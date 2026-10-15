import Foundation
import Testing
import RunletCore
@testable import RunletExecution

struct KubernetesLogFollowTests {
    func target(name: String = "shop-app-a", uid: String = "shop-app-a-uid") -> KubernetesRunTarget {
        let profile = KubernetesProfile(name: "Fake", context: "example", namespace: "shop", labelSelector: "app=shop", container: "app")
        return KubernetesRunTarget(executable: TestSupport.fixtures.appendingPathComponent("fake-kubectl/kubectl").path,
                                   profile: profile, pod: .init(name: name, uid: uid))
    }

    @Test func byteExactArgumentsAndEnvironment() {
        var target = target()
        target.kubeconfig = "/scratch/config with spaces"
        let flags = ["--kubeconfig", "/scratch/config with spaces", "--context", "example", "--namespace", "shop"]
        #expect(LogFollowCommand.kubernetesLogsArguments(target: target) == flags + ["logs", "--follow", "--tail", "500", "-c", "app", "shop-app-a"])
        let script = "exec 3<&0; tail -n 500 -F -- '/app/a'\\''b.log' <&- & p=$!; { cat <&3 >/dev/null; kill $p 2>/dev/null; } >/dev/null 2>&1 & wait $p"
        #expect(LogFollowCommand.kubernetesExecTailArguments(target: target, path: "/app/a'b.log") == flags + ["exec", "-i", "-c", "app", "shop-app-a", "--", "/bin/sh", "-c", script])
        #expect(LogFollowCommand.kubernetesLogsArguments(target: target, lines: -1).contains("0"))
        let spec = KubernetesLogFollow.spec(target: target)
        #expect(spec.arguments == LogFollowCommand.kubernetesLogsArguments(target: target))
        #expect(spec.newProcessGroup)
        #expect(spec.environment == KubernetesCLI(target: target).spec([]).environment)
    }

    @Test func choiceUsesRunConsentAndInvalidatesReplacements() async throws {
        var profile = KubernetesProfile(name: "Fake", context: "example", namespace: "shop", labelSelector: "app=shop", container: "app")
        let pods = try await KubernetesCLI(target: target()).pods(selector: profile.labelSelector)
        #expect(KubernetesResolver.resolve(profile, pods: pods) == .ambiguous(pods))
        #expect(KubernetesResolver.resolve(profile, pods: [pods[1]]) == .resolved(pods[1]))
        profile.interchangeableReplicas = true
        #expect(KubernetesResolver.resolve(profile, pods: pods.reversed()) == .resolved(pods[0]))
        profile.pinnedPod = pods[1].identity
        #expect(KubernetesResolver.resolve(profile, pods: pods) == .resolved(pods[1]))
        var choice = KubernetesTabChoice(profile: profile, pod: pods[1].identity)
        var replacement = pods[1]
        replacement.identity.uid = "replacement"
        #expect(choice.resolve(profile, pods: [replacement]) == .ambiguous([replacement]))
        #expect(choice.pod == nil)
    }

    @Test(arguments: ["shop-app-a", "deleted", "forbidden", "missing-namespace"])
    func recheckMapsOnlyMissingPod(name: String) async throws {
        do {
            try await KubernetesLogFollow.recheck(target(name: name))
            #expect(name == "shop-app-a")
        } catch {
            let message = String(describing: error)
            if name == "deleted" {
                #expect(message.contains("chosen pod no longer exists"))
                #expect(!message.contains("Check the profile"))
            } else {
                #expect(message.contains("Check the profile"))
            }
        }
        await #expect(throws: (any Error).self) { try await KubernetesLogFollow.recheck(target(uid: "old-uid")) }
    }

    @Test func fakeOutputIsParsedAndStopEndsLocalClient() async throws {
        let events = LogFollowTests.Events()
        let follower = try LogProcessFollower(spec: KubernetesLogFollow.spec(target: target()), stderrIsLog: false,
                                              deliveryQueue: DispatchQueue(label: "test.kubernetes.logs")) { events.add($0) }
        await events.wait(for: "Order shipped")
        var buffer = LogBuffer()
        buffer.append(Data(events.text.utf8), receivedAt: Date())
        #expect(buffer.entries.count == 3)
        #expect(buffer.entries[1].level == .warning)
        #expect(buffer.entries.last?.format == .json)
        await follower.stop()
        #expect(!follower.isRunning)
        #expect(!events.all.contains { if case .ended = $0 { true } else { false } })
    }

    @Test func missingShellIsADiagnosticAndNeverALogEntry() async throws {
        var spec = KubernetesLogFollow.spec(target: target(), path: "/app/storage/logs/laravel.log")
        spec.environment["RUNLET_TEST_KUBE_NO_SHELL"] = "1"
        let events = LogFollowTests.Events()
        let follower = try LogProcessFollower(spec: spec, stderrIsLog: false,
                                              explain: { KubernetesLogFollow.explanation($0, exitCode: $1, file: true) },
                                              deliveryQueue: DispatchQueue(label: "test.kubernetes.no-shell")) { events.add($0) }
        let deadline = Date().addingTimeInterval(10)
        while !events.all.contains(where: { if case .ended = $0 { true } else { false } }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(events.text.isEmpty)
        #expect(events.all.contains { if case .ended(_, let message) = $0 { message == KubernetesLogFollow.noShellMessage } else { false } })
        await follower.stop()
    }

    @Test func findFailuresNeverDescribeAnEndedFollow() async throws {
        let message = KubernetesLogFollow.explanation("Forbidden: pods/exec", exitCode: 1, file: true, operation: .find)
        #expect(message.contains("Forbidden: pods/exec"))
        #expect(message.contains("Find Logs again"))
        #expect(!message.contains("follow ended"))
        #expect(!message.contains("Click Follow"))
        #expect(KubernetesLogFollow.explanation("exec: \"/bin/sh\": stat /bin/sh: no such file or directory", exitCode: 1, file: true, operation: .find) == KubernetesLogFollow.noShellMessage)
        do {
            try await KubernetesLogFollow.recheck(target(name: "deleted"), operation: .find)
            Issue.record("Missing pod should fail discovery")
        } catch {
            #expect(String(describing: error).contains("Find Logs"))
            #expect(!String(describing: error).contains("Click Follow"))
        }
    }

    @Test func diagnosticMessages() {
        #expect(KubernetesLogFollow.explanation("", exitCode: 0, file: false) == KubernetesLogFollow.endedMessage)
        #expect(KubernetesLogFollow.explanation("Forbidden", exitCode: 1, file: false).contains("Forbidden"))
        #expect(KubernetesLogFollow.explanation("exec: \"/bin/sh\": stat /bin/sh: no such file or directory", exitCode: 1, file: true) == KubernetesLogFollow.noShellMessage)
        #expect(KubernetesLogFollow.explanation("tail: /app/missing.log: No such file", exitCode: 1, file: true) != KubernetesLogFollow.noShellMessage)
        #expect(KubernetesLogFollow.explanation("/bin/sh: 1: tail: not found", exitCode: 127, file: true) != KubernetesLogFollow.noShellMessage)
    }
}

/// Only disposable pods are deleted; the owner's shared fixture pods are never changed (#374).
@Suite(.serialized, .live(.kubernetes, exclusive: true), .enabled(if: !(ProcessInfo.processInfo.environment["RUNLET_TEST_KUBE_CONTEXT"] ?? "").isEmpty, "requires explicit RUNLET_TEST_KUBE_CONTEXT"))
struct KubernetesLogLiveTests {
    static func profile(_ selector: String) -> KubernetesProfile {
        KubernetesProfile(name: "Logs fixture", context: ProcessInfo.processInfo.environment["RUNLET_TEST_KUBE_CONTEXT"] ?? "",
                          namespace: "runlet-fixtures", labelSelector: selector, container: "app")
    }

    static func client(_ profile: KubernetesProfile) throws -> KubernetesCLI {
        Fixtures.use(.kubernetes, exclusive: true)
        return KubernetesCLI(executable: try #require(ExecutableLocator.resolve("kubectl")), profile: profile)
    }

    static func createPod(_ name: String, cli: KubernetesCLI) async throws {
        let manifest: [String: Any] = ["apiVersion": "v1", "kind": "Pod",
            "metadata": ["name": name, "namespace": "runlet-fixtures", "labels": ["app": name]],
            "spec": ["restartPolicy": "Never", "containers": [["name": "app", "image": "php:8.4-cli", "imagePullPolicy": "Never", "command": ["sleep", "infinity"]]]]]
        let created = try await runCommand(cli.spec(["create", "-f", "-"], stdin: JSONSerialization.data(withJSONObject: manifest)), timeout: .seconds(20))
        try #require(created.exitCode == 0, "\(String(decoding: created.stderr, as: UTF8.self))")
        let result = try await runCommand(cli.spec(["wait", "--for=condition=Ready", "pod/\(name)", "--timeout=60s"]), timeout: .seconds(65))
        #expect(result.exitCode == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
    }

    static func deletePod(_ name: String, cli: KubernetesCLI) async throws {
        _ = try await cli.run(["delete", "pod", name, "--ignore-not-found", "--wait=true", "--grace-period=1", "--timeout=10s"])
    }

    static func destination(_ profile: KubernetesProfile) async throws -> KubernetesRunTarget {
        let cli = try client(profile)
        let pods = try await cli.pods(selector: profile.labelSelector)
        let pod = try #require(pods.first { $0.eligible(container: profile.container) })
        return KubernetesRunTarget(executable: cli.target.executable, profile: profile, pod: pod.identity)
    }

    @Test func outputArrivesThenDeletionEndsWithoutReconnect() async throws {
        let name = "runlet-logs-374-" + UUID().uuidString.lowercased().prefix(8)
        let profile = Self.profile("app=\(name)")
        let cli = try Self.client(profile)
        var follower: LogProcessFollower?
        do {
            try await Self.createPod(name, cli: cli)
            let destination = try await Self.destination(profile)
            try await KubernetesLogFollow.recheck(destination)
            let events = LogFollowTests.Events()
            follower = try LogProcessFollower(spec: KubernetesLogFollow.spec(target: destination), stderrIsLog: false,
                                              explain: { KubernetesLogFollow.explanation($0, exitCode: $1, file: false) },
                                              deliveryQueue: DispatchQueue(label: "test.kubernetes.live.logs")) { events.add($0) }
            let marker = "line-" + UUID().uuidString
            let write = try await runCommand(KubernetesCLI(target: destination).exec(["sh", "-c", "echo '\(marker)' >> /proc/1/fd/1"]), timeout: .seconds(10))
            #expect(write.exitCode == 0)
            await events.wait(for: marker)
            #expect(events.text.contains(marker))
            try await Self.deletePod(name, cli: cli)
            let deadline = Date().addingTimeInterval(15)
            while !events.all.contains(where: { if case .ended = $0 { true } else { false } }), Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(events.all.contains { if case .ended(_, let message) = $0 { message?.contains("Click Follow") == true } else { false } })
            #expect(follower?.isRunning == false)
            // A same-name replacement doesn't restart the finished follower.
            try await Self.createPod(name, cli: cli)
            let replacement = try await Self.destination(profile)
            #expect(replacement.pod.uid != destination.pod.uid)
            await #expect(throws: (any Error).self) { try await KubernetesLogFollow.recheck(destination) }
            #expect(follower?.isRunning == false)
            await follower?.stop()
            try await Self.deletePod(name, cli: cli)
        } catch {
            await follower?.stop()
            try? await Self.deletePod(name, cli: cli)
            throw error
        }
    }

    @Test func laravelFileFollowStopsTailInsidePod() async throws {
        let destination = try await Self.destination(Self.profile("app=runlet-laravel"))
        let cli = KubernetesCLI(target: destination)
        let path = "/app/storage/logs/laravel.log"
        let marker = "logs-374-" + UUID().uuidString
        let append = try await runCommand(cli.exec(["sh", "-c", "printf '%s\\n' \"$1\" >> \"$2\"", "sh", marker, path]), timeout: .seconds(10))
        #expect(append.exitCode == 0)
        try await KubernetesLogFollow.recheck(destination)
        let scan = ["sh", "-c", LogFollowTests.processScan] + LogFollowTests.split("tail -n 500 -F -- " + path)
        let baseline = try await runCommand(cli.exec(scan), timeout: .seconds(10))
        let existing = Set(LogFollowTests.lines(baseline.stdout))
        let events = LogFollowTests.Events()
        let follower = try LogProcessFollower(spec: KubernetesLogFollow.spec(target: destination, path: path), stderrIsLog: false,
                                              deliveryQueue: DispatchQueue(label: "test.kubernetes.live.file")) { events.add($0) }
        do {
            await events.wait(for: marker)
            #expect(events.text.contains(marker))
            // Identify just this follow's tail by comparing before/after PID lists, not other users' tails.
            let running = try await runCommand(cli.exec(scan), timeout: .seconds(10))
            let processes = LogFollowTests.lines(running.stdout).filter { !existing.contains($0) }
            #expect(!processes.isEmpty)
            await follower.stop()
            #expect(!follower.isRunning)
            let after = try await runCommand(cli.exec(scan), timeout: .seconds(10))
            #expect(LogFollowTests.lines(after.stdout).allSatisfy { existing.contains($0) }, "tail remains after Stop: \(String(decoding: after.stdout, as: UTF8.self))")
        } catch {
            await follower.stop()
            throw error
        }
    }
}
