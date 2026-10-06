import Foundation
import Testing
@testable import RunletCore

/// A project driver's inspector tabs: the list JSON, and the declarations remembered per target.
struct DriverInspectorTabsTests {
    private func listing(_ json: String) -> DriverInspectorTabListing? {
        DriverInspectorTabListing.decode(Data(json.utf8))
    }

    @Test func aListHasItemsAndAnOptionalMessage() throws {
        let decoded = try #require(listing(#"""
        {"items": [
            {"id": "emails", "title": "emails", "subtitle": "12 pending", "badge": "12"},
            {"id": "invoices", "title": "Invoices", "badge": 3},
            {"id": 7}
        ], "message": "16 jobs pending"}
        """#))
        #expect(decoded.items == [
            .init(id: "emails", title: "emails", subtitle: "12 pending", badge: "12"),
            .init(id: "invoices", title: "Invoices", badge: "3"),
            // A number is an id too; a missing title is the id.
            .init(id: "7", title: "7"),
        ])
        #expect(decoded.message == "16 jobs pending")
        #expect(decoded.skipped.isEmpty)
    }

    @Test func invalidItemsAreSkippedAndNamed() throws {
        let decoded = try #require(listing(#"""
        {"items": [
            {"title": "no id"}, "text", {"id": "  "}, {"id": true},
            {"id": "a", "title": "A", "subtitle": "", "badge": null}, {"id": "a", "title": "again"}
        ]}
        """#))
        #expect(decoded.items == [.init(id: "a", title: "A")])
        #expect(decoded.skipped == ["item 1 (no id)", "item 2 (no id)", "item 3 (no id)", "item 4 (no id)", "a (the id is used twice)"])
        #expect(decoded.message == nil)
    }

    @Test func anObjectWithoutAnItemsArrayIsNoList() {
        #expect(listing(#"{"commands": []}"#) == nil)
        #expect(listing(#"{"items": {"a": 1}}"#) == nil)
        #expect(listing("[1, 2]") == nil)
        #expect(listing("not json") == nil)
        #expect(listing(#"{"items": []}"#)?.items == [])
    }

    private func catalog(_ tabs: [DriverInspectorTab], declared: Bool) -> ProjectCommandCatalog {
        var catalog = ProjectCommandCatalog()
        catalog.inspectorTabs = tabs
        catalog.inspectorTabsDeclared = declared
        return catalog
    }

    private let queues = DriverInspectorTab(id: "queues", title: "Queues", icon: "tray.full", listCommand: "tool queues --json", runCommand: "tool work {id}", emptyText: "Nothing pending.")

    @Test func declaredTabsAreRememberedPerTarget() {
        var memory = DriverInspectorTabMemory()
        #expect(!memory.knows("local:a", loaded: nil))
        let changed1 = memory.remember(catalog([queues], declared: true), for: "local:a")
        #expect(changed1)
        #expect(memory.tabs(for: "local:a", loaded: nil) == [queues])
        #expect(memory.knows("local:a", loaded: nil))
        // The same declaration again changes nothing (no save); none is remembered as none.
        let changed2 = memory.remember(catalog([queues], declared: true), for: "local:a")
        #expect(!changed2)
        let changed3 = memory.remember(catalog([], declared: true), for: "local:a")
        #expect(changed3)
        #expect(memory.knows("local:a", loaded: nil))
        #expect(memory.tabs(for: "local:a", loaded: nil).isEmpty)
    }

    @Test func aListingThatDidntReachTheDriverChangesNothing() {
        var memory = DriverInspectorTabMemory(tabs: ["docker:b": [queues]])
        let changed4 = memory.remember(catalog([], declared: false), for: "docker:b")
        #expect(!changed4)
        #expect(memory.tabs(for: "docker:b", loaded: catalog([], declared: false)) == [queues])
        // A loaded declaration wins over the remembered one.
        #expect(memory.tabs(for: "docker:b", loaded: catalog([], declared: true)).isEmpty)
        #expect(!memory.knows("docker:c", loaded: catalog([], declared: false)))
        memory.forget("docker:b")
        #expect(!memory.knows("docker:b", loaded: nil))
    }

    @Test func theMemorySurvivesARelaunch() throws {
        var memory = DriverInspectorTabMemory()
        memory.remember(catalog([queues, DriverInspectorTab(id: "jobs", title: "Jobs", listCommand: "jobs", runCommand: "job {id}")], declared: true), for: "local:a")
        memory.remember(catalog([], declared: true), for: "ssh:c")
        let data = try JSONEncoder().encode(memory)
        let restored = try JSONDecoder().decode(DriverInspectorTabMemory.self, from: data)
        #expect(restored == memory)
        #expect(restored.tabs(for: "local:a", loaded: nil).map(\.id) == ["queues", "jobs"])
        #expect(restored.tabs(for: "local:a", loaded: nil).last?.icon == nil)
        #expect(restored.tabs(for: "local:a", loaded: nil).last?.symbol == "rectangle.stack")
        #expect(restored.knows("ssh:c", loaded: nil))
    }
}
