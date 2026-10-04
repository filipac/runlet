#if DEBUG
import AppKit
import RunletCore

/// RUNLET_DEBUG_STEPS for the MongoDB query builder (#217), for screenshots and scripted checks
/// with scratch data only (see `DebugSteps`, `MongoDebugSteps`). In arguments, `\c` is a comma
/// and `\n` a newline:
/// `mongo-builder:open|close|toggle` (Show Builder) · `mongo-builder:read` (Read Query) ·
/// `mongo-builder:flush` (writes a waiting change now) · `mongo-builder:insert` (Insert as New
/// Query) · `mongo-builder:select` · `mongo-builder:burst` (five changes 0.1 s apart, as typing
/// makes: one write) · `mongo-builder:undo-check` (builder writes are one Undo step each and
/// leave other queries alone, on an editor of its own that is never shown) ·
/// `mongo-builder:state` (prints the builder, the tab's text, and its caret) ·
/// `mongo-builder-set:<json>` (puts a query into the builder as if built in its forms: the
/// change is written into the tab like any other) · `mongo-builder-start:<collection>` (Start
/// from Collection) · `mongo-builder-filter:<field>|<canonical JSON>` (Filter by This Value) ·
/// `mongo-builder-width:<points>` · `mongo-builder-scroll:<section identifier>` (scrolls the
/// form, e.g. to `mongo-builder-sort`).
@MainActor
enum MongoBuilderDebugSteps {
    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        guard name.hasPrefix("mongo-builder") else { return false }
        guard let tab = model.selectedTab else { return true }
        let state = model.mongoBuilder(for: tab)
        let text = argument.replacingOccurrences(of: "\\c", with: ",").replacingOccurrences(of: "\\n", with: "\n")
        switch name {
        case "mongo-builder":
            switch argument {
            case "open": if !state.isOpen { model.toggleMongoBuilder(tab) }
            case "close": if state.isOpen { model.toggleMongoBuilder(tab) }
            case "toggle": model.toggleBuilder(tab)
            case "read": model.readMongoBuilder(tab)
            case "flush": model.flushMongoBuilder(tab)
            case "insert": model.insertMongoBuilderQuery(tab)
            case "select": model.selectMongoBuilderQuery(tab)
            case "burst": burst(model, tab)
            case "undo-check": RedisDebugSteps.log("mongo-builder undo-check: \(undoCheck())")
            default: RedisDebugSteps.log("mongo-builder: \(describe(model, tab))")
            }
        case "mongo-builder-set":
            switch MongoQueryBuilder.read(text) {
            case .success(let builder):
                if !state.isOpen { model.toggleMongoBuilder(tab) }
                state.phase = .ready
                state.builder = builder
            case .failure(let error):
                RedisDebugSteps.log("mongo-builder-set: \(error.localizedDescription)")
            }
        case "mongo-builder-start":
            model.startMongoBuilder(tab, collection: text)
        case "mongo-builder-filter":
            let parts = text.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let value = try? MongoJSON.parse(parts[1]) else {
                RedisDebugSteps.log("mongo-builder-filter: expected <field>|<JSON>")
                return true
            }
            model.mongoBuilderFilter(tab, field: parts[0], value: value)
        case "mongo-builder-scroll":
            state.debugScrollTarget = argument
        case "mongo-builder-width":
            state.width = Double(argument) ?? state.width
        default:
            RedisDebugSteps.log("unknown step \(name)")
        }
        return true
    }

    static func describe(_ model: AppModel, _ tab: TabModel) -> String {
        let state = model.mongoBuilder(for: tab)
        let builder = state.builder
        let editorText = tab.editor.text.replacingOccurrences(of: "\n", with: "\\n")
        let json = (try? builder?.json())??.inline ?? "-"
        return "open=\(state.isOpen) phase=\(state.phase) lines=\(state.lines.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "-") writes=\(state.writes) pending=\(state.isWriting) effect=\(builder?.effect.map { "\($0)" } ?? "-") raw=\(builder.map(AppModel.rawCount) ?? 0) problem=\(builder?.problem ?? "-") incomplete=\(builder?.incomplete ?? []) runProblem=\(builder?.runProblem ?? "-") note=\(state.note?.text ?? "-") | builder=\(json) | text=\(editorText) caret=\(tab.editor.selectedRange.location) undo=\(tab.editor.textView.undoManager?.undoActionName ?? "-")"
    }

    /// Five changes 0.1 s apart (a value typed in the builder): written once, 0.4 s after the last.
    private static func burst(_ model: AppModel, _ tab: TabModel) {
        let state = model.mongoBuilder(for: tab)
        Task { @MainActor in
            for step in 1...5 {
                guard var builder = state.builder else { return }
                builder.limit = .number(String(10 * step))
                state.builder = builder
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// The builder's writes are one Undo step each and leave the tab's other queries and the
    /// user's typing alone, checked on an editor of its own that is never shown (steps aren't
    /// events, so in a tab AppKit's per-event undo group would hold every change since the tab
    /// was loaded).
    private static func undoCheck() -> String {
        let original = "{\"collection\": \"p217_orders\", \"operation\": \"find\"}\n\n{\"collection\": \"other\", \"operation\": \"find\"}\n"
        let editor = EditorController(text: original, selection: NSRange(location: 5, length: 0))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = editor.scrollView
        guard let undo = window.undoManager else { return "no undo manager" }
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.textView.insertText(" ", replacementRange: NSRange(location: 1, length: 0))
        undo.endUndoGrouping()
        editor.textView.breakUndoCoalescing()
        let typed = editor.text
        func write(_ change: (inout MongoQueryBuilder) -> Void) -> String? {
            guard case .query(let range) = MongoBuilderText.target(in: editor.text, selection: editor.selectedRange),
                  var builder = try? MongoQueryBuilder.read((editor.text as NSString).substring(with: range)).get() else { return nil }
            change(&builder)
            guard let query = builder.text else { return nil }
            editor.apply(MongoBuilderText.rewrite(range, with: query, in: editor.text, selection: editor.selectedRange), actionName: "Query Builder")
            return editor.text
        }
        let first = write { $0.filter = MongoFilterGroup(children: [.rule(MongoFilterRule(path: "status", value: .string("paid")))]) }
        let name = undo.undoActionName
        let second = write { $0.limit = .number("10") }
        let other = "{\"collection\": \"other\", \"operation\": \"find\"}"
        undo.undo()
        let afterOne = editor.text
        undo.undo()
        let afterTwo = editor.text
        let ok = first != nil && second != nil && name == "Query Builder" && afterOne == first && afterTwo == typed
            && second?.contains(other) == true && second?.contains("\"limit\": 10") == true && first?.hasPrefix("{\n  \"collection\": \"p217_orders\"") == true
        return "\(ok ? "ok" : "FAILED") action=\(name) first=\(first?.replacingOccurrences(of: "\n", with: "\\n") ?? "-") after-undo=\(afterTwo.replacingOccurrences(of: "\n", with: "\\n"))"
    }
}
#endif
