import Foundation

/// One turn of a conversation with a model (#368). A one-off question is a single user message;
/// a chat (#45) sends the earlier turns too.
public struct AIMessage: Sendable, Codable, Equatable, Hashable {
    public enum Role: String, Sendable, Codable, Hashable {
        case user, assistant
    }

    public var role: Role
    public var text: String

    public init(_ role: Role, _ text: String) {
        self.role = role
        self.text = text
    }
}

/// Everything one request to a provider holds, before it's an HTTP request. Built only from an
/// `AIDisclosure` the user saw (`AIDisclosure.request`), so what is sent is what was shown.
public struct AIRequest: Sendable, Equatable {
    public var provider: AIProvider
    public var model: String
    /// The system prompt (Anthropic's `system`, OpenAI's `instructions`).
    public var instructions: String
    public var messages: [AIMessage]
    /// The answer's limit, thinking included. An answer that reaches it ends with
    /// `AIStopReason.maxTokens`.
    public var maxOutputTokens: Int
    public var effort: AIEffort?
    /// Server-sent events as the model writes, or one answer at the end.
    public var stream: Bool

    public init(provider: AIProvider, model: String, instructions: String, messages: [AIMessage], maxOutputTokens: Int, effort: AIEffort? = nil, stream: Bool = true) {
        self.provider = provider
        self.model = model
        self.instructions = instructions
        self.messages = messages
        self.maxOutputTokens = maxOutputTokens
        self.effort = effort
        self.stream = stream
    }
}

/// HTTP requests for the providers' APIs (#368), checked against their documentation in
/// October 2026:
///
/// - **Anthropic:** `POST /v1/messages` with `x-api-key` and `anthropic-version: 2023-06-01`;
///   `system`, `messages`, `max_tokens`, and `stream`. `thinking` is left out: current models
///   then think adaptively, and older ones don't. `output_config.effort` goes only to models
///   that take it, and models with safety classifiers get `fallbacks: "default"` with its beta
///   header, so a declined request is retried on Anthropic's recommended model instead of
///   failing (`AIClient` asks once more without them when an account rejects the beta). `GET /v1/models?limit=1000` lists the account's models.
///   An effort level goes only when the model takes that level (`AIModelTraits.effortLevels`).
/// - **OpenAI:** the Responses API, `POST /v1/responses` with `Authorization: Bearer`;
///   `instructions`, `input`, `max_output_tokens`, `stream`, and `store: false`, so OpenAI
///   doesn't keep the response for later retrieval. `reasoning.effort` goes only to reasoning
///   models. `GET /v1/models` lists the models.
///
/// The key goes only into a header, never into the URL or the body.
public enum AIEndpoint {
    public static let anthropicVersion = "2023-06-01"
    /// The beta that gates `fallbacks: "default"` (the array form has another).
    public static let anthropicFallbackBeta = "server-side-fallback-2026-07-01"
    /// Seconds without a byte before a request gives up. Streams send events (and Anthropic's
    /// pings) well within it, also while a model thinks.
    public static let idleTimeout: TimeInterval = 120

    /// `fallbacks: false` leaves Anthropic's server-side fallbacks out, for an account that
    /// rejects their beta header (`AIClient` retries once without them).
    public static func messages(_ request: AIRequest, key: SensitiveString, baseURL: URL, fallbacks: Bool = true) throws -> URLRequest {
        var url = baseURL
        switch request.provider {
        case .anthropic: url.append(path: "v1/messages")
        case .openai: url.append(path: "v1/responses")
        }
        var http = URLRequest(url: url, timeoutInterval: idleTimeout)
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if request.stream { http.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        authorize(&http, provider: request.provider, key: key)
        if fallbacks, request.provider == .anthropic, AIModelTraits.anthropicTakesDefaultFallbacks(request.model) {
            http.setValue(anthropicFallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        http.httpBody = try body(request, fallbacks: fallbacks)
        return http
    }

    public static func models(_ provider: AIProvider, key: SensitiveString, baseURL: URL) -> URLRequest {
        var url = baseURL
        url.append(path: "v1/models")
        if provider == .anthropic { url.append(queryItems: [URLQueryItem(name: "limit", value: "1000")]) }
        var http = URLRequest(url: url, timeoutInterval: 30)
        http.httpMethod = "GET"
        authorize(&http, provider: provider, key: key)
        return http
    }

    private static func authorize(_ http: inout URLRequest, provider: AIProvider, key: SensitiveString) {
        switch provider {
        case .anthropic:
            http.setValue(key.revealed(), forHTTPHeaderField: "x-api-key")
            http.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        case .openai:
            http.setValue("Bearer " + key.revealed(), forHTTPHeaderField: "Authorization")
        }
    }

    /// The JSON body, with sorted keys (the same request always has the same bytes).
    public static func body(_ request: AIRequest, fallbacks: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        switch request.provider {
        case .anthropic:
            return try encoder.encode(AnthropicBody(request, fallbacks: fallbacks))
        case .openai:
            return try encoder.encode(OpenAIBody(request))
        }
    }

    private struct AnthropicBody: Encodable {
        struct Message: Encodable {
            var role: String
            var content: String
        }

        struct OutputConfig: Encodable {
            var effort: String
        }

        var model: String
        var max_tokens: Int
        var system: String?
        var messages: [Message]
        var stream: Bool?
        var output_config: OutputConfig?
        var fallbacks: String?

        init(_ request: AIRequest, fallbacks: Bool) {
            model = request.model
            max_tokens = request.maxOutputTokens
            system = request.instructions.isEmpty ? nil : request.instructions
            messages = request.messages.map { Message(role: $0.role.rawValue, content: $0.text) }
            stream = request.stream ? true : nil
            // #45: only a level the model takes; any other would be a 400.
            if let effort = request.effort, AIModelTraits.effortLevels(.anthropic, request.model).contains(effort) {
                output_config = OutputConfig(effort: effort.rawValue)
            }
            self.fallbacks = fallbacks && AIModelTraits.anthropicTakesDefaultFallbacks(request.model) ? "default" : nil
        }
    }

    private struct OpenAIBody: Encodable {
        struct Message: Encodable {
            var role: String
            var content: String
        }

        struct Reasoning: Encodable {
            var effort: String
        }

        var model: String
        var instructions: String?
        var input: [Message]
        var max_output_tokens: Int
        var stream: Bool?
        var store: Bool
        var reasoning: Reasoning?

        init(_ request: AIRequest) {
            model = request.model
            instructions = request.instructions.isEmpty ? nil : request.instructions
            input = request.messages.map { Message(role: $0.role.rawValue, content: $0.text) }
            max_output_tokens = request.maxOutputTokens
            stream = request.stream ? true : nil
            store = false
            if let effort = request.effort, AIModelTraits.effortLevels(.openai, request.model).contains(effort) {
                reasoning = Reasoning(effort: effort.rawValue)
            }
        }
    }
}
