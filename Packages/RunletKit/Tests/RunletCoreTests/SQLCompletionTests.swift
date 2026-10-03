import Foundation
import Testing
@testable import RunletCore

/// SQL completion (#128): keywords without a schema; tables and columns from a loaded one.
struct SQLCompletionTests {
    let schema = SQLSchemaInfo(driver: "sqlite", tables: [
        .init(name: "users", columns: [.init(name: "id", type: "integer"), .init(name: "email", type: "varchar"), .init(name: "created_at")]),
        .init(name: "orders", columns: [.init(name: "id"), .init(name: "user_id"), .init(name: "total", type: "numeric")]),
        .init(name: "Order Lines", columns: [.init(name: "order"), .init(name: "qty")]),
    ])

    /// Completions where `|` marks the caret.
    func complete(_ marked: String, schema: SQLSchemaInfo? = nil) -> SQLCompletion.Result? {
        let caret = (marked as NSString).range(of: "|").location
        let text = (marked as NSString).replacingCharacters(in: NSRange(location: caret, length: 1), with: "")
        return SQLCompletion.suggestions(in: text, caret: caret, schema: schema)
    }

    func labels(_ result: SQLCompletion.Result?, _ kind: SQLCompletion.Kind? = nil, rank: Int? = nil) -> [String] {
        (result?.items ?? []).filter { (kind == nil || $0.kind == kind) && (rank == nil || $0.rank == rank) }.map(\.label)
    }

    @Test func keywordsWithoutASchema() throws {
        let result = try #require(complete("SEL|"))
        #expect(result.prefix == "SEL" && result.anchor == 0)
        #expect(labels(result).contains("SELECT"))
        #expect(labels(result, .function).contains("COUNT"))
        #expect(labels(result).contains("ORDER BY"))
        #expect(labels(result, .table).isEmpty && labels(result, .column).isEmpty)
        // Lower-case typing gets lower-case keywords; so does a lower-case statement.
        #expect(labels(complete("sel|")).contains("select"))
        #expect(labels(complete("select * from users |")).contains("where"))
        #expect(labels(complete("SELECT * FROM users |")).contains("WHERE"))
        // Functions insert their parentheses with the caret inside.
        let count = try #require(complete("SELECT cou|")?.items.first { $0.label == "count" })
        #expect(count.insertText == "count()" && count.cursor == 6)
    }

    @Test func nothingInsideStringsCommentsOrQuotedNames() {
        #expect(complete("SELECT 'us|'", schema: schema) == nil)
        #expect(complete("SELECT 'unterminated us|", schema: schema) == nil)
        #expect(complete("SELECT 1 -- us|", schema: schema) == nil)
        #expect(complete("SELECT /* us| */ 1", schema: schema) == nil)
        #expect(complete("SELECT \"us|\"", schema: schema) == nil)
        #expect(complete("SELECT 12|", schema: schema) == nil)
        #expect(complete("SELECT * FROM users WHERE id = :us|", schema: schema) == nil)
        // After a closed string or comment, completion works again.
        #expect(complete("SELECT 'x', em|", schema: schema) != nil)
        #expect(complete("/* note */ SEL|", schema: schema) != nil)
    }

    @Test func tablesAfterFromJoinUpdateAndInto() throws {
        for marked in ["SELECT * FROM |", "SELECT * FROM us|", "SELECT * FROM users u JOIN |", "UPDATE |", "INSERT INTO |", "SELECT * FROM users, |"] {
            let result = try #require(complete(marked, schema: schema), "\(marked)")
            #expect(labels(result, rank: 0) == ["users", "orders", "Order Lines"], "\(marked)")
            #expect(result.items.first { $0.label == "users" }?.detail == "table · 3 columns")
        }
        // A name that needs quotes is inserted quoted (backticks on MySQL).
        #expect(complete("SELECT * FROM |", schema: schema)?.items.first { $0.label == "Order Lines" }?.insertText == "\"Order Lines\"")
        var mysql = schema
        mysql.driver = "mysql"
        #expect(complete("SELECT * FROM |", schema: mysql)?.items.first { $0.label == "Order Lines" }?.insertText == "`Order Lines`")
    }

    @Test func columnsOfTheStatementsTablesFirst() throws {
        let result = try #require(complete("SELECT em| FROM users WHERE id = 1", schema: schema))
        #expect(labels(result, .column, rank: 0) == ["id", "email", "created_at"])
        #expect(result.items.first { $0.label == "email" }?.detail == "users · varchar")
        // Keywords come next, then tables.
        #expect(labels(result, .keyword, rank: 1).contains("from"), "lower-case typing")
        #expect(labels(result, .table, rank: 2) == ["users", "orders", "Order Lines"])

        // Two tables: each column name once.
        let joined = try #require(complete("SELECT * FROM users JOIN orders ON | ", schema: schema))
        #expect(labels(joined, .column, rank: 0) == ["id", "email", "created_at", "user_id", "total"])

        // INSERT INTO t (|: that table's columns; a reserved word is quoted.
        let insert = try #require(complete("INSERT INTO \"Order Lines\" (|", schema: schema))
        #expect(labels(insert, .column, rank: 0) == ["order", "qty"])
        #expect(insert.items.first { $0.label == "order" }?.insertText == "\"order\"")

        // Before FROM: every column once, after the keywords.
        let early = try #require(complete("SELECT tot|", schema: schema))
        #expect(labels(early, .column, rank: 2).contains("total"))
    }

    @Test func qualifiedNamesUseAliases() throws {
        let alias = try #require(complete("SELECT o.| FROM orders o JOIN users AS u ON u.id = o.user_id", schema: schema))
        #expect(labels(alias) == ["id", "user_id", "total"])
        #expect(alias.anchor == 9 && alias.prefix.isEmpty)
        let typed = try #require(complete("SELECT u.em| FROM orders o JOIN users AS u ON u.id = o.user_id", schema: schema))
        #expect(labels(typed) == ["id", "email", "created_at"])
        #expect(typed.prefix == "em")
        // A table name works without an alias, case-insensitively and quoted.
        #expect(labels(complete("SELECT USERS.| FROM users", schema: schema)) == ["id", "email", "created_at"])
        #expect(labels(complete("SELECT \"Order Lines\".| FROM \"Order Lines\"", schema: schema)) == ["order", "qty"])
        // An unknown qualifier offers nothing.
        #expect(complete("SELECT x.| FROM users", schema: schema) == nil)
        // Schema-qualified tables: `reporting.` lists that schema's tables.
        let pg = SQLSchemaInfo(driver: "pgsql", tables: [.init(name: "users"), .init(name: "reporting.Daily", columns: [.init(name: "day")])])
        let tables = try #require(complete("SELECT * FROM reporting.|", schema: pg))
        #expect(tables.items.map(\.label) == ["Daily"])
        #expect(tables.items.first?.insertText == "\"Daily\"", "PostgreSQL folds unquoted names to lower case")
        #expect(labels(complete("SELECT d.| FROM reporting.Daily d", schema: pg)) == ["day"])
    }

    @Test func onlyTheStatementAtTheCaretCounts() throws {
        let result = try #require(complete("SELECT * FROM orders;\nSELECT | FROM users;\nSELECT 1", schema: schema))
        #expect(labels(result, .column, rank: 0) == ["id", "email", "created_at"])
        #expect(SQLCompletion.tableReferences([], []).isEmpty)
    }

    @Test func schemaDecodingAndLookup() throws {
        let json = #"{"connection":"main","driver":"sqlite","source":"AcmeApiDriver::sqlConnection()","how":"sqlite_master","tables":[{"name":"leases","columns":[{"name":"id","type":"integer"},{"name":"tenant"}]}],"elapsedMs":1.5}"#
        let decoded = try JSONDecoder().decode(SQLSchemaInfo.self, from: Data(json.utf8))
        #expect(decoded.tables.first?.columns == [.init(name: "id", type: "integer"), .init(name: "tenant")])
        #expect(decoded.summary == "1 table, 2 columns")
        #expect(decoded.table(named: "`LEASES`")?.name == "leases")
        let failed = try JSONDecoder().decode(SQLSchemaInfo.self, from: Data(#"{"error":"no access"}"#.utf8))
        #expect(failed.tables.isEmpty && failed.error == "no access")
        #expect(SQLCompletion.unquoted("\"a\"\"b\"") == "a\"b")
        #expect(SQLCompletion.unquoted("[dbo]") == "dbo")
    }

    @Test func generatedPHPAsksForTheSchemaOnlyWhenWanted() {
        #expect(!SQLTabRun.code(statement: "select 1", connection: nil).contains(", true)"))
        #expect(SQLTabRun.code(statement: "select 1", connection: nil, schema: true).hasSuffix(#"SqlTab::run("select 1", null, 1000, true);"#))
        #expect(SQLTabRun.schemaCode(connection: "reports").hasSuffix(#"SqlTab::schema("reports");"#))
        let statements = SQLScript.statements(in: "select 1")
        #expect(SQLTabRun.scriptCode(statements: statements, connection: nil, transaction: false, schema: true).hasSuffix("], null, 1000, false, true);"))
    }
}
