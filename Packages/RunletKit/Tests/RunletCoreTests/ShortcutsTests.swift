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

    @Test func fuzzyMatchPrefersTitleWordsOverScatteredLetters() {
        // Command palette rows: title, then category and keywords.
        let commands = [
            ("New Window", "File"),
            ("Open Anything…", "Library · switch target project docker snippet file quick open"),
            ("Delete Current Target…", "Library · remove docker profile project"),
            ("New Docker Profile…", "Library · container"),
            ("Manage Docker Profiles…", "Library · docker profiles containers edit delete duplicate list window"),
        ]
        func ranked(_ query: String) -> [String] {
            commands.compactMap { title, detail in FuzzyMatch.score(query, fields: [title, detail]).map { (title, $0) } }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        }
        let dock = ranked("dock")
        #expect(!dock.contains("New Window"))
        #expect(Set(dock.prefix(2)) == ["New Docker Profile…", "Manage Docker Profiles…"])
        #expect(dock.firstIndex(of: "Open Anything…")! > 1)
        #expect(ranked("manage").first == "Manage Docker Profiles…")
        #expect(ranked("docker prof").prefix(2).contains("Manage Docker Profiles…"))
        #expect(!ranked("docker prof").contains("Open Anything…"))
        // Pieces that start successive title words still match; scattered letters elsewhere don't.
        #expect(FuzzyMatch.score("mdp", "Manage Docker Profiles…") != nil)
        #expect(FuzzyMatch.score("dck", fields: ["Other", "docker"]) == nil)
        #expect(FuzzyMatch.score("doc", fields: ["Other", "load-docker"]) != nil)
        #expect(FuzzyMatch.score("ab", "TabBar") != nil)
        #expect(FuzzyMatch.score("tb", "tabBar") != nil)
    }

    @Test func paletteModeSwitchKeepsTypedText() {
        #expect(PaletteQuery.carriedOver("") == "")
        #expect(PaletteQuery.carriedOver("run") == "run")
        #expect(PaletteQuery.carriedOver("@cat") == "cat")
        #expect(PaletteQuery.carriedOver("# seed") == "seed")
        #expect(PaletteQuery.carriedOver(">") == "")
        #expect(PaletteQuery.carriedOver("> run sel") == "run sel")
        #expect(PaletteQuery.carriedOver("!User::") == "User::")
    }

    /// Open Anything lists the Appearance commands in its plain results only for these words (#135).
    @Test func appearanceWordsNameTheAppearanceCommands() {
        let words = AppearancePreference.searchWords
        for query in ["dark", "Light", "auto", "system", "theme", "mode", "appearance", "dark mode", "Appearance: Dark", "auto (system)", "dar", "sys", " light "] {
            #expect(PaletteQuery.names(query, oneOf: words), "\(query)")
        }
        for query in ["", "  ", "d", "da", "darkness", "dark sandbox", "laravel", "lease", "#", "1"] {
            #expect(!PaletteQuery.names(query, oneOf: words), "\(query)")
        }
    }

    @Test func appearanceWordsRankTheirCommandFirst() {
        // Palette rows for the three commands: title, then category and keywords.
        let detail = "View · " + AppearancePreference.searchWords.joined(separator: " ")
        let titles = AppearancePreference.allCases.map { "Appearance: \($0.displayName)" }
        #expect(titles == ["Appearance: Auto (System)", "Appearance: Light", "Appearance: Dark"])
        func ranked(_ query: String) -> [String] {
            titles.enumerated().compactMap { index, title in FuzzyMatch.score(query, fields: [title, detail]).map { (title, $0, index) } }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
                .map(\.0)
        }
        #expect(ranked("dark").first == "Appearance: Dark")
        #expect(ranked("light").first == "Appearance: Light")
        #expect(ranked("auto").first == "Appearance: Auto (System)")
        #expect(ranked("system").first == "Appearance: Auto (System)")
        // Words that name no one choice keep the list's order, so ↩ never picks at random.
        #expect(ranked("theme") == titles)
        #expect(ranked("appearance") == titles)
        #expect(ranked("dark mode").first == "Appearance: Dark")
    }
}
