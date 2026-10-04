import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// Show Definition (#148) through the runner, with host PHP: SQLite tables and views through a
/// PDO, a callable, and a saved connection; the PostgreSQL reconstruction from recorded catalog
/// rows; and the refusals. Live MariaDB and PostgreSQL are in `SQLDefinitionLiveTests`.
@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct SQLDefinitionTests {
    static let setup = """
    CREATE TABLE customers (id INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE, country TEXT DEFAULT 'UK');
    CREATE TABLE orders (
        id INTEGER PRIMARY KEY,
        customer_id INTEGER NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
        status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'paid')),
        total NUMERIC
    );
    CREATE INDEX orders_status ON orders (status, customer_id);
    CREATE UNIQUE INDEX orders_total ON orders (total) WHERE total IS NOT NULL;
    CREATE TRIGGER orders_paid AFTER UPDATE OF status ON orders BEGIN UPDATE customers SET country = country WHERE id = NEW.customer_id; END;
    CREATE VIEW order_totals AS SELECT customer_id, SUM(total) AS total FROM orders GROUP BY customer_id;
    INSERT INTO customers (email) VALUES ('a@example.test');
    """

    /// A project whose driver opens `shop.sqlite`: a PDO, or a callable for "callable".
    static func project(_ extra: String = "") throws -> URL {
        let directory = try DriverSupport.composerProject(drivers: ["ShopDriver.php": """
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
        \(extra)
        }
        """])
        let php = Process()
        php.executableURL = URL(fileURLWithPath: DriverSupport.php)
        php.arguments = ["-r", "$p = new PDO('sqlite:' . $argv[1]); $p->exec($argv[2]);", directory.appendingPathComponent("shop.sqlite").path, Self.setup]
        try php.run()
        php.waitUntilExit()
        return directory
    }

    static func load(_ table: String, in directory: URL, connection: String? = nil, php: String? = nil) async throws -> SQLDefinitionInfo {
        try await ExecutionEngine(bundle: TestSupport.bundle, docker: nil).loadSQLDefinition(target: DriverSupport.target(directory.path, php: php), table: table, connection: connection)
    }

    /// A row count, to show nothing changed.
    static func count(_ table: String, in directory: URL) throws -> String {
        let php = Process()
        php.executableURL = URL(fileURLWithPath: DriverSupport.php)
        php.arguments = ["-r", "echo (new PDO('sqlite:' . $argv[1]))->query('SELECT COUNT(*) FROM ' . $argv[2])->fetchColumn();", directory.appendingPathComponent("shop.sqlite").path, table]
        let output = Pipe()
        php.standardOutput = output
        try php.run()
        php.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    @Test func sqliteTableWithItsIndexesAndTriggersThroughAPDOAndACallable() async throws {
        let directory = try Self.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        for connection in [nil, "callable"] {
            let label = connection ?? "pdo"
            let info = try await Self.load("orders", in: directory, connection: connection)
            #expect(info.table == "orders" && info.kind == "table", "\(label)")
            #expect(info.how == "sqlite_master", "\(label)")
            #expect(info.driver == "sqlite", "\(label)")
            #expect(info.reconstructed == nil && info.notes == nil, "\(label): \(info.notes ?? [])")
            #expect(info.source == "ShopDriver::sqlConnection()", "\(label)")
            #expect(connection == nil ? info.server?.hasPrefix("SQLite 3.") == true : info.server == nil, "\(label): \(info.server ?? "-")")
            let statements = info.sql.components(separatedBy: "\n\n")
            #expect(statements.count == 4, "\(label): \(info.sql)")
            #expect(statements[0].hasPrefix("CREATE TABLE orders (\n    id INTEGER PRIMARY KEY,"), "\(label): the table as written")
            #expect(statements[0].contains("REFERENCES customers(id) ON DELETE CASCADE"), "\(label)")
            #expect(statements[0].contains("CHECK (status IN ('pending', 'paid'))"), "\(label)")
            #expect(statements[0].hasSuffix("\n);"), "\(label)")
            #expect(statements[1] == "CREATE INDEX orders_status ON orders (status, customer_id);", "\(label)")
            #expect(statements[2] == "CREATE UNIQUE INDEX orders_total ON orders (total) WHERE total IS NOT NULL;", "\(label)")
            #expect(statements[3].hasPrefix("CREATE TRIGGER orders_paid AFTER UPDATE OF status ON orders BEGIN"), "\(label)")
            #expect(statements[3].hasSuffix("END;"), "\(label)")
        }
        #expect(try Self.count("customers", in: directory) == "1", "nothing ran but the catalog read")
    }

    @Test func sqliteViewAndAKeyOnlyIndex() async throws {
        let directory = try Self.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let view = try await Self.load("order_totals", in: directory)
        #expect(view.kind == "view" && view.isView)
        #expect(view.sql == "CREATE VIEW order_totals AS SELECT customer_id, SUM(total) AS total FROM orders GROUP BY customer_id;")
        // UNIQUE's own index has no SQL of its own: the table's definition says it.
        let customers = try await Self.load("customers", in: directory)
        #expect(customers.sql == "CREATE TABLE customers (id INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE, country TEXT DEFAULT 'UK');")
    }

    @Test func anUnknownNameSaysSo() async throws {
        let directory = try Self.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: SQLDefinitionLoadError("There is no table or view named invoices in this database. Reload the schema if it was renamed or dropped.")) {
            try await Self.load("invoices", in: directory)
        }
        // A name is data: quotes reach the catalog as a bound value (PDO) or a literal (callable).
        for connection in [nil, "callable"] {
            await #expect(throws: SQLDefinitionLoadError("There is no table or view named orders' OR '1'='1 in this database. Reload the schema if it was renamed or dropped."), "\(connection ?? "pdo")") {
                try await Self.load("orders' OR '1'='1", in: directory, connection: connection)
            }
        }
    }

    @Test func aDriversSchemaWithoutACatalogCantShowADefinition() async throws {
        let directory = try Self.project("""
            public function sqlSchema(?string $connection): ?array
            {
                return ['invoices' => ['id' => 'uuid']];
            }
        """)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await Self.load("invoices", in: directory, connection: "callable")
            Issue.record("expected an error")
        } catch let error as SQLDefinitionLoadError {
            #expect(error.description.contains("can't show a definition here"), "\(error)")
            #expect(error.description.contains("sqlSchema()"), "\(error)")
        }
        // Its PDO connection still has SQLite's catalog.
        #expect(try await Self.load("orders", in: directory).how == "sqlite_master")
    }

    @Test func aSavedSQLiteConnectionRunsNoProjectCode() async throws {
        let directory = try SQLSavedConnectionTests.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = SQLSavedConnectionTests.connection()
        let (engine, _) = try SQLSavedConnectionTests.engine(for: connection)
        let info = try await engine.loadSQLDefinition(target: DriverSupport.target(directory.path), table: "orders", connection: "ignored", saved: connection)
        #expect(info.saved == true && info.connection == "Reporting")
        #expect(info.sql.hasPrefix("CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER NOT NULL REFERENCES customers(id)"))
        #expect(SQLSavedConnectionTests.markers(in: directory).isEmpty, "no project code ran")
        #expect(!SQLSavedConnectionTests.leaks(String(reflecting: info)))
    }

    @Test(.enabled(if: TestSupport.herdPHP74 != nil, "requires Herd's PHP 7.4"))
    func runsOnPHP74() async throws {
        let directory = try Self.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        for connection in [nil, "callable"] {
            let info = try await Self.load("orders", in: directory, connection: connection, php: TestSupport.herdPHP74!)
            #expect(info.sql.contains("CREATE INDEX orders_status"), "\(connection ?? "pdo")")
        }
        let reconstructed = try await TestSupport.run(Self.recordedRows, target: DriverSupport.target(directory.path, php: TestSupport.herdPHP74!), magicComments: false)
        #expect(reconstructed.stdout == Self.expectedOrders, "\(reconstructed.errors)")
    }

    // MARK: PostgreSQL from recorded catalog rows

    /// PostgreSQL 14's catalog rows for `p148_orders` (see `SQLDefinitionLiveTests.setup`).
    static let recordedRows = #"""
    $catalog = [
        'relation' => ['oid' => 16404, 'relkind' => 'r', 'relpersistence' => 'p', 'relispartition' => false, 'qualified' => 'public.p148_orders',
            'options' => null, 'partition_key' => null, 'partition_bound' => null, 'comment' => 'Orders placed by customers', 'view_definition' => null],
        'columns' => [
            ['name' => 'id', 'type' => 'bigint', 'not_null' => true, 'default_value' => null, 'identity' => 'd', 'generated' => '', 'collation' => null, 'comment' => null],
            ['name' => 'customer_id', 'type' => 'integer', 'not_null' => true, 'default_value' => null, 'identity' => '', 'generated' => '', 'collation' => null, 'comment' => null],
            ['name' => 'status', 'type' => 'p148_status', 'not_null' => true, 'default_value' => "'pending'::p148_status", 'identity' => '', 'generated' => '', 'collation' => null, 'comment' => null],
            ['name' => 'total', 'type' => 'numeric(10,2)', 'not_null' => 't', 'default_value' => '0', 'identity' => '', 'generated' => '', 'collation' => null, 'comment' => 'In euros'],
            ['name' => 'note', 'type' => 'text', 'not_null' => 'f', 'default_value' => null, 'identity' => '', 'generated' => '', 'collation' => 'pg_catalog."C"', 'comment' => null],
            ['name' => 'placed_at', 'type' => 'timestamp with time zone', 'not_null' => true, 'default_value' => 'now()', 'identity' => '', 'generated' => '', 'collation' => null, 'comment' => null],
        ],
        'constraints' => [
            ['name' => 'p148_orders_pkey', 'type' => 'p', 'definition' => 'PRIMARY KEY (id)'],
            ['name' => 'p148_orders_total_check', 'type' => 'c', 'definition' => 'CHECK (total >= 0::numeric)'],
            ['name' => 'p148_orders_customer_id_fkey', 'type' => 'f', 'definition' => 'FOREIGN KEY (customer_id) REFERENCES p148_customers(id) ON DELETE CASCADE'],
        ],
        'indexes' => [
            ['definition' => 'CREATE UNIQUE INDEX p148_orders_note ON public.p148_orders USING btree (lower(note)) WHERE (note IS NOT NULL)'],
            ['definition' => 'CREATE INDEX p148_orders_status ON public.p148_orders USING btree (status, customer_id)'],
        ],
        'triggers' => [],
        'enums' => [['name' => 'p148_status', 'labels' => '["pending", "paid", "shipped"]']],
        'parents' => [],
    ];
    echo \RunletRunner\SqlDefinition::postgres($catalog)['sql'];
    """#

    static let expectedOrders = """
    -- Enum types its columns use (defined on their own, not by this table):
    CREATE TYPE p148_status AS ENUM ('pending', 'paid', 'shipped');

    CREATE TABLE public.p148_orders (
        id bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL,
        customer_id integer NOT NULL,
        status p148_status DEFAULT 'pending'::p148_status NOT NULL,
        total numeric(10,2) DEFAULT 0 NOT NULL,
        note text COLLATE pg_catalog."C",
        placed_at timestamp with time zone DEFAULT now() NOT NULL,
        CONSTRAINT p148_orders_pkey PRIMARY KEY (id),
        CONSTRAINT p148_orders_total_check CHECK (total >= 0::numeric),
        CONSTRAINT p148_orders_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES p148_customers(id) ON DELETE CASCADE
    );

    CREATE UNIQUE INDEX p148_orders_note ON public.p148_orders USING btree (lower(note)) WHERE (note IS NOT NULL);
    CREATE INDEX p148_orders_status ON public.p148_orders USING btree (status, customer_id);

    COMMENT ON TABLE public.p148_orders IS 'Orders placed by customers';
    COMMENT ON COLUMN public.p148_orders.total IS 'In euros';
    """

    static func reconstruct(_ php: String) async throws -> (sql: String, kind: String, notes: String) {
        let events = try await TestSupport.run("""
            \(php)
            $built = \\RunletRunner\\SqlDefinition::postgres($catalog);
            echo $built['sql'], "\\n--KIND--\\n", $built['kind'], "\\n--NOTES--\\n", implode("\\n", $built['notes']);
            """, target: DriverSupport.target(TestSupport.fixtures.appendingPathComponent("composer").path), magicComments: false)
        let parts = events.stdout.components(separatedBy: "\n--KIND--\n")
        let rest = (parts.count > 1 ? parts[1] : "").components(separatedBy: "\n--NOTES--\n")
        return (parts[0], rest[0], rest.count > 1 ? rest[1] : "\(events.errors)")
    }

    @Test func postgresTableFromRecordedRows() async throws {
        let events = try await TestSupport.run(Self.recordedRows, target: DriverSupport.target(TestSupport.fixtures.appendingPathComponent("composer").path), magicComments: false)
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.stdout == Self.expectedOrders)
    }

    @Test func postgresPartitionsInheritanceGeneratedColumnsAndQuotes() async throws {
        let partitioned = try await Self.reconstruct("""
            $catalog = [
                'relation' => ['relkind' => 'p', 'relpersistence' => 'u', 'qualified' => 'sales."Events"', 'options' => 'fillfactor=70', 'partition_key' => 'RANGE (happened_on)', 'comment' => "It's \\\\ here"],
                'columns' => [
                    (object) ['name' => 'id', 'type' => 'integer', 'not_null' => true, 'identity' => 'a'],
                    (object) ['name' => 'happened_on', 'type' => 'date', 'not_null' => true],
                    (object) ['name' => '"Year"', 'type' => 'integer', 'default_value' => 'EXTRACT(year FROM happened_on)', 'generated' => 's'],
                ],
                'enums' => [['name' => 'mood', 'labels' => '["it\\'s", "ok"]']],
            ];
            """)
        #expect(partitioned.kind == "partitioned table")
        #expect(partitioned.sql == """
            -- Enum types its columns use (defined on their own, not by this table):
            CREATE TYPE mood AS ENUM ('it''s', 'ok');

            CREATE UNLOGGED TABLE sales."Events" (
                id integer GENERATED ALWAYS AS IDENTITY NOT NULL,
                happened_on date NOT NULL,
                "Year" integer GENERATED ALWAYS AS (EXTRACT(year FROM happened_on)) STORED
            )
            PARTITION BY RANGE (happened_on) WITH (fillfactor=70);

            COMMENT ON TABLE sales."Events" IS E'It''s \\\\ here';
            """)
        #expect(partitioned.notes.contains("Reconstructed by Runlet from the catalog"))

        let partition = try await Self.reconstruct("""
            $catalog = [
                'relation' => ['relkind' => 'r', 'relispartition' => true, 'qualified' => 'sales.events_2026', 'partition_bound' => "FOR VALUES FROM ('2026-01-01') TO ('2027-01-01')"],
                'columns' => [['name' => 'id', 'type' => 'integer', 'not_null' => true]],
                'parents' => [['name' => 'sales."Events"']],
            ];
            """)
        #expect(partition.sql == """
            -- A partition of sales."Events" FOR VALUES FROM ('2026-01-01') TO ('2027-01-01'):
            -- ALTER TABLE sales."Events" ATTACH PARTITION sales.events_2026 FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
            CREATE TABLE sales.events_2026 (
                id integer NOT NULL
            );
            """)

        let child = try await Self.reconstruct("""
            $catalog = [
                'relation' => ['relkind' => 'f', 'qualified' => 'public.remote_items'],
                'columns' => [['name' => 'id', 'type' => 'integer']],
                'parents' => [['name' => 'public.items'], ['name' => 'public.audited']],
                'triggers' => [['definition' => 'CREATE TRIGGER audit AFTER INSERT ON public.remote_items FOR EACH ROW EXECUTE FUNCTION audit()']],
            ];
            """)
        #expect(child.kind == "foreign table")
        #expect(child.sql == """
            CREATE FOREIGN TABLE public.remote_items (
                id integer
            )
            INHERITS (public.items, public.audited);

            CREATE TRIGGER audit AFTER INSERT ON public.remote_items FOR EACH ROW EXECUTE FUNCTION audit();
            """)
        #expect(child.notes.contains("server and options are left out"))
    }

    @Test func postgresViewsFromRecordedRows() async throws {
        let view = try await Self.reconstruct(#"""
            $catalog = [
                'relation' => ['relkind' => 'v', 'qualified' => 'public.p148_open_orders', 'options' => 'security_barrier=true', 'comment' => 'Not shipped yet',
                    'view_definition' => " SELECT o.id,\n    c.email\n   FROM p148_orders o\n     JOIN p148_customers c ON c.id = o.customer_id;"],
                'columns' => [['name' => 'id', 'type' => 'bigint', 'comment' => 'The order']],
            ];
            """#)
        #expect(view.kind == "view")
        #expect(view.sql == """
            CREATE OR REPLACE VIEW public.p148_open_orders WITH (security_barrier=true) AS
            SELECT o.id,
                c.email
               FROM p148_orders o
                 JOIN p148_customers c ON c.id = o.customer_id;

            COMMENT ON VIEW public.p148_open_orders IS 'Not shipped yet';
            COMMENT ON COLUMN public.p148_open_orders.id IS 'The order';
            """)
        #expect(view.notes == "Reconstructed by Runlet around PostgreSQL's pg_get_viewdef().\nLeft out: owner and privileges.")

        let materialized = try await Self.reconstruct(#"""
            $catalog = [
                'relation' => ['relkind' => 'm', 'qualified' => 'public.totals', 'view_definition' => ' SELECT 1 AS one;'],
                'indexes' => [['definition' => 'CREATE INDEX totals_one ON public.totals USING btree (one)']],
            ];
            """#)
        #expect(materialized.kind == "materialized view")
        #expect(materialized.sql == "CREATE MATERIALIZED VIEW public.totals AS\nSELECT 1 AS one;\n\nCREATE INDEX totals_one ON public.totals USING btree (one);")
    }
}
