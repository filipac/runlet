import Foundation
import RunletCore

/// Why the MongoDB Server section (#207) has nothing to show: the runner's message or a timeout.
public struct MongoLoadError: Error, CustomStringConvertible, Sendable, Equatable {
    public var description: String

    public init(_ description: String) {
        self.description = description
    }
}

extension ExecutionEngine {
    /// Runs one MongoDB panel runner (#207: the Server section's read, Kill Op) in a fresh runner,
    /// like Redis's panels: on the target (the application's connection, booting the project) or
    /// with `saved`, opening that saved connection without project code. Returns the payload of the
    /// runner's `event`. Call it only when the user asks, after any production confirmation.
    public func runMongoPanel<Value: Decodable & Sendable>(target: TargetSnapshot, code: String, event: String, as type: Value.Type, saved: DatabaseConnection?, timeout: Duration = .seconds(30)) async throws -> Value {
        try LocalConnectionLaunch.check(saved, target: target) // #142
        let runId = UUID()
        let report = MongoPanelReport<Value>()
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
        var notices: [String] = []
        await withTaskCancellationHandler {
            for await item in session.events {
                switch item.kind {
                case .error(let error): errors.append(error)
                case .notice(let text): notices.append(text)
                default: break
                }
            }
        } onCancel: {
            Task { await self.cancel(runId: runId) }
        }
        try Task.checkCancellation()
        if let value = report.value { return value }
        if report.didTimeOut { throw MongoLoadError("MongoDB didn't answer within \(timeout.components.seconds) s, so Runlet stopped. The server or the application may be busy.") }
        throw MongoLoadError(errors.first?.message ?? notices.first ?? "The runner ended without an answer.")
    }

    /// The Server section: `serverStatus` and `$currentOp`.
    public func loadMongoServer(target: TargetSnapshot, connection: String?, saved: DatabaseConnection?) async throws -> MongoServerReport {
        try await runMongoPanel(target: target, code: MongoServerPanel.serverCode(connection: saved == nil ? connection : nil), event: "mongoServer", as: MongoServerReport.self, saved: saved)
    }

    /// A confirmed Kill Op. Never throws for the kill itself: its outcome is in the report.
    public func killMongoOperation(_ operation: MongoServerReport.Operation, report: MongoServerReport, target: TargetSnapshot, connection: String?, saved: DatabaseConnection?) async -> MongoKillReport {
        do {
            return try await runMongoPanel(target: target, code: MongoServerPanel.killCode(operation, report: report, connection: saved == nil ? connection : nil), event: "mongoKill", as: MongoKillReport.self, saved: saved, timeout: .seconds(20))
        } catch {
            return MongoKillReport(opid: operation.opid, outcome: .failed, detail: "\(error)")
        }
    }
}

/// A MongoDB panel runner's report and timeout, set from the event pump and the watchdog.
private final class MongoPanelReport<Value: Sendable>: @unchecked Sendable {
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
