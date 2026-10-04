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
    ///
    /// With `saved` (#138), the runner opens that saved connection instead: it boots no
    /// project code, and the password comes from the credential store as for a run.
    public func loadSQLSchema(target: TargetSnapshot, connection: String?, saved: DatabaseConnection? = nil, timeout: Duration = .seconds(60)) async throws -> SQLSchemaInfo {
        try LocalConnectionLaunch.check(saved, target: target) // #142
        let runId = UUID()
        let session = RunSession(runId: runId, limits: limits)
        let code = SQLTabRun.schemaCode(connection: saved == nil ? connection : nil)
        let credentials = self.credentials
        try launch(session, tabId: runId, target: target) { bundle, nonce, limits in
            let connection = try saved.map { try Self.runnerConnection($0, password: .stored, credentials: credentials, tunnel: target.sqlTunnel) }
            return bundle.script(code: code, nonce: nonce, runId: runId, magicComments: false, limits: limits, sqlConnection: connection)
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

/// Why Test Connection (#138) failed: the runner's message (never a password: the runner
/// replaces it with •••), a missing PDO driver, or the target being unreachable.
public struct SQLConnectionTestError: Error, CustomStringConvertible, Sendable, Equatable {
    public var description: String

    public init(_ description: String) {
        self.description = description
    }
}

extension ExecutionEngine {
    /// Test Connection (#138): opens `connection` on the target, in the target's PHP (local
    /// PHP, `docker exec`, SSH), or from this Mac (#142: `LocalConnectionLaunch`), and reports the server's version, the current database and
    /// user, and the round trip. The runner boots no project code and runs no statement of
    /// the user's. `password` is the one typed in the editor (not saved yet) or the stored one.
    public func testSQLConnection(target: TargetSnapshot, connection: DatabaseConnection, password: SQLPassword, timeout: Duration = .seconds(60)) async throws -> SQLConnectionTestInfo {
        try LocalConnectionLaunch.check(connection, target: target) // #142
        let runId = UUID()
        let report = TestReport()
        let session = RunSession(runId: runId, limits: limits) { type, payload in
            if type == "sqlTest", let info = try? JSONDecoder().decode(SQLConnectionTestInfo.self, from: payload) { report.set(info) }
        }
        let credentials = self.credentials
        try launch(session, tabId: runId, target: target) { bundle, nonce, limits in
            let saved = try Self.runnerConnection(connection, password: password, credentials: credentials, tunnel: target.sqlTunnel)
            // #190: a Redis connection is tested by Runlet's RESP client.
            return bundle.script(code: connection.driver.family == .redis ? RedisTabRun.testCode : connection.driver == .mongodb ? "\\RunletRunner\\MongoTab::test();" : SQLTabRun.testCode, nonce: nonce, runId: runId, magicComments: false, limits: limits, sqlConnection: saved)
        }
        let timedOut = TimeoutFlag()
        let watchdog = Task { [weak self] in
            try await Task.sleep(for: timeout)
            timedOut.set()
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
        if timedOut.isSet {
            throw SQLConnectionTestError("The test took longer than \(timeout.components.seconds) s, so Runlet stopped it.")
        }
        if let error = errors.first { throw SQLConnectionTestError(error.message) }
        throw SQLConnectionTestError("The runner ended without reporting the connection.")
    }
}

/// Test Connection's report, set from the event pump.
private final class TestReport: @unchecked Sendable {
    private let lock = NSLock()
    private var info: SQLConnectionTestInfo?

    func set(_ value: SQLConnectionTestInfo) {
        lock.lock()
        info = value
        lock.unlock()
    }

    var value: SQLConnectionTestInfo? {
        lock.lock()
        defer { lock.unlock() }
        return info
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
