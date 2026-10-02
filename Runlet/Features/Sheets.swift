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

/// Where Save Snippet writes.
enum SnippetDestination: Hashable {
    /// Runlet's own snippet library.
    case personal
    /// `<project>/.runlet/snippets/<slug>.php`, to share through the project's repository.
    case project
}

struct SnippetDraft: Identifiable {
    let id = UUID()
    var label: String
    var code: String
    var target: TargetRef
    var associate: Bool
    /// `.project` is used only when the target has a project folder (`AppModel.projectRoot(for:)`).
    var destination: SnippetDestination = .personal
    /// Written as `@description` for project snippets.
    var description: String = ""

    /// A draft of the tab's selection, or its whole code. `.project` is kept only when the
    /// tab's target has a project folder (`AppModel.projectRoot(for:)`).
    static func make(for tab: TabModel, model: AppModel, destination: SnippetDestination = .personal) -> SnippetDraft {
        let code = tab.editor.selectedText ?? tab.editor.text
        let hasProject = model.projectRoot(for: tab.target) != nil
        return SnippetDraft(label: "", code: code, target: tab.target, associate: tab.target != .sandbox, destination: hasProject ? destination : .personal)
    }
}

struct SaveSnippetSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: SnippetDraft
    /// The existing project file the user must agree to replace.
    @State private var pendingOverwrite: URL?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Snippet").font(.headline)
            if projectRoot != nil {
                Picker("Save to", selection: $draft.destination) {
                    Text("Personal").tag(SnippetDestination.personal)
                    Text("Project (.runlet/snippets)").tag(SnippetDestination.project)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("snippet-destination")
            }
            TextField("Label", text: $draft.label)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("snippet-label-field")
            if savesToProject {
                TextField("Description (optional)", text: $draft.description)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("snippet-description-field")
                Text("Writes \(relativePath) in \(model.projectName(for: draft.target) ?? "the project"). Commit it to share it with everyone who works on the project.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Toggle("Associate with \(model.targetLabel(draft.target))", isOn: $draft.associate)
                Text("Associated snippets open in a new tab with that target. The association is always shown in the snippet list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(draft.code)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 140)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(savesToProject ? "Save to Project" : "Save") { save(overwrite: false) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("snippet-save-button")
            }
        }
        .padding(20)
        .frame(width: 460)
        .onChange(of: draft.destination) { errorMessage = nil }
        .confirmationDialog("Replace \(pendingOverwrite?.lastPathComponent ?? "the file")?", isPresented: Binding(
            get: { pendingOverwrite != nil },
            set: { if !$0 { pendingOverwrite = nil } }
        )) {
            Button("Replace", role: .destructive) { save(overwrite: true) }
            Button("Cancel", role: .cancel) { pendingOverwrite = nil }
        } message: {
            Text("A project snippet with this file name already exists in \(ProjectSnippets.relativeDirectory). Replacing it overwrites that file. You can also change the label to save a new file.")
        }
    }

    private var projectRoot: URL? { model.projectRoot(for: draft.target) }

    private var savesToProject: Bool { draft.destination == .project && projectRoot != nil }

    private var trimmedLabel: String { draft.label.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var relativePath: String {
        "\(ProjectSnippets.relativeDirectory)/\(ProjectSnippets.fileName(forLabel: trimmedLabel.isEmpty ? "Untitled snippet" : trimmedLabel))"
    }

    /// Saves only on this explicit action; writing a project file never runs code.
    private func save(overwrite: Bool) {
        if savesToProject {
            do {
                let description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
                try model.saveProjectSnippet(label: trimmedLabel, description: description.isEmpty ? nil : description, code: draft.code, target: draft.target, overwrite: overwrite)
            } catch ProjectSnippets.SaveError.fileExists(let url) {
                pendingOverwrite = url
                return
            } catch {
                errorMessage = "Could not write the snippet: \(error.localizedDescription)"
                return
            }
        } else {
            model.saveSnippet(label: draft.label, code: draft.code, target: draft.associate ? draft.target : nil)
        }
        model.inspectorPane = .snippets
        dismiss()
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
            StrictTypesPicker(selection: $project.strictTypes)
                .accessibilityIdentifier("project-strict-types")
            MailInterceptionPicker(selection: $project.interceptMail)
                .accessibilityIdentifier("project-intercept-mail")
            TargetEnvironmentFields(environment: $project.environment.orDevelopment, color: $project.color)
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

/// Per-target strict-types override: follow Settings ▸ General ▸ Running, or force it
/// on or off for one project or Docker profile.
struct StrictTypesPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Bool?

    var body: some View {
        Picker("Strict types", selection: $selection) {
            Text("Default (\(model.settings.strictTypes ? "On" : "Off"))").tag(Bool?.none)
            Text("On").tag(Bool?.some(true))
            Text("Off").tag(Bool?.some(false))
        }
        .help("Whether runs on this target declare strict_types=1. Default follows Settings ▸ General ▸ Running. Code that declares strict_types itself is left alone.")
    }
}

/// Per-target mail interception override: follow Settings ▸ General ▸ Run Inspector, or
/// intercept (or send) mail for one project or Docker profile.
struct MailInterceptionPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Bool?

    var body: some View {
        Picker("Mail", selection: $selection) {
            Text("Default (\(model.settings.interceptMail ? "Intercept" : "Send"))").tag(Bool?.none)
            Text("Intercept (record, don't send)").tag(Bool?.some(true))
            Text("Send").tag(Bool?.some(false))
        }
        .help("Whether runs on this target ask the driver to record mail without sending it. Default follows Settings ▸ General ▸ Run Inspector. Queued mail is still sent by its worker.")
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
