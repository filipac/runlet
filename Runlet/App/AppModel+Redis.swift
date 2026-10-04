import AppKit
import RunletCore
import RunletExecution

/// Redis tabs (#190): creating them and running their commands.
extension AppModel {
    /// Runs a Redis tab's command at the caret (or the selected one).
    func runRedis(_ tab: TabModel, selectionOnly: Bool) {
        guard !tab.isRunning, tab.language == .redis else { return }
        alert = AppAlert(title: "Redis tabs aren't ready yet", message: "Nothing ran.")
    }
}
