import Foundation
import Testing
import RunletCore
@testable import RunletExecution

@Suite(.serialized, .live(.kubernetes, exclusive: true), .enabled(if: !(ProcessInfo.processInfo.environment["RUNLET_TEST_KUBE_CONTEXT"] ?? "").isEmpty, "requires explicit RUNLET_TEST_KUBE_CONTEXT"))
struct KubernetesRunTests {
    func profile(_ app: String = "php", container: String = "app") -> KubernetesProfile {
        var profile = KubernetesProfile(name: "Fixture", context: ProcessInfo.processInfo.environment["RUNLET_TEST_KUBE_CONTEXT"] ?? "", namespace: "runlet-fixtures", labelSelector: "app=runlet-\(app)", container: container)
        profile.workingDirectory = "/tmp"
        return profile
    }
    func cli(_ profile: KubernetesProfile) throws -> KubernetesCLI {
        Fixtures.use(.kubernetes, exclusive: true)
        let executable = try #require(ExecutableLocator.resolve("kubectl"))
        return KubernetesCLI(executable: executable, profile: profile)
    }
    func target(_ profile: KubernetesProfile, pod: KubernetesPod) throws -> TargetSnapshot {
        var target = TargetSnapshot(kind: .kubernetes, label: "Fixture · \(pod.name)", targetId: profile.id.uuidString, workingDirectory: profile.workingDirectory, phpExecutable: "php", temporaryDirectory: "/tmp")
        target.kubernetes = KubernetesRunTarget(executable: try cli(profile).target.executable, profile: profile, pod: pod.identity)
        return target
    }
    func resolved(_ profile: KubernetesProfile) async throws -> KubernetesPod {
        let pods = try await cli(profile).pods(selector: profile.labelSelector)
        if case .resolved(let pod) = KubernetesResolver.resolve(profile, pods: pods) { return pod }
        throw ExecutionError.invalidTarget("Fixture resolution failed")
    }

    @Test func ambiguousAndInterchangeableReplicas() async throws {
        var profile = profile()
        let pods = try await cli(profile).pods(selector: profile.labelSelector)
        guard case .ambiguous(let candidates) = KubernetesResolver.resolve(profile, pods: pods) else { Issue.record("Expected two replicas"); return }
        #expect(candidates.count == 2)
        profile.interchangeableReplicas = true
        #expect(KubernetesResolver.resolve(profile, pods: pods) == KubernetesResolver.resolve(profile, pods: pods.reversed()))
    }

    @Test(arguments: ["sidecar", "alpine", "php74"])
    func snippetsAndWorkingDirectory(app: String) async throws {
        let profile = profile(app)
        let pod = try await resolved(profile)
        let events = try await TestSupport.run("echo getcwd(); echo PHP_VERSION; 6 * 7", target: target(profile, pod: pod))
        #expect(events.finished?.status == .completed)
        #expect(events.stdout.contains("/tmp"))
        #expect(events.started?.workingDirectory == "/tmp")
    }

    @Test func laravelBootsFromFixtureHostPath() async throws {
        var profile = profile("laravel")
        profile.workingDirectory = "/app"
        let pod = try await resolved(profile)
        let events = try await TestSupport.run("app()->version()", target: target(profile, pod: pod))
        #expect(events.finished?.status == .completed)
        #expect(events.started?.workingDirectory == "/app")
        #expect(events.started?.framework == "laravel")
    }

    @Test func explicitSidecarAndLargeStdinOutput() async throws {
        let profile = profile("sidecar", container: "sidecar")
        let pod = try await resolved(profile)
        let code = "/*" + String(repeating: "large script ", count: 150_000) + "*/\necho PHP_VERSION; echo str_repeat('x', 300000); 42"
        let events = try await TestSupport.run(code, target: target(profile, pod: pod))
        #expect(events.finished?.status == .completed)
        #expect(events.stdout.hasPrefix("7.4."))
        #expect(events.stdout.count > 300_000)
    }

    @Test func stopConfirmsRunnerDeathAndPreservesPod() async throws {
        for app in ["sidecar", "alpine", "php74"] {
            let profile = profile(app)
            let pod = try await resolved(profile)
            let snapshot = try target(profile, pod: pod)
            let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
            let request = RunRequest(tabId: UUID(), documentVersion: 1, target: snapshot, code: "echo 'ready'; while (true) { usleep(10000); }")
            var outcome: CancelOutcome?
            for await event in try await engine.start(request) {
                if case .stdout = event.kind, outcome == nil { outcome = await engine.cancel(runId: request.runId) }
            }
            #expect(outcome?.confirmed == true, "\(app): \(outcome?.message ?? "no result")")
            #expect(try await KubernetesCLI(target: #require(snapshot.kubernetes)).pod().identity == pod.identity)
        }
    }

    @Test func churnRefusesSnapshotThenResolvesReplacement() async throws {
        var profile = profile()
        profile.interchangeableReplicas = true
        let before = try await resolved(profile)
        let snapshot = try target(profile, pod: before)
        let client = try cli(profile)
        _ = try await client.run(["delete", "pod", before.name, "--wait=true", "--grace-period=1", "--timeout=10s"])
        let events = try await TestSupport.run("echo 'must not run';", target: snapshot)
        #expect(events.finished?.status != .completed)
        #expect(!events.stdout.contains("must not run"))
        _ = try await client.run(["wait", "--for=condition=Ready", "pod", "-l", profile.labelSelector, "--timeout=60s"])
        let after = try await resolved(profile)
        #expect(after.identity != before.identity)
    }
}

struct KubernetesCLITests {
    @Test func allCommandsUseExplicitScopeAndBadScopeExplainsFailure() async throws {
        var profile = KubernetesProfile(name: "Fake", context: "example", namespace: "shop", labelSelector: "app=shop", container: "app")
        let executable = TestSupport.fixtures.appendingPathComponent("fake-kubectl/kubectl").path
        var client = KubernetesCLI(executable: executable, profile: profile)
        #expect(try await client.contexts() == ["example"])
        #expect(try await client.namespaces() == ["shop"])
        #expect(try await client.pods(selector: profile.labelSelector).count == 2)
        #expect(client.spec(["get", "pods"]).arguments == ["--context", "example", "--namespace", "shop", "get", "pods"])
        // Wrong scope uses the fake only: never sends a request to another real context/namespace.
        profile.namespace = "missing"
        client = KubernetesCLI(executable: executable, profile: profile)
        do { _ = try await client.pods(selector: profile.labelSelector); Issue.record("Expected a scope error") }
        catch { #expect(String(describing: error).contains("Check the profile")) }
        profile.namespace = "shop"; profile.context = "missing"
        do { _ = try await KubernetesCLI(executable: executable, profile: profile).pods(selector: profile.labelSelector); Issue.record("Expected context error") }
        catch { #expect(String(describing: error).contains("Check the profile")) }
    }
}

extension KubernetesCLITests {
    @Test(arguments: ["deleted", "forbidden", "missing-namespace"])
    func missingPodIsDistinctFromAccessAndScopeFailures(name: String) async throws {
        let profile = KubernetesProfile(name: "Fake", context: "example", namespace: "shop", labelSelector: "app=shop", container: "app")
        let destination = KubernetesRunTarget(executable: TestSupport.fixtures.appendingPathComponent("fake-kubectl/kubectl").path,
                                              profile: profile, pod: .init(name: name, uid: "original"))
        var target = TargetSnapshot(kind: .kubernetes, label: "Fake", targetId: profile.id.uuidString, workingDirectory: "/tmp", phpExecutable: "php")
        target.kubernetes = destination
        do {
            _ = try await KubernetesExecAdapter.prepare(target: target, runId: UUID(), script: Data("must not execute".utf8))
            Issue.record("Expected launch to be refused")
        } catch {
            let message = String(describing: error)
            if name == "deleted" {
                #expect(message.contains("The chosen pod no longer exists. Choose Pod again; nothing ran."))
                #expect(!message.contains("Check the profile"))
            } else {
                #expect(message.contains("Check the profile"))
                #expect(!message.contains("chosen pod no longer exists"))
            }
        }
        let stop = await KubernetesExecAdapter.signal(cli: KubernetesCLI(target: destination), php: "php", pid: 123,
                                                      runId: UUID(), signal: 15)
        if name == "deleted" {
            #expect(stop.contains("The chosen pod no longer exists. Choose Pod again. No signal was sent."))
        } else {
            #expect(stop.contains("Check the profile"))
        }
    }
}
