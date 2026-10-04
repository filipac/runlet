import AppKit
import Observation
import RunletCore

/// A Redis tab's command builder (#218), in memory while Runlet runs: whether it is open, the
/// picker's search, and the form. The tab's text stays the source of truth: the builder writes
/// a command into it only on Insert or Replace Line, and never runs anything.
@MainActor
@Observable
final class RedisBuilderState {
    /// What the builder last read or wrote, under its header.
    struct Note: Equatable {
        var text: String
        var isWarning = false
    }

    var isOpen = false
    /// The command list instead of the form.
    var showsPicker = true
    var search = ""
    var form: RedisCommandForm?
    var note: Note?
    /// The panel's width while dragging its edge; the saved one otherwise.
    var width: Double = 320
}

/// Each Redis tab's builder (#218).
@MainActor
@Observable
final class RedisBuilderStore {
    @ObservationIgnored private var states: [UUID: RedisBuilderState] = [:]
    #if DEBUG
    /// DEBUG step `redis-key-menu:<key>`: the key whose context menu items show in a popover.
    var debugMenuKey: String?
    #endif

    @ObservationIgnored private static var stores: [ObjectIdentifier: RedisBuilderStore] = [:]

    static func shared(for model: AppModel) -> RedisBuilderStore {
        let key = ObjectIdentifier(model)
        if let existing = stores[key] { return existing }
        let created = RedisBuilderStore()
        stores[key] = created
        return created
    }

    func state(for tabId: UUID) -> RedisBuilderState {
        if let state = states[tabId] { return state }
        let state = RedisBuilderState()
        states[tabId] = state
        return state
    }
}

extension AppModel {
    var redisBuilders: RedisBuilderStore { RedisBuilderStore.shared(for: self) }

    func redisBuilder(for tab: TabModel) -> RedisBuilderState {
        redisBuilders.state(for: tab.id)
    }

    /// Show Command Builder (⌥⌘B, the Redis bar's button): opens the builder on the caret's
    /// line, or closes it.
    func toggleRedisBuilder(_ tab: TabModel) {
        guard tab.language == .redis else { return }
        let state = redisBuilder(for: tab)
        if state.isOpen {
            state.isOpen = false
            tab.editor.focus()
        } else {
            state.isOpen = true
            readRedisBuilderLine(tab)
        }
    }

    /// Opens the builder with `form` (the key browser's Insert Command items). Nothing is
    /// written until Insert or Replace Line.
    func openRedisBuilder(_ tab: TabModel, form: RedisCommandForm, note: String? = nil) {
        guard tab.language == .redis else { return }
        let state = redisBuilder(for: tab)
        state.isOpen = true
        state.form = form
        state.showsPicker = false
        state.search = ""
        state.note = note.map { RedisBuilderState.Note(text: $0) }
    }

    /// Read Line: the caret's command line into the form. A line the builder can't read leaves
    /// the form fresh (the command list) and the text untouched.
    func readRedisBuilderLine(_ tab: TabModel) {
        let state = redisBuilder(for: tab)
        let editor = tab.editor
        let (line, result) = RedisBuilderText.read(editor.text, at: editor.selectedRange.location)
        switch result {
        case .success(let form):
            state.form = form
            state.showsPicker = false
            state.search = ""
            let what = form.spec == nil ? "a command without a syntax in Runlet, as raw arguments" : form.extra.isEmpty ? form.nameWords.joined(separator: " ") : "\(form.nameWords.joined(separator: " ")), with \(form.extra.count) argument\(form.extra.count == 1 ? "" : "s") it couldn't place kept raw"
            state.note = .init(text: "Read line \(line): \(what).")
        case .failure(.blank), .failure(.comment):
            state.form = nil
            state.showsPicker = true
            state.note = nil
        case .failure(.unreadable(let why)):
            state.form = nil
            state.showsPicker = true
            state.search = ""
            state.note = .init(text: "Line \(line) can't be read: \(why) The builder started fresh; the line is unchanged.", isWarning: true)
        }
    }

    /// The picker's choice: a fresh form for `spec` (the key of the form it replaces carries
    /// over), or raw arguments for a command without a spec.
    func chooseRedisBuilderCommand(_ tab: TabModel, spec: RedisCommandSpec?, rawName: String = "") {
        let state = redisBuilder(for: tab)
        let previousKey = state.form.flatMap(Self.firstKey)
        if let spec {
            var form = RedisCommandForm(spec: spec)
            if let previousKey, let index = spec.arguments.firstIndex(where: { $0.kind == .key }) {
                form.values[index].rows[0].value = previousKey
            }
            state.form = form
        } else {
            state.form = RedisCommandForm(rawName: rawName.uppercased())
        }
        state.showsPicker = false
        state.search = ""
        state.note = nil
    }

    private static func firstKey(_ form: RedisCommandForm) -> String? {
        guard let spec = form.spec, let index = spec.arguments.firstIndex(where: { $0.kind == .key }), index < form.values.count else { return nil }
        return form.values[index].rows.first?.value.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Insert (on a new line after the caret's) or Replace Line: the form's command as one
    /// undoable edit. Nothing runs.
    func writeRedisBuilder(_ tab: TabModel, replace: Bool) {
        let state = redisBuilder(for: tab)
        guard tab.language == .redis, let form = state.form, form.canWrite else { return }
        let editor = tab.editor
        let line = form.line
        let caret = editor.selectedRange.location
        let edit = replace ? RedisBuilderText.replace(line, in: editor.text, at: caret) : RedisBuilderText.insert(line, in: editor.text, at: caret)
        guard let edit else {
            state.note = .init(text: "The caret's line is a comment: put the caret on a command line to replace it, or use Insert.", isWarning: true)
            return
        }
        editor.apply(edit, actionName: replace ? "Replace Redis Command" : "Insert Redis Command")
        let number = RedisBuilderText.caretLine(in: editor.text, at: edit.caret).number
        state.note = .init(text: (replace ? "Replaced line \(number)" : "Inserted on line \(number)") + ". Nothing ran: ⌘R runs it.")
    }

    /// Whether Replace Line has a line to replace: the caret's line isn't a comment.
    func redisBuilderCanReplace(_ tab: TabModel) -> Bool {
        let editor = tab.editor
        return RedisBuilderText.replace("", in: editor.text, at: editor.selectedRange.location) != nil
    }

    /// Key names for completion: the key browser's last scan of this tab's connection. Typing
    /// never reads anything from the server.
    func redisBuilderKeys(for tab: TabModel) -> (keys: [String], db: Int?) {
        guard let key = redisPaneKey(for: tab), let browser = redisUI.browsers[key], !browser.keys.isEmpty else { return ([], nil) }
        return (browser.keys.compactMap(\.key), browser.db)
    }

    /// The key browser's Insert Command item: the builder, prefilled.
    func openRedisBuilder(_ tab: TabModel, key entry: RedisKeyEntry, command: RedisKeyCommand) {
        openRedisBuilder(tab, form: command.form, note: "From the key browser: \(entry.displayName). Insert writes it into the tab; nothing runs.")
    }
}

extension EditorController {
    /// The builder's edit (#218) as one undoable edit named `actionName`; the caret goes after
    /// the command, which scrolls into view.
    func apply(_ edit: RedisBuilderText.Edit, actionName: String) {
        textView.breakUndoCoalescing()
        textView.undoManager?.beginUndoGrouping()
        textView.replace(range: edit.range, with: edit.replacement, selectAfter: NSRange(location: edit.caret, length: 0))
        textView.undoManager?.setActionName(actionName)
        textView.undoManager?.endUndoGrouping()
        textView.breakUndoCoalescing()
        // The command's line from its start: a long line in a narrow editor would otherwise
        // scroll the text sideways to its end.
        let lineStart = (text as NSString).lineRange(for: NSRange(location: min(edit.caret, (text as NSString).length), length: 0)).location
        textView.scrollRangeToVisible(NSRange(location: lineStart, length: 0))
    }
}
