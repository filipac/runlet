import CoreServices
import Foundation

/// Watches a workspace folder with FSEvents for the globs its language server registered, and
/// hands the matching changes to `send` in debounced batches (#336). Everything runs on the
/// watcher's own queue, never the main thread: FSEvents delivers there, the batcher waits there,
/// and `send` is called there, in order.
///
/// - Paths that no glob matches are dropped as they arrive; so is everything inside `.git`.
/// - The stream starts when the server registers its watchers and stops with the server
///   (`stop()`); changes made before the server registered aren't replayed, as in other editors.
/// - A folder that appears (moved in, unpacked) is reported as its files. A folder that
///   disappears is reported as itself: FSEvents doesn't list what was in it.
/// - When FSEvents drops events (`MustScanSubDirs`), nothing is rescanned; Reindex Project
///   catches up.
/// - Only the workspace folder is watched: a relative pattern based outside it (PHPantom 0.11
///   asks for followed symlinks that way; the bundled 0.10 doesn't) never matches.
final class WorkspaceFileWatcher: @unchecked Sendable {
    typealias Sink = @Sendable ([WatchedFileChange]) -> Void

    let root: String
    private let realRoot: String
    private let queue = DispatchQueue(label: "dev.runlet.language.file-watcher", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let sink: Sink
    // Queue-confined.
    private var stream: FSEventStreamRef?
    private var registry: WatchedFileRegistry
    private var batcher: FileChangeBatcher
    private var flushScheduled = false
    // Read from any thread.
    private let lock = NSLock()
    private var sentChanges = 0
    private var sentNotifications = 0

    init(root: String, registry: WatchedFileRegistry, batcher: FileChangeBatcher = FileChangeBatcher(), send: @escaping Sink) {
        self.root = LSPGlob.trimmingSlash(root)
        self.realRoot = Self.realPath(root)
        self.registry = registry
        self.batcher = batcher
        self.sink = send
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        // The session always calls `stop()`; this only guards against a stream outliving us.
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// How many changes, and notifications, went to the server.
    var sent: (changes: Int, notifications: Int) { lock.withLock { (sentChanges, sentNotifications) } }

    @discardableResult
    func start() -> Bool {
        onQueue {
            guard stream == nil else { return true }
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
            guard let created = FSEventStreamCreate(kCFAllocatorDefault, Self.callback, &context, [realRoot] as CFArray,
                                                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else { return false }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                return false
            }
            stream = created
            return true
        }
    }

    /// The server registered or unregistered watchers.
    func update(registry: WatchedFileRegistry) {
        queue.async { self.registry = registry }
    }

    /// Stops watching. Pending changes are dropped: the server is going away.
    func stop() {
        onQueue {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            batcher = FileChangeBatcher(debounce: batcher.debounce, maxDelay: batcher.maxDelay, maxBatchSize: batcher.maxBatchSize, maxFolderFiles: batcher.maxFolderFiles)
        }
    }

    private func onQueue<T>(_ work: () -> T) -> T {
        DispatchQueue.getSpecific(key: queueKey) == true ? work() : queue.sync(execute: work)
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let watcher = Unmanaged<WorkspaceFileWatcher>.fromOpaque(info).takeUnretainedValue()
        let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
        var events: [(String, FSEventStreamEventFlags)] = []
        events.reserveCapacity(count)
        for index in 0..<count {
            guard let path = list[index] as? String else { continue }
            events.append((path, flags[index]))
        }
        watcher.receive(events)
    }

    /// On the queue.
    private func receive(_ events: [(String, FSEventStreamEventFlags)]) {
        guard stream != nil else { return }
        let now = Self.now()
        for (eventPath, raw) in events {
            let flags = Self.flags(raw)
            guard let path = WatchedPaths.workspacePath(eventPath, root: root, realRoot: realRoot) else { continue }
            if flags.contains(.isDirectory) {
                // Only folders that appear or go matter (their files, or a server's folder glob).
                guard !flags.isDisjoint(with: [.created, .renamed, .removed]) else { continue }
            } else {
                guard registry.couldMatch(path: path, root: root) else { continue }
            }
            batcher.record(path: path, flags: flags, at: now)
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled, let deadline = batcher.deadline else { return }
        flushScheduled = true
        let delay = max(0, deadline - Self.now())
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.flush() }
    }

    private func flush() {
        flushScheduled = false
        guard stream != nil else { return }
        guard let events = batcher.takeIfDue(at: Self.now()) else {
            scheduleFlush()
            return
        }
        let changes = batcher.changes(for: events, registry: registry, root: root, probe: DiskProbe())
        let notifications = batcher.notifications(for: changes)
        for batch in notifications { sink(batch) }
        lock.withLock {
            sentChanges += changes.count
            sentNotifications += notifications.count
        }
    }

    static func flags(_ raw: FSEventStreamEventFlags) -> FileEventFlags {
        var flags: FileEventFlags = []
        if raw & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0 { flags.insert(.created) }
        if raw & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0 { flags.insert(.removed) }
        if raw & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0 { flags.insert(.renamed) }
        if raw & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemInodeMetaMod) != 0 { flags.insert(.modified) }
        if raw & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 { flags.insert(.isDirectory) }
        return flags
    }

    private static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    /// The folder's real path, as FSEvents reports it (`/private/var/…`, a symlink's target).
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return LSPGlob.trimmingSlash(path) }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
