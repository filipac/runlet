import Darwin
import Foundation

/// How a terminal tab's process starts: an argument vector run inside a pseudo-terminal.
///
/// A plain request starts the user's own login shell (`argv[0]` prefixed with `-`, so
/// `/etc/zprofile`, `~/.zprofile`, `~/.zshrc`, … run exactly as in Terminal.app). Runlet adds
/// no rc files, prompt changes, or shell options; it only describes the terminal through
/// `TERM`, `COLORTERM`, and `TERM_PROGRAM`. A request that types a command into zsh, bash,
/// or fish also gets `ShellIntegration`, so the command waits for the first prompt.
public struct TerminalLaunch: Sendable, Equatable {
    /// Absolute path passed to `execve`.
    public var executable: String
    /// `argv[0]`: `-zsh` for a login shell, the request's own first element otherwise.
    public var argv0: String
    /// Arguments after `argv[0]`.
    public var arguments: [String]
    /// The child's environment as `KEY=VALUE` entries (sorted, for stable comparisons).
    public var environment: [String]
    /// Existing directory the process starts in.
    public var workingDirectory: String
    /// Typed into the session once it is ready (`commandLine`, followed by Return unless the
    /// request only types it).
    public var pendingInput: String?
    /// True when this is the user's login shell (false for a direct executable).
    public var isLoginShell: Bool
    /// Set when the shell reports its first prompt through `ShellIntegration`: the session
    /// types `pendingInput` only after the marker with this token arrives. nil: no
    /// integration (the session falls back to watching the output).
    public var readyToken: String?

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case emptyCommand
        case executableNotFound(String)

        public var description: String {
            switch self {
            case .emptyCommand: "The terminal request has an empty command."
            case .executableNotFound(let name): "“\(name)” was not found or is not executable."
            }
        }
    }

    /// Variables that describe a different terminal session (when Runlet itself was started
    /// from a terminal) or that Xcode injects for debugging; none of them should reach the
    /// user's shell. Everything else is inherited unchanged.
    static let droppedKeys: Set<String> = [
        "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "SHLVL", "PWD", "OLDPWD", "_",
        "LC_TERMINAL", "LC_TERMINAL_VERSION", "TMUX", "TMUX_PANE", "STY", "WINDOW", "WINDOWID",
        "TERMINAL_EMULATOR", "OS_ACTIVITY_DT_MODE", "NSUnbufferedIO",
        ShellIntegration.tokenVariable, ShellIntegration.userZdotdirVariable,
    ]
    static let droppedPrefixes = [
        "ITERM_", "KITTY_", "WEZTERM_", "ALACRITTY_", "GHOSTTY_", "VTE_", "KONSOLE_", "VSCODE_",
        "WT_", "DYLD_", "__XPC_DYLD_",
    ]

    /// Builds the launch for `request`.
    /// - Parameters:
    ///   - shell: the user's shell (see `userShell()`); used unless the request has an executable.
    ///   - baseEnvironment: inherited environment (normally the app's own).
    ///   - home: fallback directory when the requested one does not exist.
    ///   - language: `LANG` value used only when the inherited environment has none.
    ///   - termProgramVersion: value for `TERM_PROGRAM_VERSION` (Runlet's version).
    ///   - shellIntegration: directory where `ShellIntegration.install` wrote its scripts;
    ///     used only when a command is typed into zsh, bash, or fish (nil: never).
    ///   - readyToken: the token the shell reports readiness with (random by default).
    ///   - resolveExecutable: maps a request's `executable[0]` to an absolute path.
    public static func make(
        for request: TerminalRequest,
        shell: String,
        baseEnvironment: [String: String],
        home: String,
        language: String,
        termProgramVersion: String? = nil,
        shellIntegration: URL? = nil,
        readyToken: String = ShellIntegration.makeToken(),
        resolveExecutable: (String) -> String? = ExecutableLocator.resolve
    ) throws -> TerminalLaunch {
        var environment = Self.environment(from: baseEnvironment, home: home, language: language, termProgramVersion: termProgramVersion)
        let directory = Self.workingDirectory(request.workingDirectory, home: home)
        let input = request.commandLine.flatMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed + (request.runsCommandLine ? "\r" : "")
        }

        if let argv = request.executable {
            guard let first = argv.first, !first.isEmpty else { throw Failure.emptyCommand }
            guard let path = resolveExecutable(first) else { throw Failure.executableNotFound(first) }
            return TerminalLaunch(
                executable: path,
                argv0: first,
                arguments: Array(argv.dropFirst()),
                environment: Self.entries(environment),
                workingDirectory: directory,
                pendingInput: input,
                isLoginShell: false
            )
        }

        // login(1) sets SHELL to the account's shell; do the same.
        environment["SHELL"] = shell
        let name = (shell as NSString).lastPathComponent
        var argv0 = "-" + name
        var arguments: [String] = []
        var token: String?
        if input != nil, let root = shellIntegration, let kind = ShellIntegration.Shell(executable: shell) {
            token = readyToken
            switch kind {
            case .zsh:
                let zdotdir = ShellIntegration.zshDirectory(in: root).path
                // An inherited ZDOTDIR is the user's (one pointing here would make the files source themselves).
                if let user = environment["ZDOTDIR"], user != zdotdir { environment[ShellIntegration.userZdotdirVariable] = user }
                environment["ZDOTDIR"] = zdotdir
                environment[ShellIntegration.tokenVariable] = readyToken
            case .bash:
                // `--rcfile` applies only to a non-login shell; the rc file reads the login files.
                argv0 = name
                arguments = ["--rcfile", ShellIntegration.bashRCFile(in: root).path, "-i"]
                environment[ShellIntegration.tokenVariable] = readyToken
            case .fish:
                arguments = ["--init-command", ShellIntegration.fishInitCommand(token: readyToken)]
            }
        }
        return TerminalLaunch(
            executable: shell,
            argv0: argv0,
            arguments: arguments,
            environment: Self.entries(environment),
            workingDirectory: directory,
            pendingInput: input,
            isLoginShell: true,
            readyToken: token
        )
    }

    /// The inherited environment plus the terminal description.
    public static func environment(from base: [String: String], home: String, language: String, termProgramVersion: String?) -> [String: String] {
        var environment = base.filter { key, _ in
            !droppedKeys.contains(key) && !droppedPrefixes.contains { key.hasPrefix($0) }
        }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Runlet"
        if let termProgramVersion { environment["TERM_PROGRAM_VERSION"] = termProgramVersion }
        if (environment["LANG"] ?? "").isEmpty { environment["LANG"] = language }
        if (environment["HOME"] ?? "").isEmpty { environment["HOME"] = home }
        if (environment["USER"] ?? "").isEmpty, let user = accountName() {
            environment["USER"] = user
            if (environment["LOGNAME"] ?? "").isEmpty { environment["LOGNAME"] = user }
        }
        return environment
    }

    /// The requested directory when it exists (with `~` expanded), else `home`.
    public static func workingDirectory(_ requested: String?, home: String) -> String {
        guard let requested, !requested.isEmpty else { return home }
        let expanded = (requested as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else { return home }
        return expanded
    }

    /// The user's login shell: the account's shell from the user database, then `$SHELL`,
    /// then `/bin/zsh`. Candidates that are not executable are skipped.
    public static func userShell(
        accountShell: String? = TerminalLaunch.accountShell(),
        environmentShell: String? = ProcessInfo.processInfo.environment["SHELL"],
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String {
        for candidate in [accountShell, environmentShell] {
            if let candidate, candidate.hasPrefix("/"), isExecutable(candidate) { return candidate }
        }
        return "/bin/zsh"
    }

    /// `pw_shell` of the current user (`getpwuid(getuid())`).
    public static func accountShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        let value = String(cString: shell)
        return value.isEmpty ? nil : value
    }

    static func accountName() -> String? {
        guard let entry = getpwuid(getuid()), let name = entry.pointee.pw_name else { return nil }
        let value = String(cString: name)
        return value.isEmpty ? nil : value
    }

    /// A UTF-8 locale for the user's language and region when the system has it (as
    /// Terminal.app sets `LANG`), else `en_US.UTF-8`.
    public static func defaultLanguage(
        locale: Locale = .current,
        localeExists: (String) -> Bool = { FileManager.default.fileExists(atPath: "/usr/share/locale/\($0)") }
    ) -> String {
        if let language = locale.language.languageCode?.identifier, let region = locale.region?.identifier {
            let candidate = "\(language)_\(region).UTF-8"
            if localeExists(candidate) { return candidate }
        }
        return "en_US.UTF-8"
    }

    static func entries(_ environment: [String: String]) -> [String] {
        environment.map { "\($0.key)=\($0.value)" }.sorted()
    }

    /// Decodes a raw `waitpid` status into an exit code (or 128 + signal number).
    public static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 { return (status >> 8) & 0xff }
        return 128 + signal
    }
}
