import AppKit
import RunletCore
import RunletExecution
import RunletLanguage
import SwiftUI

/// The app's Settings window: appearance, editor, PHP, Docker, and sandbox preferences.
/// Every change is saved immediately through `AppModel.settings`.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsTab()
            }
            Tab("Editor", systemImage: "character.cursor.ibeam") {
                EditorSettingsTab()
            }
            Tab("PHP", systemImage: "chevron.left.forwardslash.chevron.right") {
                PHPSettingsTab()
            }
            Tab("Docker", systemImage: "cube.box") {
                DockerSettingsTab()
            }
            Tab("Sandbox", systemImage: "shippingbox") {
                SandboxSettingsTab()
            }
            Tab("Targets", systemImage: "square.stack.3d.up") {
                TargetSettingsView()
            }
            Tab("Shortcuts", systemImage: "keyboard") {
                ShortcutSettingsView()
            }
        }
        .frame(width: 560)
        .frame(minHeight: 380, idealHeight: 520, maxHeight: .infinity)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClearHistory = false

    private func libraryOpenDescription(_ behavior: LibraryOpenBehavior) -> String {
        switch behavior {
        case .reuseBlankTab:
            "For History and Snippets entries. A blank tab (nothing but <?php) on the entry's project takes the code, so you don't collect empty tabs. Snippets saved for any target fit every tab. Nothing runs until you press Run."
        case .newTab:
            "For History and Snippets entries: each opens in a new tab with its target. Nothing runs until you press Run."
        case .currentTab:
            "For History and Snippets entries: replaces the current tab's code (⌘Z undoes it) and switches the tab to the entry's target. A running tab gets a new tab instead. Nothing runs until you press Run."
        }
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $model.settings.appearance) {
                    Text("System").tag(AppearancePreference.system)
                    Text("Light").tag(AppearancePreference.light)
                    Text("Dark").tag(AppearancePreference.dark)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings-appearance")

                Picker("Output pane", selection: $model.settings.outputLayout) {
                    Label("Right of Editor", systemImage: "rectangle.split.2x1").tag(OutputLayout.right)
                    Label("Below Editor", systemImage: "rectangle.split.1x2").tag(OutputLayout.bottom)
                }
                .accessibilityIdentifier("settings-output-layout")

                Picker("Tabs", selection: $model.settings.tabLayout) {
                    Label("Horizontal (on top)", systemImage: "rectangle.split.3x1").tag(TabLayout.horizontal)
                    Label("Vertical (sidebar with details)", systemImage: "sidebar.left").tag(TabLayout.vertical)
                }
                .accessibilityIdentifier("settings-tab-layout")
            }

            Section("Running") {
                Toggle(isOn: $model.settings.runPrefersSelection) {
                    Text("Run prefers selection")
                    Text("When text is selected, Run (⌘R) runs only the selection. Run Selection (⇧⌘R) is always available, whatever this is set to.")
                }
                .accessibilityIdentifier("settings-run-prefers-selection")

                Toggle(isOn: $model.settings.strictTypes) {
                    Text("Declare strict_types=1 for every run")
                    Text("Scalar arguments and return values are no longer coerced, as in a file starting with declare(strict_types=1). Code that declares strict_types itself is left alone, and line numbers don't change. Projects and Docker profiles can override this in their options.")
                }
                .accessibilityIdentifier("settings-strict-types")
            }

            Section("Run Inspector") {
                Toggle(isOn: $model.settings.runInspector) {
                    Text("Record queries, mail, and logs")
                    Text("Next to the output, the inspector lists the SQL a run sent (with timings and duplicate or N+1 hints), its mail and log messages, and sections your project's driver adds. Turned off, runs record nothing.")
                }
                .accessibilityIdentifier("settings-run-inspector")

                Toggle(isOn: $model.settings.interceptMail) {
                    Text("Intercept mail")
                    Text("Mail sent during a run is recorded but not delivered (Laravel, and Symfony Mailer 6.3+), and the output says so. Mail pushed to an asynchronous queue is still sent by its queue worker. Projects and Docker profiles can override this in their options; it keeps the inspector on.")
                }
                .accessibilityIdentifier("settings-intercept-mail")

                Toggle(isOn: $model.settings.renderPreviews) {
                    Text("Preview returned mail, views, and HTML")
                    Text("Mailables, mail notifications, views, and HTML responses a snippet returns or dumps are rendered and shown without scripts or remote content. Rendering runs the application's view code.")
                }
                .accessibilityIdentifier("settings-render-previews")
            }

            Section {
                Picker("Default target", selection: $model.settings.defaultTarget) {
                    Label(model.targetLabel(.sandbox), systemImage: model.targetSymbol(.sandbox))
                        .tag(TargetRef.sandbox)
                    if !model.library.localProjects.isEmpty {
                        Section("Local Projects") {
                            ForEach(model.library.localProjects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { project in
                                Label(project.name, systemImage: "folder").tag(TargetRef.local(project.id))
                            }
                        }
                    }
                    if !model.library.dockerProfiles.isEmpty {
                        Section("Docker Applications") {
                            ForEach(model.library.dockerProfiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { profile in
                                Label(profile.name, systemImage: "cube.box").tag(TargetRef.docker(profile.id))
                            }
                        }
                    }
                    if !targetIsSaved(model.settings.defaultTarget, in: model.library) {
                        Text("Missing target (new tabs use the Sandbox)").tag(model.settings.defaultTarget)
                    }
                }
                .accessibilityIdentifier("settings-default-target")
            } header: {
                Text("New Tabs")
            } footer: {
                Text("Projects appear here after you open them with Open Project… (⇧⌘O). Docker applications appear after you save a Docker profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker(selection: $model.settings.libraryOpenBehavior) {
                    Text("This tab if it's empty and on the same target, else a new tab").tag(LibraryOpenBehavior.reuseBlankTab)
                    Text("Always a new tab").tag(LibraryOpenBehavior.newTab)
                    Text("Always the current tab").tag(LibraryOpenBehavior.currentTab)
                } label: {
                    Text("Double-click opens in")
                    Text(libraryOpenDescription(model.settings.libraryOpenBehavior))
                }
                .accessibilityIdentifier("settings-library-open")

                LabeledContent("Keep the most recent") {
                    HStack(spacing: 6) {
                        TextField("Runs", value: historyLimit, format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 72)
                            .accessibilityIdentifier("settings-history-limit")
                        Stepper("Runs", value: historyLimit, in: AppSettingsLimits.history, step: 50)
                            .labelsHidden()
                        Text("runs")
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent {
                    Button("Clear History…", role: .destructive) { confirmClearHistory = true }
                        .disabled(model.history.isEmpty)
                        .accessibilityIdentifier("settings-clear-history")
                } label: {
                    Text("Stored history")
                    Text(model.history.count == 1 ? "1 entry" : "\(model.history.count.formatted()) entries")
                }
            } header: {
                Text("History & Snippets")
            } footer: {
                Text("History stores each run's code, target, time, and final status (\(AppSettingsLimits.history.lowerBound.formatted())–\(AppSettingsLimits.history.upperBound.formatted()) runs). Older entries are dropped as new runs are recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear all history?", isPresented: $confirmClearHistory) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
        } message: {
            Text("This removes all \(model.history.count.formatted()) history entries. Snippets are not affected. This can't be undone.")
        }
    }

    private var historyLimit: Binding<Int> {
        Binding(
            get: { model.settings.historyLimit },
            set: { model.settings.historyLimit = min(max($0, AppSettingsLimits.history.lowerBound), AppSettingsLimits.history.upperBound) }
        )
    }
}

private enum AppSettingsLimits {
    static let history = 50...10_000
    static let fontSize = 9.0...28.0
}

// MARK: - Editor

private struct EditorSettingsTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    /// Installed fixed-pitch families (loaded off the main thread).
    @State private var fontFamilies: [String] = []
    @State private var installedEditors: [InstalledEditor] = []

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Font", selection: fontName) {
                    Text("System Monospaced").tag(String?.none)
                    if let name = model.settings.editorFontName, !fontFamilies.contains(name) {
                        Text(fontFamilies.isEmpty ? name : "\(name) (not installed)").tag(String?.some(name))
                    }
                    if !fontFamilies.isEmpty {
                        Divider()
                        ForEach(fontFamilies, id: \.self) { family in
                            Text(family).tag(String?.some(family))
                        }
                    }
                }
                .accessibilityIdentifier("settings-editor-font")
                LabeledContent("Font size") {
                    HStack(spacing: 6) {
                        Text("\(Int(model.settings.fontSize)) pt")
                            .monospacedDigit()
                            .accessibilityIdentifier("settings-font-size-value")
                        Stepper("Font size", value: fontSize, in: AppSettingsLimits.fontSize, step: 1)
                            .labelsHidden()
                            .accessibilityIdentifier("settings-font-size")
                    }
                }
                LabeledContent("Line height") {
                    HStack(spacing: 8) {
                        Slider(value: lineHeight, in: AppSettings.lineHeightRange, step: 0.05)
                            .frame(minWidth: 140, maxWidth: 220)
                            .accessibilityIdentifier("settings-line-height")
                        Text(model.settings.lineHeight.formatted(.number.precision(.fractionLength(2))) + "×")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                            .accessibilityIdentifier("settings-line-height-value")
                    }
                }
                Toggle(isOn: $model.settings.ligatures) {
                    Text("Ligatures")
                    Text(ligatureNote)
                }
                .accessibilityIdentifier("settings-ligatures")
                Toggle(isOn: $model.settings.softWrap) {
                    Text("Wrap long lines")
                    Text("Long lines wrap at the editor's width instead of scrolling sideways. Line numbers count lines, not wrapped rows.")
                }
                .accessibilityIdentifier("settings-soft-wrap")
                EditorTypographyPreview(preferences: EditorPreferences(settings: model.settings, dark: colorScheme == .dark))
                    .accessibilityHidden(true)
            } header: {
                Text("Text")
            }

            Section("Indentation") {
                Picker("Tab width", selection: $model.settings.tabWidth) {
                    Text("2").tag(2)
                    Text("4").tag(4)
                    Text("8").tag(8)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings-tab-width")
                Toggle("Insert spaces instead of tabs", isOn: $model.settings.insertSpaces)
                    .accessibilityIdentifier("settings-insert-spaces")
            }

            ExternalEditorSection(installedEditors: installedEditors)

            Section {
                Toggle(isOn: languageServiceEnabled) {
                    Text("PHPantom code intelligence")
                    Text("Completion, hover, signature help, and diagnostics.")
                }
                .accessibilityIdentifier("settings-language-service")
                if model.languageService == nil {
                    Label("PHPantom is missing from this build, so completion is unavailable.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Language Service")
            } footer: {
                Text("PHPantom runs on this Mac as a bundled helper and does not need PHP installed. It indexes the tab's project (or the sandbox) without executing your code. External analyzers and formatters such as PHPStan or PHP-CS-Fixer are disabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { installedEditors = InstalledEditor.detect() }
        .task {
            fontFamilies = await Task.detached(priority: .userInitiated) { EditorFonts.monospacedFamilies() }.value
        }
    }

    private var fontSize: Binding<Double> {
        Binding(
            get: { model.settings.fontSize },
            set: { model.settings.fontSize = min(max($0.rounded(), AppSettingsLimits.fontSize.lowerBound), AppSettingsLimits.fontSize.upperBound) }
        )
    }

    private var fontName: Binding<String?> {
        Binding(
            get: { model.settings.editorFontName },
            set: { model.settings.editorFontName = $0 }
        )
    }

    private var lineHeight: Binding<Double> {
        Binding(
            get: { model.settings.lineHeight },
            set: { value in
                let range = AppSettings.lineHeightRange
                // Snap to the slider's 0.05 steps so the stored value stays tidy.
                model.settings.lineHeight = min(max((value * 20).rounded() / 20, range.lowerBound), range.upperBound)
            }
        )
    }

    private var ligatureNote: String {
        let base = "Draws -> => !== >= as joined glyphs. Needs a font with programming ligatures, such as Fira Code, JetBrains Mono, Cascadia Code, or Iosevka."
        guard model.settings.ligatures else { return base }
        if model.settings.editorFontName == nil { return base + " The system monospaced font has none." }
        if let name = model.settings.editorFontName, !EditorFonts.isInstalled(name) { return base + " \(name) isn't installed." }
        return base
    }

    private var languageServiceEnabled: Binding<Bool> {
        Binding(
            get: { model.settings.languageServiceEnabled },
            set: { model.setLanguageServiceEnabled($0) }
        )
    }
}

/// A few highlighted lines rendered exactly like the editor: font family, size, line height,
/// and ligatures. Updates live as the settings change.
private struct EditorTypographyPreview: View {
    var preferences: EditorPreferences

    var body: some View {
        PreviewLabel(preferences: preferences)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: EditorTheme.resolve(dark: preferences.dark).background)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))
            .clipped()
    }

    private struct PreviewLabel: NSViewRepresentable {
        var preferences: EditorPreferences

        static let sample = """
        <?php
        $users = User::where('active', true)->get();
        $total = $users->sum(fn ($user) => $user->credits);
        return $total !== 0 && $total >= 10;
        """

        func makeNSView(context: Context) -> NSTextField {
            let field = NSTextField(labelWithAttributedString: NSAttributedString())
            field.maximumNumberOfLines = 0
            field.lineBreakMode = .byClipping
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.setAccessibilityIdentifier("settings-editor-preview")
            return field
        }

        func updateNSView(_ field: NSTextField, context: Context) {
            field.attributedStringValue = Self.render(preferences)
        }

        static func render(_ preferences: EditorPreferences) -> NSAttributedString {
            let theme = EditorTheme.resolve(dark: preferences.dark)
            let font = EditorFonts.font(family: preferences.fontName, size: preferences.fontSize, ligatures: preferences.ligatures)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = preferences.lineHeight
            paragraph.lineBreakMode = .byClipping
            let text = NSMutableAttributedString(string: sample, attributes: [
                .font: font,
                .paragraphStyle: paragraph,
                .foregroundColor: theme.text,
                .ligature: preferences.ligatures ? 1 : 0,
            ])
            for token in PHPHighlighter.tokenize(sample as NSString) where NSMaxRange(token.range) <= text.length {
                text.addAttribute(.foregroundColor, value: theme.color(for: token.kind), range: token.range)
            }
            return text
        }
    }
}

/// Settings ▸ Editor ▸ External Editor: which app file links open in, a custom command, and a test.
private struct ExternalEditorSection: View {
    @Environment(AppModel.self) private var model
    let installedEditors: [InstalledEditor]

    var body: some View {
        @Bindable var model = model
        Section {
            Picker("Open files in", selection: $model.settings.externalEditor) {
                Text("None (Reveal in Finder)").tag(ExternalEditor.none)
                if !installedEditors.isEmpty {
                    Divider()
                    ForEach(installedEditors) { app in
                        Text(app.name).tag(app.editor)
                    }
                }
                if isMissing(model.settings.externalEditor) {
                    Text("\(model.settings.externalEditor.displayName) (not installed)").tag(model.settings.externalEditor)
                }
                Divider()
                Text("Custom Command…").tag(ExternalEditor.custom)
            }
            .accessibilityIdentifier("settings-external-editor")

            if model.settings.externalEditor == .custom {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Command", text: customCommand, prompt: Text("code --goto {file}:{line}"))
                        .font(.system(.body, design: .monospaced))
                        .accessibilityIdentifier("settings-external-editor-command")
                    if let problem = commandProblem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text("`{file}` is replaced with the file's absolute path and `{line}` with the line number; without `{file}` the path is added at the end. When there is no line (opening a project), `:{line}` is dropped. The command runs directly, not through a shell: quotes group words, but variables, `~` in arguments, and pipes are not expanded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            LabeledContent {
                Button("Test") { model.openProjectInEditor(for: testTarget) }
                    .disabled(model.settings.externalEditor == .none || !model.canOpenProjectInEditor(for: testTarget) || (model.settings.externalEditor == .custom && commandProblem != nil))
                    .accessibilityIdentifier("settings-external-editor-test")
            } label: {
                Text("Open the current project")
                Text(testDescription)
            }
        } header: {
            Text("External Editor")
        } footer: {
            Text("File paths in dumps, errors, and stack traces open at their line in this editor (or in Finder when none is set). Paths from Docker targets map through the profile's local source folder; paths with no counterpart on this Mac are shown as plain text.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func isMissing(_ editor: ExternalEditor) -> Bool {
        editor != .none && editor != .custom && !installedEditors.contains { $0.editor == editor }
    }

    private var customCommand: Binding<String> {
        Binding(
            get: { model.settings.externalEditorCommand ?? "" },
            set: { model.settings.externalEditorCommand = $0.isEmpty ? nil : $0 }
        )
    }

    private var commandProblem: String? {
        guard let template = model.settings.externalEditorCommand, !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Enter the command that opens a file, using {file} and {line}."
        }
        do {
            let arguments = try EditorLinks.splitArguments(template)
            if let executable = arguments.first, ExecutableLocator.resolve(executable) == nil {
                return "“\(executable)” was not found. Use an absolute path or a command on your PATH."
            }
        } catch {
            return "\(error)"
        }
        return nil
    }

    private var testTarget: TargetRef { model.selectedTab?.target ?? model.validTarget(model.settings.defaultTarget) }

    private var testDescription: String {
        switch model.projectFolder(for: testTarget) {
        case .mapped(let path):
            "\(model.targetLabel(testTarget)) — \((path as NSString).abbreviatingWithTildeInPath)"
        case .unavailable(let reason):
            reason
        }
    }
}

// MARK: - PHP

private struct PHPSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var isScanning = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                PHPPicker(selection: $model.settings.defaultPHPExecutable, allowDefault: false)
            } header: {
                Text("Default PHP")
            } footer: {
                Text("Used by local projects that don't choose their own PHP, and preferred by the Laravel sandbox when it is compatible\(sandboxMinimum.map { " (PHP \($0)+)" } ?? ""). Automatic uses your default `php` on PATH (stable releases before RC/beta builds).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if model.phpInstallations.isEmpty {
                    Text(isScanning ? "Scanning…" : "No PHP installations were found. The sandbox can still run in Docker.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.phpInstallations) { php in
                        PHPInstallationRow(php: php)
                    }
                }
                HStack {
                    Text("Searches PATH, Herd, Homebrew, and other common locations.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isScanning { ProgressView().controlSize(.small) }
                    Button("Rescan") { rescan() }
                        .disabled(isScanning)
                        .accessibilityIdentifier("settings-php-rescan")
                }
            } header: {
                Text("Discovered Installations")
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.settings.defaultPHPExecutable) {
            // The sandbox prefers the default PHP when compatible.
            Task { await model.refreshSandbox() }
        }
    }

    private var sandboxMinimum: String? { model.sandbox?.manifest.minimumPHP }

    private func rescan() {
        isScanning = true
        Task {
            await model.refreshEnvironment()
            isScanning = false
        }
    }
}

private struct PHPInstallationRow: View {
    @Environment(AppModel.self) private var model
    let php: PHPInstallation

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("PHP \(php.version)").fontWeight(.medium)
                SettingsBadge(text: php.source)
                if php.path == model.settings.defaultPHPExecutable {
                    SettingsBadge(text: "Default", tint: .accentColor)
                } else if model.settings.defaultPHPExecutable == nil, php.path == model.bestPHP?.path {
                    SettingsBadge(text: "Automatic", tint: .accentColor)
                }
                Spacer()
                if !php.isSupportedByRunner {
                    Label("Older than 7.4 — not supported", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if !php.hasTokenizer {
                    Label("Missing tokenizer extension", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Text(php.path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1)
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings-php-installation")
    }

    private var helpText: String {
        var notes = ["\(php.path) (\(php.source))"]
        if !php.isSupportedByRunner { notes.append("Runlet's runner needs PHP 7.4 or newer.") }
        if !php.hasTokenizer { notes.append("The tokenizer extension is required to run snippets.") }
        return notes.joined(separator: "\n")
    }
}

// MARK: - Docker

private struct DockerSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var dockerPath = ""
    @State private var isScanning = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    dockerStatusView
                }
                LabeledContent("Docker CLI") {
                    Text(model.docker?.executable ?? "Not found")
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .foregroundStyle(model.docker == nil ? .secondary : .primary)
                }
                if case .unavailable(let message) = model.dockerStatus {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(5)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Docker")
            } footer: {
                Text("Docker is optional. Runlet uses it for saved Docker applications and as the sandbox fallback when no compatible local PHP is installed. Commands use your currently selected Docker context.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("CLI path", text: $dockerPath, prompt: Text("Automatic"))
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { apply() }
                    .accessibilityIdentifier("settings-docker-path")
                if let warning = overrideWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button("Choose…") {
                        if let url = FilePanels.chooseExecutable(message: "Choose the docker CLI executable") {
                            dockerPath = url.path
                        }
                    }
                    Spacer()
                    if isScanning { ProgressView().controlSize(.small) }
                    Button(hasPendingChange ? "Apply & Rescan" : "Rescan") { apply() }
                        .disabled(isScanning)
                        .keyboardShortcut(hasPendingChange ? .defaultAction : nil)
                        .accessibilityIdentifier("settings-docker-apply")
                }
            } header: {
                Text("Docker CLI Override")
            } footer: {
                Text("Leave blank to find docker automatically (PATH, Docker Desktop, OrbStack, Rancher Desktop, Homebrew).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { dockerPath = model.settings.dockerExecutable ?? "" }
    }

    @ViewBuilder
    private var dockerStatusView: some View {
        switch model.dockerStatus {
        case .unknown:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…")
            }
        case .available(let version):
            Label {
                Text("Running · Engine \(version)")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .accessibilityIdentifier("settings-docker-status")
        case .unavailable:
            Label {
                Text(model.docker == nil ? "Not installed" : "Not running")
            } icon: {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
            .accessibilityIdentifier("settings-docker-status")
        }
    }

    private var trimmedPath: String { dockerPath.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var hasPendingChange: Bool { trimmedPath != (model.settings.dockerExecutable ?? "") }

    private var overrideWarning: String? {
        guard !trimmedPath.isEmpty, ExecutableLocator.resolve(trimmedPath) == nil else { return nil }
        return "\(trimmedPath) was not found or is not executable; automatic detection is used instead."
    }

    private func apply() {
        model.settings.dockerExecutable = trimmedPath.isEmpty ? nil : trimmedPath
        isScanning = true
        Task {
            await model.refreshEnvironment()
            isScanning = false
        }
    }
}

// MARK: - Sandbox

private struct SandboxSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReset = false

    var body: some View {
        Form {
            if let sandbox = model.sandbox {
                Section("Laravel Sandbox") {
                    LabeledContent("Laravel", value: sandbox.manifest.laravelVersion)
                    LabeledContent("Requires", value: "PHP \(sandbox.manifest.minimumPHP)+ locally, or Docker")
                    LabeledContent("Services", value: SandboxManager.serviceSummary)
                    LabeledContent {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([sandbox.installURL])
                        }
                        .disabled(!FileManager.default.fileExists(atPath: sandbox.installURL.path))
                        .accessibilityIdentifier("settings-sandbox-reveal")
                    } label: {
                        Text("Location")
                        Text(sandbox.installURL.path)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }

                Section {
                    Picker("Run sandbox with", selection: Binding(
                        get: { model.settings.sandboxRuntime },
                        set: { value in
                            model.settings.sandboxRuntime = value
                            Task { await model.refreshSandbox() }
                        }
                    )) {
                        Text("Automatic").tag(SandboxRuntimePreference.automatic)
                        Text("Local PHP").tag(SandboxRuntimePreference.localPHP)
                        Text("Docker (\(sandbox.manifest.dockerImage))").tag(SandboxRuntimePreference.docker)
                    }
                    .accessibilityIdentifier("settings-sandbox-runtime")
                    LabeledContent("Runtime") {
                        runtimeView
                    }
                    if case .needsImage(let image) = model.sandboxStatus {
                        imageDownload(image)
                    }
                    if case .unavailable(let reason) = model.sandboxStatus {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    HStack {
                        Spacer()
                        Button("Check Again") { Task { await model.refreshSandbox() } }
                            .disabled(model.sandboxStatus == .checking || model.isPullingImage)
                    }
                } header: {
                    Text("Runtime")
                } footer: {
                    Text("Automatic uses a compatible local PHP when one is installed and falls back to a disposable Docker container otherwise. Docker runs need no host PHP.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent {
                        Button("Reset Sandbox…", role: .destructive) { confirmReset = true }
                            .accessibilityIdentifier("settings-sandbox-reset")
                    } label: {
                        Text("Reset")
                        Text("Restore a fresh copy of the sandbox, discarding its database, cache, logs, and compiled views.")
                    }
                }
            } else {
                Section("Laravel Sandbox") {
                    Label("The bundled sandbox template is missing from this build.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset the Laravel sandbox?", isPresented: $confirmReset) {
            Button("Reset Sandbox", role: .destructive) { Task { await model.resetSandbox() } }
        } message: {
            Text("This deletes only sandbox-owned data (its SQLite database, cache, sessions, logs, and compiled views) and restores a fresh copy of Laravel. Your local projects, Docker applications, snippets, and history are not touched.")
        }
    }

    @ViewBuilder
    private var runtimeView: some View {
        switch model.sandboxStatus {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…")
            }
        case .ready(.local(let php)):
            VStack(alignment: .trailing, spacing: 2) {
                Text("Local PHP \(php.version)")
                Text(php.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .ready(.docker(let image, _)):
            Text("Docker · \(image)")
        case .ready(.unavailable), .unavailable:
            Label {
                Text("Unavailable")
            } icon: {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
        case .needsImage(let image):
            Label {
                Text("Docker · \(image) (not downloaded)")
            } icon: {
                Image(systemName: "arrow.down.circle").foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func imageDownload(_ image: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No compatible local PHP was found, so the sandbox runs in Docker using the \(image) image. It is a one-time download of a few hundred megabytes and is reused for every sandbox run.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if model.isPullingImage {
                    ProgressView().controlSize(.small)
                    Text("Downloading \(image)…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Download Docker Image") {
                    Task { await model.downloadSandboxImage() }
                }
                .disabled(model.isPullingImage || !model.dockerStatus.isAvailable)
                .accessibilityIdentifier("settings-sandbox-download-image")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Shared

private struct SettingsBadge: View {
    var text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(0.15)))
    }
}

/// Whether a target still refers to a saved project/profile (the sandbox always exists).
private func targetIsSaved(_ target: TargetRef, in library: TargetLibrary) -> Bool {
    switch target {
    case .sandbox: true
    case .local(let id): library.localProject(id) != nil
    case .docker(let id): library.dockerProfile(id) != nil
    }
}
