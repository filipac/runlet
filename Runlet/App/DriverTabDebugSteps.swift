#if DEBUG
import AppKit
import RunletCore

/// RUNLET_DEBUG_STEPS for a project driver's inspector tabs (`inspectorTabs()`), for scripted
/// checks with scratch data only (see `DebugSteps`), all on the selected tab's target:
/// `custom-tab:open[:<id>]` (shows the tab, or the first one the driver declares) ·
/// `custom-tab:load` (the picker's Load the Driver's Tabs) · `custom-tab:refresh` (Refresh) ·
/// `custom-tab:play:<row>`, `custom-tab:pause:<row>`, `custom-tab:logs:<row>` (a row's buttons;
/// Logs opens its popover) · `custom-tab:logs-promote` (the popover's Open in Terminal) ·
/// `custom-tab:logs-close` · `custom-tab:copy:visible|all` (the popover's Copy, printed) ·
/// `custom-tab:filter:<id>` (the filter control) · `custom-tab:scroll:<y>`, `custom-tab:scroll-watch`,
/// `custom-tab:scroll-state` (the rows' scroll position and content height, and what changed them) ·
/// `custom-tab:pane:<pane>` (a built-in pane, as the picker chooses it) · `custom-tab:state`
/// (prints the tabs, the list, each row's state, the terminal tabs, and the last lines of each
/// row's terminal) · `custom-tab-wait:<condition>[:<seconds>]` (in `DriverTabDebugSteps.reached`:
/// `known`, `listed`, `failed`, `settled`, `filters=<n>`, `running=<row>`, `stopped=<row>`,
/// `output=<row>~<text>`) · `custom-tab:reload` (the pane's Reload Its Tabs).
@MainActor
enum DriverTabDebugSteps {
    static var waited: Double = 0

    /// " (took N ms)": how long the shown tab's last list took.
    static func lastDuration(_ model: AppModel) -> String {
        guard let editorTab = model.selectedTab, let tab = model.shownDriverInspectorTab(for: editorTab.target),
              let duration = model.driverTabs.durations[DriverTabRowKey.listKey(target: editorTab.target.stableKey, tab: tab.id)] else { return "" }
        return " (the list took \(Int(duration / .milliseconds(1))) ms)"
    }

    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        guard name == "custom-tab" else { return false }
        let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
        let action = parts.first ?? ""
        let value = parts.count > 1 ? parts[1] : ""
        guard let editorTab = model.selectedTab else {
            log("custom-tab: no tab")
            return true
        }
        let target = editorTab.target
        let tabs = model.driverInspectorTabs(for: target)
        let shown = model.shownDriverInspectorTab(for: target) ?? tabs.first
        switch action {
        case "open":
            guard let tab = value.isEmpty ? tabs.first : tabs.first(where: { $0.id == value }) else {
                log("custom-tab open: none of \(tabs.map(\.id))")
                return true
            }
            model.driverInspectorTab = tab.id
            model.setInspectorVisible(true)
        case "pane":
            if let pane = AppModel.InspectorPane.allCases.first(where: { "\($0)" == value }) { model.inspectorPane = pane }
        case "load":
            model.loadDriverInspectorTabs(for: editorTab)
        case "reload":
            // The pane's Reload Its Tabs (after the driver changed on a production target).
            model.reloadDriverInspectorTabs(for: target, confirm: true)
        case "refresh":
            if let shown { model.refreshDriverTab(shown, target: target, window: model.activeWindow) }
        case "play", "pause", "logs":
            guard let tab = shown else {
                log("custom-tab \(action): no tab")
                return true
            }
            let key = DriverTabRowKey(target: target.stableKey, tab: tab.id, row: value)
            switch action {
            case "play":
                guard let item = model.driverTabRows(tab, target: target).first(where: { $0.id == value }) else {
                    log("custom-tab play: no row \(value)")
                    return true
                }
                model.playDriverTabRow(item, of: tab, for: editorTab, in: model.activeWindow)
            case "pause":
                model.pauseDriverTabRow(key, of: tab, target: target)
            default:
                model.showDriverTabRowLogs(key)
            }
        case "logs-promote":
            // The open Logs popover's Open in Terminal.
            if let key = model.driverTabs.logsPopover { model.promoteDriverTabRowLogs(key) } else { log("custom-tab logs-promote: no popover") }
        case "logs-close":
            model.driverTabs.logsPopover = nil
        case "copy":
            // `custom-tab:copy:visible|all`: the open Logs popover's Copy, printed instead of copied.
            if let key = model.driverTabs.logsPopover, let (session, _) = model.driverTabSession(key) {
                let text = session.text(visibleOnly: value != "all")
                log("custom-tab copy \(value): \(text.split(separator: "\n").count) lines, last: \(text.split(separator: "\n").last ?? "")")
            }
        case "filter":
            // `custom-tab:filter:<id>`: the filter control, as clicked.
            if let tab = shown, tab.filters.contains(where: { $0.id == value }) {
                model.setDriverTabFilter(value, of: tab, target: target)
            } else {
                log("custom-tab filter: no filter \(value) in \(shown?.filters.map(\.id) ?? [])")
            }
        case "scroll":
            // `custom-tab:scroll:<y>`: scrolls the rows to y points from the top, as the scroll wheel would.
            guard let scroll = rowsScrollView() else {
                log("custom-tab scroll: no list")
                return true
            }
            let y = CGFloat(Double(value) ?? 0)
            ownScroll = true
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            ownScroll = false
        case "scroll-watch":
            // Counts every scroll and every content height change of the rows from now on.
            watchScroll()
        case "scroll-state":
            log(scrollState())
        case "state":
            log(state(model))
        default:
            log("custom-tab: \(argument)?")
        }
        return true
    }

    /// Whether `custom-tab-wait:<condition>` holds.
    static func reached(_ argument: String, model: AppModel) -> Bool {
        let condition = argument.split(separator: ":").first.map(String.init) ?? argument
        guard let editorTab = model.selectedTab else { return true }
        let target = editorTab.target
        if condition == "known" { return model.knowsDriverInspectorTabs(for: target) && !model.commandsState(for: target).isLoading }
        guard let tab = model.shownDriverInspectorTab(for: target) ?? model.driverInspectorTabs(for: target).first else { return false }
        let state = model.driverTabListState(tab, target: target)
        let pair = condition.split(separator: "=", maxSplits: 1).map(String.init)
        func key(_ row: String) -> DriverTabRowKey { DriverTabRowKey(target: target.stableKey, tab: tab.id, row: row) }
        switch pair.first {
        case "filters":
            // The shown tab declares this many filters, and nothing is being read.
            return tab.filters.count == Int(pair.last ?? "") && !model.driverTabs.reloading.contains(target.stableKey) && !state.isLoading
        case "settled":
            return !model.driverTabs.reloading.contains(target.stableKey) && !model.commandsState(for: target).isLoading && !state.isLoading
        case "listed":
            if case .loaded = state { return true }
            return false
        case "failed":
            if case .failed = state { return true }
            return false
        case "running":
            if case .running = model.driverTabRowState(key(pair.last ?? "")) { return true }
            return false
        case "stopped":
            return model.driverTabRowState(key(pair.last ?? "")) == .stopped
        case "output":
            let parts = (pair.last ?? "").split(separator: "~", maxSplits: 1).map(String.init)
            guard parts.count == 2, let (session, _) = model.driverTabSession(key(parts[0])) else { return false }
            return text(of: session).contains(parts[1])
        default:
            return true
        }
    }

    /// The tabs, the list, rows and their states, the terminal tabs, and each row terminal's
    /// last lines (scratch data only).
    static func state(_ model: AppModel) -> String {
        guard let editorTab = model.selectedTab else { return "custom-tab: no tab" }
        let target = editorTab.target
        let tabs = model.driverInspectorTabs(for: target)
        let key = target.stableKey
        let stored = model.driverInspectorTabMemory.fingerprints[key]
        let current = model.driverFolderFingerprint(for: target)
        var line = "custom-tab: target=\(model.targetLabel(target)) driver=\(model.hasProjectDriver(for: target)) known=\(model.knowsDriverInspectorTabs(for: target)) "
            + "fingerprint=\(stored == nil ? "none" : stored == current ? "current" : "changed") reloading=\(model.driverTabs.reloading.contains(key)) offer=\(model.driverTabs.reloadOffers.contains(key)) reloadError=\(model.driverTabs.reloadErrors[key] ?? "-") "
            + "offersLoad=\(model.offersDriverInspectorTabsLoad(for: target)) tabs=\(tabs.map { "\($0.id)(\($0.title), \($0.listCommand.map { "host: \($0)" } ?? "driver"))" }) "
            + "shown=\(model.shownDriverInspectorTab(for: target)?.id ?? "none") inspector=\(model.showInspector ? "\(model.inspectorPane)" : "hidden")"
        if let tab = model.shownDriverInspectorTab(for: target) ?? tabs.first {
            let state = model.driverTabListState(tab, target: target)
            let list: String
            switch state {
            case .idle: list = "idle"
            case .loading: list = "loading"
            case .loaded(let listing): list = "loaded(\(listing.items.count))"
            case .failed(let message, let output, _): list = "failed(\(message) | output: \(output ?? "-"))"
            }
            let updated = state.listing.map { $0.loadedAt.formatted(date: .omitted, time: .standard) } ?? "-"
            let took = model.driverTabs.durations[DriverTabRowKey.listKey(target: target.stableKey, tab: tab.id)].map { "\(Int($0 / .milliseconds(1))) ms" } ?? "-"
            let counts = model.driverTabFilterCounts(tab, target: target)
            let filters = tab.filters.map { "\($0.id)\($0.tag.map { "[tag \($0)]" } ?? "")\($0.isDefault ? "*" : "")=\(counts?[$0.id].map(String.init) ?? "-")" }
            line += " filters=\(filters) filter=\(model.driverTabFilter(tab, target: target)?.id ?? "none")"
            line += " list=\(list) took=\(took) updated=\(updated) message=\(state.listing?.message ?? "-") skipped=\(state.listing?.skipped ?? []) notices=\(state.listing?.notices ?? [])"
            let rows = model.driverTabRows(tab, target: target).map { item -> String in
                let key = DriverTabRowKey(target: target.stableKey, tab: tab.id, row: item.id)
                return "\(item.id)[\(item.subtitle ?? "-")|badge=\(item.badge ?? "-")|tags=\(item.tags.joined(separator: "+"))|\(describe(model.driverTabRowState(key)))\(model.driverTabSession(key) == nil ? "" : "|terminal")]"
            }
            line += " rows=\(rows)"
            for (key, _) in model.driverTabs.runs where key.target == target.stableKey && key.tab == tab.id {
                if let (session, _) = model.driverTabSession(key) {
                    let last = text(of: session).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(3)
                    line += " output(\(key.row))=\(Array(last))"
                }
            }
        }
        let popover = NSApp.windows.first { String(describing: type(of: $0)).contains("Popover") && $0.isVisible }
        line += " popover=\(model.driverTabs.logsPopover?.row ?? "none") popoverWindow=\(popover == nil ? "none" : "shown") active=\(NSApp.isActive) key=\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "none")"
        if let first = popover?.firstResponder { line += " popoverFirstResponder=\(type(of: first))" }
        if let window = model.activeWindow {
            let terminals = window.terminals.sessions.map { "\($0.title):\($0.state)\($0.isBorrowed ? "(borrowed)" : "")\($0.view.isReadOnly ? "(read-only)" : "") \($0.view.getTerminal().cols)x\($0.view.getTerminal().rows)" }
            line += " terminals=\(terminals) selectedTerminal=\(window.terminals.selected?.title ?? "none") panel=\(model.isTerminalVisible(in: window) ? "visible" : "hidden")"
        }
        return line
    }

    private static func describe(_ state: DriverTabRowState) -> String {
        switch state {
        case .idle: "idle"
        case .running(let since): "running \(Int(Date().timeIntervalSince(since)))s"
        case .pausing: "pausing"
        case .stopped: "stopped"
        case .exited(let code): "exited(\(code.map(String.init) ?? "?"))"
        case .failed(let message): "failed(\(message))"
        }
    }

    // MARK: Scroll position of the rows

    /// How often the pane's and its rows' bodies ran (since `scroll-watch`).
    static var renders = (pane: 0, rows: 0)
    private static var ownScroll = false
    private static var scrollMoves: [CGFloat] = []
    private static var heights: [CGFloat] = []
    private static var observers: [NSObjectProtocol] = []

    /// The rows' scroll view: the table-backed list in the inspector (the rightmost one).
    static func rowsScrollView() -> NSScrollView? {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }), let content = window.contentView else { return nil }
        func all(_ view: NSView) -> [NSScrollView] { ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(all) }
        return all(content)
            .filter { $0.documentView is NSTableView && !$0.isHiddenOrHasHiddenAncestor && $0.window != nil }
            .max { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    private static func watchScroll() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        scrollMoves = []
        heights = []
        renders = (0, 0)
        guard let scroll = rowsScrollView(), let document = scroll.documentView else { return log("custom-tab scroll-watch: no list") }
        scroll.contentView.postsBoundsChangedNotifications = true
        document.postsFrameChangedNotifications = true
        heights = [document.frame.height]
        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { _ in
            MainActor.assumeIsolated {
                if !ownScroll, let y = rowsScrollView()?.contentView.bounds.origin.y, scrollMoves.last != y { scrollMoves.append(y) }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: document, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let height = rowsScrollView()?.documentView?.frame.height, heights.last != height { heights.append(height) }
            }
        })
    }

    /// Where the rows are scrolled to, their content height, and (since `scroll-watch`) every
    /// scroll Runlet made by itself and every content height they had.
    static func scrollState() -> String {
        guard let scroll = rowsScrollView(), let document = scroll.documentView else { return "custom-tab scroll: no list" }
        let rows = (document as? NSTableView)?.numberOfRows ?? -1
        return "custom-tab scroll: y=\(Int(scroll.documentVisibleRect.origin.y)) contentHeight=\(Int(document.frame.height)) rows=\(rows) "
            + "selfScrolls=\(scrollMoves.map { Int($0) }) heights=\(heights.map { Int($0) }) renders: pane=\(renders.pane) rows=\(renders.rows)"
    }

    static func text(of session: TerminalSession) -> String {
        String(decoding: session.view.getTerminal().getBufferAsData(), as: UTF8.self)
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(message)\n".utf8))
    }
}
#endif
