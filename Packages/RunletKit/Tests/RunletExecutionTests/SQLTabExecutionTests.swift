import Foundation
import RunletCore
import Testing
@testable import RunletExecution

extension Array where Element == RunEvent {
    /// The `sql` event of an SQL tab's run (#35).
    var sqlResult: SQLResultInfo? {
        for event in self { if case .sql(let info) = event.kind { return info } }
        return nil
    }
}

/// SQL tabs (#35) against real fixtures: the generated PHP, connection resolution (the
/// project driver first, then the built-in framework connections, then a clear refusal),
/// result sets, affected rows, and limits.
@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct SQLTabExecutionTests {
    static func ready(_ fixture: String) -> Bool {
        FileManager.default.fileExists(atPath: TestSupport.fixtures.appendingPathComponent("\(fixture)/vendor/autoload.php").path)
    }

    func run(_ sql: String, connection: String? = nil, maxRows: Int = SQLTabRun.defaultMaxRows, in directory: String) async throws -> [RunEvent] {
        try await TestSupport.run(SQLTabRun.code(statement: sql, connection: connection, maxRows: maxRows), target: DriverSupport.target(directory), magicComments: false)
    }

    /// A temporary project whose entries link to `fixture`, except the copied ones (a database
    /// the test may change) and `.runlet`, replaced by `drivers` when given.
    func scratchProject(_ fixture: String, copying copied: [String] = [], drivers: [String: String]? = nil, keepDrivers: Bool = true) throws -> URL {
        let directory = try DriverSupport.temporaryDirectory("sql-\(fixture)")
        let source = TestSupport.fixtures.appendingPathComponent(fixture)
        for entry in try FileManager.default.contentsOfDirectory(atPath: source.path) {
            if entry == ".runlet", drivers != nil || !keepDrivers { continue }
            if copied.contains(entry) {
                try FileManager.default.copyItem(at: source.appendingPathComponent(entry), to: directory.appendingPathComponent(entry))
            } else {
                try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(entry), withDestinationURL: source.appendingPathComponent(entry))
            }
        }
        if let drivers { try DriverSupport.write(drivers, into: directory.appendingPathComponent(".runlet")) }
        return directory
    }

    // MARK: Project drivers

    @Test func projectDriverProvidesAPDOAndACallable() async throws {
        let fixture = DriverSupport.fixture("custom-driver")
        let select = try await run("SELECT id, tenant, rent FROM leases ORDER BY id", in: fixture)
        #expect(select.errors.isEmpty, "\(select.errors)")
        let rows = try #require(select.sqlResult)
        #expect(rows.columns == ["id", "tenant", "rent"])
        #expect(rows.rows.map { $0[1] } == [.string("Ada"), .string("Grace"), .string("Linus")])
        #expect(rows.rows.first?.first == .int(1))
        #expect(rows.driver == "sqlite")
        #expect(rows.source == "AcmeApiDriver::sqlConnection()")
        #expect(rows.connections == ["main", "archive"])
        #expect(rows.connection == nil)
        #expect(rows.elapsedMs != nil)
        #expect(select.result?.hasValue == false)

        let update = try await run("UPDATE leases SET rent = rent + 10 WHERE rent > 1000", connection: "main", in: fixture)
        #expect(update.errors.isEmpty, "\(update.errors)")
        #expect(update.sqlResult?.affectedRows == 2)
        #expect(update.sqlResult?.hasResultSet == false)
        #expect(update.sqlResult?.connection == "main")

        let callable = try await run("SELECT tenant FROM leases WHERE rent < 1000", connection: "archive", in: fixture)
        #expect(callable.errors.isEmpty, "\(callable.errors)")
        #expect(callable.sqlResult?.columns == ["tenant"])
        #expect(callable.sqlResult?.rows == [[.string("Grace")]])
        #expect(callable.sqlResult?.driver == nil)
        let callableUpdate = try await run("DELETE FROM leases", connection: "archive", in: fixture)
        #expect(callableUpdate.sqlResult?.affectedRows == 3)

        // A driver's own error names the driver file and method.
        let unknown = try await run("SELECT 1", connection: "nope", in: fixture)
        #expect(unknown.sqlResult == nil)
        let error = try #require(unknown.errors.first)
        #expect(error.message.contains("AcmeApiDriver (.runlet/AcmeApiDriver.php) failed in sqlConnection()"), "\(error.message)")
        #expect(error.message.contains(#"Acme has no "nope" database."#))
    }

    @Test(.enabled(if: TestSupport.herdPHP74 != nil, "requires Herd's PHP 7.4"))
    func runsOnPHP74() async throws {
        let events = try await TestSupport.run(SQLTabRun.code(statement: "SELECT tenant FROM leases WHERE rent > 1000 ORDER BY id", connection: "archive"),
                                               target: DriverSupport.target(DriverSupport.fixture("custom-driver"), php: TestSupport.herdPHP74!), magicComments: false)
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.started?.phpVersion?.hasPrefix("7.4") == true)
        #expect(events.sqlResult?.rows == [[.string("Ada")], [.string("Linus")]])
    }

    @Test func statementTextReachesTheDatabaseUnchanged() async throws {
        let text = #"it's $x \ "q" {$y} 💡"#
        let events = try await run(#"SELECT 'it''s $x \ "q" {$y} 💡' AS "text", 1 AS id, 2 AS id"#, in: DriverSupport.fixture("custom-driver"))
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.sqlResult?.rows == [[.string(text), .int(1), .int(2)]])
        // Duplicate column names are kept as separate columns.
        #expect(events.sqlResult?.columns == ["text", "id", "id"])
    }

    @Test func largeResultsAreCappedAndCellsBounded() async throws {
        let sql = """
        WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 50)
        SELECT i, x'00FF10' AS bytes, printf('%9000s', 'x') AS long, NULL AS empty, 1.5 AS price FROM n
        """
        let events = try await run(sql, maxRows: 10, in: DriverSupport.fixture("custom-driver"))
        #expect(events.errors.isEmpty, "\(events.errors)")
        let result = try #require(events.sqlResult)
        #expect(result.rows.count == 10)
        #expect(result.truncated == true)
        #expect(result.truncation == "rows")
        #expect(result.maxRows == 10)
        #expect(result.summary == "First 10 rows (more not shown)")
        let row = try #require(result.rows.first)
        #expect(row[1] == .binary(bytes: 3, hexPrefix: "00FF10"))
        if case .clipped(let text, let omitted) = row[2] {
            #expect(text.utf8.count == 8192)
            #expect(omitted == 9000 - 8192)
        } else {
            Issue.record("expected a clipped cell, got \(row[2])")
        }
        #expect(row[3] == .null)
        #expect(row[4] == .double(1.5))
        // Exactly the cap: not truncated.
        let exact = try await run("SELECT 1 UNION ALL SELECT 2", maxRows: 2, in: DriverSupport.fixture("custom-driver"))
        #expect(exact.sqlResult?.truncated == nil)
    }

    // MARK: Built-in framework connections

    @Test(.enabled(if: ready("laravel-app"), "requires scripts/setup-fixtures.sh"))
    func laravelUsesTheApplicationsConnections() async throws {
        let directory = try scratchProject("laravel-app", copying: ["database"], keepDrivers: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let select = try await run("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'widgets'", in: directory.path)
        #expect(select.errors.isEmpty, "\(select.errors)")
        let result = try #require(select.sqlResult)
        #expect(result.rows == [[.string("widgets")]])
        #expect(result.source == "Laravel DB::connection()")
        #expect(result.driver == "sqlite")
        #expect(result.connections?.first == "sqlite")
        #expect(result.connections?.contains("mysql") == true)

        let update = try await run("UPDATE widgets SET price = price", connection: "sqlite", in: directory.path)
        #expect(update.errors.isEmpty, "\(update.errors)")
        #expect((update.sqlResult?.affectedRows ?? 0) > 0)

        let unknown = try await run("SELECT 1", connection: "nope", in: directory.path)
        let error = try #require(unknown.errors.first)
        #expect(error.className == "RunletRunner\\SqlConnectionFailed")
        #expect(error.message.contains(#"Runlet could not open the "nope" connection: Database connection [nope] not configured."#), "\(error.message)")
        #expect(error.message.contains("Connections: sqlite, "))
        #expect(error.previous?.className == "InvalidArgumentException")

        let failing = try await run("SELECT * FROM no_such_table", in: directory.path)
        #expect(failing.errors.first?.message.contains("no such table") == true, "\(failing.errors)")
    }

    @Test(.enabled(if: ready("laravel-app"), "requires scripts/setup-fixtures.sh"))
    func projectDriverConnectionWinsOverTheBuiltInOne() async throws {
        // TenantDriver extends LaravelDriver: its default connection is the tenant's own
        // database; named connections still come from the built-in Laravel driver.
        let directory = try scratchProject("laravel-app", copying: ["database"], keepDrivers: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(at: TestSupport.fixtures.appendingPathComponent("custom-laravel-driver/.runlet"), to: directory.appendingPathComponent(".runlet"))

        let tenant = try await run("SELECT tenant, plan FROM tenant_settings", in: directory.path)
        #expect(tenant.errors.isEmpty, "\(tenant.errors)")
        #expect(tenant.sqlResult?.rows == [[.string("acme"), .string("gold")]])
        #expect(tenant.sqlResult?.source == "TenantDriver::sqlConnection()")
        #expect(tenant.sqlResult?.connections?.first == "sqlite")

        let laravel = try await run("SELECT COUNT(*) AS widgets FROM widgets", connection: "sqlite", in: directory.path)
        #expect(laravel.errors.isEmpty, "\(laravel.errors)")
        #expect(laravel.sqlResult?.source == "TenantDriver::sqlConnection()")
        #expect(laravel.sqlResult?.columns == ["widgets"])
        let missing = try await run("SELECT * FROM tenant_settings", connection: "sqlite", in: directory.path)
        #expect(missing.errors.first?.message.contains("no such table: tenant_settings") == true, "\(missing.errors)")
    }

    @Test(.enabled(if: ready("eloquent-app"), "requires scripts/setup-fixtures.sh"))
    func eloquentWithoutLaravelIsFoundAutomatically() async throws {
        // ShopDriver has no sqlConnection(): Runlet uses the Capsule connection resolver.
        let fixture = DriverSupport.fixture("eloquent-app")
        let select = try await run("SELECT name FROM customers ORDER BY id", in: fixture)
        #expect(select.errors.isEmpty, "\(select.errors)")
        #expect(select.sqlResult?.rows == [[.string("Ada")], [.string("Grace")], [.string("Linus")]])
        #expect(select.sqlResult?.source == "Eloquent connection resolver")
        #expect(select.sqlResult?.connections == nil)
        let update = try await run("UPDATE orders SET total = total + 1 WHERE total = 50", in: fixture)
        #expect(update.sqlResult?.affectedRows == 3)
    }

    @Test(.enabled(if: ["eloquent-app", "eloquent-app-modern"].allSatisfy(ready), "requires the Eloquent/DBAL 3/4 fixtures"))
    func doctrineConnectionsThroughTheHelper() async throws {
        let driver = """
        <?php
        use Runlet\\SqlConnections;

        class ReportsDriver extends \\Runlet\\Driver
        {
            private $container;

            public function bootstrap(string $projectPath): void
            {
                $this->container = require $projectPath . '/config/bootstrap.php';
            }

            public function sqlConnection(?string $connection)
            {
                return SqlConnections::doctrine($this->container->get('reports'));
            }
        }
        """
        for fixture in ["eloquent-app", "eloquent-app-modern"] {
            let directory = try scratchProject(fixture, drivers: ["ReportsDriver.php": driver])
            defer { try? FileManager.default.removeItem(at: directory) }
            let events = try await run("SELECT name FROM reports ORDER BY id", in: directory.path)
            #expect(events.errors.isEmpty, "\(fixture): \(events.errors)")
            #expect(events.sqlResult?.rows == [[.string("daily")], [.string("weekly")]], "\(fixture)")
            #expect(events.sqlResult?.source == "ReportsDriver::sqlConnection()")
            let insert = try await run("INSERT INTO reports (name) VALUES ('monthly')", in: directory.path)
            #expect(insert.sqlResult?.affectedRows == 1, "\(fixture): \(insert.errors)")
        }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: TestSupport.fixtures.appendingPathComponent("wordpress/.runlet-fixture-ready").path), "requires the WordPress SQLite fixture"))
    func wordpressUsesItsOwnPDOAndWpdbByName() async throws {
        let fixture = DriverSupport.fixture("wordpress")
        // #208: the SQLite drop-in's file, through PDO.
        let select = try await run("-- the site name\nSELECT option_value FROM rl_options WHERE option_name = 'blogname'", in: fixture)
        #expect(select.errors.isEmpty, "\(select.errors)")
        #expect(select.sqlResult?.columns == ["option_value"])
        #expect(select.sqlResult?.rows.count == 1)
        #expect(select.sqlResult?.source == "WordPress (PDO from wp-config)")
        // The `wpdb` connection runs through $wpdb->query().
        let wpdb = try await run("-- the site name\nSELECT option_value FROM rl_options WHERE option_name = 'blogname'", connection: "wpdb", in: fixture)
        #expect(wpdb.errors.isEmpty, "\(wpdb.errors)")
        #expect(wpdb.sqlResult?.rows == select.sqlResult?.rows)
        #expect(wpdb.sqlResult?.source == "WordPress $wpdb")
        let named = try await run("SELECT 1", connection: "replica", in: fixture)
        #expect(named.errors.first?.message.contains("WordPress has one database connection") == true, "\(named.errors)")
    }

    // MARK: Unsupported targets

    @Test func projectsWithoutAConnectionSaySoInsteadOfGuessing() async throws {
        var fixtures = [DriverSupport.fixture("plain"), DriverSupport.fixture("composer")]
        if Self.ready("symfony-app") { fixtures.append(DriverSupport.fixture("symfony-app")) } // no DoctrineBundle
        for fixture in fixtures {
            let events = try await run("SELECT 1", in: fixture)
            #expect(events.sqlResult == nil)
            let error = try #require(events.errors.first, "\(fixture)")
            #expect(error.className == "RunletRunner\\SqlUnavailable", "\(fixture): \(error)")
            #expect(error.message.contains("has no database connection that SQL tabs can use"))
            #expect(error.message.contains("save a connection for this target"))
            #expect(error.message.contains("New Connection…"))
            #expect(error.message.contains("sqlConnection()"))
        }
    }
}
