import Foundation
import Testing
@testable import RunletCore

struct TerminalLaunchTests {
    let home = NSTemporaryDirectory()

    private func environment(_ launch: TerminalLaunch) -> [String: String] {
        Dictionary(uniqueKeysWithValues: launch.environment.map { entry in
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
        })
    }

    @Test func plainRequestStartsTheLoginShell() throws {
        let launch = try TerminalLaunch.make(
            for: TerminalRequest(title: "zsh", workingDirectory: "/usr"),
            shell: "/bin/zsh",
            baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": "/Users/me", "LANG": "ro_RO.UTF-8", "SHELL": "/bin/bash"],
            home: home,
            language: "en_US.UTF-8",
            termProgramVersion: "0.1.0"
        )
        #expect(launch.isLoginShell)
        #expect(launch.executable == "/bin/zsh")
        #expect(launch.argv0 == "-zsh")
        #expect(launch.arguments.isEmpty)
        #expect(launch.workingDirectory == "/usr")
        #expect(launch.pendingInput == nil)
        let env = environment(launch)
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["COLORTERM"] == "truecolor")
        #expect(env["TERM_PROGRAM"] == "Runlet")
        #expect(env["TERM_PROGRAM_VERSION"] == "0.1.0")
        #expect(env["LANG"] == "ro_RO.UTF-8", "an inherited LANG is kept")
        #expect(env["PATH"] == "/usr/bin:/bin", "PATH is left to the user's profile")
        #expect(env["HOME"] == "/Users/me")
        #expect(env["SHELL"] == "/bin/zsh")
    }

    @Test func otherTerminalsAndDebuggerVariablesAreDropped() throws {
        let launch = try TerminalLaunch.make(
            for: TerminalRequest(title: "zsh"),
            shell: "/bin/zsh",
            baseEnvironment: [
                "TERM": "dumb", "TERM_PROGRAM": "iTerm.app", "TERM_PROGRAM_VERSION": "3.5", "TERM_SESSION_ID": "w0t0p0",
                "ITERM_SESSION_ID": "x", "SHLVL": "3", "PWD": "/elsewhere", "DYLD_INSERT_LIBRARIES": "/x.dylib",
                "__XPC_DYLD_LIBRARY_PATH": "/y", "TMUX": "/tmp/tmux", "EDITOR": "vim", "COMPOSER_HOME": "/c",
            ],
            home: home,
            language: "en_US.UTF-8"
        )
        let env = environment(launch)
        for key in ["TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "ITERM_SESSION_ID", "SHLVL", "PWD", "DYLD_INSERT_LIBRARIES", "__XPC_DYLD_LIBRARY_PATH", "TMUX"] {
            #expect(env[key] == nil, "\(key) should not reach the shell")
        }
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["TERM_PROGRAM"] == "Runlet")
        #expect(env["EDITOR"] == "vim")
        #expect(env["COMPOSER_HOME"] == "/c")
        #expect(env["LANG"] == "en_US.UTF-8", "LANG is filled in only when missing")
        #expect(launch.environment == launch.environment.sorted())
    }

    @Test func commandLineIsTypedIntoTheShell() throws {
        let launch = try TerminalLaunch.make(
            for: TerminalRequest(title: "migrate", commandLine: "  php artisan migrate:status \n"),
            shell: "/bin/bash", baseEnvironment: [:], home: home, language: "en_US.UTF-8"
        )
        #expect(launch.argv0 == "-bash")
        #expect(launch.pendingInput == "php artisan migrate:status\r")
        let blank = try TerminalLaunch.make(for: TerminalRequest(title: "x", commandLine: "  "), shell: "/bin/zsh", baseEnvironment: [:], home: home, language: "C")
        #expect(blank.pendingInput == nil)
    }

    @Test func missingDirectoryFallsBackToHome() throws {
        let launch = try TerminalLaunch.make(
            for: TerminalRequest(title: "zsh", workingDirectory: "/definitely/not/here"),
            shell: "/bin/zsh", baseEnvironment: [:], home: home, language: "C"
        )
        #expect(launch.workingDirectory == home)
        #expect(TerminalLaunch.workingDirectory(nil, home: home) == home)
        #expect(TerminalLaunch.workingDirectory("~", home: "/x") == NSHomeDirectory())
    }

    @Test func executableRunsDirectlyWithoutAShell() throws {
        let argv = ["docker", "exec", "-it", "-w", "/var/www/html", "abc123", "sh", "-c", "command -v bash >/dev/null && exec bash || exec sh"]
        let launch = try TerminalLaunch.make(
            for: TerminalRequest(title: "app shell", executable: argv),
            shell: "/bin/zsh", baseEnvironment: ["SHELL": "/bin/zsh"], home: home, language: "C",
            resolveExecutable: { $0 == "docker" ? "/usr/local/bin/docker" : nil }
        )
        #expect(!launch.isLoginShell)
        #expect(launch.executable == "/usr/local/bin/docker")
        #expect(launch.argv0 == "docker")
        #expect(launch.arguments == Array(argv.dropFirst()))
        #expect(environment(launch)["TERM"] == "xterm-256color")

        #expect(throws: TerminalLaunch.Failure.executableNotFound("nope")) {
            try TerminalLaunch.make(for: TerminalRequest(title: "x", executable: ["nope"]), shell: "/bin/zsh", baseEnvironment: [:], home: home, language: "C", resolveExecutable: { _ in nil })
        }
        #expect(throws: TerminalLaunch.Failure.emptyCommand) {
            try TerminalLaunch.make(for: TerminalRequest(title: "x", executable: []), shell: "/bin/zsh", baseEnvironment: [:], home: home, language: "C")
        }
    }

    @Test func userShellPrefersTheAccountShell() {
        let all: (String) -> Bool = { _ in true }
        #expect(TerminalLaunch.userShell(accountShell: "/opt/homebrew/bin/fish", environmentShell: "/bin/zsh", isExecutable: all) == "/opt/homebrew/bin/fish")
        #expect(TerminalLaunch.userShell(accountShell: nil, environmentShell: "/bin/bash", isExecutable: all) == "/bin/bash")
        #expect(TerminalLaunch.userShell(accountShell: "/gone/shell", environmentShell: "/bin/bash", isExecutable: { $0 != "/gone/shell" }) == "/bin/bash")
        #expect(TerminalLaunch.userShell(accountShell: nil, environmentShell: nil, isExecutable: all) == "/bin/zsh")
        #expect(TerminalLaunch.userShell().hasPrefix("/"))
    }

    @Test func languageAndExitStatus() {
        #expect(TerminalLaunch.defaultLanguage(locale: Locale(identifier: "ro_RO"), localeExists: { _ in true }) == "ro_RO.UTF-8")
        #expect(TerminalLaunch.defaultLanguage(locale: Locale(identifier: "xx_YY"), localeExists: { _ in false }) == "en_US.UTF-8")
        #expect(TerminalLaunch.exitCode(fromWaitStatus: 0) == 0)
        #expect(TerminalLaunch.exitCode(fromWaitStatus: 3 << 8) == 3)
        #expect(TerminalLaunch.exitCode(fromWaitStatus: SIGHUP) == 128 + SIGHUP)
    }

    @Test func terminalSettingsDecodeTolerantly() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"fontSize": 15}"#.utf8))
        #expect(old.terminalVisible == false)
        #expect(old.terminalHeight == 240)
        #expect(old.terminalOptionAsMeta == false)
        let new = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"terminalVisible": true, "terminalHeight": 300, "terminalOptionAsMeta": true}"#.utf8))
        #expect(new.terminalVisible && new.terminalHeight == 300 && new.terminalOptionAsMeta)
    }
}
