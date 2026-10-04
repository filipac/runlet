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
    /// Show Definition (#148) reads in flight, by the same key, and what the last one did
    /// (for DEBUG steps).
    var definitionTasks: [String: Task<Void, Never>] = [:]
    var lastDefinition: String?

    private static var states: [ObjectIdentifier: SchemaExplorerState] = [:]

    static func shared(for model: AppModel) -> SchemaExplorerState {
        let key = ObjectIdentifier(model)
        if let existing = states[key] { return existing }
        let created = SchemaExplorerState()
        states[key] = created
        return created
    }
}

/// The schema explorer (#21): the Library's Database pane shows the tables and columns of the
/// current tab's target and connection (an SQL tab's own, else the default), from the schema
/// completion shares (`SQLSchemaStore`). Its actions open or insert text; none of them runs it.
/// Show Definition (#148) reads one table's DDL from the catalog first, as Load Schema reads names.
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

    /// Show Definition (#148): reads one table's or view's definition (DDL) from the catalog of
    /// the explorer's connection, in a fresh runner (production asks first, as for Load Schema),
    /// then opens it in a new SQL tab on the same target and connection, titled "orders
    /// (definition)". The tab doesn't run; its header says what was read, how, and when.
    func showSchemaDefinition(_ table: SQLSchemaInfo.Table, from tab: TabModel) {
        let choice = explorerConnection(for: tab)
        if case .missing(let name) = choice {
            alert = AppAlert(title: "The saved connection isn't defined", message: SQLConnectionChoice.missingMessage(name))
            return
        }
        guard let ref = choice.ref else { return }
        let target = tab.target
        let key = SQLSchemaStore.key(target, ref) + "\u{1F}" + table.name
        guard schemaExplorer.definitionTasks[key] == nil else { return }
        let saved = choice.savedConnection
        let kind = table.isView ? "view" : "table"
        let what = saved == nil
            ? "Show the definition of \(kind) \(table.name) from the catalog of \(choice.label) (boots the application, reads no rows, runs nothing)"
            : "Show the definition of \(kind) \(table.name) from the catalog of \(choice.label) (\(saved?.summary ?? "")) (opens the connection without booting the application, reads no rows, runs nothing)"
        guardProduction(.sqlDefinition, target: target, text: what, sqlConnection: saved.map { "the saved connection “\($0.name)” (\($0.summary))" } ?? choice.label, sqlSaved: saved != nil, savedConnection: saved,
                        in: window(containing: tab.id)) { [weak self, weak tab] in
            guard let self, let tab, tab.target == target else { return }
            let explorer = self.schemaExplorer
            explorer.definitionTasks[key] = Task {
                defer { explorer.definitionTasks[key] = nil }
                do {
                    let snapshot = try await self.snapshot(for: tab)
                    let info = try await self.engine.loadSQLDefinition(target: snapshot, table: table.name, connection: ref.appName, saved: saved)
                    let text = SQLDefinition.document(info, connection: choice.label, target: self.targetLabel(target), readAt: Date())
                    explorer.lastDefinition = "\(info.table) \(info.kind ?? "?") via \(info.how ?? "?")\(info.reconstructed == true ? " (reconstructed)" : ""): \(info.sql.count) characters"
                    self.openDefinitionTab(text, title: SQLDefinition.tabTitle(table.name), connection: choice, target: target, near: tab)
                } catch is CancellationError {
                    explorer.lastDefinition = "stopped"
                } catch {
                    explorer.lastDefinition = "failed: \(error)"
                    self.alert = AppAlert(title: "Runlet could not show the definition of \(table.name)", message: "\(error)")
                }
            }
        }
    }

    /// Whether Show Definition is reading `table` for the tab's explorer connection.
    func isLoadingDefinition(_ table: String, for tab: TabModel) -> Bool {
        guard let ref = explorerConnection(for: tab).ref else { return false }
        return schemaExplorer.definitionTasks[SQLSchemaStore.key(tab.target, ref) + "\u{1F}" + table] != nil
    }

    /// A new SQL tab holding a definition, on the explorer's target and connection, in the
    /// window of the tab it came from. It doesn't run, so it opens with the editor alone: the
    /// output pane comes back with a run or Show Output Pane (#60's per-tab dismissal).
    private func openDefinitionTab(_ text: String, title: String, connection: SQLConnectionChoice, target: TargetRef, near tab: TabModel) {
        let window = window(containing: tab.id)
        let opened = switch connection {
        case .saved(let saved):
            newTab(target: target, code: text, title: title, in: window, language: .sql, sqlSavedConnection: saved.id, sqlSavedConnectionName: saved.name)
        case .missing(let name):
            newTab(target: target, code: text, title: title, in: window, language: .sql, sqlSavedConnectionName: name)
        case .app(let name):
            newTab(target: target, code: text, title: title, in: window, language: .sql, sqlConnection: name)
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
