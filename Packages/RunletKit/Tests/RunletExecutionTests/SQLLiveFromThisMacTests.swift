import Foundation
@testable import RunletCore
import Testing
@testable import RunletExecution

/// Saved connections opened from this Mac (#142), against the live MariaDB and PostgreSQL
/// fixtures through their published ports, as `SQLLiveDatabaseTests` does through host PHP:
/// Test Connection (which PHP, its drivers), a statement with a bound value, Run All, Load
/// Schema, Explain, Load Next, read-only, and a wrong password, each through
/// `LocalConnectionLaunch`'s snapshot (an empty folder of Runlet's, the plain bootstrap). The
/// connection is one of all targets, so it is the sandbox's too. With `RUNLET_TEST_RUNLET_PHP`,
/// the same runs use Runlet's own PHP as well. Tables are `p142_*`, created idempotently.
@Suite(.serialized, .enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct SQLLiveFromThisMacTests {
    static var servers: [SQLLiveDatabaseTests.Server] { SQLLiveDatabaseTests.servers }

    /// Host PHP, and Runlet's PHP when the environment names one.
    static var phps: [LocalConnectionLaunch.PHP] {
        [LocalConnectionLaunch.PHP(path: DriverSupport.php, label: "host PHP", isRunletPHP: false)]
            + (TestSupport.runletPHP.map { [LocalConnectionLaunch.PHP(path: $0, label: "Runlet's PHP", isRunletPHP: true)] } ?? [])
    }

    static func setup(_ server: SQLLiveDatabaseTests.Server) throws {
        let mysql = server.dialect == "mysql"
        for statement in [
            mysql
                ? "CREATE TABLE IF NOT EXISTS p142_orders (id INT PRIMARY KEY, status VARCHAR(20) NOT NULL, total DECIMAL(10,2)) ENGINE=InnoDB"
                : "CREATE TABLE IF NOT EXISTS p142_orders (id INT PRIMARY KEY, status VARCHAR(20) NOT NULL, total NUMERIC(10,2))",
            "DELETE FROM p142_orders",
            "INSERT INTO p142_orders (id, status, total) VALUES (1, 'paid', 10.50), (2, 'pending', 20), (3, 'paid', 7)",
        ] { _ = try server.exec(statement) }
    }

    /// The server as a saved connection of all targets, its password in memory.
    static func connection(_ server: SQLLiveDatabaseTests.Server, readOnly: Bool = false, password: String? = nil) -> (DatabaseConnection, InMemoryCredentialStore) {
        let (target, store) = SQLLiveDatabaseTests.saved(server, password: password)
        var connection = target
        connection.scope = nil
        connection.name = "Analytics"
        connection.readOnly = readOnly
        return (connection.normalized, store)
    }

    struct Place {
        var engine: ExecutionEngine
        var target: TargetSnapshot
        var folder: URL
        var root: URL
    }

    static func place(_ connection: DatabaseConnection, store: InMemoryCredentialStore, php: LocalConnectionLaunch.PHP) throws -> Place {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-p142-\(UUID().uuidString)", isDirectory: true)
        let folder = try LocalConnectionLaunch.directory(in: AppPaths(root: root))
        return Place(engine: ExecutionEngine(bundle: TestSupport.bundle, docker: nil, credentials: store), target: LocalConnectionLaunch.snapshot(connection: connection, php: php, directory: folder), folder: folder, root: root)
    }

    static func run(_ code: String, _ connection: DatabaseConnection, at place: Place) async throws -> [RunEvent] {
        var request = RunRequest(tabId: UUID(), documentVersion: 1, target: place.target, code: code, magicComments: false)
        request.sqlConnection = connection
        var events: [RunEvent] = []
        for await event in try await place.engine.start(request) { events.append(event) }
        return events
    }

    @Test(.enabled(if: !servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func everySQLActionFromThisMac() async throws {
        for server in Self.servers {
            try Self.setup(server)
            for php in Self.phps {
                let label = "\(server.dialect) via \(php.label)"
                let (connection, store) = Self.connection(server)
                let place = try Self.place(connection, store: store, php: php)
                defer { try? FileManager.default.removeItem(at: place.root) }
                #expect(place.target.label == "Analytics · this Mac (\(php.label))")

                // Test Connection: the server, and the PHP's drivers.
                let info = try await place.engine.testSQLConnection(target: place.target, connection: connection, password: .stored)
                #expect(info.driver == server.dialect && info.serverVersion != nil, "\(label): \(info)")
                #expect(info.pdoDrivers?.contains(server.dialect) == true, "\(label): \(info.pdoDrivers ?? [])")

                // A statement with a bound value, and the schema on the first run.
                let select = try await Self.run(SQLTabRun.code(statement: "SELECT id, status FROM p142_orders WHERE status = :status ORDER BY id", connection: nil, schema: true, bindings: [SQLBinding(target: .name("status"), value: .text("paid"))]), connection, at: place)
                #expect(select.errors.isEmpty, "\(label): \(select.errors)")
                #expect(select.sqlResult?.rows.map { $0.first } == [.int(1), .int(3)], "\(label): \(select.sqlResult?.rows ?? [])")
                #expect(select.sqlResult?.saved == true && select.bootstrapped?.framework == "plain", "\(label)")
                #expect(select.sqlSchema?.table(named: "p142_orders") != nil, "\(label)")

                // Run All in one transaction.
                let script = "UPDATE p142_orders SET total = total + 1 WHERE id = 2;\nSELECT total FROM p142_orders WHERE id = 2;"
                let statements = try SQLScript.statementsToRunAll(in: script, selection: NSRange(location: 0, length: 0)).get()
                let all = try await Self.run(SQLTabRun.scriptCode(statements: statements, connection: nil, transaction: true), connection, at: place)
                #expect(all.errors.isEmpty && all.sqlResults.first?.affectedRows == 1, "\(label): \(all.errors)")

                // Load Schema, Explain, and Load Next.
                let schema = try await place.engine.loadSQLSchema(target: place.target, connection: nil, saved: connection)
                #expect(schema.table(named: "p142_orders")?.columns.map(\.name) == ["id", "status", "total"], "\(label)")
                let explain = try await Self.run(SQLExplain.code(statement: "SELECT * FROM p142_orders WHERE id = 1", connection: nil, mode: .plan), connection, at: place)
                #expect(explain.errors.isEmpty && explain.sqlPlan != nil, "\(label): \(explain.errors)")
                let plan = try SQLPaging.plan(for: "SELECT id FROM p142_orders ORDER BY id", driver: server.dialect).get()
                let page = try await Self.run(SQLTabRun.pageCode(plan.page(offset: 1, size: 1), connection: nil), connection, at: place)
                #expect(page.sqlResult?.rows == [[.int(2)]], "\(label): \(page.errors) \(page.sqlResult?.rows ?? [])")

                // Nothing was written to Runlet's folder.
                #expect(try FileManager.default.contentsOfDirectory(atPath: place.folder.path).isEmpty, "\(label)")
            }
        }
    }

    @Test(.enabled(if: !servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func readOnlyAndAWrongPasswordFromThisMac() async throws {
        for server in Self.servers {
            try Self.setup(server)
            let php = Self.phps[0]
            let (readOnly, store) = Self.connection(server, readOnly: true)
            let place = try Self.place(readOnly, store: store, php: php)
            defer { try? FileManager.default.removeItem(at: place.root) }
            // The database refuses the write in the read-only session (past Runlet's own check).
            let write = try await Self.run(SQLTabRun.code(statement: "DELETE FROM p142_orders", connection: nil), readOnly, at: place)
            #expect(!write.errors.isEmpty, "\(server.dialect): a read-only session refuses writes")
            #expect(try server.exec("SELECT COUNT(*) FROM p142_orders") == "3", "\(server.dialect)")

            let wrong = "p142-wrong-Pw!"
            let (denied, deniedStore) = Self.connection(server, password: wrong)
            let deniedPlace = try Self.place(denied, store: deniedStore, php: php)
            defer { try? FileManager.default.removeItem(at: deniedPlace.root) }
            let failed = try await Self.run(SQLTabRun.code(statement: "SELECT 1", connection: nil), denied, at: deniedPlace)
            #expect(!failed.errors.isEmpty, "\(server.dialect)")
            #expect(!failed.scannableText.contains { $0.contains(wrong) }, "\(server.dialect): the password appears in no event")
        }
    }
}
