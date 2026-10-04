import AppKit
import Foundation
import RunletCore
import RunletExecution
import RunletLanguage

/// `Runlet --self-test [--docker]`: verifies a packaged build end to end without the UI —
/// bundled resources, sandbox installation, real sandbox runs (local PHP and optionally the
/// Docker fallback), and PHPantom startup with completion. Prints a JSON report and exits.
/// Uses RUNLET_DATA_DIR when set, otherwise a temporary directory (never the user's data).
@MainActor
enum SelfTest {
    static var isRequested: Bool { CommandLine.arguments.contains("--self-test") }

    struct Check: Encodable {
        var name: String
        var ok: Bool
        var detail: String
        var ms: Int
    }

    static func run() async -> Int32 {
        let dataRoot = ProcessInfo.processInfo.environment["RUNLET_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("runlet-selftest-\(UUID().uuidString)")
        let paths = AppPaths(root: dataRoot)
        let resources = AppResources.main
        var checks: [Check] = []

        func record(_ name: String, _ body: () async throws -> String) async {
            let start = ContinuousClock.now
            do {
                let detail = try await body()
                checks.append(Check(name: name, ok: true, detail: detail, ms: elapsed(since: start)))
            } catch {
                checks.append(Check(name: name, ok: false, detail: "\(error)", ms: elapsed(since: start)))
            }
        }

        await record("resources") {
            for url in [resources.runner, resources.sandboxTemplate.appendingPathComponent("runlet-sandbox.json"), resources.sandboxTemplate.appendingPathComponent("vendor/autoload.php")] {
                guard FileManager.default.fileExists(atPath: url.path) else { throw Failure("missing \(url.path)") }
            }
            guard FileManager.default.isExecutableFile(atPath: resources.phpantom.path) else { throw Failure("PHPantom not executable at \(resources.phpantom.path)") }
            return "runner, sandbox template, and PHPantom found in \(Bundle.main.bundlePath)"
        }

        await record("command-line-tool") {
            let tool = Bundle.main.bundleURL.appendingPathComponent(CommandLineTool.bundledPath)
            guard FileManager.default.isExecutableFile(atPath: tool.path) else { throw Failure("runlet not executable at \(tool.path)") }
            let result = try await runCommand(ProcessSpec(executable: tool.path, arguments: ["--version"]))
            let output = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.exitCode == 0, output.hasPrefix("runlet") else { throw Failure("runlet --version: exit \(result.exitCode), \(output)") }
            return output
        }

        // The command registry (#214): unique ids, and New SQL, Redis, and MongoDB Tab in File.
        await record("command-catalog") {
            let problems = CommandCatalog.problems()
            guard problems.isEmpty else { throw Failure(problems.joined(separator: "; ")) }
            let titles = CommandCatalog.newTabIds.compactMap { CommandCatalog.byId[$0]?.title }
            return "\(CommandCatalog.all.count) commands with unique ids; File: \(titles.joined(separator: ", "))"
        }

        // Format Code (#36): the bundled Mago formats a tagless snippet and keeps its magic comment.
        await record("formatter") {
            let formatter = SnippetFormatter(executable: resources.mago)
            guard formatter.isAvailable else { throw Failure("Mago not executable at \(resources.mago.path)") }
            let formatted = try await formatter.format("$a=[1,2];\ncount($a) //?")
            guard formatted == "$a = [1, 2];\ncount($a) //?" else { throw Failure("unexpected output: \(formatted)") }
            return "Mago formatted a snippet: \(formatted.replacingOccurrences(of: "\n", with: " ⏎ "))"
        }

        let sandbox = try? SandboxManager(templateURL: resources.sandboxTemplate, paths: paths)
        await record("sandbox-install") {
            guard let sandbox else { throw Failure("sandbox manifest unreadable") }
            let url = try sandbox.ensureInstalled()
            return "Laravel \(sandbox.manifest.laravelVersion) installed at \(url.path)"
        }

        let bundle = try? RunnerBundle(contentsOf: resources.runner)
        let docker = DockerCLI.locate()
        let engine = bundle.map { ExecutionEngine(bundle: $0, docker: docker) }
        let installations = await PHPDiscovery.discover()

        if let sandbox, let engine, let php = PHPDiscovery.preferred(installations, minimum: sandbox.manifest.minimumPHPComponents) {
            await record("sandbox-run-local") {
                let target = TargetSnapshot(kind: .sandboxLocal, label: "self-test", targetId: "sandbox", workingDirectory: sandbox.installURL.path, phpExecutable: php.path)
                return try await runSnippet(engine: engine, target: target, expecting: "6")
            }
        } else {
            checks.append(Check(name: "sandbox-run-local", ok: true, detail: "skipped: no compatible host PHP", ms: 0))
        }

        if CommandLine.arguments.contains("--docker") {
            await record("sandbox-run-docker") {
                guard let sandbox, let engine, let docker else { throw Failure("Docker CLI not found") }
                guard await docker.imageExists(sandbox.manifest.dockerImage) else { throw Failure("image \(sandbox.manifest.dockerImage) not present") }
                let target = TargetSnapshot(kind: .sandboxDocker, label: "self-test", targetId: "sandbox", workingDirectory: SandboxManager.containerDirectory, phpExecutable: "php", image: sandbox.manifest.dockerImage, hostMountDirectory: sandbox.installURL.path)
                return try await runSnippet(engine: engine, target: target, expecting: "6")
            }
        }

        await record("phpantom-completion") {
            guard let sandbox else { throw Failure("no sandbox") }
            let service = LanguageService(binary: resources.phpantom, dataDirectory: paths.languageService)
            let workspace = LanguageWorkspace(kind: .project, rootPath: sandbox.installURL.path)
            let session = await service.acquire(workspace, for: UUID())
            await session.start()
            guard await session.state.isReady else { throw Failure("server state: \(await session.state)") }
            let text = "collect([1])->ma"
            let mapping = ScratchDocumentMapping(editorText: text)
            let uri = LanguageService.scratchURI(root: workspace.rootURL, documentId: UUID())
            await session.open(uri: uri, text: mapping.lspText(for: text), version: 1)
            let items = try await session.completion(uri: uri, position: mapping.toLSP(LSPPosition(line: 0, character: 16)), triggerCharacter: nil)
            let startup = await session.lastStartupMs ?? -1
            await service.stopAll()
            guard items.contains(where: { $0.label.hasPrefix("map") }) else { throw Failure("no `map` among \(items.count) items") }
            return "\(items.count) items incl. map; server startup \(startup) ms (PATH=/usr/bin:/bin, no host PHP needed)"
        }

        let report: [String: Any] = [
            "app": Bundle.main.bundlePath,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?",
            "architecture": machineArchitecture(),
            "ok": checks.allSatisfy(\.ok),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var output = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        output += "\n" + String(decoding: (try? encoder.encode(checks)) ?? Data(), as: UTF8.self) + "\n"
        FileHandle.standardOutput.write(Data(output.utf8))
        return checks.allSatisfy(\.ok) ? 0 : 1
    }

    private static func runSnippet(engine: ExecutionEngine, target: TargetSnapshot, expecting: String) async throws -> String {
        let request = RunRequest(tabId: UUID(), documentVersion: 1, target: target, code: "collect([1, 2, 3])->sum()")
        var result: String?
        var php: String?
        var laravel: String?
        var failure: String?
        for await event in try await engine.start(request) {
            switch event.kind {
            case .started(let info): php = info.phpVersion
            case .bootstrapped(let info): laravel = info.frameworkVersion
            case .result(let info): result = info.value?.scalar
            case .error(let info): failure = info.message
            default: break
            }
        }
        guard result == expecting else { throw Failure("expected \(expecting), got \(result ?? "nothing") \(failure ?? "")") }
        return "PHP \(php ?? "?"), Laravel \(laravel ?? "?") → \(expecting)"
    }

    private static func elapsed(since start: ContinuousClock.Instant) -> Int {
        let duration = ContinuousClock.now - start
        return Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func machineArchitecture() -> String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }
}
