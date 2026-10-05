import AppKit
import Observation
import RunletCore
import RunletExecution

// MARK: - Log viewer (#20)

/// Where a log comes from.
struct LogSource: Hashable, Identifiable {
    enum Kind: Hashable {
        /// A file on this Mac: in a local project, the sandbox, or a Docker profile's local folder
        /// (its bind mount). Read directly and followed with a file watcher; nothing runs.
        case hostFile(String)
        /// A file in the target's container: a Docker profile's, or an SSH profile's container
        /// step. Followed with `docker exec -i … tail -F` once the user clicks Follow.
        case containerFile(String)
        /// A file on an SSH host, followed with `ssh … tail -F` once the user clicks Follow.
        case serverFile(String)
        /// The container's output (`docker logs --follow --tail 500`), once the user clicks Follow.
        case containerOutput
    }

    enum Group: String, CaseIterable {
        case thisMac = "On This Mac"
        case container = "In the Container"
        case server = "On the Server"
        case output = "Output"
    }

    var kind: Kind
    /// `storage/logs/laravel.log`, `Container output`.
    var title: String
    /// `412 KB · 2 min ago`, `From the driver's logPaths()`.
    var detail: String?
    var group: Group

    var id: String {
        switch kind {
        case .hostFile(let path): "host:\(path)"
        case .containerFile(let path): "container:\(path)"
        case .serverFile(let path): "server:\(path)"
        case .containerOutput: "output"
        }
    }

    /// Read in a container or on a server: only after Follow.
    var isRemote: Bool {
        if case .hostFile = kind { return false }
        return true
    }

    var path: String? {
        switch kind {
        case .hostFile(let path), .containerFile(let path), .serverFile(let path): path
        case .containerOutput: nil
        }
    }

    /// "tail -F", "docker logs".
    var commandName: String {
        switch kind {
        case .hostFile: "file watcher"
        case .containerFile, .serverFile: "tail -F"
        case .containerOutput: "docker logs"
        }
    }
}

/// One source shown in the Logs window: what was read, and how it is followed.
@MainActor
@Observable
final class LogSession: Identifiable {
    enum State: Equatable {
        /// The first read of a file on this Mac.
        case loading
        /// Nothing is read now: a remote source before Follow, or a file read once.
        case idle
        /// A follow is reading what is added.
        case following(since: Date)
        /// Starting a remote follow (asking, connecting, resolving the container).
        case starting
        /// The follow ended by itself (the container stopped, the connection was lost).
        case ended(String)
        case failed(String)
    }

    let id = UUID()
    let target: TargetRef
    let source: LogSource
    var buffer = LogBuffer()
    var state: State = .idle
    /// What the follow said about itself (tail's "file truncated", a rotation), newest last.
    var notices: [String] = []
    /// Pause: the entries shown while new ones keep arriving.
    var frozen: [LogEntry]?
    var expanded: Set<Int> = []
    /// The file's size at the last read, and how much of its start the first read skipped.
    var fileSize: UInt64?
    var skippedHead: UInt64 = 0
    /// "Logs written by the last run" for a file on this Mac: the part of the file the run
    /// added, read again (nil: the main list is filtered instead).
    var runEntries: [LogEntry]?
    /// Why "Last run" shows what it shows.
    var runNote: String?

    @ObservationIgnored var fileFollower: LogFileFollower?
    @ObservationIgnored var processFollower: LogProcessFollower?
    @ObservationIgnored var identity: LogFileIdentity?
    /// Connection Manager row details (#180) of a remote follow.
    var destination = ""
    var via: [String] = []
    var environment: TargetEnvironment = .development

    init(target: TargetRef, source: LogSource) {
        self.target = target
        self.source = source
    }

    var isFollowing: Bool {
        if case .following = state { return true }
        return false
    }

    var isPaused: Bool { frozen != nil }

    /// The entries the list shows (Pause keeps the ones from when it was paused).
    var shownEntries: [LogEntry] { frozen ?? buffer.entries }

    /// Entries that arrived since Pause.
    var newWhilePaused: Int {
        guard let last = frozen?.last?.id else { return frozen == nil ? 0 : buffer.entries.count }
        return buffer.entries.reversed().prefix { $0.id > last }.count
    }

    func note(_ text: String) {
        notices.append(text)
        if notices.count > 20 { notices.removeFirst(notices.count - 20) }
    }

    /// Stops reading: the file watcher, or the remote follow (its `tail` ends on the far side).
    func stopFollowing() async {
        fileFollower?.cancel()
        fileFollower = nil
        if let process = processFollower {
            processFollower = nil
            await process.stop()
        }
        if isFollowing || state == .starting { state = .idle }
    }
}

/// Where the log ended when a run started and ended on a target (#20): the sizes of the target's
/// log files on this Mac, for "Logs written by the last run".
struct LogRunMark: Equatable {
    var startedAt: Date
    var endedAt: Date?
    var tabTitle: String
    var startSizes: [String: UInt64] = [:]
    var endSizes: [String: UInt64] = [:]
    var identities: [String: LogFileIdentity] = [:]
}

/// The Logs window's state (#20), per app model.
@MainActor
@Observable
final class LogViewerStore {
    /// The target whose logs are shown.
    var target: TargetRef?
    var session: LogSession?
    var minimumLevel: LogLevel?
    var search = ""
    /// "Logs written by the last run".
    var showsLastRun = false
    /// Files found on this Mac per target (`TargetRef.stableKey`).
    var hostCandidates: [String: [LogFileCandidate]] = [:]
    /// Find Logs' results per target: paths in the container or on the server.
    var found: [String: [String]] = [:]
    var finding: Set<String> = []
    /// Paths typed with Other Path… per target.
    var otherPaths: [String: [String]] = [:]
    var runMarks: [String: LogRunMark] = [:]
    var isWindowOpen = false
    /// #8's read-only peek of a frame's file, shown next to the entry `peekEntryId`.
    var peek: ExcerptPeek?
    var peekEntryId: Int?
    /// The window was opened this session: runs record where the target's logs end.
    var wasOpened = false
    /// What the last action did, for DEBUG steps.
    var lastEvent: String?

    private static var stores: [ObjectIdentifier: LogViewerStore] = [:]

    static func shared(for model: AppModel) -> LogViewerStore {
        let key = ObjectIdentifier(model)
        if let store = stores[key] { return store }
        let store = LogViewerStore()
        stores[key] = store
        return store
    }

    var filter: LogFilter {
        LogFilter(minimumLevel: minimumLevel, search: search)
    }
}

extension AppModel {
    static let logViewerSceneId = "logs"

    var logViewer: LogViewerStore { LogViewerStore.shared(for: self) }

    // MARK: Window

    /// View ▸ Logs (⌘L) and Open Anything: the Logs window for `target` (the current tab's by
    /// default). Opening reads the target's log files on this Mac; nothing connects or runs.
    func showLogs(target: TargetRef? = nil, lastRun: Bool = false) {
        let store = logViewer
        let chosen = target ?? store.target.flatMap { isKnownTarget($0) ? $0 : nil } ?? selectedTab?.target ?? .sandbox
        store.wasOpened = true
        if lastRun { store.showsLastRun = true }
        if store.target != chosen || store.session == nil {
            selectLogTarget(chosen)
        } else {
            // Reopened: a file on this Mac is read and watched again (closing stopped it).
            if let session = store.session, !session.source.isRemote, !session.isFollowing { reloadLog() }
            if lastRun { refreshLastRun() }
        }
        openSingleWindowAction?(Self.logViewerSceneId)
    }

    /// The Logs window closed: every follow stops (a remote one's `tail` with it).
    func logViewerClosed() {
        logViewer.isWindowOpen = false
        let session = logViewer.session
        Task { await session?.stopFollowing() }
        logViewer.lastEvent = "closed"
    }

    /// On quit: every follow stops.
    func stopAllLogFollows() async {
        await logViewer.session?.stopFollowing()
    }

    func isKnownTarget(_ target: TargetRef) -> Bool {
        switch target {
        case .sandbox: true
        case .local(let id): library.localProject(id) != nil
        case .docker(let id): library.dockerProfile(id) != nil
        case .ssh(let id): library.sshProfile(id) != nil
        }
    }

    /// Every target, for the window's target menu: the sandbox, then projects and profiles.
    var logTargets: [TargetRef] {
        [.sandbox] + library.localProjects.map { .local($0.id) } + library.dockerProfiles.map { .docker($0.id) } + library.sshProfiles.map { .ssh($0.id) }
    }

    /// Shows `target`'s logs: its files on this Mac are looked for, and the first source opens.
    func selectLogTarget(_ target: TargetRef) {
        let store = logViewer
        let previous = store.session
        Task { await previous?.stopFollowing() }
        store.target = target
        store.session = nil
        refreshLogCandidates(for: target) { [weak self] in
            guard let self, self.logViewer.target == target, self.logViewer.session == nil else { return }
            if let first = self.defaultLogSource(for: target) { self.openLogSource(first) }
        }
    }

    /// The source a target opens with: Laravel's `storage/logs/laravel.log` when it's on this
    /// Mac, else the first one listed (the driver's, then the newest file).
    func defaultLogSource(for target: TargetRef) -> LogSource? {
        let sources = logSources(for: target)
        return sources.first { !$0.isRemote && ($0.path?.hasSuffix("/storage/logs/laravel.log") ?? false) } ?? sources.first
    }

    /// The folder on this Mac whose log files are read directly: the sandbox's install, a local
    /// project, or a Docker profile's local folder (its bind mount). SSH profiles have none: their
    /// local folder is a copy, so its logs aren't the server's.
    func logHostFolder(for target: TargetRef) -> String? {
        switch target {
        case .sandbox:
            guard let sandbox, sandbox.isInstalled else { return nil }
            return sandbox.installURL.path
        case .local, .docker:
            return library.localFolder(for: target)
        case .ssh:
            return nil
        }
    }

    /// The driver's `logPaths()`: from the target's command list when it is loaded, else the
    /// last ones it declared (#271, kept across launches). Never loads anything.
    func driverLogPaths(for target: TargetRef) -> [String] {
        driverLogPathMemory.paths(for: target.stableKey, loaded: commands(for: target))
    }

    /// Whether Runlet knows what the target's driver declares as its log paths (#271).
    func knowsDriverLogPaths(for target: TargetRef) -> Bool {
        driverLogPathMemory.knows(target.stableKey, loaded: commands(for: target))
    }

    /// Whether the target's project on this Mac has a project driver (`.runlet/`).
    func hasProjectDriver(for target: TargetRef) -> Bool {
        guard let folder = logHostFolder(for: target) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(".runlet"), isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Load the Driver's Log Paths (#271): lists the target's commands, which boots the
    /// project like the Commands panel does (production asks first). The driver's
    /// `logPaths()` come with the listing; an explicit action, so the Logs window still never
    /// runs code by itself.
    func loadDriverLogPaths(for target: TargetRef) {
        guard !commandsState(for: target).isLoading else { return }
        // Any tab on the target resolves it the same way; Test Connection makes one the same way.
        let tab = allTabs.first { $0.target == target } ?? TabModel(state: TabState(title: "", target: target))
        guardProduction(.listCommands, target: target, text: "List the commands of \(targetLabel(target)) to find its driver's log files (boots the application)") { [weak self] in
            self?.startLoadingCommands(for: tab)
        }
    }

    /// Remembers a fresh listing's `logPaths()` and, when the Logs window shows the target,
    /// looks for its files again (#271).
    func rememberDriverLogPaths(_ catalog: ProjectCommandCatalog, for target: TargetRef) {
        if driverLogPathMemory.remember(catalog, for: target.stableKey) { scheduleFactsSave() }
        if catalog.logPathsDeclared, logViewer.target == target { refreshLogCandidates(for: target) }
    }

    /// Looks for the target's log files on this Mac, off the main thread.
    func refreshLogCandidates(for target: TargetRef, then: (@MainActor () -> Void)? = nil) {
        guard let folder = logHostFolder(for: target) else {
            logViewer.hostCandidates[target.stableKey] = []
            then?()
            return
        }
        // A driver's absolute paths are the target's: map them into the local folder.
        let mapping = logPathMapping(for: target)
        let driver = driverLogPaths(for: target).map { path in path.hasPrefix("/") ? (mapping.resolve(path).path ?? path) : path }
        let search = Task.detached(priority: .userInitiated) { LogDiscovery.find(in: folder, driverPaths: driver) }
        Task { [weak self] in
            let found = await search.value
            self?.logViewer.hostCandidates[target.stableKey] = found
            then?()
        }
    }

    /// What the window's source menu lists for `target`, in order.
    func logSources(for target: TargetRef) -> [LogSource] {
        var sources: [LogSource] = []
        let key = target.stableKey
        for candidate in logViewer.hostCandidates[key] ?? [] {
            let size = ByteCountFormatter.string(fromByteCount: Int64(candidate.size), countStyle: .file)
            let when = candidate.modified.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
            let detail = candidate.origin == .driver ? "\(size) · \(when) · from the driver" : "\(size) · \(when)"
            sources.append(LogSource(kind: .hostFile(candidate.path), title: candidate.relativePath, detail: detail, group: .thisMac))
        }
        for path in logViewer.otherPaths[key] ?? [] where path.hasPrefix("/") && FileManager.default.fileExists(atPath: path) && logHostFolder(for: target) != nil && !target.isSSH {
            if !sources.contains(where: { $0.path == path }) {
                sources.append(LogSource(kind: .hostFile(path), title: path, detail: "Other path", group: .thisMac))
            }
        }
        let remoteBase: String?
        let group: LogSource.Group
        var hasContainer = false
        let hostFolder = logHostFolder(for: target)
        switch target {
        case .docker(let id):
            hasContainer = true
            group = .container
            remoteBase = library.dockerProfile(id)?.workingDirectory
        case .ssh(let id):
            let profile = library.sshProfile(id)
            hasContainer = profile?.container != nil
            group = hasContainer ? .container : .server
            remoteBase = profile?.container?.workingDirectory ?? profile?.remoteDirectory
        default:
            remoteBase = nil
            group = .server
        }
        if let base = remoteBase {
            var seen = Set<String>()
            func add(_ path: String, detail: String?) {
                let absolute = path.hasPrefix("/") ? path : (base as NSString).appendingPathComponent(path)
                guard seen.insert(absolute).inserted else { return }
                let title = absolute.hasPrefix(base + "/") ? String(absolute.dropFirst(base.count + 1)) : absolute
                let kind: LogSource.Kind = group == .server ? .serverFile(absolute) : .containerFile(absolute)
                sources.append(LogSource(kind: kind, title: title, detail: detail, group: group))
            }
            // With a local folder (a Docker profile's bind mount), the project's logs are its files
            // above: the container lists only what Find Logs found and absolute paths typed.
            let defaults = hostFolder == nil
            if defaults {
                for path in driverLogPaths(for: target) where !path.contains("*") { add(path, detail: "From the driver") }
            }
            for path in logViewer.found[key] ?? [] { add(path, detail: "Found") }
            for path in logViewer.otherPaths[key] ?? [] where defaults || (path.hasPrefix("/") && !sources.contains { $0.path == path }) {
                add(path, detail: "Other path")
            }
            if defaults {
                for path in LogDiscovery.usualPaths(framework: targetFacts[key]?.framework) { add(path, detail: logViewer.found[key] == nil ? "If it exists" : nil) }
            }
        }
        if hasContainer {
            sources.append(LogSource(kind: .containerOutput, title: "Container output", detail: "docker logs", group: .output))
        }
        return sources
    }

    /// Opens `source`: a file on this Mac is read (its last 512 KB) and followed; a remote
    /// source waits for Follow.
    func openLogSource(_ source: LogSource) {
        guard let target = logViewer.target else { return }
        let previous = logViewer.session
        Task { await previous?.stopFollowing() }
        let session = LogSession(target: target, source: source)
        session.environment = library.environment(for: target)
        logViewer.session = session
        logViewer.lastEvent = "opened \(source.id)"
        if case .hostFile(let path) = source.kind {
            loadHostFile(path, into: session, follow: true)
        } else {
            session.state = .idle
            refreshLastRun()
        }
    }

    /// Reads the file's end again (Reload) and goes on following.
    func reloadLog() {
        guard let session = logViewer.session else { return }
        if case .hostFile(let path) = session.source.kind {
            Task {
                await session.stopFollowing()
                session.buffer = LogBuffer()
                session.frozen = nil
                self.loadHostFile(path, into: session, follow: true)
            }
        } else {
            refreshLastRun()
        }
    }

    private func loadHostFile(_ path: String, into session: LogSession, follow: Bool) {
        session.state = .loading
        let read = Task.detached(priority: .userInitiated) { () -> Result<(LogTail.Chunk, LogBuffer), Error> in
            do {
                let chunk = try LogTail.read(path: path)
                var buffer = LogBuffer()
                buffer.begin(at: chunk.start)
                buffer.append(chunk.data)
                buffer.flush()
                return .success((chunk, buffer))
            } catch {
                return .failure(error)
            }
        }
        Task { [weak self] in
            let result = await read.value
            guard let self, self.logViewer.session === session else { return }
            do {
                switch result {
                case .success(let (chunk, buffer)):
                    session.buffer = buffer
                    session.identity = chunk.identity
                    session.fileSize = chunk.end
                    session.skippedHead = chunk.skipped
                    session.state = .idle
                    if follow { self.followHostFile(path, session: session, from: chunk.end, identity: chunk.identity) }
                case .failure(let error):
                    session.state = .failed("\(error)")
                    // A file that isn't there yet is followed until it appears.
                    if follow, case LogTail.ReadError.missing = error { self.followHostFile(path, session: session, from: 0, identity: nil) }
                }
                self.refreshLastRun()
            }
        }
    }

    private func followHostFile(_ path: String, session: LogSession, from offset: UInt64, identity: LogFileIdentity?) {
        session.fileFollower?.cancel()
        session.fileFollower = LogFileFollower(path: path, from: offset, identity: identity) { [weak self, weak session] event in
            MainActor.assumeIsolated {
                guard let self, let session, self.logViewer.session === session else { return }
                self.receive(event, in: session)
            }
        }
        session.state = .following(since: Date())
    }

    private func receive(_ event: LogFileFollower.Event, in session: LogSession) {
        switch event {
        case .appended(let data, let start, let skipped):
            if skipped > 0 {
                session.note("\(ByteCountFormatter.string(fromByteCount: Int64(skipped), countStyle: .file)) were written at once; Runlet read only the last part.")
                session.buffer.begin(at: start)
            }
            session.buffer.append(data, receivedAt: Date())
            session.fileSize = start + UInt64(data.count)
            if case .failed = session.state { session.state = .following(since: Date()) }
        case .truncated:
            session.note("The file was truncated at \(Date().formatted(date: .omitted, time: .standard)); reading it from its start.")
            session.buffer.begin(at: 0)
        case .rotated:
            session.note("The log was rotated at \(Date().formatted(date: .omitted, time: .standard)); following the new file.")
            session.buffer.begin(at: 0)
            if case .hostFile(let path) = session.source.kind { session.identity = LogFileIdentity.of(path: path)?.identity }
        case .missing:
            session.note("The file is gone; Runlet follows the path until a file is there again.")
        }
    }

    // MARK: Follow, Pause, Clear

    /// Follow: a file on this Mac is watched again; a container or server log starts its
    /// `tail -F` or `docker logs` (asking first on production, and before connecting an SSH
    /// profile that isn't connected).
    func followLog() {
        guard let session = logViewer.session, !session.isFollowing, session.state != .starting else { return }
        switch session.source.kind {
        case .hostFile(let path):
            followHostFile(path, session: session, from: session.fileSize ?? 0, identity: session.identity)
        case .containerFile, .serverFile, .containerOutput:
            session.state = .starting
            Task {
                do {
                    try await self.startRemoteFollow(session)
                } catch {
                    session.state = .failed(String(describing: error))
                    self.logViewer.lastEvent = "follow failed: \(error)"
                }
            }
        }
    }

    /// Stop: no more reading (the remote `tail` ends too).
    func stopFollowingLog() {
        guard let session = logViewer.session else { return }
        logViewer.lastEvent = "stopped \(session.source.id)"
        Task { await session.stopFollowing() }
    }

    func toggleLogPause() {
        guard let session = logViewer.session else { return }
        session.frozen = session.frozen == nil ? session.buffer.entries : nil
    }

    /// Clear: empties the list. The log itself is never changed.
    func clearLog() {
        guard let session = logViewer.session else { return }
        session.buffer.clear()
        session.frozen = session.frozen.map { _ in [] }
        session.expanded = []
        session.runEntries = session.runEntries.map { _ in [] }
    }

    private func startRemoteFollow(_ session: LogSession) async throws {
        let target = session.target
        let name = targetLabel(target)
        if isProduction(target) {
            let alert = NSAlert()
            alert.messageText = "Follow this log on production?"
            alert.informativeText = "“\(name)” is marked as production. Runlet reads \(session.source.path.map { "“\($0)”" } ?? "the container's output") with \(session.source.commandName) and runs nothing else. Log lines can hold personal data or secrets: Runlet shows them in this window only, and never saves them or gives them to AI clients."
            alert.addButton(withTitle: "Follow")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                session.state = .idle
                logViewer.lastEvent = "production follow declined"
                return
            }
        }
        let started = try await remoteFollowSpec(for: session)
        guard logViewer.session === session, session.state == .starting else { return }
        session.destination = started.destination
        session.via = started.via
        let follower = try LogProcessFollower(spec: started.spec, stderrIsLog: started.stderrIsLog, explain: started.explain) { [weak self, weak session] event in
            MainActor.assumeIsolated {
                guard let self, let session else { return }
                switch event {
                case .output(let data):
                    session.buffer.append(data, receivedAt: Date())
                case .notice(let line):
                    session.note(line)
                case .ended(let code, let message):
                    session.processFollower = nil
                    session.state = .ended(message ?? (code == 0 ? "The follow ended." : "The follow ended (exit code \(code))."))
                    self.logViewer.lastEvent = "follow ended \(code)"
                    if case .ssh(let id) = session.target { self.refreshSSHStatus(id) }
                }
            }
        }
        session.processFollower = follower
        session.state = .following(since: Date())
        logViewer.lastEvent = "following \(session.source.id)"
        if case .ssh(let id) = target { refreshSSHStatus(id) }
    }

    private struct RemoteFollow {
        var spec: ProcessSpec
        var stderrIsLog: Bool
        var explain: (@Sendable (String, Int32) -> String?)?
        var destination: String
        var via: [String]
    }

    private func remoteFollowSpec(for session: LogSession) async throws -> RemoteFollow {
        switch session.target {
        case .docker(let id):
            guard let profile = library.dockerProfile(id) else { throw TargetResolutionError(description: "This Docker profile was removed.") }
            guard let docker else { throw TargetResolutionError(description: "The Docker CLI was not found. Install Docker or set its path in Settings.") }
            let container = try await logContainer(profile: profile, docker: docker)
            switch session.source.kind {
            case .containerOutput:
                return RemoteFollow(spec: docker.spec(LogFollowCommand.dockerLogsArguments(container: container.id)), stderrIsLog: true, explain: nil,
                                    destination: "docker logs \(container.name) on this Mac", via: [])
            case .containerFile(let path):
                return RemoteFollow(spec: docker.spec(LogFollowCommand.dockerExecTailArguments(container: container.id, user: profile.user, path: path)), stderrIsLog: false, explain: nil,
                                    destination: "tail -F in \(container.name) on this Mac", via: [])
            default:
                throw TargetResolutionError(description: "This source isn't in the container.")
            }
        case .ssh(let id):
            guard let profile = library.sshProfile(id) else { throw TargetResolutionError(description: "This SSH profile was removed.") }
            try await ensureLogConnection(profile)
            let endpoint = sshEndpoint(for: profile)
            let client = sshClient
            try SSHControlPaths.prepareDirectory(for: endpoint.controlPath)
            let host = endpoint.displayName
            let explain: @Sendable (String, Int32) -> String? = { output, code in SSHFailure.explain(output, exitCode: code, host: host) }
            let via = ["ssh:\(profile.id)"]
            if let step = profile.container {
                let container = try await logRemoteContainer(profile: profile, step: step)
                switch session.source.kind {
                case .containerOutput:
                    return RemoteFollow(spec: client.spec(endpoint, remoteCommand: LogFollowCommand.sshDockerLogsCommand(dockerCommand: step.dockerCommand, container: container.id)),
                                        stderrIsLog: true, explain: explain, destination: "docker logs \(container.name) on \(profile.destinationLabel)", via: via)
                case .containerFile(let path):
                    return RemoteFollow(spec: client.spec(endpoint, remoteCommand: LogFollowCommand.sshDockerTailCommand(dockerCommand: step.dockerCommand, container: container.id, user: step.user, path: path)),
                                        stderrIsLog: false, explain: explain, destination: "tail -F in \(container.name) on \(profile.destinationLabel)", via: via)
                default:
                    break
                }
            }
            guard case .serverFile(let path) = session.source.kind else { throw TargetResolutionError(description: "This source isn't on the server.") }
            return RemoteFollow(spec: client.spec(endpoint, remoteCommand: LogFollowCommand.sshTailCommand(path: path)), stderrIsLog: false, explain: explain,
                                destination: "tail -F on \(profile.destinationLabel)", via: via)
        case .sandbox, .local:
            throw TargetResolutionError(description: "This target's logs are files on this Mac.")
        }
    }

    /// The Docker profile's running container, as runs resolve it; anything that needs a
    /// choice is left to a run.
    private func logContainer(profile: DockerProfile, docker: DockerCLI) async throws -> ContainerInfo {
        switch try await DockerProfileResolver.resolve(profile, docker: docker) {
        case .resolved(let container, _):
            return container
        case .ambiguous:
            throw TargetResolutionError(description: "Several running containers match \(profile.identity.displayName). Run a snippet on the profile once to choose one, then follow again.")
        case .needsConfirmation(_, let reason):
            throw TargetResolutionError(description: "\(reason) Run a snippet on the profile once to confirm the container, then follow again.")
        case .notRunning(let message):
            throw TargetResolutionError(description: "\(message) Start the application's containers, then follow again.")
        }
    }

    private func logRemoteContainer(profile: SSHProfile, step: RemoteContainerStep) async throws -> ContainerInfo {
        let containers: [ContainerInfo]
        do {
            containers = try await remoteDocker(for: profile, step: step).runningContainers()
        } catch {
            throw TargetResolutionError(description: "Runlet couldn't list the containers on \(profile.destinationLabel): \(error)")
        }
        switch DockerProfileResolver.resolve(step.identity, among: containers) {
        case .resolved(let container, _):
            return container
        case .ambiguous, .needsConfirmation:
            throw TargetResolutionError(description: "Several containers on \(profile.destinationLabel) could be \(step.identity.displayName). Run a snippet on the profile once to choose one, then follow again.")
        case .notRunning(let message):
            throw TargetResolutionError(description: "\(message) on \(profile.destinationLabel).")
        }
    }

    /// Asks before a follow connects an SSH profile that isn't connected, as a tunnel does
    /// (#143). Agent and key profiles then connect like their runs; password and 2FA profiles
    /// open Connect… in a terminal, and Follow is clicked again once logged in.
    private func ensureLogConnection(_ profile: SSHProfile) async throws {
        let status = refreshSSHStatus(profile.id)
        guard status != .connected else { return }
        let interactive = profile.authentication == .interactive
        let alert = NSAlert()
        alert.messageText = "Connect to “\(profile.name)” to follow the log?"
        alert.informativeText = "\(profile.destinationLabel) \(status == .expired ? "isn't connected any more (its login ended)" : "isn't connected"). Runlet connects only when you say so. "
            + (interactive
                ? "Connect… opens a terminal where OpenSSH asks for the password or code; click Follow again once you're logged in."
                : "Runlet logs in with your SSH agent or keys, as a run on that profile would.")
        alert.addButton(withTitle: interactive ? "Connect…" : "Connect")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            throw TargetResolutionError(description: "Not connected to \(profile.destinationLabel), so nothing is followed.")
        }
        if interactive {
            connectSSH(profile.id, in: activeWindow)
            throw TargetResolutionError(description: "Log in to \(profile.destinationLabel) in the terminal, then click Follow again.")
        }
        let endpoint = sshEndpoint(for: profile)
        SSHControlSocket.removeIfStale(at: endpoint.controlPath)
        do {
            try await sshClient.openSharedConnection(endpoint)
        } catch {
            refreshSSHStatus(profile.id)
            throw TargetResolutionError(description: "Runlet couldn't connect to \(profile.destinationLabel): \(error)")
        }
        refreshSSHStatus(profile.id)
    }

    // MARK: Find Logs, Other Path

    /// Find Logs: lists the `*.log` files of `storage/logs` and `var/log`, `wp-content/debug.log`,
    /// and the driver's folders in the container or on the server (names only). Asks like
    /// Follow does on production and before connecting.
    func findRemoteLogs() {
        guard let target = logViewer.target else { return }
        let key = target.stableKey
        guard !logViewer.finding.contains(key) else { return }
        if isProduction(target) {
            let alert = NSAlert()
            alert.messageText = "List log files on production?"
            alert.informativeText = "“\(targetLabel(target))” is marked as production. Runlet lists the names of its log files with `find` and reads nothing else."
            alert.addButton(withTitle: "Find Logs")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        logViewer.finding.insert(key)
        Task {
            defer { self.logViewer.finding.remove(key) }
            do {
                let paths = try await self.listRemoteLogs(target)
                self.logViewer.found[key] = paths
                self.logViewer.lastEvent = "found \(paths.count)"
            } catch {
                self.alert = AppAlert(title: "Couldn't list the log files", message: "\(error)")
                self.logViewer.lastEvent = "find failed: \(error)"
            }
        }
    }

    private func listRemoteLogs(_ target: TargetRef) async throws -> [String] {
        let extra = driverLogPaths(for: target).filter { !$0.contains("*") }
        switch target {
        case .docker(let id):
            guard let profile = library.dockerProfile(id), let docker else { throw TargetResolutionError(description: "Docker isn't available.") }
            let container = try await logContainer(profile: profile, docker: docker)
            var arguments = ["exec"]
            if let user = profile.user, !user.isEmpty { arguments += ["--user", user] }
            arguments += [container.id, "/bin/sh", "-c", LogFollowCommand.findScript(directory: profile.workingDirectory, extra: extra)]
            return LogFollowCommand.parseFound(String(decoding: try await docker.run(arguments, timeout: .seconds(30)), as: UTF8.self))
        case .ssh(let id):
            guard let profile = library.sshProfile(id) else { throw TargetResolutionError(description: "This SSH profile was removed.") }
            try await ensureLogConnection(profile)
            if let step = profile.container {
                let container = try await logRemoteContainer(profile: profile, step: step)
                var arguments = ["exec"]
                if let user = step.user, !user.isEmpty { arguments += ["--user", user] }
                arguments += [container.id, "/bin/sh", "-c", LogFollowCommand.findScript(directory: step.workingDirectory, extra: extra)]
                return LogFollowCommand.parseFound(String(decoding: try await remoteDocker(for: profile, step: step).run(arguments, timeout: .seconds(30)), as: UTF8.self))
            }
            let result = try await sshClient.run(sshEndpoint(for: profile), remoteCommand: RemoteShell.command(LogFollowCommand.findScript(directory: profile.remoteDirectory, extra: extra)), timeout: .seconds(30))
            guard result.exitCode == 0 else {
                let output = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw TargetResolutionError(description: SSHFailure.explain(output, exitCode: result.exitCode, host: profile.destinationLabel) ?? output)
            }
            refreshSSHStatus(profile.id)
            return LogFollowCommand.parseFound(String(decoding: result.stdout, as: UTF8.self))
        case .sandbox, .local:
            return []
        }
    }

    /// Other Path…: a path typed by the user (on this Mac, in the container, or on the server).
    func addOtherLogPath(_ path: String) {
        guard let target = logViewer.target else { return }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = target.stableKey
        var paths = logViewer.otherPaths[key] ?? []
        if !paths.contains(trimmed) { paths.insert(trimmed, at: 0) }
        logViewer.otherPaths[key] = paths
        let base = logHostFolder(for: target)
        if let base, !trimmed.hasPrefix("/") {
            let absolute = (base as NSString).appendingPathComponent(trimmed)
            openLogSource(LogSource(kind: .hostFile(absolute), title: trimmed, detail: "Other path", group: .thisMac))
            return
        }
        if let source = logSources(for: target).first(where: { $0.path == trimmed || ($0.path?.hasSuffix("/" + trimmed) ?? false) }) {
            openLogSource(source)
        }
    }

    // MARK: Logs written by the last run

    /// A run started on `target` (`startRun`): while the Logs window was opened this session,
    /// the sizes of the target's log files on this Mac are noted.
    func logRunStarted(_ target: TargetRef, tabTitle: String) {
        guard logViewer.wasOpened else { return }
        var mark = LogRunMark(startedAt: Date(), tabTitle: tabTitle)
        for path in logHostPaths(for: target) {
            if let info = LogFileIdentity.of(path: path) {
                mark.startSizes[path] = info.size
                mark.identities[path] = info.identity
            } else {
                // A file the run creates starts empty.
                mark.startSizes[path] = 0
            }
        }
        logViewer.runMarks[target.stableKey] = mark
    }

    /// The run on `target` ended: where its log files end now.
    func logRunEnded(_ target: TargetRef) {
        let key = target.stableKey
        guard logViewer.wasOpened, var mark = logViewer.runMarks[key], mark.endedAt == nil else { return }
        mark.endedAt = Date()
        for path in mark.startSizes.keys {
            if let info = LogFileIdentity.of(path: path) { mark.endSizes[path] = info.size }
        }
        logViewer.runMarks[key] = mark
        if logViewer.target == target, logViewer.showsLastRun {
            // Writes may land a moment after the run's end.
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                self.refreshLastRun()
            }
        }
    }

    /// The target's log files on this Mac that a run is measured on: the ones found, and the
    /// open one.
    private func logHostPaths(for target: TargetRef) -> [String] {
        var paths = (logViewer.hostCandidates[target.stableKey] ?? []).map(\.path)
        if logViewer.target == target, case .hostFile(let path)? = logViewer.session?.source.kind, !paths.contains(path) { paths.append(path) }
        return paths
    }

    /// The last run on `target`: Runlet's own mark, else the most recent finished run of a tab
    /// on it.
    func lastLogRun(for target: TargetRef) -> LogRunMark? {
        if let mark = logViewer.runMarks[target.stableKey] { return mark }
        var best: LogRunMark?
        for tab in allTabs where (tab.inspectionTarget ?? tab.target) == target {
            switch tab.runState {
            case .finished(let info):
                guard let start = info.startedAt else { continue }
                let mark = LogRunMark(startedAt: start, endedAt: start.addingTimeInterval(Double(info.elapsedMs) / 1000), tabTitle: tab.title)
                if best.map({ $0.startedAt < mark.startedAt }) ?? true { best = mark }
            case .running(_, let start), .stopping(_, let start):
                let mark = LogRunMark(startedAt: start, endedAt: nil, tabTitle: tab.title)
                if best.map({ $0.startedAt < mark.startedAt }) ?? true { best = mark }
            default:
                break
            }
        }
        return best
    }

    /// Recomputes "Logs written by the last run" for the open source: the bytes the run added
    /// to a file on this Mac are read again; otherwise the list is filtered by time.
    func refreshLastRun() {
        guard let session = logViewer.session else { return }
        guard logViewer.showsLastRun, let mark = lastLogRun(for: session.target) else {
            session.runEntries = nil
            session.runNote = logViewer.showsLastRun ? "No run on \(targetLabel(session.target)) yet in this session." : nil
            return
        }
        let when = mark.startedAt.formatted(date: .omitted, time: .standard)
        if case .hostFile(let path) = session.source.kind, let start = mark.startSizes[path] {
            let end = mark.endSizes[path] ?? LogFileIdentity.of(path: path)?.size ?? start
            let sameFile = mark.identities[path].map { $0 == LogFileIdentity.of(path: path)?.identity } ?? true
            if sameFile, end >= start {
                session.runNote = "Lines the run of “\(mark.tabTitle)” at \(when) added to this file\(mark.endedAt == nil ? " (still running)" : "")."
                let read = Task.detached(priority: .userInitiated) { () -> [LogEntry] in
                    let chunk = try? LogTail.read(path: path, range: start..<end)
                    var buffer = LogBuffer()
                    buffer.begin(at: chunk?.start ?? start)
                    if let chunk { buffer.append(chunk.data) }
                    buffer.flush()
                    return buffer.entries
                }
                Task { session.runEntries = await read.value }
                return
            }
        }
        session.runEntries = nil
        session.runNote = session.source.isRemote
            ? "Lines that arrived while following during the run of “\(mark.tabTitle)” at \(when), or whose time falls in it."
            : "Entries whose time falls in the run of “\(mark.tabTitle)” at \(when). Times without a zone are read in this Mac's time zone."
    }

    /// The filter's run window for the open source.
    var logRunWindow: LogRunWindow? {
        guard logViewer.showsLastRun, let session = logViewer.session, let mark = lastLogRun(for: session.target) else { return nil }
        return LogRunWindow(startedAt: mark.startedAt, endedAt: mark.endedAt)
    }

    /// What the list shows now: the run's own entries or the filtered buffer.
    func visibleLogEntries(_ session: LogSession) -> [LogEntry] {
        var filter = logViewer.filter
        if logViewer.showsLastRun {
            if let run = session.runEntries { return filter.apply(run) }
            filter.run = logRunWindow ?? LogRunWindow(startedAt: .distantFuture, endedAt: .distantFuture)
        }
        return filter.apply(session.shownEntries)
    }

    // MARK: Frames

    /// How paths written by the target's application map to this Mac (as the output's file
    /// links do, without a tab).
    func logPathMapping(for target: TargetRef) -> EditorPathMapping {
        switch target {
        case .sandbox, .local:
            return .host
        case .docker(let id):
            let profile = library.dockerProfile(id)
            return .container(root: profile?.workingDirectory ?? "/", hostRoot: profile?.localSourcePath)
        case .ssh(let id):
            let profile = library.sshProfile(id)
            if let step = profile?.container {
                return .remote(roots: [step.workingDirectory], localRoot: library.localFolder(for: target), host: "\(step.identity.displayName) on \(profile?.destinationLabel ?? "the server")")
            }
            return .remote(roots: [profile?.remoteDirectory], localRoot: library.localFolder(for: target), host: profile?.destinationLabel ?? "the server")
        }
    }

    /// Finds a frame's file on this Mac with #8's `FrameSourceResolver`: the target's path
    /// mapping, whether the file is a local copy of a container's or server's, and whether it is
    /// project code, vendor code, or outside the project.
    func logFrameResolver(for target: TargetRef) -> FrameSourceResolver {
        let mapping = logPathMapping(for: target)
        switch target {
        case .sandbox, .local:
            return FrameSourceResolver(mapping: mapping, readsLocalCopy: false, projectRoot: logHostFolder(for: target))
        case .docker, .ssh:
            return FrameSourceResolver(mapping: mapping)
        }
    }

    /// Where a frame opens: a file on this Mac, a tab's line for a snippet frame, or why it can't.
    enum LogFrameDestination {
        case file(FrameSourceFile, line: Int?)
        case tabLine(TabModel, line: Int)
        case unavailable(String)
    }

    func logFrameDestination(_ frame: LogFrame, target: TargetRef) -> LogFrameDestination {
        if let snippetLine = frame.snippetLine {
            let tabs = allTabs.filter { ($0.inspectionTarget ?? $0.target) == target && $0.currentRequestForDisplay != nil }
            guard let tab = tabs.first(where: { $0.id == selectedTab?.id }) ?? tabs.first, let request = tab.currentRequestForDisplay else {
                return .unavailable("A line of a snippet that ran on \(targetLabel(target)); no tab has run there in this session.")
            }
            return .tabLine(tab, line: request.editorLine(forSnippetLine: snippetLine))
        }
        switch logFrameResolver(for: target).locate(frame.path) {
        case .file(let file): return .file(file, line: frame.line)
        case .unavailable(_, let reason): return .unavailable(reason)
        case .none: return .unavailable("“\(frame.path)” is not a file on disk.")
        }
    }

    /// Opens a frame of entry `entryId`: what `openLogFrame` doesn't open itself is read off the
    /// main thread and shown in the read-only peek next to the entry.
    func openLogFrame(_ frame: LogFrame, target: TargetRef, entryId: Int) {
        guard let (file, line) = openLogFrame(frame, target: target) else { return }
        Task {
            guard let peek = await ExcerptPeek.load(file, line: line) else {
                self.logViewer.lastEvent = "peek unreadable: \(file.displayPath)"
                return
            }
            self.logViewer.peekEntryId = entryId
            self.logViewer.peek = peek
        }
    }

    /// Project files open in the external editor, as error cards' frames do (#8); vendor code,
    /// files outside the project, and every file when no editor is set open in the read-only peek.
    func logFrameOpensInEditor(_ file: FrameSourceFile) -> Bool {
        file.origin == .project && settings.externalEditor != .none
    }

    /// Opens a frame: the tab's line, or a project file in the external editor. Returns the file
    /// to show in the read-only peek instead (the window presents it).
    @discardableResult
    func openLogFrame(_ frame: LogFrame, target: TargetRef) -> (FrameSourceFile, line: Int)? {
        let destination = logFrameDestination(frame, target: target)
        #if DEBUG
        if LogDebugSteps.logsFrames {
            switch destination {
            case .file(let file, let line): logViewer.lastEvent = "would \(logFrameOpensInEditor(file) ? "open" : "peek") \(file.displayPath):\(line ?? 0)\(file.isLocalCopy ? " (local copy)" : "")"
            case .tabLine(let tab, let line): logViewer.lastEvent = "would go to line \(line) of \(tab.title)"
            case .unavailable(let reason): logViewer.lastEvent = "unavailable: \(reason)"
            }
            return nil
        }
        #endif
        switch destination {
        case .file(let file, let line):
            if logFrameOpensInEditor(file) {
                openInExternalEditor(path: file.hostPath, line: line)
                logViewer.lastEvent = "open \(file.displayPath):\(line ?? 0)"
                return nil
            }
            logViewer.lastEvent = "peek \(file.displayPath):\(line ?? 0)"
            return (file, max(1, line ?? 1))
        case .tabLine(let tab, let line):
            revealTab(tab.id)
            tab.editor.goTo(line: line)
            logViewer.lastEvent = "line \(line) of \(tab.title)"
        case .unavailable(let reason):
            logViewer.lastEvent = "unavailable: \(reason)"
            NSSound.beep()
        }
        return nil
    }
}

// MARK: - Connection Manager (#180)

/// Remote log follows (#20): `docker logs`, `docker exec … tail -F`, `ssh … tail -F`. Close is
/// the Logs window's Stop. Files on this Mac open no connection and aren't listed.
struct LogFollowConnectionProvider: ConnectionProvider {
    let prefix = "log:"

    func connections(in model: AppModel) -> [ActiveConnection] {
        guard let session = model.logViewer.session, session.source.isRemote, case .following(let since) = session.state else { return [] }
        return [ActiveConnection(
            id: "log:\(session.id)", kind: .logFollow, title: session.source.title, destination: session.destination,
            owner: "Logs window · \(model.targetLabel(session.target))", startedAt: since, environment: session.environment,
            details: ["Read-only (\(session.source.commandName)); stops when the Logs window closes"], via: session.via
        )]
    }

    func close(_ id: String, in model: AppModel) {
        guard let session = model.logViewer.session, id == "log:\(session.id)" else { return }
        model.stopFollowingLog()
    }
}
