import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// #368: `AIClient` with the real `URLSessionAITransport`, against the provider stand-in in
/// `Tests/Fixtures/ai-stub` on 127.0.0.1. Proves the answer streams as it's written, Stop
/// cancels the request, failures map to their `AIError`s, and a chat's turns go out as one
/// conversation (#45). Never reaches a provider, and the keys are made up.
@Suite(.serialized, .enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct AIStubTests {
    /// `php -S` with the stub's router, its scenario, and a log of what it received.
    final class Stub {
        let port: Int
        let directory: URL
        private let server: TestProcess

        init(scenario: [String: Any]) throws {
            directory = try DriverSupport.temporaryDirectory("ai-stub")
            try JSONSerialization.data(withJSONObject: scenario).write(to: directory.appendingPathComponent("scenario.json"))
            port = try SSHForwardPorts.pickFree()
            let router = TestSupport.fixtures.appendingPathComponent("ai-stub/router.php").path
            server = TestProcess([DriverSupport.php, "-S", "127.0.0.1:\(port)", router], step: "ai stub on 127.0.0.1:\(port)")
            server.process.environment = [
                "RUNLET_AI_STUB_SCENARIO": directory.appendingPathComponent("scenario.json").path,
                "RUNLET_AI_STUB_LOG": directory.appendingPathComponent("requests.jsonl").path,
                "PATH": "/usr/bin:/bin",
            ]
            try server.start()
            let deadline = Date().addingTimeInterval(10)
            while !SSHForwardPorts.isListening(port) {
                guard Date() < deadline, server.process.isRunning else {
                    stop()
                    throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "php -S didn't start on 127.0.0.1:\(port)"])
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        var url: URL { URL(string: "http://127.0.0.1:\(port)")! }

        /// What the stub received, one object per request.
        var requests: [[String: Any]] {
            let text = (try? String(contentsOf: directory.appendingPathComponent("requests.jsonl"), encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }

        func stop() {
            server.stopBlocking()
            try? FileManager.default.removeItem(at: directory)
        }

        deinit { stop() }
    }

    static let answer = "`$user` is `null`.\n\n```runlet-fix\n<?php\necho $user?->name;\n```"

    static func disclosure(_ provider: AIProvider) -> AIDisclosure {
        ExplainErrorPrompt.disclosure(ExplainErrorInput(language: .php, error: "ErrorException: Attempt to read property \"name\" on null\nOn line 2 of the tab's code.",
                                                        code: "<?php\necho $user->name;", line: 2), provider: provider, model: provider.defaultModel)
    }

    @Test(arguments: AIProvider.allCases)
    func theAnswerStreamsAsItIsWritten(provider: AIProvider) async throws {
        let stub = try Stub(scenario: ["answer": Self.answer, "chunk": 6, "delay_ms": 40])
        defer { stub.stop() }
        let client = AIClient(transport: URLSessionAITransport(), baseURLOverride: stub.url)
        let disclosure = Self.disclosure(provider)
        let started = Date()
        var firstText: TimeInterval?
        var text = ""
        var finish: AIFinish?
        for try await event in client.stream(disclosure, consent: AIConsent(approving: disclosure), key: SensitiveString("sk-EXAMPLE-not-a-real-key-0000")) {
            switch event {
            case .text(let piece):
                if firstText == nil { firstText = Date().timeIntervalSince(started) }
                text += piece
            case .finished(let end):
                finish = end
            default:
                break
            }
        }
        let total = Date().timeIntervalSince(started)
        #expect(text == Self.answer)
        #expect(finish?.reason == .complete)
        #expect(finish?.model == provider.defaultModel)
        #expect(AIAnswer.parse(text).fix == "<?php\necho $user?->name;")
        // The first words arrived well before the last: the answer streamed, it wasn't buffered.
        let first = try #require(firstText)
        #expect(total - first > 0.3, "first text at \(first)s, done at \(total)s")

        // The stub got the disclosure's message, and a key (it never logs the key itself).
        let request = try #require(stub.requests.first)
        #expect(request["key"] as? String == "present")
        let body = try #require(request["body"] as? [String: Any])
        switch provider {
        case .anthropic:
            #expect(request["path"] as? String == "/v1/messages")
            #expect(request["anthropic_version"] as? String == "2023-06-01")
            let messages = try #require(body["messages"] as? [[String: Any]])
            #expect(messages.first?["content"] as? String == disclosure.message)
            #expect(body["system"] as? String == disclosure.instructions)
        case .openai:
            #expect(request["path"] as? String == "/v1/responses")
            let input = try #require(body["input"] as? [[String: Any]])
            #expect(input.first?["content"] as? String == disclosure.message)
            #expect(body["store"] as? Bool == false)
        }
    }

    @Test func stopEndsTheRequestAtOnce() async throws {
        let stub = try Stub(scenario: ["answer": String(repeating: "Still writing. ", count: 40), "chunk": 10, "delay_ms": 10, "hold_after": 20, "hold_ms": 20000])
        defer { stub.stop() }
        let disclosure = Self.disclosure(.anthropic)
        let stream = AIClient(transport: URLSessionAITransport(), baseURLOverride: stub.url)
            .stream(disclosure, consent: AIConsent(approving: disclosure), key: SensitiveString("sk-ant-EXAMPLE-not-a-real-key-0000"))
        let reader = Task { () -> (String, AIError?) in
            var text = ""
            do {
                for try await event in stream {
                    if case .text(let piece) = event { text += piece }
                }
                return (text, nil)
            } catch {
                return (text, error as? AIError)
            }
        }
        // Wait for the first words, then stop while the stub holds the rest for 20 seconds.
        let deadline = Date().addingTimeInterval(10)
        while stub.requests.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(400))
        let stopped = Date()
        reader.cancel()
        let (text, error) = await reader.value
        #expect(Date().timeIntervalSince(stopped) < 3)
        #expect(!text.isEmpty)
        #expect(text.count < 200)
        #expect(error == .cancelled || error == nil)
    }

    @Test func failuresAndModelLists() async throws {
        let stub = try Stub(scenario: ["status": 429, "retry_after": "7"])
        defer { stub.stop() }
        let client = AIClient(transport: URLSessionAITransport(), baseURLOverride: stub.url)
        for provider in AIProvider.allCases {
            let disclosure = Self.disclosure(provider)
            do {
                for try await _ in client.stream(disclosure, consent: AIConsent(approving: disclosure), key: SensitiveString("sk-EXAMPLE-not-a-real-key-0000")) {}
                Issue.record("\(provider): no error")
            } catch {
                #expect(error as? AIError == .rateLimited(provider, retryAfter: 7))
            }
        }
        #expect(try await client.models(.anthropic, key: SensitiveString("sk-ant-EXAMPLE-not-a-real-key-0000")).first == AIModelInfo(id: "claude-opus-5-5", displayName: "Claude Opus 5.5"))
        #expect(try await client.models(.openai, key: SensitiveString("sk-EXAMPLE-not-a-real-key-0000")).map(\.id) == ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-luna"])
        await #expect(throws: AIError.invalidKey(.openai)) { try await client.models(.openai, key: SensitiveString("sk-invalid-EXAMPLE-0000")) }
    }

    /// #45: each chat message sends the earlier turns, in order, with the new message last, and
    /// the stand-in answers each turn with its own answer.
    @Test(arguments: AIProvider.allCases)
    func aChatSendsItsEarlierTurns(provider: AIProvider) async throws {
        let stub = try Stub(scenario: ["answers": ["First answer.", "Second answer, with `code`."], "chunk": 8, "delay_ms": 5])
        defer { stub.stop() }
        let client = AIClient(transport: URLSessionAITransport(), baseURLOverride: stub.url)
        let key = SensitiveString("sk-EXAMPLE-not-a-real-key-0000")
        var conversation = AIChatConversation()
        let editor = AIChatEditorContext(tabTitle: "Orders", language: .php, code: "<?php\n\nOrder::count();")
        for question in ["How many orders are there?", "And today?"] {
            let draft = AIChatPrompt.draft(provider: provider, model: provider.defaultModel, configured: [provider], conversation: conversation, message: question,
                                           editor: editor, output: nil, files: [], choice: AIChatContextChoice())
            #expect(draft.canSend)
            var turn = AIChatTurn(question: question, context: draft.contextParts.map(\.title), sent: draft.disclosure.message,
                                  provider: provider, model: provider.defaultModel)
            for try await event in client.stream(draft.disclosure, consent: AIConsent(approving: draft.disclosure), key: key) {
                if case .text(let piece) = event { turn.answer += piece }
            }
            turn.state = .complete
            conversation.turns.append(turn)
        }
        #expect(conversation.turns.map(\.answer) == ["First answer.", "Second answer, with `code`."])
        let requests = stub.requests.compactMap { $0["body"] as? [String: Any] }
        #expect(requests.count == 2)
        let key2 = provider == .anthropic ? "messages" : "input"
        let first = try #require(requests.first?[key2] as? [[String: Any]])
        let second = try #require(requests.last?[key2] as? [[String: Any]])
        #expect(first.map { $0["role"] as? String } == ["user"])
        #expect(second.map { $0["role"] as? String } == ["user", "assistant", "user"])
        #expect(second[0]["content"] as? String == conversation.turns[0].sent)
        #expect(second[1]["content"] as? String == "First answer.")
        #expect((second[2]["content"] as? String)?.hasSuffix("## Message\n\nAnd today?") == true)
        #expect((second[2]["content"] as? String)?.contains("Order::count();") == true)
    }

    /// #45: a chat that switches from Anthropic to OpenAI mid-conversation sends the earlier
    /// turn to OpenAI as plain text, and each turn goes to its own provider's endpoint.
    @Test func aChatCanSwitchProvidersMidConversation() async throws {
        let stub = try Stub(scenario: ["answers": ["Anthropic's answer.", "OpenAI's answer."], "chunk": 8, "delay_ms": 5])
        defer { stub.stop() }
        let client = AIClient(transport: URLSessionAITransport(), baseURLOverride: stub.url)
        var conversation = AIChatConversation()
        for (provider, question) in [(AIProvider.anthropic, "First?"), (.openai, "Second?")] {
            let draft = AIChatPrompt.draft(provider: provider, model: provider.defaultModel, configured: [.anthropic, .openai], conversation: conversation,
                                           message: question, editor: nil, output: nil, files: [], choice: AIChatContextChoice())
            var turn = AIChatTurn(question: question, context: [], sent: draft.disclosure.message, provider: provider, model: provider.defaultModel)
            for try await event in client.stream(draft.disclosure, consent: AIConsent(approving: draft.disclosure), key: SensitiveString("sk-EXAMPLE-not-a-real-key-0000")) {
                switch event {
                case .text(let piece): turn.answer += piece
                case .started(let model): turn.answeringModel = model
                default: break
                }
            }
            turn.state = .complete
            conversation.turns.append(turn)
        }
        #expect(conversation.turns.map(\.answeringModel) == ["claude-opus-5-5", "gpt-6-astra"])
        let requests = stub.requests
        #expect(requests.map { $0["path"] as? String } == ["/v1/messages", "/v1/responses"])
        let input = try #require((requests.last?["body"] as? [String: Any])?["input"] as? [[String: Any]])
        #expect(input.map { $0["role"] as? String } == ["user", "assistant", "user"])
        #expect(input[1]["content"] as? String == "Anthropic's answer.")
    }

    @Test func refusalsAndCutOffAnswers() async throws {
        for (stop, expected) in [("refusal", AIStopReason.refusal(category: "cyber", explanation: "The stub declined.")), ("max_tokens", .maxTokens)] {
            let stub = try Stub(scenario: ["answer": "Partial", "stop": stop])
            defer { stub.stop() }
            let disclosure = Self.disclosure(.anthropic)
            var finish: AIFinish?
            for try await event in AIClient(transport: URLSessionAITransport(), baseURLOverride: stub.url)
                .stream(disclosure, consent: AIConsent(approving: disclosure), key: SensitiveString("sk-ant-EXAMPLE-not-a-real-key-0000")) {
                if case .finished(let end) = event { finish = end }
            }
            #expect(finish?.reason == expected)
        }
    }
}
