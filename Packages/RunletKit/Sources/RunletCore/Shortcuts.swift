import Foundation

/// A keyboard shortcut as stored in settings: one key plus modifiers.
public struct KeyCombo: Sendable, Codable, Hashable {
    public enum Modifier: String, Sendable, Codable, CaseIterable, Comparable {
        case control, option, shift, command

        /// Display order used by macOS menus: ⌃⌥⇧⌘.
        public static func < (lhs: Modifier, rhs: Modifier) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }

        public var symbol: String {
            switch self {
            case .control: "⌃"
            case .option: "⌥"
            case .shift: "⇧"
            case .command: "⌘"
            }
        }
    }

    /// A single lowercase character ("r", "/", "1") or a named key
    /// ("return", "escape", "tab", "space", "delete", "up", "down", "left", "right").
    public var key: String
    public var modifiers: Set<Modifier>

    public init(_ key: String, _ modifiers: Set<Modifier> = [.command]) {
        self.key = key.count == 1 ? key.lowercased() : key
        self.modifiers = modifiers
    }

    public static let namedKeys: [String: String] = [
        "return": "↩", "escape": "⎋", "tab": "⇥", "space": "Space", "delete": "⌫",
        "up": "↑", "down": "↓", "left": "←", "right": "→",
    ]

    public var displayString: String {
        let mods = modifiers.sorted().map(\.symbol).joined()
        let keyText = Self.namedKeys[key] ?? key.uppercased()
        return mods + keyText
    }

    /// A combo is usable as a menu shortcut if it has ⌘/⌃/⌥, or is a named key.
    public var isValidShortcut: Bool {
        !key.isEmpty && (!modifiers.isDisjoint(with: [.command, .control, .option]) || Self.namedKeys[key] != nil)
    }
}

/// A user's change to a command's shortcut: a different combo, or none at all.
public struct ShortcutOverride: Sendable, Codable, Hashable {
    public var combo: KeyCombo?

    public init(combo: KeyCombo?) {
        self.combo = combo
    }
}

/// Resolves effective shortcuts and finds conflicts.
public enum ShortcutResolver {
    public static func effective(defaults: [String: KeyCombo?], overrides: [String: ShortcutOverride]) -> [String: KeyCombo] {
        var result: [String: KeyCombo] = [:]
        for (id, combo) in defaults {
            if let override = overrides[id] {
                if let combo = override.combo { result[id] = combo }
            } else if let combo {
                result[id] = combo
            }
        }
        return result
    }

    /// Commands that share a combo, keyed by combo.
    public static func conflicts(in effective: [String: KeyCombo]) -> [KeyCombo: [String]] {
        var byCombo: [KeyCombo: [String]] = [:]
        for (id, combo) in effective { byCombo[combo, default: []].append(id) }
        return byCombo.filter { $0.value.count > 1 }.mapValues { $0.sorted() }
    }
}

/// Fuzzy matching for palettes: every query character must appear in order. Higher scores
/// mean better matches (prefix, word starts, consecutive runs, shorter candidates).
public enum FuzzyMatch {
    public static func score(_ query: String, _ candidate: String) -> Int? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        let haystack = Array(candidate)
        let lower = Array(candidate.lowercased())
        var score = 0
        var searchFrom = 0
        var previousMatch = -2
        var firstMatch: Int?
        for character in needle {
            guard let index = lower[searchFrom...].firstIndex(of: character) else { return nil }
            if firstMatch == nil { firstMatch = index }
            var points = 1
            if index == previousMatch + 1 { points += 5 }
            if index == 0 {
                points += 8
            } else {
                let before = haystack[index - 1]
                if before == " " || before == "-" || before == "_" || before == "/" || before == "\\" || before == "." || before == ":" || before == "(" {
                    points += 6
                } else if haystack[index].isUppercase && before.isLowercase {
                    points += 4
                }
            }
            score += points
            previousMatch = index
            searchFrom = index + 1
        }
        if lower.starts(with: needle) { score += 10 }
        score -= (firstMatch ?? 0)
        score -= max(0, haystack.count - needle.count) / 8
        return score
    }

    /// Best score across several fields (e.g. title and subtitle); the first field counts more.
    public static func score(_ query: String, fields: [String]) -> Int? {
        var best: Int?
        for (index, field) in fields.enumerated() {
            guard let value = score(query, field) else { continue }
            let weighted = index == 0 ? value + 3 : value
            best = max(best ?? weighted, weighted)
        }
        return best
    }
}
