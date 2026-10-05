import AppKit
import Observation
import RunletCore

/// The Quick Run panel's state (#25): its tab, which is in no window, and the global shortcut.
@MainActor
@Observable
final class QuickRunModel {
    /// The panel's code and target until it first opens: the saved session's, or what Open in Tab
    /// left. Afterwards the tab holds them.
    var draft = QuickRunDraft()
    /// The panel's tab, made when the panel first opens: its editor, its runs, and their output.
    fileprivate(set) var tab: TabModel?
    /// Why the last ⌘R ran nothing, until the next run, edit, or target.
    var refusal: String?
    /// Whether the panel is on screen.
    fileprivate(set) var isOpen = false
    /// Settings ▸ Shortcuts ▸ Quick Run: where the global shortcut stands.
    var hotKeyStatus: GlobalHotKeyStatus = .off
    @ObservationIgnored fileprivate var hotKeys: GlobalHotKeyController?
}

extension AppModel {
    // MARK: The panel's tab

    /// The panel's tab, made from the draft (and its language bound) on first use. Nothing runs.
    @discardableResult
    func quickRunTab() -> TabModel {
        if let tab = quickRun.tab { return tab }
        let draft = QuickRun.restored(quickRun.draft, in: library)
        let caret = NSRangeCodable(location: (draft.code as NSString).length, length: 0)
        let tab = TabModel(state: TabState(title: QuickRun.tabTitle, code: draft.code, target: draft.target, selection: caret))
        tab.isQuickRun = true
        tab.onChange = { [weak self] change in
            guard let self, change == .content else { return }
            self.quickRun.refusal = nil
            self.scheduleSessionSave()
        }
        // Esc that the editor didn't need (completions, find bar) closes the panel.
        tab.onEditorEscape = { [weak self] in
            self?.closeQuickRun()
            return true
        }
        tab.defaultModelDisplay = { [weak self] in self?.settings.modelDisplay ?? .values } // #307
        tab.onModelDisplayPick = { [weak self, weak tab] display in
            guard let self, let tab else { return }
            self.setModelDisplay(display, for: tab)
        }
        quickRun.tab = tab
        bindLanguage(tab)
        return tab
    }

    /// The panel's code and target as the session saves them; nil while it was never used.
    var quickRunDraftForSaving: QuickRunDraft? {
        let draft = quickRun.tab.map { QuickRunDraft(code: $0.editorIfLoaded?.text ?? $0.code, target: $0.target) } ?? quickRun.draft
        return draft == QuickRunDraft() ? nil : draft
    }

    /// What the target's application said its environment was on its last run (#12).
    private func reportedEnvironment(_ target: TargetRef) -> String? {
        targetFacts[target.stableKey]?.appEnvironment
    }

    /// The targets the panel's picker offers: never a production one (`QuickRun.offeredTargets`).
    var quickRunTargets: [TargetRef] {
        QuickRun.offeredTargets(in: library, reportedEnvironments: targetFacts.compactMapValues(\.appEnvironment))
    }

    /// Why the panel won't run on `target` now, or nil.
    func quickRunRefusal(for target: TargetRef) -> String? {
        QuickRun.refusal(for: target, in: library, reportedEnvironment: reportedEnvironment(target))
    }

    // MARK: Opening and closing

    /// Shows the panel (Window ▸ Quick Run, the command palette, Open Anything, the global
    /// shortcut), with the keyboard in its editor. Opening runs nothing.
    func showQuickRun() {
        let tab = quickRunTab()
        // A target removed while the panel was away: back to the sandbox.
        if validTarget(tab.target) != tab.target { setTarget(.sandbox, for: tab) }
        QuickRunPanelController.shared(model: self).show(tab)
        quickRun.isOpen = true
    }

    /// The global shortcut: opens the panel, or closes it when it's open with the keyboard.
    func toggleQuickRun() {
        if quickRun.isOpen, QuickRunPanelController.current?.hasKeyboard == true {
            closeQuickRun()
        } else {
            showQuickRun()
        }
    }

    /// Esc, ⌘W, or the close button. The panel keeps its code, and a run goes on.
    func closeQuickRun() {
        quickRun.tab?.editorIfLoaded?.hidePopups()
        QuickRunPanelController.current?.hide()
        quickRun.isOpen = false
        scheduleSessionSave()
    }

    /// Whether the panel has the keyboard: the Run menu then acts on it, not on a tab behind it.
    var quickRunHasKeyboard: Bool {
        quickRun.isOpen && QuickRunPanelController.current?.hasKeyboard == true
    }

    // MARK: Target, run, and Open in Tab

    /// The picker: only offered targets, never a production one.
    func setQuickRunTarget(_ target: TargetRef) {
        guard quickRunTargets.contains(target) else { return NSSound.beep() }
        let tab = quickRunTab()
        quickRun.refusal = nil
        setTarget(target, for: tab)
    }

    /// ⌘R, and only ⌘R: runs the panel's code through the same pipeline as a tab's Run (History,
    /// the run inspector, magic comments, the runner's limits). The target is checked again now,
    /// so one marked production since it was picked, or whose application said it runs in
    /// production, is refused with the reason, and nothing runs.
    func runQuickRun() {
        let tab = quickRunTab()
        guard !tab.isRunning else { return }
        let code = tab.editor.text
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let refusal = quickRunRefusal(for: tab.target) {
            quickRun.refusal = refusal
            NSSound.beep()
            return
        }
        quickRun.refusal = nil
        startRun(tab, code: code, selection: nil)
    }

    /// ⌘. in the panel.
    func stopQuickRun() {
        if let tab = quickRun.tab, tab.isRunning { stop(tab) }
    }

    /// Open in Tab (⌘↩): the panel's tab, with its code, target, and output, moves into the
    /// active editor window (a new one when none is open), which comes forward. The panel closes
    /// and starts empty next time, on the same target. Nothing runs; a production target's tab
    /// asks before each run, as usual.
    func openQuickRunInTab() {
        guard let tab = quickRun.tab else { return }
        guard let handoff = QuickRun.handoff(QuickRunDraft(code: tab.editor.text, target: tab.target), in: library) else { return NSSound.beep() }
        // The panel lets go of the editor first; it makes a new tab when it opens again.
        tab.editorIfLoaded?.hidePopups()
        QuickRunPanelController.current?.hide(releasing: tab)
        quickRun.isOpen = false
        quickRun.tab = nil
        quickRun.refusal = nil
        quickRun.draft = handoff.remaining
        tab.isQuickRun = false
        tab.title = handoff.title
        if tab.target != handoff.target { setTarget(handoff.target, for: tab) }
        QuickRunEditorStyle.restore(tab.editor)
        let window: WindowModel
        let isNew: Bool
        if let active = activeWindow, active.nsWindow != nil {
            (window, isNew) = (active, false)
        } else if let shown = windows.first(where: { $0.nsWindow != nil }) ?? windows.first {
            (window, isNew) = (shown, shown.nsWindow == nil)
        } else {
            let made = WindowModel()
            windows.append(made)
            (window, isNew) = (made, true)
        }
        adopt(tab, into: window)
        activeWindowId = window.id
        scheduleSessionSave()
        if isNew {
            if let open = openWindowAction { open(window.id) } else { AppDelegate.ensureMainWindow() }
        }
        bringQuickRunTabForward(window)
    }

    /// Opening a window or a tab from the panel brings Runlet forward, unless a scripted Debug
    /// run is checking it (it must never take the keyboard from the app in front).
    private func bringQuickRunTabForward(_ window: WindowModel) {
        guard QuickRunPanel.mayTakeKeyboard else { return }
        NSApp.activate()
        if window.nsWindow?.isMiniaturized == true { window.nsWindow?.deminiaturize(nil) }
        window.nsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Global shortcut

    /// Registers, re-registers, or unregisters the global shortcut as Settings say (at launch,
    /// and when the setting or Runlet's own shortcuts change).
    func applyQuickRunHotKey() {
        let controller = quickRun.hotKeys ?? GlobalHotKeyController(registrar: Self.makeHotKeyRegistrar()) { [weak self] in
            self?.toggleQuickRun()
        }
        quickRun.hotKeys = controller
        var titles: [String: KeyCombo] = [:]
        for (id, combo) in effectiveShortcuts {
            if let title = CommandCatalog.byId[id]?.title { titles[title] = combo }
        }
        quickRun.hotKeyStatus = controller.apply(enabled: settings.quickRunHotKeyEnabled, hotKey: settings.quickRunHotKey, appShortcuts: titles)
    }

    /// Unregisters the global shortcut (quitting).
    func releaseQuickRunHotKey() {
        quickRun.hotKeys?.release()
    }

    /// Carbon's, except in scripted Debug runs, which never register a global shortcut.
    private static func makeHotKeyRegistrar() -> any GlobalHotKeyRegistering {
        #if DEBUG
        if ProcessInfo.processInfo.environment.keys.contains(where: { $0.hasPrefix("RUNLET_DEBUG_") }) { return DebugHotKeyRegistrar.shared }
        #endif
        return CarbonHotKeyRegistrar()
    }
}
