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
    /// The row whose Logs popover is open.
    var logsPopover: DriverTabRowKey?
    /// The filter chosen per list (for this launch); none chosen: the tab's default.
    var filterSelection: [String: String] = [:]
    /// Targets (keys) whose commands are being listed again because their driver changed.
    var reloading: Set<String> = []
    /// Targets whose driver changed, but which only list when the user asks (production,
    /// SSH hosts): the tab offers Reload.
    var reloadOffers: Set<String> = []
    /// Why reading a changed driver's tabs failed, per target.
    var reloadErrors: [String: String] = [:]
    /// The fingerprint a reload failed for, per target: only Refresh tries it again.
    @ObservationIgnored var failedReloads: [String: String] = [:]
    /// Lists to refresh again when their current refresh ends (their declaration changed).
    @ObservationIgnored var refreshAgain: Set<String> = []
    @ObservationIgnored var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var refreshWork: [String: DispatchWorkItem] = [:]
    /// How long each list's last refresh took (a command on this Mac, or the runner).
    @ObservationIgnored var durations: [String: Duration] = [:]

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

    /// Remembers a fresh listing's `inspectorTabs()`, with the `.runlet` folder's fingerprint
    /// taken when the listing started. When the declaration changed, the shown tab follows it in
    /// place: its rows are listed again, and a tab the driver removed falls back to History.
    func rememberDriverInspectorTabs(_ catalog: ProjectCommandCatalog, for target: TargetRef, fingerprint: String?) {
        let key = target.stableKey
        let before = driverInspectorTabMemory.tabs[key]
        if driverInspectorTabMemory.remember(catalog, for: key, fingerprint: fingerprint) { scheduleFactsSave() }
        guard catalog.inspectorTabsDeclared else {
            driverTabsReloadEnded(for: target, error: catalog.errors.first?.message ?? "The driver's tabs weren't reported.", fingerprint: fingerprint)
            return
        }
        driverTabs.reloading.remove(key)
        driverTabs.reloadErrors[key] = nil
        driverTabs.failedReloads[key] = nil
        driverTabs.reloadOffers.remove(key)
        guard before != catalog.inspectorTabs, selectedTab?.target == target, let id = driverInspectorTab else { return }
        if let tab = catalog.inspectorTabs.first(where: { $0.id == id }) {
            refreshDriverTab(tab, target: target, automatic: true, checkDriver: false)
        } else {
            inspectorPane = .history
        }
    }

    /// The `.runlet` folder's fingerprint on this Mac (the project's, or a Docker or SSH
    /// profile's local folder); nil when the target has none.
    func driverFolderFingerprint(for target: TargetRef) -> String? {
        hostDirectory(for: target).flatMap { DriverFolderFingerprint.compute(at: URL(fileURLWithPath: $0).appendingPathComponent(".runlet")) }
    }

    /// A listing that didn't reach the driver ended: when it was a reload of a changed driver,
    /// the tabs keep their declaration and show why.
    func driverTabsReloadEnded(for target: TargetRef, error: String?, fingerprint: String?) {
        let key = target.stableKey
        guard driverTabs.reloading.remove(key) != nil else { return }
        guard let error else { return }
        driverTabs.reloadErrors[key] = "Runlet couldn't read the changed driver's tabs, so they are as before: " + error
        driverTabs.failedReloads[key] = fingerprint
    }

    /// Compares the driver folder with the one the tabs were declared from and, when it
    /// changed, lists the project's commands again in the background (the rows are listed
    /// meanwhile with the current declaration, and again if it changes). Production targets and
    /// SSH hosts never list by themselves: the tab offers Reload instead.
    func checkDriverInspectorTabs(for target: TargetRef, explicit: Bool) {
        let key = target.stableKey
        let store = driverTabs
        guard !store.reloading.contains(key), !commandsState(for: target).isLoading else { return }
        let current = driverFolderFingerprint(for: target)
        switch driverInspectorTabMemory.reload(for: key, current: current, listsAutomatically: listsCommandsAutomatically(for: target), failed: store.failedReloads[key], explicit: explicit) {
        case .upToDate:
            store.reloadOffers.remove(key)
        case .offer:
            store.reloadOffers.insert(key)
        case .reload:
            store.reloadOffers.remove(key)
            reloadDriverInspectorTabs(for: target)
        }
    }

    /// Lists the target's commands again to read its driver's changed tabs. `confirm` (the
    /// offer's Reload button) asks first on production, like Load.
    func reloadDriverInspectorTabs(for target: TargetRef, confirm: Bool = false) {
        let key = target.stableKey
        guard !commandsState(for: target).isLoading else { return }
        let tab = allTabs.first { $0.target == target } ?? TabModel(state: TabState(title: "", target: target))
        let start = { [weak self] in
            guard let self else { return }
            self.driverTabs.reloading.insert(key)
            self.driverTabs.reloadOffers.remove(key)
            self.driverTabs.reloadErrors[key] = nil
            self.startLoadingCommands(for: tab)
        }
        guard confirm else { return start() }
        guardProduction(.listCommands, target: target, text: "List the commands of \(targetLabel(target)) to read its driver's changed inspector tabs (boots the application)", in: window(containing: tab.id), perform: start)
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

    /// Lists the tab: its command on this Mac, in the project's folder, or its PHP callable,
    /// which boots the project like App Info. `automatic` (the pane appeared, a row was started
    /// or stopped) skips production targets, which list only on Refresh and ask first (like host
    /// commands, or like App Info for a callable), and, for a callable, SSH hosts (like the
    /// Commands panel).
    func refreshDriverTab(_ tab: DriverInspectorTab, target: TargetRef, window: WindowModel? = nil, automatic: Bool = false, checkDriver: Bool = true) {
        let key = DriverTabRowKey.listKey(target: target.stableKey, tab: tab.id)
        // Has the driver changed since the tabs were declared? (Never blocks the rows.)
        if checkDriver { checkDriverInspectorTabs(for: target, explicit: !automatic) }
        guard !(driverTabs.lists[key]?.isLoading ?? false) else {
            // A new declaration while the rows load: list them again once they're in.
            if !checkDriver { driverTabs.refreshAgain.insert(key) }
            return
        }
        switch tab.list {
        case .host(let command):
            if automatic, isProduction(target) { return }
            guardProduction(.command, target: target, text: command, runsOnThisMac: true, in: window) { [weak self] in
                self?.startListingDriverTab(tab, target: target)
            }
        case .driver:
            if automatic, !listsCommandsAutomatically(for: target) { return }
            guardProduction(.driverTab, target: target, text: "List \(tab.title) of \(targetLabel(target)) (boots the application and calls its driver's list)", in: window) { [weak self] in
                self?.startListingDriverTab(tab, target: target)
            }
        }
    }

    private func startListingDriverTab(_ tab: DriverInspectorTab, target: TargetRef) {
        let store = driverTabs
        let key = DriverTabRowKey.listKey(target: target.stableKey, tab: tab.id)
        let previous = store.lists[key]?.listing
        let started = ContinuousClock.now
        if case .driver = tab.list {
            store.lists[key] = .loading(previous: previous)
            store.tasks[key] = Task {
                defer {
                    store.tasks[key] = nil
                    store.durations[key] = ContinuousClock.now - started
                    self.refreshAgainIfNeeded(tab.id, target: target)
                }
                do {
                    // Any tab on the target resolves it the same way (the container, the host).
                    let editorTab = self.allTabs.first { $0.target == target } ?? TabModel(state: TabState(title: "", target: target))
                    let snapshot = try await self.snapshot(for: editorTab)
                    switch try await self.engine.listDriverInspectorTab(tab.id, title: tab.title, target: snapshot) {
                    case .listed(let listing): store.lists[key] = .loaded(listing)
                    case .failed(let message, let output): store.lists[key] = .failed(message: message, output: output, previous: previous)
                    }
                } catch is CancellationError {
                    store.lists[key] = previous.map { .loaded($0) } ?? .idle
                } catch {
                    store.lists[key] = .failed(message: "Could not list \(tab.title): \(error)", output: nil, previous: previous)
                }
            }
            return
        }
        guard let directory = hostDirectory(for: target) else {
            store.lists[key] = .failed(message: Self.noHostFolderMessage(tab), output: nil, previous: previous)
            return
        }
        store.lists[key] = .loading(previous: previous)
        store.tasks[key] = Task {
            defer {
                store.tasks[key] = nil
                store.durations[key] = ContinuousClock.now - started
                self.refreshAgainIfNeeded(tab.id, target: target)
            }
            let environment = await HostShellEnvironment.shared.environment()
            switch await DriverInspectorTabCommands.list(tab, directory: directory, environment: environment) {
            case .listed(let listing):
                store.lists[key] = .loaded(listing)
            case .failed(let message, let output):
                store.lists[key] = .failed(message: message, output: output, previous: previous)
            }
        }
    }

    /// Lists a tab again, with its current declaration, when that changed while it listed.
    private func refreshAgainIfNeeded(_ id: String, target: TargetRef) {
        guard driverTabs.refreshAgain.remove(DriverTabRowKey.listKey(target: target.stableKey, tab: id)) != nil,
              let tab = driverInspectorTabs(for: target).first(where: { $0.id == id }) else { return }
        refreshDriverTab(tab, target: target, automatic: true, checkDriver: false)
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

    /// The rows a tab shows: the listed items its filter includes, then rows whose run command
    /// still runs although the filter or the list leaves them out (the list no longer has them:
    /// nothing pending). Filtering is local: it never lists again.
    func driverTabRows(_ tab: DriverInspectorTab, target: TargetRef) -> [DriverInspectorTabListing.Item] {
        let listed = driverTabListState(tab, target: target).listing?.items ?? []
        let active = driverTabs.runs.filter { $0.key.target == target.stableKey && $0.key.tab == tab.id && driverTabRowState($0.key).isActive }
        var items = tab.visibleItems(listed, filter: driverTabFilter(tab, target: target), active: Set(active.keys.map(\.row)))
        let ids = Set(listed.map(\.id))
        let extra = active.filter { !ids.contains($0.key.row) }.sorted { $0.value.startedAt < $1.value.startedAt }
        items += extra.map { DriverInspectorTabListing.Item(id: $0.key.row, title: $0.value.rowTitle, subtitle: "Nothing pending") }
        return items
    }

    /// The tab's chosen filter on `target`, else its default; nil when it has none.
    func driverTabFilter(_ tab: DriverInspectorTab, target: TargetRef) -> DriverInspectorTab.Filter? {
        tab.filter(driverTabs.filterSelection[DriverTabRowKey.listKey(target: target.stableKey, tab: tab.id)])
    }

    func setDriverTabFilter(_ id: String, of tab: DriverInspectorTab, target: TargetRef) {
        driverTabs.filterSelection[DriverTabRowKey.listKey(target: target.stableKey, tab: tab.id)] = id
    }

    /// How many listed rows each filter includes (nil before the first list).
    func driverTabFilterCounts(_ tab: DriverInspectorTab, target: TargetRef) -> [String: Int]? {
        guard let items = driverTabListState(tab, target: target).listing?.items else { return nil }
        return Dictionary(uniqueKeysWithValues: tab.filters.map { filter in (filter.id, items.filter(filter.includes).count) })
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

    /// Logs: a popover on the row with a read-only, live view of its terminal tab.
    func showDriverTabRowLogs(_ key: DriverTabRowKey) {
        guard driverTabSession(key) != nil else { return }
        driverTabs.logsPopover = key
    }

    /// Open in Terminal (in the Logs popover): closes the popover and shows the row's terminal
    /// tab in the panel, selected and focused, as an ordinary interactive tab.
    func promoteDriverTabRowLogs(_ key: DriverTabRowKey) {
        guard let (session, window) = driverTabSession(key) else { return }
        // Take the view back from the popover first, so the panel hosts and focuses it.
        if session.isBorrowed, let peek = session.view.superview as? PeekContainerView { peek.giveBack() }
        if driverTabs.logsPopover == key { driverTabs.logsPopover = nil }
        showTerminal(session.id, in: window)
    }

    /// Run Again in the terminal panel started a row's command anew: the row follows it.
    func driverTabTerminalReplaced(_ old: UUID, with new: UUID) {
        guard let key = driverTabs.runs.first(where: { $0.value.sessionId == old })?.key else { return }
        driverTabs.runs[key]?.sessionId = new
        driverTabs.runs[key]?.startedAt = Date()
        driverTabs.runs[key]?.pausedAt = nil
    }
}
