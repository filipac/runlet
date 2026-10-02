import Foundation

/// What the `runlet` command-line tool asks Runlet to open. Opening never runs code.
public struct OpenRequest: Sendable, Codable, Equatable {
    public enum Item: Sendable, Codable, Equatable {
        /// A folder: saved as a local project (or the saved one reused) and opened in a tab.
        case folder(String)
        /// A file, opened in a tab whose edits save back to it.
        case file(String)
        /// A `.runlet` workspace, opened in its own window.
        case workspace(String)

        public var path: String {
            switch self {
            case .folder(let path), .file(let path), .workspace(let path): path
            }
        }
    }

    public var id: UUID
    /// Absolute paths, in command-line order.
    public var items: [Item]
    /// `--target`: the target for opened files, or for a new tab when nothing else is opened.
    /// Matched by the app against its saved targets (`TargetLibrary.target(matching:home:)`).
    public var target: String?
    /// `--new-window`
    public var newWindow: Bool
    /// The Runlet process the request is for: several copies of Runlet can run, and each
    /// one sees every request.
    public var recipient: Int32?

    public init(id: UUID = UUID(), items: [Item], target: String? = nil, newWindow: Bool = false, recipient: Int32? = nil) {
        self.id = id
        self.items = items
        self.target = target
        self.newWindow = newWindow
        self.recipient = recipient
    }

    /// JSON text, the form requests travel in (a launch argument or a notification's object).
    public var encoded: String {
        String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self)
    }

    public static func decode(_ text: String) -> OpenRequest? {
        try? JSONDecoder().decode(OpenRequest.self, from: Data(text.utf8))
    }
}

/// Runlet's answer to an `OpenRequest`, sent back to the waiting tool.
public struct OpenReply: Sendable, Codable, Equatable {
    public var id: UUID
    /// What could not be opened, as messages for the terminal; empty when everything opened.
    public var errors: [String]

    public init(id: UUID, errors: [String] = []) {
        self.id = id
        self.errors = errors
    }

    public var encoded: String {
        String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self)
    }

    public static func decode(_ text: String) -> OpenReply? {
        try? JSONDecoder().decode(OpenReply.self, from: Data(text.utf8))
    }
}

/// The `runlet` command-line tool: its arguments, and how it reaches the app.
///
/// The tool sends an `OpenRequest` to a running Runlet as a distributed notification (local
/// to the user's session) and waits for the `OpenReply`. When Runlet isn't running, the tool
/// launches it with the request as a launch argument. Requests only open things; nothing
/// runs until the user presses Run.
public enum CommandLineTool {
    public static let name = "runlet"
    public static let appBundleIdentifier = "dev.runlet.Runlet"
    /// Notification names. The request's or reply's JSON is the notification's object.
    public static let requestNotification = "dev.runlet.Runlet.cli.open"
    public static let replyNotification = "dev.runlet.Runlet.cli.opened"
    /// The launch argument that carries a request (followed by its JSON) when the tool starts Runlet.
    public static let launchArgument = "--runlet-open-request"
    /// Where the tool sits inside Runlet.app.
    public static let bundledPath = "Contents/Helpers/runlet"

    public enum PathKind: Sendable { case file, directory }

    public enum Invocation: Equatable {
        case help
        case version
        case open(OpenRequest)
        /// `runlet mcp`: an MCP server on standard input and output for AI clients (docs/mcp.md).
        case mcp
    }

    /// A problem with the arguments, worded for the terminal.
    public struct UsageError: Error, Equatable, CustomStringConvertible {
        public var description: String

        public init(_ description: String) {
            self.description = description
        }
    }

    public static let usage = """
    Usage: runlet [options] [path ...]

    Opens folders, PHP files, and workspaces in Runlet. Nothing runs until you press Run.

      runlet                 open the current folder as a project (same as `runlet .`)
      runlet <folder>        open a folder as a local project in a new tab
      runlet <file.php>      open a file in a tab; saving writes back to it
      runlet <name.runlet>   open a workspace in its own window
      runlet mcp             serve AI clients over MCP (stdio); each run they ask for
                             waits for your approval in Runlet (Settings ▸ AI Clients).
                             A folder named mcp opens as ./mcp

    Options:
      -t, --target <name>    open files (or, with no paths, a new tab) on this target:
                             "sandbox", a local project's name or path, or a Docker or
                             SSH profile's name (local:, docker:, or ssh: before the
                             name when several match); opening never connects
      -n, --new-window       open in a new window
      -h, --help             show this help
      -v, --version          show Runlet's version
    """

    /// Parses the tool's arguments (without the program name).
    /// - Parameters:
    ///   - currentDirectory: relative paths resolve against it, and it is what no paths opens.
    ///   - home: refused as a project (indexing a whole home folder is never what was meant).
    ///   - kind: whether a path is a file, a folder, or missing.
    public static func parse(_ arguments: [String], currentDirectory: String, home: String = NSHomeDirectory(), kind: (String) -> PathKind?) throws(UsageError) -> Invocation {
        if arguments.first == "mcp" {
            guard arguments.count == 1 else { throw UsageError("mcp takes no arguments (to open a folder named mcp, write ./mcp)") }
            return .mcp
        }
        var target: String?
        var newWindow = false
        var paths: [String] = []
        var index = 0
        var onlyPaths = false
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if onlyPaths || !argument.hasPrefix("-") {
                paths.append(argument)
                continue
            }
            switch argument {
            case "--":
                onlyPaths = true
            case "-h", "--help":
                return .help
            case "-v", "--version":
                return .version
            case "-n", "--new-window":
                newWindow = true
            case "-t", "--target":
                guard index < arguments.count else { throw UsageError("\(argument) needs a target name") }
                guard target == nil else { throw UsageError("only one --target can be given") }
                target = arguments[index]
                index += 1
            case "-":
                throw UsageError("reading code from standard input isn't supported yet")
            default:
                if argument.hasPrefix("--target=") {
                    guard target == nil else { throw UsageError("only one --target can be given") }
                    target = String(argument.dropFirst("--target=".count))
                } else {
                    throw UsageError("unknown option \(argument)")
                }
            }
        }
        if let name = target {
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw UsageError("--target needs a target name") }
            // A project given by its path is resolved here, where the current folder is known.
            let kindPrefix = TargetLibrary.kindPrefixes.first { name.lowercased().hasPrefix($0) } ?? ""
            let rest = String(name.dropFirst(kindPrefix.count))
            if kindPrefix.isEmpty || kindPrefix == "local:", TargetLibrary.looksLikePath(rest) {
                target = kindPrefix + absolutePath(rest, currentDirectory: currentDirectory, home: home)
            }
        }
        // No paths opens the current folder, unless a target alone asks for a new tab.
        if paths.isEmpty, target == nil { paths = ["."] }

        var items: [OpenRequest.Item] = []
        for argument in paths {
            let path = absolutePath(argument, currentDirectory: currentDirectory, home: home)
            switch kind(path) {
            case .directory:
                if path == "/" || path == standardized(home) {
                    throw UsageError("\(argument) is \(path == "/" ? "the root folder" : "your home folder"), not a project; open a project folder instead")
                }
                items.append(.folder(path))
            case .file:
                items.append(path.lowercased().hasSuffix(".runlet") ? .workspace(path) : .file(path))
            case nil:
                throw UsageError("no such file or folder: \(argument)")
            }
        }
        if target != nil, items.contains(where: { if case .file = $0 { false } else { true } }) {
            throw UsageError("--target applies to files: a folder is its own project, and a workspace keeps its tabs' targets")
        }
        return .open(OpenRequest(items: items, target: target, newWindow: newWindow))
    }

    /// `path` as an absolute, standardized path (`~` expanded, `.` and `..` resolved; symbolic
    /// links are kept as typed).
    public static func absolutePath(_ path: String, currentDirectory: String, home: String = NSHomeDirectory()) -> String {
        var expanded = path
        if expanded == "~" {
            expanded = home
        } else if expanded.hasPrefix("~/") {
            expanded = home + expanded.dropFirst(1)
        }
        let base = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded, isDirectory: false) : URL(fileURLWithPath: expanded, isDirectory: false, relativeTo: base)
        return standardized(url.path)
    }

    static func standardized(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL.path
        return standardized.count > 1 && standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }
}

// MARK: - Targets by name

/// The saved target a name given on the command line refers to.
public enum TargetMatch: Equatable, Sendable {
    case found(TargetRef)
    case notFound
    /// Several targets fit; their descriptions.
    case ambiguous([String])
}

extension TargetLibrary {
    /// The kind prefixes a target name may start with.
    public static let kindPrefixes = ["local:", "docker:", "ssh:"]

    /// Finds the target `query` names: "sandbox", a local project's name or folder path, a
    /// Docker profile's name, or an SSH profile's name, ignoring case. `local:`, `docker:`, and
    /// `ssh:` prefixes pick a kind, and a prefixed id (`docker:<uuid>`) names exactly one target.
    /// An exact name wins; otherwise a name that starts with the query, when only one does.
    public func target(matching query: String, home: String = NSHomeDirectory()) -> TargetMatch {
        var name = query.trimmingCharacters(in: .whitespaces)
        var kinds: Set<String> = ["local", "docker", "ssh"]
        for prefix in Self.kindPrefixes where name.lowercased().hasPrefix(prefix) {
            kinds = [String(prefix.dropLast())]
            name = String(name.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        let lower = name.lowercased()
        if kinds.count == 3, ["sandbox", "laravel sandbox"].contains(lower) { return .found(.sandbox) }

        var candidates: [(ref: TargetRef, id: UUID, name: String, description: String)] = []
        if kinds.contains("local") {
            candidates += localProjects.map { (.local($0.id), $0.id, $0.name, "\($0.name) (local project, \(($0.path as NSString).abbreviatingWithTildeInPath))") }
        }
        if kinds.contains("docker") {
            candidates += dockerProfiles.map { (.docker($0.id), $0.id, $0.name, "\($0.name) (Docker profile)") }
        }
        if kinds.contains("ssh") {
            candidates += sshProfiles.map { (.ssh($0.id), $0.id, $0.name, "\($0.name) (SSH host \($0.destinationLabel))") }
        }

        // A prefixed id names one target, whatever its name.
        if kinds.count == 1, let id = UUID(uuidString: name) {
            return candidates.first { $0.id == id }.map { .found($0.ref) } ?? .notFound
        }
        // A path (made absolute by the tool) names a local project by its folder.
        if kinds.contains("local"), Self.looksLikePath(name) {
            let path = CommandLineTool.absolutePath(name, currentDirectory: "/", home: home)
            let project = localProjects.first { CommandLineTool.standardized($0.path) == path }
            return project.map { .found(.local($0.id)) } ?? .notFound
        }
        let exact = candidates.filter { $0.name.lowercased() == lower }
        let matches = exact.isEmpty ? candidates.filter { $0.name.lowercased().hasPrefix(lower) } : exact
        switch matches.count {
        case 0: return .notFound
        case 1: return .found(matches[0].ref)
        default: return .ambiguous(matches.map(\.description))
        }
    }

    /// A name for `target` that `target(matching:)` resolves to exactly that target:
    /// "sandbox", "local:<name>", "docker:<name>", "ssh:<name>", or the folder or id when
    /// another target shares the name.
    public func selector(for target: TargetRef) -> String {
        let candidate: String
        let fallback: String
        switch target {
        case .sandbox:
            return "sandbox"
        case .local(let id):
            candidate = "local:" + (localProject(id)?.name ?? "")
            fallback = "local:" + (localProject(id)?.path ?? id.uuidString)
        case .docker(let id):
            candidate = "docker:" + (dockerProfile(id)?.name ?? "")
            fallback = "docker:" + id.uuidString
        case .ssh(let id):
            candidate = "ssh:" + (sshProfile(id)?.name ?? "")
            fallback = "ssh:" + id.uuidString
        }
        return self.target(matching: candidate) == .found(target) ? candidate : fallback
    }

    /// Whether a target name is a folder path rather than a name.
    static func looksLikePath(_ name: String) -> Bool {
        name.contains("/") || name == "." || name == ".." || name == "~"
    }
}
