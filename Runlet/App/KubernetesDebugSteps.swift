#if DEBUG
import AppKit
import RunletCore
import RunletExecution

/// #33: fake-kubectl-only screenshots. No credentials or real cluster calls.
/// `kubernetes:editor`, `kubernetes:list`, `kubernetes:choose`, `kubernetes:confirm`,
/// and `kubernetes:state` operate on the seeded scratch profile.
/// #373: `command`, `needs-input`, `again`, `production`, `approve`, and `terminal-state`
/// exercise terminal launch and rerun safety; `kubernetes-menu-shot:<name>` draws the real + menu.
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
        // #373: exercise the public actions, without keyboard input or live kubectl.
        case "command", "needs-input":
            if let tab = model.selectedTab {
                model.runProjectCommand(ProjectCommand(name: "Pod Check", commandLine: "printf 'Shop pod terminal\\n'; pwd; printf 'TMPDIR=%s\\n' \"$TMPDIR\"", origin: .driver, source: "Shop", needsInput: argument == "needs-input"), in: tab)
            }
        case "again":
            if let window = model.activeWindow, let session = window.terminals.selected { model.runTerminalAgain(session.id, in: window) }
        case "approve":
            if let pending = model.productionGuard.pending { model.confirmProduction(pending, grace: false) }
        case "production":
            if case .kubernetes(let id) = model.selectedTab?.target, var profile = model.library.kubernetesProfile(id) {
                profile.environment = .production
                model.saveKubernetesProfile(profile)
            }
        case "terminal-state":
            let sessions = model.activeWindow?.terminals.sessions ?? []
            let state = sessions.map { "\($0.request.requiresKubernetesRelaunch ? "pod" : "local"):\($0.state)" }.joined(separator: "|")
            let notice = model.projectCommands.notice.map { "\($0.kind)" } ?? "none"
            FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: terminals=\(sessions.count) \(state) notice=\(notice) alert=\(model.alert?.message ?? "none") pending=\(model.productionGuard.pending != nil) key=\(NSApp.keyWindow != nil)\n".utf8))
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
