import AppKit
import Observation
import RunletCore
import SwiftUI

/// An external change to a tab's file that needs the user; shown as a banner above the editor.
enum DiskIssue: Equatable {
    /// The file changed while the tab has unsaved edits (for a tab restored from the last
    /// session: the file and the tab differ).
    case changed
    /// The file was moved or deleted, or can't be read as text.
    case missing
}

/// Follows the files behind file-backed tabs (keyed by tab id): one `FileWatcher` per tab, and
/// what each tab last loaded, saved, or accepted from its file. Comparing contents with that
/// baseline tells another app's change from the tab's own edits (`DiskSync`).
@MainActor
@Observable
final class FileSyncStore {
    var issues: [UUID: DiskIssue] = [:]
    @ObservationIgnored var baselines: [UUID: String] = [:]
    @ObservationIgnored var watchers: [UUID: FileWatcher] = [:]
    /// Tabs whose "moved or deleted" banner was dismissed (until the file is back or saved).
    @ObservationIgnored var dismissedMissing: Set<UUID> = []
    @ObservationIgnored var activationObserver: NSObjectProtocol?

    private static var stores: [ObjectIdentifier: FileSyncStore] = [:]

    static func shared(for model: AppModel) -> FileSyncStore {
        let key = ObjectIdentifier(model)
        if let store = stores[key] { return store }
        let store = FileSyncStore()
        stores[key] = store
        return store
    }

    func forget(_ id: UUID) {
        watchers.removeValue(forKey: id)?.cancel()
        baselines[id] = nil
        issues[id] = nil
        dismissedMissing.remove(id)
    }
}

extension AppModel {
    var fileSync: FileSyncStore { FileSyncStore.shared(for: self) }

    func diskIssue(for tab: TabModel) -> DiskIssue? { fileSync.issues[tab.id] }

    /// Watches exactly the open file-backed tabs: starts watching new ones (and compares them
    /// with their files once), stops for closed tabs or changed paths. Runs whenever the
    /// session is saved and after a file is opened or saved.
    func syncFileWatchers() {
        let store = fileSync
        if store.activationObserver == nil {
            // Changes made while Runlet was in the background are checked on return too, in
            // case an event was missed (a network volume, a folder that was replaced).
            store.activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkAllFiles() }
            }
        }
        var fileTabs: [UUID: (tab: TabModel, url: URL)] = [:]
        for tab in allTabs {
            if let url = tab.fileURL { fileTabs[tab.id] = (tab, url.standardizedFileURL) }
        }
        for (id, watcher) in store.watchers where fileTabs[id]?.url != watcher.url {
            store.forget(id)
        }
        for (id, entry) in fileTabs where store.watchers[id] == nil {
            store.watchers[id] = FileWatcher(url: entry.url) { [weak self, weak tab = entry.tab] in
                MainActor.assumeIsolated {
                    guard let self, let tab else { return }
                    self.checkDisk(tab)
                }
            }
            checkDisk(entry.tab)
        }
    }

    func checkAllFiles() {
        for tab in allTabs where tab.fileURL != nil { checkDisk(tab) }
    }

    /// Compares a file-backed tab with its file. A tab without unsaved edits shows the file's
    /// new contents; one with edits gets a Reload / Keep Mine banner; a missing file gets its
    /// own banner. Never writes the file, and never runs code.
    func checkDisk(_ tab: TabModel) {
        guard let url = tab.fileURL else { return }
        let store = fileSync
        let disk = try? String(contentsOf: url, encoding: .utf8)
        let editor = tab.editorIfLoaded?.text ?? tab.code
        switch DiskSync.evaluate(disk: disk, baseline: store.baselines[tab.id], editor: editor) {
        case .unchanged:
            store.dismissedMissing.remove(tab.id)
            if store.issues[tab.id] != nil { store.issues[tab.id] = nil }
        case .reload(let text):
            show(text, in: tab)
        case .inSync(let text):
            store.baselines[tab.id] = text
            store.dismissedMissing.remove(tab.id)
            tab.isFileDirty = false
            if store.issues[tab.id] != nil { store.issues[tab.id] = nil }
        case .conflict:
            tab.isFileDirty = true
            store.dismissedMissing.remove(tab.id)
            if store.issues[tab.id] != .changed { store.issues[tab.id] = .changed }
        case .missing:
            // Its code is no longer on disk: closing the window asks, and ⌘S writes it back.
            tab.isFileDirty = true
            if !store.dismissedMissing.contains(tab.id), store.issues[tab.id] != .missing { store.issues[tab.id] = .missing }
        }
    }

    /// Replaces the tab's code with the file's (undoable), keeping the caret and scroll position.
    private func show(_ text: String, in tab: TabModel) {
        let store = fileSync
        store.baselines[tab.id] = text
        store.dismissedMissing.remove(tab.id)
        if let editor = tab.editorIfLoaded { editor.reload(with: text) } else { tab.replaceCode(text) }
        tab.isFileDirty = false
        store.issues[tab.id] = nil
    }

    /// The banner's Reload (also Reload from Disk): the file's version replaces the tab's code
    /// (⌘Z brings the tab's back).
    func reloadFromDisk(_ tab: TabModel) {
        guard let url = tab.fileURL, let text = try? String(contentsOf: url, encoding: .utf8) else {
            checkDisk(tab)
            return
        }
        show(text, in: tab)
    }

    /// The banner's Keep Mine: the tab keeps its code, and the file's current version counts as
    /// seen, so ⌘S replaces it without asking again.
    func keepTabVersion(_ tab: TabModel) {
        guard let url = tab.fileURL else { return }
        if let text = try? String(contentsOf: url, encoding: .utf8) { fileSync.baselines[tab.id] = text }
        fileSync.issues[tab.id] = nil
    }

    func dismissMissingFile(_ tab: TabModel) {
        fileSync.dismissedMissing.insert(tab.id)
        fileSync.issues[tab.id] = nil
    }

    /// After `tab` was opened from or saved to its file: `text` is what the file holds, the
    /// file is watched, and it is listed in recent documents (the Dock menu and ⌘P).
    func noteFileSynced(_ tab: TabModel, text: String) {
        guard let url = tab.fileURL else { return }
        syncFileWatchers()
        let store = fileSync
        store.baselines[tab.id] = text
        store.issues[tab.id] = nil
        store.dismissedMissing.remove(tab.id)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    /// Before ⌘S writes over `tab`'s own file: asks when another app changed the file since
    /// the tab last loaded, saved, or accepted it. Returns whether to write.
    func confirmSaveOverDiskChanges(_ tab: TabModel) -> Bool {
        guard let url = tab.fileURL else { return true }
        let disk = try? String(contentsOf: url, encoding: .utf8)
        let editor = tab.editorIfLoaded?.text ?? tab.code
        guard DiskSync.saveNeedsConfirmation(disk: disk, baseline: fileSync.baselines[tab.id], editor: editor) else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(url.lastPathComponent)” changed on disk"
        alert.informativeText = "Another app changed this file since Runlet opened or saved it. Saving replaces that version with this tab's code."
        alert.addButton(withTitle: "Save Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Above the editor of a file-backed tab whose file changed under it or went away.
struct DiskIssueBanner: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel

    var body: some View {
        if let issue = model.diskIssue(for: tab), let url = tab.fileURL {
            HStack(spacing: 8) {
                Image(systemName: issue == .changed ? "doc.badge.arrow.up" : "questionmark.folder")
                    .foregroundStyle(.orange)
                Text(message(issue, name: url.lastPathComponent))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                switch issue {
                case .changed:
                    Button("Reload") { model.reloadFromDisk(tab) }
                        .help("Show the file's version. ⌘Z brings this tab's code back.")
                        .accessibilityIdentifier("disk-reload")
                    Button("Keep Mine") { model.keepTabVersion(tab) }
                        .help("Keep this tab's code. Saving replaces the file's version.")
                        .accessibilityIdentifier("disk-keep-mine")
                case .missing:
                    Button("Save") { _ = model.save(tab) }
                        .help("Write this tab's code to \((url.path as NSString).abbreviatingWithTildeInPath) again.")
                        .accessibilityIdentifier("disk-save-again")
                    Button("Dismiss") { model.dismissMissingFile(tab) }
                        .accessibilityIdentifier("disk-dismiss")
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.12))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("disk-change-banner")
        }
    }

    private func message(_ issue: DiskIssue, name: String) -> String {
        switch issue {
        case .changed where model.fileSync.baselines[tab.id] == nil:
            "“\(name)” on disk differs from this tab, which was restored from the last session. Keep this tab's code, or reload the file's?"
        case .changed:
            "“\(name)” changed on disk, and this tab has unsaved edits. Keep yours, or reload the file's version?"
        case .missing:
            "“\(name)” was moved, deleted, or can't be read. Its code is still here; Save writes it back."
        }
    }
}
