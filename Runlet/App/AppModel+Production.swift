import AppKit
import Observation
import RunletCore
import RunletExecution

/// One statement of Run All Statements (#129) in the production confirmation.
struct SQLStatementCheck: Identifiable, Hashable {
    var index: Int
    var line: Int
    var text: String
    /// Why it can change data, from `SQLScript.effect`; nil for reads.
    var warning: String?

    var id: Int { index }
}

/// Something that runs code on a production target and waits for the user's confirmation.
struct ProductionConfirmation: Identifiable {
    let id = UUID()
    var action: GuardedAction
    var target: TargetRef
    /// The window whose sheet asks.
    var windowId: UUID?
    var targetName: String
    /// Where it runs: `user@host:directory`, a container, or a folder.
    var destination: String
    /// The code or command line, shortened to its first lines.
    var preview: String
    var lineCount: Int
    var isSelection: Bool
    /// Host commands run on this Mac (in the target's local folder), not on the target.
    var runsOnThisMac: Bool
    /// SQL tabs (#35): the statement can write (or Runlet can't tell), from `SQLScript.effect`.
    var sqlWarning: String?
    /// SQL tabs: the connection the statement runs on, e.g. "the default connection", or
    /// "the saved connection “Reporting” (pgsql, db.internal:5432/reports)".
    var sqlConnection: String?
    /// The connection is a saved one (#138): the run opens it without booting the application.
    var sqlSaved = false
    /// The saved connection whose own marking makes this production (#139) when the target
    /// isn't; nil when the target is production.
    var markedConnection: String?
    /// The saved connection is read-only (#139): the session can't write.
    var sqlReadOnly = false
    /// The saved connection's init statements (#140), which run first, as part of it.
    var sqlInitStatements: [String] = []
    /// Run All Statements (#129): every statement, with its own warning.
    var sqlStatements: [SQLStatementCheck]?
    /// Run All Statements: whether the script runs in one transaction.
    var sqlTransaction: Bool?
    /// Bound values (#145): listed next to the statement, in the sheet's order.
    var sqlValues: [SQLParameterLine]?
    /// Load Next (#146): the next page of a statement that ran before, e.g. "rows 1,001–2,000".
    var sqlPage: String?
    var perform: () -> Void

    /// Run All Statements with more than one statement.
    var isSQLScript: Bool { sqlStatements != nil }

    var allowsGrace: Bool { action == .run }

    var title: String {
        switch action {
        case .run: isSelection ? "Run the selection on production?" : "Run this code on production?"
        case .sql:
            if let sqlPage {
                "Load the next page on production (\(sqlPage))?"
            } else if let count = sqlStatements?.count {
                sqlWarning == nil ? "Run \(count == 1 ? "this SQL statement" : "\(count) SQL statements") on production?" : "Run \(count == 1 ? "this SQL statement" : "\(count) SQL statements") on production? \(count == 1 ? "It" : "Some") can change data."
            } else {
                sqlWarning == nil ? "Run this SQL on production?" : "Run this SQL on production? It can change data."
            }
        case .listCommands: "List commands on production?"
        case .command: "Run this command for production?"
        case .shell: "Open a shell on production?"
        case .repl: "Open a REPL on production?"
        case .appInfo: "Load App Info on production?"
        case .sqlSchema: "Read the schema on production?"
        case .sqlExplain(let analyze):
            !analyze ? "Explain this statement on production?"
                : sqlWarning == nil ? "Explain Analyze on production? It runs the statement." : "Explain Analyze on production? It runs the statement, which can change data."
        }
    }

    var confirmTitle: String {
        switch action {
        case .run: "Run on Production"
        case .sql: sqlPage != nil ? "Load Next on Production" : isSQLScript ? "Run All on Production" : "Run SQL on Production"
        case .listCommands: "List Commands"
        case .command: "Run Command"
        case .shell: "Open Shell"
        case .repl: "Open REPL"
        case .appInfo: "Load App Info"
        case .sqlSchema: "Load Schema"
        case .sqlExplain(let analyze): analyze ? "Explain Analyze on Production" : "Explain on Production"
        }
    }

    /// Why this is production: the target's marking, or the saved connection's (#139).
    private var marked: String {
        markedConnection.map { "The saved connection “\($0)” is marked as production." } ?? "\(targetName) is marked as production."
    }

    /// Bound values (#145) are listed under the statement.
    private var boundNote: String {
        sqlValues.map { " Its placeholders are bound to the \($0.count == 1 ? "value" : "\($0.count) values") listed below." } ?? ""
    }

    /// A read-only connection (#139) can't write, whatever the statement says.
    private var readOnlyNote: String {
        sqlReadOnly ? " The session is read-only: the database refuses writes." : ""
    }

    var explanation: String {
        switch action {
        case .run:
            "\(targetName) is marked as production. The code below runs there with the application's real data."
        case .sql:
            if let sqlPage {
                "\(marked) This is the next page of a previous statement: Load Next runs it again \(markedConnection == nil ? "there, " : "")\(sqlThrough), for \(sqlPage). Runlet asks before every SQL run on production." + readOnlyNote + boundNote
            } else if let statements = sqlStatements {
                "\(marked) The \(statements.count == 1 ? "statement" : "\(statements.count) statements") below run \(markedConnection == nil ? "there " : "")in order, \(sqlThrough), "
                    + (sqlTransaction == true ? "in one transaction: Runlet stops at the first error and rolls back. MySQL and MariaDB commit DDL (CREATE, ALTER, DROP, …) at once, so those can't be rolled back." : "without a transaction: Runlet stops at the first error, and the statements that ran before it stay.")
                    + readOnlyNote + boundNote
            } else {
                "\(marked) The statement below runs \(markedConnection == nil ? "there, " : "")\(sqlThrough). Runlet asks before every SQL run on production." + readOnlyNote + boundNote
            }
        case .listCommands:
            "Listing commands boots \(targetName) (its bootstrap code runs, as for a snippet). It is marked as production."
        case .command:
            runsOnThisMac
                ? "This host command runs on this Mac in the project's folder, for \(targetName), which is marked as production. It can change the production system."
                : "This command runs on \(targetName), which is marked as production."
        case .shell:
            "This opens a login shell on \(targetName), which is marked as production. Everything you type there runs on the server."
        case .repl:
            "This opens an interactive PHP session on \(targetName), which is marked as production. Each line you enter runs at once with the application's real data, and Runlet doesn't ask again inside it."
        case .appInfo:
            "App Info boots \(targetName) (its bootstrap code runs, as for a snippet) and reads its environment, caches, and drivers. It is marked as production."
        case .sqlExplain(let analyze):
            analyze
                ? "\(marked) Explain Analyze runs the statement below \(markedConnection == nil ? "there, " : "")\(sqlThrough), to show its plan with real row counts and timings. On PostgreSQL, Runlet runs it in a transaction and rolls it back; MySQL and MariaDB refuse statements that can write." + readOnlyNote
                : "\(marked) Explain asks the database for the plan of the statement below \(sqlThrough); the statement doesn't run. Runlet asks before every SQL action on production." + readOnlyNote
        case .sqlSchema:
            sqlSaved
                ? "Loading the schema opens \(sqlConnection ?? "the saved connection") from \(targetName) (no application code runs) and reads its table and column names, for completion. It reads no rows. \(marked)"
                : "Loading the schema boots \(targetName) (its bootstrap code runs, as for a snippet) and reads the table and column names of \(sqlConnection ?? "the default connection"), for completion. It reads no rows. \(marked)"
        }
    }

    /// How the SQL reaches the database: the application's connection, or a saved one (#138).
    private var sqlThrough: String {
        sqlSaved
            ? "on \(sqlConnection ?? "the saved connection"), opened from \(targetName)"
            : "with the application's real data, through its own database connection (\(sqlConnection ?? "the default connection"))"
    }
}

/// N14 production guard state: the pending confirmation and the in-memory grace
/// (`ProductionGrace`: snippet runs only, reset on relaunch and on target edits).
@MainActor
@Observable
final class ProductionGuard {
    var pending: ProductionConfirmation?
    var grace = ProductionGrace()

    private static var guards: [ObjectIdentifier: ProductionGuard] = [:]

    static func shared(for model: AppModel) -> ProductionGuard {
        let key = ObjectIdentifier(model)
        if let existing = guards[key] { return existing }
        let created = ProductionGuard()
        guards[key] = created
        return created
    }
}

extension AppModel {
    var productionGuard: ProductionGuard { ProductionGuard.shared(for: self) }

    func isProduction(_ target: TargetRef) -> Bool {
        library.isProduction(target)
    }

    /// Whether SQL on `target` through `connection` is production (#139): the target's
    /// marking, or the saved connection's own.
    func isProduction(_ target: TargetRef, connection: DatabaseConnection?) -> Bool {
        library.marking(for: target, connection: connection).isProduction
    }

    /// A target's settings changed: a granted grace no longer applies, and its App Info is
    /// read again next time.
    func targetEdited(_ target: TargetRef) {
        productionGuard.grace.revoke(target)
        forgetAppInfo(for: target)
        forgetSQLSchemas(for: target)
    }

    /// Runs `perform` now, or asks first when `target` is production. Snippet runs inside a
    /// granted 10-minute grace don't ask; listings and commands always do. SQL on a saved
    /// connection (#139) passes `savedConnection`: the stricter of the target's and the
    /// connection's marking applies.
    func guardProduction(_ action: GuardedAction, target: TargetRef, text: String, isSelection: Bool = false, runsOnThisMac: Bool = false, sqlWarning: String? = nil, sqlConnection: String? = nil, sqlSaved: Bool = false, savedConnection: DatabaseConnection? = nil, sqlStatements: [SQLStatementCheck]? = nil, sqlTransaction: Bool? = nil, sqlValues: [SQLParameterLine]? = nil, sqlPage: String? = nil, in window: WindowModel? = nil, perform: @escaping () -> Void) {
        let marking = library.marking(for: target, connection: savedConnection)
        guard productionGuard.grace.needsConfirmation(action, on: target, environment: marking.environment) else {
            perform()
            return
        }
        let preview = ProductionGrace.preview(of: text)
        productionGuard.pending = ProductionConfirmation(
            action: action,
            target: target,
            windowId: (window ?? self.window(containingTarget: target) ?? activeWindow)?.id,
            targetName: targetLabel(target),
            destination: productionDestination(target),
            preview: preview.text,
            lineCount: preview.lineCount,
            isSelection: isSelection,
            runsOnThisMac: runsOnThisMac,
            sqlWarning: sqlWarning,
            sqlConnection: sqlConnection,
            sqlSaved: sqlSaved,
            markedConnection: marking.fromConnection ? savedConnection?.name : nil,
            sqlReadOnly: savedConnection?.readOnly == true,
            sqlInitStatements: savedConnection?.normalized.initStatements ?? [],
            sqlStatements: sqlStatements,
            sqlTransaction: sqlTransaction,
            sqlValues: sqlValues,
            sqlPage: sqlPage,
            perform: perform
        )
    }

    /// The user confirmed (⌘↩). `grace` grants "don't ask again for 10 minutes" (snippet runs).
    func confirmProduction(_ confirmation: ProductionConfirmation, grace: Bool) {
        productionGuard.pending = nil
        if grace, confirmation.allowsGrace { productionGuard.grace.grant(confirmation.target) }
        confirmation.perform()
    }

    func cancelProduction() {
        productionGuard.pending = nil
    }

    // MARK: The application's own environment (#12)

    /// What a tab on `target` says about the environment its application reported on the last
    /// run, next to the target's marking; nil when nothing needs saying.
    func environmentNotice(for target: TargetRef) -> AppEnvironmentNotice? {
        let facts = targetFacts[target.stableKey]
        return AppEnvironmentNotice.decide(target: target, marking: library.environment(for: target), reported: facts?.appEnvironment, dismissed: facts?.dismissedEnvironmentNotices ?? [])
    }

    /// Mark as Production: the change choosing Production in the target's settings makes,
    /// saved the same way (a granted grace ends), so the badge and confirmations apply from the
    /// next run. Runs nothing.
    func markAsProduction(_ target: TargetRef) {
        switch target {
        case .sandbox:
            return
        case .local(let id):
            guard var project = library.localProject(id), project.environment != .production else { return }
            project.environment = .production
            saveProject(project)
        case .docker(let id):
            guard var profile = library.dockerProfile(id), profile.environment != .production else { return }
            profile.environment = .production
            saveDockerProfile(profile)
        case .ssh(let id):
            guard var profile = library.sshProfile(id), profile.environment != .production else { return }
            profile.environment = .production
            saveSSHProfile(profile)
        }
    }

    /// Dismiss: this kind of notice stays hidden for `target`, across relaunches (kept with
    /// the target's facts).
    func dismissEnvironmentNotice(_ kind: AppEnvironmentNotice.Kind, for target: TargetRef) {
        var facts = targetFacts[target.stableKey] ?? TargetFacts()
        facts.dismissedEnvironmentNotices = (facts.dismissedEnvironmentNotices ?? []).union([kind])
        targetFacts[target.stableKey] = facts
    }

    /// The active window if its selected tab uses `target`, else the first window that does.
    private func window(containingTarget target: TargetRef) -> WindowModel? {
        if let active = activeWindow, active.selectedTab?.target == target { return active }
        return windows.first { $0.tabs.contains { $0.target == target } }
    }

    /// "forge@shop:/home/forge/shop/current", "shop/app · /var/www/html", or a folder.
    func productionDestination(_ target: TargetRef) -> String {
        switch target {
        case .sandbox:
            return "Laravel Sandbox"
        case .local(let id):
            return library.localProject(id).map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? ""
        case .docker(let id):
            guard let profile = library.dockerProfile(id) else { return "" }
            return "\(profile.identity.displayName) · \(profile.workingDirectory)" + (profile.user.map { " · user \($0)" } ?? "")
        case .ssh(let id):
            guard let profile = library.sshProfile(id) else { return "" }
            if let step = profile.container {
                return "\(profile.destinationLabel) · container \(step.summary)" + (step.user.map { " · user \($0)" } ?? "")
            }
            return "\(profile.destinationLabel):\(profile.remoteDirectory)"
        }
    }
}
