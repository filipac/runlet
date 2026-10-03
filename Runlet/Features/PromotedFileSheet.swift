import SwiftUI

/// After Save as Artisan Command… or Save as Test… (#39): where the file went, what to review,
/// and a way to open it in the external editor or reveal it in Finder. Nothing runs.
struct PromotedFileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let file: PromotedFile

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: file.kind == .artisanCommand ? "terminal" : "checkmark.seal")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Saved \(file.url.lastPathComponent)")
                        .font(.headline)
                    Text("\(file.description) · \(file.relativePath)" + (file.projectName.map { " in \($0)" } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Text(file.nextStep)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if !file.notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label(file.notes.count == 1 ? "One TODO in the file needs a look:" : "\(file.notes.count) TODOs in the file need a look:", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                    ForEach(Array(file.notes.enumerated()), id: \.offset) { _, note in
                        Text(note)
                            .font(.caption)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("promoted-file-notes")
            }
            HStack {
                Button("Reveal in Finder") {
                    model.revealInFinder(path: file.url.path)
                    close()
                }
                .accessibilityIdentifier("promoted-file-reveal")
                Spacer()
                if let editor = model.externalEditorName {
                    Button("Open in \(editor)") {
                        model.openInExternalEditor(path: file.url.path, line: nil)
                        close()
                    }
                    .accessibilityIdentifier("promoted-file-open")
                }
                Button("Done") { close() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("promoted-file-done")
            }
        }
        .padding(20)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("promoted-file-sheet")
    }

    private func close() {
        if model.promotedFile?.id == file.id { model.promotedFile = nil }
        dismiss()
    }
}
