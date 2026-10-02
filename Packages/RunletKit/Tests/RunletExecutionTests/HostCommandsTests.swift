import Foundation
import RunletCore
import Testing
@testable import RunletExecution

// MARK: - Runner: hostCommands() declarations

@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct HostCommandDeclarationTests {
    static let driver = #"""
    <?php
    class HostDriver extends \Runlet\Driver
    {
        public function canBootstrap(string $projectPath): bool { return true; }
        public function bootstrap(string $projectPath): void { require $projectPath . '/vendor/autoload.php'; }
        public function commands(): array { return ['inside' => 'php -v']; }
        public function hostCommands(): array
        {
            return [
                'up' => ['command' => 'docker compose up -d', 'description' => 'Start the stack', 'group' => 'stack'],
                'logs' => 'docker compose logs -f',
                'new' => ['command' => 'mytool new', 'needsInput' => true],
                'biker' => ['list' => 'biker runlet:commands', 'description' => 'Team CLI'],
                'mytool' => ['console' => 'vendor/bin/mytool'],
                'broken' => ['description' => 'no command'],
            ];
        }
    }
    """#

    @Test func driverDeclaresHostCommandsAndSources() async throws {
        let project = try DriverSupport.composerProject(drivers: ["HostDriver.php": Self.driver])
        defer { try? FileManager.default.removeItem(at: project) }
        let catalog = try await CommandsSupport.list(project.path)
        #expect(catalog.errors.isEmpty, "\(catalog.errors)")
        #expect(catalog.hostDeclared)
        #expect(catalog.hostCommands == [
            ProjectCommand(name: "up", description: "Start the stack", commandLine: "docker compose up -d", group: "stack", origin: .host, source: "Host commands"),
            ProjectCommand(name: "logs", commandLine: "docker compose logs -f", origin: .host, source: "Host commands"),
            ProjectCommand(name: "new", commandLine: "mytool new", origin: .host, source: "Host commands", needsInput: true),
        ])
        #expect(catalog.hostSources == [
            HostCommandSource(name: "biker", format: .runlet, listCommand: "biker runlet:commands", description: "Team CLI"),
            HostCommandSource(name: "mytool", format: .symfony, listCommand: "vendor/bin/mytool list --format=json", console: "vendor/bin/mytool"),
        ])
        #expect(catalog.notices.contains { $0.contains("broken") })
        // The driver's own commands are unaffected; host commands are added by the app.
        #expect(catalog.driverCommandNames == ["inside"])
    }

    @Test func hostCommandsAreDeclaredEvenWhenBootstrapFails() async throws {
        let failing = Self.driver.replacingOccurrences(of: "require $projectPath . '/vendor/autoload.php';", with: "throw new \\RuntimeException('database is down');")
        let project = try DriverSupport.composerProject(drivers: ["HostDriver.php": failing])
        defer { try? FileManager.default.removeItem(at: project) }
        let catalog = try await CommandsSupport.list(project.path)
        #expect(!catalog.driverListed)
        #expect(catalog.errors.first?.message.contains("database is down") == true)
        #expect(catalog.hostDeclared)
        #expect(catalog.hostSources.map(\.name) == ["biker", "mytool"])
    }

    @Test func driversWithoutHostCommandsDeclareNone() async throws {
        let catalog = try await CommandsSupport.list(DriverSupport.fixture("custom-driver"))
        #expect(catalog.hostDeclared)
        #expect(catalog.hostCommands.isEmpty)
        #expect(catalog.hostSources.isEmpty)
    }

    @Test func failingHostCommandsIsANotice() async throws {
        let driver = Self.driver.replacingOccurrences(of: "hostCommands(): array\n    {", with: "hostCommands(): array\n    {\n        throw new \\LogicException('nope');")
        #expect(driver != Self.driver)
        let project = try DriverSupport.composerProject(drivers: ["HostDriver.php": driver])
        defer { try? FileManager.default.removeItem(at: project) }
        let catalog = try await CommandsSupport.list(project.path)
        #expect(catalog.driverListed)
        #expect(!catalog.hostDeclared)
        #expect(catalog.notices.contains { $0.contains("hostCommands() failed") && $0.contains("nope") })
    }

    @Test func consoleCommandsFlagRequiredArguments() async throws {
        guard LaravelFamilyDriverTests.hasLaravelFixture else { return }
        let catalog = try await CommandsSupport.list(DriverSupport.fixture("laravel-app"))
        #expect(catalog.driverCommand("make:model")?.needsInput == true)
        #expect(catalog.driverCommand("migrate")?.needsInput == false)
    }
}

// MARK: - Listing sources on the host

struct HostCommandListerTests {
    static let runletSource = HostCommandSource(name: "biker", format: .runlet, listCommand: "biker runlet:commands")
    static let symfonySource = HostCommandSource(name: "tool", format: .symfony, listCommand: "tool list --format=json", console: "tool")

    @Test func parsesRunletFormatAroundNoise() throws {
        let output = """
        Deprecated: something {weird} happened
        {"commands":[{"name":"phinx:migrate","command":"biker phinx:migrate","description":"Runs <fg=gray>the</> migrations","group":"biker · lease-api"},{"name":"x","command":"biker x","needsInput":true},{"name":"","command":"nothing"},{"name":"x","command":"duplicate"}]}
          ---------------------------
          Detected service: ** Lease API [lease-api] **
        """
        let commands = try #require(HostCommandLister.parse(Data(output.utf8), source: Self.runletSource))
        #expect(commands == [
            ProjectCommand(name: "phinx:migrate", description: "Runs the migrations", commandLine: "biker phinx:migrate", group: "biker · lease-api", origin: .host, source: "biker"),
            ProjectCommand(name: "x", commandLine: "biker x", origin: .host, source: "biker", needsInput: true),
        ])
    }

    @Test func parsesSymfonyListJSON() throws {
        let output = #"""
        {"application":{"name":"Tool","version":"1.0"},"commands":[
          {"name":"_complete","description":"Internal","hidden":true,"definition":{"arguments":[],"options":{}}},
          {"name":"list","description":"List commands","hidden":false,"definition":{"arguments":{"namespace":{"is_required":false}},"options":{}}},
          {"name":"start!","description":"<fg=gray>[aliases: s]</> <fg=gray>[aliases: s]</> Starts the container","hidden":false,"definition":{"arguments":[],"options":{}}},
          {"name":"make:migration","description":"Generate a migration","hidden":false,"definition":{"arguments":{"name":{"is_required":true}},"options":{}}},
          {"name":"secret","description":"","hidden":true,"definition":{"arguments":[],"options":{}}}
        ],"namespaces":[]}
        trailing banner
        """#
        let commands = try #require(HostCommandLister.parse(Data(output.utf8), source: Self.symfonySource))
        #expect(commands == [
            ProjectCommand(name: "start!", description: "[aliases: s] Starts the container", commandLine: "tool 'start!'", origin: .host, source: "tool"),
            ProjectCommand(name: "make:migration", description: "Generate a migration", commandLine: "tool make:migration", origin: .host, source: "tool", needsInput: true),
        ])
    }

    @Test func outputWithoutAListIsNil() {
        #expect(HostCommandLister.parse(Data("command not found: biker\n".utf8), source: Self.runletSource) == nil)
        #expect(HostCommandLister.parse(Data(#"{"unrelated": true}"#.utf8), source: Self.runletSource) == nil)
    }

    @Test func runsTheListCommandInTheDirectoryWithTheGivenEnvironment() async throws {
        let directory = try DriverSupport.temporaryDirectory("host-list")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bin = directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appendingPathComponent("teamtool")
        // Prints the folder it ran in, so the test sees the working directory was used.
        try """
        #!/bin/sh
        echo "banner before"
        printf '{"commands":[{"name":"where","command":"teamtool where","description":"%s"}]}\\n' "$(basename "$PWD")"
        echo "banner after"
        """.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = bin.path + ":/usr/bin:/bin"

        let source = HostCommandSource(name: "teamtool", format: .runlet, listCommand: "teamtool runlet:commands")
        let listing = await HostCommandLister.list(source, directory: directory.path, environment: environment)
        #expect(listing.error == nil)
        #expect(listing.commands.map(\.description) == [directory.lastPathComponent])

        let missing = await HostCommandLister.list(source, directory: directory.path, environment: ["PATH": "/usr/bin:/bin"])
        #expect(missing.commands.isEmpty)
        #expect(missing.error?.contains("exited with code 127") == true)
        #expect(missing.error?.contains("not found") == true)
    }

    @Test func consoleTextDropsStylesAndRepeatedLabels() {
        #expect(ConsoleText.plain("<fg=gray>[aliases: wt]</> <fg=gray>[aliases: wt]</> Switches <info>mounts</info>") == "[aliases: wt] Switches mounts")
        #expect(ConsoleText.plain("Compare a < b and <b>bold</b>") == "Compare a < b and <b>bold</b>")
    }
}

// MARK: - Shell environment and launching

struct HostShellEnvironmentTests {
    @Test func parsesEnvBetweenMarkers() {
        let data = Data("motd {noise}\nMARK".utf8) + Data("PATH=/a:/b\0EMPTY=\0WEIRD=x=y\0".utf8) + Data("MARK trailing".utf8)
        #expect(HostShellEnvironment.parseEnvironment(data, marker: "MARK") == ["PATH": "/a:/b", "EMPTY": "", "WEIRD": "x=y"])
        #expect(HostShellEnvironment.parseEnvironment(Data("no markers".utf8), marker: "MARK") == nil)
    }

    @Test func resolvesTheLoginShellPath() async throws {
        let shell = try DriverSupport.temporaryDirectory("fake-shell")
        defer { try? FileManager.default.removeItem(at: shell) }
        // A stand-in "login shell" that prints noise, then runs the -c script with a PATH
        // only rc files would set.
        let script = shell.appendingPathComponent("fakesh")
        try """
        #!/bin/sh
        echo "rc file chatter"
        PATH="/custom/bin:$PATH" exec /bin/sh -c "$4"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let environment = await HostShellEnvironment.resolve(shell: script.path, base: ["PATH": "/usr/bin:/bin", "KEEP": "1"], home: shell.path)
        #expect(environment["PATH"]?.hasPrefix("/custom/bin:") == true)
        #expect(environment["KEEP"] == "1")
        #expect(environment["SHLVL"] == nil)

        let broken = await HostShellEnvironment.resolve(shell: "/nonexistent/shell", base: ["PATH": "/usr/bin:/bin"], home: shell.path)
        #expect(broken["PATH"] == "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin")
    }

    @Test func hostCommandsOpenTheUsersShellInTheProjectFolder() throws {
        let command = ProjectCommand(name: "start!", commandLine: "biker 'start!'", origin: .host, source: "biker")
        let request = try ProjectCommandLauncher.hostTerminalRequest(for: command, directory: "/Users/me/Code/lease-api")
        #expect(request.workingDirectory == "/Users/me/Code/lease-api")
        #expect(request.commandLine == "biker 'start!'")
        #expect(request.executable == nil)
        #expect(request.runsCommandLine)
        #expect(request.title == "biker 'start!'")
        #expect(throws: ExecutionError.self) { try ProjectCommandLauncher.hostTerminalRequest(for: command, directory: nil) }

        let typed = ProjectCommand(name: "make:migration", commandLine: "biker make:migration", origin: .host, source: "biker", needsInput: true)
        #expect(try ProjectCommandLauncher.hostTerminalRequest(for: typed, directory: "/tmp").runsCommandLine == false)
    }

    @Test func commandsThatNeedInputAreTypedNotRun() throws {
        let command = ProjectCommand(name: "make:model", commandLine: "php artisan make:model", origin: .driver, source: "Laravel", needsInput: true)
        let local = try ProjectCommandLauncher.terminalRequest(for: command, target: TestSupport.localTarget("/tmp", php: "php"), dockerExecutable: nil)
        #expect(local.commandLine == "php artisan make:model")
        #expect(!local.runsCommandLine)

        var docker = TestSupport.localTarget("/var/www", php: "php")
        docker.kind = .docker
        docker.containerId = "abc123"
        let exec = try ProjectCommandLauncher.terminalRequest(for: command, target: docker, dockerExecutable: "/usr/local/bin/docker")
        #expect(exec.executable == ["/usr/local/bin/docker", "exec", "-it", "-w", "/var/www", "abc123", "sh", "-l"])
        #expect(exec.commandLine == "php artisan make:model")
        #expect(!exec.runsCommandLine)

        let launch = try TerminalLaunch.make(for: local, shell: "/bin/zsh", baseEnvironment: [:], home: "/tmp", language: "en_US.UTF-8")
        #expect(launch.pendingInput == "php artisan make:model")
    }

    @Test func hostGroupsFollowDriverGroupsInListingOrder() {
        let catalog = ProjectCommandCatalog(commands: [
            ProjectCommand(name: "migrate", commandLine: "./phinx migrate", group: "db", origin: .driver, source: "Lease"),
            ProjectCommand(name: "tests", commandLine: "./unit-tests", origin: .driver, source: "Lease"),
            ProjectCommand(name: "up", commandLine: "docker compose up", origin: .host, source: "Host commands"),
            ProjectCommand(name: "phinx:migrate", commandLine: "biker phinx:migrate", group: "biker · lease-api", origin: .host, source: "biker"),
            ProjectCommand(name: "ps", commandLine: "biker ps", group: "biker", origin: .host, source: "biker"),
            ProjectCommand(name: "test", commandLine: "composer test", origin: .composer, source: "Composer"),
        ])
        #expect(catalog.groups().map(\.title) == ["Lease", "db", "Host commands", "biker · lease-api", "biker", "Composer scripts"])
        #expect(Set(catalog.commands.map(\.id)).count == catalog.commands.count)
    }
}

// MARK: - Launch failures reported on stdout (docker exec)

struct LaunchFailureMessageTests {
    static let ociChdir = #"OCI runtime exec failed: exec failed: unable to start container process: chdir to cwd ("/var/www") set in config.json failed: no such file or directory: unknown"#

    @Test func explainsMissingWorkingDirectoryAndMissingPHP() {
        let chdir = RunSession.explainLaunchFailure(Self.ociChdir)
        #expect(chdir.hasPrefix("The working directory /var/www does not exist in this container."))
        #expect(chdir.hasSuffix(Self.ociChdir))
        let missing = RunSession.explainLaunchFailure(#"OCI runtime exec failed: exec failed: unable to start container process: exec: "php8": executable file not found in $PATH: unknown"#)
        #expect(missing.hasPrefix("The PHP executable was not found in this container."))
        #expect(RunSession.explainLaunchFailure("something else") == "something else")
    }

    /// `docker exec` prints its launch error on stdout and exits 127; the error (in runs and
    /// in command listings) must carry that text instead of only the exit code.
    @Test func stdoutBeforeStartBecomesTheLaunchError() async throws {
        let directory = try DriverSupport.temporaryDirectory("launch-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fakePHP = directory.appendingPathComponent("fake-docker-exec")
        try "#!/bin/sh\ncat > /dev/null\necho '\(Self.ociChdir)'\nexit 127\n".write(to: fakePHP, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakePHP.path)
        let target = TestSupport.localTarget(directory.path, php: fakePHP.path)

        let events = try await TestSupport.run("1", target: target)
        let runError = events.compactMap { event -> RunErrorInfo? in if case .error(let info) = event.kind { return info } else { return nil } }.first
        #expect(runError?.message.hasPrefix("The working directory /var/www does not exist") == true)

        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
        let catalog = try await engine.listCommands(target: target)
        #expect(catalog.errors.first?.message.contains("chdir to cwd") == true)
    }
}

// MARK: - Driver::gitRevision()

@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct GitRevisionTests {
    static let driver = #"""
    <?php
    class RevisionDriver extends \Runlet\Driver
    {
        private $path = '';
        public function canBootstrap(string $projectPath): bool { return true; }
        public function bootstrap(string $projectPath): void { $this->path = getenv('RUNLET_TEST_GIT_PATH') ?: $projectPath; }
        public function version(): ?string { return $this->gitRevision($this->path); }
    }
    """#

    @discardableResult
    static func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.email=test@example.invalid", "-c", "user.name=Test", "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + arguments
        process.currentDirectoryURL = directory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func version(of project: URL) async throws -> String? {
        try await CommandsSupport.list(project.path).frameworkVersion
    }

    @Test func readsBranchAndCommitInEveryLayout() async throws {
        let project = try DriverSupport.composerProject(drivers: ["RevisionDriver.php": Self.driver])
        defer { try? FileManager.default.removeItem(at: project) }
        #expect(try await Self.version(of: project) == nil, "no checkout")

        try Self.git(["init", "-q"], in: project)
        try Self.git(["add", "-A"], in: project)
        try Self.git(["commit", "-q", "-m", "first"], in: project)
        let short = try Self.git(["rev-parse", "--short=7", "HEAD"], in: project)
        #expect(try await Self.version(of: project) == "main @ \(short)")

        try Self.git(["pack-refs", "--all"], in: project)
        #expect(try await Self.version(of: project) == "main @ \(short)", "packed refs")

        try Self.git(["checkout", "-q", "--detach"], in: project)
        #expect(try await Self.version(of: project) == short, "detached HEAD")
        try Self.git(["checkout", "-q", "main"], in: project)

        let worktree = project.deletingLastPathComponent().appendingPathComponent(project.lastPathComponent + "-wt")
        defer { try? FileManager.default.removeItem(at: worktree) }
        try Self.git(["worktree", "add", "-q", "-b", "feature/x", worktree.path], in: project)
        // `.runlet` may be globally git-ignored (it is meant to be), so copy the driver over.
        try? FileManager.default.removeItem(at: worktree.appendingPathComponent(".runlet"))
        try FileManager.default.copyItem(at: project.appendingPathComponent(".runlet"), to: worktree.appendingPathComponent(".runlet"))
        if !FileManager.default.fileExists(atPath: worktree.appendingPathComponent("vendor").path) {
            try FileManager.default.copyItem(at: project.appendingPathComponent("vendor"), to: worktree.appendingPathComponent("vendor"))
        }
        try "<?php // changed".write(to: worktree.appendingPathComponent("changed.php"), atomically: true, encoding: .utf8)
        try Self.git(["add", "-A"], in: worktree)
        try Self.git(["commit", "-q", "-m", "second"], in: worktree)
        let worktreeShort = try Self.git(["rev-parse", "--short=7", "HEAD"], in: worktree)
        #expect(try await Self.version(of: worktree) == "feature/x @ \(worktreeShort)", "linked worktree")
    }
}

// MARK: - Run Log and exit-during-bootstrap diagnostics

extension Array where Element == RunEvent {
    var logs: [RunLogEntry] { compactMap { if case .log(let entry) = $0.kind { return entry } else { return nil } } }
}

@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct RunLogTests {
    @Test func logsTheLaunchTheDriverAndTheBoot() async throws {
        let events = try await TestSupport.run("1 + 1", target: DriverSupport.target(DriverSupport.fixture("custom-driver")))
        let logs = events.logs
        let launch = try #require(logs.first { $0.source == "launch" })
        #expect(launch.message.contains(DriverSupport.php) || launch.message.contains("php"))
        #expect(launch.detail?.contains("bytes on stdin") == true)
        #expect(logs.contains { $0.source == "runner" && $0.message.hasPrefix("Driver: AcmeApiDriver") })
        #expect(logs.contains { $0.source == "runner" && $0.message.hasPrefix("Booted ") && $0.detail?.contains("$_app") == true })
    }

    @Test func exitDuringBootstrapNamesTheLastFileLoaded() async throws {
        let project = try DriverSupport.composerProject(drivers: [
            "ExitDriver.php": "<?php class ExitDriver extends \\Runlet\\Driver { public function bootstrap(string $p): void { require $p . '/boot-exit.php'; } }",
        ])
        defer { try? FileManager.default.removeItem(at: project) }
        try "<?php\nheader('Location: /login');\nexit;\n".write(to: project.appendingPathComponent("boot-exit.php"), atomically: true, encoding: .utf8)
        let events = try await TestSupport.run("1", target: DriverSupport.target(project.path))
        let error = try #require(events.errors.first)
        #expect(error.message.contains("called exit() while Runlet was bootstrapping it"))
        #expect(error.message.contains("The last file loaded was boot-exit.php"))
        #expect(events.logs.contains { $0.source == "bootstrap" && $0.message.contains("boot-exit.php") })
    }
}

extension WordPressDriverTests {
    /// A plugin (or WordPress's "not installed" check) redirects during bootstrap and exits:
    /// the error says where it redirected and who sent it.
    @Test func redirectDuringBootstrapIsExplained() async throws {
        let muPlugins = TestSupport.fixtures.appendingPathComponent("wordpress/wp-content/mu-plugins")
        let plugin = muPlugins.appendingPathComponent("runlet-test-redirect.php")
        try FileManager.default.createDirectory(at: muPlugins, withIntermediateDirectories: true)
        try "<?php\nadd_action('init', function () { wp_redirect('https://example.test/wp-admin/install.php'); exit; });\n".write(to: plugin, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: plugin) }
        let events = try await TestSupport.run("1", target: target)
        let error = try #require(events.errors.first)
        #expect(error.message.contains("WordPress redirected to https://example.test/wp-admin/install.php (302)"))
        #expect(error.message.contains("runlet-test-redirect.php:2"))
        #expect(error.message.contains("no installation in the database"))
        #expect(events.logs.contains { $0.source == "driver" && $0.message.hasPrefix("WordPress redirect to https://example.test") })
        #expect(events.logs.contains { $0.source == "driver" && $0.message.hasPrefix("WordPress request: http://localhost/") })
    }
}
