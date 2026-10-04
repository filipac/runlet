import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// A project driver's `logPaths()` (#20): declared with the project's commands, before
/// bootstrap, for the log viewer.
@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct DriverLogPathsTests {
    static let driver = #"""
    <?php
    class LogsDriver extends \Runlet\Driver
    {
        public function canBootstrap(string $projectPath): bool { return true; }
        public function bootstrap(string $projectPath): void { require $projectPath . '/vendor/autoload.php'; }
        public function logPaths(): array
        {
            return ['logs/worker.log', '  var/log  ', '', 42, 'logs/worker.log', '/srv/app/logs/app-*.log', str_repeat('x', 2000)];
        }
    }
    """#

    @Test func driverDeclaresItsLogPaths() async throws {
        let project = try DriverSupport.composerProject(drivers: ["LogsDriver.php": Self.driver])
        defer { try? FileManager.default.removeItem(at: project) }
        let catalog = try await CommandsSupport.list(project.path)
        #expect(catalog.errors.isEmpty, "\(catalog.errors)")
        #expect(catalog.logPathsDeclared)
        // Strings only, trimmed, once each, at most 1,024 characters.
        #expect(catalog.logPaths == ["logs/worker.log", "var/log", "/srv/app/logs/app-*.log"])
    }

    @Test func logPathsAreDeclaredEvenWhenBootstrapFails() async throws {
        let failing = Self.driver.replacingOccurrences(of: "require $projectPath . '/vendor/autoload.php';", with: "throw new \\RuntimeException('database is down');")
        let project = try DriverSupport.composerProject(drivers: ["LogsDriver.php": failing])
        defer { try? FileManager.default.removeItem(at: project) }
        let catalog = try await CommandsSupport.list(project.path)
        #expect(!catalog.driverListed)
        #expect(catalog.logPathsDeclared)
        #expect(catalog.logPaths.first == "logs/worker.log")
    }

    @Test func driversWithoutLogPathsDeclareNone() async throws {
        let catalog = try await CommandsSupport.list(DriverSupport.fixture("custom-driver"))
        #expect(catalog.logPathsDeclared)
        #expect(catalog.logPaths.isEmpty)
    }

    @Test func failingLogPathsIsANotice() async throws {
        let driver = Self.driver.replacingOccurrences(of: "logPaths(): array\n    {", with: "logPaths(): array\n    {\n        throw new \\LogicException('nope');")
        let project = try DriverSupport.composerProject(drivers: ["LogsDriver.php": driver])
        defer { try? FileManager.default.removeItem(at: project) }
        let catalog = try await CommandsSupport.list(project.path)
        #expect(!catalog.logPathsDeclared)
        #expect(catalog.notices.contains { $0.contains("logPaths() failed") && $0.contains("nope") }, "\(catalog.notices)")
        #expect(catalog.driverListed)
    }
}
