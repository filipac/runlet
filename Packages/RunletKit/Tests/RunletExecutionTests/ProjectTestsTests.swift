import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// The Tests group (N37, #40): which runner a project gets, the exact terminal request per target
/// kind, quoting of files and filters, and the production rule. The selection script and the
/// typed command lines are run for real (`sh`, `dash`, `bash`, `zsh`) against folders laid out
/// like projects, with a stand-in PHP that prints each argument it gets.
struct ProjectTestsTests {
    /// A configuration whose test suites are `locations` (`<file>` for paths ending in .php).
    static func configuration(_ locations: [String]) -> String {
        let entries = locations.map { $0.hasSuffix(".php") ? "<file>\($0)</file>" : "<directory suffix=\"Test.php\">\($0)</directory>" }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <phpunit bootstrap="vendor/autoload.php" colors="true">
            <testsuites>
                <testsuite name="Suite">\(entries.joined())</testsuite>
            </testsuites>
        </phpunit>
        """
    }

    /// A project folder with `files` (relative paths; a trailing `/` makes a directory).
    /// Configuration files list `tests` unless `contents` says otherwise.
    static func project(_ files: [String], contents: [String: String] = [:], name: String = "app") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-tests-\(UUID().uuidString.prefix(8))", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in files {
            let url = root.appendingPathComponent(file)
            if file.hasSuffix("/") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let text = contents[file] ?? (ProjectTests.configurationFiles.contains(file) ? configuration(["tests"]) : "<?php\n")
                try Data(text.utf8).write(to: url)
            }
        }
        return root
    }

    /// A stand-in PHP at a path with a space and a quote: prints each argument on its own line,
    /// then its directory.
    static func fakePHP() throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-tests-php \(UUID().uuidString.prefix(6))/it's \"php\"", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let php = folder.appendingPathComponent("php")
        try Data("#!/bin/sh\nfor a in \"$@\"; do printf 'ARG[%s]\\n' \"$a\"; done\necho \"PWD[$(pwd)]\"\n".utf8).write(to: php)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: php.path)
        return php.path
    }

    /// The `ARG[…]` lines the stand-in PHP printed, in order.
    static func arguments(_ stdout: String) -> [String] {
        var result: [String] = []
        var rest = Substring(stdout)
        while let start = rest.range(of: "ARG[") {
            rest = rest[start.upperBound...]
            // An argument may contain "]" or a newline: it ends at the next "]\n" before ARG[ or PWD[.
            guard let end = rest.range(of: "]\nARG[") ?? rest.range(of: "]\nPWD[") else { break }
            result.append(String(rest[..<end.lowerBound]))
            rest = rest[rest.index(after: end.lowerBound)...]
        }
        return result
    }

    static let config = "phpunit.xml"
    static let tests = "tests/"
    static let collision = "vendor/nunomaduro/collision/"

    static let layouts: [(files: [String], runner: ProjectTests.Runner?, engine: ProjectTests.Runner?)] = [
        ([], nil, nil),
        (["composer.json", "vendor/autoload.php", tests], nil, nil),
        // A runner needs a configuration: it names the test suites "run all" runs.
        (["vendor/bin/phpunit", tests], nil, nil),
        (["vendor/bin/phpunit", config, tests], .phpunit, .phpunit),
        (["vendor/bin/phpunit", "phpunit.xml.dist", tests], .phpunit, .phpunit),
        (["vendor/bin/phpunit", "phpunit.dist.xml", tests], .phpunit, .phpunit),
        // Pest before PHPUnit (Pest brings PHPUnit along and runs its classes too).
        (["vendor/bin/pest", "vendor/bin/phpunit", config, tests], .pest, .pest),
        (["vendor/bin/pest", "phpunit.xml.dist", tests], .pest, .pest),
        // Laravel with Collision: `php artisan test`, which starts Pest or PHPUnit itself.
        (["artisan", collision, "vendor/bin/phpunit", config, tests], .artisan, .phpunit),
        (["artisan", collision, "vendor/bin/pest", "vendor/bin/phpunit", "phpunit.xml.dist", tests], .artisan, .pest),
        // Without Collision there is no `artisan test` command.
        (["artisan", "vendor/bin/phpunit", config, tests], .phpunit, .phpunit),
        (["artisan", "vendor/bin/pest", config, tests], .pest, .pest),
        // Collision reads phpunit.xml or phpunit.xml.dist only: phpunit.dist.xml goes to the runner.
        (["artisan", collision, "vendor/bin/phpunit", "phpunit.dist.xml", tests], .phpunit, .phpunit),
        // `artisan test` without Pest or PHPUnit has nothing to start.
        (["artisan", collision, config, tests], nil, nil),
        // Only real files and folders count.
        (["vendor/bin/phpunit/", config, tests], nil, nil),
        (["artisan/", collision, "vendor/bin/phpunit", config, tests], .phpunit, .phpunit),
        (["artisan", "vendor/nunomaduro/collision", "vendor/bin/phpunit", config, tests], .phpunit, .phpunit),
        (["vendor/bin/phpunit", "phpunit.xml/", tests], nil, nil),
    ]

    @Test func detectionFollowsTheProjectsFiles() throws {
        for layout in Self.layouts {
            let root = try Self.project(layout.files)
            let detection = ProjectTests.detect(projectDirectory: root.path)
            #expect(detection?.runner == layout.runner, "\(layout.files)")
            #expect(detection?.engine == layout.engine, "\(layout.files)")
            #expect(detection.map { ProjectTests.configurationFiles.contains($0.configuration) } ?? true)
        }
        #expect(ProjectTests.detect(projectDirectory: "/nonexistent/runlet-tests") == nil)
        #expect(ProjectTests.detect(projectDirectory: TestSupport.fixtures.appendingPathComponent("plain").path) == nil)
        #expect(ProjectTests.Runner.artisan.commandLine == "php artisan test")
        #expect(ProjectTests.Runner.pest.commandLine == "php vendor/bin/pest")
        #expect(ProjectTests.Runner.phpunit.commandLine == "php vendor/bin/phpunit")
        // phpunit.xml wins over the .dist files, as PHPUnit reads it first.
        let both = try Self.project(["vendor/bin/phpunit", "phpunit.xml", "phpunit.xml.dist", Self.tests])
        #expect(ProjectTests.detect(projectDirectory: both.path)?.configuration == "phpunit.xml")
    }

    /// The configuration's test suites must exist on this Mac; their folders also tell the file
    /// picker where to start.
    @Test func theConfigurationsTestSuitesMustExist() throws {
        let runner = ["vendor/bin/phpunit", Self.config]
        let laravel = Self.configuration(["./tests/Unit", "./tests/Feature/"])
        let some = try Self.project(runner + ["tests/Unit/"], contents: [Self.config: laravel])
        #expect(ProjectTests.detect(projectDirectory: some.path)?.testLocations == ["tests/Unit"])
        let all = try Self.project(runner + ["tests/Unit/", "tests/Feature/"], contents: [Self.config: laravel])
        #expect(ProjectTests.detect(projectDirectory: all.path)?.testLocations == ["tests/Unit", "tests/Feature"])
        // Like the bundled sandbox, which ships phpunit.xml and PHPUnit but no tests/.
        #expect(ProjectTests.detect(projectDirectory: try Self.project(runner, contents: [Self.config: laravel]).path) == nil)

        // A <file> suite entry, and a glob (not expanded: assumed to match).
        let file = try Self.project(runner + ["checks/OneTest.php"], contents: [Self.config: Self.configuration(["checks/OneTest.php"])])
        #expect(ProjectTests.detect(projectDirectory: file.path)?.testLocations == ["checks/OneTest.php"])
        let glob = try Self.project(runner, contents: [Self.config: Self.configuration(["src/*/Tests"])])
        #expect(ProjectTests.detect(projectDirectory: glob.path)?.testLocations == ["src/*/Tests"])

        // No test suites listed: Pest's default folder, tests/.
        let bare = "<?xml version=\"1.0\"?><phpunit bootstrap=\"vendor/autoload.php\"></phpunit>"
        #expect(ProjectTests.detect(projectDirectory: try Self.project(runner + [Self.tests], contents: [Self.config: bare]).path)?.testLocations == ["tests"])
        #expect(ProjectTests.detect(projectDirectory: try Self.project(runner, contents: [Self.config: bare]).path) == nil)

        // A configuration that isn't XML: offered, and the runner explains the problem.
        let broken = try Self.project(runner, contents: [Self.config: "<phpunit"])
        #expect(ProjectTests.detect(projectDirectory: broken.path)?.runner == .phpunit)
        #expect(ProjectTests.detect(projectDirectory: broken.path)?.testLocations == [])

        // The repository's Laravel fixture (once its vendor/ is installed).
        let fixture = TestSupport.fixtures.appendingPathComponent("laravel-app")
        if FileManager.default.fileExists(atPath: fixture.appendingPathComponent("vendor/bin/phpunit").path) {
            let detection = try #require(ProjectTests.detect(projectDirectory: fixture.path))
            #expect(detection.runner == .artisan && detection.engine == .phpunit && detection.configuration == "phpunit.xml")
            #expect(detection.testLocations == ["tests/Unit", "tests/Feature"])
            #expect(detection.summary == "php artisan test · PHPUnit")
        }
    }

    /// The values the quoting tests pass through every layer.
    static let awkward = [
        "it's \"odd\" $HOME `uname` $(id) \\ *",
        "-leading dash",
        "--",
        "tests/Feature/Some Test.php",
        "émoji ✓ & | ; < > ( ) { } [ ] ! # ~",
        "trailing backslash \\",
    ]

    /// Every action reaches the runner as exactly one argument, through the selection script
    /// (Docker profiles, SSH hosts) under `sh` and `dash`, and in the right directory.
    @Test func selectionScriptChoosesLikeTheCheckOnThisMac() throws {
        let php = try Self.fakePHP()
        let place = "it's \"odd\" $HOME `x`"
        let shells = ["/bin/sh", "/bin/dash"].filter { FileManager.default.isExecutableFile(atPath: $0) }
        let actions: [ProjectTests.Action] = [.all, .file("tests/Unit/ExampleTest.php"), .filter("it's a $test")]
        for shell in shells {
            for layout in Self.layouts {
                let root = try Self.project(layout.files)
                for action in actions {
                    let result = try ProjectREPLTests.run(ProjectTests.selectionScript(php: php, action: action, place: place), shell: shell, in: root)
                    guard let runner = layout.runner else {
                        #expect(result.status == 1, "\(shell) \(layout.files): \(result.stdout)")
                        #expect(result.stderr.contains("Runlet: no test runner here"), "\(shell) \(layout.files): \(result.stderr)")
                        #expect(!result.stdout.contains("ARG["))
                        continue
                    }
                    #expect(result.status == 0, "\(shell) \(layout.files): \(result.stderr)")
                    #expect(Self.arguments(result.stdout) == runner.phpArguments + action.arguments, "\(shell) \(layout.files): \(result.stdout)")
                    let folder = root.deletingLastPathComponent().lastPathComponent + "/" + root.lastPathComponent
                    #expect(result.stdout.contains("\(folder)]"), "in the project's directory: \(result.stdout)")
                    #expect(result.stdout.hasPrefix("\u{1b}]2;\(ProjectTests.title(runner, action: action, place: place))\u{07}"), "\(shell): the title, unexpanded: \(result.stdout.debugDescription)")
                }
                // The script and the check on this Mac agree (the layouts all list tests/).
                #expect(ProjectTests.detect(projectDirectory: root.path)?.runner == layout.runner)
            }
        }
    }

    @Test func filesAndFiltersAreOneQuotedArgumentEverywhere() throws {
        let php = try Self.fakePHP()
        let root = try Self.project(["artisan", Self.collision, "vendor/bin/phpunit", Self.config, Self.tests], name: "it's \"app\" $HOME")
        let shells = ["/bin/sh", "/bin/dash", "/bin/bash", "/bin/zsh"].filter { FileManager.default.isExecutableFile(atPath: $0) }
        for text in Self.awkward {
            for action in [ProjectTests.Action.file(text), .filter(text)] {
                let expected = ["artisan", "test"] + action.arguments
                if case .file = action { #expect(action.arguments == [text.hasPrefix("-") ? "./" + text : text], "never read as an option") }
                if case .filter = action { #expect(action.arguments == ["--filter=" + text]) }

                // Local: typed into the user's shell in the project folder.
                let local = try ProjectTests.terminalRequest(target: TargetSnapshot(kind: .local, label: "app", targetId: "x", workingDirectory: root.path, phpExecutable: php), action: action, place: "app", dockerExecutable: nil)
                let line = try #require(local.commandLine)
                for shell in shells {
                    let result = try ProjectREPLTests.run(line, shell: shell, in: root)
                    #expect(Self.arguments(result.stdout) == expected, "\(shell) \(text): \(result.stdout) \(result.stderr)")
                }

                // The selection script (Docker, SSH).
                let script = try ProjectREPLTests.run(ProjectTests.selectionScript(php: php, action: action, place: "x"), in: root)
                #expect(Self.arguments(script.stdout) == expected, "script \(text): \(script.stdout)")

                // SSH: unwrapped as the server's login shell would, from any folder.
                let control = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rlt-tests-\(UUID().uuidString.prefix(6))/ab.sock").path
                let ssh = try ProjectTests.terminalRequest(target: TargetSnapshot(kind: .ssh, label: "x", targetId: "x", workingDirectory: root.path, phpExecutable: php, ssh: SSHEndpoint(host: "h", controlPath: control)), action: action, place: "h", dockerExecutable: nil, ssh: SSHClient(executable: "/usr/bin/ssh", environment: [:]))
                let words = try ProjectCommandLauncherTests.shellWords(try #require(ssh.executable?.last))
                #expect(words.prefix(2) == ["/bin/sh", "-lc"])
                let remote = try ProjectREPLTests.run(words[2], in: FileManager.default.temporaryDirectory)
                #expect(Self.arguments(remote.stdout) == expected, "ssh \(text): \(remote.stdout) \(remote.stderr)")
            }
        }
    }

    @Test func localAndSandboxTargetsTypeTheCommandInTheProjectFolder() throws {
        let php = "/Users/me/PHP's bin/php 8.4"
        let target = TargetSnapshot(kind: .local, label: "app", targetId: "x", workingDirectory: "/Users/me/Code/acme shop", phpExecutable: php)
        let all = try ProjectTests.terminalRequest(target: target, action: .all, runner: .artisan, place: "acme shop", dockerExecutable: nil)
        #expect(all.title == "artisan test · acme shop")
        #expect(all.workingDirectory == "/Users/me/Code/acme shop", "the shell starts there: the folder is never typed")
        #expect(all.commandLine == #"'/Users/me/PHP'\''s bin/php 8.4' artisan test"#)
        #expect(all.executable == nil && all.runsCommandLine, "runs at once: nothing left to type")
        #expect(all.isCommand, "the tab stays open after the tests finish")

        let file = try ProjectTests.terminalRequest(target: target, action: .file("tests/Feature/Order Test.php"), runner: .pest, place: "acme shop", dockerExecutable: nil)
        #expect(file.title == "pest Order Test.php · acme shop")
        #expect(file.commandLine == #"'/Users/me/PHP'\''s bin/php 8.4' vendor/bin/pest 'tests/Feature/Order Test.php'"#)
        let filter = try ProjectTests.terminalRequest(target: target, action: .filter("checkout"), runner: .phpunit, place: "acme shop", dockerExecutable: nil)
        #expect(filter.title == "phpunit --filter=checkout · acme shop")
        #expect(filter.commandLine == #"'/Users/me/PHP'\''s bin/php 8.4' vendor/bin/phpunit --filter=checkout"#)
        #expect(ProjectTests.title(.phpunit, action: .filter(String(repeating: "x", count: 50)), place: "p") == "phpunit --filter=\(String(repeating: "x", count: 40))… · p")

        // Without a runner, the project's files on this Mac decide; a PATH `php` stays as typed.
        let pest = try Self.project(["vendor/bin/pest", Self.config, Self.tests], name: "it's a \"project\"")
        let sandbox = TargetSnapshot(kind: .sandboxLocal, label: "sandbox", targetId: "sandbox", workingDirectory: pest.path, phpExecutable: "php")
        let found = try ProjectTests.terminalRequest(target: sandbox, action: .all, place: "Sandbox", dockerExecutable: nil)
        #expect(found.title == "pest · Sandbox")
        #expect(found.commandLine == "php vendor/bin/pest")
        #expect(found.workingDirectory == pest.path)
        // No runner: an explanation, not a broken command.
        let none = TargetSnapshot(kind: .local, label: "x", targetId: "x", workingDirectory: try Self.project([]).path, phpExecutable: "php")
        #expect(throws: ExecutionError.self) { try ProjectTests.terminalRequest(target: none, action: .all, place: "x", dockerExecutable: nil) }
        #expect(ProjectTests.commandLine(.artisan, action: .filter("it's")) == #"php artisan test '--filter=it'\''s'"#)
    }

    @Test func dockerProfilesChooseInTheResolvedContainer() throws {
        let target = TargetSnapshot(kind: .docker, label: "api", targetId: "p", workingDirectory: "/var/www/my app", phpExecutable: "/usr/local/bin/php", containerId: "abc123", containerName: "api-1", user: "www-data", temporaryDirectory: "/scratch")
        let action = ProjectTests.Action.filter("it's $x")
        let request = try ProjectTests.terminalRequest(target: target, action: action, runner: .pest, place: "api", dockerExecutable: "/usr/local/bin/docker")
        let script = ProjectTests.selectionScript(php: "/usr/local/bin/php", action: action, place: "api")
        #expect(request.executable == ["/usr/local/bin/docker", "exec", "-it", "--user", "www-data", "--env", "TMPDIR=/scratch", "-w", "/var/www/my app", "abc123", "sh", "-lc", script], "the container chooses, whatever this Mac guessed")
        #expect(request.title == "Tests --filter=it's $x · api", "until the script sets the exact title")
        #expect(request.commandLine == nil && request.isCommand)

        var bare = target
        bare.user = nil
        bare.temporaryDirectory = nil
        #expect(try ProjectTests.terminalRequest(target: bare, action: .all, place: "api", dockerExecutable: "docker").executable == ["docker", "exec", "-it", "-w", "/var/www/my app", "abc123", "sh", "-lc", ProjectTests.selectionScript(php: "/usr/local/bin/php", action: .all, place: "api")])
        bare.containerId = nil
        #expect(throws: ExecutionError.self) { try ProjectTests.terminalRequest(target: bare, action: .all, place: "api", dockerExecutable: "docker") }
        #expect(throws: ExecutionError.dockerUnavailable) { try ProjectTests.terminalRequest(target: target, action: .all, place: "api", dockerExecutable: nil) }
    }

    @Test func dockerSandboxUsesADisposableContainer() throws {
        let host = try Self.project(["artisan", Self.collision, "vendor/bin/phpunit", Self.config, Self.tests], name: "Sandbox folder")
        let target = TargetSnapshot(kind: .sandboxDocker, label: "sandbox", targetId: "sandbox", workingDirectory: "/sandbox", phpExecutable: "php", image: "php:8.4-cli", hostMountDirectory: host.path)
        let request = try ProjectTests.terminalRequest(target: target, action: .file("tests/Unit/A Test.php"), place: "Sandbox", dockerExecutable: "docker")
        #expect(request.executable == ["docker", "run", "--rm", "-it", "--init", "--label", "dev.runlet.owned=sandbox", "--volume", "\(host.path):/sandbox", "--workdir", "/sandbox", "php:8.4-cli", "sh", "-lc", "exec php artisan test 'tests/Unit/A Test.php'"])
        #expect(request.title == "artisan test A Test.php · Sandbox" && request.isCommand)
    }

    @Test func sshHostsRunTheScriptInTheProfilesDirectory() throws {
        let control = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rlt-tests-\(UUID().uuidString.prefix(6))/ab.sock").path
        let directory = "/home/forge/it's \"app\" $HOME"
        let ssh = SSHClient(executable: "/usr/bin/ssh", environment: [:])
        for authentication in [SSHAuthentication.interactive, .automatic] {
            let endpoint = SSHEndpoint(host: "app-staging", user: "forge", controlPath: control, authentication: authentication)
            let target = TargetSnapshot(kind: .ssh, label: "x", targetId: "x", workingDirectory: directory, phpExecutable: "php8.3", ssh: endpoint)
            let request = try ProjectTests.terminalRequest(target: target, action: .all, runner: .phpunit, place: "app-staging", dockerExecutable: nil, ssh: ssh)
            let argv = try #require(request.executable)
            #expect(request.title == "Tests · app-staging" && request.isCommand && request.commandLine == nil)
            #expect(argv.first == "/usr/bin/ssh" && argv.contains("-t") && !argv.contains("-T"), "a pty, for the runner's colors and progress")
            #expect(argv.contains("BatchMode=yes") && argv.contains("StrictHostKeyChecking=yes"), "no prompts, no unknown host keys")
            // A password or 2FA host only reuses Connect…'s login; a key host may start the
            // shared connection.
            #expect(argv.contains(authentication == .interactive ? "ControlMaster=no" : "ControlMaster=auto"))
            #expect(Array(argv.suffix(3).prefix(2)) == ["--", "app-staging"])
            let words = try ProjectCommandLauncherTests.shellWords(try #require(argv.last))
            #expect(words == ["/bin/sh", "-lc", RemoteShell.commandScript(directory: directory, commandLine: ProjectTests.selectionScript(php: "php8.3", action: .all, place: "app-staging"))])
        }

        // A directory the login can't open: explained, and nothing runs.
        let php = try Self.fakePHP()
        let missing = TargetSnapshot(kind: .ssh, label: "x", targetId: "x", workingDirectory: "/nonexistent/runlet tests", phpExecutable: php, ssh: SSHEndpoint(host: "h", controlPath: control))
        let failed = try ProjectTests.terminalRequest(target: missing, action: .all, place: "h", dockerExecutable: nil, ssh: ssh)
        let result = try ProjectREPLTests.run(try ProjectCommandLauncherTests.shellWords(try #require(failed.executable?.last))[2], in: FileManager.default.temporaryDirectory)
        #expect(result.status == 2)
        #expect(result.stderr.contains("/nonexistent/runlet tests doesn't exist on this server"))
        #expect(!result.stdout.contains("ARG["))
    }

    @Test func sshContainerStepsExecIntoTheResolvedContainerOnTheServer() throws {
        let control = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rlt-tests-\(UUID().uuidString.prefix(6))/ab.sock").path
        let target = TargetSnapshot(kind: .ssh, label: "x", targetId: "x", workingDirectory: "/var/www/html", phpExecutable: "php", containerId: "abc123", containerName: "shop-app-1", user: "www-data", temporaryDirectory: "/scratch", ssh: SSHEndpoint(host: "app-staging", controlPath: control), dockerCommand: "sudo -n docker")
        let action = ProjectTests.Action.file("tests/Feature/It's `here`.php")
        let request = try ProjectTests.terminalRequest(target: target, action: action, place: "shop/app on app-staging", dockerExecutable: nil, ssh: SSHClient(executable: "/usr/bin/ssh", environment: [:]))
        let argv = try #require(request.executable)
        #expect(argv.contains("-t"))
        #expect(request.title == "Tests It's `here`.php · shop/app on app-staging")
        let outer = try ProjectCommandLauncherTests.shellWords(try #require(argv.last))
        #expect(outer.prefix(2) == ["/bin/sh", "-c"])
        #expect(try ProjectCommandLauncherTests.shellWords(outer[2]) == ["sudo", "-n", "docker", "exec", "-it", "--user", "www-data", "--env", "TMPDIR=/scratch", "-w", "/var/www/html", "abc123", "sh", "-lc", ProjectTests.selectionScript(php: "php", action: action, place: "shop/app on app-staging")])

        var noHost = target
        noHost.ssh = nil
        #expect(throws: ExecutionError.self) { try ProjectTests.terminalRequest(target: noHost, action: .all, place: "x", dockerExecutable: nil) }
    }

    @Test func testsNeverRunOnProductionTargets() {
        #expect(ProjectTests.isAllowed(on: .development))
        #expect(ProjectTests.isAllowed(on: .staging))
        #expect(!ProjectTests.isAllowed(on: .production))
        #expect(ProjectTests.productionReason == "Tests can reset the database; they're disabled on production targets.")
    }

    @Test func pickedFilesMustBeInsideTheProject() throws {
        let root = try Self.project(["tests/Unit/A Test.php", "outside.php"], name: "it's app")
        let real = root.resolvingSymlinksInPath()
        #expect(ProjectTests.relativePath(of: root.appendingPathComponent("tests/Unit/A Test.php"), in: root) == "tests/Unit/A Test.php")
        // /var and /private/var are the same folder.
        #expect(ProjectTests.relativePath(of: real.appendingPathComponent("tests/Unit/A Test.php"), in: root) == "tests/Unit/A Test.php")
        #expect(ProjectTests.relativePath(of: root, in: root) == nil)
        #expect(ProjectTests.relativePath(of: root.deletingLastPathComponent().appendingPathComponent("elsewhere.php"), in: root) == nil)
        #expect(ProjectTests.relativePath(of: root.appendingPathComponent("tests/../../escape.php"), in: root) == nil)
        // A sibling whose name starts like the project's.
        #expect(ProjectTests.relativePath(of: URL(fileURLWithPath: root.path + "-other/a.php"), in: root) == nil)
        // A link inside the project that points out of it is outside.
        let link = root.appendingPathComponent("tests/linked.php")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        #expect(ProjectTests.relativePath(of: link, in: root) == nil)
    }

    @Test func typedInputIsTrimmedAndSingleLine() {
        #expect(ProjectTests.cleanedInput("  checkout total \n") == "checkout total")
        #expect(ProjectTests.cleanedInput("   ") == nil)
        #expect(ProjectTests.cleanedInput("") == nil)
        #expect(ProjectTests.cleanedInput("one\ntwo") == nil)
        #expect(ProjectTests.cleanedInput("tab\there") == nil)
        #expect(ProjectTests.cleanedInput("it's $x `y`") == "it's $x `y`")
    }
}

/// `php artisan test` in the repository's Laravel fixture, typed the way the terminal tab runs
/// it: the filter reaches PHPUnit as one argument and selects exactly the matching test.
@Suite(.enabled(if: TestSupport.hasPHP && FileManager.default.fileExists(atPath: TestSupport.fixtures.appendingPathComponent("laravel-app/vendor/bin/phpunit").path), "requires PHP and the Laravel fixture's vendor/ (scripts/setup-fixtures.sh)"))
struct ProjectTestsLiveTests {
    @Test func artisanTestRunsTheFilteredTestInTheFixture() throws {
        let fixture = TestSupport.fixtures.appendingPathComponent("laravel-app").path
        let php = try #require(TestSupport.php())
        let target = TargetSnapshot(kind: .local, label: "laravel-app", targetId: "x", workingDirectory: fixture, phpExecutable: php)
        let request = try ProjectTests.terminalRequest(target: target, action: .filter("that true is true|test_that_true_is_true"), place: "laravel-app", dockerExecutable: nil)
        #expect(request.title.hasPrefix("artisan test --filter="))
        let line = try #require(request.commandLine)
        // A plain environment: no AI-agent variables (Collision would print JSON).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", line]
        process.currentDirectoryURL = URL(fileURLWithPath: fixture)
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.temporaryDirectory.path, "TERM": "dumb"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "\(text)")
        #expect(text.contains("1 passed"), "exactly the matching test: \(text)")
        #expect(!text.contains("returns a successful response"), "the feature test was filtered out: \(text)")
    }
}

/// Tests on the disposable SSH fixture (part of the serialized `SSHRunTests`): the exact argv a
/// terminal tab runs, under a pseudo-terminal.
extension SSHRunTests {
    @Test func testsOnTheServerChooseThereAndGetOneArgument() async throws {
        let environment = try await SSHFixture.environment()
        let client = environment.client()
        let endpoint = environment.endpoint()
        defer { Task { await client.disconnect(endpoint) } }

        // A project with PHPUnit (a stand-in that reports its arguments and folder) and a
        // configuration, in an oddly named directory.
        let directory = "/srv/tests it's \"phpunit\" $HOME"
        try await environment.exec("rm -rf \"$1\" && mkdir -p \"$1/vendor/bin\" \"$1/tests\" && printf '%s\\n' '<phpunit/>' > \"$1/phpunit.xml\" && printf '%s\\n' '<?php foreach (array_slice($argv, 1) as $a) { echo \"ARG[\", $a, \"]\", PHP_EOL; } echo \"PWD[\", getcwd(), \"]\", PHP_EOL;' > \"$1/vendor/bin/phpunit\" && chmod -R a+rX \"$1\"", arguments: [directory])
        let filter = "it's \"odd\" $HOME `uname`"
        let request = try ProjectTests.terminalRequest(target: environment.target(endpoint, directory: directory, php: "/usr/local/bin/php"), action: .filter(filter), place: "fixture", dockerExecutable: nil, ssh: client)
        let started = try PseudoTerminal(try #require(request.executable), environment: client.environment)
        defer { started.stop() }
        #expect(try await started.waitFor { !started.isRunning }, "\(started.text)")
        let text = started.text.replacingOccurrences(of: "\r\n", with: "\n")
        #expect(ProjectTestsTests.arguments(text) == ["--filter=" + filter], "\(text)")
        #expect(text.contains("PWD[\(directory)]"), "\(text)")
        #expect(text.contains("\u{1b}]2;phpunit --filter=\(filter) · fixture\u{07}"), "the exact tab title")

        // The fixture's own app has no test runner: explained, nothing runs.
        let plain = try ProjectTests.terminalRequest(target: environment.target(endpoint), action: .all, place: "fixture", dockerExecutable: nil, ssh: client)
        let none = try PseudoTerminal(try #require(plain.executable), environment: client.environment)
        defer { none.stop() }
        #expect(try await none.waitFor { !none.isRunning }, "\(none.text)")
        #expect(none.text.contains("Runlet: no test runner here"), "\(none.text)")
    }
}

/// `php artisan test` in a Docker profile's container, against the runlet-fixtures `laravel`
/// service only (found with a label-filtered `docker ps`; no other container is listed or touched).
@Suite(.enabled(if: TestSupport.hasDocker, "requires a running Docker engine"))
struct ProjectTestsDockerTests {
    @Test func artisanTestInTheFixtureContainer() async throws {
        let docker = try #require(TestSupport.docker)
        let listed = try await runCommand(docker.spec(["ps", "-q", "--filter", "label=com.docker.compose.project=runlet-fixtures", "--filter", "label=com.docker.compose.service=laravel"]), timeout: .seconds(20))
        let containerId = String(decoding: listed.stdout, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
        try #require(!containerId.isEmpty, "start the fixtures with scripts/setup-fixtures.sh docker")
        let target = TargetSnapshot(kind: .docker, label: "laravel", targetId: "fixture", workingDirectory: "/var/www/html", phpExecutable: "php", containerId: containerId, containerName: "laravel", temporaryDirectory: "/tmp")
        let request = try ProjectTests.terminalRequest(target: target, action: .filter("test_that_true_is_true"), place: "laravel", dockerExecutable: docker.executable)
        var environment = ProcessInfo.processInfo.environment
        for name in environment.keys where name.hasPrefix("CLAUDE") || name.hasPrefix("CODEX") || name == "AI_AGENT" { environment[name] = nil }
        let terminal = try PseudoTerminal(try #require(request.executable), environment: environment)
        defer { terminal.stop() }
        #expect(try await terminal.waitFor(seconds: 120) { !terminal.isRunning }, "\(terminal.text)")
        #expect(terminal.text.contains("\u{1b}]2;artisan test --filter=test_that_true_is_true · laravel\u{07}"), "the container chose artisan test: \(terminal.text)")
        #expect(terminal.text.contains("1 passed"), "\(terminal.text)")
    }
}
