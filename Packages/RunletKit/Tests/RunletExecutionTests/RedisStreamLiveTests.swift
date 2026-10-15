import Foundation
import Testing
@testable import RunletCore
@testable import RunletExecution

/// Live streams use only the shared fixture (#203); separate runners publish while the tab is busy.
@Suite(.serialized, .live(.redis), .enabled(if: TestSupport.hasPHP && RedisFixture.server != nil, "requires Redis fixture"))
struct RedisStreamLiveTests {
    private let fixture = RedisLiveTests()

    private func run(_ line: String, saved: DatabaseConnection?, store: InMemoryCredentialStore = .init(), target: TargetSnapshot? = nil, limits: RedisStreamLimits, stopAfter: Int? = nil, opened: () throws -> Void = {}) async throws -> [RunEvent] {
        let command = try RedisScript.commandsToRunAll(in: line, selection: NSRange()).get()[0]
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil, credentials: store)
        var request = RunRequest(tabId: UUID(), documentVersion: 1, target: target ?? DriverSupport.target(RedisLiveTests.plain), code: RedisTabRun.streamCode(command: command, connection: nil, limits: limits), magicComments: false)
        request.sqlConnection = saved
        var events: [RunEvent] = []
        // A broken deadline test must still clean up its runner.
        let runID = request.runId
        let watchdog = Task { try? await Task.sleep(for: .seconds(15)); if !Task.isCancelled { _ = await engine.cancel(runId: runID) } }
        defer { watchdog.cancel() }
        for await event in try await engine.start(request) {
            events.append(event)
            if case .redisStream = event.kind { try opened() }
            if case .redisMessages(let batch) = event.kind, let stopAfter, batch.received >= stopAfter { _ = await engine.cancel(runId: request.runId) }
        }
        return events
    }
    private var short: RedisStreamLimits {
        var limits = RedisStreamLimits(); limits.idleSeconds = 1; limits.totalSeconds = 3; return limits
    }
    private func rows(_ events: [RunEvent]) -> [RedisStreamMessage] {
        events.flatMap { event -> [RedisStreamMessage] in
            if case .redisMessages(let batch) = event.kind { return batch.messages }
            return []
        }
    }
    private func end(_ events: [RunEvent]) -> RedisStreamEnd? {
        events.compactMap { if case .redisStreamEnd(let end) = $0.kind { end } else { nil } }.last
    }

    @Test func subscribeTwoChannelsBinaryReadOnlyAndStop() async throws {
        let (saved, store) = fixture.saved(readOnly: true)
        let events = try await run("SUBSCRIBE p203:a p203:b", saved: saved, store: store, limits: short, stopAfter: 2) {
            try fixture.cli(["PUBLISH", "p203:a", #"{"order":42}"#])
            // JSON transport of cli cannot represent invalid UTF-8; use a byte literal on the publisher.
            let server = fixture.server
            let code = """
            require \(RedisLiveTests.phpString(TestSupport.repoRoot.appendingPathComponent("Resources/Runner/dist/runlet-runner.php").path));
            $c = new \\RunletRunner\\RedisClient(stream_socket_client('tcp://\(server.host):\(server.port)'));
            $c->command(['AUTH', \(RedisLiveTests.phpString(server.password))]);
            $c->command(['PUBLISH', 'p203:b', "\\x00\\xff\\xfe"]);
            """
            _ = try TestProcess.runBlocking([DriverSupport.php, "-r", code], step: "binary publisher", within: .seconds(10))
        }
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(rows(events).map(\.channel) == ["p203:a", "p203:b"])
        #expect(rows(events).map(\.payload) == [Data(#"{"order":42}"#.utf8), Data([0, 255, 254])])
        #expect(events.finished?.status == .cancelled)
        #expect(end(events) == nil, "Stop kills the runner; the app supplies Stopped")
        let counts = try JSONDecoder().decode(RedisValue.self, from: Data(fixture.cli(["PUBSUB", "NUMSUB", "p203:a", "p203:b"]).utf8))
        #expect(counts.elements == [.string("p203:a"), .integer(0), .string("p203:b"), .integer(0)])
    }

    @Test func patternsShardsIdleAndPayloadCap() async throws {
        let (saved, store) = fixture.saved()
        for (command, publish) in [("PSUBSCRIBE p203:*", "PUBLISH"), ("SSUBSCRIBE p203:shard", "SPUBLISH")] {
            var limits = short; limits.payloadBytes = 3
            let events = try await run(command, saved: saved, store: store, limits: limits) {
                try fixture.cli([publish, "p203:shard", "abcdef"])
            }
            #expect(events.errors.isEmpty, "\(events.errors)")
            let row = try #require(rows(events).first)
            #expect(row.payload == Data("abc".utf8) && row.omitted == 3)
            #expect(row.pattern == (publish == "PUBLISH" ? "p203:*" : nil))
            #expect(end(events)?.reason == .idle && end(events)?.received == 1)
        }
    }

    @Test func totalRateCapAndThisMac() async throws {
        let (saved, store) = fixture.saved(from: .thisMac)
        let directory = try DriverSupport.temporaryDirectory("redis-stream-mac")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = LocalConnectionLaunch.snapshot(connection: saved, php: .init(path: DriverSupport.php, label: "PHP", isRunletPHP: false), directory: directory)
        var limits = short; limits.idleSeconds = 5; limits.totalSeconds = 1; limits.messagesPerSecond = 2
        let events = try await run("SUBSCRIBE p203:rate", saved: saved, store: store, target: target, limits: limits) {
            let server = fixture.server
            let code = """
            require \(RedisLiveTests.phpString(TestSupport.repoRoot.appendingPathComponent("Resources/Runner/dist/runlet-runner.php").path));
            $c = new \\RunletRunner\\RedisClient(stream_socket_client('tcp://\(server.host):\(server.port)'));
            $c->command(['AUTH', \(RedisLiveTests.phpString(server.password))]);
            for ($i = 0; $i < 20; $i++) { $c->command(['PUBLISH', 'p203:rate', 'payload']); }
            """
            _ = try TestProcess.runBlocking([DriverSupport.php, "-r", code], step: "burst publisher", within: .seconds(10))
        }
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(rows(events).count == 2)
        #expect(end(events)?.reason == .total && end(events)?.received == 20 && end(events)?.skipped == 18)
    }

    @Test func monitorKeepsStreamingAfterOversizedBinaryValue() async throws {
        let (saved, store) = fixture.saved()
        let events = try await run("MONITOR", saved: saved, store: store, limits: short) {
            let server = fixture.server
            let code = """
            require \(RedisLiveTests.phpString(TestSupport.repoRoot.appendingPathComponent("Resources/Runner/dist/runlet-runner.php").path));
            $c = new \\RunletRunner\\RedisClient(stream_socket_client('tcp://\(server.host):\(server.port)'));
            $c->command(['AUTH', \(RedisLiveTests.phpString(server.password))]);
            try {
                $c->command(['SET', 'p203:large', str_repeat("\\x00", 2300000)]);
                $c->command(['SET', 'p203:after-large', 'still-streaming']);
            } finally {
                $c->command(['DEL', 'p203:large', 'p203:after-large']);
                $c->close();
            }
            """
            _ = try TestProcess.runBlocking([DriverSupport.php, "-r", code], step: "large MONITOR publisher", within: .seconds(10))
        }
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(rows(events).contains { $0.argv == ["SET", "p203:after-large", "still-streaming"] })
        #expect(end(events)?.reason == .idle)
        #expect(end(events)?.omitted == 1 && end(events)?.skipped == 0)
    }

    @Test func deniedSubscriptionsShowServerError() async throws {
        let (saved, store) = fixture.saved(readOnly: true, user: "runlet-reader", password: "runlet-reader")
        let events = try await run("SUBSCRIBE p203:denied", saved: saved, store: store, limits: short)
        #expect(events.errors.contains { $0.message.contains("NOPERM") }, "\(events.errors)")
        #expect(rows(events).isEmpty)
    }

    @Test func monitorRedactsOtherClientPasswords() async throws {
        let (saved, store) = fixture.saved()
        let events = try await run("MONITOR", saved: saved, store: store, limits: short) {
            try fixture.cli(["SET", "p203:monitor", "visible-value"])
            try fixture.cli(["AUTH", "invalid-password-p203"])
            try fixture.cli(["HELLO", "3", "AUTH", "default", "invalid-hello-p203"])
            try fixture.cli(["ACL", "SETUSER", "p203-user", "off", ">acl-password-p203"])
            try fixture.cli(["CONFIG", "SET", "masterauth", "master-password-p203"])
            try fixture.cli(["CONFIG", "SET", "masterauth", ""])
            try fixture.cli(["ACL", "DELUSER", "p203-user"])
            try fixture.cli(["DEL", "p203:monitor"])
        }
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(rows(events).contains { $0.argv == ["SET", "p203:monitor", "visible-value"] })
        let all = String(describing: events)
        for secret in ["invalid-password-p203", "invalid-hello-p203", "acl-password-p203", "master-password-p203", fixture.server.password] {
            #expect(!all.contains(secret), "secret in an event: \(secret)")
        }
        #expect(rows(events).allSatisfy { $0.db != nil && $0.client != nil })
    }

    @Test(.live(.ssh), .enabled(if: SSHFixture.available, "requires SSH fixture"))
    func streamsThroughSSHTunnel() async throws {
        let bastion = try await SQLLiveTunnelTests.Bastion.open()
        var (saved, store) = fixture.saved(from: .sshTunnel, port: 6379)
        saved.host = "redis"; saved.sshProfile = SQLLiveTunnelTests.profileId; saved = saved.normalized
        let (lease, target) = try await bastion.lease(saved)
        let events = try await run("SUBSCRIBE p203:tunnel", saved: saved, store: store, target: target, limits: short) {
            try fixture.cli(["PUBLISH", "p203:tunnel", "through SSH"])
        }
        await bastion.manager.release(lease); await bastion.close()
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(rows(events).first?.text == "through SSH")
    }

    @Test(.enabled(if: RedisFixture.hasPhpredis, "requires phpredis"))
    func laravelDedicatedConnectionUsesLiteralChannels() async throws {
        let directory = try DriverSupport.temporaryDirectory("redis-stream-laravel")
        defer { try? FileManager.default.removeItem(at: directory) }
        let php = directory.appendingPathComponent("php")
        let server = fixture.server
        try """
        #!/bin/sh
        REDIS_HOST=\(RemoteShell.quote(server.host)) REDIS_PORT=\(server.port) REDIS_PASSWORD=\(RemoteShell.quote(server.password)) REDIS_CLIENT=phpredis REDIS_PREFIX=app_prefix_
        export REDIS_HOST REDIS_PORT REDIS_PASSWORD REDIS_CLIENT REDIS_PREFIX
        exec \(RemoteShell.quote(DriverSupport.php)) "$@"

        """.write(to: php, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: php.path)
        let target = DriverSupport.target(DriverSupport.fixture("laravel-app"), php: php.path)
        let events = try await run("SUBSCRIBE p203:laravel app_prefix_p203:laravel", saved: nil, target: target, limits: short) {
            try fixture.cli(["PUBLISH", "p203:laravel", "literal channel"])
            try fixture.cli(["PUBLISH", "app_prefix_p203:laravel", "explicit prefix"])
            let publisher = """
            $r = new Redis(); $r->connect('\(server.host)', \(server.port));
            $r->auth(\(RedisLiveTests.phpString(server.password))); $r->setOption(Redis::OPT_PREFIX, 'app_prefix_');
            $r->publish('p203:laravel', 'phpredis prefix');
            """
            _ = try TestProcess.runBlocking([DriverSupport.php, "-r", publisher], step: "phpredis prefix publisher", within: .seconds(10))
        }
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(rows(events).map(\.text) == ["literal channel", "explicit prefix", "phpredis prefix"])
        #expect(rows(events).last?.channel == "app_prefix_p203:laravel")
    }
}
