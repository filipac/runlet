import AppKit
import Observation
import RunletCore
import RunletExecution

/// Export Query to CSV (#152): one read statement's every row, streamed to a file on this Mac.
/// The sheet shows the options, then the progress with Stop, then the summary.
@MainActor
@Observable
final class SQLCSVExportJob: Identifiable {
    enum Phase: Equatable {
        case options
        case running
        case finished
        case failed(String)
        case stopped(String)
    }

    let id = UUID()
    let windowId: UUID?
    let tabId: UUID
    let tabTitle: String
    let target: TargetRef
    /// The statement, its connection, and its bound values (#145).
    let run: SQLRunInfo
    var options: SQLCSVExportOptions
    var destination: URL?
    var phase: Phase = .options
    var rows = 0
    /// Bytes written to the file so far.
    var bytes = 0
    var startedAt: Date?
    var endedAt: Date?
    /// Stops the export while it runs.
    @ObservationIgnored var stop: (() -> Void)?

    init(windowId: UUID?, tabId: UUID, tabTitle: String, target: TargetRef, run: SQLRunInfo, options: SQLCSVExportOptions) {
        self.windowId = windowId
        self.tabId = tabId
        self.tabTitle = tabTitle
        self.target = target
        self.run = run
        self.options = options
    }

    var statement: String { run.statements.first?.text ?? "" }

    var isRunning: Bool { phase == .running }

    var elapsed: TimeInterval? { startedAt.map { (endedAt ?? Date()).timeIntervalSince($0) } }

    /// "12,000 rows · 1.2 MB"
    var progressText: String {
        "\(rows.formatted()) row\(rows == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
    }
}

/// Import CSV (#152): a CSV file mapped onto a table from the schema explorer, previewed, then
/// inserted in one transaction.
@MainActor
@Observable
final class SQLCSVImportJob: Identifiable {
    enum Phase: Equatable {
        case mapping
        case running
        case finished
        case failed(String)
        case stopped(String)
    }

    let id = UUID()
    let windowId: UUID?
    let tabId: UUID
    let tabTitle: String
    let target: TargetRef
    let connection: SQLConnectionChoice
    let fileName: String
    /// The text, kept to parse it again with another delimiter.
    let text: String
    var plan: SQLCSVImport
    var phase: Phase = .mapping
    var inserted = 0
    /// The failure's data row and its line in the file.
    var failedRow: Int?
    var failedLine: Int?
    var startedAt: Date?
    var endedAt: Date?
    @ObservationIgnored var stop: (() -> Void)?

    init(windowId: UUID?, tabId: UUID, tabTitle: String, target: TargetRef, connection: SQLConnectionChoice, fileName: String, text: String, plan: SQLCSVImport) {
        self.windowId = windowId
        self.tabId = tabId
        self.tabTitle = tabTitle
        self.target = target
        self.connection = connection
        self.fileName = fileName
        self.text = text
        self.plan = plan
    }

    var isRunning: Bool { phase == .running }

    var elapsed: TimeInterval? { startedAt.map { (endedAt ?? Date()).timeIntervalSince($0) } }

    /// Another delimiter: the file is read again; a mapping by name is made again.
    func setDelimiter(_ delimiter: Character) {
        guard delimiter != plan.delimiter, let parsed = try? SQLCSVImport.parse(text, delimiter: delimiter, table: plan.table, tableColumns: plan.tableColumns, driver: plan.driver) else { return }
        var next = parsed
        next.emptyIsNull = plan.emptyIsNull
        plan = next
    }

    func setHeader(_ hasHeader: Bool) {
        guard hasHeader != plan.hasHeader else { return }
        plan.hasHeader = hasHeader
        plan.mapping = plan.autoMapping()
    }
}

/// The CSV sheets' state (#152), per app model: at most one export and one import at a time.
@MainActor
@Observable
final class SQLCSVStore {
    var export: SQLCSVExportJob?
    var importJob: SQLCSVImportJob?
    /// The last export's options, for the next one (in memory).
    var lastOptions = SQLCSVExportOptions()
    #if DEBUG
    /// DEBUG steps: a file the next export writes, instead of asking in the save panel.
    var debugDestination: URL?
    #endif

    private static var stores: [ObjectIdentifier: SQLCSVStore] = [:]

    static func shared(for model: AppModel) -> SQLCSVStore {
        let key = ObjectIdentifier(model)
        if let existing = stores[key] { return existing }
        let created = SQLCSVStore()
        stores[key] = created
        return created
    }
}

/// Export Query to CSV and Import CSV (#152). Both run in a fresh runner apart from the tab's
/// output, like Load Next: an export's rows go only to its file (never the output, Run History,
/// the Run Log, or an MCP result), and an import's rows only to the database. Each is one Run
/// History entry (the statement, never the data). Production asks once; a read-only connection
/// (#139) refuses imports; Stop cancels the statement on the server first (#144).
extension AppModel {
    var sqlCSV: SQLCSVStore { SQLCSVStore.shared(for: self) }

    // MARK: Export

    func exportCSVDisabledReason(for tab: TabModel?) -> String? {
        guard let tab, tab.language == .sql else { return "Export Query to CSV works in SQL tabs." }
        if sqlCSV.export != nil { return "An export is open." }
        return nil
    }

    /// Export Query to CSV…: the selected statement, or the one at the caret (or `statement`,
    /// from a result card), when it is a read Load Next could page. Opens the sheet; nothing
    /// runs until Export.
    func exportQueryToCSV(_ tab: TabModel, statement given: SQLScript.Statement? = nil) {
        guard tab.language == .sql, sqlCSV.export == nil else { return }
        let editor = tab.editor
        let text = editor.text
        let statement: SQLScript.Statement
        if let given {
            statement = given
        } else {
            switch SQLScript.statementToRun(in: text, selection: editor.selectedRange) {
            case .failure(let error):
                alert = AppAlert(title: error == .empty ? "No SQL to export" : error.title, message: error.description)
                return
            case .success(let found):
                statement = found
            }
        }
        if let refusal = SQLCSVExport.refusal(of: statement.text) {
            alert = AppAlert(title: "Runlet exports read statements only", message: refusal)
            return
        }
        let choice = sqlConnectionChoice(for: tab)
        if case .missing(let name) = choice {
            alert = AppAlert(title: "The saved connection isn't defined", message: SQLConnectionChoice.missingMessage(name))
            return
        }
        let target = tab.target
        let scan = SQLParameters.scan([statement], driver: sqlDriver(for: choice, target: target))
        if let problem = scan.problem {
            alert = AppAlert(title: problem.title, message: problem.description)
            return
        }
        var base = SQLRunInfo(statement: statement, connection: choice.ref?.appName, saved: choice.savedConnection)
        base.tunnelProfile = library.tunnelProfile(of: choice.savedConnection)?.name
        let inText = given == nil || (text as NSString).length >= NSMaxRange(statement.range) && (text as NSString).substring(with: statement.range) == statement.text
        withSQLParameterValues(scan, statements: [statement], in: tab, text: text, scope: .statement, action: "export") { [weak self, weak tab] values in
            guard let self, let tab, tab.target == target, self.sqlCSV.export == nil, let bindings = scan.bindings(values) else { return }
            var info = base
            info.bindings = bindings
            if !scan.isEmpty {
                info.values = scan.lines(values)
                if inText { info.historyCode = SQLParameters.historyCode(text, start: statement.range.location, end: NSMaxRange(statement.range), statements: [statement], scan: scan, values: values) }
            }
            self.sqlCSV.export = SQLCSVExportJob(windowId: self.window(containing: tab.id)?.id, tabId: tab.id, tabTitle: tab.title, target: target, run: info, options: self.sqlCSV.lastOptions)
        }
    }

    /// Export All Rows to CSV… under a cut result (#146's pager): the statement that ran, with
    /// the same connection and bound values.
    func exportResultToCSV(_ pager: SQLResultPager) {
        guard let tab = pager.tab, sqlCSV.export == nil, tab.target == pager.target, let statement = pager.run.statements.first else { return }
        if let refusal = SQLCSVExport.refusal(of: statement.text) {
            alert = AppAlert(title: "Runlet exports read statements only", message: refusal)
            return
        }
        if let saved = pager.run.saved, library.databaseConnection(saved.id) != saved {
            alert = AppAlert(title: "The saved connection changed", message: "The saved connection “\(saved.name)” changed or was removed since the statement ran. Run it again, then export.")
            return
        }
        sqlCSV.export = SQLCSVExportJob(windowId: window(containing: tab.id)?.id, tabId: tab.id, tabTitle: tab.title, target: pager.target, run: pager.run, options: sqlCSV.lastOptions)
    }

    /// Export… in the sheet: the save panel, then (on production) the confirmation, then the run.
    func chooseCSVExportFile(_ job: SQLCSVExportJob) {
        guard job.phase == .options else { return }
        #if DEBUG
        if let url = sqlCSV.debugDestination {
            sqlCSV.debugDestination = nil
            job.destination = url
            startCSVExport(job)
            return
        }
        #endif
        let panel = NSSavePanel()
        panel.title = "Export Query to CSV"
        panel.prompt = "Export"
        panel.nameFieldStringValue = job.destination?.lastPathComponent ?? SQLCSVExport.suggestedFileName(job.tabTitle)
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        job.destination = url
        startCSVExport(job)
    }

    private func startCSVExport(_ job: SQLCSVExportJob) {
        guard let destination = job.destination else { return }
        sqlCSV.lastOptions = job.options
        let run = job.run
        guardProduction(.sql, target: job.target, text: job.statement, sqlConnection: run.connectionLabel, sqlSaved: run.saved != nil, savedConnection: run.saved,
                        sqlValues: run.values.isEmpty ? nil : run.values, sqlExportFile: destination.lastPathComponent,
                        in: job.windowId.flatMap { id in windows.first { $0.id == id } }) { [weak self, weak job] in
            guard let self, let job, self.sqlCSV.export === job, job.phase == .options else { return }
            self.runCSVExport(job, to: destination)
        }
    }

    /// The outcome of the export's run, off the main thread.
    private struct ExportOutcome: Sendable {
        var finished: FinishedInfo?
        var errors: [RunErrorInfo] = []
        var done = false
        var rows = 0
        var bytes = 0
        var cancel: SQLCancelReport?
        var writeError: String?
    }

    private func runCSVExport(_ job: SQLCSVExportJob, to destination: URL) {
        guard let tab = csvTab(job.tabId) else {
            job.phase = .failed("The tab is closed.")
            return
        }
        let run = job.run
        let target = job.target
        let options = job.options
        let marking = library.marking(for: target, connection: run.saved)
        let code = SQLCSVExport.code(statement: job.statement, connection: run.connection, bindings: run.bindings.first ?? [])
        let inspector = inspectorOptions(for: target)
        let hints = run.saved == nil ? sessionHints[target.stableKey] ?? [:] : [:]
        let runId = UUID()
        let engine = self.engine
        job.phase = .running
        job.startedAt = Date()
        job.rows = 0
        job.bytes = 0
        let progress: @Sendable (Int, Int) async -> Void = { rows, bytes in
            await MainActor.run {
                job.rows = rows
                job.bytes = bytes
            }
        }
        let task = Task { [weak self, weak job] in
            guard let self else { return }
            var outcome = ExportOutcome()
            var label = ""
            do {
                let snapshot = try await self.sqlSnapshot(for: tab, saved: run.saved)
                defer { self.releaseSQLTunnel(snapshot) } // #143
                label = snapshot.label
                try Task.checkCancellation()
                var request = RunRequest(runId: runId, tabId: UUID(), documentVersion: tab.documentVersion, target: snapshot, code: code, inspector: inspector, magicComments: false)
                request.sqlConnection = run.saved
                request.hints = hints
                let stream = try await engine.start(request)
                // The frames are written off the main thread, one at a time.
                outcome = await withTaskCancellationHandler {
                    await Task.detached(priority: .userInitiated) {
                        await Self.writeExport(stream, to: destination, options: options, progress: progress)
                    }.value
                } onCancel: {
                    Task { await engine.cancel(runId: runId) }
                }
            } catch is CancellationError {
            } catch {
                outcome.errors.append(RunErrorInfo(stage: .launch, message: "\(error)"))
            }
            let history = "-- Export Query to CSV: \(outcome.done ? "\(outcome.rows.formatted()) rows" : "stopped") to \(destination.lastPathComponent)\n" + run.historyCode
            if let finished = outcome.finished {
                self.recordHistory(HistoryEntry(runId: runId, code: history, target: target, targetLabel: label, status: finished.status, reason: finished.reason, elapsedMs: finished.elapsedMs, language: .sql, targetEnvironment: marking.environment, targetColor: marking.color, connection: run.historyConnection))
            }
            guard let job else { return }
            job.stop = nil
            job.endedAt = Date()
            job.rows = outcome.rows
            job.bytes = outcome.bytes
            if outcome.done {
                job.phase = .finished
            } else if Task.isCancelled || outcome.finished?.status == .cancelled {
                job.phase = .stopped("Stopped after \(outcome.rows.formatted()) row\(outcome.rows == 1 ? "" : "s"). Runlet deleted the partial file\(FileManager.default.fileExists(atPath: destination.path) ? "; the file that was there stays as it was" : "")." + (outcome.cancel.map { " " + $0.message } ?? ""))
            } else {
                let message = outcome.writeError ?? outcome.errors.first(where: { $0.interruptedByStop != true })?.message ?? "The export ended without its last rows."
                job.phase = .failed(message + " Runlet deleted the partial file; nothing was written to \(destination.lastPathComponent).")
            }
        }
        job.stop = { [weak job] in
            job?.stop = nil
            // #144: stopping the run (not its task) cancels the statement on the server first.
            Task { if await engine.cancel(runId: runId) == nil { task.cancel() } }
        }
        trackDatabaseWork(DatabaseWork(purpose: .csv("Export Query to CSV: \(destination.lastPathComponent)"), tabId: job.tabId, tabTitle: job.tabTitle, target: target,
                                       connection: run.saved.map { .saved($0) } ?? .app(run.connection), statement: job.statement) { [weak job] in
            job?.stop?()
        }, until: task)
    }

    /// Writes the frames of an export's run to its file as they arrive, then moves it into
    /// place; anything short of the last frame deletes it.
    private nonisolated static func writeExport(_ stream: AsyncStream<RunEvent>, to destination: URL, options: SQLCSVExportOptions, progress: @escaping @Sendable (Int, Int) async -> Void) async -> ExportOutcome {
        var outcome = ExportOutcome()
        let writer: SQLCSVExportWriter
        do {
            writer = try SQLCSVExportWriter(destination: destination, options: options)
        } catch {
            outcome.writeError = "Runlet could not write next to \(destination.lastPathComponent): \(error.localizedDescription)"
            for await event in stream { if case .finished(let info) = event.kind { outcome.finished = info } }
            return outcome
        }
        var lastReport = Date.distantPast
        for await event in stream {
            switch event.kind {
            case .sqlExport(let frame):
                guard outcome.writeError == nil else { continue }
                do {
                    try writer.write(frame)
                } catch {
                    outcome.writeError = "Runlet could not write \(destination.lastPathComponent): \(error.localizedDescription)"
                }
                if frame.done == true { outcome.done = true }
                if Date().timeIntervalSince(lastReport) > 0.1 {
                    lastReport = Date()
                    await progress(writer.rows, writer.bytes)
                }
            case .error(let error): outcome.errors.append(error)
            case .sqlCancel(let report): outcome.cancel = report
            case .finished(let info): outcome.finished = info
            default: break
            }
        }
        outcome.rows = writer.rows
        outcome.bytes = writer.bytes
        if outcome.done, outcome.writeError == nil, outcome.errors.isEmpty {
            do {
                try writer.finish()
            } catch {
                outcome.done = false
                outcome.writeError = "Runlet could not save \(destination.lastPathComponent): \(error.localizedDescription)"
                writer.abandon()
            }
        } else {
            outcome.done = false
            writer.abandon()
        }
        return outcome
    }

    func stopCSVExport() {
        sqlCSV.export?.stop?()
    }

    /// Cancel or Done: closes the sheet (Stop first while it runs).
    func closeCSVExport() {
        guard let job = sqlCSV.export else { return }
        if job.isRunning { job.stop?() }
        sqlCSV.export = nil
    }

    func revealCSVExport() {
        guard let url = sqlCSV.export?.destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Import

    /// Import CSV… on a table in the schema explorer: refused on views and read-only
    /// connections (#139); otherwise the open panel, then the sheet with the mapping and the
    /// preview. Nothing is inserted until Import.
    func importCSV(into table: SQLSchemaInfo.Table, schema: SQLSchemaInfo, from tab: TabModel) {
        guard sqlCSV.importJob == nil else { return }
        let choice = explorerConnection(for: tab)
        if case .missing(let name) = choice {
            alert = AppAlert(title: "The saved connection isn't defined", message: SQLConnectionChoice.missingMessage(name))
            return
        }
        if table.isView {
            alert = AppAlert(title: "Import CSV imports into tables", message: "\(table.name) is a view. Choose the table its rows come from.")
            return
        }
        if let saved = choice.savedConnection, saved.readOnly {
            alert = AppAlert(title: SQLReadOnlyRefusal.title(connection: saved.name), message: "“\(saved.name)” is a read-only connection, so Runlet won't import into \(table.name): an import inserts rows. Nothing ran.")
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Import CSV into \(table.name)"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openCSVImport(url, into: table, schema: schema, from: tab)
    }

    /// Reads and parses the file (refused past the limits), then shows the sheet.
    func openCSVImport(_ url: URL, into table: SQLSchemaInfo.Table, schema: SQLSchemaInfo, from tab: TabModel) {
        let choice = explorerConnection(for: tab)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= SQLCSVImport.maxFileBytes else {
            alert = AppAlert(title: "The file is too large to import", message: SQLCSVImport.Problem.tooLarge(bytes: size).description)
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            alert = AppAlert(title: "Runlet could not read the file", message: url.lastPathComponent)
            return
        }
        guard let text = String(data: data, encoding: .utf8) else {
            alert = AppAlert(title: "The file isn't UTF-8 text", message: SQLCSVImport.Problem.notText.description)
            return
        }
        do {
            let plan = try SQLCSVImport.parse(text, table: table.name, tableColumns: table.columns, driver: schema.driver)
            sqlCSV.importJob = SQLCSVImportJob(windowId: window(containing: tab.id)?.id, tabId: tab.id, tabTitle: tab.title, target: tab.target, connection: choice, fileName: url.lastPathComponent, text: text, plan: plan)
        } catch {
            alert = AppAlert(title: "Runlet can't import this file", message: "\(error)")
        }
    }

    /// Import in the sheet: on production the confirmation (with the row count and the table),
    /// then the run.
    func startCSVImport(_ job: SQLCSVImportJob) {
        guard job.phase == .mapping || isRetryable(job.phase) else { return }
        if let problem = job.plan.problem {
            job.phase = .failed(problem)
            return
        }
        let saved = job.connection.savedConnection
        if let saved, saved.readOnly { // #139
            job.phase = .failed("“\(saved.name)” is a read-only connection, so Runlet won't import into it. Nothing ran.")
            return
        }
        let rows = job.plan.rowCount
        let label = saved.map { "the saved connection “\($0.name)” (\($0.summary))" } ?? job.connection.label
        guardProduction(.sql, target: job.target, text: job.plan.insertStatement, sqlWarning: "Import CSV inserts \(rows.formatted()) row\(rows == 1 ? "" : "s") into \(job.plan.table).",
                        sqlConnection: label, sqlSaved: saved != nil, savedConnection: saved,
                        sqlImport: SQLImportCheck(rows: rows, table: job.plan.table, file: job.fileName),
                        in: job.windowId.flatMap { id in windows.first { $0.id == id } }) { [weak self, weak job] in
            guard let self, let job, self.sqlCSV.importJob === job, !job.isRunning else { return }
            self.runCSVImport(job)
        }
    }

    private func isRetryable(_ phase: SQLCSVImportJob.Phase) -> Bool {
        if case .failed = phase { return true }
        if case .stopped = phase { return true }
        return false
    }

    private func runCSVImport(_ job: SQLCSVImportJob) {
        guard let tab = csvTab(job.tabId) else {
            job.phase = .failed("The tab is closed.")
            return
        }
        let plan = job.plan
        let target = job.target
        let saved = job.connection.savedConnection
        let appName = job.connection.ref?.appName
        let marking = library.marking(for: target, connection: saved)
        let code = plan.code(connection: appName)
        let inspector = inspectorOptions(for: target)
        let hints = saved == nil ? sessionHints[target.stableKey] ?? [:] : [:]
        let history = plan.historyCode(fileName: job.fileName)
        let historyConnection: SQLConnectionReference = saved.map(SQLConnectionReference.init) ?? .application(appName)
        let runId = UUID()
        let engine = self.engine
        job.phase = .running
        job.inserted = 0
        job.failedRow = nil
        job.failedLine = nil
        job.startedAt = Date()
        job.endedAt = nil
        let task = Task { [weak self, weak job] in
            guard let self else { return }
            var report: SQLImportReport?
            var errors: [RunErrorInfo] = []
            var finished: FinishedInfo?
            var cancelled: SQLCancelReport?
            var label = ""
            do {
                let snapshot = try await self.sqlSnapshot(for: tab, saved: saved)
                defer { self.releaseSQLTunnel(snapshot) } // #143
                label = snapshot.label
                try Task.checkCancellation()
                var request = RunRequest(runId: runId, tabId: UUID(), documentVersion: tab.documentVersion, target: snapshot, code: code, inspector: inspector, magicComments: false)
                request.sqlConnection = saved
                request.hints = hints
                let stream = try await engine.start(request)
                await withTaskCancellationHandler {
                    for await event in stream {
                        switch event.kind {
                        case .sqlImport(let next):
                            report = next
                            if next.failedRow == nil, next.rolledBack == nil { job?.inserted = next.inserted }
                        case .error(let error): errors.append(TabModel.withoutRunnerLocation(error))
                        case .sqlCancel(let next): cancelled = next
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
                self.recordHistory(HistoryEntry(runId: runId, code: history, target: target, targetLabel: label, status: finished.status, reason: finished.reason, elapsedMs: finished.elapsedMs, language: .sql, targetEnvironment: marking.environment, targetColor: marking.color, connection: historyConnection))
            }
            guard let job else { return }
            job.stop = nil
            job.endedAt = Date()
            if report?.done == true, finished?.status == .completed {
                job.inserted = report?.inserted ?? job.inserted
                job.phase = .finished
                // The table has more rows now: the schema's estimate reads again on Reload.
            } else if Task.isCancelled || finished?.status == .cancelled {
                job.phase = .stopped("Stopped. The transaction was rolled back (or ends with its connection), so no rows were imported." + (cancelled.map { " " + $0.message } ?? ""))
            } else {
                job.failedRow = report?.failedRow
                job.failedLine = report?.failedRow.flatMap(plan.line(ofRow:))
                let message = report?.message ?? errors.first(where: { $0.interruptedByStop != true })?.message ?? "The import ended without committing."
                let place = job.failedLine.map { line in "Line \(line.formatted()) of \(job.fileName) (row \((job.failedRow ?? 0).formatted())) failed: " } ?? ""
                let undone = report?.rolledBack == true ? " Rolled back the transaction: no rows were imported." : report == nil ? "" : " The transaction wasn't committed."
                job.phase = .failed(place + message + undone)
            }
        }
        job.stop = { [weak job] in
            job?.stop = nil
            Task { if await engine.cancel(runId: runId) == nil { task.cancel() } }
        }
        trackDatabaseWork(DatabaseWork(purpose: .csv("Import CSV: \(job.fileName) into \(plan.table)"), tabId: job.tabId, tabTitle: job.tabTitle, target: target,
                                       connection: job.connection, statement: plan.insertStatement) { [weak job] in
            job?.stop?()
        }, until: task)
    }

    func stopCSVImport() {
        sqlCSV.importJob?.stop?()
    }

    func closeCSVImport() {
        guard let job = sqlCSV.importJob else { return }
        if job.isRunning { job.stop?() }
        sqlCSV.importJob = nil
    }

    private func csvTab(_ id: UUID) -> TabModel? {
        window(containing: id)?.tabs.first { $0.id == id }
    }
}
