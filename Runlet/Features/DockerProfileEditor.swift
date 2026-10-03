import AppKit
import RunletCore
import RunletExecution
import SwiftUI

/// Sheet that creates or edits one saved Docker profile (target menu, ⇧⌘N, Settings ▸
/// Targets). The form itself is `DockerProfileForm`, which the Docker profile manager window
/// embeds as well. Nothing here runs a snippet.
struct DockerProfileEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var profile: DockerProfile
    var isNew: Bool
    var onSave: (DockerProfile) -> Void

    @State private var confirmingDelete = false

    var body: some View {
        VStack(spacing: 0) {
            DockerProfileHeader(title: isNew ? "New Docker Profile" : "Edit Docker Profile")
            Divider()
            DockerProfileForm(profile: $profile, isNew: isNew)
            Divider()
            footer
        }
        .frame(width: 780, height: 660)
        .confirmationDialog("Delete the profile “\(savedName)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Profile", role: .destructive) {
                model.removeDockerProfile(profile.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Tabs using this profile switch to the Laravel Sandbox. The container itself is not touched.")
        }
    }

    private var footer: some View {
        let errors = profile.normalizedForSaving.validate()
        return HStack {
            if !isNew {
                Button("Delete Profile…", role: .destructive) { confirmingDelete = true }
                    .accessibilityIdentifier("docker-delete-button")
            }
            Spacer()
            DockerProfileIssueCount(count: errors.count)
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("docker-cancel-button")
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!errors.isEmpty)
                .accessibilityIdentifier("docker-save-button")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var savedName: String {
        model.library.dockerProfile(profile.id)?.name ?? profile.name
    }

    /// Dismissing removes the form, which cancels a running connection test.
    private func save() {
        let result = profile.normalizedForSaving
        guard result.validate().isEmpty else { return }
        onSave(result)
        dismiss()
    }
}

/// Icon, title, and the "never runs code" reminder above a profile form.
struct DockerProfileHeader: View {
    var title: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cube.box")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Run snippets inside an existing container. Saving or opening a profile never runs code.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

/// "N issues to fix" next to a disabled Save button.
struct DockerProfileIssueCount: View {
    var count: Int

    var body: some View {
        if count > 0 {
            Text(count == 1 ? "1 issue to fix" : "\(count) issues to fix")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The profile editor's body: running containers on the left; name, execution settings,
/// code intelligence, and the connection test on the right. It edits `profile` in place and
/// never saves; the sheet or the manager window decides when. Give it a new identity
/// (`.id(profile.id)`) to edit another profile, so the container list state starts fresh.
/// Opening it lists containers (`docker ps`, `docker inspect`) but never execs into one: Test
/// Connection and Browse… are the only actions that do, and only when clicked.
struct DockerProfileForm: View {
    @Environment(AppModel.self) private var model
    @Binding var profile: DockerProfile
    /// Not saved yet: picking a container also fills in its working directory.
    var isNew: Bool
    var containerColumnWidth: CGFloat = 290
    /// Called after each container listing (the manager uses it for its status dots).
    var onContainersListed: () -> Void = {}

    // Container list
    @State private var selectedContainerId: String?
    @State private var search = ""
    @State private var isRefreshing = false
    @State private var hasLoaded = false
    @State private var listError: String?

    // Field defaults derived from the chosen container
    @State private var suggestions: [String] = []
    @State private var detectedDirectories: [String] = []
    @State private var autoName: String?
    @State private var autoUser: String?
    /// Local source filled in from the container's bind mount (replaced if the user picks another container).
    @State private var autoSource: String?
    @State private var workingDirectoryEdited = false

    // Connection test
    @State private var probe: ContainerProbe?
    @State private var probeContext: String?
    @State private var isProbing = false
    @State private var probeTask: Task<Void, Never>?

    // Browse… (the working directory inside the selected container)
    @State private var browseRequest: BrowseRequest?

    private static let commonDirectories = ["/var/www/html", "/var/www", "/app", "/srv/app", "/code", "/application"]

    var body: some View {
        HStack(spacing: 0) {
            containerColumn
                .frame(width: containerColumnWidth)
            Divider()
            form
        }
        .task { await initialLoad() }
        .onChange(of: model.dockerStatus) { _, status in
            if status.isAvailable, model.runningContainers.isEmpty, hasLoaded, !isRefreshing {
                Task { await refresh() }
            }
        }
        .onDisappear { probeTask?.cancel() }
        .sheet(item: $browseRequest) { request in directoryBrowser(request) }
        #if DEBUG
        // DEBUG step `docker-test` (DebugSteps.swift): Test Connection without a click, for screenshots.
        .onReceive(NotificationCenter.default.publisher(for: .debugDockerTestConnection)) { _ in
            if canProbe { runProbe() }
        }
        #endif
    }

    // MARK: Container list

    private var containerColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Running Containers").font(.headline)
                Spacer()
                if isRefreshing { ProgressView().controlSize(.small) }
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Refresh the list of running containers")
                .disabled(isRefreshing)
                .accessibilityIdentifier("docker-refresh-button")
            }
            TextField("Search", text: $search, prompt: Text("Search name, image, or project"))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("docker-container-search")
            if let savedIdentity, hasLoaded, !isRefreshing, !model.runningContainers.isEmpty, !isSavedRunning {
                Label {
                    Text("The saved container \(savedIdentity.displayName) is not running. Start it and click Refresh; the saved identity is kept.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "moon.zzz")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            List(selection: listSelection) {
                ForEach(containerGroups) { group in
                    Section {
                        ForEach(group.containers) { container in
                            DockerEditorContainerRow(container: container, isSaved: matchesSavedIdentity(container))
                                .tag(container.id)
                        }
                    } header: {
                        Label(group.title, systemImage: group.isCompose ? "square.stack.3d.up" : "shippingbox")
                    }
                }
            }
            .listStyle(.inset)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay { emptyState }
            .accessibilityIdentifier("docker-container-list")
            if case .available(let version) = model.dockerStatus {
                Text("Docker \(version) · \(model.runningContainers.count) running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var emptyState: some View {
        if !model.runningContainers.isEmpty {
            if containerGroups.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        } else if isRefreshing || !hasLoaded {
            ProgressView()
        } else if case .unavailable(let reason) = model.dockerStatus {
            ContentUnavailableView {
                Label("Docker Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text("\(reason)\n\nStart Docker (or set the Docker CLI path in Settings), then click Refresh.")
            } actions: {
                Button("Refresh") { Task { await refresh() } }
            }
        } else if let listError {
            ContentUnavailableView {
                Label("Couldn’t List Containers", systemImage: "exclamationmark.triangle")
            } description: {
                Text(listError)
            } actions: {
                Button("Refresh") { Task { await refresh() } }
            }
        } else {
            ContentUnavailableView(
                "No Running Containers",
                systemImage: "shippingbox",
                description: Text("Start your application (for example `sail up -d` or `docker compose up -d`), then click Refresh.")
            )
        }
    }

    private struct ContainerGroup: Identifiable {
        var id: String
        var title: String
        var isCompose: Bool
        var containers: [ContainerInfo]
    }

    private var containerGroups: [ContainerGroup] {
        let visible = model.runningContainers.filter { container in
            matchesSearch(search, in: container.name, container.image, container.composeProject ?? "", container.composeService ?? "", container.shortId)
        }
        let grouped = Dictionary(grouping: visible) { $0.composeProject }
        var groups: [ContainerGroup] = grouped.compactMap { project, containers in
            guard let project else { return nil }
            return ContainerGroup(id: "compose:\(project)", title: project, isCompose: true, containers: containers.sorted(by: Self.containerOrder))
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if let standalone = grouped[String?.none], !standalone.isEmpty {
            groups.append(ContainerGroup(id: "standalone", title: "Other Containers", isCompose: false, containers: standalone.sorted(by: Self.containerOrder)))
        }
        return groups
    }

    private static func containerOrder(_ lhs: ContainerInfo, _ rhs: ContainerInfo) -> Bool {
        let left = lhs.composeService ?? lhs.name
        let right = rhs.composeService ?? rhs.name
        if left != right { return left.localizedStandardCompare(right) == .orderedAscending }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private var selectedContainer: ContainerInfo? {
        guard let selectedContainerId else { return nil }
        return model.runningContainers.first { $0.id == selectedContainerId }
    }

    /// User selection applies the container to the profile; programmatic preselection
    /// (writing `selectedContainerId` directly) does not.
    private var listSelection: Binding<String?> {
        Binding(
            get: { selectedContainerId },
            set: { id in
                guard id != selectedContainerId else { return }
                selectedContainerId = id
                if let id, let container = model.runningContainers.first(where: { $0.id == id }) {
                    choose(container)
                }
            }
        )
    }

    private func matchesSavedIdentity(_ container: ContainerInfo) -> Bool {
        guard let saved = savedIdentity else { return false }
        if let project = saved.composeProject, let service = saved.composeService {
            return container.composeProject == project && container.composeService == service
        }
        return container.id == saved.lastContainerId || (saved.containerName != nil && container.name == saved.containerName)
    }

    private var isSavedRunning: Bool {
        model.runningContainers.contains { matchesSavedIdentity($0) }
    }

    // MARK: Form

    private var form: some View {
        Form {
            Section {
                field("Name", error: .emptyName) {
                    TextField("Name", text: $profile.name, prompt: Text("e.g. Billing API"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("docker-profile-name")
                }
                field("Container", error: .missingIdentity) {
                    identitySummary
                }
            } header: {
                Text("Profile")
            } footer: {
                Text("The profile identifies its container by Compose project and service labels when available, so it survives the container being recreated (with a container-name fallback otherwise). Runlet never silently switches containers: if the match is unclear, you’re asked to choose.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Inside the Container") {
                field("Working directory", error: .relativeWorkingDirectory, help: "The directory containing the application and its installed dependencies. Browse… lists folders inside the selected container (folder names only; nothing runs or is written). Symlinks are kept as chosen.") {
                    HStack(spacing: 6) {
                        TextField("Working directory", text: workingDirectoryBinding, prompt: Text("/var/www/html"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("docker-working-directory")
                        suggestionsMenu
                        Button("Browse…") { browse() }
                            .disabled(!canBrowse)
                            .help(browseHelp)
                            .accessibilityIdentifier("docker-browse-directory")
                    }
                }
                field("PHP executable", error: .emptyPHP) {
                    TextField("PHP executable", text: $profile.phpExecutable, prompt: Text("php"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("docker-php-executable")
                }
                field("Execution user", error: .invalidUser, help: "Optional, e.g. sail or 1000:1000. Blank uses the container’s default user.") {
                    TextField("Execution user", text: optionalBinding(\.user), prompt: Text("Container default"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("docker-user")
                }
                field("Temporary directory", error: .relativeTemporaryDirectory, help: "Writable directory exported as TMPDIR for each run (sys_get_temp_dir()). Runlet itself writes no files into the container.") {
                    TextField("Temporary directory", text: $profile.temporaryDirectory, prompt: Text("/tmp"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("docker-temp-directory")
                }
                field("Strict types", help: "Whether runs in this container declare strict_types=1. Default follows Settings ▸ General ▸ Running.") {
                    StrictTypesPicker(selection: $profile.strictTypes)
                        .labelsHidden()
                        .accessibilityIdentifier("docker-strict-types")
                }
                field("Mail", help: "Whether runs in this container record mail without sending it. Default follows Settings ▸ General ▸ Run Inspector.") {
                    MailInterceptionPicker(selection: $profile.interceptMail)
                        .labelsHidden()
                        .accessibilityIdentifier("docker-intercept-mail")
                }
            }

            Section("Code Intelligence") {
                field("Local source", help: "Optional host checkout of the same application. It powers PHPantom completion for your project’s classes; without it only basic PHP completion is available.") {
                    HStack(spacing: 6) {
                        Text(profile.localSourcePath ?? "None")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(profile.localSourcePath == nil ? .secondary : .primary)
                            .help(profile.localSourcePath ?? "No local source mapping")
                            .textSelection(.enabled)
                        Spacer(minLength: 4)
                        Button("Choose…") {
                            if let url = FilePanels.chooseDirectory(message: "Choose the local checkout of this application’s source", start: profile.localSourcePath) {
                                profile.localSourcePath = url.standardizedFileURL.path
                            }
                        }
                        .accessibilityIdentifier("docker-local-source-choose")
                        if profile.localSourcePath != nil {
                            Button("Clear") { profile.localSourcePath = nil }
                                .accessibilityIdentifier("docker-local-source-clear")
                        }
                    }
                }
                field("PHP version", help: "PHP version used for completion, e.g. 8.2. Blank infers it from composer.json.") {
                    TextField("PHP version for completion", text: optionalBinding(\.languagePHPVersion), prompt: Text("Infer"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("docker-language-php-version")
                }
            }

            Section("Environment") {
                TargetEnvironmentFields(environment: $profile.environment.orDevelopment, color: $profile.color)
            }

            Section {
                Toggle("Resolve container when opening this profile (never runs code)", isOn: $profile.autoResolve)
                    .accessibilityIdentifier("docker-auto-resolve")
                testRow
                if let probe {
                    probeResults(probe)
                }
            } header: {
                Text("Connection")
            }
        }
        .formStyle(.grouped)
    }

    private func field<Content: View>(_ title: String, error: DockerProfile.ValidationError? = nil, help: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        LabeledContent {
            VStack(alignment: .leading, spacing: 4) {
                content()
                if let error, errors.contains(error) {
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
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title)
        }
    }

    @ViewBuilder
    private var identitySummary: some View {
        let identity = profile.identity
        if !Self.hasIdentity(identity) {
            Text("None — select a running container on the left.")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(identity.displayName)
                    .fontWeight(.medium)
                    .textSelection(.enabled)
                Text(Self.identityDetail(identity))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if hasLoaded {
                    identityStatus(identity)
                }
            }
        }
    }

    @ViewBuilder
    private func identityStatus(_ identity: ContainerIdentity) -> some View {
        switch DockerProfileResolver.resolve(identity, among: model.runningContainers) {
        case .resolved(let container, let recreated):
            Label(recreated ? "Running (recreated since last use, now \(container.shortId))" : "Running", systemImage: "circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .ambiguous(let matches):
            Label("\(matches.count) running replicas match. Select one on the left.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .needsConfirmation(let container, _):
            Label("A different container (\(container.shortId)) now uses this name. Select it on the left to confirm it is the same application.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .notRunning:
            Label("Not running. The saved identity is kept.", systemImage: "moon.zzz")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var suggestionsMenu: some View {
        Menu {
            if !detectedDirectories.isEmpty {
                Section("Contains composer.json or artisan") {
                    ForEach(detectedDirectories, id: \.self) { directory in
                        suggestionButton(directory)
                    }
                }
            }
            Section(suggestions.isEmpty ? "Common locations" : "From container metadata") {
                ForEach(menuSuggestions.filter { !detectedDirectories.contains($0) }, id: \.self) { directory in
                    suggestionButton(directory)
                }
            }
        } label: {
            Label("Suggestions", systemImage: "list.bullet")
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Suggested working directories")
        .accessibilityIdentifier("docker-working-directory-suggestions")
    }

    private func suggestionButton(_ directory: String) -> some View {
        Button {
            profile.workingDirectory = directory
            workingDirectoryEdited = true
        } label: {
            if directory == profile.workingDirectory {
                Label(directory, systemImage: "checkmark")
            } else {
                Text(directory)
            }
        }
    }

    private var menuSuggestions: [String] {
        suggestions.isEmpty ? Self.commonDirectories : suggestions
    }

    // MARK: Browse…

    /// Browse… needs Docker, a running container selected on the left, and the PHP and user it
    /// lists with (the profile's, so permissions match runs).
    private var canBrowse: Bool {
        model.docker != nil && selectedContainer != nil
            && !errors.contains(.emptyPHP) && !errors.contains(.invalidUser)
    }

    private var browseHelp: String {
        if model.docker == nil { return "Docker is unavailable." }
        if selectedContainer == nil { return "Select a running container on the left to browse its folders." }
        if !canBrowse { return "Fix the PHP executable and execution user first: Browse… lists folders with them." }
        return "Choose the folder inside the selected container (lists folder names with the profile's PHP and user; nothing is written)"
    }

    /// What Browse… lists with, fixed when it is clicked: the selected container, the
    /// profile's identity, and the PHP and user runs would use.
    private struct BrowseRequest: Identifiable {
        let id = UUID()
        var docker: DockerCLI
        var container: ContainerInfo
        var identity: ContainerIdentity
        var user: String?
        var phpExecutable: String
        var startPath: String
    }

    private func browse() {
        guard canBrowse, let docker = model.docker, let container = selectedContainer else { return }
        let target = normalizedProfile
        browseRequest = BrowseRequest(docker: docker, container: container, identity: target.identity, user: target.user, phpExecutable: target.phpExecutable, startPath: Self.browseStart(target.workingDirectory, container: container))
    }

    /// The folder picker over the selected container. Every listing checks that container again
    /// (`DockerCLI.listProfileDirectory`): a stopped, removed, or recreated container is
    /// reported, or followed only where a run would follow it (a recreated Compose service).
    private func directoryBrowser(_ request: BrowseRequest) -> some View {
        RemoteDirectoryBrowser(place: request.container.name, startPath: request.startPath, preposition: "in") { path in
            await request.docker.listProfileDirectory(selectedId: request.container.id, identity: request.identity, user: request.user, phpExecutable: request.phpExecutable, path: path)
        } choose: { path in
            // Kept exactly as listed: absolute, symlinks not resolved.
            profile.workingDirectory = path
            workingDirectoryEdited = true
        }
    }

    /// Browse… starts in the typed working directory when it is absolute, else in the
    /// container's own working directory, else at /.
    static func browseStart(_ workingDirectory: String, container: ContainerInfo) -> String {
        if workingDirectory.hasPrefix("/") { return workingDirectory }
        if container.workingDir.hasPrefix("/") { return container.workingDir }
        return "/"
    }

    // MARK: Connection test

    private var testRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    runProbe()
                } label: {
                    Label("Test Connection", systemImage: "bolt.horizontal")
                }
                .disabled(!canProbe)
                .accessibilityIdentifier("docker-test-button")
                if isProbing {
                    ProgressView().controlSize(.small)
                    Text("Probing the container…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.docker == nil {
                    Text("Docker is unavailable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if selectedContainer == nil {
                    Text("Select a running container to test.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text("Runs a short read-only PHP check inside the container. Your snippet is not run.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var canProbe: Bool {
        model.docker != nil && selectedContainer != nil && !isProbing
            && !errors.contains(.emptyPHP) && !errors.contains(.invalidUser)
    }

    private func runProbe() {
        guard let docker = model.docker, let container = selectedContainer else { return }
        let target = normalizedProfile
        let candidates = menuSuggestions
        probeTask?.cancel()
        probe = nil
        probeContext = "\(container.name) as \(target.user ?? "the default user") in \(target.workingDirectory)"
        isProbing = true
        probeTask = Task {
            let result = await docker.probe(
                containerId: container.id,
                phpExecutable: target.phpExecutable,
                user: target.user,
                workingDirectory: target.workingDirectory,
                temporaryDirectory: target.temporaryDirectory,
                extraCandidates: candidates
            )
            guard !Task.isCancelled else { return }
            probe = result
            isProbing = false
            // Profile Run's availability, when the probe checked the saved profile's PHP.
            if let saved = model.library.dockerProfile(target.id), saved.phpExecutable == target.phpExecutable, saved.user == target.user {
                model.noteProfilers(result.profilers, for: .docker(target.id))
            }
            detectedDirectories = result.candidates
            for candidate in result.candidates where !suggestions.contains(candidate) {
                suggestions.append(candidate)
            }
        }
    }

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

    @ViewBuilder
    private func probeResults(_ probe: ContainerProbe) -> some View {
        if let probeContext {
            Text("Results for \(probeContext)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let error = probe.error {
            LabeledContent {
                VStack(alignment: .leading, spacing: 4) {
                    Text(error)
                        .font(.callout.monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Check the PHP executable, execution user, and that the container is still running.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Error", systemImage: CheckState.failure.symbol)
                    .foregroundStyle(CheckState.failure.color)
            }
        }
        if let version = probe.phpVersion {
            let supported = Self.isSupportedPHP(version)
            resultRow("PHP", value: supported ? version + (probe.phpBinary.map { " · \($0)" } ?? "") : "\(version) is older than Runlet’s minimum (7.4)", state: supported ? .ok : .failure)
            resultRow("User", value: Self.userDescription(probe), state: .info)
            resultRow("Framework", value: Self.frameworkDescription(probe.framework), state: probe.framework == "plain" ? .warning : .ok)
            resultRow(
                "Working directory",
                value: !probe.workingDirectoryExists ? "Does not exist" : (probe.workingDirectoryReadable ? "Exists and is readable" : "Exists but is not readable by this user"),
                state: probe.workingDirectoryExists && probe.workingDirectoryReadable ? .ok : .failure
            )
            resultRow("Temporary directory", value: probe.temporaryDirectoryWritable ? "Writable" : "Not writable by this user", state: probe.temporaryDirectoryWritable ? .ok : .failure)
            resultRow("Tokenizer", value: probe.hasTokenizer ? "Available" : "Missing; Runlet’s runner needs the tokenizer extension", state: probe.hasTokenizer ? .ok : .failure)
            resultRow("Stop", value: Self.signalDescription(probe.canSignal), state: probe.canSignal == "none" ? .warning : .ok)
            if let profilers = probe.profilers {
                resultRow("Profilers", value: ProfilerText.probeDescription(profilers), state: profilers.canProfile ? .ok : .info)
            }
            let otherCandidates = probe.candidates.filter { $0 != normalizedProfile.workingDirectory }
            if !otherCandidates.isEmpty {
                LabeledContent("Applications found") {
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(otherCandidates, id: \.self) { candidate in
                            Button("Use \(candidate)") {
                                profile.workingDirectory = candidate
                                workingDirectoryEdited = true
                            }
                        }
                    }
                }
            }
        }
    }

    private func resultRow(_ title: String, value: String, state: CheckState) -> some View {
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

    private static func isSupportedPHP(_ version: String) -> Bool {
        let parts = version.split(separator: ".").compactMap { part in Int(part.prefix { character in character.isNumber }) }
        guard parts.count >= 2 else { return true }
        return (parts[0], parts[1]) >= (7, 4)
    }

    private static func userDescription(_ probe: ContainerProbe) -> String {
        switch (probe.user, probe.uid) {
        case (let user?, let uid?): "\(user) (uid \(uid))"
        case (nil, let uid?): "uid \(uid)"
        case (let user?, nil): user
        case (nil, nil): "Unknown (the posix extension is not available)"
        }
    }

    private static func frameworkDescription(_ framework: String) -> String {
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

    private static func signalDescription(_ capability: String) -> String {
        switch capability {
        case "posix": "Supported (posix_kill)"
        case "shell": "Supported (through /bin/sh)"
        case "none": "Stop can’t terminate PHP inside this container (no posix extension or shell). A running snippet continues until it finishes."
        default: capability
        }
    }

    // MARK: State helpers

    /// The container identity saved in the library; nil while the profile is not saved yet.
    private var savedIdentity: ContainerIdentity? {
        guard let identity = model.library.dockerProfile(profile.id)?.identity, Self.hasIdentity(identity) else { return nil }
        return identity
    }

    private var workingDirectoryBinding: Binding<String> {
        Binding(
            get: { profile.workingDirectory },
            set: { value in
                profile.workingDirectory = value
                workingDirectoryEdited = true
            }
        )
    }

    private func optionalBinding(_ keyPath: WritableKeyPath<DockerProfile, String?>) -> Binding<String> {
        Binding(
            get: { profile[keyPath: keyPath] ?? "" },
            set: { value in profile[keyPath: keyPath] = value.isEmpty ? nil : value }
        )
    }

    /// The profile as it would be saved (whitespace trimmed, blank optionals cleared).
    private var normalizedProfile: DockerProfile {
        profile.normalizedForSaving
    }

    private var errors: [DockerProfile.ValidationError] {
        normalizedProfile.validate()
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func hasIdentity(_ identity: ContainerIdentity) -> Bool {
        identity.composeService != nil || identity.containerName != nil
    }

    private static func identityDetail(_ identity: ContainerIdentity) -> String {
        var parts: [String] = []
        if let project = identity.composeProject, let service = identity.composeService {
            parts.append("Compose project \(project), service \(service)")
        } else if let name = identity.containerName {
            parts.append("Container name \(name) (no Compose labels)")
        }
        var last: [String] = []
        if let id = identity.lastContainerId { last.append(String(id.prefix(12))) }
        if let image = identity.lastImage, !image.isEmpty { last.append(image) }
        if !last.isEmpty { parts.append("Last seen: " + last.joined(separator: " · ")) }
        return parts.joined(separator: "\n")
    }

    // MARK: Actions

    private func initialLoad() async {
        guard !hasLoaded else { return }
        await refresh()
        hasLoaded = true
        preselectContainer()
    }

    private func refresh() async {
        isRefreshing = true
        let previousAlert = model.alert?.id
        await model.refreshContainers()
        // Show listing failures inline instead of as an alert behind this sheet or window.
        if let alert = model.alert, alert.id != previousAlert, alert.title.hasPrefix("Could not list containers") {
            listError = alert.message
            model.alert = nil
        } else {
            listError = nil
        }
        isRefreshing = false
        onContainersListed()
        if hasLoaded {
            if selectedContainer == nil { selectedContainerId = nil }
            preselectContainer()
        }
    }

    /// Selects the running container that matches the profile's identity without changing
    /// the profile. Ambiguous or unconfirmed matches are left for the user to choose.
    private func preselectContainer() {
        guard selectedContainerId == nil, Self.hasIdentity(profile.identity) else { return }
        if case .resolved(let container, _) = DockerProfileResolver.resolve(profile.identity, among: model.runningContainers) {
            selectedContainerId = container.id
            suggestions = DockerCLI.workingDirectorySuggestions(for: container)
        }
    }

    private func choose(_ container: ContainerInfo) {
        profile.identity = container.identity

        let suggestedName = container.composeService ?? container.name
        let currentName = Self.trimmed(profile.name)
        if currentName.isEmpty || currentName == autoName {
            profile.name = suggestedName
            autoName = suggestedName
        }

        let currentUser = profile.user ?? ""
        if currentUser.isEmpty || currentUser == autoUser {
            let containerUser = container.user.isEmpty ? nil : container.user
            profile.user = containerUser
            autoUser = containerUser
        }

        suggestions = DockerCLI.workingDirectorySuggestions(for: container)
        detectedDirectories = []
        if isNew, !workingDirectoryEdited, !container.workingDir.isEmpty, container.workingDir != "/" {
            profile.workingDirectory = container.workingDir
        }

        // Local source for completion: the host folder bind-mounted at the working directory.
        let currentSource = profile.localSourcePath ?? ""
        if currentSource.isEmpty || currentSource == autoSource {
            if let host = container.hostPath(forContainerPath: profile.workingDirectory), FileManager.default.fileExists(atPath: host) {
                profile.localSourcePath = host
                autoSource = host
            } else if currentSource == autoSource {
                profile.localSourcePath = nil
                autoSource = nil
            }
        }

        probeTask?.cancel()
        probe = nil
        probeContext = nil
        isProbing = false
    }
}

extension DockerProfile {
    /// Defaults of a profile created with New Docker Profile (sheet or manager window).
    static func newDraft() -> DockerProfile {
        DockerProfile(name: "", identity: ContainerIdentity(), workingDirectory: "/var/www/html")
    }

    /// The profile as it is saved: whitespace trimmed, blank optional fields cleared.
    var normalizedForSaving: DockerProfile {
        func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
        var result = self
        result.name = trimmed(result.name)
        result.workingDirectory = trimmed(result.workingDirectory)
        result.phpExecutable = trimmed(result.phpExecutable)
        result.temporaryDirectory = trimmed(result.temporaryDirectory)
        result.user = result.user.map(trimmed).flatMap { $0.isEmpty ? nil : $0 }
        result.languagePHPVersion = result.languagePHPVersion.map(trimmed).flatMap { $0.isEmpty ? nil : $0 }
        result.localSourcePath = result.localSourcePath.flatMap { $0.isEmpty ? nil : $0 }
        return result
    }
}

/// One running container in the editor's list.
private struct DockerEditorContainerRow: View {
    let container: ContainerInfo
    let isSaved: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(container.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isSaved {
                    Text("Saved")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.tint.opacity(0.2)))
                }
            }
            if let project = container.composeProject, let service = container.composeService {
                Text("\(project) / \(service)")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(container.image)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(container.shortId) · \(container.status)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .help("\(container.name)\n\(container.image)")
        .accessibilityElement(children: .combine)
    }
}
