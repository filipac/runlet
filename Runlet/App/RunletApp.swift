import AppKit
import RunletCore
import SwiftUI
import UniformTypeIdentifiers

/// Entry point: `--self-test` runs headless checks of the packaged app; otherwise the UI starts.
@main
enum RunletMain {
    static func main() {
        if SelfTest.isRequested {
            Task {
                let code = await SelfTest.run()
                exit(code)
            }
            dispatchMain()
        } else {
            RunletApp.main()
        }
    }
}

struct RunletApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        AppDelegate.model = model
    }

    var body: some Scene {
        WindowGroup("Runlet", id: "main", for: UUID.self) { $windowId in
            WindowRoot(windowId: windowId)
                .environment(model)
                .preferredColorScheme(model.settings.appearance.colorScheme)
        } defaultValue: {
            model.nextDefaultWindowId()
        }
        .defaultSize(width: 1180, height: 760)
        // Runlet restores its own windows and tabs from the saved session.
        .restorationBehavior(.disabled)
        // Present a window even when launched to open a file (Finder or CLI).
        .defaultLaunchBehavior(.presented)
        .commands { RunletCommands(model: model) }

        // Library ▸ Manage Docker Profiles…: one window for every saved Docker profile.
        Window("Docker Profiles", id: DockerProfileManager.sceneId) {
            DockerProfileManager()
                .environment(model)
                .preferredColorScheme(model.settings.appearance.colorScheme)
        }
        .defaultSize(width: 1080, height: 700)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        // Opened from the Library menu, the target menu, and Settings ▸ Targets instead.
        .commandsRemoved()

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(model.settings.appearance.colorScheme)
        }
    }
}

extension AppearancePreference {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?

    /// Standard Mac behavior: closing the last window keeps Runlet running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainActor.assumeIsolated {
                if let model = Self.model, model.openWindowAction != nil {
                    model.openNewWindow()
                } else {
                    Self.ensureMainWindow()
                }
            }
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `Runlet file.php …` from a terminal opens the files (never runs them).
        let files = CommandLine.arguments.dropFirst().filter { argument in
            let lower = argument.lowercased()
            return !argument.hasPrefix("-") && (lower.hasSuffix(".php") || lower.hasSuffix(".runlet"))
        }
        MainActor.assumeIsolated {
            for path in files {
                Self.open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            }
        }
        // A launch that opens documents (Finder or CLI) skips SwiftUI's initial window;
        // ask SwiftUI's own app delegate to present it.
        DispatchQueue.main.async { Self.ensureMainWindow() }
        #if DEBUG
        MainActor.assumeIsolated { Self.runDebugInspectorCheck() }
        #endif
    }

    #if DEBUG
    /// Development aid: replays UI steps at launch so layout bugs reproduce without UI
    /// scripting. Use with RUNLET_DATA_DIR pointing at scratch data (and RUNLET_SNAPSHOT_DIR
    /// for `snapshot`). RUNLET_DEBUG_STEPS is a comma-separated list, run 1.5 s apart after
    /// a 2 s start delay:
    /// `inspector:history|snippets|commands|off`, `tabs:vertical|horizontal`, `snapshot`,
    /// `wait`. The app prints "RUNLET_DEBUG_STEPS: done" to stderr and quits after the last
    /// step. RUNLET_DEBUG_INSPECTOR=<pane> is shorthand for `inspector:<pane>,snapshot`.
    @MainActor private static func runDebugInspectorCheck() {
        let environment = ProcessInfo.processInfo.environment
        let script = environment["RUNLET_DEBUG_STEPS"] ?? environment["RUNLET_DEBUG_INSPECTOR"].map { "inspector:\($0),snapshot" }
        guard let script else { return }
        let steps = script.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        func run(_ index: Int) {
            guard index < steps.count else {
                FileHandle.standardError.write(Data("RUNLET_DEBUG_STEPS: done\n".utf8))
                exit(0)
            }
            guard let model = Self.model else { return }
            let parts = steps[index].split(separator: ":", maxSplits: 1).map(String.init)
            let argument = parts.count > 1 ? parts[1] : ""
            FileHandle.standardError.write(Data("RUNLET_DEBUG_STEPS: \(steps[index])\n".utf8))
            switch parts[0] {
            case "inspector":
                if let pane = AppModel.InspectorPane.allCases.first(where: { "\($0)" == argument }) {
                    model.inspectorPane = pane
                    model.setInspectorVisible(true)
                } else {
                    model.setInspectorVisible(false)
                }
            case "tabs":
                model.settings.tabLayout = argument == "vertical" ? .vertical : .horizontal
            case "snapshot":
                if let directory = WindowSnapshots.directory { WindowSnapshots.capture(into: directory) }
            default:
                break
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { run(index + 1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { run(0) }
    }
    #endif

    @MainActor static func ensureMainWindow() {
        guard !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        _ = NSApp.delegate?.applicationOpenUntitledFile?(NSApp)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model else { return .terminateNow }
        // Stop managed runs and language servers; restart restores code without running it.
        Task { @MainActor in
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @MainActor static func open(_ url: URL) {
        model?.open(url)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls { Self.open(url) }
        }
        DispatchQueue.main.async { Self.ensureMainWindow() }
    }
}

/// Menu commands. Shortcuts are shown in the menus and toolbar help.
/// Menus built from `CommandCatalog`; every item shows its effective (possibly remapped)
/// shortcut. Settings ▸ Shortcuts changes them.
struct RunletCommands: Commands {
    let model: AppModel

    private func item(_ id: String) -> CommandMenuItem { CommandMenuItem(id: id, model: model) }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            item("file.newWindow")
            item("file.newTab")
            item("file.duplicateTab")
            Divider()
            item("file.open")
            item("file.openProject")
            item("file.openProjectInEditor")
            Divider()
            item("file.closeTab")
            item("file.closeWindow")
        }
        CommandGroup(replacing: .saveItem) {
            item("file.save")
            item("file.saveTabAs")
            Divider()
            item("file.saveWorkspaceAs")
        }
        CommandGroup(after: .textEditing) {
            item("edit.toggleComment")
            item("edit.complete")
        }
        CommandMenu("Run") {
            item("run.run")
            item("run.runSelection")
            item("run.stop")
            item("run.toggleStrictTypes")
            Divider()
            item("output.copy")
            item("output.clear")
            Divider()
            item("output.structured")
            item("output.plain")
            item("output.raw")
        }
        CommandMenu("Library") {
            item("library.openAnything")
            item("library.commandPalette")
            Divider()
            item("library.history")
            item("library.snippets")
            item("view.projectCommands")
            item("library.togglePanel")
            item("library.saveSnippet")
            item("library.saveSnippetToProject")
            Divider()
            item("library.newDockerProfile")
            item("library.manageDockerProfiles")
            item("library.deleteTarget")
            Divider()
            item("library.restartLanguageServer")
            item("library.resetSandbox")
        }
        if let directory = WindowSnapshots.directory {
            CommandMenu("Debug") {
                Button("Snapshot Windows") { WindowSnapshots.capture(into: directory) }
                    .keyboardShortcut("s", modifiers: [.command, .control, .option])
            }
        }
        CommandGroup(before: .toolbar) {
            item("view.verticalTabs")
            item("view.wrapLines")
            item("output.toggle")
            item("view.toggleTerminal")
            item("view.newTerminal")
            item("output.swapPosition")
            Divider()
        }
        CommandGroup(after: .windowArrangement) {
            Divider()
            item("tabs.next")
            item("tabs.previous")
            item("tabs.reopenClosed")
            item("tabs.closeOthers")
            item("tabs.closeToRight")
            item("tabs.rename")
            Divider()
            ForEach(1...9, id: \.self) { number in
                item("tabs.select\(number)")
            }
        }
    }
}

extension Notification.Name {
    static let saveSnippetRequested = Notification.Name("RunletSaveSnippetRequested")
    static let newDockerProfileRequested = Notification.Name("RunletNewDockerProfileRequested")
    static let resetSandboxRequested = Notification.Name("RunletResetSandboxRequested")
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

@MainActor
enum FilePanels {
    static var phpTypes: [UTType] {
        [UTType(filenameExtension: "php") ?? .sourceCode, .plainText, .sourceCode]
    }

    static var workspaceType: UTType {
        UTType(exportedAs: WorkspaceDocument.typeIdentifier, conformingTo: .json)
    }

    /// Opens PHP files (as tabs) and `.runlet` workspaces (as windows).
    static func open(model: AppModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = phpTypes + [workspaceType]
        panel.allowsMultipleSelection = true
        panel.message = "Open PHP files or a Runlet workspace"
        if panel.runModal() == .OK {
            for url in panel.urls { AppDelegate.open(url) }
        }
    }

    /// ⌘S: saves the active window's workspace (if it has one) and the current tab's PHP file
    /// (if it has one). An untitled window with no file asks where to save the tab.
    static func saveActive(model: AppModel) {
        guard let window = model.activeWindow else { return }
        var saved = false
        if let url = window.workspaceURL {
            saved = model.saveWorkspace(window, to: url)
        }
        if let tab = window.selectedTab, tab.fileURL != nil {
            saved = model.save(tab) || saved
        }
        if !saved, window.workspaceURL == nil, let tab = window.selectedTab {
            save(tab, model: model, saveAs: true)
        }
    }

    @discardableResult
    static func saveWorkspaceAs(_ window: WindowModel, model: AppModel) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [workspaceType]
        panel.nameFieldStringValue = (window.workspaceURL?.lastPathComponent) ?? "Workspace.\(WorkspaceDocument.fileExtension)"
        panel.message = "Save this window's tabs and their targets as a workspace file."
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return model.saveWorkspace(window, to: url)
    }

    static func openProject(model: AppModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open Project"
        panel.message = "Choose a PHP, Composer, or Laravel project directory."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let project = model.openProject(at: url)
        if let tab = model.selectedTab {
            model.setTarget(.local(project.id), for: tab)
        }
    }

    static func chooseDirectory(message: String, start: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = message
        if let start { panel.directoryURL = URL(fileURLWithPath: start) }
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseExecutable(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    @discardableResult
    static func save(_ tab: TabModel, model: AppModel, saveAs: Bool) -> Bool {
        if !saveAs, tab.fileURL != nil { return model.save(tab) }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "php") ?? .sourceCode]
        panel.nameFieldStringValue = tab.fileURL?.lastPathComponent ?? (tab.title.hasSuffix(".php") ? tab.title : tab.title + ".php")
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return model.save(tab, to: url)
    }
}

/// Development aid: with RUNLET_SNAPSHOT_DIR set, a Debug menu command renders every visible
/// Runlet window (including sheets and popups) to PNG using AppKit drawing, which needs no
/// Screen Recording permission and captures nothing outside Runlet.
@MainActor
enum WindowSnapshots {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["RUNLET_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    static var counter = 0

    static func capture(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        counter += 1
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView else { continue }
            let bounds = view.bounds
            guard bounds.width > 1, bounds.height > 1, let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { continue }
            view.cacheDisplay(in: bounds, to: rep)
            let name = String(format: "%02d-%d-%@.png", counter, index, window.title.isEmpty ? (window.identifier?.rawValue ?? "window") : window.title)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-")))
        }
    }
}
