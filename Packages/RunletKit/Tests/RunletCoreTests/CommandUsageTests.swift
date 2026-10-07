import Foundation
import Testing
@testable import RunletCore

/// Usage-ranked commands (#328): the frecency record, and the palette order it gives with and
/// without a query.
struct CommandUsageTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func days(_ count: Double) -> Date { start.addingTimeInterval(count * 24 * 60 * 60) }

    private func usage(_ uses: [(String, Int)], at date: Date? = nil) -> CommandUsage {
        var usage = CommandUsage()
        for (id, count) in uses { for _ in 0..<count { usage.record(id, at: date ?? start) } }
        return usage
    }

    // MARK: The record

    @Test func aUseCountsOneAndHalvesEveryTwoWeeks() {
        var usage = CommandUsage()
        #expect(usage.frecency(of: "run.run", at: start) == 0)
        usage.record("run.run", at: start)
        usage.record("run.run", at: start)
        #expect(usage.frecency(of: "run.run", at: start) == 2)
        #expect(abs(usage.frecency(of: "run.run", at: days(14)) - 1) < 1e-9)
        #expect(abs(usage.frecency(of: "run.run", at: days(28)) - 0.5) < 1e-9)
        #expect(usage.entries["run.run"]?.uses == 2)
        #expect(usage.entries["run.run"]?.lastUsed == start)
    }

    @Test func aNewUseAddsToWhatIsLeftOfTheOldOnes() {
        var usage = CommandUsage()
        usage.record("run.run", at: start)
        usage.record("run.run", at: days(14))
        #expect(abs(usage.frecency(of: "run.run", at: days(14)) - 1.5) < 1e-9)
        #expect(usage.entries["run.run"]?.uses == 2)
        #expect(usage.entries["run.run"]?.lastUsed == days(14))
    }

    @Test func oldHabitsFadeBehindRecentUse() {
        var usage = CommandUsage()
        for _ in 0..<100 { usage.record("tabs.togglePin", at: start) }
        usage.record("tabs.rename", at: days(120))
        // A hundred uses four months ago count for less than one today.
        #expect(usage.frecency(of: "tabs.togglePin", at: days(120)) < usage.frecency(of: "tabs.rename", at: days(120)))
        // Ten uses six weeks ago count for less than two today.
        var recent = CommandUsage()
        for _ in 0..<10 { recent.record("file.newTab", at: start) }
        for _ in 0..<2 { recent.record("run.run", at: days(42)) }
        #expect(recent.frecency(of: "file.newTab", at: days(42)) < recent.frecency(of: "run.run", at: days(42)))
    }

    @Test func aClockSetBackNeverAddsWeight() {
        let usage = usage([("run.run", 3)], at: days(10))
        #expect(usage.frecency(of: "run.run", at: start) == 3)
    }

    @Test func entriesThatDecayedAwayAreForgotten() {
        var usage = CommandUsage()
        usage.record("tabs.rename", at: start)
        usage.record("run.run", at: days(80))
        #expect(usage.entries["tabs.rename"] != nil)
        // One use is gone after about 93 days.
        usage.record("run.run", at: days(100))
        #expect(usage.entries["tabs.rename"] == nil)
        #expect(usage.entries["run.run"] != nil)
    }

    @Test func theRecordKeepsTheStrongestUpToItsCapacity() {
        var usage = CommandUsage()
        for index in 0..<(CommandUsage.capacity + 5) {
            usage.record("command.\(index)", at: start.addingTimeInterval(Double(index) * 60))
        }
        #expect(usage.entries.count == CommandUsage.capacity)
        // The oldest uses went.
        for index in 0..<5 { #expect(usage.entries["command.\(index)"] == nil) }
        #expect(usage.entries["command.\(CommandUsage.capacity + 4)"] != nil)
    }

    @Test func unknownIdsArePruned() {
        var usage = usage([("run.run", 2), ("removed.command", 5)])
        usage.prune(keeping: ["run.run", "tabs.rename"], at: start)
        #expect(Set(usage.entries.keys) == ["run.run"])
        #expect(usage.frecency(of: "removed.command", at: start) == 0)
    }

    @Test func theRecordRoundTripsAndToleratesDamage() throws {
        let usage = usage([("run.run", 2), ("tabs.rename", 1)])
        let decoded = try JSONDecoder().decode(CommandUsage.self, from: JSONEncoder().encode(usage))
        #expect(decoded == usage)
        let damaged = try JSONDecoder().decode(CommandUsage.self, from: Data(#"{"entries": "nonsense"}"#.utf8))
        #expect(damaged.isEmpty)
        let empty = try JSONDecoder().decode(CommandUsage.self, from: Data("{}".utf8))
        #expect(empty.isEmpty)
    }

    // MARK: An empty command search

    private func commands(_ ids: [String], disabled: Set<String> = []) -> [CommandRanking.Candidate] {
        ids.map { CommandRanking.Candidate(commandId: $0, isEnabled: !disabled.contains($0)) }
    }

    private let catalog = ["file.newTab", "file.closeTab", "run.run", "run.stop", "tabs.togglePin", "tabs.rename", "view.logs", "window.connections"]

    private func ids(_ indices: [Int]) -> [String] { indices.map { catalog[$0] } }

    @Test func withoutUsageTheListKeepsCatalogOrder() {
        let order = CommandRanking.emptyQueryOrder(commands(catalog), usage: CommandUsage(), now: start)
        #expect(ids(order.indices) == catalog)
        #expect(order.frequentCount == 0)
    }

    @Test func theMostUsedComeFirstThenTheRestInCatalogOrderOnce() {
        let usage = usage([("view.logs", 4), ("run.run", 9), ("tabs.rename", 1)])
        let order = CommandRanking.emptyQueryOrder(commands(catalog), usage: usage, now: start)
        #expect(order.frequentCount == 3)
        #expect(ids(order.indices) == ["run.run", "view.logs", "tabs.rename", "file.newTab", "file.closeTab", "run.stop", "tabs.togglePin", "window.connections"])
    }

    @Test func atMostFiveArePromoted() {
        let usage = usage(catalog.enumerated().map { ($0.element, $0.offset + 1) })
        let order = CommandRanking.emptyQueryOrder(commands(catalog), usage: usage, now: start)
        #expect(order.frequentCount == CommandRanking.frequentLimit)
        #expect(ids(Array(order.indices.prefix(5))) == ["window.connections", "view.logs", "tabs.rename", "tabs.togglePin", "run.stop"])
        #expect(ids(Array(order.indices.dropFirst(5))) == ["file.newTab", "file.closeTab", "run.run"])
        #expect(Set(order.indices).count == catalog.count)
    }

    @Test func equallyUsedCommandsKeepCatalogOrder() {
        let usage = usage([("tabs.rename", 1), ("file.closeTab", 1)])
        let order = CommandRanking.emptyQueryOrder(commands(catalog), usage: usage, now: start)
        #expect(ids(Array(order.indices.prefix(order.frequentCount))) == ["file.closeTab", "tabs.rename"])
    }

    @Test func disabledCommandsAreNotPromoted() {
        let usage = usage([("run.run", 9), ("run.stop", 2)])
        let order = CommandRanking.emptyQueryOrder(commands(catalog, disabled: ["run.run"]), usage: usage, now: start)
        #expect(order.frequentCount == 1)
        #expect(ids(order.indices) == ["run.stop", "file.newTab", "file.closeTab", "run.run", "tabs.togglePin", "tabs.rename", "view.logs", "window.connections"])
    }

    @Test func commandsUsedLongAgoAreNoLongerPromoted() {
        let usage = usage([("view.logs", 1)])
        // One use three weeks ago is still frequent; five weeks ago it isn't.
        #expect(CommandRanking.emptyQueryOrder(commands(catalog), usage: usage, now: days(21)).frequentCount == 1)
        #expect(CommandRanking.emptyQueryOrder(commands(catalog), usage: usage, now: days(35)).frequentCount == 0)
    }

    @Test func idsOutsideTheListAreIgnored() {
        let usage = usage([("removed.command", 50), ("tabs.rename", 1)])
        let order = CommandRanking.emptyQueryOrder(commands(catalog), usage: usage, now: start)
        #expect(order.frequentCount == 1)
        #expect(ids(Array(order.indices.prefix(1))) == ["tabs.rename"])
        #expect(order.indices.count == catalog.count)
    }

    // MARK: A query

    /// Palette rows as the command palette builds them: title, then category and keywords.
    private struct Row {
        var id: String
        var fields: [String]
    }

    private func ranked(_ query: String, _ rows: [Row], usage: CommandUsage) -> [String] {
        let matched = rows.compactMap { row in FuzzyMatch.score(query, fields: row.fields).map { (row.id, $0) } }
        let candidates = matched.map { CommandRanking.Candidate(commandId: $0.0, score: $0.1) }
        return CommandRanking.order(candidates, usage: usage, now: start).map { matched[$0].0 }
    }

    private let run = Row(id: "run.run", fields: ["Run", "Run · execute"])
    private let rename = Row(id: "tabs.rename", fields: ["Rename Tab…", "Tabs · title name"])
    private let restart = Row(id: "app.restartLanguageServer", fields: ["Restart Language Server", "Runlet · phpantom"])

    @Test func typingRenameRanksRenameTabAboveAHeavilyUsedRun() {
        let heavy = usage([("run.run", 100), ("app.restartLanguageServer", 100)])
        #expect(ranked("rename", [run, restart, rename], usage: heavy).first == "tabs.rename")
        // Even a Run whose keywords match the query loses to the title that starts with it.
        let runWithRename = Row(id: "run.run", fields: ["Run", "Run · execute rerun rename"])
        #expect(ranked("rename", [runWithRename, restart, rename], usage: heavy) == ["tabs.rename", "run.run"])
    }

    @Test func usageBreaksTies() {
        // "r" starts both titles: a tie, which catalog order settles until one is used.
        #expect(ranked("r", [run, rename], usage: CommandUsage()) == ["run.run", "tabs.rename"])
        #expect(ranked("r", [run, rename], usage: usage([("tabs.rename", 1)])) == ["tabs.rename", "run.run"])
    }

    @Test func aStrongMatchBeatsAFrequentCommand() {
        let candidates = [
            CommandRanking.Candidate(commandId: "frequent", score: 80),
            CommandRanking.Candidate(commandId: "better", score: 100),
            CommandRanking.Candidate(commandId: "close", score: 95),
        ]
        let heavy = usage([("frequent", 1000), ("close", 1000)])
        #expect(CommandRanking.order(candidates, usage: heavy, now: start) == [1, 2, 0])
    }

    @Test func usageNudgesCloseScores() {
        // A match two points behind (a word later in the title) is lifted by regular use.
        let candidates = [
            CommandRanking.Candidate(commandId: "unused", score: 80),
            CommandRanking.Candidate(commandId: "used", score: 77),
        ]
        #expect(CommandRanking.order(candidates, usage: CommandUsage(), now: start) == [0, 1])
        #expect(CommandRanking.order(candidates, usage: usage([("used", 1)]), now: start) == [0, 1])
        #expect(CommandRanking.order(candidates, usage: usage([("used", 20)]), now: start) == [1, 0])
    }

    @Test func disabledCommandsGetNoBoost() {
        let candidates = [
            CommandRanking.Candidate(commandId: "run.run", score: 100, isEnabled: false),
            CommandRanking.Candidate(commandId: "tabs.rename", score: 100),
        ]
        let usage = usage([("run.run", 50), ("tabs.rename", 1)])
        #expect(CommandRanking.order(candidates, usage: usage, now: start) == [1, 0])
    }

    @Test func otherRowsKeepTheirPlacesWhileCommandsReorderAmongThemselves() {
        // Open Anything: a target, two Appearance commands, and a snippet.
        let candidates = [
            CommandRanking.Candidate(commandId: nil, score: 100),
            CommandRanking.Candidate(commandId: "view.appearance.dark", score: 90),
            CommandRanking.Candidate(commandId: "view.appearance.light", score: 90),
            CommandRanking.Candidate(commandId: nil, score: 90),
        ]
        let usage = usage([("view.appearance.light", 3)])
        #expect(CommandRanking.order(candidates, usage: CommandUsage(), now: start) == [0, 1, 2, 3])
        #expect(CommandRanking.order(candidates, usage: usage, now: start) == [0, 2, 1, 3])
        // Without a query too (Open Anything's windows, after its targets).
        let plain = candidates.map { CommandRanking.Candidate(commandId: $0.commandId, score: 0) }
        #expect(CommandRanking.order(plain, usage: usage, now: start) == [0, 2, 1, 3])
    }

    @Test func theBoostIsBoundedAndGrowsWithUse() {
        #expect(CommandRanking.boost(forFrecency: 0) == 0)
        #expect(CommandRanking.boost(forFrecency: CommandRanking.halfBoostFrecency) == CommandRanking.maxBoost / 2)
        #expect(CommandRanking.boost(forFrecency: 1) < CommandRanking.boost(forFrecency: 2))
        #expect(CommandRanking.boost(forFrecency: 1_000_000) < CommandRanking.maxBoost)
    }
}
