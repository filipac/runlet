import Foundation
import RunletCore
@testable import RunletExecution

/// The disposable SSH host from `Tests/Fixtures/docker/compose.yml` (service `ssh` of the
/// `runlet-fixtures` project, 127.0.0.1:2222 only), started on first use.
///
/// Tests never touch the developer's SSH setup: a throwaway ed25519 key is generated per test
/// process, `ssh` gets its own config with `-F` (so `~/.ssh/config` and the system config are
/// not read), its own `known_hosts`, no agent (`IdentityAgent none`, no `SSH_AUTH_SOCK`), and
/// control sockets in a fresh temporary folder.
enum SSHFixture {
    static let project = "runlet-fixtures"
    static let service = "ssh"
    static let port = 2222
    /// The `runletpw` account's password (a fixture value, see ssh/Dockerfile).
    static let password = "runlet-fixture-password"

    static var available: Bool {
        TestSupport.hasDocker && FileManager.default.isExecutableFile(atPath: SSHClient.systemExecutable) && FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen")
    }

    /// Key, config, known_hosts, and control sockets for this test process.
    struct Environment: Sendable {
        let base: URL
        let configFile: String
        let containerId: String
        let controlDirectory: URL

        /// Hosts in the generated config.
        static let keyHost = "runlet-fixture"
        static let passwordHost = "runlet-fixture-pw"
        static let unknownKeyHost = "runlet-fixture-unknown"

        func client(extraOptions: [String] = []) -> SSHClient {
            var environment = ProcessInfo.processInfo.environment
            environment["SSH_AUTH_SOCK"] = nil
            environment["HOME"] = base.path
            return SSHClient(environment: environment, configFile: configFile, extraOptions: extraOptions)
        }

        /// An endpoint with its own control socket (a fresh shared connection).
        func endpoint(host: String = keyHost, authentication: SSHAuthentication = .automatic, keepAliveMinutes: Int? = 1) -> SSHEndpoint {
            SSHEndpoint(host: host, controlPath: SSHControlPaths.socketPath(for: UUID(), in: controlDirectory), authentication: authentication, keepAliveMinutes: keepAliveMinutes)
        }

        func target(_ endpoint: SSHEndpoint, directory: String = "/home/runlet/site/current", php: String = "php") -> TargetSnapshot {
            TargetSnapshot(kind: .ssh, label: "fixture", targetId: "ssh-fixture", workingDirectory: directory, phpExecutable: php, ssh: endpoint)
        }

        func engine(extraOptions: [String] = []) -> ExecutionEngine {
            ExecutionEngine(bundle: TestSupport.bundle, docker: nil, ssh: client(extraOptions: extraOptions))
        }

        /// Installs `Tests/Fixtures/docker/ssh/fake-docker` as the server's `docker` and
        /// describes its made-up containers (see that script for the line format).
        /// It replaces the server's `docker` for everyone: the test holds the fixture alone.
        func installFakeDocker(containers: [String]) async throws {
            Fixtures.use(.ssh, exclusive: true)
            let script = try Data(contentsOf: TestSupport.fixtures.appendingPathComponent("docker/ssh/fake-docker"))
            try await exec("cat > /usr/local/bin/docker && chmod 755 /usr/local/bin/docker", stdin: script)
            try await exec("mkdir -p /etc/runlet-fake-docker && cat > /etc/runlet-fake-docker/containers", stdin: Data((containers.joined(separator: "\n") + "\n").utf8))
        }

        /// Runs `body` with a `~/.cache` for `runlet` (its home belongs to root; without
        /// `create`, with none), and removes it before returning, also when `body` throws. The
        /// removal is awaited: a cleanup left to a `Task` could delete the next test's folder.
        func withHomeCache<T>(create: Bool = true, _ body: () async throws -> T) async throws -> T {
            let clean = "rm -rf /home/runlet/.cache /tmp/runlet-elsewhere.php"
            _ = try await exec(clean + (create ? " && mkdir -p /home/runlet/.cache && chown runlet:runlet /home/runlet/.cache" : ""))
            do {
                let value = try await body()
                _ = try? await exec(clean)
                return value
            } catch {
                _ = try? await exec(clean)
                throw error
            }
        }

        /// Runs a shell command as root inside the fixture container (`arguments` are `$1`…).
        @discardableResult
        func exec(_ command: String, stdin: Data? = nil, arguments: [String] = []) async throws -> String {
            let docker = try require2(TestSupport.docker)
            let result = try await runCommand(docker.spec(["exec", "-i", containerId, "sh", "-c", command, "sh"] + arguments, stdin: stdin), timeout: .seconds(30))
            guard result.exitCode == 0 else {
                throw DockerError("fixture command failed (\(result.exitCode)): \(String(decoding: result.stderr, as: UTF8.self))")
            }
            return String(decoding: result.stdout, as: UTF8.self)
        }
    }

    private static let shared = SharedEnvironment()

    /// Starts the fixture if needed and prepares this process's key and config (once). The test
    /// needs `.live(.ssh)` (#242).
    static func environment() async throws -> Environment {
        Fixtures.use(.ssh)
        return try await shared.get()
    }

    private actor SharedEnvironment {
        private var task: Task<Environment, Error>?

        func get() async throws -> Environment {
            if let task { return try await task.value }
            let task = Task { try await SSHFixture.prepare() }
            self.task = task
            return try await task.value
        }
    }

    private static func prepare() async throws -> Environment {
        let docker = try require2(TestSupport.docker)
        var container = try await docker.runningContainers().first { $0.composeProject == project && $0.composeService == service }
        if container == nil {
            let compose = TestSupport.fixtures.appendingPathComponent("docker/compose.yml").path
            try await docker.run(["compose", "-p", project, "-f", compose, "up", "-d", service], timeout: .seconds(900))
            container = try await docker.runningContainers().first { $0.composeProject == project && $0.composeService == service }
        }
        let containerId = try require2(container?.id)

        let base = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-ssh-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let key = base.appendingPathComponent("id_ed25519")
        let keygen = try await runCommand(ProcessSpec(executable: "/usr/bin/ssh-keygen", arguments: ["-q", "-t", "ed25519", "-N", "", "-C", "runlet-ssh-tests", "-f", key.path]), timeout: .seconds(20))
        guard keygen.exitCode == 0 else { throw DockerError("ssh-keygen failed: \(String(decoding: keygen.stderr, as: UTF8.self))") }

        // Wait for sshd to have created its host keys.
        var hostKey = ""
        for _ in 0..<100 {
            if let result = try? await runCommand(docker.spec(["exec", containerId, "cat", "/etc/ssh/ssh_host_ed25519_key.pub"]), timeout: .seconds(10)), result.exitCode == 0 {
                hostKey = String(decoding: result.stdout, as: UTF8.self).split(separator: " ").prefix(2).joined(separator: " ")
                if !hostKey.isEmpty { break }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard !hostKey.isEmpty else { throw DockerError("the SSH fixture has no host key") }

        let environment = Environment(base: base, configFile: base.appendingPathComponent("config").path, containerId: containerId,
                                      controlDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("rlt-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true))
        _ = try await environment.exec("cat > /home/runlet/.ssh/authorized_keys && chown runlet:runlet /home/runlet/.ssh/authorized_keys && chmod 600 /home/runlet/.ssh/authorized_keys",
                                       stdin: try Data(contentsOf: key.appendingPathExtension("pub")))

        let knownHosts = base.appendingPathComponent("known_hosts")
        try Data("[127.0.0.1]:\(port) \(hostKey)\n".utf8).write(to: knownHosts)
        let emptyKnownHosts = base.appendingPathComponent("known_hosts_empty")
        try Data().write(to: emptyKnownHosts)
        let config = """
        Host \(Environment.keyHost)
            HostName 127.0.0.1
            Port \(port)
            User runlet
            IdentityFile \(key.path)
            IdentitiesOnly yes
            IdentityAgent none
            PasswordAuthentication no
            UserKnownHostsFile \(knownHosts.path)
            GlobalKnownHostsFile /dev/null

        Host \(Environment.passwordHost)
            HostName 127.0.0.1
            Port \(port)
            User runletpw
            PubkeyAuthentication no
            IdentityAgent none
            UserKnownHostsFile \(knownHosts.path)
            GlobalKnownHostsFile /dev/null

        Host \(Environment.unknownKeyHost)
            HostName 127.0.0.1
            Port \(port)
            User runlet
            IdentityFile \(key.path)
            IdentitiesOnly yes
            IdentityAgent none
            UserKnownHostsFile \(emptyKnownHosts.path)
            GlobalKnownHostsFile /dev/null

        """
        try Data(config.utf8).write(to: URL(fileURLWithPath: environment.configFile))

        // sshd may still be starting: wait until a key login works.
        let probe = environment.endpoint(keepAliveMinutes: nil)
        let client = environment.client()
        for attempt in 0..<60 {
            if let result = try? await client.run(probe, remoteCommand: "true", timeout: .seconds(10)), result.exitCode == 0 { break }
            if attempt == 59 { throw DockerError("the SSH fixture does not accept the test key") }
            try await Task.sleep(for: .milliseconds(250))
        }
        await client.disconnect(probe)
        return environment
    }
}

/// `#require` for helpers outside a test body.
func require2<T>(_ value: T?, _ message: String = "missing value") throws -> T {
    guard let value else { throw DockerError(message) }
    return value
}
