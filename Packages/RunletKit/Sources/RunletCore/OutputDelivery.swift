import Foundation

// Output realtime or at once (#82): when a run's output reaches the tab, and how often the
// tab's views are updated while events pour in.

/// When a run's output appears (Settings ▸ General ▸ Output).
public enum OutputDelivery: String, Sendable, Codable, CaseIterable {
    /// As the code runs (the default).
    case realtime
    /// All at once when the run ends: completed, failed, `dd()`, `exit`, or stopped.
    case atOnce
}

/// Decides when each of a run's events reaches the tab: the output (printed text, dumps, the
/// result, errors, notices), the editor's magic-comment values, and the run inspector (queries,
/// mail, logs, benchmarks, profile). With `.realtime` everything passes as it arrives. With
/// `.atOnce` those events are held, in the app, and released together, in arrival order,
/// with the `finished` event, however the run ends: completed, failed, `dd()`, `exit`, stopped,
/// or a process or SSH connection that went away (the engine always ends a run with `finished`).
/// Status events (`started`, `bootstrapped`, the Run Log's `log`, `remember`) always pass at
/// once, so the status bar and the Run Log stay live.
public struct RunEventGate: Sendable, Equatable {
    public let delivery: OutputDelivery
    public private(set) var held: [RunEvent] = []

    public init(delivery: OutputDelivery) {
        self.delivery = delivery
    }

    /// Events that describe the run rather than its output: never held.
    public static func isStatus(_ kind: RunEvent.Kind) -> Bool {
        switch kind {
        case .started, .bootstrapped, .log, .remember: true
        default: false
        }
    }

    /// The events to apply now, in order.
    public mutating func receive(_ event: RunEvent) -> [RunEvent] {
        if case .finished = event.kind {
            defer { held = [] }
            return held + [event]
        }
        guard delivery == .atOnce, !Self.isStatus(event.kind) else { return [event] }
        held.append(event)
        return []
    }

    /// The run's events ended without `finished` (the engine guarantees one, so this is a
    /// backstop): everything held, in order.
    public mutating func flush() -> [RunEvent] {
        defer { held = [] }
        return held
    }

    /// Clear Output while the run goes on: what arrived so far is dropped, as in Realtime.
    public mutating func discardHeld() {
        held = []
    }
}

/// A run's events, taken in batches by the UI (#82). The consumer asks for the next batch "not
/// before" a deadline it chooses (`OutputPacer`): events gather until then, so a run that prints
/// thousands of lines or dumps updates the tab a few times a second instead of once per event.
/// `finished` and the end of the events never wait. Nothing is dropped or reordered; events are
/// read off the stream on their own task, so the run never waits for the UI.
public final class RunEventFeed: @unchecked Sendable {
    public struct Batch: Sendable {
        public var events: [RunEvent]
        /// When the batch was ready for the consumer: compared with when the consumer got it,
        /// this shows whether its thread was busy.
        public var readyAt: ContinuousClock.Instant
    }

    private let lock = NSLock()
    private var pending: [RunEvent] = []
    private var hasFinished = false
    private var closed = false
    private var waiter: CheckedContinuation<ContinuousClock.Instant, Never>?
    private var waiterDeadline: ContinuousClock.Instant?
    private var reader: Task<Void, Never>?

    public init(_ events: AsyncStream<RunEvent>) {
        reader = Task.detached { [weak self] in
            for await event in events { self?.add(event) }
            self?.close()
        }
    }

    deinit { reader?.cancel() }

    /// The next events, in order, once there is at least one and `deadline` has passed (at once
    /// for `finished` or when the events have ended); nil when every event was taken.
    public func next(notBefore deadline: ContinuousClock.Instant) async -> Batch? {
        var readyAt = ContinuousClock.now
        while true {
            if let batch = take(deadline, readyAt: readyAt) { return batch.events.isEmpty ? nil : batch }
            readyAt = await withCheckedContinuation { continuation in
                lock.lock()
                if isReady(deadline) {
                    lock.unlock()
                    continuation.resume(returning: ContinuousClock.now)
                    return
                }
                waiter = continuation
                waiterDeadline = deadline
                let waitsForDeadline = !pending.isEmpty
                lock.unlock()
                if waitsForDeadline { scheduleWake(at: deadline) }
            }
        }
    }

    /// Ready: the events ended, `finished` arrived, or events are pending and the deadline passed.
    private func isReady(_ deadline: ContinuousClock.Instant) -> Bool {
        closed || hasFinished || (!pending.isEmpty && ContinuousClock.now >= deadline)
    }

    /// Takes the pending events when ready (an empty batch: the events ended).
    private func take(_ deadline: ContinuousClock.Instant, readyAt: ContinuousClock.Instant) -> Batch? {
        lock.lock()
        defer { lock.unlock() }
        guard isReady(deadline) else { return nil }
        defer { pending = []; hasFinished = false }
        return Batch(events: pending, readyAt: readyAt)
    }

    private func add(_ event: RunEvent) {
        lock.lock()
        pending.append(event)
        if case .finished = event.kind { hasFinished = true }
        let deadline = waiterDeadline
        let wakeNow = waiter != nil && (hasFinished || deadline.map { ContinuousClock.now >= $0 } ?? true)
        let wakeLater = waiter != nil && !wakeNow && pending.count == 1
        lock.unlock()
        if wakeNow { wake() } else if wakeLater, let deadline { scheduleWake(at: deadline) }
    }

    private func close() {
        lock.lock()
        closed = true
        lock.unlock()
        wake()
    }

    private func scheduleWake(at deadline: ContinuousClock.Instant) {
        Task.detached { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            self?.wake()
        }
    }

    private func wake() {
        lock.lock()
        let continuation = waiter
        waiter = nil
        waiterDeadline = nil
        lock.unlock()
        continuation?.resume(returning: .now)
    }
}

/// Paces a tab's output updates (#82): at most every `minimumInterval`, and slower while the
/// UI is slow to lay out and draw what it got, so updates use about a third of the main thread
/// at most and typing and scrolling stay responsive. When a batch reaches the consumer late,
/// its thread was busy (drawing the previous batch) since that batch was applied; the next
/// batch then waits three times that long. The wait shrinks back as the UI keeps up.
public struct OutputPacer: Sendable {
    public static let minimumInterval: Duration = .milliseconds(100)
    public static let maximumInterval: Duration = .seconds(1)
    /// Lateness below this is scheduling noise, not a busy thread.
    static let lateness: Duration = .milliseconds(4)

    public private(set) var interval: Duration = minimumInterval
    private var appliedAt: ContinuousClock.Instant?

    public init() {}

    /// When to take the next batch: right away at first, then `interval` after the last one
    /// was applied.
    public var nextDeadline: ContinuousClock.Instant {
        appliedAt.map { $0 + interval } ?? .now
    }

    /// A batch that was ready at `readyAt` reached the consumer at `receivedAt`.
    public mutating func received(readyAt: ContinuousClock.Instant, at receivedAt: ContinuousClock.Instant = .now) {
        if let appliedAt, receivedAt - readyAt > Self.lateness {
            interval = min(Self.maximumInterval, max(Self.minimumInterval, (receivedAt - appliedAt) * 3))
        } else {
            interval = max(Self.minimumInterval, interval * 0.75)
        }
    }

    /// The batch was applied.
    public mutating func applied(at time: ContinuousClock.Instant = .now) {
        appliedAt = time
    }
}
