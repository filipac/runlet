import AppKit
import RunletCore
import SwiftUI

/// One user-invokable action. Menus, the ⇧⌘P palette, toolbar help, and Settings ▸ Shortcuts
/// are all built from this catalog, so a remapped shortcut updates everywhere.
struct AppCommand: Identifiable {
    enum Category: String, CaseIterable {
        case file = "File", edit = "Edit", run = "Run", output = "Output", tabs = "Tabs", library = "Library", view = "View", app = "Runlet"
    }

    let id: String
    let title: String
    let category: Category
    let defaultShortcut: KeyCombo?
    var keywords: String = ""
    var isEnabled: @MainActor (AppModel) -> Bool = { _ in true }
    /// For an on/off command: whether it is on (a checkmark in the menu).
    var isChecked: (@MainActor (AppModel) -> Bool)?
    let perform: @MainActor (AppModel) -> Void
}

@MainActor
enum CommandCatalog {
    static let all: [AppCommand] = build()
    static let byId: [String: AppCommand] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static var defaultShortcuts: [String: KeyCombo?] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.defaultShortcut) })
    }

    private static func k(_ key: String, _ modifiers: Set<KeyCombo.Modifier> = [.command]) -> KeyCombo { KeyCombo(key, modifiers) }

    /// Closes the command palette when it has keyboard focus. Returns whether it did.
    private static func closeOpenPalette() -> Bool {
        guard let panel = NSApp.keyWindow as? PalettePanel, let controller = panel.controller else { return false }
        controller.close()
        return true
    }

    private static func build() -> [AppCommand] {
        let hasTab: @MainActor (AppModel) -> Bool = { $0.selectedTab != nil }
        let canRun: @MainActor (AppModel) -> Bool = { !($0.selectedTab?.isRunning ?? true) }
        let isRunning: @MainActor (AppModel) -> Bool = { $0.selectedTab?.isRunning ?? false }
        var commands: [AppCommand] = [
            // File
            AppCommand(id: "file.newWindow", title: "New Window", category: .file, defaultShortcut: k("n")) { $0.openNewWindow() },
            AppCommand(id: "file.newTab", title: "New Tab", category: .file, defaultShortcut: k("t")) { $0.newTab() },
            AppCommand(id: "file.duplicateTab", title: "Duplicate Tab", category: .file, defaultShortcut: k("d", [.command, .shift]), isEnabled: hasTab) { model in
                model.selectedTab.map { model.duplicateTab($0.id) }
            },
            AppCommand(id: "file.open", title: "Open…", category: .file, defaultShortcut: k("o"), keywords: "file workspace php") { FilePanels.open(model: $0) },
            AppCommand(id: "file.openProject", title: "Open Project…", category: .file, defaultShortcut: k("o", [.command, .shift]), keywords: "folder directory local") { FilePanels.openProject(model: $0) },
            AppCommand(id: "file.save", title: "Save", category: .file, defaultShortcut: k("s")) { FilePanels.saveActive(model: $0) },
            AppCommand(id: "file.saveTabAs", title: "Save Tab As PHP File…", category: .file, defaultShortcut: k("s", [.command, .shift]), isEnabled: hasTab) { model in
                if let tab = model.selectedTab { FilePanels.save(tab, model: model, saveAs: true) }
            },
            AppCommand(id: "file.saveWorkspaceAs", title: "Save Workspace As…", category: .file, defaultShortcut: k("s", [.command, .shift, .option]), keywords: "runlet window") { model in
                if let window = model.activeWindow { FilePanels.saveWorkspaceAs(window, model: model) }
            },
            AppCommand(id: "file.reloadFromDisk", title: "Reload from Disk", category: .file, defaultShortcut: nil, keywords: "revert file changed external",
                       isEnabled: { $0.selectedTab?.fileURL != nil }) { model in
                if let tab = model.selectedTab { model.reloadFromDisk(tab) }
            },
            AppCommand(id: "file.closeTab", title: "Close Tab", category: .file, defaultShortcut: k("w"), isEnabled: hasTab) { model in
                // An open palette closes first (like a popover), never the tab behind it.
                if closeOpenPalette() { return }
                // With a terminal focused, this closes the terminal tab instead.
                if model.closeFocusedTerminal() { return }
                model.selectedTab.map { model.closeTab($0.id) }
            },
            AppCommand(id: "file.closeWindow", title: "Close Window", category: .file, defaultShortcut: k("w", [.command, .shift])) { _ in
                if closeOpenPalette() { return }
                NSApp.keyWindow?.standardWindowButton(.closeButton)?.performClick(nil)
            },

            // Edit
            AppCommand(id: "edit.toggleComment", title: "Toggle Line Comment", category: .edit, defaultShortcut: k("/")) { _ in
                NSApp.sendAction(#selector(CodeTextView.toggleLineComment(_:)), to: nil, from: nil)
            },
            AppCommand(id: "edit.complete", title: "Show Completions", category: .edit, defaultShortcut: k("escape", [.option]), keywords: "autocomplete intellisense") { _ in
                NSApp.sendAction(#selector(NSTextView.complete(_:)), to: nil, from: nil)
            },

            // Run
            AppCommand(id: "run.run", title: "Run", category: .run, defaultShortcut: k("r"), keywords: "execute", isEnabled: canRun) { model in
                model.selectedTab.map { model.run($0) }
            },
            AppCommand(id: "run.runSelection", title: "Run Selection", category: .run, defaultShortcut: k("r", [.command, .shift]), keywords: "execute", isEnabled: canRun) { model in
                model.selectedTab.map { model.run($0, selectionOnly: true) }
            },
            AppCommand(id: "run.toggleStrictTypes", title: "Toggle Strict Types", category: .run, defaultShortcut: nil, keywords: "declare strict_types") { $0.toggleStrictTypes() },
            AppCommand(id: "run.toggleRunLog", title: "Show Run Log", category: .run, defaultShortcut: nil, keywords: "debug diagnostics launch command ssh docker stderr exit troubleshoot",
                       isChecked: { $0.settings.showRunLog }) { $0.settings.showRunLog.toggle() },
            AppCommand(id: "run.toggleMailInterception", title: "Toggle Mail Interception", category: .run, defaultShortcut: nil, keywords: "intercept mail email send fake inspector") { $0.toggleMailInterception() },
            AppCommand(id: "run.stop", title: "Stop", category: .run, defaultShortcut: k("."), keywords: "cancel kill", isEnabled: isRunning) { model in
                model.selectedTab.map { model.stop($0) }
            },

            // Output
            AppCommand(id: "output.copy", title: "Copy Output", category: .output, defaultShortcut: k("c", [.command, .option]), isEnabled: hasTab) { model in
                if let tab = model.selectedTab { Pasteboard.copy(tab.outputText(for: model.settings.outputMode)) }
            },
            AppCommand(id: "output.copyMarkdown", title: "Copy Output as Markdown", category: .output, defaultShortcut: nil, keywords: "export md", isEnabled: hasTab) { model in
                if let tab = model.selectedTab { Pasteboard.copy(tab.outputMarkdown) }
            },
            AppCommand(id: "output.saveAs", title: "Save Output As…", category: .output, defaultShortcut: nil, keywords: "export file markdown text", isEnabled: hasTab) { model in
                if let tab = model.selectedTab { model.saveOutput(of: tab) }
            },
            AppCommand(id: "output.clear", title: "Clear Output", category: .output, defaultShortcut: k("k"), isEnabled: hasTab) { $0.selectedTab?.clearOutput() },
            AppCommand(id: "output.showQueries", title: "Show Queries", category: .output, defaultShortcut: nil, keywords: "sql inspector database n+1",
                       isEnabled: { $0.selectedTab?.inspection.sections.contains(RunInspection.queries) ?? false }) { $0.selectedTab?.outputSection = RunInspection.queries },
            AppCommand(id: "output.showMail", title: "Show Mail", category: .output, defaultShortcut: nil, keywords: "email inspector intercepted",
                       isEnabled: { $0.selectedTab?.inspection.sections.contains(RunInspection.mail) ?? false }) { $0.selectedTab?.outputSection = RunInspection.mail },
            AppCommand(id: "output.toggle", title: "Show/Hide Output Pane", category: .output, defaultShortcut: k("o", [.command, .control]), keywords: "hide output panel") { $0.settings.outputVisible.toggle() },
            AppCommand(id: "output.swapPosition", title: "Move Output Right/Below", category: .output, defaultShortcut: k(".", [.control]), keywords: "layout bottom right") { model in
                model.settings.outputLayout = model.settings.outputLayout == .right ? .bottom : .right
                model.settings.outputVisible = true
            },
            AppCommand(id: "output.structured", title: "Output: Structured", category: .output, defaultShortcut: k("1", [.command, .control]), keywords: "cards tree mode") { $0.settings.outputMode = .structured },
            AppCommand(id: "output.plain", title: "Output: Plain", category: .output, defaultShortcut: k("2", [.command, .control]), keywords: "text transcript mode") { $0.settings.outputMode = .plain },
            AppCommand(id: "output.raw", title: "Output: Raw", category: .output, defaultShortcut: k("3", [.command, .control]), keywords: "stdout bytes mode") { $0.settings.outputMode = .raw },

            // Tabs
            AppCommand(id: "tabs.reopenClosed", title: "Reopen Closed Tab", category: .tabs, defaultShortcut: k("t", [.command, .shift]), keywords: "undo close restore", isEnabled: { $0.canReopenClosedTab }) { $0.reopenClosedTab() },
            AppCommand(id: "tabs.next", title: "Next Tab", category: .tabs, defaultShortcut: k("]", [.command, .shift])) { $0.selectTab(offset: 1) },
            AppCommand(id: "tabs.previous", title: "Previous Tab", category: .tabs, defaultShortcut: k("[", [.command, .shift])) { $0.selectTab(offset: -1) },
            AppCommand(id: "tabs.closeOthers", title: "Close Other Tabs", category: .tabs, defaultShortcut: nil, isEnabled: hasTab) { model in
                model.selectedTab.map { model.closeOtherTabs($0.id) }
            },
            AppCommand(id: "tabs.closeToRight", title: "Close Tabs to the Right", category: .tabs, defaultShortcut: nil, isEnabled: hasTab) { model in
                model.selectedTab.map { model.closeTabsToRight(of: $0.id) }
            },
            AppCommand(id: "tabs.rename", title: "Rename Tab…", category: .tabs, defaultShortcut: nil, isEnabled: hasTab) { _ in
                NotificationCenter.default.post(name: .renameTabRequested, object: nil)
            },

            // Library
            AppCommand(id: "library.openAnything", title: "Open Anything…", category: .library, defaultShortcut: k("p"), keywords: "switch target project docker snippet file quick open") { _ in
                NotificationCenter.default.post(name: .paletteRequested, object: PaletteMode.anything)
            },
            AppCommand(id: "library.commandPalette", title: "Command Palette…", category: .library, defaultShortcut: k("p", [.command, .shift]), keywords: "commands actions") { _ in
                NotificationCenter.default.post(name: .paletteRequested, object: PaletteMode.commands)
            },
            AppCommand(id: "library.history", title: "Show History", category: .library, defaultShortcut: k("y"), keywords: "runs previous") { model in
                model.inspectorPane = .history
                model.setInspectorVisible(true)
                LibrarySearchFocus.request(.history)
            },
            AppCommand(id: "library.snippets", title: "Show Snippets", category: .library, defaultShortcut: k("l", [.command, .shift])) { model in
                model.inspectorPane = .snippets
                model.setInspectorVisible(true)
                LibrarySearchFocus.request(.snippets)
            },
            AppCommand(id: "view.projectCommands", title: "Show Project Commands", category: .library, defaultShortcut: k("k", [.command, .shift]), keywords: "artisan console composer scripts terminal") { model in
                model.inspectorPane = .commands
                model.setInspectorVisible(true)
            },
            AppCommand(id: "library.togglePanel", title: "Show/Hide History & Snippets", category: .library, defaultShortcut: k("l", [.command, .option]), keywords: "inspector sidebar") { $0.setInspectorVisible(!$0.showInspector) },
            AppCommand(id: "library.saveSnippet", title: "Save as Snippet…", category: .library, defaultShortcut: k("s", [.command, .option]), isEnabled: hasTab) { _ in
                NotificationCenter.default.post(name: .saveSnippetRequested, object: nil)
            },
            AppCommand(id: "library.saveSnippetToProject", title: "Save Snippet to Project…", category: .library, defaultShortcut: nil, keywords: ".runlet snippets share team",
                       isEnabled: { model in model.selectedTab.map { model.projectRoot(for: $0.target) != nil } ?? false }) { _ in
                NotificationCenter.default.post(name: .saveSnippetToProjectRequested, object: nil)
            },
            AppCommand(id: "library.deleteTarget", title: "Delete Current Target…", category: .library, defaultShortcut: nil, keywords: "remove docker ssh profile project",
                       isEnabled: { model in model.selectedTab.map { $0.target != .sandbox } ?? false }) { model in
                if let target = model.selectedTab?.target { model.confirmDeleteTarget(target) }
            },
            AppCommand(id: "library.newDockerProfile", title: "New Docker Profile…", category: .library, defaultShortcut: k("n", [.command, .shift]), keywords: "container") { _ in
                NotificationCenter.default.post(name: .newDockerProfileRequested, object: nil)
            },
            AppCommand(id: "library.manageDockerProfiles", title: "Manage Docker Profiles…", category: .library, defaultShortcut: nil, keywords: "docker profiles containers edit delete duplicate list window") {
                $0.showDockerProfileManager()
            },
            AppCommand(id: "library.newSSHProfile", title: "New SSH Profile…", category: .library, defaultShortcut: nil, keywords: "ssh server remote host forge") { _ in
                NotificationCenter.default.post(name: .newSSHProfileRequested, object: nil)
            },
            AppCommand(id: "ssh.connect", title: "Connect to SSH Host…", category: .library, defaultShortcut: nil, keywords: "ssh login password 2fa server remote",
                       isEnabled: { model in model.selectedSSHProfileId.map { model.sshStatus($0) != .connected && !model.isConnectingSSH($0) } ?? false }) { model in
                if let id = model.selectedSSHProfileId { model.connectSSH(id, in: model.activeWindow) }
            },
            AppCommand(id: "ssh.disconnect", title: "Disconnect from SSH Host", category: .library, defaultShortcut: nil, keywords: "ssh logout close connection server remote",
                       isEnabled: { model in model.selectedSSHProfileId.map { model.sshStatus($0) == .connected } ?? false }) { model in
                if let id = model.selectedSSHProfileId { model.disconnectSSH(id) }
            },
            AppCommand(id: "library.restartLanguageServer", title: "Restart Language Server", category: .library, defaultShortcut: nil, keywords: "phpantom lsp completion") { model in
                model.selectedTab.map { model.restartLanguageServer(for: $0) }
            },
            AppCommand(id: "library.resetSandbox", title: "Reset Sandbox…", category: .library, defaultShortcut: nil, keywords: "laravel fresh") { _ in
                NotificationCenter.default.post(name: .resetSandboxRequested, object: nil)
            },

            // View
            AppCommand(id: "view.verticalTabs", title: "Toggle Vertical Tabs", category: .view, defaultShortcut: k("t", [.command, .control]), keywords: "sidebar layout") { model in
                model.settings.tabLayout = model.settings.tabLayout == .vertical ? .horizontal : .vertical
            },
            AppCommand(id: "view.toggleTerminal", title: "Show/Hide Terminal", category: .view, defaultShortcut: k("`", [.control]), keywords: "shell console zsh panel") { $0.toggleTerminal() },
            AppCommand(id: "view.newTerminal", title: "New Terminal", category: .view, defaultShortcut: k("`", [.control, .shift]), keywords: "shell console zsh tab") { $0.newTerminal() },
            AppCommand(id: "view.wrapLines", title: "Wrap Lines", category: .view, defaultShortcut: k("w", [.command, .option]), keywords: "soft wrap word wrap") { $0.toggleSoftWrap() },
            AppCommand(id: "file.openProjectInEditor", title: "Open Project in Editor", category: .file, defaultShortcut: k("e", [.command, .shift]), keywords: "phpstorm vscode cursor zed sublime external",
                       isEnabled: { model in model.selectedTab.map { model.canOpenProjectInEditor(for: $0.target) } ?? false }) { model in
                if let target = model.selectedTab?.target { model.openProjectInEditor(for: target) }
            },
            AppCommand(id: "app.settings", title: "Settings…", category: .app, defaultShortcut: nil, keywords: "preferences") { _ in
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            },
            AppCommand(id: "app.installCommandLineTool", title: "Install Command-Line Tool…", category: .app, defaultShortcut: nil, keywords: "runlet cli terminal shell path symlink") {
                CommandLineToolWindow.show(model: $0)
            },
            AppCommand(id: "window.floatOnTop", title: "Float on Top", category: .view, defaultShortcut: nil, keywords: "pin pinned always on top keep above window",
                       isEnabled: { $0.activeWindow != nil }, isChecked: { $0.activeWindow?.isFloating ?? false }) { model in
                model.activeWindow?.isFloating.toggle()
            },
        ]
        // ⌘1–⌘8 select tabs by position; ⌘9 selects the last tab (browser convention).
        for number in 1...9 {
            commands.append(AppCommand(id: "tabs.select\(number)", title: number == 9 ? "Select Last Tab" : "Select Tab \(number)", category: .tabs, defaultShortcut: k(String(number))) { model in
                model.selectTab(position: number == 9 ? -1 : number - 1)
            })
        }
        return commands
    }
}

extension AppModel {
    /// Effective shortcut for a command after user overrides.
    func shortcut(for id: String) -> KeyCombo? {
        if let override = settings.shortcutOverrides[id] { return override.combo }
        return CommandCatalog.byId[id]?.defaultShortcut ?? nil
    }

    var effectiveShortcuts: [String: KeyCombo] {
        ShortcutResolver.effective(defaults: CommandCatalog.defaultShortcuts, overrides: settings.shortcutOverrides)
    }

    func perform(_ id: String) {
        guard let command = CommandCatalog.byId[id], command.isEnabled(self) else { return }
        command.perform(self)
    }

    func setShortcut(_ combo: KeyCombo?, for id: String) {
        let defaultCombo = CommandCatalog.byId[id]?.defaultShortcut ?? nil
        if combo == defaultCombo {
            settings.shortcutOverrides[id] = nil
        } else {
            settings.shortcutOverrides[id] = ShortcutOverride(combo: combo)
        }
    }
}

extension KeyCombo {
    /// SwiftUI shortcut for menus.
    var keyboardShortcut: KeyboardShortcut? {
        let equivalent: KeyEquivalent
        switch key {
        case "return": equivalent = .return
        case "escape": equivalent = .escape
        case "tab": equivalent = .tab
        case "space": equivalent = .space
        case "delete": equivalent = .delete
        case "up": equivalent = .upArrow
        case "down": equivalent = .downArrow
        case "left": equivalent = .leftArrow
        case "right": equivalent = .rightArrow
        default:
            guard let character = key.first, key.count == 1 else { return nil }
            equivalent = KeyEquivalent(character)
        }
        var flags: EventModifiers = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return KeyboardShortcut(equivalent, modifiers: flags)
    }

    /// Builds a combo from a key-down event (used by the shortcut recorder).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Set<Modifier> = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        let named: [UInt16: String] = [36: "return", 53: "escape", 48: "tab", 49: "space", 51: "delete", 126: "up", 125: "down", 123: "left", 124: "right"]
        if let name = named[event.keyCode] {
            self.init(name, modifiers)
        } else {
            guard let characters = event.charactersIgnoringModifiers?.lowercased(), characters.count == 1 else { return nil }
            self.init(characters, modifiers)
        }
    }
}

/// A menu item for a catalog command, with its effective (possibly remapped) shortcut.
struct CommandMenuItem: View {
    let id: String
    let model: AppModel

    var body: some View {
        if let command = CommandCatalog.byId[id] {
            if let isChecked = command.isChecked {
                Toggle(command.title, isOn: Binding(get: { isChecked(model) }, set: { _ in model.perform(id) }))
                    .keyboardShortcut(model.shortcut(for: id)?.keyboardShortcut)
                    .disabled(!command.isEnabled(model))
            } else {
                Button(command.title) { model.perform(id) }
                    .keyboardShortcut(model.shortcut(for: id)?.keyboardShortcut)
                    .disabled(!command.isEnabled(model))
            }
        }
    }
}

extension Notification.Name {
    static let paletteRequested = Notification.Name("RunletPaletteRequested")
    static let renameTabRequested = Notification.Name("RunletRenameTabRequested")
    static let saveSnippetToProjectRequested = Notification.Name("RunletSaveSnippetToProjectRequested")
}
