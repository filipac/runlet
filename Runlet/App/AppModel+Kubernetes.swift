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
                kubernetesChoice = KubernetesChoice(tabId: tab.id, profile: profile, pods: pods.filter { $0.eligible(container: profile.container) })
            } catch { alert = AppAlert(title: "Couldn't list pods", message: "\(error)") }
        }
    }

    func confirmKubernetesPod(_ pod: KubernetesPod, choice: KubernetesChoice, pin: Bool) {
        guard var profile = library.kubernetesProfile(choice.profile.id), profile.revision == choice.profile.revision else {
            kubernetesChoice = nil
            alert = AppAlert(title: "The profile changed", message: "Choose Pod again with the updated profile.")
            return
        }
        if pin {
            profile.pinnedPod = pod.identity
            saveKubernetesProfile(profile)
        } else {
            kubernetesChoices[choice.tabId] = pod.identity
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
        let choice = kubernetesChoices.removeValue(forKey: tab.id)
        switch KubernetesResolver.resolve(profile, pods: pods, choice: choice) {
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
            throw TargetResolutionError(description: "Several Ready pods match. Choose one, then run again.")
        case .unavailable(let message):
            tab.targetIssue = message
            throw TargetResolutionError(description: message)
        }
    }
}
