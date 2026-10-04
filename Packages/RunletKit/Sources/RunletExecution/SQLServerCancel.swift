import Foundation
import RunletCore

/// Stop on an SQL tab's run (#144): before the runner process is stopped, its statement is
/// cancelled on the database server. Killing the process alone leaves MySQL and MariaDB
/// executing a long statement until they write to the closed connection, and PostgreSQL usually
/// finishes it, holding its locks meanwhile.
///
/// The run reported its database session (`sqlSession`) right after connecting. Stop starts a
/// second, short runner on the same target with the same connection: an application connection
/// boots the application again and opens it through the same driver; a saved connection (#138)
/// opens it again with its password from the credential store, on stdin. That runner checks it
/// reached the same server and that the session still runs something, sends `KILL QUERY <id>`,
/// `SELECT pg_cancel_backend(<pid>)`, or `KILL <spid>` (SQL Server), and watches the statement
/// end. Stop never asks, not even on production: it only stops what already ran with
/// confirmation. The run's output and Run Log say what happened.
extension ExecutionEngine {
    /// Cancels `sql`'s statement with `plan` and reports it into the run's `session` (a Run Log
    /// line, then `.sqlCancel`), holding the run's `finished` event until then. Bounded by
    /// `SQLCancel.timeout`.
    ///
    /// The database's cancellation error that the run reports meanwhile is held until the report;
    /// when the server took the cancel, it's marked `interruptedByStop` (the output shows an info
    /// line instead of an error card). The runner then gets up to 0.5 s to end on its own (Run
    /// All rolls back and says what it undid) before the adapter's stop.
    func cancelOnServer(_ plan: SQLCancel.Plan, sql: SQLSessionInfo, request: RunRequest, target: TargetSnapshot, session: RunSession, process: SupervisedProcess) async -> SQLCancelReport {
        let gate = AsyncStream<Never>.makeStream()
        session.control.holdFinish(until: Task { for await _ in gate.stream {} })
        defer { gate.continuation.finish() }
        session.control.beginServerCancel()
        let how = request.sqlConnection == nil ? "boots the application again and opens the same connection" : "opens the saved connection again"
        session.inject(.log(RunLogEntry(source: "cancel", message: "Stop: cancelling the \(plan.noun) on the server with \(plan.statement)",
                                        detail: "A second runner on \(target.label) \(how). Stop doesn't ask, on production either.")))
        var report = await runCancel(plan, sql: sql, request: request, target: target, main: session)
        let accepted = [.cancelled, .stillRunning].contains(report.outcome)
        if accepted { _ = await process.waitForExit(within: .milliseconds(500)) }
        let held = session.control.settleServerCancel(accepted: accepted)
        for error in held { session.inject(.error(error)) }
        if accepted, !held.isEmpty { report.interrupted = true }
        session.inject(.sqlCancel(report))
        return report
    }

    /// The second runner: same target, same connection, the cancel statement, no slot (it
    /// never waits behind other runs), stopped after `SQLCancel.timeout`. A saved connection
    /// that opens from this Mac (#142) runs it where the run ran: the same local PHP in Runlet's
    /// empty folder (`LocalConnectionLaunch`), never on the tab's target. Its launch line goes to
    /// the run's Run Log (`main`).
    private func runCancel(_ plan: SQLCancel.Plan, sql: SQLSessionInfo, request: RunRequest, target: TargetSnapshot, main: RunSession) async -> SQLCancelReport {
        var report = SQLCancelReport(outcome: .failed, driver: sql.driver, session: sql.id, statement: plan.statement, transaction: sql.transaction)
        var cancel = RunRequest(tabId: UUID(), documentVersion: request.documentVersion, target: target, code: SQLCancel.code(plan, session: sql),
                                inspector: RunInspectorOptions(enabled: false, interceptMail: false, previews: false), magicComments: false)
        cancel.sqlConnection = request.sqlConnection
        cancel.hints = request.hints
        do {
            try LocalConnectionLaunch.check(cancel.sqlConnection, target: target)
        } catch {
            report.detail = "\(error)"
            return report
        }
        let timer = SQLCancelTimer()
        let session = RunSession(runId: cancel.runId, limits: limits)
        do {
            try launch(session, tabId: cancel.tabId, target: target, usesSlot: false, script: Self.script(for: cancel, credentials: credentials))
        } catch {
            report.detail = "\(error)"
            return report
        }
        let runId = cancel.runId
        let watchdog = Task { [weak self] in
            try await Task.sleep(for: SQLCancel.timeout)
            timer.markTimedOut()
            _ = await self?.cancel(runId: runId)
        }
        defer { watchdog.cancel() }
        var errors: [String] = []
        var received: SQLCancelReport?
        for await event in session.events {
            switch event.kind {
            case .error(let error): errors.append(error.message)
            case .sqlCancel(let report): received = report
            case .log(let entry) where entry.source == "launch":
                main.inject(.log(RunLogEntry(source: "cancel", message: "Second runner: " + entry.message, detail: entry.detail)))
            default: break
            }
        }
        if var reported = received {
            reported.driver = sql.driver
            reported.session = sql.id
            // MongoDB's runner names the operations it killed (#207: "killOp 4711").
            if plan.dialect != "mongodb" || !reported.statement.hasPrefix("killOp") { reported.statement = plan.statement }
            reported.transaction = sql.transaction
            return reported
        }
        if timer.timedOut {
            report.outcome = .timedOut
            return report
        }
        report.detail = errors.first ?? "the second runner ended without saying what happened"
        return report
    }
}

/// Whether the cancel runner's time ran out (#144).
final class SQLCancelTimer: @unchecked Sendable {
    private let lock = NSLock()
    private var _timedOut = false

    var timedOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return _timedOut
    }

    func markTimedOut() {
        lock.lock(); _timedOut = true; lock.unlock()
    }
}
