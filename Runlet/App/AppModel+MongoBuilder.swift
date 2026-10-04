import AppKit
import Observation
import RunletCore

/// A MongoDB tab's query builder (#217), in memory while Runlet runs. The tab's text stays the
/// source of truth: the builder reads the selected query (or the one at the caret) into its
/// model, and every change in it rewrites that query as pretty-printed JSON, one undoable edit
/// once the builder has been still for a moment. Reading never changes the text. It never runs
/// anything.
@MainActor
@Observable
final class MongoBuilderState {
    /// What the builder last read or wrote, under its header (shared with Redis's, #218).
    typealias Note = BuilderNote

    enum Phase: Equatable {
        /// No query at the caret (a blank tab): Start from Collection.
        case fresh
        /// The model of the tab's query.
        case ready
        /// The query at the caret isn't one JSON object: why. The text stays as it is.
        case unreadable(String)
    }

    var isOpen = false
    var phase: Phase = .fresh
    /// The model; a change made in the panel is written into the tab (see `AppModel.mongoBuilderEdited`).
    var builder: MongoQueryBuilder? {
        didSet { if builder != oldValue { onEdit?() } }
    }
    var note: Note?
    /// The panel's width while dragging its edge; the saved one otherwise.
    var width: Double = 380
    /// The query's first and last line, for the footer ("lines 3–12").
    var lines: ClosedRange<Int>?
    /// A change is waiting to be written.
    var isWriting: Bool { schedule.isPending }

    @ObservationIgnored var onEdit: (() -> Void)?
    /// The tab's text after the builder's last read or write: another text means the user edited it.
    @ObservationIgnored var syncedText: String?
    /// The query's range in `syncedText`, and its text there; nil while the builder's query isn't
    /// in the tab yet (its first write inserts it).
    @ObservationIgnored var queryRange: NSRange?
    @ObservationIgnored var queryText: String?
    /// The builder's own text for the model as last read or written: a change that writes the same
    /// text (an incomplete rule) changes nothing in the tab.
    @ObservationIgnored var builderText: String?
    /// The query the builder couldn't read: Start from Collection inserts after it.
    @ObservationIgnored var unreadableRange: NSRange?
    @ObservationIgnored var schedule = MongoBuilderSchedule(delay: 0.4)
    @ObservationIgnored var writeTask: Task<Void, Never>?
    @ObservationIgnored var readTask: Task<Void, Never>?
    #if DEBUG
    /// Writes and reads, for DEBUG steps.
    @ObservationIgnored var writes = 0
    #endif
}

/// Each MongoDB tab's builder (#217).
@MainActor
final class MongoBuilderStore {
    private var states: [UUID: MongoBuilderState] = [:]
    static let shared = MongoBuilderStore()

    func state(for tabId: UUID) -> MongoBuilderState {
        if let state = states[tabId] { return state }
        let state = MongoBuilderState()
        states[tabId] = state
        return state
    }
}

extension AppModel {
    func mongoBuilder(for tab: TabModel) -> MongoBuilderState {
        let state = MongoBuilderStore.shared.state(for: tab.id)
        if state.onEdit == nil {
            state.onEdit = { [weak self, weak tab] in
                guard let self, let tab else { return }
                self.mongoBuilderEdited(tab)
            }
        }
        return state
    }

    /// Show Builder (⌥⌘B, the MongoDB bar's Builder button): opens the builder on the selected
    /// query or the one at the caret, or closes it (writing a waiting change first).
    func toggleMongoBuilder(_ tab: TabModel) {
        guard tab.language == .mongodb else { return }
        let state = mongoBuilder(for: tab)
        if state.isOpen {
            flushMongoBuilder(tab)
            state.isOpen = false
            tab.editor.focus()
        } else {
            state.isOpen = true
            readMongoBuilder(tab)
        }
    }

    // MARK: Text → builder

    /// Reads the selected query, or the one at the caret, into the builder. The text is never
    /// changed by reading: a query the builder can't read leaves a note and Start from Collection.
    func readMongoBuilder(_ tab: TabModel) {
        let state = mongoBuilder(for: tab)
        if state.schedule.isPending { flushMongoBuilder(tab) }
        state.readTask?.cancel()
        state.readTask = nil
        let editor = tab.editor
        let text = editor.text
        state.syncedText = text
        func set(_ builder: MongoQueryBuilder?, phase: MongoBuilderState.Phase, range: NSRange?, note: MongoBuilderState.Note?) {
            state.builderText = builder?.text
            state.queryRange = range
            state.queryText = range.map { (text as NSString).substring(with: $0) }
            state.lines = range.map { MongoBuilderText.line(of: $0.location, in: text)...MongoBuilderText.line(of: NSMaxRange($0), in: text) }
            state.phase = phase
            state.note = note
            state.builder = builder
        }
        switch MongoBuilderText.target(in: text, selection: editor.selectedRange) {
        case .query(let range):
            let line = MongoBuilderText.line(of: range.location, in: text)
            switch MongoQueryBuilder.read((text as NSString).substring(with: range)) {
            case .success(let builder):
                let raw = Self.rawCount(builder)
                let kept = raw == 0 ? "" : " \(raw) part\(raw == 1 ? "" : "s") the builder has no form for \(raw == 1 ? "is" : "are") kept as JSON."
                set(builder, phase: .ready, range: range, note: .init(text: "Read the query on line \(line).\(kept)"))
            case .failure(let error):
                set(nil, phase: .unreadable("The query on line \(line) can't be read. \(error.localizedDescription)"), range: nil,
                    note: .init(text: "The query on line \(line) can't be read; the text is unchanged.", isWarning: true))
                state.queryRange = nil
                state.lines = nil
                state.unreadableRange = range
                return
            }
        case .unclosed(let range):
            let line = MongoBuilderText.line(of: range.location, in: text)
            set(nil, phase: .unreadable("The query on line \(line) isn't closed with “}”."), range: nil,
                note: .init(text: "The query on line \(line) can't be read; the text is unchanged.", isWarning: true))
            state.unreadableRange = range
            return
        case .none:
            set(nil, phase: .fresh, range: nil, note: nil)
        }
        state.unreadableRange = nil
    }

    /// How many raw blocks the builder keeps (filter members, stages, update parts, extras).
    static func rawCount(_ builder: MongoQueryBuilder) -> Int {
        func count(_ group: MongoFilterGroup) -> Int {
            group.children.reduce(0) { total, node in
                switch node {
                case .raw: total + 1
                case .group(let nested): total + count(nested)
                case .rule: total
                }
            }
        }
        var total = builder.extras.count + (builder.filter.map(count) ?? 0)
        for stage in builder.pipeline ?? [] {
            if case .raw = stage.body { total += 1 }
            if case .match(let group) = stage.body { total += count(group) }
        }
        total += builder.update?.filter { if case .raw = $0 { true } else { false } }.count ?? 0
        return total
    }

    /// The tab's text or caret changed (`TabModel.onChange`): an edit of the text, or the caret
    /// moving to another query, is read again shortly after. The builder's own writes are not.
    func mongoBuilderEditorChanged(_ tab: TabModel, selectionOnly: Bool) {
        let state = mongoBuilder(for: tab)
        guard state.isOpen, tab.language == .mongodb else { return }
        let text = tab.editor.text
        if selectionOnly {
            guard text == state.syncedText else { return }
            let target = MongoBuilderText.target(in: text, selection: tab.editor.selectedRange)
            switch target {
            case .query(let range) where range == state.queryRange: return
            case .none: return
            default: break
            }
        } else if text == state.syncedText {
            return
        }
        state.readTask?.cancel()
        state.readTask = Task { @MainActor [weak self, weak tab] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, let tab else { return }
            self.mongoBuilder(for: tab).readTask = nil
            self.readMongoBuilder(tab)
        }
    }

    // MARK: Builder → text

    /// A change in the panel: written once the builder has been still for a moment (one Undo
    /// step for typing a value). A value that isn't valid yet is not written; the note says why.
    func mongoBuilderEdited(_ tab: TabModel) {
        let state = mongoBuilder(for: tab)
        guard state.isOpen, let builder = state.builder else { return }
        guard let text = builder.text else {
            state.note = .init(text: "Not written yet: \(builder.problem ?? "a value isn't valid").", isWarning: true)
            return
        }
        guard text != state.builderText else { return }
        state.schedule.change(at: Date())
        guard state.writeTask == nil else { return }
        state.writeTask = Task { @MainActor [weak self, weak tab, weak state] in
            while let state, let due = state.schedule.due {
                let wait = due.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait * 1000) + 5)) }
                guard let self, let tab else { return }
                if state.schedule.isDue(at: Date()) { self.flushMongoBuilder(tab) }
            }
            state?.writeTask = nil
        }
    }

    /// Writes the builder's query now: rewrites the query it read or last wrote, or inserts it
    /// as a new query (a blank tab, Start from Collection). One undoable edit; nothing runs. If
    /// the tab's text changed underneath, it reads the text again instead.
    func flushMongoBuilder(_ tab: TabModel) {
        let state = mongoBuilder(for: tab)
        state.schedule.clear()
        guard let builder = state.builder, let query = builder.text, query != state.builderText else { return }
        let editor = tab.editor
        let text = editor.text
        guard text == state.syncedText else {
            readMongoBuilder(tab)
            state.note = .init(text: "The tab's text changed, so the builder read it again; its last change wasn't written.", isWarning: true)
            return
        }
        let edit: MongoBuilderText.Edit
        if let range = state.queryRange, NSMaxRange(range) <= (text as NSString).length,
           (text as NSString).substring(with: range) == state.queryText {
            edit = MongoBuilderText.rewrite(range, with: query, in: text, selection: editor.selectedRange)
        } else {
            edit = MongoBuilderText.insert(query, in: text, after: state.unreadableRange)
        }
        editor.apply(edit, actionName: "Query Builder")
        let written = editor.text
        state.syncedText = written
        state.queryRange = edit.query
        state.queryText = query
        state.builderText = query
        state.unreadableRange = nil
        state.phase = .ready
        let lines = MongoBuilderText.line(of: edit.query.location, in: written)...MongoBuilderText.line(of: NSMaxRange(edit.query), in: written)
        state.lines = lines
        state.note = .init(text: "Wrote the query on line\(lines.count == 1 ? "" : "s") \(lines.lowerBound)\(lines.count == 1 ? "" : "–\(lines.upperBound)"). Nothing ran: ⌘R runs it.")
        #if DEBUG
        state.writes += 1
        #endif
    }

    /// Start from Collection: a find of `collection`, inserted as a new query (after a query the
    /// builder couldn't read, which stays as it is).
    func startMongoBuilder(_ tab: TabModel, collection: String) {
        let state = mongoBuilder(for: tab)
        guard !collection.isEmpty else { return }
        state.isOpen = true
        if state.syncedText != tab.editor.text { readMongoBuilder(tab) }
        state.queryRange = nil
        state.builderText = nil
        state.phase = .ready
        state.builder = .start(collection: collection)
        flushMongoBuilder(tab)
    }

    /// Insert as New Query: the builder's query as a new query after this one, which the builder
    /// then follows. The query it was on keeps what was last written.
    func insertMongoBuilderQuery(_ tab: TabModel) {
        let state = mongoBuilder(for: tab)
        flushMongoBuilder(tab)
        guard let builder = state.builder, let query = builder.text else { return }
        let editor = tab.editor
        let edit = MongoBuilderText.insert(query, in: editor.text, after: state.queryRange)
        editor.apply(edit, actionName: "Insert Query")
        let written = editor.text
        state.syncedText = written
        state.queryRange = edit.query
        state.queryText = query
        state.builderText = query
        let line = MongoBuilderText.line(of: edit.query.location, in: written)
        state.lines = line...MongoBuilderText.line(of: NSMaxRange(edit.query), in: written)
        state.note = .init(text: "Inserted a copy on line \(line); the builder now edits it. Nothing ran.")
    }

    /// Selects the builder's query in the editor, so ⌘R runs it alone (a tab with several queries).
    func selectMongoBuilderQuery(_ tab: TabModel) {
        let state = mongoBuilder(for: tab)
        flushMongoBuilder(tab)
        guard let range = state.queryRange, tab.editor.text == state.syncedText else { return }
        tab.editor.textView.setSelectedRange(range)
        tab.editor.textView.scrollRangeToVisible(range)
        tab.editor.focus()
    }

    /// Whether the tab holds more than one query (⌘R runs the whole text without a selection).
    func mongoBuilderHasSeveralQueries(_ tab: TabModel) -> Bool {
        MongoBuilderText.blocks(in: tab.editor.text).count > 1
    }

    // MARK: Fields and collections (the explorer's cache; nothing is read here)

    /// The sampled fields of `collection` (Sample Fields), with their types; empty when not sampled.
    func mongoBuilderFields(_ tab: TabModel, collection: String?) -> [MongoSampledField] {
        guard let collection, !collection.isEmpty, let result = MongoUI.shared.fields[mongoCacheKey(tab)]?[collection] else { return [] }
        return result.rows.compactMap { row in
            guard let name = row.first?.text, !name.isEmpty else { return nil }
            return MongoSampledField(name: name, types: row.count > 1 ? row[1].text : "")
        }
    }

    /// The collections Load Collections read for the tab's connection.
    func mongoBuilderCollections(_ tab: TabModel) -> [String] {
        (MongoUI.shared.collections[mongoCacheKey(tab)]?.rows.compactMap { $0.first?.text } ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: Filter by this value (a result cell)

    /// Adds a rule `field = value` to the builder's filter (or its first `$match`), opening the
    /// builder on the tab's query first. `value` is the cell's canonical Extended JSON.
    func mongoBuilderFilter(_ tab: TabModel, field: String, value: MongoJSON) {
        let state = mongoBuilder(for: tab)
        if !state.isOpen { toggleMongoBuilder(tab) }
        guard var builder = state.builder else {
            state.note = .init(text: "Open the builder on a query to filter by a value.", isWarning: true)
            return
        }
        let rule = MongoFilterRule(path: field, value: MongoValue(canonical: value))
        if builder.operation == "aggregate" {
            var pipeline = builder.pipeline ?? []
            if let index = pipeline.firstIndex(where: { $0.kind == .match }), case .match(var group) = pipeline[index].body {
                group.setRule(rule)
                pipeline[index].body = .match(group)
            } else {
                pipeline.insert(MongoStage(.match(MongoFilterGroup(children: [.rule(rule)]))), at: 0)
            }
            builder.pipeline = pipeline
        } else if builder.allowedFields.contains("filter") {
            var filter = builder.filter ?? MongoFilterGroup()
            filter.setRule(rule)
            builder.filter = filter
        } else {
            state.note = .init(text: "\(builder.operation ?? "This operation") takes no filter.", isWarning: true)
            return
        }
        state.builder = builder
    }
}

/// A field Sample Fields read, with the BSON types seen.
struct MongoSampledField: Hashable {
    var name: String
    var types: String
    /// "ObjectId", "UTCDateTime, null"…
    var displayTypes: String {
        types.split(separator: ",").map { part in
            let type = part.trimmingCharacters(in: .whitespaces)
            return type == "stdClass" ? "object" : type == "NULL" ? "null" : type.components(separatedBy: "\\").last ?? type
        }.joined(separator: ", ")
    }
}

extension EditorController {
    /// The query builder's edit (#217) as one undoable edit named `actionName`; the changed
    /// part scrolls into view.
    func apply(_ edit: MongoBuilderText.Edit, actionName: String) {
        textView.breakUndoCoalescing()
        textView.undoManager?.beginUndoGrouping()
        textView.replace(range: edit.range, with: edit.replacement, selectAfter: edit.selection)
        textView.undoManager?.setActionName(actionName)
        textView.undoManager?.endUndoGrouping()
        textView.breakUndoCoalescing()
        textView.scrollRangeToVisible(NSRange(location: edit.range.location, length: (edit.replacement as NSString).length))
    }
}
