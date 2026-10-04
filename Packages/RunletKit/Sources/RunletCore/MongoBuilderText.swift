import Foundation

/// Where the MongoDB query builder (#217) reads and writes in a tab's text. A tab may hold
/// several queries (⌘R runs the selected one): the builder works on the one that is selected,
/// or the one at the caret, and leaves the others alone. Offsets are UTF-16, like NSString's.
public enum MongoBuilderText {
    /// A top-level `{ … }` in the text.
    public struct Block: Equatable, Sendable {
        public var range: NSRange
        /// False when the text ends before its closing brace.
        public var closed: Bool
    }

    /// The top-level JSON objects of `text`, skipping braces in strings and `//` comment lines
    /// between queries.
    public static func blocks(in text: String) -> [Block] {
        let units = Array(text.utf16)
        var blocks: [Block] = []
        var depth = 0, start = 0, index = 0
        var inString = false, escaped = false
        while index < units.count {
            let unit = units[index]
            if inString {
                if escaped { escaped = false } else if unit == 92 { escaped = true } else if unit == 34 { inString = false }
            } else if depth > 0, unit == 34 {
                inString = true
            } else if depth == 0, unit == 47, index + 1 < units.count, units[index + 1] == 47 {
                while index < units.count, units[index] != 10 { index += 1 }
                continue
            } else if unit == 123 {
                if depth == 0 { start = index }
                depth += 1
            } else if unit == 125, depth > 0 {
                depth -= 1
                if depth == 0 { blocks.append(Block(range: NSRange(location: start, length: index + 1 - start), closed: true)) }
            }
            index += 1
        }
        if depth > 0 { blocks.append(Block(range: NSRange(location: start, length: units.count - start), closed: false)) }
        return blocks
    }

    public enum Target: Equatable, Sendable {
        /// The query the builder reads and rewrites.
        case query(NSRange)
        /// A query that never closes: the builder can't read it, and doesn't touch it.
        case unclosed(NSRange)
        /// No query at the caret: the builder's query is inserted.
        case none
    }

    /// The selected query (the block the selection is in, or covers), or the one at the caret
    /// (on it, or on its line), or the tab's only query.
    public static func target(in text: String, selection: NSRange) -> Target {
        let blocks = blocks(in: text)
        func target(_ block: Block) -> Target { block.closed ? .query(block.range) : .unclosed(block.range) }
        if selection.length > 0 {
            if let block = blocks.first(where: { NSIntersectionRange($0.range, selection).length > 0 }) { return target(block) }
            return .none
        }
        let caret = selection.location
        if let block = blocks.first(where: { caret >= $0.range.location && caret <= NSMaxRange($0.range) }) { return target(block) }
        let length = (text as NSString).length
        let line = (text as NSString).lineRange(for: NSRange(location: min(caret, length), length: 0))
        if let block = blocks.first(where: { NSIntersectionRange($0.range, line).length > 0 }) { return target(block) }
        if blocks.count == 1 { return target(blocks[0]) }
        return .none
    }

    /// The 1-based line `offset` is on.
    public static func line(of offset: Int, in text: String) -> Int {
        let ns = text as NSString
        return ns.substring(to: min(max(0, offset), ns.length)).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    /// An edit of the tab's text: replace `range` with `replacement`, then select `selection`.
    /// `query` is the written query's range in the new text.
    public struct Edit: Equatable, Sendable {
        public var range: NSRange
        public var replacement: String
        public var selection: NSRange
        public var query: NSRange
    }

    /// Rewrites the query at `range` as `query`, replacing only the part that differs (so the
    /// lines around it and the scroll position stay). A caret keeps its place in the unchanged
    /// text; a selection of the whole query selects the new one, so ⌘R still runs it.
    public static func rewrite(_ range: NSRange, with query: String, in text: String, selection: NSRange) -> Edit {
        let old = Array((text as NSString).substring(with: range).utf16)
        let new = Array(query.utf16)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        if prefix > 0, UTF16.isLeadSurrogate(old[prefix - 1]) { prefix -= 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        if suffix > 0, UTF16.isTrailSurrogate(old[old.count - suffix]) { suffix -= 1 }
        let changed = NSRange(location: range.location + prefix, length: old.count - prefix - suffix)
        let inserted = String(decoding: new[prefix..<(new.count - suffix)], as: UTF16.self)
        let delta = new.count - old.count
        let written = NSRange(location: range.location, length: new.count)
        let selected: NSRange
        if selection.length > 0, NSIntersectionRange(selection, range).length > 0, selection.location <= range.location, NSMaxRange(selection) >= NSMaxRange(range) {
            selected = NSRange(location: selection.location, length: selection.length + delta)
        } else {
            func map(_ offset: Int) -> Int {
                if offset <= changed.location { return offset }
                if offset >= NSMaxRange(changed) { return offset + delta }
                return changed.location + min(offset - changed.location, (inserted as NSString).length)
            }
            selected = NSRange(location: map(selection.location), length: 0)
        }
        return Edit(range: changed, replacement: inserted, selection: selected, query: written)
    }

    /// Inserts `query` as a new query: after the block at `after` (Insert as New Query), else
    /// at the end of the text, separated by a blank line; a blank tab gets just the query.
    /// The caret goes to the new query's start.
    public static func insert(_ query: String, in text: String, after: NSRange? = nil) -> Edit {
        let ns = text as NSString
        let length = (query as NSString).length
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Edit(range: NSRange(location: 0, length: ns.length), replacement: query + "\n", selection: NSRange(location: 0, length: 0), query: NSRange(location: 0, length: length))
        }
        let at = after.map { min(NSMaxRange($0), ns.length) } ?? ns.length
        let before = ns.substring(to: at)
        let separator = before.hasSuffix("\n\n") ? "" : before.hasSuffix("\n") ? "\n" : "\n\n"
        let trailer = at == ns.length ? "\n" : ""
        let start = at + (separator as NSString).length
        return Edit(range: NSRange(location: at, length: 0), replacement: separator + query + trailer,
                    selection: NSRange(location: start, length: 0), query: NSRange(location: start, length: length))
    }
}

/// When the builder writes (#217): a change is written once the builder has been still for
/// `delay`, so typing a value makes one edit (one Undo step) rather than one per keystroke.
public struct MongoBuilderSchedule: Equatable, Sendable {
    public var delay: TimeInterval
    public private(set) var due: Date?

    public init(delay: TimeInterval = 0.4) {
        self.delay = delay
    }

    /// A change at `now`: the write waits until `delay` after the last change.
    public mutating func change(at now: Date) {
        due = now.addingTimeInterval(delay)
    }

    /// Whether a change is waiting and its time has come.
    public func isDue(at now: Date) -> Bool {
        due.map { now >= $0 } ?? false
    }

    public var isPending: Bool { due != nil }

    /// The write happened, or was dropped.
    public mutating func clear() {
        due = nil
    }
}
