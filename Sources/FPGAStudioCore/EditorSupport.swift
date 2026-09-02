import Foundation

/// A UTF-16 line-start index suitable for AppKit's NSRange-based text system.
/// Updates rescan only the replacement and adjust existing offsets, avoiding a
/// full-document newline count while the gutter is drawing.
package struct LogicalLineIndex: Sendable {
    package private(set) var lineStarts: [Int] = [0]

    package init(_ text: String = "") {
        rebuild(for: text)
    }

    package var lineCount: Int { lineStarts.count }

    package mutating func rebuild(for text: String) {
        let source = text as NSString
        var starts = [0]
        starts.reserveCapacity(max(1, source.length / 32))
        for offset in 0..<source.length where source.character(at: offset) == 10 {
            starts.append(offset + 1)
        }
        lineStarts = starts
    }

    /// Applies an NSTextStorage character edit. `editedRange` is the range in
    /// the new string and `changeInLength` is new length minus old length.
    package mutating func applyEdit(
        to text: String,
        editedRange: NSRange,
        changeInLength delta: Int
    ) {
        let source = text as NSString
        guard editedRange.location >= 0,
              editedRange.location <= source.length,
              editedRange.length >= 0,
              NSMaxRange(editedRange) <= source.length else {
            rebuild(for: text)
            return
        }

        let oldLength = editedRange.length - delta
        guard oldLength >= 0 else {
            rebuild(for: text)
            return
        }
        let oldEnd = editedRange.location + oldLength

        lineStarts.removeAll {
            $0 > editedRange.location && $0 <= oldEnd
        }
        for index in lineStarts.indices where lineStarts[index] > oldEnd {
            lineStarts[index] += delta
        }

        var insertedStarts: [Int] = []
        if editedRange.length > 0 {
            for offset in editedRange.location..<NSMaxRange(editedRange)
            where source.character(at: offset) == 10 {
                insertedStarts.append(offset + 1)
            }
        }
        if let firstInserted = insertedStarts.first {
            var lower = 0
            var upper = lineStarts.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if lineStarts[middle] < firstInserted {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            lineStarts.insert(contentsOf: insertedStarts, at: lower)
            var index = max(1, lower)
            let upperBound = min(lineStarts.count, lower + insertedStarts.count + 1)
            while index < upperBound, index < lineStarts.count {
                if lineStarts[index] == lineStarts[index - 1] {
                    lineStarts.remove(at: index)
                } else {
                    index += 1
                }
            }
        }
        if lineStarts.first != 0 { lineStarts.insert(0, at: 0) }
    }

    /// Returns a one-based logical line number.
    package func lineNumber(atUTF16Offset offset: Int) -> Int {
        var lower = 0
        var upper = lineStarts.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if lineStarts[middle] <= offset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return max(1, lower)
    }

    package func start(ofLine lineNumber: Int) -> Int? {
        guard lineNumber > 0, lineNumber <= lineStarts.count else { return nil }
        return lineStarts[lineNumber - 1]
    }
}

package enum HDLSyntaxTokenKind: Sendable, Equatable {
    case keyword
    case number
    case string
    case comment
}

package struct HDLSyntaxToken: Sendable, Equatable {
    package let range: NSRange
    package let kind: HDLSyntaxTokenKind

    package init(range: NSRange, kind: HDLSyntaxTokenKind) {
        self.range = range
        self.kind = kind
    }
}

package struct HDLSyntaxLineResult: Sendable, Equatable {
    package let tokens: [HDLSyntaxToken]
    package let endsInBlockComment: Bool
}

/// A line-oriented lexer. Keeping block-comment state per logical line lets the
/// editor propagate highlighting only until the state becomes stable.
package enum HDLSyntaxLexer {
    private static let keywords = try! NSRegularExpression(
        pattern: #"\b(module|endmodule|logic|wire|reg|input|output|always|always_ff|always_comb|begin|end|if|else|case|endcase|assign|entity|architecture|signal|process|port|is|then|library|use|generic|downto|to)\b"#,
        options: [.caseInsensitive]
    )
    private static let numbers = try! NSRegularExpression(
        pattern: #"\b(0x[0-9A-Fa-f]+|\d+'[bhd][0-9A-Fa-f_xzXZ]+|\d+)\b"#
    )
    private static let strings = try! NSRegularExpression(
        pattern: #"\"(?:\\.|[^\"])*\""#
    )

    package static func lexLine(
        _ line: String,
        language: HDLLanguage,
        startsInBlockComment: Bool
    ) -> HDLSyntaxLineResult {
        let source = line as NSString
        let full = NSRange(location: 0, length: source.length)
        var tokens: [HDLSyntaxToken] = []

        for match in keywords.matches(in: line, range: full) {
            tokens.append(.init(range: match.range, kind: .keyword))
        }
        for match in numbers.matches(in: line, range: full) {
            tokens.append(.init(range: match.range, kind: .number))
        }
        for match in strings.matches(in: line, range: full) {
            tokens.append(.init(range: match.range, kind: .string))
        }

        if language == .vhdl {
            let comment = source.range(of: "--")
            if comment.location != NSNotFound {
                tokens.append(.init(
                    range: NSRange(location: comment.location, length: source.length - comment.location),
                    kind: .comment
                ))
            }
            return .init(tokens: tokens, endsInBlockComment: false)
        }

        var inBlock = startsInBlockComment
        var cursor = 0
        while cursor < source.length {
            if inBlock {
                let close = source.range(of: "*/", options: [], range: NSRange(location: cursor, length: source.length - cursor))
                if close.location == NSNotFound {
                    tokens.append(.init(range: NSRange(location: cursor, length: source.length - cursor), kind: .comment))
                    cursor = source.length
                } else {
                    let end = NSMaxRange(close)
                    tokens.append(.init(range: NSRange(location: cursor, length: end - cursor), kind: .comment))
                    cursor = end
                    inBlock = false
                }
                continue
            }

            let remaining = NSRange(location: cursor, length: source.length - cursor)
            let lineComment = source.range(of: "//", options: [], range: remaining)
            let blockComment = source.range(of: "/*", options: [], range: remaining)
            if lineComment.location != NSNotFound,
               blockComment.location == NSNotFound || lineComment.location < blockComment.location {
                tokens.append(.init(
                    range: NSRange(location: lineComment.location, length: source.length - lineComment.location),
                    kind: .comment
                ))
                cursor = source.length
            } else if blockComment.location != NSNotFound {
                cursor = blockComment.location
                inBlock = true
            } else {
                cursor = source.length
            }
        }

        return .init(tokens: tokens, endsInBlockComment: inBlock)
    }
}

package actor DocumentSaveCoordinator {
    private var latestRevision: [String: Int] = [:]

    package init() {}

    /// Returns false when a newer revision was already accepted.
    @discardableResult
    package func write(
        documentID: String,
        revision: Int,
        text: String,
        to url: URL
    ) throws -> Bool {
        guard revision >= latestRevision[documentID, default: -1] else { return false }
        try Data(text.utf8).write(to: url, options: .atomic)
        latestRevision[documentID] = revision
        return true
    }
}
