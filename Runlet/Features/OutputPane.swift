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
            HStack {
                Text("Output").font(.headline)
                Spacer()
                Button {
                    Pasteboard.copy(tab.outputPlainText)
                } label: {
                    Label("Copy Output", systemImage: "doc.on.doc")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Copy Output (⌥⌘C)")
                .disabled(tab.output.isEmpty)
                .accessibilityIdentifier("copy-output-button")
                Button {
                    tab.output = []
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Clear Output (⌘K)")
                .disabled(tab.output.isEmpty || tab.isRunning)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            if tab.output.isEmpty {
                ContentUnavailableView {
                    Label(tab.isRunning ? "Running…" : "No output yet", systemImage: tab.isRunning ? "bolt" : "play")
                } description: {
                    Text(tab.isRunning ? model.targetLabel(tab.target) : "Press ⌘R to run this tab, or ⇧⌘R to run the selection.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Card(title: dump.isDD ? "dd" : "dump", subtitle: dumpLocation(dump, line: line), tint: .purple, copyText: dump.value.plainText(), onTapSubtitle: line.map { line in { tab.editor.goTo(line: line) } }) {
                ValueTreeView(node: dump.value, label: dump.label)
            }
            .accessibilityIdentifier("output-dump")
        case .result(_, let result):
            if result.hasValue, let value = result.value {
                Card(title: "Result", subtitle: value.typeLabel, tint: .green, copyText: value.plainText()) {
                    ValueTreeView(node: value, label: nil, expandFirstLevel: true)
                }
                .accessibilityIdentifier("output-result")
            } else {
                Text("No return value")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("output-no-result")
            }
        case .error(_, let error, let line):
            ErrorCard(error: error, line: line, tab: tab)
                .accessibilityIdentifier("output-error")
        case .notice(_, let text):
            Label(text, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
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

    private func dumpLocation(_ dump: DumpInfo, line: Int?) -> String? {
        if let line { return "line \(line)" }
        if let file = dump.file { return "\((file as NSString).lastPathComponent):\(dump.line ?? 0)" }
        return nil
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
        return parts.joined(separator: " · ")
    }
}

struct Card<Content: View>: View {
    var title: String
    var subtitle: String?
    var tint: Color
    var copyText: String?
    var onTapSubtitle: (() -> Void)?
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
                Button("Go to line \(line)\(error.snippetColumn.map { ", column \($0)" } ?? "")") {
                    tab.editor.goTo(line: line, column: error.snippetColumn ?? 1)
                }
                .buttonStyle(.link)
                .font(.caption)
                .accessibilityIdentifier("error-line-link")
            } else if let file = error.file {
                Text("\(file):\(error.line ?? 0)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
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
                Text("\((file as NSString).lastPathComponent):\(frame.line ?? 0)").foregroundStyle(.secondary).help(file)
            }
        }
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
    var expandFirstLevel = false

    var body: some View {
        ValueRow(key: label.map { AnyKey(text: $0, kind: .label) }, node: node, initiallyExpanded: expandFirstLevel || node.type == .array || node.type == .object, depth: 0)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
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
    let initiallyExpanded: Bool
    let depth: Int
    @State private var expanded: Bool?

    var body: some View {
        let isExpanded = expanded ?? (initiallyExpanded && depth == 0)
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
                        ValueRow(key: AnyKey(text: entry.key, kind: entry.keyType == "int" ? .int : (entry.keyType == "string" ? .string : .property), visibility: entry.visibility), node: entry.value, initiallyExpanded: false, depth: depth + 1)
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
