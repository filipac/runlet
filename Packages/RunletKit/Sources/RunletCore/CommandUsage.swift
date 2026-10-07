import Foundation

// Commands you choose often, and recently, rank higher in the command palette and among Open
// Anything's commands (#328). The app records a use when a command is chosen in the palette and
// asks these rules for the order; it never ranks on its own.

/// How often and how recently each command was chosen in the palette, in
/// `State/command-usage.json`. Per user, and only command ids: no arguments, code, or targets.
///
/// Frecency is a decayed count of uses: each use adds 1, and the total halves every
/// `halfLife` (two weeks). Ten uses a month ago weigh about as much as two today, so a command
/// you stopped using drops back over a few weeks, and one you used once is forgotten after
/// about three months (`forgottenBelow`).
public struct CommandUsage: Sendable, Codable, Equatable {
    public struct Entry: Sendable, Codable, Equatable {
        /// Every use, for reference; the ranking reads `weight`.
        public var uses: Int
        public var lastUsed: Date
        /// The decayed count of uses as of `lastUsed`.
        public var weight: Double

        public init(uses: Int, lastUsed: Date, weight: Double) {
            self.uses = uses
            self.lastUsed = lastUsed
            self.weight = weight
        }
    }

    /// Two weeks: long enough that a command you use every few days stays up, short enough
    /// that last month's habits fade.
    public static let halfLife: TimeInterval = 14 * 24 * 60 * 60
    /// The most ids kept; the weakest go first.
    public static let capacity = 200
    /// An entry whose frecency decays below this is dropped: a single use after about 93 days.
    public static let forgottenBelow = 0.01

    /// By command id.
    public private(set) var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = (try? c.decode([String: Entry].self, forKey: .entries)) ?? [:]
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// The command's decayed count of uses at `now`; 0 for a command never chosen.
    public func frecency(of id: String, at now: Date) -> Double {
        guard let entry = entries[id] else { return 0 }
        // A clock set back never makes a use count for more.
        let age = max(0, now.timeIntervalSince(entry.lastUsed))
        return entry.weight * pow(0.5, age / Self.halfLife)
    }

    /// Counts one use of `id` at `now`, then forgets what decayed away or doesn't fit.
    public mutating func record(_ id: String, at now: Date) {
        let weight = frecency(of: id, at: now) + 1
        let previous = entries[id]
        entries[id] = Entry(uses: (previous?.uses ?? 0) + 1, lastUsed: max(previous?.lastUsed ?? now, now), weight: weight)
        trim(at: now)
    }

    /// Drops ids that aren't in `known` (commands removed from the catalog) and trims the rest.
    public mutating func prune(keeping known: Set<String>, at now: Date) {
        entries = entries.filter { known.contains($0.key) }
        trim(at: now)
    }

    /// Forgets entries that decayed below `forgottenBelow`, and keeps the `capacity` strongest.
    private mutating func trim(at now: Date) {
        entries = entries.filter { frecency(of: $0.key, at: now) >= Self.forgottenBelow }
        guard entries.count > Self.capacity else { return }
        // Strongest first; equal ones by id, so the same record always keeps the same ids.
        let ranked = entries.keys.map { (id: $0, frecency: frecency(of: $0, at: now)) }
            .sorted { $0.frecency != $1.frecency ? $0.frecency > $1.frecency : $0.id < $1.id }
        let kept = Set(ranked.prefix(Self.capacity).map(\.id))
        entries = entries.filter { kept.contains($0.key) }
    }
}

extension AppPaths {
    /// The command palette's usage record (#328).
    public var commandUsage: URL { state.appendingPathComponent("command-usage.json") }
}

/// The order of palette rows, from their text match and the commands' frecency (#328).
///
/// - With an empty command search, up to `frequentLimit` of the most used enabled commands come
///   first ("Frequently Used"), then every other command in catalog order.
/// - With a query, the text match decides. A command's frecency adds a boost below `maxBoost`,
///   which breaks ties and can lift it past a match a few points better (a word later in the
///   title, a slightly longer title), but never past a clearly better kind of match: a title
///   that starts with the query scores 100, one with a later word starting with it at most 80.
/// - Rows that aren't commands keep their places. Commands are ordered among themselves, in
///   the places commands hold, so Open Anything's targets, snippets, and files never move.
public enum CommandRanking {
    /// One palette row, matched or not.
    public struct Candidate: Sendable, Equatable {
        /// The catalog command the row runs; nil for a row that isn't a command.
        public var commandId: String?
        /// The text match (`FuzzyMatch`); 0 for an empty query.
        public var score: Int
        /// A disabled command is never promoted or boosted.
        public var isEnabled: Bool

        public init(commandId: String?, score: Int = 0, isEnabled: Bool = true) {
            self.commandId = commandId
            self.score = score
            self.isEnabled = isEnabled
        }
    }

    /// How many commands an empty command search promotes.
    public static let frequentLimit = 5
    /// The frecency a command needs to be promoted: one use in the last four weeks (two
    /// half-lives), or several longer ago.
    public static let frequentMinimum = 0.25
    /// The usage boost's ceiling, in `FuzzyMatch` points. Five points is a quarter of the gap
    /// between a title that starts with the query (100) and the best match that doesn't (80),
    /// and half the gap between a title match (40 and up) and the best match elsewhere (30).
    public static let maxBoost = 5.0
    /// The frecency that earns half of `maxBoost`; the boost grows quickly for the first few
    /// uses and levels off towards `maxBoost`.
    public static let halfBoostFrecency = 3.0

    /// A command's boost for its frecency: 0 for none, under `maxBoost` however much it is used.
    public static func boost(forFrecency frecency: Double) -> Double {
        guard frecency > 0 else { return 0 }
        return maxBoost * frecency / (frecency + halfBoostFrecency)
    }

    /// The indices of `candidates` in display order: best text match first (equal scores keep
    /// their order), then the commands reordered among their own places by score plus boost,
    /// frecency, and their order.
    public static func order(_ candidates: [Candidate], usage: CommandUsage, now: Date) -> [Int] {
        let byText = candidates.indices.sorted { a, b in
            candidates[a].score != candidates[b].score ? candidates[a].score > candidates[b].score : a < b
        }
        let slots = byText.indices.filter { candidates[byText[$0]].commandId != nil }
        guard slots.count > 1 else { return byText }
        let frecency = candidates.map { effectiveFrecency($0, usage: usage, now: now) }
        let rank = candidates.indices.map { Double(candidates[$0].score) + boost(forFrecency: frecency[$0]) }
        let commands = slots.map { byText[$0] }.sorted { a, b in
            if rank[a] != rank[b] { return rank[a] > rank[b] }
            if frecency[a] != frecency[b] { return frecency[a] > frecency[b] }
            return a < b
        }
        var result = byText
        for (slot, index) in zip(slots, commands) { result[slot] = index }
        return result
    }

    /// An empty command search: the indices of up to `limit` frequently used commands, most used
    /// first, then every other candidate in its own order, each once.
    public static func emptyQueryOrder(_ candidates: [Candidate], usage: CommandUsage, now: Date,
                                       limit: Int = frequentLimit) -> (indices: [Int], frequentCount: Int) {
        let frecency: [Double] = candidates.map { effectiveFrecency($0, usage: usage, now: now) }
        let eligible: [Int] = candidates.indices.filter { frecency[$0] >= frequentMinimum }
        let mostUsed: [Int] = eligible.sorted { a, b in frecency[a] != frecency[b] ? frecency[a] > frecency[b] : a < b }
        let frequent = Array(mostUsed.prefix(max(0, limit)))
        let promoted = Set(frequent)
        return (frequent + candidates.indices.filter { !promoted.contains($0) }, frequent.count)
    }

    private static func effectiveFrecency(_ candidate: Candidate, usage: CommandUsage, now: Date) -> Double {
        guard candidate.isEnabled, let id = candidate.commandId else { return 0 }
        return usage.frecency(of: id, at: now)
    }
}
