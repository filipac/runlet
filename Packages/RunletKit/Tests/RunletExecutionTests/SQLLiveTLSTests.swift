import Foundation
@testable import RunletCore
import Testing
@testable import RunletExecution

/// Saved connection options (#140) against the live MariaDB 11 and PostgreSQL 14 fixtures,
/// which offer TLS with throwaway certificates (`scripts/setup-fixtures.sh databases` prints
/// `RUNLET_TEST_TLS`, the folder with `ca.crt`, `other-ca.crt`, `client.crt`, `client.key`):
/// each TLS mode, a CA that didn't sign the server, a host name the certificate doesn't name,
/// client certificates, charsets, extra options, and init statements on read-only
/// connections. Objects these tests create are prefixed `p140_` and dropped afterwards.
@Suite(.serialized, .enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct SQLLiveTLSTests {
    typealias Server = SQLLiveDatabaseTests.Server

    static let tls: URL? = {
        guard let path = ProcessInfo.processInfo.environment["RUNLET_TEST_TLS"], !path.isEmpty,
              FileManager.default.fileExists(atPath: path + "/client.key") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }()

    static var enabled: Bool { tls != nil && !SQLLiveDatabaseTests.servers.isEmpty }

    static func file(_ name: String) -> String { tls!.appendingPathComponent(name).path }

    static let plain = DriverSupport.fixture("plain")

    /// Test Connection for `connection` with the server's (or `password`'s) password.
    static func test(_ connection: DatabaseConnection, server: Server, password: String? = nil, php: String? = nil) async throws -> SQLConnectionTestInfo {
        let (_, store) = SQLLiveDatabaseTests.saved(server)
        try store.set(SensitiveString(password ?? server.password), for: connection.id, label: "Runlet database: test")
        return try await ExecutionEngine(bundle: TestSupport.bundle, docker: nil, credentials: store).testSQLConnection(target: DriverSupport.target(plain, php: php), connection: connection, password: .stored)
    }

    /// Runs `code` on `connection`.
    static func run(_ code: String, _ connection: DatabaseConnection, server: Server, password: String? = nil) async throws -> [RunEvent] {
        let (_, store) = SQLLiveDatabaseTests.saved(server)
        try store.set(SensitiveString(password ?? server.password), for: connection.id, label: "Runlet database: test")
        var request = RunRequest(tabId: UUID(), documentVersion: 1, target: DriverSupport.target(plain), code: code, magicComments: false)
        request.sqlConnection = connection
        // The engine must outlive the run: its launch task holds it weakly.
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil, credentials: store)
        var events: [RunEvent] = []
        for await event in try await engine.start(request) { events.append(event) }
        return events
    }

    /// The single value `sql` returns on `connection`.
    static func value(_ sql: String, _ connection: DatabaseConnection, server: Server, password: String? = nil) async throws -> String? {
        let events = try await run(SQLTabRun.code(statement: sql, connection: nil), connection, server: server, password: password)
        #expect(events.errors.isEmpty, "\(sql): \(events.errors)")
        return events.sqlResult?.rows.first?.first?.text
    }

    static func failure(_ connection: DatabaseConnection, server: Server, password: String? = nil) async -> String {
        do {
            let info = try await test(connection, server: server, password: password)
            return "connected: \(info.summary)"
        } catch {
            return "\(error)"
        }
    }

    // MARK: PostgreSQL

    @Test(.enabled(if: enabled && SQLLiveDatabaseTests.pgsql != nil, "set RUNLET_TEST_PGSQL and RUNLET_TEST_TLS"))
    func postgresTLSModesAndCertificates() async throws {
        let server = try #require(SQLLiveDatabaseTests.pgsql)
        let (base, _) = SQLLiveDatabaseTests.saved(server)
        func with(_ tls: DatabaseTLS?, _ configure: (inout DatabaseConnection) -> Void = { _ in }) -> DatabaseConnection {
            var connection = base
            connection.tls = tls
            configure(&connection)
            #expect(connection.validate().isEmpty, "\(connection.validate())")
            return connection
        }

        // Off, and each mode that encrypts; Test Connection says which (pg_stat_ssl).
        let off = try await Self.test(with(DatabaseTLS(mode: .disable)), server: server)
        #expect(off.tls == false && off.summary.hasSuffix("· not encrypted"), "\(off.summary)")
        for mode in [DatabaseTLSMode.prefer, .require] {
            let info = try await Self.test(with(DatabaseTLS(mode: mode)), server: server)
            #expect(info.tls == true && info.tlsVersion?.hasPrefix("TLSv1.") == true, "\(mode): \(info.summary)")
        }
        for mode in [DatabaseTLSMode.verifyCA, .verifyFull] {
            let info = try await Self.test(with(DatabaseTLS(mode: mode, caFile: Self.file("ca.crt"))), server: server)
            #expect(info.tls == true && info.tlsCipher?.isEmpty == false, "\(mode): \(info.summary)")
        }

        // A CA that didn't sign the server's certificate fails the checks; libpq checks the CA
        // with Require too when it has a CA file.
        for mode in [DatabaseTLSMode.require, .verifyCA, .verifyFull] {
            let message = await Self.failure(with(DatabaseTLS(mode: mode, caFile: Self.file("other-ca.crt"))), server: server)
            #expect(message.contains("Runlet could not open the saved connection") && message.contains("certificate verify failed"), "\(mode): \(message)")
        }

        // A host name the certificate doesn't name (connecting to 127.0.0.1 through hostaddr):
        // verify-ca passes, verify-full refuses.
        let renamed: (inout DatabaseConnection) -> Void = {
            $0.host = "runlet-wrong-name.test"
            $0.options = [DatabaseOption(key: "hostaddr", value: "127.0.0.1")]
        }
        #expect(try await Self.test(with(DatabaseTLS(mode: .verifyCA, caFile: Self.file("ca.crt")), renamed), server: server).tls == true)
        let mismatch = await Self.failure(with(DatabaseTLS(mode: .verifyFull, caFile: Self.file("ca.crt")), renamed), server: server)
        #expect(mismatch.contains("does not match host name"), "\(mismatch)")

        // A client certificate reaches the server.
        let client = with(DatabaseTLS(mode: .verifyFull, caFile: Self.file("ca.crt"), certificateFile: Self.file("client.crt"), keyFile: Self.file("client.key")))
        let clientDN = try await Self.value("SELECT client_dn FROM pg_stat_ssl WHERE pid = pg_backend_pid()", client, server: server)
        // The certificate's name holds the fixture password ("runlet-fixture"), so the runner
        // scrubs it from the result: "/CN=•••-client".
        #expect(clientDN?.hasPrefix("/CN=") == true && clientDN?.hasSuffix("-client") == true, "\(clientDN ?? "nil")")

        // The charset and extra options.
        let encoded = with(nil) {
            $0.charset = "LATIN1"
            $0.options = [DatabaseOption(key: "application_name", value: "Runlet p140 test")]
        }
        #expect(try await Self.value("SHOW client_encoding", encoded, server: server) == "LATIN1")
        #expect(try await Self.value("SELECT current_setting('application_name')", encoded, server: server) == "Runlet p140 test")

        // PHP 7.4 opens the verified connection too.
        if let php = TestSupport.herdPHP74 {
            let info = try await Self.test(client, server: server, php: php)
            #expect(info.phpVersion?.hasPrefix("7.4") == true && info.tls == true, "\(info.summary)")
        }
    }

    @Test(.enabled(if: enabled && SQLLiveDatabaseTests.pgsql != nil, "set RUNLET_TEST_PGSQL and RUNLET_TEST_TLS"))
    func postgresInitStatementsOnAReadOnlyConnection() async throws {
        let server = try #require(SQLLiveDatabaseTests.pgsql)
        defer { _ = try? server.exec("DROP SCHEMA IF EXISTS p140_reports CASCADE") }
        _ = try server.exec("DROP SCHEMA IF EXISTS p140_reports CASCADE")
        _ = try server.exec("CREATE SCHEMA p140_reports")
        _ = try server.exec("CREATE TABLE p140_reports.p140_audit (id serial PRIMARY KEY, at timestamptz DEFAULT now())")
        _ = try server.exec("CREATE FUNCTION p140_reports.p140_bump() RETURNS int LANGUAGE sql AS 'INSERT INTO p140_reports.p140_audit DEFAULT VALUES RETURNING id'")

        var (connection, _) = SQLLiveDatabaseTests.saved(server)
        connection.readOnly = true
        connection.tls = DatabaseTLS(mode: .verifyFull, caFile: Self.file("ca.crt"))
        connection.initStatements = ["SET search_path TO p140_reports, public", "SET TIME ZONE 'UTC'"]
        #expect(connection.validate().isEmpty, "\(connection.validate())")
        let info = try await Self.test(connection, server: server)
        #expect(info.readOnly == true && info.initStatements == 2 && info.tls == true, "\(info.summary)")
        #expect(try await Self.value("SHOW search_path", connection, server: server) == "p140_reports, public")
        #expect(try await Self.value("SELECT COUNT(*) FROM p140_audit", connection, server: server) == "0", "the search path finds the table")
        #expect(try await Self.value("SHOW transaction_read_only", connection, server: server) == "on")

        // A read that writes, past the rules (a function): the session is already read-only
        // when init statements run, so the database refuses it, and nothing of the user's runs.
        connection.initStatements = ["SELECT p140_reports.p140_bump()"]
        #expect(connection.validate().isEmpty, "the rules can't see inside functions")
        let refused = try await Self.run(SQLTabRun.code(statement: "SELECT 1", connection: nil), connection, server: server)
        let message = refused.errors.first?.message ?? ""
        #expect(message.hasPrefix(#"Init statement 1 of the saved connection "Reporting replica""#) && message.contains("read-only transaction"), "\(message)")
        #expect(refused.sqlResult == nil)
        #expect(try server.exec("SELECT COUNT(*) FROM p140_reports.p140_audit") == "0")

        // Past the app's validation, the runner refuses an init statement that would undo
        // read-only, before connecting.
        connection.initStatements = ["SET default_transaction_read_only = off"]
        let undone = try await Self.run(SQLTabRun.code(statement: "SELECT 1", connection: nil), connection, server: server)
        #expect(undone.errors.first?.message.contains("would make the read-only session writable again") == true, "\(undone.errors)")

        // Without Read-only, the same function writes.
        connection.readOnly = false
        connection.initStatements = ["SELECT p140_reports.p140_bump()"]
        #expect(try await Self.value("SELECT COUNT(*) FROM p140_reports.p140_audit", connection, server: server) == "1")
    }

    // MARK: MariaDB

    @Test(.enabled(if: enabled && SQLLiveDatabaseTests.mysql != nil, "set RUNLET_TEST_MYSQL and RUNLET_TEST_TLS"))
    func mariaDBTLSModesAndUsersThatRequireIt() async throws {
        let server = try #require(SQLLiveDatabaseTests.mysql)
        let userPassword = "p140-fixture-Pw"
        defer {
            _ = try? server.exec("DROP USER IF EXISTS 'p140_tls'@'%', 'p140_x509'@'%'")
        }
        _ = try server.exec("DROP USER IF EXISTS 'p140_tls'@'%', 'p140_x509'@'%'")
        _ = try server.exec("CREATE USER 'p140_tls'@'%' IDENTIFIED BY '\(userPassword)' REQUIRE SSL")
        _ = try server.exec("CREATE USER 'p140_x509'@'%' IDENTIFIED BY '\(userPassword)' REQUIRE X509")
        let (base, _) = SQLLiveDatabaseTests.saved(server)
        func with(_ tls: DatabaseTLS?, user: String? = nil, _ configure: (inout DatabaseConnection) -> Void = { _ in }) -> DatabaseConnection {
            var connection = base
            connection.tls = tls
            if let user {
                connection.user = user
                connection.database = ""
            }
            configure(&connection)
            #expect(connection.validate().isEmpty, "\(connection.validate())")
            return connection
        }

        // mysqlnd encrypts only when asked.
        for tls in [nil, DatabaseTLS(mode: .disable)] {
            let info = try await Self.test(with(tls), server: server)
            #expect(info.tls == false, "\(String(describing: tls)): \(info.summary)")
        }
        let required = try await Self.test(with(DatabaseTLS(mode: .require)), server: server)
        #expect(required.tls == true && required.tlsVersion?.hasPrefix("TLSv1.") == true, "\(required.summary)")
        let verified = try await Self.test(with(DatabaseTLS(mode: .verifyFull, caFile: Self.file("ca.crt"))), server: server)
        #expect(verified.tls == true && verified.tlsCipher?.isEmpty == false, "\(verified.summary)")
        // Require doesn't check the certificate; verify-full refuses a CA that didn't sign it.
        #expect(try await Self.test(with(DatabaseTLS(mode: .require, caFile: Self.file("other-ca.crt"))), server: server).tls == true)
        let wrongCA = await Self.failure(with(DatabaseTLS(mode: .verifyFull, caFile: Self.file("other-ca.crt"))), server: server)
        #expect(wrongCA.contains("Runlet could not open the saved connection") && !wrongCA.contains(server.password), "\(wrongCA)")

        // A user that requires TLS: refused without it, admitted with it.
        let tlsUser = await Self.failure(with(nil, user: "p140_tls"), server: server, password: userPassword)
        #expect(tlsUser.contains("Access denied"), "\(tlsUser)")
        #expect(try await Self.test(with(DatabaseTLS(mode: .require), user: "p140_tls"), server: server, password: userPassword).user?.hasPrefix("p140_tls@") == true)
        // A user that requires a client certificate.
        let noCertificate = await Self.failure(with(DatabaseTLS(mode: .require), user: "p140_x509"), server: server, password: userPassword)
        #expect(noCertificate.contains("Access denied"), "\(noCertificate)")
        let certificate = with(DatabaseTLS(mode: .verifyFull, caFile: Self.file("ca.crt"), certificateFile: Self.file("client.crt"), keyFile: Self.file("client.key")), user: "p140_x509")
        #expect(try await Self.test(certificate, server: server, password: userPassword).tls == true)

        // The charset.
        #expect(try await Self.value("SELECT @@character_set_client", with(nil) { $0.charset = "latin1" }, server: server) == "latin1")
        #expect(try await Self.value("SELECT @@character_set_client", with(nil), server: server) == "utf8mb4")

        // PHP 7.4 encrypts too (its build crashes when a verification fails, so only successes).
        if let php = TestSupport.herdPHP74 {
            let info = try await Self.test(with(DatabaseTLS(mode: .verifyFull, caFile: Self.file("ca.crt"))), server: server, php: php)
            #expect(info.phpVersion?.hasPrefix("7.4") == true && info.tls == true, "\(info.summary)")
        }
    }

    @Test(.enabled(if: enabled && SQLLiveDatabaseTests.mysql != nil, "set RUNLET_TEST_MYSQL and RUNLET_TEST_TLS"))
    func mariaDBInitStatementsOnAReadOnlyConnection() async throws {
        let server = try #require(SQLLiveDatabaseTests.mysql)
        defer {
            _ = try? server.exec("DROP FUNCTION IF EXISTS p140_bump")
            _ = try? server.exec("DROP TABLE IF EXISTS p140_audit")
        }
        _ = try server.exec("DROP FUNCTION IF EXISTS p140_bump")
        _ = try server.exec("DROP TABLE IF EXISTS p140_audit")
        _ = try server.exec("CREATE TABLE p140_audit (id INT AUTO_INCREMENT PRIMARY KEY)")
        _ = try server.exec("CREATE FUNCTION p140_bump() RETURNS INT MODIFIES SQL DATA BEGIN INSERT INTO p140_audit VALUES (); RETURN LAST_INSERT_ID(); END")

        var (connection, _) = SQLLiveDatabaseTests.saved(server)
        connection.readOnly = true
        connection.tls = DatabaseTLS(mode: .require)
        connection.initStatements = ["SET time_zone = '+00:00'", "SET SESSION sql_mode = 'ANSI_QUOTES'"]
        #expect(connection.validate().isEmpty, "\(connection.validate())")
        let info = try await Self.test(connection, server: server)
        #expect(info.readOnly == true && info.initStatements == 2 && info.tls == true, "\(info.summary)")
        #expect(try await Self.value("SELECT @@session.time_zone", connection, server: server) == "+00:00")
        #expect(try await Self.value("SELECT @@session.sql_mode", connection, server: server) == "ANSI_QUOTES")
        #expect(try await Self.value("SELECT @@session.transaction_read_only", connection, server: server) == "1")

        // A session SET that writes through a function: allowed by the rules, refused by the
        // read-only session it runs in.
        connection.initStatements = ["SET @bumped = p140_bump()"]
        #expect(connection.validate().isEmpty, "the rules can't see inside functions")
        let refused = try await Self.run(SQLTabRun.code(statement: "SELECT 1", connection: nil), connection, server: server)
        let message = refused.errors.first?.message ?? ""
        #expect(message.hasPrefix(#"Init statement 1 of the saved connection "Reporting replica""#) && message.contains("READ ONLY"), "\(message)")
        #expect(try server.exec("SELECT COUNT(*) FROM p140_audit") == "0")

        // Server-wide settings are refused before connecting.
        connection.initStatements = ["SET GLOBAL max_connections = 10"]
        #expect(!connection.validate().isEmpty)
        let global = try await Self.run(SQLTabRun.code(statement: "SELECT 1", connection: nil), connection, server: server)
        #expect(global.errors.first?.message.contains("changes a server-wide setting") == true, "\(global.errors)")
    }
}
