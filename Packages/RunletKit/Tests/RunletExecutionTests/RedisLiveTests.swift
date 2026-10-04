import Foundation
@testable import RunletCore
import Testing
@testable import RunletExecution

extension Array where Element == RunEvent {
    /// #190: every `redis` event's reply, in order.
    var redisReplies: [RedisReplyInfo] {
        compactMap { if case .redis(let reply) = $0.kind { reply } else { nil } }
    }

    var redisNotices: [String] {
        compactMap { if case .notice(let text) = $0.kind { text } else { nil } }
    }
}

/// Redis tabs (#190) against the live Redis fixture (`scripts/setup-fixtures.sh databases`:
/// redis:7-alpine, `RUNLET_TEST_REDIS` = `redis://:<password>@127.0.0.1:<port>/0`, TLS on
/// `RUNLET_TEST_REDIS_TLS` with the CA in `RUNLET_TEST_TLS`): Runlet's RESP client on a saved
/// connection from the target and from this Mac, every reply type, read-only and streaming
/// refusals, Run All and MULTI/EXEC, passwords, TLS, ACL users, the key browser, the server
/// panel, Kill Client, Stop on BLPOP, and application connections (a driver's callable, phpredis,
/// and Laravel's Redis::connection()). Keys start with `p190:`.
/// The Redis fixture's address and password (#190), from `RUNLET_TEST_REDIS`.
struct RedisFixtureServer {
    var host: String
    var port: Int
    var password: String
    var tlsPort: Int?

    init?() {
        guard let url = ProcessInfo.processInfo.environment["RUNLET_TEST_REDIS"].flatMap(URL.init(string:)), let host = url.host, let port = url.port else { return nil }
        self.host = host
        self.port = port
        password = url.password ?? ""
        tlsPort = ProcessInfo.processInfo.environment["RUNLET_TEST_REDIS_TLS"].flatMap(URL.init(string:))?.port
    }
}

enum RedisFixture {
    static let server = RedisFixtureServer()
    static var tlsFolder: String? { ProcessInfo.processInfo.environment["RUNLET_TEST_TLS"].flatMap { $0.isEmpty ? nil : $0 } }
    static var hasPhpredis: Bool {
        guard let php = TestSupport.php(), let result = try? TestProcess.runBlocking([php, "-r", "echo extension_loaded('redis') ? 'yes' : 'no';"], step: "php -r", within: .seconds(20)) else { return false }
        return result.output == "yes"
    }
}

@Suite(.serialized, .enabled(if: TestSupport.hasPHP && RedisFixture.server != nil, "set RUNLET_TEST_REDIS (scripts/setup-fixtures.sh databases)"))
struct RedisLiveTests {
    typealias Server = RedisFixtureServer

    static var server: Server? { RedisFixture.server }
    static var tlsFolder: String? { RedisFixture.tlsFolder }
    static let plain = DriverSupport.fixture("plain")

    var server: Server { Self.server! }

    /// A saved Redis connection to the fixture, with its password in an in-memory store.
    func saved(readOnly: Bool = false, user: String = "", password: String? = nil, database: String = "", from: DatabaseConnectFrom = .target, tls: DatabaseTLS? = nil, port: Int? = nil) -> (DatabaseConnection, InMemoryCredentialStore) {
        let connection = DatabaseConnection(name: "Fixture cache", scope: .local(UUID()), connectFrom: from, driver: .redis, host: server.host, port: port ?? server.port, database: database, user: user, connectTimeout: 5, readOnly: readOnly, tls: tls)
        let store = InMemoryCredentialStore()
        try? store.set(SensitiveString(password ?? server.password), for: connection.id, label: "Runlet database: test")
        return (connection, store)
    }

    /// Runs `script` (Redis tab text) on `connection`, as the app does.
    func run(_ script: String, on connection: DatabaseConnection, store: InMemoryCredentialStore, all: Bool = true, transaction: Bool = false, target: TargetSnapshot? = nil) async throws -> [RunEvent] {
        let commands = try RedisScript.commandsToRunAll(in: script, selection: NSRange(location: 0, length: 0)).get()
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil, credentials: store)
        var request = RunRequest(tabId: UUID(), documentVersion: 1, target: target ?? DriverSupport.target(Self.plain), code: RedisTabRun.code(commands: commands, connection: nil, all: all, transaction: transaction), magicComments: false)
        request.sqlConnection = connection
        var events: [RunEvent] = []
        for await event in try await engine.start(request) { events.append(event) }
        return events
    }

    /// Sends one command to the fixture with Runlet's RESP client in host PHP (setup and checks,
    /// outside a run), and returns the reply as JSON.
    @discardableResult
    func cli(_ arguments: [String]) throws -> String {
        let code = """
            require \(Self.phpString(TestSupport.repoRoot.appendingPathComponent("Resources/Runner/dist/runlet-runner.php").path));
            $s = stream_socket_client('tcp://\(server.host):\(server.port)', $no, $err, 5);
            $c = new \\RunletRunner\\RedisClient($s);
            $c->command(['AUTH', \(Self.phpString(server.password))]);
            echo json_encode($c->command(json_decode($argv[1], true), 1000));
            """
        let json = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        let result = try TestProcess.runBlocking([DriverSupport.php, "-r", code, json], step: "redis \(arguments.first ?? "")", within: .seconds(20))
        return result.output
    }

    static func phpString(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    func reset() throws {
        let keys = try cli(["KEYS", "p190:*"])
        let names = (try? JSONDecoder().decode(RedisValue.self, from: Data(keys.utf8)))?.elements?.compactMap(\.stringValue) ?? []
        if !names.isEmpty { try cli(["DEL"] + names) }
    }

    // MARK: Saved connections

    @Test func everyReplyTypeFromTheTarget() async throws {
        try reset()
        let (connection, store) = saved()
        let events = try await run("""
        PING
        SET p190:greeting "{\\"hello\\": \\"world\\"}"
        GET p190:greeting
        INCR p190:counter
        GET p190:missing
        HSET p190:user:1 name Ada role admin
        HGETALL p190:user:1
        RPUSH p190:queue a b c
        LRANGE p190:queue 0 -1
        SADD p190:tags red green
        SMEMBERS p190:tags
        ZADD p190:board 12 ada 7.5 bob
        ZRANGE p190:board 0 -1 WITHSCORES
        XADD p190:events 1-0 type signup user 7
        XRANGE p190:events - +
        SCAN 0 MATCH p190:* COUNT 1000
        """, on: connection, store: store)
        #expect(events.errors.isEmpty, "\(events.errors)")
        let replies = events.redisReplies
        #expect(replies.count == 16)
        #expect(replies[0].reply == .status("PONG"))
        #expect(replies[2].reply == .string(#"{"hello": "world"}"#))
        #expect(replies[3].reply == .integer(1))
        #expect(replies[4].reply == .null)
        #expect(replies[6].view.kind == .hash && replies[6].view.table.rows.map { $0.map(\.text) } == [["name", "Ada"], ["role", "admin"]])
        #expect(replies[8].view.kind == .list && replies[8].view.table.rows.count == 3)
        #expect(replies[10].view.kind == .set && Set(replies[10].view.table.rows.map { $0[0].text }) == ["red", "green"])
        #expect(replies[12].view.kind == .zset && replies[12].view.table.rows.map { $0.map(\.text) } == [["bob", "7.5"], ["ada", "12"]])
        #expect(replies[14].view.kind == .stream && replies[14].view.table.columns == ["id", "type", "user"])
        #expect(replies[15].view.kind == .keys && replies[15].view.cursor == "0")
        #expect(replies.allSatisfy { $0.saved == true && $0.connection == "Fixture cache" && $0.db == 0 })
        #expect(replies[0].statement?.title == "Statement 1 of 16 · line 1")
        // The Connection Manager learns the client id (#180); Stop has no server cancel (#144).
        let session = try #require(events.compactMap { if case .sqlSession(let info) = $0.kind { info } else { nil } }.first)
        #expect(session.driver == "redis" && session.id > 0 && SQLCancel.plan(for: session) == nil)
    }

    /// From this Mac with host PHP, and with Runlet's own PHP too when `RUNLET_TEST_RUNLET_PHP`
    /// names a scratch install (#212).
    @Test func fromThisMacAndAnotherDatabase() async throws {
        let phps = [LocalConnectionLaunch.PHP(path: DriverSupport.php, label: "PHP", isRunletPHP: false)]
            + (TestSupport.runletPHP.map { [LocalConnectionLaunch.PHP(path: $0, label: "Runlet's PHP", isRunletPHP: true)] } ?? [])
        for php in phps {
            try reset()
            let (connection, store) = saved(database: "3", from: .thisMac)
            let directory = try DriverSupport.temporaryDirectory("redis-mac")
            defer { try? FileManager.default.removeItem(at: directory) }
            let target = LocalConnectionLaunch.snapshot(connection: connection, php: php, directory: directory)
            let events = try await run("SET p190:db3 here\nGET p190:db3\nSELECT 0\nEXISTS p190:db3", on: connection, store: store, target: target)
            #expect(events.errors.isEmpty, "\(php.label): \(events.errors)")
            #expect(events.redisReplies.map(\.db) == [3, 3, 0, 0], "\(php.label)")
            #expect(events.redisReplies.last?.reply == .integer(0), "the key is in database 3 only (\(php.label))")
            // Sending it to a target instead is refused before anything starts.
            await #expect(throws: (any Error).self) { _ = try await run("PING", on: connection, store: store) }
            let cleanup = try await run("SELECT 3\nDEL p190:db3", on: connection, store: store, target: target)
            #expect(cleanup.errors.isEmpty)
        }
    }

    @Test func errorsStopRunAllAndMultiRunsEverything() async throws {
        try reset()
        let (connection, store) = saved()
        let stopped = try await run("SET p190:a 1\nHGET p190:a field\nSET p190:b 2", on: connection, store: store)
        #expect(stopped.redisReplies.count == 1)
        let message = try #require(stopped.errors.first?.message)
        #expect(message.hasPrefix("Command 2 of 3 (line 2): WRONGTYPE"), "\(message)")
        #expect(message.contains("Command 3 did not run. Command 1 ran and stays"), "\(message)")
        #expect(try cli(["EXISTS", "p190:b"]).contains(#""v":0"#))

        let multi = try await run("INCR p190:n\nHGET p190:a field\nINCR p190:n", on: connection, store: store, transaction: true)
        #expect(multi.errors.isEmpty, "\(multi.errors)")
        #expect(multi.redisReplies.map(\.reply) == [.integer(1), .error("WRONGTYPE Operation against a key holding the wrong kind of value"), .integer(2)])
        #expect(multi.redisReplies.allSatisfy { $0.transaction == true })
        #expect(multi.redisNotices.last?.contains("1 of them returned an error") == true, "\(multi.redisNotices)")

        // A command Redis won't queue discards the whole transaction.
        let discarded = try await run("INCR p190:n\nNOSUCHCOMMAND x", on: connection, store: store, transaction: true)
        #expect(discarded.errors.first?.message.contains("discarded the transaction: nothing ran") == true, "\(discarded.errors)")
        #expect(try cli(["GET", "p190:n"]).contains(#""v":"2""#))
    }

    @Test func readOnlyAndStreamingAreRefusedBeforeSending() async throws {
        try reset()
        let (connection, store) = saved(readOnly: true)
        let reads = try await run("GET p190:none\nSCAN 0 MATCH p190:*\nCONFIG GET maxmemory\nCLIENT LIST", on: connection, store: store)
        #expect(reads.errors.isEmpty, "\(reads.errors)")
        let refused = try await run("GET p190:x\nSET p190:x 1", on: connection, store: store)
        #expect(refused.redisReplies.isEmpty)
        #expect(refused.errors.first?.className == "RunletRunner\\RedisRefused")
        #expect(refused.errors.first?.message.contains("Command 2 of 2 (line 2) can change data or the server (SET)") == true, "\(refused.errors)")
        #expect(try cli(["EXISTS", "p190:x"]).contains(#""v":0"#))
        let unknown = try await run("FT.SEARCH idx hello", on: connection, store: store, all: false)
        #expect(unknown.errors.first?.message.contains("doesn't know") == true)
        let (writable, writableStore) = saved()
        let streaming = try await run("SUBSCRIBE p190:news", on: writable, store: writableStore, all: false)
        #expect(streaming.errors.first?.message.contains("SUBSCRIBE streams messages") == true, "\(streaming.errors)")
    }

    @Test func passwordsNeverLeave() async throws {
        let (connection, store) = saved()
        // The server echoes it back: the event says •••.
        let echoed = try await run("ECHO \(server.password)", on: connection, store: store, all: false)
        #expect(echoed.redisReplies.first?.reply == .string("•••"))
        for text in echoed.scannableText { #expect(!text.contains(server.password), "\(text)") }
        // A typed AUTH: echoed as •••, and its password scrubbed from every event.
        let typed = try await run("AUTH \(server.password)\nECHO \(server.password)", on: connection, store: store)
        #expect(typed.redisReplies.first?.argv == ["AUTH", "•••"])
        for text in typed.scannableText { #expect(!text.contains(server.password), "\(text)") }
        // A wrong password: a clear error without either password.
        let (wrong, wrongStore) = saved(password: "not-the-Pw-123")
        let failed = try await run("PING", on: wrong, store: wrongStore, all: false)
        let message = try #require(failed.errors.first?.message)
        #expect(message.contains("WRONGPASS") && !message.contains("not-the-Pw-123"), "\(message)")
        for text in failed.scannableText { #expect(!text.contains("not-the-Pw-123") && !text.contains(server.password), "\(text)") }
    }

    @Test(.enabled(if: RedisFixture.server?.tlsPort != nil && RedisFixture.tlsFolder != nil, "set RUNLET_TEST_REDIS_TLS and RUNLET_TEST_TLS"))
    func tlsAndACLUsers() async throws {
        let folder = try #require(Self.tlsFolder)
        let verified = saved(tls: DatabaseTLS(mode: .verifyFull, caFile: folder + "/ca.crt"), port: server.tlsPort)
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil, credentials: verified.1)
        let info = try await engine.testSQLConnection(target: DriverSupport.target(Self.plain), connection: verified.0, password: .stored)
        #expect(info.driver == "redis" && info.tls == true && info.tlsVersion?.hasPrefix("TLS") == true, "\(info)")
        #expect(info.summary.hasPrefix("Connected: Redis 7"), "\(info.summary)")
        let wrongCA = saved(tls: DatabaseTLS(mode: .verifyFull, caFile: folder + "/other-ca.crt"), port: server.tlsPort)
        await #expect(throws: (any Error).self) {
            _ = try await ExecutionEngine(bundle: TestSupport.bundle, docker: nil, credentials: wrongCA.1).testSQLConnection(target: DriverSupport.target(Self.plain), connection: wrongCA.0, password: .stored)
        }
        let required = saved(tls: DatabaseTLS(mode: .require), port: server.tlsPort)
        let replies = try await run("PING", on: required.0, store: required.1, all: false)
        #expect(replies.redisReplies.first?.reply == .status("PONG"), "\(replies.errors)")

        // The fixture's ACL user may only read: Redis itself refuses its writes.
        let (reader, readerStore) = saved(user: "runlet-reader", password: "runlet-reader")
        let read = try await run("GET p190:none", on: reader, store: readerStore, all: false)
        #expect(read.errors.isEmpty, "\(read.errors)")
        let write = try await run("SET p190:x 1", on: reader, store: readerStore, all: false)
        #expect(write.errors.first?.message.contains("NOPERM") == true, "\(write.errors)")
    }

    /// #143 for Redis: from this Mac through the SSH fixture's tunnel to the Compose service
    /// `redis:6379`, which only the SSH server resolves; and TLS (Require) to `redis:6380`.
    @Test(.enabled(if: SSHFixture.available, "requires Docker and OpenSSH"))
    func throughAnSSHTunnel() async throws {
        let bastion = try await SQLLiveTunnelTests.Bastion.open()
        for (port, tls) in [(6379, DatabaseTLS?.none), (6380, DatabaseTLS(mode: .require))] {
            var (connection, store) = saved(from: .sshTunnel, tls: tls, port: port)
            connection.host = "redis"
            connection.sshProfile = SQLLiveTunnelTests.profileId
            connection = connection.normalized
            let (lease, target) = try await bastion.lease(connection)
            let events = try await run("SET p190:tunnel ok\nGET p190:tunnel\nDEL p190:tunnel", on: connection, store: store, target: target)
            await bastion.manager.release(lease)
            #expect(events.errors.isEmpty, "\(port): \(events.errors)")
            #expect(events.redisReplies.map(\.reply) == [.status("OK"), .string("ok"), .integer(1)], "\(port)")
            #expect(events.redisReplies.first?.source?.contains("through SSH “bastion”") == true, "\(String(describing: events.redisReplies.first?.source))")
        }
        await bastion.close()
    }

    // MARK: Key browser and server panel

    @Test func keyBrowserScansPagesAndReadsValues() async throws {
        try reset()
        for index in 1...25 { try cli(["SET", "p190:key:\(index)", "v\(index)", "EX", "3600"]) }
        try cli(["HSET", "p190:hash", "a", "1", "b", "2"])
        let (connection, store) = saved()
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil, credentials: store)
        let target = DriverSupport.target(Self.plain)
        var cursor = "0"
        var seen = Set<String>()
        var pages = 0
        repeat {
            let page = try await engine.loadRedisKeys(target: target, db: 0, pattern: "p190:*", cursor: cursor, count: 5, type: nil, connection: nil, saved: connection)
            for key in page.keys { seen.insert(key.displayName) }
            #expect(page.keys.allSatisfy { $0.type != nil && $0.ttl != nil })
            cursor = page.next
            pages += 1
        } while cursor != "0" && pages < 100
        #expect(seen.isSuperset(of: Set((1...25).map { "p190:key:\($0)" }).union(["p190:hash"])), "\(seen.count)")
        #expect(pages > 1, "SCAN pages with COUNT 5")
        let page = try await engine.loadRedisKeys(target: target, db: 0, pattern: "p190:hash", cursor: "0", count: 1000, type: "hash", connection: nil, saved: connection)
        let hash = try #require(page.keys.first)
        #expect(hash.type == "hash" && hash.ttl == -1 && hash.readCommand == "HGETALL p190:hash")
        #expect(page.databases == 16 && page.keyspace?.first?.db == 0)
        let value = try await engine.loadRedisValue(target: target, db: 0, key: hash.bytes, maxElements: 100, connection: nil, saved: connection)
        #expect(value.view.kind == .hash && value.view.table.rows.count == 2)
        let details = try await engine.loadRedisKeyDetails(target: target, db: 0, key: hash.bytes, connection: nil, saved: connection)
        #expect(details.type == "hash" && details.length == 2 && (details.memory ?? 0) > 0, "\(details)")
        let string = try await engine.loadRedisValue(target: target, db: 0, key: Array("p190:key:1".utf8), maxElements: 100, connection: nil, saved: connection)
        #expect(string.reply == .string("v1"))
    }

    @Test func serverPanelAndKillClient() async throws {
        let (connection, store) = saved()
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil, credentials: store)
        let target = DriverSupport.target(Self.plain)
        let report = try await engine.loadRedisServer(target: target, connection: nil, saved: connection)
        #expect(report.summary.hasPrefix("Redis 7"), "\(report.summary)")
        #expect(report.sections.map(\.name).contains("Keyspace") || report.sections.map(\.name).contains("Clients"))
        let own = try #require(report.ownId)
        #expect(report.clientList.contains { $0.id == own })
        let runId = try #require(report.runId)
        // The panel's own client is refused.
        let refused = await engine.killRedisClient(target: target, clientId: own, address: "", runId: runId, listedBy: own, connection: nil, saved: connection)
        #expect(refused.outcome == .refused || refused.outcome == .gone, "\(refused)")
        // Another server's list is refused.
        let otherServer = await engine.killRedisClient(target: target, clientId: 999_999, address: "", runId: "not-this-server", listedBy: own, connection: nil, saved: connection)
        #expect(otherServer.outcome == .refused && otherServer.detail.contains("another Redis server"))
        let gone = await engine.killRedisClient(target: target, clientId: 999_999, address: "", runId: runId, listedBy: own, connection: nil, saved: connection)
        #expect(gone.outcome == .gone, "\(gone)")
    }

    /// Stop on a blocking command (BLPOP … 0): the process ends, its connection closes, and Redis
    /// drops the blocked client. Kill Client ends another blocked client.
    @Test func stopEndsABlockingCommandAndKillEndsAnother() async throws {
        try reset()
        let (connection, store) = saved()
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil, credentials: store)
        var request = RunRequest(tabId: UUID(), documentVersion: 1, target: DriverSupport.target(Self.plain), code: RedisTabRun.code(commands: try RedisScript.commandsToRunAll(in: "BLPOP p190:never 0", selection: NSRange()).get(), connection: nil), magicComments: false)
        request.sqlConnection = connection
        let stream = try await engine.start(request)
        let collector = Task { () -> [RunEvent] in
            var events: [RunEvent] = []
            for await event in stream { events.append(event) }
            return events
        }
        func blockedClients() async throws -> [RedisClientInfo] {
            try await engine.loadRedisServer(target: DriverSupport.target(Self.plain), connection: nil, saved: connection).clientList.filter { $0.command == "blpop" }
        }
        var blocked: [RedisClientInfo] = []
        for _ in 0..<50 where blocked.isEmpty {
            blocked = try await blockedClients()
            if blocked.isEmpty { try await Task.sleep(for: .milliseconds(200)) }
        }
        #expect(blocked.count == 1 && blocked.first?.isBlocked == true, "\(blocked)")
        let started = ContinuousClock.now
        _ = await engine.cancel(runId: request.runId)
        let events = await collector.value
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(events.finished?.status == .cancelled, "\(String(describing: events.finished))")
        var remaining = try await blockedClients()
        for _ in 0..<20 where !remaining.isEmpty {
            try await Task.sleep(for: .milliseconds(200))
            remaining = try await blockedClients()
        }
        #expect(remaining.isEmpty, "Redis dropped the blocked client")

        // Kill Client on another blocked client, listed by the panel.
        var second = request
        second.runId = UUID()
        second.tabId = UUID()
        let secondStream = try await engine.start(second)
        let secondCollector = Task { () -> [RunEvent] in
            var events: [RunEvent] = []
            for await event in secondStream { events.append(event) }
            return events
        }
        var listed: [RedisClientInfo] = []
        for _ in 0..<50 where listed.isEmpty {
            listed = try await blockedClients()
            if listed.isEmpty { try await Task.sleep(for: .milliseconds(200)) }
        }
        let report = try await engine.loadRedisServer(target: DriverSupport.target(Self.plain), connection: nil, saved: connection)
        let victim = try #require(listed.first)
        let kill = await engine.killRedisClient(target: DriverSupport.target(Self.plain), clientId: victim.id, address: victim.address, runId: report.runId ?? "", listedBy: report.ownId ?? 0, connection: nil, saved: connection)
        #expect(kill.outcome == .killed, "\(kill)")
        let killedEvents = await secondCollector.value
        #expect(killedEvents.errors.first?.message.contains("closed") == true, "\(killedEvents.errors)")
    }

    // MARK: Application connections

    @Test func applicationConnectionThroughADriverCallable() async throws {
        try reset()
        // A project driver's redisConnection() returns a callable that speaks RESP itself (no
        // extension needed); the run boots the project, as for any application connection.
        let directory = try DriverSupport.composerProject(drivers: ["CacheDriver.php": """
        <?php
        class CacheDriver extends \\Runlet\\Driver
        {
            public function bootstrap(string $projectPath): void
            {
            }

            public function redisConnections(): array
            {
                return ['default', 'queue'];
            }

            public function redisConnection(?string $connection)
            {
                $socket = stream_socket_client('tcp://\(server.host):\(server.port)');
                $client = new \\RunletRunner\\RedisClient($socket);
                $client->command(['AUTH', \(Self.phpString(server.password))]);
                $client->command(['SELECT', $connection === 'queue' ? '1' : '0']);
                return function (array $argv) use ($client) {
                    $reply = $client->command($argv);
                    return $reply['t'] === 'i' ? $reply['v'] : ($reply['v'] ?? null);
                };
            }
        }
        """])
        defer { try? FileManager.default.removeItem(at: directory) }
        let commands = try RedisScript.commandsToRunAll(in: "SET p190:app driver\nGET p190:app\nDEL p190:app", selection: NSRange()).get()
        let events = try await TestSupport.run(RedisTabRun.code(commands: commands, connection: "queue", all: true), target: DriverSupport.target(directory.path), magicComments: false)
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.redisReplies.map(\.reply) == [.string("OK"), .string("driver"), .integer(1)])
        #expect(events.redisReplies.first?.connections == ["default", "queue"])
        #expect(events.redisReplies.first?.connection == "queue" && events.redisReplies.first?.source == "CacheDriver::redisConnection()")
    }

    /// Laravel's Redis::connection() through phpredis, with the Laravel fixture's config/database.php
    /// pointed at the fixture by REDIS_* environment variables (they win over .env).
    @Test(.enabled(if: FileManager.default.fileExists(atPath: TestSupport.fixtures.appendingPathComponent("laravel-app/vendor").path) && RedisFixture.hasPhpredis, "needs the Laravel fixture's vendor and phpredis in host PHP"))
    func laravelRedisConnection() async throws {
        try reset()
        setenv("REDIS_HOST", server.host, 1)
        setenv("REDIS_PORT", String(server.port), 1)
        setenv("REDIS_PASSWORD", server.password, 1)
        setenv("REDIS_CLIENT", "phpredis", 1)
        defer {
            for name in ["REDIS_HOST", "REDIS_PORT", "REDIS_PASSWORD", "REDIS_CLIENT"] { unsetenv(name) }
        }
        let commands = try RedisScript.commandsToRunAll(in: "SET p190:laravel ok\nGET p190:laravel\nHSET p190:lh a 1\nHGETALL p190:lh\nGET p190:none\nHGET p190:laravel x", selection: NSRange()).get()
        let events = try await TestSupport.run(RedisTabRun.code(commands: commands, connection: nil, all: true), target: DriverSupport.target(DriverSupport.fixture("laravel-app")), magicComments: false)
        let replies = events.redisReplies
        #expect(replies.count == 5, "\(events.errors)")
        #expect(replies.first?.source == "Laravel Redis::connection()")
        #expect(replies.first?.connections?.first == "default" && replies.first?.connections?.contains("cache") == true)
        #expect(replies[1].reply == .string("ok"))
        #expect(replies[3].view.kind == .hash)
        #expect(replies[4].reply == .null)
        #expect(events.errors.first?.message.hasPrefix("Command 6 of 6 (line 6): WRONGTYPE") == true, "\(events.errors)")
    }

}

/// #190: the runner's command lists match the app's (RedisCommands.swift and RedisTab.php).
@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct RedisCommandTableTests {

    /// The runner's lists match the app's (RedisCommands.swift and RedisTab.php).
    @Test func runnerAndAppShareTheCommandTable() throws {
        let code = """
            require \(RedisLiveTests.phpString(TestSupport.repoRoot.appendingPathComponent("Resources/Runner/dist/runlet-runner.php").path));
            echo json_encode(['reads' => \\RunletRunner\\RedisCommands::READS, 'connection' => \\RunletRunner\\RedisCommands::CONNECTION, 'transaction' => \\RunletRunner\\RedisCommands::TRANSACTION, 'streaming' => \\RunletRunner\\RedisCommands::STREAMING, 'containers' => \\RunletRunner\\RedisCommands::CONTAINERS]);
            """
        let result = try TestProcess.runBlocking([DriverSupport.php, "-r", code], step: "php table", within: .seconds(20))
        let lists = try JSONDecoder().decode([String: [String]].self, from: Data(result.output.utf8))
        #expect(Set(lists["reads"] ?? []) == RedisCommands.reads)
        #expect(Set(lists["connection"] ?? []) == RedisCommands.connection)
        #expect(Set(lists["transaction"] ?? []) == RedisCommands.transaction)
        #expect(Set(lists["streaming"] ?? []) == RedisCommands.streaming)
        #expect(Set(lists["containers"] ?? []) == RedisCommands.containers)
    }
}
