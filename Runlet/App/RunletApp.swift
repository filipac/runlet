import AppKit
import RunletCore
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

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

        // Library ▸ Manage Profiles…: one window for every saved Docker and SSH profile.
        Window("Profiles", id: ProfileManager.sceneId) {
            ProfileManager()
                .environment(model)
                .preferredColorScheme(model.settings.appearance.colorScheme)
        }
        .defaultSize(width: 1080, height: 700)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        // Opened from the Library menu, the target menu, and Settings ▸ Targets instead.
        .commandsRemoved()

        // Window ▸ Connections (#180): everything Runlet has open now, with a Close per row. One
        // window, opened from the status bar, the Window menu, and Open Anything. Never restored.
        Window("Connections", id: ConnectionManagerView.sceneId) {
            ConnectionManagerView()
                .environment(model)
                .preferredColorScheme(model.settings.appearance.colorScheme)
        }
        .defaultSize(width: 760, height: 560)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .commandsRemoved()

        // View ▸ Logs (#20): a target's logs, parsed, filtered, and followed. One window; its
        // follows stop when it closes. Never restored.
        Window("Logs", id: AppModel.logViewerSceneId) {
            LogViewerView()
                .environment(model)
                .preferredColorScheme(model.settings.appearance.colorScheme)
        }
        .defaultSize(width: 1040, height: 640)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .commandsRemoved()

        // A result's table in its own window (#21): search, filters, sorting, CSV. Never restored.
        WindowGroup("Result", id: "result", for: UUID.self) { $id in
            ResultWindowView(id: id)
                .environment(model)
                .preferredColorScheme(model.settings.appearance.colorScheme)
        }
        .defaultSize(width: 1000, height: 640)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .commandsRemoved()

        // Show Relations (#153): a table's foreign key diagram in its own window. Never restored.
        WindowGroup("Relations", id: "relations", for: UUID.self) { $id in
            RelationsWindowView(id: id)
                .environment(model)
                .preferredColorScheme(model.settings.appearance.colorScheme)
        }
        .defaultSize(width: 1100, height: 720)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
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

    /// The whole app's appearance (`NSApp.appearance`); nil follows the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?

    /// Standard Mac behavior: closing the last window keeps Runlet running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Recent projects in the Dock icon's menu.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        DockMenu.make(model: Self.model)
    }

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

    /// Clicks on run notifications (#26). The center keeps its delegate weakly.
    private static let runNotificationResponder = RunNotificationResponder()

    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // The saved appearance applies before the first window opens (#135).
            Self.model?.applyAppearance()
            // Set before launch finishes, so a click that launched Runlet still reaches the tab
            // (#26). A Debug build that only logs notifications leaves macOS's notification
            // center alone.
            if Self.model?.runNotifier is SystemRunNotifier {
                UNUserNotificationCenter.current().delegate = Self.runNotificationResponder
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `Runlet file.php …` from a terminal opens the files (never runs them).
        let files = CommandLine.arguments.dropFirst().filter { argument in
            let lower = argument.lowercased()
            return !argument.hasPrefix("-") && (lower.hasSuffix(".php") || lower.hasSuffix(".runlet") || lower.hasSuffix(".sql"))
        }
        MainActor.assumeIsolated {
            for path in files {
                Self.open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            }
            // The `runlet` tool: requests while running, or the one it launched Runlet with.
            CommandLineRequests.start()
            // `runlet mcp` (AI clients), when Settings ▸ AI Clients allows it.
            Self.model?.startMCPServerIfEnabled()
            // #232: the guided tour on a first launch, What's New on a new version or build.
            WhatsNew.presentIfNeeded(model: Self.model)
            // ⌥⌘, or ⌥ while Settings opens reveals Settings ▸ Advanced (#187).
            AdvancedSettingsTrigger.install { AppDelegate.model }
            // In-app updates (#233): the "launched" marker, what the last update left, and the
            // automatic checks (never in Debug builds, self-tests, or `runlet mcp` launches).
            if let model = Self.model { model.updater.start(model: model) }
            // #25: the Quick Run panel's global shortcut, when Settings ▸ Shortcuts turned it on.
            Self.model?.applyQuickRunHotKey()
        }
        // A launch that opens documents (Finder or CLI) skips SwiftUI's initial window;
        // ask SwiftUI's own app delegate to present it.
        DispatchQueue.main.async {
            #if DEBUG
            // A step run launched hidden (`open -j`, the screenshot scripts) has its window, just
            // not visible: a second one would take the steps and the keyboard (#295).
            if ProcessInfo.processInfo.environment["RUNLET_DEBUG_STEPS"] != nil, NSApp.isHidden { return }
            #endif
            Self.ensureMainWindow()
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: nil) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { Self.handOffKeyStatus(from: window) }
        }
        #if DEBUG
        MainActor.assumeIsolated {
            Self.runDebugInspectorCheck()
            PaletteDebugCheck.runIfRequested(model: Self.model)
        }
        #endif
    }

    #if DEBUG
    /// Development aid: replays UI steps at launch so layout bugs reproduce without UI
    /// scripting. Use with RUNLET_DATA_DIR pointing at scratch data (and RUNLET_SNAPSHOT_DIR
    /// for `snapshot`). RUNLET_DEBUG_STEPS is a comma-separated list, run 1.5 s apart after
    /// a 2 s start delay:
    /// `inspector:history|snippets|commands|off`, `tabs:vertical|horizontal`, `snapshot`,
    /// `wait`, `settings` (open Settings), `profiles[:<name>]` (open the Profiles window, on that saved profile),
    /// `ssh:new` or `ssh:<profile name>` (the SSH profile sheet), `connect:<profile name>` and
    /// `disconnect:<profile name>`, `select:<tab title>`, `run` (the selected tab; use only
    /// with test targets such as the runlet-fixtures SSH host and `RUNLET_SSH_CONFIG`, or the
    /// test fixtures), `project:<dir>` (open a local project in the current tab), `code:<file>`
    /// (load a file's code into the current tab), `section:<name>` (show an output section
    /// such as Queries; empty for the output), `intercept:on|off` (Intercept Mail),
    /// `confirm`/`confirm:grace`/`cancel` (a pending production confirmation),
    /// `mcp-wait[:<seconds>]` (waits for an AI client's approval sheet; see DebugSteps for the
    /// other `mcp` steps), `wait-run[:<seconds>]` (waits for the selected tab's run to end and
    /// prints its timings: see `DebugRunTiming`),
    /// `close` (close the key window), `activate` (bring Runlet to the front), and `report`
    /// (print activation and key/main windows). `DebugSteps` adds keys, commands, files, and
    /// `state`. The app prints "RUNLET_DEBUG_STEPS: done" to stderr and quits after the last
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
            case "activate":
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            case "settings":
                // The app menu's Settings… item (⌘,): what the user's shortcut triggers.
                if let menu = NSApp.mainMenu?.items.first?.submenu,
                   let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
                    menu.performActionForItem(at: index)
                }
            case "profiles":
                // `profiles:<name>` opens the Profiles window on that saved Docker or SSH profile.
                if let docker = model.library.dockerProfiles.first(where: { $0.name == argument }) {
                    model.showProfileManager(selecting: .docker(docker.id))
                } else if let ssh = model.library.sshProfiles.first(where: { $0.name == argument }) {
                    model.showProfileManager(selecting: .ssh(ssh.id))
                } else {
                    model.showDockerProfileManager()
                }
            case "ssh":
                // `ssh:new` opens New SSH Profile; `ssh:<name>` edits that saved profile.
                if let profile = model.library.sshProfiles.first(where: { $0.name == argument }) {
                    NotificationCenter.default.post(name: .editSSHProfileRequested, object: profile.id)
                } else {
                    NotificationCenter.default.post(name: .newSSHProfileRequested, object: nil)
                }
            case "connect", "disconnect":
                if let profile = model.library.sshProfiles.first(where: { $0.name == argument }) {
                    if parts[0] == "connect" { model.connectSSH(profile.id) } else { model.disconnectSSH(profile.id) }
                }
            case "select":
                if let window = model.activeWindow, let tab = window.tabs.first(where: { $0.title == argument }) {
                    window.selectedTabId = tab.id
                }
            case "run":
                if let tab = model.selectedTab {
                    DebugRunTiming.start(tab)
                    model.run(tab)
                }
            case "wait-run":
                // `wait-run[:<seconds>]` holds the steps until the selected tab's run ends (at
                // most 120 s by default), then prints its timings (DebugRunTiming).
                if let tab = model.selectedTab, tab.isRunning, DebugRunTiming.sinceStart < (Double(argument) ?? 120) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { run(index) }
                    return
                }
                DebugRunTiming.report(model.selectedTab)
            case "inspector-wait":
                // `inspector-wait[:<seconds>]` (#320) holds the steps until the visible inspector
                // pane's list is taller than its visible area (at most 30 s by default).
                if !InspectorScrollDebugSteps.listIsLong(model), InspectorScrollDebugSteps.waited < (Double(argument) ?? 30) {
                    InspectorScrollDebugSteps.waited += 0.1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { run(index) }
                    return
                }
                FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: inspector-wait: \(InspectorScrollDebugSteps.listIsLong(model) ? "long" : "timed out") after \(InspectorScrollDebugSteps.waited)s\n".utf8))
                InspectorScrollDebugSteps.waited = 0
            case "quick-run-wait":
                // `quick-run-wait[:<seconds>]` (#25) holds the steps until the Quick Run panel's run
                // ends (at most 120 s by default).
                if QuickRunDebugSteps.isRunning(model), QuickRunDebugSteps.waited < (Double(argument) ?? 120) {
                    QuickRunDebugSteps.waited += 0.1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { run(index) }
                    return
                }
                QuickRunDebugSteps.waited = 0
            case "wait-page":
                // `wait-page[:<seconds>]` holds the steps until the current tab's Load Next page
                // ends (#146; at most 120 s by default), then prints its timings and state.
                if let tab = model.selectedTab, tab.sqlPagers.values.contains(where: \.isLoading), DebugRunTiming.sinceStart < (Double(argument) ?? 120) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { run(index) }
                    return
                }
                DebugRunTiming.report(model.selectedTab)
                SQLPagingDebugSteps.report(model)
            case "csv-wait":
                // `csv-wait[:<seconds>]` holds the steps until Export Query to CSV or Import CSV
                // ends (#152; at most 60 s by default); `csv-wait:rows=<n>` until the export
                // wrote n rows.
                let rows = argument.hasPrefix("rows=") ? Int(argument.dropFirst(5)) : nil
                if SQLCSVDebugSteps.busy(model, rows: rows), SQLCSVDebugSteps.waited < (rows == nil ? Double(argument) ?? 60 : 60) {
                    SQLCSVDebugSteps.waited += 0.1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { run(index) }
                    return
                }
                SQLCSVDebugSteps.waited = 0
                SQLCSVDebugSteps.log(SQLCSVDebugSteps.state(model))
            case "browse-wait":
                // `browse-wait[:<seconds>]` holds the steps while the latest Browse Table window
                // reads a page or applies changes (#151; at most 60 s by default), then prints its state.
                if TableBrowserDebugSteps.isBusy, DebugSteps.dbWaited < (Double(argument) ?? 60) {
                    DebugSteps.dbWaited += 0.1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { run(index) }
                    return
                }
                DebugSteps.dbWaited = 0
                if let browser = ResultWindows.latestBrowser { FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(TableBrowserDebugSteps.state(browser))\n".utf8)) }
            case "db-wait":
                // `db-wait[:<seconds>]` holds the steps until the connection editor's Test
                // Connection ends (#138; at most 60 s by default), then prints its result.
                if DatabaseDebugSteps.isTesting(model), DebugSteps.dbWaited < (Double(argument) ?? 60) {
                    DebugSteps.dbWaited += 0.1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { run(index) }
                    return
                }
                DebugSteps.dbWaited = 0
                DatabaseDebugSteps.log("db-wait: \(DatabaseDebugSteps.state(model))")
            case "redis-wait":
                // `redis-wait[:<seconds>]` (#190): holds the steps until the Redis key browser,
                // server panel, Open Value, and Load More are idle (at most 60 s by default).
                if RedisDebugSteps.isBusy(model), RedisDebugSteps.waited < (Double(argument) ?? 60) {
                    RedisDebugSteps.waited += 0.1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { run(index) }
                    return
                }
                RedisDebugSteps.waited = 0
                RedisDebugSteps.log("redis-wait: \(RedisDebugSteps.state(model))")
            case "tableplus-wait":
                // `tableplus-wait[:<seconds>]` (#188): holds the steps until the Import from
                // TablePlus sheet shows its summary (at most 30 s by default).
                if let session = TablePlusImportSession.current, session.phase == .importing, TablePlusDebugSteps.waited < (Double(argument) ?? 30) {
                    TablePlusDebugSteps.waited += 0.1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { run(index) }
                    return
                }
                TablePlusDebugSteps.waited = 0
                _ = TablePlusDebugSteps.run("tableplus-state", "", model: model)
            case "nav-wait":
                // `nav-wait:ready|done|hints|folds[:<seconds>]` (#22): holds the steps until PHPantom is
                // ready for the tab, its last navigation request is answered, or inlay hints show.
                let what = argument.split(separator: ":").map(String.init)
                if !NavigationDebugSteps.reached(what.first ?? "done", model: model), NavigationDebugSteps.waited < (what.count > 1 ? Double(what[1]) ?? 30 : 30) {
                    NavigationDebugSteps.waited += 0.1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { run(index) }
                    return
                }
                NavigationDebugSteps.log("nav-wait \(argument): \(NavigationDebugSteps.reached(what.first ?? "done", model: model) ? "reached" : "timed out") after \(NavigationDebugSteps.waited)s")
                NavigationDebugSteps.waited = 0
            case "connections-wait":
                // `connections-wait:<kind>=<n>[:<seconds>]` (#180): holds the steps until the
                // Connection Manager lists that many rows of a kind (at most 30 s by default).
                let limit = argument.split(separator: ":").dropFirst().first.flatMap { Double($0) } ?? 30
                if !ConnectionDebugSteps.reached(argument, model: model), ConnectionDebugSteps.waited < limit {
                    ConnectionDebugSteps.waited += 0.25
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { run(index) }
                    return
                }
                ConnectionDebugSteps.waited = 0
                FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: connections-wait \(argument): \(ConnectionDebugSteps.reached(argument, model: model) ? "reached" : "timed out")\n".utf8))
            case "logs-wait":
                // `logs-wait:<entries>|following|idle|found[:<seconds>]` (#20): holds the steps until
                // the Logs window shows that many entries, or its follow is in that state.
                let limit = argument.split(separator: ":").dropFirst().first.flatMap { Double($0) } ?? 30
                if !LogDebugSteps.reached(argument, model: model), LogDebugSteps.waited < limit {
                    LogDebugSteps.waited += 0.25
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { run(index) }
                    return
                }
                LogDebugSteps.waited = 0
                LogDebugSteps.log("logs-wait \(argument): \(LogDebugSteps.reached(argument, model: model) ? "reached" : "timed out")")
            case "update-wait":
                // `update-wait:<phase>[:<seconds>]` (#233): holds the steps until the updater's phase
                // (at most 60 s by default); see UpdateDebugSteps.
                let limit = argument.split(separator: ":").dropFirst().first.flatMap { Double($0) } ?? 60
                if !UpdateDebugSteps.reached(argument, model: model), UpdateDebugSteps.waited < limit {
                    UpdateDebugSteps.waited += 0.1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { run(index) }
                    return
                }
                UpdateDebugSteps.log("update-wait \(argument): \(UpdateDebugSteps.reached(argument, model: model) ? "reached" : "timed out") after \(UpdateDebugSteps.waited)s")
                UpdateDebugSteps.waited = 0
            case "confirm":
                // Confirms a pending production confirmation (`confirm:grace` ticks the
                // 10-minute box); `cancel` cancels it.
                if let pending = model.productionGuard.pending { model.confirmProduction(pending, grace: argument == "grace") }
            case "cancel":
                model.cancelProduction()
            case "close":
                NSApp.keyWindow?.performClose(nil)
            case "project":
                let project = model.openProject(at: URL(fileURLWithPath: argument))
                if let tab = model.selectedTab { model.setTarget(.local(project.id), for: tab) }
            case "code":
                if let code = try? String(contentsOfFile: argument, encoding: .utf8) { model.selectedTab?.replaceCode(code) }
            case "section":
                model.selectedTab?.outputSection = argument.isEmpty ? nil : argument
            case "intercept":
                model.settings.interceptMail = argument == "on"
            case "mcp-wait":
                // Holds the steps until an AI client's approval sheet is on screen (at most
                // `mcp-wait:<seconds>`, default 60), so a script driving `runlet mcp` and the
                // steps stay in step.
                if !model.mcpSheetAttached, DebugSteps.mcpWaited < (Double(argument) ?? 60) {
                    DebugSteps.mcpWaited += 0.25
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { run(index) }
                    return
                }
                FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: mcp approval \(model.mcp.presented.map { "\($0.clientName) → \($0.targetName)" } ?? "none (timed out)")\n".utf8))
                DebugSteps.mcpWaited = 0
            case "report":
                let windows = NSApp.windows.map { window in
                    "\(window.title.isEmpty ? String(describing: type(of: window)) : window.title)[visible=\(window.isVisible) key=\(window.isKeyWindow) main=\(window.isMainWindow) canKey=\(window.canBecomeKey) level=\(window.level.rawValue)]"
                }
                let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                FileHandle.standardError.write(Data("RUNLET_DEBUG_REPORT: active=\(NSApp.isActive) frontmost=\(front) key=\(NSApp.keyWindow?.title ?? "nil") main=\(NSApp.mainWindow?.title ?? "nil") windows=\(windows)\n".utf8))
            default:
                // Keys, commands, files, and state (DebugSteps.swift).
                _ = DebugSteps.run(parts[0], argument, model: model)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { run(index + 1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { run(0) }
    }
    #endif

    /// Closing the key window (Settings, Docker Profiles, …) lets macOS activate whatever
    /// window is next on screen, which was often another app's when one sat between the
    /// closing window and Runlet's main window. Before such a window goes away, make the
    /// frontmost other Runlet window key (an editor window first). Sheets, alerts, and popup
    /// panels are left to AppKit.
    @MainActor static func handOffKeyStatus(from closing: NSWindow) {
        guard closing.isKeyWindow, NSApp.isActive, closing.sheetParent == nil, NSApp.modalWindow !== closing else { return }
        let candidates = NSApp.orderedWindows.filter { window in
            window !== closing && window.isVisible && !window.isMiniaturized && window.canBecomeKey
                && window.sheetParent == nil && !(window is NSPanel)
        }
        (candidates.first { $0.canBecomeMain } ?? candidates.first)?.makeKeyAndOrderFront(nil)
    }

    @MainActor static func ensureMainWindow() {
        guard !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        _ = NSApp.delegate?.applicationOpenUntitledFile?(NSApp)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model else { return .terminateNow }
        // Stop managed runs, language servers, and automatic SSH connections; restart restores
        // code without running it. Quitting never waits more than a few seconds: anything still
        // stopping is left to the system, so Runlet can't linger "Running in Background".
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        Task { @MainActor in
            await model.shutdown()
            reply()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            MainActor.assumeIsolated { reply() }
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
        // Runlet ▸ Check for Updates… (#233), under About Runlet.
        CommandGroup(after: .appInfo) {
            item("app.checkForUpdates")
        }
        CommandGroup(after: .appSettings) {
            item("app.installCommandLineTool")
        }
        CommandGroup(replacing: .newItem) {
            item("file.newWindow")
            // New Tab, then New SQL, Redis, and MongoDB Tab (#214).
            ForEach(CommandCatalog.newTabIds, id: \.self) { item($0) }
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
            item("file.reloadFromDisk")
            Divider()
            item("file.saveAsArtisanCommand")
            item("file.saveAsTest")
            Divider()
            item("file.saveWorkspaceAs")
        }
        CommandGroup(after: .textEditing) {
            item("edit.toggleComment")
            // Move and duplicate lines (#234).
            Menu("Lines") {
                ForEach(LineCommand.allCases.map(\.commandId), id: \.self) { item($0) }
            }
            item("edit.formatCode")
            item("edit.complete")
            Divider()
            item("edit.goToDefinition")
            item("edit.findReferences")
            item("edit.codeActions")
            Menu("Code Folding") {
                item("edit.fold")
                item("edit.unfold")
                item("edit.foldAll")
                item("edit.unfoldAll")
            }
            // Magic comments' values (#302).
            Divider()
            item("edit.showInlineValue")
            item("edit.clearInlineValues")
        }
        CommandMenu("Run") {
            item("run.run")
            item("run.runSelection")
            item("run.sqlRunAll")
            item("run.sqlExplain")
            item("run.sqlExplainAnalyze")
            item("run.sqlExportCSV")
            item("run.profile")
            item("run.stop")
            item("run.toggleStrictTypes")
            item("run.toggleMailInterception")
            item("run.toggleRollback")
            Divider()
            item("output.copy")
            item("output.copyMarkdown")
            item("output.saveAs")
            item("output.clear")
            item("output.showQueries")
            item("output.showMail")
            item("output.showHTTP") // #5
            item("output.showJobs")
            item("output.showEvents")
            item("run.toggleRunLog") // #302
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
            item("library.database")
            item("view.projectCommands")
            item("project.openREPL")
            item("project.appInfo")
            item("library.togglePanel")
            item("library.saveSnippet")
            item("library.saveSnippetToProject")
            Divider()
            item("library.newDockerProfile")
            item("library.manageDockerProfiles")
            item("library.newSSHProfile")
            item("library.importSSHHosts")
            item("ssh.connect")
            item("ssh.disconnect")
            item("ssh.shell")
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
            item("view.inlayHints")
            item("output.toggle")
            item("view.toggleTerminal")
            item("view.newTerminal")
            item("output.swapPosition")
            item("view.builder")
            item("view.logs")
            Menu("Appearance") {
                ForEach(AppearancePreference.allCases, id: \.self) { appearance in
                    item(appearance.commandId)
                }
            }
            Divider()
        }
        // Help ▸ Runlet Documentation (#287), in place of the standard "Runlet Help" item, which has
        // no help book to open; then What's New and Show Tour (#232).
        CommandGroup(replacing: .help) {
            item("help.documentation")
            Divider()
            item("help.whatsNew")
            item("help.showTour")
        }
        CommandGroup(after: .windowArrangement) {
            Divider()
            item("window.connections")
            item("window.quickRun") // #25
            item("window.floatOnTop")
            Divider()
            item("tabs.next")
            item("tabs.previous")
            item("tabs.reopenClosed")
            item("tabs.closeOthers")
            item("tabs.closeToRight")
            item("tabs.rename")
            item("tabs.togglePin")
            item("tabs.toggleLanguage")
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

    /// `.sql` files open as SQL tabs (#35).
    static var sqlType: UTType { UTType(filenameExtension: "sql") ?? .plainText }

    static var workspaceType: UTType {
        UTType(exportedAs: WorkspaceDocument.typeIdentifier, conformingTo: .json)
    }

    /// Opens PHP files (as tabs) and `.runlet` workspaces (as windows).
    static func open(model: AppModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = phpTypes + [sqlType, workspaceType] + (UTType(filenameExtension: "redis").map { [$0] } ?? []) // #190
        panel.allowsMultipleSelection = true
        panel.message = "Open PHP or SQL files, or a Runlet workspace"
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
        if !saved, window.workspaceURL == nil, let tab = window.selectedTab, tab.fileURL == nil {
            save(tab, model: model, saveAs: true)
        }
    }

    @discardableResult
    static func saveWorkspaceAs(_ window: WindowModel, model: AppModel) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [workspaceType]
        panel.nameFieldStringValue = (window.workspaceURL?.lastPathComponent) ?? "Workspace.\(WorkspaceDocument.fileExtension)"
        panel.message = "Save this window's tabs and their targets as a workspace file."
            + (window.tabs.contains { $0.target.isSSH } ? " SSH tabs store their host names and directories (never keys or passwords)." : "")
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
        // SQL tabs save as .sql files (#35).
        let suffix = "." + tab.language.rawValue
        panel.allowedContentTypes = [UTType(filenameExtension: tab.language.rawValue) ?? .sourceCode]
        panel.nameFieldStringValue = tab.fileURL?.lastPathComponent ?? (tab.title.hasSuffix(suffix) ? tab.title : tab.title + suffix)
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
