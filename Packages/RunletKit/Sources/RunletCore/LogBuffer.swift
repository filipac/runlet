import Foundation

/// The entries the log viewer keeps (#20): bytes in, entries out, with bounded memory.
///
/// Text arrives in chunks (a tail read, then whatever a follow reads). Complete lines are
/// grouped into entries: a header line (Monolog, JSON, PHP's error log) starts one; a stack
/// trace, Laravel's multi-line context, and indented lines join the entry before them. A line
/// without its newline waits for the next chunk (or `flush`).
///
/// Memory is bounded three ways: at most `capacity` entries (the oldest go first, counted in
/// `dropped`), `maxLinesPerEntry` lines and `maxEntryBytes` bytes per entry (the rest counted
/// in the entry's `omittedLines`), and `maxLineBytes` per line. Nothing is ever written back
/// to the log; `clear()` only empties the view.
public struct LogBuffer: Sendable, Equatable {
    public static let defaultCapacity = 5_000
    public static let maxLinesPerEntry = 2_000
    public static let maxEntryBytes = 256 * 1024
    public static let maxLineBytes = 32 * 1024
    /// All entries together; past it the oldest go, like past `capacity`.
    public static let maxTotalBytes = 48 * 1024 * 1024

    public let capacity: Int
    /// Times written without a zone are read in this one.
    public var timeZone: TimeZone
    public private(set) var entries: [LogEntry] = []
    /// Entries removed to stay within the bounds since the last `clear()` or `reset`.
    public private(set) var dropped = 0
    /// Where the next byte sits in the source (a local file), when the source has positions.
    public private(set) var position: UInt64?

    private var nextId = 1
    private var pending: [UInt8] = []
    private var pendingStart: UInt64?
    /// The last entry may still get lines (false after `clear()` and at a new source).
    private var lastIsOpen = false
    /// The last entry got lines since it was last split into message and context.
    private var lastNeedsSplit = false
    private var storedBytes = 0
    private var entryBytes: [Int: Int] = [:]

    public init(capacity: Int = LogBuffer.defaultCapacity, timeZone: TimeZone = .current) {
        self.capacity = max(1, capacity)
        self.timeZone = timeZone
    }

    /// The text that follows comes from `offset` of a (new) source: a waiting partial line is
    /// kept as a line first, and nothing after joins the entries before.
    public mutating func begin(at offset: UInt64?) {
        flush(receivedAt: nil)
        closeLast()
        position = offset
    }

    /// Adds a chunk. `receivedAt` marks entries a follow read (nil for a first read).
    public mutating func append(_ data: Data, receivedAt: Date? = nil) {
        guard !data.isEmpty else { return }
        if pending.isEmpty { pendingStart = position }
        var lineStart = data.startIndex
        while let newline = data[lineStart...].firstIndex(of: 0x0A) {
            if pending.isEmpty {
                take(data[lineStart..<newline], start: position, receivedAt: receivedAt)
            } else {
                appendPending(data[lineStart..<newline])
                let bytes = pending
                pending.removeAll(keepingCapacity: true)
                take(bytes[...], start: pendingStart, receivedAt: receivedAt)
            }
            position = position.map { $0 + UInt64(data.distance(from: lineStart, to: newline) + 1) }
            lineStart = data.index(after: newline)
            pendingStart = position
        }
        if lineStart < data.endIndex {
            if pending.isEmpty { pendingStart = position }
            appendPending(data[lineStart..<data.endIndex])
            position = position.map { $0 + UInt64(data.distance(from: lineStart, to: data.endIndex)) }
        }
        finishBatch()
    }

    public mutating func append(_ text: String, receivedAt: Date? = nil) {
        append(Data(text.utf8), receivedAt: receivedAt)
    }

    /// Keeps a waiting partial line (the end of a file without a final newline) as a line.
    public mutating func flush(receivedAt: Date? = nil) {
        guard !pending.isEmpty else { return }
        let bytes = pending
        pending.removeAll()
        take(bytes[...], start: pendingStart, receivedAt: receivedAt)
        finishBatch()
    }

    /// Clear: empties the view. The log itself is never touched.
    public mutating func clear() {
        entries.removeAll()
        entryBytes.removeAll()
        storedBytes = 0
        dropped = 0
        closeLast()
    }

    /// A line waits for its newline.
    public var hasPartialLine: Bool { !pending.isEmpty }

    // MARK: Lines

    private mutating func appendPending(_ bytes: Data.SubSequence) {
        let room = Self.maxLineBytes - pending.count
        guard room > 0 else { return }
        pending.append(contentsOf: bytes.prefix(room))
    }

    private mutating func take<C: Collection>(_ bytes: C, start: UInt64?, receivedAt: Date?) where C.Element == UInt8 {
        var slice = Array(bytes.prefix(Self.maxLineBytes))
        let cut = bytes.count > Self.maxLineBytes
        if slice.last == 0x0D { slice.removeLast() }
        var line = String(decoding: slice, as: UTF8.self)
        if cut { line += " …" }
        receive(line, start: start, receivedAt: receivedAt)
    }

    private mutating func receive(_ line: String, start: UInt64?, receivedAt: Date?) {
        switch LogLineParser.classify(line, timeZone: timeZone) {
        case .header(var entry):
            closeLast()
            entry.offset = start
            entry.receivedAt = receivedAt
            add(entry)
        case .continuation:
            if lastIsOpen, !entries.isEmpty {
                extendLast(line)
            } else {
                addPlain(line, start: start, receivedAt: receivedAt)
            }
        case .plain:
            if lastIsOpen, let last = entries.last, last.format == .monolog || last.format == .phpError {
                extendLast(line)
            } else {
                addPlain(line, start: start, receivedAt: receivedAt)
            }
        }
    }

    private mutating func addPlain(_ line: String, start: UInt64?, receivedAt: Date?) {
        closeLast()
        var entry = LogLineParser.plain(line)
        entry.offset = start
        entry.receivedAt = receivedAt
        add(entry)
    }

    private mutating func add(_ entry: LogEntry) {
        var entry = entry
        entry.id = nextId
        nextId += 1
        let bytes = entry.header.utf8.count
        entries.append(entry)
        entryBytes[entry.id] = bytes
        storedBytes += bytes
        lastIsOpen = true
        lastNeedsSplit = false
    }

    private mutating func extendLast(_ line: String) {
        let index = entries.count - 1
        let id = entries[index].id
        let size = entryBytes[id] ?? 0
        let bytes = line.utf8.count + 1
        if entries[index].lines.count >= Self.maxLinesPerEntry || size + bytes > Self.maxEntryBytes {
            entries[index].omittedLines += 1
            return
        }
        entries[index].lines.append(line)
        entryBytes[id] = size + bytes
        storedBytes += bytes
        if entries[index].format == .monolog { lastNeedsSplit = true }
        if entries[index].format == .plain, entries[index].lines.count == 1 {
            // A plain line with a trace after it keeps its first line as the message.
            entries[index].message = entries[index].header
        }
    }

    /// The last entry gets no more lines: its message and context are final.
    private mutating func closeLast() {
        splitLastIfNeeded()
        lastIsOpen = false
    }

    private mutating func splitLastIfNeeded() {
        guard lastNeedsSplit, !entries.isEmpty else { return }
        LogMonologParts.split(&entries[entries.count - 1])
        lastNeedsSplit = false
    }

    private mutating func finishBatch() {
        // The open entry shows its context split as far as it has arrived.
        splitLastIfNeeded()
        var excess = max(0, entries.count - capacity)
        if storedBytes > Self.maxTotalBytes {
            var freed = 0
            var count = excess
            while count < entries.count - 1, storedBytes - freed > Self.maxTotalBytes {
                freed += entryBytes[entries[count].id] ?? 0
                count += 1
            }
            excess = max(excess, count)
        }
        guard excess > 0 else { return }
        for entry in entries.prefix(excess) {
            storedBytes -= entryBytes.removeValue(forKey: entry.id) ?? 0
        }
        entries.removeFirst(excess)
        dropped += excess
    }
}

/// What the log viewer shows (#20): a minimum level, a search, and "Logs written by the last
/// run". Pure.
public struct LogFilter: Sendable, Equatable {
    /// nil shows every entry, also lines without a level; a level shows that level and above.
    public var minimumLevel: LogLevel?
    /// Words that must all appear in the entry (any case).
    public var search: String
    /// "Written by the last run": entries in the run's part of the file, or read (or
    /// timestamped) between its start and end.
    public var run: LogRunWindow?

    public init(minimumLevel: LogLevel? = nil, search: String = "", run: LogRunWindow? = nil) {
        self.minimumLevel = minimumLevel
        self.search = search
        self.run = run
    }

    public var isActive: Bool { minimumLevel != nil || !search.trimmingCharacters(in: .whitespaces).isEmpty || run != nil }

    public func matches(_ entry: LogEntry) -> Bool {
        if let minimumLevel {
            guard let level = entry.level, level >= minimumLevel else { return false }
        }
        if let run, !run.contains(entry) { return false }
        let terms = search.lowercased().split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return true }
        // The header first: most searches end there, without joining the trace.
        let header = entry.header.lowercased()
        if terms.allSatisfy({ header.contains($0) }) { return true }
        let text = entry.text.lowercased()
        return terms.allSatisfy { text.contains($0) }
    }

    public func apply(_ entries: [LogEntry]) -> [LogEntry] {
        isActive ? entries.filter(matches) : entries
    }
}

/// When a run happened, and where the log ended at its start and end (#20), for "Logs written
/// by the last run".
public struct LogRunWindow: Sendable, Equatable {
    public var startedAt: Date
    public var endedAt: Date?
    /// The log file's size when the run started and ended (local files only).
    public var startOffset: UInt64?
    public var endOffset: UInt64?
    /// How much later than the end a line may arrive and still count (writes are buffered,
    /// a follow reads a moment later).
    public var slack: TimeInterval

    public init(startedAt: Date, endedAt: Date?, startOffset: UInt64? = nil, endOffset: UInt64? = nil, slack: TimeInterval = 2) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.slack = slack
    }

    /// The bytes the run added to the file, when both sizes are known and the file grew.
    public var byteRange: Range<UInt64>? {
        guard let startOffset, let endOffset, endOffset >= startOffset else { return nil }
        return startOffset..<endOffset
    }

    public func contains(_ entry: LogEntry) -> Bool {
        if let range = byteRange, let offset = entry.offset { return range.contains(offset) }
        let end = (endedAt ?? Date.distantFuture).addingTimeInterval(slack)
        if let received = entry.receivedAt { return received >= startedAt.addingTimeInterval(-slack) && received <= end }
        guard let timestamp = entry.timestamp else { return false }
        // Log times are often whole seconds: a second's leeway before the start.
        return timestamp >= startedAt.addingTimeInterval(-1) && timestamp <= end
    }
}
