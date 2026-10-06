#if DEBUG
import AppKit
import RunletCore

/// RUNLET_DEBUG_STEPS for dragging tabs along the horizontal tab bar (#322), with scratch data
/// and the horizontal layout. They go through the drag the pointer makes (`TabStripDragState`),
/// without a mouse, so Runlet can stay in the background (`ghost`):
///
/// - `tab-drag:<tab title>=<index>` starts dragging that tab of the active window and moves the
///   pointer to land it at that position: just past the middle of the tab there now. An index
///   in the other group (pinned or not) aims at that tab, and the drag stops at its group's end.
///   Prints the drag, as `tab-drag-state` does.
/// - `tab-drag-edge:<tab title>=start|end` starts dragging that tab with the pointer at that end
///   of the visible bar, which then scrolls by itself.
/// - `tab-drag-state` prints the drag: the tab, where it would land, the tabs that slid aside
///   (and by how much), and the bar's scroll position.
/// - `tab-drop` releases the tab, and prints the tabs in order (`*` selected, `📌` pinned);
///   `tab-drag-cancel` ends the drag without moving anything.
///
/// `move-tab:<tab title>=<index>` moves a tab straight through the model, as the vertical tabs do.
@MainActor
enum TabStripDebugSteps {
    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        switch name {
        case "tab-drag", "tab-drag-edge":
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let window = model.activeWindow, let tab = window.tabs.first(where: { $0.title == parts[0] }) else {
                log("\(name): no tab \(argument)")
                return true
            }
            let state = window.tabStripDrag
            state.cancel()
            guard let probe = TabStripDrag(dragging: tab.id, in: window.pinOrder, spans: state.spans, spacing: TabStripDragState.spacing) else {
                log("\(name): the tab bar isn't laid out (vertical tabs, or no window): \(state.spans.count) of \(window.tabs.count) tabs placed")
                return true
            }
            if name == "tab-drag" {
                guard let index = Int(parts[1]) else {
                    log("tab-drag: no index in \(argument)")
                    return true
                }
                // The pointer ends in the middle of the visible bar, away from its ends, so the
                // bar doesn't scroll.
                let middle = state.scroll.width / 2
                state.begin(tab.id, in: window, start: middle - probe.offset(landingAt: index))
                state.move(pointer: middle)
            } else {
                let pointer = parts[1] == "start" ? 1 : max(1, state.scroll.width - 1)
                state.begin(tab.id, in: window, start: pointer)
                state.move(pointer: pointer)
            }
            log(dragState(window, name))
        case "tab-drag-state":
            guard let window = model.activeWindow else { return true }
            log(dragState(window, name))
        case "tab-drop", "tab-drag-cancel":
            guard let window = model.activeWindow else { return true }
            if name == "tab-drop" { window.tabStripDrag.drop(model: model) } else { window.tabStripDrag.cancel() }
            log("\(name): \(order(window))")
        default:
            return false
        }
        return true
    }

    private static func dragState(_ window: WindowModel, _ step: String) -> String {
        let state = window.tabStripDrag
        let scroll = "scroll=\(Int(state.scroll.x.rounded()))/\(Int(max(0, state.scroll.contentWidth - state.scroll.width).rounded()))"
        guard let drag = state.drag else { return "\(step): no drag \(scroll) \(order(window))" }
        let slid = window.tabs.compactMap { tab -> String? in
            let shift = drag.shift(of: tab.id)
            return shift == 0 ? nil : "\(tab.title)\(shift > 0 ? "+" : "")\(Int(shift.rounded()))"
        }
        return "\(step): dragging=\(title(drag.id, window)) from=\(drag.groupStart + drag.from) lands=\(drag.destination) moves=\(drag.movesTab) "
            + "tabOffset=\(Int(drag.tabOffset.rounded())) slid=\(slid) edge=\(state.edgeDirection) \(scroll) \(order(window))"
    }

    private static func order(_ window: WindowModel) -> String {
        let tabs = window.tabs.map { tab in "\(tab.id == window.selectedTab?.id ? "*" : "")\(tab.isPinned ? "📌" : "")\(tab.title)" }
        return "tabs=\(tabs)"
    }

    private static func title(_ id: UUID, _ window: WindowModel) -> String {
        window.tabs.first { $0.id == id }?.title ?? "?"
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(message)\n".utf8))
    }
}
#endif
