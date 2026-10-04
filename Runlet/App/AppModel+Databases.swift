import AppKit
import Observation
import RunletCore
import RunletExecution

/// What an SQL tab's connection resolves to (#138).
enum SQLConnectionChoice: Equatable {
    /// One the application configures, by name; nil is its default connection.
    case app(String?)
    /// One the user saved for the tab's target, or for all targets (#142).
    case saved(DatabaseConnection)
    /// A saved connection the tab names that its target doesn't have (a workspace from another
    /// Mac, a deleted connection, or a tab moved to another target).
    case missing(String)

    /// The schema cache's key; nil when the connection is missing.
    var ref: SQLConnectionRef? {
        switch self {
        case .app(let name): .app(name)
        case .saved(let connection): .saved(connection.id)
        case .missing: nil
        }
    }

    var savedConnection: DatabaseConnection? {
        if case .saved(let connection) = self { return connection }
        return nil
    }

    /// "the default connection", "the “mysql” connection", "the saved connection “Reporting”".
    var label: String {
        switch self {
        case .app(let name): SQLRunInfo.label(for: name)
        case .saved(let connection): "the saved connection “\(connection.name)”"
        case .missing(let name): "the saved connection “\(name)”"
        }
    }

    /// The message shown when a tab's saved connection isn't defined for its target.
    static func missingMessage(_ name: String) -> String {
        "The saved connection “\(name)” isn't defined for this target. Choose another connection, or create it with New Connection…."
    }
}

/// A saved connection's password, as the editor changes it.
enum DatabasePasswordChange {
    case keep
    case replace(SensitiveString)
    case remove
}

/// An open connection editor (#138): the definition being edited, the password typed in it
/// (never saved until Save), and Test Connection's state. Debug steps fill it through
/// `current`. Cancelling drops it, so nothing typed is kept.
@MainActor
@Observable
final class DatabaseConnectionDraft: Identifiable {
    enum PasswordMode: Equatable {
        /// A saved connection's stored password stays (or it has none).
        case keep
        /// The secure field: a new password (typed, possibly empty for none).
        case replace
        /// Remove the stored password on Save.
        case remove
    }

    enum TestState: Equatable {
        case idle
        case testing
        case succeeded(SQLConnectionTestInfo)
        case failed(String)
    }

    let id = UUID()
    var connection: DatabaseConnection
    let isNew: Bool
    /// The password typed in the secure field. Handed on only as a `SensitiveString`.
    var password = ""
    var passwordMode: PasswordMode
    /// Whether the saved connection has a password in the store (the editor never shows it).
    let hasStoredPassword: Bool
    var test: TestState = .idle
    /// The editor's Advanced section (#140) is open: from the start when the connection uses
    /// one of its options.
    var showAdvanced: Bool
    /// The SQL tab that switches to the connection once it is saved (New Connection… in the SQL bar).
    var useInTab: UUID?
    /// The target the connection can belong to (#142): its own, or the tab's it was created
    /// from; nil when it can only be one of all targets (from the sandbox or Settings ▸ Databases).
    let homeTarget: TargetRef?
    @ObservationIgnored var testTask: Task<Void, Never>?

    /// The open editor, for Debug steps.
    static weak var current: DatabaseConnectionDraft?

    init(connection: DatabaseConnection, isNew: Bool, hasStoredPassword: Bool, useInTab: UUID? = nil, homeTarget: TargetRef? = nil) {
        self.connection = connection
        self.homeTarget = connection.scope ?? homeTarget.flatMap { TargetLibrary.supportsDatabaseConnections($0) ? $0 : nil }
        self.isNew = isNew
        self.hasStoredPassword = hasStoredPassword
        passwordMode = isNew || !hasStoredPassword ? .replace : .keep
        self.useInTab = useInTab
        showAdvanced = connection.socket != nil || connection.charset != nil || connection.tls != nil || !connection.initStatements.isEmpty || !connection.options.isEmpty
    }

    var passwordChange: DatabasePasswordChange {
        switch passwordMode {
        case .keep: .keep
        case .remove: .remove
        case .replace: password.isEmpty ? (hasStoredPassword ? .remove : .keep) : .replace(SensitiveString(password))
        }
    }

    /// The password Test Connection uses: the typed one, else the stored one.
    var testPassword: ExecutionEngine.SQLPassword {
        switch passwordMode {
        case .keep: hasStoredPassword ? .stored : .given(nil)
        case .remove: .given(nil)
        case .replace: .given(password.isEmpty ? nil : SensitiveString(password))
        }
    }
}

/// The SQL bar's requests for the connection sheets, presented by the main window.
@MainActor
@Observable
final class DatabaseConnectionsUI {
    /// New Connection… or Edit… from the SQL bar.
    var editor: DatabaseConnectionDraft?
    /// Edit Connections…: the target whose connections the sheet lists.
    var listTarget: TargetRef?
    /// Which window shows them.
    var windowId: UUID?
    /// Whether each connection has a password in the store (`exists` asks the store without
    /// reading the secret); filled on demand, updated on save and delete.
    @ObservationIgnored var passwordSaved: [UUID: Bool] = [:]

    private static var states: [ObjectIdentifier: DatabaseConnectionsUI] = [:]

    static func shared(for model: AppModel) -> DatabaseConnectionsUI {
        let key = ObjectIdentifier(model)
        if let existing = states[key] { return existing }
        let created = DatabaseConnectionsUI()
        states[key] = created
        return created
    }
}

/// Saved database connections (#138): their definitions in `targets.json`, passwords in the
/// credential store (the Keychain), and which one an SQL tab uses. Nothing here connects or
/// runs anything, except Test Connection when the user presses it.
extension AppModel {
    var databaseUI: DatabaseConnectionsUI { DatabaseConnectionsUI.shared(for: self) }

    /// The Keychain; in Debug builds, memory for scratch data (`RUNLET_DATA_DIR`) unless
    /// `RUNLET_CREDENTIALS=keychain`, and always with `RUNLET_CREDENTIALS=memory`, so
    /// development runs and screenshots never touch the login keychain. A scratch data folder
    /// also gets its own Keychain service (`KeychainCredentialStore.service(for:)`).
    static func makeCredentialStore(paths: AppPaths) -> CredentialStore {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let scratch = !(environment["RUNLET_DATA_DIR"] ?? "").isEmpty
        switch environment["RUNLET_CREDENTIALS"] {
        case "memory":
            return InMemoryCredentialStore()
        case "keychain":
            break
        default:
            if scratch { return InMemoryCredentialStore() }
        }
        #endif
        return KeychainCredentialStore(service: KeychainCredentialStore.service(for: paths))
    }

    func databaseConnections(for target: TargetRef) -> [DatabaseConnection] {
        library.databaseConnections(for: target)
    }

    /// Connections of all targets (#142), offered in every SQL tab's picker.
    var allTargetsDatabaseConnections: [DatabaseConnection] {
        library.allTargetsDatabaseConnections
    }

    /// Whether the connection has a password in the store (without reading it, so no prompt).
    func hasSavedPassword(_ id: UUID) -> Bool {
        if let known = databaseUI.passwordSaved[id] { return known }
        let exists = credentials.exists(id)
        databaseUI.passwordSaved[id] = exists
        return exists
    }

    /// Saves the definition, then the password. A Keychain that refuses keeps the definition
    /// and says the password wasn't saved. Editing forgets the connection's schema.
    @discardableResult
    func saveDatabaseConnection(_ connection: DatabaseConnection, password: DatabasePasswordChange) -> DatabaseConnection {
        let saved = library.saveDatabaseConnection(connection)
        saveLibrary()
        switch password {
        case .keep:
            break
        case .replace(let secret):
            do {
                try credentials.set(secret, for: saved.id, label: "Runlet database: \(saved.name)")
            } catch {
                alert = AppAlert(title: "The password wasn't saved", message: "“\(saved.name)” was saved, but its password wasn't: \(error) Edit the connection to enter it again.")
            }
        case .remove:
            deleteStoredPassword(of: saved)
        }
        databaseUI.passwordSaved[saved.id] = nil
        forgetSQLSchema(target: saved.scope ?? .sandbox, ref: .saved(saved.id))
        cancelSQLTunnel(for: saved.id) // #143: the next run adds the forward it needs now
        for tab in allTabs where tab.sqlSavedConnection == saved.id && tab.sqlSavedConnectionName != saved.name {
            tab.sqlSavedConnectionName = saved.name
            scheduleSessionSave()
        }
        return saved
    }

    /// Deletes a saved connection and its password. SQL tabs that used it say it's missing.
    func removeDatabaseConnection(_ id: UUID) {
        guard let removed = library.removeDatabaseConnection(id) else { return }
        saveLibrary()
        deleteStoredPassword(of: removed)
        forgetSQLSchema(target: removed.scope ?? .sandbox, ref: .saved(id))
        cancelSQLTunnel(for: id) // #143
    }

    /// Asks, then deletes a saved connection. Returns whether it was deleted.
    @discardableResult
    func confirmRemoveDatabaseConnection(_ id: UUID) -> Bool {
        guard let connection = library.databaseConnection(id) else { return false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete the saved connection “\(connection.name)”?"
        alert.informativeText = "Runlet forgets its definition and deletes its password from the Keychain. The database itself is not touched. SQL tabs that use it\(connection.isAllTargets ? ", on any target," : "") will say it's missing."
        alert.addButton(withTitle: "Delete Connection")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        removeDatabaseConnection(id)
        return true
    }

    /// Duplicate: the same definition under a new name, without the password (the editor asks
    /// for it again).
    @discardableResult
    func duplicateDatabaseConnection(_ id: UUID) -> DatabaseConnection? {
        guard let original = library.databaseConnection(id) else { return nil }
        let copy = original.duplicated(named: uniqueConnectionName(original.name + " copy", on: original.scope))
        let saved = library.saveDatabaseConnection(copy)
        saveLibrary()
        return saved
    }

    /// A target is being removed: its connections go, with their passwords. The caller saves
    /// the library.
    func removeDatabaseConnections(for target: TargetRef) {
        for connection in library.removeDatabaseConnections(for: target) {
            deleteStoredPassword(of: connection)
        }
    }

    /// A duplicated target gets copies of the original's connections, without passwords.
    func copyDatabaseConnections(from source: TargetRef, to target: TargetRef) {
        let originals = library.databaseConnections(for: source)
        guard !originals.isEmpty, source != target else { return }
        for original in originals { library.saveDatabaseConnection(original.duplicated(named: original.name, scope: target)) }
        saveLibrary()
    }

    /// "…, and its 2 saved database connections, with their passwords" for removal alerts.
    func savedConnectionsNote(for target: TargetRef) -> String? {
        let count = library.databaseConnections(for: target).count
        guard count > 0 else { return nil }
        return count == 1
            ? "Its saved database connection is deleted too, with its password in the Keychain."
            : "Its \(count) saved database connections are deleted too, with their passwords in the Keychain."
    }

    private func uniqueConnectionName(_ base: String, on scope: TargetRef?) -> String {
        let taken = Set(library.databaseConnections(scope: scope).map { $0.name.lowercased() })
        var name = base
        var number = 2
        while taken.contains(name.lowercased()) {
            name = "\(base) \(number)"
            number += 1
        }
        return name
    }

    private func deleteStoredPassword(of connection: DatabaseConnection) {
        databaseUI.passwordSaved[connection.id] = nil
        do {
            try credentials.delete(connection.id)
        } catch {
            alert = AppAlert(title: "The password wasn't deleted", message: "\(error) Delete the item “Runlet database: \(connection.name)” in Keychain Access.")
        }
    }

    // MARK: Tabs

    /// The connection an SQL tab uses: a saved one (by id on its target, else by name), a
    /// missing saved one, or an application connection.
    /// #190: only a connection of the tab's family counts: a Redis connection an SQL tab names
    /// (or the other way round) is missing for it.
    func sqlConnectionChoice(for tab: TabModel) -> SQLConnectionChoice {
        if tab.sqlSavedConnection != nil || tab.sqlSavedConnectionName != nil {
            if let found = library.databaseConnection(id: tab.sqlSavedConnection, name: tab.sqlSavedConnectionName, on: tab.target, family: tab.language.connectionFamily ?? .sql) { return .saved(found) }
            return .missing(tab.sqlSavedConnectionName ?? "saved connection")
        }
        return .app(tab.sqlConnection)
    }

    /// The name a workspace keeps for the tab's saved connection.
    func savedConnectionName(for tab: TabModel) -> String? {
        switch sqlConnectionChoice(for: tab) {
        case .saved(let connection): connection.name
        case .missing(let name): name
        case .app: nil
        }
    }

    /// Switches an SQL tab to a saved connection. Nothing connects or runs.
    func setSQLSavedConnection(_ connection: DatabaseConnection, for tab: TabModel) {
        tab.sqlConnectionNote = nil
        guard tab.sqlSavedConnection != connection.id || tab.sqlSavedConnectionName != connection.name || tab.sqlConnection != nil else { return }
        tab.sqlSavedConnection = connection.id
        tab.sqlSavedConnectionName = connection.name
        tab.sqlConnection = nil
        window(containing: tab.id)?.markEdited()
        scheduleSessionSave()
        cancelUnusedSQLTunnels() // #143
    }

    // MARK: Editor

    /// A draft for New Connection… on `scope` (nil: all targets, #142): MySQL on 127.0.0.1
    /// with the default port. The sandbox has no connections of its own, so from a sandbox tab
    /// the new connection is one of all targets, opened from this Mac.
    /// #190: `family` picks the first driver: MySQL for SQL, Redis for a Redis tab.
    func newConnectionDraft(for scope: TargetRef?, useInTab: UUID? = nil, family: DatabaseFamily = .sql) -> DatabaseConnectionDraft {
        let scope = scope.flatMap { TargetLibrary.supportsDatabaseConnections($0) ? $0 : nil }
        let connection = DatabaseConnection(name: uniqueConnectionName("New Connection", on: scope), scope: scope, connectFrom: scope == nil ? .thisMac : .target, driver: DatabaseDriverKind.kinds(of: family).first ?? .mysql, host: "127.0.0.1")
        return DatabaseConnectionDraft(connection: connection, isNew: true, hasStoredPassword: false, useInTab: useInTab)
    }

    /// Edit… from an SQL tab on `target`: an all-targets connection can be moved to that target.
    func editConnectionDraft(_ connection: DatabaseConnection, from target: TargetRef) -> DatabaseConnectionDraft {
        DatabaseConnectionDraft(connection: connection, isNew: false, hasStoredPassword: hasSavedPassword(connection.id), homeTarget: target)
    }

    func editConnectionDraft(_ connection: DatabaseConnection) -> DatabaseConnectionDraft {
        DatabaseConnectionDraft(connection: connection, isNew: false, hasStoredPassword: hasSavedPassword(connection.id))
    }

    /// Save in the editor: the definition and the password change; a tab that asked for a new
    /// connection switches to it.
    func commitConnectionDraft(_ draft: DatabaseConnectionDraft) {
        let saved = saveDatabaseConnection(draft.connection, password: draft.passwordChange)
        draft.password = ""
        if let id = draft.useInTab, let tab = allTabs.first(where: { $0.id == id }), saved.isAvailable(on: tab.target), saved.driver.family == tab.language.connectionFamily {
            setSQLSavedConnection(saved, for: tab)
        }
    }

    /// Test Connection (#138): opens the connection on its target, or from this Mac (#142),
    /// and reports the server and where it was opened, or the error. It runs no user SQL and no
    /// project code, so production doesn't ask. Through an SSH tunnel (#143), a profile that
    /// isn't connected asks first, as a run does; the forward goes after the test unless an SQL
    /// tab uses the connection.
    func testDatabaseConnection(_ connection: DatabaseConnection, password: ExecutionEngine.SQLPassword) async throws -> SQLConnectionTestInfo {
        let connection = connection.normalized
        let snapshot: TargetSnapshot
        let place: String
        if connection.usesSSHTunnel {
            snapshot = try await tunnelSnapshot(for: connection, tab: nil)
            defer { releaseSQLTunnel(snapshot, cancelWhenUnused: sqlTunnelUnused(connection.id)) }
            var info = try await engine.testSQLConnection(target: snapshot, connection: connection, password: password)
            let route = snapshot.sqlTunnel
            info.openedFrom = thisMacLabel(for: connection) + " through SSH “\(route?.profileName ?? "")”" + (route.map { " (127.0.0.1:\($0.localPort) → \($0.remoteHost):\($0.remotePort))" } ?? "")
            return info
        } else if connection.opensOnThisMac || connection.scope == nil {
            snapshot = try await localConnectionSnapshot(for: connection)
            place = thisMacLabel(for: connection)
        } else {
            // Resolving the target (a Docker container, an SSH connection) works on a tab; this
            // one is never shown.
            let target = connection.scope ?? .sandbox
            snapshot = try await self.snapshot(for: TabModel(state: TabState(title: "Test Connection", target: target)))
            place = targetLabel(target)
        }
        var info = try await engine.testSQLConnection(target: snapshot, connection: connection, password: password)
        info.openedFrom = place
        return info
    }

    func runConnectionTest(_ draft: DatabaseConnectionDraft) {
        draft.testTask?.cancel()
        let connection = draft.connection.normalized
        let password = draft.testPassword
        draft.test = .testing
        draft.testTask = Task { [weak self, weak draft] in
            guard let self else { return }
            let state: DatabaseConnectionDraft.TestState
            do {
                state = .succeeded(try await self.testDatabaseConnection(connection, password: password))
            } catch is CancellationError {
                return
            } catch {
                state = .failed("\(error)")
            }
            guard !Task.isCancelled else { return }
            draft?.test = state
        }
    }
}
