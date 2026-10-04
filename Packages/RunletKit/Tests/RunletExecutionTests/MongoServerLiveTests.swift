import Foundation
@testable import RunletCore
import Testing
@testable import RunletExecution

/// MongoDB's server panel and Stop (#207), live against the `mongo:7` fixture
/// (`RUNLET_TEST_MONGODB`): Stop finds the run's operation by its `runlet:<run id>` comment with
/// `currentOp` and kills it from a second runner (on the target, from this Mac, and through the
/// SSH fixture's tunnel), the output says "Interrupted by Stop"; the Server section reads
/// `serverStatus` and `$currentOp`, and Kill Op refuses the panel's own operation and kills only
/// an operation this test started. Data lives in `p207_` collections of `p207_tests`.
@Suite(.serialized, .live(.mongo), .enabled(if: LiveServers.mongo != nil && TestSupport.hasPHP))
struct MongoServerLiveTests {
    static func fixture() throws -> (connection: DatabaseConnection, password: String) {
        let value = try #require(LiveServers.mongo)
        let parts = value.components(separatedBy: "|")
        let url = try #require(URLComponents(string: parts[0]))
        let connection = DatabaseConnection(name: "Mongo fixture", scope: .local(UUID()), driver: .mongodb, host: "127.0.0.1", port: url.port, database: "p207_tests", user: parts[1])
        return (connection.normalized, parts[2])
    }

    static func engine(_ connection: DatabaseConnection, password: String) throws -> ExecutionEngine {
        let store = InMemoryCredentialStore()
        try store.set(SensitiveString(password), for: connection.id, label: "Runlet database: \(connection.name)")
        return ExecutionEngine(bundle: TestSupport.bundle, docker: nil, credentials: store)
    }

    static func request(_ json: String, connection: DatabaseConnection, target: TargetSnapshot, confirmed: Bool = false) throws -> RunRequest {
        var request = RunRequest(tabId: UUID(), documentVersion: 1, target: target, code: try MongoQuery(json).runnerCode(connection: nil, confirmed: confirmed), magicComments: false)
        request.sqlConnection = connection
        return request
    }

    static func run(_ json: String, connection: DatabaseConnection, target: TargetSnapshot, engine: ExecutionEngine, confirmed: Bool = false) async throws -> [RunEvent] {
        var events: [RunEvent] = []
        for await event in try await engine.start(try request(json, connection: connection, target: target, confirmed: confirmed)) { events.append(event) }
        return events
    }

    /// `p207_slow` with 10,000 small documents, made once per suite run: a correlated `$lookup` over
    /// it reads 10,000² documents, well over the time a test lets it run (its 25-second limit
    /// ends it anyway).
    static func prepareSlow(connection: DatabaseConnection, target: TargetSnapshot, engine: ExecutionEngine) async throws {
        let count = try await run(#"{"collection":"p207_slow","operation":"countDocuments"}"#, connection: connection, target: target, engine: engine)
        if count.sqlResult?.rows.first?.first == .int(10_000) { return }
        _ = try await run(#"{"collection":"p207_slow","operation":"drop"}"#, connection: connection, target: target, engine: engine, confirmed: true)
        _ = try await run(#"{"collection":"p207_seed","operation":"drop"}"#, connection: connection, target: target, engine: engine, confirmed: true)
        let seed = try await run(#"{"collection":"p207_seed","operation":"insertOne","documents":[{"seed":true}]}"#, connection: connection, target: target, engine: engine)
        #expect(seed.errors.isEmpty, "\(seed.errors)")
        let made = try await run(#"{"collection":"p207_seed","operation":"aggregate","pipeline":[{"$project":{"_id":0,"n":{"$range":[0,10000]}}},{"$unwind":"$n"},{"$out":"p207_slow"}]}"#, connection: connection, target: target, engine: engine)
        #expect(made.errors.isEmpty, "\(made.errors)")
    }

    static let slow = #"{"collection":"p207_slow","operation":"aggregate","pipeline":[{"$lookup":{"from":"p207_slow","let":{"m":"$n"},"pipeline":[{"$match":{"$expr":{"$ne":["$n","$$m"]}}},{"$count":"c"}],"as":"x"}},{"$count":"total"}]}"#

    /// The common checks after Stop: killed on the server, an info line rather than an error card.
    static func expectKilled(_ stopped: SQLCancelExecutionTests.Stopped, _ label: String) {
        #expect(stopped.session?.driver == "mongodb", "\(label): \(String(describing: stopped.session))")
        #expect(stopped.session?.tag?.hasPrefix("runlet:") == true && stopped.session?.server?.count == 16, "\(label)")
        #expect(stopped.took < .seconds(6), "\(label): Stop took \(stopped.took)")
        #expect(stopped.events.finished?.status == .cancelled, "\(label)")
        guard let report = stopped.events.sqlCancel else {
            Issue.record("\(label): no cancel report; errors \(stopped.events.errors)")
            return
        }
        #expect(report.outcome == .cancelled && report.verified == true, "\(label): \(report)")
        #expect(report.statement.hasPrefix("killOp "), "\(label): \(report.statement)")
        #expect(report.message.hasPrefix("Killed the operation on the server (killOp "), "\(label): \(report.message)")
        let errors = stopped.events.errors
        #expect(!errors.isEmpty && errors.allSatisfy { $0.interruptedByStop == true }, "\(label): \(errors)")
        #expect(errors.first.map(SQLCancel.interruptedText) == "Interrupted by Stop.", "\(label)")
        #expect(report.interrupted == true, "\(label)")
        #expect(stopped.events.logEntries.contains { $0.source == "cancel" && $0.message.hasPrefix("Stop: cancelling the operation on the server with killOp") }, "\(label)")
        #expect(stopped.events.logEntries.contains { $0.source == "sql" && $0.message.hasPrefix("MongoDB operations tagged runlet:") }, "\(label)")
        if case .finished = stopped.events.last?.kind {} else { Issue.record("\(label): finished must be last") }
    }

    /// Whether the panel still lists an operation tagged `tag`.
    static func stillRunning(_ tag: String, engine: ExecutionEngine, connection: DatabaseConnection, target: TargetSnapshot) async throws -> Bool {
        let report = try await engine.loadMongoServer(target: target, connection: nil, saved: connection)
        return report.operations?.contains { $0.comment == tag } == true
    }

    @Test func stopKillsTheOperationFromTheTarget() async throws {
        let (connection, password) = try Self.fixture()
        let engine = try Self.engine(connection, password: password)
        let directory = try DriverSupport.temporaryDirectory("mongo-stop")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = DriverSupport.target(directory.path)
        try await Self.prepareSlow(connection: connection, target: target, engine: engine)
        let request = try Self.request(Self.slow, connection: connection, target: target)
        let stopped = try await SQLCancelExecutionTests.runAndStop(request, engine: engine, running: .milliseconds(800))
        Self.expectKilled(stopped, "from the target")
        #expect(stopped.session?.tag == "runlet:" + request.runId.uuidString.lowercased())
        #expect(stopped.session?.saved == true && stopped.session?.connection == nil)
        #expect(try await Self.stillRunning(stopped.session?.tag ?? "", engine: engine, connection: connection, target: target) == false)
    }

    @Test func stopKillsTheOperationFromThisMac() async throws {
        var (connection, password) = try Self.fixture()
        connection.connectFrom = .thisMac
        connection = connection.normalized
        let engine = try Self.engine(connection, password: password)
        let root = try DriverSupport.temporaryDirectory("mongo-stop-mac")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try LocalConnectionLaunch.directory(in: AppPaths(root: root))
        let target = LocalConnectionLaunch.snapshot(connection: connection, php: .init(path: DriverSupport.php, label: "host PHP", isRunletPHP: false), directory: folder)
        try await Self.prepareSlow(connection: connection, target: target, engine: engine)
        let stopped = try await SQLCancelExecutionTests.runAndStop(try Self.request(Self.slow, connection: connection, target: target), engine: engine, running: .milliseconds(800))
        Self.expectKilled(stopped, "from this Mac")
        let second = stopped.events.logEntries.first { $0.source == "cancel" && $0.message.hasPrefix("Second runner: ") }
        #expect(second?.message.contains(DriverSupport.php) == true, "\(second?.message ?? "none")")
    }

    @Test(.live(.ssh), .enabled(if: SSHFixture.available, "requires Docker and OpenSSH"))
    func stopKillsTheOperationThroughAnSSHTunnel() async throws {
        let (fixture, password) = try Self.fixture()
        var connection = fixture
        connection.name = "Mongo through bastion"
        connection.connectFrom = .sshTunnel
        connection.sshProfile = SQLLiveTunnelTests.profileId
        // The SSH server reaches the fixture by its Compose service name; this Mac can't.
        connection.host = "mongo"
        connection.port = 27017
        connection = connection.normalized
        let bastion = try await SQLLiveTunnelTests.Bastion.open()
        let (lease, target) = try await bastion.lease(connection)
        let engine = try Self.engine(connection, password: password)
        do {
            try await Self.prepareSlow(connection: connection, target: target, engine: engine)
            let plain = try await Self.run(#"{"collection":"p207_slow","operation":"find","limit":1}"#, connection: connection, target: target, engine: engine)
            #expect(plain.errors.isEmpty && plain.sqlResult?.rows.count == 1, "through the tunnel, a direct connection: \(plain.errors)")
            let stopped = try await SQLCancelExecutionTests.runAndStop(try Self.request(Self.slow, connection: connection, target: target), engine: engine, running: .milliseconds(800))
            Self.expectKilled(stopped, "through the SSH tunnel")
        } catch {
            Issue.record("\(error)")
        }
        await bastion.manager.release(lease, cancelWhenUnused: true)
        await bastion.close()
    }

    @Test func serverPanelListsAndKillsOperations() async throws {
        let (connection, password) = try Self.fixture()
        let engine = try Self.engine(connection, password: password)
        let directory = try DriverSupport.temporaryDirectory("mongo-panel")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = DriverSupport.target(directory.path)
        try await Self.prepareSlow(connection: connection, target: target, engine: engine)

        let request = try Self.request(Self.slow, connection: connection, target: target)
        let tag = "runlet:" + request.runId.uuidString.lowercased()
        let collector = Task {
            var events: [RunEvent] = []
            for await event in try await engine.start(request) { events.append(event) }
            return events
        }
        var report = try await engine.loadMongoServer(target: target, connection: nil, saved: connection)
        var operation = report.operations?.first { $0.comment == tag }
        let deadline = ContinuousClock.now + .seconds(10)
        while operation == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
            report = try await engine.loadMongoServer(target: target, connection: nil, saved: connection)
            operation = report.operations?.first { $0.comment == tag }
        }
        #expect(report.summary.hasPrefix("MongoDB 7."), "\(report.summary)")
        #expect(report.status?.connections?.current ?? 0 > 0 && report.status?.uptime != nil, "\(String(describing: report.status))")
        #expect(report.summary.contains("standalone"), "\(report.summary)")
        #expect(report.errors == nil, "\(String(describing: report.errors))")
        let own = try #require(report.operations?.first { $0.own == true }, "the panel's own $currentOp read is listed")
        #expect(MongoServerPanel.refusal(own) != nil)
        let ownKill = await engine.killMongoOperation(own, report: report, target: target, connection: nil, saved: connection)
        #expect(ownKill.outcome == .gone || ownKill.outcome == .refused, "\(ownKill)")
        let listed = try #require(operation, "the run's operation is listed with its tag")
        #expect(listed.ns?.hasPrefix("p207_tests.") == true && listed.op == "command" && listed.command?.contains("aggregate") == true, "\(listed)")
        #expect(listed.users == ["runlet@admin"], "\(String(describing: listed.users))")
        // The confirmation always shows, naming the operation and the connection.
        let confirmation = DatabaseDangerConfirmation.mongoKill(listed, connection: "the saved connection “Mongo fixture”", isProduction: false, tabId: UUID()) {}
        #expect(confirmation.title.hasPrefix("Kill operation \(listed.opid) (command on p207_tests.") && confirmation.confirmTitle == "Kill Op" && confirmation.identifier == "mongo-kill")
        // An operation that isn't the listed one any more (another namespace) is refused.
        var changed = listed
        changed.ns = "p207_tests.other"
        let refused = await engine.killMongoOperation(changed, report: report, target: target, connection: nil, saved: connection)
        #expect(refused.outcome == .refused, "\(refused)")
        let killed = await engine.killMongoOperation(listed, report: report, target: target, connection: nil, saved: connection)
        #expect(killed.outcome == .killed, "\(killed)")
        let events = try await collector.value
        // Someone else's kill (the panel's) keeps the error card: it wasn't Stop.
        #expect(events.errors.contains { $0.message.contains("Driver code: 11601") && $0.interruptedByStop != true }, "\(events.errors)")
        let again = await engine.killMongoOperation(listed, report: report, target: target, connection: nil, saved: connection)
        #expect(again.outcome == .gone, "\(again)")
    }
}
