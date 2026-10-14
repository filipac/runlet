import Foundation

/// One server-sent event: its `event:` name and its `data:` lines joined by newlines.
public struct SSEEvent: Sendable, Equatable {
    public var event: String?
    public var data: String

    public init(event: String? = nil, data: String) {
        self.event = event
        self.data = data
    }
}

/// Reads server-sent events from bytes as they arrive (#368), in any chunks: a line, or a
/// UTF-8 character, may be split between two. Lines end with LF, CRLF, or CR; a blank line ends
/// an event; `:` lines are comments; `id:` and `retry:` are ignored.
public struct SSEDecoder: Sendable {
    private var line: [UInt8] = []
    private var lastWasCR = false
    private var event: String?
    private var data: [String] = []

    public init() {}

    public mutating func feed(_ chunk: Data) -> [SSEEvent] {
        var events: [SSEEvent] = []
        for byte in chunk {
            if byte == 0x0A, lastWasCR {
                lastWasCR = false
                continue
            }
            lastWasCR = byte == 0x0D
            if byte == 0x0A || byte == 0x0D {
                if let event = endLine() { events.append(event) }
            } else {
                line.append(byte)
            }
        }
        return events
    }

    /// The last event, when the stream ended without a blank line after it.
    public mutating func finish() -> [SSEEvent] {
        var events: [SSEEvent] = []
        if !line.isEmpty, let event = endLine() { events.append(event) }
        if let event = dispatch() { events.append(event) }
        return events
    }

    private mutating func endLine() -> SSEEvent? {
        let text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        if text.isEmpty { return dispatch() }
        if text.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(text)
            value = ""
        }
        switch field {
        case "event": event = String(value)
        case "data": data.append(String(value))
        default: break
        }
        return nil
    }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            event = nil
            data = []
        }
        guard !data.isEmpty else { return nil }
        return SSEEvent(event: event, data: data.joined(separator: "\n"))
    }
}

/// What a streamed answer tells Runlet, the same for both providers (#368).
public enum AIStreamEvent: Sendable, Equatable {
    /// The answer started; `model` is the model that answers.
    case started(model: String)
    /// The model is thinking (its reasoning isn't shown).
    case thinking
    /// The answer's next text.
    case text(String)
    /// Anthropic's safety checks declined the request, and another model (`to`) took over: the
    /// answer goes on.
    case fallback(from: String?, to: String?)
    /// The answer ended.
    case finished(AIFinish)
}

public struct AIFinish: Sendable, Equatable {
    public var reason: AIStopReason
    public var model: String?
    public var usage: AIUsage?

    public init(reason: AIStopReason, model: String? = nil, usage: AIUsage? = nil) {
        self.reason = reason
        self.model = model
        self.usage = usage
    }
}

/// Why an answer ended.
public enum AIStopReason: Sendable, Equatable {
    /// The model finished.
    case complete
    /// The answer reached `maxOutputTokens`: it's cut off.
    case maxTokens
    /// The model, or the provider's safety checks, declined. Text already received isn't a
    /// complete answer.
    case refusal(category: String?, explanation: String?)
    /// Any other reason, as the provider names it.
    case other(String)
}

public struct AIUsage: Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// A whole answer, not streamed.
public struct AIResponse: Sendable, Equatable {
    public var text: String
    public var finish: AIFinish

    public init(text: String, finish: AIFinish) {
        self.text = text
        self.finish = finish
    }
}

/// Turns a provider's server-sent events into `AIStreamEvent`s (#368). An error event in the
/// stream throws its `AIError`; unknown events are skipped, as both providers ask.
///
/// - **Anthropic:** `message_start` (the model), `content_block_start` (`text`, `thinking`,
///   `redacted_thinking`, and `fallback` blocks), `content_block_delta` (`text_delta`; thinking
///   deltas aren't shown), `message_delta` (`stop_reason`, `stop_details` for a refusal, the
///   output tokens), `message_stop`, `ping`, and `error`.
/// - **OpenAI:** `response.created`, `response.output_item.added` (a `reasoning` item),
///   `response.output_text.delta`, `response.refusal.delta`, `response.completed`,
///   `response.incomplete` (`max_output_tokens`, `content_filter`), `response.failed`, and
///   `error`.
public struct AIStreamDecoder: Sendable {
    public let provider: AIProvider
    public private(set) var model: String?
    public private(set) var isFinished = false
    private var stopReason: String?
    private var refusalCategory: String?
    private var refusalExplanation: String?
    private var refusalText = ""
    private var usage = AIUsage()
    private var key: SensitiveString?

    public init(provider: AIProvider, key: SensitiveString? = nil) {
        self.provider = provider
        self.key = key
    }

    public mutating func decode(_ event: SSEEvent) throws -> [AIStreamEvent] {
        guard !isFinished else { return [] }
        guard let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any] else {
            if event.data.trimmingCharacters(in: .whitespaces) == "[DONE]" { return [] }
            throw AIError.invalidResponse(provider, detail: "An event wasn't JSON.")
        }
        let type = object["type"] as? String ?? event.event ?? ""
        switch provider {
        case .anthropic: return try anthropic(type, object)
        case .openai: return try openai(type, object)
        }
    }

    // MARK: Anthropic

    private mutating func anthropic(_ type: String, _ object: [String: Any]) throws -> [AIStreamEvent] {
        switch type {
        case "message_start":
            let message = object["message"] as? [String: Any]
            model = message?["model"] as? String
            if let usage = message?["usage"] as? [String: Any] { self.usage.inputTokens = usage["input_tokens"] as? Int }
            return [.started(model: model ?? "")]
        case "content_block_start":
            guard let block = object["content_block"] as? [String: Any] else { return [] }
            switch block["type"] as? String {
            case "thinking", "redacted_thinking":
                return [.thinking]
            case "text":
                let text = block["text"] as? String ?? ""
                return text.isEmpty ? [] : [.text(text)]
            case "fallback":
                let from = (block["from"] as? [String: Any])?["model"] as? String
                let to = (block["to"] as? [String: Any])?["model"] as? String
                if let to { model = to }
                return [.fallback(from: from, to: to)]
            default:
                return []
            }
        case "content_block_delta":
            guard let delta = object["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String, !text.isEmpty else { return [] }
            return [.text(text)]
        case "message_delta":
            if let delta = object["delta"] as? [String: Any] {
                if let reason = delta["stop_reason"] as? String { stopReason = reason }
                if let details = delta["stop_details"] as? [String: Any] {
                    refusalCategory = details["category"] as? String
                    refusalExplanation = details["explanation"] as? String
                }
            }
            if let usage = object["usage"] as? [String: Any], let output = usage["output_tokens"] as? Int { self.usage.outputTokens = output }
            return []
        case "message_stop":
            isFinished = true
            return [.finished(AIFinish(reason: anthropicReason(), model: model, usage: usage))]
        case "error":
            let error = object["error"] as? [String: Any]
            throw AIErrorMapping.stream(type: error?["type"] as? String, message: error?["message"] as? String, provider: provider, key: key)
        default:
            return []
        }
    }

    private func anthropicReason() -> AIStopReason {
        switch stopReason {
        case nil, "end_turn", "stop_sequence": .complete
        case "max_tokens": .maxTokens
        case "refusal": .refusal(category: refusalCategory, explanation: refusalExplanation)
        case let other?: .other(other)
        }
    }

    // MARK: OpenAI

    private mutating func openai(_ type: String, _ object: [String: Any]) throws -> [AIStreamEvent] {
        switch type {
        case "response.created":
            model = (object["response"] as? [String: Any])?["model"] as? String
            return [.started(model: model ?? "")]
        case "response.output_item.added":
            let item = object["item"] as? [String: Any]
            return item?["type"] as? String == "reasoning" ? [.thinking] : []
        case "response.output_text.delta":
            guard let text = object["delta"] as? String, !text.isEmpty else { return [] }
            return [.text(text)]
        case "response.refusal.delta":
            refusalText += object["delta"] as? String ?? ""
            return []
        case "response.completed", "response.incomplete":
            let response = object["response"] as? [String: Any] ?? [:]
            if let name = response["model"] as? String { model = name }
            if let usage = response["usage"] as? [String: Any] {
                self.usage = AIUsage(inputTokens: usage["input_tokens"] as? Int, outputTokens: usage["output_tokens"] as? Int)
            }
            isFinished = true
            let reason: AIStopReason
            if type == "response.incomplete" {
                switch (response["incomplete_details"] as? [String: Any])?["reason"] as? String {
                case "max_output_tokens": reason = .maxTokens
                case "content_filter": reason = .refusal(category: "content_filter", explanation: refusalText.isEmpty ? nil : refusalText)
                case let other?: reason = .other(other)
                case nil: reason = .other("incomplete")
                }
            } else if !refusalText.isEmpty {
                reason = .refusal(category: nil, explanation: refusalText)
            } else {
                reason = .complete
            }
            return [.finished(AIFinish(reason: reason, model: model, usage: usage))]
        case "response.failed":
            let error = (object["response"] as? [String: Any])?["error"] as? [String: Any]
            throw AIErrorMapping.stream(type: error?["code"] as? String, message: error?["message"] as? String, provider: provider, key: key)
        case "error":
            throw AIErrorMapping.stream(type: object["code"] as? String, message: object["message"] as? String, provider: provider, key: key)
        default:
            return []
        }
    }
}

/// Reads whole answers (not streamed) and model lists (#368).
public enum AIResponseParser {
    public static func response(_ data: Data, provider: AIProvider) throws -> AIResponse {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.invalidResponse(provider, detail: "The answer wasn't JSON.")
        }
        let model = object["model"] as? String
        switch provider {
        case .anthropic:
            let blocks = object["content"] as? [[String: Any]] ?? []
            let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            let usage = object["usage"] as? [String: Any]
            let details = object["stop_details"] as? [String: Any]
            let reason: AIStopReason = switch object["stop_reason"] as? String {
            case nil, "end_turn", "stop_sequence": .complete
            case "max_tokens": .maxTokens
            case "refusal": .refusal(category: details?["category"] as? String, explanation: details?["explanation"] as? String)
            case let other?: .other(other)
            }
            return AIResponse(text: text, finish: AIFinish(reason: reason, model: model, usage: AIUsage(inputTokens: usage?["input_tokens"] as? Int, outputTokens: usage?["output_tokens"] as? Int)))
        case .openai:
            if let error = object["error"] as? [String: Any] {
                throw AIErrorMapping.stream(type: error["code"] as? String, message: error["message"] as? String, provider: provider)
            }
            var text = ""
            var refusal = ""
            for item in object["output"] as? [[String: Any]] ?? [] where item["type"] as? String == "message" {
                for part in item["content"] as? [[String: Any]] ?? [] {
                    switch part["type"] as? String {
                    case "output_text": text += part["text"] as? String ?? ""
                    case "refusal": refusal += part["refusal"] as? String ?? ""
                    default: break
                    }
                }
            }
            let usage = object["usage"] as? [String: Any]
            let reason: AIStopReason
            if object["status"] as? String == "incomplete" {
                switch (object["incomplete_details"] as? [String: Any])?["reason"] as? String {
                case "max_output_tokens": reason = .maxTokens
                case "content_filter": reason = .refusal(category: "content_filter", explanation: refusal.isEmpty ? nil : refusal)
                case let other: reason = .other(other ?? "incomplete")
                }
            } else {
                reason = refusal.isEmpty ? .complete : .refusal(category: nil, explanation: refusal)
            }
            return AIResponse(text: text, finish: AIFinish(reason: reason, model: model, usage: AIUsage(inputTokens: usage?["input_tokens"] as? Int, outputTokens: usage?["output_tokens"] as? Int)))
        }
    }

    /// `GET /v1/models`: Anthropic's models as listed (newest first, with their names);
    /// OpenAI's text models only, newest first, without audio, image, embedding, moderation,
    /// realtime, search, and speech models.
    public static func models(_ data: Data, provider: AIProvider) throws -> [AIModelInfo] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else {
            throw AIError.invalidResponse(provider, detail: "The model list wasn't JSON.")
        }
        switch provider {
        case .anthropic:
            return list.compactMap { item in
                guard let id = item["id"] as? String else { return nil }
                return AIModelInfo(id: id, displayName: item["display_name"] as? String)
            }
        case .openai:
            let excluded = ["audio", "realtime", "tts", "transcribe", "image", "search", "embedding", "moderation", "dall-e", "whisper", "computer-use", "instruct"]
            return list
                .compactMap { item -> (String, Int)? in
                    guard let id = item["id"] as? String else { return nil }
                    return (id, item["created"] as? Int ?? 0)
                }
                .filter { id, _ in
                    (id.hasPrefix("gpt-") || AIModelTraits.isOSeries(id)) && !excluded.contains { id.contains($0) }
                }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
                .map { AIModelInfo(id: $0.0) }
        }
    }
}
