import AppKit
import RunletCore
import SwiftUI
import UniformTypeIdentifiers

/// A table in the output (#162): an SQL tab's rows, or a PHP value's Table view. A filter field,
/// Open in Window (#21), and CSV above a native grid that makes views only for the rows on
/// screen, so a result of a thousand rows draws and scrolls like a short one. The grid grows
/// with its rows up to `OutputTableLayout.maxHeight`, then scrolls inside. Filtering and
/// sorting run off the main thread, and only when the filter or the sort changes.
struct ValueTableView: View {
    let table: ValueTable
    /// The result window's title (#21).
    var title = "Table"
    var subtitle: String?
    /// Load Next (#146) of an SQL result, which the result window offers too.
    var pager: SQLResultPager?
    @State private var search = ""
    @State private var sortColumn: Int?
    @State private var ascending = true
    /// The rows the filter and sort leave, in order; nil while they leave every row as it came.
    @State private var shownRows: [Int]?

    private var rows: [Int] { shownRows ?? Array(table.rows.indices) }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("Filter rows", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 220)
                    .accessibilityIdentifier("table-filter")
                if shownRows != nil, rows.count != table.rows.count {
                    Text("\(rows.count.formatted()) of \(table.rows.count.formatted())")
                        .font(.caption)
                        .foregroundStyle(.teal)
                        .accessibilityIdentifier("table-shown-count")
                }
                Spacer()
                // A larger view with filters and resizable columns (#21); runs nothing.
                Button {
                    ResultWindows.open(title: title, subtitle: subtitle, table: table, query: query, pager: pager)
                } label: {
                    Label("Open in Window", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .controlSize(.small)
                .help("Opens this table in its own window, with search, filters, sorting, and resizable columns")
                .accessibilityIdentifier("table-open-window")
                Button("Copy CSV") { Pasteboard.copy(table.csv(rows: rows)) }
                    .controlSize(.small)
                    .help("Copies the rows shown, as CSV")
                Button("Export CSV…") { exportCSV(rows) }
                    .controlSize(.small)
                    .help("Saves the rows shown as a CSV file")
            }
            ValueTableGrid(table: table, rows: rows, sortColumn: sortColumn, ascending: ascending, compact: true) { column, ascending in
                sortColumn = column
                self.ascending = ascending
            }
            .frame(height: Self.gridHeight(rows: table.rows.count))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.2)))
            if table.omittedRows > 0 {
                Text("\(table.omittedRows) more rows not shown (runner limit)").font(.caption).foregroundStyle(.orange)
            }
        }
        .task(id: QueryKey(search: search, sortColumn: sortColumn, ascending: ascending, rowCount: table.rows.count)) { await refresh() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("value-table")
    }

    private var query: ValueTableQuery {
        ValueTableQuery(search: search, sortColumn: sortColumn, ascending: ascending)
    }

    /// What the shown rows depend on.
    private struct QueryKey: Equatable {
        var search: String
        var sortColumn: Int?
        var ascending: Bool
        var rowCount: Int
    }

    /// Filters and sorts on another thread; typing waits a moment so each key press doesn't
    /// filter the whole table again.
    private func refresh() async {
        let query = query
        guard query.isFiltered || query.sortColumn != nil else {
            shownRows = nil
            return
        }
        if query.isFiltered {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
        }
        let table = table
        let rows = await Task.detached(priority: .userInitiated) { query.rowIndices(in: table) }.value
        guard !Task.isCancelled else { return }
        shownRows = rows
    }

    /// The header and every row up to `OutputTableLayout.maxHeight`, plus room for a
    /// horizontal scroller that doesn't overlay the rows (a mouse without a trackpad).
    static func gridHeight(rows: Int) -> CGFloat {
        let scroller = NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        return CGFloat(OutputTableLayout.gridHeight(rows: rows, scroller: Double(scroller)))
    }

    private func exportCSV(_ rows: [Int]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "runlet-export.csv"
        if panel.runModal() == .OK, let url = panel.url {
            try? table.csv(rows: rows).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// The native grid behind output tables and the result window (#21, #162): an `NSTableView`
/// that makes views only for the visible rows. A row-number column, then the table's columns
/// (resizable; click a header to sort), multiple selection with ⌘C (tab-separated), and a
/// context menu to copy a value or rows (as text, CSV, JSON, or a PHP array), and, where
/// `onFilter` is set, to filter by a value.
struct ValueTableGrid: NSViewRepresentable {
    let table: ValueTable
    /// The rows shown, in order (indices into `table.rows`).
    let rows: [Int]
    /// The columns shown, in order (indices into `table.columns`); nil for all of them.
    var columns: [Int]?
    var sortColumn: Int?
    var ascending = true
    /// Output cards: a smaller monospaced font, and vertical scrolls that reach the grid's top
    /// or bottom move the output instead.
    var compact = false
    /// Adds a filter rule (the result window's context menu); nil leaves those items out.
    var onFilter: ((ValueTableFilter) -> Void)?
    /// A header was clicked: the column to sort by (nil for the result's own order), ascending.
    var onSort: (Int?, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let table = ValueGridTableView()
        table.coordinator = coordinator
        table.dataSource = coordinator
        table.delegate = coordinator
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.style = .fullWidth
        table.rowHeight = compact ? CGFloat(OutputTableLayout.rowHeight) : 20
        table.intercellSpacing = NSSize(width: 10, height: 2)
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.headerView?.frame.size.height = CGFloat(OutputTableLayout.headerHeight)
        table.menu = NSMenu()
        table.menu?.delegate = coordinator
        table.setAccessibilityIdentifier(compact ? "value-table-grid" : "result-table")
        let scroll = compact ? EdgeForwardingScrollView() : NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        coordinator.table = table
        coordinator.rebuildColumns()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let previous = coordinator.grid
        coordinator.grid = self
        if previous.table != table || previous.columns != columns {
            if previous.columns == columns, previous.table.columns == table.columns, table.rows.count > previous.table.rows.count {
                // Load Next (#146) added rows: the columns keep the widths they have.
                coordinator.fitRowNumbers()
                coordinator.table?.reloadData()
            } else {
                coordinator.rebuildColumns()
            }
        } else if previous.rows != rows {
            coordinator.table?.reloadData()
        }
        coordinator.showSort()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var grid: ValueTableGrid
        weak var table: NSTableView?
        /// The columns shown (indices into the table's columns).
        private(set) var shownColumns: [Int] = []
        /// Set while the grid shows the parent's sort, so the table's callback doesn't echo it.
        private var showingSort = false
        private lazy var fonts = Fonts(compact: grid.compact)

        init(_ grid: ValueTableGrid) {
            self.grid = grid
        }

        private var data: ValueTable { grid.table }

        func rebuildColumns() {
            guard let table else { return }
            shownColumns = grid.columns ?? Array(data.columns.indices)
            for column in table.tableColumns { table.removeTableColumn(column) }
            let number = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("#"))
            number.title = "#"
            number.width = rowNumberWidth
            number.isEditable = false
            table.addTableColumn(number)
            let widths = Self.widths(of: data, columns: shownColumns, fonts: fonts)
            for (index, width) in zip(shownColumns, widths) {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
                column.title = data.columns[index]
                column.headerToolTip = data.columns[index]
                column.isEditable = false
                column.minWidth = 40
                column.width = width
                column.sortDescriptorPrototype = NSSortDescriptor(key: "c\(index)", ascending: true)
                table.addTableColumn(column)
            }
            table.reloadData()
            showSort()
        }

        /// The row-number column's width for the longest row key.
        private var rowNumberWidth: CGFloat {
            let longestKey = data.rowKeys.count > 2000 ? String(data.rowKeys.count) : data.rowKeys.max(by: { $0.utf16.count < $1.utf16.count }) ?? "#"
            return min(160, max(36, CGFloat(longestKey.utf16.count) * (grid.compact ? 7 : 8) + 16))
        }

        /// Rows were added: the row numbers may need a wider column (never narrower).
        func fitRowNumbers() {
            guard let column = table?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("#")) else { return }
            let width = rowNumberWidth
            if width > column.width { column.width = width }
        }

        /// Shows the parent's sort in the headers.
        func showSort() {
            guard let table else { return }
            let wanted = grid.sortColumn.map { [NSSortDescriptor(key: "c\($0)", ascending: grid.ascending)] } ?? []
            guard table.sortDescriptors != wanted else { return }
            showingSort = true
            table.sortDescriptors = wanted
            showingSort = false
        }

        /// Widths that fit each header and the longest of the first 200 values (measuring only
        /// the few longest by length), up to 360 points.
        static func widths(of table: ValueTable, columns: [Int], fonts: Fonts) -> [CGFloat] {
            let sample = table.rows.prefix(200)
            return columns.map { column in
                var widest = (table.columns[column] as NSString).size(withAttributes: [.font: fonts.header]).width + 24
                let longest = sample.compactMap { column < $0.count ? $0[column] : nil }
                    .sorted { $0.text.utf16.count > $1.text.utf16.count }
                    .prefix(3)
                for cell in longest {
                    let text = String(cell.text.prefix(80)) as NSString
                    widest = max(widest, text.size(withAttributes: [.font: fonts.font(for: cell)]).width + 12)
                }
                return min(360, max(48, widest.rounded(.up)))
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { grid.rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, row < grid.rows.count, grid.rows[row] < data.rows.count else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("cell")
            let field = (tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField) ?? {
                let label = NSTextField(labelWithString: "")
                label.identifier = identifier
                label.lineBreakMode = .byTruncatingTail
                label.cell?.truncatesLastVisibleLine = true
                return label
            }()
            let index = grid.rows[row]
            if tableColumn.identifier.rawValue == "#" {
                field.stringValue = data.rowKeys.indices.contains(index) ? data.rowKeys[index] : String(index + 1)
                field.textColor = .tertiaryLabelColor
                field.font = fonts.rowNumber
                field.alignment = .right
                field.toolTip = nil
                return field
            }
            let column = Int(tableColumn.identifier.rawValue.dropFirst()) ?? 0
            let cells = data.rows[index]
            let cell = column < cells.count ? cells[column] : ValueTable.Cell(text: "", number: nil, isNull: true)
            let text = cell.text.utf16.count > 2000 ? String(cell.text.prefix(2000)) : cell.text
            field.stringValue = text.contains("\n") ? text.replacingOccurrences(of: "\n", with: " ⏎ ") : text
            field.toolTip = text.utf16.count > 40 ? text : nil
            field.alignment = cell.number != nil ? .right : .left
            field.font = fonts.font(for: cell)
            field.textColor = cell.isNull ? .tertiaryLabelColor : cell.number != nil ? .systemPurple : .labelColor
            return field
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !showingSort else { return }
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key, let column = Int(key.dropFirst()) else {
                grid.onSort(nil, true)
                return
            }
            grid.onSort(column, descriptor.ascending)
        }

        /// The selected rows (indices into the table), in the order shown.
        func selectedRows() -> [Int] {
            guard let table else { return [] }
            return table.selectedRowIndexes.compactMap { $0 < grid.rows.count ? grid.rows[$0] : nil }
        }

        func copySelection() {
            let selected = selectedRows()
            guard !selected.isEmpty else { return }
            Pasteboard.copy(data.tsv(rows: selected, columns: shownColumns))
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, table.clickedRow >= 0, table.clickedRow < grid.rows.count else { return }
            let row = grid.rows[table.clickedRow]
            if !table.selectedRowIndexes.contains(table.clickedRow) {
                table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
            }
            let data = data
            let selectedCount = table.selectedRowIndexes.count
            let clickedColumn = table.clickedColumn >= 0 ? table.tableColumns[table.clickedColumn].identifier.rawValue : "#"
            if clickedColumn != "#", let column = Int(clickedColumn.dropFirst()), column < data.rows[row].count {
                let cell = data.rows[row][column]
                menu.addItem(item("Copy Value") { Pasteboard.copy(cell.text) })
                if let onFilter = grid.onFilter {
                    let name = data.columns[column]
                    let shown = cell.text.count > 24 ? String(cell.text.prefix(24)) + "…" : cell.text
                    menu.addItem(.separator())
                    if cell.isNull {
                        menu.addItem(item("Filter: \(name) is empty or NULL") { onFilter(ValueTableFilter(column: column, op: .isEmpty)) })
                        menu.addItem(item("Filter: \(name) isn't empty") { onFilter(ValueTableFilter(column: column, op: .isNotEmpty)) })
                    } else {
                        menu.addItem(item("Filter: \(name) = \(shown)") { onFilter(ValueTableFilter(column: column, op: .equals, value: cell.text)) })
                        menu.addItem(item("Filter: \(name) ≠ \(shown)") { onFilter(ValueTableFilter(column: column, op: .doesNotEqual, value: cell.text)) })
                    }
                }
                menu.addItem(.separator())
            }
            menu.addItem(item(selectedCount > 1 ? "Copy \(selectedCount) Rows" : "Copy Row") { [weak self] in self?.copySelection() })
            menu.addItem(item(selectedCount > 1 ? "Copy \(selectedCount) Rows as CSV" : "Copy Row as CSV") { [weak self] in
                guard let self else { return }
                Pasteboard.copy(data.csv(rows: self.selectedRows(), columns: self.shownColumns))
            })
            if selectedCount == 1, row < data.rowFields.count {
                let fields = data.rowFields[row]
                menu.addItem(item("Copy Row as JSON") { Pasteboard.copy(ValueExport.json(fields: fields)) })
                menu.addItem(item("Copy Row as PHP Array") { Pasteboard.copy(ValueExport.php(fields: fields)) })
            }
        }

        private func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
            let handler = GridMenuAction(action)
            let item = NSMenuItem(title: title, action: #selector(GridMenuAction.run), keyEquivalent: "")
            item.target = handler
            // The item keeps its handler alive.
            item.representedObject = handler
            return item
        }
    }

    /// The grid's fonts, made once rather than per cell.
    struct Fonts {
        let regular: NSFont
        let number: NSFont
        let null: NSFont
        let header: NSFont
        let rowNumber: NSFont

        init(compact: Bool) {
            let size = compact ? NSFont.smallSystemFontSize : NSFont.systemFontSize
            regular = compact ? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
            number = compact ? regular : .monospacedDigitSystemFont(ofSize: size, weight: .regular)
            null = NSFontManager.shared.convert(regular, toHaveTrait: .italicFontMask)
            header = .boldSystemFont(ofSize: NSFont.systemFontSize)
            rowNumber = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        }

        func font(for cell: ValueTable.Cell) -> NSFont {
            cell.isNull ? null : cell.number != nil ? number : regular
        }
    }
}

/// ⌘C copies the selected rows.
private final class ValueGridTableView: NSTableView {
    weak var coordinator: ValueTableGrid.Coordinator?

    @objc func copy(_ sender: Any?) {
        coordinator?.copySelection()
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selectedRowIndexes.count > 0 }
        return super.validateUserInterfaceItem(item)
    }
}

/// An output card's grid scrolls inside the output: a vertical scroll that starts where the
/// grid can't move that way (it fits, or is at its top or bottom) scrolls the output instead,
/// so the pointer passing over a table doesn't stop the output from scrolling.
private final class EdgeForwardingScrollView: NSScrollView {
    /// The current gesture (and its momentum) goes to the output.
    private var forwarding = false

    override func scrollWheel(with event: NSEvent) {
        // A trackpad gesture is decided when it begins, and its momentum follows; a mouse
        // wheel's clicks are decided one by one.
        let startsGesture = event.phase == .began || event.phase == .mayBegin || (event.phase == [] && event.momentumPhase == [])
        if startsGesture, let document = documentView {
            let visible = contentView.bounds
            forwarding = OutputTableLayout.scrollGoesToOutput(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                                                              visibleMinY: visible.minY, visibleHeight: visible.height,
                                                              documentHeight: document.frame.height, flipped: document.isFlipped)
        }
        if forwarding, let next = nextResponder {
            next.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// A context menu item's action.
private final class GridMenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() { handler() }
}
