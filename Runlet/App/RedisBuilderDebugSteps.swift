#if DEBUG
import AppKit
import RunletCore

/// RUNLET_DEBUG_STEPS for the Redis command builder (#218), for screenshots and scripted
/// checks (see `DebugSteps`, `RedisDebugSteps`):
/// `redis-builder:open|close|toggle` (Show Command Builder) · `redis-builder:read` (Read Line) ·
/// `redis-builder:insert|replace` (its buttons) · `redis-builder:picker` (the command list) ·
/// `redis-builder:undo-check` (Insert is one Undo step, on an editor of its own that is never
/// shown) · `redis-builder:state` (prints the builder, the tab's text, and its caret) ·
/// `redis-builder-search:<text>` (the list's search) · `redis-builder-pick:<command>` (chooses a
/// command, as a click on it) · `redis-builder-line:<command line>` (fills the form from a line,
/// without touching the tab) · `redis-builder-key:<key>|<item>` (a listed key's Insert Command
/// item, e.g. `user:1|EXPIRE…`) · `redis-key-menu:<key>|off` (a listed key's context menu, with
/// Insert Command open, in a popover).
@MainActor
enum RedisBuilderDebugSteps {
    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        guard name.hasPrefix("redis-builder") || name == "redis-key-menu" else { return false }
        guard let tab = model.selectedTab else { return true }
        let state = model.redisBuilder(for: tab)
        switch name {
        case "redis-builder":
            switch argument {
            case "open": if !state.isOpen { model.toggleRedisBuilder(tab) }
            case "close": if state.isOpen { model.toggleRedisBuilder(tab) }
            case "toggle": model.toggleRedisBuilder(tab)
            case "read": model.readRedisBuilderLine(tab)
            case "insert": model.writeRedisBuilder(tab, replace: false)
            case "replace": model.writeRedisBuilder(tab, replace: true)
            case "picker": state.showsPicker = true
            case "undo-check": RedisDebugSteps.log("redis-builder undo-check: \(undoCheck())")
            default: RedisDebugSteps.log("redis-builder: \(describe(model, tab))")
            }
        case "redis-builder-search":
            state.isOpen = true
            state.showsPicker = true
            state.search = argument
        case "redis-builder-pick":
            state.isOpen = true
            if let spec = RedisCommandSpecs.spec(named: argument) {
                model.chooseRedisBuilderCommand(tab, spec: spec)
            } else {
                model.chooseRedisBuilderCommand(tab, spec: nil, rawName: argument)
            }
        case "redis-builder-line":
            switch RedisCommandForm.parse(line: argument) {
            case .success(let form): model.openRedisBuilder(tab, form: form)
            case .failure(let error): RedisDebugSteps.log("redis-builder-line: \(error)")
            }
        case "redis-builder-key":
            let parts = argument.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let key = model.redisPaneKey(for: tab),
                  let entry = model.redisUI.browser(key).keys.first(where: { $0.displayName == parts[0] }),
                  let command = entry.builderCommands.first(where: { $0.title == parts[1] }) else {
                RedisDebugSteps.log("redis-builder-key: no listed key or item \(argument)")
                return true
            }
            model.openRedisBuilder(tab, key: entry, command: command)
        case "redis-key-menu":
            model.redisBuilders.debugMenuKey = argument == "off" ? nil : argument
        default:
            RedisDebugSteps.log("unknown step \(name)")
        }
        return true
    }

    static func describe(_ model: AppModel, _ tab: TabModel) -> String {
        let state = model.redisBuilder(for: tab)
        let form = state.form
        let issues = form?.issues.map { ($0.isBlocking ? "!" : "") + $0.message } ?? []
        let text = tab.editor.text.replacingOccurrences(of: "\n", with: "\\n")
        return "open=\(state.isOpen) picker=\(state.showsPicker) search=\(state.search) command=\(form?.nameWords.joined(separator: " ") ?? "-") line=\(form?.line ?? "-") extra=\(form?.extra ?? []) issues=\(issues) canWrite=\(form?.canWrite ?? false) note=\(state.note?.text ?? "-") | text=\(text) caret=\(tab.editor.selectedRange.location) undo=\(tab.editor.textView.undoManager?.undoActionName ?? "-")"
    }

    /// Insert is one Undo step that leaves earlier edits alone, checked on an editor of its own
    /// that is never shown (steps aren't events, so in a tab AppKit's per-event undo group would
    /// hold every change since the tab was loaded).
    private static func undoCheck() -> String {
        let editor = EditorController(text: "GET a\nGET b", selection: NSRange(location: 2, length: 0))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = editor.scrollView
        guard let undo = window.undoManager else { return "no undo manager" }
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.textView.insertText("# typed\n", replacementRange: NSRange(location: 0, length: 0))
        undo.endUndoGrouping()
        editor.textView.breakUndoCoalescing()
        let typed = editor.text
        let form = RedisCommandForm.parse(["ZRANGE", "scores", "0", "-1", "WITHSCORES"])
        editor.apply(RedisBuilderText.insert(form.line, in: editor.text, at: 10), actionName: "Insert Redis Command")
        let inserted = editor.text
        let name = undo.undoActionName
        undo.undo()
        let afterInsertUndo = editor.text
        editor.textView.setSelectedRange(NSRange(location: 10, length: 0))
        if let edit = RedisBuilderText.replace("TTL a", in: editor.text, at: 10) { editor.apply(edit, actionName: "Replace Redis Command") }
        let replaced = editor.text
        undo.undo()
        let ok = inserted == "# typed\nGET a\nZRANGE scores 0 -1 WITHSCORES\nGET b" && afterInsertUndo == typed && name == "Insert Redis Command"
            && replaced == "# typed\nTTL a\nGET b" && editor.text == typed
        return "\(ok ? "ok" : "FAILED") action=\(name) inserted=\(inserted.replacingOccurrences(of: "\n", with: "\\n")) replaced=\(replaced.replacingOccurrences(of: "\n", with: "\\n")) after-undo=\(editor.text.replacingOccurrences(of: "\n", with: "\\n"))"
    }
}
#endif
