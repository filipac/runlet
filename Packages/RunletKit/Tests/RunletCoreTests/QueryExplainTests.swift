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
        #expect(code.contains("EXPLAIN select :name, :enabled"))
        #expect(code.contains(#""name" => "\$name\\\"\n\x00""#))
        #expect(code.contains(#""enabled" => false"#))
        #expect(code.contains(#"$connectionName = "reporting";"#))
        #expect(!code.contains("DISPLAY ONLY"))
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
