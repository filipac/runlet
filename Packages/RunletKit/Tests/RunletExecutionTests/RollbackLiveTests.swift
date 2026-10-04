import Foundation
@testable import RunletCore
import Testing
@testable import RunletExecution

/// Rollback ("dry run") mode (#13) on live MariaDB and PostgreSQL, through the laravel-app
/// fixture booted with the server's DB_* settings. They run only when `RUNLET_TEST_MYSQL` /
/// `RUNLET_TEST_PGSQL` are set (`scripts/setup-fixtures.sh databases`), and use `p13_` tables.
@Suite(.serialized, .live(.sql), .enabled(if: TestSupport.hasPHP && RollbackSupport.hasLaravel && !SQLLiveDatabaseTests.servers.isEmpty,
                             "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL, and install Tests/Fixtures/laravel-app/vendor"))
struct RollbackLiveTests {
    typealias Server = SQLLiveDatabaseTests.Server

    /// The laravel-app fixture's DB_* for `server` (its `mariadb` or `pgsql` connection).
    static func project(_ server: Server) throws -> URL {
        var fields: [String: String] = [:]
        for part in server.dsn.drop(while: { $0 != ":" }).dropFirst().split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { fields[pair[0]] = pair[1] }
        }
        return try RollbackSupport.laravelProject([
            "DB_CONNECTION": server.dialect == "pgsql" ? "pgsql" : "mariadb",
            "DB_HOST": fields["host"] ?? "127.0.0.1",
            "DB_PORT": fields["port"] ?? "",
            "DB_DATABASE": fields["dbname"] ?? "",
            "DB_USERNAME": server.user,
            "DB_PASSWORD": server.password,
        ])
    }

    static func seed(_ server: Server) throws {
        _ = try server.exec("DROP TABLE IF EXISTS p13_items")
        _ = try server.exec(server.dialect == "pgsql"
            ? "CREATE TABLE p13_items (id SERIAL PRIMARY KEY, name VARCHAR(50) NOT NULL)"
            : "CREATE TABLE p13_items (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(50) NOT NULL) ENGINE=InnoDB")
        _ = try server.exec("INSERT INTO p13_items (name) VALUES ('alpha'), ('beta'), ('gamma')")
    }

    static func names(_ server: Server) throws -> String {
        try server.exec("SELECT name FROM p13_items ORDER BY id")
    }

    static func connection(_ server: Server) -> String { server.dialect == "pgsql" ? "pgsql" : "mariadb" }

    @Test func insertsUpdatesAndDeletesAreGone() async throws {
        for server in SQLLiveDatabaseTests.servers {
            try Self.seed(server)
            let project = try Self.project(server)
            defer { try? FileManager.default.removeItem(at: project) }
            let events = try await RollbackSupport.run(RollbackSupport.changes, in: project)
            #expect(events.errors.isEmpty, "\(server.dialect): \(events.errors)")
            #expect(events.result?.value?.plainText().contains("nested") == true, "\(server.dialect)")
            let outcome = try #require(events.rollbackOutcome, "\(server.dialect)")
            #expect(outcome.statements == 6, "\(server.dialect): \(outcome)")
            #expect(outcome.title == "Rolled back 6 statements on \(Self.connection(server))")
            #expect(outcome.connections?.first?.status == .rolledBack)
            #expect(outcome.connections?.first?.reads == 1)
            #expect(events.rollbackWarnings.isEmpty, "\(events.rollbackWarnings)")
            #expect(try Self.names(server) == "alpha\nbeta\ngamma", "\(server.dialect)")
        }
    }

    @Test func anErrorMidRunStillRollsBack() async throws {
        for server in SQLLiveDatabaseTests.servers {
            try Self.seed(server)
            let project = try Self.project(server)
            defer { try? FileManager.default.removeItem(at: project) }
            let events = try await RollbackSupport.run("""
                use Illuminate\\Support\\Facades\\DB;
                DB::table('p13_items')->insert(['name' => 'delta']);
                DB::table('p13_items')->where('name', 'gamma')->delete();
                DB::table('p13_items')->insert(['id' => 1, 'name' => 'duplicate']);
                DB::table('p13_items')->insert(['name' => 'never']);
                """, in: project)
            let error = try #require(events.errors.first, "\(server.dialect)")
            #expect(error.snippetLine == 4, "\(server.dialect): \(error)")
            let outcome = try #require(events.rollbackOutcome)
            #expect(outcome.reason == "error")
            #expect(outcome.connections?.first?.status == .rolledBack, "\(server.dialect): \(outcome)")
            // The INSERT that failed isn't counted: Laravel reports the statements that ran.
            #expect(outcome.statements == 2, "\(server.dialect): \(outcome)")
            #expect(try Self.names(server) == "alpha\nbeta\ngamma", "\(server.dialect)")
        }
    }

    @Test func nestedTransactionsAndUnbalancedCommits() async throws {
        for server in SQLLiveDatabaseTests.servers {
            try Self.seed(server)
            let project = try Self.project(server)
            defer { try? FileManager.default.removeItem(at: project) }
            // A rolled-back nested transaction and committed ones, all inside Runlet's.
            let nested = try await RollbackSupport.run("""
                use Illuminate\\Support\\Facades\\DB;
                DB::transaction(function () {
                    DB::table('p13_items')->insert(['name' => 'one']);
                    DB::transaction(function () { DB::table('p13_items')->insert(['name' => 'two']); });
                });
                try {
                    DB::transaction(function () {
                        DB::table('p13_items')->insert(['name' => 'three']);
                        throw new RuntimeException('undo three');
                    });
                } catch (RuntimeException $e) {
                }
                return DB::table('p13_items')->count();
                """, in: project)
            #expect(nested.errors.isEmpty, "\(server.dialect): \(nested.errors)")
            #expect(nested.result?.value?.scalar == "5", "\(server.dialect)")
            #expect(nested.rollbackOutcome?.connections?.first?.status == .rolledBack)
            #expect(nested.rollbackWarnings.isEmpty)
            #expect(try Self.names(server) == "alpha\nbeta\ngamma", "\(server.dialect)")
            // DB::commit() without the snippet's own beginTransaction() commits Runlet's.
            let committed = try await RollbackSupport.run("""
                use Illuminate\\Support\\Facades\\DB;
                DB::table('p13_items')->insert(['name' => 'committed']);
                DB::commit();
                """, in: project)
            #expect(committed.rollbackOutcome?.connections?.first?.status == .committed, "\(server.dialect): \(String(describing: committed.rollbackOutcome))")
            #expect(committed.rollbackWarnings.first?.kind == "committed")
            #expect(try Self.names(server) == "alpha\nbeta\ngamma\ncommitted", "\(server.dialect)")
        }
    }

    static func columns(_ server: Server) throws -> String {
        try server.exec(server.dialect == "pgsql"
            ? "SELECT column_name FROM information_schema.columns WHERE table_name = 'p13_items' ORDER BY ordinal_position"
            : "SELECT column_name FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = 'p13_items' ORDER BY ordinal_position")
    }

    static func tableExists(_ server: Server, _ table: String) throws -> Bool {
        try server.exec(server.dialect == "pgsql"
            ? "SELECT COUNT(*) FROM information_schema.tables WHERE table_name = '\(table)'"
            : "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = '\(table)'") != "0"
    }

    /// The fields of a server's DSN (host, port, dbname).
    static func fields(_ server: Server) -> [String: String] {
        var fields: [String: String] = [:]
        for part in server.dsn.drop(while: { $0 != ":" }).dropFirst().split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { fields[pair[0]] = pair[1] }
        }
        return fields
    }

    /// Statements MariaDB would commit Runlet's transaction with, as Laravel code, and what they
    /// start with: each is refused before it reaches the server.
    static let implicitCommits: [(code: String, sql: String)] = [
        ("DB::statement('ALTER TABLE p13_items ADD COLUMN extra INT NULL');", "ALTER TABLE p13_items"),
        ("Illuminate\\Support\\Facades\\Schema::create('p13_other', function ($table) { $table->id(); });", "create table `p13_other`"),
        ("DB::table('p13_items')->truncate();", "truncate table `p13_items`"),
        ("DB::statement('START TRANSACTION');", "START TRANSACTION"),
    ]

    @Test func implicitCommitsAreRefusedBeforeTheyRunOnMariaDB() async throws {
        let server = try #require(SQLLiveDatabaseTests.mysql, "set RUNLET_TEST_MYSQL")
        let project = try Self.project(server)
        defer { try? FileManager.default.removeItem(at: project) }
        for statement in Self.implicitCommits {
            try Self.seed(server)
            _ = try server.exec("DROP TABLE IF EXISTS p13_other")
            let events = try await RollbackSupport.run("""
                use Illuminate\\Support\\Facades\\DB;
                DB::table('p13_items')->insert(['name' => 'before']);
                \(statement.code)
                DB::table('p13_items')->insert(['name' => 'never']);
                """, in: project)
            // A normal error card at the snippet line, with Laravel's frames in its trace.
            let error = try #require(events.errors.first, "\(statement.sql)")
            #expect(error.className == "Runlet\\DryRunRefused", "\(error)")
            #expect(error.inSnippet == true && error.snippetLine == 3, "\(statement.sql): \(error)")
            #expect(error.message.hasPrefix("Dry run: Runlet refused \(statement.sql)"), "\(error.message)")
            #expect(error.message.contains("(line 3) on mariadb before it ran"), "\(error.message)")
            #expect(error.message.contains("Turn off Dry Run to run it."), "\(error.message)")
            #expect(error.trace?.first?.function?.hasPrefix("Illuminate\\Database\\") == true, "\(String(describing: error.trace))")
            #expect(events.stdout.isEmpty)
            // Recorded in the rollback report as `refused`; nothing was saved.
            let outcome = try #require(events.rollbackOutcome)
            #expect(outcome.reason == "error")
            #expect(outcome.warnings?.map(\.kind) == ["refused"], "\(outcome)")
            #expect(outcome.warnings?.first?.snippetLine == 3)
            #expect(outcome.warnings?.first?.sql?.hasPrefix(statement.sql) == true, "\(String(describing: outcome.warnings))")
            let connection = try #require(outcome.connections?.first)
            #expect(connection.status == .rolledBack, "\(connection)")
            #expect(connection.writes == 1 && connection.saved == 0, "\(connection)")
            #expect(outcome.title == "Rolled back 1 statement on mariadb")
            #expect(!outcome.hasProblems)
            #expect(try Self.columns(server) == "id\nname", "\(statement.sql)")
            #expect(try Self.names(server) == "alpha\nbeta\ngamma", "\(statement.sql)")
            #expect(try !Self.tableExists(server, "p13_other"), "\(statement.sql)")
        }
        // A temporary table commits nothing: it runs, and is rolled back like the rest.
        try Self.seed(server)
        let temporary = try await RollbackSupport.run("""
            use Illuminate\\Support\\Facades\\DB;
            DB::statement('CREATE TEMPORARY TABLE p13_scratch (id INT)');
            DB::table('p13_scratch')->insert(['id' => 1]);
            DB::table('p13_items')->insert(['name' => 'kept in the transaction']);
            return DB::table('p13_scratch')->count();
            """, in: project)
        #expect(temporary.errors.isEmpty, "\(temporary.errors)")
        #expect(temporary.result?.value?.scalar == "1")
        #expect(temporary.rollbackWarnings.isEmpty, "\(temporary.rollbackWarnings)")
        #expect(temporary.rollbackOutcome?.connections?.first?.status == .rolledBack)
        #expect(try Self.names(server) == "alpha\nbeta\ngamma")
    }

    @Test func schemaChangesAreRolledBackOnPostgreSQL() async throws {
        let server = try #require(SQLLiveDatabaseTests.pgsql, "set RUNLET_TEST_PGSQL")
        try Self.seed(server)
        _ = try server.exec("DROP TABLE IF EXISTS p13_other")
        let project = try Self.project(server)
        defer { try? FileManager.default.removeItem(at: project) }
        // PostgreSQL's DDL is transactional: nothing is refused, and everything is rolled back.
        let events = try await RollbackSupport.run("""
            use Illuminate\\Support\\Facades\\DB;
            DB::table('p13_items')->insert(['name' => 'before']);
            DB::statement('ALTER TABLE p13_items ADD COLUMN extra INT NULL');
            Illuminate\\Support\\Facades\\Schema::create('p13_other', function ($table) { $table->id(); });
            DB::table('p13_items')->insert(['name' => 'after']);
            DB::table('p13_items')->truncate();
            """, in: project)
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.rollbackWarnings.isEmpty, "\(events.rollbackWarnings)")
        let outcome = try #require(events.rollbackOutcome)
        #expect(outcome.connections?.first?.status == .rolledBack)
        #expect((outcome.statements ?? 0) >= 5, "\(outcome)")
        #expect(try Self.columns(server) == "id\nname")
        #expect(try Self.names(server) == "alpha\nbeta\ngamma")
        #expect(try !Self.tableExists(server, "p13_other"))
    }

    /// A project driver whose dry run wraps a plain PDO on `server`: Runlet sees its statements
    /// only after they run (watchPdo()), so an implicit commit is warned about, not refused.
    static func pdoProject(_ server: Server) throws -> URL {
        let directory = try DriverSupport.temporaryDirectory("rollback-live-pdo")
        try DriverSupport.write([".runlet/P13PdoDriver.php": """
        <?php
        class P13PdoDriver extends \\Runlet\\Driver
        {
            private $ledger;

            public function bootstrap(string $projectPath): void
            {
                $this->ledger = new PDO(\(RollbackSupport.php(server.dsn)), \(RollbackSupport.php(server.user)), \(RollbackSupport.php(server.password)), [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
            }

            public function variables(): array
            {
                return ['ledger' => $this->ledger];
            }

            public function rollbackConnections(): array
            {
                return ['ledger' => $this->ledger];
            }
        }
        """], into: directory)
        return directory
    }

    @Test func aPlainPDOStillWarnsAndReopensOnMariaDB() async throws {
        let server = try #require(SQLLiveDatabaseTests.mysql, "set RUNLET_TEST_MYSQL")
        try Self.seed(server)
        let project = try Self.pdoProject(server)
        defer { try? FileManager.default.removeItem(at: project) }
        let events = try await RollbackSupport.run("""
            $ledger->prepare('INSERT INTO p13_items (name) VALUES (?)')->execute(['before']);
            $ledger->prepare('ALTER TABLE p13_items ADD COLUMN extra INT NULL')->execute();
            $ledger->prepare('INSERT INTO p13_items (name) VALUES (?)')->execute(['after']);
            """, in: project)
        #expect(events.errors.isEmpty, "\(events.errors)")
        // MariaDB commits the ALTER (and the INSERT before it) at once; Runlet says so on the
        // line, begins a new transaction, and rolls back what follows.
        let warning = try #require(events.rollbackWarnings.first)
        #expect(warning.kind == "implicitCommit")
        #expect(warning.snippetLine == 2)
        #expect(warning.message.contains("committed the transaction on ledger"), "\(warning.message)")
        #expect(warning.message.contains("Runlet began a new transaction right after it"), "\(warning.message)")
        let outcome = try #require(events.rollbackOutcome)
        let connection = try #require(outcome.connections?.first)
        #expect(connection.api == "pdo")
        #expect(connection.status == .rolledBack)
        #expect(connection.writes == 3 && connection.saved == 2, "\(connection)")
        #expect(connection.commits?.first?.reopened == true)
        #expect(outcome.title == "Rolled back 1 statement on ledger · 2 statements saved")
        #expect(try Self.columns(server) == "id\nname\nextra")
        #expect(try Self.names(server) == "alpha\nbeta\ngamma\nbefore")
    }

    /// A project driver with a Doctrine DBAL connection to `server`, from `fixture`'s vendor
    /// (eloquent-app: DBAL 3, eloquent-app-modern: DBAL 4).
    static func doctrineProject(_ server: Server, fixture: String) throws -> URL {
        let fields = Self.fields(server)
        let directory = try DriverSupport.temporaryDirectory("rollback-live-doctrine")
        try DriverSupport.write([".runlet/P13DoctrineDriver.php": """
        <?php
        class P13DoctrineDriver extends \\Runlet\\Driver
        {
            private $reports;

            public function bootstrap(string $projectPath): void
            {
                require_once \(RollbackSupport.php(DriverSupport.fixture(fixture) + "/vendor/autoload.php"));
                $this->reports = \\Doctrine\\DBAL\\DriverManager::getConnection([
                    'driver' => 'pdo_mysql', 'host' => \(RollbackSupport.php(fields["host"] ?? "127.0.0.1")), 'port' => \(Int(fields["port"] ?? "3306") ?? 3306),
                    'dbname' => \(RollbackSupport.php(fields["dbname"] ?? "")), 'user' => \(RollbackSupport.php(server.user)), 'password' => \(RollbackSupport.php(server.password)),
                ]);
            }

            public function variables(): array
            {
                return ['reports' => $this->reports];
            }

            public function inspect(\\Runlet\\Inspector $inspector): void
            {
                $this->inspectDoctrine($inspector, $this->reports, 'reports');
            }

            public function rollbackConnections(): array
            {
                return ['reports' => $this->reports];
            }
        }
        """], into: directory)
        return directory
    }

    @Test func doctrineRefusesImplicitCommitsOnMariaDB() async throws {
        let server = try #require(SQLLiveDatabaseTests.mysql, "set RUNLET_TEST_MYSQL")
        // DBAL 3 through its SQL logger (PHP 8 and 7.4), DBAL 4 through Runlet's middleware.
        var runs: [(fixture: String, php: String?)] = []
        if FileManager.default.fileExists(atPath: DriverSupport.fixture("eloquent-app") + "/vendor") {
            runs.append(("eloquent-app", nil))
            if let php74 = TestSupport.herdPHP74 { runs.append(("eloquent-app", php74)) }
        }
        if FileManager.default.fileExists(atPath: DriverSupport.fixture("eloquent-app-modern") + "/vendor") {
            runs.append(("eloquent-app-modern", nil))
        }
        #expect(!runs.isEmpty, "needs Tests/Fixtures/eloquent-app/vendor or eloquent-app-modern/vendor")
        for run in runs {
            let label = "\(run.fixture) \(run.php ?? "php")"
            try Self.seed(server)
            let project = try Self.doctrineProject(server, fixture: run.fixture)
            defer { try? FileManager.default.removeItem(at: project) }
            var request = RollbackSupport.request("""
                $reports->executeStatement("INSERT INTO p13_items (name) VALUES ('before')");
                $reports->executeStatement('ALTER TABLE p13_items ADD COLUMN extra INT NULL');
                $reports->executeStatement("INSERT INTO p13_items (name) VALUES ('never')");
                """, in: project)
            request.target = DriverSupport.target(project.path, php: run.php)
            let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
            var events: [RunEvent] = []
            for await event in try await engine.start(request) { events.append(event) }
            let error = try #require(events.errors.first, "\(label)")
            #expect(error.className == "Runlet\\DryRunRefused", "\(label): \(error)")
            #expect(error.snippetLine == 2, "\(label): \(error)")
            #expect(error.message.contains("ALTER TABLE p13_items ADD COLUMN extra INT NULL (line 2) on reports before it ran"), "\(label): \(error.message)")
            let outcome = try #require(events.rollbackOutcome, "\(label)")
            #expect(outcome.warnings?.map(\.kind) == ["refused"], "\(label): \(outcome)")
            #expect(outcome.connections?.first?.status == .rolledBack, "\(label): \(outcome)")
            #expect(outcome.connections?.first?.saved == 0, "\(label): \(outcome)")
            #expect(try Self.columns(server) == "id\nname", "\(label)")
            #expect(try Self.names(server) == "alpha\nbeta\ngamma", "\(label)")
        }
    }

    @Test func stopLeavesNothingCommitted() async throws {
        for server in SQLLiveDatabaseTests.servers {
            try Self.seed(server)
            let project = try Self.project(server)
            defer { try? FileManager.default.removeItem(at: project) }
            let marker = project.appendingPathComponent("inserted")
            let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
            let request = RollbackSupport.request("""
                use Illuminate\\Support\\Facades\\DB;
                DB::table('p13_items')->insert(['name' => 'stopped']);
                DB::table('p13_items')->where('name', 'alpha')->update(['name' => 'ALPHA']);
                file_put_contents(\(RollbackSupport.php(marker.path)), 'x');
                sleep(60);
                """, in: project)
            let stream = try await engine.start(request)
            let collector = Task {
                var events: [RunEvent] = []
                for await event in stream { events.append(event) }
                return events
            }
            let deadline = ContinuousClock.now + .seconds(30)
            while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(FileManager.default.fileExists(atPath: marker.path), "\(server.dialect): the snippet never got to sleep")
            // Uncommitted while the run sleeps: other sessions don't see the changes.
            #expect(try Self.names(server) == "alpha\nbeta\ngamma", "\(server.dialect)")
            let outcome = await engine.cancel(runId: request.runId)
            #expect(outcome?.confirmed == true, "\(server.dialect): \(String(describing: outcome))")
            let events = await collector.value
            #expect(events.finished?.status == .cancelled)
            #expect(events.rollbackReports.map(\.state) == [.begun], "the runner never got to roll back")
            // The server discarded the transaction when the connection closed.
            var names = ""
            for _ in 0..<40 {
                names = try Self.names(server)
                if names == "alpha\nbeta\ngamma" { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(names == "alpha\nbeta\ngamma", "\(server.dialect)")
        }
    }
}
