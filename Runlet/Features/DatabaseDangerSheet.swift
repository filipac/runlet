import RunletCore
import SwiftUI

/// The dangerous-operation confirmation of database tabs (`DatabaseDangerConfirmation`): Redis's
/// dangerous commands (#190) and MongoDB's destructive operations (#191). It names the action, the
/// connection and what it acts on, and each dangerous line with what it does. It shows on every
/// connection, production or not; production asks again after it.
struct DatabaseDangerSheet: View {
    let confirmation: DatabaseDangerConfirmation
    var confirm: () -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text(confirmation.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(confirmation.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("\(confirmation.identifier)-cancel")
                Button(confirmation.confirmTitle, role: .destructive, action: confirm)
                    .tint(.red)
                    .accessibilityIdentifier("\(confirmation.identifier)-confirm")
            }
        }
        .padding(20)
        .frame(width: 520)
        .accessibilityIdentifier(confirmation.identifier)
    }
}
