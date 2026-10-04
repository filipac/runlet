import Foundation
@testable import RunletCore
import Testing
@testable import RunletExecution

/// Every result set of a statement (#154) against live MariaDB 11 (procedures) and PostgreSQL 14
/// (one result, as before), through `RUNLET_TEST_MYSQL` / `RUNLET_TEST_PGSQL`. The tests use their
/// own `p154_` table and procedures, created on each run.
@Suite(.serialized, .live(.sql), .enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct SQLResultSetsLiveTests {
    typealias Server = SQLLiveDatabaseTests.Server

    /// `p154_items` (three rows) and four procedures: two SELECTs, a SELECT and an UPDATE, no
    /// result (two UPDATEs), and a SELECT then an error.
    static func setup(_ server: Server) throws {
        for statement in [
            "DROP TABLE IF EXISTS p154_items",
            "CREATE TABLE p154_items (id INT PRIMARY KEY, name VARCHAR(20) NOT NULL, qty INT NOT NULL) ENGINE=InnoDB",
            "INSERT INTO p154_items VALUES (1, 'bolt', 5), (2, 'nut', 7), (3, 'washer', 9)",
            "DROP PROCEDURE IF EXISTS p154_two",
            "CREATE PROCEDURE p154_two() BEGIN SELECT id, name FROM p154_items ORDER BY id; SELECT COUNT(*) AS items FROM p154_items; END",
            "DROP PROCEDURE IF EXISTS p154_select_update",
            "CREATE PROCEDURE p154_select_update() BEGIN SELECT id, qty FROM p154_items ORDER BY id; UPDATE p154_items SET qty = qty + 1 WHERE id <= 2; END",
            "DROP PROCEDURE IF EXISTS p154_none",
            "CREATE PROCEDURE p154_none() BEGIN UPDATE p154_items SET qty = qty WHERE id = 3; UPDATE p154_items SET qty = qty + 1; END",
            "DROP PROCEDURE IF EXISTS p154_fails",
            "CREATE PROCEDURE p154_fails() BEGIN SELECT id FROM p154_items ORDER BY id; SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'p154 stops here'; END",
        ] {
            _ = try server.exec(statement)
        }
    }

    func run(_ server: Server, _ statement: String, maxRows: Int = 1000) async throws -> [RunEvent] {
        let directory = try server.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await TestSupport.run(SQLTabRun.code(statement: statement, connection: nil, maxRows: maxRows), target: DriverSupport.target(directory.path), magicComments: false)
    }

    @Test(.enabled(if: SQLLiveDatabaseTests.mysql != nil, "set RUNLET_TEST_MYSQL"))
    func aProcedureWithTwoSelectsShowsTwoTables() async throws {
        let server = try #require(SQLLiveDatabaseTests.mysql)
        try Self.setup(server)
        let events = try await run(server, "CALL p154_two()")
        #expect(events.errors.isEmpty, "\(events.errors)")
        let results = events.sqlResults
        #expect(results.count == 2, "the CALL's own status (no columns, nothing changed) is left out")
        #expect(results.map(\.title) == ["Result 1 of 2", "Result 2 of 2"])
        #expect(results[0].columns == ["id", "name"])
        #expect(results[0].rows.map { $0.map(\.text) } == [["1", "bolt"], ["2", "nut"], ["3", "washer"]])
        #expect(results[1].columns == ["items"])
        #expect(results[1].rows.map { $0.map(\.text) } == [["3"]])
        #expect(results[0].connections == nil || results[1].connections == nil, "the connection names come once")
        #expect(results[1].plainText.hasPrefix("SQL (Result 2 of 2): 1 row"))
    }

    @Test(.enabled(if: SQLLiveDatabaseTests.mysql != nil, "set RUNLET_TEST_MYSQL"))
    func aSelectAndAnUpdateShowTheRowsAndTheAffectedRows() async throws {
        let server = try #require(SQLLiveDatabaseTests.mysql)
        try Self.setup(server)
        let events = try await run(server, "CALL p154_select_update()")
        #expect(events.errors.isEmpty, "\(events.errors)")
        let results = events.sqlResults
        #expect(results.map(\.title) == ["Result 1 of 2", "Result 2 of 2"])
        #expect(results[0].rows.map { $0.map(\.text) } == [["1", "5"], ["2", "7"], ["3", "9"]])
        #expect(results[1].hasResultSet == false)
        #expect(results[1].affectedRows == 2)
        #expect(results[1].summary == "2 rows affected")
        #expect(try server.exec("SELECT SUM(qty) FROM p154_items") == "23")
    }

    @Test(.enabled(if: SQLLiveDatabaseTests.mysql != nil, "set RUNLET_TEST_MYSQL"))
    func aProcedureWithoutAResultShowsItsAffectedRows() async throws {
        let server = try #require(SQLLiveDatabaseTests.mysql)
        try Self.setup(server)
        let events = try await run(server, "CALL p154_none()")
        #expect(events.errors.isEmpty, "\(events.errors)")
        let results = events.sqlResults
        #expect(results.count == 1)
        #expect(results[0].resultSet == nil, "one result keeps today's card")
        #expect(results[0].title == "SQL")
        #expect(results[0].affectedRows == 3)
        // CALL stays a possible write (unchanged).
        #expect(SQLScript.effect(of: "CALL p154_none()") == .write("CALL"))
    }

    @Test(.enabled(if: SQLLiveDatabaseTests.mysql != nil, "set RUNLET_TEST_MYSQL"))
    func theRowCapAppliesToTheRunAsAWhole() async throws {
        let server = try #require(SQLLiveDatabaseTests.mysql)
        try Self.setup(server)
        let events = try await run(server, "CALL p154_two()", maxRows: 2)
        #expect(events.errors.isEmpty, "\(events.errors)")
        let results = events.sqlResults
        #expect(results.count == 2)
        #expect(results[0].rows.count == 2)
        #expect(results[0].truncated == true)
        #expect(results[1].rows.isEmpty, "the first set used the run's two rows")
        #expect(results[1].truncated == true)
    }

    @Test(.enabled(if: SQLLiveDatabaseTests.mysql != nil, "set RUNLET_TEST_MYSQL"))
    func theSetsBeforeAFailureStillShow() async throws {
        let server = try #require(SQLLiveDatabaseTests.mysql)
        try Self.setup(server)
        let events = try await run(server, "CALL p154_fails()")
        let results = events.sqlResults
        #expect(results.count == 1)
        #expect(results.first?.title == "Result 1", "the count isn't known")
        #expect(results.first?.rows.count == 3)
        #expect(events.errors.first?.message.contains("p154 stops here") == true, "\(events.errors)")
    }

    @Test(.enabled(if: SQLLiveDatabaseTests.mysql != nil, "set RUNLET_TEST_MYSQL"))
    func runAllLabelsEachStatementsResults() async throws {
        let server = try #require(SQLLiveDatabaseTests.mysql)
        try Self.setup(server)
        let directory = try server.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = "SELECT 1 AS one;\nCALL p154_two();"
        let statements = try SQLScript.statementsToRunAll(in: script, selection: NSRange(location: 0, length: 0)).get()
        let events = try await TestSupport.run(SQLTabRun.scriptCode(statements: statements, connection: nil, transaction: false), target: DriverSupport.target(directory.path), magicComments: false)
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.sqlResults.map(\.title) == ["Statement 1 of 2", "Statement 2 of 2 · Result 1 of 2", "Statement 2 of 2 · Result 2 of 2"])
    }

    @Test(.enabled(if: SQLLiveDatabaseTests.pgsql != nil, "set RUNLET_TEST_PGSQL"))
    func postgreSQLKeepsOneResult() async throws {
        let server = try #require(SQLLiveDatabaseTests.pgsql)
        let events = try await run(server, "SELECT n FROM generate_series(1, 3) AS n")
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.sqlResults.count == 1)
        #expect(events.sqlResults.first?.resultSet == nil)
        #expect(events.sqlResults.first?.rows.count == 3)
    }
}
