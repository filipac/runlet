import RunletCore
import SwiftUI

/// The tab context menu (#214), shared by the tab bar and the vertical tabs: the items of
/// `TabMenuItem.items(for:pinned:)`. Switching language is disabled while the tab runs; Close
/// Other Tabs when every other tab is pinned (#279).
struct TabContextMenu: View {
    let tab: TabModel
    let model: AppModel
    let rename: () -> Void

    var body: some View {
        ForEach(TabMenuItem.items(for: tab.language, pinned: tab.isPinned), id: \.self) { item in
            switch item {
            case .rename: Button(item.title, action: rename)
            case .duplicate: Button(item.title) { model.duplicateTab(tab.id) }
            case .pin: Button(item.title) { model.setPinned(true, for: tab.id) }
            case .unpin: Button(item.title) { model.setPinned(false, for: tab.id) }
            case .switchLanguage(let language):
                Button(item.title) { model.setLanguage(language, for: tab) }
                    .disabled(tab.isRunning)
            case .divider: Divider()
            case .close: Button(item.title) { model.closeTab(tab.id) }
            case .closeOthers:
                Button(item.title) { model.closeOtherTabs(tab.id) }
                    .disabled(!model.canCloseOtherTabs(tab.id))
            }
        }
    }
}

extension View {
    /// The shared tab context menu (#214). Debug builds also show its items in a popover for
    /// the `tab-menu:<title>` step, since a menu can't be snapshotted.
    func tabContextMenu(_ tab: TabModel, model: AppModel, rename: @escaping () -> Void) -> some View {
        contextMenu { TabContextMenu(tab: tab, model: model, rename: rename) }
        #if DEBUG
            .popover(isPresented: Binding(get: { TabMenuDebug.shared.title == tab.title }, set: { if !$0 { TabMenuDebug.shared.title = nil } }), arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) { TabContextMenu(tab: tab, model: model, rename: rename) }
                    .buttonStyle(.plain)
                    .padding(10)
                    .frame(minWidth: 180, alignment: .leading)
            }
        #endif
    }
}

#if DEBUG
/// DEBUG step `tab-menu:<title>` (#214): that tab's context menu items in a popover.
@MainActor @Observable
final class TabMenuDebug {
    static let shared = TabMenuDebug()
    var title: String?
}
#endif
