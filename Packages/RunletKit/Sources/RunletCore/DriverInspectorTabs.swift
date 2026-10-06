import Foundation

/// A tab a project driver adds to the inspector with `inspectorTabs()`: rows that a command on
/// this Mac or a PHP callable in the driver lists, each with a long-running command the tab
/// starts and stops in a terminal. Commands run in the project's local folder, like host
/// commands.
public struct DriverInspectorTab: Sendable, Codable, Hashable, Identifiable {
    /// Where the rows come from.
    public enum ListSource: Sendable, Hashable {
        /// A command on this Mac that prints `{"items": [{"id", "title", "subtitle"?,
        /// "badge"?}], "message"?}`.
        case host(command: String)
        /// A PHP callable in the driver: the runner boots the project and calls it.
        case driver
    }

    /// A choice of rows above the list: the rows tagged `tag`, or every row (no tag).
    public struct Filter: Sendable, Codable, Hashable, Identifiable {
        public var id: String
        public var title: String
        public var tag: String?
        /// The filter the tab starts on (else the first one).
        public var isDefault: Bool

        public init(id: String, title: String, tag: String? = nil, isDefault: Bool = false) {
            self.id = id
            self.title = title
            self.tag = tag
            self.isDefault = isDefault
        }

        /// Whether the filter shows `item`.
        public func includes(_ item: DriverInspectorTabListing.Item) -> Bool {
            tag.map(item.tags.contains) ?? true
        }

        private enum CodingKeys: String, CodingKey { case id, title, tag, isDefault = "default" }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            title = try container.decode(String.self, forKey: .title)
            tag = try container.decodeIfPresent(String.self, forKey: .tag)
            isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(title, forKey: .title)
            try container.encodeIfPresent(tag, forKey: .tag)
            if isDefault { try container.encode(true, forKey: .isDefault) }
        }
    }

    /// Unique within the driver.
    public var id: String
    public var title: String
    /// An SF Symbol name, if the driver chose one.
    public var icon: String?
    public var list: ListSource
    /// Started per row; `{id}` stands for the row's id, shell-quoted.
    public var runCommand: String
    /// Shown when the list has no items.
    public var emptyText: String?
    /// The filters above the list (none: every row shows).
    public var filters: [Filter]

    public init(id: String, title: String, icon: String? = nil, list: ListSource, runCommand: String, emptyText: String? = nil, filters: [Filter] = []) {
        self.id = id
        self.title = title
        self.icon = icon
        self.list = list
        self.runCommand = runCommand
        self.emptyText = emptyText
        self.filters = filters
    }

    /// A tab whose rows a command on this Mac lists.
    public init(id: String, title: String, icon: String? = nil, listCommand: String, runCommand: String, emptyText: String? = nil, filters: [Filter] = []) {
        self.init(id: id, title: title, icon: icon, list: .host(command: listCommand), runCommand: runCommand, emptyText: emptyText, filters: filters)
    }

    /// The filter `id` names, else the default one (the one marked default, else the first);
    /// nil when the tab has no filters.
    public func filter(_ id: String?) -> Filter? {
        filters.first { $0.id == id } ?? filters.first(where: \.isDefault) ?? filters.first
    }

    /// The rows `filter` shows, in order: the items it includes, and every item in `active`
    /// (rows whose command runs) whatever the filter.
    public func visibleItems(_ items: [DriverInspectorTabListing.Item], filter: Filter?, active: Set<String> = []) -> [DriverInspectorTabListing.Item] {
        guard let filter else { return items }
        return items.filter { filter.includes($0) || active.contains($0.id) }
    }

    /// The list command, for a tab whose rows a command on this Mac lists.
    public var listCommand: String? {
        if case .host(let command) = list { return command }
        return nil
    }

    /// The icon to show: the driver's, or a generic one.
    public var symbol: String { icon ?? "rectangle.stack" }

    // facts.json: `list` is {"kind": "host", "command": …} or {"kind": "driver"}.
    private enum CodingKeys: String, CodingKey { case id, title, icon, list, runCommand, emptyText, filters, listCommand }
    private enum ListKeys: String, CodingKey { case kind, command }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        runCommand = try container.decode(String.self, forKey: .runCommand)
        emptyText = try container.decodeIfPresent(String.self, forKey: .emptyText)
        // Written before tabs had filters: none.
        filters = try container.decodeIfPresent([Filter].self, forKey: .filters) ?? []
        if let source = try? container.nestedContainer(keyedBy: ListKeys.self, forKey: .list),
           let kind = try source.decodeIfPresent(String.self, forKey: .kind) {
            if kind == "host", let command = try source.decodeIfPresent(String.self, forKey: .command) {
                list = .host(command: command)
            } else {
                list = .driver
            }
        } else {
            // Written before lists could be callables.
            list = .host(command: try container.decode(String.self, forKey: .listCommand))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encode(runCommand, forKey: .runCommand)
        try container.encodeIfPresent(emptyText, forKey: .emptyText)
        if !filters.isEmpty { try container.encode(filters, forKey: .filters) }
        var source = container.nestedContainer(keyedBy: ListKeys.self, forKey: .list)
        switch list {
        case .host(let command):
            try source.encode("host", forKey: .kind)
            try source.encode(command, forKey: .command)
        case .driver:
            try source.encode("driver", forKey: .kind)
        }
    }
}

/// What a tab's list printed or returned.
public struct DriverInspectorTabListing: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Hashable, Identifiable {
        public var id: String
        public var title: String
        public var subtitle: String?
        public var badge: String?
        /// What the tab's filters match.
        public var tags: [String]

        public init(id: String, title: String, subtitle: String? = nil, badge: String? = nil, tags: [String] = []) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.badge = badge
            self.tags = tags
        }
    }

    public var items: [Item]
    public var message: String?
    /// Entries Runlet ignored (no id, an id used twice), described for a notice.
    public var skipped: [String]
    /// What the runner noted about a driver callable's result (values it left out).
    public var notices: [String] = []
    public var loadedAt: Date

    public init(items: [Item] = [], message: String? = nil, skipped: [String] = [], notices: [String] = [], loadedAt: Date = Date()) {
        self.items = items
        self.message = message
        self.skipped = skipped
        self.notices = notices
        self.loadedAt = loadedAt
    }

    /// The listing in one JSON object, or nil when it isn't one (`items` must be an array).
    /// Ids, badges, and tags may be strings or numbers; an item without an id, or with an id used
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
            // A list of strings (or numbers); a single string is one tag.
            let rawTags = fields["tags"].map { ($0 as? [Any]) ?? [$0] } ?? []
            var tags: [String] = []
            for tag in rawTags.compactMap(text) where !tags.contains(tag) { tags.append(tag) }
            listing.items.append(Item(id: id, title: text(fields["title"]) ?? id, subtitle: text(fields["subtitle"]), badge: text(fields["badge"]), tags: tags))
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

    /// A target whose tabs can't be read (a newer Runlet wrote them) is left out, not the
    /// whole memory (facts.json would be set aside).
    public init(from decoder: Decoder) throws {
        struct Lenient: Decodable {
            var tab: DriverInspectorTab?
            init(from decoder: Decoder) throws { tab = try? DriverInspectorTab(from: decoder) }
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = (try? container.decode([String: [Lenient]].self, forKey: .tabs)) ?? [:]
        tabs = stored.mapValues { $0.compactMap(\.tab) }
    }

    private enum CodingKeys: String, CodingKey { case tabs }

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
