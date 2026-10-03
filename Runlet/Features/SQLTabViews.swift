import RunletCore
import SwiftUI

/// "SQL" capsule on an SQL tab's tab (#35).
struct SQLBadge: View {
    var body: some View {
        Text("SQL")
            .font(.system(size: 8.5, weight: .bold, design: .rounded))
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .foregroundStyle(.white)
            .background(Capsule().fill(Color.teal))
            .help("SQL tab: statements run through the target application's own database connection")
            .accessibilityLabel("SQL tab")
            .accessibilityIdentifier("sql-badge")
    }
}

/// The bar above an SQL tab's editor (#35): which connection statements use, and what Run
/// runs. Choosing a connection never connects or runs anything.
struct SQLTabBar: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    @State private var showsOther = false
    @State private var otherName = ""

    var body: some View {
        let names = model.sqlConnectionNames(for: tab)
        HStack(spacing: 8) {
            Image(systemName: "cylinder.split.1x2").foregroundStyle(.teal)
            Text("SQL").fontWeight(.semibold)
            Menu {
                Button {
                    model.setSQLConnection(nil, for: tab)
                } label: {
                    checked(tab.sqlConnection == nil, defaultLabel(names))
                }
                if !names.isEmpty {
                    Divider()
                    ForEach(names, id: \.self) { name in
                        Button {
                            model.setSQLConnection(name, for: tab)
                        } label: {
                            checked(tab.sqlConnection == name, name)
                        }
                    }
                }
                Divider()
                Button("Other Connection…") {
                    otherName = tab.sqlConnection ?? ""
                    showsOther = true
                }
                if names.isEmpty {
                    Text("The application's connection names appear here after a run.")
                }
            } label: {
                Text(tab.sqlConnection.map { "Connection: \($0)" } ?? "Default connection")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("The application's database connection the statement runs on. Runlet uses the project's own configuration and never asks for or stores credentials.")
            .accessibilityIdentifier("sql-connection-picker")
            .popover(isPresented: $showsOther, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connection name").font(.headline)
                    Text("A connection from the application's configuration, such as a key of Laravel's database.connections or a Doctrine connection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("Name", text: $otherName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitOther)
                        .accessibilityIdentifier("sql-connection-name")
                    HStack {
                        Spacer()
                        Button("Cancel") { showsOther = false }
                        Button("Use", action: commitOther).keyboardShortcut(.defaultAction)
                    }
                }
                .padding(12)
                .frame(width: 280)
            }
            Divider().frame(height: 14)
            // Run All Statements (#129).
            Button {
                model.runAllSQL(tab)
            } label: {
                Label("Run All", systemImage: "play.square.stack")
            }
            .buttonStyle(.borderless)
            .disabled(tab.isRunning)
            .help("Run All Statements (⌥⇧⌘R): every statement of the selection, or of the tab, in order on one connection. Runlet stops at the first error.")
            .accessibilityIdentifier("sql-run-all")
            Toggle("In a Transaction", isOn: Binding(get: { tab.sqlTransaction }, set: { model.setSQLTransaction($0, for: tab) }))
                .toggleStyle(.checkbox)
                .help("Run All Statements runs the script in one transaction: committed after the last statement, rolled back when one fails. MySQL and MariaDB commit DDL (CREATE, ALTER, DROP, TRUNCATE, …) at once, even in a transaction; Runlet says so before running. Turn it off for scripts that manage their own transactions or statements that can't run in one (VACUUM, CREATE INDEX CONCURRENTLY).")
                .accessibilityIdentifier("sql-transaction")
            Text("⌘R runs the selected statement, or the one at the caret, through \(model.targetLabel(tab.target))'s own connection.")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.teal.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sql-tab-bar")
    }

    private func defaultLabel(_ names: [String]) -> String {
        // Drivers list the default connection first.
        names.first.map { "Default connection (\($0))" } ?? "Default connection"
    }

    @ViewBuilder
    private func checked(_ isOn: Bool, _ title: String) -> some View {
        if isOn { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private func commitOther() {
        model.setSQLConnection(otherName, for: tab)
        showsOther = false
    }
}

/// An SQL tab's result (#35): a sortable, filterable table of the rows (with CSV copy and
/// export), or the number of rows a statement affected; with timing and the connection used.
struct SQLResultCard: View {
    let result: SQLResultInfo

    var body: some View {
        Card(title: result.statement.map { "Statement \($0.index) of \($0.count)" } ?? "SQL", subtitle: subtitle, tint: .teal, copyText: result.plainText) {
            VStack(alignment: .leading, spacing: 6) {
                if let text = result.statement?.text {
                    // Run All Statements (#129): which statement this is.
                    Text(CodePreview.lines(text, limit: 3))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("sql-statement-text")
                }
                if result.hasResultSet {
                    if result.columns.isEmpty {
                        Text("The statement returned no rows.").foregroundStyle(.secondary)
                    } else {
                        ValueTableView(table: result.table)
                    }
                    if result.truncated == true {
                        Label(truncationNote, systemImage: "scissors")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("sql-truncated")
                    }
                    if let omitted = result.omittedColumns, omitted > 0 {
                        Label("\(omitted) more column\(omitted == 1 ? "" : "s") not shown", systemImage: "scissors")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Label(result.summary, systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.teal)
                        .accessibilityIdentifier("sql-affected-rows")
                }
                Text(origin)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("output-sql")
    }

    private var subtitle: String {
        [result.statement.map { "line \($0.line)" }, result.hasResultSet ? result.summary : nil, result.elapsedText].compactMap { $0 }.joined(separator: " · ")
    }

    private var truncationNote: String {
        let limit = (result.maxRows ?? result.rows.count).formatted()
        return result.truncation == "bytes"
            ? "The result was larger than Runlet keeps (8 MiB of cells); the rows after these were not fetched. Add a LIMIT or select fewer columns."
            : "Runlet shows at most \(limit) rows per statement; the rows after these were not fetched. Add a LIMIT, or page with OFFSET."
    }

    private var origin: String {
        let connection = result.connection.map { "connection “\($0)”" } ?? "default connection"
        return [result.driver, connection, result.source.map { "via \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }
}
