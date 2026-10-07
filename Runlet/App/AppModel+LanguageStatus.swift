import Foundation
import RunletLanguage

/// Reindex Project (#336): the status bar's PHPantom popover and the Library menu.
extension AppModel {
    /// Why Reindex Project can't run for `tab`, or nil when it can.
    func reindexProjectDisabledReason(for tab: TabModel?) -> String? {
        guard let tab, tab.language == .php else { return "Reindex Project works in PHP tabs." }
        guard settings.languageServiceEnabled else { return "Reindex Project needs PHPantom, which is off in Settings ▸ Editor." }
        guard tab.languageWorkspace != nil, languageService != nil else { return "Reindex Project needs PHPantom running for this tab." }
        return nil
    }

    /// Indexes the tab's project again: PHPantom's own reindex command when it has one,
    /// otherwise a restart of the workspace's server, which every tab on that project shares.
    /// Changes on disk normally reach PHPantom without this; it catches up after anything the
    /// file watcher missed.
    func reindexProject(for tab: TabModel) {
        guard reindexProjectDisabledReason(for: tab) == nil, let workspace = tab.languageWorkspace, let languageService else { return }
        Task {
            let session = await languageService.acquire(workspace, for: tab.id)
            await session.reindex()
        }
    }

    /// The indexed folder as the popover shows it, `~/Sites/shop`, as tab cards show it
    /// (`RUNLET_DEBUG_HOME` in Debug builds).
    func languageFolderDescription(for tab: TabModel) -> String? {
        guard let workspace = tab.languageWorkspace, workspace.kind == .project else { return nil }
        return TabCardText.folder(workspace.rootPath)
    }
}
