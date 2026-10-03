import Foundation
import Observation
import RunletCore
import RunletExecution

/// Load Next (#146) for one SQL result the row cap cut: whether it can load more rows (or why
/// not), how many it holds, and the page that is loading. The tab keeps one per cut result of
/// its current output; a new run or Clear Output drops them (and stops a page that is loading).
@MainActor
@Observable
final class SQLResultPager {
    enum Phase: Equatable {
        case idle
        /// A page is loading: which rows ("rows 1,001–2,000").
        case loading(String)
        /// The last page didn't load: why (a refusal, an error, Stop).
        case failed(String)
    }

    @ObservationIgnored weak var tab: TabModel?
    /// The output item whose rows this pages.
    let itemId: Int
    /// The run that produced the result: its statement, connection, and bound values.
    let run: SQLRunInfo
    /// The target the statement ran on; a page runs there too.
    let target: TargetRef
    /// How the statement pages, or why it can't.
    let plan: Result<SQLPaging.Plan, SQLPaging.Refusal>
    /// Rows per page: what the first run fetched at most.
    let pageSize: Int
    var phase: Phase = .idle
    /// Rows the result holds, the runner's count of their bytes, and how many pages they took.
    private(set) var rows: Int
    private(set) var bytes: Int
    private(set) var pages = 1
    /// The last page was cut: more rows follow.
    private(set) var more: Bool
    /// Stops the page that is loading (set while one loads).
    @ObservationIgnored var stop: (() -> Void)?
    /// The tab ran again or cleared its output, so this result no longer pages (a result
    /// window keeps the rows it has).
    private(set) var isDetached = false

    init(tab: TabModel, itemId: Int, run: SQLRunInfo, target: TargetRef, result: SQLResultInfo) {
        self.tab = tab
        self.itemId = itemId
        self.run = run
        self.target = target
        pageSize = SQLPaging.normalizedPageSize(result.maxRows)
        rows = result.rows.count
        bytes = result.bytes ?? 0
        more = result.truncated == true
        if run.statements.count != 1 {
            plan = .failure(.script)
        } else {
            plan = SQLPaging.plan(for: run.statements[0].text, driver: result.driver)
        }
    }

    var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    var refusal: SQLPaging.Refusal? {
        if case .failure(let refusal) = plan { return refusal }
        return nil
    }

    /// The statement orders its rows (pages are stable while the data stays the same).
    var ordered: Bool {
        if case .success(let plan) = plan { return plan.ordered }
        return false
    }

    /// The result card keeps no more (`SQLPaging.maxLoadedRows` or `maxLoadedBytes`).
    var atLimit: Bool { rows >= SQLPaging.maxLoadedRows || bytes >= SQLPaging.maxLoadedBytes }

    var canLoadMore: Bool { more && refusal == nil && !atLimit && !isLoading && !isDetached }

    /// Stops a page that is loading and stops paging: the output this paged is going away.
    func detach() {
        stop?()
        isDetached = true
    }

    /// Rows the next page asks for: a page, or what is left under the row limit.
    var nextSize: Int { max(1, min(pageSize, SQLPaging.maxLoadedRows - rows)) }

    /// A page was appended: the result now holds `result`'s rows.
    func appended(_ result: SQLResultInfo) {
        rows = result.rows.count
        bytes = result.bytes ?? bytes
        pages = result.pages ?? pages
        more = result.truncated == true
        phase = .idle
    }

    /// "Load Next 1,000"
    var buttonTitle: String { "Load Next \(nextSize.formatted())" }

    /// Why pages may not line up, shown once the result can page or has paged.
    var stabilityNote: String {
        ordered
            ? "Each page runs the statement again: rows can shift between pages if the data changes in between."
            : "Each page runs the statement again, and it has no ORDER BY: the database may return rows in another order each time, so rows can repeat or go missing. Add ORDER BY for stable pages."
    }

    /// Why the result can't load more of its rows, when it is cut but can't page.
    var limitNote: String {
        rows >= SQLPaging.maxLoadedRows
            ? "A result keeps at most \(SQLPaging.maxLoadedRows.formatted()) rows; the rows after these were not fetched. Narrow the statement with WHERE, or page with LIMIT and OFFSET."
            : "A result keeps at most \(ByteCountFormatter.string(fromByteCount: Int64(SQLPaging.maxLoadedBytes), countStyle: .memory)) of cells; the rows after these were not fetched. Select fewer columns, or page with LIMIT and OFFSET."
    }
}

/// Load Next (#146): runs the next page of a cut result's statement in a fresh runner, on the
/// same target and connection with the same bound values, and appends its rows to the card (and
/// to result windows showing it). Only plain reads page (`SQLPaging`). Like Run, a page asks
/// first on production, a read-only connection stays read-only, and the page is a Run History
/// entry of its own ("-- Load Next: rows 1,001–2,000" after the statement).
extension AppModel {
    func loadNextSQLPage(_ tab: TabModel, item itemId: Int) {
        guard let pager = tab.sqlPagers[itemId], pager.canLoadMore, case .success(let plan) = pager.plan else { return }
        let run = pager.run
        let target = pager.target
        guard tab.target == target else {
            pager.phase = .failed("The tab is on another target now. Run the statement again to page its rows.")
            return
        }
        if let saved = run.saved, library.databaseConnection(saved.id) != saved {
            // The rows so far came from that definition; a page from another would mix databases.
            pager.phase = .failed("The saved connection “\(saved.name)” changed or was removed since the statement ran. Run the statement again to page its rows.")
            return
        }
        guard !tab.isRunning else {
            pager.phase = .failed("The tab is running. Load Next when the run ends.")
            return
        }
        let page = plan.page(offset: pager.rows, size: pager.nextSize)
        guardProduction(.sql, target: target, text: page.sql, sqlConnection: run.connectionLabel, sqlSaved: run.saved != nil, savedConnection: run.saved,
                        sqlValues: run.values.isEmpty ? nil : run.values, sqlPage: page.rowsText, in: window(containing: tab.id)) { [weak self, weak tab] in
            guard let self, let tab, tab.sqlPagers[itemId] === pager, pager.canLoadMore, !tab.isRunning, tab.target == target else { return }
            self.startSQLPage(tab, pager: pager, page: page)
        }
    }

    func stopSQLPage(_ tab: TabModel, item itemId: Int) {
        tab.sqlPagers[itemId]?.stop?()
    }

    private func startSQLPage(_ tab: TabModel, pager: SQLResultPager, page: SQLPaging.Page) {
        let run = pager.run
        let target = pager.target
        let itemId = pager.itemId
        let marking = library.marking(for: target, connection: run.saved)
        let code = SQLTabRun.pageCode(page, connection: run.connection, bindings: run.bindings.first ?? [])
        let historyCode = run.historyCode + "\n-- Load Next: \(page.rowsText)"
        let inspector = inspectorOptions(for: target)
        let hints = run.saved == nil ? sessionHints[target.stableKey] ?? [:] : [:]
        pager.phase = .loading(page.rowsText)
        let runId = UUID()
        let engine = self.engine
        let task = Task { [weak self, weak tab, weak pager] in
            guard let self, let tab, let pager else { return }
            var result: SQLResultInfo?
            var errors: [RunErrorInfo] = []
            var finished: FinishedInfo?
            var label = ""
            do {
                let snapshot = try await self.snapshot(for: tab)
                label = snapshot.label
                try Task.checkCancellation()
                // A pseudo tab id keeps the page apart from the tab's own runs.
                var request = RunRequest(runId: runId, tabId: UUID(), documentVersion: tab.documentVersion, target: snapshot, code: code, inspector: inspector, magicComments: false)
                request.sqlConnection = run.saved
                request.hints = hints
                let stream = try await engine.start(request)
                await withTaskCancellationHandler {
                    for await event in stream {
                        switch event.kind {
                        case .sql(let info): result = info
                        case .error(let error): errors.append(TabModel.withoutRunnerLocation(error))
                        case .finished(let info): finished = info
                        default: break
                        }
                    }
                } onCancel: {
                    Task { await engine.cancel(runId: runId) }
                }
            } catch is CancellationError {
            } catch {
                errors.append(RunErrorInfo(stage: .launch, message: "\(error)"))
            }
            if let finished {
                self.recordHistory(HistoryEntry(runId: runId, code: historyCode, target: target, targetLabel: label, status: finished.status, reason: finished.reason, elapsedMs: finished.elapsedMs, language: .sql, targetEnvironment: marking.environment, targetColor: marking.color))
            }
            pager.stop = nil
            guard tab.sqlPagers[itemId] === pager else { return }
            if Task.isCancelled || finished?.status == .cancelled {
                pager.phase = .failed("Stopped. No rows were added.")
                return
            }
            guard let result, let base = tab.sqlResult(itemId) else {
                pager.phase = .failed(errors.first?.message ?? "The page ended without rows.")
                return
            }
            // Only the page's rows are added to the table, off the main thread.
            let combined = await Task.detached(priority: .userInitiated) { base.appending(result) }.value
            guard tab.sqlPagers[itemId] === pager else { return }
            guard let combined else {
                pager.phase = .failed("The page's columns differ from the result's (\(result.columns.joined(separator: ", "))). The statement or the table changed: run it again.")
                return
            }
            tab.replaceSQLResult(itemId, with: combined)
            pager.appended(combined)
            ResultWindows.refresh(pager: pager, table: combined.table, title: SQLResultCard.windowTitle(tabTitle: tab.title, result: combined))
        }
        pager.stop = { [weak pager] in
            task.cancel()
            pager?.stop = nil
        }
    }
}
