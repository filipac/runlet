import Foundation

/// A bounded, structured representation of a PHP value produced by the runner.
public struct ValueNode: Sendable, Codable, Equatable, Hashable {
    public enum Kind: String, Sendable, Codable {
        case null, bool, int, float, string, array, object, `enum`, closure, resource, unknown
    }

    public struct Entry: Sendable, Codable, Equatable, Hashable {
        public var key: String
        /// int | string | property | field (a driver caster's, #6)
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

    /// An object the project's driver showed with one of its casters (#6). The node's summary
    /// and entries (key type `field`) are the caster's; `raw` is the object as Runlet sees it.
    public struct Cast: Sendable, Codable, Equatable, Hashable {
        /// The driver whose caster showed the object.
        public var by: String
        /// The class or interface the caster is declared for, when it isn't the object's class.
        public var type: String?
        /// Why the caster didn't show the object (it threw, returned the object itself, or the
        /// value's casters ran out of time). The node is then the object as Runlet sees it.
        public var error: String?
        /// Stored in an array: a struct can't hold its own type directly.
        private var rawNode: [ValueNode]

        /// The object as Runlet sees it, without casters (Show Raw). Nil when the caster
        /// failed (the node is already raw), or the value's size limit left it out.
        public var raw: ValueNode? {
            get { rawNode.first }
            set { rawNode = newValue.map { [$0] } ?? [] }
        }

        public init(by: String, type: String? = nil, error: String? = nil, raw: ValueNode? = nil) {
            self.by = by
            self.type = type
            self.error = error
            self.rawNode = raw.map { [$0] } ?? []
        }

        enum CodingKeys: String, CodingKey {
            case by, type, error, raw
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            by = try c.decodeIfPresent(String.self, forKey: .by) ?? ""
            type = try c.decodeIfPresent(String.self, forKey: .type)
            error = try c.decodeIfPresent(String.self, forKey: .error)
            rawNode = try c.decodeIfPresent(ValueNode.self, forKey: .raw).map { [$0] } ?? []
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(by, forKey: .by)
            try c.encodeIfPresent(type, forKey: .type)
            try c.encodeIfPresent(error, forKey: .error)
            try c.encodeIfPresent(raw, forKey: .raw)
        }

        /// The tooltip of the value's driver mark.
        public var help: String {
            let declared = type.map { " for \($0)" } ?? ""
            if let error { return "\(by)'s caster\(declared) couldn't show this object (\(error)), so it shows as Runlet sees it." }
            return "Shown by \(by)'s caster\(declared)." + (raw == nil ? " The raw object was left out: the value is too large." : " Click to show the raw object.")
        }
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
    /// Set when the project's driver showed this object with a caster (#6).
    public var cast: Cast?

    public init(id: Int, type: Kind, className: String? = nil, scalar: String? = nil, entries: [Entry]? = nil) {
        self.id = id
        self.type = type
        self.className = className
        self.scalar = scalar
        self.entries = entries
    }

    enum CodingKeys: String, CodingKey {
        case id, type, className, scalar, encoding, length, count, entries, referenceId, repeated, recursion, summary, backingValue, truncation, budgetExceeded, cast
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
        cast = try c.decodeIfPresent(Cast.self, forKey: .cast)
    }

    /// Whether the driver's caster shows this object (and not Runlet's own view of it).
    public var isCast: Bool { cast != nil && cast?.error == nil }

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
            let summary = isCast ? summary.map { " " + $0 } ?? "" : ""
            open = "\(className ?? "object")\(ref)\(summary) {"
            close = "}"
        }
        lines.append(pad + prefix + open)
        for entry in entries {
            let keyText: String
            switch entry.keyType {
            case "int": keyText = "\(entry.key) => "
            case "string": keyText = "\"\(entry.key)\" => "
            case "field": keyText = "\(entry.key): "
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
