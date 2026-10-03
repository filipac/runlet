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
            .help("SQL tab: statements run through the target application's own database connection, or a connection you saved for the target")
            .accessibilityLabel("SQL tab")
            .accessibilityIdentifier("sql-badge")
    }
}

/// The bar above an SQL tab's editor (#35): which connection statements use, and what Run
/// runs. Choosing a connection never connects or runs anything.
struct SQLTabBar: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window: WindowModel?
    let tab: TabModel
    @State private var showsPicker = false

    var body: some View {
        let choice = model.sqlConnectionChoice(for: tab)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "cylinder.split.1x2").foregroundStyle(.teal)
                Text("SQL").fontWeight(.semibold)
                Button {
                    showsPicker.toggle()
                } label: {
                    HStack(spacing: 4) {
                        if case .saved(let connection) = choice {
                            DatabaseDriverIcon(driver: connection.driver)
                        }
                        Text(title(choice))
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .help("The database connection the statement runs on: one the application configures (it needs no credentials from Runlet), or one you saved for this target (its password stays in the macOS Keychain).")
                .accessibilityIdentifier("sql-connection-picker")
                .popover(isPresented: $showsPicker, arrowEdge: .bottom) {
                    SQLConnectionPicker(tab: tab, close: { showsPicker = false }, newConnection: newConnection, editConnections: editConnections)
                }
                #if DEBUG
                // DEBUG step `db-picker` (DatabaseDebugSteps): opens the picker for screenshots.
                .onReceive(NotificationCenter.default.publisher(for: .debugShowConnectionPicker)) { note in
                    if model.selectedTab === tab { showsPicker = note.object as? Bool ?? true }
                }
                #endif
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
                Divider().frame(height: 14)
                SQLSchemaMenu(tab: tab)
                Text(hint(choice))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            if case .missing(let name) = choice {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(SQLConnectionChoice.missingMessage(name))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("sql-missing-connection")
                    Spacer(minLength: 0)
                    if TargetLibrary.supportsDatabaseConnections(tab.target) {
                        Button("New Connection…") { newConnection(named: name) }
                    }
                }
                .font(.callout)
                .padding(.bottom, 5)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .background(Color.teal.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sql-tab-bar")
    }

    private func title(_ choice: SQLConnectionChoice) -> String {
        switch choice {
        case .app(let name): name.map { "Connection: \($0)" } ?? "Default connection"
        case .saved(let connection): connection.name
        case .missing(let name): "\(name) (missing)"
        }
    }

    private func hint(_ choice: SQLConnectionChoice) -> String {
        switch choice {
        case .app: "⌘R runs the selected statement, or the one at the caret, through \(model.targetLabel(tab.target))'s own connection."
        case .saved(let connection): "⌘R runs the selected statement, or the one at the caret, on \(connection.summary), opened from \(model.targetLabel(tab.target))."
        case .missing: "Choose a connection to run statements."
        }
    }

    private func newConnection() {
        newConnection(named: nil)
    }

    private func newConnection(named name: String?) {
        let draft = model.newConnectionDraft(for: tab.target, useInTab: tab.id)
        if let name { draft.connection.name = name }
        model.databaseUI.windowId = window?.id
        model.databaseUI.editor = draft
    }

    private func editConnections() {
        model.databaseUI.windowId = window?.id
        model.databaseUI.listTarget = tab.target
    }
}

/// The SQL bar's connection picker (#138): the application's connections (the default, the
/// names its driver reported, any other name), the target's saved connections, and New /
/// Edit Connections. Choosing one never connects or runs anything.
struct SQLConnectionPicker: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    var close: () -> Void
    var newConnection: () -> Void
    var editConnections: () -> Void
    @State private var askingName = false
    @State private var otherName = ""

    var body: some View {
        if askingName {
            otherNameForm
        } else {
            list
        }
    }

    private var list: some View {
        let choice = model.sqlConnectionChoice(for: tab)
        let names = model.sqlConnectionNames(for: tab)
        let saved = model.databaseConnections(for: tab.target)
        let supportsSaved = TargetLibrary.supportsDatabaseConnections(tab.target)
        return VStack(alignment: .leading, spacing: 2) {
            sectionHeader("Application connections")
            item(defaultLabel(names), detail: "The application's own; needs no credentials", checked: choice == .app(nil)) {
                model.setSQLConnection(nil, for: tab)
                close()
            }
            ForEach(names, id: \.self) { name in
                item(name, detail: nil, checked: choice == .app(name)) {
                    model.setSQLConnection(name, for: tab)
                    close()
                }
            }
            if case .app(let chosen?) = choice, !names.contains(chosen) {
                item(chosen, detail: nil, checked: true) { close() }
            }
            item("Other Connection…", detail: nil, checked: false) {
                if case .app(let name) = choice { otherName = name ?? "" }
                askingName = true
            }
            .accessibilityIdentifier("sql-other-connection")
            if names.isEmpty {
                Text("The application's connection names appear here after a run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)
            }
            Divider().padding(.vertical, 4)
            sectionHeader("Saved connections")
            if !supportsSaved {
                Text("The Laravel sandbox can't have saved connections yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            } else if saved.isEmpty {
                Text("None saved for \(model.targetLabel(tab.target)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
            ForEach(saved) { connection in
                item(connection.name, detail: connection.summary, checked: choice.savedConnection?.id == connection.id, driver: connection.driver) {
                    model.setSQLSavedConnection(connection, for: tab)
                    close()
                }
                .accessibilityIdentifier("sql-saved-connection-\(connection.name)")
            }
            if case .missing(let name) = choice {
                item("\(name) (not defined here)", detail: "From a workspace or another target", checked: true) { close() }
            }
            if supportsSaved {
                Divider().padding(.vertical, 4)
                item("New Connection…", detail: nil, checked: false) {
                    close()
                    newConnection()
                }
                .accessibilityIdentifier("sql-new-connection")
                item("Edit Connections…", detail: nil, checked: false) {
                    close()
                    editConnections()
                }
                .accessibilityIdentifier("sql-edit-connections")
            }
        }
        .padding(8)
        .frame(width: 330)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sql-connection-list")
    }

    private var otherNameForm: some View {
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
                Button("Cancel") { askingName = false }
                Button("Use", action: commitOther).keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private func commitOther() {
        model.setSQLConnection(otherName, for: tab)
        askingName = false
        close()
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 2)
    }

    private func item(_ title: String, detail: String?, checked: Bool, driver: DatabaseDriverKind? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .opacity(checked ? 1 : 0)
                    .frame(width: 12)
                if let driver { DatabaseDriverIcon(driver: driver) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(SQLPickerRowStyle())
    }

    private func defaultLabel(_ names: [String]) -> String {
        // Drivers list the default connection first.
        names.first.map { "Default connection (\($0))" } ?? "Default connection"
    }
}

/// A list row that highlights under the pointer, like a menu item.
private struct SQLPickerRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(configuration.isPressed ? 0.3 : hovering ? 0.15 : 0)))
            .onHover { hovering = $0 }
    }
}

/// The SQL bar's schema menu (#128): what completion knows about the connection, and Load
/// Schema. Loading reads table and column names only; production asks first.
struct SQLSchemaMenu: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel

    var body: some View {
        let state = model.sqlSchemaState(for: tab)
        Menu {
            Button(state?.schema == nil ? "Load Schema" : "Reload Schema") { model.loadSQLSchema(for: tab) }
                .disabled(state?.isLoading == true)
                .accessibilityIdentifier("sql-load-schema")
            if state != nil {
                Button("Forget Schema") { model.forgetSQLSchema(for: tab) }
            }
            Divider()
            Text(detail(state))
        } label: {
            Label(title(state), systemImage: symbol(state))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Completion offers SQL keywords and functions; with the schema it also offers this connection's tables and columns. Runlet reads the schema when you load it, or with a statement you run (never on production without asking). It reads names and types, no rows, and keeps them in memory until you quit.")
        .accessibilityIdentifier("sql-schema-menu")
    }

    private func title(_ state: SQLSchemaState?) -> String {
        switch state {
        case nil: "No schema"
        case .loading: "Loading schema…"
        case .loaded(let schema, _): "\(schema.tables.count.formatted()) table\(schema.tables.count == 1 ? "" : "s")"
        case .failed(_, _, let previous): previous.map { "\($0.tables.count.formatted()) tables" } ?? "Schema unavailable"
        }
    }

    private func symbol(_ state: SQLSchemaState?) -> String {
        switch state {
        case .failed(_, _, nil): "exclamationmark.triangle"
        case .loading: "hourglass"
        default: "tablecells"
        }
    }

    private func detail(_ state: SQLSchemaState?) -> String {
        switch state {
        case nil:
            return "Completion offers keywords. Load the schema, or run a statement, to complete tables and columns."
        case .loading:
            return "Reading table and column names…"
        case .loaded(let schema, let date):
            return "\(schema.summary) via \(schema.how ?? "the connection"), read \(date.formatted(.relative(presentation: .named)))."
        case .failed(let message, _, _):
            return "Could not read the schema: \(message)"
        }
    }
}

/// An SQL tab's result (#35): a sortable, filterable table of the rows (with CSV copy and
/// export), or the number of rows a statement affected; with timing and the connection used.
struct SQLResultCard: View {
    let result: SQLResultInfo
    /// Names the result window (#21), e.g. "orders" for a tab the schema explorer opened.
    var tabTitle = "SQL"
    /// The statement that ran (a single run's comes from the tab), for the result window.
    var statementText: String?

    var body: some View {
        // The table is built once, with the result (#162); the copied text only on Copy.
        Card(title: result.statement.map { "Statement \($0.index) of \($0.count)" } ?? "SQL", subtitle: subtitle, tint: .teal, copyTextProvider: { result.plainText }) {
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
                        ValueTableView(table: result.table, title: windowTitle, subtitle: [statementText.map { CodePreview.title($0) }, origin].compactMap { $0 }.joined(separator: " — "))
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

    /// The result window's title (#21): the tab, the statement of a Run All, and the rows.
    private var windowTitle: String {
        ([tabTitle] + [result.statement.map { "Statement \($0.index) of \($0.count)" }].compactMap { $0 } + [result.summary]).joined(separator: " · ")
    }

    private var truncationNote: String {
        let limit = (result.maxRows ?? result.rows.count).formatted()
        return result.truncation == "bytes"
            ? "The result was larger than Runlet keeps (8 MiB of cells); the rows after these were not fetched. Add a LIMIT or select fewer columns."
            : "Runlet shows at most \(limit) rows per statement; the rows after these were not fetched. Add a LIMIT, or page with OFFSET."
    }

    private var origin: String { result.originText }
}
