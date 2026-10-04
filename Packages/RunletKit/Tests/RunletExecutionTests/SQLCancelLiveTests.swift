import Foundation
@testable import RunletCore
import Testing
@testable import RunletExecution

/// Stop cancels the statement on the server (#144), against live MariaDB 11 and PostgreSQL 14
/// (the throwaway fixture containers of `scripts/setup-fixtures.sh databases`, through
/// `RUNLET_TEST_MYSQL` / `RUNLET_TEST_PGSQL`). A `SLEEP(30)` / `pg_sleep(30)` stops within a few
/// seconds and is gone from the server's process list: on an application connection, a saved
/// one, a read-only saved one, in Run All with a transaction (rolled back), Load Next's page,
/// and Explain Analyze. The second runner's checks and refusals run against the servers too.
/// The tests use their own `p144_` table and the `p144_reader` user, created on each run.
@Suite(.serialized, .enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct SQLCancelLiveTests {
    typealias Server = SQLLiveDatabaseTests.Server
    static let reader = (user: "p144_reader", password: "p144-fixture")

    /// `p144_ledger` (empty) and a user who may only read, for refusals.
    static func setup(_ server: Server) throws {
        _ = try server.exec("DROP TABLE IF EXISTS p144_ledger")
        if server.dialect == "mysql" {
            _ = try server.exec("CREATE TABLE p144_ledger (id INT AUTO_INCREMENT PRIMARY KEY, note VARCHAR(40) NOT NULL) ENGINE=InnoDB")
            _ = try server.exec("CREATE USER IF NOT EXISTS p144_reader@'%' IDENTIFIED BY 'p144-fixture'")
            _ = try server.exec("GRANT SELECT ON shop.* TO p144_reader@'%'")
        } else {
            _ = try server.exec("CREATE TABLE p144_ledger (id SERIAL PRIMARY KEY, note VARCHAR(40) NOT NULL)")
            _ = try server.exec("DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'p144_reader') THEN CREATE ROLE p144_reader LOGIN PASSWORD 'p144-fixture'; END IF; END $$")
            _ = try server.exec("GRANT CONNECT ON DATABASE shop TO p144_reader")
        }
    }

    /// A statement that sleeps 30 s, marked so the server's process list finds it.
    static func sleep(_ server: Server, marker: String) -> String {
        server.dialect == "mysql" ? "SELECT SLEEP(30) AS \(marker)" : "SELECT pg_sleep(30) AS \(marker)"
    }

    /// How many sessions still run a statement with `marker`, other than the check's own.
    static func running(_ server: Server, marker: String) throws -> Int {
        let sql = server.dialect == "mysql"
            ? "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE INFO LIKE '%\(marker)%' AND ID <> CONNECTION_ID()"
            : "SELECT COUNT(*) FROM pg_stat_activity WHERE state = 'active' AND query LIKE '%\(marker)%' AND pid <> pg_backend_pid()"
        return Int(try server.exec(sql)) ?? -1
    }

    /// Waits up to `within` for the server to run nothing with `marker`.
    static func gone(_ server: Server, marker: String, within: Duration = .seconds(3)) async throws -> Bool {
        let deadline = ContinuousClock.now + within
        repeat {
            if try running(server, marker: marker) == 0 { return true }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        return false
    }

    static func marker() -> String { "p144_" + UUID().uuidString.prefix(8).lowercased() }

    /// The common checks after Stop: quick, cancelled, a confirmed report, gone on the server.
    func expectCancelled(_ stopped: SQLCancelExecutionTests.Stopped, _ server: Server, marker: String, _ label: String) async throws {
        #expect(stopped.session?.driver == server.dialect, "\(label): \(String(describing: stopped.session))")
        #expect(stopped.took < .seconds(5), "\(label): Stop took \(stopped.took)")
        #expect(stopped.events.finished?.status == .cancelled, "\(label)")
        let report = try #require(stopped.events.sqlCancel, "\(label): \(stopped.events.errors)")
        #expect(report.outcome == .cancelled, "\(label): \(report)")
        #expect(report.verified == true, "\(label): \(report)")
        #expect(stopped.outcome?.server == report)
        #expect(report.message.hasPrefix("Cancelled the statement on the server ("), "\(label): \(report.message)")
        #expect(stopped.events.logEntries.contains { $0.source == "cancel" && $0.message.hasPrefix("Stop: cancelling the statement on the server with") }, "\(label)")
        #expect(stopped.events.logEntries.contains { $0.source == "sql" && $0.message.hasPrefix("Database session ") }, "\(label)")
        // The report comes before the run's last event.
        if case .finished = stopped.events.last?.kind {} else { Issue.record("\(label): finished must be last") }
        #expect(try await Self.gone(server, marker: marker), "\(label): the statement still runs on the server")
    }

    @Test(.enabled(if: !SQLLiveDatabaseTests.servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func applicationConnectionStopCancelsOnTheServer() async throws {
        for server in SQLLiveDatabaseTests.servers {
            try Self.setup(server)
            let directory = try server.project()
            defer { try? FileManager.default.removeItem(at: directory) }
            let marker = Self.marker()
            let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
            let request = SQLCancelExecutionTests.request(SQLTabRun.code(statement: Self.sleep(server, marker: marker), connection: nil), in: directory)
            let stopped = try await SQLCancelExecutionTests.runAndStop(request, engine: engine)
            try await expectCancelled(stopped, server, marker: marker, server.dialect)
            let expected = server.dialect == "mysql" ? "KILL QUERY \(stopped.session?.id ?? 0)" : "SELECT pg_cancel_backend(\(stopped.session?.id ?? 0))"
            #expect(stopped.events.sqlCancel?.statement == expected)
            #expect(stopped.session?.server?.count == 16, "a server fingerprint")
            #expect(stopped.session?.saved == nil && stopped.session?.connection == nil)
        }
    }

    /// Without the server cancel, MariaDB keeps sleeping after the process is gone (the problem
    /// #144 fixes): a control for the test above.
    @Test(.enabled(if: SQLLiveDatabaseTests.mysql != nil, "set RUNLET_TEST_MYSQL"))
    func killingOnlyTheProcessLeavesMariaDBRunning() async throws {
        let server = try #require(SQLLiveDatabaseTests.mysql)
        let marker = Self.marker()
        let php = Process()
        php.executableURL = URL(fileURLWithPath: DriverSupport.php)
        php.arguments = ["-r", "$p = new PDO($argv[1], $argv[2], $argv[3]); $p->query($argv[4]);", server.dsn, server.user, server.password, "SELECT SLEEP(4) AS \(marker)"]
        try php.run()
        try await Task.sleep(for: .milliseconds(700))
        php.terminate()
        php.waitUntilExit()
        try await Task.sleep(for: .milliseconds(300))
        #expect(try Self.running(server, marker: marker) == 1, "MariaDB still runs the statement of a killed client")
        #expect(try await Self.gone(server, marker: marker, within: .seconds(6)))
    }

    @Test(.enabled(if: !SQLLiveDatabaseTests.servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func savedAndReadOnlySavedConnectionsCancelToo() async throws {
        for server in SQLLiveDatabaseTests.servers {
            try Self.setup(server)
            let directory = try SQLSavedConnectionTests.project()
            defer { try? FileManager.default.removeItem(at: directory) }
            for readOnly in [false, true] {
                var (connection, store) = SQLLiveDatabaseTests.saved(server)
                connection.readOnly = readOnly
                let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil, credentials: store)
                let marker = Self.marker()
                var request = SQLCancelExecutionTests.request(SQLTabRun.code(statement: Self.sleep(server, marker: marker), connection: nil), in: directory)
                request.sqlConnection = connection
                let stopped = try await SQLCancelExecutionTests.runAndStop(request, engine: engine)
                let label = "\(server.dialect)\(readOnly ? ", read-only" : "")"
                try await expectCancelled(stopped, server, marker: marker, label)
                #expect(stopped.session?.saved == true, "\(label)")
                // The password never reaches an event, the second runner's report included.
                let text = stopped.events.map { "\($0.kind)" }.joined(separator: "\n")
                #expect(!text.contains(server.password), "\(label)")
                // No project code ran in either runner.
                #expect(SQLSavedConnectionTests.markers(in: directory).isEmpty, "\(label)")
            }
        }
    }

    @Test(.enabled(if: !SQLLiveDatabaseTests.servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func runAllInATransactionIsRolledBack() async throws {
        for server in SQLLiveDatabaseTests.servers {
            try Self.setup(server)
            let directory = try server.project()
            defer { try? FileManager.default.removeItem(at: directory) }
            let marker = Self.marker()
            let script = "INSERT INTO p144_ledger (note) VALUES ('first');\n\(Self.sleep(server, marker: marker));\nINSERT INTO p144_ledger (note) VALUES ('never');"
            let statements = try SQLScript.statementsToRunAll(in: script, selection: NSRange(location: 0, length: 0)).get()
            let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
            let request = SQLCancelExecutionTests.request(SQLTabRun.scriptCode(statements: statements, connection: nil, transaction: true), in: directory)
            let stopped = try await SQLCancelExecutionTests.runAndStop(request, engine: engine)
            try await expectCancelled(stopped, server, marker: marker, server.dialect)
            #expect(stopped.session?.transaction == true)
            #expect(stopped.events.sqlCancel?.message.contains("The open transaction is rolled back") == true, "\(stopped.events.sqlCancel?.message ?? "")")
            #expect(try server.exec("SELECT COUNT(*) FROM p144_ledger") == "0", "\(server.dialect): the first INSERT was rolled back, the last never ran")
        }
    }

    @Test(.enabled(if: !SQLLiveDatabaseTests.servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func loadNextAndExplainAnalyzeCancelToo() async throws {
        for server in SQLLiveDatabaseTests.servers {
            try Self.setup(server)
            let directory = try server.project()
            defer { try? FileManager.default.removeItem(at: directory) }
            let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
            // Load Next (#146): a page whose statement sleeps.
            let pageMarker = Self.marker()
            let page = SQLPaging.Page(sql: Self.sleep(server, marker: pageMarker), offset: 1, size: 10, skip: 1, driver: nil, added: nil)
            let paged = try await SQLCancelExecutionTests.runAndStop(SQLCancelExecutionTests.request(SQLTabRun.pageCode(page, connection: nil), in: directory), engine: engine)
            try await expectCancelled(paged, server, marker: pageMarker, "\(server.dialect) Load Next")
            // Explain Analyze (#147) runs the statement.
            let explainMarker = Self.marker()
            let explain = SQLExplain.code(statement: Self.sleep(server, marker: explainMarker), connection: nil, mode: .analyze)
            let explained = try await SQLCancelExecutionTests.runAndStop(SQLCancelExecutionTests.request(explain, in: directory), engine: engine)
            try await expectCancelled(explained, server, marker: explainMarker, "\(server.dialect) Explain Analyze")
        }
    }

    // MARK: The second runner's checks

    /// A project whose driver connects as `user`.
    static func project(_ server: Server, user: String, password: String) throws -> URL {
        try DriverSupport.composerProject(drivers: ["ReaderDriver.php": """
        <?php
        class ReaderDriver extends \\Runlet\\Driver
        {
            public function bootstrap(string $projectPath): void
            {
            }

            public function sqlConnection(?string $connection)
            {
                return new \\PDO(\(Server.php(server.dsn)), \(Server.php(user)), \(Server.php(password)));
            }
        }
        """])
    }

    /// Runs the second runner's code for `session` directly.
    static func cancel(_ server: Server, session: SQLSessionInfo, statement: String? = nil, in directory: URL) async throws -> SQLCancelReport {
        var plan = try #require(SQLCancel.plan(for: session))
        if let statement { plan.statement = statement }
        let events = try await TestSupport.run(SQLCancel.code(plan, session: session), target: DriverSupport.target(directory.path), magicComments: false)
        #expect(events.errors.isEmpty, "\(events.errors)")
        return try #require(events.sqlCancel, "\(events)")
    }

    /// A session of `user` held open by host PHP, which sleeps in PHP (idle) or in SQL.
    static func holdSession(_ server: Server, user: String, password: String, sql: String?) throws -> (Process, Int64) {
        let php = Process()
        php.executableURL = URL(fileURLWithPath: DriverSupport.php)
        let id = server.dialect == "mysql" ? "SELECT CONNECTION_ID()" : "SELECT pg_backend_pid()"
        php.arguments = ["-r", "$p = new PDO($argv[1], $argv[2], $argv[3]); echo $p->query($argv[4])->fetchColumn(), \"\\n\"; if ($argv[5] !== '') { $p->query($argv[5]); } else { sleep(6); }", server.dsn, user, password, id, sql ?? ""]
        let output = Pipe()
        php.standardOutput = output
        try php.run()
        var line = Data()
        while !line.contains(10) {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            line.append(chunk)
        }
        let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (php, Int64(text) ?? 0)
    }

    @Test(.enabled(if: !SQLLiveDatabaseTests.servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func secondRunnerChecksBeforeItSends() async throws {
        for server in SQLLiveDatabaseTests.servers {
            try Self.setup(server)
            let directory = try server.project()
            defer { try? FileManager.default.removeItem(at: directory) }
            let label = server.dialect
            // The session is gone.
            let gone = try await Self.cancel(server, session: SQLSessionInfo(driver: server.dialect, id: 2_000_000_000), in: directory)
            #expect(gone.outcome == .alreadyEnded, "\(label): \(gone)")
            // The session is idle: nothing is sent.
            let (idler, idle) = try Self.holdSession(server, user: server.user, password: server.password, sql: nil)
            defer { idler.terminate() }
            let idleReport = try await Self.cancel(server, session: SQLSessionInfo(driver: server.dialect, id: idle), in: directory)
            #expect(idleReport.outcome == .idle, "\(label): \(idleReport)")
            // Only Runlet's own statement for the session goes out.
            let other = try await Self.cancel(server, session: SQLSessionInfo(driver: server.dialect, id: idle), statement: "DROP TABLE p144_ledger", in: directory)
            #expect(other.outcome == .refused, "\(label): \(other)")
            #expect(other.detail == "Runlet sends only its own cancel statement for session \(idle)")
            #expect(try server.exec("SELECT COUNT(*) FROM p144_ledger") == "0", "\(label): the table is still there")
            // Another server (a fingerprint that doesn't match): nothing is sent.
            let marker = Self.marker()
            let (sleeper, busy) = try Self.holdSession(server, user: server.user, password: server.password, sql: "SELECT \(server.dialect == "mysql" ? "SLEEP(4)" : "pg_sleep(4)") AS \(marker)")
            defer { sleeper.terminate() }
            try await Task.sleep(for: .milliseconds(300))
            let elsewhere = try await Self.cancel(server, session: SQLSessionInfo(driver: server.dialect, id: busy, server: "0000000000000000"), in: directory)
            #expect(elsewhere.outcome == .refused, "\(label): \(elsewhere)")
            #expect(elsewhere.detail?.contains("another database server") == true, "\(label): \(elsewhere)")
            #expect(try Self.running(server, marker: marker) == 1, "\(label): still sleeping")
        }
    }

    /// A user who may not cancel the session gets a clear refusal, and the statement runs on.
    @Test(.enabled(if: !SQLLiveDatabaseTests.servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func anotherUsersSessionIsRefused() async throws {
        for server in SQLLiveDatabaseTests.servers {
            try Self.setup(server)
            let directory = try Self.project(server, user: Self.reader.user, password: Self.reader.password)
            defer { try? FileManager.default.removeItem(at: directory) }
            let marker = Self.marker()
            let (sleeper, busy) = try Self.holdSession(server, user: server.user, password: server.password, sql: "SELECT \(server.dialect == "mysql" ? "SLEEP(4)" : "pg_sleep(4)") AS \(marker)")
            defer { sleeper.terminate() }
            try await Task.sleep(for: .milliseconds(300))
            let report = try await Self.cancel(server, session: SQLSessionInfo(driver: server.dialect, id: busy), in: directory)
            #expect(report.outcome == .refused, "\(server.dialect): \(report)")
            if server.dialect == "mysql" {
                // The reader can't see root's thread, so the database refuses KILL QUERY.
                #expect(report.detail?.hasPrefix("the database user may not cancel session \(busy) (You are not owner of thread \(busy))") == true, "\(report.detail ?? "")")
                #expect(report.message.contains("CONNECTION_ADMIN or SUPER"), "\(report.message)")
            } else {
                // PostgreSQL shows whose session it is, so Runlet refuses before sending.
                #expect(report.detail == "session \(busy) belongs to another database user now", "\(report.detail ?? "")")
            }
            #expect(try Self.running(server, marker: marker) == 1, "\(server.dialect): still sleeping")
        }
    }
}
