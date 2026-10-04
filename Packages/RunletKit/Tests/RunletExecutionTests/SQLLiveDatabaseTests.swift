import Foundation
@testable import RunletCore
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

        /// How long one `exec` may take. A statement or a connection that stalls fails the test
        /// with a timeout that names the statement, instead of hanging the run (#182).
        static let execLimit: Duration = .seconds(30)

        /// Host PHP that runs `sql` on the server and prints its rows, one per line.
        func execCommand(_ sql: String) -> [String] {
            [DriverSupport.php, "-r", """
                $p = new PDO(\(Self.php(dsn)), \(Self.php(user)), \(Self.php(password)), [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
                $s = $p->query($argv[1]);
                while ($s !== false && $s->columnCount() > 0 && ($row = $s->fetch(PDO::FETCH_NUM)) !== false) { echo implode('|', $row), "\\n"; }
                """, sql]
        }

        /// `sql` as a timeout names it.
        func execStep(_ sql: String) -> String {
            "\(dialect) statement \"\(sql.count > 120 ? sql.prefix(120) + "…" : sql)\""
        }

        /// Runs `sql` on the server with host PHP (setup and checks, not through Runlet), at most
        /// `limit`. Sync helpers and `defer` cleanup call it, so it blocks the calling thread,
        /// with that deadline, until the process's termination handler signals (#182). Async
        /// code that polls the server runs `execCommand` with `TestProcess.run` instead.
        func exec(_ sql: String, within limit: Duration = Self.execLimit) throws -> String {
            let result = try TestProcess.runBlocking(execCommand(sql), step: execStep(sql), within: limit)
            // PHP's own messages, which went to the test's output before.
            if !result.errors.isEmpty { FileHandle.standardError.write(Data(result.errors.utf8)) }
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// The server as a saved connection (#138): host, port, and database from the DSN.
    static func saved(_ server: Server, password: String? = nil) -> (DatabaseConnection, InMemoryCredentialStore) {
        var fields: [String: String] = [:]
        for part in server.dsn.drop(while: { $0 != ":" }).dropFirst().split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { fields[pair[0]] = pair[1] }
        }
        let connection = DatabaseConnection(name: "Reporting replica", scope: .local(UUID()), driver: server.dialect == "pgsql" ? .pgsql : .mysql, host: fields["host"] ?? "127.0.0.1", port: fields["port"].flatMap(Int.init), database: fields["dbname"] ?? "", user: server.user, connectTimeout: 5)
        let store = InMemoryCredentialStore()
        try? store.set(SensitiveString(password ?? server.password), for: connection.id, label: "Runlet database: test")
        return (connection, store)
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

    // MARK: Saved connections (#138)

    @Test(.enabled(if: !servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func savedConnections() async throws {
        let plain = DriverSupport.fixture("plain")
        for server in Self.servers {
            try Self.setup(server)
            let label = server.dialect
            let (connection, store) = Self.saved(server)
            let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil, credentials: store)

            // Test Connection: the version, database, and user.
            let info = try await engine.testSQLConnection(target: DriverSupport.target(plain), connection: connection, password: .stored)
            #expect(info.driver == server.dialect, "\(label)")
            #expect(info.database == "shop", "\(label)")
            #expect(info.user?.hasPrefix(server.user) == true, "\(label): \(info)")
            #expect(info.serverVersion?.isEmpty == false, "\(label)")
            #expect(info.summary.hasPrefix(server.dialect == "pgsql" ? "Connected: PostgreSQL 14" : "Connected: MariaDB 11"), "\(label): \(info.summary)")

            // A statement and its schema, from a plain PHP project with no driver at all.
            var request = RunRequest(tabId: UUID(), documentVersion: 1, target: DriverSupport.target(plain), code: SQLTabRun.code(statement: "SELECT email FROM customers ORDER BY id", connection: nil, schema: true), magicComments: false)
            request.sqlConnection = connection
            var events: [RunEvent] = []
            for await event in try await engine.start(request) { events.append(event) }
            #expect(events.errors.isEmpty, "\(label): \(events.errors)")
            #expect(events.sqlResult?.rows == [[.string("a@example.test")], [.string("b@example.test")]], "\(label)")
            #expect(events.sqlResult?.saved == true && events.sqlResult?.connection == "Reporting replica", "\(label)")
            let tables: Set<String> = Set((events.sqlSchema?.tables ?? []).map(\.name))
            #expect(tables.isSuperset(of: ["customers", "orders"]), "\(label)")
            let schema = try await engine.loadSQLSchema(target: DriverSupport.target(plain), connection: nil, saved: connection)
            #expect(schema.table(named: "orders")?.indexes?.isEmpty == false, "\(label)")

            // MySQL echoes the statement in its errors: the password is replaced there too.
            var echo = RunRequest(tabId: UUID(), documentVersion: 1, target: DriverSupport.target(plain), code: SQLTabRun.code(statement: "SELECT FROM WHERE '\(server.password)'", connection: nil), magicComments: false)
            echo.sqlConnection = connection
            var echoed: [RunEvent] = []
            for await event in try await engine.start(echo) { echoed.append(event) }
            #expect(!echoed.errors.isEmpty, "\(label)")
            for text in echoed.scannableText { #expect(!SQLSavedConnectionTests.leaks(text, password: server.password), "\(label): \(text)") }

            // A wrong password: a clear error that holds neither password.
            let wrongPassword = "wrong-\(UUID().uuidString.prefix(8))"
            let (wrong, wrongStore) = Self.saved(server, password: wrongPassword)
            let failing = ExecutionEngine(bundle: TestSupport.bundle, docker: nil, credentials: wrongStore)
            var bad = RunRequest(tabId: UUID(), documentVersion: 1, target: DriverSupport.target(plain), code: SQLTabRun.code(statement: "SELECT 1", connection: nil), magicComments: false)
            bad.sqlConnection = wrong
            var failed: [RunEvent] = []
            for await event in try await failing.start(bad) { failed.append(event) }
            let error = try #require(failed.errors.first, "\(label)")
            #expect(error.message.contains("Runlet could not open the saved connection \"Reporting replica\""), "\(label): \(error.message)")
            #expect(error.message.contains(server.dialect == "pgsql" ? "password authentication failed" : "Access denied"), "\(label): \(error.message)")
            #expect(error.previous == nil, "\(label)")
            for text in failed.scannableText {
                #expect(!SQLSavedConnectionTests.leaks(text, password: wrongPassword), "\(label): \(text)")
                #expect(!SQLSavedConnectionTests.leaks(text, password: server.password), "\(label): \(text)")
            }
        }
    }

    // MARK: Read-only saved connections (#139)

    /// Runs `code` on the server as a saved connection (read-only unless `readOnly` is false).
    func runSaved(_ server: Server, _ code: String, readOnly: Bool = true) async throws -> [RunEvent] {
        let (saved, store) = Self.saved(server)
        var connection = saved
        connection.readOnly = readOnly
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil, credentials: store)
        var request = RunRequest(tabId: UUID(), documentVersion: 1, target: DriverSupport.target(DriverSupport.fixture("plain")), code: code, magicComments: false)
        request.sqlConnection = connection
        var events: [RunEvent] = []
        for await event in try await engine.start(request) { events.append(event) }
        return events
    }

    /// The database refuses writes, DDL, and temporary tables in the read-only session, even
    /// when they are sent past the app's and the runner's checks; Runlet's refusals stop them
    /// (and attempts to switch the session back) first; reads, Test Connection, the schema,
    /// and Run All of reads work.
    @Test(.enabled(if: !servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func readOnlySavedConnections() async throws {
        for server in Self.servers {
            try Self.setup(server)
            let label = server.dialect
            let mysql = server.dialect == "mysql"

            // Reads work, and say they ran in a read-only session.
            let read = try await runSaved(server, SQLTabRun.code(statement: "SELECT email FROM customers ORDER BY id", connection: nil, schema: true))
            #expect(read.errors.isEmpty, "\(label): \(read.errors)")
            #expect(read.sqlResult?.rows == [[.string("a@example.test")], [.string("b@example.test")]], "\(label)")
            #expect(read.sqlResult?.source?.hasSuffix(", read-only session") == true, "\(label): \(read.sqlResult?.source ?? "")")
            #expect(read.sqlSchema?.table(named: "orders") != nil, "\(label)")
            let flag = mysql ? "SELECT @@session.transaction_read_only AS ro" : "SHOW transaction_read_only"
            let shown = try await runSaved(server, SQLTabRun.code(statement: flag, connection: nil))
            #expect(["1", "on"].contains(shown.sqlResult?.rows.first?.first?.text ?? ""), "\(label): \(shown.sqlResult?.rows ?? []) \(shown.errors)")

            // Test Connection confirms it.
            let (saved, store) = Self.saved(server)
            var connection = saved
            connection.readOnly = true
            let info = try await ExecutionEngine(bundle: TestSupport.bundle, docker: nil, credentials: store).testSQLConnection(target: DriverSupport.target(DriverSupport.fixture("plain")), connection: connection, password: .stored)
            #expect(info.readOnly == true, "\(label)")

            // Runlet refuses writes and session changes before connecting.
            var refusals = [
                "INSERT INTO customers (email) VALUES ('ro@example.test')", "UPDATE customers SET country = 'FR'", "CREATE TABLE audit (id INT)",
                "DROP TABLE tags", "SET SESSION TRANSACTION READ WRITE",
            ]
            refusals += mysql
                ? ["SET @@session.transaction_read_only = 0", "SET tx_read_only = 0", "START TRANSACTION READ WRITE", "CREATE TEMPORARY TABLE scratch (id INT)", "SELECT * FROM customers /*!50000 INTO OUTFILE '/tmp/runlet-ro' */"]
                : ["SET default_transaction_read_only = off", "SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE", "BEGIN READ WRITE", "RESET ALL", "DISCARD ALL", "SELECT set_config('default_transaction_read_only', 'off', false)"]
            for sql in refusals {
                let events = try await runSaved(server, SQLTabRun.code(statement: sql, connection: nil))
                #expect(SQLScript.readOnlyRefusal(of: sql, driver: mysql ? .mysql : .pgsql) != nil, "\(label): the app refuses \(sql)")
                #expect(events.errors.first?.message.hasPrefix(#"Runlet refused this statement on the read-only connection "Reporting replica""#) == true, "\(label) \(sql): \(events.errors)")
            }

            // Past both checks, the database refuses: INSERT, UPDATE, DDL, a temporary table
            // (PostgreSQL always; MariaDB 11 too, though MySQL allows them), FOR UPDATE, and
            // nextval() on PostgreSQL.
            var attempts = [
                "INSERT INTO customers (email) VALUES ('ro@example.test')", "UPDATE customers SET country = 'FR'", "CREATE TABLE audit (id INT)",
                "DROP TABLE tags", "CREATE TEMPORARY TABLE scratch (id INT)", "SELECT * FROM customers FOR UPDATE",
            ]
            if !mysql { attempts.append("SELECT nextval('customers_id_seq')") }
            let past = try await runSaved(server, """
                <?php
                $pdo = \\RunletRunner\\SqlConnect::pdo();
                foreach (\(SQLReadOnlyConnectionTests.phpArray(attempts)) as $sql) {
                    try { $pdo->query($sql); echo "OK $sql\\n"; } catch (\\Throwable $e) { echo "FAIL $sql: ", $e->getMessage(), "\\n"; }
                }
                """)
            #expect(past.errors.isEmpty, "\(label): \(past.errors)")
            let lines = past.stdout.split(separator: "\n").map(String.init)
            #expect(lines.count == attempts.count, "\(label): \(past.stdout)")
            for line in lines {
                #expect(line.hasPrefix("FAIL") && line.lowercased().contains("read") && line.lowercased().contains("only"), "\(label): \(line)")
            }
            #expect(try server.exec("SELECT COUNT(*) FROM customers") == "2", "\(label)")
            #expect(try server.exec(mysql ? "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'audit'" : "SELECT to_regclass('audit') IS NULL") == (mysql ? "0" : "1"), "\(label)")

            // A session switched back past the checks is read-only again for the next statement
            // of Run All (the runner sends the setting before each one).
            let switchBack = mysql ? "SET SESSION TRANSACTION READ WRITE" : "SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE"
            let reasserted = try await runSaved(server, """
                <?php
                \\RunletRunner\\SqlConnect::pdo()->exec(\(QueryExplain.phpString(switchBack)));
                return \\RunletRunner\\SqlTab::runAll([['sql' => \(QueryExplain.phpString(flag)), 'line' => 1], ['sql' => \(QueryExplain.phpString(flag)), 'line' => 2]], null, 10, false);
                """)
            #expect(reasserted.errors.isEmpty, "\(label): \(reasserted.errors)")
            let values = reasserted.sqlResults.map { $0.rows.first?.first?.text ?? "" }
            #expect(values.count == 2 && ["0", "off"].contains(values[0]) && ["1", "on"].contains(values[1]), "\(label): \(values)")

            // Run All of reads, in a transaction and not.
            for transaction in [true, false] {
                let statements = try SQLScript.statementsToRunAll(in: "SELECT COUNT(*) FROM customers;\nSELECT COUNT(*) FROM orders;", selection: NSRange(location: 0, length: 0)).get()
                let all = try await runSaved(server, SQLTabRun.scriptCode(statements: statements, connection: nil, transaction: transaction))
                #expect(all.errors.isEmpty, "\(label): \(all.errors)")
                #expect(all.sqlResults.count == 2, "\(label)")
            }
            // Run All refuses the whole script when one statement would write.
            let mixed = try SQLScript.statementsToRunAll(in: "SELECT 1;\nINSERT INTO customers (email) VALUES ('x@example.test');", selection: NSRange(location: 0, length: 0)).get()
            let refused = try await runSaved(server, SQLTabRun.scriptCode(statements: mixed, connection: nil, transaction: true))
            #expect(refused.sqlResults.isEmpty, "\(label)")
            #expect(refused.errors.first?.message.hasPrefix("Statement 2 of 2 (line 2) can change data or the schema (INSERT)") == true, "\(label): \(refused.errors)")

            // The same connection without Read-only writes.
            let written = try await runSaved(server, SQLTabRun.code(statement: "INSERT INTO customers (email) VALUES ('rw@example.test')", connection: nil), readOnly: false)
            #expect(written.errors.isEmpty && written.sqlResult?.affectedRows == 1, "\(label): \(written.errors)")
            #expect(try server.exec("SELECT COUNT(*) FROM customers") == "3", "\(label)")
        }
    }
}
