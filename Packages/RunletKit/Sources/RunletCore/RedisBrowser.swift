import Foundation

// MARK: - Key browser (#190)

/// One key of a SCAN page in the key browser.
public struct RedisKeyEntry: Sendable, Codable, Equatable, Hashable, Identifiable {
    /// The key as text; nil when its bytes aren't UTF-8 (`raw` holds them).
    public var key: String?
    /// The key's bytes, base64.
    public var raw: String
    public var type: String?
    /// Milliseconds to live; -1: no expiry, -2: gone.
    public var ttl: Int64?

    public init(key: String?, raw: String, type: String? = nil, ttl: Int64? = nil) {
        self.key = key
        self.raw = raw
        self.type = type
        self.ttl = ttl
    }

    public var id: String { raw }

    /// The key's bytes.
    public var bytes: [UInt8] { Data(base64Encoded: raw).map { [UInt8]($0) } ?? Array((key ?? "").utf8) }

    /// The key as shown: its text, or with `\xHH` for bytes that aren't UTF-8.
    public var displayName: String {
        if let key { return key }
        return bytes.map { $0 >= 0x20 && $0 < 0x7F ? String(UnicodeScalar($0)) : String(format: "\\x%02X", $0) }.joined()
    }

    /// "no expiry", "12 s", "3 min", "2 h 5 min", "4 d".
    public var ttlText: String { Self.ttlText(ttl) }

    public static func ttlText(_ ttl: Int64?) -> String {
        guard let ttl else { return "" }
        if ttl == -1 { return "no expiry" }
        if ttl < 0 { return "gone" }
        let seconds = Double(ttl) / 1000
        if seconds < 1 { return "\(ttl) ms" }
        if seconds < 120 { return String(format: "%.0f s", seconds) }
        if seconds < 7200 { return String(format: "%.0f min", seconds / 60) }
        if seconds < 172_800 { return "\(Int(seconds / 3600)) h \(Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)) min" }
        return String(format: "%.0f d", seconds / 86400)
    }

    /// The command Insert Command puts in the tab for the key's type.
    public var readCommand: String {
        let quoted = RedisScript.quoted(bytes)
        switch type {
        case "string": return "GET \(quoted)"
        case "hash": return "HGETALL \(quoted)"
        case "list": return "LRANGE \(quoted) 0 99"
        case "set": return "SSCAN \(quoted) 0 COUNT 100"
        case "zset": return "ZRANGE \(quoted) 0 99 WITHSCORES"
        case "stream": return "XRANGE \(quoted) - + COUNT 100"
        default: return "TYPE \(quoted)"
        }
    }
}

/// The runner's `redisKeys` event: one SCAN page of the key browser.
public struct RedisKeyPage: Sendable, Codable, Equatable {
    public struct Keyspace: Sendable, Codable, Equatable, Hashable {
        public var db: Int
        public var keys: Int
        public var expires: Int
    }

    public var db: Int
    public var pattern: String?
    /// The cursor this page was read from.
    public var cursor: String?
    /// The cursor of the next page; "0" when the scan is complete.
    public var next: String
    public var keys: [RedisKeyEntry]
    /// INFO keyspace: the databases that hold keys.
    public var keyspace: [Keyspace]?
    /// CONFIG GET databases (nil when the server refuses CONFIG).
    public var databases: Int?
    public var source: String?
    public var connections: [String]?
    public var elapsedMs: Double?

    public init(db: Int, pattern: String? = nil, cursor: String? = nil, next: String, keys: [RedisKeyEntry], keyspace: [Keyspace]? = nil, databases: Int? = nil, source: String? = nil, connections: [String]? = nil, elapsedMs: Double? = nil) {
        self.db = db
        self.pattern = pattern
        self.cursor = cursor
        self.next = next
        self.keys = keys
        self.keyspace = keyspace
        self.databases = databases
        self.source = source
        self.connections = connections
        self.elapsedMs = elapsedMs
    }

    public var isComplete: Bool { next == "0" }

    /// The database numbers to offer: 0 to `databases - 1` (16 when unknown), and any database
    /// the keyspace lists.
    public static func databaseNumbers(databases: Int?, keyspace: [Keyspace]?) -> [Int] {
        let count = min(max(databases ?? 16, 1), 256)
        var numbers = Array(0..<count)
        for entry in keyspace ?? [] where !numbers.contains(entry.db) { numbers.append(entry.db) }
        return numbers.sorted()
    }
}

/// The runner's `redisKeyInfo` event: one key's details (Memory Usage).
public struct RedisKeyDetails: Sendable, Codable, Equatable {
    public var raw: String
    public var type: String?
    public var ttl: Int64?
    public var encoding: String?
    /// MEMORY USAGE, bytes.
    public var memory: Int?
    /// Why MEMORY USAGE failed (an ACL that doesn't allow it, …).
    public var memoryError: String?
    /// Its length: bytes of a string, fields, elements, members, or entries.
    public var length: Int?

    public init(raw: String, type: String? = nil, ttl: Int64? = nil, encoding: String? = nil, memory: Int? = nil, memoryError: String? = nil, length: Int? = nil) {
        self.raw = raw
        self.type = type
        self.ttl = ttl
        self.encoding = encoding
        self.memory = memory
        self.memoryError = memoryError
        self.length = length
    }

    /// "136 B · listpack · 30 elements"
    public var summary: String {
        var parts: [String] = []
        if let memory { parts.append(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory)) }
        if let encoding { parts.append(encoding) }
        if let length {
            let noun = switch type {
            case "string": length == 1 ? "byte" : "bytes"
            case "hash": length == 1 ? "field" : "fields"
            case "list": length == 1 ? "element" : "elements"
            case "set", "zset": length == 1 ? "member" : "members"
            case "stream": length == 1 ? "entry" : "entries"
            default: "items"
            }
            parts.append("\(length.formatted()) \(noun)")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Server panel (#190)

/// The runner's `redisServer` event: INFO and CLIENT LIST, as Redis wrote them.
public struct RedisServerReport: Sendable, Codable, Equatable {
    public var info: String?
    public var infoError: String?
    public var clients: String?
    public var clientsError: String?
    /// The panel's own client (refused by Kill).
    public var ownId: Int64?
    public var source: String?
    public var connection: String?
    public var saved: Bool?
    public var elapsedMs: Double?

    public init(info: String? = nil, infoError: String? = nil, clients: String? = nil, clientsError: String? = nil, ownId: Int64? = nil, source: String? = nil, connection: String? = nil, saved: Bool? = nil, elapsedMs: Double? = nil) {
        self.info = info
        self.infoError = infoError
        self.clients = clients
        self.clientsError = clientsError
        self.ownId = ownId
        self.source = source
        self.connection = connection
        self.saved = saved
        self.elapsedMs = elapsedMs
    }

    public var sections: [RedisInfoSection] { RedisInfoSection.parse(info ?? "") }
    public var clientList: [RedisClientInfo] { RedisClientInfo.parse(clients ?? "") }

    /// INFO server's run_id: Kill checks it reaches the same server.
    public var runId: String? { sections.first { $0.name == "Server" }?.value("run_id") }

    /// "Redis 7.4.11 · standalone · up 3 days · 12 clients · 1.2 MB used"
    public var summary: String {
        let values = Dictionary(sections.flatMap(\.items).map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        var parts: [String] = []
        if let version = values["redis_version"] { parts.append("Redis \(version)") }
        if let mode = values["redis_mode"] { parts.append(mode) }
        if let uptime = values["uptime_in_seconds"].flatMap(Int.init) { parts.append("up " + Self.duration(uptime)) }
        if let clients = values["connected_clients"] { parts.append("\(clients) client\(clients == "1" ? "" : "s")") }
        if let memory = values["used_memory_human"] { parts.append("\(memory) used") }
        if let role = values["role"], role != "master" { parts.append(role) }
        return parts.joined(separator: " · ")
    }

    static func duration(_ seconds: Int) -> String {
        if seconds < 120 { return "\(seconds) s" }
        if seconds < 7200 { return "\(seconds / 60) min" }
        if seconds < 172_800 { return "\(seconds / 3600) h" }
        return "\(seconds / 86400) days"
    }
}

/// One INFO section ("# Server") and its `key:value` lines, in order.
public struct RedisInfoSection: Sendable, Equatable, Hashable, Identifiable {
    public struct Item: Sendable, Equatable, Hashable {
        public var key: String
        public var value: String
    }

    public var name: String
    public var items: [Item]
    public var id: String { name }

    public func value(_ key: String) -> String? { items.first { $0.key == key }?.value }

    public static func parse(_ text: String) -> [RedisInfoSection] {
        var sections: [RedisInfoSection] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r "))
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                sections.append(RedisInfoSection(name: line.dropFirst().trimmingCharacters(in: .whitespaces), items: []))
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            if sections.isEmpty { sections.append(RedisInfoSection(name: "Info", items: [])) }
            sections[sections.count - 1].items.append(Item(key: String(line[..<colon]), value: String(line[line.index(after: colon)...])))
        }
        return sections
    }
}

/// One client of CLIENT LIST: `id=5 addr=127.0.0.1:52341 laddr=… name= age=3 idle=0 … db=0 … cmd=client|list user=default …`.
public struct RedisClientInfo: Sendable, Equatable, Hashable, Identifiable {
    public var fields: [String: String]

    public var id: Int64 { Int64(fields["id"] ?? "") ?? 0 }
    public var address: String { fields["addr"] ?? "" }
    public var name: String { fields["name"] ?? "" }
    public var user: String { fields["user"] ?? "" }
    public var db: Int? { fields["db"].flatMap(Int.init) }
    /// The last command (`client|list`).
    public var command: String { (fields["cmd"] ?? "").replacingOccurrences(of: "|", with: " ") }
    public var ageSeconds: Int? { fields["age"].flatMap(Int.init) }
    public var idleSeconds: Int? { fields["idle"].flatMap(Int.init) }
    public var flags: String { fields["flags"] ?? "" }

    /// Blocked (`b` in flags): waiting on BLPOP, XREAD BLOCK, …
    public var isBlocked: Bool { flags.contains("b") }

    public static func parse(_ text: String) -> [RedisClientInfo] {
        text.components(separatedBy: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r "))
            guard !line.isEmpty else { return nil }
            var fields: [String: String] = [:]
            for part in line.split(separator: " ") {
                guard let equals = part.firstIndex(of: "=") else { continue }
                fields[String(part[..<equals])] = String(part[part.index(after: equals)...])
            }
            return fields["id"] == nil ? nil : RedisClientInfo(fields: fields)
        }
    }
}

/// The runner's `redisKill` event: what came of a confirmed Kill Client.
public struct RedisKillReport: Sendable, Codable, Equatable {
    public enum Outcome: String, Sendable, Codable {
        case killed, refused, gone, failed, timedOut
    }

    public var id: Int64
    public var outcome: Outcome
    public var detail: String

    public init(id: Int64, outcome: Outcome, detail: String) {
        self.id = id
        self.outcome = outcome
        self.detail = detail
    }
}
