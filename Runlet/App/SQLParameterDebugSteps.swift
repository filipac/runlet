#if DEBUG
import AppKit
import RunletCore

/// RUNLET_DEBUG_STEPS for the SQL parameters drawer (#168), for screenshots and scripted checks
/// with scratch data (see `DebugSteps`). In an SQL tab whose statement has placeholders (put
/// the caret there with `caret:<line>`):
/// `sql-param:<placeholder>=<type>[:<value>]` sets a row's type (text, integer, decimal,
/// boolean, null) and value as its field would; `<placeholder>` is `:name`, `?N`, or `?N@S`
/// (the Nth `?` of statement S while the drawer shows all statements); in values `\n` is a
/// newline and `\c` a comma · `sql-params:run` is Return in a field (Run, or Run All while the
/// drawer shows all statements; `wait-run` waits for it) · `sql-params:collapse|expand` ·
/// `sql-params:statement|all` (the drawer's scope switch) · `sql-params:return|escape|tab|shift+tab`
/// (the key, handed to whatever has the keyboard in the tab's window, such as the drawer field
/// a run focused; prints what has it afterwards) · `sql-params:type:<text>` (typed into that
/// field) · `sql-params:state` prints the scope, whether it is
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
            case "return", "escape", "tab", "shift+tab":
                // The key, handed straight to whatever has the keyboard in the tab's window (a
                // drawer field after a run asked for a value), so Runlet can stay in the background.
                key(argument, in: tab)
                // SwiftUI reports the new focus on a later pass.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    log("sql-params: \(argument): first-responder=\(responder(tab, drawer))")
                }
            case let typed where typed.hasPrefix("type:"):
                // Typed into the drawer field that has the keyboard, as keys would.
                guard let editor = tab.editor.textView.window?.firstResponder as? NSTextView, editor.isFieldEditor else {
                    log("sql-params: type: no drawer field has the keyboard (\(responder(tab, drawer)))")
                    return true
                }
                editor.insertText(String(typed.dropFirst(5)), replacementRange: editor.selectedRange())
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
        return "scope=\(drawer.scope) collapsed=\(drawer.collapsed) shown=\(!content.isEmpty) note=\(drawer.note ?? "none") focus-request=\(focus) first-responder=\(responder(tab, drawer)) rows=[\(rows.joined(separator: "; "))] problem=\(content.problem?.description ?? "none") summary=\(content.summary)"
    }

    /// "editor", the drawer row whose field has the keyboard, or the responder's class.
    private static func responder(_ tab: TabModel, _ drawer: SQLParameterDrawer) -> String {
        let responder = tab.editor.textView.window?.firstResponder
        if responder === tab.editor.textView { return "editor" }
        // A focused field edits through the window's field editor.
        if let editor = responder as? NSTextView, editor.isFieldEditor {
            return "field(\(drawer.focusedRow.map { "\($0)" } ?? "?"))"
        }
        return responder.map { String(describing: type(of: $0)) } ?? "none"
    }

    private static func key(_ name: String, in tab: TabModel) {
        let code: CGKeyCode = switch name {
        case "return": 36
        case "escape": 53
        default: 48
        }
        guard let window = tab.editor.textView.window, let responder = window.firstResponder,
              let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: true) else { return }
        if name.hasPrefix("shift+") { event.flags = .maskShift }
        // A background window's text input context is inactive and would drop the key.
        (responder as? NSTextView)?.inputContext?.activate()
        NSEvent(cgEvent: event).map { responder.keyDown(with: $0) }
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
