import Foundation
import RunletCore

/// Why Show Definition (#148) has no definition to show: the runner's message (an unknown
/// name, a database Runlet can't read definitions on, a catalog error) or a timeout.
public struct SQLDefinitionLoadError: Error, CustomStringConvertible, Sendable, Equatable {
    public var description: String

    public init(_ description: String) {
        self.description = description
    }
}

extension ExecutionEngine {
    /// Show Definition (#148): reads one table's or view's definition from the catalog of an
    /// SQL connection, in a fresh runner, like Load Schema (`loadSQLSchema`): the runner boots
    /// the project (or, with `saved`, opens that saved connection without project code),
    /// resolves the connection as a statement would, and reads only the catalog. Nothing is
    /// created or changed, and the DDL is never run. Call it only when the user asks, after
    /// any production confirmation.
    ///
    /// A saved connection that opens from this Mac (#142) must come with a this-Mac snapshot
    /// (`LocalConnectionLaunch`); it is never sent to the target.
    public func loadSQLDefinition(target: TargetSnapshot, table: String, connection: String?, saved: DatabaseConnection? = nil, timeout: Duration = .seconds(60)) async throws -> SQLDefinitionInfo {
        try LocalConnectionLaunch.check(saved, target: target) // #142
        let runId = UUID()
        let report = DefinitionReport()
        let session = RunSession(runId: runId, limits: limits) { type, payload in
            if type == "sqlDefinition", let info = try? JSONDecoder().decode(SQLDefinitionInfo.self, from: payload) { report.set(info) }
        }
        let code = SQLDefinition.code(table: table, connection: saved == nil ? connection : nil)
        let credentials = self.credentials
        try launch(session, tabId: runId, target: target) { bundle, nonce, limits in
            let connection = try saved.map { try Self.runnerConnection($0, password: .stored, credentials: credentials) }
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
        if let info = report.value { return info }
        if report.didTimeOut {
            throw SQLDefinitionLoadError("Reading the definition took longer than \(timeout.components.seconds) s, so Runlet stopped it. The application may be waiting on its database.")
        }
        if let error = errors.first { throw SQLDefinitionLoadError(error.message) }
        throw SQLDefinitionLoadError("The runner ended without reporting the definition.")
    }
}

/// Show Definition's report and timeout, set from the event pump and the watchdog.
private final class DefinitionReport: @unchecked Sendable {
    private let lock = NSLock()
    private var info: SQLDefinitionInfo?
    private var expired = false

    func set(_ value: SQLDefinitionInfo) {
        lock.lock()
        info = value
        lock.unlock()
    }

    func timedOut() {
        lock.lock()
        expired = true
        lock.unlock()
    }

    var value: SQLDefinitionInfo? {
        lock.lock()
        defer { lock.unlock() }
        return info
    }

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expired
    }
}
