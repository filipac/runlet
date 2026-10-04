import Foundation
@testable import RunletCore
import Testing
@testable import RunletExecution

/// Bound parameters (#145) against live MariaDB 11 and PostgreSQL 14 (the throwaway fixture
/// containers of `scripts/setup-fixtures.sh databases`, through `RUNLET_TEST_MYSQL` /
/// `RUNLET_TEST_PGSQL`): every type through named and positional placeholders, Run All, each
/// server's rules for a repeated name, PostgreSQL's `??` operators, and a saved connection.
/// The tests use their own `p145_` table, created on each run.
@Suite(.serialized, .live(.sql), .enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct SQLParameterLiveTests {
    typealias Server = SQLLiveDatabaseTests.Server

    static func setup(_ server: Server) throws {
        let mysql = server.dialect == "mysql"
        _ = try server.exec("DROP TABLE IF EXISTS p145_items")
        _ = try server.exec(mysql
            ? "CREATE TABLE p145_items (id INT PRIMARY KEY, name VARCHAR(60) NOT NULL, price DECIMAL(10,2), active BOOLEAN, note VARCHAR(40) NULL) ENGINE=InnoDB"
            : "CREATE TABLE p145_items (id INT PRIMARY KEY, name VARCHAR(60) NOT NULL, price NUMERIC(10,2), active BOOLEAN, note VARCHAR(40) NULL, tags JSONB)")
    }

    func run(_ server: Server, _ text: String, _ values: [String: SQLParameterValue]) async throws -> [RunEvent] {
        let directory = try server.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let statements = SQLScript.statements(in: text)
        let scan = SQLParameters.scan(statements, driver: server.dialect == "mysql" ? .mysql : .pgsql)
        #expect(scan.problem == nil, "\(String(describing: scan.problem))")
        let bindings = try #require(scan.bindings(SQLParameterExecutionTests().keyed(values, scan)))
        let code = statements.count == 1
            ? SQLTabRun.code(statement: statements[0].text, connection: nil, bindings: bindings[0])
            : SQLTabRun.scriptCode(statements: statements, connection: nil, transaction: true, bindings: bindings)
        return try await TestSupport.run(code, target: DriverSupport.target(directory.path), magicComments: false)
    }

    @Test(.enabled(if: !SQLLiveDatabaseTests.servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func everyTypeThroughNamedAndPositionalPlaceholders() async throws {
        for server in SQLLiveDatabaseTests.servers {
            try Self.setup(server)
            let mysql = server.dialect == "mysql"
            let insert = try await run(server, "INSERT INTO p145_items (id, name, price, active, note) VALUES (:id, :name, :price, :active, :note)", [
                ":id": .integer(1), ":name": .text("O'Brien'); DROP TABLE p145_items; --"), ":price": .decimal("19.99"), ":active": .boolean(true), ":note": .null,
            ])
            #expect(insert.errors.isEmpty, "\(server.dialect): \(insert.errors)")
            #expect(insert.sqlResult?.affectedRows == 1, "\(server.dialect)")
            let second = try await run(server, "INSERT INTO p145_items (id, name, price, active, note) VALUES (?, ?, ?, ?, ?)", [
                "?1": .integer(2), "?2": .text("plain"), "?3": .decimal("5"), "?4": .boolean(false), "?5": .text("n"),
            ])
            #expect(second.errors.isEmpty, "\(server.dialect): \(second.errors)")

            let select = try await run(server, "SELECT id, name, price, active, note FROM p145_items WHERE price = ? AND active = ? AND note IS NULL", [
                "?1": .decimal("19.99"), "?2": .boolean(true),
            ])
            #expect(select.errors.isEmpty, "\(server.dialect): \(select.errors)")
            #expect(select.sqlResult?.rows.first?.map(\.text) == ["1", "O'Brien'); DROP TABLE p145_items; --", "19.99", mysql ? "1" : "true", "NULL"], "\(server.dialect): \(String(describing: select.sqlResult?.rows))")

            let typed = try await run(server, mysql
                ? "SELECT :i + 1 AS i, :d + 0 AS d, :n IS NULL AS n, CHAR_LENGTH(:t) AS t FROM p145_items WHERE id = :id"
                : "SELECT CAST(:i AS integer) + 1 AS i, CAST(:d AS numeric) + 0 AS d, CAST(:n AS text) IS NULL AS n, CHAR_LENGTH(CAST(:t AS text)) AS t FROM p145_items WHERE id = CAST(:id AS integer)", [
                    ":i": .integer(2), ":id": .integer(2), ":d": .decimal("1.25"), ":n": .null, ":t": .text("héllo"),
                ])
            #expect(typed.errors.isEmpty, "\(server.dialect): \(typed.errors)")
            #expect(typed.sqlResult?.rows.first?.map(\.text) == ["3", "1.25", mysql ? "1" : "true", "5"], "\(server.dialect): \(String(describing: typed.sqlResult?.rows))")
            #expect(try server.exec("SELECT COUNT(*) FROM p145_items") == "2", "\(server.dialect): the table is still there")
        }
    }

    @Test(.enabled(if: !SQLLiveDatabaseTests.servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func runAllSharesNamesInOneTransaction() async throws {
        for server in SQLLiveDatabaseTests.servers {
            try Self.setup(server)
            let fixed = try await run(server, """
            INSERT INTO p145_items (id, name, price) VALUES (:id, :name, :price);
            UPDATE p145_items SET note = ? WHERE id = ?;
            SELECT name, price, note FROM p145_items WHERE id = :id
            """, [":id": .integer(7), ":name": .text("seven"), ":price": .decimal("7.70"), "?1@2": .text("noted"), "?2@2": .integer(7)])
            #expect(fixed.errors.isEmpty, "\(server.dialect): \(fixed.errors)")
            #expect(fixed.sqlResults.last?.rows.first?.map(\.text) == ["seven", "7.70", "noted"], "\(server.dialect)")
            #expect(fixed.sqlNotices.last == "Committed the transaction: all 3 statements ran.", "\(server.dialect)")

            // A failing statement rolls back what the values wrote.
            let failed = try await run(server, """
            INSERT INTO p145_items (id, name) VALUES (:id, :name);
            INSERT INTO p145_items (id, name) VALUES (:id, :name)
            """, [":id": .integer(8), ":name": .text("dup")])
            #expect(failed.errors.first?.message.contains("Rolled back the transaction") == true, "\(server.dialect): \(failed.errors)")
            #expect(try server.exec("SELECT COUNT(*) FROM p145_items WHERE id = 8") == "0", "\(server.dialect)")
        }
    }

    @Test(.enabled(if: !SQLLiveDatabaseTests.servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func aRepeatedNameIsRefusedOnMySQLAndBoundOnPostgreSQL() async throws {
        for server in SQLLiveDatabaseTests.servers {
            try Self.setup(server)
            let events = try await run(server, "SELECT :n AS a, :n AS b", [":n": .integer(4)])
            if server.dialect == "mysql" {
                let error = try #require(events.errors.first)
                #expect(error.className == "RunletRunner\\SqlParametersRefused")
                #expect(error.message == "This statement has :n 2 times. MySQL and MariaDB can't bind one name in several places when the statement is prepared natively, as Runlet prepares it. Give each place its own name (:n, :n_2), or use ? placeholders. Nothing ran.", "\(error.message)")
            } else {
                #expect(events.errors.isEmpty, "\(events.errors)")
                #expect(events.sqlResult?.rows.first?.map(\.text) == ["4", "4"])
            }
        }
    }

    @Test(.enabled(if: SQLLiveDatabaseTests.pgsql != nil, "set RUNLET_TEST_PGSQL"))
    func postgresJSONOperatorsNeedTheirPDOEscape() async throws {
        let server = try #require(SQLLiveDatabaseTests.pgsql)
        try Self.setup(server)
        _ = try server.exec(#"INSERT INTO p145_items (id, name, tags) VALUES (1, 'a', '{"red": 1, "blue": 2}'), (2, 'b', '{"green": 1}')"#)
        let events = try await run(server, "SELECT id FROM p145_items WHERE tags ??| array['red', 'pink'] AND tags ?? 'blue' AND id::text = :id ORDER BY id", [":id": .text("1")])
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.sqlResult?.rows == [[.int(1)]])
    }

    @Test(.enabled(if: !SQLLiveDatabaseTests.servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func savedConnectionsBindToo() async throws {
        for server in SQLLiveDatabaseTests.servers {
            try Self.setup(server)
            _ = try server.exec("INSERT INTO p145_items (id, name, price) VALUES (1, 'one', 1.50), (2, 'two', 2.50)")
            let directory = try SQLSavedConnectionTests.project()
            defer { try? FileManager.default.removeItem(at: directory) }
            let (connection, _) = SQLLiveDatabaseTests.saved(server)
            let code = SQLTabRun.code(statement: "SELECT name FROM p145_items WHERE price > :min ORDER BY id", connection: nil, bindings: [SQLBinding(target: .name("min"), value: .decimal("2"))])
            let events = try await SQLSavedConnectionTests.run(code, connection: connection, in: directory, password: server.password)
            #expect(events.errors.isEmpty, "\(server.dialect): \(events.errors)")
            #expect(events.sqlResult?.rows == [[.string("two")]], "\(server.dialect)")
            #expect(events.sqlResult?.saved == true)
        }
    }
}
