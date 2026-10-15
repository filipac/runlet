import Foundation
import RunletCore

/// Interactive pod launches (#373). Builders do no I/O; callers must preflight immediately
/// before opening a terminal. Snippets still use stdin-only PHP and need no shell.
public enum KubernetesTerminal {
    public static let missingShellMessage = "This container has no shell, so Runlet can't open terminals or commands in it. Snippets still run with Run."

    /// A direct kubectl argv, with the working directory and TMPDIR inside the pod (#373).
    /// Pending input is typed into an interactive sh without Return; it never runs here.
    public static func request(target: TargetSnapshot, title: String, commandLine: String? = nil, pendingInput: String? = nil) throws -> TerminalRequest {
        guard let destination = target.kubernetes, !destination.context.isEmpty, !destination.namespace.isEmpty,
              !destination.container.isEmpty, !destination.pod.name.isEmpty, !destination.pod.uid.isEmpty else {
            throw ExecutionError.invalidTarget("Choose a Kubernetes pod and container before opening a terminal.")
        }
        let command = commandLine ?? (pendingInput == nil
            ? "command -v bash >/dev/null && exec bash || exec sh"
            : "exec sh -l")
        let environment = "export TMPDIR=\(RemoteShell.quote(target.temporaryDirectory ?? "/tmp")); "
        let script = RemoteShell.commandScript(directory: target.workingDirectory, commandLine: environment + command)
        var request = TerminalRequest(title: title, commandLine: pendingInput,
            executable: [destination.executable] + destination.execArguments(["sh", "-lc", script], stdin: true, tty: true),
            runsCommandLine: pendingInput == nil, isCommand: commandLine != nil || pendingInput != nil)
        request.requiresKubernetesRelaunch = true
        return request
    }

    /// Recognizes the runtime's missing executable diagnostic, not access/network errors (#373).
    public static func isMissingShell(_ message: String, executable: String = "sh") -> Bool {
        message.contains("exec: \"\(executable)\": executable file not found")
            || message.contains("exec: \"\(executable)\": stat \(executable): no such file or directory")
    }

    /// Checks identity before probing sh, then again immediately before returning (#373).
    /// The final name-based exec still has a small replacement race; kubectl has no UID flag.
    public static func preflight(target: KubernetesRunTarget) async throws {
        let cli = KubernetesCLI(target: target)
        try await recheck(cli)
        let result = try await runCommand(cli.exec(["sh", "-c", "exit 0"]), timeout: .seconds(10))
        guard result.exitCode == 0 else {
            let message = String(decoding: result.stderr + result.stdout, as: UTF8.self)
            throw ExecutionError.invalidTarget(isMissingShell(message) ? missingShellMessage
                : "Couldn't open a shell in the chosen pod. Check your kubectl exec access and the container's state.\n\n\(message)")
        }
        try await recheck(cli)
        try Task.checkCancellation()
    }

    private static func recheck(_ cli: KubernetesCLI) async throws {
        let pod: KubernetesPod
        do { pod = try await cli.pod() }
        catch KubernetesCLIError.podNotFound {
            throw ExecutionError.invalidTarget("The chosen pod no longer exists. Choose Pod again; nothing ran.")
        }
        guard KubernetesResolver.recheck(pod, target: cli.target) else {
            throw ExecutionError.invalidTarget("The chosen pod was replaced or isn't ready. Choose Pod again; nothing ran.")
        }
    }
}
