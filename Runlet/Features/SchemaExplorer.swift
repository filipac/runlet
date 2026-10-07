import AppKit
import RunletCore
import SwiftUI

/// The Library's Database pane (#21): the tables and views of the current tab's target and
/// connection, with columns (type, NULL, default, keys) and indexes, from the schema SQL
/// completion shares. Nothing loads by itself: Load Schema reads it (production asks first),
/// or a statement run on a non-production target already did. Its actions only open or insert
/// text; none of them runs it. Show Definition (#148) reads one table's DDL from the catalog
/// (production asks first) into a read-only sheet (`SchemaDefinitionSheetView`). Show Relations
/// (#153) opens a table's foreign key diagram from the loaded schema (`RelationsWindowView`). Its
/// Server section (#150, `DatabaseServerView`) shows the server's version, sizes, and sessions.
struct SchemaExplorerPane: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window: WindowModel?

    var body: some View {
        let _ = inspectorRenderTick("database")
        if let tab = window?.selectedTab ?? model.selectedTab, tab.language == .redis {
            // #190: a Redis tab's pane is its key browser and server panel.
            RedisDatabasePane(tab: tab)
        } else if let tab = window?.selectedTab ?? model.selectedTab {
            if tab.language == .mongodb { MongoExplorer(tab: tab) } else { content(tab) }
        } else {
            ContentUnavailableView("No Tab", systemImage: "tablecells", description: Text("Open a tab to see its target's database."))
        }
    }

    @ViewBuilder
    private func content(_ tab: TabModel) -> some View {
        let connection = model.explorerConnection(for: tab)
        let state = connection.ref.flatMap { model.sqlSchemaState(target: tab.target, connection: $0) }
        let section = model.databaseServer.section
        VStack(alignment: .leading, spacing: 0) {
            SchemaExplorerHeader(tab: tab, connection: connection, state: state, showsSchema: section == .tables)
            DatabasePaneSectionPicker()
            Divider()
            if section == .server {
                DatabaseServerView(tab: tab, connection: connection)
            } else if let schema = state?.schema, let ref = connection.ref {
                SchemaTableList(tab: tab, connection: ref, schema: schema)
            } else {
                SchemaExplorerPlaceholder(tab: tab, connection: connection, state: state)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("schema-explorer")
    }
}

/// Tables or Server (#150).
private struct DatabasePaneSectionPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var store = model.databaseServer
        Picker("Show", selection: $store.section) {
            ForEach(DatabasePaneSection.allCases, id: \.self) { section in
                Text(section.rawValue).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .help("Tables: the schema's tables and columns. Server: the server's version, sizes, and sessions.")
        .accessibilityIdentifier("database-pane-section")
    }
}

/// Target, connection, what is loaded, and Load/Reload/Forget.
private struct SchemaExplorerHeader: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    let connection: SQLConnectionChoice
    let state: SQLSchemaState?
    /// The Tables section (#150): the schema's status and Load/Reload/Forget.
    var showsSchema = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "cylinder.split.1x2").foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.targetLabel(tab.target)).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(connection.label.capitalizedFirst + (connection.savedConnection.map { " · \($0.summary)" } ?? "") + (tab.language == .sql ? "" : " (PHP tabs use the default)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if !showsSchema {
                    EmptyView()
                } else if state?.isLoading == true {
                    ProgressView().controlSize(.small)
                } else if state?.schema != nil {
                    Button {
                        model.loadSQLSchema(for: tab, connection: connection)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Reload Schema: read the tables and columns again (production asks first)")
                    .accessibilityIdentifier("schema-reload")
                    Menu {
                        Button("Reload Schema") { model.loadSQLSchema(for: tab, connection: connection) }
                        Button("Forget Schema") { if let ref = connection.ref { model.forgetSQLSchema(target: tab.target, ref: ref) } }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            if showsSchema, let status {
                // One line each (#320): when it was read ("read now", "read 18 seconds ago" on a
                // later render) must not wrap to a line of its own, which pushed the tables down.
                VStack(alignment: .leading, spacing: 1) {
                    Text(status.summary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail = status.detail {
                        Text(detail)
                            .lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help([status.summary, status.detail].compactMap { $0 }.joined(separator: "\n"))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("schema-status")
            }
            if showsSchema, case .failed(let message, _, .some) = state {
                Label("Reload failed: \(message)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
            ForEach(showsSchema ? state?.schema?.notes ?? [] : [], id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What is loaded, and when it was read.
    private var status: (summary: String, detail: String?)? {
        switch state {
        case .loaded(let schema, let date):
            ("\(schema.summary) · \(schema.driver ?? "database") via \(schema.how ?? "the connection")", "Read \(date.formatted(.relative(presentation: .named)))")
        case .loading(let previous?):
            (previous.summary, "Reading again…")
        case .failed(_, _, let previous?):
            (previous.summary, nil)
        default:
            nil
        }
    }
}

/// Before the schema is loaded: what Load Schema does, and the button.
private struct SchemaExplorerPlaceholder: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    let connection: SQLConnectionChoice
    let state: SQLSchemaState?

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 20)
            switch state {
            case .loading:
                ProgressView()
                Text("Reading the tables and columns…").foregroundStyle(.secondary)
            case .failed(let message, _, _):
                Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(.orange)
                Text("Runlet could not read the schema").font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("schema-error")
                loadButton("Try Again")
            default:
                if case .missing(let name) = connection {
                    Image(systemName: "questionmark.diamond").font(.largeTitle).foregroundStyle(.orange)
                    Text(SQLConnectionChoice.missingMessage(name))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("schema-missing-connection")
                } else {
                Image(systemName: "tablecells").font(.largeTitle).foregroundStyle(.teal)
                Text("Browse the database").font(.headline)
                Text("Load the schema of \(connection.label) on \(model.targetLabel(tab.target)) to see its tables, views, columns, keys, and indexes. Runlet \(connection.savedConnection == nil ? "boots the application" : "opens the saved connection (no application code runs)") and reads only names and types, never rows\(model.isProduction(tab.target) ? "; this target is production, so it asks first" : model.isProduction(tab.target, connection: connection.savedConnection) ? "; this connection is production, so it asks first" : ""). Running an SQL statement here loads it too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                loadButton("Load Schema")
                }
            }
            Spacer(minLength: 20)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadButton(_ title: String) -> some View {
        Button(title) { model.loadSQLSchema(for: tab, connection: connection) }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
            .accessibilityIdentifier("schema-load")
    }
}

/// The filter field and the tables, each expanding to its columns and indexes.
private struct SchemaTableList: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    let connection: SQLConnectionRef
    let schema: SQLSchemaInfo
    /// What the rows and their context menus do (#320), so rows hold neither the tab nor closures.
    @State private var rowActions = InspectorActions<SchemaRowAction>()

    var body: some View {
        @Bindable var explorer = model.schemaExplorer
        let matches = SQLSchemaExplorer.filter(schema.tables, query: explorer.search)
        let keyPrefix = SQLSchemaStore.key(tab.target, connection) + "\u{1F}"
        let actions = rowActions.handle { action in perform(action, keyPrefix: keyPrefix) }
        VStack(spacing: 0) {
            TextField("Filter tables and columns", text: $explorer.search)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .accessibilityIdentifier("schema-filter")
            if matches.isEmpty {
                ContentUnavailableView.search(text: explorer.search)
            } else {
                // Evaluated only when the tables, what's expanded, or Open as PHP change (#320):
                // a run (which sets the tab's framework) or another tab on the same target and
                // connection doesn't update the rows.
                StableInspectorList(SchemaListValue(matches: matches, expanded: explorer.expanded.filter { $0.hasPrefix(keyPrefix) }, keyPrefix: keyPrefix,
                                                    queryBuilder: model.offersQueryBuilder(for: tab))) { value in
                    SchemaTables(value: value, actions: actions)
                }
            }
        }
    }

    private func perform(_ action: SchemaRowAction, keyPrefix: String) {
        switch action {
        case .browse(let table): model.browseSchemaTable(table, schema: schema, from: tab)
        case .definition(let table): model.showSchemaDefinition(table, schema: schema, from: tab)
        case .relations(let name): model.showSchemaRelations(name, from: tab)
        case .open(let name): model.openSchemaTable(name, schema: schema, from: tab)
        case .openAsPHP(let name): model.openSchemaTableAsPHP(name, from: tab)
        case .importCSV(let table): model.importCSV(into: table, schema: schema, from: tab)
        case .insertName(let name): model.insertSchemaName(name, schema: schema)
        case .setExpanded(let name, let open):
            if open { model.schemaExplorer.expanded.insert(keyPrefix + name) } else { model.schemaExplorer.expanded.remove(keyPrefix + name) }
        }
    }
}

/// What a Database pane row does (#320).
enum SchemaRowAction {
    case browse(SQLSchemaInfo.Table)
    case definition(SQLSchemaInfo.Table)
    case relations(String)
    case open(String)
    case openAsPHP(String)
    case importCSV(SQLSchemaInfo.Table)
    case insertName(String)
    case setExpanded(table: String, Bool)
}

/// What the tables list shows (#320).
private nonisolated struct SchemaListValue: Equatable, Sendable {
    var matches: [SQLSchemaExplorer.Match]
    /// The expanded tables' keys (`keyPrefix` + name) of this target and connection.
    var expanded: Set<String>
    var keyPrefix: String
    /// The context menus offer Open as PHP (Query Builder).
    var queryBuilder: Bool
}

private struct SchemaTables: View {
    let value: SchemaListValue
    let actions: InspectorActions<SchemaRowAction>

    var body: some View {
        let _ = inspectorRenderTick("schema-list")
        List {
            ForEach(value.matches, id: \.table.name) { match in
                DisclosureGroup(isExpanded: Binding(
                    get: { match.matchedColumns || value.expanded.contains(value.keyPrefix + match.table.name) },
                    set: { actions(.setExpanded(table: match.table.name, $0)) }
                )) {
                    ForEach(match.columns, id: \.name) { column in
                        SchemaColumnRow(table: match.table.name, column: column, actions: actions)
                            .equatable()
                    }
                    if !match.matchedColumns {
                        ForEach(match.table.indexes ?? [], id: \.name) { index in
                            SchemaIndexRow(index: index)
                        }
                    }
                } label: {
                    SchemaTableRow(table: match.table, queryBuilder: value.queryBuilder, actions: actions)
                        .equatable()
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("schema-tables")
    }
}

/// Values only (#320): SwiftUI draws it again only when its table changes, or when the pointer
/// comes or goes (its own `hovering`, which redraws only this row).
///
/// #334: the name gets the row's whole width. The buttons show only while the pointer is over the
/// row, laid over its trailing end (the summary) on the list's own background, so the name never
/// moves or truncates differently under the pointer. They come in the context menu's order, each
/// with a tooltip of its own: the row's tooltip covers only the name and the summary (on the whole
/// row, it replaced the buttons' own). SwiftUI makes a DisclosureGroup's label one accessibility
/// element, buttons included, so VoiceOver reaches their actions as the row's named actions, in the
/// same order. The context menu and double-click work without the buttons.
private struct SchemaTableRow: View, Equatable {
    #if DEBUG
    @Environment(AppModel.self) private var model
    #endif
    let table: SQLSchemaInfo.Table
    /// Offer Open as PHP (Query Builder).
    let queryBuilder: Bool
    let actions: InspectorActions<SchemaRowAction>
    @State private var hovering = false

    nonisolated static func == (lhs: SchemaTableRow, rhs: SchemaTableRow) -> Bool {
        lhs.table == rhs.table && lhs.queryBuilder == rhs.queryBuilder && lhs.actions === rhs.actions
    }

    var body: some View {
        let _ = inspectorRenderTick("schema-table-row")
        HStack(spacing: 6) {
            Image(systemName: table.isView ? "eye" : "tablecells")
                .foregroundStyle(table.isView ? .purple : .teal)
                .frame(width: 16)
            Text(table.name)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            if table.isView {
                Text("VIEW")
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .foregroundStyle(.white)
                    .background(Capsule().fill(Color.purple.opacity(0.8)))
            }
            Spacer(minLength: 4)
            Text(summary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help(table.name + "\nDouble-click to open its first rows in a new SQL tab. Nothing runs until you press Run.")
        .accessibilityElement(children: .combine)
        // The buttons' actions by name, for VoiceOver and while the buttons are hidden. SwiftUI
        // lists the last one declared first, so they're declared in reverse: VoiceOver offers
        // Browse Table, Open in SQL Tab, Show Relations, then Show Definition, as the menu does.
        .accessibilityAction(named: "Show Definition") { actions(.definition(table)) }
        .accessibilityAction(named: "Show Relations") { actions(.relations(table.name)) }
        .accessibilityAction(named: "Open in SQL Tab") { actions(.open(table.name)) }
        .accessibilityAction(named: browseTitle) { actions(.browse(table)) }
        .accessibilityIdentifier("schema-table-row")
        .overlay(alignment: .trailing) {
            if showsButtons { buttons }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { actions(.open(table.name)) }
        .contextMenu { menuItems }
        #if DEBUG
        // DEBUG step `schema-menu:<table>` (#148): the context menu's items in a popover, since a
        // menu can't be snapshotted.
        .popover(isPresented: Binding(get: { model.schemaExplorer.debugMenuTable == table.name }, set: { if !$0 { model.schemaExplorer.debugMenuTable = nil } }), arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 6) { menuItems }
                .buttonStyle(.plain)
                .padding(10)
                .frame(minWidth: 220, alignment: .leading)
        }
        #endif
    }

    private var showsButtons: Bool {
        #if DEBUG
        // DEBUG step `schema-hover:<table>` (#334): the buttons without a pointer, for screenshots.
        if model.schemaExplorer.debugHoverTable == table.name { return true }
        #endif
        return hovering
    }

    private var browseTitle: String { table.isView ? "Browse View" : "Browse Table" }

    /// The row's buttons (#334), in the context menu's order. Each tooltip starts with the menu
    /// item's name and says what happens, and what doesn't.
    private var buttons: some View {
        HStack(spacing: 6) {
            Button {
                actions(.browse(table))
            } label: {
                Image(systemName: "tablecells.badge.ellipsis")
            }
            .help(table.isView
                  ? "Browse View: open its rows in a window, a page at a time. Nothing changes."
                  : "Browse Table: open its rows in a window, a page at a time. Nothing changes until you review and apply an edit.")
            .accessibilityLabel(browseTitle)
            .accessibilityIdentifier("schema-browse-table")
            Button {
                actions(.open(table.name))
            } label: {
                Image(systemName: "cylinder.split.1x2")
            }
            .help("Open in SQL Tab: write a SELECT of its first 50 rows in a new SQL tab. Nothing runs until you press Run.")
            .accessibilityLabel("Open in SQL Tab")
            .accessibilityIdentifier("schema-open-table")
            Button {
                actions(.relations(table.name))
            } label: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
            }
            .help("Show Relations: open a diagram of the tables it references and the tables that reference it. Nothing runs.")
            .accessibilityLabel("Show Relations")
            .accessibilityIdentifier("schema-show-relations")
            Button {
                actions(.definition(table))
            } label: {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
            }
            .help("Show Definition: show its \(table.isView ? "CREATE VIEW" : "CREATE TABLE") statement in a sheet. Nothing runs or changes.")
            .accessibilityLabel("Show Definition")
            .accessibilityIdentifier("schema-show-definition")
        }
        .buttonStyle(.borderless)
        .padding(.leading, 14)
        // The list's own background, so the buttons cover the summary (and the end of a long name)
        // without the row's layout changing; it fades in over the first points.
        .background {
            SidebarBackground()
                .mask {
                    HStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 12)
                        Color.black
                    }
                }
        }
    }

    /// The context menu's items: the buttons' actions first, in the same order (#334).
    @ViewBuilder private var menuItems: some View {
        Button(browseTitle) { actions(.browse(table)) }
        Button("Open in SQL Tab") { actions(.open(table.name)) }
        Button("Show Relations") { actions(.relations(table.name)) }
        Button("Show Definition") { actions(.definition(table)) }
        if queryBuilder {
            Button("Open as PHP (Query Builder)") { actions(.openAsPHP(table.name)) }
        }
        if !table.isView {
            // #152: map a CSV file's columns, preview, then insert in one transaction.
            Button("Import CSV…") { actions(.importCSV(table)) }
        }
        Divider()
        Button("Insert Name") { actions(.insertName(table.name)) }
        Button("Copy Name") { Pasteboard.copy(table.name) }
    }

    private var summary: String {
        let columns = "\(table.columns.count) col\(table.columns.count == 1 ? "" : "s")"
        return [columns, SQLSchemaExplorer.rowsText(table)].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Values only (#320).
private struct SchemaColumnRow: View, Equatable {
    let table: String
    let column: SQLSchemaInfo.Column
    let actions: InspectorActions<SchemaRowAction>

    nonisolated static func == (lhs: SchemaColumnRow, rhs: SchemaColumnRow) -> Bool {
        lhs.table == rhs.table && lhs.column == rhs.column && lhs.actions === rhs.actions
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Group {
        let _ = inspectorRenderTick("schema-column-row")
                if column.primaryKey == true {
                    Image(systemName: "key.fill").foregroundStyle(.yellow)
                } else if column.references != nil {
                    Image(systemName: "arrow.turn.down.right").foregroundStyle(.blue)
                } else {
                    Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 14)
            Text(column.name)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
            Text(SQLSchemaExplorer.details(of: column))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { actions(.insertName(column.name)) }
        .contextMenu {
            Button("Insert Name") { actions(.insertName(column.name)) }
            Button("Copy Name") { Pasteboard.copy(column.name) }
            Button("Copy \(table).\(column.name)") { Pasteboard.copy("\(table).\(column.name)") }
        }
        .help([column.name, SQLSchemaExplorer.details(of: column)].filter { !$0.isEmpty }.joined(separator: "\n") + "\nDouble-click to insert the name at the cursor.")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("schema-column-row")
    }
}

private struct SchemaIndexRow: View {
    let index: SQLSchemaInfo.Index

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "list.number")
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(index.name)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(SQLSchemaExplorer.details(of: index))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .help("Index \(index.name): \(SQLSchemaExplorer.details(of: index))")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("schema-index-row")
    }
}

/// The material a `.sidebar` list draws behind its rows (#334), for views laid over a row that
/// must hide what is under them and look like the list: it blends what is behind the window, as
/// the list does, so it matches in light and dark, and when the window is inactive.
private struct SidebarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private extension String {
    /// "the default connection" → "The default connection".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
