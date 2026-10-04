import Foundation

/// Redis snippets (#205): `.runlet/snippets/*.redis` project files and personal snippets of
/// Redis tabs. The leading block of `#` lines is `DatabaseSnippetHeader`'s (`# @title`,
/// `# @description`, `# @connection`, `# @input`), as `.mongodb` files have it after `//`; then
/// Redis commands, one per line, as a Redis tab reads them (`RedisScript`).
///
/// ```
/// # @title Inspect a user's session
/// # @description The session hash and how long it lives
/// # @connection cache
/// # @input string $user "User id" = "42"
///
/// HGETALL session:$user
/// TTL session:$user
/// ```
///
/// Inputs fill placeholders in the commands' unquoted arguments: `$name`, or `${name}` when a
/// letter, digit, or `_` follows it (`${user}_lock`). The whole argument that holds a
/// placeholder is rebuilt with the value and written back as one quoted Redis argument
/// (`RedisScript.quoted`), so a value with spaces, quotes, or line breaks stays one argument
/// and is never spliced into the line as text. A placeholder inside quotes (`'$user'`,
/// `"$user"`) stays text, as does one whose name isn't an input; comment lines and lines Runlet
/// can't read are left as written. Opening a snippet never runs it.
public enum RedisSnippets {
    /// The comment marker of `.redis` files (`DatabaseSnippetHeader.marker(for: .redis)`).
    public static let marker = "#"

    /// A snippet's inputs and the commands without the metadata block.
    public static func parse(_ code: String) -> (inputs: SnippetInputSet, body: String, header: DatabaseSnippetHeader?) {
        let (header, body) = DatabaseSnippetHeader.split(Substring(code), marker: marker)
        let inputs = header.map { SnippetInputs.parse(declarations: $0.inputs) } ?? .none
        return (inputs, tidy(body), header)
    }

    /// The code of a personal copy (or a saved file): the header's lines, a blank line, the commands.
    public static func code(header: DatabaseSnippetHeader, body: String) -> String {
        let lines = header.lines(marker: marker)
        let body = tidy(Substring(body))
        return lines.isEmpty ? body : lines.joined(separator: "\n") + "\n\n" + body
    }

    /// The value as the bytes of one Redis argument, before quoting: a string as is, a number
    /// as Redis reads numbers (`42`, `2.5`, `+inf`), a bool as `1` or `0`.
    public static func argumentText(_ value: SnippetInputValue) -> String {
        switch value {
        case .string(let string): return string
        case .int(let number): return String(number)
        case .bool(let flag): return flag ? "1" : "0"
        case .float(let number):
            if number.isNaN { return "nan" }
            if number.isInfinite { return number < 0 ? "-inf" : "+inf" }
            return "\(number)"
        }
    }

    /// The value as one argument of a command line: bare when it can be, else double-quoted
    /// with redis-cli's escapes (`"two words"`, `"a\nb"`, `""`).
    public static func quotedArgument(_ value: SnippetInputValue) -> String {
        RedisScript.quoted(argumentText(value))
    }

    /// `text` with each placeholder of an input in `values` filled (see the type's notes).
    /// Arguments without a placeholder keep their spelling; so do comment lines and lines that
    /// don't parse (an unclosed quote), which a run refuses anyway.
    public static func substitute(_ text: String, values: [String: SnippetInputValue]) -> String {
        guard !values.isEmpty, text.contains("$") else { return text }
        let replacements = values.mapValues { Array(argumentText($0).utf8) }
        let bytes = Array(text.utf8)
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var start = 0
        while start < bytes.count {
            var end = start
            while end < bytes.count, bytes[end] != 10, bytes[end] != 13 { end += 1 }
            let line = Array(bytes[start..<end])
            result += substituteLine(line, values: replacements) ?? line
            // The line break (`\n`, `\r`, or `\r\n`) as written.
            if end < bytes.count {
                result.append(bytes[end])
                if bytes[end] == 13, end + 1 < bytes.count, bytes[end + 1] == 10 {
                    end += 1
                    result.append(10)
                }
                end += 1
            }
            start = end
        }
        return String(decoding: result, as: UTF8.self)
    }

    /// One line with its placeholders filled, or nil when it's a comment, has none, or
    /// doesn't parse. Lexes arguments exactly as `RedisScript.parse` does.
    private static func substituteLine(_ bytes: [UInt8], values: [String: [UInt8]]) -> [UInt8]? {
        let end = bytes.count
        func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 11 || c == 12 || c == 0 }
        func hex(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: c - 48
            case 65...70: c - 55
            case 97...102: c - 87
            default: nil
            }
        }
        guard let first = bytes.firstIndex(where: { $0 != 32 && $0 != 9 }), bytes[first] != 35, bytes.contains(36) else { return nil }
        var output: [UInt8] = []
        var copied = 0
        var changed = false
        var p = 0
        var isFirst = true
        while true {
            while p < end, isSpace(bytes[p]) { p += 1 }
            if p >= end { break }
            let argumentStart = p
            var argument: [UInt8] = []
            var filled = false
            lexing: while p < end {
                let c = bytes[p]
                if isSpace(c) { break }
                if c == 34 || c == 39 {
                    // A quoted part ends the argument: its text is never a placeholder.
                    p += 1
                    var closed = false
                    while p < end {
                        let d = bytes[p]
                        if c == 34, d == 92, p + 3 < end, bytes[p + 1] == 120, let high = hex(bytes[p + 2]), let low = hex(bytes[p + 3]) {
                            argument.append(high << 4 | low)
                            p += 4
                        } else if c == 34, d == 92, p + 1 < end {
                            switch bytes[p + 1] {
                            case 110: argument.append(10)
                            case 114: argument.append(13)
                            case 116: argument.append(9)
                            case 98: argument.append(8)
                            case 97: argument.append(7)
                            default: argument.append(bytes[p + 1])
                            }
                            p += 2
                        } else if c == 39, d == 92, p + 1 < end, bytes[p + 1] == 39 {
                            argument.append(39)
                            p += 2
                        } else if d == c {
                            p += 1
                            closed = true
                            break
                        } else {
                            argument.append(d)
                            p += 1
                        }
                    }
                    guard closed, p >= end || isSpace(bytes[p]) else { return nil }
                    break lexing
                }
                if c == 36, let (name, length) = placeholder(in: bytes, at: p), let value = values[name] {
                    argument += value
                    p += length
                    filled = true
                    continue
                }
                argument.append(c)
                p += 1
            }
            if filled {
                var text = RedisScript.quoted(argument)
                // A line whose first word starts with `#` is a comment: quote it (bare means it needs no escapes).
                if isFirst, text.hasPrefix("#") { text = "\"" + text + "\"" }
                output += bytes[copied..<argumentStart]
                output += Array(text.utf8)
                copied = p
                changed = true
            }
            isFirst = false
        }
        guard changed else { return nil }
        return output + bytes[copied...]
    }

    /// `$name` or `${name}` at `index`: the name and the placeholder's length in bytes. A name
    /// is a PHP variable's (`SnippetInputs.isValidVariableName`); `$name` takes the longest one.
    private static func placeholder(in bytes: [UInt8], at index: Int) -> (name: String, length: Int)? {
        func isStart(_ c: UInt8) -> Bool { (65...90).contains(c) || (97...122).contains(c) || c == 95 || c >= 0x80 }
        func isPart(_ c: UInt8) -> Bool { isStart(c) || (48...57).contains(c) }
        var p = index + 1
        guard p < bytes.count else { return nil }
        if bytes[p] == 123 { // ${name}
            p += 1
            let nameStart = p
            while p < bytes.count, isPart(bytes[p]) { p += 1 }
            guard p < bytes.count, bytes[p] == 125, p > nameStart, isStart(bytes[nameStart]) else { return nil }
            return (String(decoding: bytes[nameStart..<p], as: UTF8.self), p + 1 - index)
        }
        guard isStart(bytes[p]) else { return nil }
        while p < bytes.count, isPart(bytes[p]) { p += 1 }
        return (String(decoding: bytes[(index + 1)..<p], as: UTF8.self), p - index)
    }

    private static func tidy(_ text: Substring) -> String {
        var text = text.drop { $0.isNewline || $0 == " " || $0 == "\t" }
        while let last = text.last, last.isWhitespace { text = text.dropLast() }
        return String(text)
    }
}
