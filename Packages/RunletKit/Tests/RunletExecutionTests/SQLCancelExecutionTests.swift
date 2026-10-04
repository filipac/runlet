import Foundation
@testable import RunletCore
import Testing
@testable import RunletExecution

extension Array where Element == RunEvent {
    /// Stop's server cancel (#144).
    var sqlCancel: SQLCancelReport? {
        for event in self { if case .sqlCancel(let report) = event.kind { return report } }
        return nil
    }

    var logEntries: [RunLogEntry] {
        compactMap { if case .log(let entry) = $0.kind { return entry } else { return nil } }
    }
}

/// Stop on an SQL run (#144), with host PHP and SQLite: SQLite reports no database session, so
/// Stop ends the runner as before (no second runner, no report); the second runner refuses a
/// connection of another kind; the runner still loads on PHP 7.4.
@Suite(.serialized, .enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct SQLCancelExecutionTests {
    /// SQLite counting forever, until Stop.
    static let endless = "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n) SELECT COUNT(*) FROM n"

    struct Stopped {
        var events: [RunEvent]
        var outcome: CancelOutcome?
        var session: SQLSessionInfo?
        /// From Stop to the run's last event.
        var took: Duration
    }

    /// Starts `request`, waits until the run reported its database session (at most `wait`), lets
    /// the statement run for `running`, then Stops it as the app does.
    static func runAndStop(_ request: RunRequest, engine: ExecutionEngine, wait: Duration = .seconds(20), running: Duration = .milliseconds(500)) async throws -> Stopped {
        let stream = try await engine.start(request)
        let collector = Task {
            var events: [RunEvent] = []
            for await event in stream { events.append(event) }
            return events
        }
        var session: SQLSessionInfo?
        let deadline = ContinuousClock.now + wait
        while session == nil, ContinuousClock.now < deadline {
            session = await engine.sqlSession(runId: request.runId)
            if session == nil { try await Task.sleep(for: .milliseconds(25)) }
        }
        try await Task.sleep(for: running)
        let stopped = ContinuousClock.now
        let outcome = await engine.cancel(runId: request.runId)
        let events = await collector.value
        return Stopped(events: events, outcome: outcome, session: session, took: ContinuousClock.now - stopped)
    }

    static func request(_ code: String, in directory: URL, php: String? = nil) -> RunRequest {
        RunRequest(tabId: UUID(), documentVersion: 1, target: DriverSupport.target(directory.path, php: php), code: code, inspector: RunInspectorOptions(), magicComments: false)
    }

    @Test func sqliteKeepsTodaysStop() async throws {
        let directory = try SQLScriptExecutionTests().project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
        let stopped = try await Self.runAndStop(Self.request(SQLTabRun.code(statement: Self.endless, connection: nil), in: directory), engine: engine, wait: .seconds(1))
        #expect(stopped.session == nil, "SQLite has no server session")
        #expect(stopped.events.finished?.status == .cancelled)
        #expect(stopped.events.sqlCancel == nil, "no second runner")
        #expect(stopped.outcome?.server == nil)
        #expect(stopped.outcome?.confirmed == true)
        #expect(!stopped.events.logEntries.contains { $0.source == "cancel" || $0.source == "sql" })
        #expect(stopped.took < .seconds(3), "\(stopped.took)")
    }

    @Test func savedSQLiteConnectionsKeepTodaysStopToo() async throws {
        let directory = try SQLSavedConnectionTests.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = SQLSavedConnectionTests.connection()
        let (engine, _) = try SQLSavedConnectionTests.engine(for: connection)
        var request = Self.request(SQLTabRun.code(statement: Self.endless, connection: nil), in: directory)
        request.sqlConnection = connection
        let stopped = try await Self.runAndStop(request, engine: engine, wait: .seconds(1))
        #expect(stopped.session == nil)
        #expect(stopped.events.finished?.status == .cancelled)
        #expect(stopped.events.sqlCancel == nil)
    }

    /// The second runner checks the connection is of the statement's kind before sending.
    @Test func cancelRefusesAConnectionOfAnotherKind() async throws {
        let directory = try SQLScriptExecutionTests().project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SQLSessionInfo(driver: "mysql", id: 42)
        let code = SQLCancel.code(SQLCancel.plan(for: session)!, session: session)
        let events = try await TestSupport.run(code, target: DriverSupport.target(directory.path), magicComments: false)
        #expect(events.errors.isEmpty, "\(events.errors)")
        let report = try #require(Self.report(events))
        #expect(report.outcome == .failed)
        #expect(report.detail == "the connection is a sqlite connection now, and the statement ran on mysql", "\(report.detail ?? "")")
    }

    /// The second runner's `sqlCancel` frame, as the engine reads it.
    static func report(_ events: [RunEvent]) -> SQLCancelReport? {
        events.sqlCancel
    }

    /// A second runner that doesn't answer (its application takes too long to boot) is stopped
    /// after `SQLCancel.timeout`, and so is the run.
    @Test func aSecondRunnerThatHangsIsStoppedAndSoIsTheRun() async throws {
        let directory = try DriverSupport.composerProject(drivers: ["SlowDriver.php": """
        <?php
        class SlowDriver extends \\Runlet\\Driver
        {
            public function bootstrap(string $projectPath): void
            {
                if (file_exists($projectPath . '/slow.marker')) {
                    sleep(30);
                }
            }
        }
        """])
        defer { try? FileManager.default.removeItem(at: directory) }
        let code = """
            <?php
            file_put_contents(getcwd() . '/slow.marker', 'x');
            \\RunletRunner\\Channel::emit('sqlSession', ['driver' => 'pgsql', 'id' => 812]);
            sleep(30);
            """
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
        let stopped = try await Self.runAndStop(Self.request(code, in: directory), engine: engine)
        #expect(stopped.session?.id == 812)
        #expect(stopped.events.finished?.status == .cancelled)
        #expect(stopped.events.sqlCancel?.outcome == .timedOut, "\(String(describing: stopped.events.sqlCancel))")
        #expect(stopped.took >= SQLCancel.timeout && stopped.took < SQLCancel.timeout + .seconds(4), "\(stopped.took)")
        let active = await engine.activeRunIds
        #expect(active.isEmpty, "the second runner was stopped too: \(active)")
    }

    @Test(.enabled(if: TestSupport.herdPHP74 != nil, "requires PHP 7.4"))
    func runsAndCancelsOnPHP74() async throws {
        let php74 = try #require(TestSupport.herdPHP74)
        let directory = try SQLScriptExecutionTests().project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = try await TestSupport.run(SQLTabRun.code(statement: "SELECT SUM(amount) FROM entries", connection: nil), target: DriverSupport.target(directory.path, php: php74), magicComments: false)
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.sqlResult?.rows.first?.first?.text == "30")
        let session = SQLSessionInfo(driver: "pgsql", id: 7)
        let cancel = try await TestSupport.run(SQLCancel.code(SQLCancel.plan(for: session)!, session: session), target: DriverSupport.target(directory.path, php: php74), magicComments: false)
        #expect(cancel.errors.isEmpty, "\(cancel.errors)")
        #expect(cancel.sqlCancel?.outcome == .failed)
    }
}

/// Stop's second runner (#144) goes where the run went: `docker exec` into the same container,
/// or over SSH to the same server. The fixtures' PHP has no MySQL or PostgreSQL driver, so a
/// PHP snippet reports a session itself and sleeps; the second runner finds no connection,
/// says so, and the run still stops within a few seconds.
enum SQLCancelTransport {
    static let fakeSession = """
        <?php
        \\RunletRunner\\Channel::emit('sqlSession', ['driver' => 'mysql', 'id' => 4711, 'server' => 'abc']);
        sleep(30);
        """

    static func expectReportedAndStopped(_ stopped: SQLCancelExecutionTests.Stopped, _ label: String) {
        #expect(stopped.session?.id == 4711, "\(label)")
        #expect(stopped.events.finished?.status == .cancelled, "\(label)")
        #expect(stopped.took < .seconds(8), "\(label): Stop took \(stopped.took)")
        let report = stopped.events.sqlCancel
        #expect(report?.outcome == .failed, "\(label): \(String(describing: report))")
        // The second runner ran on the target: it booted the project there and found no MySQL
        // connection (the `custom` fixture's driver has an SQLite one; the SSH site has none).
        let detail = report?.detail ?? ""
        #expect(detail.contains("no database connection that SQL tabs can use") || detail == "the connection is a sqlite connection now, and the statement ran on mysql", "\(label): \(detail)")
        #expect(report?.message.hasPrefix("Runlet couldn't cancel the statement on the server (KILL QUERY 4711): ") == true, "\(label)")
    }
}

@Suite(.serialized, .live(.docker), .enabled(if: TestSupport.hasDocker, "requires a running Docker engine"))
struct SQLCancelDockerTests {
    @Test func secondRunnerRunsInTheSameContainer() async throws {
        let containers = try await TestSupport.docker!.runningContainers()
        let container = try #require(containers.first { $0.composeProject == "runlet-fixtures" && $0.composeService == "custom" }, "start fixtures with scripts/setup-fixtures.sh docker")
        let target = TargetSnapshot(kind: .docker, label: container.name, targetId: container.id, workingDirectory: "/var/www", phpExecutable: "php", containerId: container.id, containerName: container.name, image: container.image, temporaryDirectory: "/tmp")
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: TestSupport.docker)
        let request = RunRequest(tabId: UUID(), documentVersion: 1, target: target, code: SQLCancelTransport.fakeSession, magicComments: false)
        let stopped = try await SQLCancelExecutionTests.runAndStop(request, engine: engine)
        SQLCancelTransport.expectReportedAndStopped(stopped, "docker")
    }
}

@Suite(.serialized, .live(.ssh), .enabled(if: SSHFixture.available, "requires Docker and /usr/bin/ssh"))
struct SQLCancelSSHTests {
    @Test func secondRunnerRunsOnTheSameServer() async throws {
        let environment = try await SSHFixture.environment()
        let endpoint = environment.endpoint()
        let client = environment.client()
        defer { Task { await client.disconnect(endpoint) } }
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil, ssh: client)
        let request = RunRequest(tabId: UUID(), documentVersion: 1, target: environment.target(endpoint), code: SQLCancelTransport.fakeSession, magicComments: false)
        let stopped = try await SQLCancelExecutionTests.runAndStop(request, engine: engine)
        SQLCancelTransport.expectReportedAndStopped(stopped, "ssh")
    }
}
