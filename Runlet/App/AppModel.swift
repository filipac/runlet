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
    var tabs: [TabModel] = []
    var selectedTabId: UUID?

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
    }

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

        // Restore tabs (code and targets only — nothing runs).
        for state in loadedSession.value.tabs { addTab(TabModel(state: state)) }
        if tabs.isEmpty { newTab() }
        selectedTabId = loadedSession.value.selectedTabId.flatMap { id in tabs.contains { $0.id == id } ? id : nil } ?? tabs.first?.id

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
        for tab in tabs { bindLanguage(tab) }
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

    // MARK: Tabs

    var selectedTab: TabModel? { tabs.first { $0.id == selectedTabId } }

    private func addTab(_ tab: TabModel, at index: Int? = nil) {
        tab.onChange = { [weak self] in self?.scheduleSessionSave() }
        if let index { tabs.insert(tab, at: index) } else { tabs.append(tab) }
    }

    @discardableResult
    func newTab(target: TargetRef? = nil, code: String = "", title: String? = nil, select: Bool = true) -> TabModel {
        let target = target ?? validTarget(settings.defaultTarget)
        let tab = TabModel(state: TabState(title: title ?? nextTabTitle(), code: code, target: target))
        let index = selectedTab.flatMap { selected in tabs.firstIndex { $0 === selected } }.map { $0 + 1 }
        addTab(tab, at: index)
        if select { selectedTabId = tab.id }
        bindLanguage(tab)
        scheduleSessionSave()
        return tab
    }

    private func nextTabTitle() -> String {
        var number = tabs.count + 1
        while tabs.contains(where: { $0.title == "Tab \(number)" }) { number += 1 }
        return "Tab \(number)"
    }

    private func validTarget(_ target: TargetRef) -> TargetRef {
        switch target {
        case .sandbox: return .sandbox
        case .local(let id): return library.localProject(id) != nil ? target : .sandbox
        case .docker(let id): return library.dockerProfile(id) != nil ? target : .sandbox
        }
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        if tab.isRunning { stop(tab) }
        unbindLanguage(tab)
        tabs.remove(at: index)
        if tabs.isEmpty { newTab() }
        if selectedTabId == id { selectedTabId = tabs[min(index, tabs.count - 1)].id }
        scheduleSessionSave()
    }

    func closeOtherTabs(_ id: UUID) {
        for tab in tabs where tab.id != id { closeTab(tab.id) }
    }

    func duplicateTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        newTab(target: tab.target, code: tab.editorIfLoaded?.text ?? tab.code, title: tab.title + " copy")
    }

    func renameTab(_ id: UUID, to title: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { tab.title = trimmed }
        scheduleSessionSave()
    }

    func selectTab(offset: Int) {
        guard let current = tabs.firstIndex(where: { $0.id == selectedTabId }), !tabs.isEmpty else { return }
        selectedTabId = tabs[(current + offset + tabs.count) % tabs.count].id
    }

    func moveTab(_ id: UUID, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: max(0, min(index, tabs.count)))
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
        var updated = project
        if let index = library.localProjects.firstIndex(where: { $0.id == project.id }) {
            updated.revision = library.localProjects[index].revision + 1
            library.localProjects[index] = updated
        } else {
            library.localProjects.append(updated)
        }
        saveLibrary()
        for tab in tabs where tab.target == .local(project.id) { bindLanguage(tab) }
    }

    func removeProject(_ id: UUID) {
        library.localProjects.removeAll { $0.id == id }
        saveLibrary()
        for tab in tabs where tab.target == .local(id) { setTarget(.sandbox, for: tab) }
    }

    func saveDockerProfile(_ profile: DockerProfile) {
        var updated = profile
        if let index = library.dockerProfiles.firstIndex(where: { $0.id == profile.id }) {
            updated.revision = library.dockerProfiles[index].revision + 1
            library.dockerProfiles[index] = updated
        } else {
            library.dockerProfiles.append(updated)
        }
        saveLibrary()
        for tab in tabs where tab.target == .docker(profile.id) { bindLanguage(tab) }
    }

    func removeDockerProfile(_ id: UUID) {
        library.dockerProfiles.removeAll { $0.id == id }
        saveLibrary()
        for tab in tabs where tab.target == .docker(id) { setTarget(.sandbox, for: tab) }
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
                for tab in tabs where tab.target == .docker(id) {
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
        for tab in tabs where tab.target == .docker(profile.id) { tab.targetIssue = nil }
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
                throw TargetResolutionError(description: "No compatible local PHP was found, so the sandbox runs in Docker. Download the \(image) image first (Sandbox ▸ Download Docker Image).")
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
            let request = RunRequest(tabId: tab.id, documentVersion: documentVersion, target: snapshot, code: code, selection: selection)
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

    // MARK: Files

    func openFile(_ url: URL) {
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
            editor.bindLanguage(session: session, uri: LanguageService.scratchURI(root: workspace.rootURL, documentId: tab.id))
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
        for tab in tabs {
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
        persist { try sessionStore.save(SessionState(tabs: tabs.map(\.state), selectedTabId: selectedTabId)) }
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
        await engine.cancelAll()
        await languageService?.stopAll()
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
