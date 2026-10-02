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
    @State private var editingProject: LocalProject?
    @State private var savingSnippet: SnippetDraft?
    @State private var confirmReset = false
    @State private var showSwitcher = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            TabStrip()
            Divider()
            if let tab = window.selectedTab {
                TabContent(tab: tab)
                    .id(tab.id)
            } else {
                ContentUnavailableView("No tab", systemImage: "doc.text")
            }
        }
        .toolbar { toolbarContent }
        .inspector(isPresented: $model.showInspector) {
            LibraryInspector()
                .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
        }
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
            editingProfile = DockerProfile(name: "", identity: ContainerIdentity(), workingDirectory: "/var/www/html")
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveSnippetRequested).filter { _ in isActiveWindow }) { _ in
            beginSaveSnippet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .resetSandboxRequested).filter { _ in isActiveWindow }) { _ in
            confirmReset = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchTargetRequested).filter { _ in isActiveWindow }) { _ in
            showSwitcher = true
        }
        .sheet(isPresented: $showSwitcher) {
            TargetSwitcher()
        }
        .onReceive(NotificationCenter.default.publisher(for: .editProjectRequested).filter { _ in isActiveWindow }) { note in
            if let id = note.object as? UUID { editingProject = model.library.localProject(id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .editDockerProfileRequested).filter { _ in isActiveWindow }) { note in
            if let id = note.object as? UUID { editingProfile = model.library.dockerProfile(id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            model.saveSession()
        }
        .frame(minWidth: 760, minHeight: 420)
    }

    private var isActiveWindow: Bool { model.activeWindowId == window.id }

    private func beginSaveSnippet() {
        guard let tab = window.selectedTab else { return }
        let code = tab.editor.selectedText ?? tab.editor.text
        savingSnippet = SnippetDraft(label: "", code: code, target: tab.target, associate: tab.target != .sandbox)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            TargetMenu(onNewDockerProfile: {
                editingProfile = DockerProfile(name: "", identity: ContainerIdentity(), workingDirectory: "/var/www/html")
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
                    .help("Stop (⌘.)")
                    .accessibilityIdentifier("stop-button")
                } else {
                    Button {
                        model.run(tab)
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .help("Run (⌘R)")
                    .accessibilityIdentifier("run-button")
                    Button {
                        model.run(tab, selectionOnly: true)
                    } label: {
                        Label("Run Selection", systemImage: "text.cursor")
                    }
                    .help("Run Selection (⇧⌘R)")
                    .accessibilityIdentifier("run-selection-button")
                }
            }
            Button {
                beginSaveSnippet()
            } label: {
                Label("Save Snippet", systemImage: "bookmark")
            }
            .help("Save as Snippet (⌥⌘S)")
            Button {
                model.showInspector.toggle()
            } label: {
                Label("History & Snippets", systemImage: "sidebar.trailing")
            }
            .help("History & Snippets (⌘Y)")
        }
    }
}

extension Notification.Name {
    static let switchTargetRequested = Notification.Name("RunletSwitchTargetRequested")
    static let editProjectRequested = Notification.Name("RunletEditProjectRequested")
    static let editDockerProfileRequested = Notification.Name("RunletEditDockerProfileRequested")
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
    }

    @ViewBuilder
    private var split: some View {
        let editor = CodeEditorView(
            controller: tab.editor,
            fontSize: model.settings.fontSize,
            tabWidth: model.settings.tabWidth,
            insertSpaces: model.settings.insertSpaces,
            isDark: colorScheme == .dark
        )
        .frame(minWidth: 280, minHeight: 120)
        let output = OutputPane(tab: tab)
            .frame(minWidth: 240, minHeight: 100)
        switch model.settings.outputLayout {
        case .right:
            HSplitView {
                editor
                output
            }
        case .bottom:
            VSplitView {
                editor
                output
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
                Divider()
                Button("Switch Target… (⌘P)") { NotificationCenter.default.post(name: .switchTargetRequested, object: nil) }
                Button("Open Project…") { FilePanels.openProject(model: model) }
                Button("New Docker Profile…") { onNewDockerProfile() }
                Divider()
                switch tab.target {
                case .local(let id):
                    if let project = model.library.localProject(id) {
                        Button("Project Options…") { onEditProject(project) }
                    }
                case .docker(let id):
                    if let profile = model.library.dockerProfile(id) {
                        Button("Edit Docker Profile…") { onEditProfile(profile) }
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
            if let message = tab.stopMessage {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(1)
            }
            Spacer()
            if let summary = tab.lastRun {
                if let php = summary.phpVersion { Text("PHP \(php)") }
                if let framework = summary.framework, framework != "plain" {
                    Text(framework.capitalized + (summary.frameworkVersion.map { " \($0)" } ?? ""))
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
