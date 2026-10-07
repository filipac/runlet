import RunletCore
import SwiftUI

/// The SQL bar's Explain button (#147): Explain Statement on click; its menu adds Explain
/// Analyze, which runs the statement.
struct SQLExplainButton: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel

    var body: some View {
        Menu {
            // #345: the commands, so a click can show the shortcut tip.
            Button("Explain Statement") { model.perform("run.sqlExplain", source: .button, for: tab) }
                .accessibilityIdentifier("sql-explain-plan")
            Button("Explain Analyze…") { model.perform("run.sqlExplainAnalyze", source: .button, for: tab) }
                .accessibilityIdentifier("sql-explain-analyze")
        } label: {
            Label("Explain", systemImage: "list.bullet.indent")
        } primaryAction: {
            model.perform("run.sqlExplain", source: .button, for: tab)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(tab.isRunning)
        .help(model.commandHelp("Explain Statement", "run.sqlExplain", detail: "the database's plan for the selected statement, or the one at the caret, without running it. The menu also has Explain Analyze, which runs the statement to measure it."))
        .accessibilityIdentifier("sql-explain")
    }
}

/// Explain Statement's result (#147): the plan as a collapsible tree, full scans highlighted,
/// with the database's own output under Raw. At most `maxRows` steps are drawn at once.
struct SQLPlanCard: View {
    let info: SQLPlanInfo
    @State private var showsRaw = false
    @State private var collapsed: Set<Int> = []

    static let maxRows = 300
    /// Characters of the raw output drawn; Copy copies all of it.
    static let maxRawCharacters = 200_000

    var body: some View {
        Card(title: info.isAnalyze ? "Explain Analyze" : "Explain", subtitle: subtitle, tint: .teal, copyTextProvider: { showsRaw ? info.rawText : info.plainText }) {
            VStack(alignment: .leading, spacing: 6) {
                header
                if showsRaw || info.plan == nil {
                    if let error = info.parseError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("sql-plan-error")
                    }
                    raw
                } else if let plan = info.plan {
                    tree(plan)
                }
                Text(info.originText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("output-sql-plan")
        #if DEBUG
        // DEBUG step `sql-plan:raw|tree|collapse:<n>|expand` (SQLExplainDebugSteps).
        .onReceive(NotificationCenter.default.publisher(for: .debugSQLPlan)) { note in
            switch note.object as? String {
            case "raw": showsRaw = true
            case "tree": showsRaw = false
            case "expand": collapsed = []
            case let command? where command.hasPrefix("collapse:"):
                if let index = Int(command.dropFirst(9)) { collapsed.insert(index) }
            default: break
            }
        }
        #endif
    }

    private var subtitle: String {
        [info.plan?.summary, info.elapsedMs.map { $0 < 10 ? String(format: "%.2f ms", $0) : String(format: "%.0f ms", $0) }].compactMap { $0 }.joined(separator: " · ")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Picker("View", selection: $showsRaw) {
                Text("Plan").tag(false)
                Text("Raw").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(info.plan == nil)
            .help("Plan shows Runlet's tree; Raw shows the database's own output (\(info.explained ?? "EXPLAIN")).")
            .accessibilityIdentifier("sql-plan-mode")
            if let scans = info.plan?.fullScans.count, scans > 0 {
                Label("\(scans) full scan\(scans == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .help("The database reads every row of these tables. An index on the columns the statement filters or joins on can avoid it; on small tables a scan is often the cheapest plan.")
                    .accessibilityIdentifier("sql-plan-full-scans")
            }
            if info.rolledBack == true {
                Label("Rolled back", systemImage: "arrow.uturn.backward.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Explain Analyze ran the statement in a transaction that Runlet rolled back.")
                    .accessibilityIdentifier("sql-plan-rolled-back")
            }
            Spacer(minLength: 0)
            if !showsRaw, let plan = info.plan, plan.nodes.contains(where: { $0.descendants > 0 }) {
                Button(collapsed.isEmpty ? "Collapse All" : "Expand All") {
                    collapsed = collapsed.isEmpty ? Set(plan.nodes.filter { $0.descendants > 0 && $0.depth == 0 }.map(\.id)) : []
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    private var raw: some View {
        let text = info.rawText
        let shown = text.count > Self.maxRawCharacters ? String(text.prefix(Self.maxRawCharacters)) + "\n… (Copy copies all of it)" : text
        return ScrollView([.vertical, .horizontal]) {
            Text(shown)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        }
        .frame(maxHeight: 320)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.06)))
        .accessibilityIdentifier("sql-plan-raw")
    }

    /// The steps to draw (each collapsed node's subtree skipped, at most `maxRows`), and how
    /// many more would be drawn past the limit.
    private func visible(_ plan: SQLPlan) -> (rows: [SQLPlan.Node], more: Int) {
        var rows: [SQLPlan.Node] = []
        var more = 0
        var index = 0
        while index < plan.nodes.count {
            let node = plan.nodes[index]
            if rows.count < Self.maxRows { rows.append(node) } else { more += 1 }
            index += collapsed.contains(node.id) ? node.descendants + 1 : 1
        }
        return (rows, more)
    }

    private func tree(_ plan: SQLPlan) -> some View {
        let (rows, hidden) = visible(plan)
        let estimates = plan.nodes.contains { $0.rows != nil || $0.cost != nil }
        let actuals = plan.nodes.contains { $0.actualRows != nil || $0.actualMs != nil }
        return VStack(alignment: .leading, spacing: 1) {
            if estimates || actuals {
                HStack(spacing: 6) {
                    Text("Step")
                    Spacer(minLength: 8)
                    if estimates {
                        Text("Est. rows").frame(width: SQLPlanRow.columnWidth, alignment: .trailing)
                        Text("Cost").frame(width: SQLPlanRow.columnWidth, alignment: .trailing)
                    }
                    if actuals {
                        Text("Rows").frame(width: SQLPlanRow.columnWidth, alignment: .trailing)
                        Text("Time × loops").frame(width: SQLPlanRow.columnWidth + 20, alignment: .trailing)
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
            } else if plan.dialect == .sqlite {
                Text("SQLite's query plan has no row or cost estimates.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(rows) { node in
                SQLPlanRow(node: node, estimates: estimates, actuals: actuals, isCollapsed: collapsed.contains(node.id)) {
                    if collapsed.contains(node.id) { collapsed.remove(node.id) } else { collapsed.insert(node.id) }
                }
            }
            if hidden > 0 {
                Text("\(hidden.formatted()) more step\(hidden == 1 ? "" : "s"): collapse some, or see Raw.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One step of a plan: indented by depth, its operation, table, and index, the database's
/// estimates (and, with Analyze, what happened), and its conditions.
struct SQLPlanRow: View {
    let node: SQLPlan.Node
    let estimates: Bool
    let actuals: Bool
    let isCollapsed: Bool
    let toggle: () -> Void

    static let columnWidth: CGFloat = 62

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if node.descendants > 0 {
                    Button(action: toggle) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .frame(width: 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(isCollapsed ? "Show the \(node.descendants) step\(node.descendants == 1 ? "" : "s") under this one" : "Hide the steps under this one")
                } else {
                    Color.clear.frame(width: 12, height: 1)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(node.operation).fontWeight(.semibold).lineLimit(1).fixedSize()
                        if let table = node.table {
                            Text(table).font(.system(size: 11.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        }
                        if let index = node.index {
                            Label(index, systemImage: "key.horizontal")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .help("Index used: \(index)")
                        }
                        if node.fullScan {
                            Text("FULL SCAN")
                                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1.5)
                                .foregroundStyle(.white)
                                .background(Capsule().fill(Color.orange))
                                .fixedSize()
                                .help("The database reads every row of \(node.table ?? "the table").")
                                .accessibilityIdentifier("sql-plan-full-scan")
                        }
                        if isCollapsed {
                            Text("+\(node.descendants)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !node.details.isEmpty {
                        Text(node.details.joined(separator: " · "))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .help(node.details.joined(separator: "\n"))
                    }
                }
            }
            .padding(.leading, CGFloat(min(node.depth, 24)) * 12)
            .layoutPriority(1)
            .help(node.title)
            Spacer(minLength: 8)
            if estimates {
                metric(node.rows.map { SQLPlanRow.number($0) })
                metric(node.cost.map { SQLPlanRow.cost($0) })
            }
            if actuals {
                metric(node.actualRows.map { SQLPlanRow.number($0) })
                metric(node.actualMs.map { String(format: $0 < 10 ? "%.3f ms" : "%.1f ms", $0) + (node.loops.map { $0 == 1 ? "" : " × " + SQLPlanRow.number($0) } ?? "") }, extra: 20)
            }
        }
        .font(.callout)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 4).fill(node.fullScan ? Color.orange.opacity(0.13) : Color.clear))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(node.title + (node.fullScan ? ", full scan" : ""))
        .accessibilityValue(node.metrics)
        .accessibilityIdentifier("sql-plan-row")
    }

    private func metric(_ text: String?, extra: CGFloat = 0) -> some View {
        Text(text ?? "–")
            .font(.caption.monospacedDigit())
            .foregroundStyle(text == nil ? .tertiary : .secondary)
            .frame(width: Self.columnWidth + extra, alignment: .trailing)
    }

    static func number(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? Int64(value).formatted() : String(format: "%.1f", value)
    }

    static func cost(_ value: Double) -> String {
        value >= 1000 ? Int64(value.rounded()).formatted() : String(format: value >= 1 || value == 0 ? "%.2f" : "%.4f", value)
    }
}

/// Explain Analyze's question for a statement that can write (#147), on its window.
struct SQLAnalyzeConfirmationModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    let windowId: UUID

    func body(content: Content) -> some View {
        let pending = model.sqlExplainUI.pendingAnalyze.flatMap { $0.windowId == nil || $0.windowId == windowId ? $0 : nil }
        content.alert(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { model.answerAnalyzeConfirmation(false) } }), presenting: pending) { _ in
            // Return cancels: the safe choice is the default.
            Button("Cancel", role: .cancel) { model.answerAnalyzeConfirmation(false) }
                .keyboardShortcut(.defaultAction)
            Button("Run Explain Analyze", role: .destructive) { model.answerAnalyzeConfirmation(true) }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }
}

#if DEBUG
extension Notification.Name {
    /// DEBUG step `sql-plan:…`: switches the plan cards between Plan and Raw, or collapses a step.
    static let debugSQLPlan = Notification.Name("RunletDebugSQLPlan")
}
#endif
