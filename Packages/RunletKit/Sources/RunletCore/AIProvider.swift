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

/// How hard a model thinks before it answers (#368; every level, #45): Anthropic's
/// `output_config.effort` and OpenAI's `reasoning.effort`. Each model takes only some levels
/// (`AIModelTraits.effortLevels`), and one it doesn't take is never sent.
public enum AIEffort: String, Sendable, Codable, CaseIterable {
    /// OpenAI's `none`: no reasoning (some models).
    case noReasoning = "none"
    case minimal, low, medium, high, xhigh, max

    public var displayName: String {
        switch self {
        case .noReasoning: "None"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra High"
        case .max: "Max"
        }
    }
}

/// A reasoning level as the user chose it (#45): the model's own default, which sends no
/// parameter at all, or a level. Saved as "default" or the level's API name.
public enum AIEffortChoice: Sendable, Equatable, Hashable, Codable {
    case modelDefault
    case level(AIEffort)

    public var level: AIEffort? {
        if case .level(let level) = self { level } else { nil }
    }

    public var displayName: String { level?.displayName ?? "Default" }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "default" {
            self = .modelDefault
        } else if let level = AIEffort(rawValue: raw) {
            self = .level(level)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown reasoning level \(raw)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(level?.rawValue ?? "default")
    }
}

/// What a model id accepts, so a model the user picks never gets a parameter it rejects with a
/// 400. Unknown ids get none of the optional parameters, or only the levels every model of
/// their family takes.
public enum AIModelTraits {
    /// Anthropic models without `output_config.effort`: Claude 3 and older, Haiku 4.5, Sonnet
    /// 4.5, and the first Claude 4 models (their dated ids, `claude-opus-4-20250514`, start with
    /// `claude-opus-4-2`). Opus 4.5 and every newer model take it.
    private static let anthropicWithoutEffort = [
        "claude-2", "claude-instant", "claude-3", "claude-haiku-4-5", "claude-sonnet-4-5",
        "claude-sonnet-4-0", "claude-sonnet-4-2", "claude-opus-4-0", "claude-opus-4-1", "claude-opus-4-2",
    ]

    /// Anthropic's effort levels by model (#45), from Anthropic's per-model table (October
    /// 2026): every level from `low` to `max` on Claude Fable 5 and 5.1, Opus 5.5, 5, 4.8, and
    /// 4.7, Sonnet 5.5 and 5, and Haiku 5.5; no `xhigh` on Opus 4.6 and Sonnet 4.6; and only
    /// `low` to `high` on Opus 4.5. Opus 5.5 and Haiku 5.5 default to `medium`, the others to
    /// `high`. An unknown newer Claude model gets `low` to `high`, which every model with effort
    /// takes.
    private static let anthropicEffort: [(prefixes: [String], levels: [AIEffort])] = [
        (["claude-fable-5", "claude-mythos-5", "claude-opus-5", "claude-sonnet-5", "claude-haiku-5", "claude-opus-4-8", "claude-opus-4-7"],
         [.low, .medium, .high, .xhigh, .max]),
        (["claude-opus-4-6", "claude-sonnet-4-6"], [.low, .medium, .high, .max]),
        (["claude-opus-4-5"], [.low, .medium, .high]),
    ]

    /// OpenAI's `reasoning.effort` levels by model (#45), from OpenAI's model pages (October
    /// 2026): GPT-6 Astra and GPT-6.1 Sol take `low` to `max`, GPT-6 Luna also `none`, GPT-5.5
    /// `none` to `xhigh`, GPT-5.1 `none` to `high`, and GPT-5 `minimal` to `high`. Other
    /// reasoning models (the o-series, newer GPT-5 and GPT-6 models) get `low` to `high`.
    private static let openAIEffort: [(matches: @Sendable (String) -> Bool, levels: [AIEffort])] = [
        ({ $0.hasPrefix("gpt-6-astra") || $0.hasPrefix("gpt-6.1-sol") || $0.hasPrefix("gpt-6-sol") }, [.low, .medium, .high, .xhigh, .max]),
        ({ $0.hasPrefix("gpt-6-luna") }, [.noReasoning, .low, .medium, .high, .xhigh, .max]),
        ({ $0.hasPrefix("gpt-5.5") }, [.noReasoning, .low, .medium, .high, .xhigh]),
        ({ $0.hasPrefix("gpt-5.1") }, [.noReasoning, .low, .medium, .high]),
        ({ $0 == "gpt-5" || $0.hasPrefix("gpt-5-") }, [.minimal, .low, .medium, .high]),
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

    /// The reasoning levels a model takes, lowest first (#45); empty when it takes none.
    public static func effortLevels(_ provider: AIProvider, _ model: String) -> [AIEffort] {
        switch provider {
        case .anthropic:
            guard anthropicTakesEffort(model) else { return [] }
            return anthropicEffort.first { $0.prefixes.contains(where: model.hasPrefix) }?.levels ?? [.low, .medium, .high]
        case .openai:
            guard openAITakesReasoningEffort(model) else { return [] }
            return openAIEffort.first { $0.matches(model) }?.levels ?? [.low, .medium, .high]
        }
    }

    /// The level a request sends for a choice (#45): the chosen level when the model takes it;
    /// nil (the model's own default, nothing sent) for Default, or a level it doesn't take.
    public static func effort(_ choice: AIEffortChoice, _ provider: AIProvider, _ model: String) -> AIEffort? {
        guard let level = choice.level, effortLevels(provider, model).contains(level) else { return nil }
        return level
    }

    /// How many tokens a model reads at once, its context window (#45), from the providers'
    /// model pages (October 2026): 1M for Claude Fable 5 and 5.1, Opus 4.6 and newer, Sonnet 4.6
    /// and newer, and Haiku 5.5; 200K for older Claude models and unknown ones. 1.05M for
    /// OpenAI's GPT-6 models, 400K for GPT-5, about 1M for GPT-4.1, 200K for the o-series, and
    /// 128K for anything else.
    public static func contextTokens(_ provider: AIProvider, _ model: String) -> Int {
        switch provider {
        case .anthropic:
            let million = ["claude-fable-5", "claude-mythos-5", "claude-opus-5", "claude-sonnet-5", "claude-haiku-5",
                           "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-sonnet-4-6"]
            return million.contains(where: model.hasPrefix) ? 1_000_000 : 200_000
        case .openai:
            if model.hasPrefix("gpt-6") { return 1_050_000 }
            if model.hasPrefix("gpt-5") { return 400_000 }
            if model.hasPrefix("gpt-4.1") { return 1_047_576 }
            if isOSeries(model) { return 200_000 }
            return 128_000
        }
    }

    /// A rough, cautious count of the tokens text takes: a token for every three characters
    /// (English and code run three to four). Used only to warn before a request is too long.
    public static func estimatedTokens(characters: Int) -> Int {
        (characters + 2) / 3
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
