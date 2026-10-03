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

/// Palette search text. Open Anything scopes its search with a prefix (`/` local projects,
/// `@` Docker profiles, `#` snippets, `!` history); `>` switches to commands.
public enum PaletteQuery {
    public static let prefixes: Set<Character> = [">", "/", "@", "#", "!"]

    /// The search text kept when the palette switches between Open Anything and commands: what
    /// was typed, without a leading prefix (which means nothing in the other mode).
    public static func carriedOver(_ text: String) -> String {
        var rest = Substring(text)
        if let first = rest.first, prefixes.contains(first) { rest = rest.dropFirst() }
        return String(rest.drop { $0.isWhitespace })
    }

    /// Whether every word of `query` names one of `words`: the whole word, or at least its first
    /// three letters ("dar" for dark). Open Anything lists a few commands, such as the Appearance
    /// ones (#135), only for such a query, so its plain results stay targets, snippets, and files.
    public static func names(_ query: String, oneOf words: [String]) -> Bool {
        let tokens = query.lowercased().split { !$0.isLetter }
        guard !tokens.isEmpty else { return false }
        return tokens.allSatisfy { token in
            words.contains { word in
                let word = word.lowercased()
                return word.hasPrefix(token) && (token.count >= 3 || token.count == word.count)
            }
        }
    }
}

/// Fuzzy matching for palettes. The query is split into words and every word must match one
/// field. In the first field (a title) a word matches as a prefix, the start of a word, a
/// substring, or as pieces that each start a later word ("vt" → Vertical Tabs, "mdp" → Manage
/// Docker Profiles); in the other fields (subtitles, keywords) only as the start of a word or a
/// substring, never as letters scattered across unrelated words. Higher scores are better, and
/// title matches outrank the rest.
public enum FuzzyMatch {
    public static func score(_ query: String, _ candidate: String) -> Int? {
        score(query, fields: [candidate])
    }

    public static func score(_ query: String, fields: [String]) -> Int? {
        let tokens = query.split(whereSeparator: \.isWhitespace).map { Array($0.lowercased()) }
        guard !tokens.isEmpty else { return 0 }
        let prepared = fields.map(Field.init)
        var total = 0
        for token in tokens {
            var best: Int?
            for (index, field) in prepared.enumerated() {
                guard let value = index == 0 ? field.titleScore(token) : field.detailScore(token) else { continue }
                best = max(best ?? value, value)
            }
            guard let best else { return nil }
            total += best
        }
        // Shorter titles first among equal matches.
        return total - (fields.first?.count ?? 0) / 16
    }

    private struct Field {
        let lower: [Character]
        /// Start and end of every word: runs of letters and digits, also split at camelCase.
        let words: [Range<Int>]

        init(_ text: String) {
            let characters = Array(text)
            lower = characters.map { $0.lowercased().first ?? $0 }
            var words: [Range<Int>] = []
            var start: Int?
            for (index, character) in characters.enumerated() {
                let isWordCharacter = character.isLetter || character.isNumber
                let isBoundary = index > 0 && character.isUppercase && characters[index - 1].isLowercase
                if let current = start, !isWordCharacter || isBoundary {
                    words.append(current..<index)
                    start = nil
                }
                if isWordCharacter && start == nil { start = index }
            }
            if let start { words.append(start..<characters.count) }
            self.words = words
        }

        func titleScore(_ token: [Character]) -> Int? {
            if lower.starts(with: token) { return token.count == lower.count ? 110 : 100 }
            if let word = wordStarting(with: token) { return max(62, 80 - 3 * word) }
            if let skipped = wordPieces(token) { return max(52, 60 - 4 * skipped) }
            if let position = position(of: token) { return max(40, 50 - position / 2) }
            return nil
        }

        func detailScore(_ token: [Character]) -> Int? {
            if let word = wordStarting(with: token) { return max(20, 30 - word) }
            return position(of: token) == nil ? nil : 15
        }

        /// The first word that starts with `token` (which may run on past the word's end).
        private func wordStarting(with token: [Character]) -> Int? {
            words.firstIndex { lower[$0.lowerBound...].starts(with: token) }
        }

        private func position(of token: [Character]) -> Int? {
            guard !token.isEmpty, token.count <= lower.count else { return nil }
            return (0...(lower.count - token.count)).first { lower[$0..<($0 + token.count)].elementsEqual(token) }
        }

        /// `token` split into pieces that each start a later word; the fewest words skipped.
        private func wordPieces(_ token: [Character]) -> Int? {
            var memo: [Int: Int?] = [:]
            func best(_ matched: Int, from first: Int) -> Int? {
                if matched == token.count { return 0 }
                let key = matched * (words.count + 1) + first
                if let known = memo[key] { return known }
                var result: Int?
                for word in words.indices.dropFirst(first) {
                    var length = 0
                    while matched + length < token.count, words[word].lowerBound + length < words[word].upperBound,
                          lower[words[word].lowerBound + length] == token[matched + length] {
                        length += 1
                        if let rest = best(matched + length, from: word + 1) {
                            result = min(result ?? .max, rest + word - first)
                        }
                    }
                }
                memo[key] = result
                return result
            }
            return best(0, from: 0)
        }
    }
}
