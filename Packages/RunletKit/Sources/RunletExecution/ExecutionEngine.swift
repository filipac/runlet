import Darwin
import Foundation
import RunletCore

public struct CancelOutcome: Sendable, Equatable {
    /// True when Runlet confirmed the PHP process ended.
    public var confirmed: Bool
    public var message: String
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
/// `maxConcurrentRuns`, beyond which they wait for a free slot.
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
    }

    private var active: [UUID: ActiveRun] = [:]
    private var runningCount = 0
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []

    public init(bundle: RunnerBundle, docker: DockerCLI?, ssh: SSHClient = SSHClient(), limits: RunLimits = RunLimits(), maxConcurrentRuns: Int = 4, credentials: CredentialStore? = nil) {
        self.bundle = bundle
        self.docker = docker
        self.ssh = ssh
        self.limits = limits
        self.maxConcurrentRuns = maxConcurrentRuns
        self.credentials = credentials
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
        let credentials = self.credentials
        try launch(session, tabId: request.tabId, target: request.target) { bundle, nonce, limits in
            if let saved = request.sqlConnection {
                let connection = try Self.runnerConnection(saved, password: .stored, credentials: credentials)
                return bundle.script(code: request.code, nonce: nonce, runId: request.runId, magicComments: false, limits: limits, sqlConnection: connection)
            }
            return bundle.script(code: request.code, nonce: nonce, runId: request.runId, strictTypes: request.strictTypes, inspector: request.inspector, hints: request.hints, profile: request.profile, magicComments: request.magicComments, limits: limits)
        }
        return session.events
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
    static func runnerConnection(_ definition: DatabaseConnection, password: SQLPassword, credentials: CredentialStore?) throws -> RunnerSQLConnection {
        switch password {
        case .given(let secret):
            return RunnerSQLConnection(definition: definition, password: secret)
        case .stored:
            guard let credentials else { return RunnerSQLConnection(definition: definition, password: nil) }
            do {
                return RunnerSQLConnection(definition: definition, password: try credentials.read(definition.id))
            } catch {
                throw ExecutionError.invalidTarget("The password of the saved connection “\(definition.name)” couldn't be read, so nothing ran. \(error)")
            }
        }
    }

    /// Admits one runner process for `session` and launches it on a free slot. Shared by
    /// runs and command listing; `cancel(runId:)` and `cancelAll()` stop either. `makeScript`
    /// runs once a slot is free; when it throws, the run fails before any process starts.
    func launch(_ session: RunSession, tabId: UUID, target: TargetSnapshot, script makeScript: @escaping @Sendable (RunnerBundle, String, RunLimits) throws -> Data) throws {
        if [.docker, .sandboxDocker].contains(target.kind), docker == nil { throw ExecutionError.dockerUnavailable }

        let runId = session.runId
        active[runId] = ActiveRun(tabId: tabId, session: session)
        let docker = self.docker
        let ssh = self.ssh
        let bundle = self.bundle
        let limits = self.limits

        Task.detached { [weak self] in
            guard let self else { return }
            await self.acquireSlot()
            defer { Task { await self.releaseSlot(runId) } }

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
    /// user's application container.
    public func cancel(runId: UUID) async -> CancelOutcome? {
        guard let run = active[runId] else { return nil }
        run.session.control.markCancelRequested()
        guard let process = run.process, let launch = run.launch else {
            return CancelOutcome(confirmed: true, message: "Stopped before the PHP process launched.")
        }
        let outcome = await launch.stop(process, run.session.control)
        if !outcome.confirmed { run.session.control.setCancelNote(outcome.message) }
        return outcome
    }

    /// Stops every active run (used on quit).
    public func cancelAll() async {
        for runId in active.keys { _ = await cancel(runId: runId) }
    }

    private func attach(runId: UUID, process: SupervisedProcess, launch: PreparedLaunch) {
        active[runId]?.process = process
        active[runId]?.launch = launch
    }

    private func acquireSlot() async {
        if runningCount < maxConcurrentRuns {
            runningCount += 1
            return
        }
        await withCheckedContinuation { slotWaiters.append($0) }
    }

    private func releaseSlot(_ runId: UUID) {
        active[runId] = nil
        if slotWaiters.isEmpty {
            runningCount -= 1
        } else {
            slotWaiters.removeFirst().resume()
        }
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
