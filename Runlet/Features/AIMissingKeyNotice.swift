import RunletCore
import SwiftUI

/// What an AI feature shows when the provider Settings ▸ AI chose has no key (#368, #45): an
/// orange callout that says so, where keys live, and Open AI Settings…, which opens Settings on
/// its AI tab and leaves the feature where it is, so it can send once a key is saved.
struct AIMissingKeyNotice: View {
    @Environment(AppModel.self) private var model
    let provider: AIProvider
    /// The feature's identifier prefix: `<prefix>-no-key` and `<prefix>-open-settings`.
    let identifier: String
    /// The text above the button, for a narrow pane.
    var compact = false
    var window: WindowModel?

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        symbol
                        message
                    }
                    button
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    symbol
                    message
                    Spacer(minLength: 8)
                    button
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(identifier)-no-key")
    }

    private var symbol: some View {
        Image(systemName: "key.slash").foregroundStyle(.orange)
    }

    private var message: some View {
        Text("No \(provider.displayName) key is saved. Add one in Settings ▸ AI; Runlet keeps it in your Mac's Keychain.")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var button: some View {
        Button("Open AI Settings…") { model.perform("app.aiSettings", source: .button, in: window) }
            .controlSize(.small)
            .accessibilityIdentifier("\(identifier)-open-settings")
    }
}
