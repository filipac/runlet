import AppKit
import Observation
import RunletCore
import RunletLanguage

extension MailRecord {
    /// What happened to the message: sent, intercepted, or queued.
    var statusLabel: String {
        if queued { return "Mail queued" + (queueConnection.map { " on \($0)" } ?? "") + " (a queue worker sends it)" }
        return intercepted ? "Mail intercepted (not sent)" : "Mail sent"
    }
}

/// One item in a tab's output pane, in execution order.
enum OutputItem: Identifiable, Equatable {
    case header(id: Int, label: String, startedAt: Date)
    case text(id: Int, stream: Stream, text: String)
    case dump(id: Int, DumpInfo, editorLine: Int?)
    case result(id: Int, ResultInfo)
    case error(id: Int, RunErrorInfo, editorLine: Int?)
    case notice(id: Int, String)
    /// Something the user should not miss, such as mail interception that no driver supports.
    case warning(id: Int, String)
    /// Mail the run sent, intercepted, or queued (details in the inspector's Mail section).
    case mail(id: Int, MailRecord, recordIndex: Int)
    /// A benchmark card (`Runlet\bench()`, Laravel's `Benchmark::dd()`); also in the Benchmarks section.
    case benchmark(id: Int, InspectorRecord)
    /// A Profile Run's samples (the flame graph is in the Profile section).
    case profile(id: Int, ProfileSummary)
    case finished(id: Int, FinishedInfo)

    enum Stream: String { case stdout, stderr }

    var id: Int {
        switch self {
        case .header(let id, _, _), .text(let id, _, _), .dump(let id, _, _), .result(let id, _),
             .error(let id, _, _), .notice(let id, _), .warning(let id, _), .mail(let id, _, _), .benchmark(let id, _), .profile(let id, _), .finished(let id, _):
            id
        }
    }

    /// Plain-text rendering used by Copy Output.
    var plainText: String {
        switch self {
        case .header(_, let label, let date):
            return "▶ \(label) — \(date.formatted(date: .omitted, time: .standard))"
        case .text(_, _, let text):
            return text
        case .dump(_, let dump, let line):
            let location = line.map { " (line \($0))" } ?? dump.file.map { " (\($0):\(dump.line ?? 0))" } ?? ""
            return "\(dump.isDD ? "dd" : "dump")\(location):\n" + dump.value.plainText()
        case .result(_, let result):
            return result.hasValue ? "=> " + (result.value?.plainText() ?? "") : "(no result)"
        case .error(_, let error, let line):
            var text = "\(error.className ?? "Error") [\(error.stage.rawValue)]: \(error.message)"
            if let line { text += " (line \(line))" } else if let file = error.file { text += " (\(file):\(error.line ?? 0))" }
            return text
        case .notice(_, let text):
            return "ℹ︎ \(text)"
        case .warning(_, let text):
            return "⚠︎ \(text)"
        case .mail(_, let mail, _):
            return "✉︎ \(mail.statusLabel): \(mail.summary)"
        case .benchmark(_, let record):
            return "⏱︎ \(record.title ?? "Benchmark"):\n" + (record.benchmark?.plainSummary ?? "")
        case .profile(_, let summary):
            return "≋ \(summary.text)"
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
    /// Last persisted/observed text; the live text lives in the editor.
    private(set) var code: String
    private(set) var documentVersion = 1
    var isFileDirty = false

    /// #30: session-only opt-in; deliberately absent from TabState/workspaces.
    private(set) var autoRunEnabled = false
    @ObservationIgnored private var autoRunTask: Task<Void, Never>?
    @ObservationIgnored var onEditorEdit: (() -> Void)?

    var runState: RunState = .idle
    var output: [OutputItem] = []
    /// The current run's inspector records: queries, mail, logs, and driver sections.
    var inspection = RunInspection()
    /// #9: completion metrics survive clearing the inspector/output until the next run.
    private(set) var finishedQueryCount = 0
    private(set) var finishedQueryTimeMs: Double = 0
    /// #4: output can outlive a target switch; Explain belongs to the run's target.
    private(set) var inspectionTarget: TargetRef?
    var lastRun: RunSummary?
    /// The output pane's section: nil for the output, else an inspector section ("Queries", …).
    var outputSection: String?
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
    /// The current run's magic-comment delivery: streamed or held (nil: magic comments off).
    @ObservationIgnored private var inlineGate: InlineEventGate?
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
        initialSelection = state.selection.nsRange
    }

    private func makeEditor() -> EditorController {
        let controller = EditorController(text: code, selection: initialSelection)
        controller.onTextChange = { [weak self] text, origin in
            guard let self else { return }
            self.code = text
            self.documentVersion += 1
            if self.fileURL != nil { self.isFileDirty = true }
            self.onChange?(.content)
            if origin == .load { self.setAutoRunEnabled(false) }
            else { self.onEditorEdit?() }
        }
        controller.onSelectionChange = { [weak self] _ in self?.onChange?(.selection) }
        return controller
    }

    var state: TabState {
        let selection = editorIfLoaded?.selectedRange ?? initialSelection
        return TabState(id: id, title: title, code: code, target: target, selection: NSRangeCodable(location: selection.location, length: 0), fileURL: fileURL)
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
        autoRunEnabled = enabled && target == .sandbox
    }

    func cancelPendingAutoRun() {
        autoRunTask?.cancel()
        autoRunTask = nil
    }

    /// Debounce only editor edits. If a run is active, wait for it without overlapping it.
    func scheduleAutoRun(_ action: @escaping @MainActor (TabModel) -> Void) {
        cancelPendingAutoRun()
        guard autoRunEnabled, target == .sandbox else { return }
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
    /// values, and drops the previous run's. With `magicComments` off the run shows none;
    /// without `streamInlineValues` its values are held until it ends.
    func beginRun(code: String? = nil, selection: SourceSelection? = nil, magicComments: Bool = true, streamInlineValues: Bool = true) {
        if let code, magicComments {
            editorIfLoaded?.beginInlineValues(code: code, selection: selection)
            inlineGate = InlineEventGate(streams: streamInlineValues)
        } else {
            editorIfLoaded?.clearInlineValues()
            inlineGate = nil
        }
        preparationID = UUID()
        inspectionTarget = target
        output = []
        runLog = []
        runLogStartedAt = Date()
        inspection = RunInspection()
        finishedQueryCount = 0
        finishedQueryTimeMs = 0
        nextOutputId = 0
        stopMessage = nil
        targetIssue = nil
        runState = .preparing
        editorIfLoaded?.clearExecutionError()
    }

    func failBeforeLaunch(_ message: String) {
        preparationID = nil
        log("launch", "Could not launch: " + message)
        append { .error(id: $0, RunErrorInfo(stage: .launch, message: message), editorLine: nil) }
        let info = FinishedInfo(status: .failed, reason: "launch-failed", elapsedMs: 0)
        append { .finished(id: $0, info) }
        runState = .finished(info)
    }

    func cancelPreparing() {
        preparationID = nil
        runState = .idle
    }

    func started(_ request: RunRequest) {
        preparationID = nil
        currentRequest = request
        runState = .running(runId: request.runId, startedAt: Date())
        lastRun = RunSummary(targetLabel: request.target.label)
        var label = request.target.label + (request.strictTypes ? " · strict_types=1" : "")
        if request.inspector.interceptMail { label += " · mail intercepted" }
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

    /// Applies one event; events from any other run are ignored.
    func apply(_ event: RunEvent) {
        guard let request = currentRequest, event.runId == request.runId else { return }
        switch event.kind {
        case .started(let info):
            lastRun?.phpVersion = info.phpVersion
            lastRun?.framework = info.framework
            lastRun?.workingDirectory = info.workingDirectory
        case .bootstrapped(let info):
            lastRun?.framework = info.framework
            lastRun?.frameworkVersion = info.frameworkVersion
            lastRun?.driverName = info.driverName
        case .stdout(let data):
            appendText(data, stream: .stdout)
        case .stderr(let data):
            appendText(data, stream: .stderr)
        case .dump(let dump):
            let line = dump.inSnippet == true ? dump.snippetLine.map(request.editorLine(forSnippetLine:)) : nil
            append { .dump(id: $0, dump, editorLine: line) }
        case .result(let result):
            append { .result(id: $0, result) }
        case .error(let error):
            let line = error.inSnippet == true || error.snippetLine != nil ? error.snippetLine.map(request.editorLine(forSnippetLine:)) : nil
            append { .error(id: $0, error, editorLine: line) }
            if let line { editorIfLoaded?.showExecutionError(line: line) }
        case .notice(let message):
            append { .notice(id: $0, message) }
        case .inspector(let inspectorEvent):
            inspection.apply(inspectorEvent)
            switch inspectorEvent {
            case .ready(let info) where info.interceptionUnsupported:
                let driver = info.driverName.map { "the \($0) driver" } ?? "this project's driver"
                append { .warning(id: $0, "Intercept Mail is on, but \(driver) can't intercept mail. Mail this run sends is delivered normally.") }
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
            // Values from a selection map back to the editor lines it came from. Held until the
            // run ends when streaming is off; ignored when magic comments are off.
            for ready in inlineGate?.receive(inlineEvent) ?? [] {
                editorIfLoaded?.applyInline(ready, editorLine: request.editorLine(forSnippetLine:))
            }
        case .finished(let info):
            finishedQueryCount = inspection.queryEntries.count
            finishedQueryTimeMs = inspection.queryTimeMs
            for ready in inlineGate?.finish() ?? [] {
                editorIfLoaded?.applyInline(ready, editorLine: request.editorLine(forSnippetLine:))
            }
            append { .finished(id: $0, info) }
            runState = .finished(info)
            log("exit", "Finished: \(info.status.rawValue) (\(info.reason))" + (info.exitCode.map { ", exit code \($0)" } ?? "") + " after \(info.elapsedMs) ms")
        }
        logIfNeeded(event.kind)
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
        default:
            break
        }
    }

    private func log(_ source: String, _ message: String, detail: String? = nil) {
        guard runLog.count < Self.maxRunLogLines else { return }
        let offset = Int(Date().timeIntervalSince(runLogStartedAt) * 1000)
        runLog.append(RunLogLine(id: runLog.count, offsetMs: offset, source: source, message: message, detail: detail))
    }

    private func appendText(_ data: Data, stream: OutputItem.Stream) {
        let text = String(decoding: data, as: UTF8.self)
        if case .text(let id, let lastStream, let existing) = output.last, lastStream == stream {
            output[output.count - 1] = .text(id: id, stream: stream, text: existing + text)
        } else {
            append { .text(id: $0, stream: stream, text: text) }
        }
    }

    var outputPlainText: String {
        output.map(\.plainText).joined(separator: "\n")
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
                blocks.append((stream == .stderr ? "**stderr**\n\n" : "") + MarkdownText.fence(text, language: "text"))
            case .dump(_, let dump, let line):
                let location = line.map { " (line \($0))" } ?? dump.file.map { " (\(MarkdownText.inline(($0 as NSString).lastPathComponent)):\(dump.line ?? 0))" } ?? ""
                blocks.append("### \(dump.isDD ? "dd" : "dump")\(location)" + (dump.label.map { " — \(MarkdownText.inline($0))" } ?? "") + "\n\n" + MarkdownText.value(dump.value))
            case .result(_, let result):
                if result.hasValue, let value = result.value {
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
            case .mail(_, let mail, _):
                blocks.append("> ✉︎ \(mail.statusLabel): \(MarkdownText.inline(mail.summary))")
            case .benchmark(_, let record):
                blocks.append("### Benchmark: \(MarkdownText.inline(record.title ?? "bench()"))\n\n" + MarkdownText.fence(record.benchmark?.plainSummary ?? "", language: "text"))
            case .profile(_, let summary):
                blocks.append("> ≋ \(MarkdownText.inline(summary.text))")
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
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// Exactly what the PHP process wrote to stdout/stderr, in arrival order.
    var rawOutput: String {
        output.compactMap { item -> String? in
            if case .text(_, _, let text) = item { return text }
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
        inspectionTarget = nil
        editorIfLoaded?.clearInlineValues()
        output = []
        runLog = []
        inspection = RunInspection()
        outputSection = nil
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
