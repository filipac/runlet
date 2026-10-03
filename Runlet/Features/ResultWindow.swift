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

    init(title: String, subtitle: String?, table: ValueTable) {
        self.title = title
        self.subtitle = subtitle
        self.table = table
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

    static func open(title: String, subtitle: String?, table: ValueTable) {
        let document = ResultDocument(title: title, subtitle: subtitle, table: table)
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
            ResultGrid(document: document, rows: shown)
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

// MARK: - Grid

/// A native table for the result: row numbers, resizable and sortable columns (click a
/// header), multiple selection with ⌘C (tab-separated), and a context menu to copy or filter
/// by a value.
private struct ResultGrid: NSViewRepresentable {
    @Bindable var document: ResultDocument
    let rows: [Int]

    func makeCoordinator() -> Coordinator { Coordinator(document: document) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ResultTableView()
        table.coordinator = context.coordinator
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.style = .fullWidth
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 10, height: 2)
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.menu = NSMenu()
        table.menu?.delegate = context.coordinator
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.table = table
        context.coordinator.rebuildColumns()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.visibleColumns != document.visibleColumns { coordinator.rebuildColumns() }
        if coordinator.rows != rows {
            coordinator.rows = rows
            coordinator.table?.reloadData()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        let document: ResultDocument
        weak var table: NSTableView?
        var rows: [Int] = []
        var visibleColumns: [Int] = []

        init(document: ResultDocument) {
            self.document = document
        }

        func rebuildColumns() {
            guard let table else { return }
            visibleColumns = document.visibleColumns
            rows = document.shownRows
            for column in table.tableColumns { table.removeTableColumn(column) }
            let number = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("#"))
            number.title = "#"
            number.width = max(36, CGFloat(String(document.table.rows.count).count) * 8 + 16)
            number.isEditable = false
            table.addTableColumn(number)
            for index in visibleColumns {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
                column.title = document.table.columns[index]
                column.isEditable = false
                column.minWidth = 40
                column.width = width(for: index)
                column.sortDescriptorPrototype = NSSortDescriptor(key: "c\(index)", ascending: true)
                table.addTableColumn(column)
            }
            if let sort = document.query.sortColumn {
                table.sortDescriptors = [NSSortDescriptor(key: "c\(sort)", ascending: document.query.ascending)]
            }
            table.reloadData()
        }

        /// A width that fits the header and the first rows' values, up to 360 points.
        private func width(for column: Int) -> CGFloat {
            let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            var widest = (document.table.columns[column] as NSString).size(withAttributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]).width + 24
            for row in document.table.rows.prefix(200) where column < row.count {
                widest = max(widest, (row[column].text.prefix(80) as NSString).size(withAttributes: [.font: font]).width + 12)
            }
            return min(360, max(48, widest))
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, row < rows.count else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("cell")
            let field = (tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField) ?? {
                let label = NSTextField(labelWithString: "")
                label.identifier = identifier
                label.lineBreakMode = .byTruncatingTail
                label.cell?.truncatesLastVisibleLine = true
                return label
            }()
            let index = rows[row]
            if tableColumn.identifier.rawValue == "#" {
                field.stringValue = document.table.rowKeys.indices.contains(index) ? document.table.rowKeys[index] : String(index + 1)
                field.textColor = .tertiaryLabelColor
                field.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                field.alignment = .right
                return field
            }
            let column = Int(tableColumn.identifier.rawValue.dropFirst()) ?? 0
            let cells = document.table.rows[index]
            let cell = column < cells.count ? cells[column] : ValueTable.Cell(text: "", number: nil, isNull: true)
            field.stringValue = String(cell.text.prefix(2000)).replacingOccurrences(of: "\n", with: " ⏎ ")
            field.toolTip = cell.text.count > 60 ? String(cell.text.prefix(2000)) : nil
            field.alignment = cell.number != nil ? .right : .left
            if cell.isNull {
                field.textColor = .tertiaryLabelColor
                field.font = NSFontManager.shared.convert(.systemFont(ofSize: NSFont.systemFontSize), toHaveTrait: .italicFontMask)
            } else {
                field.textColor = cell.number != nil ? .systemPurple : .labelColor
                field.font = cell.number != nil ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) : .systemFont(ofSize: NSFont.systemFontSize)
            }
            return field
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key, let column = Int(key.dropFirst()) else {
                document.query.sortColumn = nil
                return
            }
            document.query.sortColumn = column
            document.query.ascending = descriptor.ascending
        }

        /// The selected rows (indices into the table), or the clicked one.
        func selectedRows() -> [Int] {
            guard let table else { return [] }
            return table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0] : nil }
        }

        func copySelection() {
            let selected = selectedRows()
            guard !selected.isEmpty else { return }
            Pasteboard.copy(document.table.tsv(rows: selected, columns: visibleColumns))
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, table.clickedRow >= 0, table.clickedRow < rows.count else { return }
            let row = rows[table.clickedRow]
            if !table.selectedRowIndexes.contains(table.clickedRow) {
                table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
            }
            let selectedCount = table.selectedRowIndexes.count
            let clickedColumn = table.clickedColumn >= 0 ? table.tableColumns[table.clickedColumn].identifier.rawValue : "#"
            if clickedColumn != "#", let column = Int(clickedColumn.dropFirst()), column < document.table.rows[row].count {
                let cell = document.table.rows[row][column]
                let name = document.table.columns[column]
                menu.addItem(item("Copy Value") { Pasteboard.copy(cell.text) })
                menu.addItem(.separator())
                let shown = cell.text.count > 24 ? String(cell.text.prefix(24)) + "…" : cell.text
                if cell.isNull {
                    menu.addItem(item("Filter: \(name) is empty or NULL") { [weak self] in self?.addFilter(column, .isEmpty, "") })
                    menu.addItem(item("Filter: \(name) isn't empty") { [weak self] in self?.addFilter(column, .isNotEmpty, "") })
                } else {
                    menu.addItem(item("Filter: \(name) = \(shown)") { [weak self] in self?.addFilter(column, .equals, cell.text) })
                    menu.addItem(item("Filter: \(name) ≠ \(shown)") { [weak self] in self?.addFilter(column, .doesNotEqual, cell.text) })
                }
                menu.addItem(.separator())
            }
            menu.addItem(item(selectedCount > 1 ? "Copy \(selectedCount) Rows" : "Copy Row") { [weak self] in self?.copySelection() })
            menu.addItem(item(selectedCount > 1 ? "Copy \(selectedCount) Rows as CSV" : "Copy Row as CSV") { [weak self] in
                guard let self else { return }
                Pasteboard.copy(self.document.table.csv(rows: self.selectedRows(), columns: self.visibleColumns))
            })
        }

        private func addFilter(_ column: Int, _ op: ValueTableFilter.Operator, _ value: String) {
            document.query.filters.append(ValueTableFilter(column: column, op: op, value: value))
        }

        private func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
            let handler = MenuAction(action)
            let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
            item.target = handler
            // The item keeps its handler alive.
            item.representedObject = handler
            return item
        }
    }
}

/// ⌘C copies the selected rows.
private final class ResultTableView: NSTableView {
    weak var coordinator: ResultGrid.Coordinator?

    @objc func copy(_ sender: Any?) {
        coordinator?.copySelection()
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selectedRowIndexes.count > 0 }
        return super.validateUserInterfaceItem(item)
    }
}

/// A context menu item's action.
private final class MenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() { handler() }
}
