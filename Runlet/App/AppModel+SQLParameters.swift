import Foundation
import Observation
import RunletCore

/// An SQL tab's parameters drawer (#168): the placeholders of what the next run sends, with
/// the values set for them, under the editor. It reads the tab shortly after an edit or a
/// caret move (`AppModel.scheduleSQLParameterRefresh`). Values live in memory for the session
/// only: never in the tab, the session, or a workspace.
@MainActor
@Observable
final class SQLParameterDrawer {
    /// What the drawer shows. Replaced only when it changes, so typing in the editor redraws
    /// nothing while the placeholders stay the same.
    private(set) var content = SQLParameterDrawerModel.Content()
    /// The run the drawer shows values for: Run's statement, or every statement of Run All.
    private(set) var scope: SQLParameterDrawerModel.Scope = .statement
    /// Collapsed to its one-line summary.
    var collapsed = false
    /// Why the last Run didn't run (a value is missing or not valid), until every value is set.
    var note: String?
    /// The row a run asked to fill: the drawer focuses it.
    private(set) var focusRequest: FocusRequest?
    @ObservationIgnored private(set) var model = SQLParameterDrawerModel()
    /// The refresh waiting for the editor to settle.
    @ObservationIgnored var pending: Task<Void, Never>?

    struct FocusRequest: Equatable {
        let id = UUID()
        var key: SQLParameter.Key
    }

    func update(text: String, selection: NSRange, driver: DatabaseDriverKind?) {
        model.update(text: text, selection: selection, driver: driver)
        publish()
    }

    func setScope(_ scope: SQLParameterDrawerModel.Scope) {
        model.setScope(scope)
        publish()
    }

    /// A row's field changed.
    func set(_ id: SQLParameter.Key, draft: SQLParameterDraft) {
        model.set(id, draft: draft)
        publish()
    }

    /// Sets a row by placeholder (`:name`, `?N`, `?N@S`), as `SQLParameterDrawerModel.set`.
    @discardableResult
    func set(_ placeholder: String, type: SQLParameterType?, text: String?) -> Bool {
        defer { publish() }
        return model.set(placeholder, type: type, text: text)
    }

    func focus(_ key: SQLParameter.Key) {
        collapsed = false
        focusRequest = FocusRequest(key: key)
    }

    private func publish() {
        if content != model.content { content = model.content }
        if scope != model.scope { scope = model.scope }
        if note != nil, content.firstIssue == nil { note = nil }
    }
}

/// Each SQL tab's parameters drawer (#168).
@MainActor
final class SQLParameterStore {
    private var drawers: [UUID: SQLParameterDrawer] = [:]

    private static var stores: [ObjectIdentifier: SQLParameterStore] = [:]

    static func shared(for model: AppModel) -> SQLParameterStore {
        let key = ObjectIdentifier(model)
        if let existing = stores[key] { return existing }
        let created = SQLParameterStore()
        stores[key] = created
        return created
    }

    func drawer(for tabId: UUID) -> SQLParameterDrawer {
        if let drawer = drawers[tabId] { return drawer }
        let drawer = SQLParameterDrawer()
        drawers[tabId] = drawer
        return drawer
    }
}

extension AppModel {
    var sqlParameters: SQLParameterStore { SQLParameterStore.shared(for: self) }

    func sqlParameterDrawer(for tab: TabModel) -> SQLParameterDrawer {
        sqlParameters.drawer(for: tab.id)
    }

    /// How the database reads the run's text, when Runlet knows it: a saved connection's
    /// driver, else the driver the connection's schema or last result reported.
    func sqlDriver(for choice: SQLConnectionChoice, target: TargetRef) -> DatabaseDriverKind? {
        if let saved = choice.savedConnection { return saved.driver }
        guard let ref = choice.ref, let driver = sqlSchemaState(target: target, connection: ref)?.schema?.driver else { return nil }
        return DatabaseDriverKind(rawValue: driver)
    }

    /// After an edit or a caret move in an SQL tab: the drawer reads the tab once the editor
    /// has been still for a moment, so typing stays smooth.
    func scheduleSQLParameterRefresh(for tab: TabModel) {
        guard tab.language == .sql else { return }
        let drawer = sqlParameterDrawer(for: tab)
        drawer.pending?.cancel()
        drawer.pending = Task { [weak self, weak tab] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, let tab else { return }
            self.refreshSQLParameters(tab)
        }
    }

    /// The drawer reads the tab's text, selection, and connection's driver now.
    func refreshSQLParameters(_ tab: TabModel) {
        guard tab.language == .sql, let editor = tab.editorIfLoaded else { return }
        let drawer = sqlParameterDrawer(for: tab)
        drawer.pending?.cancel()
        drawer.pending = nil
        drawer.update(text: editor.text, selection: editor.selectedRange, driver: sqlDriver(for: sqlConnectionChoice(for: tab), target: tab.target))
    }

    /// Calls `run` with the parameters drawer's values for `scan` (at once without
    /// placeholders). When a value is missing or not valid, nothing runs: the drawer shows
    /// `scope` (Run's statement, or all statements), opens, and focuses that row with a note.
    func withSQLParameterValues(_ scan: SQLParameterScan, statements: [SQLScript.Statement], in tab: TabModel, text: String, scope: SQLParameterDrawerModel.Scope,
                                run: @MainActor ([SQLParameter.Key: SQLParameterValue]) -> Void) {
        guard !scan.isEmpty else { return run([:]) }
        let drawer = sqlParameterDrawer(for: tab)
        // An edit made just before the run carries its values over first.
        refreshSQLParameters(tab)
        let rows = drawer.model.rows(for: scan, statements: statements, text: text)
        if let values = SQLParameterRows.values(rows) {
            drawer.note = nil
            return run(values)
        }
        guard let row = rows.first(where: { $0.issue != nil }) else { return }
        drawer.setScope(scope)
        let label = row.label(namesStatements: scan.positionalSpansStatements)
        let action = scope == .all ? "Run All" : "Run"
        drawer.note = row.isSet ? "\(label): \(row.issue ?? "not valid") \(action) didn't run." : "Set a value for \(label) to \(action == "Run" ? "run" : "run all statements")."
        drawer.focus(row.id)
    }

    /// Return in a drawer field, or its Run button: Run, or Run All while the drawer shows
    /// all statements.
    func runFromSQLParameterDrawer(_ tab: TabModel) {
        if sqlParameterDrawer(for: tab).scope == .all {
            runAllSQL(tab)
        } else {
            runSQL(tab, selectionOnly: false)
        }
    }
}

extension SQLParameterScan {
    /// The values as the output, the production confirmation, and history show them, in
    /// the drawer's order.
    func lines(_ values: [SQLParameter.Key: SQLParameterValue]) -> [SQLParameterLine] {
        parameters.compactMap { parameter in
            values[parameter.key].map { SQLParameterLine(placeholder: parameter.placeholder, statement: positionalSpansStatements ? parameter.statement.map { $0 + 1 } : nil, value: $0) }
        }
    }
}

/// One bound value for display: `:status = 'paid'`, `?1 (statement 2) = 42`.
struct SQLParameterLine: Identifiable, Hashable {
    var placeholder: String
    /// 1-based, for `?` values of a Run All script with them in several statements.
    var statement: Int?
    var value: SQLParameterValue

    var id: String { placeholder + "@" + (statement.map(String.init) ?? "") }

    var label: String { statement.map { "\(placeholder) (statement \($0))" } ?? placeholder }

    /// `:status = 'paid'`
    func text(limit: Int = 120) -> String { "\(label) = \(value.display(limit: limit))" }
}
