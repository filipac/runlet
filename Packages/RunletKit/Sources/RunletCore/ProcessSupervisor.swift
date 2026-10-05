import Darwin
import Foundation

/// Describes a subprocess launch. Commands are always argument arrays; nothing is
/// interpreted by a shell.
public struct ProcessSpec: Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?
    /// Written to stdin on a background thread, then stdin is closed. nil closes stdin immediately.
    public var standardInput: Data?
    /// Start the child in its own process group so cancellation can signal its descendants.
    public var newProcessGroup: Bool
    /// Keep stdin open for streaming writes (`SupervisedProcess.write`), e.g. for LSP servers.
    public var keepStdinOpen: Bool = false

    public init(executable: String, arguments: [String] = [], environment: [String: String] = ProcessInfo.processInfo.environment, workingDirectory: String? = nil, standardInput: Data? = nil, newProcessGroup: Bool = true) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.standardInput = standardInput
        self.newProcessGroup = newProcessGroup
    }
}

public enum ProcessChunk: Sendable, Equatable {
    case stdout(Data)
    case stderr(Data)
}

public enum ProcessTermination: Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)

    public var exitCode: Int32 {
        switch self {
        case .exited(let code): code
        case .signaled(let signal): 128 + signal
        }
    }
}

public struct ProcessLaunchError: Error, CustomStringConvertible, Sendable {
    public var executable: String
    public var errno: Int32

    public var description: String {
        "Could not launch \(executable): \(String(cString: strerror(errno)))"
    }
}

/// A running child process with streamed, binary-safe output.
///
/// Output is read on dedicated threads (never the main thread) and delivered through
/// `output`, which finishes after both pipes reach EOF. `termination` resolves once the
/// child has been reaped.
public final class SupervisedProcess: @unchecked Sendable {
    public let pid: pid_t
    public let output: AsyncStream<ProcessChunk>
    private let processGroup: Bool
    private let lock = NSLock()
    private var terminationResult: ProcessTermination?
    private var terminationWaiters: [CheckedContinuation<ProcessTermination, Never>] = []
    private var stdinFD: Int32 = -1
    private let stdinQueue = DispatchQueue(label: "dev.runlet.process.stdin")

    init(pid: pid_t, processGroup: Bool, output: AsyncStream<ProcessChunk>) {
        self.pid = pid
        self.processGroup = processGroup
        self.output = output
    }

    /// Launches `spec`. Throws if the executable cannot be spawned.
    public static func launch(_ spec: ProcessSpec) throws -> SupervisedProcess {
        var stdinPipe: [Int32] = [-1, -1]
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        guard pipe(&stdinPipe) == 0, pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            throw ProcessLaunchError(executable: spec.executable, errno: errno)
        }
        // Parent ends must not leak into other children.
        for fd in [stdinPipe[1], stdoutPipe[0], stderrPipe[0]] {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        // Writing to a child that exited early must not raise SIGPIPE in the app.
        _ = fcntl(stdinPipe[1], F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], 2)
        if let cwd = spec.workingDirectory {
            // macOS 26 names it without the _np suffix; the _np one exists since 10.15 (#248).
            if #available(macOS 26, *) {
                posix_spawn_file_actions_addchdir(&actions, cwd)
            } else {
                posix_spawn_file_actions_addchdir_np(&actions, cwd)
            }
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var flags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        if spec.newProcessGroup {
            flags |= Int16(POSIX_SPAWN_SETPGROUP)
            posix_spawnattr_setpgroup(&attributes, 0)
        }
        posix_spawnattr_setflags(&attributes, flags)
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signal in [SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGCHLD] {
            sigaddset(&defaultSignals, signal)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)

        let argv = [spec.executable] + spec.arguments
        let envp = spec.environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let status = withCStrings(argv) { argvPointer in
            withCStrings(envp) { envPointer in
                posix_spawn(&pid, spec.executable, &actions, &attributes, argvPointer, envPointer)
            }
        }

        close(stdinPipe[0])
        close(stdoutPipe[1])
        close(stderrPipe[1])

        guard status == 0 else {
            close(stdinPipe[1])
            close(stdoutPipe[0])
            close(stderrPipe[0])
            throw ProcessLaunchError(executable: spec.executable, errno: status)
        }

        let (stream, continuation) = AsyncStream<ProcessChunk>.makeStream(bufferingPolicy: .unbounded)
        let process = SupervisedProcess(pid: pid, processGroup: spec.newProcessGroup, output: stream)

        let stdinFD = stdinPipe[1]
        let input = spec.standardInput
        if spec.keepStdinOpen {
            process.stdinFD = stdinFD
            if let input { process.write(input) }
        } else { Thread.detachNewThread {
            if let input, !input.isEmpty {
                input.withUnsafeBytes { buffer in
                    var offset = 0
                    while offset < buffer.count {
                        let written = Darwin.write(stdinFD, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                        if written < 0 {
                            if errno == EINTR { continue }
                            break
                        }
                        offset += written
                    }
                }
            }
            close(stdinFD)
        } }

        let remaining = OpenStreams(count: 2) { continuation.finish() }
        for (fd, isStdout) in [(stdoutPipe[0], true), (stderrPipe[0], false)] {
            Thread.detachNewThread {
                let size = 64 * 1024
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 1)
                defer { buffer.deallocate() }
                while true {
                    let count = read(fd, buffer, size)
                    if count > 0 {
                        let data = Data(bytes: buffer, count: count)
                        continuation.yield(isStdout ? .stdout(data) : .stderr(data))
                    } else if count < 0 && errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
                close(fd)
                remaining.close()
            }
        }

        let childPid = pid
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(childPid, &status, 0) < 0 && errno == EINTR {}
            let termination: ProcessTermination
            if (status & 0x7f) == 0 {
                termination = .exited((status >> 8) & 0xff)
            } else {
                termination = .signaled(status & 0x7f)
            }
            process.resolve(termination)
        }

        return process
    }

    /// Writes to a stdin kept open with `keepStdinOpen`. Writes are serialized off the caller's thread.
    public func write(_ data: Data) {
        stdinQueue.async { [self] in
            guard stdinFD >= 0 else { return }
            data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(stdinFD, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        return
                    }
                    offset += written
                }
            }
        }
    }

    public func closeStdin() {
        stdinQueue.async { [self] in
            if stdinFD >= 0 {
                close(stdinFD)
                stdinFD = -1
            }
        }
    }

    private func resolve(_ termination: ProcessTermination) {
        lock.lock()
        terminationResult = termination
        let waiters = terminationWaiters
        terminationWaiters = []
        lock.unlock()
        waiters.forEach { $0.resume(returning: termination) }
    }

    public var hasExited: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminationResult != nil
    }

    /// Waits for the child to be reaped.
    public func termination() async -> ProcessTermination {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result = terminationResult {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                terminationWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Sends `signal` to the child's process group (or just the child).
    public func send(_ signal: Int32) {
        guard !hasExited else { return }
        if processGroup {
            if kill(-pid, signal) != 0 { kill(pid, signal) }
        } else {
            kill(pid, signal)
        }
    }

    /// SIGTERM, then SIGKILL after `grace` if the child is still alive. Returns once reaped
    /// or after `timeout`.
    @discardableResult
    public func terminate(grace: Duration = .milliseconds(1500), timeout: Duration = .seconds(5)) async -> ProcessTermination? {
        send(SIGTERM)
        if await waitForExit(within: grace) { return await termination() }
        send(SIGKILL)
        if await waitForExit(within: timeout - grace) { return await termination() }
        return nil
    }

    /// Returns true if the process exits within `duration`.
    public func waitForExit(within duration: Duration) async -> Bool {
        let deadline = ContinuousClock.now + duration
        while ContinuousClock.now < deadline {
            if hasExited { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return hasExited
    }

    /// Convenience: collects all output and the termination status.
    public func collect(limit: Int = 16 * 1024 * 1024) async -> (stdout: Data, stderr: Data, termination: ProcessTermination) {
        var out = Data()
        var err = Data()
        for await chunk in output {
            switch chunk {
            case .stdout(let data): if out.count < limit { out.append(data) }
            case .stderr(let data): if err.count < limit { err.append(data) }
            }
        }
        return (out, err, await termination())
    }
}

private final class OpenStreams: @unchecked Sendable {
    private var count: Int
    private let lock = NSLock()
    private let onAllClosed: () -> Void

    init(count: Int, onAllClosed: @escaping () -> Void) {
        self.count = count
        self.onAllClosed = onAllClosed
    }

    func close() {
        lock.lock()
        count -= 1
        let done = count == 0
        lock.unlock()
        if done { onAllClosed() }
    }
}

private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { pointers.forEach { free($0) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}

/// Runs a short command and returns its output, killing it after `timeout`.
public func runCommand(_ spec: ProcessSpec, timeout: Duration = .seconds(15)) async throws -> (stdout: Data, stderr: Data, exitCode: Int32) {
    let process = try SupervisedProcess.launch(spec)
    let watchdog = Task {
        try await Task.sleep(for: timeout)
        await process.terminate(grace: .milliseconds(300), timeout: .seconds(2))
    }
    let result = await process.collect()
    watchdog.cancel()
    return (result.stdout, result.stderr, result.termination.exitCode)
}
