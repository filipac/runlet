import Foundation
import RunletCore
import RunletExecution

/// Profile Run (#41): which profiler the PHP of a tab's target loads, and whether Profile Run
/// can run there. A Profile Run is an ordinary run (same production guard, same explicit
/// target resolution) whose request asks the runner to sample the snippet with Excimer.
extension AppModel {
    /// What is known about the profiler extensions of the PHP that runs `target`'s code, and
    /// how to name that PHP in a reason. Local PHP comes from discovery (fresh each launch);
    /// containers, servers, and the Docker sandbox from their last run or probe.
    func profilerFacts(for target: TargetRef) -> (profilers: PHPProfilers?, php: String) {
        let learned = targetFacts[target.stableKey]?.profilers
        switch target {
        case .sandbox:
            if case .ready(.local(let php)) = sandboxStatus {
                let known = installation(at: php.path) ?? php
                return (known.profilers ?? learned, Self.describe(known))
            }
            return (learned, "the sandbox image's PHP")
        case .local(let id):
            let path = library.localProject(id)?.phpExecutable ?? settings.defaultPHPExecutable ?? bestPHP?.path
            if let path, let known = installation(at: path) {
                return (known.profilers ?? learned, Self.describe(known))
            }
            return (learned, "this project's PHP")
        case .docker:
            return (learned, "this container's PHP")
        case .ssh(let id):
            let profile = library.sshProfile(id)
            let host = profile?.destinationLabel ?? "the server"
            return (learned, profile?.container == nil ? "the PHP on \(host)" : "the container's PHP on \(host)")
        }
    }

    /// Whether Profile Run is available for the tab (and why not); nil without a tab.
    func profileRunAvailability(for tab: TabModel?) -> ProfileRunAvailability? {
        guard let tab else { return nil }
        if tab.language == .sql { return .unavailable("Profile Run profiles PHP; SQL tabs run a database statement.") }
        let facts = profilerFacts(for: tab.target)
        return ProfileRunAvailability.evaluate(facts.profilers, php: facts.php)
    }

    /// Run ▸ Profile Run: runs the tab like Run, sampled by Excimer, then shows the flame graph.
    func profileRun(_ tab: TabModel) {
        guard profileRunAvailability(for: tab)?.isEnabled ?? false else { return }
        run(tab, profile: true)
    }

    /// Remembers what a probe found about a target's PHP (Docker Test, SSH Test Connection).
    func noteProfilers(_ profilers: PHPProfilers?, for target: TargetRef) {
        guard let profilers else { return }
        var facts = targetFacts[target.stableKey] ?? TargetFacts()
        facts.profilers = profilers
        if targetFacts[target.stableKey] != facts { targetFacts[target.stableKey] = facts }
    }

    /// The discovered installation at `path` (compared with symbolic links resolved).
    func installation(at path: String) -> PHPInstallation? {
        let resolved = (path as NSString).resolvingSymlinksInPath
        return phpInstallations.first { $0.path == path || ($0.path as NSString).resolvingSymlinksInPath == resolved }
    }

    private static func describe(_ php: PHPInstallation) -> String {
        "PHP \(php.version) (\(php.source))"
    }
}

/// How probes and Settings describe a PHP's profilers.
enum ProfilerText {
    static func probeDescription(_ profilers: PHPProfilers) -> String {
        if profilers.canProfile {
            return profilers.summary + " · Profile Run can sample this PHP"
        }
        if profilers.spx != nil {
            return profilers.summary + " · Profile Run needs Excimer (Runlet can't read SPX's profiles)"
        }
        return "None · Profile Run needs the Excimer extension"
    }
}
