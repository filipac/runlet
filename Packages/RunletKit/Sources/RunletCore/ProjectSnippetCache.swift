import Foundation
import Observation

/// Project snippets read from `<root>/.runlet/snippets`, cached per project root. Views observe
/// `generation`, which changes whenever a folder's snippets change.
///
/// Each cached root's snippets folder is watched (#51, `FolderWatcher`): files added, edited,
/// atomically replaced, renamed, or deleted, in any format `ProjectSnippets.load` reads, re-read
/// the folder once per burst. Only the list changes: tabs opened from a snippet are never
/// touched, and nothing runs. `retain(roots:)` stops watching the roots no open tab uses.
@MainActor
@Observable
public final class ProjectSnippetCache {
    public private(set) var generation = 0
    @ObservationIgnored private var entries: [String: [ProjectSnippet]] = [:]
    @ObservationIgnored private var watchers: [String: FolderWatcher] = [:]
    @ObservationIgnored private let watchesFolders: Bool
    @ObservationIgnored private let latency: TimeInterval

    /// - Parameters:
    ///   - watchFolders: false reads folders only when asked (`reload`), as before #51.
    ///   - latency: how long a folder must stay quiet before it is re-read.
    public init(watchFolders: Bool = true, latency: TimeInterval = 0.25) {
        self.watchesFolders = watchFolders
        self.latency = latency
    }

    /// The root's snippets, sorted by label: read once, then kept up to date by its watcher.
    public func snippets(root: URL) -> [ProjectSnippet] {
        _ = generation
        let key = root.path
        if let cached = entries[key] { return cached }
        let loaded = ProjectSnippets.load(projectRoot: root)
        entries[key] = loaded
        watch(root)
        return loaded
    }

    /// Re-reads the root's folder (the Snippets panel's reload button, after saving a snippet,
    /// and when its watcher fires). Observers hear about it only when the snippets changed.
    public func reload(root: URL) {
        let key = root.path
        let loaded = ProjectSnippets.load(projectRoot: root)
        watch(root)
        guard entries[key] != loaded else { return }
        entries[key] = loaded
        generation += 1
    }

    /// Forgets every cached folder; each is read again when next shown.
    public func reloadAll() {
        entries.removeAll()
        generation += 1
    }

    /// Keeps watching (and caching) only `roots`, the project roots of the open tabs: a project
    /// whose last tab closed (or whose folder changed) is no longer watched.
    public func retain(roots: Set<URL>) {
        let keep = Set(roots.map(\.path))
        for key in Array(watchers.keys) where !keep.contains(key) {
            watchers.removeValue(forKey: key)?.cancel()
        }
        let dropped = entries.keys.filter { !keep.contains($0) }
        for key in dropped { entries[key] = nil }
    }

    /// The roots whose snippets folder is watched now.
    public var watchedRoots: Set<String> { Set(watchers.keys) }

    private func watch(_ root: URL) {
        let key = root.path
        guard watchesFolders, watchers[key] == nil else { return }
        watchers[key] = FolderWatcher(url: ProjectSnippets.directory(projectRoot: root), latency: latency) { [weak self] in
            MainActor.assumeIsolated { self?.folderChanged(root) }
        }
    }

    private func folderChanged(_ root: URL) {
        // A folder nobody reads any more waits until it's shown again.
        guard entries[root.path] != nil else { return }
        reload(root: root)
    }
}
