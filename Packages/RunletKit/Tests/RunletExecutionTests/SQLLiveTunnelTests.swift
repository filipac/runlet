import Darwin
import Foundation
@testable import RunletCore
import Testing
@testable import RunletExecution

/// Saved connections through an SSH profile's tunnel (#143), live: the SSH fixture
/// (`runlet-fixtures` service `ssh`, 127.0.0.1:2222, with this process's throwaway key and
/// config) forwards to MariaDB and PostgreSQL by their Compose service names (`mariadb:3306`,
/// `postgres:5432`), which this Mac can't resolve but the SSH server can. Each test opens its
/// own shared connection and closes it. Statements, Run All, Load Schema, Show Definition, Test
/// Connection, Stop's server cancel, PostgreSQL's verify-full against the server's name, the
/// forward listening only on 127.0.0.1 and gone after use, and a master that isn't open being
/// refused rather than opened. Tables are `p143_*`, created idempotently.
@Suite(.serialized, .enabled(if: TestSupport.hasPHP && SSHFixture.available, "requires host PHP, Docker, and OpenSSH"))
struct SQLLiveTunnelTests {
    typealias Server = SQLLiveDatabaseTests.Server
    static var servers: [Server] { SQLLiveDatabaseTests.servers }
    static let php = LocalConnectionLaunch.PHP(path: DriverSupport.php, label: "host PHP", isRunletPHP: false)
    static let profileId = UUID()

    /// The database as the SSH server sees it: its Compose service and container port.
    static func service(_ server: Server) -> (host: String, port: Int) {
        server.dialect == "mysql" ? ("mariadb", 3306) : ("postgres", 5432)
    }

    static func setup(_ server: Server) throws {
        let mysql = server.dialect == "mysql"
        for statement in [
            mysql
                ? "CREATE TABLE IF NOT EXISTS p143_orders (id INT PRIMARY KEY, status VARCHAR(20) NOT NULL, total DECIMAL(10,2)) ENGINE=InnoDB"
                : "CREATE TABLE IF NOT EXISTS p143_orders (id INT PRIMARY KEY, status VARCHAR(20) NOT NULL, total NUMERIC(10,2))",
            "DELETE FROM p143_orders",
            "INSERT INTO p143_orders (id, status, total) VALUES (1, 'paid', 10.50), (2, 'pending', 20), (3, 'paid', 7)",
        ] { _ = try server.exec(statement) }
    }

    /// The server as a saved connection through the tunnel, its password in memory.
    static func connection(_ server: Server, host: String? = nil) -> (DatabaseConnection, InMemoryCredentialStore) {
        var (connection, store) = SQLLiveDatabaseTests.saved(server)
        let address = service(server)
        connection.name = "Shop through bastion"
        connection.connectFrom = .sshTunnel
        connection.sshProfile = profileId
        connection.host = host ?? address.host
        connection.port = address.port
        return (connection.normalized, store)
    }

    /// A shared connection to the fixture (opened like Connect for an agent/key profile) and a
    /// tunnel manager on it; `close()` cancels its forwards and ends it.
    struct Bastion {
        var environment: SSHFixture.Environment
        var endpoint: SSHEndpoint
        var client: SSHClient
        var manager: SSHTunnelManager
        var root: URL
        var folder: URL

        static func open(idle: Duration = .seconds(60), connect: Bool = true) async throws -> Bastion {
            let environment = try await SSHFixture.environment()
            let endpoint = environment.endpoint(keepAliveMinutes: 2)
            let client = environment.client()
            if connect { try await client.openSharedConnection(endpoint) }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-p143-\(UUID().uuidString)", isDirectory: true)
            let folder = try LocalConnectionLaunch.directory(in: AppPaths(root: root))
            return Bastion(environment: environment, endpoint: endpoint, client: client, manager: SSHTunnelManager(forwarder: client, idleTimeout: idle), root: root, folder: folder)
        }

        func lease(_ connection: DatabaseConnection) async throws -> (SSHTunnelManager.Lease, TargetSnapshot) {
            let lease = try await manager.acquire(key: connection.id, endpoint: endpoint, remoteHost: connection.host, remotePort: connection.effectivePort ?? 0)
            let route = SQLTunnelRoute(localPort: lease.spec.localPort, remoteHost: connection.host, remotePort: connection.effectivePort ?? 0, profileId: SQLLiveTunnelTests.profileId, profileName: "bastion", forwardCommand: lease.commandLine, reused: lease.reused)
            return (lease, LocalConnectionLaunch.snapshot(connection: connection, php: SQLLiveTunnelTests.php, directory: folder, tunnel: route))
        }

        func close() async {
            await manager.cancelAll(reason: .quit)
            await client.disconnect(endpoint)
            try? FileManager.default.removeItem(at: root)
        }
    }

    static func run(_ code: String, _ connection: DatabaseConnection, store: InMemoryCredentialStore, target: TargetSnapshot) async throws -> [RunEvent] {
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil, credentials: store)
        var request = RunRequest(tabId: UUID(), documentVersion: 1, target: target, code: code, magicComments: false)
        request.sqlConnection = connection
        var events: [RunEvent] = []
        for await event in try await engine.start(request) { events.append(event) }
        return events
    }

    /// `lsof`'s listening sockets on `port`: "127.0.0.1:50123" per line, with the owning command.
    static func listeners(on port: Int) async throws -> [String] {
        let result = try await runCommand(ProcessSpec(executable: "/usr/sbin/lsof", arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fcn"]), timeout: .seconds(10))
        var command = ""
        var lines: [String] = []
        for line in String(decoding: result.stdout, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("c") { command = String(line.dropFirst()) }
            if line.hasPrefix("n") { lines.append("\(command) \(line.dropFirst())") }
        }
        return lines
    }

    /// This Mac can't resolve the Compose service names: only the SSH server can.
    static func resolvesHere(_ host: String) -> Bool {
        var result: UnsafeMutablePointer<addrinfo>?
        defer { if let result { freeaddrinfo(result) } }
        return getaddrinfo(host, nil, nil, &result) == 0
    }

    @Test(.enabled(if: !servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func everySQLActionThroughTheTunnel() async throws {
        let bastion = try await Bastion.open()
        for server in Self.servers {
            try Self.setup(server)
            let label = "\(server.dialect) through the tunnel"
            let (connection, store) = Self.connection(server)
            if Self.resolvesHere(connection.host) { Issue.record("\(connection.host) resolves on this Mac; the test can't show the tunnel is needed") }
            let (lease, target) = try await bastion.lease(connection)
            let port = lease.spec.localPort
            #expect(target.label == "Shop through bastion · this Mac (host PHP) through bastion")

            // The forward listens on 127.0.0.1 only, in the SSH master.
            let listening = try await Self.listeners(on: port)
            #expect(listening == ["ssh 127.0.0.1:\(port)"], "\(label): \(listening)")

            // Test Connection.
            let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil, credentials: store)
            let info = try await engine.testSQLConnection(target: target, connection: connection, password: .stored)
            #expect(info.driver == server.dialect && info.serverVersion != nil, "\(label): \(info)")

            // A statement with a bound value, and the schema on the first run.
            let select = try await Self.run(SQLTabRun.code(statement: "SELECT id, status FROM p143_orders WHERE status = :status ORDER BY id", connection: nil, schema: true, bindings: [SQLBinding(target: .name("status"), value: .text("paid"))]), connection, store: store, target: target)
            #expect(select.errors.isEmpty, "\(label): \(select.errors)")
            #expect(select.sqlResult?.rows.map { $0.first } == [.int(1), .int(3)], "\(label): \(select.sqlResult?.rows ?? [])")
            #expect(select.logEntries.contains { $0.source == "tunnel" && $0.message.contains("-O forward -L 127.0.0.1:\(port):\(connection.host):") }, "\(label): the Run Log names the forward")
            // (The fixture's SSH host alias, in the Run Log's forward line, happens to equal its
            // database password.)
            let texts = select.scannableText.map { $0.replacingOccurrences(of: "-- \(SSHFixture.Environment.keyHost)", with: "--") }
            #expect(!texts.contains { $0.contains(server.password) }, "\(label): the password appears in no event")

            // Run All in one transaction, Load Schema, Show Definition, Explain, and Load Next.
            let script = "UPDATE p143_orders SET total = total + 1 WHERE id = 2;\nSELECT total FROM p143_orders WHERE id = 2;"
            let statements = try SQLScript.statementsToRunAll(in: script, selection: NSRange(location: 0, length: 0)).get()
            let all = try await Self.run(SQLTabRun.scriptCode(statements: statements, connection: nil, transaction: true), connection, store: store, target: target)
            #expect(all.errors.isEmpty && all.sqlResults.first?.affectedRows == 1, "\(label): \(all.errors)")
            let schema = try await engine.loadSQLSchema(target: target, connection: nil, saved: connection)
            #expect(schema.table(named: "p143_orders")?.columns.map(\.name) == ["id", "status", "total"], "\(label)")
            let definition = try await engine.loadSQLDefinition(target: target, table: "p143_orders", connection: nil, saved: connection)
            #expect(definition.sql.contains("p143_orders"), "\(label): \(definition)")
            let explain = try await Self.run(SQLExplain.code(statement: "SELECT * FROM p143_orders WHERE id = 1", connection: nil, mode: .plan), connection, store: store, target: target)
            #expect(explain.errors.isEmpty && explain.sqlPlan != nil, "\(label): \(explain.errors)")
            let plan = try SQLPaging.plan(for: "SELECT id FROM p143_orders ORDER BY id", driver: server.dialect).get()
            let page = try await Self.run(SQLTabRun.pageCode(plan.page(offset: 1, size: 1), connection: nil), connection, store: store, target: target)
            #expect(page.sqlResult?.rows == [[.int(2)]], "\(label): \(page.errors)")

            // Released and unused: the forward is cancelled, nothing listens any more.
            await bastion.manager.release(lease, cancelWhenUnused: true)
            #expect(try await Self.listeners(on: port).isEmpty, "\(label)")
            #expect(!SSHForwardPorts.isListening(port))
            #expect(await bastion.manager.forwards.isEmpty)
        }
        await bastion.close()
    }

    @Test(.enabled(if: !servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func anIdleForwardIsCancelledAndAReusedOneKeepsItsPort() async throws {
        let bastion = try await Bastion.open(idle: .milliseconds(600))
        let server = Self.servers[0]
        let (connection, store) = Self.connection(server)
        let (first, target) = try await bastion.lease(connection)
        let one = try await Self.run(SQLTabRun.code(statement: "SELECT 1 AS one", connection: nil), connection, store: store, target: target)
        #expect(one.errors.isEmpty, "\(one.errors)")
        await bastion.manager.release(first)
        // Used again within the idle time: the same forward.
        let (second, _) = try await bastion.lease(connection)
        #expect(second.reused && second.spec == first.spec)
        await bastion.manager.release(second)
        #expect(try await Self.listeners(on: first.spec.localPort).count == 1, "still there while idle")
        try await Task.sleep(for: .milliseconds(1500))
        #expect(try await Self.listeners(on: first.spec.localPort).isEmpty, "cancelled after the idle time")
        #expect(SSHControlSocket.status(at: bastion.endpoint.controlPath) == .connected, "the master stays")
        await bastion.close()
    }

    @Test(.enabled(if: !servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func stopCancelsTheStatementThroughTheTunnel() async throws {
        let bastion = try await Bastion.open()
        for server in Self.servers {
            try SQLCancelLiveTests.setup(server)
            let (connection, store) = Self.connection(server)
            let (lease, target) = try await bastion.lease(connection)
            let marker = SQLCancelLiveTests.marker()
            var request = RunRequest(tabId: UUID(), documentVersion: 1, target: target, code: SQLTabRun.code(statement: SQLCancelLiveTests.sleep(server, marker: marker), connection: nil), magicComments: false)
            request.sqlConnection = connection
            let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil, credentials: store)
            let stopped = try await SQLCancelExecutionTests.runAndStop(request, engine: engine)
            let label = "\(server.dialect) through the tunnel"
            #expect(stopped.took < .seconds(5), "\(label): \(stopped.took)")
            let report = try #require(stopped.events.sqlCancel, "\(label): \(stopped.events.errors)")
            // The second runner went through the same forward: the server check saw the same server.
            #expect(report.outcome == .cancelled && report.verified == true, "\(label): \(report)")
            #expect(try await SQLCancelLiveTests.gone(server, marker: marker), "\(label): still running on the server")
            await bastion.manager.release(lease, cancelWhenUnused: true)
        }
        await bastion.close()
    }

    @Test(.enabled(if: SQLLiveDatabaseTests.pgsql != nil && ProcessInfo.processInfo.environment["RUNLET_TEST_TLS"] != nil, "set RUNLET_TEST_PGSQL and RUNLET_TEST_TLS"))
    func postgresVerifiesTheServersNameThroughTheTunnel() async throws {
        let server = try #require(SQLLiveDatabaseTests.pgsql)
        let ca = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RUNLET_TEST_TLS"]!).appendingPathComponent("ca.crt").path
        let bastion = try await Bastion.open()
        // The fixture's certificate names "postgres" (and 127.0.0.1); the container's address on
        // the Compose network reaches the same server but isn't in the certificate.
        let address = try await bastion.environment.exec("getent hosts postgres | cut -d' ' -f1").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!address.isEmpty && address != "127.0.0.1")
        for (host, matches) in [("postgres", true), (address, false)] {
            var (connection, store) = Self.connection(server, host: host)
            connection.tls = DatabaseTLS(mode: .verifyFull, caFile: ca)
            let (lease, target) = try await bastion.lease(connection)
            let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil, credentials: store)
            if matches {
                let info = try await engine.testSQLConnection(target: target, connection: connection, password: .stored)
                #expect(info.tls == true, "\(info)")
            } else {
                await #expect {
                    _ = try await engine.testSQLConnection(target: target, connection: connection, password: .stored)
                } throws: { error in
                    "\(error)".contains("does not match host name \"\(address)\"")
                }
            }
            await bastion.manager.release(lease, cancelWhenUnused: true)
        }
        await bastion.close()
    }

    /// Run History and SQL snippets (#149): an entry and a snippet recorded from a tunnelled
    /// connection, stored and read back, resolve to that same connection on the tab's target,
    /// and running the restored statement goes through the tunnel again.
    @Test(.enabled(if: !servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func aStatementFromHistoryOrASnippetRunsThroughTheTunnelAgain() async throws {
        let server = Self.servers[0]
        try Self.setup(server)
        let bastion = try await Bastion.open()
        var library = TargetLibrary()
        library.sshProfiles = [SSHProfile(id: Self.profileId, name: "bastion", host: SSHFixture.Environment.keyHost, remoteDirectory: "/")]
        let (connection, store) = Self.connection(server)
        let saved = library.saveDatabaseConnection(connection)
        let target = try #require(saved.scope)
        let code = "SELECT id FROM p143_orders ORDER BY id"
        // Recorded as the app records them, then stored and read back.
        let entry = HistoryEntry(runId: UUID(), code: code, target: target, targetLabel: "Shop", status: .completed, reason: "completed", elapsedMs: 3, language: .sql, connection: SQLConnectionReference(saved))
        let snippet = Snippet(label: "Orders", code: code, target: target, language: .sql, connection: SQLConnectionReference(saved).forSnippet)
        let restoredEntry = try JSONDecoder().decode(HistoryEntry.self, from: JSONEncoder().encode(entry))
        let restoredSnippet = try JSONDecoder().decode(Snippet.self, from: JSONEncoder().encode(snippet))
        var ports: [Int] = []
        for (label, restored, reference) in [("history", restoredEntry.code, restoredEntry.connection), ("snippet", restoredSnippet.code, restoredSnippet.connection)] {
            let resolution = library.resolve(try #require(reference, "\(label)"), on: target)
            guard case .saved(let found) = resolution else {
                Issue.record("\(label): \(resolution)")
                continue
            }
            #expect(found == saved && found.usesSSHTunnel && found.sshProfile == Self.profileId, "\(label)")
            let (lease, snapshot) = try await bastion.lease(found)
            ports.append(lease.spec.localPort)
            let events = try await Self.run(SQLTabRun.code(statement: restored, connection: nil), found, store: store, target: snapshot)
            #expect(events.errors.isEmpty, "\(label): \(events.errors)")
            #expect(events.sqlResult?.rows == [[.int(1)], [.int(2)], [.int(3)]], "\(label): \(events.sqlResult?.rows ?? [])")
            #expect(events.logEntries.contains { $0.source == "tunnel" }, "\(label): through the tunnel")
            await bastion.manager.release(lease)
        }
        #expect(ports.count == 2 && ports[0] == ports[1], "the second run reuses the forward")
        await bastion.close()
    }

    @Test func aMasterThatIsntOpenIsNeverOpenedByTheTunnel() async throws {
        let bastion = try await Bastion.open(connect: false)
        let connection = DatabaseConnection(name: "Shop", scope: nil, connectFrom: .sshTunnel, driver: .pgsql, host: "postgres", sshProfile: Self.profileId)
        await #expect(throws: SSHTunnelError.self) { _ = try await bastion.lease(connection) }
        #expect(SSHControlSocket.status(at: bastion.endpoint.controlPath) == .disconnected, "the tunnel never logs in by itself")
        await bastion.close()
    }
}
