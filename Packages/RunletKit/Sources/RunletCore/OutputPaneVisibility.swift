import Foundation

// Output pane auto-hide and Escape (#60): whether the output pane is shown next to or below
// the editor, and how runs, Clear Output, the Show/Hide command, and Escape change that.

/// Whether a tab's output pane is shown. Settings ▸ General ▸ Output has two switches, both
/// off by default: "Hide the output pane until a run" (`hideUntilRun`) and "Escape hides the
/// output pane" (see `escape(hidesPane:)`).
///
/// - With `hideUntilRun` off, the pane follows `paneVisible`: Show/Hide Output Pane, saved in
///   settings (`AppSettings.outputVisible`) and shared by every window, as before.
/// - With it on, each tab decides (`tabRevealed`, never saved): a tab shows the pane from the
///   moment a run starts in it, and hides it again when its output is cleared while it isn't
///   running. A tab that hasn't run since it was opened or restored shows the editor alone, so
///   switching tabs shows or hides the pane with the tab. Show/Hide Output Pane and Escape
///   change the current tab only, until its next run.
///
/// Nothing here moves or resizes the pane: when it appears it takes the saved layout (right or
/// below) and split position (`AppSettings.editorSplitRight` / `editorSplitBottom`). Opening,
/// importing, or restoring code never runs it, so it never reveals the pane either.
public struct OutputPaneVisibility: Sendable, Equatable {
    /// Show/Hide Output Pane (`AppSettings.outputVisible`), used while `hideUntilRun` is off.
    public var paneVisible: Bool
    /// Settings ▸ General ▸ Output ▸ Hide the output pane until a run.
    public var hideUntilRun: Bool
    /// The tab's own state, used while `hideUntilRun` is on: revealed by a run.
    public var tabRevealed: Bool

    public init(paneVisible: Bool = true, hideUntilRun: Bool = false, tabRevealed: Bool = false) {
        self.paneVisible = paneVisible
        self.hideUntilRun = hideUntilRun
        self.tabRevealed = tabRevealed
    }

    public var isShown: Bool { hideUntilRun ? tabRevealed : paneVisible }

    public enum Event: Sendable, Equatable {
        /// A run started in the tab: Run, Run Selection, Profile Run, an AI client's run the
        /// user approved, or the sandbox auto-run the user turned on for the tab.
        case runStarted
        /// Clear Output. A running tab keeps the pane, since more output is on the way.
        case outputCleared(running: Bool)
        /// Show/Hide Output Pane.
        case toggle
        /// Move Output Right/Below shows the pane in its new place.
        case show
        /// Hides the pane (Escape in the editor).
        case hide
    }

    public mutating func apply(_ event: Event) {
        switch event {
        case .runStarted:
            // Recorded whatever the setting, so turning it on later keeps showing the output
            // of tabs that already ran.
            tabRevealed = true
        case .outputCleared(let running):
            if !running { tabRevealed = false }
        case .toggle:
            setShown(!isShown)
        case .show:
            setShown(true)
        case .hide:
            setShown(false)
        }
    }

    /// Escape in the editor, once nothing in the editor wanted it (a completion list, a hover
    /// or inline-value panel, the find bar, text being composed): hides the pane when
    /// `hidesPane` (Settings ▸ General ▸ Output ▸ Escape hides the output pane) is on and the
    /// pane is shown. Returns whether it did, and so used the key.
    public mutating func escape(hidesPane: Bool) -> Bool {
        guard hidesPane, isShown else { return false }
        apply(.hide)
        return true
    }

    private mutating func setShown(_ shown: Bool) {
        if hideUntilRun { tabRevealed = shown } else { paneVisible = shown }
    }
}
