#if DEBUG
import AppKit
import RunletCore

/// RUNLET_DEBUG_STEPS for Load Next (#146), for screenshots and scripted checks with scratch
/// data (see `DebugSteps`): `sql-load-next` (Load Next on the current tab's last cut result, as
/// its button does; production asks with its sheet; waitable with `wait-page`, which then
/// prints the main thread's timings, `DebugRunTiming`) · `sql-page-stop` (its Stop) ·
/// `sql-page-state` (prints each cut result's rows, pages, plan, and phase) ·
/// `sql-rows-per-page:<n>` (Settings ▸ General ▸ SQL Results ▸ Rows per page) ·
/// `table-scroll:<row>|end` (scrolls the output's last grid to a row, e.g. where a page starts) ·
/// `timing:start` and `timing:report` (the main thread's stalls over the steps between).
@MainActor
enum SQLPagingDebugSteps {
    /// Runs one step; false when `name` isn't one of these.
    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        switch name {
        case "sql-load-next":
            guard let tab = model.selectedTab, let pager = lastPager(tab) else {
                log("sql-load-next: no cut result")
                return true
            }
            DebugRunTiming.start(tab)
            model.loadNextSQLPage(tab, item: pager.itemId)
            log("sql-load-next: \(describe(pager))")
        case "sql-page-stop":
            if let tab = model.selectedTab, let pager = lastPager(tab) { model.stopSQLPage(tab, item: pager.itemId) }
        case "sql-page-state":
            report(model)
        case "table-scroll":
            // `table-scroll:<row>` scrolls the output's last grid so that row (1-based) is the
            // first one shown, e.g. where a page starts; `table-scroll:end` to its last row.
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.isMainWindow }) ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
                  let grid = grids(in: window.contentView).last else {
                log("table-scroll: no grid")
                return true
            }
            let row = argument == "end" ? grid.numberOfRows - 1 : max(0, min(grid.numberOfRows - 1, (Int(argument) ?? 1) - 1))
            if let clip = grid.enclosingScrollView?.contentView {
                let headerHeight = grid.headerView?.frame.height ?? 0
                var origin = grid.rect(ofRow: row).origin
                origin.y -= headerHeight
                if argument == "end" { origin.y = max(0, grid.frame.height - clip.bounds.height) }
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: max(-headerHeight, origin.y)))
                grid.enclosingScrollView?.reflectScrolledClipView(clip)
            }
            log("table-scroll: row \(row + 1) of \(grid.numberOfRows)")
        case "timing":
            // `timing:start` and `timing:report`: the main thread's stalls (DebugRunTiming) over
            // the steps between, such as typing in a result window's search.
            guard let tab = model.selectedTab else { return true }
            if argument == "start" { DebugRunTiming.start(tab) } else { DebugRunTiming.report(tab) }
        case "sql-rows-per-page":
            model.settings.sqlRowsPerPage = SQLPaging.normalizedPageSize(Int(argument))
            log("sql-rows-per-page: \(model.settings.sqlRowsPerPage)")
        default:
            return false
        }
        return true
    }

    static func report(_ model: AppModel) {
        guard let tab = model.selectedTab else { return log("sql-page-state: no tab") }
        let pagers = tab.sqlPagers.values.sorted { $0.itemId < $1.itemId }
        guard !pagers.isEmpty else { return log("sql-page-state: no cut results") }
        for pager in pagers {
            let summary = tab.sqlResult(pager.itemId)?.summary ?? "gone"
            log("sql-page-state: \(describe(pager)) card=\"\(summary)\" memory=\(residentMegabytes())MB")
        }
    }

    /// The app's resident memory, for the row limit's cost.
    private static func residentMegabytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size / 1_048_576) : -1
    }

    /// The output's grids, in the order they are laid out.
    private static func grids(in view: NSView?) -> [NSTableView] {
        guard let view else { return [] }
        if let table = view as? NSTableView, table.accessibilityIdentifier() == "value-table-grid" { return [table] }
        return view.subviews.flatMap { grids(in: $0) }
    }

    private static func lastPager(_ tab: TabModel) -> SQLResultPager? {
        tab.sqlPagers.values.max { $0.itemId < $1.itemId }
    }

    private static func describe(_ pager: SQLResultPager) -> String {
        let plan: String = switch pager.plan {
        case .success(let plan): "\(plan.mode.rawValue)\(plan.ordered ? " ordered" : "")"
        case .failure(let refusal): "refused(\(refusal.message))"
        }
        let phase: String = switch pager.phase {
        case .idle: "idle"
        case .loading(let rows): "loading \(rows)"
        case .failed(let message): "failed(\(message))"
        }
        return "rows=\(pager.rows) pages=\(pager.pages) more=\(pager.more) atLimit=\(pager.atLimit) bytes=\(pager.bytes) plan=\(plan) phase=\(phase)"
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(message)\n".utf8))
    }
}
#endif
