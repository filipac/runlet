import Foundation
import RunletCore

extension ExecutionEngine {
    /// Lists the commands a target's project offers: the driver's `commands()` (every
    /// Artisan or `bin/console` command, or a project driver's own) and Composer scripts.
    ///
    /// The runner boots the project exactly like a run, through the same adapter (local PHP
    /// in the project directory, `docker exec` into the snapshotted container with its user,
    /// working directory, and TMPDIR, or the Docker sandbox), so this executes project code:
    /// call it only when the user asks for the list. No snippet runs.
    ///
    /// Bootstrap and `commands()` failures do not throw: the catalog then has
    /// `driverListed == false`, the errors, and whatever Composer scripts were read. Throws
    /// when the run cannot be admitted (e.g. no Docker CLI) or the calling task is cancelled;
    /// a run that exceeds `timeout` is stopped and reported as an error in the catalog.
    public func listCommands(target: TargetSnapshot, timeout: Duration = .seconds(120)) async throws -> ProjectCommandCatalog {
        let runId = UUID()
        let collector = CommandFrameCollector()
        let session = RunSession(runId: runId, limits: limits) { type, payload in
            collector.receive(type: type, payload: payload)
        }
        // A fresh pseudo tab id: listing never conflicts with (or blocks) a tab's run.
        try launch(session, tabId: runId, target: target) { bundle, nonce, limits in
            bundle.script(code: "", nonce: nonce, runId: runId, mode: .commands, limits: limits)
        }

        let watchdog = Task { [weak self] in
            try await Task.sleep(for: timeout)
            collector.markTimedOut()
            _ = await self?.cancel(runId: runId)
        }
        defer { watchdog.cancel() }

        var catalog = ProjectCommandCatalog()
        var sawBootstrapped = false
        await withTaskCancellationHandler {
            for await event in session.events {
                switch event.kind {
                case .started(let info):
                    catalog.phpVersion = info.phpVersion
                    catalog.workingDirectory = info.workingDirectory
                    catalog.framework = info.framework
                case .bootstrapped(let info):
                    sawBootstrapped = true
                    catalog.framework = info.framework
                    catalog.frameworkVersion = info.frameworkVersion
                    catalog.driverName = info.driverName
                    catalog.driverFile = info.driverFile
                    catalog.variables = info.variables
                case .error(let error):
                    catalog.errors.append(error)
                case .notice(let message):
                    catalog.notices.append(message)
                case .finished(let info):
                    catalog.finished = info
                default:
                    break
                }
            }
        } onCancel: {
            Task { await self.cancel(runId: runId) }
        }
        try Task.checkCancellation()

        let collected = collector.result()
        catalog.commands = collected.driver + collected.composer
        catalog.driverListed = collected.driverListed
        catalog.hostCommands = collected.hostCommands
        catalog.hostSources = collected.hostSources
        catalog.hostDeclared = collected.hostDeclared
        catalog.errors += collected.errors
        if collected.driverName != nil, catalog.driverName == nil { catalog.driverName = collected.driverName }
        if collected.timedOut {
            catalog.errors.append(RunErrorInfo(stage: sawBootstrapped ? .execute : .bootstrap, message: "Listing commands took longer than \(timeout.components.seconds) s, so Runlet stopped it. The application may be waiting on a service (database, cache) while it boots."))
        }
        catalog.loadedAt = Date()
        return catalog
    }
}

/// Builds the terminal request that runs a project command for a resolved target.
public enum ProjectCommandLauncher {
    /// - Local and sandbox targets: the command line runs in the user's shell in the
    ///   project (or sandbox) directory; a leading `php` becomes the target's PHP binary, so
    ///   commands use the same PHP as snippets.
    /// - Docker targets: `docker exec -it [--user] [--env TMPDIR] -w <workdir> <container>
    ///   sh -lc <command>` into the snapshot's container, never another one.
    /// - Docker sandbox: a disposable, Runlet-labelled `docker run --rm -it` with the sandbox
    ///   mounted, like sandbox runs.
    ///
    /// - SSH targets: `ssh -t` to the host (see `sshTerminalRequest`).
    ///
    /// Commands that need input (required arguments) are typed without running: into the
    /// user's shell, or into an interactive `sh -l` in the container or login shell on the host.
    public static func terminalRequest(for command: ProjectCommand, target: TargetSnapshot, dockerExecutable: String?, ssh: SSHClient = SSHClient()) throws -> TerminalRequest {
        let title = terminalTitle(for: command)
        switch target.kind {
        case .local, .sandboxLocal:
            return TerminalRequest(title: title, workingDirectory: target.workingDirectory, commandLine: localCommandLine(command.commandLine, php: target.phpExecutable), runsCommandLine: !command.needsInput)
        case .docker:
            guard let docker = dockerExecutable else { throw ExecutionError.dockerUnavailable }
            guard let containerId = target.containerId, !containerId.isEmpty else {
                throw ExecutionError.invalidTarget("No container is resolved for this profile.")
            }
            var arguments = [docker, "exec", "-it"]
            if let user = target.user, !user.isEmpty { arguments += ["--user", user] }
            if let temporary = target.temporaryDirectory, !temporary.isEmpty { arguments += ["--env", "TMPDIR=\(temporary)"] }
            arguments += ["-w", target.workingDirectory, containerId]
            if command.needsInput {
                // An interactive shell in the container with the command typed, not run.
                return TerminalRequest(title: title, commandLine: command.commandLine, executable: arguments + ["sh", "-l"], runsCommandLine: false)
            }
            return TerminalRequest(title: title, executable: arguments + ["sh", "-lc", command.commandLine], isCommand: true)
        case .sandboxDocker:
            guard let docker = dockerExecutable else { throw ExecutionError.dockerUnavailable }
            guard let hostDirectory = target.hostMountDirectory, let image = target.image else {
                throw ExecutionError.invalidTarget("The Docker sandbox is not configured.")
            }
            let arguments = [
                docker, "run", "--rm", "-it", "--init", "--label", "dev.runlet.owned=sandbox",
                "--volume", "\(hostDirectory):\(target.workingDirectory)", "--workdir", target.workingDirectory,
                image, "sh", "-lc", command.commandLine,
            ]
            return TerminalRequest(title: title, workingDirectory: hostDirectory, executable: arguments, isCommand: true)
        case .ssh:
            return try sshTerminalRequest(for: command, target: target, ssh: ssh, title: title)
        }
    }

    /// A project command on an SSH host: `ssh -t` (BatchMode, strict host keys, the shared
    /// connection) running `/bin/sh -lc 'cd <dir> && <command>'`, with a leading `php`
    /// replaced by the profile's PHP. With a container step, `<docker> exec -it … sh -lc
    /// <command>` into the snapshot's container on that server instead (never another one).
    /// Commands that need input open an interactive shell there with the command typed.
    static func sshTerminalRequest(for command: ProjectCommand, target: TargetSnapshot, ssh: SSHClient, title: String) throws -> TerminalRequest {
        guard let endpoint = target.ssh else { throw ExecutionError.invalidTarget("This SSH target has no host.") }
        let title = "\(title) · \(endpoint.host)"
        let line = RemoteShell.commandLine(command.commandLine, php: target.phpExecutable)
        let remote: String
        if let containerId = target.containerId {
            let exec = RemoteShell.dockerExec(dockerCommand: target.dockerCommand ?? "docker", containerId: containerId, workingDirectory: target.workingDirectory, user: target.user, temporaryDirectory: target.temporaryDirectory)
            if command.needsInput {
                remote = RemoteShell.command((exec + ["sh", "-l"]).joined(separator: " "))
            } else {
                remote = RemoteShell.command((exec + ["sh", "-lc", RemoteShell.quote(line)]).joined(separator: " "))
            }
        } else if command.needsInput {
            remote = RemoteShell.command(RemoteShell.shellScript(directory: target.workingDirectory))
        } else {
            remote = RemoteShell.loginCommand(RemoteShell.commandScript(directory: target.workingDirectory, commandLine: line))
        }
        let argv = try preparedTerminal(ssh, endpoint: endpoint, remote: remote)
        if command.needsInput {
            return TerminalRequest(title: title, commandLine: line, executable: argv, runsCommandLine: false)
        }
        return TerminalRequest(title: title, executable: argv, isCommand: true)
    }

    /// Shell on Host: an interactive login shell on the SSH host in the profile's directory,
    /// or, with a container step, bash (else sh) inside the snapshot's container there.
    public static func sshShellRequest(target: TargetSnapshot, title: String, ssh: SSHClient = SSHClient()) throws -> TerminalRequest {
        guard let endpoint = target.ssh else { throw ExecutionError.invalidTarget("This SSH target has no host.") }
        let remote: String
        if let containerId = target.containerId {
            let exec = RemoteShell.dockerExec(dockerCommand: target.dockerCommand ?? "docker", containerId: containerId, workingDirectory: target.workingDirectory, user: target.user, temporaryDirectory: target.temporaryDirectory)
            remote = RemoteShell.command((exec + ["sh", "-c", RemoteShell.quote("command -v bash >/dev/null && exec bash || exec sh")]).joined(separator: " "))
        } else {
            remote = RemoteShell.command(RemoteShell.shellScript(directory: target.workingDirectory))
        }
        return TerminalRequest(title: title, executable: try preparedTerminal(ssh, endpoint: endpoint, remote: remote))
    }

    private static func preparedTerminal(_ ssh: SSHClient, endpoint: SSHEndpoint, remote: String) throws -> [String] {
        do {
            return try ssh.terminalCommand(endpoint, remoteCommand: remote)
        } catch {
            throw ExecutionError.invalidTarget("Runlet could not create its SSH control folder: \(error.localizedDescription)")
        }
    }

    /// A host command (`hostCommands()`): the command line in the user's own shell on this
    /// Mac, in `directory` (the project's local folder), for every kind of target.
    public static func hostTerminalRequest(for command: ProjectCommand, directory: String?) throws -> TerminalRequest {
        guard let directory, !directory.isEmpty else {
            throw ExecutionError.invalidTarget("Host commands run in the project's folder on this Mac, and this target has none. For a Docker profile, set its local source folder in Settings ▸ Targets.")
        }
        return TerminalRequest(title: terminalTitle(for: command), workingDirectory: directory, commandLine: command.commandLine, runsCommandLine: !command.needsInput)
    }

    /// "artisan migrate:status", "bin/console cache:clear", or "composer test": the command
    /// line without its leading `php`, or the script name for Composer scripts.
    public static func terminalTitle(for command: ProjectCommand) -> String {
        if command.origin == .composer { return "composer \(command.name)" }
        let line = command.commandLine
        return line.hasPrefix("php ") ? String(line.dropFirst(4)) : line
    }

    /// `line` with a leading `php` word replaced by the target's PHP binary, when that is an
    /// absolute path (configured per project or in Settings).
    public static func localCommandLine(_ line: String, php: String) -> String {
        guard php.hasPrefix("/"), line == "php" || line.hasPrefix("php ") else { return line }
        return shellQuote(php) + line.dropFirst(3)
    }

    /// Quotes one shell word (POSIX single quotes) unless it is plainly safe.
    public static func shellQuote(_ word: String) -> String {
        if !word.isEmpty, word.range(of: #"^[A-Za-z0-9_@%+=:,./-]+$"#, options: .regularExpression) != nil { return word }
        return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// The request as one pasteable shell line (used when no terminal panel is available).
    public static func shellText(_ request: TerminalRequest) -> String {
        if let arguments = request.executable { return arguments.map(shellQuote).joined(separator: " ") }
        let line = request.commandLine ?? ""
        guard let directory = request.workingDirectory else { return line }
        return "cd \(shellQuote(directory)) && \(line)"
    }
}

/// Collects `commands` frames on the session's pump thread.
final class CommandFrameCollector: @unchecked Sendable {
    struct Result {
        var driver: [ProjectCommand] = []
        var composer: [ProjectCommand] = []
        var driverListed = false
        var driverName: String?
        var hostCommands: [ProjectCommand] = []
        var hostSources: [HostCommandSource] = []
        var hostDeclared = false
        var errors: [RunErrorInfo] = []
        var timedOut = false
    }

    private struct Frame: Decodable {
        var origin: String
        var source: String?
        var commands: [Entry]
    }

    private struct Entry: Decodable {
        var name: String
        var command: String
        var description: String?
        var group: String?
        var needsInput: Bool?
    }

    private struct HostFrame: Decodable {
        struct Source: Decodable {
            var name: String
            var format: String
            var list: String
            var console: String?
            var description: String?
        }

        var commands: [Entry]
        var sources: [Source]
    }

    private let lock = NSLock()
    private var state = Result()

    func receive(type: String, payload: Data) {
        if type == "hostCommands" {
            receiveHost(payload)
            return
        }
        guard type == "commands" else { return }
        do {
            let frame = try JSONDecoder().decode(Frame.self, from: payload)
            let origin: ProjectCommand.Origin = frame.origin == "composer" ? .composer : .driver
            let source = frame.source ?? (origin == .composer ? "Composer" : "Driver")
            let commands = frame.commands.map {
                ProjectCommand(name: $0.name, description: $0.description, commandLine: $0.command, group: $0.group, origin: origin, source: source, needsInput: $0.needsInput ?? false)
            }
            lock.lock()
            defer { lock.unlock() }
            switch origin {
            case .composer:
                state.composer += commands
            case .driver, .host:
                state.driver += commands
                state.driverListed = true
                state.driverName = frame.source
            }
        } catch {
            lock.lock()
            state.errors.append(RunErrorInfo(stage: .transport, message: "Runlet could not decode the project's command list: \(error.localizedDescription)"))
            lock.unlock()
        }
    }

    /// The driver's `hostCommands()`: static commands (titled "Host commands" unless grouped)
    /// and command sources the app lists on this Mac.
    private func receiveHost(_ payload: Data) {
        do {
            let frame = try JSONDecoder().decode(HostFrame.self, from: payload)
            let commands = frame.commands.map {
                ProjectCommand(name: $0.name, description: $0.description, commandLine: $0.command, group: $0.group, origin: .host, source: "Host commands", needsInput: $0.needsInput ?? false)
            }
            let sources = frame.sources.map {
                HostCommandSource(name: $0.name, format: $0.format == "symfony" ? .symfony : .runlet, listCommand: $0.list, console: $0.console, description: $0.description)
            }
            lock.lock()
            defer { lock.unlock() }
            state.hostCommands = commands
            state.hostSources = sources
            state.hostDeclared = true
        } catch {
            lock.lock()
            state.errors.append(RunErrorInfo(stage: .transport, message: "Runlet could not decode the project's host commands: \(error.localizedDescription)"))
            lock.unlock()
        }
    }

    func markTimedOut() {
        lock.lock()
        state.timedOut = true
        lock.unlock()
    }

    func result() -> Result {
        lock.lock()
        defer { lock.unlock() }
        return state
    }
}
