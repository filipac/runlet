import AppKit
import Observation
import RunletCore
import RunletExecution

/// Database work outside a tab's own run (#180): a Load Next page, Load Schema, Show
/// Definition, or a read or action of the Database pane's Server section. Each opens a database
/// session in a fresh runner while it runs; the Connection Manager lists it, and Close stops it.
struct DatabaseWork: Identifiable {
    enum Purpose: Equatable {
        /// Load Next (#146): which rows.
        case loadNext(String)
        /// Load Schema (#128).
        case schema
        /// Show Definition (#148): the table or view.
        case definition(String)
        /// The Server section's read (#150).
        case serverRead
        /// Cancel Query or Kill Session (#150): "Kill Session 4711".
        case serverAction(String)
    }

    let id = UUID()
    var purpose: Purpose
    var tabId: UUID?
    var tabTitle: String
    var target: TargetRef
    var connection: SQLConnectionChoice
    /// The statement it runs (Load Next's), for its first line.
    var statement: String?
    var startedAt = Date()
    /// Stops it the way its own Stop or Done does.
    var stop: @MainActor () -> Void
}

/// A Close waiting for the user's answer.
struct PendingConnectionClose: Identifiable, Equatable {
    /// The connection's id.
    let id: String
    let confirmation: ActiveConnectionCloseConfirmation
}

/// The Connection Manager's state (#180), per app model: database work outside tabs' runs,
/// the rows whose Close is under way, and a Close waiting for an answer.
@MainActor
@Observable
final class ConnectionManagerStore {
    var databaseWork: [UUID: DatabaseWork] = [:]
    /// Rows whose Close (Disconnect, Stop) is under way.
    var closing: Set<String> = []
    var pendingClose: PendingConnectionClose?
    /// The window is open: its SSH rows look at the control sockets on this Mac again while it is.
    var isWindowOpen = false
    /// What the last Close did, for DEBUG steps.
    var lastEvent: String?

    private static var stores: [ObjectIdentifier: ConnectionManagerStore] = [:]

    static func shared(for model: AppModel) -> ConnectionManagerStore {
        let key = ObjectIdentifier(model)
        if let store = stores[key] { return store }
        let store = ConnectionManagerStore()
        stores[key] = store
        return store
    }
}

/// One source of Connection Manager rows (#180). A provider reads state Runlet already keeps
/// and closes its own rows; listing never connects, reads, or runs anything.
@MainActor
protocol ConnectionProvider {
    /// The id prefix of its rows (`ssh:`, `run:`, …).
    var prefix: String { get }
    func connections(in model: AppModel) -> [ActiveConnection]
    func close(_ id: String, in model: AppModel)
}

/// The Connection Manager (#180): one registry of everything Runlet has open, fed by providers
/// that observe existing state: SSH shared connections (control sockets on this Mac), SSH tunnels
/// (#143), database sessions of running SQL work, PHP runs, and AI clients over MCP. Close acts
/// through each subsystem's own path (Disconnect, Stop, the MCP server's drop), and never asks
/// the production question: ending something is always allowed.
extension AppModel {
    var connectionManager: ConnectionManagerStore { ConnectionManagerStore.shared(for: self) }

    /// The providers, in no particular order (the list sorts by kind).
    static let connectionProviders: [any ConnectionProvider] = [
        SSHConnectionProvider(),
        SSHTunnelConnectionProvider(),
        TabRunConnectionProvider(),
        DatabaseWorkConnectionProvider(),
        MCPClientConnectionProvider(),
    ]

    /// Everything open now. Reading it in a view observes every provider's state, so the status
    /// bar and the window update as things open and close.
    var activeConnections: ActiveConnectionList {
        let closing = connectionManager.closing
        let items = Self.connectionProviders.flatMap { $0.connections(in: self) }.map { item -> ActiveConnection in
            guard closing.contains(item.id) else { return item }
            var copy = item
            copy.isClosing = true
            return copy
        }
        return ActiveConnectionList(items)
    }

    // MARK: Window

    /// Window ▸ Connections, the status bar item, and Open Anything: the Connection Manager
    /// window (one; brought forward when open). The SSH rows look at the control sockets again.
    func showConnectionManager() {
        refreshSSHStatuses()
        openSingleWindowAction?(ConnectionManagerView.sceneId)
    }

    /// Reveal Tab: selects the tab in its window and brings that window forward.
    func revealTab(_ tabId: UUID) {
        guard let window = window(containing: tabId) else { return }
        window.selectedTabId = tabId
        activeWindowId = window.id
        #if DEBUG
        if DebugSteps.isGhosted { return }
        #endif
        window.nsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Close

    /// Close on a row: asks first when the list's rule says so (an SSH connection that carries
    /// work or needs a password or 2FA login again, a tunnel in use), else closes at once.
    func requestCloseConnection(_ id: String) {
        let list = activeConnections
        guard let item = list.item(id), !item.isClosing else { return }
        if let confirmation = list.closeConfirmation(for: id) {
            connectionManager.pendingClose = PendingConnectionClose(id: id, confirmation: confirmation)
            connectionManager.lastEvent = "asking: \(confirmation.title)"
        } else {
            closeConnection(id)
        }
    }

    func answerCloseConnection(_ confirmed: Bool) {
        guard let pending = connectionManager.pendingClose else { return }
        connectionManager.pendingClose = nil
        if confirmed {
            closeConnection(pending.id)
        } else {
            connectionManager.lastEvent = "kept: \(pending.id)"
        }
    }

    /// Closes `id` through its provider's own path, without asking.
    func closeConnection(_ id: String) {
        guard let provider = Self.connectionProviders.first(where: { id.hasPrefix($0.prefix) }) else { return }
        // Forget marks of rows that are gone (their ids never come back).
        let present = Set(activeConnections.items.map(\.id))
        connectionManager.closing.formIntersection(present)
        connectionManager.closing.insert(id)
        connectionManager.lastEvent = "closing: \(id)"
        provider.close(id, in: self)
    }

    // MARK: Database work

    /// Lists `work` until `task` ends (Load Next, Load Schema, Show Definition, Server reads and
    /// actions). It may open an SSH profile's shared connection, so that is looked at after.
    func trackDatabaseWork(_ work: DatabaseWork, until task: Task<Void, Never>) {
        let id = work.id
        connectionManager.databaseWork[id] = work
        Task { [weak self] in
            _ = await task.value
            guard let self else { return }
            self.connectionManager.databaseWork[id] = nil
            self.connectionManager.closing.remove("work:\(id)")
            if case .ssh(let profileId) = work.target { self.refreshSSHStatus(profileId) }
        }
    }

    /// "mysql · shop.internal:3306/shop · saved connection “Reporting” from this Mac", or
    /// "mysql · the default connection of acme": where SQL work goes, never a password.
    func databaseDestination(_ choice: SQLConnectionChoice, target: TargetRef, driver: String?) -> String {
        switch choice {
        case .saved(let saved):
            let place = saved.opensOnThisMac ? "from this Mac" : "on \(targetLabel(saved.scope ?? target))"
            return "\(saved.driver.rawValue) · \(saved.location) · saved connection “\(saved.name)” \(place)"
        case .app(let name):
            let connection = name.map { "the “\($0)” connection" } ?? "the default connection"
            return (driver.map { "\($0) · " } ?? "") + "\(connection) of \(targetLabel(target))"
        case .missing(let name):
            return "saved connection “\(name)”"
        }
    }

    /// The SSH profile a target's work goes through, as a row id (`ssh:<profile>`).
    func sshVia(_ target: TargetRef, choice: SQLConnectionChoice? = nil) -> [String] {
        if let saved = choice?.savedConnection, saved.opensOnThisMac { return [] }
        if case .ssh(let id) = target { return ["ssh:\(id)"] }
        return []
    }

    /// The environment marking of work on `target` (with a saved connection, the stricter one).
    func connectionEnvironment(_ target: TargetRef, choice: SQLConnectionChoice? = nil) -> TargetEnvironment {
        library.marking(for: target, connection: choice?.savedConnection).environment
    }
}

// MARK: - Providers

/// SSH profiles whose shared connection (control master) is up, from the control sockets on
/// this Mac. Close is the profile's Disconnect.
struct SSHConnectionProvider: ConnectionProvider {
    let prefix = "ssh:"

    func connections(in model: AppModel) -> [ActiveConnection] {
        model.library.sshProfiles.compactMap { profile in
            guard model.sshStatus(profile.id) == .connected else { return nil }
            let interactive = profile.authentication == .interactive
            let login = interactive
                ? "Password or 2FA login (Connect…); stays until you disconnect"
                : profile.keepAliveMinutes.map { "Agent or key login; closes after \($0) min unused, or when Runlet quits" } ?? "Agent or key login; closes when Runlet quits"
            var details = [login]
            if let jump = profile.jumpHost, !jump.isEmpty { details.append("Through \(jump)") }
            let tabs = model.allTabs.filter { $0.target == .ssh(profile.id) }
            let owner: String? = switch tabs.count {
            case 0: nil
            case 1: "Tab “\(tabs[0].title)”"
            default: "\(tabs.count) tabs"
            }
            return ActiveConnection(
                id: "ssh:\(profile.id)", kind: .ssh, title: profile.name, destination: profile.destinationLabel,
                owner: owner, ownerTabId: tabs.count == 1 ? tabs[0].id : nil,
                startedAt: SSHControlSocket.createdAt(SSHControlPaths.socketPath(for: profile.id, in: model.paths.ssh)),
                environment: profile.environment, details: details, needsLoginToReconnect: interactive
            )
        }
    }

    func close(_ id: String, in model: AppModel) {
        guard let profileId = UUID(uuidString: String(id.dropFirst(prefix.count))) else { return }
        // The Connection Manager asked already (its own rule covers runs and tunnels).
        model.disconnectSSH(profileId, confirmed: true)
    }
}

/// SSH tunnels for saved database connections (#143). The forward lifecycle lands with #143;
/// until then there is nothing to list.
// TODO(#180, #143): list #143's forwards (local port → host:port, the profile's master as
// `via`, statements using them as users) and close with the forward's cancel (`-O cancel`).
struct SSHTunnelConnectionProvider: ConnectionProvider {
    let prefix = "tunnel:"

    func connections(in model: AppModel) -> [ActiveConnection] { [] }

    func close(_ id: String, in model: AppModel) {}
}

/// Tabs' runs in progress: PHP runs on every target, and SQL tabs' statements, Run All, and
/// Explain as database sessions. Close is the tab's Stop (#144's server cancel included).
struct TabRunConnectionProvider: ConnectionProvider {
    let prefix = "run:"

    func connections(in model: AppModel) -> [ActiveConnection] {
        model.allTabs.compactMap { tab in
            guard tab.isRunning else { return nil }
            return connection(for: tab, in: model)
        }
    }

    /// `run:<run id>`, or `run:<tab id>-preparing` before the run has an id.
    static func id(for tab: TabModel) -> String {
        "run:" + (tab.runState.runId?.uuidString ?? "\(tab.id.uuidString)-preparing")
    }

    private func connection(for tab: TabModel, in model: AppModel) -> ActiveConnection {
        let request = tab.runState.runId != nil ? tab.currentRequest : nil
        let target = tab.inspectionTarget ?? tab.target
        let startedAt: Date? = switch tab.runState {
        case .running(_, let date), .stopping(_, let date): date
        default: nil
        }
        let owner = "Tab “\(tab.title)”"
        if tab.runsSQL, let run = tab.sqlRun {
            let choice: SQLConnectionChoice = run.saved.map { .saved($0) } ?? .app(run.connection)
            let first = ConnectionText.firstLine(of: run.statements.first?.text ?? "")
            var title = first
            if let explain = run.explain { title = "\(explain.title): \(first)" }
            if run.transaction != nil, run.statements.count > 1 { title = "\(run.statements.count) statements: \(first)" }
            var details: [String] = []
            if let session = tab.sqlSession { details.append("Database session \(session.id)") }
            if run.readOnly { details.append("Read-only") }
            if run.transaction == true, run.statements.count > 1 { details.append("In one transaction") }
            if request == nil { details.append("Preparing…") }
            let driver = tab.sqlSession?.driver ?? run.saved?.driver.rawValue ?? model.sqlSchemaState(target: target, connection: run.ref)?.schema?.driver
            return ActiveConnection(
                id: Self.id(for: tab), kind: .database, title: title,
                destination: model.databaseDestination(choice, target: target, driver: driver),
                owner: owner, ownerTabId: tab.id, startedAt: startedAt,
                environment: model.connectionEnvironment(target, choice: choice), details: details,
                via: model.sshVia(target, choice: choice), isClosing: tab.runState.isStopping
            )
        }
        var details: [String] = []
        if request?.profile != nil { details.append("Profile Run") }
        if request == nil { details.append("Preparing…") }
        if let client = model.mcp.connections.first(where: { $0.tabId == tab.id }) { details.append("Tab of \(client.displayName) (MCP)") }
        let title = request.map { ConnectionText.firstLine(of: $0.code) }.flatMap { $0.isEmpty ? nil : $0 } ?? tab.title
        return ActiveConnection(
            id: Self.id(for: tab), kind: .phpRun, title: title,
            destination: request?.target.label ?? model.targetLabel(target),
            owner: owner, ownerTabId: tab.id, startedAt: startedAt,
            environment: model.connectionEnvironment(target), details: details,
            via: model.sshVia(target), isClosing: tab.runState.isStopping
        )
    }

    func close(_ id: String, in model: AppModel) {
        guard let tab = model.allTabs.first(where: { Self.id(for: $0) == id }) else { return }
        model.stop(tab)
    }
}

/// Database work outside tabs' runs (`DatabaseWork`): Load Next, Load Schema, Show Definition,
/// and the Server section. Close stops it as its own Stop or Done does.
struct DatabaseWorkConnectionProvider: ConnectionProvider {
    let prefix = "work:"

    func connections(in model: AppModel) -> [ActiveConnection] {
        model.connectionManager.databaseWork.values.map { work in
            let title: String
            let feature: String
            switch work.purpose {
            case .loadNext(let rows):
                title = "Load Next: \(rows)"
                feature = "Load Next"
            case .schema:
                title = "Load Schema"
                feature = "Load Schema"
            case .definition(let table):
                title = "Show Definition: \(table)"
                feature = "Show Definition"
            case .serverRead:
                title = "Read the server's details"
                feature = "Database pane · Server"
            case .serverAction(let action):
                title = action
                feature = "Database pane · Server"
            }
            var details: [String] = []
            if let statement = work.statement { details.append(ConnectionText.firstLine(of: statement)) }
            let tabExists = work.tabId.map { model.window(containing: $0) != nil } ?? false
            return ActiveConnection(
                id: "work:\(work.id)", kind: .database, title: title,
                destination: model.databaseDestination(work.connection, target: work.target, driver: work.connection.savedConnection?.driver.rawValue),
                owner: "Tab “\(work.tabTitle)” · \(feature)", ownerTabId: tabExists ? work.tabId : nil, startedAt: work.startedAt,
                environment: model.connectionEnvironment(work.target, choice: work.connection), details: details,
                via: model.sshVia(work.target, choice: work.connection)
            )
        }
    }

    func close(_ id: String, in model: AppModel) {
        guard let uuid = UUID(uuidString: String(id.dropFirst(prefix.count))), let work = model.connectionManager.databaseWork[uuid] else { return }
        work.stop()
    }
}

/// AI clients connected to Runlet's MCP server (#43). Close drops that client's connection;
/// the server keeps listening, so the client's next call connects again.
struct MCPClientConnectionProvider: ConnectionProvider {
    let prefix = "mcp:"

    func connections(in model: AppModel) -> [ActiveConnection] {
        model.mcp.connections.map { connection in
            var details = ["\(connection.callCount) call\(connection.callCount == 1 ? "" : "s")"]
            if let version = connection.client?.version { details.append("Version \(version)") }
            if let pid = connection.helperPID { details.append("runlet mcp, process \(pid)") }
            if connection.sandboxAllowed { details.append("Sandbox runs allowed for this session") }
            let tab = connection.tabId.flatMap { id in model.allTabs.first { $0.id == id } }
            return ActiveConnection(
                id: "mcp:\(connection.id)", kind: .aiClient, title: connection.displayName,
                destination: "Runlet's MCP server on this Mac",
                owner: tab.map { "Runs in tab “\($0.title)”" }, ownerTabId: tab?.id, startedAt: connection.connectedAt,
                details: details
            )
        }
    }

    func close(_ id: String, in model: AppModel) {
        guard let uuid = UUID(uuidString: String(id.dropFirst(prefix.count))) else { return }
        model.disconnectMCPClient(uuid)
    }
}
