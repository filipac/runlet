import Foundation

/// A Redis reply (#190) as the runner reports it: RESP2 and RESP3 types, with the runner's caps
/// (strings shortened, aggregates cut after a number of elements, which it counts). JSON:
/// `{"t": "s", "v": "text"}` (with `"o"`: bytes left out), `{"t": "x", "n": bytes, "h": hex}`
/// (not UTF-8), `+` status, `-` error, `i` integer, `d` double (as text), `b` boolean, `n`
/// nil, `*` array, `~` set, `%` map (`v` holds `[key, value]` pairs); aggregates have `"o"`:
/// elements left out.
public indirect enum RedisValue: Sendable, Equatable, Hashable, Codable {
    case string(String)
    /// A string the runner shortened; -1: its full size is unknown.
    case clipped(String, omittedBytes: Int)
    /// Bytes that aren't UTF-8: their size and the hex of the first 32.
    case binary(bytes: Int, hexPrefix: String)
    case status(String)
    case error(String)
    case integer(Int64)
    /// RESP3 doubles, and floats from an application's client; kept as text (`inf`, `1.5`).
    case double(String)
    case bool(Bool)
    case null
    case array([RedisValue], omitted: Int)
    case set([RedisValue], omitted: Int)
    case map([RedisPair], omitted: Int)

    private enum Keys: String, CodingKey { case t, v, o, n, h }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .t)
        let omitted = (try? c.decodeIfPresent(Int.self, forKey: .o)) ?? 0
        switch type {
        case "s":
            let text = try c.decodeIfPresent(String.self, forKey: .v) ?? ""
            self = omitted != 0 ? .clipped(text, omittedBytes: omitted) : .string(text)
        case "x": self = .binary(bytes: try c.decodeIfPresent(Int.self, forKey: .n) ?? 0, hexPrefix: try c.decodeIfPresent(String.self, forKey: .h) ?? "")
        case "+": self = .status(try c.decodeIfPresent(String.self, forKey: .v) ?? "")
        case "-": self = .error(try c.decodeIfPresent(String.self, forKey: .v) ?? "")
        case "i":
            if let value = try? c.decode(Int64.self, forKey: .v) {
                self = .integer(value)
            } else {
                self = .double(try c.decodeIfPresent(String.self, forKey: .v) ?? "")
            }
        case "d":
            if let text = try? c.decode(String.self, forKey: .v) {
                self = .double(text)
            } else {
                self = .double(String(try c.decode(Double.self, forKey: .v)))
            }
        case "b": self = .bool(try c.decode(Bool.self, forKey: .v))
        case "*": self = .array(try c.decodeIfPresent([RedisValue].self, forKey: .v) ?? [], omitted: omitted)
        case "~": self = .set(try c.decodeIfPresent([RedisValue].self, forKey: .v) ?? [], omitted: omitted)
        case "%":
            let pairs = try c.decodeIfPresent([[RedisValue]].self, forKey: .v) ?? []
            self = .map(pairs.compactMap { $0.count == 2 ? RedisPair(key: $0[0], value: $0[1]) : nil }, omitted: omitted)
        default: self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .string(let text):
            try c.encode("s", forKey: .t)
            try c.encode(text, forKey: .v)
        case .clipped(let text, let omitted):
            try c.encode("s", forKey: .t)
            try c.encode(text, forKey: .v)
            try c.encode(omitted, forKey: .o)
        case .binary(let bytes, let hex):
            try c.encode("x", forKey: .t)
            try c.encode(bytes, forKey: .n)
            try c.encode(hex, forKey: .h)
        case .status(let text):
            try c.encode("+", forKey: .t)
            try c.encode(text, forKey: .v)
        case .error(let text):
            try c.encode("-", forKey: .t)
            try c.encode(text, forKey: .v)
        case .integer(let value):
            try c.encode("i", forKey: .t)
            try c.encode(value, forKey: .v)
        case .double(let text):
            try c.encode("d", forKey: .t)
            try c.encode(text, forKey: .v)
        case .bool(let value):
            try c.encode("b", forKey: .t)
            try c.encode(value, forKey: .v)
        case .null:
            try c.encode("n", forKey: .t)
        case .array(let items, let omitted), .set(let items, let omitted):
            try c.encode(self.isSet ? "~" : "*", forKey: .t)
            try c.encode(items, forKey: .v)
            if omitted != 0 { try c.encode(omitted, forKey: .o) }
        case .map(let pairs, let omitted):
            try c.encode("%", forKey: .t)
            try c.encode(pairs.map { [$0.key, $0.value] }, forKey: .v)
            if omitted != 0 { try c.encode(omitted, forKey: .o) }
        }
    }

    private var isSet: Bool {
        if case .set = self { return true }
        return false
    }

    /// The elements of an array or set (a map's keys and values in turn), else nil.
    public var elements: [RedisValue]? {
        switch self {
        case .array(let items, _), .set(let items, _): items
        case .map(let pairs, _): pairs.flatMap { [$0.key, $0.value] }
        default: nil
        }
    }

    /// Elements the runner left out of an aggregate (a map's pairs count twice).
    public var omitted: Int {
        switch self {
        case .array(_, let omitted), .set(_, let omitted): omitted
        case .map(_, let omitted): omitted * 2
        default: 0
        }
    }

    public var isError: Bool {
        if case .error = self { return true }
        return false
    }

    public var isAggregate: Bool { elements != nil }

    /// A cell's text: the string itself, `(nil)`, `5`, `OK`, …
    public var text: String {
        switch self {
        case .string(let text): text
        case .clipped(let text, let omitted): text + (omitted < 0 ? "… (truncated)" : "… (\(ByteCountFormatter.string(fromByteCount: Int64(omitted), countStyle: .memory)) more)")
        case .binary(let bytes, let hex): "0x\(hex)\(bytes * 2 > hex.count ? "…" : "") (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)) binary)"
        case .status(let text): text
        case .error(let text): "(error) " + text
        case .integer(let value): String(value)
        case .double(let text): text
        case .bool(let value): value ? "true" : "false"
        case .null: "(nil)"
        case .array(let items, let omitted), .set(let items, let omitted): "[\(items.count + omitted) element\(items.count + omitted == 1 ? "" : "s")]"
        case .map(let pairs, let omitted): "{\(pairs.count + omitted) pair\(pairs.count + omitted == 1 ? "" : "s")}"
        }
    }

    /// The value as a number (integers, doubles, and numeric strings), for sorting.
    public var number: Double? {
        switch self {
        case .integer(let value): Double(value)
        case .double(let text): Double(text)
        case .string(let text): Double(text)
        default: nil
        }
    }

    /// The text of a string-like reply (a key, a field), nil for others.
    public var stringValue: String? {
        switch self {
        case .string(let text), .status(let text), .double(let text): text
        case .clipped(let text, _): text
        case .integer(let value): String(value)
        default: nil
        }
    }

    /// redis-cli's rendering, for Copy Output: `"text"`, `(integer) 5`, `(nil)`, numbered elements.
    public func cliText(indent: Int = 0) -> String {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
        }
        switch self {
        case .string(let text): return quoted(text)
        case .clipped(let text, _): return quoted(text) + " (truncated)"
        case .binary: return self.text
        case .status(let text): return text
        case .error(let text): return "(error) " + text
        case .integer(let value): return "(integer) \(value)"
        case .double(let text): return "(double) " + text
        case .bool(let value): return value ? "(true)" : "(false)"
        case .null: return "(nil)"
        case .array, .set, .map:
            let items = elements ?? []
            if items.isEmpty, omitted == 0 { return self.isSet ? "(empty set)" : "(empty array)" }
            let width = String(items.count).count
            var lines: [String] = []
            for (index, item) in items.enumerated() {
                let number = String(index + 1)
                let prefix = String(repeating: " ", count: width - number.count) + number + ") "
                let rendered = item.cliText(indent: indent + prefix.count)
                lines.append((index == 0 ? "" : String(repeating: " ", count: indent)) + prefix + rendered)
            }
            if omitted > 0 { lines.append(String(repeating: " ", count: indent) + "… \(omitted.formatted()) more not shown") }
            return lines.joined(separator: "\n")
        }
    }

    /// A value tree for the output's value view (nested replies, scalars with the string viewers).
    public func valueNode(nextId: inout Int) -> ValueNode {
        nextId += 1
        let id = nextId
        switch self {
        case .string(let text):
            var node = ValueNode(id: id, type: .string, scalar: text)
            node.length = text.utf8.count
            return node
        case .clipped(let text, let omitted):
            var node = ValueNode(id: id, type: .string, scalar: text)
            node.length = omitted < 0 ? nil : text.utf8.count + omitted
            if omitted != 0 { node.truncation = ValueNode.Truncation(reason: "length", omitted: omitted) }
            return node
        case .binary, .error, .status:
            return ValueNode(id: id, type: .string, className: isError ? "error" : nil, scalar: text)
        case .integer(let value): return ValueNode(id: id, type: .int, scalar: String(value))
        case .double(let text): return ValueNode(id: id, type: .float, scalar: text)
        case .bool(let value): return ValueNode(id: id, type: .bool, scalar: value ? "true" : "false")
        case .null: return ValueNode(id: id, type: .null)
        case .array(let items, let omitted), .set(let items, let omitted):
            var entries: [ValueNode.Entry] = []
            for (index, item) in items.enumerated() {
                entries.append(ValueNode.Entry(key: String(index), keyType: "int", value: item.valueNode(nextId: &nextId)))
            }
            var node = ValueNode(id: id, type: .array, entries: entries)
            node.count = items.count + omitted
            if omitted > 0 { node.truncation = ValueNode.Truncation(reason: "children", omitted: omitted) }
            return node
        case .map(let pairs, let omitted):
            var entries: [ValueNode.Entry] = []
            for pair in pairs {
                entries.append(ValueNode.Entry(key: pair.key.stringValue ?? pair.key.text, keyType: "string", value: pair.value.valueNode(nextId: &nextId)))
            }
            var node = ValueNode(id: id, type: .array, entries: entries)
            node.count = pairs.count + omitted
            if omitted > 0 { node.truncation = ValueNode.Truncation(reason: "children", omitted: omitted) }
            return node
        }
    }
}

public struct RedisPair: Sendable, Equatable, Hashable {
    public var key: RedisValue
    public var value: RedisValue

    public init(key: RedisValue, value: RedisValue) {
        self.key = key
        self.value = value
    }
}

/// How a reply is shown (#190), from the command that produced it: hashes, sorted sets with
/// scores, sets, lists, streams, and SCAN pages as tables; everything else as a value.
public struct RedisReplyView: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// A scalar or a nested reply, shown as a value (strings get the string viewers).
        case value
        case error
        /// SCAN's keys.
        case keys
        case list
        case set
        /// Field/value pairs: HGETALL, HSCAN, CONFIG GET, …
        case hash
        /// Member/score pairs: ZRANGE … WITHSCORES, ZSCAN, ZPOPMIN, …
        case zset
        /// Stream entries: XRANGE, XREVRANGE, XREAD.
        case stream
    }

    public var kind: Kind
    /// The rows of a table kind; empty for `value` and `error`.
    public var table: ValueTable
    /// Rows (elements, pairs, entries) the runner left out.
    public var omitted: Int
    /// SCAN, HSCAN, SSCAN, ZSCAN: the cursor of the next page ("0": the scan is complete).
    public var cursor: String?

    public var isTable: Bool { kind != .value && kind != .error }

    /// "3 fields", "12 members", "1,000 of 4,212 elements".
    public var countText: String? {
        let rows = table.rows.count
        let noun: (String, String) = switch kind {
        case .keys: ("key", "keys")
        case .list: ("element", "elements")
        case .set, .zset: ("member", "members")
        case .hash: ("field", "fields")
        case .stream: ("entry", "entries")
        case .value, .error: ("", "")
        }
        guard isTable else { return nil }
        if omitted > 0 { return "First \(rows.formatted()) of \((rows + omitted).formatted()) \(noun.1)" }
        return "\(rows.formatted()) \(rows == 1 ? noun.0 : noun.1)"
    }

    /// The view of `reply` to `arguments` (the command, upper or lower case).
    public static func make(arguments: [String], reply: RedisValue) -> RedisReplyView {
        let empty = ValueTable(columns: [], rowKeys: [], rows: [], rowFields: [], omittedRows: 0)
        if reply.isError { return RedisReplyView(kind: .error, table: empty, omitted: 0, cursor: nil) }
        let upper = arguments.map { $0.uppercased() }
        let key = RedisCommands.key(arguments)
        let withScores = upper.contains("WITHSCORES") || upper.contains("WITHSCORE")
        func value() -> RedisReplyView { RedisReplyView(kind: .value, table: empty, omitted: 0, cursor: nil) }
        switch key {
        case "SCAN", "HSCAN", "SSCAN", "ZSCAN":
            guard case .array(let parts, _) = reply, parts.count == 2, let cursor = parts[0].stringValue, let items = parts[1].elements else { return value() }
            let inner: RedisReplyView = switch key {
            case "HSCAN": pairs(parts[1], kind: .hash, items: items) ?? list(items, kind: .list, omitted: parts[1].omitted)
            case "ZSCAN": pairs(parts[1], kind: .zset, items: items) ?? list(items, kind: .list, omitted: parts[1].omitted)
            case "SSCAN": list(items, kind: .set, omitted: parts[1].omitted)
            default: list(items, kind: .keys, omitted: parts[1].omitted)
            }
            var view = inner
            view.cursor = cursor
            return view
        case "HGETALL", "CONFIG|GET":
            return pairs(reply, kind: .hash, items: reply.elements ?? []) ?? value()
        case "HRANDFIELD" where upper.contains("WITHVALUES"):
            return pairs(reply, kind: .hash, items: reply.elements ?? []) ?? value()
        case "ZRANGE", "ZRANGEBYSCORE", "ZREVRANGE", "ZREVRANGEBYSCORE", "ZRANGEBYLEX", "ZREVRANGEBYLEX", "ZRANDMEMBER", "ZUNION", "ZINTER", "ZDIFF":
            if withScores { return pairs(reply, kind: .zset, items: reply.elements ?? []) ?? value() }
            guard let items = reply.elements, items.allSatisfy({ !$0.isAggregate }) else { return value() }
            return list(items, kind: .set, omitted: reply.omitted)
        case "ZPOPMIN", "ZPOPMAX":
            return pairs(reply, kind: .zset, items: reply.elements ?? []) ?? value()
        case "SMEMBERS", "SINTER", "SUNION", "SDIFF", "SRANDMEMBER", "SPOP", "KEYS":
            guard let items = reply.elements, items.allSatisfy({ !$0.isAggregate }) else { return value() }
            return list(items, kind: key == "KEYS" ? .keys : .set, omitted: reply.omitted)
        case "XRANGE", "XREVRANGE":
            return stream(reply, streamKey: nil) ?? value()
        case "XREAD", "XREADGROUP":
            return streams(reply) ?? value()
        case "LRANGE":
            guard let items = reply.elements, items.allSatisfy({ !$0.isAggregate }) else { return value() }
            let start = arguments.count > 2 ? Int(arguments[2]).flatMap { $0 >= 0 ? $0 : nil } ?? 0 : 0
            return list(items, kind: .list, omitted: reply.omitted, firstIndex: start)
        default:
            if case .set(let items, let omitted) = reply, items.allSatisfy({ !$0.isAggregate }) { return list(items, kind: .set, omitted: omitted) }
            if case .map = reply { return pairs(reply, kind: .hash, items: reply.elements ?? []) ?? value() }
            if case .array(let items, let omitted) = reply, !items.isEmpty, items.allSatisfy({ !$0.isAggregate }) {
                return list(items, kind: .list, omitted: omitted)
            }
            return value()
        }
    }

    private static func cell(_ value: RedisValue) -> ValueTable.Cell {
        ValueTable.Cell(text: value.text, number: value.number, isNull: value == .null)
    }

    private static func node(_ value: RedisValue) -> ValueNode {
        var id = 0
        return value.valueNode(nextId: &id)
    }

    private static func list(_ items: [RedisValue], kind: Kind, omitted: Int, firstIndex: Int = 0) -> RedisReplyView {
        let column = kind == .keys ? "key" : kind == .set ? "member" : "value"
        let keys = items.indices.map { String(kind == .list ? $0 + firstIndex : $0 + 1) }
        let table = ValueTable(columns: [column], rowKeys: keys, rows: items.map { [cell($0)] },
                               rowFields: items.map { [ValueTable.Field(key: column, keyType: "string", value: node($0))] }, omittedRows: omitted)
        return RedisReplyView(kind: kind, table: table, omitted: omitted, cursor: nil)
    }

    /// Field/value or member/score pairs: a flat array (RESP2), a map, or an array of pairs (RESP3).
    private static func pairs(_ reply: RedisValue, kind: Kind, items: [RedisValue]) -> RedisReplyView? {
        var pairs: [(RedisValue, RedisValue)] = []
        var omitted = 0
        if case .map(let found, let left) = reply {
            pairs = found.map { ($0.key, $0.value) }
            omitted = left
        } else if !items.isEmpty, items.allSatisfy({ if case .array(let pair, _) = $0 { pair.count == 2 } else { false } }) {
            pairs = items.compactMap { item in item.elements.map { ($0[0], $0[1]) } }
            omitted = reply.omitted
        } else {
            guard items.count % 2 == 0, items.allSatisfy({ !$0.isAggregate }) else { return nil }
            pairs = stride(from: 0, to: items.count, by: 2).map { (items[$0], items[$0 + 1]) }
            omitted = (reply.omitted + 1) / 2
        }
        let columns = kind == .zset ? ["member", "score"] : ["field", "value"]
        let table = ValueTable(columns: columns, rowKeys: pairs.indices.map { String($0 + 1) },
                               rows: pairs.map { [cell($0.0), cell($0.1)] },
                               rowFields: pairs.map { [ValueTable.Field(key: columns[0], keyType: "string", value: node($0.0)), ValueTable.Field(key: columns[1], keyType: "string", value: node($0.1))] },
                               omittedRows: omitted)
        return RedisReplyView(kind: kind, table: table, omitted: omitted, cursor: nil)
    }

    /// Stream entries `[[id, [field, value, …]], …]`: an id column and one column per field
    /// (the first 30 field names, in order of appearance).
    private static func stream(_ reply: RedisValue, streamKey: String?) -> RedisReplyView? {
        guard let entries = reply.elements else { return nil }
        return streamTable([(streamKey, entries, reply.omitted)])
    }

    /// XREAD's `[[key, entries], …]` (or a RESP3 map of key to entries).
    private static func streams(_ reply: RedisValue) -> RedisReplyView? {
        var groups: [(String?, [RedisValue], Int)] = []
        if case .map(let pairs, _) = reply {
            for pair in pairs {
                guard let entries = pair.value.elements else { return nil }
                groups.append((pair.key.stringValue, entries, pair.value.omitted))
            }
        } else if let items = reply.elements {
            for item in items {
                guard let parts = item.elements, parts.count == 2, let entries = parts[1].elements else { return nil }
                groups.append((parts[0].stringValue, entries, parts[1].omitted))
            }
        } else {
            return nil
        }
        return streamTable(groups, showsKey: true)
    }

    private static func streamTable(_ groups: [(String?, [RedisValue], Int)], showsKey: Bool = false) -> RedisReplyView? {
        var fieldNames: [String] = []
        var rows: [(key: String?, id: RedisValue, fields: [(String, RedisValue)])] = []
        var omitted = 0
        for (key, entries, left) in groups {
            omitted += left
            for entry in entries {
                guard let parts = entry.elements, parts.count == 2, let values = parts[1].elements else { return nil }
                var fields: [(String, RedisValue)] = []
                var index = 0
                while index + 1 < values.count {
                    let name = values[index].stringValue ?? values[index].text
                    fields.append((name, values[index + 1]))
                    if !fieldNames.contains(name), fieldNames.count < 30 { fieldNames.append(name) }
                    index += 2
                }
                rows.append((key, parts[0], fields))
            }
        }
        let columns = (showsKey ? ["stream"] : []) + ["id"] + fieldNames
        let table = ValueTable(
            columns: columns,
            rowKeys: rows.indices.map { String($0 + 1) },
            rows: rows.map { row in
                (showsKey ? [ValueTable.Cell(text: row.key ?? "")] : []) + [cell(row.id)]
                    + fieldNames.map { name in row.fields.first { $0.0 == name }.map { cell($0.1) } ?? ValueTable.Cell(text: "", isNull: true) }
            },
            rowFields: rows.map { row in
                (showsKey ? [ValueTable.Field(key: "stream", keyType: "string", value: node(.string(row.key ?? "")))] : [])
                    + [ValueTable.Field(key: "id", keyType: "string", value: node(row.id))]
                    + row.fields.map { ValueTable.Field(key: $0.0, keyType: "string", value: node($0.1)) }
            },
            omittedRows: omitted
        )
        return RedisReplyView(kind: .stream, table: table, omitted: omitted, cursor: nil)
    }
}

/// The runner's `redis` event (#190): one command's reply, with what ran where.
public struct RedisReplyInfo: Sendable, Codable, Equatable {
    /// The command as sent, each argument as text (passwords as `•••`; long arguments shortened).
    public var argv: [String]
    public var reply: RedisValue { didSet { view = RedisReplyView.make(arguments: argv, reply: reply) } }
    /// How the reply is shown, made once with the reply (where the event is decoded). Not part
    /// of the event.
    public private(set) var view: RedisReplyView
    /// Sending and reading, measured by the runner.
    public var elapsedMs: Double?
    /// The application connection's name (nil: its default), or the saved connection's name.
    public var connection: String?
    /// The command ran on a saved connection (#138).
    public var saved: Bool?
    /// Where the connection came from: `Laravel Redis::connection()`, `saved connection "Cache"
    /// (redis, 127.0.0.1:6379/0)`.
    public var source: String?
    /// The application's Redis connection names (the default first), for the picker.
    public var connections: [String]?
    /// The database the command ran in, when known.
    public var db: Int?
    /// Run All: which command of the run this is.
    public var statement: SQLResultInfo.StatementInfo?
    /// The element cap the run used.
    public var maxElements: Int?
    /// Bytes of the reply's strings, as the runner counted them against its cap.
    public var bytes: Int?
    /// The reply came from EXEC: the command ran in Runlet's MULTI/EXEC transaction.
    public var transaction: Bool?
    /// Load More: how many pages the reply holds (nil: one). Not part of the event.
    public var pages: Int?

    public init(argv: [String], reply: RedisValue, elapsedMs: Double? = nil, connection: String? = nil, saved: Bool? = nil, source: String? = nil, connections: [String]? = nil, db: Int? = nil, statement: SQLResultInfo.StatementInfo? = nil, maxElements: Int? = nil, bytes: Int? = nil, transaction: Bool? = nil) {
        self.argv = argv
        self.reply = reply
        view = RedisReplyView.make(arguments: argv, reply: reply)
        self.elapsedMs = elapsedMs
        self.connection = connection
        self.saved = saved
        self.source = source
        self.connections = connections
        self.db = db
        self.statement = statement
        self.maxElements = maxElements
        self.bytes = bytes
        self.transaction = transaction
    }

    enum CodingKeys: String, CodingKey {
        case argv, reply, elapsedMs, connection, saved, source, connections, db, statement, maxElements, bytes, transaction
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        argv = (try? c.decodeIfPresent([String].self, forKey: .argv)) ?? []
        reply = try c.decodeIfPresent(RedisValue.self, forKey: .reply) ?? .null
        view = RedisReplyView.make(arguments: argv, reply: reply)
        elapsedMs = try? c.decodeIfPresent(Double.self, forKey: .elapsedMs)
        connection = try? c.decodeIfPresent(String.self, forKey: .connection)
        saved = try? c.decodeIfPresent(Bool.self, forKey: .saved)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        connections = try? c.decodeIfPresent([String].self, forKey: .connections)
        db = try? c.decodeIfPresent(Int.self, forKey: .db)
        statement = try? c.decodeIfPresent(SQLResultInfo.StatementInfo.self, forKey: .statement)
        maxElements = try? c.decodeIfPresent(Int.self, forKey: .maxElements)
        bytes = try? c.decodeIfPresent(Int.self, forKey: .bytes)
        transaction = try? c.decodeIfPresent(Bool.self, forKey: .transaction)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(argv, forKey: .argv)
        try c.encode(reply, forKey: .reply)
        try c.encodeIfPresent(elapsedMs, forKey: .elapsedMs)
        try c.encodeIfPresent(connection, forKey: .connection)
        try c.encodeIfPresent(saved, forKey: .saved)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(connections, forKey: .connections)
        try c.encodeIfPresent(db, forKey: .db)
        try c.encodeIfPresent(statement, forKey: .statement)
        try c.encodeIfPresent(maxElements, forKey: .maxElements)
        try c.encodeIfPresent(bytes, forKey: .bytes)
        try c.encodeIfPresent(transaction, forKey: .transaction)
    }

    /// The command as one line: `HGETALL user:1`.
    public var commandText: String {
        argv.map { RedisScript.quoted($0) == $0 || $0 == "•••" ? $0 : RedisScript.quoted($0) }.joined(separator: " ")
    }

    /// The command's name: `HGETALL`, `CONFIG GET`.
    public var name: String { RedisCommands.classify(argv).name }

    /// "3 fields", "OK", "(integer) 5", "(nil)", "WRONGTYPE …".
    public var summary: String {
        if let count = view.countText { return count }
        switch reply {
        case .integer(let value): return "(integer) \(value)"
        case .null: return "(nil)"
        case .status(let text): return text
        case .error(let text): return text
        case .string(let text), .clipped(let text, _): return "\(text.utf8.count.formatted()) byte\(text.utf8.count == 1 ? "" : "s")"
        case .binary(let bytes, _): return "\(bytes.formatted()) bytes, binary"
        default: return reply.text
        }
    }

    /// "0.42 ms"
    public var elapsedText: String? {
        elapsedMs.map { $0 < 10 ? String(format: "%.2f ms", $0) : String(format: "%.0f ms", $0) }
    }

    /// The line under a reply: `via saved connection "Cache" (redis, 127.0.0.1:6379/0)`, or
    /// `connection “cache” · db 1 · via Laravel Redis::connection()`.
    public var originText: String {
        var parts: [String] = []
        if saved == true {
            parts.append(source.map { "via \($0)" } ?? "via saved connection “\(connection ?? "")”")
        } else {
            parts.append(connection.map { "connection “\($0)”" } ?? "default connection")
            if let db { parts.append("db \(db)") }
            if let source { parts.append("via \(source)") }
        }
        if transaction == true { parts.append("in MULTI/EXEC") }
        return parts.joined(separator: " · ")
    }

    /// Load More: this reply with `page`'s rows after its own (a SCAN page, the next LRANGE or
    /// ZRANGE range). Nil when the page's shape differs.
    public func appending(_ page: RedisReplyInfo) -> RedisReplyInfo? {
        guard view.isTable, page.view.kind == view.kind, page.view.table.columns == view.table.columns || view.kind == .stream else { return nil }
        var copy = self
        var table = view.table
        let added = page.view.table
        let base = table.rows.count
        if view.kind == .stream, added.columns != table.columns { return nil }
        table.rowKeys += added.rowKeys.indices.map { index in
            view.kind == .list ? added.rowKeys[index] : String(base + index + 1)
        }
        table.rows += added.rows
        table.rowFields += added.rowFields
        table.omittedRows = page.view.omitted
        copy.view = RedisReplyView(kind: view.kind, table: table, omitted: page.view.omitted, cursor: page.view.cursor)
        copy.elapsedMs = page.elapsedMs.map { $0 + (elapsedMs ?? 0) } ?? elapsedMs
        copy.bytes = (bytes ?? 0) + (page.bytes ?? 0)
        copy.pages = (pages ?? 1) + 1
        return copy
    }

    /// redis-cli's text, for Copy Output.
    public var plainText: String {
        var head = "Redis" + (statement.map { " (\($0.title))" } ?? "") + ": " + commandText
        if let elapsedText { head += " (\(elapsedText))" }
        return head + "\n" + reply.cliText()
    }

    /// Copy Output as Markdown.
    public var markdown: String {
        "### Redis" + (statement.map { " — " + MarkdownText.inline($0.title) } ?? "") + ": " + MarkdownText.inline(summary) + (elapsedText.map { " (\($0))" } ?? "")
            + "\n\n" + MarkdownText.fence(commandText, language: "text") + "\n\n" + MarkdownText.fence(reply.cliText(), language: "text")
    }
}
