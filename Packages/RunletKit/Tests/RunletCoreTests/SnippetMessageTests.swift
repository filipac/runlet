import Foundation
import Testing
@testable import RunletCore

/// `\Runlet\notice()`, `warning()`, and `error()` (#196): decoding the runner's `notice` events
/// (old and new), how the cards read in Copy Output and MCP results, the footer's counts, and
/// that none of them fails a run.
struct SnippetMessageTests {
    static func kind(_ json: String) throws -> RunEvent.Kind {
        try SnippetMessage.noticeEvent(payload: Data(json.utf8))
    }

    @Test func aPlainNoticeStaysRunletsOwnNotice() throws {
        // What every runner before #196 sent, and what Runlet's own notices still are.
        #expect(try Self.kind(#"{"message":"Runlet does not record queries on the \"pdo\" PDO connection."}"#) == .notice("Runlet does not record queries on the \"pdo\" PDO connection."))
        #expect(try Self.kind(#"{}"#) == .notice(""))
        // Fields a later runner might add don't make it a card without a level.
        #expect(try Self.kind(#"{"message":"x","user":true}"#) == .notice("x"))
    }

    @Test func aLeveledNoticeIsTheSnippetsCard() throws {
        let json = #"""
        {"message":"Cache is cold","level":"warning","user":true,"inSnippet":true,"snippetLine":3,
         "context":{"id":1,"type":"array","count":1,"entries":[{"key":"store","keyType":"string","value":{"id":2,"type":"string","length":5,"scalar":"redis"}}]}}
        """#
        guard case .snippetMessage(let message) = try Self.kind(json) else {
            Issue.record("expected a snippet message")
            return
        }
        #expect(message.level == .warning)
        #expect(message.message == "Cache is cold")
        #expect(message.user == true)
        #expect(message.callerSnippetLine == 3)
        #expect(message.context?.entries?.first?.key == "store")
        #expect(message.context?.entries?.first?.value.scalar == "redis")
        #expect(message.exception == nil)
    }

    @Test func anErrorCardCarriesTheThrowable() throws {
        let json = #"""
        {"message":"deep","level":"error","user":true,"inSnippet":true,"snippetLine":2,
         "exception":{"className":"DomainException","inSnippet":true,"snippetLine":1,
           "trace":[{"function":"fail","inSnippet":true,"snippetLine":2}],
           "previous":{"className":"LogicException","message":"cause"}}}
        """#
        guard case .snippetMessage(let message) = try Self.kind(json) else {
            Issue.record("expected a snippet message")
            return
        }
        #expect(message.level == .error)
        let exception = try #require(message.exception)
        #expect(exception.className == "DomainException")
        #expect(exception.snippetLine == 1)
        #expect(exception.trace?.first?.function == "fail")
        #expect(exception.previous?.className == "LogicException")
        #expect(message.text == "DomainException: deep")
        #expect(message.summary(line: 2) == "Error (line 2): DomainException: deep\nCaused by LogicException: cause")
    }

    @Test func unknownLevelsAndProjectFilesAreRead() throws {
        guard case .snippetMessage(let message) = try Self.kind(#"{"message":"m","level":"critical","inSnippet":false,"file":"/app/src/Job.php","line":12}"#) else {
            Issue.record("expected a snippet message")
            return
        }
        #expect(message.level == .notice, "a level a newer runner adds reads as a notice")
        #expect(message.callerSnippetLine == nil)
        #expect(message.summary(line: nil) == "Notice (/app/src/Job.php:12): m")
    }

    @Test func summariesNameTheLineContextAndClippedBytes() {
        let context = ValueNode(id: 1, type: .int, scalar: "7")
        var message = SnippetMessage(level: .notice, message: "Imported", inSnippet: true, snippetLine: 4, context: context)
        #expect(message.summary(line: 4) == "Notice (line 4): Imported\nContext: 7")
        message.context = nil
        message.omittedBytes = 10
        #expect(message.summary(line: 9) == "Notice (line 9): Imported … (10 more bytes)")
        #expect(SnippetMessage.Level.allCases.map(\.symbol) == ["ℹ︎", "⚠︎", "✖︎"])
    }

    @Test func theCallingLineMapsThroughARunSelection() {
        // Run Selection from editor line 10: snippet line 3 is editor line 12.
        let selection = SourceSelection(startLine: 10, startColumn: 1, utf16Range: NSRangeCodable(location: 0, length: 0))
        let message = SnippetMessage(level: .warning, message: "w", inSnippet: true, snippetLine: 3)
        #expect(message.callerSnippetLine.map { RunRequest.editorLine(forSnippetLine: $0, selection: selection) } == 12)
        #expect(SnippetMessage(level: .warning, message: "w", inSnippet: false, snippetLine: 3, file: "/x.php", line: 1).callerSnippetLine == nil)
    }

    @Test func theFooterCountsWarningsAndErrors() {
        var counts = SnippetMessageCounts()
        #expect(counts.footer == nil)
        counts.add(.notice)
        #expect(counts.footer == nil, "notices are left out of the footer")
        counts.add(.warning)
        #expect(counts.footer == "1 warning")
        counts.add(.warning)
        counts.add(.error)
        #expect(counts.footer == "2 warnings, 1 error")
        #expect(counts == SnippetMessageCounts(notices: 1, warnings: 2, errors: 1))
    }

    @Test func mcpResultsIncludeTheCardsWithoutFailingTheRun() {
        var report = MCPRunReport(clientName: "c", tabTitle: "t", targetLabel: "sandbox")
        report.apply(.snippetMessage(SnippetMessage(level: .notice, message: "Imported 120 rows", inSnippet: true, snippetLine: 1)))
        report.apply(.snippetMessage(SnippetMessage(level: .warning, message: "Cache is cold", inSnippet: true, snippetLine: 3, context: ValueNode(id: 1, type: .string, scalar: "redis"))))
        report.apply(.snippetMessage(SnippetMessage(level: .error, message: "boom", inSnippet: true, snippetLine: 5, exception: .init(className: "RuntimeException"))))
        report.apply(.result(ResultInfo(hasValue: true, value: ValueNode(id: 1, type: .string, scalar: "done"))))
        report.apply(.finished(FinishedInfo(status: .completed, reason: "completed", elapsedMs: 3)))
        let result = report.toolResult()
        #expect(!result.isError, "error() doesn't fail the run")
        #expect(result.text.contains("Notice (line 1): Imported 120 rows"))
        #expect(result.text.contains("Warning (line 3): Cache is cold\nContext: \"redis\""), "\(result.text)")
        #expect(result.text.contains("Error (line 5): RuntimeException: boom"))
        #expect(result.structured?["errors"] == [], "an error card is not an error")
        #expect(result.structured?["messages"] == [
            ["level": "notice", "message": "Imported 120 rows", "line": 1],
            ["level": "warning", "message": "Cache is cold", "line": 3, "context": "\"redis\""],
            ["level": "error", "message": "boom", "line": 5, "class": "RuntimeException"],
        ])
    }

    @Test func aRunWithErrorCardsIsCompletedForHistoryAndNotifications() {
        // The runner reports `completed`; history and notifications read only FinishedInfo.
        let finished = FinishedInfo(status: .completed, reason: "completed", elapsedMs: 12_000)
        #expect(RunNotificationOutcome(finished) == .completed)
        // The output gate holds the cards like other output in At once mode, and they never
        // count as status events.
        #expect(!RunEventGate.isStatus(.snippetMessage(SnippetMessage(level: .error, message: "e"))))
    }
}
