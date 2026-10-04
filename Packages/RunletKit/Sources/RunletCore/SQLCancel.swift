import Foundation

// MARK: - Cancelling a statement on the server (#144)

/// The runner's `sqlSession` event (#144): the server-side id of the connection an SQL tab's
/// run opened, reported right after connecting and before the statement runs. MySQL/MariaDB
/// `CONNECTION_ID()`, PostgreSQL `pg_backend_pid()`, SQL Server `@@SPID`; SQLite and callable
/// connections report none. It never holds credentials: a driver, a number, the tab's
/// application connection name, and an opaque fingerprint of the server.
public struct SQLSessionInfo: Sendable, Codable, Equatable {
    /// The PDO driver (`mysql`, `pgsql`, `sqlsrv`, `dblib`).
    public var driver: String
    /// The session's id on the server.
    public var id: Int64
    /// The tab's application connection name (nil: the default connection, or a saved one).
    public var connection: String?
    /// The run is on a saved connection (#138).
    public var saved: Bool?
    /// Run All in one transaction (#129).
    public var transaction: Bool?
    /// A hash of what identifies the database server (host and port, PostgreSQL's start time):
    /// the cancel's connection must reach the same server before it sends anything.
    public var server: String?

    public init(driver: String, id: Int64, connection: String? = nil, saved: Bool? = nil, transaction: Bool? = nil, server: String? = nil) {
        self.driver = driver
        self.id = id
        self.connection = connection
        self.saved = saved
        self.transaction = transaction
        self.server = server
    }

    /// The Run Log's line: "Database session 4711 (mysql): Stop cancels its statement with KILL QUERY 4711".
    public var logMessage: String {
        let stop = SQLCancel.plan(for: self).map { "Stop cancels its statement with \($0.statement)" } ?? "Stop ends the runner only"
        return "Database session \(id) (\(driver)): \(stop)"
    }
}

/// Stop on an SQL run (#144): the statement that cancels a session's running statement on its
/// server, sent from a second, short runner on the same target and connection before the
/// runner process is stopped. Killing the process alone leaves MySQL and MariaDB executing a
/// long statement until they write to the closed connection, and PostgreSQL usually finishes it,
/// holding its locks meanwhile.
public enum SQLCancel {
    /// How long Stop waits for the second runner (booting the application for an application
    /// connection, connecting, cancelling, checking) before it stops the run's process anyway.
    public static let timeout: Duration = .seconds(8)

    public struct Plan: Sendable, Equatable {
        /// `mysql`, `pgsql`, or `sqlsrv`.
        public var dialect: String
        public var session: Int64
        /// `KILL QUERY 4711`, `SELECT pg_cancel_backend(4711)`, `KILL 57`.
        public var statement: String

        /// SQL Server has no KILL QUERY: KILL ends the whole session and rolls back its
        /// transaction (the runner's process is stopped right after anyway).
        public var endsSession: Bool { dialect == "sqlsrv" }

        /// What the output names: "KILL QUERY 4711", "pg_cancel_backend(4711)".
        public var shortText: String { statement.hasPrefix("SELECT ") ? String(statement.dropFirst("SELECT ".count)) : statement }
    }

    /// The dialect of a PDO driver name, for the drivers Runlet can cancel on.
    public static func dialect(of driver: String?) -> String? {
        switch driver?.lowercased() {
        case "mysql": "mysql"
        case "pgsql": "pgsql"
        case "sqlsrv", "dblib": "sqlsrv"
        default: nil
        }
    }

    /// The cancel statement for `session` on `driver`; nil where there is none (SQLite needs
    /// none: its database is in the runner's process; others Runlet doesn't know).
    public static func plan(driver: String?, session: Int64) -> Plan? {
        guard session > 0, let dialect = dialect(of: driver) else { return nil }
        let statement = switch dialect {
        case "mysql": "KILL QUERY \(session)"
        case "pgsql": "SELECT pg_cancel_backend(\(session))"
        default: "KILL \(session)"
        }
        return Plan(dialect: dialect, session: session, statement: statement)
    }

    public static func plan(for session: SQLSessionInfo) -> Plan? {
        plan(driver: session.driver, session: session.id)
    }

    /// The second runner's PHP: opens the same connection (an application connection by name
    /// through the booted driver, or the run's saved connection) and sends the plan's statement
    /// after checking it reached the same server and the session still runs something.
    public static func code(_ plan: Plan, session: SQLSessionInfo) -> String {
        """
        <?php
        // Runlet SQL tab (#144): Stop cancels the running statement on the database server.
        return \\RunletRunner\\SqlTab::cancel(\(QueryExplain.phpString(plan.dialect)), \(plan.session), \(QueryExplain.phpString(plan.statement)), \(session.connection.map(QueryExplain.phpString) ?? "null"), \(QueryExplain.phpString(session.server ?? "")));
        """
    }
}

/// What came of cancelling a statement on its server (#144): the second runner's `sqlCancel`
/// event, or the engine's own report when that runner failed or didn't answer in time.
public struct SQLCancelReport: Sendable, Codable, Equatable {
    public enum Outcome: String, Sendable, Codable {
        /// The server took the cancel, and the statement ended (or Runlet couldn't see it to check).
        case cancelled
        /// The server took the cancel, but the statement was still running when Runlet stopped
        /// checking (MySQL rolling back a large change, a step that doesn't check for cancels).
        case stillRunning
        /// The session was gone: the statement had ended, and its connection with it.
        case alreadyEnded
        /// The session ran nothing any more: the statement had finished.
        case idle
        /// Runlet or the database refused: the user may not cancel the session, the second
        /// connection reached another server, the session belongs to another user.
        case refused
        /// The second runner failed (it couldn't boot or connect, the driver changed, …).
        case failed
        /// The second runner didn't answer within `SQLCancel.timeout`.
        case timedOut

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Outcome(rawValue: raw) ?? .failed
        }
    }

    public var outcome: Outcome
    /// The PDO driver of the session.
    public var driver: String
    public var session: Int64
    /// The cancel statement, as sent (or as it would have been).
    public var statement: String
    /// The database's (or the runner's) own words, when something went wrong.
    public var detail: String?
    /// What the session was doing when Runlet stopped checking (MySQL's `Killed`, …).
    public var state: String?
    /// Run All in one transaction (#129), from the session's report.
    public var transaction: Bool?
    /// The second runner's time from connecting to its last check.
    public var elapsedMs: Double?
    /// Runlet saw the statement end on the server after the cancel.
    public var verified: Bool?

    public init(outcome: Outcome, driver: String, session: Int64, statement: String, detail: String? = nil, state: String? = nil, transaction: Bool? = nil, elapsedMs: Double? = nil, verified: Bool? = nil) {
        self.outcome = outcome
        self.driver = driver
        self.session = session
        self.statement = statement
        self.detail = detail
        self.state = state
        self.transaction = transaction
        self.elapsedMs = elapsedMs
        self.verified = verified
    }

    /// The statement ended (or had already ended) on the server.
    public var succeeded: Bool { [.cancelled, .alreadyEnded, .idle].contains(outcome) }

    /// "KILL QUERY 4711", "pg_cancel_backend(4711)".
    var shortStatement: String { statement.hasPrefix("SELECT ") ? String(statement.dropFirst("SELECT ".count)) : statement }

    private var dialect: String? { SQLCancel.dialect(of: driver) }

    /// The output's line, e.g. "Cancelled the statement on the server (KILL QUERY 4711)."
    public var message: String {
        // The database's words end the sentence: "…: You are not owner of thread 4711."
        let detail = detail.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : ($0.hasSuffix(".") ? String($0.dropLast()) : $0) }
        let lingers = dialect == "pgsql"
            ? "It may run to its end: PostgreSQL usually notices the closed connection only then."
            : "It keeps running until it ends or the database notices the closed connection."
        var text: String
        switch outcome {
        case .cancelled:
            text = "Cancelled the statement on the server (\(shortStatement))."
            if dialect == "sqlsrv" { text += " SQL Server's KILL ended the session and rolled back its open transaction." }
        case .stillRunning:
            let waited = elapsedMs.map { String(format: " %.1f s later", $0 / 1000) } ?? ""
            text = "The server accepted \(shortStatement), but the statement was still running\(waited)\(state.map { " (\($0))" } ?? ""). The database finishes cancelling it, and undoing its changes, on its own."
        case .alreadyEnded:
            text = "Session \(session) had already ended on the server, so there was no statement to cancel."
        case .idle:
            text = "The statement had already finished on the server (session \(session) was idle), so there was nothing to cancel."
        case .refused:
            text = "Runlet didn't cancel the statement on the server" + (detail.map { ": \($0)." } ?? ".") + " " + lingers
        case .failed:
            text = "Runlet couldn't cancel the statement on the server (\(shortStatement))" + (detail.map { ": \($0)." } ?? ".") + " " + lingers
        case .timedOut:
            text = "Runlet couldn't cancel the statement on the server: the second runner didn't answer within \(SQLCancel.timeout.components.seconds) s. " + lingers
        }
        if transaction == true {
            switch outcome {
            case .cancelled, .stillRunning, .idle, .alreadyEnded:
                text += dialect == "mysql"
                    ? " The open transaction is rolled back (statements MySQL committed at once stay)."
                    : " The open transaction is rolled back."
            case .refused, .failed, .timedOut:
                text += " The database rolls back the open transaction once the statement ends and it notices the closed connection."
            }
        }
        return text
    }
}
