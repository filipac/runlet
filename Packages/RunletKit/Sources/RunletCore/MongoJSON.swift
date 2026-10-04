import Foundation

/// A JSON value that keeps what `JSONSerialization` loses (#217): its members' order and its
/// numbers' text. The query builder reads a MongoDB tab's query into this, and writes the
/// builder's query from it, so a query read and written back keeps its key order and literals.
public indirect enum MongoJSON: Equatable, Hashable, Sendable {
    case object([Member])
    case array([MongoJSON])
    case string(String)
    /// The number's literal, as written (`1`, `1.50`, `-2e3`).
    case number(String)
    case bool(Bool)
    case null

    public struct Member: Equatable, Hashable, Sendable {
        public var key: String
        public var value: MongoJSON
        public init(_ key: String, _ value: MongoJSON) {
            self.key = key
            self.value = value
        }
    }

    /// Why a text isn't one JSON value, and where (1-based line and column).
    public struct ParseError: Error, Equatable, Sendable, LocalizedError {
        public var message: String
        public var line: Int
        public var column: Int
        public var errorDescription: String? { "Line \(line), column \(column): \(message)" }
    }

    public var members: [Member]? { if case .object(let members) = self { members } else { nil } }
    public var elements: [MongoJSON]? { if case .array(let elements) = self { elements } else { nil } }
    public var stringValue: String? { if case .string(let value) = self { value } else { nil } }

    /// The value of the first member named `key`.
    public subscript(key: String) -> MongoJSON? {
        members?.first { $0.key == key }?.value
    }

    // MARK: Parsing

    /// Reads one strict JSON value (RFC 8259): no comments, no trailing commas.
    public static func parse(_ text: String) throws(ParseError) -> MongoJSON {
        var parser = Parser(Array(text.utf8))
        parser.skipBlanks()
        let value = try parser.value(depth: 0)
        parser.skipBlanks()
        guard parser.index == parser.bytes.count else { throw parser.error("Unexpected text after the JSON value.") }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        static let maxDepth = 256

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        func error(_ message: String) -> ParseError {
            var line = 1, column = 1
            for byte in bytes[0..<min(index, bytes.count)] {
                if byte == 10 { line += 1; column = 1 } else if byte & 0xC0 != 0x80 { column += 1 }
            }
            return ParseError(message: message, line: line, column: column)
        }

        mutating func skipBlanks() {
            while index < bytes.count, [32, 9, 10, 13].contains(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) throws(ParseError) -> MongoJSON {
            guard depth < Self.maxDepth else { throw error("The JSON is nested too deeply.") }
            guard index < bytes.count else { throw error("Expected a value; the text ended.") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try number())
            default: throw error("Expected a value (an object, array, string, number, true, false, or null).")
            }
        }

        mutating func literal(_ word: String) throws(ParseError) {
            let expected = Array(word.utf8)
            guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else {
                throw error("Expected \(word).")
            }
            index += expected.count
        }

        mutating func object(depth: Int) throws(ParseError) -> MongoJSON {
            index += 1
            var members: [Member] = []
            skipBlanks()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
            while true {
                skipBlanks()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("Expected a member name in double quotes.") }
                let key = try string()
                skipBlanks()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("Expected ':' after the member name.") }
                index += 1
                skipBlanks()
                members.append(Member(key, try value(depth: depth + 1)))
                skipBlanks()
                guard index < bytes.count else { throw error("Expected ',' or '}'; the text ended.") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                throw error("Expected ',' or '}'.")
            }
        }

        mutating func array(depth: Int) throws(ParseError) -> MongoJSON {
            index += 1
            var elements: [MongoJSON] = []
            skipBlanks()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(elements) }
            while true {
                skipBlanks()
                elements.append(try value(depth: depth + 1))
                skipBlanks()
                guard index < bytes.count else { throw error("Expected ',' or ']'; the text ended.") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(elements) }
                throw error("Expected ',' or ']'.")
            }
        }

        mutating func string() throws(ParseError) -> String {
            index += 1
            var scalars = String.UnicodeScalarView()
            var run = [UInt8]()
            func flush() { if !run.isEmpty { scalars.append(contentsOf: String(decoding: run, as: UTF8.self).unicodeScalars); run.removeAll() } }
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    index += 1
                    flush()
                    return String(scalars)
                }
                if byte < 0x20 { throw error("A string can't contain a raw control character or line break; write \\n.") }
                if byte != UInt8(ascii: "\\") {
                    run.append(byte)
                    index += 1
                    continue
                }
                flush()
                index += 1
                guard index < bytes.count else { break }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code) {
                        guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else {
                            throw error("A \\u escape of a high surrogate needs its low surrogate.")
                        }
                        index += 2
                        let low = try hex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw error("Invalid surrogate pair.") }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    } else if (0xDC00...0xDFFF).contains(code) {
                        throw error("A lone low surrogate.")
                    }
                    guard let scalar = Unicode.Scalar(code) else { throw error("Invalid \\u escape.") }
                    scalars.append(scalar)
                default:
                    index -= 1
                    throw error("Invalid escape in a string.")
                }
            }
            throw error("A string isn't closed with '\"'.")
        }

        mutating func hex4() throws(ParseError) -> UInt32 {
            guard index + 4 <= bytes.count, let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else {
                throw error("Expected four hex digits after \\u.")
            }
            index += 4
            return value
        }

        mutating func number() throws(ParseError) -> String {
            let start = index
            func digits() -> Int {
                let from = index
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
                return index - from
            }
            if bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count else { throw error("Expected digits.") }
            if bytes[index] == UInt8(ascii: "0") {
                index += 1
            } else if digits() == 0 {
                throw error("Expected digits.")
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                guard digits() > 0 else { throw error("Expected digits after the decimal point.") }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard digits() > 0 else { throw error("Expected the exponent's digits.") }
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
    }

    /// Whether `text` is one JSON number literal.
    public static func isNumber(_ text: String) -> Bool {
        if case .number = try? parse(text) { return true }
        return false
    }

    // MARK: Writing

    /// The value on one line: `{ "status": "paid", "total": { "$gt": 10 } }`, `["a", "b"]`.
    public var inline: String {
        var out = ""
        writeInline(into: &out)
        return out
    }

    private func writeInline(into out: inout String) {
        switch self {
        case .object(let members):
            if members.isEmpty { out += "{}"; return }
            out += "{ "
            for (index, member) in members.enumerated() {
                if index > 0 { out += ", " }
                out += Self.quoted(member.key)
                out += ": "
                member.value.writeInline(into: &out)
            }
            out += " }"
        case .array(let elements):
            out += "["
            for (index, element) in elements.enumerated() {
                if index > 0 { out += ", " }
                element.writeInline(into: &out)
            }
            out += "]"
        case .string(let value): out += Self.quoted(value)
        case .number(let literal): out += literal
        case .bool(let value): out += value ? "true" : "false"
        case .null: out += "null"
        }
    }

    /// Pretty-printed with two-space indents: a value that fits in `width` columns stays on its
    /// line, like `"filter": { "status": "paid" }`; a longer one is broken over lines. The
    /// top-level object is always broken, and so are its `pipeline` and `documents` arrays (one
    /// stage or document per line).
    public func pretty(width: Int = 80) -> String {
        var out = ""
        write(into: &out, indent: 0, column: 0, width: width, forceBreak: true, breakArraysOf: ["pipeline", "documents"])
        return out
    }

    private func write(into out: inout String, indent: Int, column: Int, width: Int, forceBreak: Bool, breakArraysOf: Set<String> = []) {
        let flat = inline
        if !forceBreak, column + flat.count <= width {
            out += flat
            return
        }
        let pad = String(repeating: " ", count: indent + 2)
        switch self {
        case .object(let members) where !members.isEmpty:
            out += "{\n"
            for (index, member) in members.enumerated() {
                let key = Self.quoted(member.key) + ": "
                out += pad + key
                let breaks = breakArraysOf.contains(member.key) && member.value.elements?.isEmpty == false
                member.value.write(into: &out, indent: indent + 2, column: indent + 2 + key.count, width: width, forceBreak: breaks)
                out += index == members.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: " ", count: indent) + "}"
        case .array(let elements) where !elements.isEmpty:
            out += "[\n"
            for (index, element) in elements.enumerated() {
                out += pad
                element.write(into: &out, indent: indent + 2, column: indent + 2, width: width, forceBreak: false)
                out += index == elements.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: " ", count: indent) + "]"
        default:
            out += flat
        }
    }

    /// A JSON string literal: quotes, backslashes, and control characters escaped; `/` and
    /// non-ASCII characters as they are.
    public static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20:
                out += String(format: "\\u%04x", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
