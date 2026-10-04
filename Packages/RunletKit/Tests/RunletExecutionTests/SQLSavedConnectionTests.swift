import Foundation
import RunletCore
import Testing
@testable import RunletExecution

extension Array where Element == RunEvent {
    /// Each event as text, for scanning a run for a secret: printed output as written, every
    /// other event with all of its fields.
    var scannableText: [String] {
        map { event in
            switch event.kind {
            case .stdout(let data), .stderr(let data): String(decoding: data, as: UTF8.self)
            default: String(reflecting: event.kind)
            }
        }
    }
}

/// Saved database connections (#138) through the runner, with host PHP and SQLite: a
/// statement, Run All, the schema, Test Connection, that no project code runs, and that the
/// password appears in no event of a run, on success or failure.
@Suite(.serialized, .enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct SQLSavedConnectionTests {
    static let password = "fixture-secret-Pw9"
    static let target = TargetRef.local(UUID())

    /// The forms a leak could take.
    static func leaks(_ text: String, password: String = SQLSavedConnectionTests.password) -> Bool {
        [password, password.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? password].contains { text.contains($0) }
    }

    /// A project folder with an SQLite database (`data/shop.sqlite`: customers and orders) and a
    /// project driver whose file and bootstrap leave markers, to prove no project code ran.
    static func project() throws -> URL {
        let directory = try DriverSupport.composerProject(drivers: ["MarkerDriver.php": """
        <?php
        file_put_contents(__DIR__ . '/../loaded.marker', 'driver file loaded');
        class MarkerDriver extends \\Runlet\\Driver
        {
            public function canBootstrap(string $projectPath): bool
            {
                file_put_contents($projectPath . '/can-bootstrap.marker', 'x');
                return true;
            }

            public function bootstrap(string $projectPath): void
            {
                file_put_contents($projectPath . '/bootstrap.marker', 'x');
            }
        }
        """])
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("data"), withIntermediateDirectories: true)
        let php = Process()
        php.executableURL = URL(fileURLWithPath: DriverSupport.php)
        php.arguments = ["-r", """
            $p = new PDO('sqlite:' . $argv[1]);
            $p->exec("CREATE TABLE customers (id INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE)");
            $p->exec("CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER NOT NULL REFERENCES customers(id), total REAL)");
            $p->exec("INSERT INTO customers (email) VALUES ('a@example.test'), ('b@example.test')");
            $p->exec("INSERT INTO orders (customer_id, total) VALUES (1, 9.5), (2, 20)");
            """, directory.appendingPathComponent("data/shop.sqlite").path]
        try php.run()
        php.waitUntilExit()
        return directory
    }

    static func markers(in directory: URL) -> [String] {
        ["loaded.marker", "can-bootstrap.marker", "bootstrap.marker"].filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    static func connection(_ path: String = "data/shop.sqlite", name: String = "Reporting") -> DatabaseConnection {
        DatabaseConnection(name: name, scope: target, driver: .sqlite, database: path)
    }

    static func engine(password: String? = SQLSavedConnectionTests.password, for connection: DatabaseConnection) throws -> (ExecutionEngine, InMemoryCredentialStore) {
        let store = InMemoryCredentialStore()
        if let password { try store.set(SensitiveString(password), for: connection.id, label: "Runlet database: \(connection.name)") }
        return (ExecutionEngine(bundle: TestSupport.bundle, docker: nil, credentials: store), store)
    }

    static func run(_ code: String, connection: DatabaseConnection, in directory: URL, php: String? = nil, password: String? = SQLSavedConnectionTests.password) async throws -> [RunEvent] {
        let (engine, _) = try engine(password: password, for: connection)
        var request = RunRequest(tabId: UUID(), documentVersion: 1, target: DriverSupport.target(directory.path, php: php), code: code, inspector: RunInspectorOptions(), magicComments: false)
        request.sqlConnection = connection
        var events: [RunEvent] = []
        for await event in try await engine.start(request) { events.append(event) }
        return events
    }

    @Test func statementRunAllAndSchemaWithoutProjectCode() async throws {
        let directory = try Self.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = Self.connection()

        let select = try await Self.run(SQLTabRun.code(statement: "SELECT id, email FROM customers ORDER BY id", connection: nil, schema: true), connection: connection, in: directory)
        #expect(select.errors.isEmpty, "\(select.errors)")
        let rows = try #require(select.sqlResult)
        #expect(rows.rows == [[.int(1), .string("a@example.test")], [.int(2), .string("b@example.test")]])
        #expect(rows.saved == true)
        #expect(rows.connection == "Reporting")
        #expect(rows.driver == "sqlite")
        #expect(rows.source == #"saved connection "Reporting" (sqlite, data/shop.sqlite)"#)
        #expect(rows.connections == nil, "a saved connection lists no application connections")
        #expect(rows.originText.contains("via saved connection"))
        let schema = try #require(select.sqlSchema)
        #expect(Set(schema.tables.map(\.name)) == ["customers", "orders"])
        #expect(schema.table(named: "orders")?.columns.first { $0.name == "customer_id" }?.references != nil)

        // The project's driver never loaded; the run booted plain PHP and asked to remember nothing.
        #expect(Self.markers(in: directory).isEmpty)
        #expect(select.bootstrapped?.framework == "plain")
        #expect(!select.contains { if case .remember = $0.kind { return true } else { return false } })
        #expect(!select.contains { if case .inspector = $0.kind { return true } else { return false } })

        let script = "INSERT INTO customers (email) VALUES ('c@example.test');\nUPDATE orders SET total = total + 1;\nSELECT COUNT(*) AS n FROM customers;"
        let statements = try SQLScript.statementsToRunAll(in: script, selection: NSRange(location: 0, length: 0)).get()
        let all = try await Self.run(SQLTabRun.scriptCode(statements: statements, connection: nil, transaction: true), connection: connection, in: directory)
        #expect(all.errors.isEmpty, "\(all.errors)")
        #expect(all.sqlResults.map(\.affectedRows) == [1, 2, nil])
        #expect(all.sqlResults.last?.rows == [[.int(3)]])
        #expect(all.sqlResults.allSatisfy { $0.saved == true && $0.connection == "Reporting" })

        let (engine, _) = try Self.engine(for: connection)
        let loaded = try await engine.loadSQLSchema(target: DriverSupport.target(directory.path), connection: "ignored", saved: connection)
        #expect(loaded.tables.count == 2)
        #expect(Self.markers(in: directory).isEmpty)

        // The same project, run the usual way, does load its driver (the markers mean something).
        _ = try await TestSupport.run("1", target: DriverSupport.target(directory.path))
        #expect(Self.markers(in: directory) == ["loaded.marker", "can-bootstrap.marker", "bootstrap.marker"])
    }

    @Test func thePasswordAppearsInNoEvent() async throws {
        let directory = try Self.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = Self.connection()
        var runs: [[RunEvent]] = []
        // Success, with the password echoed by the database (scrubbed), and failures.
        runs.append(try await Self.run(SQLTabRun.code(statement: "SELECT '\(Self.password)' AS echoed, 'x\(Self.password)y' AS inside", connection: nil), connection: connection, in: directory))
        runs.append(try await Self.run(SQLTabRun.code(statement: "SELECT * FROM missing_\(Self.password.replacingOccurrences(of: "-", with: "_"))", connection: nil), connection: connection, in: directory))
        runs.append(try await Self.run(SQLTabRun.code(statement: "SELECT 1", connection: nil), connection: Self.connection("data/missing-\(Self.password).sqlite"), in: directory))
        runs.append(try await Self.run(SQLTabRun.testCode, connection: connection, in: directory))
        let mysqlDown = DatabaseConnection(name: "Down", scope: Self.target, driver: .mysql, host: "127.0.0.1", port: 1, database: "x", user: "u", connectTimeout: 2)
        runs.append(try await Self.run(SQLTabRun.code(statement: "SELECT 1", connection: nil), connection: mysqlDown, in: directory))

        // The scan sees every field of an event.
        #expect(Self.leaks(String(reflecting: RunEvent.Kind.error(RunErrorInfo(stage: .execute, message: "x \(Self.password)")))))
        let echoed = try #require(runs[0].sqlResult)
        #expect(echoed.rows == [[.string("•••"), .string("x•••y")]])
        #expect(runs[1].errors.isEmpty == false)
        #expect(runs[2].errors.first?.message.contains("doesn't exist on this target") == true, "\(runs[2].errors)")
        #expect(runs[4].errors.first?.message.contains("Runlet could not open the saved connection \"Down\" (mysql, 127.0.0.1:1/x)") == true, "\(runs[4].errors)")
        for (index, events) in runs.enumerated() {
            #expect(events.finished != nil)
            for text in events.scannableText {
                #expect(!Self.leaks(text), "run \(index): \(text)")
            }
            // The Run Log's launch line: the command and the script's size only.
            for event in events {
                if case .log(let entry) = event.kind, entry.source == "launch" { #expect(entry.detail?.contains("bytes on stdin") == true) }
            }
        }
    }

    @Test func aShortPasswordIsScrubbedFromMessagesButNotFromRows() async throws {
        let directory = try Self.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = try await Self.run(SQLTabRun.code(statement: "SELECT 'abc' AS v", connection: nil), connection: Self.connection(), in: directory, password: "ab")
        #expect(events.sqlResult?.rows == [[.string("abc")]])
    }

    @Test func testConnectionReportsTheServer() async throws {
        let directory = try Self.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = Self.connection()
        let (engine, _) = try Self.engine(for: connection)
        let info = try await engine.testSQLConnection(target: DriverSupport.target(directory.path), connection: connection, password: .stored)
        #expect(info.driver == "sqlite")
        #expect(info.serverVersion?.hasPrefix("3.") == true)
        #expect(info.database?.hasSuffix("data/shop.sqlite") == true)
        #expect(info.roundTripMs != nil && info.phpVersion != nil)
        #expect(Self.markers(in: directory).isEmpty)

        // A password typed in the editor and not saved yet.
        let typed = try await engine.testSQLConnection(target: DriverSupport.target(directory.path), connection: connection, password: .given(SensitiveString("typed")))
        #expect(typed.driver == "sqlite")

        await #expect(throws: SQLConnectionTestError.self) {
            try await engine.testSQLConnection(target: DriverSupport.target(directory.path), connection: Self.connection("nope.sqlite"), password: .stored)
        }
    }

    @Test func anUnreadableKeychainStopsBeforePHPStarts() async throws {
        struct Denied: CredentialStore {
            func set(_ secret: SensitiveString, for account: UUID, label: String) throws {}
            func read(_ account: UUID) throws -> SensitiveString? { throw CredentialStoreError(status: -128, "Runlet couldn't read the password from the Keychain: Deny was chosen.") }
            func delete(_ account: UUID) throws {}
            func exists(_ account: UUID) -> Bool { true }
        }
        let directory = try Self.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil, credentials: Denied())
        var request = RunRequest(tabId: UUID(), documentVersion: 1, target: DriverSupport.target(directory.path), code: SQLTabRun.code(statement: "SELECT 1", connection: nil), magicComments: false)
        request.sqlConnection = Self.connection()
        var events: [RunEvent] = []
        for await event in try await engine.start(request) { events.append(event) }
        #expect(events.started == nil)
        #expect(events.errors.first?.stage == .launch)
        #expect(events.errors.first?.message.contains("The password of the saved connection “Reporting” couldn't be read") == true, "\(events.errors)")
        #expect(events.finished?.reason == "launch-failed")
    }

    @Test(.enabled(if: TestSupport.herdPHP74 != nil, "requires Herd's PHP 7.4"))
    func runsOnPHP74() async throws {
        let directory = try Self.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = try await Self.run(SQLTabRun.code(statement: "SELECT email FROM customers WHERE id = 2", connection: nil, schema: true), connection: Self.connection(), in: directory, php: TestSupport.herdPHP74)
        #expect(events.started?.phpVersion?.hasPrefix("7.4") == true)
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.sqlResult?.rows == [[.string("b@example.test")]])
        #expect(events.sqlSchema?.tables.count == 2)
        let failed = try await Self.run(SQLTabRun.code(statement: "SELECT 1", connection: nil), connection: DatabaseConnection(name: "Down", scope: Self.target, driver: .pgsql, host: "127.0.0.1", port: 1, user: "u", connectTimeout: 2), in: directory, php: TestSupport.herdPHP74)
        #expect(failed.errors.first?.message.contains("Runlet could not open the saved connection") == true, "\(failed.errors)")
        for text in failed.scannableText { #expect(!Self.leaks(text), "\(text)") }
    }
}

/// Saved connections inside the Docker fixtures (#138): `php:*-cli` images have pdo_sqlite but
/// no pdo_mysql or pdo_pgsql, which tests the missing-driver message.
@Suite(.serialized, .live(.docker), .enabled(if: TestSupport.hasDocker, "requires a running Docker engine"))
struct SQLSavedConnectionDockerTests {
    func container(_ service: String) async throws -> ContainerInfo {
        let containers = try await TestSupport.docker!.runningContainers()
        return try #require(containers.first { $0.composeProject == "runlet-fixtures" && $0.composeService == service }, "start fixtures with scripts/setup-fixtures.sh docker")
    }

    func target(_ container: ContainerInfo, _ directory: String) -> TargetSnapshot {
        TargetSnapshot(kind: .docker, label: container.name, targetId: container.id, workingDirectory: directory, phpExecutable: "php", containerId: container.id, containerName: container.name, image: container.image, temporaryDirectory: "/tmp")
    }

    @Test func memorySQLiteRunsAndAMissingDriverIsNamed() async throws {
        let store = InMemoryCredentialStore()
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: TestSupport.docker, credentials: store)
        for (service, directory) in [("custom", "/var/www"), ("restricted", "/app")] {
            let target = target(try await container(service), directory)
            let memory = DatabaseConnection(name: "Scratch", scope: .docker(UUID()), driver: .sqlite, database: ":memory:")
            var request = RunRequest(tabId: UUID(), documentVersion: 1, target: target, code: SQLTabRun.code(statement: "SELECT sqlite_version() AS v", connection: nil), magicComments: false)
            request.sqlConnection = memory
            var events: [RunEvent] = []
            for await event in try await engine.start(request) { events.append(event) }
            #expect(events.errors.isEmpty, "\(service): \(events.errors)")
            #expect(events.sqlResult?.saved == true, "\(service)")

            let postgres = DatabaseConnection(name: "Postgres", scope: .docker(UUID()), driver: .pgsql, host: "postgres", database: "shop", user: "postgres")
            try store.set(SensitiveString(SQLSavedConnectionTests.password), for: postgres.id, label: "Runlet database: Postgres")
            await #expect(throws: SQLConnectionTestError.self) {
                try await engine.testSQLConnection(target: target, connection: postgres, password: .stored)
            }
            do {
                _ = try await engine.testSQLConnection(target: target, connection: postgres, password: .stored)
            } catch {
                let message = "\(error)"
                #expect(message.contains("has no pdo_pgsql driver. It has: "), "\(service): \(message)")
                #expect(message.contains("sqlite"), "\(service): \(message)")
                #expect(!SQLSavedConnectionTests.leaks(message))
            }
        }
    }
}

/// A saved connection opened on the SSH fixture's server (#138), with Keep compiled PHP on:
/// the request (and its password) comes from stdin, which the opcode file cache never stores.
@Suite(.serialized, .live(.ssh, exclusive: true), .enabled(if: SSHFixture.available, "requires Docker and /usr/bin/ssh"))
struct SQLSavedConnectionSSHTests {
    @Test func runsOnTheServerAndLeavesNothingInTheOpcodeCache() async throws {
        let environment = try await SSHFixture.environment()
        let endpoint: SSHEndpoint = {
            var endpoint = environment.endpoint()
            endpoint.keepCompiledPHP = true
            return endpoint
        }()
        let client = environment.client()
        defer { Task { await client.disconnect(endpoint) } }
        let target = environment.target(endpoint)
        _ = try await environment.exec("mkdir -p /home/runlet/.cache && chown runlet:runlet /home/runlet/.cache")
        defer { Task { _ = try? await environment.exec("rm -rf /home/runlet/.cache") } }

        let store = InMemoryCredentialStore()
        let connection = DatabaseConnection(name: "Scratch", scope: .ssh(UUID()), driver: .sqlite, database: ":memory:")
        try store.set(SensitiveString(SQLSavedConnectionTests.password), for: connection.id, label: "Runlet database: Scratch")
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil, ssh: environment.client(), credentials: store)
        var request = RunRequest(tabId: UUID(), documentVersion: 1, target: target, code: SQLTabRun.code(statement: "SELECT sqlite_version() AS v", connection: nil), magicComments: false)
        request.sqlConnection = connection
        var events: [RunEvent] = []
        for await event in try await engine.start(request) { events.append(event) }
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.sqlResult?.saved == true)
        #expect(events.bootstrapped?.framework == "plain")
        for text in events.scannableText { #expect(!SQLSavedConnectionTests.leaks(text), "\(text)") }

        // The server's PHP has no pdo_pgsql: Test Connection names the drivers it has.
        let postgres = DatabaseConnection(name: "Postgres", scope: connection.scope, driver: .pgsql, host: "postgres", user: "postgres")
        do {
            _ = try await engine.testSQLConnection(target: target, connection: postgres, password: .given(SensitiveString(SQLSavedConnectionTests.password)))
            Issue.record("the fixture's PHP unexpectedly has pdo_pgsql")
        } catch {
            #expect("\(error)".contains("has no pdo_pgsql driver. It has:"), "\(error)")
        }

        let found = try await environment.exec("grep -rl -- \"$1\" /home/runlet/.cache 2>/dev/null || true", arguments: [SQLSavedConnectionTests.password])
        #expect(found.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(found)")
    }
}
