import Foundation

/// Printed output that grows at the end, kept in pieces that end at a line break once they
/// hold `pieceLines` lines or `pieceLength` UTF-8 bytes (#82). A view shows a long stream
/// lazily, a piece at a time, and appending costs as much as the new text instead of copying
/// and laying out all of it again. A line longer than `maxPieceLength` is split between
/// Unicode scalars. Joined, the pieces are exactly the appended text.
public struct ChunkedText: Sendable, Equatable {
    public static let pieceLines = 64
    public static let pieceLength = 8 * 1024
    public static let maxPieceLength = 32 * 1024

    public private(set) var pieces: [String] = []
    /// Line breaks in each piece.
    public private(set) var pieceLineBreaks: [Int] = []
    /// UTF-8 bytes of the last piece.
    private var lastLength = 0
    private var lastLines: Int { pieceLineBreaks.last ?? 0 }

    public init(_ text: String = "") {
        append(text)
    }

    public var string: String { pieces.joined() }
    public var isEmpty: Bool { pieces.isEmpty }

    public mutating func append(_ text: String) {
        var text = text
        text.withUTF8 { bytes in
            guard let base = bytes.baseAddress else { return }
            var start = 0
            while start < bytes.count {
                if pieces.isEmpty || isFull {
                    pieces.append("")
                    pieceLineBreaks.append(0)
                    lastLength = 0
                }
                // Where this piece reaches its hard limit, as an index into `bytes`.
                let hardEnd = start + (Self.maxPieceLength - lastLength)
                var end = start
                var lines = 0
                var cut = bytes.count
                while end < bytes.count {
                    guard let found = memchr(base + end, 0x0A, bytes.count - end) else {
                        if bytes.count > hardEnd { cut = Self.scalarBoundary(in: bytes, before: hardEnd, after: start) }
                        break
                    }
                    let newline = UnsafeRawPointer(found).assumingMemoryBound(to: UInt8.self) - base
                    if newline >= hardEnd {
                        cut = Self.scalarBoundary(in: bytes, before: hardEnd, after: start)
                        break
                    }
                    end = newline + 1
                    lines += 1
                    if lastLength + (end - start) >= Self.pieceLength || lastLines + lines >= Self.pieceLines {
                        cut = end
                        break
                    }
                }
                let part = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<cut]), as: UTF8.self)
                pieces[pieces.count - 1] += part
                lastLength += cut - start
                pieceLineBreaks[pieceLineBreaks.count - 1] += lines
                start = cut
            }
        }
    }

    /// The last pieces, holding at least `lines` line breaks (every piece when there are fewer),
    /// and how many line breaks the pieces before them hold.
    public func tail(lines: Int) -> (pieces: ArraySlice<String>, hiddenLineBreaks: Int) {
        var shown = 0
        var first = pieces.count
        while first > 0, shown < lines {
            first -= 1
            shown += pieceLineBreaks[first]
        }
        return (pieces[first...], pieceLineBreaks[..<first].reduce(0, +))
    }

    private var isFull: Bool {
        // Full, or too full for another character (up to 4 bytes).
        lastLength > Self.maxPieceLength - 4
            || ((lastLength >= Self.pieceLength || lastLines >= Self.pieceLines) && pieces.last?.utf8.last == 0x0A)
    }

    /// The last Unicode scalar boundary at or before `index` and after `start`; when no whole
    /// scalar fits, the first boundary after `start`.
    private static func scalarBoundary(in bytes: UnsafeBufferPointer<UInt8>, before index: Int, after start: Int) -> Int {
        func isBoundary(_ position: Int) -> Bool { position >= bytes.count || bytes[position] & 0xC0 != 0x80 }
        var cut = min(index, bytes.count)
        while cut > start, !isBoundary(cut) { cut -= 1 }
        if cut > start { return cut }
        cut = start + 1
        while !isBoundary(cut) { cut += 1 }
        return cut
    }
}
