import Foundation
import RunletCore
import RunletExecution

/// A pod choice belongs to the requesting tab's window and never resumes a run (#33).
struct KubernetesChoice: Identifiable {
    let id = UUID()
    var tabId: UUID
    var profile: KubernetesProfile
    var pods: [KubernetesPod]
}

extension AppModel {
    func kubernetesCLI(_ profile: KubernetesProfile) throws -> KubernetesCLI {
        let configured = settings.kubectlExecutable.flatMap { $0.isEmpty ? nil : $0 } ?? "kubectl"
        guard let executable = ExecutableLocator.resolve(configured) else {
            throw TargetResolutionError(description: "kubectl wasn't found. Install it or set its path in Settings ▸ General.")
        }
        return KubernetesCLI(executable: executable, profile: profile)
    }

    func touchKubernetesProfile(_ id: UUID) {
        guard let index = library.kubernetesProfiles.firstIndex(where: { $0.id == id }) else { return }
        library.kubernetesProfiles[index].lastOpenedAt = Date()
        saveLibrary()
        let profile = library.kubernetesProfiles[index]
        guard profile.autoResolve, profile.environment != .production else { return }
        Task {
            do {
                let cli = try kubernetesCLI(profile)
                let pods = try await cli.pods(selector: profile.labelSelector)
                let result = KubernetesResolver.resolve(profile, pods: pods)
                for tab in allTabs where tab.target == .kubernetes(id) {
                    switch result {
                    case .resolved: tab.targetIssue = nil
                    case .ambiguous: tab.targetIssue = "Several Ready pods match. Choose Pod before running."
                    case .unavailable(let message): tab.targetIssue = message
                    }
                }
            } catch {
                for tab in allTabs where tab.target == .kubernetes(id) { tab.targetIssue = "\(error)" }
            }
        }
    }

    func chooseKubernetesPod() {
        guard let tab = selectedTab, case .kubernetes(let id) = tab.target,
              let profile = library.kubernetesProfile(id) else { return }
        Task {
            do {
                let pods = try await kubernetesCLI(profile).pods(selector: profile.labelSelector)
                let eligible = pods.filter { $0.eligible(container: profile.container) }
                guard !eligible.isEmpty else {
                    throw TargetResolutionError(description: KubernetesResolver.noReadyPodMessage(container: profile.container))
                }
                kubernetesChoice = KubernetesChoice(tabId: tab.id, profile: profile, pods: eligible)
            } catch { alert = AppAlert(title: "Couldn't list pods", message: "\(error)") }
        }
    }

    func confirmKubernetesPod(_ pod: KubernetesPod, choice: KubernetesChoice, pin: Bool) {
        guard var profile = library.kubernetesProfile(choice.profile.id), profile.revision == choice.profile.revision,
              allTabsWithQuickRun.contains(where: { $0.id == choice.tabId && $0.target == .kubernetes(profile.id) }) else {
            kubernetesChoice = nil
            alert = AppAlert(title: "The profile changed", message: "Choose Pod again with the updated profile.")
            return
        }
        if pin {
            profile.pinnedPod = pod.identity
            saveKubernetesProfile(profile)
        } else {
            kubernetesChoices[choice.tabId] = KubernetesTabChoice(profile: profile, pod: pod.identity)
        }
        kubernetesChoice = nil
    }

    func kubernetesSnapshot(for tab: TabModel, profileId: UUID) async throws -> TargetSnapshot {
        guard let profile = library.kubernetesProfile(profileId) else {
            throw TargetResolutionError(description: "This Kubernetes profile was removed. Choose another target.")
        }
        guard profile.validate().isEmpty else { throw TargetResolutionError(description: profile.validate().joined(separator: "\n")) }
        let cli = try kubernetesCLI(profile)
        let pods = try await cli.pods(selector: profile.labelSelector)
        guard library.kubernetesProfile(profileId)?.revision == profile.revision, tab.target == .kubernetes(profileId) else {
            throw TargetResolutionError(description: "The target changed while resolving. Run again.")
        }
        let result: KubernetesResolution
        if var choice = kubernetesChoices[tab.id], choice.matches(profile) {
            result = choice.resolve(profile, pods: pods)
            kubernetesChoices[tab.id] = choice
        } else {
            kubernetesChoices[tab.id] = nil
            result = KubernetesResolver.resolve(profile, pods: pods)
        }
        switch result {
        case .resolved(let pod):
            if let index = library.kubernetesProfiles.firstIndex(where: { $0.id == profileId }) {
                library.kubernetesProfiles[index].lastPod = pod.identity
                saveLibrary()
            }
            tab.targetIssue = nil
            var snapshot = TargetSnapshot(kind: .kubernetes, label: "\(profile.name) · \(profile.context)/\(profile.namespace) · \(pod.name) · \(profile.container)", targetId: profile.id.uuidString, profileRevision: profile.revision, workingDirectory: profile.workingDirectory, phpExecutable: profile.phpExecutable, temporaryDirectory: profile.temporaryDirectory)
            snapshot.kubernetes = KubernetesRunTarget(executable: cli.target.executable, profile: profile, pod: pod.identity)
            return snapshot
        case .ambiguous(let pods):
            kubernetesChoice = KubernetesChoice(tabId: tab.id, profile: profile, pods: pods)
            throw TargetResolutionError(description: "Choose a Ready pod, then run again.")
        case .unavailable(let message):
            tab.targetIssue = message
            throw TargetResolutionError(description: message)
        }
    }
}

extension AppModel {
    /// Captures the approved profile, so editing it while a confirmation is open cancels (#373).
    func kubernetesRevision(for target: TargetRef) -> Int? {
        guard case .kubernetes(let id) = target else { return nil }
        return library.kubernetesProfile(id)?.revision
    }

    /// The last awaited work before a pod terminal opens (#373). A changed target/profile
    /// invalidates the action, including a production marking changed during the probe.
    func prepareKubernetesTerminal(_ snapshot: TargetSnapshot, for tab: TabModel, target: TargetRef) async throws {
        guard target.isKubernetes else { return }
        guard let destination = snapshot.kubernetes, tab.target == target else {
            throw TargetResolutionError(description: "The target changed while opening the terminal. Start the action again.")
        }
        try await KubernetesTerminal.preflight(target: destination)
        guard case .kubernetes(let id) = target, tab.target == target,
              allTabsWithQuickRun.contains(where: { $0.id == tab.id }),
              library.kubernetesProfile(id)?.revision == snapshot.profileRevision else {
            throw TargetResolutionError(description: "The target changed while opening the terminal. Start the action again.")
        }
    }

    /// Run Again keeps the old output and re-enters the original action in a new terminal
    /// (#373). It cannot reuse argv or silently follow an editor tab to another target.
    func setKubernetesRelaunch(_ request: TerminalRequest, tab: TabModel, target: TargetRef, window: WindowModel?,
                              action: @escaping (AppModel, TabModel, WindowModel) -> Void) {
        guard request.requiresKubernetesRelaunch, let window = window ?? activeWindow,
              let session = window.terminals.sessions.first(where: { $0.id == request.id }) else { return }
        session.kubernetesRelaunch = { [weak self, weak tab, weak window] in
            guard let self, let window else { return }
            guard let tab, tab.target == target, window.tabs.contains(where: { $0.id == tab.id }) else {
                self.alert = AppAlert(title: "Couldn't run again", message: "The original tab was closed or changed targets. Open the Kubernetes target and start the action again.")
                return
            }
            action(self, tab, window)
        }
    }

    /// Shell in Pod connects only after an explicit action and production confirmation (#373).
    func openKubernetesShell(for tab: TabModel, in window: WindowModel) {
        let target = tab.target
        guard target.isKubernetes else { return }
        let revision = kubernetesRevision(for: target)
        guardProduction(.shell, target: target, text: "Open a shell in the selected pod", in: window) { [weak self, weak tab, weak window] in
            guard let self, let tab, let window, tab.target == target, self.kubernetesRevision(for: target) == revision else { return }
            Task {
                guard tab.target == target, self.kubernetesRevision(for: target) == revision else { return }
                do {
                    let snapshot = try await self.snapshot(for: tab)
                    let request = try KubernetesTerminal.request(target: snapshot, title: "Shell · \(snapshot.kubernetes?.pod.name ?? "Pod")")
                    try await self.prepareKubernetesTerminal(snapshot, for: tab, target: target)
                    self.openTerminal(request, in: window)
                } catch {
                    guard self.kubernetesChoice == nil else { return }
                    self.alert = AppAlert(title: "Couldn't open a shell in the pod", message: "\(error)")
                }
            }
        }
    }
}
