import Foundation
import Testing
@testable import RunletCore

/// Live stream policy, privacy summaries, and bounded state (#203).
struct RedisStreamTests {
    @Test func classificationAndRefusals() {
        for name in RedisCommands.liveStreams {
            let argv = name == "MONITOR" ? [name] : [name, "events"]
            #expect(RedisCommands.refusal(argv) == nil)
            #expect(RedisCommands.readOnlyRefusal(argv) == nil)
            #expect(RedisCommands.classify(argv).allowedReadOnly)
            #expect(RedisCommands.classify(argv).dangerous == (name == "MONITOR"))
            #expect(RedisCommands.streamRefusal([argv], transaction: false) == nil)
            #expect(RedisCommands.streamRefusal([argv], transaction: true)?.contains("Run it alone with ⌘R") == true)
            #expect(RedisCommands.streamRefusal([["GET", "x"], argv], transaction: false) != nil)
            #expect(RedisCompletion.commands.first { $0.name == name }?.badges.contains("STREAMS") == true)
        }
        for argv in [["SUBSCRIBE"], ["PSUBSCRIBE"], ["SSUBSCRIBE"], ["MONITOR", "extra"], ["UNSUBSCRIBE"], ["PUNSUBSCRIBE"], ["SUNSUBSCRIBE"], ["SYNC"], ["PSYNC"], ["REPLCONF"], ["CLIENT", "REPLY", "ON"]] {
            #expect(RedisCommands.refusal(argv) != nil, "\(argv)")
        }
        #expect(RedisCommands.readOnlyRefusal(["PUBLISH", "events", "value"]) != nil)
        #expect(RedisCommands.dangerous["MONITOR"]?.contains("other values") == true)
    }

    @Test func streamCodeIsByteExact() throws {
        let command = try RedisScript.commandsToRunAll(in: #"SUBSCRIBE "a\x00\xff$\"""#, selection: NSRange()).get()[0]
        #expect(RedisTabRun.streamCode(command: command, connection: "queue") == """
        <?php
        // Runlet Redis live stream (#203).
        return \\RunletRunner\\RedisTab::stream(["SUBSCRIBE", "a\\x00\\xFF\\$\\\""], "queue", 600, 1800, 1000, 65536);
        """)
    }

    @Test func bufferBoundsPauseClearAndSummary() {
        var buffer = RedisStreamBuffer()
        let rows = (1...5002).map { RedisStreamMessage(id: $0, payload: Data("never persist this payload".utf8)) }
        buffer.receive(.init(messages: rows, received: 5002, skipped: 12, duration: 3))
        #expect(buffer.messages.count == 5000 && buffer.messages.first?.id == 3)
        #expect(buffer.dropped == 2 && buffer.droppedNote?.contains("2 older") == true)
        buffer.pause()
        buffer.receive(.init(messages: [.init(id: 5003, payload: Data("new".utf8))], received: 5003, skipped: 12, duration: 4))
        #expect(buffer.visible.last?.id == 5002 && buffer.messages.last?.id == 5003)
        #expect(buffer.newWhilePaused == 1)
        #expect(buffer.frozen?.first?.id == 4, "paused rows cannot pin evicted payloads")
        buffer.resume()
        #expect(buffer.visible.last?.id == 5003)
        let history = buffer.historyText(command: "SUBSCRIBE events", connection: "Cache")
        #expect(history.contains("5003 messages · 12 skipped") && !history.contains("never persist"))
        buffer.pause(); buffer.clear()
        #expect(buffer.visible.isEmpty && buffer.messages.isEmpty && buffer.received == 5003)
        buffer.stopped()
        #expect(buffer.status == "STOPPED")
        var endedPaused = RedisStreamBuffer()
        endedPaused.receive(.init(messages: [.init(id: 1)], received: 1))
        endedPaused.pause()
        endedPaused.receive(.init(messages: [.init(id: 2)], received: 2))
        endedPaused.stopped()
        #expect(endedPaused.visible.map(\.id) == [1])
        endedPaused.resume()
        #expect(endedPaused.visible.map(\.id) == [1, 2], "Resume can inspect a stream that ended while paused")
        var limits = RedisStreamLimits(); limits.bytes = 5
        var bytes = RedisStreamBuffer(limits: limits)
        bytes.receive(.init(messages: [.init(id: 1, payload: Data([1, 2, 3])), .init(id: 2, payload: Data([4, 5, 6]))], received: 2))
        #expect(bytes.messages.map(\.id) == [2] && bytes.dropped == 1)
    }

    @Test func decodesFramesAndBypassesAtOnce() throws {
        let decoder = JSONDecoder()
        let opening = try decoder.decode(RedisStreamInfo.self, from: Data(#"{"kind":"SUBSCRIBE","command":"SUBSCRIBE a","channels":["a"],"confirmations":["a"],"connection":"Cache","db":0,"source":"saved"}"#.utf8))
        let batch = try decoder.decode(RedisStreamBatch.self, from: Data(#"{"messages":[{"id":1,"time":1.5,"channel":"a","payload":"AP8=","omitted":3}],"received":4,"skipped":3,"duration":2}"#.utf8))
        let end = try decoder.decode(RedisStreamEnd.self, from: Data(#"{"reason":"idle","received":4,"skipped":3,"duration":3,"message":null}"#.utf8))
        #expect(batch.messages[0].payload == Data([0, 255]))
        #expect(batch.messages[0].omitted == 3)
        var buffer = RedisStreamBuffer(); buffer.receive(batch); buffer.finish(end)
        #expect(buffer.status == "ENDED" && buffer.received == 4)
        for kind: RunEvent.Kind in [.redisStream(opening), .redisMessages(batch), .redisStreamEnd(end)] {
            #expect(RunEventGate.isStatus(kind))
        }
    }
}
