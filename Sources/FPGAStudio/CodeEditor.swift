import AppKit
import FPGAStudioCore
import SwiftUI

struct CodeEditor: NSViewRepresentable {
    let documentID: String
    let text: String
    var language: HDLLanguage
    var searchText: String
    var didEdit: (String) -> Void
    var registerBuffer: (String, @escaping @MainActor () -> String) -> Void
    var unregisterBuffer: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> CodeEditorContainerView {
        let containerView = CodeEditorContainerView()
        let scrollView = containerView.scrollView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView = containerView.textView
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.string = text
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator

        context.coordinator.attach(textView: textView, containerView: containerView)
        registerBuffer(documentID) { [weak textView] in
            textView?.string ?? text
        }
        return containerView
    }

    func updateNSView(_ containerView: CodeEditorContainerView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updateSearch(in: containerView.textView)
    }

    static func dismantleNSView(_ nsView: CodeEditorContainerView, coordinator: Coordinator) {
        coordinator.detach()
        coordinator.parent.unregisterBuffer(coordinator.parent.documentID)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
        var parent: CodeEditor
        weak var textView: NSTextView?
        weak var containerView: CodeEditorContainerView?

        private var isApplyingAttributes = false
        private var blockCommentState: [Bool] = []
        private var initialHighlightTask: Task<Void, Never>?
        private var previousSearchText = ""
        private var searchRanges: [NSRange] = []

        init(_ parent: CodeEditor) {
            self.parent = parent
        }

        func attach(textView: NSTextView, containerView: CodeEditorContainerView) {
            self.textView = textView
            self.containerView = containerView
            containerView.gutterView.rebuildIndex(for: textView.string)
            beginInitialHighlight(in: textView)
            updateSearch(in: textView)
        }

        func detach() {
            initialHighlightTask?.cancel()
            initialHighlightTask = nil
            textView?.textStorage?.delegate = nil
            textView?.delegate = nil
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingAttributes, let textView else { return }
            parent.didEdit(parent.documentID)
            if !parent.searchText.isEmpty {
                updateSearch(in: textView, force: true)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            highlightBracket(in: textView)
        }

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters), !isApplyingAttributes else { return }
            initialHighlightTask?.cancel()
            initialHighlightTask = nil
            containerView?.gutterView.applyEdit(
                text: textStorage.string,
                editedRange: editedRange,
                changeInLength: delta
            )
            containerView?.needsLayout = true
            containerView?.layoutSubtreeIfNeeded()
            containerView?.gutterView.needsDisplay = true
            containerView?.gutterView.displayIfNeeded()

            guard textView?.hasMarkedText() != true else { return }
            highlightEdit(in: textStorage, editedRange: editedRange)
        }

        func updateSearch(in textView: NSTextView, force: Bool = false) {
            guard force || previousSearchText != parent.searchText else { return }
            guard let storage = textView.textStorage else { return }
            isApplyingAttributes = true
            for range in searchRanges {
                let location = min(range.location, storage.length)
                let safeLength = max(0, min(range.length, storage.length - location))
                if safeLength > 0 {
                    storage.removeAttribute(.backgroundColor, range: NSRange(location: location, length: safeLength))
                }
            }
            searchRanges.removeAll(keepingCapacity: true)
            previousSearchText = parent.searchText

            guard !parent.searchText.isEmpty else {
                isApplyingAttributes = false
                return
            }
            let source = storage.string as NSString
            var searchRange = NSRange(location: 0, length: source.length)
            while searchRange.length > 0 {
                let found = source.range(of: parent.searchText, options: [.caseInsensitive], range: searchRange)
                if found.location == NSNotFound { break }
                searchRanges.append(found)
                storage.addAttribute(
                    .backgroundColor,
                    value: NSColor.systemYellow.withAlphaComponent(0.3),
                    range: found
                )
                let next = found.location + max(found.length, 1)
                searchRange = NSRange(location: next, length: source.length - next)
            }
            isApplyingAttributes = false
        }

        private func beginInitialHighlight(in textView: NSTextView) {
            guard let storage = textView.textStorage, let gutter = containerView?.gutterView else { return }
            blockCommentState = Array(repeating: false, count: gutter.lineIndex.lineCount)
            initialHighlightTask?.cancel()
            initialHighlightTask = Task { @MainActor [weak self, weak storage] in
                guard let self, let storage else { return }
                var firstLine = 1
                while firstLine <= gutter.lineIndex.lineCount, !Task.isCancelled {
                    let lastLine = min(firstLine + 399, gutter.lineIndex.lineCount)
                    self.highlightLines(
                        in: storage,
                        lineIndex: gutter.lineIndex,
                        from: firstLine,
                        through: lastLine,
                        stopWhenStable: false
                    )
                    firstLine = lastLine + 1
                    await Task.yield()
                }
            }
        }

        private func highlightEdit(in storage: NSTextStorage, editedRange: NSRange) {
            guard let lineIndex = containerView?.gutterView.lineIndex else { return }
            let previousCount = blockCommentState.count
            let newCount = lineIndex.lineCount
            let firstLine = lineIndex.lineNumber(atUTF16Offset: editedRange.location)
            if newCount > previousCount {
                blockCommentState.insert(
                    contentsOf: repeatElement(false, count: newCount - previousCount),
                    at: min(firstLine, blockCommentState.count)
                )
            } else if newCount < previousCount {
                let removalStart = min(firstLine, blockCommentState.count)
                let removalEnd = min(removalStart + previousCount - newCount, blockCommentState.count)
                if removalStart < removalEnd {
                    blockCommentState.removeSubrange(removalStart..<removalEnd)
                }
            }
            if blockCommentState.count != newCount {
                blockCommentState = Array(blockCommentState.prefix(newCount))
                blockCommentState.append(contentsOf: repeatElement(false, count: max(0, newCount - blockCommentState.count)))
            }

            let lastEditedOffset = max(editedRange.location, NSMaxRange(editedRange) - 1)
            let lastEditedLine = lineIndex.lineNumber(atUTF16Offset: lastEditedOffset)
            highlightLines(
                in: storage,
                lineIndex: lineIndex,
                from: firstLine,
                through: lastEditedLine,
                stopWhenStable: true
            )
        }

        private func highlightLines(
            in storage: NSTextStorage,
            lineIndex: LogicalLineIndex,
            from firstLine: Int,
            through requiredLastLine: Int,
            stopWhenStable: Bool
        ) {
            let source = storage.string as NSString
            var line = max(1, firstLine)
            var startsInBlock = line > 1 ? blockCommentState[line - 2] : false

            while line <= lineIndex.lineCount {
                guard let start = lineIndex.start(ofLine: line) else { break }
                let end = lineIndex.start(ofLine: line + 1) ?? source.length
                let range = NSRange(location: start, length: max(0, end - start))
                let lineText = source.substring(with: range)
                let oldEndState = blockCommentState.indices.contains(line - 1) ? blockCommentState[line - 1] : false
                let result = HDLSyntaxLexer.lexLine(
                    lineText,
                    language: parent.language,
                    startsInBlockComment: startsInBlock
                )

                isApplyingAttributes = true
                if range.length > 0 {
                    storage.addAttributes(
                        [
                            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                            .foregroundColor: NSColor.textColor
                        ],
                        range: range
                    )
                    for token in result.tokens {
                        storage.addAttribute(
                            .foregroundColor,
                            value: color(for: token.kind),
                            range: NSRange(location: start + token.range.location, length: token.range.length)
                        )
                    }
                }
                isApplyingAttributes = false

                if blockCommentState.indices.contains(line - 1) {
                    blockCommentState[line - 1] = result.endsInBlockComment
                }
                startsInBlock = result.endsInBlockComment
                let canStop = stopWhenStable && line >= requiredLastLine && result.endsInBlockComment == oldEndState
                line += 1
                if canStop { break }
                if !stopWhenStable && line > requiredLastLine { break }
            }
        }

        private func color(for kind: HDLSyntaxTokenKind) -> NSColor {
            switch kind {
            case .keyword: .systemPurple
            case .number: .systemBlue
            case .string: .systemRed
            case .comment: .secondaryLabelColor
            }
        }

        private func highlightBracket(in textView: NSTextView) {
            let source = textView.string as NSString
            let caret = textView.selectedRange().location
            guard caret > 0, caret <= source.length else { return }
            let character = source.substring(with: NSRange(location: caret - 1, length: 1))
            let pairs: [String: (String, Int)] = [
                "(": (")", 1), "[": ("]", 1), "{": ("}", 1),
                ")": ("(", -1), "]": ("[", -1), "}": ("{", -1)
            ]
            guard let (match, direction) = pairs[character] else { return }
            var depth = 0
            var index = caret - 1
            while index >= 0 && index < source.length {
                let candidate = source.substring(with: NSRange(location: index, length: 1))
                if candidate == character { depth += 1 }
                if candidate == match {
                    depth -= 1
                    if depth == 0 {
                        textView.showFindIndicator(for: NSRange(location: index, length: 1))
                        break
                    }
                }
                index += direction
            }
        }
    }
}

final class CodeEditorContainerView: NSView {
    let scrollView: NSScrollView
    let textView: NSTextView
    let gutterView: LineNumberGutterView

    override init(frame frameRect: NSRect) {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            fatalError("NSTextView.scrollableTextView() did not provide a text view")
        }
        self.scrollView = scrollView
        self.textView = textView
        self.gutterView = LineNumberGutterView(textView: textView)
        super.init(frame: frameRect)

        addSubview(gutterView)
        addSubview(scrollView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func layout() {
        super.layout()
        let gutterWidth = min(gutterView.preferredWidth, bounds.width)
        gutterView.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        scrollView.frame = NSRect(x: gutterWidth, y: 0, width: max(0, bounds.width - gutterWidth), height: bounds.height)
    }

    @objc private func scrollBoundsChanged() {
        gutterView.needsDisplay = true
    }
}

final class LineNumberGutterView: NSView {
    weak var textView: NSTextView?
    private(set) var lineIndex = LogicalLineIndex()
    private let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

    var preferredWidth: CGFloat {
        let digits = max(3, String(lineIndex.lineCount).count)
        let sample = String(repeating: "8", count: digits) as NSString
        return max(46, ceil(sample.size(withAttributes: [.font: font]).width) + 16)
    }

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    func rebuildIndex(for text: String) {
        lineIndex.rebuild(for: text)
        superview?.needsLayout = true
        needsDisplay = true
    }

    func applyEdit(text: String, editedRange: NSRange, changeInLength: Int) {
        let previousWidth = preferredWidth
        lineIndex.applyEdit(to: text, editedRange: editedRange, changeInLength: changeInLength)
        if preferredWidth != previousWidth { superview?.needsLayout = true }
        needsDisplay = true
    }

    func lineFragmentRect(forLineNumber lineNumber: Int) -> NSRect? {
        guard let textView,
              let layout = textView.layoutManager,
              let container = textView.textContainer,
              let start = lineIndex.start(ofLine: lineNumber) else { return nil }
        layout.ensureLayout(for: container)
        let textLength = (textView.string as NSString).length
        if start < textLength, layout.numberOfGlyphs > 0 {
            let glyph = layout.glyphIndexForCharacter(at: start)
            return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        return layout.extraLineFragmentRect
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView,
              let layout = textView.layoutManager,
              let container = textView.textContainer else { return }
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()

        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()

        layout.ensureLayout(for: container)
        let visible = textView.enclosingScrollView?.contentView.bounds ?? .zero
        let origin = textView.textContainerOrigin
        let layoutVisible = visible.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphRange = layout.glyphRange(forBoundingRect: layoutVisible, in: container)
        let textLength = (textView.string as NSString).length
        let firstCharacter = glyphRange.location < layout.numberOfGlyphs
            ? layout.characterIndexForGlyph(at: glyphRange.location)
            : textLength
        var lineNumber = lineIndex.lineNumber(atUTF16Offset: firstCharacter)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor
        ]

        while lineIndex.start(ofLine: lineNumber) != nil {
            guard let lineRect = lineFragmentRect(forLineNumber: lineNumber) else { break }
            let y = lineRect.minY + origin.y - visible.minY
            if y > bounds.maxY { break }
            if y + lineRect.height >= bounds.minY {
                let label = String(lineNumber) as NSString
                let size = label.size(withAttributes: attributes)
                label.draw(
                    at: NSPoint(x: bounds.width - size.width - 8, y: y),
                    withAttributes: attributes
                )
            }
            lineNumber += 1
        }
    }
}
