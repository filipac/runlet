import Foundation
import Testing
@testable import RunletCore

/// The schema explorer's filter and actions, and the result window's query (#21).
struct SQLSchemaExplorerTests {
    let tables: [SQLSchemaInfo.Table] = [
        .init(name: "customers", columns: [.init(name: "id"), .init(name: "email"), .init(name: "country")], rows: 1234),
        .init(name: "orders", columns: [.init(name: "id"), .init(name: "customer_id", references: "customers.id"), .init(name: "status")]),
        .init(name: "Order Lines", columns: [.init(name: "order"), .init(name: "qty")]),
    ]

    @Test func filterMatchesTablesThenColumns() {
        #expect(SQLSchemaExplorer.filter(tables, query: "").map(\.table.name) == ["customers", "orders", "Order Lines"])
        let order = SQLSchemaExplorer.filter(tables, query: "ORDER")
        #expect(order.map(\.table.name) == ["orders", "Order Lines"])
        #expect(order.allSatisfy { !$0.matchedColumns })
        let email = SQLSchemaExplorer.filter(tables, query: " mail ")
        #expect(email.map(\.table.name) == ["customers"])
        #expect(email.first?.columns.map(\.name) == ["email"])
        #expect(email.first?.matchedColumns == true)
        // Table names first, then tables matched by a column.
        #expect(SQLSchemaExplorer.filter(tables, query: "customer").map(\.table.name) == ["customers", "orders"])
        #expect(SQLSchemaExplorer.filter(tables, query: "nothing").isEmpty)
    }

    @Test func actionsPrepareCodeThatNeverRuns() {
        #expect(SQLSchemaExplorer.selectQuery(table: "orders", driver: "sqlite") == "SELECT *\nFROM orders\nLIMIT 50;")
        #expect(SQLSchemaExplorer.selectQuery(table: "Order Lines", driver: "mysql") == "SELECT *\nFROM `Order Lines`\nLIMIT 50;")
        #expect(SQLSchemaExplorer.selectQuery(table: "reporting.Daily", driver: "pgsql") == "SELECT *\nFROM reporting.\"Daily\"\nLIMIT 50;")
        #expect(SQLSchemaExplorer.selectQuery(table: "orders", driver: "sqlsrv", limit: 10) == "SELECT TOP 10 *\nFROM orders;")
        #expect(SQLSchemaExplorer.laravelQuery(table: "orders", connection: nil) == "DB::table('orders')->limit(50)->get();")
        #expect(SQLSchemaExplorer.laravelQuery(table: "it's", connection: "reports") == #"DB::connection('reports')->table('it\'s')->limit(50)->get();"#)
        #expect(SQLSchemaExplorer.hasQueryBuilder(framework: "laravel") && SQLSchemaExplorer.hasQueryBuilder(framework: "lumen"))
        #expect(!SQLSchemaExplorer.hasQueryBuilder(framework: "symfony") && !SQLSchemaExplorer.hasQueryBuilder(framework: nil))
        #expect(SQLSchemaExplorer.quoted("order", driver: "sqlite") == "\"order\"")
    }

    @Test func descriptions() {
        #expect(SQLSchemaExplorer.details(of: .init(name: "status", type: "varchar", nullable: false, defaultValue: "'pending'")) == "varchar · NOT NULL · default 'pending'")
        #expect(SQLSchemaExplorer.details(of: .init(name: "id", type: "integer", nullable: false, primaryKey: true)) == "integer · primary key")
        #expect(SQLSchemaExplorer.details(of: .init(name: "customer_id", type: "int", references: "customers.id")) == "int · → customers.id")
        #expect(SQLSchemaExplorer.rowsText(tables[0]) == "~\(Int64(1234).formatted()) rows", "in the Mac's number format")
        #expect(SQLSchemaExplorer.rowsText(tables[1]) == nil)
        #expect(SQLSchemaExplorer.details(of: .init(name: "pk", columns: ["a", "b"], unique: true, primary: true)) == "PRIMARY (a, b)")
        #expect(SQLSchemaExplorer.details(of: .init(name: "u", columns: ["email"], unique: true)) == "UNIQUE (email)")
        #expect(SQLSchemaExplorer.details(of: .init(name: "i", columns: ["status"])) == "(status)")
    }

    // MARK: Result window

    func cell(_ text: String, _ number: Double? = nil, null: Bool = false) -> ValueTable.Cell {
        ValueTable.Cell(text: text, number: number, isNull: null)
    }

    var table: ValueTable {
        ValueTable(columns: ["id", "status", "total", "placed"], rowKeys: ["1", "2", "3", "4"], rows: [
            [cell("1", 1), cell("paid"), cell("120.5", 120.5), cell("2026-09-28")],
            [cell("2", 2), cell("pending"), cell("42", 42), cell("2026-10-01")],
            [cell("3", 3), cell("Pending"), cell("18.75", 18.75), cell("NULL", null: true)],
            [cell("4", 4), cell("NULL", null: true), cell("9", 9), cell("2026-10-03")],
        ], rowFields: [[], [], [], []], omittedRows: 0)
    }

    func rows(_ query: ValueTableQuery) -> [Int] { query.rowIndices(in: table) }

    @Test func searchAndFilterRules() {
        #expect(rows(ValueTableQuery()) == [0, 1, 2, 3])
        #expect(rows(ValueTableQuery(search: "PEND")) == [1, 2])
        #expect(rows(ValueTableQuery(filters: [.init(column: 1, op: .equals, value: "pending")])) == [1, 2], "= ignores case")
        #expect(rows(ValueTableQuery(filters: [.init(column: 1, op: .doesNotEqual, value: "pending")])) == [0, 3], "≠ keeps NULL")
        #expect(rows(ValueTableQuery(filters: [.init(column: 1, op: .contains, value: "end")])) == [1, 2])
        #expect(rows(ValueTableQuery(filters: [.init(column: 1, op: .doesNotContain, value: "end")])) == [0, 3])
        #expect(rows(ValueTableQuery(filters: [.init(column: 2, op: .greaterThan, value: "40")])) == [0, 1], "numbers compare as numbers")
        #expect(rows(ValueTableQuery(filters: [.init(column: 2, op: .lessOrEqual, value: "18.75")])) == [2, 3])
        #expect(rows(ValueTableQuery(filters: [.init(column: 3, op: .greaterOrEqual, value: "2026-10-01")])) == [1, 3], "ISO dates compare as text; NULL never")
        #expect(rows(ValueTableQuery(filters: [.init(column: 3, op: .isEmpty)])) == [2])
        #expect(rows(ValueTableQuery(filters: [.init(column: 1, op: .isNotEmpty)])) == [0, 1, 2])
        // Rules combine with AND; an empty value doesn't filter yet.
        #expect(rows(ValueTableQuery(filters: [.init(column: 1, op: .contains, value: "pend"), .init(column: 2, op: .greaterThan, value: "20")])) == [1])
        #expect(rows(ValueTableQuery(filters: [.init(column: 1, op: .equals, value: "")])) == [0, 1, 2, 3])
        #expect(!ValueTableQuery(filters: [.init(column: 1, op: .equals, value: "")]).isFiltered)
        #expect(ValueTableQuery(filters: [.init(column: 1, op: .isEmpty)]).isFiltered)
    }

    @Test func sortingIsNumberAwareWithNullsLast() {
        #expect(rows(ValueTableQuery(sortColumn: 2)) == [3, 2, 1, 0])
        #expect(rows(ValueTableQuery(sortColumn: 2, ascending: false)) == [0, 1, 2, 3])
        #expect(rows(ValueTableQuery(sortColumn: 3)) == [0, 1, 3, 2], "NULL last ascending")
        #expect(rows(ValueTableQuery(sortColumn: 3, ascending: false)) == [3, 1, 0, 2], "and descending")
        #expect(rows(ValueTableQuery(search: "pend", sortColumn: 2)) == [2, 1])
    }

    @Test func csvAndTSVOfTheShownRows() {
        #expect(table.csv(rows: [1, 3], columns: [1, 2]) == "status,total\r\npending,42\r\nNULL,9\r\n", "NULL as Export CSV writes it")
        #expect(table.tsv(rows: [0, 2], columns: [0, 1]) == "1\tpaid\n3\tPending")
    }
}
