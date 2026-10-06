import AppKit
import Observation
import RunletCore
import RunletExecution

/// The list of one driver tab on one target.
enum DriverTabListState: Equatable {
    /// Not listed yet (production targets list only on Refresh).
    case idle
    case loading(previous: DriverInspectorTabListing?)
    case loaded(DriverInspectorTabListing)
    /// The list command failed or printed no list: the message, the end of its stderr (or the
    /// start of its output), and the last good list.
    case failed(message: String, output: String?, previous: DriverInspectorTabListing?)

    var listing: DriverInspectorTabListing? {
        switch self {
        case .idle: nil
        case .loading(let previous), .failed(_, _, let previous): previous
        case .loaded(let listing): listing
        }
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

/// One row of a driver tab on one target: what its run command is tracked by.
struct DriverTabRowKey: Hashable {
    var target: String
    var tab: String
    var row: String

    var listKey: String { DriverTabRowKey.listKey(target: target, tab: tab) }

    static func listKey(target: String, tab: String) -> String { target + "\u{1F}" + tab }
}

/// A row's run command, started in a terminal tab of a window.
struct DriverTabRun: Equatable {
    var windowId: UUID
    var sessionId: UUID
    var rowTitle: String
    var commandLine: String
    var startedAt: Date
    /// Set when Pause asked it to stop.
    var pausedAt: Date?
}

/// What a row shows about its run command.
enum DriverTabRowState: Equatable {
    /// Not started since Runlet launched.
    case idle
    case running(since: Date)
    /// Pause sent Ctrl-C and waits for it to end.
    case pausing
    /// Paused, or its terminal tab was closed.
    case stopped
    /// Ended by itself, with its exit code (nil when unknown).
    case exited(Int32?)
    case failed(String)

    /// Running, or still stopping: Play is not offered.
    var isActive: Bool {
        switch self {
        case .running, .pausing: true
        default: false
        }
    }
}

/// Drivers' inspector tabs for the app's lifetime: each tab's list per target, and the rows'
/// run commands (terminal tabs, so they end with their window or when Runlet quits).
@MainActor
@Observable
final class DriverTabsStore {
    var lists: [String: DriverTabListState] = [:]
    var runs: [DriverTabRowKey: DriverTabRun] = [:]
    /// Rows whose run command is being prepared (the shell environment is resolved first).
    var starting: Set<DriverTabRowKey> = []
    var pausing: Set<DriverTabRowKey> = []
    /// A message from starting a row (no folder on this Mac), per list.
    var notices: [String: String] = [:]
    @ObservationIgnored var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var refreshWork: [String: DispatchWorkItem] = [:]

    private static var stores: [ObjectIdentifier: DriverTabsStore] = [:]

    static func shared(for model: AppModel) -> DriverTabsStore {
        let key = ObjectIdentifier(model)
        if let store = stores[key] { return store }
        let store = DriverTabsStore()
        stores[key] = store
        return store
    }
}

extension AppModel {
    var driverTabs: DriverTabsStore { DriverTabsStore.shared(for: self) }

    // MARK: Declarations

    /// The tabs the target's driver adds to the inspector: from its loaded command list, else
    /// the last ones it declared (kept across launches). Never loads anything.
    func driverInspectorTabs(for target: TargetRef) -> [DriverInspectorTab] {
        driverInspectorTabMemory.tabs(for: target.stableKey, loaded: commands(for: target))
    }

    /// Whether Runlet knows which tabs the target's driver declares.
    func knowsDriverInspectorTabs(for target: TargetRef) -> Bool {
        driverInspectorTabMemory.knows(target.stableKey, loaded: commands(for: target))
    }

    /// Whether the inspector offers to load the driver's tabs: the project has a `.runlet`
    /// driver whose tabs Runlet doesn't know yet.
    func offersDriverInspectorTabsLoad(for target: TargetRef) -> Bool {
        !knowsDriverInspectorTabs(for: target) && hasProjectDriver(for: target)
    }

    /// The driver tab the inspector shows for `target`, if one is chosen and declared.
    func shownDriverInspectorTab(for target: TargetRef?) -> DriverInspectorTab? {
        guard let id = driverInspectorTab, let target else { return nil }
        return driverInspectorTabs(for: target).first { $0.id == id }
    }

    /// Remembers a fresh listing's `inspectorTabs()`.
    func rememberDriverInspectorTabs(_ catalog: ProjectCommandCatalog, for target: TargetRef) {
        if driverInspectorTabMemory.remember(catalog, for: target.stableKey) { scheduleFactsSave() }
    }

    /// Lists the target's commands to learn its driver's tabs, which boots the project like the
    /// Commands panel does (production asks first). An explicit action, like Load the Driver's
    /// Log Paths.
    func loadDriverInspectorTabs(for tab: TabModel) {
        let target = tab.target
        guard !commandsState(for: target).isLoading else { return }
        guardProduction(.listCommands, target: target, text: "List the commands of \(targetLabel(target)) to find its driver's inspector tabs (boots the application)", in: window(containing: tab.id)) { [weak self, weak tab] in
            guard let self, let tab, tab.target == target else { return }
            self.startLoadingCommands(for: tab)
        }
    }

    // MARK: Lists

    func driverTabListState(_ tab: DriverInspectorTab, target: TargetRef) -> DriverTabListState {
        driverTabs.lists[DriverTabRowKey.listKey(target: target.stableKey, tab: tab.id)] ?? .idle
    }

    /// Runs the tab's list command on this Mac, in the project's folder. `automatic` (the pane
    /// appeared, a row was started or stopped) skips production targets, which list only on
    /// Refresh and ask first, like host commands.
    func refreshDriverTab(_ tab: DriverInspectorTab, target: TargetRef, window: WindowModel? = nil, automatic: Bool = false) {
        let key = DriverTabRowKey.listKey(target: target.stableKey, tab: tab.id)
        guard !(driverTabs.lists[key]?.isLoading ?? false) else { return }
        if automatic, isProduction(target) { return }
        guardProduction(.command, target: target, text: tab.listCommand, runsOnThisMac: true, in: window) { [weak self] in
            self?.startListingDriverTab(tab, target: target)
        }
    }

    private func startListingDriverTab(_ tab: DriverInspectorTab, target: TargetRef) {
        let store = driverTabs
        let key = DriverTabRowKey.listKey(target: target.stableKey, tab: tab.id)
        let previous = store.lists[key]?.listing
        guard let directory = hostDirectory(for: target) else {
            store.lists[key] = .failed(message: Self.noHostFolderMessage(tab), output: nil, previous: previous)
            return
        }
        store.lists[key] = .loading(previous: previous)
        store.tasks[key] = Task {
            defer { store.tasks[key] = nil }
            let environment = await HostShellEnvironment.shared.environment()
            switch await DriverInspectorTabCommands.list(tab, directory: directory, environment: environment) {
            case .listed(let listing):
                store.lists[key] = .loaded(listing)
            case .failed(let message, let output):
                store.lists[key] = .failed(message: message, output: output, previous: previous)
            }
        }
    }

    /// Lists the tab again a moment after a row started or stopped, so its counts follow.
    private func scheduleDriverTabRefresh(_ tab: DriverInspectorTab, target: TargetRef) {
        let key = DriverTabRowKey.listKey(target: target.stableKey, tab: tab.id)
        driverTabs.refreshWork[key]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.driverTabs.refreshWork[key] = nil
            self?.refreshDriverTab(tab, target: target, automatic: true)
        }
        driverTabs.refreshWork[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private static func noHostFolderMessage(_ tab: DriverInspectorTab) -> String {
        "\(tab.title) runs its commands on this Mac in the project's folder, and this target has none. For a Docker or SSH profile, set its local folder in Settings ▸ Targets."
    }

    // MARK: Rows

    /// The rows a tab shows: the listed items, then rows whose run command still runs although
    /// the list no longer has them (nothing pending).
    func driverTabRows(_ tab: DriverInspectorTab, target: TargetRef) -> [DriverInspectorTabListing.Item] {
        var items = driverTabListState(tab, target: target).listing?.items ?? []
        let listed = Set(items.map(\.id))
        let extra = driverTabs.runs
            .filter { $0.key.target == target.stableKey && $0.key.tab == tab.id && !listed.contains($0.key.row) && driverTabRowState($0.key).isActive }
            .sorted { $0.value.startedAt < $1.value.startedAt }
        items += extra.map { DriverInspectorTabListing.Item(id: $0.key.row, title: $0.value.rowTitle, subtitle: "Nothing pending") }
        return items
    }

    /// The terminal tab a run uses, and its window, while both exist.
    func driverTabSession(_ key: DriverTabRowKey) -> (session: TerminalSession, window: WindowModel)? {
        guard let run = driverTabs.runs[key], let window = windows.first(where: { $0.id == run.windowId }),
              let session = window.terminals.sessions.first(where: { $0.id == run.sessionId }) else { return nil }
        return (session, window)
    }

    /// Follows the run's terminal tab: whatever ends it (Pause, the command itself, closing the
    /// tab or its window), the row shows it.
    func driverTabRowState(_ key: DriverTabRowKey) -> DriverTabRowState {
        guard let run = driverTabs.runs[key] else { return .idle }
        guard let (session, _) = driverTabSession(key) else { return .stopped }
        switch session.state {
        case .starting, .running:
            return driverTabs.pausing.contains(key) ? .pausing : .running(since: run.startedAt)
        case .exited(let code):
            return run.pausedAt != nil ? .stopped : .exited(code)
        case .failed(let message):
            return .failed(message)
        }
    }

    /// Play: the tab's run command for the row, in a new terminal tab of `window` that isn't
    /// shown or focused (Logs shows it). It runs on this Mac in the project's folder, with the
    /// user's shell environment, like the list command and host commands, until Pause or until
    /// its terminal tab ends. Production targets ask first.
    func playDriverTabRow(_ item: DriverInspectorTabListing.Item, of tab: DriverInspectorTab, for editorTab: TabModel, in window: WindowModel? = nil) {
        let target = editorTab.target
        let key = DriverTabRowKey(target: target.stableKey, tab: tab.id, row: item.id)
        guard !driverTabRowState(key).isActive, !driverTabs.starting.contains(key) else { return }
        let line = DriverInspectorTabCommands.runCommandLine(tab.runCommand, id: item.id)
        let window = window ?? self.window(containing: editorTab.id) ?? activeWindow
        guardProduction(.command, target: target, text: line, runsOnThisMac: true, in: window) { [weak self] in
            guard let self, let window else { return }
            self.startDriverTabRow(key, title: item.title, commandLine: line, tab: tab, target: target, window: window)
        }
    }

    private func startDriverTabRow(_ key: DriverTabRowKey, title: String, commandLine: String, tab: DriverInspectorTab, target: TargetRef, window: WindowModel) {
        let store = driverTabs
        guard let directory = hostDirectory(for: target) else {
            store.notices[key.listKey] = Self.noHostFolderMessage(tab)
            return
        }
        store.starting.insert(key)
        Task {
            let environment = await HostShellEnvironment.shared.environment()
            store.starting.remove(key)
            // The window may have closed meanwhile; its terminals are gone.
            guard self.windows.contains(where: { $0.id == window.id }), !self.driverTabRowState(key).isActive else { return }
            let request = TerminalRequest(title: "\(tab.title): \(title)", workingDirectory: directory, executable: ["/bin/sh", "-c", commandLine], isCommand: true, environment: environment)
            // A finished run of this row in the same window makes room for the new one.
            let previous = store.runs[key].flatMap { $0.windowId == window.id ? $0.sessionId : nil }
            let session = self.startBackgroundTerminal(request, in: window, replacing: previous)
            store.runs[key] = DriverTabRun(windowId: window.id, sessionId: session.id, rowTitle: title, commandLine: commandLine, startedAt: Date())
            store.notices[key.listKey] = nil
            self.scheduleDriverTabRefresh(tab, target: target)
        }
    }

    /// Pause: Ctrl-C through the terminal, then up to 5 s for the command to end; one that is
    /// still running then is ended like closing its terminal tab (the tab stays, so Logs still
    /// shows its output).
    func pauseDriverTabRow(_ key: DriverTabRowKey, of tab: DriverInspectorTab, target: TargetRef) {
        let store = driverTabs
        guard store.runs[key] != nil, !store.pausing.contains(key), let (session, _) = driverTabSession(key), session.isRunning else { return }
        store.runs[key]?.pausedAt = Date()
        store.pausing.insert(key)
        if !session.interrupt() { session.terminate() }
        Task {
            let deadline = Date().addingTimeInterval(5)
            while session.isRunning, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if session.isRunning {
                session.terminate()
                session.view.feed(text: "\r\n\u{1b}[2m— Ended by Runlet: still running 5 s after Ctrl-C —\u{1b}[0m\r\n")
            }
            store.pausing.remove(key)
            self.scheduleDriverTabRefresh(tab, target: target)
        }
    }

    /// Logs: the terminal panel with the row's terminal tab selected and focused.
    func showDriverTabRowLogs(_ key: DriverTabRowKey) {
        guard let (session, window) = driverTabSession(key) else { return }
        showTerminal(session.id, in: window)
    }
}
