import AppKit
import RunletCore
import SwiftUI

/// Ordered run output: raw stdout/stderr, structured dumps, the final result, errors, and
/// the terminal status. Raw output is rendered as text; values are expandable trees.
struct OutputPane: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Output").font(.headline).lineLimit(1).fixedSize()
                ViewThatFits(in: .horizontal) {
                    modePicker.pickerStyle(.segmented)
                    modePicker.pickerStyle(.menu)
                }
                .fixedSize()
                if model.settings.outputMode == .structured {
                    Menu {
                        Picker("Expand values", selection: Binding(get: { model.settings.valueExpansion }, set: { model.settings.valueExpansion = $0 })) {
                            Text("Collapsed").tag(ValueExpansion.collapsed)
                            Text("First level").tag(ValueExpansion.firstLevel)
                            Text("Expand all").tag(ValueExpansion.all)
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Image(systemName: "list.bullet.indent")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("How far values expand automatically")
                }
                Spacer()
                if model.interceptMail(for: tab.target) {
                    MailInterceptionChip(target: tab.target)
                }
                Button {
                    Pasteboard.copy(tab.outputText(for: model.settings.outputMode))
                } label: {
                    Label("Copy Output", systemImage: "doc.on.doc")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Copy Output (⌥⌘C)")
                .disabled(tab.output.isEmpty)
                .accessibilityIdentifier("copy-output-button")
                Menu {
                    Button("Copy Output as Markdown") { Pasteboard.copy(tab.outputMarkdown) }
                    Button("Save Output As…") { model.saveOutput(of: tab) }
                    Divider()
                    Toggle("Show Run Log", isOn: Binding(get: { model.settings.showRunLog }, set: { model.settings.showRunLog = $0 }))
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Copy as Markdown or save the output to a file")
                .disabled(tab.output.isEmpty)
                .accessibilityIdentifier("export-output-menu")
                Button {
                    model.clearOutput(tab)
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Clear Output (⌘K)")
                .disabled((tab.output.isEmpty && tab.inspection.isEmpty) || tab.isRunning)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            if !tab.inspection.isEmpty {
                OutputSectionBar(tab: tab)
                Divider()
            }
            if let section = tab.visibleOutputSection {
                InspectorSectionView(section: section, tab: tab)
            } else if tab.output.isEmpty, tab.runsSQL, tab.isRunning {
                // An SQL tab's statement is on its way (#162): say so, with Stop.
                SQLRunningRow(tab: tab)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if tab.output.isEmpty {
                ContentUnavailableView {
                    Label(tab.isRunning ? "Running…" : "No output yet", systemImage: tab.isRunning ? "bolt" : "play")
                } description: {
                    Text(tab.isRunning ? model.targetLabel(tab.target) : tab.autoRunEnabled ? "Edit this sandbox tab to auto-run after 800 ms, or press ⌘R." : tab.language == .sql ? "Press ⌘R to run the statement at the caret (or the selected statement), or ⌥⇧⌘R to run all statements." : "Press ⌘R to run this tab, or ⇧⌘R to run the selection.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.settings.outputMode != .structured {
                VStack(spacing: 0) {
                    if tab.runsSQL, tab.isRunning {
                        SQLRunningRow(tab: tab).padding(10)
                        Divider()
                    } else if tab.holdsOutputUntilEnd {
                        HoldingOutputRow().padding(10)
                        Divider()
                    }
                    TranscriptView(text: tab.outputText(for: model.settings.outputMode), generation: tab.outputGeneration, mode: model.settings.outputMode,
                                   emptyMessage: model.settings.outputMode == .raw ? "PHP wrote nothing to stdout/stderr. Dumps and results appear in Structured and Plain modes." : "No output.")
                }
            } else {
                StructuredOutputList(tab: tab)
            }
            if model.settings.showRunLog {
                Divider()
                RunLogView(tab: tab) { model.settings.showRunLog = false }
                    .frame(height: 190)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

extension OutputPane {
    var modePicker: some View {
        Picker("Display", selection: Binding(get: { model.settings.outputMode }, set: { model.settings.outputMode = $0 })) {
            Text("Structured").tag(OutputDisplayMode.structured)
            Text("Plain").tag(OutputDisplayMode.plain)
            Text("Raw").tag(OutputDisplayMode.raw)
        }
        .labelsHidden()
        .help("Structured: expandable cards · Plain: CLI-style transcript · Raw: exactly what PHP wrote to stdout/stderr")
        .accessibilityIdentifier("output-mode-picker")
    }
}

/// The Structured output: cards in a lazy stack. Long printed output is shown a piece at a time,
/// so only what is on screen is laid out (#82). While scrolled to the bottom the list follows
/// new output, once per batch of events; scrolling up stops that until the bottom is reached
/// again.
struct StructuredOutputList: View {
    let tab: TabModel
    @State private var followsOutput = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                let (rows, earlier) = tab.outputRows
                LazyVStack(alignment: .leading, spacing: 0) {
                    if earlier > 0 {
                        EarlierOutputRow(count: earlier) { tab.showsAllCards = true }
                            .padding(.bottom, 8)
                    }
                    ForEach(rows) { row in
                        OutputItemView(item: row.item, tab: tab, piece: row.piece)
                            .padding(.bottom, row.continues || row.id == rows.last?.id ? 0 : 8)
                    }
                    if tab.runsSQL, tab.isRunning {
                        SQLRunningRow(tab: tab).padding(.top, 8)
                    } else if tab.holdsOutputUntilEnd {
                        HoldingOutputRow().padding(.top, 8)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onScrollGeometryChange(for: ScrollFollow.self) { geometry in
                ScrollFollow(contentHeight: geometry.contentSize.height, atBottom: geometry.visibleRect.maxY >= geometry.contentSize.height - 24)
            } action: { old, new in
                // Only the user's own scrolling (the content keeps its height) changes whether
                // the list follows.
                if old.contentHeight == new.contentHeight { followsOutput = new.atBottom }
            }
            .onChange(of: tab.outputGeneration) { followsOutput = true }
            .onChange(of: tab.outputRevision) {
                if followsOutput, let last = tab.outputRows.rows.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .accessibilityIdentifier("output-list")
    }
}

/// Where the Structured output's scroll view is, for following new output.
struct ScrollFollow: Equatable {
    var contentHeight: CGFloat
    var atBottom: Bool
}

/// One row of the Structured output: a card, or one piece of a long printed-output card.
struct OutputRow: Identifiable {
    struct ID: Hashable {
        var item: Int
        var piece: Int
    }

    let id: ID
    let item: OutputItem
    /// Printed output: the piece this row shows, and where it sits in its card.
    var piece: OutputPiece?

    /// The next row continues this card.
    var continues: Bool { piece.map { !$0.isLast } ?? false }
}

struct OutputPiece: Equatable {
    var text: String
    var isFirst: Bool
    var isLast: Bool
    /// On the first piece shown: earlier lines the card leaves to Plain and Raw.
    var hiddenLines = 0
}

extension TabModel {
    /// Lines of one printed output the Structured view shows: the most recent ones, like a
    /// terminal's scrollback. Plain and Raw (and Copy and Save Output) have all of it.
    static let structuredTextLines = 5_000
    /// Cards the Structured view shows at most, the most recent ones, unless Show All was chosen:
    /// a lazy list scrolled to its end places every card above what it shows each time it
    /// changes. Earlier cards are left out `structuredCardStep` at a time, so the first card
    /// shown doesn't change with every update.
    static let structuredCards = 1_000
    static let structuredCardStep = 250

    /// The Structured output's rows (one per card, and one per piece of printed output), and how
    /// many earlier cards are left out.
    var outputRows: (rows: [OutputRow], earlierCards: Int) {
        let over = output.count - Self.structuredCards
        let earlier = showsAllCards || over <= 0 ? 0 : (over + Self.structuredCardStep - 1) / Self.structuredCardStep * Self.structuredCardStep
        var rows: [OutputRow] = []
        rows.reserveCapacity(output.count - earlier)
        for item in output[earlier...] {
            if case .text(let id, _, let text) = item, text.pieces.count > 1 {
                let (pieces, hidden) = text.tail(lines: Self.structuredTextLines)
                for index in pieces.indices {
                    let first = index == pieces.startIndex
                    rows.append(OutputRow(id: .init(item: id, piece: index), item: item,
                                          piece: OutputPiece(text: pieces[index], isFirst: first, isLast: index == pieces.endIndex - 1, hiddenLines: first ? hidden : 0)))
                }
            } else {
                rows.append(OutputRow(id: .init(item: item.id, piece: 0), item: item))
            }
        }
        return (rows, earlier)
    }
}

/// Above the Structured output when it leaves earlier cards out.
struct EarlierOutputRow: View {
    @Environment(AppModel.self) private var model
    let count: Int
    let showAll: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            Text("\(count.formatted()) earlier \(count == 1 ? "item is" : "items are") in Plain.")
                .foregroundStyle(.secondary)
            Button("Show All", action: showAll)
                .buttonStyle(.link)
                .help("Show every card of this run here (slower while the run goes on)")
            Button("Show in Plain") { model.settings.outputMode = .plain }
                .buttonStyle(.link)
        }
        .font(.caption)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("output-earlier-items")
    }
}

/// At once (Settings ▸ General ▸ Output): the run's output is held until it ends.
struct HoldingOutputRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Output appears when the run ends")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .help("Settings ▸ General ▸ Output is set to At once. Stop the run to see what it printed so far.")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("output-holding")
    }
}

/// While an SQL tab's statement (or Run All) runs (#162): where it runs, for how long, and Stop.
/// PHP tabs keep the status bar's timer and the toolbar's Stop.
struct SQLRunningRow: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            switch tab.runState {
            case .running(_, let startedAt), .stopping(_, let startedAt):
                TimelineView(.periodic(from: startedAt, by: 0.1)) { context in
                    Text(text(elapsed: max(0, context.date.timeIntervalSince(startedAt))))
                        .monospacedDigit()
                }
            default:
                Text("Preparing \(model.targetLabel(tab.target))…")
            }
            Spacer(minLength: 0)
            Button("Stop") { model.stop(tab) }
                .controlSize(.small)
                .disabled(tab.runState.isStopping)
                .help("Stop the statement (⌘.)")
                .accessibilityIdentifier("sql-running-stop")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.teal.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.teal.opacity(0.25)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sql-running")
    }

    private func text(elapsed: TimeInterval) -> String {
        let seconds = String(format: "%.1f s", elapsed)
        if tab.runState.isStopping { return "Stopping… \(seconds)" }
        return "Running \(tab.sqlActivity ?? "on the connection")… \(seconds)"
    }
}

/// Printed output (stdout or stderr), or one piece of a long one.
struct PrintedTextView: View {
    @Environment(AppModel.self) private var model
    let text: String
    let stream: OutputItem.Stream
    var isFirst = true
    var isLast = true
    var hiddenLines = 0

    var body: some View {
        // Pieces end at a line break; the next piece starts the next line.
        let shown = !isLast && text.hasSuffix("\n") ? String(text.dropLast()) : text
        VStack(alignment: .leading, spacing: 6) {
            if hiddenLines > 0 {
                HStack(spacing: 6) {
                    Text("\(hiddenLines.formatted()) earlier lines are in Plain and Raw.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Show All in Raw") { model.settings.outputMode = .raw }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                .accessibilityIdentifier("output-earlier-lines")
            }
            Text(LinkedText.attributed(shown))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(stream == .stderr ? Color.orange : Color.primary)
                .textSelection(.enabled)
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.top, isFirst ? 6 : 0)
            .padding(.bottom, isLast ? 6 : 0)
            .background(UnevenRoundedRectangle(topLeadingRadius: isFirst ? 4 : 0, bottomLeadingRadius: isLast ? 4 : 0, bottomTrailingRadius: isLast ? 4 : 0, topTrailingRadius: isFirst ? 4 : 0)
                .fill(Color.secondary.opacity(0.06)))
            .accessibilityIdentifier(stream == .stderr ? "output-stderr" : "output-stdout")
    }
}

struct OutputItemView: View {
    @Environment(AppModel.self) private var model
    let item: OutputItem
    let tab: TabModel
    /// For a long printed output: the piece this row shows.
    var piece: OutputPiece?

    var body: some View {
        switch item {
        case .header(_, let label, let date):
            HStack(spacing: 6) {
                Image(systemName: "play.circle").foregroundStyle(.secondary)
                Text(label).font(.caption.weight(.semibold))
                Text(date.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("output-header")
        case .text(_, let stream, let text):
            if let piece {
                PrintedTextView(text: piece.text, stream: stream, isFirst: piece.isFirst, isLast: piece.isLast, hiddenLines: piece.hiddenLines)
            } else {
                PrintedTextView(text: text.string, stream: stream)
            }
        case .dump(_, let dump, let line):
            // Snippet lines go to the editor; files outside the snippet open in the external editor.
            let fileLink = line == nil ? dump.file.map { file in
                AnyView(FileLocationLink(path: file, line: dump.line, label: "\((file as NSString).lastPathComponent):\(dump.line ?? 0)", tab: tab))
            } : nil
            Card(title: dump.isDD ? "dd" : "dump", subtitle: line.map { "line \($0)" }, tint: .purple, copyText: dump.value.plainText(), copyValue: dump.value, onTapSubtitle: line.map { line in { tab.editor.goTo(line: line) } }, subtitleAccessory: fileLink) {
                ValueContentView(node: dump.value, label: dump.label, expansion: model.settings.valueExpansion, preview: dump.preview)
            }
            .accessibilityElement(children: .contain)
                .accessibilityIdentifier("output-dump")
        case .result(_, let result):
            if result.hasValue, let value = result.value {
                Card(title: "Result", subtitle: value.typeLabel, tint: .green, copyText: value.plainText(), copyValue: value) {
                    ValueContentView(node: value, label: nil, expansion: model.settings.valueExpansion, preview: result.preview)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("output-result")
            } else {
                Text("No return value")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("output-no-result")
            }
        case .error(_, let error, let line):
            ErrorCard(error: error, line: line, tab: tab)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("output-error")
        case .notice(_, let text):
            Label(text, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
        case .warning(_, let text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("output-warning")
        case .mail(_, let mail, _):
            MailOutputRow(mail: mail) { tab.outputSection = RunInspection.mail }
                .help("Open the Mail section for the headers and a preview")
        case .benchmark(_, let record):
            BenchmarkCard(record: record, tab: tab)
        case .profile(_, let summary):
            ProfileOutputRow(summary: summary, tab: tab)
        case .sql(_, let result):
            SQLResultCard(result: result, tabTitle: tab.title, statementText: result.statement?.text)
        case .finished(_, let info):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: info.status.symbol).foregroundStyle(info.status.color)
                    Text(finishedText(info)).font(.caption).foregroundStyle(.secondary)
                }
                Text(phaseText(info)).font(.caption).foregroundStyle(.secondary)
            }
            .help(tab.timingDetails(info))
            .accessibilityElement(children: .combine)
            .accessibilityValue(tab.timingDetails(info))
            .accessibilityIdentifier("output-finished")
            if let truncation = info.truncation {
                Label(truncation, systemImage: "scissors").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func phaseText(_ info: FinishedInfo) -> String {
        var parts: [String] = []
        if let bootstrap = info.bootstrapMs { parts.append("Bootstrap \(bootstrap) ms") }
        if let execute = info.executeMs { parts.append("Execute \(execute) ms") }
        if let started = info.startedAt { parts.append("Started " + started.formatted(.dateTime.hour().minute().second())) }
        return parts.joined(separator: " · ")
    }

    private func finishedText(_ info: FinishedInfo) -> String {
        var parts = ["\(info.status.label)"]
        switch info.reason {
        case "completed", "cancelled": break
        case "dd": parts.append("dd()")
        case "exit": parts.append("exit()")
        default: parts.append(info.reason)
        }
        parts.append("Total \(info.elapsedMs) ms")
        if let exitCode = info.exitCode, exitCode != 0 { parts.append("exit code \(exitCode)") }
        if let memory = info.peakMemory { parts.append(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory) + " peak") }
        let queries = tab.finishedQueryCount
        if queries > 0 { parts.append("\(queries) quer\(queries == 1 ? "y" : "ies") (\(String(format: "%.1f", tab.finishedQueryTimeMs)) ms)") }
        return parts.joined(separator: " · ")
    }
}

struct Card<Content: View>: View {
    var title: String
    var subtitle: String?
    var tint: Color
    var copyText: String?
    /// Makes the text to copy when Copy is clicked, for a card whose text is too large to make
    /// on every update (an SQL result's rows, #162).
    var copyTextProvider: (() -> String)?
    /// When set, the copy button also offers the value as JSON, PHP, and Markdown.
    var copyValue: ValueNode?
    var onTapSubtitle: (() -> Void)?
    /// Shown after the subtitle, e.g. a file link.
    var subtitleAccessory: AnyView?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title).font(.caption.weight(.bold)).foregroundStyle(tint)
                if let subtitle {
                    if let onTapSubtitle {
                        Button(subtitle, action: onTapSubtitle).buttonStyle(.link).font(.caption)
                    } else {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let subtitleAccessory {
                    subtitleAccessory.font(.caption)
                }
                Spacer()
                if copyText != nil || copyTextProvider != nil {
                    Button {
                        Pasteboard.copy(copyText ?? copyTextProvider?() ?? "")
                    } label: {
                        Image(systemName: "doc.on.doc").font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy")
                    if let copyValue {
                        Menu {
                            Button("Copy as JSON") { Pasteboard.copy(ValueExport.json(copyValue)) }
                            Button("Copy as PHP") { Pasteboard.copy(ValueExport.php(copyValue)) }
                            Button("Copy as Markdown") { Pasteboard.copy(MarkdownText.value(copyValue)) }
                        } label: {
                            Image(systemName: "chevron.down").font(.caption2)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Copy as JSON, PHP, or Markdown")
                    }
                }
            }
            content
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tint.opacity(0.25)))
    }
}

struct ErrorCard: View {
    let error: RunErrorInfo
    let line: Int?
    let tab: TabModel
    @State private var showTrace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text(error.className ?? "Error").font(.callout.weight(.semibold))
                Text(stageLabel).font(.caption).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.red.opacity(0.15)))
                Spacer()
                Button {
                    Pasteboard.copy(OutputItem.error(id: 0, error, editorLine: line).plainText)
                } label: {
                    Image(systemName: "doc.on.doc").font(.caption)
                }
                .buttonStyle(.borderless)
            }
            Text(error.message)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let line {
                let column = error.snippetColumn.map { column in
                    tab.currentRequestForDisplay?.editorColumn(forSnippetLine: error.snippetLine ?? 0, column: column) ?? column
                }
                Button("Go to line \(line)\(column.map { ", column \($0)" } ?? "")") {
                    tab.editor.goTo(line: line, column: column ?? 1)
                }
                .buttonStyle(.link)
                .font(.caption)
                .accessibilityIdentifier("error-line-link")
            } else if let file = error.file {
                FileLocationLink(path: file, line: error.line, label: "\(file):\(error.line ?? 0)", tab: tab)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let previous = error.previous {
                Text("Caused by \(previous.className): \(previous.message)").font(.caption).foregroundStyle(.secondary)
            }
            if let trace = error.trace, !trace.isEmpty {
                DisclosureGroup("Stack trace (\(trace.count))", isExpanded: $showTrace) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(trace.enumerated()), id: \.offset) { index, frame in
                            traceRow(index: index, frame: frame)
                        }
                    }
                }
                .font(.caption)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.red.opacity(0.3)))
    }

    private var stageLabel: String {
        switch error.stage {
        case .launch: "launch"
        case .bootstrap: "bootstrap"
        case .parse: "parse"
        case .execute: error.fatal == true ? "fatal" : "runtime"
        case .transport: "transport"
        }
    }

    @ViewBuilder
    private func traceRow(index: Int, frame: RunErrorInfo.Frame) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("#\(index)").foregroundStyle(.secondary).monospacedDigit()
            Text(frame.function ?? "{main}").font(.system(.caption, design: .monospaced))
            if frame.inSnippet == true, let snippetLine = frame.snippetLine, let request = tab.currentRequestForDisplay {
                let editorLine = request.editorLine(forSnippetLine: snippetLine)
                Button("line \(editorLine)") { tab.editor.goTo(line: editorLine) }.buttonStyle(.link)
            } else if let file = frame.file {
                FileLocationLink(path: file, line: frame.line, label: "\((file as NSString).lastPathComponent):\(frame.line ?? 0)", tab: tab)
            }
        }
    }
}

/// A `file:line` from run output. Opens in the external editor (or reveals in Finder when
/// none is configured). Container paths map through the target's local source; a path with
/// no counterpart on this Mac is plain text whose tooltip explains why.
struct FileLocationLink: View {
    @Environment(AppModel.self) private var model
    let path: String
    let line: Int?
    let label: String
    let tab: TabModel

    var body: some View {
        let resolution = model.editorLink(forRuntimePath: path, in: tab)
        if let hostPath = resolution.path {
            let location = hostPath + (line.map { ":\($0)" } ?? "")
            Button(label) { model.openInExternalEditor(path: hostPath, line: line) }
                .buttonStyle(.link)
                .help("\(model.openInEditorTitle): \(location)")
                .contextMenu {
                    Button(model.openInEditorTitle) { model.openInExternalEditor(path: hostPath, line: line) }
                    if model.settings.externalEditor != .none {
                        Button("Reveal in Finder") { model.revealInFinder(path: hostPath) }
                    }
                    Button("Copy Path") { copy(location) }
                }
                .accessibilityIdentifier("output-file-link")
        } else {
            Text(label)
                .foregroundStyle(.secondary)
                .help(resolution.reason ?? path)
                .contextMenu {
                    Button("Copy Path") { copy(path + (line.map { ":\($0)" } ?? "")) }
                }
                .accessibilityIdentifier("output-file-unlinked")
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension TabModel {
    var currentRequestForDisplay: RunRequest? { currentRequest }
}

/// Expandable view of a ValueNode. Children are built only when expanded, and the runner
/// already bounds depth/size, so large or cyclic values never freeze the UI.
struct ValueTreeView: View {
    let node: ValueNode
    var label: String?
    var expansion: ValueExpansion = .firstLevel

    /// Levels expanded automatically ("Expand all" is still bounded by the runner's depth limit).
    var autoDepth: Int {
        switch expansion {
        case .collapsed: 0
        case .firstLevel: 1
        case .all: 8
        }
    }

    var body: some View {
        ValueRow(key: label.map { AnyKey(text: $0, kind: .label) }, node: node, autoDepth: autoDepth, depth: 0)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .id(expansion)
    }
}

/// Structured values keep their tree/table/runner-preview views. Bounded strings also
/// offer JSON, searchable text, image, or restricted HTML views (#7).
struct ValueContentView: View {
    enum Mode: Hashable { case tree, table, preview, json, text, image }

    let node: ValueNode
    var label: String?
    var expansion: ValueExpansion
    var preview: HTMLPreview?
    @State private var mode: Mode?

    var body: some View {
        let table = ValueTable.make(from: node)
        let viewers = StringViewers(node: node)
        let html = preview ?? viewers?.html.map { HTMLPreview(title: "HTML string", html: $0) }
        let current = mode ?? (preview != nil ? .preview : viewers?.image != nil ? .image : viewers?.isLong == true ? .text : .tree)
        VStack(alignment: .leading, spacing: 4) {
            if table != nil || html != nil || viewers != nil {
                Picker("View", selection: Binding(get: { current }, set: { mode = $0 })) {
                    if html != nil { Text("Preview").tag(Mode.preview) }
                    Text("Tree").tag(Mode.tree)
                    if let table { Text("Table (\(table.rows.count)×\(table.columns.count))").tag(Mode.table) }
                    if viewers?.jsonTree != nil { Text("JSON").tag(Mode.json) }
                    if viewers != nil { Text("Text").tag(Mode.text) }
                    if viewers?.image != nil { Text("Image").tag(Mode.image) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .accessibilityIdentifier("value-view-picker")
            }
            if current == .preview, let html {
                HTMLPreviewView(content: PreviewContent(html))
            } else if current == .json, let pretty = viewers?.prettyJSON, let tree = viewers?.jsonTree {
                Button("Copy Pretty") { Pasteboard.copy(pretty) }
                    .controlSize(.small)
                    .accessibilityIdentifier("copy-pretty-json")
                ValueTreeView(node: tree, label: label, expansion: expansion)
                    .accessibilityIdentifier("json-value-tree")
            } else if current == .text, let viewers {
                StringTextViewer(text: viewers.text, omittedBytes: node.truncation?.omitted)
            } else if current == .image, let payload = viewers?.image {
                StringImageViewer(payload: payload)
            } else if current == .table, let table {
                ValueTableView(table: table, title: label ?? "Table")
            } else {
                ValueTreeView(node: node, label: label, expansion: expansion)
            }
        }
    }
}

/// A one-line card for mail the run sent, intercepted, or queued.
struct MailOutputRow: View {
    let mail: MailRecord
    let open: () -> Void

    var body: some View {
        let tint: Color = mail.queued ? .blue : (mail.intercepted ? .orange : .green)
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: mail.intercepted ? "envelope.badge.shield.half.filled" : (mail.queued ? "tray.and.arrow.up" : "envelope"))
                Text(mail.statusLabel).fontWeight(.semibold)
                Text(mail.summary).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }
            .font(.callout)
            .foregroundStyle(tint)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(mail.intercepted ? "output-mail-intercepted" : "output-mail")
    }
}

/// Shown in the output header while runs on this tab's target intercept mail. Click for
/// where the setting comes from and a switch.
struct MailInterceptionChip: View {
    @Environment(AppModel.self) private var model
    let target: TargetRef
    @State private var showsDetails = false

    var body: some View {
        Button {
            showsDetails.toggle()
        } label: {
            Label("Intercepting Mail", systemImage: "envelope.badge.shield.half.filled")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.orange.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .help("Runs on this target record mail without sending it")
        .accessibilityIdentifier("mail-interception-chip")
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Mail is intercepted").font(.headline)
                Text("Runs on this target ask the project's driver to record mail without sending it (Laravel, and Symfony Mailer 6.3+). Mail pushed to an asynchronous queue is still sent by its queue worker.")
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.settings.interceptMail ? "Set in Settings ▸ General ▸ Run Inspector." : "Set in this target's options.")
                    .foregroundStyle(.secondary)
                if model.settings.interceptMail {
                    Button("Stop Intercepting Mail") {
                        model.toggleMailInterception()
                        showsDetails = false
                    }
                }
            }
            .font(.callout)
            .padding(12)
            .frame(width: 300)
        }
    }
}

/// Plain text with its web links clickable (they open in the default browser).
enum LinkedText {
    static func attributed(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        for link in OutputLinks.links(in: text) {
            guard let range = Range(link.range, in: attributed) else { continue }
            attributed[range].link = link.url
        }
        return attributed
    }
}

/// Selectable monospaced transcript used by Plain and Raw modes: a native text view, so long
/// output scrolls, selects, and finds (⌘F) without laying out all of it, and output that
/// arrives during a run is appended rather than set again (#82). It follows the end while
/// scrolled to the bottom.
struct TranscriptView: NSViewRepresentable {
    let text: String
    /// `TabModel.outputGeneration`: a new value means the text was replaced, not appended to.
    var generation = 0
    var mode: OutputDisplayMode = .plain
    let emptyMessage: String

    final class Coordinator {
        var generation = -1
        var mode: OutputDisplayMode?
        /// UTF-16 length of the text shown (0 while the empty message shows).
        var length = 0
        var showsEmptyMessage = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static var font: NSFont {
        .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 6, height: 10)
        textView.font = Self.font
        textView.setAccessibilityIdentifier("output-transcript")
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, let storage = textView.textStorage else { return }
        let state = context.coordinator
        let length = (text as NSString).length
        let atEnd = scrollView.contentView.bounds.maxY >= textView.frame.maxY - 4
        if text.isEmpty {
            guard !state.showsEmptyMessage else { return }
            storage.setAttributedString(NSAttributedString(string: emptyMessage, attributes: Self.attributes(color: .secondaryLabelColor)))
            state.showsEmptyMessage = true
            state.length = 0
        } else if !state.showsEmptyMessage, state.generation == generation, state.mode == mode, length >= state.length {
            // The same output, grown: append what is new.
            guard length > state.length else { return }
            let from = state.length
            storage.beginEditing()
            storage.append(NSAttributedString(string: (text as NSString).substring(from: from), attributes: Self.attributes(color: .labelColor)))
            Self.addLinks(to: storage, from: (storage.string as NSString).lineRange(for: NSRange(location: from, length: 0)).location)
            storage.endEditing()
            state.length = length
        } else {
            storage.beginEditing()
            storage.setAttributedString(NSAttributedString(string: text, attributes: Self.attributes(color: .labelColor)))
            Self.addLinks(to: storage, from: 0)
            storage.endEditing()
            state.showsEmptyMessage = false
            state.length = length
        }
        state.generation = generation
        state.mode = mode
        if atEnd { textView.scrollToEndOfDocument(nil) }
    }

    private static func attributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color]
    }

    /// Makes web links from `location` on clickable (they open in the default browser).
    private static func addLinks(to storage: NSTextStorage, from location: Int) {
        let tail = (storage.string as NSString).substring(from: location)
        for link in OutputLinks.links(in: tail) {
            storage.addAttribute(.link, value: link.url, range: NSRange(location: location + link.range.location, length: link.range.length))
        }
    }
}

struct AnyKey {
    enum Kind { case label, int, string, property }
    var text: String
    var kind: Kind
    var visibility: String?
}

struct ValueRow: View {
    let key: AnyKey?
    let node: ValueNode
    /// Levels below this row's root that expand automatically.
    let autoDepth: Int
    let depth: Int
    @State private var expanded: Bool?

    var body: some View {
        let isExpanded = expanded ?? (depth < autoDepth)
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if node.isExpandable {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                } else {
                    Spacer().frame(width: 10)
                }
                if let key { keyView(key) }
                valueText
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if node.isExpandable { expanded = !isExpanded }
            }
            if isExpanded, let entries = node.entries {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        ValueRow(key: AnyKey(text: entry.key, kind: entry.keyType == "int" ? .int : (entry.keyType == "string" ? .string : .property), visibility: entry.visibility), node: entry.value, autoDepth: autoDepth, depth: depth + 1)
                    }
                    if let truncation = node.truncation, truncation.omitted != 0 {
                        Text(truncationText(truncation))
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.leading, 14)
                    }
                }
                .padding(.leading, 14)
            }
        }
    }

    @ViewBuilder
    private func keyView(_ key: AnyKey) -> some View {
        switch key.kind {
        case .label:
            Text(key.text + ":").foregroundStyle(.secondary)
        case .int:
            Text("\(key.text) =>").foregroundStyle(.blue)
        case .string:
            Text("\"\(key.text)\" =>").foregroundStyle(.blue)
        case .property:
            let marker = key.visibility == "protected" ? "#" : (key.visibility == "private" ? "-" : "+")
            Text("\(marker)\(key.text):").foregroundStyle(key.visibility == "public" ? Color.teal : Color.secondary)
                .help(key.visibility ?? "public")
        }
    }

    @ViewBuilder
    private var valueText: some View {
        switch node.type {
        case .string:
            Text(node.inlineSummary).foregroundStyle(.orange).lineLimit(node.displayString.count > 300 ? 6 : nil)
            if node.encoding == "base64" { Text("binary").font(.caption2).foregroundStyle(.secondary) }
        case .int, .float:
            Text(node.inlineSummary).foregroundStyle(.purple)
        case .bool, .null:
            Text(node.inlineSummary).foregroundStyle(.pink)
        case .array:
            Text(node.recursion == true ? "array *RECURSION*" : "array:\(node.count ?? 0)").foregroundStyle(.secondary)
            if node.truncation?.reason == "depth" { Text("…").foregroundStyle(.orange).help("Depth limit reached") }
        case .object:
            HStack(spacing: 4) {
                Text(node.className ?? "object").foregroundStyle(.cyan)
                if let ref = node.referenceId { Text("#\(ref)").foregroundStyle(.secondary) }
                if node.repeated == true { Text("(see above)").foregroundStyle(.secondary).help("Same object shown elsewhere in this value; not expanded again to avoid cycles.") }
                if let summary = node.summary { Text(summary).foregroundStyle(.secondary) }
                if node.truncation?.reason == "depth" { Text("…").foregroundStyle(.orange).help("Depth limit reached") }
            }
        case .enum, .closure, .resource, .unknown:
            Text(node.inlineSummary).foregroundStyle(.cyan)
        }
    }

    private func truncationText(_ truncation: ValueNode.Truncation) -> String {
        switch truncation.reason {
        case "children": "… \(truncation.omitted) more not shown (limit 200 per level)"
        case "budget": "… \(truncation.omitted) more not shown (value size limit reached)"
        default: "… truncated"
        }
    }
}

/// Run ▸ Show Run Log: how the current run was launched and what happened, for
/// troubleshooting (e.g. the exact `ssh …` or `docker exec …` command, the driver the runner
/// chose, boot timing, redirects, stderr, and the exit code). Never shows environment values.
struct RunLogView: View {
    let tab: TabModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Run Log").font(.caption.weight(.semibold))
                Text(tab.runLog.isEmpty ? "Run the tab to see how it launches" : "\(tab.runLog.count) lines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { Pasteboard.copy(text) }
                    .controlSize(.small)
                    .disabled(tab.runLog.isEmpty)
                    .accessibilityIdentifier("run-log-copy")
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Hide the Run Log (Run ▸ Show Run Log)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(tab.runLog) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("+\(line.offsetMs) ms")
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 70, alignment: .trailing)
                                Text(line.source)
                                    .foregroundStyle(Self.tint(line.source))
                                    .frame(width: 64, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(line.message)
                                    if let detail = line.detail {
                                        Text(detail).foregroundStyle(.secondary)
                                    }
                                }
                                .textSelection(.enabled)
                            }
                            .font(.system(.caption, design: .monospaced))
                            .id(line.id)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: tab.runLog.count) {
                    if let last = tab.runLog.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.4))
        .accessibilityIdentifier("run-log")
    }

    private var text: String {
        tab.runLog.map { line in
            "+\(line.offsetMs)ms [\(line.source)] \(line.message)" + (line.detail.map { "\n    " + $0.replacingOccurrences(of: "\n", with: "\n    ") } ?? "")
        }.joined(separator: "\n")
    }

    static func tint(_ source: String) -> Color {
        switch source {
        case "error", "stderr": .red
        case "exit": .orange
        case "launch": .blue
        default: .secondary
        }
    }
}
