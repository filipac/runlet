import Foundation

/// The lexical structure of PHP code, enough to rearrange a snippet without changing what it
/// does (#39): tokens outside comments and literals, the comments, and the literals (strings,
/// heredocs, nowdocs, inline HTML) whose line breaks are part of their value.
///
/// Code starts in PHP mode, as Runlet runs a snippet without an opening tag; an opening
/// `<?php` at the start is a token of its own. `?>` ends PHP mode until the next `<?php` or
/// `<?=`. Double-quoted strings, backticks, and heredocs are scanned through their `{$…}` and
/// `${…}` interpolations, so quotes inside those don't end them. Nothing here runs code.
struct PHPCodeScan {
    enum Kind: Equatable {
        /// An identifier, keyword, or qualified name (`App\Models\User`, `\strlen`).
        case word
        /// `$name`.
        case variable
        /// A string, heredoc, or nowdoc.
        case literal
        case number
        /// One byte of punctuation, or `#[`.
        case symbol
        /// `<?php` or `<?=`.
        case openTag
        /// `?>`, with the line break PHP takes with it.
        case closeTag
        case inlineHTML
    }

    struct Token: Equatable {
        var kind: Kind
        var range: Range<Int>
    }

    /// The code as UTF-8.
    let bytes: [UInt8]
    private(set) var tokens: [Token] = []
    /// Every comment (`//`, `#`, `/* */`, `/** */`), in order; a line comment ends before its
    /// line break (or before `?>`).
    private(set) var comments: [Range<Int>] = []
    /// Strings, heredocs, nowdocs, and inline HTML, in order. A line that starts inside one
    /// belongs to its value.
    private(set) var literals: [Range<Int>] = []
    /// False when a string, comment, heredoc, or interpolation doesn't end.
    private(set) var isComplete = true

    init(_ text: String) {
        bytes = Array(text.utf8)
        scan()
    }

    func text(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
    func text(_ token: Token) -> String { text(token.range) }

    /// Whether `token` is the symbol `symbol`.
    func isSymbol(_ token: Token, _ symbol: String) -> Bool {
        token.kind == .symbol && text(token) == symbol
    }

    /// A word token's text in lower case (keywords are case-insensitive), else nil.
    func keyword(_ token: Token) -> String? {
        token.kind == .word ? text(token).lowercased() : nil
    }

    /// Whether `offset` is inside a literal (not at its first byte), so a line starting there
    /// is part of a string's value.
    func isInsideLiteral(_ offset: Int) -> Bool {
        literals.contains { $0.lowerBound < offset && offset < $0.upperBound }
    }

    // MARK: Scanning

    static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0B || byte == 0x0C }
    static func isIdentifierStart(_ byte: UInt8) -> Bool { (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F || byte >= 0x80 }
    static func isIdentifier(_ byte: UInt8) -> Bool { isIdentifierStart(byte) || (byte >= 0x30 && byte <= 0x39) }

    private func has(_ prefix: String, at index: Int) -> Bool {
        let utf8 = Array(prefix.utf8)
        guard index >= 0, index + utf8.count <= bytes.count else { return false }
        for offset in utf8.indices where bytes[index + offset] != utf8[offset] { return false }
        return true
    }

    private func byte(_ index: Int) -> UInt8? { index < bytes.count ? bytes[index] : nil }

    /// `<?php` followed by whitespace or the end, or `<?=`; the tag's length.
    private func openTagLength(at index: Int) -> Int? {
        if has("<?php", at: index), index + 5 == bytes.count || Self.isSpace(bytes[index + 5]) { return 5 }
        if has("<?=", at: index) { return 3 }
        return nil
    }

    private mutating func scan() {
        let count = bytes.count
        var index = 0
        var start = 0
        while start < count, Self.isSpace(bytes[start]) { start += 1 }
        if has("<?php", at: start), start + 5 == count || Self.isSpace(bytes[start + 5]) {
            tokens.append(Token(kind: .openTag, range: start..<start + 5))
            index = start + 5
        }
        var inPHP = true
        while index < count {
            if !inPHP {
                let htmlStart = index
                while index < count, openTagLength(at: index) == nil { index += 1 }
                if index > htmlStart {
                    tokens.append(Token(kind: .inlineHTML, range: htmlStart..<index))
                    literals.append(htmlStart..<index)
                }
                if let length = openTagLength(at: index) {
                    tokens.append(Token(kind: .openTag, range: index..<index + length))
                    index += length
                    inPHP = true
                }
                continue
            }
            let current = bytes[index]
            if Self.isSpace(current) {
                index += 1
                continue
            }
            let next = byte(index + 1)
            switch current {
            case UInt8(ascii: "?") where next == UInt8(ascii: ">"):
                var end = index + 2
                // PHP takes one line break after `?>` with the tag.
                if has("\r\n", at: end) { end += 2 } else if byte(end) == 0x0A { end += 1 }
                tokens.append(Token(kind: .closeTag, range: index..<end))
                index = end
                inPHP = false
            case UInt8(ascii: "#") where next == UInt8(ascii: "["):
                tokens.append(Token(kind: .symbol, range: index..<index + 2))
                index += 2
            case _ where current == UInt8(ascii: "#") || (current == UInt8(ascii: "/") && next == UInt8(ascii: "/")):
                let commentStart = index
                while index < count, bytes[index] != 0x0A, bytes[index] != 0x0D, !has("?>", at: index) { index += 1 }
                comments.append(commentStart..<index)
            case UInt8(ascii: "/") where next == UInt8(ascii: "*"):
                let commentStart = index
                index += 2
                while index < count, !has("*/", at: index) { index += 1 }
                if index < count { index += 2 } else { isComplete = false }
                comments.append(commentStart..<index)
            case UInt8(ascii: "'"):
                let end = endOfSingleQuoted(from: index)
                append(literal: index..<end)
                index = end
            case UInt8(ascii: "\""), UInt8(ascii: "`"):
                let end = endOfInterpolated(from: index, quote: current)
                append(literal: index..<end)
                index = end
            case UInt8(ascii: "<") where has("<<<", at: index):
                if let end = endOfHeredoc(from: index) {
                    append(literal: index..<end)
                    index = end
                } else {
                    tokens.append(Token(kind: .symbol, range: index..<index + 1))
                    index += 1
                }
            case UInt8(ascii: "$") where next.map(Self.isIdentifierStart) ?? false:
                var end = index + 1
                while end < count, Self.isIdentifier(bytes[end]) { end += 1 }
                tokens.append(Token(kind: .variable, range: index..<end))
                index = end
            case UInt8(ascii: "\\") where next.map(Self.isIdentifierStart) ?? false:
                let end = endOfName(from: index + 1)
                tokens.append(Token(kind: .word, range: index..<end))
                index = end
            case _ where Self.isIdentifierStart(current):
                let end = endOfName(from: index)
                tokens.append(Token(kind: .word, range: index..<end))
                index = end
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                var end = index
                while end < count {
                    if Self.isIdentifier(bytes[end]) {
                        end += 1
                    } else if bytes[end] == UInt8(ascii: "."), let after = byte(end + 1), after >= 0x30, after <= 0x39 {
                        end += 1
                    } else {
                        break
                    }
                }
                tokens.append(Token(kind: .number, range: index..<end))
                index = end
            default:
                tokens.append(Token(kind: .symbol, range: index..<index + 1))
                index += 1
            }
        }
    }

    private mutating func append(literal range: Range<Int>) {
        tokens.append(Token(kind: .literal, range: range))
        literals.append(range)
    }

    /// The end of an identifier or a qualified name starting at `start` (`App\Models\User`).
    private func endOfName(from start: Int) -> Int {
        var end = start
        while end < bytes.count {
            if Self.isIdentifier(bytes[end]) {
                end += 1
            } else if bytes[end] == UInt8(ascii: "\\"), let after = byte(end + 1), Self.isIdentifierStart(after) {
                end += 1
            } else {
                break
            }
        }
        return end
    }

    /// Just after a single-quoted string that starts at `start`.
    private mutating func endOfSingleQuoted(from start: Int) -> Int {
        var index = start + 1
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "\\"): index += 2
            case UInt8(ascii: "'"): return index + 1
            default: index += 1
            }
        }
        isComplete = false
        return bytes.count
    }

    /// Just after a double-quoted string or backtick command starting at `start`, through its
    /// interpolations.
    private mutating func endOfInterpolated(from start: Int, quote: UInt8) -> Int {
        var index = start + 1
        while index < bytes.count {
            let current = bytes[index]
            if current == UInt8(ascii: "\\") {
                index += 2
            } else if current == quote {
                return index + 1
            } else if current == UInt8(ascii: "{"), byte(index + 1) == UInt8(ascii: "$") {
                index = endOfBraces(from: index)
            } else if current == UInt8(ascii: "$"), byte(index + 1) == UInt8(ascii: "{") {
                index = endOfBraces(from: index + 1)
            } else {
                index += 1
            }
        }
        isComplete = false
        return bytes.count
    }

    /// Just after the `}` matching the `{` at `open`, inside an interpolation.
    private mutating func endOfBraces(from open: Int) -> Int {
        var depth = 0
        var index = open
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "{"):
                depth += 1
                index += 1
            case UInt8(ascii: "}"):
                depth -= 1
                index += 1
                if depth == 0 { return index }
            case UInt8(ascii: "'"):
                index = endOfSingleQuoted(from: index)
            case UInt8(ascii: "\""), UInt8(ascii: "`"):
                index = endOfInterpolated(from: index, quote: bytes[index])
            default:
                index += 1
            }
        }
        isComplete = false
        return bytes.count
    }

    /// Just after a heredoc's or nowdoc's closing identifier, or nil when `<<<` at `start`
    /// doesn't open one. The closing identifier starts a line (after optional indentation)
    /// and is not followed by another identifier character (PHP 7.3's flexible syntax).
    private mutating func endOfHeredoc(from start: Int) -> Int? {
        var index = start + 3
        while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 { index += 1 }
        let quote = byte(index).flatMap { $0 == UInt8(ascii: "'") || $0 == UInt8(ascii: "\"") ? $0 : nil }
        if quote != nil { index += 1 }
        let nameStart = index
        guard index < bytes.count, Self.isIdentifierStart(bytes[index]) else { return nil }
        while index < bytes.count, Self.isIdentifier(bytes[index]) { index += 1 }
        let name = Array(bytes[nameStart..<index])
        if let quote {
            guard byte(index) == quote else { return nil }
            index += 1
        }
        if has("\r\n", at: index) { index += 2 } else if byte(index) == 0x0A { index += 1 } else { return nil }
        let nowdoc = quote == UInt8(ascii: "'")
        var atLineStart = true
        while index < bytes.count {
            if atLineStart {
                atLineStart = false
                var cursor = index
                while cursor < bytes.count, bytes[cursor] == 0x20 || bytes[cursor] == 0x09 { cursor += 1 }
                if cursor + name.count <= bytes.count, Array(bytes[cursor..<cursor + name.count]) == name,
                   cursor + name.count == bytes.count || !Self.isIdentifier(bytes[cursor + name.count]) {
                    return cursor + name.count
                }
            }
            let current = bytes[index]
            if current == 0x0A {
                atLineStart = true
                index += 1
            } else if !nowdoc, current == UInt8(ascii: "\\"), byte(index + 1) != 0x0A {
                index += 2
            } else if !nowdoc, current == UInt8(ascii: "{"), byte(index + 1) == UInt8(ascii: "$") {
                index = endOfBraces(from: index)
            } else if !nowdoc, current == UInt8(ascii: "$"), byte(index + 1) == UInt8(ascii: "{") {
                index = endOfBraces(from: index + 1)
            } else {
                index += 1
            }
        }
        isComplete = false
        return bytes.count
    }
}

extension PHPCodeScan {
    /// One top-level statement: its tokens (indices into `tokens`) and how it ended.
    struct Statement: Equatable {
        enum End: Equatable {
            /// `;` (the last token).
            case semicolon
            /// The `}` closing a block statement (the last token).
            case brace
            /// Right before `?>`, which ends a statement like `;`.
            case closeTag
            /// The code ended without a terminator (Runlet accepts a missing final `;`).
            case none
            /// An opening or closing tag, or inline HTML.
            case markup
        }

        var tokens: Range<Int>
        var end: End
    }

    /// Statement keywords that start a block a `}` can end (with `else`, `elseif`, `catch`,
    /// and `finally` continuing it).
    private static let blockKeywords: Set<String> = [
        "if", "elseif", "else", "for", "foreach", "while", "switch", "try", "catch", "finally",
        "declare", "namespace", "class", "interface", "trait", "abstract", "final", "readonly",
    ]

    /// The index of the first token after any attribute groups (`#[…]`) from `index`.
    func skippingAttributes(_ index: Int) -> Int {
        var index = index
        while index < tokens.count, isSymbol(tokens[index], "#[") {
            var depth = 0
            while index < tokens.count {
                let token = tokens[index]
                if isSymbol(token, "#[") || isSymbol(token, "[") { depth += 1 }
                if isSymbol(token, "]") { depth -= 1 }
                index += 1
                if depth == 0 { break }
            }
        }
        return index
    }

    /// Whether a statement starting at `index` is a block a closing `}` ends, and whether it
    /// is a `do … while (…);`, which only `;` ends.
    private func blockKind(at index: Int) -> (block: Bool, isDo: Bool) {
        let first = skippingAttributes(index)
        guard first < tokens.count else { return (false, false) }
        let token = tokens[first]
        if isSymbol(token, "{") { return (true, false) }
        guard let word = keyword(token) else { return (false, false) }
        if word == "do" { return (false, true) }
        if Self.blockKeywords.contains(word) { return (true, false) }
        let next = first + 1 < tokens.count ? tokens[first + 1] : nil
        switch word {
        case "enum":
            return (next?.kind == .word, false)
        case "function":
            // A declaration (`function name(`), not a closure (`function (`).
            guard let next else { return (false, false) }
            if next.kind == .word { return (true, false) }
            if isSymbol(next, "&"), first + 2 < tokens.count, tokens[first + 2].kind == .word { return (true, false) }
            return (false, false)
        default:
            return (false, false)
        }
    }

    /// The top-level statements, in order, from token `start` (after the opening tag).
    func statements(from start: Int = 0) -> [Statement] {
        var statements: [Statement] = []
        var index = start
        while index < tokens.count {
            let first = tokens[index]
            if first.kind == .openTag || first.kind == .closeTag || first.kind == .inlineHTML {
                statements.append(Statement(tokens: index..<index + 1, end: .markup))
                index += 1
                continue
            }
            let (block, isDo) = blockKind(at: index)
            var depth = 0
            var cursor = index
            var finished: Statement?
            while cursor < tokens.count {
                let token = tokens[cursor]
                if token.kind == .closeTag, depth <= 0 {
                    finished = Statement(tokens: index..<cursor, end: .closeTag)
                    break
                }
                if token.kind == .symbol {
                    switch text(token) {
                    case "(", "[", "{", "#[":
                        depth += 1
                    case ")", "]":
                        depth = max(0, depth - 1)
                    case "}":
                        depth = max(0, depth - 1)
                        if depth == 0, block, !isDo {
                            let next = cursor + 1 < tokens.count ? keyword(tokens[cursor + 1]) : nil
                            if !["else", "elseif", "catch", "finally"].contains(next ?? "") {
                                finished = Statement(tokens: index..<cursor + 1, end: .brace)
                            }
                        }
                    case ";" where depth == 0:
                        finished = Statement(tokens: index..<cursor + 1, end: .semicolon)
                    default:
                        break
                    }
                }
                if finished != nil { break }
                cursor += 1
            }
            let statement = finished ?? Statement(tokens: index..<tokens.count, end: .none)
            statements.append(statement)
            index = statement.tokens.upperBound
        }
        return statements
    }

    /// The statement's bytes, from its first token through its last (with its terminator).
    func range(of statement: Statement) -> Range<Int> {
        tokens[statement.tokens.lowerBound].range.lowerBound..<tokens[statement.tokens.upperBound - 1].range.upperBound
    }

    /// The tokens of a statement without its `;` (or `}`) terminator.
    func body(of statement: Statement) -> Range<Int> {
        statement.end == .semicolon ? statement.tokens.lowerBound..<statement.tokens.upperBound - 1 : statement.tokens
    }

    /// Words that start a statement which has no value as a result: declarations, control
    /// structures, `echo`, `return`, `exit`, … (`static` only before a variable, `function`
    /// and `enum` only before a name).
    private static let statementKeywords: Set<String> = [
        "abstract", "break", "case", "class", "const", "continue", "declare", "default", "die", "do",
        "echo", "else", "elseif", "enddeclare", "endfor", "endforeach", "endif", "endswitch", "endwhile",
        "exit", "final", "for", "foreach", "global", "goto", "if", "include", "include_once", "interface",
        "namespace", "print", "readonly", "require", "require_once", "return", "switch", "throw", "trait",
        "try", "unset", "use", "while", "__halt_compiler",
    ]

    /// Whether the statement is an expression statement (its value is a snippet's result when
    /// it comes last), as opposed to a declaration, a control structure, or markup.
    func isExpressionStatement(_ statement: Statement) -> Bool {
        guard statement.end != .markup, statement.end != .brace else { return false }
        let first = statement.tokens.lowerBound
        guard first < statement.tokens.upperBound else { return false }
        let token = tokens[first]
        if token.kind == .symbol { return !(isSymbol(token, "{") || isSymbol(token, "#[") || isSymbol(token, ";")) }
        guard let word = keyword(token) else { return true }
        let next = first + 1 < statement.tokens.upperBound ? tokens[first + 1] : nil
        if Self.statementKeywords.contains(word) { return false }
        switch word {
        case "static":
            return next?.kind != .variable
        case "enum":
            return next?.kind != .word
        case "function":
            // A closure, not a declaration (`function name(` or `function &name(`).
            guard let next else { return true }
            if next.kind == .word { return false }
            if isSymbol(next, "&"), first + 2 < statement.tokens.upperBound, tokens[first + 2].kind == .word { return false }
            return true
        default:
            // A label (`retry:`), not a static call (`Foo::bar()`).
            if let next, isSymbol(next, ":") {
                let after = first + 2 < statement.tokens.upperBound ? tokens[first + 2] : nil
                if after.map({ isSymbol($0, ":") && $0.range.lowerBound == next.range.upperBound }) != true { return false }
            }
            return true
        }
    }

    /// Whether the statement declares a named function, a class, an interface, a trait, an
    /// enum, or a constant (`const X = 1;`). In a snippet these are declared before its code
    /// runs; inside a method they would be declared only when reached (and `const` not at all).
    func isDeclaration(_ statement: Statement) -> Bool {
        let first = skippingAttributes(statement.tokens.lowerBound)
        guard first < statement.tokens.upperBound, let word = keyword(tokens[first]) else { return false }
        let next = first + 1 < statement.tokens.upperBound ? tokens[first + 1] : nil
        switch word {
        case "class", "interface", "trait", "abstract", "final", "readonly":
            return statement.end == .brace
        case "const":
            return statement.end == .semicolon
        case "enum":
            return statement.end == .brace && next?.kind == .word
        case "function":
            guard statement.end == .brace, let next else { return false }
            return next.kind == .word || (isSymbol(next, "&") && first + 2 < statement.tokens.upperBound && tokens[first + 2].kind == .word)
        default:
            return false
        }
    }

    /// The assignment operators a statement can start with after a variable.
    private static let assignmentOperators: Set<String> = ["=", "+=", "-=", "*=", "/=", ".=", "%=", "**=", "??=", "|=", "&=", "^=", "<<=", ">>="]

    /// The variable a statement assigns to when it is `$name <op> …` (any assignment
    /// operator, also `=&`), else nil.
    func assignedVariable(_ statement: Statement) -> String? {
        let first = statement.tokens.lowerBound
        guard statement.tokens.count >= 3, tokens[first].kind == .variable else { return nil }
        // The symbols right after the variable, adjacent to each other: `= -1` gives "=",
        // `=== 1` gives "===".
        var symbols = ""
        var end = -1
        var cursor = first + 1
        while cursor < statement.tokens.upperBound, tokens[cursor].kind == .symbol {
            let token = tokens[cursor]
            if end >= 0, token.range.lowerBound != end { break }
            symbols += text(token)
            end = token.range.upperBound
            cursor += 1
        }
        // The longest assignment operator they start with, not followed by `=` or `>`
        // (`==`, `=>`).
        guard let op = Self.assignmentOperators.filter({ symbols.hasPrefix($0) }).max(by: { $0.count < $1.count }) else { return nil }
        let after = symbols.dropFirst(op.count).first
        return after == "=" || after == ">" ? nil : text(tokens[first])
    }
}
