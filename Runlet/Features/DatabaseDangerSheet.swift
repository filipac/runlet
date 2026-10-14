import RunletCore
import SwiftUI

/// The dangerous-operation confirmation of database tabs (`DatabaseDangerConfirmation`): Redis's
/// dangerous commands (#190) and Kill Client, MongoDB's destructive operations (#191, #220) and
/// Kill Op (#207). It names the action, the connection and what it acts on, and each dangerous
/// line with what it does. It shows on every connection, production or not; production asks
/// again after it. #367: a risky confirmation's keys, as `ProductionConfirmationSheet` has them:
/// Return alone cancels, ⌘Return confirms, Esc cancels, and the confirm button is red.
struct DatabaseDangerSheet: View {
    let confirmation: DatabaseDangerConfirmation
    var confirm: () -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text(confirmation.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(confirmation.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(confirmation.items, id: \.self) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.sentence)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(item.text)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.07)))
                }
            }
            HStack {
                Text("⌘↩ confirms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // ↩ alone cancels: the safe choice is the default.
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("\(confirmation.identifier)-cancel")
                // A red title, as macOS draws an alert's destructive button: a tint alone leaves a
                // bordered button grey, and a prominent one turns grey in a window that isn't active.
                Button(role: .destructive, action: confirm) {
                    Text(confirmation.confirmTitle).foregroundStyle(.red)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("\(confirmation.identifier)-confirm")
            }
        }
        .padding(20)
        .frame(width: 520)
        .onExitCommand(perform: cancel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(confirmation.identifier)
    }
}
