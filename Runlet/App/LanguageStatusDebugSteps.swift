#if DEBUG
import AppKit
import RunletLanguage

/// RUNLET_DEBUG_STEPS for the status bar's PHPantom item (#336), with scratch data. They need
/// no key window, so Runlet can stay in the background (`ghost`):
///
/// - `language-popover:on|off` opens or closes the item's popover for the current tab, as a
///   click on the item does.
/// - `language-progress:<percentage>|<message>` shows made-up indexing progress on the current
///   tab, for screenshots of a state that lasts a second on a small project; the next real
///   report replaces it. `language-progress:off` clears it.
/// - `language-state` prints the item's text and tooltip, the server's state and activity, the
///   indexed folder, the limitations, whether the popover is open, how many file changes went to
///   PHPantom, and Reindex Project's availability.
///
/// `nav-wait:ready` waits for PHPantom to start; it registers its file watchers when its first
/// index is done, a step or two later on a small project. Reindex Project itself:
/// `perform:library.reindexProject`.
@MainActor
enum LanguageStatusDebugSteps {
    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        guard name.hasPrefix("language-") else { return false }
        guard let tab = model.selectedTab else {
            log("\(name): no tab")
            return true
        }
        switch name {
        case "language-popover":
            tab.languagePopoverShown = argument != "off"
        case "language-progress":
            if argument == "off" {
                tab.languageActivity.progress = nil
            } else {
                let parts = argument.split(separator: "|", maxSplits: 1).map(String.init)
                tab.languageActivity.progress = LanguageServerProgress(token: "debug", title: "PHPantom: Indexing", message: parts.count > 1 ? parts[1] : nil, percentage: Int(parts[0]))
            }
        case "language-state":
            let line = state(model, tab: tab)
            guard let workspace = tab.languageWorkspace, let service = model.languageService else {
                log(line + " sent=none")
                return true
            }
            Task {
                let session = await service.acquire(workspace, for: tab.id)
                let sent = await session.fileChangesSent
                log(line + " sent=" + (sent.map { "\($0.changes) changes in \($0.notifications) notifications" } ?? "none"))
            }
        default:
            log("\(name)?")
        }
        return true
    }

    private static func state(_ model: AppModel, tab: TabModel) -> String {
        let summary = LanguageStatusSummary(state: tab.languageState, activity: tab.languageActivity, limitations: tab.languageNotes)
        let activity = tab.languageActivity
        let progress = activity.progress.map { "\($0.title) \($0.percentage.map { "\($0)%" } ?? "-") \($0.message ?? "")" } ?? "none"
        let last = activity.lastProgress.map { "\($0.title): \($0.message ?? "")" } ?? "none"
        return "language-state item=\"\(summary.title)\" help=\"\(summary.help)\" state=\(tab.languageState) progress=\(progress) last=\(last) "
            + "watched=[\(activity.watchedPatterns.joined(separator: ", "))] folder=\(model.languageFolderDescription(for: tab) ?? "none") "
            + "notes=\(tab.languageNotes.count) popover=\(tab.languagePopoverShown) reindex=\(model.reindexProjectDisabledReason(for: tab) ?? "enabled")"
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(message)\n".utf8))
    }
}
#endif
