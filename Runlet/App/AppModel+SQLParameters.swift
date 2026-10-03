import Foundation
import Observation
import RunletCore

/// A statement (or Run All script) with placeholders waiting for its values (#145):
/// `SQLParameterSheet` shows it on its window. Run hands the values to `run`; Cancel or
/// Escape runs nothing.
@MainActor
@Observable
final class SQLParameterRequest: Identifiable {
    let id = UUID()
    /// The window the sheet belongs to: the tab's.
    let windowId: UUID?
    let tabId: UUID
    let title: String
    /// Where it runs and which lines, e.g. "Line 3 · the default connection".
    let subtitle: String
    /// The statement, shortened, or nil for Run All.
    let preview: String?
    /// `-- @param` lines that couldn't be read; those placeholders start empty.
    let problems: [String]
    /// The confirm button's title: "Run" or "Run All".
    let actionTitle: String
    /// Positional `?`s in several statements: rows name their statement.
    let namesStatements: Bool
    var form: SQLParameterForm
    @ObservationIgnored let scan: SQLParameterScan
    @ObservationIgnored let statements: [SQLScript.Statement]
    @ObservationIgnored let run: @MainActor ([SQLParameter.Key: SQLParameterValue]) -> Void

    init(windowId: UUID?, tabId: UUID, title: String, subtitle: String, preview: String?, problems: [String], actionTitle: String, scan: SQLParameterScan, statements: [SQLScript.Statement], form: SQLParameterForm, run: @escaping @MainActor ([SQLParameter.Key: SQLParameterValue]) -> Void) {
        self.windowId = windowId
        self.tabId = tabId
        self.title = title
        self.subtitle = subtitle
        self.preview = preview
        self.problems = problems
        self.actionTitle = actionTitle
        self.namesStatements = scan.positionalSpansStatements
        self.scan = scan
        self.statements = statements
        self.form = form
        self.run = run
    }

    /// "statement 2 · line 7" or "line 7".
    func caption(for parameter: SQLParameter) -> String {
        if namesStatements, let statement = parameter.statement { return "statement \(statement + 1) · line \(parameter.line)" }
        let uses = parameter.uses > 1 ? " · used \(parameter.uses) times" : ""
        return "line \(parameter.line)\(uses)"
    }
}

/// The values sheet on screen, and each tab's last values (#145). In memory only: values are
/// never saved with the tab, the session, or a workspace.
@MainActor
@Observable
final class SQLParameterStore {
    var request: SQLParameterRequest?
    @ObservationIgnored var memory: [UUID: SQLParameterMemory] = [:]

    private static var stores: [ObjectIdentifier: SQLParameterStore] = [:]

    static func shared(for model: AppModel) -> SQLParameterStore {
        let key = ObjectIdentifier(model)
        if let existing = stores[key] { return existing }
        let created = SQLParameterStore()
        stores[key] = created
        return created
    }
}

extension AppModel {
    var sqlParameters: SQLParameterStore { SQLParameterStore.shared(for: self) }

    /// How the database reads the run's text, when Runlet knows it: a saved connection's
    /// driver, else the driver the connection's schema or last result reported.
    func sqlDriver(for choice: SQLConnectionChoice, target: TargetRef) -> DatabaseDriverKind? {
        if let saved = choice.savedConnection { return saved.driver }
        guard let ref = choice.ref, let driver = sqlSchemaState(target: target, connection: ref)?.schema?.driver else { return nil }
        return DatabaseDriverKind(rawValue: driver)
    }

    /// Calls `run` at once without placeholders; otherwise shows the values sheet, prefilled
    /// with the tab's last values or the text's `-- @param` presets, and calls `run` with the
    /// values only when the user presses Run.
    func askForSQLParameters(_ scan: SQLParameterScan, statements: [SQLScript.Statement], in tab: TabModel, text: String, title: String, subtitle: String, preview: String?, actionTitle: String,
                             run: @escaping @MainActor ([SQLParameter.Key: SQLParameterValue]) -> Void) {
        guard !scan.isEmpty else { return run([:]) }
        let presets = SQLParameters.presets(in: text, statements: statements)
        let memory = sqlParameters.memory[tab.id] ?? SQLParameterMemory()
        let form = SQLParameterForm(scan: scan, presets: presets.values) { memory.value(for: $0, statements: statements) }
        sqlParameters.request = SQLParameterRequest(windowId: window(containing: tab.id)?.id, tabId: tab.id, title: title, subtitle: subtitle, preview: preview, problems: presets.problems,
                                                    actionTitle: actionTitle, scan: scan, statements: statements, form: form, run: run)
    }

    /// The sheet's Run (↩): remembers the values for the tab, then runs.
    func confirmSQLParameters(_ request: SQLParameterRequest) {
        guard sqlParameters.request === request, let values = request.form.values else { return }
        sqlParameters.request = nil
        sqlParameters.memory[request.tabId, default: SQLParameterMemory()].remember(values, scan: request.scan, statements: request.statements)
        request.run(values)
    }

    /// Cancel, Escape, or closing the sheet: nothing runs.
    func cancelSQLParameters(_ request: SQLParameterRequest) {
        guard sqlParameters.request === request else { return }
        sqlParameters.request = nil
    }
}

extension SQLParameterScan {
    /// The values as the output, the production confirmation, and history show them, in
    /// the sheet's order.
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
