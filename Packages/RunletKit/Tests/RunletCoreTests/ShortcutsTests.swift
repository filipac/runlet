import Foundation
import Testing
@testable import RunletCore

struct ShortcutsTests {
    @Test func displayUsesMenuOrder() {
        #expect(KeyCombo("p", [.command, .shift]).displayString == "⇧⌘P")
        #expect(KeyCombo("t", [.command, .control]).displayString == "⌃⌘T")
        #expect(KeyCombo("escape", [.option]).displayString == "⌥⎋")
        #expect(KeyCombo("R", [.command]).key == "r")
        #expect(!KeyCombo("r", [.shift]).isValidShortcut)
        #expect(KeyCombo("escape", []).isValidShortcut)
    }

    @Test func overridesReplaceOrRemoveDefaults() {
        let defaults: [String: KeyCombo?] = ["run": KeyCombo("r"), "stop": KeyCombo("."), "reset": nil]
        let effective = ShortcutResolver.effective(defaults: defaults, overrides: [
            "run": ShortcutOverride(combo: KeyCombo("e")),
            "stop": ShortcutOverride(combo: nil),
            "reset": ShortcutOverride(combo: KeyCombo("r")),
        ])
        #expect(effective == ["run": KeyCombo("e"), "reset": KeyCombo("r")])
    }

    @Test func conflictsAreReported() {
        let conflicts = ShortcutResolver.conflicts(in: ["a": KeyCombo("r"), "b": KeyCombo("r"), "c": KeyCombo("k")])
        #expect(conflicts == [KeyCombo("r"): ["a", "b"]])
    }

    @Test func fuzzyMatchRanksSensibly() {
        #expect(FuzzyMatch.score("xyz", "Run Selection") == nil)
        let runSelection = FuzzyMatch.score("rs", "Run Selection")!
        let restart = FuzzyMatch.score("rs", "Restart Language Server")!
        #expect(runSelection > restart)
        #expect(FuzzyMatch.score("cat", "Catalog Worker")! > FuzzyMatch.score("cat", "Duplicate Tab")!)
        #expect(FuzzyMatch.score("vt", "Vertical Tabs") != nil)
        #expect(FuzzyMatch.score("", "anything") == 0)
        #expect(FuzzyMatch.score("lease", fields: ["Lease API", "/var/www"])! > FuzzyMatch.score("lease", fields: ["Other", "lease-api/app"])!)
    }
}
