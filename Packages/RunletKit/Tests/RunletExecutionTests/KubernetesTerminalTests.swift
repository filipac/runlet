import Foundation
import Testing
import RunletCore
@testable import RunletExecution

/// #373: terminal argv and preflight without touching kubeconfig or a real cluster.
struct KubernetesTerminalTests {
    func snapshot(directory: String = "/app", temporary: String = "/scratch", container: String = "app") -> TargetSnapshot {
        var profile = KubernetesProfile(name: "Shop", context: "example", namespace: "shop", labelSelector: "app=shop", container: container)
        profile.kubeconfig = "/config/kube config"
        var target = TargetSnapshot(kind: .kubernetes, label: "Shop", targetId: profile.id.uuidString,
                                    workingDirectory: directory, phpExecutable: "php8.4", temporaryDirectory: temporary)
        target.kubernetes = KubernetesRunTarget(executable: TestSupport.fixtures.appendingPathComponent("fake-kubectl/kubectl").path,
                                              profile: profile, pod: .init(name: "shop-app-a", uid: "shop-app-a-uid"))
        return target
    }
    func prefix(_ target: TargetSnapshot) throws -> [String] {
        [try #require(target.kubernetes).executable, "--kubeconfig", "/config/kube config", "--context", "example", "--namespace", "shop", "exec", "-it", "-c", "app", "shop-app-a", "--", "sh", "-lc"]
    }
    let cd = "cd /app 2>/dev/null || { echo 'Runlet: /app doesn'\\''t exist on this server, or this login can'\\''t open it.' >&2; exit 2; }; export TMPDIR=/scratch; "

    @Test func commandAndPendingInput() throws {
        let target = snapshot()
        var command = ProjectCommand(name: "check", commandLine: "php artisan --version", origin: .driver, source: "Laravel")
        var request = try ProjectCommandLauncher.terminalRequest(for: command, target: target, dockerExecutable: nil)
        #expect(request.executable == (try prefix(target)) + [cd + "php8.4 artisan --version"])
        #expect(request.isCommand && request.runsCommandLine && request.commandLine == nil)
        #expect(request.requiresKubernetesRelaunch)
        command.needsInput = true
        request = try ProjectCommandLauncher.terminalRequest(for: command, target: target, dockerExecutable: nil)
        #expect(request.executable == (try prefix(target)) + [cd + "exec sh -l"])
        #expect(request.commandLine == "php8.4 artisan --version")
        #expect(!request.runsCommandLine && request.isCommand && request.requiresKubernetesRelaunch)
    }

    @Test func replTestsAndShell() throws {
        let target = snapshot()
        let repl = try ProjectREPL.terminalRequest(target: target, place: "Shop", dockerExecutable: nil)
        #expect(repl.executable == (try prefix(target)) + [cd + ProjectREPL.selectionScript(php: "php8.4", place: "Shop")])
        #expect(repl.isCommand && repl.requiresKubernetesRelaunch)
        let tests = try ProjectTests.terminalRequest(target: target, action: .filter("it's $HOME; dangerous"), place: "Shop", dockerExecutable: nil)
        #expect(tests.executable == (try prefix(target)) + [cd + ProjectTests.selectionScript(php: "php8.4", action: .filter("it's $HOME; dangerous"), place: "Shop")])
        #expect(tests.isCommand && tests.requiresKubernetesRelaunch)
        let shell = try KubernetesTerminal.request(target: target, title: "Shell in Pod")
        #expect(shell.executable == (try prefix(target)) + [cd + "command -v bash >/dev/null && exec bash || exec sh"])
        #expect(!shell.isCommand && shell.requiresKubernetesRelaunch)
        #expect(!ProjectTests.isAllowed(on: .production))
    }

    @Test func ttyIsExplicitAndSnippetsStayStdinOnly() throws {
        let destination = try #require(snapshot().kubernetes)
        let flags = ["--kubeconfig", "/config/kube config", "--context", "example", "--namespace", "shop", "exec"]
        let tail = ["-c", "app", "shop-app-a", "--", "php"]
        #expect(destination.execArguments(["php"], stdin: true) == flags + ["-i"] + tail)
        #expect(destination.execArguments(["php"], stdin: true, tty: true) == flags + ["-it"] + tail)
        #expect(KubernetesCLI(target: destination).exec(["php"], stdin: Data()).arguments == flags + ["-i"] + tail)
    }

    @Test func hostileWordsStayLiteralAndCommandRemainsOneScriptArgument() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-373-\(UUID().uuidString)").resolvingSymlinksInPath().appendingPathComponent("it's $HOME; $(false)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let temporary = "/tmp/it's $HOME; $(false)"
        let target = snapshot(directory: directory.path, temporary: temporary)
        let line = "printf '%s\\n' \"$PWD\" \"$TMPDIR\" 'literal; $(false)'"
        let request = try KubernetesTerminal.request(target: target, title: "Quote", commandLine: line)
        let argv = try #require(request.executable)
        #expect(argv.count == (try prefix(target)).count + 1)
        #expect(argv.last == RemoteShell.commandScript(directory: directory.path, commandLine: "export TMPDIR='/tmp/it'\\''s $HOME; $(false)'; " + line))
        let result = try await runCommand(ProcessSpec(executable: "/bin/sh", arguments: ["-lc", try #require(argv.last)]))
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == directory.path + "\n" + temporary + "\nliteral; $(false)\n")
    }

    @Test func missingDirectoryStopsBeforeCommand() async throws {
        let target = snapshot(directory: "/nonexistent/runlet-373")
        let request = try KubernetesTerminal.request(target: target, title: "Missing", commandLine: "echo must-not-run")
        let result = try await runCommand(ProcessSpec(executable: "/bin/sh", arguments: ["-lc", try #require(request.executable?.last)]))
        #expect(result.exitCode == 2)
        #expect(result.stdout.isEmpty)
        #expect(String(decoding: result.stderr, as: UTF8.self).contains("doesn't exist"))
    }

    @Test func preflightAndMissingShell() async throws {
        try await KubernetesTerminal.preflight(target: #require(snapshot().kubernetes))
        do {
            try await KubernetesTerminal.preflight(target: #require(snapshot(container: "no-shell").kubernetes))
            Issue.record("Expected missing shell")
        } catch { #expect(String(describing: error).contains(KubernetesTerminal.missingShellMessage)) }
        #expect(!KubernetesTerminal.isMissingShell("Error from server (Forbidden): pods/exec is forbidden"))
        #expect(!KubernetesTerminal.isMissingShell("exec: \"php\": executable file not found in $PATH"))
    }

    @Test(arguments: ["deleted", "replaced", "not-ready", "forbidden"])
    func preflightRefusesStaleOrInaccessiblePod(_ scenario: String) async throws {
        var target = try #require(snapshot().kubernetes)
        switch scenario {
        case "deleted": target.pod.name = "deleted"
        case "replaced": target.pod.uid = "old-uid"
        case "not-ready": target.container = "not-ready"
        default: target.pod.name = "forbidden"
        }
        do { try await KubernetesTerminal.preflight(target: target); Issue.record("Expected refusal") }
        catch {
            let message = String(describing: error)
            #expect(message.contains(scenario == "deleted" ? "no longer exists" : scenario == "forbidden" ? "Check the profile" : "was replaced or isn't ready"))
            #expect(!message.contains(KubernetesTerminal.missingShellMessage))
        }
    }
}

extension KubernetesTerminalTests {
    /// A successful shell probe doesn't authorize a replacement that appears afterwards (#373).
    @Test func replacementDuringShellProbeIsRefused() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-373-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var destination = try #require(snapshot().kubernetes)
        let wrapper = root.appendingPathComponent("kubectl")
        let script = """
        #!/usr/bin/env python3
        import json, pathlib, subprocess, sys
        marker = pathlib.Path(\(String(reflecting: root.appendingPathComponent("probed").path)))
        result = subprocess.run([\(String(reflecting: destination.executable))] + sys.argv[1:], capture_output=True)
        output = result.stdout
        if 'exec' in sys.argv:
            marker.write_text('ready')
        elif 'pod' in sys.argv and marker.exists():
            pod = json.loads(output)
            pod['metadata']['uid'] = 'replacement-uid'
            output = json.dumps(pod).encode()
        sys.stdout.buffer.write(output)
        sys.stderr.buffer.write(result.stderr)
        sys.exit(result.returncode)
        """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        destination.executable = wrapper.path
        do { try await KubernetesTerminal.preflight(target: destination); Issue.record("Expected final UID check to refuse replacement") }
        catch { #expect(String(describing: error).contains("was replaced or isn't ready")) }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("probed").path))
    }
}
