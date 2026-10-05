import AppKit
import Observation
import RunletCore
import RunletLanguage

extension MailRecord {
    /// What happened to the message: sent, intercepted, queued, or failed.
    var statusLabel: String {
        if queued { return "Mail queued" + (queueConnection.map { " on \($0)" } ?? "") + " (a queue worker sends it)" }
        if failed { return "Mail failed" }
        return intercepted ? "Mail intercepted (not sent)" : "Mail sent"
    }
}

/// One item in a tab's output pane, in execution order.
enum OutputItem: Identifiable, Equatable {
    case header(id: Int, label: String, startedAt: Date)
    /// Printed output (stdout or stderr), in pieces so long output stays fast (#82).
    case text(id: Int, stream: Stream, text: ChunkedText)
    case dump(id: Int, DumpInfo, editorLine: Int?)
    case result(id: Int, ResultInfo)
    case error(id: Int, RunErrorInfo, editorLine: Int?)
    case notice(id: Int, String)
    /// Something the user should not miss, such as mail interception that no driver supports.
    case warning(id: Int, String)
    /// A card the snippet asked for (#196): `\Runlet\notice()`, `warning()`, or `error()`. Never a
    /// failure; `editorLine` is the editor line that called it.
    case snippetMessage(id: Int, SnippetMessage, editorLine: Int?)
    /// Mail the run sent, intercepted, or queued (details in the inspector's Mail section).
    case mail(id: Int, MailRecord, recordIndex: Int)
    /// A benchmark card (`Runlet\bench()`, Laravel's `Benchmark::dd()`); also in the Benchmarks section.
    case benchmark(id: Int, InspectorRecord)
    /// A Profile Run's samples (the flame graph is in the Profile section).
    case profile(id: Int, ProfileSummary)
    /// An SQL tab's result set or affected-row count (#35).
    case sql(id: Int, SQLResultInfo)
    /// Explain Statement's plan (#147).
    case sqlPlan(id: Int, SQLPlanInfo)
    /// A Redis tab's reply (#190).
    case redis(id: Int, RedisReplyInfo)
    /// Rollback mode (#13): a dry run's warning, or its outcome ("Rolled back 3 statements on
    /// mysql"). `editorLine` is the editor line of a warning's statement.
    case rollback(id: Int, RollbackReport, editorLine: Int?)
    case finished(id: Int, FinishedInfo)

    enum Stream: String { case stdout, stderr }

    var id: Int {
        switch self {
        case .header(let id, _, _), .text(let id, _, _), .dump(let id, _, _), .result(let id, _),
             .error(let id, _, _), .notice(let id, _), .warning(let id, _), .snippetMessage(let id, _, _), .mail(let id, _, _), .benchmark(let id, _), .profile(let id, _), .sql(let id, _), .sqlPlan(let id, _), .redis(let id, _), .rollback(let id, _, _), .finished(let id, _):
            id
        }
    }

    /// Plain-text rendering used by Copy Output.
    var plainText: String { plainText(display: .object) }

    /// Plain-text rendering used by Copy Output; `display` (#307) picks the tree of a value that
    /// holds Eloquent models.
    func plainText(display: ModelDisplay) -> String {
        switch self {
        case .header(_, let label, let date):
            return "▶ \(label) — \(date.formatted(date: .omitted, time: .standard))"
        case .text(_, _, let text):
            return text.string
        case .dump(_, let dump, let line):
            let location = line.map { " (line \($0))" } ?? dump.file.map { " (\($0):\(dump.line ?? 0))" } ?? ""
            return "\(dump.isDD ? "dd" : "dump")\(location):\n" + dump.node(for: display).plainText()
        case .result(_, let result):
            return result.hasValue ? "=> " + (result.node(for: display)?.plainText() ?? "") : "(no result)"
        case .error(_, let error, let line):
            var text = "\(error.className ?? "Error") [\(error.stage.rawValue)]: \(error.message)"
            if let line { text += " (line \(line))" } else if let file = error.file { text += " (\(file):\(error.line ?? 0))" }
            return text
        case .notice(_, let text):
            return "ℹ︎ \(text)"
        case .warning(_, let text):
            return "⚠︎ \(text)"
        case .snippetMessage(_, let message, let line):
            return message.level.symbol + " " + message.summary(line: line)
        case .mail(_, let mail, _):
            return "✉︎ \(mail.statusLabel): \(mail.summary)"
        case .benchmark(_, let record):
            return "⏱︎ \(record.title ?? "Benchmark"):\n" + (record.benchmark?.plainSummary ?? "")
        case .profile(_, let summary):
            return "≋ \(summary.text)"
        case .sql(_, let result):
            return result.plainText
        case .sqlPlan(_, let plan):
            return plan.plainText
        case .redis(_, let reply):
            return reply.plainText
        case .rollback(_, let report, let line):
            return "↺ " + (report.state == .warning ? report.title + (line.map { " (line \($0))" } ?? "") : report.plainText)
        case .finished(_, let info):
            return "■ \(info.status.rawValue) (\(info.reason)) in \(info.elapsedMs) ms" + (info.exitCode.map { ", exit \($0)" } ?? "")
        }
    }
}

enum RunState: Equatable {
    case idle
    case preparing
    case running(runId: UUID, startedAt: Date)
    case stopping(runId: UUID, startedAt: Date)
    case finished(FinishedInfo)

    var isActive: Bool {
        switch self {
        case .preparing, .running, .stopping: true
        default: false
        }
    }

    var runId: UUID? {
        switch self {
        case .running(let id, _), .stopping(let id, _): id
        default: nil
        }
    }
}

/// Facts from the most recent run, shown in the status bar.
struct RunSummary: Equatable {
    var targetLabel: String
    var phpVersion: String?
    var framework: String?
    var frameworkVersion: String?
    var driverName: String?
    var workingDirectory: String?
}

@MainActor
@Observable
final class TabModel: Identifiable {
    let id: UUID
    var title: String
    var target: TargetRef {
        didSet { if target != oldValue { setAutoRunEnabled(false) } }
    }
    var fileURL: URL?
    /// PHP or SQL (#35). Change it with `AppModel.setLanguage(_:for:)`, which also rebinds
    /// the language server (SQL tabs have none).
    private(set) var language: TabLanguage
    /// An SQL tab's connection name; nil for the application's default connection.
    var sqlConnection: String?
    /// A saved connection the SQL tab uses instead (#138): its id, and its name to find it on
    /// another target or to say which one is missing. Resolve with `AppModel.sqlConnectionChoice`.
    var sqlSavedConnection: UUID?
    var sqlSavedConnectionName: String?
    /// Run All Statements (#129) runs the script in one transaction (the default).
    var sqlTransaction = true
    /// #190: Run All in a Redis tab wraps the commands in MULTI/EXEC (off by default).
    var redisTransaction = false
    /// #13: Dry Run: this PHP tab's runs roll back their database changes. Saved with the tab;
    /// change it with `AppModel.setRollback(_:for:)`. Turning it on runs nothing.
    var rollback = false
    /// #279: pinned first in its window and kept by Close Other Tabs and Close Tabs to the
    /// Right. Saved with the tab; change it with `AppModel.setPinned(_:for:)`, which also moves it.
    private(set) var isPinned = false
    /// #307: Values | Object for Eloquent models in this tab's output, once a card switched it;
    /// nil follows Settings. Saved with the tab; change it with `AppModel.setModelDisplay(_:for:)`.
    var modelDisplay: ModelDisplay?
    /// Settings' default for `modelDisplay`, and the inline-value panel's switch, set by
    /// `AppModel` when it adds the tab.
    @ObservationIgnored var defaultModelDisplay: () -> ModelDisplay = { .values }
    @ObservationIgnored var onModelDisplayPick: ((ModelDisplay) -> Void)?
    /// How this tab shows Eloquent models now.
    var shownModelDisplay: ModelDisplay { modelDisplay ?? defaultModelDisplay() }
    /// The SQL bar's note after opening a history entry or snippet whose saved connection no
    /// longer exists (#149). Not saved; choosing a connection or dismissing it clears it.
    var sqlConnectionNote: String?
    /// SQL completion (#128) for this tab's editor, from its target's and connection's schema.
    /// Set by `AppModel.bindLanguage`; used only while the tab is an SQL tab.
    var sqlCompletionProvider: ((String, Int) -> SQLCompletion.Result?)?
    /// #206: a completion item's action (Redis's Load Keys for Completion), and hover text for
    /// a tab without a language server (a Redis command's syntax). Set by `AppModel.bindLanguage`.
    var completionActionHandler: ((String) -> Void)?
    var hoverProvider: ((String, Int) -> String?)?
    /// Last persisted/observed text; the live text lives in the editor.
    private(set) var code: String
    private(set) var documentVersion = 1
    var isFileDirty = false

    /// #30: session-only opt-in; deliberately absent from TabState/workspaces.
    private(set) var autoRunEnabled = false
    @ObservationIgnored private var autoRunTask: Task<Void, Never>?
    @ObservationIgnored var onEditorEdit: (() -> Void)?
    /// Format Code (#36): why the last formatting left the text as it was, shown above the
    /// editor until the next edit or a dismissal.
    var formatIssue: String?
    /// Format Code (#36) is waiting for the formatter (Run waits too, with format before run).
    var isFormatting = false
    /// Escape in the editor that the editor itself didn't need (#60); returns whether it was used.
    @ObservationIgnored var onEditorEscape: (() -> Bool)?
    /// #25: the Quick Run panel's tab, in no window. Its runs are marked Quick Run in History, and
    /// it never runs on production. Open in Tab moves it into a window, as an ordinary tab.
    @ObservationIgnored var isQuickRun = false

    var runState: RunState = .idle
    var output: [OutputItem] = []
    /// The current run's inspector records: queries, mail, logs, and driver sections.
    var inspection = RunInspection()
    /// #9: completion metrics survive clearing the inspector/output until the next run.
    private(set) var finishedQueryCount = 0
    private(set) var finishedQueryTimeMs: Double = 0
    /// #196: the snippet's notice, warning, and error cards, for the run's footer.
    private(set) var finishedMessageCounts = SnippetMessageCounts()
    /// #4: output can outlive a target switch; Explain belongs to the run's target.
    private(set) var inspectionTarget: TargetRef?
    var lastRun: RunSummary?
    /// The output pane's section: nil for the output, else an inspector section ("Queries", …).
    var outputSection: String?
    /// #5: inspector records whose details are open (HTTP and job rows), by index; the run's
    /// records clear them.
    var expandedRecords: Set<Int> = []
    /// This tab's part of `OutputPaneVisibility` (#60; see `AppModel+OutputPane`), never saved:
    /// a run revealed the pane (used by Hide the output pane until a run, so opened and restored
    /// tabs start hidden), and Escape hid it until the next run.
    var outputPaneRevealed = false
    var outputPaneDismissed = false
    /// The current run's diagnostic log (Run ▸ Show Run Log): launch command, runner steps,
    /// stderr, errors, and how the process ended. Capped at `maxRunLogLines`.
    var runLog: [RunLogLine] = []
    @ObservationIgnored private var runLogStartedAt = Date()
    static let maxRunLogLines = 500
    var targetIssue: String?
    var stopMessage: String?

    var languageState: LanguageServerState = .stopped
    var languageNotes: [String] = []
    @ObservationIgnored var languageWorkspace: LanguageWorkspace?
    @ObservationIgnored var languageStateTask: Task<Void, Never>?

    @ObservationIgnored private(set) var preparationID: UUID?
    @ObservationIgnored private(set) var currentRequest: RunRequest?
    /// When the current run's output reaches the tab: as it arrives, or held until it ends (#82).
    @ObservationIgnored private var outputGate = RunEventGate(delivery: .realtime)
    /// The current run's output appears when it ends (Settings ▸ General ▸ Output: At once).
    private(set) var holdsOutputUntilEnd = false
    /// The current run shows magic-comment values (off in Settings, or for Profile Run).
    @ObservationIgnored private var showsInlineValues = false
    /// The current run is an SQL tab's statement (#35): its PHP is generated, so its lines
    /// don't map to the editor, and it reports an `sql` event instead of a return value.
    private(set) var runsSQL = false
    /// What the current SQL run runs where, for the output's running state (#162): "on the default
    /// connection", or "3 statements on the saved connection “Reporting” (…)". Nil for PHP runs.
    private(set) var sqlActivity: String?
    /// The current SQL run's statements, connection, and bound values, for Load Next (#146);
    /// the Connection Manager (#180) reads it too.
    private(set) var sqlRun: SQLRunInfo?
    /// The current SQL run's database session (#144), once the runner reported it: the
    /// Connection Manager (#180) shows its id. Driver, id, and connection name only.
    private(set) var sqlSession: SQLSessionInfo?
    /// #13: the current dry run's transactions began (the runner's `begun` report), and whether
    /// it reported the outcome; a run that ends without one (Stop) gets the app's card.
    @ObservationIgnored private var rollbackBegun: RollbackReport?
    @ObservationIgnored private var rollbackFinished = false
    /// Load Next (#146) for the current output's cut results, by output item id.
    private(set) var sqlPagers: [Int: SQLResultPager] = [:]
    /// #190: Load More for the current output's Redis replies that page (SCAN cursors, cut ranges).
    private(set) var redisPagers: [Int: RedisReplyPager] = [:]
    /// Bumped whenever the output is replaced rather than appended to (a new run, Clear Output),
    /// so the Plain and Raw transcripts know when to start over.
    private(set) var outputGeneration = 0
    /// Bumped once per batch of events that changed the output, so the output can follow it.
    private(set) var outputRevision = 0
    /// Structured output: show every card of this run, not only the most recent ones.
    var showsAllCards = false
    /// Plain-text renderings of finished cards (dumps, results, …), so the Plain transcript
    /// doesn't render every value again on each update.
    @ObservationIgnored private var plainTextCache: [Int: String] = [:]
    /// The Values | Object `plainTextCache` was made with (#307).
    @ObservationIgnored private var plainTextDisplay = ModelDisplay.values
    @ObservationIgnored private var nextOutputId = 0
    @ObservationIgnored private var loadedEditor: EditorController?
    @ObservationIgnored private var initialSelection: NSRange
    /// Content changes (code, title, target) vs. selection-only changes.
    enum Change { case content, selection }
    @ObservationIgnored var onChange: ((Change) -> Void)?

    init(state: TabState) {
        id = state.id
        title = state.title
        target = state.target
        fileURL = state.fileURL
        code = state.code
        language = state.language
        sqlConnection = state.sqlConnection
        sqlSavedConnection = state.sqlSavedConnection
        sqlSavedConnectionName = state.sqlSavedConnectionName
        sqlTransaction = state.sqlTransaction ?? true
        redisTransaction = state.redisTransaction ?? false
        rollback = state.rollback ?? false
        isPinned = state.isPinned
        modelDisplay = state.modelDisplay
        initialSelection = state.selection.nsRange
    }

    /// Only `AppModel` changes this, together with the tab's place in the window (#279).
    func setPinnedFlag(_ pinned: Bool) {
        isPinned = pinned
    }

    private func makeEditor() -> EditorController {
        let controller = EditorController(text: code, selection: initialSelection)
        controller.syntax = language
        controller.sqlCompletion = { [weak self] text, caret in self?.sqlCompletionProvider?(text, caret) }
        controller.completionAction = { [weak self] action in self?.completionActionHandler?(action) }
        controller.textHover = { [weak self] text, index in self?.hoverProvider?(text, index) }
        controller.onTextChange = { [weak self] text, origin in
            guard let self else { return }
            self.code = text
            self.documentVersion += 1
            if self.fileURL != nil { self.isFileDirty = true }
            self.onChange?(.content)
            // Format Code (#36) changes no behaviour and never starts an automatic run.
            if origin != .format, self.formatIssue != nil { self.formatIssue = nil }
            if origin == .load { self.setAutoRunEnabled(false) }
            else if origin == .edit { self.onEditorEdit?() }
        }
        controller.onSelectionChange = { [weak self] _ in self?.onChange?(.selection) }
        controller.textView.onUnhandledEscape = { [weak self] in self?.onEditorEscape?() ?? false }
        controller.inlineValues.modelDisplay = { [weak self] in self?.shownModelDisplay ?? .values }
        controller.inlineValues.onModelDisplayPick = { [weak self] in self?.onModelDisplayPick?($0) }
        return controller
    }

    var state: TabState {
        let selection = editorIfLoaded?.selectedRange ?? initialSelection
        return TabState(id: id, title: title, code: code, target: target, selection: NSRangeCodable(location: selection.location, length: 0), fileURL: fileURL, language: language, sqlConnection: sqlConnection, sqlTransaction: sqlTransaction, sqlSavedConnection: sqlSavedConnection, sqlSavedConnectionName: sqlSavedConnectionName, redisTransaction: redisTransaction, rollback: rollback, pinned: isPinned, modelDisplay: modelDisplay)
    }

    /// The tab's native editor, created on first use and kept for the tab's lifetime.
    var editor: EditorController {
        if let loadedEditor { return loadedEditor }
        let controller = makeEditor()
        loadedEditor = controller
        return controller
    }

    /// The editor without forcing its creation.
    var editorIfLoaded: EditorController? { loadedEditor }

    var isRunning: Bool { runState.isActive }

    // MARK: Sandbox auto-run (#30)

    func setAutoRunEnabled(_ enabled: Bool) {
        cancelPendingAutoRun()
        // SQL tabs never auto-run (#35).
        autoRunEnabled = enabled && target == .sandbox && language == .php
    }

    /// Switches the tab between PHP and SQL (#35): the editor's highlighting and comment
    /// marker follow, and auto-run turns off. Running nothing.
    func setLanguage(_ language: TabLanguage) {
        guard language != self.language else { return }
        self.language = language
        setAutoRunEnabled(false)
        editorIfLoaded?.syntax = language
        editorIfLoaded?.clearInlineValues()
        onChange?(.content)
    }

    func cancelPendingAutoRun() {
        autoRunTask?.cancel()
        autoRunTask = nil
    }

    /// Debounce only editor edits. If a run is active, wait for it without overlapping it.
    func scheduleAutoRun(_ action: @escaping @MainActor (TabModel) -> Void) {
        cancelPendingAutoRun()
        guard autoRunEnabled, target == .sandbox, language == .php else { return }
        let version = documentVersion
        autoRunTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(800))
                while let tab = self, tab.isRunning {
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard !Task.isCancelled, let tab = self, tab.autoRunEnabled,
                      tab.target == .sandbox, tab.documentVersion == version else { return }
                tab.autoRunTask = nil
                action(tab)
            } catch { /* A newer edit, Stop, loading code, or closing the tab cancelled it. */ }
        }
    }

    // MARK: Run lifecycle

    /// A run is starting. `code` and `selection` are what runs (Run Selection: the selected
    /// code and where it starts): the editor follows the lines whose magic comments may show
    /// values, and drops the previous run's. With `magicComments` off the run shows none.
    /// `delivery` says when its output appears: as it arrives, or all at once when it ends.
    func beginRun(code: String? = nil, selection: SourceSelection? = nil, magicComments: Bool = true, delivery: OutputDelivery = .realtime, sql: Bool = false, sqlActivity: String? = nil, sqlRun: SQLRunInfo? = nil) {
        runsSQL = sql
        self.sqlActivity = sql ? sqlActivity : nil
        self.sqlRun = sql ? sqlRun : nil
        sqlSession = nil
        rollbackBegun = nil
        rollbackFinished = false
        dropSQLPagers()
        if let code, magicComments, !sql {
            editorIfLoaded?.beginInlineValues(code: code, selection: selection)
            showsInlineValues = true
        } else {
            editorIfLoaded?.clearInlineValues()
            showsInlineValues = false
        }
        outputGate = RunEventGate(delivery: delivery)
        holdsOutputUntilEnd = delivery == .atOnce
        outputGeneration += 1
        plainTextCache = [:]
        showsAllCards = false
        preparationID = UUID()
        inspectionTarget = target
        output = []
        runLog = []
        runLogStartedAt = Date()
        inspection = RunInspection()
        expandedRecords = []
        finishedQueryCount = 0
        finishedQueryTimeMs = 0
        finishedMessageCounts = SnippetMessageCounts()
        nextOutputId = 0
        stopMessage = nil
        targetIssue = nil
        runState = .preparing
        editorIfLoaded?.clearExecutionError()
    }

    func failBeforeLaunch(_ message: String) {
        preparationID = nil
        holdsOutputUntilEnd = false
        log("launch", "Could not launch: " + message)
        append { .error(id: $0, RunErrorInfo(stage: .launch, message: message), editorLine: nil) }
        let info = FinishedInfo(status: .failed, reason: "launch-failed", elapsedMs: 0)
        append { .finished(id: $0, info) }
        runState = .finished(info)
    }

    func cancelPreparing() {
        preparationID = nil
        holdsOutputUntilEnd = false
        runState = .idle
    }

    func started(_ request: RunRequest) {
        preparationID = nil
        currentRequest = request
        runState = .running(runId: request.runId, startedAt: Date())
        var summary = RunSummary(targetLabel: request.target.label)
        if request.sqlConnection != nil, let previous = lastRun {
            // A saved connection's run (#138) boots plain PHP: what the last run learned about
            // the project's framework stays on show.
            summary.framework = previous.framework
            summary.frameworkVersion = previous.frameworkVersion
            summary.driverName = previous.driverName
        }
        lastRun = summary
        var label = request.target.label + (request.strictTypes ? " · strict_types=1" : "")
        if request.inspector.interceptMail { label += " · mail intercepted" }
        if request.rollback { label += " · dry run: database changes are rolled back" }
        if request.profile != nil { label += " · profiling" }
        append { .header(id: $0, label: label, startedAt: Date()) }
    }

    /// A line in the output that says something about the run (e.g. who asked for it).
    func note(_ text: String) {
        append { .notice(id: $0, text) }
    }

    private func append(_ make: (Int) -> OutputItem) {
        nextOutputId += 1
        output.append(make(nextOutputId))
    }

    #if DEBUG
    /// DEBUG `wait-run` timings (#82): events applied, when the first output after the header
    /// and the `finished` event reached the tab (`ProcessInfo.systemUptime`).
    @ObservationIgnored var debugEvents = 0
    @ObservationIgnored var debugFirstOutputAt: TimeInterval?
    @ObservationIgnored var debugFinishedAt: TimeInterval?
    #endif

    /// Applies a batch of the current run's events, in order; events from any other run are
    /// ignored. The Run Log and the status follow every event as it arrives; the output, the
    /// inspector, and magic-comment values follow `outputGate` (held until the run ends in
    /// At once mode, then applied in arrival order).
    func apply(_ events: [RunEvent]) {
        guard let request = currentRequest else { return }
        var changed = false
        for event in events where event.runId == request.runId {
            logIfNeeded(event.kind)
            for ready in outputGate.receive(event) {
                apply(ready.kind, request: request)
                changed = true
            }
        }
        if changed { outputRevision += 1 }
        #if DEBUG
        debugEvents += events.count
        if debugFirstOutputAt == nil, output.count > 1 { debugFirstOutputAt = ProcessInfo.processInfo.systemUptime }
        if case .finished = runState, debugFinishedAt == nil { debugFinishedAt = ProcessInfo.processInfo.systemUptime }
        #endif
    }

    /// The run's events ended. The engine always ends with `finished`; should a stream end
    /// without it, whatever was held is still shown.
    func endOfEvents() {
        guard let request = currentRequest else { return }
        for ready in outputGate.flush() { apply(ready.kind, request: request) }
        holdsOutputUntilEnd = false
    }

    private func apply(_ kind: RunEvent.Kind, request: RunRequest) {
        switch kind {
        case .started(let info):
            lastRun?.phpVersion = info.phpVersion
            lastRun?.workingDirectory = info.workingDirectory
            // A saved connection's run (#138) boots plain PHP, which says nothing about the project.
            if request.sqlConnection == nil { lastRun?.framework = info.framework }
        case .bootstrapped(let info):
            guard request.sqlConnection == nil else { break }
            lastRun?.framework = info.framework
            lastRun?.frameworkVersion = info.frameworkVersion
            lastRun?.driverName = info.driverName
        case .stdout(let data):
            appendText(data, stream: .stdout)
        case .stderr(let data):
            appendText(data, stream: .stderr)
        case .dump(let dump):
            let line = dump.inSnippet == true && !runsSQL ? dump.snippetLine.map(request.editorLine(forSnippetLine:)) : nil
            append { .dump(id: $0, dump, editorLine: line) }
        case .result(let result):
            // An SQL run's result is its `sql` event; its generated PHP returns nothing.
            if runsSQL, !result.hasValue { break }
            append { .result(id: $0, result) }
        case .sql(let result):
            append { .sql(id: $0, result) }
            // Load Next (#146): a result the row cap cut can load more of its rows.
            if result.truncated == true, let run = sqlRun, let id = output.last?.id {
                sqlPagers[id] = SQLResultPager(tab: self, itemId: id, run: run, target: inspectionTarget ?? target, result: result)
            }
        case .sqlPlan(let plan):
            append { .sqlPlan(id: $0, plan) }
        case .redis(let reply):
            append { .redis(id: $0, reply) }
            // #190: Load More for a SCAN page or a cut range.
            if let run = sqlRun, let id = output.last?.id, let pager = RedisReplyPager(tab: self, itemId: id, run: run, target: inspectionTarget ?? target, reply: reply) {
                redisPagers[id] = pager
            }
        case .sqlSession(let info):
            // #180: the Connection Manager shows the session's id (the Run Log has its line).
            sqlSession = info
        case .sqlCancel(let report):
            // Stop cancelled the statement on the server first (#144), or says why it couldn't.
            append { report.succeeded ? .notice(id: $0, report.message) : .warning(id: $0, report.message) }
        case .sqlSchema:
            // Completion's schema (#128): AppModel keeps it; it is not output.
            break
        case .sqlExport, .sqlImport:
            // #152: Export Query to CSV and Import CSV run apart from the tab's output.
            break
        case .rollback(let report):
            // #13: the transactions began (the Run Log says where), a warning as it happens, and
            // the outcome after the output.
            switch report.state {
            case .begun:
                rollbackBegun = report
            case .warning:
                // A refused statement and a transaction that couldn't begin come with an error
                // card at the same line; the Run Log and the outcome card still list them.
                if report.warning?.raisesError == true { break }
                let line = report.warning.flatMap { $0.inSnippet == true ? $0.snippetLine : nil }.map(request.editorLine(forSnippetLine:))
                append { .rollback(id: $0, report, editorLine: line) }
            case .finished, .stopped:
                rollbackFinished = true
                append { .rollback(id: $0, report, editorLine: nil) }
            }
        case .error(var error):
            if runsSQL { error = Self.withoutRunnerLocation(error) }
            let line = !runsSQL && (error.inSnippet == true || error.snippetLine != nil) ? error.snippetLine.map(request.editorLine(forSnippetLine:)) : nil
            append { .error(id: $0, error, editorLine: line) }
            if let line { editorIfLoaded?.showExecutionError(line: line) }
        case .notice(let message):
            append { .notice(id: $0, message) }
        case .snippetMessage(let message):
            // Not an error event: the run goes on, and nothing marks it failed (#196).
            let line = !runsSQL ? message.callerSnippetLine.map(request.editorLine(forSnippetLine:)) : nil
            append { .snippetMessage(id: $0, message, editorLine: line) }
        case .inspector(let inspectorEvent):
            inspection.apply(inspectorEvent)
            switch inspectorEvent {
            case .ready(let info) where info.interceptionUnsupported:
                // The mail chip quotes the same text (#193).
                if let warning = info.interceptionWarning { append { .warning(id: $0, warning) } }
            case .record(let record):
                if let mail = record.mail { append { .mail(id: $0, mail, recordIndex: record.index) } }
                if record.benchmark != nil { append { .benchmark(id: $0, record) } }
                if let profile = record.profile {
                    append { .profile(id: $0, ProfileSummary(profile)) }
                    // Profile Run: show the flame graph, unless the run failed (the error comes first).
                    let failed = output.contains { if case .error = $0 { true } else { false } }
                    if outputSection == nil, !failed, profile.samples > 0 { outputSection = RunInspection.profile }
                }
            default:
                break
            }
        case .log(let entry):
            log(entry.source, entry.message, detail: entry.detail)
        case .remember:
            break
        case .inline(let inlineEvent):
            // Values from a selection map back to the editor lines it came from; ignored when
            // magic comments are off.
            if showsInlineValues {
                editorIfLoaded?.applyInline(inlineEvent, editorLine: request.editorLine(forSnippetLine:))
            }
        case .finished(let info):
            holdsOutputUntilEnd = false
            if request.rollback, let begun = rollbackBegun, !rollbackFinished {
                // #13: Stop (or a crash) ended PHP before the runner rolled back.
                rollbackFinished = true
                append { .rollback(id: $0, .stopped(reason: info.reason, connections: begun.connections), editorLine: nil) }
            }
            finishedQueryCount = inspection.queryEntries.count
            finishedQueryTimeMs = inspection.queryTimeMs
            finishedMessageCounts = Self.messageCounts(in: output)
            append { .finished(id: $0, info) }
            runState = .finished(info)
            log("exit", "Finished: \(info.status.rawValue) (\(info.reason))" + (info.exitCode.map { ", exit code \($0)" } ?? "") + " after \(info.elapsedMs) ms")
        }
    }

    /// How many notice, warning, and error cards the snippet showed (#196).
    static func messageCounts(in output: [OutputItem]) -> SnippetMessageCounts {
        var counts = SnippetMessageCounts()
        for case .snippetMessage(_, let message, _) in output { counts.add(message.level) }
        return counts
    }

    /// An SQL run's error (#35) without the places inside Runlet's runner script (stdin) and
    /// its generated snippet: they say nothing about the statement. A project driver's file
    /// and lines stay.
    static func withoutRunnerLocation(_ error: RunErrorInfo) -> RunErrorInfo {
        var error = error
        let runner = "Standard input code"
        if error.file == runner || error.inSnippet == true {
            error.file = nil
            error.line = nil
        }
        error.inSnippet = nil
        error.snippetLine = nil
        error.snippetColumn = nil
        error.trace = error.trace?.filter { $0.file != runner && $0.inSnippet != true }
        if error.trace?.isEmpty == true { error.trace = nil }
        // The runner's own refusals read as what they are.
        switch error.className {
        case "RunletRunner\\SqlUnavailable": error.className = "No SQL connection"
        case "RunletRunner\\SqlConnectionFailed": error.className = "Connection failed"
        case "RunletRunner\\SqlStatementFailed": error.className = "Statement failed"
        // #190
        case "RunletRunner\\RedisUnavailable": error.className = "No Redis connection"
        case "RunletRunner\\RedisConnectionFailed": error.className = "Connection failed"
        case "RunletRunner\\RedisRefused": error.className = "Refused"
        case "RunletRunner\\RedisCommandFailed": error.className = "Command failed"
        default: break
        }
        return error
    }

    /// Run Log lines for events that also show in the output (start, stderr, errors).
    private func logIfNeeded(_ kind: RunEvent.Kind) {
        switch kind {
        case .started(let info):
            let parts = [info.phpVersion.map { "PHP " + $0 }, info.phpBinary, info.pid.map { "pid \($0)" }, info.user.map { "uid \($0)" }].compactMap { $0 }
            log("runner", "Runner started: " + parts.joined(separator: " · "), detail: info.workingDirectory.map { "in " + $0 })
        case .stderr(let data):
            let text = String(decoding: data.prefix(4000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { log("stderr", text) }
        case .inline(.probes(let info)):
            log("runner", "Magic comments: \(info.probes.count) shown" + (info.rejected.isEmpty ? "" : ", \(info.rejected.count) not shown"),
                detail: info.rejected.isEmpty ? nil : info.rejected.map { "line \($0.line): \($0.reason)" }.joined(separator: "\n"))
        case .error(let error):
            log("error", "[\(error.stage.rawValue)] " + error.message, detail: [error.className, error.file.map { $0 + (error.line.map { ":\($0)" } ?? "") }].compactMap { $0 }.joined(separator: " · ").nilIfEmpty)
        case .sqlCancel(let report):
            // #144: every server cancel is in the Run Log, production or not.
            log("cancel", report.message, detail: [report.statement, report.elapsedMs.map { String(format: "%.0f ms", $0) }, report.state].compactMap { $0 }.joined(separator: " · "))
        case .rollback(let report) where report.state == .warning:
            // #13: what a dry run can't roll back, as it happens.
            if let warning = report.warning { log("rollback", warning.message, detail: warning.sql) }
        default:
            break
        }
    }

    /// A line from outside the run (the Database pane's Cancel Query and Kill Session, #150; an
    /// SSH tunnel the last run used was cancelled, #143).
    func appendRunLog(_ source: String, _ message: String, detail: String? = nil) {
        log(source, message, detail: detail)
    }

    private func log(_ source: String, _ message: String, detail: String? = nil) {
        guard runLog.count < Self.maxRunLogLines else { return }
        let offset = Int(Date().timeIntervalSince(runLogStartedAt) * 1000)
        runLog.append(RunLogLine(id: runLog.count, offsetMs: offset, source: source, message: message, detail: detail))
    }

    private func appendText(_ data: Data, stream: OutputItem.Stream) {
        let text = String(decoding: data, as: UTF8.self)
        if case .text(let id, let lastStream, var existing) = output.last, lastStream == stream {
            // Release the array's copy first so the pieces grow in place.
            output[output.count - 1] = .notice(id: id, "")
            existing.append(text)
            output[output.count - 1] = .text(id: id, stream: stream, text: existing)
        } else {
            append { .text(id: $0, stream: stream, text: ChunkedText(text)) }
        }
    }

    /// #307: Values | Object changed: the Plain transcript and the editor's inline values follow.
    func modelDisplayChanged() {
        plainTextCache = [:]
        outputGeneration += 1
        editorIfLoaded?.inlineValues.modelDisplayChanged()
    }

    var outputPlainText: String {
        // #307: dumps and results follow the tab's Values | Object.
        let display = shownModelDisplay
        if display != plainTextDisplay {
            plainTextCache = [:]
            plainTextDisplay = display
        }
        return output.map { item in
            if case .text(_, _, let text) = item { return text.string }
            if let cached = plainTextCache[item.id] { return cached }
            let text = item.plainText(display: display)
            plainTextCache[item.id] = text
            return text
        }.joined(separator: "\n")
    }

    /// The output as Markdown: each card is a heading with its content in a fenced block (or
    /// a table for tabular values), followed by the inspector's queries and mail.
    var outputMarkdown: String {
        var blocks: [String] = []
        for item in output {
            switch item {
            case .header(_, let label, let date):
                blocks.append("## \(MarkdownText.inline(label)) — \(date.formatted(date: .abbreviated, time: .standard))")
            case .text(_, let stream, let text):
                blocks.append((stream == .stderr ? "**stderr**\n\n" : "") + MarkdownText.fence(text.string, language: "text"))
            case .dump(_, let dump, let line):
                let location = line.map { " (line \($0))" } ?? dump.file.map { " (\(MarkdownText.inline(($0 as NSString).lastPathComponent)):\(dump.line ?? 0))" } ?? ""
                blocks.append("### \(dump.isDD ? "dd" : "dump")\(location)" + (dump.label.map { " — \(MarkdownText.inline($0))" } ?? "") + "\n\n" + MarkdownText.value(dump.node(for: shownModelDisplay)))
            case .result(_, let result):
                if result.hasValue, let value = result.node(for: shownModelDisplay) {
                    blocks.append("### Result: \(MarkdownText.inline(value.typeLabel))\n\n" + MarkdownText.value(value))
                } else {
                    blocks.append("_No return value_")
                }
            case .error(_, let error, let line):
                var text = "### \(MarkdownText.inline(error.className ?? "Error")) (\(error.stage.rawValue))\n\n" + MarkdownText.fence(error.message)
                if let line { text += "\n\nLine \(line)" } else if let file = error.file { text += "\n\n`\(file):\(error.line ?? 0)`" }
                blocks.append(text)
            case .notice(_, let text):
                blocks.append("> ℹ︎ \(MarkdownText.inline(text))")
            case .warning(_, let text):
                blocks.append("> ⚠︎ \(MarkdownText.inline(text))")
            case .snippetMessage(_, let message, let line):
                let location = line.map { " (line \($0))" } ?? message.file.map { " (\(MarkdownText.inline(($0 as NSString).lastPathComponent)):\(message.line ?? 0))" } ?? ""
                var text = "> \(message.level.symbol) **\(message.level.title)**\(location): \(MarkdownText.inline(message.text))"
                if let previous = message.exception?.previous { text += "\n>\n> Caused by \(MarkdownText.inline(previous.className)): \(MarkdownText.inline(previous.message))" }
                if let context = message.context { text += "\n\n" + MarkdownText.value(context) }
                blocks.append(text)
            case .mail(_, let mail, _):
                blocks.append("> ✉︎ \(mail.statusLabel): \(MarkdownText.inline(mail.summary))")
            case .benchmark(_, let record):
                blocks.append("### Benchmark: \(MarkdownText.inline(record.title ?? "bench()"))\n\n" + MarkdownText.fence(record.benchmark?.plainSummary ?? "", language: "text"))
            case .profile(_, let summary):
                blocks.append("> ≋ \(MarkdownText.inline(summary.text))")
            case .sql(_, let result):
                blocks.append(result.markdown)
            case .sqlPlan(_, let plan):
                blocks.append(plan.markdown)
            case .redis(_, let reply):
                blocks.append(reply.markdown)
            case .rollback(_, let report, _):
                blocks.append("> ↺ **\(MarkdownText.inline(report.title))**" + report.details.map { "\n>\n> \(MarkdownText.inline($0))" }.joined()
                              + (report.state == .finished ? (report.warnings ?? []).map { "\n>\n> ⚠︎ \(MarkdownText.inline($0.message))" }.joined() : ""))
            case .finished:
                blocks.append("_\(MarkdownText.inline(item.plainText))_")
            }
        }
        let queries = inspection.queries
        if !queries.isEmpty {
            let analysis = inspection.queryAnalysis
            var parts = ["## Queries (\(queries.count), \(String(format: "%.2f", analysis.totalMs)) ms)"]
            for (index, query) in queries {
                let time = query.timeMs.map { String(format: "%.2f ms", $0) } ?? "time unknown"
                let hints = analysis.group(of: index)?.hints.map(\.label).joined(separator: ", ") ?? ""
                parts.append("\(MarkdownText.inline(query.connection ?? "query")) · \(time)" + (hints.isEmpty ? "" : " · \(hints)") + "\n\n" + MarkdownText.fence(query.interpolatedSQL, language: "sql"))
            }
            blocks.append(parts.joined(separator: "\n\n"))
        }
        let mails = inspection.mails
        if !mails.isEmpty {
            blocks.append("## Mail (\(mails.count))\n\n" + mails.map { "- \($0.statusLabel): \(MarkdownText.inline($0.summary))" }.joined(separator: "\n"))
        }
        // #5: the HTTP and Jobs sections, one line each (URLs and headers as redacted by the runner).
        let requests = inspection.httpRequests
        if !requests.isEmpty {
            blocks.append("## HTTP (\(requests.count))\n\n" + requests.map { "- \(MarkdownText.inline($0.summary))" }.joined(separator: "\n"))
        }
        let jobs = inspection.jobs
        if !jobs.isEmpty {
            blocks.append("## Jobs (\(jobs.count))\n\n" + jobs.map { "- \(MarkdownText.inline($0.summary))" }.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// Exactly what the PHP process wrote to stdout/stderr, in arrival order.
    var rawOutput: String {
        output.compactMap { item -> String? in
            if case .text(_, _, let text) = item { return text.string }
            return nil
        }.joined()
    }

    func outputText(for mode: OutputDisplayMode) -> String {
        switch mode {
        case .raw: rawOutput
        case .plain, .structured: outputPlainText
        }
    }

    /// Clears the output and the inspector's records (Clear Output).
    /// Shared finished-card/status tooltip; unknown phases are never inferred from total time.
    func timingDetails(_ info: FinishedInfo) -> String {
        [
            "Started: " + (info.startedAt?.formatted(date: .abbreviated, time: .standard) ?? "Unavailable"),
            "Bootstrap: " + (info.bootstrapMs.map { "\($0) ms" } ?? "Unavailable"),
            "Execute: " + (info.executeMs.map { "\($0) ms" } ?? "Unavailable"),
            "Total: \(info.elapsedMs) ms",
            "Peak memory: " + (info.peakMemory.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) } ?? "Unavailable"),
            "Queries: \(finishedQueryCount) · \(String(format: "%.1f", finishedQueryTimeMs)) ms",
        ].joined(separator: "\n")
    }

    func clearOutput() {
        outputGate.discardHeld()
        dropSQLPagers()
        outputGeneration += 1
        plainTextCache = [:]
        showsAllCards = false
        inspectionTarget = nil
        editorIfLoaded?.clearInlineValues()
        output = []
        runLog = []
        inspection = RunInspection()
        expandedRecords = []
        outputSection = nil
    }

    // MARK: Load Next (#146)

    /// Stops any page that is loading and forgets the pagers: the output they page is going away.
    private func dropSQLPagers() {
        for pager in sqlPagers.values { pager.detach() }
        if !sqlPagers.isEmpty { sqlPagers = [:] }
        for pager in redisPagers.values { pager.detach() }
        if !redisPagers.isEmpty { redisPagers = [:] }
    }

    /// #190: Load More appended a page to a Redis reply: the card shows `reply` instead.
    func replaceRedisReply(_ id: Int, with reply: RedisReplyInfo) {
        guard let index = output.lastIndex(where: { $0.id == id }), case .redis = output[index] else { return }
        output[index] = .redis(id: id, reply)
        plainTextCache[id] = nil
        outputGeneration += 1
    }

    /// The Redis reply of output item `id`, if the output still has it.
    func redisReply(_ id: Int) -> RedisReplyInfo? {
        for item in output.reversed() where item.id == id {
            if case .redis(_, let reply) = item { return reply }
            return nil
        }
        return nil
    }

    /// The SQL result of output item `id`, if the output still has it.
    func sqlResult(_ id: Int) -> SQLResultInfo? {
        for item in output.reversed() where item.id == id {
            if case .sql(_, let result) = item { return result }
            return nil
        }
        return nil
    }

    /// #207: a MongoDB tab's last result card and its Extended JSON tree after it (the items Load
    /// More appends to), if the output still has the card.
    func mongoResultItems() -> (sql: Int, dump: Int?)? {
        guard let index = output.lastIndex(where: { if case .sql(_, let result) = $0 { result.driver == "mongodb" } else { false } }) else { return nil }
        let dump = output[(index + 1)...].first { if case .dump(_, let dump, _) = $0 { dump.label?.hasPrefix("MongoDB documents") == true } else { false } }
        return (output[index].id, dump?.id)
    }

    /// The dump of output item `id`, if the output still has it.
    func dumpInfo(_ id: Int) -> DumpInfo? {
        for item in output.reversed() where item.id == id {
            if case .dump(_, let dump, _) = item { return dump }
            return nil
        }
        return nil
    }

    /// #207: Load More appended a MongoDB page to the tree: the item shows `dump` instead.
    func replaceDump(_ id: Int, with dump: DumpInfo) {
        guard let index = output.lastIndex(where: { $0.id == id }), case .dump(_, _, let line) = output[index] else { return }
        output[index] = .dump(id: id, dump, editorLine: line)
        plainTextCache[id] = nil
        outputGeneration += 1
    }

    /// Load Next appended a page: the card shows `result` in place of the rows it had. The text
    /// transcripts start over, since a card's text changed rather than more being appended.
    func replaceSQLResult(_ id: Int, with result: SQLResultInfo) {
        guard let index = output.lastIndex(where: { $0.id == id }), case .sql = output[index] else { return }
        output[index] = .sql(id: id, result)
        plainTextCache[id] = nil
        outputGeneration += 1
    }

    // MARK: Loading helpers (disarm auto-run)

    /// Holds nothing worth keeping (only whitespace or an opening `<?php`), is not backed by
    /// a file, and is not running: library entries may load here instead of a new tab.
    var isBlankScratch: Bool {
        guard fileURL == nil, !isRunning else { return false }
        let text = (editorIfLoaded?.text ?? code).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text == "<?php"
    }

    func replaceCode(_ newCode: String) {
        setAutoRunEnabled(false)
        if let loadedEditor {
            loadedEditor.replaceAll(with: newCode)
        } else {
            code = newCode
            documentVersion += 1
            onChange?(.content)
        }
    }

    func markSaved(to url: URL) {
        fileURL = url
        isFileDirty = false
        title = url.lastPathComponent
    }
}

/// One Run Log line: milliseconds since the run began, where it came from (`launch`,
/// `runner`, `driver`, `bootstrap`, `stderr`, `error`, `exit`), and the text.
struct RunLogLine: Identifiable, Equatable {
    let id: Int
    let offsetMs: Int
    let source: String
    let message: String
    let detail: String?
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// What the output says about a Profile Run (the flame graph itself is in the Profile section).
struct ProfileSummary: Equatable {
    var samples: Int
    var durationMs: Double?
    var engine: String

    init(_ profile: ProfileRecord) {
        samples = profile.samples
        durationMs = profile.durationMs
        engine = profile.engineSummary
    }

    var text: String {
        let duration = durationMs.map { " over " + BenchmarkFormat.duration(ns: $0 * 1_000_000) } ?? ""
        return "Profile: \(samples.formatted()) sample\(samples == 1 ? "" : "s")\(duration) (\(engine))"
    }
}
