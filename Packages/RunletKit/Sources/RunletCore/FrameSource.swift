import Foundation

/// A file a stack frame (or any `file:line` from a run) points at, as it can be read on this Mac.
public struct FrameSourceFile: Sendable, Hashable {
    public enum Origin: Sendable, Hashable {
        /// A project file.
        case project
        /// Under a `vendor/` folder of the project.
        case vendor
        /// On this Mac, outside the project.
        case outsideProject
    }

    /// The file on this Mac.
    public var hostPath: String
    /// The path PHP reported (a container or server path for Docker and SSH targets).
    public var runtimePath: String
    public var origin: Origin
    /// Read from the local folder of a Docker or SSH profile: the target's own file may differ.
    public var isLocalCopy: Bool
    /// The path relative to the project folder, or the full path outside it.
    public var displayPath: String
    /// Where the target runs ("the container", "forge@example.com") for a local copy.
    public var runtimeLocation: String?

    public init(hostPath: String, runtimePath: String, origin: Origin, isLocalCopy: Bool, displayPath: String, runtimeLocation: String? = nil) {
        self.hostPath = hostPath
        self.runtimePath = runtimePath
        self.origin = origin
        self.isLocalCopy = isLocalCopy
        self.displayPath = displayPath
        self.runtimeLocation = runtimeLocation
    }

    public var fileName: String { (displayPath as NSString).lastPathComponent }
}

/// Where a frame's source is.
public enum FrameSourceLocation: Sendable, Equatable {
    /// Not a file at all: PHP's "Standard input code" (the runner), "[internal function]".
    case none
    case file(FrameSourceFile)
    /// A file Runlet can't read here. `path` is the one to show (on this Mac when it maps, else
    /// the target's); `reason` says why.
    case unavailable(path: String, reason: String)

    public var file: FrameSourceFile? {
        if case .file(let file) = self { return file }
        return nil
    }
}

/// Finds the file on this Mac behind a path from a run (#8): the host path itself for local and
/// sandbox runs, the profile's local folder for Docker and SSH (through `EditorPathMapping`).
/// Error cards use it for source excerpts; anything else that lists frames (the log viewer,
/// #20) can use it the same way.
public struct FrameSourceResolver: Sendable {
    public var mapping: EditorPathMapping
    /// Mapped files are a local folder's copy of the target's (Docker and SSH profiles), which
    /// may differ from what ran: excerpts say "local copy".
    public var readsLocalCopy: Bool
    /// The project's folder on this Mac, for telling vendor code and other files apart.
    public var projectRoot: String?
    public var fileExists: @Sendable (String) -> Bool

    /// `readsLocalCopy` defaults to true for container and server mappings. `projectRoot`
    /// defaults to the mapping's local folder (needed for `.host`, which has none).
    public init(mapping: EditorPathMapping, readsLocalCopy: Bool? = nil, projectRoot: String? = nil,
                fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.mapping = mapping
        self.readsLocalCopy = readsLocalCopy ?? (mapping.kind != .host)
        self.projectRoot = projectRoot ?? mapping.localRoot
        self.fileExists = fileExists
    }

    /// The resolver for a run's snapshot, with the same arguments as
    /// `EditorPathMapping.forSnapshot`. The sandbox's Docker container mounts the sandbox
    /// itself, so its files are the ones that ran; Docker and SSH profiles' local folders are copies.
    public static func forSnapshot(_ snapshot: TargetSnapshot, localSource: String?, runtimeDirectory: String? = nil,
                                   fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> FrameSourceResolver {
        let mapping = EditorPathMapping.forSnapshot(snapshot, localSource: localSource, runtimeDirectory: runtimeDirectory)
        let root: String? = switch snapshot.kind {
        case .local, .sandboxLocal: snapshot.workingDirectory
        default: nil
        }
        return FrameSourceResolver(mapping: mapping, readsLocalCopy: snapshot.kind == .docker || snapshot.kind == .ssh, projectRoot: root, fileExists: fileExists)
    }

    public func locate(_ runtimePath: String) -> FrameSourceLocation {
        guard runtimePath.hasPrefix("/") else { return .none }
        switch mapping.resolve(runtimePath) {
        case .unavailable(let reason):
            return .unavailable(path: runtimePath, reason: reason)
        case .mapped(let hostPath):
            guard fileExists(hostPath) else {
                let reason = hostPath == EditorPathMapping.normalize(runtimePath)
                    ? "\(hostPath) doesn't exist on this Mac."
                    : "\(runtimePath) maps to \(hostPath), which doesn't exist on this Mac."
                return .unavailable(path: hostPath, reason: reason)
            }
            let (origin, display) = classify(hostPath)
            let copy = readsLocalCopy && mapping.kind != .host
            return .file(FrameSourceFile(hostPath: hostPath, runtimePath: runtimePath, origin: origin, isLocalCopy: copy,
                                         displayPath: display, runtimeLocation: copy ? mapping.runtimeLocationName : nil))
        }
    }

    /// Vendor code is anything under a `vendor` folder inside the project. PHP reports real
    /// paths, so a project folder behind a symlink (`/tmp` is `/private/tmp`) matches too.
    private func classify(_ hostPath: String) -> (FrameSourceFile.Origin, String) {
        guard let projectRoot else {
            return (hostPath.split(separator: "/").contains("vendor") ? .vendor : .outsideProject, hostPath)
        }
        let root = EditorPathMapping.normalize(projectRoot)
        for candidate in [root, Self.realPath(root)].compactMap({ $0 }) {
            let prefix = candidate == "/" ? "/" : candidate + "/"
            guard hostPath.hasPrefix(prefix) else { continue }
            let relative = String(hostPath.dropFirst(prefix.count))
            return (relative.split(separator: "/").contains("vendor") ? .vendor : .project, relative)
        }
        return (.outsideProject, hostPath)
    }

    /// `realpath(3)`: unlike `resolvingSymlinksInPath`, it keeps `/private`.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        let real = String(cString: resolved)
        return real == path ? nil : real
    }
}

extension EditorPathMapping {
    /// The folder on this Mac that the target's paths map into (nil for `.host` and without a
    /// local folder).
    public var localRoot: String? {
        switch kind {
        case .host: nil
        case .container(_, let hostRoot): hostRoot
        case .remote(_, let localRoot, _): localRoot
        }
    }
}

/// Reads excerpts off the main thread and keeps them for the run they were read for (#8): each
/// file and line is read once per run, and a later run reads again (the file may have changed).
public actor SourceExcerptStore {
    public static let shared = SourceExcerptStore()

    public struct Key: Hashable, Sendable {
        public var run: UUID
        /// The file's path, or "" for the run's own code.
        public var path: String
        public var line: Int
    }

    public typealias Outcome = Result<SourceExcerpt, SourceExcerptFailure>

    private var cache: [Key: Outcome] = [:]
    private var order: [Key] = []
    private var pending: [Key: Task<Outcome, Never>] = [:]
    private let capacity: Int
    private let limits: SourceExcerptLimits
    /// Files read so far (for tests: a second request for the same run and line reads nothing).
    public private(set) var fileReads = 0

    public init(capacity: Int = 400, limits: SourceExcerptLimits = SourceExcerptLimits()) {
        self.capacity = capacity
        self.limits = limits
    }

    /// Lines around `line` of the file at `hostPath`, read once for `run`.
    public func file(_ hostPath: String, line: Int, run: UUID) async -> Outcome {
        let key = Key(run: run, path: hostPath, line: line)
        if let cached = cache[key] { return cached }
        if let task = pending[key] { return await task.value }
        let limits = limits
        fileReads += 1
        let task = Task.detached(priority: .userInitiated) { SourceExcerptReader.read(path: hostPath, line: line, limits: limits) }
        pending[key] = task
        let outcome = await task.value
        pending[key] = nil
        remember(outcome, for: key)
        return outcome
    }

    /// Lines around a line of the code `request` ran, numbered like the editor.
    public func snippet(_ request: RunRequest, snippetLine: Int) async -> Outcome {
        let key = Key(run: request.runId, path: "", line: snippetLine)
        if let cached = cache[key] { return cached }
        let limits = limits
        let outcome = await Task.detached(priority: .userInitiated) { SourceExcerptReader.snippet(request, snippetLine: snippetLine, limits: limits) }.value
        remember(outcome, for: key)
        return outcome
    }

    /// What is cached for `key`, without reading.
    public func cached(_ key: Key) -> Outcome? { cache[key] }

    private func remember(_ outcome: Outcome, for key: Key) {
        if cache.updateValue(outcome, forKey: key) == nil { order.append(key) }
        while order.count > capacity {
            cache[order.removeFirst()] = nil
        }
    }
}
