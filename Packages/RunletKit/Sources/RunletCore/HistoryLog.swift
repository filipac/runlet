import Foundation

/// History keeps one entry per code and target: running the same code again on the same
/// target moves its entry to the top with the latest status, time, and duration instead of
/// adding a copy. The same code on another target is a separate entry, and so is the same SQL
/// on another connection (#149).
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
        // The same text as PHP and as SQL (#35) are different entries; so are runs on different
        // connections (#149). An entry from before connections were recorded (none) is replaced
        // by the same statement's run on any connection.
        let same: (HistoryEntry) -> Bool = {
            $0.target == entry.target && ($0.language ?? .php) == (entry.language ?? .php) && Self.key($0) == key
                && ($0.connection == nil || $0.connection?.identity == entry.connection?.identity)
        }
        if let index = rest.firstIndex(where: same) {
            recorded.id = rest[index].id
            rest.remove(at: index)
        }
        rest.removeAll(where: same)
        var result = [recorded] + rest
        if result.count > limit { result.removeLast(result.count - limit) }
        return result
    }

    /// `history` for Open Anything's `!` scope: runs on `target` (the current tab's project)
    /// first, then every other run, each group newest first.
    public static func ordered(_ history: [HistoryEntry], preferring target: TargetRef?) -> [HistoryEntry] {
        let newestFirst = history.sorted { $0.timestamp > $1.timestamp }
        guard let target else { return newestFirst }
        return newestFirst.filter { $0.target == target } + newestFirst.filter { $0.target != target }
    }

    /// Library code ready to insert at the editor's cursor (⇧↩ in History and Snippets): the
    /// leading `<?php` tag and the blank lines after it are dropped, since the tab already has
    /// its own; nothing else changes.
    public static func insertable(_ code: String) -> String {
        let start = code.drop { $0.isWhitespace }
        let head = start.prefix(5).lowercased()
        guard let tag = ["<?php", "<?"].first(where: { head.hasPrefix($0) }) else { return code }
        var rest = start.dropFirst(tag.count)
        // `<?phpinfo()` or `<?=` is not a lone open tag: one is followed by whitespace or the end.
        guard rest.first.map(\.isWhitespace) ?? true else { return code }
        // Code on the tag's own line loses only the spaces before it.
        rest = rest.drop { $0 == " " || $0 == "\t" }
        // Blank lines go, keeping the indent of the first line with code.
        while let newline = rest.firstIndex(where: \.isNewline), rest[..<newline].allSatisfy(\.isWhitespace) {
            rest = rest[rest.index(after: newline)...]
        }
        return rest.allSatisfy(\.isWhitespace) ? "" : String(rest)
    }

    /// `history` (newest first) with older duplicates (same code, target, and connection)
    /// removed: what earlier versions recorded before runs were merged.
    public static func collapsingDuplicates(_ history: [HistoryEntry]) -> [HistoryEntry] {
        var seen = Set<String>()
        return history.filter { entry in
            seen.insert("\(entry.target.stableKey)\u{0}\(entry.connection?.identity ?? "")\u{0}\(key(entry))").inserted
        }
    }

    /// The Connection filter's choices (#149): each connection the entries ran on, once, with
    /// the newest entry's name (a renamed saved connection shows its latest name), sorted by
    /// name. Entries without a connection (PHP runs, older history) add none.
    public static func connections(in history: [HistoryEntry]) -> [SQLConnectionReference] {
        var seen = Set<String>()
        var found: [SQLConnectionReference] = []
        for entry in history.sorted(by: { $0.timestamp > $1.timestamp }) {
            guard let connection = entry.connection, seen.insert(connection.identity).inserted else { continue }
            found.append(connection)
        }
        return found.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// `history` narrowed to runs on the connection with this `identity` (nil: every entry).
    public static func filtered(_ history: [HistoryEntry], connection identity: String?) -> [HistoryEntry] {
        guard let identity else { return history }
        return history.filter { $0.connection?.identity == identity }
    }
}
