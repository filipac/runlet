import AppKit
import Observation
import RunletCore
import SwiftUI
import UniformTypeIdentifiers

/// A result shown in its own window (#21): a table a run already produced (an SQL tab's rows,
/// or a PHP collection in the Table view), with search, filter rules, sorting, resizable
/// columns, and copy/CSV of what is shown. Opening it runs nothing; it is kept only while its
/// window is open.
@MainActor
@Observable
final class ResultDocument: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String?
    let table: ValueTable
    var query = ValueTableQuery()
    /// Columns the user hid (indices into `table.columns`).
    var hiddenColumns: Set<Int> = []

    init(title: String, subtitle: String?, table: ValueTable, query: ValueTableQuery = ValueTableQuery()) {
        self.title = title
        self.subtitle = subtitle
        self.table = table
        self.query = query
    }

    var visibleColumns: [Int] { table.columns.indices.filter { !hiddenColumns.contains($0) } }
    var shownRows: [Int] { query.rowIndices(in: table) }
}

/// Open result windows' documents, by window value.
@MainActor
enum ResultWindows {
    static var documents: [UUID: ResultDocument] = [:]
    /// Opening order, for `latest`.
    private static var order: [UUID] = []
    /// Set by a main window (it has the `openWindow` action).
    static var openAction: ((UUID) -> Void)?

    /// Opens `table` in a window of its own; `query` is the search and sort it starts with
    /// (an output table's filter and sort, #162).
    static func open(title: String, subtitle: String?, table: ValueTable, query: ValueTableQuery = ValueTableQuery()) {
        let document = ResultDocument(title: title, subtitle: subtitle, table: table, query: query)
        documents[document.id] = document
        order.append(document.id)
        openAction?(document.id)
    }

    /// The most recently opened document that is still open (DEBUG steps).
    static var latest: ResultDocument? { order.reversed().lazy.compactMap { documents[$0] }.first }
}

struct ResultWindowView: View {
    let id: UUID?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let id, let document = ResultWindows.documents[id] {
            ResultBrowser(document: document)
                .navigationTitle(document.title)
                .navigationSubtitle(document.subtitle ?? "")
                .onDisappear { ResultWindows.documents[id] = nil }
        } else {
            ContentUnavailableView("Result Closed", systemImage: "tablecells", description: Text("This result is no longer available. Run the statement again and open its table in a window."))
                .frame(minWidth: 420, minHeight: 240)
        }
    }
}

/// Search, filter rules, the grid, and the footer.
private struct ResultBrowser: View {
    @Bindable var document: ResultDocument

    var body: some View {
        let shown = document.shownRows
        VStack(spacing: 0) {
            ResultFilterBar(document: document)
            Divider()
            // The output's grid (#162), with the window's columns and filter rules.
            ValueTableGrid(table: document.table, rows: shown, columns: document.visibleColumns,
                           sortColumn: document.query.sortColumn, ascending: document.query.ascending,
                           onFilter: { document.query.filters.append($0) },
                           onSort: { column, ascending in
                               document.query.sortColumn = column
                               document.query.ascending = ascending
                           })
                .accessibilityIdentifier("result-grid")
            Divider()
            ResultFooter(document: document, shown: shown)
        }
        .frame(minWidth: 560, minHeight: 320)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("result-window")
    }
}

private struct ResultFilterBar: View {
    @Bindable var document: ResultDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search all columns", text: $document.query.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .accessibilityIdentifier("result-search")
                Menu {
                    ForEach(document.table.columns.indices, id: \.self) { column in
                        Button(document.table.columns[column]) {
                            document.query.filters.append(ValueTableFilter(column: column))
                        }
                    }
                } label: {
                    Label("Add Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
                .fixedSize()
                .accessibilityIdentifier("result-add-filter")
                if document.query.isFiltered || !document.query.filters.isEmpty {
                    Button("Clear") {
                        document.query.search = ""
                        document.query.filters = []
                    }
                    .accessibilityIdentifier("result-clear-filters")
                }
                Spacer()
            }
            ForEach($document.query.filters) { $filter in
                HStack(spacing: 6) {
                    Text(filter.id == document.query.filters.first?.id ? "Where" : "and")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                    Picker("Column", selection: $filter.column) {
                        ForEach(document.table.columns.indices, id: \.self) { column in
                            Text(document.table.columns[column]).tag(column)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Picker("Operator", selection: $filter.op) {
                        ForEach(ValueTableFilter.Operator.allCases) { op in
                            Text(op.title).tag(op)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if !filter.op.isUnary {
                        TextField("Value", text: $filter.value)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                    }
                    Button {
                        document.query.filters.removeAll { $0.id == filter.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this filter")
                    Spacer()
                }
                .controlSize(.small)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("result-filter-rule")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct ResultFooter: View {
    @Bindable var document: ResultDocument
    let shown: [Int]

    var body: some View {
        HStack(spacing: 10) {
            Text(countText)
                .font(.callout)
                .foregroundStyle(document.query.isFiltered ? AnyShapeStyle(.teal) : AnyShapeStyle(.secondary))
                .accessibilityIdentifier("result-count")
            if document.table.omittedRows > 0 {
                Text("(\(document.table.omittedRows.formatted()) more not loaded)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                ForEach(document.table.columns.indices, id: \.self) { column in
                    Toggle(document.table.columns[column], isOn: Binding(
                        get: { !document.hiddenColumns.contains(column) },
                        set: { isOn in
                            if isOn { document.hiddenColumns.remove(column) } else if document.visibleColumns.count > 1 { document.hiddenColumns.insert(column) }
                        }
                    ))
                }
                if !document.hiddenColumns.isEmpty {
                    Divider()
                    Button("Show All Columns") { document.hiddenColumns = [] }
                }
            } label: {
                Label(document.hiddenColumns.isEmpty ? "Columns" : "Columns (\(document.hiddenColumns.count) hidden)", systemImage: "rectangle.split.3x1")
            }
            .fixedSize()
            .accessibilityIdentifier("result-columns")
            Button("Copy CSV") { Pasteboard.copy(document.table.csv(rows: shown, columns: document.visibleColumns)) }
                .help("Copies the rows and columns shown, as CSV")
            Button("Export CSV…") { export() }
                .help("Saves the rows and columns shown as a CSV file")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var countText: String {
        let total = document.table.rows.count
        let columns = document.visibleColumns.count
        let rows = shown.count == total ? "\(total.formatted()) row\(total == 1 ? "" : "s")" : "\(shown.count.formatted()) of \(total.formatted()) rows"
        return "\(rows) · \(columns) column\(columns == 1 ? "" : "s")"
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let base = document.title.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        panel.nameFieldStringValue = (base.isEmpty ? "result" : base) + ".csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(document.table.csv(rows: shown, columns: document.visibleColumns).utf8).write(to: url, options: .atomic)
    }
}
