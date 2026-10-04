/// The tab context menu (#214), shared by the tab bar and the vertical tabs, so both show the
/// same items and a new tab language appears in both.
public enum TabMenuItem: Hashable, Sendable {
    case rename, duplicate
    /// Switch to another language: one item for each language but the tab's own.
    case switchLanguage(TabLanguage)
    case divider, close, closeOthers

    /// Rename…, Duplicate, Switch to … for every other language (in `TabLanguage.allCases`
    /// order), then Close and Close Other Tabs.
    public static func items(for language: TabLanguage) -> [TabMenuItem] {
        [.rename, .duplicate]
            + TabLanguage.allCases.filter { $0 != language }.map(TabMenuItem.switchLanguage)
            + [.divider, .close, .closeOthers]
    }

    public var title: String {
        switch self {
        case .rename: "Rename…"
        case .duplicate: "Duplicate"
        case .switchLanguage(let language): "Switch to \(language.displayName)"
        case .divider: ""
        case .close: "Close"
        case .closeOthers: "Close Other Tabs"
        }
    }
}
