import Foundation
import RunletCore
import Testing
@testable import RunletExecution

extension TestSupport {
    /// Runlet's own PHP (#2) for tests that need its drivers: `RUNLET_TEST_RUNLET_PHP`, a
    /// `bin/php` from a scratch install (never the owner's data folder). nil skips them.
    static var runletPHP: String? {
        guard let path = ProcessInfo.processInfo.environment["RUNLET_TEST_RUNLET_PHP"], !path.isEmpty else { return nil }
        return ExecutableLocator.resolve(path)
    }
}

/// Saved connections opened from this Mac (#142): the PHP Runlet picks, the empty folder, the
/// local snapshot, the engine refusing to send such a connection elsewhere, and runs through
/// the real runner with host PHP and SQLite: no project code, nothing written to the project
/// or the folder, the password in no event, and messages that say this Mac.
@Suite(.serialized, .enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct LocalConnectionLaunchTests {
    static let password = "fixture-mac-Pw7"

    static func php(_ path: String, _ version: String, source: String) -> PHPInstallation {
        PHPInstallation(path: path, version: version, hasTokenizer: true, source: source)
    }

    static func scratch() throws -> (paths: AppPaths, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-local-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (AppPaths(root: root), root)
    }

    /// An SQLite database outside any project, by absolute path.
    static func database(in folder: URL) throws -> URL {
        let file = folder.appendingPathComponent("shop.sqlite")
        let php = Process()
        php.executableURL = URL(fileURLWithPath: DriverSupport.php)
        php.arguments = ["-r", """
            $p = new PDO('sqlite:' . $argv[1]);
            $p->exec("CREATE TABLE p142_customers (id INTEGER PRIMARY KEY, email TEXT NOT NULL)");
            $p->exec("INSERT INTO p142_customers (email) VALUES ('a@example.test'), ('b@example.test')");
            """, file.path]
        try php.run()
        php.waitUntilExit()
        return file
    }

    static func engine(for connection: DatabaseConnection) throws -> ExecutionEngine {
        let store = InMemoryCredentialStore()
        try store.set(SensitiveString(password), for: connection.id, label: "Runlet database: \(connection.name)")
        return ExecutionEngine(bundle: TestSupport.bundle, docker: nil, credentials: store)
    }

    static func run(_ code: String, connection: DatabaseConnection, target: TargetSnapshot) async throws -> [RunEvent] {
        var request = RunRequest(tabId: UUID(), documentVersion: 1, target: target, code: code, magicComments: false)
        request.sqlConnection = connection
        // The engine must outlive the run: it launches the process from a task that holds it weakly.
        let engine = try engine(for: connection)
        var events: [RunEvent] = []
        for await event in try await engine.start(request) { events.append(event) }
        withExtendedLifetime(engine) {}
        return events
    }

    @Test func runletPHPFirstThenTheDefaultThenAutomatic() {
        let herd = Self.php("/Users/someone/Library/Application Support/Herd/bin/php", "8.4.25", source: "Herd")
        let brew = Self.php("/opt/homebrew/bin/php", "8.3.9", source: "Homebrew")
        let runlet = Self.php("/data/PHP/8.5.8-r2/bin/php", "8.5.8", source: RunletPHPStore.sourceName)

        let own = LocalConnectionLaunch.choosePHP(runlet: runlet, defaultPath: brew.path, installations: [herd, brew, runlet])
        #expect(own == LocalConnectionLaunch.PHP(path: runlet.path, label: "Runlet's PHP 8.5.8", isRunletPHP: true))

        let chosen = LocalConnectionLaunch.choosePHP(runlet: nil, defaultPath: brew.path, installations: [herd, brew])
        #expect(chosen?.path == brew.path && chosen?.label == "PHP 8.3.9 (Homebrew)" && chosen?.isRunletPHP == false)
        let typed = LocalConnectionLaunch.choosePHP(runlet: nil, defaultPath: "/usr/local/bin/php8", installations: [herd])
        #expect(typed?.label == "the default PHP", "a path that isn't listed is never shown")

        let automatic = LocalConnectionLaunch.choosePHP(runlet: nil, defaultPath: nil, installations: [herd, brew])
        #expect(automatic?.path == herd.path)
        #expect(automatic.map { !$0.label.contains("/") } == true, "labels never show a path")
        #expect(LocalConnectionLaunch.choosePHP(runlet: nil, defaultPath: nil, installations: []) == nil)

        let connection = DatabaseConnection(name: "Analytics", scope: nil, driver: .pgsql, host: "127.0.0.1")
        #expect(LocalConnectionLaunch.noPHPMessage(connection).contains("Download Runlet's PHP in Settings ▸ PHP"))
    }

    @Test func theFolderAndTheSnapshot() throws {
        let (paths, root) = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try LocalConnectionLaunch.directory(in: paths)
        #expect(folder.path.hasPrefix(root.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)

        let connection = DatabaseConnection(name: "Analytics", scope: nil, driver: .sqlite, database: "/tmp/a.sqlite", revision: 3)
        let snapshot = LocalConnectionLaunch.snapshot(connection: connection, php: .init(path: "/usr/bin/php", label: "Runlet's PHP 8.5.8", isRunletPHP: true), directory: folder)
        #expect(snapshot.kind == .local && snapshot.targetId == LocalConnectionLaunch.targetId)
        #expect(snapshot.label == "Analytics · this Mac (Runlet's PHP 8.5.8)")
        #expect(snapshot.workingDirectory == folder.path && snapshot.phpExecutable == "/usr/bin/php")
    }

    @Test func aConnectionFromThisMacIsNeverSentElsewhere() async throws {
        let shared = DatabaseConnection(name: "Analytics", scope: nil, driver: .pgsql, host: "127.0.0.1", user: "reader")
        let fromMac = DatabaseConnection(name: "Replica", scope: .docker(UUID()), connectFrom: .thisMac, driver: .mysql, host: "127.0.0.1")
        let engine = try Self.engine(for: shared)
        let elsewhere = [
            TargetSnapshot(kind: .docker, label: "Shop · app", targetId: "x", workingDirectory: "/var/www", phpExecutable: "php", containerId: "abc"),
            TargetSnapshot(kind: .ssh, label: "Staging", targetId: "y", workingDirectory: "/srv", phpExecutable: "php"),
            // The project's own directory on this Mac isn't Runlet's empty folder either.
            TestSupport.localTarget(DriverSupport.fixture("plain"), php: DriverSupport.php),
        ]
        for target in elsewhere {
            for connection in [shared, fromMac] {
                var request = RunRequest(tabId: UUID(), documentVersion: 1, target: target, code: "", magicComments: false)
                request.sqlConnection = connection
                await #expect(throws: ExecutionError.self, "\(connection.name) on \(target.label)") { _ = try await engine.start(request) }
                await #expect(throws: ExecutionError.self) { _ = try await engine.loadSQLSchema(target: target, connection: nil, saved: connection) }
                await #expect(throws: ExecutionError.self) { _ = try await engine.testSQLConnection(target: target, connection: connection, password: .stored) }
            }
        }
        #expect(await engine.activeRunIds.isEmpty, "nothing was launched")
    }

    @Test func runsFromRunletsFolderWithoutProjectCode() async throws {
        let (paths, root) = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let file = try Self.database(in: data)
        let folder = try LocalConnectionLaunch.directory(in: paths)
        let connection = DatabaseConnection(name: "Analytics", scope: nil, driver: .sqlite, database: file.path).normalized
        let php = LocalConnectionLaunch.PHP(path: DriverSupport.php, label: "PHP (host)", isRunletPHP: false)
        let target = LocalConnectionLaunch.snapshot(connection: connection, php: php, directory: folder)

        let events = try await Self.run(SQLTabRun.code(statement: "SELECT id, email, '\(Self.password)' AS echoed FROM p142_customers ORDER BY id", connection: nil, schema: true), connection: connection, target: target)
        #expect(events.errors.isEmpty, "\(events.errors)")
        let result = try #require(events.sqlResult)
        #expect(result.rows.count == 2 && result.saved == true && result.connection == "Analytics")
        #expect(events.started?.workingDirectory.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == folder.resolvingSymlinksInPath().path)
        #expect(events.bootstrapped?.framework == "plain")
        #expect(events.sqlSchema?.tables.map(\.name) == ["p142_customers"])
        #expect(!events.scannableText.contains { $0.contains(Self.password) }, "the password appears in no event")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty, "nothing is written to Runlet's folder")

        // Load Schema and Test Connection take the same path.
        let engine = try Self.engine(for: connection)
        #expect(try await engine.loadSQLSchema(target: target, connection: nil, saved: connection).tables.count == 1)
        let info = try await engine.testSQLConnection(target: target, connection: connection, password: .stored)
        #expect(info.driver == "sqlite" && info.pdoDrivers?.contains("sqlite") == true, "\(info)")
        #expect(info.openedFrom == nil, "the runner never says where it ran; the app does")
    }

    @Test func messagesSayThisMac() async throws {
        let (paths, root) = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try LocalConnectionLaunch.directory(in: paths)
        let php = LocalConnectionLaunch.PHP(path: DriverSupport.php, label: "PHP (host)", isRunletPHP: false)

        let missing = DatabaseConnection(name: "Gone", scope: nil, driver: .sqlite, database: root.appendingPathComponent("missing.sqlite").path)
        let gone = try await Self.run(SQLTabRun.code(statement: "SELECT 1", connection: nil), connection: missing, target: LocalConnectionLaunch.snapshot(connection: missing, php: php, directory: folder))
        #expect(gone.errors.first?.message.contains("doesn't exist on this Mac") == true, "\(gone.errors)")

        // A driver this Mac's PHP lacks: what it has, and Runlet's PHP.
        let pgsql = DatabaseConnection(name: "Analytics", scope: nil, driver: .pgsql, host: "127.0.0.1", user: "reader")
        let code = "<?php try { \\RunletRunner\\SqlConnect::plan(['sqlite']); } catch (\\Throwable $e) { echo $e->getMessage(); }"
        let plan = try await Self.run(code, connection: pgsql, target: LocalConnectionLaunch.snapshot(connection: pgsql, php: php, directory: folder))
        #expect(plan.stdout.hasPrefix("This Mac's PHP "), "\(plan.stdout)")
        #expect(plan.stdout.contains("has no pdo_pgsql driver. It has: sqlite."), "\(plan.stdout)")
        #expect(plan.stdout.contains("Download Runlet's PHP in Settings ▸ PHP"), "\(plan.stdout)")

        var oracle = DatabaseConnection(name: "Oracle", scope: .ssh(UUID()), connectFrom: .thisMac, driver: .custom)
        oracle.dsn = "oci:dbname=//db.internal:1521/XE"
        let custom = try await Self.run(SQLTabRun.code(statement: "SELECT 1 FROM dual", connection: nil), connection: oracle, target: LocalConnectionLaunch.snapshot(connection: oracle, php: php, directory: folder))
        let message = custom.errors.first?.message ?? ""
        #expect(message.contains("This Mac's PHP") && message.contains("has no pdo_oci driver for the DSN") && message.contains("Runlet's PHP doesn't have it either"), "\(custom.errors)")

        // A target's connection keeps saying the target.
        let onTarget = DatabaseConnection(name: "Shop", scope: .local(UUID()), driver: .pgsql, host: "127.0.0.1")
        let directory = try SQLSavedConnectionTests.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let targetPlan = try await Self.run(code, connection: onTarget, target: DriverSupport.target(directory.path))
        #expect(targetPlan.stdout.hasPrefix("This target's PHP ") && !targetPlan.stdout.contains("Runlet's PHP"), "\(targetPlan.stdout)")
    }

    @Test(.enabled(if: TestSupport.runletPHP != nil, "set RUNLET_TEST_RUNLET_PHP to Runlet's PHP (bin/php of a scratch install)"))
    func runletsPHPHasTheDrivers() async throws {
        let (paths, root) = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try Self.database(in: root)
        let connection = DatabaseConnection(name: "Analytics", scope: nil, driver: .sqlite, database: file.path)
        let php = LocalConnectionLaunch.PHP(path: TestSupport.runletPHP!, label: "Runlet's PHP", isRunletPHP: true)
        let target = LocalConnectionLaunch.snapshot(connection: connection, php: php, directory: try LocalConnectionLaunch.directory(in: paths))
        let engine = try Self.engine(for: connection)
        let info = try await engine.testSQLConnection(target: target, connection: connection, password: .stored)
        withExtendedLifetime(engine) {}
        #expect(Set(info.pdoDrivers ?? []).isSuperset(of: ["mysql", "pgsql", "sqlite"]), "\(info.pdoDrivers ?? [])")
    }
}
