import Foundation

/// An HTTP answer whose body arrives in chunks (#368).
public struct AIHTTPResponse: Sendable {
    public var status: Int
    /// Header names in lowercase.
    public var headers: [String: String]
    public var body: AsyncThrowingStream<Data, Error>

    public init(status: Int, headers: [String: String], body: AsyncThrowingStream<Data, Error>) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// Sends an HTTP request and hands back its body as it arrives. The app uses
/// `URLSessionAITransport`; tests give canned answers, so no test reaches a provider.
public protocol AITransport: Sendable {
    func send(_ request: URLRequest) async throws -> AIHTTPResponse
}

/// `URLSession` with an ephemeral configuration: no cookies, cache, or saved credentials. The
/// body comes a line at a time (or every 16 KB). Cancelling the task that reads it cancels the
/// request.
public struct URLSessionAITransport: AITransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = AIEndpoint.idleTimeout
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> AIHTTPResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
        }
        let body = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    var chunk = Data()
                    for try await byte in bytes {
                        chunk.append(byte)
                        if byte == 0x0A || chunk.count >= 16 * 1024 {
                            continuation.yield(chunk)
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                bytes.task.cancel()
            }
        }
        return AIHTTPResponse(status: http.statusCode, headers: headers, body: body)
    }
}

/// Sends what the user confirmed to a provider, and reads the answer (#368). The only way a
/// feature reaches a provider: `stream` and `complete` take the disclosure the user saw and the
/// consent their click made, and refuse anything else (`AIError.notConfirmed`). `models` sends
/// only the key (Test Key).
public struct AIClient: Sendable {
    public var transport: AITransport
    /// Debug builds only: one base URL for both providers, such as a local stub
    /// (`RUNLET_AI_BASE_URL`). Release builds leave it nil.
    public var baseURLOverride: URL?

    public init(transport: AITransport = URLSessionAITransport(), baseURLOverride: URL? = nil) {
        self.transport = transport
        self.baseURLOverride = baseURLOverride
    }

    public func baseURL(for provider: AIProvider) -> URL {
        baseURLOverride ?? provider.defaultBaseURL
    }

    /// The answer as it's written. Ends with `.finished`, or throws an `AIError` (`.cancelled`
    /// when the task reading it is cancelled).
    public func stream(_ disclosure: AIDisclosure, consent: AIConsent, key: SensitiveString?) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.streamAnswer(disclosure, consent: consent, key: key) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AIErrorMapping.transport(error, provider: disclosure.provider))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamAnswer(_ disclosure: AIDisclosure, consent: AIConsent, key: SensitiveString?, yield: (AIStreamEvent) -> Void) async throws {
        let provider = disclosure.provider
        let (response, key) = try await send(disclosure, consent: consent, key: key, stream: true)
        var sse = SSEDecoder()
        var decoder = AIStreamDecoder(provider: provider, key: key)
        for try await chunk in response.body {
            try Task.checkCancellation()
            for event in sse.feed(chunk) {
                for decoded in try decoder.decode(event) { yield(decoded) }
            }
            if decoder.isFinished { return }
        }
        for event in sse.finish() {
            for decoded in try decoder.decode(event) { yield(decoded) }
        }
        try Task.checkCancellation()
        guard decoder.isFinished else {
            throw AIError.network(provider, detail: "The connection closed before the answer was complete.")
        }
    }

    /// The whole answer at once: for short requests (an inline completion, #46). Cancel the
    /// calling task to stop it.
    public func complete(_ disclosure: AIDisclosure, consent: AIConsent, key: SensitiveString?) async throws -> AIResponse {
        let provider = disclosure.provider
        do {
            let (response, _) = try await send(disclosure, consent: consent, key: key, stream: false)
            return try AIResponseParser.response(try await Self.collect(response.body, limit: 8 * 1024 * 1024), provider: provider)
        } catch {
            throw AIErrorMapping.transport(error, provider: provider)
        }
    }

    /// Test Key: the models the key can use. Sends the key and nothing else.
    public func models(_ provider: AIProvider, key: SensitiveString?) async throws -> [AIModelInfo] {
        do {
            guard let key, !key.isEmpty else { throw AIError.missingKey(provider) }
            let response = try await transport.send(AIEndpoint.models(provider, key: key, baseURL: baseURL(for: provider)))
            try await check(response, provider: provider, model: nil, key: key)
            return try AIResponseParser.models(try await Self.collect(response.body, limit: 8 * 1024 * 1024), provider: provider)
        } catch {
            throw AIErrorMapping.transport(error, provider: provider)
        }
    }

    /// Checks the consent and the key, sends, and returns a 2xx answer (or throws its error). An
    /// Anthropic account that rejects the server-side fallbacks' beta (a 400 that names
    /// `anthropic-beta` or `fallbacks`) gets the same request once more without them.
    private func send(_ disclosure: AIDisclosure, consent: AIConsent, key: SensitiveString?, stream: Bool) async throws -> (AIHTTPResponse, SensitiveString) {
        guard consent.covers(disclosure), !disclosure.isEmpty else { throw AIError.notConfirmed }
        guard let key, !key.revealed().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.missingKey(disclosure.provider) }
        let provider = disclosure.provider
        let request = disclosure.request(stream: stream)
        let baseURL = baseURL(for: provider)
        var response = try await transport.send(try AIEndpoint.messages(request, key: key, baseURL: baseURL))
        if response.status == 400, provider == .anthropic, AIModelTraits.anthropicTakesDefaultFallbacks(request.model) {
            let body = (try? await Self.collect(response.body, limit: 64 * 1024)) ?? Data()
            let text = String(decoding: body, as: UTF8.self).lowercased()
            guard text.contains("anthropic-beta") || text.contains("fallbacks") else {
                throw AIErrorMapping.http(status: 400, headers: response.headers, body: body, provider: provider, model: disclosure.model, key: key)
            }
            response = try await transport.send(try AIEndpoint.messages(request, key: key, baseURL: baseURL, fallbacks: false))
        }
        try await check(response, provider: provider, model: disclosure.model, key: key)
        return (response, key)
    }

    private func check(_ response: AIHTTPResponse, provider: AIProvider, model: String?, key: SensitiveString?) async throws {
        guard !(200..<300).contains(response.status) else { return }
        let body = (try? await Self.collect(response.body, limit: 64 * 1024)) ?? Data()
        throw AIErrorMapping.http(status: response.status, headers: response.headers, body: body, provider: provider, model: model, key: key)
    }

    static func collect(_ body: AsyncThrowingStream<Data, Error>, limit: Int) async throws -> Data {
        var data = Data()
        for try await chunk in body {
            data.append(chunk)
            if data.count >= limit { break }
        }
        return data
    }
}
