import Foundation
import Testing
@testable import RunletCore

struct HistoryLogTests {
    static let project = TargetRef.local(UUID())

    static func entry(_ code: String, _ target: TargetRef = .sandbox, status: RunStatus = .completed, at seconds: TimeInterval = 0) -> HistoryEntry {
        HistoryEntry(runId: UUID(), timestamp: Date(timeIntervalSince1970: seconds), code: code, target: target, targetLabel: "t", status: status, reason: status.rawValue, elapsedMs: 10)
    }

    @Test func rerunningTheSameCodeMovesItsEntryToTheTop() {
        let first = Self.entry("User::count()", at: 1)
        let other = Self.entry("app()", at: 2)
        let history = [other, first]
        let rerun = Self.entry("User::count()\n", status: .failed, at: 3)
        let result = HistoryLog.recording(rerun, into: history, limit: 100)
        #expect(result.count == 2)
        #expect(result[0].id == first.id, "keeps the entry's identity so a selection survives")
        #expect(result[0].status == .failed)
        #expect(result[0].timestamp == rerun.timestamp)
        #expect(result[0].runId == rerun.runId)
        #expect(result[1].id == other.id)
    }

    @Test func sameCodeOnAnotherTargetIsSeparate() {
        let sandbox = Self.entry("app()")
        let result = HistoryLog.recording(Self.entry("app()", Self.project), into: [sandbox], limit: 100)
        #expect(result.count == 2)
        #expect(result[1].id == sandbox.id)
    }

    @Test func differentCodeIsAddedAndTheLimitHolds() {
        let history = (0..<3).map { Self.entry("echo \($0);", at: Double($0)) }.reversed()
        let result = HistoryLog.recording(Self.entry("echo 9;"), into: Array(history), limit: 3)
        #expect(result.map(\.code) == ["echo 9;", "echo 2;", "echo 1;"])
    }

    @Test func loadingCollapsesOlderDuplicates() {
        let newest = Self.entry("app()", at: 3)
        let middle = Self.entry("other()", at: 2)
        let oldest = Self.entry("  app()  ", at: 1)
        let elsewhere = Self.entry("app()", Self.project, at: 0)
        #expect(HistoryLog.collapsingDuplicates([newest, middle, oldest, elsewhere]).map(\.id) == [newest.id, middle.id, elsewhere.id])
    }
}
