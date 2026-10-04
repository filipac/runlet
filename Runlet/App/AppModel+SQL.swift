import AppKit
import Observation
import RunletCore
import RunletExecution

/// What an SQL tab's run carries besides its generated PHP (#35): one statement, or every
/// statement of Run All Statements (#129).
struct SQLRunInfo {
    var statements: [SQLScript.Statement]
    /// The tab's connection name; nil for the default connection (or a saved connection).
    var connection: String?
    /// A saved connection (#138): the definition the run request carries (no password).
    var saved: DatabaseConnection?
    /// Run All Statements: whether the script runs in one transaction. Nil for one statement.
    var transaction: Bool?
    /// What run history keeps: the statement, or the script from its first statement to its
    /// last; with bound values (#145), a `-- @param` line for each.
    var historyCode: String
    /// Bound values (#145), for the output's first line.
    var values: [SQLParameterLine] = []
    /// Each statement's bound values (#145), as the runner binds them; Load Next (#146) binds
    /// the same values again for every page.
    var bindings: [[SQLBinding]] = []
    /// Explain Statement (#147): the plan, or Explain Analyze; nil for a run.
    var explain: SQLExplain.Mode?

    init(statement: SQLScript.Statement, connection: String?, saved: DatabaseConnection? = nil) {
        statements = [statement]
        self.connection = saved == nil ? connection : nil
        self.saved = saved
        historyCode = statement.text
    }

    init(script statements: [SQLScript.Statement], in text: String, connection: String?, saved: DatabaseConnection? = nil, transaction: Bool) {
        self.statements = statements
        self.connection = saved == nil ? connection : nil
        self.saved = saved
        self.transaction = transaction
        let first = statements.first?.range.location ?? 0
        let end = statements.last.map { NSMaxRange($0.range) } ?? first
        historyCode = (text as NSString).substring(with: NSRange(location: first, length: end - first))
    }

    /// The schema cache's key for the run's connection.
    var ref: SQLConnectionRef { saved.map { .saved($0.id) } ?? .app(connection) }

    /// What Run History keeps of the connection (#149): the application connection's name, or
    /// the saved connection's id and name. Never its definition.
    var historyConnection: SQLConnectionReference { saved.map(SQLConnectionReference.init) ?? .application(connection) }

    /// "the default connection", "the saved connection “Reporting” (pgsql, db:5432/reports)",
    /// with "from this Mac" for one opened there (#142).
    var connectionLabel: String {
        saved.map { "the saved connection “\($0.name)” (\($0.summary))" + ($0.opensOnThisMac ? " from this Mac" : "") } ?? SQLRunInfo.label(for: connection)
    }

    /// The saved connection is read-only (#139).
    var readOnly: Bool { saved?.readOnly == true }

    /// "with :id = 42 and :status = 'paid' bound" (#145); empty without values.
    private var bound: String {
        guard !values.isEmpty else { return "" }
        let shown = values.prefix(4).map { $0.text(limit: 40) }
        let more = values.count > 4 ? ", and \(values.count - 4) more" : ""
        let list = shown.count > 1 && more.isEmpty ? shown.dropLast().joined(separator: ", ") + " and " + shown.last! : shown.joined(separator: ", ") + more
        return ", with \(list) bound"
    }

    /// The output's first line under the run header.
    var note: String {
        let session = readOnly ? ", in a read-only session" : ""
        guard let transaction else {
            let statement = statements[0]
            if let explain {
                // #147: what Explain does with the statement.
                let what = explain == .plan ? "the statement doesn't run" : "the statement runs" + (readOnly ? "" : "; on PostgreSQL in a transaction that is rolled back")
                return "\(explain.title) of \(Self.lines(statement)) on \(connectionLabel)\(session)\(bound): \(what)."
            }
            return "SQL from \(Self.lines(statement)) on \(connectionLabel)\(session)\(bound)."
        }
        let first = statements.first?.startLine ?? 1
        let last = statements.last.map { $0.startLine + $0.text.components(separatedBy: "\n").count - 1 } ?? first
        let place = first == last ? "line \(first)" : "lines \(first)–\(last)"
        let count = statements.count == 1 ? "1 statement" : "\(statements.count) statements"
        return "\(count) from \(place) on \(connectionLabel)\(session)\(bound), \(transaction ? "in one transaction" : "without a transaction"). Runlet stops at the first error."
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

/// A connection's schema for SQL completion (#128).
enum SQLSchemaState: Equatable {
    /// Load Schema is reading it; `previous` stays in use meanwhile.
    case loading(previous: SQLSchemaInfo?)
    case loaded(SQLSchemaInfo, at: Date)
    /// Reading failed (an explicit load, or the read after a statement).
    case failed(String, at: Date, previous: SQLSchemaInfo?)

    var schema: SQLSchemaInfo? {
        switch self {
        case .loading(let previous), .failed(_, _, let previous): previous
        case .loaded(let schema, _): schema
        }
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

/// Schemas per target and connection (#128), in memory until the target's settings change or
/// Runlet quits. Never saved: they are the application's, and can be read again.
@MainActor
@Observable
final class SQLSchemaStore {
    var states: [String: SQLSchemaState] = [:]
    @ObservationIgnored var tasks: [String: Task<Void, Never>] = [:]

    private static var stores: [ObjectIdentifier: SQLSchemaStore] = [:]

    static func shared(for model: AppModel) -> SQLSchemaStore {
        let key = ObjectIdentifier(model)
        if let existing = stores[key] { return existing }
        let created = SQLSchemaStore()
        stores[key] = created
        return created
    }

    /// Per target and connection reference: `app:<name>`, or `saved:<uuid>` (#138), which
    /// is the same database on every target (a connection of all targets, #142, is read once).
    static func key(_ target: TargetRef, _ connection: SQLConnectionRef) -> String {
        (connection.isSaved ? "saved" : target.stableKey) + "\u{1F}" + connection.key
    }
}

/// SQL tabs (#35): creating them, switching a tab's language, choosing the connection, and
/// running a statement. A statement runs only when the user presses Run: opening, importing,
/// or restoring an SQL tab never runs it, SQL tabs never auto-run, and MCP clients can't run
/// them. Production targets always ask, showing the statement and a warning when it can write.
extension AppModel {
    var sqlConnectionCatalog: SQLConnectionCatalog { SQLConnectionCatalog.shared(for: self) }
    var sqlSchemas: SQLSchemaStore { SQLSchemaStore.shared(for: self) }

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

    /// The application connection an SQL tab uses: a name from the application's config, or
    /// nil for its default connection. Only the name is stored: the application's connections
    /// need no credentials from Runlet. (Saved connections, #138: `setSQLSavedConnection`.)
    func setSQLConnection(_ name: String?, for tab: TabModel) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed?.isEmpty == false ? trimmed : nil
        tab.sqlConnectionNote = nil
        guard tab.sqlConnection != value || tab.sqlSavedConnection != nil || tab.sqlSavedConnectionName != nil else { return }
        tab.sqlConnection = value
        tab.sqlSavedConnection = nil
        tab.sqlSavedConnectionName = nil
        window(containing: tab.id)?.markEdited()
        scheduleSessionSave()
    }

    /// Application connection names to offer in an SQL tab's connection picker: those the
    /// target's driver listed in this session, plus the tab's own choice.
    func sqlConnectionNames(for tab: TabModel) -> [String] {
        var names = sqlConnectionCatalog.names[tab.target.stableKey] ?? []
        if tab.sqlSavedConnection == nil, tab.sqlSavedConnectionName == nil, let chosen = tab.sqlConnection, !names.contains(chosen) { names.append(chosen) }
        return names
    }

    /// The tab's connection for a run, or nil after explaining why it has none (a missing saved
    /// connection). Nothing runs.
    private func runnableSQLConnection(for tab: TabModel) -> SQLConnectionChoice? {
        let choice = sqlConnectionChoice(for: tab)
        if case .missing(let name) = choice {
            alert = AppAlert(title: "The saved connection isn't defined", message: SQLConnectionChoice.missingMessage(name))
            return nil
        }
        return choice
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
        guard let choice = runnableSQLConnection(for: tab) else { return }
        // #139: a read-only connection refuses writing and session-changing statements before
        // anything is sent (the database and the runner refuse them too).
        if let saved = choice.savedConnection, saved.readOnly, let refusal = SQLScript.readOnlyRefusal(of: statement.text, driver: saved.driver) {
            alert = AppAlert(title: SQLReadOnlyRefusal.title(connection: saved.name), message: refusal.message(connection: saved.name))
            return
        }
        let target = tab.target
        let effect = SQLScript.effect(of: statement.text)
        let text = editor.text
        let isSelection = selection.length > 0
        // #145: placeholders get their values from the parameters drawer (#168); ones PDO can't
        // bind are refused. Write detection and read-only refusals read the statement text.
        let scan = SQLParameters.scan([statement], driver: sqlDriver(for: choice, target: target))
        if let problem = scan.problem {
            alert = AppAlert(title: problem.title, message: problem.description)
            return
        }
        let base = SQLRunInfo(statement: statement, connection: choice.ref?.appName, saved: choice.savedConnection)
        withSQLParameterValues(scan, statements: [statement], in: tab, text: text, scope: .statement) { [weak self, weak tab] values in
            guard let self, let tab, tab.target == target, tab.language == .sql, !tab.isRunning, let bindings = scan.bindings(values) else { return }
            var info = base
            info.bindings = bindings
            if !scan.isEmpty {
                info.values = scan.lines(values)
                info.historyCode = SQLParameters.historyCode(text, start: statement.range.location, end: NSMaxRange(statement.range), statements: [statement], scan: scan, values: values)
            }
            self.guardProduction(.sql, target: target, text: statement.text, isSelection: isSelection,
                                 sqlWarning: effect.warning, sqlConnection: info.connectionLabel, sqlSaved: info.saved != nil, savedConnection: info.saved, sqlValues: info.values.isEmpty ? nil : info.values,
                                 in: self.window(containing: tab.id)) { [weak self, weak tab] in
                guard let self, let tab, tab.target == target, tab.language == .sql else { return }
                self.startRun(tab, code: SQLTabRun.code(statement: statement.text, connection: info.connection, maxRows: self.settings.sqlRowsPerPage, schema: self.wantsSQLSchema(target, info.ref), bindings: bindings.first ?? []), selection: nil, sql: info)
            }
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
        // #139: on a read-only connection, one refused statement refuses the whole script
        // before anything runs.
        if let saved = sqlConnectionChoice(for: tab).savedConnection, saved.readOnly {
            let refused = statements.enumerated().compactMap { index, statement in
                SQLScript.readOnlyRefusal(of: statement.text, driver: saved.driver).map { (index: index, statement: statement, refusal: $0) }
            }
            if let first = refused.first {
                alert = AppAlert(title: SQLReadOnlyRefusal.title(connection: saved.name),
                                 message: first.refusal.message(connection: saved.name, index: first.index + 1, count: statements.count, line: first.statement.startLine, others: refused.count - 1))
                return
            }
        }
        let transaction = tab.sqlTransaction
        if transaction, let control = statements.lazy.compactMap({ statement in SQLScript.transactionControl(of: statement.text).map { (line: statement.startLine, keyword: $0) } }).first {
            alert = AppAlert(title: "The script manages its own transaction",
                             message: "Line \(control.line) has \(control.keyword). Run All Statements runs the script in one transaction, which \(control.keyword) would end or nest. Turn off In a Transaction in the SQL bar to run the script as written, or remove \(control.keyword).")
            return
        }
        guard let choice = runnableSQLConnection(for: tab) else { return }
        let target = tab.target
        // #145: the values of the whole script, from the parameters drawer (#168): a name used
        // by several statements gets one value; each statement's `?`s get their own.
        let scan = SQLParameters.scan(statements, driver: sqlDriver(for: choice, target: target))
        if let problem = scan.problem {
            alert = AppAlert(title: problem.title, message: problem.description)
            return
        }
        let checks = statements.enumerated().map { index, statement in
            SQLStatementCheck(index: index + 1, line: statement.startLine, text: statement.text, warning: SQLScript.effect(of: statement.text).warning)
        }
        let base = SQLRunInfo(script: statements, in: text, connection: choice.ref?.appName, saved: choice.savedConnection, transaction: transaction)
        let isSelection = selection.length > 0
        withSQLParameterValues(scan, statements: statements, in: tab, text: text, scope: .all) { [weak self, weak tab] values in
            guard let self, let tab, tab.target == target, tab.language == .sql, !tab.isRunning, let bindings = scan.bindings(values) else { return }
            var info = base
            info.bindings = bindings
            if !scan.isEmpty {
                info.values = scan.lines(values)
                let start = statements.first?.range.location ?? 0
                info.historyCode = SQLParameters.historyCode(text, start: start, end: statements.last.map { NSMaxRange($0.range) } ?? start, statements: statements, scan: scan, values: values)
            }
            self.guardProduction(.sql, target: target, text: base.historyCode, isSelection: isSelection,
                                 sqlWarning: checks.contains { $0.warning != nil } ? "Some of these statements can change data or the schema." : nil,
                                 sqlConnection: info.connectionLabel, sqlSaved: info.saved != nil, savedConnection: info.saved, sqlStatements: checks, sqlTransaction: transaction,
                                 sqlValues: info.values.isEmpty ? nil : info.values,
                                 in: self.window(containing: tab.id)) { [weak self, weak tab] in
                guard let self, let tab, tab.target == target, tab.language == .sql else { return }
                self.startRun(tab, code: SQLTabRun.scriptCode(statements: statements, connection: info.connection, transaction: transaction, maxRows: self.settings.sqlRowsPerPage, schema: self.wantsSQLSchema(target, info.ref), bindings: bindings), selection: nil, sql: info)
            }
        }
    }

    // MARK: Schema (#128)

    /// The schema state of the tab's target and connection; nil when never read (or when the
    /// tab's saved connection is missing).
    func sqlSchemaState(for tab: TabModel) -> SQLSchemaState? {
        sqlConnectionChoice(for: tab).ref.flatMap { sqlSchemaState(target: tab.target, connection: $0) }
    }

    func sqlSchemaState(target: TargetRef, connection: SQLConnectionRef) -> SQLSchemaState? {
        sqlSchemas.states[SQLSchemaStore.key(target, connection)]
    }

    /// Whether a statement run should read the schema too: the first successful run of a
    /// connection in this session, except on production (the target's marking or a saved
    /// connection's, #139), where only Load Schema reads it (after its confirmation).
    func wantsSQLSchema(_ target: TargetRef, _ connection: SQLConnectionRef) -> Bool {
        let saved: DatabaseConnection? = if case .saved(let id) = connection { library.databaseConnection(id) } else { nil }
        return !isProduction(target, connection: saved) && sqlSchemas.states[SQLSchemaStore.key(target, connection)] == nil
    }

    /// A run read the schema of `connection`. A failed read is kept too, so later runs don't
    /// retry it; Load Schema does.
    func learnSQLSchema(_ schema: SQLSchemaInfo, for target: TargetRef, connection: SQLConnectionRef) {
        let key = SQLSchemaStore.key(target, connection)
        if let error = schema.error {
            if sqlSchemas.states[key]?.schema == nil { sqlSchemas.states[key] = .failed(error, at: Date(), previous: nil) }
        } else {
            sqlSchemas.states[key] = .loaded(schema, at: Date())
        }
    }

    /// Load Schema (or Reload): reads the tab's connection's tables and columns in a fresh
    /// runner, apart from the tab's output. Production asks first. Nothing else runs.
    func loadSQLSchema(for tab: TabModel) {
        let choice = sqlConnectionChoice(for: tab)
        if case .missing(let name) = choice {
            alert = AppAlert(title: "The saved connection isn't defined", message: SQLConnectionChoice.missingMessage(name))
            return
        }
        loadSQLSchema(for: tab, connection: choice)
    }

    /// Load Schema for `connection` on the tab's target (the schema explorer, #21, uses the
    /// default connection for PHP tabs). A saved connection (#138) boots no project code.
    func loadSQLSchema(for tab: TabModel, connection choice: SQLConnectionChoice) {
        guard let ref = choice.ref else { return }
        let target = tab.target
        let key = SQLSchemaStore.key(target, ref)
        guard sqlSchemas.states[key]?.isLoading != true else { return }
        let saved = choice.savedConnection
        let what = saved == nil
            ? "Read the table and column names of \(choice.label) (boots the application, reads no rows)"
            : "Read the table and column names of \(choice.label) (\(saved?.summary ?? "")) (opens the connection \(saved?.opensOnThisMac == true ? "from this Mac" : "without booting the application"), reads no rows)"
        guardProduction(.sqlSchema, target: target, text: what, sqlConnection: saved.map { "the saved connection “\($0.name)” (\($0.summary))" + ($0.opensOnThisMac ? " from this Mac" : "") } ?? choice.label, sqlSaved: saved != nil, savedConnection: saved,
                        in: window(containing: tab.id)) { [weak self, weak tab] in
            guard let self, let tab, tab.target == target else { return }
            let store = self.sqlSchemas
            let previous = store.states[key]?.schema
            store.states[key] = .loading(previous: previous)
            let task = Task {
                let state: SQLSchemaState
                do {
                    let snapshot = try await self.sqlSnapshot(for: tab, saved: saved)
                    state = .loaded(try await self.engine.loadSQLSchema(target: snapshot, connection: ref.appName, saved: saved), at: Date())
                } catch is CancellationError {
                    state = previous.map { .loaded($0, at: Date()) } ?? .failed("Stopped.", at: Date(), previous: nil)
                } catch {
                    state = .failed("\(error)", at: Date(), previous: previous)
                }
                guard store.states[key]?.isLoading == true else { return }
                store.tasks[key] = nil
                store.states[key] = state
            }
            store.tasks[key] = task
            // #180: listed in the Connection Manager while it reads; Close stops it.
            self.trackDatabaseWork(DatabaseWork(purpose: .schema, tabId: tab.id, tabTitle: tab.title, target: target, connection: choice) { task.cancel() }, until: task)
        }
    }

    /// Forget Schema: completion offers keywords again until the schema is read once more.
    func forgetSQLSchema(for tab: TabModel) {
        guard let ref = sqlConnectionChoice(for: tab).ref else { return }
        forgetSQLSchema(target: tab.target, ref: ref)
    }

    func forgetSQLSchema(target: TargetRef, ref: SQLConnectionRef) {
        let key = SQLSchemaStore.key(target, ref)
        sqlSchemas.tasks[key]?.cancel()
        sqlSchemas.tasks[key] = nil
        sqlSchemas.states[key] = nil
    }

    /// A target's settings changed: its schemas may belong to another database now (those of
    /// its own saved connections too; connections of all targets don't depend on it).
    func forgetSQLSchemas(for target: TargetRef) {
        let prefix = target.stableKey + "\u{1F}"
        for key in sqlSchemas.states.keys where key.hasPrefix(prefix) {
            sqlSchemas.tasks[key]?.cancel()
            sqlSchemas.tasks[key] = nil
            sqlSchemas.states[key] = nil
        }
        for connection in library.databaseConnections(for: target) {
            forgetSQLSchema(target: target, ref: .saved(connection.id))
        }
    }
}
