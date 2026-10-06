import RunletCore
import RunletExecution
import SwiftUI

/// "Docker on This Host" in the SSH profile form: the optional container step. Choosing a
/// container lists the server's containers (an explicit List Containers, over the profile's
/// SSH connection); the step keeps the container's Compose project and service (or its name),
/// so runs find it again after it is recreated and ask when the match is unclear.
struct SSHContainerStepSection: View {
    @Environment(AppModel.self) private var model
    @Binding var profile: SSHProfile

    @State private var picking = false
    @State private var browsing = false
    /// Working directories suggested by the chosen container (its own and its mounts).
    @State private var suggestions: [String] = []
    /// The step that was switched off, restored when it is switched on again.
    @State private var parkedStep: RemoteContainerStep?

    var body: some View {
        Section {
            Toggle(isOn: enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run inside a Docker container on this host")
                    Text("Runs use `docker exec` into a container on the server, through this SSH connection, instead of the server's own PHP.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityIdentifier("ssh-container-enabled")
            if let step = profile.container {
                field("Container", errors: [.missingContainer]) {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.hasIdentity ? step.identity.displayName : "None chosen")
                                .fontWeight(step.hasIdentity ? .medium : .regular)
                                .foregroundStyle(step.hasIdentity ? .primary : .secondary)
                                .textSelection(.enabled)
                            if step.hasIdentity {
                                Text(Self.identityDetail(step.identity))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 4)
                        Button("List Containers…") { picking = true }
                            .disabled(!canReachServer)
                            .help("List the running containers on the server (docker ps over SSH) and choose one")
                            .accessibilityIdentifier("ssh-container-choose")
                    }
                }
                field("Working directory", errors: [.relativeContainerDirectory], help: "The application's directory inside the container.") {
                    HStack(spacing: 6) {
                        TextField("Working directory", text: stepBinding(\.workingDirectory, default: "/var/www/html"), prompt: Text("Absolute path in the container"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("ssh-container-directory")
                        if !suggestions.isEmpty {
                            Menu {
                                ForEach(suggestions, id: \.self) { directory in
                                    Button(directory) { profile.container?.workingDirectory = directory }
                                }
                            } label: {
                                Label("Suggestions", systemImage: "list.bullet")
                            }
                            .labelStyle(.iconOnly)
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Directories from the container's settings and mounts")
                        }
                        Button("Browse…") { browsing = true }
                            .disabled(!canReachServer || !step.hasIdentity)
                            .help("Pick the folder inside the container (lists folder names; nothing is written)")
                            .accessibilityIdentifier("ssh-container-browse")
                    }
                }
                field("PHP executable", errors: [.invalidContainerPHP]) {
                    TextField("PHP executable", text: stepBinding(\.phpExecutable, default: "php"), prompt: Text("php"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("ssh-container-php")
                }
                field("Execution user", errors: [.invalidContainerUser], help: "Optional, such as www-data or 1000:1000. Blank uses the container's default user.") {
                    TextField("Execution user", text: userBinding, prompt: Text("Container default"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("ssh-container-user")
                }
                field("Temporary directory", errors: [.relativeContainerTemporaryDirectory], help: "Exported as TMPDIR for each run. Runlet itself writes nothing in the container.") {
                    TextField("Temporary directory", text: stepBinding(\.temporaryDirectory, default: "/tmp"), prompt: Text("/tmp"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("ssh-container-tmp")
                }
                field("Docker command", errors: [.invalidDockerCommand], help: "How the server calls Docker: docker, an absolute path, or sudo -n docker (passwordless sudo only; runs can't answer a sudo prompt).") {
                    TextField("Docker command", text: stepBinding(\.dockerCommand, default: "docker"), prompt: Text("docker"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("ssh-container-docker-command")
                }
            }
        } header: {
            Text("Docker on This Host")
        } footer: {
            if profile.container != nil {
                Text("Runlet finds the container by its Compose project and service (or its name) each time it runs, and never switches containers silently: if several match or the container was replaced, it asks. File links map container paths to the local folder through the server directory's bind mount.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $picking) {
            let snapshot = profile.normalizedForSaving
            let dockerCommand = snapshot.container?.dockerCommand ?? "docker"
            RemoteContainerPicker(place: snapshot.destinationLabel, current: snapshot.container?.identity) {
                try await model.listRemoteContainers(snapshot, dockerCommand: dockerCommand)
            } choose: { container in
                choose(container)
            }
        }
        .sheet(isPresented: $browsing) {
            let snapshot = profile.normalizedForSaving
            if let step = snapshot.container {
                RemoteDirectoryBrowser(place: "\(step.identity.displayName) on \(snapshot.host)", startPath: step.workingDirectory, preposition: "in") { path in
                    await model.listContainerDirectory(snapshot, step: step, path: path)
                } choose: { path in
                    profile.container?.workingDirectory = path
                }
            }
        }
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { profile.container != nil },
            set: { on in
                if on {
                    profile.container = parkedStep ?? RemoteContainerStep()
                } else {
                    parkedStep = profile.container
                    profile.container = nil
                }
            }
        )
    }

    /// Listing containers needs a host ssh can reach.
    private var canReachServer: Bool {
        !profile.validate().contains(where: SSHProfile.ValidationError.connectionErrors.contains)
    }

    /// Applies a chosen container (`SSHProfile.choosingContainer`): its identity, and its
    /// working directory and user unless they were set. One write, so nothing it fills in can
    /// replace another when SwiftUI calls this during a view update (#318).
    private func choose(_ container: ContainerInfo) {
        guard profile.container != nil else { return }
        profile = profile.choosingContainer(container)
        suggestions = DockerCLI.workingDirectorySuggestions(for: container)
    }

    private func stepBinding(_ keyPath: WritableKeyPath<RemoteContainerStep, String>, default value: String) -> Binding<String> {
        Binding(
            get: { profile.container?[keyPath: keyPath] ?? value },
            set: { profile.container?[keyPath: keyPath] = $0 }
        )
    }

    private var userBinding: Binding<String> {
        Binding(
            get: { profile.container?.user ?? "" },
            set: { profile.container?.user = $0.isEmpty ? nil : $0 }
        )
    }

    static func identityDetail(_ identity: ContainerIdentity) -> String {
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

    private func field<Content: View>(_ title: String, errors: [SSHProfile.ValidationError], help: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        LabeledContent {
            VStack(alignment: .leading, spacing: 4) {
                content()
                if let error = profile.validate().first(where: errors.contains) {
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
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title)
        }
    }
}

/// List Containers…: the running containers on an SSH host, grouped by Compose project, to
/// choose a profile's container step. Lists only when opened (and on Refresh).
struct RemoteContainerPicker: View {
    @Environment(\.dismiss) private var dismiss
    let place: String
    let current: ContainerIdentity?
    let load: () async throws -> [ContainerInfo]
    let choose: (ContainerInfo) -> Void

    @State private var containers: [ContainerInfo] = []
    @State private var error: String?
    @State private var isLoading = false
    @State private var selection: String?
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Containers on \(place)").font(.headline)
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                Button {
                    refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .disabled(isLoading)
                .help("List the running containers again")
            }
            TextField("Search", text: $search, prompt: Text("Search name, image, or project"))
                .textFieldStyle(.roundedBorder)
            List(selection: $selection) {
                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.containers) { container in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(container.name).fontWeight(.medium)
                                    if matchesCurrent(container) {
                                        Text("Current")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Capsule().fill(.tint.opacity(0.2)))
                                    }
                                }
                                Text("\(container.image) · \(container.shortId) · \(container.workingDir.isEmpty ? "/" : container.workingDir)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .tag(container.id)
                            .accessibilityIdentifier("remote-container-\(container.name)")
                        }
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 240)
            .contextMenu(forSelectionType: String.self) { _ in
            } primaryAction: { ids in
                if let id = ids.first, let container = containers.first(where: { $0.id == id }) {
                    choose(container)
                    dismiss()
                }
            }
            .overlay { emptyState }
            .accessibilityIdentifier("remote-container-list")
            Text("Runlet keeps the container's Compose project and service (or its name), never its ID, so the profile follows the container when it is recreated.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Use This Container") {
                    if let id = selection, let container = containers.first(where: { $0.id == id }) {
                        choose(container)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
                .accessibilityIdentifier("remote-container-use")
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
        .onAppear(perform: refresh)
    }

    @ViewBuilder
    private var emptyState: some View {
        if isLoading, containers.isEmpty {
            ProgressView("Listing containers on \(place)…")
        } else if let error {
            ContentUnavailableView {
                Label("Couldn't List Containers", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error).textSelection(.enabled)
            } actions: {
                Button("Try Again", action: refresh)
            }
        } else if containers.isEmpty, !isLoading {
            ContentUnavailableView("No Running Containers", systemImage: "shippingbox", description: Text("Start the application's containers on the server, then click Refresh."))
        } else if groups.isEmpty, !search.isEmpty {
            ContentUnavailableView.search(text: search)
        }
    }

    private var groups: [(title: String, containers: [ContainerInfo])] {
        let visible = containers.filter { matchesSearch(search, in: $0.name, $0.image, $0.composeProject ?? "", $0.composeService ?? "") }
        let grouped = Dictionary(grouping: visible) { $0.composeProject ?? "" }
        return grouped.keys.sorted { lhs, rhs in
            if lhs.isEmpty != rhs.isEmpty { return !lhs.isEmpty }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }.map { key in
            (key.isEmpty ? "Other Containers" : key, (grouped[key] ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
    }

    private func matchesCurrent(_ container: ContainerInfo) -> Bool {
        guard let current else { return false }
        if let project = current.composeProject, let service = current.composeService {
            return container.composeProject == project && container.composeService == service
        }
        return current.containerName != nil && container.name == current.containerName
    }

    private func refresh() {
        isLoading = true
        Task {
            do {
                containers = try await load()
                error = nil
            } catch {
                self.error = "\(error)"
                containers = []
            }
            isLoading = false
            if selection == nil, let match = containers.first(where: matchesCurrent) { selection = match.id }
        }
    }
}

/// Test Connection's result for the container step: the container it found and the probe
/// inside it, or why it couldn't check.
struct RemoteContainerCheckResults: View {
    let check: RemoteContainerCheck

    var body: some View {
        if let problem = check.problem {
            LabeledContent {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Container", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .accessibilityIdentifier("ssh-container-problem")
        }
        if let container = check.container {
            row("Container", "\(container.name) · \(container.image) · \(container.shortId)", ok: true)
        }
        if let probe = check.probe {
            if let error = probe.error {
                LabeledContent {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("In the container", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
            } else if let version = probe.phpVersion {
                row("Container PHP", version + (probe.phpBinary.map { " · \($0)" } ?? ""), ok: SSHProbeResults.isSupportedPHP(version))
                row("Container user", [probe.user, probe.uid.map { "uid \($0)" }].compactMap { $0 }.joined(separator: " · "), ok: true)
                row("Working directory", probe.workingDirectoryExists ? (probe.workingDirectoryReadable ? "Exists and is readable" : "Not readable by this user") : "Does not exist", ok: probe.workingDirectoryExists && probe.workingDirectoryReadable)
                row("Framework", SSHProbeResults.frameworkDescription(probe.framework), ok: probe.framework != "plain")
                row("Temporary directory", probe.temporaryDirectoryWritable ? "Writable" : "Not writable by this user", ok: probe.temporaryDirectoryWritable)
                row("Stop", probe.canSignal == "none" ? "Can't signal PHP in this container" : "Supported (\(probe.canSignal))", ok: probe.canSignal != "none")
            }
        }
    }

    private func row(_ title: String, _ value: String, ok: Bool) -> some View {
        LabeledContent(title) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? .green : .orange)
            }
        }
    }
}
