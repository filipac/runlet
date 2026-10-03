import Foundation
import RunletCore

/// Why Load Schema (#128) has no schema to show.
public struct SQLSchemaLoadError: Error, CustomStringConvertible, Sendable, Equatable {
    public var description: String

    public init(_ description: String) {
        self.description = description
    }
}

extension ExecutionEngine {
    /// Reads the tables and columns of an SQL tab's connection for completion (#128): the
    /// runner boots the project like a run (local PHP, `docker exec`, the Docker sandbox, or
    /// SSH), resolves the connection the way a statement would (`SqlTab::schema()`), and reads
    /// only names and types. It runs project code: call it only when the user asks (Load
    /// Schema), after any production confirmation. A fresh pseudo tab id keeps it apart from
    /// the tab's own runs.
    public func loadSQLSchema(target: TargetSnapshot, connection: String?, timeout: Duration = .seconds(60)) async throws -> SQLSchemaInfo {
        let runId = UUID()
        let session = RunSession(runId: runId, limits: limits)
        let code = SQLTabRun.schemaCode(connection: connection)
        try launch(session, tabId: runId, target: target) { bundle, nonce, limits in
            bundle.script(code: code, nonce: nonce, runId: runId, magicComments: false, limits: limits)
        }
        let timedOut = TimeoutFlag()
        let watchdog = Task { [weak self] in
            try await Task.sleep(for: timeout)
            timedOut.set()
            _ = await self?.cancel(runId: runId)
        }
        defer { watchdog.cancel() }

        var schema: SQLSchemaInfo?
        var errors: [RunErrorInfo] = []
        await withTaskCancellationHandler {
            for await event in session.events {
                switch event.kind {
                case .sqlSchema(let info): schema = info
                case .error(let error): errors.append(error)
                default: break
                }
            }
        } onCancel: {
            Task { await self.cancel(runId: runId) }
        }
        try Task.checkCancellation()
        if let schema {
            if let error = schema.error { throw SQLSchemaLoadError(error) }
            return schema
        }
        if timedOut.isSet {
            throw SQLSchemaLoadError("Reading the schema took longer than \(timeout.components.seconds) s, so Runlet stopped it. The application may be waiting on its database.")
        }
        if let error = errors.first {
            throw SQLSchemaLoadError(error.message)
        }
        throw SQLSchemaLoadError("The runner ended without reporting the schema.")
    }
}

/// Set once by the watchdog; read after the run's events end.
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
