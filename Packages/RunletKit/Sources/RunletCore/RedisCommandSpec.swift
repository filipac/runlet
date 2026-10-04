import Foundation

/// One argument of a Redis command's syntax (#218, shared with completion, #206), modelled on
/// Redis's `COMMAND DOCS`: a typed value, a pure token (`NX`), one of several (`NX | XX`), or a
/// block (`LIMIT offset count`); optional or required, once or repeated, with a token before it
/// (`EX seconds`) or before each repetition (`GET pattern [GET pattern ...]`).
public struct RedisArgument: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable, Equatable, Hashable {
        /// A key name: completed from the key browser's last scan.
        case key
        case string
        case integer
        case double
        /// A glob-style pattern (`MATCH user:*`).
        case pattern
        /// A Unix time (seconds or milliseconds, by `unit`).
        case unixTime
        /// The token itself (`NX`, `WITHSCORES`).
        case pureToken
        /// `numkeys`: the number of rows of the next argument, written by the builder.
        case count
        /// One of `children`.
        case oneOf
        /// `children` in order.
        case block
    }

    /// What a number counts, for durations: `EX seconds`, `PX milliseconds`.
    public enum Unit: String, Sendable, Equatable, Hashable {
        case seconds, milliseconds
    }

    /// The argument's name in the syntax (`key`, `seconds`, `condition`).
    public var name: String
    public var kind: Kind
    /// The word before the value (`EX` of `EX seconds`, `LIMIT` of `LIMIT offset count`).
    public var token: String?
    public var isOptional = false
    public var isMultiple = false
    /// A repeated argument whose token comes before every repetition (`GET pattern [GET pattern ...]`).
    public var tokenEachRow = false
    /// A repeated block written column by column: `STREAMS key [key ...] id [id ...]`.
    public var isColumnwise = false
    public var children: [RedisArgument] = []
    public var unit: Unit?
    /// Values to offer (`INFO` sections, `SCAN … TYPE` types).
    public var suggestions: [String] = []
    /// What to show in an empty field (`0`, `-1`, `-inf`).
    public var placeholder: String?

    public init(name: String, kind: Kind, token: String? = nil, children: [RedisArgument] = []) {
        self.name = name
        self.kind = kind
        self.token = token
        self.children = children
    }

    // MARK: Building the table

    public static func key(_ name: String = "key") -> Self { Self(name: name, kind: .key) }
    public static func string(_ name: String) -> Self { Self(name: name, kind: .string) }
    public static func integer(_ name: String) -> Self { Self(name: name, kind: .integer) }
    public static func double(_ name: String) -> Self { Self(name: name, kind: .double) }
    public static func pattern(_ name: String = "pattern") -> Self { Self(name: name, kind: .pattern) }
    public static func unixTime(_ name: String, _ unit: Unit) -> Self { Self(name: name, kind: .unixTime).unit(unit) }
    public static func token(_ token: String) -> Self { Self(name: token.lowercased(), kind: .pureToken, token: token) }
    public static func count(_ name: String) -> Self { Self(name: name, kind: .count) }
    public static func oneOf(_ name: String, _ branches: [Self]) -> Self { Self(name: name, kind: .oneOf, children: branches) }
    public static func block(_ name: String, _ children: [Self]) -> Self { Self(name: name, kind: .block, children: children) }

    public var optional: Self { with { $0.isOptional = true } }
    public var multiple: Self { with { $0.isMultiple = true } }
    public var columnwise: Self { with { $0.isColumnwise = true } }
    /// The token before the value: `.integer("seconds").prefixed("EX")`.
    public func prefixed(_ token: String) -> Self { with { $0.token = token } }
    /// The token before each repetition: `.pattern().prefixedEach("GET")`.
    public func prefixedEach(_ token: String) -> Self { with { $0.token = token; $0.isMultiple = true; $0.tokenEachRow = true } }
    public func unit(_ unit: Unit) -> Self { with { $0.unit = unit } }
    public func suggest(_ values: [String]) -> Self { with { $0.suggestions = values } }
    public func hint(_ placeholder: String) -> Self { with { $0.placeholder = placeholder } }

    private func with(_ change: (inout Self) -> Void) -> Self {
        var copy = self
        change(&copy)
        return copy
    }

    // MARK: Reading it

    /// A value typed in a field (a key, a string, a number), not a token or a group.
    public var isValue: Bool {
        switch kind {
        case .key, .string, .integer, .double, .pattern, .unixTime: true
        case .pureToken, .count, .oneOf, .block: false
        }
    }

    /// The words this argument can start with, upper case, when it always starts with a token:
    /// `EX` for `EX seconds`, `MAXLEN` and `MINID` for XADD's trimming block. Empty when it
    /// can start with a value.
    public var leadingTokens: Set<String> {
        if let token { return [token.uppercased()] }
        switch kind {
        case .oneOf:
            let branches = children.map(\.leadingTokens)
            return branches.contains(where: \.isEmpty) ? [] : branches.reduce(into: Set<String>()) { $0.formUnion($1) }
        case .block:
            guard let first = children.first, !first.isOptional else { return [] }
            return first.leadingTokens
        default:
            return []
        }
    }

    /// The argument as Redis's docs write it: `[EX seconds | PX milliseconds]`, `key [key ...]`.
    public var syntax: String {
        var core: String
        switch kind {
        case .pureToken:
            core = token ?? name
        case .oneOf:
            core = children.map(\.syntax).joined(separator: " | ")
            if token != nil || !isOptional { core = "<" + core + ">" }
        case .block:
            core = children.map(\.syntax).joined(separator: " ")
        default:
            core = name
        }
        if kind != .pureToken, let token { core = token + " " + core }
        if isMultiple {
            core = tokenEachRow || token == nil ? "\(core) [\(core) ...]" : "\(token!) \(Self.withoutToken(self).syntax) [\(Self.withoutToken(self).syntax) ...]"
            if isColumnwise, kind == .block {
                let prefix = token.map { $0 + " " } ?? ""
                core = prefix + children.map { "\($0.syntax) [\($0.syntax) ...]" }.joined(separator: " ")
            }
        }
        return isOptional ? "[" + core + "]" : core
    }

    private static func withoutToken(_ argument: Self) -> Self {
        var copy = argument
        copy.token = nil
        copy.isMultiple = false
        copy.isOptional = false
        return copy
    }
}

/// A Redis command Runlet knows the syntax of (#218): the command builder's form and, later,
/// completion (#206) come from these. Its class (read, write, dangerous, …) comes from
/// `RedisCommands`, the table every run is checked with; `access` is what Redis's own command
/// flags say, and `RedisCommandBuilderTests` checks the two agree.
public struct RedisCommandSpec: Sendable, Equatable, Hashable, Identifiable {
    /// The picker's groups: Redis's data types, then keys and the server.
    public enum Group: String, Sendable, CaseIterable, Hashable {
        case string, hash, list, set, sortedSet, stream, keys, server

        public var title: String {
            switch self {
            case .string: "Strings"
            case .hash: "Hashes"
            case .list: "Lists"
            case .set: "Sets"
            case .sortedSet: "Sorted Sets"
            case .stream: "Streams"
            case .keys: "Keys"
            case .server: "Server"
            }
        }

        /// The key type it works on (`TYPE`'s answer), for the key browser's suggestions.
        public var keyType: String? {
            switch self {
            case .string: "string"
            case .hash: "hash"
            case .list: "list"
            case .set: "set"
            case .sortedSet: "zset"
            case .stream: "stream"
            case .keys, .server: nil
            }
        }
    }

    /// `GET`, or `XINFO STREAM` for a container's subcommand.
    public var name: String
    public var group: Group
    /// Read, write, or connection, as Redis's command flags have it.
    public var access: RedisCommands.Access
    public var summary: String
    public var arguments: [RedisArgument]

    public init(_ name: String, _ group: Group, _ access: RedisCommands.Access, _ summary: String, _ arguments: [RedisArgument] = []) {
        self.name = name
        self.group = group
        self.access = access
        self.summary = summary
        self.arguments = arguments
    }

    public var id: String { name }

    /// The command's own words: `["XINFO", "STREAM"]`.
    public var words: [String] { name.split(separator: " ").map(String.init) }

    /// `RedisCommands`' key: `XINFO|STREAM`.
    public var tableKey: String { words.joined(separator: "|") }

    /// How Runlet classifies it before every run (read-only refusals, confirmations).
    public var info: RedisCommands.Info { RedisCommands.classify(words) }

    /// `ZRANGE key start stop [BYSCORE | BYLEX] [REV] [LIMIT offset count] [WITHSCORES]`
    public var syntax: String {
        ([name] + arguments.map(\.syntax)).joined(separator: " ")
    }

    /// Whether `query` finds it in the picker: its name, its words, its group, or its summary.
    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return name.range(of: query, options: .caseInsensitive) != nil
            || summary.range(of: query, options: .caseInsensitive) != nil
            || group.title.range(of: query, options: .caseInsensitive) != nil
    }

    /// How well it matches `query`, for sorting search results: the name first.
    public func rank(_ query: String) -> Int {
        let query = query.trimmingCharacters(in: .whitespaces).uppercased()
        if name == query { return 0 }
        if name.hasPrefix(query) { return 1 }
        if name.contains(query) { return 2 }
        return 3
    }
}

/// The commands the builder (#218) and completion (#206) know, by data type: the common ones of
/// every type, SCAN and its family, and the server's read commands. Other commands get a form
/// of raw arguments.
public enum RedisCommandSpecs {
    public static let all: [RedisCommandSpec] = strings + keys + hashes + lists + sets + sortedSets + streams + server

    /// By `RedisCommands`' key (`GET`, `XINFO|STREAM`).
    public static let byKey: [String: RedisCommandSpec] = Dictionary(all.map { ($0.tableKey, $0) }, uniquingKeysWith: { first, _ in first })

    /// The spec of a command line (its arguments, the name first), with how many of its words
    /// name the command (2 for `XINFO STREAM key`); nil when Runlet has none.
    public static func spec(for arguments: [String]) -> (spec: RedisCommandSpec, words: Int)? {
        guard let first = arguments.first?.uppercased(), !first.isEmpty else { return nil }
        if RedisCommands.containers.contains(first), arguments.count > 1, let spec = byKey[first + "|" + arguments[1].uppercased()] {
            return (spec, 2)
        }
        return byKey[first].map { ($0, 1) }
    }

    public static func spec(named name: String) -> RedisCommandSpec? {
        byKey[name.uppercased().split(separator: " ").joined(separator: "|")]
    }

    /// The picker's list: matching `query`, by group in `Group` order (search results by rank).
    public static func grouped(matching query: String = "") -> [(group: RedisCommandSpec.Group, commands: [RedisCommandSpec])] {
        let found = all.filter { $0.matches(query) }
        return RedisCommandSpec.Group.allCases.compactMap { group in
            let commands = found.filter { $0.group == group }
            guard !commands.isEmpty else { return nil }
            let sorted = query.isEmpty ? commands : commands.sorted { ($0.rank(query), $0.name) < ($1.rank(query), $1.name) }
            return (group, sorted)
        }
    }

    // MARK: Shared pieces

    private typealias A = RedisArgument

    private static let expiryCondition = A.oneOf("condition", [.token("NX"), .token("XX"), .token("GT"), .token("LT")]).optional
    private static let expiration = A.oneOf("expiration", [
        .integer("seconds").prefixed("EX").unit(.seconds),
        .integer("milliseconds").prefixed("PX").unit(.milliseconds),
        .unixTime("unix-time-seconds", .seconds).prefixed("EXAT"),
        .unixTime("unix-time-milliseconds", .milliseconds).prefixed("PXAT"),
    ])
    private static let limit = A.block("limit", [.integer("offset").hint("0"), .integer("count").hint("10")]).prefixed("LIMIT").optional
    private static let match = A.pattern().prefixed("MATCH").optional.hint("*")
    private static let scanCount = A.integer("count").prefixed("COUNT").optional.hint("10")
    private static let cursor = A.integer("cursor").hint("0")
    private static let keyTypes = ["string", "list", "set", "zset", "hash", "stream"]
    private static let rangeBound = "a rank (0, -1), a score with BYSCORE (1.5, (1, -inf, +inf), or a member with BYLEX ([a, (a, -, +)"
    private static let scoreMin = A.string("min").hint("-inf")
    private static let scoreMax = A.string("max").hint("+inf")
    private static let streamTrim = A.block("trim", [
        .oneOf("strategy", [.token("MAXLEN"), .token("MINID")]),
        .oneOf("operator", [.token("="), .token("~")]).optional,
        .string("threshold").hint("1000"),
        .integer("count").prefixed("LIMIT").optional,
    ])
    private static let fieldsBlock = A.block("fields", [.count("numfields"), .string("field").multiple]).prefixed("FIELDS")

    // MARK: Strings

    static let strings: [RedisCommandSpec] = [
        .init("GET", .string, .read, "Returns the string value of a key.", [.key()]),
        .init("SET", .string, .write, "Sets the string value of a key, with an optional expiry and condition.", [
            .key(), .string("value"),
            A.oneOf("condition", [.token("NX"), .token("XX")]).optional,
            A.token("GET").optional,
            A.oneOf("expiration", expiration.children + [.token("KEEPTTL")]).optional,
        ]),
        .init("GETEX", .string, .write, "Returns the string value of a key after setting or removing its expiry.", [
            .key(), A.oneOf("expiration", expiration.children + [.token("PERSIST")]).optional,
        ]),
        .init("GETDEL", .string, .write, "Returns the string value of a key and deletes the key.", [.key()]),
        .init("MGET", .string, .read, "Returns the values of several keys.", [A.key().multiple]),
        .init("MSET", .string, .write, "Sets several keys to their values.", [A.block("data", [.key(), .string("value")]).multiple]),
        .init("SETNX", .string, .write, "Sets a key's value only when the key doesn't exist.", [.key(), .string("value")]),
        .init("SETEX", .string, .write, "Sets a key's value and its expiry in seconds.", [.key(), A.integer("seconds").unit(.seconds), .string("value")]),
        .init("APPEND", .string, .write, "Appends a string to a key's value.", [.key(), .string("value")]),
        .init("STRLEN", .string, .read, "Returns the length of a key's value.", [.key()]),
        .init("GETRANGE", .string, .read, "Returns a substring of a key's value.", [.key(), A.integer("start").hint("0"), A.integer("end").hint("-1")]),
        .init("SETRANGE", .string, .write, "Overwrites part of a key's value from an offset.", [.key(), .integer("offset"), .string("value")]),
        .init("INCR", .string, .write, "Adds 1 to a key's integer value.", [.key()]),
        .init("INCRBY", .string, .write, "Adds a number to a key's integer value.", [.key(), .integer("increment")]),
        .init("INCRBYFLOAT", .string, .write, "Adds a floating-point number to a key's value.", [.key(), .double("increment")]),
        .init("DECR", .string, .write, "Subtracts 1 from a key's integer value.", [.key()]),
        .init("DECRBY", .string, .write, "Subtracts a number from a key's integer value.", [.key(), .integer("decrement")]),
    ]

    // MARK: Keys

    static let keys: [RedisCommandSpec] = [
        .init("SCAN", .keys, .read, "Iterates over the keys of the database, a page at a time.", [
            cursor, match, scanCount, A.string("type").prefixed("TYPE").optional.suggest(keyTypes),
        ]),
        .init("EXISTS", .keys, .read, "Counts how many of the keys exist.", [A.key().multiple]),
        .init("TYPE", .keys, .read, "Returns the type of the value stored at a key.", [.key()]),
        .init("TTL", .keys, .read, "Returns a key's time to live in seconds.", [.key()]),
        .init("PTTL", .keys, .read, "Returns a key's time to live in milliseconds.", [.key()]),
        .init("EXPIRETIME", .keys, .read, "Returns the Unix time, in seconds, at which a key expires.", [.key()]),
        .init("PEXPIRETIME", .keys, .read, "Returns the Unix time, in milliseconds, at which a key expires.", [.key()]),
        .init("EXPIRE", .keys, .write, "Sets a key's time to live in seconds.", [.key(), A.integer("seconds").unit(.seconds).hint("60"), expiryCondition]),
        .init("PEXPIRE", .keys, .write, "Sets a key's time to live in milliseconds.", [.key(), A.integer("milliseconds").unit(.milliseconds).hint("60000"), expiryCondition]),
        .init("EXPIREAT", .keys, .write, "Sets a key's expiry to a Unix time in seconds.", [.key(), .unixTime("unix-time-seconds", .seconds), expiryCondition]),
        .init("PEXPIREAT", .keys, .write, "Sets a key's expiry to a Unix time in milliseconds.", [.key(), .unixTime("unix-time-milliseconds", .milliseconds), expiryCondition]),
        .init("PERSIST", .keys, .write, "Removes a key's expiry.", [.key()]),
        .init("DEL", .keys, .write, "Deletes keys.", [A.key().multiple]),
        .init("UNLINK", .keys, .write, "Deletes keys, freeing their memory in the background.", [A.key().multiple]),
        .init("RENAME", .keys, .write, "Renames a key, overwriting the destination.", [.key(), .key("newkey")]),
        .init("RENAMENX", .keys, .write, "Renames a key only when the new name doesn't exist.", [.key(), .key("newkey")]),
        .init("COPY", .keys, .write, "Copies a key's value to another key.", [
            .key("source"), .key("destination"), A.integer("destination-db").prefixed("DB").optional, A.token("REPLACE").optional,
        ]),
        .init("MOVE", .keys, .write, "Moves a key to another database.", [.key(), .integer("db")]),
        .init("TOUCH", .keys, .read, "Updates the last access time of keys, and counts those that exist.", [A.key().multiple]),
        .init("RANDOMKEY", .keys, .read, "Returns a random key of the database."),
        .init("OBJECT ENCODING", .keys, .read, "Returns the internal encoding of a key's value.", [.key()]),
        .init("OBJECT IDLETIME", .keys, .read, "Returns the seconds since a key was last read or written.", [.key()]),
        .init("OBJECT FREQ", .keys, .read, "Returns a key's access frequency (with an LFU eviction policy).", [.key()]),
        .init("KEYS", .keys, .read, "Returns every key matching a pattern, in one call that blocks the server. Prefer SCAN.", [.pattern()]),
    ]

    // MARK: Hashes

    static let hashes: [RedisCommandSpec] = [
        .init("HGET", .hash, .read, "Returns the value of a field.", [.key(), .string("field")]),
        .init("HSET", .hash, .write, "Sets fields to their values.", [.key(), A.block("data", [.string("field"), .string("value")]).multiple]),
        .init("HSETNX", .hash, .write, "Sets a field's value only when the field doesn't exist.", [.key(), .string("field"), .string("value")]),
        .init("HMGET", .hash, .read, "Returns the values of several fields.", [.key(), A.string("field").multiple]),
        .init("HGETALL", .hash, .read, "Returns every field and value.", [.key()]),
        .init("HDEL", .hash, .write, "Deletes fields.", [.key(), A.string("field").multiple]),
        .init("HEXISTS", .hash, .read, "Whether a field exists.", [.key(), .string("field")]),
        .init("HLEN", .hash, .read, "Returns the number of fields.", [.key()]),
        .init("HKEYS", .hash, .read, "Returns every field name.", [.key()]),
        .init("HVALS", .hash, .read, "Returns every value.", [.key()]),
        .init("HSTRLEN", .hash, .read, "Returns the length of a field's value.", [.key(), .string("field")]),
        .init("HINCRBY", .hash, .write, "Adds a number to a field's integer value.", [.key(), .string("field"), .integer("increment")]),
        .init("HINCRBYFLOAT", .hash, .write, "Adds a floating-point number to a field's value.", [.key(), .string("field"), .double("increment")]),
        .init("HRANDFIELD", .hash, .read, "Returns random fields, optionally with their values.", [
            .key(), A.block("options", [.integer("count"), A.token("WITHVALUES").optional]).optional,
        ]),
        .init("HSCAN", .hash, .read, "Iterates over a hash's fields and values, a page at a time.", [.key(), cursor, match, scanCount, A.token("NOVALUES").optional]),
        .init("HEXPIRE", .hash, .write, "Sets the time to live of fields, in seconds (Redis 7.4).", [.key(), A.integer("seconds").unit(.seconds).hint("60"), expiryCondition, fieldsBlock]),
        .init("HTTL", .hash, .read, "Returns the time to live of fields, in seconds (Redis 7.4).", [.key(), fieldsBlock]),
        .init("HPERSIST", .hash, .write, "Removes the expiry of fields (Redis 7.4).", [.key(), fieldsBlock]),
    ]

    // MARK: Lists

    private static let side = A.oneOf("where", [.token("LEFT"), .token("RIGHT")])

    static let lists: [RedisCommandSpec] = [
        .init("LPUSH", .list, .write, "Prepends elements to a list.", [.key(), A.string("element").multiple]),
        .init("RPUSH", .list, .write, "Appends elements to a list.", [.key(), A.string("element").multiple]),
        .init("LPUSHX", .list, .write, "Prepends elements only when the list exists.", [.key(), A.string("element").multiple]),
        .init("RPUSHX", .list, .write, "Appends elements only when the list exists.", [.key(), A.string("element").multiple]),
        .init("LPOP", .list, .write, "Removes and returns the first elements.", [.key(), A.integer("count").optional]),
        .init("RPOP", .list, .write, "Removes and returns the last elements.", [.key(), A.integer("count").optional]),
        .init("LRANGE", .list, .read, "Returns a range of elements (0 -1: all of them).", [.key(), A.integer("start").hint("0"), A.integer("stop").hint("-1")]),
        .init("LLEN", .list, .read, "Returns the length of a list.", [.key()]),
        .init("LINDEX", .list, .read, "Returns the element at an index.", [.key(), A.integer("index").hint("0")]),
        .init("LSET", .list, .write, "Sets the element at an index.", [.key(), .integer("index"), .string("element")]),
        .init("LINSERT", .list, .write, "Inserts an element before or after another.", [.key(), .oneOf("where", [.token("BEFORE"), .token("AFTER")]), .string("pivot"), .string("element")]),
        .init("LREM", .list, .write, "Removes elements equal to a value (count 0: all of them).", [.key(), A.integer("count").hint("0"), .string("element")]),
        .init("LTRIM", .list, .write, "Keeps only a range of elements.", [.key(), A.integer("start").hint("0"), A.integer("stop").hint("99")]),
        .init("LPOS", .list, .read, "Returns the index of matching elements.", [
            .key(), .string("element"), A.integer("rank").prefixed("RANK").optional, A.integer("num-matches").prefixed("COUNT").optional, A.integer("len").prefixed("MAXLEN").optional,
        ]),
        .init("LMOVE", .list, .write, "Pops an element from one list and pushes it onto another.", [.key("source"), .key("destination"), side.with(name: "wherefrom"), side.with(name: "whereto")]),
        .init("LMPOP", .list, .write, "Pops elements from the first non-empty list.", [.count("numkeys"), A.key().multiple, side, A.integer("count").prefixed("COUNT").optional]),
        .init("BLPOP", .list, .write, "Pops the first element of the first non-empty list, waiting up to the timeout (0: forever).", [A.key().multiple, A.double("timeout").hint("5")]),
        .init("BRPOP", .list, .write, "Pops the last element of the first non-empty list, waiting up to the timeout (0: forever).", [A.key().multiple, A.double("timeout").hint("5")]),
    ]

    // MARK: Sets

    static let sets: [RedisCommandSpec] = [
        .init("SADD", .set, .write, "Adds members to a set.", [.key(), A.string("member").multiple]),
        .init("SREM", .set, .write, "Removes members from a set.", [.key(), A.string("member").multiple]),
        .init("SMEMBERS", .set, .read, "Returns every member of a set.", [.key()]),
        .init("SISMEMBER", .set, .read, "Whether a value is a member.", [.key(), .string("member")]),
        .init("SMISMEMBER", .set, .read, "Whether each value is a member.", [.key(), A.string("member").multiple]),
        .init("SCARD", .set, .read, "Returns the number of members.", [.key()]),
        .init("SPOP", .set, .write, "Removes and returns random members.", [.key(), A.integer("count").optional]),
        .init("SRANDMEMBER", .set, .read, "Returns random members (a negative count may repeat them).", [.key(), A.integer("count").optional]),
        .init("SMOVE", .set, .write, "Moves a member from one set to another.", [.key("source"), .key("destination"), .string("member")]),
        .init("SINTER", .set, .read, "Returns the intersection of sets.", [A.key().multiple]),
        .init("SUNION", .set, .read, "Returns the union of sets.", [A.key().multiple]),
        .init("SDIFF", .set, .read, "Returns the members of the first set that aren't in the others.", [A.key().multiple]),
        .init("SINTERSTORE", .set, .write, "Stores the intersection of sets in a key.", [.key("destination"), A.key().multiple]),
        .init("SUNIONSTORE", .set, .write, "Stores the union of sets in a key.", [.key("destination"), A.key().multiple]),
        .init("SDIFFSTORE", .set, .write, "Stores the difference of sets in a key.", [.key("destination"), A.key().multiple]),
        .init("SINTERCARD", .set, .read, "Counts the intersection of sets.", [.count("numkeys"), A.key().multiple, A.integer("limit").prefixed("LIMIT").optional]),
        .init("SSCAN", .set, .read, "Iterates over a set's members, a page at a time.", [.key(), cursor, match, scanCount]),
    ]

    // MARK: Sorted sets

    private static let aggregate = A.oneOf("aggregate", [.token("SUM"), .token("MIN"), .token("MAX")]).prefixed("AGGREGATE").optional
    private static let weights = A.double("weight").prefixed("WEIGHTS").multiple.optional

    static let sortedSets: [RedisCommandSpec] = [
        .init("ZADD", .sortedSet, .write, "Adds members with scores, or updates their scores.", [
            .key(),
            A.oneOf("condition", [.token("NX"), .token("XX")]).optional,
            A.oneOf("comparison", [.token("GT"), .token("LT")]).optional,
            A.token("CH").optional,
            A.token("INCR").optional,
            A.block("data", [.double("score"), .string("member")]).multiple,
        ]),
        .init("ZRANGE", .sortedSet, .read, "Returns members in a range of ranks, scores (BYSCORE), or names (BYLEX).", [
            .key(), A.string("start").hint("0"), A.string("stop").hint("-1"),
            A.oneOf("sortby", [.token("BYSCORE"), .token("BYLEX")]).optional,
            A.token("REV").optional,
            limit,
            A.token("WITHSCORES").optional,
        ]),
        .init("ZRANGEBYSCORE", .sortedSet, .read, "Returns members with scores in a range (ZRANGE … BYSCORE).", [.key(), scoreMin, scoreMax, A.token("WITHSCORES").optional, limit]),
        .init("ZREVRANGE", .sortedSet, .read, "Returns members in a range of ranks, highest score first (ZRANGE … REV).", [.key(), A.integer("start").hint("0"), A.integer("stop").hint("-1"), A.token("WITHSCORES").optional]),
        .init("ZRANGESTORE", .sortedSet, .write, "Stores a range of members in a key.", [
            .key("dst"), .key("src"), A.string("min").hint("0"), A.string("max").hint("-1"),
            A.oneOf("sortby", [.token("BYSCORE"), .token("BYLEX")]).optional, A.token("REV").optional, limit,
        ]),
        .init("ZREM", .sortedSet, .write, "Removes members.", [.key(), A.string("member").multiple]),
        .init("ZSCORE", .sortedSet, .read, "Returns a member's score.", [.key(), .string("member")]),
        .init("ZMSCORE", .sortedSet, .read, "Returns the scores of several members.", [.key(), A.string("member").multiple]),
        .init("ZINCRBY", .sortedSet, .write, "Adds to a member's score.", [.key(), .double("increment"), .string("member")]),
        .init("ZCARD", .sortedSet, .read, "Returns the number of members.", [.key()]),
        .init("ZCOUNT", .sortedSet, .read, "Counts members with scores in a range.", [.key(), scoreMin, scoreMax]),
        .init("ZLEXCOUNT", .sortedSet, .read, "Counts members in a range of names.", [.key(), A.string("min").hint("-"), A.string("max").hint("+")]),
        .init("ZRANK", .sortedSet, .read, "Returns a member's rank, lowest score first.", [.key(), .string("member"), A.token("WITHSCORE").optional]),
        .init("ZREVRANK", .sortedSet, .read, "Returns a member's rank, highest score first.", [.key(), .string("member"), A.token("WITHSCORE").optional]),
        .init("ZPOPMIN", .sortedSet, .write, "Removes and returns the members with the lowest scores.", [.key(), A.integer("count").optional]),
        .init("ZPOPMAX", .sortedSet, .write, "Removes and returns the members with the highest scores.", [.key(), A.integer("count").optional]),
        .init("ZRANDMEMBER", .sortedSet, .read, "Returns random members, optionally with their scores.", [
            .key(), A.block("options", [.integer("count"), A.token("WITHSCORES").optional]).optional,
        ]),
        .init("ZREMRANGEBYSCORE", .sortedSet, .write, "Removes members with scores in a range.", [.key(), scoreMin, scoreMax]),
        .init("ZREMRANGEBYRANK", .sortedSet, .write, "Removes members in a range of ranks.", [.key(), A.integer("start").hint("0"), A.integer("stop").hint("-1")]),
        .init("ZREMRANGEBYLEX", .sortedSet, .write, "Removes members in a range of names.", [.key(), A.string("min").hint("-"), A.string("max").hint("+")]),
        .init("ZSCAN", .sortedSet, .read, "Iterates over a sorted set's members and scores, a page at a time.", [.key(), cursor, match, scanCount]),
        .init("ZUNION", .sortedSet, .read, "Returns the union of sorted sets.", [.count("numkeys"), A.key().multiple, weights, aggregate, A.token("WITHSCORES").optional]),
        .init("ZINTER", .sortedSet, .read, "Returns the intersection of sorted sets.", [.count("numkeys"), A.key().multiple, weights, aggregate, A.token("WITHSCORES").optional]),
        .init("ZDIFF", .sortedSet, .read, "Returns the members of the first sorted set that aren't in the others.", [.count("numkeys"), A.key().multiple, A.token("WITHSCORES").optional]),
        .init("ZUNIONSTORE", .sortedSet, .write, "Stores the union of sorted sets in a key.", [.key("destination"), .count("numkeys"), A.key().multiple, weights, aggregate]),
        .init("ZINTERSTORE", .sortedSet, .write, "Stores the intersection of sorted sets in a key.", [.key("destination"), .count("numkeys"), A.key().multiple, weights, aggregate]),
        .init("ZINTERCARD", .sortedSet, .read, "Counts the intersection of sorted sets.", [.count("numkeys"), A.key().multiple, A.integer("limit").prefixed("LIMIT").optional]),
        .init("ZMPOP", .sortedSet, .write, "Pops members from the first non-empty sorted set.", [
            .count("numkeys"), A.key().multiple, .oneOf("where", [.token("MIN"), .token("MAX")]), A.integer("count").prefixed("COUNT").optional,
        ]),
    ]

    // MARK: Streams

    private static let streamsBlock = A.block("streams", [.key(), A.string("id").hint("$")]).prefixed("STREAMS").multiple.columnwise

    static let streams: [RedisCommandSpec] = [
        .init("XADD", .stream, .write, "Appends an entry to a stream, optionally trimming it.", [
            .key(),
            A.token("NOMKSTREAM").optional,
            streamTrim.optional,
            .oneOf("id", [.token("*"), A.string("id").hint("1700000000000-0")]),
            A.block("data", [.string("field"), .string("value")]).multiple,
        ]),
        .init("XRANGE", .stream, .read, "Returns entries with ids in a range (- +: all of them).", [
            .key(), A.string("start").hint("-"), A.string("end").hint("+"), A.integer("count").prefixed("COUNT").optional,
        ]),
        .init("XREVRANGE", .stream, .read, "Returns entries with ids in a range, newest first.", [
            .key(), A.string("end").hint("+"), A.string("start").hint("-"), A.integer("count").prefixed("COUNT").optional,
        ]),
        .init("XLEN", .stream, .read, "Returns the number of entries.", [.key()]),
        .init("XREAD", .stream, .read, "Reads entries after ids from streams, optionally waiting (BLOCK).", [
            A.integer("count").prefixed("COUNT").optional, A.integer("milliseconds").prefixed("BLOCK").unit(.milliseconds).optional, streamsBlock,
        ]),
        .init("XDEL", .stream, .write, "Deletes entries.", [.key(), A.string("id").multiple]),
        .init("XTRIM", .stream, .write, "Trims a stream to a length (MAXLEN) or an id (MINID).", [.key()] + streamTrim.children),
        .init("XINFO STREAM", .stream, .read, "Returns a stream's details.", [
            .key(), A.block("full", [.token("FULL"), A.integer("count").prefixed("COUNT").optional]).optional,
        ]),
        .init("XINFO GROUPS", .stream, .read, "Returns a stream's consumer groups.", [.key()]),
        .init("XINFO CONSUMERS", .stream, .read, "Returns the consumers of a group.", [.key(), .string("group")]),
        .init("XGROUP CREATE", .stream, .write, "Creates a consumer group.", [
            .key(), .string("group"), .oneOf("id", [A.string("id").hint("0"), .token("$")]), A.token("MKSTREAM").optional,
            A.integer("entries-read").prefixed("ENTRIESREAD").optional,
        ]),
        .init("XGROUP DESTROY", .stream, .write, "Deletes a consumer group.", [.key(), .string("group")]),
        .init("XREADGROUP", .stream, .write, "Reads entries as a consumer of a group.", [
            A.block("group", [.string("group"), .string("consumer")]).prefixed("GROUP"),
            A.integer("count").prefixed("COUNT").optional, A.integer("milliseconds").prefixed("BLOCK").unit(.milliseconds).optional, A.token("NOACK").optional,
            A.block("streams", [.key(), A.string("id").hint(">")]).prefixed("STREAMS").multiple.columnwise,
        ]),
        .init("XACK", .stream, .write, "Acknowledges entries of a group.", [.key(), .string("group"), A.string("id").multiple]),
        .init("XPENDING", .stream, .read, "Returns a group's pending entries.", [
            .key(), .string("group"),
            A.block("filters", [
                A.integer("min-idle-time").prefixed("IDLE").optional, A.string("start").hint("-"), A.string("end").hint("+"), A.integer("count").hint("10"), A.string("consumer").optional,
            ]).optional,
        ]),
    ]

    // MARK: Server

    private static let flushMode = A.oneOf("flush-type", [.token("ASYNC"), .token("SYNC")]).optional

    static let server: [RedisCommandSpec] = [
        .init("INFO", .server, .read, "Returns the server's information and statistics.", [
            A.string("section").multiple.optional.suggest(["server", "clients", "memory", "persistence", "stats", "replication", "cpu", "commandstats", "latencystats", "keyspace", "errorstats", "modules", "all", "everything", "default"]),
        ]),
        .init("DBSIZE", .server, .read, "Returns the number of keys in the database."),
        .init("MEMORY USAGE", .server, .read, "Returns the bytes a key and its value take in memory.", [.key(), A.integer("count").prefixed("SAMPLES").optional]),
        .init("MEMORY STATS", .server, .read, "Returns the server's memory usage details."),
        .init("MEMORY DOCTOR", .server, .read, "Reports memory problems and advice."),
        .init("PING", .server, .connection, "Checks the connection.", [A.string("message").optional]),
        .init("TIME", .server, .read, "Returns the server's time."),
        .init("LASTSAVE", .server, .read, "Returns the Unix time of the last save to disk."),
        .init("ROLE", .server, .read, "Returns the replication role."),
        .init("SELECT", .server, .connection, "Switches to another database for the rest of the run.", [A.integer("index").hint("0")]),
        .init("CONFIG GET", .server, .read, "Returns configuration parameters (glob patterns allowed).", [A.string("parameter").multiple.suggest(["maxmemory", "maxmemory-policy", "databases", "save", "appendonly", "timeout", "notify-keyspace-events", "*"])]),
        .init("CONFIG SET", .server, .write, "Changes configuration parameters for every client.", [A.block("data", [.string("parameter"), .string("value")]).multiple]),
        .init("CLIENT LIST", .server, .read, "Lists the connected clients.", [
            A.oneOf("client-type", [.token("NORMAL"), .token("MASTER"), .token("REPLICA"), .token("PUBSUB")]).prefixed("TYPE").optional,
            A.integer("client-id").prefixed("ID").multiple.optional,
        ]),
        .init("CLIENT INFO", .server, .read, "Returns this connection's details."),
        .init("CLIENT SETNAME", .server, .connection, "Names this connection.", [.string("connection-name")]),
        .init("SLOWLOG GET", .server, .read, "Returns the slow log's entries.", [A.integer("count").optional.hint("10")]),
        .init("SLOWLOG LEN", .server, .read, "Returns the number of entries in the slow log."),
        .init("SLOWLOG RESET", .server, .write, "Clears the slow log."),
        .init("LATENCY LATEST", .server, .read, "Returns the latest latency samples."),
        .init("FLUSHDB", .server, .write, "Deletes every key of the database.", [flushMode]),
        .init("FLUSHALL", .server, .write, "Deletes every key of every database.", [flushMode]),
    ]
}

private extension RedisArgument {
    func with(name: String) -> Self {
        var copy = self
        copy.name = name
        return copy
    }
}
