import Darwin
import Foundation
import RunletCore

public struct CancelOutcome: Sendable, Equatable {
    /// True when Runlet confirmed the PHP process ended.
    public var confirmed: Bool
    public var message: String
    /// An SQL run's statement cancelled on the database server first (#144); nil when the run
    /// reported no database session (SQLite, a callable connection, a PHP tab).
    public var server: SQLCancelReport? = nil
}

public enum ExecutionError: Error, CustomStringConvertible, Sendable, Equatable {
    case tabBusy
    case dockerUnavailable
    case invalidTarget(String)

    public var description: String {
        switch self {
        case .tabBusy: "This tab already has a run in progress. Stop it or wait for it to finish."
        case .dockerUnavailable: "The Docker CLI was not found. Install Docker Desktop or OrbStack, or set its path in Settings."
        case .invalidTarget(let message): message
        }
    }
}

/// How a prepared run is launched and stopped.
struct PreparedLaunch: Sendable {
    var spec: ProcessSpec
    var stop: @Sendable (SupervisedProcess, RunControl) async -> CancelOutcome
    /// Turns the transport's own failure output (e.g. `ssh` exit 255 with OpenSSH's message)
    /// into a plain explanation: (end of stderr, exit code, the runner had started). nil keeps
    /// the default message.
    var explainFailure: (@Sendable (String, Int32, Bool) -> String?)?

    init(spec: ProcessSpec, stop: @escaping @Sendable (SupervisedProcess, RunControl) async -> CancelOutcome, explainFailure: (@Sendable (String, Int32, Bool) -> String?)? = nil) {
        self.spec = spec
        self.stop = stop
        self.explainFailure = explainFailure
    }
}

/// Runs snippets against sandbox, local, Docker, and SSH targets through the shared runner.
///
/// One active run per tab; runs in different tabs execute concurrently up to
/// `maxConcurrentRuns`, beyond which they wait for a free slot, in order (#183: `slots`, and
/// `slotChanges` for the app, which lists a waiting run as queued).
public actor ExecutionEngine {
    public let bundle: RunnerBundle
    public var limits: RunLimits
    public let maxConcurrentRuns: Int
    private var docker: DockerCLI?
    private var ssh: SSHClient
    /// Saved database connections' passwords (#138), read only while a run's script is built.
    let credentials: CredentialStore?

    private struct ActiveRun {
        var tabId: UUID
        var session: RunSession
        var process: SupervisedProcess?
        var launch: PreparedLaunch?
        /// #144: what the run was asked to do and where it launched, so Stop on an SQL run can
        /// cancel its statement on the server from a second runner on the same target.
        var request: RunRequest?
        var target: TargetSnapshot?
    }

    private var active: [UUID: ActiveRun] = [:]
    /// #183: runs holding a slot, and runs waiting for one in the order they get it. A run is
    /// admitted to one or the other as it's accepted, so it is never in neither while it waits.
    private var slotHolders: [UUID: RunSlots.Entry] = [:]
    private var slotQueue: [RunSlots.Entry] = []
    /// Queued runs' launch tasks waiting for their slot: true when they got it, false when
    /// Stop or Close took them out of the queue first.
    private var slotWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private let slotContinuation: AsyncStream<RunSlots>.Continuation

    /// The run slots after every change (#183): a run joined the queue, got a slot, or ended.
    /// Keeps only the newest value, so a reader that falls behind skips to the current one.
    /// One reader (the app).
    public nonisolated let slotChanges: AsyncStream<RunSlots>

    public init(bundle: RunnerBundle, docker: DockerCLI?, ssh: SSHClient = SSHClient(), limits: RunLimits = RunLimits(), maxConcurrentRuns: Int = 4, credentials: CredentialStore? = nil) {
        self.bundle = bundle
        self.docker = docker
        self.ssh = ssh
        self.limits = limits
        self.maxConcurrentRuns = maxConcurrentRuns
        self.credentials = credentials
        (slotChanges, slotContinuation) = AsyncStream.makeStream(of: RunSlots.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// The run slots now (#183): which runs run and which wait for a slot.
    public var slots: RunSlots {
        RunSlots(limit: maxConcurrentRuns, running: slotHolders.values.sorted { $0.since < $1.since }, queued: slotQueue)
    }

    public func setDocker(_ docker: DockerCLI?) {
        self.docker = docker
    }

    public func setSSH(_ ssh: SSHClient) {
        self.ssh = ssh
    }

    public func isTabRunning(_ tabId: UUID) -> Bool {
        active.values.contains { $0.tabId == tabId }
    }

    public var activeRunIds: [UUID] { Array(active.keys) }

    /// Accepts a run and returns its event stream. The stream always ends with `finished`.
    /// A run with a saved connection (#138) gets its password from the credential store while
    /// the script is built, after the run was admitted; the script reaches PHP only on stdin.
    public func start(_ request: RunRequest) throws -> AsyncStream<RunEvent> {
        guard !isTabRunning(request.tabId) else { throw ExecutionError.tabBusy }
        try LocalConnectionLaunch.check(request.sqlConnection, target: request.target) // #142
        let session = RunSession(runId: request.runId, limits: limits)
        try launch(session, tabId: request.tabId, target: request.target, script: Self.script(for: request, credentials: credentials))
        active[request.runId]?.request = request
        return session.events
    }

    /// The runner script of `request`: on a saved connection (#138) with its password read from
    /// `credentials` while the script is built, else the run's own options. Shared by runs and
    /// Stop's cancel runner (#144).
    static func script(for request: RunRequest, credentials: CredentialStore?) -> @Sendable (RunnerBundle, String, RunLimits) throws -> Data {
        { bundle, nonce, limits in
            if let saved = request.sqlConnection {
                let connection = try Self.runnerConnection(saved, password: .stored, credentials: credentials, tunnel: request.target.sqlTunnel)
                return bundle.script(code: request.code, nonce: nonce, runId: request.runId, magicComments: false, limits: limits, sqlConnection: connection, sqlBatches: request.sqlBatches)
            }
            return bundle.script(code: request.code, nonce: nonce, runId: request.runId, strictTypes: request.strictTypes, inspector: request.inspector, hints: request.hints, profile: request.profile, magicComments: request.magicComments, limits: limits, sqlBatches: request.sqlBatches)
        }
    }

    /// Where a saved connection's password comes from (#138).
    public enum SQLPassword: Sendable {
        /// The credential store (a run, Load Schema, Test Connection of a saved connection).
        case stored
        /// Typed in the connection editor and not saved yet (Test Connection); nil for none.
        case given(SensitiveString?)
    }

    /// The definition with its password, read from `credentials` now. A store that can't be
    /// read (Deny, a locked keychain) stops the run before PHP starts, with the reason.
    /// `tunnel` (#143) is the run's local forward (`target.sqlTunnel`), for a connection through
    /// an SSH tunnel; every caller passes it, so no path can open such a connection directly.
    static func runnerConnection(_ definition: DatabaseConnection, password: SQLPassword, credentials: CredentialStore?, tunnel: SQLTunnelRoute?) throws -> RunnerSQLConnection {
        switch password {
        case .given(let secret):
            return RunnerSQLConnection(definition: definition, password: secret, tunnel: tunnel)
        case .stored:
            guard let credentials else { return RunnerSQLConnection(definition: definition, password: nil, tunnel: tunnel) }
            do {
                return RunnerSQLConnection(definition: definition, password: try credentials.read(definition.id), tunnel: tunnel)
            } catch {
                throw ExecutionError.invalidTarget("The password of the saved connection “\(definition.name)” couldn't be read, so nothing ran. \(error)")
            }
        }
    }

    /// Admits one runner process for `session` and launches it on a free slot. Shared by
    /// runs and command listing; `cancel(runId:)` and `cancelAll()` stop either. `makeScript`
    /// runs once a slot is free; when it throws, the run fails before any process starts.
    /// `usesSlot: false` (Stop's cancel runner, #144) launches at once, past the run limit.
    func launch(_ session: RunSession, tabId: UUID, target: TargetSnapshot, usesSlot: Bool = true, script makeScript: @escaping @Sendable (RunnerBundle, String, RunLimits) throws -> Data) throws {
        if [.docker, .sandboxDocker].contains(target.kind), docker == nil { throw ExecutionError.dockerUnavailable }

        let runId = session.runId
        active[runId] = ActiveRun(tabId: tabId, session: session, target: target)
        if usesSlot { admit(RunSlots.Entry(runId: runId, tabId: tabId, since: Date()), session: session) }
        // #143: the Run Log says which forward the run's connection goes through.
        if let tunnel = target.sqlTunnel {
            session.inject(.log(RunLogEntry(source: "tunnel", message: tunnel.forwardCommand.isEmpty ? "ssh -O forward -L \(SSHForwardSpec(localPort: tunnel.localPort, remoteHost: tunnel.remoteHost, remotePort: tunnel.remotePort).argument)" : tunnel.forwardCommand,
                                            detail: "\(tunnel.reused ? "Reused" : "Added") the SSH tunnel \(tunnel.summary); this Mac's PHP connects to it, and the database password goes only to that PHP, on stdin.")))
        }
        let docker = self.docker
        let ssh = self.ssh
        let bundle = self.bundle
        let limits = self.limits

        Task.detached { [weak self] in
            guard let self else { return }
            defer { Task { await self.releaseSlot(runId) } }
            // #183: a queued run waits here; Stop or Close takes it out of the queue instead.
            if usesSlot, !(await self.waitForSlot(runId)) {
                session.cancelBeforeLaunch()
                return
            }

            if session.control.cancelRequested {
                session.cancelBeforeLaunch()
                return
            }
            let nonce = RunnerBundle.makeNonce()
            var script: Data
            do {
                script = try makeScript(bundle, nonce, limits)
            } catch {
                session.failLaunch("\(error)")
                return
            }
            var prepared: PreparedLaunch
            do {
                prepared = try await Self.prepare(target: target, runId: runId, script: script, docker: docker, ssh: ssh)
            } catch {
                session.failLaunch("\(error)")
                return
            }
            // The Run Log gets the command line and the script's size only: the script (and a
            // saved connection's password in its request, #138) goes to PHP on stdin.
            session.logLaunch(prepared.spec, scriptBytes: script.count)
            if session.control.cancelRequested {
                session.cancelBeforeLaunch()
                return
            }
            let process: SupervisedProcess
            do {
                process = try SupervisedProcess.launch(prepared.spec)
            } catch {
                session.failLaunch("\(error)")
                return
            }
            // The process writes its own copy to stdin; the engine keeps none for the run.
            script = Data()
            prepared.spec.standardInput = nil
            let launched = prepared
            session.failureExplainer = launched.explainFailure
            await self.attach(runId: runId, process: process, launch: launched)
            if session.control.cancelRequested {
                // Stop arrived while launching.
                Task.detached { _ = await launched.stop(process, session.control) }
            }
            await session.pump(process, nonce: nonce)
        }
    }

    /// Stops a run: graceful termination, then forced after ~1.5 s. Never stops the
    /// user's application container. An SQL tab's run that reported its database session
    /// first has its statement cancelled on the server (#144, `cancelOnServer`), within
    /// `SQLCancel.timeout`; the process is stopped either way.
    public func cancel(runId: UUID) async -> CancelOutcome? {
        guard let run = active[runId] else { return nil }
        let first = run.session.control.markFirstCancelRequest()
        // #183: a run still waiting for a slot leaves the queue. Nothing was launched or sent,
        // so there is nothing to cancel on a server.
        if slotQueue.contains(where: { $0.runId == runId }) {
            let message = "Removed from the queue before it started; nothing was sent."
            run.session.inject(.log(RunLogEntry(source: "queue", message: message)))
            dequeue(runId)
            return CancelOutcome(confirmed: true, message: message)
        }
        guard let process = run.process, let launch = run.launch else {
            return CancelOutcome(confirmed: true, message: "Stopped before the PHP process launched.")
        }
        var server: SQLCancelReport?
        if first, !process.hasExited, let sql = run.session.control.sqlSession, let plan = SQLCancel.plan(for: sql), let request = run.request, let target = run.target {
            server = await cancelOnServer(plan, sql: sql, request: request, target: target, session: run.session, process: process)
        }
        var outcome = await launch.stop(process, run.session.control)
        if !outcome.confirmed { run.session.control.setCancelNote(outcome.message) }
        outcome.server = server
        return outcome
    }

    /// Stops every active run (used on quit), at the same time.
    public func cancelAll() async {
        let runIds = Array(active.keys)
        await withTaskGroup(of: Void.self) { group in
            for runId in runIds {
                group.addTask { _ = await self.cancel(runId: runId) }
            }
        }
    }

    /// The database session an SQL tab's run reported (#144), once it has.
    public func sqlSession(runId: UUID) -> SQLSessionInfo? {
        active[runId]?.session.control.sqlSession
    }

    private func attach(runId: UUID, process: SupervisedProcess, launch: PreparedLaunch) {
        active[runId]?.process = process
        active[runId]?.launch = launch
    }

    // MARK: Run slots (#183)

    /// A slot for `entry` now when one is free, else a place at the end of the queue; the
    /// queued run's Run Log says why it waits.
    private func admit(_ entry: RunSlots.Entry, session: RunSession) {
        if slotHolders.count < maxConcurrentRuns, slotQueue.isEmpty {
            slotHolders[entry.runId] = entry
        } else {
            slotQueue.append(entry)
            session.inject(.log(RunLogEntry(source: "queue", message: "Waiting for a free run slot",
                                            detail: RunSlots.waitingText(running: slotHolders.count, limit: maxConcurrentRuns, position: slotQueue.count))))
        }
        publishSlots()
    }

    /// Waits until `runId` holds a slot: true then, false when it left the queue first.
    private func waitForSlot(_ runId: UUID) async -> Bool {
        if slotHolders[runId] != nil { return true }
        guard slotQueue.contains(where: { $0.runId == runId }) else { return false }
        return await withCheckedContinuation { slotWaiters[runId] = $0 }
    }

    /// Takes a queued run out of the queue; its launch task ends without starting anything.
    private func dequeue(_ runId: UUID) {
        guard let index = slotQueue.firstIndex(where: { $0.runId == runId }) else { return }
        slotQueue.remove(at: index)
        slotWaiters.removeValue(forKey: runId)?.resume(returning: false)
        publishSlots()
    }

    /// Hands free slots to the queue's first runs; "since" becomes when each got its slot.
    private func grantFreeSlots() {
        while slotHolders.count < maxConcurrentRuns, !slotQueue.isEmpty {
            var entry = slotQueue.removeFirst()
            let now = Date()
            let waited = ConnectionText.elapsed(since: entry.since, now: now)
            entry.since = now
            slotHolders[entry.runId] = entry
            active[entry.runId]?.session.inject(.log(RunLogEntry(source: "queue", message: "Got a run slot after waiting \(waited)")))
            slotWaiters.removeValue(forKey: entry.runId)?.resume(returning: true)
        }
    }

    private func releaseSlot(_ runId: UUID) {
        active[runId] = nil
        let held = slotHolders.removeValue(forKey: runId) != nil
        if !held, slotQueue.contains(where: { $0.runId == runId }) {
            dequeue(runId)
            return
        }
        guard held else { return }
        grantFreeSlots()
        publishSlots()
    }

    private func publishSlots() {
        slotContinuation.yield(slots)
    }

    // MARK: - Adapters

    static func prepare(target: TargetSnapshot, runId: UUID, script: Data, docker: DockerCLI?, ssh: SSHClient) async throws -> PreparedLaunch {
        switch target.kind {
        case .local, .sandboxLocal:
            return try LocalAdapter.prepare(target: target, runId: runId, script: script)
        case .docker:
            guard let docker else { throw ExecutionError.dockerUnavailable }
            return try await DockerExecAdapter.prepare(target: target, runId: runId, script: script, docker: docker)
        case .sandboxDocker:
            guard let docker else { throw ExecutionError.dockerUnavailable }
            return try DockerSandboxAdapter.prepare(target: target, runId: runId, script: script, docker: docker)
        case .ssh:
            guard target.containerId != nil else {
                return try SSHExecAdapter.prepare(target: target, runId: runId, script: script, ssh: ssh)
            }
            // A container on the SSH host: the Docker adapter, unchanged, with Docker called
            // through ssh (its re-check, `docker exec -i`, and Stop all go to the server).
            guard let endpoint = target.ssh else { throw ExecutionError.invalidTarget("This SSH target has no host.") }
            let remote = DockerCLI(ssh: ssh, endpoint: endpoint, dockerCommand: target.dockerCommand ?? "docker")
            var prepared = try await DockerExecAdapter.prepare(target: target, runId: runId, script: script, docker: remote)
            let host = endpoint.displayName
            prepared.explainFailure = { output, exitCode, afterStart in
                if afterStart { return SSHFailure.explain(output, exitCode: exitCode, host: host, afterStart: true) }
                return remote.explainFailure(output, exitCode: exitCode)
            }
            return prepared
        }
    }
}

/// Host PHP in the project directory.
enum LocalAdapter {
    static func prepare(target: TargetSnapshot, runId: UUID, script: Data) throws -> PreparedLaunch {
        guard let php = ExecutableLocator.resolve(target.phpExecutable) else {
            throw ExecutionError.invalidTarget("PHP executable not found: \(target.phpExecutable). Choose a PHP binary in Settings or the project's options.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.workingDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ExecutionError.invalidTarget("Project directory not found: \(target.workingDirectory)")
        }
        var environment = ExecutableLocator.toolEnvironment(prepending: [(php as NSString).deletingLastPathComponent])
        environment["RUNLET_RUN_ID"] = runId.uuidString
        let spec = ProcessSpec(executable: php, arguments: RunnerBundle.phpArguments, environment: environment, workingDirectory: target.workingDirectory, standardInput: script, newProcessGroup: true)
        return PreparedLaunch(spec: spec) { process, _ in
            // The runner leads its own process group, so snippet-spawned children receive the signal too.
            if await process.terminate() != nil {
                return CancelOutcome(confirmed: true, message: "Stopped.")
            }
            return CancelOutcome(confirmed: false, message: "The PHP process (pid \(process.pid)) did not exit after SIGKILL.")
        }
    }
}

/// `docker exec` into an existing application container.
enum DockerExecAdapter {
    static func prepare(target: TargetSnapshot, runId: UUID, script: Data, docker: DockerCLI) async throws -> PreparedLaunch {
        guard let containerId = target.containerId else { throw ExecutionError.invalidTarget("No container is resolved for this profile.") }
        // Recheck the snapshotted container right before launch: never run in a different one.
        // A failing `docker` (or ssh, for a container on an SSH host) says why.
        let found: ContainerInfo?
        do {
            found = try await docker.inspect([containerId]).first
        } catch {
            throw ExecutionError.invalidTarget("\(error)")
        }
        guard let info = found else {
            throw ExecutionError.invalidTarget("Container \(target.containerName ?? String(containerId.prefix(12))) no longer exists. Reopen the profile to resolve its replacement.")
        }
        guard info.running else {
            throw ExecutionError.invalidTarget("Container \(info.name) is not running (\(info.status)).")
        }
        var arguments = ["exec", "-i", "--env", "RUNLET_RUN_ID=\(runId.uuidString)", "--workdir", target.workingDirectory]
        // The profile's writable directory becomes TMPDIR (sys_get_temp_dir(), tempnam(), …),
        // which matters for read-only containers. Runlet itself writes nothing there.
        if let temporary = target.temporaryDirectory, !temporary.isEmpty {
            arguments += ["--env", "TMPDIR=\(temporary)"]
        }
        if let user = target.user, !user.isEmpty { arguments += ["--user", user] }
        arguments += [containerId, target.phpExecutable] + RunnerBundle.phpArguments
        let spec = docker.spec(arguments, stdin: script)
        return PreparedLaunch(spec: spec) { process, control in
            await stopInContainer(docker: docker, containerId: containerId, user: target.user, php: target.phpExecutable, runId: runId, process: process, control: control)
        }
    }

    /// PHP program run via a separate `docker exec` to signal the tracked runner. It checks
    /// the PID still belongs to this run (via its RUNLET_RUN_ID environment) before signaling,
    /// and uses posix_kill or the shell's `kill`, whichever exists.
    static var signalHelper: String { RemoteSignal.runnerOnlyHelper }

    static func signal(docker: DockerCLI, containerId: String, user: String?, php: String, pid: Int, runId: UUID, signal: Int32) async -> String {
        var arguments = ["exec"]
        if let user, !user.isEmpty { arguments += ["--user", user] }
        arguments += [containerId, php, "-r", docker.phpCode(signalHelper), "--", String(pid), runId.uuidString, String(signal)]
        guard let result = try? await runCommand(docker.spec(arguments), timeout: .seconds(5)) else { return "error" }
        let text = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.exitCode != 0 {
            let stderr = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return "error: \(stderr.isEmpty ? "exit \(result.exitCode)" : stderr)"
        }
        return text
    }

    static func stopInContainer(docker: DockerCLI, containerId: String, user: String?, php: String, runId: UUID, process: SupervisedProcess, control: RunControl) async -> CancelOutcome {
        guard let pid = await control.waitForRunnerPid(timeout: .seconds(2)) else {
            let message = "The runner had not reported its process ID, so only the local docker client was stopped; PHP may still be starting inside the container."
            control.setCancelNote(message)
            await process.terminate(grace: .milliseconds(300))
            return CancelOutcome(confirmed: false, message: message)
        }

        var outcome = await signal(docker: docker, containerId: containerId, user: user, php: php, pid: pid, runId: runId, signal: SIGTERM)
        if outcome == "unsupported" || outcome.hasPrefix("error") || outcome == "failed" {
            let message = "Could not signal PHP inside the container (\(outcome)). The docker client was stopped, but the runner (pid \(pid)) may still be running."
            control.setCancelNote(message)
            await process.terminate(grace: .milliseconds(300))
            return CancelOutcome(confirmed: false, message: message)
        }
        if outcome != "gone" && outcome != "mismatch" {
            // `docker exec` returns once the runner exits.
            if !(await process.waitForExit(within: .milliseconds(1500))) {
                outcome = await signal(docker: docker, containerId: containerId, user: user, php: php, pid: pid, runId: runId, signal: SIGKILL)
                _ = await process.waitForExit(within: .seconds(3))
            }
        }
        let check = await signal(docker: docker, containerId: containerId, user: user, php: php, pid: pid, runId: runId, signal: 0)
        let confirmed = check == "gone" || check == "mismatch"
        let message = confirmed ? "Stopped the runner inside the container; the container keeps running." : "The runner (pid \(pid)) is still running inside the container (\(check))."
        if !confirmed { control.setCancelNote(message) }
        if !process.hasExited { await process.terminate(grace: .milliseconds(300)) }
        return CancelOutcome(confirmed: confirmed, message: message)
    }
}

/// The Laravel sandbox in a disposable `php` container when no compatible host PHP exists.
enum DockerSandboxAdapter {
    static func containerName(for runId: UUID) -> String {
        "runlet-sandbox-\(runId.uuidString.prefix(8).lowercased())"
    }

    static func prepare(target: TargetSnapshot, runId: UUID, script: Data, docker: DockerCLI) throws -> PreparedLaunch {
        guard let hostDirectory = target.hostMountDirectory, let image = target.image else {
            throw ExecutionError.invalidTarget("The Docker sandbox is not configured.")
        }
        let name = containerName(for: runId)
        let arguments = [
            // --init: PID 1 is a tiny init that forwards signals, so PHP is never PID 1 (which
            // would ignore SIGTERM).
            "run", "--rm", "-i", "--init", "--name", name,
            "--label", "dev.runlet.owned=sandbox",
            "--env", "RUNLET_RUN_ID=\(runId.uuidString)",
            "--volume", "\(hostDirectory):\(target.workingDirectory)",
            "--workdir", target.workingDirectory,
            image, target.phpExecutable,
        ] + RunnerBundle.phpArguments
        let spec = docker.spec(arguments, stdin: script)
        return PreparedLaunch(spec: spec) { process, control in
            await stopSandboxContainer(docker: docker, name: name, process: process, control: control)
        }
    }

    /// Stops a Runlet-owned sandbox container. Stop may arrive before `docker run` has created
    /// the container, so `docker kill` is retried until it succeeds or the client exits; as a
    /// last resort the container is force-removed (it belongs to Runlet).
    static func stopSandboxContainer(docker: DockerCLI, name: String, process: SupervisedProcess, control: RunControl) async -> CancelOutcome {
        let deadline = ContinuousClock.now + .seconds(4)
        var killed = false
        while !process.hasExited && ContinuousClock.now < deadline {
            if (try? await docker.run(["kill", name], timeout: .seconds(3))) != nil {
                killed = true
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if killed || process.hasExited {
            if await process.waitForExit(within: .seconds(4)) {
                return CancelOutcome(confirmed: true, message: "Stopped the sandbox container.")
            }
        }
        _ = try? await docker.run(["rm", "-f", name], timeout: .seconds(5))
        if await process.waitForExit(within: .seconds(2)) {
            return CancelOutcome(confirmed: true, message: "Force-removed the sandbox container.")
        }
        let message = "The sandbox container \(name) did not stop in time."
        control.setCancelNote(message)
        await process.terminate()
        return CancelOutcome(confirmed: false, message: message)
    }
}
