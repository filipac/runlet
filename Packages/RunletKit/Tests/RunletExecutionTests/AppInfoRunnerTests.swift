import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// App Info panels (#19) through the real runner: `mode: "panels"` on the sandbox and the
/// framework fixtures, project drivers' `panels()`, bounds, redaction, and failures.
enum AppInfoSupport {
    static func load(_ directory: String, php: String? = nil) async throws -> AppInfoReport {
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
        return try await engine.loadAppInfo(target: DriverSupport.target(directory, php: php))
    }

    static var hasSandbox: Bool {
        FileManager.default.fileExists(atPath: TestSupport.repoRoot.appendingPathComponent("Resources/Sandbox/laravel/vendor/autoload.php").path)
    }
}

extension AppInfoReport {
    func section(_ title: String) -> AppInfoSection? { sections.first { $0.title == title } }

    func value(_ title: String, _ key: String) -> AppInfoValue? {
        section(title)?.rows.first { $0.key == key }?.value
    }

    /// Every key and value, for checking that a secret appears nowhere.
    var allText: String {
        sections.flatMap { [$0.title] + $0.rows.flatMap { [$0.key, $0.value.copyText] } }.joined(separator: "\n") + notes.joined(separator: "\n")
    }
}

@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct AppInfoRunnerTests {
    @Test(.enabled(if: AppInfoSupport.hasSandbox, "requires the sandbox's vendor/ (scripts/build-sandbox.sh)"))
    func sandboxShowsWhatArtisanAboutShows() async throws {
        let sandbox = TestSupport.repoRoot.appendingPathComponent("Resources/Sandbox/laravel").path
        let report = try await AppInfoSupport.load(sandbox)
        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.finished?.status == .completed)
        #expect(report.framework == "laravel" && report.driverName == "Laravel")
        #expect(Array(report.sections.map(\.title).prefix(3)) == ["Environment", "Cache", "Drivers"])
        #expect(report.sections.last?.title == "PHP")
        #expect(report.sections.allSatisfy { $0.origin == .builtin })
        #expect(report.value("Environment", "Laravel Version")?.displayText == report.frameworkVersion)
        #expect(report.value("Environment", "PHP Version")?.displayText == report.phpVersion)
        #expect(report.value("Environment", "Debug Mode") == .text("Enabled") || report.value("Environment", "Debug Mode") == .text("Off"))
        #expect(report.value("Cache", "Config") == .text("Not cached"))
        #expect(report.value("Drivers", "Database") == .text("sqlite"))
        // Runlet doesn't run `composer --version` for it.
        #expect(report.value("Environment", "Composer Version") == nil)
        // Paths inside the project are relative to it.
        #expect(report.section("Storage")?.rows.first?.key == "public/storage")
        #expect(!report.allText.contains(sandbox))
        #expect(report.value("PHP", "Version")?.displayText == report.phpVersion)
        if case .list(let drivers)? = report.value("PHP", "PDO drivers") { #expect(drivers.contains("sqlite")) } else { Issue.record("PDO drivers is not a list") }
    }

    /// A project driver extending LaravelDriver keeps the built-in sections and adds its own
    /// after them; secrets are hidden by key and by value before they leave PHP.
    @Test(.enabled(if: LaravelFamilyDriverTests.hasLaravelFixture, "requires scripts/setup-fixtures.sh"))
    func laravelProjectDriverAppendsPanelsWithoutSecrets() async throws {
        let directory = try CommandsSupport.laravelProject([
            ".runlet/OpsDriver.php": """
            <?php
            class OpsDriver extends Runlet\\Drivers\\LaravelDriver {
                public function panels(): array {
                    return parent::panels() + [
                        'Ops' => [
                            'Tenant' => config('app.name'),
                            'APP_KEY' => config('app.key'),
                            'Workers' => 3,
                            'Paused' => false,
                            'Queues' => ['default', 'mail'],
                            'Redis' => 'redis://:hunter2-secret@cache:6379/0',
                            'Since' => new DateTimeImmutable('2026-01-02T03:04:05+00:00'),
                        ],
                        ['title' => 'Listed', 'rows' => [['key' => 'One', 'value' => 1]]],
                    ];
                }
            }
            """,
        ])
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = try await AppInfoSupport.load(directory.path)
        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.framework == "custom:OpsDriver" && report.driverFile == ".runlet/OpsDriver.php")
        #expect(report.sections.map(\.title) == ["Environment", "Cache", "Drivers", "Storage", "PHP", "Ops", "Listed"])
        #expect(report.value("Environment", "Application Name") == .text("Runlet Fixture"))
        let ops = try #require(report.section("Ops"))
        #expect(ops.origin == .driver && ops.source == "Laravel", "the driver's name(), inherited from LaravelDriver")
        #expect(report.value("Ops", "Tenant") == .text("Runlet Fixture"))
        #expect(report.value("Ops", "APP_KEY") == .text(AppInfoRedaction.mask))
        #expect(report.value("Ops", "Workers") == .integer(3))
        #expect(report.value("Ops", "Paused") == .flag(false))
        #expect(report.value("Ops", "Queues") == .list(["default", "mail"]))
        #expect(report.value("Ops", "Redis") == .text("redis://:\(AppInfoRedaction.mask)@cache:6379/0"))
        #expect(report.value("Ops", "Since") == .text("2026-01-02T03:04:05+00:00"))
        #expect(report.value("Listed", "One") == .integer(1))
        #expect(report.redactedCount == 2)
        let key = try String(contentsOf: TestSupport.fixtures.appendingPathComponent("laravel-app/.env"), encoding: .utf8)
            .split(separator: "\n").first { $0.hasPrefix("APP_KEY=") }.map { String($0.dropFirst(8)) }
        if let key, !key.isEmpty { #expect(!report.allText.contains(key)) }
        #expect(!report.allText.contains("hunter2-secret"))
    }

    /// A package's `about` section that throws: the configuration rows instead, with a note.
    @Test(.enabled(if: LaravelFamilyDriverTests.hasLaravelFixture, "requires scripts/setup-fixtures.sh"))
    func failingAboutDataFallsBackToTheConfiguration() async throws {
        let directory = try CommandsSupport.laravelProject([
            ".runlet/BrokenAboutDriver.php": """
            <?php
            class BrokenAboutDriver extends Runlet\\Drivers\\LaravelDriver {
                public function bootstrap(string $projectPath): void {
                    parent::bootstrap($projectPath);
                    Illuminate\\Foundation\\Console\\AboutCommand::add('Broken', function () { throw new RuntimeException('package section failed'); });
                }
            }
            """,
        ])
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = try await AppInfoSupport.load(directory.path)
        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.sections.map(\.title) == ["Environment", "Drivers", "PHP"])
        #expect(report.value("Environment", "Application Name") == .text("Runlet Fixture"))
        #expect(report.value("Drivers", "Database") == .text("sqlite"))
        #expect(report.notes.contains { $0.contains("package section failed") && $0.contains("shows the configuration instead") }, "\(report.notes)")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: TestSupport.fixtures.appendingPathComponent("custom-driver/vendor/autoload.php").path), "requires composer install in the custom-driver fixture"))
    func customDriverPanelsFollowPHP() async throws {
        let report = try await AppInfoSupport.load(DriverSupport.fixture("custom-driver"))
        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.framework == "custom:AcmeApiDriver")
        #expect(report.sections.map(\.title) == ["PHP", "Acme API"])
        #expect(report.value("Acme API", "Application") == .text("Acme Lease API"))
        #expect(report.value("Acme API", "Routes") == .integer(1))
        #expect(report.value("Acme API", "Route list") == .list(["GET /health"]))
        #expect(report.value("Acme API", "Read-only") == .flag(false))
        #expect(report.value("Acme API", "API token") == .text(AppInfoRedaction.mask))
        #expect(report.value("Acme API", "Upstream") == .text("https://acme:\(AppInfoRedaction.mask)@api.acme.test/v1"))
        #expect(report.redactedCount == 2)
        #expect(!report.allText.contains("acme-fixture-token") && !report.allText.contains("fixture-password"))
    }

    /// Panels.php keeps PHP 7.4 syntax: the same panels on the oldest supported PHP.
    @Test(.enabled(if: TestSupport.herdPHP74 != nil && FileManager.default.fileExists(atPath: TestSupport.fixtures.appendingPathComponent("custom-driver/vendor/autoload.php").path), "requires PHP 7.4"))
    func customDriverPanelsOnPHP74() async throws {
        let report = try await AppInfoSupport.load(DriverSupport.fixture("custom-driver"), php: TestSupport.herdPHP74)
        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.phpVersion?.hasPrefix("7.4") == true)
        #expect(report.sections.map(\.title) == ["PHP", "Acme API"])
        #expect(report.value("Acme API", "API token") == .text(AppInfoRedaction.mask))
        #expect(report.value("Acme API", "Route list") == .list(["GET /health"]))
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: TestSupport.fixtures.appendingPathComponent("symfony-app/vendor/autoload.php").path), "requires the Symfony fixture"))
    func symfonyShowsItsKernel() async throws {
        let report = try await AppInfoSupport.load(DriverSupport.fixture("symfony-app"))
        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.sections.map(\.title) == ["Symfony", "PHP"])
        #expect(report.value("Symfony", "Version")?.displayText == report.frameworkVersion)
        #expect(report.value("Symfony", "Environment") == .text("dev"))
        #expect(report.value("Symfony", "Cache directory") == .text("var/cache/dev"))
        #expect(report.value("Symfony", "Kernel") == .text("App\\Kernel"))
    }

    @Test(.fixture(.wordpress), .enabled(if: TestSupport.hasWordPressFixture, "requires the WordPress fixture"))
    func wordPressShowsSiteDebugAndDatabase() async throws {
        let report = try await AppInfoSupport.load(DriverSupport.fixture("wordpress"))
        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.sections.map(\.title) == ["WordPress", "Debug", "Database", "PHP"])
        #expect(report.value("WordPress", "Version")?.displayText == report.frameworkVersion)
        #expect(report.value("WordPress", "Multisite") == .text("No"))
        #expect(report.value("WordPress", "Site URL")?.displayText.hasPrefix("http") == true)
        #expect(report.value("Debug", "WP_DEBUG") != nil)
        #expect(report.value("Database", "Table prefix") != nil)
        // wp-config.php's keys and salts are never shown.
        #expect(!report.allText.contains("AUTH_KEY"))
    }

    // MARK: Bounds and failures

    @Test func boundsSectionsRowsAndValues() async throws {
        let directory = try DriverSupport.composerProject(drivers: [
            "BigDriver.php": """
            <?php
            class BigDriver extends \\Runlet\\Driver {
                public function bootstrap(string $projectPath): void {}
                public function panels(): array {
                    $sections = [];
                    for ($s = 0; $s < 30; $s++) {
                        $rows = [];
                        for ($r = 0; $r < 150; $r++) { $rows['row ' . $r] = str_repeat('é', 3000); }
                        $sections['Section ' . $s] = $rows;
                    }
                    $sections['Section 0']['row 0'] = range(1, 80);
                    return $sections;
                }
            }
            """,
        ])
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = try await AppInfoSupport.load(directory.path)
        #expect(report.errors.isEmpty, "\(report.errors)")
        // 20 sections in all: PHP plus 19 of the driver's.
        #expect(report.sections.count == AppInfoLimits.maxSections)
        #expect(report.omittedSections == 11)
        let first = try #require(report.section("Section 0"))
        #expect(first.rows.count <= AppInfoLimits.maxRows)
        #expect(first.rows.count + first.omittedRows == 150)
        guard case .list(let items)? = first.rows.first?.value else { Issue.record("not a list"); return }
        #expect(items.count == 51 && items.last == "… 30 more")
        guard case .text(let text)? = first.rows.dropFirst().first?.value else { Issue.record("not text"); return }
        #expect(text.utf8.count <= 2003 && text.hasSuffix("…"))
        // The total budget (256 KB) leaves rows out, with a note.
        #expect(report.sections.reduce(0) { $0 + $1.omittedRows } > 0)
        #expect(report.notes.contains { $0.contains("left out") })
    }

    @Test func driverFailuresKeepTheBuiltinSections() async throws {
        let throwing = try DriverSupport.composerProject(drivers: [
            "BrokenDriver.php": """
            <?php
            class BrokenDriver extends \\Runlet\\Driver {
                public function bootstrap(string $projectPath): void {}
                public function panels(): array { throw new RuntimeException('no panels today'); }
            }
            """,
        ])
        defer { try? FileManager.default.removeItem(at: throwing) }
        let report = try await AppInfoSupport.load(throwing.path)
        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.sections.map(\.title) == ["PHP"])
        #expect(report.driverError == "Runlet driver BrokenDriver (.runlet/BrokenDriver.php) failed in panels(): no panels today")

        let exiting = try DriverSupport.composerProject(drivers: [
            "ExitDriver.php": """
            <?php
            class ExitDriver extends \\Runlet\\Driver {
                public function bootstrap(string $projectPath): void {}
                public function panels(): array { exit(4); }
            }
            """,
        ])
        defer { try? FileManager.default.removeItem(at: exiting) }
        let exited = try await AppInfoSupport.load(exiting.path)
        #expect(exited.sections.map(\.title) == ["PHP"], "the built-ins were sent before panels() ran")
        #expect(exited.errors.first?.message.contains("called exit() while Runlet was reading its App Info") == true, "\(exited.errors)")

        let invalid = try DriverSupport.composerProject(drivers: [
            "OddDriver.php": """
            <?php
            class OddDriver extends \\Runlet\\Driver {
                public function bootstrap(string $projectPath): void {}
                public function panels(): array { return ['Fine' => ['a' => 1], 'Scalar' => 'nope', 7]; }
            }
            """,
        ])
        defer { try? FileManager.default.removeItem(at: invalid) }
        let odd = try await AppInfoSupport.load(invalid.path)
        #expect(odd.sections.map(\.title) == ["PHP", "Fine"])
        #expect(odd.notes.contains { $0.contains("which Runlet skipped: Scalar, #0") }, "\(odd.notes)")
    }

    @Test func bootstrapErrorsAreReportedWithoutSections() async throws {
        let directory = try DriverSupport.composerProject(drivers: [
            "DownDriver.php": """
            <?php
            class DownDriver extends \\Runlet\\Driver {
                public function bootstrap(string $projectPath): void { throw new RuntimeException('database is down'); }
                public function panels(): array { return ['Never' => ['x' => 1]]; }
            }
            """,
        ])
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = try await AppInfoSupport.load(directory.path)
        #expect(report.sections.isEmpty)
        #expect(report.errors.first?.stage == .bootstrap)
        #expect(report.errors.first?.message.contains("database is down") == true)
    }
}

// MARK: - Docker and SSH (the suites' own serialization and fixtures)

extension DockerRunTests {
    /// App Info boots Laravel inside the fixture container, like a run.
    @Test func appInfoReadsLaravelInsideTheContainer() async throws {
        let container = try await fixtureContainer("laravel")
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: docker)
        let report = try await engine.loadAppInfo(target: target(container, workingDirectory: "/var/www/html"))
        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.framework == "laravel")
        #expect(report.value("Environment", "Application Name") == .text("Runlet Fixture"))
        #expect(report.value("PHP", "Version")?.displayText.hasPrefix("8.4") == true)
        #expect(report.section("Storage")?.rows.first?.key == "public/storage")
    }
}

extension SSHRunTests {
    /// App Info on an SSH host: the runner boots the project on the server, through the
    /// shared connection, only when asked.
    @Test func appInfoRunsOnTheServer() async throws {
        let environment = try await SSHFixture.environment()
        let endpoint = environment.endpoint()
        let client = environment.client()
        defer { Task { await client.disconnect(endpoint) } }
        #expect(client.status(endpoint) == .disconnected)
        let report = try await environment.engine().loadAppInfo(target: environment.target(endpoint, directory: "/srv/app"))
        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.framework == "composer")
        #expect(report.sections.map(\.title) == ["PHP"])
        #expect(report.value("PHP", "Version")?.displayText.hasPrefix("8.4") == true)
    }
}
