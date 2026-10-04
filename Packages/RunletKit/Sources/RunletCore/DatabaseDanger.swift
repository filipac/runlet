import Foundation

/// The confirmation a database tab shows before a dangerous command or operation: Redis's
/// FLUSHALL, FLUSHDB, KEYS, … (#190), and MongoDB's drop and unfiltered deleteMany/updateMany
/// (#191). It names each dangerous line and what it does, the connection, and (MongoDB) the
/// collection and database. It shows on every connection, production or not; production asks
/// again after it. `perform` runs only after the action button.
public struct DatabaseDangerConfirmation: Identifiable {
    public struct Item: Hashable, Sendable {
        /// The editor line it starts on.
        public var line: Int?
        /// The command or operation: "FLUSHDB", "drop".
        public var name: String
        /// The line or query on one line, passwords as •••.
        public var text: String
        /// What it does: "deletes every key of the current database".
        public var danger: String

        public init(line: Int?, name: String, text: String, danger: String) {
            self.line = line
            self.name = name
            self.text = text
            self.danger = danger
        }

        /// "Line 3: FLUSHDB deletes every key of the current database."
        public var sentence: String {
            (line.map { "Line \($0): " } ?? "") + "\(name) \(danger)."
        }
    }

    public let id = UUID()
    public var family: DatabaseFamily
    public var tabId: UUID
    /// The connection and where it connects: "the saved connection “Cache” (redis, 127.0.0.1:6379/0)".
    public var connection: String
    /// What the operation acts on inside the connection, when narrower than it: "the
    /// collection “orders” in the database “shop”".
    public var destination: String?
    public var items: [Item]
    public var perform: () -> Void
    /// The action button's title when it isn't "Run …" (#207: "Kill Op").
    public var actionTitle: String?
    /// The accessibility identifier when it isn't the family's (#207: "mongo-kill").
    public var customIdentifier: String?
    /// The question when it isn't "Run … on …?" (#207: dropDatabase names the database).
    public var customTitle: String?

    public init(family: DatabaseFamily, tabId: UUID, connection: String, destination: String? = nil, items: [Item], perform: @escaping () -> Void) {
        self.family = family
        self.tabId = tabId
        self.connection = connection
        self.destination = destination
        self.items = items
        self.perform = perform
    }

    /// "Run FLUSHDB on the saved connection “Cache” (…)?"; "Run drop on the collection
    /// “orders” in the database “shop”, on the saved connection “Documents” (…)?"
    public var title: String {
        if let customTitle { return customTitle }
        if let actionTitle { return "\(actionTitle) on " + (destination.map { "\($0), on " } ?? "") + "\(connection)?" }
        let names = Array(Set(items.map(\.name))).sorted()
        return "Run \(names.joined(separator: ", ")) on " + (destination.map { "\($0), on " } ?? "") + "\(connection)?"
    }

    public var confirmTitle: String {
        if let actionTitle { return actionTitle }
        let names = Set(items.map(\.name))
        return names.count == 1 ? "Run \(names.first!)" : family == .redis ? "Run Commands" : "Run Operations"
    }

    /// Under the title: when Runlet asks.
    public var explanation: String {
        "Runlet asks before every dangerous \(family.displayName) \(family == .redis ? "command" : "operation"), on every connection."
    }

    /// The sheet's accessibility identifier; its buttons add `-cancel` and `-confirm`.
    public var identifier: String {
        if let customIdentifier { return customIdentifier }
        return switch family {
        case .mongodb: "mongo-danger"
        default: "\(family.rawValue)-danger"
        }
    }
}

extension DatabaseDangerConfirmation {
    /// A MongoDB query's confirmation (#191), or nil when the query isn't destructive. `line` is
    /// where the query starts in the editor; `database` the saved connection's, when known.
    public static func mongo(_ query: MongoQuery, line: Int?, database: String?, connection: String, tabId: UUID, perform: @escaping () -> Void) -> DatabaseDangerConfirmation? {
        guard let danger = query.danger else { return nil }
        let text = query.json.replacingOccurrences(of: #"\s*\n\s*"#, with: " ", options: .regularExpression)
        let database = database.flatMap { $0.isEmpty ? nil : $0 }
        let destination = "the collection “\(query.collection)” in " + (database.map { "the database “\($0)”" } ?? "the connection's database")
        return DatabaseDangerConfirmation(family: .mongodb, tabId: tabId, connection: connection, destination: destination,
                                          items: [Item(line: line, name: query.operation, text: text, danger: danger)], perform: perform)
    }
}

extension MongoQuery {
    /// What a destructive operation does (#191), for its confirmation; nil for the others.
    public var danger: String? {
        guard effect == .destructive else { return nil }
        switch operation {
        case "drop": return "removes the collection “\(collection)” with all its documents and indexes"
        case "deleteMany": return "has an empty filter: it deletes every document of “\(collection)”"
        case "updateMany": return "has an empty filter: it updates every document of “\(collection)”"
        default: return "can't be undone"
        }
    }

    /// Open Find Query (#191): the first 50 documents of a collection, by _id. Nothing runs.
    public static func findTemplate(collection: String) -> String {
        let name = (try? JSONSerialization.data(withJSONObject: collection, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        return "{\n  \"collection\": \(name),\n  \"operation\": \"find\",\n  \"filter\": {},\n  \"sort\": { \"_id\": 1 },\n  \"limit\": 50\n}\n"
    }

    /// The editor line a query starts on: the first line with text at or after `offset` (the
    /// selection's start, or 0 for the whole tab).
    public static func startLine(in text: String, from offset: Int = 0) -> Int {
        let ns = text as NSString
        var index = min(max(0, offset), ns.length)
        while index < ns.length, let scalar = UnicodeScalar(ns.character(at: index)), CharacterSet.whitespacesAndNewlines.contains(scalar) {
            index += 1
        }
        if index >= ns.length { index = min(max(0, offset), ns.length) }
        return ns.substring(to: index).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }
}
