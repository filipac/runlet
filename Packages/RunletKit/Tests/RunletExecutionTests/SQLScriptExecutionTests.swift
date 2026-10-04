import Foundation
import RunletCore
import Testing
@testable import RunletExecution

extension Array where Element == RunEvent {
    /// Every `sql` event of a run, in order (Run All Statements, #129).
    var sqlResults: [SQLResultInfo] {
        compactMap { if case .sql(let info) = $0.kind { return info } else { return nil } }
    }

    var sqlNotices: [String] {
        compactMap { if case .notice(let message) = $0.kind { return message } else { return nil } }
    }
}

/// Run All Statements (#129) on SQLite: statements in order on one connection, one result per
/// statement, stop at the first error, and the optional transaction (PDO and callable
/// connections).
@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct SQLScriptExecutionTests {
    /// A project whose driver opens `ledger.sqlite` in the project: a PDO for the default
    /// connection, a callable for "callable".
    static let driver = """
    <?php
    class LedgerDriver extends \\Runlet\\Driver
    {
        private $path;

        public function name(): string
        {
            return 'Ledger';
        }

        public function bootstrap(string $projectPath): void
        {
            $this->path = $projectPath . '/ledger.sqlite';
        }

        public function sqlConnection(?string $connection)
        {
            $pdo = new \\PDO('sqlite:' . $this->path);
            $pdo->setAttribute(\\PDO::ATTR_ERRMODE, \\PDO::ERRMODE_EXCEPTION);
            if ($connection === 'callable') {
                return static function (string $sql) use ($pdo) {
                    $statement = $pdo->query($sql);

                    return $statement->columnCount() > 0 ? $statement->fetchAll(\\PDO::FETCH_ASSOC) : $statement->rowCount();
                };
            }

            return $pdo;
        }
    }
    """

    func project() throws -> URL {
        let directory = try DriverSupport.composerProject(drivers: ["LedgerDriver.php": Self.driver])
        let setup = "CREATE TABLE entries (id INTEGER PRIMARY KEY, amount INTEGER NOT NULL); INSERT INTO entries (amount) VALUES (10), (20);"
        let pdo = Process()
        pdo.executableURL = URL(fileURLWithPath: DriverSupport.php)
        pdo.arguments = ["-r", "$p = new PDO('sqlite:' . $argv[1]); $p->exec($argv[2]);", directory.appendingPathComponent("ledger.sqlite").path, setup]
        try pdo.run()
        pdo.waitUntilExit()
        return directory
    }

    func runAll(_ script: String, connection: String? = nil, transaction: Bool, in directory: URL) async throws -> [RunEvent] {
        let statements = try SQLScript.statementsToRunAll(in: script, selection: NSRange(location: 0, length: 0)).get()
        return try await TestSupport.run(SQLTabRun.scriptCode(statements: statements, connection: connection, transaction: transaction),
                                         target: DriverSupport.target(directory.path), magicComments: false)
    }

    func total(in directory: URL) async throws -> SQLCell? {
        let events = try await TestSupport.run(SQLTabRun.code(statement: "SELECT SUM(amount) FROM entries", connection: nil), target: DriverSupport.target(directory.path), magicComments: false)
        return events.sqlResult?.rows.first?.first
    }

    @Test func everyStatementRunsInOrderWithItsOwnResult() async throws {
        let directory = try project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = """
        INSERT INTO entries (amount) VALUES (5);
        -- the new total
        SELECT SUM(amount) AS total FROM entries;

        UPDATE entries SET amount = amount * 2 WHERE amount > 10
        """
        let events = try await runAll(script, transaction: false, in: directory)
        #expect(events.errors.isEmpty, "\(events.errors)")
        let results = events.sqlResults
        #expect(results.count == 3)
        #expect(results.map(\.statement?.index) == [1, 2, 3])
        #expect(results.map(\.statement?.count) == [3, 3, 3])
        #expect(results.map(\.statement?.line) == [1, 2, 5])
        #expect(results[0].affectedRows == 1)
        #expect(results[1].columns == ["total"] && results[1].rows == [[.int(35)]])
        #expect(results[2].affectedRows == 1)
        #expect(results[1].statement?.text == "-- the new total\nSELECT SUM(amount) AS total FROM entries")
        #expect(results[0].source == "LedgerDriver::sqlConnection()")
        #expect(events.sqlNotices.isEmpty, "no transaction, no notice")
        #expect(try await total(in: directory) == .int(55))
    }

    @Test func aTransactionCommitsAtTheEndAndRollsBackOnAnError() async throws {
        for connection in [nil, "callable"] {
            let directory = try project()
            defer { try? FileManager.default.removeItem(at: directory) }
            let committed = try await runAll("INSERT INTO entries (amount) VALUES (1); INSERT INTO entries (amount) VALUES (2);", connection: connection, transaction: true, in: directory)
            #expect(committed.errors.isEmpty, "\(connection ?? "pdo"): \(committed.errors)")
            #expect(committed.sqlResults.count == 2)
            #expect(committed.sqlNotices == ["Committed the transaction: all 2 statements ran."], "\(connection ?? "pdo")")
            #expect(try await total(in: directory) == .int(33), "\(connection ?? "pdo")")

            let failed = try await runAll("""
            INSERT INTO entries (amount) VALUES (100);
            UPDATE entries SET amount = 0;
            SELECT nope FROM missing;
            DELETE FROM entries;
            """, connection: connection, transaction: true, in: directory)
            #expect(failed.sqlResults.count == 2, "\(connection ?? "pdo")")
            let error = try #require(failed.errors.first)
            #expect(error.className == "RunletRunner\\SqlStatementFailed")
            #expect(error.message.hasPrefix("Statement 3 of 4 (line 3): "), "\(error.message)")
            #expect(error.message.contains("no such table: missing"), "\(error.message)")
            #expect(error.message.hasSuffix("Rolled back the transaction: statements 1–2 were undone. Statement 4 did not run."), "\(error.message)")
            #expect(try await total(in: directory) == .int(33), "\(connection ?? "pdo"): the failed run changed nothing")
        }
    }

    @Test func withoutATransactionEarlierStatementsStay() async throws {
        let directory = try project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failed = try await runAll("INSERT INTO entries (amount) VALUES (100);\nSELECT nope FROM missing;\nSELECT 1;\nSELECT 2;", transaction: false, in: directory)
        #expect(failed.sqlResults.count == 1)
        let error = try #require(failed.errors.first)
        #expect(error.message.hasPrefix("Statement 2 of 4 (line 2): "), "\(error.message)")
        #expect(error.message.hasSuffix("Statements 3–4 did not run."), "\(error.message)")
        #expect(!error.message.contains("Rolled back"))
        #expect(try await total(in: directory) == .int(130))

        // The first statement failing: nothing ran, nothing to undo.
        let first = try await runAll("SELECT nope FROM missing; SELECT 1;", transaction: true, in: directory)
        #expect(first.sqlResults.isEmpty)
        #expect(first.errors.first?.message.hasSuffix("Rolled back the transaction. Statement 2 did not run.") == true, "\(first.errors)")
    }

    @Test(.enabled(if: TestSupport.herdPHP74 != nil, "requires Herd's PHP 7.4"))
    func runsOnPHP74() async throws {
        let directory = try project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let statements = try SQLScript.statementsToRunAll(in: "INSERT INTO entries (amount) VALUES (1);\nSELECT nope FROM missing;", selection: NSRange(location: 0, length: 0)).get()
        let events = try await TestSupport.run(SQLTabRun.scriptCode(statements: statements, connection: nil, transaction: true),
                                               target: DriverSupport.target(directory.path, php: TestSupport.herdPHP74!), magicComments: false)
        #expect(events.started?.phpVersion?.hasPrefix("7.4") == true)
        #expect(events.sqlResults.count == 1)
        #expect(events.errors.first?.message.hasSuffix("Rolled back the transaction: statement 1 was undone.") == true, "\(events.errors)")
        #expect(try await total(in: directory) == .int(30))
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: TestSupport.fixtures.appendingPathComponent("wordpress/.runlet-fixture-ready").path), "requires the WordPress SQLite fixture"))
    func wordpressRunsScriptsThroughWpdb() async throws {
        // Reads only: the fixture's database is shared. On the `wpdb` connection (#208), BEGIN,
        // COMMIT, and ROLLBACK go through $wpdb.
        let target = DriverSupport.target(DriverSupport.fixture("wordpress"))
        let script = "SELECT option_value FROM rl_options WHERE option_name = 'blogname';\nSELECT COUNT(*) AS options FROM rl_options;"
        let statements = try SQLScript.statementsToRunAll(in: script, selection: NSRange(location: 0, length: 0)).get()
        let committed = try await TestSupport.run(SQLTabRun.scriptCode(statements: statements, connection: "wpdb", transaction: true), target: target, magicComments: false)
        #expect(committed.errors.isEmpty, "\(committed.errors)")
        #expect(committed.sqlResults.map(\.statement?.index) == [1, 2])
        #expect(committed.sqlResults.first?.source == "WordPress $wpdb")
        #expect(committed.sqlNotices.last == "Committed the transaction: all 2 statements ran.")

        let failing = try SQLScript.statementsToRunAll(in: "SELECT 1 AS one;\nSELECT nope FROM missing_table;", selection: NSRange(location: 0, length: 0)).get()
        let failed = try await TestSupport.run(SQLTabRun.scriptCode(statements: failing, connection: "wpdb", transaction: true), target: target, magicComments: false)
        #expect(failed.sqlResults.count == 1)
        #expect(failed.errors.first?.message.hasPrefix("Statement 2 of 2 (line 2): ") == true, "\(failed.errors)")
        #expect(failed.errors.first?.message.contains("Rolled back the transaction: statement 1 was undone.") == true, "\(failed.errors)")
    }

    @Test func implicitlyCommittingStatementsAreFlaggedForTheRunner() {
        let statements = SQLScript.statements(in: "CREATE TABLE t (id int); CREATE TEMPORARY TABLE x (id int); INSERT INTO t VALUES (1)")
        let code = SQLTabRun.scriptCode(statements: statements, connection: "reports", transaction: true)
        #expect(code.contains(#"['sql' => "CREATE TABLE t (id int)", 'line' => 1, 'implicitCommit' => true],"#), "\(code)")
        #expect(code.contains(#"['sql' => "CREATE TEMPORARY TABLE x (id int)", 'line' => 1],"#), "\(code)")
        #expect(code.contains(#"], "reports", 1000, true);"#), "\(code)")
    }
}
