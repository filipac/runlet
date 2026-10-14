import Foundation
import Testing
@testable import RunletCore

/// #45: reasoning levels (Anthropic's `output_config.effort`, OpenAI's `reasoning.effort`): only
/// the levels each model takes, Default sending nothing, the settings that hold them, and each
/// model's context window.
struct AIReasoningTests {
    static func body(_ provider: AIProvider, _ model: String, _ effort: AIEffort?) throws -> [String: Any] {
        let request = AIRequest(provider: provider, model: model, instructions: "Help.", messages: [AIMessage(.user, "Hi")],
                                maxOutputTokens: 16_000, effort: effort)
        return try #require(JSONSerialization.jsonObject(with: AIEndpoint.body(request)) as? [String: Any])
    }

    static func sent(_ provider: AIProvider, _ model: String, _ effort: AIEffort?) throws -> String? {
        let body = try Self.body(provider, model, effort)
        let container = body[provider == .anthropic ? "output_config" : "reasoning"] as? [String: Any]
        return container?["effort"] as? String
    }

    @Test func eachModelTakesItsOwnLevels() {
        let all: [AIEffort] = [.low, .medium, .high, .xhigh, .max]
        for model in ["claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5", "claude-sonnet-5", "claude-haiku-5-5", "claude-fable-5-1", "claude-opus-4-8", "claude-opus-4-7"] {
            #expect(AIModelTraits.effortLevels(.anthropic, model) == all, "\(model)")
        }
        #expect(AIModelTraits.effortLevels(.anthropic, "claude-opus-4-6") == [.low, .medium, .high, .max])
        #expect(AIModelTraits.effortLevels(.anthropic, "claude-sonnet-4-6") == [.low, .medium, .high, .max])
        #expect(AIModelTraits.effortLevels(.anthropic, "claude-opus-4-5") == [.low, .medium, .high])
        #expect(AIModelTraits.effortLevels(.anthropic, "claude-opus-6") == [.low, .medium, .high])
        for model in ["claude-haiku-4-5", "claude-sonnet-4-5", "claude-3-haiku-20240307", "gpt-6-astra"] {
            #expect(AIModelTraits.effortLevels(.anthropic, model).isEmpty, "\(model)")
        }
        #expect(AIModelTraits.effortLevels(.openai, "gpt-6-astra") == all)
        #expect(AIModelTraits.effortLevels(.openai, "gpt-6.1-sol") == all)
        #expect(AIModelTraits.effortLevels(.openai, "gpt-6-luna") == [.noReasoning] + all)
        #expect(AIModelTraits.effortLevels(.openai, "gpt-5.5") == [.noReasoning, .low, .medium, .high, .xhigh])
        #expect(AIModelTraits.effortLevels(.openai, "gpt-5.1") == [.noReasoning, .low, .medium, .high])
        #expect(AIModelTraits.effortLevels(.openai, "gpt-5") == [.minimal, .low, .medium, .high])
        #expect(AIModelTraits.effortLevels(.openai, "gpt-5-mini") == [.minimal, .low, .medium, .high])
        #expect(AIModelTraits.effortLevels(.openai, "o3") == [.low, .medium, .high])
        for model in ["gpt-4.1", "gpt-4o", "gpt-5-chat-latest", "claude-opus-5-5"] {
            #expect(AIModelTraits.effortLevels(.openai, model).isEmpty, "\(model)")
        }
    }

    @Test func defaultSendsNothingAndUnsupportedLevelsAreNeverSent() throws {
        #expect(AIModelTraits.effort(.modelDefault, .anthropic, "claude-opus-5-5") == nil)
        #expect(AIModelTraits.effort(.level(.xhigh), .anthropic, "claude-opus-5-5") == .xhigh)
        #expect(AIModelTraits.effort(.level(.xhigh), .anthropic, "claude-opus-4-6") == nil)
        #expect(AIModelTraits.effort(.level(.high), .anthropic, "claude-haiku-4-5") == nil)
        #expect(AIModelTraits.effort(.level(.noReasoning), .openai, "gpt-6-luna") == .noReasoning)
        #expect(AIModelTraits.effort(.level(.noReasoning), .openai, "gpt-6-astra") == nil)

        // Request bodies: Anthropic's output_config.effort, OpenAI's reasoning.effort.
        #expect(try Self.sent(.anthropic, "claude-opus-5-5", .xhigh) == "xhigh")
        #expect(try Self.sent(.anthropic, "claude-opus-5-5", .max) == "max")
        #expect(try Self.sent(.anthropic, "claude-opus-5-5", nil) == nil)
        #expect(try Self.body(.anthropic, "claude-opus-5-5", nil)["output_config"] == nil)
        #expect(try Self.sent(.anthropic, "claude-opus-4-6", .xhigh) == nil)
        #expect(try Self.sent(.anthropic, "claude-opus-4-6", .max) == "max")
        #expect(try Self.sent(.anthropic, "claude-haiku-4-5", .low) == nil)
        #expect(try Self.sent(.anthropic, "claude-opus-5-5", .noReasoning) == nil)
        #expect(try Self.sent(.openai, "gpt-6-astra", .max) == "max")
        #expect(try Self.sent(.openai, "gpt-6-astra", .noReasoning) == nil)
        #expect(try Self.sent(.openai, "gpt-6-luna", .noReasoning) == "none")
        #expect(try Self.sent(.openai, "gpt-5", .minimal) == "minimal")
        #expect(try Self.sent(.openai, "gpt-5.1", .xhigh) == nil)
        #expect(try Self.sent(.openai, "gpt-4o", .high) == nil)
        #expect(try Self.body(.openai, "gpt-4o", .high)["reasoning"] == nil)
    }

    @Test func settingsHoldADefaultPerProviderAndTheChatsOwn() throws {
        var settings = AppSettings()
        #expect(settings.aiEffort(for: .anthropic) == .modelDefault && settings.aiEffort(for: .openai) == .modelDefault)
        #expect(settings.aiChatEffort(for: .openai) == .modelDefault)
        settings.setAIEffort(.level(.high), for: .anthropic)
        #expect(settings.aiChatEffort(for: .anthropic) == .level(.high))
        settings.setAIChatEffort(.level(.max), for: .anthropic)
        settings.setAIChatEffort(.modelDefault, for: .openai)
        settings.setAIEffort(.level(.low), for: .openai)
        #expect(settings.aiChatEffort(for: .anthropic) == .level(.max))
        #expect(settings.aiChatEffort(for: .openai) == .modelDefault)
        let data = try JSONEncoder().encode(settings)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""aiAnthropicEffort":"high""#) && text.contains(#""aiChatOpenAIEffort":"default""#))
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.aiEffort(for: .anthropic) == .level(.high))
        #expect(decoded.aiChatEffort(for: .anthropic) == .level(.max))
        #expect(decoded.aiChatEffort(for: .openai) == .modelDefault)
        // Older files and unknown levels: the model's default.
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"aiProvider": "anthropic"}"#.utf8))
        #expect(old.aiEffort(for: .anthropic) == .modelDefault && old.aiChatEffort(for: .anthropic) == .modelDefault)
        let odd = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"aiAnthropicEffort": "turbo", "aiOpenAIEffort": 3, "aiChatAnthropicEffort": "ultra"}"#.utf8))
        #expect(odd.aiEffort(for: .anthropic) == .modelDefault && odd.aiEffort(for: .openai) == .modelDefault)
        #expect(odd.aiChatAnthropicEffort == nil)
    }

    @Test func theChatSendsItsLevelAndNamesIt() {
        var settings = AppSettings()
        settings.setAIChatEffort(.level(.high), for: .anthropic)
        let destination = AIChatDestination.resolve(settings, configured: [.anthropic])
        #expect(destination?.effort == .high)
        #expect(destination?.effortLevels == [.low, .medium, .high, .xhigh, .max])
        let draft = AIChatPrompt.draft(provider: .anthropic, model: "claude-opus-5-5", effort: destination?.effort, configured: [.anthropic],
                                       conversation: AIChatConversation(), message: "Hi", editor: nil, output: nil, files: [], choice: AIChatContextChoice())
        #expect(draft.disclosure.effort == .high)
        #expect(draft.disclosure.request(stream: true).effort == .high)
        // The consent covers the level: another level is another request.
        var other = draft.disclosure
        other.effort = .low
        #expect(!AIConsent(approving: draft.disclosure).covers(other))
        #expect(AIChatDestination.label(model: "claude-opus-5-5", provider: .anthropic, effort: .high) == "claude-opus-5-5 · effort high")
        #expect(AIChatDestination.label(model: "gpt-6-astra", provider: .openai, effort: nil) == "gpt-6-astra · default effort")
        #expect(AIChatDestination.label(model: "gpt-4o", provider: .openai, effort: nil) == "gpt-4o")
        // A level the model doesn't take is dropped from the disclosure, not sent.
        let older = AIChatPrompt.draft(provider: .anthropic, model: "claude-opus-4-6", effort: .xhigh, configured: [.anthropic],
                                       conversation: AIChatConversation(), message: "Hi", editor: nil, output: nil, files: [], choice: AIChatContextChoice())
        #expect(older.disclosure.effort == nil)
        // Explain or Fix uses Settings ▸ AI's level, when the model takes it.
        let input = ExplainErrorInput(language: .php, error: "E", code: "x")
        #expect(ExplainErrorPrompt.disclosure(input, provider: .anthropic, model: "claude-opus-5-5").effort == nil)
        #expect(ExplainErrorPrompt.disclosure(input, provider: .anthropic, model: "claude-opus-5-5", effort: .xhigh).effort == .xhigh)
        #expect(ExplainErrorPrompt.disclosure(input, provider: .anthropic, model: "claude-haiku-4-5", effort: .high).effort == nil)
    }

    @Test func contextWindows() {
        #expect(AIModelTraits.contextTokens(.anthropic, "claude-opus-5-5") == 1_000_000)
        #expect(AIModelTraits.contextTokens(.anthropic, "claude-sonnet-4-6") == 1_000_000)
        #expect(AIModelTraits.contextTokens(.anthropic, "claude-haiku-4-5") == 200_000)
        #expect(AIModelTraits.contextTokens(.anthropic, "claude-opus-6") == 200_000)
        #expect(AIModelTraits.contextTokens(.openai, "gpt-6-astra") == 1_050_000)
        #expect(AIModelTraits.contextTokens(.openai, "gpt-5") == 400_000)
        #expect(AIModelTraits.contextTokens(.openai, "o3") == 200_000)
        #expect(AIModelTraits.contextTokens(.openai, "gpt-4o") == 128_000)
        #expect(AIModelTraits.estimatedTokens(characters: 300) == 100)
    }
}
