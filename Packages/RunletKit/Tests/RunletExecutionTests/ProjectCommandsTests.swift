import Foundation
import RunletCore
import Testing
@testable import RunletExecution

enum CommandsSupport {
    static func list(_ directory: String, php: String? = nil) async throws -> ProjectCommandCatalog {
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
        return try await engine.listCommands(target: DriverSupport.target(directory, php: php))
    }

    /// A temporary directory whose entries link to the Laravel fixture, plus the given files.
    static func laravelProject(_ files: [String: String]) throws -> URL {
        let directory = try DriverSupport.temporaryDirectory("commands-laravel")
        let app = TestSupport.fixtures.appendingPathComponent("laravel-app")
        let overridden = Set(files.keys.map { String($0.split(separator: "/").first ?? "") })
        for entry in try FileManager.default.contentsOfDirectory(atPath: app.path) where entry != ".runlet" && !overridden.contains(entry) {
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(entry), withDestinationURL: app.appendingPathComponent(entry))
        }
        try DriverSupport.write(files, into: directory)
        return directory
    }
}

extension ProjectCommandCatalog {
    func driverCommand(_ name: String) -> ProjectCommand? {
        commands.first { $0.origin == .driver && $0.name == name }
    }

    func composerScript(_ name: String) -> ProjectCommand? {
        commands.first { $0.origin == .composer && $0.name == name }
    }

    var driverCommandNames: [String] { commands.filter { $0.origin == .driver }.map(\.name) }
    var composerScriptNames: [String] { commands.filter { $0.origin == .composer }.map(\.name) }
}

// MARK: - Laravel and Symfony (built-in drivers)

@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct BuiltInDriverCommandsTests {
    @Test(.enabled(if: LaravelFamilyDriverTests.hasLaravelFixture, "requires scripts/setup-fixtures.sh"))
    func laravelListsEveryVisibleArtisanCommand() async throws {
        let catalog = try await CommandsSupport.list(DriverSupport.fixture("laravel-app"))
        #expect(catalog.errors.isEmpty, "\(catalog.errors)")
        #expect(catalog.driverListed)
        #expect(catalog.framework == "laravel")
        #expect(catalog.driverName == "Laravel")
        #expect(catalog.finished?.status == .completed)

        let migrate = try #require(catalog.driverCommand("migrate"))
        #expect(migrate.commandLine == "php artisan migrate")
        #expect(migrate.description == "Run the database migrations")
        // A top-level command joins its namespace's group when one exists.
        #expect(migrate.group == "migrate")
        #expect(migrate.source == "Laravel")
        #expect(catalog.driverCommand("migrate:status")?.group == "migrate")
        #expect(catalog.driverCommand("make:model")?.commandLine == "php artisan make:model")
        #expect(catalog.driverCommand("make:model")?.group == "make")
        #expect(catalog.driverCommand("queue:work")?.group == "queue")
        #expect(catalog.driverCommand("inspire")?.group == nil)
        #expect(catalog.driverCommand("tinker") != nil, "laravel/tinker's command is listed")
        #expect(catalog.driverCommand("about")?.description?.isEmpty == false)
        // Hidden commands and aliases are not listed.
        #expect(catalog.driverCommand("_complete") == nil)
        #expect(catalog.driverCommand("queue:resume") != nil)
        #expect(catalog.driverCommand("queue:continue") == nil)
        #expect(catalog.driverCommandNames.count > 80)
        #expect(Set(catalog.driverCommandNames).count == catalog.driverCommandNames.count)

        // Composer scripts come after the driver's commands; Composer event hooks are skipped.
        let test = try #require(catalog.composerScript("test"))
        #expect(test.commandLine == "composer run-script test")
        #expect(test.group == "composer")
        #expect(test.source == "Composer")
        #expect(catalog.composerScript("post-autoload-dump") == nil)
        #expect(catalog.commands.last?.origin == .composer)

        let groups = catalog.groups()
        #expect(groups.first?.title == "Laravel")
        #expect(groups.last?.title == "Composer scripts")
        #expect(groups.first { $0.title == "migrate" }?.commands.map(\.name).starts(with: ["migrate", "migrate:fresh"]) == true)
        #expect(catalog.groups(matching: "migrate stat").flatMap(\.commands).map(\.name) == ["migrate:status"])
        #expect(catalog.groups(matching: "DATABASE MIGRATIONS").flatMap(\.commands).contains { $0.name == "migrate" })
    }

    /// A project driver extends Laravel's list: `parent::commands() + [...]`.
    @Test(.enabled(if: LaravelFamilyDriverTests.hasLaravelFixture, "requires scripts/setup-fixtures.sh"))
    func projectDriverAppendsToArtisanCommands() async throws {
        let directory = try CommandsSupport.laravelProject([
            ".runlet/OpsDriver.php": """
            <?php
            class OpsDriver extends Runlet\\Drivers\\LaravelDriver {
                public function commands(): array {
                    return parent::commands() + [
                        'deploy' => ['command' => './vendor/bin/envoy run deploy', 'description' => 'Deploy ' . config('app.name'), 'group' => 'ops'],
                        'horizon:pause' => 'php artisan horizon:pause',
                    ];
                }
            }
            """,
        ])
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try await CommandsSupport.list(directory.path)
        #expect(catalog.errors.isEmpty, "\(catalog.errors)")
        #expect(catalog.framework == "custom:OpsDriver")
        #expect(catalog.driverFile == ".runlet/OpsDriver.php")
        #expect(catalog.driverCommand("migrate")?.commandLine == "php artisan migrate")
        let deploy = try #require(catalog.driverCommand("deploy"))
        #expect(deploy.commandLine == "./vendor/bin/envoy run deploy")
        #expect(deploy.description == "Deploy Runlet Fixture")
        #expect(deploy.group == "ops")
        #expect(catalog.driverCommand("horizon:pause")?.commandLine == "php artisan horizon:pause")
        #expect(catalog.groups().contains { $0.title == "ops" && $0.commands.map(\.name) == ["deploy"] })
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: TestSupport.fixtures.appendingPathComponent("symfony-app/vendor/autoload.php").path), "requires the Symfony fixture"))
    func symfonyListsConsoleCommands() async throws {
        let catalog = try await CommandsSupport.list(DriverSupport.fixture("symfony-app"))
        #expect(catalog.errors.isEmpty, "\(catalog.errors)")
        #expect(catalog.framework == "symfony")
        let clear = try #require(catalog.driverCommand("cache:clear"))
        #expect(clear.commandLine == "php bin/console cache:clear")
        #expect(clear.group == "cache")
        #expect(clear.description == "Clear the cache")
        #expect(catalog.driverCommand("about")?.group == nil)
        #expect(catalog.driverCommand("_complete") == nil)
        // Flex's "auto-scripts" map lists its commands as the description.
        #expect(catalog.composerScript("auto-scripts")?.description?.hasPrefix("cache:clear") == true)
        #expect(catalog.composerScript("post-install-cmd") == nil)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: TestSupport.fixtures.appendingPathComponent("wordpress/.runlet-fixture-ready").path), "requires the WordPress fixture"))
    func wordpressHasNoBuiltInCommands() async throws {
        let catalog = try await CommandsSupport.list(DriverSupport.fixture("wordpress"))
        #expect(catalog.errors.isEmpty, "\(catalog.errors)")
        #expect(catalog.driverListed)
        #expect(catalog.driverCommandNames.isEmpty)
    }

    /// Stub Laravel Zero app: commands use the binary from composer.json "bin"; aliases and
    /// hidden commands are skipped.
    @Test func laravelZeroUsesItsBinaryName() async throws {
        let directory = try DriverSupport.temporaryDirectory("zero-commands")
        defer { try? FileManager.default.removeItem(at: directory) }
        try DriverSupport.write([
            "composer.json": #"{"bin": ["lease-cli"], "require": {"laravel-zero/framework": "^11.0"}}"#,
            "lease-cli": "#!/usr/bin/env php\n<?php require __DIR__.'/bootstrap/app.php';\n",
            "bootstrap/app.php": "<?php return new LaravelZero\\Framework\\Application();",
            "vendor/autoload.php": """
            <?php
            namespace LaravelZero\\Framework {
                class Application {
                    public function make($id) { return new Kernel(); }
                    public function version() { return 'v2.0.0'; }
                }
                class Kernel {
                    public function bootstrap() {}
                    public function all() {
                        $build = new Command('app:build', 'Build a standalone binary');
                        return ['app:build' => $build, 'build' => $build, 'app' => new Command('app', ''),
                                'secret' => new Command('secret', 'Hidden', true), 'lease:sync' => new Command('lease:sync', 'Sync leases')];
                    }
                }
                class Command {
                    private $name; private $description; private $hidden;
                    public function __construct($name, $description, $hidden = false) { $this->name = $name; $this->description = $description; $this->hidden = $hidden; }
                    public function getName() { return $this->name; }
                    public function getDescription() { return $this->description; }
                    public function isHidden() { return $this->hidden; }
                }
            }
            """,
        ], into: directory)
        let catalog = try await CommandsSupport.list(directory.path)
        #expect(catalog.errors.isEmpty, "\(catalog.errors)")
        #expect(catalog.framework == "laravel-zero")
        #expect(catalog.driverCommandNames == ["app", "app:build", "lease:sync"])
        #expect(catalog.driverCommand("app:build")?.commandLine == "php lease-cli app:build")
        #expect(catalog.driverCommand("app")?.group == "app")
        #expect(catalog.driverCommand("app")?.description == nil)
        #expect(catalog.driverCommand("lease:sync")?.group == "lease")
    }
}

// MARK: - Project drivers and Composer scripts

@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct ProjectDriverCommandsTests {
    @Test func customDriverListsItsCommandsAndComposerScripts() async throws {
        let catalog = try await CommandsSupport.list(DriverSupport.fixture("custom-driver"))
        #expect(catalog.errors.isEmpty, "\(catalog.errors)")
        #expect(catalog.driverListed)
        #expect(catalog.framework == "custom:AcmeApiDriver")
        #expect(catalog.frameworkVersion == "Acme Lease API")
        #expect(catalog.driverName == "AcmeApiDriver")
        #expect(catalog.driverFile == ".runlet/AcmeApiDriver.php")
        #expect(catalog.commands == [
            ProjectCommand(name: "acme:routes", description: "List the routes of Acme Lease API", commandLine: "php bin/acme routes", group: "acme", origin: .driver, source: "AcmeApiDriver"),
            ProjectCommand(name: "health", commandLine: "php bin/acme health", origin: .driver, source: "AcmeApiDriver"),
            ProjectCommand(name: "routes", description: "List the app's routes", commandLine: "composer run-script routes", group: "composer", origin: .composer, source: "Composer"),
        ])
        #expect(catalog.groups().map(\.title) == ["AcmeApiDriver", "acme", "Composer scripts"])
    }

    @Test(.enabled(if: TestSupport.herdPHP74 != nil, "requires PHP 7.4"))
    func commandsOnPHP74() async throws {
        let catalog = try await CommandsSupport.list(DriverSupport.fixture("custom-driver"), php: TestSupport.herdPHP74!)
        #expect(catalog.phpVersion?.hasPrefix("7.4") == true)
        #expect(catalog.errors.isEmpty, "\(catalog.errors)")
        #expect(catalog.driverCommandNames == ["acme:routes", "health"])
    }

    @Test func composerScriptsSkipEventHooksAndQuoteOddNames() async throws {
        let project = try DriverSupport.composerProject(drivers: [:])
        defer { try? FileManager.default.removeItem(at: project) }
        try #"""
        {
            "autoload": { "psr-4": { "Acme\\": "src/" } },
            "scripts": {
                "test": "phpunit",
                "lint": ["@php -l src/Greeter.php", "phpstan analyse"],
                "check all": "@lint",
                "post-autoload-dump": "@php -r 'echo 1;'",
                "pre-install-cmd": "true"
            },
            "scripts-descriptions": { "test": "Run the test suite" }
        }
        """#.write(to: project.appendingPathComponent("composer.json"), atomically: true, encoding: .utf8)
        let catalog = try await CommandsSupport.list(project.path)
        #expect(catalog.errors.isEmpty, "\(catalog.errors)")
        #expect(catalog.framework == "composer")
        #expect(catalog.driverListed)
        #expect(catalog.composerScriptNames == ["test", "lint", "check all"])
        #expect(catalog.composerScript("test")?.description == "Run the test suite")
        #expect(catalog.composerScript("lint")?.description == "@php -l src/Greeter.php (+1 more)")
        #expect(catalog.composerScript("check all")?.commandLine == "composer run-script 'check all'")
    }

    /// The application cannot boot: Composer scripts (read before any project code runs)
    /// are still listed, with the bootstrap error.
    @Test func bootstrapFailureStillListsComposerScripts() async throws {
        let directory = try DriverSupport.temporaryDirectory("no-vendor")
        defer { try? FileManager.default.removeItem(at: directory) }
        try DriverSupport.write(["composer.json": #"{"scripts": {"install-deps": "composer install"}}"#], into: directory)
        let catalog = try await CommandsSupport.list(directory.path)
        #expect(!catalog.driverListed)
        #expect(catalog.errors.first?.stage == .bootstrap)
        #expect(catalog.errors.first?.message.contains("composer install") == true)
        #expect(catalog.composerScriptNames == ["install-deps"])
        #expect(catalog.finished?.status == .failed)
    }

    @Test func throwingCommandsReportsDriverAndMethod() async throws {
        let project = try DriverSupport.composerProject(drivers: [
            "BrokenListDriver.php": """
            <?php
            class BrokenListDriver extends Runlet\\Driver {
                public function bootstrap(string $p): void {}
                public function commands(): array { throw new RuntimeException('registry offline'); }
            }
            """,
        ])
        defer { try? FileManager.default.removeItem(at: project) }
        let catalog = try await CommandsSupport.list(project.path)
        #expect(!catalog.driverListed)
        let error = try #require(catalog.errors.first)
        #expect(error.stage == .execute)
        #expect(error.message == "Runlet driver BrokenListDriver (.runlet/BrokenListDriver.php) failed in commands(): registry offline")
        #expect(catalog.finished?.status == .failed)
    }

    @Test func invalidEntriesAreSkippedWithANotice() async throws {
        let project = try DriverSupport.composerProject(drivers: [
            "ListDriver.php": """
            <?php
            class ListDriver extends Runlet\\Driver {
                public function bootstrap(string $p): void {}
                public function commands(): array {
                    return [
                        ['name' => 'listed', 'command' => 'make listed', 'description' => '  Spaces trimmed  '],
                        ['name' => 'listed', 'command' => 'make duplicate'],
                        'no-command' => ['description' => 'missing command'],
                        ['command' => 'no name'],
                        'tagged' => ['command' => 'make tagged', 'group' => 'tasks', 'description' => str_repeat('é', 400)],
                    ];
                }
            }
            """,
        ])
        defer { try? FileManager.default.removeItem(at: project) }
        let catalog = try await CommandsSupport.list(project.path)
        #expect(catalog.errors.isEmpty, "\(catalog.errors)")
        #expect(catalog.driverCommandNames == ["listed", "tagged"])
        #expect(catalog.driverCommand("listed")?.commandLine == "make listed")
        #expect(catalog.driverCommand("listed")?.description == "Spaces trimmed")
        let long = try #require(catalog.driverCommand("tagged")?.description)
        #expect(long.hasSuffix("…") && long.utf8.count <= 503)
        #expect(catalog.notices.contains { $0.contains("ListDriver") && $0.contains("no-command") })
    }

    @Test func exitInCommandsIsReported() async throws {
        let project = try DriverSupport.composerProject(drivers: [
            "ExitListDriver.php": "<?php class ExitListDriver extends Runlet\\Driver { public function bootstrap(string $p): void {} public function commands(): array { exit(0); } }",
        ])
        defer { try? FileManager.default.removeItem(at: project) }
        let catalog = try await CommandsSupport.list(project.path)
        #expect(!catalog.driverListed)
        #expect(catalog.errors.first?.message.contains("listing its commands") == true)
        #expect(catalog.errors.first?.message.contains("ExitListDriver") == true)
    }

    /// Commands mode never runs `code`, and snippet runs never call commands().
    @Test func modesAreIndependent() async throws {
        let project = try DriverSupport.composerProject(drivers: [
            "LoudDriver.php": "<?php class LoudDriver extends Runlet\\Driver { public function bootstrap(string $p): void {} public function commands(): array { echo 'listing'; return ['a' => 'b']; } }",
        ])
        defer { try? FileManager.default.removeItem(at: project) }
        let run = try await TestSupport.run("'ran'", target: DriverSupport.target(project.path))
        #expect(run.result?.value?.scalar == "ran")
        #expect(!run.stdout.contains("listing"))

        let nonce = RunnerBundle.makeNonce()
        let script = TestSupport.bundle.script(code: "echo 'snippet ran';", nonce: nonce, runId: UUID(), mode: .commands, limits: RunLimits())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: DriverSupport.php)
        process.arguments = RunnerBundle.phpArguments
        process.currentDirectoryURL = project
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(script)
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("snippet ran"))
        #expect(text.contains("listing"))
        #expect(!text.contains("\"type\":\"result\""))
    }

    @Test func cancellingTheCallerStopsTheRunner() async throws {
        let project = try DriverSupport.composerProject(drivers: [
            "SlowDriver.php": "<?php class SlowDriver extends Runlet\\Driver { public function bootstrap(string $p): void { sleep(30); } }",
        ])
        defer { try? FileManager.default.removeItem(at: project) }
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
        let started = ContinuousClock.now
        let task = Task { try await engine.listCommands(target: DriverSupport.target(project.path)) }
        try await Task.sleep(for: .milliseconds(500))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(10))
        // The engine releases the run's slot right after its last event.
        var attempts = 0
        while await !engine.activeRunIds.isEmpty, attempts < 50 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await engine.activeRunIds.isEmpty)
    }

    @Test func timeoutStopsTheRunnerAndKeepsComposerScripts() async throws {
        let project = try DriverSupport.composerProject(drivers: [
            "SlowDriver.php": "<?php class SlowDriver extends Runlet\\Driver { public function bootstrap(string $p): void { sleep(30); } }",
        ])
        defer { try? FileManager.default.removeItem(at: project) }
        try #"{"autoload": {"psr-4": {"Acme\\": "src/"}}, "scripts": {"serve": "php -S localhost:8000"}}"#.write(to: project.appendingPathComponent("composer.json"), atomically: true, encoding: .utf8)
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
        let catalog = try await engine.listCommands(target: DriverSupport.target(project.path), timeout: .seconds(1))
        #expect(catalog.finished?.status == .cancelled)
        #expect(catalog.errors.last?.message.contains("took longer than 1 s") == true)
        #expect(catalog.composerScriptNames == ["serve"])
        #expect(!catalog.driverListed)
    }
}

// MARK: - Terminal requests and grouping (no PHP needed)

struct ProjectCommandLauncherTests {
    let artisan = ProjectCommand(name: "migrate:status", description: "Show the status of each migration", commandLine: "php artisan migrate:status", group: "migrate", origin: .driver, source: "Laravel")

    @Test func localTargetRunsInProjectDirectoryWithTheTargetsPHP() throws {
        let target = TargetSnapshot(kind: .local, label: "app", targetId: "x", workingDirectory: "/Users/me/Code/app", phpExecutable: "/Users/me/Library/Application Support/Herd/bin/php84")
        let request = try ProjectCommandLauncher.terminalRequest(for: artisan, target: target, dockerExecutable: nil)
        #expect(request.title == "artisan migrate:status")
        #expect(request.workingDirectory == "/Users/me/Code/app")
        #expect(request.commandLine == "'/Users/me/Library/Application Support/Herd/bin/php84' artisan migrate:status")
        #expect(request.executable == nil)

        let composer = ProjectCommand(name: "test", commandLine: "composer run-script test", group: "composer", origin: .composer, source: "Composer")
        let plain = TargetSnapshot(kind: .sandboxLocal, label: "sandbox", targetId: "sandbox", workingDirectory: "/tmp/sandbox", phpExecutable: "php")
        let composerRequest = try ProjectCommandLauncher.terminalRequest(for: composer, target: plain, dockerExecutable: nil)
        #expect(composerRequest.title == "composer test")
        #expect(composerRequest.commandLine == "composer run-script test")
        #expect(ProjectCommandLauncher.shellText(composerRequest) == "cd /tmp/sandbox && composer run-script test")
        #expect(ProjectCommandLauncher.localCommandLine("phpunit --filter x", php: "/opt/php") == "phpunit --filter x")
    }

    @Test func dockerTargetExecsIntoTheResolvedContainer() throws {
        let target = TargetSnapshot(kind: .docker, label: "api", targetId: "p", workingDirectory: "/var/www/html", phpExecutable: "php", containerId: "abc123", containerName: "api-1", user: "www-data", temporaryDirectory: "/scratch")
        let request = try ProjectCommandLauncher.terminalRequest(for: artisan, target: target, dockerExecutable: "/usr/local/bin/docker")
        #expect(request.executable == ["/usr/local/bin/docker", "exec", "-it", "--user", "www-data", "--env", "TMPDIR=/scratch", "-w", "/var/www/html", "abc123", "sh", "-lc", "php artisan migrate:status"])
        #expect(request.commandLine == nil)
        #expect(ProjectCommandLauncher.shellText(request) == "/usr/local/bin/docker exec -it --user www-data --env TMPDIR=/scratch -w /var/www/html abc123 sh -lc 'php artisan migrate:status'")

        var bare = target
        bare.user = nil
        bare.temporaryDirectory = nil
        #expect(try ProjectCommandLauncher.terminalRequest(for: artisan, target: bare, dockerExecutable: "docker").executable == ["docker", "exec", "-it", "-w", "/var/www/html", "abc123", "sh", "-lc", "php artisan migrate:status"])

        bare.containerId = nil
        #expect(throws: ExecutionError.self) { try ProjectCommandLauncher.terminalRequest(for: artisan, target: bare, dockerExecutable: "docker") }
        #expect(throws: ExecutionError.dockerUnavailable) { try ProjectCommandLauncher.terminalRequest(for: artisan, target: target, dockerExecutable: nil) }
    }

    @Test func dockerSandboxUsesADisposableContainer() throws {
        let target = TargetSnapshot(kind: .sandboxDocker, label: "sandbox", targetId: "sandbox", workingDirectory: "/sandbox", phpExecutable: "php", image: "php:8.4-cli", hostMountDirectory: "/Users/me/Sandbox")
        let request = try ProjectCommandLauncher.terminalRequest(for: artisan, target: target, dockerExecutable: "docker")
        #expect(request.executable == ["docker", "run", "--rm", "-it", "--init", "--label", "dev.runlet.owned=sandbox", "--volume", "/Users/me/Sandbox:/sandbox", "--workdir", "/sandbox", "php:8.4-cli", "sh", "-lc", "php artisan migrate:status"])
    }

    @Test func groupingAndSearch() {
        let catalog = ProjectCommandCatalog(commands: [
            ProjectCommand(name: "about", commandLine: "php artisan about", origin: .driver, source: "Laravel"),
            ProjectCommand(name: "make:model", description: "Create a new Eloquent model class", commandLine: "php artisan make:model", group: "make", origin: .driver, source: "Laravel"),
            ProjectCommand(name: "cache:clear", commandLine: "php artisan cache:clear", group: "cache", origin: .driver, source: "Laravel"),
            ProjectCommand(name: "inspire", commandLine: "php artisan inspire", origin: .driver, source: "Laravel"),
            ProjectCommand(name: "test", commandLine: "composer run-script test", group: "composer", origin: .composer, source: "Composer"),
        ], driverListed: true)
        let groups = catalog.groups()
        #expect(groups.map(\.title) == ["Laravel", "cache", "make", "Composer scripts"])
        #expect(groups[0].commands.map(\.name) == ["about", "inspire"])
        #expect(catalog.groups(matching: "eloquent").flatMap(\.commands).map(\.name) == ["make:model"])
        #expect(catalog.groups(matching: "composer").map(\.title) == ["Composer scripts"])
        #expect(catalog.groups(matching: "nothing-matches").isEmpty)
    }
}

// MARK: - Docker

/// Requires `scripts/setup-fixtures.sh docker` (disposable `runlet-fixtures` Compose project).
@Suite(.serialized, .enabled(if: TestSupport.hasDocker, "requires a running Docker engine"))
struct DockerCommandsTests {
    var docker: DockerCLI { TestSupport.docker! }

    func fixtureContainer(_ service: String) async throws -> ContainerInfo {
        let containers = try await docker.runningContainers()
        return try #require(containers.first { $0.composeProject == "runlet-fixtures" && $0.composeService == service }, "start fixtures with scripts/setup-fixtures.sh docker")
    }

    func target(_ container: ContainerInfo, workingDirectory: String, user: String? = nil, temporaryDirectory: String = "/tmp") -> TargetSnapshot {
        TargetSnapshot(kind: .docker, label: container.name, targetId: container.id, workingDirectory: workingDirectory, phpExecutable: "php", containerId: container.id, containerName: container.name, image: container.image, user: user, temporaryDirectory: temporaryDirectory)
    }

    /// The custom-driver fixture (this checkout's copy, with vendor/ resolved) in a scratch
    /// directory of the `custom` service, so the test never depends on what the service mounts.
    @Test func customDriverCommandsInsideContainer() async throws {
        let container = try await fixtureContainer("custom")
        let staging = try DriverSupport.temporaryDirectory("docker-commands")
        defer { try? FileManager.default.removeItem(at: staging) }
        let fixture = TestSupport.fixtures.appendingPathComponent("custom-driver")
        for entry in try FileManager.default.contentsOfDirectory(atPath: fixture.path) {
            try FileManager.default.copyItem(at: fixture.appendingPathComponent(entry).resolvingSymlinksInPath(), to: staging.appendingPathComponent(entry))
        }
        let remote = "/tmp/runlet-commands-\(UUID().uuidString.prefix(8).lowercased())"
        try await docker.run(["cp", staging.path, "\(container.id):\(remote)"], timeout: .seconds(60))

        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: docker)
        let catalog: ProjectCommandCatalog
        do {
            catalog = try await engine.listCommands(target: target(container, workingDirectory: remote))
        } catch {
            _ = try? await docker.run(["exec", container.id, "rm", "-rf", remote])
            throw error
        }
        _ = try? await docker.run(["exec", container.id, "rm", "-rf", remote])
        #expect(catalog.errors.isEmpty, "\(catalog.errors)")
        #expect(catalog.workingDirectory == remote)
        #expect(catalog.framework == "custom:AcmeApiDriver")
        #expect(catalog.driverCommand("acme:routes")?.description == "List the routes of Acme Lease API")
        #expect(catalog.driverCommandNames == ["acme:routes", "health"])
        #expect(catalog.composerScriptNames == ["routes"])
    }

    @Test func laravelArtisanCommandsInsideContainer() async throws {
        let container = try await fixtureContainer("laravel")
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: docker)
        let catalog = try await engine.listCommands(target: target(container, workingDirectory: "/var/www/html"))
        #expect(catalog.errors.isEmpty, "\(catalog.errors)")
        #expect(catalog.framework == "laravel")
        #expect(catalog.driverCommand("migrate:status")?.commandLine == "php artisan migrate:status")
        #expect(catalog.composerScript("test") != nil)
    }

    /// Non-root user, read-only filesystem, custom TMPDIR, PHP 7.4.
    @Test func restrictedContainer() async throws {
        let container = try await fixtureContainer("restricted")
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: docker)
        let catalog = try await engine.listCommands(target: target(container, workingDirectory: "/app", temporaryDirectory: "/scratch"))
        #expect(catalog.errors.isEmpty, "\(catalog.errors)")
        #expect(catalog.phpVersion?.hasPrefix("7.4") == true)
        #expect(catalog.framework == "composer")
        #expect(catalog.driverListed)
        #expect(catalog.commands.isEmpty)
    }
}
