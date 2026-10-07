import Foundation

// Shortcut tips (#345): a command that has a keyboard shortcut, run with the mouse or from the
// palette, shows its shortcut in a small tip. The app counts how each command was run and asks
// `ShortcutTipRule` whether to show a tip; it never decides on its own.

/// Where a command came from.
public enum CommandSource: String, Sendable, Codable, CaseIterable {
    /// Its keyboard shortcut (a menu item's key equivalent).
    case keyboard
    /// A click on its menu item.
    case menu
    /// A button in the window's toolbar.
    case toolbar
    /// A button elsewhere in a window: a pane's header, the tab bar, the terminal panel.
    case button
    /// Open Anything or the command palette.
    case palette
    /// A debug step or a tour: never counted, never a tip.
    case script

    /// Whether a use from here is counted.
    public var isCounted: Bool { self != .script }

    /// Whether a use from here can show a tip: the mouse or the palette, never the keyboard.
    public var showsTips: Bool {
        switch self {
        case .menu, .toolbar, .button, .palette: true
        case .keyboard, .script: false
        }
    }
}

/// How each command was run, by source, and its shortcut tips (#345), in
/// `State/shortcut-tips.json`, beside the palette's usage record (#328). Per user, and only
/// command ids, counts, when a tip was last shown, and Don't Show Again: no arguments, code, or
/// targets.
public struct ShortcutTipRecord: Sendable, Codable, Equatable {
    public struct Entry: Sendable, Codable, Equatable {
        /// Uses by source (`CommandSource.rawValue`). Sources this Runlet doesn't know are kept.
        public var uses: [String: Int]
        /// When a tip was last shown for the command.
        public var lastTip: Date?
        /// The user chose Don't Show Again on its tip.
        public var tipDismissed: Bool

        public init(uses: [String: Int] = [:], lastTip: Date? = nil, tipDismissed: Bool = false) {
            self.uses = uses
            self.lastTip = lastTip
            self.tipDismissed = tipDismissed
        }

        public init(from decoder: Decoder) throws {
            // Tolerate missing or damaged keys, so older and newer files keep loading.
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uses = ((try? c.decode([String: Int].self, forKey: .uses)) ?? [:]).filter { $0.value > 0 }
            lastTip = try? c.decodeIfPresent(Date.self, forKey: .lastTip)
            tipDismissed = (try? c.decode(Bool.self, forKey: .tipDismissed)) ?? false
        }

        /// How many times the command came from `source`.
        public func count(_ source: CommandSource) -> Int { uses[source.rawValue] ?? 0 }
    }

    /// By command id.
    public private(set) var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // One damaged entry is left out rather than losing the others.
        var entries: [String: Entry] = [:]
        if let nested = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: .entries) {
            for key in nested.allKeys {
                if let entry = try? nested.decode(Entry.self, forKey: key) { entries[key.stringValue] = entry }
            }
        }
        self.entries = entries
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// The entry for `id`, empty for a command never counted.
    public func entry(_ id: String) -> Entry { entries[id] ?? Entry() }

    /// Counts one use of `id` from `source` (a script's isn't counted), and when `tipShown`, that
    /// its tip was shown then.
    public mutating func record(_ id: String, source: CommandSource, tipShown: Date? = nil) {
        guard source.isCounted || tipShown != nil else { return }
        var entry = entry(id)
        if source.isCounted {
            let count = entry.count(source)
            entry.uses[source.rawValue] = count == .max ? count : count + 1
        }
        if let tipShown { entry.lastTip = tipShown }
        entries[id] = entry
    }

    /// Don't Show Again: the command's tip never shows again.
    public mutating func dismissTip(_ id: String) {
        var entry = entry(id)
        entry.tipDismissed = true
        entries[id] = entry
    }

    /// Drops ids that aren't in `known` (commands removed from the catalog).
    public mutating func prune(keeping known: Set<String>) {
        entries = entries.filter { known.contains($0.key) }
    }
}

extension AppPaths {
    /// How commands were run and their shortcut tips (#345).
    public var shortcutTips: URL { state.appendingPathComponent("shortcut-tips.json") }
}

/// Whether a command run with the mouse or from the palette shows a tip with its shortcut (#345).
///
/// - Only a click (a menu item, a toolbar or window button) or the palette shows one, and only
///   for a command that has a shortcut, as the user mapped it.
/// - At most one tip per command a day (`interval`), so clicking the same button all afternoon
///   shows it once.
/// - Never again for a command once its shortcut was used `learnedAfter` times, or after Don't
///   Show Again on its tip.
/// - Never with Settings ▸ General ▸ Tips ▸ Show shortcut tips off.
public enum ShortcutTipRule {
    /// Shortcut uses after which a command's tip stops for good. Three: once could be a
    /// coincidence (a key pressed for something else, the menu's key equivalent tried once);
    /// by the third the shortcut is a habit, and a tip would only be in the way.
    public static let learnedAfter = 3
    /// The least time between two tips for one command: a day. A button clicked all day long
    /// gets one reminder, and the next working day another, until the shortcut sticks.
    public static let interval: TimeInterval = 24 * 60 * 60

    public enum Decision: String, Sendable, Equatable {
        /// Show the tip.
        case show
        /// Shortcut tips are turned off.
        case turnedOff
        /// The command came from the keyboard or a script.
        case notClicked
        /// The command has no shortcut, or the user removed it.
        case noShortcut
        /// The shortcut was used `learnedAfter` times.
        case learned
        /// Don't Show Again.
        case dismissed
        /// A tip for the command was shown less than `interval` ago (or the clock went back).
        case shownRecently
    }

    /// Whether to show a tip for a command run from `source` at `now`, given its `shortcut` (the
    /// effective one; nil when it has none) and what `entry` counted before this use.
    public static func decide(source: CommandSource, shortcut: KeyCombo?, entry: ShortcutTipRecord.Entry,
                              enabled: Bool, now: Date) -> Decision {
        guard enabled else { return .turnedOff }
        guard source.showsTips else { return .notClicked }
        guard shortcut != nil else { return .noShortcut }
        if entry.tipDismissed { return .dismissed }
        if entry.count(.keyboard) >= learnedAfter { return .learned }
        if let last = entry.lastTip, now.timeIntervalSince(last) < interval { return .shownRecently }
        return .show
    }
}

/// What a shortcut tip says (#345): made from the command's title, so there is no copy to keep
/// for each command.
public enum ShortcutTipText {
    /// "⌃⌘T is the shortcut for Toggle Vertical Tabs. It saves a trip to the toolbar."
    public static func sentence(keys: String, title: String, source: CommandSource) -> String {
        "\(keys) is the shortcut for \(commandName(title)). \(benefit(source))"
    }

    /// The command's name as the palette shows it, without a trailing ellipsis.
    public static func commandName(_ title: String) -> String {
        var name = title.trimmingCharacters(in: .whitespaces)
        for suffix in ["…", "..."] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return name
    }

    /// What the shortcut saves, after where the command came from.
    public static func benefit(_ source: CommandSource) -> String {
        switch source {
        case .menu: "It saves a trip to the menu bar."
        case .toolbar: "It saves a trip to the toolbar."
        case .palette: "It skips the palette."
        case .button, .keyboard, .script: "It keeps your hands on the keyboard."
        }
    }
}

extension KeyCombo {
    /// The keys one by one, for key caps: the modifiers in menu order (⌃⌥⇧⌘), then the key.
    public var displayKeys: [String] {
        modifiers.sorted().map(\.symbol) + [Self.namedKeys[key] ?? key.uppercased()]
    }
}
