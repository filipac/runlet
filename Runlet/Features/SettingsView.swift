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
        }
        .frame(width: 560)
        .frame(minHeight: 380, idealHeight: 520, maxHeight: .infinity)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClearHistory = false

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
                Text("History")
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

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Text") {
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
                Text("<?php echo 'The quick brown fox';")
                    .font(.system(size: model.settings.fontSize, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityHidden(true)
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
    }

    private var fontSize: Binding<Double> {
        Binding(
            get: { model.settings.fontSize },
            set: { model.settings.fontSize = min(max($0.rounded(), AppSettingsLimits.fontSize.lowerBound), AppSettingsLimits.fontSize.upperBound) }
        )
    }

    private var languageServiceEnabled: Binding<Bool> {
        Binding(
            get: { model.settings.languageServiceEnabled },
            set: { model.setLanguageServiceEnabled($0) }
        )
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
