import AppKit
import Observation
import RunletCore
import RunletExecution
import SwiftUI

/// What the Profiles window should do when it opens or comes forward: select a profile, or
/// start importing hosts from `~/.ssh/config`.
struct ProfileManagerRequest: Equatable {
    let id = UUID()
    var select: TargetRef?
    var importSSHHosts = false
}

/// The pending request for the Profiles window (one per app model).
@MainActor
@Observable
final class ProfileManagerRequests {
    var pending: ProfileManagerRequest?

    private static var stores: [ObjectIdentifier: ProfileManagerRequests] = [:]

    static func shared(for model: AppModel) -> ProfileManagerRequests {
        let key = ObjectIdentifier(model)
        if let store = stores[key] { return store }
        let store = ProfileManagerRequests()
        stores[key] = store
        return store
    }
}

extension AppModel {
    var profileManagerRequests: ProfileManagerRequests { ProfileManagerRequests.shared(for: self) }

    /// Opens the Profiles window, or brings it forward when it is already open.
    func showDockerProfileManager() {
        showProfileManager()
    }

    /// Opens the Profiles window on `target` (a Docker or SSH profile), or with the
    /// `~/.ssh/config` import sheet.
    func showProfileManager(selecting target: TargetRef? = nil, importSSHHosts: Bool = false) {
        if target != nil || importSSHHosts {
            profileManagerRequests.pending = ProfileManagerRequest(select: target, importSSHHosts: importSSHHosts)
        }
        openSingleWindowAction?(ProfileManager.sceneId)
    }
}

/// Library ▸ Manage Profiles…: one window for every saved Docker and SSH profile. The list on
/// the right (Docker profiles, then SSH hosts) switches between profiles and creates (+),
/// duplicates, and deletes (−) them, and imports hosts from `~/.ssh/config`; the rest of the
/// window edits the selected profile with the same form as its sheet.
///
/// Editing is explicit, as in the sheets: the form changes a draft, Save (↩ or ⌘S) writes it
/// once it validates, and Revert goes back to the saved values. Switching profiles, creating
/// or duplicating one, importing, or closing the window while the draft has unsaved changes
/// asks Save / Don't Save / Cancel (a draft with issues can only be discarded or kept). A new
/// profile is only a draft until it is saved. Deleting goes through
/// `AppModel.confirmDeleteTarget`, so tabs using the profile switch to the sandbox exactly as
/// from the target menu. Nothing here runs code: the Docker form lists containers and offers
/// a read-only Test; the SSH form connects only for Test Connection, Detect, Browse…, List
/// Containers…, and Connect….
struct ProfileManager: View {
    /// Kept from the Docker-only window so restored windows keep their place.
    static let sceneId = "docker-profiles"

    enum Kind: Equatable {
        case docker, ssh
    }

    /// The profile being edited.
    enum Draft: Equatable {
        case docker(DockerProfile)
        case ssh(SSHProfile)

        var id: UUID {
            switch self {
            case .docker(let profile): profile.id
            case .ssh(let profile): profile.id
            }
        }

        var kind: Kind {
            if case .docker = self { return .docker }
            return .ssh
        }

        var target: TargetRef {
            switch self {
            case .docker(let profile): .docker(profile.id)
            case .ssh(let profile): .ssh(profile.id)
            }
        }

        var name: String {
            switch self {
            case .docker(let profile): profile.name
            case .ssh(let profile): profile.name
            }
        }

        /// As it would be saved (trimmed, blank optionals cleared).
        var normalized: Draft {
            switch self {
            case .docker(let profile): .docker(profile.normalizedForSaving)
            case .ssh(let profile): .ssh(profile.normalizedForSaving)
            }
        }

        var errorCount: Int {
            switch self {
            case .docker(let profile): profile.normalizedForSaving.validate().count
            case .ssh(let profile): profile.normalizedForSaving.validate().count
            }
        }

        /// A new, untouched draft of the same kind with the same id.
        var blank: Draft {
            switch self {
            case .docker(let profile):
                var empty = DockerProfile.newDraft()
                empty.id = profile.id
                return .docker(empty)
            case .ssh(let profile):
                var empty = SSHProfile.newDraft()
                empty.id = profile.id
                return .ssh(empty)
            }
        }

        static func new(_ kind: Kind) -> Draft {
            kind == .docker ? .docker(.newDraft()) : .ssh(.newDraft())
        }
    }

    @Environment(AppModel.self) private var model
    /// The profile being edited: a saved profile's id or the new draft's id.
    @State private var selection: UUID?
    /// Working copy shown in the form.
    @State private var draft: Draft?
    /// What the draft started from (the saved profile, or a new draft's initial values).
    @State private var baseline: Draft?
    /// The draft was never saved (+ or Duplicate).
    @State private var isNewDraft = false
    /// Selected before a new draft, so discarding the draft goes back to it.
    @State private var selectionBeforeDraft: UUID?
    /// Bumped by Revert so the form drops its container choice along with the edits.
    @State private var formGeneration = 0
    @State private var search = ""
    /// An action waiting on the unsaved-changes prompt.
    @State private var pending: PendingAction?
    /// Docker status dots appear once the form has listed containers in this window.
    @State private var containersListed = false
    @State private var hasAppeared = false
    @State private var windowHandle = ManagerWindowHandle()
    @State private var importing = false

    /// What to do once unsaved changes are saved or discarded.
    private enum PendingAction {
        case select(UUID)
        case create(Kind)
        case duplicate(UUID)
        case importHosts
        case close
    }

    var body: some View {
        HStack(spacing: 0) {
            editorPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            profileColumn
                .frame(width: 280)
        }
        .frame(minWidth: 960, minHeight: 560)
        .background(
            ManagerWindowAccessor(handle: windowHandle, isEdited: hasUnsavedChanges, shortcuts: windowShortcuts, onClose: { request(.close) })
        )
        .onAppear(perform: selectInitialProfile)
        .onChange(of: model.library.dockerProfiles) { _, _ in followLibrary() }
        .onChange(of: model.library.sshProfiles) { _, _ in followLibrary() }
        .onChange(of: model.profileManagerRequests.pending) { _, request in
            if hasAppeared, let request { handle(request) }
        }
        .onAppear { model.refreshSSHStatuses() }
        .alert(pendingTitle, isPresented: pendingBinding, presenting: pending) { action in
            if draftErrorCount == 0 {
                Button("Save") { if save() { run(action) } }
            }
            Button("Don't Save", role: .destructive) { discard(then: action) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(draftErrorCount == 0
                ? "Your changes are lost if you don't save them."
                : "The profile has issues to fix before it can be saved. Don't Save discards the changes; Cancel keeps editing.")
        }
        .sheet(isPresented: $importing) {
            SSHConfigImportSheet { imported in
                if let first = imported.first { load(first) }
            }
        }
    }

    // MARK: Editor

    @ViewBuilder
    private var editorPane: some View {
        switch draft {
        case .docker:
            VStack(spacing: 0) {
                DockerProfileHeader(title: isNewDraft ? "New Docker Profile" : (baseline?.name ?? draft?.name ?? ""))
                Divider()
                DockerProfileForm(profile: dockerBinding, isNew: isNewDraft, containerColumnWidth: 250, onContainersListed: { containersListed = true })
                    .id("\(draft?.id.uuidString ?? "")-\(formGeneration)")
                Divider()
                editorFooter
            }
        case .ssh:
            VStack(spacing: 0) {
                SSHProfileHeader(title: isNewDraft ? "New SSH Profile" : (baseline?.name ?? draft?.name ?? ""))
                Divider()
                SSHProfileForm(profile: sshBinding)
                    .id("\(draft?.id.uuidString ?? "")-\(formGeneration)")
                Divider()
                editorFooter
            }
        case nil:
            ContentUnavailableView {
                Label(hasProfiles ? "No Profile Selected" : "No Profiles", systemImage: "square.stack.3d.up")
            } description: {
                Text(hasProfiles
                    ? "Select a profile on the right to edit it."
                    : "A Docker profile runs snippets inside one of your running containers; an SSH profile runs them on a server. Creating one never runs code or connects.")
            } actions: {
                HStack {
                    Button("New Docker Profile") { request(.create(.docker)) }
                        .accessibilityIdentifier("profile-manager-empty-add")
                    Button("New SSH Profile") { request(.create(.ssh)) }
                        .accessibilityIdentifier("profile-manager-empty-add-ssh")
                    Button("Import SSH Hosts…") { request(.importHosts) }
                }
            }
        }
    }

    private var editorFooter: some View {
        HStack(spacing: 8) {
            if hasUnsavedChanges {
                Label(isNewDraft ? "Not saved yet" : "Unsaved changes", systemImage: "pencil.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("profile-manager-unsaved")
            }
            Spacer()
            DockerProfileIssueCount(count: draftErrorCount)
            Button("Revert") { revert() }
                .disabled(!canRevert)
                .help(isNewDraft ? "Go back to the new profile's initial values" : "Discard unsaved changes and go back to the saved profile")
                .accessibilityIdentifier("profile-manager-revert")
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                .help("Save this profile (⌘S)")
                .accessibilityIdentifier("profile-manager-save")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var dockerBinding: Binding<DockerProfile> {
        Binding(
            get: { if case .docker(let profile) = draft { return profile } else { return .newDraft() } },
            set: { draft = .docker($0) }
        )
    }

    private var sshBinding: Binding<SSHProfile> {
        Binding(
            get: { if case .ssh(let profile) = draft { return profile } else { return .newDraft() } },
            set: { draft = .ssh($0) }
        )
    }

    // MARK: Profile list

    private var profileColumn: some View {
        VStack(spacing: 0) {
            LibrarySearchField(prompt: "Search profiles", text: $search, identifier: "profile-manager-search")
                .padding(10)
            Divider()
            List(selection: listSelection) {
                if !visibleDockerProfiles.isEmpty || newDraft(of: .docker) != nil {
                    Section("Docker") {
                        if case .docker(let profile)? = newDraft(of: .docker) {
                            DockerProfileManagerRow(profile: profile, isNew: true, isEdited: false, status: nil, tabCount: 0)
                                .tag(profile.id)
                        }
                        ForEach(visibleDockerProfiles) { profile in
                            let isSelected = profile.id == selection
                            let shown: DockerProfile = {
                                if isSelected, case .docker(let edited) = draft { return edited }
                                return profile
                            }()
                            DockerProfileManagerRow(
                                profile: shown,
                                isNew: false,
                                isEdited: isSelected && hasUnsavedChanges,
                                status: containersListed ? status(of: shown) : nil,
                                tabCount: model.allTabs.count(where: { $0.target == .docker(profile.id) })
                            )
                            .tag(profile.id)
                        }
                    }
                }
                if !visibleSSHProfiles.isEmpty || newDraft(of: .ssh) != nil {
                    Section("SSH Hosts") {
                        if case .ssh(let profile)? = newDraft(of: .ssh) {
                            SSHProfileManagerRow(profile: profile, isNew: true, isEdited: false, status: nil, tabCount: 0)
                                .tag(profile.id)
                        }
                        ForEach(visibleSSHProfiles) { profile in
                            let isSelected = profile.id == selection
                            let shown: SSHProfile = {
                                if isSelected, case .ssh(let edited) = draft { return edited }
                                return profile
                            }()
                            SSHProfileManagerRow(
                                profile: shown,
                                isNew: false,
                                isEdited: isSelected && hasUnsavedChanges,
                                status: model.sshStatus(profile.id),
                                tabCount: model.allTabs.count(where: { $0.target == .ssh(profile.id) })
                            )
                            .tag(profile.id)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: UUID.self) { ids in
                if ids.count == 1, let id = ids.first {
                    actions(for: id)
                }
            }
            .onDeleteCommand {
                if let selection { delete(selection) }
            }
            .overlay { listEmptyState }
            .accessibilityIdentifier("profile-manager-list")
            Divider()
            listBar
        }
    }

    @ViewBuilder
    private var listEmptyState: some View {
        if !isNewDraft {
            if !hasProfiles {
                ContentUnavailableView("No Profiles", systemImage: "square.stack.3d.up", description: Text("Click + to add one."))
            } else if visibleDockerProfiles.isEmpty, visibleSSHProfiles.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
    }

    /// + / − and the actions menu under the list (the standard macOS list editing bar).
    private var listBar: some View {
        HStack(spacing: 2) {
            Menu {
                Button("New Docker Profile") { request(.create(.docker)) }
                    .accessibilityIdentifier("profile-manager-add-docker")
                Button("New SSH Profile") { request(.create(.ssh)) }
                    .accessibilityIdentifier("profile-manager-add-ssh")
                Divider()
                Button("Import SSH Hosts from ~/.ssh/config…") { request(.importHosts) }
                    .accessibilityIdentifier("profile-manager-import-ssh")
            } label: {
                Image(systemName: "plus").frame(width: 22, height: 18)
            } primaryAction: {
                request(.create(selectedKind ?? .docker))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .help("New profile (click: \(selectedKind == .ssh ? "SSH" : "Docker"); hold for more)")
            .accessibilityLabel("New Profile")
            .accessibilityIdentifier("profile-manager-add")
            Button {
                if let selection { delete(selection) }
            } label: {
                Image(systemName: "minus").frame(width: 22, height: 18)
            }
            .disabled(selection == nil)
            .help(isNewDraft ? "Discard the new profile" : "Delete the selected profile from Runlet (the container or server is not touched)")
            .accessibilityLabel(isNewDraft ? "Discard New Profile" : "Delete Profile")
            .accessibilityIdentifier("profile-manager-remove")
            Menu {
                if let selection { actions(for: selection) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(selection == nil)
            .help("More actions for the selected profile")
            .accessibilityIdentifier("profile-manager-actions")
            Spacer()
            Text(countText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var countText: String {
        let docker = model.library.dockerProfiles.count
        let ssh = model.library.sshProfiles.count
        let total = docker + ssh
        return total == 1 ? "1 profile" : "\(total) profiles"
    }

    @ViewBuilder
    private func actions(for id: UUID) -> some View {
        if isNewDraft, id == draft?.id {
            Button("Discard New Profile", role: .destructive) { delete(id) }
        } else {
            Button("Duplicate") { request(.duplicate(id)) }
                .accessibilityIdentifier("profile-manager-duplicate")
            Button("Use in Current Tab") {
                if let tab = model.selectedTab, let target = target(of: id) { model.setTarget(target, for: tab) }
            }
            .disabled(model.selectedTab == nil)
            if model.library.sshProfile(id) != nil {
                if model.sshStatus(id) == .connected {
                    Button("Disconnect") { model.disconnectSSH(id) }
                } else {
                    Button("Connect…") { model.connectSSH(id) }
                }
            }
            Divider()
            Button("Delete…", role: .destructive) { delete(id) }
        }
    }

    /// User selection goes through the unsaved-changes check; deselecting is ignored.
    private var listSelection: Binding<UUID?> {
        Binding(
            get: { selection },
            set: { id in
                guard let id, id != selection else { return }
                request(.select(id))
            }
        )
    }

    private var hasProfiles: Bool {
        !model.library.dockerProfiles.isEmpty || !model.library.sshProfiles.isEmpty
    }

    private var selectedKind: Kind? { draft?.kind }

    /// The unsaved new draft of `kind`, if one is being edited.
    private func newDraft(of kind: Kind) -> Draft? {
        guard isNewDraft, let draft, draft.kind == kind else { return nil }
        return draft
    }

    private func target(of id: UUID) -> TargetRef? {
        if model.library.dockerProfile(id) != nil { return .docker(id) }
        if model.library.sshProfile(id) != nil { return .ssh(id) }
        return nil
    }

    private func saved(_ id: UUID?) -> Draft? {
        guard let id else { return nil }
        if let profile = model.library.dockerProfile(id) { return .docker(profile) }
        if let profile = model.library.sshProfile(id) { return .ssh(profile) }
        return nil
    }

    private var sortedDockerProfiles: [DockerProfile] {
        model.library.dockerProfiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var sortedSSHProfiles: [SSHProfile] {
        model.library.sshProfiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Every profile id in list order (Docker, then SSH).
    private var orderedIds: [UUID] {
        sortedDockerProfiles.map(\.id) + sortedSSHProfiles.map(\.id)
    }

    private var visibleDockerProfiles: [DockerProfile] {
        sortedDockerProfiles.filter { profile in
            matchesSearch(search, in: profile.name, profile.identity.displayName, profile.identity.containerName ?? "", profile.workingDirectory, profile.localSourcePath ?? "", "docker")
        }
    }

    private var visibleSSHProfiles: [SSHProfile] {
        sortedSSHProfiles.filter { profile in
            matchesSearch(search, in: profile.name, profile.host, profile.destinationLabel, profile.remoteDirectory, profile.localSourcePath ?? "", profile.container?.identity.displayName ?? "", "ssh")
        }
    }

    private func status(of profile: DockerProfile) -> ProfileContainerStatus? {
        guard model.dockerStatus.isAvailable, DockerProfileForm.hasIdentity(profile.identity) else { return nil }
        switch DockerProfileResolver.resolve(profile.identity, among: model.runningContainers) {
        case .resolved: return .running
        case .ambiguous, .needsConfirmation: return .needsChoice
        case .notRunning: return .notRunning
        }
    }

    /// Shortcuts this window handles itself while it is key: the menus would otherwise act on
    /// the main window (close its tab, save its file, open the profile sheet there).
    private var windowShortcuts: [KeyCombo: () -> Void] {
        var actions: [KeyCombo: () -> Void] = [:]
        func add(_ combo: KeyCombo?, _ action: @escaping () -> Void) {
            if let combo { actions[combo] = action }
        }
        add(model.shortcut(for: "library.newDockerProfile")) { request(.create(.docker)) }
        add(model.shortcut(for: "library.newSSHProfile")) { request(.create(.ssh)) }
        add(KeyCombo("s")) { save() }
        add(model.shortcut(for: "file.save")) { save() }
        add(KeyCombo("w")) { request(.close) }
        add(model.shortcut(for: "file.closeTab")) { request(.close) }
        return actions
    }

    // MARK: Draft state

    private var draftErrorCount: Int {
        draft?.errorCount ?? 0
    }

    /// The draft differs from what it started from.
    private var canRevert: Bool {
        guard let draft, let baseline else { return false }
        return draft.normalized != baseline.normalized
    }

    /// Switching away would lose something: edits to a saved profile, or a new profile with
    /// any content (an untouched + draft is simply dropped).
    private var hasUnsavedChanges: Bool {
        guard let draft else { return false }
        if isNewDraft { return draft.normalized != draft.blank.normalized }
        return canRevert
    }

    private var canSave: Bool {
        draft != nil && draftErrorCount == 0 && (isNewDraft || canRevert)
    }

    private var pendingBinding: Binding<Bool> {
        Binding(
            get: { pending != nil },
            set: { if !$0 { pending = nil } }
        )
    }

    private var pendingTitle: String {
        let name = draft?.normalized.name ?? ""
        let kind = draft?.kind == .ssh ? "SSH" : "Docker"
        if isNewDraft {
            return name.isEmpty ? "Do you want to save the new \(kind) profile?" : "Do you want to save the new \(kind) profile “\(name)”?"
        }
        return "Do you want to save the changes to “\(baseline?.name ?? name)”?"
    }

    // MARK: Actions

    /// Opens on the requested profile, else the current tab's Docker or SSH profile, else the
    /// first one.
    private func selectInitialProfile() {
        guard !hasAppeared else { return }
        hasAppeared = true
        if let request = model.profileManagerRequests.pending {
            handle(request)
            return
        }
        switch model.selectedTab?.target {
        case .docker(let id) where model.library.dockerProfile(id) != nil: load(id)
        case .ssh(let id) where model.library.sshProfile(id) != nil: load(id)
        default: load(orderedIds.first)
        }
    }

    /// A request from elsewhere (Settings, a menu, the palette) while the window is open.
    private func handle(_ request: ProfileManagerRequest) {
        model.profileManagerRequests.pending = nil
        if request.importSSHHosts {
            self.request(.importHosts)
        } else if let target = request.select {
            switch target {
            case .docker(let id), .ssh(let id):
                if id != selection { self.request(.select(id)) }
            default:
                break
            }
        }
        if draft == nil, !request.importSSHHosts { load(orderedIds.first) }
    }

    /// Runs `action` now, or asks first when it would lose unsaved changes.
    private func request(_ action: PendingAction) {
        if hasUnsavedChanges {
            pending = action
        } else {
            run(action)
        }
    }

    private func run(_ action: PendingAction) {
        switch action {
        case .select(let id):
            load(id)
        case .create(let kind):
            startDraft(.new(kind))
        case .duplicate(let id):
            switch saved(id) {
            case .docker(var copy)?:
                copy.id = UUID()
                copy.name += " copy"
                copy.revision = 1
                copy.lastOpenedAt = nil
                startDraft(.docker(copy))
            case .ssh(var copy)?:
                copy.id = UUID()
                copy.name += " copy"
                copy.revision = 1
                copy.lastOpenedAt = nil
                startDraft(.ssh(copy))
            case nil:
                break
            }
        case .importHosts:
            if isNewDraft { load(selectionBeforeDraft ?? orderedIds.first) }
            importing = true
        case .close:
            windowHandle.close()
        }
    }

    /// Don't Save: drops the edits (or the whole new draft), then runs `action`.
    private func discard(then action: PendingAction) {
        if isNewDraft {
            load(selectionBeforeDraft ?? orderedIds.first)
        } else {
            draft = baseline
        }
        run(action)
    }

    private func load(_ id: UUID?) {
        let profile = saved(id)
        selection = profile?.id
        draft = profile
        baseline = profile
        isNewDraft = false
    }

    private func startDraft(_ profile: Draft) {
        if !isNewDraft { selectionBeforeDraft = selection }
        selection = profile.id
        draft = profile
        baseline = profile
        isNewDraft = true
    }

    private func revert() {
        guard let baseline else { return }
        let restored = isNewDraft ? baseline : (saved(baseline.id) ?? baseline)
        draft = restored
        self.baseline = restored
        formGeneration += 1
    }

    /// Saves the draft once it validates. Values that changed underneath while it was open
    /// (last use, and the last-seen container when the container wasn't changed here) keep
    /// their newer values.
    @discardableResult
    private func save() -> Bool {
        guard canSave, let normalized = draft?.normalized else { return false }
        switch normalized {
        case .docker(var result):
            if let current = model.library.dockerProfile(result.id) {
                result.lastOpenedAt = current.lastOpenedAt
                if case .docker(let base)? = baseline, result.identity == base.identity { result.identity = current.identity }
            }
            model.saveDockerProfile(result)
        case .ssh(var result):
            if let current = model.library.sshProfile(result.id) {
                result.lastOpenedAt = current.lastOpenedAt
                if case .ssh(let base)? = baseline, result.container?.identity == base.container?.identity, let identity = current.container?.identity {
                    result.container?.identity = identity
                }
            }
            model.saveSSHProfile(result)
        }
        let saved = saved(normalized.id) ?? normalized
        selection = saved.id
        draft = saved
        baseline = saved
        isNewDraft = false
        return true
    }

    /// Deletes a saved profile after the usual confirmation, or drops the new draft.
    private func delete(_ id: UUID) {
        if isNewDraft, id == draft?.id {
            load(selectionBeforeDraft ?? orderedIds.first)
            return
        }
        guard let target = target(of: id) else { return }
        let next = neighbour(of: id)
        guard model.confirmDeleteTarget(target) else { return }
        if id == selection { load(next) }
    }

    /// The profile to select after deleting `id`: the next one in the list, else the previous.
    private func neighbour(of id: UUID) -> UUID? {
        let ids = visibleDockerProfiles.map(\.id) + visibleSSHProfiles.map(\.id)
        if let index = ids.firstIndex(of: id) {
            if index + 1 < ids.count { return ids[index + 1] }
            if index > 0 { return ids[index - 1] }
        }
        return orderedIds.first { $0 != id }
    }

    /// Follows changes saved elsewhere (a run noting a recreated container, a profile sheet,
    /// deletion from the target menu or Settings, an import) without touching unsaved edits.
    private func followLibrary() {
        guard !isNewDraft else { return }
        guard let id = selection, let current = saved(id) else {
            load(orderedIds.first)
            return
        }
        if !hasUnsavedChanges, current != baseline {
            draft = current
            baseline = current
        }
    }
}

/// Icon, title, and the "never connects by itself" reminder above an SSH profile form.
struct SSHProfileHeader: View {
    var title: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Run snippets with a server's PHP over SSH. Saving or opening a profile never connects. The runner is streamed to PHP; only the compiled-PHP cache (Speed) is kept on the server.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

/// One SSH host in the manager's list: name, where it runs, its local folder, the connection
/// status (from the control socket on this Mac; never connects), and how many tabs use it.
private struct SSHProfileManagerRow: View {
    let profile: SSHProfile
    let isNew: Bool
    let isEdited: Bool
    let status: SSHConnectionStatus?
    let tabCount: Int

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            statusDot
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title)
                        .fontWeight(.medium)
                        .foregroundStyle(profile.name.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                    if isNew {
                        badge("New")
                    } else if isEdited {
                        badge("Edited")
                    }
                    EnvironmentBadge(environment: profile.environment)
                }
                Text(profile.host.isEmpty ? "No host yet" : TabCardText.sshSubtitle(profile))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Label {
                    Text(profile.localSourcePath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "No local folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "folder")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if tabCount > 0 {
                    Text(tabCount == 1 ? "Used by 1 tab" : "Used by \(tabCount) tabs")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
        .help([title, TabCardText.sshSubtitle(profile), status?.label].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("profile-manager-row-\(profile.name)")
    }

    private var title: String {
        profile.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled Profile" : profile.name
    }

    @ViewBuilder
    private var statusDot: some View {
        switch status {
        case .connected:
            Circle().fill(.green).frame(width: 8, height: 8).accessibilityLabel(SSHConnectionStatus.connected.label)
        case .expired:
            Circle().fill(.orange).frame(width: 8, height: 8).accessibilityLabel(SSHConnectionStatus.expired.label)
        default:
            Circle().strokeBorder(.secondary, lineWidth: 1).frame(width: 8, height: 8).accessibilityLabel(SSHConnectionStatus.disconnected.label)
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(.tint.opacity(0.2)))
    }
}

/// Whether a profile's container is running, from the last container listing.
private enum ProfileContainerStatus {
    case running, needsChoice, notRunning

    var label: String {
        switch self {
        case .running: "Container running"
        case .needsChoice: "Several containers match, or the container was recreated; you choose when you run"
        case .notRunning: "Container not running"
        }
    }
}

/// One profile in the manager's list: name, container identity, local source folder, how
/// many tabs use it, and whether its container is running.
private struct DockerProfileManagerRow: View {
    let profile: DockerProfile
    let isNew: Bool
    let isEdited: Bool
    let status: ProfileContainerStatus?
    let tabCount: Int

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            statusDot
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title)
                        .fontWeight(.medium)
                        .foregroundStyle(profile.name.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                    if isNew {
                        badge("New")
                    } else if isEdited {
                        badge("Edited")
                    }
                }
                Text(identityLine)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Label {
                    Text(profile.localSourcePath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "No local source")
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "folder")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if tabCount > 0 {
                    Text(tabCount == 1 ? "Used by 1 tab" : "Used by \(tabCount) tabs")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("profile-manager-row-\(profile.name)")
    }

    private var title: String {
        profile.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled Profile" : profile.name
    }

    private var identityLine: String {
        guard DockerProfileForm.hasIdentity(profile.identity) else { return "No container chosen" }
        return "\(profile.identity.displayName) · \(profile.workingDirectory)"
    }

    private var helpText: String {
        var lines = [title, identityLine]
        if let source = profile.localSourcePath { lines.append("Local source: \(source)") }
        if let status { lines.append(status.label) }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private var statusDot: some View {
        switch status {
        case .running:
            Circle().fill(.green).frame(width: 8, height: 8).accessibilityLabel(ProfileContainerStatus.running.label)
        case .needsChoice:
            Circle().fill(.orange).frame(width: 8, height: 8).accessibilityLabel(ProfileContainerStatus.needsChoice.label)
        case .notRunning:
            Circle().strokeBorder(.secondary, lineWidth: 1).frame(width: 8, height: 8).accessibilityLabel(ProfileContainerStatus.notRunning.label)
        case nil:
            Color.clear.frame(width: 8, height: 8).accessibilityHidden(true)
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(.tint.opacity(0.2)))
    }
}

/// The manager's NSWindow, once SwiftUI has created it.
private final class ManagerWindowHandle {
    weak var window: NSWindow?

    /// Closes without asking again (the unsaved-changes prompt has already run).
    func close() { window?.close() }
}

/// Wires the manager's NSWindow: the close button (and ⇧⌘W, which clicks it) asks about unsaved
/// changes first, `shortcuts` (⌘W, ⌘S, New Docker Profile) act on this window instead of
/// reaching the menus, and the title bar's "edited" dot follows the draft. Other menu
/// shortcuts act on the main window as usual.
private struct ManagerWindowAccessor: NSViewRepresentable {
    let handle: ManagerWindowHandle
    var isEdited: Bool
    var shortcuts: [KeyCombo: () -> Void]
    var onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(handle: handle) }

    func makeNSView(context: Context) -> NSView {
        let view = WindowAccessor.AccessorView()
        view.onWindow = { [weak coordinator = context.coordinator] nsWindow in
            coordinator?.attach(nsWindow)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.isEdited = isEdited
        coordinator.shortcuts = shortcuts
        coordinator.onClose = onClose
        coordinator.handle.window?.isDocumentEdited = isEdited
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject {
        let handle: ManagerWindowHandle
        var isEdited = false
        var shortcuts: [KeyCombo: () -> Void] = [:]
        var onClose: () -> Void = {}
        private var monitor: Any?

        init(handle: ManagerWindowHandle) {
            self.handle = handle
        }

        func attach(_ nsWindow: NSWindow) {
            guard handle.window !== nsWindow else { return }
            handle.window = nsWindow
            nsWindow.tabbingMode = .disallowed
            nsWindow.isDocumentEdited = isEdited
            if let close = nsWindow.standardWindowButton(.closeButton) {
                close.target = self
                close.action = #selector(closeRequested(_:))
            }
            // A local monitor runs before the menus.
            if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, let window = self.handle.window, let eventWindow = event.window,
                          let combo = KeyCombo(event: event), let action = self.shortcuts[combo] else { return event }
                    if eventWindow === window {
                        action()
                        return nil
                    }
                    // An alert on this window: the shortcut must not reach the main window either.
                    return eventWindow.sheetParent === window ? nil : event
                }
            }
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        @objc func closeRequested(_ sender: Any?) {
            onClose()
        }
    }
}
