import AppKit
import RunletCore
import SwiftUI

/// Tabs above the output: Output, then the run inspector's sections (Queries, Mail, Log,
/// and driver sections) with their counts. Shown once a run reports inspector sections.
struct OutputSectionBar: View {
    let tab: TabModel

    var body: some View {
        let inspection = tab.inspection
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                chip(nil, title: "Output", count: nil, flag: nil)
                ForEach(inspection.sections, id: \.self) { section in
                    chip(section, title: section, count: inspection.records(in: section).count + (inspection.omitted(in: section)?.omitted ?? 0), flag: flag(for: section, in: inspection))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
        }
        .accessibilityIdentifier("output-section-bar")
    }

    private func flag(for section: String, in inspection: RunInspection) -> (symbol: String, help: String)? {
        switch section {
        case RunInspection.queries:
            let flagged = inspection.queryAnalysis.flaggedGroups
            return flagged.isEmpty ? nil : ("exclamationmark.triangle.fill", "\(flagged.count) repeated statement\(flagged.count == 1 ? "" : "s"): possible N+1 or duplicate queries")
        case RunInspection.mail:
            let count = inspection.interceptedMailCount
            return count == 0 ? nil : ("envelope.badge.shield.half.filled", "\(count) message\(count == 1 ? " was" : "s were") intercepted, not sent")
        default:
            return nil
        }
    }

    private func chip(_ section: String?, title: String, count: Int?, flag: (symbol: String, help: String)?) -> some View {
        let selected = tab.visibleOutputSection == section
        return Button {
            tab.outputSection = section
        } label: {
            HStack(spacing: 4) {
                Text(title).fontWeight(selected ? .semibold : .regular)
                if let count {
                    Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
                }
                if let flag {
                    Image(systemName: flag.symbol).foregroundStyle(.orange).help(flag.help)
                }
            }
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(selected ? Color.accentColor.opacity(0.18) : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("output-section-\(section ?? "output")")
    }
}

extension TabModel {
    /// The section the output pane shows: the selected inspector section while the current
    /// run has it, else the output.
    var visibleOutputSection: String? {
        guard let outputSection, inspection.sections.contains(outputSection) else { return nil }
        return outputSection
    }

    /// The editor line of a record's snippet line, when it came from the snippet.
    func editorLine(of record: InspectorRecord) -> Int? {
        guard record.inSnippet == true, let line = record.snippetLine, line > 0 else { return nil }
        return currentRequestForDisplay?.editorLine(forSnippetLine: line) ?? line
    }
}

/// One inspector section in place of the output.
struct InspectorSectionView: View {
    let section: String
    let tab: TabModel

    var body: some View {
        Group {
            switch section {
            case RunInspection.queries: QueriesSectionView(tab: tab)
            case RunInspection.mail: MailSectionView(tab: tab)
            case RunInspection.benchmarks: BenchmarksSectionView(tab: tab)
            case RunInspection.profile: ProfileSectionView(tab: tab)
            default: RecordsSectionView(section: section, tab: tab)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Where a record came from: a link to the snippet line, or a file link.
struct RecordLocationView: View {
    let record: InspectorRecord
    let tab: TabModel

    var body: some View {
        if let line = tab.editorLine(of: record) {
            Button("line \(line)") { tab.editor.goTo(line: line) }
                .buttonStyle(.link)
                .help("Go to line \(line) in the editor")
                .accessibilityIdentifier("record-line-link")
        } else if let file = record.file {
            FileLocationLink(path: file, line: record.line, label: "\((file as NSString).lastPathComponent):\(record.line ?? 0)", tab: tab)
                .lineLimit(1)
        }
    }
}

/// "N more … not recorded" under a section that reached a limit.
struct OmittedRecordsNote: View {
    let limit: RecordLimitInfo?
    var noun = "records"

    var body: some View {
        if let limit, limit.omitted > 0 {
            Label(text(limit), systemImage: "scissors")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func text(_ limit: RecordLimitInfo) -> String {
        switch limit.reason {
        case "bytes": "\(limit.omitted) more \(noun) not recorded: the run reached the inspector's 8 MiB limit."
        case "app": "\(limit.omitted) more \(noun) not shown: the run sent more than Runlet accepts."
        default: "\(limit.omitted) more \(noun) not recorded: the inspector keeps 2,000 per run."
        }
    }
}

// MARK: - Queries

struct QueriesSectionView: View {
    let tab: TabModel
    @State private var filter = ""
    @State private var grouped = false
    /// A group picked from a hint chip; only its statements are listed.
    @State private var focus: String?

    var body: some View {
        let inspection = tab.inspection
        let analysis = inspection.queryAnalysis
        let records = Dictionary(uniqueKeysWithValues: inspection.records(in: RunInspection.queries).map { ($0.index, $0) })
        let entries = visibleEntries(inspection.queryEntries)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(summary(analysis)).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("queries-summary")
                    Spacer()
                    Toggle("Group Similar", isOn: $grouped)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .help("One row per statement shape, with how often it ran")
                    TextField("Filter", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(maxWidth: 160)
                }
                if !analysis.flaggedGroups.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(analysis.flaggedGroups) { group in
                                hintChip(group, entries: inspection.queryEntries)
                            }
                            if focus != nil {
                                Button("Show All") { focus = nil }.buttonStyle(.link).font(.caption)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            if inspection.queryEntries.isEmpty {
                ContentUnavailableView("No queries", systemImage: "cylinder", description: Text("This run sent no SQL to the connections Runlet watches."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if grouped {
                            ForEach(groups(analysis, entries: entries)) { group in
                                QueryGroupRow(group: group, entries: entries.filter { group.indices.contains($0.index) }, records: records, tab: tab)
                            }
                        } else {
                            ForEach(entries, id: \.index) { entry in
                                QueryRowView(entry: entry, record: records[entry.index], group: analysis.group(of: entry.index), isSlowest: analysis.slowestIndex == entry.index && analysis.count > 1, tab: tab)
                            }
                        }
                        OmittedRecordsNote(limit: inspection.omitted(in: RunInspection.queries), noun: "statements")
                    }
                    .padding(10)
                }
                .accessibilityIdentifier("queries-list")
            }
        }
    }

    private func summary(_ analysis: QueryAnalysis) -> String {
        guard analysis.count > 0 else { return "No queries" }
        var parts = ["\(analysis.count) quer\(analysis.count == 1 ? "y" : "ies")", String(format: "%.2f ms", analysis.totalMs)]
        let repeated = analysis.groups.filter { $0.count > 1 }.count
        if repeated > 0 { parts.append("\(repeated) repeated statement\(repeated == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private func visibleEntries(_ entries: [QueryEntry]) -> [QueryEntry] {
        var result = entries
        if let focus { result = result.filter { $0.fingerprint == focus } }
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            result = result.filter { $0.statement.lowercased().contains(needle) || ($0.query.connection?.lowercased().contains(needle) ?? false) }
        }
        return result
    }

    private func groups(_ analysis: QueryAnalysis, entries: [QueryEntry]) -> [QueryAnalysis.Group] {
        let visible = Set(entries.map(\.fingerprint))
        return analysis.groups.filter { visible.contains($0.fingerprint) }
    }

    private func hintChip(_ group: QueryAnalysis.Group, entries: [QueryEntry]) -> some View {
        let sql = entries.first { $0.fingerprint == group.fingerprint }?.query.sql ?? group.fingerprint
        return Button {
            focus = focus == group.fingerprint ? nil : group.fingerprint
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(group.hints.map(\.label).joined(separator: " · ")).fontWeight(.semibold)
                Text(sql).lineLimit(1).truncationMode(.tail).frame(maxWidth: 220, alignment: .leading).foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.orange.opacity(focus == group.fingerprint ? 0.25 : 0.1)))
        }
        .buttonStyle(.plain)
        .help(group.hints.map(\.explanation).joined(separator: "\n\n") + "\n\nClick to list only these statements.")
    }
}

/// Copy actions for one statement.
@ViewBuilder
func queryCopyItems(_ entry: QueryEntry) -> some View {
    Button("Copy SQL") { Pasteboard.copy(entry.query.sql) }
    Button("Copy SQL with Bindings") { Pasteboard.copy(entry.statement) }
    if !entry.query.bindings.isEmpty {
        Button("Copy Bindings as JSON") {
            let values = entry.query.bindings.map { binding -> String in
                switch binding.type {
                case "null": "null"
                case "int", "float", "bool": binding.value ?? "null"
                default: "\"" + (binding.value ?? "").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
                }
            }
            Pasteboard.copy("[" + values.joined(separator: ", ") + "]")
        }
    }
}

struct QueryRowView: View {
    let entry: QueryEntry
    let record: InspectorRecord?
    let group: QueryAnalysis.Group?
    let isSlowest: Bool
    let tab: TabModel
    @State private var expanded = false

    var body: some View {
        let query = entry.query
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold)).frame(width: 10)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(expanded ? "Collapse" : "Show the whole statement and its bindings")
                Text("#\(entry.index)").foregroundStyle(.secondary).monospacedDigit()
                Text(query.timeMs.map { String(format: "%.2f ms", $0) } ?? "–")
                    .monospacedDigit()
                    .foregroundStyle(isSlowest ? Color.orange : Color.secondary)
                    .help(isSlowest ? "The slowest statement of this run" : "Execution time")
                if let connection = query.connection {
                    Text(connection + (query.driver.flatMap { $0 == connection ? nil : " · \($0)" } ?? ""))
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        .foregroundStyle(.secondary)
                }
                ForEach(group?.hints ?? [], id: \.self) { hint in
                    Text(hint.label)
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(Color.orange.opacity(0.18)))
                        .foregroundStyle(.orange)
                        .help(hint.explanation)
                }
                Spacer()
                if let record { RecordLocationView(record: record, tab: tab) }
                QueryExplainButton(entry: entry, tab: tab)
                Menu {
                    queryCopyItems(entry)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Copy this statement")
            }
            .font(.caption)
            Text(entry.statement)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(expanded ? nil : 3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if expanded {
                if entry.statement != query.sql {
                    Text(query.sql)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .help("The statement as sent, with placeholders")
                }
                if !query.bindings.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(query.bindings.enumerated()), id: \.offset) { index, binding in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(binding.name.map { ":\($0)" } ?? "\(index + 1)").foregroundStyle(.blue)
                                Text(binding.displayValue).foregroundStyle(binding.type == "string" ? Color.orange : Color.purple).textSelection(.enabled)
                                Text(binding.type).foregroundStyle(.secondary)
                            }
                        }
                        if let omitted = query.omittedBindings {
                            Text("… \(omitted) more bindings").foregroundStyle(.orange)
                        }
                    }
                    .font(.system(.caption, design: .monospaced))
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.06)))
        .contextMenu {
            QueryExplainButton(entry: entry, tab: tab)
            Divider()
            queryCopyItems(entry)
            if let record, let line = tab.editorLine(of: record) {
                Divider()
                Button("Go to Line \(line)") { tab.editor.goTo(line: line) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("query-row")
    }

}

/// #4: shared by query rows, grouped statements, and their context menus.
struct QueryExplainButton: View {
    @Environment(AppModel.self) private var model
    let entry: QueryEntry
    let tab: TabModel

    var body: some View {
        let reason = QueryExplain.unavailableReason(for: entry.query)
        let code = QueryExplain.code(for: entry.query, style: model.explainStyle(for: entry.query, in: tab))
        return Button("Explain") { model.explain(entry.query, from: tab, index: entry.index) }
            .buttonStyle(.borderless)
            .disabled(code == nil || tab.inspectionTarget == nil)
            .help(reason ?? (code == nil ? "The captured bindings cannot be recreated with this database API." : "Open a new PHP tab with this query's plan request. It does not run until you press Run."))
            .accessibilityIdentifier("query-explain-\(entry.index)")
    }
}

/// One shape of statement in Group Similar mode: how often and how long it ran.
struct QueryGroupRow: View {
    let group: QueryAnalysis.Group
    let entries: [QueryEntry]
    let records: [Int: InspectorRecord]
    let tab: TabModel
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold)).frame(width: 10)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Text("\(group.count)×").fontWeight(.semibold).monospacedDigit()
                Text(String(format: "%.2f ms", group.totalMs)).monospacedDigit().foregroundStyle(.secondary)
                if group.count > 1 {
                    Text("\(group.distinctStatements) distinct").foregroundStyle(.secondary)
                }
                ForEach(group.hints, id: \.self) { hint in
                    Text(hint.label)
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(Color.orange.opacity(0.18)))
                        .foregroundStyle(.orange)
                        .help(hint.explanation)
                }
                Spacer()
            }
            .font(.caption)
            Text(entries.first?.query.sql ?? group.fingerprint)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(expanded ? nil : 3)
                .textSelection(.enabled)
            if expanded {
                ForEach(entries, id: \.index) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("#\(entry.index)").foregroundStyle(.secondary).monospacedDigit()
                        Text(entry.statement).lineLimit(2).textSelection(.enabled)
                        Spacer()
                        if let record = records[entry.index] { RecordLocationView(record: record, tab: tab) }
                        QueryExplainButton(entry: entry, tab: tab)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .contextMenu {
                        QueryExplainButton(entry: entry, tab: tab)
                        Divider()
                        queryCopyItems(entry)
                    }
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.06)))
    }
}

// MARK: - Mail

struct MailSectionView: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    /// The message whose preview is open (one web view at a time); nil means the first.
    @State private var selected: Int?

    var body: some View {
        let inspection = tab.inspection
        let records = inspection.records(in: RunInspection.mail).filter { $0.mail != nil }
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                banner(inspection)
                if records.isEmpty {
                    ContentUnavailableView("No mail", systemImage: "envelope", description: Text("This run sent no mail through the mailers Runlet watches."))
                        .frame(maxWidth: .infinity)
                }
                ForEach(records) { record in
                    if let mail = record.mail {
                        MailCard(mail: mail, record: record, tab: tab, showsPreview: (selected ?? records.first?.index) == record.index) {
                            selected = record.index
                        }
                    }
                }
                OmittedRecordsNote(limit: inspection.omitted(in: RunInspection.mail), noun: "messages")
            }
            .padding(10)
        }
        .accessibilityIdentifier("mail-list")
    }

    @ViewBuilder
    private func banner(_ inspection: RunInspection) -> some View {
        let intercepted = inspection.interceptedMailCount
        if intercepted > 0 {
            Label("\(intercepted) message\(intercepted == 1 ? " was" : "s were") intercepted and not sent. Turn off Intercept Mail in Settings ▸ General ▸ Run Inspector (or the target's options) to send mail again.", systemImage: "envelope.badge.shield.half.filled")
                .font(.callout)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("mail-intercepted-banner")
        } else if let info = inspection.info, info.interceptionUnsupported {
            Label(info.interceptMailReason.map { "Intercept Mail is on, but this project's driver can't guarantee it. \($0)" } ?? "Intercept Mail is on, but this project's driver can't intercept mail: mail was delivered normally.", systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("mail-interception-unsupported-banner")
        }
        if inspection.mails.contains(where: \.queued) {
            Label("Queued mail is sent later by a queue worker, outside this run. Runlet can't intercept it.", systemImage: "tray.and.arrow.up")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct MailCard: View {
    let mail: MailRecord
    let record: InspectorRecord
    let tab: TabModel
    let showsPreview: Bool
    let select: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                status
                Text(mail.subject ?? "(no subject)").font(.callout.weight(.semibold)).textSelection(.enabled)
                Spacer()
                RecordLocationView(record: record, tab: tab).font(.caption)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 2) {
                addressRow("From", mail.from)
                addressRow("To", mail.to)
                addressRow("Cc", mail.cc)
                addressRow("Bcc", mail.bcc)
                addressRow("Reply-To", mail.replyTo)
                if let mailable = mail.mailable {
                    GridRow {
                        Text("Mailable").foregroundStyle(.secondary)
                        Text(mailable).textSelection(.enabled)
                    }
                }
                if let caller = mail.caller {
                    GridRow {
                        Text("Sent by").foregroundStyle(.secondary)
                        Text(caller).textSelection(.enabled)
                    }
                }
                if let mailer = mail.mailer {
                    GridRow {
                        Text("Mailer").foregroundStyle(.secondary)
                        Text(mailer)
                    }
                }
                if !mail.attachments.isEmpty {
                    GridRow {
                        Text("Attachments").foregroundStyle(.secondary)
                        Text(mail.attachments.map(attachmentText).joined(separator: ", ")).textSelection(.enabled)
                    }
                }
                if let error = mail.error {
                    GridRow {
                        Text("Error").foregroundStyle(.secondary)
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            }
            .font(.caption)
            if mail.html != nil || mail.text != nil {
                if showsPreview {
                    HTMLPreviewView(content: PreviewContent(mail))
                } else {
                    Button("Show Preview", action: select).buttonStyle(.link).font(.caption)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tint.opacity(0.25)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mail-card")
    }

    private var tint: Color { mail.queued ? .blue : (mail.failed ? .red : (mail.intercepted ? .orange : .green)) }

    private var status: some View {
        let text = mail.queued ? "QUEUED" : (mail.failed ? "FAILED" : (mail.intercepted ? "INTERCEPTED" : "SENT"))
        return Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.18)))
            .foregroundStyle(tint)
            .help(mail.queued ? "Pushed to the \(mail.queueConnection ?? "") queue: a worker sends it later." : (mail.failed ? "The mailer couldn't send it." : (mail.intercepted ? "Recorded, not sent (Intercept Mail)." : "Handed to the mailer during the run.")))
    }

    @ViewBuilder
    private func addressRow(_ label: String, _ addresses: [MailRecord.Address]) -> some View {
        if !addresses.isEmpty {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(addresses.map(\.display).joined(separator: ", ")).textSelection(.enabled)
            }
        }
    }

    private func attachmentText(_ attachment: MailRecord.Attachment) -> String {
        var text = attachment.filename ?? (attachment.inline == true ? "inline" : "attachment")
        var details: [String] = []
        if let type = attachment.contentType { details.append(type) }
        if let size = attachment.size { details.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
        if !details.isEmpty { text += " (\(details.joined(separator: ", ")))" }
        return text
    }
}

// MARK: - Log, HTML, and driver sections

/// Any other section: log messages, HTML, and values a driver recorded.
struct RecordsSectionView: View {
    @Environment(AppModel.self) private var model
    let section: String
    let tab: TabModel

    var body: some View {
        let records = tab.inspection.records(in: section)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if section == RunInspection.log {
                    // #20: what the run wrote to the target's log files, in the Logs window.
                    HStack {
                        Spacer()
                        Button("Show in Logs Window") { model.showLogs(target: tab.inspectionTarget ?? tab.target, lastRun: true) }
                            .buttonStyle(.link)
                            .font(.caption)
                            .help("The Logs window with Last Run on: what this run wrote to the target's log files")
                            .accessibilityIdentifier("records-show-in-logs")
                    }
                }
                if records.isEmpty {
                    ContentUnavailableView("Nothing recorded", systemImage: "tray", description: Text("This run recorded nothing in \(section)."))
                        .frame(maxWidth: .infinity)
                }
                ForEach(records) { record in
                    RecordRowView(record: record, tab: tab)
                }
                OmittedRecordsNote(limit: tab.inspection.omitted(in: section))
            }
            .padding(10)
        }
        .accessibilityIdentifier("records-list")
    }
}

struct RecordRowView: View {
    @Environment(AppModel.self) private var model
    let record: InspectorRecord
    let tab: TabModel
    @State private var showsPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch record.content {
            case .log(let log):
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(log.level.uppercased())
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(levelColor(log.level).opacity(0.18)))
                        .foregroundStyle(levelColor(log.level))
                    if let channel = log.channel { Text(channel).font(.caption).foregroundStyle(.secondary) }
                    Text(log.message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    RecordLocationView(record: record, tab: tab).font(.caption)
                }
                if let context = log.context, context.isExpandable {
                    ValueTreeView(node: context, label: "context", expansion: .collapsed)
                }
            case .value(let value):
                header
                ValueContentView(node: value, label: nil, expansion: model.settings.valueExpansion)
            case .html(let html):
                header
                if showsPreview {
                    HTMLPreviewView(content: PreviewContent(title: record.title ?? "HTML", html: html.html, omittedBytes: html.omittedBytes))
                } else {
                    Button("Show Preview") { showsPreview = true }.buttonStyle(.link).font(.caption)
                }
            case .query(let query):
                QueryRowView(entry: QueryEntry(index: record.index, query: query), record: record, group: nil, isSlowest: false, tab: tab)
            case .mail(let mail):
                MailCard(mail: mail, record: record, tab: tab, showsPreview: showsPreview) { showsPreview = true }
            case .benchmark:
                BenchmarkCard(record: record, tab: tab)
            case .profile:
                header
                Button("Show Flame Graph") { tab.outputSection = RunInspection.profile }.buttonStyle(.link).font(.caption)
            case .unknown(let kind):
                header
                Text("This version of Runlet can't show “\(kind)” records.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("record-row")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(record.title ?? "#\(record.index)").font(.callout.weight(.semibold)).textSelection(.enabled)
            Spacer()
            RecordLocationView(record: record, tab: tab).font(.caption)
        }
    }

    private func levelColor(_ level: String) -> Color {
        switch level {
        case "emergency", "alert", "critical", "error": .red
        case "warning": .orange
        case "notice", "info": .blue
        default: .secondary
        }
    }
}
