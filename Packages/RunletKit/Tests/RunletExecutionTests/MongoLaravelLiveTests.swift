import Foundation
@testable import RunletCore
import Testing
@testable import RunletExecution

/// MongoDB tabs on a laravel-mongodb application connection (#207), live: a Laravel application
/// with `mongodb/laravel-mongodb` and a `mongodb` connection to the `mongo:7` fixture, named by
/// `RUNLET_TEST_LARAVEL_MONGODB` (a scratch copy of `Tests/Fixtures/laravel-app` after
/// `composer require mongodb/laravel-mongodb`; never committed: see docs/mongodb.md). Runlet
/// boots the application and opens `DB::connection('mongodb')`, with no credentials of its own.
@Suite(.serialized, .enabled(if: TestSupport.hasPHP && ProcessInfo.processInfo.environment["RUNLET_TEST_LARAVEL_MONGODB"] != nil,
                             "set RUNLET_TEST_LARAVEL_MONGODB to a Laravel app with mongodb/laravel-mongodb whose mongodb connection reaches the fixture"))
struct MongoLaravelLiveTests {
    static var project: String { ProcessInfo.processInfo.environment["RUNLET_TEST_LARAVEL_MONGODB"] ?? "" }

    static func request(_ json: String, confirmed: Bool = false) throws -> RunRequest {
        RunRequest(tabId: UUID(), documentVersion: 1, target: DriverSupport.target(project), code: try MongoQuery(json).runnerCode(connection: "mongodb", confirmed: confirmed), magicComments: false)
    }

    static func run(_ json: String, engine: ExecutionEngine, confirmed: Bool = false) async throws -> [RunEvent] {
        var events: [RunEvent] = []
        for await event in try await engine.start(try request(json, confirmed: confirmed)) { events.append(event) }
        return events
    }

    @Test func queriesThroughTheApplicationsConnection() async throws {
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
        let collection = "p207_laravel_" + UUID().uuidString.prefix(8).lowercased()
        let inserted = try await Self.run("{\"collection\":\"\(collection)\",\"operation\":\"insertMany\",\"documents\":[{\"n\":1,\"at\":{\"$date\":\"2026-01-01T00:00:00Z\"}},{\"n\":2},{\"n\":3}]}", engine: engine)
        #expect(inserted.errors.isEmpty, "\(inserted.errors)")
        #expect(inserted.bootstrapped?.framework == "laravel", "\(String(describing: inserted.bootstrapped))")
        let found = try await Self.run("{\"collection\":\"\(collection)\",\"operation\":\"find\",\"sort\":{\"n\":1}}", engine: engine)
        #expect(found.errors.isEmpty, "\(found.errors)")
        let result = try #require(found.sqlResult)
        #expect(result.rows.count == 3 && result.connection == "mongodb" && result.saved == false, "\(result)")
        #expect(result.columns.contains("at") && result.rows.first?[result.columns.firstIndex(of: "at")!] == .string("2026-01-01 00:00:00.000+00:00"))
        // The application's URI holds the fixture's password: it never reaches the output.
        #expect(!found.scannableText.joined().contains("runlet-fixture"))
        // No deprecation from the adapter (getClient(), not getMongoClient()).
        #expect(!found.scannableText.joined().contains("deprecated"), "\(found.scannableText.joined().prefix(400))")
        let counted = try await Self.run("{\"collection\":\"\(collection)\",\"operation\":\"countDocuments\",\"filter\":{\"n\":{\"$gt\":1}}}", engine: engine)
        #expect(counted.sqlResult?.rows.first?.first == .int(2), "\(counted.errors)")
        // The server panel and Stop's second runner boot the application again for its connection.
        let report = try await engine.loadMongoServer(target: DriverSupport.target(Self.project), connection: "mongodb", saved: nil)
        #expect(report.status?.version?.hasPrefix("7.") == true, "\(report)")
        let dropped = try await Self.run("{\"collection\":\"\(collection)\",\"operation\":\"drop\"}", engine: engine, confirmed: true)
        #expect(dropped.errors.isEmpty, "\(dropped.errors)")
    }

    @Test func stopKillsTheOperationOnTheApplicationsConnection() async throws {
        let (fixture, password) = try MongoServerLiveTests.fixture()
        // The slow collection lives in the fixture's p207_tests; the application uses p207_laravel.
        let setupEngine = try MongoServerLiveTests.engine(fixture, password: password)
        let directory = try DriverSupport.temporaryDirectory("mongo-laravel-stop")
        defer { try? FileManager.default.removeItem(at: directory) }
        var laravelSide = fixture
        laravelSide.database = "p207_laravel"
        laravelSide = laravelSide.normalized
        let laravelEngine = try MongoServerLiveTests.engine(laravelSide, password: password)
        try await MongoServerLiveTests.prepareSlow(connection: laravelSide, target: DriverSupport.target(directory.path), engine: laravelEngine)
        withExtendedLifetime(setupEngine) {}
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
        let stopped = try await SQLCancelExecutionTests.runAndStop(try Self.request(MongoServerLiveTests.slow), engine: engine, running: .milliseconds(800))
        MongoServerLiveTests.expectKilled(stopped, "laravel-mongodb")
        #expect(stopped.session?.connection == "mongodb" && stopped.session?.saved == nil)
    }
}
