import Foundation

/// Rollback ("dry run") mode (#13): what the runner reports about the transactions it wrapped a
/// PHP tab's run in. A `rollback` event is `begun` once the transactions are open, `warning` as
/// soon as something can't be rolled back (an implicit commit, a commit in the code, a change on
/// a connection the dry run doesn't wrap), and `finished` with each connection's outcome. The app
/// makes a `stopped` report itself when the run ended before the runner could report.
public struct RollbackReport: Sendable, Codable, Equatable {
    public enum State: String, Sendable, Codable {
        case begun, warning, finished
        /// Made by the app: the run ended (Stop, a crash) before the runner rolled back.
        case stopped
    }

    /// One connection in the dry run, or one it didn't wrap.
    public struct Connection: Sendable, Codable, Equatable, Identifiable {
        public enum Status: String, Sendable, Codable {
            /// The transaction is open (a `begun` report).
            case open
            /// Rolled back at the end (some statements may still be saved: see `saved`).
            case rolledBack
            /// The transaction was committed before the end (implicitly, or by the code).
            case committed
            /// The code rolled the transaction back early; what came after is saved.
            case ended
            /// The transaction was gone at the end, and Runlet didn't see what ended it.
            case lost
            /// Runlet's ROLLBACK failed; the database discards the transaction when PHP exits.
            case failed
            /// The transaction never began (the error says why).
            case notStarted
            /// Statements ran on a connection the dry run doesn't wrap.
            case notWrapped
            /// A runner newer than this app.
            case unknown

            public init(from decoder: Decoder) throws {
                self = Status(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
            }
        }

        /// What ended Runlet's transaction before the end.
        public struct Commit: Sendable, Codable, Equatable {
            /// implicit (DDL on MySQL/MariaDB), begin, commit, or rollback.
            public var how: String
            public var sql: String?
            /// Runlet began a new transaction right after (implicit commits).
            public var reopened: Bool?
            public var inSnippet: Bool?
            public var snippetLine: Int?
        }

        public var name: String
        public var driver: String?
        /// eloquent, doctrine, wordpress, or pdo.
        public var api: String?
        public var status: Status
        /// Statements that can change data, and how many of them are saved anyway.
        public var writes: Int?
        public var reads: Int?
        public var saved: Int?
        public var error: String?
        public var commits: [Commit]?

        public var id: String { name + "/" + (api ?? "") }

        /// Statements whose changes the rollback undid.
        public var rolledBack: Int {
            switch status {
            case .rolledBack, .ended: max(0, (writes ?? 0) - (saved ?? 0))
            default: 0
            }
        }
    }

    public struct Warning: Sendable, Codable, Equatable {
        /// implicitCommit, committed, rolledBackEarly, notWrapped, or notStarted.
        public var kind: String
        public var message: String
        public var connection: String?
        public var sql: String?
        public var inSnippet: Bool?
        public var snippetLine: Int?
        public var file: String?
        public var line: Int?

        public init(kind: String, message: String) {
            self.kind = kind
            self.message = message
        }
    }

    public var state: State
    /// How the run ended (completed, error, exit, dd, fatal), for `finished`.
    public var reason: String?
    /// `begun` and `finished`: the connections.
    public var connections: [Connection]?
    /// `finished`: statements that can change data whose changes were rolled back.
    public var statements: Int?
    /// `finished`: reads on the wrapped connections.
    public var reads: Int?
    /// `finished`: every warning; `warning`: the one.
    public var warnings: [Warning]?
    public var warning: Warning?
    public var omittedWarnings: Int?
    /// What wasn't wrapped, and why (a MongoDB connection, a connection type Runlet doesn't know).
    public var notes: [String]?
    /// Connections the snippet opens later join too (Laravel 10+).
    public var watching: Bool?

    public init(state: State, reason: String? = nil, connections: [Connection]? = nil, statements: Int? = nil, warnings: [Warning]? = nil) {
        self.state = state
        self.reason = reason
        self.connections = connections
        self.statements = statements
        self.warnings = warnings
    }

    /// The app's report for a run that ended before the runner could roll back.
    public static func stopped(reason: String, connections: [Connection]?) -> RollbackReport {
        RollbackReport(state: .stopped, reason: reason, connections: connections)
    }

    /// Wrapped connections (not the ones listed only because statements ran outside the dry run).
    public var wrapped: [Connection] {
        (connections ?? []).filter { $0.status != .notWrapped }
    }

    /// Something was saved, or may have been: a warning, a commit, a failure.
    public var hasProblems: Bool {
        !(warnings ?? []).isEmpty || (connections ?? []).contains { [.committed, .ended, .lost, .failed, .notStarted, .notWrapped].contains($0.status) || ($0.saved ?? 0) > 0 }
    }

    /// The card's title: "Rolled back 3 statements on mysql", "Nothing to roll back on mysql",
    /// "Dry run: 2 statements were saved on mysql", ….
    public var title: String {
        switch state {
        case .begun:
            return "Dry run: database changes are rolled back"
        case .warning:
            return "Dry run: " + (warning?.message ?? "a statement can't be rolled back")
        case .stopped:
            return "Stopped before Runlet rolled back"
        case .finished:
            let wrapped = self.wrapped
            let names = Self.list(wrapped.map(\.name))
            let saved = (connections ?? []).reduce(0) { $0 + ($1.saved ?? 0) }
            let count = statements ?? wrapped.reduce(0) { $0 + $1.rolledBack }
            if wrapped.isEmpty {
                return saved > 0 ? "Dry run: \(Self.statements(saved)) saved on connections it doesn't wrap" : "Dry run: no database connection to roll back"
            }
            if count == 0 && saved == 0 {
                return "Nothing to roll back on \(names)"
            }
            var text = "Rolled back \(Self.statements(count)) on \(names)"
            if saved > 0 { text += " · \(Self.statements(saved)) saved" }
            return text
        }
    }

    /// One line per connection, for the card and Copy Output.
    public var details: [String] {
        switch state {
        case .stopped:
            return ["The database discards the open transaction when the connection closes, so the changes aren't saved. A statement still running on the server may finish first, and holds its locks until then."]
                + Self.unknownCommits(connections)
        case .begun, .warning:
            return []
        case .finished:
            var lines: [String] = []
            for connection in connections ?? [] {
                lines.append(Self.line(connection))
            }
            if let notes { lines += notes }
            return lines
        }
    }

    /// Plain text (Copy Output, MCP): the title, each connection, and the warnings.
    public var plainText: String {
        var lines = [title]
        lines += details
        if state == .finished {
            for warning in warnings ?? [] { lines.append("⚠︎ " + warning.message) }
            if let omitted = omittedWarnings, omitted > 0 { lines.append("(\(omitted) more warning\(omitted == 1 ? "" : "s"))") }
        }
        return lines.joined(separator: "\n")
    }

    static func line(_ connection: Connection) -> String {
        let label = connection.name + (connection.driver.map { $0.isEmpty ? "" : " (\($0))" } ?? "")
        let writes = connection.writes ?? 0
        let saved = connection.saved ?? 0
        let reads = connection.reads ?? 0
        let readText = reads > 0 ? "; \(reads) read\(reads == 1 ? "" : "s")" : ""
        switch connection.status {
        case .rolledBack:
            if writes == 0 { return "\(label): no changes to roll back\(readText)." }
            if saved > 0 { return "\(label): rolled back \(statements(writes - saved)); \(statements(saved)) saved before Runlet's transaction began again\(readText)." }
            return "\(label): rolled back \(statements(writes))\(readText)."
        case .committed:
            return "\(label): not rolled back: the transaction was committed during the run, so \(writes == 1 ? "its statement is" : "all \(writes) statements are") saved\(readText)."
        case .ended:
            return "\(label): the code rolled back the transaction early: \(statements(writes - saved)) undone, \(statements(saved)) saved after it\(readText)."
        case .lost:
            return "\(label): the transaction had ended before Runlet rolled back (a commit, an implicit commit, or a reconnect Runlet didn't see); its changes are saved\(readText)."
        case .failed:
            return "\(label): Runlet couldn't roll back (\(connection.error ?? "unknown error")). The database discards the open transaction when PHP exits and the connection closes."
        case .notStarted:
            return "\(label): no transaction (\(connection.error ?? "it didn't begin")); \(writes == 0 ? "nothing changed there" : "\(statements(writes)) saved")."
        case .notWrapped:
            return "\(label): not in the dry run; \(statements(writes)) that can change data saved."
        case .open, .unknown:
            return "\(label): \(statements(writes)) that can change data."
        }
    }

    private static func unknownCommits(_ connections: [Connection]?) -> [String] {
        let names = (connections ?? []).map(\.name)
        return names.isEmpty ? [] : ["Connections in the dry run: \(list(names))."]
    }

    static func statements(_ count: Int) -> String {
        "\(count) statement\(count == 1 ? "" : "s")"
    }

    static func list(_ names: [String]) -> String {
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        switch unique.count {
        case 0: return "no connection"
        case 1: return unique[0]
        case 2: return unique[0] + " and " + unique[1]
        default: return unique.dropLast().joined(separator: ", ") + ", and " + unique[unique.count - 1]
        }
    }

    /// What a dry run doesn't cover, for the bar above the editor, the toggle's help, and docs.
    public static let limits = "Only the application's database connections are rolled back: mail (use Intercept Mail), queued jobs on other connections, HTTP calls, files, caches, and Redis are not. MySQL and MariaDB commit schema changes at once. The transaction holds its row and table locks until the run ends."
}

extension RollbackReport.Connection {
    /// A connection without a status (an older runner's `begun` report) reads as open.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        driver = try c.decodeIfPresent(String.self, forKey: .driver)
        api = try c.decodeIfPresent(String.self, forKey: .api)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .open
        writes = try c.decodeIfPresent(Int.self, forKey: .writes)
        reads = try c.decodeIfPresent(Int.self, forKey: .reads)
        saved = try c.decodeIfPresent(Int.self, forKey: .saved)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        commits = try c.decodeIfPresent([Commit].self, forKey: .commits)
    }
}
