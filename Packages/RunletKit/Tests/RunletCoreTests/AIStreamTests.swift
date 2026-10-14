import Foundation
import Testing
@testable import RunletCore

/// #368: server-sent events, both providers' streams and whole answers, and model lists, from
/// canned bytes shaped like the providers' documented examples.
struct AIStreamTests {
    // MARK: SSE

    @Test func eventsSurviveAnyChunking() {
        let text = "event: message_start\r\ndata: {\"a\":1}\r\n\r\n: a comment\nevent: x\ndata: first\ndata: second\nid: 7\nretry: 10\n\ndata:no-space\n\ndata: ü€\n\n"
        let bytes = Array(text.utf8)
        let expected = [SSEEvent(event: "message_start", data: "{\"a\":1}"), SSEEvent(event: "x", data: "first\nsecond"),
                        SSEEvent(data: "no-space"), SSEEvent(data: "ü€")]
        for size in [1, 2, 3, 5, 7, 64, bytes.count] {
            var decoder = SSEDecoder()
            var events: [SSEEvent] = []
            var index = 0
            while index < bytes.count {
                events += decoder.feed(Data(bytes[index..<min(index + size, bytes.count)]))
                index += size
            }
            events += decoder.finish()
            #expect(events == expected, "chunks of \(size)")
        }
    }

    @Test func aLastEventWithoutABlankLineIsKept() {
        var decoder = SSEDecoder()
        #expect(decoder.feed(Data("data: {\"type\":\"message_stop\"}".utf8)).isEmpty)
        #expect(decoder.finish() == [SSEEvent(data: "{\"type\":\"message_stop\"}")])
        #expect(decoder.finish().isEmpty)
    }

    static func decode(_ provider: AIProvider, _ events: [String]) throws -> [AIStreamEvent] {
        var decoder = AIStreamDecoder(provider: provider)
        var result: [AIStreamEvent] = []
        for data in events { result += try decoder.decode(SSEEvent(data: data)) }
        return result
    }

    // MARK: Anthropic

    static let anthropicStream = [
        #"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-opus-5-5","stop_reason":null,"usage":{"input_tokens":812,"output_tokens":1}}}"#,
        #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqQB"}}"#,
        #"{"type":"content_block_stop","index":0}"#,
        #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
        #"{"type":"ping"}"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"`$user` is "}}"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"null."}}"#,
        #"{"type":"content_block_stop","index":1}"#,
        #"{"type":"some_future_event","x":1}"#,
        #"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":215}}"#,
        #"{"type":"message_stop"}"#,
    ]

    @Test func anthropicStream() throws {
        let events = try Self.decode(.anthropic, Self.anthropicStream)
        #expect(events == [
            .started(model: "claude-opus-5-5"), .thinking, .text("`$user` is "), .text("null."),
            .finished(AIFinish(reason: .complete, model: "claude-opus-5-5", usage: AIUsage(inputTokens: 812, outputTokens: 215))),
        ])
    }

    @Test func anthropicStopReasons() throws {
        func finish(_ delta: String) throws -> AIStopReason? {
            let events = try Self.decode(.anthropic, [
                #"{"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":5}}}"#,
                #"{"type":"message_delta","delta":\#(delta),"usage":{"output_tokens":9}}"#,
                #"{"type":"message_stop"}"#,
            ])
            if case .finished(let finish) = events.last { return finish.reason }
            return nil
        }
        #expect(try finish(#"{"stop_reason":"max_tokens"}"#) == .maxTokens)
        #expect(try finish(#"{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber","explanation":"Declined."}}"#)
            == .refusal(category: "cyber", explanation: "Declined."))
        #expect(try finish(#"{"stop_reason":"refusal","stop_details":null}"#) == .refusal(category: nil, explanation: nil))
        #expect(try finish(#"{"stop_reason":"pause_turn"}"#) == .other("pause_turn"))
    }

    @Test func anthropicFallbackBlockNamesTheModelThatTookOver() throws {
        let events = try Self.decode(.anthropic, [
            #"{"type":"message_start","message":{"model":"claude-opus-4-8","usage":{"input_tokens":5}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"fallback","from":{"model":"claude-opus-5-5"},"to":{"model":"claude-opus-4-8"}}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":"Hi"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}"#,
            #"{"type":"message_stop"}"#,
        ])
        #expect(events.contains(.fallback(from: "claude-opus-5-5", to: "claude-opus-4-8")))
        #expect(events.contains(.text("Hi")))
    }

    @Test func anthropicErrorEventsThrow() {
        #expect(throws: AIError.overloaded(.anthropic, retryAfter: nil)) {
            try Self.decode(.anthropic, [#"{"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}}"#])
        }
        #expect(throws: AIError.rateLimited(.anthropic, retryAfter: nil)) {
            try Self.decode(.anthropic, [#"{"type": "error", "error": {"type": "rate_limit_error", "message": "Slow down"}}"#])
        }
        #expect(throws: AIError.server(.anthropic, status: nil, message: "Internal error")) {
            try Self.decode(.anthropic, [#"{"type": "error", "error": {"type": "api_error", "message": "Internal error"}}"#])
        }
        #expect(throws: AIError.invalidResponse(.anthropic, detail: "An event wasn't JSON.")) {
            try Self.decode(.anthropic, ["not json"])
        }
    }

    @Test func nothingIsDecodedAfterTheEnd() throws {
        var decoder = AIStreamDecoder(provider: .anthropic)
        for data in Self.anthropicStream { _ = try decoder.decode(SSEEvent(data: data)) }
        #expect(decoder.isFinished)
        #expect(try decoder.decode(SSEEvent(data: #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"late"}}"#)).isEmpty)
    }

    // MARK: OpenAI

    @Test func openAIStream() throws {
        let events = try Self.decode(.openai, [
            #"{"type":"response.created","sequence_number":0,"response":{"id":"resp_1","status":"in_progress","model":"gpt-6-astra"}}"#,
            #"{"type":"response.in_progress","sequence_number":1,"response":{"id":"resp_1"}}"#,
            #"{"type":"response.output_item.added","sequence_number":2,"output_index":0,"item":{"type":"reasoning","id":"rs_1"}}"#,
            #"{"type":"response.output_item.added","sequence_number":3,"output_index":1,"item":{"type":"message","id":"msg_1","role":"assistant"}}"#,
            #"{"type":"response.output_text.delta","sequence_number":4,"item_id":"msg_1","output_index":1,"content_index":0,"delta":"It's ","logprobs":[]}"#,
            #"{"type":"response.output_text.delta","sequence_number":5,"item_id":"msg_1","output_index":1,"content_index":0,"delta":"null.","logprobs":[]}"#,
            #"{"type":"response.output_text.done","sequence_number":6,"text":"It's null."}"#,
            #"{"type":"response.completed","sequence_number":7,"response":{"id":"resp_1","status":"completed","model":"gpt-6-astra-2026-09-01","usage":{"input_tokens":700,"output_tokens":120}}}"#,
        ])
        #expect(events == [
            .started(model: "gpt-6-astra"), .thinking, .text("It's "), .text("null."),
            .finished(AIFinish(reason: .complete, model: "gpt-6-astra-2026-09-01", usage: AIUsage(inputTokens: 700, outputTokens: 120))),
        ])
    }

    @Test func openAIEndings() throws {
        let start = #"{"type":"response.created","response":{"model":"gpt-6-astra"}}"#
        let refused = try Self.decode(.openai, [start,
            #"{"type":"response.refusal.delta","delta":"I can't help "}"#, #"{"type":"response.refusal.delta","delta":"with that."}"#,
            #"{"type":"response.completed","response":{"status":"completed"}}"#])
        #expect(refused.last == .finished(AIFinish(reason: .refusal(category: nil, explanation: "I can't help with that."), model: "gpt-6-astra", usage: AIUsage())))

        let cut = try Self.decode(.openai, [start, #"{"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}"#])
        if case .finished(let finish) = cut.last { #expect(finish.reason == .maxTokens) } else { Issue.record("no finish") }

        let filtered = try Self.decode(.openai, [start, #"{"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"content_filter"}}}"#])
        if case .finished(let finish) = filtered.last { #expect(finish.reason == .refusal(category: "content_filter", explanation: nil)) } else { Issue.record("no finish") }

        #expect(throws: AIError.rateLimited(.openai, retryAfter: nil)) {
            try Self.decode(.openai, [start, #"{"type":"response.failed","response":{"status":"failed","error":{"code":"rate_limit_exceeded","message":"Too many"}}}"#])
        }
        #expect(throws: AIError.refused(.openai, category: "bio_policy", explanation: "Blocked.")) {
            try Self.decode(.openai, [start, #"{"type":"response.failed","response":{"status":"failed","error":{"code":"bio_policy","message":"Blocked."}}}"#])
        }
        #expect(throws: AIError.server(.openai, status: nil, message: "Something broke")) {
            try Self.decode(.openai, [#"{"type":"error","code":"server_error","message":"Something broke","param":null,"sequence_number":1}"#])
        }
    }

    // MARK: Whole answers

    @Test func wholeAnswers() throws {
        let anthropic = try AIResponseParser.response(Data(#"""
        {"id":"msg_1","type":"message","model":"claude-opus-5-5","content":[{"type":"thinking","thinking":""},{"type":"text","text":"$x"},{"type":"text","text":"->name"}],
         "stop_reason":"end_turn","usage":{"input_tokens":30,"output_tokens":4}}
        """#.utf8), provider: .anthropic)
        #expect(anthropic == AIResponse(text: "$x->name", finish: AIFinish(reason: .complete, model: "claude-opus-5-5", usage: AIUsage(inputTokens: 30, outputTokens: 4))))

        let refusal = try AIResponseParser.response(Data(#"{"model":"claude-opus-5-5","content":[],"stop_reason":"refusal","stop_details":{"category":"bio","explanation":null}}"#.utf8), provider: .anthropic)
        #expect(refusal.finish.reason == .refusal(category: "bio", explanation: nil))

        let openai = try AIResponseParser.response(Data(#"""
        {"id":"resp_1","status":"completed","model":"gpt-6-luna","output":[{"type":"reasoning","summary":[]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"->name","annotations":[]}]}],
         "usage":{"input_tokens":10,"output_tokens":2}}
        """#.utf8), provider: .openai)
        #expect(openai == AIResponse(text: "->name", finish: AIFinish(reason: .complete, model: "gpt-6-luna", usage: AIUsage(inputTokens: 10, outputTokens: 2))))

        let incomplete = try AIResponseParser.response(Data(#"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}"#.utf8), provider: .openai)
        #expect(incomplete.finish.reason == .maxTokens)

        #expect(throws: AIError.invalidResponse(.openai, detail: "The answer wasn't JSON.")) {
            try AIResponseParser.response(Data("<html>".utf8), provider: .openai)
        }
    }

    // MARK: Model lists

    @Test func modelLists() throws {
        let anthropic = try AIResponseParser.models(Data(#"""
        {"data":[{"type":"model","id":"claude-opus-5-5","display_name":"Claude Opus 5.5","created_at":"2026-09-01T00:00:00Z"},
                 {"type":"model","id":"claude-haiku-5-5","display_name":"Claude Haiku 5.5","created_at":"2026-08-01T00:00:00Z"}],
         "has_more":false,"first_id":"claude-opus-5-5","last_id":"claude-haiku-5-5"}
        """#.utf8), provider: .anthropic)
        #expect(anthropic == [AIModelInfo(id: "claude-opus-5-5", displayName: "Claude Opus 5.5"), AIModelInfo(id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5")])

        let openai = try AIResponseParser.models(Data(#"""
        {"object":"list","data":[
          {"id":"gpt-6-luna","object":"model","created":1790000000,"owned_by":"system"},
          {"id":"gpt-6-astra","object":"model","created":1795000000,"owned_by":"system"},
          {"id":"text-embedding-3-large","object":"model","created":1705000000,"owned_by":"system"},
          {"id":"gpt-realtime","object":"model","created":1796000000,"owned_by":"system"},
          {"id":"gpt-image-2","object":"model","created":1796000000,"owned_by":"system"},
          {"id":"o4-mini","object":"model","created":1745000000,"owned_by":"system"},
          {"id":"omni-moderation-latest","object":"model","created":1731000000,"owned_by":"system"},
          {"id":"whisper-1","object":"model","created":1677000000,"owned_by":"openai-internal"}]}
        """#.utf8), provider: .openai)
        #expect(openai.map(\.id) == ["gpt-6-astra", "gpt-6-luna", "o4-mini"])
        #expect(openai.first?.displayName == "gpt-6-astra")

        #expect(throws: AIError.invalidResponse(.anthropic, detail: "The model list wasn't JSON.")) {
            try AIResponseParser.models(Data("{}".utf8), provider: .anthropic)
        }
    }
}
