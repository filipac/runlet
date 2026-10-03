import AppKit
import Observation
import RunletCore

/// What an SQL tab's run carries besides its generated PHP (#35): one statement, or every
/// statement of Run All Statements (#129).
struct SQLRunInfo {
    var statements: [SQLScript.Statement]
    /// The tab's connection name; nil for the default connection.
    var connection: String?
    /// Run All Statements: whether the script runs in one transaction. Nil for one statement.
    var transaction: Bool?
    /// What run history keeps: the statement, or the script from its first statement to its last.
    var historyCode: String

    init(statement: SQLScript.Statement, connection: String?) {
        statements = [statement]
        self.connection = connection
        historyCode = statement.text
    }

    init(script statements: [SQLScript.Statement], in text: String, connection: String?, transaction: Bool) {
        self.statements = statements
        self.connection = connection
        self.transaction = transaction
        let first = statements.first?.range.location ?? 0
        let end = statements.last.map { NSMaxRange($0.range) } ?? first
        historyCode = (text as NSString).substring(with: NSRange(location: first, length: end - first))
    }

    /// The output's first line under the run header.
    var note: String {
        guard let transaction else {
            let statement = statements[0]
            return "SQL from \(Self.lines(statement)) on \(SQLRunInfo.label(for: connection))."
        }
        let first = statements.first?.startLine ?? 1
        let last = statements.last.map { $0.startLine + $0.text.components(separatedBy: "\n").count - 1 } ?? first
        let place = first == last ? "line \(first)" : "lines \(first)–\(last)"
        let count = statements.count == 1 ? "1 statement" : "\(statements.count) statements"
        return "\(count) from \(place) on \(SQLRunInfo.label(for: connection)), \(transaction ? "in one transaction" : "without a transaction"). Runlet stops at the first error."
    }

    private static func lines(_ statement: SQLScript.Statement) -> String {
        let lines = statement.text.components(separatedBy: "\n").count
        return lines == 1 ? "line \(statement.startLine)" : "lines \(statement.startLine)–\(statement.startLine + lines - 1)"
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

    /// Run All Statements (#129) in one transaction, or not. Nothing runs.
    func setSQLTransaction(_ isOn: Bool, for tab: TabModel) {
        guard tab.sqlTransaction != isOn else { return }
        tab.sqlTransaction = isOn
        window(containing: tab.id)?.markEdited()
        scheduleSessionSave()
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

    /// Run All Statements (#129): every statement of the selection (else of the tab) in order,
    /// on one connection and in one process, stopping at the first error; in one transaction
    /// unless the tab turned that off. A script that manages transactions itself is refused
    /// while the transaction is on. Production asks once, listing every statement.
    func runAllSQL(_ tab: TabModel) {
        guard !tab.isRunning, tab.language == .sql else { return }
        let editor = tab.editor
        let text = editor.text
        let selection = editor.selectedRange
        let statements: [SQLScript.Statement]
        switch SQLScript.statementsToRunAll(in: text, selection: selection) {
        case .failure(let error):
            alert = AppAlert(title: error.title, message: error.description)
            return
        case .success(let found):
            statements = found
        }
        let transaction = tab.sqlTransaction
        if transaction, let control = statements.lazy.compactMap({ statement in SQLScript.transactionControl(of: statement.text).map { (line: statement.startLine, keyword: $0) } }).first {
            alert = AppAlert(title: "The script manages its own transaction",
                             message: "Line \(control.line) has \(control.keyword). Run All Statements runs the script in one transaction, which \(control.keyword) would end or nest. Turn off In a Transaction in the SQL bar to run the script as written, or remove \(control.keyword).")
            return
        }
        let connection = tab.sqlConnection
        let target = tab.target
        let checks = statements.enumerated().map { index, statement in
            SQLStatementCheck(index: index + 1, line: statement.startLine, text: statement.text, warning: SQLScript.effect(of: statement.text).warning)
        }
        let info = SQLRunInfo(script: statements, in: text, connection: connection, transaction: transaction)
        guardProduction(.sql, target: target, text: info.historyCode, isSelection: selection.length > 0,
                        sqlWarning: checks.contains { $0.warning != nil } ? "Some of these statements can change data or the schema." : nil,
                        sqlConnection: SQLRunInfo.label(for: connection), sqlStatements: checks, sqlTransaction: transaction,
                        in: window(containing: tab.id)) { [weak self, weak tab] in
            guard let self, let tab, tab.target == target, tab.language == .sql else { return }
            self.startRun(tab, code: SQLTabRun.scriptCode(statements: statements, connection: connection, transaction: transaction), selection: nil, sql: info)
        }
    }
}
