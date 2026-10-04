import Foundation

/// A value the MongoDB query builder edits with a typed input (#217), written as Extended JSON:
/// a string, a number, true or false, null, a date (`{"$date": "…Z"}`, UTC), an ObjectId
/// (`{"$oid": …}`), a Decimal128 (`{"$numberDecimal": …}`), a 64-bit integer
/// (`{"$numberLong": …}`), a regular expression (`{"$regularExpression": …}`), a field reference
/// in an aggregation expression (`"$total"`), a snippet input (`{"$input": "name"}`), or any
/// other JSON, as text.
public struct MongoValue: Equatable, Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case string, number, bool, null, date, objectId, decimal, long, regex, field, input, json

        public var title: String {
            switch self {
            case .string: "String"
            case .number: "Number"
            case .bool: "Boolean"
            case .null: "Null"
            case .date: "Date"
            case .objectId: "ObjectId"
            case .decimal: "Decimal128"
            case .long: "Int64"
            case .regex: "Regex"
            case .field: "Field"
            case .input: "Snippet input"
            case .json: "JSON"
            }
        }

        /// The kinds a filter value offers (a field reference is an aggregation expression).
        public static let literals: [Kind] = [.string, .number, .bool, .null, .date, .objectId, .decimal, .long, .regex, .input, .json]
        /// The kinds an aggregation expression offers.
        public static let expressions: [Kind] = [.field, .string, .number, .bool, .null, .date, .objectId, .decimal, .json]
    }

    public var kind: Kind
    /// What the input edits: the string; the number's literal; `true` or `false`; the date in
    /// ISO 8601; the ObjectId's 24 hex digits; the decimal's or Int64's digits; the regex's
    /// pattern; the field's path (without `$`); the snippet input's name; or JSON text.
    public var text: String
    /// A regex's options (`i`, `m`, `s`, `x`, `u`).
    public var options: String

    public init(_ kind: Kind = .string, _ text: String = "", options: String = "") {
        self.kind = kind
        self.text = text
        self.options = options
    }

    public static func string(_ text: String) -> MongoValue { MongoValue(.string, text) }
    public static func number(_ literal: String) -> MongoValue { MongoValue(.number, literal) }
    public static func bool(_ value: Bool) -> MongoValue { MongoValue(.bool, value ? "true" : "false") }
    public static let null = MongoValue(.null)
    public static func field(_ path: String) -> MongoValue { MongoValue(.field, path) }
    public static func json(_ value: MongoJSON) -> MongoValue { MongoValue(.json, value.display) }

    /// Reads a JSON value: an Extended JSON wrapper the builder types becomes that kind; other
    /// objects and arrays stay JSON. In an aggregation `expression`, `"$path"` is a field.
    public init(json: MongoJSON, expression: Bool = false) {
        switch json {
        case .string(let text):
            if expression, text.hasPrefix("$"), !text.hasPrefix("$$"), text.count > 1 {
                self.init(.field, String(text.dropFirst()))
            } else {
                self.init(.string, text)
            }
        case .number(let literal): self.init(.number, literal)
        case .bool(let value): self = .bool(value)
        case .null: self.init(.null)
        case .array: self = .json(json)
        case .object(let members):
            if members.count == 1, let member = members.first {
                switch (member.key, member.value) {
                case ("$oid", .string(let hex)):
                    self.init(.objectId, hex); return
                case ("$date", .string(let iso)) where Self.date(from: iso) != nil:
                    self.init(.date, iso); return
                case ("$numberDecimal", .string(let digits)):
                    self.init(.decimal, digits); return
                case ("$numberLong", .string(let digits)) where Int64(digits) != nil:
                    self.init(.long, digits); return
                case ("$input", .string(let name)) where !name.isEmpty:
                    self.init(.input, name); return
                case ("$regularExpression", .object(let parts)) where parts.count == 2 && parts[0].key == "pattern" && parts[1].key == "options":
                    if case .string(let pattern) = parts[0].value, case .string(let options) = parts[1].value {
                        self.init(.regex, pattern, options: options); return
                    }
                default: break
                }
            }
            self = .json(json)
        }
    }

    /// A value from a result (canonical Extended JSON, as the result tree has it), as the builder
    /// types it: `$numberInt` and `$numberDouble` become numbers, `{"$date": {"$numberLong": …}}`
    /// a UTC date, and so on (Filter by This Value, #217).
    public init(canonical json: MongoJSON) {
        if case .object(let members) = json, members.count == 1, let member = members.first {
            switch (member.key, member.value) {
            case ("$numberInt", .string(let digits)) where MongoJSON.isNumber(digits),
                 ("$numberDouble", .string(let digits)) where MongoJSON.isNumber(digits):
                self.init(.number, digits); return
            case ("$date", .object(let inner)) where inner.count == 1 && inner[0].key == "$numberLong":
                if let text = inner[0].value.stringValue, let milliseconds = Double(text) {
                    self.init(.date, Self.isoText(Date(timeIntervalSince1970: milliseconds / 1000))); return
                }
            default: break
            }
        }
        self.init(json: json)
    }

    /// The Extended JSON this value writes, or nil while its text isn't valid for its kind.
    public var json: MongoJSON? {
        switch kind {
        case .string: return .string(text)
        case .number: return MongoJSON.isNumber(text.mongoTrimmed) ? .number(text.mongoTrimmed) : nil
        case .bool:
            switch text.mongoTrimmed.lowercased() {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: return nil
            }
        case .null: return .null
        case .date: return Self.date(from: text.mongoTrimmed) == nil ? nil : .object([.init("$date", .string(text.mongoTrimmed))])
        case .objectId: return Self.isObjectId(text.mongoTrimmed) ? .object([.init("$oid", .string(text.mongoTrimmed))]) : nil
        case .decimal: return Self.isDecimal(text.mongoTrimmed) ? .object([.init("$numberDecimal", .string(text.mongoTrimmed))]) : nil
        case .long: return Int64(text.mongoTrimmed) == nil ? nil : .object([.init("$numberLong", .string(text.mongoTrimmed))])
        case .regex:
            guard options.allSatisfy({ "imsxu".contains($0) }) else { return nil }
            return .object([.init("$regularExpression", .object([.init("pattern", .string(text)), .init("options", .string(options))]))])
        case .field: return text.mongoTrimmed.isEmpty ? nil : .string("$" + text.mongoTrimmed)
        case .input: return text.mongoTrimmed.isEmpty ? nil : .object([.init("$input", .string(text.mongoTrimmed))])
        case .json: return try? MongoJSON.parse(text)
        }
    }

    /// Why the value can't be written yet, for the input's warning.
    public var problem: String? {
        guard json == nil else { return nil }
        return switch kind {
        case .number: "Enter a number, such as 42 or 12.5."
        case .bool: "Enter true or false."
        case .date: "Enter a date and time, such as 2026-01-01T00:00:00Z."
        case .objectId: "An ObjectId is 24 hexadecimal digits."
        case .decimal: "Enter a decimal number, such as 12.50."
        case .long: "Enter a whole number from −9223372036854775808 to 9223372036854775807."
        case .regex: "Regex options are i, m, s, x, and u."
        case .field: "Choose a field."
        case .input: "Name the snippet input."
        case .json: (try? MongoJSON.parse(text)).map { _ in nil } ?? Self.jsonProblem(text)
        case .string, .null: nil
        }
    }

    private static func jsonProblem(_ text: String) -> String {
        do { _ = try MongoJSON.parse(text); return "" } catch { return error.errorDescription ?? "Invalid JSON." }
    }

    /// The value converted to `kind`, keeping what carries over (a number's digits as a
    /// decimal, a string as a regex pattern).
    public func converted(to kind: Kind) -> MongoValue {
        guard kind != self.kind else { return self }
        switch kind {
        case .null: return .null
        case .bool: return .bool(text.mongoTrimmed.lowercased() == "true")
        case .date:
            if let date = Self.date(from: text.mongoTrimmed) { return MongoValue(.date, Self.isoText(date)) }
            return MongoValue(.date, Self.isoText(Self.startOfTodayUTC()))
        case .json: return json.map { .json($0) } ?? MongoValue(.json, self.kind == .string ? MongoJSON.quoted(text) : "{}")
        case .number, .decimal, .long:
            return MongoValue(kind, [.number, .decimal, .long].contains(self.kind) ? text : kind == .number ? "0" : kind == .decimal ? "0.00" : "0")
        default:
            return MongoValue(kind, [.bool, .null, .json].contains(self.kind) ? "" : text)
        }
    }

    // MARK: Kinds from sampled fields

    /// The input a sampled field's types suggest: Sample Fields' names (`ObjectId`,
    /// `UTCDateTime`, `Decimal128`, `Int64`, `int`, `double`, `bool`, `null`, `object`, `array`,
    /// `string`, or PHP's class names); the first non-null type wins.
    public static func kind(forSampledTypes types: String) -> Kind {
        let names = types.split(separator: ",").map { part in
            let name = part.trimmingCharacters(in: .whitespaces)
            return name.components(separatedBy: "\\").last ?? name
        }
        for name in names where !["null", "NULL"].contains(name) {
            switch name {
            case "ObjectId": return .objectId
            case "UTCDateTime": return .date
            case "Decimal128": return .decimal
            case "Int64": return .long
            case "int", "integer", "double", "Int32": return .number
            case "bool", "boolean": return .bool
            case "Regex": return .regex
            case "object", "stdClass", "array", "Document", "PackedArray", "Binary", "Timestamp": return .json
            default: return .string
            }
        }
        return names.isEmpty ? .string : .null
    }

    /// A new value of `kind` for an empty input.
    public static func empty(_ kind: Kind) -> MongoValue {
        switch kind {
        case .bool: .bool(true)
        case .date: MongoValue(.date, isoText(startOfTodayUTC()))
        case .json: MongoValue(.json, "{}")
        default: MongoValue(kind, "")
        }
    }

    // MARK: Validation and dates

    public static func isObjectId(_ text: String) -> Bool {
        text.utf8.count == 24 && text.allSatisfy(\.isHexDigit)
    }

    public static func isDecimal(_ text: String) -> Bool {
        if ["NaN", "Infinity", "-Infinity", "Inf", "-Inf"].contains(text) { return true }
        return text.range(of: #"^[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?$"#, options: .regularExpression) != nil
    }

    /// An ISO 8601 date and time, with or without fractional seconds, in UTC (`Z`) or with an offset.
    public static func date(from text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    /// The date as the builder writes it: UTC, `2026-01-01T09:30:00Z`, with milliseconds when it has them.
    public static func isoText(_ date: Date) -> String {
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        let rounded = Date(timeIntervalSince1970: milliseconds / 1000)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = milliseconds.truncatingRemainder(dividingBy: 1000) == 0 ? [.withInternetDateTime] : [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: rounded)
    }

    static func startOfTodayUTC(_ now: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.startOfDay(for: now)
    }
}

/// MongoDB's `$type` aliases, for the filter's type operator.
public enum MongoTypeAliases {
    public static let all = ["string", "int", "long", "double", "decimal", "bool", "date", "objectId", "object", "array", "null", "regex", "binData", "timestamp", "number", "missing"]
}

extension String {
    var mongoTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
