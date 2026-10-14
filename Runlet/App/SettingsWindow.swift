import AppKit

/// Opens Settings from code: the palette's Settings…, AI Settings… and Explain or Fix's Open AI
/// Settings… (#368), the mail chip's link to General, the editor's link to PHP, and ⌥⌘, for
/// Advanced (#187).
///
/// `NSApp.sendAction(showSettingsWindow:)`, which these used, opens nothing on the macOS
/// versions Runlet supports: SwiftUI's Settings scene no longer answers that selector, with or
/// without a sheet in front (#368). This chooses the app menu's Settings… item instead, as ⌘,
/// does; SwiftUI wires that item to the scene.
@MainActor
enum SettingsWindow {
    /// Opens Settings, or brings it forward, then picks the tab labelled `tab`.
    static func open(selecting tab: String? = nil) {
        if let menu = NSApp.mainMenu?.items.first?.submenu,
           let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
            menu.performActionForItem(at: index)
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        if let tab { SettingsTabSelection.select(tab, waiting: 3) }
    }
}

/// Picks a tab of the open Settings window by its toolbar item's label, as a click on it would
/// (the `settings-tab` Debug step does the same).
@MainActor
enum SettingsTabSelection {
    /// `waiting` seconds at most for the item: a window that's just opening, or a tab that
    /// appears once SwiftUI redraws (Advanced), has none yet.
    static func select(_ label: String, waiting seconds: Double = 0) {
        let items = NSApp.windows.compactMap(\.toolbar).flatMap(\.items)
        if let item = items.first(where: { $0.label == label }), let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
            return
        }
        guard seconds > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { select(label, waiting: seconds - 0.1) }
    }
}
