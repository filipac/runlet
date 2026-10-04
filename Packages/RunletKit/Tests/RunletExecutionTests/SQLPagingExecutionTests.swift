import Foundation
@testable import RunletCore
import Testing
@testable import RunletExecution

/// Load Next (#146) through the runner, with host PHP and SQLite: pages that the database skips
/// (a `LIMIT … OFFSET …` added to the statement) and pages the runner skips (a statement with
/// its own LIMIT, a callable connection), appended until the end with the same columns; bound
/// values bound again for each page; a read-only saved connection; and the runner's refusals.
@Suite(.serialized, .enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct SQLPagingExecutionTests {
    /// The ledger project with `readings`: 2,500 rows, `id` 1…2,500.
    func project() throws -> URL {
        let directory = try SQLScriptExecutionTests().project()
        let php = Process()
        php.executableURL = URL(fileURLWithPath: DriverSupport.php)
        php.arguments = ["-r", """
            $p = new PDO('sqlite:' . $argv[1]);
            $p->exec('CREATE TABLE readings (id INTEGER PRIMARY KEY, sensor TEXT NOT NULL, value REAL NOT NULL)');
            $p->beginTransaction();
            $s = $p->prepare('INSERT INTO readings (id, sensor, value) VALUES (?, ?, ?)');
            for ($i = 1; $i <= 2500; $i++) { $s->execute([$i, 'sensor-' . ($i % 7), $i / 4]); }
            $p->commit();
            """, directory.appendingPathComponent("ledger.sqlite").path]
        try php.run()
        php.waitUntilExit()
        return directory
    }

    func first(_ statement: String, connection: String? = nil, bindings: [SQLBinding] = [], maxRows: Int = 1000, in directory: URL) async throws -> SQLResultInfo {
        let events = try await TestSupport.run(SQLTabRun.code(statement: statement, connection: connection, maxRows: maxRows, bindings: bindings), target: DriverSupport.target(directory.path), magicComments: false)
        #expect(events.errors.isEmpty, "\(events.errors)")
        return try #require(events.sqlResult)
    }

    func page(_ page: SQLPaging.Page, connection: String? = nil, bindings: [SQLBinding] = [], in directory: URL) async throws -> [RunEvent] {
        try await TestSupport.run(SQLTabRun.pageCode(page, connection: connection, bindings: bindings), target: DriverSupport.target(directory.path), magicComments: false)
    }

    /// Loads pages until the result says there are no more, as the result card's Load Next does.
    func loadAll(_ statement: String, connection: String? = nil, bindings: [SQLBinding] = [], size: Int = 1000, in directory: URL) async throws -> (SQLResultInfo, SQLPaging.Plan) {
        var result = try await first(statement, connection: connection, bindings: bindings, maxRows: size, in: directory)
        let plan = try SQLPaging.plan(for: statement, driver: result.driver).get()
        var pages = 0
        while result.truncated == true, pages < 10 {
            let events = try await page(plan.page(offset: result.rows.count, size: size), connection: connection, bindings: bindings, in: directory)
            #expect(events.errors.isEmpty, "\(events.errors)")
            let next = try #require(events.sqlResult)
            result = try #require(result.appending(next), "same columns")
            pages += 1
        }
        return (result, plan)
    }

    @Test func pagesTheDatabaseSkipsAppendToTheEnd() async throws {
        let directory = try project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await first("SELECT id, sensor, value FROM readings ORDER BY id DESC", in: directory)
        #expect(first.rows.count == 1000)
        #expect(first.truncated == true)
        #expect(first.bytes ?? 0 > 0)
        let plan = try SQLPaging.plan(for: "SELECT id, sensor, value FROM readings ORDER BY id DESC", driver: first.driver).get()
        #expect(plan.mode == .append)
        let second = try await page(plan.page(offset: 1000, size: 1000), in: directory)
        #expect(second.errors.isEmpty, "\(second.errors)")
        let rows = try #require(second.sqlResult)
        #expect(rows.columns == ["id", "sensor", "value"])
        #expect(rows.rows.count == 1000)
        #expect(rows.rows.first?.first == .int(1500))
        #expect(rows.truncated == true, "row 2,001 exists")
        #expect(rows.truncation == "rows")
        #expect(rows.maxRows == 1000)

        let (all, _) = try await loadAll("SELECT id, sensor, value FROM readings ORDER BY id DESC", in: directory)
        #expect(all.rows.count == 2500)
        #expect(all.rows.map(\.first) == (1...2500).reversed().map { SQLCell.int(Int64($0)) })
        #expect(all.truncated == nil, "the last page ends the result")
        #expect(all.pages == 3)
        #expect(all.table.rowKeys.last == "2500")
    }

    @Test func pagesOfAStatementWithItsOwnLimitAreSkippedByTheRunner() async throws {
        let directory = try project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (all, plan) = try await loadAll("SELECT id FROM readings ORDER BY id LIMIT 2200", in: directory)
        #expect(plan.mode == .skip)
        #expect(all.rows.count == 2200)
        #expect(all.rows.map(\.first) == (1...2200).map { SQLCell.int(Int64($0)) })
        #expect(all.truncated == nil)
    }

    @Test func boundValuesAreBoundAgainForEachPage() async throws {
        let directory = try project()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 2,500 / 7 ≈ 357 rows of sensor-3; pages of 100.
        let statement = "SELECT id, sensor FROM readings WHERE sensor = :sensor AND id > :min ORDER BY id"
        let named = [SQLBinding(target: .name("sensor"), value: .text("sensor-3")), SQLBinding(target: .name("min"), value: .integer(10))]
        let (all, plan) = try await loadAll(statement, bindings: named, size: 100, in: directory)
        #expect(plan.mode == .append)
        let expected = (11...2500).filter { $0 % 7 == 3 }
        #expect(all.rows.count == expected.count)
        #expect(all.rows.map(\.first) == expected.map { SQLCell.int(Int64($0)) })
        #expect(all.rows.allSatisfy { $0[1] == .string("sensor-3") })
        // Positional placeholders keep their positions: the added clause has none.
        let (positional, _) = try await loadAll("SELECT id FROM readings WHERE id > ? AND id <= ? ORDER BY id", bindings: [SQLBinding(target: .position(1), value: .integer(100)), SQLBinding(target: .position(2), value: .integer(450))], size: 100, in: directory)
        #expect(positional.rows.map(\.first) == (101...450).map { SQLCell.int(Int64($0)) })
    }

    @Test func callableConnectionsAreSkippedByTheRunner() async throws {
        let directory = try project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (all, plan) = try await loadAll("SELECT id FROM readings ORDER BY id", connection: "callable", in: directory)
        #expect(plan.mode == .skip, "a callable's dialect is unknown")
        #expect(all.rows.count == 2500)
        #expect(all.rows.last?.first == .int(2500))
    }

    @Test func aPageOnAnotherDriverOrARefusedLimitFailsWithAHint() async throws {
        let directory = try project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pgsql = try SQLPaging.plan(for: "SELECT id FROM readings ORDER BY id", driver: "pgsql").get().page(offset: 1000, size: 1000)
        let other = try await page(pgsql, in: directory)
        #expect(other.sqlResult == nil)
        #expect(other.errors.first?.className == "RunletRunner\\SqlPageFailed")
        #expect(other.errors.first?.message == "The connection is a sqlite connection now, and Load Next wrote the next page for pgsql. Run the statement again.")
        // A limit the tokenizer missed: the database refuses the second LIMIT, and the error says what Runlet added.
        let refused = SQLPaging.Page(sql: "SELECT id FROM readings LIMIT 5\nLIMIT 1001 OFFSET 1000", offset: 1000, size: 1000, skip: 0, driver: "sqlite", added: "LIMIT 1001 OFFSET 1000")
        let failed = try await page(refused, in: directory)
        let error = try #require(failed.errors.first)
        #expect(error.className == "RunletRunner\\SqlPageFailed")
        #expect(error.message.hasSuffix("Load Next added “LIMIT 1001 OFFSET 1000” to the end of the statement. If the database can't take that, add LIMIT and OFFSET to the statement yourself."), "\(error.message)")
    }

    @Test func readOnlySavedConnectionsPageReadsAndRefuseWrites() async throws {
        let directory = try SQLSavedConnectionTests.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = SQLReadOnlyConnectionTests.readOnly()
        let plan = try SQLPaging.plan(for: "SELECT email FROM customers ORDER BY id", driver: "sqlite").get()
        let events = try await SQLSavedConnectionTests.run(SQLTabRun.pageCode(plan.page(offset: 1, size: 1), connection: nil), connection: connection, in: directory)
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.sqlResult?.rows == [[.string("b@example.test")]])
        #expect(events.sqlResult?.truncated == nil)
        #expect(events.sqlResult?.saved == true)
        // The runner's own read-only check, should a write reach it.
        let write = SQLPaging.Page(sql: "DELETE FROM customers RETURNING id", offset: 1, size: 1, skip: 1, driver: nil, added: nil)
        let refused = try await SQLSavedConnectionTests.run(SQLTabRun.pageCode(write, connection: nil), connection: connection, in: directory)
        #expect(refused.errors.first?.className == "RunletRunner\\SqlReadOnlyRefused")
        #expect(try SQLReadOnlyConnectionTests.count(in: directory) == "2")
    }

    @Test(.enabled(if: TestSupport.herdPHP74 != nil, "requires PHP 7.4"))
    func pagesRunOnPHP74() async throws {
        let php74 = try #require(TestSupport.herdPHP74)
        let directory = try project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let plan = try SQLPaging.plan(for: "SELECT id FROM readings ORDER BY id", driver: "sqlite").get()
        let events = try await TestSupport.run(SQLTabRun.pageCode(plan.page(offset: 2400, size: 1000), connection: nil), target: DriverSupport.target(directory.path, php: php74), magicComments: false)
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.sqlResult?.rows.count == 100)
        #expect(events.sqlResult?.rows.first?.first?.text == "2401", "PHP 7.4 reads SQLite integers as text")
    }
}
