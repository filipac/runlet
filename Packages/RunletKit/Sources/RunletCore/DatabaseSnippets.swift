import Foundation

/// The metadata of database snippet files whose language has line comments (#207): the leading
/// block of comment lines of a `.runlet/snippets/*.mongodb` file (`//`), and of `.redis` files
/// (`#`, #205: `RedisSnippets`) with the same keys. Nothing here runs anything.
///
/// ```
/// // @title Paid orders of a customer
/// // @description The newest first
/// // @connection Documents (saved)
/// // @input string $customer "Customer" = "c-1001"
/// // @input int $limit "How many" = 20
///
/// { "collection": "orders", "operation": "find",
///   "filter": { "customer": { "$input": "customer" }, "status": "paid" },
///   "sort": { "placed_at": -1, "_id": 1 }, "limit": { "$input": "limit" } }
/// ```
///
/// The block is the first run of comment lines (blank lines before it are skipped; a blank or
/// other line ends it). It counts as metadata only when it has `@title` (or `@label`, as PHP
/// and SQL snippets call it), `@description`, `@connection`, or `@input`; then it isn't part
/// of the code. `@title` and `@description` continue on following comment lines without a tag.
/// `@connection` names the connection as SQL snippets do (#149: a bare name, or `Name (saved)`).
/// `@input` lines are PHP snippets' declarations (#14): `<type> $<name> ["Label"] [= default]
/// [{choice, …}]`.
public struct DatabaseSnippetHeader: Sendable, Equatable {
    public var title: String?
    public var description: String?
    public var connection: String?
    /// The text after each `@input`.
    public var inputs: [String]

    public init(title: String? = nil, description: String? = nil, connection: String? = nil, inputs: [String] = []) {
        self.title = title
        self.description = description
        self.connection = connection
        self.inputs = inputs
    }

    /// The comment marker of a language's snippet files: `//` for MongoDB, `#` for Redis; nil for
    /// the languages whose metadata is a docblock or `--` lines.
    public static func marker(for language: TabLanguage) -> String? {
        switch language {
        case .mongodb: "//"
        case .redis: "#"
        default: nil
        }
    }

    /// The leading metadata block of `text` and the text after it. Without a metadata block the
    /// header is nil and the body is `text` itself.
    public static func split(_ text: Substring, marker: String) -> (header: DatabaseSnippetHeader?, body: Substring) {
        var text = text
        if text.first == "\u{FEFF}" { text = text.dropFirst() }
        var index = text.startIndex
        // Skip blank lines before the block.
        while index < text.endIndex {
            let lineEnd = text[index...].firstIndex(where: \.isNewline) ?? text.endIndex
            guard text[index..<lineEnd].allSatisfy(\.isWhitespace), lineEnd < text.endIndex else { break }
            index = text.index(after: lineEnd)
        }
        var lines: [Substring] = []
        var end = index
        var cursor = index
        while cursor < text.endIndex {
            let lineEnd = text[cursor...].firstIndex(where: \.isNewline) ?? text.endIndex
            let line = text[cursor..<lineEnd].drop { $0 == " " || $0 == "\t" }
            guard line.hasPrefix(marker) else { break }
            lines.append(line.dropFirst(marker.count))
            cursor = lineEnd < text.endIndex ? text.index(after: lineEnd) : lineEnd
            end = cursor
        }
        guard !lines.isEmpty, let header = parse(lines) else { return (nil, text) }
        return (header, text[end...])
    }

    private enum Tag { case title, description }

    private static func parse(_ lines: [Substring]) -> DatabaseSnippetHeader? {
        var header = DatabaseSnippetHeader()
        var tagged = false
        var current: Tag?
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { current = nil; continue }
            guard line.hasPrefix("@") else {
                switch current {
                case .title: header.title = (header.title ?? "") + " " + line
                case .description: header.description = (header.description ?? "") + " " + line
                case nil: break
                }
                continue
            }
            let name = line.prefix { !$0.isWhitespace }
            let value = line.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
            current = nil
            switch name.lowercased() {
            case "@title", "@label":
                header.title = value
                current = .title
                tagged = true
            case "@description":
                header.description = value
                current = .description
                tagged = true
            case "@connection":
                header.connection = value.isEmpty ? nil : value
                tagged = true
            case "@input":
                header.inputs.append(value)
                tagged = true
            default:
                break
            }
        }
        guard tagged else { return nil }
        header.title = header.title.flatMap { $0.isEmpty ? nil : $0 }
        header.description = header.description.flatMap { $0.isEmpty ? nil : $0 }
        return header
    }

    /// The block's lines, as `split` reads them back: `// @title …`, `// @description …`,
    /// `// @connection …`, then one `// @input …` per input. Values are on one line each.
    public func lines(marker: String) -> [String] {
        func oneLine(_ value: String?) -> String? {
            let text = (value ?? "").split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        var lines: [String] = []
        if let title = oneLine(title) { lines.append("\(marker) @title \(title)") }
        if let description = oneLine(description) { lines.append("\(marker) @description \(description)") }
        if let connection = oneLine(connection) { lines.append("\(marker) @connection \(connection)") }
        for input in inputs { if let input = oneLine(input) { lines.append("\(marker) @input \(input)") } }
        return lines
    }
}

/// MongoDB snippets (#207): the header above, then one JSON query. Inputs fill placeholders
/// written as `{"$input": "name"}` anywhere a JSON value can be: each becomes the value as a JSON
/// literal (a string quoted and escaped, a number, true or false). The query's text and key order
/// stay as written; placeholders inside strings are left alone. Opening a snippet never runs it.
public enum MongoSnippets {
    /// A snippet's inputs and the query without its header.
    public static func parse(_ code: String) -> (inputs: SnippetInputSet, body: String, header: DatabaseSnippetHeader?) {
        let (header, body) = DatabaseSnippetHeader.split(Substring(code), marker: "//")
        let inputs = header.map { SnippetInputs.parse(declarations: $0.inputs) } ?? .none
        return (inputs, tidy(body), header)
    }

    /// `json` with each placeholder of an input in `values` replaced by its value. A placeholder
    /// without a value stays (the server refuses `$input` if it runs).
    public static func substitute(_ json: String, values: [String: SnippetInputValue]) -> String {
        guard !values.isEmpty else { return json }
        let text = json as NSString
        let pattern = try! NSRegularExpression(pattern: #"\{\s*"\$input"\s*:\s*"([A-Za-z_][A-Za-z0-9_]*)"\s*\}"#)
        var result = ""
        var inString = false
        var escaped = false
        var copied = 0
        var index = 0
        while index < text.length {
            let character = text.character(at: index)
            if inString {
                if escaped { escaped = false } else if character == 92 { escaped = true } else if character == 34 { inString = false }
                index += 1
                continue
            }
            if character == 34 { inString = true; index += 1; continue }
            if character == 123, let match = pattern.firstMatch(in: json, options: .anchored, range: NSRange(location: index, length: text.length - index)),
               let value = values[text.substring(with: match.range(at: 1))] {
                result += text.substring(with: NSRange(location: copied, length: index - copied)) + jsonLiteral(value)
                index = NSMaxRange(match.range)
                copied = index
                continue
            }
            index += 1
        }
        return result + text.substring(from: copied)
    }

    /// The value as one JSON literal.
    public static func jsonLiteral(_ value: SnippetInputValue) -> String {
        switch value {
        case .int(let number): return String(number)
        case .float(let number):
            guard number.isFinite else { return "null" }
            return number == number.rounded() && abs(number) < 1e15 ? String(format: "%.1f", number) : "\(number)"
        case .bool(let flag): return flag ? "true" : "false"
        case .string(let string):
            let data = (try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("\"\"".utf8)
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// The code of a personal copy (or a saved file): the header's lines, a blank line, the query.
    public static func code(header: DatabaseSnippetHeader, body: String) -> String {
        let lines = header.lines(marker: "//")
        let body = tidy(Substring(body))
        return lines.isEmpty ? body : lines.joined(separator: "\n") + "\n\n" + body
    }

    private static func tidy(_ text: Substring) -> String {
        var text = text.drop { $0.isNewline || $0 == " " || $0 == "\t" }
        while let last = text.last, last.isWhitespace { text = text.dropLast() }
        return String(text)
    }
}
