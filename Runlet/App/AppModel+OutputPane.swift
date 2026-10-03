import RunletCore

/// Showing and hiding the output pane (#60): Show/Hide Output Pane, Move Output Right/Below,
/// and Settings ▸ General ▸ Output's "Hide the output pane until a run" and "Escape hides the
/// output pane". The rules are in `OutputPaneVisibility`; here they meet the saved settings
/// (app-wide) and the tab (`TabModel.outputPaneRevealed`, `outputPaneDismissed`). The pane's
/// layout and split position are never touched: it reappears where it was, at its size.
extension AppModel {
    func outputPaneVisibility(for tab: TabModel?) -> OutputPaneVisibility {
        OutputPaneVisibility(paneVisible: settings.outputVisible, hideUntilRun: settings.hideOutputUntilRun,
                             tabRevealed: tab?.outputPaneRevealed ?? false, tabDismissed: tab?.outputPaneDismissed ?? false)
    }

    /// Whether the window showing `tab` shows the output pane next to or below the editor.
    func isOutputPaneShown(for tab: TabModel?) -> Bool {
        outputPaneVisibility(for: tab).isShown
    }

    func updateOutputPane(_ event: OutputPaneVisibility.Event, for tab: TabModel?) {
        var visibility = outputPaneVisibility(for: tab)
        visibility.apply(event)
        store(visibility, for: tab)
    }

    /// Clear Output (⌘K or the output pane's button). Under Hide the output pane until a run,
    /// an idle tab's pane hides again until its next run.
    func clearOutput(_ tab: TabModel) {
        tab.clearOutput()
        updateOutputPane(.outputCleared(running: tab.isRunning), for: tab)
    }

    /// Escape in `tab`'s editor that the editor didn't need: with Escape hides the output pane,
    /// hides the tab's pane until its next run. Returns whether it did.
    func editorEscapePressed(in tab: TabModel) -> Bool {
        var visibility = outputPaneVisibility(for: tab)
        guard visibility.escape(hidesPane: settings.escapeHidesOutput) else { return false }
        store(visibility, for: tab)
        return true
    }

    private func store(_ visibility: OutputPaneVisibility, for tab: TabModel?) {
        if settings.outputVisible != visibility.paneVisible { settings.outputVisible = visibility.paneVisible }
        guard let tab else { return }
        if tab.outputPaneRevealed != visibility.tabRevealed { tab.outputPaneRevealed = visibility.tabRevealed }
        if tab.outputPaneDismissed != visibility.tabDismissed { tab.outputPaneDismissed = visibility.tabDismissed }
    }
}
