import Foundation

/// Renaming a tab (#285), the same in the tab bar, the vertical tabs, and pinned tabs in both:
/// the field opens with the whole title selected, so typing replaces it. Return commits, Esc
/// cancels, and the field losing the keyboard (a click elsewhere) commits, as in Finder. An
/// empty or whitespace-only name keeps the old title.
public enum TabRename {
    /// How a rename ended.
    public enum End: String, Sendable, Equatable {
        /// Return (or Tab): the typed name.
        case commit
        /// Esc: the old title stays.
        case cancel
        /// The keyboard went elsewhere (a click on the editor, another tab…): commits, like Finder.
        case focusLost
    }

    /// The title a rename ending this way gives the tab, or nil when the tab keeps its title:
    /// Esc, an empty or whitespace-only name, or the same name. The name is trimmed.
    public static func newTitle(after end: End, text: String, current: String) -> String? {
        guard end != .cancel else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == current ? nil : trimmed
    }

    /// AppKit's text movement codes (`NSTextMovement`), which say why a field's editing ended.
    public enum TextMovement {
        public static let other = 0
        public static let `return` = 0x10
        public static let tab = 0x11
        public static let backtab = 0x12
        public static let cancel = 0x17
    }

    /// How a rename ends when its field's editing ended with `movement`: Return, Tab, and ⇧Tab
    /// commit, Esc cancels, and anything else means the field lost the keyboard, which commits.
    public static func end(forTextMovement movement: Int) -> End {
        switch movement {
        case TextMovement.return, TextMovement.tab, TextMovement.backtab: .commit
        case TextMovement.cancel: .cancel
        default: .focusLost
        }
    }

    /// How long after the field takes the keyboard it takes it back from code that grabs it
    /// (a closing palette or a tab's editor giving the keyboard back) instead of committing.
    public static let reclaimSeconds: TimeInterval = 1

    /// Whether a field that just lost the keyboard takes it back instead of ending the rename:
    /// only within `reclaimSeconds` of taking it, and only when no click or key press of the
    /// user's since then moved it.
    public static func reclaimsFocus(secondsSinceFocused: TimeInterval, byUser: Bool) -> Bool {
        !byUser && secondsSinceFocused >= 0 && secondsSinceFocused < reclaimSeconds
    }

    public static let searchWords = ["rename", "renaming"]

    /// Whether Open Anything (⌘P) should list Rename Tab… for `query`, as it lists Pin Tab for
    /// "pin": one of its words names renaming ("ren…"), and the rest name renaming or a tab.
    public static func paletteMatches(_ query: String) -> Bool {
        let tokens = query.lowercased().split { !$0.isLetter }.map(String.init)
        guard tokens.contains(where: { PaletteQuery.names($0, oneOf: searchWords) }) else { return false }
        return PaletteQuery.names(query, oneOf: searchWords + ["tab", "tabs", "title"])
    }
}
