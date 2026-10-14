import Foundation
import Testing
@testable import RunletCore

/// #368: the HTTP requests for Anthropic's Messages API and OpenAI's Responses API, built
/// without sending anything. The key goes only into a header.
struct AIRequestTests {
    static let key = SensitiveString("sk-ant-api03-EXAMPLE-not-a-real-key-Q2c4")
    static let base = URL(string: "http://127.0.0.1:9")!

    static func request(_ provider: AIProvider, model: String? = nil, effort: AIEffort? = .medium, stream: Bool = true) -> AIRequest {
        AIRequest(provider: provider, model: model ?? provider.defaultModel, instructions: "Explain the error.",
                  messages: [AIMessage(.user, "## The error\n\nTypeError: …"), AIMessage(.assistant, "It's a type error."), AIMessage(.user, "Why?")],
                  maxOutputTokens: 16_000, effort: effort, stream: stream)
    }

    static func json(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func anthropicMessagesRequest() throws {
        let http = try AIEndpoint.messages(Self.request(.anthropic), key: Self.key, baseURL: AIProvider.anthropic.defaultBaseURL)
        #expect(http.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(http.httpMethod == "POST")
        #expect(http.value(forHTTPHeaderField: "x-api-key") == Self.key.revealed())
        #expect(http.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(http.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(http.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try Self.json(http)
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["max_tokens"] as? Int == 16_000)
        #expect(body["system"] as? String == "Explain the error.")
        #expect(body["stream"] as? Bool == true)
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "medium")
        #expect(body["fallbacks"] as? String == "default")
        // Thinking is left to the model (adaptive on current models), and no sampling parameters.
        #expect(body["thinking"] == nil)
        #expect(body["temperature"] == nil)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        #expect(messages.last?["content"] as? String == "Why?")
        // The key is never in the URL or the body.
        #expect(!(http.url?.absoluteString.contains("sk-") ?? true))
        #expect(!String(decoding: http.httpBody ?? Data(), as: UTF8.self).contains(Self.key.revealed()))
    }

    @Test func anthropicOlderModelsGetNoEffortOrFallbacks() throws {
        let http = try AIEndpoint.messages(Self.request(.anthropic, model: "claude-haiku-4-5"), key: Self.key, baseURL: Self.base)
        #expect(http.url?.absoluteString == "http://127.0.0.1:9/v1/messages")
        #expect(http.value(forHTTPHeaderField: "anthropic-beta") == nil)
        let body = try Self.json(http)
        #expect(body["output_config"] == nil)
        #expect(body["fallbacks"] == nil)
        // Haiku 5.5 takes effort but rejects fallbacks.
        let haiku = try Self.json(try AIEndpoint.messages(Self.request(.anthropic, model: "claude-haiku-5-5"), key: Self.key, baseURL: Self.base))
        #expect((haiku["output_config"] as? [String: Any])?["effort"] as? String == "medium")
        #expect(haiku["fallbacks"] == nil)
        // No effort asked for, none sent; a whole answer has no stream field.
        let plain = try Self.json(try AIEndpoint.messages(Self.request(.anthropic, effort: nil, stream: false), key: Self.key, baseURL: Self.base))
        #expect(plain["output_config"] == nil)
        #expect(plain["stream"] == nil)
    }

    @Test func openAIResponsesRequest() throws {
        let key = SensitiveString("sk-proj-EXAMPLEEXAMPLEEXAMPLE9xYz")
        let http = try AIEndpoint.messages(Self.request(.openai), key: key, baseURL: AIProvider.openai.defaultBaseURL)
        #expect(http.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(http.value(forHTTPHeaderField: "Authorization") == "Bearer \(key.revealed())")
        #expect(http.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(http.value(forHTTPHeaderField: "anthropic-version") == nil)
        let body = try Self.json(http)
        #expect(body["model"] as? String == "gpt-6-astra")
        #expect(body["instructions"] as? String == "Explain the error.")
        #expect(body["max_output_tokens"] as? Int == 16_000)
        #expect(body["stream"] as? Bool == true)
        // OpenAI keeps no copy of the response for later retrieval.
        #expect(body["store"] as? Bool == false)
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "medium")
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.map { $0["role"] as? String } == ["user", "assistant", "user"])
        #expect(input.first?["content"] as? String == "## The error\n\nTypeError: …")

        let chat = try Self.json(try AIEndpoint.messages(Self.request(.openai, model: "gpt-4.1"), key: key, baseURL: Self.base))
        #expect(chat["reasoning"] == nil)
    }

    @Test func modelListRequests() {
        let anthropic = AIEndpoint.models(.anthropic, key: Self.key, baseURL: AIProvider.anthropic.defaultBaseURL)
        #expect(anthropic.url?.absoluteString == "https://api.anthropic.com/v1/models?limit=1000")
        #expect(anthropic.httpMethod == "GET")
        #expect(anthropic.value(forHTTPHeaderField: "x-api-key") == Self.key.revealed())
        #expect(anthropic.httpBody == nil)
        let openai = AIEndpoint.models(.openai, key: Self.key, baseURL: Self.base)
        #expect(openai.url?.absoluteString == "http://127.0.0.1:9/v1/models")
        #expect(openai.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.key.revealed())")
    }

    @Test func theSameRequestHasTheSameBytes() throws {
        let one = try AIEndpoint.body(Self.request(.anthropic))
        let two = try AIEndpoint.body(Self.request(.anthropic))
        #expect(one == two)
    }
}
