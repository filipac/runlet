import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// Open REPL (N19, #32): which REPL a target gets, and the exact terminal request per target
/// kind. The selection script is run for real with `sh` and `dash` against folders laid out
/// like projects, with a stand-in PHP that reports how it was started.
struct ProjectREPLTests {
    /// A folder with `files` (relative paths; a trailing `/` makes a directory).
    static func project(_ files: [String], name: String = "app") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-repl-\(UUID().uuidString.prefix(8))", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in files {
            let url = root.appendingPathComponent(file)
            if file.hasSuffix("/") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("<?php\n".utf8).write(to: url)
            }
        }
        return root
    }

    /// A stand-in PHP at a path with a space and a quote: prints its arguments and directory.
    static func fakePHP() throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-repl-php \(UUID().uuidString.prefix(6))/it's \"php\"", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let php = folder.appendingPathComponent("php")
        try Data("#!/bin/sh\necho \"PHP-ARGS[$*] PWD[$(pwd)]\"\n".utf8).write(to: php)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: php.path)
        return php.path
    }

    /// Runs `script` with `shell` in `directory`; stdout and stderr.
    static func run(_ script: String, shell: String = "/bin/sh", in directory: URL) throws -> (stdout: String, stderr: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", script]
        process.currentDirectoryURL = directory
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": directory.path]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        return (String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), process.terminationStatus)
    }

    static let layouts: [(files: [String], kind: ProjectREPL.Kind)] = [
        ([], .phpShell),
        (["composer.json", "vendor/autoload.php"], .phpShell),
        (["vendor/bin/psysh"], .psysh),
        // Laravel with laravel/tinker installed (it brings PsySH along).
        (["artisan", "bootstrap/app.php", "vendor/laravel/tinker/", "vendor/bin/psysh"], .tinker),
        // Laravel without laravel/tinker: `artisan tinker` would fail, so PsySH or `php -a`.
        (["artisan", "vendor/bin/psysh"], .psysh),
        (["artisan"], .phpShell),
        // Only real files and folders count.
        (["artisan/", "vendor/laravel/tinker/", "vendor/bin/psysh/"], .phpShell),
        (["artisan", "vendor/laravel/tinker"], .phpShell),
    ]

    @Test func kindFollowsTheProjectsFiles() throws {
        for layout in Self.layouts {
            let root = try Self.project(layout.files)
            #expect(ProjectREPL.kind(projectDirectory: root.path) == layout.kind, "\(layout.files)")
        }
        #expect(ProjectREPL.kind(projectDirectory: "/nonexistent/runlet-repl") == .phpShell)
        // The bundled sandbox is a Laravel app with laravel/tinker (once its vendor/ is built).
        let sandbox = TestSupport.repoRoot.appendingPathComponent("Resources/Sandbox/laravel")
        if FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("vendor/laravel/tinker").path) {
            #expect(ProjectREPL.kind(projectDirectory: sandbox.path) == .tinker)
        }
        #expect(ProjectREPL.kind(projectDirectory: TestSupport.fixtures.appendingPathComponent("plain").path) == .phpShell)
        #expect(ProjectREPL.Kind.tinker.commandLine == "php artisan tinker")
        #expect(ProjectREPL.Kind.psysh.commandLine == "php vendor/bin/psysh")
        #expect(ProjectREPL.Kind.phpShell.commandLine == "php -a")
        #expect(ProjectREPL.Kind.phpShell.displayName == "PHP interactive shell")
    }

    /// The script Docker and SSH targets run chooses exactly like the check on this Mac, under
    /// bash's `sh` and under `dash` (Debian and Ubuntu's `/bin/sh`), and sets the tab title.
    @Test func selectionScriptChoosesLikeTheCheckOnThisMac() throws {
        let php = try Self.fakePHP()
        let place = "it's \"odd\" $HOME `x`"
        let script = ProjectREPL.selectionScript(php: php, place: place)
        let shells = ["/bin/sh", "/bin/dash"].filter { FileManager.default.isExecutableFile(atPath: $0) }
        for shell in shells {
            for layout in Self.layouts {
                let root = try Self.project(layout.files)
                let result = try Self.run(script, shell: shell, in: root)
                let arguments = layout.kind.phpArguments.joined(separator: " ")
                #expect(result.status == 0, "\(shell) \(layout.files): \(result.stderr)")
                // In the project's directory (`pwd` may report /private/var for /var).
                let folder = root.deletingLastPathComponent().lastPathComponent + "/" + root.lastPathComponent
                #expect(result.stdout.contains("PHP-ARGS[\(arguments)] PWD[") && result.stdout.contains("\(folder)]"), "\(shell) \(layout.files): \(result.stdout)")
                #expect(result.stdout.hasPrefix("\u{1b}]2;\(layout.kind.shortName) · \(place)\u{07}"), "\(shell): the title, unexpanded: \(result.stdout.debugDescription)")
                #expect(result.stderr.contains("no Tinker or PsySH") == (layout.kind == .phpShell), "\(shell) \(layout.files): \(result.stderr)")
                #expect(ProjectREPL.kind(projectDirectory: root.path) == layout.kind)
            }
        }
    }

    @Test func localAndSandboxTargetsTypeTheREPLInTheProjectFolder() throws {
        let php = "/Users/me/PHP's bin/php 8.4"
        let target = TargetSnapshot(kind: .local, label: "app", targetId: "x", workingDirectory: "/Users/me/Code/acme shop", phpExecutable: php)
        let request = try ProjectREPL.terminalRequest(target: target, kind: .tinker, place: "acme shop", dockerExecutable: nil)
        #expect(request.title == "Tinker · acme shop")
        #expect(request.workingDirectory == "/Users/me/Code/acme shop", "the shell starts there: the folder is never typed")
        #expect(request.commandLine == #"'/Users/me/PHP'\''s bin/php 8.4' artisan tinker"#)
        #expect(try ProjectCommandLauncherTests.shellWords(try #require(request.commandLine)) == [php, "artisan", "tinker"])
        #expect(request.executable == nil && request.runsCommandLine)
        #expect(request.isCommand, "the tab stays open after the REPL exits")

        // Without a kind, the project's files on this Mac decide; a PATH `php` stays as typed.
        let psysh = try Self.project(["vendor/bin/psysh"], name: "it's a \"project\"")
        let sandbox = TargetSnapshot(kind: .sandboxLocal, label: "sandbox", targetId: "sandbox", workingDirectory: psysh.path, phpExecutable: "php")
        let found = try ProjectREPL.terminalRequest(target: sandbox, place: "Sandbox", dockerExecutable: nil)
        #expect(found.title == "PsySH · Sandbox")
        #expect(found.commandLine == "php vendor/bin/psysh")
        #expect(found.workingDirectory == psysh.path)
        let shell = try ProjectREPL.terminalRequest(target: TargetSnapshot(kind: .local, label: "x", targetId: "x", workingDirectory: try Self.project([]).path, phpExecutable: "/opt/php/bin/php"), place: "x", dockerExecutable: nil)
        #expect(shell.title == "PHP shell · x")
        #expect(shell.commandLine == "/opt/php/bin/php -a")
    }

    @Test func dockerProfilesChooseInTheResolvedContainer() throws {
        let target = TargetSnapshot(kind: .docker, label: "api", targetId: "p", workingDirectory: "/var/www/my app", phpExecutable: "/usr/local/bin/php", containerId: "abc123", containerName: "api-1", user: "www-data", temporaryDirectory: "/scratch")
        let request = try ProjectREPL.terminalRequest(target: target, kind: .tinker, place: "api", dockerExecutable: "/usr/local/bin/docker")
        let script = ProjectREPL.selectionScript(php: "/usr/local/bin/php", place: "api")
        #expect(request.executable == ["/usr/local/bin/docker", "exec", "-it", "--user", "www-data", "--env", "TMPDIR=/scratch", "-w", "/var/www/my app", "abc123", "sh", "-lc", script], "the container chooses, whatever this Mac guessed")
        #expect(request.title == "REPL · api", "until the script sets the exact title")
        #expect(request.commandLine == nil && request.isCommand)

        var bare = target
        bare.user = nil
        bare.temporaryDirectory = nil
        #expect(try ProjectREPL.terminalRequest(target: bare, place: "api", dockerExecutable: "docker").executable == ["docker", "exec", "-it", "-w", "/var/www/my app", "abc123", "sh", "-lc", script])
        bare.containerId = nil
        #expect(throws: ExecutionError.self) { try ProjectREPL.terminalRequest(target: bare, place: "api", dockerExecutable: "docker") }
        #expect(throws: ExecutionError.dockerUnavailable) { try ProjectREPL.terminalRequest(target: target, place: "api", dockerExecutable: nil) }
    }

    @Test func dockerSandboxUsesADisposableContainer() throws {
        let host = try Self.project(["artisan", "vendor/laravel/tinker/"], name: "Sandbox folder")
        let target = TargetSnapshot(kind: .sandboxDocker, label: "sandbox", targetId: "sandbox", workingDirectory: "/sandbox", phpExecutable: "php", image: "php:8.4-cli", hostMountDirectory: host.path)
        let request = try ProjectREPL.terminalRequest(target: target, place: "Sandbox", dockerExecutable: "docker")
        #expect(request.executable == ["docker", "run", "--rm", "-it", "--init", "--label", "dev.runlet.owned=sandbox", "--volume", "\(host.path):/sandbox", "--workdir", "/sandbox", "php:8.4-cli", "sh", "-lc", "exec php artisan tinker"])
        #expect(request.title == "Tinker · Sandbox" && request.isCommand)
    }

    @Test func sshHostsRunTheScriptInTheProfilesDirectory() throws {
        let control = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rlt-repl-\(UUID().uuidString.prefix(6))/ab.sock").path
        let directory = "/home/forge/it's \"app\" $HOME"
        let ssh = SSHClient(executable: "/usr/bin/ssh", environment: [:])
        for authentication in [SSHAuthentication.interactive, .automatic] {
            let endpoint = SSHEndpoint(host: "app-prod", user: "forge", controlPath: control, authentication: authentication)
            let target = TargetSnapshot(kind: .ssh, label: "x", targetId: "x", workingDirectory: directory, phpExecutable: "php8.3", ssh: endpoint)
            let request = try ProjectREPL.terminalRequest(target: target, kind: .phpShell, place: "app-prod", dockerExecutable: nil, ssh: ssh)
            let argv = try #require(request.executable)
            #expect(request.title == "REPL · app-prod" && request.isCommand && request.commandLine == nil)
            #expect(argv.first == "/usr/bin/ssh" && argv.contains("-t") && !argv.contains("-T"), "a pty for the REPL")
            #expect(argv.contains("BatchMode=yes") && argv.contains("StrictHostKeyChecking=yes"), "no prompts, no unknown host keys")
            // The same connection rules as project commands: a password or 2FA host only
            // reuses Connect…'s login; a key host may start the shared connection.
            #expect(argv.contains(authentication == .interactive ? "ControlMaster=no" : "ControlMaster=auto"))
            #expect(Array(argv.suffix(3).prefix(2)) == ["--", "app-prod"])
            let words = try ProjectCommandLauncherTests.shellWords(try #require(argv.last))
            #expect(words == ["/bin/sh", "-lc", RemoteShell.commandScript(directory: directory, commandLine: ProjectREPL.selectionScript(php: "php8.3", place: "app-prod"))])
        }
    }

    /// The remote command, unwrapped as the server's shell would, runs the right REPL in an
    /// oddly named directory (here on this Mac, with the stand-in PHP).
    @Test func sshRemoteCommandSurvivesQuotingEndToEnd() throws {
        let root = try Self.project(["artisan", "vendor/laravel/tinker/"], name: "it's \"app\" $HOME `x`")
        let php = try Self.fakePHP()
        let control = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rlt-repl-\(UUID().uuidString.prefix(6))/ab.sock").path
        let target = TargetSnapshot(kind: .ssh, label: "x", targetId: "x", workingDirectory: root.path, phpExecutable: php, ssh: SSHEndpoint(host: "h", controlPath: control))
        let request = try ProjectREPL.terminalRequest(target: target, place: "h", dockerExecutable: nil, ssh: SSHClient(executable: "/usr/bin/ssh", environment: [:]))
        let words = try ProjectCommandLauncherTests.shellWords(try #require(request.executable?.last))
        #expect(words.prefix(2) == ["/bin/sh", "-lc"])
        let result = try Self.run(words[2], in: FileManager.default.temporaryDirectory)
        #expect(result.stdout.contains("PHP-ARGS[artisan tinker] PWD["), "\(result.stdout) \(result.stderr)")
        #expect(result.stdout.contains("\u{1b}]2;Tinker · h\u{07}"))

        // A directory the login can't open: explained, and no REPL starts.
        var missing = target
        missing.workingDirectory = "/nonexistent/runlet repl"
        let failed = try ProjectREPL.terminalRequest(target: missing, place: "h", dockerExecutable: nil, ssh: SSHClient(executable: "/usr/bin/ssh", environment: [:]))
        let failedResult = try Self.run(try ProjectCommandLauncherTests.shellWords(try #require(failed.executable?.last))[2], in: FileManager.default.temporaryDirectory)
        #expect(failedResult.status == 2)
        #expect(failedResult.stderr.contains("/nonexistent/runlet repl doesn't exist on this server"))
        #expect(!failedResult.stdout.contains("PHP-ARGS"))
    }

    @Test func sshContainerStepsExecIntoTheResolvedContainerOnTheServer() throws {
        let control = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rlt-repl-\(UUID().uuidString.prefix(6))/ab.sock").path
        let target = TargetSnapshot(kind: .ssh, label: "x", targetId: "x", workingDirectory: "/var/www/html", phpExecutable: "php", containerId: "abc123", containerName: "shop-app-1", user: "www-data", temporaryDirectory: "/scratch", ssh: SSHEndpoint(host: "app-prod", controlPath: control), dockerCommand: "sudo -n docker")
        let request = try ProjectREPL.terminalRequest(target: target, place: "shop/app on app-prod", dockerExecutable: nil, ssh: SSHClient(executable: "/usr/bin/ssh", environment: [:]))
        let argv = try #require(request.executable)
        #expect(argv.contains("-t"))
        #expect(request.title == "REPL · shop/app on app-prod")
        let outer = try ProjectCommandLauncherTests.shellWords(try #require(argv.last))
        #expect(outer.prefix(2) == ["/bin/sh", "-c"])
        #expect(try ProjectCommandLauncherTests.shellWords(outer[2]) == ["sudo", "-n", "docker", "exec", "-it", "--user", "www-data", "--env", "TMPDIR=/scratch", "-w", "/var/www/html", "abc123", "sh", "-lc", ProjectREPL.selectionScript(php: "php", place: "shop/app on app-prod")])

        var noHost = target
        noHost.ssh = nil
        #expect(throws: ExecutionError.self) { try ProjectREPL.terminalRequest(target: noHost, place: "x", dockerExecutable: nil) }
    }
}

/// A real Tinker session in the bundled sandbox, typed into a pseudo-terminal the way the
/// terminal tab runs it: state carries over between inputs. Its psysh files go to a scratch
/// HOME, never the developer's own.
@Suite(.enabled(if: TestSupport.hasPHP && FileManager.default.fileExists(atPath: TestSupport.repoRoot.appendingPathComponent("Resources/Sandbox/laravel/vendor/laravel/tinker").path), "requires PHP and the sandbox's vendor/ (scripts/build-sandbox.sh)"))
struct ProjectREPLLiveTests {
    @Test func tinkerInTheSandboxKeepsStateBetweenInputs() async throws {
        let sandbox = TestSupport.repoRoot.appendingPathComponent("Resources/Sandbox/laravel").path
        let php = try #require(TestSupport.php())
        let request = try ProjectREPL.terminalRequest(target: TargetSnapshot(kind: .sandboxLocal, label: "sandbox", targetId: "sandbox", workingDirectory: sandbox, phpExecutable: php), place: "Sandbox", dockerExecutable: nil)
        #expect(request.title == "Tinker · Sandbox")
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-repl-home-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["PATH": "/usr/bin:/bin", "HOME": home.path, "XDG_CONFIG_HOME": home.path + "/config", "XDG_DATA_HOME": home.path + "/data", "TERM": "xterm-256color"]
        let line = try #require(request.commandLine)
        let terminal = try PseudoTerminal(["/bin/sh", "-c", "cd \(ProjectCommandLauncher.shellQuote(sandbox)) && \(line)"], environment: environment)
        defer { terminal.stop() }
        #expect(try await terminal.waitFor(seconds: 60) { terminal.text.contains(">") }, "a prompt: \(terminal.text)")
        terminal.send("$x = collect([1, 2, 3])->map(fn ($n) => $n * 7);\r")
        #expect(try await terminal.waitFor(seconds: 30) { terminal.text.contains("Collection") }, "\(terminal.text)")
        terminal.send("$x->sum()\r")
        #expect(try await terminal.waitFor(seconds: 30) { terminal.text.components(separatedBy: "sum()").last?.contains("42") == true }, "the second input sees $x: \(terminal.text)")
        terminal.send("exit\r")
        #expect(try await terminal.waitFor(seconds: 20) { !terminal.isRunning }, "\(terminal.text)")
    }
}

/// Open REPL on the disposable SSH fixture (part of the serialized `SSHRunTests`): the exact
/// argv a terminal tab runs, under `script(1)` for a pty.
extension SSHRunTests {
    @Test func replOnTheServerKeepsStateAndChoosesThere() async throws {
        let environment = try await SSHFixture.environment()
        let client = environment.client()
        let endpoint = environment.endpoint()
        defer { Task { await client.disconnect(endpoint) } }

        // The fixture's app has neither Tinker nor PsySH: PHP's interactive shell, with state
        // kept between inputs, the server's PHP, and the profile's directory.
        let plain = environment.target(endpoint, directory: "/home/runlet/site/current", php: "/usr/local/bin/php")
        let request = try ProjectREPL.terminalRequest(target: plain, place: "fixture", dockerExecutable: nil, ssh: client)
        let shell = try PseudoTerminal(try #require(request.executable), environment: client.environment)
        defer { shell.stop() }
        #expect(try await shell.waitFor { shell.text.contains("php >") }, "PHP's prompt: \(shell.text)")
        #expect(shell.text.contains("\u{1b}]2;PHP shell · fixture\u{07}"), "the exact tab title")
        #expect(shell.text.contains("no Tinker or PsySH"), "\(shell.text)")
        shell.send("$x = 40;\r")
        shell.send("echo $x + 2, '|', getcwd(), '|', PHP_BINARY, PHP_EOL;\r")
        #expect(try await shell.waitFor { shell.text.contains("42|/home/runlet/site/releases/20260101|/usr/local/bin/php") }, "\(shell.text)")
        shell.send("exit\r")
        #expect(try await shell.waitFor { !shell.isRunning }, "\(shell.text)")

        // A Laravel layout with laravel/tinker: the server runs `php artisan tinker` (here a
        // stand-in artisan that reports its arguments), in an oddly named directory.
        let directory = "/srv/repl it's \"tinker\" $HOME"
        try await environment.exec("rm -rf \"$1\" && mkdir -p \"$1/vendor/laravel/tinker\" && printf '%s\\n' '<?php echo \"artisan:\", implode(\" \", array_slice($argv, 1)), \"|\", getcwd(), PHP_EOL;' > \"$1/artisan\" && chmod -R a+rX \"$1\"", arguments: [directory])
        let tinker = try ProjectREPL.terminalRequest(target: environment.target(endpoint, directory: directory), place: "fixture", dockerExecutable: nil, ssh: client)
        let started = try PseudoTerminal(try #require(tinker.executable), environment: client.environment)
        defer { started.stop() }
        #expect(try await started.waitFor { !started.isRunning }, "\(started.text)")
        #expect(started.text.contains("artisan:tinker|\(directory)"), "\(started.text)")
        #expect(started.text.contains("\u{1b}]2;Tinker · fixture\u{07}"))
    }
}

/// Open REPL in a Docker profile's container, against the runlet-fixtures `laravel` service
/// only (found with a label-filtered `docker ps`; no other container is listed or touched).
@Suite(.live(.docker), .enabled(if: TestSupport.hasDocker, "requires a running Docker engine"))
struct ProjectREPLDockerTests {
    @Test func tinkerInTheFixtureContainerKeepsStateBetweenInputs() async throws {
        let docker = try #require(TestSupport.docker)
        let listed = try await runCommand(docker.spec(["ps", "-q", "--filter", "label=com.docker.compose.project=runlet-fixtures", "--filter", "label=com.docker.compose.service=laravel"]), timeout: .seconds(20))
        let containerId = String(decoding: listed.stdout, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
        try #require(!containerId.isEmpty, "start the fixtures with scripts/setup-fixtures.sh docker")
        let target = TargetSnapshot(kind: .docker, label: "laravel", targetId: "fixture", workingDirectory: "/var/www/html", phpExecutable: "php", containerId: containerId, containerName: "laravel", temporaryDirectory: "/tmp")
        let request = try ProjectREPL.terminalRequest(target: target, place: "laravel", dockerExecutable: docker.executable)
        let terminal = try PseudoTerminal(try #require(request.executable), environment: ProcessInfo.processInfo.environment)
        defer { terminal.stop() }
        #expect(try await terminal.waitFor(seconds: 60) { terminal.text.contains("Psy Shell") && terminal.text.contains(">") }, "Tinker's prompt: \(terminal.text)")
        #expect(terminal.text.contains("\u{1b}]2;Tinker · laravel\u{07}"), "the container chose Tinker")
        terminal.send("$x = collect([1, 2, 3])->map(fn ($n) => $n * 7);\r")
        #expect(try await terminal.waitFor(seconds: 30) { terminal.text.contains("Collection") }, "\(terminal.text)")
        terminal.send("$x->sum()\r")
        #expect(try await terminal.waitFor(seconds: 30) { terminal.text.components(separatedBy: "sum()").last?.contains("42") == true }, "the second input sees $x: \(terminal.text)")
        terminal.send("exit\r")
        #expect(try await terminal.waitFor(seconds: 20) { !terminal.isRunning }, "\(terminal.text)")
    }
}
