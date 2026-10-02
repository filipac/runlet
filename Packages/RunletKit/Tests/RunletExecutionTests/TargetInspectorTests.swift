import Foundation
import Testing
@testable import RunletExecution

struct TargetInspectorTests {
    let fixtures = TestSupport.fixtures

    @Test func detectsCustomDriverFromFiles() {
        let facts = TargetInspector.staticFacts(projectRoot: fixtures.appendingPathComponent("custom-driver"))
        #expect(facts.framework == "custom:AcmeApiDriver")
        #expect(facts.driverName != nil)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: TestSupport.fixtures.appendingPathComponent("laravel-app/vendor").path)))
    func detectsLaravelVersionWithoutRunning() {
        let facts = TargetInspector.staticFacts(projectRoot: fixtures.appendingPathComponent("laravel-app"))
        #expect(facts.framework == "laravel")
        #expect(facts.frameworkVersion == "13.34.0")
    }

    @Test func composerAndPlain() {
        #expect(TargetInspector.staticFacts(projectRoot: fixtures.appendingPathComponent("composer")).framework == "composer")
        #expect(TargetInspector.staticFacts(projectRoot: fixtures.appendingPathComponent("plain")).framework == "plain")
    }

    @Test func literalReturnsAreRead() {
        let source = """
        class X extends \\Runlet\\Driver {
            public function name(): string { return 'Hellorider Lease API'; }
            public function version(): ?string
            {
                return 'Lease-API';
            }
        }
        """
        #expect(TargetInspector.literalReturn(of: "name", in: source) == "Hellorider Lease API")
        #expect(TargetInspector.literalReturn(of: "version", in: source) == "Lease-API")
        #expect(TargetInspector.literalReturn(of: "variables", in: source) == nil)
    }

    @Test(.enabled(if: TestSupport.hasDocker, "requires Docker fixtures"))
    func detectsInsideContainerWithoutRunningProjectCode() async throws {
        let docker = try #require(TestSupport.docker)
        let containers = try await docker.runningContainers()
        let laravel = try #require(containers.first { $0.composeProject == "runlet-fixtures" && $0.composeService == "laravel" })
        let facts = try #require(await docker.detectFacts(containerId: laravel.id, phpExecutable: "php", user: nil, workingDirectory: "/var/www/html"))
        #expect(facts.framework == "laravel")
        #expect(facts.frameworkVersion == "13.34.0")
        #expect(facts.phpVersion?.hasPrefix("8.4") == true)
        #expect(await docker.phpVersion(containerId: laravel.id, phpExecutable: "php", user: nil)?.hasPrefix("8.4") == true)
        if let custom = containers.first(where: { $0.composeProject == "runlet-fixtures" && $0.composeService == "custom" }) {
            let customFacts = await docker.detectFacts(containerId: custom.id, phpExecutable: "php", user: nil, workingDirectory: "/var/www")
            #expect(customFacts?.framework == "custom:AcmeApiDriver")
        }
    }
}
