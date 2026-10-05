/// The tab context menu (#214), shared by the tab bar and the vertical tabs, so both show the
/// same items and a new tab language appears in both.
public enum TabMenuItem: Hashable, Sendable {
    case rename, duplicate
    /// Pin Tab or Unpin Tab (#279), whichever the tab needs.
    case pin, unpin
    /// Switch to another language: one item for each language but the tab's own.
    case switchLanguage(TabLanguage)
    case divider, close, closeOthers

    /// Rename…, Duplicate, Pin Tab (Unpin Tab for a pinned tab), Switch to … for every other
    /// language (in `TabLanguage.allCases` order), then Close and Close Other Tabs.
    public static func items(for language: TabLanguage, pinned: Bool = false) -> [TabMenuItem] {
        [.rename, .duplicate, pinned ? .unpin : .pin]
            + TabLanguage.allCases.filter { $0 != language }.map(TabMenuItem.switchLanguage)
            + [.divider, .close, .closeOthers]
    }

    public var title: String {
        switch self {
        case .rename: "Rename…"
        case .duplicate: "Duplicate"
        case .pin: "Pin Tab"
        case .unpin: "Unpin Tab"
        case .switchLanguage(let language): "Switch to \(language.displayName)"
        case .divider: ""
        case .close: "Close"
        case .closeOthers: "Close Other Tabs"
        }
    }
}
