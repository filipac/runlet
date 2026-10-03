import AppKit
import RunletCore
import SwiftUI

/// Side panel with searchable execution history, personal snippets, and the active tab's
/// project snippets (`.runlet/snippets`).
/// Loading or opening anything from here only restores code; nothing runs until the user presses Run.
struct LibraryInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Picker("Library", selection: $model.inspectorPane) {
                ForEach(AppModel.InspectorPane.allCases, id: \.self) { pane in
                    Text(pane.rawValue).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("library-pane-picker")
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)

            switch model.inspectorPane {
            case .history:
                HistoryPane()
            case .snippets:
                SnippetsPane()
            case .commands:
                // Loads only while shown (or on Refresh): listing commands boots the app.
                ProjectCommandsView()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Describes the double-click setting in the panes' hints.
enum LibraryOpenHint {
    static func text(_ behavior: LibraryOpenBehavior) -> String {
        switch behavior {
        case .reuseBlankTab: "to open in this tab when it's empty and on the same target, otherwise in a new tab"
        case .newTab: "to open in a new tab"
        case .currentTab: "to load into the current tab (⌘Z undoes)"
        }
    }

    /// The panes' keyboard hint: ↩ and double-click follow the setting.
    static func keys(_ behavior: LibraryOpenBehavior) -> String {
        "↩ or double-click \(text(behavior)). ⌘↩ new tab, ⇧↩ insert at the cursor."
    }
}

// MARK: - History

private struct HistoryPane: View {
    /// Which runs the list shows.
    enum Scope: String, CaseIterable {
        /// Runs on the current tab's target (the default).
        case project = "This Project"
        case all = "All Projects"
    }

    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window: WindowModel?
    @State private var search = ""
    @State private var scope: Scope = .project
    @State private var selection: Set<HistoryEntry.ID> = []
    @State private var confirmClear = false

    /// The target "This Project" means: the window's selected tab's.
    private var currentTarget: TargetRef? { (window?.selectedTab ?? model.selectedTab)?.target }

    /// Runs in the current scope, before searching.
    private var scopedEntries: [HistoryEntry] {
        guard scope == .project else { return model.history }
        guard let currentTarget else { return [] }
        return model.history.filter { $0.target == currentTarget }
    }

    var body: some View {
        let entries = filteredEntries
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Picker("Show", selection: $scope) {
                    ForEach(Scope.allCases, id: \.self) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .help(currentTarget.map { "This Project: runs on \(model.targetLabel($0))" } ?? "")
                .accessibilityIdentifier("history-scope-picker")
                LibrarySearchField(prompt: scope == .all ? "Search code or target" : "Search code", text: $search, identifier: "history-search",
                                   pane: .history, onMove: moveSelection, onAction: perform, onEscape: { model.focusSelectedEditor() })
                Text(LibraryOpenHint.keys(model.settings.libraryOpenBehavior) + " Nothing runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            Divider()

            ScrollViewReader { proxy in
                List(entries, selection: $selection) { entry in
                    HistoryRow(entry: entry)
                        .id(entry.id)
                }
                .listStyle(.inset)
                .accessibilityIdentifier("history-list")
                .contextMenu(forSelectionType: HistoryEntry.ID.self) { ids in
                    menu(for: ids)
                } primaryAction: { ids in
                    if let entry = single(ids) { model.open(entry) }
                }
                .onDeleteCommand { delete(selection) }
                .onKeyPress(phases: .down) { press in listKey(press) }
                .onChange(of: selection) {
                    if selection.count == 1, let id = selection.first { proxy.scrollTo(id) }
                }
            }
            .overlay {
                if model.history.isEmpty {
                    ContentUnavailableView {
                        Label("No History Yet", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("Each run's code, target, time, and result status is saved here. Loading an entry never runs it.")
                    }
                } else if scopedEntries.isEmpty {
                    ContentUnavailableView {
                        Label("No Runs Here Yet", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text(currentTarget.map { "Nothing has run on \(model.targetLabel($0)) yet." } ?? "Open a tab to see its project's runs.")
                    } actions: {
                        Button("Show All Projects") { scope = .all }
                            .accessibilityIdentifier("history-show-all")
                    }
                } else if entries.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }

            Divider()
            footer(visibleCount: entries.count)
        }
        .confirmationDialog("Clear all history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) {
                model.clearHistory()
                selection = []
            }
        } message: {
            Text("This removes all \(model.history.count.formatted()) history entries. Snippets are not affected. This can't be undone.")
        }
        .onChange(of: model.history.map(\.id)) { _, ids in
            selection.formIntersection(ids)
        }
        // Keep the selection to visible rows when the scope or the current project changes.
        .onChange(of: "\(scope.rawValue)|\(currentTarget?.stableKey ?? "")") {
            selection.formIntersection(filteredEntries.map(\.id))
        }
        // Typing narrows the list to its best match, ready for ↩.
        .onChange(of: search) {
            selection = filteredEntries.first.map { [$0.id] } ?? []
        }
    }

    private var filteredEntries: [HistoryEntry] {
        scopedEntries
            .filter { matchesSearch(search, in: $0.code, $0.targetLabel, model.targetLabel($0.target)) }
            .sorted { $0.timestamp > $1.timestamp }
    }

    private func single(_ ids: Set<HistoryEntry.ID>) -> HistoryEntry? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return model.history.first { $0.id == id }
    }

    // MARK: Keyboard

    /// ↑/↓ from the search field: moves the selection through the visible rows.
    private func moveSelection(_ delta: Int) {
        let ids = filteredEntries.map(\.id)
        guard !ids.isEmpty else { return }
        let current = ids.lastIndex { selection.contains($0) }
        let next = current.map { min(max($0 + delta, 0), ids.count - 1) } ?? 0
        selection = [ids[next]]
    }

    /// ↩, ⌘↩, ⇧↩ (from the search field or the list): the selected entry, or the first one
    /// when nothing is selected. Only loads code, then hands the keyboard to the editor.
    private func perform(_ action: LibraryKeyAction) {
        let entries = filteredEntries
        guard let entry = entries.first(where: { selection.contains($0.id) }) ?? entries.first else { return }
        switch action {
        case .open: model.open(entry)
        case .openInNewTab: model.restore(entry, inNewTab: true)
        case .insert: model.insertLibraryCode(entry.code)
        }
        model.focusSelectedEditor()
    }

    /// Keys in the list itself: ⌘↩ and ⇧↩ (plain ↩ is the primary action, like double-click),
    /// and typing, which goes on in the search field.
    private func listKey(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .return {
            if press.modifiers.contains(.command) {
                perform(.openInNewTab)
            } else if press.modifiers.contains(.shift) {
                perform(.insert)
            } else {
                return .ignored
            }
            return .handled
        }
        guard press.isTyping else { return .ignored }
        search += press.characters
        LibrarySearchFocus.request(.history, selectAll: false)
        return .handled
    }

    @ViewBuilder
    private func menu(for ids: Set<HistoryEntry.ID>) -> some View {
        if let entry = single(ids) {
            Button("Load in Current Tab") { model.restore(entry, inNewTab: false) }
                .disabled(model.selectedTab == nil)
            Button("Open in New Tab") { model.restore(entry, inNewTab: true) }
            Divider()
            Button("Save as Snippet") { saveAsSnippet(entry) }
            Button("Copy Code") { Pasteboard.copy(entry.code) }
            Divider()
        }
        if !ids.isEmpty {
            Button(ids.count == 1 ? "Delete" : "Delete \(ids.count) Entries", role: .destructive) { delete(ids) }
        }
    }

    @ViewBuilder
    private func footer(visibleCount: Int) -> some View {
        VStack(spacing: 6) {
            if let entry = single(selection) {
                HStack(spacing: 6) {
                    Button("Load in Current Tab") { model.restore(entry, inNewTab: false) }
                        .disabled(model.selectedTab == nil)
                        .help("Replace the current tab's code with this entry. Nothing runs.")
                        .accessibilityIdentifier("history-load-button")
                    Button("Open in New Tab") { model.restore(entry, inNewTab: true) }
                        .help("Open this entry in a new tab with its target. Nothing runs.")
                        .accessibilityIdentifier("history-open-new-tab-button")
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 6) {
                Text(countText(visibleCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityIdentifier("history-count")
                Spacer(minLength: 0)
                Button("Clear History…") { confirmClear = true }
                    .disabled(model.history.isEmpty)
                    .accessibilityIdentifier("history-clear-button")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func countText(_ visible: Int) -> String {
        let total = scopedEntries.count
        let noun = total == 1 ? "entry" : "entries"
        let count = search.isEmpty || visible == total ? "\(total.formatted()) \(noun)" : "\(visible.formatted()) of \(total.formatted()) \(noun)"
        return scope == .project ? count + " here · \(model.history.count.formatted()) in all" : count
    }

    private func saveAsSnippet(_ entry: HistoryEntry) {
        model.saveSnippet(label: CodePreview.title(entry.code), code: entry.code, target: entry.target)
        model.inspectorPane = .snippets
    }

    /// Deletes entries (a log of runs, so without asking) and selects the next row, so ⌫ can
    /// go on through the list.
    private func delete(_ ids: Set<HistoryEntry.ID>) {
        let visible = filteredEntries.map(\.id)
        let first = visible.firstIndex { ids.contains($0) }
        for id in ids { model.deleteHistory(id) }
        selection.subtract(ids)
        let remaining = visible.filter { !ids.contains($0) }
        if selection.isEmpty, let first, !remaining.isEmpty {
            selection = [remaining[min(first, remaining.count - 1)]]
        }
    }
}

private struct HistoryRow: View {
    @Environment(AppModel.self) private var model
    let entry: HistoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.status.symbol)
                .foregroundStyle(entry.status.color)
                .font(.body)
                .accessibilityLabel(entry.status.label)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: model.targetSymbol(entry.target))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(entry.targetLabel)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(entry.timestamp, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(CodePreview.lines(entry.code, limit: 3))
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(statusLine)
                    .font(.caption2)
                    .foregroundStyle(entry.status == .completed ? AnyShapeStyle(.secondary) : AnyShapeStyle(entry.status.color))
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .help("\(entry.timestamp.formatted(date: .abbreviated, time: .standard)) · \(entry.targetLabel)\nDouble-click \(LibraryOpenHint.text(model.settings.libraryOpenBehavior)). Loading never runs code.")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("history-row")
    }

    private var statusLine: String {
        var status = entry.status.label
        let reason = entry.reason.trimmingCharacters(in: .whitespaces)
        if !reason.isEmpty, reason != entry.status.rawValue, reason != "completed" {
            status += " (\(reason))"
        }
        return "\(status) · \(entry.elapsedMs.formatted()) ms"
    }
}

// MARK: - Snippets

/// A row in the Snippets list: a personal snippet, or a project snippet file (by path).
private enum SnippetItemID: Hashable {
    case personal(UUID)
    case project(String)

    var personalID: UUID? {
        if case .personal(let id) = self { return id }
        return nil
    }
}

private struct SnippetsPane: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var selection: Set<SnippetItemID> = []
    @State private var editing: Snippet?
    @State private var pendingDelete: Set<Snippet.ID> = []
    @State private var confirmDelete = false

    var body: some View {
        let snippets = filteredSnippets
        let project = projectContext
        let projectSnippets = project.map { filteredProjectSnippets($0.snippets) } ?? []
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    LibrarySearchField(prompt: "Search snippets", text: $search, identifier: "snippet-search",
                                       pane: .snippets, onMove: moveSelection, onAction: perform, onEscape: { model.focusSelectedEditor() })
                    Button {
                        requestSaveCurrentTab()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Save Current Tab as Snippet (⌥⌘S)")
                    .accessibilityLabel("Save Current Tab as Snippet")
                    .accessibilityIdentifier("snippet-save-current-button")
                    .disabled(model.selectedTab == nil)
                }
                Text(LibraryOpenHint.keys(model.settings.libraryOpenBehavior) + " Snippets bring their target. Nothing runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            Divider()

            ScrollViewReader { proxy in
                List(selection: $selection) {
                    if let project {
                        Section {
                            ForEach(projectSnippets) { snippet in
                                ProjectSnippetRow(snippet: snippet, projectName: project.name)
                                    .tag(SnippetItemID.project(snippet.id))
                                    .id(SnippetItemID.project(snippet.id))
                            }
                            if projectSnippets.isEmpty {
                                Text(project.snippets.isEmpty
                                     ? "No snippets in \(ProjectSnippets.relativeDirectory) yet. Save one with Save Snippet ▸ Project to share it through the project."
                                     : "No project snippets match.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .selectionDisabled()
                            }
                        } header: {
                            ProjectSectionHeader(name: project.name, root: project.root) {
                                model.refreshProjectSnippets(for: project.target)
                            }
                        }
                        .accessibilityIdentifier("project-snippets-section")
                        Section("Personal snippets") {
                            personalRows(snippets)
                            if model.snippets.isEmpty {
                                Text("No personal snippets yet.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .selectionDisabled()
                            }
                        }
                    } else {
                        personalRows(snippets)
                    }
                }
                .listStyle(.inset)
                .accessibilityIdentifier("snippet-list")
                .contextMenu(forSelectionType: SnippetItemID.self) { ids in
                    menu(for: ids)
                } primaryAction: { ids in
                    openPreferred(ids)
                }
                .onDeleteCommand { requestDelete(personalIDs(selection)) }
                .onKeyPress(phases: .down) { press in listKey(press) }
                .onChange(of: selection) {
                    if selection.count == 1, let id = selection.first { proxy.scrollTo(id) }
                }
            }
            .overlay {
                if project == nil, model.snippets.isEmpty {
                    ContentUnavailableView {
                        Label("No Snippets", systemImage: "bookmark")
                    } description: {
                        Text("Save code you reuse. A snippet can be tied to a target or work with any target.")
                    } actions: {
                        Button("Save Current Tab as Snippet") { requestSaveCurrentTab() }
                            .disabled(model.selectedTab == nil)
                    }
                } else if !search.isEmpty, snippets.isEmpty, projectSnippets.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }

            Divider()
            footer(visibleCount: snippets.count, projectCount: project == nil ? nil : projectSnippets.count)
        }
        .sheet(item: $editing) { snippet in
            SnippetEditSheet(snippet: snippet)
                .environment(model)
        }
        .confirmationDialog(deleteTitle, isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                deleteConfirmed()
            }
            Button("Cancel", role: .cancel) { pendingDelete = [] }
        } message: {
            Text("This can't be undone.")
        }
        .onAppear {
            // Pick up files added or changed in the project since the pane was last shown.
            if let target = model.selectedTab?.target { model.refreshProjectSnippets(for: target) }
        }
        .onChange(of: validIDs) { _, ids in
            selection.formIntersection(ids)
        }
        // Typing narrows the list to its best match, ready for ↩.
        .onChange(of: search) {
            selection = orderedIDs.first.map { [$0] } ?? []
        }
    }

    @ViewBuilder
    private func personalRows(_ snippets: [Snippet]) -> some View {
        ForEach(snippets) { snippet in
            SnippetRow(snippet: snippet)
                .tag(SnippetItemID.personal(snippet.id))
                .id(SnippetItemID.personal(snippet.id))
        }
    }

    // MARK: Keyboard

    /// The visible rows in list order: project snippets, then personal ones.
    private var orderedIDs: [SnippetItemID] {
        let project = projectContext.map { filteredProjectSnippets($0.snippets).map { SnippetItemID.project($0.id) } } ?? []
        return project + filteredSnippets.map { .personal($0.id) }
    }

    /// ↑/↓ from the search field: moves the selection through the visible rows.
    private func moveSelection(_ delta: Int) {
        let ids = orderedIDs
        guard !ids.isEmpty else { return }
        let current = ids.lastIndex { selection.contains($0) }
        let next = current.map { min(max($0 + delta, 0), ids.count - 1) } ?? 0
        selection = [ids[next]]
    }

    /// ↩, ⌘↩, ⇧↩ (from the search field or the list): the selected snippet, or the first one
    /// when nothing is selected. Only loads code, then hands the keyboard to the editor.
    private func perform(_ action: LibraryKeyAction) {
        let ids = orderedIDs
        guard let id = ids.first(where: { selection.contains($0) }) ?? ids.first else { return }
        switch action {
        case .open:
            openPreferred([id])
        case .openInNewTab:
            openInNewTab([id])
        case .insert:
            if let snippet = single([id]) {
                model.insert(snippet)
            } else if let item = singleProject([id]) {
                model.insert(item.snippet, target: item.target)
            }
        }
        // A parameterised snippet's form (#14) keeps the keyboard until it closes.
        if model.snippetInputRequest == nil { model.focusSelectedEditor() }
    }

    /// Keys in the list itself: ⌘↩ and ⇧↩ (plain ↩ is the primary action, like double-click),
    /// and typing, which goes on in the search field.
    private func listKey(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .return {
            if press.modifiers.contains(.command) {
                perform(.openInNewTab)
            } else if press.modifiers.contains(.shift) {
                perform(.insert)
            } else {
                return .ignored
            }
            return .handled
        }
        guard press.isTyping else { return .ignored }
        search += press.characters
        LibrarySearchFocus.request(.snippets, selectAll: false)
        return .handled
    }

    /// Deletes the snippets the user confirmed and selects the next row, so ⌫ can go on.
    private func deleteConfirmed() {
        let visible = orderedIDs
        let deleted = Set(pendingDelete.map(SnippetItemID.personal))
        let first = visible.firstIndex { deleted.contains($0) }
        for id in pendingDelete { model.deleteSnippet(id) }
        selection.subtract(deleted)
        pendingDelete = []
        let remaining = visible.filter { !deleted.contains($0) }
        if selection.isEmpty, let first, !remaining.isEmpty {
            selection = [remaining[min(first, remaining.count - 1)]]
        }
    }

    /// The active tab's project snippets, when its target has a project folder.
    private struct ProjectContext {
        var target: TargetRef
        var name: String
        var root: URL
        var snippets: [ProjectSnippet]
    }

    private var projectContext: ProjectContext? {
        guard let target = model.selectedTab?.target, let root = model.projectRoot(for: target) else { return nil }
        return ProjectContext(target: target, name: model.projectName(for: target) ?? root.lastPathComponent, root: root, snippets: model.projectSnippets(for: target))
    }

    /// Every selectable row, used to drop selections whose rows went away.
    private var validIDs: Set<SnippetItemID> {
        var ids = Set(model.snippets.map { SnippetItemID.personal($0.id) })
        for snippet in projectContext?.snippets ?? [] { ids.insert(.project(snippet.id)) }
        return ids
    }

    private var filteredSnippets: [Snippet] {
        model.snippets.filter { snippet in
            matchesSearch(search, in: snippet.label, snippet.description ?? "", snippet.code, targetDescription(snippet))
        }
    }

    private func filteredProjectSnippets(_ snippets: [ProjectSnippet]) -> [ProjectSnippet] {
        snippets.filter { matchesSearch(search, in: $0.label, $0.description ?? "", $0.code, $0.fileURL.lastPathComponent) }
    }

    private func targetDescription(_ snippet: Snippet) -> String {
        guard let target = snippet.target else { return "Any target" }
        return targetIsSaved(target, in: model.library) ? model.targetLabel(target) : (snippet.targetLabel ?? model.targetLabel(target))
    }

    private var deleteTitle: String {
        if pendingDelete.count == 1, let id = pendingDelete.first, let snippet = model.snippets.first(where: { $0.id == id }) {
            return "Delete “\(snippet.label)”?"
        }
        return "Delete \(pendingDelete.count) snippets?"
    }

    private func personalIDs(_ ids: Set<SnippetItemID>) -> Set<Snippet.ID> {
        Set(ids.compactMap(\.personalID))
    }

    private func single(_ ids: Set<SnippetItemID>) -> Snippet? {
        guard ids.count == 1, let id = ids.first?.personalID else { return nil }
        return model.snippets.first { $0.id == id }
    }

    private func singleProject(_ ids: Set<SnippetItemID>) -> (snippet: ProjectSnippet, target: TargetRef)? {
        guard ids.count == 1, case .project(let path) = ids.first, let project = projectContext,
              let snippet = project.snippets.first(where: { $0.id == path }) else { return nil }
        return (snippet, project.target)
    }

    /// Double-click / Return: where Settings ▸ General says.
    private func openPreferred(_ ids: Set<SnippetItemID>) {
        if let snippet = single(ids) {
            model.open(snippet)
        } else if let item = singleProject(ids) {
            model.open(item.snippet, target: item.target)
        }
    }

    private func openInNewTab(_ ids: Set<SnippetItemID>) {
        if let snippet = single(ids) {
            model.open(snippet, inNewTab: true)
        } else if let item = singleProject(ids) {
            model.open(item.snippet, target: item.target, inNewTab: true)
        }
    }

    @ViewBuilder
    private func menu(for ids: Set<SnippetItemID>) -> some View {
        if let snippet = single(ids) {
            Button("Open in Current Tab") { model.open(snippet, inNewTab: false) }
                .disabled(model.selectedTab == nil)
            Button("Open in New Tab") { model.open(snippet, inNewTab: true) }
            Divider()
            Button("Edit…") { editing = snippet }
            Button("Duplicate") { duplicate(snippet) }
            Button("Copy Code") { Pasteboard.copy(snippet.code) }
            Divider()
        } else if let item = singleProject(ids) {
            Button("Open in Current Tab") { model.open(item.snippet, target: item.target, inNewTab: false) }
                .disabled(model.selectedTab == nil)
            Button("Open in New Tab") { model.open(item.snippet, target: item.target, inNewTab: true) }
            Divider()
            Button("Copy Code") { Pasteboard.copy(item.snippet.code) }
            Button("Copy to Personal Snippets") { copyToPersonal(item.snippet, target: item.target) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.snippet.fileURL]) }
        }
        let personal = personalIDs(ids)
        if !personal.isEmpty {
            Button(personal.count == 1 ? "Delete…" : "Delete \(personal.count) Snippets…", role: .destructive) { requestDelete(personal) }
        }
    }

    @ViewBuilder
    private func footer(visibleCount: Int, projectCount: Int?) -> some View {
        VStack(spacing: 6) {
            if let snippet = single(selection) {
                HStack(spacing: 6) {
                    Button("Open in Current Tab") { model.open(snippet, inNewTab: false) }
                        .disabled(model.selectedTab == nil)
                        .help("Replace the current tab's code with this snippet. The tab keeps its target and nothing runs.")
                        .accessibilityIdentifier("snippet-open-button")
                    Button("Open in New Tab") { model.open(snippet, inNewTab: true) }
                        .help("Open in a new tab using the snippet's target. Nothing runs.")
                        .accessibilityIdentifier("snippet-open-new-tab-button")
                    Spacer(minLength: 0)
                }
            } else if let item = singleProject(selection) {
                HStack(spacing: 6) {
                    Button("Open in Current Tab") { model.open(item.snippet, target: item.target, inNewTab: false) }
                        .disabled(model.selectedTab == nil)
                        .help("Replace the current tab's code with this project snippet. Nothing runs.")
                        .accessibilityIdentifier("project-snippet-open-button")
                    Button("Open in New Tab") { model.open(item.snippet, target: item.target, inNewTab: true) }
                        .help("Open in a new tab with this project's target. Nothing runs.")
                        .accessibilityIdentifier("project-snippet-open-new-tab-button")
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 6) {
                Text(countText(visibleCount, projectCount: projectCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityIdentifier("snippet-count")
                Spacer(minLength: 0)
                if let snippet = single(selection) {
                    Button("Edit…") { editing = snippet }
                        .accessibilityIdentifier("snippet-edit-button")
                } else if let item = singleProject(selection) {
                    Button("Copy to Personal") { copyToPersonal(item.snippet, target: item.target) }
                        .help("Save a personal copy (associated with this project) that you can edit.")
                        .accessibilityIdentifier("project-snippet-copy-personal-button")
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func countText(_ visible: Int, projectCount: Int?) -> String {
        let total = model.snippets.count
        let noun = total == 1 ? "snippet" : "snippets"
        var text = search.isEmpty || visible == total ? "\(total.formatted()) \(noun)" : "\(visible.formatted()) of \(total.formatted()) \(noun)"
        if let projectCount { text += " · \(projectCount.formatted()) project" }
        return text
    }

    private func requestSaveCurrentTab() {
        NotificationCenter.default.post(name: .saveSnippetRequested, object: nil)
    }

    private func requestDelete(_ ids: Set<Snippet.ID>) {
        guard !ids.isEmpty else { return }
        pendingDelete = ids
        confirmDelete = true
    }

    private func duplicate(_ snippet: Snippet) {
        let copy = model.saveSnippet(label: snippet.label + " copy", code: snippet.code, target: snippet.target, description: snippet.description)
        selection = [.personal(copy.id)]
    }

    private func copyToPersonal(_ snippet: ProjectSnippet, target: TargetRef) {
        let copy = model.copyToPersonalSnippets(snippet, target: target)
        selection = [.personal(copy.id)]
    }
}

/// "Project snippets — <name>" with a Refresh button.
private struct ProjectSectionHeader: View {
    let name: String
    let root: URL
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text("Project snippets — \(name)")
                .lineLimit(1)
                .truncationMode(.middle)
                .help("Shared files in \(root.appendingPathComponent(ProjectSnippets.relativeDirectory).path)")
            Spacer(minLength: 4)
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Reload \(ProjectSnippets.relativeDirectory)")
            .accessibilityLabel("Reload Project Snippets")
            .accessibilityIdentifier("project-snippets-refresh")
        }
    }
}

/// A read-only project snippet (a file in `.runlet/snippets`).
private struct ProjectSnippetRow: View {
    @Environment(AppModel.self) private var model
    let snippet: ProjectSnippet
    let projectName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(snippet.label)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            if let description = snippet.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 4) {
                ProjectBadge(fileName: snippet.fileURL.lastPathComponent)
                SnippetInputsBadge(inputs: snippet.inputs)
            }
            Text(CodePreview.lines(snippet.code, limit: 2))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .help("\(ProjectSnippets.relativeDirectory)/\(snippet.fileURL.lastPathComponent) in \(projectName)\nShared through the project and read-only here: edit the file to change it.\nDouble-click \(LibraryOpenHint.text(model.settings.libraryOpenBehavior)). Opening never runs code.")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("project-snippet-row")
    }
}

/// Marks a snippet that comes from the project folder.
private struct ProjectBadge: View {
    let fileName: String

    var body: some View {
        Label {
            Text("Project · \(fileName)").lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: "folder.badge.person.crop")
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.teal)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.teal.opacity(0.13)))
    }
}

private struct SnippetRow: View {
    @Environment(AppModel.self) private var model
    let snippet: Snippet

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(snippet.label)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(snippet.updatedAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let description = snippet.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(description)
            }
            HStack(spacing: 4) {
                TargetBadge(snippet: snippet)
                SnippetInputsBadge(inputs: snippet.inputs)
            }
            Text(CodePreview.lines(snippet.code, limit: 2))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .help("Updated \(snippet.updatedAt.formatted(date: .abbreviated, time: .shortened))\nDouble-click \(LibraryOpenHint.text(model.settings.libraryOpenBehavior)). Opening never runs code.")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("snippet-row")
    }
}

/// Shows a snippet's explicit target association (or "Any target").
private struct TargetBadge: View {
    @Environment(AppModel.self) private var model
    let snippet: Snippet

    var body: some View {
        let (text, symbol, tint) = content
        Label {
            Text(text).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.13)))
        .help(snippet.target == nil ? "Not tied to a target; opens with the default target in a new tab." : "Opens in a new tab with this target.")
    }

    private var content: (String, String, Color) {
        guard let target = snippet.target else { return ("Any target", "circle.dashed", .secondary) }
        if targetIsSaved(target, in: model.library) {
            return (model.targetLabel(target), model.targetSymbol(target), .accentColor)
        }
        return ("\(snippet.targetLabel ?? model.targetLabel(target)) (missing)", "exclamationmark.triangle", .orange)
    }
}

// MARK: - Snippet editor

private struct SnippetEditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var snippet: Snippet
    private let original: Snippet

    init(snippet: Snippet) {
        original = snippet
        _snippet = State(initialValue: snippet)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Snippet").font(.headline)
            TextField("Label", text: $snippet.label)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("snippet-edit-label")
            TextField("Description (optional)", text: Binding(
                get: { snippet.description ?? "" },
                set: { snippet.description = $0.isEmpty ? nil : $0 }
            ))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("snippet-edit-description")
            Picker("Target", selection: $snippet.target) {
                Label("Any target", systemImage: "circle.dashed").tag(TargetRef?.none)
                Divider()
                Label(model.targetLabel(.sandbox), systemImage: model.targetSymbol(.sandbox)).tag(TargetRef?.some(.sandbox))
                if !model.library.localProjects.isEmpty {
                    Section("Local Projects") {
                        ForEach(model.library.localProjects) { project in
                            Label(project.name, systemImage: "folder").tag(TargetRef?.some(.local(project.id)))
                        }
                    }
                }
                if !model.library.dockerProfiles.isEmpty {
                    Section("Docker Applications") {
                        ForEach(model.library.dockerProfiles) { profile in
                            Label(profile.name, systemImage: "cube.box").tag(TargetRef?.some(.docker(profile.id)))
                        }
                    }
                }
                if let target = original.target, !targetIsSaved(target, in: model.library) {
                    Text("\(original.targetLabel ?? "Removed target") (missing)").tag(TargetRef?.some(target))
                }
            }
            .accessibilityIdentifier("snippet-edit-target")
            Text("Opening a snippet in a new tab uses its target. Opening it into the current tab keeps that tab's target.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SnippetCodeEditor(text: $snippet.code, fontSize: model.settings.fontSize)
                .frame(minHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                .accessibilityIdentifier("snippet-edit-code")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    var updated = snippet
                    let label = updated.label.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.label = label.isEmpty ? "Untitled snippet" : label
                    model.updateSnippet(updated)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(snippet == original)
                .accessibilityIdentifier("snippet-edit-save")
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 420, idealHeight: 480)
    }
}

/// Plain monospaced code editor for the snippet sheet, with smart quotes, dashes, and
/// other substitutions disabled so PHP code is never altered while typing.
private struct SnippetCodeEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: Double

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.font = .monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        textView.string = text
        textView.delegate = context.coordinator
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let font = NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        if textView.font != font { textView.font = font }
        if textView.string != text { textView.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

// MARK: - Shared

/// Short, readable previews of PHP code for list rows, palette rows, and default snippet labels.
enum CodePreview {
    /// Meaningful lines: skips blank lines and a leading `<?php` tag.
    static func meaningfulLines(_ code: String) -> [String] {
        code.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "<?php" && $0 != "<?" }
    }

    static func lines(_ code: String, limit: Int) -> String {
        let lines = meaningfulLines(code)
        guard !lines.isEmpty else { return "(empty)" }
        return lines.prefix(limit).joined(separator: "\n")
    }

    /// The first meaningful line, shortened for use as a label.
    static func title(_ code: String, maxLength: Int = 60) -> String {
        guard var line = meaningfulLines(code).first else { return "Untitled snippet" }
        if line.hasPrefix("<?php ") { line = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        return line.count > maxLength ? String(line.prefix(maxLength - 1)) + "…" : line
    }
}

/// Whether a target still refers to a saved project/profile (the sandbox always exists).
private func targetIsSaved(_ target: TargetRef, in library: TargetLibrary) -> Bool {
    switch target {
    case .sandbox: true
    case .local(let id): library.localProject(id) != nil
    case .docker(let id): library.dockerProfile(id) != nil
    case .ssh(let id): library.sshProfile(id) != nil
    }
}
