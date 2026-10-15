import Darwin
import Foundation
import RunletCore

/// Stdin-only PHP execution in one snapshotted pod (#33). Stop never deletes a pod.
enum KubernetesExecAdapter {
    static func prepare(target: TargetSnapshot, runId: UUID, script: Data) async throws -> PreparedLaunch {
        guard let destination = target.kubernetes, !destination.context.isEmpty, !destination.namespace.isEmpty,
              !destination.container.isEmpty, !destination.pod.name.isEmpty, !destination.pod.uid.isEmpty else {
            throw ExecutionError.invalidTarget("Choose a Kubernetes pod and container before running.")
        }
        let cli = KubernetesCLI(target: destination)
        let pod = try await cli.pod()
        guard KubernetesResolver.recheck(pod, target: destination) else {
            throw ExecutionError.invalidTarget("The chosen pod was replaced or isn't ready. Choose Pod again; nothing ran.")
        }
        let command = ["env", "RUNLET_RUN_ID=\(runId.uuidString)", "TMPDIR=\(target.temporaryDirectory ?? "/tmp")", target.phpExecutable] + RunnerBundle.phpArguments
        var launch = PreparedLaunch(spec: cli.exec(command, stdin: script)) { process, control in
            await stopInPod(cli: cli, php: target.phpExecutable, runId: runId, process: process, control: control)
        }
        launch.stdinNote = "Pod \(destination.pod.name) · UID \(destination.pod.uid) · container \(destination.container)"
        launch.explainFailure = { output, _, started in
            guard !started else { return nil }
            return "PHP couldn't start in the chosen pod. The image must contain env and the profile's PHP executable; no shell is needed for runs. Check the working directory and permissions.\n\n\(output)"
        }
        return launch
    }

    static func signal(cli: KubernetesCLI, php: String, pid: Int, runId: UUID, signal: Int32) async -> String {
        // A name can be reused after deletion: never signal a replacement pod (#33).
        guard let pod = try? await cli.pod(), pod.identity == cli.target.pod else { return "error: pod identity could not be verified" }
        let command = [php, "-r", RemoteSignal.runnerOnlyHelper, "--", String(pid), runId.uuidString, String(signal)]
        guard let result = try? await runCommand(cli.exec(command), timeout: .seconds(5)) else { return "error" }
        guard result.exitCode == 0 else { return "error: " + String(decoding: result.stderr, as: UTF8.self) }
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stopInPod(cli: KubernetesCLI, php: String, runId: UUID, process: SupervisedProcess, control: RunControl) async -> CancelOutcome {
        guard let pid = await control.waitForRunnerPid(timeout: .seconds(2)) else {
            let message = "The runner had not reported its process ID, so only the local kubectl client was stopped; PHP may still be starting inside the pod."
            control.setCancelNote(message)
            await process.terminate(grace: .milliseconds(300))
            return CancelOutcome(confirmed: false, message: message)
        }

        var outcome = await signal(cli: cli, php: php, pid: pid, runId: runId, signal: SIGTERM)
        if outcome == "unsupported" || outcome.hasPrefix("error") || outcome == "failed" {
            let message = "Could not signal PHP inside the pod (\(outcome)). The kubectl client was stopped, but the runner (pid \(pid)) may still be running."
            control.setCancelNote(message)
            await process.terminate(grace: .milliseconds(300))
            return CancelOutcome(confirmed: false, message: message)
        }
        if outcome != "gone" && outcome != "mismatch" {
            // `kubectl exec` returns once the runner exits.
            if !(await process.waitForExit(within: .milliseconds(1500))) {
                outcome = await signal(cli: cli, php: php, pid: pid, runId: runId, signal: SIGKILL)
                _ = await process.waitForExit(within: .seconds(3))
            }
        }
        let check = await signal(cli: cli, php: php, pid: pid, runId: runId, signal: 0)
        let confirmed = KubernetesResolver.stopConfirmed(check)
        let message = confirmed ? "Stopped the runner inside the pod; the pod keeps running." : "The runner (pid \(pid)) is still running inside the pod (\(check))."
        if !confirmed { control.setCancelNote(message) }
        if !process.hasExited { await process.terminate(grace: .milliseconds(300)) }
        return CancelOutcome(confirmed: confirmed, message: message)
    }
}
