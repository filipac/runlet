import Foundation
@testable import RunletCore
import Testing
@testable import RunletExecution

/// Read-only saved connections (#139) through the runner, with host PHP and SQLite: the
/// database refuses writes even when a statement gets past the app's and the runner's checks,
/// the runner refuses writing and session-changing statements before connecting, reads run,
/// and the runner's rules agree with the app's.
@Suite(.serialized, .enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct SQLReadOnlyConnectionTests {
    static func readOnly(_ path: String = "data/shop.sqlite") -> DatabaseConnection {
        var connection = SQLSavedConnectionTests.connection(path, name: "Replica")
        connection.readOnly = true
        return connection
    }

    /// PHP that bypasses SqlTab's checks and writes through the saved connection's PDO.
    static func pastTheChecks(_ statements: [String]) -> String {
        """
        <?php
        $pdo = \\RunletRunner\\SqlConnect::pdo();
        foreach (\(phpArray(statements)) as $sql) {
            try {
                $pdo->exec($sql);
                echo "OK $sql\\n";
            } catch (\\Throwable $error) {
                echo "FAIL $sql: ", $error->getMessage(), "\\n";
            }
        }
        echo 'customers=', $pdo->query('SELECT COUNT(*) FROM customers')->fetchColumn(), "\\n";
        """
    }

    static func phpArray(_ values: [String]) -> String {
        "[" + values.map(QueryExplain.phpString).joined(separator: ", ") + "]"
    }

    static func count(in directory: URL) throws -> String {
        let php = Process()
        php.executableURL = URL(fileURLWithPath: DriverSupport.php)
        php.arguments = ["-r", "echo (new PDO('sqlite:' . $argv[1]))->query('SELECT COUNT(*) FROM customers')->fetchColumn();", directory.appendingPathComponent("data/shop.sqlite").path]
        let output = Pipe()
        php.standardOutput = output
        try php.run()
        php.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    @Test func readsRunAndTheResultSaysTheSessionIsReadOnly() async throws {
        let directory = try SQLSavedConnectionTests.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = try await SQLSavedConnectionTests.run(SQLTabRun.code(statement: "SELECT email FROM customers ORDER BY id", connection: nil, schema: true), connection: Self.readOnly(), in: directory)
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.sqlResult?.rows == [[.string("a@example.test")], [.string("b@example.test")]])
        #expect(events.sqlResult?.source == #"saved connection "Replica" (sqlite, data/shop.sqlite), read-only session"#)
        #expect(events.sqlSchema?.tables.count == 2, "the schema reads in a read-only session")

        // Run All: reads and plain transaction control.
        let script = "BEGIN;\nSELECT COUNT(*) AS n FROM customers;\nPRAGMA table_info(orders);\nCOMMIT;"
        let statements = try SQLScript.statementsToRunAll(in: script, selection: NSRange(location: 0, length: 0)).get()
        let all = try await SQLSavedConnectionTests.run(SQLTabRun.scriptCode(statements: statements, connection: nil, transaction: false), connection: Self.readOnly(), in: directory)
        #expect(all.errors.isEmpty, "\(all.errors)")
        #expect(all.sqlResults.count == 4)
        let inTransaction = try SQLScript.statementsToRunAll(in: "SELECT 1;\nSELECT 2", selection: NSRange(location: 0, length: 0)).get()
        let committed = try await SQLSavedConnectionTests.run(SQLTabRun.scriptCode(statements: inTransaction, connection: nil, transaction: true), connection: Self.readOnly(), in: directory)
        #expect(committed.errors.isEmpty, "\(committed.errors)")
        #expect(committed.sqlResults.map(\.rows) == [[[.int(1)]], [[.int(2)]]])

        // Test Connection says the session is read-only.
        let (engine, _) = try SQLSavedConnectionTests.engine(for: Self.readOnly())
        let info = try await engine.testSQLConnection(target: DriverSupport.target(directory.path), connection: Self.readOnly(), password: .stored)
        #expect(info.readOnly == true)
        #expect(info.summary.hasSuffix("read-only session"))
        // A read-write connection doesn't.
        let writable = try await engine.testSQLConnection(target: DriverSupport.target(directory.path), connection: SQLSavedConnectionTests.connection(), password: .stored)
        #expect(writable.readOnly == nil)
    }

    @Test func theRunnerRefusesWritesAndSessionChangesBeforeConnecting() async throws {
        let directory = try SQLSavedConnectionTests.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        for sql in ["INSERT INTO customers (email) VALUES ('c@example.test')", "PRAGMA query_only = 0", "/* x */ pragma QUERY_ONLY(false)", "CREATE TABLE t (x)", "DELETE FROM customers", "ATTACH DATABASE 'other.sqlite' AS o"] {
            let events = try await SQLSavedConnectionTests.run(SQLTabRun.code(statement: sql, connection: nil), connection: Self.readOnly(), in: directory)
            let message = try #require(events.errors.first?.message, "\(sql)")
            #expect(message.hasPrefix(#"Runlet refused this statement on the read-only connection "Replica": it "#), "\(sql): \(message)")
            #expect(message.hasSuffix("Nothing ran."), "\(sql): \(message)")
            #expect(events.sqlResult == nil)
        }
        // Run All refuses the whole script before anything runs.
        let script = "SELECT 1;\nUPDATE orders SET total = 0;\nSELECT 2;"
        let statements = try SQLScript.statementsToRunAll(in: script, selection: NSRange(location: 0, length: 0)).get()
        let all = try await SQLSavedConnectionTests.run(SQLTabRun.scriptCode(statements: statements, connection: nil, transaction: true), connection: Self.readOnly(), in: directory)
        #expect(all.sqlResults.isEmpty, "nothing ran")
        #expect(all.errors.first?.message == #"Statement 2 of 3 (line 2) can change data or the schema (UPDATE), so Runlet ran none of the script on the read-only connection "Replica". Nothing ran."#, "\(all.errors)")
        #expect(try Self.count(in: directory) == "2")
    }

    /// The runner-level guarantee: an INSERT sent past both checks fails in SQLite, which opened
    /// the file read-only; switching query_only off doesn't help.
    @Test func anInsertPastTheChecksFailsInTheDatabase() async throws {
        let directory = try SQLSavedConnectionTests.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = try await SQLSavedConnectionTests.run(Self.pastTheChecks(["INSERT INTO customers (email) VALUES ('c@example.test')", "PRAGMA query_only = 0", "INSERT INTO customers (email) VALUES ('d@example.test')", "CREATE TABLE t (x)"]), connection: Self.readOnly(), in: directory)
        #expect(events.errors.isEmpty, "\(events.errors)")
        let lines = events.stdout.components(separatedBy: "\n")
        #expect(lines.first?.hasPrefix("FAIL INSERT") == true && lines.first?.contains("attempt to write a readonly database") == true, "\(events.stdout)")
        #expect(lines.filter { $0.hasPrefix("FAIL") }.count == 3, "\(events.stdout)")
        #expect(events.stdout.contains("customers=2"))
        #expect(try Self.count(in: directory) == "2")

        // The same connection without Read-only writes, so the failures above are Read-only's.
        let writable = try await SQLSavedConnectionTests.run(Self.pastTheChecks(["INSERT INTO customers (email) VALUES ('c@example.test')"]), connection: SQLSavedConnectionTests.connection(), in: directory)
        #expect(writable.stdout.hasPrefix("OK INSERT"), "\(writable.stdout)")
        #expect(try Self.count(in: directory) == "3")
    }

    @Test(.enabled(if: TestSupport.herdPHP74 != nil, "requires Herd's PHP 7.4"))
    func phpSevenFourOpensTheFileReadOnlyToo() async throws {
        let directory = try SQLSavedConnectionTests.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = try await SQLSavedConnectionTests.run(Self.pastTheChecks(["PRAGMA query_only = 0", "INSERT INTO customers (email) VALUES ('c@example.test')"]), connection: Self.readOnly(), in: directory, php: TestSupport.herdPHP74)
        #expect(events.started?.phpVersion?.hasPrefix("7.4") == true)
        #expect(events.stdout.contains("FAIL INSERT"), "\(events.stdout) \(events.errors)")
        #expect(try Self.count(in: directory) == "2")
        let refused = try await SQLSavedConnectionTests.run(SQLTabRun.code(statement: "DELETE FROM customers", connection: nil), connection: Self.readOnly(), in: directory, php: TestSupport.herdPHP74)
        #expect(refused.errors.first?.message.contains("Runlet refused this statement") == true, "\(refused.errors)")
        let read = try await SQLSavedConnectionTests.run(SQLTabRun.code(statement: "SELECT COUNT(*) FROM orders", connection: nil), connection: Self.readOnly(), in: directory, php: TestSupport.herdPHP74)
        #expect(read.sqlResult?.rows.first?.first?.text == "2", "\(read.errors)")
    }

    /// The runner's rules (SqlReadOnly.php) refuse what the app's (SQLReadOnly.swift) refuse.
    @Test func theRunnerAndTheAppAgree() async throws {
        let statements: [(String, DatabaseDriverKind?)] = [
            ("SET SESSION TRANSACTION READ WRITE", nil), ("set @@session.tx_read_only = 0", .mysql), ("SET `transaction_read_only` = 0", .mysql),
            ("SET default_transaction_read_only = off", .pgsql), ("SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE", .pgsql),
            ("BEGIN READ WRITE", .pgsql), ("start transaction with consistent snapshot, read write", .mysql), ("RESET ALL", .pgsql),
            ("DISCARD ALL", .pgsql), ("PRAGMA query_only = 0", .sqlite), ("PRAGMA query_only(0)", .sqlite), ("PRAGMA main.query_only", .sqlite),
            ("SELECT set_config('default_transaction_read_only', 'off', false)", .pgsql), ("INSERT INTO t VALUES (1)", nil),
            ("-- x\nupdate t set a = 1", nil), ("create temporary table x (id int)", .mysql), ("with g as (delete from t returning *) select * from g", .pgsql),
            ("select * into outfile '/tmp/x' from t", .mysql), ("select * from t for update", nil), ("explain analyze delete from t", .pgsql),
            ("PRAGMA user_version = 3", .sqlite), ("PRAGMA journal_mode(DELETE)", .sqlite), ("SET search_path TO x", .pgsql), ("CALL p()", .mysql),
            ("USE other", .mysql), ("select 1; delete from t", nil), (#"SELECT 'x\'' INTO OUTFILE '/tmp/x' -- '"#, .mysql),
            ("SELECT * FROM t /*!50000 INTO OUTFILE '/tmp/x' */", .mysql), ("SELECT 1 # 0, set_config('a', 'b', false)", .pgsql),
            (#"SELECT E'x\'' , set_config('default_transaction_read_only', 'off', false) -- '"#, .pgsql),
            // Allowed.
            ("SELECT * FROM orders", nil), ("select 'insert into t', \"delete\" from t -- drop table t", nil), ("SHOW TABLES", .mysql),
            ("describe orders", .mysql), ("explain analyze select 1", .pgsql), ("with x as (select 1) select * from x", nil),
            ("PRAGMA table_info(orders)", .sqlite), ("pragma main.index_list('orders')", .sqlite), ("SELECT @@transaction_read_only", .mysql),
            ("SHOW default_transaction_read_only", .pgsql), ("select current_setting('transaction_read_only')", .pgsql), ("BEGIN", nil),
            ("START TRANSACTION READ ONLY", .mysql), ("COMMIT", nil), ("ROLLBACK", nil), ("SAVEPOINT a", nil), ("select 1;", nil),
            ("SELECT 1 # we delete nothing", .mysql), (#"SELECT 'C:\path' FROM t"#, .mysql), ("SELECT $$delete$$", .pgsql),
        ]
        let cases = statements.map { "[\(QueryExplain.phpString($0.0)), \($0.1.map { "'\($0.rawValue)'" } ?? "null")]" }.joined(separator: ", ")
        let code = """
        <?php
        $out = [];
        foreach ([\(cases)] as [$sql, $driver]) {
            $out[] = \\RunletRunner\\SqlReadOnly::refusal($sql, $driver);
        }
        echo json_encode($out);
        """
        let events = try await TestSupport.run(code, target: DriverSupport.target(DriverSupport.fixture("plain")), magicComments: false)
        #expect(events.errors.isEmpty, "\(events.errors)")
        let refusals = try #require(try JSONSerialization.jsonObject(with: Data(events.stdout.utf8)) as? [Any], "\(events.stdout)")
        #expect(refusals.count == statements.count)
        for (index, (sql, driver)) in statements.enumerated() where index < refusals.count {
            let app = SQLScript.readOnlyRefusal(of: sql, driver: driver)
            let runner = refusals[index] as? String
            #expect((app == nil) == (runner == nil), "\(sql): app \(String(describing: app)), runner \(runner ?? "nil")")
        }
    }
}
