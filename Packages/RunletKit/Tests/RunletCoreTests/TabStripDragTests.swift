import Foundation
import Testing
@testable import RunletCore

/// Dragging a tab along the horizontal tab bar (#322): where it lands, how the others make
/// room, the pinned/unpinned groups (#279), and scrolling near the ends.
struct TabStripDragTests {
    typealias Order = TabPinOrder<String>
    typealias Drag = TabStripDrag<String>

    /// Tabs laid out left to right with `spacing` between them, the first at x = 0.
    private func spans(_ widths: [(String, Double)], spacing: Double = 2, start: Double = 0) -> [String: TabSpan] {
        var x = start
        var spans: [String: TabSpan] = [:]
        for (id, width) in widths {
            spans[id] = TabSpan(minX: x, maxX: x + width)
            x += width + spacing
        }
        return spans
    }

    private func drag(_ id: String, _ order: Order, _ spans: [String: TabSpan], offset: Double) -> Drag? {
        var drag = Drag(dragging: id, in: order, spans: spans, spacing: 2)
        drag?.offset = offset
        return drag
    }

    // MARK: Landing

    @Test func aTabLandsPastANeighbourOnceItsLeadingEdgePassesTheNeighboursMiddle() throws {
        let order = Order(ids: ["a", "b", "c", "d"], pinned: [])
        // a 0…100, b 102…202 (middle 152), c 204…304 (254), d 306…406 (356).
        let layout = spans([("a", 100), ("b", 100), ("c", 100), ("d", 100)])
        // a's trailing edge (100) has to pass b's middle (152).
        #expect(try #require(drag("a", order, layout, offset: 52)).destination == 0)
        #expect(try #require(drag("a", order, layout, offset: 53)).destination == 1)
        #expect(try #require(drag("a", order, layout, offset: 155)).destination == 2)
        #expect(try #require(drag("a", order, layout, offset: 257)).destination == 3)
        // Dragged left: d's leading edge (306) has to pass c's middle (254).
        #expect(try #require(drag("d", order, layout, offset: -52)).destination == 3)
        #expect(try #require(drag("d", order, layout, offset: -53)).destination == 2)
        #expect(try #require(drag("d", order, layout, offset: -400)).destination == 0)
        // No movement, or too little, moves nothing.
        let still = try #require(drag("b", order, layout, offset: 0))
        #expect(still.destination == 1)
        #expect(!still.movesTab)
        #expect(try #require(drag("b", order, layout, offset: 40)).movesTab == false)
    }

    @Test func tabsOfDifferentWidthsUseTheirOwnMiddles() throws {
        let order = Order(ids: ["wide", "s", "m"], pinned: [])
        // wide 0…200, s 202…242 (middle 222), m 244…324 (284).
        let layout = spans([("wide", 200), ("s", 40), ("m", 80)])
        #expect(try #require(drag("wide", order, layout, offset: 22)).destination == 0)
        #expect(try #require(drag("wide", order, layout, offset: 23)).destination == 1)
        #expect(try #require(drag("wide", order, layout, offset: 85)).destination == 2)
        // A narrow tab dragged left passes the wide one once its leading edge is past 100.
        #expect(try #require(drag("s", order, layout, offset: -101)).destination == 1)
        #expect(try #require(drag("s", order, layout, offset: -103)).destination == 0)
    }

    // MARK: Making room

    @Test func passedTabsSlideTowardTheDraggedTabsOldPlace() throws {
        let order = Order(ids: ["a", "b", "c", "d"], pinned: [])
        let layout = spans([("a", 100), ("b", 60), ("c", 100), ("d", 100)])
        // b dragged right past c: c slides left by b's width and the spacing.
        let right = try #require(drag("b", order, layout, offset: 120))
        #expect(right.destination == 2)
        #expect(right.shift(of: "c") == -62)
        #expect(right.shift(of: "a") == 0)
        #expect(right.shift(of: "d") == 0)
        #expect(right.shift(of: "b") == 0)
        // b dragged left past a: a slides right.
        let left = try #require(drag("b", order, layout, offset: -60))
        #expect(left.destination == 0)
        #expect(left.shift(of: "a") == 62)
        #expect(left.shift(of: "c") == 0)
    }

    @Test func theSlidesMatchTheLayoutAfterTheMove() throws {
        // After the drop, every tab is where it was drawn while dragging: the passed tabs at
        // their place plus their shift.
        let widths: [(String, Double)] = [("a", 90), ("b", 140), ("c", 60), ("d", 110), ("e", 75)]
        let layout = spans(widths)
        let order = Order(ids: widths.map(\.0), pinned: [])
        for id in order.ids {
            for target in order.ids.indices {
                var drag = try #require(Drag(dragging: id, in: order, spans: layout, spacing: 2))
                drag.offset = drag.offset(landingAt: target)
                #expect(drag.destination == target, "\(id) to \(target)")
                var moved = order
                moved.move(id, to: drag.destination)
                let after = spans(moved.ids.map { tab in (tab, widths.first { $0.0 == tab }!.1) })
                for other in order.ids where other != id {
                    #expect(after[other]!.minX == layout[other]!.minX + drag.shift(of: other), "\(other) with \(id) to \(target)")
                }
            }
        }
    }

    // MARK: Groups (#279)

    @Test func anUnpinnedTabStopsAtTheFirstUnpinnedPlace() throws {
        let order = Order(ids: ["p1", "p2", "a", "b", "c"], pinned: ["p1", "p2"])
        // A divider between the groups.
        let layout = spans([("p1", 50), ("p2", 50)]).merging(spans([("a", 100), ("b", 100), ("c", 100)], start: 120)) { $1 }
        var drag = try #require(Drag(dragging: "c", in: order, spans: layout, spacing: 2))
        #expect(drag.group == ["a", "b", "c"])
        #expect(drag.groupStart == 2)
        // Far over the pinned tabs: it stays the first unpinned tab, drawn at the group's start.
        drag.offset = -1_000
        #expect(drag.destination == 2)
        #expect(drag.tabOffset == layout["a"]!.minX - layout["c"]!.minX)
        #expect(drag.shift(of: "p1") == 0)
        #expect(drag.shift(of: "p2") == 0)
        // Aiming at a pinned tab's place does the same.
        drag.offset = drag.offset(landingAt: 0)
        #expect(drag.destination == 2)
    }

    @Test func aPinnedTabStopsAtTheLastPinnedPlace() throws {
        let order = Order(ids: ["p1", "p2", "p3", "a", "b"], pinned: ["p1", "p2", "p3"])
        let layout = spans([("p1", 50), ("p2", 50), ("p3", 50)]).merging(spans([("a", 100), ("b", 100)], start: 170)) { $1 }
        var drag = try #require(Drag(dragging: "p1", in: order, spans: layout, spacing: 2))
        #expect(drag.group == ["p1", "p2", "p3"])
        #expect(drag.groupStart == 0)
        drag.offset = 1_000
        #expect(drag.destination == 2)
        #expect(drag.tabOffset == layout["p3"]!.maxX - layout["p1"]!.maxX)
        #expect(drag.shift(of: "a") == 0)
        drag.offset = drag.offset(landingAt: 4)
        #expect(drag.destination == 2)
        // Within the group, it lands where aimed.
        drag.offset = drag.offset(landingAt: 1)
        #expect(drag.destination == 1)
        // And TabPinOrder agrees.
        var moved = order
        moved.move("p1", to: drag.destination)
        #expect(moved.ids == ["p2", "p1", "p3", "a", "b"])
    }

    @Test func aDragNeedsItsGroupLaidOut() {
        let order = Order(ids: ["a", "b", "c"], pinned: [])
        #expect(Drag(dragging: "a", in: order, spans: spans([("a", 100), ("b", 100)]), spacing: 2) == nil)
        #expect(Drag(dragging: "x", in: order, spans: spans([("a", 100), ("b", 100), ("c", 100)]), spacing: 2) == nil)
        // The other group's places don't matter.
        let pinned = Order(ids: ["p", "a"], pinned: ["p"])
        #expect(Drag(dragging: "a", in: pinned, spans: spans([("a", 100)]), spacing: 2) != nil)
    }

    @Test func aTabAloneInItsGroupStaysPut() throws {
        let order = Order(ids: ["p", "a", "b"], pinned: ["p"])
        let layout = spans([("p", 50), ("a", 100), ("b", 100)])
        var drag = try #require(Drag(dragging: "p", in: order, spans: layout, spacing: 2))
        drag.offset = 300
        #expect(drag.tabOffset == 0)
        #expect(drag.destination == 0)
        #expect(!drag.movesTab)
    }

    // MARK: Move Tab Left / Right

    @Test func moveLeftAndRightStayInTheGroup() {
        let order = Order(ids: ["p1", "p2", "a", "b"], pinned: ["p1", "p2"])
        #expect(order.neighbourIndex(of: "p1", by: -1) == nil)
        #expect(order.neighbourIndex(of: "p1", by: 1) == 1)
        #expect(order.neighbourIndex(of: "p2", by: 1) == nil)
        #expect(order.neighbourIndex(of: "a", by: -1) == nil)
        #expect(order.neighbourIndex(of: "a", by: 1) == 3)
        #expect(order.neighbourIndex(of: "b", by: -1) == 2)
        #expect(order.neighbourIndex(of: "b", by: 1) == nil)
        #expect(order.neighbourIndex(of: "x", by: 1) == nil)
    }

    // MARK: Edge scrolling

    @Test func theBarScrollsNearItsEnds() {
        let width = 600.0
        #expect(TabStripEdgeScroll.step(pointer: 300, width: width) == 0)
        #expect(TabStripEdgeScroll.step(pointer: TabStripEdgeScroll.margin, width: width) == 0)
        #expect(TabStripEdgeScroll.step(pointer: width - TabStripEdgeScroll.margin, width: width) == 0)
        // Faster the closer to the end, full speed at or past it.
        let near = TabStripEdgeScroll.step(pointer: 30, width: width)
        let nearer = TabStripEdgeScroll.step(pointer: 10, width: width)
        #expect(near < 0 && nearer < near)
        #expect(TabStripEdgeScroll.step(pointer: 0, width: width) == -TabStripEdgeScroll.maxStep)
        #expect(TabStripEdgeScroll.step(pointer: -50, width: width) == -TabStripEdgeScroll.maxStep)
        #expect(TabStripEdgeScroll.step(pointer: 590, width: width) > 0)
        #expect(TabStripEdgeScroll.step(pointer: 700, width: width) == TabStripEdgeScroll.maxStep)
        // A narrow bar keeps a middle that doesn't scroll.
        #expect(TabStripEdgeScroll.step(pointer: 45, width: 90) == 0)
        #expect(TabStripEdgeScroll.step(pointer: 10, width: 0) == 0)
    }

    @Test func scrollingStaysInsideTheContent() {
        #expect(TabStripEdgeScroll.scrolled(5, by: -9, contentWidth: 1_000, width: 600) == 0)
        #expect(TabStripEdgeScroll.scrolled(100, by: 9, contentWidth: 1_000, width: 600) == 109)
        #expect(TabStripEdgeScroll.scrolled(395, by: 9, contentWidth: 1_000, width: 600) == 400)
        // Content that fits doesn't scroll.
        #expect(TabStripEdgeScroll.scrolled(0, by: 9, contentWidth: 500, width: 600) == 0)
    }
}
