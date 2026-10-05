import Foundation
import Testing
@testable import RunletCore

/// Pinned tabs (#279): their order, closing, palette words, and how sessions and workspaces
/// keep the pin.
struct TabPinsTests {
    typealias Order = TabPinOrder<String>

    // MARK: Order

    @Test func pinnedTabsComeFirstInTheirOwnOrder() {
        let order = Order(ids: ["a", "b", "c", "d"], pinned: ["c", "a"])
        #expect(order.ids == ["a", "c", "b", "d"])
        #expect(order.pinnedCount == 2)
        // A pin of a tab that isn't there is dropped.
        #expect(Order(ids: ["a"], pinned: ["x"]).pinned.isEmpty)
    }

    @Test func pinningMovesTheTabToTheEndOfThePinnedGroup() {
        var order = Order(ids: ["a", "b", "c", "d"], pinned: ["a"])
        order.pin("d")
        #expect(order.ids == ["a", "d", "b", "c"])
        #expect(order.pinned == ["a", "d"])
        order.pin("c")
        #expect(order.ids == ["a", "d", "c", "b"])
        // Pinning a pinned tab changes nothing.
        order.pin("a")
        #expect(order.ids == ["a", "d", "c", "b"])
    }

    @Test func unpinningMovesTheTabToTheStartOfTheOtherTabs() {
        var order = Order(ids: ["a", "b", "c", "d"], pinned: ["a", "b", "c"])
        order.unpin("a")
        #expect(order.ids == ["b", "c", "a", "d"])
        #expect(order.pinned == ["b", "c"])
        order.unpin("c")
        #expect(order.ids == ["b", "c", "a", "d"])
        #expect(order.pinned == ["b"])
        // Unpinning an unpinned tab changes nothing.
        order.unpin("d")
        #expect(order.ids == ["b", "c", "a", "d"])
    }

    @Test func pinThenUnpinRoundTrips() {
        var order = Order(ids: ["a", "b", "c"], pinned: [])
        order.pin("b")
        order.unpin("b")
        #expect(order.ids == ["b", "a", "c"])
        #expect(order.pinned.isEmpty)
    }

    @Test func newTabsOpenAfterThePinnedOnes() {
        var order = Order(ids: ["p1", "p2", "a", "b"], pinned: ["p1", "p2"])
        // After the selected tab when it isn't pinned.
        #expect(order.newTabIndex(after: "a") == 3)
        // After the last pinned tab when a pinned tab is selected, never between them.
        #expect(order.newTabIndex(after: "p1") == 2)
        #expect(order.newTabIndex(after: "p2") == 2)
        // At the end without a selection.
        #expect(order.newTabIndex(after: nil) == 4)
        order.insert("n", after: "p1")
        #expect(order.ids == ["p1", "p2", "n", "a", "b"])
        #expect(!order.isPinned("n"))
        // Every tab pinned: the new tab goes last.
        var allPinned = Order(ids: ["p1", "p2"], pinned: ["p1", "p2"])
        allPinned.insert("n", after: "p1")
        #expect(allPinned.ids == ["p1", "p2", "n"])
    }

    @Test func movesStayInTheTabsGroup() {
        var order = Order(ids: ["p1", "p2", "a", "b", "c"], pinned: ["p1", "p2"])
        // Inside a group, as asked.
        #expect(order.move("c", to: 2) == 2)
        #expect(order.ids == ["p1", "p2", "c", "a", "b"])
        #expect(order.move("p2", to: 0) == 0)
        #expect(order.ids == ["p2", "p1", "c", "a", "b"])
        // An unpinned tab dragged among the pinned ones becomes the first unpinned tab.
        #expect(order.move("b", to: 0) == 2)
        #expect(order.ids == ["p2", "p1", "b", "c", "a"])
        // A pinned tab dragged past the pinned ones becomes the last pinned tab.
        #expect(order.move("p2", to: 4) == 1)
        #expect(order.ids == ["p1", "p2", "b", "c", "a"])
        // The pins don't change.
        #expect(order.pinned == ["p1", "p2"])
        #expect(order.move("missing", to: 0) == nil)
    }

    @Test func reopenedTabsGoBackIntoTheirGroup() {
        var order = Order(ids: ["p1", "a", "b"], pinned: ["p1"])
        // A closed pinned tab comes back pinned, among the pinned tabs.
        order.reinsert("p2", at: 3, pinned: true)
        #expect(order.ids == ["p1", "p2", "a", "b"])
        #expect(order.isPinned("p2"))
        // A closed unpinned tab whose old position is now among the pinned ones goes after them.
        order.reinsert("c", at: 0, pinned: false)
        #expect(order.ids == ["p1", "p2", "c", "a", "b"])
        order.reinsert("d", at: 99, pinned: false)
        #expect(order.ids.last == "d")
        order.remove("p1")
        #expect(order.ids.first == "p2")
        #expect(order.pinned == ["p2"])
    }

    @Test func shortcutNumbersCountPinnedTabsFirst() {
        var order = Order(ids: ["a", "b", "c", "d"], pinned: [])
        order.pin("c")
        order.pin("d")
        // As shown: c, d (pinned), then a, b.
        #expect(order.tab(forShortcut: 1) == "c")
        #expect(order.tab(forShortcut: 2) == "d")
        #expect(order.tab(forShortcut: 3) == "a")
        #expect(order.tab(forShortcut: 4) == "b")
        #expect(order.tab(forShortcut: 5) == nil)
        // ⌘9 is the last tab.
        #expect(order.tab(forShortcut: 9) == "b")
        #expect(Order(ids: [], pinned: []).tab(forShortcut: 9) == nil)
    }

    // MARK: Closing

    @Test func closeOtherTabsKeepsPinnedTabs() {
        let order = Order(ids: ["p1", "p2", "a", "b", "c"], pinned: ["p1", "p2"])
        #expect(order.closedByCloseOthers(keeping: "b") == ["a", "c"])
        // From a pinned tab: every unpinned tab; the other pinned tab stays.
        #expect(order.closedByCloseOthers(keeping: "p1") == ["a", "b", "c"])
        #expect(Order(ids: ["p1", "a"], pinned: ["p1"]).closedByCloseOthers(keeping: "a").isEmpty)
    }

    @Test func closeTabsToTheRightKeepsPinnedTabs() {
        let order = Order(ids: ["p1", "p2", "a", "b", "c"], pinned: ["p1", "p2"])
        #expect(order.closedByCloseToRight(of: "a") == ["b", "c"])
        #expect(order.closedByCloseToRight(of: "c").isEmpty)
        // From a pinned tab: the unpinned tabs, never the pinned ones after it.
        #expect(order.closedByCloseToRight(of: "p1") == ["a", "b", "c"])
        #expect(order.closedByCloseToRight(of: "missing").isEmpty)
    }

    // MARK: Menu and palette

    @Test func theContextMenuOffersPinOrUnpin() {
        #expect(TabMenuItem.items(for: .php).contains(.pin))
        #expect(!TabMenuItem.items(for: .php).contains(.unpin))
        let pinned = TabMenuItem.items(for: .redis, pinned: true)
        #expect(pinned.contains(.unpin))
        #expect(!pinned.contains(.pin))
        #expect(TabMenuItem.pin.title == "Pin Tab")
        #expect(TabMenuItem.unpin.title == "Unpin Tab")
    }

    @Test func openAnythingListsPinTabForPinWords() {
        #expect(TabPinning.paletteMatches("pin"))
        #expect(TabPinning.paletteMatches("unpin"))
        #expect(TabPinning.paletteMatches("unp"))
        #expect(TabPinning.paletteMatches("pin tab"))
        #expect(TabPinning.paletteMatches("Pinned"))
        // Not for a tab, a target, or a snippet search.
        #expect(!TabPinning.paletteMatches("tab"))
        #expect(!TabPinning.paletteMatches("pi"))
        #expect(!TabPinning.paletteMatches("pin users"))
        #expect(!TabPinning.paletteMatches(""))
    }

    // MARK: Persistence

    @Test func sessionsKeepThePin() throws {
        let pinned = TabState(title: "Prod SQL", code: "select 1", language: .sql, pinned: true)
        let decoded = try JSONDecoder().decode(TabState.self, from: JSONEncoder().encode(pinned))
        #expect(decoded.isPinned)
        #expect(decoded.pinned == true)
        // An unpinned tab writes nothing, so its session entry is unchanged.
        let plain = TabState(title: "Tab 1", code: "1", pinned: false)
        #expect(plain.pinned == nil)
        let json = try #require(String(data: try JSONEncoder().encode(plain), encoding: .utf8))
        #expect(!json.contains("pinned"), "\(json)")
        // A whole session round trip.
        let session = SessionState(windows: [WindowState(tabs: [pinned, plain], selectedTabId: plain.id)])
        let restored = try JSONDecoder().decode(SessionState.self, from: JSONEncoder().encode(session))
        #expect(restored.tabs.map(\.isPinned) == [true, false])
    }

    @Test func olderSessionsDecodeAsUnpinned() throws {
        let id = UUID()
        let json = #"{"windows":[{"id":"\#(UUID().uuidString)","tabs":[{"id":"\#(id.uuidString)","title":"Old","code":"1","target":{"sandbox":{}},"selection":{"location":0,"length":0},"createdAt":0}]}]}"#
        let session = try JSONDecoder().decode(SessionState.self, from: Data(json.utf8))
        #expect(session.tabs.count == 1)
        #expect(session.tabs.first?.pinned == nil)
        #expect(session.tabs.first?.isPinned == false)
        // Something other than a Bool also reads as unpinned.
        let odd = json.replacingOccurrences(of: #""createdAt":0"#, with: #""createdAt":0,"pinned":"yes""#)
        #expect(try JSONDecoder().decode(SessionState.self, from: Data(odd.utf8)).tabs.first?.isPinned == false)
    }

    @Test func workspacesKeepThePin() throws {
        let document = WorkspaceDocument(tabs: [
            WorkspaceTab(title: "Pinned", code: "1", target: .sandbox, pinned: true),
            WorkspaceTab(title: "Other", code: "2", target: .sandbox),
        ], selectedIndex: 0)
        let data = try document.encoded()
        // Unpinned tabs write nothing.
        #expect(String(decoding: data, as: UTF8.self).components(separatedBy: "\"pinned\"").count == 2)
        let read = try WorkspaceDocument.read(from: data)
        #expect(read.tabs.map(\.pinned) == [true, nil])
    }
}
