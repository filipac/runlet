#if DEBUG
import AppKit
import RunletCore

/// RUNLET_DEBUG_STEPS for Browse Table (#151), for screenshots and scripted checks with scratch
/// data (see `DebugSteps`). They act on the most recently opened Browse Table window:
/// `browse:<table>` (Browse Table from the current tab's Database pane, whose schema must be
/// loaded: `sql-schema:load`; production asks first) · `browse-page:next|previous|reload` ·
/// `browse-size:<rows>` · `browse-sort:<column>[:desc]` (`browse-sort:` for none) ·
/// `browse-filter:<column>|<operator>|<value>` (an operator of the result window's filters by
/// its name: `contains`, `equals`, `lessThan`, `isEmpty`, …; adds a rule) and
/// `browse-filters:apply|clear` · `browse-edit:<row>|<column>=<value>` (a pending change: rows
/// count from 1 on the page, new rows follow it; `\N` is NULL, `\c` a comma) ·
/// `browse-editor:<row>|<column>[=<text>]` (opens Edit Value on a cell, optionally typing
/// `<text>`; `browse-editor:set|null|cancel` press its controls) · `browse-add-row` ·
/// `browse-delete:<row>[+<row>…]` · `browse-select:<row>[+<row>…]` (the grid's selection) ·
/// `browse-review[:off]` (Review Changes) · `browse-apply` (its Apply; production asks with its
/// sheet) · `browse-discard` · `browse-stop` · `browse-state` (prints the window's state) ·
/// `browse-wait[:<seconds>]` (in `RunletApp`: holds the steps while a read or Apply runs).
@MainActor
enum TableBrowserDebugSteps {
    /// Runs one step; false when `name` isn't one of these.
    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        guard name.hasPrefix("browse") else { return false }
        if name == "browse" {
            guard let tab = model.selectedTab else { return true }
            let choice = model.explorerConnection(for: tab)
            guard let ref = choice.ref, let schema = model.sqlSchemaState(target: tab.target, connection: ref)?.schema, let table = schema.table(named: argument) else {
                log("browse: no table \(argument) in the loaded schema")
                return true
            }
            model.browseSchemaTable(table, schema: schema, from: tab)
            log("browse: \(table.name) editable=\(SQLTableEdits.refusal(table: table, driver: schema.driver, source: schema.source, readOnlyConnection: choice.savedConnection?.readOnly == true ? choice.savedConnection?.name : nil).map(\.description) ?? "yes")")
            return true
        }
        guard let browser = ResultWindows.latestBrowser else {
            log("\(name): no Browse Table window")
            return true
        }
        let text = argument.replacingOccurrences(of: "\\c", with: ",")
        switch name {
        case "browse-page":
            switch argument {
            case "next": model.loadTablePage(browser, offset: browser.pageOffset + (browser.page?.rows.count ?? browser.pageSize))
            case "previous": model.loadTablePage(browser, offset: max(0, browser.pageOffset - browser.pageSize))
            default: model.loadTablePage(browser, offset: browser.pageOffset)
            }
        case "browse-size":
            browser.pageSize = Int(argument) ?? SQLTableBrowse.defaultPageSize
        case "browse-sort":
            let parts = argument.split(separator: ":").map(String.init)
            browser.setSort(parts.first.map { SQLTableBrowse.Sort(column: $0, ascending: parts.count < 2 || parts[1] != "desc") })
            model.loadTablePage(browser, offset: 0)
        case "browse-filter":
            let parts = text.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard let column = browser.columns.firstIndex(where: { $0.name == parts.first }), parts.count >= 2, let op = ValueTableFilter.Operator(rawValue: parts[1]) else {
                log("browse-filter: \(argument)?")
                return true
            }
            browser.filters.append(ValueTableFilter(column: column, op: op, value: parts.count > 2 ? parts[2] : ""))
        case "browse-filters":
            if argument == "clear" { browser.filters = [] }
            model.loadTablePage(browser, offset: 0)
        case "browse-edit":
            guard let (row, column, value) = cell(text, browser) else { return true }
            if let problem = browser.cellProblem(row: row, column: column) { log("browse-edit: \(problem)") }
            let typed: SQLTableEdits.Value = value == "\\N" ? .null : .text(value ?? "")
            if let problem = SQLTableEdits.valueProblem(typed, column: browser.columns[column], dialect: browser.dialect) { log("browse-edit: \(problem)") }
            browser.set(row: row, column: column, to: typed)
        case "browse-editor":
            switch argument {
            case "set": browser.commitEdit()
            case "null": browser.cellEdit?.isNull = true
            case "cancel": browser.cellEdit = nil
            default:
                guard let (row, column, value) = cell(text, browser) else { return true }
                if let problem = browser.beginEditing(row: row, column: column) { log("browse-editor: \(problem)") }
                if let value { browser.cellEdit?.text = value }
            }
        case "browse-add-row":
            browser.addRow()
        case "browse-delete":
            browser.delete(rows: rows(argument))
        case "browse-select":
            select(rows(argument))
        case "browse-review":
            browser.isReviewing = argument != "off"
        case "browse-apply":
            model.applyTableChanges(browser)
        case "browse-discard":
            browser.discardChanges()
        case "browse-stop":
            model.stopTableBrowser(browser)
        case "browse-state":
            log(state(browser))
        default:
            return false
        }
        return true
    }

    /// Whether the latest Browse Table window is reading or applying.
    static var isBusy: Bool { ResultWindows.latestBrowser?.isBusy == true }

    static func state(_ browser: TableBrowser) -> String {
        let phase: String = switch browser.phase {
        case .idle: "idle"
        case .loading(let rows): "loading \(rows)"
        case .applying(let count): "applying \(count)"
        case .failed(let message): "failed(\(message))"
        }
        let sort = browser.sort.map { "\($0.column) \($0.ascending ? "asc" : "desc")" } ?? "none"
        let first = browser.display.rows.first.map { $0.map(\.text).joined(separator: "|") } ?? "-"
        return "browse-state: \(browser.table.name) \(browser.rowsText) phase=\(phase) sort=\(sort) filters=\(browser.appliedFilters.count) changes=\(browser.changes.count) (\(browser.changes.summary)) editable=\(browser.canEdit) report=\(browser.report?.message ?? "none") last=\(browser.lastEvent ?? "none") first=\(first)"
    }

    /// `<row>|<column>[=<value>]`: a display row (1-based) and a column by name.
    private static func cell(_ text: String, _ browser: TableBrowser) -> (Int, Int, String?)? {
        let parts = text.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let row = Int(parts[0]) else {
            log("browse: \(text)? (<row>|<column>=<value>)")
            return nil
        }
        let assignment = parts[1].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let column = browser.columns.firstIndex(where: { $0.name == assignment[0] }) else {
            log("browse: no column \(assignment[0])")
            return nil
        }
        return (row - 1, column, assignment.count > 1 ? assignment[1] : nil)
    }

    private static func rows(_ argument: String) -> [Int] {
        argument.split(separator: "+").compactMap { Int($0).map { $0 - 1 } }
    }

    /// Selects display rows in the Browse Table window's grid, as clicks would.
    private static func select(_ rows: [Int]) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title.hasSuffix(" · Browse") }),
              let grid = grids(in: window.contentView).first else {
            log("browse-select: no grid")
            return
        }
        grid.selectRowIndexes(IndexSet(rows.filter { $0 >= 0 && $0 < grid.numberOfRows }), byExtendingSelection: false)
    }

    private static func grids(in view: NSView?) -> [NSTableView] {
        guard let view else { return [] }
        if let table = view as? NSTableView, table.accessibilityIdentifier() == "result-table" { return [table] }
        return view.subviews.flatMap { grids(in: $0) }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(message)\n".utf8))
    }
}
#endif
