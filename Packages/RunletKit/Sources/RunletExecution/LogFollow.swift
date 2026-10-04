import Foundation
import RunletCore

// MARK: - Following logs in a container or on a server (#20)

/// The command lines of the log viewer's remote follows. Every follow reads only: `docker logs`
/// or `tail -F`, nothing else runs.
///
/// A follow must end when Runlet stops it, also on the far side. Killing the local `ssh` (or
/// `docker`) client isn't enough there: without a terminal the remote `tail` gets no hang-up, and
/// a `docker exec`'d process outlives its client. So each command reads its standard input,
/// which Runlet keeps open while it follows: when Stop closes it (or the client dies), the input
/// ends, and the command kills its `tail` itself. Through `ssh` the end of input is the channel
/// closing; through `docker exec -i` Docker passes it on to the process in the container.
public enum LogFollowCommand {
    /// Lines a follow starts with.
    public static let initialLines = 500

    /// `command` in the background, ended as soon as standard input ends:
    /// `exec 3<&0; <command> <&- & p=$!; { cat <&3 >/dev/null; kill $p 2>/dev/null; } >/dev/null 2>&1 & wait $p`.
    /// The watcher reads a copy of the input (fd 3: a background job's own input would be
    /// /dev/null), writes nowhere, and so never holds the session open; when `command` ends by
    /// itself (a stopped container's `docker logs`), the script ends with it.
    public static func stopsWithInput(_ command: String) -> String {
        "exec 3<&0; \(command) <&- & p=$!; { cat <&3 >/dev/null; kill $p 2>/dev/null; } >/dev/null 2>&1 & wait $p"
    }

    /// `tail -n <lines> -F -- '<path>'`, stopped by the end of input. `-F` follows the name, so
    /// rotation and a file that appears later are followed as well (GNU, BusyBox, and BSD tail).
    public static func tailScript(path: String, lines: Int = initialLines) -> String {
        stopsWithInput("tail -n \(max(0, lines)) -F -- \(RemoteShell.quote(path))")
    }

    /// This Mac's Docker: `docker logs --follow --tail <lines> <container>` (the container's
    /// standard output and error). Stop ends the client; nothing runs in the container.
    public static func dockerLogsArguments(container: String, lines: Int = initialLines) -> [String] {
        ["logs", "--follow", "--tail", String(max(0, lines)), container]
    }

    /// This Mac's Docker: `docker exec -i [--user <user>] <container> /bin/sh -c '<tail script>'`,
    /// as the profile's user (the one runs use), stopped by the end of input.
    public static func dockerExecTailArguments(container: String, user: String?, path: String, lines: Int = initialLines) -> [String] {
        var arguments = ["exec", "-i"]
        if let user, !user.isEmpty { arguments += ["--user", user] }
        return arguments + [container, "/bin/sh", "-c", tailScript(path: path, lines: lines)]
    }

    /// An SSH host's file: the remote command for `ssh … host`.
    public static func sshTailCommand(path: String, lines: Int = initialLines) -> String {
        RemoteShell.command(tailScript(path: path, lines: lines))
    }

    /// A file in a container on an SSH host (a profile's container step): the server's Docker
    /// runs `exec -i` with the channel as its input, so the end of input reaches the container.
    public static func sshDockerTailCommand(dockerCommand: String, container: String, user: String?, path: String, lines: Int = initialLines) -> String {
        let docker = dockerWords(dockerCommand)
        let words = docker + Array(dockerExecTailArguments(container: container, user: user, path: path, lines: lines))
        return RemoteShell.command("exec " + words.map(RemoteShell.quote).joined(separator: " "))
    }

    /// A container's output on an SSH host: the server's `docker logs --follow`, stopped by the
    /// end of input.
    public static func sshDockerLogsCommand(dockerCommand: String, container: String, lines: Int = initialLines) -> String {
        let words = dockerWords(dockerCommand) + dockerLogsArguments(container: container, lines: lines)
        return RemoteShell.command(stopsWithInput(words.map(RemoteShell.quote).joined(separator: " ")))
    }

    static func dockerWords(_ command: String) -> [String] {
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        return words.isEmpty ? ["docker"] : words
    }

    /// Lists the log files under `directory` on a server or in a container (Find Logs): the
    /// `*.log` files of `storage/logs` and `var/log` (4 folders deep), `wp-content/debug.log`,
    /// and the `extra` paths (files, or folders whose `*.log` files are listed), one per line,
    /// at most `limit`. It reads names only.
    public static func findScript(directory: String, extra: [String] = [], limit: Int = LogDiscovery.limit) -> String {
        let base = directory.hasSuffix("/") && directory.count > 1 ? String(directory.dropLast()) : directory
        func absolute(_ path: String) -> String { path.hasPrefix("/") ? path : base + "/" + path }
        let folders = ["storage/logs", "var/log"].map(absolute) + extra.map(absolute)
        let files = [absolute("wp-content/debug.log")] + extra.map(absolute)
        return "{ for d in \(folders.map(RemoteShell.quote).joined(separator: " ")); do [ -d \"$d\" ] && find \"$d\" -maxdepth 4 -type f -name '*.log' 2>/dev/null; done; "
            + "for f in \(files.map(RemoteShell.quote).joined(separator: " ")); do [ -f \"$f\" ] && printf '%s\\n' \"$f\"; done; } | awk '!seen[$0]++' | head -n \(max(1, limit))"
    }

    /// The paths `findScript` printed.
    public static func parseFound(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("/") }
    }
}

/// A running remote or container follow (#20): one process (`docker logs`, `docker exec … tail`,
/// or `ssh … tail`) whose output is passed on as whole lines. `stop()` closes the process's input
/// (the commands end their `tail` then, see `LogFollowCommand`), waits a moment, then ends the
/// local client and its process group.
public final class LogProcessFollower: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        /// Whole lines of the log (each ending in a newline).
        case output(Data)
        /// A line the command wrote about itself (tail's "file truncated", "cannot open").
        case notice(String)
        /// The process ended: its exit code, and an explanation when Runlet has one (an SSH or
        /// Docker failure). Not sent after `stop()`.
        case ended(exitCode: Int32, message: String?)
    }

    public let process: SupervisedProcess
    private let lock = NSLock()
    private var stopping = false
    private let reader: Task<Void, Never>

    /// - Parameters:
    ///   - spec: the command; its input is kept open (`keepStdinOpen`) so Stop can end it.
    ///   - stderrIsLog: standard error carries log lines too (`docker logs`); otherwise its
    ///     lines are notices.
    ///   - explain: a plain explanation of a failed exit from its last output (SSH, Docker).
    public init(spec: ProcessSpec, stderrIsLog: Bool, explain: (@Sendable (String, Int32) -> String?)? = nil, deliveryQueue: DispatchQueue = .main, onEvent: @escaping @Sendable (Event) -> Void) throws {
        var spec = spec
        spec.keepStdinOpen = true
        spec.standardInput = nil
        let process = try SupervisedProcess.launch(spec)
        self.process = process
        let state = LockedFlag()
        reader = Task.detached { [process] in
            var stdout = LineAssembler()
            var stderr = LineAssembler()
            var lastError = ""
            func send(_ event: Event) {
                deliveryQueue.async { onEvent(event) }
            }
            for await chunk in process.output {
                switch chunk {
                case .stdout(let data):
                    if let lines = stdout.add(data) { send(.output(lines)) }
                case .stderr(let data):
                    guard let lines = stderr.add(data) else { continue }
                    let text = String(decoding: lines, as: UTF8.self)
                    // Kept for the explanation of a failed exit (an ssh or Docker message).
                    lastError = String((lastError + text).suffix(4000))
                    if stderrIsLog {
                        send(.output(lines))
                    } else if !state.isSet {
                        // After Stop, the shell's "Terminated" for its killed tail isn't news.
                        for line in text.split(whereSeparator: \.isNewline) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                            send(.notice(String(line)))
                        }
                    }
                }
            }
            if let rest = stdout.flush() { send(.output(rest)) }
            if let rest = stderr.flush() {
                let text = String(decoding: rest, as: UTF8.self)
                lastError = String((lastError + text).suffix(4000))
                if stderrIsLog {
                    send(.output(rest))
                } else if !state.isSet {
                    send(.notice(text.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            let termination = await process.termination()
            guard !state.isSet else { return }
            let output = lastError.trimmingCharacters(in: .whitespacesAndNewlines)
            send(.ended(exitCode: termination.exitCode, message: explain?(output, termination.exitCode)))
        }
        stoppedFlag = state
    }

    private let stoppedFlag: LockedFlag

    public var isRunning: Bool { !process.hasExited }

    /// Ends the follow: the input closes (the command ends its `tail`), then after `grace` the
    /// client and its process group get SIGTERM, then SIGKILL. Returns once the local process is
    /// gone. No `.ended` event follows.
    public func stop(grace: Duration = .milliseconds(1500)) async {
        let first = lock.withLock { () -> Bool in
            defer { stopping = true }
            return !stopping
        }
        stoppedFlag.set()
        if first { process.closeStdin() }
        if !(await process.waitForExit(within: grace)) {
            await process.terminate(grace: .milliseconds(500), timeout: .seconds(3))
        }
        _ = await reader.value
    }
}

/// A flag shared with the reader task.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Passes on whole lines only: a chunk's unfinished last line waits for the next chunk.
struct LineAssembler {
    private var pending = Data()
    /// Longest unfinished line kept; longer ones are passed on as they are.
    static let maxPending = 256 * 1024

    mutating func add(_ data: Data) -> Data? {
        pending.append(data)
        guard let last = pending.lastIndex(of: 0x0A) else {
            if pending.count > Self.maxPending { return flush() }
            return nil
        }
        let end = pending.index(after: last)
        let lines = pending.subdata(in: pending.startIndex..<end)
        pending = pending.subdata(in: end..<pending.endIndex)
        return lines
    }

    mutating func flush() -> Data? {
        guard !pending.isEmpty else { return nil }
        defer { pending = Data() }
        return pending + Data([0x0A])
    }
}
