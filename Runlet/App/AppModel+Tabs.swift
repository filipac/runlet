import AppKit
import RunletCore

/// Recently closed tabs (most recent last), so ⇧⌘T can bring them back with their code.
struct ClosedTab {
    var state: TabState
    var windowId: UUID
    var index: Int
}

extension AppModel {
    /// Keeps the last 20 closed tabs that had any code, a file, or a pin: ⇧⌘T brings a closed
    /// pinned tab back pinned, even an empty one (#279).
    func rememberClosedTab(_ tab: TabModel, in window: WindowModel, at index: Int) {
        var state = tab.state
        state.code = tab.editorIfLoaded?.text ?? tab.code
        guard !state.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || tab.fileURL != nil || tab.isPinned else { return }
        closedTabs.append(ClosedTab(state: state, windowId: window.id, index: index))
        if closedTabs.count > 20 { closedTabs.removeFirst(closedTabs.count - 20) }
    }

    var canReopenClosedTab: Bool { !closedTabs.isEmpty }

    /// Reopens the most recently closed tab (in its original window if still open). Never runs
    /// code. A pinned tab comes back pinned, at its old position among the pinned tabs (or the
    /// last of them); an unpinned one never lands among them (#279).
    func reopenClosedTab() {
        guard let closed = closedTabs.popLast() else { return }
        let window = self.window(closed.windowId) ?? activeWindow ?? makeWindow()
        var state = closed.state
        state.id = UUID()
        let tab = newTab(target: validTarget(state.target), code: state.code, title: state.title, in: window, language: state.language, sqlConnection: state.sqlConnection, sqlSavedConnection: state.sqlSavedConnection, sqlSavedConnectionName: state.sqlSavedConnectionName)
        tab.fileURL = state.fileURL
        if let index = window.index(of: tab.id) {
            window.tabs.remove(at: index)
            // Back where it was, pinned if it was (#279), inside its group.
            var order = window.pinOrder
            order.reinsert(tab.id, at: closed.index, pinned: state.isPinned)
            window.tabs.insert(tab, at: order.ids.firstIndex(of: tab.id) ?? window.tabs.count)
            tab.setPinnedFlag(state.isPinned)
        }
        window.selectedTabId = tab.id
        activeWindowId = window.id
        openWindowAction?(window.id)
    }

    /// Close Tab (⌘W, File ▸ Close Tab) on the selected tab, once the palette, a sheet or window
    /// in front, and a focused terminal have had their turn. A pinned tab asks first, in a sheet
    /// on its window (#279): Close (Return) or Cancel (Esc; ⌘W on the sheet cancels it too). The
    /// tab's context menu closes it without asking.
    func closeTabForCommandW(_ tab: TabModel) {
        guard TabPinning.asksBeforeClosing(pinned: tab.isPinned, request: .closeTabCommand) else { return closeTab(tab.id) }
        guard pinnedClosePrompt == nil, let window = window(containing: tab.id) else { return }
        // Without a window on screen there's nothing to ask on; the close stays undoable.
        guard let host = window.nsWindow, host.isVisible else { return closeTab(tab.id) }
        guard host.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Close pinned tab?"
        let reopen = shortcut(for: "tabs.reopenClosed").map { "Reopen Closed Tab (\($0.displayString))" } ?? "Window ▸ Reopen Closed Tab"
        alert.informativeText = "“\(tab.title)” is pinned. \(reopen) brings it back, pinned."
        alert.addButton(withTitle: "Close")
        // NSAlert gives a button titled Cancel the Esc key.
        alert.addButton(withTitle: "Cancel")
        pinnedClosePrompt = (alert, tab.id)
        let id = tab.id
        alert.beginSheetModal(for: host) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pinnedClosePrompt = nil
                if response == .alertFirstButtonReturn { self.closeTab(id) }
            }
        }
    }

    /// Closes the tabs to the right of a tab, except pinned ones (#279).
    func closeTabsToRight(of id: UUID) {
        guard let window = window(containing: id) else { return }
        for tab in window.pinOrder.closedByCloseToRight(of: id) { closeTab(tab) }
    }

    /// Why Close Other Tabs closes nothing when the other tabs are all pinned (#279).
    func pinnedTabsStayReason(for id: UUID) -> String? {
        guard let window = window(containing: id), window.tabs.contains(where: { $0.id != id && $0.isPinned }) else { return nil }
        return "Pinned tabs stay open: unpin a tab, or close it with ⌘W."
    }

    /// Whether Close Tabs to the Right would close anything: pinned tabs stay (#279).
    func canCloseTabsToRight(of id: UUID) -> Bool {
        window(containing: id).map { !$0.pinOrder.closedByCloseToRight(of: id).isEmpty } ?? false
    }

    /// ⌘1…⌘8 select the nth tab of the active window as shown (pinned tabs first, #279); ⌘9
    /// the last one.
    func selectTab(shortcut number: Int) {
        guard let window = activeWindow, let id = window.pinOrder.tab(forShortcut: number) else { return }
        window.selectedTabId = id
    }
}

extension AppModel {
    /// Asks, then removes a saved local project, Docker profile, or SSH profile from Runlet.
    /// The project folder, the container, and the server are not touched; tabs using it
    /// switch to the sandbox. Returns whether it was removed.
    @discardableResult
    func confirmDeleteTarget(_ target: TargetRef) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch target {
        case .sandbox:
            return false
        case .local(let id):
            guard let project = library.localProject(id) else { return false }
            alert.messageText = "Remove the project “\(project.name)” from Runlet?"
            alert.informativeText = "The folder \((project.path as NSString).abbreviatingWithTildeInPath) is not touched. Tabs using this project switch to the Laravel Sandbox; their code stays."
        case .docker(let id):
            guard let profile = library.dockerProfile(id) else { return false }
            alert.messageText = "Delete the Docker profile “\(profile.name)”?"
            alert.informativeText = "This removes it from Runlet only; the container keeps running. Tabs using this profile switch to the Laravel Sandbox; their code stays."
        case .ssh(let id):
            guard let profile = library.sshProfile(id) else { return false }
            alert.messageText = "Delete the SSH profile “\(profile.name)”?"
            alert.informativeText = "This removes it from Runlet only and closes its connection; nothing on \(profile.destinationLabel) is touched. Tabs using this profile switch to the Laravel Sandbox; their code stays."
        }
        if let note = savedConnectionsNote(for: target) { alert.informativeText += " " + note }
        alert.addButton(withTitle: target.isProfile ? "Delete Profile" : "Remove Project")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        switch target {
        case .local(let id): removeProject(id)
        case .docker(let id): removeDockerProfile(id)
        case .ssh(let id): removeSSHProfile(id)
        case .sandbox: break
        }
        return true
    }
}

extension TargetRef {
    var isDocker: Bool {
        if case .docker = self { return true }
        return false
    }

    var isSSH: Bool {
        if case .ssh = self { return true }
        return false
    }

    /// A Docker or SSH profile (as opposed to a local project or the sandbox).
    var isProfile: Bool { isDocker || isSSH }
}
