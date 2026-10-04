import Foundation
@testable import RunletCore
import Testing
@testable import RunletExecution

/// Rollback ("dry run") mode (#13) through the runner with host PHP: Laravel on an SQLite file,
/// Capsule and Doctrine DBAL in the eloquent-app fixture, a project driver's own PDO, the
/// inspector turned off, and a driver whose hook fails. `RollbackLiveTests` covers MariaDB and
/// PostgreSQL.
enum RollbackSupport {
    static var laravelApp: URL { TestSupport.fixtures.appendingPathComponent("laravel-app") }
    static var hasLaravel: Bool { FileManager.default.fileExists(atPath: laravelApp.appendingPathComponent("vendor/autoload.php").path) }

    static func php(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// A folder whose project driver boots the laravel-app fixture with `environment` (DB_*)
    /// set first, so its own .env doesn't choose the database.
    static func laravelProject(_ environment: [String: String]) throws -> URL {
        let directory = try DriverSupport.temporaryDirectory("rollback")
        let values = environment.sorted { $0.key < $1.key }.map { "\(php($0.key)) => \(php($0.value))" }.joined(separator: ", ")
        try DriverSupport.write([".runlet/P13LaravelDriver.php": """
        <?php
        class P13LaravelDriver extends \\Runlet\\Drivers\\LaravelDriver
        {
            public function canBootstrap(string $projectPath): bool
            {
                return true;
            }

            public function bootstrap(string $projectPath): void
            {
                foreach ([\(values)] as $key => $value) {
                    putenv($key . '=' . $value);
                    $_ENV[$key] = $value;
                    $_SERVER[$key] = $value;
                }
                parent::bootstrap(\(php(laravelApp.path)));
            }
        }
        """], into: directory)
        return directory
    }

    static func request(_ code: String, in directory: URL, inspector: RunInspectorOptions = RunInspectorOptions(), rollback: Bool = true) -> RunRequest {
        var request = RunRequest(tabId: UUID(), documentVersion: 1, target: DriverSupport.target(directory.path), code: code, inspector: inspector, magicComments: false)
        request.rollback = rollback
        return request
    }

    static func run(_ code: String, in directory: URL, inspector: RunInspectorOptions = RunInspectorOptions(), rollback: Bool = true) async throws -> [RunEvent] {
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
        var events: [RunEvent] = []
        for await event in try await engine.start(request(code, in: directory, inspector: inspector, rollback: rollback)) { events.append(event) }
        return events
    }

    /// Runs `sql` on an SQLite file with host PHP and returns its rows, one per line.
    @discardableResult
    static func sqlite(_ file: URL, _ sql: String) throws -> String {
        let result = try TestProcess.runBlocking([DriverSupport.php, "-r", """
            $p = new PDO('sqlite:' . $argv[1], null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
            $s = $p->query($argv[2]);
            while ($s !== false && $s->columnCount() > 0 && ($row = $s->fetch(PDO::FETCH_NUM)) !== false) { echo implode('|', $row), "\\n"; }
            """, file.path, sql], step: "sqlite \(sql)", within: .seconds(30))
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A fresh SQLite file with a seeded `p13_items` table.
    static func seededSQLite() throws -> URL {
        let file = try DriverSupport.temporaryDirectory("rollback-db").appendingPathComponent("p13.sqlite")
        try sqlite(file, "CREATE TABLE p13_items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
        try sqlite(file, "INSERT INTO p13_items (name) VALUES ('alpha'), ('beta'), ('gamma')")
        return file
    }

    /// Inserts two rows, updates one, deletes one, and nests a closure transaction and a manual
    /// one: six statements that change data, then one read.
    static let changes = """
        use Illuminate\\Support\\Facades\\DB;
        DB::table('p13_items')->insert(['name' => 'delta']);
        DB::table('p13_items')->insert(['name' => 'epsilon']);
        DB::table('p13_items')->where('name', 'alpha')->update(['name' => 'ALPHA']);
        DB::table('p13_items')->where('name', 'beta')->delete();
        DB::transaction(function () { DB::table('p13_items')->insert(['name' => 'nested']); });
        DB::beginTransaction();
        DB::table('p13_items')->insert(['name' => 'manual']);
        DB::commit();
        return DB::table('p13_items')->orderBy('id')->pluck('name')->all();
        """
}

extension Array where Element == RunEvent {
    var rollbackReports: [RollbackReport] {
        compactMap { if case .rollback(let report) = $0.kind { return report } else { return nil } }
    }

    var rollbackOutcome: RollbackReport? { rollbackReports.last { $0.state == .finished } }

    var rollbackWarnings: [RollbackReport.Warning] { rollbackReports.compactMap { $0.state == .warning ? $0.warning : nil } }
}

@Suite(.serialized, .enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct RollbackModeTests {
    @Test func scriptsCarryTheFlagForSnippetRunsOnly() throws {
        func request(_ data: Data) throws -> [String: Any] {
            let text = String(decoding: data, as: UTF8.self)
            let encoded = try #require(text.components(separatedBy: "Runner::main('").last?.components(separatedBy: "');").first)
            let data = try #require(Data(base64Encoded: encoded))
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let bundle = TestSupport.bundle
        #expect(try request(bundle.script(code: "1", nonce: "n", runId: UUID(), limits: RunLimits(), rollback: true))["rollback"] as? Bool == true)
        #expect(try request(bundle.script(code: "1", nonce: "n", runId: UUID(), limits: RunLimits()))["rollback"] == nil)
        #expect(try request(bundle.script(code: "", nonce: "n", runId: UUID(), mode: .commands, limits: RunLimits(), rollback: true))["rollback"] == nil)
        // The engine passes the request's flag on.
        var run = RollbackSupport.request("1", in: URL(fileURLWithPath: "/tmp"))
        #expect(try request(ExecutionEngine.script(for: run, credentials: nil)(bundle, "n", RunLimits()))["rollback"] as? Bool == true)
        run.rollback = false
        #expect(try request(ExecutionEngine.script(for: run, credentials: nil)(bundle, "n", RunLimits()))["rollback"] == nil)
    }

    @Test func classifiesStatements() async throws {
        let directory = try DriverSupport.temporaryDirectory("rollback-plain")
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = try await TestSupport.run("""
            $kinds = [];
            foreach (['SELECT 1', '  /* c */ (SELECT 1)', 'WITH x AS (SELECT 1) SELECT * FROM x', 'WITH x AS (SELECT 1) DELETE FROM t', 'insert into t values (1)',
                      'UPDATE t SET a = 1', 'CREATE TABLE t (a int)', 'CREATE TEMPORARY TABLE t (a int)', 'drop temporary table t', 'ALTER TABLE t ADD b int',
                      'TRUNCATE t', 'LOCK TABLES t WRITE', 'START TRANSACTION', 'BEGIN', '"COMMIT"', 'END', 'ROLLBACK', 'ROLLBACK TO SAVEPOINT trans2',
                      'SAVEPOINT trans2', 'RELEASE SAVEPOINT trans2', 'SET NAMES utf8mb4', 'SET autocommit = 1', 'LOAD DATA INFILE x INTO TABLE t', 'SHOW TABLES', 'PRAGMA foreign_keys'] as $sql) {
                $kinds[] = \\RunletRunner\\Rollback::classify($sql)[0];
            }
            return implode(',', $kinds);
            """, target: DriverSupport.target(directory.path), magicComments: false)
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.result?.value?.scalar == "read,read,read,write,write,write,ddl,write,write,ddl,ddl,ddl,begin,begin,commit,commit,rollback,savepoint,savepoint,savepoint,session,ddl,write,read,read")
    }

    @Test(.enabled(if: RollbackSupport.hasLaravel, "needs Tests/Fixtures/laravel-app/vendor"))
    func laravelOnSQLiteRollsEverythingBack() async throws {
        let database = try RollbackSupport.seededSQLite()
        defer { try? FileManager.default.removeItem(at: database.deletingLastPathComponent()) }
        let project = try RollbackSupport.laravelProject(["DB_CONNECTION": "sqlite", "DB_DATABASE": database.path])
        defer { try? FileManager.default.removeItem(at: project) }
        for inspector in [RunInspectorOptions(), RunInspectorOptions(enabled: false)] {
            let events = try await RollbackSupport.run(RollbackSupport.changes, in: project, inspector: inspector)
            #expect(events.errors.isEmpty, "\(events.errors)")
            // Inside the run the snippet saw its own changes.
            #expect(events.result?.value?.plainText().contains("ALPHA") == true, "\(String(describing: events.result))")
            let outcome = try #require(events.rollbackOutcome, "\(events.rollbackReports)")
            #expect(events.rollbackReports.first?.state == .begun)
            #expect(outcome.reason == "completed")
            #expect(outcome.statements == 6, "inspector \(inspector.enabled): \(outcome)")
            #expect(outcome.title == "Rolled back 6 statements on sqlite")
            #expect(outcome.connections?.map(\.status) == [.rolledBack])
            #expect(outcome.connections?.first?.reads == 1)
            #expect(outcome.warnings ?? [] == [])
            // The inspector on: Runlet's own BEGIN and ROLLBACK aren't in the Queries section.
            if inspector.enabled {
                #expect(events.inspection.queries.count == 7, "\(events.inspection.queries.map(\.query.sql))")
            } else {
                #expect(events.inspection.queries.isEmpty)
            }
            #expect(try RollbackSupport.sqlite(database, "SELECT name FROM p13_items ORDER BY id") == "alpha\nbeta\ngamma")
        }
        // Without Dry Run the same code changes the table.
        let real = try await RollbackSupport.run("use Illuminate\\Support\\Facades\\DB;\nDB::table('p13_items')->insert(['name' => 'kept']);", in: project, rollback: false)
        #expect(real.rollbackReports.isEmpty)
        #expect(try RollbackSupport.sqlite(database, "SELECT COUNT(*) FROM p13_items") == "4")
    }

    @Test(.enabled(if: RollbackSupport.hasLaravel, "needs Tests/Fixtures/laravel-app/vendor"))
    func errorsExitsAndCommitsInTheSnippet() async throws {
        let database = try RollbackSupport.seededSQLite()
        defer { try? FileManager.default.removeItem(at: database.deletingLastPathComponent()) }
        let project = try RollbackSupport.laravelProject(["DB_CONNECTION": "sqlite", "DB_DATABASE": database.path])
        defer { try? FileManager.default.removeItem(at: project) }
        let failed = try await RollbackSupport.run("use Illuminate\\Support\\Facades\\DB;\nDB::table('p13_items')->insert(['name' => 'x']);\nthrow new RuntimeException('halfway');", in: project)
        #expect(failed.errors.first?.message == "halfway")
        #expect(failed.rollbackOutcome?.reason == "error")
        #expect(failed.rollbackOutcome?.statements == 1)
        let exited = try await RollbackSupport.run("use Illuminate\\Support\\Facades\\DB;\nDB::table('p13_items')->delete();\nexit(2);", in: project)
        #expect(exited.rollbackOutcome?.reason == "exit")
        #expect(exited.rollbackOutcome?.statements == 1)
        let dumped = try await RollbackSupport.run("use Illuminate\\Support\\Facades\\DB;\nDB::table('p13_items')->update(['name' => 'z']);\ndd(1);", in: project)
        #expect(dumped.rollbackOutcome?.reason == "dd")
        #expect(try RollbackSupport.sqlite(database, "SELECT name FROM p13_items ORDER BY id") == "alpha\nbeta\ngamma")
        // A commit that isn't nested inside the snippet's own transaction ends Runlet's: saved, and said.
        let committed = try await RollbackSupport.run("use Illuminate\\Support\\Facades\\DB;\nDB::table('p13_items')->insert(['name' => 'committed']);\nDB::commit();\nDB::table('p13_items')->insert(['name' => 'after']);", in: project)
        let outcome = try #require(committed.rollbackOutcome)
        #expect(outcome.connections?.first?.status == .committed, "\(outcome)")
        #expect(outcome.connections?.first?.saved == 2)
        #expect(outcome.statements == 0)
        #expect(committed.rollbackWarnings.first?.kind == "committed")
        #expect(committed.rollbackWarnings.first?.snippetLine == 3, "\(committed.rollbackWarnings)")
        #expect(try RollbackSupport.sqlite(database, "SELECT name FROM p13_items WHERE id > 3 ORDER BY id") == "committed\nafter")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: TestSupport.fixtures.appendingPathComponent("eloquent-app/vendor").path), "needs Tests/Fixtures/eloquent-app/vendor"))
    func capsuleAndDoctrineInAProjectDriver() async throws {
        let code = """
            use Shop\\Models\\Customer;
            Customer::create(['name' => 'Zed']);
            Customer::where('name', 'Ada')->update(['name' => 'Ada L']);
            $reports = $container->get('reports');
            $reports->executeStatement("INSERT INTO reports (name) VALUES ('monthly')");
            $reports->beginTransaction();
            $reports->executeStatement("DELETE FROM reports WHERE name = 'daily'");
            $reports->commit();
            return [Customer::count(), (int) $reports->fetchOne('SELECT COUNT(*) FROM reports')];
            """
        var php: [String?] = [nil]
        if let php74 = TestSupport.herdPHP74 { php.append(php74) }
        for binary in php {
            let target = DriverSupport.target(DriverSupport.fixture("eloquent-app"), php: binary)
            var request = RunRequest(tabId: UUID(), documentVersion: 1, target: target, code: code, magicComments: false)
            request.rollback = true
            let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
            var events: [RunEvent] = []
            for await event in try await engine.start(request) { events.append(event) }
            #expect(events.errors.isEmpty, "\(binary ?? "php"): \(events.errors)")
            let outcome = try #require(events.rollbackOutcome, "\(binary ?? "php")")
            #expect(outcome.title == "Rolled back 4 statements on default and reports", "\(binary ?? "php"): \(outcome)")
            #expect(outcome.connections?.map(\.api) == ["eloquent", "doctrine"])
            // illuminate/database 8 has no ConnectionEstablished event: the report says so.
            #expect(outcome.notes?.first?.contains("ConnectionEstablished") == true)
        }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: TestSupport.fixtures.appendingPathComponent("wordpress/.runlet-fixture-ready").path), "needs the WordPress fixture"))
    func wordpressThroughWpdb() async throws {
        let directory = URL(fileURLWithPath: DriverSupport.fixture("wordpress"))
        let events = try await RollbackSupport.run("""
            global $wpdb;
            add_option('p13_dry_run_probe', 'x');
            update_option('blogname', 'Changed by a dry run');
            return get_option('blogname');
            """, in: directory)
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.result?.value?.scalar == "Changed by a dry run")
        let outcome = try #require(events.rollbackOutcome)
        #expect(outcome.connections?.map(\.name) == ["wpdb"])
        #expect(outcome.connections?.first?.api == "wordpress")
        #expect(outcome.connections?.first?.status == .rolledBack)
        #expect((outcome.statements ?? 0) >= 2, "\(outcome)")
        let after = try await RollbackSupport.run("return [get_option('blogname'), get_option('p13_dry_run_probe')];", in: directory, rollback: false)
        #expect(after.result?.value?.plainText().contains("Changed by a dry run") == false, "\(String(describing: after.result))")
        #expect(after.result?.value?.plainText().contains("false") == true)
    }

    @Test func aProjectDriversOwnPDOAndUnwrappedConnections() async throws {
        let directory = try DriverSupport.temporaryDirectory("rollback-pdo")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = directory.appendingPathComponent("ledger.sqlite")
        let audit = directory.appendingPathComponent("audit.sqlite")
        try RollbackSupport.sqlite(ledger, "CREATE TABLE entries (id INTEGER PRIMARY KEY, amount INTEGER)")
        try RollbackSupport.sqlite(ledger, "INSERT INTO entries (amount) VALUES (10), (20)")
        try RollbackSupport.sqlite(audit, "CREATE TABLE events (id INTEGER PRIMARY KEY, what TEXT)")
        try DriverSupport.write([".runlet/LedgerDriver.php": """
        <?php
        class LedgerDriver extends \\Runlet\\Driver
        {
            private $ledger;
            private $audit;

            public function bootstrap(string $projectPath): void
            {
                $this->ledger = new PDO('sqlite:' . $projectPath . '/ledger.sqlite', null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
                $this->audit = new PDO('sqlite:' . $projectPath . '/audit.sqlite', null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
            }

            public function variables(): array
            {
                return ['ledger' => $this->ledger, 'audit' => $this->audit];
            }

            public function inspect(\\Runlet\\Inspector $inspector): void
            {
                $inspector->watchPdo($this->audit, 'audit');
            }

            public function rollbackConnections(): array
            {
                return ['ledger' => $this->ledger];
            }
        }
        """], into: directory)
        let events = try await RollbackSupport.run("""
            $ledger->prepare('INSERT INTO entries (amount) VALUES (?)')->execute([30]);
            $ledger->prepare('UPDATE entries SET amount = amount * 2')->execute();
            $audit->prepare('INSERT INTO events (what) VALUES (?)')->execute(['doubled']);
            return (int) $ledger->query('SELECT SUM(amount) FROM entries')->fetchColumn();
            """, in: directory)
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.result?.value?.scalar == "120")
        let outcome = try #require(events.rollbackOutcome)
        #expect(outcome.statements == 2, "\(outcome)")
        #expect(outcome.connections?.map(\.status) == [.rolledBack, .notWrapped])
        #expect(outcome.title == "Rolled back 2 statements on ledger · 1 statement saved")
        #expect(events.rollbackWarnings.map(\.kind) == ["notWrapped"])
        #expect(events.rollbackWarnings.first?.snippetLine == 3)
        #expect(try RollbackSupport.sqlite(ledger, "SELECT SUM(amount) FROM entries") == "30")
        #expect(try RollbackSupport.sqlite(audit, "SELECT what FROM events") == "doubled")
    }

    @Test func aFailingHookRunsNothing() async throws {
        let directory = try DriverSupport.temporaryDirectory("rollback-hook")
        defer { try? FileManager.default.removeItem(at: directory) }
        try DriverSupport.write([".runlet/BrokenDriver.php": """
        <?php
        class BrokenDriver extends \\Runlet\\Driver
        {
            public function bootstrap(string $projectPath): void
            {
            }

            public function rollbackConnections(): array
            {
                throw new RuntimeException('no database configured');
            }
        }
        """], into: directory)
        let events = try await RollbackSupport.run("echo 'ran';\nreturn 1;", in: directory)
        #expect(events.stdout.isEmpty)
        #expect(events.result == nil)
        let error = try #require(events.errors.first)
        #expect(error.stage == .bootstrap)
        #expect(error.message.contains("rollbackConnections(): no database configured"), "\(error.message)")
        #expect(error.message.hasSuffix("Rollback mode: nothing ran."))
        #expect(events.finished?.status == .failed)
        // Without Dry Run the hook isn't called.
        let normal = try await RollbackSupport.run("echo 'ran';", in: directory, rollback: false)
        #expect(normal.stdout == "ran")
    }

    @Test func noConnectionToWrap() async throws {
        let directory = try DriverSupport.temporaryDirectory("rollback-none")
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = try await RollbackSupport.run("return 2 + 2;", in: directory)
        #expect(events.result?.value?.scalar == "4")
        #expect(events.rollbackOutcome?.title == "Dry run: no database connection to roll back")
    }
}
