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
@Suite(.serialized, .live(.sql), .enabled(if: TestSupport.hasPHP, "requires host PHP"))
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

    /// How many sessions still run a statement with `marker`, other than the check's own. A
    /// check that takes longer than `limit` fails the test, naming the marker (#182).
    static func running(_ server: Server, marker: String, within limit: Duration = .seconds(10)) async throws -> Int {
        let sql = server.dialect == "mysql"
            ? "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE INFO LIKE '%\(marker)%' AND ID <> CONNECTION_ID()"
            : "SELECT COUNT(*) FROM pg_stat_activity WHERE state = 'active' AND query LIKE '%\(marker)%' AND pid <> pg_backend_pid()"
        let check = try await TestProcess.run(server.execCommand(sql), step: "the \(server.dialect) process-list check for \(marker)", within: limit)
        return Int(check.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    /// Waits up to `within` for the server to run nothing with `marker` (each check bounded by
    /// `running`'s own limit).
    static func gone(_ server: Server, marker: String, within: Duration = .seconds(3)) async throws -> Bool {
        let deadline = ContinuousClock.now + within
        repeat {
            if try await running(server, marker: marker) == 0 { return true }
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
        // The database's cancellation error is marked: an info line, not an error card.
        let errors = stopped.events.errors
        #expect(!errors.isEmpty && errors.allSatisfy { $0.interruptedByStop == true }, "\(label): \(errors)")
        #expect(report.interrupted == true, "\(label)")
        #expect(errors.first.map(SQLCancel.interruptedText)?.hasPrefix("Interrupted by Stop") == true, "\(label)")
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

    /// A saved connection that opens from this Mac (#142): the second runner starts where the run
    /// did, with the same local PHP in Runlet's empty folder, not on the tab's target.
    @Test(.enabled(if: !SQLLiveDatabaseTests.servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func fromThisMacTheSecondRunnerStaysOnThisMac() async throws {
        for server in SQLLiveDatabaseTests.servers {
            let (connection, store) = SQLLiveFromThisMacTests.connection(server)
            #expect(connection.opensOnThisMac)
            let place = try SQLLiveFromThisMacTests.place(connection, store: store, php: LocalConnectionLaunch.PHP(path: DriverSupport.php, label: "host PHP", isRunletPHP: false))
            defer { try? FileManager.default.removeItem(at: place.root) }
            let marker = Self.marker()
            var request = RunRequest(tabId: UUID(), documentVersion: 1, target: place.target, code: SQLTabRun.code(statement: Self.sleep(server, marker: marker), connection: nil), magicComments: false)
            request.sqlConnection = connection
            let stopped = try await SQLCancelExecutionTests.runAndStop(request, engine: place.engine)
            try await expectCancelled(stopped, server, marker: marker, "\(server.dialect) from this Mac")
            let second = stopped.events.logEntries.first { $0.source == "cancel" && $0.message.hasPrefix("Second runner: ") }
            #expect(second?.message.contains(DriverSupport.php) == true, "\(server.dialect): \(second?.message ?? "none")")
            #expect(second?.detail?.contains(place.folder.lastPathComponent) == true && second?.detail?.contains(place.root.lastPathComponent) == true, "\(server.dialect): \(second?.detail ?? "none")")
            // Runlet's folder stays empty.
            #expect((try? FileManager.default.contentsOfDirectory(atPath: place.folder.path))?.isEmpty == true)
        }
    }

    /// A cancel that isn't Stop's (another session's KILL QUERY / pg_cancel_backend) keeps the
    /// database's error card.
    @Test(.enabled(if: !SQLLiveDatabaseTests.servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func someoneElsesCancelKeepsTheErrorCard() async throws {
        for server in SQLLiveDatabaseTests.servers {
            try Self.setup(server)
            let directory = try server.project()
            defer { try? FileManager.default.removeItem(at: directory) }
            let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
            let request = SQLCancelExecutionTests.request(SQLTabRun.code(statement: Self.sleep(server, marker: Self.marker()), connection: nil), in: directory)
            let stream = try await engine.start(request)
            let collector = Task {
                var events: [RunEvent] = []
                for await event in stream { events.append(event) }
                return events
            }
            var session: SQLSessionInfo?
            let deadline = ContinuousClock.now + .seconds(20)
            while session == nil, ContinuousClock.now < deadline {
                session = await engine.sqlSession(runId: request.runId)
                if session == nil { try await Task.sleep(for: .milliseconds(25)) }
            }
            guard let id = session?.id else {
                _ = await engine.cancel(runId: request.runId)
                collector.cancel()
                Issue.record("\(server.dialect): the run reported no database session within 20 seconds")
                continue
            }
            try await Task.sleep(for: .milliseconds(400))
            _ = try server.exec(server.dialect == "mysql" ? "KILL QUERY \(id)" : "SELECT pg_cancel_backend(\(id))")
            let events = await collector.value
            #expect(events.finished?.status == .failed, "\(server.dialect)")
            let error = try #require(events.errors.first, "\(server.dialect)")
            #expect(SQLCancel.isCancellationError(error, driver: server.dialect), "\(server.dialect): \(error.message)")
            #expect(error.interruptedByStop == nil, "\(server.dialect): not Stop's")
            #expect(events.sqlCancel == nil)
        }
    }

    /// Without the server cancel, MariaDB keeps sleeping after the process is gone (the problem
    /// #144 fixes): a control for the test above. The client is stopped and awaited with
    /// deadlines (#182): its `waitUntilExit()` after the `await` once hung the whole run.
    @Test(.enabled(if: SQLLiveDatabaseTests.mysql != nil, "set RUNLET_TEST_MYSQL"))
    func killingOnlyTheProcessLeavesMariaDBRunning() async throws {
        let server = try #require(SQLLiveDatabaseTests.mysql)
        let marker = Self.marker()
        let client = TestProcess([DriverSupport.php, "-r", "$p = new PDO($argv[1], $argv[2], $argv[3]); $p->query($argv[4]);", server.dsn, server.user, server.password, "SELECT SLEEP(4) AS \(marker)"], step: "the plain PHP client")
        try client.start()
        try await Task.sleep(for: .milliseconds(700))
        let ending = await client.stop(grace: .seconds(2))
        try #require(ending == .terminated || ending == .killed, "the plain PHP client \(ending.rawValue) when it was stopped: \(client.errors)\(client.output)")
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await Self.running(server, marker: marker) == 1, "MariaDB still runs the statement of a killed client")
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
            // The interrupted line says what the runner rolled back; the report doesn't repeat it.
            let interrupted = stopped.events.errors.first.map(SQLCancel.interruptedText) ?? ""
            #expect(interrupted.hasPrefix("Interrupted by Stop: statement 2 of 3 (line 2). Rolled back the transaction"), "\(interrupted)")
            #expect(stopped.events.sqlCancel?.message.contains("rolled back") == false, "\(stopped.events.sqlCancel?.message ?? "")")
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

    /// A session of `user` held open by host PHP, which sleeps in PHP (idle) or in SQL. Its id
    /// must arrive within `limit` (#182). Stop the holder with `stopBlocking()` when done.
    static func holdSession(_ server: Server, user: String, password: String, sql: String?, within limit: Duration = .seconds(10)) async throws -> (TestProcess, Int64) {
        let id = server.dialect == "mysql" ? "SELECT CONNECTION_ID()" : "SELECT pg_backend_pid()"
        let holder = TestProcess([DriverSupport.php, "-r", "$p = new PDO($argv[1], $argv[2], $argv[3]); echo $p->query($argv[4])->fetchColumn(), \"\\n\"; if ($argv[5] !== '') { $p->query($argv[5]); } else { sleep(6); }", server.dsn, user, password, id, sql ?? ""], step: "the \(server.dialect) session holder")
        try holder.start()
        let line = try await holder.firstLine(within: limit)
        if let session = line.flatMap({ Int64($0.trimmingCharacters(in: .whitespaces)) }) { return (holder, session) }
        let ending = await holder.stop()
        if line == nil, ending != .exited {
            throw TestProcess.Timeout(step: "\(holder.step)'s session id", limit: limit, ending: ending, output: holder.output, errors: holder.errors)
        }
        throw TestProcess.Failure("\(holder.step) printed no session id: \(holder.errors)\(holder.output)")
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
            let (idler, idle) = try await Self.holdSession(server, user: server.user, password: server.password, sql: nil)
            defer { idler.stopBlocking() }
            let idleReport = try await Self.cancel(server, session: SQLSessionInfo(driver: server.dialect, id: idle), in: directory)
            #expect(idleReport.outcome == .idle, "\(label): \(idleReport)")
            // Only Runlet's own statement for the session goes out.
            let other = try await Self.cancel(server, session: SQLSessionInfo(driver: server.dialect, id: idle), statement: "DROP TABLE p144_ledger", in: directory)
            #expect(other.outcome == .refused, "\(label): \(other)")
            #expect(other.detail == "Runlet sends only its own cancel statement for session \(idle)")
            #expect(try server.exec("SELECT COUNT(*) FROM p144_ledger") == "0", "\(label): the table is still there")
            // Another server (a fingerprint that doesn't match): nothing is sent.
            let marker = Self.marker()
            let (sleeper, busy) = try await Self.holdSession(server, user: server.user, password: server.password, sql: "SELECT \(server.dialect == "mysql" ? "SLEEP(4)" : "pg_sleep(4)") AS \(marker)")
            defer { sleeper.stopBlocking() }
            try await Task.sleep(for: .milliseconds(300))
            let elsewhere = try await Self.cancel(server, session: SQLSessionInfo(driver: server.dialect, id: busy, server: "0000000000000000"), in: directory)
            #expect(elsewhere.outcome == .refused, "\(label): \(elsewhere)")
            #expect(elsewhere.detail?.contains("another database server") == true, "\(label): \(elsewhere)")
            #expect(try await Self.running(server, marker: marker) == 1, "\(label): still sleeping")
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
            let (sleeper, busy) = try await Self.holdSession(server, user: server.user, password: server.password, sql: "SELECT \(server.dialect == "mysql" ? "SLEEP(4)" : "pg_sleep(4)") AS \(marker)")
            defer { sleeper.stopBlocking() }
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
            #expect(try await Self.running(server, marker: marker) == 1, "\(server.dialect): still sleeping")
        }
    }
}
