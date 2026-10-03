import AppKit
import Observation
import RunletCore

/// Explain Analyze's question before it runs a statement that can write (#147), on the tab's
/// window: "EXPLAIN ANALYZE runs the DELETE".
struct SQLAnalyzeConfirmation: Identifiable {
    let id = UUID()
    var windowId: UUID?
    var title: String
    var message: String
    var perform: () -> Void
}

/// The pending Explain Analyze question (#147), per app model.
@MainActor
@Observable
final class SQLExplainUI {
    var pendingAnalyze: SQLAnalyzeConfirmation?

    private static var stores: [ObjectIdentifier: SQLExplainUI] = [:]

    static func shared(for model: AppModel) -> SQLExplainUI {
        let key = ObjectIdentifier(model)
        if let existing = stores[key] { return existing }
        let created = SQLExplainUI()
        stores[key] = created
        return created
    }
}

/// Explain Statement in SQL tabs (#147): the plan of the statement at the caret (or the
/// selected one) on the tab's connection, application or saved, shown as a plan tree. Plain
/// Explain never runs the statement. Explain Analyze runs it: a statement that can write is
/// refused where Runlet can't undo it (MySQL, MariaDB, read-only connections) and asks first
/// elsewhere; production always asks. Placeholders get their values from #145's sheet.
extension AppModel {
    var sqlExplainUI: SQLExplainUI { SQLExplainUI.shared(for: self) }

    /// Why Explain Statement is unavailable for the current tab, or nil.
    func explainDisabledReason(for tab: TabModel?) -> String? {
        guard let tab else { return "Explain Statement works in SQL tabs." }
        if tab.language != .sql { return "Explain Statement works in SQL tabs." }
        if tab.isRunning { return "The tab is running." }
        return nil
    }

    func explainSQL(_ tab: TabModel, mode: SQLExplain.Mode) {
        guard !tab.isRunning, tab.language == .sql else { return }
        let editor = tab.editor
        let text = editor.text
        let selection = editor.selectedRange
        let statement: SQLScript.Statement
        switch SQLScript.statementToRun(in: text, selection: selection) {
        case .failure(let error):
            alert = AppAlert(title: error == .empty ? "No SQL to explain" : error.title, message: error.description)
            return
        case .success(let found):
            statement = found
        }
        if let refusal = SQLExplain.refusal(of: statement.text) {
            alert = AppAlert(title: "The statement is already an EXPLAIN", message: refusal)
            return
        }
        let choice = sqlConnectionChoice(for: tab)
        if case .missing(let name) = choice {
            alert = AppAlert(title: "The saved connection isn't defined", message: SQLConnectionChoice.missingMessage(name))
            return
        }
        let target = tab.target
        let saved = choice.savedConnection
        let driver = sqlDriver(for: choice, target: target)
        let write = mode == .analyze ? SQLExplain.analyzeWrite(of: statement.text) : nil
        if mode == .analyze, let refusal = analyzeRefusal(write: write, driver: driver, saved: saved) {
            alert = AppAlert(title: "Explain Analyze would run the statement", message: refusal)
            return
        }
        // #145: placeholders get their values from the same sheet as Run.
        let scan = SQLParameters.scan([statement], driver: driver)
        if let problem = scan.problem {
            alert = AppAlert(title: problem.title, message: problem.description)
            return
        }
        var base = SQLRunInfo(statement: statement, connection: choice.ref?.appName, saved: saved)
        base.explain = mode
        let lines = SQLRunInfo.linesLabel(statement)
        askForSQLParameters(scan, statements: [statement], in: tab, text: text, title: scan.parameters.count == 1 ? "Value for \(mode.title)" : "Values for \(mode.title)",
                            subtitle: "\(lines.prefix(1).uppercased() + lines.dropFirst()) · \(base.connectionLabel)", preview: statement.text, actionTitle: mode.title) { [weak self, weak tab] values in
            guard let self, let tab, tab.target == target, tab.language == .sql, !tab.isRunning, let bindings = scan.bindings(values) else { return }
            var info = base
            if !scan.isEmpty {
                info.values = scan.lines(values)
                info.historyCode = SQLParameters.historyCode(text, start: statement.range.location, end: NSMaxRange(statement.range), statements: [statement], scan: scan, values: values)
            }
            // Run History keeps the statement, saying it was explained, not run.
            info.historyCode = (mode == .plan ? "-- Explain Statement: Runlet showed the plan; the statement didn't run.\n" : "-- Explain Analyze: the statement ran to measure its plan.\n") + info.historyCode
            let start: @MainActor () -> Void = { [weak self, weak tab] in
                guard let self, let tab, tab.target == target, tab.language == .sql else { return }
                self.startRun(tab, code: SQLExplain.code(statement: statement.text, connection: info.connection, mode: mode, bindings: bindings.first ?? []), selection: nil, sql: info)
            }
            let next: @MainActor () -> Void = { [weak self, weak tab] in
                guard let self, let tab else { return }
                if self.isProduction(target, connection: saved) {
                    // Production asks every time; Explain Analyze of a write shows the
                    // `EXPLAIN ANALYZE … DELETE` warning there.
                    self.guardProduction(.sqlExplain(analyze: mode == .analyze), target: target, text: statement.text, isSelection: selection.length > 0,
                                         sqlWarning: mode == .analyze ? SQLExplain.productionWarning(analyzing: statement.text) : nil,
                                         sqlConnection: info.connectionLabel, sqlSaved: info.saved != nil, savedConnection: info.saved, sqlValues: info.values.isEmpty ? nil : info.values,
                                         in: self.window(containing: tab.id), perform: start)
                } else if mode == .analyze, let write {
                    self.sqlExplainUI.pendingAnalyze = SQLAnalyzeConfirmation(
                        windowId: self.window(containing: tab.id)?.id,
                        title: "EXPLAIN ANALYZE runs \(SQLExplain.analyzedStatement(write))",
                        message: Self.analyzeWriteMessage(write: write, driver: driver),
                        perform: start
                    )
                } else {
                    start()
                }
            }
            // After the values sheet, the next sheet or alert waits for it to go.
            if scan.isEmpty { next() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { next() } }
        }
    }

    /// Explain Analyze refused before anything is sent: SQLite has none; a write on MySQL or
    /// MariaDB, or on a read-only connection (#139), can't be undone or isn't allowed.
    private func analyzeRefusal(write: SQLScript.Effect?, driver: DatabaseDriverKind?, saved: DatabaseConnection?) -> String? {
        if driver == .sqlite {
            return "SQLite has no EXPLAIN ANALYZE. Explain Statement shows SQLite's query plan without running the statement."
        }
        guard let write else { return nil }
        let what = SQLExplain.analyzedStatement(write)
        if let saved, saved.readOnly {
            return "Explain Analyze runs \(what), and “\(saved.name)” is a read-only connection, which refuses statements that can change data. Explain Statement (without Analyze) shows the plan without running it."
        }
        if driver == .mysql {
            return "Explain Analyze runs \(what). MySQL and MariaDB commit DDL at once and can't roll back non-transactional tables, so Runlet runs only reading statements with Explain Analyze there. Explain Statement (without Analyze) shows the plan without running it."
        }
        return nil
    }

    /// The tab's question before Explain Analyze runs a statement that can write.
    static func analyzeWriteMessage(write: SQLScript.Effect, driver: DatabaseDriverKind?) -> String {
        let warning = write.warning.map { $0 + " " } ?? ""
        if driver == .pgsql {
            return warning + "Explain Analyze runs it to measure its plan. Runlet runs it in a transaction and rolls the transaction back, so its changes don't stay; sequences it advances and anything it does outside the database do."
        }
        return warning + "Explain Analyze runs it to measure its plan. On PostgreSQL, Runlet runs it in a transaction and rolls the transaction back, so its changes don't stay (sequences it advances do). MySQL, MariaDB, and SQLite refuse it, and nothing runs."
    }

    /// The tab's question was answered.
    func answerAnalyzeConfirmation(_ confirmed: Bool) {
        guard let pending = sqlExplainUI.pendingAnalyze else { return }
        sqlExplainUI.pendingAnalyze = nil
        if confirmed { pending.perform() }
    }
}
