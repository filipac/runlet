import Foundation
import Testing
@testable import RunletCore

struct KubernetesTests {
    func profile() -> KubernetesProfile {
        KubernetesProfile(name: "Shop", context: "example", namespace: "shop", labelSelector: "app=shop", container: "app")
    }
    func pod(_ name: String, uid: String? = nil, created: String = "2026-01-01", phase: String = "Running", ready: [String] = ["app"], deleting: Bool = false) -> KubernetesPod {
        KubernetesPod(identity: .init(name: name, uid: uid ?? name), node: "node", created: created, phase: phase, deleting: deleting, containers: ["app", "sidecar"], readyContainers: ready, restarts: 0)
    }

    @Test func olderFilesAndRoundTrip() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(TargetLibrary.self, from: Data("{}".utf8)).kubernetesProfiles.isEmpty)
        #expect(try decoder.decode(AppSettings.self, from: Data("{}".utf8)).kubectlExecutable == nil)
        var saved = profile()
        saved.environment = .production
        saved.lastPod = .init(name: "shop-old", uid: "old")
        let library = TargetLibrary(kubernetesProfiles: [saved])
        #expect(try decoder.decode(TargetLibrary.self, from: JSONEncoder().encode(library)) == library)
        let ref = TargetRef.kubernetes(saved.id)
        #expect(try decoder.decode(TargetRef.self, from: JSONEncoder().encode(ref)) == ref)
        #expect(library.environment(for: ref) == .production)
        #expect(library.target(matching: library.selector(for: ref)) == .found(ref))
        #expect(MCPApprovalPolicy.decide(.init(target: ref, environment: .production, allowedForSession: true)) == .ask(.init(offersSessionAllowance: false, isProduction: true, connectsSSH: false)))
    }

    @Test func resolutionNeverUsesDiagnosticPodAsConsent() {
        var saved = profile()
        let a = pod("a"), b = pod("b")
        saved.lastPod = b.identity
        #expect(KubernetesResolver.resolve(saved, pods: [b, a]) == .ambiguous([a, b]))
        #expect(KubernetesResolver.resolve(saved, pods: [b, a], choice: b.identity) == .resolved(b))
        saved.interchangeableReplicas = true
        #expect(KubernetesResolver.resolve(saved, pods: [b, a]) == .resolved(a))
        #expect(KubernetesResolver.resolve(saved, pods: [pod("old", created: "2025-01-01"), a]) == .resolved(pod("old", created: "2025-01-01")))
        saved.pinnedPod = b.identity
        if case .unavailable = KubernetesResolver.resolve(saved, pods: [a, pod("b", uid: "replacement")]) {} else { Issue.record("Pin must not follow a reused name") }
    }

    @Test func readinessAndUIDRecheck() {
        let saved = profile(), ready = pod("ready")
        let candidates = [pod("pending", phase: "Pending"), pod("deleting", deleting: true), pod("not-ready", ready: ["sidecar"]), ready]
        #expect(KubernetesResolver.resolve(saved, pods: candidates) == .resolved(ready))
        let target = KubernetesRunTarget(executable: "/usr/bin/kubectl", profile: saved, pod: ready.identity)
        #expect(KubernetesResolver.recheck(ready, target: target))
        #expect(!KubernetesResolver.recheck(pod("ready", uid: "reused"), target: target))
        #expect(!KubernetesResolver.recheck(pod("ready", ready: []), target: target))
        #expect(!KubernetesResolver.recheck(pod("ready", deleting: true), target: target))
    }

    @Test func explicitArgumentsPreserveValuesWithoutShellParsing() {
        var saved = profile()
        saved.kubeconfig = "/configs/config with spaces"
        let target = KubernetesRunTarget(executable: "/bin/kubectl", profile: saved, pod: .init(name: "shop-a", uid: "uid"))
        #expect(target.execArguments(["env", "RUNLET_RUN_ID=abc", "TMPDIR=/tmp/a b", "php", "-d", "display_errors=stderr"], stdin: true) == ["--kubeconfig", "/configs/config with spaces", "--context", "example", "--namespace", "shop", "exec", "-i", "-c", "app", "shop-a", "--", "env", "RUNLET_RUN_ID=abc", "TMPDIR=/tmp/a b", "php", "-d", "display_errors=stderr"])
        #expect(!target.execArguments(["php"]).contains("-t"))
        for result in ["gone", "mismatch"] { #expect(KubernetesResolver.stopConfirmed(result)) }
        for result in ["sent", "alive", "unsupported", "error", "failed", ""] { #expect(!KubernetesResolver.stopConfirmed(result)) }
    }

    @Test func parsePodJSONAndRejectMalformedInput() throws {
        let json = #"{"items":[{"metadata":{"name":"shop","uid":"123","deletionTimestamp":"now"},"spec":{"containers":[{"name":"app"},{"name":"sidecar"}]},"status":{"phase":"Running","containerStatuses":[{"name":"app","ready":false,"restartCount":3},{"name":"sidecar","ready":true,"restartCount":1}]}}]}"#
        let pods = try KubernetesPod.parseList(Data(json.utf8))
        #expect(pods.count == 1)
        #expect(pods[0].deleting)
        #expect(pods[0].restarts == 4)
        #expect(pods[0].readyContainers == ["sidecar"])
        #expect(!pods[0].eligible(container: "sidecar"))
        #expect(throws: (any Error).self) { try KubernetesPod.parseList(Data("{}".utf8)) }
    }

    @Test func workspaceClearsMachineIdentityAndRetainsProduction() throws {
        var saved = profile()
        saved.environment = .production
        saved.pinnedPod = .init(name: "old", uid: "old")
        saved.lastPod = saved.pinnedPod
        let base = URL(fileURLWithPath: "/projects/shop")
        let definition = WorkspaceTargets.definition(for: .kubernetes(saved.id), library: TargetLibrary(kubernetesProfiles: [saved]), base: base)
        let made = try #require(WorkspaceTargets.makeTarget(definition, base: base).kubernetesProfile)
        #expect(made.pinnedPod == nil)
        #expect(made.lastPod == nil)
        #expect(made.environment == .production)
        #expect(!made.autoResolve)
        #expect(made.id != saved.id)
    }
}

extension KubernetesTests {
    @Test func tabChoicePersistsAndNeverFollowsAnUnavailablePod() {
        let saved = profile()
        let a = pod("a")
        let b = pod("b")
        var choice = KubernetesTabChoice(profile: saved, pod: b.identity)
        #expect(choice.resolve(saved, pods: [a, b]) == .resolved(b))
        #expect(choice.resolve(saved, pods: [a, b]) == .resolved(b))
        #expect(choice.resolve(saved, pods: [a, pod("b", uid: "replacement")]) == .ambiguous([a, pod("b", uid: "replacement")]))
        #expect(choice.pod == nil)
        #expect(choice.resolve(saved, pods: [a]) == .ambiguous([a]))
        let unavailable = KubernetesResolution.unavailable("No Running pod has the Ready container “app”. Check the context, namespace, selector, and container, then resolve again.")
        #expect(choice.resolve(saved, pods: []) == unavailable)
        #expect(choice.resolve(saved, pods: [pod("a", ready: [])]) == unavailable)
        #expect(choice.resolve(saved, pods: [a]) == .ambiguous([a]))

        var vanished = KubernetesTabChoice(profile: saved, pod: b.identity)
        #expect(vanished.resolve(saved, pods: [a]) == .ambiguous([a]))

        var unready = KubernetesTabChoice(profile: saved, pod: b.identity)
        #expect(unready.resolve(saved, pods: [a, pod("b", ready: [])]) == .ambiguous([a]))
        // Even regained readiness does not restore consent after it was invalidated (#33).
        #expect(unready.resolve(saved, pods: [a, b]) == .ambiguous([a, b]))
        var changed = saved
        changed.revision += 1
        #expect(!choice.matches(changed))
        #expect(choice.resolve(changed, pods: [a]) == .resolved(a))
        changed = saved
        changed.id = UUID()
        #expect(!choice.matches(changed))
    }

    @Test func workspaceKubeconfigUsesHomeAbbreviationInBothDirections() throws {
        var saved = profile()
        let homeConfig = NSHomeDirectory() + "/.kube/config"
        saved.kubeconfig = homeConfig
        let library = TargetLibrary(kubernetesProfiles: [saved])
        let base = URL(fileURLWithPath: "/projects/shop")
        let definition = WorkspaceTargets.definition(for: .kubernetes(saved.id), library: library, base: base)
        guard case .kubernetes(let exported) = definition else {
            Issue.record("Expected Kubernetes definition")
            return
        }
        #expect(exported.kubeconfig == "~/.kube/config")
        let imported = try #require(WorkspaceTargets.makeTarget(definition, base: base).kubernetesProfile)
        #expect(imported.kubeconfig == homeConfig)
        #expect(WorkspaceTargets.match(definition, in: library, base: base) == .kubernetes(saved.id))
        saved.kubeconfig = "~/.kube/config"
        #expect(WorkspaceTargets.match(.kubernetes(imported), in: TargetLibrary(kubernetesProfiles: [saved]), base: base) == .kubernetes(saved.id))
        saved.kubeconfig = "/shared/config"
        guard case .kubernetes(let external) = WorkspaceTargets.definition(for: .kubernetes(saved.id), library: TargetLibrary(kubernetesProfiles: [saved]), base: base) else {
            Issue.record("Expected Kubernetes definition")
            return
        }
        #expect(external.kubeconfig == "/shared/config")
    }
}
