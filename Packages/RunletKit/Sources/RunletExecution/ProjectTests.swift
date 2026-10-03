import Foundation
import RunletCore

/// The Tests group of the Commands pane (N37, #40): run the project's test suite, one test file,
/// or the tests matching a `--filter`, in a terminal tab on the tab's target. Started only by an
/// explicit click, never by opening, importing, or restoring code, and never on production
/// targets (`isAllowed(on:)`): test suites often reset or migrate the database.
///
/// Which runner a project gets, by its files (no PHP runs to decide), in this order:
/// 1. **`php artisan test`**: `artisan`, Laravel's `vendor/nunomaduro/collision/` (which provides
///    the command), Pest or PHPUnit in `vendor/bin/`, and `phpunit.xml` or `phpunit.xml.dist`
///    (the two files Collision passes to the runner). It starts Pest when Pest is installed,
///    else PHPUnit, with the same PHP, and is what Laravel's own `composer test` runs.
/// 2. **Pest** (`php vendor/bin/pest`): Pest also runs plain PHPUnit test classes.
/// 3. **PHPUnit** (`php vendor/bin/phpunit`).
///
/// Pest and PHPUnit need a configuration file in the project directory (`phpunit.xml`,
/// `phpunit.dist.xml`, or `phpunit.xml.dist`, PHPUnit's own order): it names the test suites,
/// without which "run all" has nothing to run. On this Mac, its `<testsuite>` folders and files
/// must also exist (`detect(projectDirectory:)`), so a project without tests (such as the bundled
/// sandbox, which ships without `tests/`) shows no Tests group.
///
/// Local projects and the sandbox are checked on this Mac before the tab opens. Docker profiles
/// and SSH hosts choose on the target itself, in the same `sh` that starts the tests
/// (`selectionScript`), like Open REPL (`ProjectREPL`), so nothing connects or runs to decide.
public enum ProjectTests {
    public enum Runner: String, Sendable, Equatable, CaseIterable {
        case artisan
        case pest
        case phpunit

        /// "php artisan test", "Pest", or "PHPUnit".
        public var displayName: String {
            switch self {
            case .artisan: "php artisan test"
            case .pest: "Pest"
            case .phpunit: "PHPUnit"
            }
        }

        /// For tab titles: "artisan test", "pest", or "phpunit".
        public var shortName: String {
            switch self {
            case .artisan: "artisan test"
            case .pest: "pest"
            case .phpunit: "phpunit"
            }
        }

        /// What follows the PHP binary, run in the project's directory.
        public var phpArguments: [String] {
            switch self {
            case .artisan: ["artisan", "test"]
            case .pest: ["vendor/bin/pest"]
            case .phpunit: ["vendor/bin/phpunit"]
            }
        }

        /// "php artisan test", "php vendor/bin/pest", or "php vendor/bin/phpunit".
        public var commandLine: String { (["php"] + phpArguments).joined(separator: " ") }
    }

    /// What to run.
    public enum Action: Sendable, Hashable {
        /// Every test suite in the configuration.
        case all
        /// One test file (or folder): relative to the project directory, or absolute on the target.
        case file(String)
        /// Tests whose name matches this pattern (`--filter`).
        case filter(String)

        /// The runner's arguments, each one shell word: a file as given (`./` first when it
        /// starts with `-`, so it can't read as an option), a filter as `--filter=<text>`.
        public var arguments: [String] {
            switch self {
            case .all: []
            case .file(let path): [path.hasPrefix("-") ? "./" + path : path]
            case .filter(let pattern): ["--filter=" + pattern]
            }
        }

        /// For tab titles: "", " ExampleTest.php", or " --filter=checkout".
        var titleSuffix: String {
            switch self {
            case .all: ""
            case .file(let path): " " + ((path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent)
            case .filter(let pattern): " --filter=" + (pattern.count > 40 ? String(pattern.prefix(40)) + "…" : pattern)
            }
        }
    }

    /// The runner a project uses, with what it found.
    public struct Detection: Sendable, Equatable {
        public var runner: Runner
        /// What actually runs the tests: Pest or PHPUnit (`artisan test` starts one of them).
        public var engine: Runner
        /// The configuration file the runner reads ("phpunit.xml").
        public var configuration: String
        /// Where the configuration's test suites are, relative to the project directory, those
        /// that exist ("tests/Unit", "tests/Feature"); empty when not checked.
        public var testLocations: [String]

        public init(runner: Runner, engine: Runner, configuration: String, testLocations: [String] = []) {
            self.runner = runner
            self.engine = engine
            self.configuration = configuration
            self.testLocations = testLocations
        }

        /// "php artisan test · PHPUnit", "Pest · php vendor/bin/pest".
        public var summary: String {
            runner == .artisan ? "\(runner.displayName) · \(engine.displayName)" : "\(runner.displayName) · \(runner.commandLine)"
        }
    }

    /// PHPUnit's configuration files, in the order PHPUnit (and Pest) look for them.
    public static let configurationFiles = ["phpunit.xml", "phpunit.dist.xml", "phpunit.xml.dist"]
    /// The ones `php artisan test` passes on (Collision checks only these two).
    static let artisanConfigurationFiles = ["phpunit.xml", "phpunit.xml.dist"]

    /// Why the Tests group is disabled on production targets.
    public static let productionReason = "Tests can reset the database; they're disabled on production targets."

    /// Tests never run on production targets: suites often reset or migrate the database
    /// (`RefreshDatabase`, `migrate:fresh`), and the configuration's test database isn't
    /// guaranteed to be a separate one. Development and staging targets run them without asking.
    public static func isAllowed(on environment: TargetEnvironment) -> Bool {
        environment != .production
    }

    /// The runner for a project, from whether `path` (relative to the project directory) is a
    /// file or a directory. `selectionScript` makes the same choice with `[ -f ]`/`[ -d ]`.
    public static func detect(isFile: (String) -> Bool, isDirectory: (String) -> Bool) -> Detection? {
        let engine: Runner? = isFile("vendor/bin/pest") ? .pest : (isFile("vendor/bin/phpunit") ? .phpunit : nil)
        guard let engine else { return nil }
        if isFile("artisan"), isDirectory("vendor/nunomaduro/collision"),
           let configuration = artisanConfigurationFiles.first(where: isFile) {
            return Detection(runner: .artisan, engine: engine, configuration: configuration)
        }
        guard let configuration = configurationFiles.first(where: isFile) else { return nil }
        return Detection(runner: engine, engine: engine, configuration: configuration)
    }

    /// The runner for a project directory on this Mac (symbolic links are followed, as `test`
    /// does), or nil when it has none, or when none of its configuration's test folders and
    /// files exist.
    public static func detect(projectDirectory: String) -> Detection? {
        let root = URL(fileURLWithPath: projectDirectory, isDirectory: true)
        func check(_ path: String, directory: Bool) -> Bool {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path, isDirectory: &isDirectory) else { return false }
            return isDirectory.boolValue == directory
        }
        guard var detection = detect(isFile: { check($0, directory: false) }, isDirectory: { check($0, directory: true) }) else { return nil }
        guard let declared = testLocations(configuration: root.appendingPathComponent(detection.configuration)) else {
            // A configuration Runlet can't read: let the runner explain it.
            return detection
        }
        detection.testLocations = (declared.isEmpty ? ["tests"] : declared).filter { location in
            // Glob patterns (`src/*/Tests`) aren't expanded here: assume they match.
            location.contains("*") || FileManager.default.fileExists(atPath: location.hasPrefix("/") ? location : root.appendingPathComponent(location).path)
        }
        return detection.testLocations.isEmpty ? nil : detection
    }

    /// The `<directory>` and `<file>` entries of a configuration's test suites, in order, without
    /// a leading "./" (empty: it lists none). nil when the file can't be read as XML.
    public static func testLocations(configuration: URL) -> [String]? {
        guard let document = try? XMLDocument(contentsOf: configuration, options: []),
              let nodes = try? document.nodes(forXPath: "//testsuite/directory | //testsuite/file") else { return nil }
        var seen: Set<String> = []
        return nodes.compactMap { node -> String? in
            var path = (node.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            while path.hasPrefix("./") { path.removeFirst(2) }
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            guard !path.isEmpty, path != ".", seen.insert(path).inserted else { return nil }
            return path
        }
    }

    /// `file` relative to `projectDirectory` when it is inside it (symbolic links resolved on
    /// both sides), for the local file picker; nil for a file elsewhere or the folder itself.
    public static func relativePath(of file: URL, in projectDirectory: URL) -> String? {
        let root = projectDirectory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let path = file.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard path.count > root.count, Array(path.prefix(root.count)) == root else { return nil }
        return path.dropFirst(root.count).joined(separator: "/")
    }

    /// A filter or path as typed, trimmed; nil when it is empty or has a line break or other
    /// control character (it is passed as one argument on one line).
    public static func cleanedInput(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return trimmed
    }

    /// Title of a tests tab: "artisan test · acme-shop", "pest ExampleTest.php · app",
    /// "phpunit --filter=checkout · app". Docker and SSH tabs start as "Tests · <place>" until
    /// the target has chosen (the script sets the exact title).
    public static func title(_ runner: Runner?, action: Action, place: String) -> String {
        "\(runner?.shortName ?? "Tests")\(action.titleSuffix) · \(place)"
    }

    /// `php artisan test --filter='…'`: what runs, for help texts and the production preview,
    /// with `php` standing for the target's PHP.
    public static func commandLine(_ runner: Runner, action: Action) -> String {
        ([runner.commandLine] + action.arguments.map(RemoteShell.quote)).joined(separator: " ")
    }

    /// `exec '<php>' artisan test '<argument>'`.
    static func launchLine(_ runner: Runner, action: Action, php: String) -> String {
        (["exec", RemoteShell.quote(php)] + runner.phpArguments + action.arguments.map(RemoteShell.quote)).joined(separator: " ")
    }

    /// A POSIX `sh` script, run in the project's directory on the target, that chooses like
    /// `detect(isFile:isDirectory:)` and `exec`s that runner with `php` and the action's
    /// arguments. It first sets the terminal tab's title (OSC 2), and explains on stderr (exit 1)
    /// when the project has no test runner, e.g. a deploy without dev dependencies.
    public static func selectionScript(php: String, action: Action, place: String) -> String {
        func start(_ runner: Runner) -> String {
            "printf '\\033]2;%s\\007' \(RemoteShell.quote(title(runner, action: action, place: place))); " + launchLine(runner, action: action, php: php)
        }
        func anyFile(_ files: [String]) -> String {
            "{ " + files.map { "[ -f \($0) ]" }.joined(separator: " || ") + "; }"
        }
        let runners = anyFile(["vendor/bin/pest", "vendor/bin/phpunit"])
        return "if [ -f artisan ] && [ -d vendor/nunomaduro/collision ] && \(runners) && \(anyFile(artisanConfigurationFiles)); then \(start(.artisan)); fi; "
            + "if \(anyFile(configurationFiles)); then "
            + "if [ -f vendor/bin/pest ]; then \(start(.pest)); fi; "
            + "if [ -f vendor/bin/phpunit ]; then \(start(.phpunit)); fi; "
            + "fi; "
            + "echo \(RemoteShell.quote(missingRunnerMessage)) >&2; exit 1"
    }

    /// What the selection script prints when the target has no test runner.
    static let missingRunnerMessage = "Runlet: no test runner here. Tests need vendor/bin/pest or vendor/bin/phpunit (installed with the dev dependencies) and a phpunit.xml, phpunit.dist.xml, or phpunit.xml.dist in the project folder."

    /// The terminal request that runs `action` for a resolved target, the way project commands
    /// run (`ProjectCommandLauncher`):
    /// - Local projects and the sandbox: the command typed into the user's login shell in the
    ///   project (or sandbox) directory, with the target's PHP (`'<php>' artisan test …`).
    /// - Docker profiles: `docker exec -it [--user] [--env TMPDIR] -w <dir> <container> sh -lc
    ///   <selectionScript>` into the snapshot's container (never another one).
    /// - Docker sandbox: a disposable, Runlet-labelled `docker run --rm -it` with the sandbox
    ///   mounted.
    /// - SSH hosts: `ssh -t` (BatchMode, strict host keys, the shared connection) running
    ///   `/bin/sh -lc 'cd <dir> && <selectionScript>'` with the profile's PHP; with a container
    ///   step, `<docker> exec -it … sh -lc <selectionScript>` in that container on the server.
    ///
    /// The tab stays open after the tests finish. `runner` overrides what is found on this Mac
    /// for local and sandbox targets (nil: check their files now; throws when there is no
    /// runner); Docker profiles and SSH hosts always choose on the target. `place` names the
    /// target in the tab title. Production targets are refused (`isAllowed(on:)`) by the caller.
    public static func terminalRequest(target: TargetSnapshot, action: Action, runner: Runner? = nil, place: String, dockerExecutable: String?, ssh: SSHClient = SSHClient()) throws -> TerminalRequest {
        func localRunner(_ directory: String) throws -> Runner {
            if let runner { return runner }
            guard let detection = detect(projectDirectory: directory) else {
                throw ExecutionError.invalidTarget("Runlet found no tests to run in \(directory): it needs vendor/bin/pest or vendor/bin/phpunit, a phpunit.xml (or phpunit.xml.dist), and the test folders it names.")
            }
            return detection.runner
        }
        switch target.kind {
        case .local, .sandboxLocal:
            let runner = try localRunner(target.workingDirectory)
            let line = ProjectCommandLauncher.localCommandLine(commandLine(runner, action: action), php: target.phpExecutable)
            return TerminalRequest(title: title(runner, action: action, place: place), workingDirectory: target.workingDirectory, commandLine: line, isCommand: true)
        case .docker:
            guard let docker = dockerExecutable else { throw ExecutionError.dockerUnavailable }
            guard let containerId = target.containerId, !containerId.isEmpty else {
                throw ExecutionError.invalidTarget("No container is resolved for this profile.")
            }
            var arguments = [docker, "exec", "-it"]
            if let user = target.user, !user.isEmpty { arguments += ["--user", user] }
            if let temporary = target.temporaryDirectory, !temporary.isEmpty { arguments += ["--env", "TMPDIR=\(temporary)"] }
            arguments += ["-w", target.workingDirectory, containerId, "sh", "-lc", selectionScript(php: target.phpExecutable, action: action, place: place)]
            return TerminalRequest(title: title(nil, action: action, place: place), executable: arguments, isCommand: true)
        case .sandboxDocker:
            guard let docker = dockerExecutable else { throw ExecutionError.dockerUnavailable }
            guard let hostDirectory = target.hostMountDirectory, let image = target.image else {
                throw ExecutionError.invalidTarget("The Docker sandbox is not configured.")
            }
            let runner = try localRunner(hostDirectory)
            let arguments = [
                docker, "run", "--rm", "-it", "--init", "--label", "dev.runlet.owned=sandbox",
                "--volume", "\(hostDirectory):\(target.workingDirectory)", "--workdir", target.workingDirectory,
                image, "sh", "-lc", launchLine(runner, action: action, php: target.phpExecutable),
            ]
            return TerminalRequest(title: title(runner, action: action, place: place), workingDirectory: hostDirectory, executable: arguments, isCommand: true)
        case .ssh:
            guard let endpoint = target.ssh else { throw ExecutionError.invalidTarget("This SSH target has no host.") }
            let script = selectionScript(php: target.phpExecutable, action: action, place: place)
            let remote: String
            if let containerId = target.containerId {
                let exec = RemoteShell.dockerExec(dockerCommand: target.dockerCommand ?? "docker", containerId: containerId, workingDirectory: target.workingDirectory, user: target.user, temporaryDirectory: target.temporaryDirectory)
                remote = RemoteShell.command((exec + ["sh", "-lc", RemoteShell.quote(script)]).joined(separator: " "))
            } else {
                remote = RemoteShell.loginCommand(RemoteShell.commandScript(directory: target.workingDirectory, commandLine: script))
            }
            return TerminalRequest(title: title(nil, action: action, place: place), executable: try ProjectCommandLauncher.preparedTerminal(ssh, endpoint: endpoint, remote: remote), isCommand: true)
        }
    }
}
