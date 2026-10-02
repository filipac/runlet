import Foundation
import Testing
@testable import RunletCore

/// What a test listener saw, collected across threads.
final class ListenerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var connectedIDs: [UUID] = []
    private var received: [(UUID, MCPBridge.ClientMessage)] = []
    private var closed: [UUID] = []

    func connected(_ id: UUID) { lock.withLock { connectedIDs.append(id) } }
    func message(_ id: UUID, _ message: MCPBridge.ClientMessage) { lock.withLock { received.append((id, message)) } }
    func disconnected(_ id: UUID) { lock.withLock { closed.append(id) } }

    var connections: [UUID] { lock.withLock { connectedIDs } }
    var messages: [MCPBridge.ClientMessage] { lock.withLock { received.map(\.1) } }
    var disconnections: [UUID] { lock.withLock { closed } }

    func wait(_ condition: @escaping () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

/// Socket tests use scratch folders under the temporary directory and remove them.
@Suite(.serialized)
struct MCPBridgeTests {
    static func scratch() -> (AppPaths, URL) {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("rl-mcp-" + UUID().uuidString.prefix(8), isDirectory: true)
        return (AppPaths(root: root), root)
    }

    static func listener(_ path: String, log: ListenerLog, answer: (@Sendable (MCPSocketListener, UUID, MCPBridge.ClientMessage) -> Void)? = nil) -> MCPSocketListener {
        let box = ListenerBox()
        let listener = MCPSocketListener(path: path, events: MCPSocketListener.Events(
            connected: { id, _ in log.connected(id) },
            message: { id, message in
                log.message(id, message)
                if let listener = box.listener { answer?(listener, id, message) }
            },
            disconnected: { id in log.disconnected(id) }
        ))
        box.listener = listener
        return listener
    }

    final class ListenerBox: @unchecked Sendable {
        weak var listener: MCPSocketListener?
    }

    @Test func messagesSurviveTheirLineForm() {
        let call = MCPBridge.ClientMessage.call(id: 3, client: MCPClientInfo(name: "x", title: "X"), call: .runPHP(target: "sandbox", code: "echo \"a\nb\";"))
        let data = MCPBridge.encode(call)
        #expect(data.last == 0x0A)
        #expect(data.dropLast().firstIndex(of: 0x0A) == nil, "one message per line")
        #expect(MCPBridge.decode(MCPBridge.ClientMessage.self, from: String(decoding: data.dropLast(), as: UTF8.self)) == call)
        let result = MCPBridge.AppMessage.result(id: 3, result: MCPToolResult(text: "=> 2", structured: ["status": "completed"], isError: false))
        #expect(MCPBridge.decode(MCPBridge.AppMessage.self, from: String(decoding: MCPBridge.encode(result).dropLast(), as: UTF8.self)) == result)
        for message in [MCPBridge.ClientMessage.hello(bridgeVersion: 1, helperPID: 42), .client(MCPClientInfo(name: "c")), .cancel(id: 9), .call(id: 1, client: .unknown, call: .listTargets), .call(id: 2, client: .unknown, call: .listSnippets(target: nil, query: "x")), .call(id: 4, client: .unknown, call: .getLastOutput)] {
            #expect(MCPBridge.decode(MCPBridge.ClientMessage.self, from: String(decoding: MCPBridge.encode(message).dropLast(), as: UTF8.self)) == message)
        }
    }

    @Test func socketPathsFollowTheDataFolder() {
        let short = AppPaths(root: URL(fileURLWithPath: "/Users/me/Library/Application Support/Runlet"))
        #expect(MCPSocketPaths.socketPath(for: short) == "/Users/me/Library/Application Support/Runlet/MCP/runlet.sock")
        let deep = AppPaths(root: URL(fileURLWithPath: "/Users/me/" + String(repeating: "very-long-folder-name/", count: 5) + "data"))
        let fallback = MCPSocketPaths.socketPath(for: deep)
        #expect(fallback.utf8.count <= MCPSocketPaths.maximumLength)
        #expect(fallback.hasPrefix(MCPSocketPaths.userTemporaryDirectory.path))
        #expect(fallback == MCPSocketPaths.socketPath(for: deep), "both ends compute the same path")
        let other = AppPaths(root: URL(fileURLWithPath: "/Users/me/" + String(repeating: "very-long-folder-name/", count: 5) + "other"))
        #expect(MCPSocketPaths.socketPath(for: other) != fallback, "each data folder gets its own socket")
    }

    @Test func listenerIsPrivateAndAnswers() async throws {
        let (paths, root) = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = MCPSocketPaths.socketPath(for: paths)
        let log = ListenerLog()
        let listener = Self.listener(path, log: log) { listener, id, message in
            if case .call(let callId, _, _) = message { listener.send(.result(id: callId, result: MCPToolResult(text: "pong")), to: id) }
        }
        try listener.start()
        defer { listener.stop() }

        var info = stat()
        #expect(lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK)
        #expect(info.st_mode & 0o777 == 0o600, "socket mode 0600")
        #expect(lstat(paths.mcp.path, &info) == 0 && info.st_mode & 0o777 == 0o700, "folder mode 0700")

        let replies = Replies()
        let client = MCPSocketClient(path: path)
        try client.connect(onMessage: { replies.append($0) }, onClose: {})
        #expect(client.send(.hello(bridgeVersion: MCPBridge.version, helperPID: getpid())))
        #expect(client.send(.call(id: 7, client: .unknown, call: .listTargets)))
        #expect(await log.wait { log.messages.count == 2 })
        #expect(await log.wait { replies.all.contains(.result(id: 7, result: MCPToolResult(text: "pong"))) })
        #expect(log.connections.count == 1)
        client.close()
        #expect(await log.wait { log.disconnections.count == 1 })
    }

    @Test func listenerDropsOversizedAndGarbledMessages() async throws {
        let (paths, root) = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = MCPSocketPaths.socketPath(for: paths)
        let log = ListenerLog()
        let listener = Self.listener(path, log: log)
        try listener.start()
        defer { listener.stop() }

        let fd = try UnixSocket.makeSocket()
        defer { close(fd) }
        try UnixSocket.connect(fd, to: path)
        var big = Data(repeating: 0x61, count: MCPBridge.maxClientMessageBytes + 10)
        big.append(0x0A)
        _ = UnixSocket.writeAll(fd, big, timeout: 5)
        #expect(await log.wait { log.disconnections.count == 1 }, "an oversized message closes the connection")

        let second = try UnixSocket.makeSocket()
        defer { close(second) }
        try UnixSocket.connect(second, to: path)
        _ = UnixSocket.writeAll(second, Data("not json\n".utf8), timeout: 5)
        #expect(await log.wait { log.disconnections.count == 2 }, "so does a message that isn't one")
        #expect(log.messages.isEmpty)
    }

    @Test func listenerLeavesForeignFilesAndLiveSocketsAlone() async throws {
        let (paths, root) = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = MCPSocketPaths.socketPath(for: paths)
        try MCPSocketPaths.prepareDirectory(for: path)
        try Data("keep me".utf8).write(to: URL(fileURLWithPath: path))
        let log = ListenerLog()
        #expect(throws: MCPSocketError.notASocket(path)) { try Self.listener(path, log: log).start() }
        #expect(FileManager.default.contents(atPath: path) == Data("keep me".utf8))
        try FileManager.default.removeItem(atPath: path)

        let first = Self.listener(path, log: log)
        try first.start()
        defer { first.stop() }
        #expect(throws: MCPSocketError.inUse(path)) { try Self.listener(path, log: log).start() }
    }

    @Test func listenerReplacesAStaleSocketAndTightensTheFolder() async throws {
        let (paths, root) = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = MCPSocketPaths.socketPath(for: paths)
        let log = ListenerLog()
        let first = Self.listener(path, log: log)
        try first.start()
        // A crash leaves the socket file behind: simulate by closing without unlinking.
        first.stop()
        let fd = try UnixSocket.makeSocket()
        var address = try UnixSocket.address(path)
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        close(fd)
        chmod(paths.mcp.path, 0o755)
        let second = Self.listener(path, log: log)
        try second.start()
        defer { second.stop() }
        var info = stat()
        #expect(lstat(paths.mcp.path, &info) == 0 && info.st_mode & 0o777 == 0o700)
        #expect(UnixSocket.isListening(path))
    }

    @Test func clientRefusesSocketsInOpenFolders() throws {
        let (paths, root) = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = MCPSocketPaths.socketPath(for: paths)
        let listener = Self.listener(path, log: ListenerLog())
        try listener.start()
        defer { listener.stop() }
        chmod(paths.mcp.path, 0o755)
        #expect(throws: MCPSocketError.wrongOwner) { try MCPSocketClient(path: path).connect(onMessage: { _ in }, onClose: {}) }
        chmod(paths.mcp.path, 0o700)
        let client = MCPSocketClient(path: path)
        try client.connect(onMessage: { _ in }, onClose: {})
        client.close()
        #expect(throws: MCPSocketError.notRunning) { try MCPSocketClient(path: path + ".missing").connect(onMessage: { _ in }, onClose: {}) }
    }

    @Test func appClientRoutesCallsAndStatus() async throws {
        let (paths, root) = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = MCPSocketPaths.socketPath(for: paths)
        let log = ListenerLog()
        let listener = Self.listener(path, log: log) { listener, id, message in
            guard case .call(let callId, let client, let call) = message else { return }
            listener.send(.status(id: callId, message: "Waiting for the user"), to: id)
            listener.send(.result(id: callId, result: MCPToolResult(text: "\(call.toolName) for \(client.displayName)")), to: id)
        }
        try listener.start()
        defer { listener.stop() }

        let backend = MCPAppClient(socketPath: path)
        #expect(backend.connectIfListening())
        backend.announce(MCPClientInfo(name: "claude-code", title: "Claude Code"))
        let statuses = Replies()
        let result = await backend.call(.listTargets, client: MCPClientInfo(name: "cursor"), progress: MCPProgress { statuses.appendText($0) })
        #expect(result == MCPToolResult(text: "list_targets for cursor"))
        #expect(statuses.texts == ["Waiting for the user"])
        #expect(await log.wait { log.messages.contains(.client(MCPClientInfo(name: "claude-code", title: "Claude Code"))) })
        #expect(log.messages.contains { if case .hello(MCPBridge.version, _) = $0 { true } else { false } })
        backend.disconnect()
    }

    @Test func appClientExplainsWhenRunletIsAway() async throws {
        let (paths, root) = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = MCPSocketPaths.socketPath(for: paths)
        let offline = MCPAppClient(socketPath: path)
        let result = await offline.call(.listTargets, client: .unknown, progress: MCPProgress())
        #expect(result.isError && result.text.contains("isn't running"))

        // A launcher that "starts" Runlet whose MCP server stays off.
        let launched = MCPAppClient(socketPath: path, connectWait: .milliseconds(300)) { .alreadyRunning }
        let off = await launched.call(.listTargets, client: .unknown, progress: MCPProgress())
        #expect(off.isError && off.text.contains("MCP server is off"))
        let failing = MCPAppClient(socketPath: path, connectWait: .milliseconds(300)) { .failed("no app") }
        #expect(await failing.call(.listTargets, client: .unknown, progress: MCPProgress()).text.contains("no app"))
    }

    @Test func appClientStartsRunletAndWaitsForItsSocket() async throws {
        let (paths, root) = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = MCPSocketPaths.socketPath(for: paths)
        let log = ListenerLog()
        let listener = Self.listener(path, log: log) { listener, id, message in
            if case .call(let callId, _, _) = message { listener.send(.result(id: callId, result: MCPToolResult(text: "up")), to: id) }
        }
        defer { listener.stop() }
        let launches = Replies()
        // "Starting Runlet": the socket appears a moment after the launch.
        let backend = MCPAppClient(socketPath: path, connectWait: .seconds(5)) {
            launches.appendText("launch")
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                try? listener.start()
            }
            return .launched
        }
        #expect(!backend.connectIfListening(), "connecting alone never starts Runlet")
        #expect(launches.texts.isEmpty)
        let result = await backend.call(.listTargets, client: .unknown, progress: MCPProgress())
        #expect(result == MCPToolResult(text: "up"))
        #expect(launches.texts == ["launch"])
        let again = await backend.call(.getLastOutput, client: .unknown, progress: MCPProgress())
        #expect(again == MCPToolResult(text: "up"))
        #expect(launches.texts == ["launch"], "a connected client doesn't start Runlet again")
        backend.disconnect()
    }

    @Test func appClientFailsWaitingCallsWhenTheAppGoesAway() async throws {
        let (paths, root) = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = MCPSocketPaths.socketPath(for: paths)
        let log = ListenerLog()
        let listener = Self.listener(path, log: log)
        try listener.start()
        let backend = MCPAppClient(socketPath: path)
        #expect(backend.connectIfListening())
        let pending = Task { await backend.call(.runPHP(target: "sandbox", code: "1"), client: .unknown, progress: MCPProgress()) }
        #expect(await log.wait { log.messages.contains { if case .call = $0 { true } else { false } } })
        listener.stop()
        let result = await pending.value
        #expect(result.isError && result.text.contains("closed the connection"))
    }

    @Test func appClientCancelsCallsInTheApp() async throws {
        let (paths, root) = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = MCPSocketPaths.socketPath(for: paths)
        let log = ListenerLog()
        let listener = Self.listener(path, log: log)
        try listener.start()
        defer { listener.stop() }
        let backend = MCPAppClient(socketPath: path)
        let pending = Task { await backend.call(.runPHP(target: "sandbox", code: "1"), client: .unknown, progress: MCPProgress()) }
        #expect(await log.wait { log.messages.contains { if case .call = $0 { true } else { false } } })
        pending.cancel()
        #expect(await pending.value.isError)
        #expect(await log.wait { log.messages.contains { if case .cancel = $0 { true } else { false } } }, "the app hears about it and withdraws the approval")
    }
}

final class Replies: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [MCPBridge.AppMessage] = []
    private var strings: [String] = []

    func append(_ message: MCPBridge.AppMessage) { lock.withLock { messages.append(message) } }
    func appendText(_ text: String) { lock.withLock { strings.append(text) } }
    var all: [MCPBridge.AppMessage] { lock.withLock { messages } }
    var texts: [String] { lock.withLock { strings } }
}
