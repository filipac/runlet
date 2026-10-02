import Foundation

/// A JSON value for MCP messages (#43). Integers and floating-point numbers stay apart, so
/// JSON-RPC request ids round-trip exactly, and booleans never read as numbers.
public enum MCPJSON: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([MCPJSON])
    case object([String: MCPJSON])

    /// Parses one JSON document (any value, not only objects).
    public static func parse(_ data: Data) throws -> MCPJSON {
        try MCPJSON(any: JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    public static func parse(_ text: String) throws -> MCPJSON {
        try parse(Data(text.utf8))
    }

    /// Compact JSON on one line: strings escape their newlines, keys are sorted.
    public var serialized: String {
        let data = (try? JSONSerialization.data(withJSONObject: anyValue, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Indented JSON for people (and models) to read.
    public var pretty: String {
        let data = (try? JSONSerialization.data(withJSONObject: anyValue, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes, .prettyPrinted])) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    struct UnsupportedValue: Error {}

    init(any value: Any) throws {
        switch value {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                let double = number.doubleValue
                // 3.0 written as a float is still a whole number (JSON has one number type).
                if double.rounded() == double, abs(double) < 9.0e15 { self = .int(Int(double)) } else { self = .double(double) }
            } else {
                self = .int(number.intValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(try array.map(MCPJSON.init(any:)))
        case let object as [String: Any]:
            self = .object(try object.mapValues(MCPJSON.init(any:)))
        default:
            throw UnsupportedValue()
        }
    }

    var anyValue: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): NSNumber(value: value)
        case .int(let value): NSNumber(value: value)
        case .double(let value): value.isFinite ? NSNumber(value: value) : NSNull()
        case .string(let value): value
        case .array(let values): values.map(\.anyValue)
        case .object(let values): values.mapValues(\.anyValue)
        }
    }

    public subscript(key: String) -> MCPJSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: MCPJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool { self == .null }
}

extension MCPJSON: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([MCPJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: MCPJSON].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension MCPJSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: MCPJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, MCPJSON)...) { self = .object(Dictionary(elements, uniquingKeysWith: { $1 })) }
    public init(nilLiteral: ()) { self = .null }
}
