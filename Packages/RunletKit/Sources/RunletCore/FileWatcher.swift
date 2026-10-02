import Darwin
import Foundation

/// Watches one file for changes by any process: writes in place, atomic replacement (a new
/// file renamed over the old one, as most editors and `git` save), deletion, and coming back.
/// It watches the file itself and its folder, and calls `onChange` once per burst of events,
/// `latency` after the last one. It only says that the file may have changed: callers compare
/// contents (`DiskSync`).
public final class FileWatcher: @unchecked Sendable {
    public let url: URL
    private let latency: DispatchTimeInterval
    private let queue = DispatchQueue(label: "dev.runlet.file-watcher")
    private let deliveryQueue: DispatchQueue
    private let onChange: @Sendable () -> Void

    // Touched only on `queue`.
    private var fileSource: DispatchSourceFileSystemObject?
    private var folderSource: DispatchSourceFileSystemObject?
    private var watched: Signature?
    private var pending: DispatchWorkItem?
    private var fileEventPending = false
    private var cancelled = false

    /// What identifies the file's current version without reading it.
    private struct Signature: Equatable {
        var device: dev_t
        var inode: ino_t
        var size: off_t
        var modified: timespec

        static func == (lhs: Signature, rhs: Signature) -> Bool {
            lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size
                && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
        }

        init?(path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            modified = info.st_mtimespec
        }
    }

    public init(url: URL, latency: TimeInterval = 0.15, deliveryQueue: DispatchQueue = .main, onChange: @escaping @Sendable () -> Void) {
        self.url = url.standardizedFileURL
        self.latency = .milliseconds(Int(latency * 1000))
        self.deliveryQueue = deliveryQueue
        self.onChange = onChange
        queue.sync {
            armFolder()
            armFile()
        }
    }

    /// Stops watching; no callback is delivered after this returns (except one already queued
    /// on the delivery queue).
    public func cancel() {
        queue.sync {
            cancelled = true
            pending?.cancel()
            fileSource?.cancel()
            folderSource?.cancel()
            fileSource = nil
            folderSource = nil
        }
    }

    deinit {
        fileSource?.cancel()
        folderSource?.cancel()
    }

    private func armFile() {
        fileSource?.cancel()
        fileSource = nil
        watched = Signature(path: url.path)
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .attrib, .delete, .rename, .link, .revoke], queue: queue)
        source.setEventHandler { [weak self] in self?.eventArrived(fromFile: true) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        fileSource = source
    }

    private func armFolder() {
        let descriptor = open(url.deletingLastPathComponent().path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .link, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self] in self?.eventArrived(fromFile: false) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        folderSource = source
    }

    private func eventArrived(fromFile: Bool) {
        guard !cancelled else { return }
        fileEventPending = fileEventPending || fromFile
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settle() }
        pending = work
        queue.asyncAfter(deadline: .now() + latency, execute: work)
    }

    private func settle() {
        guard !cancelled else { return }
        let fromFile = fileEventPending
        fileEventPending = false
        let current = Signature(path: url.path)
        let replaced = current?.device != watched?.device || current?.inode != watched?.inode
        let changed = current != watched
        // The path may hold another file now (atomic save) or nothing: watch what is there.
        if replaced || fileSource == nil { armFile() } else { watched = current }
        // Folder events also come from other files in the folder; they count only when this
        // file's identity, size, or modification time changed.
        guard fromFile || changed else { return }
        let onChange = onChange
        deliveryQueue.async { onChange() }
    }
}

/// How a tab backed by a file follows that file on disk. Contents are compared, never just
/// dates, so saving the same text, `touch`, or Runlet's own saves change nothing.
public enum DiskSync {
    public enum Outcome: Equatable, Sendable {
        /// The file holds what the tab last loaded or saved (or the change only touched it).
        case unchanged
        /// The tab has no unsaved edits: show the file's new contents.
        case reload(String)
        /// The file now holds exactly the tab's code: the tab is in sync with it again.
        case inSync(String)
        /// The tab has unsaved edits and the file changed too: the user decides (Reload or
        /// Keep Mine).
        case conflict(String)
        /// The file was moved or deleted, or can't be read as text.
        case missing
    }

    /// - Parameters:
    ///   - disk: the file's contents now; nil when it's missing or unreadable.
    ///   - baseline: the contents the tab last loaded, saved, or accepted (Keep Mine); nil when
    ///     not known, e.g. a tab restored from the last session.
    ///   - editor: the tab's code now.
    public static func evaluate(disk: String?, baseline: String?, editor: String) -> Outcome {
        guard let disk else { return .missing }
        if disk == editor { return disk == baseline ? .unchanged : .inSync(disk) }
        if disk == baseline { return .unchanged }
        if let baseline, editor == baseline { return .reload(disk) }
        return .conflict(disk)
    }

    /// Whether ⌘S has to ask before writing over the file: it changed since the tab last
    /// loaded, saved, or accepted it. With no baseline, any difference from the tab counts.
    public static func saveNeedsConfirmation(disk: String?, baseline: String?, editor: String) -> Bool {
        guard let disk else { return false }
        if let baseline { return disk != baseline && disk != editor }
        return disk != editor
    }
}
