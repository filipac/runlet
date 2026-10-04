import Foundation
import Testing
@testable import RunletCore

/// Browse Table (#151): each dialect's page SQL (quoting, paging, sort, filters with bound
/// values), column types, refusals, and the generated PHP.
struct SQLTableBrowseTests {
    typealias Dialect = SQLTableBrowse.Dialect
    typealias Kind = SQLTableBrowse.ColumnKind

    static let columns: [SQLSchemaInfo.Column] = [
        .init(name: "id", type: "integer", nullable: false, primaryKey: true),
        .init(name: "name", type: "varchar", nullable: false),
        .init(name: "price", type: "decimal"),
        .init(name: "active", type: "boolean"),
        .init(name: "meta", type: "json"),
        .init(name: "photo", type: "blob"),
        .init(name: "created", type: "timestamp"),
    ]

    func request(_ dialect: Dialect, sort: SQLTableBrowse.Sort? = nil, filters: [SQLTableBrowse.Filter] = [], offset: Int = 0, pageSize: Int = 50, columns: [SQLSchemaInfo.Column] = SQLTableBrowseTests.columns, table: String = "items", binds: Bool = true) -> SQLTableBrowse.Request {
        SQLTableBrowse.Request(table: table, columns: columns, dialect: dialect, sort: sort, filters: filters, offset: offset, pageSize: pageSize, bindsValues: binds)
    }

    func query(_ request: SQLTableBrowse.Request) throws -> SQLTableBrowse.Query {
        try SQLTableBrowse.query(request).get()
    }

    func refusal(_ request: SQLTableBrowse.Request) -> SQLTableBrowse.Refusal? {
        if case .failure(let refusal) = SQLTableBrowse.query(request) { return refusal }
        return nil
    }

    // MARK: Dialects

    @Test func dialectsComeFromTheSchemasDriver() {
        #expect(Dialect(driver: "mysql") == .mysql)
        #expect(Dialect(driver: "pgsql") == .pgsql)
        #expect(Dialect(driver: "sqlite") == .sqlite)
        #expect(Dialect(driver: "sqlsrv") == .sqlServer)
        #expect(Dialect(driver: "dblib") == .sqlServer)
        #expect(Dialect(driver: nil, source: "WordPress $wpdb") == .mysql, "$wpdb is MySQL")
        #expect(Dialect(driver: nil, source: "AcmeDriver::sqlConnection()") == nil, "a callable's dialect is unknown")
        #expect(Dialect(driver: "oci") == nil)
    }

    @Test func namesAreAlwaysQuotedWithTheirQuoteDoubled() {
        #expect(Dialect.mysql.quote("order") == "`order`")
        #expect(Dialect.mysql.quote("we`ird") == "`we``ird`")
        #expect(Dialect.pgsql.quote("Mixed \"Case\"") == "\"Mixed \"\"Case\"\"\"")
        #expect(Dialect.sqlite.quote("a b") == "\"a b\"")
        #expect(Dialect.sqlServer.quote("a]b") == "[a]]b]")
        // PostgreSQL and SQL Server name tables outside the default schema `schema.table`.
        #expect(Dialect.pgsql.table("audit.events") == "\"audit\".\"events\"")
        #expect(Dialect.sqlServer.table("sales.orders") == "[sales].[orders]")
        #expect(Dialect.pgsql.table("orders") == "\"orders\"")
        #expect(Dialect.mysql.table("odd.name") == "`odd.name`", "MySQL lists only the current database's tables")
        #expect(Dialect.sqlite.table("odd.name") == "\"odd.name\"")
    }

    @Test func columnKindsFromTypeNames() {
        let cases: [(String?, Kind)] = [
            ("integer", .integer), ("INT(11) unsigned", .integer), ("bigint", .integer), ("tinyint", .integer), ("UNSIGNED BIG INT", .integer),
            ("decimal(8,2)", .decimal), ("numeric", .decimal), ("money", .decimal),
            ("double precision", .float), ("REAL", .float), ("float", .float),
            ("boolean", .boolean), ("bool", .boolean),
            ("character varying", .text), ("VARCHAR(255)", .text), ("text", .text), ("longtext", .text), ("nvarchar", .text), ("enum", .text),
            ("timestamp without time zone", .temporal), ("datetime", .temporal), ("date", .temporal), ("DATETIME2", .temporal),
            ("bytea", .binary), ("blob", .binary), ("varbinary", .binary),
            ("json", .json), ("jsonb", .json), ("uuid", .uuid), ("uniqueidentifier", .uuid),
            ("ARRAY", .other), ("integer[]", .other), ("point", .other), ("USER-DEFINED", .other), ("inet", .other), ("", .other), (nil, .other),
        ]
        for (type, kind) in cases {
            #expect(Kind(type: type) == kind, "\(type ?? "nil")")
        }
        #expect(Kind(type: "bit") == .binary, "MySQL's bit is a bit string")
        #expect(Kind(type: "bit", dialect: .sqlServer) == .integer, "SQL Server's bit is 0 or 1")
    }

    @Test func valuesAreTypedByTheirColumn() {
        #expect(Kind.integer.value("42") == .integer(42))
        #expect(Kind.integer.value(" -7 ") == .integer(-7))
        #expect(Kind.integer.value("+3") == .integer(3))
        #expect(Kind.integer.value("18446744073709551615") == .decimal("18446744073709551615"), "past 64 bits: digits as text")
        #expect(Kind.integer.value("4.5") == nil)
        #expect(Kind.integer.value("12a") == nil)
        #expect(Kind.decimal.value("19.99") == .decimal("19.99"))
        #expect(Kind.decimal.value("1e3") == .decimal("1e3"))
        #expect(Kind.decimal.value(".5") == .decimal(".5"))
        #expect(Kind.decimal.value("1,5") == nil)
        #expect(Kind.boolean.value("TRUE") == .boolean(true))
        #expect(Kind.boolean.value("0") == .boolean(false))
        #expect(Kind.boolean.value("maybe") == nil)
        #expect(Kind.text.value(" padded ") == .text(" padded "), "text is kept as typed")
        #expect(Kind.binary.value("00") == nil)
        #expect(Kind.uuid.value("0b6e…") == .text("0b6e…"))
    }

    // MARK: Pages

    @Test func aPageReadsTheSchemasColumnsInPrimaryKeyOrderWithOneRowMore() throws {
        let page = try query(request(.pgsql, offset: 100, pageSize: 50))
        #expect(page.sql == """
        SELECT "id", "name", "price", "active", "meta", "photo", "created"
        FROM "items"
        ORDER BY "id" ASC
        LIMIT 51 OFFSET 100
        """)
        #expect(page.bindings.isEmpty)
        #expect(page.ordered)
        #expect(page.rowsText == "rows 101–150")
        let mysql = try query(request(.mysql))
        #expect(mysql.sql.hasPrefix("SELECT `id`, `name`"))
        #expect(mysql.sql.hasSuffix("FROM `items`\nORDER BY `id` ASC\nLIMIT 51 OFFSET 0"))
    }

    @Test func sqlServerPagesWithOffsetFetchAndAlwaysOrders() throws {
        let page = try query(request(.sqlServer, offset: 20, pageSize: 10, table: "sales.orders"))
        #expect(page.sql.hasSuffix("FROM [sales].[orders]\nORDER BY [id] ASC\nOFFSET 20 ROWS FETCH NEXT 11 ROWS ONLY"))
        let keyless = try query(request(.sqlServer, columns: [.init(name: "note", type: "nvarchar")], table: "log"))
        #expect(keyless.sql == "SELECT [note]\nFROM [log]\nORDER BY (SELECT NULL)\nOFFSET 0 ROWS FETCH NEXT 51 ROWS ONLY")
        #expect(!keyless.ordered)
        let sqlite = try query(request(.sqlite, columns: [.init(name: "note", type: "text")], table: "log"))
        #expect(sqlite.sql == "SELECT \"note\"\nFROM \"log\"\nLIMIT 51 OFFSET 0", "no primary key, no sort: the database's order")
    }

    @Test func aSortAddsThePrimaryKeyAfterIt() throws {
        let page = try query(request(.mysql, sort: .init(column: "price", ascending: false)))
        #expect(page.sql.contains("ORDER BY `price` DESC, `id` DESC\n"))
        let byKey = try query(request(.sqlite, sort: .init(column: "id", ascending: false)))
        #expect(byKey.sql.contains("ORDER BY \"id\" DESC\n"))
        #expect(refusal(request(.sqlite, sort: .init(column: "price; DROP TABLE items")))
            == .unknownColumn("price; DROP TABLE items"), "only the schema's columns sort")
    }

    @Test func compositeKeysOrderByEveryColumn() throws {
        let columns: [SQLSchemaInfo.Column] = [.init(name: "order_id", type: "int", primaryKey: true), .init(name: "line", type: "int", primaryKey: true), .init(name: "qty", type: "int")]
        let page = try query(request(.pgsql, columns: columns, table: "lines"))
        #expect(page.sql.contains("ORDER BY \"order_id\" ASC, \"line\" ASC\n"))
    }

    // MARK: Filters

    @Test func filterValuesAreBoundAndTypedNeverWrittenIntoTheSQL() throws {
        let page = try query(request(.mysql, filters: [
            .init(column: "id", op: .greaterOrEqual, value: "10"),
            .init(column: "name", op: .equals, value: "O'Brien'; DROP TABLE items; --"),
            .init(column: "price", op: .lessThan, value: "19.99"),
            .init(column: "active", op: .equals, value: "yes"),
        ]))
        #expect(page.sql.contains("WHERE `id` >= ?\n  AND `name` = ?\n  AND `price` < ?\n  AND `active` = ?\n"))
        #expect(!page.sql.contains("O'Brien"), "values never reach the SQL")
        #expect(page.bindings == [
            SQLBinding(target: .position(1), value: .integer(10)),
            SQLBinding(target: .position(2), value: .text("O'Brien'; DROP TABLE items; --")),
            SQLBinding(target: .position(3), value: .decimal("19.99")),
            SQLBinding(target: .position(4), value: .boolean(true)),
        ])
        #expect(page.display.hasSuffix("-- ?1 = 10, ?2 = 'O''Brien''; DROP TABLE items; --', ?3 = 19.99, ?4 = true"))
    }

    @Test func containsIsALikeWithItsWildcardsEscaped() throws {
        let mysql = try query(request(.mysql, filters: [.init(column: "name", op: .contains, value: "50%_off!")]))
        #expect(mysql.sql.contains("WHERE `name` LIKE ? ESCAPE '!'\n"))
        #expect(mysql.bindings.first?.value == .text("%50!%!_off!!%"))
        // PostgreSQL ignores case with ILIKE and compares other types as text.
        let pgsql = try query(request(.pgsql, filters: [.init(column: "name", op: .contains, value: "ada"), .init(column: "id", op: .contains, value: "7")]))
        #expect(pgsql.sql.contains("WHERE \"name\" ILIKE ? ESCAPE '!'\n  AND CAST(\"id\" AS TEXT) ILIKE ? ESCAPE '!'\n"))
        let sqlServer = try query(request(.sqlServer, filters: [.init(column: "name", op: .contains, value: "[x]"), .init(column: "price", op: .contains, value: "9")]))
        #expect(sqlServer.sql.contains("WHERE [name] LIKE ? ESCAPE '!'\n  AND CAST([price] AS NVARCHAR(MAX)) LIKE ? ESCAPE '!'\n"))
        #expect(sqlServer.bindings.first?.value == .text("%![x]%"), "SQL Server reads [ as a pattern")
    }

    @Test func nullMatchesDoesntContainAndNotEqualsAsInTheResultWindow() throws {
        let page = try query(request(.pgsql, filters: [.init(column: "name", op: .doesNotContain, value: "x"), .init(column: "price", op: .doesNotEqual, value: "5")]))
        #expect(page.sql.contains("WHERE (\"name\" IS NULL OR \"name\" NOT ILIKE ? ESCAPE '!')\n  AND (\"price\" IS NULL OR \"price\" <> ?)\n"))
        let sqlite = try query(request(.sqlite, filters: [.init(column: "name", op: .doesNotContain, value: "x")]))
        #expect(sqlite.sql.contains("WHERE (\"name\" IS NULL OR \"name\" NOT LIKE ? ESCAPE '!')\n"))
    }

    @Test func emptyIsNullOrEmptyTextAndNullElsewhere() throws {
        let page = try query(request(.mysql, filters: [.init(column: "name", op: .isEmpty), .init(column: "price", op: .isEmpty), .init(column: "name", op: .isNotEmpty), .init(column: "photo", op: .isNotEmpty)]))
        #expect(page.sql.contains("WHERE (`name` IS NULL OR `name` = '')\n  AND `price` IS NULL\n  AND (`name` IS NOT NULL AND `name` <> '')\n  AND `photo` IS NOT NULL\n"))
        #expect(page.bindings.isEmpty)
    }

    @Test func rulesWithoutAValueYetAreLeftOut() throws {
        let page = try query(request(.sqlite, filters: [.init(column: "name", op: .contains, value: "")]))
        #expect(!page.sql.contains("WHERE"))
    }

    @Test func unsupportedOperatorsAndValuesAreRefused() {
        #expect(refusal(request(.pgsql, filters: [.init(column: "active", op: .lessThan, value: "true")])) == .unsupported(column: "active", op: .lessThan, kind: .boolean))
        #expect(refusal(request(.pgsql, filters: [.init(column: "meta", op: .equals, value: "{}")])) == .unsupported(column: "meta", op: .equals, kind: .json))
        #expect(refusal(request(.mysql, filters: [.init(column: "photo", op: .contains, value: "ff")])) == .unsupported(column: "photo", op: .contains, kind: .binary))
        #expect(refusal(request(.mysql, filters: [.init(column: "id", op: .equals, value: "seven")])) == .invalidValue(column: "id", value: "seven", kind: .integer))
        #expect(refusal(request(.mysql, filters: [.init(column: "gone", op: .equals, value: "1")])) == .unknownColumn("gone"))
        let message = SQLTableBrowse.Refusal.invalidValue(column: "id", value: "seven", kind: .integer).description
        #expect(message == "The filter on id can't run: “seven” isn't a whole number. id is an integer column, and Runlet binds the value as one.")
        #expect(SQLTableBrowse.Refusal.unsupported(column: "meta", op: .equals, kind: .json).description.contains("“contains”"))
        // JSON can still be searched as text.
        #expect(refusal(request(.pgsql, filters: [.init(column: "meta", op: .contains, value: "red")])) == nil)
    }

    @Test func callableConnectionsTakeOnlyFiltersWithoutValues() {
        #expect(refusal(request(.mysql, filters: [.init(column: "name", op: .equals, value: "Ada")], binds: false)) == .cannotBind(column: "name"))
        #expect(refusal(request(.mysql, filters: [.init(column: "name", op: .isEmpty)], binds: false)) == nil)
        #expect(refusal(request(.mysql, sort: .init(column: "name"), binds: false)) == nil)
    }

    @Test func wideTablesReadTheFirstTwoHundredColumns() throws {
        let columns = (1...250).map { SQLSchemaInfo.Column(name: "c\($0)", type: "int", primaryKey: $0 == 1) }
        let page = try query(request(.sqlite, columns: columns, table: "wide"))
        #expect(page.sql.contains("\"c200\"\nFROM"))
        #expect(!page.sql.contains("\"c201\""))
        #expect(refusal(request(.sqlite, columns: [], table: "empty")) == .noColumns("empty"))
    }

    // MARK: Generated PHP

    @Test func browseCodeCallsTheRunnerWithTheValuesAsData() throws {
        let page = try query(request(.pgsql, filters: [.init(column: "name", op: .equals, value: "it's")]))
        let code = SQLTabRun.browseCode(page, connection: "reporting", driver: "pgsql")
        #expect(code.contains("return \\RunletRunner\\SqlTab::browse(\"SELECT \\\"id\\\", "))
        #expect(code.contains("\\nFROM \\\"items\\\"\\nWHERE \\\"name\\\" = ?\\n"), "the SQL is a PHP string; the value isn't in it")
        #expect(code.hasSuffix(", \"reporting\", 50, \"pgsql\", [['position' => 1, 'type' => 'str', 'value' => 'it\\'s']]);"))
        let callable = SQLTabRun.browseCode(try query(request(.mysql, binds: false)), connection: nil, driver: nil)
        #expect(callable.hasSuffix(", null, 50, null, []);"))
    }
}
