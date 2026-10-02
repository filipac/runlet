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
        Window("Runlet", id: "main") {
            MainWindow()
                .environment(model)
                .preferredColorScheme(model.settings.appearance.colorScheme)
        }
        .defaultSize(width: 1180, height: 760)
        .commands { RunletCommands(model: model) }

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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model else { return .terminateNow }
        // Stop managed runs and language servers; restart restores code without running it.
        Task { @MainActor in
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { Self.model?.openFile(url) }
    }
}

/// Menu commands. Shortcuts are shown in the menus and toolbar help.
struct RunletCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { model.newTab() }
                .keyboardShortcut("t")
            Button("Duplicate Tab") { model.selectedTab.map { model.duplicateTab($0.id) } }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("Open PHP File…") { FilePanels.openPHPFile(model: model) }
                .keyboardShortcut("o")
            Button("Open Project…") { FilePanels.openProject(model: model) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Close Tab") { model.selectedTab.map { model.closeTab($0.id) } }
                .keyboardShortcut("w")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { if let tab = model.selectedTab { FilePanels.save(tab, model: model, saveAs: false) } }
                .keyboardShortcut("s")
            Button("Save As…") { if let tab = model.selectedTab { FilePanels.save(tab, model: model, saveAs: true) } }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }
        CommandGroup(after: .textEditing) {
            Button("Toggle Line Comment") {
                NSApp.sendAction(#selector(CodeTextView.toggleLineComment(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("/")
            Button("Complete") {
                NSApp.sendAction(#selector(NSTextView.complete(_:)), to: nil, from: nil)
            }
            .keyboardShortcut(.escape, modifiers: [.option])
        }
        CommandMenu("Run") {
            Button("Run") { model.selectedTab.map { model.run($0) } }
                .keyboardShortcut("r")
                .disabled(model.selectedTab?.isRunning ?? true)
            Button("Run Selection") { model.selectedTab.map { model.run($0, selectionOnly: true) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.selectedTab?.isRunning ?? true)
            Button("Stop") { model.selectedTab.map { model.stop($0) } }
                .keyboardShortcut(".")
                .disabled(!(model.selectedTab?.isRunning ?? false))
            Divider()
            Button("Copy Output") { if let tab = model.selectedTab { Pasteboard.copy(tab.outputText(for: model.settings.outputMode)) } }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Clear Output") { model.selectedTab?.output = [] }
                .keyboardShortcut("k")
        }
        CommandMenu("Library") {
            Button("Show History") {
                model.inspectorPane = .history
                model.showInspector = true
            }
            .keyboardShortcut("y")
            Button("Show Snippets") {
                model.inspectorPane = .snippets
                model.showInspector = true
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Save as Snippet…") { NotificationCenter.default.post(name: .saveSnippetRequested, object: nil) }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Divider()
            Button("New Docker Profile…") { NotificationCenter.default.post(name: .newDockerProfileRequested, object: nil) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Restart Language Server") { model.selectedTab.map { model.restartLanguageServer(for: $0) } }
            Button("Reset Sandbox…") { NotificationCenter.default.post(name: .resetSandboxRequested, object: nil) }
        }
        CommandGroup(after: .windowArrangement) {
            Button("Next Tab") { model.selectTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { model.selectTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
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

    static func openPHPFile(model: AppModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = phpTypes
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls { model.openFile(url) }
        }
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
