import AppKit
import RunletCore
import SwiftUI

// Shortcut tips (#345): a command that has a keyboard shortcut, run with the mouse (a menu item,
// a toolbar or window button) or from the palette, shows its shortcut in a small tip near the
// status bar. `ShortcutTipRule` decides; this file counts, shows, and saves.

/// One tip on screen, in one window.
struct ShortcutTip: Identifiable, Equatable {
    let id = UUID()
    let commandId: String
    let windowId: UUID
    /// The shortcut as the user mapped it, key by key, for key caps.
    let keys: [String]
    /// "⌃⌘T is the shortcut for Toggle Vertical Tabs. It saves a trip to the toolbar.", which
    /// VoiceOver reads.
    let text: String
    /// The same without the keys, which the tip shows as key caps before it.
    let predicate: String
    /// Above the status bar, or at the top of the tab's content when the caret's line is down
    /// there (the tip never covers it).
    let edge: VerticalEdge
}

/// The tip on screen (#345). Its own observable object, read only by the tip's views, so a tip
/// coming and going redraws nothing else in the window (#320).
@MainActor
@Observable
final class ShortcutTipPresenter {
    /// How long a tip stays.
    static let duration: Duration = .seconds(5)
    /// The height kept free for a tip at its edge: two lines of text and its padding.
    static let bandHeight: CGFloat = 64

    private(set) var current: ShortcutTip?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    /// Each window's tab content area (`ShortcutTipAnchor`), by window id: where a tip would go.
    @ObservationIgnored private var anchors: [UUID: WeakView] = [:]

    private struct WeakView { weak var view: NSView? }

    func show(_ tip: ShortcutTip) {
        current = tip
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.duration)
            guard !Task.isCancelled else { return }
            self?.hide(tip.id)
        }
        // VoiceOver reads it out; the tip itself never takes the keyboard.
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: tip.text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    /// Hides the tip (`id`: only if it is still that one).
    func hide(_ id: UUID? = nil) {
        guard let current, id == nil || current.id == id else { return }
        hideTask?.cancel()
        hideTask = nil
        self.current = nil
    }

    func setAnchor(_ view: NSView, for windowId: UUID) {
        if anchors[windowId]?.view !== view { anchors[windowId] = WeakView(view: view) }
    }

    /// Where a tip goes in `window`: above the status bar, unless the caret's line is there;
    /// then at the top of the tab's content; nil when the caret's line is in both places (an
    /// editor too short for a tip).
    func edge(in window: WindowModel) -> VerticalEdge? {
        guard let anchor = anchors[window.id]?.view, anchor.window != nil, anchor.window === window.nsWindow,
              let caret = window.selectedTab?.editorIfLoaded?.caretLineRectInWindow else { return .bottom }
        let area = anchor.convert(anchor.bounds, to: nil)
        let height = min(Self.bandHeight, area.height)
        let bottom = NSRect(x: area.minX, y: area.minY, width: area.width, height: height)
        let top = NSRect(x: area.minX, y: area.maxY - height, width: area.width, height: height)
        if !caret.intersects(bottom) { return .bottom }
        if !caret.intersects(top) { return .top }
        return nil
    }

    #if DEBUG
    /// For `shortcut-tip-state`: the anchor's frame and the caret's line, in window coordinates.
    func debugGeometry(in window: WindowModel) -> String {
        let anchor = anchors[window.id]?.view.map { NSStringFromRect($0.convert($0.bounds, to: nil)) } ?? "none"
        let caret = window.selectedTab?.editorIfLoaded?.caretLineRectInWindow.map(NSStringFromRect) ?? "none"
        return "area=\(anchor) caretLine=\(caret)"
    }
    #endif
}

extension EditorController {
    /// The caret's whole line across the visible editor, in window coordinates; nil when it is
    /// scrolled out of view or the editor isn't in a window (#345: a shortcut tip never covers it).
    var caretLineRectInWindow: NSRect? {
        guard let window = textView.window else { return nil }
        let location = min(textView.selectedRange().location, (textView.string as NSString).length)
        let screen = textView.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
        guard screen != .zero else { return nil }
        let caret = window.convertFromScreen(screen)
        let visible = scrollView.convert(scrollView.bounds, to: nil)
        let line = NSRect(x: visible.minX, y: caret.minY, width: visible.width, height: max(caret.height, 1)).intersection(visible)
        return line.isEmpty ? nil : line
    }
}

extension AppModel {
    /// Whether tips show: the setting, and in scripted Debug runs only after a step asked for
    /// them, so other features' screenshots never catch one.
    var shortcutTipsEnabled: Bool {
        #if DEBUG
        if ShortcutTipDebugSteps.isScriptedRun, !ShortcutTipDebugSteps.tipsAllowed { return false }
        #endif
        return settings.shortcutTips
    }

    /// Counts a use of the command `id` from `source`, and shows its shortcut tip in `window`
    /// when `ShortcutTipRule` says so. `perform` calls it; a button that does what a command does
    /// without running it (a tab's close button) calls it itself. Returns what the rule decided
    /// (nil for a use that isn't counted), for debug steps.
    @discardableResult
    func noteCommandUse(_ id: String, source: CommandSource, in window: WindowModel?, now: Date = Date()) -> ShortcutTipRule.Decision? {
        guard source.isCounted, let command = CommandCatalog.byId[id] else { return nil }
        let shortcut = shortcut(for: id)
        let decision = ShortcutTipRule.decide(source: source, shortcut: shortcut, entry: shortcutTipRecord.entry(id),
                                              enabled: shortcutTipsEnabled, now: now)
        var shown = false
        if decision == .show, let shortcut, let window, self.window(window.id) != nil, let edge = shortcutTips.edge(in: window) {
            shortcutTips.show(ShortcutTip(commandId: id, windowId: window.id, keys: shortcut.displayKeys,
                                          text: ShortcutTipText.sentence(keys: shortcut.displayString, title: command.title, source: source),
                                          predicate: ShortcutTipText.predicate(title: command.title, source: source), edge: edge))
            shown = true
        }
        shortcutTipRecord.record(id, source: source, tipShown: shown ? now : nil)
        scheduleShortcutTipSave()
        return decision
    }

    /// A tab's close button: closes that tab, as it always did (without Close Tab's checks for a
    /// sheet, a focused terminal, or a pinned tab). Closing the selected tab, which ⌘W would
    /// have closed, counts as a click on Close Tab.
    func closeTabFromButton(_ tab: TabModel, in window: WindowModel) {
        let asCommand = window.selectedTab?.id == tab.id && !tab.isPinned
        if asCommand { shortcutTips.hide() }
        closeTab(tab.id)
        if asCommand { noteCommandUse("file.closeTab", source: .button, in: window) }
    }

    /// The tip's Don't Show Again: that command's tip never shows again.
    func dontShowShortcutTip(_ tip: ShortcutTip) {
        shortcutTipRecord.dismissTip(tip.commandId)
        shortcutTips.hide(tip.id)
        scheduleShortcutTipSave()
    }

    /// Part of Clear Command History (#328): the counts and tip dates, not Don't Show Again.
    func clearShortcutTipRecord() {
        shortcutTipSaveWork?.cancel()
        shortcutTipSaveWork = nil
        shortcutTipRecord.clearHistory()
        // No copy of the counts is left behind; what stays is Don't Show Again.
        persist { try shortcutTipStore.remove() }
        if !shortcutTipRecord.isEmpty { persist { try shortcutTipStore.save(shortcutTipRecord) } }
    }

    func flushShortcutTipRecord() {
        guard let work = shortcutTipSaveWork else { return }
        work.cancel()
        saveShortcutTipRecord()
    }

    private func scheduleShortcutTipSave() {
        shortcutTipSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveShortcutTipRecord() }
        shortcutTipSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func saveShortcutTipRecord() {
        shortcutTipSaveWork = nil
        persist { try shortcutTipStore.save(shortcutTipRecord) }
    }
}
