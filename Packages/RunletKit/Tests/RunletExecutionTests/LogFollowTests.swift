import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// The log viewer's remote follows (#20): the command lines, and live follows that stop
/// cleanly, leaving no process behind on either side: a shell on this Mac, `docker logs` and
/// `docker exec … tail -F` in the runlet-fixtures Laravel container, and `ssh … tail -F` on the
/// runlet-fixtures SSH host.
@Suite(.serialized) struct LogFollowTests {
    @Test func commandLines() {
        #expect(LogFollowCommand.stopsWithInput("tail -F x") == "exec 3<&0; tail -F x <&- & p=$!; { cat <&3 >/dev/null; kill $p 2>/dev/null; } >/dev/null 2>&1 & wait $p")
        #expect(LogFollowCommand.tailScript(path: "/var/www/html/storage/logs/laravel.log", lines: 200)
            == "exec 3<&0; tail -n 200 -F -- /var/www/html/storage/logs/laravel.log <&- & p=$!; { cat <&3 >/dev/null; kill $p 2>/dev/null; } >/dev/null 2>&1 & wait $p")
        // Paths are quoted: nothing in them reaches the shell.
        #expect(LogFollowCommand.tailScript(path: "/srv/my logs/a'b.log").contains(#"-- '/srv/my logs/a'\''b.log' <&-"#))
        #expect(LogFollowCommand.dockerLogsArguments(container: "abc") == ["logs", "--follow", "--tail", "500", "abc"])
        #expect(LogFollowCommand.dockerExecTailArguments(container: "abc", user: "sail", path: "/app/x.log", lines: 10)
            == ["exec", "-i", "--user", "sail", "abc", "/bin/sh", "-c", LogFollowCommand.tailScript(path: "/app/x.log", lines: 10)])
        #expect(LogFollowCommand.dockerExecTailArguments(container: "abc", user: nil, path: "/app/x.log").prefix(3) == ["exec", "-i", "abc"])
        #expect(LogFollowCommand.sshTailCommand(path: "/home/forge/site/storage/logs/laravel.log", lines: 5)
            == "/bin/sh -c " + RemoteShell.quote(LogFollowCommand.tailScript(path: "/home/forge/site/storage/logs/laravel.log", lines: 5)))
        let inContainer = LogFollowCommand.sshDockerTailCommand(dockerCommand: "sudo -n docker", container: "c1", user: nil, path: "/app/x.log", lines: 5)
        #expect(inContainer.hasPrefix("/bin/sh -c 'exec sudo -n docker exec -i c1 /bin/sh -c "))
        let output = LogFollowCommand.sshDockerLogsCommand(dockerCommand: "docker", container: "c1", lines: 5)
        #expect(output == "/bin/sh -c " + RemoteShell.quote(LogFollowCommand.stopsWithInput("docker logs --follow --tail 5 c1")))
        let find = LogFollowCommand.findScript(directory: "/srv/app/", extra: ["logs/custom"])
        #expect(find.contains("/srv/app/storage/logs /srv/app/var/log /srv/app/logs/custom"))
        #expect(find.contains("/srv/app/wp-content/debug.log"))
        #expect(LogFollowCommand.parseFound("/a/b.log\nnoise\n /c.log \n") == ["/a/b.log", "/c.log"])
    }

    @Test func linesArriveWhole() {
        var lines = LineAssembler()
        #expect(lines.add(Data("one\ntw".utf8)) == Data("one\n".utf8))
        #expect(lines.add(Data("o".utf8)) == nil)
        #expect(lines.add(Data("\nthree".utf8)) == Data("two\n".utf8))
        #expect(lines.flush() == Data("three\n".utf8))
        #expect(lines.flush() == nil)
    }

    /// Collects a follower's events.
    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [LogProcessFollower.Event] = []
        func add(_ event: LogProcessFollower.Event) { lock.withLock { events.append(event) } }
        var all: [LogProcessFollower.Event] { lock.withLock { events } }
        var text: String {
            all.compactMap { if case .output(let data) = $0 { String(decoding: data, as: UTF8.self) } else { nil } }.joined()
        }

        func wait(for text: String, timeout: TimeInterval = 20) async {
            let deadline = Date().addingTimeInterval(timeout)
            while !self.text.contains(text), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        }
    }

    /// Process ids on this Mac whose command line contains `marker`.
    static func localProcesses(_ marker: String) async throws -> [String] {
        let result = try await runCommand(ProcessSpec(executable: "/usr/bin/pgrep", arguments: ["-f", marker]), timeout: .seconds(5))
        return String(decoding: result.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    }

    /// The stop-with-input script on this Mac's /bin/sh: Stop closes the input, and the shell
    /// kills its `tail`.
    @Test func aLocalShellFollowEndsItsTail() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-follow-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("app.log").path
        try Data("[2026-10-04 10:00:00] app.INFO: before []\n".utf8).write(to: URL(fileURLWithPath: path))
        let events = Events()
        let follower = try LogProcessFollower(spec: ProcessSpec(executable: "/bin/sh", arguments: ["-c", LogFollowCommand.tailScript(path: path, lines: 10)]),
                                              stderrIsLog: false, deliveryQueue: DispatchQueue(label: "test.local-follow")) { events.add($0) }
        await events.wait(for: "before")
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("[2026-10-04 10:00:01] app.ERROR: during []\n".utf8))
        try handle.close()
        await events.wait(for: "during")
        #expect(events.text.contains("before") && events.text.contains("during"))
        #expect(try await Self.localProcesses(path).count >= 1)
        await follower.stop()
        #expect(!follower.isRunning)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await Self.localProcesses(path).isEmpty, "a tail is still running")
        #expect(!events.all.contains { if case .ended = $0 { true } else { false } })
    }

    // MARK: Docker (runlet-fixtures)

    static func laravelContainer() async throws -> (DockerCLI, String)? {
        guard let docker = TestSupport.docker else { return nil }
        guard let container = try await docker.runningContainers().first(where: { $0.composeProject == "runlet-fixtures" && $0.composeService == "laravel" }) else { return nil }
        return (docker, container.id)
    }

    /// Processes in the container whose command line contains `marker` (from /proc: the image
    /// has no `ps`).
    static func containerProcesses(_ docker: DockerCLI, _ container: String, _ marker: String) async throws -> [String] {
        let data = try await docker.run(["exec", container, "sh", "-c", processScan] + split(marker))
        return lines(data)
    }

    /// Lists processes whose command line contains `$1$2`. The marker comes in two halves, so
    /// the scanning shell's own command line never matches, and only shell built-ins compare.
    static let processScan = #"m="$1$2"; for f in /proc/[0-9]*/cmdline; do c=$(tr '\0' ' ' < "$f" 2>/dev/null) || continue; case "$c" in *"$m"*) echo "${f%/cmdline} $c";; esac; done; true"#

    static func split(_ marker: String) -> [String] {
        ["sh", String(marker.prefix(8)), String(marker.dropFirst(8))]
    }

    static func lines(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("/proc/self") }
    }

    @Test(.live(.docker), .enabled(if: TestSupport.hasDocker, "requires a running Docker engine"))
    func dockerExecTailFollowsAndStopsInTheContainer() async throws {
        guard let (docker, container) = try await Self.laravelContainer() else {
            Issue.record("the runlet-fixtures laravel container isn't running")
            return
        }
        let path = "/tmp/runlet-log-follow-\(UUID().uuidString.prefix(8)).log"
        try await docker.run(["exec", container, "sh", "-c", "printf '%s\\n' '[2026-10-04 10:00:00] local.INFO: first []' > \"$1\"", "sh", path])
        defer { Task { _ = try? await docker.run(["exec", container, "rm", "-f", path]) } }
        let events = Events()
        let follower = try LogProcessFollower(spec: docker.spec(LogFollowCommand.dockerExecTailArguments(container: container, user: nil, path: path, lines: 50)),
                                              stderrIsLog: false, deliveryQueue: DispatchQueue(label: "test.docker-tail")) { events.add($0) }
        await events.wait(for: "first")
        try await docker.run(["exec", container, "sh", "-c", "printf '%s\\n' '[2026-10-04 10:00:01] local.ERROR: second []' >> \"$1\"", "sh", path])
        await events.wait(for: "second")
        #expect(events.text.contains("local.INFO: first") && events.text.contains("local.ERROR: second"), "\(events.all)")
        #expect(try await Self.containerProcesses(docker, container, path).count >= 1)
        await follower.stop()
        #expect(!follower.isRunning)
        var left: [String] = []
        for _ in 0..<20 {
            left = try await Self.containerProcesses(docker, container, path)
            if left.isEmpty { break }
            try await Task.sleep(for: .milliseconds(150))
        }
        #expect(left.isEmpty, "tail is still running in the container: \(left)")
    }

    @Test(.live(.docker), .enabled(if: TestSupport.hasDocker, "requires a running Docker engine"))
    func dockerLogsFollowsTheContainersOutput() async throws {
        guard let (docker, container) = try await Self.laravelContainer() else {
            Issue.record("the runlet-fixtures laravel container isn't running")
            return
        }
        let marker = "runlet-log-follow-\(UUID().uuidString.prefix(8))"
        let events = Events()
        let follower = try LogProcessFollower(spec: docker.spec(LogFollowCommand.dockerLogsArguments(container: container, lines: 5)),
                                              stderrIsLog: true, deliveryQueue: DispatchQueue(label: "test.docker-logs")) { events.add($0) }
        try await Task.sleep(for: .milliseconds(500))
        // What the container's main process prints: standard output and standard error.
        try await docker.run(["exec", container, "sh", "-c", "echo \"[2026-10-04 10:00:00] local.WARNING: $1 out []\" > /proc/1/fd/1; echo \"$1 err\" > /proc/1/fd/2", "sh", marker])
        await events.wait(for: "\(marker) err")
        await events.wait(for: "\(marker) out")
        #expect(events.text.contains("local.WARNING: \(marker) out"), "\(events.all)")
        #expect(events.text.contains("\(marker) err"))
        let pid = follower.process.pid
        await follower.stop()
        #expect(!follower.isRunning)
        #expect(kill(pid, 0) != 0, "the docker logs client is still running")
    }

    // MARK: SSH (runlet-fixtures)

    @Test(.live(.ssh), .enabled(if: SSHFixture.available, "requires Docker and the system ssh client"))
    func sshTailFollowsAndStopsOnTheServer() async throws {
        let fixture = try await SSHFixture.environment()
        let client = fixture.client()
        let endpoint = fixture.endpoint()
        defer { Task { await client.disconnect(endpoint) } }
        let path = "/tmp/runlet-log-follow-\(UUID().uuidString.prefix(8)).log"
        try await fixture.exec("printf '%s\\n' '[2026-10-04 10:00:00] production.INFO: on the server []' > \"$1\" && chown runlet \"$1\"", arguments: [path])
        defer { Task { _ = try? await fixture.exec("rm -f \"$1\"", arguments: [path]) } }
        try SSHControlPaths.prepareDirectory(for: endpoint.controlPath)
        let events = Events()
        let follower = try LogProcessFollower(spec: client.spec(endpoint, remoteCommand: LogFollowCommand.sshTailCommand(path: path, lines: 20)), stderrIsLog: false,
                                              explain: { output, code in SSHFailure.explain(output, exitCode: code, host: endpoint.displayName) },
                                              deliveryQueue: DispatchQueue(label: "test.ssh-tail")) { events.add($0) }
        await events.wait(for: "on the server")
        try await fixture.exec("printf '%s\\n' '[2026-10-04 10:00:01] production.CRITICAL: still there []' >> \"$1\"", arguments: [path])
        await events.wait(for: "still there")
        #expect(events.text.contains("production.INFO: on the server") && events.text.contains("production.CRITICAL: still there"), "\(events.all)")
        func remote() async throws -> [String] {
            Self.lines(Data(try await fixture.exec(Self.processScan, arguments: Array(Self.split(path).dropFirst())).utf8))
        }
        #expect(try await remote().count >= 1)
        let pid = follower.process.pid
        await follower.stop()
        #expect(!follower.isRunning)
        #expect(kill(pid, 0) != 0, "the local ssh is still running")
        var left: [String] = []
        for _ in 0..<20 {
            left = try await remote()
            if left.isEmpty { break }
            try await Task.sleep(for: .milliseconds(150))
        }
        #expect(left.isEmpty, "tail is still running on the server: \(left)")
        // The shared connection stays for the profile's other work.
        #expect(client.status(endpoint) == .connected)
    }

    @Test(.live(.ssh), .enabled(if: SSHFixture.available, "requires Docker and the system ssh client"))
    func sshFindListsLogFiles() async throws {
        let fixture = try await SSHFixture.environment()
        let client = fixture.client()
        let endpoint = fixture.endpoint()
        defer { Task { await client.disconnect(endpoint) } }
        let base = "/tmp/runlet-find-\(UUID().uuidString.prefix(8))"
        try await fixture.exec("mkdir -p \"$1/storage/logs/2026\" \"$1/wp-content\" && touch \"$1/storage/logs/laravel.log\" \"$1/storage/logs/2026/daily.log\" \"$1/storage/logs/notes.txt\" \"$1/wp-content/debug.log\" && chown -R runlet \"$1\"", arguments: [base])
        defer { Task { _ = try? await fixture.exec("rm -rf \"$1\"", arguments: [base]) } }
        let result = try await client.run(endpoint, remoteCommand: RemoteShell.command(LogFollowCommand.findScript(directory: base)))
        #expect(result.exitCode == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
        let found = Set(LogFollowCommand.parseFound(String(decoding: result.stdout, as: UTF8.self)))
        #expect(found == ["\(base)/storage/logs/laravel.log", "\(base)/storage/logs/2026/daily.log", "\(base)/wp-content/debug.log"])
    }
}
