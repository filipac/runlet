import Foundation
import Testing
@testable import RunletCore

/// A transport that answers with canned replies and records what it was asked (#368). No test
/// reaches a provider.
final class FakeAITransport: AITransport, @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var chunks: [Data] = []
        /// Thrown after the chunks, as a dropped connection would.
        var failure: Error?
        /// Keep the body open after the chunks until the reader cancels.
        var hangs = false
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var _requests: [URLRequest] = []
    private var _bodiesCancelled = 0

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    var requests: [URLRequest] { lock.withLock { _requests } }
    var bodiesCancelled: Int { lock.withLock { _bodiesCancelled } }

    func send(_ request: URLRequest) async throws -> AIHTTPResponse {
        let reply: Reply = lock.withLock {
            _requests.append(request)
            return replies.isEmpty ? Reply(status: 500) : replies.removeFirst()
        }
        let body = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                for chunk in reply.chunks {
                    continuation.yield(chunk)
                    await Task.yield()
                }
                if reply.hangs {
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
                }
                if let failure = reply.failure { continuation.finish(throwing: failure) } else { continuation.finish() }
            }
            continuation.onTermination = { [weak self] termination in
                task.cancel()
                if case .cancelled = termination { self?.lock.withLock { self?._bodiesCancelled += 1 } }
            }
        }
        return AIHTTPResponse(status: reply.status, headers: reply.headers, body: body)
    }

    /// Server-sent events from data lines, split into chunks of `size` bytes.
    static func sse(_ events: [String], chunk size: Int = 17) -> [Data] {
        let bytes = Array(events.map { "data: \($0)\n\n" }.joined().utf8)
        return stride(from: 0, to: bytes.count, by: size).map { Data(bytes[$0..<min($0 + size, bytes.count)]) }
    }
}

struct AIClientTests {
    static let key = SensitiveString("sk-ant-api03-EXAMPLE-not-a-real-key-Q2c4")

    static func disclosure(_ provider: AIProvider = .anthropic) -> AIDisclosure {
        AIDisclosure(provider: provider, model: provider.defaultModel, instructions: "Explain the error.",
                     parts: [AIDisclosurePart(id: "error", title: "The error", text: "TypeError: x"),
                             AIDisclosurePart(id: "code", title: "The tab's PHP code", text: "<?php\nstrlen([]);")],
                     maxOutputTokens: 1000, effort: .medium)
    }

    static func collect(_ stream: AsyncThrowingStream<AIStreamEvent, Error>) async -> (events: [AIStreamEvent], error: AIError?) {
        var events: [AIStreamEvent] = []
        do {
            for try await event in stream { events.append(event) }
            return (events, nil)
        } catch {
            return (events, error as? AIError)
        }
    }

    @Test func streamsWhatWasConfirmed() async throws {
        let transport = FakeAITransport([FakeAITransport.Reply(chunks: FakeAITransport.sse(AIStreamTests.anthropicStream))])
        let disclosure = Self.disclosure()
        let client = AIClient(transport: transport, baseURLOverride: URL(string: "http://127.0.0.1:9"))
        let result = await Self.collect(client.stream(disclosure, consent: AIConsent(approving: disclosure), key: Self.key))
        #expect(result.error == nil)
        #expect(result.events.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined() == "`$user` is null.")
        #expect(result.events.last == .finished(AIFinish(reason: .complete, model: "claude-opus-5-5", usage: AIUsage(inputTokens: 812, outputTokens: 215))))

        // Exactly the disclosure's message went out, to the override, with the key in a header only.
        let request = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        #expect(request.url?.absoluteString == "http://127.0.0.1:9/v1/messages")
        let sent = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: sent) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["content"] as? String == disclosure.message)
        #expect(body["system"] as? String == disclosure.instructions)
    }

    @Test func nothingIsSentWithoutConsentForWhatIsShown() async {
        let transport = FakeAITransport([])
        let client = AIClient(transport: transport)
        let shown = Self.disclosure()
        let consent = AIConsent(approving: shown)

        var changed = shown
        changed.setIncluded("code", false)
        #expect(await Self.collect(client.stream(changed, consent: consent, key: Self.key)).error == .notConfirmed)
        var otherModel = shown
        otherModel.model = "claude-haiku-5-5"
        #expect(await Self.collect(client.stream(otherModel, consent: consent, key: Self.key)).error == .notConfirmed)
        var nothing = shown
        nothing.setIncluded("code", false)
        nothing.setIncluded("error", false)
        #expect(await Self.collect(client.stream(nothing, consent: AIConsent(approving: nothing), key: Self.key)).error == .notConfirmed)
        // No key: nothing is sent either.
        #expect(await Self.collect(client.stream(shown, consent: consent, key: nil)).error == .missingKey(.anthropic))
        #expect(await Self.collect(client.stream(shown, consent: consent, key: SensitiveString("  "))).error == .missingKey(.anthropic))
        await #expect(throws: AIError.notConfirmed) { try await client.complete(changed, consent: consent, key: Self.key) }
        #expect(transport.requests.isEmpty)
    }

    @Test func httpErrorsBecomeAIErrors() async {
        let transport = FakeAITransport([
            FakeAITransport.Reply(status: 429, headers: ["retry-after": "12"], chunks: [Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"Rate limited"}}"#.utf8)]),
            FakeAITransport.Reply(status: 401, chunks: [Data(#"{"error":{"message":"Incorrect API key provided: sk-proj-****9xYz."}}"#.utf8)]),
        ])
        let client = AIClient(transport: transport)
        let disclosure = Self.disclosure(.openai)
        #expect(await Self.collect(client.stream(disclosure, consent: AIConsent(approving: disclosure), key: Self.key)).error == .rateLimited(.openai, retryAfter: 12))
        #expect(await Self.collect(client.stream(disclosure, consent: AIConsent(approving: disclosure), key: Self.key)).error == .invalidKey(.openai))
    }

    @Test func aStreamThatStopsEarlyIsANetworkError() async {
        let partial = Array(AIStreamTests.anthropicStream.prefix(8))
        let transport = FakeAITransport([
            FakeAITransport.Reply(chunks: FakeAITransport.sse(partial)),
            FakeAITransport.Reply(chunks: FakeAITransport.sse(partial), failure: URLError(.networkConnectionLost)),
        ])
        let client = AIClient(transport: transport)
        let disclosure = Self.disclosure()
        let ended = await Self.collect(client.stream(disclosure, consent: AIConsent(approving: disclosure), key: Self.key))
        #expect(ended.error == .network(.anthropic, detail: "The connection closed before the answer was complete."))
        #expect(ended.events.contains(.text("`$user` is ")))
        let dropped = await Self.collect(client.stream(disclosure, consent: AIConsent(approving: disclosure), key: Self.key))
        guard case .network(.anthropic, _) = dropped.error else {
            Issue.record("expected a network error, got \(String(describing: dropped.error))")
            return
        }
    }

    @Test func anErrorEventMidStreamIsThrown() async {
        let events = Array(AIStreamTests.anthropicStream.prefix(8)) + [#"{"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}}"#]
        let transport = FakeAITransport([FakeAITransport.Reply(chunks: FakeAITransport.sse(events))])
        let disclosure = Self.disclosure()
        let result = await Self.collect(AIClient(transport: transport).stream(disclosure, consent: AIConsent(approving: disclosure), key: Self.key))
        #expect(result.error == .overloaded(.anthropic, retryAfter: nil))
    }

    @Test func stoppingCancelsTheRequest() async throws {
        let transport = FakeAITransport([FakeAITransport.Reply(chunks: FakeAITransport.sse(Array(AIStreamTests.anthropicStream.prefix(8))), hangs: true)])
        let disclosure = Self.disclosure()
        let stream = AIClient(transport: transport).stream(disclosure, consent: AIConsent(approving: disclosure), key: Self.key)
        let reader = Task { await Self.collect(stream) }
        // Wait for the request, then stop, as the sheet's Stop button does.
        let deadline = Date().addingTimeInterval(5)
        while transport.requests.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        reader.cancel()
        let result = await reader.value
        #expect(result.error == .cancelled || result.error == nil)
        let cancelDeadline = Date().addingTimeInterval(5)
        while transport.bodiesCancelled == 0, Date() < cancelDeadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(transport.bodiesCancelled == 1)
    }

    @Test func wholeAnswersAndModelLists() async throws {
        let transport = FakeAITransport([
            FakeAITransport.Reply(chunks: [Data(#"{"status":"completed","model":"gpt-6-luna","output":[{"type":"message","content":[{"type":"output_text","text":"->name"}]}]}"#.utf8)]),
            FakeAITransport.Reply(chunks: [Data(#"{"object":"list","data":[{"id":"gpt-6-luna","created":2},{"id":"tts-1","created":1}]}"#.utf8)]),
            FakeAITransport.Reply(status: 401, chunks: [Data(#"{"error":{"message":"bad key"}}"#.utf8)]),
        ])
        let client = AIClient(transport: transport)
        let disclosure = Self.disclosure(.openai)
        let answer = try await client.complete(disclosure, consent: AIConsent(approving: disclosure), key: Self.key)
        #expect(answer.text == "->name")
        let sent = try #require(transport.requests.first?.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(body["stream"] == nil)
        #expect(try await client.models(.openai, key: Self.key).map(\.id) == ["gpt-6-luna"])
        await #expect(throws: AIError.invalidKey(.openai)) { try await client.models(.openai, key: Self.key) }
        await #expect(throws: AIError.missingKey(.anthropic)) { try await client.models(.anthropic, key: nil) }
        // Test Key sent the key and nothing else.
        #expect(transport.requests[1].httpBody == nil)
        #expect(transport.requests.count == 3)
    }
}
