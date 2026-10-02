import Foundation
import Testing
@testable import RunletCore

/// Lines a server sent, collected across threads.
final class SentLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
    var messages: [MCPJSON] { all.compactMap { try? MCPJSON.parse($0) } }
    func reset() { lock.withLock { lines = [] } }

    /// The message answering `id`, waiting up to a second for it.
    func reply(to id: MCPJSON) async -> MCPJSON? {
        for _ in 0..<200 {
            if let reply = messages.first(where: { $0["id"] == id && $0["method"] == nil }) { return reply }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }
}

/// A backend that records calls and answers with a fixed result, or waits until cancelled.
final class FakeBackend: MCPToolBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(MCPToolCall, MCPClientInfo)] = []
    private var cancelled = false
    var result = MCPToolResult(text: "done", structured: ["ok": true])
    var waitForCancel = false
    var statuses: [String] = []

    var calls: [(MCPToolCall, MCPClientInfo)] { lock.withLock { recorded } }
    var sawCancel: Bool { lock.withLock { cancelled } }

    func call(_ call: MCPToolCall, client: MCPClientInfo, progress: MCPProgress) async -> MCPToolResult {
        lock.withLock { recorded.append((call, client)) }
        for status in statuses { progress.report(status) }
        if waitForCancel {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            lock.withLock { cancelled = true }
        }
        return result
    }
}

struct MCPFramingTests {
    @Test func linesSplitAcrossChunksAndMessagesSharingOne() {
        var framer = JSONLineFramer(maxLineBytes: 1000)
        #expect(framer.append(Data("{\"a\":".utf8)) == [])
        #expect(framer.append(Data("1}\n{\"b\":2}\r\n\n  \n{\"c\"".utf8)) == [.line("{\"a\":1}"), .line("{\"b\":2}")])
        #expect(framer.append(Data(":3}\n".utf8)) == [.line("{\"c\":3}")])
    }

    @Test func oversizedMessagesAreDroppedUpToTheirNewline() {
        var framer = JSONLineFramer(maxLineBytes: 10)
        #expect(framer.append(Data("0123456789AB".utf8)) == [], "the start of a long line is held back")
        #expect(framer.append(Data("CD\n{}\n".utf8)) == [.oversized(14), .line("{}")], "the next message still arrives")
        #expect(framer.append(Data("01234567890123\n[]\n".utf8)) == [.oversized(14), .line("[]")])
    }

    @Test func jsonKeepsIntegersBooleansAndStringsApart() throws {
        let value = try MCPJSON.parse(#"{"id":1,"flag":true,"zero":0,"half":0.5,"text":"a\nb","none":null}"#)
        #expect(value["id"] == .int(1))
        #expect(value["flag"] == .bool(true))
        #expect(value["zero"] == .int(0))
        #expect(value["half"] == .double(0.5))
        #expect(value["text"] == .string("a\nb"))
        #expect(value["none"] == .null)
        #expect(!value.serialized.contains("\n"), "one message per line: newlines in strings are escaped")
        #expect(try MCPJSON.parse(value.serialized) == value)
        let decoded = try JSONDecoder().decode(MCPJSON.self, from: Data(#"{"id":1,"flag":true}"#.utf8))
        #expect(decoded == ["id": 1, "flag": true], "Codable keeps the same distinctions")
    }
}

struct MCPServerTests {
    static let modernMeta: MCPJSON = [
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": [:],
        "io.modelcontextprotocol/clientInfo": ["name": "test-client", "title": "Test Client", "version": "1.0"],
    ]

    static func make(_ backend: FakeBackend = FakeBackend()) -> (MCPServer, SentLines) {
        let lines = SentLines()
        let server = MCPServer(info: MCPServer.Info(version: "9.9"), backend: backend, heartbeat: .milliseconds(30)) { lines.append($0) }
        return (server, lines)
    }

    static func request(_ id: MCPJSON, _ method: String, _ params: MCPJSON? = nil) -> String {
        var object: [String: MCPJSON] = ["jsonrpc": "2.0", "id": id, "method": .string(method)]
        if let params { object["params"] = params }
        return MCPJSON.object(object).serialized
    }

    static func initialize(_ server: MCPServer, version: String = "2025-11-25") {
        server.receive(request(0, "initialize", ["protocolVersion": .string(version), "capabilities": [:], "clientInfo": ["name": "claude-code", "title": "Claude Code", "version": "2.1"]]))
        server.receive(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
    }

    @Test func initializeAgreesOnALegacyRevision() async {
        for (requested, expected) in [("2025-06-18", "2025-06-18"), ("2024-11-05", "2024-11-05"), ("2027-01-01", "2025-11-25"), ("2026-07-28", "2025-11-25")] {
            let (server, lines) = Self.make()
            server.receive(Self.request(1, "initialize", ["protocolVersion": .string(requested), "capabilities": [:], "clientInfo": ["name": "cursor", "version": "1"]]))
            let reply = await lines.reply(to: 1)
            #expect(reply?["result"]?["protocolVersion"] == .string(expected), "requested \(requested)")
            #expect(reply?["result"]?["capabilities"]?["tools"] == [:])
            #expect(reply?["result"]?["serverInfo"]?["name"] == "runlet")
            #expect(reply?["result"]?["instructions"]?.stringValue?.contains("approve") == true)
            #expect(reply?["result"]?["resultType"] == nil, "legacy results have no resultType")
            #expect(server.initializedClient == MCPClientInfo(name: "cursor", version: "1"))
        }
    }

    @Test func initializeNeedsAVersion() async {
        let (server, lines) = Self.make()
        server.receive(Self.request("a", "initialize", ["capabilities": [:]]))
        #expect(await lines.reply(to: "a")?["error"]?["code"] == .int(-32602))
    }

    @Test func requestsWithoutMetadataOrInitializeAreRefused() async {
        let (server, lines) = Self.make()
        server.receive(Self.request(1, "tools/list"))
        let reply = await lines.reply(to: 1)
        #expect(reply?["error"]?["code"] == .int(-32602))
        #expect(reply?["error"]?["data"]?["supported"]?.serialized.contains("2026-07-28") == true)
    }

    @Test func toolsListServesLegacyAndModernClients() async {
        let (server, lines) = Self.make()
        server.receive(Self.request(1, "tools/list", ["_meta": Self.modernMeta]))
        let modern = await lines.reply(to: 1)
        #expect(modern?["result"]?["resultType"] == "complete")
        #expect(modern?["result"]?["ttlMs"] != nil && modern?["result"]?["cacheScope"] == "public")
        #expect(modern?["result"]?["_meta"]?["io.modelcontextprotocol/serverInfo"]?["version"] == "9.9")
        guard case .array(let tools)? = modern?["result"]?["tools"] else {
            Issue.record("no tools")
            return
        }
        #expect(tools.compactMap { $0["name"]?.stringValue } == MCPTools.names)
        for tool in tools {
            let schema = tool["inputSchema"]
            #expect(schema?["type"] == "object")
            #expect(schema?["additionalProperties"] == false)
            #expect(tool["description"]?.stringValue?.isEmpty == false)
        }
        let run = tools.first { $0["name"] == "run_php" }
        #expect(run?["inputSchema"]?["required"] == ["target", "code"])
        #expect(run?["annotations"]?["destructiveHint"] == true)
        #expect(tools.first { $0["name"] == "list_targets" }?["annotations"]?["readOnlyHint"] == true)

        Self.initialize(server)
        server.receive(Self.request(2, "tools/list"))
        let legacy = await lines.reply(to: 2)
        #expect(legacy?["result"]?["tools"] == modern?["result"]?["tools"])
        #expect(legacy?["result"]?["resultType"] == nil && legacy?["result"]?["ttlMs"] == nil)
    }

    @Test func modernRequestsCheckTheirMetadata() async {
        let (server, lines) = Self.make()
        server.receive(Self.request(1, "tools/list", ["_meta": ["io.modelcontextprotocol/protocolVersion": "1999-01-01", "io.modelcontextprotocol/clientCapabilities": [:]]]))
        let unsupported = await lines.reply(to: 1)
        #expect(unsupported?["error"]?["code"] == .int(-32022))
        #expect(unsupported?["error"]?["data"]?["requested"] == "1999-01-01")
        #expect(unsupported?["error"]?["data"]?["supported"]?.serialized.contains("2026-07-28") == true)

        server.receive(Self.request(2, "tools/list", ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]]))
        #expect(await lines.reply(to: 2)?["error"]?["code"] == .int(-32602), "clientCapabilities is required")

        server.receive(Self.request(3, "server/discover", ["_meta": Self.modernMeta]))
        let discover = await lines.reply(to: 3)
        #expect(discover?["result"]?["supportedVersions"]?.serialized == MCPJSON.array(MCPServer.supportedVersions.map(MCPJSON.string)).serialized)
        #expect(discover?["result"]?["capabilities"]?["tools"] == [:])
        #expect(discover?["result"]?["resultType"] == "complete")
    }

    @Test func malformedMessagesGetJSONRPCErrors() async {
        let (server, lines) = Self.make()
        server.receive("{not json")
        server.receive(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)
        server.receive(#"{"jsonrpc":"1.0","id":7,"method":"ping"}"#)
        server.receive(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#)
        server.receive(#"{"jsonrpc":"2.0","id":8,"method":"ping","params":[1]}"#)
        try? await Task.sleep(for: .milliseconds(20))
        let messages = lines.messages
        #expect(messages.count == 5)
        #expect(messages[0]["error"]?["code"] == .int(-32700) && messages[0]["id"] == nil, "no id when it can't be read")
        #expect(messages[1]["error"]?["code"] == .int(-32600), "no batches")
        #expect(messages[2]["error"]?["code"] == .int(-32600) && messages[2]["id"] == 7)
        #expect(messages[3]["error"]?["code"] == .int(-32600) && messages[3]["id"] == nil)
        #expect(messages[4]["error"]?["code"] == .int(-32600) && messages[4]["id"] == 8)
    }

    @Test func unknownMethodsAndNotificationsAndResponses() async {
        let (server, lines) = Self.make()
        Self.initialize(server)
        lines.reset()
        server.receive(Self.request("x", "resources/list"))
        #expect(await lines.reply(to: "x")?["error"]?["code"] == .int(-32601))
        lines.reset()
        server.receive(#"{"jsonrpc":"2.0","method":"notifications/whatever","params":{}}"#)
        server.receive(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":404}}"#)
        server.receive(#"{"jsonrpc":"2.0","id":5,"result":{}}"#)
        server.receive(Self.request(6, "ping"))
        #expect(await lines.reply(to: 6)?["result"] == [:])
        #expect(lines.messages.count == 1, "notifications and stray responses get no answer")
    }

    @Test func toolCallsReachTheBackendWithTheClient() async {
        let backend = FakeBackend()
        let (server, lines) = Self.make(backend)
        Self.initialize(server, version: "2025-06-18")
        server.receive(Self.request(10, "tools/call", ["name": "run_php", "arguments": ["target": "sandbox", "code": "1 + 1"]]))
        let legacy = await lines.reply(to: 10)
        #expect(legacy?["result"]?["content"] == [["type": "text", "text": "done"]])
        #expect(legacy?["result"]?["isError"] == false)
        #expect(legacy?["result"]?["structuredContent"] == ["ok": true])
        #expect(backend.calls.first?.0 == .runPHP(target: "sandbox", code: "1 + 1"))
        #expect(backend.calls.first?.1.displayName == "Claude Code")

        server.receive(Self.request(11, "tools/call", ["name": "list_targets", "_meta": Self.modernMeta]))
        let modern = await lines.reply(to: 11)
        #expect(modern?["result"]?["resultType"] == "complete")
        #expect(backend.calls.last?.0 == .listTargets)
        #expect(backend.calls.last?.1.displayName == "Test Client", "modern requests name their client per request")
    }

    @Test func olderRevisionsGetNoStructuredContent() async {
        let (server, lines) = Self.make()
        Self.initialize(server, version: "2025-03-26")
        server.receive(Self.request(1, "tools/call", ["name": "get_last_output", "arguments": [:]]))
        let reply = await lines.reply(to: 1)
        #expect(reply?["result"]?["content"] != nil)
        #expect(reply?["result"]?["structuredContent"] == nil)
    }

    @Test func toolCallErrors() async {
        let backend = FakeBackend()
        let (server, lines) = Self.make(backend)
        Self.initialize(server)
        server.receive(Self.request(1, "tools/call", ["name": "rm_rf", "arguments": [:]]))
        #expect(await lines.reply(to: 1)?["error"]?["code"] == .int(-32602), "an unknown tool is a protocol error")
        server.receive(Self.request(2, "tools/call", ["name": "run_php", "arguments": ["target": "sandbox"]]))
        let missing = await lines.reply(to: 2)
        #expect(missing?["result"]?["isError"] == true, "bad arguments are a tool error the model can fix")
        #expect(missing?["result"]?["content"]?.serialized.contains("code") == true)
        server.receive(Self.request(3, "tools/call", ["name": "run_php", "arguments": "sandbox"]))
        #expect(await lines.reply(to: 3)?["error"]?["code"] == .int(-32602))
        server.receive(Self.request(4, "tools/call", ["arguments": [:]]))
        #expect(await lines.reply(to: 4)?["error"]?["code"] == .int(-32602))
        #expect(backend.calls.isEmpty, "nothing reached the app")
    }

    @Test func cancelledCallsStopAndGetNoAnswer() async {
        let backend = FakeBackend()
        backend.waitForCancel = true
        let (server, lines) = Self.make(backend)
        Self.initialize(server)
        lines.reset()
        server.receive(Self.request("run-1", "tools/call", ["name": "run_php", "arguments": ["target": "sandbox", "code": "sleep(60);"]]))
        server.receive(Self.request("run-1", "tools/call", ["name": "list_targets"]))
        #expect(await lines.reply(to: "run-1")?["error"]?["code"] == .int(-32600), "an id in use is refused")
        lines.reset()
        server.receive(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"run-1","reason":"user"}}"#)
        for _ in 0..<200 where !backend.sawCancel { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(backend.sawCancel)
        await server.waitUntilIdle()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(lines.all.isEmpty, "a cancelled request gets no response")
    }

    @Test func shutdownCancelsEverything() async {
        let backend = FakeBackend()
        backend.waitForCancel = true
        let (server, lines) = Self.make(backend)
        Self.initialize(server)
        lines.reset()
        server.receive(Self.request(1, "tools/call", ["name": "run_php", "arguments": ["target": "sandbox", "code": "1"]]))
        for _ in 0..<200 where backend.calls.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        server.shutdown()
        for _ in 0..<200 where !backend.sawCancel { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(backend.sawCancel)
        await server.waitUntilIdle()
        #expect(lines.all.isEmpty)
    }

    @Test func progressGoesOnlyToCallsThatAskForIt() async {
        let backend = FakeBackend()
        backend.waitForCancel = true
        backend.statuses = ["Waiting for the user to approve the run in Runlet"]
        let (server, lines) = Self.make(backend)
        Self.initialize(server)
        lines.reset()
        server.receive(Self.request(1, "tools/call", ["name": "run_php", "arguments": ["target": "sandbox", "code": "1"], "_meta": ["progressToken": "p1"]]))
        try? await Task.sleep(for: .milliseconds(120))
        let progress = lines.messages.filter { $0["method"] == "notifications/progress" }
        #expect(progress.count >= 2, "the status, then heartbeats while waiting")
        #expect(progress.allSatisfy { $0["params"]?["progressToken"] == "p1" })
        #expect(progress.first?["params"]?["message"] == "Waiting for the user to approve the run in Runlet")
        let values = progress.compactMap { message -> Int? in
            if case .int(let value)? = message["params"]?["progress"] { return value }
            return nil
        }
        #expect(values == values.sorted() && Set(values).count == values.count, "progress increases")
        server.receive(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#)
        await server.waitUntilIdle()
        let count = lines.all.count
        try? await Task.sleep(for: .milliseconds(80))
        #expect(lines.all.count == count, "no progress after the call ended")

        lines.reset()
        backend.waitForCancel = false
        server.receive(Self.request(2, "tools/call", ["name": "list_targets"]))
        _ = await lines.reply(to: 2)
        #expect(!lines.messages.contains { $0["method"] == "notifications/progress" }, "no token, no progress")
    }
}

struct MCPToolArgumentTests {
    @Test func argumentsAreChecked() {
        #expect(MCPTools.parse(name: "list_targets", arguments: nil) == .success(.listTargets))
        #expect(MCPTools.parse(name: "list_targets", arguments: [:]) == .success(.listTargets))
        #expect(MCPTools.parse(name: "list_snippets", arguments: ["target": "sandbox", "query": " users "]) == .success(.listSnippets(target: "sandbox", query: "users")))
        #expect(MCPTools.parse(name: "list_snippets", arguments: ["target": ""]) == .success(.listSnippets(target: nil, query: nil)), "empty optional strings count as missing")
        #expect(MCPTools.parse(name: "get_snippet", arguments: ["id": "abc"]) == .success(.getSnippet(id: "abc")))
        #expect(MCPTools.parse(name: "add_snippet", arguments: ["label": "Users", "code": "User::count();"]) == .success(.addSnippet(label: "Users", code: "User::count();", target: nil)))
        #expect(MCPTools.parse(name: "run_php", arguments: ["target": "local:shop", "code": "<?php\necho 1;"]) == .success(.runPHP(target: "local:shop", code: "<?php\necho 1;")))
        #expect(MCPTools.parse(name: "get_last_output", arguments: nil) == .success(.getLastOutput))
        #expect(MCPTools.parse(name: "exec", arguments: nil) == .failure(.unknownTool("exec")))
    }

    @Test func badArgumentsAreExplained() {
        func message(_ name: String, _ arguments: MCPJSON?) -> String? {
            if case .failure(.invalidArguments(let text)) = MCPTools.parse(name: name, arguments: arguments) { return text }
            return nil
        }
        #expect(message("run_php", ["code": "1"])?.contains("target") == true)
        #expect(message("run_php", ["target": "sandbox", "code": 1])?.contains("string") == true)
        #expect(message("run_php", ["target": "sandbox", "code": "  <?php  "])?.contains("empty") == true)
        #expect(message("run_php", ["target": "sandbox", "code": .string(String(repeating: "x", count: MCPTools.maxCodeBytes + 1))])?.contains("larger") == true)
        #expect(message("run_php", ["target": "sandbox", "code": "1", "selection": "all"])?.contains("selection") == true, "unknown arguments are refused")
        #expect(message("list_targets", ["verbose": true])?.contains("no arguments") == true)
        #expect(message("add_snippet", ["label": .string(String(repeating: "a", count: 201)), "code": "1"])?.contains("label") == true)
        #expect(message("get_snippet", [:])?.contains("id") == true)
        #expect(message("get_snippet", ["id": "a"]) == nil)
    }

    @Test func clientNamesAreCleanedForDisplay() {
        #expect(MCPClientInfo(json: ["name": "claude-code", "title": "Claude Code"])?.displayName == "Claude Code")
        #expect(MCPClientInfo(json: ["name": "cursor\nEvil\u{7}"])?.displayName == "cursorEvil")
        #expect(MCPClientInfo(json: ["name": .string(String(repeating: "a", count: 100))])?.displayName.count == 60)
        #expect(MCPClientInfo(json: ["title": "No name"]) == nil)
        #expect(MCPClientInfo(json: nil) == nil)
    }
}
