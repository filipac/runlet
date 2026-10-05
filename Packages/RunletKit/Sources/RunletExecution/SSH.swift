import Darwin
import Foundation
import RunletCore

/// Builds remote command lines for `ssh`. OpenSSH joins its arguments into one string that
/// the user's login shell runs with `-c`, so Runlet always sends `/bin/sh -c '<script>'` with
/// every word POSIX-quoted: the same text works under bash, zsh, dash, and fish logins.
public enum RemoteShell {
    /// Printed to stderr when the run's directory can't be entered (mapped to a plain message).
    public static let missingDirectoryMarker = "runlet: the remote directory could not be opened"

    /// Quotes one shell word (POSIX single quotes) unless it is plainly safe.
    public static func quote(_ word: String) -> String {
        ProjectCommandLauncher.shellQuote(word)
    }

    /// `/bin/sh -c '<script>'`, the one string handed to `ssh` after the host.
    public static func command(_ script: String) -> String {
        "/bin/sh -c " + quote(script)
    }

    /// PHP code for `php -r` that survives any login shell's quoting rules: the code travels
    /// as base64 (letters, digits, `+`, `/`, `=`) and is evaluated on the server.
    public static func inlinePHP(_ code: String) -> String {
        "eval(base64_decode(\"" + Data(code.utf8).base64EncodedString() + "\"));"
    }

    /// The script that starts the runner: enter the directory (or report it missing), mark
    /// the process with the run ID (Stop checks it), and `exec` PHP so it leads the SSH
    /// session's process group. The runner itself arrives on stdin and is never written on
    /// the server.
    ///
    /// With `keepCompiledPHP`, PHP gets an opcode file cache in `~/.cache/runlet/opcache`
    /// (created 0700 when missing; skipped when it can't be). Timestamps are checked on every
    /// run, so edited files are recompiled; a PHP without the opcache extension ignores it.
    ///
    /// With `runnerCache` (#48, only with `keepCompiledPHP`), stdin starts with
    /// `SSHRunnerCache`'s loader instead of the runner: `php -n` runs it, and it writes the
    /// runner's program (the runner kept in `~/.cache/runlet/runner`, or the one on stdin, then
    /// the request) into a pipe to the runner's PHP, which reads it as it reads stdin otherwise.
    /// When PHP isn't found, the plain `exec` reports it as without the cache; when the loader
    /// fails, the runner's PHP gets `SSHRunnerCache.missProgram`, so the run is sent again.
    /// A runner killed by a signal ends the shell with that signal, as `exec` would.
    public static func runScript(directory: String, php: String, runId: UUID, keepCompiledPHP: Bool = false, runnerCache: Bool = false) -> String {
        var script = "cd \(quote(directory)) 2>/dev/null || { echo \(quote(missingDirectoryMarker)) >&2; exit 2; }; "
            + "RUNLET_RUN_ID=\(runId.uuidString); export RUNLET_RUN_ID; "
        let arguments = RunnerBundle.phpArguments.map(quote).joined(separator: " ")
        if keepCompiledPHP {
            script += #"set --; d="${HOME:-/tmp}/.cache/runlet/opcache"; "#
                + #"if (umask 077; mkdir -p "$d") 2>/dev/null && chmod 700 "${d%/opcache}" "$d" 2>/dev/null; then "#
                + #"set -- -d opcache.enable=1 -d opcache.enable_cli=1 -d "opcache.file_cache=$d" -d opcache.file_cache_only=1 -d opcache.validate_timestamps=1 -d opcache.revalidate_freq=0; fi; "#
            let run = "exec \(quote(php)) \"$@\" " + arguments
            guard runnerCache else { return script + run }
            return script
                + "command -v \(quote(php)) >/dev/null 2>&1 || \(run); "
                + "{ \(quote(php)) -n -r \(quote(SSHRunnerCache.bootstrap)) -- \"$(id -u)\" || echo \(quote(SSHRunnerCache.missProgram)); } | \(run); "
                + #"s=$?; [ "$s" -gt 128 ] && kill -$((s - 128)) $$; exit "$s""#
        }
        return script + "exec \(quote(php)) " + arguments
    }

    /// `exec <php> [-n] -r <code> -- <arguments>` as a remote command line.
    public static func phpCommand(php: String, code: String, arguments: [String], skipIni: Bool = false) -> String {
        var words = ["exec", quote(php)]
        if skipIni { words.append("-n") }
        words += ["-r", quote(inlinePHP(code)), "--"] + arguments.map(quote)
        return command(words.joined(separator: " "))
    }

    /// `/bin/sh -lc '<script>'`: like `command`, but the shell reads `/etc/profile` and
    /// `~/.profile` first, so a project command finds what the login's PATH adds (Composer's
    /// global bin, a PHP version manager), as it would in an interactive login.
    public static func loginCommand(_ script: String) -> String {
        "/bin/sh -lc " + quote(script)
    }

    /// Enters `directory` (explaining when it can't, in the terminal) and runs `commandLine`, a
    /// project command's shell line as the driver declared it.
    public static func commandScript(directory: String, commandLine: String) -> String {
        "cd \(quote(directory)) 2>/dev/null || { echo \(quote("Runlet: \(directory) doesn't exist on this server, or this login can't open it.")) >&2; exit 2; }; "
            + commandLine
    }

    /// An interactive login shell in `directory` (the home folder, with a note, when the
    /// directory can't be entered), for Shell on Host and commands that need input.
    public static func shellScript(directory: String) -> String {
        "cd \(quote(directory)) 2>/dev/null || echo \(quote("Runlet: couldn't open \(directory); the shell starts in your home folder.")) >&2; "
            + "exec \"${SHELL:-/bin/sh}\" -l"
    }

    /// `line` with a leading `php` word replaced by the server's PHP (`php8.3`, a path), so
    /// project commands use the same PHP as snippets on that server.
    public static func commandLine(_ line: String, php: String) -> String {
        guard php != "php", line == "php" || line.hasPrefix("php ") else { return line }
        return quote(php) + line.dropFirst(3)
    }

    /// `<docker command> exec -it [--user] [--env TMPDIR] -w <dir> <container>` as quoted
    /// words, for terminal tabs inside a container on an SSH host.
    public static func dockerExec(dockerCommand: String, containerId: String, workingDirectory: String, user: String?, temporaryDirectory: String?) -> [String] {
        var words = dockerCommand.split(whereSeparator: \.isWhitespace).map(String.init) + ["exec", "-it"]
        if let user, !user.isEmpty { words += ["--user", user] }
        if let temporaryDirectory, !temporaryDirectory.isEmpty { words += ["--env", "TMPDIR=\(temporaryDirectory)"] }
        words += ["-w", workingDirectory, containerId]
        return words.map(quote)
    }
}

/// Whether Runlet's shared connection (OpenSSH ControlMaster) to a host is up.
public enum SSHConnectionStatus: String, Sendable, Equatable {
    /// A master process is listening on the profile's control socket.
    case connected
    /// No control socket: nobody logged in yet, or Disconnect closed it.
    case disconnected
    /// The socket file is left over from a master that died (network change, sleep, killed).
    case expired
}

/// Checks a control socket locally, without starting `ssh` (so `~/.ssh/config` isn't read and
/// nothing reaches the network): it connects to the Unix socket and closes it at once.
public enum SSHControlSocket {
    public static func status(at path: String) -> SSHConnectionStatus {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .disconnected }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else { return .expired }
        return canConnect(path) ? .connected : .expired
    }

    /// When the socket file was made, i.e. when the shared connection started (the Connection
    /// Manager's "since", #180). Read from this Mac's file system; nil without a socket.
    public static func createdAt(_ path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK else { return nil }
        let birth = info.st_birthtimespec
        return Date(timeIntervalSince1970: TimeInterval(birth.tv_sec) + TimeInterval(birth.tv_nsec) / 1_000_000_000)
    }

    /// Removes a socket file nobody listens on (OpenSSH refuses to start a master over it).
    @discardableResult
    public static func removeIfStale(at path: String) -> Bool {
        guard status(at: path) == .expired else { return false }
        return unlink(path) == 0
    }

    static func canConnect(_ path: String) -> Bool {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return result == 0
    }
}

/// The system OpenSSH client. Runlet stores no keys or passwords and holds no crypto code:
/// `~/.ssh/config`, agents (including 1Password's), `known_hosts`, and `UseKeychain` all work
/// exactly as in the user's terminal.
///
/// Every non-interactive call uses `BatchMode=yes` (never prompts) and
/// `StrictHostKeyChecking=yes` (never accepts an unknown host key); only Connect… (a terminal
/// tab) can ask for a password, a code, or a host key confirmation, and OpenSSH asks it.
public struct SSHClient: Sendable {
    public static let systemExecutable = "/usr/bin/ssh"

    public let executable: String
    public let environment: [String: String]
    /// Test hook: `-F <file>` instead of `~/.ssh/config`. The app never sets it.
    public let configFile: String?
    /// Test hook: options placed before Runlet's own. OpenSSH keeps the first value it sees
    /// for an option, so these win (e.g. shorter keep-alive timeouts).
    public let extraOptions: [String]

    public init(executable: String = SSHClient.systemExecutable, environment: [String: String]? = nil, configFile: String? = nil, extraOptions: [String] = []) {
        self.executable = executable
        var environment = environment ?? ExecutableLocator.toolEnvironment()
        // Nothing may route a prompt around BatchMode.
        for key in ["SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "DISPLAY"] { environment[key] = nil }
        self.environment = environment
        self.configFile = configFile
        self.extraOptions = extraOptions
    }

    /// What an `ssh` invocation is for.
    public enum Purpose: Sendable, Equatable {
        /// A run, probe, Stop signal, or listing: no prompts, no unknown host keys, banners
        /// suppressed, through the shared connection.
        case batch
        /// `ssh -O <operation>` on the control socket (`check`, `exit`); never connects.
        case control(String)
        /// Connect…: an interactive login in a terminal that opens the shared connection and
        /// goes to the background (`-M -N -f`), kept until Disconnect.
        case connect
        /// A terminal tab on the server (a project command or a shell): a pty (`-t`), but
        /// otherwise like `batch`: no login prompts, no unknown host keys, the shared
        /// connection. Only Connect… asks anything.
        case terminal
    }

    /// The `ssh` arguments (without the executable) for `purpose`.
    public func arguments(for endpoint: SSHEndpoint, purpose: Purpose, remoteCommand: String? = nil) -> [String] {
        var arguments: [String] = []
        if let configFile { arguments += ["-F", configFile] }
        arguments += extraOptions
        switch purpose {
        case .batch, .terminal:
            arguments += [
                purpose == .terminal ? "-t" : "-T",
                "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=yes",
                "-o", "ConnectTimeout=10",
                "-o", "ServerAliveInterval=15",
                "-o", "ServerAliveCountMax=3",
                "-o", "LogLevel=ERROR",
                "-o", "RemoteCommand=none",
                "-o", "PermitLocalCommand=no",
                "-o", "ClearAllForwardings=yes",
                "-S", endpoint.controlPath,
            ]
            switch endpoint.authentication {
            case .automatic:
                // The first call opens the shared connection by itself and leaves it in the
                // background for later runs.
                arguments += ["-o", "ControlMaster=auto", "-o", "ControlPersist=\(Self.persist(endpoint.keepAliveMinutes))"]
            case .interactive:
                // Only reuse the connection Connect… opened; never log in from a run.
                arguments += ["-o", "ControlMaster=no"]
            }
            if endpoint.compression { arguments.append("-C") }
        case .control(let operation):
            arguments += ["-o", "BatchMode=yes", "-o", "LogLevel=ERROR", "-S", endpoint.controlPath, "-O", operation]
        case .connect:
            arguments += [
                "-M", "-S", endpoint.controlPath,
                "-o", "ControlPersist=yes",
                "-o", "BatchMode=no",
                // Unknown keys are confirmed by the user against OpenSSH's own fingerprint
                // prompt, whatever ~/.ssh/config says; changed keys are refused.
                "-o", "StrictHostKeyChecking=ask",
                "-o", "ConnectTimeout=15",
                "-o", "ServerAliveInterval=15",
                "-o", "ServerAliveCountMax=3",
                "-o", "RemoteCommand=none",
                "-o", "ClearAllForwardings=yes",
                "-N", "-f",
            ]
            if endpoint.compression { arguments.append("-C") }
        }
        if let user = endpoint.user, !user.isEmpty { arguments += ["-l", user] }
        if let port = endpoint.port { arguments += ["-p", String(port)] }
        if let jump = endpoint.jumpHost, !jump.isEmpty { arguments += ["-J", jump] }
        // #188: a key file the profile names; `-o control` calls only talk to the master.
        var talksToMaster = false
        if case .control = purpose { talksToMaster = true }
        if !talksToMaster, let identityFile = endpoint.identityFile, SSHProfile.isValidIdentityFile(identityFile) {
            arguments += ["-i", identityFile]
        }
        arguments += ["--", endpoint.host]
        if let remoteCommand { arguments.append(remoteCommand) }
        return arguments
    }

    /// "10m", or "yes" (until Disconnect).
    static func persist(_ minutes: Int?) -> String {
        minutes.map { "\($0)m" } ?? "yes"
    }

    public func spec(_ endpoint: SSHEndpoint, purpose: Purpose = .batch, remoteCommand: String? = nil, stdin: Data? = nil) -> ProcessSpec {
        ProcessSpec(executable: executable, arguments: arguments(for: endpoint, purpose: purpose, remoteCommand: remoteCommand), environment: environment, standardInput: stdin, newProcessGroup: true)
    }

    /// Runs a short remote command through the shared connection (BatchMode).
    public func run(_ endpoint: SSHEndpoint, remoteCommand: String, stdin: Data? = nil, timeout: Duration = .seconds(15)) async throws -> (stdout: Data, stderr: Data, exitCode: Int32) {
        try SSHControlPaths.prepareDirectory(for: endpoint.controlPath)
        return try await runCommand(spec(endpoint, remoteCommand: remoteCommand, stdin: stdin), timeout: timeout)
    }

    /// The argument vector a terminal tab runs for Connect…: OpenSSH asks for the password,
    /// code, or host key itself, then keeps the connection in the background until
    /// Disconnect. Removes a stale socket first, since OpenSSH would not replace it.
    public func connectCommand(_ endpoint: SSHEndpoint) throws -> [String] {
        try SSHControlPaths.prepareDirectory(for: endpoint.controlPath)
        SSHControlSocket.removeIfStale(at: endpoint.controlPath)
        return [executable] + arguments(for: endpoint, purpose: .connect)
    }

    /// The argument vector of a terminal tab that runs `remoteCommand` on the server with a
    /// pty (project commands, shells): no prompts and no unknown host keys, through the
    /// shared connection (opened by it for agent and key profiles).
    public func terminalCommand(_ endpoint: SSHEndpoint, remoteCommand: String) throws -> [String] {
        try SSHControlPaths.prepareDirectory(for: endpoint.controlPath)
        return [executable] + arguments(for: endpoint, purpose: .terminal, remoteCommand: remoteCommand)
    }

    /// The shared connection's state, checked locally (see `SSHControlSocket`).
    public func status(_ endpoint: SSHEndpoint) -> SSHConnectionStatus {
        SSHControlSocket.status(at: endpoint.controlPath)
    }

    /// Disconnect: asks the master to exit (`ssh -O exit`); runs in progress end with it.
    /// Returns once the socket is gone (or after a few seconds).
    @discardableResult
    public func disconnect(_ endpoint: SSHEndpoint) async -> Bool {
        if SSHControlSocket.status(at: endpoint.controlPath) == .connected {
            _ = try? await runCommand(spec(endpoint, purpose: .control("exit")), timeout: .seconds(5))
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while SSHControlSocket.status(at: endpoint.controlPath) == .connected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        SSHControlSocket.removeIfStale(at: endpoint.controlPath)
        return SSHControlSocket.status(at: endpoint.controlPath) != .connected
    }

    /// `ssh -G`: the effective settings for `host` from `~/.ssh/config` (no connection is
    /// made). Keys are lowercased option names (`hostname`, `user`, `port`, `proxyjump`,
    /// `identityagent`, …); options given more than once keep the first value.
    public func effectiveConfiguration(host: String, user: String? = nil, port: Int? = nil) async -> [String: String]? {
        var arguments: [String] = []
        if let configFile { arguments += ["-F", configFile] }
        arguments += ["-G"]
        if let user, !user.isEmpty { arguments += ["-l", user] }
        if let port { arguments += ["-p", String(port)] }
        arguments += ["--", host]
        let spec = ProcessSpec(executable: executable, arguments: arguments, environment: environment)
        guard let result = try? await runCommand(spec, timeout: .seconds(5)), result.exitCode == 0 else { return nil }
        var values: [String: String] = [:]
        for line in String(decoding: result.stdout, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            if values[key] == nil { values[key] = String(parts[1]) }
        }
        return values
    }
}

/// Plain-language explanations of `ssh` failures (exit 255 plus OpenSSH's message), the
/// missing-directory marker, and a missing PHP (exit 127). The original output is kept.
public enum SSHFailure {
    /// - Parameters:
    ///   - output: the end of stderr (and pre-runner stdout).
    ///   - afterStart: the runner had started, so only a lost connection is explained.
    public static func explain(_ output: String, exitCode: Int32, host: String, directory: String? = nil, php: String? = nil, afterStart: Bool = false) -> String? {
        let lower = output.lowercased()
        func lead(_ text: String) -> String { output.isEmpty ? text : "\(text)\n\n\(output)" }
        let lostConnection = ["timeout, server not responding", "broken pipe", "connection reset", "closed by remote host", "connection closed by", "client_loop", "mux_client_read_packet", "master hung up"]
        if afterStart {
            guard exitCode == 255 else { return nil }
            if lostConnection.contains(where: lower.contains) {
                return lead("The SSH connection to \(host) was lost before the run finished. PHP may still be running on the server until it notices.")
            }
            // Through a shared connection, a dead link usually ends the session silently.
            return lead("The SSH session on \(host) ended before the runner finished (ssh exit 255): the connection was lost, or PHP was killed on the server (for example by the out-of-memory killer).")
        }
        if exitCode == 255 {
            if lower.contains("remote host identification has changed") {
                return lead("The host key of \(host) changed since it was last trusted. The server may have been reinstalled, or someone may be intercepting the connection, so Runlet won't connect. If you know why the key changed, update ~/.ssh/known_hosts in Terminal (for example `ssh-keygen -R <host>`), then use Connect… to check the new key.")
            }
            if lower.contains("host key verification failed") || lower.contains("host key is known") {
                return lead("\(host) isn't in your known hosts yet, and Runlet never accepts a host key by itself. Use Connect… to compare the server's fingerprint in a terminal and accept it.")
            }
            if lower.contains("control socket connect") || lower.contains("control socket") && lower.contains("no such file") {
                return lead("The login to \(host) has ended. Use Connect… to log in again.")
            }
            if lower.contains("permission denied") || lower.contains("too many authentication failures") {
                return lead("\(host) didn't accept a key from your SSH agent or key files, and Runlet doesn't ask for passwords during a run. If this server needs a password or a one-time code, set the profile's authentication to Password / 2FA and use Connect… to log in.")
            }
            if lower.contains("could not resolve hostname") || lower.contains("nodename nor servname") {
                return lead("The host name \(host) could not be resolved. Check the profile's host, ~/.ssh/config, and your network or VPN.")
            }
            if lower.contains("connection refused") {
                return lead("\(host) refused the SSH connection. Check the host and port, and that the SSH server runs.")
            }
            if lower.contains("timed out") || lower.contains("no route to host") || lower.contains("network is unreachable") || lower.contains("host is down") {
                return lead("Runlet couldn't reach \(host) in time. Check your network or VPN.")
            }
            if lostConnection.contains(where: lower.contains) {
                return lead("The SSH connection to \(host) was lost.")
            }
            return lead("ssh could not run the command on \(host) (exit 255).")
        }
        if output.contains(RemoteShell.missingDirectoryMarker) {
            return "The directory \(directory ?? "of this profile") doesn't exist on \(host), or this login can't open it. Check the profile's remote directory; Test Connection lists the applications it finds."
        }
        if exitCode == 127 {
            return lead("PHP was not found as \(php.map { "“\($0)”" } ?? "php") on \(host). Set the profile's PHP executable; Test Connection lists the PHP binaries it finds.")
        }
        if exitCode == 126 {
            return lead("\(php ?? "PHP") on \(host) can't be executed by this login.")
        }
        return nil
    }
}

/// Runs snippets on an SSH host: `ssh -T … host /bin/sh -c 'cd <dir> && … exec php …'` with
/// the runner streamed on stdin. Without `keepCompiledPHP` nothing is written on the server;
/// with it, PHP's opcode file cache and (#48) the runner itself are kept in `~/.cache/runlet`,
/// and a run sends only its request when the server has the runner (`SSHRunnerCache`).
/// Framing, raw output, limits, and the single `finished` event work as for local runs,
/// because `ssh -T` keeps stdout and stderr apart.
enum SSHExecAdapter {
    static func prepare(target: TargetSnapshot, runId: UUID, script: Data, ssh: SSHClient, bundle: RunnerBundle? = nil, runnerCache: RunnerCacheMemory? = nil) throws -> PreparedLaunch {
        guard let endpoint = target.ssh else { throw ExecutionError.invalidTarget("This SSH target has no host.") }
        do {
            try SSHControlPaths.prepareDirectory(for: endpoint.controlPath)
        } catch {
            throw ExecutionError.invalidTarget("Runlet could not create its SSH control folder: \(error.localizedDescription)")
        }
        let directory = target.workingDirectory
        let php = target.phpExecutable
        let keepCompiledPHP = endpoint.keepCompiledPHP == true
        // #48: one attempt's ssh call. `.stream` is the run as without the runner cache.
        let make: @Sendable (SSHRunnerCache.Step, Data) -> ProcessSpec = { step, request in
            let script = RemoteShell.runScript(directory: directory, php: php, runId: runId, keepCompiledPHP: keepCompiledPHP, runnerCache: step != .stream)
            var stdin: Data
            switch step {
            case .stream:
                stdin = bundle?.source ?? Data()
                stdin.append(request)
            case .use, .save:
                stdin = bundle.map { SSHRunnerCache.stdin(step, bundle: $0, request: request) } ?? request
            }
            return ssh.spec(endpoint, remoteCommand: RemoteShell.command(script), stdin: stdin)
        }
        var spec = ssh.spec(endpoint, remoteCommand: RemoteShell.command(RemoteShell.runScript(directory: directory, php: php, runId: runId, keepCompiledPHP: keepCompiledPHP)), stdin: script)
        var attempts: SSHRunnerAttempts?
        if keepCompiledPHP, let bundle, let runnerCache, let request = bundle.request(in: script) {
            let step = runnerCache.firstStep(key: endpoint.controlPath, hash: bundle.sha256)
            if step != .stream {
                let first = SSHRunnerAttempts(step: step, request: request, memory: runnerCache, key: endpoint.controlPath, hash: bundle.sha256, make: make)
                if let cached = first.spec() {
                    spec = cached
                    attempts = first
                }
            }
        }
        let host = endpoint.displayName
        var prepared = PreparedLaunch(spec: spec, stop: { process, control in
            await stopRemote(ssh: ssh, endpoint: endpoint, php: php, runId: runId, process: process, control: control)
        }, explainFailure: { output, exitCode, afterStart in
            SSHFailure.explain(output, exitCode: exitCode, host: host, directory: directory, php: php, afterStart: afterStart)
        })
        prepared.attempts = attempts
        prepared.stdinNote = attempts.flatMap { SSHRunnerAttempts.note($0.step, hash: $0.hash) }
        return prepared
    }

    static func signal(ssh: SSHClient, endpoint: SSHEndpoint, php: String, pid: Int, runId: UUID, signal: Int32) async -> String {
        let command = RemoteShell.phpCommand(php: php, code: RemoteSignal.wholeRunHelper, arguments: [String(pid), runId.uuidString, String(signal)])
        guard let result = try? await ssh.run(endpoint, remoteCommand: command, timeout: .seconds(8)) else { return "error" }
        let text = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.exitCode != 0 {
            let stderr = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return "error: \(stderr.isEmpty ? "exit \(result.exitCode)" : stderr)"
        }
        return text
    }

    /// Stop on an SSH host. Killing the local `ssh` alone is not enough: without a pty the
    /// remote PHP gets no SIGHUP (and a shared connection keeps the session open), so a
    /// separate `ssh` runs `RemoteSignal.wholeRunHelper`, which signals only processes that
    /// carry this run's `RUNLET_RUN_ID`: the runner and anything the snippet started.
    /// SIGTERM, 1.5 s, SIGKILL, 3 s, then a check. Servers without `/proc` are left alone and
    /// the stop is reported as unconfirmed.
    static func stopRemote(ssh: SSHClient, endpoint: SSHEndpoint, php: String, runId: UUID, process: SupervisedProcess, control: RunControl) async -> CancelOutcome {
        let host = endpoint.displayName
        guard let pid = await control.waitForRunnerPid(timeout: .seconds(2)) else {
            let message = "The runner had not reported its process ID, so only the local ssh client was stopped; PHP may still be starting on \(host)."
            control.setCancelNote(message)
            await process.terminate(grace: .milliseconds(300))
            return CancelOutcome(confirmed: false, message: message)
        }

        var outcome = await signal(ssh: ssh, endpoint: endpoint, php: php, pid: pid, runId: runId, signal: SIGTERM)
        if outcome == "noproc" {
            let message = "\(host) has no /proc, so Runlet can't check that process \(pid) still belongs to this run and didn't signal it. The local ssh client was stopped; PHP may keep running on the server until it finishes."
            control.setCancelNote(message)
            await process.terminate(grace: .milliseconds(300))
            return CancelOutcome(confirmed: false, message: message)
        }
        if outcome == "unsupported" || outcome.hasPrefix("error") || outcome == "failed" {
            let message = "Could not signal PHP on \(host) (\(outcome)). The local ssh client was stopped, but the runner (pid \(pid)) may still be running."
            control.setCancelNote(message)
            await process.terminate(grace: .milliseconds(300))
            return CancelOutcome(confirmed: false, message: message)
        }
        if outcome != "gone" && outcome != "mismatch" {
            // The session (and the local ssh) ends once the runner and its children exit.
            if !(await process.waitForExit(within: .milliseconds(1500))) {
                outcome = await signal(ssh: ssh, endpoint: endpoint, php: php, pid: pid, runId: runId, signal: SIGKILL)
                _ = await process.waitForExit(within: .seconds(3))
            }
        }
        let check = await signal(ssh: ssh, endpoint: endpoint, php: php, pid: pid, runId: runId, signal: 0)
        let confirmed = check == "gone" || check == "mismatch"
        let message: String
        if confirmed {
            message = "Stopped the runner on \(host)."
        } else if check == "children" {
            message = "The runner on \(host) stopped, but processes it started are still running."
        } else {
            message = "The runner (pid \(pid)) is still running on \(host) (\(check))."
        }
        if !confirmed { control.setCancelNote(message) }
        if !process.hasExited { await process.terminate(grace: .milliseconds(300)) }
        return CancelOutcome(confirmed: confirmed, message: message)
    }
}

/// PHP programs that signal a run's processes on another machine (inside a container or on
/// an SSH host), run as a separate `php -r`. Both read Linux `/proc` and never signal a
/// process whose environment lacks the run's `RUNLET_RUN_ID`, so a reused PID is safe.
enum RemoteSignal {
    /// Signals only the runner PID (Docker profiles). Prints `gone`, `mismatch`, `alive`
    /// (signal 0), `sent`, `failed`, or `unsupported`.
    static let runnerOnlyHelper = #"""
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

    /// Signals the runner and every process that inherited the run's `RUNLET_RUN_ID` (what
    /// the snippet started, even after the runner exited or if they left its process group).
    /// Prints `noproc` without Linux `/proc`; for signal 0 `alive`, `children` (the runner is
    /// gone but its processes remain), `gone`, or `mismatch`; otherwise `sent`, `failed`,
    /// `unsupported`, or `gone`/`mismatch` when nothing of the run is left.
    static let wholeRunHelper = #"""
    $p = (int) $argv[1]; $id = $argv[2]; $sig = (int) $argv[3];
    if (!is_dir('/proc/self')) { echo 'noproc'; exit(0); }
    $needle = "RUNLET_RUN_ID=$id\0";
    $state = function ($q) { $s = @file_get_contents("/proc/$q/stat"); if ($s === false) { return null; } $r = strrpos($s, ')'); return $r === false ? null : substr($s, $r + 2, 1); };
    $ours = function ($q) use ($needle) { $e = @file_get_contents("/proc/$q/environ"); return $e !== false && strpos($e, $needle) !== false; };
    $s = $state($p);
    $runner = ($s === null || $s === 'Z') ? 'gone' : ($ours($p) ? 'alive' : 'mismatch');
    $self = getmypid();
    $others = [];
    foreach (glob('/proc/[0-9]*', GLOB_ONLYDIR) ?: [] as $d) {
        $q = (int) basename($d);
        if ($q === $p || $q === $self) { continue; }
        $t = $state($q);
        if ($t !== null && $t !== 'Z' && $ours($q)) { $others[] = $q; }
    }
    if ($sig === 0) { echo $runner === 'alive' ? 'alive' : ($others ? 'children' : $runner); exit(0); }
    $targets = $runner === 'alive' ? array_merge([$p], $others) : $others;
    if (!$targets) { echo $runner; exit(0); }
    $ok = true;
    foreach ($targets as $t) {
        if (function_exists('posix_kill')) { $sent = posix_kill($t, $sig); }
        elseif (function_exists('exec')) { $o = []; @exec('kill -' . $sig . ' ' . $t . ' 2>&1', $o, $rc); $sent = $rc === 0; }
        else { echo 'unsupported'; exit(0); }
        // Only the runner's result counts: a child may have exited since the scan.
        if ($t === $p) { $ok = $sent; }
    }
    echo $ok ? 'sent' : 'failed';
    """#
}
