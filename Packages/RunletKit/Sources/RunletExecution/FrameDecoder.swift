import Foundation

/// Splits the runner's stdout into raw application output and machine frames.
///
/// Frame layout: `0x1E "RL1:" <nonce> ":" <decimal byte length> ":" <json> "\n"`.
/// The nonce is random per run, so application output (including binary data or text
/// that imitates a frame) can never be mistaken for a frame. Chunks may split a frame or
/// its marker anywhere; bytes that might begin a marker are held back until resolved.
public struct FrameDecoder: Sendable {
    public enum Item: Sendable, Equatable {
        case raw(Data)
        case frame(Data)
        /// A frame header was found but its length/body was malformed.
        case malformed(String)
    }

    private let marker: [UInt8]
    private var buffer: [UInt8] = []
    public private(set) var framesDecoded = 0

    public init(nonce: String) {
        marker = [0x1e] + Array("RL1:\(nonce):".utf8)
    }

    public mutating func feed(_ data: Data) -> [Item] {
        buffer.append(contentsOf: data)
        return drain(final: false)
    }

    /// Flushes anything left at EOF as raw output.
    public mutating func finish() -> [Item] {
        drain(final: true)
    }

    private mutating func drain(final: Bool) -> [Item] {
        var items: [Item] = []
        var cursor = 0
        while cursor < buffer.count {
            guard let markerStart = find(marker, in: buffer, from: cursor) else {
                // No complete marker: emit raw bytes except a possible partial marker at the end.
                let keep = final ? 0 : partialMarkerSuffixLength(from: cursor)
                let end = buffer.count - keep
                if end > cursor { items.append(.raw(Data(buffer[cursor..<end]))) }
                cursor = end
                break
            }
            if markerStart > cursor {
                items.append(.raw(Data(buffer[cursor..<markerStart])))
            }
            let lengthStart = markerStart + marker.count
            guard let colon = buffer[lengthStart...].firstIndex(of: UInt8(ascii: ":")) else {
                if final || buffer.count - lengthStart > 20 {
                    items.append(.malformed("frame header without length"))
                    cursor = buffer.count
                } else {
                    cursor = markerStart
                }
                break
            }
            guard colon - lengthStart <= 12,
                  let length = Int(String(decoding: buffer[lengthStart..<colon], as: UTF8.self)), length >= 0 else {
                items.append(.malformed("invalid frame length"))
                cursor = colon + 1
                continue
            }
            let bodyStart = colon + 1
            let bodyEnd = bodyStart + length
            guard bodyEnd < buffer.count else {
                if final {
                    items.append(.malformed("truncated frame (\(buffer.count - bodyStart) of \(length) bytes)"))
                    cursor = buffer.count
                } else {
                    cursor = markerStart
                }
                break
            }
            items.append(.frame(Data(buffer[bodyStart..<bodyEnd])))
            framesDecoded += 1
            // Skip the trailing newline written after each frame.
            cursor = buffer[bodyEnd] == UInt8(ascii: "\n") ? bodyEnd + 1 : bodyEnd
        }
        buffer.removeFirst(min(cursor, buffer.count))
        return items
    }

    private func partialMarkerSuffixLength(from start: Int) -> Int {
        let available = buffer.count - start
        var length = min(marker.count - 1, available)
        while length > 0 {
            if buffer[(buffer.count - length)...].elementsEqual(marker[0..<length]) { return length }
            length -= 1
        }
        return 0
    }

    private func find(_ needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard needle.count <= haystack.count - start else { return nil }
        let first = needle[0]
        var index = start
        let last = haystack.count - needle.count
        while index <= last {
            if haystack[index] == first {
                var match = true
                for offset in 1..<needle.count where haystack[index + offset] != needle[offset] {
                    match = false
                    break
                }
                if match { return index }
            }
            index += 1
        }
        return nil
    }
}

/// Splits a frame body `{"type": ..., "payload": {...}}` into its type and payload JSON.
func splitFrame(_ body: Data) throws -> (type: String, payload: Data) {
    guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
          let type = object["type"] as? String else {
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "frame without type"))
    }
    let payload = object["payload"] ?? [String: Any]()
    return (type, try JSONSerialization.data(withJSONObject: payload))
}
