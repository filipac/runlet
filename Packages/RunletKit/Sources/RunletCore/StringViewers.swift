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
    public let json: MCPJSON?
    public let jsonTree: ValueNode?
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
        let trimmed = scalar.trimmingCharacters(in: .whitespacesAndNewlines)
        if complete, node.encoding != "base64", Self.boundedJSON(trimmed), let parsed = try? MCPJSON.parse(trimmed) {
            json = parsed
            var id = 0
            jsonTree = Self.tree(parsed, id: &id)
        } else { json = nil; jsonTree = nil }
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

    static func tree(_ json: MCPJSON, id: inout Int) -> ValueNode {
        id += 1
        let current = id
        switch json {
        case .null: return ValueNode(id: current, type: .null)
        case .bool(let value): return ValueNode(id: current, type: .bool, scalar: value ? "true" : "false")
        case .int(let value): return ValueNode(id: current, type: .int, scalar: String(value))
        case .double(let value): return ValueNode(id: current, type: .float, scalar: String(value))
        case .string(let value): return ValueNode(id: current, type: .string, scalar: value)
        case .array(let values):
            var node = ValueNode(id: current, type: .array, entries: values.enumerated().map {
                ValueNode.Entry(key: String($0.offset), keyType: "int", value: tree($0.element, id: &id))
            })
            node.count = values.count
            return node
        case .object(let values):
            var node = ValueNode(id: current, type: .object, className: "JSON object", entries: values.keys.sorted().map {
                ValueNode.Entry(key: $0, keyType: "property", value: tree(values[$0]!, id: &id))
            })
            node.count = values.count
            return node
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
            if let decoded = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), !decoded.isEmpty { data = decoded }
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
