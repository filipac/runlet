import Foundation
import Testing
@testable import RunletCore

/// Shortcut tips (#345): the rule that decides when a command's tip shows, the record of how
/// commands were run, and the tip's words.
struct ShortcutTipsTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func hours(_ count: Double) -> Date { start.addingTimeInterval(count * 60 * 60) }
    private let tabLayout = KeyCombo("t", [.command, .control])

    /// Records a click on `id` the way the app does: asks the rule first, then counts the use
    /// and, when the rule said so, the tip.
    @discardableResult
    private func click(_ id: String, from source: CommandSource = .toolbar, in record: inout ShortcutTipRecord,
                       shortcut: KeyCombo?, enabled: Bool = true, at now: Date) -> ShortcutTipRule.Decision {
        let decision = ShortcutTipRule.decide(source: source, shortcut: shortcut, entry: record.entry(id), enabled: enabled, now: now)
        record.record(id, source: source, tipShown: decision == .show ? now : nil)
        return decision
    }

    // MARK: The rule

    @Test func aClickOnACommandWithAShortcutShowsTheTip() {
        for source in [CommandSource.menu, .toolbar, .button, .palette] {
            #expect(ShortcutTipRule.decide(source: source, shortcut: tabLayout, entry: .init(), enabled: true, now: start) == .show)
        }
    }

    @Test func theKeyboardAndScriptsNeverShowOne() {
        #expect(ShortcutTipRule.decide(source: .keyboard, shortcut: tabLayout, entry: .init(), enabled: true, now: start) == .notClicked)
        #expect(ShortcutTipRule.decide(source: .script, shortcut: tabLayout, entry: .init(), enabled: true, now: start) == .notClicked)
    }

    @Test func aCommandWithoutAShortcutHasNoTip() {
        #expect(ShortcutTipRule.decide(source: .menu, shortcut: nil, entry: .init(), enabled: true, now: start) == .noShortcut)
    }

    @Test func atMostOneTipPerCommandADay() {
        var record = ShortcutTipRecord()
        #expect(click("view.verticalTabs", in: &record, shortcut: tabLayout, at: start) == .show)
        // The second click that afternoon, and one just before a day has passed, show nothing.
        #expect(click("view.verticalTabs", in: &record, shortcut: tabLayout, at: hours(3)) == .shownRecently)
        #expect(click("view.verticalTabs", in: &record, shortcut: tabLayout, at: hours(23.9)) == .shownRecently)
        // Another command has its own day.
        #expect(click("file.newTab", from: .button, in: &record, shortcut: KeyCombo("t"), at: hours(3)) == .show)
        // A day after the last tip, it shows again.
        #expect(click("view.verticalTabs", in: &record, shortcut: tabLayout, at: hours(24)) == .show)
        #expect(record.entry("view.verticalTabs").lastTip == hours(24))
        #expect(record.entry("view.verticalTabs").count(.toolbar) == 4)
    }

    @Test func aClockSetBackShowsNothingUntilADayAfterTheLastTip() {
        var record = ShortcutTipRecord()
        click("view.verticalTabs", in: &record, shortcut: tabLayout, at: hours(48))
        #expect(click("view.verticalTabs", in: &record, shortcut: tabLayout, at: start) == .shownRecently)
        #expect(click("view.verticalTabs", in: &record, shortcut: tabLayout, at: hours(72)) == .show)
    }

    @Test func theTipStopsForGoodOnceTheShortcutIsLearned() {
        var record = ShortcutTipRecord()
        click("view.verticalTabs", in: &record, shortcut: tabLayout, at: start)
        record.record("view.verticalTabs", source: .keyboard)
        record.record("view.verticalTabs", source: .keyboard)
        // Two uses of the shortcut aren't a habit yet.
        #expect(click("view.verticalTabs", in: &record, shortcut: tabLayout, at: hours(30)) == .show)
        record.record("view.verticalTabs", source: .keyboard)
        #expect(record.entry("view.verticalTabs").count(.keyboard) == ShortcutTipRule.learnedAfter)
        // The third use: never again, however long it has been.
        #expect(click("view.verticalTabs", in: &record, shortcut: tabLayout, at: hours(24 * 365)) == .learned)
    }

    @Test func dontShowAgainStopsOnlyThatCommand() {
        var record = ShortcutTipRecord()
        click("view.verticalTabs", in: &record, shortcut: tabLayout, at: start)
        record.dismissTip("view.verticalTabs")
        #expect(click("view.verticalTabs", in: &record, shortcut: tabLayout, at: hours(24 * 30)) == .dismissed)
        #expect(click("output.copy", from: .button, in: &record, shortcut: KeyCombo("c", [.command, .option]), at: hours(24 * 30)) == .show)
    }

    @Test func tipsTurnedOffShowNothingButStillCount() {
        var record = ShortcutTipRecord()
        #expect(click("view.verticalTabs", in: &record, shortcut: tabLayout, enabled: false, at: start) == .turnedOff)
        #expect(record.entry("view.verticalTabs").count(.toolbar) == 1)
        #expect(record.entry("view.verticalTabs").lastTip == nil)
        // Turned on again, the first click shows it.
        #expect(click("view.verticalTabs", in: &record, shortcut: tabLayout, at: hours(1)) == .show)
    }

    @Test func aRemappedShortcutStillShowsAndARemovedOneDoesNot() {
        var record = ShortcutTipRecord()
        let remapped = KeyCombo("v", [.command, .option, .shift])
        #expect(click("view.verticalTabs", in: &record, shortcut: remapped, at: start) == .show)
        // The user removed the shortcut: nothing to learn, so no tip, and its day doesn't start.
        #expect(click("output.copy", from: .button, in: &record, shortcut: nil, at: start) == .noShortcut)
        #expect(record.entry("output.copy").lastTip == nil)
        #expect(click("output.copy", from: .button, in: &record, shortcut: KeyCombo("c", [.command, .option]), at: hours(1)) == .show)
    }

    // MARK: The record

    @Test func usesAreCountedBySourceAndScriptsAreNot() {
        var record = ShortcutTipRecord()
        record.record("run.run", source: .keyboard)
        record.record("run.run", source: .keyboard)
        record.record("run.run", source: .toolbar)
        record.record("run.run", source: .palette)
        record.record("run.run", source: .script)
        record.record("tabs.rename", source: .script)
        let entry = record.entry("run.run")
        #expect(entry.count(.keyboard) == 2)
        #expect(entry.count(.toolbar) == 1)
        #expect(entry.count(.palette) == 1)
        #expect(entry.count(.menu) == 0)
        #expect(entry.count(.script) == 0)
        #expect(record.entries["tabs.rename"] == nil)
    }

    @Test func commandsNoLongerInTheCatalogAreDropped() {
        var record = ShortcutTipRecord()
        record.record("run.run", source: .menu)
        record.record("gone.command", source: .menu)
        record.prune(keeping: ["run.run"])
        #expect(Set(record.entries.keys) == ["run.run"])
    }

    @Test func clearingTheHistoryKeepsDontShowAgain() {
        var record = ShortcutTipRecord()
        #expect(!record.hasHistory)
        record.record("run.run", source: .keyboard)
        record.record("view.verticalTabs", source: .toolbar, tipShown: start)
        record.dismissTip("view.verticalTabs")
        record.dismissTip("output.copy")
        #expect(record.hasHistory)
        record.clearHistory()
        #expect(!record.hasHistory)
        #expect(record.entries == ["view.verticalTabs": .init(tipDismissed: true), "output.copy": .init(tipDismissed: true)])
        #expect(click("view.verticalTabs", in: &record, shortcut: tabLayout, at: start) == .dismissed)
        #expect(click("run.run", in: &record, shortcut: KeyCombo("r"), at: start) == .show)
    }

    @Test func theFileRoundTripsAndDamagedPartsAreLeftOut() throws {
        var record = ShortcutTipRecord()
        record.record("run.run", source: .keyboard, tipShown: start)
        record.dismissTip("view.verticalTabs")
        let decoded = try JSONDecoder().decode(ShortcutTipRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)

        let json = #"""
        {"entries": {
            "run.run": {"uses": {"keyboard": 2, "toolbar": 1, "touchBar": 4}, "lastTip": 800000000},
            "output.copy": "nonsense",
            "view.verticalTabs": {"tipDismissed": true, "uses": "nonsense"},
            "file.newTab": {}
        }, "later": true}
        """#
        let damaged = try JSONDecoder().decode(ShortcutTipRecord.self, from: Data(json.utf8))
        #expect(damaged.entry("run.run").count(.keyboard) == 2)
        // A source this Runlet doesn't know is kept, for the Runlet that wrote it.
        #expect(damaged.entry("run.run").uses["touchBar"] == 4)
        #expect(damaged.entry("run.run").lastTip == start)
        #expect(damaged.entries["output.copy"] == nil)
        #expect(damaged.entry("view.verticalTabs").tipDismissed)
        #expect(damaged.entry("view.verticalTabs").uses.isEmpty)
        #expect(damaged.entries["file.newTab"] == ShortcutTipRecord.Entry())

        #expect(try JSONDecoder().decode(ShortcutTipRecord.self, from: Data("{}".utf8)).isEmpty)
        #expect(try JSONDecoder().decode(ShortcutTipRecord.self, from: Data(#"{"entries": []}"#.utf8)).isEmpty)
    }

    @Test func theSettingIsOnByDefaultAndLoadsFromOlderFiles() throws {
        #expect(AppSettings().shortcutTips)
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data(#"{"fontSize":14}"#.utf8)).shortcutTips)
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data(#"{"shortcutTips":"nonsense"}"#.utf8)).shortcutTips)
        var off = AppSettings()
        off.shortcutTips = false
        #expect(try !JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(off)).shortcutTips)
        #expect(AppPaths(root: URL(fileURLWithPath: "/tmp/r")).shortcutTips.path == "/tmp/r/State/shortcut-tips.json")
    }

    // MARK: The words

    @Test func theSentenceNamesTheCommandAndWhatTheShortcutSaves() {
        #expect(ShortcutTipText.sentence(keys: "⌃⌘T", title: "Toggle Vertical Tabs", source: .toolbar)
            == "⌃⌘T is the shortcut for Toggle Vertical Tabs. It saves a trip to the toolbar.")
        #expect(ShortcutTipText.sentence(keys: "⌘P", title: "Open Anything…", source: .menu)
            == "⌘P is the shortcut for Open Anything. It saves a trip to the menu bar.")
        #expect(ShortcutTipText.sentence(keys: "⇧⌘B", title: "Show Database", source: .palette)
            == "⇧⌘B is the shortcut for Show Database. It skips the palette.")
        #expect(ShortcutTipText.sentence(keys: "⌥⌘C", title: "Copy Output", source: .button)
            == "⌥⌘C is the shortcut for Copy Output. It keeps your hands on the keyboard.")
        #expect(ShortcutTipText.commandName("Save Workspace As...") == "Save Workspace As")
        // The tip shows the keys as key caps, then the rest of the sentence.
        #expect(ShortcutTipText.predicate(title: "New Tab", source: .button) == "is the shortcut for New Tab. It keeps your hands on the keyboard.")
    }

    @Test func keyCapsAreTheModifiersInMenuOrderThenTheKey() {
        #expect(KeyCombo("t", [.command, .control]).displayKeys == ["⌃", "⌘", "T"])
        #expect(KeyCombo("r", [.shift, .command, .option]).displayKeys == ["⌥", "⇧", "⌘", "R"])
        #expect(KeyCombo("escape", [.option]).displayKeys == ["⌥", "⎋"])
        #expect(KeyCombo("f12", []).displayKeys == ["F12"])
        #expect(KeyCombo("t", [.command, .control]).displayKeys.joined() == KeyCombo("t", [.command, .control]).displayString)
    }
}
