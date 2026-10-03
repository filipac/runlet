import Foundation
@testable import RunletCore
import Testing
@testable import RunletExecution

/// Bound parameters (#145) through the runner, with host PHP and SQLite: named and positional
/// placeholders bound with every type, values that stay data, Run All sharing names, callable
/// connections refusing, read-only connections still refusing writes, and PHP 7.4.
@Suite(.serialized, .enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct SQLParameterExecutionTests {
    func project() throws -> URL {
        try SQLScriptExecutionTests().project()
    }

    /// Runs `text` (one statement) with `values` set on the sheet's form.
    func run(_ text: String, _ values: [String: SQLParameterValue], connection: String? = nil, in directory: URL, php: String? = nil) async throws -> [RunEvent] {
        let statements = SQLScript.statements(in: text)
        let scan = SQLParameters.scan(statements)
        #expect(scan.problem == nil)
        let bindings = try #require(scan.bindings(keyed(values, scan)))
        return try await TestSupport.run(SQLTabRun.code(statement: statements[0].text, connection: connection, bindings: bindings[0]),
                                         target: DriverSupport.target(directory.path, php: php), magicComments: false)
    }

    func runAll(_ text: String, _ values: [String: SQLParameterValue], connection: String? = nil, transaction: Bool = true, in directory: URL) async throws -> [RunEvent] {
        let statements = SQLScript.statements(in: text)
        let scan = SQLParameters.scan(statements)
        #expect(scan.problem == nil)
        let bindings = try #require(scan.bindings(keyed(values, scan)))
        return try await TestSupport.run(SQLTabRun.scriptCode(statements: statements, connection: connection, transaction: transaction, bindings: bindings),
                                         target: DriverSupport.target(directory.path), magicComments: false)
    }

    /// `[":a": …, "?1": …, "?1@2": …]` as the scan's keys.
    func keyed(_ values: [String: SQLParameterValue], _ scan: SQLParameterScan) -> [SQLParameter.Key: SQLParameterValue] {
        var keyed: [SQLParameter.Key: SQLParameterValue] = [:]
        for parameter in scan.parameters {
            if let entry = values.first(where: { SQLParameterForm.matches(parameter, $0.key) }) { keyed[parameter.key] = entry.value }
        }
        return keyed
    }

    @Test func namedPlaceholdersBindEveryType() async throws {
        let directory = try project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = try await run(
            "SELECT :t AS t, typeof(:t) AS tt, :i AS i, typeof(:i) AS ti, :i + 1 AS next, :d AS d, typeof(:d) AS td, :d + 0 AS dn, :b AS b, :n AS n, typeof(:n) AS tn",
            [":t": .text("it's; DROP TABLE entries; --"), ":i": .integer(9_007_199_254_740_993), ":d": .decimal("19.50"), ":b": .boolean(true), ":n": .null],
            in: directory)
        #expect(events.errors.isEmpty, "\(events.errors)")
        let result = try #require(events.sqlResult)
        #expect(result.columns == ["t", "tt", "i", "ti", "next", "d", "td", "dn", "b", "n", "tn"])
        #expect(result.rows == [[
            .string("it's; DROP TABLE entries; --"), .string("text"),
            .int(9_007_199_254_740_993), .string("integer"), .int(9_007_199_254_740_994),
            .string("19.50"), .string("text"), .double(19.5),
            .int(1), .null, .string("null"),
        ]])
        // The text stayed a value: the table is still there.
        #expect(try await SQLScriptExecutionTests().total(in: directory) == .int(30))
    }

    @Test func positionalPlaceholdersWriteAndRead() async throws {
        let directory = try project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let insert = try await run("INSERT INTO entries (amount) VALUES (?), (?)", ["?1": .integer(5), "?2": .integer(7)], in: directory)
        #expect(insert.errors.isEmpty, "\(insert.errors)")
        #expect(insert.sqlResult?.affectedRows == 2)
        let select = try await run("SELECT COUNT(*) AS n, SUM(amount) AS total FROM entries WHERE amount >= ? AND amount <= ?", ["?1": .integer(5), "?2": .decimal("10")], in: directory)
        #expect(select.errors.isEmpty, "\(select.errors)")
        #expect(select.sqlResult?.rows == [[.int(3), .int(22)]])
        // `??` is a literal `?` for PDO, not a placeholder.
        let escaped = try await run("SELECT '??' AS q, ? AS v", ["?1": .text("x")], in: directory)
        #expect(escaped.errors.isEmpty, "\(escaped.errors)")
        #expect(escaped.sqlResult?.rows == [[.string("??"), .string("x")]], "inside a string PDO leaves ?? alone")
    }

    @Test func runAllSharesNamesAndBindsEachStatementsQuestionMarks() async throws {
        let directory = try project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = try await runAll("""
        INSERT INTO entries (amount) VALUES (:amount);
        INSERT INTO entries (amount) VALUES (?), (?);
        SELECT COUNT(*) AS n FROM entries WHERE amount = :amount;
        SELECT SUM(amount) AS total FROM entries
        """, [":amount": .integer(3), "?1@2": .integer(3), "?2@2": .integer(4)], in: directory)
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.sqlResults.map(\.statement?.index) == [1, 2, 3, 4])
        #expect(events.sqlResults[2].rows == [[.int(2)]])
        #expect(events.sqlResults[3].rows == [[.int(40)]])
        #expect(events.sqlNotices == ["Committed the transaction: all 4 statements ran."])
    }

    @Test func callableConnectionsRefuseBeforeAnythingRuns() async throws {
        let directory = try project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let single = try await run("DELETE FROM entries WHERE amount = :amount", [":amount": .integer(10)], connection: "callable", in: directory)
        let error = try #require(single.errors.first)
        #expect(error.className == "RunletRunner\\SqlParametersRefused")
        #expect(error.message.hasPrefix("This statement has placeholders, and this connection (LedgerDriver::sqlConnection()) runs statements through a callable, which can't bind values. Runlet never writes values into the SQL, so nothing ran."), "\(error.message)")
        #expect(single.sqlResults.isEmpty)

        // Run All: refused as a whole before the first statement (or BEGIN) runs.
        let script = try await runAll("INSERT INTO entries (amount) VALUES (1);\nDELETE FROM entries WHERE amount = ?", ["?1@2": .integer(10)], connection: "callable", in: directory)
        let refused = try #require(script.errors.first)
        #expect(refused.message.hasPrefix("Statement 2 of 2 (line 2) has placeholders"), "\(refused.message)")
        #expect(script.sqlResults.isEmpty)
        #expect(try await SQLScriptExecutionTests().total(in: directory) == .int(30), "nothing ran")

        // Statements without placeholders still run on callables.
        let plain = try await TestSupport.run(SQLTabRun.code(statement: "SELECT COUNT(*) FROM entries", connection: "callable"), target: DriverSupport.target(directory.path), magicComments: false)
        #expect(plain.errors.isEmpty, "\(plain.errors)")
    }

    @Test func readOnlyConnectionsStillRefuseWritesWhateverTheValues() async throws {
        let directory = try SQLSavedConnectionTests.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let write = SQLTabRun.code(statement: "UPDATE customers SET email = :email WHERE id = :id", connection: nil, bindings: [
            SQLBinding(target: .name("email"), value: .text("c@example.test")), SQLBinding(target: .name("id"), value: .integer(1)),
        ])
        let refused = try await SQLSavedConnectionTests.run(write, connection: SQLReadOnlyConnectionTests.readOnly(), in: directory)
        #expect(refused.errors.first?.className == "RunletRunner\\SqlReadOnlyRefused", "\(refused.errors)")
        #expect(try SQLReadOnlyConnectionTests.count(in: directory) == "2")

        let read = SQLTabRun.code(statement: "SELECT email FROM customers WHERE id = :id", connection: nil, bindings: [SQLBinding(target: .name("id"), value: .integer(2))])
        let events = try await SQLSavedConnectionTests.run(read, connection: SQLReadOnlyConnectionTests.readOnly(), in: directory)
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.sqlResult?.rows == [[.string("b@example.test")]])
    }

    @Test(.enabled(if: TestSupport.herdPHP74 != nil, "requires Herd's PHP 7.4"))
    func bindsOnPHP74() async throws {
        let directory = try project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = try await run("SELECT :t AS t, :i + 1 AS i, :b AS b, :n AS n, :d AS d", [":t": .text("ok"), ":i": .integer(41), ":b": .boolean(false), ":n": .null, ":d": .decimal("0.1")], in: directory, php: TestSupport.herdPHP74)
        #expect(events.started?.phpVersion?.hasPrefix("7.4") == true)
        #expect(events.errors.isEmpty, "\(events.errors)")
        // PHP 7.4's SQLite driver returns numbers as text.
        #expect(events.sqlResult?.rows.first?.map(\.text) == ["ok", "42", "0", "NULL", "0.1"])
    }
}
