import AppKit
import FPGAStudioCore
import SwiftUI

struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var language: HDLLanguage
    var searchText: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // NSViewRepresentable is initially measured without a useful frame. Give
        // TextKit a real document size so AppKit cannot collapse valid source to
        // a zero-height, apparently read-only editor.
        let initialSize = NSSize(width: 800, height: 600)
        let textView = NSTextView(frame: NSRect(origin: .zero, size: initialSize))
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
        textView.delegate = context.coordinator
        textView.string = text
        textView.minSize = NSSize(width: 0, height: initialSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: initialSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: initialSize))
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.textView = textView
        context.coordinator.highlight(textView)
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(location: min(selection.location, text.utf16.count), length: 0))
            context.coordinator.highlight(textView)
        }
        context.coordinator.highlightSearch(textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var textView: NSTextView?
        private var highlighting = false
        init(_ parent: CodeEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !highlighting, let textView else { return }
            parent.text = textView.string
            highlight(textView)
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            highlightBracket(in: textView)
        }

        func highlight(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            highlighting = true
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.textColor], range: full)
            let rules: [(String, NSColor)] = [
                (parent.language == .vhdl ? #"--.*$"# : #"//.*$|/\*[\s\S]*?\*/"#, .secondaryLabelColor),
                (#"\b(module|endmodule|logic|wire|reg|input|output|always|always_ff|always_comb|begin|end|if|else|case|endcase|assign|entity|architecture|signal|process|port|is|then|library|use|generic|downto|to)\b"#, .systemPurple),
                (#"\b(0x[0-9A-Fa-f]+|\d+'[bhd][0-9A-Fa-f_xzXZ]+|\d+)\b"#, .systemBlue),
                (#"\"(?:\\.|[^\"])*\""#, .systemRed)
            ]
            for (pattern, color) in rules {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines, .caseInsensitive]) else { continue }
                for match in regex.matches(in: storage.string, range: full) { storage.addAttribute(.foregroundColor, value: color, range: match.range) }
            }
            storage.endEditing()
            highlighting = false
        }

        func highlightSearch(_ textView: NSTextView) {
            guard !parent.searchText.isEmpty, let storage = textView.textStorage else { return }
            let source = storage.string as NSString
            var searchRange = NSRange(location: 0, length: source.length)
            while searchRange.length > 0 {
                let found = source.range(of: parent.searchText, options: [.caseInsensitive], range: searchRange)
                if found.location == NSNotFound { break }
                storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), range: found)
                let next = found.location + found.length
                searchRange = NSRange(location: next, length: source.length - next)
            }
        }

        private func highlightBracket(in textView: NSTextView) {
            let source = textView.string as NSString
            let caret = textView.selectedRange().location
            guard caret > 0, caret <= source.length else { return }
            let character = source.substring(with: NSRange(location: caret - 1, length: 1))
            let pairs: [String: (String, Int)] = ["(": (")", 1), "[": ("]", 1), "{": ("}", 1), ")": ("(", -1), "]": ("[", -1), "}": ("{", -1)]
            guard let (match, direction) = pairs[character] else { return }
            var depth = 0
            var index = caret - 1
            while index >= 0 && index < source.length {
                let candidate = source.substring(with: NSRange(location: index, length: 1))
                if candidate == character { depth += 1 }
                if candidate == match { depth -= 1; if depth == 0 { textView.showFindIndicator(for: NSRange(location: index, length: 1)); break } }
                index += direction
            }
        }
    }
}

final class LineNumberRulerView: NSRulerView {
    weak var textView: NSTextView?
    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 46
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        NSColor.controlBackgroundColor.setFill(); rect.fill()
        let visible = textView.enclosingScrollView?.contentView.bounds ?? .zero
        let glyphRange = layout.glyphRange(forBoundingRect: visible, in: container)
        let text = textView.string as NSString
        var lineNumber = 1
        if glyphRange.location > 0 { lineNumber += text.substring(to: glyphRange.location).filter { $0 == "\n" }.count }
        var glyph = glyphRange.location
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor]
        while glyph < NSMaxRange(glyphRange) {
            let character = layout.characterIndexForGlyph(at: glyph)
            let lineRange = text.lineRange(for: NSRange(location: character, length: 0))
            let lineGlyph = layout.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            var location = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).origin
            location.y += textView.textContainerOrigin.y
            let label = String(lineNumber) as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: location.y), withAttributes: attributes)
            glyph = NSMaxRange(lineGlyph)
            lineNumber += 1
        }
    }
}
