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
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
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

    private var status: String? {
        switch state {
        case .loaded(let schema, let date):
            "\(schema.summary) · \(schema.driver ?? "database") via \(schema.how ?? "the connection") · read \(date.formatted(.relative(presentation: .named)))"
        case .loading(let previous?):
            "\(previous.summary) · reading again…"
        case .failed(_, _, let previous?):
            previous.summary
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

    var body: some View {
        @Bindable var explorer = model.schemaExplorer
        let matches = SQLSchemaExplorer.filter(schema.tables, query: explorer.search)
        let keyPrefix = SQLSchemaStore.key(tab.target, connection) + "\u{1F}"
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
                List {
                    ForEach(matches, id: \.table.name) { match in
                        DisclosureGroup(isExpanded: Binding(
                            get: { match.matchedColumns || explorer.expanded.contains(keyPrefix + match.table.name) },
                            set: { isOpen in
                                if isOpen { explorer.expanded.insert(keyPrefix + match.table.name) } else { explorer.expanded.remove(keyPrefix + match.table.name) }
                            }
                        )) {
                            ForEach(match.columns, id: \.name) { column in
                                SchemaColumnRow(table: match.table.name, column: column, schema: schema)
                            }
                            if !match.matchedColumns {
                                ForEach(match.table.indexes ?? [], id: \.name) { index in
                                    SchemaIndexRow(index: index)
                                }
                            }
                        } label: {
                            SchemaTableRow(tab: tab, table: match.table, schema: schema)
                        }
                    }
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier("schema-tables")
            }
        }
    }
}

private struct SchemaTableRow: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    let table: SQLSchemaInfo.Table
    let schema: SQLSchemaInfo

    var body: some View {
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
            Button {
                model.browseSchemaTable(table, schema: schema, from: tab)
            } label: {
                Image(systemName: "tablecells.badge.ellipsis")
            }
            .buttonStyle(.borderless)
            .help("Browse Table: page through its rows in a window, sorted and filtered on the server\(table.isView ? "" : "; edit them when it has a primary key (you review the SQL before anything runs)")")
            .accessibilityIdentifier("schema-browse-table")
            Button {
                model.showSchemaDefinition(table, schema: schema, from: tab)
            } label: {
                Image(systemName: "doc.plaintext")
            }
            .buttonStyle(.borderless)
            .help("Show Definition: read its \(table.isView ? "CREATE VIEW" : "CREATE TABLE") from the catalog and show it (nothing runs)")
            .accessibilityIdentifier("schema-show-definition")
            Button {
                model.showSchemaRelations(table.name, from: tab)
            } label: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
            }
            .buttonStyle(.borderless)
            .help("Show Relations: a diagram of the tables it references and that reference it, from the loaded schema (#153)")
            .accessibilityIdentifier("schema-show-relations")
            Button {
                model.openSchemaTable(table.name, schema: schema, from: tab)
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .help("Open in SQL Tab: SELECT its first 50 rows in a new SQL tab (it doesn't run)")
            .accessibilityIdentifier("schema-open-table")
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.openSchemaTable(table.name, schema: schema, from: tab) }
        .contextMenu { actions }
        #if DEBUG
        // DEBUG step `schema-menu:<table>` (#148): the context menu's items in a popover, since a
        // menu can't be snapshotted.
        .popover(isPresented: Binding(get: { model.schemaExplorer.debugMenuTable == table.name }, set: { if !$0 { model.schemaExplorer.debugMenuTable = nil } }), arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 6) { actions }
                .buttonStyle(.plain)
                .padding(10)
                .frame(minWidth: 220, alignment: .leading)
        }
        #endif
        .help(table.name + "\nDouble-click to open its first rows in a new SQL tab. Nothing runs until you press Run.")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("schema-table-row")
    }

    /// The context menu's items.
    @ViewBuilder private var actions: some View {
        Button(table.isView ? "Browse View" : "Browse Table") { model.browseSchemaTable(table, schema: schema, from: tab) }
        Button("Open in SQL Tab") { model.openSchemaTable(table.name, schema: schema, from: tab) }
        Button("Show Definition") { model.showSchemaDefinition(table, schema: schema, from: tab) }
        Button("Show Relations") { model.showSchemaRelations(table.name, from: tab) }
        if model.offersQueryBuilder(for: tab) {
            Button("Open as PHP (Query Builder)") { model.openSchemaTableAsPHP(table.name, from: tab) }
        }
        if !table.isView {
            // #152: map a CSV file's columns, preview, then insert in one transaction.
            Button("Import CSV…") { model.importCSV(into: table, schema: schema, from: tab) }
        }
        Divider()
        Button("Insert Name") { model.insertSchemaName(table.name, schema: schema) }
        Button("Copy Name") { Pasteboard.copy(table.name) }
    }

    private var summary: String {
        let columns = "\(table.columns.count) col\(table.columns.count == 1 ? "" : "s")"
        return [columns, SQLSchemaExplorer.rowsText(table)].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct SchemaColumnRow: View {
    @Environment(AppModel.self) private var model
    let table: String
    let column: SQLSchemaInfo.Column
    let schema: SQLSchemaInfo

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Group {
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
        .onTapGesture(count: 2) { model.insertSchemaName(column.name, schema: schema) }
        .contextMenu {
            Button("Insert Name") { model.insertSchemaName(column.name, schema: schema) }
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

private extension String {
    /// "the default connection" → "The default connection".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
