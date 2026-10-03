import Foundation
@testable import RunletCore
import Testing

/// Explain Statement (#147): plans read from each database's own output into one tree, the
/// generated PHP, and the refusals made before anything is sent.
struct SQLPlanTests {
    private func titles(_ plan: SQLPlan) -> [String] {
        plan.nodes.map { String(repeating: "  ", count: $0.depth) + $0.title }
    }

    private func decode(_ json: String) throws -> SQLPlanInfo {
        try JSONDecoder().decode(SQLPlanInfo.self, from: Data(json.utf8))
    }

    // MARK: MariaDB

    @Test func mariadbFullScanAndJoin() throws {
        let scan = try SQLPlanParser.mysql(json: SQLPlanFixtures.mariadbScan, dialect: .mariadb)
        #expect(titles(scan) == ["Full table scan on p147_customers"])
        let node = try #require(scan.nodes.first)
        #expect(node.fullScan)
        #expect(node.rows == 50)
        #expect(node.cost == 0.0190048)
        #expect(node.details == ["Condition: p147_customers.country = 'UK'"])
        #expect(scan.totalCost == 0.0190048)
        #expect(scan.fullScans.count == 1)

        let join = try SQLPlanParser.mysql(json: SQLPlanFixtures.mariadbJoin, dialect: .mariadb)
        #expect(titles(join) == [
            "Sort (filesort)",
            "  Temporary table",
            "    Nested loop join",
            "      Full table scan on i",
            "      Unique index lookup on c using PRIMARY",
        ])
        #expect(join.nodes[0].details == ["Sort key: sum(i.qty) desc"])
        #expect(join.nodes[0].descendants == 4)
        #expect(join.nodes[3].fullScan && !join.nodes[4].fullScan)
        #expect(join.nodes[3].details.contains("Possible keys (none used): p147_items_customer"))
        #expect(join.nodes[4].details.contains("Ref: shop.i.customer_id"))
        #expect(join.nodes[4].parent == 2)
        #expect(join.totalCost == 0.223162)
    }

    @Test func mariadbUnionSubqueryDeleteAndNoTables() throws {
        let sub = try SQLPlanParser.mysql(json: SQLPlanFixtures.mariadbSub, dialect: .mariadb)
        #expect(titles(sub) == [
            "Union result on <union1,3>",
            "  Select #1",
            "    Nested loop join",
            "      Full table scan on p147_customers",
            "      Unique index lookup on <subquery2> using distinct_key",
            "        Materialize",
            "          Select #2",
            "            Full table scan on p147_items",
            "  UNION #3",
            "    Single row (constant) on p147_customers using PRIMARY",
        ])
        #expect(sub.fullScans.count == 2)

        let delete = try SQLPlanParser.mysql(json: SQLPlanFixtures.mariadbDelete, dialect: .mariadb)
        #expect(titles(delete) == ["Delete: full table scan on p147_items"])
        #expect(delete.nodes[0].fullScan && delete.nodes[0].rows == 200)

        let none = try SQLPlanParser.mysql(json: SQLPlanFixtures.mariadbNone, dialect: .mariadb)
        #expect(titles(none) == ["No tables used"])
        #expect(!none.nodes[0].fullScan)

        let pk = try SQLPlanParser.mysql(json: SQLPlanFixtures.mariadbPk, dialect: .mariadb)
        #expect(titles(pk) == ["Single row (constant) on p147_customers using PRIMARY"])
        #expect(pk.fullScans.isEmpty)
    }

    @Test func mariadbAnalyze() throws {
        let plan = try SQLPlanParser.mysql(json: SQLPlanFixtures.mariadbAnalyze, dialect: .mariadb, analyzed: true)
        #expect(plan.analyzed)
        #expect(titles(plan).last == "      Unique index lookup on c using PRIMARY")
        let customers = try #require(plan.nodes.last)
        #expect(customers.actualRows == 1)
        #expect(customers.loops == 200)
        #expect(customers.actualMs.map { abs($0 - 0.232807238) < 0.000001 } == true)
        #expect(plan.nodes[0].details.contains("Output rows: 25"))
        #expect(plan.executionMs.map { abs($0 - (0.528894576 + 0.01600811)) < 0.000001 } == true)
    }

    // MARK: MySQL

    @Test func mysqlJSONFormats() throws {
        let join = try SQLPlanParser.mysql(json: SQLPlanFixtures.mysqlJoin)
        #expect(titles(join) == [
            "Sort (filesort)",
            "  Group",
            "    Nested loop join",
            "      Full table scan on c",
            "      Index lookup on i using p147_items_customer",
        ])
        #expect(join.totalCost == 12.25)
        let customers = join.nodes[3]
        #expect(customers.fullScan && customers.rows == 50 && customers.cost == 5.25)
        #expect(customers.details.contains("Filtered: 10%"))
        #expect(join.nodes[1].details == ["Using a temporary table"])

        let union = try SQLPlanParser.mysql(json: SQLPlanFixtures.mysqlUnion)
        #expect(titles(union) == [
            "Union result on <union1,2>",
            "  Select #1",
            "    Single row (constant) on p147_customers using PRIMARY",
            "  Select #2",
            "    Full table scan on p147_items",
        ])
        #expect(union.nodes[3].cost == 20.25)

        let none = try SQLPlanParser.mysql(json: SQLPlanFixtures.mysqlNoTables)
        #expect(titles(none) == ["No tables used"])

        let version2 = try SQLPlanParser.mysql(json: SQLPlanFixtures.mysqlVersion2)
        #expect(titles(version2) == ["Filter", "  Table scan on c"])
        #expect(version2.nodes[0].details == ["Condition: (c.country = 'UK')"])
        #expect(version2.nodes[1].fullScan && version2.nodes[1].rows == 50)
        #expect(version2.totalCost == 5.25)
    }

    @Test func mysqlAnalyzeTree() {
        let plan = SQLPlanParser.mysqlTree(SQLPlanFixtures.mysqlAnalyzeTree)
        #expect(titles(plan) == [
            "Sort",
            "  Table scan on <temporary>",
            "    Aggregate using temporary table",
            "      Nested loop inner join",
            "        Filter",
            "          Table scan on c",
            "        Index lookup on i using p147_items_customer",
        ])
        #expect(plan.nodes[0].details == ["sum(i.qty) DESC"])
        #expect(plan.nodes[4].details == ["(c.country = 'UK')"])
        let scan = plan.nodes[5]
        #expect(scan.fullScan && scan.rows == 50 && scan.cost == 5.25 && scan.actualRows == 50 && scan.actualMs == 0.060 && scan.loops == 1)
        let lookup = plan.nodes[6]
        #expect(lookup.table == "i" && lookup.index == "p147_items_customer" && lookup.loops == 25 && lookup.actualRows == 4)
        #expect(!lookup.fullScan)
        #expect(!plan.nodes[1].fullScan, "a scan of MySQL's own temporary table isn't a table's full scan")
        #expect(plan.nodes[6].details == ["(customer_id=c.id)"])
        #expect(plan.analyzed)
    }

    // MARK: PostgreSQL

    @Test func postgresPlans() throws {
        let scan = try SQLPlanParser.postgres(json: SQLPlanFixtures.postgresScan)
        #expect(titles(scan) == ["Seq Scan on p147_customers"])
        #expect(scan.nodes[0].fullScan && scan.nodes[0].rows == 25 && scan.nodes[0].cost == 1.62)
        #expect(scan.nodes[0].details == ["Filter: ((country)::text = 'UK'::text)"])

        let join = try SQLPlanParser.postgres(json: SQLPlanFixtures.postgresJoin)
        #expect(titles(join) == [
            "Sort",
            "  HashAggregate",
            "    Hash Join",
            "      Seq Scan on p147_items i",
            "      Hash",
            "        Seq Scan on p147_customers c",
        ])
        #expect(join.totalCost == 7.90)
        #expect(join.nodes[0].details == ["Sort Key: (sum(i.qty)) DESC"])
        #expect(join.nodes[2].details == ["Hash Cond: (i.customer_id = c.id)"])
        #expect(join.fullScans.count == 2)
        #expect(join.summary == "6 steps · 2 full scans · cost 7.90")

        let sub = try SQLPlanParser.postgres(json: SQLPlanFixtures.postgresSub)
        #expect(sub.nodes.count == 8)
        #expect(titles(sub).last == "    Seq Scan on p147_customers p147_customers_1")

        let delete = try SQLPlanParser.postgres(json: SQLPlanFixtures.postgresDelete)
        #expect(titles(delete) == ["Delete on p147_items", "  Seq Scan on p147_items"])

        let none = try SQLPlanParser.postgres(json: SQLPlanFixtures.postgresNone)
        #expect(titles(none) == ["Result"])
        #expect(none.fullScans.isEmpty)
    }

    @Test func postgresAnalyze() throws {
        let plan = try SQLPlanParser.postgres(json: SQLPlanFixtures.postgresAnalyze)
        #expect(plan.analyzed)
        #expect(plan.planningMs != nil && plan.executionMs != nil)
        let customers = try #require(plan.nodes.last)
        #expect(customers.actualRows == 25 && customers.loops == 1)
        #expect(customers.details.contains("Rows Removed by Filter: 25"))
        #expect(plan.nodes[0].details.contains("Sort Method: quicksort, 26 kB"))
        #expect(plan.nodes[0].metrics.hasPrefix("rows 25 · cost 7.90 · actual 25 rows, 0.048 ms"))

        let delete = try SQLPlanParser.postgres(json: SQLPlanFixtures.postgresAnalyzeDelete)
        #expect(titles(delete) == ["Delete on p147_items", "  Seq Scan on p147_items"])
        #expect(delete.nodes[1].details.contains("Rows Removed by Filter: 196"))
    }

    // MARK: SQLite

    @Test func sqliteQueryPlanRows() {
        func rows(_ list: [(Int64, Int64, String)]) -> [[SQLCell]] { list.map { [.int($0.0), .int($0.1), .string($0.2)] } }
        // SQLite 3.45.2, the same tables.
        let join = SQLPlanParser.sqlite(rows: rows([
            (9, 0, "SCAN c"),
            (13, 0, "SEARCH i USING INDEX items_customer (customer_id=?)"),
            (18, 0, "USE TEMP B-TREE FOR GROUP BY"),
            (56, 0, "USE TEMP B-TREE FOR ORDER BY"),
        ]))
        #expect(titles(join) == ["SCAN c", "SEARCH i USING INDEX items_customer", "USE TEMP B-TREE FOR GROUP BY", "USE TEMP B-TREE FOR ORDER BY"])
        #expect(join.nodes[0].fullScan && !join.nodes[1].fullScan)
        #expect(join.nodes[1].details == ["(customer_id=?)"])
        #expect(join.nodes.allSatisfy { $0.rows == nil && $0.cost == nil })

        let compound = SQLPlanParser.sqlite(rows: rows([
            (1, 0, "COMPOUND QUERY"),
            (2, 1, "LEFT-MOST SUBQUERY"),
            (5, 2, "SEARCH customers USING INTEGER PRIMARY KEY (rowid=?)"),
            (9, 2, "LIST SUBQUERY 1"),
            (11, 9, "SCAN items"),
            (31, 1, "UNION USING TEMP B-TREE"),
            (33, 31, "SEARCH customers USING INTEGER PRIMARY KEY (rowid=?)"),
        ]))
        #expect(titles(compound) == [
            "COMPOUND QUERY",
            "  LEFT-MOST SUBQUERY",
            "    SEARCH customers USING INTEGER PRIMARY KEY",
            "    LIST SUBQUERY 1",
            "      SCAN items",
            "  UNION USING TEMP B-TREE",
            "    SEARCH customers USING INTEGER PRIMARY KEY",
        ])
        #expect(compound.fullScans.map(\.table) == ["items"])

        let covering = SQLPlanParser.sqlite(rows: rows([(2, 0, "SCAN items USING COVERING INDEX items_customer")]))
        #expect(!covering.nodes[0].fullScan && covering.nodes[0].index == "items_customer")
        #expect(covering.nodes[0].details == ["Covering index"])
        let constant = SQLPlanParser.sqlite(rows: rows([(1, 0, "SCAN CONSTANT ROW")]))
        #expect(!constant.nodes[0].fullScan)
        // SQLite before 3.36: "SCAN TABLE orders".
        let old = SQLPlanParser.sqlite(rows: rows([(0, 0, "SCAN TABLE orders"), (0, 0, "SEARCH TABLE users USING INDEX users_email (email=?)")]))
        #expect(old.nodes.map(\.table) == ["orders", "users"])
        #expect(old.nodes.map(\.depth) == [0, 0])
        #expect(old.nodes[0].fullScan)
    }

    // MARK: The event

    @Test func eventDecodesAndParsesOnce() throws {
        let raw = String(data: try JSONEncoder().encode(SQLPlanFixtures.postgresJoin), encoding: .utf8)!
        let info = try decode(#"{"driver":"pgsql","dialect":"pgsql","format":"json","analyze":false,"explained":"EXPLAIN (FORMAT JSON)","raw":\#(raw),"serverVersion":"14.23 (Debian 14.23-1.pgdg13+1)","elapsedMs":1.5,"connection":null,"source":"Laravel DB::connection()"}"#)
        #expect(info.plan?.nodes.count == 6)
        #expect(info.parseError == nil)
        #expect(info.databaseName == "PostgreSQL 14.23")
        #expect(info.originText == "PostgreSQL 14.23 · default connection · via Laravel DB::connection()")
        #expect(info.plainText.hasPrefix("Explain: 6 steps · 2 full scans · cost 7.90 in 1.50 ms\n-> Sort  (rows 25 · cost 7.90)\n     Sort Key: (sum(i.qty)) DESC\n  -> HashAggregate"))
        #expect(info.markdown.contains("```text"))

        let sqlite = try decode(#"{"driver":"sqlite","dialect":"sqlite","format":"rows","analyze":false,"rows":[[2,0,"SCAN customers"]],"serverVersion":"3.45.2","saved":true,"connection":"Local file","source":"saved connection \"Local file\" (sqlite, /tmp/x.sqlite)"}"#)
        #expect(sqlite.plan?.nodes.first?.fullScan == true)
        #expect(sqlite.rawText == "id\tparent\tdetail\n2\t0\tSCAN customers")
        #expect(sqlite.originText == "SQLite 3.45.2 · via saved connection \"Local file\" (sqlite, /tmp/x.sqlite)")

        let mariadb = try decode(#"{"driver":"mysql","dialect":"mariadb","format":"json","raw":"{}","serverVersion":"5.5.5-10.11.6-MariaDB"}"#)
        #expect(mariadb.plan == nil)
        #expect(mariadb.parseError?.contains("query_block") == true)
        #expect(mariadb.databaseName == "MariaDB 10.11.6")

        let truncated = try decode(#"{"driver":"pgsql","dialect":"pgsql","format":"json","raw":"[{\"Plan\":","rawTruncated":true}"#)
        #expect(truncated.plan == nil && truncated.parseError?.contains("longer than Runlet keeps") == true)
        #expect(truncated.rawText.hasSuffix("(Runlet keeps the first 4 MiB of a plan)"))

        let tree = try decode(#"{"driver":"mysql","dialect":"mysql","format":"tree","analyze":true,"raw":"-> Table scan on t  (cost=1 rows=2) (actual time=0.1..0.2 rows=2 loops=1)","serverVersion":"8.4.2"}"#)
        #expect(tree.plan?.nodes.first?.fullScan == true)
        #expect(tree.isAnalyze && tree.databaseName == "MySQL 8.4.2")

        let unknown = try decode(#"{"driver":"oci","raw":"x"}"#)
        #expect(unknown.plan == nil && unknown.parseError != nil)
    }

    @Test func textTreeForCopy() throws {
        let plan = try SQLPlanParser.postgres(json: SQLPlanFixtures.postgresDelete)
        #expect(plan.text == """
        -> Delete on p147_items  (rows 0 · cost 4.50)
          -> Seq Scan on p147_items  (rows 4 · cost 4.50)  [full scan]
               Filter: (qty < 5)
        """)
    }

    // MARK: Requests and refusals

    @Test func generatedCode() {
        let plan = SQLExplain.code(statement: "SELECT * FROM t WHERE name = 'it''s'", connection: "mysql", mode: .plan)
        #expect(plan.contains(#"return \RunletRunner\SqlTab::explain("SELECT * FROM t WHERE name = 'it''s'", "mysql", false);"#))
        #expect(plan.contains("the statement doesn't run"))
        let analyze = SQLExplain.code(statement: "DELETE FROM t", connection: nil, mode: .analyze, params: "[['position' => 1, 'type' => 'int', 'value' => 3]]")
        #expect(analyze.contains(#"SqlTab::explain("DELETE FROM t", null, true, [['position' => 1, 'type' => 'int', 'value' => 3]]);"#))
        #expect(analyze.contains("the statement runs"))
    }

    @Test func refusalsAndAnalyzeGuards() {
        #expect(SQLExplain.refusal(of: "SELECT 1") == nil)
        #expect(SQLExplain.refusal(of: "-- note\nexplain select 1")?.contains("already an EXPLAIN") == true)
        #expect(SQLExplain.refusal(of: "DESCRIBE SELECT 1")?.contains("DESCRIBE") == true)
        #expect(SQLExplain.refusal(of: "ANALYZE SELECT 1")?.contains("ANALYZE") == true)
        #expect(SQLExplain.refusal(of: "WITH x AS (SELECT 1) SELECT * FROM x") == nil)

        #expect(SQLExplain.analyzeWrite(of: "SELECT * FROM t") == nil)
        #expect(SQLExplain.analyzeWrite(of: "DELETE FROM t") == .write("DELETE"))
        #expect(SQLExplain.analyzeWrite(of: "WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d") == .write("DELETE"))
        #expect(SQLExplain.analyzeWrite(of: "LISTEN x") == .unknown("LISTEN"))
        #expect(SQLExplain.analyzedStatement(.write("DELETE")) == "the DELETE")
        #expect(SQLExplain.analyzedStatement(.unknown("LISTEN")) == "a statement starting with LISTEN")

        #expect(SQLExplain.productionWarning(analyzing: "DELETE FROM t") == "This statement can change data or the schema (EXPLAIN ANALYZE … DELETE).")
        #expect(SQLExplain.productionWarning(analyzing: "SELECT 1") == nil)
        #expect(SQLExplain.productionWarning(analyzing: "LISTEN x")?.contains("can't tell") == true)
    }
}
