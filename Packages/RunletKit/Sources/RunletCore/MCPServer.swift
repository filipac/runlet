import Foundation

/// Splits a byte stream into newline-delimited messages (the MCP stdio framing, also used on
/// Runlet's own socket). `\r\n` endings are accepted. A message longer than `maxLineBytes`
/// is dropped up to its newline and reported once, so one oversized message can't exhaust
/// memory or desynchronize the stream.
public struct JSONLineFramer: Sendable {
    public enum Item: Equatable, Sendable {
        case line(String)
        /// A message over the limit was dropped (its size so far).
        case oversized(Int)
    }

    public let maxLineBytes: Int
    private var buffer = Data()
    private var discarding = false
    private var discarded = 0

    public init(maxLineBytes: Int) {
        self.maxLineBytes = maxLineBytes
    }

    /// Adds bytes and returns the complete messages they finish, in order.
    public mutating func append(_ data: Data) -> [Item] {
        var items: [Item] = []
        var rest = data[...]
        while let newline = rest.firstIndex(of: 0x0A) {
            let chunk = rest[rest.startIndex..<newline]
            rest = rest[rest.index(after: newline)...]
            if discarding {
                discarding = false
                items.append(.oversized(discarded + chunk.count))
                discarded = 0
                continue
            }
            if buffer.count + chunk.count > maxLineBytes {
                items.append(.oversized(buffer.count + chunk.count))
                buffer.removeAll(keepingCapacity: false)
                continue
            }
            buffer.append(chunk)
            if buffer.last == 0x0D { buffer.removeLast() }
            let line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll(keepingCapacity: true)
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { items.append(.line(line)) }
        }
        if discarding {
            discarded += rest.count
        } else if buffer.count + rest.count > maxLineBytes {
            discarding = true
            discarded = buffer.count + rest.count
            buffer.removeAll(keepingCapacity: false)
        } else {
            buffer.append(contentsOf: rest)
        }
        return items
    }
}

/// Status updates a tool call reports while it waits ("Waiting for approval in Runlet").
public final class MCPProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (String) -> Void)?

    public init(_ handler: (@Sendable (String) -> Void)? = nil) {
        self.handler = handler
    }

    public func report(_ message: String) {
        let handler = lock.withLock { self.handler }
        handler?(message)
    }

    func stop() {
        lock.withLock { handler = nil }
    }
}

/// Where `runlet mcp` sends tool calls: the running app, through its socket.
public protocol MCPToolBackend: Sendable {
    /// Performs a call. Task cancellation means the client cancelled it (or went away).
    func call(_ call: MCPToolCall, client: MCPClientInfo, progress: MCPProgress) async -> MCPToolResult
}

/// The MCP server side of `runlet mcp` (#43): JSON-RPC 2.0 over newline-delimited messages.
///
/// Dual-era, as the 2026-07-28 revision describes: requests that carry
/// `io.modelcontextprotocol/protocolVersion` in `_meta` are served statelessly under that
/// revision (`server/discover`, `resultType`, per-request client info); a client that starts
/// with `initialize` gets the negotiated earlier revision for the rest of the process.
/// Only tools are offered. Tool calls go to `backend`; everything else is answered here.
public final class MCPServer: @unchecked Sendable {
    /// Revisions served with per-request metadata.
    public static let modernVersions = ["2026-07-28"]
    /// Revisions that start with `initialize`, newest first.
    public static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static var supportedVersions: [String] { modernVersions + legacyVersions }

    public static let unsupportedProtocolVersion = -32022
    /// Calls in progress at once (each may wait minutes for an approval).
    public static let maxConcurrentCalls = 8

    public struct Info: Sendable {
        public var name: String
        public var title: String
        public var version: String

        public init(name: String = "runlet", title: String = "Runlet", version: String) {
            self.name = name
            self.title = title
            self.version = version
        }

        var json: MCPJSON { ["name": .string(name), "title": .string(title), "version": .string(version)] }
    }

    /// How a request is served: under per-request metadata, or the `initialize`d revision.
    struct Era: Equatable {
        var version: String
        var modern: Bool
        var client: MCPClientInfo?
    }

    private let info: Info
    private let backend: MCPToolBackend
    private let send: @Sendable (String) -> Void
    private let heartbeat: Duration
    private let lock = NSLock()
    /// The revision `initialize` agreed on, and the client it named.
    private var legacy: (version: String, client: MCPClientInfo?)?
    private var calls: [String: CallEntry] = [:]

    /// - Parameters:
    ///   - send: writes one message (a line without its newline) to the client.
    ///   - heartbeat: how often a waiting call repeats its progress notification (when the
    ///     client asked for progress), so clients that reset their timeout on progress keep waiting.
    public init(info: Info, backend: MCPToolBackend, heartbeat: Duration = .seconds(15), send: @escaping @Sendable (String) -> Void) {
        self.info = info
        self.backend = backend
        self.heartbeat = heartbeat
        self.send = send
    }

    /// The client named by `initialize` (legacy clients), for showing before any call.
    public var initializedClient: MCPClientInfo? { lock.withLock { legacy?.client } }

    /// Handles one message from the client.
    public func receive(_ line: String) {
        let message: MCPJSON
        do {
            message = try MCPJSON.parse(line)
        } catch {
            return reply(error: -32700, "Parse error: the message is not valid JSON.", id: nil)
        }
        guard case .object(let object) = message else {
            // JSON-RPC batches were removed from MCP in 2025-06-18.
            return reply(error: -32600, "Invalid request: send one JSON-RPC object per line.", id: nil)
        }
        let id = object["id"]
        let validId = id.flatMap { id -> MCPJSON? in
            switch id {
            case .string, .int: id
            default: nil
            }
        }
        guard object["jsonrpc"] == "2.0" else {
            return reply(error: -32600, "Invalid request: \"jsonrpc\" must be \"2.0\".", id: validId)
        }
        guard let method = object["method"]?.stringValue else {
            // A response: this server sends no requests, so there is nothing to match it with.
            if object["result"] != nil || object["error"] != nil { return }
            return reply(error: -32600, "Invalid request: no method.", id: validId)
        }
        let params = object["params"]
        if let params, params.objectValue == nil {
            return reply(error: -32600, "Invalid request: \"params\" must be an object.", id: validId)
        }
        guard id != nil else { return notification(method, params: params?.objectValue ?? [:]) }
        guard let validId else {
            return reply(error: -32600, "Invalid request: \"id\" must be a string or an integer.", id: nil)
        }
        request(method, id: validId, params: params?.objectValue ?? [:])
    }

    /// The client went away (end of input): stops every call in progress.
    public func shutdown() {
        let running = lock.withLock { () -> [Task<Void, Never>] in
            let entries = Array(calls.values)
            calls = [:]
            entries.forEach { $0.cancelled = true }
            return entries.compactMap(\.task)
        }
        running.forEach { $0.cancel() }
    }

    /// Waits until no call is in progress (tests).
    public func waitUntilIdle() async {
        while lock.withLock({ !calls.isEmpty }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: Notifications

    private func notification(_ method: String, params: [String: MCPJSON]) {
        switch method {
        case "notifications/cancelled":
            guard let id = params["requestId"] else { return }
            let task = lock.withLock { () -> Task<Void, Never>? in
                guard let entry = calls.removeValue(forKey: id.serialized) else { return nil }
                entry.cancelled = true
                return entry.task
            }
            task?.cancel()
        default:
            // notifications/initialized and anything else need no answer.
            break
        }
    }

    // MARK: Requests

    private func request(_ method: String, id: MCPJSON, params: [String: MCPJSON]) {
        if method == "initialize" { return initialize(id: id, params: params) }
        let era: Era
        switch self.era(of: params, method: method) {
        case .success(let value): era = value
        case .failure(let failure): return reply(error: failure.code, failure.message, data: failure.data, id: id)
        }
        switch method {
        case "ping":
            reply(result: [:], era: era, id: id)
        case "server/discover":
            reply(result: [
                "supportedVersions": .array(Self.supportedVersions.map(MCPJSON.string)),
                "capabilities": ["tools": [:]],
                "instructions": .string(MCPTools.instructions),
                "ttlMs": 3_600_000,
                "cacheScope": "public",
            ], era: era, id: id)
        case "tools/list":
            var result: [String: MCPJSON] = ["tools": .array(MCPTools.definitions)]
            if era.modern {
                result["ttlMs"] = 3_600_000
                result["cacheScope"] = "public"
            }
            reply(result: result, era: era, id: id)
        case "tools/call":
            callTool(id: id, params: params, era: era)
        default:
            reply(error: -32601, "Method not found: \(method)", id: id)
        }
    }

    struct Failure: Error {
        var code: Int
        var message: String
        var data: MCPJSON?
    }

    /// Per-request metadata (2026-07-28) or the `initialize`d revision.
    func era(of params: [String: MCPJSON], method: String) -> Result<Era, Failure> {
        let meta = params["_meta"]?.objectValue ?? [:]
        if let requested = meta["io.modelcontextprotocol/protocolVersion"] {
            guard let version = requested.stringValue else {
                return .failure(Failure(code: -32602, message: "Invalid params: io.modelcontextprotocol/protocolVersion must be a string."))
            }
            guard Self.modernVersions.contains(version) else {
                return .failure(Failure(code: Self.unsupportedProtocolVersion, message: "Unsupported protocol version", data: [
                    "supported": .array(Self.supportedVersions.map(MCPJSON.string)),
                    "requested": .string(version),
                ]))
            }
            guard meta["io.modelcontextprotocol/clientCapabilities"]?.objectValue != nil else {
                return .failure(Failure(code: -32602, message: "Invalid params: io.modelcontextprotocol/clientCapabilities is required in _meta."))
            }
            return .success(Era(version: version, modern: true, client: MCPClientInfo(json: meta["io.modelcontextprotocol/clientInfo"])))
        }
        if let legacy = lock.withLock({ legacy }) {
            return .success(Era(version: legacy.version, modern: false, client: legacy.client))
        }
        if method == "ping" { return .success(Era(version: Self.legacyVersions[0], modern: false, client: nil)) }
        return .failure(Failure(code: -32602, message: "Invalid params: send initialize first, or put io.modelcontextprotocol/protocolVersion (\(Self.modernVersions.joined(separator: ", "))) and clientCapabilities in the request's _meta.", data: [
            "supported": .array(Self.supportedVersions.map(MCPJSON.string)),
        ]))
    }

    private func initialize(id: MCPJSON, params: [String: MCPJSON]) {
        guard let requested = params["protocolVersion"]?.stringValue else {
            return reply(error: -32602, "Invalid params: initialize needs protocolVersion.", id: id)
        }
        // The requested revision when it is one of ours, else the newest we speak; the client
        // disconnects if it can't use that.
        let version = Self.legacyVersions.contains(requested) ? requested : Self.legacyVersions[0]
        let client = MCPClientInfo(json: params["clientInfo"])
        lock.withLock { legacy = (version, client) }
        reply(result: [
            "protocolVersion": .string(version),
            "capabilities": ["tools": [:]],
            "serverInfo": info.json,
            "instructions": .string(MCPTools.instructions),
        ], era: Era(version: version, modern: false, client: client), id: id)
    }

    private func callTool(id: MCPJSON, params: [String: MCPJSON], era: Era) {
        guard let name = params["name"]?.stringValue else {
            return reply(error: -32602, "Invalid params: tools/call needs a tool name.", id: id)
        }
        if let arguments = params["arguments"], arguments != .null, arguments.objectValue == nil {
            return reply(error: -32602, "Invalid params: arguments must be an object.", id: id)
        }
        let call: MCPToolCall
        switch MCPTools.parse(name: name, arguments: params["arguments"]) {
        case .success(let parsed):
            call = parsed
        case .failure(.unknownTool(let tool)):
            return reply(error: -32602, "Unknown tool: \(tool)", id: id)
        case .failure(.invalidArguments(let message)):
            return reply(result: Self.toolResult(.error(message), era: era), era: era, id: id)
        }
        let key = id.serialized
        let token = params["_meta"]?["progressToken"].flatMap { token -> MCPJSON? in
            switch token {
            case .string, .int: token
            default: nil
            }
        }
        let client = era.client ?? .unknown
        let entry = CallEntry()
        enum Admission { case admitted, duplicate, busy }
        let admission: Admission = lock.withLock {
            if calls[key] != nil { return .duplicate }
            if calls.count >= Self.maxConcurrentCalls { return .busy }
            calls[key] = entry
            return .admitted
        }
        switch admission {
        case .duplicate:
            return reply(error: -32600, "Invalid request: request id \(key) is already in use.", id: id)
        case .busy:
            return reply(result: Self.toolResult(.error("Too many Runlet calls are in progress (at most \(Self.maxConcurrentCalls)). Wait for one to finish."), era: era), era: era, id: id)
        case .admitted:
            break
        }
        let progress = ProgressSender(token: token, heartbeat: heartbeat, send: send)
        let reporter = MCPProgress { message in progress.update(message) }
        let task = Task { [weak self, backend] in
            let result = await backend.call(call, client: client, progress: reporter)
            reporter.stop()
            progress.stop()
            guard let self else { return }
            // A cancelled call gets no answer (its entry is gone then).
            let wanted = self.lock.withLock { () -> Bool in
                guard self.calls[key] === entry else { return false }
                self.calls[key] = nil
                return !entry.cancelled
            }
            guard wanted else { return }
            self.reply(result: Self.toolResult(result, era: era), era: era, id: id)
        }
        let cancelNow = lock.withLock { () -> Bool in
            entry.task = task
            return entry.cancelled
        }
        if cancelNow { task.cancel() }
        progress.start()
    }

    static func toolResult(_ result: MCPToolResult, era: Era) -> [String: MCPJSON] {
        var object: [String: MCPJSON] = [
            "content": [["type": "text", "text": .string(result.text)]],
            "isError": .bool(result.isError),
        ]
        // Structured content exists from 2025-06-18 on.
        if let structured = result.structured, era.modern || era.version >= "2025-06-18" {
            object["structuredContent"] = structured
        }
        return object
    }

    // MARK: Replies

    private func reply(result: [String: MCPJSON], era: Era, id: MCPJSON) {
        var result = result
        if era.modern {
            result["resultType"] = "complete"
            var meta = result["_meta"]?.objectValue ?? [:]
            meta["io.modelcontextprotocol/serverInfo"] = info.json
            result["_meta"] = .object(meta)
        }
        send(MCPJSON.object(["jsonrpc": "2.0", "id": id, "result": .object(result)]).serialized)
    }

    private func reply(error code: Int, _ message: String, data: MCPJSON? = nil, id: MCPJSON?) {
        var error: [String: MCPJSON] = ["code": .int(code), "message": .string(message)]
        if let data { error["data"] = data }
        var object: [String: MCPJSON] = ["jsonrpc": "2.0", "error": .object(error)]
        // MCP leaves the id out when it couldn't be read.
        if let id { object["id"] = id }
        send(MCPJSON.object(object).serialized)
    }
}

/// One tool call in progress (guarded by the server's lock).
private final class CallEntry: @unchecked Sendable {
    var task: Task<Void, Never>?
    var cancelled = false
}

/// Sends `notifications/progress` for one call: on each status change, and again every
/// `heartbeat` while the call waits. Nothing without a progress token, nothing after `stop`.
private final class ProgressSender: @unchecked Sendable {
    private let token: MCPJSON?
    private let heartbeat: Duration
    private let send: @Sendable (String) -> Void
    private let lock = NSLock()
    private var message = "Waiting for Runlet"
    private var count = 0
    private var stopped = false
    private var ticker: Task<Void, Never>?

    init(token: MCPJSON?, heartbeat: Duration, send: @escaping @Sendable (String) -> Void) {
        self.token = token
        self.heartbeat = heartbeat
        self.send = send
    }

    func start() {
        guard token != nil else { return }
        let task = Task { [weak self, heartbeat] in
            while !Task.isCancelled {
                try? await Task.sleep(for: heartbeat)
                guard !Task.isCancelled else { return }
                self?.emit(nil)
            }
        }
        lock.withLock {
            if stopped { task.cancel() } else { ticker = task }
        }
    }

    func update(_ message: String) {
        emit(message)
    }

    func stop() {
        let task = lock.withLock {
            stopped = true
            return ticker
        }
        task?.cancel()
    }

    private func emit(_ newMessage: String?) {
        guard let token else { return }
        let line: String? = lock.withLock {
            guard !stopped else { return nil }
            if let newMessage { message = newMessage }
            count += 1
            return MCPJSON.object([
                "jsonrpc": "2.0",
                "method": "notifications/progress",
                "params": ["progressToken": token, "progress": .int(count), "message": .string(message)],
            ]).serialized
        }
        if let line { send(line) }
    }
}
