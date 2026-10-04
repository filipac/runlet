import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// The SSH tunnel of saved connections (#143) without a server: the `ssh -O forward` and
/// `-O cancel` command lines, port picking, the forward lifecycle (in use, idle, cancelled,
/// a taken port retried) with a fake master, and what the runner and the engine do with a
/// tunnel (the DSN each driver gets; no tunnel, no connection).
@Suite(.serialized)
struct SSHTunnelTests {
    static let endpoint = SSHEndpoint(host: "bastion", user: "deploy", port: 2222, controlPath: "/tmp/rlt-test/abcd1234.sock")

    @Test func forwardSpecAndCommandLines() {
        let spec = SSHForwardSpec(localPort: 50123, remoteHost: "postgres", remotePort: 5432)
        #expect(spec.argument == "127.0.0.1:50123:postgres:5432")
        #expect(SSHForwardSpec(localPort: 50124, remoteHost: "fd00::5", remotePort: 3306).argument == "127.0.0.1:50124:[fd00::5]:3306")
        #expect(SSHForwardSpec(localPort: 50125, remoteHost: "[fd00::5]", remotePort: 3306).argument == "127.0.0.1:50125:[fd00::5]:3306")

        let client = SSHClient(environment: [:], configFile: "/tmp/should-not-be-read")
        let add = client.forwardArguments(for: Self.endpoint, spec: spec, cancel: false)
        #expect(add == ["-F", "/dev/null", "-o", "BatchMode=yes", "-o", "LogLevel=ERROR", "-S", "/tmp/rlt-test/abcd1234.sock", "-O", "forward", "-L", "127.0.0.1:50123:postgres:5432", "--", "bastion"])
        let cancel = client.forwardArguments(for: Self.endpoint, spec: spec, cancel: true)
        #expect(cancel.contains("cancel") && !cancel.contains("forward"))
        #expect(!add.contains("/tmp/should-not-be-read"), "the master's -O commands read no ssh config")
        #expect(client.forwardCommandLine(spec, on: Self.endpoint, cancel: false) == "/usr/bin/ssh -F /dev/null -o BatchMode=yes -o LogLevel=ERROR -S /tmp/rlt-test/abcd1234.sock -O forward -L 127.0.0.1:50123:postgres:5432 -- bastion")
        // Runs keep clearing forwards; only the master's -O forward adds one.
        #expect(client.arguments(for: Self.endpoint, purpose: .batch).contains("ClearAllForwardings=yes"))
    }

    @Test func freePortsAreLoopbackPortsNothingListensOn() throws {
        let port = try SSHForwardPorts.pickFree()
        #expect((1024...65535).contains(port))
        #expect(!SSHForwardPorts.isListening(port))
    }

    @Test func aForwardIsReusedWhileInUseAndCancelledWhenIdle() async throws {
        let master = FakeMaster()
        let events = EventLog()
        let manager = SSHTunnelManager(forwarder: master, idleTimeout: .milliseconds(150), pickPort: master.nextPort, observer: events.record)
        let key = UUID()

        let first = try await manager.acquire(key: key, endpoint: Self.endpoint, remoteHost: "postgres", remotePort: 5432)
        #expect(!first.reused && first.spec.localPort == 41001)
        let second = try await manager.acquire(key: key, endpoint: Self.endpoint, remoteHost: "postgres", remotePort: 5432)
        #expect(second.reused && second.spec == first.spec, "one forward per connection")
        #expect(master.added.count == 2, "every acquire re-sends -O forward (idempotent on the master)")
        #expect(await manager.forwards.first?.leases == 2)

        await manager.release(first)
        await manager.release(second)
        #expect(await manager.forwards.first?.idle == true)
        // A new lease within the idle time stops the timer.
        let third = try await manager.acquire(key: key, endpoint: Self.endpoint, remoteHost: "postgres", remotePort: 5432)
        try await Task.sleep(for: .milliseconds(250))
        #expect(master.cancelled.isEmpty, "in use: never cancelled")
        await manager.release(third)
        try await Task.sleep(for: .milliseconds(400))
        #expect(master.cancelled == [first.spec])
        #expect(await manager.forwards.isEmpty)
        #expect(events.reasons == [.idle])
    }

    @Test func closingTheTabCancelsOnceTheLastRunEnds() async throws {
        let master = FakeMaster()
        let events = EventLog()
        let manager = SSHTunnelManager(forwarder: master, idleTimeout: .seconds(60), pickPort: master.nextPort, observer: events.record)
        let key = UUID()
        let lease = try await manager.acquire(key: key, endpoint: Self.endpoint, remoteHost: "mariadb", remotePort: 3306)
        await manager.cancel(key: key, reason: .tabClosed)
        #expect(master.cancelled.isEmpty, "a run still uses it")
        await manager.release(lease)
        #expect(master.cancelled == [lease.spec])
        #expect(events.reasons == [.tabClosed])

        // Test Connection releases with cancelWhenUnused.
        let test = try await manager.acquire(key: UUID(), endpoint: Self.endpoint, remoteHost: "mariadb", remotePort: 3306)
        await manager.release(test, cancelWhenUnused: true)
        #expect(master.cancelled.last == test.spec)
    }

    /// What a connection manager (#180) lists and closes: open and last-used times, holds, and
    /// a close that waits for runs, or doesn't (`force`).
    @Test func forwardsAreListedAndCanBeClosedByHand() async throws {
        let master = FakeMaster()
        let events = EventLog()
        let manager = SSHTunnelManager(forwarder: master, idleTimeout: .seconds(60), pickPort: master.nextPort, observer: events.record)
        let key = UUID()
        let before = Date()
        let lease = try await manager.acquire(key: key, endpoint: Self.endpoint, remoteHost: "postgres", remotePort: 5432)
        let listed = try #require(await manager.forwards.first)
        #expect(listed.key == key && listed.leases == 1 && !listed.idle && listed.openedAt >= before && listed.lastUsedAt >= listed.openedAt)
        await manager.cancel(key: key, reason: .closed)
        let waiting = await manager.forwards.first?.cancelWhenUnused
        #expect(master.cancelled.isEmpty && waiting == true, "waits for the run")
        await manager.cancel(key: key, reason: .closed, force: true)
        let remaining = await manager.forwards
        #expect(master.cancelled == [lease.spec] && remaining.isEmpty)
        #expect(events.reasons == [.closed])
        await manager.release(lease) // the run's late release changes nothing
        #expect(master.cancelled.count == 1)
    }

    @Test func disconnectAndQuitCancelEverythingOnTheirMaster() async throws {
        let master = FakeMaster()
        let manager = SSHTunnelManager(forwarder: master, idleTimeout: .seconds(60), pickPort: master.nextPort)
        var other = Self.endpoint
        other.controlPath = "/tmp/rlt-test/other.sock"
        let a = try await manager.acquire(key: UUID(), endpoint: Self.endpoint, remoteHost: "postgres", remotePort: 5432)
        let b = try await manager.acquire(key: UUID(), endpoint: other, remoteHost: "postgres", remotePort: 5432)
        await manager.cancelAll(controlPath: Self.endpoint.controlPath, reason: .disconnected)
        #expect(master.cancelled == [a.spec])
        #expect(await manager.forwards.map(\.spec) == [b.spec])
        await manager.release(a) // a lease of a cancelled forward is ignored
        await manager.drop(controlPath: other.controlPath)
        #expect(await manager.forwards.isEmpty && master.cancelled == [a.spec], "a gone master has nothing to cancel")

        let c = try await manager.acquire(key: UUID(), endpoint: Self.endpoint, remoteHost: "postgres", remotePort: 5432)
        await manager.cancelAll(reason: .quit)
        #expect(master.cancelled.last == c.spec)
    }

    @Test func aTakenPortIsRetriedAndAChangedConnectionReplacesItsForward() async throws {
        let master = FakeMaster()
        master.takenPorts = [41001, 41002]
        let manager = SSHTunnelManager(forwarder: master, idleTimeout: .seconds(60), pickPort: master.nextPort)
        let key = UUID()
        let lease = try await manager.acquire(key: key, endpoint: Self.endpoint, remoteHost: "postgres", remotePort: 5432)
        #expect(lease.spec.localPort == 41003)

        // The connection now points elsewhere: the old forward goes, a new one comes.
        let moved = try await manager.acquire(key: key, endpoint: Self.endpoint, remoteHost: "postgres", remotePort: 6432)
        #expect(master.cancelled == [lease.spec] && moved.spec.remotePort == 6432 && !moved.reused)

        master.takenPorts = Set(41000...41100)
        await #expect(throws: SSHTunnelError.self) {
            _ = try await manager.acquire(key: UUID(), endpoint: Self.endpoint, remoteHost: "postgres", remotePort: 5432)
        }
    }

    @Test func aMissingMasterIsReportedAndForgotten() async throws {
        let master = FakeMaster()
        let manager = SSHTunnelManager(forwarder: master, idleTimeout: .seconds(60), pickPort: master.nextPort)
        let key = UUID()
        let lease = try await manager.acquire(key: key, endpoint: Self.endpoint, remoteHost: "postgres", remotePort: 5432)
        await manager.release(lease)
        master.connected = false
        await #expect(throws: SSHTunnelError.notConnected("deploy@bastion:2222")) {
            _ = try await manager.acquire(key: key, endpoint: Self.endpoint, remoteHost: "postgres", remotePort: 5432)
        }
        #expect(await manager.forwards.isEmpty)
        #expect(SSHTunnelError.notConnected("bastion").description.contains("Nothing ran"))
    }

    @Test func concurrentRunsShareOneForward() async throws {
        let master = FakeMaster()
        master.delay = .milliseconds(50)
        let manager = SSHTunnelManager(forwarder: master, idleTimeout: .seconds(60), pickPort: master.nextPort)
        let key = UUID()
        let leases = try await withThrowingTaskGroup(of: SSHTunnelManager.Lease.self) { group in
            for _ in 0..<4 { group.addTask { try await manager.acquire(key: key, endpoint: Self.endpoint, remoteHost: "postgres", remotePort: 5432) } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(Set(leases.map(\.spec)).count == 1)
        #expect(leases.filter { !$0.reused }.count == 1)
    }

    // MARK: Runner and engine

    static func tunnelled(_ driver: DatabaseDriverKind, host: String = "postgres") -> DatabaseConnection {
        DatabaseConnection(name: "Shop", scope: .local(UUID()), connectFrom: .sshTunnel, driver: driver, host: host, database: "shop", user: "reader", sshProfile: UUID())
    }

    static func route(port: Int = 50123) -> SQLTunnelRoute {
        SQLTunnelRoute(localPort: port, remoteHost: "postgres", remotePort: 5432, profileId: UUID(), profileName: "bastion", forwardCommand: "ssh -O forward -L 127.0.0.1:\(port):postgres:5432")
    }

    @Test(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
    func theRunnerConnectsToTheTunnel() async throws {
        let (paths, root) = try LocalConnectionLaunchTests.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try LocalConnectionLaunch.directory(in: paths)
        let php = LocalConnectionLaunch.PHP(path: DriverSupport.php, label: "PHP (host)", isRunletPHP: false)
        let code = "<?php try { echo json_encode(\\RunletRunner\\SqlConnect::plan(['mysql', 'pgsql', 'sqlsrv'])); } catch (\\Throwable $e) { echo 'ERR ', $e->getMessage(); }"
        func plan(_ connection: DatabaseConnection) async throws -> String {
            let target = LocalConnectionLaunch.snapshot(connection: connection, php: php, directory: folder, tunnel: Self.route())
            #expect(target.label.hasSuffix(" through bastion"))
            let events = try await LocalConnectionLaunchTests.run(code, connection: connection, target: target)
            let log = events.compactMap { if case .log(let entry) = $0.kind { return entry } else { return nil } }
            #expect(log.contains { $0.source == "tunnel" && $0.message.contains("127.0.0.1:50123:postgres:5432") }, "the Run Log names the forward")
            #expect(!events.scannableText.contains { $0.contains(LocalConnectionLaunchTests.password) })
            return events.stdout
        }

        // PostgreSQL keeps the server's name as host (TLS verify-full) and connects to hostaddr.
        var pgsql = Self.tunnelled(.pgsql)
        pgsql.tls = DatabaseTLS(mode: .verifyFull)
        let pg = try await plan(pgsql)
        #expect(pg.contains(#""dsn":"pgsql:host=postgres;hostaddr=127.0.0.1;port=50123;dbname='shop';sslmode=verify-full""#), "\(pg)")
        // MySQL and SQL Server connect to 127.0.0.1.
        let my = try await plan(Self.tunnelled(.mysql, host: "mariadb"))
        #expect(my.contains(#""dsn":"mysql:host=127.0.0.1;port=50123;dbname=shop;charset=utf8mb4""#), "\(my)")
        let ms = try await plan(Self.tunnelled(.sqlsrv, host: "mssql"))
        #expect(ms.contains("sqlsrv:Server=127.0.0.1,50123;Database=shop"), "\(ms)")

        // An option that would send libpq elsewhere is refused by the runner too.
        var hostaddr = Self.tunnelled(.pgsql)
        hostaddr.options = [DatabaseOption(key: "hostaddr", value: "10.0.0.5")]
        let refused = try await plan(hostaddr)
        #expect(refused.hasPrefix("ERR ") && refused.contains("set by the tunnel"), "\(refused)")
    }

    @Test(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
    func noTunnelNoConnection() async throws {
        let (paths, root) = try LocalConnectionLaunchTests.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try LocalConnectionLaunch.directory(in: paths)
        let php = LocalConnectionLaunch.PHP(path: DriverSupport.php, label: "PHP (host)", isRunletPHP: false)
        let connection = Self.tunnelled(.pgsql)
        // A this-Mac snapshot without the forward: refused before PHP starts, so the password
        // never goes to a "postgres" this Mac might resolve.
        let engine = try LocalConnectionLaunchTests.engine(for: connection)
        var request = RunRequest(tabId: UUID(), documentVersion: 1, target: LocalConnectionLaunch.snapshot(connection: connection, php: php, directory: folder), code: "<?php echo 1;", magicComments: false)
        request.sqlConnection = connection
        await #expect(throws: ExecutionError.self) { _ = try await engine.start(request) }
        await #expect(throws: (any Error).self) {
            _ = try await engine.testSQLConnection(target: request.target, connection: connection, password: .stored)
        }
    }
}

/// A shared connection that records forwards (ports 41001, 41002, … from `nextPort`).
final class FakeMaster: SSHForwarding, @unchecked Sendable {
    private let lock = NSLock()
    private var _added: [SSHForwardSpec] = []
    private var _cancelled: [SSHForwardSpec] = []
    private var _port = 41000
    private var _taken: Set<Int> = []
    private var _connected = true
    var delay: Duration = .zero

    var added: [SSHForwardSpec] { lock.withLock { _added } }
    var cancelled: [SSHForwardSpec] { lock.withLock { _cancelled } }
    var takenPorts: Set<Int> {
        get { lock.withLock { _taken } }
        set { lock.withLock { _taken = newValue } }
    }
    var connected: Bool {
        get { lock.withLock { _connected } }
        set { lock.withLock { _connected = newValue } }
    }

    var nextPort: @Sendable () throws -> Int {
        { [self] in lock.withLock { _port += 1; return _port } }
    }

    func addForward(_ spec: SSHForwardSpec, on endpoint: SSHEndpoint) async throws {
        if delay > .zero { try await Task.sleep(for: delay) }
        guard connected else { throw SSHTunnelError.notConnected(endpoint.displayName) }
        if takenPorts.contains(spec.localPort) { throw SSHTunnelError.portTaken("127.0.0.1:\(spec.localPort)") }
        lock.withLock { _added.append(spec) }
    }

    func cancelForward(_ spec: SSHForwardSpec, on endpoint: SSHEndpoint) async -> Bool {
        lock.withLock { _cancelled.append(spec) }
        return connected
    }

    func forwardCommandLine(_ spec: SSHForwardSpec, on endpoint: SSHEndpoint, cancel: Bool) -> String {
        "ssh -O \(cancel ? "cancel" : "forward") -L \(spec.argument)"
    }
}

/// The manager's events, for assertions.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SSHTunnelManager.Event] = []

    var record: @Sendable (SSHTunnelManager.Event) -> Void {
        { [self] event in lock.withLock { events.append(event) } }
    }

    var reasons: [SSHTunnelManager.CancelReason] {
        lock.withLock {
            events.compactMap { if case .cancelled(_, _, _, let reason, _, _) = $0 { return reason } else { return nil } }
        }
    }
}
