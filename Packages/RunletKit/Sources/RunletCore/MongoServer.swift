import Foundation

/// The runner's `mongoServer` event (#207): the Database pane's Server section for a MongoDB
/// connection, like SQL's (#150) and Redis's (#190). A `serverStatus` summary and `$currentOp`'s
/// active operations of the server the tab's reads go to. Never credentials: the runner scrubs
/// connection strings and passwords from the command summaries.
public struct MongoServerReport: Sendable, Codable, Equatable {
    public struct Status: Sendable, Codable, Equatable {
        public struct Connections: Sendable, Codable, Equatable {
            public var current: Int
            public var available: Int
            public var totalCreated: Int?
        }

        public struct Memory: Sendable, Codable, Equatable {
            public var residentMB: Int
            public var virtualMB: Int
        }

        public var version: String?
        public var process: String?
        public var host: String?
        /// Seconds.
        public var uptime: Int?
        public var connections: Connections?
        public var memory: Memory?
        public var storageEngine: String?
        public var replicaState: String?
        public var opcounters: [String: Int]?

        public init(version: String? = nil, process: String? = nil, host: String? = nil, uptime: Int? = nil, connections: Connections? = nil, memory: Memory? = nil, storageEngine: String? = nil, replicaState: String? = nil, opcounters: [String: Int]? = nil) {
            self.version = version
            self.process = process
            self.host = host
            self.uptime = uptime
            self.connections = connections
            self.memory = memory
            self.storageEngine = storageEngine
            self.replicaState = replicaState
            self.opcounters = opcounters
        }
    }

    /// What `hello` said about the replica set (anyone may read it).
    public struct Replica: Sendable, Codable, Equatable {
        public var setName: String?
        /// PRIMARY, SECONDARY, ARBITER, OTHER.
        public var state: String?
        public var primary: String?
        public var me: String?
        public var mongos: Bool?
    }

    public struct Operation: Sendable, Codable, Equatable, Identifiable {
        /// 4711, or "shard01:4711" on mongos.
        public var opid: String
        /// The opid is a number (mongod); else a string (mongos).
        public var numeric: Bool?
        public var op: String?
        public var ns: String?
        public var desc: String?
        public var client: String?
        public var appName: String?
        /// `user@db`.
        public var users: [String]?
        public var active: Bool?
        public var micros: Int64?
        public var waitingForLock: Bool?
        public var comment: String?
        /// The command, shortened (session fields left out).
        public var command: String?
        /// The panel's own `$currentOp` read.
        public var own: Bool?

        public var id: String { opid }

        public init(opid: String, numeric: Bool? = true, op: String? = nil, ns: String? = nil, desc: String? = nil, client: String? = nil, appName: String? = nil, users: [String]? = nil, active: Bool? = true, micros: Int64? = nil, waitingForLock: Bool? = nil, comment: String? = nil, command: String? = nil, own: Bool? = nil) {
            self.opid = opid
            self.numeric = numeric
            self.op = op
            self.ns = ns
            self.desc = desc
            self.client = client
            self.appName = appName
            self.users = users
            self.active = active
            self.micros = micros
            self.waitingForLock = waitingForLock
            self.comment = comment
            self.command = command
            self.own = own
        }

        /// "running 12.4 s", "running 3 ms".
        public var runningText: String? {
            guard let micros else { return nil }
            if micros < 1_000_000 { return "running \(max(0, micros / 1000)) ms" }
            return String(format: "running %.1f s", Double(micros) / 1_000_000)
        }

        /// The operation tagged by a Runlet run (#207): "runlet:<run id>".
        public var isRunlet: Bool { comment?.hasPrefix("runlet:") == true }

        /// The kind and namespace, for the confirmation: "find on shop.orders".
        public var title: String {
            (op ?? "operation") + (ns.map { " on \($0)" } ?? "")
        }
    }

    /// The server's fingerprint (its process id, hashed): Kill Op checks it reaches this server.
    public var server: String
    /// The address the panel read, as the driver saw it ("127.0.0.1:27017").
    public var host: String?
    /// The panel's own comment, which names its `$currentOp` read in `operations`.
    public var listedBy: String
    public var replica: Replica?
    public var status: Status?
    public var operations: [Operation]?
    /// Only this user's operations: it may not list others' (no inprog privilege).
    public var ownOnly: Bool?
    /// Why a part is missing: `serverStatus`, `currentOp`.
    public var errors: [String: String]?

    public init(server: String, host: String? = nil, listedBy: String, replica: Replica? = nil, status: Status? = nil, operations: [Operation]? = nil, ownOnly: Bool? = nil, errors: [String: String]? = nil) {
        self.server = server
        self.host = host
        self.listedBy = listedBy
        self.replica = replica
        self.status = status
        self.operations = operations
        self.ownOnly = ownOnly
        self.errors = errors
    }

    /// "MongoDB 7.0.14 · up 3 h 12 min · 12 connections (838,848 available) · 151 MB resident · replica set rs0 PRIMARY".
    public var summary: String {
        var parts: [String] = []
        if let version = status?.version { parts.append("MongoDB \(version)") }
        if replica?.mongos == true { parts.append("mongos") }
        if let uptime = status?.uptime { parts.append("up " + Self.duration(uptime)) }
        if let connections = status?.connections {
            parts.append("\(connections.current.formatted()) connection\(connections.current == 1 ? "" : "s") (\(connections.available.formatted()) available)")
        }
        if let memory = status?.memory { parts.append("\(memory.residentMB.formatted()) MB resident") }
        if let set = replica?.setName {
            parts.append("replica set \(set) \(replica?.state ?? status?.replicaState ?? "")".trimmingCharacters(in: .whitespaces))
        } else if replica?.mongos != true {
            parts.append("standalone")
        }
        return parts.isEmpty ? (host.map { "MongoDB at \($0)" } ?? "MongoDB") : parts.joined(separator: " · ")
    }

    /// "3 d 4 h", "3 h 12 min", "42 s".
    public static func duration(_ seconds: Int) -> String {
        let days = seconds / 86_400, hours = seconds % 86_400 / 3600, minutes = seconds % 3600 / 60
        if days > 0 { return "\(days) d \(hours) h" }
        if hours > 0 { return "\(hours) h \(minutes) min" }
        if minutes > 0 { return "\(minutes) min" }
        return "\(seconds) s"
    }
}

/// The runner's `mongoKill` event (#207): what came of a confirmed Kill Op.
public struct MongoKillReport: Sendable, Codable, Equatable {
    public enum Outcome: String, Sendable, Codable {
        case killed, gone, refused, failed

        public init(from decoder: Decoder) throws {
            self = Outcome(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .failed
        }
    }

    public var opid: String
    public var outcome: Outcome
    public var detail: String

    public init(opid: String, outcome: Outcome, detail: String) {
        self.opid = opid
        self.outcome = outcome
        self.detail = detail
    }
}

/// The Server section's runner code and Kill Op's checks (#207).
public enum MongoServerPanel {
    /// Seconds between automatic reads; never offered on production.
    public static func refreshIntervals(isProduction: Bool) -> [Int] {
        isProduction ? [] : [5, 15, 60]
    }

    /// Reads `serverStatus` and `$currentOp` (`MongoTab::server`).
    public static func serverCode(connection: String?) -> String {
        "\\RunletRunner\\MongoTab::server(\(phpString(connection)));"
    }

    /// A confirmed Kill Op (`MongoTab::killOp`): the runner checks the server, the operation, and
    /// that it isn't Runlet's own before `killOp`.
    public static func killCode(_ operation: MongoServerReport.Operation, report: MongoServerReport, connection: String?) -> String {
        let opid = operation.numeric == true && Int64(operation.opid) != nil ? operation.opid : QueryExplain.phpString(operation.opid)
        return "\\RunletRunner\\MongoTab::killOp(\(opid), \(QueryExplain.phpString(report.server)), \(QueryExplain.phpString(report.listedBy)), \(QueryExplain.phpString(operation.ns ?? "")), \(QueryExplain.phpString(operation.op ?? "")), \(phpString(connection)));"
    }

    private static func phpString(_ value: String?) -> String {
        value.map(QueryExplain.phpString) ?? "null"
    }

    /// Why Runlet won't kill `operation`, or nil: the panel's own read.
    public static func refusal(_ operation: MongoServerReport.Operation) -> String? {
        operation.own == true ? "Operation \(operation.opid) is the panel's own read of the operations; it has already ended. Nothing was killed." : nil
    }
}

extension DatabaseDangerConfirmation {
    /// Kill Op's confirmation (#207): always, on every connection, in the shared danger sheet.
    public static func mongoKill(_ operation: MongoServerReport.Operation, connection: String, isProduction: Bool, tabId: UUID, perform: @escaping () -> Void) -> DatabaseDangerConfirmation {
        let what = [operation.client.map { "client \($0)" }, operation.users.map { "as " + $0.joined(separator: ", ") }, operation.runningText].compactMap { $0 }.joined(separator: ", ")
        let danger = "ends operation \(operation.opid) (\(operation.title)\(what.isEmpty ? "" : ", " + what)) at its next interruption point"
            + (operation.op == "insert" || operation.op == "update" || operation.op == "remove" || operation.op == "command" ? "; what it already wrote stays" : "")
            + (isProduction ? ", on a production connection" : "")
        var confirmation = DatabaseDangerConfirmation(family: .mongodb, tabId: tabId, connection: connection, destination: "operation \(operation.opid)",
                                                      items: [Item(line: nil, name: "killOp", text: operation.command ?? operation.desc ?? operation.title, danger: danger)], perform: perform)
        confirmation.actionTitle = "Kill Op"
        confirmation.customTitle = "Kill operation \(operation.opid) (\(operation.title)) through \(connection)?"
        confirmation.customIdentifier = "mongo-kill"
        return confirmation
    }
}
