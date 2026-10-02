import Foundation

/// `runlet mcp`'s link to the running app (#43): sends each tool call over the MCP socket and
/// waits for the app's answer. It connects when the app listens, and before a call it can
/// start Runlet (`launcher`), which never runs anything by itself.
public final class MCPAppClient: MCPToolBackend, @unchecked Sendable {
    public enum LaunchOutcome: Sendable, Equatable {
        case launched
        case alreadyRunning
        case failed(String)
    }

    private struct Pending {
        var continuation: CheckedContinuation<MCPToolResult, Never>
        var progress: MCPProgress
        /// The connection the call went out on.
        var generation: Int
    }

    private let socket: MCPSocketClient
    private let launcher: (@Sendable () async -> LaunchOutcome)?
    private let connectWait: Duration
    private let lock = NSLock()
    private var nextId = 1
    private var pending: [Int: Pending] = [:]
    private var cancelledEarly: Set<Int> = []
    private var client: MCPClientInfo?
    private var refusal: String?
    /// Counts connections, so a closed one fails only its own calls.
    private var generation = 0

    /// - Parameters:
    ///   - launcher: starts Runlet when nothing listens (nil: report that it isn't running).
    ///   - connectWait: how long to wait for the socket after starting Runlet.
    public init(socketPath: String, connectWait: Duration = .seconds(20), launcher: (@Sendable () async -> LaunchOutcome)? = nil) {
        socket = MCPSocketClient(path: socketPath)
        self.connectWait = connectWait
        self.launcher = launcher
    }

    /// Connects if Runlet listens; never starts it.
    @discardableResult
    public func connectIfListening() -> Bool {
        lock.withLock {
            if socket.isConnected { return true }
            let next = generation + 1
            do {
                try socket.connect(onMessage: { [weak self] message in self?.received(message) }, onClose: { [weak self] in self?.closed(next) })
            } catch {
                return false
            }
            generation = next
            refusal = nil
            socket.send(.hello(bridgeVersion: MCPBridge.version, helperPID: getpid()))
            if let client { socket.send(.client(client)) }
            return true
        }
    }

    /// The client `initialize` named, shown in Runlet's Settings (sent again after a reconnect).
    public func announce(_ client: MCPClientInfo) {
        lock.withLock { self.client = client }
        socket.send(.client(client))
    }

    public func disconnect() {
        socket.close()
    }

    public func call(_ call: MCPToolCall, client: MCPClientInfo, progress: MCPProgress) async -> MCPToolResult {
        if let problem = await ensureConnected() { return .error(problem) }
        if Task.isCancelled { return .error("The request was cancelled.") }
        let id = lock.withLock {
            defer { nextId += 1 }
            return nextId
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<MCPToolResult, Never>) in
                let proceed = lock.withLock { () -> Bool in
                    if cancelledEarly.remove(id) != nil { return false }
                    pending[id] = Pending(continuation: continuation, progress: progress, generation: generation)
                    return true
                }
                guard proceed else { return continuation.resume(returning: .error("The request was cancelled.")) }
                if !socket.send(.call(id: id, client: client, call: call)) {
                    finish(id, with: .error(Self.lostConnection))
                }
            }
        } onCancel: {
            let waiting = lock.withLock { () -> Pending? in
                if let waiting = pending.removeValue(forKey: id) { return waiting }
                cancelledEarly.insert(id)
                return nil
            }
            // The app withdraws an approval it is still asking for; a run already started
            // finishes in its tab (get_last_output returns it).
            socket.send(.cancel(id: id))
            waiting?.continuation.resume(returning: .error("The request was cancelled."))
        }
    }

    static let lostConnection = "Runlet closed the connection (it quit, or turned its MCP server off) before answering. If a run had started, its tab in Runlet shows what happened."

    /// Nil once connected; otherwise why the call can't go through.
    private func ensureConnected() async -> String? {
        if let refusal = lock.withLock({ refusal }) { return refusal }
        if connectIfListening() { return nil }
        guard let launcher else { return "Runlet isn't running, or its MCP server is off (Runlet ▸ Settings ▸ AI Clients)." }
        let outcome = await launcher()
        if case .failed(let message) = outcome { return "Couldn't start Runlet: \(message)" }
        let deadline = ContinuousClock.now + connectWait
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return "The request was cancelled." }
            try? await Task.sleep(for: .milliseconds(250))
            if connectIfListening() { return nil }
        }
        let start = outcome == .launched ? "Runlet started, but its MCP server is off." : "Runlet is running, but its MCP server is off."
        return start + " The user can turn it on in Runlet ▸ Settings ▸ AI Clients (“Allow AI clients to connect”), then try again."
    }

    private func received(_ message: MCPBridge.AppMessage) {
        switch message {
        case .welcome:
            break
        case .status(let id, let text):
            let progress = lock.withLock { pending[id]?.progress }
            progress?.report(text)
        case .result(let id, let result):
            finish(id, with: result)
        case .refused(let text):
            lock.withLock { refusal = text }
            failAll(text)
        }
    }

    private func closed(_ connection: Int) {
        failAll(lock.withLock { refusal } ?? Self.lostConnection, generation: connection)
    }

    private func finish(_ id: Int, with result: MCPToolResult) {
        let waiting = lock.withLock { pending.removeValue(forKey: id) }
        waiting?.continuation.resume(returning: result)
    }

    private func failAll(_ text: String, generation: Int? = nil) {
        let waiting = lock.withLock { () -> [Pending] in
            let ids = pending.filter { generation == nil || $0.value.generation == generation }.map(\.key)
            return ids.compactMap { pending.removeValue(forKey: $0) }
        }
        for entry in waiting { entry.continuation.resume(returning: .error(text)) }
    }
}
