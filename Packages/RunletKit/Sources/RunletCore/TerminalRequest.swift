import Foundation

/// A request to open a terminal tab: an interactive login shell in a directory, optionally
/// running a command first. Shared contract between the terminal panel and features that
/// launch commands (project commands, container shells).
public struct TerminalRequest: Sendable, Hashable, Identifiable {
    public var id: UUID
    /// Tab title, e.g. "artisan migrate:status" or "lease-api shell".
    public var title: String
    /// Host directory to start in (nil: the user's home directory).
    public var workingDirectory: String?
    /// A command line typed into the user's own shell after it starts (runs with the
    /// user's PATH, aliases, and rc files). nil opens a plain shell.
    public var commandLine: String?
    /// When set, run this argument vector directly instead of a login shell (e.g.
    /// `docker exec -it <container> sh`). Never passed through a shell.
    public var executable: [String]?
    /// False types `commandLine` without pressing Return, so the user can complete it (e.g.
    /// a command with required arguments).
    public var runsCommandLine: Bool
    /// True when the tab exists to run a command (a project command, typed into the shell
    /// or run directly): it stays open after the process exits so its output can be read.
    /// Plain and container shells close when they exit cleanly. Defaults to whether
    /// `commandLine` is set.
    public var isCommand: Bool
    /// The environment the process inherits instead of Runlet's own (e.g. the user's shell
    /// environment, so a command finds the same tools as in their terminal). The terminal's
    /// own variables (`TERM`, …) are still set on top.
    public var environment: [String: String]?

    public init(id: UUID = UUID(), title: String, workingDirectory: String? = nil, commandLine: String? = nil, executable: [String]? = nil, runsCommandLine: Bool = true, isCommand: Bool? = nil, environment: [String: String]? = nil) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
        self.commandLine = commandLine
        self.executable = executable
        self.runsCommandLine = runsCommandLine
        self.isCommand = isCommand ?? (commandLine != nil)
        self.environment = environment
    }
}
