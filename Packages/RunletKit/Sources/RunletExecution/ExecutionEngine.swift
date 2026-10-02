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
}

/// Runs snippets against sandbox, local, and Docker targets through the shared runner.
///
/// One active run per tab; runs in different tabs execute concurrently up to
/// `maxConcurrentRuns`, beyond which they wait for a free slot.
public actor ExecutionEngine {
    public let bundle: RunnerBundle
    public var limits: RunLimits
    public let maxConcurrentRuns: Int
    private var docker: DockerCLI?

    private struct ActiveRun {
        var tabId: UUID
        var session: RunSession
        var process: SupervisedProcess?
        var launch: PreparedLaunch?
    }

    private var active: [UUID: ActiveRun] = [:]
    private var runningCount = 0
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []

    public init(bundle: RunnerBundle, docker: DockerCLI?, limits: RunLimits = RunLimits(), maxConcurrentRuns: Int = 4) {
        self.bundle = bundle
        self.docker = docker
        self.limits = limits
        self.maxConcurrentRuns = maxConcurrentRuns
    }

    public func setDocker(_ docker: DockerCLI?) {
        self.docker = docker
    }

    public func isTabRunning(_ tabId: UUID) -> Bool {
        active.values.contains { $0.tabId == tabId }
    }

    public var activeRunIds: [UUID] { Array(active.keys) }

    /// Accepts a run and returns its event stream. The stream always ends with `finished`.
    public func start(_ request: RunRequest) throws -> AsyncStream<RunEvent> {
        guard !isTabRunning(request.tabId) else { throw ExecutionError.tabBusy }
        if [.docker, .sandboxDocker].contains(request.target.kind), docker == nil { throw ExecutionError.dockerUnavailable }

        let session = RunSession(runId: request.runId, limits: limits)
        active[request.runId] = ActiveRun(tabId: request.tabId, session: session)
        let docker = self.docker
        let bundle = self.bundle
        let limits = self.limits

        Task.detached { [weak self] in
            guard let self else { return }
            await self.acquireSlot()
            defer { Task { await self.releaseSlot(request.runId) } }

            if session.control.cancelRequested {
                session.failLaunch("Stopped before launch.")
                return
            }
            let nonce = RunnerBundle.makeNonce()
            let script = bundle.script(code: request.code, nonce: nonce, runId: request.runId, limits: limits)
            let prepared: PreparedLaunch
            do {
                prepared = try await Self.prepare(request, script: script, docker: docker)
            } catch {
                session.failLaunch("\(error)")
                return
            }
            if session.control.cancelRequested {
                session.failLaunch("Stopped before launch.")
                return
            }
            let process: SupervisedProcess
            do {
                process = try SupervisedProcess.launch(prepared.spec)
            } catch {
                session.failLaunch("\(error)")
                return
            }
            await self.attach(runId: request.runId, process: process, launch: prepared)
            if session.control.cancelRequested {
                // Stop arrived while launching.
                Task.detached { _ = await prepared.stop(process, session.control) }
            }
            await session.pump(process, nonce: nonce)
        }
        return session.events
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

    static func prepare(_ request: RunRequest, script: Data, docker: DockerCLI?) async throws -> PreparedLaunch {
        let target = request.target
        switch target.kind {
        case .local, .sandboxLocal:
            return try LocalAdapter.prepare(target: target, runId: request.runId, script: script)
        case .docker:
            guard let docker else { throw ExecutionError.dockerUnavailable }
            return try await DockerExecAdapter.prepare(target: target, runId: request.runId, script: script, docker: docker)
        case .sandboxDocker:
            guard let docker else { throw ExecutionError.dockerUnavailable }
            return try DockerSandboxAdapter.prepare(target: target, runId: request.runId, script: script, docker: docker)
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
        guard let info = await docker.inspect(containerId) else {
            throw ExecutionError.invalidTarget("Container \(target.containerName ?? String(containerId.prefix(12))) no longer exists. Reopen the profile to resolve its replacement.")
        }
        guard info.running else {
            throw ExecutionError.invalidTarget("Container \(info.name) is not running (\(info.status)).")
        }
        var arguments = ["exec", "-i", "--env", "RUNLET_RUN_ID=\(runId.uuidString)", "--workdir", target.workingDirectory]
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
    static let signalHelper = #"""
    $p = (int) $argv[1]; $id = $argv[2]; $sig = (int) $argv[3];
    $stat = @file_get_contents("/proc/$p/stat");
    if ($stat === false) { echo 'gone'; exit(0); }
    if (preg_match('/\) (\S)/', $stat, $m) && $m[1] === 'Z') { echo 'gone'; exit(0); }
    $env = @file_get_contents("/proc/$p/environ");
    if ($env === false || strpos($env, "RUNLET_RUN_ID=$id\0") === false) { echo 'mismatch'; exit(0); }
    if ($sig === 0) { echo 'alive'; exit(0); }
    if (function_exists('posix_kill')) { echo posix_kill($p, $sig) ? 'sent' : 'failed'; exit(0); }
    if (function_exists('exec')) { @exec('kill -' . $sig . ' ' . $p . ' 2>&1', $o, $rc); echo $rc === 0 ? 'sent' : 'failed'; exit(0); }
    echo 'unsupported';
    """#

    static func signal(docker: DockerCLI, containerId: String, user: String?, php: String, pid: Int, runId: UUID, signal: Int32) async -> String {
        var arguments = ["exec"]
        if let user, !user.isEmpty { arguments += ["--user", user] }
        arguments += [containerId, php, "-r", signalHelper, "--", String(pid), runId.uuidString, String(signal)]
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
            await process.terminate(grace: .milliseconds(300))
            return CancelOutcome(confirmed: false, message: "The runner had not reported its process ID, so only the local docker client was stopped; PHP may still be starting inside the container.")
        }

        var outcome = await signal(docker: docker, containerId: containerId, user: user, php: php, pid: pid, runId: runId, signal: SIGTERM)
        if outcome == "unsupported" || outcome.hasPrefix("error") || outcome == "failed" {
            await process.terminate(grace: .milliseconds(300))
            return CancelOutcome(confirmed: false, message: "Could not signal PHP inside the container (\(outcome)). The docker client was stopped, but the runner (pid \(pid)) may still be running.")
        }
        if outcome != "gone" && outcome != "mismatch" {
            // `docker exec` returns once the runner exits.
            if !(await process.waitForExit(within: .milliseconds(1500))) {
                outcome = await signal(docker: docker, containerId: containerId, user: user, php: php, pid: pid, runId: runId, signal: SIGKILL)
                _ = await process.waitForExit(within: .seconds(3))
            }
        }
        let check = await signal(docker: docker, containerId: containerId, user: user, php: php, pid: pid, runId: runId, signal: 0)
        if !process.hasExited { await process.terminate(grace: .milliseconds(300)) }
        if check == "gone" || check == "mismatch" {
            return CancelOutcome(confirmed: true, message: "Stopped the runner inside the container; the container keeps running.")
        }
        return CancelOutcome(confirmed: false, message: "The runner (pid \(pid)) is still running inside the container (\(check)).")
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
            "run", "--rm", "-i", "--name", name,
            "--label", "dev.runlet.owned=sandbox",
            "--env", "RUNLET_RUN_ID=\(runId.uuidString)",
            "--volume", "\(hostDirectory):\(target.workingDirectory)",
            "--workdir", target.workingDirectory,
            image, target.phpExecutable,
        ] + RunnerBundle.phpArguments
        let spec = docker.spec(arguments, stdin: script)
        return PreparedLaunch(spec: spec) { process, _ in
            // This container belongs to Runlet, so removing it is the targeted stop.
            _ = try? await docker.run(["kill", name], timeout: .seconds(5))
            if await process.waitForExit(within: .seconds(4)) {
                return CancelOutcome(confirmed: true, message: "Stopped the sandbox container.")
            }
            await process.terminate()
            return CancelOutcome(confirmed: false, message: "The sandbox container \(name) did not stop in time.")
        }
    }
}
