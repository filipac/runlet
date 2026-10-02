import Foundation
import RunletCore

/// Open REPL (N19, #32): the target's own interactive REPL in a terminal tab, so state carries
/// over from one input to the next. Opened only by an explicit user action (the Commands
/// pane's Open REPL, its menu item, or the palette), never by opening, importing, or
/// restoring code. Production targets confirm every time (`GuardedAction.repl`, no grace).
///
/// Which REPL a project gets, by its files (no PHP runs to decide):
/// 1. **Tinker** (`php artisan tinker`): `artisan` and `vendor/laravel/tinker/` exist (the
///    sandbox and Laravel applications with laravel/tinker installed).
/// 2. **PsySH** (`php vendor/bin/psysh`): the project's own PsySH.
/// 3. **PHP interactive shell** (`php -a`): neither is installed.
///
/// Local projects and the sandbox are checked on this Mac before the tab opens. Docker
/// profiles and SSH hosts choose on the target itself, in the same `sh` that starts the REPL
/// (`selectionScript`), so no extra connection or `docker exec` is needed to decide.
public enum ProjectREPL {
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case tinker
        case psysh
        case phpShell

        /// "Tinker", "PsySH", or "PHP interactive shell".
        public var displayName: String {
            switch self {
            case .tinker: "Tinker"
            case .psysh: "PsySH"
            case .phpShell: "PHP interactive shell"
            }
        }

        /// What follows the PHP binary, run in the project's directory.
        public var phpArguments: [String] {
            switch self {
            case .tinker: ["artisan", "tinker"]
            case .psysh: ["vendor/bin/psysh"]
            case .phpShell: ["-a"]
            }
        }

        /// "php artisan tinker", "php vendor/bin/psysh", or "php -a".
        public var commandLine: String { (["php"] + phpArguments).joined(separator: " ") }
    }

    /// The REPL for a project, from whether `path` (relative to the project directory) is a
    /// file or a directory. `selectionScript` makes the same choice with `[ -f ]`/`[ -d ]`.
    public static func kind(isFile: (String) -> Bool, isDirectory: (String) -> Bool) -> Kind {
        if isFile("artisan"), isDirectory("vendor/laravel/tinker") { return .tinker }
        if isFile("vendor/bin/psysh") { return .psysh }
        return .phpShell
    }

    /// The REPL for a project directory on this Mac (symbolic links are followed, as `test`
    /// does).
    public static func kind(projectDirectory: String) -> Kind {
        let root = URL(fileURLWithPath: projectDirectory, isDirectory: true)
        func check(_ path: String, directory: Bool) -> Bool {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path, isDirectory: &isDirectory) else { return false }
            return isDirectory.boolValue == directory
        }
        return kind(isFile: { check($0, directory: false) }, isDirectory: { check($0, directory: true) })
    }

    /// Title of a REPL tab: "Tinker · acme-shop". Docker and SSH tabs start as "REPL · <place>"
    /// until the target has chosen (the script sets the exact title).
    public static func title(_ kind: Kind?, place: String) -> String {
        "\(kind?.displayName ?? "REPL") · \(place)"
    }

    /// A POSIX `sh` script, run in the project's directory on the target, that chooses like
    /// `kind(isFile:isDirectory:)` and `exec`s that REPL with `php`. It first sets the terminal
    /// tab's title (OSC 2) to "<REPL> · <place>", and explains on stderr when it falls back to
    /// PHP's interactive shell.
    public static func selectionScript(php: String, place: String) -> String {
        func start(_ kind: Kind) -> String {
            "printf '\\033]2;%s\\007' \(RemoteShell.quote(title(kind, place: place))); " + launchLine(kind, php: php)
        }
        return "if [ -f artisan ] && [ -d vendor/laravel/tinker ]; then \(start(.tinker)); fi; "
            + "if [ -f vendor/bin/psysh ]; then \(start(.psysh)); fi; "
            + "echo \(RemoteShell.quote("Runlet: this project has neither Tinker nor PsySH, so this is PHP's interactive shell (php -a).")) >&2; "
            + start(.phpShell)
    }

    /// `exec <php> artisan tinker` (PHP quoted).
    static func launchLine(_ kind: Kind, php: String) -> String {
        (["exec", RemoteShell.quote(php)] + kind.phpArguments).joined(separator: " ")
    }

    /// The terminal request that opens the REPL for a resolved target, the way project
    /// commands run (`ProjectCommandLauncher`):
    /// - Local projects and the sandbox: the command typed into the user's login shell in the
    ///   project (or sandbox) directory, with the target's PHP (`'<php>' artisan tinker`).
    /// - Docker profiles: `docker exec -it [--user] [--env TMPDIR] -w <dir> <container> sh -lc
    ///   <selectionScript>` into the snapshot's container (never another one).
    /// - Docker sandbox: a disposable, Runlet-labelled `docker run --rm -it` with the sandbox
    ///   mounted.
    /// - SSH hosts: `ssh -t` (BatchMode, strict host keys, the shared connection) running
    ///   `/bin/sh -lc 'cd <dir> && <selectionScript>'` with the profile's PHP; with a container
    ///   step, `<docker> exec -it … sh -lc <selectionScript>` in that container on the server.
    ///
    /// The tab stays open after the REPL exits, like a command's. `kind` overrides what is found
    /// on this Mac for local and sandbox targets (nil: check their files now); Docker profiles
    /// and SSH hosts always choose on the target. `place` names the target in the tab title.
    public static func terminalRequest(target: TargetSnapshot, kind: Kind? = nil, place: String, dockerExecutable: String?, ssh: SSHClient = SSHClient()) throws -> TerminalRequest {
        switch target.kind {
        case .local, .sandboxLocal:
            let kind = kind ?? Self.kind(projectDirectory: target.workingDirectory)
            let line = ProjectCommandLauncher.localCommandLine(kind.commandLine, php: target.phpExecutable)
            return TerminalRequest(title: title(kind, place: place), workingDirectory: target.workingDirectory, commandLine: line, isCommand: true)
        case .docker:
            guard let docker = dockerExecutable else { throw ExecutionError.dockerUnavailable }
            guard let containerId = target.containerId, !containerId.isEmpty else {
                throw ExecutionError.invalidTarget("No container is resolved for this profile.")
            }
            var arguments = [docker, "exec", "-it"]
            if let user = target.user, !user.isEmpty { arguments += ["--user", user] }
            if let temporary = target.temporaryDirectory, !temporary.isEmpty { arguments += ["--env", "TMPDIR=\(temporary)"] }
            arguments += ["-w", target.workingDirectory, containerId, "sh", "-lc", selectionScript(php: target.phpExecutable, place: place)]
            return TerminalRequest(title: title(nil, place: place), executable: arguments, isCommand: true)
        case .sandboxDocker:
            guard let docker = dockerExecutable else { throw ExecutionError.dockerUnavailable }
            guard let hostDirectory = target.hostMountDirectory, let image = target.image else {
                throw ExecutionError.invalidTarget("The Docker sandbox is not configured.")
            }
            let kind = kind ?? Self.kind(projectDirectory: hostDirectory)
            let arguments = [
                docker, "run", "--rm", "-it", "--init", "--label", "dev.runlet.owned=sandbox",
                "--volume", "\(hostDirectory):\(target.workingDirectory)", "--workdir", target.workingDirectory,
                image, "sh", "-lc", launchLine(kind, php: target.phpExecutable),
            ]
            return TerminalRequest(title: title(kind, place: place), workingDirectory: hostDirectory, executable: arguments, isCommand: true)
        case .ssh:
            guard let endpoint = target.ssh else { throw ExecutionError.invalidTarget("This SSH target has no host.") }
            let script = selectionScript(php: target.phpExecutable, place: place)
            let remote: String
            if let containerId = target.containerId {
                let exec = RemoteShell.dockerExec(dockerCommand: target.dockerCommand ?? "docker", containerId: containerId, workingDirectory: target.workingDirectory, user: target.user, temporaryDirectory: target.temporaryDirectory)
                remote = RemoteShell.command((exec + ["sh", "-lc", RemoteShell.quote(script)]).joined(separator: " "))
            } else {
                remote = RemoteShell.loginCommand(RemoteShell.commandScript(directory: target.workingDirectory, commandLine: script))
            }
            return TerminalRequest(title: title(nil, place: place), executable: try ProjectCommandLauncher.preparedTerminal(ssh, endpoint: endpoint, remote: remote), isCommand: true)
        }
    }
}
