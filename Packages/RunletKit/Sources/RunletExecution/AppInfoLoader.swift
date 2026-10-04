import Foundation
import RunletCore

extension ExecutionEngine {
    /// Reads a target's App Info (#19): the runner boots the project exactly like a run (local
    /// PHP, `docker exec` into the snapshotted container, the Docker sandbox, or SSH), runs no
    /// snippet, and reports key/value sections: Laravel's `artisan about` data, Symfony's or
    /// WordPress's details, PHP, then the driver's `panels()`. This executes project code: call
    /// it only when the user opens App Info or presses Refresh.
    ///
    /// Bootstrap failures, exit(), fatal errors, and a timeout don't throw: the report then has
    /// `errors` (and whatever sections arrived first). Throws when the run cannot be admitted
    /// (e.g. no Docker CLI) or the calling task is cancelled.
    public func loadAppInfo(target: TargetSnapshot, timeout: Duration = .seconds(120)) async throws -> AppInfoReport {
        let runId = UUID()
        let collector = AppInfoFrameCollector()
        let session = RunSession(runId: runId, limits: limits) { type, payload in
            collector.receive(type: type, payload: payload)
        }
        // A fresh pseudo tab id: loading never conflicts with (or blocks) a tab's run.
        try launch(session, tabId: runId, target: target) { bundle, nonce, limits in
            bundle.script(code: "", nonce: nonce, runId: runId, mode: .panels, limits: limits)
        }

        let watchdog = Task { [weak self] in
            try await Task.sleep(for: timeout)
            collector.markTimedOut()
            _ = await self?.cancel(runId: runId)
        }
        defer { watchdog.cancel() }

        var errors: [RunErrorInfo] = []
        var notices: [String] = []
        var started: StartedInfo?
        var bootstrapped: BootstrappedInfo?
        var finished: FinishedInfo?
        await withTaskCancellationHandler {
            for await event in session.events {
                switch event.kind {
                case .started(let info): started = info
                case .bootstrapped(let info): bootstrapped = info
                case .error(let error): errors.append(error)
                case .notice(let message): notices.append(message)
                // \Runlet\notice() and friends from a driver's panels() (#196).
                case .snippetMessage(let message): notices.append(message.summary(line: nil))
                case .finished(let info): finished = info
                default: break
                }
            }
        } onCancel: {
            Task { await self.cancel(runId: runId) }
        }
        try Task.checkCancellation()

        var report = collector.result()
        report.phpVersion = started?.phpVersion
        report.workingDirectory = started?.workingDirectory
        report.framework = bootstrapped?.framework ?? started?.framework
        report.frameworkVersion = bootstrapped?.frameworkVersion
        report.driverName = bootstrapped?.driverName
        report.driverFile = bootstrapped?.driverFile ?? report.driverFile
        report.bootstrapMs = bootstrapped?.bootstrapMs
        report.errors = collector.decodeErrors() + errors
        report.notices = notices
        report.finished = finished
        if collector.timedOut {
            report.errors.append(RunErrorInfo(stage: bootstrapped == nil ? .bootstrap : .execute, message: "App Info took longer than \(timeout.components.seconds) s, so Runlet stopped it. The application may be waiting on a service (database, cache) while it boots."))
        }
        report.loadedAt = Date()
        return report
    }
}

/// Collects `panels` frames on the session's pump thread.
final class AppInfoFrameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var report = AppInfoReport()
    private var errors: [RunErrorInfo] = []
    private var didTimeOut = false

    func receive(type: String, payload: Data) {
        guard type == "panels" else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            try report.add(panelsFrame: payload)
        } catch {
            errors.append(RunErrorInfo(stage: .transport, message: "Runlet could not decode the App Info: \(error.localizedDescription)"))
        }
    }

    func markTimedOut() {
        lock.lock()
        didTimeOut = true
        lock.unlock()
    }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didTimeOut
    }

    func result() -> AppInfoReport {
        lock.lock()
        defer { lock.unlock() }
        return report
    }

    func decodeErrors() -> [RunErrorInfo] {
        lock.lock()
        defer { lock.unlock() }
        return errors
    }
}
