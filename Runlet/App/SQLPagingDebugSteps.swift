#if DEBUG
import Foundation
import RunletCore

/// RUNLET_DEBUG_STEPS for Load Next (#146), for screenshots and scripted checks with scratch
/// data (see `DebugSteps`): `sql-load-next` (Load Next on the current tab's last cut result, as
/// its button does; production asks with its sheet; waitable with `wait-page`, which then
/// prints the main thread's timings, `DebugRunTiming`) · `sql-page-stop` (its Stop) ·
/// `sql-page-state` (prints each cut result's rows, pages, plan, and phase) ·
/// `sql-rows-per-page:<n>` (Settings ▸ General ▸ SQL Results ▸ Rows per page).
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
            log("sql-page-state: \(describe(pager)) card=\"\(summary)\"")
        }
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
