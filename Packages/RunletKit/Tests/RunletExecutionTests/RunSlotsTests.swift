import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// The engine's run slots (#183): with every slot taken, a further run waits in the queue (the
/// engine says so as it happens, without polling), then runs once a slot is free; Stop on a
/// queued run takes it out of the queue at once, before anything starts.
@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct RunSlotsTests {
    var plain: TargetSnapshot { TestSupport.localTarget(TestSupport.fixtures.appendingPathComponent("plain").path, php: TestSupport.php()!) }

    private func request(_ code: String) -> RunRequest {
        RunRequest(tabId: UUID(), documentVersion: 1, target: plain, code: code)
    }

    private func collect(_ stream: AsyncStream<RunEvent>) async -> [RunEvent] {
        var events: [RunEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private func logs(_ events: [RunEvent]) -> [RunLogEntry] {
        events.compactMap { if case .log(let entry) = $0.kind, entry.source == "queue" { entry } else { nil } }
    }

    @Test func secondSleepWaitsForTheOnlySlotThenRuns() async throws {
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil, maxConcurrentRuns: 1)
        let first = request("usleep(400000); 'first'")
        let second = request("usleep(100000); 'second'")
        // The app's view: every change, as it happens.
        let changes = Task {
            var seen: [RunSlots] = []
            for await slots in engine.slotChanges { seen.append(slots) }
            return seen
        }
        let queuedAt = Date()
        let firstStream = try await engine.start(first)
        let secondStream = try await engine.start(second)

        // Accepted, but waiting: the first holds the only slot.
        let slots = await engine.slots
        #expect(slots.limit == 1)
        #expect(slots.running.map(\.runId) == [first.runId])
        #expect(slots.queued.map(\.runId) == [second.runId])
        guard case .queued(let position, let since)? = slots.state(of: second.runId) else {
            Issue.record("the second run isn't queued: \(String(describing: slots.state(of: second.runId)))")
            return
        }
        #expect(position == 1)
        #expect(since >= queuedAt.addingTimeInterval(-1))
        #expect(slots.state(of: first.runId)?.isQueued == false)

        async let firstEvents = collect(firstStream)
        async let secondEvents = collect(secondStream)
        let (one, two) = await (firstEvents, secondEvents)
        #expect(one.result?.value?.scalar == "first")
        #expect(two.result?.value?.scalar == "second")
        #expect(logs(one).isEmpty)
        // The queued run's Run Log says why it waited, and when it got its slot.
        #expect(logs(two).map(\.message) == ["Waiting for a free run slot", "Got a run slot after waiting 0 s"])
        #expect(logs(two).first?.detail?.contains("1 run is going, at most 1 at once; next to start") == true)
        // It started only after the first one ended.
        let firstEnd = try #require(one.finished?.startedAt).addingTimeInterval(Double(try #require(one.finished?.elapsedMs)) / 1000)
        #expect(two.started != nil)
        // Both slots are given back once the runs' tasks end; then the reader stops.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !(await engine.slots.running.isEmpty) { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(50))
        changes.cancel()
        let seen = await changes.value
        // Queued, then running once the first had left, then nothing.
        let runningSince = seen.compactMap { slots -> Date? in
            if case .running(let since)? = slots.state(of: second.runId) { return since } else { return nil }
        }.first
        let granted = try #require(runningSince)
        #expect(granted >= firstEnd.addingTimeInterval(-0.05))
        #expect(granted > since, "since restarts when it gets its slot")
        #expect(seen.contains { $0.state(of: second.runId)?.isQueued == true })
        #expect(seen.allSatisfy { $0.running.count <= 1 })
        #expect(seen.last?.running.isEmpty == true && seen.last?.queued.isEmpty == true)
    }

    @Test func stopOnAQueuedRunRemovesItBeforeItStarts() async throws {
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil, maxConcurrentRuns: 1)
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-queued-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: marker) }
        let first = request("sleep(20);")
        let queued = request("file_put_contents('\(marker)', 'ran'); 2")
        let firstStream = try await engine.start(first)
        let queuedStream = try await engine.start(queued)
        #expect(await engine.slots.state(of: queued.runId)?.isQueued == true)

        let clock = ContinuousClock()
        let stopped = clock.now
        let outcome = try #require(await engine.cancel(runId: queued.runId))
        #expect(outcome.confirmed)
        #expect(outcome.message == "Removed from the queue before it started; nothing was sent.")
        // Nothing was sent, so no server cancel was tried.
        #expect(outcome.server == nil)
        let events = await collect(queuedStream)
        // It ends at once, while the first still holds the slot.
        #expect(clock.now - stopped < .seconds(2))
        #expect(events.finished?.status == .cancelled)
        #expect(events.started == nil)
        #expect(!events.contains { if case .log(let entry) = $0.kind { entry.source == "launch" } else { false } })
        #expect(logs(events).map(\.message) == ["Waiting for a free run slot", "Removed from the queue before it started; nothing was sent."])
        let slots = await engine.slots
        #expect(slots.queued.isEmpty)
        #expect(slots.running.map(\.runId) == [first.runId])

        _ = await engine.cancel(runId: first.runId)
        let firstEvents = await collect(firstStream)
        #expect(firstEvents.finished?.status == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: marker), "the queued run never ran")
    }

    @Test func queuePositionsMoveUpAsRunsLeave() async throws {
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil, maxConcurrentRuns: 1)
        let first = request("sleep(20);")
        let second = request("1")
        let third = request("2")
        let streams = [try await engine.start(first), try await engine.start(second), try await engine.start(third)]
        var slots = await engine.slots
        #expect(slots.state(of: second.runId).map { if case .queued(let position, _) = $0 { position } else { 0 } } == 1)
        #expect(slots.state(of: third.runId).map { if case .queued(let position, _) = $0 { position } else { 0 } } == 2)
        _ = await engine.cancel(runId: second.runId)
        slots = await engine.slots
        #expect(slots.state(of: second.runId) == nil)
        #expect(slots.state(of: third.runId).map { if case .queued(let position, _) = $0 { position } else { 0 } } == 1)
        // Stopping everything (quit) ends the queued runs too, without starting them.
        await engine.cancelAll()
        for stream in streams { _ = await collect(stream) }
        slots = await engine.slots
        #expect(slots.queued.isEmpty)
    }
}
