import Foundation

/// Tables in the output (#162): an SQL tab's rows, or a PHP value's Table view, drawn by a
/// native grid inside the output's scrolling list. The grid is as tall as its rows up to
/// `maxHeight`, then scrolls inside; a vertical scroll the grid can't take scrolls the output.
public enum OutputTableLayout {
    /// The tallest a table's grid gets in the output before it scrolls inside, in points.
    public static let maxHeight: Double = 400
    /// The grid's header row.
    public static let headerHeight: Double = 24
    /// A row: its height plus the space between rows.
    public static let rowHeight: Double = 17
    public static let rowPitch: Double = rowHeight + 2

    /// The grid's height for `rows` rows (at least one row's room, for an empty filter), plus
    /// `scroller` for a horizontal scroller that takes room (a mouse without a trackpad).
    public static func gridHeight(rows: Int, scroller: Double = 0) -> Double {
        min(maxHeight, headerHeight + Double(max(rows, 1)) * rowPitch + 4 + scroller)
    }

    /// Whether a scroll gesture that starts with this movement belongs to the output rather
    /// than the grid: it is mostly vertical, and the grid's rows can't move that way (they
    /// fit, or are at their top or bottom). `deltaY` > 0 moves toward the top. The visible
    /// rect is in the grid's document coordinates; `flipped` documents grow downward.
    public static func scrollGoesToOutput(deltaX: Double, deltaY: Double, visibleMinY: Double, visibleHeight: Double, documentHeight: Double, flipped: Bool) -> Bool {
        guard deltaY != 0, abs(deltaY) > abs(deltaX) else { return false }
        guard documentHeight > visibleHeight + 1 else { return true }
        let up = deltaY > 0
        let visibleMaxY = visibleMinY + visibleHeight
        let atTop = flipped ? visibleMinY <= 0 : visibleMaxY >= documentHeight - 1
        let atBottom = flipped ? visibleMaxY >= documentHeight - 1 : visibleMinY <= 0
        return up ? atTop : atBottom
    }
}
