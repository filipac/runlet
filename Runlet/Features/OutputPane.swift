import AppKit
import RunletCore
import SwiftUI
import UniformTypeIdentifiers

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
                Button {
                    tab.clearOutput()
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
            } else if tab.output.isEmpty {
                ContentUnavailableView {
                    Label(tab.isRunning ? "Running…" : "No output yet", systemImage: tab.isRunning ? "bolt" : "play")
                } description: {
                    Text(tab.isRunning ? model.targetLabel(tab.target) : "Press ⌘R to run this tab, or ⇧⌘R to run the selection.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.settings.outputMode != .structured {
                TranscriptView(text: tab.outputText(for: model.settings.outputMode), emptyMessage: model.settings.outputMode == .raw ? "PHP wrote nothing to stdout/stderr. Dumps and results appear in Structured and Plain modes." : "No output.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(tab.output) { item in
                                OutputItemView(item: item, tab: tab)
                                    .id(item.id)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: tab.output.count) {
                        if let last = tab.output.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .accessibilityIdentifier("output-list")
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

struct OutputItemView: View {
    @Environment(AppModel.self) private var model
    let item: OutputItem
    let tab: TabModel

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
            Text(text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(stream == .stderr ? Color.orange : Color.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.06)))
                .accessibilityIdentifier(stream == .stderr ? "output-stderr" : "output-stdout")
        case .dump(_, let dump, let line):
            // Snippet lines go to the editor; files outside the snippet open in the external editor.
            let fileLink = line == nil ? dump.file.map { file in
                AnyView(FileLocationLink(path: file, line: dump.line, label: "\((file as NSString).lastPathComponent):\(dump.line ?? 0)", tab: tab))
            } : nil
            Card(title: dump.isDD ? "dd" : "dump", subtitle: line.map { "line \($0)" }, tint: .purple, copyText: dump.value.plainText(), onTapSubtitle: line.map { line in { tab.editor.goTo(line: line) } }, subtitleAccessory: fileLink) {
                ValueContentView(node: dump.value, label: dump.label, expansion: model.settings.valueExpansion, preview: dump.preview)
            }
            .accessibilityElement(children: .contain)
                .accessibilityIdentifier("output-dump")
        case .result(_, let result):
            if result.hasValue, let value = result.value {
                Card(title: "Result", subtitle: value.typeLabel, tint: .green, copyText: value.plainText()) {
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
        case .finished(_, let info):
            HStack(spacing: 6) {
                Image(systemName: info.status.symbol).foregroundStyle(info.status.color)
                Text(finishedText(info)).font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("output-finished")
            if let truncation = info.truncation {
                Label(truncation, systemImage: "scissors").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func finishedText(_ info: FinishedInfo) -> String {
        var parts = ["\(info.status.label)"]
        switch info.reason {
        case "completed", "cancelled": break
        case "dd": parts.append("dd()")
        case "exit": parts.append("exit()")
        default: parts.append(info.reason)
        }
        parts.append("\(info.elapsedMs) ms")
        if let exitCode = info.exitCode, exitCode != 0 { parts.append("exit code \(exitCode)") }
        if let memory = info.peakMemory { parts.append(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory) + " peak") }
        let queries = tab.inspection.queryEntries.count
        if queries > 0 { parts.append("\(queries) quer\(queries == 1 ? "y" : "ies") (\(String(format: "%.1f", tab.inspection.queryTimeMs)) ms)") }
        return parts.joined(separator: " · ")
    }
}

struct Card<Content: View>: View {
    var title: String
    var subtitle: String?
    var tint: Color
    var copyText: String?
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
                if let copyText {
                    Button {
                        Pasteboard.copy(copyText)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy")
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

/// A value shown as a tree, with a Table toggle when it is tabular and a Preview (shown
/// first) when the runner rendered it as HTML (mailables, views, responses).
struct ValueContentView: View {
    enum Mode: Hashable { case tree, table, preview }

    let node: ValueNode
    var label: String?
    var expansion: ValueExpansion
    var preview: HTMLPreview?
    @State private var mode: Mode?

    var body: some View {
        let table = ValueTable.make(from: node)
        let current = mode ?? (preview != nil ? .preview : .tree)
        VStack(alignment: .leading, spacing: 4) {
            if table != nil || preview != nil {
                Picker("View", selection: Binding(get: { current }, set: { mode = $0 })) {
                    if preview != nil { Text("Preview").tag(Mode.preview) }
                    Text("Tree").tag(Mode.tree)
                    if let table { Text("Table (\(table.rows.count)×\(table.columns.count))").tag(Mode.table) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .accessibilityIdentifier("value-view-picker")
            }
            if current == .preview, let preview {
                HTMLPreviewView(content: PreviewContent(preview))
            } else if current == .table, let table {
                ValueTableView(table: table)
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


/// Sortable grid for tabular values, with search and CSV copy/export.
struct ValueTableView: View {
    let table: ValueTable
    @State private var sortColumn: Int?
    @State private var ascending = true
    @State private var filter = ""

    private var rowIndices: [Int] {
        var indices = Array(table.rows.indices)
        if !filter.isEmpty {
            let needle = filter.lowercased()
            indices = indices.filter { index in
                table.rowKeys[index].lowercased().contains(needle) || table.rows[index].contains { $0.text.lowercased().contains(needle) }
            }
        }
        if let sortColumn {
            indices.sort { lhs, rhs in
                let a = table.rows[lhs][sortColumn]
                let b = table.rows[rhs][sortColumn]
                let ordered: Bool
                if let x = a.number, let y = b.number { ordered = x < y } else { ordered = a.text.localizedStandardCompare(b.text) == .orderedAscending }
                return ascending ? ordered : !ordered && a.text != b.text
            }
        }
        return indices
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Filter rows", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 220)
                Spacer()
                Button("Copy CSV") { Pasteboard.copy(table.csv()) }
                    .controlSize(.small)
                Button("Export CSV…") { exportCSV() }
                    .controlSize(.small)
            }
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                    GridRow {
                        Text("#").foregroundStyle(.secondary)
                        ForEach(Array(table.columns.enumerated()), id: \.offset) { index, column in
                            Button {
                                if sortColumn == index { ascending.toggle() } else { sortColumn = index; ascending = true }
                            } label: {
                                HStack(spacing: 2) {
                                    Text(column).fontWeight(.semibold)
                                    if sortColumn == index { Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.caption2) }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(rowIndices, id: \.self) { index in
                        GridRow {
                            Text(table.rowKeys[index]).foregroundStyle(.secondary)
                            ForEach(Array(table.rows[index].enumerated()), id: \.offset) { _, cell in
                                Text(cell.text)
                                    .foregroundStyle(cell.isNull ? Color.secondary : (cell.number != nil ? Color.purple : Color.primary))
                                    .lineLimit(1)
                                    .frame(maxWidth: 320, alignment: .leading)
                                    .help(cell.text)
                            }
                        }
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(.vertical, 2)
            }
            if table.omittedRows > 0 {
                Text("\(table.omittedRows) more rows not shown (runner limit)").font(.caption).foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("value-table")
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "runlet-export.csv"
        if panel.runModal() == .OK, let url = panel.url {
            try? table.csv().write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// Selectable monospaced transcript used by Plain and Raw modes.
struct TranscriptView: View {
    let text: String
    let emptyMessage: String

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? emptyMessage : text)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .accessibilityIdentifier("output-transcript")
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
