import Foundation
import Testing
@testable import RunletCore

/// Starts real shells with `ShellIntegration` inside a pseudo-terminal (`script(1)`), using
/// temporary HOME, ZDOTDIR, and XDG directories only (never the developer's dotfiles), and
/// checks that the ready marker arrives only once startup is over: not while an rc file is
/// asking a question, and with the user's ZDOTDIR, PROMPT_COMMAND, and namespace restored.
/// A shell that is not installed is skipped.
@Suite(.serialized)
struct ShellIntegrationLiveTests {
    static let script = "/usr/bin/script"
    static let question = "dotenv: found '.env' file. Source it?"

    static func available(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: script) && FileManager.default.isExecutableFile(atPath: path)
    }

    /// A temporary sandbox: `root` holds the integration scripts (in a path with a space),
    /// `home` is the shell's HOME.
    struct Sandbox {
        let base: URL
        var root: URL { base.appendingPathComponent("Application Support/ShellIntegration", isDirectory: true) }
        var home: URL { base.appendingPathComponent("home", isDirectory: true) }

        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-live-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: base.appendingPathComponent("home"), withIntermediateDirectories: true)
            try ShellIntegration.install(in: root)
        }

        func write(_ path: String, _ text: String) throws {
            let url = base.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func environment(_ extra: [String: String] = [:]) -> [String: String] {
            var environment = [
                "HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
                "USER": NSUserName(), "LOGNAME": NSUserName(), "TMPDIR": NSTemporaryDirectory(),
                "XDG_CONFIG_HOME": base.appendingPathComponent("xdg/config").path,
                "XDG_DATA_HOME": base.appendingPathComponent("xdg/data").path,
                "XDG_CACHE_HOME": base.appendingPathComponent("xdg/cache").path,
            ]
            environment.merge(extra) { $1 }
            return environment
        }

        func launch(shell: String, environment: [String: String]) throws -> TerminalLaunch {
            try TerminalLaunch.make(
                for: TerminalRequest(title: "test", commandLine: "echo ready"),
                shell: shell, baseEnvironment: environment, home: home.path, language: "en_US.UTF-8",
                shellIntegration: root
            )
        }

        func remove() { try? FileManager.default.removeItem(at: base) }
    }

    // MARK: zsh

    @Test(.enabled(if: available("/bin/zsh")))
    func zshReportsReadyOnlyAfterAnRCQuestionIsAnswered() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let zdotdir = sandbox.base.appendingPathComponent("zdot dir").path
        try sandbox.write("zdot dir/.zshenv", "zshenv_ran=1\n")
        try sandbox.write("zdot dir/.zprofile", "zprofile_ran=1\n")
        try sandbox.write("zdot dir/.zshrc", """
        zshrc_ran=1
        if read -q "REPLY?\(Self.question) ([y]es/[N]o) "; then zshrc_answer=yes; else zshrc_answer=no; fi

        """)
        try sandbox.write("zdot dir/.zlogin", "zlogin_ran=1\n")
        let launch = try sandbox.launch(shell: "/bin/zsh", environment: sandbox.environment(["ZDOTDIR": zdotdir]))
        let shell = try LiveShell(launch: launch, loginFlag: true, directory: sandbox.home)
        defer { shell.stop() }

        #expect(try await shell.waitFor { shell.text.contains(Self.question) }, "the rc file's question appears: \(shell.text)")
        #expect(!shell.markerSeen, "no marker while the question waits")
        try await Task.sleep(for: .milliseconds(1500))
        #expect(!shell.markerSeen, "still no marker: a command typed now would answer the question")

        shell.send("y")
        #expect(try await shell.waitFor { shell.markerSeen }, "marker after the answer: \(shell.text)")
        #expect(!shell.textBeforeMarker.contains("ShellIntegration") && !shell.textBeforeMarker.lowercased().contains("runlet"), "nothing printed by the integration: \(shell.textBeforeMarker)")

        let result = try await shell.result(#"print -r -- "RES""ULT zd=[${ZDOTDIR-unset}] type=[${(t)ZDOTDIR}] hf=[$HISTFILE] env=[${RUNLET_USER_ZDOTDIR-x}${RUNLET_SHELL_READY_TOKEN-x}] ran=[$zshenv_ran$zprofile_ran$zshrc_ran$zlogin_ran] ans=[$zshrc_answer] left=[${#${(M)${(k)functions}:#*runlet*}}${#${(M)${(k)parameters}:#*runlet*}}${#${(M)precmd_functions:#*runlet*}}] login=[${options[login]}]""#)
        #expect(result.contains("zd=[\(zdotdir)]"), "the user's ZDOTDIR is back: \(result)")
        #expect(result.contains("type=[scalar-export]"), "and still exported: \(result)")
        #expect(result.contains("hf=[\(zdotdir)/.zsh_history]"), "history goes where /etc/zshrc would put it: \(result)")
        #expect(result.contains("env=[xx]"), "integration variables are unset: \(result)")
        #expect(result.contains("ran=[1111]"), "every user startup file ran: \(result)")
        #expect(result.contains("ans=[yes]"), "the question got the user's answer: \(result)")
        #expect(result.contains("left=[000]"), "no functions, variables, or hooks left behind: \(result)")
        #expect(result.contains("login=[on]"), "still a login shell: \(result)")
        await shell.exit()
    }

    @Test(.enabled(if: available("/bin/zsh")))
    func zshFollowsAZdotdirSetByTheUsersZshenv() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.write("home/.zshenv", "ZDOTDIR=$HOME/cfg\nhome_env=1\n")
        try sandbox.write("home/.zshrc", "home_rc=1\n")
        try sandbox.write("home/cfg/.zprofile", "cfg_profile=1\n")
        try sandbox.write("home/cfg/.zshrc", "cfg_rc=1\n")
        try sandbox.write("home/cfg/.zlogin", "cfg_login=1\n")
        let launch = try sandbox.launch(shell: "/bin/zsh", environment: sandbox.environment())
        let shell = try LiveShell(launch: launch, loginFlag: true, directory: sandbox.home)
        defer { shell.stop() }

        #expect(try await shell.waitFor { shell.markerSeen }, "marker without any input: \(shell.text)")
        let cfg = sandbox.home.appendingPathComponent("cfg").path
        let result = try await shell.result(#"print -r -- "RES""ULT zd=[${ZDOTDIR-unset}] type=[${(t)ZDOTDIR}] hf=[$HISTFILE] ran=[$home_env$cfg_profile$cfg_rc$cfg_login] home_rc=[${home_rc-unset}] left=[${#${(M)${(k)functions}:#*runlet*}}${#${(M)${(k)parameters}:#*runlet*}}]""#)
        #expect(result.contains("zd=[\(cfg)]"), "\(result)")
        #expect(result.contains("type=[scalar]"), "not exported, as the user's .zshenv left it: \(result)")
        #expect(result.contains("hf=[\(cfg)/.zsh_history]"), "\(result)")
        #expect(result.contains("ran=[1111]"), "files come from the new ZDOTDIR: \(result)")
        #expect(result.contains("home_rc=[unset]"), "~/.zshrc is not read when ZDOTDIR moved: \(result)")
        #expect(result.contains("left=[00]"), "\(result)")
        await shell.exit()
    }

    @Test(.enabled(if: available("/bin/zsh")))
    func zshWithNoRCsStillReportsReady() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.write("home/.zshenv", "setopt no_rcs\n")
        try sandbox.write("home/.zshrc", "home_rc=1\n")
        let launch = try sandbox.launch(shell: "/bin/zsh", environment: sandbox.environment())
        let shell = try LiveShell(launch: launch, loginFlag: true, directory: sandbox.home)
        defer { shell.stop() }

        #expect(try await shell.waitFor { shell.markerSeen }, "\(shell.text)")
        let result = try await shell.result(#"print -r -- "RES""ULT zd=[${ZDOTDIR-unset}] home_rc=[${home_rc-unset}] left=[${#${(M)${(k)functions}:#*runlet*}}${#${(M)${(k)parameters}:#*runlet*}}]""#)
        #expect(result.contains("zd=[unset]"), "\(result)")
        #expect(result.contains("home_rc=[unset]"), "\(result)")
        #expect(result.contains("left=[00]"), "\(result)")
        await shell.exit()
    }

    @Test(.enabled(if: available("/bin/zsh")))
    func zshHooksSurviveUnusualOptionsAndHooksFromTheRCFile() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.write("home/.zshrc", """
        setopt ksh_arrays no_unset warn_create_global sh_word_split glob_subst
        user_hook() { user_hook_ran=1; }
        precmd_functions=(user_hook)

        """)
        let launch = try sandbox.launch(shell: "/bin/zsh", environment: sandbox.environment())
        let shell = try LiveShell(launch: launch, loginFlag: true, directory: sandbox.home)
        defer { shell.stop() }

        #expect(try await shell.waitFor { shell.markerSeen }, "\(shell.text)")
        #expect(!shell.textBeforeMarker.contains("runlet"), "no warnings or errors: \(shell.textBeforeMarker)")
        let result = try await shell.result(#"print -r -- "RES""ULT hooks=[${precmd_functions[*]}] ran=[${user_hook_ran-}] zd=[${ZDOTDIR-unset}] left=[${#${(M)${(k)functions}:#*runlet*}}]""#)
        #expect(result.contains("hooks=[user_hook]"), "only the user's hook is left: \(result)")
        #expect(result.contains("ran=[1]"), "\(result)")
        #expect(result.contains("zd=[unset]"), "\(result)")
        #expect(result.contains("left=[0]"), "\(result)")
        #expect(!shell.text.contains("runlet:") && !shell.text.contains("_runlet"), "no errors from the hook: \(shell.text)")
        await shell.exit()
    }

    // MARK: bash

    @Test(arguments: ["/bin/bash", "/opt/homebrew/bin/bash", "/usr/local/bin/bash"])
    func bashReportsReadyOnlyAfterAProfileQuestionIsAnswered(_ bash: String) async throws {
        guard Self.available(bash) else { return }
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.write("home/.bash_profile", """
        PROMPT_COMMAND='user_pc=1'
        profile_ran=1
        read -n 1 -p "\(Self.question) " answer

        """)
        try sandbox.write("home/.bashrc", "bashrc_ran=1\n")
        let launch = try sandbox.launch(shell: bash, environment: sandbox.environment(["BASH_SILENCE_DEPRECATION_WARNING": "1"]))
        let shell = try LiveShell(launch: launch, loginFlag: false, directory: sandbox.home)
        defer { shell.stop() }

        #expect(try await shell.waitFor { shell.text.contains(Self.question) }, "\(shell.text)")
        try await Task.sleep(for: .milliseconds(1500))
        #expect(!shell.markerSeen, "no marker while the question waits")
        shell.send("y")
        #expect(try await shell.waitFor { shell.markerSeen }, "marker after the answer: \(shell.text)")
        #expect(!shell.textBeforeMarker.contains("ShellIntegration") && !shell.textBeforeMarker.contains("runlet"), "\(shell.textBeforeMarker)")

        let result = try await shell.result(#"echo "RES""ULT pc=[${PROMPT_COMMAND-unset}] ran=[${profile_ran-}${bashrc_ran-}${user_pc-}] ans=[$answer] left=[$(declare -F | grep -c runlet)$(compgen -v | grep -c runlet)] env=[${RUNLET_SHELL_READY_TOKEN-x}]""#)
        #expect(result.contains("pc=[user_pc=1]"), "the user's PROMPT_COMMAND is back: \(result)")
        #expect(result.contains("ran=[11]"), "~/.bash_profile ran (and ran PROMPT_COMMAND), ~/.bashrc did not: \(result)")
        #expect(result.contains("ans=[y]"), "\(result)")
        #expect(result.contains("left=[00]"), "\(result)")
        #expect(result.contains("env=[x]"), "\(result)")
        await shell.exit()
    }

    @Test(arguments: ["/bin/bash", "/opt/homebrew/bin/bash", "/usr/local/bin/bash"])
    func bashWithoutProfileOrPromptCommand(_ bash: String) async throws {
        guard Self.available(bash) else { return }
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.write("home/.profile", "profile_ran=1\n")
        let launch = try sandbox.launch(shell: bash, environment: sandbox.environment(["BASH_SILENCE_DEPRECATION_WARNING": "1"]))
        let shell = try LiveShell(launch: launch, loginFlag: false, directory: sandbox.home)
        defer { shell.stop() }

        #expect(try await shell.waitFor { shell.markerSeen }, "\(shell.text)")
        let result = try await shell.result(#"echo "RES""ULT pc=[${PROMPT_COMMAND-unset}] ran=[${profile_ran-}] left=[$(declare -F | grep -c runlet)$(compgen -v | grep -c runlet)]""#)
        #expect(result.contains("pc=[unset]"), "\(result)")
        #expect(result.contains("ran=[1]"), "~/.profile is read when there is no ~/.bash_profile: \(result)")
        #expect(result.contains("left=[00]"), "\(result)")
        await shell.exit()
    }

    // MARK: fish

    @Test(arguments: ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"])
    func fishReportsReadyOnlyAfterAConfigQuestionIsAnswered(_ fish: String) async throws {
        guard Self.available(fish) else { return }
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.write("xdg/config/fish/config.fish", """
        set -g fish_greeting
        set -g config_ran 1
        read --nchars 1 --prompt-str "\(Self.question) " answer

        """)
        let launch = try sandbox.launch(shell: fish, environment: sandbox.environment())
        let shell = try LiveShell(launch: launch, loginFlag: true, directory: sandbox.home)
        defer { shell.stop() }

        #expect(try await shell.waitFor { shell.text.contains(Self.question) }, "\(shell.text)")
        try await Task.sleep(for: .milliseconds(1500))
        #expect(!shell.markerSeen, "no marker while the question waits")
        shell.send("y")
        #expect(try await shell.waitFor { shell.markerSeen }, "marker after the answer: \(shell.text)")

        let result = try await shell.result(#"echo "RES""ULT ran=[$config_ran] ans=[$answer] left=[$(functions --all | string match '*runlet*' | count)] login=[$(status is-login; and echo yes; or echo no)]""#)
        #expect(result.contains("ran=[1]"), "\(result)")
        #expect(result.contains("ans=[y]"), "\(result)")
        #expect(result.contains("left=[0]"), "\(result)")
        #expect(result.contains("login=[yes]"), "\(result)")
        await shell.exit()
    }
}

/// A shell running under `script -q /dev/null …` (which gives it a pseudo-terminal as its
/// controlling terminal), fed through a pipe, with its output collected and scanned. It
/// answers Primary Device Attributes queries like a terminal (fish 4 waits up to 10 s for one).
final class LiveShell: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var scanner: ShellIntegration.ReadyScanner
    private var markerEnd: Int?

    /// - Parameter loginFlag: passes `-l` (script cannot set `argv[0]` to `-zsh`/`-fish`).
    init(launch: TerminalLaunch, loginFlag: Bool, directory: URL) throws {
        let token = try #require(launch.readyToken, "the launch uses the shell integration")
        scanner = ShellIntegration.ReadyScanner(token: token)
        process.executableURL = URL(fileURLWithPath: ShellIntegrationLiveTests.script)
        process.arguments = ["-q", "/dev/null", launch.executable] + (loginFlag ? ["-l"] : []) + launch.arguments
        process.environment = Dictionary(uniqueKeysWithValues: launch.environment.map { entry in
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
        })
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.received(handle.availableData)
        }
        try process.run()
    }

    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        if markerEnd == nil, scanner.scan(data) { markerEnd = buffer.count }
        let queries = String(decoding: data, as: UTF8.self).components(separatedBy: "\u{1b}[0c").count - 1
        for _ in 0..<queries { send("\u{1b}[?62;22c") }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }

    var markerSeen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return markerEnd != nil
    }

    /// Output up to (not including) the chunk that completed the marker.
    var textBeforeMarker: String {
        lock.lock()
        defer { lock.unlock() }
        let end = markerEnd ?? buffer.count
        let text = String(decoding: buffer.prefix(end), as: UTF8.self)
        return text.components(separatedBy: "\u{1b}]6973;").first ?? text
    }

    func send(_ text: String) {
        input.fileHandleForWriting.write(Data(text.utf8))
    }

    func waitFor(seconds: Double = 15, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    /// Types `command` (which prints a line starting with `RESULT `) and returns that line
    /// (empty, with a recorded issue, when it never appears).
    func result(_ command: String) async throws -> String {
        // Give the line editor a moment to take over the terminal, as the app does.
        try await Task.sleep(for: .milliseconds(300))
        send(command + "\r")
        guard try await waitFor({ self.resultLine != nil }), let line = resultLine else {
            Issue.record("no RESULT line in: \(text)")
            return ""
        }
        return line
    }

    /// The first complete output line starting with `RESULT ` (the typed command spells it
    /// `"RES""ULT`, so its echo never matches).
    private var resultLine: String? {
        let text = text
        guard let range = text.range(of: "RESULT ") else { return nil }
        let rest = text[range.lowerBound...]
        // "\r\n" is a single Character, so look for any newline character.
        guard let end = rest.firstIndex(where: \.isNewline) else { return nil }
        return String(rest[..<end])
    }

    func exit() async {
        send("exit\r")
        _ = try? await waitFor(seconds: 5) { !self.process.isRunning }
        stop()
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }
}
