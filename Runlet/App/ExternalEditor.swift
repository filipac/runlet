import AppKit
import RunletCore

/// An editor application found on this Mac.
struct InstalledEditor: Identifiable, Hashable {
    var editor: ExternalEditor
    var application: EditorApplication
    /// The `.app` bundle.
    var url: URL
    /// The app's display name, e.g. "Visual Studio Code - Insiders".
    var name: String

    var id: ExternalEditor { editor }

    /// Whether the app declares the editor's URL scheme in its Info.plist.
    var registersURLScheme: Bool {
        let types = Bundle(url: url)?.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]] ?? []
        return types.contains { ($0["CFBundleURLSchemes"] as? [String])?.contains(application.urlScheme) == true }
    }

    /// The command-line launcher inside the bundle, when present.
    var commandLineTool: URL? {
        let tool = url.appendingPathComponent(application.cliPath)
        return FileManager.default.isExecutableFile(atPath: tool.path) ? tool : nil
    }

    /// Editors installed on this Mac (the first installed variant of each), in menu order.
    /// Always asks Launch Services again (Settings calls this when it appears).
    static func detect() -> [InstalledEditor] {
        cache = [:]
        return ExternalEditor.allCases.compactMap(find)
    }

    /// Lookups cached briefly: output links ask for the editor's name on every render.
    private static var cache: [ExternalEditor: (installed: InstalledEditor?, checkedAt: Date)] = [:]

    /// The first installed variant of `editor` (stable releases before previews).
    static func find(_ editor: ExternalEditor) -> InstalledEditor? {
        if let cached = cache[editor], Date().timeIntervalSince(cached.checkedAt) < 30 { return cached.installed }
        var found: InstalledEditor?
        for application in editor.applications {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: application.bundleIdentifier) {
                let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                found = InstalledEditor(editor: editor, application: application, url: url, name: name)
                break
            }
        }
        cache[editor] = (found, Date())
        return found
    }
}

enum ExternalEditorError: LocalizedError {
    case notInstalled(String)
    case missingCommand
    case commandNotFound(String)
    case commandFailed(command: String, status: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let name): "\(name) isn't installed. Choose another editor in Settings ▸ Editor."
        case .missingCommand: "Set a custom editor command in Settings ▸ Editor."
        case .commandNotFound(let name): "The editor command “\(name)” was not found. Use an absolute path, or a command on your PATH."
        case .commandFailed(let command, let status, let output):
            "“\(command)” exited with status \(status)." + (output.isEmpty ? "" : "\n\n" + output)
        }
    }
}

/// Opens host files and folders in the configured external editor.
///
/// Files with a line use the editor's documented URL scheme when the installed app registers
/// it (`phpstorm://open?file=…&line=…`, `vscode://file/…:line`, `cursor://…`, `zed://…`,
/// `subl://open?url=…&line=…`, `txmt://open?url=…&line=…`), otherwise the command-line tool
/// bundled in the app; folders and files without a line are opened with the app directly
/// (like `open -a`). A custom command is split into arguments and launched without a shell.
@MainActor
struct ExternalEditorLauncher {
    var editor: ExternalEditor
    var customCommand: String?

    init(editor: ExternalEditor, customCommand: String? = nil) {
        self.editor = editor
        self.customCommand = customCommand
    }

    init(settings: AppSettings) {
        self.init(editor: settings.externalEditor, customCommand: settings.externalEditorCommand)
    }

    /// Opens `path` (an absolute host path) at the 1-based `line`. With no editor
    /// configured, reveals the file in Finder.
    func open(path: String, line: Int?) async throws {
        let fileURL = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        switch editor {
        case .none:
            if exists { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
        case .custom:
            try await runCustomCommand(path: path, line: line, isDirectory: isDirectory.boolValue)
        case .phpstorm, .vscode, .cursor, .zed, .sublime, .textmate:
            guard let app = InstalledEditor.find(editor) else { throw ExternalEditorError.notInstalled(editor.displayName) }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            if let line, line > 0, !isDirectory.boolValue {
                if app.registersURLScheme, let url = EditorLinks.url(for: editor, scheme: app.application.urlScheme, path: path, line: line) {
                    try await NSWorkspace.shared.open([url], withApplicationAt: app.url, configuration: configuration)
                    return
                }
                if let tool = app.commandLineTool {
                    try await launch(executable: tool.path, arguments: EditorLinks.cliArguments(for: editor, path: path, line: line), workingDirectory: fileURL.deletingLastPathComponent().path)
                    return
                }
            }
            try await NSWorkspace.shared.open([fileURL], withApplicationAt: app.url, configuration: configuration)
        }
    }

    private func runCustomCommand(path: String, line: Int?, isDirectory: Bool) async throws {
        guard let template = customCommand, !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExternalEditorError.missingCommand
        }
        let arguments = try EditorLinks.customCommand(template, path: path, line: line)
        guard let executable = ExecutableLocator.resolve(arguments[0]) else {
            throw ExternalEditorError.commandNotFound(arguments[0])
        }
        let directory = isDirectory ? path : (path as NSString).deletingLastPathComponent
        try await launch(executable: executable, arguments: Array(arguments.dropFirst()), workingDirectory: directory)
    }

    /// Launches a tool directly (argument array, no shell). Waits briefly so quick launchers
    /// (`code`, `subl`, `zed`) can report failures; long-running commands keep running.
    private func launch(executable: String, arguments: [String], workingDirectory: String) async throws {
        var isDirectory: ObjCBool = false
        let cwd = FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory) && isDirectory.boolValue ? workingDirectory : nil
        // stdin is closed immediately (no input), and the tool gets its own process group.
        let process = try SupervisedProcess.launch(ProcessSpec(executable: executable, arguments: arguments, environment: ExecutableLocator.toolEnvironment(), workingDirectory: cwd))
        // Drain output so a chatty child never blocks on a full pipe.
        let collected = Task.detached { await process.collect(limit: 64 * 1024) }
        guard await process.waitForExit(within: .seconds(8)) else { return }
        let result = await collected.value
        let status = result.termination.exitCode
        guard status != 0 else { return }
        let output = String(decoding: result.stderr.isEmpty ? result.stdout : result.stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw ExternalEditorError.commandFailed(command: (executable as NSString).lastPathComponent, status: status, output: String(output.suffix(800)))
    }
}

// MARK: - AppModel

extension AppModel {
    /// The configured editor's display name ("PhpStorm", "Zed Preview"), or nil for none.
    var externalEditorName: String? {
        switch settings.externalEditor {
        case .none: nil
        case .custom: "Custom Command"
        default: InstalledEditor.find(settings.externalEditor)?.name ?? settings.externalEditor.displayName
        }
    }

    /// "Open in PhpStorm", or "Reveal in Finder" when no editor is configured.
    var openInEditorTitle: String {
        externalEditorName.map { "Open in \($0)" } ?? "Reveal in Finder"
    }

    /// Opens a host file (or folder) in the external editor; reveals it in Finder when none
    /// is configured. Never runs code.
    func openInExternalEditor(path: String, line: Int?) {
        let launcher = ExternalEditorLauncher(settings: settings)
        Task {
            do {
                try await launcher.open(path: path, line: line)
            } catch {
                alert = AppAlert(title: "Could not open \((path as NSString).lastPathComponent)", message: error.localizedDescription)
            }
        }
    }

    func revealInFinder(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// How paths reported by the tab's last run map to this Mac (falls back to the tab's
    /// current target before the first run).
    func editorPathMapping(for tab: TabModel) -> EditorPathMapping {
        if let snapshot = tab.currentRequestForDisplay?.target {
            var localSource: String?
            if snapshot.kind == .docker, let id = UUID(uuidString: snapshot.targetId) {
                localSource = library.dockerProfile(id)?.localSourcePath
            }
            if snapshot.kind == .ssh, let id = UUID(uuidString: snapshot.targetId) {
                localSource = library.localFolder(for: .ssh(id))
            }
            // SSH: PHP reports real paths, so the run's own directory (e.g. Forge's
            // releases/<id> behind `current`) maps too.
            return .forSnapshot(snapshot, localSource: localSource, runtimeDirectory: tab.lastRun?.workingDirectory)
        }
        switch tab.target {
        case .sandbox, .local:
            return .host
        case .docker(let id):
            let profile = library.dockerProfile(id)
            return .container(root: profile?.workingDirectory ?? "/", hostRoot: profile?.localSourcePath)
        case .ssh(let id):
            let profile = library.sshProfile(id)
            return .remote(roots: [profile?.remoteDirectory], localRoot: library.localFolder(for: tab.target), host: profile?.destinationLabel ?? "the server")
        }
    }

    /// Where a file path from a run's output opens on this Mac, or why it can't.
    func editorLink(forRuntimePath path: String, in tab: TabModel) -> EditorPathResolution {
        let resolution = editorPathMapping(for: tab).resolve(path)
        if let hostPath = resolution.path, !FileManager.default.fileExists(atPath: hostPath) {
            return .unavailable(reason: hostPath == path ? "\(path) doesn't exist on this Mac." : "\(path) maps to \(hostPath), which doesn't exist on this Mac.")
        }
        return resolution
    }

    /// The folder "Open Project in Editor" opens for `target`, or why there is none.
    func projectFolder(for target: TargetRef) -> EditorPathResolution {
        switch target {
        case .sandbox:
            guard let sandbox, FileManager.default.fileExists(atPath: sandbox.installURL.path) else {
                return .unavailable(reason: "The sandbox isn't installed yet.")
            }
            return .mapped(sandbox.installURL.path)
        case .local(let id):
            guard let project = library.localProject(id) else { return .unavailable(reason: "This tab's project was removed.") }
            guard FileManager.default.fileExists(atPath: project.path) else { return .unavailable(reason: "\(project.path) doesn't exist.") }
            return .mapped(project.path)
        case .docker(let id):
            guard let profile = library.dockerProfile(id) else { return .unavailable(reason: "This tab's Docker profile was removed.") }
            guard let source = profile.localSourcePath, !source.trimmingCharacters(in: .whitespaces).isEmpty else {
                return .unavailable(reason: "“\(profile.name)” has no local source folder. Set one in the Docker profile to open the project in an editor.")
            }
            let path = (source as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { return .unavailable(reason: "\(path) doesn't exist.") }
            return .mapped(path)
        case .ssh(let id):
            guard let profile = library.sshProfile(id) else { return .unavailable(reason: "This tab's SSH profile was removed.") }
            guard let path = library.localFolder(for: target) else {
                return .unavailable(reason: "“\(profile.name)” has no local folder. Set the project's checkout on this Mac in the SSH profile to open it in an editor.")
            }
            guard FileManager.default.fileExists(atPath: path) else { return .unavailable(reason: "\(path) doesn't exist.") }
            return .mapped(path)
        }
    }

    /// Whether "Open Project in Editor" can act on `target`.
    func canOpenProjectInEditor(for target: TargetRef) -> Bool {
        projectFolder(for: target).path != nil
    }

    /// Opens the target's project folder (the sandbox install, the local project, or a
    /// Docker profile's local source) in the external editor, or reveals it in Finder when
    /// no editor is configured. Never runs code.
    func openProjectInEditor(for target: TargetRef) {
        switch projectFolder(for: target) {
        case .mapped(let path):
            openInExternalEditor(path: path, line: nil)
        case .unavailable(let reason):
            alert = AppAlert(title: "Can't open the project", message: reason)
        }
    }

    // MARK: Editor typography

    /// Toggles soft wrap for every editor (View ▸ Wrap Lines). Persisted like the Settings toggle.
    func toggleSoftWrap() {
        settings.softWrap.toggle()
    }
}
