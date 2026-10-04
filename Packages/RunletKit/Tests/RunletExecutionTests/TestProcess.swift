import Foundation

/// A child process of the tests whose every wait has a deadline (#182).
///
/// It learns of the exit from its `terminationHandler`, never from `waitUntilExit()`. On macOS,
/// `waitUntilExit()` on a Swift-concurrency thread can block for good when `run()` happened on
/// another thread (`run()`, an `await`, then the wait, as the live cancel test did), and nothing
/// bounds it. Async callers wait through a continuation. Sync helpers (setup, `defer` cleanup)
/// block on the termination handler's signal, with a deadline. Output is collected while the
/// process runs, so a full pipe can't stall it. A process that overstays is stopped: SIGTERM,
/// then SIGKILL after a grace period.
final class TestProcess: @unchecked Sendable {
    /// How `stop` ended the process.
    enum Ending: String, Sendable {
        case exited = "had already exited"
        case terminated = "ended on SIGTERM"
        case killed = "ended only on SIGKILL"
        case stuck = "outlived SIGKILL"
    }

    /// A process that didn't finish in time. Thrown, it fails the test and names the step.
    struct Timeout: Error, CustomStringConvertible {
        var step: String
        var limit: Duration
        var ending: Ending
        var output: String
        var errors: String

        var description: String {
            var text = "\(step) did not finish within \(limit) (the process \(ending.rawValue))"
            if !output.isEmpty { text += "; output: \(output.prefix(500))" }
            if !errors.isEmpty { text += "; errors: \(errors.prefix(500))" }
            return text
        }
    }

    /// A process that ended without what the step needed from it.
    struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    struct Result: Sendable {
        var status: Int32
        var output: String
        var errors: String
    }

    /// What the process is for, in failures.
    let step: String
    let process = Process()

    private let lock = NSLock()
    /// Left by the termination handler.
    private let exited = DispatchGroup()
    /// Left when both pipes reach their end.
    private let drained = DispatchGroup()
    private var started = false
    private var ended = false
    private var stdout = Data()
    private var stderr = Data()
    private var open: [ObjectIdentifier: Bool] = [:]

    /// `command` is the executable's path, then its arguments. Without `environment`, the
    /// process inherits the tests' environment.
    init(_ command: [String], step: String, environment: [String: String]? = nil) {
        self.step = step
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        if let environment { process.environment = environment }
    }

    func start() throws {
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        exited.enter()
        // Holds `self` (and its groups) until the exit: a group must not go while entered.
        process.terminationHandler = { [self] _ in
            lock.withLock { ended = true }
            exited.leave()
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            exited.leave()
            throw error
        }
        lock.withLock { started = true }
        collect(out.fileHandleForReading, isOutput: true)
        collect(err.fileHandleForReading, isOutput: false)
    }

    private func collect(_ handle: FileHandle, isOutput: Bool) {
        let id = ObjectIdentifier(handle)
        lock.withLock { open[id] = true }
        drained.enter()
        handle.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            let reachedEnd = lock.withLock {
                guard open[id] == true else { return false }
                if chunk.isEmpty {
                    open[id] = false
                    return true
                }
                if isOutput { stdout.append(chunk) } else { stderr.append(chunk) }
                return false
            }
            if reachedEnd {
                handle.readabilityHandler = nil
                drained.leave()
            }
        }
    }

    var output: String { lock.withLock { String(decoding: stdout, as: UTF8.self) } }
    var errors: String { lock.withLock { String(decoding: stderr, as: UTF8.self) } }
    var hasEnded: Bool { lock.withLock { ended } }

    // MARK: Waits

    /// Waits at most `limit` for the process to end, through a continuation: true once it ended.
    func waitForExit(within limit: Duration) async -> Bool {
        await Self.wait(exited, within: limit)
    }

    /// The same for sync callers: blocks this thread until the termination handler signals, at
    /// most `limit`.
    func waitForExitBlocking(within limit: Duration) -> Bool {
        exited.wait(timeout: .now() + limit.timeInterval) == .success
    }

    /// Waits at most `limit` for a first whole line of output. nil when the process ended
    /// without one, or the time ran out first.
    func firstLine(within limit: Duration) async throws -> String? {
        let deadline = ContinuousClock.now + limit
        while true {
            if let line = Self.firstLine(of: output) { return line }
            if hasEnded {
                _ = await Self.wait(drained, within: .seconds(2))
                return Self.firstLine(of: output)
            }
            if ContinuousClock.now >= deadline { return nil }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func firstLine(of text: String) -> String? {
        text.firstIndex(of: "\n").map { String(text[..<$0]) }
    }

    // MARK: Stopping

    /// Ends the process if it still runs: SIGTERM, then SIGKILL when it outlives `grace`.
    @discardableResult
    func stop(grace: Duration = .seconds(2)) async -> Ending {
        guard send(SIGTERM) else { return .exited }
        if await waitForExit(within: grace) { return .terminated }
        guard send(SIGKILL) else { return .terminated }
        return await waitForExit(within: .seconds(5)) ? .killed : .stuck
    }

    /// The same for sync callers (`defer`): blocks this thread, at most `grace` plus 5 seconds.
    @discardableResult
    func stopBlocking(grace: Duration = .seconds(2)) -> Ending {
        guard send(SIGTERM) else { return .exited }
        if waitForExitBlocking(within: grace) { return .terminated }
        guard send(SIGKILL) else { return .terminated }
        return waitForExitBlocking(within: .seconds(5)) ? .killed : .stuck
    }

    /// Sends `signal` while the process runs. false when it never started or already ended.
    private func send(_ signal: Int32) -> Bool {
        lock.withLock {
            guard started, !ended else { return false }
            kill(process.processIdentifier, signal)
            return true
        }
    }

    // MARK: Whole runs

    /// Runs `command` to its end, at most `limit`, waiting through a continuation. A process
    /// that overstays is stopped, and the run throws a `Timeout` naming `step`.
    static func run(_ command: [String], step: String, within limit: Duration) async throws -> Result {
        let child = TestProcess(command, step: step)
        try child.start()
        guard await child.waitForExit(within: limit) else {
            let ending = await child.stop()
            throw child.timeout(limit, ending)
        }
        _ = await wait(child.drained, within: .seconds(2))
        return child.result
    }

    /// The same for sync callers: blocks this thread, with the same deadline.
    static func runBlocking(_ command: [String], step: String, within limit: Duration, environment: [String: String]? = nil) throws -> Result {
        let child = TestProcess(command, step: step, environment: environment)
        try child.start()
        guard child.waitForExitBlocking(within: limit) else {
            let ending = child.stopBlocking()
            throw child.timeout(limit, ending)
        }
        _ = child.drained.wait(timeout: .now() + 2)
        return child.result
    }

    private var result: Result { Result(status: process.terminationStatus, output: output, errors: errors) }

    private func timeout(_ limit: Duration, _ ending: Ending) -> Timeout {
        Timeout(step: step, limit: limit, ending: ending, output: output, errors: errors)
    }

    /// Waits at most `limit` for `group` to empty, without blocking a thread.
    private static func wait(_ group: DispatchGroup, within limit: Duration) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = Once()
            group.notify(queue: .global()) {
                if once.claim() { continuation.resume(returning: true) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + limit.timeInterval) {
                if once.claim() { continuation.resume(returning: false) }
            }
        }
    }
}

/// Resumes a continuation once, whichever of its wake-ups comes first.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}

private extension Duration {
    var timeInterval: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
