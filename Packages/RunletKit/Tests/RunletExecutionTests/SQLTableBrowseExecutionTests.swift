import Foundation
@testable import RunletCore
import Testing
@testable import RunletExecution

/// Browse Table (#151) through the runner, with host PHP and SQLite: pages read on the server
/// (paging, sort, filters with bound values), reviewed changes applied in one transaction with
/// the exactly-one-row check, rollbacks when a row was changed or deleted in the meantime or a
/// change fails, and the runner's own refusals (other statements, a callable connection, a
/// read-only saved connection).
@Suite(.serialized, .enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct SQLTableBrowseExecutionTests {
    static let columns: [SQLSchemaInfo.Column] = [
        .init(name: "id", type: "INTEGER", nullable: false, primaryKey: true),
        .init(name: "name", type: "TEXT", nullable: false),
        .init(name: "price", type: "NUMERIC"),
        .init(name: "note", type: "TEXT"),
    ]

    /// The ledger project with `p151_items`: 250 rows, `id` 1…250, `name` "Item 001"…, `price`
    /// id / 4, `note` NULL for every tenth row.
    func project() throws -> URL {
        let directory = try SQLScriptExecutionTests().project()
        try sqlite(directory, """
            $p->exec('CREATE TABLE p151_items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, price NUMERIC, note TEXT)');
            $p->beginTransaction();
            $s = $p->prepare('INSERT INTO p151_items (id, name, price, note) VALUES (?, ?, ?, ?)');
            for ($i = 1; $i <= 250; $i++) { $s->execute([$i, sprintf('Item %03d', $i), $i / 4, $i % 10 === 0 ? null : 'note ' . $i]); }
            $p->commit();
            """)
        return directory
    }

    /// Runs PHP with `$p`, a PDO on the project's ledger, and returns what it prints.
    @discardableResult
    func sqlite(_ directory: URL, _ code: String) throws -> String {
        let php = Process()
        let output = Pipe()
        php.executableURL = URL(fileURLWithPath: DriverSupport.php)
        php.arguments = ["-r", "$p = new PDO('sqlite:' . $argv[1]); $p->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION); " + code, directory.appendingPathComponent("ledger.sqlite").path]
        php.standardOutput = output
        try php.run()
        php.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func request(sort: SQLTableBrowse.Sort? = nil, filters: [SQLTableBrowse.Filter] = [], offset: Int = 0, pageSize: Int = 100, binds: Bool = true) -> SQLTableBrowse.Request {
        SQLTableBrowse.Request(table: "p151_items", columns: Self.columns, dialect: .sqlite, sort: sort, filters: filters, offset: offset, pageSize: pageSize, bindsValues: binds)
    }

    func browse(_ request: SQLTableBrowse.Request, connection: String? = nil, driver: String? = "sqlite", in directory: URL) async throws -> [RunEvent] {
        let query = try SQLTableBrowse.query(request).get()
        return try await TestSupport.run(SQLTabRun.browseCode(query, connection: connection, driver: driver), target: DriverSupport.target(directory.path), magicComments: false)
    }

    func page(_ request: SQLTableBrowse.Request, in directory: URL) async throws -> SQLResultInfo {
        let events = try await browse(request, in: directory)
        #expect(events.errors.isEmpty, "\(events.errors)")
        return try #require(events.sqlResult)
    }

    func apply(_ statements: [SQLTableEdits.Statement], connection: String? = nil, in directory: URL) async throws -> [RunEvent] {
        try await TestSupport.run(SQLTabRun.applyCode(statements, connection: connection, driver: "sqlite"), target: DriverSupport.target(directory.path), magicComments: false)
    }

    func statements(_ changes: SQLTableEdits.Changes, page: SQLResultInfo, offset: Int = 0) throws -> [SQLTableEdits.Statement] {
        try SQLTableEdits.statements(changes, table: "p151_items", columns: Self.columns, rows: page.rows, dialect: .sqlite, offset: offset).get()
    }

    // MARK: Browsing

    @Test func pagesComeFromTheServerWithOneRowMoreToTellWhetherMoreFollow() async throws {
        let directory = try project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await page(request(), in: directory)
        #expect(first.columns == ["id", "name", "price", "note"])
        #expect(first.rows.count == 100)
        #expect(first.truncated == true, "row 101 exists")
        #expect(first.rows.first?.first == .int(1))
        #expect(first.maxRows == 100)
        #expect(first.source == "LedgerDriver::sqlConnection()")
        let last = try await page(request(offset: 200), in: directory)
        #expect(last.rows.count == 50)
        #expect(last.truncated == nil, "the last page")
        #expect(last.rows.map(\.first) == (201...250).map { SQLCell.int(Int64($0)) })
    }

    @Test func sortAndFiltersRunOnTheServerWithBoundValues() async throws {
        let directory = try project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sorted = try await page(request(sort: .init(column: "price", ascending: false), pageSize: 3), in: directory)
        #expect(sorted.rows.map(\.first) == [.int(250), .int(249), .int(248)])
        let filtered = try await page(request(filters: [
            .init(column: "name", op: .contains, value: "item 1"),
            .init(column: "price", op: .greaterOrEqual, value: "30"),
            .init(column: "note", op: .isEmpty),
        ]), in: directory)
        // "Item 1xx" (LIKE ignores ASCII case), price ≥ 30 (id ≥ 120), note NULL (every tenth).
        #expect(filtered.rows.map(\.first) == [120, 130, 140, 150, 160, 170, 180, 190].map { SQLCell.int(Int64($0)) })
        // A value that would break SQL written by hand is only data.
        let quoted = try await page(request(filters: [.init(column: "name", op: .equals, value: "x' OR '1'='1")]), in: directory)
        #expect(quoted.rows.isEmpty)
        // LIKE's wildcards are literal in "contains".
        let wildcard = try await page(request(filters: [.init(column: "name", op: .contains, value: "%")]), in: directory)
        #expect(wildcard.rows.isEmpty)
        let count = try sqlite(directory, "echo $p->query('SELECT COUNT(*) FROM p151_items')->fetchColumn();")
        #expect(count == "250", "browsing changed nothing")
    }

    @Test func theRunnerRefusesAnythingButASelectWrittenForItsDialect() async throws {
        let directory = try project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let query = SQLTableBrowse.Query(sql: "DELETE FROM p151_items", bindings: [], pageSize: 10, offset: 0, ordered: false)
        let refused = try await TestSupport.run(SQLTabRun.browseCode(query, connection: nil, driver: "sqlite"), target: DriverSupport.target(directory.path), magicComments: false)
        #expect(refused.errors.first?.className == "RunletRunner\\SqlTableRefused")
        let writing = SQLTableBrowse.Query(sql: "SELECT * INTO copy FROM p151_items", bindings: [], pageSize: 10, offset: 0, ordered: false)
        let alsoRefused = try await TestSupport.run(SQLTabRun.browseCode(writing, connection: nil, driver: "sqlite"), target: DriverSupport.target(directory.path), magicComments: false)
        #expect(alsoRefused.errors.first?.className == "RunletRunner\\SqlTableRefused")
        let otherDialect = try await browse(request(), driver: "pgsql", in: directory)
        #expect(otherDialect.errors.first?.className == "RunletRunner\\SqlTableRefused")
        #expect(otherDialect.errors.first?.message == "The connection is a sqlite connection now, and Browse Table wrote its SQL for pgsql. Load the schema again and browse the table again. Nothing ran.")
        #expect(try sqlite(directory, "echo $p->query('SELECT COUNT(*) FROM p151_items')->fetchColumn();") == "250")
    }

    @Test func callableConnectionsBrowseWithoutBoundValues() async throws {
        let directory = try project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rows = try await browse(request(sort: .init(column: "id", ascending: false), filters: [.init(column: "note", op: .isNotEmpty)], pageSize: 5, binds: false), connection: "callable", driver: nil, in: directory)
        #expect(rows.errors.isEmpty, "\(rows.errors)")
        #expect(rows.sqlResult?.rows.map { $0[0].text } == ["249", "248", "247", "246", "245"])
        #expect(rows.sqlResult?.truncated == true)
        // Should a value reach the runner, the callable can't bind it.
        let valued = try SQLTableBrowse.query(request(filters: [.init(column: "name", op: .equals, value: "Item 001")])).get()
        let refused = try await TestSupport.run(SQLTabRun.browseCode(valued, connection: "callable", driver: nil), target: DriverSupport.target(directory.path), magicComments: false)
        #expect(refused.errors.first?.className == "RunletRunner\\SqlParametersRefused")
    }

    // MARK: Applying

    @Test func reviewedChangesApplyInOneTransactionAndEachAffectsOneRow() async throws {
        let directory = try project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await page(request(pageSize: 10), in: directory)
        var changes = SQLTableEdits.Changes()
        changes.set(row: 0, column: 1, to: .text("Lamp"), original: first.rows[0][1])
        changes.set(row: 0, column: 3, to: .null, original: first.rows[0][3])
        changes.set(row: 1, column: 2, to: .text("9.99"), original: first.rows[1][2])
        changes.delete(rows: [2])
        changes.addRow()
        changes.setNew(row: 0, column: 1, to: .text("Chair"))
        changes.setNew(row: 0, column: 2, to: .text("45.5"))
        let events = try await apply(try statements(changes, page: first), in: directory)
        #expect(events.errors.isEmpty, "\(events.errors)")
        let results = events.sqlResults
        #expect(results.map(\.affectedRows) == [1, 1, 1, 1])
        #expect(results.map(\.statement?.index) == [1, 2, 3, 4])
        #expect(results.first?.statement?.text == "DELETE FROM \"p151_items\"\nWHERE \"id\" = ?")
        #expect(results.first?.source == "LedgerDriver::sqlConnection()")
        #expect(events.sqlNotices == ["Committed the transaction: all 4 changes affected exactly one row each."])
        let rows = try sqlite(directory, "foreach ($p->query('SELECT id, name, price, note FROM p151_items WHERE id IN (1, 2, 3) OR id > 250 ORDER BY id')->fetchAll(PDO::FETCH_NUM) as $r) { echo implode('|', array_map('strval', $r)), \"\\n\"; }")
        #expect(rows == "1|Lamp|0.25|\n2|Item 002|9.99|note 2\n251|Chair|45.5|")
        // The page read again shows them.
        let again = try await page(request(pageSize: 3), in: directory)
        #expect(again.rows.map { $0[1].text } == ["Lamp", "Item 002", "Item 004"])
    }

    @Test func aRowChangedByAnotherSessionRollsEverythingBack() async throws {
        let directory = try project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await page(request(pageSize: 10), in: directory)
        var changes = SQLTableEdits.Changes()
        changes.delete(rows: [5])
        changes.set(row: 0, column: 1, to: .text("Lamp"), original: first.rows[0][1])
        // Someone renames row 1 after the page was read.
        try sqlite(directory, "$p->exec(\"UPDATE p151_items SET name = 'Renamed' WHERE id = 1\");")
        let events = try await apply(try statements(changes, page: first), in: directory)
        let error = try #require(events.errors.first)
        #expect(error.className == "RunletRunner\\SqlEditsFailed")
        #expect(error.message == "Change 2 of 2 (row 1 · id = 1): row not found: it was changed or deleted by someone else since the page was read (Runlet looks it up by its primary key and the values you changed).\n\nRolled back the transaction: nothing was changed.")
        #expect(events.sqlResults.isEmpty, "nothing is reported as applied")
        #expect(try sqlite(directory, "echo $p->query('SELECT COUNT(*) FROM p151_items WHERE id = 6')->fetchColumn();") == "1", "the DELETE before it was rolled back")
        #expect(try sqlite(directory, "echo $p->query('SELECT name FROM p151_items WHERE id = 1')->fetchColumn();") == "Renamed")
    }

    @Test func aRowDeletedByAnotherSessionRollsBack() async throws {
        let directory = try project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await page(request(pageSize: 10), in: directory)
        var changes = SQLTableEdits.Changes()
        changes.delete(rows: [3])
        try sqlite(directory, "$p->exec('DELETE FROM p151_items WHERE id = 4');")
        let events = try await apply(try statements(changes, page: first), in: directory)
        #expect(events.errors.first?.message.hasPrefix("Change 1 of 1 (row 4 · id = 4): row not found: it was changed or deleted by someone else since the page was read (Runlet looks it up by its primary key).") == true, "\(events.errors)")
    }

    @Test func aFailingChangeRollsBackWithTheDatabasesMessage() async throws {
        let directory = try project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await page(request(pageSize: 10), in: directory)
        var changes = SQLTableEdits.Changes()
        changes.set(row: 0, column: 1, to: .text("Lamp"), original: first.rows[0][1])
        // A duplicate primary key: the database refuses the INSERT.
        var duplicate = try statements(changes, page: first)
        duplicate.append(SQLTableEdits.Statement(kind: .insert, sql: "INSERT INTO \"p151_items\" (\"id\", \"name\")\nVALUES (?, ?)", bindings: [SQLBinding(target: .position(1), value: .integer(2)), SQLBinding(target: .position(2), value: .text("Twin"))], verifySQL: nil, verifyBindings: [], label: "new row 1"))
        let events = try await apply(duplicate, in: directory)
        let error = try #require(events.errors.first)
        #expect(error.className == "RunletRunner\\SqlEditsFailed")
        #expect(error.message.hasPrefix("Change 2 of 2 (new row 1): "), "\(error.message)")
        #expect(error.message.contains("UNIQUE constraint failed"), "\(error.message)")
        #expect(error.message.hasSuffix("Rolled back the transaction: nothing was changed."))
        #expect(try sqlite(directory, "echo $p->query('SELECT name FROM p151_items WHERE id = 1')->fetchColumn();") == "Item 001")
    }

    @Test func theRunnerRefusesStatementsOfAnotherKindAndCallableConnections() async throws {
        let directory = try project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disguised = SQLTableEdits.Statement(kind: .update, sql: "DELETE FROM p151_items", bindings: [], verifySQL: nil, verifyBindings: [], label: "row 1")
        let refused = try await apply([disguised], in: directory)
        #expect(refused.errors.first?.className == "RunletRunner\\SqlTableRefused")
        #expect(refused.errors.first?.message == "Change 1 isn't an UPDATE, INSERT, or DELETE that Review Changes wrote. Nothing ran.")
        let delete = SQLTableEdits.Statement(kind: .delete, sql: "DELETE FROM \"p151_items\"\nWHERE \"id\" = ?", bindings: [SQLBinding(target: .position(1), value: .integer(1))], verifySQL: nil, verifyBindings: [], label: "row 1")
        let callable = try await apply([delete], connection: "callable", in: directory)
        #expect(callable.errors.first?.className == "RunletRunner\\SqlTableRefused")
        #expect(callable.errors.first?.message.contains("runs statements through a callable") == true)
        #expect(try sqlite(directory, "echo $p->query('SELECT COUNT(*) FROM p151_items')->fetchColumn();") == "250")
    }

    @Test func readOnlySavedConnectionsBrowseAndNeverApply() async throws {
        let directory = try SQLSavedConnectionTests.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = SQLReadOnlyConnectionTests.readOnly()
        let customers: [SQLSchemaInfo.Column] = [.init(name: "id", type: "INTEGER", primaryKey: true), .init(name: "email", type: "TEXT")]
        let query = try SQLTableBrowse.query(SQLTableBrowse.Request(table: "customers", columns: customers, dialect: .sqlite, filters: [.init(column: "email", op: .contains, value: "b@")])).get()
        let browsed = try await SQLSavedConnectionTests.run(SQLTabRun.browseCode(query, connection: nil, driver: "sqlite"), connection: connection, in: directory)
        #expect(browsed.errors.isEmpty, "\(browsed.errors)")
        #expect(browsed.sqlResult?.rows == [[.int(2), .string("b@example.test")]])
        #expect(browsed.sqlResult?.saved == true)
        let delete = SQLTableEdits.Statement(kind: .delete, sql: "DELETE FROM \"customers\"\nWHERE \"id\" = ?", bindings: [SQLBinding(target: .position(1), value: .integer(2))], verifySQL: nil, verifyBindings: [], label: "row 2")
        let refused = try await SQLSavedConnectionTests.run(SQLTabRun.applyCode([delete], connection: nil, driver: "sqlite"), connection: connection, in: directory)
        #expect(refused.errors.first?.className == "RunletRunner\\SqlReadOnlyRefused", "\(refused.errors)")
        let check = try await SQLSavedConnectionTests.run(SQLTabRun.code(statement: "SELECT COUNT(*) FROM customers", connection: nil), connection: connection, in: directory)
        #expect(check.sqlResult?.rows.first?.first == .int(2))
    }
}
