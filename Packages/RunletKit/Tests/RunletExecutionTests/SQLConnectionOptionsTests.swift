import Foundation
@testable import RunletCore
import Testing
@testable import RunletExecution

/// Saved connection options (#140) through the runner, with host PHP: the DSN and PDO
/// attributes each driver gets (sent through the real request), init statements and how they
/// keep a read-only session read-only, custom DSNs, SQL Server DSNs against the host's
/// pdo_sqlsrv (no server: the driver parses them, then reports its missing ODBC driver), PHP
/// 7.4, and that no event of these runs holds the password.
@Suite(.serialized, .enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct SQLConnectionOptionsTests {
    static let target = SQLSavedConnectionTests.target

    /// Reads SQLite's query_only through the saved connection's PDO, after its init statements
    /// (the SQL tab refuses even reading the pragma on a read-only connection).
    static let queryOnly = "<?php echo 'query_only=', \\RunletRunner\\SqlConnect::pdo()->query('PRAGMA query_only')->fetchColumn();"

    /// A connection of `driver` to db.internal (a custom one: an Oracle DSN).
    static func connection(_ driver: DatabaseDriverKind) -> DatabaseConnection {
        var connection = DatabaseConnection(name: "Reporting", scope: target, driver: driver, host: driver.usesHost ? "db.internal" : "", database: driver == .custom ? "" : "reports", user: "reader")
        if driver == .custom { connection.dsn = "oci:dbname=//db.internal:1521/XE" }
        return connection
    }

    /// The PDO drivers of host PHP.
    static let hostDrivers: [String] = {
        let php = Process()
        php.executableURL = URL(fileURLWithPath: DriverSupport.php)
        php.arguments = ["-r", "echo class_exists('PDO') ? implode(',', PDO::getAvailableDrivers()) : '';"]
        let output = Pipe()
        php.standardOutput = output
        guard (try? php.run()) != nil else { return [] }
        php.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: ",").map(String.init)
    }()

    /// Empty files standing in for certificates (the runner checks they exist; nothing reads them).
    static func certificates() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-tls-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["ca.pem", "client.pem", "client.key"] {
            try Data("not a certificate".utf8).write(to: directory.appendingPathComponent(name))
        }
        return directory
    }

    /// `SqlConnect::plan()` for `connection`, sent through the real runner request.
    func plan(_ connection: DatabaseConnection, available: [String], in directory: URL, php: String? = nil) async throws -> (dsn: String, attributes: [String: Any], pdoDriver: String)? {
        let code = "<?php echo json_encode(\\RunletRunner\\SqlConnect::plan([" + available.map { "'\($0)'" }.joined(separator: ", ") + "]));"
        let events = try await SQLSavedConnectionTests.run(code, connection: connection, in: directory, php: php)
        #expect(events.errors.isEmpty, "\(connection.driver): \(events.errors)")
        guard let object = try? JSONSerialization.jsonObject(with: Data(events.stdout.utf8)) as? [String: Any] else { return nil }
        let attributes = (object["attributes"] as? [String: [Any]] ?? [:]).mapValues { $0.count == 2 ? $0[1] : NSNull() }
        return (object["dsn"] as? String ?? "", attributes, object["pdoDriver"] as? String ?? "")
    }

    @Test func eachDriverGetsItsDSNAndAttributes() async throws {
        let directory = try SQLSavedConnectionTests.project()
        let tls = try Self.certificates()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: tls)
        }
        let ca = tls.appendingPathComponent("ca.pem").path
        let cert = tls.appendingPathComponent("client.pem").path
        let key = tls.appendingPathComponent("client.key").path
        let all = ["mysql", "pgsql", "sqlite", "sqlsrv", "dblib", "oci"]

        // MySQL: host and port, charset utf8mb4 by default, and verify-full's attributes.
        var mysql = Self.connection(.mysql)
        mysql.tls = DatabaseTLS(mode: .verifyFull, caFile: ca, certificateFile: cert, keyFile: key)
        mysql.connectTimeout = 7
        let verified = try #require(try await plan(mysql, available: all, in: directory))
        #expect(verified.dsn == "mysql:host=db.internal;port=3306;dbname=reports;charset=utf8mb4")
        #expect(verified.attributes["PDO::ATTR_TIMEOUT"] as? Int == 7)
        #expect(verified.attributes["Pdo\\Mysql::ATTR_SSL_CA"] as? String == ca)
        #expect(verified.attributes["Pdo\\Mysql::ATTR_SSL_CERT"] as? String == cert)
        #expect(verified.attributes["Pdo\\Mysql::ATTR_SSL_KEY"] as? String == key)
        #expect(verified.attributes["Pdo\\Mysql::ATTR_SSL_VERIFY_SERVER_CERT"] as? Bool == true)

        // A socket, a charset, and require: TLS on (an empty CA), the certificate not checked.
        var socket = Self.connection(.mysql)
        socket.socket = "/tmp/mysql.sock"
        socket.charset = "latin1"
        socket.tls = DatabaseTLS(mode: .require)
        let required = try #require(try await plan(socket, available: all, in: directory))
        #expect(required.dsn == "mysql:unix_socket=/tmp/mysql.sock;dbname=reports;charset=latin1")
        #expect(required.attributes["Pdo\\Mysql::ATTR_SSL_CA"] as? String == "")
        #expect(required.attributes["Pdo\\Mysql::ATTR_SSL_VERIFY_SERVER_CERT"] as? Bool == false)

        // Without TLS, no SSL attribute: mysqlnd doesn't encrypt.
        let plain = try #require(try await plan(Self.connection(.mysql), available: all, in: directory))
        #expect(plain.attributes.keys.sorted() == ["PDO::ATTR_TIMEOUT"])

        // PostgreSQL: a socket directory and its port, quoted values, TLS files, the client
        // encoding, and extra options.
        var pgsql = Self.connection(.pgsql)
        pgsql.socket = "/var/run/postgresql"
        pgsql.port = 5433
        pgsql.charset = "UTF8"
        pgsql.tls = DatabaseTLS(mode: .verifyCA, caFile: ca, certificateFile: cert, keyFile: key)
        pgsql.options = [DatabaseOption(key: "application_name", value: "Runlet's tab"), DatabaseOption(key: "target_session_attrs", value: "any")]
        let libpq = try #require(try await plan(pgsql, available: all, in: directory))
        #expect(libpq.dsn == "pgsql:host='/var/run/postgresql';port=5433;dbname='reports';sslmode=verify-ca;sslrootcert='\(ca)';sslcert='\(cert)';sslkey='\(key)';client_encoding='UTF8';application_name='Runlet\\'s tab';target_session_attrs='any'")
        var off = Self.connection(.pgsql)
        off.tls = DatabaseTLS(mode: .disable, caFile: ca)
        #expect(try await plan(off, available: all, in: directory)?.dsn == "pgsql:host=db.internal;port=5432;dbname='reports';sslmode=disable")

        // SQL Server through pdo_sqlsrv: LoginTimeout instead of PDO::ATTR_TIMEOUT (which it
        // rejects), and the TLS keywords; through pdo_dblib when that is all there is.
        var sqlsrv = Self.connection(.sqlsrv)
        sqlsrv.tls = DatabaseTLS(mode: .require)
        sqlsrv.options = [DatabaseOption(key: "APP", value: "Runlet"), DatabaseOption(key: "ApplicationIntent", value: "ReadOnly")]
        let microsoft = try #require(try await plan(sqlsrv, available: all, in: directory))
        #expect(microsoft.dsn == "sqlsrv:Server=db.internal,1433;Database=reports;LoginTimeout=10;Encrypt=yes;TrustServerCertificate=yes;APP=Runlet;ApplicationIntent=ReadOnly")
        #expect(microsoft.attributes.isEmpty && microsoft.pdoDriver == "sqlsrv")
        sqlsrv.tls = DatabaseTLS(mode: .verifyFull)
        #expect(try await plan(sqlsrv, available: all, in: directory)?.dsn.contains(";Encrypt=yes;TrustServerCertificate=no;") == true)
        sqlsrv.tls = DatabaseTLS(mode: .disable)
        #expect(try await plan(sqlsrv, available: all, in: directory)?.dsn.contains(";Encrypt=no;") == true)
        var freeTDS = Self.connection(.sqlsrv)
        freeTDS.port = 14330
        let dblib = try #require(try await plan(freeTDS, available: ["dblib"], in: directory))
        #expect(dblib.dsn == "dblib:host=db.internal:14330;dbname=reports;charset=UTF-8")
        #expect(dblib.pdoDriver == "dblib" && dblib.attributes["PDO::ATTR_TIMEOUT"] as? Int == 10)

        // A custom DSN as typed.
        let custom = try #require(try await plan(Self.connection(.custom), available: all, in: directory))
        #expect(custom.dsn == "oci:dbname=//db.internal:1521/XE" && custom.pdoDriver == "oci")

        // Read-only SQLite still opens the file read-only (#139).
        let sqlite = try #require(try await plan(SQLReadOnlyConnectionTests.readOnly(), available: all, in: directory))
        #expect(sqlite.dsn == "sqlite:data/shop.sqlite")
        #expect(sqlite.attributes.keys.contains { $0.hasSuffix("ATTR_OPEN_FLAGS") })
    }

    @Test func whatADriverCantExpressFailsBeforeConnecting() async throws {
        let directory = try SQLSavedConnectionTests.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        // These definitions don't validate in the app; the runner refuses them again.
        var cases: [(DatabaseConnection, String)] = []
        var mysql = Self.connection(.mysql)
        mysql.tls = DatabaseTLS(mode: .prefer)
        cases.append((mysql, "MySQL's PDO driver can't express the TLS mode prefer"))
        var missingCA = Self.connection(.pgsql)
        missingCA.tls = DatabaseTLS(mode: .verifyFull, caFile: "/nonexistent/runlet-ca.pem")
        cases.append((missingCA, "The CA file /nonexistent/runlet-ca.pem doesn't exist on this target"))
        var option = Self.connection(.pgsql)
        option.options = [DatabaseOption(key: "password", value: SQLSavedConnectionTests.password)]
        cases.append((option, "looks like a password"))
        var leakyDSN = Self.connection(.custom)
        leakyDSN.dsn = "sqlite:data/shop.sqlite;password=" + SQLSavedConnectionTests.password
        cases.append((leakyDSN, "contains a password"))
        var uri = Self.connection(.custom)
        uri.dsn = "uri:file:///etc/hosts"
        cases.append((uri, "can't be a uri: DSN"))
        var oracle = Self.connection(.custom)
        oracle.dsn = "oci:dbname=//db.internal:1521/XE"
        cases.append((oracle, "has no pdo_oci driver for the DSN. It has: "))
        var readOnlyServer = Self.connection(.sqlsrv)
        readOnlyServer.readOnly = true
        cases.append((readOnlyServer, "SQL Server has no read-only session it can enforce"))
        var dblibTLS = Self.connection(.sqlsrv)
        dblibTLS.tls = DatabaseTLS(mode: .require)
        if !Self.hostDrivers.contains("sqlsrv"), !Self.hostDrivers.contains("dblib") {
            cases.append((dblibTLS, "has neither pdo_sqlsrv nor pdo_dblib, which SQL Server needs. It has: "))
        }
        for (connection, phrase) in cases {
            let events = try await SQLSavedConnectionTests.run(SQLTabRun.code(statement: "SELECT 1", connection: nil), connection: connection, in: directory)
            let message = events.errors.first?.message ?? ""
            #expect(message.contains(phrase), "\(connection.summary): \(message)")
            #expect(events.sqlResult == nil)
            for text in events.scannableText {
                #expect(!SQLSavedConnectionTests.leaks(text), "\(connection.summary): \(text)")
            }
        }
    }

    @Test func initStatementsRunFirstOnEveryRunTestAndSchema() async throws {
        let directory = try SQLSavedConnectionTests.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        var connection = SQLSavedConnectionTests.connection()
        connection.initStatements = ["PRAGMA foreign_keys = ON", "CREATE TEMP VIEW recent AS SELECT * FROM customers WHERE id > 1;"]
        #expect(connection.validate().isEmpty)

        let view = try await SQLSavedConnectionTests.run(SQLTabRun.code(statement: "SELECT email FROM recent", connection: nil, schema: true), connection: connection, in: directory)
        #expect(view.errors.isEmpty, "\(view.errors)")
        #expect(view.sqlResult?.rows == [[.string("b@example.test")]])
        #expect(view.sqlSchema?.tables.isEmpty == false)
        let pragma = try await SQLSavedConnectionTests.run(SQLTabRun.code(statement: "PRAGMA foreign_keys", connection: nil), connection: connection, in: directory)
        #expect(pragma.sqlResult?.rows.first?.first?.text == "1", "\(pragma.errors)")

        let (engine, _) = try SQLSavedConnectionTests.engine(for: connection)
        let info = try await engine.testSQLConnection(target: DriverSupport.target(directory.path), connection: connection, password: .stored)
        #expect(info.initStatements == 2)
        #expect(info.tls == nil, "SQLite has no TLS")

        // A failing init statement stops the run before the user's statement.
        connection.initStatements = ["SELECT * FROM no_such_table"]
        let failed = try await SQLSavedConnectionTests.run(SQLTabRun.code(statement: "DELETE FROM customers", connection: nil), connection: connection, in: directory)
        #expect(failed.errors.first?.message.hasPrefix(#"Init statement 1 of the saved connection "Reporting" (sqlite, data/shop.sqlite) failed, so nothing of yours ran"#) == true, "\(failed.errors)")
        #expect(try SQLReadOnlyConnectionTests.count(in: directory) == "2")
        // Transaction control is refused before connecting.
        connection.initStatements = ["BEGIN"]
        let begin = try await SQLSavedConnectionTests.run(SQLTabRun.code(statement: "SELECT 1", connection: nil), connection: connection, in: directory)
        #expect(begin.errors.first?.message.contains("Init statement 1 of the saved connection \"Reporting\" begins or ends a transaction (BEGIN)") == true, "\(begin.errors)")
    }

    @Test func initStatementsKeepAReadOnlySessionReadOnly() async throws {
        let directory = try SQLSavedConnectionTests.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        var connection = SQLReadOnlyConnectionTests.readOnly()
        connection.initStatements = ["SELECT COUNT(*) FROM customers"]
        let read = try await SQLSavedConnectionTests.run(Self.queryOnly, connection: connection, in: directory)
        #expect(read.stdout == "query_only=1", "\(read.stdout) \(read.errors)")

        // Past the app's validation, the runner refuses init statements that would undo
        // read-only or write, before connecting.
        for (statement, phrase) in [("PRAGMA query_only = 0", "would make the read-only session writable again (PRAGMA query_only)"), ("INSERT INTO customers (email) VALUES ('x@example.test')", "can change data or the schema (INSERT)"), ("ATTACH DATABASE 'other.sqlite' AS other", "can change data or the schema (ATTACH)")] {
            connection.initStatements = [statement]
            #expect(!connection.validate().isEmpty, "the app refuses \(statement)")
            let refused = try await SQLSavedConnectionTests.run(SQLTabRun.code(statement: "SELECT 1", connection: nil), connection: connection, in: directory)
            #expect(refused.errors.first?.message == #"Init statement 1 of the saved connection "Replica" "# + phrase + ", so Runlet didn't connect. Nothing ran.", "\(refused.errors)")
        }
        #expect(try SQLReadOnlyConnectionTests.count(in: directory) == "2")
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("other.sqlite").path))
    }

    /// The runner's init rules (SqlReadOnly::initRefusal) agree with the app's.
    @Test func theRunnerAndTheAppAgreeOnInitStatements() async throws {
        let statements: [(String, DatabaseDriverKind?, Bool)] = [
            ("SET search_path TO reports", .pgsql, true), ("SET time_zone = '+00:00'", .mysql, true), ("SET NAMES utf8mb4", .mysql, true),
            ("SET @@session.sql_mode = 'ANSI'", .mysql, true), ("SET ROLE reporting", .pgsql, true), ("SELECT 1", nil, true),
            ("SET GLOBAL max_connections = 10", .mysql, true), ("set @@global.time_zone = '+00:00'", .mysql, true), ("SET PERSIST x = 1", .mysql, true),
            ("SET PASSWORD = 'x'", .mysql, true), ("SET DEFAULT ROLE ALL TO r", .mysql, true), ("SET default_transaction_read_only = off", .pgsql, true),
            ("SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE", .pgsql, true), ("SET SESSION TRANSACTION READ WRITE", .mysql, true),
            ("RESET ALL", .pgsql, true), ("PRAGMA query_only = 0", .sqlite, true), ("INSERT INTO t VALUES (1)", nil, true), ("USE other", .mysql, true),
            ("SELECT set_config('a', 'b', false)", .pgsql, true), ("SET search_path TO x # ; DELETE FROM t", .pgsql, true),
            ("BEGIN", nil, false), ("START TRANSACTION", .mysql, false), ("COMMIT", nil, false), ("SELECT 1; SELECT 2", nil, false), ("-- x", nil, false),
            ("INSERT INTO t VALUES (1)", nil, false), ("SET GLOBAL x = 1", .mysql, false), ("CREATE TEMP TABLE t (id int)", .pgsql, false),
        ]
        let cases = statements.map { "[\(QueryExplain.phpString($0.0)), \($0.1.map { "'\($0.rawValue)'" } ?? "null"), \($0.2 ? "true" : "false")]" }.joined(separator: ", ")
        let code = """
        <?php
        $out = [];
        foreach ([\(cases)] as [$sql, $driver, $readOnly]) {
            $out[] = \\RunletRunner\\SqlReadOnly::initRefusal($sql, $driver, $readOnly);
        }
        echo json_encode($out);
        """
        let events = try await TestSupport.run(code, target: DriverSupport.target(DriverSupport.fixture("plain")), magicComments: false)
        #expect(events.errors.isEmpty, "\(events.errors)")
        let refusals = try #require(try JSONSerialization.jsonObject(with: Data(events.stdout.utf8)) as? [Any], "\(events.stdout)")
        #expect(refusals.count == statements.count)
        for (index, (sql, driver, readOnly)) in statements.enumerated() where index < refusals.count {
            let app = SQLScript.initStatementRefusal(of: sql, driver: driver, readOnly: readOnly)
            let runner = refusals[index] as? String
            #expect((app == nil) == (runner == nil), "\(sql) (read-only \(readOnly)): app \(app ?? "nil"), runner \(runner ?? "nil")")
        }
    }

    @Test func aCustomDSNRunsWithoutRunletParsingIt() async throws {
        let directory = try SQLSavedConnectionTests.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        var connection = Self.connection(.custom)
        connection.dsn = "sqlite:" + directory.appendingPathComponent("data/shop.sqlite").path
        connection.initStatements = ["PRAGMA foreign_keys = ON"]
        #expect(connection.validate().isEmpty)
        let events = try await SQLSavedConnectionTests.run(SQLTabRun.code(statement: "SELECT COUNT(*) AS n FROM orders", connection: nil, schema: true), connection: connection, in: directory)
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.sqlResult?.rows.first?.first?.text == "2")
        #expect(events.sqlResult?.driver == "sqlite")
        #expect(events.sqlResult?.source?.hasPrefix(#"saved connection "Reporting" (custom, sqlite:/"#) == true, "\(events.sqlResult?.source ?? "")")
        #expect(events.sqlSchema?.table(named: "orders") != nil)

        let (engine, _) = try SQLSavedConnectionTests.engine(for: connection)
        let info = try await engine.testSQLConnection(target: DriverSupport.target(directory.path), connection: connection, password: .stored)
        #expect(info.driver == "sqlite" && info.initStatements == 1)
        #expect(info.summary.hasPrefix("Connected: SQLite"), "\(info.summary)")
    }

    @Test(.enabled(if: SQLConnectionOptionsTests.hostDrivers.contains("sqlsrv"), "requires pdo_sqlsrv in host PHP"))
    func sqlServerDSNsAreAcceptedByPdoSqlsrv() async throws {
        let directory = try SQLSavedConnectionTests.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        // pdo_sqlsrv parses the DSN's keywords before it needs Microsoft's ODBC driver (or a
        // server): each DSN Runlet builds gets past the keywords, to the ODBC driver or the
        // network, never "invalid keyword".
        for mode in [nil, DatabaseTLSMode.disable, .require, .verifyFull] {
            var connection = Self.connection(.sqlsrv)
            connection.host = "127.0.0.1"
            connection.port = 1
            connection.connectTimeout = 2
            connection.tls = mode.map { DatabaseTLS(mode: $0) }
            connection.options = [DatabaseOption(key: "APP", value: "Runlet"), DatabaseOption(key: "MultiSubnetFailover", value: "no")]
            #expect(connection.validate().isEmpty)
            let (engine, _) = try SQLSavedConnectionTests.engine(for: connection)
            do {
                _ = try await engine.testSQLConnection(target: DriverSupport.target(directory.path), connection: connection, password: .stored)
                Issue.record("no SQL Server listens on 127.0.0.1:1")
            } catch {
                let message = "\(error)"
                #expect(message.hasPrefix(#"Runlet could not open the saved connection "Reporting" (sqlsrv, 127.0.0.1:1/reports)"#), "\(message)")
                #expect(!message.contains("invalid keyword"), "\(mode.map(\.rawValue) ?? "default"): \(message)")
                #expect(!SQLSavedConnectionTests.leaks(message))
            }
        }
        // A keyword pdo_sqlsrv doesn't know reaches the user in its own words.
        var unknown = Self.connection(.sqlsrv)
        unknown.options = [DatabaseOption(key: "Bogus", value: "1")]
        let (engine, _) = try SQLSavedConnectionTests.engine(for: unknown)
        await #expect {
            _ = try await engine.testSQLConnection(target: DriverSupport.target(directory.path), connection: unknown, password: .stored)
        } throws: { error in
            "\(error)".contains("An invalid keyword 'Bogus' was specified in the DSN string")
        }
    }

    @Test(.enabled(if: TestSupport.herdPHP74 != nil, "requires Herd's PHP 7.4"))
    func phpSevenFourGetsThePDOConstantsAndRunsInitStatements() async throws {
        let directory = try SQLSavedConnectionTests.project()
        let tls = try Self.certificates()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: tls)
        }
        var mysql = Self.connection(.mysql)
        mysql.tls = DatabaseTLS(mode: .verifyFull, caFile: tls.appendingPathComponent("ca.pem").path)
        let plan = try #require(try await plan(mysql, available: ["mysql"], in: directory, php: TestSupport.herdPHP74))
        #expect(plan.attributes["PDO::MYSQL_ATTR_SSL_CA"] as? String == tls.appendingPathComponent("ca.pem").path)
        #expect(plan.attributes["PDO::MYSQL_ATTR_SSL_VERIFY_SERVER_CERT"] as? Bool == true)

        var connection = SQLReadOnlyConnectionTests.readOnly()
        connection.initStatements = ["SELECT 1"]
        let events = try await SQLSavedConnectionTests.run(Self.queryOnly, connection: connection, in: directory, php: TestSupport.herdPHP74)
        #expect(events.started?.phpVersion?.hasPrefix("7.4") == true)
        #expect(events.stdout == "query_only=1", "\(events.stdout) \(events.errors)")
        connection.initStatements = ["PRAGMA query_only = 0"]
        let refused = try await SQLSavedConnectionTests.run(SQLTabRun.code(statement: "SELECT 1", connection: nil), connection: connection, in: directory, php: TestSupport.herdPHP74)
        #expect(refused.errors.first?.message.contains("would make the read-only session writable again") == true, "\(refused.errors)")
    }
}
