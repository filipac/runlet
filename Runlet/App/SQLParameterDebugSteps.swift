#if DEBUG
import Foundation
import RunletCore

/// RUNLET_DEBUG_STEPS for the SQL parameters drawer (#168), for screenshots and scripted checks
/// with scratch data (see `DebugSteps`). In an SQL tab whose statement has placeholders (put
/// the caret there with `caret:<line>`):
/// `sql-param:<placeholder>=<type>[:<value>]` sets a row's type (text, integer, decimal,
/// boolean, null) and value as its field would; `<placeholder>` is `:name`, `?N`, or `?N@S`
/// (the Nth `?` of statement S while the drawer shows all statements); in values `\n` is a
/// newline and `\c` a comma · `sql-params:run` is Return in a field (Run, or Run All while the
/// drawer shows all statements; `wait-run` waits for it) · `sql-params:collapse|expand` ·
/// `sql-params:statement|all` (the drawer's scope switch) · `sql-params:escape` (Escape in a
/// field: the editor gets the keyboard) · `sql-params:state` prints the scope, whether it is
/// collapsed, its note, the focused row, each row's type, value, and where it came from, and
/// the summary · `sql-params:timing[:<n>]` times n (default 200) drawer updates on the
/// current tab's text, as typing would cause them, and prints the average · `sql-history`
/// prints the newest Run History entry's code.
@MainActor
enum SQLParameterDebugSteps {
    /// Runs one step; false when `name` isn't one of these.
    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        switch name {
        case "sql-param":
            guard let tab = model.selectedTab, tab.language == .sql else {
                log("sql-param: not an SQL tab")
                return true
            }
            model.refreshSQLParameters(tab)
            let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else {
                log("sql-param: can't read \(argument)")
                return true
            }
            let spec = parts[1].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let value = spec.count > 1 ? spec[1].replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\c", with: ",") : nil
            guard let type = SQLParameterType(word: spec[0]), model.sqlParameterDrawer(for: tab).set(parts[0], type: type, text: value) else {
                log("sql-param: can't set \(argument)")
                return true
            }
        case "sql-params":
            guard let tab = model.selectedTab, tab.language == .sql else {
                log("sql-params: not an SQL tab")
                return true
            }
            let drawer = model.sqlParameterDrawer(for: tab)
            switch argument {
            case "run":
                DebugRunTiming.start(tab)
                model.runFromSQLParameterDrawer(tab)
            case "collapse", "expand":
                drawer.collapsed = argument == "collapse"
            case "statement", "all":
                model.refreshSQLParameters(tab)
                drawer.setScope(argument == "all" ? .all : .statement)
            case "escape":
                tab.editor.focus()
                log("sql-params: escape: editor focused=\(tab.editor.textView.window?.firstResponder === tab.editor.textView)")
            case let timing where timing.hasPrefix("timing"):
                log("sql-params: \(self.timing(tab, count: Int(timing.dropFirst(7)) ?? 200, model: model))")
            default:
                model.refreshSQLParameters(tab)
                log("sql-params: \(state(drawer, tab: tab))")
            }
        case "sql-history":
            log("sql-history: \(model.history.count) entries; newest: \(model.history.first.map { $0.code.replacingOccurrences(of: "\n", with: "\\n") } ?? "none")")
        default:
            return false
        }
        return true
    }

    private static func state(_ drawer: SQLParameterDrawer, tab: TabModel) -> String {
        let content = drawer.content
        let rows = content.rows.map { row in
            let value = row.value.map { $0.display() } ?? (row.isSet ? "invalid(\(row.draft.error ?? "?"))" : "not set")
            return "\(row.label(namesStatements: content.namesStatements)) \(row.draft.type.word)=\(value) [\(row.source)]"
        }
        let focus = drawer.focusRequest.map { "\($0.key)" } ?? "none"
        let responder = tab.editor.textView.window?.firstResponder
        let where_ = responder === tab.editor.textView ? "editor" : responder.map { String(describing: type(of: $0)) } ?? "none"
        return "scope=\(drawer.scope) collapsed=\(drawer.collapsed) shown=\(!content.isEmpty) note=\(drawer.note ?? "none") focus-request=\(focus) first-responder=\(where_) rows=[\(rows.joined(separator: "; "))] problem=\(content.problem?.description ?? "none") summary=\(content.summary)"
    }

    /// The cost of the drawer's refresh while typing: updates on the tab's text with one
    /// character more, then less, on a copy of the drawer (its values are untouched).
    private static func timing(_ tab: TabModel, count: Int, model: AppModel) -> String {
        let editor = tab.editor
        let text = editor.text
        let selection = editor.selectedRange
        let driver = model.sqlDriver(for: model.sqlConnectionChoice(for: tab), target: tab.target)
        var drawer = model.sqlParameterDrawer(for: tab).model
        let caret = min(selection.location, (text as NSString).length)
        let typed = (text as NSString).replacingCharacters(in: NSRange(location: caret, length: 0), with: "x")
        let start = Date()
        for index in 0..<max(1, count) {
            drawer.update(text: index.isMultiple(of: 2) ? typed : text, selection: NSRange(location: caret, length: 0), driver: driver)
        }
        let average = Date().timeIntervalSince(start) * 1000 / Double(max(1, count))
        return "timing: \(String(format: "%.3f", average)) ms per update over \(count) updates of \((text as NSString).length) characters (\(drawer.content.rows.count) rows)"
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(message)\n".utf8))
    }
}
#endif
