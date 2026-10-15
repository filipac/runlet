import Foundation
import RunletCore

/// Log follows bind to one pod identity (#374). Rechecking narrows the name-reuse race;
/// kubectl itself accepts a name, so replacement between this check and launch remains possible.
public enum KubernetesLogFollow {
    public enum Operation: Sendable {
        case follow, find

        var retryMessage: String {
            switch self {
            case .follow: "Click Follow to resolve again; nothing was followed."
            case .find: "Click Find Logs to resolve again; no files were listed."
            }
        }
    }

    public static let endedMessage = "The pod log follow ended. Click Follow to resolve the pod again; Runlet never reconnects automatically."
    public static let noShellMessage = "This container has no shell, so Runlet can't follow files in it; container output still works."

    public static func recheck(_ target: KubernetesRunTarget, operation: Operation = .follow) async throws {
        let pod: KubernetesPod
        do {
            pod = try await KubernetesCLI(target: target).pod()
        } catch KubernetesCLIError.podNotFound {
            throw ExecutionError.invalidTarget("The chosen pod no longer exists. \(operation.retryMessage)")
        }
        guard KubernetesResolver.recheck(pod, target: target) else {
            throw ExecutionError.invalidTarget("The chosen pod was replaced or isn't ready. \(operation.retryMessage)")
        }
        try Task.checkCancellation()
    }

    /// Keep kubectl diagnostics separate from log entries, including a successful stream's EOF (#374).
    public static func explanation(_ output: String, exitCode: Int32, file: Bool, operation: Operation = .follow) -> String {
        let lower = output.lowercased()
        if file, lower.contains("/bin/sh"), lower.contains("exec:") || lower.contains("stat /bin/sh"),
           ["no such file", "not found", "executable file"].contains(where: { lower.contains($0) }) {
            return noShellMessage
        }
        let detail = output.isEmpty ? (exitCode == 0 ? "" : "kubectl exited with code \(exitCode).") : output
        let message = operation == .find
            ? "Runlet couldn't list the log files. Check the container's shell and access, then click Find Logs again."
            : endedMessage
        return detail.isEmpty ? message : detail + "\n\n" + message
    }

    /// Preserve kubectl's tool environment and process group while supplying scoped arguments (#374).
    public static func spec(target: KubernetesRunTarget, path: String? = nil) -> ProcessSpec {
        var spec = KubernetesCLI(target: target).spec([])
        spec.arguments = path.map { LogFollowCommand.kubernetesExecTailArguments(target: target, path: $0) }
            ?? LogFollowCommand.kubernetesLogsArguments(target: target)
        return spec
    }
}
