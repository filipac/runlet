import Foundation
@testable import RunletCore
import Testing
@testable import RunletExecution

/// Rollback ("dry run") mode (#13) on live MariaDB and PostgreSQL, through the laravel-app
/// fixture booted with the server's DB_* settings. They run only when `RUNLET_TEST_MYSQL` /
/// `RUNLET_TEST_PGSQL` are set (`scripts/setup-fixtures.sh databases`), and use `p13_` tables.
@Suite(.serialized, .enabled(if: TestSupport.hasPHP && RollbackSupport.hasLaravel && !SQLLiveDatabaseTests.servers.isEmpty,
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

    @Test func schemaChanges() async throws {
        for server in SQLLiveDatabaseTests.servers {
            try Self.seed(server)
            let project = try Self.project(server)
            defer { try? FileManager.default.removeItem(at: project) }
            let events = try await RollbackSupport.run("""
                use Illuminate\\Support\\Facades\\DB;
                DB::table('p13_items')->insert(['name' => 'before']);
                DB::statement('ALTER TABLE p13_items ADD COLUMN extra INT NULL');
                DB::table('p13_items')->insert(['name' => 'after']);
                """, in: project)
            #expect(events.errors.isEmpty, "\(server.dialect): \(events.errors)")
            let outcome = try #require(events.rollbackOutcome)
            let columns = try server.exec(server.dialect == "pgsql"
                ? "SELECT column_name FROM information_schema.columns WHERE table_name = 'p13_items' ORDER BY ordinal_position"
                : "SELECT column_name FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = 'p13_items' ORDER BY ordinal_position")
            if server.dialect == "pgsql" {
                // PostgreSQL's DDL is transactional: everything is rolled back.
                #expect(events.rollbackWarnings.isEmpty, "\(events.rollbackWarnings)")
                #expect(outcome.statements == 3)
                #expect(columns == "id\nname")
                #expect(try Self.names(server) == "alpha\nbeta\ngamma")
            } else {
                // MariaDB commits the ALTER (and the INSERT before it) at once; Runlet says so on the
                // line, begins a new transaction, and rolls back what follows.
                let warning = try #require(events.rollbackWarnings.first)
                #expect(warning.kind == "implicitCommit")
                #expect(warning.snippetLine == 3)
                #expect(warning.message.contains("committed the transaction on mariadb"), "\(warning.message)")
                #expect(warning.message.contains("Runlet began a new transaction right after it"), "\(warning.message)")
                let connection = try #require(outcome.connections?.first)
                #expect(connection.status == .rolledBack)
                #expect(connection.writes == 3 && connection.saved == 2, "\(connection)")
                #expect(connection.commits?.first?.reopened == true)
                #expect(outcome.title == "Rolled back 1 statement on mariadb · 2 statements saved")
                #expect(columns == "id\nname\nextra")
                #expect(try Self.names(server) == "alpha\nbeta\ngamma\nbefore")
            }
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
