import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// SQL tabs against live MariaDB and PostgreSQL servers: the schema explorer's details (#21),
/// Run All's transactions (#129), and a single statement (#35). They run only when
/// `RUNLET_TEST_MYSQL` / `RUNLET_TEST_PGSQL` hold `<PDO DSN>|<user>|<password>`, as
/// `scripts/setup-fixtures.sh databases` prints for its throwaway fixture containers.
@Suite(.serialized, .enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct SQLLiveDatabaseTests {
    struct Server {
        var dsn: String
        var user: String
        var password: String
        var dialect: String

        init?(_ variable: String) {
            guard let value = ProcessInfo.processInfo.environment[variable], !value.isEmpty else { return nil }
            let parts = value.components(separatedBy: "|")
            guard parts.count == 3 else { return nil }
            (dsn, user, password) = (parts[0], parts[1], parts[2])
            dialect = dsn.hasPrefix("pgsql:") ? "pgsql" : "mysql"
        }

        /// A PHP string literal.
        static func php(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
        }

        /// Runs `sql` on the server with host PHP (setup and checks, not through Runlet).
        func exec(_ sql: String) throws -> String {
            let php = Process()
            php.executableURL = URL(fileURLWithPath: DriverSupport.php)
            php.arguments = ["-r", """
                $p = new PDO(\(Self.php(dsn)), \(Self.php(user)), \(Self.php(password)), [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
                $s = $p->query($argv[1]);
                while ($s !== false && $s->columnCount() > 0 && ($row = $s->fetch(PDO::FETCH_NUM)) !== false) { echo implode('|', $row), "\\n"; }
                """, sql]
            let output = Pipe()
            php.standardOutput = output
            try php.run()
            php.waitUntilExit()
            return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// A project whose driver connects to this server.
        func project() throws -> URL {
            try DriverSupport.composerProject(drivers: ["LiveDriver.php": """
            <?php
            class LiveDriver extends \\Runlet\\Driver
            {
                public function bootstrap(string $projectPath): void
                {
                }

                public function sqlConnection(?string $connection)
                {
                    return new \\PDO(\(Self.php(dsn)), \(Self.php(user)), \(Self.php(password)));
                }
            }
            """])
        }
    }

    static let mysql = Server("RUNLET_TEST_MYSQL")
    static let pgsql = Server("RUNLET_TEST_PGSQL")
    static var servers: [Server] { [mysql, pgsql].compactMap { $0 } }

    static func setup(_ server: Server) throws {
        let mysql = server.dialect == "mysql"
        let statements = [
            "DROP VIEW IF EXISTS order_totals",
            "DROP TABLE IF EXISTS tags, orders, customers, audit, audit2",
            mysql
                ? "CREATE TABLE customers (id INT AUTO_INCREMENT PRIMARY KEY, email VARCHAR(190) NOT NULL UNIQUE, country VARCHAR(2) DEFAULT 'UK') ENGINE=InnoDB"
                : "CREATE TABLE customers (id SERIAL PRIMARY KEY, email VARCHAR(190) NOT NULL UNIQUE, country VARCHAR(2) DEFAULT 'UK')",
            mysql
                ? "CREATE TABLE orders (id INT AUTO_INCREMENT PRIMARY KEY, customer_id INT NOT NULL, status VARCHAR(20) NOT NULL DEFAULT 'pending', reference VARCHAR(40), total DECIMAL(10,2), CONSTRAINT orders_customer FOREIGN KEY (customer_id) REFERENCES customers(id)) ENGINE=InnoDB"
                : "CREATE TABLE orders (id SERIAL PRIMARY KEY, customer_id INT NOT NULL REFERENCES customers(id), status VARCHAR(20) NOT NULL DEFAULT 'pending', reference VARCHAR(40), total NUMERIC(10,2))",
            "CREATE INDEX orders_status ON orders (status, customer_id)",
            "CREATE UNIQUE INDEX orders_reference ON orders (reference)",
            "CREATE TABLE tags (order_id INT NOT NULL, name VARCHAR(40) NOT NULL, PRIMARY KEY (order_id, name))",
            "CREATE VIEW order_totals AS SELECT customer_id, SUM(total) AS total FROM orders GROUP BY customer_id",
            "INSERT INTO customers (email) VALUES ('a@example.test'), ('b@example.test')",
            mysql ? "ANALYZE TABLE customers" : "ANALYZE customers",
        ]
        for statement in statements { _ = try server.exec(statement) }
    }

    func load(_ server: Server) async throws -> SQLSchemaInfo {
        let directory = try server.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await ExecutionEngine(bundle: TestSupport.bundle, docker: nil).loadSQLSchema(target: DriverSupport.target(directory.path), connection: nil)
    }

    func runAll(_ server: Server, _ script: String, transaction: Bool = true) async throws -> [RunEvent] {
        let directory = try server.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let statements = try SQLScript.statementsToRunAll(in: script, selection: NSRange(location: 0, length: 0)).get()
        return try await TestSupport.run(SQLTabRun.scriptCode(statements: statements, connection: nil, transaction: transaction), target: DriverSupport.target(directory.path), magicComments: false)
    }

    @Test(.enabled(if: !servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func schemaDetails() async throws {
        for server in Self.servers {
            try Self.setup(server)
            let schema = try await load(server)
            let label = server.dialect
            #expect(schema.driver == server.dialect, "\(label)")
            #expect(schema.how == "information_schema", "\(label)")
            #expect(schema.notes == nil, "\(label): \(schema.notes ?? [])")
            #expect(Set(schema.tables.map(\.name)).isSuperset(of: ["customers", "orders", "tags", "order_totals"]), "\(label): \(schema.tables.map(\.name))")

            let customers = try #require(schema.table(named: "customers"), "\(label)")
            #expect(customers.columns.map(\.name) == ["id", "email", "country"], "\(label)")
            #expect(customers.columns[0].primaryKey == true && customers.columns[0].nullable == false, "\(label)")
            #expect(customers.columns[1].nullable == false && customers.columns[1].primaryKey == nil, "\(label)")
            #expect(customers.columns[2].nullable == true, "\(label)")
            #expect(customers.columns[2].defaultValue?.contains("UK") == true, "\(label): \(customers.columns[2])")
            #expect(customers.rows != nil, "\(label): a row estimate after ANALYZE")
            #expect(customers.indexes?.contains { $0.primary == true && $0.columns == ["id"] } == true, "\(label): \(customers.indexes ?? [])")
            #expect(customers.indexes?.contains { $0.unique == true && $0.columns == ["email"] } == true, "\(label)")

            let orders = try #require(schema.table(named: "orders"))
            #expect(orders.columns.first { $0.name == "customer_id" }?.references == "customers.id", "\(label)")
            #expect(orders.columns.first { $0.name == "status" }?.defaultValue?.contains("pending") == true, "\(label)")
            #expect(orders.indexes?.first { $0.name == "orders_status" }?.columns == ["status", "customer_id"], "\(label): \(orders.indexes ?? [])")
            #expect(orders.indexes?.first { $0.name == "orders_reference" }?.unique == true, "\(label)")

            let tags = try #require(schema.table(named: "tags"))
            #expect(tags.columns.filter { $0.primaryKey == true }.map(\.name) == ["order_id", "name"], "\(label)")
            #expect(schema.table(named: "order_totals")?.isView == true, "\(label)")
        }
    }

    @Test(.enabled(if: !servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func aStatementAndItsSchema() async throws {
        for server in Self.servers {
            try Self.setup(server)
            let directory = try server.project()
            defer { try? FileManager.default.removeItem(at: directory) }
            let events = try await TestSupport.run(SQLTabRun.code(statement: "SELECT email FROM customers ORDER BY id", connection: nil, schema: true), target: DriverSupport.target(directory.path), magicComments: false)
            #expect(events.errors.isEmpty, "\(server.dialect): \(events.errors)")
            #expect(events.sqlResult?.rows == [[.string("a@example.test")], [.string("b@example.test")]], "\(server.dialect)")
            #expect(events.sqlResult?.driver == server.dialect)
            #expect(events.sqlSchema?.table(named: "orders") != nil, "\(server.dialect)")
        }
    }

    /// MariaDB commits DDL at once: Runlet says so, and a later failure rolls back only what
    /// came after it.
    @Test(.enabled(if: mysql != nil, "set RUNLET_TEST_MYSQL"))
    func mariadbImplicitCommits() async throws {
        let server = try #require(Self.mysql)
        try Self.setup(server)
        let events = try await runAll(server, """
        INSERT INTO customers (email) VALUES ('c@example.test');
        CREATE TABLE audit (id INT);
        INSERT INTO customers (email) VALUES ('d@example.test');
        SELECT nope FROM missing;
        """)
        #expect(events.sqlResults.count == 3)
        #expect(events.sqlNotices.first?.hasPrefix("MySQL commits statement 2 (line 2) at once") == true, "\(events.sqlNotices)")
        let message = try #require(events.errors.first?.message)
        #expect(message.hasPrefix("Statement 4 of 4 (line 4): "), "\(message)")
        #expect(message.hasSuffix("Rolled back the transaction: statement 3 was undone. Statements 1–2 stay: the database committed them at statement 2."), "\(message)")
        #expect(try server.exec("SELECT email FROM customers ORDER BY id") == "a@example.test\nb@example.test\nc@example.test")
        #expect(try server.exec("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'audit'") == "1")
    }

    /// PostgreSQL rolls back DDL too.
    @Test(.enabled(if: pgsql != nil, "set RUNLET_TEST_PGSQL"))
    func postgresRollsBackEverything() async throws {
        let server = try #require(Self.pgsql)
        try Self.setup(server)
        let events = try await runAll(server, """
        CREATE TABLE audit2 (id INT);
        INSERT INTO customers (email) VALUES ('e@example.test');
        SELECT nope FROM missing;
        """)
        #expect(events.sqlResults.count == 2)
        #expect(events.sqlNotices.isEmpty, "\(events.sqlNotices)")
        #expect(events.errors.first?.message.hasSuffix("Rolled back the transaction: statements 1–2 were undone.") == true, "\(events.errors)")
        #expect(try server.exec("SELECT COUNT(*) FROM customers") == "2")
        #expect(try server.exec("SELECT to_regclass('audit2') IS NULL") == "1")

        let committed = try await runAll(server, "INSERT INTO customers (email) VALUES ('f@example.test'); SELECT COUNT(*) AS n FROM customers")
        #expect(committed.errors.isEmpty, "\(committed.errors)")
        #expect(committed.sqlResults.last?.rows == [[.int(3)]])
        #expect(committed.sqlNotices.last == "Committed the transaction: all 2 statements ran.")
    }
}
