import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// #9: preserve runner timings through every terminal path, without inventing absent phases.
struct RunTimingTests {
    func frame(_ type: String, _ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["type": type, "payload": payload])
        return "\u{1e}RL1:timing:\(data.count):" + String(decoding: data, as: UTF8.self) + "\n"
    }

    func pump(_ session: RunSession, stream: String) async throws -> [RunEvent] {
        let process = try SupervisedProcess.launch(ProcessSpec(executable: "/usr/bin/printf", arguments: ["%s", stream]))
        await session.pump(process, nonce: "timing")
        var events: [RunEvent] = []
        for await event in session.events { events.append(event) }
        #expect(events.filter { if case .finished = $0.kind { true } else { false } }.count == 1)
        return events
    }

    @Test(arguments: [false, true]) func receivedTimingsSurviveCompletionAndCancellation(cancel: Bool) async throws {
        let before = Date()
        let session = RunSession(runId: UUID(), limits: RunLimits())
        if cancel { session.control.markCancelRequested() }
        let stream = try frame("started", [:]) + frame("bootstrapped", ["bootstrapMs": 0])
            + frame("runnerFinished", ["reason": "completed", "executeMs": 123, "peakMemory": 4096])
        let events = try await pump(session, stream: stream)
        let info = try #require(events.finished)
        #expect(info.status == (cancel ? .cancelled : .completed))
        #expect(info.bootstrapMs == 0) // A measured zero is different from missing.
        #expect(info.executeMs == 123)
        #expect(info.peakMemory == 4096)
        let start = try #require(info.startedAt)
        #expect(start >= before && start <= Date())
        #expect(info.elapsedMs >= 0)
    }

    @Test(arguments: [false, true]) func partialTransportKeepsBootstrapAndUnknownExecute(cancel: Bool) async throws {
        let session = RunSession(runId: UUID(), limits: RunLimits())
        if cancel { session.control.markCancelRequested() }
        let events = try await pump(session, stream: frame("started", [:]) + frame("bootstrapped", ["bootstrapMs": 45]))
        #expect(events.finished?.status == (cancel ? .cancelled : .failed))
        #expect(events.finished?.bootstrapMs == 45)
        #expect(events.finished?.executeMs == nil)
        #expect(events.finished?.startedAt != nil)
    }

    @Test func missingAndLegacyFramesHaveNoInventedTimings() async throws {
        let session = RunSession(runId: UUID(), limits: RunLimits())
        let events = try await pump(session, stream: frame("started", [:]) + frame("runnerFinished", ["reason": "completed"]))
        #expect(events.finished?.bootstrapMs == nil)
        #expect(events.finished?.executeMs == nil)
        #expect(events.finished?.startedAt != nil)
    }

    @Test(arguments: [false, true]) func beforeLaunchHasStartButNoRunnerPhases(cancel: Bool) async throws {
        let session = RunSession(runId: UUID(), limits: RunLimits())
        if cancel { session.cancelBeforeLaunch() } else { session.failLaunch("test launch failure") }
        var events: [RunEvent] = []
        for await event in session.events { events.append(event) }
        #expect(events.finished?.startedAt != nil)
        #expect(events.finished?.bootstrapMs == nil)
        #expect(events.finished?.executeMs == nil)
        #expect(events.finished?.status == (cancel ? .cancelled : .failed))
    }
}
