import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// #184: a connection from this Mac gets the first local PHP, in the usual order, that has its
/// driver; the drivers come from discovery or a cache, never from a probe per run; and when no
/// PHP has the driver, the message names it and the PHPs checked.
struct PHPDriverChoiceTests {
    static func php(_ path: String, _ version: String, source: String, drivers: PHPDrivers?) -> PHPInstallation {
        var php = PHPInstallation(path: path, version: version, hasTokenizer: true, source: source)
        php.drivers = drivers
        return php
    }

    /// Runlet's PHP r3: MySQL, PostgreSQL, SQLite, phpredis, and ext-mongodb; no SQL Server.
    static let runlet = php("/data/PHP/8.5.8-r3/bin/php", "8.5.8", source: RunletPHPStore.sourceName,
                            drivers: PHPDrivers(pdo: ["mysql", "pgsql", "sqlite"], extensions: ["redis", "mongodb"]))
    /// The default PHP (Herd): SQL Server through Microsoft's driver, and Oracle.
    static let herd = php("/Users/someone/Library/Application Support/Herd/bin/php", "8.4.25", source: "Herd",
                          drivers: PHPDrivers(pdo: ["mysql", "pgsql", "sqlite", "sqlsrv", "oci"]))
    /// Homebrew: FreeTDS and ODBC.
    static let brew = php("/opt/homebrew/bin/php", "8.3.9", source: "Homebrew",
                          drivers: PHPDrivers(pdo: ["sqlite", "dblib", "odbc"], extensions: ["mongodb"]))
    static let installations = [herd, brew, runlet]

    static func connection(_ driver: DatabaseDriverKind, dsn: String? = nil, name: String = "Warehouse") -> DatabaseConnection {
        var connection = DatabaseConnection(name: name, scope: nil, connectFrom: .thisMac, driver: driver, host: "127.0.0.1", database: driver == .sqlite ? "/tmp/a.sqlite" : "")
        connection.dsn = dsn
        return connection
    }

    static func drivers(_ installations: [PHPInstallation]) -> (String) -> PHPDrivers? {
        { path in installations.first { $0.path == path }?.drivers }
    }

    var candidates: [LocalConnectionLaunch.PHP] {
        LocalConnectionLaunch.candidates(runlet: Self.runlet, defaultPath: Self.herd.path, installations: Self.installations)
    }

    func choose(_ connection: DatabaseConnection, candidates: [LocalConnectionLaunch.PHP]? = nil, installations: [PHPInstallation] = installations) -> LocalConnectionLaunch.Choice? {
        LocalConnectionLaunch.choosePHP(for: connection, candidates: candidates ?? self.candidates, drivers: Self.drivers(installations))
    }

    @Test func oneOrderForEveryDriver() {
        #expect(candidates.map(\.path) == [Self.runlet.path, Self.herd.path, Self.brew.path])
        #expect(candidates.map(\.label) == ["Runlet's PHP 8.5.8", "Herd PHP 8.4.25", "Homebrew PHP 8.3.9"])
        // MongoDB's list (#212) is the same list now.
        #expect(MongoLaunch.candidates(runlet: Self.runlet, defaultPath: Self.herd.path, installations: Self.installations) == candidates)
        // The first choice, whatever the driver, is the first candidate.
        #expect(LocalConnectionLaunch.choosePHP(runlet: Self.runlet, defaultPath: Self.herd.path, installations: Self.installations) == candidates.first)
    }

    @Test func mysqlPostgresAndSQLiteStayOnRunletsPHP() throws {
        for driver in [DatabaseDriverKind.mysql, .pgsql, .sqlite] {
            let choice = try #require(choose(Self.connection(driver)))
            #expect(choice.php.isRunletPHP, "\(driver)")
            #expect(choice.passedOver.isEmpty)
            #expect(choice.label == "Runlet's PHP 8.5.8")
            #expect(choice.reason == nil)
        }
    }

    @Test func sqlServerPicksTheFirstPHPWithItsDriver() throws {
        let choice = try #require(choose(Self.connection(.sqlsrv)))
        #expect(choice.php.path == Self.herd.path)
        #expect(choice.passedOver.map(\.path) == [Self.runlet.path])
        #expect(choice.label == "Herd PHP 8.4.25, the first PHP here with pdo_sqlsrv or pdo_dblib")
        #expect(choice.reason == "Runlet's PHP 8.5.8 comes first but has neither pdo_sqlsrv nor pdo_dblib.")
        #expect(!choice.label.contains("/"), "labels never show a path")

        // FreeTDS (pdo_dblib) will do when no PHP has Microsoft's driver.
        let withoutHerd = LocalConnectionLaunch.candidates(runlet: Self.runlet, defaultPath: nil, installations: [Self.brew, Self.runlet])
        let dblib = try #require(choose(Self.connection(.sqlsrv), candidates: withoutHerd))
        #expect(dblib.php.path == Self.brew.path)
    }

    @Test func aCustomDSNNeedsTheDriverItNames() throws {
        #expect(try #require(choose(Self.connection(.custom, dsn: "oci:dbname=//db.internal:1521/XE"))).php.path == Self.herd.path)
        let odbc = try #require(choose(Self.connection(.custom, dsn: "odbc:Driver={FreeTDS};Server=db")))
        #expect(odbc.php.path == Self.brew.path)
        #expect(odbc.passedOver.map(\.label) == ["Runlet's PHP 8.5.8", "Herd PHP 8.4.25"])
        #expect(odbc.reason == "Runlet's PHP 8.5.8 and Herd PHP 8.4.25 come first but have no pdo_odbc.")
        // A DSN for a driver Runlet's PHP has stays there.
        #expect(try #require(choose(Self.connection(.custom, dsn: "mysql:host=db;dbname=shop"))).php.isRunletPHP)
        #expect(choose(Self.connection(.custom, dsn: "firebird:dbname=db")) == nil)
    }

    @Test func mongoDBNeedsTheExtensionAndRedisNothing() throws {
        #expect(try #require(choose(Self.connection(.mongodb))).php.isRunletPHP)
        // Without Runlet's PHP: the default PHP (Herd) lacks it, Homebrew has it.
        let others = LocalConnectionLaunch.candidates(runlet: nil, defaultPath: Self.herd.path, installations: [Self.herd, Self.brew])
        let mongo = try #require(choose(Self.connection(.mongodb), candidates: others))
        #expect(mongo.php.path == Self.brew.path)
        #expect(mongo.reason == "Herd PHP 8.4.25 comes first but has no ext-mongodb.")
        // Redis: Runlet's RESP client needs no extension, so the first PHP, whatever it has.
        let bare = Self.php("/usr/bin/php", "8.2.0", source: "PATH", drivers: PHPDrivers())
        let redis = try #require(choose(Self.connection(.redis), candidates: LocalConnectionLaunch.candidates(runlet: nil, defaultPath: nil, installations: [bare, Self.brew]), installations: [bare, Self.brew]))
        #expect(redis.php.path == bare.path && redis.reason == nil)
    }

    @Test func noPHPWithTheDriverNamesItAndThePHPsChecked() {
        let connection = Self.connection(.sqlsrv)
        let checked = LocalConnectionLaunch.candidates(runlet: Self.runlet, defaultPath: nil, installations: [Self.runlet])
        #expect(choose(connection, candidates: checked) == nil)
        let message = LocalConnectionLaunch.noPHPMessage(connection, checked: checked)
        #expect(message.hasPrefix("No PHP on this Mac has pdo_sqlsrv or pdo_dblib, which the saved connection “Warehouse” needs, so nothing ran. Checked Runlet's PHP 8.5.8."))
        #expect(message.contains("install the driver in one of these PHPs"))

        let two = LocalConnectionLaunch.candidates(runlet: Self.runlet, defaultPath: nil, installations: [Self.runlet, Self.herd])
        let oracle = Self.connection(.custom, dsn: "firebird:dbname=db", name: "Ledger")
        #expect(LocalConnectionLaunch.noPHPMessage(oracle, checked: two).contains("has pdo_firebird, which the saved connection “Ledger” needs, so nothing ran. Checked Runlet's PHP 8.5.8 and Herd PHP 8.4.25."))

        // MySQL without Runlet's PHP: it has the driver, so the message offers it.
        let bare = Self.php("/usr/bin/php", "8.2.0", source: "PATH", drivers: PHPDrivers(pdo: ["sqlite"]))
        let mysql = LocalConnectionLaunch.noPHPMessage(Self.connection(.mysql, name: "Shop"), checked: LocalConnectionLaunch.candidates(runlet: nil, defaultPath: nil, installations: [bare]))
        #expect(mysql.contains("Checked PHP 8.2.0.") && mysql.contains("Download Runlet's PHP in Settings ▸ PHP"))
        // MongoDB keeps its advice.
        #expect(LocalConnectionLaunch.noPHPMessage(Self.connection(.mongodb), checked: [checked[0]]).contains("ext-mongodb from build r3"))
        // No PHP at all: the message from before.
        #expect(LocalConnectionLaunch.noPHPMessage(connection, checked: []) == LocalConnectionLaunch.noPHPMessage(connection))
    }

    @Test func unknownDriversAreTriedOnlyWhenNoKnownPHPHasTheDriver() throws {
        let unknown = Self.php("/opt/php/bin/php", "8.3.0", source: "PATH", drivers: nil)
        // An unchecked PHP before one known to have the driver is skipped.
        let order = LocalConnectionLaunch.candidates(runlet: Self.runlet, defaultPath: unknown.path, installations: [unknown, Self.herd, Self.runlet])
        #expect(try #require(choose(Self.connection(.sqlsrv), candidates: order, installations: [unknown, Self.herd, Self.runlet])).php.path == Self.herd.path)
        // When none known has it, the unchecked one is tried, and the reason says so.
        let fallback = try #require(choose(Self.connection(.sqlsrv), candidates: order, installations: [unknown, Self.runlet]))
        #expect(fallback.php.path == unknown.path)
        #expect(fallback.unchecked)
        #expect(fallback.reason == "Runlet's PHP 8.5.8 comes first but has neither pdo_sqlsrv nor pdo_dblib. Runlet couldn't read the drivers of PHP 8.3.0, so it tries that one.")
    }

    // MARK: The cache

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func add(_ path: String) { lock.withLock { paths.append(path) } }
        var all: [String] { lock.withLock { paths } }
    }

    @Test func driversAreReadOnceAndKeptUntilTheInstallationsChange() async {
        let counter = Counter()
        let typed = "/usr/local/bin/php8"
        let cache = PHPDriverCache { path in
            counter.add(path)
            try? await Task.sleep(for: .milliseconds(30))
            return path == typed ? PHPDrivers(pdo: ["sqlsrv"]) : nil
        }
        cache.update(installations: Self.installations)
        // Listed installations come from discovery: nothing to probe.
        #expect(cache.known(Self.herd.path) == Self.herd.drivers)
        await cache.prepare(Self.installations.map(\.path))
        #expect(cache.probeCount == 0)
        #expect(cache.known(typed) == nil)

        // A default PHP discovery didn't list is probed once, even when asked for at once.
        async let first: Void = cache.prepare([typed, Self.runlet.path])
        async let second: Void = cache.prepare([typed])
        _ = await (first, second)
        #expect(counter.all == [typed])
        #expect(cache.known(typed) == PHPDrivers(pdo: ["sqlsrv"]))
        // Every later run reads the cache.
        for _ in 0..<5 { await cache.prepare([typed]) }
        #expect(cache.probeCount == 1)

        // A probe that fails isn't retried on every run either.
        await cache.prepare(["/broken/php"])
        await cache.prepare(["/broken/php"])
        #expect(counter.all == [typed, "/broken/php"])
        #expect(cache.known("/broken/php") == nil)

        // Discovery ran again: probed paths are read again when next needed.
        cache.update(installations: [Self.runlet])
        #expect(cache.known(typed) == nil)
        #expect(cache.known(Self.herd.path) == nil)
        await cache.prepare([typed])
        #expect(counter.all == [typed, "/broken/php", typed])
    }
}

/// The probe against this Mac's PHP (#184).
@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct PHPDriverProbeTests {
    @Test func discoveryReadsTheDriversOfAnInstallation() async throws {
        let path = try #require(TestSupport.php())
        let probed = try #require(await PHPDiscovery.drivers(executable: path))
        let php = try #require(await PHPDiscovery.inspect(path: path))
        #expect(php.drivers == probed)
        #expect(probed.pdo == probed.pdo.map { $0.lowercased() })
        #expect(probed.extensions.allSatisfy { PHPDrivers.extensionNames.contains($0) })
        // The same as PHP says itself.
        let output = try await runCommand(ProcessSpec(executable: path, arguments: ["-r", "echo implode(',', PDO::getAvailableDrivers());"]), timeout: .seconds(10))
        #expect(probed.pdo == String(decoding: output.stdout, as: UTF8.self).split(separator: ",").map { $0.lowercased() })
        #expect(await PHPDiscovery.drivers(executable: "/nonexistent/bin/php") == nil)
    }
}
