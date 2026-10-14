import AppKit
import RunletCore
import SwiftUI

/// Settings ▸ AI (#368): the provider AI features send to, an API key per provider (saved in
/// the Keychain, shown only masked, with Test Key and Remove Key…), a model per provider, and
/// the privacy rules every AI feature follows. Opening the pane sends nothing; only Test Key
/// sends, and only the key.
struct AISettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker(selection: $model.settings.aiProvider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                } label: {
                    Text("Send to")
                    Text("AI features, such as Explain or Fix Error, use this provider and its model below.")
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings-ai-provider")
            } header: {
                Text("Provider")
            }

            ForEach(AIProvider.allCases) { provider in
                AIProviderSection(provider: provider)
            }

            Section {
                rule("hand.raised", "Nothing is sent on its own. Each feature first shows exactly what it would send, with the provider and the model, and sends only when you click Send.")
                rule("key", "Keys stay in your Mac's Keychain, never in Runlet's files, and aren't shown again after you save them.")
                rule("play.slash", "Runlet never runs code a model writes. A proposed fix changes your tab only when you apply it, and Undo puts the code back.")
                rule("creditcard", "Requests go straight from this Mac to the provider, with your key, and are billed to your account.")
            } header: {
                Text("Privacy")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshAIKeyStates() }
        .accessibilityIdentifier("settings-ai")
    }

    private func rule(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
    }
}

/// One provider's key, its test, and its model.
private struct AIProviderSection: View {
    @Environment(AppModel.self) private var model
    let provider: AIProvider
    @State private var confirmRemove = false

    var body: some View {
        let state = model.ai.keyState(provider)
        Section {
            LabeledContent("API key") {
                if case .saved(let masked) = state {
                    HStack(spacing: 8) {
                        Text(masked ?? "Saved")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .help("Saved in your Mac's Keychain. Runlet doesn't show the whole key again.")
                            .accessibilityIdentifier("settings-ai-masked-key-\(provider.rawValue)")
                        Button("Test Key") { model.testAIKey(provider) }
                            .disabled(model.ai.testState(provider) == .testing)
                            .help("Test Key: ask \(provider.displayName) which models this key can use. Sends the key and nothing else.")
                            .accessibilityIdentifier("settings-ai-test-key-\(provider.rawValue)")
                        Button("Remove Key…", role: .destructive) { confirmRemove = true }
                            .accessibilityIdentifier("settings-ai-remove-key-\(provider.rawValue)")
                    }
                } else {
                    HStack(spacing: 8) {
                        SecureField(provider.keyPlaceholder, text: draft)
                            .frame(maxWidth: 260)
                            .onSubmit { model.saveAIKey(provider) }
                            .accessibilityIdentifier("settings-ai-key-\(provider.rawValue)")
                        Button("Save Key") { model.saveAIKey(provider) }
                            .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("settings-ai-save-key-\(provider.rawValue)")
                    }
                }
            }
            if let error = model.ai.keyErrors[provider] {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            testStatus
            Picker(selection: modelBinding) {
                ForEach(model.aiModelChoices(provider)) { info in
                    Text(info.displayName == info.id ? info.id : "\(info.displayName) (\(info.id))").tag(info.id)
                }
            } label: {
                Text("Model")
                Text(model.ai.models[provider] == nil
                     ? "Test Key lists the models your key can use. \(provider.suggestedModels.first?.displayName ?? provider.defaultModel) is the default."
                     : "The models your key can use, newest first.")
            }
            .accessibilityIdentifier("settings-ai-model-\(provider.rawValue)")
            if model.aiModelUnlisted(provider) {
                Label("Your \(provider.displayName) account doesn't list this model. Choose one it lists.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("settings-ai-model-unlisted-\(provider.rawValue)")
            }
        } header: {
            Text(provider.displayName)
        } footer: {
            HStack(spacing: 4) {
                Text(state.isSaved ? "Requests use this key and are billed to your \(provider.displayName) account." : "You need an API key from your \(provider.displayName) account.")
                Link("Get an API Key", destination: provider.keysPageURL)
                    .accessibilityIdentifier("settings-ai-get-key-\(provider.rawValue)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .confirmationDialog("Remove the \(provider.displayName) key?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Key", role: .destructive) { model.removeAIKey(provider) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Runlet deletes it from your Mac's Keychain. The key itself keeps working at \(provider.displayName) until you revoke it there.")
        }
    }

    @ViewBuilder
    private var testStatus: some View {
        switch model.ai.testState(provider) {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing the key…").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("settings-ai-key-status-\(provider.rawValue)")
        case .succeeded(let count):
            Label("The key works. Your account lists \(count == 1 ? "1 model" : "\(count) models").", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .accessibilityIdentifier("settings-ai-key-status-\(provider.rawValue)")
        case .failed(let title, let message):
            Label("\(title). \(message)", systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-ai-key-status-\(provider.rawValue)")
        }
    }

    private var draft: Binding<String> {
        Binding(get: { model.ai.drafts[provider] ?? "" }, set: { model.ai.drafts[provider] = $0 })
    }

    private var modelBinding: Binding<String> {
        Binding(get: { model.settings.aiModel(for: provider) }, set: { model.settings.setAIModel($0, for: provider) })
    }
}
