import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// Helpers for framework-driver tests: temporary projects and raw runner frames (for
/// `bootstrapped` fields the app's models do not decode yet: `driverName`, `variables`).
enum DriverSupport {
    static var php: String { TestSupport.php()! }

    static func target(_ directory: String, php: String? = nil) -> TargetSnapshot {
        TestSupport.localTarget(directory, php: php ?? self.php)
    }

    static func fixture(_ name: String) -> String {
        if name == "wordpress" { return TestSupport.wordpressFixture.path }
        return TestSupport.fixtures.appendingPathComponent(name).path
    }

    static func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A copy of the Composer fixture with the given `.runlet/` files.
    static func composerProject(drivers: [String: String]) throws -> URL {
        let directory = try temporaryDirectory("drivers")
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.copyItem(at: TestSupport.fixtures.appendingPathComponent("composer"), to: directory)
        try write(drivers, into: directory.appendingPathComponent(".runlet"))
        return directory
    }

    static func write(_ files: [String: String], into directory: URL) throws {
        for (path, contents) in files {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Runs the runner bundle directly and returns its decoded frames as (type, payload).
    /// `phpOptions` go before Runlet's own `php` arguments (for example `-n` to skip php.ini).
    static func rawFrames(_ code: String, directory: String, bootstrap: String = "auto", command: [String]? = nil, environment: [String: String]? = nil, php phpBinary: String? = nil, phpOptions: [String] = []) throws -> [(type: String, payload: [String: Any])] {
        let nonce = RunnerBundle.makeNonce()
        let script = TestSupport.bundle.script(code: code, nonce: nonce, runId: UUID(), bootstrap: bootstrap, limits: RunLimits())
        let scriptFile = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-script-\(UUID().uuidString).php")
        try script.write(to: scriptFile)
        defer { try? FileManager.default.removeItem(at: scriptFile) }

        let process = Process()
        let arguments = command ?? [phpBinary ?? php] + phpOptions + RunnerBundle.phpArguments
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        if command == nil { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        if let environment { process.environment = environment }
        process.standardInput = try FileHandle(forReadingFrom: scriptFile)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var decoder = FrameDecoder(nonce: nonce)
        var frames: [(type: String, payload: [String: Any])] = []
        for item in decoder.feed(data) + decoder.finish() {
            guard case .frame(let body) = item else { continue }
            let (type, payload) = try splitFrame(body)
            frames.append((type, try JSONSerialization.jsonObject(with: payload) as? [String: Any] ?? [:]))
        }
        return frames
    }

    static func bootstrapped(_ frames: [(type: String, payload: [String: Any])]) -> [String: Any]? {
        frames.first { $0.type == "bootstrapped" }?.payload
    }

    static func variables(_ frames: [(type: String, payload: [String: Any])]) -> [String: String]? {
        bootstrapped(frames)?["variables"] as? [String: String]
    }
}

private extension Array where Element == RunEvent {
    var notices: [String] {
        compactMap { if case .notice(let message) = $0.kind { return message } else { return nil } }
    }

    var resultStrings: [String?]? {
        result?.value?.entries?.map { $0.value.scalar }
    }
}

// MARK: - Project drivers (.runlet/)

@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct ProjectDriverTests {
    var customDriver: String { DriverSupport.fixture("custom-driver") }

    @Test func customDriverBootsNonFrameworkApp() async throws {
        let events = try await TestSupport.run("""
        dump(BASE_PATH === getcwd());
        [get_class($_app), $_app->name(), $_app->handle('GET', '/health')['status']]
        """, target: DriverSupport.target(customDriver))
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.started?.framework == "custom")
        #expect(events.bootstrapped?.framework == "custom:AcmeApiDriver")
        #expect(events.bootstrapped?.frameworkVersion == "Acme Lease API")
        #expect(events.resultStrings == ["Acme\\App", "Acme Lease API", "ok"])
        #expect(events.dumps.first?.value.scalar == "true")
        #expect(events.finished?.status == .completed)

        let frames = try DriverSupport.rawFrames("1", directory: customDriver)
        let bootstrapped = try #require(DriverSupport.bootstrapped(frames))
        #expect(bootstrapped["driverName"] as? String == "AcmeApiDriver")
        #expect(bootstrapped["driverFile"] as? String == ".runlet/AcmeApiDriver.php")
        #expect(DriverSupport.variables(frames) == ["_app": "Acme\\App"])
    }

    /// Runlet loads vendor/autoload.php before the driver; the app's bootstrap requires it
    /// again with a plain `require`. Composer must still register exactly one loader.
    @Test func composerAutoloaderLoadedBeforeDriverAndAgainByAppIsHarmless() async throws {
        // Other loaders may exist (e.g. php.ini auto_prepend_file tools ship their own).
        let events = try await TestSupport.run("""
        $project = Composer\\Autoload\\ClassLoader::getRegisteredLoaders()[getcwd() . '/vendor'];
        [count(array_filter(spl_autoload_functions(), fn ($f) => is_array($f) && $f[0] === $project)),
         (require BASE_PATH . '/vendor/autoload.php') === $project]
        """, target: DriverSupport.target(customDriver))
        #expect(events.resultStrings == ["1", "true"], "\(events.errors)")
    }

    @Test func driverThatDeclinesFallsThroughToBuiltIns() async throws {
        let project = try DriverSupport.composerProject(drivers: [
            "NeverDriver.php": """
            <?php
            class NeverDriver extends Runlet\\Driver {
                public function canBootstrap(string $projectPath): bool { return false; }
                public function bootstrap(string $projectPath): void { throw new RuntimeException('must not boot'); }
            }
            """,
            "AbstractBaseDriver.php": "<?php abstract class AbstractBaseDriver extends Runlet\\Driver {}",
            "Helpers.php": "<?php class NotLoadedBecauseNotADriverFile {}",
        ])
        defer { try? FileManager.default.removeItem(at: project) }
        let events = try await TestSupport.run("[(new Acme\\Greeter())->greet('Ana'), class_exists('NotLoadedBecauseNotADriverFile', false)]", target: DriverSupport.target(project.path))
        #expect(events.started?.framework == "custom")
        #expect(events.bootstrapped?.framework == "composer")
        #expect(events.resultStrings == ["Hello, Ana!", "false"], "\(events.errors)")
    }

    /// Project snippets live in `.runlet/snippets/`; nothing there is loaded as a driver or run.
    @Test func snippetsFolderIsNeverLoadedAsDrivers() async throws {
        let project = try DriverSupport.composerProject(drivers: [
            "snippets/BrokenDriver.php": "<?php\nclass BrokenDriver extends Runlet\\Driver { this is not php",
            "snippets/recent.php": "<?php\n/** @label Recent */\nthrow new RuntimeException('a project snippet ran');",
        ])
        defer { try? FileManager.default.removeItem(at: project) }
        let events = try await TestSupport.run("(new Acme\\Greeter())->greet('Ana')", target: DriverSupport.target(project.path))
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.started?.framework == "composer")
        #expect(events.bootstrapped?.framework == "composer")
        #expect(events.result?.value?.scalar == "Hello, Ana!")
    }

    @Test func driversLoadInNameOrderAndMayExtendEachOther() async throws {
        // ZetaDriver extends BetaDriver (a later file): the sibling autoloader resolves it.
        // AlphaDriver sorts first but declines, so ZetaDriver (declared next) wins.
        let project = try DriverSupport.composerProject(drivers: [
            "AlphaDriver.php": "<?php class AlphaDriver extends Runlet\\Driver { public function canBootstrap(string $p): bool { return false; } public function bootstrap(string $p): void {} }",
            "ZetaDriver.php": "<?php class ZetaDriver extends BetaDriver { public function version(): ?string { return 'z1'; } }",
            "BetaDriver.php": "<?php abstract class BetaDriver extends Runlet\\Driver { public function name(): string { return 'Beta ' . parent::name(); } public function bootstrap(string $p): void {} }",
        ])
        defer { try? FileManager.default.removeItem(at: project) }
        let frames = try DriverSupport.rawFrames("1", directory: project.path)
        let bootstrapped = try #require(DriverSupport.bootstrapped(frames))
        #expect(bootstrapped["framework"] as? String == "custom:ZetaDriver")
        #expect(bootstrapped["driverName"] as? String == "Beta ZetaDriver")
        #expect(bootstrapped["frameworkVersion"] as? String == "z1")
    }

    @Test func brokenDriverReportsBootstrapErrorNamingFile() async throws {
        let project = try DriverSupport.composerProject(drivers: [
            "BrokenDriver.php": "<?php\nclass BrokenDriver extends Runlet\\Driver {\n    public function bootstrap(string $p): void { $x = ; }\n}\n",
        ])
        defer { try? FileManager.default.removeItem(at: project) }
        let events = try await TestSupport.run("1", target: DriverSupport.target(project.path))
        let error = try #require(events.errors.first)
        #expect(error.stage == .bootstrap)
        #expect(error.className == "ParseError")
        #expect(error.message.contains("Runlet driver .runlet/BrokenDriver.php could not be loaded"))
        #expect(error.file?.hasSuffix(".runlet/BrokenDriver.php") == true)
        #expect(error.line == 3)
        #expect(events.finished?.status == .failed)
        #expect(events.result == nil)
    }

    @Test func throwingDriverReportsClassAndMethod() async throws {
        let project = try DriverSupport.composerProject(drivers: [
            "ThrowingDriver.php": "<?php\nclass ThrowingDriver extends Runlet\\Driver {\n    public function bootstrap(string $p): void { throw new RuntimeException('database is down'); }\n}\n",
        ])
        defer { try? FileManager.default.removeItem(at: project) }
        let events = try await TestSupport.run("1", target: DriverSupport.target(project.path))
        let error = try #require(events.errors.first)
        #expect(error.stage == .bootstrap)
        #expect(error.className == "RuntimeException")
        #expect(error.message == "Runlet driver ThrowingDriver (.runlet/ThrowingDriver.php) failed in bootstrap(): database is down")
        #expect(error.line == 3)
        let frames = try DriverSupport.rawFrames("1", directory: project.path)
        let payload = try #require(frames.first { $0.type == "error" }?.payload)
        #expect(payload["driverClass"] as? String == "ThrowingDriver")
        #expect(payload["driverFile"] as? String == ".runlet/ThrowingDriver.php")
    }

    /// A Tinkerwell-style driver (untyped methods) is a fatal declaration error in PHP.
    @Test func incompatibleSignatureIsAFatalBootstrapErrorNamingDriver() async throws {
        let project = try DriverSupport.composerProject(drivers: [
            "OldStyleDriver.php": "<?php\nclass OldStyleDriver extends Runlet\\Driver {\n    public function canBootstrap($projectPath) { return true; }\n    public function bootstrap($projectPath) {}\n}\n",
        ])
        defer { try? FileManager.default.removeItem(at: project) }
        let events = try await TestSupport.run("1", target: DriverSupport.target(project.path))
        let error = try #require(events.errors.first)
        #expect(error.stage == .bootstrap)
        #expect(error.fatal == true)
        #expect(error.message.contains(".runlet/OldStyleDriver.php"))
        #expect(error.message.contains("must be compatible"))
        #expect(events.finished?.reason == "fatal")
    }

    @Test func exitDuringBootstrapIsReported() async throws {
        let project = try DriverSupport.composerProject(drivers: [
            "ExitDriver.php": "<?php class ExitDriver extends Runlet\\Driver { public function bootstrap(string $p): void { echo 'bye'; exit(0); } }",
        ])
        defer { try? FileManager.default.removeItem(at: project) }
        let events = try await TestSupport.run("1", target: DriverSupport.target(project.path))
        #expect(events.errors.first?.stage == .bootstrap)
        #expect(events.errors.first?.message.contains("ExitDriver") == true)
        #expect(events.errors.first?.message.contains("exit()") == true)
        #expect(events.stdout == "bye")
        #expect(events.finished?.status == .failed)
    }

    @Test func driverVariablesNeverReplaceRunnerLocals() async throws {
        let project = try DriverSupport.composerProject(drivers: [
            "VarsDriver.php": """
            <?php
            class VarsDriver extends Runlet\\Driver {
                public function bootstrap(string $p): void {}
                public function variables(): array {
                    return ['__runletCode' => 'echo "hijacked";', 'this' => 1, 'GLOBALS' => 2, '0' => 3,
                            'greeter' => new Acme\\Greeter('Yo'), 'ratio' => 1.5, 'tags' => ['a'], 'anon' => new class {}];
                }
            }
            """,
        ])
        defer { try? FileManager.default.removeItem(at: project) }
        let events = try await TestSupport.run("[$greeter->greet('Ana'), $ratio, count($tags)]", target: DriverSupport.target(project.path))
        #expect(events.resultStrings == ["Yo, Ana!", "1.5", "1"], "\(events.errors)")
        #expect(!events.stdout.contains("hijacked"))
        #expect(events.notices.contains { $0.contains("__runletCode, this, GLOBALS, 0") })
        let frames = try DriverSupport.rawFrames("1", directory: project.path)
        #expect(DriverSupport.variables(frames) == ["greeter": "Acme\\Greeter", "ratio": "float", "tags": "array", "anon": "class@anonymous"])
    }

    @Test func explicitBootstrapModes() async throws {
        // An explicit built-in driver skips project drivers.
        let plain = try DriverSupport.rawFrames("defined('BASE_PATH')", directory: customDriver, bootstrap: "plain")
        #expect(plain.first { $0.type == "started" }?.payload["framework"] as? String == "plain")
        #expect(DriverSupport.bootstrapped(plain)?["framework"] as? String == "plain")
        // "custom" requires a project driver.
        let custom = try DriverSupport.rawFrames("1", directory: DriverSupport.fixture("composer"), bootstrap: "custom")
        let error = try #require(custom.first { $0.type == "error" }?.payload)
        #expect(error["stage"] as? String == "bootstrap")
        #expect((error["message"] as? String)?.contains("No Runlet project driver") == true)
        let forced = try DriverSupport.rawFrames("1", directory: customDriver, bootstrap: "custom")
        #expect(DriverSupport.bootstrapped(forced)?["framework"] as? String == "custom:AcmeApiDriver")
    }

    @Test func builtInDriversReportNameAndEmptyVariables() async throws {
        let plain = try DriverSupport.rawFrames("1", directory: DriverSupport.fixture("plain"))
        #expect(DriverSupport.bootstrapped(plain)?["driverName"] as? String == "PHP")
        #expect(DriverSupport.variables(plain) == [:], "variables must encode as a JSON object, not []")
        let composer = try DriverSupport.rawFrames("1", directory: DriverSupport.fixture("composer"))
        #expect(DriverSupport.bootstrapped(composer)?["driverName"] as? String == "Composer")
        // #12: plain and Composer projects have no application environment; the key is left out.
        #expect(DriverSupport.bootstrapped(plain)?.keys.contains("environment") == false)
        #expect(DriverSupport.bootstrapped(composer)?.keys.contains("environment") == false)
    }

    /// #12: a project driver reports the application's environment through environment(),
    /// with or without a return type (drivers written before the hook keep loading). The value
    /// is cleaned; a throwing environment() is a Run Log line and the run goes on.
    @Test func projectDriversReportTheirEnvironment() async throws {
        let typed = try DriverSupport.composerProject(drivers: [
            "AcmeDriver.php": "<?php class AcmeDriver extends Runlet\\Driver { public function bootstrap(string $p): void {} public function environment(): ?string { return \"  production\\n\"; } }",
        ])
        defer { try? FileManager.default.removeItem(at: typed) }
        let events = try await TestSupport.run("1", target: DriverSupport.target(typed.path))
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.bootstrapped?.environment == "production")
        #expect(events.logs.contains { $0.message.hasPrefix("Booted AcmeDriver (environment: production) in ") })

        let untyped = try DriverSupport.composerProject(drivers: [
            "LegacyDriver.php": "<?php class LegacyDriver extends Runlet\\Driver { public function bootstrap(string $p): void {} public function environment() { return str_repeat('e', 100); } }",
        ])
        defer { try? FileManager.default.removeItem(at: untyped) }
        let legacy = try await TestSupport.run("1", target: DriverSupport.target(untyped.path))
        #expect(legacy.errors.isEmpty, "\(legacy.errors)")
        #expect(legacy.bootstrapped?.environment == String(repeating: "e", count: 64))

        let failing = try DriverSupport.composerProject(drivers: [
            "FailingDriver.php": "<?php class FailingDriver extends Runlet\\Driver { public function bootstrap(string $p): void {} public function environment() { throw new RuntimeException('no config'); } }",
        ])
        defer { try? FileManager.default.removeItem(at: failing) }
        let failed = try await TestSupport.run("40 + 2", target: DriverSupport.target(failing.path))
        #expect(failed.errors.isEmpty, "\(failed.errors)")
        #expect(failed.result?.value?.scalar == "42")
        #expect(failed.bootstrapped?.environment == nil)
        #expect(failed.logs.contains { $0.message.contains("environment() failed") && $0.detail?.contains("no config") == true })
    }

    @Test(.enabled(if: TestSupport.herdPHP74 != nil, "requires PHP 7.4"))
    func customDriverOnPHP74() async throws {
        let events = try await TestSupport.run("[get_class($_app), PHP_VERSION]", target: DriverSupport.target(customDriver, php: TestSupport.herdPHP74!))
        #expect(events.started?.phpVersion?.hasPrefix("7.4") == true)
        #expect(events.bootstrapped?.framework == "custom:AcmeApiDriver")
        #expect(events.resultStrings?.first == "Acme\\App", "\(events.errors)")

        // #12: the environment() hook and its cleaning run on PHP 7.4 too.
        let project = try DriverSupport.composerProject(drivers: [
            "AcmeDriver.php": "<?php class AcmeDriver extends Runlet\\Driver { public function bootstrap(string $p): void {} public function environment(): ?string { return ' Staging '; } }",
        ])
        defer { try? FileManager.default.removeItem(at: project) }
        let staging = try await TestSupport.run("PHP_VERSION", target: DriverSupport.target(project.path, php: TestSupport.herdPHP74!))
        #expect(staging.result?.value?.scalar?.hasPrefix("7.4") == true, "\(staging.errors)")
        #expect(staging.bootstrapped?.environment == "Staging")
    }
}

// MARK: - Laravel family

@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct LaravelFamilyDriverTests {
    static var hasLaravelFixture: Bool {
        FileManager.default.fileExists(atPath: TestSupport.fixtures.appendingPathComponent("laravel-app/vendor").path)
    }

    @Test(.enabled(if: hasLaravelFixture, "requires scripts/setup-fixtures.sh"))
    func laravelReportsAppVariable() async throws {
        let frames = try DriverSupport.rawFrames("1", directory: DriverSupport.fixture("laravel-app"))
        let bootstrapped = try #require(DriverSupport.bootstrapped(frames))
        #expect(bootstrapped["framework"] as? String == "laravel")
        #expect(bootstrapped["driverName"] as? String == "Laravel")
        #expect(DriverSupport.variables(frames) == ["app": "Illuminate\\Foundation\\Application"])
        let events = try await TestSupport.run("$app->version()", target: DriverSupport.target(DriverSupport.fixture("laravel-app")))
        #expect(events.result?.value?.scalar == events.bootstrapped?.frameworkVersion)
    }

    /// #12: `app()->environment()` from the fixture's .env (APP_ENV=local), and production when
    /// the process environment sets APP_ENV (it wins over .env; the fixture is never edited).
    @Test(.enabled(if: hasLaravelFixture, "requires scripts/setup-fixtures.sh"))
    func laravelReportsTheAppEnvironment() async throws {
        let directory = DriverSupport.fixture("laravel-app")
        let local = try DriverSupport.rawFrames("app()->environment()", directory: directory)
        #expect(DriverSupport.bootstrapped(local)?["environment"] as? String == "local")

        var environment = ProcessInfo.processInfo.environment
        environment["APP_ENV"] = "production"
        let production = try DriverSupport.rawFrames("app()->environment()", directory: directory, environment: environment)
        #expect(DriverSupport.bootstrapped(production)?["environment"] as? String == "production")
        let result = production.first { $0.type == "result" }?.payload["value"] as? [String: Any]
        #expect(result?["scalar"] as? String == "production", "the snippet sees the same environment")
    }

    /// Tests/Fixtures/custom-laravel-driver/.runlet in a directory whose other entries link
    /// to the Laravel fixture.
    @Test(.enabled(if: hasLaravelFixture, "requires scripts/setup-fixtures.sh"))
    func projectDriverExtendingLaravelDriver() async throws {
        let directory = try DriverSupport.temporaryDirectory("tenant")
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = TestSupport.fixtures.appendingPathComponent("laravel-app")
        for entry in try FileManager.default.contentsOfDirectory(atPath: app.path) where entry != ".runlet" {
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(entry), withDestinationURL: app.appendingPathComponent(entry))
        }
        try FileManager.default.copyItem(at: TestSupport.fixtures.appendingPathComponent("custom-laravel-driver/.runlet"), to: directory.appendingPathComponent(".runlet"))

        let events = try await TestSupport.run("""
        [$tenant, config('app.tenant'), get_class($app), $formatter->format(App\\Models\\Widget::expensive()->sum('price'))]
        """, target: DriverSupport.target(directory.path))
        #expect(events.bootstrapped?.framework == "custom:TenantDriver")
        #expect(events.bootstrapped?.frameworkVersion == "13.34.0")
        #expect(events.resultStrings == ["acme", "acme", "Illuminate\\Foundation\\Application", "$14.50"], "\(events.errors)")

        let frames = try DriverSupport.rawFrames("1", directory: directory.path)
        #expect(DriverSupport.bootstrapped(frames)?["driverName"] as? String == "Tenant Laravel")
        #expect(DriverSupport.variables(frames) == ["app": "Illuminate\\Foundation\\Application", "tenant": "string", "formatter": "App\\Services\\PriceFormatter"])
    }

    /// Stub Lumen app: detected by package, booted with $app->boot() after constructing the
    /// console kernel, whose (empty in Lumen) bootstrap() must not run.
    @Test func lumenIsDetectedAndBootedLikeArtisan() async throws {
        let directory = try DriverSupport.temporaryDirectory("lumen")
        defer { try? FileManager.default.removeItem(at: directory) }
        try DriverSupport.write([
            "artisan": "",
            "composer.json": #"{"require":{"laravel/lumen-framework":"^10.0"}}"#,
            "bootstrap/app.php": "<?php return new Laravel\\Lumen\\Application();",
            "vendor/autoload.php": """
            <?php
            namespace Laravel\\Lumen {
                class Application {
                    public $log = [];
                    public function make($id) { $this->log[] = 'make ' . $id; return new Console\\Kernel($this); }
                    public function bound($id) { return true; }
                    public function boot() { $this->log[] = 'boot'; }
                    public function version() { return 'Lumen (10.0.4) (Laravel Components ^10.0)'; }
                    public function environment() { return 'testing'; }
                }
            }
            namespace Laravel\\Lumen\\Console {
                class Kernel {
                    private $app;
                    public function __construct($app) { $this->app = $app; }
                    public function bootstrap() { $this->app->log[] = 'kernel bootstrap'; }
                }
            }
            """,
        ], into: directory)
        let events = try await TestSupport.run("$app->log", target: DriverSupport.target(directory.path))
        #expect(events.started?.framework == "lumen")
        #expect(events.bootstrapped?.framework == "lumen")
        #expect(events.bootstrapped?.frameworkVersion == "10.0.4")
        #expect(events.bootstrapped?.environment == "testing")
        #expect(events.resultStrings == ["make Illuminate\\Contracts\\Console\\Kernel", "boot"], "\(events.errors)")
    }

    /// Stub Laravel Zero app: no artisan, detected by its framework package.
    @Test func laravelZeroIsDetectedWithoutArtisan() async throws {
        let directory = try DriverSupport.temporaryDirectory("zero")
        defer { try? FileManager.default.removeItem(at: directory) }
        try DriverSupport.write([
            "vendor/laravel-zero/framework/composer.json": "{}",
            "bootstrap/app.php": "<?php return new LaravelZero\\Framework\\Application();",
            "vendor/autoload.php": """
            <?php
            namespace LaravelZero\\Framework {
                class Application {
                    public $log = [];
                    public function make($id) { return new Kernel($this); }
                    public function version() { return 'v1.2.3'; }
                }
                class Kernel {
                    private $app;
                    public function __construct($app) { $this->app = $app; }
                    public function bootstrap() { $this->app->log[] = 'kernel bootstrap'; }
                }
            }
            """,
        ], into: directory)
        let events = try await TestSupport.run("$app->log", target: DriverSupport.target(directory.path))
        #expect(events.started?.framework == "laravel-zero")
        #expect(events.bootstrapped?.framework == "laravel-zero")
        #expect(events.bootstrapped?.frameworkVersion == "v1.2.3")
        // This stub application has no environment() method: nothing is reported.
        #expect(events.bootstrapped?.environment == nil)
        #expect(events.resultStrings == ["kernel bootstrap"], "\(events.errors)")
    }
}

// MARK: - WordPress

@Suite(.serialized, .fixture(.wordpress), .enabled(if: TestSupport.hasPHP && TestSupport.hasWordPressFixture,
                             "requires the WordPress fixture (scripts/setup-fixtures.sh; skipped when it could not be downloaded)"))
struct WordPressDriverTests {
    var target: TargetSnapshot { DriverSupport.target(DriverSupport.fixture("wordpress")) }

    @Test func bootsWordPressOnSQLite() async throws {
        let events = try await TestSupport.run("""
        dump(get_bloginfo('name'));
        dump($wpdb->prefix);
        [$GLOBALS['wp_version'], wp_list_pluck(get_posts(['orderby' => 'ID', 'order' => 'ASC']), 'post_title')]
        """, target: target)
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.started?.framework == "wordpress")
        #expect(events.bootstrapped?.framework == "wordpress")
        let version = try #require(events.bootstrapped?.frameworkVersion)
        #expect(events.dumps.map { $0.value.scalar } == ["Runlet WordPress Fixture", "rl_"])
        let entries = try #require(events.result?.value?.entries)
        #expect(entries.first?.value.scalar == version)
        #expect(entries.last?.value.entries?.compactMap { $0.value.scalar }.contains("Hello from Runlet") == true)

        let frames = try DriverSupport.rawFrames("1", directory: DriverSupport.fixture("wordpress"))
        #expect(DriverSupport.bootstrapped(frames)?["driverName"] as? String == "WordPress")
        #expect(DriverSupport.variables(frames)?["wpdb"]?.isEmpty == false)
    }

    /// #12: wp_get_environment_type(): "production" when nothing sets it (the fixture), or
    /// WP_ENVIRONMENT_TYPE from the process environment.
    @Test func reportsTheEnvironmentType() async throws {
        let directory = DriverSupport.fixture("wordpress")
        let unset = try DriverSupport.rawFrames("wp_get_environment_type()", directory: directory)
        #expect(DriverSupport.bootstrapped(unset)?["environment"] as? String == "production")

        var environment = ProcessInfo.processInfo.environment
        environment["WP_ENVIRONMENT_TYPE"] = "local"
        let local = try DriverSupport.rawFrames("1", directory: directory, environment: environment)
        #expect(DriverSupport.bootstrapped(local)?["environment"] as? String == "local")
    }

    @Test func wordpressGlobalsAndAdminAPIs() async throws {
        let events = try await TestSupport.run("""
        global $post;
        $post = get_posts(['title' => 'Hello from Runlet', 'post_type' => 'post'])[0];
        setup_postdata($post);
        [get_the_title(), get_class($GLOBALS['wp_query']), $GLOBALS['table_prefix'], function_exists('get_plugins'), has_action('init', 'wp_cron')]
        """, target: target)
        #expect(events.resultStrings == ["Hello from Runlet", "WP_Query", "rl_", "true", "false"], "\(events.errors)")
    }

    @Test func wpDieAndFatalErrorsAreReportedWithoutHTMLPages() async throws {
        let died = try await TestSupport.run("wp_die('Not <b>allowed</b>');", target: target)
        #expect(died.errors.first?.stage == .execute)
        #expect(died.errors.first?.message == "wp_die(): Not allowed")
        #expect(died.errors.first?.snippetLine == 1)
        #expect(!died.stdout.contains("<html"))

        let fatal = try await TestSupport.run("ini_set('memory_limit', '64M');\n$a = str_repeat('x', 128 * 1024 * 1024);", target: target)
        #expect(fatal.errors.first?.className == "FatalError")
        #expect(fatal.errors.first?.snippetLine == 2)
        #expect(fatal.finished?.reason == "fatal")
        // WordPress's own fatal-error handler (HTML page, recovery-mode email) is disabled.
        #expect(!fatal.stdout.contains("critical error"))
    }
}

// MARK: - Symfony

@Suite(.serialized, .enabled(if: TestSupport.hasPHP && FileManager.default.fileExists(atPath: TestSupport.fixtures.appendingPathComponent("symfony-app/vendor/autoload.php").path),
                             "requires the Symfony fixture (scripts/setup-fixtures.sh)"))
struct SymfonyDriverTests {
    @Test func bootsKernelAndExposesContainer() async throws {
        let directory = DriverSupport.fixture("symfony-app")
        let events = try await TestSupport.run("""
        [$container->has('kernel'), $kernel->getEnvironment(), Symfony\\Component\\HttpKernel\\Kernel::VERSION, $container->get('kernel') === $kernel]
        """, target: DriverSupport.target(directory))
        #expect(events.started?.framework == "symfony")
        #expect(events.bootstrapped?.framework == "symfony")
        let values = try #require(events.resultStrings, "\(events.errors)")
        #expect(values[0] == "true" && values[1] == "dev" && values[3] == "true")
        #expect(events.bootstrapped?.frameworkVersion == values[2])
        // #12: the kernel's environment.
        #expect(events.bootstrapped?.environment == "dev")

        let frames = try DriverSupport.rawFrames("1", directory: directory)
        #expect(DriverSupport.bootstrapped(frames)?["driverName"] as? String == "Symfony")
        #expect(DriverSupport.variables(frames)?["kernel"] == "App\\Kernel")
        #expect(DriverSupport.variables(frames)?["container"] != nil)
    }
}

// MARK: - Docker

/// Requires `docker compose -f Tests/Fixtures/docker/compose.yml -p runlet-fixtures up -d custom`
/// (or `scripts/setup-fixtures.sh docker`).
@Suite(.serialized, .live(.docker), .enabled(if: TestSupport.hasDocker, "requires a running Docker engine"))
struct DockerDriverTests {
    @Test func customDriverRunsInsideContainer() async throws {
        let docker = try #require(TestSupport.docker)
        let containers = try await docker.runningContainers()
        let container = try #require(containers.first { $0.composeProject == "runlet-fixtures" && $0.composeService == "custom" }, "start the fixture: docker compose -f Tests/Fixtures/docker/compose.yml -p runlet-fixtures up -d custom")
        let target = TargetSnapshot(kind: .docker, label: container.name, targetId: container.id, workingDirectory: "/var/www", phpExecutable: "php", containerId: container.id, containerName: container.name, image: container.image, temporaryDirectory: "/tmp")
        let events = try await TestSupport.run("dump(getenv('FIXTURE_SERVICE'), BASE_PATH);\n[get_class($_app), $_app->name()]", target: target)
        #expect(events.started?.workingDirectory == "/var/www")
        #expect(events.bootstrapped?.framework == "custom:AcmeApiDriver")
        #expect(events.bootstrapped?.frameworkVersion == "Acme Lease API")
        #expect(events.dumps.map { $0.value.scalar } == ["custom", "/var/www"])
        #expect(events.resultStrings == ["Acme\\App", "Acme Lease API"], "\(events.errors)")

        let frames = try DriverSupport.rawFrames("1", directory: "/var/www", command: [docker.executable, "exec", "-i", "-w", "/var/www", container.id, "php"] + RunnerBundle.phpArguments, environment: docker.environment)
        #expect(DriverSupport.variables(frames) == ["_app": "Acme\\App"])
    }
}
