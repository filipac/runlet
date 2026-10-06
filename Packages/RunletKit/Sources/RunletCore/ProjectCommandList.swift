import Foundation

/// What the Commands pane's list shows (#320): the catalog's groups for the filter, which are
/// expanded, and which commands are launching, as plain values. The pane builds it on each
/// render and redraws the list only when it differs from the last one, so nothing else in the
/// window (the pane's header and focus, runs, other tabs on the same target, the REPL or tests
/// launching) makes SwiftUI update the list's rows, which moves its scroller and scroll position.
public struct ProjectCommandList: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public var command: ProjectCommand
        /// The command is starting in a terminal tab (its row shows progress instead of ▶).
        public var isLaunching: Bool

        public var id: ProjectCommand.ID { command.id }
    }

    public struct Section: Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        /// How many commands the group has (shown in its header, also when it's collapsed).
        public var count: Int
        public var isExpanded: Bool
        public var rows: [Row]
    }

    public var sections: [Section]
    /// The filter isn't empty: every section is expanded.
    public var isSearching: Bool

    /// - Parameters:
    ///   - collapsed: The ids of the groups the user collapsed.
    ///   - launching: What is launching: command ids, and other keys (the REPL's, the tests'),
    ///     which don't change the list.
    public init(catalog: ProjectCommandCatalog, search: String, collapsed: Set<String>, launching: Set<String>) {
        let searching = !search.trimmingCharacters(in: .whitespaces).isEmpty
        isSearching = searching
        sections = catalog.groups(matching: search).map { group in
            Section(id: group.id, title: group.title, count: group.commands.count, isExpanded: searching || !collapsed.contains(group.id),
                    rows: group.commands.map { Row(command: $0, isLaunching: launching.contains($0.id)) })
        }
    }

    /// The listed command with this id.
    public func command(_ id: ProjectCommand.ID?) -> ProjectCommand? {
        guard let id else { return nil }
        for section in sections {
            if let row = section.rows.first(where: { $0.id == id }) { return row.command }
        }
        return nil
    }
}
