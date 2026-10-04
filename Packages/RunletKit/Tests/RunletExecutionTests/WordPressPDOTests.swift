import Foundation
@testable import RunletCore
import Testing
@testable import RunletExecution

/// WordPress's own PDO connection (#208) through the runner, with host PHP: DB_HOST read as
/// `wpdb::parse_db_host()` reads it (compared with WordPress's own on the fixture), the DSN and
/// TLS attributes for every form, each fallback to `$wpdb` with its reason (a missing PDO driver,
/// unknown drop-ins, RUNLET_WPDB_ONLY, `$wpdb` on other settings), PHP 7.4; and on the WordPress
/// fixture (the SQLite Database Integration drop-in) the features a callable couldn't offer:
/// bound values, Browse Table with filters and edits, Import CSV, Explain, Load Next paging, Run
/// All transactions, and Show Definition. `$wpdb` stays available as the `wpdb` connection.
/// Live MariaDB is in `WordPressPDOLiveTests`.
@Suite(.serialized, .enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct WordPressPDOTests {
    static var fixtureReady: Bool {
        FileManager.default.fileExists(atPath: TestSupport.fixtures.appendingPathComponent("wordpress/.runlet-fixture-ready").path)
    }

    /// Runs `code` (after `<?php`) on the plain project and decodes what it printed as JSON.
    func json(_ code: String, php: String? = nil) async throws -> Any? {
        let events = try await TestSupport.run("<?php " + code, target: DriverSupport.target(DriverSupport.fixture("plain"), php: php), magicComments: false)
        #expect(events.errors.isEmpty, "\(events.errors)")
        return try? JSONSerialization.jsonObject(with: Data(events.stdout.utf8), options: [.fragmentsAllowed])
    }

    /// What `WordPressDatabase::environment()` reads from a plain WordPress on MySQL.
    static var environment: [String: Any] { [
        "class": "wpdb", "dropIn": NSNull(), "multisite": false, "wpdbOnly": false, "engine": NSNull(), "sqliteFile": NSNull(),
        "name": "shop_wp", "user": "wp", "host": "localhost", "charset": "utf8mb4", "collate": "utf8mb4_unicode_520_ci",
        "flags": 0, "tls": [String: String](), "wpdb": [String: String](), "defaultSocket": "", "defaultPort": 3306,
    ] }

    /// `WordPressDatabase::plan()` for the environment with `changes`.
    func plan(_ changes: [String: Any] = [:], available: [String] = ["mysql", "sqlite"], php: String? = nil) async throws -> [String: Any] {
        let environment = Self.environment.merging(changes) { $1 }
        let data = try JSONSerialization.data(withJSONObject: environment)
        let list = available.map { "'\($0)'" }.joined(separator: ", ")
        let code = "echo json_encode(\\RunletRunner\\WordPressDatabase::plan(json_decode(\(QueryExplain.phpString(String(decoding: data, as: UTF8.self))), true), [\(list)]));"
        return try #require(try await json(code, php: php) as? [String: Any], "\(changes)")
    }

    /// A plan's PDO attribute by its suffix (`SSL_CA`: `PDO::MYSQL_ATTR_SSL_CA` or `Pdo\Mysql::ATTR_SSL_CA`).
    static func attribute(_ plan: [String: Any], _ suffix: String) -> Any? {
        let attributes = plan["attributes"] as? [String: [Any]] ?? [:]
        return attributes.first { $0.key.hasSuffix("ATTR_" + suffix) }.map { $0.value.count == 2 ? $0.value[1] : NSNull() }
    }

    // MARK: DB_HOST

    @Test func dbHostIsReadAsWordPressReadsIt() async throws {
        let hosts = ["localhost", "db.internal", "db.internal:3307", "127.0.0.1:3306", "localhost:/tmp/mysql.sock", ":/var/run/mysqld/mysqld.sock",
                     "db.internal:/tmp/x.sock", "[::1]", "[::1]:3307", "::1", "fe80::1:3306", "", "db.internal:abc"]
        let list = hosts.map(QueryExplain.phpString).joined(separator: ", ")
        // WordPress's own parse_db_host(), from the fixture's class-wpdb.php, when it is there.
        let wpdb = TestSupport.fixtures.appendingPathComponent("wordpress/wp-includes/class-wpdb.php").path
        let code = """
            $theirs = null;
            if (is_file(\(QueryExplain.phpString(wpdb)))) {
                if (!function_exists('absint')) { function absint($value) { return abs((int) $value); } }
                if (!defined('ABSPATH')) { define('ABSPATH', \(QueryExplain.phpString(TestSupport.fixtures.appendingPathComponent("wordpress").path + "/"))); }
                if (!defined('WPINC')) { define('WPINC', 'wp-includes'); }
                require_once \(QueryExplain.phpString(wpdb));
                $theirs = (new ReflectionClass('wpdb'))->newInstanceWithoutConstructor();
            }
            $out = [];
            foreach ([\(list)] as $host) {
                $ours = \\RunletRunner\\WordPressDatabase::parseHost($host);
                $out[] = ['host' => $host, 'ours' => $ours, 'same' => $theirs === null ? null : $theirs->parse_db_host($host) === ($ours ?? false)];
            }
            echo json_encode($out);
            """
        let rows = try #require(try await json(code) as? [[String: Any]])
        #expect(rows.count == hosts.count)
        if Self.fixtureReady {
            for row in rows { #expect(row["same"] as? Bool == true, "\(row)") }
        }
        let parsed = Dictionary(uniqueKeysWithValues: rows.map { ($0["host"] as? String ?? "", ($0["ours"] as? [Any])?.map { "\($0)" } ?? []) })
        #expect(parsed["db.internal:3307"] == ["db.internal", "3307", "<null>", "0"])
        #expect(parsed["localhost:/tmp/mysql.sock"] == ["localhost", "<null>", "/tmp/mysql.sock", "0"])
        #expect(parsed[":/var/run/mysqld/mysqld.sock"] == ["", "<null>", "/var/run/mysqld/mysqld.sock", "0"])
        #expect(parsed["[::1]:3307"] == ["::1", "3307", "<null>", "1"])
        #expect(parsed["[::1]"] == ["::1", "<null>", "<null>", "1"])
    }

    @Test func everyDBHostFormBecomesTheDSNMysqliWouldUse() async throws {
        let cases: [(host: String, socket: String, dsn: String)] = [
            ("localhost", "", "mysql:host=localhost;dbname=shop_wp;charset=utf8mb4"),
            // mysqli talks to localhost over its default socket; PDO gets the same one.
            ("localhost", "/tmp/mysql.sock", "mysql:host=localhost;unix_socket=/tmp/mysql.sock;dbname=shop_wp;charset=utf8mb4"),
            ("localhost:/var/run/mysqld/mysqld.sock", "/tmp/mysql.sock", "mysql:host=localhost;unix_socket=/var/run/mysqld/mysqld.sock;dbname=shop_wp;charset=utf8mb4"),
            (":/tmp/other.sock", "", "mysql:host=localhost;unix_socket=/tmp/other.sock;dbname=shop_wp;charset=utf8mb4"),
            ("db.internal", "", "mysql:host=db.internal;port=3306;dbname=shop_wp;charset=utf8mb4"),
            ("db.internal:3307", "", "mysql:host=db.internal;port=3307;dbname=shop_wp;charset=utf8mb4"),
            // mysqli ignores the socket of a host that isn't localhost.
            ("db.internal:/tmp/x.sock", "", "mysql:host=db.internal;port=3306;dbname=shop_wp;charset=utf8mb4"),
            ("127.0.0.1:33060", "", "mysql:host=127.0.0.1;port=33060;dbname=shop_wp;charset=utf8mb4"),
            ("[::1]", "", "mysql:host=[::1];port=3306;dbname=shop_wp;charset=utf8mb4"),
            ("[::1]:3307", "", "mysql:host=[::1];port=3307;dbname=shop_wp;charset=utf8mb4"),
            ("::1", "", "mysql:host=[::1];port=3306;dbname=shop_wp;charset=utf8mb4"),
        ]
        for item in cases {
            let plan = try await plan(["host": item.host, "defaultSocket": item.socket])
            #expect(plan["dsn"] as? String == item.dsn, "\(item.host): \(plan)")
            #expect(plan["driver"] as? String == "mysql" && plan["user"] as? String == "wp", "\(item.host)")
            #expect(plan["collate"] as? String == "utf8mb4_unicode_520_ci")
            #expect(plan["tls"] as? Bool == false)
            #expect(Self.attribute(plan, "TIMEOUT") as? Int == 10)
        }
        let summary = try await plan(["host": "db.internal:3307"])["summary"] as? String
        #expect(summary == "mysql, db.internal:3307/shop_wp")
        // Without DB_CHARSET, the server's default, as wpdb.
        #expect(try await plan(["charset": "", "collate": "", "host": "db.internal"])["dsn"] as? String == "mysql:host=db.internal;port=3306;dbname=shop_wp")
        // What a DSN can't hold falls back.
        #expect(try await plan(["host": "db;evil"])["fallback"] as? String == "DB_HOST \"db;evil\" isn't a host, port, or socket Runlet can read")
        #expect(try await plan(["name": "shop;evil"])["fallback"] as? String == "DB_NAME contains \";\" or control characters, which a PDO DSN can't hold")
        #expect((try await plan(["charset": "utf8mb4'"])["fallback"] as? String)?.hasPrefix("the charset") == true)
    }

    // MARK: TLS

    @Test func tlsFollowsMysqlClientFlagsAndTheSSLConstants() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-wp208-tls-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["ca.pem", "client.pem", "client.key"] { try Data("not a certificate".utf8).write(to: folder.appendingPathComponent(name)) }
        let ca = folder.appendingPathComponent("ca.pem").path
        let ssl = 2048, dontVerify = 64, verify = 1_073_741_824, compress = 32

        // MYSQLI_CLIENT_SSL alone: encrypted, unverified, as mysqli without a CA.
        let plain = try await plan(["flags": ssl, "host": "db.internal"])
        #expect(plain["tls"] as? Bool == true)
        #expect(Self.attribute(plain, "SSL_CA") as? String == "")
        #expect(Self.attribute(plain, "SSL_VERIFY_SERVER_CERT") as? Bool == false)
        #expect((plain["summary"] as? String)?.hasSuffix(", TLS") == true)
        // A CA verifies, unless the flags say not to.
        let withCA = try await plan(["flags": ssl, "tls": ["MYSQL_SSL_CA": ca]])
        #expect(Self.attribute(withCA, "SSL_CA") as? String == ca)
        #expect(Self.attribute(withCA, "SSL_VERIFY_SERVER_CERT") as? Bool == true)
        let unverified = try await plan(["flags": ssl | dontVerify, "tls": ["MYSQL_SSL_CA": ca]])
        #expect(Self.attribute(unverified, "SSL_VERIFY_SERVER_CERT") as? Bool == false)
        let verified = try await plan(["flags": ssl | verify])
        #expect(Self.attribute(verified, "SSL_VERIFY_SERVER_CERT") as? Bool == true)
        // The constants alone turn TLS on, with the client certificate and key.
        let client = try await plan(["tls": ["MYSQL_SSL_CA": ca, "MYSQL_SSL_CERT": folder.appendingPathComponent("client.pem").path, "MYSQL_SSL_KEY": folder.appendingPathComponent("client.key").path, "MYSQL_SSL_CIPHER": "ECDHE-RSA-AES256-GCM-SHA384"]])
        #expect(client["tls"] as? Bool == true)
        #expect(Self.attribute(client, "SSL_CERT") as? String == folder.appendingPathComponent("client.pem").path)
        #expect(Self.attribute(client, "SSL_KEY") as? String == folder.appendingPathComponent("client.key").path)
        #expect(Self.attribute(client, "SSL_CIPHER") as? String == "ECDHE-RSA-AES256-GCM-SHA384")
        let capath = try await plan(["tls": ["MYSQL_SSL_CAPATH": folder.path]])
        #expect(Self.attribute(capath, "SSL_CA") == nil && Self.attribute(capath, "SSL_CAPATH") as? String == folder.path)
        #expect(Self.attribute(capath, "SSL_VERIFY_SERVER_CERT") as? Bool == true)
        // A file this PHP can't read: $wpdb, with the reason.
        #expect(try await plan(["flags": ssl, "tls": ["MYSQL_SSL_CA": "/nonexistent/ca.pem"]])["fallback"] as? String == "MYSQL_SSL_CA (/nonexistent/ca.pem) isn't a file this PHP can read")
        // No flags, no constants: no TLS attributes. MYSQLI_CLIENT_COMPRESS compresses.
        let none = try await plan()
        #expect(Self.attribute(none, "SSL_CA") == nil && none["tls"] as? Bool == false)
        #expect(Self.attribute(try await plan(["flags": compress]), "COMPRESS") as? Bool == true)
    }

    // MARK: Falling back

    @Test func everyFallbackSaysWhy() async throws {
        #expect(try await plan(["wpdbOnly": true])["fallback"] as? String == "RUNLET_WPDB_ONLY is set")
        #expect(try await plan(["class": "hyperdb", "dropIn": "/srv/wp/wp-content/db.php"])["fallback"] as? String == "the db.php drop-in replaces wpdb with HyperDB, which Runlet doesn't open itself")
        #expect(try await plan(["class": "LudicrousDB", "dropIn": "/srv/wp/wp-content/db.php", "multisite": true])["fallback"] as? String == "the db.php drop-in replaces wpdb with LudicrousDB, which Runlet doesn't open itself (a multisite's databases can be split)")
        #expect(try await plan(["class": "Acme_DB"])["fallback"] as? String == "$wpdb is Acme_DB, not wpdb, which Runlet doesn't open itself")
        // Query Monitor's drop-in only times queries: wpdb's own connection.
        #expect(try await plan(["class": "QM_DB", "dropIn": "/srv/wp/wp-content/db.php"])["driver"] as? String == "mysql")
        // A missing driver (simulated: the drivers this PHP would have).
        #expect(try await plan(available: ["sqlite"])["fallback"] as? String == "this PHP has no pdo_mysql (it has pdo_sqlite)")
        #expect(try await plan(available: [])["fallback"] as? String == "this PHP has no pdo_mysql (it has no PDO drivers)")
        // $wpdb connected with other settings than the constants.
        #expect(try await plan(["wpdb": ["name": "shop_wp", "host": "replica.internal", "user": "wp"]])["fallback"] as? String == "$wpdb connected with another DB_HOST than wp-config.php defines")
        #expect(try await plan(["wpdb": ["name": "shop_wp", "host": "localhost", "user": "wp"]])["driver"] as? String == "mysql")
        #expect(try await plan(["name": NSNull()])["fallback"] as? String == "wp-config.php doesn't define DB_NAME, DB_USER, and DB_HOST as text")
    }

    @Test func theSQLiteDropInOpensItsFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-wp208-sqlite-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(".ht.sqlite").path
        try Data().write(to: URL(fileURLWithPath: file))
        let sqlite = try await plan(["class": "WP_SQLite_DB", "dropIn": "/srv/wp/wp-content/db.php", "engine": "sqlite", "sqliteFile": file])
        #expect(sqlite["driver"] as? String == "sqlite" && sqlite["dsn"] as? String == "sqlite:" + file, "\(sqlite)")
        #expect(sqlite["summary"] as? String == "sqlite, " + file)
        // DB_ENGINE alone, with a class Runlet doesn't know (an older drop-in).
        #expect(try await plan(["class": "Other_DB", "engine": "sqlite", "sqliteFile": file])["driver"] as? String == "sqlite")
        // DB_ENGINE without the drop-in's class (the drop-in bailed out): wpdb on MySQL.
        #expect(try await plan(["engine": "sqlite", "sqliteFile": file])["driver"] as? String == "mysql")
        #expect(try await plan(["class": "WP_SQLite_DB", "sqliteFile": file], available: ["mysql"])["fallback"] as? String == "the SQLite drop-in needs pdo_sqlite, and this PHP has pdo_mysql")
        #expect(try await plan(["class": "WP_SQLite_DB", "sqliteFile": folder.appendingPathComponent("missing.sqlite").path])["fallback"] as? String == "the SQLite drop-in's database file (\(folder.appendingPathComponent("missing.sqlite").path)) wasn't found (FQDB, or DB_DIR and DB_FILE)")
    }

    @Test(.enabled(if: TestSupport.herdPHP74 != nil, "requires Herd's PHP 7.4"))
    func plansOnPHP74() async throws {
        let php = TestSupport.herdPHP74!
        let tls = try await plan(["host": "[::1]:3307", "flags": 2048], php: php)
        #expect(tls["dsn"] as? String == "mysql:host=[::1];port=3307;dbname=shop_wp;charset=utf8mb4")
        #expect(Self.attribute(tls, "SSL_VERIFY_SERVER_CERT") as? Bool == false)
        #expect(try await plan(["class": "hyperdb", "dropIn": "/x/db.php"], php: php)["fallback"] as? String == "the db.php drop-in replaces wpdb with HyperDB, which Runlet doesn't open itself")
    }

    // MARK: The WordPress fixture (SQLite drop-in)

    @Test(.enabled(if: WordPressPDOTests.fixtureReady, "requires the WordPress SQLite fixture"))
    func theFixtureRunsOnItsOwnPDOAndKeepsWpdbByName() async throws {
        let fixture = DriverSupport.fixture("wordpress")
        let select = try await TestSupport.run(SQLTabRun.code(statement: "SELECT option_value FROM rl_options WHERE option_name = 'blogname'", connection: nil), target: DriverSupport.target(fixture), magicComments: false)
        #expect(select.errors.isEmpty, "\(select.errors)")
        #expect(select.sqlResult?.source == "WordPress (PDO from wp-config)")
        #expect(select.sqlResult?.driver == "sqlite")
        #expect(select.sqlResult?.originText == "sqlite · default connection · via WordPress (PDO from wp-config)")
        #expect(select.logEntries.contains { $0.source == "sql" && $0.message.hasPrefix("WordPress: PDO connection from wp-config.php (sqlite, ") && $0.message.hasSuffix("/wp-content/database/.ht.sqlite)") }, "\(select.logEntries)")
        let wpdb = try await TestSupport.run(SQLTabRun.code(statement: "SELECT option_value FROM rl_options WHERE option_name = 'blogname'", connection: "wpdb"), target: DriverSupport.target(fixture), magicComments: false)
        #expect(wpdb.errors.isEmpty, "\(wpdb.errors)")
        #expect(wpdb.sqlResult?.source == "WordPress $wpdb" && wpdb.sqlResult?.driver == nil)
        #expect(wpdb.sqlResult?.rows == select.sqlResult?.rows)
        let named = try await TestSupport.run(SQLTabRun.code(statement: "SELECT 1", connection: "replica"), target: DriverSupport.target(fixture), magicComments: false)
        #expect(named.errors.first?.message.contains("WordPress has one database connection, not \"replica\"") == true, "\(named.errors)")
    }

    /// A clone of the WordPress fixture (APFS copies it without copying the bytes) with `p208_items`:
    /// 1,200 rows, `id` 1…1,200, `name` "Item 0001"…, `price` id / 4, `note` NULL for every tenth.
    static func scratchFixture(config: String? = nil) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-wp208-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.copyItem(at: TestSupport.fixtures.appendingPathComponent("wordpress"), to: directory)
        let php = Process()
        php.executableURL = URL(fileURLWithPath: DriverSupport.php)
        php.arguments = ["-r", """
            $p = new PDO('sqlite:' . $argv[1], null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
            $p->exec('CREATE TABLE p208_items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, price NUMERIC, note TEXT)');
            $p->beginTransaction();
            $s = $p->prepare('INSERT INTO p208_items (id, name, price, note) VALUES (?, ?, ?, ?)');
            for ($i = 1; $i <= 1200; $i++) { $s->execute([$i, sprintf('Item %04d', $i), $i / 4, $i % 10 === 0 ? null : 'note ' . $i]); }
            $p->commit();
            """, directory.appendingPathComponent("wp-content/database/.ht.sqlite").path]
        try php.run()
        php.waitUntilExit()
        if let config {
            let file = directory.appendingPathComponent("wp-config.php")
            let text = try String(contentsOf: file, encoding: .utf8)
            try text.replacingOccurrences(of: "$table_prefix = 'rl_';", with: "$table_prefix = 'rl_';\n" + config).write(to: file, atomically: true, encoding: .utf8)
        }
        return directory
    }

    @Test(.enabled(if: WordPressPDOTests.fixtureReady, "requires the WordPress SQLite fixture"))
    func everyDatabaseFeatureWorksThroughThePDO() async throws {
        let directory = try Self.scratchFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await WordPressPDOFeatures(directory: directory, dialect: .sqlite, label: "SQLite drop-in").checkAll()
    }

    @Test(.enabled(if: WordPressPDOTests.fixtureReady, "requires the WordPress SQLite fixture"))
    func runletWpdbOnlyKeepsWpdbAndItsLimits() async throws {
        let directory = try Self.scratchFixture(config: "define( 'RUNLET_WPDB_ONLY', true );")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = DriverSupport.target(directory.path)
        let select = try await TestSupport.run(SQLTabRun.code(statement: "SELECT name FROM p208_items WHERE id = 7", connection: nil), target: target, magicComments: false)
        #expect(select.errors.isEmpty, "\(select.errors)")
        let origin = "WordPress ($wpdb, because RUNLET_WPDB_ONLY is set)"
        #expect(select.sqlResult?.source == origin)
        #expect(select.sqlResult?.rows == [[.string("Item 0007")]])
        #expect(select.logEntries.contains { $0.source == "sql" && $0.message == "WordPress: statements run through $wpdb, because RUNLET_WPDB_ONLY is set" })
        // Still a callable: values are refused before anything runs, naming the reason.
        let bound = try await TestSupport.run(SQLTabRun.code(statement: "SELECT name FROM p208_items WHERE id = :id", connection: nil, bindings: [SQLBinding(target: .name("id"), value: .integer(7))]), target: target, magicComments: false)
        #expect(bound.errors.first?.className == "RunletRunner\\SqlParametersRefused")
        #expect(bound.errors.first?.message.contains("this connection (\(origin)) runs statements through WordPress's $wpdb") == true, "\(bound.errors)")
        // The app still treats it as $wpdb's MySQL: browsing read-only, editing refused.
        #expect(SQLTableBrowse.Dialect(driver: nil, source: origin) == .mysql)
        #expect(SQLTableBrowse.isWordPressWpdb(origin) && !SQLTableBrowse.isWordPressWpdb("WordPress (PDO from wp-config)"))
        let table = SQLSchemaInfo.Table(name: "p208_items", columns: [.init(name: "id", type: "integer", primaryKey: true)])
        #expect(SQLTableEdits.refusal(table: table, driver: nil, source: origin, readOnlyConnection: nil) == .callable(origin))
    }
}

/// The database features #208 gives WordPress, run against one WordPress project with
/// `p208_items` (see `WordPressPDOTests.scratchFixture`, `WordPressPDOLiveTests`): each must run
/// through "WordPress (PDO from wp-config)".
struct WordPressPDOFeatures {
    let directory: URL
    let dialect: SQLTableBrowse.Dialect
    let label: String
    static let origin = "WordPress (PDO from wp-config)"

    var target: TargetSnapshot { DriverSupport.target(directory.path) }
    var driver: String { dialect == .sqlite ? "sqlite" : "mysql" }
    var columns: [SQLSchemaInfo.Column] {
        dialect == .sqlite
            ? [.init(name: "id", type: "INTEGER", nullable: false, primaryKey: true), .init(name: "name", type: "TEXT", nullable: false), .init(name: "price", type: "NUMERIC"), .init(name: "note", type: "TEXT")]
            : [.init(name: "id", type: "int", nullable: false, primaryKey: true), .init(name: "name", type: "varchar", nullable: false), .init(name: "price", type: "decimal"), .init(name: "note", type: "varchar")]
    }

    func run(_ code: String) async throws -> [RunEvent] {
        try await TestSupport.run(code, target: target, magicComments: false)
    }

    func rows(_ sql: String) async throws -> [[SQLCell]] {
        let events = try await run(SQLTabRun.code(statement: sql, connection: nil))
        #expect(events.errors.isEmpty, "\(label): \(sql): \(events.errors)")
        #expect(events.sqlResult?.source == Self.origin, "\(label)")
        return events.sqlResult?.rows ?? []
    }

    func checkAll() async throws {
        try await boundValues()
        try await browseAndEdit()
        try await importCSV()
        try await explain()
        try await loadNext()
        try await runAllInATransaction()
        try await showDefinition()
    }

    func boundValues() async throws {
        let positional = try await run(SQLTabRun.code(statement: "SELECT name FROM p208_items WHERE id = ? AND price > ?", connection: nil, bindings: [
            SQLBinding(target: .position(1), value: .integer(8)), SQLBinding(target: .position(2), value: .decimal("1.5")),
        ]))
        #expect(positional.errors.isEmpty, "\(label): \(positional.errors)")
        #expect(positional.sqlResult?.rows == [[.string("Item 0008")]], "\(label)")
        let named = try await run(SQLTabRun.code(statement: "SELECT name FROM p208_items WHERE id = :id OR name = :name", connection: nil, bindings: [
            SQLBinding(target: .name("id"), value: .integer(7)), SQLBinding(target: .name("name"), value: .text("x' OR '1'='1")),
        ]))
        #expect(named.errors.isEmpty, "\(label): \(named.errors)")
        #expect(named.sqlResult?.rows == [[.string("Item 0007")]], "\(label): a value that looks like SQL stays data")
        #expect(named.sqlResult?.source == Self.origin && named.sqlResult?.driver == driver, "\(label)")
    }

    func request(sort: SQLTableBrowse.Sort? = nil, filters: [SQLTableBrowse.Filter] = [], pageSize: Int = 100) -> SQLTableBrowse.Request {
        SQLTableBrowse.Request(table: "p208_items", columns: columns, dialect: dialect, sort: sort, filters: filters, offset: 0, pageSize: pageSize, bindsValues: true)
    }

    func browseAndEdit() async throws {
        // The schema the app reads makes the table editable.
        let schema = try await ExecutionEngine(bundle: TestSupport.bundle, docker: nil).loadSQLSchema(target: target, connection: nil)
        #expect(schema.source == Self.origin && schema.driver == driver, "\(label): \(schema.source ?? "") \(schema.driver ?? "")")
        let table = try #require(schema.tables.first { $0.name == "p208_items" }, "\(label): \(schema.tables.map(\.name))")
        #expect(SQLTableEdits.refusal(table: table, driver: schema.driver, source: schema.source, readOnlyConnection: nil) == nil, "\(label)")
        #expect(SQLTableBrowse.Dialect(driver: schema.driver, source: schema.source) == dialect)

        // Filters with values, bound.
        let filtered = try await run(SQLTabRun.browseCode(try SQLTableBrowse.query(request(filters: [.init(column: "name", op: .equals, value: "Item 0010"), .init(column: "price", op: .greaterThan, value: "1")])).get(), connection: nil, driver: driver))
        #expect(filtered.errors.isEmpty, "\(label): \(filtered.errors)")
        #expect(filtered.sqlResult?.rows.map { $0[0].text } == ["10"], "\(label)")
        let first = try await run(SQLTabRun.browseCode(try SQLTableBrowse.query(request(sort: .init(column: "id", ascending: true), pageSize: 5)).get(), connection: nil, driver: driver))
        let page = try #require(first.sqlResult, "\(label): \(first.errors)")
        #expect(page.rows.count == 5 && page.truncated == true, "\(label)")

        // Reviewed changes, in one transaction.
        var changes = SQLTableEdits.Changes()
        changes.set(row: 0, column: 1, to: .text("Lamp"), original: page.rows[0][1])
        changes.delete(rows: [1])
        changes.addRow()
        changes.setNew(row: 0, column: 0, to: .text("5001"))
        changes.setNew(row: 0, column: 1, to: .text("Chair"))
        let statements = try SQLTableEdits.statements(changes, table: "p208_items", columns: columns, rows: page.rows, dialect: dialect, offset: 0).get()
        let applied = try await run(SQLTabRun.applyCode(statements, connection: nil, driver: driver))
        #expect(applied.errors.isEmpty, "\(label): \(applied.errors)")
        #expect(applied.sqlResults.map(\.affectedRows) == [1, 1, 1], "\(label)")
        #expect(applied.sqlNotices.last == "Committed the transaction: all 3 changes affected exactly one row each.", "\(label)")
        #expect(try await rows("SELECT id, name FROM p208_items WHERE id IN (1, 2, 5001) ORDER BY id").map { $0.map(\.text) } == [["1", "Lamp"], ["5001", "Chair"]], "\(label)")
    }

    func importCSV() async throws {
        let csvColumns = [SQLSchemaInfo.Column(name: "id", type: dialect == .sqlite ? "integer" : "int", primaryKey: true), SQLSchemaInfo.Column(name: "name", type: dialect == .sqlite ? "text" : "varchar", nullable: false), SQLSchemaInfo.Column(name: "note", type: dialect == .sqlite ? "text" : "varchar")]
        let plan = try SQLCSVImport.parse("id,name,note\n6001,washer,\n6002,\"spring, coil\",soft\n6003,pin,x\n", table: "p208_items", tableColumns: csvColumns, driver: driver)
        var request = RunRequest(tabId: UUID(), documentVersion: 1, target: target, code: plan.code(connection: nil), inspector: RunInspectorOptions(), magicComments: false)
        request.sqlBatches = plan.batches()
        var events: [RunEvent] = []
        // The engine must outlive the run: it launches the runner from a task that holds it weakly.
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
        for await event in try await engine.start(request) { events.append(event) }
        #expect(events.errors.isEmpty, "\(label): \(events.errors)")
        #expect(events.sqlImportReports.last?.inserted == 3 && events.sqlImportReports.last?.done == true, "\(label): \(events.sqlImportReports)")
        #expect(try await rows("SELECT COUNT(*) AS n FROM p208_items WHERE id BETWEEN 6001 AND 6003").first?.first?.text == "3", "\(label)")
    }

    func explain() async throws {
        let events = try await run(SQLExplain.code(statement: "SELECT * FROM p208_items WHERE id = :id", connection: nil, mode: .plan, bindings: [SQLBinding(target: .name("id"), value: .integer(5))]))
        #expect(events.errors.isEmpty, "\(label): \(events.errors)")
        let plan = try #require(events.sqlPlan, "\(label)")
        #expect(plan.source == Self.origin && plan.driver == driver, "\(label): \(plan.source ?? "") \(plan.driver ?? "")")
        #expect(plan.plan != nil || plan.rows?.isEmpty == false, "\(label)")
    }

    func loadNext() async throws {
        let statement = "SELECT id, name FROM p208_items ORDER BY id"
        let first = try await run(SQLTabRun.code(statement: statement, connection: nil, maxRows: 1000))
        let result = try #require(first.sqlResult, "\(label): \(first.errors)")
        #expect(result.truncated == true && result.rows.count == 1000, "\(label)")
        let paging = try SQLPaging.plan(for: statement, driver: result.driver).get()
        #expect(paging.mode == .append, "\(label): the database pages, not the runner")
        let next = try await run(SQLTabRun.pageCode(paging.page(offset: 1000, size: 1000), connection: nil))
        #expect(next.errors.isEmpty, "\(label): \(next.errors)")
        // The page continues where the first one ended (earlier steps changed some rows).
        let last = Int(result.rows.last?.first?.text ?? "") ?? 0
        let continued = Int(next.sqlResult?.rows.first?.first?.text ?? "") ?? 0
        #expect(last > 0 && continued > last, "\(label): \(last) then \(continued)")
        #expect(SQLResultInfo(columns: result.columns, rows: result.rows).appending(try #require(next.sqlResult)) != nil, "\(label): the same columns")
        #expect(next.sqlResult?.source == Self.origin, "\(label)")
    }

    func runAllInATransaction() async throws {
        let failing = try SQLScript.statementsToRunAll(in: "INSERT INTO p208_items (id, name) VALUES (7001, 'Desk');\nSELECT nope FROM p208_missing;", selection: NSRange(location: 0, length: 0)).get()
        let failed = try await run(SQLTabRun.scriptCode(statements: failing, connection: nil, transaction: true))
        #expect(failed.errors.first?.message.contains("Rolled back the transaction: statement 1 was undone.") == true, "\(label): \(failed.errors)")
        #expect(try await rows("SELECT COUNT(*) AS n FROM p208_items WHERE id = 7001").first?.first?.text == "0", "\(label): rolled back")
        let committing = try SQLScript.statementsToRunAll(in: "INSERT INTO p208_items (id, name) VALUES (7002, 'Shelf');\nSELECT name FROM p208_items WHERE id = 7002;", selection: NSRange(location: 0, length: 0)).get()
        let committed = try await run(SQLTabRun.scriptCode(statements: committing, connection: nil, transaction: true))
        #expect(committed.errors.isEmpty, "\(label): \(committed.errors)")
        #expect(committed.sqlNotices.last == "Committed the transaction: all 2 statements ran.", "\(label)")
        #expect(committed.sqlResults.last?.rows == [[.string("Shelf")]], "\(label)")
    }

    func showDefinition() async throws {
        let info = try await ExecutionEngine(bundle: TestSupport.bundle, docker: nil).loadSQLDefinition(target: target, table: "p208_items", connection: nil)
        #expect(info.sql.contains("p208_items"), "\(label): \(info.sql)")
        #expect(info.driver == driver, "\(label)")
    }
}
