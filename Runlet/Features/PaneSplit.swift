import AppKit
import SwiftUI

/// Two panes with a draggable divider whose position is a fraction of the space, remembered
/// by the caller (SwiftUI's HSplitView and VSplitView cannot restore a divider position).
/// The fraction is clamped so each pane keeps its minimum size; when the space is too small
/// for both minimums, the panes split evenly.
struct PaneSplit<First: View, Second: View>: View {
    enum Axis {
        /// Side by side; the fraction is the first pane's share of the width.
        case horizontal
        /// Stacked; the fraction is the first pane's share of the height.
        case vertical
    }

    var axis: Axis
    /// The saved position (0…1).
    var fraction: Double
    var minFirst: CGFloat
    var minSecond: CGFloat
    /// Called once when a drag ends, with the new position.
    var onCommit: (Double) -> Void
    @ViewBuilder var first: First
    @ViewBuilder var second: Second

    /// Position while dragging; nil otherwise.
    @State private var live: Double?
    @State private var dragStart: Double?

    private static var handleThickness: CGFloat { 5 }

    var body: some View {
        GeometryReader { geometry in
            let total = axis == .horizontal ? geometry.size.width : geometry.size.height
            let available = max(0, total - Self.handleThickness)
            let share = clamped(live ?? fraction, available: available)
            let firstSize = (available * share).rounded()
            let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                first
                    .frame(width: axis == .horizontal ? firstSize : nil, height: axis == .vertical ? firstSize : nil)
                    .frame(maxWidth: axis == .vertical ? .infinity : nil, maxHeight: axis == .horizontal ? .infinity : nil)
                handle(available: available)
                second
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func handle(available: CGFloat) -> some View {
        let horizontal = axis == .horizontal
        return Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1)
            .padding(horizontal ? .horizontal : .vertical, (Self.handleThickness - 1) / 2)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        guard available > 0 else { return }
                        let start = dragStart ?? clamped(fraction, available: available)
                        if dragStart == nil { dragStart = start }
                        let delta = horizontal ? value.translation.width : value.translation.height
                        live = clamped(start + delta / available, available: available)
                    }
                    .onEnded { _ in
                        if let live { onCommit(live) }
                        live = nil
                        dragStart = nil
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Editor and output divider")
            .accessibilityIdentifier("editor-output-divider")
    }

    private func clamped(_ value: Double, available: CGFloat) -> Double {
        guard available > 0 else { return 0.5 }
        let lower = Double(minFirst / available)
        let upper = 1 - Double(minSecond / available)
        guard lower <= upper else { return 0.5 }
        return min(upper, max(lower, value.isFinite ? value : 0.5))
    }
}
