import Foundation

/// Why an AI request failed (#368), with the alert's title and message (`title`, `message`):
/// what happened, and what to do next. No case holds the key, and messages from a provider are
/// shown only through `AIRedaction.scrub`.
public enum AIError: Error, Sendable, Equatable {
    case missingKey(AIProvider)
    /// 401: the key is wrong, revoked, or for another provider.
    case invalidKey(AIProvider)
    /// 403: the key can't do this (a workspace or region restriction, for example).
    case permissionDenied(AIProvider, message: String?)
    /// 402, or OpenAI's `insufficient_quota`: no credits or no billing set up.
    case billing(AIProvider, message: String?)
    /// 429, with the `retry-after` the provider sent.
    case rateLimited(AIProvider, retryAfter: TimeInterval?)
    /// 529 or 503, or an `overloaded_error` in the stream.
    case overloaded(AIProvider, retryAfter: TimeInterval?)
    /// Another 5xx, or a failure the provider reported in the stream.
    case server(AIProvider, status: Int?, message: String?)
    /// 404: the model doesn't exist, or the account can't use it.
    case modelNotFound(AIProvider, model: String)
    /// 400: the provider rejected the request.
    case badRequest(AIProvider, message: String?)
    /// 413: the request is larger than the provider takes.
    case tooLarge(AIProvider)
    /// The provider's safety checks declined the request, and no fallback model answered.
    case refused(AIProvider, category: String?, explanation: String?)
    /// No connection, a lost connection, or an answer that stopped before it ended.
    case network(AIProvider, detail: String)
    case timedOut(AIProvider)
    /// The user pressed Stop, or closed the sheet.
    case cancelled
    /// The answer couldn't be read.
    case invalidResponse(AIProvider, detail: String)
    /// Code asked to send something the user didn't confirm (`AIConsent`). Never shown to users
    /// in normal use: it means a feature skipped the disclosure.
    case notConfirmed

    public var provider: AIProvider? {
        switch self {
        case .missingKey(let p), .invalidKey(let p), .permissionDenied(let p, _), .billing(let p, _), .rateLimited(let p, _),
             .overloaded(let p, _), .server(let p, _, _), .modelNotFound(let p, _), .badRequest(let p, _), .tooLarge(let p),
             .refused(let p, _, _), .network(let p, _), .timedOut(let p), .invalidResponse(let p, _):
            p
        case .cancelled, .notConfirmed:
            nil
        }
    }

    /// Trying the same request again later may work.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded, .server, .network, .timedOut: true
        default: false
        }
    }

    /// Fixed in Settings ▸ AI (a key or a model): the alert offers to open it.
    public var opensSettings: Bool {
        switch self {
        case .missingKey, .invalidKey, .modelNotFound: true
        default: false
        }
    }

    /// The alert's title: a statement, in sentence case, without a period.
    public var title: String {
        let name = provider?.displayName ?? "The provider"
        switch self {
        case .missingKey: return "No \(name) key"
        case .invalidKey: return "\(name) didn't accept the key"
        case .permissionDenied: return "\(name) didn't allow the request"
        case .billing: return "\(name) needs billing set up"
        case .rateLimited: return "\(name) is limiting requests"
        case .overloaded: return "\(name) is overloaded"
        case .server(_, let status, _): return status.map { "\(name) had a problem (error \($0))" } ?? "\(name) had a problem"
        case .modelNotFound(_, let model): return "\(name) doesn't offer “\(model)”"
        case .badRequest: return "\(name) rejected the request"
        case .tooLarge: return "The request is too large"
        case .refused: return "The model declined to answer"
        case .network: return "Couldn't reach \(name)"
        case .timedOut: return "\(name) took too long to answer"
        case .cancelled: return "Stopped"
        case .invalidResponse: return "\(name)'s answer couldn't be read"
        case .notConfirmed: return "Nothing was sent"
        }
    }

    /// The alert's message: full sentences that say what to do next.
    public var message: String {
        let name = provider?.displayName ?? "the provider"
        switch self {
        case .missingKey:
            return "Add your \(name) API key in Settings ▸ AI. Runlet keeps it in your Mac's Keychain."
        case .invalidKey:
            return "Check the key in Settings ▸ AI and press Test Key, or create a new key in your \(name) account."
        case .permissionDenied(_, let detail):
            return joined(detail, "Check what this key's account or workspace may use in your \(name) account.")
        case .billing(_, let detail):
            return joined(detail, "Check your plan and credits in your \(name) account, then try again.")
        case .rateLimited(_, let retryAfter):
            return retryAfter.map { "Try again in \(Self.duration($0))." } ?? "Wait a moment, then try again."
        case .overloaded(_, let retryAfter):
            return (retryAfter.map { "Try again in \(Self.duration($0))" } ?? "Try again in a minute") + ", or choose another model in Settings ▸ AI."
        case .server(_, _, let detail):
            return joined(detail, "Try again in a moment.")
        case .modelNotFound:
            return "The model doesn't exist, or your account can't use it. Choose another in Settings ▸ AI; Test Key lists the models your key can use."
        case .badRequest(_, let detail):
            return joined(detail, "If it names the model, choose another one in Settings ▸ AI.")
        case .tooLarge:
            return "Leave out the source or part of the code, then try again."
        case .refused(_, let category, let explanation):
            let reason = category.map { " (\($0))" } ?? ""
            return joined(explanation, "\(name)'s safety checks stopped this request\(reason). Leave out part of the code, or rephrase, then try again.")
        case .network(_, let detail):
            return "Check your internet connection, then try again. \(detail)"
        case .timedOut:
            return "Try again, or choose a faster model in Settings ▸ AI."
        case .cancelled:
            return "Nothing more was received."
        case .invalidResponse(_, let detail):
            return "Try again. \(detail)"
        case .notConfirmed:
            return "Runlet sends only what you've seen and confirmed."
        }
    }

    private func joined(_ detail: String?, _ next: String) -> String {
        guard let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty else { return next }
        let sentence = detail.hasSuffix(".") || detail.hasSuffix("!") || detail.hasSuffix("?") ? detail : detail + "."
        return sentence + " " + next
    }

    /// "30 seconds", "1 minute", "2 minutes".
    static func duration(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded(.up))
        if whole < 60 { return whole == 1 ? "1 second" : "\(max(whole, 1)) seconds" }
        let minutes = Int((Double(whole) / 60).rounded(.up))
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}

/// Turns what a provider answered into an `AIError` (#368).
public enum AIErrorMapping {
    /// A non-2xx answer: its status, headers (lowercased names), and body. Provider messages are
    /// scrubbed of the key and anything shaped like one; a 401's message isn't kept at all,
    /// since providers repeat part of the key in it.
    public static func http(status: Int, headers: [String: String], body: Data, provider: AIProvider, model: String?, key: SensitiveString?) -> AIError {
        let detail = errorDetail(body)
        let message = detail.message.map { AIRedaction.scrub($0, key: key) }
        switch status {
        case 401:
            return .invalidKey(provider)
        case 402:
            return .billing(provider, message: message)
        case 403:
            return .permissionDenied(provider, message: message)
        case 404:
            if let model { return .modelNotFound(provider, model: model) }
            return .badRequest(provider, message: message)
        case 413:
            return .tooLarge(provider)
        case 429:
            if detail.code == "insufficient_quota" || detail.type == "insufficient_quota" { return .billing(provider, message: message) }
            return .rateLimited(provider, retryAfter: retryAfter(headers))
        case 503, 529:
            return .overloaded(provider, retryAfter: retryAfter(headers))
        case 400, 422:
            return .badRequest(provider, message: message)
        case 500...599:
            return .server(provider, status: status, message: message)
        default:
            return .server(provider, status: status, message: message)
        }
    }

    /// An error event in a stream: Anthropic's `{"type": "error", "error": {"type", "message"}}`,
    /// or OpenAI's `error` event and failed response (`code`, `message`).
    public static func stream(type: String?, message: String?, provider: AIProvider, key: SensitiveString? = nil) -> AIError {
        let message = message.map { AIRedaction.scrub($0, key: key) }
        switch type {
        case "overloaded_error", "server_is_overloaded", "slow_down":
            return .overloaded(provider, retryAfter: nil)
        case "rate_limit_error", "rate_limit_exceeded":
            return .rateLimited(provider, retryAfter: nil)
        case "insufficient_quota", "billing_error":
            return .billing(provider, message: message)
        case "authentication_error", "invalid_api_key":
            return .invalidKey(provider)
        case "permission_error":
            return .permissionDenied(provider, message: message)
        case "request_too_large":
            return .tooLarge(provider)
        case "invalid_request_error", "invalid_prompt":
            return .badRequest(provider, message: message)
        case "bio_policy", "misalignment_policy_violation", "image_content_policy_violation", "content_filter":
            return .refused(provider, category: type, explanation: message)
        default:
            return .server(provider, status: nil, message: message)
        }
    }

    /// A failure before any answer: no network, a timeout, or Stop.
    public static func transport(_ error: Error, provider: AIProvider) -> AIError {
        if let error = error as? AIError { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timedOut(provider)
            default: return .network(provider, detail: error.localizedDescription)
            }
        }
        return .network(provider, detail: error.localizedDescription)
    }

    /// Seconds to wait, from `retry-after-ms`, or `retry-after` in seconds or as an HTTP date.
    public static func retryAfter(_ headers: [String: String], now: Date = Date()) -> TimeInterval? {
        if let ms = headers["retry-after-ms"].flatMap(Double.init), ms >= 0 { return ms / 1000 }
        guard let value = headers["retry-after"]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Double(value) { return seconds >= 0 ? seconds : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    struct Detail {
        var type: String?
        var code: String?
        var message: String?
    }

    /// Both providers answer `{"error": {"type", "message"}}` (OpenAI adds `code`).
    static func errorDetail(_ body: Data) -> Detail {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = object["error"] as? [String: Any] else {
            let text = String(decoding: body.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return Detail(message: text.isEmpty || text.hasPrefix("<") ? nil : text)
        }
        return Detail(type: error["type"] as? String, code: error["code"] as? String, message: error["message"] as? String)
    }
}

/// Keeps keys out of what Runlet shows (#368).
public enum AIRedaction {
    /// The text without the key, and without anything shaped like an API key (`sk-…`), which a
    /// provider may echo in part.
    public static func scrub(_ text: String, key: SensitiveString?) -> String {
        var text = text
        if let key, key.revealed().count >= 8 {
            text = text.replacingOccurrences(of: key.revealed(), with: "•••")
        }
        let pattern = #"sk-[A-Za-z0-9_\-*•]{6,}"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "sk-•••")
        }
        return text
    }
}
