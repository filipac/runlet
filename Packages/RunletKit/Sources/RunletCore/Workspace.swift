import Foundation

/// A `.runlet` workspace file: a window's tabs with their code and *embedded* target
/// definitions, so the file works on another machine or committed next to a project.
/// Machine-specific state (container IDs, profile UUIDs) is never written.
public struct WorkspaceDocument: Sendable, Codable, Equatable {
    public static let format = "runlet-workspace"
    public static let currentVersion = 1
    public static let fileExtension = "runlet"
    public static let typeIdentifier = "dev.runlet.workspace"

    public var format: String
    public var version: Int
    public var tabs: [WorkspaceTab]
    public var selectedIndex: Int?

    public init(tabs: [WorkspaceTab], selectedIndex: Int?) {
        self.format = Self.format
        self.version = Self.currentVersion
        self.tabs = tabs
        self.selectedIndex = selectedIndex
    }

    public enum ReadError: Error, CustomStringConvertible, Equatable {
        case notAWorkspace
        case newerVersion(Int)

        public var description: String {
            switch self {
            case .notAWorkspace: "This file is not a Runlet workspace."
            case .newerVersion(let version): "This workspace was written by a newer Runlet (format version \(version))."
            }
        }
    }

    public static func read(from data: Data) throws -> WorkspaceDocument {
        let document: WorkspaceDocument
        do {
            document = try JSONDecoder().decode(WorkspaceDocument.self, from: data)
        } catch {
            throw ReadError.notAWorkspace
        }
        guard document.format == format else { throw ReadError.notAWorkspace }
        guard document.version <= currentVersion else { throw ReadError.newerVersion(document.version) }
        return document
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public struct WorkspaceTab: Sendable, Codable, Equatable {
    public var title: String
    public var code: String
    public var target: WorkspaceTarget
    /// A PHP file this tab edits, relative to the workspace file when possible.
    public var file: String?

    public init(title: String, code: String, target: WorkspaceTarget, file: String? = nil) {
        self.title = title
        self.code = code
        self.target = target
        self.file = file
    }
}

/// A self-contained target definition.
public enum WorkspaceTarget: Sendable, Codable, Hashable {
    case sandbox
    case local(LocalDefinition)
    case docker(DockerDefinition)
    /// An SSH host. The file names the host (an alias or host name), which is infrastructure
    /// detail but no secret: no keys, passwords, or control sockets are written.
    case ssh(SSHDefinition)

    public struct LocalDefinition: Sendable, Codable, Hashable {
        public var name: String
        /// Relative to the workspace file's directory when inside it, else absolute (`~` allowed).
        public var path: String
        public var phpExecutable: String?
        public var languagePHPVersion: String?
    }

    public struct DockerDefinition: Sendable, Codable, Hashable {
        public var name: String
        public var composeProject: String?
        public var composeService: String?
        public var containerName: String?
        public var workingDirectory: String
        public var phpExecutable: String
        public var user: String?
        public var temporaryDirectory: String
        /// Optional local checkout, relative to the workspace file when possible.
        public var localSourcePath: String?
        public var languagePHPVersion: String?
    }

    public struct SSHDefinition: Sendable, Codable, Hashable {
        public var name: String
        public var host: String
        public var user: String?
        public var port: Int?
        public var jumpHost: String?
        public var remoteDirectory: String
        public var phpExecutable: String
        public var authentication: SSHAuthentication?
        /// Optional local checkout, relative to the workspace file when possible.
        public var localSourcePath: String?
        public var languagePHPVersion: String?
        /// Kept so a production host opened from a workspace still asks before each run.
        public var environment: TargetEnvironment?
        /// The container step on the host: its Compose identity or name (never a container
        /// ID), directory, PHP, user, temporary directory, and Docker command.
        public var container: SSHContainerDefinition?
    }

    public struct SSHContainerDefinition: Sendable, Codable, Hashable {
        public var composeProject: String?
        public var composeService: String?
        public var containerName: String?
        public var workingDirectory: String
        public var phpExecutable: String
        public var user: String?
        public var temporaryDirectory: String
        public var dockerCommand: String

        public init(_ step: RemoteContainerStep) {
            composeProject = step.identity.composeProject
            composeService = step.identity.composeService
            containerName = step.identity.isCompose ? nil : step.identity.containerName
            workingDirectory = step.workingDirectory
            phpExecutable = step.phpExecutable
            user = step.user
            temporaryDirectory = step.temporaryDirectory
            dockerCommand = step.dockerCommand
        }

        public var step: RemoteContainerStep {
            RemoteContainerStep(identity: ContainerIdentity(composeProject: composeProject, composeService: composeService, containerName: containerName), workingDirectory: workingDirectory, phpExecutable: phpExecutable, user: user, temporaryDirectory: temporaryDirectory, dockerCommand: dockerCommand)
        }

        /// The same container step, ignoring what was last seen running.
        func matches(_ step: RemoteContainerStep?) -> Bool {
            guard let step else { return false }
            let identity = step.identity
            let sameIdentity = composeProject != nil && composeService != nil
                ? identity.composeProject == composeProject && identity.composeService == composeService
                : !identity.isCompose && identity.containerName == containerName
            return sameIdentity && step.workingDirectory == workingDirectory
        }
    }

    enum CodingKeys: String, CodingKey { case kind, local, docker, ssh }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "sandbox": self = .sandbox
        case "local": self = .local(try container.decode(LocalDefinition.self, forKey: .local))
        case "docker": self = .docker(try container.decode(DockerDefinition.self, forKey: .docker))
        case "ssh": self = .ssh(try container.decode(SSHDefinition.self, forKey: .ssh))
        default: self = .sandbox
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sandbox:
            try container.encode("sandbox", forKey: .kind)
        case .local(let definition):
            try container.encode("local", forKey: .kind)
            try container.encode(definition, forKey: .local)
        case .docker(let definition):
            try container.encode("docker", forKey: .kind)
            try container.encode(definition, forKey: .docker)
        case .ssh(let definition):
            try container.encode("ssh", forKey: .kind)
            try container.encode(definition, forKey: .ssh)
        }
    }

    public var displayName: String {
        switch self {
        case .sandbox: "Laravel Sandbox"
        case .local(let definition): definition.name
        case .docker(let definition): "\(definition.name) (Docker)"
        case .ssh(let definition): "\(definition.name) (SSH)"
        }
    }
}

/// Converts between workspace definitions and the user's saved targets.
public enum WorkspaceTargets {
    /// Stores `path` relative to `base` when it is inside it, else as an absolute path
    /// abbreviated with `~` when under the home directory.
    public static func storedPath(_ path: String, relativeTo base: URL) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let basePath = base.standardizedFileURL.path
        if standardized == basePath { return "." }
        if standardized.hasPrefix(basePath + "/") {
            return String(standardized.dropFirst(basePath.count + 1))
        }
        return (standardized as NSString).abbreviatingWithTildeInPath
    }

    /// Resolves a stored path against the workspace file's directory.
    public static func resolvedPath(_ stored: String, relativeTo base: URL) -> String {
        let expanded = (stored as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL.path }
        return base.appendingPathComponent(stored).standardizedFileURL.path
    }

    public static func definition(for target: TargetRef, library: TargetLibrary, base: URL) -> WorkspaceTarget {
        switch target {
        case .sandbox:
            return .sandbox
        case .local(let id):
            guard let project = library.localProject(id) else { return .sandbox }
            return .local(.init(name: project.name, path: storedPath(project.path, relativeTo: base), phpExecutable: project.phpExecutable, languagePHPVersion: project.languagePHPVersion))
        case .docker(let id):
            guard let profile = library.dockerProfile(id) else { return .sandbox }
            return .docker(.init(
                name: profile.name,
                composeProject: profile.identity.composeProject,
                composeService: profile.identity.composeService,
                containerName: profile.identity.isCompose ? nil : profile.identity.containerName,
                workingDirectory: profile.workingDirectory,
                phpExecutable: profile.phpExecutable,
                user: profile.user,
                temporaryDirectory: profile.temporaryDirectory,
                localSourcePath: profile.localSourcePath.map { storedPath($0, relativeTo: base) },
                languagePHPVersion: profile.languagePHPVersion
            ))
        case .ssh(let id):
            guard let profile = library.sshProfile(id) else { return .sandbox }
            return .ssh(.init(
                name: profile.name,
                host: profile.host,
                user: profile.user,
                port: profile.port,
                jumpHost: profile.jumpHost,
                remoteDirectory: profile.remoteDirectory,
                phpExecutable: profile.phpExecutable,
                authentication: profile.authentication,
                localSourcePath: profile.localSourcePath.map { storedPath($0, relativeTo: base) },
                languagePHPVersion: profile.languagePHPVersion,
                environment: profile.environment == .development ? nil : profile.environment,
                container: profile.container.map { WorkspaceTarget.SSHContainerDefinition($0) }
            ))
        }
    }

    /// A saved target matching the definition, if the user already has one.
    public static func match(_ target: WorkspaceTarget, in library: TargetLibrary, base: URL) -> TargetRef? {
        switch target {
        case .sandbox:
            return .sandbox
        case .local(let definition):
            let path = resolvedPath(definition.path, relativeTo: base)
            return library.localProjects.first { URL(fileURLWithPath: $0.path).standardizedFileURL.path == path }.map { .local($0.id) }
        case .docker(let definition):
            return library.dockerProfiles.first { profile in
                let sameIdentity: Bool
                if let project = definition.composeProject, let service = definition.composeService {
                    sameIdentity = profile.identity.composeProject == project && profile.identity.composeService == service
                } else {
                    sameIdentity = definition.containerName != nil && profile.identity.containerName == definition.containerName && !profile.identity.isCompose
                }
                return sameIdentity && profile.workingDirectory == definition.workingDirectory
            }.map { .docker($0.id) }
        case .ssh(let definition):
            return library.sshProfiles.first { profile in
                profile.host == definition.host && profile.user == definition.user && profile.port == definition.port
                    && profile.remoteDirectory == definition.remoteDirectory
                    && (definition.container.map { $0.matches(profile.container) } ?? (profile.container == nil))
            }.map { .ssh($0.id) }
        }
    }

    /// Creates a new saved target from a definition (no container is resolved or run).
    public static func makeTarget(_ target: WorkspaceTarget, base: URL) -> (ref: TargetRef, project: LocalProject?, profile: DockerProfile?, sshProfile: SSHProfile?) {
        switch target {
        case .sandbox:
            return (.sandbox, nil, nil, nil)
        case .local(let definition):
            let project = LocalProject(name: definition.name, path: resolvedPath(definition.path, relativeTo: base), phpExecutable: definition.phpExecutable, languagePHPVersion: definition.languagePHPVersion)
            return (.local(project.id), project, nil, nil)
        case .docker(let definition):
            let identity = ContainerIdentity(composeProject: definition.composeProject, composeService: definition.composeService, containerName: definition.containerName)
            let profile = DockerProfile(
                name: definition.name,
                identity: identity,
                workingDirectory: definition.workingDirectory,
                phpExecutable: definition.phpExecutable,
                user: definition.user,
                temporaryDirectory: definition.temporaryDirectory,
                localSourcePath: definition.localSourcePath.map { resolvedPath($0, relativeTo: base) },
                languagePHPVersion: definition.languagePHPVersion
            )
            return (.docker(profile.id), nil, profile, nil)
        case .ssh(let definition):
            let profile = SSHProfile(
                name: definition.name,
                host: definition.host,
                user: definition.user,
                port: definition.port,
                jumpHost: definition.jumpHost,
                remoteDirectory: definition.remoteDirectory,
                phpExecutable: definition.phpExecutable,
                authentication: definition.authentication ?? .automatic,
                localSourcePath: definition.localSourcePath.map { resolvedPath($0, relativeTo: base) },
                languagePHPVersion: definition.languagePHPVersion,
                environment: definition.environment ?? .development,
                container: definition.container?.step
            )
            return (.ssh(profile.id), nil, nil, profile)
        }
    }
}

/// Persisted state of one window (its tabs and optional workspace file).
public struct WindowState: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var tabs: [TabState]
    public var selectedTabId: UUID?
    public var workspacePath: String?
    /// Unsaved workspace edits survive quitting and are restored, like other Mac apps.
    public var workspaceEdited: Bool

    enum CodingKeys: String, CodingKey { case id, tabs, selectedTabId, workspacePath, workspaceEdited }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        tabs = try container.decodeIfPresent([TabState].self, forKey: .tabs) ?? []
        selectedTabId = try container.decodeIfPresent(UUID.self, forKey: .selectedTabId)
        workspacePath = try container.decodeIfPresent(String.self, forKey: .workspacePath)
        workspaceEdited = try container.decodeIfPresent(Bool.self, forKey: .workspaceEdited) ?? false
    }

    public init(id: UUID = UUID(), tabs: [TabState], selectedTabId: UUID? = nil, workspacePath: String? = nil, workspaceEdited: Bool = false) {
        self.id = id
        self.tabs = tabs
        self.selectedTabId = selectedTabId
        self.workspacePath = workspacePath
        self.workspaceEdited = workspaceEdited
    }
}
