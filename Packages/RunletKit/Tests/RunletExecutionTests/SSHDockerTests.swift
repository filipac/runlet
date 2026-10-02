import Darwin
import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// Docker on an SSH host (SSH-6) against the SSH fixture, whose `docker` is a fake
/// (`Tests/Fixtures/docker/ssh/fake-docker`) that lists made-up containers and runs `exec`
/// with the fixture's own PHP in their folders. Part of the serialized `SSHRunTests`.
extension SSHRunTests {
    static let appId = String(repeating: "a", count: 64)
    static let workerIds = [String(repeating: "b", count: 64), String(repeating: "c", count: 64)]
    static let legacyId = String(repeating: "d", count: 64)

    func installContainers(_ environment: SSHFixture.Environment, appId: String = SSHRunTests.appId) async throws {
        try await environment.installFakeDocker(containers: [
            "\(appId)|shop-app-1|shop|app|1|/srv/app|acme/shop-php:8.4|/srv/app|/var/www/html",
            "\(Self.workerIds[0])|shop-worker-1|shop|worker|1|/srv/app|acme/shop-php:8.4||",
            "\(Self.workerIds[1])|shop-worker-2|shop|worker|2|/srv/app|acme/shop-php:8.4||",
            "\(Self.legacyId)|legacy||||/srv/app|php:8.4-cli||",
        ])
    }

    func containerTarget(_ endpoint: SSHEndpoint, id: String = SSHRunTests.appId, dockerCommand: String = "docker") -> TargetSnapshot {
        TargetSnapshot(kind: .ssh, label: "fixture container", targetId: "ssh-container", workingDirectory: "/srv/app", phpExecutable: "php", containerId: id, containerName: "shop-app-1", image: "acme/shop-php:8.4", temporaryDirectory: "/tmp", ssh: endpoint, dockerCommand: dockerCommand)
    }

    @Test func remoteDockerListsAndResolvesContainersOnTheServer() async throws {
        let environment = try await SSHFixture.environment()
        try await installContainers(environment)
        let client = environment.client()
        let endpoint = environment.endpoint()
        defer { Task { await client.disconnect(endpoint) } }
        let docker = DockerCLI(ssh: client, endpoint: endpoint, dockerCommand: "docker")

        let containers = try await docker.runningContainers()
        #expect(containers.count == 4)
        let app = try #require(containers.first { $0.id == Self.appId })
        #expect(app.composeProject == "shop" && app.composeService == "app" && app.name == "shop-app-1")
        // The server's directory maps into the container through its bind mount.
        #expect(app.containerPath(forHostPath: "/srv/app") == "/var/www/html")
        #expect(app.containerPath(forHostPath: "/srv/app/public/") == "/var/www/html/public")
        #expect(app.containerPath(forHostPath: "/srv/other") == nil)

        let identity = ContainerIdentity(composeProject: "shop", composeService: "app")
        #expect(DockerProfileResolver.resolve(identity, among: containers).container?.id == Self.appId)
        // Two replicas: the user chooses; never the first one.
        guard case .ambiguous(let replicas) = DockerProfileResolver.resolve(ContainerIdentity(composeProject: "shop", composeService: "worker"), among: containers) else {
            Issue.record("replicas must be ambiguous")
            return
        }
        #expect(replicas.map(\.name) == ["shop-worker-1", "shop-worker-2"])
        // A recreated Compose container (new ID) resolves, marked as recreated.
        let recreated = ContainerIdentity(composeProject: "shop", composeService: "app", lastContainerId: String(repeating: "f", count: 64))
        #expect(DockerProfileResolver.resolve(recreated, among: containers) == .resolved(app, recreated: true))
        // A named container whose ID changed needs confirmation.
        let renamed = ContainerIdentity(containerName: "legacy", lastContainerId: String(repeating: "e", count: 64), lastImage: "php:8.4-cli")
        guard case .needsConfirmation = DockerProfileResolver.resolve(renamed, among: containers) else {
            Issue.record("a recreated named container needs confirmation")
            return
        }
        #expect(await docker.inspect(String(repeating: "9", count: 64)) == nil)

        // Docker missing on the server, or ssh failing, is explained.
        let missing = DockerCLI(ssh: client, endpoint: endpoint, dockerCommand: "/opt/nowhere/docker")
        do {
            _ = try await missing.runningContainers()
            Issue.record("a missing docker must fail")
        } catch {
            #expect("\(error)".contains("Docker was not found on"), "\(error)")
        }
        let unknown = DockerCLI(ssh: client, endpoint: environment.endpoint(host: SSHFixture.Environment.unknownKeyHost), dockerCommand: "docker")
        do {
            _ = try await unknown.runningContainers()
            Issue.record("an unknown host key must fail")
        } catch {
            #expect("\(error)".contains("never accepts a host key"), "\(error)")
        }
    }

    @Test func runsInsideAContainerOnTheServerAndStopsThere() async throws {
        let environment = try await SSHFixture.environment()
        try await installContainers(environment)
        let client = environment.client()
        let endpoint = environment.endpoint()
        defer { Task { await client.disconnect(endpoint) } }
        let engine = environment.engine()
        let target = containerTarget(endpoint)

        let (events, request) = try await run("dump(getenv('RUNLET_RUN_ID'), getenv('TMPDIR'));\n(new Acme\\Greeter())->greet('box')", environment, target: target, engine: engine)
        #expect(events.finished?.status == .completed, "\(events.errors)")
        #expect(events.dumps.first?.value.scalar == request.runId.uuidString)
        #expect(events.started?.framework == "composer")
        #expect(events.result?.value?.scalar?.hasPrefix("Hello, box") == true, "\(events.errors)")

        // Stop goes through `docker exec` on the server (the runner-only helper, base64 PHP).
        let long = RunRequest(tabId: UUID(), documentVersion: 1, target: target, code: "echo 'go';\nwhile (true) { usleep(10000); }")
        var outcome: CancelOutcome?
        var stopped: [RunEvent] = []
        for await event in try await engine.start(long) {
            stopped.append(event)
            if case .stdout = event.kind, outcome == nil {
                try await Task.sleep(for: .milliseconds(200))
                outcome = await engine.cancel(runId: long.runId)
            }
        }
        #expect(outcome?.confirmed == true, "\(outcome?.message ?? "")")
        #expect(outcome?.message.contains("inside the container") == true)
        #expect(stopped.finished?.status == .cancelled)
        let left = try await environment.exec("ps -u runlet -o args= || true")
        #expect(!left.contains("display_errors=stderr"), "the runner survived: \(left)")

        // The container is checked again right before launch: a vanished one never runs.
        let gone = try await run("1", environment, target: containerTarget(endpoint, id: String(repeating: "9", count: 64)), engine: engine).events
        #expect(gone.finished?.reason == "launch-failed")
        #expect(gone.errors.first?.message.contains("no longer exists") == true, "\(gone.errors)")
    }

    @Test func probesFactsListingsAndCommandsInsideARemoteContainer() async throws {
        let environment = try await SSHFixture.environment()
        try await installContainers(environment)
        let client = environment.client()
        let endpoint = environment.endpoint()
        defer { Task { await client.disconnect(endpoint) } }
        let docker = DockerCLI(ssh: client, endpoint: endpoint, dockerCommand: "docker")

        let probe = await docker.probe(containerId: Self.appId, phpExecutable: "php", user: nil, workingDirectory: "/srv/app", temporaryDirectory: "/tmp", extraCandidates: ["/srv/app"])
        #expect(probe.error == nil, "\(probe.error ?? "")")
        #expect(probe.phpVersion?.hasPrefix("8.4") == true && probe.framework == "composer" && probe.canSignal == "posix")
        #expect(probe.candidates == ["/srv/app"])
        #expect(await docker.phpVersion(containerId: Self.appId, phpExecutable: "php", user: nil)?.hasPrefix("8.4") == true)
        #expect(await docker.detectFacts(containerId: Self.appId, phpExecutable: "php", user: nil, workingDirectory: "/srv/app")?.framework == "composer")

        let listing = await docker.listDirectory(containerId: Self.appId, user: nil, phpExecutable: "php", path: "/srv", place: "shop-app-1")
        #expect(listing.error == nil && listing.entries.contains { $0.name == "app" && $0.markers == ["composer"] }, "\(listing)")

        // Listing commands boots the project inside the container.
        let catalog = try await environment.engine().listCommands(target: containerTarget(endpoint))
        #expect(catalog.framework == "composer" && catalog.errors.isEmpty, "\(catalog.errors)")

        // A project command in the container, through the terminal argv.
        let command = ProjectCommand(name: "where", commandLine: "php -r 'echo getcwd(), \"|\", getenv(\"TMPDIR\"), PHP_EOL;'", origin: .driver, source: "Test")
        let request = try ProjectCommandLauncher.terminalRequest(for: command, target: containerTarget(endpoint), dockerExecutable: nil, ssh: client)
        let terminal = try PseudoTerminal(try #require(request.executable), environment: client.environment)
        defer { terminal.stop() }
        #expect(try await terminal.waitFor { !terminal.isRunning }, "\(terminal.text)")
        #expect(terminal.exitCode == 0 && terminal.text.contains("/srv/app|/tmp"), "\(terminal.text)")
    }
}
