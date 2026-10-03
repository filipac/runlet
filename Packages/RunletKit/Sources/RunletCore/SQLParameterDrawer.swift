import Foundation

/// The parameters drawer under an SQL tab's editor (#168): the placeholders of what the next
/// run sends, each with its value, set before running.
///
/// `update` follows the tab: with the scope `.statement`, the statement Run would send (the
/// selection, or the statement at the caret, `SQLScript.statementToRun`); with `.all`, every
/// statement Run All would send. Rows come from the tab's memory first (what was set in the
/// drawer), then `-- @param` comments, else they are not set. Values set for placeholders that
/// disappear stay in the memory, and come back with them. While you edit a statement, its `?`
/// values follow their positions and a renamed `:name` keeps its value. Nothing here runs SQL.
public struct SQLParameterDrawerModel: Sendable, Equatable {
    /// Which run the drawer shows values for.
    public enum Scope: String, Sendable, Hashable, CaseIterable {
        /// Run (and Run Selection): the selection, or the statement at the caret.
        case statement
        /// Run All Statements: every statement of the selection, or of the tab.
        case all
    }

    /// What the drawer shows.
    public struct Content: Sendable, Equatable {
        public var rows: [SQLParameterRow] = []
        /// A placeholder PDO can't bind; Run refuses it.
        public var problem: SQLParameterProblem?
        /// `-- @param` lines that couldn't be read.
        public var presetProblems: [String] = []
        /// Statements in the tab: the scope switch is offered from two on.
        public var statementCount = 0
        /// `?`s of several statements are listed (Run All), so rows name their statement.
        public var namesStatements = false

        public init() {}

        /// Nothing to show: the drawer hides.
        public var isEmpty: Bool { rows.isEmpty && problem == nil }

        /// The first row that keeps the run from running (not set, or not valid).
        public var firstIssue: SQLParameterRow? { rows.first { $0.issue != nil } }

        /// "2 parameters: :min_rent = 1000, :skip = 'Linus'" (a collapsed drawer's line).
        public var summary: String {
            guard !rows.isEmpty else { return problem.map { "Can't bind: \($0.description)" } ?? "No parameters" }
            let items = rows.map { row -> String in
                let label = row.label(namesStatements: namesStatements)
                if let value = row.value { return "\(label) = \(value.display(limit: 40))" }
                return row.isSet ? "\(label) not valid" : "\(label) not set"
            }
            return "\(rows.count == 1 ? "1 parameter" : "\(rows.count) parameters"): \(items.joined(separator: ", "))"
        }
    }

    public var scope: Scope = .statement
    public private(set) var content = Content()
    public private(set) var memory = SQLParameterMemory()
    /// What the last update read, so an unchanged tab costs nothing.
    private var input: Input?
    /// What the last update read of the tab's statements, by their place in the tab, for
    /// carrying values over while one is edited: every statement's text, and the rows' own.
    private var seenTexts: [String] = []
    private var seen: [Int: Seen] = [:]

    private struct Input: Sendable, Equatable {
        var text: String
        var selection: NSRange
        var driver: DatabaseDriverKind?
        var scope: Scope
    }

    private struct Seen: Sendable, Equatable {
        /// The statement's text, trimmed (as positional memory keys use it).
        var text: String
        /// Its `:name`s in order of first use; nil when the drawer didn't list it.
        var names: [String]?
    }

    public init() {}

    /// Reads the tab's text and selection (and how the connection's database reads SQL,
    /// when known). Returns whether `content` changed.
    @discardableResult
    public mutating func update(text: String, selection: NSRange, driver: DatabaseDriverKind?) -> Bool {
        let input = Input(text: text, selection: selection, driver: driver, scope: scope)
        guard input != self.input else { return false }
        let edited = self.input.map { $0.text != text } ?? false
        self.input = input
        let all = SQLScript.statements(in: text)
        let statements: [SQLScript.Statement] = switch scope {
        case .statement: (try? SQLScript.statementToRun(in: text, selection: selection).get()).map { [$0] } ?? []
        case .all: (try? SQLScript.statementsToRunAll(in: text, selection: selection).get()) ?? []
        }
        let scan = SQLParameters.scan(statements, driver: driver)
        // A statement's place in the tab: the tab's statement it starts in.
        let places = statements.map { statement in
            all.firstIndex { NSLocationInRange(statement.range.location, $0.range) }
        }
        if edited, all.count == seenTexts.count { carryOver(scan: scan, statements: statements, places: places) }
        seenTexts = all.map { Self.trimmed($0.text) }
        seen = [:]
        for (index, statement) in statements.enumerated() {
            guard let place = places[index] else { continue }
            seen[place] = Seen(text: Self.trimmed(statement.text), names: Self.names(scan, index))
        }
        let presets = SQLParameters.presets(in: text, statements: statements)
        var content = Content()
        content.rows = SQLParameterRows.make(scan, statements: statements, presets: presets.values, memory: memory)
        content.problem = scan.problem
        content.presetProblems = scan.isEmpty ? [] : presets.problems
        content.statementCount = all.count
        content.namesStatements = scan.positionalSpansStatements
        guard content != self.content else { return false }
        self.content = content
        return true
    }

    /// Reads the tab again even when nothing changed (after the memory or the scope changed).
    private mutating func refresh() {
        guard let input else { return }
        // Without a previous input this isn't an edit, so nothing is carried over.
        self.input = nil
        update(text: input.text, selection: input.selection, driver: input.driver)
    }

    /// Shows the values for `scope`.
    public mutating func setScope(_ scope: Scope) {
        guard scope != self.scope else { return }
        self.scope = scope
        refresh()
    }

    /// Sets a row's value as the drawer's field does, and remembers it for the tab.
    public mutating func set(_ id: SQLParameter.Key, draft: SQLParameterDraft) {
        guard let key = content.rows.first(where: { $0.id == id })?.memoryKey else { return }
        memory.set(draft, for: key)
        // Every row remembered under the key (the same statement twice in Run All) follows.
        for index in content.rows.indices where content.rows[index].memoryKey == key {
            content.rows[index].draft = draft
            content.rows[index].source = .typed
            content.rows[index].isSet = true
        }
    }

    /// Sets a row by placeholder (`:name`, `?N`, or `?N@S`): `type` when given, then the text
    /// (a boolean reads true or false). False when no row matches or the text doesn't fit.
    @discardableResult
    public mutating func set(_ placeholder: String, type: SQLParameterType? = nil, text: String? = nil) -> Bool {
        guard let row = content.rows.first(where: { SQLParameterRows.matches($0.parameter, placeholder) }) else { return false }
        var draft = row.draft
        guard draft.set(type: type, text: text) else { return false }
        set(row.id, draft: draft)
        return true
    }

    /// The rows of a run about to start: `scan` of `statements` (from `text`), with this tab's
    /// memory and `text`'s `-- @param` presets. Update the drawer first, so an edit made just
    /// before the run has carried its values over.
    public func rows(for scan: SQLParameterScan, statements: [SQLScript.Statement], text: String) -> [SQLParameterRow] {
        SQLParameterRows.make(scan, statements: statements, presets: SQLParameters.presets(in: text, statements: statements).values, memory: memory)
    }

    // MARK: Carrying values over

    /// The statements of this update that are the last update's statements edited (the same
    /// place in a tab with as many statements, other text): their `?` values follow their
    /// positions, and a `:name` renamed in place keeps its value (the old name keeps it too).
    private mutating func carryOver(scan: SQLParameterScan, statements: [SQLScript.Statement], places: [Int?]) {
        for (index, statement) in statements.enumerated() {
            guard let place = places[index] else { continue }
            // The statement as the drawer listed it (perhaps a selection), else as the tab had it.
            let before = seen[place] ?? Seen(text: seenTexts[place], names: nil)
            let text = Self.trimmed(statement.text)
            guard text != before.text else { continue }
            var moved: [String] = []
            for parameter in scan.parameters where parameter.statement == index {
                guard case .positional(_, let position) = parameter.key else { continue }
                let key = SQLParameterMemory.positionalKey(position, statement: text)
                let old = SQLParameterMemory.positionalKey(position, statement: before.text)
                guard memory.draft(for: key) == nil, let draft = memory.draft(for: old) else { continue }
                memory.set(draft, for: key)
                moved.append(old)
            }
            for old in moved { memory.set(nil, for: old) }
            let names = Self.names(scan, index)
            guard let previous = before.names, names.count == previous.count else { continue }
            let renamed = zip(previous, names).filter { $0.0 != $0.1 }
            guard renamed.count == 1, let (old, new) = renamed.first, !names.contains(old), !previous.contains(new),
                  memory.draft(for: SQLParameterMemory.namedKey(new)) == nil, let draft = memory.draft(for: SQLParameterMemory.namedKey(old)) else { continue }
            memory.set(draft, for: SQLParameterMemory.namedKey(new))
        }
    }

    /// The `:name`s of statement `index` of `scan`, in order of first use.
    private static func names(_ scan: SQLParameterScan, _ index: Int) -> [String] {
        guard scan.statementKeys.indices.contains(index) else { return [] }
        return scan.statementKeys[index].compactMap { key in
            if case .named(let name) = key { return name }
            return nil
        }
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
