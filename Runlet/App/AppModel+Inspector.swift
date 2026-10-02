import AppKit
import RunletCore

/// Run inspector settings per target.
extension AppModel {
    /// Whether runs on `target` ask drivers to intercept mail: the project's or Docker
    /// profile's override, else Settings ▸ General ▸ Run Inspector.
    func interceptMail(for target: TargetRef) -> Bool {
        library.interceptMail(for: target, global: settings.interceptMail)
    }

    /// What a run on `target` asks of the run inspector. Mail interception needs the
    /// inspector (drivers intercept from their inspect() hook), so it keeps it on.
    func inspectorOptions(for target: TargetRef) -> RunInspectorOptions {
        let intercept = interceptMail(for: target)
        return RunInspectorOptions(enabled: settings.runInspector || intercept, interceptMail: intercept, previews: settings.renderPreviews)
    }

    /// Flips the global Intercept Mail setting (per-target overrides still win).
    func toggleMailInterception() {
        settings.interceptMail.toggle()
    }
}
