import Foundation
import RunletCore

/// Why the key browser or the server panel (#190) has nothing to show: the runner's message or
/// a timeout.
public struct RedisLoadError: Error, CustomStringConvertible, Sendable, Equatable {
    public var description: String

    public init(_ description: String) {
        self.description = description
    }
}

extension ExecutionEngine {
    /// Runs one Redis panel runner (#190: the key browser's SCAN page, Open Value, Memory Usage,
    /// the server panel, Kill Client) in a fresh runner, like Load Schema: on the target (the
    /// application's connection, booting the project) or with `saved`, opening that saved
    /// connection without project code. Returns the payload of the runner's `event`. Call it
    /// only when the user asks, after any production confirmation.
    public func runRedisPanel<Value: Decodable & Sendable>(target: TargetSnapshot, code: String, event: String, as type: Value.Type, saved: DatabaseConnection?, timeout: Duration = .seconds(60)) async throws -> Value {
        try LocalConnectionLaunch.check(saved, target: target) // #142
        let runId = UUID()
        let report = RedisPanelReport<Value>()
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
        var replies: [RedisReplyInfo] = []
        var notices: [String] = []
        await withTaskCancellationHandler {
            for await item in session.events {
                switch item.kind {
                case .error(let error): errors.append(error)
                case .redis(let reply): replies.append(reply)
                case .notice(let text): notices.append(text)
                default: break
                }
            }
        } onCancel: {
            Task { await self.cancel(runId: runId) }
        }
        try Task.checkCancellation()
        if event == "redis", let reply = replies.last as? Value { return reply }
        if let value = report.value { return value }
        if report.didTimeOut { throw RedisLoadError("Redis didn't answer within \(timeout.components.seconds) s, so Runlet stopped. The server or the application may be busy.") }
        throw RedisLoadError(errors.first.map { RedisLoadError.describe($0) } ?? notices.first ?? "The runner ended without an answer.")
    }

    /// The key browser: one SCAN page.
    public func loadRedisKeys(target: TargetSnapshot, db: Int, pattern: String, cursor: String, count: Int, type: String?, connection: String?, saved: DatabaseConnection?, details: Bool = true) async throws -> RedisKeyPage {
        try await runRedisPanel(target: target, code: RedisTabRun.keysCode(db: db, pattern: pattern, cursor: cursor, count: count, type: type, connection: saved == nil ? connection : nil, details: details), event: "redisKeys", as: RedisKeyPage.self, saved: saved)
    }

    /// Open Value: the key's value as a reply.
    public func loadRedisValue(target: TargetSnapshot, db: Int, key: [UInt8], maxElements: Int, connection: String?, saved: DatabaseConnection?) async throws -> RedisReplyInfo {
        try await runRedisPanel(target: target, code: RedisTabRun.valueCode(db: db, key: key, maxElements: maxElements, connection: saved == nil ? connection : nil), event: "redis", as: RedisReplyInfo.self, saved: saved)
    }

    /// Memory Usage: one key's details.
    public func loadRedisKeyDetails(target: TargetSnapshot, db: Int, key: [UInt8], connection: String?, saved: DatabaseConnection?) async throws -> RedisKeyDetails {
        try await runRedisPanel(target: target, code: RedisTabRun.keyInfoCode(db: db, key: key, connection: saved == nil ? connection : nil), event: "redisKeyInfo", as: RedisKeyDetails.self, saved: saved)
    }

    /// The server panel: INFO and CLIENT LIST.
    public func loadRedisServer(target: TargetSnapshot, connection: String?, saved: DatabaseConnection?) async throws -> RedisServerReport {
        try await runRedisPanel(target: target, code: RedisTabRun.serverCode(connection: saved == nil ? connection : nil), event: "redisServer", as: RedisServerReport.self, saved: saved, timeout: .seconds(30))
    }

    /// A confirmed Kill Client. Never throws for the kill itself: its outcome is in the report.
    public func killRedisClient(target: TargetSnapshot, clientId: Int64, address: String, runId: String, listedBy: Int64, connection: String?, saved: DatabaseConnection?) async -> RedisKillReport {
        do {
            return try await runRedisPanel(target: target, code: RedisTabRun.killCode(clientId: clientId, address: address, runId: runId, listedBy: listedBy, connection: saved == nil ? connection : nil), event: "redisKill", as: RedisKillReport.self, saved: saved, timeout: .seconds(20))
        } catch {
            return RedisKillReport(id: clientId, outcome: .failed, detail: "\(error)")
        }
    }
}

extension RedisLoadError {
    /// A runner error's message, with the runner's own class names in words.
    static func describe(_ error: RunErrorInfo) -> String {
        error.message
    }
}

/// A Redis panel runner's report and timeout, set from the event pump and the watchdog.
private final class RedisPanelReport<Value: Sendable>: @unchecked Sendable {
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
