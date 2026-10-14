import Foundation

// AI providers (#368): Anthropic's Messages API and OpenAI's Responses API, reached over plain
// HTTPS with the user's own API key (there is no official Anthropic SDK for Swift). This file
// holds what each provider is; `AIEndpoint` builds requests, `AIStreamDecoder` reads answers,
// `AIErrorMapping` turns failures into `AIError`, and `AIClient` sends what the user confirmed
// (`AIDisclosure`, `AIConsent`). Nothing here runs code, and nothing is sent on its own.

/// An AI provider Runlet's AI features can use (Settings ▸ AI, #368). Apple's on-device models
/// and other providers are later work.
public enum AIProvider: String, Sendable, Codable, CaseIterable, Identifiable {
    case anthropic
    case openai

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        }
    }

    /// The model a provider starts with, until the user picks another in Settings ▸ AI. Each is
    /// the provider's own recommended starting point in October 2026: Claude Opus 5.5 (the
    /// current Opus), and GPT-6 Astra ("If you're not sure where to start" in OpenAI's model
    /// guide). Cheaper models are a choice in Settings, never a silent downgrade.
    public var defaultModel: String {
        switch self {
        case .anthropic: "claude-opus-5-5"
        case .openai: "gpt-6-astra"
        }
    }

    /// The provider's API. Debug builds can point both providers at a local stub instead
    /// (`RUNLET_AI_BASE_URL`, in the app); release builds always use these.
    public var defaultBaseURL: URL {
        switch self {
        case .anthropic: URL(string: "https://api.anthropic.com")!
        case .openai: URL(string: "https://api.openai.com")!
        }
    }

    /// Where the user creates an API key, linked from Settings ▸ AI.
    public var keysPageURL: URL {
        switch self {
        case .anthropic: URL(string: "https://platform.claude.com/settings/keys")!
        case .openai: URL(string: "https://platform.openai.com/api-keys")!
        }
    }

    /// The key field's placeholder.
    public var keyPlaceholder: String {
        switch self {
        case .anthropic: "sk-ant-…"
        case .openai: "sk-…"
        }
    }

    /// The models Settings ▸ AI offers before Test Key has read the account's own list.
    public var suggestedModels: [AIModelInfo] {
        switch self {
        case .anthropic:
            [AIModelInfo(id: "claude-opus-5-5", displayName: "Claude Opus 5.5"),
             AIModelInfo(id: "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5"),
             AIModelInfo(id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5"),
             AIModelInfo(id: "claude-fable-5-1", displayName: "Claude Fable 5.1")]
        case .openai:
            [AIModelInfo(id: "gpt-6-astra", displayName: "GPT-6 Astra"),
             AIModelInfo(id: "gpt-6.1-sol", displayName: "GPT-6.1 Sol"),
             AIModelInfo(id: "gpt-6-luna", displayName: "GPT-6 Luna")]
        }
    }

    /// The provider's item in the AI keys' Keychain service: one fixed account per provider.
    public var keychainAccount: UUID {
        switch self {
        case .anthropic: UUID(uuidString: "A1A1A1A1-0368-4A1A-8A1A-000000000001")!
        case .openai: UUID(uuidString: "A1A1A1A1-0368-4A1A-8A1A-000000000002")!
        }
    }
}

/// A model a provider offers, as Settings ▸ AI lists it.
public struct AIModelInfo: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var id: String
    public var displayName: String

    public init(id: String, displayName: String? = nil) {
        self.id = id
        self.displayName = displayName ?? id
    }
}

/// How hard a model thinks before it answers. Sent only to models that take it
/// (`AIModelTraits`); nil leaves the model's own default.
public enum AIEffort: String, Sendable, Codable, CaseIterable {
    case low, medium, high
}

/// What a model id accepts, so a model the user picks never gets a parameter it rejects with a
/// 400. Unknown ids get none of the optional parameters.
public enum AIModelTraits {
    /// Anthropic models without `output_config.effort`: Claude 3 and older, Haiku 4.5, Sonnet
    /// 4.5, and the first Claude 4 models (their dated ids, `claude-opus-4-20250514`, start with
    /// `claude-opus-4-2`). Opus 4.5 and every newer model take it.
    private static let anthropicWithoutEffort = [
        "claude-2", "claude-instant", "claude-3", "claude-haiku-4-5", "claude-sonnet-4-5",
        "claude-sonnet-4-0", "claude-sonnet-4-2", "claude-opus-4-0", "claude-opus-4-1", "claude-opus-4-2",
    ]

    /// Anthropic models whose safety classifiers can decline a request, and that accept the
    /// server-side `fallbacks: "default"` (beta `server-side-fallback-2026-07-01`): the API
    /// then re-runs a declined request on the model Anthropic recommends for that category,
    /// instead of returning the refusal.
    private static let anthropicDefaultFallbacks: Set<String> = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]

    public static func anthropicTakesEffort(_ model: String) -> Bool {
        model.hasPrefix("claude-") && !anthropicWithoutEffort.contains { model.hasPrefix($0) }
    }

    public static func anthropicTakesDefaultFallbacks(_ model: String) -> Bool {
        anthropicDefaultFallbacks.contains(model)
    }

    /// OpenAI's reasoning models (`reasoning.effort`): the o-series and GPT-5 and later, but not
    /// their chat variants.
    public static func openAITakesReasoningEffort(_ model: String) -> Bool {
        guard !model.contains("-chat") else { return false }
        if model.hasPrefix("gpt-") {
            let major = model.dropFirst(4).prefix { $0.isNumber }
            return (Int(major) ?? 0) >= 5
        }
        return isOSeries(model)
    }

    /// `o1`, `o3-mini`, `o4-mini`: an "o" and a digit.
    static func isOSeries(_ model: String) -> Bool {
        guard model.hasPrefix("o"), model.count > 1 else { return false }
        return model[model.index(after: model.startIndex)].isNumber
    }
}

/// How a saved key is shown after it's saved (#368): never in full. The provider's prefix and
/// the last four characters, "sk-ant-…Q2c4"; a short key shows only dots.
public enum AIKeyMask {
    public static func mask(_ key: String) -> String {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 16 else { return "••••" }
        return prefix(of: key) + "…" + key.suffix(4)
    }

    /// "sk-ant-", "sk-proj-", "sk-": up to the second dash within the first 8 characters, or
    /// the first within the first 4.
    static func prefix(of key: String) -> String {
        let head = Array(key.prefix(8))
        let dashes = head.indices.filter { head[$0] == "-" }
        if dashes.count >= 2 { return String(head[...dashes[1]]) }
        if let first = dashes.first, first < 4 { return String(head[...first]) }
        return ""
    }
}

/// The Keychain item's label for a provider's key: "Runlet AI key: Anthropic (sk-ant-…Q2c4)".
/// Settings ▸ AI reads the masked form back from the label, which macOS gives without asking
/// for the key itself.
public enum AIKeyLabel {
    public static func make(_ provider: AIProvider, masked: String) -> String {
        "Runlet AI key: \(provider.displayName) (\(masked))"
    }

    public static func masked(from label: String?) -> String? {
        guard let label, label.hasSuffix(")"), let open = label.lastIndex(of: "(") else { return nil }
        let inner = label[label.index(after: open)..<label.index(before: label.endIndex)]
        return inner.isEmpty ? nil : String(inner)
    }
}
