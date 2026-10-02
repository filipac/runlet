import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// Requires `scripts/setup-fixtures.sh docker` (disposable `runlet-fixtures` Compose project).
@Suite(.serialized, .enabled(if: TestSupport.hasDocker, "requires a running Docker engine"))
struct DockerRunTests {
    var docker: DockerCLI { TestSupport.docker! }

    func fixtureContainer(_ service: String) async throws -> ContainerInfo {
        let containers = try await docker.runningContainers()
        return try #require(containers.first { $0.composeProject == "runlet-fixtures" && $0.composeService == service }, "start fixtures with scripts/setup-fixtures.sh docker")
    }

    func target(_ container: ContainerInfo, workingDirectory: String, user: String? = nil) -> TargetSnapshot {
        TargetSnapshot(kind: .docker, label: container.name, targetId: container.id, workingDirectory: workingDirectory, phpExecutable: "php", containerId: container.id, containerName: container.name, image: container.image, user: user, temporaryDirectory: "/tmp")
    }

    @Test func discoversFixtureContainersWithComposeLabels() async throws {
        let restricted = try await fixtureContainer("restricted")
        #expect(restricted.user == "1000:1000")
        #expect(DockerCLI.workingDirectorySuggestions(for: restricted).first == "/app")
        let containers = try await docker.runningContainers()
        #expect(!containers.contains { $0.isRunletOwned })
    }

    @Test func runsLaravelInsideContainerWithItsEnvironment() async throws {
        let container = try await fixtureContainer("laravel")
        let events = try await TestSupport.run("dump(getenv('FIXTURE_SERVICE'));\nApp\\Models\\Widget::orderBy('price')->pluck('name')", target: target(container, workingDirectory: "/var/www/html"))
        #expect(events.started?.framework == "laravel")
        #expect(events.dumps.first?.value.scalar == "laravel")
        let names = events.result?.value?.entries?.first { $0.key == "items" }?.value.entries?.map { $0.value.scalar }
        #expect(names == ["Gear", "Sprocket", "Flywheel"], "\(events.errors)")
    }

    @Test func restrictedNonRootReadOnlyContainer() async throws {
        let container = try await fixtureContainer("restricted")
        let probe = await docker.probe(containerId: container.id, phpExecutable: "php", user: nil, workingDirectory: "/app", temporaryDirectory: "/scratch", extraCandidates: ["/app"])
        #expect(probe.uid == 1000)
        #expect(probe.framework == "composer")
        #expect(probe.temporaryDirectoryWritable)
        #expect(probe.candidates == ["/app"])
        let events = try await TestSupport.run("dump(posix_geteuid(), is_writable('/app'));\n(new Acme\\Greeter())->greet(PHP_VERSION)", target: target(container, workingDirectory: "/app"))
        #expect(events.started?.phpVersion?.hasPrefix("7.4") == true)
        #expect(events.dumps.map { $0.value.scalar } == ["1000", "false"])
        #expect(events.result?.value?.scalar?.hasPrefix("Hello, 7.4") == true)
    }

    @Test func explicitUserOverride() async throws {
        let container = try await fixtureContainer("laravel")
        let events = try await TestSupport.run("posix_geteuid()", target: target(container, workingDirectory: "/var/www/html", user: "33"))
        #expect(events.result?.value?.scalar == "33")
    }

    @Test func stopKillsRunnerButNotContainer() async throws {
        for service in ["laravel", "restricted"] {
            let container = try await fixtureContainer(service)
            let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: docker)
            let workingDirectory = service == "laravel" ? "/var/www/html" : "/app"
            let request = RunRequest(tabId: UUID(), documentVersion: 1, target: target(container, workingDirectory: workingDirectory), code: "echo 'go';\nwhile (true) { usleep(10000); }")
            var events: [RunEvent] = []
            var runnerPid: Int?
            var outcome: CancelOutcome?
            let clock = ContinuousClock()
            var stopAt: ContinuousClock.Instant?
            for await event in try await engine.start(request) {
                events.append(event)
                if case .started(let info) = event.kind { runnerPid = info.pid }
                if case .stdout = event.kind, stopAt == nil {
                    stopAt = clock.now
                    outcome = await engine.cancel(runId: request.runId)
                }
            }
            #expect(clock.now - stopAt! < .seconds(5), "\(service)")
            #expect(outcome?.confirmed == true, "\(service): \(outcome?.message ?? "")")
            #expect(events.finished?.status == .cancelled)
            // The PHP runner process is gone inside the container…
            let pid = try #require(runnerPid)
            let check = await DockerExecAdapter.signal(docker: docker, containerId: container.id, user: nil, php: "php", pid: pid, runId: request.runId, signal: 0)
            #expect(check == "gone" || check == "mismatch", "\(service): \(check)")
            // …and the application container keeps running.
            #expect(await docker.inspect(container.id)?.running == true)
        }
    }

    @Test func refusesToRunInRemovedContainer() async throws {
        let container = try await fixtureContainer("laravel")
        var snapshot = target(container, workingDirectory: "/var/www/html")
        snapshot.containerId = String(repeating: "0", count: 64)
        let events = try await TestSupport.run("1", target: snapshot)
        #expect(events.errors.first?.stage == .launch)
        #expect(events.finished?.reason == "launch-failed")
    }

    @Test func resolvesComposeIdentityAndAmbiguousReplicas() async throws {
        let containers = try await docker.runningContainers()
        let laravel = try await fixtureContainer("laravel")
        var identity = laravel.identity
        identity.lastContainerId = "previous-container-id"
        guard case .resolved(let resolved, let recreated) = DockerProfileResolver.resolve(identity, among: containers) else {
            Issue.record("expected resolution")
            return
        }
        #expect(resolved.id == laravel.id)
        #expect(recreated)
        let replicas = ContainerIdentity(composeProject: "runlet-fixtures", composeService: "replicas")
        guard case .ambiguous(let matches) = DockerProfileResolver.resolve(replicas, among: containers) else {
            Issue.record("replicas should be ambiguous")
            return
        }
        #expect(matches.count == 2)
    }
}
