import Foundation
import RunletCore
@testable import RunletExecution
import Testing

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RUNLET_TEST_MONGODB"] != nil))
struct MongoLiveTests {
    private func connection(readOnly: Bool = false) throws -> (DatabaseConnection, String) {
        let value = try #require(ProcessInfo.processInfo.environment["RUNLET_TEST_MONGODB"])
        let parts = value.components(separatedBy: "|")
        #expect(parts.count == 3)
        let url = try #require(URLComponents(string: parts[0]))
        #expect(url.host == "127.0.0.1")
        let connection = DatabaseConnection(name: "Mongo fixture", scope: .local(UUID()), driver: .mongodb, host: "127.0.0.1", port: url.port, database: "p191_tests", user: parts[1], readOnly: readOnly)
        return (connection, parts[2])
    }

    private func run(_ json: String, readOnly: Bool = false, offset: Int = 0, size: Int = 100, confirmed: Bool = false) async throws -> [RunEvent] {
        let (connection, password) = try connection(readOnly: readOnly)
        let directory = try DriverSupport.temporaryDirectory("mongo")
        defer { try? FileManager.default.removeItem(at: directory) }
        let query = try MongoQuery(json)
        return try await SQLSavedConnectionTests.run(query.runnerCode(connection: nil, pageSize: size, offset: offset, confirmed: confirmed), connection: connection, in: directory, password: password)
    }

    @Test func crudAggregationPagingAndSafety() async throws {
        let collection = "p191_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        func query(_ tail: String) -> String { "{\"collection\":\"\(collection)\"," + tail + "}" }
        let inserted = try await run(query(#""operation":"insertMany","documents":[{"status":"paid","total":10},{"status":"paid","total":20},{"status":"pending","total":30}]"#))
        #expect(inserted.errors.isEmpty, "\(inserted.errors)")
        let first = try await run(query(#""operation":"find","sort":{"total":1}"#), size: 2)
        #expect(first.errors.isEmpty, "\(first.errors)")
        #expect(first.sqlResult?.rows.count == 2)
        let next = try await run(query(#""operation":"find","sort":{"total":1}"#), offset: 2, size: 2)
        #expect(next.sqlResult?.rows.count == 1)
        for operation in [#""operation":"countDocuments","filter":{"status":"paid"}"#, #""operation":"distinct","field":"status""#, #""operation":"aggregate","pipeline":[{"$match":{"status":"paid"}},{"$group":{"_id":"$status","total":{"$sum":"$total"}}}]"#, #""operation":"updateOne","filter":{"total":10},"update":{"$set":{"status":"complete"}}"#] {
            let events = try await run(query(operation))
            #expect(events.errors.isEmpty, "\(events.errors)")
            #expect(events.sqlResult != nil)
        }
        for operation in [#""operation":"insertOne","documents":[{}]"#, #""operation":"updateMany","update":{"$set":{"status":"bad"}}"#, #""operation":"deleteOne""#, #""operation":"drop""#, #""operation":"createIndex","keys":{"total":1}"#, #""operation":"aggregate","pipeline":[{"$out":"p191_refused"}]"#, #""operation":"aggregate","pipeline":[{"$merge":"p191_refused"}]"#] {
            let events = try await run(query(operation), readOnly: true, confirmed: true)
            #expect(!events.errors.isEmpty)
            #expect(events.scannableText.joined().contains("Read-only"))
        }
        let unconfirmed = try await run(query(#""operation":"deleteMany""#))
        #expect(!unconfirmed.errors.isEmpty)
        let remaining = try await run(query(#""operation":"find""#))
        #expect(remaining.sqlResult?.rows.count == 3)
        for operation in ["listDatabases", "listCollections", "sampleSchema", "getIndexes"] {
            let metadata = try await run(query("\"operation\":\"\(operation)\""), readOnly: true)
            #expect(metadata.errors.isEmpty, "\(metadata.errors)")
            #expect(metadata.sqlResult?.rows.isEmpty == false)
        }
        let dropped = try await run(query(#""operation":"drop""#), confirmed: true)
        #expect(dropped.errors.isEmpty)
    }

    @Test func applicationDriverConnection() async throws {
        let (saved, password) = try connection()
        let project = try DriverSupport.composerProject(drivers: ["MongoFixtureDriver.php": """
        <?php
        class MongoFixtureDriver extends \\Runlet\\Driver {
            public function bootstrap(string $projectPath): void {}
            public function mongoConnection(?string $name) {
                return ['manager' => new \\MongoDB\\Driver\\Manager('mongodb://127.0.0.1:\(saved.port!)',
                    ['username' => 'runlet', 'password' => '\(password)', 'authSource' => 'admin']), 'database' => 'p191_tests'];
            }
        }
        """])
        defer { try? FileManager.default.removeItem(at: project) }
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
        let query = try MongoQuery(#"{"collection":"p191_application","operation":"find"}"#)
        let request = RunRequest(tabId: UUID(), documentVersion: 1, target: DriverSupport.target(project.path), code: query.runnerCode(connection: "mongodb"), magicComments: false)
        var events: [RunEvent] = []
        for await event in try await engine.start(request) { events.append(event) }
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.sqlResult != nil)
        #expect(!events.scannableText.joined().contains(password))
    }

    @Test func extendedTypesAndRedaction() async throws {
        let collection = "p191_types_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let insert = try await run("{\"collection\":\"\(collection)\"," + #""operation":"insertOne","documents":[{"_id":{"$oid":"507f1f77bcf86cd799439011"},"amount":{"$numberDecimal":"12.50"},"date":{"$date":"2026-01-01T00:00:00Z"},"binary":{"$binary":{"base64":"aGVsbG8=","subType":"00"}}}]}"#)
        #expect(insert.errors.isEmpty, "\(insert.errors)")
        let found = try await run("{\"collection\":\"\(collection)\",\"operation\":\"findOne\"}")
        #expect(found.errors.isEmpty)
        #expect(found.scannableText.joined().contains("507f1f77bcf86cd799439011"))
        let (_, password) = try connection()
        #expect(!found.scannableText.joined().contains(password))
        let dropped = try await run("{\"collection\":\"\(collection)\",\"operation\":\"drop\"}", confirmed: true)
        #expect(dropped.errors.isEmpty)
    }
}
