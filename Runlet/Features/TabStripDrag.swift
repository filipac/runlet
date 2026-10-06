import RunletCore
import SwiftUI

/// Dragging tabs along the horizontal tab bar (#322). The dragged tab follows the pointer, the
/// tabs it passes slide aside, and on release it lands in the gap, through
/// `AppModel.moveTab(_:to:)` like a move in the vertical tabs. Where it lands, and the
/// pinned/unpinned groups it stays in (#279), are `TabStripDrag`'s (RunletCore).
///
/// The drag is a plain SwiftUI drag inside the bar, not a drag and drop: nothing from another
/// window or app can be dropped on the bar, and a tab can't leave its window. A click still
/// selects, a double-click renames, and the close button and context menu work as before: a
/// drag starts only once the pointer has moved a few points with the button down, and not on
/// a tab being renamed (dragging in its field selects text).
@MainActor
@Observable
final class TabStripDragState {
    /// The space between two tabs in the bar.
    static let spacing: Double = 2
    /// The tabs' coordinates: they scroll with the tabs.
    static let contentSpace = "tab-strip-content"
    /// The visible bar's coordinates: they don't scroll.
    static let barSpace = "tab-strip-bar"
    /// How far the pointer moves with the button down before a drag starts.
    static let minimumDistance: Double = 4

    /// The bar's scroll position, the tabs' whole width, and the visible width.
    struct Scroll: Equatable {
        var x = 0.0
        var contentWidth = 0.0
        var width = 0.0
    }

    /// The drag in progress, nil when none.
    private(set) var drag: TabStripDrag<UUID>?
    /// The pointer along the visible bar while dragging, for scrolling near its ends.
    private(set) var pointer: Double?

    /// Where each tab sits along the bar, as last laid out.
    @ObservationIgnored var spans: [UUID: TabSpan] = [:]
    @ObservationIgnored private(set) var scroll = Scroll()
    /// Where the pointer was among the tabs when the drag began.
    @ObservationIgnored private var anchor = 0.0

    var draggedId: UUID? { drag?.id }

    /// How far a tab is drawn from its place: the dragged one with the pointer, the ones it
    /// passed aside.
    func offset(of id: UUID) -> Double {
        guard let drag else { return 0 }
        return id == drag.id ? drag.tabOffset : drag.shift(of: id)
    }

    /// Starts dragging a tab, from `start` along the visible bar, and selects it. False when
    /// another drag is in progress or the bar isn't laid out.
    @discardableResult
    func begin(_ id: UUID, in window: WindowModel, start: Double) -> Bool {
        guard drag == nil, let drag = TabStripDrag(dragging: id, in: window.pinOrder, spans: spans, spacing: Self.spacing) else { return false }
        anchor = start + scroll.x
        pointer = start
        self.drag = drag
        window.selectedTabId = id
        return true
    }

    /// The pointer moved, to `pointer` along the visible bar.
    func move(pointer: Double) {
        guard drag != nil else { return }
        self.pointer = pointer
        update()
    }

    /// The bar scrolled (or resized). While dragging, the tab stays under the pointer.
    func scrolled(_ scroll: Scroll) {
        self.scroll = scroll
        update()
    }

    private func update() {
        guard var drag, let pointer else { return }
        let offset = pointer + scroll.x - anchor
        guard offset != drag.offset else { return }
        drag.offset = offset
        self.drag = drag
    }

    /// Releases the dragged tab: it lands in the gap, and the order is saved with the session.
    func drop(model: AppModel) {
        guard let drag else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            if drag.movesTab { model.moveTab(drag.id, to: drag.destination) }
            self.drag = nil
            pointer = nil
        }
    }

    /// Ends the drag without moving anything (the gesture was cancelled).
    func cancel() {
        guard drag != nil else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            drag = nil
            pointer = nil
        }
    }

    /// How far to scroll the bar in one step: the pointer is near (or past) one of its ends.
    var edgeStep: Double {
        guard drag != nil, let pointer else { return 0 }
        return TabStripEdgeScroll.step(pointer: pointer, width: scroll.width)
    }

    /// Which way the bar scrolls by itself: -1 toward the start, 1 toward the end, 0 not at all.
    var edgeDirection: Int { edgeStep < 0 ? -1 : edgeStep > 0 ? 1 : 0 }
}

extension View {
    /// Makes a tab of the horizontal tab bar draggable along it (#322).
    func tabStripDraggable(_ tabId: UUID, renaming: Bool) -> some View {
        modifier(TabStripDraggable(tabId: tabId, renaming: renaming))
    }
}

private struct TabStripDraggable: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window
    let tabId: UUID
    let renaming: Bool
    /// Resets when the gesture ends or is cancelled; a cancelled drag puts the tab back.
    @GestureState private var dragging = false

    func body(content: Content) -> some View {
        let state = window.tabStripDrag
        let dragged = state.draggedId == tabId
        let offset = state.offset(of: tabId)
        content
            .background {
                // Lifted above the tabs it passes.
                if dragged {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.bar)
                        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                }
            }
            .offset(x: offset)
            // The passed tabs slide aside; the dragged one follows the pointer at once.
            .animation(dragged ? nil : .easeOut(duration: 0.15), value: offset)
            // After `offset`: the place the tab is laid out at, not where it is drawn.
            .onGeometryChange(for: TabSpan.self) { proxy in
                let frame = proxy.frame(in: .named(TabStripDragState.contentSpace))
                return TabSpan(minX: frame.minX, maxX: frame.maxX)
            } action: { span in
                state.spans[tabId] = span
            }
            .simultaneousGesture(gesture(state), including: renaming ? .subviews : .all)
            .onChange(of: dragging) { _, dragging in
                if !dragging, state.draggedId == tabId { state.cancel() }
            }
            .zIndex(dragged ? 1 : 0)
    }

    private func gesture(_ state: TabStripDragState) -> some Gesture {
        DragGesture(minimumDistance: TabStripDragState.minimumDistance, coordinateSpace: .named(TabStripDragState.barSpace))
            .updating($dragging) { _, dragging, _ in dragging = true }
            .onChanged { value in
                if state.draggedId != tabId {
                    guard state.begin(tabId, in: window, start: value.startLocation.x) else { return }
                }
                state.move(pointer: value.location.x)
            }
            .onEnded { _ in
                if state.draggedId == tabId { state.drop(model: model) }
            }
    }
}
