import Foundation
@testable import RunletCore
import Testing
@testable import RunletExecution

/// The run inspector's Explain (#4) showing #147's plan tree (#170) against live MariaDB and
/// PostgreSQL: a captured PDO query's Explain tab (and that its DELETE never runs), and the
/// same plan through Eloquent (Capsule) and Doctrine DBAL 3/4 connections. They run only when
/// `RUNLET_TEST_MYSQL` / `RUNLET_TEST_PGSQL` are set (see SQLLiveDatabaseTests). The table is
/// `p170_customers`, created again by each test.
@Suite(.serialized, .live(.sql), .enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct QueryExplainLiveTests {
    typealias Server = SQLLiveDatabaseTests.Server
    static var servers: [Server] { SQLLiveDatabaseTests.servers }

    static func setup(_ server: Server) throws {
        let mysql = server.dialect == "mysql"
        let rows = (1...200).map { "('c\($0)@example.test', '\($0 % 2 == 0 ? "RO" : "UK")')" }.joined(separator: ", ")
        for statement in [
            "DROP TABLE IF EXISTS p170_customers",
            mysql
                ? "CREATE TABLE p170_customers (id INT AUTO_INCREMENT PRIMARY KEY, email VARCHAR(190) NOT NULL, country VARCHAR(2)) ENGINE=InnoDB"
                : "CREATE TABLE p170_customers (id SERIAL PRIMARY KEY, email VARCHAR(190) NOT NULL, country VARCHAR(2))",
            "INSERT INTO p170_customers (email, country) VALUES \(rows)",
            mysql ? "ANALYZE TABLE p170_customers" : "ANALYZE p170_customers",
        ] { _ = try server.exec(statement) }
    }

    static func pdo(_ server: Server) -> String {
        "new PDO(\(Server.php(server.dsn)), \(Server.php(server.user)), \(Server.php(server.password)), [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION])"
    }

    /// `host`, `port`, and `dbname` of the server's DSN.
    static func fields(_ server: Server) -> [String: String] {
        var fields: [String: String] = [:]
        for part in server.dsn.drop(while: { $0 != ":" }).dropFirst().split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { fields[pair[0]] = pair[1] }
        }
        return fields
    }

    func count(_ server: Server) throws -> String {
        try server.exec("SELECT COUNT(*) FROM p170_customers")
    }

    @Test(.enabled(if: !servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func capturedPDOQueriesShowJSONPlans() async throws {
        let target = DriverSupport.target(DriverSupport.fixture("plain"))
        for server in Self.servers {
            try Self.setup(server)
            let label = server.dialect
            let mysql = server.dialect == "mysql"
            let captured = try await TestSupport.run("""
            $pdo = \(Self.pdo(server));
            \\Runlet\\Inspector::current()->watchPdo($pdo, 'reporting');
            $select = $pdo->prepare('SELECT * FROM p170_customers WHERE country = ?');
            $select->bindValue(1, 'UK', PDO::PARAM_STR);
            $select->execute();
            $delete = $pdo->prepare('DELETE FROM p170_customers WHERE id = ?');
            $delete->bindValue(1, 1, PDO::PARAM_INT);
            $delete->execute();
            """, target: target, magicComments: false)
            #expect(captured.errors.isEmpty, "\(label): \(captured.errors)")
            let queries = captured.inspection.queries.map(\.query)
            let select = try #require(queries.first { $0.sql.hasPrefix("SELECT") }, "\(label)")
            let delete = try #require(queries.first { $0.sql.hasPrefix("DELETE") }, "\(label)")
            #expect(select.driver == server.dialect && select.databaseAPI == "pdo" && select.connection == "reporting", "\(label)")
            let explained = mysql ? "EXPLAIN FORMAT=JSON" : "EXPLAIN (FORMAT JSON)"

            // PostgreSQL may scan a table this small even by its primary key.
            for (query, scans) in [(select, 1), (delete, nil)] as [(QueryRecord, Int?)] {
                // Explain the DELETE of a row that is still there: it must stay.
                let code = try #require(QueryExplain.code(for: query, style: .pdo)).replacingOccurrences(of: "    0 => 1,", with: "    0 => 2,")
                #expect(!code.uppercased().contains("ANALYZE"))
                let before = try count(server)
                let events = try await TestSupport.run("$pdo = \(Self.pdo(server));\n\\Runlet\\Inspector::current()->watchPdo($pdo, 'reporting');\n" + code, target: target, magicComments: false)
                #expect(events.errors.isEmpty, "\(label): \(events.errors)")
                let info = try #require(events.sqlPlan, "\(label) \(query.sql)")
                #expect(info.dialect == (mysql ? "mariadb" : "pgsql") && info.format == "json", "\(label)")
                #expect(info.explained == explained && info.analyze == false, "\(label)")
                #expect(info.connection == "reporting" && info.source == "PDO", "\(label)")
                #expect(info.databaseName.hasPrefix(mysql ? "MariaDB 1" : "PostgreSQL 1"), "\(label): \(info.databaseName)")
                let plan = try #require(info.plan, "\(label): \(info.parseError ?? "")")
                #expect(!plan.nodes.isEmpty && (scans == nil || plan.fullScans.count == scans), "\(label) \(query.sql): \(plan.text)")
                #expect(!plan.analyzed, "\(label)")
                #expect(events.result?.hasValue == false, "\(label)")
                #expect(try count(server) == before, "\(label): Explain ran the DELETE")
                let ran = try #require(events.inspection.queries.first { $0.query.sql.hasPrefix("EXPLAIN") }?.query, "\(label)")
                #expect(ran.sql == explained + " " + query.sql, "\(label)")
                #expect(ran.bindings == (query.sql.hasPrefix("DELETE") ? [.init(type: "int", value: "2")] : query.bindings), "\(label)")
            }
            #expect(try server.exec("SELECT COUNT(*) FROM p170_customers WHERE id = 2") == "1", "\(label)")
        }
    }

    @Test(.enabled(if: !servers.isEmpty && ["eloquent-app", "eloquent-app-modern"].allSatisfy {
        FileManager.default.fileExists(atPath: DriverSupport.fixture($0) + "/vendor/autoload.php")
    }, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL; requires the Eloquent/DBAL 3/4 fixtures"))
    func eloquentAndDoctrineConnectionsShowJSONPlans() async throws {
        for fixture in ["eloquent-app", "eloquent-app-modern"] {
            let target = DriverSupport.target(DriverSupport.fixture(fixture))
            for server in Self.servers {
                try Self.setup(server)
                let label = "\(fixture) \(server.dialect)"
                let mysql = server.dialect == "mysql"
                let fields = Self.fields(server)
                let (host, port, database) = (Server.php(fields["host"] ?? "127.0.0.1"), fields["port"] ?? "0", Server.php(fields["dbname"] ?? "shop"))
                let user = Server.php(server.user), password = Server.php(server.password)
                let sql = mysql ? "select * from `p170_customers` where `country` = ?" : #"select * from "p170_customers" where "country" = ?"#
                let capsule = """
                $capsule = new \\Illuminate\\Database\\Capsule\\Manager();
                $capsule->addConnection(['driver' => '\(server.dialect)', 'host' => \(host), 'port' => \(port), 'database' => \(database), 'username' => \(user), 'password' => \(password)], 'live');
                $capsule->setAsGlobal();
                $capsule->bootEloquent();

                """
                let dbal = "$connection = \\Doctrine\\DBAL\\DriverManager::getConnection(['driver' => 'pdo_\(server.dialect)', 'host' => \(host), 'port' => \(port), 'dbname' => \(database), 'user' => \(user), 'password' => \(password)]);\n"
                for (api, style, setup, source) in [("eloquent", QueryExplain.ConnectionStyle.eloquent, capsule, "Illuminate database connection"),
                                                    ("doctrine", .doctrineManual, dbal, "Doctrine DBAL")] {
                    let query = QueryRecord(sql: sql, bindings: [.init(type: "string", value: "UK")], connection: "live", driver: server.dialect, databaseAPI: api)
                    let code = try #require(QueryExplain.code(for: query, style: style))
                    let events = try await TestSupport.run(setup + code, target: target, magicComments: false)
                    #expect(events.errors.isEmpty, "\(label) \(api): \(events.errors)")
                    let info = try #require(events.sqlPlan, "\(label) \(api)")
                    #expect(info.dialect == (mysql ? "mariadb" : "pgsql") && info.format == "json", "\(label) \(api)")
                    #expect(info.source == source && info.connection == "live", "\(label) \(api)")
                    #expect(info.plan?.fullScans.count == 1, "\(label) \(api): \(info.parseError ?? info.plan?.text ?? "")")
                }
            }
        }
    }
}
