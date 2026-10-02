import Foundation

/// Version of the run request/event contract shared by the app and the PHP runner.
public let runProtocolVersion = 1

/// What the user asked to run, snapshotted when Run is accepted.
public struct RunRequest: Sendable, Codable, Equatable {
    public var protocolVersion: Int
    public var runId: UUID
    public var tabId: UUID
    public var documentVersion: Int
    public var target: TargetSnapshot
    public var code: String
    /// Present when only a selection runs; maps runner lines back to the editor.
    public var selection: SourceSelection?
    /// The runner declares `strict_types=1` (on the first line, so line numbers are
    /// unchanged) unless the code declares strict_types itself.
    public var strictTypes: Bool
    /// What the run inspector records (queries, mail, logs), mail interception, and previews.
    public var inspector: RunInspectorOptions
    /// Values the runner asked the app to remember for this target during this session
    /// (`remember` events: the chosen driver, a WordPress site URL, …). The runner checks each
    /// is still valid before using it.
    public var hints: [String: String] = [:]

    public init(runId: UUID = UUID(), tabId: UUID, documentVersion: Int, target: TargetSnapshot, code: String, selection: SourceSelection? = nil, strictTypes: Bool = false, inspector: RunInspectorOptions = RunInspectorOptions()) {
        self.protocolVersion = runProtocolVersion
        self.runId = runId
        self.tabId = tabId
        self.documentVersion = documentVersion
        self.target = target
        self.code = code
        self.selection = selection
        self.strictTypes = strictTypes
        self.inspector = inspector
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion, runId, tabId, documentVersion, target, code, selection, strictTypes, inspector
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        runId = try c.decode(UUID.self, forKey: .runId)
        tabId = try c.decode(UUID.self, forKey: .tabId)
        documentVersion = try c.decode(Int.self, forKey: .documentVersion)
        target = try c.decode(TargetSnapshot.self, forKey: .target)
        code = try c.decode(String.self, forKey: .code)
        selection = try c.decodeIfPresent(SourceSelection.self, forKey: .selection)
        // Absent in requests encoded before the strict-types option existed.
        strictTypes = try c.decodeIfPresent(Bool.self, forKey: .strictTypes) ?? false
        inspector = try c.decodeIfPresent(RunInspectorOptions.self, forKey: .inspector) ?? RunInspectorOptions()
    }

    /// Maps a 1-based line in the submitted code to a 1-based editor line.
    public func editorLine(forSnippetLine line: Int) -> Int {
        line + (selection?.startLine ?? 1) - 1
    }

    /// Maps a 1-based column; only the selection's first line is offset by its start column.
    public func editorColumn(forSnippetLine line: Int, column: Int) -> Int {
        guard let selection, line == 1 else { return column }
        return column + selection.startColumn - 1
    }
}

/// Where a selection started in the editor (1-based line, 1-based UTF-16 column).
public struct SourceSelection: Sendable, Codable, Equatable {
    public var startLine: Int
    public var startColumn: Int
    public var utf16Range: NSRangeCodable

    public init(startLine: Int, startColumn: Int, utf16Range: NSRangeCodable) {
        self.startLine = startLine
        self.startColumn = startColumn
        self.utf16Range = utf16Range
    }
}

public struct NSRangeCodable: Sendable, Codable, Hashable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public init(_ range: NSRange) {
        self.init(location: range.location, length: range.length)
    }

    public var nsRange: NSRange { NSRange(location: location, length: length) }
}

/// The resolved execution context captured when a run starts. Later edits to the
/// target or profile never redirect an active run.
public struct TargetSnapshot: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case sandboxLocal
        case sandboxDocker
        case local
        case docker
        /// The server's PHP over the system `ssh` client (`ssh` holds the endpoint).
        case ssh
    }

    public var kind: Kind
    /// Human-readable label shown on run output, e.g. "Sandbox · PHP 8.4" or "lease-api (docker)".
    public var label: String
    /// Identity of the target definition (sandbox id, project id, or Docker profile id).
    public var targetId: String
    public var profileRevision: Int
    /// Host directory (local/sandbox) or container directory (Docker).
    public var workingDirectory: String
    public var phpExecutable: String
    /// Docker-only fields.
    public var containerId: String?
    public var containerName: String?
    public var image: String?
    public var user: String?
    public var temporaryDirectory: String?
    /// Sandbox via Docker: the host directory mounted into the disposable container.
    public var hostMountDirectory: String?
    /// SSH targets: how to reach the server (`workingDirectory` is the server directory).
    /// With a remote container step, the Docker fields above describe the container on that
    /// server (`workingDirectory` is then the container's directory).
    public var ssh: SSHEndpoint?
    /// SSH container step: the Docker command on the server (`docker`, `sudo -n docker`).
    public var dockerCommand: String?
    /// SSH container step: the container path that corresponds to the profile's local folder,
    /// when it differs from `workingDirectory` (the server directory's bind mount).
    public var localFolderRoot: String?

    /// An SSH target that runs inside a container on the server.
    public var isRemoteContainer: Bool { kind == .ssh && containerId != nil }

    public init(kind: Kind, label: String, targetId: String, profileRevision: Int = 0, workingDirectory: String, phpExecutable: String, containerId: String? = nil, containerName: String? = nil, image: String? = nil, user: String? = nil, temporaryDirectory: String? = nil, hostMountDirectory: String? = nil, ssh: SSHEndpoint? = nil, dockerCommand: String? = nil, localFolderRoot: String? = nil) {
        self.kind = kind
        self.label = label
        self.targetId = targetId
        self.profileRevision = profileRevision
        self.workingDirectory = workingDirectory
        self.phpExecutable = phpExecutable
        self.containerId = containerId
        self.containerName = containerName
        self.image = image
        self.user = user
        self.temporaryDirectory = temporaryDirectory
        self.hostMountDirectory = hostMountDirectory
        self.ssh = ssh
        self.dockerCommand = dockerCommand
        self.localFolderRoot = localFolderRoot
    }
}

/// A normalized, sequenced event delivered for one run.
public struct RunEvent: Sendable, Equatable, Identifiable {
    public var runId: UUID
    public var sequence: Int
    public var kind: Kind

    public var id: String { "\(runId.uuidString)-\(sequence)" }

    public init(runId: UUID, sequence: Int, kind: Kind) {
        self.runId = runId
        self.sequence = sequence
        self.kind = kind
    }

    public enum Kind: Sendable, Equatable {
        case started(StartedInfo)
        case bootstrapped(BootstrappedInfo)
        case stdout(Data)
        case stderr(Data)
        case dump(DumpInfo)
        case result(ResultInfo)
        case error(RunErrorInfo)
        case notice(String)
        /// Run inspector: sections, records (queries, mail, logs, …), and limits.
        case inspector(InspectorEvent)
        /// A Run Log line: how the run was launched, what the runner did while booting, …
        case log(RunLogEntry)
        /// A value to remember for this target until the app quits (sent back as `hints`).
        case remember(key: String, value: String)
        /// Exactly one per accepted run, always last.
        case finished(FinishedInfo)

        public var typeName: String {
            switch self {
            case .started: "started"
            case .bootstrapped: "bootstrapped"
            case .stdout: "stdout"
            case .stderr: "stderr"
            case .dump: "dump"
            case .result: "result"
            case .error: "error"
            case .notice: "notice"
            case .inspector: "inspector"
            case .log: "log"
            case .remember: "remember"
            case .finished: "finished"
            }
        }
    }
}

/// One line of a run's diagnostic log (Run ▸ Show Run Log): from the app (`launch`, `exit`)
/// or the runner (`runner`, `driver`, `bootstrap`). Never contains secrets: environment
/// values and the runner script are left out.
public struct RunLogEntry: Sendable, Codable, Equatable {
    public var source: String
    public var message: String
    public var detail: String?

    public init(source: String, message: String, detail: String? = nil) {
        self.source = source
        self.message = message
        self.detail = detail
    }
}

public struct StartedInfo: Sendable, Codable, Equatable {
    public var pid: Int?
    public var phpVersion: String?
    public var phpBinary: String?
    public var workingDirectory: String?
    public var framework: String?
    public var user: Int?
}

public struct BootstrappedInfo: Sendable, Codable, Equatable {
    public var framework: String?
    public var frameworkVersion: String?
    public var bootstrapMs: Int?
    /// Display name of the driver that booted the app (built-in or a project `.runlet` driver).
    public var driverName: String?
    /// The project driver file under `.runlet/`, when a project driver booted the app.
    public var driverFile: String?
    /// Variables the driver injected into the snippet scope: name → class or type.
    public var variables: [String: String]?
}

public struct SourceLocation: Sendable, Codable, Equatable {
    public var inSnippet: Bool?
    public var snippetLine: Int?
    public var file: String?
    public var line: Int?
}

public struct DumpInfo: Sendable, Codable, Equatable {
    public var index: Int
    public var origin: String
    public var label: String?
    public var value: ValueNode
    public var inSnippet: Bool?
    public var snippetLine: Int?
    public var file: String?
    public var line: Int?
    /// Rendered HTML of a dumped mailable, view, or response (`Driver::preview()`).
    public var preview: HTMLPreview?

    public var isDD: Bool { origin == "dd" }
}

public struct ResultInfo: Sendable, Codable, Equatable {
    public var hasValue: Bool
    public var value: ValueNode?
    /// Rendered HTML of a returned mailable, view, or response (`Driver::preview()`).
    public var preview: HTMLPreview?
}

public enum RunErrorStage: String, Sendable, Codable {
    case launch, bootstrap, parse, execute, transport
}

public struct RunErrorInfo: Sendable, Codable, Equatable {
    public struct Frame: Sendable, Codable, Equatable {
        public var function: String?
        public var inSnippet: Bool?
        public var snippetLine: Int?
        public var file: String?
        public var line: Int?
    }

    public struct Previous: Sendable, Codable, Equatable {
        public var className: String
        public var message: String
    }

    public var stage: RunErrorStage
    public var className: String?
    public var message: String
    public var inSnippet: Bool?
    public var snippetLine: Int?
    public var snippetColumn: Int?
    public var file: String?
    public var line: Int?
    public var fatal: Bool?
    public var trace: [Frame]?
    public var previous: Previous?

    public init(stage: RunErrorStage, className: String? = nil, message: String) {
        self.stage = stage
        self.className = className
        self.message = message
    }
}

public enum RunStatus: String, Sendable, Codable {
    case completed, failed, cancelled
}

public struct FinishedInfo: Sendable, Codable, Equatable {
    public var status: RunStatus
    /// completed | dd | exit | error | fatal | cancelled | launch-failed | transport-closed
    public var reason: String
    public var exitCode: Int32?
    public var elapsedMs: Int
    public var peakMemory: Int?
    public var truncation: String?

    public init(status: RunStatus, reason: String, exitCode: Int32? = nil, elapsedMs: Int, peakMemory: Int? = nil, truncation: String? = nil) {
        self.status = status
        self.reason = reason
        self.exitCode = exitCode
        self.elapsedMs = elapsedMs
        self.peakMemory = peakMemory
        self.truncation = truncation
    }
}

/// The runner's own completion record; the backend turns it into `finished`.
public struct RunnerFinishedInfo: Sendable, Codable, Equatable {
    public var reason: String
    public var elapsedMs: Int?
    public var peakMemory: Int?
    public var executeMs: Int?
}
