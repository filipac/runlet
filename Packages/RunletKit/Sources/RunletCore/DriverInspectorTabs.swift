import Foundation

/// A tab a project driver adds to the inspector with `inspectorTabs()`: rows that a command on
/// this Mac lists, each with a long-running command the tab starts and stops in a terminal.
/// Both commands run in the project's local folder, like host commands.
public struct DriverInspectorTab: Sendable, Codable, Hashable, Identifiable {
    /// Unique within the driver.
    public var id: String
    public var title: String
    /// An SF Symbol name, if the driver chose one.
    public var icon: String?
    /// Prints `{"items": [{"id", "title", "subtitle"?, "badge"?}], "message"?}`.
    public var listCommand: String
    /// Started per row; `{id}` stands for the row's id, shell-quoted.
    public var runCommand: String
    /// Shown when the list has no items.
    public var emptyText: String?

    public init(id: String, title: String, icon: String? = nil, listCommand: String, runCommand: String, emptyText: String? = nil) {
        self.id = id
        self.title = title
        self.icon = icon
        self.listCommand = listCommand
        self.runCommand = runCommand
        self.emptyText = emptyText
    }

    /// The icon to show: the driver's, or a generic one.
    public var symbol: String { icon ?? "rectangle.stack" }
}

/// What a tab's list command printed.
public struct DriverInspectorTabListing: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Hashable, Identifiable {
        public var id: String
        public var title: String
        public var subtitle: String?
        public var badge: String?

        public init(id: String, title: String, subtitle: String? = nil, badge: String? = nil) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.badge = badge
        }
    }

    public var items: [Item]
    public var message: String?
    /// Entries Runlet ignored (no id, an id used twice), described for a notice.
    public var skipped: [String]
    public var loadedAt: Date

    public init(items: [Item] = [], message: String? = nil, skipped: [String] = [], loadedAt: Date = Date()) {
        self.items = items
        self.message = message
        self.skipped = skipped
        self.loadedAt = loadedAt
    }

    /// The listing in one JSON object, or nil when it isn't one (`items` must be an array).
    /// Ids and badges may be strings or numbers; an item without an id, or with an id used
    /// before, is skipped and named in `skipped`. A missing title is the id.
    public static func decode(_ object: Data, loadedAt: Date = Date()) -> DriverInspectorTabListing? {
        guard let root = try? JSONSerialization.jsonObject(with: object) as? [String: Any],
              let entries = root["items"] as? [Any] else { return nil }
        var listing = DriverInspectorTabListing(loadedAt: loadedAt)
        listing.message = text(root["message"])
        var seen = Set<String>()
        for (index, entry) in entries.enumerated() {
            guard let fields = entry as? [String: Any], let id = text(fields["id"]) else {
                listing.skipped.append("item \(index + 1) (no id)")
                continue
            }
            guard seen.insert(id).inserted else {
                listing.skipped.append("\(id) (the id is used twice)")
                continue
            }
            listing.items.append(Item(id: id, title: text(fields["title"]) ?? id, subtitle: text(fields["subtitle"]), badge: text(fields["badge"])))
        }
        return listing
    }

    /// A trimmed, non-empty string, or a number written as text.
    private static func text(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            // JSON booleans decode as NSNumber too; they are no id or badge.
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.stringValue
        default:
            return nil
        }
    }
}

/// The `inspectorTabs()` each target's project driver declared on its last command listing,
/// kept across launches (in facts.json) so its tabs show without listing the project's
/// commands again. Keyed by `TargetRef.stableKey`.
public struct DriverInspectorTabMemory: Codable, Equatable, Sendable {
    /// Target key → the tabs the driver declared, maybe none (it declared that it has none).
    public var tabs: [String: [DriverInspectorTab]]

    public init(tabs: [String: [DriverInspectorTab]] = [:]) {
        self.tabs = tabs
    }

    /// Remembers what a fresh listing declared. Returns whether anything changed (to save).
    /// A listing that didn't reach the driver's `inspectorTabs()` changes nothing.
    @discardableResult
    public mutating func remember(_ catalog: ProjectCommandCatalog, for key: String) -> Bool {
        guard catalog.inspectorTabsDeclared, tabs[key] != catalog.inspectorTabs else { return false }
        tabs[key] = catalog.inspectorTabs
        return true
    }

    /// The driver's tabs for a target: the loaded listing's when it declared them, else the
    /// remembered ones.
    public func tabs(for key: String, loaded catalog: ProjectCommandCatalog?) -> [DriverInspectorTab] {
        if let catalog, catalog.inspectorTabsDeclared { return catalog.inspectorTabs }
        return tabs[key] ?? []
    }

    /// Whether Runlet knows what the target's driver declares (loaded now, or remembered).
    public func knows(_ key: String, loaded catalog: ProjectCommandCatalog?) -> Bool {
        catalog?.inspectorTabsDeclared == true || tabs[key] != nil
    }

    /// Forgets a target (it was removed).
    public mutating func forget(_ key: String) {
        tabs[key] = nil
    }
}
