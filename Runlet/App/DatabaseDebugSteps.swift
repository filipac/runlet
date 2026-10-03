#if DEBUG
import Foundation
import RunletCore

/// RUNLET_DEBUG_STEPS for saved database connections (#138), for screenshots and scripted
/// checks with scratch data and fixture passwords only (see `DebugSteps`). Debug builds with a
/// scratch `RUNLET_DATA_DIR` keep passwords in memory (`AppModel.makeCredentialStore`), so
/// these steps never touch the login keychain:
/// `db-new:<name>|<driver>|<host>|<port>|<database>|<user>|<password>[|<marks>]` saves a
/// connection for the current tab's target (empty parts are left out; `\c` is a comma; marks,
/// #139, are joined with `+`: `ro` for Read-only, an environment such as `production`, a
/// colour such as `red`) ·
/// `db-use:<name>` switches the current SQL tab to that saved connection (`db-use:` back to the
/// default connection) · `db-editor:new` or `db-editor:<name>` opens the SQL bar's connection
/// editor on the current tab's target · `db-field:<field>=<value>` sets a field of the open
/// editor (`name`, `driver`, `host`, `port`, `database`, `user`, `password`, `timeout`, and,
/// #139, `readOnly` = on/off, `environment` = development/staging/production, `color` = a
/// colour or none) ·
/// `db-test` presses its Test Connection and `db-wait[:<seconds>]` waits for the result ·
/// `db-save` and `db-cancel` press Save and Cancel · `db-picker` opens the SQL bar's
/// connection picker (`db-picker:off` closes it) · `db-list` opens Edit Connections… · `db-state` prints the current
/// tab's connection and the open editor's test state.
@MainActor
enum DatabaseDebugSteps {
    /// Runs one step; false when `name` isn't one of these. (`db-wait` is in `RunletApp`, which
    /// holds the steps.)
    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        switch name {
        case "db-new":
            guard let tab = model.selectedTab else { return true }
            let parts = argument.replacingOccurrences(of: "\\c", with: ",").split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            func part(_ index: Int) -> String { parts.indices.contains(index) ? parts[index] : "" }
            var connection = DatabaseConnection(name: part(0), scope: tab.target, driver: DatabaseDriverKind(rawValue: part(1)) ?? .mysql, host: part(2), port: Int(part(3)), database: part(4), user: part(5))
            for mark in part(7).split(separator: "+").map(String.init) {
                if mark == "ro" { connection.readOnly = true }
                if let environment = TargetEnvironment(rawValue: mark) { connection.environment = environment }
                if let color = TargetColor(rawValue: mark) { connection.color = color }
            }
            let errors = connection.validate(others: model.databaseConnections(for: tab.target))
            guard errors.isEmpty else {
                log("db-new: \(errors.map(\.description))")
                return true
            }
            model.saveDatabaseConnection(connection, password: part(6).isEmpty ? .keep : .replace(SensitiveString(part(6))))
        case "db-use":
            guard let tab = model.selectedTab else { return true }
            if argument.isEmpty {
                model.setSQLConnection(nil, for: tab)
            } else if let connection = model.databaseConnections(for: tab.target).first(where: { $0.name == argument }) {
                model.setSQLSavedConnection(connection, for: tab)
            } else {
                log("db-use: no saved connection named \(argument)")
            }
        case "db-editor":
            guard let tab = model.selectedTab else { return true }
            model.databaseUI.windowId = model.activeWindow?.id
            if argument == "new" || argument.isEmpty {
                model.databaseUI.editor = model.newConnectionDraft(for: tab.target, useInTab: tab.id)
            } else if let connection = model.databaseConnections(for: tab.target).first(where: { $0.name == argument }) {
                model.databaseUI.editor = model.editConnectionDraft(connection)
            }
        case "db-field":
            guard let draft = DatabaseConnectionDraft.current ?? model.databaseUI.editor else {
                log("db-field: no open editor")
                return true
            }
            let pair = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let value = pair.count == 2 ? pair[1].replacingOccurrences(of: "\\c", with: ",") : ""
            switch pair.first {
            case "name": draft.connection.name = value
            case "driver":
                draft.connection.driver = DatabaseDriverKind(rawValue: value) ?? draft.connection.driver
                draft.connection.port = nil
            case "host": draft.connection.host = value
            case "port": draft.connection.port = Int(value)
            case "database": draft.connection.database = value
            case "user": draft.connection.user = value
            case "password":
                draft.passwordMode = .replace
                draft.password = value
            case "timeout": draft.connection.connectTimeout = Int(value) ?? draft.connection.connectTimeout
            case "readOnly": draft.connection.readOnly = value == "on"
            case "environment": draft.connection.environment = TargetEnvironment(rawValue: value).flatMap { $0 == .development ? nil : $0 }
            case "color": draft.connection.color = TargetColor(rawValue: value)
            default: log("db-field: unknown field \(argument)")
            }
        case "db-test":
            if let draft = DatabaseConnectionDraft.current ?? model.databaseUI.editor { model.runConnectionTest(draft) }
        case "db-save":
            if let draft = DatabaseConnectionDraft.current ?? model.databaseUI.editor {
                model.commitConnectionDraft(draft)
                model.databaseUI.editor = nil
            }
        case "db-cancel":
            model.databaseUI.editor = nil
        case "db-picker":
            NotificationCenter.default.post(name: .debugShowConnectionPicker, object: argument != "off")
        case "db-list":
            guard let tab = model.selectedTab else { return true }
            model.databaseUI.windowId = model.activeWindow?.id
            model.databaseUI.listTarget = tab.target
        case "db-state":
            log("db-state: \(state(model))")
        default:
            return false
        }
        return true
    }

    /// Whether the open editor's Test Connection is still running (`db-wait`).
    static func isTesting(_ model: AppModel) -> Bool {
        (DatabaseConnectionDraft.current ?? model.databaseUI.editor)?.test == .testing
    }

    static func state(_ model: AppModel) -> String {
        let tab = model.selectedTab.map { "\(model.sqlConnectionChoice(for: $0).label)" } ?? "no tab"
        let test: String
        switch (DatabaseConnectionDraft.current ?? model.databaseUI.editor)?.test {
        case nil: test = "no editor"
        case .idle?: test = "idle"
        case .testing?: test = "testing"
        case .succeeded(let info)?: test = info.summary
        case .failed(let message)?: test = "failed: \(message)"
        }
        return "tab=\(tab) saved=\(model.library.databaseConnections.map(\.name)) test=\(test)"
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(message)\n".utf8))
    }
}

extension Notification.Name {
    /// DEBUG step `db-picker`: opens the SQL bar's connection picker without a click.
    static let debugShowConnectionPicker = Notification.Name("RunletDebugShowConnectionPicker")
}
#endif
