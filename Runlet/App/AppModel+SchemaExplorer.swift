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
extension AppModel {
    var schemaExplorer: SchemaExplorerState { SchemaExplorerState.shared(for: self) }

    /// The connection the explorer shows for a tab: an SQL tab's, else the default.
    func explorerConnection(for tab: TabModel) -> String? {
        tab.language == .sql ? tab.sqlConnection : nil
    }

    /// The framework the tab's target last reported (for Open as PHP).
    func framework(for tab: TabModel) -> String? {
        tab.lastRun?.framework ?? targetFacts[tab.target.stableKey]?.framework
    }

    /// Open in SQL Tab: the table's first rows in a new SQL tab on the same target and
    /// connection. It doesn't run.
    func openSchemaTable(_ table: String, schema: SQLSchemaInfo, from tab: TabModel) {
        let query = SQLSchemaExplorer.selectQuery(table: table, driver: schema.driver)
        newTab(target: tab.target, code: query, title: table, language: .sql, sqlConnection: explorerConnection(for: tab))
        focusSelectedEditor()
    }

    /// Open as PHP (Laravel): the query builder for the table in a new PHP tab. It doesn't run.
    func openSchemaTableAsPHP(_ table: String, from tab: TabModel) {
        newTab(target: tab.target, code: SQLSchemaExplorer.laravelQuery(table: table, connection: explorerConnection(for: tab)), title: table, language: .php)
        focusSelectedEditor()
    }

    /// Inserts a name at the current tab's cursor (quoted for SQL tabs when it must be).
    func insertSchemaName(_ name: String, schema: SQLSchemaInfo) {
        guard let tab = selectedTab else { return }
        tab.editor.insert(tab.language == .sql ? SQLSchemaExplorer.quoted(name, driver: schema.driver) : name)
        focusSelectedEditor()
    }
}
