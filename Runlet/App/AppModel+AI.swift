import AppKit
import RunletCore

/// AI providers (#368): Settings ▸ AI's keys, their tests, and the models; the keys' own
/// Keychain store; and the client every AI feature sends through. Keys live only in the
/// Keychain (memory for Debug runs on scratch data): never in `State/*.json`, UserDefaults, the
/// logs, history, or an error message, and the app never shows one again after it's saved.
@MainActor
@Observable
final class AIProviderState {
    enum KeyState: Equatable {
        case missing
        /// Saved; `masked` is "sk-ant-…Q2c4", read from the Keychain item's label.
        case saved(masked: String?)

        var isSaved: Bool { if case .saved = self { true } else { false } }
    }

    enum TestState: Equatable {
        case idle
        case testing
        /// The key works; the account lists this many models.
        case succeeded(models: Int)
        case failed(title: String, message: String)
    }

    var keyStates: [AIProvider: KeyState] = [:]
    var tests: [AIProvider: TestState] = [:]
    /// The models Test Key read, for this session only.
    var models: [AIProvider: [AIModelInfo]] = [:]
    /// What's typed in a key field. Memory only, cleared once saved.
    var drafts: [AIProvider: String] = [:]
    /// A key couldn't be saved or removed (a Keychain error), shown under the field.
    var keyErrors: [AIProvider: String] = [:]

    @ObservationIgnored let keys: CredentialStore
    @ObservationIgnored let client: AIClient
    @ObservationIgnored var testTasks: [AIProvider: Task<Void, Never>] = [:]

    init(keys: CredentialStore, client: AIClient) {
        self.keys = keys
        self.client = client
    }

    func keyState(_ provider: AIProvider) -> KeyState { keyStates[provider] ?? .missing }
    func testState(_ provider: AIProvider) -> TestState { tests[provider] ?? .idle }
}

extension AppModel {
    /// The Keychain, under the AI keys' own service (`dev.runlet.Runlet.ai`); in Debug builds,
    /// memory for scratch data (`RUNLET_DATA_DIR`) unless `RUNLET_CREDENTIALS=keychain`, as for
    /// database passwords, so development runs and screenshots never touch the login keychain.
    static func makeAIKeyStore(paths: AppPaths) -> CredentialStore {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let scratch = !(environment["RUNLET_DATA_DIR"] ?? "").isEmpty
        switch environment["RUNLET_CREDENTIALS"] {
        case "memory":
            return InMemoryCredentialStore()
        case "keychain":
            break
        default:
            if scratch { return InMemoryCredentialStore() }
        }
        #endif
        return KeychainCredentialStore(service: KeychainCredentialStore.service(for: paths, base: KeychainCredentialStore.aiBaseService),
                                       comment: KeychainCredentialStore.aiComment, noun: "API key")
    }

    /// The providers' real APIs. Debug builds only: `RUNLET_AI_BASE_URL` sends both providers'
    /// requests to another base URL instead, such as the local stand-in in
    /// `Tests/Fixtures/ai-stub` (an undocumented hook for checks and screenshots). Release builds
    /// never read it.
    static func makeAIClient() -> AIClient {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["RUNLET_AI_BASE_URL"], let url = URL(string: value), url.scheme != nil {
            return AIClient(baseURLOverride: url)
        }
        #endif
        return AIClient()
    }

    // MARK: Keys

    /// Reads whether each key is saved, and its masked form, from the items' attributes: macOS
    /// doesn't ask for the keys themselves.
    func refreshAIKeyStates() {
        for provider in AIProvider.allCases {
            ai.keyStates[provider] = ai.keys.exists(provider.keychainAccount)
                ? .saved(masked: AIKeyLabel.masked(from: ai.keys.label(provider.keychainAccount)))
                : .missing
        }
    }

    /// Whether a key is saved. Never changes state, so views can ask while they draw.
    func hasAIKey(_ provider: AIProvider) -> Bool {
        ai.keyStates[provider]?.isSaved ?? ai.keys.exists(provider.keychainAccount)
    }

    /// Settings ▸ AI's Save Key: the typed key goes to the Keychain, labelled with its masked
    /// form, and the field empties. Nothing is sent.
    func saveAIKey(_ provider: AIProvider) {
        let key = (ai.drafts[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let masked = AIKeyMask.mask(key)
        do {
            try ai.keys.set(SensitiveString(key), for: provider.keychainAccount, label: AIKeyLabel.make(provider, masked: masked))
            ai.drafts[provider] = nil
            ai.keyErrors[provider] = nil
            ai.keyStates[provider] = .saved(masked: masked)
            ai.tests[provider] = .idle
            ai.models[provider] = nil
        } catch {
            ai.keyErrors[provider] = (error as? CredentialStoreError)?.description ?? error.localizedDescription
        }
    }

    /// Settings ▸ AI's Remove Key…, after its confirmation: the Keychain item goes.
    func removeAIKey(_ provider: AIProvider) {
        ai.testTasks[provider]?.cancel()
        do {
            try ai.keys.delete(provider.keychainAccount)
            ai.keyErrors[provider] = nil
        } catch {
            ai.keyErrors[provider] = (error as? CredentialStoreError)?.description ?? error.localizedDescription
        }
        refreshAIKeyStates()
        ai.tests[provider] = .idle
        ai.models[provider] = nil
    }

    /// The saved key, read off the main thread (macOS may ask first, after an update).
    func readAIKey(_ provider: AIProvider) async throws -> SensitiveString? {
        let store = ai.keys
        let account = provider.keychainAccount
        return try await Task.detached(priority: .userInitiated) { try store.read(account) }.value
    }

    /// Settings ▸ AI's Test Key: lists the account's models with the key, which sends the key
    /// and nothing else. The list replaces the suggested models for this session.
    func testAIKey(_ provider: AIProvider) {
        ai.testTasks[provider]?.cancel()
        ai.tests[provider] = .testing
        ai.testTasks[provider] = Task { [weak self] in
            guard let self else { return }
            do {
                let key = try await self.readAIKey(provider)
                let models = try await self.ai.client.models(provider, key: key)
                guard !Task.isCancelled else { return }
                self.ai.models[provider] = models
                self.ai.tests[provider] = .succeeded(models: models.count)
            } catch let error as CredentialStoreError {
                self.ai.tests[provider] = .failed(title: "Couldn't read the key", message: error.description)
            } catch {
                guard !Task.isCancelled else { return }
                let failure = error as? AIError ?? AIErrorMapping.transport(error, provider: provider)
                if failure == .cancelled { return }
                self.ai.tests[provider] = .failed(title: failure.title, message: failure.message)
            }
        }
    }

    // MARK: Models

    /// The models Settings ▸ AI offers: the account's list once Test Key read it, the suggested
    /// ones before; the chosen model is always among them.
    func aiModelChoices(_ provider: AIProvider) -> [AIModelInfo] {
        var choices = ai.models[provider] ?? provider.suggestedModels
        let current = settings.aiModel(for: provider)
        if !choices.contains(where: { $0.id == current }) {
            let known = provider.suggestedModels.first { $0.id == current }
            choices.insert(known ?? AIModelInfo(id: current), at: 0)
        }
        return choices
    }

    /// The chosen model isn't in the list Test Key read: the account can't use it.
    func aiModelUnlisted(_ provider: AIProvider) -> Bool {
        guard let listed = ai.models[provider] else { return false }
        return !listed.contains { $0.id == settings.aiModel(for: provider) }
    }

    func aiModelName(_ provider: AIProvider, _ id: String) -> String {
        (ai.models[provider] ?? []).first { $0.id == id }?.displayName
            ?? provider.suggestedModels.first { $0.id == id }?.displayName
            ?? id
    }

    // MARK: Settings

    /// Opens Settings on its AI tab (AI Settings…, and Explain or Fix's Open AI Settings…, which
    /// leaves its sheet open: once a key is saved, Send works).
    func showAISettings() {
        SettingsWindow.open(selecting: "AI")
    }

    // MARK: Sending

    /// The one way an AI feature sends (#368): the disclosure the user saw and the consent their
    /// click made. Reads the provider's key, then streams the answer. Errors arrive as
    /// `AIError`s; a Keychain failure as `CredentialStoreError`.
    func streamAI(_ disclosure: AIDisclosure, consent: AIConsent) -> AsyncThrowingStream<AIStreamEvent, Error> {
        let client = ai.client
        let store = ai.keys
        let account = disclosure.provider.keychainAccount
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let key = try store.read(account)
                    for try await event in client.stream(disclosure, consent: consent, key: key) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
