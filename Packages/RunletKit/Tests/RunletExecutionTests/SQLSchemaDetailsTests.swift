import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// The schema explorer's details (#21): kinds, keys, foreign keys, indexes, defaults, and row
/// estimates, read from the catalog with the schema. Live MariaDB and PostgreSQL run only when
/// `RUNLET_TEST_MYSQL` / `RUNLET_TEST_PGSQL` hold a PDO DSN (see `scripts/setup-fixtures.sh databases`).
@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct SQLSchemaDetailsTests {
    static let setup = """
    CREATE TABLE customers (id INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE, country TEXT DEFAULT 'UK');
    CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER NOT NULL REFERENCES customers(id), status TEXT NOT NULL DEFAULT 'pending', reference TEXT, total NUMERIC);
    CREATE INDEX orders_status ON orders (status, customer_id);
    CREATE UNIQUE INDEX orders_reference ON orders (reference);
    CREATE TABLE tags (order_id INTEGER, name TEXT, PRIMARY KEY (order_id, name));
    CREATE VIEW order_totals AS SELECT customer_id, SUM(total) AS total FROM orders GROUP BY customer_id;
    """

    /// A project whose driver opens `shop.sqlite`: a PDO, or a callable for "callable".
    static func driver(_ extra: String = "") -> String {
        """
        <?php
        class ShopDriver extends \\Runlet\\Driver
        {
            private $path;

            public function bootstrap(string $projectPath): void
            {
                $this->path = $projectPath . '/shop.sqlite';
            }

            public function sqlConnection(?string $connection)
            {
                $pdo = new \\PDO(getenv('RUNLET_SCHEMA_DSN') ?: 'sqlite:' . $this->path);
                $pdo->setAttribute(\\PDO::ATTR_ERRMODE, \\PDO::ERRMODE_EXCEPTION);
                if ($connection === 'callable') {
                    return static function (string $sql) use ($pdo) {
                        $statement = $pdo->query($sql);

                        return $statement->columnCount() > 0 ? $statement->fetchAll(\\PDO::FETCH_ASSOC) : $statement->rowCount();
                    };
                }

                return $pdo;
            }
        \(extra)
        }
        """
    }

    func project(_ driver: String = SQLSchemaDetailsTests.driver(), setup: String = SQLSchemaDetailsTests.setup) throws -> URL {
        let directory = try DriverSupport.composerProject(drivers: ["ShopDriver.php": driver])
        let php = Process()
        php.executableURL = URL(fileURLWithPath: DriverSupport.php)
        php.arguments = ["-r", "$p = new PDO('sqlite:' . $argv[1]); $p->exec($argv[2]);", directory.appendingPathComponent("shop.sqlite").path, setup]
        try php.run()
        php.waitUntilExit()
        return directory
    }

    func load(_ directory: URL, connection: String? = nil) async throws -> SQLSchemaInfo {
        try await ExecutionEngine(bundle: TestSupport.bundle, docker: nil).loadSQLSchema(target: DriverSupport.target(directory.path), connection: connection)
    }

    @Test func sqliteDetailsThroughPDOAndACallable() async throws {
        let directory = try project()
        defer { try? FileManager.default.removeItem(at: directory) }
        for connection in [nil, "callable"] {
            let schema = try await load(directory, connection: connection)
            let label = connection ?? "pdo"
            #expect(schema.how == "sqlite_master", "\(label)")
            #expect(schema.notes == nil, "\(label): \(schema.notes ?? [])")
            #expect(schema.tables.map(\.name) == ["customers", "order_totals", "orders", "tags"], "\(label)")

            let customers = try #require(schema.table(named: "customers"))
            #expect(customers.columns[0] == .init(name: "id", type: "integer", nullable: false, primaryKey: true), "\(label)")
            #expect(customers.columns[1] == .init(name: "email", type: "text", nullable: false), "\(label)")
            #expect(customers.columns[2] == .init(name: "country", type: "text", nullable: true, defaultValue: "'UK'"), "\(label)")
            #expect(customers.indexes?.map(\.columns) == [["email"]], "\(label): UNIQUE makes an index")
            #expect(customers.indexes?.first?.unique == true)
            #expect(customers.isView == false && customers.rows == nil)

            let orders = try #require(schema.table(named: "orders"))
            #expect(orders.columns.first { $0.name == "customer_id" }?.references == "customers.id", "\(label)")
            #expect(orders.columns.first { $0.name == "status" }?.defaultValue == "'pending'")
            let indexes = Dictionary(uniqueKeysWithValues: (orders.indexes ?? []).map { ($0.name, $0) })
            #expect(indexes["orders_status"] == .init(name: "orders_status", columns: ["status", "customer_id"]), "\(label): \(orders.indexes ?? [])")
            #expect(indexes["orders_reference"] == .init(name: "orders_reference", columns: ["reference"], unique: true))

            let tags = try #require(schema.table(named: "tags"))
            #expect(tags.columns.filter { $0.primaryKey == true }.map(\.name) == ["order_id", "name"], "a composite primary key")
            #expect(tags.indexes?.first { $0.primary == true }?.columns == ["order_id", "name"])

            let view = try #require(schema.table(named: "order_totals"))
            #expect(view.isView, "\(label)")
            #expect(view.columns.map(\.name) == ["customer_id", "total"])
        }
    }

    /// #153: each table's foreign key constraints, so a composite key is one relation, for the
    /// relations diagram; a self-reference; and `REFERENCES t` without a column.
    @Test func foreignKeyConstraintsThroughPDOAndACallable() async throws {
        let directory = try project(setup: """
        CREATE TABLE lines (order_id INTEGER NOT NULL, line_no INTEGER NOT NULL, PRIMARY KEY (order_id, line_no));
        CREATE TABLE shipments (id INTEGER PRIMARY KEY, line_order INTEGER, line_no INTEGER, carrier_id INTEGER REFERENCES carriers,
            FOREIGN KEY (line_order, line_no) REFERENCES lines (order_id, line_no));
        CREATE TABLE carriers (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES carriers (id));
        """)
        defer { try? FileManager.default.removeItem(at: directory) }
        for connection in [nil, "callable"] {
            let schema = try await load(directory, connection: connection)
            let label = connection ?? "pdo"
            let shipments = try #require(schema.table(named: "shipments"))
            let keys = try #require(shipments.foreignKeys, "\(label)")
            #expect(keys.count == 2, "\(label): \(keys)")
            #expect(keys.contains(.init(name: keys.first { $0.references == "lines" }?.name ?? "?", columns: ["line_order", "line_no"], references: "lines", referencedColumns: ["order_id", "line_no"])), "\(label): \(keys)")
            #expect(keys.contains { $0.references == "carriers" && $0.columns == ["carrier_id"] && $0.referencedColumns == nil }, "\(label): no referenced column named")
            #expect(shipments.columns.first { $0.name == "line_no" }?.references == "lines.line_no", "\(label): columns keep their references")
            #expect(schema.table(named: "carriers")?.foreignKeys == [.init(name: "0", columns: ["parent_id"], references: "carriers", referencedColumns: ["id"])], "\(label)")
            #expect(schema.table(named: "lines")?.foreignKeys == nil)

            let relations = SQLRelations.relations(in: schema)
            #expect(relations.map(\.summary) == [
                "carriers.parent_id → carriers.id",
                "shipments.carrier_id → carriers.id",
                "shipments(line_order, line_no) → lines(order_id, line_no)",
            ], "\(label)")
        }
    }

    @Test func aDriversDetailedSchema() async throws {
        let directory = try project(Self.driver("""
            public function sqlSchema(?string $connection): ?array
            {
                return [
                    'invoices' => [
                        'columns' => [
                            'id' => ['type' => 'uuid', 'nullable' => false, 'primaryKey' => true],
                            'customer' => ['type' => 'uuid', 'references' => 'customers.id'],
                            'note' => 'text',
                        ],
                        'indexes' => [['name' => 'invoices_customer', 'columns' => ['customer']]],
                        'rows' => 1200,
                    ],
                    'open_invoices' => ['columns' => ['id' => 'uuid'], 'kind' => 'view'],
                    'tags' => ['name'],
                ];
            }
        """))
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = try await load(directory)
        #expect(schema.how == "ShopDriver::sqlSchema()")
        #expect(schema.tables.map(\.name) == ["invoices", "open_invoices", "tags"])
        let invoices = try #require(schema.table(named: "invoices"))
        #expect(invoices.rows == 1200)
        #expect(invoices.columns == [
            .init(name: "id", type: "uuid", nullable: false, primaryKey: true),
            .init(name: "customer", type: "uuid", references: "customers.id"),
            .init(name: "note", type: "text"),
        ])
        #expect(invoices.indexes == [.init(name: "invoices_customer", columns: ["customer"])])
        #expect(invoices.foreignKeys == nil, "#153: a driver's schema names no constraints")
        #expect(schema.table(named: "open_invoices")?.isView == true)
        #expect(schema.table(named: "tags")?.columns.map(\.name) == ["name"])
    }

    @Test(.enabled(if: TestSupport.herdPHP74 != nil, "requires Herd's PHP 7.4"))
    func runsOnPHP74() async throws {
        let directory = try project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = try await ExecutionEngine(bundle: TestSupport.bundle, docker: nil).loadSQLSchema(target: DriverSupport.target(directory.path, php: TestSupport.herdPHP74!), connection: nil)
        #expect(schema.table(named: "orders")?.columns.first { $0.name == "customer_id" }?.references == "customers.id")
        #expect(schema.table(named: "orders")?.indexes?.count == 2)
    }
}
