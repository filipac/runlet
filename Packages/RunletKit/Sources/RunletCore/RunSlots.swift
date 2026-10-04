import Foundation

/// The execution engine's run slots at one moment (#183). The engine runs at most `limit` runner
/// processes at once; each holds a slot while it runs, and further runs wait in a queue, in the
/// order they get a slot. A queued run has started nothing yet: no PHP process, no database
/// connection, no use of an SSH connection. The engine publishes a new value whenever a run joins
/// the queue, gets a slot, or ends (`ExecutionEngine.slotChanges`), so nothing polls.
public struct RunSlots: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var runId: UUID
        /// The tab that asked for it; loaders that run outside a tab use the run's own id.
        public var tabId: UUID
        /// When it got its slot (running), or when it joined the queue (queued).
        public var since: Date

        public init(runId: UUID, tabId: UUID, since: Date) {
            self.runId = runId
            self.tabId = tabId
            self.since = since
        }
    }

    /// Where one run is.
    public enum State: Sendable, Equatable {
        /// Holds a slot since `since`: its runner was started then.
        case running(since: Date)
        /// Waits for a slot since `since`. `position` 1 is the next run to get one.
        case queued(position: Int, since: Date)

        public var isQueued: Bool {
            if case .queued = self { true } else { false }
        }
    }

    /// At most this many runs hold a slot at once (`ExecutionEngine.maxConcurrentRuns`).
    public var limit: Int
    /// Runs holding a slot, oldest first.
    public var running: [Entry]
    /// Runs waiting for a slot, in the order they get one.
    public var queued: [Entry]

    public init(limit: Int, running: [Entry] = [], queued: [Entry] = []) {
        self.limit = limit
        self.running = running
        self.queued = queued
    }

    public static let none = RunSlots(limit: 0)

    /// Where `runId` is; nil when the engine doesn't hold or queue it (not admitted yet, ended,
    /// or a run that never takes a slot, such as Stop's cancel runner).
    public func state(of runId: UUID) -> State? {
        if let index = queued.firstIndex(where: { $0.runId == runId }) {
            return .queued(position: index + 1, since: queued[index].since)
        }
        if let entry = running.first(where: { $0.runId == runId }) {
            return .running(since: entry.since)
        }
        return nil
    }

    /// "Waiting for a free run slot: 4 runs are going, at most 4 at once; next to start." The
    /// queued run's Run Log line.
    public static func waitingText(running: Int, limit: Int, position: Int) -> String {
        "\(running) run\(running == 1 ? " is" : "s are") going, at most \(limit) at once; \(ConnectionText.queuePlace(position)). Nothing is opened until it starts."
    }
}
