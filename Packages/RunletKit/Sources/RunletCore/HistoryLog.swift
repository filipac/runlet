import Foundation

/// History keeps one entry per code and target: running the same code again on the same
/// target moves its entry to the top with the latest status, time, and duration instead of
/// adding a copy. The same code on another target is a separate entry.
public enum HistoryLog {
    /// Code compared without leading and trailing whitespace (a trailing newline or the
    /// editor's indentation at the end does not make a new entry).
    static func key(_ entry: HistoryEntry) -> String {
        entry.code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `history` (newest first) with `entry` recorded at the top. An existing entry with
    /// the same code and target is replaced, keeping its `id` so selections survive; the list
    /// is capped at `limit`.
    public static func recording(_ entry: HistoryEntry, into history: [HistoryEntry], limit: Int) -> [HistoryEntry] {
        let key = key(entry)
        var recorded = entry
        var rest = history
        if let index = rest.firstIndex(where: { $0.target == entry.target && Self.key($0) == key }) {
            recorded.id = rest[index].id
            rest.remove(at: index)
        }
        rest.removeAll { $0.target == entry.target && Self.key($0) == key }
        var result = [recorded] + rest
        if result.count > limit { result.removeLast(result.count - limit) }
        return result
    }

    /// `history` (newest first) with older duplicates (same code and target) removed: what
    /// earlier versions recorded before runs were merged.
    public static func collapsingDuplicates(_ history: [HistoryEntry]) -> [HistoryEntry] {
        var seen = Set<String>()
        return history.filter { entry in
            seen.insert("\(entry.target.stableKey)\u{0}\(key(entry))").inserted
        }
    }
}
