import AppKit
import RunletCore

/// Recently closed tabs (most recent last), so ⇧⌘T can bring them back with their code.
struct ClosedTab {
    var state: TabState
    var windowId: UUID
    var index: Int
}

extension AppModel {
    /// Keeps the last 20 closed tabs that had any code.
    func rememberClosedTab(_ tab: TabModel, in window: WindowModel, at index: Int) {
        var state = tab.state
        state.code = tab.editorIfLoaded?.text ?? tab.code
        guard !state.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || tab.fileURL != nil else { return }
        closedTabs.append(ClosedTab(state: state, windowId: window.id, index: index))
        if closedTabs.count > 20 { closedTabs.removeFirst(closedTabs.count - 20) }
    }

    var canReopenClosedTab: Bool { !closedTabs.isEmpty }

    /// Reopens the most recently closed tab (in its original window if still open). Never runs code.
    func reopenClosedTab() {
        guard let closed = closedTabs.popLast() else { return }
        let window = self.window(closed.windowId) ?? activeWindow ?? makeWindow()
        var state = closed.state
        state.id = UUID()
        let tab = newTab(target: validTarget(state.target), code: state.code, title: state.title, in: window)
        tab.fileURL = state.fileURL
        if let index = window.index(of: tab.id) {
            window.tabs.remove(at: index)
            window.tabs.insert(tab, at: min(closed.index, window.tabs.count))
        }
        window.selectedTabId = tab.id
        activeWindowId = window.id
        openWindowAction?(window.id)
    }

    func closeTabsToRight(of id: UUID) {
        guard let window = window(containing: id), let index = window.index(of: id) else { return }
        for tab in window.tabs[(index + 1)...] { closeTab(tab.id) }
    }

    /// Selects a tab by 0-based position in the active window; -1 selects the last tab.
    func selectTab(position: Int) {
        guard let window = activeWindow, !window.tabs.isEmpty else { return }
        let index = position < 0 ? window.tabs.count - 1 : position
        guard window.tabs.indices.contains(index) else { return }
        window.selectedTabId = window.tabs[index].id
    }
}

extension AppModel {
    /// Asks, then removes a saved local project or Docker profile from Runlet. The project
    /// folder and the container are not touched; tabs using it switch to the sandbox.
    func confirmDeleteTarget(_ target: TargetRef) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch target {
        case .sandbox:
            return
        case .local(let id):
            guard let project = library.localProject(id) else { return }
            alert.messageText = "Remove the project “\(project.name)” from Runlet?"
            alert.informativeText = "The folder \((project.path as NSString).abbreviatingWithTildeInPath) is not touched. Tabs using this project switch to the Laravel Sandbox; their code stays."
        case .docker(let id):
            guard let profile = library.dockerProfile(id) else { return }
            alert.messageText = "Delete the Docker profile “\(profile.name)”?"
            alert.informativeText = "This removes it from Runlet only; the container keeps running. Tabs using this profile switch to the Laravel Sandbox; their code stays."
        }
        alert.addButton(withTitle: target.isDocker ? "Delete Profile" : "Remove Project")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        switch target {
        case .local(let id): removeProject(id)
        case .docker(let id): removeDockerProfile(id)
        case .sandbox: break
        }
    }
}

extension TargetRef {
    var isDocker: Bool {
        if case .docker = self { return true }
        return false
    }
}
