import Foundation

/// The profiler extensions a PHP loads: their versions, or nil when not loaded (an empty
/// string means loaded without a version). From PHP discovery, Docker and SSH probes, and the
/// runner's `started` frame.
public struct PHPProfilers: Sendable, Codable, Equatable, Hashable {
    public var excimer: String?
    public var spx: String?

    public init(excimer: String? = nil, spx: String? = nil) {
        self.excimer = excimer
        self.spx = spx
    }

    /// PHP that prints this struct as JSON on one line (for `php -r`; PHP 5.4+).
    public static let probeCode = "echo json_encode(array('excimer' => extension_loaded('excimer') ? (string) phpversion('excimer') : null, 'spx' => extension_loaded('spx') ? (string) phpversion('spx') : null));"

    /// The probe's JSON: the last line of output that decodes (login scripts may print first).
    public static func parse(_ output: String) -> PHPProfilers? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), let profilers = try? JSONDecoder().decode(PHPProfilers.self, from: Data(trimmed.utf8)) else { continue }
            return profilers
        }
        return nil
    }

    public var isEmpty: Bool { excimer == nil && spx == nil }

    /// Profile Run can sample this PHP (it uses Excimer).
    public var canProfile: Bool { excimer != nil }

    /// "Excimer 1.2.6 · SPX 0.4.22", or "None" when neither is loaded.
    public var summary: String {
        let parts = [excimer.map { "Excimer" + ($0.isEmpty ? "" : " " + $0) }, spx.map { "SPX" + ($0.isEmpty ? "" : " " + $0) }].compactMap { $0 }
        return parts.isEmpty ? "None" : parts.joined(separator: " · ")
    }
}

/// Whether Profile Run can run on a tab's target, and why not.
public enum ProfileRunAvailability: Sendable, Equatable {
    /// The target's PHP loads Excimer (its name and version).
    case ready(String)
    /// Not known yet (a container or server not probed or run since): the run checks first
    /// and stops before anything runs when Excimer is missing.
    case unchecked
    case unavailable(String)

    public var isEnabled: Bool {
        if case .unavailable = self { return false }
        return true
    }

    /// Why Profile Run is disabled, or nil when it isn't.
    public var reason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }

    /// From what is known about the target's PHP. `php` describes it for the reason, e.g.
    /// "PHP 8.4.25 (Herd)" or "this container's PHP".
    public static func evaluate(_ profilers: PHPProfilers?, php: String) -> ProfileRunAvailability {
        guard let profilers else { return .unchecked }
        if let excimer = profilers.excimer { return .ready("Excimer" + (excimer.isEmpty ? "" : " " + excimer)) }
        if profilers.spx != nil {
            return .unavailable("Profile Run needs the Excimer extension. \(php) loads SPX only, and Runlet can't read SPX's profiles (SPX writes them to files and needs SPX_ENABLED=1 when PHP starts).")
        }
        return .unavailable("Profile Run needs the Excimer extension, which \(php) doesn't load.")
    }
}

/// What a Profile Run asks the runner for (`request.profile`).
public struct RunProfileOptions: Sendable, Codable, Equatable {
    /// `excimer`, the only engine Runlet reads.
    public var engine: String
    /// Sampling period in milliseconds.
    public var periodMs: Double
    /// `wall` (wall-clock time, including waiting on I/O) or `cpu` (Linux and BSD only).
    public var eventType: String

    public init(engine: String = "excimer", periodMs: Double = 1, eventType: String = "wall") {
        self.engine = engine
        self.periodMs = periodMs
        self.eventType = eventType
    }
}

/// A Profile Run's samples (`profile` record in the Profile section): collapsed stacks and
/// what each frame name stands for.
public struct ProfileRecord: Sendable, Codable, Equatable {
    public struct Frame: Sendable, Codable, Equatable {
        /// The line the frame spent the most samples on.
        public var line: Int?
        /// The file (as the target sees it), absent for the snippet.
        public var file: String?
        public var inSnippet: Bool?
    }

    public struct Truncation: Sendable, Codable, Equatable {
        /// Distinct stacks folded into "[other stacks]".
        public var stacks: Int?
        public var foldedSamples: Int?
        /// Samples whose stacks were deeper than `maxDepth`.
        public var deepSamples: Int?

        public init(stacks: Int? = nil, foldedSamples: Int? = nil, deepSamples: Int? = nil) {
            self.stacks = stacks
            self.foldedSamples = foldedSamples
            self.deepSamples = deepSamples
        }

        public var isEmpty: Bool { (stacks ?? 0) == 0 && (foldedSamples ?? 0) == 0 && (deepSamples ?? 0) == 0 }
    }

    public var engine: String
    public var version: String?
    /// `wall` or `cpu`.
    public var eventType: String
    public var periodMs: Double
    /// Samples in the snippet.
    public var samples: Int
    public var durationMs: Double?
    /// Samples of the runner's own code around the snippet (not shown).
    public var outsideSamples: Int?
    public var maxStacks: Int?
    public var maxDepth: Int?
    /// "frame;frame;frame count" per line, root first.
    public var collapsed: String
    public var frames: [String: Frame]
    public var truncated: Truncation?
    public var php: String?

    public init(engine: String = "excimer", version: String? = nil, eventType: String = "wall", periodMs: Double = 1, samples: Int, durationMs: Double? = nil, collapsed: String, frames: [String: Frame] = [:], truncated: Truncation? = nil) {
        self.engine = engine
        self.version = version
        self.eventType = eventType
        self.periodMs = periodMs
        self.samples = samples
        self.durationMs = durationMs
        self.collapsed = collapsed
        self.frames = frames
        self.truncated = truncated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? "excimer"
        version = try c.decodeIfPresent(String.self, forKey: .version)
        eventType = try c.decodeIfPresent(String.self, forKey: .eventType) ?? "wall"
        periodMs = try c.decodeIfPresent(Double.self, forKey: .periodMs) ?? 1
        samples = try c.decodeIfPresent(Int.self, forKey: .samples) ?? 0
        durationMs = try c.decodeIfPresent(Double.self, forKey: .durationMs)
        outsideSamples = try c.decodeIfPresent(Int.self, forKey: .outsideSamples)
        maxStacks = try c.decodeIfPresent(Int.self, forKey: .maxStacks)
        maxDepth = try c.decodeIfPresent(Int.self, forKey: .maxDepth)
        collapsed = try c.decodeIfPresent(String.self, forKey: .collapsed) ?? ""
        frames = try c.decodeIfPresent([String: Frame].self, forKey: .frames) ?? [:]
        truncated = try c.decodeIfPresent(Truncation.self, forKey: .truncated)
        php = try c.decodeIfPresent(String.self, forKey: .php)
    }

    /// "Excimer 1.2.6 · wall time · 1 ms period".
    public var engineSummary: String {
        let engineName = engine == "excimer" ? "Excimer" : engine
        let period = periodMs == periodMs.rounded() ? "\(Int(periodMs)) ms" : String(format: "%.1f ms", periodMs)
        return "\(engineName)\(version.map { " " + $0 } ?? "") · \(eventType == "cpu" ? "CPU time" : "wall time") · \(period) period"
    }
}

/// A flame graph built from collapsed stacks ("a;b;c 12" per line, root first). Node 0 is the
/// root ("all"); every node knows its samples (inclusive and self) and its offset among its
/// siblings, so a view lays it out as fractions of the focused node. Children are ordered by
/// samples, largest first. Bounded: at most `maxNodes` nodes and `maxDepth` levels.
public struct FlameGraph: Sendable, Equatable {
    public struct Node: Sendable, Equatable, Identifiable {
        public let id: Int
        public var name: String
        public var parent: Int?
        public var children: [Int]
        public var depth: Int
        /// Samples in this frame and below it.
        public var value: Int
        /// Samples in this frame itself.
        public var selfValue: Int
        /// Samples before this node at its depth, measured from the root's start.
        public var offset: Int
    }

    /// What the bounds or malformed input left out.
    public struct Truncation: Sendable, Equatable {
        public var malformedLines = 0
        /// Samples whose stacks were cut at `maxDepth` levels.
        public var depthSamples = 0
        /// Samples that reached the node limit and were kept on a shallower frame.
        public var nodeSamples = 0

        public var isEmpty: Bool { malformedLines == 0 && depthSamples == 0 && nodeSamples == 0 }
    }

    /// One frame to draw: its node and its horizontal extent (0…1 of the visible width).
    public struct Placement: Sendable, Equatable {
        public var node: Int
        public var depth: Int
        public var x: Double
        public var width: Double
    }

    public static let rootName = "all"
    public static let deeperName = "[deeper frames]"

    public private(set) var nodes: [Node]
    public private(set) var truncation = Truncation()
    public let maxNodes: Int
    public let maxDepth: Int

    public var root: Node { nodes[0] }
    public var totalSamples: Int { nodes[0].value }
    /// Levels below the root.
    public var depth: Int { nodes.map(\.depth).max() ?? 0 }

    public init(collapsed: String, maxNodes: Int = 50_000, maxDepth: Int = 256) {
        self.maxNodes = max(2, maxNodes)
        self.maxDepth = max(1, maxDepth)
        nodes = [Node(id: 0, name: Self.rootName, parent: nil, children: [], depth: 0, value: 0, selfValue: 0, offset: 0)]
        var childIndex: [Int: [String: Int]] = [:]
        for rawLine in collapsed.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let space = line.lastIndex(of: " "), let count = Int(line[line.index(after: space)...]), count > 0 else {
                truncation.malformedLines += 1
                continue
            }
            var frames = line[..<space].split(separator: ";", omittingEmptySubsequences: true).map(String.init)
            if frames.isEmpty {
                truncation.malformedLines += 1
                continue
            }
            if frames.count > self.maxDepth {
                frames = Array(frames.prefix(self.maxDepth - 1)) + [Self.deeperName]
                truncation.depthSamples += count
            }
            var current = 0
            nodes[0].value += count
            for name in frames {
                if let existing = childIndex[current]?[name] {
                    current = existing
                } else if nodes.count < self.maxNodes {
                    let id = nodes.count
                    nodes.append(Node(id: id, name: name, parent: current, children: [], depth: nodes[current].depth + 1, value: 0, selfValue: 0, offset: 0))
                    nodes[current].children.append(id)
                    childIndex[current, default: [:]][name] = id
                    current = id
                } else {
                    truncation.nodeSamples += count
                    break
                }
                nodes[current].value += count
            }
            nodes[current].selfValue += count
        }
        layOut()
    }

    /// Children ordered by samples (largest first, then by name), offsets from the root.
    private mutating func layOut() {
        var stack = [0]
        while let id = stack.popLast() {
            let sorted = nodes[id].children.sorted { a, b in
                nodes[a].value != nodes[b].value ? nodes[a].value > nodes[b].value : nodes[a].name < nodes[b].name
            }
            nodes[id].children = sorted
            var offset = nodes[id].offset
            for child in sorted {
                nodes[child].offset = offset
                offset += nodes[child].value
                stack.append(child)
            }
        }
    }

    /// The node and its ancestors, root first.
    public func path(to id: Int) -> [Int] {
        var path: [Int] = []
        var current: Int? = id
        while let node = current, nodes.indices.contains(node) {
            path.append(node)
            current = nodes[node].parent
        }
        return path.reversed()
    }

    public func isAncestor(_ ancestor: Int, of id: Int) -> Bool {
        var current = nodes.indices.contains(id) ? nodes[id].parent : nil
        while let node = current {
            if node == ancestor { return true }
            current = nodes[node].parent
        }
        return false
    }

    /// What to draw while `focus` is zoomed in: its ancestors at full width (dimmed by the
    /// view), then its subtree scaled to the width. Frames narrower than `minimumWidth` (a
    /// fraction of the width) are left out with their children.
    public func placements(focus: Int = 0, minimumWidth: Double = 0) -> [Placement] {
        guard nodes.indices.contains(focus), nodes[focus].value > 0 else { return [] }
        let start = Double(nodes[focus].offset)
        let span = Double(nodes[focus].value)
        var result = path(to: focus).dropLast().map { Placement(node: $0, depth: nodes[$0].depth, x: 0, width: 1) }
        var stack = [focus]
        while let id = stack.popLast() {
            let node = nodes[id]
            let width = Double(node.value) / span
            guard width >= minimumWidth || id == focus else { continue }
            result.append(Placement(node: id, depth: node.depth, x: (Double(node.offset) - start) / span, width: width))
            stack.append(contentsOf: node.children)
        }
        return result
    }

    /// Nodes whose name contains `query` (case-insensitive); empty for an empty query.
    public func matches(_ query: String) -> Set<Int> {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        return Set(nodes.dropFirst().filter { $0.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }.map(\.id))
    }

    /// Samples under the matched frames, counting nested matches (recursion) once.
    public func matchedSamples(_ matches: Set<Int>) -> Int {
        matches.filter { id in !path(to: id).dropLast().contains { matches.contains($0) } }.reduce(0) { $0 + nodes[$1].value }
    }

    /// The functions with the most samples of their own, with their inclusive samples (a
    /// recursive function counted once per stack).
    public func hottestFunctions(limit: Int = 10) -> [(name: String, selfSamples: Int, totalSamples: Int)] {
        var selfByName: [String: Int] = [:]
        var totalByName: [String: Int] = [:]
        for node in nodes.dropFirst() {
            selfByName[node.name, default: 0] += node.selfValue
            let ancestorHasName = path(to: node.id).dropLast().contains { nodes[$0].name == node.name }
            if !ancestorHasName { totalByName[node.name, default: 0] += node.value }
        }
        return selfByName.filter { $0.value > 0 }
            .map { (name: $0.key, selfSamples: $0.value, totalSamples: totalByName[$0.key] ?? $0.value) }
            .sorted { $0.selfSamples != $1.selfSamples ? $0.selfSamples > $1.selfSamples : $0.name < $1.name }
            .prefix(limit)
            .map { $0 }
    }
}
