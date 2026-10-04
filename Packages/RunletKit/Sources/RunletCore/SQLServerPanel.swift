import Foundation

// MARK: - The Database pane's Server section (#150)

/// What the server of an SQL tab's connection is, how big its database and largest tables are,
/// and which sessions it has: the runner's `sqlServer` event
/// (`Resources/Runner/src/SqlServerInfo.php`). It is read only when the user asks (production
/// asks first) or, off production, on a refresh interval the user turned on. Each part can fail
/// on its own (`errors`), so a missing privilege for one doesn't hide the others.
public struct SQLServerInfo: Sendable, Codable, Equatable {
    public enum Part: String, Sendable, Codable, CaseIterable, Hashable {
        case overview, sizes, sessions

        public var title: String {
            switch self {
            case .overview: "Server"
            case .sizes: "Sizes"
            case .sessions: "Sessions"
            }
        }
    }

    public struct Overview: Sendable, Codable, Equatable {
        /// `MariaDB`, `MySQL`, `PostgreSQL`, or `SQLite`.
        public var product: String?
        /// "11.8.9", "14.23".
        public var version: String?
        /// The server's own version text ("11.8.9-MariaDB-ubu2404 (mariadb.org binary distribution)").
        public var versionText: String?
        /// The current database (SQLite: the file's path).
        public var database: String?
        /// The current user: `user@host` on MySQL and MariaDB.
        public var user: String?
        public var uptimeSeconds: Int64?
        /// Client connections the server has (MySQL `Threads_connected`; PostgreSQL client backends).
        public var connections: Int?
        public var tls: Bool?
        public var tlsVersion: String?
        public var tlsCipher: String?
        /// SQLite's journal mode.
        public var journalMode: String?

        public init(product: String? = nil, version: String? = nil, versionText: String? = nil, database: String? = nil, user: String? = nil, uptimeSeconds: Int64? = nil, connections: Int? = nil, tls: Bool? = nil, tlsVersion: String? = nil, tlsCipher: String? = nil, journalMode: String? = nil) {
            self.product = product
            self.version = version
            self.versionText = versionText
            self.database = database
            self.user = user
            self.uptimeSeconds = uptimeSeconds
            self.connections = connections
            self.tls = tls
            self.tlsVersion = tlsVersion
            self.tlsCipher = tlsCipher
            self.journalMode = journalMode
        }

        /// "MariaDB 11.8.9".
        public var server: String? {
            switch (product, version) {
            case let (product?, version?): "\(product) \(version)"
            case let (product?, nil): product
            case let (nil, version?): version
            default: nil
            }
        }

        /// "TLSv1.3 (TLS_AES_256_GCM_SHA384)", "not encrypted", or nil when unknown.
        public var tlsText: String? {
            guard let tls else { return nil }
            guard tls else { return "not encrypted" }
            let version = tlsVersion.flatMap { $0.isEmpty ? nil : $0 } ?? "encrypted"
            return version + (tlsCipher.map { " (\($0))" } ?? "")
        }
    }

    public struct TableSize: Sendable, Codable, Equatable, Identifiable {
        public var name: String
        /// PostgreSQL's schema.
        public var schema: String?
        /// `partitioned table` or `materialized view` (PostgreSQL); nil for a plain table.
        public var kind: String?
        public var engine: String?
        /// The server's estimate (InnoDB, PostgreSQL); nil when unknown.
        public var rows: Int64?
        public var dataBytes: Int64?
        public var indexBytes: Int64?
        public var totalBytes: Int64?
        /// MySQL's `DATA_FREE`: allocated but unused.
        public var freeBytes: Int64?

        public init(name: String, schema: String? = nil, kind: String? = nil, engine: String? = nil, rows: Int64? = nil, dataBytes: Int64? = nil, indexBytes: Int64? = nil, totalBytes: Int64? = nil, freeBytes: Int64? = nil) {
            self.name = name
            self.schema = schema
            self.kind = kind
            self.engine = engine
            self.rows = rows
            self.dataBytes = dataBytes
            self.indexBytes = indexBytes
            self.totalBytes = totalBytes
            self.freeBytes = freeBytes
        }

        public var id: String { qualifiedName }

        /// The name, with its schema unless that is PostgreSQL's `public`.
        public var qualifiedName: String {
            guard let schema, !schema.isEmpty, schema != "public" else { return name }
            return "\(schema).\(name)"
        }
    }

    public struct Sizes: Sendable, Codable, Equatable {
        public var database: String?
        public var databaseBytes: Int64?
        public var dataBytes: Int64?
        public var indexBytes: Int64?
        public var freeBytes: Int64?
        public var tableCount: Int?
        public var viewCount: Int?
        /// The largest tables, largest first (at most 20).
        public var tables: [TableSize]
        /// How the sizes were read: `information_schema.TABLES`, `dbstat`, ….
        public var how: String?
        /// Sizes and row counts are the server's estimates.
        public var estimated: Bool?
        public var notes: [String]?

        public init(database: String? = nil, databaseBytes: Int64? = nil, dataBytes: Int64? = nil, indexBytes: Int64? = nil, freeBytes: Int64? = nil, tableCount: Int? = nil, viewCount: Int? = nil, tables: [TableSize] = [], how: String? = nil, estimated: Bool? = nil, notes: [String]? = nil) {
            self.database = database
            self.databaseBytes = databaseBytes
            self.dataBytes = dataBytes
            self.indexBytes = indexBytes
            self.freeBytes = freeBytes
            self.tableCount = tableCount
            self.viewCount = viewCount
            self.tables = tables
            self.how = how
            self.estimated = estimated
            self.notes = notes
        }

        /// The largest table's total, for the bars.
        public var largestBytes: Int64 { tables.compactMap(\.totalBytes).max() ?? 0 }
    }

    public struct Session: Sendable, Codable, Equatable, Identifiable {
        /// MySQL's thread id or PostgreSQL's pid.
        public var id: Int64
        public var user: String?
        /// `address:port`, a socket, or MySQL's host as it lists it.
        public var host: String?
        public var database: String?
        /// MySQL's command (`Query`, `Sleep`, …).
        public var command: String?
        /// PostgreSQL's application name.
        public var application: String?
        /// MySQL's state ("User sleep"), PostgreSQL's (`active`, `idle`, `idle in transaction`);
        /// nil when the server hides it (another role's session without pg_read_all_stats).
        public var state: String?
        /// It runs a statement now.
        public var active: Bool?
        /// Seconds in its current state (running the statement, or idle).
        public var seconds: Double?
        /// Seconds since its open transaction began.
        public var transactionSeconds: Double?
        /// PostgreSQL: when the session started, as the server wrote it (it tells a reused pid apart).
        public var started: String?
        /// PostgreSQL: when its current (or last) statement started.
        public var queryStarted: String?
        /// PostgreSQL's wait event ("Lock: transactionid").
        public var waiting: String?
        /// Sessions holding a lock this one waits for.
        public var blockedBy: [Int64]?
        /// The connection the panel read the list with.
        public var own: Bool?
        /// The statement it runs (or, idle on PostgreSQL, ran last), cut to 4 KB.
        public var query: String?
        /// The statement's full length when `query` was cut.
        public var queryBytes: Int?

        public init(id: Int64, user: String? = nil, host: String? = nil, database: String? = nil, command: String? = nil, application: String? = nil, state: String? = nil, active: Bool? = nil, seconds: Double? = nil, transactionSeconds: Double? = nil, started: String? = nil, queryStarted: String? = nil, waiting: String? = nil, blockedBy: [Int64]? = nil, own: Bool? = nil, query: String? = nil, queryBytes: Int? = nil) {
            self.id = id
            self.user = user
            self.host = host
            self.database = database
            self.command = command
            self.application = application
            self.state = state
            self.active = active
            self.seconds = seconds
            self.transactionSeconds = transactionSeconds
            self.started = started
            self.queryStarted = queryStarted
            self.waiting = waiting
            self.blockedBy = blockedBy
            self.own = own
            self.query = query
            self.queryBytes = queryBytes
        }

        public var isOwn: Bool { own == true }
        public var isActive: Bool { active == true }
        /// The server says it runs nothing (MySQL `Sleep`, PostgreSQL `idle…`); false when unknown.
        public var isIdle: Bool {
            if isActive { return false }
            if let command { return command == "Sleep" }
            return state?.hasPrefix("idle") == true
        }

        public var queryTruncated: Bool { queryBytes != nil }

        /// "Query · User sleep", "idle in transaction", "Sleep".
        public var stateText: String {
            let parts = [command, state].compactMap { $0?.isEmpty == false ? $0 : nil }
            return parts.isEmpty ? "state hidden" : parts.joined(separator: " · ")
        }

        /// "app@10.0.0.5:51234", or the user alone.
        public var userAndHost: String {
            [user, host].compactMap { $0 }.joined(separator: "@").nilIfEmpty ?? "unknown user"
        }

        /// Whether `text` (lowercased) appears in what the row shows.
        public func matches(_ text: String) -> Bool {
            let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
            guard !needle.isEmpty else { return true }
            return [String(id), user, host, database, command, application, state, query].compactMap { $0?.lowercased() }.contains { $0.contains(needle) }
        }
    }

    public struct Sessions: Sendable, Codable, Equatable {
        public var list: [Session]
        /// `all`; `own` (MySQL without PROCESS); `partial` (PostgreSQL without
        /// pg_read_all_stats: other roles' sessions without their statements); `none` (SQLite).
        public var visibility: String?
        /// The user may cancel and kill other users' sessions; nil when unknown.
        public var endOthers: Bool?
        public var truncated: Bool?
        public var notes: [String]?

        public init(list: [Session] = [], visibility: String? = nil, endOthers: Bool? = nil, truncated: Bool? = nil, notes: [String]? = nil) {
            self.list = list
            self.visibility = visibility
            self.endOthers = endOthers
            self.truncated = truncated
            self.notes = notes
        }
    }

    /// The PDO driver (`mysql`, `pgsql`, `sqlite`).
    public var driver: String?
    /// Where the connection came from (`Laravel DB::connection()`, a saved connection, …).
    public var source: String?
    /// The application connection's name (nil: the default), or a saved connection's name.
    public var connection: String?
    public var saved: Bool?
    /// The parts this read asked for.
    public var parts: [Part]?
    /// The session the list was read with (`CONNECTION_ID()`, `pg_backend_pid()`).
    public var sessionId: Int64?
    /// #144's fingerprint of the server: an action must reach the same one.
    public var server: String?
    public var overview: Overview?
    public var sizes: Sizes?
    public var sessions: Sessions?
    /// The parts that failed, with the database's words.
    public var errors: [String: String]?
    public var elapsedMs: Double?

    public init(driver: String? = nil, source: String? = nil, connection: String? = nil, saved: Bool? = nil, parts: [Part]? = nil, sessionId: Int64? = nil, server: String? = nil, overview: Overview? = nil, sizes: Sizes? = nil, sessions: Sessions? = nil, errors: [String: String]? = nil, elapsedMs: Double? = nil) {
        self.driver = driver
        self.source = source
        self.connection = connection
        self.saved = saved
        self.parts = parts
        self.sessionId = sessionId
        self.server = server
        self.overview = overview
        self.sizes = sizes
        self.sessions = sessions
        self.errors = errors
        self.elapsedMs = elapsedMs
    }

    public func error(for part: Part) -> String? { errors?[part.rawValue] }

    /// `newer` (a read of some parts) laid over this one: the parts it read replace these, and
    /// the list's session and server fingerprint come from the read that listed the sessions,
    /// so an action always pairs a list with the server it came from.
    public func merged(with newer: SQLServerInfo) -> SQLServerInfo {
        var result = self
        let read = Set(newer.parts ?? Part.allCases)
        result.driver = newer.driver ?? driver
        result.source = newer.source ?? source
        result.connection = newer.connection
        result.saved = newer.saved
        result.elapsedMs = newer.elapsedMs
        var errors = self.errors ?? [:]
        for part in read {
            errors[part.rawValue] = newer.errors?[part.rawValue]
            switch part {
            case .overview: result.overview = newer.overview
            case .sizes: result.sizes = newer.sizes
            case .sessions:
                result.sessions = newer.sessions
                result.sessionId = newer.sessionId
                result.server = newer.server
            }
        }
        if !read.contains(.sessions), result.sessions == nil {
            result.sessionId = newer.sessionId
            result.server = newer.server
        }
        result.errors = errors.isEmpty ? nil : errors
        result.parts = Array(Set(parts ?? []).union(read)).sorted { $0.rawValue < $1.rawValue }
        return result
    }
}

/// Cancel Query or Kill Session on a row of the Server section (#150).
public enum SQLServerAction: String, Sendable, Codable, CaseIterable {
    case cancel, kill

    /// "Cancel Query", "Kill Session".
    public var title: String {
        switch self {
        case .cancel: "Cancel Query"
        case .kill: "Kill Session"
        }
    }
}

/// What a confirmed action sends, and what it checks first: the list's server fingerprint, the
/// session it was read with (refused), and what the list showed for the session.
public struct SQLServerActionPlan: Sendable, Equatable {
    public var action: SQLServerAction
    /// `mysql` or `pgsql`.
    public var dialect: String
    public var session: Int64
    /// `KILL QUERY 4711`, `KILL 4711`, `SELECT pg_cancel_backend(4711)`, `SELECT pg_terminate_backend(4711)`.
    public var statement: String
    public var server: String
    public var listedBy: Int64
    public var user: String
    /// PostgreSQL's backend start of the listed session.
    public var started: String

    public init(action: SQLServerAction, dialect: String, session: Int64, statement: String, server: String, listedBy: Int64, user: String, started: String) {
        self.action = action
        self.dialect = dialect
        self.session = session
        self.statement = statement
        self.server = server
        self.listedBy = listedBy
        self.user = user
        self.started = started
    }

    /// "KILL QUERY 4711", "pg_terminate_backend(4711)".
    public var shortStatement: String { statement.hasPrefix("SELECT ") ? String(statement.dropFirst("SELECT ".count)) : statement }
}

/// The Server section's rules and texts (#150).
public enum SQLServerPanel {
    /// How long a read or an action may take before Runlet stops its runner.
    public static let readTimeout: Duration = .seconds(60)
    public static let actionTimeout: Duration = .seconds(15)
    /// The refresh intervals the sessions list offers, in seconds. Off by default, never on production.
    public static let refreshIntervals = [5, 10, 30]

    /// The runner code that reads `parts` on the tab's connection; nothing else runs. A saved
    /// connection (#138) comes with the run's request, so `connection` is nil.
    public static func code(parts: [SQLServerInfo.Part], connection: String?) -> String {
        let list = parts.map { QueryExplain.phpString($0.rawValue) }.joined(separator: ", ")
        return """
        <?php
        // Runlet Database pane (#150): the server's details, read from its catalog and status. Nothing else runs.
        return \\RunletRunner\\SqlTab::server([\(list)], \(connection.map(QueryExplain.phpString) ?? "null"));
        """
    }

    /// The runner code of a confirmed action: opens the same connection again and sends the
    /// plan's statement after its checks.
    public static func code(_ plan: SQLServerActionPlan, connection: String?) -> String {
        """
        <?php
        // Runlet Database pane (#150): \(plan.action.title) on session \(plan.session), confirmed by the user.
        return \\RunletRunner\\SqlTab::serverAction(\(QueryExplain.phpString(plan.action.rawValue)), \(QueryExplain.phpString(plan.dialect)), \(plan.session), \(QueryExplain.phpString(plan.statement)), \(connection.map(QueryExplain.phpString) ?? "null"), \(QueryExplain.phpString(plan.server)), \(plan.listedBy), \(QueryExplain.phpString(plan.user)), \(QueryExplain.phpString(plan.started)));
        """
    }

    /// The dialect actions work on: `mysql` or `pgsql`.
    public static func actionDialect(of driver: String?) -> String? {
        switch driver?.lowercased() {
        case "mysql": "mysql"
        case "pgsql": "pgsql"
        default: nil
        }
    }

    /// The statement `action` sends for `session`; nil on databases without one.
    public static func statement(_ action: SQLServerAction, driver: String?, session: Int64) -> String? {
        guard session > 0, let dialect = actionDialect(of: driver) else { return nil }
        switch (action, dialect) {
        case (.cancel, "mysql"): return "KILL QUERY \(session)"
        case (.kill, "mysql"): return "KILL \(session)"
        case (.cancel, _): return "SELECT pg_cancel_backend(\(session))"
        case (.kill, _): return "SELECT pg_terminate_backend(\(session))"
        }
    }

    /// Why `action` on `session` isn't offered, or nil when it is (it still asks first). The
    /// panel's own session is always refused; the runner checks again, and refuses its own.
    public static func refusal(_ action: SQLServerAction, session: SQLServerInfo.Session, info: SQLServerInfo) -> String? {
        if session.isOwn || session.id == info.sessionId {
            return "Session \(session.id) is the panel's own: the connection Runlet read the list with. Runlet never cancels or kills it."
        }
        guard actionDialect(of: info.driver) != nil else {
            return "Runlet cancels and kills sessions on MySQL, MariaDB, and PostgreSQL only."
        }
        guard session.id > 0 else { return "The server listed no id for this session." }
        guard let server = info.server, !server.isEmpty, (info.sessionId ?? 0) > 0 else {
            return "Runlet couldn't identify the server the list came from, so it can't make sure the action reaches the same one. Read the sessions again."
        }
        if action == .cancel, session.isIdle {
            return "Session \(session.id) was idle when the list was read: there was no statement to cancel. Read the sessions again, or kill the session."
        }
        return nil
    }

    /// The plan for `action` on `session`, or the refusal.
    public static func plan(_ action: SQLServerAction, session: SQLServerInfo.Session, info: SQLServerInfo) -> Result<SQLServerActionPlan, SQLServerRefusal> {
        if let refusal = refusal(action, session: session, info: info) { return .failure(SQLServerRefusal(message: refusal)) }
        guard let dialect = actionDialect(of: info.driver), let statement = statement(action, driver: dialect, session: session.id), let server = info.server, let listedBy = info.sessionId else {
            return .failure(SQLServerRefusal(message: "Runlet cancels and kills sessions on MySQL, MariaDB, and PostgreSQL only."))
        }
        return .success(SQLServerActionPlan(action: action, dialect: dialect, session: session.id, statement: statement, server: server, listedBy: listedBy, user: session.user ?? "", started: session.started ?? ""))
    }

    /// The refresh intervals a connection offers: none on production.
    public static func refreshIntervals(isProduction: Bool) -> [Int] {
        isProduction ? [] : refreshIntervals
    }

    // MARK: Confirmation

    /// The confirmation's title: "Kill session 4711?", "Cancel the statement of session 4711?".
    public static func confirmationTitle(_ plan: SQLServerActionPlan) -> String {
        switch plan.action {
        case .cancel: "Cancel the statement of session \(plan.session)?"
        case .kill: "Kill session \(plan.session)?"
        }
    }

    /// What the confirmation says about the session: who, where, what it does, since when.
    /// "app@10.0.0.5:51234 · database shop · Query · User sleep for 12 s (since about 14:03:05)".
    public static func sessionLine(_ session: SQLServerInfo.Session, readAt: Date, calendar: Calendar = .current) -> String {
        var parts = [session.userAndHost]
        if let database = session.database { parts.append("database \(database)") }
        var state = session.stateText
        if let seconds = session.seconds {
            let start = readAt.addingTimeInterval(-seconds)
            state += " for \(duration(seconds)) (since about \(clock(start, calendar: calendar)))"
        }
        parts.append(state)
        if let transaction = session.transactionSeconds, transaction > 0 {
            parts.append("in a transaction for \(duration(transaction))")
        }
        return parts.joined(separator: " · ")
    }

    /// The confirmation's explanation, for `connection` (the explorer's label for it) opened from
    /// `openedFrom`.
    public static func confirmationText(_ plan: SQLServerActionPlan, connection: String, openedFrom: String, isProduction: Bool, readOnly: Bool) -> String {
        let check = "Runlet opens \(connection) on \(openedFrom) again and sends \(plan.statement) only after checking that it reached the server the list came from and that session \(plan.session) is still \(plan.user.isEmpty ? "the one listed" : plan.user + "'s")."
        let effect = switch (plan.action, plan.dialect) {
        case (.cancel, "mysql"): "Cancelling stops the running statement and keeps the session; MySQL and MariaDB roll back what the statement changed."
        case (.cancel, _): "Cancelling stops the running statement and keeps the session; in a transaction, PostgreSQL then refuses its next statements until it rolls back."
        case (.kill, "mysql"): "Killing ends the session: its open transaction is rolled back, and its client gets an error on its next statement."
        case (.kill, _): "Killing ends the session (pg_terminate_backend): its open transaction is rolled back, and its client is disconnected."
        }
        var text = check + " " + effect
        if readOnly { text += " The connection is read-only, but this changes no data, so Runlet allows it." }
        if isProduction { text += " This connection is production." }
        return text + " Runlet asks before every cancel and kill, on every connection."
    }

    // MARK: Formatting

    /// "0 B", "512 B", "1.5 KB", "12 MB", "3.2 GB": powers of 1024, like pg_size_pretty.
    public static func bytes(_ value: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var size = Double(max(0, value))
        var unit = 0
        while size >= 1024, unit < units.count - 1 {
            size /= 1024
            unit += 1
        }
        if unit == 0 { return "\(Int(size)) B" }
        return size < 10 ? String(format: "%.1f %@", size, units[unit]) : String(format: "%.0f %@", size.rounded(), units[unit])
    }

    /// "0 s", "45 s", "12 min", "3 h 12 min", "4 d 3 h".
    public static func duration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        if total < 60 { return "\(total) s" }
        if total < 3600 { return "\(total / 60) min" }
        if total < 86400 {
            let minutes = (total % 3600) / 60
            return "\(total / 3600) h" + (minutes > 0 ? " \(minutes) min" : "")
        }
        let hours = (total % 86400) / 3600
        return "\(total / 86400) d" + (hours > 0 ? " \(hours) h" : "")
    }

    /// "1,234,567" rows, grouped for reading.
    public static func count(_ value: Int64) -> String {
        let digits = String(abs(value))
        var grouped = ""
        for (index, character) in digits.reversed().enumerated() {
            if index > 0, index % 3 == 0 { grouped.append(",") }
            grouped.append(character)
        }
        return (value < 0 ? "-" : "") + String(grouped.reversed())
    }

    /// "14:03:05"
    public static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// One line of a statement, for a row: whitespace runs as single spaces.
    public static func oneLine(_ text: String, limit: Int = 300) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }
}

/// Why the Server section doesn't offer an action on a session (#150).
public struct SQLServerRefusal: Error, Sendable, Equatable, CustomStringConvertible {
    public var message: String
    public init(message: String) { self.message = message }
    public var description: String { message }
}

/// What came of a confirmed Cancel Query or Kill Session (#150): the runner's `sqlServerAction`
/// event, or the engine's own report when the runner failed or didn't answer in time.
public struct SQLServerActionReport: Sendable, Codable, Equatable {
    public enum Outcome: String, Sendable, Codable {
        /// The statement stopped (or Runlet couldn't see it to check: `verified` false).
        case cancelled
        /// The session ended.
        case killed
        /// The server took the statement, but the statement or session was still there when
        /// Runlet stopped checking.
        case stillRunning
        /// The session had already ended.
        case alreadyEnded
        /// The session ran nothing, so there was nothing to cancel; nothing was sent.
        case idle
        /// Runlet or the database refused: the panel's own session, another server, another
        /// user's session now, no privilege.
        case refused
        /// The runner couldn't send it (it couldn't connect, the driver changed, an error).
        case failed
        /// The runner didn't answer in time.
        case timedOut

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Outcome(rawValue: raw) ?? .failed
        }
    }

    public var action: SQLServerAction
    public var outcome: Outcome
    public var driver: String
    public var session: Int64
    public var statement: String
    public var detail: String?
    /// What the session was doing when Runlet stopped checking.
    public var state: String?
    /// Runlet saw the statement or session end.
    public var verified: Bool?
    public var elapsedMs: Double?

    public init(action: SQLServerAction, outcome: Outcome, driver: String, session: Int64, statement: String, detail: String? = nil, state: String? = nil, verified: Bool? = nil, elapsedMs: Double? = nil) {
        self.action = action
        self.outcome = outcome
        self.driver = driver
        self.session = session
        self.statement = statement
        self.detail = detail
        self.state = state
        self.verified = verified
        self.elapsedMs = elapsedMs
    }

    /// The statement ended, or the session did (or already had).
    public var succeeded: Bool { [.cancelled, .killed, .alreadyEnded].contains(outcome) }

    private var shortStatement: String { statement.hasPrefix("SELECT ") ? String(statement.dropFirst("SELECT ".count)) : statement }

    /// What the panel says, e.g. "Killed session 4711 (KILL 4711): it's gone from the server's list."
    public var message: String {
        let detail = detail.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : ($0.hasSuffix(".") ? String($0.dropLast()) : $0) }
        switch outcome {
        case .cancelled:
            return "Cancelled the statement of session \(session) (\(shortStatement))" + (verified == false ? ". Runlet couldn't watch it stop: this user doesn't see the session." : ": it stopped on the server.")
        case .killed:
            return "Killed session \(session) (\(shortStatement))" + (verified == false ? ". Runlet couldn't watch it end: this user doesn't see the session." : ": it's gone from the server's list.")
        case .stillRunning:
            let waited = elapsedMs.map { String(format: " %.1f s later", $0 / 1000) } ?? ""
            return "The server accepted \(shortStatement), but session \(session) was still \(action == .kill ? "listed" : "running the statement")\(waited)\(state.map { " (\($0))" } ?? ""). The server finishes \(action == .kill ? "ending it" : "cancelling it"), and undoing its changes, on its own."
        case .alreadyEnded:
            return "Session \(session) had already ended on the server."
        case .idle:
            return "Session \(session) ran no statement\(state.map { " (\($0))" } ?? ""), so there was nothing to cancel. Nothing was sent."
        case .refused:
            return "Runlet didn't send \(shortStatement)" + (detail.map { ": \($0)." } ?? ".")
        case .failed:
            return "\(shortStatement) failed" + (detail.map { ": \($0)." } ?? ".")
        case .timedOut:
            return "Runlet didn't hear back within \(SQLServerPanel.actionTimeout.components.seconds) s: the server may or may not have taken \(shortStatement). Read the sessions again to check."
        }
    }

    /// The Run Log's line: the action, the statement, and the outcome; never the session's statement text.
    public func logMessage(connection: String) -> String {
        "Database pane: \(action.title) on session \(session) (\(statement)) through \(connection): \(outcome.rawValue)\(verified == false ? ", unverified" : "")"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
