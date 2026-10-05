import Darwin
import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// #48: the runner kept on an SSH host. The script and stdin are checked as text; the loader,
/// the shell around it, and the engine's attempts run on this Mac through
/// `Tests/Fixtures/fake-ssh/ssh`, which runs the remote command locally, with a scratch `HOME`.
/// `SSHRunTests` checks the same against the SSH fixture.
@Suite struct SSHRunnerCacheScriptTests {
    let runId = UUID(uuidString: "6F2A3C4D-1111-2222-3333-444455556666")!

    @Test func theLoaderRunsOnlyWithTheSetting() {
        let plain = RemoteShell.runScript(directory: "/srv/app", php: "php8.4", runId: runId)
        #expect(RemoteShell.runScript(directory: "/srv/app", php: "php8.4", runId: runId, runnerCache: true) == plain, "off: nothing is written, the runner streams")
        #expect(!plain.contains("-n -r") && !plain.contains(".cache"))
        let compiled = RemoteShell.runScript(directory: "/srv/app", php: "php8.4", runId: runId, keepCompiledPHP: true)
        #expect(!compiled.contains("-n -r") && compiled.hasSuffix("exec php8.4 \"$@\" -d display_errors=stderr -d html_errors=0 -d log_errors=0"))

        let cached = RemoteShell.runScript(directory: "/srv/app", php: "php8.4", runId: runId, keepCompiledPHP: true, runnerCache: true)
        #expect(cached.hasPrefix(compiled.components(separatedBy: "exec php8.4").first ?? "-"), "the directory check, run ID, and opcode cache come first, unchanged")
        // A missing PHP is reported by the plain exec, as without the cache.
        #expect(cached.contains("command -v php8.4 >/dev/null 2>&1 || exec php8.4 \"$@\" -d display_errors=stderr"))
        #expect(cached.contains("{ php8.4 -n -r 'eval(stream_get_contents(STDIN, (int) fgets(STDIN)));' -- \"$(id -u)\" || echo '<?php fwrite(STDERR, \"Runlet: runner cache miss\" . PHP_EOL); exit(75);'; } | exec php8.4 \"$@\" -d display_errors=stderr -d html_errors=0 -d log_errors=0; "))
        #expect(cached.hasSuffix(#"s=$?; [ "$s" -gt 128 ] && kill -$((s - 128)) $$; exit "$s""#), "a runner killed by a signal ends the shell with it, as exec would")
        // No backslashes: fish reads `\'` and `\\` inside single quotes as escapes.
        #expect(!cached.dropFirst(compiled.count - 80).contains("\\"))
    }

    @Test func quotingSurvivesOddDirectoriesAndPHPPaths() {
        let directory = "/srv/it's a \"dir\" $HOME `x`"
        let php = "/opt/php 8/bin/php"
        let script = RemoteShell.runScript(directory: directory, php: php, runId: runId, keepCompiledPHP: true, runnerCache: true)
        #expect(script.hasPrefix("cd \(RemoteShell.quote(directory)) 2>/dev/null"))
        #expect(script.contains("command -v '/opt/php 8/bin/php' >/dev/null"))
        #expect(script.contains("{ '/opt/php 8/bin/php' -n -r "))
        #expect(script.contains("| exec '/opt/php 8/bin/php' \"$@\" "))
        // The whole script is one word for the login shell.
        #expect(RemoteShell.command(script) == "/bin/sh -c " + RemoteShell.quote(script))
    }

    @Test func stdinCarriesTheLoaderThenTheRequestOrTheRunner() throws {
        let bundle = RunnerBundle(source: Data("<?php\nnamespace RunletRunner { class Runner { public static function main($r) { echo $r; } } }\n".utf8))
        #expect(bundle.sha256.count == 64 && bundle.sha256 == bundle.sha256.lowercased())
        let request = Data("namespace {\n\\RunletRunner\\Runner::main('e30=');\n}\n".utf8)
        var script = bundle.source
        script.append(request)
        #expect(bundle.request(in: script) == request)
        #expect(bundle.request(in: request) == nil, "a script that doesn't start with the runner streams as it is")
        #expect(bundle.request(in: bundle.source) == nil)

        for step in [SSHRunnerCache.Step.use, .save] {
            let stdin = SSHRunnerCache.stdin(step, bundle: bundle, request: request)
            let text = String(decoding: stdin, as: UTF8.self)
            let newline = try #require(text.firstIndex(of: "\n"))
            let length = try #require(Int(text[..<newline]))
            let loader = SSHRunnerCache.loader(step, bundle: bundle)
            #expect(loader.count == length)
            #expect(String(decoding: loader, as: UTF8.self).hasPrefix("$mode = '\(step.rawValue)'; $hash = '\(bundle.sha256)'; $size = \(bundle.source.count); $keep = 3;\n"))
            let rest = stdin.suffix(from: stdin.startIndex + text.utf8.distance(from: text.utf8.startIndex, to: newline) + 1 + length)
            #expect(Data(rest) == (step == .save ? script : request), "\(step)")
        }
    }

    @Test func memoryTriesTheCacheFirstAndBacksOffWhenItDoesNotLast() {
        let clock = TestClock()
        let memory = RunnerCacheMemory(clock: { clock.now })
        let key = "/tmp/ab.sock"
        #expect(memory.firstStep(key: key, hash: "a") == .use, "optimistic: the server usually keeps it from an earlier session")

        // Several first runs at once all miss, and each sends the runner: none of those misses
        // says the server can't keep it.
        let begun = clock.now
        clock.advance(.seconds(1))
        memory.missed(key: key, hash: "a", step: .use, begun: begun)
        memory.started(key: key, hash: "a", step: .save)
        memory.missed(key: key, hash: "a", step: .use, begun: begun)
        #expect(memory.firstStep(key: key, hash: "a") == .use)

        // A miss after a finished save: the server doesn't keep it. Runs send it for a while.
        clock.advance(.seconds(1))
        memory.missed(key: key, hash: "a", step: .use, begun: clock.now)
        #expect(memory.firstStep(key: key, hash: "a") == .save)
        #expect(memory.firstStep(key: key, hash: "b") == .use, "another runner starts over")
        #expect(memory.firstStep(key: "/tmp/cd.sock", hash: "a") == .use, "another profile starts over")
        clock.advance(RunnerCacheMemory.pause + .seconds(1))
        #expect(memory.firstStep(key: key, hash: "a") == .use, "and tries again later")

        // The loader failed: stream without it for a while.
        memory.missed(key: key, hash: "a", step: .save, begun: clock.now)
        #expect(memory.firstStep(key: key, hash: "a") == .stream)
        clock.advance(RunnerCacheMemory.pause + .seconds(1))
        #expect(memory.firstStep(key: key, hash: "a") == .use)
        memory.started(key: key, hash: "a", step: .use)
        #expect(memory.firstStep(key: key, hash: "a") == .use)

        // After a hit, a miss (someone cleared the folder) is just sent again, and saved.
        memory.started(key: key, hash: "a", step: .save)
        memory.started(key: key, hash: "a", step: .use)
        clock.advance(.seconds(1))
        memory.missed(key: key, hash: "a", step: .use, begun: clock.now)
        #expect(memory.firstStep(key: key, hash: "a") == .use)
    }

    @Test func missesAreTheMarkerAndExitCode75() {
        #expect(SSHRunnerCache.isMiss(exitCode: 75, stderr: "Runlet: runner cache miss\n"))
        #expect(!SSHRunnerCache.isMiss(exitCode: 75, stderr: "something else"))
        #expect(!SSHRunnerCache.isMiss(exitCode: 1, stderr: "Runlet: runner cache miss\n"))
        #expect(!SSHRunnerCache.missProgram.contains("'") && !SSHRunnerCache.missProgram.contains("\\"))
        #expect(!SSHRunnerCache.bootstrap.contains("'") && !SSHRunnerCache.bootstrap.contains("\\") && !SSHRunnerCache.bootstrap.contains("\""))
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.withLock { current } }
    func advance(_ duration: Duration) { lock.withLock { current += duration } }
}

/// The loader and the engine's attempts, end to end on this Mac (`fake-ssh` runs the remote
/// command locally), with a scratch `HOME` whose `~/.cache/runlet/runner` the tests inspect.
@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct SSHRunnerCacheLocalTests {
    final class Scratch: @unchecked Sendable {
        let home: URL
        let control: String
        let client: SSHClient
        let engine: ExecutionEngine
        let bundle = TestSupport.bundle

        init(php: String? = nil) throws {
            home = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-runner-cache-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            control = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rlt-rc-\(UUID().uuidString.prefix(6))/ab.sock").path
            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = home.path
            environment["SSH_AUTH_SOCK"] = nil
            let bin = (php ?? TestSupport.php() ?? "/usr/bin/php") as NSString
            environment["PATH"] = bin.deletingLastPathComponent + ":/usr/bin:/bin"
            client = SSHClient(executable: TestSupport.fixtures.appendingPathComponent("fake-ssh/ssh").path, environment: environment)
            engine = ExecutionEngine(bundle: bundle, docker: nil, ssh: client)
        }

        var runnerDirectory: URL { home.appendingPathComponent(".cache/runlet/runner") }
        var runnerFile: URL { runnerDirectory.appendingPathComponent("\(bundle.sha256).php") }

        func target(keep: Bool = true, php: String = "php") -> TargetSnapshot {
            var endpoint = SSHEndpoint(host: "cache-test", controlPath: control)
            endpoint.keepCompiledPHP = keep ? true : nil
            return TargetSnapshot(kind: .ssh, label: "cache", targetId: "cache", workingDirectory: TestSupport.fixtures.appendingPathComponent("plain").path, phpExecutable: php, ssh: endpoint)
        }

        func run(_ code: String = "echo \"hi\\n\";\nfwrite(STDERR, \"warn\\n\");\ndump(['a' => 1]);\n40 + 2", keep: Bool = true, php: String = "php") async throws -> [RunEvent] {
            let request = RunRequest(tabId: UUID(), documentVersion: 1, target: target(keep: keep, php: php), code: code)
            var events: [RunEvent] = []
            for await event in try await engine.start(request) { events.append(event) }
            return events
        }

        func close() async {
            await client.disconnect(SSHEndpoint(host: "cache-test", controlPath: control))
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runnerDirectory.path)
            try? FileManager.default.removeItem(at: home)
        }

        func mode(_ url: URL) -> Int {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return -1 }
            return Int(info.st_mode & 0o7777)
        }
    }

    /// The bytes on stdin of each launch, from the Run Log's launch lines.
    static func stdinBytes(_ events: [RunEvent]) -> [Int] {
        events.logs.filter { $0.source == "launch" }.compactMap { entry in
            guard let detail = entry.detail, let range = detail.range(of: " bytes on stdin") else { return nil }
            let prefix = detail[..<range.lowerBound].split(separator: " ").last.map(String.init) ?? ""
            return Int(prefix.filter(\.isNumber))
        }
    }

    /// What a run shows, without timings and IDs.
    static func shown(_ events: [RunEvent]) -> String {
        "\(events.stdout)|\(events.stderr)|\(String(describing: events.result?.value))|\(events.dumps.map(\.value))|\(events.finished?.status.rawValue ?? "-")|\(events.errors.map(\.message))"
    }

    @Test func firstRunFillsTheCacheAndTheNextSendsOnlyTheRequest() async throws {
        let scratch = try Scratch()
        defer { Task { await scratch.close() } }

        let streamed = try await scratch.run(keep: false)
        #expect(streamed.finished?.status == .completed, "\(streamed.errors)")
        #expect(!FileManager.default.fileExists(atPath: scratch.home.appendingPathComponent(".cache").path), "the setting off writes nothing")
        #expect(Self.stdinBytes(streamed) == [scratch.bundle.source.count + (Self.stdinBytes(streamed).first.map { $0 - scratch.bundle.source.count } ?? 0)])

        let first = try await scratch.run()
        #expect(first.finished?.status == .completed, "\(first.errors)")
        #expect(Self.shown(first) == Self.shown(streamed))
        #expect(first.logs.contains { $0.source == "runner cache" && $0.message.contains("no valid copy") })
        let firstBytes = Self.stdinBytes(first)
        #expect(firstBytes.count == 2 && firstBytes[0] < 20_000 && firstBytes[1] > scratch.bundle.source.count, "tried the cache, then sent the runner: \(firstBytes)")
        #expect(try Data(contentsOf: scratch.runnerFile) == scratch.bundle.source)
        #expect(scratch.mode(scratch.runnerFile) == 0o600)
        #expect(scratch.mode(scratch.runnerDirectory) == 0o700)
        #expect(scratch.mode(scratch.runnerDirectory.deletingLastPathComponent()) == 0o700)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: scratch.runnerDirectory.path)
        #expect(leftovers == ["\(scratch.bundle.sha256).php"], "no temporary files: \(leftovers)")

        let second = try await scratch.run()
        #expect(second.finished?.status == .completed, "\(second.errors)")
        #expect(Self.shown(second) == Self.shown(streamed), "the same output with and without the cache")
        let secondBytes = Self.stdinBytes(second)
        #expect(secondBytes.count == 1 && secondBytes[0] < 20_000, "only the request and the loader: \(secondBytes)")
        #expect(!second.logs.contains { $0.source == "runner cache" })
        #expect(second.logs.first { $0.source == "launch" }?.detail?.contains("read from ~/.cache/runlet/runner") == true)
        // Nothing of the request is on the server.
        let cached = try FileManager.default.contentsOfDirectory(atPath: scratch.runnerDirectory.path)
        #expect(cached == ["\(scratch.bundle.sha256).php"])
    }

    @Test func aTamperedRunnerIsNeverUsed() async throws {
        let scratch = try Scratch()
        defer { Task { await scratch.close() } }
        _ = try await scratch.run()
        #expect(Self.stdinBytes(try await scratch.run()).count == 1, "filled, then used")
        let file = scratch.runnerFile
        let manager = FileManager.default

        // Changed content, same size: the hash catches it.
        var changed = scratch.bundle.source
        changed.replaceSubrange(changed.startIndex + 10..<changed.startIndex + 11, with: Data("X".utf8))
        try changed.write(to: file)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        // Group- or world-readable.
        let tampered: [(String, () throws -> Void)] = [
            ("content", { }),
            ("mode 0644", { try scratch.bundle.source.write(to: file); try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }),
            ("symlink", {
                let elsewhere = scratch.home.appendingPathComponent("copy.php")
                try scratch.bundle.source.write(to: elsewhere)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: elsewhere.path)
                try manager.removeItem(at: file)
                try manager.createSymbolicLink(at: file, withDestinationURL: elsewhere)
            }),
            ("truncated", { try scratch.bundle.source.prefix(1000).write(to: file); try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }),
        ]
        for (label, tamper) in tampered {
            try tamper()
            let events = try await scratch.run("'ok'")
            #expect(events.result?.value?.scalar == "ok", "\(label): \(events.errors)")
            #expect(events.logs.contains { $0.source == "runner cache" && $0.message.contains("no valid copy") }, "\(label) is a miss")
            #expect(try Data(contentsOf: file) == scratch.bundle.source, "\(label): replaced by the runner")
            #expect(scratch.mode(file) == 0o600, "\(label)")
            var info = stat()
            #expect(lstat(file.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG, "\(label): a regular file again")
            // The refreshed runner is used by the next run.
            let hit = try await scratch.run("'ok'")
            #expect(hit.result?.value?.scalar == "ok" && Self.stdinBytes(hit).count == 1 && Self.stdinBytes(hit)[0] < 20_000, "\(label): \(Self.stdinBytes(hit))")
        }
    }

    @Test func aFolderOthersCanWriteIsNeitherUsedNorFilled() async throws {
        let scratch = try Scratch()
        defer { Task { await scratch.close() } }
        _ = try await scratch.run()
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: scratch.runnerDirectory.path)
        let events = try await scratch.run("'ok'")
        #expect(events.result?.value?.scalar == "ok", "\(events.errors)")
        #expect(events.logs.contains { $0.source == "runner cache" && $0.message.contains("no valid copy") })
        #expect(Self.stdinBytes(events).last ?? 0 > scratch.bundle.source.count, "streamed")
        #expect(scratch.mode(scratch.runnerDirectory) == 0o777, "left alone")
    }

    @Test func aReadOnlyFolderFallsBackToStreaming() async throws {
        let scratch = try Scratch()
        defer { Task { await scratch.close() } }
        try FileManager.default.createDirectory(at: scratch.runnerDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scratch.runnerDirectory.deletingLastPathComponent().path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: scratch.runnerDirectory.path)

        let first = try await scratch.run()
        #expect(first.finished?.status == .completed, "\(first.errors)")
        #expect(Self.stdinBytes(first).count == 2)
        #expect(!FileManager.default.fileExists(atPath: scratch.runnerFile.path))
        // The save didn't last: the next run tries the cache once more, misses, and from then
        // on the runs send the runner without trying first.
        let second = try await scratch.run()
        #expect(second.finished?.status == .completed, "\(second.errors)")
        #expect(Self.stdinBytes(second).count == 2)
        let third = try await scratch.run()
        #expect(Self.shown(third) == Self.shown(first))
        let bytes = Self.stdinBytes(third)
        #expect(bytes.count == 1 && bytes[0] > scratch.bundle.source.count, "sent the runner at once: \(bytes)")
        #expect(!third.logs.contains { $0.source == "runner cache" })
    }

    @Test func savingKeepsTheThreeMostRecentlyUsedRunners() async throws {
        let scratch = try Scratch()
        defer { Task { await scratch.close() } }
        let manager = FileManager.default
        try manager.createDirectory(at: scratch.runnerDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scratch.runnerDirectory.deletingLastPathComponent().path)
        let old = (1...4).map { String(repeating: String($0), count: 64) }
        for (index, name) in old.enumerated() {
            let url = scratch.runnerDirectory.appendingPathComponent("\(name).php")
            try Data("<?php // \(name)".utf8).write(to: url)
            try manager.setAttributes([.posixPermissions: 0o600, .modificationDate: Date(timeIntervalSinceNow: -Double(1000 * (index + 1)))], ofItemAtPath: url.path)
        }
        let staleTemp = scratch.runnerDirectory.appendingPathComponent(".\(old[0]).123.456.tmp")
        try Data("partial".utf8).write(to: staleTemp)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: staleTemp.path)
        let other = scratch.runnerDirectory.appendingPathComponent("notes.txt")
        try Data("mine".utf8).write(to: other)

        let events = try await scratch.run("'ok'")
        #expect(events.result?.value?.scalar == "ok", "\(events.errors)")
        let names = Set(try manager.contentsOfDirectory(atPath: scratch.runnerDirectory.path))
        #expect(names == ["\(scratch.bundle.sha256).php", "\(old[0]).php", "\(old[1]).php", "notes.txt"], "\(names)")
    }

    @Test func aFailingLoaderFallsBackToStreaming() async throws {
        // A PHP that refuses `-n`: the loader can't run, so the runner's PHP gets the miss
        // program, the run is sent with the runner, misses again, and finally streams.
        let wrapper = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-php-no-n-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: wrapper, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: wrapper) }
        let php = try #require(TestSupport.php())
        let script = wrapper.appendingPathComponent("php")
        try Data("#!/bin/sh\n[ \"$1\" = -n ] && { echo 'no -n here' >&2; exit 1; }\nexec \(RemoteShell.quote(php)) \"$@\"\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let scratch = try Scratch(php: script.path)
        defer { Task { await scratch.close() } }
        let first = try await scratch.run("'ok'")
        #expect(first.result?.value?.scalar == "ok", "\(first.errors)")
        #expect(first.stderr.isEmpty, "the failed attempts' output isn't shown: \(first.stderr)")
        #expect(Self.stdinBytes(first).count == 3)
        #expect(first.logs.filter { $0.source == "runner cache" }.count == 2)
        let second = try await scratch.run("'ok'")
        #expect(second.result?.value?.scalar == "ok")
        #expect(Self.stdinBytes(second).count == 1, "streams at once for a while")
        #expect(!FileManager.default.fileExists(atPath: scratch.runnerFile.path))
    }

    @Test func missingPHPAndDirectoriesAreExplainedAsWithoutTheCache() async throws {
        let scratch = try Scratch()
        defer { Task { await scratch.close() } }
        let missing = try await scratch.run("1", php: "php9.9-missing")
        #expect(missing.errors.first?.message.contains("PHP was not found") == true, "\(missing.errors)")
        #expect(Self.stdinBytes(missing).count == 1, "not a miss")
        let plain = try await scratch.run("1", keep: false, php: "php9.9-missing")
        #expect(missing.errors.first?.message == plain.errors.first?.message)
    }
}
