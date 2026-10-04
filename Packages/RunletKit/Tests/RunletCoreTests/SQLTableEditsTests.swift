import Foundation
import Testing
@testable import RunletCore

/// Browse Table's row edits (#151): who may edit, pending changes, the UPDATE/INSERT/DELETE
/// statements per dialect with their bound values and optimistic check, Run History's script,
/// and the generated PHP.
struct SQLTableEditsTests {
    typealias Edits = SQLTableEdits

    static let columns: [SQLSchemaInfo.Column] = [
        .init(name: "id", type: "integer", nullable: false, primaryKey: true),
        .init(name: "name", type: "varchar", nullable: false),
        .init(name: "price", type: "decimal"),
        .init(name: "weight", type: "double precision"),
        .init(name: "note", type: "text"),
    ]
    static let rows: [[SQLCell]] = [
        [.int(1), .string("Lamp"), .string("19.90"), .double(1.5), .null],
        [.int(2), .string("Desk"), .string("120.00"), .double(20.25), .string("oak")],
        [.int(3), .clipped("long…", omittedBytes: 100), .null, .null, .null],
    ]

    func table(_ columns: [SQLSchemaInfo.Column] = SQLTableEditsTests.columns, kind: String? = nil) -> SQLSchemaInfo.Table {
        SQLSchemaInfo.Table(name: "items", columns: columns, kind: kind)
    }

    func statements(_ changes: Edits.Changes, _ dialect: SQLTableBrowse.Dialect = .pgsql, columns: [SQLSchemaInfo.Column] = SQLTableEditsTests.columns, rows: [[SQLCell]] = SQLTableEditsTests.rows, offset: Int = 0) throws -> [Edits.Statement] {
        try Edits.statements(changes, table: "items", columns: columns, rows: rows, dialect: dialect, offset: offset).get()
    }

    func problem(_ changes: Edits.Changes, _ dialect: SQLTableBrowse.Dialect = .pgsql) -> String? {
        if case .failure(let problem) = Edits.statements(changes, table: "items", columns: Self.columns, rows: Self.rows, dialect: dialect) { return problem.description }
        return nil
    }

    // MARK: Who can edit

    @Test func onlyTablesWithAPrimaryKeyOnWritableBindingConnections() {
        #expect(Edits.refusal(table: table(), driver: "pgsql", source: nil, readOnlyConnection: nil) == nil)
        #expect(Edits.refusal(table: table(kind: "view"), driver: "pgsql", source: nil, readOnlyConnection: nil) == .view)
        let keyless = Self.columns.map { column -> SQLSchemaInfo.Column in var column = column; column.primaryKey = nil; return column }
        #expect(Edits.refusal(table: table(keyless), driver: "mysql", source: nil, readOnlyConnection: nil) == .noPrimaryKey)
        #expect(Edits.refusal(table: table(), driver: "pgsql", source: nil, readOnlyConnection: "Replica") == .readOnlyConnection("Replica"))
        #expect(Edits.refusal(table: table(), driver: nil, source: "WordPress $wpdb", readOnlyConnection: nil) == .callable("WordPress $wpdb"))
        #expect(Edits.refusal(table: table(), driver: "oci", source: nil, readOnlyConnection: nil) == .unknownDialect("oci"))
        let binaryKey = [SQLSchemaInfo.Column(name: "uuid", type: "binary", primaryKey: true)]
        #expect(Edits.refusal(table: table(binaryKey), driver: "mysql", source: nil, readOnlyConnection: nil) == .binaryPrimaryKey("uuid"))
        let wide = (1...201).map { SQLSchemaInfo.Column(name: "c\($0)", type: "int", primaryKey: $0 == 201) }
        #expect(Edits.refusal(table: table(wide), driver: "sqlite", source: nil, readOnlyConnection: nil) == .primaryKeyNotRead)
        #expect(Edits.Refusal.noPrimaryKey.description.contains("primary key"))
        #expect(Edits.Refusal.readOnlyConnection("Replica").description == "The saved connection “Replica” is read-only: Browse Table never edits through it.")
    }

    @Test func cellsRunletDidntReadInFullCantBeEdited() {
        let name = Self.columns[1]
        #expect(Edits.cellProblem(.clipped("x", omittedBytes: 10), column: name, dialect: .mysql)?.contains("8 KB") == true)
        #expect(Edits.cellProblem(.binary(bytes: 4, hexPrefix: "00FF00FF"), column: name, dialect: .mysql) != nil)
        #expect(Edits.cellProblem(.string("ok"), column: name, dialect: .mysql) == nil)
        #expect(Edits.cellProblem(.null, column: .init(name: "photo", type: "bytea"), dialect: .pgsql) == "photo holds binary values, which Runlet doesn't edit.")
    }

    @Test func valuesAreCheckedAgainstTheirColumn() {
        #expect(Edits.valueProblem(.null, column: Self.columns[1], dialect: .pgsql) == "name is NOT NULL, so it can't be set to NULL.")
        #expect(Edits.valueProblem(.null, column: Self.columns[2], dialect: .pgsql) == nil)
        #expect(Edits.valueProblem(.text("cheap"), column: Self.columns[2], dialect: .pgsql) == "“cheap” isn't a number: price is a decimal column.")
        #expect(Edits.valueProblem(.text("1.5"), column: Self.columns[0], dialect: .pgsql) == "“1.5” isn't a whole number: id is an integer column.")
        #expect(Edits.valueProblem(.text("NULL"), column: Self.columns[1], dialect: .pgsql) == nil, "the word NULL is text; NULL itself is explicit")
    }

    // MARK: Pending changes

    @Test func pendingChangesDropWhatGoesBackToTheOriginal() {
        var changes = Edits.Changes()
        #expect(changes.isEmpty)
        changes.set(row: 0, column: 1, to: .text("Lamp"), original: .string("Lamp"))
        #expect(changes.isEmpty, "the same value is no change")
        changes.set(row: 0, column: 1, to: .text("Lantern"), original: .string("Lamp"))
        changes.set(row: 0, column: 4, to: .text("brass"), original: .null)
        #expect(changes.value(row: 0, column: 1) == .text("Lantern"))
        #expect(changes.count == 1, "one row, one UPDATE")
        changes.set(row: 0, column: 1, to: .text("Lamp"), original: .string("Lamp"))
        #expect(changes.value(row: 0, column: 1) == nil)
        changes.revert(row: 0, column: 4)
        #expect(changes.isEmpty)
        changes.set(row: 1, column: 0, to: .text("2"), original: .int(2))
        #expect(changes.isEmpty, "an integer typed back as text")
        changes.set(row: 1, column: 4, to: .null, original: .string("oak"))
        changes.delete(rows: [1])
        #expect(changes.cells.isEmpty, "a deleted row's edits go")
        changes.addRow()
        changes.setNew(row: 0, column: 1, to: .text("Chair"))
        #expect(changes.count == 2)
        #expect(changes.summary == "1 new, 1 deleted")
        changes.restore(row: 1)
        changes.removeNewRow(0)
        #expect(changes.isEmpty)
    }

    // MARK: Statements

    @Test func anUpdateFindsItsRowByThePrimaryKeyAndTheValuesItChanges() throws {
        var changes = Edits.Changes()
        changes.set(row: 0, column: 1, to: .text("Lantern"), original: .string("Lamp"))
        changes.set(row: 0, column: 4, to: .text("brass"), original: .null)
        changes.set(row: 0, column: 3, to: .text("1.75"), original: .double(1.5))
        let update = try #require(try statements(changes).first)
        #expect(update.kind == .update)
        // `weight` is approximate: its original isn't compared; NULL is matched with IS NULL.
        #expect(update.sql == """
        UPDATE "items"
        SET "name" = ?, "weight" = ?, "note" = ?
        WHERE "id" = ? AND "name" = ? AND "note" IS NULL
        """)
        #expect(update.bindings.map(\.value) == [.text("Lantern"), .decimal("1.75"), .text("brass"), .integer(1), .text("Lamp")])
        #expect(update.bindings.map(\.target) == (1...5).map { .position($0) })
        #expect(update.label == "row 1 · id = 1")
        #expect(update.verifySQL == nil, "PostgreSQL counts the rows it matched")
        #expect(update.display.hasSuffix("\n-- ?1 = 'Lantern', ?2 = 1.75, ?3 = 'brass', ?4 = 1, ?5 = 'Lamp'"))
    }

    @Test func mysqlUpdatesCarryACountOfTheSameWhere() throws {
        var changes = Edits.Changes()
        changes.set(row: 1, column: 2, to: .text("99.50"), original: .string("120.00"))
        let update = try #require(try statements(changes, .mysql, offset: 100).first)
        #expect(update.sql == "UPDATE `items`\nSET `price` = ?\nWHERE `id` = ? AND `price` = ?")
        #expect(update.bindings.map(\.value) == [.decimal("99.50"), .integer(2), .decimal("120.00")])
        #expect(update.verifySQL == "SELECT COUNT(*) FROM `items`\nWHERE `id` = ? AND `price` = ?")
        #expect(update.verifyBindings == [SQLBinding(target: .position(1), value: .integer(2)), SQLBinding(target: .position(2), value: .decimal("120.00"))])
        #expect(update.label == "row 102 · id = 2", "labels count from the page's first row")
    }

    @Test func deletesThenUpdatesThenInsertsEachWithBoundValues() throws {
        var changes = Edits.Changes()
        changes.addRow()
        changes.setNew(row: 0, column: 1, to: .text("Chair"))
        changes.setNew(row: 0, column: 2, to: .null)
        changes.addRow()
        changes.set(row: 1, column: 1, to: .text("Table"), original: .string("Desk"))
        changes.delete(rows: [0])
        let all = try statements(changes, .sqlite)
        #expect(all.map(\.kind) == [.delete, .update, .insert, .insert])
        #expect(all[0].sql == "DELETE FROM \"items\"\nWHERE \"id\" = ?")
        #expect(all[0].bindings.map(\.value) == [.integer(1)])
        #expect(all[2].sql == "INSERT INTO \"items\" (\"name\", \"price\")\nVALUES (?, ?)")
        #expect(all[2].bindings.map(\.value) == [.text("Chair"), .null])
        #expect(all[2].label == "new row 1")
        #expect(all[3].sql == "INSERT INTO \"items\" DEFAULT VALUES", "every column takes its default")
        let mysql = try statements(changes, .mysql)
        #expect(mysql[3].sql == "INSERT INTO `items` () VALUES ()")
        let sqlServer = try statements(changes, .sqlServer)
        #expect(sqlServer[0].sql == "DELETE FROM [items]\nWHERE [id] = ?")
    }

    @Test func compositeKeysFindTheRowByEveryColumn() throws {
        let columns: [SQLSchemaInfo.Column] = [.init(name: "order_id", type: "int", primaryKey: true), .init(name: "line", type: "int", primaryKey: true), .init(name: "qty", type: "int")]
        var changes = Edits.Changes()
        changes.set(row: 0, column: 2, to: .text("5"), original: .string("4"))
        let update = try #require(try statements(changes, .mysql, columns: columns, rows: [[.string("7"), .string("2"), .string("4")]]).first)
        #expect(update.sql == "UPDATE `items`\nSET `qty` = ?\nWHERE `order_id` = ? AND `line` = ? AND `qty` = ?")
        #expect(update.bindings.map(\.value) == [.integer(5), .integer(7), .integer(2), .integer(4)], "integers read as text bind as integers")
        #expect(update.label == "row 1 · order_id = 7, line = 2")
    }

    @Test func valuesThatDontFitOrRowsRunletCantFindAreRefused() {
        var notNull = Edits.Changes()
        notNull.set(row: 0, column: 1, to: .null, original: .string("Lamp"))
        #expect(problem(notNull) == "Row 1 · id = 1: name is NOT NULL, so it can't be set to NULL.")
        var number = Edits.Changes()
        number.addRow()
        number.setNew(row: 0, column: 2, to: .text("cheap"))
        #expect(problem(number) == "New row 1: “cheap” isn't a number: price is a decimal column.")
        let keyless = Self.columns.map { column -> SQLSchemaInfo.Column in var column = column; column.primaryKey = nil; return column }
        var any = Edits.Changes()
        any.delete(rows: [0])
        if case .failure(let refused) = Edits.statements(any, table: "items", columns: keyless, rows: Self.rows, dialect: .sqlite) {
            #expect(refused.description.contains("no primary key"))
        } else {
            Issue.record("a table without a primary key has no statements")
        }
        var clippedKey = Edits.Changes()
        clippedKey.delete(rows: [0])
        let clipped = Edits.statements(clippedKey, table: "items", columns: Self.columns, rows: [[.clipped("1…", omittedBytes: 9), .null, .null, .null, .null]], dialect: .pgsql)
        if case .failure(let refused) = clipped {
            #expect(refused.description == "Row 1's id isn't a value Runlet read in full, so Runlet can't find the row by it.")
        } else {
            Issue.record("a clipped primary key can't find its row")
        }
    }

    // MARK: History and PHP

    @Test func historyKeepsOneScriptWithEachStatementsValues() throws {
        var changes = Edits.Changes()
        changes.set(row: 0, column: 1, to: .text("Lantern"), original: .string("Lamp"))
        changes.delete(rows: [1])
        let code = Edits.historyCode(try statements(changes), table: "items")
        #expect(code == """
        -- Browse Table: 2 changes to items, applied in one transaction
        -- @param ?1 integer 2
        DELETE FROM "items"
        WHERE "id" = ?;
        -- @param ?1 text Lantern
        -- @param ?2 integer 1
        -- @param ?3 text Lamp
        UPDATE "items"
        SET "name" = ?
        WHERE "id" = ? AND "name" = ?;
        """)
    }

    @Test func applyCodeSendsEachStatementWithItsValuesAndCheck() throws {
        var changes = Edits.Changes()
        changes.set(row: 0, column: 1, to: .text("O'Neil"), original: .string("Lamp"))
        let code = SQLTabRun.applyCode(try statements(changes, .mysql), connection: nil, driver: "mysql")
        #expect(code.contains("return \\RunletRunner\\SqlTab::applyEdits(["))
        #expect(code.contains("['kind' => 'update', 'sql' => \"UPDATE `items`\\nSET `name` = ?\\nWHERE `id` = ? AND `name` = ?\", 'line' => 1, 'label' => \"row 1 · id = 1\", 'params' => [['position' => 1, 'type' => 'str', 'value' => 'O\\'Neil'], ['position' => 2, 'type' => 'int', 'value' => 1], ['position' => 3, 'type' => 'str', 'value' => 'Lamp']], 'verify' => \"SELECT COUNT(*) FROM `items`\\nWHERE `id` = ? AND `name` = ?\", 'verifyParams' => [['position' => 1, 'type' => 'int', 'value' => 1], ['position' => 2, 'type' => 'str', 'value' => 'Lamp']]],"))
        #expect(code.hasSuffix("], null, \"mysql\");"))
    }
}
