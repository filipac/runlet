import Foundation

/// A window's tab order with its pinned tabs (#279), for both tab layouts. Pinned tabs come
/// first (leftmost in the tab bar, at the top of the vertical tabs), and the two groups never
/// mix: pinning moves a tab to the end of the pinned group, unpinning to the start of the other
/// tabs, new tabs open after the pinned ones, and a move stays inside the tab's group. The
/// order is the shown order, so ⌘1…⌘9 count pinned tabs first.
///
/// Close Other Tabs and Close Tabs to the Right leave pinned tabs open; closing one tab
/// (⌘W, Close in its menu) closes it whether or not it is pinned.
public struct TabPinOrder<ID: Hashable>: Equatable {
    /// The tabs in the order they are shown: the pinned ones first.
    public private(set) var ids: [ID]
    public private(set) var pinned: Set<ID>

    /// Puts the pinned tabs first, each group in its own order (a session saved by hand, or by
    /// an older build, can mix them). Pins of ids not in `ids` are dropped.
    public init(ids: [ID], pinned: Set<ID>) {
        let pinned = pinned.intersection(ids)
        self.ids = ids.filter { pinned.contains($0) } + ids.filter { !pinned.contains($0) }
        self.pinned = pinned
    }

    public var pinnedCount: Int { pinned.count }

    public func isPinned(_ id: ID) -> Bool { pinned.contains(id) }

    /// Pins a tab: it moves to the end of the pinned group. Pinning a pinned tab does nothing.
    public mutating func pin(_ id: ID) {
        guard let index = ids.firstIndex(of: id), !pinned.contains(id) else { return }
        ids.remove(at: index)
        ids.insert(id, at: pinnedCount)
        pinned.insert(id)
    }

    /// Unpins a tab: it moves to the start of the other tabs.
    public mutating func unpin(_ id: ID) {
        guard let index = ids.firstIndex(of: id), pinned.contains(id) else { return }
        ids.remove(at: index)
        pinned.remove(id)
        ids.insert(id, at: pinnedCount)
    }

    /// Where a new tab opens: right after the selected tab, but never among the pinned ones
    /// (after the last pinned tab when a pinned tab is selected). Without a selection, at the end.
    public func newTabIndex(after selected: ID?) -> Int {
        guard let selected, let index = ids.firstIndex(of: selected) else { return ids.count }
        return max(index + 1, pinnedCount)
    }

    /// Adds an unpinned tab where `newTabIndex(after:)` says.
    public mutating func insert(_ id: ID, after selected: ID?) {
        guard !ids.contains(id) else { return }
        ids.insert(id, at: newTabIndex(after: selected))
    }

    /// A position for a tab of the given group, moved into the group: a pinned tab dragged past
    /// the last pinned tab stays the last pinned tab, and an unpinned tab dragged among the
    /// pinned ones becomes the first unpinned tab. `index` is the tab's position after the move.
    public func clampedIndex(_ index: Int, pinned isPinned: Bool, alreadyIn: Bool) -> Int {
        // A tab that isn't in the list yet (reopening a closed tab) makes its group one longer.
        let extra = alreadyIn ? 0 : 1
        let lower = isPinned ? 0 : pinnedCount
        let upper = isPinned ? pinnedCount - 1 + extra : ids.count - 1 + extra
        return min(max(index, lower), max(lower, upper))
    }

    /// Moves a tab to `index` (its position after the move), kept inside its group.
    /// Returns where it went.
    @discardableResult
    public mutating func move(_ id: ID, to index: Int) -> Int? {
        guard let from = ids.firstIndex(of: id) else { return nil }
        let destination = clampedIndex(index, pinned: pinned.contains(id), alreadyIn: true)
        ids.remove(at: from)
        ids.insert(id, at: destination)
        return destination
    }

    /// Adds a tab back at `index` (reopening a closed tab), pinned or not, kept inside its group.
    public mutating func reinsert(_ id: ID, at index: Int, pinned isPinned: Bool) {
        guard !ids.contains(id) else { return }
        let destination = clampedIndex(index, pinned: isPinned, alreadyIn: false)
        ids.insert(id, at: destination)
        if isPinned { pinned.insert(id) }
    }

    public mutating func remove(_ id: ID) {
        ids.removeAll { $0 == id }
        pinned.remove(id)
    }

    /// Close Other Tabs: every other tab that isn't pinned.
    public func closedByCloseOthers(keeping id: ID) -> [ID] {
        ids.filter { $0 != id && !pinned.contains($0) }
    }

    /// Close Tabs to the Right: the tabs after `id` that aren't pinned. For a pinned tab, that
    /// is every unpinned tab.
    public func closedByCloseToRight(of id: ID) -> [ID] {
        guard let index = ids.firstIndex(of: id) else { return [] }
        return ids[(index + 1)...].filter { !pinned.contains($0) }
    }

    /// The tab ⌘1…⌘8 selects (the nth shown, pinned tabs first), or ⌘9 (the last).
    public func tab(forShortcut number: Int) -> ID? {
        guard !ids.isEmpty else { return nil }
        if number == 9 { return ids.last }
        guard (1 ... 8).contains(number), number <= ids.count else { return nil }
        return ids[number - 1]
    }
}

/// Pinned tabs' words (#279): Open Anything lists Pin Tab only for a query that names one.
public enum TabPinning {
    public static let searchWords = ["pin", "unpin", "pinned"]

    /// Whether Open Anything should list Pin Tab for `query`: one of its words names pinning
    /// ("pin", "unp…"), and the rest name pinning or a tab ("pin tab").
    public static func paletteMatches(_ query: String) -> Bool {
        let tokens = query.lowercased().split { !$0.isLetter }.map(String.init)
        guard tokens.contains(where: { PaletteQuery.names($0, oneOf: searchWords) }) else { return false }
        return PaletteQuery.names(query, oneOf: searchWords + ["tab", "tabs"])
    }
}
