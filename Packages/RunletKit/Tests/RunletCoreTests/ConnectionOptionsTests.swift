import Foundation
import Testing
@testable import RunletCore

/// Saved connection options (#140): socket, charset, TLS, init statements, extra DSN options,
/// SQL Server, and custom DSNs. Their storage (older files load unchanged, new keys only when
/// set), normalization, validation per driver, the init statement rules, and that no option
/// can carry a password.
struct ConnectionOptionsTests {
    static let target = TargetRef.local(UUID())

    static func connection(_ driver: DatabaseDriverKind = .pgsql, configure: (inout DatabaseConnection) -> Void = { _ in }) -> DatabaseConnection {
        var connection = DatabaseConnection(name: "Reporting", scope: target, driver: driver, host: driver.usesHost ? "db.internal" : "", database: driver == .sqlite ? "data/app.sqlite" : driver == .custom ? "" : "reports", user: driver == .sqlite ? "" : "reader")
        if driver == .custom { connection.dsn = "oci:dbname=//db.internal:1521/XE" }
        configure(&connection)
        return connection
    }

    func errors(_ connection: DatabaseConnection) -> [DatabaseConnection.ValidationError] {
        connection.validate()
    }

    // MARK: Storage

    @Test func connectionsSavedBeforeThisPhaseKeepTheirKeys() throws {
        let legacy = #"{"id":"\#(UUID().uuidString)","name":"Legacy","scope":{"local":{"_0":"\#(UUID().uuidString)"}},"driver":"mysql","host":"db","database":"shop","user":"u","connectTimeout":10,"readOnly":true,"revision":2}"#
        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: Data(legacy.utf8))
        #expect(decoded.socket == nil && decoded.charset == nil && decoded.tls == nil && decoded.dsn == nil)
        #expect(decoded.initStatements.isEmpty && decoded.options.isEmpty)
        let keys = Set(try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]).keys)
        #expect(keys == ["id", "name", "scope", "driver", "host", "database", "user", "connectTimeout", "readOnly", "revision"])
    }

    @Test func optionsRoundTripAndAreWrittenOnlyWhenSet() throws {
        let full = Self.connection(.pgsql) {
            $0.socket = "/var/run/postgresql"
            $0.charset = "UTF8"
            $0.tls = DatabaseTLS(mode: .verifyFull, caFile: "/etc/ssl/db-ca.pem", certificateFile: "/etc/ssl/client.pem", keyFile: "/etc/ssl/client.key")
            $0.initStatements = ["SET search_path TO reports", "SET TIME ZONE 'UTC'"]
            $0.options = [DatabaseOption(key: "application_name", value: "Runlet"), DatabaseOption(key: "target_session_attrs", value: "read-only")]
        }
        let data = try JSONEncoder().encode(full)
        #expect(try JSONDecoder().decode(DatabaseConnection.self, from: data) == full)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["tls"] as? [String: String] == ["mode": "verify-full", "ca": "/etc/ssl/db-ca.pem", "cert": "/etc/ssl/client.pem", "key": "/etc/ssl/client.key"])
        #expect(object["initStatements"] as? [String] == ["SET search_path TO reports", "SET TIME ZONE 'UTC'"])
        #expect(object["socket"] as? String == "/var/run/postgresql")

        let custom = Self.connection(.custom)
        let customKeys = Set(try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(custom)) as? [String: Any]).keys)
        #expect(customKeys.contains("dsn") && !customKeys.contains("tls") && !customKeys.contains("options") && !customKeys.contains("initStatements"))
        #expect(!String(decoding: data, as: UTF8.self).lowercased().contains("password"))
    }

    @Test func aTLSSettingFromANewerRunletLeavesTheConnectionOut() throws {
        let target = UUID()
        let file = #"""
        {"localProjects":[{"id":"\#(target.uuidString)","name":"Shop","path":"/tmp/shop","revision":1}],
         "databaseConnections":[
          {"id":"\#(UUID().uuidString)","name":"Future","scope":{"local":{"_0":"\#(target.uuidString)"}},"driver":"pgsql","host":"db","database":"","user":"","connectTimeout":10,"tls":{"mode":"verify-quantum"},"revision":1},
          {"id":"\#(UUID().uuidString)","name":"Kept","scope":{"local":{"_0":"\#(target.uuidString)"}},"driver":"sqlsrv","host":"sql","database":"erp","user":"sa","connectTimeout":10,"tls":{"mode":"require"},"revision":1},
          {"id":"\#(UUID().uuidString)","name":"Lenient","scope":{"local":{"_0":"\#(target.uuidString)"}},"driver":"pgsql","host":"db","database":"","user":"","connectTimeout":10,"initStatements":"SET x = 1","revision":1}
         ]}
        """#
        let library = try JSONDecoder().decode(TargetLibrary.self, from: Data(file.utf8))
        #expect(library.databaseConnections.map(\.name) == ["Kept", "Lenient"])
        #expect(library.databaseConnections.first?.tls == DatabaseTLS(mode: .require))
        #expect(library.databaseConnections.last?.initStatements == [])
    }

    @Test func runRequestsCarryTheOptions() throws {
        var request = RunRequest(tabId: UUID(), documentVersion: 1, target: TargetSnapshot(kind: .local, label: "Shop", targetId: "x", workingDirectory: "/tmp", phpExecutable: "php"), code: "<?php")
        request.sqlConnection = Self.connection(.mysql) {
            $0.tls = DatabaseTLS(mode: .require)
            $0.initStatements = ["SET time_zone = '+00:00'"]
        }
        let decoded = try JSONDecoder().decode(RunRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded.sqlConnection?.tls?.mode == .require)
        #expect(decoded.sqlConnection?.initStatements == ["SET time_zone = '+00:00'"])
    }

    // MARK: Normalization

    @Test func normalizedDropsWhatTheDriverHasNot() {
        // A socket replaces the host, and MySQL's port; PostgreSQL's port names the socket file.
        let mysql = Self.connection(.mysql) {
            $0.socket = " /tmp/mysql.sock "
            $0.port = 3307
        }.normalized
        #expect(mysql.socket == "/tmp/mysql.sock" && mysql.host.isEmpty && mysql.port == nil)
        #expect(mysql.location == "socket /tmp/mysql.sock, database reports")
        #expect(mysql.summary == "mysql, socket /tmp/mysql.sock, database reports")
        let pgsql = Self.connection(.pgsql) {
            $0.socket = "/var/run/postgresql"
            $0.port = 5433
        }.normalized
        #expect(pgsql.host.isEmpty && pgsql.port == 5433)

        // TLS files go with TLS off; empty paths are nil.
        let off = Self.connection(.pgsql) { $0.tls = DatabaseTLS(mode: .disable, caFile: "/ca.pem") }.normalized
        #expect(off.tls == DatabaseTLS(mode: .disable))
        let blank = Self.connection(.mysql) { $0.tls = DatabaseTLS(mode: .require, caFile: "  ") }.normalized
        #expect(blank.tls == DatabaseTLS(mode: .require))
        // SQL Server has TLS modes but no files; SQLite and custom DSNs have no TLS setting.
        #expect(Self.connection(.sqlsrv) { $0.tls = DatabaseTLS(mode: .require, caFile: "/ca.pem") }.normalized.tls == DatabaseTLS(mode: .require))
        #expect(Self.connection(.sqlite) { $0.tls = DatabaseTLS(mode: .require) }.normalized.tls == nil)

        // Init statements lose their semicolons and blanks; options go where the driver has none.
        let trimmed = Self.connection(.pgsql) {
            $0.initStatements = ["  SET search_path TO reports ;; ", "", "   "]
            $0.options = [DatabaseOption(key: " application_name ", value: " Runlet "), DatabaseOption(key: "", value: "")]
        }.normalized
        #expect(trimmed.initStatements == ["SET search_path TO reports"])
        #expect(trimmed.options == [DatabaseOption(key: "application_name", value: "Runlet")])
        #expect(Self.connection(.mysql) { $0.options = [DatabaseOption(key: "a", value: "b")] }.normalized.options.isEmpty)

        // Only a custom connection keeps a DSN, and it keeps no host or database.
        #expect(Self.connection(.pgsql) { $0.dsn = "pgsql:host=x" }.normalized.dsn == nil)
        let custom = Self.connection(.custom) { $0.host = "x"; $0.database = "y" }.normalized
        #expect(custom.host.isEmpty && custom.database.isEmpty && custom.dsn == "oci:dbname=//db.internal:1521/XE")
        #expect(custom.summary == "custom, oci:dbname=//db.internal:1521/XE")
        #expect(custom.customDSNDriver == "oci")
        #expect(Self.connection(.sqlsrv).normalized.summary == "sqlsrv, db.internal:1433/reports")
    }

    // MARK: Validation

    @Test func socketAndCharset() {
        #expect(errors(Self.connection(.mysql) { $0.socket = "/tmp/mysql.sock"; $0.host = "" }).isEmpty)
        #expect(errors(Self.connection(.mysql) { $0.host = "" }) == [.emptyHost])
        for bad in ["relative.sock", "/tmp/a;b", "/tmp/'q'", "/tmp/a\\b", "/tmp/a\nb"] {
            #expect(errors(Self.connection(.pgsql) { $0.socket = bad }) == [.invalidSocket], "\(bad)")
        }
        #expect(errors(Self.connection(.mysql) { $0.charset = "latin1" }).isEmpty)
        #expect(errors(Self.connection(.pgsql) { $0.charset = "WIN1252" }).isEmpty)
        #expect(errors(Self.connection(.mysql) { $0.charset = "utf8mb4;port=1" }) == [.invalidCharset])
        #expect(errors(Self.connection(.pgsql) { $0.charset = "UTF8' options='-c x" }) == [.invalidCharset])
    }

    @Test func tlsModesEachDriverCanExpress() {
        for mode in DatabaseTLSMode.allCases {
            #expect(errors(Self.connection(.pgsql) { $0.tls = DatabaseTLS(mode: mode) }).isEmpty, "pgsql \(mode)")
        }
        for (driver, modes) in [(DatabaseDriverKind.mysql, [DatabaseTLSMode.prefer, .verifyCA]), (.sqlsrv, [.prefer, .verifyCA])] {
            for mode in modes {
                let found = errors(Self.connection(driver) { $0.tls = DatabaseTLS(mode: mode) })
                #expect(found == [.unsupportedTLSMode(driver, mode)], "\(driver) \(mode)")
                #expect(found.first?.description.contains("can't express") == true)
            }
            for mode in [DatabaseTLSMode.disable, .require, .verifyFull] {
                #expect(errors(Self.connection(driver) { $0.tls = DatabaseTLS(mode: mode) }).isEmpty, "\(driver) \(mode)")
            }
        }
        #expect(errors(Self.connection(.mysql) { $0.tls = DatabaseTLS(mode: .verifyFull, caFile: "ca.pem") }) == [.invalidTLSFile("CA file")])
        #expect(errors(Self.connection(.pgsql) { $0.tls = DatabaseTLS(mode: .require, certificateFile: "/c.pem") }) == [.certificateWithoutKey])
        #expect(errors(Self.connection(.pgsql) { $0.tls = DatabaseTLS(mode: .require, certificateFile: "/c.pem", keyFile: "/k;ey") }) == [.invalidTLSFile("client key")])
        #expect(errors(Self.connection(.pgsql) { $0.tls = DatabaseTLS(mode: .verifyFull, caFile: "/Users/me/Application Support/ca.pem", certificateFile: "/c.pem", keyFile: "/k.pem") }).isEmpty, "spaces are fine")
    }

    @Test func extraOptionsNeverCarryAPassword() {
        #expect(errors(Self.connection(.pgsql) { $0.options = [DatabaseOption(key: "application_name", value: "Runlet tab"), DatabaseOption(key: "hostaddr", value: "10.0.0.5")] }).isEmpty)
        #expect(errors(Self.connection(.sqlsrv) { $0.options = [DatabaseOption(key: "APP", value: "Runlet"), DatabaseOption(key: "ApplicationIntent", value: "ReadOnly")] }).isEmpty)
        for key in ["password", "PWD", "sslpassword", "passfile", "Passphrase"] {
            let found = errors(Self.connection(.pgsql) { $0.options = [DatabaseOption(key: key, value: "secret")] })
            #expect(found == [.passwordOption(key)], "\(key)")
            #expect(found.first?.description.contains("Password field") == true)
        }
        #expect(errors(Self.connection(.pgsql) { $0.options = [DatabaseOption(key: "sslmode", value: "disable")] }) == [.managedOption("sslmode")])
        #expect(errors(Self.connection(.sqlsrv) { $0.options = [DatabaseOption(key: "Encrypt", value: "no")] }) == [.managedOption("Encrypt")])
        #expect(errors(Self.connection(.pgsql) { $0.options = [DatabaseOption(key: "a b", value: "x")] }) == [.invalidOptionKey("a b")])
        #expect(errors(Self.connection(.pgsql) { $0.options = [DatabaseOption(key: "options", value: "-c a=1;password=x")] }) == [.invalidOptionValue("options")])
        #expect(errors(Self.connection(.sqlsrv) { $0.options = [DatabaseOption(key: "APP", value: "{x}")] }) == [.invalidOptionValue("APP")])
        #expect(errors(Self.connection(.pgsql) { $0.options = Array(repeating: DatabaseOption(key: "application_name", value: "x"), count: 31) }).contains(.tooManyOptions))
    }

    @Test func customDSNs() {
        #expect(errors(Self.connection(.custom)).isEmpty)
        #expect(errors(Self.connection(.custom) { $0.dsn = "odbc:Driver={ODBC Driver 18 for SQL Server};Server=sql;Database=erp" }).isEmpty)
        #expect(errors(Self.connection(.custom) { $0.dsn = nil }) == [.emptyDSN])
        #expect(errors(Self.connection(.custom) { $0.dsn = "  " }) == [.emptyDSN])
        for leaking in ["mysql:host=db;password=secret", "odbc:DSN=erp;PWD=secret", "pgsql:host=db sslpassword = x", "odbc:DSN=erp; Passwd=x", "pgsql:postgresql://reader:secret@db/reports"] {
            #expect(errors(Self.connection(.custom) { $0.dsn = leaking }) == [.passwordInDSN], "\(leaking)")
        }
        #expect(errors(Self.connection(.custom) { $0.dsn = "pgsql:postgresql://reader@db/reports" }).isEmpty, "a user without a password is fine")
        #expect(errors(Self.connection(.custom) { $0.dsn = "uri:file:///etc/dsn" }).first?.description.contains("uri:") == true)
        #expect(errors(Self.connection(.custom) { $0.dsn = "no prefix" }).first?.description.contains("PDO driver name") == true)
        #expect(errors(Self.connection(.custom) { $0.dsn = "oci:a\nb" }).count == 1)
    }

    @Test func readOnlyNeedsADriverThatEnforcesIt() {
        for driver in [DatabaseDriverKind.sqlsrv, .custom] {
            #expect(errors(Self.connection(driver) { $0.readOnly = true }) == [.readOnlyUnsupported(driver)], "\(driver)")
            #expect(!driver.supportsReadOnly)
        }
        for driver in [DatabaseDriverKind.mysql, .pgsql, .sqlite] {
            #expect(errors(Self.connection(driver) { $0.readOnly = true }).isEmpty, "\(driver)")
        }
    }

    // MARK: Init statements

    @Test func initStatementsOnAnyConnection() {
        #expect(errors(Self.connection(.pgsql) { $0.initStatements = ["SET search_path TO reports", "CREATE TEMP TABLE scratch (id int)"] }).isEmpty)
        for (statement, phrase) in [("BEGIN", "BEGIN"), ("start transaction", "START TRANSACTION"), ("COMMIT", "COMMIT"), ("SELECT 1; SELECT 2", "several statements"), ("-- nothing", "no statement")] {
            let found = errors(Self.connection(.mysql) { $0.initStatements = [statement] })
            #expect(found.count == 1 && found.first?.description.contains(phrase) == true, "\(statement): \(found)")
        }
        let many = Self.connection(.pgsql) { $0.initStatements = Array(repeating: "SET a = 1", count: 21) }
        #expect(errors(many).contains(.tooManyInitStatements))
        #expect(errors(Self.connection(.pgsql) { $0.initStatements = [String(repeating: "x", count: 4001)] }) == [.longInitStatement(1)])
    }

    @Test func initStatementsOnAReadOnlyConnectionKeepItReadOnly() {
        let allowed: [(String, DatabaseDriverKind)] = [
            ("SET search_path TO reports, public", .pgsql), ("SET TIME ZONE 'UTC'", .pgsql), ("SET statement_timeout = '5s'", .pgsql),
            ("SET ROLE reporting", .pgsql), ("SET time_zone = '+00:00'", .mysql), ("SET NAMES utf8mb4", .mysql),
            ("SET SESSION sql_mode = 'ANSI'", .mysql), ("SET @@session.time_zone = '+00:00'", .mysql), ("SELECT 1", .pgsql),
            ("PRAGMA foreign_keys", .sqlite), ("SET TRANSACTION ISOLATION LEVEL READ COMMITTED", .mysql),
        ]
        for (statement, driver) in allowed {
            #expect(SQLScript.initStatementRefusal(of: statement, driver: driver, readOnly: true) == nil, "\(statement)")
            #expect(errors(Self.connection(driver) { $0.readOnly = true; $0.initStatements = [statement] }).isEmpty, "\(statement)")
        }
        let refused: [(String, DatabaseDriverKind, String)] = [
            ("SET default_transaction_read_only = off", .pgsql, "writable again"),
            ("SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE", .pgsql, "writable again"),
            ("SET SESSION TRANSACTION READ WRITE", .mysql, "writable again"),
            ("SET @@session.transaction_read_only = 0", .mysql, "writable again"),
            ("SET GLOBAL max_connections = 10", .mysql, "server-wide"),
            ("SET @@global.time_zone = '+00:00'", .mysql, "server-wide"),
            ("SET PERSIST sql_mode = ''", .mysql, "server-wide"),
            ("SET PASSWORD = 'x'", .mysql, "account"),
            ("SET DEFAULT ROLE ALL TO reader", .mysql, "account"),
            ("RESET ALL", .pgsql, "writable again"),
            ("PRAGMA query_only = 0", .sqlite, "writable again"),
            ("INSERT INTO audit VALUES (1)", .pgsql, "can change data"),
            ("CREATE TEMP TABLE scratch (id int)", .pgsql, "can change data"),
            ("SELECT set_config('search_path', 'x', false)", .pgsql, "writable again"),
            ("USE other", .mysql, "can't tell"),
            ("SET search_path TO x # ; DELETE FROM t", .pgsql, "several statements"),
        ]
        for (statement, driver, phrase) in refused {
            let why = SQLScript.initStatementRefusal(of: statement, driver: driver, readOnly: true)
            #expect(why?.contains(phrase) == true, "\(statement): \(why ?? "nil")")
            #expect(SQLScript.initStatementRefusal(of: statement, driver: driver, readOnly: false) == nil || statement.contains("#"), "\(statement) is fine on a read-write connection")
        }
        let found = errors(Self.connection(.pgsql) { $0.readOnly = true; $0.initStatements = ["SET search_path TO reports", "SET default_transaction_read_only = off"] })
        #expect(found.count == 1)
        #expect(found.first?.description.hasPrefix("Init statement 2 would make the read-only session writable again") == true, "\(found)")
    }

    // MARK: Test Connection

    @Test func testReportsSayWhetherTLSIsInUse() {
        let encrypted = SQLConnectionTestInfo(driver: "pgsql", serverVersion: "14.23", database: "shop", user: "postgres", roundTripMs: 1.25, tls: true, tlsVersion: "TLSv1.3", tlsCipher: "TLS_AES_256_GCM_SHA384", initStatements: 2)
        #expect(encrypted.summary == "Connected: PostgreSQL 14.23 · database shop · user postgres · 1.2 ms round trip · TLSv1.3")
        #expect(encrypted.tlsDetail == "TLSv1.3, TLS_AES_256_GCM_SHA384")
        let plain = SQLConnectionTestInfo(driver: "mysql", serverVersion: "11.8.3-MariaDB", tls: false)
        #expect(plain.summary == "Connected: MariaDB 11.8.3 · not encrypted")
        #expect(plain.tlsDetail == nil)
        #expect(SQLConnectionTestInfo(driver: "sqlsrv", serverVersion: "16.00.4135", pdoDriver: "dblib").summary == "Connected: SQL Server 16.00.4135 (pdo_dblib)")
        let decoded = try? JSONDecoder().decode(SQLConnectionTestInfo.self, from: Data(#"{"driver":"pgsql","tls":true,"tlsVersion":"TLSv1.3","initStatements":1}"#.utf8))
        #expect(decoded?.tls == true && decoded?.initStatements == 1)
    }
}
