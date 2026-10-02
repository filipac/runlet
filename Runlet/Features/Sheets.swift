import RunletCore
import RunletExecution
import SwiftUI

/// Explicit choice when a profile's container is ambiguous or was recreated without a
/// stable Compose identity. Nothing runs from this sheet.
struct ContainerChoiceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let choice: ContainerChoice
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a container for \(choice.profile.name)").font(.headline)
            Text(choice.reason).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(choice.candidates, selection: $selection) { container in
                VStack(alignment: .leading) {
                    Text(container.name).font(.body.weight(.medium))
                    Text("\(container.shortId) · \(container.image) · \(container.status)").font(.caption).foregroundStyle(.secondary)
                }
                .tag(container.id)
            }
            .frame(minHeight: 120)
            Text("Runlet never switches containers on its own. After choosing, press Run again.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.containerChoice = nil
                    dismiss()
                }
                Button("Use This Container") {
                    if let id = selection, let container = choice.candidates.first(where: { $0.id == id }) {
                        model.confirmContainer(container, for: choice.profile)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { if choice.candidates.count == 1 { selection = choice.candidates[0].id } }
    }
}

struct SnippetDraft: Identifiable {
    let id = UUID()
    var label: String
    var code: String
    var target: TargetRef
    var associate: Bool
}

struct SaveSnippetSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: SnippetDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Snippet").font(.headline)
            TextField("Label", text: $draft.label)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("snippet-label-field")
            Toggle("Associate with \(model.targetLabel(draft.target))", isOn: $draft.associate)
            Text("Associated snippets open in a new tab with that target. The association is always shown in the snippet list.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(draft.code)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 140)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    model.saveSnippet(label: draft.label, code: draft.code, target: draft.associate ? draft.target : nil)
                    model.inspectorPane = .snippets
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("snippet-save-button")
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Per-project PHP executable and language-service PHP version.
struct ProjectSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var project: LocalProject
    @State private var customPHP = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Project Options").font(.headline)
            LabeledContent("Directory") {
                Text(project.path).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            }
            TextField("Name", text: $project.name).textFieldStyle(.roundedBorder)
            PHPPicker(selection: $project.phpExecutable, allowDefault: true)
            TextField("PHP version for completion (blank = infer from composer.json)", text: Binding(
                get: { project.languagePHPVersion ?? "" },
                set: { project.languagePHPVersion = $0.isEmpty ? nil : $0 }
            ))
            .textFieldStyle(.roundedBorder)
            HStack {
                Button("Remove Project", role: .destructive) {
                    model.removeProject(project.id)
                    dismiss()
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    model.saveProject(project)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// Chooses a host PHP executable from discovered installations or a custom path.
struct PHPPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: String?
    var allowDefault: Bool
    @State private var validation: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("PHP", selection: $selection) {
                if allowDefault {
                    Text("Default (\(model.settings.defaultPHPExecutable.flatMap { path in model.phpInstallations.first { $0.path == path }?.version } ?? model.bestPHP?.version ?? "none"))").tag(String?.none)
                } else {
                    Text("Automatic (\(model.bestPHP.map { "PHP \($0.version)" } ?? "none found"))").tag(String?.none)
                }
                ForEach(model.phpInstallations) { php in
                    Text("PHP \(php.version) — \(php.path)").tag(String?.some(php.path))
                }
                if let selection, !model.phpInstallations.contains(where: { $0.path == selection }) {
                    Text("Custom — \(selection)").tag(String?.some(selection))
                }
            }
            .accessibilityIdentifier("php-picker")
            HStack {
                Button("Choose Executable…") {
                    if let url = FilePanels.chooseExecutable(message: "Choose a PHP CLI executable") {
                        Task {
                            if let php = await PHPDiscovery.inspect(path: url.path) {
                                if !model.phpInstallations.contains(php) { model.phpInstallations.append(php) }
                                selection = php.path
                                validation = php.isSupportedByRunner ? "PHP \(php.version) found." : "PHP \(php.version) is older than Runlet's minimum (7.4)."
                            } else {
                                validation = "\(url.path) is not a working PHP CLI."
                            }
                        }
                    }
                }
                if let validation { Text(validation).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}
