import AppKit
import RunletCore
import RunletExecution
import SwiftUI

extension AppModel {
    /// Opens the Docker profile manager window, or brings it forward when it is already open.
    func showDockerProfileManager() {
        openSingleWindowAction?(DockerProfileManager.sceneId)
    }
}

/// Library ▸ Manage Docker Profiles…: one window for every saved Docker profile. The list on
/// the right switches between profiles and creates (+), duplicates, and deletes (−) them; the
/// rest of the window edits the selected profile with the same form as the profile sheet.
///
/// Editing is explicit, as in the sheet: the form changes a draft, Save (↩ or ⌘S) writes it
/// once it validates, and Revert goes back to the saved values. Switching profiles, creating
/// or duplicating one, or closing the window while the draft has unsaved changes asks Save /
/// Don't Save / Cancel (a draft with issues can only be discarded or kept). A new profile is
/// only a draft until it is saved. Deleting goes through `AppModel.confirmDeleteTarget`, so
/// tabs using the profile switch to the sandbox exactly as from the target menu. Nothing here
/// runs code; the form lists containers and offers the same read-only Test as the sheet.
struct DockerProfileManager: View {
    static let sceneId = "docker-profiles"

    @Environment(AppModel.self) private var model
    /// The profile being edited: a saved profile's id or the new draft's id.
    @State private var selection: UUID?
    /// Working copy shown in the form.
    @State private var draft: DockerProfile?
    /// What the draft started from (the saved profile, or a new draft's initial values).
    @State private var baseline: DockerProfile?
    /// The draft was never saved (+ or Duplicate).
    @State private var isNewDraft = false
    /// Selected before a new draft, so discarding the draft goes back to it.
    @State private var selectionBeforeDraft: UUID?
    /// Bumped by Revert so the form drops its container choice along with the edits.
    @State private var formGeneration = 0
    @State private var search = ""
    /// An action waiting on the unsaved-changes prompt.
    @State private var pending: PendingAction?
    /// Status dots appear once the form has listed containers in this window.
    @State private var containersListed = false
    @State private var hasAppeared = false
    @State private var windowHandle = ManagerWindowHandle()

    /// What to do once unsaved changes are saved or discarded.
    private enum PendingAction {
        case select(UUID)
        case create
        case duplicate(UUID)
        case close
    }

    var body: some View {
        HStack(spacing: 0) {
            editorPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            profileColumn
                .frame(width: 270)
        }
        .frame(minWidth: 960, minHeight: 560)
        .background(
            ManagerWindowAccessor(handle: windowHandle, isEdited: hasUnsavedChanges, shortcuts: windowShortcuts, onClose: { request(.close) })
        )
        .onAppear(perform: selectInitialProfile)
        .onChange(of: model.library.dockerProfiles) { _, _ in followLibrary() }
        .alert(pendingTitle, isPresented: pendingBinding, presenting: pending) { action in
            if draftErrors.isEmpty {
                Button("Save") { if save() { run(action) } }
            }
            Button("Don't Save", role: .destructive) { discard(then: action) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(draftErrors.isEmpty
                ? "Your changes are lost if you don't save them."
                : "The profile has issues to fix before it can be saved. Don't Save discards the changes; Cancel keeps editing.")
        }
    }

    // MARK: Editor

    @ViewBuilder
    private var editorPane: some View {
        if let draft {
            VStack(spacing: 0) {
                DockerProfileHeader(title: isNewDraft ? "New Docker Profile" : (baseline?.name ?? draft.name))
                Divider()
                DockerProfileForm(profile: draftBinding, isNew: isNewDraft, containerColumnWidth: 250, onContainersListed: { containersListed = true })
                    .id("\(draft.id.uuidString)-\(formGeneration)")
                Divider()
                editorFooter
            }
        } else {
            ContentUnavailableView {
                Label(model.library.dockerProfiles.isEmpty ? "No Docker Profiles" : "No Profile Selected", systemImage: "cube.box")
            } description: {
                Text(model.library.dockerProfiles.isEmpty
                    ? "A Docker profile runs snippets inside one of your running containers. Creating one never runs code."
                    : "Select a profile on the right to edit it.")
            } actions: {
                Button("New Docker Profile") { request(.create) }
                    .accessibilityIdentifier("profile-manager-empty-add")
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
            DockerProfileIssueCount(count: draftErrors.count)
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

    private var draftBinding: Binding<DockerProfile> {
        Binding(
            get: { draft ?? .newDraft() },
            set: { draft = $0 }
        )
    }

    // MARK: Profile list

    private var profileColumn: some View {
        VStack(spacing: 0) {
            LibrarySearchField(prompt: "Search profiles", text: $search, identifier: "profile-manager-search")
                .padding(10)
            Divider()
            List(selection: listSelection) {
                if isNewDraft, let draft {
                    DockerProfileManagerRow(profile: draft, isNew: true, isEdited: false, status: nil, tabCount: 0)
                        .tag(draft.id)
                }
                ForEach(visibleProfiles) { profile in
                    let isSelected = profile.id == selection
                    let shown = isSelected ? (draft ?? profile) : profile
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
            if model.library.dockerProfiles.isEmpty {
                ContentUnavailableView("No Profiles", systemImage: "cube.box", description: Text("Click + to add one."))
            } else if visibleProfiles.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
    }

    /// + / − and the actions menu under the list (the standard macOS list editing bar).
    private var listBar: some View {
        HStack(spacing: 2) {
            Button {
                request(.create)
            } label: {
                Image(systemName: "plus").frame(width: 22, height: 18)
            }
            .help("New Docker Profile")
            .accessibilityLabel("New Docker Profile")
            .accessibilityIdentifier("profile-manager-add")
            Button {
                if let selection { delete(selection) }
            } label: {
                Image(systemName: "minus").frame(width: 22, height: 18)
            }
            .disabled(selection == nil)
            .help(isNewDraft ? "Discard the new profile" : "Delete the selected profile from Runlet (the container is not touched)")
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
            Text(model.library.dockerProfiles.count == 1 ? "1 profile" : "\(model.library.dockerProfiles.count) profiles")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func actions(for id: UUID) -> some View {
        if isNewDraft, id == draft?.id {
            Button("Discard New Profile", role: .destructive) { delete(id) }
        } else {
            Button("Duplicate") { request(.duplicate(id)) }
                .accessibilityIdentifier("profile-manager-duplicate")
            Button("Use in Current Tab") {
                if let tab = model.selectedTab { model.setTarget(.docker(id), for: tab) }
            }
            .disabled(model.selectedTab == nil)
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

    private var sortedProfiles: [DockerProfile] {
        model.library.dockerProfiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var visibleProfiles: [DockerProfile] {
        sortedProfiles.filter { profile in
            matchesSearch(search, in: profile.name, profile.identity.displayName, profile.identity.containerName ?? "", profile.workingDirectory, profile.localSourcePath ?? "")
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
        add(model.shortcut(for: "library.newDockerProfile")) { request(.create) }
        add(KeyCombo("s")) { save() }
        add(model.shortcut(for: "file.save")) { save() }
        add(KeyCombo("w")) { request(.close) }
        add(model.shortcut(for: "file.closeTab")) { request(.close) }
        return actions
    }

    // MARK: Draft state

    private var draftErrors: [DockerProfile.ValidationError] {
        draft?.normalizedForSaving.validate() ?? []
    }

    /// The draft differs from what it started from.
    private var canRevert: Bool {
        guard let draft, let baseline else { return false }
        return draft.normalizedForSaving != baseline.normalizedForSaving
    }

    /// Switching away would lose something: edits to a saved profile, or a new profile with
    /// any content (an untouched + draft is simply dropped).
    private var hasUnsavedChanges: Bool {
        guard let draft else { return false }
        if isNewDraft {
            var blank = DockerProfile.newDraft()
            blank.id = draft.id
            return draft.normalizedForSaving != blank.normalizedForSaving
        }
        return canRevert
    }

    private var canSave: Bool {
        draft != nil && draftErrors.isEmpty && (isNewDraft || canRevert)
    }

    private var pendingBinding: Binding<Bool> {
        Binding(
            get: { pending != nil },
            set: { if !$0 { pending = nil } }
        )
    }

    private var pendingTitle: String {
        let name = draft?.normalizedForSaving.name ?? ""
        if isNewDraft {
            return name.isEmpty ? "Do you want to save the new Docker profile?" : "Do you want to save the new Docker profile “\(name)”?"
        }
        return "Do you want to save the changes to “\(baseline?.name ?? name)”?"
    }

    // MARK: Actions

    /// Opens on the current tab's Docker profile, else the first one.
    private func selectInitialProfile() {
        guard !hasAppeared else { return }
        hasAppeared = true
        if case .docker(let id) = model.selectedTab?.target, model.library.dockerProfile(id) != nil {
            load(id)
        } else {
            load(sortedProfiles.first?.id)
        }
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
        case .create:
            startDraft(.newDraft())
        case .duplicate(let id):
            guard let source = model.library.dockerProfile(id) else { return }
            var copy = source
            copy.id = UUID()
            copy.name = source.name + " copy"
            copy.revision = 1
            copy.lastOpenedAt = nil
            startDraft(copy)
        case .close:
            windowHandle.close()
        }
    }

    /// Don't Save: drops the edits (or the whole new draft), then runs `action`.
    private func discard(then action: PendingAction) {
        if isNewDraft {
            load(selectionBeforeDraft ?? sortedProfiles.first?.id)
        } else {
            draft = baseline
        }
        run(action)
    }

    private func load(_ id: UUID?) {
        let profile = id.flatMap { model.library.dockerProfile($0) }
        selection = profile?.id
        draft = profile
        baseline = profile
        isNewDraft = false
    }

    private func startDraft(_ profile: DockerProfile) {
        if !isNewDraft { selectionBeforeDraft = selection }
        selection = profile.id
        draft = profile
        baseline = profile
        isNewDraft = true
    }

    private func revert() {
        guard let baseline else { return }
        let restored = isNewDraft ? baseline : (model.library.dockerProfile(baseline.id) ?? baseline)
        draft = restored
        self.baseline = restored
        formGeneration += 1
    }

    /// Saves the draft once it validates. Values that changed underneath while it was open
    /// (last use, and the last-seen container when the container wasn't changed here) keep
    /// their newer values.
    @discardableResult
    private func save() -> Bool {
        guard canSave, var result = draft?.normalizedForSaving else { return false }
        if let current = model.library.dockerProfile(result.id) {
            result.lastOpenedAt = current.lastOpenedAt
            if let baseline, result.identity == baseline.identity { result.identity = current.identity }
        }
        model.saveDockerProfile(result)
        let saved = model.library.dockerProfile(result.id) ?? result
        selection = saved.id
        draft = saved
        baseline = saved
        isNewDraft = false
        return true
    }

    /// Deletes a saved profile after the usual confirmation, or drops the new draft.
    private func delete(_ id: UUID) {
        if isNewDraft, id == draft?.id {
            load(selectionBeforeDraft ?? sortedProfiles.first?.id)
            return
        }
        let next = neighbour(of: id)
        guard model.confirmDeleteTarget(.docker(id)) else { return }
        if id == selection { load(next) }
    }

    /// The profile to select after deleting `id`: the next one in the list, else the previous.
    private func neighbour(of id: UUID) -> UUID? {
        let ids = visibleProfiles.map(\.id)
        if let index = ids.firstIndex(of: id) {
            if index + 1 < ids.count { return ids[index + 1] }
            if index > 0 { return ids[index - 1] }
        }
        return sortedProfiles.first { $0.id != id }?.id
    }

    /// Follows changes saved elsewhere (a run noting a recreated container, the profile sheet,
    /// deletion from the target menu or Settings) without touching unsaved edits.
    private func followLibrary() {
        guard !isNewDraft else { return }
        guard let id = selection else {
            load(sortedProfiles.first?.id)
            return
        }
        guard let saved = model.library.dockerProfile(id) else {
            load(sortedProfiles.first?.id)
            return
        }
        if !hasUnsavedChanges, saved != baseline {
            draft = saved
            baseline = saved
        }
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
