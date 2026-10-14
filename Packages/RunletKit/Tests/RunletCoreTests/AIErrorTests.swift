import Foundation
import Testing
@testable import RunletCore

/// #368: provider failures as `AIError`s, and the alerts they make: what happened and what to
/// do next, never with the key in them.
struct AIErrorTests {
    static let key = SensitiveString("sk-ant-api03-EXAMPLE-not-a-real-key-Q2c4")

    static func http(_ status: Int, _ body: String = "", headers: [String: String] = [:], provider: AIProvider = .anthropic, model: String? = "claude-opus-5-5") -> AIError {
        AIErrorMapping.http(status: status, headers: headers, body: Data(body.utf8), provider: provider, model: model, key: key)
    }

    @Test func statusCodes() {
        #expect(Self.http(401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#) == .invalidKey(.anthropic))
        #expect(Self.http(402, #"{"error":{"type":"billing_error","message":"Your credit balance is too low."}}"#) == .billing(.anthropic, message: "Your credit balance is too low."))
        #expect(Self.http(403, #"{"error":{"type":"permission_error","message":"Not allowed."}}"#) == .permissionDenied(.anthropic, message: "Not allowed."))
        #expect(Self.http(404, #"{"error":{"type":"not_found_error","message":"model: claude-x"}}"#, model: "claude-x") == .modelNotFound(.anthropic, model: "claude-x"))
        #expect(Self.http(413) == .tooLarge(.anthropic))
        #expect(Self.http(429, headers: ["retry-after": "20"]) == .rateLimited(.anthropic, retryAfter: 20))
        #expect(Self.http(529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#) == .overloaded(.anthropic, retryAfter: nil))
        #expect(Self.http(503, headers: ["retry-after-ms": "1500"], provider: .openai) == .overloaded(.openai, retryAfter: 1.5))
        #expect(Self.http(500, #"{"error":{"type":"api_error","message":"Internal server error"}}"#) == .server(.anthropic, status: 500, message: "Internal server error"))
        #expect(Self.http(400, #"{"error":{"message":"max_tokens: too large","type":"invalid_request_error"}}"#) == .badRequest(.anthropic, message: "max_tokens: too large"))
        #expect(Self.http(502, "<html>Bad gateway</html>") == .server(.anthropic, status: 502, message: nil))
        // OpenAI's out-of-credits answer is a 429 with its own code: billing, not a rate limit.
        #expect(Self.http(429, #"{"error":{"message":"You exceeded your current quota.","type":"insufficient_quota","code":"insufficient_quota"}}"#, provider: .openai)
            == .billing(.openai, message: "You exceeded your current quota."))
    }

    @Test func aRejectedKeyIsNeverRepeated() {
        // OpenAI echoes part of a wrong key in its 401 message; Runlet doesn't keep that message.
        let error = Self.http(401, #"{"error":{"message":"Incorrect API key provided: sk-proj-****9xYz.","type":"invalid_request_error","code":"invalid_api_key"}}"#, provider: .openai)
        #expect(error == .invalidKey(.openai))
        #expect(!error.message.contains("sk-"))
        // Other messages are scrubbed of the key and of anything shaped like one.
        let echoed = Self.http(400, #"{"error":{"message":"Bad header sk-ant-api03-EXAMPLE-not-a-real-key-Q2c4 and sk-proj-abcdef123456"}}"#)
        guard case .badRequest(_, let message?) = echoed else { Issue.record("not a bad request"); return }
        #expect(!message.contains("EXAMPLE"))
        #expect(!message.contains("abcdef123456"))
        #expect(message.contains("sk-•••"))
    }

    @Test func retryAfter() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AIErrorMapping.retryAfter(["retry-after": "30"], now: now) == 30)
        #expect(AIErrorMapping.retryAfter(["retry-after": "2.5"], now: now) == 2.5)
        #expect(AIErrorMapping.retryAfter(["retry-after-ms": "750", "retry-after": "9"], now: now) == 0.75)
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.timeZone = TimeZone(identifier: "GMT")
        date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        #expect(AIErrorMapping.retryAfter(["retry-after": date.string(from: now.addingTimeInterval(45))], now: now) == 45)
        #expect(AIErrorMapping.retryAfter(["retry-after": "soon"], now: now) == nil)
        #expect(AIErrorMapping.retryAfter([:], now: now) == nil)
        #expect(AIErrorMapping.retryAfter(["retry-after": "-3"], now: now) == nil)
    }

    @Test func transportFailures() {
        #expect(AIErrorMapping.transport(CancellationError(), provider: .openai) == .cancelled)
        #expect(AIErrorMapping.transport(URLError(.cancelled), provider: .openai) == .cancelled)
        #expect(AIErrorMapping.transport(URLError(.timedOut), provider: .openai) == .timedOut(.openai))
        guard case .network(.openai, _) = AIErrorMapping.transport(URLError(.notConnectedToInternet), provider: .openai) else {
            Issue.record("not a network error")
            return
        }
        #expect(AIErrorMapping.transport(AIError.tooLarge(.anthropic), provider: .openai) == .tooLarge(.anthropic))
    }

    @Test func alertsSayWhatToDoNext() {
        let errors: [AIError] = [
            .missingKey(.anthropic), .invalidKey(.openai), .permissionDenied(.anthropic, message: nil), .billing(.openai, message: "No credits"),
            .rateLimited(.anthropic, retryAfter: 30), .rateLimited(.openai, retryAfter: nil), .overloaded(.anthropic, retryAfter: 90),
            .server(.anthropic, status: 500, message: nil), .modelNotFound(.openai, model: "gpt-x"), .badRequest(.anthropic, message: "bad"),
            .tooLarge(.openai), .refused(.anthropic, category: "cyber", explanation: nil), .network(.openai, detail: "The Internet connection appears to be offline."),
            .timedOut(.anthropic), .invalidResponse(.openai, detail: "An event wasn't JSON."), .notConfirmed,
        ]
        for error in errors {
            #expect(!error.title.isEmpty && !error.message.isEmpty, "\(error)")
            #expect(!error.title.hasSuffix("."), "\(error.title)")
            #expect(!error.message.contains("Please"), "\(error.message)")
            #expect(!error.title.hasPrefix("Error"), "\(error.title)")
            if error.opensSettings { #expect(error.message.contains("Settings ▸ AI"), "\(error.message)") }
        }
        #expect(AIError.rateLimited(.anthropic, retryAfter: 30).message == "Try again in 30 seconds.")
        #expect(AIError.overloaded(.anthropic, retryAfter: 90).message == "Try again in 2 minutes, or choose another model in Settings ▸ AI.")
        #expect(AIError.missingKey(.openai).title == "No OpenAI key")
        #expect(AIError.billing(.openai, message: "No credits").message.hasPrefix("No credits. "))
        #expect(AIError.rateLimited(.anthropic, retryAfter: nil).isRetryable)
        #expect(!AIError.invalidKey(.anthropic).isRetryable)
    }
}
