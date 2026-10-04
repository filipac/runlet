import Foundation
import Testing
@testable import RunletCore

/// Load Next (#146): which statements page, how each dialect's page is written, the generated
/// PHP, appending a page to a result, and the rows-per-page setting.
struct SQLPagingTests {
    func plan(_ statement: String, _ driver: String?) throws -> SQLPaging.Plan {
        try SQLPaging.plan(for: statement, driver: driver).get()
    }

    func refusal(_ statement: String, _ driver: String? = "mysql") -> SQLPaging.Refusal? {
        if case .failure(let refusal) = SQLPaging.plan(for: statement, driver: driver) { return refusal }
        return nil
    }

    // MARK: Which statements page

    @Test func writesNeverPage() {
        #expect(refusal("INSERT INTO t (a) VALUES (1) RETURNING id") == .writes("INSERT"))
        #expect(refusal("UPDATE t SET a = 1 RETURNING *", "pgsql") == .writes("UPDATE"))
        #expect(refusal("DELETE FROM t RETURNING id", "sqlite") == .writes("DELETE"))
        #expect(refusal("WITH moved AS (DELETE FROM a RETURNING *) SELECT * FROM moved", "pgsql") == .writes("DELETE"))
        #expect(refusal("SELECT * INTO backup FROM t", "pgsql") == .writes("SELECT … INTO"))
        #expect(refusal("SELECT id FROM t FOR UPDATE") == .writes("FOR UPDATE, which locks rows"))
        #expect(refusal("SELECT id FROM t FOR NO KEY UPDATE", "pgsql") == .writes("FOR UPDATE, which locks rows"))
        #expect(refusal("CALL report()") == .writes("CALL"))
        #expect(refusal("EXPLAIN ANALYZE DELETE FROM t", "pgsql") == .writes("EXPLAIN ANALYZE … DELETE"))
    }

    @Test func lockingReadsNeverPage() {
        #expect(refusal("SELECT id FROM t FOR SHARE") == .locking("FOR SHARE"))
        #expect(refusal("SELECT id FROM t WHERE a > 1 FOR KEY SHARE", "pgsql") == .locking("FOR KEY SHARE"))
        #expect(refusal("SELECT id FROM t LOCK IN SHARE MODE") == .locking("LOCK IN SHARE MODE"))
        #expect(refusal("SELECT * FROM (SELECT id FROM t FOR SHARE) s", "pgsql") == .locking("FOR SHARE"))
    }

    @Test func otherReadsAndUnknownStatementsDontPage() {
        #expect(refusal("SHOW TABLES") == .notAQuery("SHOW"))
        #expect(refusal("DESCRIBE users") == .notAQuery("DESCRIBE"))
        #expect(refusal("EXPLAIN SELECT 1") == .notAQuery("EXPLAIN"))
        #expect(refusal("PRAGMA table_info(users)", "sqlite") == .notAQuery("PRAGMA"))
        #expect(refusal("FETCH 10 FROM cursor_name", "pgsql") == .unclassified("FETCH"))
        #expect(refusal("-- only a comment") == .unclassified(""))
        for refusal in [SQLPaging.Refusal.writes("INSERT"), .unclassified("FETCH"), .locking("FOR SHARE"), .notAQuery("SHOW"), .script] {
            #expect(!refusal.message.isEmpty)
        }
        #expect(SQLPaging.Refusal.writes("INSERT").message.contains("won't run it again"))
    }

    @Test func plainReadsPage() throws {
        for statement in ["SELECT * FROM users", "select id from users order by id", "WITH recent AS (SELECT * FROM orders) SELECT * FROM recent", "TABLE users", "VALUES (1), (2)",
                          "SELECT a FROM t UNION ALL SELECT a FROM u", "SELECT * FROM t WHERE name = :name AND id > ?"] {
            #expect(throws: Never.self, "\(statement)") { try plan(statement, "pgsql") }
        }
    }

    // MARK: Pages per dialect

    @Test func sqliteMySQLAndPostgreSQLGetALimitAddedToTheEnd() throws {
        for driver in ["sqlite", "mysql", "pgsql"] {
            let plan = try plan("SELECT id, name FROM users ORDER BY id", driver)
            #expect(plan.mode == .append)
            #expect(plan.ordered)
            let page = plan.page(offset: 1000, size: 1000)
            // One row more than the page, so the result says whether more follow.
            #expect(page.sql == "SELECT id, name FROM users ORDER BY id\nLIMIT 1001 OFFSET 1000")
            #expect(page.skip == 0)
            #expect(page.size == 1000)
            #expect(page.driver == driver)
            #expect(page.added == "LIMIT 1001 OFFSET 1000")
            #expect(page.rowsText == "rows \(1001.formatted())–\(2000.formatted())", "in the Mac's number format")
        }
    }

    @Test func aTrailingCommentCantHideTheLimit() throws {
        let page = try plan("SELECT * FROM users -- every user", "mysql").page(offset: 2500, size: 2500)
        #expect(page.sql == "SELECT * FROM users -- every user\nLIMIT 2501 OFFSET 2500")
    }

    @Test func ctesUnionsAndPlaceholdersKeepTheirShape() throws {
        let cte = try plan("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n LIMIT 5000) SELECT i FROM n", "sqlite")
        // The LIMIT inside the CTE isn't the statement's own.
        #expect(cte.mode == .append)
        #expect(!cte.ordered)
        #expect(cte.page(offset: 1000, size: 1000).sql.hasSuffix(") SELECT i FROM n\nLIMIT 1001 OFFSET 1000"))
        let union = try plan("SELECT a FROM t UNION SELECT a FROM u ORDER BY a", "pgsql")
        #expect(union.mode == .append && union.ordered)
        let bound = try plan("SELECT * FROM t WHERE a = ? AND b = :b ORDER BY id", "mysql").page(offset: 10, size: 10)
        // Placeholders keep their order: the clause has none.
        #expect(bound.sql == "SELECT * FROM t WHERE a = ? AND b = :b ORDER BY id\nLIMIT 11 OFFSET 10")
        // ORDER BY inside a window or a subquery doesn't order the statement.
        #expect(try !plan("SELECT id, row_number() OVER (ORDER BY id) FROM t", "pgsql").ordered)
        #expect(try !plan("SELECT * FROM (SELECT id FROM t ORDER BY id) s", "pgsql").ordered)
    }

    @Test func statementsWithTheirOwnLimitAreSkippedByTheRunner() throws {
        for (statement, driver) in [("SELECT * FROM t ORDER BY id LIMIT 5000", "mysql"), ("SELECT * FROM t LIMIT 10, 5000", "sqlite"),
                                    ("SELECT * FROM t ORDER BY id OFFSET 5", "pgsql"), ("SELECT * FROM t ORDER BY id FETCH FIRST 3000 ROWS ONLY", "pgsql"),
                                    ("SELECT TOP 5000 * FROM t ORDER BY id", "sqlsrv")] {
            let plan = try plan(statement, driver)
            #expect(plan.mode == .skip, "\(statement)")
            let page = plan.page(offset: 1000, size: 1000)
            #expect(page.sql == statement, "runs as written")
            #expect(page.skip == 1000)
            #expect(page.driver == nil)
            #expect(page.added == nil)
        }
    }

    @Test func sqlServerAddsOffsetFetchOnlyAfterItsOwnOrderBy() throws {
        let ordered = try plan("SELECT id, name FROM users ORDER BY name", "sqlsrv")
        #expect(ordered.mode == .append)
        #expect(ordered.page(offset: 1000, size: 1000).sql == "SELECT id, name FROM users ORDER BY name\nOFFSET 1000 ROWS FETCH NEXT 1001 ROWS ONLY")
        #expect(try plan("WITH x AS (SELECT * FROM users) SELECT * FROM x ORDER BY id", "dblib").page(offset: 5, size: 5).added == "OFFSET 5 ROWS FETCH NEXT 6 ROWS ONLY")
        // Without ORDER BY there is nothing for OFFSET to follow, and FOR XML/JSON must come last.
        #expect(try plan("SELECT id FROM users", "sqlsrv").mode == .skip)
        #expect(try plan("SELECT id FROM users ORDER BY id FOR JSON PATH", "sqlsrv").mode == .skip)
    }

    @Test func unknownDialectsAndCallablesSkipInTheRunner() throws {
        for driver in [nil, "oci", "firebird", "odbc"] as [String?] {
            let plan = try plan("SELECT * FROM t ORDER BY id", driver)
            #expect(plan.mode == .skip)
            #expect(plan.dialect == .other)
        }
    }

    // MARK: Generated PHP

    @Test func pageCodeCarriesTheSkipTheDriverAndTheBoundValues() throws {
        let page = try plan("SELECT * FROM t WHERE a = :a ORDER BY id", "pgsql").page(offset: 1000, size: 1000)
        let code = SQLTabRun.pageCode(page, connection: "reporting", bindings: [SQLBinding(target: .name("a"), value: .integer(5))])
        #expect(code.contains(#"return \RunletRunner\SqlTab::page("SELECT * FROM t WHERE a = :a ORDER BY id\nLIMIT 1001 OFFSET 1000", "reporting", 1000, 0, "pgsql", [['name' => "#))
        #expect(code.hasSuffix(#"], "LIMIT 1001 OFFSET 1000");"#))
        let skipped = SQLTabRun.pageCode(try plan("SELECT * FROM t LIMIT 5000", "mysql").page(offset: 2000, size: 1000), connection: nil)
        #expect(skipped.contains(#"::page("SELECT * FROM t LIMIT 5000", null, 1000, 2000, null, [], null);"#))
    }

    // MARK: Appending

    @Test func appendingAPageExtendsTheRowsAndTheTable() throws {
        let first = SQLResultInfo(columns: ["id", "name"], rows: [[.int(1), .string("a")], [.int(2), .string("b")]], truncated: true, truncation: "rows", elapsedMs: 2, driver: "sqlite", maxRows: 2, bytes: 18)
        let page = SQLResultInfo(columns: ["id", "name"], rows: [[.int(3), .null]], elapsedMs: 1.5, driver: "sqlite", maxRows: 2, bytes: 16)
        let combined = try #require(first.appending(page))
        #expect(combined.rows.count == 3)
        #expect(combined.table.rows.count == 3)
        #expect(combined.table.rowKeys == ["1", "2", "3"])
        #expect(combined.table.rows[2].map(\.text) == ["3", "NULL"])
        #expect(combined.table.rowFields[2].map(\.key) == ["id", "name"])
        // The same table a result of all three rows would have.
        #expect(combined.table == SQLResultInfo(columns: ["id", "name"], rows: combined.rows).table)
        #expect(combined.truncated == nil, "the last page says whether more follow")
        #expect(combined.elapsedMs == 3.5)
        #expect(combined.bytes == 34)
        #expect(combined.pages == 2)
        #expect(combined.summary == "3 rows in 2 pages")
        var more = page
        more.truncated = true
        more.truncation = "bytes"
        let third = try #require(combined.appending(more))
        #expect(third.summary == "First 4 rows in 3 pages (more not shown)")
        #expect(third.truncation == "bytes")
    }

    @Test func aPageWithOtherColumnsIsNotAppended() {
        let first = SQLResultInfo(columns: ["id", "name"], rows: [[.int(1), .string("a")]], truncated: true)
        #expect(first.appending(SQLResultInfo(columns: ["name", "id"], rows: [[.string("b"), .int(2)]])) == nil)
        #expect(first.appending(SQLResultInfo(affectedRows: 3)) == nil)
    }

    @Test func bytesDecodeFromTheEvent() throws {
        let decoded = try JSONDecoder().decode(SQLResultInfo.self, from: Data(#"{"columns":["a"],"rows":[[1]],"bytes":8}"#.utf8))
        #expect(decoded.bytes == 8)
        #expect(decoded.pages == nil)
    }

    // MARK: Limits

    @Test func pagesStopAtTheRowCellAndByteLimits() {
        #expect(SQLPaging.nextPageSize(rows: 1000, columns: 6, bytes: 50_000, pageSize: 1000) == 1000)
        #expect(SQLPaging.nextPageSize(rows: 49_500, columns: 6, bytes: 50_000, pageSize: 1000) == 500, "what is left under 50,000 rows")
        #expect(SQLPaging.nextPageSize(rows: 50_000, columns: 6, bytes: 50_000, pageSize: 1000) == nil)
        // A wide result keeps fewer rows: 500,000 cells of 40 columns are 12,500 rows.
        #expect(SQLPaging.nextPageSize(rows: 12_000, columns: 40, bytes: 50_000, pageSize: 1000) == 500)
        #expect(SQLPaging.nextPageSize(rows: 12_500, columns: 40, bytes: 50_000, pageSize: 1000) == nil)
        #expect(SQLPaging.nextPageSize(rows: 2000, columns: 3, bytes: SQLPaging.maxLoadedBytes, pageSize: 1000) == nil)
        #expect(SQLPaging.nextPageSize(rows: 1000, columns: 0, bytes: 0, pageSize: 10_000) == 10_000)
    }

    // MARK: Setting

    @Test func rowsPerPageIsOneOfTheOfferedSizes() throws {
        #expect(SQLPaging.normalizedPageSize(nil) == 1000)
        #expect(SQLPaging.normalizedPageSize(2500) == 2500)
        #expect(SQLPaging.normalizedPageSize(3000) == 2500)
        #expect(SQLPaging.normalizedPageSize(50_000) == 10_000)
        #expect(SQLPaging.normalizedPageSize(10) == 1000)
        #expect(AppSettings().sqlRowsPerPage == 1000)
        let saved = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"sqlRowsPerPage":99999}"#.utf8))
        #expect(saved.sqlRowsPerPage == 10_000)
        var settings = AppSettings()
        settings.sqlRowsPerPage = 5000
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).sqlRowsPerPage == 5000)
    }
}
