import AppKit
import os
import RunletCore
import RunletExecution

/// Saved connections through an SSH profile's tunnel (#143): this Mac's PHP opens them, as
/// #142 does, against a local forward that Runlet adds on the profile's shared connection
/// (`ssh -S <control path> -O forward -L 127.0.0.1:<free port>:<host>:<port>`).
///
/// - A profile that isn't connected is never connected silently: the run, Load Schema, Show
///   Definition, Load Next, or Test Connection asks first. Agent and key profiles then connect
///   as their runs would; password and 2FA profiles open Connect… in a terminal, and that login
///   stays until Disconnect.
/// - Every run holds the forward while it runs (`SSHTunnelManager` leases); it is reused while
///   in use, cancelled after `SSHTunnelManager.defaultIdleTimeout` unused, when no SQL tab uses
///   the connection any more, when the connection changes, on Disconnect, and on quit.
/// - The password still reaches only the local PHP, on stdin; the forward's `-L` holds only a
///   host and ports. Adds, reuses, and cancels go to the Run Log (and the unified log).
@MainActor
final class SQLTunnelStore {
    let manager: SSHTunnelManager
    /// Leases of runs in progress, by token (`SQLTunnelRoute.lease`).
    var leases: [UUID: SSHTunnelManager.Lease] = [:]
    /// Tabs whose runs used a connection's forward, for the Run Log line when it is cancelled.
    var tabs: [UUID: Set<UUID>] = [:]

    static let log = Logger(subsystem: "dev.runlet.Runlet", category: "ssh-tunnel")

    private static var stores: [ObjectIdentifier: SQLTunnelStore] = [:]

    init(manager: SSHTunnelManager) {
        self.manager = manager
    }

    static func shared(for model: AppModel) -> SQLTunnelStore {
        let key = ObjectIdentifier(model)
        if let store = stores[key] { return store }
        let manager = SSHTunnelManager(forwarder: AppModel.makeSSHClient(), idleTimeout: AppModel.sqlTunnelIdleTimeout)
        let store = SQLTunnelStore(manager: manager)
        stores[key] = store
        Task { [weak model] in
            await manager.setObserver { event in
                Task { @MainActor in model?.sqlTunnelEvent(event) }
            }
        }
        return store
    }
}

extension AppModel {
    var sqlTunnels: SQLTunnelStore { SQLTunnelStore.shared(for: self) }

    /// How long an unused forward stays (5 minutes). Debug builds: `RUNLET_SQL_TUNNEL_IDLE`
    /// seconds, for checks.
    nonisolated static var sqlTunnelIdleTimeout: Duration {
        #if DEBUG
        if let text = ProcessInfo.processInfo.environment["RUNLET_SQL_TUNNEL_IDLE"], let seconds = Double(text), seconds > 0 { return .milliseconds(Int(seconds * 1000)) }
        #endif
        return SSHTunnelManager.defaultIdleTimeout
    }

    /// " from this Mac", " from this Mac through SSH “bastion”", or "" (the target's PHP), for
    /// confirmations and previews.
    func savedConnectionPlace(_ connection: DatabaseConnection) -> String {
        guard connection.opensOnThisMac else { return "" }
        guard connection.usesSSHTunnel else { return " from this Mac" }
        return " from this Mac through SSH “\(library.tunnelProfile(of: connection)?.name ?? "a removed profile")”"
    }

    /// " · from this Mac", " · through bastion", " · SSH profile missing" (#143), or "", for
    /// pickers and lists. `inList`: a list of all-targets connections leaves "from this Mac" out.
    func savedConnectionPlaceDetail(_ connection: DatabaseConnection, inList: Bool = false) -> String {
        if connection.usesSSHTunnel {
            return library.tunnelProfile(of: connection).map { " · through \($0.name)" } ?? " · SSH profile missing"
        }
        guard connection.opensOnThisMac, !(inList && connection.isAllTargets) else { return "" }
        return " · from this Mac"
    }

    /// The snapshot of a run on `connection` through its SSH tunnel: asks to connect the profile
    /// when needed, holds the connection's forward (`releaseSQLTunnel` ends the hold), and runs
    /// this Mac's PHP against it. `tab` gets the Run Log line when the forward is cancelled.
    func tunnelSnapshot(for connection: DatabaseConnection, tab: TabModel?) async throws -> TargetSnapshot {
        if let problem = library.tunnelProblem(of: connection) { throw TargetResolutionError(description: problem) }
        guard let profile = library.tunnelProfile(of: connection) else { throw TargetResolutionError(description: "The saved connection “\(connection.name)” has no SSH profile for its tunnel.") }
        let problems = profile.validate().filter(SSHProfile.ValidationError.connectionErrors.contains)
        guard problems.isEmpty else {
            throw TargetResolutionError(description: "The SSH profile “\(profile.name)”, which carries the tunnel of “\(connection.name)”, needs fixing: " + problems.map(\.description).joined(separator: " "))
        }
        // No PHP on this Mac: nothing to forward for.
        let local = try await localConnectionSnapshot(for: connection)
        try await ensureTunnelConnected(profile, for: connection, window: tab.flatMap { window(containing: $0.id) })
        let endpoint = sshEndpoint(for: profile)
        let lease: SSHTunnelManager.Lease
        do {
            lease = try await sqlTunnels.manager.acquire(key: connection.id, endpoint: endpoint, remoteHost: connection.host, remotePort: connection.effectivePort ?? 0)
        } catch {
            refreshSSHStatus(profile.id)
            if case SSHTunnelError.notConnected = error {
                throw TargetResolutionError(description: "The SSH connection to \(profile.destinationLabel) ended before the tunnel was added, so nothing ran. Run again to connect.")
            }
            throw TargetResolutionError(description: "\(error)")
        }
        sqlTunnels.leases[lease.token] = lease
        if let tab { sqlTunnels.tabs[connection.id, default: []].insert(tab.id) }
        let route = SQLTunnelRoute(localPort: lease.spec.localPort, remoteHost: connection.host, remotePort: connection.effectivePort ?? 0,
                                   profileId: profile.id, profileName: profile.name, forwardCommand: lease.commandLine, reused: lease.reused, lease: lease.token)
        var snapshot = local
        snapshot.label += " through \(profile.name)"
        snapshot.sqlTunnel = route
        return snapshot
    }

    /// Ends a run's hold on its forward (no-op without a tunnel). The last hold starts the idle
    /// time, or (`cancelWhenUnused`, Test Connection of a connection no tab uses) removes it.
    func releaseSQLTunnel(_ snapshot: TargetSnapshot, cancelWhenUnused: Bool = false) {
        guard let token = snapshot.sqlTunnel?.lease, let lease = sqlTunnels.leases.removeValue(forKey: token) else { return }
        let manager = sqlTunnels.manager
        Task { await manager.release(lease, cancelWhenUnused: cancelWhenUnused) }
    }

    /// Asks before a tunnel connects its SSH profile. Agent and key profiles then connect the
    /// way their runs do (BatchMode); password and 2FA profiles open Connect… in a terminal, and
    /// the run ends so it can be run again once logged in.
    func ensureTunnelConnected(_ profile: SSHProfile, for connection: DatabaseConnection, window: WindowModel?) async throws {
        let status = refreshSSHStatus(profile.id)
        guard status != .connected else { return }
        let interactive = profile.authentication == .interactive
        let alert = NSAlert()
        alert.messageText = "Connect to “\(profile.name)” for the SSH tunnel?"
        alert.informativeText = "The saved connection “\(connection.name)” reaches \(connection.location) through an SSH tunnel on \(profile.destinationLabel), which \(status == .expired ? "isn't connected any more (its login ended)" : "isn't connected"). Runlet connects only when you say so. "
            + (interactive
                ? "Connect… opens a terminal where OpenSSH asks for the password or code; run again once you're logged in. The login stays until you disconnect."
                : "Runlet logs in with your SSH agent or keys, as a run on that profile would.")
        alert.addButton(withTitle: interactive ? "Connect…" : "Connect")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            throw TargetResolutionError(description: "Not connected to \(profile.destinationLabel), so nothing ran. The saved connection “\(connection.name)” goes through that SSH profile's tunnel, and Runlet connects only when you say so.")
        }
        if interactive {
            connectSSH(profile.id, in: window)
            throw TargetResolutionError(description: "Log in to \(profile.destinationLabel) in the terminal, then run again. Runlet reuses that login for the tunnel until you disconnect.")
        }
        let endpoint = sshEndpoint(for: profile)
        SSHControlSocket.removeIfStale(at: endpoint.controlPath)
        do {
            try await sshClient.openSharedConnection(endpoint)
        } catch {
            refreshSSHStatus(profile.id)
            throw TargetResolutionError(description: "Runlet couldn't connect to \(profile.destinationLabel) for the tunnel of “\(connection.name)”, so nothing ran. \(error)")
        }
        refreshSSHStatus(profile.id)
    }

    /// The connections open SQL tabs use through a tunnel.
    private var tunnelledConnectionsInUse: Set<UUID> {
        Set(allTabs.compactMap { tab -> UUID? in
            guard tab.language == .sql, case .saved(let connection) = sqlConnectionChoice(for: tab), connection.usesSSHTunnel else { return nil }
            return connection.id
        })
    }

    /// A tab closed or switched connections: forwards no open SQL tab uses go once their runs end.
    func cancelUnusedSQLTunnels() {
        let used = tunnelledConnectionsInUse
        let manager = sqlTunnels.manager
        Task {
            for forward in await manager.forwards where !used.contains(forward.key) {
                await manager.cancel(key: forward.key, reason: .tabClosed)
            }
        }
    }

    /// The connection was edited or removed: its forward goes once its runs end.
    func cancelSQLTunnel(for connectionId: UUID) {
        let manager = sqlTunnels.manager
        Task { await manager.cancel(key: connectionId, reason: .edited) }
    }

    /// Whether `tab`'s saved connection goes through `profileId`'s tunnel.
    func usesSQLTunnel(of profileId: UUID, _ tab: TabModel) -> Bool {
        guard tab.language == .sql, case .saved(let connection) = sqlConnectionChoice(for: tab) else { return false }
        return connection.usesSSHTunnel && connection.sshProfile == profileId
    }

    /// Whether Test Connection's forward should go right after the test (no SQL tab uses it).
    func sqlTunnelUnused(_ connectionId: UUID) -> Bool {
        !tunnelledConnectionsInUse.contains(connectionId)
    }

    /// Disconnect or removal of an SSH profile: its forwards go first (runs on it end with
    /// the connection anyway).
    func cancelSQLTunnels(on endpoint: SSHEndpoint) async {
        await sqlTunnels.manager.cancelAll(controlPath: endpoint.controlPath, reason: .disconnected)
    }

    /// Quit: every forward goes, also on password and 2FA logins, which stay connected.
    func cancelAllSQLTunnels() async {
        await sqlTunnels.manager.cancelAll(reason: .quit)
    }

    /// The manager's report: the unified log, and the Run Log of tabs that used the forward.
    func sqlTunnelEvent(_ event: SSHTunnelManager.Event) {
        switch event {
        case .added(_, let spec, _, let commandLine):
            SQLTunnelStore.log.info("Added SSH tunnel \(spec.argument, privacy: .public): \(commandLine, privacy: .public)")
        case .reused(_, let spec, _):
            SQLTunnelStore.log.debug("Reused SSH tunnel \(spec.argument, privacy: .public)")
        case .cancelled(let key, let spec, _, let reason, let confirmed, let commandLine):
            SQLTunnelStore.log.info("Cancelled SSH tunnel \(spec.argument, privacy: .public) (\(reason.rawValue, privacy: .public), confirmed: \(confirmed))")
            let detail = "Removed the SSH tunnel 127.0.0.1:\(spec.localPort) → \(spec.remoteHost):\(spec.remotePort) because \(reason.phrase)" + (confirmed ? "." : "; it was already gone.")
            logTunnelInTabs(key: key, message: commandLine, detail: detail)
        case .dropped(let key, let spec, _):
            SQLTunnelStore.log.info("Forgot SSH tunnel \(spec.argument, privacy: .public): its connection ended")
            logTunnelInTabs(key: key, message: "SSH tunnel 127.0.0.1:\(spec.localPort) → \(spec.remoteHost):\(spec.remotePort) ended", detail: "Its SSH connection ended; the next run adds it again.")
        }
    }

    private func logTunnelInTabs(key: UUID, message: String, detail: String) {
        guard let ids = sqlTunnels.tabs.removeValue(forKey: key) else { return }
        for tab in allTabs where ids.contains(tab.id) && !tab.isRunning {
            tab.appendRunLog(source: "tunnel", message: message, detail: detail)
        }
    }

    #if DEBUG
    /// Debug state: the forwards and the leases of runs in progress.
    func sqlTunnelState() async -> String {
        let forwards = await sqlTunnels.manager.forwards
        let lines = forwards.map { "\($0.spec.argument) leases=\($0.leases)\($0.idle ? " idle" : "")\($0.cancelWhenUnused ? " cancel-when-unused" : "")" }
        return "tunnels: " + (lines.isEmpty ? "none" : lines.joined(separator: "; "))
    }
    #endif
}
