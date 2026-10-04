import CoreServices
import Darwin
import Foundation

/// Watches a folder's contents for changes by any process (#51): files added, written in place,
/// atomically replaced (a new file renamed over the old one, as editors and `git` save), renamed,
/// or deleted, and the folder itself created, moved, or removed later. It calls `onChange` once
/// per burst of events, `latency` after the last one. It only says that something in the folder
/// may have changed: the caller re-reads it.
///
/// While the folder exists, one FSEvents stream with file-level events watches it (no file
/// descriptor per file; `WatchRoot` reports the folder being moved or removed). While it doesn't
/// (a project without `.runlet/snippets` yet), a kqueue source watches its nearest existing
/// ancestor's entries and moves down as the missing folders appear: FSEvents alone doesn't
/// reliably report a path that didn't exist when its stream started. Switching to the folder
/// counts as a change, so whatever it already holds is read.
public final class FolderWatcher: @unchecked Sendable {
    public let url: URL
    private let latency: DispatchTimeInterval
    private let queue = DispatchQueue(label: "dev.runlet.folder-watcher")
    private let deliveryQueue: DispatchQueue
    private let onChange: @Sendable () -> Void

    // Touched only on `queue`.
    private var stream: FSEventStreamRef?
    private var ancestorSource: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var rearmPending = false
    private var cancelled = false

    /// What the stream's context points at: a weak way back to the watcher, retained by the
    /// stream, so an event can't reach a watcher that is gone.
    private final class Link: @unchecked Sendable {
        weak var watcher: FolderWatcher?
        init(_ watcher: FolderWatcher) { self.watcher = watcher }
    }

    /// - Parameters:
    ///   - latency: how long the folder must stay quiet before `onChange` is called.
    ///   - deliveryQueue: where `onChange` runs.
    public init(url: URL, latency: TimeInterval = 0.25, deliveryQueue: DispatchQueue = .main, onChange: @escaping @Sendable () -> Void) {
        self.url = url.standardizedFileURL
        self.latency = .milliseconds(max(1, Int(latency * 1000)))
        self.deliveryQueue = deliveryQueue
        self.onChange = onChange
        queue.sync { arm() }
    }

    /// Stops watching; no callback is delivered after this returns (except one already queued
    /// on the delivery queue).
    public func cancel() {
        queue.sync {
            cancelled = true
            pending?.cancel()
            pending = nil
            disarm()
        }
    }

    deinit {
        // `cancel()` normally ran; what's left only holds a weak link to this watcher.
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        ancestorSource?.cancel()
    }

    /// Whether the folder itself is followed (it exists), for tests.
    var watchesFolder: Bool { queue.sync { stream != nil } }

    // MARK: Arming

    /// Watches the folder when it exists, else its nearest existing ancestor.
    private func arm() {
        while true {
            disarm()
            if Self.isDirectory(url) { return startStream() }
            let watched = watchAncestor()
            // A folder further down may have appeared before the source was armed (`mkdir -p`
            // makes them all at once): look again, so its event isn't missed.
            if Self.isDirectory(url) || nearestAncestor() != watched { continue }
            return
        }
    }

    private func disarm() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        ancestorSource?.cancel()
        ancestorSource = nil
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func startStream() {
        let link = Unmanaged.passRetained(Link(self))
        var context = FSEventStreamContext(
            version: 0,
            info: link.toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Link>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Link>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, _, flags, _ in
            guard let info else { return }
            var rootChanged = false
            for index in 0..<count where flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                rootChanged = true
            }
            Unmanaged<Link>.fromOpaque(info).takeUnretainedValue().watcher?.changed(rearm: rootChanged)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        let created = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [url.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags)
        // The stream retained the link (or failed); drop this function's reference.
        link.release()
        guard let created else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }
        stream = created
    }

    /// The nearest existing folder above `url`.
    private func nearestAncestor() -> String {
        var candidate = url.deletingLastPathComponent()
        while !Self.isDirectory(candidate), candidate.path != "/" {
            candidate = candidate.deletingLastPathComponent()
        }
        return candidate.path
    }

    /// A kqueue source on the nearest existing ancestor folder: entries added, removed, or
    /// renamed in it (a missing folder on the way being created), or the ancestor going away.
    /// Returns the folder it watches.
    @discardableResult
    private func watchAncestor() -> String {
        let candidate = nearestAncestor()
        let descriptor = open(candidate, O_EVTONLY)
        guard descriptor >= 0 else { return candidate }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .link, .rename, .delete, .revoke], queue: queue)
        source.setEventHandler { [weak self] in self?.ancestorChanged() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        ancestorSource = source
        return candidate
    }

    /// On `queue`: entries of the watched ancestor changed. Watch the next existing folder
    /// down (or the ancestor's own replacement); once the folder itself exists, read it.
    private func ancestorChanged() {
        guard !cancelled, ancestorSource != nil else { return }
        arm()
        if stream != nil { changed(rearm: false) }
    }

    // MARK: Events

    /// On `queue`: the folder (may have) changed. `rearm` when FSEvents says the folder itself
    /// moved, appeared, or went away: watch whatever is at the path now.
    private func changed(rearm: Bool) {
        guard !cancelled else { return }
        if rearm, !rearmPending {
            // Not from inside the stream's own callback.
            rearmPending = true
            queue.async { [weak self] in
                guard let self, !self.cancelled else { return }
                self.rearmPending = false
                self.arm()
            }
        }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settle() }
        pending = work
        queue.asyncAfter(deadline: .now() + latency, execute: work)
    }

    private func settle() {
        guard !cancelled else { return }
        pending = nil
        let onChange = onChange
        deliveryQueue.async { onChange() }
    }
}
