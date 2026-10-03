import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// `Tests/Fixtures/fake-ssh/ssh`, the stand-in for `/usr/bin/ssh` in screenshot tours: it must
/// answer what Runlet asks without any server (runs execute on this Mac).
@Suite(.enabled(if: TestSupport.hasPHP, "requires PHP"))
struct FakeSSHTests {
    let fake = TestSupport.fixtures.appendingPathComponent("fake-ssh/ssh").path

    func client() -> SSHClient {
        var environment = ProcessInfo.processInfo.environment
        if let php = TestSupport.php() {
            environment["PATH"] = (php as NSString).deletingLastPathComponent + ":/usr/bin:/bin"
        }
        return SSHClient(executable: fake, environment: environment)
    }

    @Test func answersRunsProbesStatusAndConfigQueries() async throws {
        let client = client()
        let control = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rlt-fake-\(UUID().uuidString.prefix(6))/ab.sock").path
        let endpoint = SSHEndpoint(host: "shop-prod", user: "forge", controlPath: control)
        defer { Task { await client.disconnect(endpoint) } }

        let values = try #require(await client.effectiveConfiguration(host: "shop-prod", user: "forge"))
        #expect(values["hostname"] == "shop-prod.example.com" && values["user"] == "forge" && values["port"] == "22")

        let directory = TestSupport.fixtures.appendingPathComponent("composer").path
        let target = TargetSnapshot(kind: .ssh, label: "tour", targetId: "tour", workingDirectory: directory, phpExecutable: "php", ssh: endpoint)
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil, ssh: client)
        var events: [RunEvent] = []
        for await event in try await engine.start(RunRequest(tabId: UUID(), documentVersion: 1, target: target, code: "(new Acme\\Greeter())->greet('tour')")) {
            events.append(event)
        }
        #expect(events.result?.value?.scalar?.hasPrefix("Hello, tour") == true, "\(events.errors)")
        // #9: remote-style transport carries the same completion phase timings.
        #expect(events.finished?.bootstrapMs == events.bootstrapped?.bootstrapMs)
        #expect(events.finished?.bootstrapMs != nil && events.finished?.executeMs != nil)
        #expect(events.finished?.startedAt != nil)
        // Like OpenSSH with ControlMaster=auto, the first run left a shared connection.
        #expect(client.status(endpoint) == .connected)

        let probe = await client.probe(endpoint, phpExecutable: "php", directory: directory)
        #expect(probe.error == nil && probe.framework == "composer", "\(probe.error ?? "")")

        #expect(await client.disconnect(endpoint))
        #expect(client.status(endpoint) == .disconnected)
    }
}
