import Foundation

/// A bounded, structured representation of a PHP value produced by the runner.
public struct ValueNode: Sendable, Codable, Equatable, Hashable {
    public enum Kind: String, Sendable, Codable {
        case null, bool, int, float, string, array, object, `enum`, closure, resource, unknown
    }

    public struct Entry: Sendable, Codable, Equatable, Hashable {
        public var key: String
        /// int | string | property
        public var keyType: String
        public var visibility: String?
        public var declaringClass: String?
        public var isReference: Bool?
        public var value: ValueNode
    }

    public struct Truncation: Sendable, Codable, Equatable, Hashable {
        /// depth | children | length | budget
        public var reason: String
        /// Number of omitted children/bytes; -1 when unknown.
        public var omitted: Int
    }

    public var id: Int
    public var type: Kind
    public var className: String?
    public var scalar: String?
    public var encoding: String?
    public var length: Int?
    public var count: Int?
    public var entries: [Entry]?
    public var referenceId: String?
    public var repeated: Bool?
    public var recursion: Bool?
    public var summary: String?
    public var backingValue: String?
    public var truncation: Truncation?
    public var budgetExceeded: Bool?

    public init(id: Int, type: Kind, className: String? = nil, scalar: String? = nil, entries: [Entry]? = nil) {
        self.id = id
        self.type = type
        self.className = className
        self.scalar = scalar
        self.entries = entries
    }

    enum CodingKeys: String, CodingKey {
        case id, type, className, scalar, encoding, length, count, entries, referenceId, repeated, recursion, summary, backingValue, truncation, budgetExceeded
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id) ?? 0
        type = (try? c.decode(Kind.self, forKey: .type)) ?? .unknown
        className = try c.decodeIfPresent(String.self, forKey: .className)
        scalar = try c.decodeIfPresent(String.self, forKey: .scalar)
        encoding = try c.decodeIfPresent(String.self, forKey: .encoding)
        length = try c.decodeIfPresent(Int.self, forKey: .length)
        count = try c.decodeIfPresent(Int.self, forKey: .count)
        entries = try c.decodeIfPresent([Entry].self, forKey: .entries)
        referenceId = try c.decodeIfPresent(String.self, forKey: .referenceId)
        repeated = try c.decodeIfPresent(Bool.self, forKey: .repeated)
        recursion = try c.decodeIfPresent(Bool.self, forKey: .recursion)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        if let string = try? c.decodeIfPresent(String.self, forKey: .backingValue) {
            backingValue = string
        } else if let int = try? c.decodeIfPresent(Int.self, forKey: .backingValue) {
            backingValue = String(int)
        }
        truncation = try c.decodeIfPresent(Truncation.self, forKey: .truncation)
        budgetExceeded = try c.decodeIfPresent(Bool.self, forKey: .budgetExceeded)
    }

    /// Decoded string bytes; base64 payloads (invalid UTF-8) are shown with escapes.
    public var displayString: String {
        guard let scalar else { return "" }
        if encoding == "base64", let data = Data(base64Encoded: scalar) {
            return data.map { byte -> String in
                if byte >= 0x20 && byte < 0x7f && byte != 0x5c { return String(UnicodeScalar(byte)) }
                return String(format: "\\x%02X", byte)
            }.joined()
        }
        return scalar
    }

    public var isExpandable: Bool {
        if let entries, !entries.isEmpty { return true }
        return false
    }

    /// A short one-line rendering used for collapsed rows and plain-text copies.
    public var inlineSummary: String {
        switch type {
        case .null: return "null"
        case .bool, .int, .float: return scalar ?? ""
        case .string:
            var text = "\"" + displayString.replacingOccurrences(of: "\n", with: "\\n") + "\""
            if let truncation, truncation.reason == "length" { text += "… (+\(truncation.omitted) bytes)" }
            return text
        case .array:
            let count = count ?? entries?.count ?? 0
            if recursion == true { return "array *RECURSION*" }
            return "array:\(count) [\(count == 0 ? "" : "…")]"
        case .object:
            let name = className ?? "object"
            let ref = referenceId.map { " #\($0)" } ?? ""
            if repeated == true { return "\(name)\(ref) (see above)" }
            if let summary { return "\(name)\(ref) \(summary)" }
            return "\(name)\(ref) {…}"
        case .enum:
            return "\(className ?? "enum")::\(scalar ?? "")" + (backingValue.map { " = \($0)" } ?? "")
        case .closure:
            return "Closure" + (summary.map { " (\($0))" } ?? "")
        case .resource:
            return "resource(\(className ?? "?")) #\(scalar ?? "")"
        case .unknown:
            return scalar ?? "unknown"
        }
    }

    public var typeLabel: String {
        switch type {
        case .string: "string(\(length ?? displayString.utf8.count))"
        case .array: "array(\(count ?? entries?.count ?? 0))"
        case .object: className ?? "object"
        case .enum: className ?? "enum"
        default: type.rawValue
        }
    }

    /// A multi-line plain-text rendering similar to a CLI dump, used for copying output.
    public func plainText(indent: Int = 0, maxDepth: Int = 12) -> String {
        var lines: [String] = []
        render(into: &lines, prefix: "", indent: indent, depth: 0, maxDepth: maxDepth)
        return lines.joined(separator: "\n")
    }

    private func render(into lines: inout [String], prefix: String, indent: Int, depth: Int, maxDepth: Int) {
        let pad = String(repeating: "  ", count: indent)
        guard let entries, !entries.isEmpty, depth < maxDepth, repeated != true else {
            var line = pad + prefix + inlineSummary
            if let truncation, truncation.reason != "length" { line += " …" }
            lines.append(line)
            return
        }
        let open: String
        let close: String
        switch type {
        case .array:
            open = "array:\(count ?? entries.count) ["
            close = "]"
        default:
            let ref = referenceId.map { " #\($0)" } ?? ""
            open = "\(className ?? "object")\(ref) {"
            close = "}"
        }
        lines.append(pad + prefix + open)
        for entry in entries {
            let keyText: String
            switch entry.keyType {
            case "int": keyText = "\(entry.key) => "
            case "string": keyText = "\"\(entry.key)\" => "
            default:
                let marker = entry.visibility == "protected" ? "#" : (entry.visibility == "private" ? "-" : "+")
                keyText = "\(marker)\(entry.key): "
            }
            entry.value.render(into: &lines, prefix: keyText, indent: indent + 1, depth: depth + 1, maxDepth: maxDepth)
        }
        if let truncation, truncation.omitted > 0 {
            lines.append(pad + "  … \(truncation.omitted) more")
        }
        lines.append(pad + close)
    }
}
