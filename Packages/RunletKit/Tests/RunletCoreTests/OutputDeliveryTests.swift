import Foundation
import Testing
@testable import RunletCore

/// Output realtime or at once (#82): holding and replaying a run's events, the setting and its
/// migration from the magic comments' switch, batching and pacing UI updates, printed output
/// kept in pieces, and MCP results in At once mode.
struct OutputDeliveryTests {
    static let runId = UUID()

    static func events(_ kinds: [RunEvent.Kind]) -> [RunEvent] {
        kinds.enumerated().map { RunEvent(runId: runId, sequence: $0.offset + 1, kind: $0.element) }
    }

    static func value(_ scalar: String) -> ValueNode {
        ValueNode(id: 1, type: .int, scalar: scalar)
    }

    static func dump(_ scalar: String, origin: String = "dump", line: Int = 2) -> RunEvent.Kind {
        .dump(DumpInfo(index: 0, origin: origin, value: value(scalar), inSnippet: true, snippetLine: line))
    }

    static func finished(_ status: RunStatus, _ reason: String) -> RunEvent.Kind {
        .finished(FinishedInfo(status: status, reason: reason, elapsedMs: 10))
    }

    /// Everything a run shows: status, printed output, dumps, inspector records, magic-comment
    /// values, an error, a notice, and how it ended.
    static func run(ending end: RunEvent.Kind) -> [RunEvent] {
        events([
            .started(StartedInfo(pid: 42, phpVersion: "8.4.1")),
            .log(RunLogEntry(source: "runner", message: "booting")),
            .bootstrapped(BootstrappedInfo(framework: "laravel")),
            .remember(key: "driver", value: "laravel"),
            .stdout(Data("one\n".utf8)),
            dump("1"),
            .inspector(.record(InspectorRecord(index: 1, section: "Logs", content: .value(value("7"))))),
            .inline(.probes(InlineProbesInfo(probes: [InlineProbe(id: 1, line: 3, kind: "value", comment: "//?")], rejected: []))),
            .inline(.hit(InlineHit(probe: 1, line: 3, kind: "value", hit: 1, value: value("10")))),
            .stderr(Data("warning\n".utf8)),
            .notice("note"),
            .error(RunErrorInfo(stage: .execute, className: "RuntimeException", message: "Boom")),
            .result(ResultInfo(hasValue: true, value: value("42"))),
            end,
        ])
    }

    static func released(_ events: [RunEvent], _ delivery: OutputDelivery) -> (live: [[RunEvent]], all: [RunEvent]) {
        var gate = RunEventGate(delivery: delivery)
        let live = events.map { gate.receive($0) }
        return (live, live.flatMap { $0 })
    }

    // MARK: Holding and replaying

    @Test func realtimePassesEveryEventAsItArrives() {
        let run = Self.run(ending: Self.finished(.completed, "completed"))
        let (live, all) = Self.released(run, .realtime)
        #expect(live.allSatisfy { $0.count == 1 })
        #expect(all == run)
    }

    @Test(arguments: [
        (RunStatus.completed, "completed"),
        (.failed, "error"),
        (.completed, "dd"),
        (.completed, "exit"),
        (.cancelled, "cancelled"),
        (.failed, "transport-closed"),
    ])
    func atOnceHoldsOutputUntilTheRunEndsHoweverItEnds(status: RunStatus, reason: String) {
        let run = Self.run(ending: Self.finished(status, reason))
        let (live, all) = Self.released(run, .atOnce)
        // Status and the Run Log pass at once; output, inspector records, and inline values wait.
        let passedEarly = live.dropLast().flatMap { $0 }.map(\.kind.typeName)
        #expect(passedEarly == ["started", "log", "bootstrapped", "remember"])
        // `finished` releases everything, in arrival order, then itself.
        #expect(live.last == run.filter { !RunEventGate.isStatus($0.kind) })
        #expect(Set(all.map(\.id)) == Set(run.map(\.id)), "nothing is lost")
    }

    @Test func aStoppedAtOnceRunShowsWhatArrivedBeforeTheStop() {
        let run = Self.events([.started(StartedInfo()), .stdout(Data("partial".utf8)), Self.dump("1"), Self.finished(.cancelled, "cancelled")])
        var gate = RunEventGate(delivery: .atOnce)
        #expect(gate.receive(run[0]) == [run[0]])
        #expect(gate.receive(run[1]).isEmpty && gate.receive(run[2]).isEmpty)
        #expect(gate.held.count == 2)
        #expect(gate.receive(run[3]) == Array(run[1...]))
        #expect(gate.held.isEmpty)
    }

    @Test func ddReleasesTheDumpsBeforeIt() {
        let run = Self.events([.started(StartedInfo()), Self.dump("1"), Self.dump("2", origin: "dd"), Self.finished(.completed, "dd")])
        let (live, _) = Self.released(run, .atOnce)
        #expect(live[1].isEmpty && live[2].isEmpty)
        #expect(live[3].map(\.kind) == [Self.dump("1"), Self.dump("2", origin: "dd"), Self.finished(.completed, "dd")])
    }

    @Test func clearOutputDropsWhatWasHeldAndTheEndOfEventsReleasesTheRest() {
        var gate = RunEventGate(delivery: .atOnce)
        let run = Self.events([.stdout(Data("a".utf8)), .stdout(Data("b".utf8)), .stdout(Data("c".utf8))])
        _ = gate.receive(run[0])
        gate.discardHeld()
        _ = gate.receive(run[1])
        _ = gate.receive(run[2])
        // A stream that ends without `finished` (the engine always sends one) still shows its output.
        #expect(gate.flush() == Array(run[1...]))
        #expect(gate.flush().isEmpty)
    }

    @Test func heldMagicCommentValuesAppearWhenTheRunEnds() {
        let run = Self.run(ending: Self.finished(.completed, "completed"))
        var gate = RunEventGate(delivery: .atOnce)
        var values = InlineValues()
        func apply(_ events: [RunEvent]) {
            for event in events { if case .inline(let inline) = event.kind { values.apply(inline, editorLine: { $0 }) } }
        }
        for event in run.dropLast() { apply(gate.receive(event)) }
        #expect(values.isEmpty)
        apply(gate.receive(run[run.count - 1]))
        #expect(values.summary(onLine: 3)?.plainText == "10")
    }

    // MARK: The setting

    @Test func settingDefaultsToRealtimeAndRoundTrips() throws {
        #expect(AppSettings().outputDelivery == .realtime)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(old.outputDelivery == .realtime, "older settings files decode with the default")
        var settings = AppSettings()
        settings.outputDelivery = .atOnce
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data).outputDelivery == .atOnce)
        #expect(!String(decoding: data, as: UTF8.self).contains("streamInlineValues"), "the old switch is no longer saved")
        let unknown = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"outputDelivery": "sometimes"}"#.utf8))
        #expect(unknown.outputDelivery == .realtime)
    }

    @Test func theMagicCommentsSwitchMigrates() throws {
        // #74's "Show values while the code runs": off becomes At once, on stays Realtime.
        let off = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"magicComments": true, "streamInlineValues": false}"#.utf8))
        #expect(off.outputDelivery == .atOnce && off.magicComments)
        let on = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"streamInlineValues": true}"#.utf8))
        #expect(on.outputDelivery == .realtime)
        // A saved Output choice wins over the old key.
        let both = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"streamInlineValues": false, "outputDelivery": "realtime"}"#.utf8))
        #expect(both.outputDelivery == .realtime)
    }

    // MARK: Batching and pacing

    static func stream(_ events: [RunEvent], gap: Duration? = nil) -> AsyncStream<RunEvent> {
        AsyncStream { continuation in
            Task {
                for event in events {
                    if let gap { try? await Task.sleep(for: gap) }
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    @Test func feedDeliversEveryEventInOrderThenEnds() async {
        let run = Self.events((1...500).map { .stdout(Data("\($0)\n".utf8)) } + [Self.finished(.completed, "completed")])
        let feed = RunEventFeed(Self.stream(run))
        var received: [RunEvent] = []
        var batches = 0
        while let batch = await feed.next(notBefore: .now + .milliseconds(20)) {
            received += batch.events
            batches += 1
        }
        #expect(received == run)
        #expect(batches < run.count, "events arrive together")
        #expect(await feed.next(notBefore: .now) == nil)
    }

    @Test func finishedNeverWaitsForTheDeadline() async throws {
        let run = Self.events([.stdout(Data("a".utf8)), Self.finished(.completed, "completed")])
        let feed = RunEventFeed(Self.stream(run))
        let start = ContinuousClock.now
        var received: [RunEvent] = []
        while let batch = await feed.next(notBefore: .now + .seconds(30)) { received += batch.events }
        #expect(received == run)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func aQuietRunsFirstEventGoesOutAtOnce() async throws {
        let (stream, continuation) = AsyncStream<RunEvent>.makeStream()
        let feed = RunEventFeed(stream)
        let run = Self.events([.stdout(Data("a".utf8)), .stdout(Data("b".utf8))])
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            continuation.yield(run[0])
        }
        // Waiting for the first event with a deadline already passed: it goes out as it comes.
        let first = try #require(await feed.next(notBefore: .now))
        #expect(first.events == [run[0]])
        // The next one waits for its deadline.
        continuation.yield(run[1])
        let deadline = ContinuousClock.now + .milliseconds(150)
        let second = try #require(await feed.next(notBefore: deadline))
        #expect(second.events == [run[1]])
        #expect(ContinuousClock.now >= deadline)
        continuation.finish()
        #expect(await feed.next(notBefore: .now) == nil)
    }

    @Test func pacerSlowsDownWhileTheUIIsBusyAndRecovers() {
        var pacer = OutputPacer()
        let start = ContinuousClock.now
        #expect(pacer.nextDeadline <= .now, "the first batch goes out at once")
        pacer.received(readyAt: start, at: start)
        pacer.applied(at: start)
        #expect(pacer.nextDeadline == start + OutputPacer.minimumInterval)
        // The next batch was ready at its deadline but reached the consumer 200 ms after the
        // last one was applied: the thread was busy drawing, so wait three times that.
        pacer.received(readyAt: start + .milliseconds(100), at: start + .milliseconds(200))
        #expect(pacer.interval == .milliseconds(600))
        pacer.applied(at: start + .milliseconds(210))
        #expect(pacer.nextDeadline == start + .milliseconds(810))
        // Very slow drawing is capped.
        pacer.received(readyAt: start + .milliseconds(810), at: start + .seconds(3))
        #expect(pacer.interval == OutputPacer.maximumInterval)
        // On time again: the wait shrinks back to the minimum.
        for _ in 0..<20 { pacer.received(readyAt: start, at: start) }
        #expect(pacer.interval == OutputPacer.minimumInterval)
    }

    // MARK: Printed output in pieces

    @Test func chunkedTextKeepsTheTextAndEndsPiecesAtLineBreaks() {
        var text = ChunkedText()
        var expected = ""
        for index in 0..<20_000 {
            let line = index % 7 == 0 ? "héllo wörld 👋🏽 \(index)" : "line \(index)\n"
            text.append(line)
            expected += line
        }
        #expect(text.string == expected)
        #expect(text.pieces.count > 1)
        for piece in text.pieces.dropLast() {
            #expect(piece.hasSuffix("\n"))
            #expect(piece.utf8.count <= ChunkedText.maxPieceLength)
        }
        #expect(text.pieceLineBreaks.reduce(0, +) == expected.utf8.count(where: { $0 == 0x0A }))
    }

    @Test func aVeryLongLineIsSplitBetweenCharacters() {
        let line = String(repeating: "ä€😀", count: 30_000)
        let text = ChunkedText(line)
        #expect(text.string == line)
        #expect(text.pieces.count > 1)
        #expect(text.pieces.allSatisfy { $0.utf8.count <= ChunkedText.maxPieceLength })
        #expect(!text.pieces.contains { $0.contains("\u{FFFD}") }, "no character is cut in half")
    }

    @Test func tailKeepsTheMostRecentLines() {
        let lines = (1...10_000).map { "line \($0)\n" }
        let text = ChunkedText(lines.joined())
        let (pieces, hidden) = text.tail(lines: 5_000)
        let shown = pieces.joined()
        #expect(shown.hasSuffix("line 10000\n"))
        #expect(hidden + shown.utf8.count(where: { $0 == 0x0A }) == 10_000)
        #expect(hidden > 0 && hidden <= 5_000)
        #expect(ChunkedText("a\nb\n").tail(lines: 100).hiddenLineBreaks == 0)
    }

    // MARK: MCP

    @Test func mcpGetsTheFullResultInAtOnceMode() {
        // As in AppModel: the tab's gate holds the output, while the MCP report gets every event.
        let run = Self.run(ending: Self.finished(.failed, "error"))
        func report(_ delivery: OutputDelivery) -> MCPRunReport {
            var gate = RunEventGate(delivery: delivery)
            var report = MCPRunReport(clientName: "c", tabTitle: "t", targetLabel: "Sandbox", startedAt: Date(timeIntervalSince1970: 0))
            for event in run.dropLast() {
                _ = gate.receive(event)
                report.apply(event.kind)
            }
            if delivery == .atOnce {
                #expect(gate.held.count == run.count - 5, "the tab still holds the output")
                #expect(!report.entries.isEmpty, "the report has it already")
            }
            _ = gate.receive(run[run.count - 1])
            report.apply(run[run.count - 1].kind)
            return report
        }
        let realtime = report(.realtime)
        let atOnce = report(.atOnce)
        #expect(atOnce.toolResult() == realtime.toolResult())
        #expect(atOnce.isFinished && atOnce.toolResult().text.contains("Result (int):\n42"))
        #expect(atOnce.toolResult().text.contains("one"))
    }
}
