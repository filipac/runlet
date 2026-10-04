import AppKit
import Observation
import RunletCore
import RunletExecution

/// Browse Table (#151): one table of the schema explorer's connection, in a result window of its
/// own. Pages are read on the server (`SQLTableBrowse`): a page size, previous and next, a sort
/// by a column, and filter rules turned into a WHERE with bound values. On a table with a
/// primary key, on a connection that isn't read-only and binds values (`SQLTableEdits.refusal`),
/// cells can be changed, rows added, and rows deleted; nothing is sent while editing, and the
/// grid marks what is pending. Review Changes shows the exact statements; Apply runs them in one
/// transaction, each affecting exactly one row, or rolls everything back.
///
/// Like every SQL action: production asks before each read and before Apply (which lists every
/// statement); a read-only connection is never edited; the run goes where the explorer's
/// connection goes (`sqlSnapshot`: the target, this Mac, or an SSH tunnel); Stop cancels the
/// statement on the server (#144). Applied changes are one Run History entry (#149). The window
/// keeps nothing when it closes: pending changes are discarded.
@MainActor
@Observable
final class TableBrowser: Identifiable {
    enum Phase: Equatable {
        case idle
        /// A page is loading: which rows.
        case loading(String)
        /// Apply is running: how many statements.
        case applying(Int)
        /// The last read failed, or was refused or stopped.
        case failed(String)
    }

    /// What the last Apply did.
    struct ApplyReport: Equatable {
        var succeeded: Bool
        var message: String
    }

    /// The cell editor sheet: a cell of the page (or of a new row) and what is typed.
    struct CellEdit: Identifiable, Equatable {
        let id = UUID()
        /// A row of the display table (the page's rows, then the new rows) and a column.
        var row: Int
        var column: Int
        var text: String
        var isNull: Bool
        /// New rows: leave the column out, so the database gives it its default.
        var useDefault: Bool
        var problem: String?
    }

    let id = UUID()
    let table: SQLSchemaInfo.Table
    let dialect: SQLTableBrowse.Dialect
    /// The schema's PDO driver, which the runner checks; nil for a callable connection.
    let driver: String?
    /// Where the connection comes from (`SQLSchemaInfo.source`).
    let source: String?
    let target: TargetRef
    let connection: SQLConnectionChoice
    /// The tab it was opened from: reads and Apply resolve the target through it.
    @ObservationIgnored weak var tab: TabModel?
    let tabTitle: String
    /// "on acme", "on this Mac (Runlet's PHP 8.5.8)".
    let openedFrom: String
    /// Why the rows are read-only; nil when they can be edited.
    let editRefusal: SQLTableEdits.Refusal?
    /// The target or the saved connection is production: reads and Apply ask.
    let isProduction: Bool

    var pageSize = SQLTableBrowse.defaultPageSize
    private(set) var sort: SQLTableBrowse.Sort?
    /// The filter rules as edited (columns index `columns`); Apply Filters reads with them.
    var filters: [ValueTableFilter] = []
    /// The rules the page was read with.
    private(set) var appliedFilters: [SQLTableBrowse.Filter] = []
    private(set) var page: SQLResultInfo?
    /// Rows before the page shown.
    private(set) var pageOffset = 0
    var phase: Phase = .idle
    private(set) var changes = SQLTableEdits.Changes()
    var report: ApplyReport?
    var cellEdit: CellEdit?
    var isReviewing = false
    /// The rows selected in the grid (rows of `display`).
    var selectedRows: [Int] = []
    /// The page with its pending changes, and their marks, as the grid shows them.
    private(set) var display: ValueTable
    private(set) var marks = SQLTableEdits.Marks()
    /// Counts the pages read: the grid fits its columns to each new page, and keeps their widths
    /// while the page is edited.
    private(set) var pageLoads = 0
    @ObservationIgnored var stop: (() -> Void)?
    /// What the last read or Apply did, for DEBUG steps.
    var lastEvent: String?

    init(table: SQLSchemaInfo.Table, dialect: SQLTableBrowse.Dialect, driver: String?, source: String?, target: TargetRef, connection: SQLConnectionChoice, tab: TabModel, openedFrom: String, editRefusal: SQLTableEdits.Refusal?, isProduction: Bool) {
        self.table = table
        self.dialect = dialect
        self.driver = driver
        self.source = source
        self.target = target
        self.connection = connection
        self.tab = tab
        tabTitle = tab.title
        self.openedFrom = openedFrom
        self.editRefusal = editRefusal
        self.isProduction = isProduction
        display = SQLTableEdits.display(columns: Array(table.columns.prefix(SQLTableBrowse.maxColumns)).map(\.name), rows: [], offset: 0, changes: SQLTableEdits.Changes()).table
    }

    /// The columns a page reads, in the table's order.
    var columns: [SQLSchemaInfo.Column] { Array(table.columns.prefix(SQLTableBrowse.maxColumns)) }

    /// "orders · Browse"
    var windowTitle: String { "\(table.name) · Browse" }

    /// "The saved connection “Shop” on this Mac · SQLite"
    var subtitle: String {
        let label = connection.label
        return label.prefix(1).uppercased() + label.dropFirst() + " on \(openedFrom) · \(dialect.displayName)"
    }

    var isBusy: Bool {
        switch phase {
        case .loading, .applying: true
        case .idle, .failed: false
        }
    }

    /// The page's columns are the schema's: else the table changed, and rows aren't edited.
    var pageMatchesSchema: Bool { page.map { $0.columns == columns.map(\.name) } ?? false }

    /// Why editing is off right now (the table's refusal, or a page whose columns changed).
    var editNote: String? {
        if let editRefusal { return editRefusal.description }
        if page != nil, !pageMatchesSchema { return "The page's columns differ from the schema Runlet read: the table changed. Reload the schema, then browse the table again to edit it." }
        return nil
    }

    var canEdit: Bool { editNote == nil && page != nil }
    var hasChanges: Bool { !changes.isEmpty }
    var hasMore: Bool { page?.truncated == true }
    var hasPrevious: Bool { pageOffset > 0 }

    /// The filter rules as the server reads them.
    var serverFilters: [SQLTableBrowse.Filter] {
        filters.compactMap { filter in columns.indices.contains(filter.column) ? SQLTableBrowse.Filter(column: columns[filter.column].name, op: filter.op, value: filter.value) : nil }
    }

    /// Apply Filters would read something else than the page shows.
    var filtersChanged: Bool { serverFilters.filter { !$0.isIncomplete } != appliedFilters }

    /// The page at `offset` with the current sort and filter rules.
    func request(offset: Int) -> SQLTableBrowse.Request {
        SQLTableBrowse.Request(table: table.name, columns: table.columns, dialect: dialect, sort: sort, filters: serverFilters, offset: offset, pageSize: pageSize, bindsValues: driver != nil)
    }

    /// "Rows 101–200", "No rows", "Rows 1–37 of 37".
    var rowsText: String {
        guard let page else { return "" }
        guard !page.rows.isEmpty else { return pageOffset == 0 ? "No rows" : "No rows after row \(pageOffset.formatted())" }
        let range = "\((pageOffset + 1).formatted())–\((pageOffset + page.rows.count).formatted())"
        return hasMore ? "Rows \(range)" : "Rows \(range) of \((pageOffset + page.rows.count).formatted())"
    }

    // MARK: Changing what the page shows

    func setSort(_ sort: SQLTableBrowse.Sort?) {
        self.sort = sort
    }

    /// A page arrived: it replaces the one shown.
    func loaded(_ result: SQLResultInfo, offset: Int, filters: [SQLTableBrowse.Filter]) {
        page = result
        pageOffset = offset
        appliedFilters = filters
        changes = SQLTableEdits.Changes()
        selectedRows = []
        phase = .idle
        pageLoads += 1
        refreshDisplay()
    }

    // MARK: Editing

    /// A row of `display` that is a page row, or nil for a new row.
    func pageRow(_ row: Int) -> Int? {
        guard let page, row < page.rows.count else { return nil }
        return row
    }

    /// The new row (index into the pending new rows) a display row is.
    func newRow(_ row: Int) -> Int? {
        let count = page?.rows.count ?? 0
        return row >= count && row - count < changes.newRows.count ? row - count : nil
    }

    /// What the page read for a cell.
    func original(row: Int, column: Int) -> SQLCell? {
        guard let page, row < page.rows.count, column < page.rows[row].count else { return nil }
        return page.rows[row][column]
    }

    /// Why a cell can't be edited (a deleted row, a value Runlet didn't read in full), or nil.
    func cellProblem(row: Int, column: Int) -> String? {
        if let editNote { return editNote }
        guard columns.indices.contains(column) else { return "That column isn't on the page." }
        if changes.deletedRows.contains(row) { return "This row will be deleted. Restore it to edit it." }
        if let original = original(row: row, column: column) {
            return SQLTableEdits.cellProblem(original, column: columns[column], dialect: dialect)
        }
        return newRow(row) == nil ? "That row isn't on the page." : SQLTableEdits.cellProblem(.null, column: columns[column], dialect: dialect)
    }

    /// Opens the cell editor on a cell.
    func beginEditing(row: Int, column: Int) -> String? {
        if let problem = cellProblem(row: row, column: column) { return problem }
        let pending: SQLTableEdits.Value?
        if let new = newRow(row) {
            pending = changes.newRows[new][column]
        } else {
            pending = changes.value(row: row, column: column) ?? original(row: row, column: column).map { $0 == .null ? .null : .text($0.text) }
        }
        cellEdit = CellEdit(row: row, column: column, text: pending.flatMap { if case .text(let text) = $0 { text } else { nil } } ?? "",
                            isNull: pending == .null, useDefault: newRow(row) != nil && pending == nil)
        return nil
    }

    /// Set in the cell editor: checks the value against its column, then keeps it pending.
    @discardableResult
    func commitEdit() -> Bool {
        guard var edit = cellEdit, columns.indices.contains(edit.column) else { return false }
        if let new = newRow(edit.row), edit.useDefault {
            changes.setNew(row: new, column: edit.column, to: nil)
            cellEdit = nil
            refreshDisplay()
            return true
        }
        let value: SQLTableEdits.Value = edit.isNull ? .null : .text(edit.text)
        if let problem = SQLTableEdits.valueProblem(value, column: columns[edit.column], dialect: dialect) {
            edit.problem = problem
            cellEdit = edit
            return false
        }
        set(row: edit.row, column: edit.column, to: value)
        cellEdit = nil
        return true
    }

    /// Keeps a value pending for a cell (a page row's or a new row's).
    func set(row: Int, column: Int, to value: SQLTableEdits.Value) {
        if let new = newRow(row) {
            changes.setNew(row: new, column: column, to: value)
        } else if let original = original(row: row, column: column) {
            changes.set(row: row, column: column, to: value, original: original)
        }
        report = nil
        refreshDisplay()
    }

    func revert(row: Int, column: Int) {
        if let new = newRow(row) {
            changes.setNew(row: new, column: column, to: nil)
        } else {
            changes.revert(row: row, column: column)
        }
        refreshDisplay()
    }

    /// Add Row: an empty new row, at the end; the database fills what is left out.
    func addRow() {
        changes.addRow()
        report = nil
        refreshDisplay()
    }

    /// Delete Rows: page rows are marked for deletion; new rows are dropped.
    func delete(rows: [Int]) {
        let pageRows = rows.filter { pageRow($0) != nil }
        for new in rows.compactMap(newRow).sorted(by: >) { changes.removeNewRow(new) }
        changes.delete(rows: pageRows)
        report = nil
        selectedRows = []
        refreshDisplay()
    }

    func restore(row: Int) {
        changes.restore(row: row)
        refreshDisplay()
    }

    func discardChanges() {
        changes = SQLTableEdits.Changes()
        isReviewing = false
        refreshDisplay()
    }

    /// The statements Apply runs, or why the changes can't become statements.
    var statements: Result<[SQLTableEdits.Statement], SQLTableEdits.Problem> {
        SQLTableEdits.statements(changes, table: table.name, columns: columns, rows: page?.rows ?? [], dialect: dialect, offset: pageOffset)
    }

    private func refreshDisplay() {
        let shown = SQLTableEdits.display(columns: columns.map(\.name), rows: page?.rows ?? [], offset: pageOffset, changes: changes)
        display = shown.table
        marks = shown.marks
    }
}

extension AppModel {
    /// Browse Table from the schema explorer: a window on one table of the explorer's connection,
    /// which reads its first page at once (production asks first).
    func browseSchemaTable(_ table: SQLSchemaInfo.Table, schema: SQLSchemaInfo, from tab: TabModel) {
        let choice = explorerConnection(for: tab)
        if case .missing(let name) = choice {
            alert = AppAlert(title: "The saved connection isn't defined", message: SQLConnectionChoice.missingMessage(name))
            return
        }
        guard let dialect = SQLTableBrowse.Dialect(driver: schema.driver, source: schema.source) else {
            alert = AppAlert(title: "Browse Table doesn't support this database",
                             message: "Browse Table writes SQL for MySQL, MariaDB, PostgreSQL, SQLite, and SQL Server, and this connection is \(schema.driver ?? schema.source ?? "of an unknown kind"). Open the table in an SQL tab instead.")
            return
        }
        let saved = choice.savedConnection
        let refusal = SQLTableEdits.refusal(table: table, driver: schema.driver, source: schema.source, readOnlyConnection: saved?.readOnly == true ? saved?.name : nil)
        let browser = TableBrowser(table: table, dialect: dialect, driver: schema.driver, source: schema.source, target: tab.target, connection: choice, tab: tab,
                                   openedFrom: saved.map { openedFromLabel($0, tabTarget: tab.target) } ?? targetLabel(tab.target),
                                   editRefusal: refusal, isProduction: isProduction(tab.target, connection: saved))
        ResultWindows.openBrowser(browser)
        loadTablePage(browser, offset: 0)
    }

    /// Reads the page at `offset` with the browser's sort and filter rules (production asks first).
    /// Pending changes must be applied or discarded first: they belong to the rows shown.
    /// - Parameter keepReport: the read after an Apply keeps what Apply did on screen.
    func loadTablePage(_ browser: TableBrowser, offset: Int, keepReport: Bool = false) {
        guard !browser.isBusy else { return }
        guard !browser.hasChanges else {
            browser.report = TableBrowser.ApplyReport(succeeded: false, message: "Apply or discard your changes first: they belong to the rows shown.")
            return
        }
        let query: SQLTableBrowse.Query
        switch SQLTableBrowse.query(browser.request(offset: offset)) {
        case .failure(let refusal):
            browser.phase = .failed(refusal.description)
            browser.lastEvent = "refused: \(refusal.description)"
            return
        case .success(let built):
            query = built
        }
        guard let tab = browser.tab, tab.target == browser.target else {
            browser.phase = .failed("The tab this table was opened from is closed or on another target now. Browse the table again from the Database pane.")
            return
        }
        let saved = browser.connection.savedConnection
        if let saved, library.databaseConnection(saved.id) != saved {
            browser.phase = .failed("The saved connection “\(saved.name)” changed or was removed since the table was opened. Browse the table again from the Database pane.")
            return
        }
        let filters = browser.serverFilters.filter { !$0.isIncomplete }
        guardProduction(.sql, target: browser.target, text: query.display, sqlConnection: tableConnectionLabel(browser), sqlSaved: saved != nil, savedConnection: saved,
                        sqlTable: .browse(table: browser.table.name, rows: query.rowsText), in: window(containing: tab.id)) { [weak self, weak browser] in
            guard let self, let browser, !browser.isBusy, !browser.hasChanges else { return }
            self.startTableRun(browser, code: SQLTabRun.browseCode(query, connection: browser.connection.ref?.appName, driver: browser.driver), purpose: .browse("\(browser.table.name): \(query.rowsText)"),
                               statement: query.sql, phase: .loading(query.rowsText), keepReport: keepReport) { [weak browser] outcome in
                guard let browser else { return }
                switch outcome {
                case .finished(let results, _, let errors):
                    if let result = results.last {
                        browser.loaded(result, offset: offset, filters: filters)
                        browser.lastEvent = "page \(query.rowsText): \(result.rows.count) rows, more=\(result.truncated == true)"
                    } else {
                        let message = errors.first ?? "The page ended without rows."
                        browser.phase = .failed(message)
                        browser.lastEvent = "failed: \(message)"
                    }
                case .stopped(let note, _):
                    browser.phase = .failed("Stopped. The page wasn't read." + (note.map { " " + $0 } ?? ""))
                    browser.lastEvent = "stopped"
                }
            }
        }
    }

    /// Review Changes' Apply: the statements in one transaction (production asks first, listing
    /// every statement), then one Run History entry, and the page read again (on production, the
    /// window offers Reload instead: nothing reads by itself there).
    func applyTableChanges(_ browser: TableBrowser) {
        guard !browser.isBusy, browser.hasChanges, browser.canEdit else { return }
        let statements: [SQLTableEdits.Statement]
        switch browser.statements {
        case .failure(let problem):
            browser.report = TableBrowser.ApplyReport(succeeded: false, message: problem.description)
            return
        case .success(let built):
            statements = built
        }
        guard let tab = browser.tab, tab.target == browser.target else {
            browser.report = TableBrowser.ApplyReport(succeeded: false, message: "The tab this table was opened from is closed or on another target now. Nothing was applied.")
            return
        }
        let saved = browser.connection.savedConnection
        if let saved, library.databaseConnection(saved.id) != saved {
            browser.report = TableBrowser.ApplyReport(succeeded: false, message: "The saved connection “\(saved.name)” changed or was removed since the table was opened. Nothing was applied.")
            return
        }
        let checks = statements.enumerated().map { index, statement in
            SQLStatementCheck(index: index + 1, line: index + 1, text: statement.display, warning: statement.kind.rawValue.uppercased(), caption: statement.label)
        }
        let history = SQLTableEdits.historyCode(statements, table: browser.table.name)
        let target = browser.target
        let marking = library.marking(for: target, connection: saved)
        let historyConnection: SQLConnectionReference = saved.map(SQLConnectionReference.init) ?? .application(browser.connection.ref?.appName)
        browser.isReviewing = false
        guardProduction(.sql, target: target, text: history, sqlWarning: "These statements change data.", sqlConnection: tableConnectionLabel(browser), sqlSaved: saved != nil, savedConnection: saved,
                        sqlStatements: checks, sqlTransaction: true, sqlTable: .apply(table: browser.table.name, count: statements.count), in: window(containing: tab.id)) { [weak self, weak browser] in
            guard let self, let browser, !browser.isBusy, browser.hasChanges else { return }
            self.startTableRun(browser, code: SQLTabRun.applyCode(statements, connection: browser.connection.ref?.appName, driver: browser.driver),
                               purpose: .applyEdits("\(browser.table.name): \(statements.count == 1 ? "1 change" : "\(statements.count) changes")"),
                               statement: statements.first?.sql, phase: .applying(statements.count)) { [weak self, weak browser] outcome in
                guard let self, let browser else { return }
                let finished: FinishedInfo? = switch outcome {
                case .finished(_, let finished, _): finished
                case .stopped(_, let finished): finished
                }
                if let finished {
                    self.recordHistory(HistoryEntry(runId: UUID(), code: history, target: target, targetLabel: browser.openedFrom, status: finished.status, reason: finished.reason, elapsedMs: finished.elapsedMs,
                                                    language: .sql, targetEnvironment: marking.environment, targetColor: marking.color, connection: historyConnection))
                }
                switch outcome {
                case .finished(let results, _, let errors):
                    if let error = errors.first {
                        browser.phase = .idle
                        let hint = error.contains("row not found") ? " Your changes are still pending: discard them and reload the page to see the rows as they are now." : ""
                        browser.report = TableBrowser.ApplyReport(succeeded: false, message: error.replacingOccurrences(of: "\n\n", with: " ") + hint)
                        browser.lastEvent = "apply failed: \(error)"
                        return
                    }
                    let affected = results.compactMap(\.affectedRows).reduce(0, +)
                    let message = "Applied \(statements.count == 1 ? "1 change" : "\(statements.count) changes") in one transaction: \(affected.formatted()) row\(affected == 1 ? "" : "s") affected."
                    browser.discardChanges()
                    browser.phase = .idle
                    browser.lastEvent = "applied: \(message)"
                    if browser.isProduction {
                        browser.report = TableBrowser.ApplyReport(succeeded: true, message: message + " Reload to read the page again.")
                    } else {
                        browser.report = TableBrowser.ApplyReport(succeeded: true, message: message)
                        self.loadTablePage(browser, offset: browser.pageOffset, keepReport: true)
                    }
                case .stopped(let note, _):
                    browser.phase = .idle
                    browser.report = TableBrowser.ApplyReport(succeeded: false, message: "Stopped. The transaction wasn't committed, so the database rolls it back." + (note.map { " " + $0 } ?? ""))
                    browser.lastEvent = "apply stopped"
                }
            }
        }
    }

    func stopTableBrowser(_ browser: TableBrowser) {
        browser.stop?()
    }

    /// "the saved connection “Shop” (sqlite, shop.sqlite) from this Mac", "the default connection".
    func tableConnectionLabel(_ browser: TableBrowser) -> String {
        switch browser.connection {
        case .saved(let saved): "the saved connection “\(saved.name)” (\(saved.summary))" + savedConnectionPlace(saved)
        case .app(let name): SQLRunInfo.label(for: name)
        case .missing(let name): "the saved connection “\(name)”"
        }
    }

    /// How a Browse Table run ended.
    enum TableRunOutcome {
        /// Its `sql` results, how the run finished, and its errors' messages.
        case finished([SQLResultInfo], FinishedInfo?, [String])
        /// Stop, with what came of cancelling the statement on the server (#144), and how the run
        /// finished (nil when it hadn't started).
        case stopped(String?, FinishedInfo?)
    }

    /// Runs Browse Table's code in a fresh runner where the explorer's connection goes, like Load
    /// Next (#146): the saved connection's definition rides with the request, Stop cancels the
    /// statement on the server, and the Connection Manager (#180) lists it while it runs.
    private func startTableRun(_ browser: TableBrowser, code: String, purpose: DatabaseWork.Purpose, statement: String?, phase: TableBrowser.Phase, keepReport: Bool = false, done: @escaping (TableRunOutcome) -> Void) {
        guard let tab = browser.tab else { return }
        let saved = browser.connection.savedConnection
        let target = browser.target
        let inspector = inspectorOptions(for: target)
        let hints = saved == nil ? sessionHints[target.stableKey] ?? [:] : [:]
        browser.phase = phase
        if !keepReport { browser.report = nil }
        let runId = UUID()
        let engine = self.engine
        let task = Task { [weak self, weak tab, weak browser] in
            guard let self, let tab, let browser else { return }
            var results: [SQLResultInfo] = []
            var errors: [String] = []
            var finished: FinishedInfo?
            var cancelled: SQLCancelReport?
            do {
                let snapshot = try await self.sqlSnapshot(for: tab, saved: saved)
                defer { self.releaseSQLTunnel(snapshot) } // #143
                try Task.checkCancellation()
                // A pseudo tab id keeps the run apart from the tab's own runs.
                var request = RunRequest(runId: runId, tabId: UUID(), documentVersion: tab.documentVersion, target: snapshot, code: code, inspector: inspector, magicComments: false)
                request.sqlConnection = saved
                request.hints = hints
                let stream = try await engine.start(request)
                await withTaskCancellationHandler {
                    for await event in stream {
                        switch event.kind {
                        case .sql(let info): results.append(info)
                        case .error(let error): errors.append(TabModel.withoutRunnerLocation(error).message)
                        case .finished(let info): finished = info
                        case .sqlCancel(let report): cancelled = report
                        default: break
                        }
                    }
                } onCancel: {
                    Task { await engine.cancel(runId: runId) }
                }
            } catch is CancellationError {
            } catch {
                errors.append("\(error)")
            }
            browser.stop = nil
            if Task.isCancelled || finished?.status == .cancelled {
                done(.stopped(cancelled?.message, finished))
            } else {
                done(.finished(results, finished, errors))
            }
        }
        browser.stop = { [weak browser] in
            browser?.stop = nil
            // #144: stopping the run, rather than its task, keeps its events coming, so the window
            // can say whether the statement was cancelled on the server.
            Task { if await engine.cancel(runId: runId) == nil { task.cancel() } }
        }
        trackDatabaseWork(DatabaseWork(purpose: purpose, tabId: tab.id, tabTitle: tab.title, target: target, connection: browser.connection, statement: statement) { [weak browser] in
            browser?.stop?()
        }, until: task)
    }
}
