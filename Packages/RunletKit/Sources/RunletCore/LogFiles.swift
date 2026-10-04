import Darwin
import Foundation

// MARK: - Log files on this Mac (#20)

/// Which file a log file is, without reading it: its device and inode. A rotated log keeps
/// its identity under another name; the new file at the path has another one.
public struct LogFileIdentity: Sendable, Hashable {
    public var device: UInt64
    public var inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }

    init(_ info: stat) {
        device = UInt64(bitPattern: Int64(info.st_dev))
        inode = UInt64(info.st_ino)
    }

    public static func of(path: String) -> (identity: LogFileIdentity, size: UInt64)? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return (LogFileIdentity(info), UInt64(max(0, info.st_size)))
    }
}

/// Bounded reads of a log file: never the whole of a large file.
public enum LogTail {
    /// The first read of a file: its last 512 KB.
    public static let defaultBytes = 512 * 1024

    public struct Chunk: Sendable, Equatable {
        public var data: Data
        /// Where `data` starts and ends in the file.
        public var start: UInt64
        public var end: UInt64
        /// Bytes before `start` that weren't read (0 when the read began at the start of the file
        /// or of the asked range).
        public var skipped: UInt64
        public var identity: LogFileIdentity
    }

    public enum ReadError: Error, Equatable, CustomStringConvertible {
        case missing(String)
        case unreadable(String, String)

        public var description: String {
            switch self {
            case .missing(let path): "\(path) doesn't exist (any more)."
            case .unreadable(let path, let reason): "Runlet can't read \(path): \(reason)."
            }
        }
    }

    /// The last `maxBytes` of the file. A read that starts inside the file begins after the
    /// first newline, so it never shows half a line.
    public static func read(path: String, maxBytes: Int = defaultBytes) throws -> Chunk {
        let fd = try openForReading(path)
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ReadError.unreadable(path, String(cString: strerror(errno))) }
        let size = UInt64(max(0, info.st_size))
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        var data = try readBytes(fd, from: start, count: Int(size - start), path: path)
        var begin = start
        if start > 0, let newline = data.firstIndex(of: 0x0A), newline < data.endIndex - 1 {
            let dropped = data.distance(from: data.startIndex, to: newline) + 1
            data = data.subdata(in: (data.startIndex + dropped)..<data.endIndex)
            begin += UInt64(dropped)
        }
        return Chunk(data: data, start: begin, end: begin + UInt64(data.count), skipped: begin, identity: LogFileIdentity(info))
    }

    /// Bytes `range` of the file, at most `maxBytes` of its end; for "Logs written by the last run".
    public static func read(path: String, range: Range<UInt64>, maxBytes: Int = 2 * 1024 * 1024) throws -> Chunk {
        let fd = try openForReading(path)
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ReadError.unreadable(path, String(cString: strerror(errno))) }
        let size = UInt64(max(0, info.st_size))
        let upper = min(range.upperBound, size)
        guard upper > range.lowerBound else {
            return Chunk(data: Data(), start: range.lowerBound, end: range.lowerBound, skipped: 0, identity: LogFileIdentity(info))
        }
        let start = upper - range.lowerBound > UInt64(maxBytes) ? upper - UInt64(maxBytes) : range.lowerBound
        let data = try readBytes(fd, from: start, count: Int(upper - start), path: path)
        return Chunk(data: data, start: start, end: start + UInt64(data.count), skipped: start - range.lowerBound, identity: LogFileIdentity(info))
    }

    static func openForReading(_ path: String) throws -> Int32 {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { throw ReadError.missing(path) }
            throw ReadError.unreadable(path, String(cString: strerror(errno)))
        }
        return fd
    }

    static func readBytes(_ fd: Int32, from offset: UInt64, count: Int, path: String) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        var total = 0
        try data.withUnsafeMutableBytes { buffer in
            while total < count {
                let read = pread(fd, buffer.baseAddress!.advanced(by: total), count - total, off_t(offset) + off_t(total))
                if read < 0 {
                    if errno == EINTR { continue }
                    throw ReadError.unreadable(path, String(cString: strerror(errno)))
                }
                if read == 0 { break }
                total += read
            }
        }
        return total == count ? data : data.prefix(total)
    }
}

/// Follows a log file on this Mac (#20) with kqueue (`DispatchSource`) on the file and its
/// folder, plus a slow poll in case a file system sends no events (some network and VM
/// shares). It reads only what was added, from where the last read ended:
///
/// - a write adds bytes: they are read (at most `maxReadBytes` per check; more than that and
///   the oldest of them are skipped, reported in `.appended`'s `skipped`);
/// - truncation (`copytruncate`, `> laravel.log`): the file is read again from its start;
/// - rotation (renamed away, a new file at the path): what was still unread in the old file
///   is read first, then the new file from its start;
/// - removal: reported once; the path is watched until a file appears there again.
///
/// Nothing is written, locked, or kept open longer than needed: the follower keeps one
/// read-only descriptor on the current file.
public final class LogFileFollower: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        /// New bytes at `start` of the current file; `skipped` bytes before them weren't read.
        case appended(Data, start: UInt64, skipped: UInt64)
        /// The file got shorter: what follows is read from its start.
        case truncated
        /// Another file is at the path now (rotation); what follows is the new file's.
        case rotated
        /// No file at the path.
        case missing
    }

    public let path: String
    public let maxReadBytes: Int
    private let queue = DispatchQueue(label: "dev.runlet.log-follower")
    private let deliveryQueue: DispatchQueue
    private let onEvent: @Sendable (Event) -> Void
    private let pollInterval: DispatchTimeInterval
    private let throttle: DispatchTimeInterval

    // Touched only on `queue`.
    private var fd: Int32 = -1
    private var identity: LogFileIdentity?
    private var offset: UInt64
    private var fileSource: DispatchSourceFileSystemObject?
    private var folderSource: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var checkScheduled = false
    private var reportedMissing = false
    private var cancelled = false

    /// - Parameters:
    ///   - offset: where reading goes on (the end of the first read).
    ///   - identity: the file the first read came from; when another file is at the path by
    ///     the time following starts, it counts as a rotation.
    public init(path: String, from offset: UInt64, identity: LogFileIdentity?, maxReadBytes: Int = 4 * 1024 * 1024, pollInterval: TimeInterval = 2, throttle: TimeInterval = 0.1, deliveryQueue: DispatchQueue = .main, onEvent: @escaping @Sendable (Event) -> Void) {
        self.path = path
        self.offset = offset
        self.maxReadBytes = max(1024, maxReadBytes)
        self.deliveryQueue = deliveryQueue
        self.onEvent = onEvent
        self.pollInterval = .milliseconds(max(50, Int(pollInterval * 1000)))
        self.throttle = .milliseconds(max(1, Int(throttle * 1000)))
        queue.sync {
            let descriptor = open(path, O_RDONLY | O_CLOEXEC)
            if descriptor >= 0 {
                var info = stat()
                if fstat(descriptor, &info) == 0, identity == nil || LogFileIdentity(info) == identity {
                    fd = descriptor
                    self.identity = LogFileIdentity(info)
                } else {
                    close(descriptor)
                    // Another file than the one read first: read the new one from its start.
                    self.identity = identity
                }
            }
            armFolder()
            armFile()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + self.pollInterval, repeating: self.pollInterval)
            timer.setEventHandler { [weak self] in self?.check() }
            timer.resume()
            self.timer = timer
            scheduleCheck()
        }
    }

    /// Stops following; no event is delivered after this returns (except one already queued
    /// on the delivery queue).
    public func cancel() {
        queue.sync {
            cancelled = true
            fileSource?.cancel()
            folderSource?.cancel()
            timer?.cancel()
            fileSource = nil
            folderSource = nil
            timer = nil
            if fd >= 0 { close(fd) }
            fd = -1
        }
    }

    deinit {
        fileSource?.cancel()
        folderSource?.cancel()
        timer?.cancel()
        if fd >= 0 { close(fd) }
    }

    /// Checks the file now (tests; the watcher does it by itself).
    public func checkNow() {
        queue.sync { check() }
    }

    private func armFile() {
        fileSource?.cancel()
        fileSource = nil
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke], queue: queue)
        source.setEventHandler { [weak self] in self?.scheduleCheck() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        fileSource = source
    }

    private func armFolder() {
        let descriptor = open((path as NSString).deletingLastPathComponent, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .link, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self] in self?.scheduleCheck() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        folderSource = source
    }

    /// At most one check per `throttle`, however many events arrive: a busy log is read in
    /// batches, and never waits for a quiet moment.
    private func scheduleCheck() {
        guard !cancelled, !checkScheduled else { return }
        checkScheduled = true
        queue.asyncAfter(deadline: .now() + throttle) { [weak self] in
            guard let self else { return }
            self.checkScheduled = false
            self.check()
        }
    }

    private func check() {
        guard !cancelled else { return }
        var info = stat()
        let exists = stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
        if !exists {
            // Renamed away or deleted: what is still unread in it comes first.
            drain()
            closeCurrent()
            if !reportedMissing {
                reportedMissing = true
                deliver(.missing)
            }
            if fileSource != nil { armFile() }
            return
        }
        let current = LogFileIdentity(info)
        if fd < 0 || current != identity {
            let rotated = identity != nil
            drain()
            closeCurrent()
            let descriptor = open(path, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { return }
            fd = descriptor
            identity = current
            offset = 0
            reportedMissing = false
            armFile()
            if rotated { deliver(.rotated) }
        }
        var now = stat()
        guard fstat(fd, &now) == 0 else { return }
        let size = UInt64(max(0, now.st_size))
        if size < offset {
            offset = 0
            deliver(.truncated)
        }
        readAvailable(upTo: size)
    }

    /// Reads from `offset` to `size` (bounded).
    private func readAvailable(upTo size: UInt64) {
        guard size > offset else { return }
        var skipped: UInt64 = 0
        if size - offset > UInt64(maxReadBytes) {
            skipped = size - offset - UInt64(maxReadBytes)
            offset += skipped
        }
        guard let data = try? LogTail.readBytes(fd, from: offset, count: Int(size - offset), path: path), !data.isEmpty else { return }
        let start = offset
        offset += UInt64(data.count)
        deliver(.appended(data, start: start, skipped: skipped))
    }

    /// The rest of the current descriptor's file (rotated or removed: the descriptor still
    /// reads it).
    private func drain() {
        guard fd >= 0 else { return }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return }
        readAvailable(upTo: UInt64(max(0, info.st_size)))
    }

    private func closeCurrent() {
        if fd >= 0 { close(fd) }
        fd = -1
    }

    private func deliver(_ event: Event) {
        let onEvent = onEvent
        deliveryQueue.async { onEvent(event) }
    }
}

// MARK: - Discovery

/// A log file found in a project folder on this Mac.
public struct LogFileCandidate: Sendable, Hashable, Identifiable {
    public enum Origin: String, Sendable, Hashable {
        case laravel, symfony, wordpress, driver
    }

    /// The absolute path on this Mac.
    public var path: String
    /// The path inside the project folder (`storage/logs/laravel.log`).
    public var relativePath: String
    public var size: UInt64
    public var modified: Date
    public var origin: Origin

    public var id: String { path }

    public init(path: String, relativePath: String, size: UInt64, modified: Date, origin: Origin) {
        self.path = path
        self.relativePath = relativePath
        self.size = size
        self.modified = modified
        self.origin = origin
    }
}

/// Finds the log files of a project folder (#20) without running anything: Laravel's
/// `storage/logs/**/*.log` (nested folders too), Symfony's `var/log/**/*.log`, WordPress's
/// `wp-content/debug.log`, and the paths a project driver's `logPaths()` declared (files,
/// folders, or `*` patterns, relative to the project or absolute). Hidden folders, symlinked
/// folders, and folders outside the project aren't entered.
public enum LogDiscovery {
    /// At most this many files are listed.
    public static let limit = 200
    /// Nested folders under `storage/logs` and `var/log` are read this deep.
    public static let depth = 4

    public static func find(in folder: String, driverPaths: [String] = [], limit: Int = LogDiscovery.limit) -> [LogFileCandidate] {
        let root = (folder as NSString).standardizingPath
        var found: [String: LogFileCandidate] = [:]
        var order: [String] = []
        func add(_ path: String, origin: LogFileCandidate.Origin) {
            guard found.count < limit else { return }
            let standardized = (path as NSString).standardizingPath
            guard found[standardized] == nil, let attributes = attributes(standardized) else { return }
            found[standardized] = LogFileCandidate(path: standardized, relativePath: relative(standardized, to: root), size: attributes.size, modified: attributes.modified, origin: origin)
            order.append(standardized)
        }
        for driverPath in driverPaths {
            for path in expand(driverPath, root: root) { add(path, origin: .driver) }
        }
        for (directory, origin) in [("storage/logs", LogFileCandidate.Origin.laravel), ("var/log", .symfony)] {
            for path in logFiles(under: (root as NSString).appendingPathComponent(directory), depth: depth, limit: limit) { add(path, origin: origin) }
        }
        add((root as NSString).appendingPathComponent("wp-content/debug.log"), origin: .wordpress)
        // Driver paths first (the project chose them), then the newest files.
        let driver = order.filter { found[$0]?.origin == .driver }
        let rest = order.filter { found[$0]?.origin != .driver }.sorted {
            let a = found[$0]!, b = found[$1]!
            return a.modified != b.modified ? a.modified > b.modified : a.relativePath < b.relativePath
        }
        return (driver + rest).compactMap { found[$0] }
    }

    /// A driver's path on this Mac: relative to the project, or absolute (kept only inside it);
    /// a folder lists its `*.log` files; `*` in the last part matches names.
    static func expand(_ declared: String, root: String) -> [String] {
        let trimmed = declared.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let absolute = trimmed.hasPrefix("/") ? trimmed : (root as NSString).appendingPathComponent(trimmed)
        let path = (absolute as NSString).standardizingPath
        guard path == root || path.hasPrefix(root + "/") else { return [] }
        let name = (path as NSString).lastPathComponent
        if name.contains("*") || name.contains("?") {
            let parent = (path as NSString).deletingLastPathComponent
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent) else { return [] }
            return names.sorted().filter { fnmatch(name, $0, 0) == 0 }.map { (parent as NSString).appendingPathComponent($0) }
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return [] }
        return isDirectory.boolValue ? logFiles(under: path, depth: 2, limit: limit) : [path]
    }

    /// `*.log` files under `directory`, `depth` folders deep, without following symlinked folders.
    static func logFiles(under directory: String, depth: Int, limit: Int) -> [String] {
        var result: [String] = []
        func walk(_ folder: String, level: Int) {
            guard result.count < limit, let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return }
            for name in names.sorted() where !name.hasPrefix(".") {
                let path = (folder as NSString).appendingPathComponent(name)
                var info = stat()
                guard lstat(path, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    if level < depth { walk(path, level: level + 1) }
                case S_IFREG, S_IFLNK:
                    if name.hasSuffix(".log") { result.append(path) }
                default:
                    break
                }
                if result.count >= limit { return }
            }
        }
        walk(directory, level: 1)
        return result
    }

    static func attributes(_ path: String) -> (size: UInt64, modified: Date)? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        return (UInt64(max(0, info.st_size)), modified)
    }

    static func relative(_ path: String, to root: String) -> String {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }

    /// Where logs usually are on a server or in a container, relative to the application's
    /// directory, for a framework Runlet learned from a run (`laravel`, `symfony`,
    /// `wordpress`); all of them when it doesn't know.
    public static func usualPaths(framework: String?) -> [String] {
        switch framework?.lowercased() {
        case "laravel": ["storage/logs/laravel.log"]
        case "symfony": ["var/log/prod.log", "var/log/dev.log"]
        case "wordpress": ["wp-content/debug.log"]
        default: ["storage/logs/laravel.log", "var/log/prod.log", "var/log/dev.log", "wp-content/debug.log"]
        }
    }
}
