import AppKit

/// Token categories used for syntax colors.
enum PHPTokenKind {
    case keyword, variable, string, comment, number, tag, type, function, constant, docTag
    /// `//?`, `/*?*/`, `/*?->…*/`, `/*?.*/`: shows a value inline when the code runs (#10).
    case magicComment
}

/// A small single-pass PHP scanner for syntax highlighting. It works on UTF-16 units so
/// ranges map directly onto NSTextStorage without conversion. Heredoc/nowdoc and
/// interpolation are approximated; correctness of execution never depends on this.
struct PHPHighlighter {
    static let keywords: Set<String> = [
        "abstract", "and", "array", "as", "break", "callable", "case", "catch", "class", "clone", "const", "continue",
        "declare", "default", "do", "echo", "else", "elseif", "empty", "enddeclare", "endfor", "endforeach", "endif",
        "endswitch", "endwhile", "enum", "extends", "final", "finally", "fn", "for", "foreach", "function", "global",
        "goto", "if", "implements", "include", "include_once", "instanceof", "insteadof", "interface", "isset", "list",
        "match", "namespace", "new", "or", "print", "private", "protected", "public", "readonly", "require",
        "require_once", "return", "static", "switch", "throw", "trait", "try", "unset", "use", "var", "while", "xor",
        "yield", "from", "exit", "die", "self", "parent",
    ]
    static let constants: Set<String> = ["true", "false", "null", "TRUE", "FALSE", "NULL"]
    static let types: Set<String> = ["int", "float", "string", "bool", "void", "mixed", "object", "iterable", "never", "null", "?"]

    struct Token {
        var range: NSRange
        var kind: PHPTokenKind
    }

    static func tokenize(_ string: NSString) -> [Token] {
        var tokens: [Token] = []
        let length = string.length
        var buffer = [unichar](repeating: 0, count: length)
        string.getCharacters(&buffer, range: NSRange(location: 0, length: length))

        func isIdentStart(_ c: unichar) -> Bool {
            (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c >= 0x80
        }
        func isIdent(_ c: unichar) -> Bool { isIdentStart(c) || (c >= 48 && c <= 57) }
        func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }

        var i = 0
        var lastSignificant: String = ""
        while i < length {
            let c = buffer[i]
            // Comments
            if c == 0x2F /* / */, i + 1 < length, buffer[i + 1] == 0x2F || buffer[i + 1] == 0x2A {
                let start = i
                if buffer[i + 1] == 0x2F {
                    while i < length && buffer[i] != 0x0A { i += 1 }
                } else {
                    i += 2
                    while i < length && !(buffer[i] == 0x2A && i + 1 < length && buffer[i + 1] == 0x2F) { i += 1 }
                    i = min(length, i + 2)
                    // PHPDoc tags inside block comments.
                    var j = start
                    while j < i {
                        if buffer[j] == 0x40 /* @ */, j + 1 < i, isIdentStart(buffer[j + 1]) {
                            let tagStart = j
                            j += 1
                            while j < i && (isIdent(buffer[j]) || buffer[j] == 0x2D) { j += 1 }
                            tokens.append(Token(range: NSRange(location: tagStart, length: j - tagStart), kind: .docTag))
                        } else {
                            j += 1
                        }
                    }
                }
                let range = NSRange(location: start, length: i - start)
                tokens.insert(Token(range: range, kind: isMagicComment(string.substring(with: range)) ? .magicComment : .comment), at: max(0, tokens.count - countDocTags(tokens, from: start)))
                continue
            }
            if c == 0x23 /* # */ {
                if i + 1 < length, buffer[i + 1] == 0x5B /* [ attribute */ {
                    i += 2
                    continue
                }
                let start = i
                while i < length && buffer[i] != 0x0A { i += 1 }
                tokens.append(Token(range: NSRange(location: start, length: i - start), kind: .comment))
                continue
            }
            // Strings
            if c == 0x27 || c == 0x22 || c == 0x60 {
                let start = i
                let quote = c
                i += 1
                while i < length && buffer[i] != quote {
                    if buffer[i] == 0x5C { i += 1 }
                    i += 1
                }
                i = min(length, i + 1)
                tokens.append(Token(range: NSRange(location: start, length: i - start), kind: .string))
                if quote == 0x22 {
                    // Interpolated variables.
                    var j = start + 1
                    while j < i - 1 {
                        if buffer[j] == 0x5C { j += 2; continue }
                        if buffer[j] == 0x24, j + 1 < i, isIdentStart(buffer[j + 1]) {
                            let varStart = j
                            j += 1
                            while j < i && isIdent(buffer[j]) { j += 1 }
                            tokens.append(Token(range: NSRange(location: varStart, length: j - varStart), kind: .variable))
                        } else {
                            j += 1
                        }
                    }
                }
                lastSignificant = "string"
                continue
            }
            // Heredoc / nowdoc
            if c == 0x3C, i + 2 < length, buffer[i + 1] == 0x3C, buffer[i + 2] == 0x3C {
                let start = i
                var j = i + 3
                while j < length && (buffer[j] == 0x20 || buffer[j] == 0x27 || buffer[j] == 0x22) { j += 1 }
                let labelStart = j
                while j < length && isIdent(buffer[j]) { j += 1 }
                let label = string.substring(with: NSRange(location: labelStart, length: j - labelStart))
                if !label.isEmpty {
                    let searchRange = NSRange(location: j, length: length - j)
                    let pattern = "(?m)^\\s*\(NSRegularExpression.escapedPattern(for: label))\\b"
                    if let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: string as String, range: searchRange) {
                        i = match.range.location + match.range.length
                    } else {
                        i = length
                    }
                    tokens.append(Token(range: NSRange(location: start, length: i - start), kind: .string))
                    continue
                }
            }
            // Open/close tags
            if c == 0x3C, i + 4 < length, buffer[i + 1] == 0x3F {
                let start = i
                i += 2
                while i < length && isIdent(buffer[i]) { i += 1 }
                tokens.append(Token(range: NSRange(location: start, length: i - start), kind: .tag))
                continue
            }
            if c == 0x3F, i + 1 < length, buffer[i + 1] == 0x3E {
                tokens.append(Token(range: NSRange(location: i, length: 2), kind: .tag))
                i += 2
                continue
            }
            // Variables
            if c == 0x24, i + 1 < length, isIdentStart(buffer[i + 1]) {
                let start = i
                i += 1
                while i < length && isIdent(buffer[i]) { i += 1 }
                tokens.append(Token(range: NSRange(location: start, length: i - start), kind: .variable))
                lastSignificant = "$"
                continue
            }
            // Numbers
            if isDigit(c) {
                let start = i
                while i < length && (isIdent(buffer[i]) || buffer[i] == 0x2E) { i += 1 }
                tokens.append(Token(range: NSRange(location: start, length: i - start), kind: .number))
                continue
            }
            // Identifiers
            if isIdentStart(c) || c == 0x5C {
                let start = i
                while i < length && (isIdent(buffer[i]) || buffer[i] == 0x5C) { i += 1 }
                let word = string.substring(with: NSRange(location: start, length: i - start))
                var next = i
                while next < length && (buffer[next] == 0x20 || buffer[next] == 0x09) { next += 1 }
                let followedByParen = next < length && buffer[next] == 0x28
                let followedByScope = next + 1 < length && buffer[next] == 0x3A && buffer[next + 1] == 0x3A
                let afterArrow = lastSignificant == "->" || lastSignificant == "::"
                let kind: PHPTokenKind?
                if afterArrow {
                    kind = followedByParen ? .function : nil
                } else if keywords.contains(word.lowercased()) {
                    kind = .keyword
                } else if constants.contains(word) {
                    kind = .constant
                } else if types.contains(word) {
                    kind = .type
                } else if followedByParen && lastSignificant != "new" {
                    kind = .function
                } else if followedByScope || lastSignificant == "new" || lastSignificant == "extends" || lastSignificant == "implements" || lastSignificant == "instanceof" || word.contains("\\") || (word.first?.isUppercase ?? false) {
                    kind = word.uppercased() == word && word.count > 1 && !word.contains("\\") ? .constant : .type
                } else {
                    kind = nil
                }
                if let kind { tokens.append(Token(range: NSRange(location: start, length: i - start), kind: kind)) }
                lastSignificant = word.lowercased()
                continue
            }
            if c == 0x2D, i + 1 < length, buffer[i + 1] == 0x3E {
                lastSignificant = "->"
                i += 2
                continue
            }
            if c == 0x3F, i + 2 < length, buffer[i + 1] == 0x2D, buffer[i + 2] == 0x3E {
                lastSignificant = "->"
                i += 3
                continue
            }
            if c == 0x3A, i + 1 < length, buffer[i + 1] == 0x3A {
                lastSignificant = "::"
                i += 2
                continue
            }
            if c != 0x20 && c != 0x09 && c != 0x0A && c != 0x0D {
                lastSignificant = String(utf16CodeUnits: [c], count: 1)
            }
            i += 1
        }
        return tokens
    }

    /// The magic-comment forms the runner shows (the runner decides with PHP's own tokenizer).
    static func isMagicComment(_ text: String) -> Bool {
        if text.hasPrefix("//?") { return text.dropFirst(3).allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" } }
        guard text.hasPrefix("/*?"), text.hasSuffix("*/"), text.count >= 5 else { return false }
        let body = text.dropFirst(3).dropLast(2).trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty || body == "." || body.hasPrefix("->") || body.hasPrefix("?->")
    }

    private static func countDocTags(_ tokens: [Token], from start: Int) -> Int {
        var count = 0
        for token in tokens.reversed() {
            if token.kind == .docTag && token.range.location >= start { count += 1 } else { break }
        }
        return count
    }
}

/// Editor color palette, resolved for light or dark appearance.
struct EditorTheme {
    var text: NSColor
    var background: NSColor
    var keyword: NSColor
    var variable: NSColor
    var string: NSColor
    var comment: NSColor
    var number: NSColor
    var tag: NSColor
    var type: NSColor
    var function: NSColor
    var constant: NSColor
    var docTag: NSColor
    var gutterText: NSColor
    var gutterBackground: NSColor
    var currentLine: NSColor
    var errorLine: NSColor
    var bracketMatch: NSColor
    /// Magic comments and their inline values (#10).
    var magicComment: NSColor = NSColor(srgbRed: 0.55, green: 0.36, blue: 0, alpha: 1)
    var magicCommentBackground: NSColor = NSColor(srgbRed: 1, green: 0.80, blue: 0.25, alpha: 0.24)
    var inlineText: NSColor = NSColor(white: 0.45, alpha: 1)
    var inlineBackground: NSColor = NSColor(white: 0, alpha: 0.04)
    var inlineWarning: NSColor = NSColor(srgbRed: 0.80, green: 0.36, blue: 0.08, alpha: 1)

    static func resolve(dark: Bool) -> EditorTheme {
        if dark {
            var theme = EditorTheme(
                text: NSColor(white: 0.88, alpha: 1), background: NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1),
                keyword: NSColor(srgbRed: 0.99, green: 0.47, blue: 0.62, alpha: 1), variable: NSColor(srgbRed: 0.55, green: 0.80, blue: 0.99, alpha: 1),
                string: NSColor(srgbRed: 0.98, green: 0.73, blue: 0.47, alpha: 1), comment: NSColor(srgbRed: 0.50, green: 0.55, blue: 0.60, alpha: 1),
                number: NSColor(srgbRed: 0.82, green: 0.70, blue: 0.99, alpha: 1), tag: NSColor(srgbRed: 0.99, green: 0.47, blue: 0.62, alpha: 1),
                type: NSColor(srgbRed: 0.45, green: 0.86, blue: 0.80, alpha: 1), function: NSColor(srgbRed: 0.70, green: 0.88, blue: 0.55, alpha: 1),
                constant: NSColor(srgbRed: 0.82, green: 0.70, blue: 0.99, alpha: 1), docTag: NSColor(srgbRed: 0.60, green: 0.70, blue: 0.85, alpha: 1),
                gutterText: NSColor(white: 0.45, alpha: 1), gutterBackground: NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1),
                currentLine: NSColor(white: 1, alpha: 0.04), errorLine: NSColor(srgbRed: 0.9, green: 0.2, blue: 0.2, alpha: 0.22),
                bracketMatch: NSColor(white: 1, alpha: 0.18)
            )
            theme.magicComment = NSColor(srgbRed: 1, green: 0.78, blue: 0.38, alpha: 1)
            theme.magicCommentBackground = NSColor(srgbRed: 1, green: 0.72, blue: 0.20, alpha: 0.16)
            theme.inlineText = NSColor(white: 0.60, alpha: 1)
            theme.inlineBackground = NSColor(white: 1, alpha: 0.06)
            theme.inlineWarning = NSColor(srgbRed: 1, green: 0.55, blue: 0.30, alpha: 1)
            return theme
        }
        return EditorTheme(
            text: NSColor(white: 0.12, alpha: 1), background: .white,
            keyword: NSColor(srgbRed: 0.70, green: 0.10, blue: 0.40, alpha: 1), variable: NSColor(srgbRed: 0.10, green: 0.35, blue: 0.70, alpha: 1),
            string: NSColor(srgbRed: 0.75, green: 0.30, blue: 0.05, alpha: 1), comment: NSColor(srgbRed: 0.45, green: 0.50, blue: 0.55, alpha: 1),
            number: NSColor(srgbRed: 0.45, green: 0.20, blue: 0.75, alpha: 1), tag: NSColor(srgbRed: 0.70, green: 0.10, blue: 0.40, alpha: 1),
            type: NSColor(srgbRed: 0.05, green: 0.50, blue: 0.50, alpha: 1), function: NSColor(srgbRed: 0.25, green: 0.45, blue: 0.10, alpha: 1),
            constant: NSColor(srgbRed: 0.45, green: 0.20, blue: 0.75, alpha: 1), docTag: NSColor(srgbRed: 0.30, green: 0.40, blue: 0.60, alpha: 1),
            gutterText: NSColor(white: 0.6, alpha: 1), gutterBackground: NSColor(white: 0.97, alpha: 1),
            currentLine: NSColor(white: 0, alpha: 0.035), errorLine: NSColor(srgbRed: 0.95, green: 0.25, blue: 0.25, alpha: 0.18),
            bracketMatch: NSColor(white: 0, alpha: 0.12)
        )
    }

    func color(for kind: PHPTokenKind) -> NSColor {
        switch kind {
        case .keyword: keyword
        case .variable: variable
        case .string: string
        case .comment: comment
        case .number: number
        case .tag: tag
        case .type: type
        case .function: function
        case .constant: constant
        case .docTag: docTag
        case .magicComment: magicComment
        }
    }
}
