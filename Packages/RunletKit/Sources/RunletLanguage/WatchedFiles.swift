import Foundation

// File watching for the language server (#336). PHPantom doesn't watch the disk itself: at
// startup it asks the client to watch PHP and composer files (`client/registerCapability` for
// `workspace/didChangeWatchedFiles`), and reindexes what the client reports. These are the pure
// parts: the registered globs, which file events match them, and how events are batched.
// `WorkspaceFileWatcher` feeds them from FSEvents.

/// LSP `FileChangeType`.
public enum WatchedFileChangeType: Int, Sendable, Hashable {
    case created = 1
    case changed = 2
    case deleted = 3

    var watchKind: WatchKind {
        switch self {
        case .created: .create
        case .changed: .change
        case .deleted: .delete
        }
    }
}

/// LSP `WatchKind`: which changes a watcher wants. The default is all three.
public struct WatchKind: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let create = WatchKind(rawValue: 1)
    public static let change = WatchKind(rawValue: 2)
    public static let delete = WatchKind(rawValue: 4)
    public static let all: WatchKind = [.create, .change, .delete]
}

/// An LSP glob pattern: `*` and `?` within a path segment, `**` for any number of segments,
/// `{a,b}` alternatives, and `[a-z]` / `[!a-z]` ranges. A plain pattern (`**/*.php`) matches a
/// path relative to the workspace root or the absolute path; a relative pattern
/// (`{baseUri, pattern}`) matches paths under its base only.
public struct LSPGlob: Sendable, Hashable, CustomStringConvertible {
    public let pattern: String
    /// The base folder of a relative pattern, as a path.
    public let basePath: String?
    private let matcher: GlobMatcher

    public init?(pattern: String, basePath: String? = nil) {
        guard !pattern.isEmpty, let matcher = GlobMatcher(pattern) else { return nil }
        self.pattern = pattern
        self.basePath = basePath.map(Self.trimmingSlash)
        self.matcher = matcher
    }

    /// A `GlobPattern` from the server: a string, or `{baseUri, pattern}` where `baseUri` is a
    /// URI or a `WorkspaceFolder`.
    public init?(json: JSONValue) {
        if let pattern = json.stringValue {
            self.init(pattern: pattern)
            return
        }
        guard let pattern = json["pattern"]?.stringValue else { return nil }
        let base = json["baseUri"]?.stringValue ?? json["baseUri"]?["uri"]?.stringValue
        guard let base, let url = URL(string: base), url.isFileURL else { return nil }
        self.init(pattern: pattern, basePath: url.path)
    }

    public var description: String {
        guard let basePath else { return pattern }
        return "\(basePath)/\(pattern)"
    }

    /// Whether `path` (absolute) matches, for a workspace at `root`.
    public func matches(path: String, root: String) -> Bool {
        if let basePath {
            guard let relative = Self.relative(path, to: basePath) else { return false }
            return matcher.matches(relative)
        }
        if let relative = Self.relative(path, to: root), matcher.matches(relative) { return true }
        return matcher.matches(path)
    }

    public static func == (lhs: LSPGlob, rhs: LSPGlob) -> Bool {
        lhs.pattern == rhs.pattern && lhs.basePath == rhs.basePath
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(pattern)
        hasher.combine(basePath)
    }

    static func relative(_ path: String, to base: String) -> String? {
        let base = trimmingSlash(base)
        guard path.hasPrefix(base + "/") else { return nil }
        return String(path.dropFirst(base.count + 1))
    }

    static func trimmingSlash(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// Compiles an LSP glob into a regular expression once.
private struct GlobMatcher: @unchecked Sendable {
    let regex: NSRegularExpression

    init?(_ glob: String) {
        guard let regex = try? NSRegularExpression(pattern: "^" + Self.translate(glob) + "$") else { return nil }
        self.regex = regex
    }

    func matches(_ path: String) -> Bool {
        regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    static func translate(_ glob: String) -> String {
        let characters = Array(glob)
        var out = ""
        var index = 0
        var braces = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "*":
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    let segmentStart = index == 0 || characters[index - 1] == "/"
                    if segmentStart, index + 2 < characters.count, characters[index + 2] == "/" {
                        // `**/`: any number of whole segments, including none.
                        out += "(?:.*/)?"
                        index += 3
                    } else {
                        out += ".*"
                        index += 2
                    }
                    continue
                }
                out += "[^/]*"
            case "?":
                out += "[^/]"
            case "{":
                braces += 1
                out += "(?:"
            case "}" where braces > 0:
                braces -= 1
                out += ")"
            case "," where braces > 0:
                out += "|"
            case "[":
                // A range up to the next `]` (a `]` right after `[` or `[!` is part of it).
                var close = index + 1
                if close < characters.count, characters[close] == "!" { close += 1 }
                if close < characters.count, characters[close] == "]" { close += 1 }
                while close < characters.count, characters[close] != "]" { close += 1 }
                guard close < characters.count else {
                    out += "\\["
                    break
                }
                var body = String(characters[(index + 1)..<close])
                if body.hasPrefix("!") { body = "^" + body.dropFirst() }
                body = body.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[")
                out += "[" + body + "]"
                index = close + 1
                continue
            default:
                out += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }
        // An unclosed `{` would leave the expression invalid: close it.
        out += String(repeating: ")", count: braces)
        return out
    }
}

/// One `FileSystemWatcher` the server registered.
public struct FileSystemWatcherSpec: Sendable, Hashable {
    public var glob: LSPGlob
    public var kind: WatchKind

    public init(glob: LSPGlob, kind: WatchKind = .all) {
        self.glob = glob
        self.kind = kind
    }
}

/// The watchers a server registered through `client/registerCapability`, by registration id.
/// Other dynamic registrations (type hierarchy, …) are ignored: Runlet doesn't use them.
public struct WatchedFileRegistry: Sendable, Equatable {
    public static let method = "workspace/didChangeWatchedFiles"

    private var registrations: [(id: String, watchers: [FileSystemWatcherSpec])] = []

    public init() {}

    public var isEmpty: Bool { registrations.allSatisfy { $0.watchers.isEmpty } }

    public var watchers: [FileSystemWatcherSpec] { registrations.flatMap(\.watchers) }

    /// The registered globs, for the status bar's popover and debug output.
    public var patterns: [String] {
        var seen = Set<String>()
        return watchers.map(\.glob.description).filter { seen.insert($0).inserted }
    }

    /// Applies `client/registerCapability` params. Returns whether watched files changed.
    @discardableResult
    public mutating func register(_ params: JSONValue) -> Bool {
        var changed = false
        for registration in params["registrations"]?.arrayValue ?? [] where registration["method"]?.stringValue == Self.method {
            let id = registration["id"]?.stringValue ?? UUID().uuidString
            let watchers = (registration["registerOptions"]?["watchers"]?.arrayValue ?? []).compactMap { watcher -> FileSystemWatcherSpec? in
                guard let glob = watcher["globPattern"].flatMap(LSPGlob.init(json:)) else { return nil }
                let kind = watcher["kind"]?.intValue.map(WatchKind.init(rawValue:)) ?? .all
                return FileSystemWatcherSpec(glob: glob, kind: kind)
            }
            registrations.removeAll { $0.id == id }
            registrations.append((id, watchers))
            changed = true
        }
        return changed
    }

    /// Applies `client/unregisterCapability` params (the spec spells the key `unregisterations`).
    @discardableResult
    public mutating func unregister(_ params: JSONValue) -> Bool {
        let entries = params["unregisterations"]?.arrayValue ?? params["unregistrations"]?.arrayValue ?? []
        var changed = false
        for entry in entries where entry["method"]?.stringValue == Self.method {
            guard let id = entry["id"]?.stringValue else { continue }
            let before = registrations.count
            registrations.removeAll { $0.id == id }
            changed = changed || registrations.count != before
        }
        return changed
    }

    /// Whether any glob matches `path`, whatever the kind of change: events for other paths are
    /// dropped as they arrive.
    public func couldMatch(path: String, root: String) -> Bool {
        watchers.contains { $0.glob.matches(path: path, root: root) }
    }

    /// The change to report for `path`, or nil when no watcher wants it. A file that appeared
    /// where a watcher only wants changes (`composer.lock` replaced by a branch switch) is
    /// reported as changed.
    public func reportedType(for type: WatchedFileChangeType, path: String, root: String) -> WatchedFileChangeType? {
        var fallback: WatchedFileChangeType?
        for watcher in watchers where watcher.glob.matches(path: path, root: root) {
            if watcher.kind.contains(type.watchKind) { return type }
            if type == .created, watcher.kind.contains(.change) { fallback = .changed }
        }
        return fallback
    }

    public static func == (lhs: WatchedFileRegistry, rhs: WatchedFileRegistry) -> Bool {
        lhs.registrations.map(\.id) == rhs.registrations.map(\.id) && lhs.registrations.map(\.watchers) == rhs.registrations.map(\.watchers)
    }
}

/// What FSEvents said happened to a path, merged over a batch.
public struct FileEventFlags: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let created = FileEventFlags(rawValue: 1)
    public static let removed = FileEventFlags(rawValue: 2)
    public static let modified = FileEventFlags(rawValue: 4)
    public static let renamed = FileEventFlags(rawValue: 8)
    public static let isDirectory = FileEventFlags(rawValue: 16)
}

/// One change sent to the server.
public struct WatchedFileChange: Sendable, Hashable {
    public var path: String
    public var type: WatchedFileChangeType

    public init(path: String, type: WatchedFileChangeType) {
        self.path = path
        self.type = type
    }

    public var uri: String { URL(fileURLWithPath: path).absoluteString }
}

/// What is on disk at a path now, for turning merged events into changes.
public protocol FileSystemProbe {
    func kind(of path: String) -> FileSystemProbeKind
    /// Files (not folders) under `directory`, at most `limit`, skipping `.git`.
    func files(under directory: String, limit: Int) -> [String]
}

public enum FileSystemProbeKind: Sendable, Equatable {
    case missing, file, directory
}

/// The real file system.
public struct DiskProbe: FileSystemProbe {
    public init() {}

    public func kind(of path: String) -> FileSystemProbeKind {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return .missing }
        return isDirectory.boolValue ? .directory : .file
    }

    /// Paths are spelled under `directory` as given (an enumerator at a URL would report
    /// `/private/var/…` for `/var/…`).
    public func files(under directory: String, limit: Int) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: directory) else { return [] }
        var files: [String] = []
        while let relative = enumerator.nextObject() as? String {
            if (relative as NSString).lastPathComponent == ".git" {
                enumerator.skipDescendants()
                continue
            }
            guard enumerator.fileAttributes?[.type] as? FileAttributeType == .typeRegular else { continue }
            files.append(LSPGlob.trimmingSlash(directory) + "/" + relative)
            if files.count >= limit { break }
        }
        return files
    }
}

/// Collects file events and hands them over in debounced batches: 300 ms after the last event,
/// or at most 2 s after the first while events keep coming (`composer install`). A branch switch
/// that touches thousands of files arrives as a few batches, each path once, and each batch is
/// sent in notifications of at most `maxBatchSize` changes. Times are seconds on any monotonic
/// clock.
public struct FileChangeBatcher: Sendable {
    public var debounce: Double
    public var maxDelay: Double
    public var maxBatchSize: Int
    /// A folder that appears (moved in, or unpacked) is reported as its files, up to this many.
    public var maxFolderFiles: Int

    private var order: [String] = []
    private var flags: [String: FileEventFlags] = [:]
    private var firstAt: Double?
    private var lastAt: Double?

    public init(debounce: Double = 0.3, maxDelay: Double = 2, maxBatchSize: Int = 2000, maxFolderFiles: Int = 20_000) {
        self.debounce = debounce
        self.maxDelay = maxDelay
        self.maxBatchSize = maxBatchSize
        self.maxFolderFiles = maxFolderFiles
    }

    public var pendingCount: Int { order.count }

    public mutating func record(path: String, flags newFlags: FileEventFlags, at time: Double) {
        if let existing = flags[path] {
            flags[path] = existing.union(newFlags)
        } else {
            flags[path] = newFlags
            order.append(path)
        }
        if firstAt == nil { firstAt = time }
        lastAt = time
    }

    /// When the pending events are due, or nil when there are none.
    public var deadline: Double? {
        guard let firstAt, let lastAt else { return nil }
        return min(lastAt + debounce, firstAt + maxDelay)
    }

    /// The pending events, in arrival order, if they are due at `time`; they are then cleared.
    public mutating func takeIfDue(at time: Double) -> [(path: String, flags: FileEventFlags)]? {
        guard let deadline, time >= deadline else { return nil }
        let events = order.map { (path: $0, flags: flags[$0] ?? []) }
        order = []
        flags = [:]
        firstAt = nil
        lastAt = nil
        return events
    }

    /// Turns merged events into the changes the server asked for, checking what's on disk now:
    /// a missing path was deleted; a file that was created or renamed into place was created;
    /// any other file changed. A folder that appeared is reported as the files in it.
    public func changes(for events: [(path: String, flags: FileEventFlags)], registry: WatchedFileRegistry, root: String, probe: some FileSystemProbe) -> [WatchedFileChange] {
        var changes: [WatchedFileChange] = []
        var seen = Set<String>()
        func add(_ path: String, _ type: WatchedFileChangeType) {
            guard let reported = registry.reportedType(for: type, path: path, root: root), seen.insert(path).inserted else { return }
            changes.append(WatchedFileChange(path: path, type: reported))
        }
        for (path, flags) in events {
            let appeared = !flags.isDisjoint(with: [.created, .renamed])
            switch probe.kind(of: path) {
            case .missing:
                add(path, .deleted)
            case .file:
                add(path, appeared ? .created : .changed)
            case .directory:
                guard appeared else { continue }
                for file in probe.files(under: path, limit: maxFolderFiles) where !WatchedPaths.isIgnored(file, root: root) {
                    add(file, .created)
                }
            }
        }
        return changes
    }

    /// Splits changes into notifications of at most `maxBatchSize`.
    public func notifications(for changes: [WatchedFileChange]) -> [[WatchedFileChange]] {
        stride(from: 0, to: changes.count, by: max(1, maxBatchSize)).map { Array(changes[$0..<min($0 + max(1, maxBatchSize), changes.count)]) }
    }

    /// `workspace/didChangeWatchedFiles` params.
    public static func params(for changes: [WatchedFileChange]) -> JSONValue {
        .object(["changes": .array(changes.map { .object(["uri": .string($0.uri), "type": .number(Double($0.type.rawValue))]) })])
    }
}

/// Paths FSEvents reports, as the server knows them.
public enum WatchedPaths {
    /// The path under the workspace `root` the server was given, for a path FSEvents reports
    /// under the folder's real path (`/private/var/…` for `/var/…`, or a symlink's target).
    /// Nil outside the workspace and inside `.git`.
    public static func workspacePath(_ eventPath: String, root: String, realRoot: String) -> String? {
        let root = LSPGlob.trimmingSlash(root)
        let realRoot = LSPGlob.trimmingSlash(realRoot)
        let path: String
        if let relative = LSPGlob.relative(eventPath, to: realRoot) {
            path = root + "/" + relative
        } else if LSPGlob.relative(eventPath, to: root) != nil {
            path = eventPath
        } else {
            return nil
        }
        return isIgnored(path, root: root) ? nil : path
    }

    /// Git's own files: a branch switch rewrites thousands of them, and no server wants them.
    public static func isIgnored(_ path: String, root: String) -> Bool {
        let relative = LSPGlob.relative(path, to: root) ?? path
        return relative == ".git" || relative.hasPrefix(".git/") || relative.contains("/.git/") || relative.hasSuffix("/.git")
    }
}
