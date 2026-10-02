import Foundation

/// A command a project offers: an Artisan or `bin/console` command, an extra command from a
/// `.runlet` project driver, a host command (run on this Mac), or a Composer script. Listed by
/// the runner's `commands` mode (which boots the project like a run) and by host command
/// sources, and run in a terminal, never by the runner itself.
public struct ProjectCommand: Sendable, Codable, Hashable, Identifiable {
    public enum Origin: String, Sendable, Codable {
        /// From the driver's `commands()` (built-in or project driver).
        case driver
        /// From the driver's `hostCommands()`: runs on this Mac in the project's local folder,
        /// also for Docker targets.
        case host
        /// A `scripts` entry in composer.json.
        case composer
    }

    /// Name shown in the list, e.g. "migrate:status" or "test".
    public var name: String
    public var description: String?
    /// Shell command line run in the project's working directory (inside the container for
    /// Docker targets; on this Mac for host commands), e.g. "php artisan migrate:status" or
    /// "composer run-script test".
    public var commandLine: String
    /// Namespace or driver-chosen group ("migrate", "make", "composer"); nil for top-level commands.
    public var group: String?
    public var origin: Origin
    /// The driver that listed it ("Laravel", "AcmeApiDriver"), the host command source
    /// ("biker"), or "Composer".
    public var source: String
    /// The command has required arguments: it is typed into the terminal without running,
    /// so the user can complete it.
    public var needsInput: Bool

    public var id: String { origin.rawValue + ":" + (origin == .host ? source + ":" : "") + name }

    public init(name: String, description: String? = nil, commandLine: String, group: String? = nil, origin: Origin, source: String, needsInput: Bool = false) {
        self.name = name
        self.description = description
        self.commandLine = commandLine
        self.group = group
        self.origin = origin
        self.source = source
        self.needsInput = needsInput
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

/// A tool on this Mac that lists commands for a project folder, declared by a driver's
/// `hostCommands()` (e.g. `'biker' => ['list' => 'biker runlet:commands']`). Runlet runs
/// `listCommand` in the project's local folder each time the commands load.
public struct HostCommandSource: Sendable, Codable, Hashable {
    public enum Format: String, Sendable, Codable {
        /// `{"commands": [{"name", "command", "description"?, "group"?, "needsInput"?}]}`.
        case runlet
        /// Symfony Console `list --format=json`; commands run as `<console> <name>`.
        case symfony
    }

    /// Key in `hostCommands()`, also the group title for its ungrouped commands.
    public var name: String
    public var format: Format
    /// Shell command line that prints the list.
    public var listCommand: String
    /// The console invocation for `.symfony` sources ("biker", "php artisan").
    public var console: String?
    public var description: String?

    public init(name: String, format: Format, listCommand: String, console: String? = nil, description: String? = nil) {
        self.name = name
        self.format = format
        self.listCommand = listCommand
        self.console = console
        self.description = description
    }
}

/// A driver's `hostCommands()`: static host commands and command sources.
public struct HostCommandDeclaration: Sendable, Codable, Equatable {
    public var sources: [HostCommandSource]
    public var commands: [ProjectCommand]

    public init(sources: [HostCommandSource] = [], commands: [ProjectCommand] = []) {
        self.sources = sources
        self.commands = commands
    }

    public var isEmpty: Bool { sources.isEmpty && commands.isEmpty }
}

/// Everything one `commands` request returned for a target.
public struct ProjectCommandCatalog: Sendable, Equatable {
    /// Driver commands first (in the driver's order), then host commands, then Composer scripts.
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
    /// Host command sources the driver declared (their commands are in `commands` once listed).
    public var hostSources: [HostCommandSource]
    /// Static host commands the driver declared, before any source was listed.
    public var hostCommands: [ProjectCommand]
    /// True when the driver's host declarations came from this load (false: none were
    /// reported, e.g. the target could not start, so the app may reuse earlier ones).
    public var hostDeclared: Bool
    /// The folder on this Mac where host commands run (nil: none is known, e.g. a Docker
    /// profile without a local source folder).
    public var hostDirectory: String?
    /// Host command sources that listed nothing, with the reason.
    public var hostErrors: [String] = []

    public init(commands: [ProjectCommand] = [], framework: String? = nil, frameworkVersion: String? = nil, driverName: String? = nil, driverFile: String? = nil, phpVersion: String? = nil, workingDirectory: String? = nil, driverListed: Bool = false, errors: [RunErrorInfo] = [], notices: [String] = [], finished: FinishedInfo? = nil, loadedAt: Date = Date(), hostSources: [HostCommandSource] = [], hostCommands: [ProjectCommand] = [], hostDeclared: Bool = false, hostDirectory: String? = nil) {
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
        self.hostSources = hostSources
        self.hostCommands = hostCommands
        self.hostDeclared = hostDeclared
        self.hostDirectory = hostDirectory
    }

    /// A titled section of the Commands list.
    public struct Group: Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var origin: ProjectCommand.Origin
        public var commands: [ProjectCommand]
    }

    /// Commands matching `query`, grouped for display: the driver's top-level commands
    /// (titled with the driver name), then its namespaces alphabetically, then host commands
    /// (by source, then group), then Composer scripts.
    public func groups(matching query: String = "") -> [Group] {
        var order: [String] = []
        var groups: [String: Group] = [:]
        for command in commands where command.matches(query) {
            let key = command.origin == .host
                ? "host:" + command.source + ":" + (command.group ?? "")
                : command.origin.rawValue + ":" + (command.group ?? "")
            if groups[key] == nil {
                order.append(key)
                let title: String
                switch (command.origin, command.group) {
                case (.composer, _): title = "Composer scripts"
                case (.driver, nil), (.host, nil): title = command.source
                case (.driver, let group?), (.host, let group?): title = group
                }
                groups[key] = Group(id: key, title: title, origin: command.origin, commands: [])
            }
            groups[key]?.commands.append(command)
        }
        func rank(_ origin: ProjectCommand.Origin) -> Int {
            switch origin {
            case .driver: 0
            case .host: 1
            case .composer: 2
            }
        }
        // Host groups keep their listing order (a source's own grouping); driver namespaces sort.
        return order.enumerated().compactMap { index, key in groups[key].map { (index, $0) } }.sorted { lhs, rhs in
            let left = (rank(lhs.1.origin), lhs.1.origin != .host && !lhs.1.id.hasSuffix(":") ? 1 : 0)
            let right = (rank(rhs.1.origin), rhs.1.origin != .host && !rhs.1.id.hasSuffix(":") ? 1 : 0)
            if left != right { return left < right }
            if lhs.1.origin == .host { return lhs.0 < rhs.0 }
            return lhs.1.title.localizedStandardCompare(rhs.1.title) == .orderedAscending
        }.map(\.1)
    }
}
