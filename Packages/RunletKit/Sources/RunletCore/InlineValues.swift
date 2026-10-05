import Foundation

// Magic comments (#10): `//?`, `/*?*/`, `/*?->projection*/`, and `/*?.*/` show values inline
// in the editor. The runner reports the compiled probes (`probes`) and streams their hits
// (`inline`) while the code runs; `InlineValues` folds them per editor line.

/// One magic comment the runner turned into a probe.
public struct InlineProbe: Sendable, Codable, Equatable {
    /// Probe id within the run (1-based, in source order).
    public var id: Int
    /// 1-based line in the submitted code.
    public var line: Int
    /// `value` (a value or projection), `time` (`/*?.*/`), or `reached` (`//?` on a line with no value).
    public var kind: String
    /// The comment as written, shortened.
    public var comment: String

    public init(id: Int, line: Int, kind: String, comment: String) {
        self.id = id
        self.line = line
        self.kind = kind
        self.comment = comment
    }
}

/// A magic comment the runner could not show, and why. The code still runs as written.
public struct InlineRejection: Sendable, Codable, Equatable {
    public var line: Int
    public var comment: String
    public var reason: String
    /// A few words for the inline text ("assigned here"); `reason` shows on hover.
    public var label: String?

    public init(line: Int, comment: String, reason: String, label: String? = nil) {
        self.line = line
        self.comment = comment
        self.reason = reason
        self.label = label
    }
}

/// The `probes` event: sent once, before the snippet runs.
public struct InlineProbesInfo: Sendable, Codable, Equatable {
    public var probes: [InlineProbe]
    public var rejected: [InlineRejection]

    public init(probes: [InlineProbe], rejected: [InlineRejection]) {
        self.probes = probes
        self.rejected = rejected
    }
}

/// One `inline` event: a hit of a probe. The first 100 hits of a probe carry values; later
/// ones are sampled (`sampled`), and a `final` event without a value carries the total count.
public struct InlineHit: Sendable, Codable, Equatable {
    public struct Failure: Sendable, Codable, Equatable {
        public var className: String
        public var message: String

        public init(className: String, message: String) {
            self.className = className
            self.message = message
        }
    }

    public var probe: Int
    /// 1-based line in the submitted code.
    public var line: Int
    public var kind: String
    /// This hit's number (1 for the first time the line ran).
    public var hit: Int
    /// Milliseconds since the snippet started running.
    public var t: Double?
    /// The value (or projection), bounded like other values.
    public var value: ValueNode?
    /// #307: the value with its Eloquent models by what they hold (Values); nil when it holds none.
    public var modelValues: ValueNode?
    /// `/*?.*/`: milliseconds since the previous `/*?.*/` (or since the snippet started).
    public var ms: Double?
    /// A projection that threw.
    public var error: Failure?
    /// Sent after the first hits, about four times a second.
    public var sampled: Bool?
    /// The final count, sent when the run finishes.
    public var final: Bool?
    /// `bytes` when the run's budget for values was used up.
    public var omitted: String?

    public init(probe: Int, line: Int, kind: String, hit: Int, t: Double? = nil, value: ValueNode? = nil, modelValues: ValueNode? = nil, ms: Double? = nil, error: Failure? = nil, sampled: Bool? = nil, final: Bool? = nil, omitted: String? = nil) {
        self.probe = probe
        self.line = line
        self.kind = kind
        self.hit = hit
        self.t = t
        self.value = value
        self.modelValues = modelValues
        self.ms = ms
        self.error = error
        self.sampled = sampled
        self.final = final
        self.omitted = omitted
    }
}

public enum InlineEvent: Sendable, Equatable {
    case probes(InlineProbesInfo)
    case hit(InlineHit)
}

/// A run's magic-comment values, by editor line: what the editor draws after each line and
/// shows on hover. Lines are the editor's lines when the run started (Run Selection is mapped
/// back through the request); `InlineLineTracker` follows them through later edits.
public struct InlineValues: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case value, time, reached
    }

    /// One recorded hit.
    public struct Hit: Sendable, Equatable, Identifiable {
        public var number: Int
        public var t: Double?
        public var value: ValueNode?
        /// #307: the Values tree, when the value holds Eloquent models.
        public var modelValues: ValueNode?
        public var ms: Double?
        public var error: InlineHit.Failure?
        public var sampled: Bool

        public var id: Int { number }
    }

    public struct Probe: Sendable, Equatable, Identifiable {
        public var id: Int
        /// 1-based editor line (when the run started).
        public var line: Int
        public var kind: Kind
        public var comment: String
        /// How many times the line ran (the final count once the run finished).
        public var hits: Int = 0
        /// The latest hit with something to show.
        public var last: Hit?
        /// The hits kept for the hover list, oldest first.
        public var recent: [Hit] = []
        /// The count is final: the run finished.
        public var isFinal = false
    }

    public struct Rejection: Sendable, Equatable {
        /// 1-based editor line (when the run started).
        public var line: Int
        public var comment: String
        public var reason: String
        public var label: String?
    }

    /// Hits kept per probe for the hover list (the runner sends values for the first 100).
    public static let maxRecent = 100

    public private(set) var probes: [Int: Probe] = [:]
    public private(set) var rejections: [Rejection] = []
    /// Editor line → probe ids on it, in source order.
    public private(set) var probeIdsByLine: [Int: [Int]] = [:]

    public init() {}

    public var isEmpty: Bool { probes.isEmpty && rejections.isEmpty }

    /// Lines with something to draw: probes (hit or not) and rejections.
    public var lines: Set<Int> {
        Set(probeIdsByLine.keys).union(rejections.map(\.line))
    }

    /// Applies one event; `editorLine` maps a line of the submitted code to the editor.
    public mutating func apply(_ event: InlineEvent, editorLine: (Int) -> Int) {
        switch event {
        case .probes(let info):
            for probe in info.probes {
                let line = editorLine(probe.line)
                if probes[probe.id] == nil {
                    probes[probe.id] = Probe(id: probe.id, line: line, kind: Kind(rawValue: probe.kind) ?? .value, comment: probe.comment)
                    probeIdsByLine[line, default: []].append(probe.id)
                    probeIdsByLine[line]?.sort()
                }
            }
            rejections += info.rejected.map { Rejection(line: editorLine($0.line), comment: $0.comment, reason: $0.reason, label: $0.label) }
        case .hit(let hit):
            var probe = probes[hit.probe] ?? {
                // A hit before (or without) its `probes` event still shows.
                let line = editorLine(hit.line)
                probeIdsByLine[line, default: []].append(hit.probe)
                probeIdsByLine[line]?.sort()
                return Probe(id: hit.probe, line: line, kind: Kind(rawValue: hit.kind) ?? .value, comment: "")
            }()
            probe.hits = max(probe.hits, hit.hit)
            if hit.final == true {
                probe.isFinal = true
            } else {
                let recorded = Hit(number: hit.hit, t: hit.t, value: hit.value, modelValues: hit.modelValues, ms: hit.ms, error: hit.error, sampled: hit.sampled == true)
                if probe.last == nil || hit.hit >= probe.last!.number {
                    probe.last = recorded
                }
                if probe.recent.count < Self.maxRecent || hit.sampled == true {
                    probe.recent.append(recorded)
                    if probe.recent.count > Self.maxRecent + 20 { probe.recent.removeSubrange(Self.maxRecent..<(probe.recent.count - 19)) }
                }
            }
            probes[hit.probe] = probe
        }
    }

    /// Probes on an editor line, in source order.
    public func probes(onLine line: Int) -> [Probe] {
        (probeIdsByLine[line] ?? []).compactMap { probes[$0] }
    }

    public func rejections(onLine line: Int) -> [Rejection] {
        rejections.filter { $0.line == line }
    }

    /// Total hits on a line (for the gutter marker).
    public func hits(onLine line: Int) -> Int {
        probes(onLine: line).map(\.hits).max() ?? 0
    }

    /// Drops everything on `line` (it was edited since the run).
    public mutating func removeLine(_ line: Int) {
        for id in probeIdsByLine[line] ?? [] { probes[id] = nil }
        probeIdsByLine[line] = nil
        rejections.removeAll { $0.line == line }
    }

    /// The text drawn after a line: each probe's latest value (`×N` when it ran more than
    /// once), the time for `/*?.*/`, `✓` for a reached line, or why a comment shows nothing.
    /// `display` (#307) picks the tree a value holding Eloquent models is summarized from.
    public func summary(onLine line: Int, maxLength: Int = 160, display: ModelDisplay = .values) -> InlineSummary? {
        var parts: [InlineSummary.Part] = []
        for probe in probes(onLine: line) {
            if let part = Self.part(for: probe, display: display) { parts.append(part) }
        }
        for rejection in rejections(onLine: line) {
            parts.append(InlineSummary.Part(text: "⚠︎ " + (rejection.label.map { "not shown: " + $0 } ?? rejection.reason), count: nil, style: .warning))
        }
        guard !parts.isEmpty else { return nil }
        return InlineSummary(parts: parts.map { part in
            var part = part
            if part.text.count > maxLength { part.text = String(part.text.prefix(maxLength - 1)) + "…" }
            return part
        })
    }

    static func part(for probe: Probe, display: ModelDisplay = .values) -> InlineSummary.Part? {
        let count = probe.hits > 1 ? probe.hits : nil
        guard probe.hits > 0 else { return nil }
        switch probe.kind {
        case .reached:
            return InlineSummary.Part(text: "✓", count: count, style: .value)
        case .time:
            guard let ms = probe.last?.ms else { return InlineSummary.Part(text: "⏱", count: count, style: .value) }
            return InlineSummary.Part(text: "⏱ " + Self.duration(ms), count: count, style: .value)
        case .value:
            guard let last = probe.last else { return InlineSummary.Part(text: "…", count: count, style: .value) }
            if let error = last.error {
                return InlineSummary.Part(text: "⚠︎ \(Self.shortClass(error.className)): \(error.message)", count: count, style: .error)
            }
            guard let value = last.node(for: display) else { return InlineSummary.Part(text: "…", count: count, style: .value) }
            return InlineSummary.Part(text: value.compactSummary(), count: count, style: .value)
        }
    }

    public static func duration(_ ms: Double) -> String {
        if ms >= 1000 { return String(format: "%.2f s", ms / 1000) }
        if ms >= 100 { return String(format: "%.1f ms", ms) }
        if ms >= 10 { return String(format: "%.1f ms", ms) }
        return String(format: "%.2f ms", ms)
    }

    static func shortClass(_ name: String) -> String {
        name.split(separator: "\\").last.map(String.init) ?? name
    }
}

/// The text drawn after a line with magic comments.
public struct InlineSummary: Sendable, Equatable {
    public enum Style: Sendable, Equatable { case value, error, warning }

    public struct Part: Sendable, Equatable {
        public var text: String
        /// Hits, when the line ran more than once (`×N`).
        public var count: Int?
        public var style: Style
    }

    public var parts: [Part]

    /// Plain text, as drawn: `×3 "c"  ·  ⏱ 1.20 ms`.
    public var plainText: String {
        parts.map { ($0.count.map { "×\($0) " } ?? "") + $0.text }.joined(separator: "  ·  ")
    }
}

extension ValueNode {
    /// A one-line preview for inline values: scalars as PHP literals, small arrays with their
    /// first items (`[1, 2, 3]`, `["id" => 1, …]`), objects by short class name.
    public func compactSummary(budget: Int = 100) -> String {
        switch type {
        case .array:
            if recursion == true { return "[*RECURSION*]" }
            let total = count ?? entries?.count ?? 0
            guard let entries, !entries.isEmpty else { return total == 0 ? "[]" : "array:\(total)" }
            let isList = entries.enumerated().allSatisfy { $0.element.keyType == "int" && $0.element.key == String($0.offset) }
            var text = "["
            var shown = 0
            for entry in entries {
                let item = (isList ? "" : (entry.keyType == "string" ? "\"\(entry.key)\" => " : "\(entry.key) => ")) + entry.value.compactSummary(budget: 30)
                if text.count + item.count > budget, shown > 0 { break }
                text += (shown > 0 ? ", " : "") + item
                shown += 1
            }
            if shown < total { text += ", …" }
            return text + "]" + (shown < total ? " (\(total))" : "")
        case .object:
            let name = className.map { $0.split(separator: "\\").last.map(String.init) ?? $0 } ?? "object"
            if let summary { return "\(name) \(summary)" }
            if let model { return modelCompactSummary(model, budget: budget) }
            if let collection {
                // #307: `Collection<User>(312) [User #1 {…}, …]`, like a collection's items.
                let title = name + (collection.of.map { "<\(ValueNode.shortClass($0))>" } ?? "")
                if repeated == true { return title + " (see above)" }
                var list = self
                list.type = .array
                list.count = collection.count
                list.collection = nil
                return "\(title)(\(collection.count)) " + list.compactSummary(budget: max(20, budget - title.count - 6))
            }
            if repeated == true { return name + " (see above)" }
            // #6: a driver caster's fields, as `Money {amount: 1250, currency: "EUR"}`.
            if isCast, let fields = entries, !fields.isEmpty {
                var text = ""
                var shown = 0
                for entry in fields {
                    let item = "\(entry.key): " + entry.value.compactSummary(budget: 24)
                    if text.count + item.count > budget, shown > 0 { break }
                    text += (shown > 0 ? ", " : "") + item
                    shown += 1
                }
                return "\(name) {" + text + (shown < (count ?? fields.count) ? ", …" : "") + "}"
            }
            // Collections keep their values in `items`, Eloquent models in `attributes`.
            if let items = entries?.first(where: { $0.key == "items" && $0.value.type == .array })?.value {
                return "\(name)(\(items.count ?? items.entries?.count ?? 0)) " + items.compactSummary(budget: max(20, budget - name.count - 6))
            }
            if let attributes = entries?.first(where: { $0.key == "attributes" && $0.value.type == .array })?.value.entries, !attributes.isEmpty {
                var text = ""
                var shown = 0
                for entry in attributes {
                    let item = "\(entry.key): " + entry.value.compactSummary(budget: 24)
                    if text.count + item.count > budget, shown > 0 { break }
                    text += (shown > 0 ? ", " : "") + item
                    shown += 1
                }
                return "\(name) {" + text + (shown < attributes.count ? ", …" : "") + "}"
            }
            let count = count ?? entries?.count
            return name + (count.map { " {\($0)}" } ?? "")
        case .string:
            var text = "\"" + displayString.replacingOccurrences(of: "\n", with: "\\n") + "\""
            if text.count > budget { text = String(text.prefix(budget - 2)) + "…\"" }
            if let length, length > displayString.utf8.count { text += " (\(length) bytes)" }
            return text
        default:
            return inlineSummary
        }
    }

    /// #307: `User #1 {name: "Alice", email: …}`: the model's title, then its attributes other
    /// than the key (it is in the title), as the Values tree shows them.
    private func modelCompactSummary(_ model: ModelInfo, budget: Int) -> String {
        let title = (modelTitle ?? shortClassName) + (model.exists ? "" : " (new)")
        if repeated == true { return title + " (see above)" }
        let attributes = (entries ?? []).filter { $0.keyType == "attribute" && !(model.key != nil && ($0.key == model.keyName || $0.key == "_id")) }
        guard !attributes.isEmpty else { return title }
        var text = ""
        var shown = 0
        for entry in attributes {
            let item = "\(entry.key): " + entry.value.compactSummary(budget: 24)
            if text.count + item.count > budget, shown > 0 { break }
            text += (shown > 0 ? ", " : "") + item
            shown += 1
        }
        return "\(title) {" + text + (shown < attributes.count || truncation != nil ? ", …" : "") + "}"
    }
}

/// Follows the lines that show inline values through edits made after the run started, by
/// their character ranges. A line whose text changed loses its values; lines above or below
/// an edit keep them, moved with their text. Work per edit is proportional to the number of
/// tracked lines, not to the document.
public struct InlineLineTracker: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        /// The line's current range, without its line break.
        public var range: NSRange
        /// Its text when the run started.
        public var text: String
    }

    /// Original editor line (1-based) → where it is now.
    public private(set) var lines: [Int: Line] = [:]

    public init() {}

    /// Starts tracking `lineNumbers` (1-based) of `text`.
    public init(text: NSString, lineNumbers: Set<Int>) {
        guard let lastWanted = lineNumbers.max() else { return }
        var number = 1
        var location = 0
        let length = text.length
        while number <= lastWanted {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            var content = lineRange
            if content.length > 0, text.character(at: NSMaxRange(content) - 1) == 10 { content.length -= 1 }
            if content.length > 0, text.character(at: NSMaxRange(content) - 1) == 13 { content.length -= 1 }
            if lineNumbers.contains(number) {
                lines[number] = Line(range: content, text: text.substring(with: content))
            }
            // The last line has no line break after it.
            if NSMaxRange(lineRange) >= length, NSMaxRange(content) == NSMaxRange(lineRange) { break }
            location = NSMaxRange(lineRange)
            number += 1
        }
    }

    public var isEmpty: Bool { lines.isEmpty }

    /// The current range of an original line, or nil once it was edited.
    public func range(ofLine line: Int) -> NSRange? {
        lines[line]?.range
    }

    /// Stops following a line.
    public mutating func remove(line: Int) {
        lines[line] = nil
    }

    /// Follows the editor lines (of `editorText`) that the lines of `code` with magic comments
    /// came from: the whole text, or a selection starting at `selection`. A line whose text
    /// doesn't hold the code that runs (code run from elsewhere than the editor) isn't
    /// followed, so its values are never shown on an unrelated line.
    public static func forRun(code: String, selection: SourceSelection?, editorText: NSString) -> InlineLineTracker {
        var wanted: [Int: String] = [:]
        for (index, line) in code.components(separatedBy: "\n").enumerated() where line.contains("//?") || line.contains("/*?") {
            wanted[RunRequest.editorLine(forSnippetLine: index + 1, selection: selection)] = line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
        var tracker = InlineLineTracker(text: editorText, lineNumbers: Set(wanted.keys))
        for (line, code) in wanted {
            // A selection may start or end inside a line.
            guard let text = tracker.lines[line]?.text, text == code || text.hasSuffix(code) || text.hasPrefix(code) else {
                tracker.remove(line: line)
                continue
            }
        }
        return tracker
    }

    /// Applies one edit: `range` (in the old text) was replaced by `replacementLength`
    /// characters, giving `newText`. Returns the original lines that stopped being tracked.
    @discardableResult
    public mutating func edit(range: NSRange, replacementLength: Int, newText: NSString) -> [Int] {
        guard !lines.isEmpty else { return [] }
        let delta = replacementLength - range.length
        var dropped: [Int] = []
        for (number, line) in lines {
            var current = line.range
            if NSMaxRange(current) < range.location {
                // Above the edit: unchanged.
            } else if current.location > NSMaxRange(range) {
                current.location += delta
            } else if NSMaxRange(current) == range.location || current.location == NSMaxRange(range) {
                // The edit touches the line's edge: unchanged if the text is the same in its old
                // place (a line break typed after it) or one edit later (a line break before it).
                let moved = NSRange(location: current.location + delta, length: current.length)
                if !Self.holds(newText, line.text, at: current) {
                    guard current.location == NSMaxRange(range), Self.holds(newText, line.text, at: moved) else {
                        dropped.append(number)
                        continue
                    }
                    current = moved
                }
            } else {
                dropped.append(number)
                continue
            }
            guard Self.holds(newText, line.text, at: current) else {
                dropped.append(number)
                continue
            }
            lines[number]?.range = current
        }
        for number in dropped { lines[number] = nil }
        return dropped.sorted()
    }

    /// Whether `text` is a whole line of `string` at `range`.
    static func holds(_ string: NSString, _ text: String, at range: NSRange) -> Bool {
        guard range.location >= 0, NSMaxRange(range) <= string.length else { return false }
        if range.location > 0, string.character(at: range.location - 1) != 10 { return false }
        if NSMaxRange(range) < string.length {
            let next = string.character(at: NSMaxRange(range))
            if next != 10 && next != 13 { return false }
        }
        return string.substring(with: range) == text
    }
}
