import Darwin
import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// SSH pieces that need no server: arguments, quoting, failure messages, control sockets.
struct SSHUnitTests {
    let endpoint = SSHEndpoint(host: "app-prod", controlPath: "/tmp/rl/abcd1234.sock")

    @Test func batchArgumentsNeverPromptAndNeverAcceptHostKeys() {
        let client = SSHClient(environment: ["PATH": "/usr/bin", "SSH_ASKPASS": "/x", "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": ":0"])
        #expect(client.environment["SSH_ASKPASS"] == nil && client.environment["SSH_ASKPASS_REQUIRE"] == nil && client.environment["DISPLAY"] == nil)
        let arguments = client.arguments(for: endpoint, purpose: .batch, remoteCommand: "/bin/sh -c true")
        #expect(!arguments.contains("-F"), "the user's ~/.ssh/config always applies")
        for option in ["BatchMode=yes", "StrictHostKeyChecking=yes", "LogLevel=ERROR", "ControlMaster=auto", "ControlPersist=10m", "ServerAliveInterval=15", "ServerAliveCountMax=3", "ConnectTimeout=10", "ClearAllForwardings=yes"] {
            #expect(arguments.contains(option), "\(option)")
        }
        #expect(arguments.contains("-T") && arguments.contains("-C"))
        #expect(arguments.suffix(3) == ["--", "app-prod", "/bin/sh -c true"])
        #expect(arguments[arguments.firstIndex(of: "-S")! + 1] == endpoint.controlPath)

        var interactive = endpoint
        interactive.authentication = .interactive
        interactive.compression = false
        interactive.user = "deploy"
        interactive.port = 2200
        interactive.jumpHost = "bastion"
        let reuse = client.arguments(for: interactive, purpose: .batch)
        #expect(reuse.contains("ControlMaster=no") && !reuse.contains("ControlMaster=auto"), "runs never log in for interactive profiles")
        #expect(!reuse.contains("-C"))
        #expect(Array(reuse.suffix(8)) == ["-l", "deploy", "-p", "2200", "-J", "bastion", "--", "app-prod"])

        var untilDisconnect = endpoint
        untilDisconnect.keepAliveMinutes = nil
        #expect(client.arguments(for: untilDisconnect, purpose: .batch).contains("ControlPersist=yes"))
    }

    @Test func connectAndControlArguments() {
        let client = SSHClient(environment: [:])
        let connect = client.arguments(for: endpoint, purpose: .connect)
        for option in ["-M", "-N", "-f", "ControlPersist=yes", "StrictHostKeyChecking=ask", "BatchMode=no"] {
            #expect(connect.contains(option), "\(option)")
        }
        #expect(!connect.contains("BatchMode=yes"))
        let exit = client.arguments(for: endpoint, purpose: .control("exit"))
        #expect(exit.contains("-O") && exit[exit.firstIndex(of: "-O")! + 1] == "exit")
        let test = SSHClient(environment: [:], configFile: "/tmp/cfg", extraOptions: ["-o", "ServerAliveInterval=1"])
        #expect(Array(test.arguments(for: endpoint, purpose: .batch).prefix(4)) == ["-F", "/tmp/cfg", "-o", "ServerAliveInterval=1"], "test options come first, so they win")
    }

    /// The remote command goes through two shells (the login shell, then /bin/sh); words must
    /// arrive unchanged. Emulated here with local shells.
    @Test func remoteCommandsSurviveLoginShells() async throws {
        let words = ["plain", "it's", "a \"b\" c", "$HOME", "`id`", "back\\slash", "new\nline", "ünïcödé", "!bang", "*"]
        let script = "printf '%s|' " + words.map(RemoteShell.quote).joined(separator: " ")
        let command = RemoteShell.command(script)
        for shell in ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash"] where FileManager.default.isExecutableFile(atPath: shell) {
            let result = try await runCommand(ProcessSpec(executable: shell, arguments: ["-c", command], environment: ["PATH": "/usr/bin:/bin", "HOME": "/nowhere"]))
            #expect(String(decoding: result.stdout, as: UTF8.self) == words.map { $0 + "|" }.joined(), "\(shell)")
        }
        let inline = RemoteShell.inlinePHP("echo \"it's\\n\";")
        #expect(inline.range(of: #"^eval\(base64_decode\("[A-Za-z0-9+/=]+"\)\);$"#, options: .regularExpression) != nil)
    }

    @Test func runScriptChecksTheDirectoryAndExecsPHP() {
        let runId = UUID()
        let script = RemoteShell.runScript(directory: "/home/forge/my app/current", php: "/usr/bin/php8.3", runId: runId)
        #expect(script.hasPrefix("cd '/home/forge/my app/current' 2>/dev/null || {"))
        #expect(script.contains("RUNLET_RUN_ID=\(runId.uuidString); export RUNLET_RUN_ID;"))
        #expect(script.hasSuffix("exec /usr/bin/php8.3 -d display_errors=stderr -d html_errors=0 -d log_errors=0"))
    }

    @Test func failuresGetPlainExplanations() {
        func explain(_ output: String, _ code: Int32 = 255, afterStart: Bool = false) -> String? {
            SSHFailure.explain(output, exitCode: code, host: "app-prod", directory: "/srv/app", php: "php8.3", afterStart: afterStart)
        }
        #expect(explain("No ED25519 host key is known for app-prod and you have requested strict checking.\r\nHost key verification failed.")?.contains("never accepts a host key") == true)
        #expect(explain("@@@@@\r\n@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\r\nHost key verification failed.")?.contains("won't connect") == true)
        #expect(explain("deploy@app-prod: Permission denied (publickey,password).")?.contains("Password / 2FA") == true)
        #expect(explain("ssh: Could not resolve hostname app-prod: nodename nor servname provided, or not known")?.contains("could not be resolved") == true)
        #expect(explain("ssh: connect to host 10.0.0.1 port 22: Operation timed out")?.contains("couldn't reach") == true)
        #expect(explain("ssh: connect to host 10.0.0.1 port 22: Connection refused")?.contains("refused") == true)
        #expect(explain("Control socket connect(/x.sock): No such file or directory")?.contains("Connect… to log in again") == true)
        #expect(explain(RemoteShell.missingDirectoryMarker, 2)?.contains("/srv/app doesn't exist on app-prod") == true)
        #expect(explain("sh: 1: exec: php8.3: not found", 127)?.contains("PHP was not found as “php8.3”") == true)
        #expect(explain("Timeout, server not responding.", afterStart: true)?.contains("was lost") == true)
        #expect(explain("", afterStart: true)?.contains("connection was lost") == true)
        #expect(explain("PHP Warning: x", 1, afterStart: true) == nil, "PHP's own failures keep the default message")
        #expect(explain("anything", 1) == nil)
        // The original output is kept below the explanation.
        #expect(explain("ssh: Could not resolve hostname app-prod")?.hasSuffix("ssh: Could not resolve hostname app-prod") == true)
    }

    @Test func controlSocketStatusIsCheckedLocally() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rlu-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path
        #expect(SSHControlSocket.status(at: path) == .disconnected)

        // A listening Unix socket counts as connected…
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            let bytes = Array(path.utf8)
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        #expect(bound == 0)
        #expect(listen(server, 4) == 0)
        #expect(SSHControlSocket.status(at: path) == .connected)
        #expect(!SSHControlSocket.removeIfStale(at: path))
        // …and a socket file nobody listens on is a stale (expired) one, which can be removed.
        close(server)
        // Under load the closed listener can take a moment to stop accepting connections.
        for _ in 0..<50 where SSHControlSocket.status(at: path) != .expired { usleep(20_000) }
        #expect(SSHControlSocket.status(at: path) == .expired)
        #expect(SSHControlSocket.removeIfStale(at: path))
        #expect(SSHControlSocket.status(at: path) == .disconnected)
    }

    @Test func configAliasesFollowIncludesAndSkipPatterns() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-sshcfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("conf.d"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("""
        # comment
        Include conf.d/*.conf
        Host app-prod app-staging *.internal !nope
            HostName 10.0.0.1
        Host=bastion
        Match host foo
            User x
        host "quoted alias"
        Host app-prod

        """.utf8).write(to: directory.appendingPathComponent("config"))
        try Data("Host forge-site\n  HostName 1.2.3.4\nInclude ../config\n".utf8).write(to: directory.appendingPathComponent("conf.d/forge.conf"))
        let aliases = SSHConfigHosts.aliases(in: directory.appendingPathComponent("config"), sshDirectory: directory)
        #expect(aliases == ["forge-site", "app-prod", "app-staging", "bastion", "quoted alias"])
        #expect(SSHConfigHosts.aliases(in: directory.appendingPathComponent("missing")) == [])
    }

    @Test func importingConfigHostsGuessesTheEnvironmentAndReadsSSHG() async throws {
        #expect(SSHHostImport.likelyEnvironment(alias: "app-prod") == .production)
        #expect(SSHHostImport.likelyEnvironment(alias: "shop", hostname: "live.shop.example.com") == .production)
        #expect(SSHHostImport.likelyEnvironment(alias: "PRD_db1") == .production)
        #expect(SSHHostImport.likelyEnvironment(alias: "app-staging") == .staging)
        #expect(SSHHostImport.likelyEnvironment(alias: "shop-preprod") == .staging, "preprod is staging, not production")
        #expect(SSHHostImport.likelyEnvironment(alias: "product-api", hostname: "10.0.0.5") == .development, "whole words only")
        #expect(SSHHostImport.newAliases(["a", "b", "c"], existingHosts: ["b"]) == ["a", "c"])
        let profile = SSHHostImport.profile(alias: "forge-site", directory: " /home/forge/site/current/ ", environment: .production)
        #expect(profile.name == "forge-site" && profile.host == "forge-site" && profile.remoteDirectory == "/home/forge/site/current" && profile.environment == .production)
        #expect(profile.validate().isEmpty)
        #expect(SSHHostImport.profile(alias: "x", directory: "", environment: .development).validate() == [.missingRemoteDirectory])

        // `ssh -G` with a test config (`-F`): reads the file, connects nowhere.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-sshg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config")
        try Data("Host forge-site\n  HostName 203.0.113.7\n  User forge\n  Port 2200\n  ProxyJump bastion\n".utf8).write(to: config)
        let client = SSHClient(environment: ["PATH": "/usr/bin:/bin", "HOME": directory.path], configFile: config.path)
        let values = try #require(await client.effectiveConfiguration(host: "forge-site"))
        #expect(values["hostname"] == "203.0.113.7" && values["user"] == "forge" && values["port"] == "2200" && values["proxyjump"] == "bastion")
    }

    @Test func controlPathsStayShortAndPrivate() throws {
        let id = UUID(uuidString: "ABCDEF12-3456-7890-ABCD-EF1234567890")!
        let short = URL(fileURLWithPath: "/Users/dev/Library/Application Support/Runlet/SSH")
        #expect(SSHControlPaths.socketPath(for: id, in: short) == "/Users/dev/Library/Application Support/Runlet/SSH/abcdef12.sock")
        let long = URL(fileURLWithPath: "/Users/dev/" + String(repeating: "deep/", count: 20))
        let fallback = SSHControlPaths.socketPath(for: id, in: long)
        #expect(fallback.hasPrefix(SSHControlPaths.fallbackDirectory.path))
        #expect(fallback.utf8.count <= 104 - 1 - 17)

        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rlp-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: directory) }
        try SSHControlPaths.prepareDirectory(for: directory.appendingPathComponent("x.sock").path)
        let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }
}

struct KeepCompiledPHPScriptTests {
    @Test func scriptAddsTheFileCacheOnlyWhenAsked() {
        let runId = UUID()
        let plain = RemoteShell.runScript(directory: "/srv/app", php: "php8.4", runId: runId)
        #expect(!plain.contains("opcache"))
        let cached = RemoteShell.runScript(directory: "/srv/app", php: "php8.4", runId: runId, keepCompiledPHP: true)
        #expect(cached.contains(#"d="${HOME:-/tmp}/.cache/runlet/opcache""#))
        #expect(cached.contains("-d opcache.file_cache_only=1"))
        #expect(cached.contains(#"exec php8.4 "$@" -d display_errors=stderr"#))
    }
}
