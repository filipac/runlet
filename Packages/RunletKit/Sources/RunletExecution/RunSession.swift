import Foundation
import RunletCore

/// Mutable per-run state shared between the event pump and the canceller.
final class RunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var _runnerPid: Int?
    private var _cancelRequested = false
    private var _cancelNote: String?
    private var pidWaiters: [CheckedContinuation<Int?, Never>] = []

    var runnerPid: Int? {
        lock.lock(); defer { lock.unlock() }
        return _runnerPid
    }

    var cancelRequested: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelRequested
    }

    var cancelNote: String? {
        lock.lock(); defer { lock.unlock() }
        return _cancelNote
    }

    func markCancelRequested() {
        lock.lock(); _cancelRequested = true; lock.unlock()
    }

    func setCancelNote(_ note: String?) {
        lock.lock(); _cancelNote = note; lock.unlock()
    }

    func setRunnerPid(_ pid: Int?) {
        lock.lock()
        _runnerPid = pid
        let waiters = pidWaiters
        pidWaiters = []
        lock.unlock()
        waiters.forEach { $0.resume(returning: pid) }
    }

    /// Waits up to `timeout` for the runner to report its PID.
    func waitForRunnerPid(timeout: Duration) async -> Int? {
        if let pid = runnerPid { return pid }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let pid = runnerPid { return pid }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return runnerPid
    }
}

/// Converts one runner process into normalized, sequenced `RunEvent`s and guarantees a
/// single terminal `finished` event, whatever happens to the process or transport.
final class RunSession: @unchecked Sendable {
    let runId: UUID
    let events: AsyncStream<RunEvent>
    let control = RunControl()

    private let continuation: AsyncStream<RunEvent>.Continuation
    private let limits: RunLimits
    private let startedAt = ContinuousClock.now
    private let lock = NSLock()
    private var sequence = 0
    private var rawBytes = 0
    private var droppedBytes = 0
    private var runnerFinished: RunnerFinishedInfo?
    private var sawStarted = false
    private var sawError = false
    private var finished = false
    private var stderrTail = Data()
    /// Inspector records accepted, their payload bytes, and those dropped per section by
    /// Runlet's own backstop (the runner enforces the same limits first).
    private var inspectorRecords = 0
    private var inspectorBytes = 0
    private var droppedRecords: [String: Int] = [:]
    /// Non-frame stdout before `started`: where `docker exec` reports that it could not start
    /// PHP (e.g. "OCI runtime exec failed: … chdir to cwd …").
    private var preStartStdout = Data()
    private let decoder = JSONDecoder()
    /// Receives frames the run event model has no case for (e.g. `commands`), in order.
    private let otherFrames: (@Sendable (_ type: String, _ payload: Data) -> Void)?

    init(runId: UUID, limits: RunLimits, otherFrames: (@Sendable (_ type: String, _ payload: Data) -> Void)? = nil) {
        self.runId = runId
        self.limits = limits
        self.otherFrames = otherFrames
        (events, continuation) = AsyncStream<RunEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    var elapsedMs: Int {
        let elapsed = ContinuousClock.now - startedAt
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    private func yield(_ kind: RunEvent.Kind) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        sequence += 1
        let event = RunEvent(runId: runId, sequence: sequence, kind: kind)
        if case .finished = kind { finished = true }
        lock.unlock()
        continuation.yield(event)
        if case .finished = kind { continuation.finish() }
    }

    /// Finishes a run that was stopped before its process launched.
    func cancelBeforeLaunch() {
        yield(.finished(FinishedInfo(status: .cancelled, reason: "cancelled", elapsedMs: elapsedMs)))
    }

    /// Emits a launch failure and finishes the run.
    func failLaunch(_ message: String) {
        sawError = true
        yield(.error(RunErrorInfo(stage: .launch, className: nil, message: message)))
        yield(.finished(FinishedInfo(status: .failed, reason: "launch-failed", elapsedMs: elapsedMs)))
    }

    /// Pumps the process output until EOF and exit, then emits `finished`.
    func pump(_ process: SupervisedProcess, nonce: String) async {
        var frames = FrameDecoder(nonce: nonce)
        for await chunk in process.output {
            switch chunk {
            case .stdout(let data):
                for item in frames.feed(data) { handle(item) }
            case .stderr(let data):
                remember(stderr: data)
                emitRaw(data, isStdout: false)
            }
        }
        for item in frames.finish() { handle(item) }
        let termination = await process.termination()
        finish(termination: termination)
    }

    private func remember(stderr data: Data) {
        stderrTail.append(data)
        if stderrTail.count > 4096 { stderrTail = stderrTail.suffix(4096) }
    }

    /// Docker's own launch errors with a plain-language lead, keeping the original text.
    static func explainLaunchFailure(_ output: String) -> String {
        if let range = output.range(of: #"chdir to cwd \("([^"]*)"\)"#, options: .regularExpression) {
            let directory = output[range].replacingOccurrences(of: #"^chdir to cwd \(""#, with: "", options: .regularExpression).replacingOccurrences(of: #""\)$"#, with: "", options: .regularExpression)
            return "The working directory \(directory) does not exist in this container. Check that the Docker profile points at the right container and working directory.\n\n\(output)"
        }
        if output.contains("executable file not found") {
            return "The PHP executable was not found in this container. Set the profile's PHP executable to the container's PHP path.\n\n\(output)"
        }
        return output
    }

    private func emitRaw(_ data: Data, isStdout: Bool) {
        guard !data.isEmpty else { return }
        let allowed = max(0, limits.maxRawOutputBytes - rawBytes)
        if allowed == 0 {
            droppedBytes += data.count
            return
        }
        let slice = data.count > allowed ? data.prefix(allowed) : data
        droppedBytes += data.count - slice.count
        rawBytes += slice.count
        yield(isStdout ? .stdout(Data(slice)) : .stderr(Data(slice)))
    }

    private func handle(_ item: FrameDecoder.Item) {
        switch item {
        case .raw(let data):
            if !sawStarted, preStartStdout.count < 4096 { preStartStdout.append(data.prefix(4096 - preStartStdout.count)) }
            emitRaw(data, isStdout: true)
        case .malformed(let message):
            sawError = true
            yield(.error(RunErrorInfo(stage: .transport, message: "Runner event stream was malformed: \(message)")))
        case .frame(let body):
            do {
                let (type, payload) = try splitFrame(body)
                try handleFrame(type: type, payload: payload)
            } catch {
                yield(.error(RunErrorInfo(stage: .transport, message: "Runlet could not decode a runner event: \(error.localizedDescription)")))
            }
        }
    }

    private func handleFrame(type: String, payload: Data) throws {
        switch type {
        case "started":
            let info = try decoder.decode(StartedInfo.self, from: payload)
            sawStarted = true
            control.setRunnerPid(info.pid)
            yield(.started(info))
        case "bootstrapped":
            yield(.bootstrapped(try decoder.decode(BootstrappedInfo.self, from: payload)))
        case "dump":
            yield(.dump(try decoder.decode(DumpInfo.self, from: payload)))
        case "result":
            yield(.result(try decoder.decode(ResultInfo.self, from: payload)))
        case "error":
            sawError = true
            yield(.error(try decoder.decode(RunErrorInfo.self, from: payload)))
        case "notice":
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
            yield(.notice(object?["message"] as? String ?? ""))
        case "inspector":
            yield(.inspector(.ready(try decoder.decode(InspectorInfo.self, from: payload))))
        case "record":
            let record = try decoder.decode(InspectorRecord.self, from: payload)
            guard acceptRecord(bytes: payload.count) else {
                droppedRecords[record.section, default: 0] += 1
                return
            }
            yield(.inspector(.record(record)))
        case "recordLimit":
            yield(.inspector(.limit(try decoder.decode(RecordLimitInfo.self, from: payload))))
        case "runnerFinished":
            runnerFinished = try decoder.decode(RunnerFinishedInfo.self, from: payload)
        default:
            otherFrames?(type, payload)
        }
    }

    /// Backstop for the runner's record limits, so a driver that bypasses `Runlet\Inspector`
    /// cannot flood the app: at most `maxQueries + maxRecords` records and about
    /// `maxRecordBytes + maxBodyBytes` of payload per run.
    private func acceptRecord(bytes: Int) -> Bool {
        guard inspectorRecords < limits.maxQueries + limits.maxRecords,
              inspectorBytes + bytes <= limits.maxRecordBytes + limits.maxBodyBytes else { return false }
        inspectorRecords += 1
        inspectorBytes += bytes
        return true
    }

    private func finish(termination: ProcessTermination) {
        for (section, omitted) in droppedRecords.sorted(by: { $0.key < $1.key }) {
            yield(.inspector(.limit(RecordLimitInfo(section: section, omitted: omitted, reason: "app"))))
        }
        let exitCode = termination.exitCode
        let truncation = droppedBytes > 0 ? "Output exceeded \(limits.maxRawOutputBytes / 1024 / 1024) MiB; \(droppedBytes) bytes were discarded." : nil
        let elapsed = elapsedMs

        if control.cancelRequested {
            var info = FinishedInfo(status: .cancelled, reason: "cancelled", exitCode: exitCode, elapsedMs: elapsed, peakMemory: runnerFinished?.peakMemory, truncation: truncation)
            if let note = control.cancelNote { info.reason = "cancelled: \(note)" }
            yield(.finished(info))
            return
        }

        if let runnerFinished {
            let status: RunStatus
            switch runnerFinished.reason {
            case "completed", "dd": status = .completed
            case "exit": status = exitCode == 0 ? .completed : .failed
            default: status = .failed
            }
            yield(.finished(FinishedInfo(status: status, reason: runnerFinished.reason, exitCode: exitCode, elapsedMs: elapsed, peakMemory: runnerFinished.peakMemory, truncation: truncation)))
            return
        }

        // The runner never reported completion: the process died, was killed, or never started.
        let stderrText = String(decoding: stderrTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !sawStarted {
            let stdoutText = String(decoding: preStartStdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let output = stderrText.isEmpty ? stdoutText : stderrText
            let detail = output.isEmpty
                ? "The PHP process exited with code \(exitCode) before the runner started."
                : Self.explainLaunchFailure(output)
            yield(.error(RunErrorInfo(stage: .launch, message: detail)))
            yield(.finished(FinishedInfo(status: .failed, reason: "launch-failed", exitCode: exitCode, elapsedMs: elapsed, truncation: truncation)))
            return
        }
        if !sawError {
            let message: String
            if case .signaled(let signal) = termination {
                message = "The PHP process was terminated by signal \(signal) before finishing."
            } else {
                message = "The PHP process exited with code \(exitCode) without reporting completion."
            }
            yield(.error(RunErrorInfo(stage: .transport, message: message)))
        }
        yield(.finished(FinishedInfo(status: .failed, reason: "transport-closed", exitCode: exitCode, elapsedMs: elapsed, truncation: truncation)))
    }
}
