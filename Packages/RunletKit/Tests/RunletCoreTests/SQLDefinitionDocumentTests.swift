import Foundation
@testable import RunletCore
import Testing

/// Show Definition (#148): the runner code, the new tab's title and text, and the event.
struct SQLDefinitionDocumentTests {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static let readAt = Date(timeIntervalSince1970: 1_791_119_000) // 2026-10-04 13:03 UTC

    @Test func codeReadsOnlyTheDefinition() {
        #expect(SQLDefinition.code(table: "orders", connection: nil) == """
            <?php
            // Runlet schema explorer (#148): a table's or view's definition, read from the catalog. Nothing else runs.
            return \\RunletRunner\\SqlTab::definition("orders", null);
            """)
        #expect(SQLDefinition.code(table: "o'rders\\x$y", connection: "pgsql").hasSuffix(#"SqlTab::definition("o'rders\\x\$y", "pgsql");"#))
    }

    @Test func titleNamesTheTable() {
        #expect(SQLDefinition.tabTitle("orders") == "orders (definition)")
    }

    @Test func documentHasAHeaderThatSaysNothingRan() {
        let info = SQLDefinitionInfo(table: "orders", kind: "table", sql: "CREATE TABLE `orders` (\n  `id` int NOT NULL\n);\n", how: "SHOW CREATE TABLE", driver: "mysql", server: "MariaDB 11.4.2")
        #expect(SQLDefinition.document(info, connection: "the default connection", target: "shop", readAt: Self.readAt, calendar: Self.calendar) == """
            -- Definition of table orders from MariaDB 11.4.2 (SHOW CREATE TABLE).
            -- Read 2026-10-04 13:03 through the default connection on shop.
            -- Not run: Runlet only read the catalog. This tab runs only when you press Run.

            CREATE TABLE `orders` (
              `id` int NOT NULL
            );

            """)
    }

    @Test func reconstructedDefinitionsCarryTheirNotes() {
        let info = SQLDefinitionInfo(table: "p148_orders", kind: "view", sql: "CREATE OR REPLACE VIEW public.p148_orders AS\nSELECT 1;", how: "pg_catalog", reconstructed: true,
                                     notes: ["Reconstructed by Runlet around PostgreSQL's pg_get_viewdef().", "Left out: owner and privileges."], driver: "pgsql")
        let text = SQLDefinition.document(info, connection: "the saved connection “Analytics”", target: "acme", readAt: Self.readAt, calendar: Self.calendar)
        #expect(text.hasPrefix("""
            -- Definition of view p148_orders from PostgreSQL (pg_catalog).
            -- Read 2026-10-04 13:03 through the saved connection “Analytics” on acme.
            -- Reconstructed by Runlet around PostgreSQL's pg_get_viewdef().
            -- Left out: owner and privileges.
            -- Not run:
            """))
        #expect(text.hasSuffix("\n\nCREATE OR REPLACE VIEW public.p148_orders AS\nSELECT 1;\n"))
        #expect(text.components(separatedBy: "\n").allSatisfy { $0.count <= 103 })
    }

    @Test func longNotesWrap() {
        let note = String(repeating: "word ", count: 30)
        let lines = SQLDefinition.wrapped(note, width: 100)
        #expect(lines.count == 2 && lines.allSatisfy { $0.count <= 100 })
        #expect(SQLDefinition.wrapped("", width: 100) == [""])
    }

    @Test func databaseNames() {
        #expect(SQLDefinition.databaseName("mysql") == "MySQL or MariaDB")
        #expect(SQLDefinition.databaseName("pgsql") == "PostgreSQL")
        #expect(SQLDefinition.databaseName("sqlite") == "SQLite")
        #expect(SQLDefinition.databaseName(nil) == "the database")
    }

    @Test func decodesTheEvent() throws {
        let json = #"{"driver":"sqlite","source":"ShopDriver::sqlConnection()","connection":null,"table":"orders","kind":"table","how":"sqlite_master","sql":"CREATE TABLE orders (id INTEGER);","server":"SQLite 3.45.1","elapsedMs":1.2,"future":"ignored"}"#
        let info = try JSONDecoder().decode(SQLDefinitionInfo.self, from: Data(json.utf8))
        #expect(info == SQLDefinitionInfo(table: "orders", kind: "table", sql: "CREATE TABLE orders (id INTEGER);", how: "sqlite_master", driver: "sqlite", server: "SQLite 3.45.1", source: "ShopDriver::sqlConnection()", elapsedMs: 1.2))
        #expect(!info.isView)
        #expect(SQLDefinitionInfo(table: "t", kind: "materialized view", sql: "").isView)
    }
}
