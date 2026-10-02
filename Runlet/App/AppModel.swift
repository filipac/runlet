import AppKit
import Observation
import RunletCore
import RunletExecution
import RunletLanguage
import UniformTypeIdentifiers

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// A Docker profile whose container identity needs an explicit user decision.
struct ContainerChoice: Identifiable {
    let id = UUID()
    var profile: DockerProfile
    var candidates: [ContainerInfo]
    var reason: String
}

enum DockerStatus: Equatable {
    case unknown
    case available(version: String)
    case unavailable(String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

enum SandboxStatus: Equatable {
    case checking
    case ready(SandboxRuntime)
    case needsImage(String)
    case unavailable(String)
}

/// Thrown while resolving a target when the user has to act first.
struct TargetResolutionError: Error, CustomStringConvertible {
    var description: String
}

/// Central app state: tabs, saved targets, snippets, history, settings, and the services
/// that execute code and provide language intelligence.
@MainActor
@Observable
final class AppModel {
    let paths: AppPaths
    let resources: AppResources

    var settings: AppSettings { didSet { if settings != oldValue { saveSettings() } } }
    var library: TargetLibrary
    var snippets: [Snippet]
    var history: [HistoryEntry]
    /// Open windows, each with its own tabs.
    var windows: [WindowModel] = []
    /// The frontmost window: menu commands and the inspector act on it.
    var activeWindowId: UUID?

    var phpInstallations: [PHPInstallation] = []
    var dockerStatus: DockerStatus = .unknown
    var runningContainers: [ContainerInfo] = []
    var sandboxStatus: SandboxStatus = .checking
    var alert: AppAlert?
    var containerChoice: ContainerChoice?
    var showInspector = false
    var inspectorPane: InspectorPane = .history

    enum InspectorPane: String, CaseIterable {
        case history = "History"
        case snippets = "Snippets"
        /// Project commands (Artisan, console, Composer scripts, driver commands).
        case commands = "Commands"
    }

    /// Project snippets (`.runlet/snippets/*.php`) per project root; see `projectSnippets(for:)`.
    let projectSnippetCache = ProjectSnippetCache()

    @ObservationIgnored let engine: ExecutionEngine
    @ObservationIgnored let languageService: LanguageService?
    @ObservationIgnored let sandbox: SandboxManager?
    @ObservationIgnored private(set) var docker: DockerCLI?
    @ObservationIgnored private let settingsStore: JSONDocumentStore<AppSettings>
    @ObservationIgnored private let libraryStore: JSONDocumentStore<TargetLibrary>
    @ObservationIgnored private let snippetStore: JSONDocumentStore<[Snippet]>
    @ObservationIgnored private let historyStore: JSONDocumentStore<[HistoryEntry]>
    @ObservationIgnored private let sessionStore: JSONDocumentStore<SessionState>
    @ObservationIgnored private var sessionSaveWork: DispatchWorkItem?
    @ObservationIgnored private var historySaveWork: DispatchWorkItem?

    init(paths: AppPaths = .standard, resources: AppResources = .main) {
        self.paths = paths
        self.resources = resources
        settingsStore = JSONDocumentStore(url: paths.settings)
        libraryStore = JSONDocumentStore(url: paths.targets)
        snippetStore = JSONDocumentStore(url: paths.snippets)
        historyStore = JSONDocumentStore(url: paths.history)
        sessionStore = JSONDocumentStore(url: paths.session)

        var notes: [String] = []
        let loadedSettings = settingsStore.load(default: AppSettings())
        let loadedLibrary = libraryStore.load(default: TargetLibrary())
        let loadedSnippets = snippetStore.load(default: [])
        let loadedHistory = historyStore.load(default: [])
        let loadedSession = sessionStore.load(default: SessionState())
        notes += loadedSettings.recoveryNotes + loadedLibrary.recoveryNotes + loadedSnippets.recoveryNotes + loadedHistory.recoveryNotes + loadedSession.recoveryNotes
        settings = loadedSettings.value
        library = loadedLibrary.value
        snippets = loadedSnippets.value
        history = loadedHistory.value

        let bundle = (try? RunnerBundle(contentsOf: resources.runner)) ?? RunnerBundle(source: Data())
        docker = DockerCLI.locate(override: loadedSettings.value.dockerExecutable)
        engine = ExecutionEngine(bundle: bundle, docker: docker)
        sandbox = try? SandboxManager(templateURL: resources.sandboxTemplate, paths: paths)
        languageService = FileManager.default.isExecutableFile(atPath: resources.phpantom.path)
            ? LanguageService(binary: resources.phpantom, dataDirectory: paths.languageService)
            : nil

        loadPersistedFacts()

        // Restore windows and tabs (code and targets only — nothing runs).
        for windowState in loadedSession.value.windows where !windowState.tabs.isEmpty {
            let window = WindowModel(id: windowState.id)
            window.workspaceURL = windowState.workspacePath.map { URL(fileURLWithPath: $0) }
            window.isWorkspaceEdited = windowState.workspaceEdited
            windows.append(window)
            for state in windowState.tabs { addTab(TabModel(state: state), to: window) }
            window.selectedTabId = windowState.selectedTabId.flatMap { id in window.tabs.contains { $0.id == id } ? id : nil } ?? window.tabs.first?.id
        }
        if windows.isEmpty { makeWindow() }
        if let active = loadedSession.value.activeWindowId, let index = windows.firstIndex(where: { $0.id == active }) {
            windows.insert(windows.remove(at: index), at: 0)
        }
        activeWindowId = windows.first?.id
        pendingLaunchWindowIds = windows.map(\.id)

        if !notes.isEmpty {
            alert = AppAlert(title: "Some saved data was recovered", message: notes.joined(separator: "\n\n"))
        }
        Task { await self.refreshEnvironment() }
    }

    // MARK: Environment

    func refreshEnvironment() async {
        phpInstallations = await PHPDiscovery.discover()
        docker = DockerCLI.locate(override: settings.dockerExecutable)
        await engine.setDocker(docker)
        if let docker {
            do {
                dockerStatus = .available(version: try await docker.serverVersion())
            } catch {
                dockerStatus = .unavailable("\(error)")
            }
        } else {
            dockerStatus = .unavailable("Docker CLI not found")
        }
        await refreshSandbox()
        for tab in allTabs { bindLanguage(tab) }
    }

    func refreshSandbox() async {
        guard let sandbox else {
            sandboxStatus = .unavailable("The bundled sandbox template is missing from this build.")
            return
        }
        sandboxStatus = .checking
        do {
            try await Task.detached { _ = try sandbox.ensureInstalled() }.value
        } catch {
            sandboxStatus = .unavailable("Could not install the sandbox: \(error.localizedDescription)")
            return
        }
        let runtime = await sandbox.chooseRuntime(preferredPHP: settings.defaultPHPExecutable, installations: phpInstallations, docker: dockerStatus.isAvailable ? docker : nil, preference: settings.sandboxRuntime)
        switch runtime {
        case .docker(let image, false): sandboxStatus = .needsImage(image)
        case .unavailable(let reason): sandboxStatus = .unavailable(reason)
        default: sandboxStatus = .ready(runtime)
        }
    }

    func refreshContainers() async {
        guard let docker else {
            runningContainers = []
            return
        }
        do {
            runningContainers = try await docker.runningContainers()
        } catch {
            runningContainers = []
            alert = AppAlert(title: "Could not list containers", message: "\(error)")
        }
    }

    var bestPHP: PHPInstallation? { PHPDiscovery.preferred(phpInstallations) }

    // MARK: Windows

    /// Every tab in every window.
    var allTabs: [TabModel] { windows.flatMap(\.tabs) }

    var activeWindow: WindowModel? { windows.first { $0.id == activeWindowId } ?? windows.first }

    /// Tabs of the active window (menu commands act on these).
    var tabs: [TabModel] { activeWindow?.tabs ?? [] }

    var selectedTabId: UUID? {
        get { activeWindow?.selectedTabId }
        set { activeWindow?.selectedTabId = newValue }
    }

    var selectedTab: TabModel? { activeWindow?.selectedTab }

    func window(_ id: UUID) -> WindowModel? { windows.first { $0.id == id } }

    func window(containing tabId: UUID) -> WindowModel? { windows.first { $0.index(of: tabId) != nil } }

    /// Restored windows not yet shown by SwiftUI.
    @ObservationIgnored var pendingLaunchWindowIds: [UUID] = []
    @ObservationIgnored var isTerminating = false
    /// Variables each target's driver injects (name → type), learned from runs; used to type
    /// them for completion. Keyed by TargetRef.stableKey.
    @ObservationIgnored var driverVariables: [String: [String: String]] = [:]

    /// What runs revealed about each target (PHP version, framework/driver), for tab cards.
    nonisolated struct TargetFacts: Equatable, Codable, Sendable {
        var phpVersion: String?
        var framework: String?
        var frameworkVersion: String?
        var driverName: String?
        var lastStatus: RunStatus?
        /// True once a real run reported these values (more exact than file detection).
        var fromRun: Bool?
    }

    /// Facts per target (keyed by TargetRef.stableKey), persisted so tab cards are complete
    /// right after launch. Filled by file-based detection and refined by runs.
    var targetFacts: [String: TargetFacts] = [:] { didSet { scheduleFactsSave() } }
    @ObservationIgnored private var factsDetectedThisSession = Set<String>()
    @ObservationIgnored private var factsSaveWork: DispatchWorkItem?

    nonisolated struct PersistedFacts: Codable, Sendable {
        var facts: [String: TargetFacts] = [:]
        var driverVariables: [String: [String: String]] = [:]
        /// Optional: files written before host commands existed lack it.
        var hostCommands: [String: HostCommandDeclaration]?
    }

    /// The last `hostCommands()` declaration per target (keyed by TargetRef.stableKey), so
    /// host commands stay available when the target cannot start (e.g. a stopped container).
    @ObservationIgnored var hostCommandDeclarations: [String: HostCommandDeclaration] = [:]

    var factsStore: JSONDocumentStore<PersistedFacts> { JSONDocumentStore(url: paths.state.appendingPathComponent("facts.json")) }

    func loadPersistedFacts() {
        let loaded = factsStore.load(default: PersistedFacts()).value
        targetFacts = loaded.facts
        driverVariables = loaded.driverVariables
        hostCommandDeclarations = loaded.hostCommands ?? [:]
    }

    func scheduleFactsSave() {
        factsSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            try? self.factsStore.save(PersistedFacts(facts: self.targetFacts, driverVariables: self.driverVariables, hostCommands: self.hostCommandDeclarations))
        }
        factsSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Detects framework/driver/PHP for a target without running project code (files on this
    /// Mac, or `php -n` file checks / PHP_VERSION inside the container). Once per session per
    /// target; runs refine the values later.
    func detectFacts(for target: TargetRef) {
        let key = target.stableKey
        guard factsDetectedThisSession.insert(key).inserted else { return }
        Task {
            var detected: DetectedFacts?
            switch target {
            case .sandbox:
                if let sandbox, sandbox.isInstalled {
                    detected = await Task.detached { TargetInspector.staticFacts(projectRoot: sandbox.installURL) }.value
                }
            case .local(let id):
                if let project = library.localProject(id) {
                    let root = URL(fileURLWithPath: project.path)
                    detected = await Task.detached { TargetInspector.staticFacts(projectRoot: root) }.value
                }
            case .docker(let id):
                guard let profile = library.dockerProfile(id), let docker else { break }
                if !dockerStatus.isAvailable, (try? await docker.serverVersion()) == nil { break }
                guard let resolution = try? await DockerProfileResolver.resolve(profile, docker: docker),
                      case .resolved(let container, _) = resolution else { break }
                noteSourceSuggestion(for: profile, container: container)
                if let source = profile.localSourcePath, !source.isEmpty, FileManager.default.fileExists(atPath: source) {
                    let root = URL(fileURLWithPath: source)
                    detected = await Task.detached { TargetInspector.staticFacts(projectRoot: root) }.value
                    detected?.phpVersion = await docker.phpVersion(containerId: container.id, phpExecutable: profile.phpExecutable, user: profile.user)
                } else {
                    detected = await docker.detectFacts(containerId: container.id, phpExecutable: profile.phpExecutable, user: profile.user, workingDirectory: profile.workingDirectory)
                }
            }
            guard let detected else { return }
            var facts = targetFacts[key] ?? TargetFacts()
            if facts.fromRun != true {
                facts.framework = detected.framework ?? facts.framework
                facts.frameworkVersion = detected.frameworkVersion
                facts.driverName = detected.driverName
            }
            if let php = detected.phpVersion { facts.phpVersion = facts.fromRun == true ? (facts.phpVersion ?? php) : php }
            if targetFacts[key] != facts { targetFacts[key] = facts }
        }
    }

    func learnFacts(from event: RunEvent.Kind, for target: TargetRef) {
        var facts = targetFacts[target.stableKey] ?? TargetFacts()
        switch event {
        case .started(let info):
            facts.phpVersion = info.phpVersion ?? facts.phpVersion
        case .bootstrapped(let info):
            facts.framework = info.framework
            facts.frameworkVersion = info.frameworkVersion
            facts.driverName = info.driverName
            facts.fromRun = true
        case .finished(let info):
            facts.lastStatus = info.status
        default:
            return
        }
        if targetFacts[target.stableKey] != facts { targetFacts[target.stableKey] = facts }
    }

    /// Best known PHP version for a target: configured PHP for local/sandbox, else learned.
    func phpVersionHint(for target: TargetRef) -> String? {
        switch target {
        case .sandbox:
            if case .ready(.local(let php)) = sandboxStatus { return php.version }
            if case .ready(.docker(let image, _)) = sandboxStatus { return targetFacts[target.stableKey]?.phpVersion ?? image.split(separator: ":").last.map { String($0.prefix { $0 == "." || $0.isNumber }) } }
        case .local(let id):
            if let project = library.localProject(id) {
                let path = project.phpExecutable ?? settings.defaultPHPExecutable ?? bestPHP?.path
                if let version = phpInstallations.first(where: { $0.path == path })?.version { return version }
            }
        case .docker:
            break
        }
        return targetFacts[target.stableKey]?.phpVersion
    }

    func learnDriverVariables(_ variables: [String: String], for target: TargetRef) {
        guard driverVariables[target.stableKey] != variables else { return }
        driverVariables[target.stableKey] = variables
        scheduleFactsSave()
        for tab in allTabs where tab.target == target {
            tab.editorIfLoaded?.setLanguageDeclarations(variables)
        }
    }
    /// SwiftUI's openWindow action, captured from the first window (used by ⌘N, workspaces, reopen).
    @ObservationIgnored var openWindowAction: ((UUID) -> Void)?
    /// Host folders detected from a profile's container bind mounts, offered as the profile's
    /// local source when it has none (keyed by profile id).
    var sourceSuggestions: [UUID: String] = [:]

    /// Records a local-source suggestion for `profile` from its resolved container.
    func noteSourceSuggestion(for profile: DockerProfile, container: ContainerInfo) {
        guard profile.localSourcePath?.isEmpty ?? true,
              let host = container.hostPath(forContainerPath: profile.workingDirectory),
              FileManager.default.fileExists(atPath: host) else { return }
        if sourceSuggestions[profile.id] != host { sourceSuggestions[profile.id] = host }
    }

    /// Uses the detected host folder as the profile's local source (explicit user action).
    func useSuggestedSource(for profileId: UUID) {
        guard var profile = library.dockerProfile(profileId), let path = sourceSuggestions[profileId] else { return }
        profile.localSourcePath = path
        sourceSuggestions[profileId] = nil
        saveDockerProfile(profile)
    }

    /// Recently closed tabs for ⇧⌘T (see AppModel+Tabs.swift).
    var closedTabs: [ClosedTab] = []
    /// Opens a terminal tab in the active window (set by the terminal panel).
    @ObservationIgnored var openTerminal: ((TerminalRequest) -> Void)?
    /// Files/workspaces opened (Finder, CLI) before any window was on screen.
    @ObservationIgnored var pendingOpenURLs: [URL] = []
    @ObservationIgnored var hasPresentedWindow = false

    /// Opens a PHP file or `.runlet` workspace; during launch, waits until the UI is up so
    /// confirmations never race SwiftUI's first window.
    func open(_ url: URL) {
        guard hasPresentedWindow else {
            if !pendingOpenURLs.contains(url) { pendingOpenURLs.append(url) }
            return
        }
        if url.pathExtension.lowercased() == WorkspaceDocument.fileExtension {
            openWorkspace(url)
        } else {
            openFile(url)
        }
    }

    /// Called by the first window once it is on screen.
    func windowPresented() {
        guard !hasPresentedWindow else { return }
        hasPresentedWindow = true
        let urls = pendingOpenURLs
        pendingOpenURLs = []
        for url in urls { open(url) }
    }

    /// A new window with one tab using the default target.
    @discardableResult
    func makeWindow() -> WindowModel {
        let window = WindowModel()
        windows.append(window)
        newTab(in: window)
        return window
    }

    /// The window value SwiftUI should show when it creates a window on its own (launch,
    /// File ▸ New Window from the system, Dock reopen).
    func nextDefaultWindowId() -> UUID {
        if let pending = pendingLaunchWindowIds.first { return pending }
        return makeWindow().id
    }

    /// Resolves a window value from SwiftUI, creating an empty window if it is unknown.
    func ensureWindow(_ id: UUID) -> WindowModel {
        pendingLaunchWindowIds.removeAll { $0 == id }
        if let existing = window(id) { return existing }
        let window = WindowModel(id: id)
        windows.append(window)
        newTab(in: window)
        return window
    }

    /// Opens a new window (⌘N).
    func openNewWindow() {
        let window = makeWindow()
        openWindowAction?(window.id)
    }

    func windowBecameActive(_ id: UUID) {
        if activeWindowId != id {
            activeWindowId = id
            scheduleSessionSave()
        }
    }

    /// Called after a window really closed: its tabs, runs, and language sessions go away.
    func windowDidClose(_ id: UUID) {
        guard !isTerminating, let index = windows.firstIndex(where: { $0.id == id }) else { return }
        let window = windows.remove(at: index)
        terminateTerminals(in: window)
        for tab in window.tabs {
            if tab.isRunning { stop(tab) }
            unbindLanguage(tab)
        }
        if activeWindowId == id { activeWindowId = windows.first?.id }
        scheduleSessionSave()
    }

    /// Asks before closing a window whose code would be lost. Returns true to close.
    func confirmClose(_ window: WindowModel, presenting nsWindow: NSWindow?) -> Bool {
        guard window.hasUnsavedScratchCode else { return true }
        let alert = NSAlert()
        if let url = window.workspaceURL {
            alert.messageText = "Save changes to the workspace “\(url.lastPathComponent)”?"
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Don't Save")
            switch alert.runModal() {
            case .alertFirstButtonReturn: return saveWorkspace(window, to: url)
            case .alertThirdButtonReturn: return true
            default: return false
            }
        }
        let count = window.tabs.count
        alert.messageText = "Close this window and its \(count == 1 ? "tab" : "\(count) tabs")?"
        alert.informativeText = "Code that is not saved to a file will be discarded. Save the window as a workspace to keep it. (Run history keeps code you already ran.)"
        alert.addButton(withTitle: "Save Workspace…")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Close")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return FilePanels.saveWorkspaceAs(window, model: self)
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    // MARK: Tabs

    private func addTab(_ tab: TabModel, to window: WindowModel, at index: Int? = nil) {
        tab.onChange = { [weak self, weak window] change in
            if change == .content { window?.markEdited() }
            self?.scheduleSessionSave()
        }
        if let index { window.tabs.insert(tab, at: index) } else { window.tabs.append(tab) }
    }

    /// Adds a tab to `window` (default: the active window).
    @discardableResult
    func newTab(target: TargetRef? = nil, code: String = "", title: String? = nil, select: Bool = true, in window: WindowModel? = nil) -> TabModel {
        let window = window ?? activeWindow ?? makeWindow()
        let target = target ?? validTarget(settings.defaultTarget)
        let tab = TabModel(state: TabState(title: title ?? nextTabTitle(in: window), code: code, target: target))
        let index = window.selectedTab.flatMap { selected in window.tabs.firstIndex { $0 === selected } }.map { $0 + 1 }
        addTab(tab, to: window, at: index)
        if select { window.selectedTabId = tab.id }
        window.markEdited()
        bindLanguage(tab)
        scheduleSessionSave()
        return tab
    }

    private func nextTabTitle(in window: WindowModel) -> String {
        var number = window.tabs.count + 1
        while window.tabs.contains(where: { $0.title == "Tab \(number)" }) { number += 1 }
        return "Tab \(number)"
    }

    func validTarget(_ target: TargetRef) -> TargetRef {
        switch target {
        case .sandbox: return .sandbox
        case .local(let id): return library.localProject(id) != nil ? target : .sandbox
        case .docker(let id): return library.dockerProfile(id) != nil ? target : .sandbox
        }
    }

    func closeTab(_ id: UUID) {
        guard let window = window(containing: id), let index = window.index(of: id) else { return }
        let tab = window.tabs[index]
        rememberClosedTab(tab, in: window, at: index)
        if tab.isRunning { stop(tab) }
        unbindLanguage(tab)
        window.tabs.remove(at: index)
        if window.tabs.isEmpty { newTab(in: window) }
        if window.selectedTabId == id { window.selectedTabId = window.tabs[min(index, window.tabs.count - 1)].id }
        window.markEdited()
        scheduleSessionSave()
    }

    func closeOtherTabs(_ id: UUID) {
        guard let window = window(containing: id) else { return }
        for tab in window.tabs where tab.id != id { closeTab(tab.id) }
    }

    func duplicateTab(_ id: UUID) {
        guard let window = window(containing: id), let tab = window.tabs.first(where: { $0.id == id }) else { return }
        newTab(target: tab.target, code: tab.editorIfLoaded?.text ?? tab.code, title: tab.title + " copy", in: window)
    }

    func renameTab(_ id: UUID, to title: String) {
        guard let window = window(containing: id), let tab = window.tabs.first(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != tab.title {
            tab.title = trimmed
            window.markEdited()
        }
        scheduleSessionSave()
    }

    func selectTab(offset: Int) {
        guard let window = activeWindow, let current = window.tabs.firstIndex(where: { $0.id == window.selectedTab?.id }), !window.tabs.isEmpty else { return }
        window.selectedTabId = window.tabs[(current + offset + window.tabs.count) % window.tabs.count].id
    }

    func moveTab(_ id: UUID, to index: Int) {
        guard let window = window(containing: id), let from = window.index(of: id) else { return }
        let tab = window.tabs.remove(at: from)
        window.tabs.insert(tab, at: max(0, min(index, window.tabs.count)))
        window.markEdited()
        scheduleSessionSave()
    }

    // MARK: Targets

    func targetLabel(_ target: TargetRef) -> String {
        switch target {
        case .sandbox:
            return "Laravel Sandbox" + (sandbox.map { " \($0.manifest.laravelVersion)" } ?? "")
        case .local(let id):
            return library.localProject(id)?.name ?? "Missing project"
        case .docker(let id):
            return library.dockerProfile(id).map { "\($0.name) (Docker)" } ?? "Missing Docker profile"
        }
    }

    func targetSymbol(_ target: TargetRef) -> String {
        switch target {
        case .sandbox: "shippingbox"
        case .local: "folder"
        case .docker: "cube.box"
        }
    }

    func setTarget(_ target: TargetRef, for tab: TabModel) {
        guard tab.target != target else { return }
        tab.target = target
        window(containing: tab.id)?.markEdited()
        tab.targetIssue = nil
        tab.lastRun = nil
        switch target {
        case .local(let id): touchProject(id)
        case .docker(let id): touchProfile(id)
        case .sandbox: break
        }
        bindLanguage(tab)
        scheduleSessionSave()
    }

    /// Opens a directory as a local project (or reuses the saved one) and returns it.
    @discardableResult
    func openProject(at url: URL) -> LocalProject {
        let path = url.standardizedFileURL.path
        if let existing = library.localProjects.first(where: { $0.path == path }) {
            touchProject(existing.id)
            return existing
        }
        let project = LocalProject(name: url.lastPathComponent, path: path, lastOpenedAt: Date())
        library.localProjects.append(project)
        saveLibrary()
        return project
    }

    func saveProject(_ project: LocalProject) {
        factsDetectedThisSession.remove(TargetRef.local(project.id).stableKey)
        var updated = project
        if let index = library.localProjects.firstIndex(where: { $0.id == project.id }) {
            updated.revision = library.localProjects[index].revision + 1
            library.localProjects[index] = updated
        } else {
            library.localProjects.append(updated)
        }
        saveLibrary()
        for tab in allTabs where tab.target == .local(project.id) { bindLanguage(tab) }
    }

    func removeProject(_ id: UUID) {
        library.localProjects.removeAll { $0.id == id }
        saveLibrary()
        for tab in allTabs where tab.target == .local(id) { setTarget(.sandbox, for: tab) }
    }

    func saveDockerProfile(_ profile: DockerProfile) {
        factsDetectedThisSession.remove(TargetRef.docker(profile.id).stableKey)
        var updated = profile
        if let index = library.dockerProfiles.firstIndex(where: { $0.id == profile.id }) {
            updated.revision = library.dockerProfiles[index].revision + 1
            library.dockerProfiles[index] = updated
        } else {
            library.dockerProfiles.append(updated)
        }
        saveLibrary()
        for tab in allTabs where tab.target == .docker(profile.id) { bindLanguage(tab) }
    }

    func removeDockerProfile(_ id: UUID) {
        library.dockerProfiles.removeAll { $0.id == id }
        saveLibrary()
        for tab in allTabs where tab.target == .docker(id) { setTarget(.sandbox, for: tab) }
    }

    private func touchProject(_ id: UUID) {
        guard let index = library.localProjects.firstIndex(where: { $0.id == id }) else { return }
        library.localProjects[index].lastOpenedAt = Date()
        saveLibrary()
    }

    private func touchProfile(_ id: UUID) {
        guard let index = library.dockerProfiles.firstIndex(where: { $0.id == id }) else { return }
        library.dockerProfiles[index].lastOpenedAt = Date()
        saveLibrary()
        // Optionally resolve the container now (never runs code).
        let profile = library.dockerProfiles[index]
        if profile.autoResolve, let docker {
            Task {
                let resolution = try? await DockerProfileResolver.resolve(profile, docker: docker)
                if case .resolved(let container, _) = resolution { noteSourceSuggestion(for: profile, container: container) }
                for tab in allTabs where tab.target == .docker(id) {
                    switch resolution {
                    case .notRunning(let message): tab.targetIssue = message
                    case .ambiguous: tab.targetIssue = "Several containers match this profile; you will be asked to choose when you run."
                    case .needsConfirmation(_, let reason): tab.targetIssue = reason
                    default: tab.targetIssue = nil
                    }
                }
            }
        }
    }

    /// The user explicitly chose `container` for `profile` (after recreation or ambiguity).
    func confirmContainer(_ container: ContainerInfo, for profile: DockerProfile) {
        var updated = profile
        updated.identity.lastContainerId = container.id
        updated.identity.lastImage = container.image
        if !updated.identity.isCompose { updated.identity.containerName = container.name }
        saveDockerProfile(updated)
        containerChoice = nil
        for tab in allTabs where tab.target == .docker(profile.id) { tab.targetIssue = nil }
    }

    /// Resolves a tab's target into a run snapshot. Throws with a user-facing message when
    /// the target cannot be used; never substitutes a different container silently.
    func snapshot(for tab: TabModel) async throws -> TargetSnapshot {
        switch tab.target {
        case .sandbox:
            guard let sandbox else { throw TargetResolutionError(description: "The sandbox template is missing from this build.") }
            if case .checking = sandboxStatus { await refreshSandbox() }
            switch sandboxStatus {
            case .ready(.local(let php)):
                return TargetSnapshot(kind: .sandboxLocal, label: "Sandbox · Laravel \(sandbox.manifest.laravelVersion)", targetId: "sandbox", workingDirectory: sandbox.installURL.path, phpExecutable: php.path)
            case .ready(.docker(let image, _)):
                return TargetSnapshot(kind: .sandboxDocker, label: "Sandbox · Laravel \(sandbox.manifest.laravelVersion) (Docker)", targetId: "sandbox", workingDirectory: SandboxManager.containerDirectory, phpExecutable: "php", image: image, hostMountDirectory: sandbox.installURL.path)
            case .needsImage(let image):
                throw TargetResolutionError(description: "No compatible local PHP was found, so the sandbox runs in Docker. Download the \(image) image first (use the banner above the editor, or Settings ▸ Sandbox).")
            case .unavailable(let reason):
                throw TargetResolutionError(description: reason)
            default:
                throw TargetResolutionError(description: "The sandbox is not ready yet.")
            }

        case .local(let id):
            guard let project = library.localProject(id) else { throw TargetResolutionError(description: "This tab's project was removed. Choose another target.") }
            guard let php = project.phpExecutable ?? settings.defaultPHPExecutable ?? bestPHP?.path else {
                throw TargetResolutionError(description: "No PHP executable was found. Set one in Settings ▸ PHP or in the project's options.")
            }
            return TargetSnapshot(kind: .local, label: project.name, targetId: project.id.uuidString, profileRevision: project.revision, workingDirectory: project.path, phpExecutable: php)

        case .docker(let id):
            guard let profile = library.dockerProfile(id) else { throw TargetResolutionError(description: "This tab's Docker profile was removed. Choose another target.") }
            guard let docker else {
                throw TargetResolutionError(description: "The Docker CLI was not found. Install Docker or set its path in Settings.")
            }
            if !dockerStatus.isAvailable {
                guard let version = try? await docker.serverVersion() else {
                    throw TargetResolutionError(description: "Docker is not available. Start Docker and try again.")
                }
                dockerStatus = .available(version: version)
            }
            let resolution = try await DockerProfileResolver.resolve(profile, docker: docker)
            switch resolution {
            case .resolved(let container, let recreated):
                noteSourceSuggestion(for: profile, container: container)
                if recreated || profile.identity.lastContainerId != container.id {
                    var updated = profile
                    updated.identity.lastContainerId = container.id
                    updated.identity.lastImage = container.image
                    saveDockerProfile(updated)
                }
                tab.targetIssue = nil
                return TargetSnapshot(kind: .docker, label: "\(profile.name) · \(container.name)", targetId: profile.id.uuidString, profileRevision: profile.revision, workingDirectory: profile.workingDirectory, phpExecutable: profile.phpExecutable, containerId: container.id, containerName: container.name, image: container.image, user: profile.user, temporaryDirectory: profile.temporaryDirectory)
            case .ambiguous(let candidates):
                containerChoice = ContainerChoice(profile: profile, candidates: candidates, reason: "Several running containers match \(profile.identity.displayName). Choose the one to use.")
                throw TargetResolutionError(description: "Choose which container to use, then run again.")
            case .needsConfirmation(let container, let reason):
                containerChoice = ContainerChoice(profile: profile, candidates: [container], reason: reason)
                throw TargetResolutionError(description: reason)
            case .notRunning(let message):
                tab.targetIssue = message
                throw TargetResolutionError(description: "\(message) Start the application's containers and run again.")
            }
        }
    }

    // MARK: Running

    func run(_ tab: TabModel, selectionOnly: Bool = false) {
        guard !tab.isRunning else { return }
        let editor = tab.editor
        let range = editor.selectedRange
        let useSelection = selectionOnly || (settings.runPrefersSelection && range.length > 0)
        var code = editor.text
        var selection: SourceSelection?
        if useSelection {
            guard let selected = editor.selectedText, !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                alert = AppAlert(title: "Nothing selected", message: "Select the code to run, or use Run to run the whole tab.")
                return
            }
            code = selected
            let position = TextLineIndex(editor.text).position(at: range.location)
            selection = SourceSelection(startLine: position.line + 1, startColumn: position.character + 1, utf16Range: NSRangeCodable(range))
        }
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let documentVersion = tab.documentVersion
        let target = tab.target
        let strictTypes = self.strictTypes(for: target)
        tab.beginRun()

        Task {
            let snapshot: TargetSnapshot
            do {
                snapshot = try await self.snapshot(for: tab)
            } catch {
                tab.failBeforeLaunch("\(error)")
                return
            }
            // The snapshot is fixed now; later edits or target changes cannot redirect this run.
            let request = RunRequest(tabId: tab.id, documentVersion: documentVersion, target: snapshot, code: code, selection: selection, strictTypes: strictTypes)
            let stream: AsyncStream<RunEvent>
            do {
                stream = try await engine.start(request)
            } catch {
                tab.failBeforeLaunch("\(error)")
                return
            }
            tab.started(request)
            var finished: FinishedInfo?
            for await event in stream {
                tab.apply(event)
                if case .finished(let info) = event.kind { finished = info }
                if case .bootstrapped(let info) = event.kind, let variables = info.variables {
                    learnDriverVariables(variables, for: target)
                }
                learnFacts(from: event.kind, for: target)
            }
            if let finished {
                recordHistory(code: code, target: target, label: snapshot.label, runId: request.runId, finished: finished)
            }
        }
    }

    func stop(_ tab: TabModel) {
        switch tab.runState {
        case .preparing:
            tab.cancelPreparing()
        case .running(let runId, let startedAt):
            tab.runState = .stopping(runId: runId, startedAt: startedAt)
            Task {
                if let outcome = await engine.cancel(runId: runId), !outcome.confirmed {
                    tab.stopMessage = outcome.message
                }
            }
        default:
            break
        }
    }

    // MARK: History

    private func recordHistory(code: String, target: TargetRef, label: String, runId: UUID, finished: FinishedInfo) {
        history.insert(HistoryEntry(runId: runId, code: code, target: target, targetLabel: label, status: finished.status, reason: finished.reason, elapsedMs: finished.elapsedMs), at: 0)
        if history.count > settings.historyLimit { history.removeLast(history.count - settings.historyLimit) }
        scheduleHistorySave()
    }

    /// Loads code from history without running it.
    func restore(_ entry: HistoryEntry, inNewTab: Bool) {
        if inNewTab {
            newTab(target: validTarget(entry.target), code: entry.code, title: "History")
        } else if let tab = selectedTab {
            tab.replaceCode(entry.code)
        }
    }

    func clearHistory() {
        history = []
        scheduleHistorySave()
    }

    func deleteHistory(_ id: UUID) {
        history.removeAll { $0.id == id }
        scheduleHistorySave()
    }

    // MARK: Snippets

    @discardableResult
    func saveSnippet(label: String, code: String, target: TargetRef?) -> Snippet {
        let snippet = Snippet(label: label.isEmpty ? "Untitled snippet" : label, code: code, target: target, targetLabel: target.map(targetLabel))
        snippets.insert(snippet, at: 0)
        saveSnippets()
        return snippet
    }

    func updateSnippet(_ snippet: Snippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        var updated = snippet
        updated.updatedAt = Date()
        updated.targetLabel = snippet.target.map(targetLabel)
        snippets[index] = updated
        saveSnippets()
    }

    func deleteSnippet(_ id: UUID) {
        snippets.removeAll { $0.id == id }
        saveSnippets()
    }

    /// Opens a snippet without running it. Its target association is applied only to a new tab.
    func open(_ snippet: Snippet, inNewTab: Bool) {
        if inNewTab {
            newTab(target: snippet.target.map(validTarget), code: snippet.code, title: snippet.label)
        } else if let tab = selectedTab {
            tab.replaceCode(snippet.code)
        }
    }

    // MARK: Project snippets

    /// The folder whose `.runlet/snippets/` a target shares: a local project's directory or a
    /// Docker profile's local source checkout. The sandbox has none.
    func projectRoot(for target: TargetRef) -> URL? {
        switch target {
        case .sandbox:
            return nil
        case .local(let id):
            return library.localProject(id).map { URL(fileURLWithPath: $0.path, isDirectory: true) }
        case .docker(let id):
            guard let path = library.dockerProfile(id)?.localSourcePath, !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    /// The project or profile name shown with a target's project snippets.
    func projectName(for target: TargetRef) -> String? {
        switch target {
        case .sandbox: nil
        case .local(let id): library.localProject(id)?.name
        case .docker(let id): library.dockerProfile(id)?.name
        }
    }

    /// The target's project snippets, sorted by label. Cached per project root until
    /// `refreshProjectSnippets` runs; reading them never runs code.
    func projectSnippets(for target: TargetRef) -> [ProjectSnippet] {
        guard let root = projectRoot(for: target) else { return [] }
        return projectSnippetCache.snippets(root: root)
    }

    /// Re-reads a target's snippets folder (every cached folder when `target` is nil).
    func refreshProjectSnippets(for target: TargetRef? = nil) {
        if let target {
            if let root = projectRoot(for: target) { projectSnippetCache.reload(root: root) }
        } else {
            projectSnippetCache.reloadAll()
        }
    }

    /// Writes `.runlet/snippets/<slug>.php` in the target's project. Throws
    /// `ProjectSnippets.SaveError.fileExists` instead of replacing a file unless `overwrite`.
    @discardableResult
    func saveProjectSnippet(label: String, description: String?, code: String, target: TargetRef, overwrite: Bool = false) throws -> URL {
        guard let root = projectRoot(for: target) else {
            throw TargetResolutionError(description: "This target has no project folder for shared snippets.")
        }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = try ProjectSnippets.save(label: trimmed.isEmpty ? "Untitled snippet" : trimmed, description: description, code: code, projectRoot: root, overwrite: overwrite)
        projectSnippetCache.reload(root: root)
        return url
    }

    /// Opens a project snippet without running it. A new tab uses `target`, the project the
    /// snippet belongs to; the current tab keeps its target.
    func open(_ snippet: ProjectSnippet, target: TargetRef, inNewTab: Bool) {
        if inNewTab {
            newTab(target: validTarget(target), code: snippet.code, title: snippet.label)
        } else if let tab = selectedTab {
            tab.replaceCode(snippet.code)
        }
    }

    /// Copies a project snippet into personal snippets, associated with `target`.
    @discardableResult
    func copyToPersonalSnippets(_ snippet: ProjectSnippet, target: TargetRef) -> Snippet {
        saveSnippet(label: snippet.label, code: snippet.code, target: target)
    }

    // MARK: Strict types

    /// Whether runs on `target` declare `strict_types=1`: the project's or Docker profile's
    /// override, else Settings ▸ General ▸ Running. The sandbox uses the global setting.
    func strictTypes(for target: TargetRef) -> Bool {
        library.strictTypes(for: target, global: settings.strictTypes)
    }

    /// Flips the global strict-types setting (per-target overrides still win).
    func toggleStrictTypes() {
        settings.strictTypes.toggle()
    }

    // MARK: Workspaces

    /// The window's tabs as a self-contained workspace document.
    func workspaceDocument(for window: WindowModel, base: URL) -> WorkspaceDocument {
        let tabs = window.tabs.map { tab in
            WorkspaceTab(
                title: tab.title,
                code: tab.editorIfLoaded?.text ?? tab.code,
                target: WorkspaceTargets.definition(for: tab.target, library: library, base: base),
                file: tab.fileURL.map { WorkspaceTargets.storedPath($0.path, relativeTo: base) }
            )
        }
        return WorkspaceDocument(tabs: tabs, selectedIndex: window.selectedTab.flatMap { window.index(of: $0.id) })
    }

    /// Writes the window as a `.runlet` workspace. Never runs code.
    @discardableResult
    func saveWorkspace(_ window: WindowModel, to url: URL) -> Bool {
        do {
            let document = workspaceDocument(for: window, base: url.deletingLastPathComponent())
            try document.encoded().write(to: url, options: .atomic)
            window.workspaceURL = url
            window.isWorkspaceEdited = false
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            scheduleSessionSave()
            return true
        } catch {
            alert = AppAlert(title: "Could not save the workspace", message: error.localizedDescription)
            return false
        }
    }

    /// Opens a workspace in a new window (or focuses the window that already has it open).
    /// Targets are matched against saved ones; new definitions are added only after the user
    /// agrees. Nothing runs.
    @discardableResult
    func openWorkspace(_ url: URL) -> WindowModel? {
        let standardized = url.standardizedFileURL
        if let open = windows.first(where: { $0.workspaceURL?.standardizedFileURL == standardized }) {
            activeWindowId = open.id
            openWindowAction?(open.id)
            return open
        }
        let document: WorkspaceDocument
        do {
            document = try WorkspaceDocument.read(from: Data(contentsOf: url))
        } catch {
            alert = AppAlert(title: "Could not open \(url.lastPathComponent)", message: "\(error)")
            return nil
        }
        let base = url.deletingLastPathComponent()

        // Match embedded targets to saved ones; collect the ones the user doesn't have yet.
        var resolved: [TargetRef?] = document.tabs.map { WorkspaceTargets.match($0.target, in: library, base: base) }
        var missing: [(index: Int, target: WorkspaceTarget)] = []
        for (index, tab) in document.tabs.enumerated() where resolved[index] == nil {
            missing.append((index, tab.target))
        }
        if !missing.isEmpty {
            var unique: [WorkspaceTarget] = []
            for item in missing where !unique.contains(item.target) { unique.append(item.target) }
            let alert = NSAlert()
            alert.messageText = "Add \(unique.count == 1 ? "a target" : "\(unique.count) targets") from “\(url.lastPathComponent)”?"
            alert.informativeText = "This workspace uses targets that aren't in your library yet:\n\n" + unique.map { "• " + $0.displayName + Self.targetDetail($0, base: base) }.joined(separator: "\n") + "\n\nAdding them doesn't connect to or run anything."
            alert.addButton(withTitle: "Add and Open")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            var created: [WorkspaceTarget: TargetRef] = [:]
            for item in missing {
                if let existing = created[item.target] {
                    resolved[item.index] = existing
                    continue
                }
                let made = WorkspaceTargets.makeTarget(item.target, base: base)
                if let project = made.project { library.localProjects.append(project) }
                if let profile = made.profile { library.dockerProfiles.append(profile) }
                created[item.target] = made.ref
                resolved[item.index] = made.ref
            }
            saveLibrary()
        }

        let window = WindowModel()
        windows.append(window)
        for (index, tab) in document.tabs.enumerated() {
            let model = TabModel(state: TabState(title: tab.title, code: tab.code, target: resolved[index] ?? .sandbox))
            model.fileURL = tab.file.map { URL(fileURLWithPath: WorkspaceTargets.resolvedPath($0, relativeTo: base)) }
            addTab(model, to: window)
            bindLanguage(model)
        }
        if window.tabs.isEmpty { newTab(in: window) }
        window.selectedTabId = document.selectedIndex.flatMap { window.tabs.indices.contains($0) ? window.tabs[$0].id : nil } ?? window.tabs.first?.id
        window.workspaceURL = url
        window.isWorkspaceEdited = false
        activeWindowId = window.id
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        scheduleSessionSave()
        openWindowAction?(window.id)
        return window
    }

    private static func targetDetail(_ target: WorkspaceTarget, base: URL) -> String {
        switch target {
        case .sandbox: return ""
        case .local(let definition): return " — " + WorkspaceTargets.resolvedPath(definition.path, relativeTo: base)
        case .docker(let definition):
            let identity = [definition.composeProject, definition.composeService].compactMap { $0 }.joined(separator: "/")
            return " — " + (identity.isEmpty ? definition.containerName ?? "" : identity) + " " + definition.workingDirectory
        }
    }

    // MARK: Files

    func openFile(_ url: URL) {
        let standardized = url.standardizedFileURL
        if let existing = allTabs.first(where: { $0.fileURL?.standardizedFileURL == standardized }), let window = window(containing: existing.id) {
            window.selectedTabId = existing.id
            activeWindowId = window.id
            return
        }
        do {
            let code = try String(contentsOf: url, encoding: .utf8)
            let tab = newTab(code: code, title: url.lastPathComponent)
            tab.fileURL = url
            tab.isFileDirty = false
            scheduleSessionSave()
        } catch {
            alert = AppAlert(title: "Could not open \(url.lastPathComponent)", message: error.localizedDescription)
        }
    }

    /// Writes the tab's code to disk. Saving never executes code.
    func save(_ tab: TabModel, to url: URL? = nil) -> Bool {
        guard let destination = url ?? tab.fileURL else { return false }
        do {
            try (tab.editorIfLoaded?.text ?? tab.code).write(to: destination, atomically: true, encoding: .utf8)
            tab.markSaved(to: destination)
            scheduleSessionSave()
            return true
        } catch {
            alert = AppAlert(title: "Could not save \(destination.lastPathComponent)", message: error.localizedDescription)
            return false
        }
    }

    // MARK: Sandbox

    func resetSandbox() async {
        guard let sandbox else { return }
        do {
            try await Task.detached { try sandbox.reset() }.value
            await refreshSandbox()
            alert = AppAlert(title: "Sandbox reset", message: "The Laravel sandbox was restored to a fresh copy. Only sandbox-owned data was removed.")
        } catch {
            alert = AppAlert(title: "Could not reset the sandbox", message: error.localizedDescription)
        }
    }

    var isPullingImage = false

    func downloadSandboxImage() async {
        guard let docker, let sandbox else { return }
        isPullingImage = true
        defer { isPullingImage = false }
        do {
            try await docker.run(["pull", sandbox.manifest.dockerImage], timeout: .seconds(1800))
            await refreshSandbox()
        } catch {
            alert = AppAlert(title: "Could not download \(sandbox.manifest.dockerImage)", message: "\(error)")
        }
    }

    // MARK: Language service

    func languageWorkspace(for target: TargetRef) -> LanguageWorkspace? {
        guard let languageService, settings.languageServiceEnabled else { return nil }
        switch target {
        case .sandbox:
            guard let sandbox, sandbox.isInstalled else { return nil }
            return LanguageWorkspace(kind: .project, rootPath: sandbox.installURL.path)
        case .local(let id):
            guard let project = library.localProject(id) else { return nil }
            return LanguageWorkspace(kind: .project, rootPath: project.path, phpVersion: project.languagePHPVersion)
        case .docker(let id):
            guard let profile = library.dockerProfile(id) else { return nil }
            if let source = profile.localSourcePath, !source.isEmpty {
                return LanguageWorkspace(kind: .project, rootPath: source, phpVersion: profile.languagePHPVersion)
            }
            return LanguageWorkspace(kind: .basic, rootPath: languageService.basicWorkspaceRoot.path, phpVersion: profile.languagePHPVersion)
        }
    }

    func bindLanguage(_ tab: TabModel) {
        detectFacts(for: tab.target)
        let workspace = languageWorkspace(for: tab.target)
        guard workspace != tab.languageWorkspace || tab.languageWorkspace == nil else { return }
        unbindLanguage(tab)
        guard let workspace, let languageService else {
            tab.languageState = .stopped
            tab.languageNotes = settings.languageServiceEnabled && self.languageService == nil ? ["PHPantom is missing from this build."] : []
            return
        }
        tab.languageWorkspace = workspace
        tab.languageNotes = workspace.sourceLimitations()
        let editor = tab.editor
        Task {
            let session = await languageService.acquire(workspace, for: tab.id)
            guard tab.languageWorkspace == workspace else { return }
            editor.bindLanguage(session: session, uri: LanguageService.scratchURI(root: workspace.rootURL, documentId: tab.id), declarations: driverVariables[tab.target.stableKey] ?? [:], limited: workspace.kind == .basic)
            tab.languageStateTask = Task {
                for await state in await session.stateUpdates() {
                    tab.languageState = state
                }
            }
        }
    }

    func unbindLanguage(_ tab: TabModel) {
        tab.languageStateTask?.cancel()
        tab.languageStateTask = nil
        tab.editorIfLoaded?.unbindLanguage()
        if let workspace = tab.languageWorkspace, let languageService {
            Task { await languageService.release(workspace, for: tab.id) }
        }
        tab.languageWorkspace = nil
        tab.languageState = .stopped
    }

    func restartLanguageServer(for tab: TabModel) {
        guard let workspace = tab.languageWorkspace, let languageService else {
            bindLanguage(tab)
            return
        }
        Task {
            let session = await languageService.acquire(workspace, for: tab.id)
            await session.restart()
        }
    }

    func setLanguageServiceEnabled(_ enabled: Bool) {
        settings.languageServiceEnabled = enabled
        for tab in allTabs {
            if enabled { bindLanguage(tab) } else { unbindLanguage(tab) }
        }
    }

    // MARK: Persistence

    func scheduleSessionSave() {
        sessionSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveSession() }
        sessionSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func scheduleHistorySave() {
        historySaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveHistory() }
        historySaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveSession() {
        guard !isTerminating || !windows.isEmpty else { return }
        persist { try sessionStore.save(SessionState(windows: windows.map(\.state), activeWindowId: activeWindowId)) }
    }

    private func saveHistory() { persist { try historyStore.save(history) } }
    private func saveSettings() { persist { try settingsStore.save(settings) } }
    private func saveLibrary() { persist { try libraryStore.save(library) } }
    private func saveSnippets() { persist { try snippetStore.save(snippets) } }

    private func persist(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            alert = AppAlert(title: "Could not save Runlet data", message: error.localizedDescription)
        }
    }

    /// Flushes pending writes (called on quit).
    func flush() {
        sessionSaveWork?.cancel()
        historySaveWork?.cancel()
        saveSession()
        saveHistory()
    }

    /// Stops active runs and language servers before quitting.
    func shutdown() async {
        flush()
        // Windows close after this point; keep their tabs in the saved session.
        isTerminating = true
        await engine.cancelAll()
        await languageService?.stopAll()
    }
}

/// Project snippets read from `<root>/.runlet/snippets`, cached per root. Views observe
/// `generation`, which changes whenever a folder is re-read.
@Observable
final class ProjectSnippetCache {
    private(set) var generation = 0
    @ObservationIgnored private var entries: [String: [ProjectSnippet]] = [:]

    func snippets(root: URL) -> [ProjectSnippet] {
        _ = generation
        if let cached = entries[root.path] { return cached }
        let loaded = ProjectSnippets.load(projectRoot: root)
        entries[root.path] = loaded
        return loaded
    }

    func reload(root: URL) {
        entries[root.path] = ProjectSnippets.load(projectRoot: root)
        generation += 1
    }

    func reloadAll() {
        entries.removeAll()
        generation += 1
    }
}

/// Locations of resources inside the app bundle.
struct AppResources {
    var runner: URL
    var sandboxTemplate: URL
    var phpantom: URL

    static var main: AppResources {
        let bundle = Bundle.main
        let resources = bundle.resourceURL ?? URL(fileURLWithPath: ".")
        return AppResources(
            runner: resources.appendingPathComponent("Runner/runlet-runner.php"),
            sandboxTemplate: resources.appendingPathComponent("Sandbox/laravel", isDirectory: true),
            phpantom: bundle.bundleURL.appendingPathComponent("Contents/Helpers/phpantom_lsp")
        )
    }
}
