import AppKit
import Observation
import RunletCore

/// What an SQL tab's run carries besides its generated PHP (#35).
struct SQLRunInfo {
    var statement: SQLScript.Statement
    /// The tab's connection name; nil for the default connection.
    var connection: String?

    /// The output's first line under the run header.
    var note: String {
        let lines = statement.text.components(separatedBy: "\n").count
        let place = lines == 1 ? "line \(statement.startLine)" : "lines \(statement.startLine)–\(statement.startLine + lines - 1)"
        return "SQL from \(place) on \(SQLRunInfo.label(for: connection))."
    }

    static func label(for connection: String?) -> String {
        connection.map { "the “\($0)” connection" } ?? "the default connection"
    }
}

/// Connection names the runner reported for each target during this session (#35), for the
/// SQL tabs' connection pickers. Never saved: the application's config is the source.
@MainActor
@Observable
final class SQLConnectionCatalog {
    var names: [String: [String]] = [:]

    private static var catalogs: [ObjectIdentifier: SQLConnectionCatalog] = [:]

    static func shared(for model: AppModel) -> SQLConnectionCatalog {
        let key = ObjectIdentifier(model)
        if let existing = catalogs[key] { return existing }
        let created = SQLConnectionCatalog()
        catalogs[key] = created
        return created
    }
}

/// SQL tabs (#35): creating them, switching a tab's language, choosing the connection, and
/// running a statement. A statement runs only when the user presses Run: opening, importing,
/// or restoring an SQL tab never runs it, SQL tabs never auto-run, and MCP clients can't run
/// them. Production targets always ask, showing the statement and a warning when it can write.
extension AppModel {
    var sqlConnectionCatalog: SQLConnectionCatalog { SQLConnectionCatalog.shared(for: self) }

    /// File ▸ New SQL Tab: an empty SQL tab on the current tab's target.
    @discardableResult
    func newSQLTab(in window: WindowModel? = nil) -> TabModel {
        let window = window ?? activeWindow
        let target = window?.selectedTab?.target
        var number = 1
        while window?.tabs.contains(where: { $0.title == "SQL \(number)" }) == true { number += 1 }
        return newTab(target: target, code: "", title: "SQL \(number)", in: window, language: .sql)
    }

    /// Switches a tab between PHP and SQL. SQL tabs have no language server; PHP tabs get
    /// theirs back. Nothing runs.
    func setLanguage(_ language: TabLanguage, for tab: TabModel) {
        guard tab.language != language else { return }
        tab.setLanguage(language)
        bindLanguage(tab)
        window(containing: tab.id)?.markEdited()
        scheduleSessionSave()
    }

    /// The connection an SQL tab uses: a name from the application's config, or nil for its
    /// default connection. Only the name is stored; Runlet never stores credentials.
    func setSQLConnection(_ name: String?, for tab: TabModel) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed?.isEmpty == false ? trimmed : nil
        guard tab.sqlConnection != value else { return }
        tab.sqlConnection = value
        window(containing: tab.id)?.markEdited()
        scheduleSessionSave()
    }

    /// Names to offer in an SQL tab's connection picker: those the target's driver listed in
    /// this session, plus the tab's own choice.
    func sqlConnectionNames(for tab: TabModel) -> [String] {
        var names = sqlConnectionCatalog.names[tab.target.stableKey] ?? []
        if let chosen = tab.sqlConnection, !names.contains(chosen) { names.append(chosen) }
        return names
    }

    func learnSQLConnections(_ result: SQLResultInfo, for target: TargetRef) {
        guard let names = result.connections, !names.isEmpty, sqlConnectionCatalog.names[target.stableKey] != names else { return }
        sqlConnectionCatalog.names[target.stableKey] = names
    }

    /// Runs an SQL tab's statement: the selection (one statement), else the statement at the
    /// caret (`SQLScript.statementToRun`). Several statements are refused before anything runs.
    func runSQL(_ tab: TabModel, selectionOnly: Bool) {
        guard !tab.isRunning, tab.language == .sql else { return }
        let editor = tab.editor
        let selection = editor.selectedRange
        let statement: SQLScript.Statement
        switch SQLScript.statementToRun(in: editor.text, selection: selection, selectionOnly: selectionOnly) {
        case .failure(let error):
            alert = AppAlert(title: error.title, message: error.description)
            return
        case .success(let found):
            statement = found
        }
        let connection = tab.sqlConnection
        let target = tab.target
        let effect = SQLScript.effect(of: statement.text)
        guardProduction(.sql, target: target, text: statement.text, isSelection: selection.length > 0,
                        sqlWarning: effect.warning, sqlConnection: SQLRunInfo.label(for: connection),
                        in: window(containing: tab.id)) { [weak self, weak tab] in
            guard let self, let tab, tab.target == target, tab.language == .sql else { return }
            self.startRun(tab, code: SQLTabRun.code(statement: statement.text, connection: connection), selection: nil,
                          sql: SQLRunInfo(statement: statement, connection: connection))
        }
    }
}
