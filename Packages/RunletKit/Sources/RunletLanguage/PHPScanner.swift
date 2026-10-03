import Foundation

/// One token of `PHPScanner`: a word, a punctuation character, a whole string literal, a
/// comment, or the text around PHP (open and close tags, inline HTML). Whitespace is skipped.
struct PHPToken: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A name, variable, keyword, or number run (`$user`, `App\Models\User`, `fn`, `42`).
        case word
        /// One other character of code (`;`, `)`, `-`, `>`).
        case punctuation
        /// A whole quoted string, backtick string, heredoc, or nowdoc.
        case string
        /// `// …` or `# …`, without the line break.
        case lineComment
        /// `/* … */` or `/** … */`.
        case blockComment
        case openTag
        case closeTag
        case inlineHTML
    }

    var kind: Kind
    /// UTF-8 byte offsets in the scanned text.
    var range: Range<Int>
    /// 0-based lines where the token starts and ends.
    var line: Int
    var endLine: Int
    var text: String

    var isCode: Bool { kind == .word || kind == .punctuation || kind == .string }
    var isComment: Bool { kind == .lineComment || kind == .blockComment }
}

/// A small PHP lexer for Format Code (#36): enough to tell code from comments, strings,
/// heredocs, and inline HTML, so the formatter wrapper can find a snippet's last statement and
/// check that the formatter kept every comment where it was. It never evaluates anything.
enum PHPScanner {
    static func tokens(_ source: String) -> [PHPToken] {
        var scanner = Scanner(bytes: Array(source.utf8))
        return scanner.run()
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0
        var line = 0
        var tokens: [PHPToken] = []

        init(bytes: [UInt8]) { self.bytes = bytes }

        var count: Int { bytes.count }

        func byte(_ offset: Int) -> UInt8? { offset < count ? bytes[offset] : nil }

        func starts(with text: String, at offset: Int) -> Bool {
            let pattern = Array(text.utf8)
            guard offset + pattern.count <= count else { return false }
            for (i, value) in pattern.enumerated() where bytes[offset + i] != value { return false }
            return true
        }

        func startsCaseInsensitive(with text: String, at offset: Int) -> Bool {
            let pattern = Array(text.lowercased().utf8)
            guard offset + pattern.count <= count else { return false }
            for (i, value) in pattern.enumerated() {
                var b = bytes[offset + i]
                if b >= 65 && b <= 90 { b += 32 }
                if b != value { return false }
            }
            return true
        }

        static func isWordByte(_ b: UInt8) -> Bool {
            (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95 || b == 92 || b >= 0x80
        }

        static func isLabelStart(_ b: UInt8) -> Bool {
            (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95 || b >= 0x80
        }

        static func isLabelByte(_ b: UInt8) -> Bool { isLabelStart(b) || (b >= 48 && b <= 57) }

        mutating func emit(_ kind: PHPToken.Kind, from start: Int, startLine: Int) {
            guard index > start else { return }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            tokens.append(PHPToken(kind: kind, range: start..<index, line: startLine, endLine: line, text: text))
        }

        /// Moves to `end`, counting line breaks.
        mutating func advance(to end: Int) {
            let target = min(end, count)
            while index < target {
                if bytes[index] == 10 { line += 1 }
                index += 1
            }
        }

        mutating func run() -> [PHPToken] {
            var inPHP = false
            while index < count {
                if !inPHP {
                    inPHP = scanHTML()
                } else {
                    inPHP = scanPHP()
                }
            }
            return tokens
        }

        /// Inline HTML up to the next open tag. Returns true when an open tag was found.
        mutating func scanHTML() -> Bool {
            let start = index, startLine = line
            var cursor = index
            while cursor < count {
                if bytes[cursor] == 60, starts(with: "<?", at: cursor) {
                    if startsCaseInsensitive(with: "<?php", at: cursor + 0), cursor + 5 >= count || !Self.isLabelByte(bytes[cursor + 5]) {
                        advance(to: cursor)
                        emit(.inlineHTML, from: start, startLine: startLine)
                        let tagStart = index, tagLine = line
                        advance(to: cursor + 5)
                        emit(.openTag, from: tagStart, startLine: tagLine)
                        return true
                    }
                    if starts(with: "<?=", at: cursor) {
                        advance(to: cursor)
                        emit(.inlineHTML, from: start, startLine: startLine)
                        let tagStart = index, tagLine = line
                        advance(to: cursor + 3)
                        emit(.openTag, from: tagStart, startLine: tagLine)
                        return true
                    }
                }
                cursor += 1
            }
            advance(to: count)
            emit(.inlineHTML, from: start, startLine: startLine)
            return false
        }

        /// One token (or whitespace) of PHP code. Returns false after a close tag.
        mutating func scanPHP() -> Bool {
            let b = bytes[index]
            let start = index, startLine = line
            switch b {
            case 32, 9, 10, 13, 11, 12:
                advance(to: index + 1)
            case 63 where byte(index + 1) == 62: // ?>
                advance(to: index + 2)
                emit(.closeTag, from: start, startLine: startLine)
                return false
            case 35 where byte(index + 1) == 91: // #[ attribute
                advance(to: index + 1)
                emit(.punctuation, from: start, startLine: startLine)
            case 35: // # comment
                scanLineComment()
                emit(.lineComment, from: start, startLine: startLine)
            case 47 where byte(index + 1) == 47: // //
                scanLineComment()
                emit(.lineComment, from: start, startLine: startLine)
            case 47 where byte(index + 1) == 42: // /*
                var cursor = index + 2
                while cursor < count, !(bytes[cursor] == 42 && byte(cursor + 1) == 47) { cursor += 1 }
                advance(to: min(cursor + 2, count))
                emit(.blockComment, from: start, startLine: startLine)
            case 39: // '
                advance(to: skipSingleQuoted(from: index))
                emit(.string, from: start, startLine: startLine)
            case 34, 96: // " or `
                advance(to: skipInterpolated(from: index, closing: b))
                emit(.string, from: start, startLine: startLine)
            case 60 where starts(with: "<<<", at: index):
                if let end = heredocEnd(from: index) {
                    advance(to: end)
                    emit(.string, from: start, startLine: startLine)
                } else {
                    advance(to: index + 1)
                    emit(.punctuation, from: start, startLine: startLine)
                }
            default:
                if Self.isWordByte(b) || (b == 36 && byte(index + 1).map(Self.isLabelStart) == true) {
                    var cursor = index + 1
                    while cursor < count, Self.isWordByte(bytes[cursor]) { cursor += 1 }
                    advance(to: cursor)
                    emit(.word, from: start, startLine: startLine)
                } else {
                    advance(to: index + 1)
                    emit(.punctuation, from: start, startLine: startLine)
                }
            }
            return true
        }

        /// A `//` or `#` comment ends before a line break or a close tag.
        mutating func scanLineComment() {
            var cursor = index
            while cursor < count, bytes[cursor] != 10, bytes[cursor] != 13, !(bytes[cursor] == 63 && byte(cursor + 1) == 62) {
                cursor += 1
            }
            advance(to: cursor)
        }

        /// The offset after a single-quoted string that starts at `start`.
        func skipSingleQuoted(from start: Int) -> Int {
            var cursor = start + 1
            while cursor < count {
                if bytes[cursor] == 92 { cursor += 2; continue }
                if bytes[cursor] == 39 { return cursor + 1 }
                cursor += 1
            }
            return count
        }

        /// The offset after a double-quoted or backtick string, skipping `{$…}` and `${…}`
        /// interpolations (which may contain strings and braces of their own).
        func skipInterpolated(from start: Int, closing: UInt8) -> Int {
            var cursor = start + 1
            while cursor < count {
                let b = bytes[cursor]
                if b == 92 { cursor += 2; continue }
                if b == closing { return cursor + 1 }
                if (b == 123 && byte(cursor + 1) == 36) || (b == 36 && byte(cursor + 1) == 123) {
                    cursor = skipBraces(from: b == 123 ? cursor : cursor + 1)
                    continue
                }
                cursor += 1
            }
            return count
        }

        /// From an opening `{`, the offset after its matching `}`.
        func skipBraces(from start: Int) -> Int {
            var depth = 0
            var cursor = start
            while cursor < count {
                let b = bytes[cursor]
                switch b {
                case 123: depth += 1
                case 125:
                    depth -= 1
                    if depth == 0 { return cursor + 1 }
                case 39:
                    cursor = skipSingleQuoted(from: cursor)
                    continue
                case 34, 96:
                    cursor = skipInterpolated(from: cursor, closing: b)
                    continue
                default: break
                }
                cursor += 1
            }
            return count
        }

        /// The offset after a heredoc or nowdoc that starts at `start` (`<<<`), or nil when the
        /// text there is not one. The closing label may be indented (PHP 7.3+).
        func heredocEnd(from start: Int) -> Int? {
            var cursor = start + 3
            while cursor < count, bytes[cursor] == 32 || bytes[cursor] == 9 { cursor += 1 }
            var quote: UInt8?
            if cursor < count, bytes[cursor] == 39 || bytes[cursor] == 34 { quote = bytes[cursor]; cursor += 1 }
            guard cursor < count, Self.isLabelStart(bytes[cursor]) else { return nil }
            let labelStart = cursor
            while cursor < count, Self.isLabelByte(bytes[cursor]) { cursor += 1 }
            let label = Array(bytes[labelStart..<cursor])
            if let quote {
                guard cursor < count, bytes[cursor] == quote else { return nil }
                cursor += 1
            }
            if cursor < count, bytes[cursor] == 13 { cursor += 1 }
            guard cursor < count, bytes[cursor] == 10 else { return nil }
            cursor += 1
            // Each following line: optional indentation, then the label not followed by a label byte.
            while cursor < count {
                var probe = cursor
                while probe < count, bytes[probe] == 32 || bytes[probe] == 9 { probe += 1 }
                if probe + label.count <= count, Array(bytes[probe..<probe + label.count]) == label,
                   probe + label.count == count || !Self.isLabelByte(bytes[probe + label.count]) {
                    return probe + label.count
                }
                while cursor < count, bytes[cursor] != 10 { cursor += 1 }
                cursor += 1
            }
            return count
        }
    }
}
