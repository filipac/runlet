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
    /// Window ▸ Float on Top: stays above other apps' windows (for this launch only).
    var isFloating = false
    /// Terminal tabs of this window (live only while Runlet runs; never persisted).
    let terminals = TerminalPanelModel()
    /// The window on screen (set once SwiftUI shows it), for bringing it forward.
    @ObservationIgnored weak var nsWindow: NSWindow?
    /// The tab being renamed, in either tab layout (#285); nil when none is.
    var rename: TabRenameSession?
    /// A tab being dragged along the horizontal tab bar, and where the tabs sit in it (#322).
    let tabStripDrag = TabStripDragState()

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

    /// The tabs' order and pins (#279), to apply `TabPinOrder`'s rules to.
    var pinOrder: TabPinOrder<UUID> {
        TabPinOrder(ids: tabs.map(\.id), pinned: Set(tabs.filter(\.isPinned).map(\.id)))
    }

    /// How many tabs are pinned: they are the first ones (#279).
    var pinnedCount: Int { tabs.prefix { $0.isPinned }.count }

    /// Puts the tabs in `order`'s order and sets their pins (#279). Returns whether anything
    /// changed; an order of other tabs changes nothing.
    @discardableResult
    func apply(_ order: TabPinOrder<UUID>) -> Bool {
        let byId = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let reordered = order.ids.compactMap { byId[$0] }
        guard reordered.count == tabs.count else { return false }
        var changed = false
        for tab in reordered where tab.isPinned != order.isPinned(tab.id) {
            tab.setPinnedFlag(order.isPinned(tab.id))
            changed = true
        }
        if reordered.map(\.id) != tabs.map(\.id) {
            tabs = reordered
            changed = true
        }
        return changed
    }

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
