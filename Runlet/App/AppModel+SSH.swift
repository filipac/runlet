import AppKit
import Observation
import RunletCore
import RunletExecution

/// SSH connection state per profile. Status comes from the profile's control socket on this
/// Mac (`SSHControlSocket`), so checking it never starts `ssh` or contacts a server.
@MainActor
@Observable
final class SSHConnectionStore {
    var statuses: [UUID: SSHConnectionStatus] = [:]
    /// Connect… terminal tabs in progress: request id → profile id.
    var connectRequests: [UUID: UUID] = [:]
    /// The last Test Connection result per profile, for this session.
    var probes: [UUID: SSHProbe] = [:]
    /// Profiles whose Test Connection is running.
    var probing: Set<UUID> = []
    /// A drift warning per profile (the local folder's checkout differs from the server's),
    /// when the profile's drift check is on.
    var drift: [UUID: String] = [:]

    private static var stores: [ObjectIdentifier: SSHConnectionStore] = [:]

    static func shared(for model: AppModel) -> SSHConnectionStore {
        let key = ObjectIdentifier(model)
        if let store = stores[key] { return store }
        let store = SSHConnectionStore()
        stores[key] = store
        return store
    }
}

extension AppModel {
    var sshConnections: SSHConnectionStore { SSHConnectionStore.shared(for: self) }

    /// The system OpenSSH client with the app's environment (agents through `SSH_AUTH_SOCK`
    /// and `~/.ssh/config`'s `IdentityAgent`).
    var sshClient: SSHClient { Self.makeSSHClient() }

    /// Debug builds: `RUNLET_SSH_CONFIG` replaces `~/.ssh/config` (passed as `ssh -F`) for
    /// screenshots and checks that must not read the developer's own SSH setup.
    nonisolated static var debugSSHConfig: String? {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["RUNLET_SSH_CONFIG"], !path.isEmpty { return path }
        #endif
        return nil
    }

    nonisolated static func makeSSHClient() -> SSHClient {
        SSHClient(configFile: debugSSHConfig)
    }

    /// The config file whose `Host` aliases the profile form offers.
    var sshConfigFile: URL {
        Self.debugSSHConfig.map { URL(fileURLWithPath: $0) } ?? SSHConfigHosts.userConfig
    }

    /// How runs, Stop, probes, and Connect… reach `profile`'s host.
    func sshEndpoint(for profile: SSHProfile) -> SSHEndpoint {
        SSHEndpoint(
            host: profile.host,
            user: profile.user,
            port: profile.port,
            jumpHost: profile.jumpHost,
            controlPath: SSHControlPaths.socketPath(for: profile.id, in: paths.ssh),
            authentication: profile.authentication,
            keepAliveMinutes: profile.keepAliveMinutes,
            compression: profile.compression
        )
    }

    // MARK: Profiles

    func saveSSHProfile(_ profile: SSHProfile) {
        let key = TargetRef.ssh(profile.id).stableKey
        resetFactsDetection(for: key)
        var updated = profile
        if let index = library.sshProfiles.firstIndex(where: { $0.id == profile.id }) {
            updated.revision = library.sshProfiles[index].revision + 1
            library.sshProfiles[index] = updated
        } else {
            library.sshProfiles.append(updated)
        }
        saveLibrary()
        for tab in allTabs where tab.target == .ssh(profile.id) { bindLanguage(tab) }
    }

    /// Removes the profile from Runlet (after closing its shared connection, if any). Tabs
    /// using it switch to the sandbox; nothing on the server is touched.
    func removeSSHProfile(_ id: UUID) {
        if let profile = library.sshProfile(id) {
            let endpoint = sshEndpoint(for: profile)
            let client = sshClient
            Task { await client.disconnect(endpoint) }
        }
        library.sshProfiles.removeAll { $0.id == id }
        saveLibrary()
        sshConnections.statuses[id] = nil
        sshConnections.probes[id] = nil
        for tab in allTabs where tab.target == .ssh(id) { setTarget(.sandbox, for: tab) }
    }

    func touchSSHProfile(_ id: UUID) {
        guard let index = library.sshProfiles.firstIndex(where: { $0.id == id }) else { return }
        library.sshProfiles[index].lastOpenedAt = Date()
        saveLibrary()
        refreshSSHStatus(id)
    }

    // MARK: Connection status

    /// The last known status (call `refreshSSHStatus` to check again).
    func sshStatus(_ profileId: UUID) -> SSHConnectionStatus {
        sshConnections.statuses[profileId] ?? .disconnected
    }

    /// Checks the profile's control socket on this Mac. Never contacts the server.
    @discardableResult
    func refreshSSHStatus(_ profileId: UUID) -> SSHConnectionStatus {
        guard let profile = library.sshProfile(profileId) else { return .disconnected }
        let status = SSHControlSocket.status(at: sshEndpoint(for: profile).controlPath)
        if sshConnections.statuses[profileId] != status { sshConnections.statuses[profileId] = status }
        return status
    }

    func refreshSSHStatuses() {
        for profile in library.sshProfiles { refreshSSHStatus(profile.id) }
    }

    /// Whether a Connect… login for the profile is still open in a terminal tab.
    func isConnectingSSH(_ profileId: UUID) -> Bool {
        let pending = sshConnections.connectRequests.filter { $0.value == profileId }.keys
        guard !pending.isEmpty else { return false }
        return windows.contains { window in
            window.terminals.sessions.contains { session in
                guard pending.contains(session.request.id) else { return false }
                if case .exited = session.state { return false }
                return true
            }
        }
    }

    // MARK: Connect and Disconnect

    /// Connect…: opens a terminal tab running `ssh -M -N -f` for the profile. OpenSSH asks
    /// for the password, one-time code, key passphrase, or an unknown host key's confirmation
    /// itself; Runlet never sees what is typed. Once logged in, ssh goes to the background
    /// (the tab closes) and runs reuse that connection until Disconnect, including after
    /// Runlet restarts.
    func connectSSH(_ profileId: UUID, in window: WindowModel? = nil) {
        guard let profile = library.sshProfile(profileId) else { return }
        guard profile.validate().isEmpty else {
            alert = AppAlert(title: "Can't connect to “\(profile.name)”", message: profile.validate().map(\.description).joined(separator: "\n"))
            return
        }
        if refreshSSHStatus(profileId) == .connected { return }
        do {
            let argv = try sshClient.connectCommand(sshEndpoint(for: profile))
            let request = TerminalRequest(title: "Connect \(profile.name)", executable: argv, isCommand: false)
            sshConnections.connectRequests[request.id] = profileId
            if let openTerminal, window == nil {
                openTerminal(request)
            } else {
                self.openTerminal(request, in: window)
            }
        } catch {
            alert = AppAlert(title: "Can't connect to “\(profile.name)”", message: "Runlet could not prepare its SSH folder: \(error.localizedDescription)")
        }
    }

    /// Disconnect: closes the shared connection (`ssh -O exit`). Asks first when runs on the
    /// profile are in progress, since they end with it.
    func disconnectSSH(_ profileId: UUID) {
        guard let profile = library.sshProfile(profileId) else { return }
        let running = allTabs.filter { $0.target == .ssh(profileId) && $0.isRunning }.count
        if running > 0 {
            let alert = NSAlert()
            alert.messageText = "Disconnect from “\(profile.name)”?"
            alert.informativeText = running == 1 ? "A run on this host is in progress; it ends with the connection." : "\(running) runs on this host are in progress; they end with the connection."
            alert.addButton(withTitle: "Disconnect")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let endpoint = sshEndpoint(for: profile)
        let client = sshClient
        Task {
            await client.disconnect(endpoint)
            refreshSSHStatus(profileId)
        }
    }

    /// Called when a terminal tab's process exits: finishes a Connect… login.
    func sshTerminalExited(_ request: TerminalRequest, code: Int32?) {
        guard let profileId = sshConnections.connectRequests.removeValue(forKey: request.id) else { return }
        let status = refreshSSHStatus(profileId)
        if status == .connected, code == 0 {
            for tab in allTabs where tab.target == .ssh(profileId) { tab.targetIssue = nil }
        }
    }

    // MARK: Runs

    /// The run snapshot for an SSH profile. Interactive profiles must be connected (checked
    /// locally); automatic ones connect on the run itself, in BatchMode.
    func sshSnapshot(for tab: TabModel, profileId: UUID) throws -> TargetSnapshot {
        guard let profile = library.sshProfile(profileId) else {
            throw TargetResolutionError(description: "This tab's SSH profile was removed. Choose another target.")
        }
        let problems = profile.validate()
        guard problems.isEmpty else {
            throw TargetResolutionError(description: "The SSH profile “\(profile.name)” needs fixing: " + problems.map(\.description).joined(separator: " "))
        }
        if profile.authentication == .interactive {
            switch refreshSSHStatus(profileId) {
            case .connected:
                break
            case .expired:
                throw TargetResolutionError(description: "The login to \(profile.destinationLabel) has ended. Use Connect… to log in again.")
            case .disconnected:
                throw TargetResolutionError(description: "Not connected to \(profile.destinationLabel). Use Connect… to log in; runs reuse that login until you disconnect.")
            }
        }
        tab.targetIssue = nil
        return TargetSnapshot(kind: .ssh, label: "\(profile.name) · \(profile.destinationLabel)", targetId: profile.id.uuidString, profileRevision: profile.revision, workingDirectory: profile.remoteDirectory, phpExecutable: profile.phpExecutable, ssh: sshEndpoint(for: profile))
    }

    // MARK: Test Connection

    /// Test Connection: reads PHP, the directory, and the server's layout with one `php -r`
    /// that only reads files. Explicit only (button in the profile form).
    func testSSHConnection(_ profile: SSHProfile) async -> SSHProbe {
        let id = profile.id
        sshConnections.probing.insert(id)
        defer { sshConnections.probing.remove(id) }
        let endpoint = sshEndpoint(for: profile)
        let client = sshClient
        if profile.authentication == .interactive, client.status(endpoint) != .connected {
            let probe = SSHProbe(error: "Not connected. Use Connect… to log in first; the test then reuses that login.")
            sshConnections.probes[id] = probe
            return probe
        }
        let probe = await client.probe(endpoint, phpExecutable: profile.phpExecutable, directory: profile.remoteDirectory)
        sshConnections.probes[id] = probe
        refreshSSHStatus(id)
        if probe.error == nil, library.sshProfile(id) != nil {
            noteProbeFacts(probe, for: profile)
        }
        return probe
    }

    /// Records what Test Connection learned (PHP version, and the framework when the profile
    /// has no local folder to read it from).
    private func noteProbeFacts(_ probe: SSHProbe, for profile: SSHProfile) {
        let key = TargetRef.ssh(profile.id).stableKey
        var facts = targetFacts[key] ?? TargetFacts()
        if let version = probe.phpVersion { facts.phpVersion = version }
        if facts.fromRun != true, library.localFolder(for: .ssh(profile.id)) == nil {
            facts.framework = probe.framework.hasPrefix("custom:") ? "custom:" + (probe.framework.dropFirst(7).split(separator: ",").first.map(String.init) ?? "") : probe.framework
        }
        if targetFacts[key] != facts { targetFacts[key] = facts }
    }
}
