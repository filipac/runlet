import Foundation
import RunletCore
@testable import RunletExecution

enum TestSupport {
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("plan.md").path) { return url }
        }
        fatalError("repository root not found")
    }()

    static var bundle: RunnerBundle {
        try! RunnerBundle(contentsOf: repoRoot.appendingPathComponent("Resources/Runner/dist/runlet-runner.php"))
    }

    static var fixtures: URL { repoRoot.appendingPathComponent("Tests/Fixtures") }

    static func php(_ name: String = "php") -> String? {
        ExecutableLocator.resolve(name)
    }

    static var herdPHP74: String? {
        ExecutableLocator.resolve("\(NSHomeDirectory())/Library/Application Support/Herd/bin/php74")
    }

    static let docker: DockerCLI? = {
        guard let cli = DockerCLI.locate() else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var ok = false
        Task.detached {
            ok = (try? await cli.serverVersion()) != nil
            semaphore.signal()
        }
        semaphore.wait()
        return ok ? cli : nil
    }()

    static var hasPHP: Bool { php() != nil }
    static var hasDocker: Bool { docker != nil }

    static func localTarget(_ directory: String, php: String) -> TargetSnapshot {
        TargetSnapshot(kind: .local, label: "test", targetId: "test", workingDirectory: directory, phpExecutable: php)
    }

    static func run(_ code: String, target: TargetSnapshot, engine: ExecutionEngine? = nil, selection: SourceSelection? = nil, strictTypes: Bool = false) async throws -> [RunEvent] {
        let engine = engine ?? ExecutionEngine(bundle: bundle, docker: docker)
        let request = RunRequest(tabId: UUID(), documentVersion: 1, target: target, code: code, selection: selection, strictTypes: strictTypes)
        var events: [RunEvent] = []
        for await event in try await engine.start(request) { events.append(event) }
        return events
    }
}

extension Array where Element == RunEvent {
    var finished: FinishedInfo? {
        for event in self { if case .finished(let info) = event.kind { return info } }
        return nil
    }

    var result: ResultInfo? {
        for event in self { if case .result(let info) = event.kind { return info } }
        return nil
    }

    var errors: [RunErrorInfo] {
        compactMap { if case .error(let info) = $0.kind { return info } else { return nil } }
    }

    var dumps: [DumpInfo] {
        compactMap { if case .dump(let info) = $0.kind { return info } else { return nil } }
    }

    var stdout: String {
        String(decoding: compactMap { if case .stdout(let data) = $0.kind { return data } else { return nil } }.reduce(Data(), +), as: UTF8.self)
    }

    var stderr: String {
        String(decoding: compactMap { if case .stderr(let data) = $0.kind { return data } else { return nil } }.reduce(Data(), +), as: UTF8.self)
    }

    var started: StartedInfo? {
        for event in self { if case .started(let info) = event.kind { return info } }
        return nil
    }

    var bootstrapped: BootstrappedInfo? {
        for event in self { if case .bootstrapped(let info) = event.kind { return info } }
        return nil
    }
}
