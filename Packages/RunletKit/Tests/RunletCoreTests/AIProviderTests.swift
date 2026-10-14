import Foundation
import Testing
@testable import RunletCore

/// #368: the providers, what each model accepts, the masked key, and where keys are kept. No
/// test here makes a network call or uses a real key.
struct AIProviderTests {
    @Test func providersHaveDefaultsAndSeparateKeychainItems() {
        #expect(AIProvider.anthropic.defaultModel == "claude-opus-5-5")
        #expect(AIProvider.openai.defaultModel == "gpt-6-astra")
        #expect(AIProvider.anthropic.defaultBaseURL.absoluteString == "https://api.anthropic.com")
        #expect(AIProvider.openai.defaultBaseURL.absoluteString == "https://api.openai.com")
        #expect(AIProvider.anthropic.keychainAccount != AIProvider.openai.keychainAccount)
        for provider in AIProvider.allCases {
            #expect(provider.suggestedModels.first?.id == provider.defaultModel)
            #expect(provider.keysPageURL.scheme == "https")
        }
    }

    @Test func effortGoesOnlyToModelsThatTakeIt() {
        for model in ["claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1", "claude-opus-4-8", "claude-opus-4-5", "claude-sonnet-4-6", "claude-opus-6"] {
            #expect(AIModelTraits.anthropicTakesEffort(model), "\(model)")
        }
        for model in ["claude-haiku-4-5", "claude-haiku-4-5-20251001", "claude-sonnet-4-5", "claude-sonnet-4-20250514", "claude-opus-4-1", "claude-opus-4-20250514", "claude-3-haiku-20240307", "gpt-6-astra"] {
            #expect(!AIModelTraits.anthropicTakesEffort(model), "\(model)")
        }
        for model in ["gpt-6-astra", "gpt-6.1-sol", "gpt-6-luna", "gpt-5", "gpt-5.5", "o3", "o4-mini"] {
            #expect(AIModelTraits.openAITakesReasoningEffort(model), "\(model)")
        }
        for model in ["gpt-4.1", "gpt-4o", "gpt-5-chat-latest", "omni-moderation-latest", "claude-opus-5-5"] {
            #expect(!AIModelTraits.openAITakesReasoningEffort(model), "\(model)")
        }
    }

    @Test func defaultFallbacksOnlyForModelsWithClassifiers() {
        for model in ["claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5", "claude-fable-5-1"] {
            #expect(AIModelTraits.anthropicTakesDefaultFallbacks(model), "\(model)")
        }
        // Claude Haiku 5.5 rejects a fallbacks list; older models have no classifiers to fall back from.
        for model in ["claude-haiku-5-5", "claude-opus-4-8", "claude-sonnet-5", "claude-opus-6"] {
            #expect(!AIModelTraits.anthropicTakesDefaultFallbacks(model), "\(model)")
        }
    }

    @Test func savedKeysShowOnlyTheirPrefixAndLastFourCharacters() {
        #expect(AIKeyMask.mask("sk-ant-api03-EXAMPLE-not-a-real-key-Q2c4") == "sk-ant-…Q2c4")
        #expect(AIKeyMask.mask("sk-proj-EXAMPLEEXAMPLEEXAMPLE9xYz") == "sk-proj-…9xYz")
        #expect(AIKeyMask.mask("sk-EXAMPLEEXAMPLEEXAMPLEab12") == "sk-…ab12")
        #expect(AIKeyMask.mask("  sk-ant-api03-EXAMPLE-not-a-real-key-Q2c4\n") == "sk-ant-…Q2c4")
        #expect(AIKeyMask.mask("EXAMPLEEXAMPLEEXAMPLE7777") == "…7777")
        // Short keys show nothing of themselves.
        #expect(AIKeyMask.mask("sk-short") == "••••")
        #expect(AIKeyMask.mask("") == "••••")
    }

    @Test func theKeychainLabelCarriesTheMaskedKey() {
        let label = AIKeyLabel.make(.anthropic, masked: "sk-ant-…Q2c4")
        #expect(label == "Runlet AI key: Anthropic (sk-ant-…Q2c4)")
        #expect(AIKeyLabel.masked(from: label) == "sk-ant-…Q2c4")
        #expect(AIKeyLabel.masked(from: "Runlet AI key: OpenAI") == nil)
        #expect(AIKeyLabel.masked(from: nil) == nil)
        #expect(AIKeyLabel.masked(from: "Runlet AI key: OpenAI ()") == nil)
    }

    @Test func aiKeysHaveTheirOwnKeychainService() {
        let standard = AppPaths(root: URL(fileURLWithPath: "/Users/someone/Library/Application Support/Runlet"))
        #expect(KeychainCredentialStore.service(for: standard, standard: standard, base: KeychainCredentialStore.aiBaseService) == "dev.runlet.Runlet.ai")
        let scratch = KeychainCredentialStore.service(for: AppPaths(root: URL(fileURLWithPath: "/private/tmp/runlet-ai")), standard: standard, base: KeychainCredentialStore.aiBaseService)
        #expect(scratch.hasPrefix("dev.runlet.Runlet.ai."))
        #expect(scratch != KeychainCredentialStore.service(for: AppPaths(root: URL(fileURLWithPath: "/private/tmp/runlet-ai")), standard: standard))
    }

    @Test func theMemoryStoreKeepsLabels() throws {
        let store = InMemoryCredentialStore()
        let account = AIProvider.openai.keychainAccount
        #expect((store as CredentialStore).label(account) == nil)
        try store.set(SensitiveString("sk-proj-EXAMPLEEXAMPLEEXAMPLE9xYz"), for: account, label: AIKeyLabel.make(.openai, masked: "sk-proj-…9xYz"))
        #expect(AIKeyLabel.masked(from: (store as CredentialStore).label(account)) == "sk-proj-…9xYz")
        try store.delete(account)
        #expect((store as CredentialStore).label(account) == nil)
    }

    /// The real Keychain, under a test-only service, only with RUNLET_TEST_KEYCHAIN=1 (it writes
    /// to the login keychain, then deletes what it wrote). Never part of a normal test run.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUNLET_TEST_KEYCHAIN"] == "1", "set RUNLET_TEST_KEYCHAIN=1 to use the login keychain"))
    func keychainKeepsAKeyAndItsLabel() throws {
        let store = KeychainCredentialStore(service: "dev.runlet.Runlet.ai.tests-\(UUID().uuidString.prefix(8))", comment: KeychainCredentialStore.aiComment, noun: "API key")
        let account = AIProvider.anthropic.keychainAccount
        defer { try? store.delete(account) }
        let key = "sk-ant-api03-EXAMPLE-not-a-real-key-Q2c4"
        try store.set(SensitiveString(key), for: account, label: AIKeyLabel.make(.anthropic, masked: AIKeyMask.mask(key)))
        #expect(store.exists(account))
        #expect(AIKeyLabel.masked(from: store.label(account)) == "sk-ant-…Q2c4")
        #expect(try store.read(account)?.revealed() == key)
        try store.delete(account)
        #expect(!store.exists(account))
        #expect(store.label(account) == nil)
    }

    @Test func settingsKeepTheProviderAndModelsAndOlderFilesLoad() throws {
        var settings = AppSettings()
        #expect(settings.aiProvider == .anthropic)
        #expect(settings.aiModel(for: .anthropic) == "claude-opus-5-5")
        #expect(settings.aiModel(for: .openai) == "gpt-6-astra")
        settings.aiProvider = .openai
        settings.setAIModel("gpt-6.1-sol", for: .openai)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.aiProvider == .openai)
        #expect(decoded.aiModel(for: .openai) == "gpt-6.1-sol")
        // No key ever goes into the settings.
        #expect(!String(decoding: data, as: UTF8.self).contains("sk-"))

        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"fontSize": 14}"#.utf8))
        #expect(old.aiProvider == .anthropic)
        #expect(old.aiModel(for: .anthropic) == "claude-opus-5-5")
        let odd = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"aiProvider": "gemini", "aiAnthropicModel": "", "aiOpenAIModel": 3}"#.utf8))
        #expect(odd.aiProvider == .anthropic)
        #expect(odd.aiModel(for: .anthropic) == "claude-opus-5-5")
        #expect(odd.aiModel(for: .openai) == "gpt-6-astra")
    }
}
