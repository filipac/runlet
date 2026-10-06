import Foundation

/// Where a tab sits along the horizontal tab bar (#322), in the bar's own coordinates (they
/// scroll with the tabs).
public struct TabSpan: Equatable, Sendable {
    public var minX: Double
    public var maxX: Double

    public init(minX: Double, maxX: Double) {
        self.minX = minX
        self.maxX = maxX
    }

    public var midX: Double { (minX + maxX) / 2 }
    public var width: Double { maxX - minX }
}

/// A tab dragged along the horizontal tab bar (#322). The dragged tab follows the pointer, the
/// tabs it passes slide aside to make room, and on release it lands where the gap is.
///
/// It stays in its group, as every move does (#279, `TabPinOrder`): a pinned tab moves among
/// the pinned ones and an unpinned tab among the others. The dragged tab can't leave its
/// group's stretch of the bar, so a drag across the boundary stops at the group's end.
///
/// A tab lands past a neighbour once its leading edge (the edge in the drag's direction) passes
/// that neighbour's middle, as in Safari and Xcode.
public struct TabStripDrag<ID: Hashable>: Equatable {
    /// The dragged tab.
    public let id: ID
    /// The dragged tab's group (the pinned tabs, or the others), in order.
    public let group: [ID]
    /// Where each tab of `group` sits, before the drag.
    public let spans: [TabSpan]
    /// The dragged tab's place in `group` before the drag.
    public let from: Int
    /// Where the group starts in the window's tabs (0 for the pinned tabs).
    public let groupStart: Int
    /// The space between two tabs.
    public let spacing: Double
    /// How far the pointer has moved along the bar since the drag began.
    public var offset: Double = 0

    /// A drag of `id`, with the tabs' places along the bar. Nil when `id` isn't in `order`, or
    /// a tab of its group has no place yet (not laid out).
    public init?(dragging id: ID, in order: TabPinOrder<ID>, spans: [ID: TabSpan], spacing: Double) {
        let pinned = order.isPinned(id)
        let group = order.ids.filter { order.isPinned($0) == pinned }
        guard let from = group.firstIndex(of: id) else { return nil }
        let groupSpans = group.compactMap { spans[$0] }
        guard groupSpans.count == group.count else { return nil }
        self.id = id
        self.group = group
        self.spans = groupSpans
        self.from = from
        self.groupStart = pinned ? 0 : order.pinnedCount
        self.spacing = spacing
    }

    /// How far the dragged tab is drawn from its place: the pointer's movement, kept inside the
    /// group's stretch of the bar.
    public var tabOffset: Double {
        let dragged = spans[from]
        let lower = spans[0].minX - dragged.minX
        let upper = spans[spans.count - 1].maxX - dragged.maxX
        return min(max(offset, lower), upper)
    }

    /// Where the dragged tab lands in its group, if released now.
    public var groupDestination: Int {
        let dragged = spans[from]
        let minX = dragged.minX + tabOffset
        let maxX = dragged.maxX + tabOffset
        // Dragged right, it passes the tabs after it whose middle its trailing edge has
        // crossed; dragged left, those before it whose middle its leading edge has crossed.
        // Only one side can count: dragged right, its leading edge is past every middle
        // before it, and dragged left, its trailing edge is short of every middle after it.
        let passedRight = spans[(from + 1)...].filter { maxX > $0.midX }.count
        let passedLeft = spans[..<from].filter { minX < $0.midX }.count
        return from + passedRight - passedLeft
    }

    /// Where the dragged tab lands among the window's tabs, if released now: the index for
    /// `TabPinOrder.move(_:to:)` (its position after the move).
    public var destination: Int { groupStart + groupDestination }

    /// Whether releasing now moves the tab.
    public var movesTab: Bool { groupDestination != from }

    /// How far another tab of the group slides aside to make room for the dragged tab: by the
    /// dragged tab's width and the spacing, toward the dragged tab's old place. Zero for the
    /// dragged tab, the tabs it hasn't passed, and tabs of the other group.
    public func shift(of other: ID) -> Double {
        guard other != id, let index = group.firstIndex(of: other) else { return 0 }
        let to = groupDestination
        let room = spans[from].width + spacing
        if from < to, index > from, index <= to { return -room }
        if to < from, index >= to, index < from { return room }
        return 0
    }

    /// The pointer movement that lands the tab at `index` among the window's tabs: just past
    /// the middle of the tab now there. An index outside the group moves the pointer far past
    /// the group's end (the tab stays at that end). For checks (`tab-drag`).
    public func offset(landingAt index: Int) -> Double {
        let target = index - groupStart
        let dragged = spans[from]
        if target < 0 { return spans[0].minX - dragged.minX - 10_000 }
        if target >= group.count { return spans[group.count - 1].maxX - dragged.maxX + 10_000 }
        if target > from { return spans[target].midX + 1 - dragged.maxX }
        if target < from { return spans[target].midX - 1 - dragged.minX }
        return 0
    }
}

/// Scrolling the horizontal tab bar while a tab is dragged near either end of it (#322).
public enum TabStripEdgeScroll {
    /// How close to an end of the visible bar the pointer starts scrolling it.
    public static let margin: Double = 36
    /// The most the bar scrolls in one step (about 60 steps a second).
    public static let maxStep: Double = 9

    /// How far to scroll the bar in one step for a pointer at `pointer` along the visible bar,
    /// `width` wide: negative toward the start, positive toward the end, faster the closer to
    /// the end (and at full speed past it), zero in between.
    public static func step(pointer: Double, width: Double, margin: Double = margin, maxStep: Double = maxStep) -> Double {
        guard width > 0, margin > 0 else { return 0 }
        let margin = min(margin, width / 3)
        if pointer < margin {
            return -maxStep * min(1, (margin - pointer) / margin)
        }
        if pointer > width - margin {
            return maxStep * min(1, (pointer - (width - margin)) / margin)
        }
        return 0
    }

    /// Where the bar's scroll position goes after a step, kept inside the scrollable range.
    public static func scrolled(_ position: Double, by step: Double, contentWidth: Double, width: Double) -> Double {
        min(max(position + step, 0), max(0, contentWidth - width))
    }
}

extension TabPinOrder {
    /// The index for Move Tab Left (`by: -1`) or Move Tab Right (`by: 1`, #322): one place
    /// along, inside the tab's group. Nil when the tab is already at that end of its group.
    public func neighbourIndex(of id: ID, by step: Int) -> Int? {
        guard let index = ids.firstIndex(of: id) else { return nil }
        let target = index + step
        guard ids.indices.contains(target), isPinned(ids[target]) == isPinned(id) else { return nil }
        return target
    }
}
