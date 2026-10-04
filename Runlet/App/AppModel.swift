import AppKit
import Observation
import RunletCore
import RunletExecution
import RunletLanguage
import SwiftUI
import UniformTypeIdentifiers

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// A Docker profile, or an SSH profile's container step, whose container identity needs an
/// explicit user decision.
struct ContainerChoice: Identifiable {
    let id = UUID()
    /// `.docker(id)` or `.ssh(id)`.
    var target: TargetRef
    var profileName: String
    var candidates: [ContainerInfo]
    var reason: String

    init(profile: DockerProfile, candidates: [ContainerInfo], reason: String) {
        self.init(target: .docker(profile.id), profileName: profile.name, candidates: candidates, reason: reason)
    }

    init(target: TargetRef, profileName: String, candidates: [ContainerInfo], reason: String) {
        self.target = target
        self.profileName = profileName
        self.candidates = candidates
        self.reason = reason
    }
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

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            if settings.appearance != oldValue.appearance { applyAppearance() }
            saveSettings()
        }
    }
    var library: TargetLibrary
    var snippets: [Snippet]
    var history: [HistoryEntry]
    /// Open windows, each with its own tabs.
    var windows: [WindowModel] = []
    /// The frontmost window: menu commands and the inspector act on it.
    var activeWindowId: UUID?

    var phpInstallations: [PHPInstallation] = []
    /// Whether the first PHP discovery has finished. Until then `phpInstallations` is empty
    /// because nothing was scanned yet, not because this Mac has no PHP (#91).
    private(set) var hasDiscoveredPHP = false
    /// Runlet's own PHP (#2): downloaded only on request, listed after every discovered
    /// installation so it is used only when none fits.
    var runletPHPState: RunletPHPState = .notInstalled
    var runletPHP: RunletPHPStore {
        var release = RunletPHPRelease.current
        #if DEBUG
        // RUNLET_DEBUG_PHP_URL fetches this Mac's archive from elsewhere (a CI artifact served
        // locally, before the release exists); it must still match the pinned checksum.
        if let url = ProcessInfo.processInfo.environment["RUNLET_DEBUG_PHP_URL"].flatMap(URL.init(string:)),
           var asset = release.assetForThisMac {
            asset.url = url
            release.assets[RunletPHPRelease.machineArchitecture] = asset
        }
        #endif
        return RunletPHPStore(paths: paths, release: release)
    }
    var dockerStatus: DockerStatus = .unknown
    var runningContainers: [ContainerInfo] = []
    var sandboxStatus: SandboxStatus = .checking
    var alert: AppAlert?
    var containerChoice: ContainerChoice?
    /// Whether the History & Snippets panel (the trailing column) is open.
    var showInspector = false
    var inspectorPane: InspectorPane = .history

    /// Shows or hides the History & Snippets panel, without animating the editor's relayout.
    func setInspectorVisible(_ visible: Bool) {
        guard showInspector != visible else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { showInspector = visible }
    }

    enum InspectorPane: String, CaseIterable {
        case history = "History"
        case snippets = "Snippets"
        /// Project commands (Artisan, console, Composer scripts, driver commands).
        case commands = "Commands"
        /// The schema explorer (#21): tables and columns of the tab's SQL connection.
        case database = "Database"
    }

    /// Project snippets (`.runlet/snippets/*.php`) per project root; see `projectSnippets(for:)`.
    let projectSnippetCache = ProjectSnippetCache()
    /// A parameterised snippet waiting for its values in a sheet (#14; AppModel+SnippetInputs).
    var snippetInputRequest: SnippetInputRequest?
    /// The file Save as Artisan Command… or Save as Test… just wrote (#39; AppModel+Promotion).
    var promotedFile: PromotedFile?

    @ObservationIgnored let engine: ExecutionEngine
    /// Saved database connections' passwords (#138): the Keychain, or memory for Debug runs on
    /// scratch data. The engine reads it when a run starts; the app writes and deletes items.
    @ObservationIgnored let credentials: CredentialStore
    /// Posts notifications for long runs (#26; AppModel+RunNotifications).
    @ObservationIgnored let runNotifier: any RunNotificationPosting = AppModel.makeRunNotifier()
    /// macOS's notification permission, as last read (Settings ▸ General ▸ Notifications); nil
    /// until read.
    var notificationAuthorization: RunNotificationAuthorization?
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
    /// The launch's `refreshEnvironment()`: a run started before it finishes waits for it.
    @ObservationIgnored private var firstEnvironmentRefresh: Task<Void, Never>?

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
        // One entry per code and target; files from earlier versions may hold repeats.
        history = HistoryLog.collapsingDuplicates(loadedHistory.value)

        let bundle = (try? RunnerBundle(contentsOf: resources.runner)) ?? RunnerBundle(source: Data())
        docker = DockerCLI.locate(override: loadedSettings.value.dockerExecutable)
        credentials = Self.makeCredentialStore(paths: paths)
        engine = ExecutionEngine(bundle: bundle, docker: docker, ssh: Self.makeSSHClient(), credentials: credentials)
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
        firstEnvironmentRefresh = Task { await self.refreshEnvironment() }
    }

    // MARK: Environment

    func refreshEnvironment() async {
        #if DEBUG
        // Development aid: a slower first discovery, to check what launch shows meanwhile (#91).
        if !hasDiscoveredPHP, let delay = ProcessInfo.processInfo.environment["RUNLET_DEBUG_DISCOVERY_DELAY"].flatMap(Double.init) {
            try? await Task.sleep(for: .seconds(delay))
        }
        #endif
        var discovered = await PHPDiscovery.discover()
        #if DEBUG
        // Development aid: behave as on a Mac without PHP (screenshots, testing #2's fallback).
        if ProcessInfo.processInfo.environment["RUNLET_DEBUG_HIDE_SYSTEM_PHP"] != nil { discovered = [] }
        #endif
        let store = runletPHP
        let own = await store.installed()
        // An older build (from an earlier Runlet) keeps working until the user updates.
        let older = own == nil ? await store.installedOlder() : nil
        if let own {
            runletPHPState = .installed(own)
            moveSettingsToRunletPHP(store)
        } else if let older {
            switch runletPHPState {
            case .downloading, .failed: break
            default: runletPHPState = .updateAvailable(older)
            }
        } else {
            switch runletPHPState {
            case .installed, .updateAvailable: runletPHPState = .notInstalled
            default: break
            }
        }
        phpInstallations = RunletPHPStore.merged(discovered: discovered, runlet: own ?? older)
        hasDiscoveredPHP = true
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
        // Without the PHP list it would pick Docker or report no PHP; the first
        // refreshEnvironment() checks once discovery has finished (#91).
        guard hasDiscoveredPHP else { return }
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

    /// Offer Runlet's PHP: discovery finished and found no usable PHP, a download exists for
    /// this Mac, and it isn't installed (the offer stays up while downloading, to show the
    /// progress).
    var shouldOfferRunletPHP: Bool {
        let isInstalled: Bool
        switch runletPHPState {
        case .notInstalled, .failed, .downloading: isInstalled = false
        case .installed, .updateAvailable: isInstalled = true
        }
        return runletPHP.shouldOffer(discoveryFinished: hasDiscoveredPHP, installations: phpInstallations, isInstalled: isInstalled)
    }

    /// Waits for the launch's PHP discovery, so a run started meanwhile doesn't fail with
    /// "no PHP" (#91).
    func waitForFirstDiscovery() async {
        if !hasDiscoveredPHP { await firstEnvironmentRefresh?.value }
    }

    /// The default PHP and projects' PHP that point at another build of Runlet's PHP move to
    /// the installed one: after an update, or when Runlet quit between installing and moving.
    private func moveSettingsToRunletPHP(_ store: RunletPHPStore) {
        if let path = store.replacement(forPHPPath: settings.defaultPHPExecutable) { settings.defaultPHPExecutable = path }
        for project in library.localProjects {
            guard let path = store.replacement(forPHPPath: project.phpExecutable) else { continue }
            var moved = project
            moved.phpExecutable = path
            saveProject(moved)
        }
    }

    /// Downloads, verifies, and installs Runlet's PHP, then rescans so the sandbox and local
    /// projects can use it. Only ever called from an explicit click.
    func downloadRunletPHP() {
        if case .downloading = runletPHPState { return }
        runletPHPState = .downloading(nil)
        let store = runletPHP
        Task {
            do {
                let installed = try await store.install { fraction in
                    Task { @MainActor in
                        if case .downloading = self.runletPHPState { self.runletPHPState = .downloading(fraction) }
                    }
                }
                runletPHPState = .installed(installed)
                await refreshEnvironment()
            } catch {
                runletPHPState = .failed("\(error)")
            }
        }
    }

    /// Deletes Runlet's PHP, every build of it (a project or the default that pointed at it
    /// falls back to the automatic choice), and rescans.
    func removeRunletPHP() {
        let store = runletPHP
        try? store.remove()
        let isRunletPHP = { (path: String?) in path.flatMap(store.releaseIdentifier(ofBinary:)) != nil }
        if isRunletPHP(settings.defaultPHPExecutable) { settings.defaultPHPExecutable = nil }
        for project in library.localProjects where isRunletPHP(project.phpExecutable) {
            var cleared = project
            cleared.phpExecutable = nil
            saveProject(cleared)
        }
        runletPHPState = .notInstalled
        Task { await refreshEnvironment() }
    }

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
    var driverVariables: [String: [String: String]] = [:]
    /// What runs asked to remember per target (TargetRef.stableKey) until Runlet quits: the
    /// chosen driver, a WordPress site URL, … Sent back with each run as `RunRequest.hints`;
    /// dropped when a run fails while booting, so the next run detects everything again.
    @ObservationIgnored var sessionHints: [String: [String: String]] = [:]

    /// What runs revealed about each target (PHP version, framework/driver), for tab cards.
    nonisolated struct TargetFacts: Equatable, Codable, Sendable {
        var phpVersion: String?
        var framework: String?
        var frameworkVersion: String?
        var driverName: String?
        var lastStatus: RunStatus?
        /// True once a real run reported these values (more exact than file detection).
        var fromRun: Bool?
        /// Profiler extensions of the target's PHP, from its last run or probe (Profile Run).
        var profilers: PHPProfilers?
        /// The environment the application reported on its last run (#12); nil when it had none.
        var appEnvironment: String?
        /// Environment notices the user dismissed for this target (#12), so they don't return.
        var dismissedEnvironmentNotices: Set<AppEnvironmentNotice.Kind>?
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

    /// Lets `detectFacts(for:)` read a target's files again (after its settings changed).
    func resetFactsDetection(for key: String) {
        factsDetectedThisSession.remove(key)
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
                // Production containers aren't touched on their own: facts come from the
                // local source only, or from runs.
                if profile.environment == .production {
                    if let source = profile.localSourcePath, !source.isEmpty, FileManager.default.fileExists(atPath: source) {
                        let root = URL(fileURLWithPath: source)
                        detected = await Task.detached { TargetInspector.staticFacts(projectRoot: root) }.value
                    }
                    break
                }
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
            case .ssh:
                // Never connects: facts come from the local folder on this Mac (runs and Test
                // Connection add the server's PHP version).
                if let folder = library.localFolder(for: target), FileManager.default.fileExists(atPath: folder) {
                    let root = URL(fileURLWithPath: folder)
                    detected = await Task.detached { TargetInspector.staticFacts(projectRoot: root) }.value
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
            facts.profilers = info.profilers ?? facts.profilers
        case .bootstrapped(let info):
            facts.framework = info.framework
            facts.frameworkVersion = info.frameworkVersion
            facts.driverName = info.driverName
            facts.appEnvironment = AppEnvironment.normalized(info.environment)
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
        case .docker, .ssh:
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
    /// SwiftUI's openWindow for single-instance windows by scene id (the Docker profile manager).
    @ObservationIgnored var openSingleWindowAction: ((String) -> Void)?
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

    /// Opens a PHP file, a `.runlet` workspace, or a folder (as a project); during launch,
    /// waits until the UI is up so confirmations never race SwiftUI's first window.
    func open(_ url: URL) {
        guard hasPresentedWindow else {
            if !pendingOpenURLs.contains(url) { pendingOpenURLs.append(url) }
            return
        }
        if url.pathExtension.lowercased() == WorkspaceDocument.fileExtension {
            openWorkspace(url)
        } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            openFolder(url)
        } else {
            openFile(url)
        }
    }

    /// Called by the first window once it is on screen.
    func windowPresented() {
        guard !hasPresentedWindow else { return }
        hasPresentedWindow = true
        // Restored file-backed tabs: compare with their files, then follow them.
        syncFileWatchers()
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
            tab.setAutoRunEnabled(false)
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
        tab.onEditorEdit = { [weak self, weak tab] in
            guard let self, let tab else { return }
            tab.scheduleAutoRun { [weak self] editedTab in
                self?.run(editedTab, automatically: true)
            }
        }
        tab.onChange = { [weak self, weak window, weak tab] change in
            if change == .content { window?.markEdited() }
            self?.scheduleSessionSave()
            // The parameters drawer (#168) follows an SQL tab's text and caret.
            if let tab, tab.language == .sql { self?.scheduleSQLParameterRefresh(for: tab) }
        }
        tab.onEditorEscape = { [weak self, weak tab] in
            guard let self, let tab else { return false }
            return self.editorEscapePressed(in: tab)
        }
        if let index { window.tabs.insert(tab, at: index) } else { window.tabs.append(tab) }
    }

    /// Adds a tab to `window` (default: the active window).
    @discardableResult
    func newTab(target: TargetRef? = nil, code: String = "", title: String? = nil, select: Bool = true, in window: WindowModel? = nil, language: TabLanguage = .php, sqlConnection: String? = nil, sqlSavedConnection: UUID? = nil, sqlSavedConnectionName: String? = nil) -> TabModel {
        let window = window ?? activeWindow ?? makeWindow()
        let target = target ?? validTarget(settings.defaultTarget)
        let tab = TabModel(state: TabState(title: title ?? nextTabTitle(in: window), code: code, target: target, language: language, sqlConnection: sqlConnection, sqlSavedConnection: sqlSavedConnection, sqlSavedConnectionName: sqlSavedConnectionName))
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
        case .ssh(let id): return library.sshProfile(id) != nil ? target : .sandbox
        }
    }

    func closeTab(_ id: UUID) {
        guard let window = window(containing: id), let index = window.index(of: id) else { return }
        let tab = window.tabs[index]
        tab.setAutoRunEnabled(false)
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
        let copy = newTab(target: tab.target, code: tab.editorIfLoaded?.text ?? tab.code, title: tab.title + " copy", in: window, language: tab.language, sqlConnection: tab.sqlConnection, sqlSavedConnection: tab.sqlSavedConnection, sqlSavedConnectionName: tab.sqlSavedConnectionName)
        copy.sqlTransaction = tab.sqlTransaction
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
        case .ssh(let id):
            return library.sshProfile(id).map { "\($0.name) (SSH)" } ?? "Missing SSH profile"
        }
    }

    func targetSymbol(_ target: TargetRef) -> String {
        switch target {
        case .sandbox: "shippingbox"
        case .local: "folder"
        case .docker: "cube.box"
        case .ssh: "server.rack"
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
        case .ssh(let id): touchSSHProfile(id)
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
        targetEdited(.local(project.id))
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
        removeDatabaseConnections(for: .local(id))
        saveLibrary()
        for tab in allTabs where tab.target == .local(id) { setTarget(.sandbox, for: tab) }
    }

    func saveDockerProfile(_ profile: DockerProfile) {
        factsDetectedThisSession.remove(TargetRef.docker(profile.id).stableKey)
        targetEdited(.docker(profile.id))
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
        removeDatabaseConnections(for: .docker(id))
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
    func confirmContainer(_ container: ContainerInfo, for choice: ContainerChoice) {
        switch choice.target {
        case .docker(let id):
            if let profile = library.dockerProfile(id) { confirmContainer(container, for: profile) }
        case .ssh(let id):
            confirmRemoteContainer(container, for: id)
        default:
            containerChoice = nil
        }
    }

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
            await waitForFirstDiscovery()
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
            if project.phpExecutable == nil, settings.defaultPHPExecutable == nil { await waitForFirstDiscovery() }
            guard let php = project.phpExecutable ?? settings.defaultPHPExecutable ?? bestPHP?.path else {
                throw TargetResolutionError(description: "No PHP executable was found. Download Runlet's PHP or choose one in Settings ▸ PHP, or set one in the project's options.")
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

        case .ssh(let id):
            return try await sshSnapshot(for: tab, profileId: id)
        }
    }

    // MARK: Running

    /// Runs the tab (or its selection). `profile` makes it a Profile Run: the same run, with
    /// the snippet sampled by Excimer for a flame graph. With Format before run on (#36), an
    /// explicit run of a whole PHP tab formats it first (`formatted` marks that second pass).
    func run(_ tab: TabModel, selectionOnly: Bool = false, automatically: Bool = false, profile: Bool = false, formatted: Bool = false) {
        tab.cancelPendingAutoRun()
        // SQL tabs (#35) run one statement, never automatically and never profiled.
        if tab.language == .sql {
            if !automatically { runSQL(tab, selectionOnly: selectionOnly) }
            return
        }
        if automatically {
            guard tab.autoRunEnabled, tab.target == .sandbox, window(containing: tab.id) != nil else { return }
        }
        // While Format before run waits for the formatter, another Run does nothing.
        guard !tab.isRunning, !tab.isFormatting else { return }
        let editor = tab.editor
        let range = editor.selectedRange
        let useSelection = !automatically && (selectionOnly || (settings.runPrefersSelection && range.length > 0))
        if !formatted, shouldFormatBeforeRun(tab, automatically: automatically, useSelection: useSelection) {
            // A syntax error is left to the run to report; other problems show above the editor.
            Task { [weak self, weak tab] in
                guard let self, let tab else { return }
                await self.format(tab, reportSyntaxErrors: false)
                self.run(tab, selectionOnly: selectionOnly, profile: profile, formatted: true)
            }
            return
        }
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
        // Production targets ask first (⌘↩ confirms), unless the user granted a grace.
        let target = tab.target
        guardProduction(.run, target: target, text: code, isSelection: selection != nil, in: window(containing: tab.id)) { [weak self, weak tab] in
            guard let self, let tab, tab.target == target else { return }
            self.startRun(tab, code: code, selection: selection, automatically: automatically, profile: profile ? RunProfileOptions() : nil)
        }
    }

    /// Follows one run from outside the tab (MCP runs report their output to the client).
    struct RunObserver {
        /// The run's request, once the target is resolved and the run launched.
        var started: (RunRequest) -> Void = { _ in }
        var event: (RunEvent.Kind) -> Void = { _ in }
        /// The run couldn't start (target, PHP, or launch problem).
        var failed: (String) -> Void = { _ in }
        /// Always called last.
        var ended: () -> Void = {}
    }

    /// Starts a run whose code and selection were captured (and confirmed, for production).
    func startRun(_ tab: TabModel, code: String, selection: SourceSelection?, automatically: Bool = false, profile: RunProfileOptions? = nil, observer: RunObserver? = nil, sql: SQLRunInfo? = nil) {
        tab.cancelPendingAutoRun()
        guard !tab.isRunning else {
            observer?.failed("The tab is already running.")
            observer?.ended()
            return
        }
        // An SQL tab's text is never run as PHP (MCP run_php, …); only its own Run sends SQL (#35).
        guard sql != nil || tab.language == .php else {
            observer?.failed("This is an SQL tab; only its Run button runs its statements.")
            observer?.ended()
            return
        }
        let documentVersion = tab.documentVersion
        let target = tab.target
        // #26: a long run that ends in the background notifies; timed from here (after any
        // production confirmation or AI client approval), including preparing the target.
        let startedAt = ContinuousClock.now
        let notificationKind: RunNotificationKind = sql != nil ? .sql : profile != nil ? .profile : .run
        // #12: how the target is marked as the run starts, kept with its history entry; for
        // a saved connection, the stricter of its marking and the target's (#139).
        let marking = library.marking(for: target, connection: sql?.saved)
        // An SQL tab's generated PHP (#35) needs neither strict types nor magic comments.
        let strictTypes = sql == nil && self.strictTypes(for: target)
        let inspector = inspectorOptions(for: target)
        // Magic comments (#10): read when Run is pressed, for the whole run. Profile Run measures
        // the code as written, so its flame graph never includes probes.
        let magicComments = settings.magicComments && profile == nil && sql == nil
        // Output (#82): read when Run is pressed too; a run started in At once mode stays so.
        // An SQL tab's output shows what runs where while it runs (#162).
        let sqlActivity = sql.map { info in
            (info.explain.map { "\($0.title) " } ?? "") + (info.transaction != nil ? "\(info.statements.count) statement\(info.statements.count == 1 ? "" : "s") " : "") + "on " + info.connectionLabel
        }
        tab.beginRun(code: code, selection: selection, magicComments: magicComments, delivery: settings.outputDelivery, sql: sql != nil, sqlActivity: sqlActivity, sqlRun: sql)
        // #60: a run shows the tab's output pane under Hide the output pane until a run.
        updateOutputPane(.runStarted, for: tab)
        let preparationID = tab.preparationID

        Task {
            defer { observer?.ended() }
            // #30: recheck opt-in/ownership before and after asynchronous preparation.
            @MainActor func automaticRunIsValid() -> Bool {
                !automatically || (tab.autoRunEnabled && tab.target == .sandbox &&
                    tab.documentVersion == documentVersion && tab.preparationID == preparationID &&
                    tab.runState == .preparing &&
                    self.window(containing: tab.id) != nil)
            }
            guard automaticRunIsValid() else {
                if tab.preparationID == preparationID { tab.cancelPreparing() }
                return
            }
            let snapshot: TargetSnapshot
            do {
                // #142: a saved connection that opens from this Mac runs there, not on the target.
                snapshot = try await self.sqlSnapshot(for: tab, saved: sql?.saved)
            } catch {
                if automatically && tab.preparationID != preparationID { return }
                tab.failBeforeLaunch("\(error)")
                observer?.failed("\(error)")
                runEnded(tab, target: target, kind: notificationKind, outcome: .couldNotStart, startedAt: startedAt, automatic: automatically)
                return
            }
            guard automaticRunIsValid(), !automatically || snapshot.targetId == "sandbox" else {
                if tab.preparationID == preparationID { tab.cancelPreparing() }
                return
            }
            // The snapshot is fixed now; later edits or target changes cannot redirect this run.
            var request = RunRequest(tabId: tab.id, documentVersion: documentVersion, target: snapshot, code: code, selection: selection, strictTypes: strictTypes, inspector: inspector, profile: profile, magicComments: magicComments)
            // A saved connection (#138): the request carries its definition; the engine adds
            // the password to the script on stdin. Such a run boots no project code, so it gets
            // no hints and teaches Runlet nothing about the target.
            let savedConnection = sql?.saved
            request.sqlConnection = savedConnection
            request.hints = savedConnection == nil ? sessionHints[target.stableKey] ?? [:] : [:]
            let stream: AsyncStream<RunEvent>
            do {
                stream = try await engine.start(request)
            } catch {
                if automatically && tab.preparationID != preparationID { return }
                tab.failBeforeLaunch("\(error)")
                observer?.failed("\(error)")
                runEnded(tab, target: target, kind: notificationKind, outcome: .couldNotStart, startedAt: startedAt, automatic: automatically)
                return
            }
            // Stop/close/edit can arrive during the engine actor hop as well.
            if automatically && !automaticRunIsValid() {
                _ = await engine.cancel(runId: request.runId)
                if tab.preparationID == preparationID { tab.cancelPreparing() }
                return
            }
            tab.started(request)
            if let sql { tab.note(sql.note) }
            observer?.started(request)
            var finished: FinishedInfo?
            var appEnvironment: String?
            // Events are taken in batches (#82): a run printing thousands of lines updates the
            // tab a few times a second, and less often while the output is slow to draw. The tab
            // holds output until the end in At once mode; the observer (MCP) and what Runlet
            // learns about the target get every event, in order.
            let feed = RunEventFeed(stream)
            var pacer = OutputPacer()
            while let next = await feed.next(notBefore: pacer.nextDeadline) {
                pacer.received(readyAt: next.readyAt)
                let batch = next.events
                tab.apply(batch)
                for event in batch {
                    observer?.event(event.kind)
                    if case .finished(let info) = event.kind { finished = info }
                    if let sql, savedConnection != nil {
                        if case .sqlSchema(let schema) = event.kind { learnSQLSchema(schema, for: target, connection: sql.ref) }
                        continue
                    }
                    if case .bootstrapped(let info) = event.kind {
                        if let variables = info.variables { learnDriverVariables(variables, for: target) }
                        appEnvironment = AppEnvironment.normalized(info.environment)
                    }
                    if case .remember(let key, let value) = event.kind {
                        sessionHints[target.stableKey, default: [:]][key] = value
                    }
                    if case .sql(let result) = event.kind { learnSQLConnections(result, for: target) }
                    if case .sqlPlan(let plan) = event.kind { learnSQLConnections(SQLResultInfo(connections: plan.connections), for: target) }
                    if case .sqlSchema(let schema) = event.kind { learnSQLSchema(schema, for: target, connection: sql?.ref ?? .app(schema.connection)) }
                    if case .error(let error) = event.kind, error.stage == .bootstrap || error.stage == .launch {
                        sessionHints[target.stableKey] = nil
                    }
                    learnFacts(from: event.kind, for: target)
                }
                pacer.applied()
            }
            tab.endOfEvents()
            if let finished {
                // SQL runs keep the statement, not the PHP that ran it (#35); the entry keeps the
                // target's marking and the application's reported environment (#12).
                recordHistory(HistoryEntry(runId: request.runId, code: sql?.historyCode ?? code, target: target, targetLabel: snapshot.label, status: finished.status, reason: finished.reason, elapsedMs: finished.elapsedMs, language: sql == nil ? .php : .sql, targetEnvironment: marking.environment, targetColor: marking.color, appEnvironment: appEnvironment, connection: sql?.historyConnection))
            }
            // A run may have opened (or found closed) the host's shared connection.
            if case .ssh(let id) = target, snapshot.kind == .ssh, let finished { sshRunFinished(id, status: finished.status, reason: finished.reason) }
            if let finished {
                runEnded(tab, target: target, kind: notificationKind, outcome: RunNotificationOutcome(finished), startedAt: startedAt, runnerElapsedMs: finished.elapsedMs, automatic: automatically)
            }
        }
    }

    func stop(_ tab: TabModel) {
        tab.cancelPendingAutoRun()
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

    /// Records a finished run. Running code that is already in history (same target) moves
    /// that entry to the top with this run's status instead of adding a copy.
    func recordHistory(_ entry: HistoryEntry) {
        history = HistoryLog.recording(entry, into: history, limit: settings.historyLimit)
        scheduleHistorySave()
    }

    /// Loads code from history without running it. An SQL entry brings its connection (#149).
    func restore(_ entry: HistoryEntry, inNewTab: Bool) {
        let language = entry.language ?? .php
        if inNewTab {
            let tab = newTab(target: validTarget(entry.target), code: entry.code, title: "History", language: language)
            applyLibraryConnection(entry.connection, to: tab, from: .historyEntry)
        } else if let tab = selectedTab {
            setLanguage(language, for: tab)
            tab.replaceCode(entry.code)
            applyLibraryConnection(entry.connection, to: tab, from: .historyEntry)
        }
    }

    /// Opens library code (a history entry or snippet) where Settings ▸ General ▸ History &
    /// Snippets says: used for double-click and Return in those panes. Only loads code.
    /// - Parameter target: the entry's target; nil for snippets saved for any target.
    /// - Parameter connection: an SQL entry's or snippet's connection (#149), which the tab
    ///   switches to (`applyLibraryConnection`).
    func openLibraryCode(_ code: String, target: TargetRef?, title: String, language: TabLanguage = .php, connection: SQLConnectionReference? = nil, from source: LibraryConnectionSource = .historyEntry) {
        let target = target.map(validTarget)
        if let tab = selectedTab {
            switch settings.libraryOpenBehavior {
            case .newTab:
                break
            case .reuseBlankTab:
                if tab.isBlankScratch, target == nil || tab.target == target {
                    setLanguage(language, for: tab)
                    tab.replaceCode(code)
                    applyLibraryConnection(connection, to: tab, from: source)
                    // An automatic "Tab 3" title says nothing; name it like a new tab would be.
                    if tab.title.range(of: #"^Tab \d+$"#, options: .regularExpression) != nil {
                        tab.title = title
                        scheduleSessionSave()
                    }
                    return
                }
            case .currentTab:
                if !tab.isRunning {
                    if let target, tab.target != target { setTarget(target, for: tab) }
                    setLanguage(language, for: tab)
                    tab.replaceCode(code)
                    applyLibraryConnection(connection, to: tab, from: source)
                    return
                }
            }
        }
        let tab = newTab(target: target, code: code, title: title, language: language)
        applyLibraryConnection(connection, to: tab, from: source)
    }

    func open(_ entry: HistoryEntry) {
        openLibraryCode(entry.code, target: entry.target, title: "History", language: entry.language ?? .php, connection: entry.connection)
    }

    /// SQL snippets (#130) open as SQL tabs, like SQL history entries, on their connection (#149).
    func open(_ snippet: Snippet) {
        askForInputs(of: snippet) { [weak self] code in
            self?.openLibraryCode(code, target: snippet.target, title: snippet.label, language: snippet.tabLanguage, connection: snippet.connection, from: .snippet)
        }
    }

    func open(_ snippet: ProjectSnippet, target: TargetRef) {
        askForInputs(of: snippet, target: target) { [weak self] code in
            self?.openLibraryCode(code, target: target, title: snippet.label, language: snippet.language, connection: snippet.connection, from: .snippet)
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

    /// - Parameter language: SQL for code from an SQL tab or SQL history (#130).
    /// - Parameter connection: the connection an SQL snippet opens on (#149); kept by name.
    @discardableResult
    func saveSnippet(label: String, code: String, target: TargetRef?, description: String? = nil, language: TabLanguage = .php, connection: SQLConnectionReference? = nil) -> Snippet {
        let snippet = Snippet(label: label.isEmpty ? "Untitled snippet" : label, code: code, description: normalizedSnippetDescription(description), target: target, targetLabel: target.map(targetLabel), language: language, connection: connection)
        snippets.insert(snippet, at: 0)
        saveSnippets()
        return snippet
    }

    private func normalizedSnippetDescription(_ description: String?) -> String? {
        guard let value = description?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    func updateSnippet(_ snippet: Snippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        var updated = snippet
        updated.description = normalizedSnippetDescription(updated.description)
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
    /// The tab takes the snippet's language (#130).
    func open(_ snippet: Snippet, inNewTab: Bool) {
        let tab = selectedTab
        guard inNewTab || tab != nil else { return }
        askForInputs(of: snippet, action: inNewTab ? "Open in New Tab" : "Open in Current Tab") { [weak self] code in
            guard let self else { return }
            if inNewTab {
                let opened = self.newTab(target: snippet.target.map(self.validTarget), code: code, title: snippet.label, language: snippet.tabLanguage)
                self.applyLibraryConnection(snippet.connection, to: opened, from: .snippet)
            } else if let tab {
                self.setLanguage(snippet.tabLanguage, for: tab)
                tab.replaceCode(code)
                self.applyLibraryConnection(snippet.connection, to: tab, from: .snippet)
            }
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
        case .ssh:
            return library.localFolder(for: target).map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
    }

    /// The project or profile name shown with a target's project snippets.
    func projectName(for target: TargetRef) -> String? {
        switch target {
        case .sandbox: nil
        case .local(let id): library.localProject(id)?.name
        case .docker(let id): library.dockerProfile(id)?.name
        case .ssh(let id): library.sshProfile(id)?.name
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

    /// Writes `.runlet/snippets/<slug>.php` (`.sql` for SQL, #130) in the target's project.
    /// Throws `ProjectSnippets.SaveError.fileExists` instead of replacing a file unless `overwrite`.
    @discardableResult
    func saveProjectSnippet(label: String, description: String?, code: String, target: TargetRef, overwrite: Bool = false, language: TabLanguage = .php, connection: SQLConnectionReference? = nil) throws -> URL {
        guard let root = projectRoot(for: target) else {
            throw TargetResolutionError(description: "This target has no project folder for shared snippets.")
        }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        // #149: an SQL snippet's connection becomes its `-- @connection` line.
        let url = try ProjectSnippets.save(label: trimmed.isEmpty ? "Untitled snippet" : trimmed, description: description, code: code, projectRoot: root, overwrite: overwrite, language: language, connection: connection)
        projectSnippetCache.reload(root: root)
        return url
    }

    /// Opens a project snippet without running it. A new tab uses `target`, the project the
    /// snippet belongs to; the current tab keeps its target.
    func open(_ snippet: ProjectSnippet, target: TargetRef, inNewTab: Bool) {
        let tab = selectedTab
        guard inNewTab || tab != nil else { return }
        askForInputs(of: snippet, target: target, action: inNewTab ? "Open in New Tab" : "Open in Current Tab") { [weak self] code in
            guard let self else { return }
            if inNewTab {
                let opened = self.newTab(target: self.validTarget(target), code: code, title: snippet.label, language: snippet.language)
                self.applyLibraryConnection(snippet.connection, to: opened, from: .snippet)
            } else if let tab {
                self.setLanguage(snippet.language, for: tab)
                tab.replaceCode(code)
                self.applyLibraryConnection(snippet.connection, to: tab, from: .snippet)
            }
        }
    }

    /// Copies a project snippet into personal snippets, associated with `target`. Its
    /// `@input` declarations come along in a docblock (#14).
    @discardableResult
    func copyToPersonalSnippets(_ snippet: ProjectSnippet, target: TargetRef) -> Snippet {
        saveSnippet(label: snippet.label, code: snippet.personalCode, target: target, description: snippet.description, language: snippet.language, connection: snippet.connection)
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
                file: tab.fileURL.map { WorkspaceTargets.storedPath($0.path, relativeTo: base) },
                language: tab.language,
                sqlConnection: tab.language == .sql ? tab.sqlConnection : nil,
                // A saved connection (#138) by name only: never its definition or password.
                sqlSavedConnection: tab.language == .sql ? savedConnectionName(for: tab) : nil
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
                if let profile = made.sshProfile { library.sshProfiles.append(profile) }
                created[item.target] = made.ref
                resolved[item.index] = made.ref
            }
            saveLibrary()
        }

        let window = WindowModel()
        windows.append(window)
        for (index, tab) in document.tabs.enumerated() {
            let target = resolved[index] ?? .sandbox
            let saved = tab.sqlSavedConnection.flatMap { library.databaseConnection(id: nil, name: $0, on: target) }
            let model = TabModel(state: TabState(title: tab.title, code: tab.code, target: target, language: tab.language ?? .php, sqlConnection: tab.sqlConnection,
                                                 sqlSavedConnection: saved?.id, sqlSavedConnectionName: tab.sqlSavedConnection))
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
        case .ssh(let definition):
            let destination = (definition.user.map { "\($0)@" } ?? "") + definition.host
            let container = definition.container.map { " · container \($0.step.identity.displayName)" } ?? ""
            return " — \(destination):\(definition.remoteDirectory)\(container)" + (definition.environment == .production ? " (production)" : "")
        }
    }

    // MARK: Files

    /// Opens a file in a tab (or selects the tab that has it) and returns that tab; nil when it
    /// can't be read (an alert says why).
    @discardableResult
    func openFile(_ url: URL) -> TabModel? {
        let standardized = url.standardizedFileURL
        if let existing = allTabs.first(where: { $0.fileURL?.standardizedFileURL == standardized }), let window = window(containing: existing.id) {
            window.selectedTabId = existing.id
            activeWindowId = window.id
            return existing
        }
        do {
            let code = try String(contentsOf: url, encoding: .utf8)
            // `.sql` files open as SQL tabs (#35); opening never runs them.
            let tab = newTab(code: code, title: url.lastPathComponent, language: TabLanguage.forFile(url))
            tab.fileURL = url
            tab.isFileDirty = false
            noteFileSynced(tab, text: code)
            scheduleSessionSave()
            return tab
        } catch {
            alert = AppAlert(title: "Could not open \(url.lastPathComponent)", message: error.localizedDescription)
            return nil
        }
    }

    /// Writes the tab's code to disk. Saving never executes code, and ⌘S asks before
    /// replacing a file another app changed (`confirmSaveOverDiskChanges`).
    func save(_ tab: TabModel, to url: URL? = nil) -> Bool {
        guard let destination = url ?? tab.fileURL else { return false }
        if destination == tab.fileURL, !confirmSaveOverDiskChanges(tab) { return false }
        do {
            let text = tab.editorIfLoaded?.text ?? tab.code
            try text.write(to: destination, atomically: true, encoding: .utf8)
            tab.markSaved(to: destination)
            noteFileSynced(tab, text: text)
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
        case .ssh(let id):
            guard let profile = library.sshProfile(id) else { return nil }
            if let folder = library.localFolder(for: target) {
                return LanguageWorkspace(kind: .project, rootPath: folder, phpVersion: profile.languagePHPVersion)
            }
            return LanguageWorkspace(kind: .basic, rootPath: languageService.basicWorkspaceRoot.path, phpVersion: profile.languagePHPVersion)
        }
    }

    func bindLanguage(_ tab: TabModel) {
        detectFacts(for: tab.target)
        // SQL completion (#128): keywords always; tables and columns from the loaded schema.
        tab.sqlCompletionProvider = { [weak self, weak tab] text, caret in
            guard let self, let tab, tab.language == .sql else { return nil }
            return SQLCompletion.suggestions(in: text, caret: caret, schema: self.sqlSchemaState(for: tab)?.schema)
        }
        // SQL tabs (#35) have no PHP language server: no PHP diagnostics or completion.
        guard tab.language == .php else {
            unbindLanguage(tab)
            tab.languageNotes = []
            return
        }
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
        // Tabs opened, closed, or restored since: watch exactly the open files (FileSync.swift).
        if !isTerminating { syncFileWatchers() }
    }

    private func saveHistory() { persist { try historyStore.save(history) } }
    private func saveSettings() { persist { try settingsStore.save(settings) } }

    /// Sets the whole app's appearance from the setting (#135), at launch and whenever it
    /// changes. SwiftUI windows also get `preferredColorScheme`; AppKit panels and popups (the
    /// palette, completion, hover, and signature help) follow `NSApp.appearance`, so a Dark
    /// choice on a light Mac gives dark popups too. System clears it to follow the Mac again.
    func applyAppearance() {
        NSApp?.appearance = settings.appearance.nsAppearance
    }
    func saveLibrary() { persist { try libraryStore.save(library) } }
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
        for tab in allTabs { tab.setAutoRunEnabled(false) }
        flush()
        // Windows close after this point; keep their tabs in the saved session.
        isTerminating = true
        stopMCPServer()
        await engine.cancelAll()
        async let ssh: Void = closeAutomaticSSHConnections()
        async let language: Void? = languageService?.stopAll()
        _ = await (ssh, language)
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
    /// The Mago formatter behind Format Code (#36).
    var mago: URL

    static var main: AppResources {
        let bundle = Bundle.main
        let resources = bundle.resourceURL ?? URL(fileURLWithPath: ".")
        return AppResources(
            runner: resources.appendingPathComponent("Runner/runlet-runner.php"),
            sandboxTemplate: resources.appendingPathComponent("Sandbox/laravel", isDirectory: true),
            phpantom: bundle.bundleURL.appendingPathComponent("Contents/Helpers/phpantom_lsp"),
            mago: bundle.bundleURL.appendingPathComponent("Contents/Helpers/mago")
        )
    }
}

/// Runlet's own PHP in the UI.
enum RunletPHPState: Equatable {
    case notInstalled
    /// Fraction downloaded, nil while unknown.
    case downloading(Double?)
    case installed(PHPInstallation)
    /// An older build is installed (and used); this Runlet installs a newer one on request.
    case updateAvailable(PHPInstallation)
    case failed(String)
}
