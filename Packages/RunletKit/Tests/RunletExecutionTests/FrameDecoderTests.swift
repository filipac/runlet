import Foundation
import Testing
@testable import RunletExecution

struct FrameDecoderTests {
    let nonce = "0123456789abcdef0123456789abcdef"

    func frame(_ json: String) -> Data {
        Data("\u{1e}RL1:\(nonce):\(json.utf8.count):\(json)\n".utf8)
    }

    func collect(_ chunks: [Data]) -> (raw: Data, frames: [String], malformed: Int) {
        var decoder = FrameDecoder(nonce: nonce)
        var items: [FrameDecoder.Item] = []
        for chunk in chunks { items += decoder.feed(chunk) }
        items += decoder.finish()
        var raw = Data()
        var frames: [String] = []
        var malformed = 0
        for item in items {
            switch item {
            case .raw(let data): raw.append(data)
            case .frame(let data): frames.append(String(decoding: data, as: UTF8.self))
            case .malformed: malformed += 1
            }
        }
        return (raw, frames, malformed)
    }

    @Test func separatesRawOutputAndFrames() {
        var stream = Data("hello ".utf8)
        stream.append(frame(#"{"type":"a"}"#))
        stream.append(Data("world".utf8))
        stream.append(frame(#"{"type":"b"}"#))
        let result = collect([stream])
        #expect(String(decoding: result.raw, as: UTF8.self) == "hello world")
        #expect(result.frames == [#"{"type":"a"}"#, #"{"type":"b"}"#])
    }

    @Test func handlesEverySplitPoint() {
        var stream = Data("abc\u{1e}RL1".utf8)
        stream.append(frame(#"{"type":"x","payload":{"s":"ünïcödé"}}"#))
        stream.append(Data([0xff, 0xfe, 0x00]))
        stream.append(frame(#"{"type":"y"}"#))
        let expected = collect([stream])
        for split in 1..<stream.count {
            let result = collect([stream.prefix(split), stream.suffix(from: split)])
            #expect(result.raw == expected.raw, "split at \(split)")
            #expect(result.frames == expected.frames, "split at \(split)")
        }
        // Byte-by-byte delivery.
        let bytewise = collect(stream.map { Data([$0]) })
        #expect(bytewise.frames == expected.frames)
        #expect(bytewise.raw == expected.raw)
    }

    @Test func forgedFramesWithOtherNoncesStayRaw() {
        let forged = Data("\u{1e}RL1:deadbeef:5:{\"a\"}\n".utf8)
        let result = collect([forged])
        #expect(result.frames.isEmpty)
        #expect(result.raw == forged)
    }

    @Test func binaryOutputIsPreserved() {
        let binary = Data((0...255).map { UInt8($0) } + [0x1e, 0x1e, 0x52])
        var stream = binary
        stream.append(frame("{}"))
        stream.append(binary)
        let result = collect([stream])
        #expect(result.raw == binary + binary)
        #expect(result.frames == ["{}"])
    }

    @Test func truncatedFrameAtEOFIsReported() {
        let full = frame(#"{"type":"a"}"#)
        let result = collect([full.prefix(full.count - 4)])
        #expect(result.frames.isEmpty)
        #expect(result.malformed == 1)
    }
}
