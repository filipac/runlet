import Foundation
import RunletCore

public struct LSPResponseError: Error, Sendable, CustomStringConvertible {
    public var code: Int
    public var message: String
    public var description: String { "LSP error \(code): \(message)" }

    /// Request cancelled (by the client) or content modified.
    public var isCancellation: Bool { code == -32800 || code == -32801 }
}

public struct LSPConnectionClosed: Error, Sendable, CustomStringConvertible {
    public var description: String { "The language server connection closed." }
}

/// JSON-RPC 2.0 over a child process's stdin/stdout with LSP Content-Length framing.
/// Protocol messages travel only on stdout; stderr is kept separately as a log.
public final class LSPConnection: @unchecked Sendable {
    public typealias NotificationHandler = @Sendable (_ method: String, _ params: JSONValue) -> Void

    private let process: SupervisedProcess
    private let lock = NSLock()
    private var nextId = 0
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var closed = false
    private var stderrLog = Data()
    private let onNotification: NotificationHandler
    private let onClose: @Sendable () -> Void

    public init(process: SupervisedProcess, onNotification: @escaping NotificationHandler, onClose: @escaping @Sendable () -> Void) {
        self.process = process
        self.onNotification = onNotification
        self.onClose = onClose
        Task.detached { [self] in await self.readLoop() }
    }

    public var pid: pid_t { process.pid }

    /// Recent stderr output (logs only, never parsed as protocol).
    public var recentLog: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: stderrLog, as: UTF8.self)
    }

    private func readLoop() async {
        var buffer = Data()
        for await chunk in process.output {
            switch chunk {
            case .stderr(let data):
                appendLog(data)
            case .stdout(let data):
                buffer.append(data)
                while let message = Self.extractMessage(from: &buffer) {
                    handle(message)
                }
            }
        }
        failAll()
        onClose()
    }

    private func appendLog(_ data: Data) {
        lock.withLock {
            stderrLog.append(data)
            if stderrLog.count > 64 * 1024 { stderrLog = stderrLog.suffix(32 * 1024) }
        }
    }

    static func extractMessage(from buffer: inout Data) -> Data? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else { return nil }
        let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var length: Int?
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                length = Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        guard let length else {
            buffer.removeSubrange(buffer.startIndex..<headerEnd.upperBound)
            return nil
        }
        let bodyStart = headerEnd.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        let body = buffer.subdata(in: bodyStart..<bodyEnd)
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        buffer = Data(buffer)
        return body
    }

    private func handle(_ body: Data) {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: body) else { return }
        let method = message["method"]?.stringValue
        let id = message["id"]
        if let method {
            if let id {
                // Server-to-client request: answer generically so the server never waits.
                let result: JSONValue
                switch method {
                case "workspace/configuration":
                    let count = message["params"]?["items"]?.arrayValue?.count ?? 1
                    result = .array(Array(repeating: .null, count: count))
                default:
                    result = .null
                }
                send(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
            } else {
                onNotification(method, message["params"] ?? .null)
            }
            return
        }
        guard let idNumber = id?.intValue else { return }
        lock.lock()
        let continuation = pending.removeValue(forKey: idNumber)
        lock.unlock()
        if let error = message["error"] {
            continuation?.resume(throwing: LSPResponseError(code: error["code"]?.intValue ?? 0, message: error["message"]?.stringValue ?? "unknown error"))
        } else {
            continuation?.resume(returning: message["result"] ?? .null)
        }
    }

    private func send(_ message: JSONValue) {
        guard let body = try? JSONEncoder().encode(message) else { return }
        var data = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        data.append(body)
        process.write(data)
    }

    public func notify(_ method: String, _ params: JSONValue) {
        lock.lock()
        let isClosed = closed
        lock.unlock()
        guard !isClosed else { return }
        send(.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params]))
    }

    /// Sends a request. Cancelling the calling task sends `$/cancelRequest`.
    public func request(_ method: String, _ params: JSONValue, timeout: Duration = .seconds(30)) async throws -> JSONValue {
        let id: Int? = lock.withLock {
            guard !closed else { return nil }
            nextId += 1
            return nextId
        }
        guard let id else { throw LSPConnectionClosed() }

        let timeoutTask = Task { [weak self] in
            try await Task.sleep(for: timeout)
            self?.fail(id: id, error: LSPResponseError(code: -32800, message: "\(method) timed out"))
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                pending[id] = continuation
                lock.unlock()
                send(.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params]))
            }
        } onCancel: { [weak self] in
            self?.notify("$/cancelRequest", .object(["id": .number(Double(id))]))
            self?.fail(id: id, error: CancellationError())
        }
    }

    private func fail(id: Int, error: Error) {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    private func failAll() {
        lock.lock()
        closed = true
        let all = pending
        pending = [:]
        lock.unlock()
        all.values.forEach { $0.resume(throwing: LSPConnectionClosed()) }
    }

    public func terminate() async {
        process.closeStdin()
        if !(await process.waitForExit(within: .seconds(1))) {
            await process.terminate(grace: .milliseconds(500), timeout: .seconds(2))
        }
    }

    /// Simulates a crash (used by tests and the "Restart language server" action).
    public func kill() {
        process.send(SIGKILL)
    }
}
