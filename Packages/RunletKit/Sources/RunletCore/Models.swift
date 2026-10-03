import Foundation

/// Which execution target a tab (or snippet) is associated with.
public enum TargetRef: Sendable, Codable, Hashable {
    case sandbox
    case local(UUID)
    case docker(UUID)
    /// A saved SSH host (`SSHProfile`).
    case ssh(UUID)

    public var stableKey: String {
        switch self {
        case .sandbox: "sandbox"
        case .local(let id): "local:\(id.uuidString)"
        case .docker(let id): "docker:\(id.uuidString)"
        case .ssh(let id): "ssh:\(id.uuidString)"
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
    /// Per-project `declare(strict_types=1)` override; nil inherits `AppSettings.strictTypes`.
    public var strictTypes: Bool?
    /// Per-project mail interception override; nil inherits `AppSettings.interceptMail`.
    public var interceptMail: Bool?
    /// Development, staging, or production (nil: development). See `TargetEnvironment`.
    public var environment: TargetEnvironment?
    public var color: TargetColor?
    public var revision: Int
    public var lastOpenedAt: Date?

    public init(id: UUID = UUID(), name: String, path: String, phpExecutable: String? = nil, languagePHPVersion: String? = nil, strictTypes: Bool? = nil, environment: TargetEnvironment? = nil, color: TargetColor? = nil, revision: Int = 1, lastOpenedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.phpExecutable = phpExecutable
        self.languagePHPVersion = languagePHPVersion
        self.strictTypes = strictTypes
        self.environment = environment
        self.color = color
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
    /// Per-profile `declare(strict_types=1)` override; nil inherits `AppSettings.strictTypes`.
    public var strictTypes: Bool?
    /// Per-profile mail interception override; nil inherits `AppSettings.interceptMail`.
    public var interceptMail: Bool?
    /// Resolve the container automatically when the profile is opened. Never runs code.
    public var autoResolve: Bool
    /// Development, staging, or production (nil: development). See `TargetEnvironment`.
    public var environment: TargetEnvironment?
    public var color: TargetColor?
    public var revision: Int
    public var lastOpenedAt: Date?

    public init(id: UUID = UUID(), name: String, identity: ContainerIdentity, workingDirectory: String, phpExecutable: String = "php", user: String? = nil, temporaryDirectory: String = "/tmp", localSourcePath: String? = nil, languagePHPVersion: String? = nil, strictTypes: Bool? = nil, autoResolve: Bool = true, environment: TargetEnvironment? = nil, color: TargetColor? = nil, revision: Int = 1, lastOpenedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.identity = identity
        self.workingDirectory = workingDirectory
        self.phpExecutable = phpExecutable
        self.user = user
        self.temporaryDirectory = temporaryDirectory
        self.localSourcePath = localSourcePath
        self.languagePHPVersion = languagePHPVersion
        self.strictTypes = strictTypes
        self.autoResolve = autoResolve
        self.environment = environment
        self.color = color
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
/// Where double-click (or Return) in the History and Snippets panes puts the code. Opening
/// an entry only loads code; nothing runs until the user presses Run.
public enum LibraryOpenBehavior: String, Sendable, Codable, CaseIterable {
    /// The current tab when it is blank (nothing but whitespace or `<?php`, no file, not
    /// running) and on the entry's target (snippets saved for any target match every tab);
    /// otherwise a new tab.
    case reuseBlankTab
    /// Always a new tab with the entry's target.
    case newTab
    /// The current tab: its code is replaced (⌘Z undoes it) and it switches to the entry's
    /// target. A running tab gets a new tab instead.
    case currentTab
}

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
    /// Shows the Run Log under the output (launch command, runner steps, stderr, exit).
    public var showRunLog: Bool = false
    /// What double-clicking a History or Snippets entry does.
    public var libraryOpenBehavior: LibraryOpenBehavior = .reuseBlankTab
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
    /// Width of the History & Snippets panel in points (user-resizable, remembered).
    public var libraryPanelWidth: Double = 320
    /// The editor's share of the width when the output pane is on the right (0…1, remembered).
    public var editorSplitRight: Double = 0.5
    /// The editor's share of the height when the output pane is below (0…1, remembered).
    public var editorSplitBottom: Double = 0.5
    /// User changes to command shortcuts, keyed by command id.
    public var shortcutOverrides: [String: ShortcutOverride] = [:]
    /// Whether the output pane is shown next to/below the editor (Show/Hide Output Pane).
    /// With `hideOutputUntilRun` on, each tab decides instead (`OutputPaneVisibility`).
    public var outputVisible: Bool = true
    /// Settings ▸ General ▸ Output (#60): the output pane stays hidden, the editor taking its
    /// space, until a run starts in the tab; it then appears at the saved layout and split.
    public var hideOutputUntilRun: Bool = false
    /// Settings ▸ General ▸ Output (#60): Escape in the editor hides the output pane, once
    /// nothing in the editor needs it (completions, hover and inline-value panels, find bar).
    public var escapeHidesOutput: Bool = false
    /// Declare `strict_types=1` for every run (unless the code declares it itself).
    /// Local projects and Docker profiles can override it.
    public var strictTypes: Bool = false
    /// Editor font family; nil uses the system monospaced font.
    public var editorFontName: String?
    /// Editor line height as a multiple of the font's line height (`lineHeightRange`).
    public var lineHeight: Double = 1.15
    /// Programming ligatures (`->`, `=>`, `!==`) in fonts that have them.
    public var ligatures: Bool = false
    /// Soft-wrap long lines to the editor width instead of scrolling horizontally.
    public var softWrap: Bool = false
    /// Where file links in the output open.
    public var externalEditor: ExternalEditor = .none
    /// Command template for `ExternalEditor.custom`, with `{file}` and `{line}` placeholders.
    /// Split into arguments and run directly, never through a shell.
    public var externalEditorCommand: String?

    public static let lineHeightRange: ClosedRange<Double> = 1.0...2.0
    /// Whether new windows show the terminal panel (the last show/hide choice).
    public var terminalVisible: Bool = false
    /// Height of the terminal panel in points (user-resizable, remembered).
    public var terminalHeight: Double = 240
    /// Option sends Meta (ESC-prefixed keys) in the terminal instead of typing special characters.
    public var terminalOptionAsMeta: Bool = false
    /// Run inspector: record queries, mail, log messages, and driver sections during runs.
    public var runInspector: Bool = true
    /// Ask drivers to intercept mail during runs (recorded, not sent). Off by default: it
    /// changes what a run does. Projects and Docker profiles can override it.
    public var interceptMail: Bool = false
    /// Render HTML previews of returned or dumped mailables, views, and responses (runs view code).
    public var renderPreviews: Bool = true
    /// Magic comments (#10): `//?`, `/*?*/`, `/*?->…*/`, and `/*?.*/` show values in the editor.
    /// Off, they are ordinary comments: runs get no probes on any target, and the editor neither
    /// highlights them nor shows values.
    public var magicComments: Bool = true
    /// When a run's output appears (#82): as the code runs, or all at once when it ends. Covers
    /// printed output, dumps, the result, errors, magic-comment values, and the run inspector.
    /// Replaces the magic comments' "Show values while the code runs" switch (`streamInlineValues`,
    /// read once from older settings files: off becomes `.atOnce`).
    public var outputDelivery: OutputDelivery = .realtime
    /// Settings ▸ AI Clients: listen for `runlet mcp` on the private MCP socket (#43). Off by
    /// default; every run a client asks for still waits for the user's approval.
    public var mcpServerEnabled: Bool = false

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
        showRunLog = (try? c.decode(Bool.self, forKey: .showRunLog)) ?? d.showRunLog
        libraryOpenBehavior = (try? c.decode(LibraryOpenBehavior.self, forKey: .libraryOpenBehavior)) ?? d.libraryOpenBehavior
        historyLimit = (try? c.decode(Int.self, forKey: .historyLimit)) ?? d.historyLimit
        dockerExecutable = try? c.decodeIfPresent(String.self, forKey: .dockerExecutable)
        languageServiceEnabled = (try? c.decode(Bool.self, forKey: .languageServiceEnabled)) ?? d.languageServiceEnabled
        sandboxRuntime = (try? c.decode(SandboxRuntimePreference.self, forKey: .sandboxRuntime)) ?? d.sandboxRuntime
        outputMode = (try? c.decode(OutputDisplayMode.self, forKey: .outputMode)) ?? d.outputMode
        valueExpansion = (try? c.decode(ValueExpansion.self, forKey: .valueExpansion)) ?? d.valueExpansion
        tabLayout = (try? c.decode(TabLayout.self, forKey: .tabLayout)) ?? d.tabLayout
        verticalTabsWidth = (try? c.decode(Double.self, forKey: .verticalTabsWidth)) ?? d.verticalTabsWidth
        libraryPanelWidth = (try? c.decode(Double.self, forKey: .libraryPanelWidth)) ?? d.libraryPanelWidth
        editorSplitRight = (try? c.decode(Double.self, forKey: .editorSplitRight)).flatMap { (0...1).contains($0) ? $0 : nil } ?? d.editorSplitRight
        editorSplitBottom = (try? c.decode(Double.self, forKey: .editorSplitBottom)).flatMap { (0...1).contains($0) ? $0 : nil } ?? d.editorSplitBottom
        shortcutOverrides = (try? c.decode([String: ShortcutOverride].self, forKey: .shortcutOverrides)) ?? d.shortcutOverrides
        outputVisible = (try? c.decode(Bool.self, forKey: .outputVisible)) ?? d.outputVisible
        hideOutputUntilRun = (try? c.decode(Bool.self, forKey: .hideOutputUntilRun)) ?? d.hideOutputUntilRun
        escapeHidesOutput = (try? c.decode(Bool.self, forKey: .escapeHidesOutput)) ?? d.escapeHidesOutput
        strictTypes = (try? c.decode(Bool.self, forKey: .strictTypes)) ?? d.strictTypes
        if let name = try? c.decodeIfPresent(String.self, forKey: .editorFontName), !name.isEmpty { editorFontName = name }
        lineHeight = (try? c.decode(Double.self, forKey: .lineHeight)).map { min(max($0, Self.lineHeightRange.lowerBound), Self.lineHeightRange.upperBound) } ?? d.lineHeight
        ligatures = (try? c.decode(Bool.self, forKey: .ligatures)) ?? d.ligatures
        softWrap = (try? c.decode(Bool.self, forKey: .softWrap)) ?? d.softWrap
        externalEditor = (try? c.decode(ExternalEditor.self, forKey: .externalEditor)) ?? d.externalEditor
        externalEditorCommand = try? c.decodeIfPresent(String.self, forKey: .externalEditorCommand)
        terminalVisible = (try? c.decode(Bool.self, forKey: .terminalVisible)) ?? d.terminalVisible
        terminalHeight = (try? c.decode(Double.self, forKey: .terminalHeight)) ?? d.terminalHeight
        terminalOptionAsMeta = (try? c.decode(Bool.self, forKey: .terminalOptionAsMeta)) ?? d.terminalOptionAsMeta
        runInspector = (try? c.decode(Bool.self, forKey: .runInspector)) ?? d.runInspector
        interceptMail = (try? c.decode(Bool.self, forKey: .interceptMail)) ?? d.interceptMail
        renderPreviews = (try? c.decode(Bool.self, forKey: .renderPreviews)) ?? d.renderPreviews
        magicComments = (try? c.decode(Bool.self, forKey: .magicComments)) ?? d.magicComments
        if let delivery = try? c.decode(OutputDelivery.self, forKey: .outputDelivery) {
            outputDelivery = delivery
        } else if let legacy = try? decoder.container(keyedBy: LegacyKeys.self), (try? legacy.decode(Bool.self, forKey: .streamInlineValues)) == false {
            // #10's switch, saved before Output existed: values held until the run ended.
            outputDelivery = .atOnce
        } else {
            outputDelivery = d.outputDelivery
        }
        mcpServerEnabled = (try? c.decode(Bool.self, forKey: .mcpServerEnabled)) ?? d.mcpServerEnabled
    }

    /// Keys older settings files may have that are no longer saved.
    private enum LegacyKeys: String, CodingKey {
        /// Magic comments' "Show values while the code runs" (#10), replaced by `outputDelivery`.
        case streamInlineValues
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
    /// PHP or SQL (#35); absent in sessions saved before SQL tabs (PHP).
    public var language: TabLanguage
    /// An SQL tab's connection name; nil for the application's default connection.
    public var sqlConnection: String?

    public init(id: UUID = UUID(), title: String, code: String = "", target: TargetRef = .sandbox, selection: NSRangeCodable = .init(location: 0, length: 0), fileURL: URL? = nil, createdAt: Date = Date(), language: TabLanguage = .php, sqlConnection: String? = nil) {
        self.id = id
        self.title = title
        self.code = code
        self.target = target
        self.selection = selection
        self.fileURL = fileURL
        self.createdAt = createdAt
        self.language = language
        self.sqlConnection = sqlConnection
    }

    enum CodingKeys: String, CodingKey {
        case id, title, code, target, selection, fileURL, createdAt, language, sqlConnection
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        code = try c.decode(String.self, forKey: .code)
        target = try c.decode(TargetRef.self, forKey: .target)
        selection = try c.decode(NSRangeCodable.self, forKey: .selection)
        fileURL = try c.decodeIfPresent(URL.self, forKey: .fileURL)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        language = try c.decodeIfPresent(TabLanguage.self, forKey: .language) ?? .php
        sqlConnection = try c.decodeIfPresent(String.self, forKey: .sqlConnection)
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
    /// SQL for runs of SQL tabs (#35); nil (PHP) in history saved before SQL tabs.
    public var language: TabLanguage?
    /// How the target was marked when the run started (#12): a snapshot, so editing the target
    /// later doesn't relabel the run. nil in history saved before snapshots existed.
    public var targetEnvironment: TargetEnvironment?
    /// The target's colour when the run started (snapshot, like `targetEnvironment`).
    public var targetColor: TargetColor?
    /// The environment the application reported when the run booted it (`bootstrapped`), if any.
    public var appEnvironment: String?

    public init(id: UUID = UUID(), runId: UUID, timestamp: Date = Date(), code: String, target: TargetRef, targetLabel: String, status: RunStatus, reason: String, elapsedMs: Int, language: TabLanguage? = nil, targetEnvironment: TargetEnvironment? = nil, targetColor: TargetColor? = nil, appEnvironment: String? = nil) {
        self.id = id
        self.runId = runId
        self.timestamp = timestamp
        self.code = code
        self.target = target
        self.targetLabel = targetLabel
        self.status = status
        self.reason = reason
        self.elapsedMs = elapsedMs
        self.language = language == .php ? nil : language
        self.targetEnvironment = targetEnvironment
        self.targetColor = targetColor
        self.appEnvironment = appEnvironment
    }

    /// The run happened on a target marked production (from the snapshot; false for history
    /// saved before snapshots).
    public var ranOnProduction: Bool { targetEnvironment == .production }
}

public struct Snippet: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var label: String
    /// Optional notes; absent in snippet libraries saved before descriptions were supported.
    public var description: String?
    public var code: String
    /// Explicit association; nil means "any target".
    public var target: TargetRef?
    public var targetLabel: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), label: String, code: String, description: String? = nil, target: TargetRef? = nil, targetLabel: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.label = label
        self.code = code
        self.description = description
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
    public var sshProfiles: [SSHProfile] = []

    public init(localProjects: [LocalProject] = [], dockerProfiles: [DockerProfile] = [], sshProfiles: [SSHProfile] = []) {
        self.localProjects = localProjects
        self.dockerProfiles = dockerProfiles
        self.sshProfiles = sshProfiles
    }

    /// Tolerates missing keys so libraries saved before SSH profiles existed keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        localProjects = try c.decodeIfPresent([LocalProject].self, forKey: .localProjects) ?? []
        dockerProfiles = try c.decodeIfPresent([DockerProfile].self, forKey: .dockerProfiles) ?? []
        sshProfiles = try c.decodeIfPresent([SSHProfile].self, forKey: .sshProfiles) ?? []
    }

    public func localProject(_ id: UUID) -> LocalProject? { localProjects.first { $0.id == id } }
    public func dockerProfile(_ id: UUID) -> DockerProfile? { dockerProfiles.first { $0.id == id } }
    public func sshProfile(_ id: UUID) -> SSHProfile? { sshProfiles.first { $0.id == id } }

    /// Whether runs on `target` ask drivers to intercept mail: the project's or profile's
    /// override, else `global`. The sandbox uses `global`.
    public func interceptMail(for target: TargetRef, global: Bool) -> Bool {
        if case .local(let id) = target { return localProject(id)?.interceptMail ?? global }
        if case .docker(let id) = target { return dockerProfile(id)?.interceptMail ?? global }
        if case .ssh(let id) = target { return sshProfile(id)?.interceptMail ?? global }
        return global
    }

    /// Whether runs on `target` declare `strict_types=1`: the project's or profile's
    /// override, else `global`. The sandbox always uses `global`.
    public func strictTypes(for target: TargetRef, global: Bool) -> Bool {
        switch target {
        case .sandbox: global
        case .local(let id): localProject(id)?.strictTypes ?? global
        case .docker(let id): dockerProfile(id)?.strictTypes ?? global
        case .ssh(let id): sshProfile(id)?.strictTypes ?? global
        }
    }

    /// The target's environment (N14). The sandbox, missing targets, and targets that never
    /// set one are development.
    public func environment(for target: TargetRef) -> TargetEnvironment {
        switch target {
        case .sandbox: .development
        case .local(let id): localProject(id)?.environment ?? .development
        case .docker(let id): dockerProfile(id)?.environment ?? .development
        case .ssh(let id): sshProfile(id)?.environment ?? .development
        }
    }

    /// The target's accent colour, if one was chosen.
    public func color(for target: TargetRef) -> TargetColor? {
        switch target {
        case .sandbox: nil
        case .local(let id): localProject(id)?.color
        case .docker(let id): dockerProfile(id)?.color
        case .ssh(let id): sshProfile(id)?.color
        }
    }

    /// Production targets confirm every run and never load or connect by themselves.
    public func isProduction(_ target: TargetRef) -> Bool {
        environment(for: target) == .production
    }

    /// The project folder on this Mac that belongs to `target`: a local project's directory,
    /// or a Docker or SSH profile's local source folder (nil when none is set).
    public func localFolder(for target: TargetRef) -> String? {
        let path: String?
        switch target {
        case .sandbox: path = nil
        case .local(let id): path = localProject(id)?.path
        case .docker(let id): path = dockerProfile(id)?.localSourcePath
        case .ssh(let id): path = sshProfile(id)?.localSourcePath
        }
        guard let path, !path.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (path as NSString).expandingTildeInPath
    }
}

/// Simple fuzzy-ish search used for history, snippets, and profiles.
public func matchesSearch(_ query: String, in fields: String...) -> Bool {
    let terms = query.lowercased().split(separator: " ").map(String.init)
    guard !terms.isEmpty else { return true }
    let haystack = fields.joined(separator: " ").lowercased()
    return terms.allSatisfy { haystack.contains($0) }
}
