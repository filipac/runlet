import AppKit
import Observation
import RunletCore

/// One window: its tabs, selection, and optional `.runlet` workspace file.
@MainActor
@Observable
final class WindowModel: Identifiable {
    let id: UUID
    var tabs: [TabModel] = []
    var selectedTabId: UUID?
    /// The workspace file this window was opened from or saved to.
    var workspaceURL: URL?
    /// Unsaved changes relative to `workspaceURL` (document-style).
    var isWorkspaceEdited = false
    /// Terminal tabs of this window (live only while Runlet runs; never persisted).
    let terminals = TerminalPanelModel()

    init(id: UUID = UUID()) {
        self.id = id
    }

    var selectedTab: TabModel? { tabs.first { $0.id == selectedTabId } ?? tabs.first }

    var title: String {
        guard let workspaceURL else { return "Runlet" }
        return workspaceURL.deletingPathExtension().lastPathComponent
    }

    /// Marks unsaved workspace changes (only meaningful for workspace windows).
    func markEdited() {
        if workspaceURL != nil, !isWorkspaceEdited { isWorkspaceEdited = true }
    }

    func index(of tabId: UUID) -> Int? { tabs.firstIndex { $0.id == tabId } }

    var state: WindowState {
        WindowState(id: id, tabs: tabs.map(\.state), selectedTabId: selectedTabId, workspacePath: workspaceURL?.path, workspaceEdited: isWorkspaceEdited)
    }

    /// Code in tabs that would be lost if the window closed now: not backed by a saved file
    /// or a saved workspace.
    var hasUnsavedScratchCode: Bool {
        if workspaceURL != nil { return isWorkspaceEdited }
        return tabs.contains { tab in
            let code = tab.editorIfLoaded?.text ?? tab.code
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && (tab.fileURL == nil || tab.isFileDirty)
        }
    }
}
