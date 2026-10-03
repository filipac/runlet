import Foundation
@testable import RunletCore
import Testing
@testable import RunletExecution

/// Load Next (#146) against live MariaDB 11 and PostgreSQL 14 (the throwaway fixture containers
/// of `scripts/setup-fixtures.sh databases`, through `RUNLET_TEST_MYSQL` / `RUNLET_TEST_PGSQL`):
/// ORDER BY results across pages (MariaDB would drop a derived table's ORDER BY, which is why
/// Runlet adds the limit to the statement instead), a CTE and a join with two `id` columns,
/// bound values on every page, a statement with its own LIMIT, and a read-only saved
/// connection. The tests use their own `p146_` table, created on each run.
@Suite(.serialized, .enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct SQLPagingLiveTests {
    typealias Server = SQLLiveDatabaseTests.Server

    /// `p146_readings`: 2,500 rows, `id` 1…2,500, sensor `s0`…`s6` (`id % 7`).
    static func setup(_ server: Server) throws {
        _ = try server.exec("DROP TABLE IF EXISTS p146_readings")
        if server.dialect == "mysql" {
            _ = try server.exec("CREATE TABLE p146_readings (id INT PRIMARY KEY, sensor VARCHAR(10) NOT NULL, celsius DECIMAL(6,2) NOT NULL) ENGINE=InnoDB")
            _ = try server.exec("INSERT INTO p146_readings (id, sensor, celsius) SELECT seq, CONCAT('s', seq % 7), seq / 4 FROM seq_1_to_2500")
        } else {
            _ = try server.exec("CREATE TABLE p146_readings (id INT PRIMARY KEY, sensor VARCHAR(10) NOT NULL, celsius NUMERIC(6,2) NOT NULL)")
            _ = try server.exec("INSERT INTO p146_readings (id, sensor, celsius) SELECT i, 's' || (i % 7), i / 4.0 FROM generate_series(1, 2500) AS i")
        }
        #expect(try server.exec("SELECT COUNT(*) FROM p146_readings") == "2500")
    }

    /// The first run, then Load Next until the end, as the result card does.
    func loadAll(_ server: Server, _ statement: String, bindings: [SQLBinding] = [], size: Int = 1000, saved: DatabaseConnection? = nil, in directory: URL) async throws -> (SQLResultInfo, SQLPaging.Plan) {
        func run(_ code: String) async throws -> [RunEvent] {
            if let saved { return try await SQLSavedConnectionTests.run(code, connection: saved, in: directory, password: server.password) }
            return try await TestSupport.run(code, target: DriverSupport.target(directory.path), magicComments: false)
        }
        let first = try await run(SQLTabRun.code(statement: statement, connection: nil, maxRows: size, bindings: bindings))
        #expect(first.errors.isEmpty, "\(server.dialect): \(first.errors)")
        var result = try #require(first.sqlResult)
        #expect(result.driver == server.dialect)
        let plan = try SQLPaging.plan(for: statement, driver: result.driver).get()
        var pages = 0
        while result.truncated == true, pages < 10 {
            let events = try await run(SQLTabRun.pageCode(plan.page(offset: result.rows.count, size: size), connection: nil, bindings: bindings))
            #expect(events.errors.isEmpty, "\(server.dialect): \(events.errors)")
            let next = try #require(events.sqlResult)
            result = try #require(result.appending(next), "\(server.dialect): same columns")
            pages += 1
        }
        return (result, plan)
    }

    @Test(.enabled(if: !SQLLiveDatabaseTests.servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func orderedResultsPageInOrderToTheEnd() async throws {
        for server in SQLLiveDatabaseTests.servers {
            try Self.setup(server)
            let directory = try server.project()
            defer { try? FileManager.default.removeItem(at: directory) }
            let (all, plan) = try await loadAll(server, "SELECT id, sensor, celsius FROM p146_readings ORDER BY id DESC", in: directory)
            #expect(plan.mode == .append, "\(server.dialect)")
            #expect(all.columns == ["id", "sensor", "celsius"])
            #expect(all.rows.count == 2500, "\(server.dialect)")
            let expected: [String] = (1...2500).reversed().map { String($0) }
            #expect(all.rows.map { $0[0].text } == expected, "\(server.dialect): every row once, in order")
            #expect(all.truncated == nil)
            #expect(all.pages == 3)
        }
    }

    @Test(.enabled(if: !SQLLiveDatabaseTests.servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func ctesAndJoinsWithTwoColumnsOfOneNamePage() async throws {
        for server in SQLLiveDatabaseTests.servers {
            try Self.setup(server)
            let directory = try server.project()
            defer { try? FileManager.default.removeItem(at: directory) }
            let (cte, _) = try await loadAll(server, "WITH warm AS (SELECT id, celsius FROM p146_readings WHERE celsius >= 100) SELECT id FROM warm ORDER BY celsius, id", size: 500, in: directory)
            let warm: [String] = (400...2500).map { String($0) }
            #expect(cte.rows.map { $0[0].text } == warm, "\(server.dialect)")
            // A derived table would refuse (MySQL) or rename (SQLite) the second `id`.
            let (join, _) = try await loadAll(server, "SELECT a.id, b.id FROM p146_readings a JOIN p146_readings b ON b.id = a.id + 1 ORDER BY a.id", size: 1000, in: directory)
            #expect(join.columns == ["id", "id"], "\(server.dialect)")
            #expect(join.rows.count == 2499, "\(server.dialect)")
            #expect(join.rows.last.map { $0.map(\.text) } == ["2499", "2500"], "\(server.dialect)")
        }
    }

    @Test(.enabled(if: !SQLLiveDatabaseTests.servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func boundValuesAndAStatementsOwnLimitPage() async throws {
        for server in SQLLiveDatabaseTests.servers {
            try Self.setup(server)
            let directory = try server.project()
            defer { try? FileManager.default.removeItem(at: directory) }
            let cast = server.dialect == "pgsql" ? "CAST(:min AS integer)" : ":min"
            let bindings = [SQLBinding(target: .name("sensor"), value: .text("s3")), SQLBinding(target: .name("min"), value: .integer(100))]
            let (bound, _) = try await loadAll(server, "SELECT id FROM p146_readings WHERE sensor = :sensor AND id > \(cast) ORDER BY id", bindings: bindings, size: 100, in: directory)
            let s3: [String] = (101...2500).filter { $0 % 7 == 3 }.map { String($0) }
            #expect(bound.rows.map { $0[0].text } == s3, "\(server.dialect)")
            let (limited, plan) = try await loadAll(server, "SELECT id FROM p146_readings ORDER BY id LIMIT 1700", in: directory)
            #expect(plan.mode == .skip)
            let first: [String] = (1...1700).map { String($0) }
            #expect(limited.rows.map { $0[0].text } == first, "\(server.dialect)")
        }
    }

    @Test(.enabled(if: !SQLLiveDatabaseTests.servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func readOnlySavedConnectionsPage() async throws {
        for server in SQLLiveDatabaseTests.servers {
            try Self.setup(server)
            let directory = try SQLSavedConnectionTests.project()
            defer { try? FileManager.default.removeItem(at: directory) }
            var (connection, _) = SQLLiveDatabaseTests.saved(server)
            connection.readOnly = true
            let (all, _) = try await loadAll(server, "SELECT id FROM p146_readings ORDER BY id", saved: connection, in: directory)
            #expect(all.rows.count == 2500, "\(server.dialect)")
            #expect(all.saved == true)
            #expect(all.source?.hasSuffix("read-only session") == true, "\(server.dialect): \(all.source ?? "")")
            // Should a write reach the runner as a page, the read-only connection still refuses it.
            let write = SQLPaging.Page(sql: "DELETE FROM p146_readings", offset: 0, size: 10, skip: 0, driver: nil, added: nil)
            let refused = try await SQLSavedConnectionTests.run(SQLTabRun.pageCode(write, connection: nil), connection: connection, in: directory, password: server.password)
            #expect(refused.errors.first?.className == "RunletRunner\\SqlReadOnlyRefused", "\(server.dialect): \(refused.errors)")
            #expect(try server.exec("SELECT COUNT(*) FROM p146_readings") == "2500")
        }
    }
}
