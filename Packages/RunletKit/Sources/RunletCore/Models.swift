import Foundation

/// Which execution target a tab (or snippet) is associated with.
public enum TargetRef: Sendable, Codable, Hashable {
    case sandbox
    case local(UUID)
    case docker(UUID)

    public var stableKey: String {
        switch self {
        case .sandbox: "sandbox"
        case .local(let id): "local:\(id.uuidString)"
        case .docker(let id): "docker:\(id.uuidString)"
        }
    }
}

/// A native local project executed with host PHP.
public struct LocalProject: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var path: String
    /// Per-project PHP executable; nil uses the global default.
    public var phpExecutable: String?
    /// Language-service PHP target override (e.g. "8.2"); nil infers from composer.json.
    public var languagePHPVersion: String?
    public var revision: Int
    public var lastOpenedAt: Date?

    public init(id: UUID = UUID(), name: String, path: String, phpExecutable: String? = nil, languagePHPVersion: String? = nil, revision: Int = 1, lastOpenedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.phpExecutable = phpExecutable
        self.languagePHPVersion = languagePHPVersion
        self.revision = revision
        self.lastOpenedAt = lastOpenedAt
    }
}

/// How a saved Docker profile identifies its container across recreation.
public struct ContainerIdentity: Sendable, Codable, Hashable {
    /// Stable Compose labels, when the container was created by Compose.
    public var composeProject: String?
    public var composeService: String?
    /// Fallback identity when Compose labels are absent.
    public var containerName: String?
    /// Last resolved container, kept for diagnostics and as a cheap first check.
    public var lastContainerId: String?
    public var lastImage: String?

    public init(composeProject: String? = nil, composeService: String? = nil, containerName: String? = nil, lastContainerId: String? = nil, lastImage: String? = nil) {
        self.composeProject = composeProject
        self.composeService = composeService
        self.containerName = containerName
        self.lastContainerId = lastContainerId
        self.lastImage = lastImage
    }

    public var isCompose: Bool { composeProject != nil && composeService != nil }

    public var displayName: String {
        if let composeProject, let composeService { return "\(composeProject)/\(composeService)" }
        return containerName ?? lastContainerId.map { String($0.prefix(12)) } ?? "container"
    }
}

/// A saved existing Docker application.
public struct DockerProfile: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var identity: ContainerIdentity
    public var workingDirectory: String
    public var phpExecutable: String
    /// Optional `docker exec --user` value (e.g. "sail" or "1000:1000").
    public var user: String?
    public var temporaryDirectory: String
    /// Optional host checkout of the same source, used for PHPantom indexing and path mapping.
    public var localSourcePath: String?
    public var languagePHPVersion: String?
    /// Resolve the container automatically when the profile is opened. Never runs code.
    public var autoResolve: Bool
    public var revision: Int
    public var lastOpenedAt: Date?

    public init(id: UUID = UUID(), name: String, identity: ContainerIdentity, workingDirectory: String, phpExecutable: String = "php", user: String? = nil, temporaryDirectory: String = "/tmp", localSourcePath: String? = nil, languagePHPVersion: String? = nil, autoResolve: Bool = true, revision: Int = 1, lastOpenedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.identity = identity
        self.workingDirectory = workingDirectory
        self.phpExecutable = phpExecutable
        self.user = user
        self.temporaryDirectory = temporaryDirectory
        self.localSourcePath = localSourcePath
        self.languagePHPVersion = languagePHPVersion
        self.autoResolve = autoResolve
        self.revision = revision
        self.lastOpenedAt = lastOpenedAt
    }

    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case emptyName, relativeWorkingDirectory, emptyPHP, invalidUser, relativeTemporaryDirectory, missingIdentity

        public var description: String {
            switch self {
            case .emptyName: "Give the profile a name."
            case .relativeWorkingDirectory: "The container working directory must be an absolute path."
            case .emptyPHP: "Set the PHP executable (usually `php`)."
            case .invalidUser: "The execution user may contain only letters, digits, '_', '-', '.', and an optional ':group'."
            case .relativeTemporaryDirectory: "The temporary directory must be an absolute path."
            case .missingIdentity: "Choose a container."
            }
        }
    }

    /// Validates fields that end up as `docker exec` arguments.
    public func validate() -> [ValidationError] {
        var errors: [ValidationError] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { errors.append(.emptyName) }
        if !workingDirectory.hasPrefix("/") { errors.append(.relativeWorkingDirectory) }
        if phpExecutable.trimmingCharacters(in: .whitespaces).isEmpty || phpExecutable.hasPrefix("-") { errors.append(.emptyPHP) }
        if let user, !user.isEmpty, user.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]*(:[A-Za-z0-9_][A-Za-z0-9_.-]*)?$"#, options: .regularExpression) == nil {
            errors.append(.invalidUser)
        }
        if !temporaryDirectory.hasPrefix("/") { errors.append(.relativeTemporaryDirectory) }
        if identity.composeService == nil && identity.containerName == nil { errors.append(.missingIdentity) }
        return errors
    }
}

public enum AppearancePreference: String, Sendable, Codable, CaseIterable {
    case system, light, dark
}

/// How the Laravel sandbox executes.
public enum SandboxRuntimePreference: String, Sendable, Codable, CaseIterable {
    /// Compatible local PHP when available, otherwise Docker.
    case automatic
    case localPHP
    case docker
}

/// Where tabs are shown.
public enum TabLayout: String, Sendable, Codable, CaseIterable {
    case horizontal
    /// A sidebar of tab cards with target details.
    case vertical
}

/// How run output is displayed.
public enum OutputDisplayMode: String, Sendable, Codable, CaseIterable {
    /// Cards with expandable value trees.
    case structured
    /// CLI-style text transcript (dumps/results rendered as text).
    case plain
    /// Exactly the bytes PHP wrote to stdout/stderr.
    case raw
}

/// How far structured values expand automatically.
public enum ValueExpansion: String, Sendable, Codable, CaseIterable {
    case collapsed
    case firstLevel
    case all
}

public enum OutputLayout: String, Sendable, Codable, CaseIterable {
    case right, bottom
}

public struct AppSettings: Sendable, Codable, Equatable {
    public var appearance: AppearancePreference = .system
    public var fontSize: Double = 13
    public var tabWidth: Int = 4
    public var insertSpaces: Bool = true
    public var outputLayout: OutputLayout = .right
    /// Global default PHP executable for local execution; nil auto-detects.
    public var defaultPHPExecutable: String?
    /// Target used by new tabs.
    public var defaultTarget: TargetRef = .sandbox
    /// Run Selection is a separate action; when true, Run prefers a non-empty selection.
    public var runPrefersSelection: Bool = false
    public var historyLimit: Int = 1000
    /// Overrides Docker CLI discovery.
    public var dockerExecutable: String?
    public var languageServiceEnabled: Bool = true
    public var sandboxRuntime: SandboxRuntimePreference = .automatic
    public var outputMode: OutputDisplayMode = .structured
    public var valueExpansion: ValueExpansion = .firstLevel
    public var tabLayout: TabLayout = .horizontal
    /// Width of the vertical tab sidebar in points (user-resizable, remembered).
    public var verticalTabsWidth: Double = 190
    /// User changes to command shortcuts, keyed by command id.
    public var shortcutOverrides: [String: ShortcutOverride] = [:]
    /// Whether new windows show the terminal panel (the last show/hide choice).
    public var terminalVisible: Bool = false
    /// Height of the terminal panel in points (user-resizable, remembered).
    public var terminalHeight: Double = 240
    /// Option sends Meta (ESC-prefixed keys) in the terminal instead of typing special characters.
    public var terminalOptionAsMeta: Bool = false

    public init() {}

    public init(from decoder: Decoder) throws {
        // Tolerate missing keys so older settings files keep loading.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        appearance = (try? c.decode(AppearancePreference.self, forKey: .appearance)) ?? d.appearance
        fontSize = (try? c.decode(Double.self, forKey: .fontSize)) ?? d.fontSize
        tabWidth = (try? c.decode(Int.self, forKey: .tabWidth)) ?? d.tabWidth
        insertSpaces = (try? c.decode(Bool.self, forKey: .insertSpaces)) ?? d.insertSpaces
        outputLayout = (try? c.decode(OutputLayout.self, forKey: .outputLayout)) ?? d.outputLayout
        defaultPHPExecutable = try? c.decodeIfPresent(String.self, forKey: .defaultPHPExecutable)
        defaultTarget = (try? c.decode(TargetRef.self, forKey: .defaultTarget)) ?? d.defaultTarget
        runPrefersSelection = (try? c.decode(Bool.self, forKey: .runPrefersSelection)) ?? d.runPrefersSelection
        historyLimit = (try? c.decode(Int.self, forKey: .historyLimit)) ?? d.historyLimit
        dockerExecutable = try? c.decodeIfPresent(String.self, forKey: .dockerExecutable)
        languageServiceEnabled = (try? c.decode(Bool.self, forKey: .languageServiceEnabled)) ?? d.languageServiceEnabled
        sandboxRuntime = (try? c.decode(SandboxRuntimePreference.self, forKey: .sandboxRuntime)) ?? d.sandboxRuntime
        outputMode = (try? c.decode(OutputDisplayMode.self, forKey: .outputMode)) ?? d.outputMode
        valueExpansion = (try? c.decode(ValueExpansion.self, forKey: .valueExpansion)) ?? d.valueExpansion
        tabLayout = (try? c.decode(TabLayout.self, forKey: .tabLayout)) ?? d.tabLayout
        verticalTabsWidth = (try? c.decode(Double.self, forKey: .verticalTabsWidth)) ?? d.verticalTabsWidth
        shortcutOverrides = (try? c.decode([String: ShortcutOverride].self, forKey: .shortcutOverrides)) ?? d.shortcutOverrides
        terminalVisible = (try? c.decode(Bool.self, forKey: .terminalVisible)) ?? d.terminalVisible
        terminalHeight = (try? c.decode(Double.self, forKey: .terminalHeight)) ?? d.terminalHeight
        terminalOptionAsMeta = (try? c.decode(Bool.self, forKey: .terminalOptionAsMeta)) ?? d.terminalOptionAsMeta
    }
}

/// Persisted editor tab state. Restoring a tab never runs its code.
public struct TabState: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var code: String
    public var target: TargetRef
    public var selection: NSRangeCodable
    public var fileURL: URL?
    public var createdAt: Date

    public init(id: UUID = UUID(), title: String, code: String = "", target: TargetRef = .sandbox, selection: NSRangeCodable = .init(location: 0, length: 0), fileURL: URL? = nil, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.code = code
        self.target = target
        self.selection = selection
        self.fileURL = fileURL
        self.createdAt = createdAt
    }
}

/// All open windows and their tabs. Older single-window session files (`tabs` +
/// `selectedTabId`) still load, as one window.
public struct SessionState: Sendable, Codable, Equatable {
    public var windows: [WindowState]
    /// The window that was frontmost.
    public var activeWindowId: UUID?

    public init(windows: [WindowState], activeWindowId: UUID? = nil) {
        self.windows = windows
        self.activeWindowId = activeWindowId
    }

    /// Single-window convenience.
    public init(tabs: [TabState] = [], selectedTabId: UUID? = nil) {
        self.init(windows: tabs.isEmpty ? [] : [WindowState(tabs: tabs, selectedTabId: selectedTabId)])
    }

    /// Every tab in every window.
    public var tabs: [TabState] { windows.flatMap(\.tabs) }

    enum CodingKeys: String, CodingKey { case windows, activeWindowId, tabs, selectedTabId }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let windows = try container.decodeIfPresent([WindowState].self, forKey: .windows) {
            self.windows = windows
            activeWindowId = try container.decodeIfPresent(UUID.self, forKey: .activeWindowId)
        } else {
            let tabs = try container.decodeIfPresent([TabState].self, forKey: .tabs) ?? []
            let selected = try container.decodeIfPresent(UUID.self, forKey: .selectedTabId)
            windows = tabs.isEmpty ? [] : [WindowState(tabs: tabs, selectedTabId: selected)]
            activeWindowId = windows.first?.id
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(windows, forKey: .windows)
        try container.encodeIfPresent(activeWindowId, forKey: .activeWindowId)
    }
}

public struct HistoryEntry: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var runId: UUID
    public var timestamp: Date
    public var code: String
    public var target: TargetRef
    public var targetLabel: String
    public var status: RunStatus
    public var reason: String
    public var elapsedMs: Int

    public init(id: UUID = UUID(), runId: UUID, timestamp: Date = Date(), code: String, target: TargetRef, targetLabel: String, status: RunStatus, reason: String, elapsedMs: Int) {
        self.id = id
        self.runId = runId
        self.timestamp = timestamp
        self.code = code
        self.target = target
        self.targetLabel = targetLabel
        self.status = status
        self.reason = reason
        self.elapsedMs = elapsedMs
    }
}

public struct Snippet: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var label: String
    public var code: String
    /// Explicit association; nil means "any target".
    public var target: TargetRef?
    public var targetLabel: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), label: String, code: String, target: TargetRef? = nil, targetLabel: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.label = label
        self.code = code
        self.target = target
        self.targetLabel = targetLabel
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Saved targets other than the sandbox.
public struct TargetLibrary: Sendable, Codable, Equatable {
    public var localProjects: [LocalProject] = []
    public var dockerProfiles: [DockerProfile] = []

    public init(localProjects: [LocalProject] = [], dockerProfiles: [DockerProfile] = []) {
        self.localProjects = localProjects
        self.dockerProfiles = dockerProfiles
    }

    public func localProject(_ id: UUID) -> LocalProject? { localProjects.first { $0.id == id } }
    public func dockerProfile(_ id: UUID) -> DockerProfile? { dockerProfiles.first { $0.id == id } }
}

/// Simple fuzzy-ish search used for history, snippets, and profiles.
public func matchesSearch(_ query: String, in fields: String...) -> Bool {
    let terms = query.lowercased().split(separator: " ").map(String.init)
    guard !terms.isEmpty else { return true }
    let haystack = fields.joined(separator: " ").lowercased()
    return terms.allSatisfy { haystack.contains($0) }
}
