import Foundation
import RunletCore
import Testing
@testable import RunletExecution

struct ResolverTests {
    func container(_ id: String, name: String, project: String? = nil, service: String? = nil, image: String = "app:1", running: Bool = true) -> ContainerInfo {
        var labels: [String: String] = [:]
        if let project { labels["com.docker.compose.project"] = project }
        if let service { labels["com.docker.compose.service"] = service }
        return ContainerInfo(id: id, name: name, image: image, running: running, status: running ? "running" : "exited", labels: labels, workingDir: "/app", user: "", mounts: [], created: "")
    }

    @Test func composeIdentitySurvivesRecreation() {
        let identity = ContainerIdentity(composeProject: "shop", composeService: "php", containerName: "shop-php-1", lastContainerId: "old")
        let result = DockerProfileResolver.resolve(identity, among: [container("new", name: "shop-php-1", project: "shop", service: "php"), container("x", name: "other", project: "shop", service: "db")])
        #expect(result == .resolved(container("new", name: "shop-php-1", project: "shop", service: "php"), recreated: true))
    }

    @Test func replicasAreAmbiguous() {
        let identity = ContainerIdentity(composeProject: "shop", composeService: "worker")
        let result = DockerProfileResolver.resolve(identity, among: [container("a", name: "w1", project: "shop", service: "worker"), container("b", name: "w2", project: "shop", service: "worker")])
        if case .ambiguous(let matches) = result { #expect(matches.count == 2) } else { Issue.record("expected ambiguous") }
    }

    @Test func aChosenReplicaStaysChosenUntilItIsGone() {
        let replicas = [container("a", name: "w1", project: "shop", service: "worker"), container("b", name: "w2", project: "shop", service: "worker")]
        let chosen = ContainerIdentity(composeProject: "shop", composeService: "worker", lastContainerId: "b")
        #expect(DockerProfileResolver.resolve(chosen, among: replicas) == .resolved(replicas[1], recreated: false))
        // The chosen replica stopped: ask again, never pick another one.
        let gone = ContainerIdentity(composeProject: "shop", composeService: "worker", lastContainerId: "c")
        if case .ambiguous = DockerProfileResolver.resolve(gone, among: replicas) {} else { Issue.record("expected ambiguous") }
    }

    @Test func nameOnlyReplacementNeedsConfirmation() {
        let identity = ContainerIdentity(containerName: "legacy", lastContainerId: "old", lastImage: "legacy:1")
        let result = DockerProfileResolver.resolve(identity, among: [container("new", name: "legacy", image: "legacy:2")])
        if case .needsConfirmation(let match, let reason) = result {
            #expect(match.id == "new")
            #expect(reason.contains("legacy:2"))
        } else {
            Issue.record("expected confirmation")
        }
        // Same container ID: resolved without asking.
        #expect(DockerProfileResolver.resolve(identity, among: [container("old", name: "legacy")]).container?.id == "old")
    }

    @Test func stoppedContainersDoNotResolve() {
        let identity = ContainerIdentity(composeProject: "shop", composeService: "php")
        if case .notRunning = DockerProfileResolver.resolve(identity, among: [container("a", name: "p", project: "shop", service: "php", running: false)]) {} else {
            Issue.record("expected notRunning")
        }
    }
}

struct MountMappingTests {
    @Test func hostPathFollowsClosestBindMount() {
        let container = ContainerInfo(id: "x", name: "api", image: "php", running: true, status: "running", labels: [:], workingDir: "/var/www", user: "", mounts: [
            ContainerMount(type: "bind", source: "/Users/dev/Code/lease-api", destination: "/var/www"),
            ContainerMount(type: "bind", source: "/host_mnt/Users/dev/shared", destination: "/var/www/shared"),
            ContainerMount(type: "volume", source: "/var/lib/docker/volumes/v/_data", destination: "/var/www/vendor"),
        ], created: "")
        #expect(container.hostPath(forContainerPath: "/var/www") == "/Users/dev/Code/lease-api")
        #expect(container.hostPath(forContainerPath: "/var/www/src/App.php") == "/Users/dev/Code/lease-api/src/App.php")
        #expect(container.hostPath(forContainerPath: "/var/www/shared/x") == "/Users/dev/shared/x")
        #expect(container.hostPath(forContainerPath: "/var/wwwx") == nil)
        #expect(container.hostPath(forContainerPath: "/etc") == nil)
    }
}
