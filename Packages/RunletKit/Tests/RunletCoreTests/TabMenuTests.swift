import Testing
@testable import RunletCore

/// The shared tab context menu (#214): both tab styles build it from `TabMenuItem.items(for:)`.
struct TabMenuTests {
    @Test(arguments: TabLanguage.allCases)
    func everyOtherLanguageHasASwitchItem(_ language: TabLanguage) {
        let items = TabMenuItem.items(for: language)
        let switches = items.compactMap { item -> TabLanguage? in
            if case .switchLanguage(let target) = item { return target }
            return nil
        }
        #expect(switches == TabLanguage.allCases.filter { $0 != language })
        #expect(!switches.contains(language))
        #expect(items.first == .rename)
        #expect(Array(items.suffix(3)) == [.divider, .close, .closeOthers])
    }

    @Test func titlesPerLanguage() {
        #expect(TabMenuItem.items(for: .php).map(\.title) == ["Rename…", "Duplicate", "Switch to SQL", "Switch to Redis", "Switch to MongoDB", "", "Close", "Close Other Tabs"])
        #expect(TabMenuItem.items(for: .sql).map(\.title).filter { $0.hasPrefix("Switch") } == ["Switch to PHP", "Switch to Redis", "Switch to MongoDB"])
        #expect(TabMenuItem.items(for: .redis).map(\.title).filter { $0.hasPrefix("Switch") } == ["Switch to PHP", "Switch to SQL", "Switch to MongoDB"])
        #expect(TabMenuItem.items(for: .mongodb).map(\.title).filter { $0.hasPrefix("Switch") } == ["Switch to PHP", "Switch to SQL", "Switch to Redis"])
    }
}
