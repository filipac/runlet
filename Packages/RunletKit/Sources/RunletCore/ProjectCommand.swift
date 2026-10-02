import Foundation

/// A command a project offers: an Artisan or `bin/console` command, an extra command from a
/// `.runlet` project driver, or a Composer script. Listed by the runner's `commands` mode
/// (which boots the project like a run) and run in a terminal, never by the runner itself.
public struct ProjectCommand: Sendable, Codable, Hashable, Identifiable {
    public enum Origin: String, Sendable, Codable {
        /// From the driver's `commands()` (built-in or project driver).
        case driver
        /// A `scripts` entry in composer.json.
        case composer
    }

    /// Name shown in the list, e.g. "migrate:status" or "test".
    public var name: String
    public var description: String?
    /// Shell command line run in the project's working directory (inside the container for
    /// Docker targets), e.g. "php artisan migrate:status" or "composer run-script test".
    public var commandLine: String
    /// Namespace or driver-chosen group ("migrate", "make", "composer"); nil for top-level commands.
    public var group: String?
    public var origin: Origin
    /// The driver that listed it ("Laravel", "AcmeApiDriver") or "Composer".
    public var source: String

    public var id: String { origin.rawValue + ":" + name }

    public init(name: String, description: String? = nil, commandLine: String, group: String? = nil, origin: Origin, source: String) {
        self.name = name
        self.description = description
        self.commandLine = commandLine
        self.group = group
        self.origin = origin
        self.source = source
    }

    /// True when every whitespace-separated token of `query` occurs (case-insensitively) in
    /// the name, group, description, or command line.
    public func matches(_ query: String) -> Bool {
        let tokens = query.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return true }
        let haystack = [name, group ?? "", description ?? "", commandLine].joined(separator: "\n")
        return tokens.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

/// Everything one `commands` request returned for a target.
public struct ProjectCommandCatalog: Sendable, Equatable {
    /// Driver commands first (in the driver's order), then Composer scripts.
    public var commands: [ProjectCommand]
    public var framework: String?
    public var frameworkVersion: String?
    /// Display name of the driver that booted the project.
    public var driverName: String?
    /// The `.runlet/` driver file, when a project driver booted the project.
    public var driverFile: String?
    public var phpVersion: String?
    public var workingDirectory: String?
    /// True when the driver listed its commands. False when the project could not boot (or
    /// `commands()` failed): then only Composer scripts are present and `errors` says why.
    public var driverListed: Bool
    public var errors: [RunErrorInfo]
    public var notices: [String]
    /// How the runner process ended.
    public var finished: FinishedInfo?
    public var loadedAt: Date

    public init(commands: [ProjectCommand] = [], framework: String? = nil, frameworkVersion: String? = nil, driverName: String? = nil, driverFile: String? = nil, phpVersion: String? = nil, workingDirectory: String? = nil, driverListed: Bool = false, errors: [RunErrorInfo] = [], notices: [String] = [], finished: FinishedInfo? = nil, loadedAt: Date = Date()) {
        self.commands = commands
        self.framework = framework
        self.frameworkVersion = frameworkVersion
        self.driverName = driverName
        self.driverFile = driverFile
        self.phpVersion = phpVersion
        self.workingDirectory = workingDirectory
        self.driverListed = driverListed
        self.errors = errors
        self.notices = notices
        self.finished = finished
        self.loadedAt = loadedAt
    }

    /// A titled section of the Commands list.
    public struct Group: Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var origin: ProjectCommand.Origin
        public var commands: [ProjectCommand]
    }

    /// Commands matching `query`, grouped for display: the driver's top-level commands
    /// (titled with the driver name), then its namespaces alphabetically, then Composer scripts.
    public func groups(matching query: String = "") -> [Group] {
        var order: [String] = []
        var groups: [String: Group] = [:]
        for command in commands where command.matches(query) {
            let key = command.origin.rawValue + ":" + (command.group ?? "")
            if groups[key] == nil {
                order.append(key)
                let title: String
                switch (command.origin, command.group) {
                case (.composer, _): title = "Composer scripts"
                case (.driver, nil): title = command.source
                case (.driver, let group?): title = group
                }
                groups[key] = Group(id: key, title: title, origin: command.origin, commands: [])
            }
            groups[key]?.commands.append(command)
        }
        return order.compactMap { groups[$0] }.sorted { lhs, rhs in
            let left = (lhs.origin == .composer ? 1 : 0, lhs.id.hasSuffix(":") ? 0 : 1)
            let right = (rhs.origin == .composer ? 1 : 0, rhs.id.hasSuffix(":") ? 0 : 1)
            if left != right { return left < right }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }
}
