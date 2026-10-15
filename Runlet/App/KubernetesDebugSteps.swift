#if DEBUG
import AppKit
import RunletCore

/// #33: fake-kubectl-only screenshots. No credentials or real cluster calls.
/// `kubernetes:editor`, `kubernetes:list`, `kubernetes:choose`, `kubernetes:confirm`,
/// and `kubernetes:state` operate on the seeded scratch profile.
@MainActor
enum KubernetesDebugSteps {
    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        guard name == "kubernetes" else { return false }
        switch argument {
        case "editor":
            if let profile = model.library.kubernetesProfiles.first { model.showProfileManager(selecting: .kubernetes(profile.id)) }
        case "list":
            NotificationCenter.default.post(name: .debugKubernetesList, object: nil)
        case "choose": model.chooseKubernetesPod()
        case "confirm":
            if let choice = model.kubernetesChoice, let pod = choice.pods.first { model.confirmKubernetesPod(pod, choice: choice, pin: false) }
        case "state":
            let choice = model.kubernetesChoice?.pods.map(\.name).joined(separator: ",") ?? "none"
            let target = model.selectedTab.map { model.targetLabel($0.target) } ?? "none"
            FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: kubernetes target=\(target) choice=\(choice) production-pending=\(model.productionGuard.pending != nil)\n".utf8))
        default: break
        }
        return true
    }
}
extension Notification.Name {
    static let debugKubernetesList = Notification.Name("RunletDebugKubernetesList")
}
#endif
