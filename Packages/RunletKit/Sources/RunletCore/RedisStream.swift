import Foundation

/// Bounds shared by live Redis runs and their in-memory cards (#203). No preference or replay.
public struct RedisStreamLimits: Sendable, Equatable {
    /// Keep the newest 5,000 rows, within 8 MiB, including channel and client metadata.
    public var messages = 5_000
    public var bytes = 8 * 1_024 * 1_024
    /// Stop after ten minutes without a message, or thirty minutes overall.
    public var idleSeconds = 600
    public var totalSeconds = 1_800
    /// The app kills a runner still alive thirty seconds past the total limit.
    public var backstopSeconds = 30
    /// The runner forwards at most 1,000 messages each second, and 64 KiB per payload.
    public var messagesPerSecond = 1_000
    public var payloadBytes = 64 * 1_024
    public init() {
    }
}

/// Live Redis command kinds, preserving the runner wire names (#203).
public enum RedisStreamKind: String, Sendable, Equatable, Decodable {
    case subscribe = "SUBSCRIBE"
    case psubscribe = "PSUBSCRIBE"
    case ssubscribe = "SSUBSCRIBE"
    case monitor = "MONITOR"
}

/// Why a live run ended; values match the runner's protocol (#203).
public enum RedisStreamEndReason: String, Sendable, Equatable, Decodable {
    case idle
    case total
    case stopped
    case closed
    case error
}

/// The card's display status, separate from the reason a run ended (#203).
public enum RedisStreamStatus: String, Sendable, Equatable {
    case live = "LIVE"
    case paused = "PAUSED"
    case stopped = "STOPPED"
    case ended = "ENDED"
}

/// Opening metadata only (#203); confirmations contain no message payloads.
public struct RedisStreamInfo: Sendable, Equatable, Decodable {
    public var kind: RedisStreamKind
    public var command: String
    public var channels: [String]
    public var confirmations: [String]
    public var connection: String
    public var db: Int
    public var source: String
}

/// Memory-only stream row (#203). Base64 preserves binary bytes exactly within the payload cap.
/// Deliberately Decodable, never Encodable: output consumers must use the summary instead.
public struct RedisStreamMessage: Sendable, Equatable, Decodable, Identifiable {
    public var id: Int
    public var time: Double
    public var channel: String?
    public var pattern: String?
    public var db: Int?
    public var client: String?
    public var argv: [String]?
    public var payload: Data
    public var omitted: Int

    public init(id: Int, time: Double = 0, channel: String? = nil, pattern: String? = nil, db: Int? = nil, client: String? = nil, argv: [String]? = nil, payload: Data = Data(), omitted: Int = 0) {
        self.id = id
        self.time = time
        self.channel = channel
        self.pattern = pattern
        self.db = db
        self.client = client
        self.argv = argv
        self.payload = payload
        self.omitted = omitted
    }
    public var text: String {
        if let argv {
            return argv.map(RedisScript.quoted).joined(separator: " ")
        }
        return String(data: payload, encoding: .utf8) ?? payload.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
    public var byteCount: Int {
        payload.count + (channel?.utf8.count ?? 0) + (pattern?.utf8.count ?? 0)
            + (client?.utf8.count ?? 0) + (argv?.reduce(0) { $0 + $1.utf8.count } ?? 0)
    }
}

/// Batches and their cumulative counters (#203); skipped rows never enter the pipe.
public struct RedisStreamBatch: Sendable, Equatable, Decodable {
    public var messages: [RedisStreamMessage]
    public var received: Int
    public var skipped: Int
    /// Oversized, malformed, or unexpected replies; never rate-limit skips (#203).
    public var omitted: Int
    public var duration: Double
    public init(messages: [RedisStreamMessage], received: Int, skipped: Int = 0, omitted: Int = 0, duration: Double = 0) {
        self.messages = messages
        self.received = received
        self.skipped = skipped
        self.omitted = omitted
        self.duration = duration
    }
}

public struct RedisStreamEnd: Sendable, Equatable, Decodable {
    public var reason: RedisStreamEndReason
    public var received: Int
    public var skipped: Int
    /// Oversized, malformed, or unexpected replies; never rate-limit skips (#203).
    public var omitted: Int
    public var duration: Double
    public var message: String?
}

/// Bounded card state (#203). Pausing freezes a bounded visible snapshot, while the buffer
/// continues receiving. Frozen rows share the buffer’s payloads and expire when its bounds evict them; Clear keeps totals.
public struct RedisStreamBuffer: Sendable, Equatable {
    public let limits: RedisStreamLimits
    public private(set) var messages: [RedisStreamMessage] = []
    public private(set) var frozen: [RedisStreamMessage]?
    public private(set) var received = 0
    public private(set) var skipped = 0
    public private(set) var omitted = 0
    public private(set) var forwarded = 0
    public private(set) var dropped = 0
    public private(set) var pausedAt = 0
    public private(set) var duration: Double = 0
    public private(set) var end: RedisStreamEnd?
    public var isPaused: Bool {
        frozen != nil
    }
    public var visible: [RedisStreamMessage] {
        frozen ?? messages
    }
    public var newWhilePaused: Int {
        isPaused ? max(0, forwarded - pausedAt) : 0
    }
    public var isActive: Bool {
        end == nil
    }
    public var status: RedisStreamStatus {
        if let end {
            return end.reason == .stopped ? .stopped : .ended
        }
        return isPaused ? .paused : .live
    }
    public var summary: String {
        "\(received) messages · \(skipped) skipped by rate limit · \(omitted) omitted · \(String(format: "%.1f", duration)) s · \(end?.reason.rawValue ?? "live")"
    }
    public var droppedNote: String? {
        dropped > 0 ? "Kept the newest \(messages.count) messages; \(dropped) older ones were dropped." : nil
    }
    public init(limits: RedisStreamLimits = .init()) {
        self.limits = limits
    }

    public mutating func receive(_ batch: RedisStreamBatch) {
        guard isActive else { return }
        received = batch.received
        skipped = batch.skipped
        omitted = batch.omitted
        duration = batch.duration
        forwarded += batch.messages.count
        messages.append(contentsOf: batch.messages)
        trim()
    }
    private mutating func trim() {
        var bytes = messages.reduce(0) { $0 + $1.byteCount }
        var remove = 0
        while remove < messages.count && (messages.count - remove > max(1, limits.messages) || bytes > max(1, limits.bytes)) {
            bytes -= messages[remove].byteCount
            remove += 1
        }
        if remove > 0 {
            messages.removeFirst(remove)
            dropped += remove
            // Pausing never pins evicted payloads beyond the memory cap (#203).
            if let frozen {
                let retained = Set(messages.map(\.id))
                self.frozen = frozen.filter { retained.contains($0.id) }
            }
        }
    }
    public mutating func pause() {
        guard isActive, !isPaused else { return }
        frozen = messages
        pausedAt = forwarded
    }

    public mutating func resume() {
        frozen = nil
        trim()
    }

    public mutating func clear() {
        messages = []
        if isPaused {
            frozen = []
            pausedAt = forwarded
        }
        dropped = 0
    }

    public mutating func finish(_ info: RedisStreamEnd) {
        received = info.received
        skipped = info.skipped
        omitted = info.omitted
        duration = info.duration
        end = info
    }

    public mutating func stopped(reason: RedisStreamEndReason = .stopped) {
        guard isActive else { return }
        end = RedisStreamEnd(reason: reason, received: received, skipped: skipped, omitted: omitted, duration: duration)
    }

    /// The only stream content permitted in history or AI context (#203).
    public func historyText(command: String, connection: String) -> String {
        command + "\n# Live stream on " + connection + ": " + summary
    }
}
