import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// #80: the package tests reach Docker only through `Tests/Fixtures/docker/fixtures-only-docker`
/// (`TestSupport.docker`). These tests put a recording stand-in for Docker
/// (`Tests/Fixtures/docker/recording-docker`) behind the wrapper the same way, and check that a
/// container outside `runlet-fixtures` is never listed, inspected, or exec'd, whatever a test
/// asks for: the stand-in's call log is what Docker would have received.
@Suite struct FixturesOnlyDockerTests {
    /// The stand-in's containers.
    static let fixture = String(repeating: "a", count: 64)    // runlet-fixtures-laravel-1
    static let sandbox = String(repeating: "d", count: 64)    // runlet-sandbox-0001
    static let foreign = String(repeating: "b", count: 64)    // personal-db-1, another project
    static let lookalike = String(repeating: "c", count: 64)  // named "aaaaaaaaaaaa", like the fixture's short ID
    static let fixtureShortId = String(fixture.prefix(12))

    /// The ways a test could name a container outside runlet-fixtures.
    static let foreignNames = [foreign, String(foreign.prefix(12)), "personal-db-1", lookalike, String(lookalike.prefix(12))]

    struct StandIn {
        let docker: DockerCLI
        let folder: URL

        /// Every call that reached the stand-in, as its arguments.
        func calls() throws -> [[String]] {
            let log = folder.appendingPathComponent("calls.log")
            guard FileManager.default.fileExists(atPath: log.path) else { return [] }
            return try String(contentsOf: log, encoding: .utf8)
                .split(separator: "\u{1E}", omittingEmptySubsequences: true)
                .map { $0.split(separator: "\u{1F}", omittingEmptySubsequences: false).dropLast().map(String.init) }
        }
    }

    /// The stand-in in a fresh folder (its own call log), behind the wrapper as
    /// `TestSupport.docker` puts the real Docker CLI.
    static func standIn() throws -> StandIn {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-recording-docker-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let engine = folder.appendingPathComponent("docker")
        try FileManager.default.copyItem(at: TestSupport.fixtures.appendingPathComponent("docker/recording-docker"), to: engine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engine.path)
        return StandIn(docker: try TestSupport.fixturesOnlyDocker(wrapping: engine.path), folder: folder)
    }

    /// Docker never saw a container outside runlet-fixtures: every `ps` it got is filtered by a
    /// label of Runlet's disposable containers, nothing else lists or looks containers up,
    /// and every container it was handed is the fixture's or the sandbox's full ID.
    static func expectOnlyRunletContainers(_ calls: [[String]], sourceLocation: Testing.SourceLocation = #_sourceLocation) {
        let allowedFilters: Set<String> = ["label=com.docker.compose.project=runlet-fixtures", "label=com.docker.compose.project=runlet-fixtures-recreate", "label=dev.runlet.owned=sandbox"]
        for call in calls {
            let command = call.first ?? ""
            #expect(["version", "ps", "inspect", "exec"].contains(command), "unexpected docker \(call)", sourceLocation: sourceLocation)
            if command == "ps" {
                let filters = call.indices.dropLast().filter { call[$0] == "--filter" }.map { call[$0 + 1] }
                #expect(filters.contains { allowedFilters.contains($0) }, "unfiltered docker \(call)", sourceLocation: sourceLocation)
                #expect(filters.allSatisfy { $0.hasPrefix("label=") }, "docker ps looked a container up: \(call)", sourceLocation: sourceLocation)
            }
            for argument in call.dropFirst() {
                for name in foreignNames {
                    #expect(argument != name && !argument.contains(String(name.prefix(12))), "docker \(command) was handed \(name)", sourceLocation: sourceLocation)
                }
                #expect(argument != fixtureShortId, "docker \(command) got a short ID it could resolve to the container named \(fixtureShortId)", sourceLocation: sourceLocation)
            }
            if command == "inspect" {
                let containers = call.dropFirst().filter { !$0.hasPrefix("-") && $0 != "container" }
                #expect(!containers.isEmpty && containers.allSatisfy { $0 == fixture || $0 == sandbox }, "\(call)", sourceLocation: sourceLocation)
            }
            if command == "exec" {
                #expect(call.contains(fixture) || call.contains(sandbox), "\(call)", sourceLocation: sourceLocation)
            }
        }
    }

    @Test func listingShowsOnlyRunletContainers() async throws {
        let standIn = try Self.standIn()
        let docker = standIn.docker
        #expect(try await docker.serverVersion() == "29.0.0")
        // Discovery: `docker ps` and `docker inspect` of what it listed (sandbox containers are
        // Runlet's own and left out of the result).
        #expect(try await docker.runningContainers().map(\.id) == [Self.fixture])
        // Whatever a test passes to `ps`, it sees Runlet's containers only.
        let names = String(decoding: try await docker.run(["ps", "-a", "--format", "{{.Names}}"]), as: UTF8.self)
        #expect(Set(names.split(whereSeparator: \.isNewline).map(String.init)) == ["runlet-fixtures-laravel-1", "runlet-sandbox-0001"])
        // A profile for another container resolves to nothing.
        for identity in [ContainerIdentity(composeProject: "personal", composeService: "db"), ContainerIdentity(containerName: "personal-db-1", lastContainerId: Self.foreign)] {
            let resolution = try await DockerProfileResolver.resolve(DockerProfile(name: "Personal", identity: identity, workingDirectory: "/"), docker: docker)
            guard case .notRunning = resolution else {
                Issue.record("expected .notRunning, got \(resolution)")
                continue
            }
        }
        let calls = try standIn.calls()
        #expect(calls.contains { $0.first == "inspect" }, "the listing was inspected")
        Self.expectOnlyRunletContainers(calls)
    }

    @Test func otherContainersAreNeverInspectedOrExeced() async throws {
        let standIn = try Self.standIn()
        let docker = standIn.docker
        for name in Self.foreignNames {
            // To `inspect`, it doesn't exist, as if it had gone.
            #expect(await docker.inspect(name) == nil, "\(name)")
            #expect(try await docker.inspect([Self.fixture, name]).map(\.id) == [Self.fixture], "\(name)")
            #expect(await docker.phpVersion(containerId: name, phpExecutable: "php", user: nil) == nil, "\(name)")
            let probe = await docker.probe(containerId: name, phpExecutable: "php", user: "www-data", workingDirectory: "/var/www/html", temporaryDirectory: "/tmp", extraCandidates: [])
            #expect(probe.error?.contains("not a runlet-fixtures container") == true, "\(probe.error ?? "")")
            for arguments in [["exec", "-i", "-w", "/", name, "php"], ["cp", "/tmp/x", "\(name):/tmp/x"], ["cp", "\(name):/etc/passwd", "/tmp/x"], ["pause", name], ["unpause", name], ["kill", "-s", "TERM", name], ["rm", "-f", name]] {
                await #expect(throws: DockerError.self, "\(arguments)") { try await docker.run(arguments) }
            }
            // A run against it fails before launch.
            let target = TargetSnapshot(kind: .docker, label: "personal", targetId: name, workingDirectory: "/", phpExecutable: "php", containerId: name)
            let events = try await TestSupport.run("1", target: target, engine: ExecutionEngine(bundle: TestSupport.bundle, docker: docker))
            #expect(events.finished?.reason == "launch-failed", "\(events.errors)")
        }
        // The fixture's short ID is also the other container's name: Docker would take the name
        // first, so the wrapper hands it the fixture's full ID instead.
        #expect(await docker.inspect(Self.fixtureShortId)?.id == Self.fixture)
        #expect(await docker.phpVersion(containerId: Self.fixtureShortId, phpExecutable: "php", user: nil) == "8.4.0")
        #expect(await docker.inspect("runlet-fixtures-laravel-1")?.id == Self.fixture)
        Self.expectOnlyRunletContainers(try standIn.calls())
    }

    @Test func otherCommandsAreRefused() async throws {
        let standIn = try Self.standIn()
        let docker = standIn.docker
        let refused: [[String]] = [
            ["container", "ls"], ["logs", Self.fixture], ["top", Self.fixture], ["stats", "--no-stream"], ["events"], ["system", "df"],
            ["compose", "-p", "personal", "ps"], ["compose", "ps"], ["run", "--rm", "php:8.4-cli", "php", "-v"], ["exec", "-it"],
        ]
        for arguments in refused {
            await #expect(throws: DockerError.self, "\(arguments)") { try await docker.run(arguments) }
        }
        let calls = try standIn.calls()
        #expect(calls.allSatisfy { $0.first == "ps" }, "\(calls)")
        Self.expectOnlyRunletContainers(calls)
        // Runlet's own sandbox and fixture Compose calls pass.
        try await docker.run(["run", "--rm", "-i", "--label", "dev.runlet.owned=sandbox", "php:8.4-cli", "php", "-v"])
        try await docker.run(["compose", "-p", "runlet-fixtures", "ps"])
        try await docker.run(["kill", "runlet-sandbox-not-started-yet"])
    }

    @Test func theWrapperNeverWrapsItself() async throws {
        let wrapped = try TestSupport.fixturesOnlyDocker(wrapping: TestSupport.fixturesOnlyDockerScript.path)
        await #expect(throws: DockerError.self) { try await wrapped.run(["version"]) }
        #expect(TestSupport.realDockerExecutable.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() } != TestSupport.fixturesOnlyDockerScript.resolvingSymlinksInPath())
    }

    /// The Docker CLI every Docker suite uses is the wrapper: it refuses a command before
    /// running Docker at all.
    @Test(.enabled(if: TestSupport.hasDocker, "requires a running Docker engine"))
    func testSupportDockerGoesThroughTheWrapper() async throws {
        let docker = try #require(TestSupport.docker)
        do {
            try await docker.run(["container", "ls"])
            Issue.record("docker container ls was not refused")
        } catch let error as DockerError {
            #expect(error.message.contains("fixtures-only-docker"), "\(error.message)")
        }
        let launcher = try String(contentsOfFile: docker.executable, encoding: .utf8)
        #expect(launcher.contains(TestSupport.fixturesOnlyDockerScript.path))
    }
}
