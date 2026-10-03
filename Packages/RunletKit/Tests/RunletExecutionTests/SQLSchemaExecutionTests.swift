import Foundation
import RunletCore
import Testing
@testable import RunletExecution

extension Array where Element == RunEvent {
    /// The `sqlSchema` event of a run (#128).
    var sqlSchema: SQLSchemaInfo? {
        for event in self { if case .sqlSchema(let info) = event.kind { return info } }
        return nil
    }
}

/// SQL completion's schema (#128) per connection kind: a project driver's PDO and callable,
/// its own `sqlSchema()`, Laravel, Eloquent through Capsule, Doctrine DBAL, and WordPress's
/// `$wpdb`. Only names and types are read.
@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct SQLSchemaExecutionTests {
    func load(_ directory: String, connection: String? = nil) async throws -> SQLSchemaInfo {
        try await ExecutionEngine(bundle: TestSupport.bundle, docker: nil).loadSQLSchema(target: DriverSupport.target(directory), connection: connection)
    }

    func columns(_ schema: SQLSchemaInfo, _ table: String) -> [String]? {
        schema.table(named: table)?.columns.map(\.name)
    }

    @Test func projectDriverPDOAndCallable() async throws {
        let fixture = DriverSupport.fixture("custom-driver")
        let pdo = try await load(fixture)
        #expect(pdo.driver == "sqlite")
        #expect(pdo.how == "sqlite_master")
        #expect(pdo.source == "AcmeApiDriver::sqlConnection()")
        #expect(columns(pdo, "leases") == ["id", "tenant", "rent"])
        #expect(pdo.table(named: "leases")?.columns.first?.type == "integer")
        #expect(pdo.error == nil && pdo.truncated == nil)

        // A callable: Runlet tries the catalogs in turn; SQLite's answers.
        let callable = try await load(fixture, connection: "archive")
        #expect(callable.how == "sqlite_master")
        #expect(callable.driver == nil)
        #expect(columns(callable, "leases") == ["id", "tenant", "rent"])

        // An unknown connection is the driver's own error.
        await #expect(throws: SQLSchemaLoadError.self) { try await load(fixture, connection: "nope") }
    }

    @Test func aDriversOwnSchemaWins() async throws {
        let driver = """
        <?php
        class CatalogDriver extends \\Runlet\\Driver
        {
            public function bootstrap(string $projectPath): void
            {
            }

            public function sqlConnection(?string $connection)
            {
                return static function (string $sql) {
                    throw new \\RuntimeException('This API runs no catalog queries.');
                };
            }

            public function sqlSchema(?string $connection): ?array
            {
                return ['invoices' => ['id' => 'uuid', 'amount' => 'money'], 'tags' => ['name'], 'empty' => []];
            }
        }
        """
        let directory = try DriverSupport.composerProject(drivers: ["CatalogDriver.php": driver])
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = try await load(directory.path)
        #expect(schema.how == "CatalogDriver::sqlSchema()")
        #expect(schema.tables.map(\.name) == ["invoices", "tags", "empty"])
        #expect(schema.table(named: "invoices")?.columns == [.init(name: "id", type: "uuid"), .init(name: "amount", type: "money")])
        #expect(columns(schema, "tags") == ["name"])
        #expect(columns(schema, "empty") == [])
    }

    @Test func aCallableWithoutACatalogSaysHowToFixIt() async throws {
        let driver = """
        <?php
        class OpaqueDriver extends \\Runlet\\Driver
        {
            public function bootstrap(string $projectPath): void
            {
            }

            public function sqlConnection(?string $connection)
            {
                return static function (string $sql) {
                    throw new \\RuntimeException('unsupported');
                };
            }
        }
        """
        let directory = try DriverSupport.composerProject(drivers: ["OpaqueDriver.php": driver])
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await load(directory.path)
            Issue.record("expected an error")
        } catch let error as SQLSchemaLoadError {
            #expect(error.description.contains("Runlet could not read the schema: unsupported"), "\(error)")
            #expect(error.description.contains("sqlSchema()"))
        }
        // Projects without a connection say so, as statements do.
        await #expect(throws: SQLSchemaLoadError.self) { try await load(DriverSupport.fixture("plain")) }
    }

    @Test func aStatementCanBringTheSchemaAlong() async throws {
        let fixture = DriverSupport.fixture("custom-driver")
        let run = try await TestSupport.run(SQLTabRun.code(statement: "SELECT COUNT(*) FROM leases", connection: nil, schema: true), target: DriverSupport.target(fixture), magicComments: false)
        #expect(run.errors.isEmpty, "\(run.errors)")
        #expect(run.sqlResult?.rows == [[.int(3)]])
        #expect(run.sqlSchema.flatMap { columns($0, "leases") } == ["id", "tenant", "rent"])
        // Not asked: not read.
        let plain = try await TestSupport.run(SQLTabRun.code(statement: "SELECT 1", connection: nil), target: DriverSupport.target(fixture), magicComments: false)
        #expect(plain.sqlSchema == nil)
        // A failing statement brings no schema; Run All brings it after the last statement.
        let failed = try await TestSupport.run(SQLTabRun.code(statement: "SELECT * FROM nope", connection: nil, schema: true), target: DriverSupport.target(fixture), magicComments: false)
        #expect(failed.sqlSchema == nil)
        let script = try await TestSupport.run(SQLTabRun.scriptCode(statements: SQLScript.statements(in: "SELECT 1; SELECT 2"), connection: "archive", transaction: false, schema: true),
                                               target: DriverSupport.target(fixture), magicComments: false)
        #expect(script.sqlResults.count == 2)
        #expect(script.sqlSchema?.connection == "archive")
        #expect(script.sqlSchema?.tables.map(\.name) == ["leases"])
    }

    @Test func aSchemaThatCantBeReadNeverFailsTheRun() async throws {
        let driver = """
        <?php
        class HalfDriver extends \\Runlet\\Driver
        {
            public function bootstrap(string $projectPath): void
            {
            }

            public function sqlConnection(?string $connection)
            {
                return static function (string $sql) {
                    if (stripos($sql, 'select 1') === 0) {
                        return [['one' => 1]];
                    }
                    throw new \\RuntimeException('catalogs are off limits');
                };
            }
        }
        """
        let directory = try DriverSupport.composerProject(drivers: ["HalfDriver.php": driver])
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = try await TestSupport.run(SQLTabRun.code(statement: "select 1", connection: nil, schema: true), target: DriverSupport.target(directory.path), magicComments: false)
        #expect(run.errors.isEmpty, "\(run.errors)")
        #expect(run.finished?.status == .completed)
        #expect(run.sqlResult?.rows == [[.int(1)]])
        #expect(run.sqlSchema?.error?.contains("catalogs are off limits") == true, "\(String(describing: run.sqlSchema))")
        #expect(run.sqlSchema?.tables.isEmpty == true)
    }

    @Test(.enabled(if: SQLTabExecutionTests.ready("laravel-app"), "requires scripts/setup-fixtures.sh"))
    func laravel() async throws {
        let schema = try await load(DriverSupport.fixture("laravel-app"))
        #expect(schema.source == "Laravel DB::connection()")
        #expect(schema.driver == "sqlite")
        #expect(schema.table(named: "widgets") != nil, "\(schema.tables.map(\.name))")
        #expect(schema.table(named: "migrations")?.columns.map(\.name).contains("migration") == true)
    }

    @Test(.enabled(if: ["eloquent-app", "eloquent-app-modern"].allSatisfy(SQLTabExecutionTests.ready), "requires the Eloquent/DBAL 3/4 fixtures"))
    func eloquentAndDoctrine() async throws {
        let eloquent = try await load(DriverSupport.fixture("eloquent-app"))
        #expect(eloquent.source == "Eloquent connection resolver")
        #expect(columns(eloquent, "customers")?.contains("name") == true, "\(eloquent.tables.map(\.name))")

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
            let directory = try SQLTabExecutionTests().scratchProject(fixture, drivers: ["ReportsDriver.php": driver])
            defer { try? FileManager.default.removeItem(at: directory) }
            let schema = try await load(directory.path)
            #expect(schema.source == "ReportsDriver::sqlConnection()", "\(fixture)")
            #expect(columns(schema, "reports")?.contains("name") == true, "\(fixture): \(schema.tables.map(\.name))")
        }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: TestSupport.fixtures.appendingPathComponent("wordpress/.runlet-fixture-ready").path), "requires the WordPress SQLite fixture"))
    func wordpress() async throws {
        let schema = try await load(DriverSupport.fixture("wordpress"))
        #expect(schema.source == "WordPress $wpdb")
        #expect(columns(schema, "rl_options")?.contains("option_name") == true, "\(schema.how ?? "") \(schema.tables.map(\.name))")
    }
}
