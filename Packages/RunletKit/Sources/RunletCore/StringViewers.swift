import Foundation

/// Swift-side recognition for #7. Never reads files, resolves URLs, or runs PHP.
public struct StringViewers: Sendable {
    public static let byteLimit = 65_536
    public enum ImageKind: String, Sendable { case png, jpeg, svg }
    public struct ImagePayload: Sendable {
        public let kind: ImageKind
        public let data: Data
    }
    public let text: String
    public let isLong: Bool
    public let jsonTree: ValueNode?
    public let prettyJSON: String?
    public let html: String?
    public let image: ImagePayload?

    public init?(node: ValueNode) {
        guard node.type == .string, let scalar = node.scalar,
              scalar.utf8.count <= (node.encoding == "base64" ? 87_384 : Self.byteLimit) else { return nil }
        let bytes = node.encoding == "base64" ? Data(base64Encoded: scalar) : Data(scalar.utf8)
        guard let bytes, bytes.count <= Self.byteLimit else { return nil }
        text = node.encoding == "base64" ? node.displayString : scalar
        isLong = text.utf8.count >= 1_000 || text.filter { $0 == "\n" }.count >= 10
        // Incomplete values stay readable, but must not masquerade as complete documents.
        let complete = node.truncation == nil && node.budgetExceeded != true
        var trimmed = scalar.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\u{FEFF}") { trimmed.removeFirst(); trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines) }
        if complete, node.encoding != "base64", Self.boundedJSON(trimmed), (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])) != nil {
            prettyJSON = Self.pretty(trimmed)
            var parser = JSONTreeParser(bytes: Array(trimmed.utf8))
            jsonTree = parser.value()
        } else { jsonTree = nil; prettyJSON = nil }
        html = complete && node.encoding != "base64" && Self.looksLikeHTML(trimmed) ? scalar : nil
        image = complete ? Self.image(bytes: bytes, text: node.encoding == "base64" ? nil : trimmed) : nil
    }

    // Preflight before a recursive parser: at most 32 levels and ~2,048 values.
    static func boundedJSON(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        var depth = 0, tokens = 1
        var quoted = false, escaped = false
        for byte in text.utf8 {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 { depth += 1; tokens += 1 }
            else if byte == 125 || byte == 93 { depth -= 1 }
            else if byte == 44 { tokens += 1 }
            if depth > 32 || tokens > 2_048 { return false }
        }
        return true
    }

    // Format the validated source, keeping large numbers and decimal precision intact.
    static func pretty(_ text: String) -> String {
        var output = "", depth = 0, quoted = false, escaped = false
        let characters = Array(text)
        func newline() -> String { "\n" + String(repeating: "  ", count: max(0, depth)) }
        for (index, character) in characters.enumerated() {
            if quoted {
                output.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else {
                switch character {
                case "\"": quoted = true; output.append(character)
                case "{", "[":
                    output.append(character); depth += 1
                    let next = characters[(index + 1)...].first { !$0.isWhitespace }
                    if next != "}" && next != "]" { output += newline() }
                case "}", "]":
                    depth -= 1
                    if output.last != "{" && output.last != "[" { output += newline() }
                    output.append(character)
                case ",": output += "," + newline()
                case ":": output += ": "
                default: if !character.isWhitespace { output.append(character) }
                }
            }
        }
        return output
    }

    /// Walk already validated JSON, retaining number literals rather than converting to Double.
    /// Keeping the original member order also preserves duplicate keys in the viewer.
    private struct JSONTreeParser {
        let bytes: [UInt8]
        var offset = 0
        var id = 0

        mutating func whitespace() {
            while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
        }

        mutating func string() -> String {
            let start = offset
            offset += 1
            var escaped = false
            while offset < bytes.count {
                let byte = bytes[offset]
                offset += 1
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { break }
            }
            return (try? JSONDecoder().decode(String.self, from: Data(bytes[start..<offset]))) ?? ""
        }

        mutating func value() -> ValueNode {
            whitespace()
            id += 1
            let current = id
            let byte = bytes[offset]
            if byte == 34 { return ValueNode(id: current, type: .string, scalar: string()) }
            if byte == 123 || byte == 91 {
                let object = byte == 123, close: UInt8 = object ? 125 : 93
                offset += 1
                whitespace()
                var entries: [ValueNode.Entry] = []
                var count = 0
                while bytes[offset] != close {
                    var key = String(count)
                    if object {
                        key = string()
                        whitespace()
                        offset += 1 // colon, checked by JSONSerialization
                    }
                    let child = value()
                    if count < 200 { entries.append(.init(key: key, keyType: object ? "property" : "int", value: child)) }
                    count += 1
                    whitespace()
                    if bytes[offset] == 44 { offset += 1; whitespace() }
                }
                offset += 1
                var node = ValueNode(id: current, type: object ? .object : .array, className: object ? "JSON object" : nil, entries: entries)
                node.count = count
                if count > 200 { node.truncation = .init(reason: "children", omitted: count - 200) }
                return node
            }
            let start = offset
            while offset < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[offset]) { offset += 1 }
            let literal = String(decoding: bytes[start..<offset], as: UTF8.self)
            let type: ValueNode.Kind = literal == "null" ? .null : ["true", "false"].contains(literal) ? .bool : literal.contains(where: { ".eE".contains($0) }) ? .float : .int
            return ValueNode(id: current, type: type, scalar: literal)
        }
    }

    static func looksLikeHTML(_ text: String) -> Bool {
        text.range(of: #"^<(?:!doctype\s+html|html|head|body|div|span|p|h[1-6]|table|ul|ol|li|a|img|section|article|style|pre|br)(?:\s|>|/)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func image(bytes: Data, text: String?) -> ImagePayload? {
        var data = bytes
        if let text {
            var encoded = text
            if text.lowercased().hasPrefix("data:") {
                guard let comma = text.firstIndex(of: ","),
                      ["data:image/png;base64", "data:image/jpeg;base64", "data:image/svg+xml;base64"].contains(String(text[..<comma]).lowercased()) else { return nil }
                encoded = String(text[text.index(after: comma)...])
            }
            let compact = encoded.filter { !$0.isWhitespace }
            if let decoded = Data(base64Encoded: compact), !decoded.isEmpty { data = decoded }
        }
        guard data.count <= byteLimit else { return nil }
        if data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { return ImagePayload(kind: .png, data: data) }
        if data.starts(with: [255, 216, 255]) { return ImagePayload(kind: .jpeg, data: data) }
        if let svg = String(data: data, encoding: .utf8), svg.range(of: #"^\s*(?:<\?xml[^>]*>\s*)?<svg(?:\s|>)"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return ImagePayload(kind: .svg, data: data)
        }
        return nil
    }
}

/// Literal, case-insensitive UTF-16 ranges, suitable for NSTextView selection.
public enum StringSearch {
    public static func matches(in text: String, query: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let source = text as NSString
        var results: [NSRange] = [], offset = 0
        while offset < source.length {
            let range = source.range(of: query, options: .caseInsensitive, range: NSRange(location: offset, length: source.length - offset))
            guard range.location != NSNotFound else { break }
            results.append(range)
            offset = NSMaxRange(range)
        }
        return results
    }
}
