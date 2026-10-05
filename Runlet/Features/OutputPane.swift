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
                // #193: always shown, except on SQL tabs (they run a statement, no application mail).
                if tab.language == .php {
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
                    Text(tab.isRunning ? model.targetLabel(tab.target) : tab.autoRunEnabled ? "Edit this sandbox tab to auto-run after 800 ms, or press ⌘R." : tab.language == .sql ? "Press ⌘R to run the statement at the caret (or the selected statement), or ⌥⇧⌘R to run all statements." : tab.language == .redis ? "Press ⌘R to run the command on the caret's line, or ⌥⇧⌘R to run all commands." : "Press ⌘R to run this tab, or ⇧⌘R to run the selection.")
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
        .tourAnchor(.outputModePicker) // #232
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
            case .running(let runId, let startedAt), .stopping(let runId, let startedAt):
                // #183: a statement waiting for a free run slot hasn't connected yet; once it
                // runs, it counts from then.
                let slot = model.connectionManager.slots.state(of: runId)
                if case .queued(let position, _)? = slot, !tab.runState.isStopping {
                    Text("Queued: waits for a free run slot (\(ConnectionText.queuePlace(position))); it connects when it starts.")
                } else {
                    let since: Date = if case .running(let since)? = slot { since } else { startedAt }
                    TimelineView(.periodic(from: since, by: 0.1)) { context in
                        Text(text(elapsed: max(0, context.date.timeIntervalSince(since))))
                            .monospacedDigit()
                    }
                }
            default:
                Text("Preparing \(model.targetLabel(tab.target))…")
            }
            Spacer(minLength: 0)
            Button("Stop") { model.stop(tab) }
                .controlSize(.small)
                .disabled(tab.runState.isStopping)
                .help("Stop the statement (⌘.). On MySQL, MariaDB, PostgreSQL, and SQL Server, Runlet first cancels it on the database server, then stops the runner.")
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
            // #307: copies follow Values | Object.
            let shown = dump.node(for: modelDisplay)
            Card(title: dump.isDD ? "dd" : "dump", subtitle: line.map { "line \($0)" }, tint: .purple, copyText: shown.plainText(), copyValue: shown, onTapSubtitle: line.map { line in { tab.editor.goTo(line: line) } }, subtitleAccessory: fileLink) {
                ValueContentView(node: dump.value, label: dump.label, expansion: model.settings.valueExpansion, preview: dump.preview, modelValues: dump.modelValues, modelDisplay: modelDisplayBinding)
            }
            .accessibilityElement(children: .contain)
                .accessibilityIdentifier("output-dump")
        case .result(_, let result):
            if result.hasValue, let value = result.value {
                // #307: the subtitle and copies follow Values | Object; Values says what it left out.
                let shown = result.node(for: modelDisplay) ?? value
                Card(title: "Result", subtitle: shown.typeLabel + (shown.omittedText.map { " · " + $0 } ?? ""), tint: .green, copyText: shown.plainText(), copyValue: shown) {
                    ValueContentView(node: value, label: nil, expansion: model.settings.valueExpansion, preview: result.preview, modelValues: result.modelValues, modelDisplay: modelDisplayBinding)
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
            if error.interruptedByStop == true {
                // #144: the database's answer to Stop's server cancel, not an error of the
                // user's. Plain output and the Run Log keep the database's words.
                Label(SQLCancel.interruptedText(error), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(error.message)
                    .accessibilityIdentifier("output-interrupted")
            } else {
                ErrorCard(error: error, line: line, tab: tab)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("output-error")
            }
        case .notice(_, let text):
            Label(text, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
        case .warning(_, let text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("output-warning")
        case .snippetMessage(_, let message, let line):
            SnippetMessageCard(message: message, line: line, tab: tab)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("output-snippet-\(message.level.rawValue)")
        case .mail(_, let mail, _):
            MailOutputRow(mail: mail) { tab.outputSection = RunInspection.mail }
                .help("Open the Mail section for the headers and a preview")
        case .benchmark(_, let record):
            BenchmarkCard(record: record, tab: tab)
        case .profile(_, let summary):
            ProfileOutputRow(summary: summary, tab: tab)
        case .sql(let id, let result):
            SQLResultCard(result: result, tabTitle: tab.title, statementText: result.statement?.text, pager: tab.sqlPagers[id],
                          footer: tab.language == .mongodb && result.driver == "mongodb" ? AnyView(MongoPagerControls(tab: tab)) : nil, // #191
                          cellMenu: tab.language == .mongodb && result.driver == "mongodb" ? { [model, tab] row, column in model.mongoResultCellMenu(tab, result: result, row: row, column: column) } : nil) // #217
        case .sqlPlan(_, let plan):
            SQLPlanCard(info: plan)
        case .redis(let id, let reply):
            RedisReplyCard(reply: reply, tabTitle: tab.title, pager: tab.redisPagers[id])
        case .rollback(_, let report, let line):
            RollbackCard(report: report, line: line, tab: tab) // #13
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

    /// #307: how this tab shows Eloquent models (Settings' default until a card switches it).
    private var modelDisplay: ModelDisplay { tab.modelDisplay ?? model.settings.modelDisplay }

    private var modelDisplayBinding: Binding<ModelDisplay> {
        Binding(get: { modelDisplay }, set: { [model, tab] in model.setModelDisplay($0, for: tab) })
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
        // #196: the snippet's own warning and error cards; they never fail the run.
        if let messages = tab.finishedMessageCounts.footer { parts.append(messages) }
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
    @Environment(AppModel.self) private var model
    let error: RunErrorInfo
    let line: Int?
    let tab: TabModel

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
            // #8: the source where it failed. When the link above is the snippet line that led
            // to a file, the file and line it was thrown in come first.
            let source = ownSource
            if line != nil, error.inSnippet != true, source != nil, let file = error.file {
                HStack(spacing: 4) {
                    Text("Thrown in").foregroundStyle(.secondary)
                    FileLocationLink(path: file, line: error.line, label: "\(file):\(error.line ?? 0)", tab: tab)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
            }
            if let source {
                SourceExcerptView(source: source, tab: tab)
            }
            if let previous = error.previous {
                Text("Caused by \(previous.className): \(previous.message)").font(.caption).foregroundStyle(.secondary)
            }
            if let trace = error.trace, !trace.isEmpty {
                StackTraceView(trace: trace, tab: tab, shownSource: source)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.red.opacity(0.3)))
    }

    /// Where the error happened, as an excerpt (#8); PHP tabs only.
    private var ownSource: ExcerptSource? {
        guard tab.language == .php else { return nil }
        return ExcerptSource.make(inSnippet: error.inSnippet, snippetLine: error.snippetLine, file: error.file, line: error.line, resolver: model.frameSourceResolver(for: tab))
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
}

/// A card the snippet asked for with `\Runlet\notice()`, `warning()`, or `error()` (#196): the
/// message, the line that called it, the context as a collapsed value, and for a Throwable its
/// class, where it was thrown, its cause, and its stack trace, as the error card shows them.
/// Notices are blue (Runlet's info symbol), warnings orange like Runlet's own, errors red like
/// the error card; none of them marks the run failed.
struct SnippetMessageCard: View {
    @Environment(AppModel.self) private var model
    let message: SnippetMessage
    let line: Int?
    let tab: TabModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(message.exception?.className ?? message.level.title).font(.callout.weight(.semibold))
                if message.level == .error {
                    Text("not fatal").font(.caption).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(tint.opacity(0.15)))
                        .help("\\Runlet\\error() shows this card; the run goes on and isn't marked failed")
                }
                if let line {
                    Button("line \(line)") { tab.editor.goTo(line: line) }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Go to the line that called \\Runlet\\\(message.level.rawValue)()")
                        .accessibilityIdentifier("snippet-message-line-link")
                } else if let file = message.file {
                    FileLocationLink(path: file, line: message.line, label: "\((file as NSString).lastPathComponent):\(message.line ?? 0)", tab: tab)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    Pasteboard.copy(OutputItem.snippetMessage(id: 0, message, editorLine: line).plainText)
                } label: {
                    Image(systemName: "doc.on.doc").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
            if !message.message.isEmpty {
                Text(message.message + (message.omittedBytes.map { $0 > 0 ? " …" : "" } ?? ""))
                    .font(message.level == .error ? .system(.body, design: .monospaced) : .callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(message.omittedBytes.map { "Runlet shows the first 16 KB; \($0) more bytes were left out." } ?? "")
            }
            if let exception = message.exception {
                thrown(exception)
                let source = thrownSource(exception)
                if let source {
                    SourceExcerptView(source: source, tab: tab)
                }
                if let previous = exception.previous {
                    Text("Caused by \(previous.className): \(previous.message)").font(.caption).foregroundStyle(.secondary)
                }
                if let trace = exception.trace, !trace.isEmpty {
                    StackTraceView(trace: trace, tab: tab, shownSource: source)
                }
            }
            if let context = message.context {
                ValueTreeView(node: context, label: "context", expansion: .collapsed)
                    .accessibilityIdentifier("snippet-message-context")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(message.level == .error ? 0.07 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tint.opacity(message.level == .error ? 0.3 : 0.25)))
    }

    private var symbol: String {
        switch message.level {
        case .notice: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch message.level {
        case .notice: .blue
        case .warning: .orange
        case .error: .red
        }
    }

    /// Where the Throwable was thrown, when that isn't the line that called error().
    @ViewBuilder
    private func thrown(_ exception: SnippetMessage.Exception) -> some View {
        if exception.inSnippet == true, let snippetLine = exception.snippetLine, let request = tab.currentRequestForDisplay {
            let thrownLine = request.editorLine(forSnippetLine: snippetLine)
            if thrownLine != line {
                Button("Thrown on line \(thrownLine)") { tab.editor.goTo(line: thrownLine) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        } else if let file = exception.file {
            HStack(spacing: 4) {
                Text("Thrown in").foregroundStyle(.secondary)
                FileLocationLink(path: file, line: exception.line, label: "\(file):\(exception.line ?? 0)", tab: tab)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption)
        }
    }

    /// The source where the Throwable was thrown (#8), when that isn't the line that called
    /// error(): the line link above already goes there.
    private func thrownSource(_ exception: SnippetMessage.Exception) -> ExcerptSource? {
        guard tab.language == .php else { return nil }
        if exception.inSnippet == true, let snippetLine = exception.snippetLine, let request = tab.currentRequestForDisplay,
           request.editorLine(forSnippetLine: snippetLine) == line {
            return nil
        }
        return ExcerptSource.make(inSnippet: exception.inSnippet, snippetLine: exception.snippetLine, file: exception.file, line: exception.line,
                                  resolver: model.frameSourceResolver(for: tab))
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
/// offer JSON, searchable text, image, or restricted HTML views (#7). A value that holds
/// Eloquent models (#307) also offers Values | Object: its Values tree, or the full dump.
struct ValueContentView: View {
    enum Mode: Hashable { case tree, table, preview, json, text, image }

    let node: ValueNode
    var label: String?
    var expansion: ValueExpansion
    var preview: HTMLPreview?
    /// #307: the Values tree of a value that holds Eloquent models, and the tab's choice.
    var modelValues: ValueNode?
    var modelDisplay: Binding<ModelDisplay>?
    @State private var mode: Mode?

    var body: some View {
        let display = modelValues == nil ? ModelDisplay.object : (modelDisplay?.wrappedValue ?? .values)
        let shown = display == .values ? (modelValues ?? node) : node
        let table = ValueTable.make(from: shown)
        let viewers = StringViewers(node: node)
        let html = preview ?? viewers?.html.map { HTMLPreview(title: "HTML string", html: $0) }
        let current = mode ?? (preview != nil ? .preview : viewers?.image != nil ? .image : viewers?.isLong == true ? .text : .tree)
        VStack(alignment: .leading, spacing: 4) {
            if table != nil || html != nil || viewers != nil || modelValues != nil {
                HStack(spacing: 8) {
                    if table != nil || html != nil || viewers != nil {
                        Picker("View", selection: Binding(get: { current }, set: { mode = $0 })) {
                            if html != nil { Text("Preview").tag(Mode.preview) }
                            Text("Tree").tag(Mode.tree)
                            if let table { Text(Self.tableTitle(table)).tag(Mode.table) }
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
                    if modelValues != nil, let modelDisplay {
                        ModelDisplayPicker(selection: modelDisplay)
                    }
                }
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
                ValueTableView(table: table, title: label ?? "Table", modelTables: modelValues.map { values in
                    ResultModelTables(values: ValueTable.make(from: values), object: ValueTable.make(from: node), display: display)
                })
                .id(display)
            } else {
                ValueTreeView(node: shown, label: label, expansion: expansion)
                    .id(display)
            }
        }
    }

    /// `Table (200×8)`, or `Table (200 of 312 × 8)` when the runner left rows out: the same
    /// count the tree's last line gives.
    static func tableTitle(_ table: ValueTable) -> String {
        let rows = table.rows.count
        guard table.omittedRows > 0 else { return "Table (\(rows)×\(table.columns.count))" }
        return "Table (\(rows.formatted()) of \((rows + table.omittedRows).formatted()) × \(table.columns.count))"
    }
}

/// #307: Values | Object for a value that holds Eloquent models. The choice is the tab's.
struct ModelDisplayPicker: View {
    @Binding var selection: ModelDisplay

    var body: some View {
        Picker("Models", selection: $selection) {
            ForEach(ModelDisplay.allCases) { display in
                Text(display.title).tag(display)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
        .help("Values: each model's class and key, attributes, and loaded relations. Object: the whole object, with its connection, casts, and other internals.")
        .accessibilityIdentifier("model-display-picker")
    }
}

/// A one-line card for mail the run sent, intercepted, or queued.
struct MailOutputRow: View {
    let mail: MailRecord
    let open: () -> Void

    var body: some View {
        let tint: Color = mail.queued ? .blue : (mail.failed ? .red : (mail.intercepted ? .orange : .green))
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: mail.failed ? "exclamationmark.triangle" : (mail.intercepted ? "envelope.badge.shield.half.filled" : (mail.queued ? "tray.and.arrow.up" : "envelope")))
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

/// The output header's mail chip (#193): what runs on this tab's target do with mail
/// (Intercepting Mail, Sending Mail, or Mail: inspector off). Click to see where that comes
/// from and to switch the target's Mail option.
struct MailInterceptionChip: View {
    @Environment(AppModel.self) private var model
    let target: TargetRef
    @State private var showsDetails = false

    var body: some View {
        let mode = model.mailInterception(for: target)
        let production = model.isProduction(target)
        // Mail that really goes out from a production target keeps the production colour.
        let tint: Color = mode.intercept ? .orange : production ? .red : .secondary
        Button {
            showsDetails.toggle()
        } label: {
            Label(Self.title(mode.state), systemImage: Self.symbol(mode.state))
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(tint.opacity(mode.state == .inspectorOff ? 0.07 : 0.14)))
                .opacity(mode.state == .inspectorOff && !production ? 0.7 : 1)
                .fixedSize()
        }
        .buttonStyle(.plain)
        .help(Self.help(mode.state, production: production))
        .accessibilityIdentifier("mail-interception-chip")
        .accessibilityValue(mode.state.rawValue + (production && !mode.intercept ? " production" : ""))
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            MailInterceptionPopover(target: target)
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .debugMailChip)) { note in
            if let action = note.object as? String, action == "on" || action == "off" { showsDetails = action == "on" }
        }
        #endif
    }

    static func title(_ state: MailInterception.State) -> String {
        switch state {
        case .intercepting: "Intercepting Mail"
        case .sending: "Sending Mail"
        case .inspectorOff: "Mail: inspector off"
        }
    }

    static func symbol(_ state: MailInterception.State) -> String {
        switch state {
        case .intercepting: "envelope.badge.shield.half.filled"
        case .sending: "paperplane"
        case .inspectorOff: "envelope"
        }
    }

    static func help(_ state: MailInterception.State, production: Bool) -> String {
        switch state {
        case .intercepting: "Runs on this target record mail without sending it"
        case .sending: production ? "Runs on this production target send real mail" : "Runs on this target send mail; the inspector records it"
        case .inspectorOff: "The run inspector is off: runs on this target send mail and record nothing"
        }
    }
}

/// The mail chip's popover (#193): the mode, where it comes from, what the last run reported,
/// and the target's Mail option (the editors' `MailInterceptionPicker`, written as their Save
/// does). Switching a production target to sending asks first, inline.
struct MailInterceptionPopover: View {
    @Environment(AppModel.self) private var model
    let target: TargetRef
    /// A choice that would make this production target send mail, waiting for Send Mail.
    @State private var pendingChoice: Bool??

    var body: some View {
        let mode = model.mailInterception(for: target)
        let production = model.isProduction(target)
        VStack(alignment: .leading, spacing: 10) {
            Text(heading(mode.state)).font(.headline)
            Text(explanation(mode.state))
                .fixedSize(horizontal: false, vertical: true)
            Text(source(mode))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("mail-chip-source")
            if production, !mode.intercept {
                Label("This target is production: runs send real mail.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            support
            Divider()
            if mode.hasOption {
                MailInterceptionPicker(selection: Binding(get: { mode.override }, set: { choose($0, mode: mode, production: production) }))
                    .pickerStyle(.radioGroup)
                    .accessibilityIdentifier("mail-chip-picker")
                if let pendingChoice {
                    confirmation(pendingChoice)
                }
                Text("Applies from the next run, as the Mail option in the target's editor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // The sandbox has no Mail option: switch the default in Settings, as before.
                Button(mode.intercept ? "Stop Intercepting Mail" : "Intercept Mail") {
                    model.toggleMailInterception()
                }
                .accessibilityIdentifier("mail-chip-global-toggle")
                Text("Changes the default in Settings, for every target that follows it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if mode.state == .inspectorOff {
                    Button("Turn On Run Inspector") { model.settings.runInspector = true }
                        .accessibilityIdentifier("mail-chip-turn-on-inspector")
                }
                Spacer()
                Button("Open Settings…") { model.showGeneralSettings() }
                    .help("Settings ▸ General ▸ Run Inspector: the default for targets that follow Settings")
                    .accessibilityIdentifier("mail-chip-open-settings")
            }
        }
        .font(.callout)
        .padding(12)
        .frame(width: 340)
        .accessibilityIdentifier("mail-chip-popover")
        .onChange(of: target) { pendingChoice = nil }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .debugMailChip)) { note in
            // `mail-chip:choose:default|intercept|send`, as a click on that option.
            guard let action = note.object as? String, action.hasPrefix("choose:") else { return }
            let choice: Bool? = switch action.dropFirst("choose:".count) { case "intercept": true; case "send": false; default: nil }
            choose(choice, mode: model.mailInterception(for: target), production: model.isProduction(target))
        }
        #endif
    }

    /// Writes the choice, unless it makes a production target send mail it intercepted until
    /// now: then it waits for Send Mail.
    private func choose(_ choice: Bool?, mode: MailInterception, production: Bool) {
        if mode.asksFirst(choosing: choice, global: model.settings.interceptMail, production: production) {
            pendingChoice = .some(choice)
        } else {
            pendingChoice = nil
            model.setInterceptMail(choice, for: target)
        }
    }

    private func confirmation(_ choice: Bool?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Send real mail from production?", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.red)
            Text("Runs on \(model.targetLabel(target)) will deliver the mail they send, from the next run.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Keep Intercepting") { pendingChoice = nil }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("mail-chip-keep-intercepting")
                Button("Send Mail", role: .destructive) {
                    pendingChoice = nil
                    model.setInterceptMail(choice, for: target)
                }
                .accessibilityIdentifier("mail-chip-confirm-send")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.08)))
        .accessibilityIdentifier("mail-chip-production-confirmation")
    }

    /// What the last run that asked for interception reported; nothing before such a run.
    @ViewBuilder
    private var support: some View {
        if let report = model.mailInterceptionReport(for: target) {
            if let warning = report.interceptionWarning {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Interception isn't confirmed for this project's driver.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("The last run said: “\(warning)”")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("mail-chip-unconfirmed")
            } else {
                Text("The last run that asked for it confirmed that \(report.driverName.map { "the \($0) driver" } ?? "the project's driver") intercepts mail.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mail-chip-confirmed")
            }
        }
    }

    private func heading(_ state: MailInterception.State) -> String {
        switch state {
        case .intercepting: "Mail is intercepted"
        case .sending: "Mail is sent"
        case .inspectorOff: "The run inspector is off"
        }
    }

    private func explanation(_ state: MailInterception.State) -> String {
        switch state {
        case .intercepting:
            "Runs on this target ask the project's driver to record mail without sending it. Mail pushed to an asynchronous queue is still sent by its queue worker."
        case .sending:
            "Runs on this target send mail as the application does. The run inspector lists each message."
        case .inspectorOff:
            "Runs record nothing, so mail is sent as the application does and isn't listed. Intercepting mail turns the inspector on for those runs."
        }
    }

    private func source(_ mode: MailInterception) -> String {
        switch (mode.source, mode.hasOption) {
        case (.target, _): "Set in this target's options."
        case (.settings, true): "Default, from Settings ▸ General ▸ Run Inspector."
        case (.settings, false): "Default, from Settings ▸ General ▸ Run Inspector. \(target == .sandbox ? "The sandbox" : "This target") has no Mail option of its own."
        }
    }
}

#if DEBUG
extension Notification.Name {
    /// DEBUG step `mail-chip:on|off|choose:<option>` (#193): opens or closes the current
    /// window's mail chip popover, or chooses an option in it.
    static let debugMailChip = Notification.Name("RunletDebugMailChip")
}
#endif

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
    /// `attribute` and `relation`: a model's in Values mode (#307); `field`: a driver caster's (#6).
    enum Kind { case label, int, string, property, field, attribute, relation }
    var text: String
    var kind: Kind
    var visibility: String?
    /// #307: a hidden attribute (`$hidden`), and a changed one with its original value.
    var hidden = false
    var dirty = false
    var original: ValueNode?

    init(text: String, kind: Kind, visibility: String? = nil) {
        self.text = text
        self.kind = kind
        self.visibility = visibility
    }

    init(_ entry: ValueNode.Entry) {
        let kinds: [String: Kind] = ["int": .int, "string": .string, "field": .field, "attribute": .attribute, "relation": .relation]
        self.init(text: entry.key, kind: kinds[entry.keyType] ?? .property, visibility: entry.visibility)
        hidden = entry.hidden == true
        dirty = entry.dirty == true
        original = entry.original
    }
}

struct ValueRow: View {
    let key: AnyKey?
    let node: ValueNode
    /// Levels below this row's root that expand automatically.
    let autoDepth: Int
    let depth: Int
    @State private var expanded: Bool?
    /// #6: the raw object instead of the driver caster's view of it.
    @State private var showsRaw = false
    /// Children shown: a long list of models (#307) shows `ValueRow.page` rows at a time.
    @State private var shownChildren = ValueRow.page

    static let page = 200

    var body: some View {
        let shown = showsRaw ? node.cast?.raw ?? node : node
        let isExpanded = expanded ?? (depth < autoDepth)
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if shown.isExpandable {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                } else {
                    Spacer().frame(width: 10)
                }
                if let key { keyView(key) }
                valueText(shown)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if shown.isExpandable { expanded = !isExpanded }
            }
            if isExpanded, let entries = shown.entries {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(entries.prefix(shownChildren).enumerated()), id: \.offset) { _, entry in
                        ValueRow(key: AnyKey(entry), node: entry.value, autoDepth: autoDepth, depth: depth + 1)
                    }
                    if entries.count > shownChildren {
                        let rest = entries.count - shownChildren
                        Button("Show \(min(rest, Self.page).formatted()) More (\(rest.formatted()) Left)") { shownChildren += Self.page }
                            .buttonStyle(.link)
                            .font(.caption)
                            .padding(.leading, 14)
                            .accessibilityIdentifier("value-show-more")
                    }
                    if let truncation = shown.truncation, truncation.omitted != 0 {
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
        case .field:
            Text("\(key.text):").foregroundStyle(.teal).help("A field from the driver's caster")
        case .attribute:
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                if key.dirty {
                    Text("●").font(.system(size: 8)).foregroundStyle(.orange)
                        .help(key.original.map { "Changed since the model was loaded. Was: " + $0.inlineSummary } ?? "Added since the model was loaded")
                        .accessibilityLabel("changed")
                }
                Text("\(key.text):").foregroundStyle(key.hidden ? Color.secondary : Color.blue)
                if key.hidden {
                    Image(systemName: "eye.slash").font(.system(size: 9)).foregroundStyle(.secondary)
                        .help("Hidden: in the model's $hidden, so its array and JSON leave it out")
                        .accessibilityLabel("hidden")
                }
            }
        case .relation:
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Image(systemName: "link").font(.system(size: 9)).foregroundStyle(.teal)
                Text("\(key.text):").foregroundStyle(.teal)
            }
            .help("A loaded relation")
        }
    }

    @ViewBuilder
    private func valueText(_ node: ValueNode) -> some View {
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
        case .object where node.model != nil || node.collection != nil:
            ModelValuesTitle(node: node)
        case .object:
            HStack(spacing: 4) {
                Text(node.className ?? "object").foregroundStyle(.cyan)
                if let ref = node.referenceId { Text("#\(ref)").foregroundStyle(.secondary) }
                castMark
                if node.repeated == true { Text("(see above)").foregroundStyle(.secondary).help("Same object shown elsewhere in this value; not expanded again to avoid cycles.") }
                if let summary = node.summary { Text(summary).foregroundStyle(self.node.isCast && !showsRaw ? .primary : .secondary) }
                if node.truncation?.reason == "depth" { Text("…").foregroundStyle(.orange).help("Depth limit reached") }
            }
        case .enum, .closure, .resource, .unknown:
            Text(node.inlineSummary).foregroundStyle(.cyan)
        }
    }

    /// #6: the mark of an object the project's driver showed with a caster. A click shows the
    /// raw object, and another the caster's view again. A caster that failed gets a note.
    @ViewBuilder
    private var castMark: some View {
        if let cast = node.cast {
            if let error = cast.error {
                Label("caster: \(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(cast.help)
                    .accessibilityIdentifier("value-cast-error")
            } else {
                Button {
                    showsRaw.toggle()
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "wand.and.stars")
                        if showsRaw { Text("raw") }
                    }
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .foregroundStyle(showsRaw ? Color.orange : Color.accentColor)
                    .background(Capsule().fill((showsRaw ? Color.orange : Color.accentColor).opacity(0.15)))
                }
                .buttonStyle(.plain)
                .disabled(cast.raw == nil)
                .help(showsRaw ? "The raw object, as Runlet sees it. Click to show it as \(cast.by)'s caster does." : cast.help)
                .accessibilityLabel(showsRaw ? "Raw object. Show it as \(cast.by)'s caster does" : "Shown by \(cast.by). Show the raw object")
                .accessibilityIdentifier("value-cast-mark")
            }
        }
    }

    private func truncationText(_ truncation: ValueNode.Truncation) -> String {
        switch truncation.reason {
        case "children": "… \(truncation.omitted) more not shown (limit 200 per level)"
        case "rows": "… \(truncation.omitted.formatted()) more not shown (limit \((truncation.limit ?? 1000).formatted()) rows)"
        case "budget": "… \(truncation.omitted.formatted()) more not shown (value size limit reached)"
        default: "… truncated"
        }
    }
}

/// #307: a model's or a list of models' row in Values mode: `User #1`, with a badge for a new
/// model and for changed attributes, or `Collection<User> · 312`.
struct ModelValuesTitle: View {
    let node: ValueNode

    var body: some View {
        HStack(spacing: 4) {
            if let model = node.model {
                Text(node.shortClassName).foregroundStyle(.cyan)
                    .help(node.className ?? "")
                if let key = model.key {
                    Text("#" + ValueNode.abbreviatedKey(key)).foregroundStyle(.secondary)
                        .help("\(model.keyName ?? "key"): \(key)")
                }
                if !model.exists {
                    badge("new", tint: .green, help: "Not saved: the model's $exists is false")
                }
                if let dirty = model.dirty, dirty > 0 {
                    badge("\(dirty) changed", tint: .orange, help: "Attributes that differ from the values the model was loaded with, marked ●")
                }
            } else if let collection = node.collection {
                (Text(node.shortClassName).foregroundStyle(.cyan)
                    + Text(collection.of.map { "<\(ValueNode.shortClass($0))>" } ?? "").foregroundStyle(.cyan.opacity(0.7)))
                    .help([node.className, collection.of.map { "of " + $0 }].compactMap { $0 }.joined(separator: " "))
                Text(node.collectionDetail ?? "").foregroundStyle(.secondary)
                if let omitted = node.omittedText {
                    Text("· " + omitted).foregroundStyle(.orange)
                }
            }
            if node.repeated == true { Text("(see above)").foregroundStyle(.secondary).help("Same object shown elsewhere in this value; not expanded again to avoid cycles.") }
            if node.truncation?.reason == "depth" { Text("…").foregroundStyle(.orange).help("Depth limit reached") }
        }
    }

    private func badge(_ text: String, tint: Color, help: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.14)))
            .help(help)
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
