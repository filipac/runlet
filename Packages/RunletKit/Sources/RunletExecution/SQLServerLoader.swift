import Foundation
import RunletCore

/// Why the Server section (#150) has nothing to show: the runner's message (a database the panel
/// doesn't support, a connection that failed) or a timeout.
public struct SQLServerLoadError: Error, CustomStringConvertible, Sendable, Equatable {
    public var description: String

    public init(_ description: String) {
        self.description = description
    }
}

extension ExecutionEngine {
    /// The Database pane's Server section (#150): reads `parts` of the server report on an SQL
    /// connection, in a fresh runner, like Load Schema (`loadSQLSchema`): the runner boots the
    /// project (or, with `saved`, opens that saved connection without project code), resolves the
    /// connection as a statement would, and reads only the catalog and the server's status. Call it
    /// only when the user asks (after any production confirmation) or on the refresh interval the
    /// user turned on, which production connections never offer.
    ///
    /// A saved connection that opens from this Mac (#142) must come with a this-Mac snapshot
    /// (`LocalConnectionLaunch`); it is never sent to the target.
    public func loadSQLServerInfo(target: TargetSnapshot, parts: [SQLServerInfo.Part] = SQLServerInfo.Part.allCases, connection: String?, saved: DatabaseConnection? = nil, timeout: Duration = SQLServerPanel.readTimeout) async throws -> SQLServerInfo {
        let code = SQLServerPanel.code(parts: parts, connection: saved == nil ? connection : nil)
        let outcome = try await runServerPanel(target: target, code: code, event: "sqlServer", as: SQLServerInfo.self, saved: saved, timeout: timeout)
        switch outcome {
        case .reported(let info):
            return info
        case .timedOut:
            throw SQLServerLoadError("Reading the server details took longer than \(timeout.components.seconds) s, so Runlet stopped it. The application or the server may be busy.")
        case .failed(let message):
            throw SQLServerLoadError(message ?? "The runner ended without reporting the server details.")
        }
    }

    /// A confirmed Cancel Query or Kill Session (#150): a fresh runner opens the same connection
    /// again and sends `plan`'s statement after checking it reached the server the list came from
    /// and that the session isn't the list's own nor its own, and is still the one listed. Never
    /// throws for the action itself: a refusal, a failure, or a timeout is in the report.
    public func runSQLServerAction(_ plan: SQLServerActionPlan, target: TargetSnapshot, connection: String?, saved: DatabaseConnection? = nil, timeout: Duration = SQLServerPanel.actionTimeout) async -> SQLServerActionReport {
        var report = SQLServerActionReport(action: plan.action, outcome: .failed, driver: plan.dialect, session: plan.session, statement: plan.statement)
        let code = SQLServerPanel.code(plan, connection: saved == nil ? connection : nil)
        do {
            switch try await runServerPanel(target: target, code: code, event: "sqlServerAction", as: SQLServerActionReport.self, saved: saved, timeout: timeout) {
            case .reported(var received):
                // The plan names what was asked for; the runner can't change it.
                received.action = plan.action
                received.session = plan.session
                received.statement = plan.statement
                return received
            case .timedOut:
                report.outcome = .timedOut
            case .failed(let message):
                report.detail = message ?? "the runner ended without saying what happened"
            }
        } catch is CancellationError {
            report.detail = "stopped before the runner answered"
        } catch {
            report.detail = "\(error)"
        }
        return report
    }

    private enum ServerPanelOutcome<Value> {
        case reported(Value)
        case timedOut
        case failed(String?)
    }

    /// One runner for the Server section: launches `code`, decodes the `event` it reports, and
    /// stops it after `timeout` or when the task is cancelled.
    private func runServerPanel<Value: Decodable & Sendable>(target: TargetSnapshot, code: String, event: String, as type: Value.Type, saved: DatabaseConnection?, timeout: Duration) async throws -> ServerPanelOutcome<Value> {
        try LocalConnectionLaunch.check(saved, target: target) // #142
        let runId = UUID()
        let report = ServerPanelReport<Value>()
        let session = RunSession(runId: runId, limits: limits) { type, payload in
            if type == event, let value = try? JSONDecoder().decode(Value.self, from: payload) { report.set(value) }
        }
        let credentials = self.credentials
        try launch(session, tabId: runId, target: target) { bundle, nonce, limits in
            let connection = try saved.map { try Self.runnerConnection($0, password: .stored, credentials: credentials, tunnel: target.sqlTunnel) } // #143
            return bundle.script(code: code, nonce: nonce, runId: runId, magicComments: false, limits: limits, sqlConnection: connection)
        }
        let watchdog = Task { [weak self] in
            try await Task.sleep(for: timeout)
            report.timedOut()
            _ = await self?.cancel(runId: runId)
        }
        defer { watchdog.cancel() }

        var errors: [RunErrorInfo] = []
        await withTaskCancellationHandler {
            for await event in session.events {
                if case .error(let error) = event.kind { errors.append(error) }
            }
        } onCancel: {
            Task { await self.cancel(runId: runId) }
        }
        try Task.checkCancellation()
        if let value = report.value { return .reported(value) }
        if report.didTimeOut { return .timedOut }
        return .failed(errors.first?.message)
    }
}

/// A Server section runner's report and timeout, set from the event pump and the watchdog.
private final class ServerPanelReport<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    private var expired = false

    func set(_ value: Value) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    func timedOut() {
        lock.lock()
        expired = true
        lock.unlock()
    }

    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expired
    }
}
