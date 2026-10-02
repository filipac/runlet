import AppKit
import Observation
import RunletCore
import RunletLanguage

/// One item in a tab's output pane, in execution order.
enum OutputItem: Identifiable, Equatable {
    case header(id: Int, label: String, startedAt: Date)
    case text(id: Int, stream: Stream, text: String)
    case dump(id: Int, DumpInfo, editorLine: Int?)
    case result(id: Int, ResultInfo)
    case error(id: Int, RunErrorInfo, editorLine: Int?)
    case notice(id: Int, String)
    case finished(id: Int, FinishedInfo)

    enum Stream: String { case stdout, stderr }

    var id: Int {
        switch self {
        case .header(let id, _, _), .text(let id, _, _), .dump(let id, _, _), .result(let id, _),
             .error(let id, _, _), .notice(let id, _), .finished(let id, _):
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
    var workingDirectory: String?
}

@MainActor
@Observable
final class TabModel: Identifiable {
    let id: UUID
    var title: String
    var target: TargetRef
    var fileURL: URL?
    /// Last persisted/observed text; the live text lives in the editor.
    private(set) var code: String
    private(set) var documentVersion = 1
    var isFileDirty = false

    var runState: RunState = .idle
    var output: [OutputItem] = []
    var lastRun: RunSummary?
    var targetIssue: String?
    var stopMessage: String?

    var languageState: LanguageServerState = .stopped
    var languageNotes: [String] = []
    @ObservationIgnored var languageWorkspace: LanguageWorkspace?
    @ObservationIgnored var languageStateTask: Task<Void, Never>?

    @ObservationIgnored private(set) var currentRequest: RunRequest?
    @ObservationIgnored private var nextOutputId = 0
    @ObservationIgnored private var loadedEditor: EditorController?
    @ObservationIgnored private var initialSelection: NSRange
    @ObservationIgnored var onChange: (() -> Void)?

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
        controller.onTextChange = { [weak self] text in
            guard let self else { return }
            self.code = text
            self.documentVersion += 1
            if self.fileURL != nil { self.isFileDirty = true }
            self.onChange?()
        }
        controller.onSelectionChange = { [weak self] _ in self?.onChange?() }
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

    // MARK: Run lifecycle

    func beginRun() {
        output = []
        nextOutputId = 0
        stopMessage = nil
        targetIssue = nil
        runState = .preparing
        editorIfLoaded?.clearExecutionError()
    }

    func failBeforeLaunch(_ message: String) {
        append { .error(id: $0, RunErrorInfo(stage: .launch, message: message), editorLine: nil) }
        let info = FinishedInfo(status: .failed, reason: "launch-failed", elapsedMs: 0)
        append { .finished(id: $0, info) }
        runState = .finished(info)
    }

    func cancelPreparing() {
        runState = .idle
    }

    func started(_ request: RunRequest) {
        currentRequest = request
        runState = .running(runId: request.runId, startedAt: Date())
        lastRun = RunSummary(targetLabel: request.target.label)
        append { .header(id: $0, label: request.target.label, startedAt: Date()) }
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
        case .finished(let info):
            append { .finished(id: $0, info) }
            runState = .finished(info)
        }
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

    // MARK: Editing helpers (never execute code)

    func replaceCode(_ newCode: String) {
        if let loadedEditor {
            loadedEditor.replaceAll(with: newCode)
        } else {
            code = newCode
            documentVersion += 1
            onChange?()
        }
    }

    func markSaved(to url: URL) {
        fileURL = url
        isFileDirty = false
        title = url.lastPathComponent
    }
}
