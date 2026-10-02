import AppKit
import RunletCore
import RunletExecution
import SwiftUI

/// Sheet that creates or edits one SSH profile (target menu, Library ▸ New SSH Profile…,
/// Settings ▸ Targets). Saving, opening, or editing a profile never connects to the server;
/// only Test Connection and Connect… do, and only when clicked.
struct SSHProfileEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var profile: SSHProfile
    var isNew: Bool
    var onSave: (SSHProfile) -> Void

    @State private var confirmingDelete = false

    var body: some View {
        VStack(spacing: 0) {
            SSHProfileHeader(title: isNew ? "New SSH Profile" : "Edit SSH Profile")
            Divider()
            SSHProfileForm(profile: $profile, connect: connectFromSheet)
            Divider()
            footer
        }
        .frame(width: 640, height: 720)
        .confirmationDialog("Delete the SSH profile “\(savedName)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Profile", role: .destructive) {
                model.removeSSHProfile(profile.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Tabs using this profile switch to the Laravel Sandbox. Its connection is closed; nothing on the server is touched.")
        }
    }

    private var footer: some View {
        let errors = profile.normalizedForSaving.validate()
        return HStack {
            if !isNew {
                Button("Delete Profile…", role: .destructive) { confirmingDelete = true }
                    .accessibilityIdentifier("ssh-delete-button")
            }
            Spacer()
            DockerProfileIssueCount(count: errors.count)
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("ssh-cancel-button")
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!errors.isEmpty)
                .accessibilityIdentifier("ssh-save-button")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var savedName: String {
        model.library.sshProfile(profile.id)?.name ?? profile.name
    }

    private func save() {
        let result = profile.normalizedForSaving
        guard result.validate().isEmpty else { return }
        onSave(result)
        dismiss()
    }

    /// Connect… needs the terminal below the sheet, so the sheet steps aside: it saves the
    /// profile when it can, closes, and reopens with these values once the login succeeds
    /// (a profile that can't be saved yet, e.g. without a directory, is kept unsaved).
    private func connectFromSheet() {
        let result = profile.normalizedForSaving
        if result.validate().isEmpty, model.library.sshProfile(result.id) != result { onSave(result) }
        dismiss()
        model.connectSSH(profile: result, resumingSheet: true)
    }
}

/// The SSH profile form: host, server directory and PHP, login, local folder, and Test
/// Connection. It edits `profile` in place and never saves.
struct SSHProfileForm: View {
    @Environment(AppModel.self) private var model
    @Binding var profile: SSHProfile
    /// Connect… for these values (the sheet steps aside and comes back after the login); nil
    /// connects the draft without closing anything (the Profiles window).
    var connect: (() -> Void)?

    @State private var aliases: [String] = []
    @State private var effective: [String: String]?
    @State private var effectiveFor: String?
    @State private var showOverrides = false
    @State private var probeTask: Task<Void, Never>?
    // Detect and Browse… (explicit actions that connect)
    @State private var detection: RemoteDirectoryDetection?
    @State private var isDetecting = false
    @State private var showDetection = false
    @State private var detectTask: Task<Void, Never>?
    @State private var browsing = false

    private static let keepAliveChoices: [Int?] = [10, 30, 60, 240, nil]

    var body: some View {
        Form {
            Section {
                field("Name", error: .emptyName) {
                    TextField("Name", text: $profile.name, prompt: Text("e.g. Shop production"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("ssh-profile-name")
                }
                field("Host", error: .invalidHost, help: "An alias from ~/.ssh/config or a host name. ssh applies your config as usual: user, port, ProxyJump, IdentityAgent (1Password), and keys.") {
                    HStack(spacing: 6) {
                        TextField("Host", text: $profile.host, prompt: Text("Alias from ~/.ssh/config or a host name"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("ssh-host")
                        aliasMenu
                    }
                }
                if let effective, effectiveFor == profile.host {
                    LabeledContent("From ~/.ssh/config") {
                        Text(Self.effectiveSummary(effective))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                DisclosureGroup("Override user, port, or jump host", isExpanded: $showOverrides) {
                    field("User", error: .invalidUser) {
                        TextField("User", text: optionalBinding(\.user), prompt: Text("From ~/.ssh/config"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("ssh-user")
                    }
                    field("Port", error: .invalidPort) {
                        TextField("Port", text: portBinding, prompt: Text("From ~/.ssh/config (22)"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("ssh-port")
                    }
                    field("Jump host", error: .invalidJumpHost) {
                        TextField("Jump host", text: optionalBinding(\.jumpHost), prompt: Text("From ~/.ssh/config (ProxyJump)"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("ssh-jump-host")
                    }
                }
            } header: {
                Text("Server")
            }

            Section("On the Server") {
                field("Directory", errors: SSHProfile.ValidationError.directoryErrors, help: "The application's folder on the server, such as /home/forge/example.com/current. Symlinks are fine. Detect and Browse… connect to the server and only read folder names.") {
                    HStack(spacing: 6) {
                        TextField("Directory", text: $profile.remoteDirectory, prompt: Text("Absolute path on the server"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("ssh-remote-directory")
                        if let probe, !probe.candidates.isEmpty {
                            suggestionMenu(probe.candidates, help: "Applications Test Connection found") { profile.remoteDirectory = $0 }
                        }
                        detectButton
                        Button("Browse…") { browsing = true }
                            .disabled(!canReachServer)
                            .help("Pick the folder on the server (lists folder names over SSH; nothing is written)")
                            .accessibilityIdentifier("ssh-browse-directory")
                    }
                }
                field("PHP executable", error: .invalidPHP, help: "php, a name such as php8.3, or an absolute path.") {
                    HStack(spacing: 6) {
                        TextField("PHP executable", text: $profile.phpExecutable, prompt: Text("php"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("ssh-php-executable")
                        if let probe, !probe.phpCandidates.isEmpty {
                            suggestionMenu(probe.phpCandidates, help: "PHP binaries Test Connection found") { profile.phpExecutable = $0 }
                        }
                    }
                }
                field("Strict types", help: "Whether runs on this host declare strict_types=1. Default follows Settings ▸ General ▸ Running.") {
                    StrictTypesPicker(selection: $profile.strictTypes)
                        .labelsHidden()
                        .accessibilityIdentifier("ssh-strict-types")
                }
                if profile.container == nil {
                    field("Speed", help: "Runs keep PHP's compiled files in a private cache on the server (~/.cache/runlet/opcache, readable only by the SSH user), so large apps such as WordPress don't recompile every file on each run. Edited files are still picked up. Off by default because it writes to the server.") {
                        Toggle("Keep compiled PHP on the server", isOn: $profile.keepCompiledPHP)
                            .accessibilityIdentifier("ssh-keep-compiled-php")
                    }
                }
                field("Mail", help: "Whether runs on this host record mail without sending it. Default follows Settings ▸ General ▸ Run Inspector. Queued mail is still sent by the server's queue worker.") {
                    MailInterceptionPicker(selection: $profile.interceptMail)
                        .labelsHidden()
                        .accessibilityIdentifier("ssh-intercept-mail")
                }
            }

            SSHContainerStepSection(profile: $profile)

            Section {
                field("Authentication") {
                    Picker("Authentication", selection: $profile.authentication) {
                        Text("SSH agent, 1Password, or key files").tag(SSHAuthentication.automatic)
                        Text("Password or two-factor code (Connect…)").tag(SSHAuthentication.interactive)
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("ssh-authentication")
                }
                if profile.authentication == .automatic {
                    field("Keep connection", error: .invalidKeepAlive, help: "The first run opens a shared connection that later runs reuse. It closes after this long without use.") {
                        Picker("Keep connection", selection: $profile.keepAliveMinutes) {
                            ForEach(Self.keepAliveChoices, id: \.self) { minutes in
                                Text(Self.keepAliveLabel(minutes)).tag(minutes)
                            }
                        }
                        .labelsHidden()
                        .accessibilityIdentifier("ssh-keep-alive")
                    }
                }
                Toggle("Compress the connection (ssh -C)", isOn: $profile.compression)
                    .accessibilityIdentifier("ssh-compression")
                LabeledContent("Connection") {
                    SSHConnectionControls(profileId: profile.id, connect: connectDraft)
                }
            } header: {
                Text("Login")
            } footer: {
                Text(profile.authentication == .automatic
                     ? "Runs log in without prompts (BatchMode). 1Password asks for approval in its own window. Unknown host keys are never accepted by a run: use Connect… once to check the fingerprint."
                     : "Connect… opens a terminal tab where OpenSSH asks for the password or code; Runlet never sees it. Runs reuse that login until you disconnect, also after Runlet restarts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Code Intelligence") {
                field("Local folder", help: "This project's checkout on your Mac. It powers completion, file links in output, project snippets, host commands, and Open in Editor; without it Runlet works in limited mode.") {
                    HStack(spacing: 6) {
                        Text(profile.localSourcePath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "None")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(profile.localSourcePath == nil ? .secondary : .primary)
                            .help(profile.localSourcePath ?? "No local folder")
                            .textSelection(.enabled)
                        Spacer(minLength: 4)
                        Button("Choose…") {
                            if let url = FilePanels.chooseDirectory(message: "Choose this project's checkout on your Mac", start: profile.localSourcePath) {
                                profile.localSourcePath = url.standardizedFileURL.path
                            }
                        }
                        .accessibilityIdentifier("ssh-local-folder-choose")
                        if profile.localSourcePath != nil {
                            Button("Clear") { profile.localSourcePath = nil }
                                .accessibilityIdentifier("ssh-local-folder-clear")
                        }
                    }
                }
                if profile.localSourcePath == nil, let suggestions = model.sshConnections.folderSuggestions[profile.id], !suggestions.isEmpty {
                    LabeledContent("Suggestions") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(suggestions) { suggestion in
                                HStack(spacing: 6) {
                                    Text((suggestion.path as NSString).abbreviatingWithTildeInPath)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(suggestion.path)
                                    Text(suggestion.reason.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 4)
                                    Button("Use") { profile.localSourcePath = suggestion.path }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier("ssh-local-folder-suggestions")
                }
                field("PHP version", help: "PHP version used for completion, e.g. 8.3. Blank infers it from the local composer.json.") {
                    TextField("PHP version for completion", text: optionalBinding(\.languagePHPVersion), prompt: Text("Infer"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("ssh-language-php-version")
                }
                Toggle(isOn: $profile.checkDrift) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Warn when the local folder differs from the server")
                        Text("After Connect…, Test Connection, and the first run of a session, Runlet reads the server's .git files (or composer.lock) with a read-only PHP check and compares them with the local folder. Off by default because it reads files on the server.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(profile.localSourcePath == nil)
                .accessibilityIdentifier("ssh-check-drift")
            }

            Section("Environment") {
                TargetEnvironmentFields(environment: $profile.environment, color: $profile.color)
            }

            Section("Connection") {
                testRow
                if let probe {
                    SSHProbeResults(probe: probe, directory: profile.remoteDirectory, hostPHPOptional: profile.container != nil) { candidate in
                        profile.remoteDirectory = candidate
                    }
                }
                if profile.container != nil, let check = model.sshConnections.containerChecks[profile.id] {
                    RemoteContainerCheckResults(check: check)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // Reading ~/.ssh/config and local folders is local; no connection is made.
            aliases = SSHConfigHosts.aliases(in: model.sshConfigFile)
            showOverrides = profile.user != nil || profile.port != nil || profile.jumpHost != nil
            if profile.localSourcePath == nil, !profile.remoteDirectory.isEmpty {
                model.lookUpFolderSuggestions(for: profile, probe: model.sshConnections.probes[profile.id])
            }
        }
        .onDisappear {
            probeTask?.cancel()
            detectTask?.cancel()
        }
        .task(id: profile.host) { await loadEffectiveConfiguration() }
        .sheet(isPresented: $browsing) {
            let snapshot = profile.normalizedForSaving
            RemoteDirectoryBrowser(place: snapshot.destinationLabel, startPath: browseStart(snapshot.remoteDirectory)) { path in
                await model.listSSHDirectory(snapshot, path: path)
            } choose: { path in
                profile.remoteDirectory = path
            }
        }
    }

    // MARK: Directory on the server

    /// Detect: fills an empty (or `~…`) Directory with the server's home folder and lists the
    /// application folders it finds, home first.
    private var detectButton: some View {
        Button {
            detect()
        } label: {
            if isDetecting {
                ProgressView().controlSize(.small).frame(width: 46)
            } else {
                Text("Detect")
            }
        }
        .disabled(!canReachServer || isDetecting)
        .help("Connect and find the home folder and the PHP applications on the server (reads folder names only)")
        .accessibilityIdentifier("ssh-detect-directory")
        .popover(isPresented: $showDetection, arrowEdge: .bottom) { detectionPopover }
    }

    @ViewBuilder
    private var detectionPopover: some View {
        if let detection {
            let connect: (() -> Void)? = loginNeeded ? { connectFromDetection() } : nil
            DetectedDirectoriesView(detection: detection, place: profile.normalizedForSaving.destinationLabel, connect: connect) { path in
                profile.remoteDirectory = path
                showDetection = false
            }
        }
    }

    private var loginNeeded: Bool {
        model.sshLoginNeeded(profile.normalizedForSaving) != nil
    }

    private func connectFromDetection() {
        showDetection = false
        connectDraft()
    }

    private func connectDraft() {
        if let connect { connect() } else { model.connectSSH(profile: profile.normalizedForSaving) }
    }

    private func detect() {
        let snapshot = profile.normalizedForSaving
        detectTask?.cancel()
        isDetecting = true
        detectTask = Task {
            let result = await model.detectSSHDirectories(snapshot)
            guard !Task.isCancelled else { return }
            isDetecting = false
            detection = result
            if let home = result.home {
                let current = SSHProfile.normalizedDirectory(profile.remoteDirectory)
                if current.isEmpty || current.hasPrefix("~") {
                    profile.remoteDirectory = current.isEmpty ? home : SSHProfile.expandingTilde(current, home: home)
                }
            }
            showDetection = true
        }
    }

    /// Browse… starts in the typed folder when it is a path, else in the home folder.
    private func browseStart(_ directory: String) -> String {
        directory.hasPrefix("/") || directory.hasPrefix("~") ? directory : ""
    }

    /// Detect and Browse… need a host they can reach (the directory itself may be blank).
    private var canReachServer: Bool {
        let errors = profile.normalizedForSaving.validate()
        return !errors.contains(.invalidHost) && !errors.contains(.invalidPHP) && !errors.contains(.invalidUser)
            && !errors.contains(.invalidPort) && !errors.contains(.invalidJumpHost)
    }

    // MARK: Host

    private var aliasMenu: some View {
        Menu {
            if aliases.isEmpty {
                Text("No Host entries in ~/.ssh/config")
            }
            ForEach(aliases, id: \.self) { alias in
                Button(alias) {
                    profile.host = alias
                    if profile.name.trimmingCharacters(in: .whitespaces).isEmpty { profile.name = alias }
                }
            }
        } label: {
            Label("Hosts from ~/.ssh/config", systemImage: "list.bullet")
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Hosts from ~/.ssh/config")
        .accessibilityIdentifier("ssh-host-aliases")
    }

    /// `ssh -G` (reads the config, never connects) for the typed host, after a short pause.
    private func loadEffectiveConfiguration() async {
        let host = profile.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, profile.validate().contains(.invalidHost) == false else {
            effective = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        let values = await model.sshClient.effectiveConfiguration(host: host, user: profile.user, port: profile.port)
        guard !Task.isCancelled else { return }
        effective = values
        effectiveFor = profile.host
    }

    static func effectiveSummary(_ values: [String: String]) -> String {
        var lines = ["\(values["user"] ?? "?")@\(values["hostname"] ?? "?"):\(values["port"] ?? "22")"]
        if let jump = values["proxyjump"], jump != "none" { lines.append("via \(jump)") }
        if let agent = values["identityagent"], agent != "none", !agent.isEmpty { lines.append("agent \((agent as NSString).abbreviatingWithTildeInPath)") }
        return lines.joined(separator: "\n")
    }

    // MARK: Test Connection

    private var probe: SSHProbe? { model.sshConnections.probes[profile.id] }
    private var isProbing: Bool { model.sshConnections.probing.contains(profile.id) }

    private var testRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    let snapshot = profile.normalizedForSaving
                    probeTask?.cancel()
                    probeTask = Task { _ = await model.testSSHConnection(snapshot) }
                } label: {
                    Label("Test Connection", systemImage: "bolt.horizontal")
                }
                .disabled(isProbing || !canProbe)
                .accessibilityIdentifier("ssh-test-button")
                if isProbing {
                    ProgressView().controlSize(.small)
                    Text("Connecting to \(profile.destinationLabel)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text("Logs in without prompts and runs a short read-only PHP check in the directory. Your snippet and the project's code don't run.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var canProbe: Bool {
        let errors = profile.normalizedForSaving.validate()
        return canReachServer && !errors.contains(where: SSHProfile.ValidationError.directoryErrors.contains)
    }

    // MARK: Helpers

    private func suggestionMenu(_ values: [String], help: String, choose: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(values, id: \.self) { value in
                Button(value) { choose(value) }
            }
        } label: {
            Label(help, systemImage: "list.bullet")
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(help)
    }

    private func field<Content: View>(_ title: String, error: SSHProfile.ValidationError? = nil, errors: [SSHProfile.ValidationError] = [], help: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        let shown = errors + (error.map { [$0] } ?? [])
        return LabeledContent {
            VStack(alignment: .leading, spacing: 4) {
                content()
                // The value exactly as typed (trimmed, as it is saved), checked on every change.
                if let error = profile.validate().first(where: shown.contains) {
                    Label {
                        Text(LocalizedStringKey(error.description))
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let help {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Grouped forms align trailing; wrapped messages read better from the left.
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title)
        }
    }

    private func optionalBinding(_ keyPath: WritableKeyPath<SSHProfile, String?>) -> Binding<String> {
        Binding(
            get: { profile[keyPath: keyPath] ?? "" },
            set: { value in profile[keyPath: keyPath] = value.isEmpty ? nil : value }
        )
    }

    private var portBinding: Binding<String> {
        Binding(
            get: { profile.port.map(String.init) ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                profile.port = trimmed.isEmpty ? nil : (Int(trimmed) ?? 0)
            }
        )
    }

    static func keepAliveLabel(_ minutes: Int?) -> String {
        guard let minutes else { return "Until I disconnect" }
        return minutes < 60 ? "\(minutes) minutes" : (minutes == 60 ? "1 hour" : "\(minutes / 60) hours")
    }
}

/// Test Connection results.
struct SSHProbeResults: View {
    let probe: SSHProbe
    let directory: String
    /// A container step runs the container's PHP, so a server without PHP is fine.
    var hostPHPOptional = false
    var useDirectory: (String) -> Void

    private enum CheckState {
        case ok, warning, failure, info

        var symbol: String {
            switch self {
            case .ok: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .failure: "xmark.octagon.fill"
            case .info: "info.circle"
            }
        }

        var color: Color {
            switch self {
            case .ok: .green
            case .warning: .orange
            case .failure: .red
            case .info: .secondary
            }
        }
    }

    var body: some View {
        if let error = probe.error, hostPHPOptional, error.contains("PHP was not found") {
            LabeledContent {
                Text("The server itself has no PHP under this name. That's fine: runs use the container's PHP. (Detect, Browse…, and the drift check need PHP on the server.)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Server PHP", systemImage: CheckState.info.symbol)
            }
        } else if let error = probe.error {
            LabeledContent {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Error", systemImage: CheckState.failure.symbol)
                    .foregroundStyle(CheckState.failure.color)
            }
            .accessibilityIdentifier("ssh-probe-error")
        } else if let version = probe.phpVersion {
            row("PHP", version + (probe.phpBinary.map { " · \($0)" } ?? ""), state: Self.isSupportedPHP(version) ? .ok : .failure)
            row("User", [probe.user, probe.uid.map { "uid \($0)" }].compactMap { $0 }.joined(separator: " · "), state: .info)
            row("Directory", directoryText, state: probe.directoryExists && probe.directoryReadable ? .ok : .failure)
            row("Framework", Self.frameworkDescription(probe.framework), state: probe.framework == "plain" ? .warning : .ok)
            row("Tokenizer", probe.hasTokenizer ? "Available" : "Missing; Runlet's runner needs the tokenizer extension", state: probe.hasTokenizer ? .ok : .failure)
            row("Stop", stopText, state: probe.hasProc && probe.canSignal != "none" ? .ok : .warning)
            if let elapsed = probe.elapsedMs {
                row("Round trip", "\(elapsed) ms", state: .info)
            }
            let others = probe.candidates.filter { $0 != directory && $0 != probe.realDirectory }
            if !others.isEmpty {
                LabeledContent("Applications found") {
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(others.prefix(8), id: \.self) { candidate in
                            Button("Use \(candidate)") { useDirectory(candidate) }
                        }
                    }
                }
            }
        }
    }

    private var directoryText: String {
        guard probe.directoryExists else { return "Does not exist" }
        guard probe.directoryReadable else { return "Exists but is not readable by this login" }
        if let real = probe.realDirectory, real != directory { return "Readable · resolves to \(real)" }
        return "Exists and is readable"
    }

    private var stopText: String {
        guard probe.hasProc else { return "This server has no /proc, so Stop can't check which process to signal (\(probe.os ?? "unknown OS")). A stopped run may keep running on the server." }
        switch probe.canSignal {
        case "posix": return "Supported (posix_kill)"
        case "shell": return "Supported (through /bin/sh)"
        default: return "Stop can't terminate PHP on this server (no posix extension or shell)."
        }
    }

    private func row(_ title: String, _ value: String, state: CheckState) -> some View {
        LabeledContent(title) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: state.symbol)
                    .foregroundStyle(state.color)
            }
        }
    }

    static func isSupportedPHP(_ version: String) -> Bool {
        let parts = version.split(separator: ".").compactMap { part in Int(part.prefix { $0.isNumber }) }
        guard parts.count >= 2 else { return true }
        return (parts[0], parts[1]) >= (7, 4)
    }

    static func frameworkDescription(_ framework: String) -> String {
        if framework.hasPrefix("custom:") {
            return "Project driver: " + framework.dropFirst(7).replacingOccurrences(of: ",", with: ", ") + " (.runlet/)"
        }
        return switch framework {
        case "laravel": "Laravel"
        case "wordpress": "WordPress"
        case "symfony": "Symfony"
        case "composer": "Composer project"
        case "plain": "Plain PHP (no composer.json, framework, or .runlet driver here)"
        default: framework
        }
    }
}

extension SSHProfile {
    /// Defaults of a profile created with New SSH Profile….
    static func newDraft() -> SSHProfile {
        SSHProfile(name: "", host: "", remoteDirectory: "")
    }

    /// The profile as it is saved (see `SSHProfile.normalized`).
    var normalizedForSaving: SSHProfile { normalized }
}
