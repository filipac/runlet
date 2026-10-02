import Foundation

/// Minimal JSON value used for loosely typed LSP payloads.
public enum JSONValue: Sendable, Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: try JSONEncoder().encode(self))
    }

    public static func from<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(value))
    }
}

public struct LSPPosition: Sendable, Codable, Hashable, Comparable {
    public var line: Int
    /// UTF-16 code units (the LSP default, matching NSString/NSTextView offsets).
    public var character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }

    public static func < (lhs: LSPPosition, rhs: LSPPosition) -> Bool {
        (lhs.line, lhs.character) < (rhs.line, rhs.character)
    }
}

public struct LSPRange: Sendable, Codable, Hashable {
    public var start: LSPPosition
    public var end: LSPPosition

    public init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }
}

public struct LSPTextEdit: Sendable, Codable, Hashable {
    public var range: LSPRange
    public var newText: String

    public init(range: LSPRange, newText: String) {
        self.range = range
        self.newText = newText
    }
}

public struct LSPDiagnostic: Sendable, Codable, Hashable {
    public var range: LSPRange
    /// 1 error, 2 warning, 3 information, 4 hint.
    public var severity: Int?
    public var code: JSONValue?
    public var source: String?
    public var message: String

    public var codeString: String? {
        switch code {
        case .string(let value): value
        case .number(let value): String(Int(value))
        default: nil
        }
    }
}

extension JSONValue: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null: hasher.combine(0)
        case .bool(let v): hasher.combine(v)
        case .number(let v): hasher.combine(v)
        case .string(let v): hasher.combine(v)
        case .array(let v): hasher.combine(v)
        case .object(let v): hasher.combine(v.keys.sorted())
        }
    }
}

public struct CompletionItem: Sendable, Hashable, Identifiable {
    public var id: Int
    public var label: String
    public var kind: Int?
    public var detail: String?
    public var documentation: String?
    public var sortText: String?
    public var filterText: String?
    public var insertText: String?
    /// 2 = snippet syntax.
    public var insertTextFormat: Int?
    public var textEdit: LSPTextEdit?
    public var additionalTextEdits: [LSPTextEdit]
    public var deprecated: Bool
    /// Raw item, used for completionItem/resolve.
    public var raw: JSONValue

    public var kindName: String {
        switch kind {
        case 2: "method"
        case 3: "function"
        case 4: "constructor"
        case 5: "field"
        case 6: "variable"
        case 7: "class"
        case 8: "interface"
        case 9: "module"
        case 10: "property"
        case 12: "value"
        case 13: "enum"
        case 14: "keyword"
        case 20: "enum member"
        case 21: "constant"
        case 22: "struct"
        default: "text"
        }
    }

    static func parse(_ value: JSONValue, index: Int) -> CompletionItem? {
        guard let label = value["label"]?.stringValue else { return nil }
        var textEdit: LSPTextEdit?
        if let edit = value["textEdit"] {
            if let range = try? edit["range"]?.decode(LSPRange.self), let newText = edit["newText"]?.stringValue {
                textEdit = LSPTextEdit(range: range, newText: newText)
            } else if let range = try? edit["replace"]?.decode(LSPRange.self), let newText = edit["newText"]?.stringValue {
                textEdit = LSPTextEdit(range: range, newText: newText)
            }
        }
        let additional = (try? value["additionalTextEdits"]?.decode([LSPTextEdit].self)) ?? []
        var documentation: String?
        switch value["documentation"] {
        case .string(let text): documentation = text
        case .object(let object): documentation = object["value"]?.stringValue
        default: break
        }
        var deprecated = false
        if case .bool(true) = value["deprecated"] { deprecated = true }
        if let tags = value["tags"]?.arrayValue, tags.contains(.number(1)) { deprecated = true }
        return CompletionItem(
            id: index,
            label: label,
            kind: value["kind"]?.intValue,
            detail: value["detail"]?.stringValue,
            documentation: documentation,
            sortText: value["sortText"]?.stringValue,
            filterText: value["filterText"]?.stringValue,
            insertText: value["insertText"]?.stringValue,
            insertTextFormat: value["insertTextFormat"]?.intValue,
            textEdit: textEdit,
            additionalTextEdits: additional,
            deprecated: deprecated,
            raw: value
        )
    }
}

public struct HoverInfo: Sendable, Hashable {
    public var markdown: String
    public var range: LSPRange?
}

public struct SignatureHelpInfo: Sendable, Hashable {
    public struct Signature: Sendable, Hashable {
        public var label: String
        public var documentation: String?
        /// UTF-16 offsets into `label` for each parameter.
        public var parameterRanges: [Range<Int>]
        public var parameterDocs: [String?]
    }

    public var signatures: [Signature]
    public var activeSignature: Int
    public var activeParameter: Int

    static func parse(_ value: JSONValue) -> SignatureHelpInfo? {
        guard let signatures = value["signatures"]?.arrayValue, !signatures.isEmpty else { return nil }
        let parsed = signatures.compactMap { signature -> Signature? in
            guard let label = signature["label"]?.stringValue else { return nil }
            var ranges: [Range<Int>] = []
            var docs: [String?] = []
            for parameter in signature["parameters"]?.arrayValue ?? [] {
                switch parameter["label"] {
                case .array(let bounds) where bounds.count == 2:
                    if let start = bounds[0].intValue, let end = bounds[1].intValue, start <= end { ranges.append(start..<end) }
                case .string(let text):
                    let ns = label as NSString
                    let found = ns.range(of: text)
                    if found.location != NSNotFound { ranges.append(found.location..<(found.location + found.length)) }
                default:
                    break
                }
                docs.append(markupText(parameter["documentation"]))
            }
            return Signature(label: label, documentation: markupText(signature["documentation"]), parameterRanges: ranges, parameterDocs: docs)
        }
        guard !parsed.isEmpty else { return nil }
        let active = min(value["activeSignature"]?.intValue ?? 0, parsed.count - 1)
        let activeParameter = value["activeParameter"]?.intValue ?? signatures[active]["activeParameter"]?.intValue ?? 0
        return SignatureHelpInfo(signatures: parsed, activeSignature: max(0, active), activeParameter: activeParameter)
    }
}

func markupText(_ value: JSONValue?) -> String? {
    switch value {
    case .string(let text): return text
    case .object(let object): return object["value"]?.stringValue
    case .array(let items): return items.compactMap { markupText($0) }.joined(separator: "\n\n")
    default: return nil
    }
}
