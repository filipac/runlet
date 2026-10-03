import Foundation
import Testing
@testable import RunletCore

struct QueryExplainTests {
    @Test func refusesIncompleteOrUnrecreatableCaptures() {
        let captures = [
            QueryRecord(sql: "select ?", omittedBindings: 1),
            QueryRecord(sql: "select", omittedBytes: 1),
            QueryRecord(sql: "select ?", bindings: [.init(type: "string", value: "part", omittedBytes: 2)]),
            QueryRecord(sql: "select ?", bindings: [.init(type: "binary", size: 10)]),
            QueryRecord(sql: "select ?", bindings: [.init(type: "int", value: "0; die();")]),
            QueryRecord(sql: "select ?", bindings: [.init(type: "float", value: "INF")]),
            QueryRecord(sql: "select ?", bindings: [.init(type: "bool", value: "anything")]),
            QueryRecord(sql: "select ?", bindings: [.init(type: "string")]),
            QueryRecord(sql: "select 1", driver: "sqlsrv"),
        ]
        for query in captures {
            #expect(QueryExplain.unavailableReason(for: query) != nil)
            #expect(QueryExplain.code(for: query, style: .laravel) == nil)
        }
    }

    @Test func usesPlaceholdersInsteadOfDisplayOnlyRawSQL() throws {
        let query = QueryRecord(sql: "select :name, :enabled", bindings: [
            .init(type: "string", value: "$name\\\"\n\0", name: "name"),
            .init(type: "bool", value: "false", name: "enabled"),
        ], connection: "reporting", driver: "pgsql", rawSql: "DISPLAY ONLY")
        let code = try #require(QueryExplain.code(for: query, style: .laravel))
        #expect(code.contains("EXPLAIN (FORMAT JSON) select :name, :enabled"))
        #expect(code.contains(#""name" => "\$name\\\"\n\x00""#))
        #expect(code.contains(#""enabled" => false"#))
        #expect(code.contains(#"$connectionName = "reporting";"#))
        #expect(!code.contains("DISPLAY ONLY"))
    }

    /// #170: the formats #147's plan tree reads, handed to the runner's Runlet\explainPlan()
    /// with each layer's connection; a capture without a driver keeps today's plain EXPLAIN.
    @Test func asksForThePlanTreeFormatsAndShowsThePlan() throws {
        let prefixes: [(String?, String)] = [
            ("mysql", "EXPLAIN FORMAT=JSON "), ("mariadb", "EXPLAIN FORMAT=JSON "), ("MySQL", "EXPLAIN FORMAT=JSON "),
            ("pgsql", "EXPLAIN (FORMAT JSON) "), ("postgresql", "EXPLAIN (FORMAT JSON) "),
            ("sqlite", "EXPLAIN QUERY PLAN "), ("sqlite3", "EXPLAIN QUERY PLAN "), (nil, "EXPLAIN "),
        ]
        let styles: [(QueryExplain.ConnectionStyle, String)] = [
            (.laravel, "$connection"), (.eloquent, "$connection"), (.doctrine, "$connection"),
            (.doctrineManual, "$connection"), (.wordpress, "$wpdb"), (.pdo, "$pdo"),
        ]
        for (driver, prefix) in prefixes {
            for (style, connection) in styles {
                let query = QueryRecord(sql: "select * from users where id = 1", connection: "main", driver: driver)
                let code = try #require(QueryExplain.code(for: query, style: style), "\(driver ?? "nil") \(style)")
                #expect(code.contains(#"$sql = "\#(prefix)select * from users where id = 1";"#), "\(driver ?? "nil") \(style)")
                #expect(!code.uppercased().contains("ANALYZE"))
                #expect(code.contains(#"$connectionName = "main";"#))
                let shows = "return function_exists('Runlet\\explainPlan')\n    ? \\Runlet\\explainPlan($plan, \(connection), $connectionName)\n    : $plan;"
                if driver == nil {
                    #expect(code.hasSuffix("\nreturn $plan;") && !code.contains("explainPlan"), "\(style)")
                } else {
                    #expect(code.hasSuffix("\n" + shows), "\(driver ?? "nil") \(style): \(code)")
                }
            }
        }
    }

    @Test func optionalAPIMetadataDecodesOldAndNewCaptures() throws {
        let decoder = JSONDecoder()
        let old = try decoder.decode(QueryRecord.self, from: Data(#"{"sql":"select 1"}"#.utf8))
        let new = try decoder.decode(QueryRecord.self, from: Data(#"{"sql":"select 1","databaseAPI":"eloquent"}"#.utf8))
        #expect(old.databaseAPI == nil)
        #expect(new.databaseAPI == "eloquent")
        #expect(try decoder.decode(QueryRecord.self, from: JSONEncoder().encode(new)) == new)
    }
}
