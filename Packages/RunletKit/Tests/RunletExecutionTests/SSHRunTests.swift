import Darwin
import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// Runs against the disposable SSH fixture (`SSHFixture`), never a real server. Skipped when
/// Docker isn't available. Serialized: one test pauses the container.
@Suite(.serialized, .live(.ssh, exclusive: true), .enabled(if: SSHFixture.available, "requires Docker and /usr/bin/ssh"))
struct SSHRunTests {
    func run(_ code: String, _ environment: SSHFixture.Environment, target: TargetSnapshot, engine: ExecutionEngine? = nil) async throws -> (events: [RunEvent], request: RunRequest) {
        let engine = engine ?? environment.engine()
        let request = RunRequest(tabId: UUID(), documentVersion: 1, target: target, code: code)
        var events: [RunEvent] = []
        for await event in try await engine.start(request) { events.append(event) }
        return (events, request)
    }

    @Test func runsSnippetsOnTheServerThroughASharedConnection() async throws {
        let environment = try await SSHFixture.environment()
        let endpoint = environment.endpoint()
        let client = environment.client()
        defer { Task { await client.disconnect(endpoint) } }
        let target = environment.target(endpoint)

        let (events, request) = try await run("echo \"hi\\n\";\nfwrite(STDERR, \"warn\\n\");\ndump(getenv('RUNLET_RUN_ID'), posix_getpwuid(posix_geteuid())['name']);\n40 + 2", environment, target: target)
        #expect(events.finished?.status == .completed, "\(events.errors)")
        #expect(events.stdout == "hi\n")
        #expect(events.stderr == "warn\n", "no banner or ssh chatter in the run's stderr")
        #expect(events.dumps.first?.value.scalar == request.runId.uuidString)
        #expect(events.dumps.first?.inSnippet == true)
        #expect(events.result?.value?.scalar == "42")
        // PHP reports the real path behind Forge-style `current`.
        #expect(events.started?.workingDirectory == "/home/runlet/site/releases/20260101")
        #expect(events.started?.framework == "plain")
        // The first run opened the shared connection; it stays for the next one.
        #expect(client.status(endpoint) == .connected)
        let second = try await run("PHP_VERSION", environment, target: target)
        #expect(second.events.result?.value?.scalar?.hasPrefix("8.4") == true)
        #expect(await client.disconnect(endpoint))
        #expect(client.status(endpoint) == .disconnected)
    }

    @Test func ddExitAndFatalFinishLikeLocalRuns() async throws {
        let environment = try await SSHFixture.environment()
        let endpoint = environment.endpoint()
        let client = environment.client()
        defer { Task { await client.disconnect(endpoint) } }
        let target = environment.target(endpoint, directory: "/srv/app")

        let dd = try await run("dump(['a' => 1]);\ndd('stop');\necho 'never';", environment, target: target).events
        #expect(dd.finished?.reason == "dd")
        #expect(dd.finished?.status == .completed)
        #expect(dd.dumps.count == 2)
        #expect(!dd.stdout.contains("never"))

        let exit = try await run("echo 'x'; exit(3);", environment, target: target).events
        #expect(exit.stdout == "x")
        #expect(exit.finished?.reason == "exit")
        #expect(exit.finished?.exitCode == 3)
        #expect(exit.finished?.status == .failed)

        let fatal = try await run("ini_set('memory_limit', (string) (memory_get_usage(true) + 8 * 1024 * 1024));\n$a = str_repeat('x', 64 * 1024 * 1024);", environment, target: target).events
        #expect(fatal.errors.first?.className == "FatalError")
        #expect(fatal.errors.first?.snippetLine == 2)
        #expect(fatal.finished?.reason == "fatal")

        let composer = try await run("(new Acme\\Greeter())->greet('ssh')", environment, target: target).events
        #expect(composer.started?.framework == "composer")
        #expect(composer.result?.value?.scalar?.hasPrefix("Hello, ssh") == true, "\(composer.errors)")
    }

    @Test func quotingSurvivesOddDirectoriesAndPHPPaths() async throws {
        let environment = try await SSHFixture.environment()
        let directory = "/srv/it's a \"dir\" $HOME `x`"
        try await environment.exec("mkdir -p \"$1\"", stdin: nil, arguments: [directory])
        let endpoint = environment.endpoint()
        let client = environment.client()
        defer { Task { await client.disconnect(endpoint) } }
        let events = try await run("getcwd()", environment, target: environment.target(endpoint, directory: directory, php: "/usr/local/bin/php")).events
        #expect(events.result?.value?.scalar == directory, "\(events.errors)")
    }

    @Test func stopEndsTheRunnerAndEverythingItStarted() async throws {
        let environment = try await SSHFixture.environment()
        let endpoint = environment.endpoint()
        let client = environment.client()
        defer { Task { await client.disconnect(endpoint) } }
        let engine = environment.engine()
        // A child in the runner's process group and one that left it (setsid).
        let code = "$a = proc_open(['sleep', '301'], [], $p1);\n$b = proc_open(['setsid', 'sleep', '302'], [], $p2);\necho 'go';\nwhile (true) { usleep(10000); }"
        let request = RunRequest(tabId: UUID(), documentVersion: 1, target: environment.target(endpoint), code: code)
        var events: [RunEvent] = []
        var outcome: CancelOutcome?
        let clock = ContinuousClock()
        var stopAt: ContinuousClock.Instant?
        for await event in try await engine.start(request) {
            events.append(event)
            if case .stdout = event.kind, stopAt == nil {
                try await Task.sleep(for: .milliseconds(300))
                stopAt = clock.now
                outcome = await engine.cancel(runId: request.runId)
            }
        }
        #expect(clock.now - (stopAt ?? clock.now) < .seconds(8))
        #expect(outcome?.confirmed == true, "\(outcome?.message ?? "")")
        #expect(events.finished?.status == .cancelled)
        let left = try await environment.exec("ps -u runlet -o args= || true")
        #expect(!left.contains("sleep 301") && !left.contains("sleep 302"), "children survived: \(left)")
        #expect(!left.contains("php -d display_errors"), "the runner survived: \(left)")
    }

    @Test func concurrentRunsShareOneConnection() async throws {
        let environment = try await SSHFixture.environment()
        let endpoint = environment.endpoint()
        let client = environment.client()
        defer { Task { await client.disconnect(endpoint) } }
        let engine = environment.engine()
        let target = environment.target(endpoint)
        // Open the shared connection first, so the four runs below don't race to create it.
        _ = try await run("1", environment, target: target, engine: engine)
        let pids = try await withThrowingTaskGroup(of: String?.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    let events = try await run("usleep(400000);\ngetmypid()", environment, target: target, engine: engine).events
                    return events.result?.value?.scalar
                }
            }
            var pids: [String?] = []
            for try await pid in group { pids.append(pid) }
            return pids
        }
        #expect(pids.compactMap { $0 }.count == 4)
        #expect(Set(pids.compactMap { $0 }).count == 4)
    }

    @Test func refusesUnknownHostKeysAndExplainsFailures() async throws {
        let environment = try await SSHFixture.environment()
        let client = environment.client()

        let unknown = environment.endpoint(host: SSHFixture.Environment.unknownKeyHost)
        let unknownEvents = try await run("1", environment, target: environment.target(unknown)).events
        #expect(unknownEvents.finished?.reason == "launch-failed")
        #expect(unknownEvents.errors.first?.message.contains("never accepts a host key") == true, "\(unknownEvents.errors)")
        #expect(client.status(unknown) != .connected)

        // A password-only account: a run never prompts, it explains.
        let password = environment.endpoint(host: SSHFixture.Environment.passwordHost)
        let deniedEvents = try await run("1", environment, target: environment.target(password)).events
        #expect(deniedEvents.finished?.reason == "launch-failed")
        #expect(deniedEvents.errors.first?.message.contains("Password / 2FA") == true, "\(deniedEvents.errors)")

        // Interactive profiles never log in from a run: without Connect… there is no socket.
        let interactive = environment.endpoint(host: SSHFixture.Environment.passwordHost, authentication: .interactive)
        let notConnected = try await run("1", environment, target: environment.target(interactive)).events
        #expect(notConnected.finished?.reason == "launch-failed")

        let endpoint = environment.endpoint()
        defer { Task { await client.disconnect(endpoint) } }
        let missingDirectory = try await run("1", environment, target: environment.target(endpoint, directory: "/srv/nope")).events
        #expect(missingDirectory.errors.first?.message.contains("doesn't exist on") == true, "\(missingDirectory.errors)")
        let missingPHP = try await run("1", environment, target: environment.target(endpoint, php: "php9.9")).events
        #expect(missingPHP.errors.first?.message.contains("PHP was not found") == true, "\(missingPHP.errors)")
    }

    @Test func deadConnectionEndsTheRunWithATransportError() async throws {
        let environment = try await SSHFixture.environment()
        guard let docker = TestSupport.docker else { return }
        // Short keep-alives: the dead link is noticed after ~3 s instead of ~45 s.
        let options = ["-o", "ServerAliveInterval=1", "-o", "ServerAliveCountMax=3"]
        let client = environment.client(extraOptions: options)
        let endpoint = environment.endpoint()
        let engine = environment.engine(extraOptions: options)
        let request = RunRequest(tabId: UUID(), documentVersion: 1, target: environment.target(endpoint), code: "echo 'go';\nsleep(60);")
        var events: [RunEvent] = []
        var paused = false
        let clock = ContinuousClock()
        var pausedAt: ContinuousClock.Instant?
        do {
            for await event in try await engine.start(request) {
                events.append(event)
                if case .stdout = event.kind, !paused {
                    try await docker.run(["pause", environment.containerId])
                    paused = true
                    pausedAt = clock.now
                }
            }
        } catch {
            if paused { _ = try? await docker.run(["unpause", environment.containerId]) }
            throw error
        }
        if paused { try await docker.run(["unpause", environment.containerId]) }
        #expect(paused)
        #expect(clock.now - (pausedAt ?? clock.now) < .seconds(20))
        #expect(events.finished?.reason == "transport-closed", "\(events.finished.map { "\($0)" } ?? "")")
        #expect(events.errors.last?.message.contains("connection was lost") == true, "\(events.errors)")
        await client.disconnect(endpoint)
        // The server-side PHP is still sleeping; end it so it doesn't linger.
        _ = try? await environment.exec("pkill -u runlet -f 'display_errors=stderr' || true")
    }

    @Test func probeReportsServerFactsWithoutRunningProjectCode() async throws {
        let environment = try await SSHFixture.environment()
        let endpoint = environment.endpoint()
        let client = environment.client()
        defer { Task { await client.disconnect(endpoint) } }

        let probe = await client.probe(endpoint, phpExecutable: "php", directory: "/home/runlet/site/current")
        #expect(probe.error == nil, "\(probe.error ?? "")")
        #expect(probe.phpVersion?.hasPrefix("8.4") == true)
        #expect(probe.user == "runlet")
        #expect(probe.os == "Linux")
        #expect(probe.hasProc)
        #expect(probe.canSignal == "posix")
        #expect(probe.directoryExists && probe.directoryReadable)
        #expect(probe.realDirectory == "/home/runlet/site/releases/20260101")
        #expect(probe.phpCandidates.contains("/usr/local/bin/php"))
        #expect(probe.candidates.contains("/srv/app"), "\(probe.candidates)")
        #expect(probe.elapsedMs != nil)

        let app = await client.probe(endpoint, phpExecutable: "php", directory: "/srv/app")
        #expect(app.framework == "composer")
        #expect(app.composerName == "runlet/fixture-composer")

        let missing = await client.probe(endpoint, phpExecutable: "php9.9", directory: "/srv/app")
        #expect(missing.error?.contains("PHP was not found") == true, "\(missing.error ?? "")")
    }

    @Test func probeReadsTheServersCheckoutForDriftAndSuggestions() async throws {
        let environment = try await SSHFixture.environment()
        let commit = String(repeating: "b", count: 40)
        try await environment.exec("""
        rm -rf /srv/gitapp && mkdir -p /srv/gitapp/.git/refs/heads && cd /srv/gitapp \
        && printf 'ref: refs/heads/main\\n' > .git/HEAD && printf '\(commit)\\n' > .git/refs/heads/main \
        && printf '[remote "origin"]\\n\\turl = git@github.com:acme/shop.git\\n' > .git/config \
        && printf '123456789' > composer.lock && printf '{"name": "acme/shop"}' > composer.json
        """)
        let endpoint = environment.endpoint()
        let client = environment.client()
        let probe = await client.probe(endpoint, phpExecutable: "php", directory: "/srv/gitapp")
        await client.disconnect(endpoint)
        #expect(probe.gitBranch == "main" && probe.gitCommit == commit && probe.gitRemote == "git@github.com:acme/shop.git", "\(probe)")
        // The server's CRC-32 (PHP hash_file crc32b) matches the one computed on this Mac.
        #expect(probe.composerLockCRC == String(format: "%08x", CRC32.checksum(Data("123456789".utf8))) && probe.composerLockSize == 9)
        #expect(probe.composerName == "acme/shop")
        #expect(probe.checkout.summary == "main @bbbbbbb")
        #expect(CheckoutDrift.warning(local: CheckoutState(branch: "main", commit: commit), remote: probe.checkout, host: "fixture") == nil)
        #expect(CheckoutDrift.warning(local: CheckoutState(branch: "dev", commit: String(repeating: "c", count: 40)), remote: probe.checkout, host: "fixture") != nil)
    }

    @Test func connectLogsInThroughAPseudoTerminalAndDisconnectEndsIt() async throws {
        let environment = try await SSHFixture.environment()
        let client = environment.client()
        let endpoint = environment.endpoint(host: SSHFixture.Environment.passwordHost, authentication: .interactive)
        #expect(client.status(endpoint) == .disconnected)

        let argv = try client.connectCommand(endpoint)
        let login = try PseudoTerminal(argv, environment: client.environment)
        defer { login.stop() }
        #expect(try await login.waitFor { login.text.lowercased().contains("password:") }, "OpenSSH asks for the password: \(login.text)")
        login.send(SSHFixture.password + "\r")
        #expect(try await login.waitFor { !login.isRunning }, "ssh -f goes to the background after the login: \(login.text)")
        #expect(login.exitCode == 0, "\(login.text)")
        #expect(!login.text.contains(SSHFixture.password), "the password is never echoed")
        #expect(client.status(endpoint) == .connected)

        // Runs reuse the login (BatchMode, no prompt).
        let events = try await run("posix_getpwuid(posix_geteuid())['name']", environment, target: environment.target(endpoint, directory: "/tmp")).events
        #expect(events.result?.value?.scalar == "runletpw", "\(events.errors)")

        #expect(await client.disconnect(endpoint))
        #expect(client.status(endpoint) == .disconnected)
        let after = try await run("1", environment, target: environment.target(endpoint, directory: "/tmp")).events
        #expect(after.finished?.reason == "launch-failed")
    }
}

/// A command under `script -q /dev/null …`, which gives it a pseudo-terminal (OpenSSH reads
/// passwords from /dev/tty), fed through a pipe, with its output collected.
final class PseudoTerminal: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()

    init(_ argv: [String], environment: [String: String]) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null"] + argv
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.lock()
            self.buffer.append(data)
            self.lock.unlock()
        }
        try process.run()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }

    var isRunning: Bool { process.isRunning }
    var exitCode: Int32 { process.terminationStatus }

    func send(_ text: String) {
        input.fileHandleForWriting.write(Data(text.utf8))
    }

    func waitFor(seconds: Double = 20, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }
}

extension SSHRunTests {
    /// "Keep compiled PHP on the server": a private opcode file cache under ~/.cache/runlet.
    @Test func keepCompiledPHPUsesAPrivateFileCache() async throws {
        let environment = try await SSHFixture.environment()
        let endpoint: SSHEndpoint = {
            var endpoint = environment.endpoint()
            endpoint.keepCompiledPHP = true
            return endpoint
        }()
        let client = environment.client()
        defer { Task { await client.disconnect(endpoint) } }
        let target = environment.target(endpoint)

        // The fixture's home belongs to root: without a writable ~/.cache, runs go on uncached.
        _ = try await environment.exec("rm -rf /home/runlet/.cache")
        let (fallback, _) = try await run("is_dir(getenv('HOME') . '/.cache/runlet') ? 'created' : 'skipped'", environment, target: target)
        #expect(fallback.finished?.status == .completed, "\(fallback.errors)")
        #expect(fallback.result?.value?.scalar == "skipped")

        _ = try await environment.exec("mkdir -p /home/runlet/.cache && chown runlet:runlet /home/runlet/.cache")
        defer { Task { _ = try? await environment.exec("rm -rf /home/runlet/.cache") } }
        let (events, _) = try await run("""
        $dir = getenv('HOME') . '/.cache/runlet/opcache';
        implode('|', [is_dir($dir) ? 'dir' : 'missing', substr(sprintf('%o', fileperms($dir)), -3), substr(sprintf('%o', fileperms(dirname($dir))), -3),
            extension_loaded('Zend OPcache') ? (ini_get('opcache.file_cache') === $dir && ini_get('opcache.enable_cli') === '1' ? 'cached' : 'not cached') : 'no opcache extension'])
        """, environment, target: target)
        #expect(events.finished?.status == .completed, "\(events.errors)")
        let value = events.result?.value?.scalar ?? ""
        #expect(value == "dir|700|700|cached" || value == "dir|700|700|no opcache extension", "\(value) — \(events.logs.first { $0.source == "launch" }?.message ?? "")")
    }
}
