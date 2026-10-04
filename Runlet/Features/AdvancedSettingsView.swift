import RunletCore
import SwiftUI

/// Settings ▸ Advanced (#187): feature flags for hidden or experimental features, all off by
/// default. The tab is hidden until revealed (⌥⌘, or ⌥ while opening Settings) and stays
/// until Hide Advanced Settings.
struct AdvancedSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(FeatureFlag.all) { flag in
                    Toggle(isOn: binding(flag)) {
                        Text(flag.title)
                        Text(detail(flag))
                    }
                    .disabled(model.isForcedOn(flag))
                    .accessibilityIdentifier("settings-flag-\(flag.id)")
                }
            } header: {
                Text("Feature Flags")
            } footer: {
                Text("Hidden and experimental features, all off by default. Turning one off hides it again; nothing it created is removed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                HStack {
                    Text("This tab stays until you hide it. Hold ⌥ while opening Settings (⌥⌘,) to show it again.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Hide Advanced Settings") { model.hideAdvancedSettings() }
                        .accessibilityIdentifier("settings-hide-advanced")
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("settings-advanced")
    }

    private func binding(_ flag: FeatureFlag) -> Binding<Bool> {
        Binding(get: { model.isEnabled(flag) }, set: { model.setFeatureFlag(flag, enabled: $0) })
    }

    private func detail(_ flag: FeatureFlag) -> String {
        var text = flag.summary
        if let issue = flag.issue { text += " (#\(issue))" }
        if model.isForcedOn(flag) { text += " On because RUNLET_FEATURE_FLAGS names it (Debug builds only)." }
        return text
    }
}
