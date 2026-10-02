import Foundation
import RunletCore
import Testing
@testable import RunletExecution

@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct QueryExplainExecutionTests {
    @Test func generatedPHPKeepsSQLAndTypedBindingsWithoutInterpolation() async throws {
        // A scalar result from real PHP proves strings do not interpolate or break out
        // of the generated literals, and verifies PHP's types rather than Swift text.
        let values: [QueryRecord.Binding] = [
            .init(type: "string", value: "'$notAVariable\\\"\n\r\t\0💡"),
            .init(type: "int", value: "9223372036854775807"),
            .init(type: "float", value: "1.25"),
            .init(type: "bool", value: "false"), .init(type: "null"),
            .init(type: "int", value: "-9223372036854775808"),
        ]
        let query = QueryRecord(sql: "select :marker -- $sql\\\"", bindings: values,
                                connection: "reporting'$name", driver: "sqlite")
        let generated = try #require(QueryExplain.code(for: query, style: .pdo))
        let prelude = try #require(generated.range(of: "// Recreate the captured"))
        let code = String(generated[..<prelude.lowerBound]) + "\nreturn json_encode([$sql, $bindings, $connectionName]);"
        let events = try await TestSupport.run(code, target: DriverSupport.target(DriverSupport.fixture("plain")))
        #expect(events.errors.isEmpty, "\(events.errors)")
        let json = try #require(events.result?.value?.scalar)
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any])
        #expect(decoded[0] as? String == "EXPLAIN QUERY PLAN " + query.sql)
        #expect(decoded[2] as? String == query.connection)
        let bindings = try #require(decoded[1] as? [Any])
        #expect(bindings[0] as? String == values[0].value)
        #expect((bindings[1] as? NSNumber)?.int64Value == Int64.max)
        #expect((bindings[2] as? NSNumber)?.doubleValue == 1.25)
        #expect((bindings[3] as? NSNumber)?.boolValue == false)
        #expect(bindings[4] is NSNull)
        #expect((bindings[5] as? NSNumber)?.int64Value == Int64.min)
    }

    @Test func pdoPlanRequiresRecreatingConnectionAndKeepsNamedBindings() async throws {
        let query = QueryRecord(sql: "select :name, :enabled, :count", bindings: [
            .init(type: "string", value: "a'$b", name: "name"),
            .init(type: "bool", value: "true", name: "enabled"),
            .init(type: "int", value: "7", name: "count"),
        ], connection: "scratch", driver: "sqlite", databaseAPI: "pdo")
        let generated = try #require(QueryExplain.code(for: query, style: .pdo))
        let target = DriverSupport.target(DriverSupport.fixture("plain"))
        let missing = try await TestSupport.run(generated, target: target)
        #expect(missing.errors.contains { $0.message.contains("Set up the captured PDO connection") })
        let events = try await TestSupport.run("$pdo = new PDO('sqlite::memory:');\n" + generated, target: target)
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.result?.value?.entries?.first?.value.entries?.contains { $0.value.scalar == "SCAN CONSTANT ROW" } == true)
    }

    @Test(.enabled(if: ["eloquent-app", "eloquent-app-modern"].allSatisfy {
        FileManager.default.fileExists(atPath: DriverSupport.fixture($0) + "/vendor/autoload.php")
    }, "requires the Eloquent/DBAL 3/4 fixtures"))
    func capturedEloquentAndDoctrineQueriesProducePlansInFreshProcesses() async throws {
        for fixture in ["eloquent-app", "eloquent-app-modern"] {
            let directory = DriverSupport.fixture(fixture)
            let target = DriverSupport.target(directory)
            let events = try await TestSupport.run("Shop\\Models\\Customer::where('name', 'Ada')->get();\n$container->get('reports')->fetchAllAssociative('SELECT name FROM reports WHERE name = ?', ['daily']);", target: target)
            #expect(events.errors.isEmpty, "\(events.errors)")
            let eloquent = try #require(events.inspection.queries.first { $0.query.sql.contains("where") && $0.query.databaseAPI == "eloquent" }?.query)
            let doctrine = try #require(events.inspection.queries.first { $0.query.sql == "SELECT name FROM reports WHERE name = ?" && $0.query.databaseAPI == "doctrine" }?.query)
            for (query, style, setup) in [(eloquent, QueryExplain.ConnectionStyle.eloquent, ""),
                                          (doctrine, .doctrineManual, "$connection = $container->get('reports');\n")] {
                let code = try #require(QueryExplain.code(for: query, style: style))
                let plan = try await TestSupport.run(setup + code, target: target)
                #expect(plan.errors.isEmpty, "\(fixture): \(plan.errors)")
                #expect(plan.result?.value?.count ?? 0 > 0)
                let explained = try #require(plan.inspection.queries.first { $0.query.sql.hasPrefix("EXPLAIN QUERY PLAN ") }?.query)
                #expect(explained.bindings == query.bindings)
                #expect(explained.connection == query.connection)
                #expect(explained.databaseAPI == query.databaseAPI)
            }
        }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: TestSupport.fixtures.appendingPathComponent("wordpress/.runlet-fixture-ready").path), "requires the WordPress SQLite fixture"))
    func wordpressSQLiteCaptureDoesNotOfferAnUnsupportedPlan() async throws {
        let target = DriverSupport.target(DriverSupport.fixture("wordpress"))
        let captured = try await TestSupport.run("$wpdb->get_var(\"SELECT COUNT(*) FROM {$wpdb->posts}\");", target: target)
        #expect(captured.errors.isEmpty, "\(captured.errors)")
        let query = try #require(captured.inspection.queries.last?.query)
        #expect(query.databaseAPI == "wordpress")
        #expect(query.driver == "sqlite")
        #expect(QueryExplain.unavailableReason(for: query)?.contains("WordPress's SQLite") == true)
        #expect(QueryExplain.code(for: query, style: .wordpress) == nil)
    }
}
