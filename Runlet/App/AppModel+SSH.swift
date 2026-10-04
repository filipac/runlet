import AppKit
import Observation
import RunletCore
import RunletExecution

/// What Test Connection found for an SSH profile's container step: the container it resolved
/// to and a read-only probe inside it, or why it couldn't (not running, several match, Docker
/// missing or not allowed on the server).
struct RemoteContainerCheck: Equatable {
    var container: ContainerInfo?
    var probe: ContainerProbe?
    var problem: String?
}

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
    /// Drift warnings the user closed (until the next check finds a difference again).
    var dismissedDrift: Set<UUID> = []
    /// Profiles whose drift was checked after a run this session.
    var driftCheckedAfterRun: Set<UUID> = []
    /// Local folders that look like a profile's project (for profiles without one).
    var folderSuggestions: [UUID: [LocalFolderSuggestions.Suggestion]] = [:]
    /// Profiles whose folder suggestions were looked up this session.
    var suggestionsLookedUp: Set<UUID> = []
    /// Test Connection's check of a profile's container step, for this session.
    var containerChecks: [UUID: RemoteContainerCheck] = [:]
    /// Profile sheets that stepped aside for a Connect… login (profile id → the sheet's
    /// values, saved or not); they reopen once that login succeeds.
    var draftsAwaitingLogin: [UUID: SSHProfile] = [:]
    /// A profile sheet to reopen now (the active window shows it).
    var resumeDraft: SSHProfile?

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

    /// Debug builds: `RUNLET_SSH_EXECUTABLE` replaces `/usr/bin/ssh`, e.g. with
    /// `Tests/Fixtures/fake-ssh/ssh` for screenshot tours that must never reach a server.
    nonisolated static var debugSSHExecutable: String? {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["RUNLET_SSH_EXECUTABLE"], !path.isEmpty { return path }
        #endif
        return nil
    }

    nonisolated static func makeSSHClient() -> SSHClient {
        SSHClient(executable: debugSSHExecutable ?? SSHClient.systemExecutable, configFile: debugSSHConfig)
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
            identityFile: profile.identityFile,
            controlPath: SSHControlPaths.socketPath(for: profile.id, in: paths.ssh),
            authentication: profile.authentication,
            keepAliveMinutes: profile.keepAliveMinutes,
            compression: profile.compression,
            keepCompiledPHP: profile.keepCompiledPHP && profile.container == nil ? true : nil
        )
    }

    // MARK: Profiles

    func saveSSHProfile(_ profile: SSHProfile) {
        let key = TargetRef.ssh(profile.id).stableKey
        resetFactsDetection(for: key)
        targetEdited(.ssh(profile.id))
        var updated = profile
        if let index = library.sshProfiles.firstIndex(where: { $0.id == profile.id }) {
            updated.revision = library.sshProfiles[index].revision + 1
            library.sshProfiles[index] = updated
        } else {
            library.sshProfiles.append(updated)
        }
        saveLibrary()
        if updated.localSourcePath != nil { sshConnections.folderSuggestions[profile.id] = nil }
        if !updated.checkDrift || updated.localSourcePath == nil { sshConnections.drift[profile.id] = nil }
        for tab in allTabs where tab.target == .ssh(profile.id) { bindLanguage(tab) }
    }

    /// Removes the profile from Runlet (after closing its shared connection, if any). Tabs
    /// using it switch to the sandbox; nothing on the server is touched.
    func removeSSHProfile(_ id: UUID) {
        if let profile = library.sshProfile(id) {
            let endpoint = sshEndpoint(for: profile)
            let client = sshClient
            Task {
                await cancelSQLTunnels(on: endpoint) // #143
                await client.disconnect(endpoint)
            }
        }
        library.sshProfiles.removeAll { $0.id == id }
        removeDatabaseConnections(for: .ssh(id))
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

    /// Checks the profile's control socket on this Mac (also for a profile not saved yet: the
    /// socket depends only on its id). Never contacts the server.
    @discardableResult
    func refreshSSHStatus(_ profileId: UUID) -> SSHConnectionStatus {
        let status = SSHControlSocket.status(at: SSHControlPaths.socketPath(for: profileId, in: paths.ssh))
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

    /// The SSH profile of the active window's selected tab, if it targets one.
    var selectedSSHProfileId: UUID? {
        if case .ssh(let id) = selectedTab?.target, library.sshProfile(id) != nil { return id }
        return nil
    }

    /// Connect…: opens a terminal tab running `ssh -M -N -f` for the profile. OpenSSH asks
    /// for the password, one-time code, key passphrase, or an unknown host key's confirmation
    /// itself; Runlet never sees what is typed. Once logged in, ssh goes to the background
    /// (the tab closes) and runs reuse that connection until Disconnect, including after
    /// Runlet restarts.
    func connectSSH(_ profileId: UUID, in window: WindowModel? = nil) {
        guard let profile = library.sshProfile(profileId) else { return }
        connectSSH(profile: profile, in: window)
    }

    /// Connect… for `profile`'s current values, which need not be saved (or complete) yet:
    /// only the host and its overrides matter for logging in. With `resumingSheet`, the
    /// profile sheet that stepped aside for the login reopens with these values once it
    /// succeeds.
    func connectSSH(profile: SSHProfile, in window: WindowModel? = nil, resumingSheet: Bool = false) {
        let problems = profile.validate().filter(SSHProfile.ValidationError.connectionErrors.contains)
        let name = profile.name.isEmpty ? profile.host : profile.name
        guard problems.isEmpty else {
            alert = AppAlert(title: "Can't connect to “\(name)”", message: problems.map(\.description).joined(separator: "\n"))
            return
        }
        if resumingSheet { sshConnections.draftsAwaitingLogin[profile.id] = profile }
        if refreshSSHStatus(profile.id) == .connected {
            resumeSheetAfterLogin(profile.id)
            return
        }
        do {
            let argv = try sshClient.connectCommand(sshEndpoint(for: profile))
            let request = TerminalRequest(title: "Connect \(name)", executable: argv, isCommand: false)
            sshConnections.connectRequests[request.id] = profile.id
            if let openTerminal, window == nil {
                openTerminal(request)
            } else {
                self.openTerminal(request, in: window)
            }
        } catch {
            alert = AppAlert(title: "Can't connect to “\(name)”", message: "Runlet could not prepare its SSH folder: \(error.localizedDescription)")
        }
    }

    /// Reopens a profile sheet that stepped aside for a login (see `connectSSH(profile:)`).
    private func resumeSheetAfterLogin(_ profileId: UUID) {
        guard let draft = sshConnections.draftsAwaitingLogin.removeValue(forKey: profileId) else { return }
        // Saved meanwhile (or before the login): show the saved values.
        sshConnections.resumeDraft = library.sshProfile(profileId) ?? draft
    }

    /// Disconnect: closes the shared connection (`ssh -O exit`). Asks first when runs on the
    /// profile are in progress, since they end with it; `confirmed` when the Connection
    /// Manager (#180) asked already.
    func disconnectSSH(_ profileId: UUID, confirmed: Bool = false) {
        guard let profile = library.sshProfile(profileId) else { return }
        // #143: SQL tabs whose saved connection goes through this profile's tunnel count too.
        let running = allTabs.filter { $0.isRunning && ($0.target == .ssh(profileId) || usesSQLTunnel(of: profileId, $0)) }.count
        if running > 0, !confirmed {
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
            await cancelSQLTunnels(on: endpoint) // #143: SQL tunnels on this connection go first
            await client.disconnect(endpoint)
            refreshSSHStatus(profileId)
            connectionManager.closing["ssh:\(profileId)"] = nil
        }
    }

    /// On quit: closes the shared connections runs opened by themselves (`automatic` profiles:
    /// agent, 1Password, or keys), so nothing stays connected after Runlet quits and the next
    /// launch connects only on the first run. Connect… logins (`interactive`: passwords, 2FA)
    /// stay open until Disconnect, as promised. Local `ssh -O exit` only; each waits ≤ 3 s.
    func closeAutomaticSSHConnections() async {
        let endpoints = library.sshProfiles
            .filter { $0.authentication == .automatic && refreshSSHStatus($0.id) == .connected }
            .map(sshEndpoint(for:))
        guard !endpoints.isEmpty else { return }
        let client = sshClient
        await withTaskGroup(of: Void.self) { group in
            for endpoint in endpoints {
                group.addTask { _ = await client.disconnect(endpoint) }
            }
        }
    }

    /// Called when a terminal tab's process exits: finishes a Connect… login.
    func sshTerminalExited(_ request: TerminalRequest, code: Int32?) {
        guard let profileId = sshConnections.connectRequests.removeValue(forKey: request.id) else { return }
        let status = refreshSSHStatus(profileId)
        if status == .connected, code == 0 {
            for tab in allTabs where tab.target == .ssh(profileId) { tab.targetIssue = nil }
            // Drift is checked after each Connect… when the profile asks for it.
            if let profile = library.sshProfile(profileId), profile.checkDrift { checkDriftOnServer(profile) }
            resumeSheetAfterLogin(profileId)
        }
    }

    /// After a run on an SSH profile: re-read the connection status, and check drift once per
    /// session (when the profile asks for it) now that a connection exists.
    func sshRunFinished(_ profileId: UUID, status: RunStatus, reason: String) {
        refreshSSHStatus(profileId)
        guard reason != "launch-failed", let profile = library.sshProfile(profileId), profile.checkDrift,
              sshConnections.driftCheckedAfterRun.insert(profileId).inserted else { return }
        checkDriftOnServer(profile)
    }

    // MARK: Runs

    /// The run snapshot for an SSH profile. Interactive profiles must be connected (checked
    /// locally); automatic ones connect on the run itself, in BatchMode. A container step is
    /// resolved on the server like a Docker profile (listing containers over SSH): an
    /// ambiguous or recreated-by-name container asks the user, and nothing else is ever
    /// substituted. `resolveContainer: false` gives the host itself (Shell on Host).
    func sshSnapshot(for tab: TabModel, profileId: UUID, resolveContainer: Bool = true) async throws -> TargetSnapshot {
        let host = try sshHostSnapshot(for: tab, profileId: profileId)
        guard resolveContainer, let profile = library.sshProfile(profileId), let step = profile.container else { return host }
        let docker = remoteDocker(for: profile, step: step)
        let containers: [ContainerInfo]
        do {
            containers = try await docker.runningContainers()
        } catch {
            throw TargetResolutionError(description: "Runlet couldn't list the containers on \(profile.destinationLabel): \(error)")
        }
        switch DockerProfileResolver.resolve(step.identity, among: containers) {
        case .resolved(let container, _):
            recordRemoteContainer(container, for: profileId)
            tab.targetIssue = nil
            var snapshot = host
            snapshot.label = "\(profile.name) · \(container.name) on \(profile.host)"
            snapshot.workingDirectory = step.workingDirectory
            snapshot.phpExecutable = step.phpExecutable
            snapshot.containerId = container.id
            snapshot.containerName = container.name
            snapshot.image = container.image
            snapshot.user = step.user
            snapshot.temporaryDirectory = step.temporaryDirectory
            snapshot.dockerCommand = step.dockerCommand
            snapshot.localFolderRoot = containerRoot(of: container, for: profile)
            return snapshot
        case .ambiguous(let candidates):
            containerChoice = ContainerChoice(target: .ssh(profileId), profileName: profile.name, candidates: candidates, reason: "Several running containers on \(profile.destinationLabel) match \(step.identity.displayName). Choose the one to use.")
            throw TargetResolutionError(description: "Choose which container on \(profile.destinationLabel) to use, then run again.")
        case .needsConfirmation(let container, let reason):
            containerChoice = ContainerChoice(target: .ssh(profileId), profileName: profile.name, candidates: [container], reason: reason)
            throw TargetResolutionError(description: reason)
        case .notRunning(let message):
            let text = "\(message.hasSuffix(".") ? String(message.dropLast()) : message) on \(profile.destinationLabel)."
            tab.targetIssue = text
            throw TargetResolutionError(description: "\(text) Start the application's containers on the server and run again.")
        }
    }

    /// Docker on the profile's host, through its SSH connection.
    func remoteDocker(for profile: SSHProfile, step: RemoteContainerStep) -> DockerCLI {
        DockerCLI(ssh: sshClient, endpoint: sshEndpoint(for: profile), dockerCommand: step.dockerCommand)
    }

    /// The container path of the profile's server directory (or its real path, from Test
    /// Connection), through the container's bind mounts: what the local folder corresponds to.
    private func containerRoot(of container: ContainerInfo, for profile: SSHProfile) -> String? {
        let directories = [profile.remoteDirectory, sshConnections.probes[profile.id]?.realDirectory].compactMap { $0 }
        return directories.lazy.compactMap { container.containerPath(forHostPath: $0) }.first
    }

    /// Remembers the container a run resolved (diagnostics and recreation checks). Not an
    /// edit: the revision, facts, and a production grace are unchanged.
    private func recordRemoteContainer(_ container: ContainerInfo, for profileId: UUID) {
        guard let index = library.sshProfiles.firstIndex(where: { $0.id == profileId }),
              var step = library.sshProfiles[index].container,
              step.identity.lastContainerId != container.id || step.identity.lastImage != container.image else { return }
        step.identity.lastContainerId = container.id
        step.identity.lastImage = container.image
        library.sshProfiles[index].container = step
        saveLibrary()
    }

    /// The user chose `container` for the profile's container step (after ambiguity or a
    /// recreated container without Compose labels).
    func confirmRemoteContainer(_ container: ContainerInfo, for profileId: UUID) {
        containerChoice = nil
        guard var profile = library.sshProfile(profileId), var step = profile.container else { return }
        step.identity.lastContainerId = container.id
        step.identity.lastImage = container.image
        if !step.identity.isCompose { step.identity.containerName = container.name }
        profile.container = step
        saveSSHProfile(profile)
        for tab in allTabs where tab.target == .ssh(profileId) { tab.targetIssue = nil }
    }

    /// The host part of an SSH snapshot (no container).
    private func sshHostSnapshot(for tab: TabModel, profileId: UUID) throws -> TargetSnapshot {
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

    // MARK: Shell on Host

    /// "Shell on app-prod", or "Shell in shop/app on app-prod" for a container step (with
    /// `onHost`, the host itself).
    func sshShellTitle(_ profile: SSHProfile, onHost: Bool = false) -> String {
        if !onHost, let step = profile.container { return "Shell in \(step.identity.displayName) on \(profile.host)" }
        return "Shell on \(profile.host)"
    }

    /// The selected tab, when it targets an SSH profile (for menu commands).
    var selectedSSHTab: TabModel? {
        guard let tab = selectedTab, case .ssh(let id) = tab.target, library.sshProfile(id) != nil else { return nil }
        return tab
    }

    /// Opens a login shell on the tab's SSH host in the profile's directory (or a shell in its
    /// container there) as a terminal tab. Resolved like a run: a password profile must be
    /// connected, and a container step never switches containers silently. Production hosts
    /// ask first, every time.
    func openSSHShell(for tab: TabModel, in window: WindowModel? = nil, onHost: Bool = false) {
        guard case .ssh(let id) = tab.target, let profile = library.sshProfile(id) else { return }
        let target = tab.target
        let inContainer = !onHost && profile.container != nil
        let preview = inContainer
            ? "ssh \(profile.destinationLabel), then a shell inside \(profile.container?.identity.displayName ?? "the container") in \(profile.container?.workingDirectory ?? "")"
            : "ssh \(profile.destinationLabel), then a login shell in \(profile.remoteDirectory)"
        guardProduction(.shell, target: target, text: preview, in: window ?? self.window(containing: tab.id)) { [weak self, weak tab] in
            guard let self, let tab, tab.target == target else { return }
            Task {
                do {
                    let snapshot = try await self.sshSnapshot(for: tab, profileId: id, resolveContainer: inContainer)
                    let place = snapshot.containerName.map { "\($0) on \(profile.host)" } ?? profile.host
                    var request = try ProjectCommandLauncher.sshShellRequest(target: snapshot, title: "Shell · \(place)", ssh: self.sshClient)
                    request.workingDirectory = self.library.localFolder(for: target)
                    self.openTerminal(request, in: window ?? self.window(containing: tab.id))
                } catch {
                    // An ambiguous or recreated container already opened the choice sheet.
                    if self.containerChoice == nil {
                        self.alert = AppAlert(title: "Could not open a shell on \(profile.name)", message: "\(error)")
                    }
                }
            }
        }
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
        if probe.error == nil {
            if library.sshProfile(id) != nil, profile.container == nil { noteProbeFacts(probe, for: profile) }
            lookUpFolderSuggestions(for: profile, probe: probe)
            await updateDrift(for: profile, server: probe)
        }
        if let step = profile.container {
            // Docker-only servers often have no PHP of their own; the container's is what runs.
            let check = await checkRemoteContainer(profile, step: step)
            sshConnections.containerChecks[id] = check
            if let version = check.probe?.phpVersion, library.sshProfile(id) != nil {
                let key = TargetRef.ssh(id).stableKey
                var facts = targetFacts[key] ?? TargetFacts()
                facts.phpVersion = version
                facts.profilers = check.probe?.profilers ?? facts.profilers
                if targetFacts[key] != facts { targetFacts[key] = facts }
            }
        } else {
            sshConnections.containerChecks[id] = nil
        }
        return probe
    }

    // MARK: Docker on the host

    /// Test Connection for a container step: lists the server's containers, resolves the
    /// step's identity (without asking: an unclear match is reported), and runs the read-only
    /// container probe in the one it finds.
    func checkRemoteContainer(_ profile: SSHProfile, step: RemoteContainerStep) async -> RemoteContainerCheck {
        guard step.hasIdentity else { return RemoteContainerCheck(problem: "Choose the container first (List Containers).") }
        let docker = remoteDocker(for: profile, step: step)
        let containers: [ContainerInfo]
        do {
            containers = try await docker.runningContainers()
        } catch {
            return RemoteContainerCheck(problem: "\(error)")
        }
        switch DockerProfileResolver.resolve(step.identity, among: containers) {
        case .resolved(let container, _):
            let probe = await docker.probe(containerId: container.id, phpExecutable: step.phpExecutable, user: step.user, workingDirectory: step.workingDirectory, temporaryDirectory: step.temporaryDirectory, extraCandidates: DockerCLI.workingDirectorySuggestions(for: container))
            return RemoteContainerCheck(container: container, probe: probe)
        case .ambiguous(let matches):
            return RemoteContainerCheck(problem: "\(matches.count) running containers on \(profile.destinationLabel) match \(step.identity.displayName). Runlet asks which one to use when you run.")
        case .needsConfirmation(_, let reason):
            return RemoteContainerCheck(problem: reason)
        case .notRunning(let message):
            return RemoteContainerCheck(problem: "\(message.hasSuffix(".") ? String(message.dropLast()) : message) on \(profile.destinationLabel).")
        }
    }

    /// The running containers on the profile's host, for the container picker (an explicit
    /// List Containers; connects like Test Connection).
    func listRemoteContainers(_ profile: SSHProfile, dockerCommand: String) async throws -> [ContainerInfo] {
        if let message = sshLoginNeeded(profile) { throw TargetResolutionError(description: message) }
        let docker = DockerCLI(ssh: sshClient, endpoint: sshEndpoint(for: profile), dockerCommand: dockerCommand)
        defer { refreshSSHStatus(profile.id) }
        return try await docker.runningContainers()
    }

    /// One folder inside the step's container (resolved without asking), for Browse… next to
    /// the container's working directory. Read-only.
    func listContainerDirectory(_ profile: SSHProfile, step: RemoteContainerStep, path: String) async -> RemoteDirectoryListing {
        if let message = sshLoginNeeded(profile) { return RemoteDirectoryListing(path: path, error: message) }
        let docker = remoteDocker(for: profile, step: step)
        let containers: [ContainerInfo]
        do {
            containers = try await docker.runningContainers()
        } catch {
            return RemoteDirectoryListing(path: path, error: "\(error)")
        }
        guard case .resolved(let container, _) = DockerProfileResolver.resolve(step.identity, among: containers) else {
            return RemoteDirectoryListing(path: path, error: "The container \(step.identity.displayName) isn't running on \(profile.destinationLabel), or several containers match it. Choose a running container first.")
        }
        return await docker.listDirectory(containerId: container.id, user: step.user, phpExecutable: step.phpExecutable, path: path, place: "\(container.name) on \(profile.host)")
    }

    // MARK: Folders on the server

    /// Why a server can't be asked anything yet: a password or 2FA profile that isn't
    /// connected (runs and helpers never log in themselves). nil when it can.
    func sshLoginNeeded(_ profile: SSHProfile) -> String? {
        guard profile.authentication == .interactive, sshClient.status(sshEndpoint(for: profile)) != .connected else { return nil }
        return "Not connected to \(profile.destinationLabel). Use Connect… to log in first; Runlet then reuses that login."
    }

    /// Detect (the profile form): the login's home folder and folders on the server that look
    /// like PHP applications, read by a short read-only `php -r`. Explicit action only; it
    /// connects like Test Connection (BatchMode, through the shared connection).
    func detectSSHDirectories(_ profile: SSHProfile) async -> RemoteDirectoryDetection {
        if let message = sshLoginNeeded(profile) { return RemoteDirectoryDetection(error: message) }
        let detection = await sshClient.detectDirectories(sshEndpoint(for: profile), phpExecutable: profile.phpExecutable)
        refreshSSHStatus(profile.id)
        return detection
    }

    /// One folder's subfolders on the server, for the directory browser (read-only `php -r`;
    /// explicit action only).
    func listSSHDirectory(_ profile: SSHProfile, path: String) async -> RemoteDirectoryListing {
        if let message = sshLoginNeeded(profile) { return RemoteDirectoryListing(path: path, error: message) }
        let listing = await sshClient.listDirectory(sshEndpoint(for: profile), phpExecutable: profile.phpExecutable, path: path)
        refreshSSHStatus(profile.id)
        return listing
    }

    // MARK: Local folder

    /// Folders Runlet already knows: local projects and the local folders of Docker and SSH
    /// profiles (suggestion candidates).
    var knownLocalFolders: [String] {
        library.localProjects.map(\.path) + library.dockerProfiles.compactMap(\.localSourcePath) + library.sshProfiles.compactMap(\.localSourcePath)
    }

    /// Looks for a local checkout of the profile's project (only for profiles without a local
    /// folder): by the server's git remote and composer.json name after Test Connection, and
    /// by folder name otherwise. Reads folders on this Mac only; never connects.
    func lookUpFolderSuggestions(for profile: SSHProfile, probe: SSHProbe?) {
        let id = profile.id
        guard profile.localSourcePath == nil else {
            sshConnections.folderSuggestions[id] = nil
            return
        }
        sshConnections.suggestionsLookedUp.insert(id)
        let known = knownLocalFolders
        let directory = profile.remoteDirectory
        Task {
            let found = await Task.detached { LocalFolderSuggestions.suggest(remoteDirectory: directory, probe: probe, knownFolders: known) }.value
            sshConnections.folderSuggestions[id] = found.isEmpty ? nil : found
        }
    }

    /// Folder suggestions for a tab's profile, looked up once per session.
    func lookUpFolderSuggestionsOnce(for profileId: UUID) {
        guard let profile = library.sshProfile(profileId), profile.localSourcePath == nil,
              !sshConnections.suggestionsLookedUp.contains(profileId) else { return }
        lookUpFolderSuggestions(for: profile, probe: sshConnections.probes[profileId])
    }

    /// Uses a suggested folder as the profile's local folder (an explicit click).
    func useSuggestedFolder(_ path: String, for profileId: UUID) {
        guard var profile = library.sshProfile(profileId) else { return }
        profile.localSourcePath = path
        sshConnections.folderSuggestions[profileId] = nil
        saveSSHProfile(profile)
    }

    // MARK: Drift

    /// Compares the local folder with the server's checkout read by `server` (a probe).
    func updateDrift(for profile: SSHProfile, server: SSHProbe) async {
        let id = profile.id
        guard profile.checkDrift, let folder = library.localFolder(for: .ssh(id)), server.error == nil else {
            sshConnections.drift[id] = nil
            return
        }
        let local = await Task.detached { LocalCheckout.read(folder) }.value
        let warning = CheckoutDrift.warning(local: local, remote: server.checkout, host: profile.destinationLabel)
        if warning != sshConnections.drift[id] { sshConnections.dismissedDrift.remove(id) }
        sshConnections.drift[id] = warning
    }

    /// Reads the server's checkout (Test Connection's read-only probe) and updates the drift
    /// warning. Only after an explicit Connect…, Test Connection, run, or Check Again.
    func checkDriftOnServer(_ profile: SSHProfile) {
        Task {
            let endpoint = sshEndpoint(for: profile)
            let client = sshClient
            if profile.authentication == .interactive, client.status(endpoint) != .connected { return }
            let probe = await client.probe(endpoint, phpExecutable: profile.phpExecutable, directory: profile.remoteDirectory)
            guard probe.error == nil else { return }
            sshConnections.probes[profile.id] = probe
            await updateDrift(for: profile, server: probe)
        }
    }

    /// Records what Test Connection learned (PHP version, and the framework when the profile
    /// has no local folder to read it from).
    private func noteProbeFacts(_ probe: SSHProbe, for profile: SSHProfile) {
        let key = TargetRef.ssh(profile.id).stableKey
        var facts = targetFacts[key] ?? TargetFacts()
        if let version = probe.phpVersion { facts.phpVersion = version }
        // A container step runs the container's PHP: the server's profilers don't apply.
        if profile.container == nil, let profilers = probe.profilers { facts.profilers = profilers }
        if facts.fromRun != true, library.localFolder(for: .ssh(profile.id)) == nil {
            facts.framework = probe.framework.hasPrefix("custom:") ? "custom:" + (probe.framework.dropFirst(7).split(separator: ",").first.map(String.init) ?? "") : probe.framework
        }
        if targetFacts[key] != facts { targetFacts[key] = facts }
    }
}
