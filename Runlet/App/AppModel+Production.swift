import AppKit
import Observation
import RunletCore
import RunletExecution

/// Something that runs code on a production target and waits for the user's confirmation.
struct ProductionConfirmation: Identifiable {
    let id = UUID()
    var action: GuardedAction
    var target: TargetRef
    /// The window whose sheet asks.
    var windowId: UUID?
    var targetName: String
    /// Where it runs: `user@host:directory`, a container, or a folder.
    var destination: String
    /// The code or command line, shortened to its first lines.
    var preview: String
    var lineCount: Int
    var isSelection: Bool
    /// Host commands run on this Mac (in the target's local folder), not on the target.
    var runsOnThisMac: Bool
    var perform: () -> Void

    var allowsGrace: Bool { action == .run }

    var title: String {
        switch action {
        case .run: isSelection ? "Run the selection on production?" : "Run this code on production?"
        case .listCommands: "List commands on production?"
        case .command: "Run this command for production?"
        case .shell: "Open a shell on production?"
        }
    }

    var confirmTitle: String {
        switch action {
        case .run: "Run on Production"
        case .listCommands: "List Commands"
        case .command: "Run Command"
        case .shell: "Open Shell"
        }
    }

    var explanation: String {
        switch action {
        case .run:
            "\(targetName) is marked as production. The code below runs there with the application's real data."
        case .listCommands:
            "Listing commands boots \(targetName) (its bootstrap code runs, as for a snippet). It is marked as production."
        case .command:
            runsOnThisMac
                ? "This host command runs on this Mac in the project's folder, for \(targetName), which is marked as production. It can change the production system."
                : "This command runs on \(targetName), which is marked as production."
        case .shell:
            "This opens a login shell on \(targetName), which is marked as production. Everything you type there runs on the server."
        }
    }
}

/// N14 production guard state: the pending confirmation and the in-memory grace
/// (`ProductionGrace`: snippet runs only, reset on relaunch and on target edits).
@MainActor
@Observable
final class ProductionGuard {
    var pending: ProductionConfirmation?
    var grace = ProductionGrace()

    private static var guards: [ObjectIdentifier: ProductionGuard] = [:]

    static func shared(for model: AppModel) -> ProductionGuard {
        let key = ObjectIdentifier(model)
        if let existing = guards[key] { return existing }
        let created = ProductionGuard()
        guards[key] = created
        return created
    }
}

extension AppModel {
    var productionGuard: ProductionGuard { ProductionGuard.shared(for: self) }

    func isProduction(_ target: TargetRef) -> Bool {
        library.isProduction(target)
    }

    /// A target's settings changed: a granted grace no longer applies.
    func targetEdited(_ target: TargetRef) {
        productionGuard.grace.revoke(target)
    }

    /// Runs `perform` now, or asks first when `target` is production. Snippet runs inside a
    /// granted 10-minute grace don't ask; listings and commands always do.
    func guardProduction(_ action: GuardedAction, target: TargetRef, text: String, isSelection: Bool = false, runsOnThisMac: Bool = false, in window: WindowModel? = nil, perform: @escaping () -> Void) {
        guard productionGuard.grace.needsConfirmation(action, on: target, environment: library.environment(for: target)) else {
            perform()
            return
        }
        let preview = ProductionGrace.preview(of: text)
        productionGuard.pending = ProductionConfirmation(
            action: action,
            target: target,
            windowId: (window ?? self.window(containingTarget: target) ?? activeWindow)?.id,
            targetName: targetLabel(target),
            destination: productionDestination(target),
            preview: preview.text,
            lineCount: preview.lineCount,
            isSelection: isSelection,
            runsOnThisMac: runsOnThisMac,
            perform: perform
        )
    }

    /// The user confirmed (⌘↩). `grace` grants "don't ask again for 10 minutes" (snippet runs).
    func confirmProduction(_ confirmation: ProductionConfirmation, grace: Bool) {
        productionGuard.pending = nil
        if grace, confirmation.allowsGrace { productionGuard.grace.grant(confirmation.target) }
        confirmation.perform()
    }

    func cancelProduction() {
        productionGuard.pending = nil
    }

    /// The active window if its selected tab uses `target`, else the first window that does.
    private func window(containingTarget target: TargetRef) -> WindowModel? {
        if let active = activeWindow, active.selectedTab?.target == target { return active }
        return windows.first { $0.tabs.contains { $0.target == target } }
    }

    /// "forge@shop:/home/forge/shop/current", "shop/app · /var/www/html", or a folder.
    func productionDestination(_ target: TargetRef) -> String {
        switch target {
        case .sandbox:
            return "Laravel Sandbox"
        case .local(let id):
            return library.localProject(id).map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? ""
        case .docker(let id):
            guard let profile = library.dockerProfile(id) else { return "" }
            return "\(profile.identity.displayName) · \(profile.workingDirectory)" + (profile.user.map { " · user \($0)" } ?? "")
        case .ssh(let id):
            guard let profile = library.sshProfile(id) else { return "" }
            if let step = profile.container {
                return "\(profile.destinationLabel) · container \(step.summary)" + (step.user.map { " · user \($0)" } ?? "")
            }
            return "\(profile.destinationLabel):\(profile.remoteDirectory)"
        }
    }
}
