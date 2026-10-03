import AppKit
import RunletCore
import SwiftUI

/// The Library's Database pane (#21): the tables and views of the current tab's target and
/// connection, with columns (type, NULL, default, keys) and indexes, from the schema SQL
/// completion shares. Nothing loads by itself: Load Schema reads it (production asks first),
/// or a statement run on a non-production target already did. Its actions only open or insert
/// text; none of them runs it.
struct SchemaExplorerPane: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window: WindowModel?

    var body: some View {
        if let tab = window?.selectedTab ?? model.selectedTab {
            content(tab)
        } else {
            ContentUnavailableView("No Tab", systemImage: "tablecells", description: Text("Open a tab to see its target's database."))
        }
    }

    @ViewBuilder
    private func content(_ tab: TabModel) -> some View {
        let connection = model.explorerConnection(for: tab)
        let state = model.sqlSchemaState(target: tab.target, connection: connection)
        VStack(alignment: .leading, spacing: 0) {
            SchemaExplorerHeader(tab: tab, connection: connection, state: state)
            Divider()
            if let schema = state?.schema {
                SchemaTableList(tab: tab, connection: connection, schema: schema)
            } else {
                SchemaExplorerPlaceholder(tab: tab, connection: connection, state: state)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("schema-explorer")
    }
}

/// Target, connection, what is loaded, and Load/Reload/Forget.
private struct SchemaExplorerHeader: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    let connection: String?
    let state: SQLSchemaState?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "cylinder.split.1x2").foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.targetLabel(tab.target)).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(SQLRunInfo.label(for: connection).capitalizedFirst + (tab.language == .sql ? "" : " (PHP tabs use the default)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if state?.isLoading == true {
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
                        Button("Forget Schema") { model.forgetSQLSchema(target: tab.target, connection: connection) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            if let status {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityIdentifier("schema-status")
            }
            if case .failed(let message, _, .some) = state {
                Label("Reload failed: \(message)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
            ForEach(state?.schema?.notes ?? [], id: \.self) { note in
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
    let connection: String?
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
                Image(systemName: "tablecells").font(.largeTitle).foregroundStyle(.teal)
                Text("Browse the database").font(.headline)
                Text("Load the schema of \(SQLRunInfo.label(for: connection)) on \(model.targetLabel(tab.target)) to see its tables, views, columns, keys, and indexes. Runlet boots the application and reads only names and types, never rows\(model.isProduction(tab.target) ? "; this target is production, so it asks first" : ""). Running an SQL statement here loads it too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                loadButton("Load Schema")
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
    let connection: String?
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
        .contextMenu {
            Button("Open in SQL Tab") { model.openSchemaTable(table.name, schema: schema, from: tab) }
            if SQLSchemaExplorer.hasQueryBuilder(framework: model.framework(for: tab)) {
                Button("Open as PHP (Query Builder)") { model.openSchemaTableAsPHP(table.name, from: tab) }
            }
            Divider()
            Button("Insert Name") { model.insertSchemaName(table.name, schema: schema) }
            Button("Copy Name") { Pasteboard.copy(table.name) }
        }
        .help(table.name + "\nDouble-click to open its first rows in a new SQL tab. Nothing runs until you press Run.")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("schema-table-row")
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
