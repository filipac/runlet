import Foundation
@testable import RunletCore
import Testing
@testable import RunletExecution

/// WordPress's own PDO connection (#208) against live MariaDB 11 (the fixture container, through
/// `RUNLET_TEST_MYSQL`): a scratch copy of the WordPress fixture without the SQLite drop-in,
/// installed with `wp_install()` into its own `p208_wp` database as the `p208_wp` user (no mail
/// is sent). Every feature #208 unlocks runs through "WordPress (PDO from wp-config)", plus the
/// server panel and Stop's cancel on the server; the session matches `$wpdb`'s (charset,
/// collation, sql_mode); DB_HOST as `host:port` and `[::1]:port` (through a forwarder on IPv6
/// loopback; the container listens on 127.0.0.1 only); TLS from MYSQL_CLIENT_FLAGS and
/// MYSQL_SSL_CA (`RUNLET_TEST_TLS`); the fallbacks to `$wpdb` (an unknown drop-in, a password
/// PDO can't use while `$wpdb` connects, RUNLET_WPDB_ONLY); and no event of any of these runs
/// carries a password. A socket DB_HOST has no fixture: `WordPressPDOTests` covers its DSN.
@Suite(.serialized, .enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct WordPressPDOLiveTests {
    typealias Server = SQLLiveDatabaseTests.Server
    static let database = "p208_wp"
    static let user = "p208_wp"
    static let password = "p208-Wp-Secret-7f3a"
    /// A DB_PASSWORD PDO is refused with while the drop-in's `$wpdb` uses the real one.
    static let wrongPassword = "p208-Wrong-Secret-9c1d"

    static var server: Server? { SQLLiveDatabaseTests.mysql }
    static var enabled: Bool { server != nil && WordPressPDOTests.fixtureReady }

    /// The server's host and port, from its DSN.
    static func address(_ server: Server) -> (host: String, port: Int) {
        var fields: [String: String] = [:]
        for part in server.dsn.drop(while: { $0 != ":" }).dropFirst().split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { fields[pair[0]] = pair[1] }
        }
        return (fields["host"] ?? "127.0.0.1", Int(fields["port"] ?? "") ?? 3306)
    }

    static func wpConfig(host: String, password: String = Self.password, extra: String = "") -> String {
        """
        <?php
        define( 'DB_NAME', '\(database)' );
        define( 'DB_USER', '\(user)' );
        define( 'DB_PASSWORD', '\(password)' );
        define( 'DB_HOST', '\(host)' );
        define( 'DB_CHARSET', 'utf8mb4' );
        define( 'DB_COLLATE', '' );
        define( 'AUTH_KEY', 'p208-auth' );
        define( 'SECURE_AUTH_KEY', 'p208-secure-auth' );
        define( 'LOGGED_IN_KEY', 'p208-logged-in' );
        define( 'NONCE_KEY', 'p208-nonce' );
        define( 'AUTH_SALT', 'p208-auth-salt' );
        define( 'SECURE_AUTH_SALT', 'p208-secure-auth-salt' );
        define( 'LOGGED_IN_SALT', 'p208-logged-in-salt' );
        define( 'NONCE_SALT', 'p208-nonce-salt' );
        $table_prefix = 'p208_';
        \(extra)
        if ( ! defined( 'ABSPATH' ) ) {
            define( 'ABSPATH', __DIR__ . '/' );
        }
        require_once ABSPATH . 'wp-settings.php';
        """
    }

    /// A clone of the WordPress fixture on MariaDB: the SQLite drop-in and its plugin removed,
    /// `wp-config.php` for `p208_wp` with `extra` lines, and `dropIn` as `wp-content/db.php`.
    static func wordpress(_ server: Server, host: String? = nil, password: String = Self.password, extra: String = "", dropIn: String? = nil) throws -> URL {
        try install(server)
        let (address, port) = Self.address(server)
        return try clone(config: wpConfig(host: host ?? "\(address):\(port)", password: password, extra: extra), dropIn: dropIn)
    }

    static func clone(config: String, dropIn: String?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-wp208-live-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.copyItem(at: TestSupport.fixtures.appendingPathComponent("wordpress"), to: directory)
        for path in ["wp-content/db.php", "wp-content/plugins/sqlite-database-integration", "wp-content/database", ".runlet-fixture-ready"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(path))
        }
        try config.write(to: directory.appendingPathComponent("wp-config.php"), atomically: true, encoding: .utf8)
        if let dropIn { try dropIn.write(to: directory.appendingPathComponent("wp-content/db.php"), atomically: true, encoding: .utf8) }
        return directory
    }

    /// `p208_wp` with WordPress installed in it (once per database; `wp_install()` with mail
    /// stopped by `pre_wp_mail` and sendmail_path), and a fresh `p208_items` of 1,200 rows.
    static func install(_ server: Server) throws {
        _ = try server.exec("CREATE DATABASE IF NOT EXISTS \(database) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci")
        _ = try server.exec("CREATE USER IF NOT EXISTS \(user)@'%' IDENTIFIED BY '\(password)'")
        _ = try server.exec("ALTER USER \(user)@'%' IDENTIFIED BY '\(password)'")
        _ = try server.exec("GRANT ALL ON \(database).* TO \(user)@'%'")
        let installed = (try? server.exec("SELECT COUNT(*) FROM \(database).p208_options WHERE option_name = 'siteurl'")) == "1"
        if !installed {
            let (address, port) = Self.address(server)
            let directory = try clone(config: wpConfig(host: "\(address):\(port)"), dropIn: nil)
            defer { try? FileManager.default.removeItem(at: directory) }
            let script = directory.appendingPathComponent("p208-install.php")
            try """
                <?php
                define('WP_INSTALLING', true);
                $_SERVER['HTTP_HOST'] = 'localhost';
                $_SERVER['REQUEST_URI'] = '/';
                require $argv[1] . '/wp-load.php';
                require_once ABSPATH . 'wp-admin/includes/upgrade.php';
                add_filter('pre_wp_mail', '__return_false');
                $result = wp_install('Runlet PDO Fixture', 'runlet', 'runlet@example.test', false, '', wp_generate_password(20));
                wp_insert_post(['post_title' => 'Hello from Runlet', 'post_content' => 'Fixture post.', 'post_status' => 'publish']);
                echo is_array($result) ? 'installed' : 'failed';
                """.write(to: script, atomically: true, encoding: .utf8)
            let result = try TestProcess.runBlocking([DriverSupport.php, "-d", "sendmail_path=/usr/bin/true", script.path, directory.path], step: "installing the p208 WordPress", within: .seconds(120))
            #expect(result.output.hasSuffix("installed"), "\(result.output) \(result.errors)")
        }
        _ = try server.exec("DROP TABLE IF EXISTS \(database).p208_items")
        _ = try server.exec("CREATE TABLE \(database).p208_items (id INT PRIMARY KEY, name VARCHAR(40) NOT NULL, price DECIMAL(8,2), note VARCHAR(40)) ENGINE=InnoDB")
        _ = try server.exec("INSERT INTO \(database).p208_items SELECT seq, CONCAT('Item ', LPAD(seq, 4, '0')), seq / 4, IF(seq % 10 = 0, NULL, CONCAT('note ', seq)) FROM seq_1_to_1200")
    }

    /// The runner's whole output (every event of the run) for `code` on `directory`.
    static func rawOutput(_ code: String, in directory: URL) throws -> String {
        let nonce = RunnerBundle.makeNonce()
        let script = TestSupport.bundle.script(code: code, nonce: nonce, runId: UUID(), limits: RunLimits())
        let scriptFile = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-wp208-\(UUID().uuidString).php")
        let errorFile = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-wp208-\(UUID().uuidString).err")
        try script.write(to: scriptFile)
        FileManager.default.createFile(atPath: errorFile.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: scriptFile)
            try? FileManager.default.removeItem(at: errorFile)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: DriverSupport.php)
        process.arguments = RunnerBundle.phpArguments
        process.currentDirectoryURL = directory
        process.standardInput = try FileHandle(forReadingFrom: scriptFile)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = try FileHandle(forWritingTo: errorFile)
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self) + (try String(contentsOf: errorFile, encoding: .utf8))
    }

    func run(_ code: String, in directory: URL) async throws -> [RunEvent] {
        try await TestSupport.run(code, target: DriverSupport.target(directory.path), magicComments: false)
    }

    // MARK: Features

    @Test(.enabled(if: WordPressPDOLiveTests.enabled, "set RUNLET_TEST_MYSQL and generate the WordPress fixture"))
    func everyFeatureWorksOnMariaDBWithTheServerPanelAndStop() async throws {
        let server = try #require(Self.server)
        let directory = try Self.wordpress(server)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await WordPressPDOFeatures(directory: directory, dialect: .mysql, label: "MariaDB").checkAll()

        // The session is $wpdb's: charset, collation, and sql_mode.
        let session = "SELECT @@character_set_client AS charset, @@collation_connection AS collation, @@SESSION.sql_mode AS mode"
        let pdo = try await run(SQLTabRun.code(statement: session, connection: nil), in: directory)
        let wpdb = try await run(SQLTabRun.code(statement: session, connection: "wpdb"), in: directory)
        #expect(pdo.sqlResult?.source == "WordPress (PDO from wp-config)" && wpdb.sqlResult?.source == "WordPress $wpdb")
        #expect(pdo.sqlResult?.rows == wpdb.sqlResult?.rows, "PDO \(pdo.sqlResult?.rows ?? []) vs $wpdb \(wpdb.sqlResult?.rows ?? [])")
        #expect(pdo.logEntries.contains { $0.source == "sql" && $0.message.hasPrefix("WordPress: PDO connection from wp-config.php (mysql, 127.0.0.1:") && $0.message.hasSuffix("/p208_wp)") }, "\(pdo.logEntries.map(\.message))")

        // The Database pane's Server section.
        let info = try await ExecutionEngine(bundle: TestSupport.bundle, docker: nil).loadSQLServerInfo(target: DriverSupport.target(directory.path), connection: nil)
        #expect(info.driver == "mysql" && info.source == "WordPress (PDO from wp-config)", "\(info)")
        #expect(info.overview?.database == Self.database, "\(String(describing: info.overview))")
        #expect(info.overview?.user?.hasPrefix(Self.user + "@") == true, "\(String(describing: info.overview))")
        #expect(info.sessions?.list.contains { $0.id == info.sessionId } == true, "the panel's own session is listed")
        #expect(info.errors == nil, "\(info.errors ?? [:])")

        // Stop cancels the statement on the server.
        let marker = SQLCancelLiveTests.marker()
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
        let stopped = try await SQLCancelExecutionTests.runAndStop(SQLCancelExecutionTests.request(SQLTabRun.code(statement: "SELECT SLEEP(30) AS \(marker)", connection: nil), in: directory), engine: engine)
        try await SQLCancelLiveTests().expectCancelled(stopped, server, marker: marker, "WordPress on MariaDB")
        #expect(stopped.events.sqlCancel?.statement == "KILL QUERY \(stopped.session?.id ?? 0)")
    }

    @Test(.enabled(if: WordPressPDOLiveTests.enabled, "set RUNLET_TEST_MYSQL and generate the WordPress fixture"))
    func ipv6DBHostConnectsThroughTheBrackets() async throws {
        let server = try #require(Self.server)
        let forwarder = try IPv6Forwarder(to: Self.address(server).port)
        defer { forwarder.stop() }
        guard let port = forwarder.port else {
            Issue.record("this Mac has no IPv6 loopback to listen on")
            return
        }
        let directory = try Self.wordpress(server, host: "[::1]:\(port)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = try await run(SQLTabRun.code(statement: "SELECT option_value FROM p208_options WHERE option_name = 'blogname'", connection: nil), in: directory)
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.sqlResult?.rows == [[.string("Runlet PDO Fixture")]])
        #expect(events.sqlResult?.source == "WordPress (PDO from wp-config)")
        #expect(events.logEntries.contains { $0.message == "WordPress: PDO connection from wp-config.php (mysql, [::1]:\(port)/p208_wp)" }, "\(events.logEntries.map(\.message))")
    }

    // MARK: TLS

    static var tls: URL? {
        ProcessInfo.processInfo.environment["RUNLET_TEST_TLS"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    }

    @Test(.enabled(if: WordPressPDOLiveTests.enabled && WordPressPDOLiveTests.tls != nil, "set RUNLET_TEST_MYSQL and RUNLET_TEST_TLS"))
    func tlsFromWpConfigIsCheckedAndAWrongCAFallsBack() async throws {
        let server = try #require(Self.server)
        let tls = try #require(Self.tls)
        let cipher = "SHOW SESSION STATUS LIKE 'Ssl_cipher'"
        // MYSQLI_CLIENT_SSL, as wpdb passes it to mysqli: encrypted.
        let flags = try Self.wordpress(server, extra: "define( 'MYSQL_CLIENT_FLAGS', MYSQLI_CLIENT_SSL );")
        defer { try? FileManager.default.removeItem(at: flags) }
        let encrypted = try await run(SQLTabRun.code(statement: cipher, connection: nil), in: flags)
        #expect(encrypted.sqlResult?.source == "WordPress (PDO from wp-config)", "\(encrypted.errors)")
        #expect(encrypted.sqlResult?.rows.first?[1].text.isEmpty == false, "\(encrypted.sqlResult?.rows ?? [])")
        #expect(encrypted.logEntries.contains { $0.message.hasPrefix("WordPress: PDO connection from wp-config.php (") && $0.message.hasSuffix(", TLS)") && $0.detail?.hasPrefix("TLS: ") == true })
        // With the fixture's CA, the server's certificate is verified.
        let verified = try Self.wordpress(server, extra: "define( 'MYSQL_CLIENT_FLAGS', MYSQLI_CLIENT_SSL ); define( 'MYSQL_SSL_CA', '\(tls.appendingPathComponent("ca.crt").path)' );")
        defer { try? FileManager.default.removeItem(at: verified) }
        let checked = try await run(SQLTabRun.code(statement: cipher, connection: nil), in: verified)
        #expect(checked.sqlResult?.source == "WordPress (PDO from wp-config)", "\(checked.errors)")
        #expect(checked.sqlResult?.rows.first?[1].text.isEmpty == false)
        // A CA that signed nothing: PDO can't verify, while $wpdb (which ignores MYSQL_SSL_CA) works.
        let wrong = try Self.wordpress(server, extra: "define( 'MYSQL_CLIENT_FLAGS', MYSQLI_CLIENT_SSL ); define( 'MYSQL_SSL_CA', '\(tls.appendingPathComponent("other-ca.crt").path)' );")
        defer { try? FileManager.default.removeItem(at: wrong) }
        let fallback = try await run(SQLTabRun.code(statement: "SELECT option_value FROM p208_options WHERE option_name = 'blogname'", connection: nil), in: wrong)
        #expect(fallback.errors.isEmpty, "\(fallback.errors)")
        #expect(fallback.sqlResult?.source?.hasPrefix("WordPress ($wpdb, because PDO couldn't connect: SQLSTATE[HY000] [2002]") == true, "\(fallback.sqlResult?.source ?? "")")
        #expect(fallback.sqlResult?.rows == [[.string("Runlet PDO Fixture")]])
    }

    // MARK: Falling back

    @Test(.enabled(if: WordPressPDOLiveTests.enabled, "set RUNLET_TEST_MYSQL and generate the WordPress fixture"))
    func unknownDropInsFailedConnectionsAndTheOptOutKeepWpdb() async throws {
        let server = try #require(Self.server)
        // A drop-in Runlet doesn't know: $wpdb, with what a callable can't do refused.
        let custom = try Self.wordpress(server, dropIn: "<?php\nclass Acme_Routing_DB extends wpdb {}\n$wpdb = new Acme_Routing_DB( DB_USER, DB_PASSWORD, DB_NAME, DB_HOST );\n")
        defer { try? FileManager.default.removeItem(at: custom) }
        let origin = "WordPress ($wpdb, because the db.php drop-in replaces wpdb with Acme_Routing_DB, which Runlet doesn't open itself)"
        let select = try await run(SQLTabRun.code(statement: "SELECT name FROM p208_items WHERE id = 3", connection: nil), in: custom)
        #expect(select.errors.isEmpty, "\(select.errors)")
        #expect(select.sqlResult?.source == origin)
        #expect(select.sqlResult?.rows == [[.string("Item 0003")]])
        let bound = try await run(SQLTabRun.code(statement: "SELECT name FROM p208_items WHERE id = :id", connection: nil, bindings: [SQLBinding(target: .name("id"), value: .integer(3))]), in: custom)
        #expect(bound.errors.first?.className == "RunletRunner\\SqlParametersRefused", "\(bound.errors)")
        let server2 = try? await ExecutionEngine(bundle: TestSupport.bundle, docker: nil).loadSQLServerInfo(target: DriverSupport.target(custom.path), connection: nil)
        #expect(server2?.overview == nil, "the server panel needs a PDO")

        // DB_PASSWORD that PDO is refused with while the drop-in connects $wpdb with another one.
        let refused = try Self.wordpress(server, password: Self.wrongPassword, dropIn: "<?php\n$wpdb = new wpdb( DB_USER, '\(Self.password)', DB_NAME, DB_HOST );\n")
        defer { try? FileManager.default.removeItem(at: refused) }
        let failed = try await run(SQLTabRun.code(statement: "SELECT name FROM p208_items WHERE id = 3", connection: nil), in: refused)
        #expect(failed.errors.isEmpty, "\(failed.errors)")
        #expect(failed.sqlResult?.source?.hasPrefix("WordPress ($wpdb, because PDO couldn't connect: SQLSTATE[HY000] [1045] Access denied for user 'p208_wp'@") == true, "\(failed.sqlResult?.source ?? "")")
        #expect(failed.sqlResult?.rows == [[.string("Item 0003")]])
        #expect(failed.logEntries.contains { $0.source == "sql" && $0.message.hasPrefix("WordPress: statements run through $wpdb, because PDO couldn't connect") })

        // RUNLET_WPDB_ONLY.
        let optOut = try Self.wordpress(server, extra: "define( 'RUNLET_WPDB_ONLY', true );")
        defer { try? FileManager.default.removeItem(at: optOut) }
        let kept = try await run(SQLTabRun.code(statement: "SELECT name FROM p208_items WHERE id = 3", connection: nil), in: optOut)
        #expect(kept.sqlResult?.source == "WordPress ($wpdb, because RUNLET_WPDB_ONLY is set)", "\(kept.errors)")
    }

    // MARK: The password

    @Test(.enabled(if: WordPressPDOLiveTests.enabled, "set RUNLET_TEST_MYSQL and generate the WordPress fixture"))
    func noEventCarriesThePassword() async throws {
        let server = try #require(Self.server)
        let plain = try Self.wordpress(server)
        let refused = try Self.wordpress(server, password: Self.wrongPassword, dropIn: "<?php\n$wpdb = new wpdb( DB_USER, '\(Self.password)', DB_NAME, DB_HOST );\n")
        let badTLS = try Self.wordpress(server, extra: "define( 'MYSQL_CLIENT_FLAGS', MYSQLI_CLIENT_SSL | MYSQLI_CLIENT_SSL_VERIFY_SERVER_CERT );")
        defer { for directory in [plain, refused, badTLS] { try? FileManager.default.removeItem(at: directory) } }
        let codes = [
            SQLTabRun.code(statement: "SELECT option_name, option_value FROM p208_options ORDER BY option_id", connection: nil, schema: true),
            SQLTabRun.code(statement: "SELECT nope FROM p208_missing", connection: nil),
            SQLTabRun.code(statement: "SELECT name FROM p208_items WHERE id = :id", connection: nil, bindings: [SQLBinding(target: .name("id"), value: .integer(3))]),
            SQLExplain.code(statement: "SELECT * FROM p208_items WHERE id = 4", connection: nil, mode: .plan),
            SQLServerPanel.code(parts: SQLServerInfo.Part.allCases, connection: nil),
            SQLTabRun.schemaCode(connection: nil),
            "<?php throw new RuntimeException('a snippet error');",
        ]
        var runs = 0
        for directory in [plain, refused, badTLS] {
            for code in codes {
                let output = try Self.rawOutput(code, in: directory)
                runs += 1
                #expect(output.contains("\"type\":\"runnerFinished\""), "\(directory.lastPathComponent): \(output.suffix(400))")
                for secret in [Self.password, Self.wrongPassword] {
                    for form in [secret, secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? secret] {
                        #expect(!output.contains(form), "\(directory.lastPathComponent): the password is in the output of \(code.prefix(80))")
                    }
                }
            }
        }
        #expect(runs == 21)

        // A message that would carry DB_PASSWORD shows ••• instead: here the password is also a
        // table's name, which the database's error repeats (PDO is refused with it, so $wpdb runs).
        let named = try Self.wordpress(server, password: "p208_secret_table", dropIn: "<?php\n$wpdb = new wpdb( DB_USER, '\(Self.password)', DB_NAME, DB_HOST );\n")
        defer { try? FileManager.default.removeItem(at: named) }
        let output = try Self.rawOutput(SQLTabRun.code(statement: "SELECT * FROM p208_secret_table", connection: nil), in: named)
        #expect(!output.contains("p208_secret_table"), "\(output.suffix(600))")
        #expect(output.contains("p208_wp.•••"), "the error names the table as •••: \(output.suffix(600))")
    }
}

/// A TCP forwarder on IPv6 loopback (`[::1]`, a free port) to 127.0.0.1:`target`, in host PHP:
/// the fixture container publishes MariaDB on 127.0.0.1 only.
final class IPv6Forwarder: @unchecked Sendable {
    let process = Process()
    let port: Int?

    init(to target: Int) throws {
        process.executableURL = URL(fileURLWithPath: DriverSupport.php)
        process.arguments = ["-r", """
            $server = @stream_socket_server('tcp://[::1]:0', $errno, $errstr);
            if ($server === false) { echo "none\\n"; exit; }
            $name = (string) stream_socket_get_name($server, false);
            echo substr($name, strrpos($name, ':') + 1), "\\n";
            $pairs = [];
            while (true) {
                $read = [$server];
                foreach ($pairs as [$a, $b]) { $read[] = $a; $read[] = $b; }
                $write = $except = null;
                if (@stream_select($read, $write, $except, 1) === false) { break; }
                foreach ($read as $stream) {
                    if ($stream === $server) {
                        $client = @stream_socket_accept($server, 1);
                        $upstream = $client === false ? false : @stream_socket_client('tcp://127.0.0.1:' . $argv[1], $errno, $errstr, 5);
                        if ($client !== false && $upstream !== false) { $pairs[] = [$client, $upstream]; }
                        continue;
                    }
                    foreach ($pairs as $index => [$a, $b]) {
                        if ($stream !== $a && $stream !== $b) { continue; }
                        $data = @fread($stream, 65536);
                        if ($data === '' || $data === false) {
                            if (feof($stream)) { @fclose($a); @fclose($b); unset($pairs[$index]); }
                            continue;
                        }
                        @fwrite($stream === $a ? $b : $a, $data);
                    }
                }
            }
            """, String(target)]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        var line = Data()
        while true {
            let byte = output.fileHandleForReading.readData(ofLength: 1)
            if byte.isEmpty || byte == Data("\n".utf8) { break }
            line.append(byte)
        }
        port = Int(String(decoding: line, as: UTF8.self))
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }
}
