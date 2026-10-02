import AppKit
import Combine
import RunletCore
import RunletExecution
import RunletLanguage
import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window
    @Environment(\.colorScheme) private var colorScheme
    @State private var editingProfile: DockerProfile?
    @State private var editingSSHProfile: SSHProfile?
    @State private var editingProject: LocalProject?
    @State private var savingSnippet: SnippetDraft?
    @State private var confirmReset = false
    @State private var palette = PaletteController()
    /// Live width while dragging the vertical tab sidebar; saved to settings on release.
    @State private var sidebarWidth: Double?
    /// Live width while dragging the History & Snippets panel; saved on release.
    @State private var libraryWidth: Double?

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            Group {
                if model.settings.tabLayout == .vertical {
                    HStack(spacing: 0) {
                        VerticalTabList()
                            .frame(width: sidebarWidth ?? model.settings.verticalTabsWidth)
                        SidebarResizeHandle(width: $sidebarWidth, committed: model.settings.verticalTabsWidth) { width in
                            model.settings.verticalTabsWidth = width
                        }
                        selectedTabContent
                    }
                } else {
                    VStack(spacing: 0) {
                        TabStrip()
                        Divider()
                        selectedTabContent
                    }
                }
            }
            // A plain trailing column, not `.inspector`: SwiftUI's inspector split view
            // re-vends the window toolbar while it lays out, which intermittently drove AppKit
            // into an Update Constraints loop (an exception, i.e. a crash) on opening it.
            if model.showInspector {
                SidebarResizeHandle(width: $libraryWidth, committed: model.settings.libraryPanelWidth, range: 260...480, edge: .trailing, identifier: "library-resize-handle") { width in
                    model.settings.libraryPanelWidth = width
                }
                LibraryInspector()
                    .frame(width: libraryWidth ?? min(480, max(260, model.settings.libraryPanelWidth)))
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .toolbar { toolbarContent }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
        .sheet(item: $model.containerChoice) { choice in
            ContainerChoiceSheet(choice: choice)
        }
        .sheet(item: $editingProfile) { profile in
            DockerProfileEditor(profile: profile, isNew: model.library.dockerProfile(profile.id) == nil) { saved in
                model.saveDockerProfile(saved)
                if let tab = window.selectedTab { model.setTarget(.docker(saved.id), for: tab) }
            }
        }
        .sheet(item: $editingSSHProfile) { profile in
            SSHProfileEditor(profile: profile, isNew: model.library.sshProfile(profile.id) == nil) { saved in
                let isNew = model.library.sshProfile(saved.id) == nil
                model.saveSSHProfile(saved)
                if isNew, let tab = window.selectedTab { model.setTarget(.ssh(saved.id), for: tab) }
            }
        }
        .sheet(item: $editingProject) { project in
            ProjectSettingsSheet(project: project)
        }
        .sheet(item: $savingSnippet) { draft in
            SaveSnippetSheet(draft: draft)
        }
        .confirmationDialog("Reset the Laravel sandbox?", isPresented: $confirmReset) {
            Button("Reset Sandbox", role: .destructive) { Task { await model.resetSandbox() } }
        } message: {
            Text("This deletes only the sandbox's own data (database, cache, logs, compiled views) and restores a fresh copy.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .newDockerProfileRequested).filter { _ in isActiveWindow }) { _ in
            editingProfile = .newDraft()
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveSnippetRequested).filter { _ in isActiveWindow }) { _ in
            beginSaveSnippet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveSnippetToProjectRequested).filter { _ in isActiveWindow }) { _ in
            if let tab = window.selectedTab { savingSnippet = SnippetDraft.make(for: tab, model: model, destination: .project) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .resetSandboxRequested).filter { _ in isActiveWindow }) { _ in
            confirmReset = true
        }
        // Open Anything / Command Palette: open, switch the open palette's mode, or close it.
        .onReceive(NotificationCenter.default.publisher(for: .paletteRequested).filter { _ in isActiveWindow }) { note in
            palette.toggle(note.object as? PaletteMode ?? .anything, model: model)
        }
        .paletteHost(palette)
        .onReceive(NotificationCenter.default.publisher(for: .editProjectRequested).filter { _ in isActiveWindow }) { note in
            if let id = note.object as? UUID { editingProject = model.library.localProject(id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .editDockerProfileRequested).filter { _ in isActiveWindow }) { note in
            if let id = note.object as? UUID { editingProfile = model.library.dockerProfile(id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newSSHProfileRequested).filter { _ in isActiveWindow }) { _ in
            editingSSHProfile = .newDraft()
        }
        .onReceive(NotificationCenter.default.publisher(for: .editSSHProfileRequested).filter { _ in isActiveWindow }) { note in
            if let id = note.object as? UUID { editingSSHProfile = model.library.sshProfile(id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            model.saveSession()
        }
        .onAppear { model.prepareTerminalPanel(for: window) }
        .frame(minWidth: 760, minHeight: 420)
    }

    private var isActiveWindow: Bool { model.activeWindowId == window.id }

    /// The selected tab's editor and output, with the window's terminal panel below.
    private var selectedTabContent: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                tabContent
                if model.isTerminalVisible(in: window) {
                    // Leave the editor/output split and status bar at least ~250 pt.
                    TerminalPanel(maxHeight: max(TerminalResizeHandle.minimum, geometry.size.height - 250))
                }
            }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        if let tab = window.selectedTab {
            TabContent(tab: tab)
                .id(tab.id)
        } else {
            ContentUnavailableView("No tab", systemImage: "doc.text")
        }
    }

    private func beginSaveSnippet() {
        guard let tab = window.selectedTab else { return }
        let code = tab.editor.selectedText ?? tab.editor.text
        savingSnippet = SnippetDraft(label: "", code: code, target: tab.target, associate: tab.target != .sandbox)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.settings.tabLayout = model.settings.tabLayout == .vertical ? .horizontal : .vertical
            } label: {
                Label("Vertical Tabs", systemImage: model.settings.tabLayout == .vertical ? "rectangle.split.3x1" : "sidebar.left")
            }
            .help(model.settings.tabLayout == .vertical ? "Show tabs on top (⌃⌘T)" : "Show tabs in a sidebar (⌃⌘T)")
            .accessibilityIdentifier("tab-layout-toggle")
        }
        ToolbarItem(placement: .navigation) {
            TargetMenu(onNewDockerProfile: {
                editingProfile = .newDraft()
            }, onEditProfile: { editingProfile = $0 }, onEditProject: { editingProject = $0 })
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let tab = window.selectedTab {
                if tab.isRunning {
                    Button {
                        model.stop(tab)
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .help("Stop (\(model.shortcut(for: "run.stop")?.displayString ?? "no shortcut"))")
                    .accessibilityIdentifier("stop-button")
                } else {
                    Button {
                        model.run(tab)
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .help("Run (\(model.shortcut(for: "run.run")?.displayString ?? "no shortcut"))")
                    .accessibilityIdentifier("run-button")
                    Button {
                        model.run(tab, selectionOnly: true)
                    } label: {
                        Label("Run Selection", systemImage: "text.cursor")
                    }
                    .help("Run Selection (\(model.shortcut(for: "run.runSelection")?.displayString ?? "no shortcut"))")
                    .accessibilityIdentifier("run-selection-button")
                }
            }
            Button {
                beginSaveSnippet()
            } label: {
                Label("Save Snippet", systemImage: "bookmark")
            }
            .help("Save as Snippet (\(model.shortcut(for: "library.saveSnippet")?.displayString ?? "no shortcut"))")
            Button {
                model.setTerminalVisible(!model.isTerminalVisible(in: window), in: window)
            } label: {
                Label("Terminal", systemImage: "apple.terminal")
            }
            .help(model.isTerminalVisible(in: window) ? "Hide Terminal (⌃`)" : "Show Terminal (⌃`)")
            .accessibilityIdentifier("terminal-toggle")
            Button {
                model.setInspectorVisible(!model.showInspector)
            } label: {
                Label("History & Snippets", systemImage: "sidebar.trailing")
            }
            .help("History & Snippets (\(model.shortcut(for: "library.history")?.displayString ?? "no shortcut"))")
        }
    }
}

extension Notification.Name {
    static let editProjectRequested = Notification.Name("RunletEditProjectRequested")
    static let editDockerProfileRequested = Notification.Name("RunletEditDockerProfileRequested")
    static let newSSHProfileRequested = Notification.Name("RunletNewSSHProfileRequested")
    static let editSSHProfileRequested = Notification.Name("RunletEditSSHProfileRequested")
}

/// Editor + output split for one tab, plus its status bar.
struct TabContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    let tab: TabModel

    var body: some View {
        VStack(spacing: 0) {
            if let issue = tab.targetIssue {
                Banner(text: issue, systemImage: "exclamationmark.triangle.fill", tint: .orange)
            }
            SSHConnectionBanner(tab: tab)
            SSHDriftBanner(tab: tab)
            SSHLocalFolderBanner(tab: tab)
            if case .docker(let profileId) = tab.target,
               let profile = model.library.dockerProfile(profileId), profile.localSourcePath?.isEmpty ?? true,
               let suggestion = model.sourceSuggestions[profileId] {
                HStack(spacing: 8) {
                    Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.blue)
                    Text("Completion is limited because this profile has no local source. The container's \(profile.workingDirectory) is mounted from \((suggestion as NSString).abbreviatingWithTildeInPath).")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Use for Completion") { model.useSuggestedSource(for: profileId) }
                        .accessibilityIdentifier("use-suggested-source")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.1))
            }
            if tab.target == .sandbox, case .needsImage(let image) = model.sandboxStatus {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle").foregroundStyle(.blue)
                    Text("No PHP \(model.sandbox?.manifest.minimumPHP ?? "8.3")+ was found on this Mac, so the sandbox runs in Docker. It needs the \(image) image (a one-time download of several hundred MB, reused for every run).")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if model.isPullingImage {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Download \(image)") { Task { await model.downloadSandboxImage() } }
                            .accessibilityIdentifier("download-sandbox-image")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.1))
            }
            split
            Divider()
            StatusBar(tab: tab)
        }
        // SSH status is read from the control socket on this Mac; nothing connects.
        .task(id: tab.target.stableKey) {
            if case .ssh(let id) = tab.target {
                model.refreshSSHStatus(id)
                model.lookUpFolderSuggestionsOnce(for: id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshSSHStatuses()
        }
    }

    @ViewBuilder
    private var split: some View {
        let editor = CodeEditorView(
            controller: tab.editor,
            preferences: EditorPreferences(settings: model.settings, dark: colorScheme == .dark)
        )
        .frame(minWidth: 280, minHeight: 120)
        let output = OutputPane(tab: tab)
            .frame(minWidth: 240, minHeight: 100)
        if !model.settings.outputVisible {
            editor
        } else {
            // The divider position is remembered per layout (Settings ▸ General ▸ Output pane).
            switch model.settings.outputLayout {
            case .right:
                PaneSplit(axis: .horizontal, fraction: model.settings.editorSplitRight, minFirst: 280, minSecond: 240) { share in
                    model.settings.editorSplitRight = share
                } first: {
                    editor
                } second: {
                    output
                }
            case .bottom:
                PaneSplit(axis: .vertical, fraction: model.settings.editorSplitBottom, minFirst: 120, minSecond: 100) { share in
                    model.settings.editorSplitBottom = share
                } first: {
                    editor
                } second: {
                    output
                }
            }
        }
    }
}

struct Banner: View {
    var text: String
    var systemImage: String
    var tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.callout).lineLimit(3).textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.12))
    }
}

/// Horizontal tab bar with rename, duplicate, and close actions.
struct TabStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window
    @State private var renaming: UUID?
    @State private var renameText = ""

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(window.tabs) { tab in
                        tabButton(tab)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            Button {
                model.newTab(in: window)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .help("New Tab (⌘T)")
            .accessibilityIdentifier("new-tab-button")
        }
        .background(.bar)
        .onReceive(NotificationCenter.default.publisher(for: .renameTabRequested).filter { _ in model.activeWindowId == window.id }) { _ in
            if let tab = window.selectedTab { beginRename(tab) }
        }
    }

    @ViewBuilder
    private func tabButton(_ tab: TabModel) -> some View {
        let selected = tab.id == window.selectedTabId
        HStack(spacing: 6) {
            Image(systemName: model.targetSymbol(tab.target))
                .font(.caption)
                .foregroundStyle(.secondary)
            if renaming == tab.id {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.plain)
                    .frame(width: 120)
                    .onSubmit { commitRename(tab) }
                    .onExitCommand { renaming = nil }
            } else {
                Text(tab.title + (tab.isFileDirty ? " •" : ""))
                    .lineLimit(1)
                    .font(.callout)
            }
            if tab.isRunning {
                ProgressView().controlSize(.mini)
            }
            Button {
                model.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark").font(.caption2.weight(.bold))
            }
            .buttonStyle(.borderless)
            .opacity(selected ? 1 : 0.5)
            .help("Close Tab (⌘W)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.18) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginRename(tab) }
        .onTapGesture { window.selectedTabId = tab.id }
        .help("\(tab.title) — \(model.targetLabel(tab.target))")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tab-\(tab.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button("Rename…") { beginRename(tab) }
            Button("Duplicate") { model.duplicateTab(tab.id) }
            Divider()
            Button("Close") { model.closeTab(tab.id) }
            Button("Close Other Tabs") { model.closeOtherTabs(tab.id) }
        }
    }

    private func beginRename(_ tab: TabModel) {
        renameText = tab.title
        renaming = tab.id
    }

    private func commitRename(_ tab: TabModel) {
        model.renameTab(tab.id, to: renameText)
        renaming = nil
    }
}

/// Toolbar menu that shows and changes the selected tab's execution target.
struct TargetMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window
    var onNewDockerProfile: () -> Void
    var onEditProfile: (DockerProfile) -> Void
    var onEditProject: (LocalProject) -> Void

    var body: some View {
        if let tab = window.selectedTab {
            Menu {
                Button {
                    model.setTarget(.sandbox, for: tab)
                } label: {
                    Label(model.targetLabel(.sandbox), systemImage: "shippingbox")
                }
                if !model.library.localProjects.isEmpty {
                    Section("Local Projects") {
                        ForEach(model.library.localProjects.sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }) { project in
                            Button {
                                model.setTarget(.local(project.id), for: tab)
                            } label: {
                                Label(project.name, systemImage: "folder")
                            }
                        }
                    }
                }
                if !model.library.dockerProfiles.isEmpty {
                    Section("Docker Applications") {
                        ForEach(model.library.dockerProfiles.sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }) { profile in
                            Button {
                                model.setTarget(.docker(profile.id), for: tab)
                            } label: {
                                Label(profile.name, systemImage: "cube.box")
                            }
                        }
                    }
                }
                if !model.library.sshProfiles.isEmpty {
                    Section("SSH Hosts") {
                        ForEach(model.library.sshProfiles.sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }) { profile in
                            Button {
                                model.setTarget(.ssh(profile.id), for: tab)
                            } label: {
                                Label(profile.name + (model.sshStatus(profile.id) == .connected ? " — connected" : ""), systemImage: "server.rack")
                            }
                        }
                    }
                }
                Divider()
                Button("Switch Target… (\(model.shortcut(for: "library.openAnything")?.displayString ?? "⌘P"))") {
                    NotificationCenter.default.post(name: .paletteRequested, object: PaletteMode.anything)
                }
                Button("Open Project…") { FilePanels.openProject(model: model) }
                Button("New Docker Profile…") { onNewDockerProfile() }
                Button("Manage Docker Profiles…") { model.showDockerProfileManager() }
                Button("New SSH Profile…") { NotificationCenter.default.post(name: .newSSHProfileRequested, object: nil) }
                Divider()
                switch tab.target {
                case .local(let id):
                    if let project = model.library.localProject(id) {
                        Button("Project Options…") { onEditProject(project) }
                        Button("Remove “\(project.name)”…", role: .destructive) { model.confirmDeleteTarget(.local(id)) }
                    }
                case .docker(let id):
                    if let profile = model.library.dockerProfile(id) {
                        Button("Edit Docker Profile…") { onEditProfile(profile) }
                        Button("Delete “\(profile.name)”…", role: .destructive) { model.confirmDeleteTarget(.docker(id)) }
                    }
                case .ssh(let id):
                    if let profile = model.library.sshProfile(id) {
                        if model.sshStatus(id) == .connected {
                            Button("Disconnect from \(profile.host)") { model.disconnectSSH(id) }
                        } else {
                            Button("Connect to \(profile.host)…") { model.connectSSH(id, in: window) }
                        }
                        Button("Edit SSH Profile…") { NotificationCenter.default.post(name: .editSSHProfileRequested, object: id) }
                        Button("Delete “\(profile.name)”…", role: .destructive) { model.confirmDeleteTarget(.ssh(id)) }
                    }
                case .sandbox:
                    Button("Reset Sandbox…") { NotificationCenter.default.post(name: .resetSandboxRequested, object: nil) }
                }
            } label: {
                Label(model.targetLabel(tab.target), systemImage: model.targetSymbol(tab.target))
                    .labelStyle(.titleAndIcon)
            }
            .help("Execution target for this tab")
            .accessibilityIdentifier("target-menu")
        }
    }
}

/// Run state, elapsed time, PHP/framework versions, and language-service status.
struct StatusBar: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel

    var body: some View {
        HStack(spacing: 14) {
            runStatus
            if case .ssh(let id) = tab.target, let profile = model.library.sshProfile(id),
               model.sshStatus(id) == .connected || profile.authentication == .interactive {
                let status = model.sshStatus(id)
                Label(status.label, systemImage: status == .connected ? "link" : "link.badge.plus")
                    .foregroundStyle(status == .connected ? Color.green : Color.secondary)
                    .help(status == .connected ? "A shared SSH connection is open; runs reuse it." : "No shared SSH connection is open.")
                    .accessibilityIdentifier("ssh-status")
            }
            if let message = tab.stopMessage {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(1)
            }
            Spacer()
            if let summary = tab.lastRun {
                if let php = summary.phpVersion { Text("PHP \(php)") }
                if let framework = summary.framework, framework != "plain" {
                    let name = summary.driverName ?? (framework.hasPrefix("custom:") ? String(framework.dropFirst(7)) : framework.capitalized)
                    Text(name + (summary.frameworkVersion.map { " \($0)" } ?? ""))
                        .help(framework.hasPrefix("custom:") ? "Booted by the project's .runlet driver" : "Detected driver: \(framework)")
                }
            } else {
                Text(targetDetail).lineLimit(1)
            }
            languageStatus
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("status-bar")
    }

    private var targetDetail: String {
        switch tab.target {
        case .sandbox:
            switch model.sandboxStatus {
            case .ready(.local(let php)): return "Sandbox · PHP \(php.version) · \(SandboxManager.serviceSummary)"
            case .ready(.docker(let image, _)): return "Sandbox in Docker (\(image)) · \(SandboxManager.serviceSummary)"
            case .needsImage(let image): return "Sandbox needs Docker image \(image)"
            case .unavailable(let reason): return reason
            default: return "Preparing sandbox…"
            }
        case .local(let id):
            guard let project = model.library.localProject(id) else { return "" }
            let php = project.phpExecutable ?? model.settings.defaultPHPExecutable ?? model.bestPHP?.path
            let version = model.phpInstallations.first { $0.path == php }?.version
            return project.path + (version.map { " · PHP \($0)" } ?? "")
        case .docker(let id):
            guard let profile = model.library.dockerProfile(id) else { return "" }
            return "\(profile.identity.displayName) · \(profile.workingDirectory)" + (profile.user.map { " · user \($0)" } ?? "")
        case .ssh(let id):
            guard let profile = model.library.sshProfile(id) else { return "" }
            return "\(profile.destinationLabel):\(profile.remoteDirectory)" + (model.phpVersionHint(for: tab.target).map { " · PHP \($0)" } ?? "")
        }
    }

    @ViewBuilder
    private var runStatus: some View {
        switch tab.runState {
        case .idle:
            Label("Ready", systemImage: "circle").accessibilityIdentifier("run-status")
        case .preparing:
            Label("Preparing…", systemImage: "hourglass").accessibilityIdentifier("run-status")
        case .running(_, let startedAt), .stopping(_, let startedAt):
            TimelineView(.periodic(from: startedAt, by: 0.1)) { context in
                let elapsed = context.date.timeIntervalSince(startedAt)
                Label(String(format: "%@ %.1fs", tab.runState.isStopping ? "Stopping…" : "Running", elapsed), systemImage: "bolt.fill")
                    .foregroundStyle(.blue)
            }
            .accessibilityIdentifier("run-status")
        case .finished(let info):
            Label("\(info.status.label) · \(info.elapsedMs) ms", systemImage: info.status.symbol)
                .foregroundStyle(info.status.color)
                .accessibilityIdentifier("run-status")
        }
    }

    @ViewBuilder
    private var languageStatus: some View {
        let notes = tab.languageNotes.joined(separator: "\n")
        switch tab.languageState {
        case .ready:
            Label(notes.isEmpty ? "PHPantom" : "PHPantom (limited)", systemImage: notes.isEmpty ? "checkmark.seal" : "exclamationmark.circle")
                .help(notes.isEmpty ? "Language server ready" : notes)
        case .starting:
            Label("Indexing…", systemImage: "arrow.triangle.2.circlepath").help("PHPantom is starting")
        case .restarting(let attempt):
            Label("Restarting (\(attempt))", systemImage: "arrow.clockwise").help("PHPantom stopped unexpectedly and is restarting")
        case .failed(let message):
            Label("PHPantom failed", systemImage: "xmark.octagon").foregroundStyle(.red).help(message)
        case .stopped:
            Label("No completion", systemImage: "minus.circle").help(notes.isEmpty ? "Language service is off for this tab" : notes)
        }
    }
}

extension RunState {
    var isStopping: Bool {
        if case .stopping = self { return true }
        return false
    }
}

extension RunStatus {
    var label: String {
        switch self {
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Stopped"
        }
    }

    var symbol: String {
        switch self {
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .cancelled: "stop.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .completed: .green
        case .failed: .red
        case .cancelled: .orange
        }
    }
}

/// Thin draggable divider that resizes the vertical tab sidebar (140–420 pt).
struct SidebarResizeHandle: View {
    @Binding var width: Double?
    var committed: Double
    /// Allowed widths of the panel being resized.
    var range: ClosedRange<Double> = 140...420
    /// The window edge the panel sits on: dragging toward the window's middle widens it.
    var edge: HorizontalEdge = .leading
    var identifier = "vertical-tabs-resize-handle"
    var onCommit: (Double) -> Void
    @State private var startWidth: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = startWidth ?? (width ?? committed)
                        if startWidth == nil { startWidth = start }
                        let delta = edge == .leading ? value.translation.width : -value.translation.width
                        width = min(range.upperBound, max(range.lowerBound, start + delta))
                    }
                    .onEnded { _ in
                        if let width { onCommit(width) }
                        startWidth = nil
                        width = nil
                    }
            )
            .accessibilityIdentifier(identifier)
    }
}
