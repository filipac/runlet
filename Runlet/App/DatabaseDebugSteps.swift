#if DEBUG
import Foundation
import RunletCore
import RunletExecution

/// RUNLET_DEBUG_STEPS for saved database connections (#138), for screenshots and scripted
/// checks with scratch data and fixture passwords only (see `DebugSteps`). Debug builds with a
/// scratch `RUNLET_DATA_DIR` keep passwords in memory (`AppModel.makeCredentialStore`), so
/// these steps never touch the login keychain:
/// `db-new:<name>|<driver>|<host>|<port>|<database>|<user>|<password>[|<marks>]` saves a
/// connection for the current tab's target (empty parts are left out; `\c` is a comma; marks,
/// #139, are joined with `+`: `ro` for Read-only, an environment such as `production`, a
/// colour such as `red`; #142: `mac` connects from this Mac, `all` saves it for all targets) ·
/// `db-use:<name>` switches the current SQL tab to that saved connection (`db-use:` back to the
/// default connection) · `db-editor:new` or `db-editor:<name>` opens the SQL bar's connection
/// editor on the current tab's target · `db-field:<field>=<value>` sets a field of the open
/// editor (`name`, `driver`, `host`, `port`, `database`, `user`, `password`, `timeout`, and,
/// #139, `readOnly` = on/off, `environment` = development/staging/production, `color` = a
/// colour or none; #140: `advanced` = on/off, `socket` (empty: on with no path; `off`),
/// `charset`, `tls` = a mode or `default`, `tlsCA`, `tlsCert`, `tlsKey`, `init` = statements
/// joined by `|`, `options` = `key=value` pairs joined by `|`, `dsn`; #142: `connectFrom` =
/// target/mac, `scope` = all/target; #143: `connectFrom` = tunnel, `sshProfile` = a profile's
/// name) ·
/// `db-test` presses its Test Connection and `db-wait[:<seconds>]` waits for the result ·
/// `db-save` and `db-cancel` press Save and Cancel · `db-picker` opens the SQL bar's
/// connection picker (`db-picker:off` closes it) · `db-list` opens Edit Connections… · `db-state` prints the current
/// tab's connection and the open editor's test state. #143: `db-new`'s mark `via-<SSH profile>`
/// saves the connection through that profile's tunnel · `ssh-add:<name>|<[user@]host[:port]>|<directory>[|<environment>]`
/// saves an SSH profile (agent or key login; use `RUNLET_SSH_CONFIG` with the fixture's host
/// and key) · `ssh-open:<name>` opens its shared connection, as Connect in the tunnel's
/// question does · `db-tunnel-state` prints the forwards and the profiles' connections ·
/// `history-open[:<n>]` opens Run History's nth entry (0, the newest, by default) in a new tab,
/// as Open in New Tab does (#149: on its connection).
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
            if !TargetLibrary.supportsDatabaseConnections(tab.target) { connection.scope = nil }
            for mark in part(7).split(separator: "+").map(String.init) {
                if mark == "ro" { connection.readOnly = true }
                if mark == "mac" { connection.connectFrom = .thisMac }
                if mark == "all" { connection.scope = nil }
                if mark.hasPrefix("via-") {
                    connection.connectFrom = .sshTunnel
                    connection.sshProfile = model.library.sshProfiles.first { $0.name == String(mark.dropFirst(4)) }?.id
                }
                if let environment = TargetEnvironment(rawValue: mark) { connection.environment = environment }
                if let color = TargetColor(rawValue: mark) { connection.color = color }
            }
            let errors = connection.validate(others: model.library.databaseConnections)
            guard errors.isEmpty else {
                log("db-new: \(errors.map(\.description))")
                return true
            }
            model.saveDatabaseConnection(connection, password: part(6).isEmpty ? .keep : .replace(SensitiveString(part(6))))
        case "db-use":
            guard let tab = model.selectedTab else { return true }
            if argument.isEmpty {
                model.setSQLConnection(nil, for: tab)
            } else if let connection = model.library.databaseConnection(id: nil, name: argument, on: tab.target) {
                model.setSQLSavedConnection(connection, for: tab)
            } else {
                log("db-use: no saved connection named \(argument)")
            }
        case "db-editor":
            guard let tab = model.selectedTab else { return true }
            model.databaseUI.windowId = model.activeWindow?.id
            if argument == "new" || argument.isEmpty {
                model.databaseUI.editor = model.newConnectionDraft(for: tab.target, useInTab: tab.id)
            } else if let connection = model.library.databaseConnection(id: nil, name: argument, on: tab.target) {
                model.databaseUI.editor = model.editConnectionDraft(connection, from: tab.target)
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
            // #140
            case "advanced": draft.showAdvanced = value != "off"
            case "socket": draft.connection.socket = value == "off" ? nil : value
            case "charset": draft.connection.charset = value.isEmpty ? nil : value
            case "tls": draft.connection.tls = DatabaseTLSMode(rawValue: value).map { DatabaseTLS(mode: $0, caFile: draft.connection.tls?.caFile, certificateFile: draft.connection.tls?.certificateFile, keyFile: draft.connection.tls?.keyFile) }
            case "tlsCA": draft.connection.tls?.caFile = value.isEmpty ? nil : value
            case "tlsCert": draft.connection.tls?.certificateFile = value.isEmpty ? nil : value
            case "tlsKey": draft.connection.tls?.keyFile = value.isEmpty ? nil : value
            case "init": draft.connection.initStatements = value.isEmpty ? [] : value.components(separatedBy: "|")
            case "options":
                draft.connection.options = value.isEmpty ? [] : value.components(separatedBy: "|").map { pair in
                    let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                    return DatabaseOption(key: parts[0], value: parts.count > 1 ? parts[1] : "")
                }
            case "dsn": draft.connection.dsn = value.isEmpty ? nil : value
            // #142
            case "connectFrom":
                draft.connection.connectFrom = value == "mac" ? .thisMac : value == "tunnel" ? .sshTunnel : .target
                if draft.connection.usesSSHTunnel { draft.connection.socket = nil }
            case "sshProfile": draft.connection.sshProfile = model.library.sshProfiles.first { $0.name == value }?.id
            case "scope":
                draft.connection.scope = value == "all" ? nil : draft.homeTarget
                if draft.connection.scope == nil { draft.connection.connectFrom = .thisMac }
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
        // #143
        case "ssh-add":
            let parts = argument.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { return true }
            var profile = SSHProfile(name: parts[0], host: parts[1], remoteDirectory: parts.count > 2 && !parts[2].isEmpty ? parts[2] : "/")
            // #188: `user@host[:port]` sets the user and port too.
            if let at = parts[1].firstIndex(of: "@") {
                profile.user = String(parts[1][..<at])
                profile.host = String(parts[1][parts[1].index(after: at)...])
            }
            if let colon = profile.host.lastIndex(of: ":"), let port = Int(profile.host[profile.host.index(after: colon)...]) {
                profile.port = port
                profile.host = String(profile.host[..<colon])
            }
            if parts.count > 3, let environment = TargetEnvironment(rawValue: parts[3]) { profile.environment = environment }
            model.saveSSHProfile(profile)
        case "ssh-open":
            guard let profile = model.library.sshProfiles.first(where: { $0.name == argument }) else {
                log("ssh-open: no SSH profile named \(argument)")
                return true
            }
            let endpoint = model.sshEndpoint(for: profile)
            let client = model.sshClient
            Task {
                do {
                    try await client.openSharedConnection(endpoint)
                    log("ssh-open: connected to \(profile.name)")
                } catch {
                    log("ssh-open: \(error)")
                }
                model.refreshSSHStatus(profile.id)
            }
        case "history-open":
            let index = Int(argument) ?? 0
            guard model.history.indices.contains(index) else {
                log("history-open: no entry \(index)")
                return true
            }
            model.restore(model.history[index], inNewTab: true)
        case "db-tunnel-state":
            Task {
                let statuses = model.library.sshProfiles.map { "\($0.name)=\(model.refreshSSHStatus($0.id).rawValue)" }.joined(separator: " ")
                log("db-tunnel-state: \(await model.sqlTunnelState()) ssh: \(statuses)")
            }
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
        let saved = model.library.databaseConnections.map { "\($0.name)\($0.isAllTargets ? "(all)" : "")\($0.opensOnThisMac ? "(mac)" : "")" }
        return "tab=\(tab) saved=\(saved) test=\(test)"
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
