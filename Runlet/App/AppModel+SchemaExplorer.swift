import AppKit
import Observation
import RunletCore

/// The schema explorer's state (#21): the filter and which tables are open, kept while Runlet
/// runs so switching panes or tabs doesn't reset them.
@MainActor
@Observable
final class SchemaExplorerState {
    var search = ""
    /// Expanded tables, by `SQLSchemaStore.key` + table name.
    var expanded: Set<String> = []
    /// Show Definition's sheet (#148), while it is open; never saved. What the last read did,
    /// for DEBUG steps.
    var definitionSheet: SchemaDefinitionSheet?
    var lastDefinition: String?
    #if DEBUG
    /// DEBUG step `schema-menu:<table>`: the row whose context menu items show in a popover.
    var debugMenuTable: String?
    #endif

    private static var states: [ObjectIdentifier: SchemaExplorerState] = [:]

    static func shared(for model: AppModel) -> SchemaExplorerState {
        let key = ObjectIdentifier(model)
        if let existing = states[key] { return existing }
        let created = SchemaExplorerState()
        states[key] = created
        return created
    }
}

/// Show Definition's sheet (#148): one table's or view's definition, read when the sheet opens,
/// shown read-only with Copy and Open in SQL Tab. It lives only while it is open: it is never
/// saved with the session, and nothing in it runs.
@MainActor
@Observable
final class SchemaDefinitionSheet: Identifiable {
    enum State {
        case loading
        /// The definition and the text Copy and Open in SQL Tab use: its header and the DDL.
        case loaded(SQLDefinitionInfo, text: String)
        case failed(String)
    }

    let id = UUID()
    /// The window it shows on (nil: any).
    let windowId: UUID?
    let table: String
    let isView: Bool
    let target: TargetRef
    let connection: SQLConnectionChoice
    /// Where the connection opens: the target's name, or "this Mac (…)" (#142).
    let openedFrom: String
    /// The explorer schema's PDO driver, until the definition names its server.
    let driver: String?
    var state: State = .loading
    var task: Task<Void, Never>?

    init(windowId: UUID?, table: String, isView: Bool, target: TargetRef, connection: SQLConnectionChoice, openedFrom: String, driver: String?) {
        self.windowId = windowId
        self.table = table
        self.isView = isView
        self.target = target
        self.connection = connection
        self.openedFrom = openedFrom
        self.driver = driver
    }

    /// "orders · table"
    var title: String {
        if case .loaded(let info, _) = state, let kind = info.kind { return "\(table) · \(kind)" }
        return "\(table) · \(isView ? "view" : "table")"
    }

    /// "The saved connection “Shop” on acme · SQLite 3.45.2", or "… on this Mac (Runlet's PHP 8.5.8) · …"
    var subtitle: String {
        var database = SQLDefinition.databaseName(driver)
        if case .loaded(let info, _) = state { database = info.server ?? SQLDefinition.databaseName(info.driver ?? driver) }
        let label = connection.label
        return label.prefix(1).uppercased() + label.dropFirst() + " on \(openedFrom) · \(database)"
    }

    /// The header and DDL, once read.
    var text: String? {
        if case .loaded(_, let text) = state { return text }
        return nil
    }
}

/// The schema explorer (#21): the Library's Database pane shows the tables and columns of the
/// current tab's target and connection (an SQL tab's own, else the default), from the schema
/// completion shares (`SQLSchemaStore`). Its actions open or insert text; none of them runs it.
/// Show Definition (#148) reads one table's DDL from the catalog into a sheet, as Load Schema reads names.
extension AppModel {
    var schemaExplorer: SchemaExplorerState { SchemaExplorerState.shared(for: self) }

    /// The connection the explorer shows for a tab: an SQL tab's (an application connection or
    /// a saved one, #138), else the application's default.
    func explorerConnection(for tab: TabModel) -> SQLConnectionChoice {
        tab.language == .sql ? sqlConnectionChoice(for: tab) : .app(nil)
    }

    /// Open as PHP is offered for the application's connections only: Runlet never generates
    /// PHP that holds a saved connection's password (#138).
    func offersQueryBuilder(for tab: TabModel) -> Bool {
        explorerConnection(for: tab).savedConnection == nil && SQLSchemaExplorer.hasQueryBuilder(framework: framework(for: tab))
    }

    /// The framework the tab's target last reported (for Open as PHP).
    func framework(for tab: TabModel) -> String? {
        tab.lastRun?.framework ?? targetFacts[tab.target.stableKey]?.framework
    }

    /// Open in SQL Tab: the table's first rows in a new SQL tab on the same target and
    /// connection. It doesn't run.
    func openSchemaTable(_ table: String, schema: SQLSchemaInfo, from tab: TabModel) {
        let query = SQLSchemaExplorer.selectQuery(table: table, driver: schema.driver)
        switch explorerConnection(for: tab) {
        case .saved(let connection):
            newTab(target: tab.target, code: query, title: table, language: .sql, sqlSavedConnection: connection.id, sqlSavedConnectionName: connection.name)
        case .missing(let name):
            newTab(target: tab.target, code: query, title: table, language: .sql, sqlSavedConnectionName: name)
        case .app(let name):
            newTab(target: tab.target, code: query, title: table, language: .sql, sqlConnection: name)
        }
        focusSelectedEditor()
    }

    /// Show Definition (#148): production asks first (as for Load Schema), then a sheet on the
    /// tab's window reads one table's or view's definition (DDL) from the catalog of the
    /// explorer's connection, in a fresh runner, and shows it read-only. Nothing runs; Open in
    /// SQL Tab (`openSchemaDefinitionInTab`) is the only way it becomes a tab.
    func showSchemaDefinition(_ table: SQLSchemaInfo.Table, schema: SQLSchemaInfo, from tab: TabModel) {
        let choice = explorerConnection(for: tab)
        if case .missing(let name) = choice {
            alert = AppAlert(title: "The saved connection isn't defined", message: SQLConnectionChoice.missingMessage(name))
            return
        }
        guard let ref = choice.ref, schemaExplorer.definitionSheet == nil else { return }
        let target = tab.target
        let saved = choice.savedConnection
        let kind = table.isView ? "view" : "table"
        let what = saved == nil
            ? "Show the definition of \(kind) \(table.name) from the catalog of \(choice.label) (boots the application, reads no rows, runs nothing)"
            : "Show the definition of \(kind) \(table.name) from the catalog of \(choice.label) (\(saved?.summary ?? "")) (opens the connection \(saved?.opensOnThisMac == true ? "from this Mac" : "without booting the application"), reads no rows, runs nothing)"
        guardProduction(.sqlDefinition, target: target, text: what, sqlConnection: saved.map { "the saved connection “\($0.name)” (\($0.summary))" + ($0.opensOnThisMac ? " from this Mac" : "") } ?? choice.label, sqlSaved: saved != nil, savedConnection: saved,
                        in: window(containing: tab.id)) { [weak self, weak tab] in
            guard let self, let tab, tab.target == target, self.schemaExplorer.definitionSheet == nil else { return }
            let openedFrom = saved.map { self.openedFromLabel($0, tabTarget: target) } ?? self.targetLabel(target)
            let sheet = SchemaDefinitionSheet(windowId: self.window(containing: tab.id)?.id, table: table.name, isView: table.isView, target: target,
                                              connection: choice, openedFrom: openedFrom, driver: schema.driver)
            self.schemaExplorer.definitionSheet = sheet
            let task = Task { [weak self, weak sheet] in
                guard let self else { return }
                let state: SchemaDefinitionSheet.State
                do {
                    // From this Mac for a saved connection that opens there (#142), else on the target.
                    let snapshot = try await self.sqlSnapshot(for: tab, saved: saved)
                    let info = try await self.engine.loadSQLDefinition(target: snapshot, table: table.name, connection: ref.appName, saved: saved)
                    state = .loaded(info, text: SQLDefinition.document(info, connection: choice.label, target: openedFrom, readAt: Date()))
                    self.schemaExplorer.lastDefinition = "\(info.table) \(info.kind ?? "?") via \(info.how ?? "?")\(info.reconstructed == true ? " (reconstructed)" : ""): \(info.sql.count) characters"
                } catch is CancellationError {
                    self.schemaExplorer.lastDefinition = "stopped"
                    return
                } catch {
                    state = .failed("\(error)")
                    self.schemaExplorer.lastDefinition = "failed: \(error)"
                }
                sheet?.state = state
                sheet?.task = nil
            }
            sheet.task = task
            // #180: listed in the Connection Manager while it reads; Close is the sheet's Done.
            self.trackDatabaseWork(DatabaseWork(purpose: .definition(table.name), tabId: tab.id, tabTitle: tab.title, target: target, connection: choice) { [weak self] in
                self?.closeSchemaDefinition()
            }, until: task)
        }
    }

    /// Done or Esc: closes the sheet and stops a read still under way.
    func closeSchemaDefinition() {
        schemaExplorer.definitionSheet?.task?.cancel()
        schemaExplorer.definitionSheet = nil
    }

    /// Copy: the whole definition, header included.
    func copySchemaDefinition() {
        if let text = schemaExplorer.definitionSheet?.text { Pasteboard.copy(text) }
    }

    /// Open in SQL Tab: the definition in a new SQL tab on the same target and connection, in
    /// the sheet's window, with the editor alone (the output pane comes back with a run or Show
    /// Output Pane, #60's per-tab dismissal). It doesn't run. Closes the sheet.
    func openSchemaDefinitionInTab() {
        guard let sheet = schemaExplorer.definitionSheet, let text = sheet.text else { return }
        closeSchemaDefinition()
        let window = sheet.windowId.flatMap { id in windows.first { $0.id == id } }
        let title = SQLDefinition.tabTitle(sheet.table)
        let opened = switch sheet.connection {
        case .saved(let saved):
            newTab(target: sheet.target, code: text, title: title, in: window, language: .sql, sqlSavedConnection: saved.id, sqlSavedConnectionName: saved.name)
        case .missing(let name):
            newTab(target: sheet.target, code: text, title: title, in: window, language: .sql, sqlSavedConnectionName: name)
        case .app(let name):
            newTab(target: sheet.target, code: text, title: title, in: window, language: .sql, sqlConnection: name)
        }
        opened.outputPaneRevealed = false
        opened.outputPaneDismissed = true
        focusSelectedEditor()
    }

    /// Open as PHP (Laravel): the query builder for the table in a new PHP tab. It doesn't run.
    func openSchemaTableAsPHP(_ table: String, from tab: TabModel) {
        guard case .app(let name) = explorerConnection(for: tab) else { return }
        newTab(target: tab.target, code: SQLSchemaExplorer.laravelQuery(table: table, connection: name), title: table, language: .php)
        focusSelectedEditor()
    }

    /// Inserts a name at the current tab's cursor (quoted for SQL tabs when it must be).
    func insertSchemaName(_ name: String, schema: SQLSchemaInfo) {
        guard let tab = selectedTab else { return }
        tab.editor.insert(tab.language == .sql ? SQLSchemaExplorer.quoted(name, driver: schema.driver) : name)
        focusSelectedEditor()
    }
}
