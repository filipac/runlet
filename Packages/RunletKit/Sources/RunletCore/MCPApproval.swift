import Foundation

/// When an AI client's `run_php` may run (#43). Every run asks the user in Runlet, except runs
/// on a target the user allowed for this client's session (#326). Nothing here connects,
/// starts, or runs anything: the app shows the sheet and runs only after Run is pressed.
///
/// - The session allowance is per connection and per target: the user's tick on a sheet allows
///   that one target, for that one `runlet mcp` process, while it stays connected (and Runlet
///   runs). Every target that isn't production can be allowed (`MCPSessionAllowance`).
/// - Production targets always ask with a warning, and never offer the allowance; a target
///   allowed earlier that is production now asks too. The production guard's 10-minute grace
///   never applies to MCP runs, and approving one never grants it.
/// - SSH: a host that isn't connected is never connected silently. A profile that logs in by
///   itself (agent or keys) asks, and the sheet says approving will connect; a profile that
///   needs a login (password or 2FA) is refused until the user logs in with Connect…. An
///   allowed host skips the sheet only while its connection is open.
public enum MCPApprovalPolicy {
    /// How long a request waits for an answer before it fails (nothing runs then).
    public static let timeout: TimeInterval = 5 * 60
    /// Requests that may wait for an answer at once, per connection.
    public static let maxWaitingPerConnection = 4

    public enum SSHState: Sendable, Equatable {
        /// The profile's shared connection is open.
        case connected
        /// Not connected; the profile logs in by itself, so approving opens the connection.
        case willConnect
        /// Not connected; logging in needs the user (Connect…), which Runlet never does for a client.
        case needsLogin
    }

    public struct Situation: Sendable, Equatable {
        public var target: TargetRef
        public var environment: TargetEnvironment
        /// For SSH targets; nil (unknown) counts as "approving connects".
        public var ssh: SSHState?
        /// The user ticked "Allow runs on this target … for this session" on an earlier sheet of
        /// this connection, and the target hasn't been edited since (`MCPSessionAllowance`).
        public var allowedForSession: Bool
        /// Whether the production guard's 10-minute grace is active for the target. MCP runs
        /// ignore it; it is an input only so tests can show that.
        public var productionGraceActive: Bool

        public init(target: TargetRef, environment: TargetEnvironment, ssh: SSHState? = nil, allowedForSession: Bool = false, productionGraceActive: Bool = false) {
            self.target = target
            self.environment = environment
            self.ssh = ssh
            self.allowedForSession = allowedForSession
            self.productionGraceActive = productionGraceActive
        }
    }

    /// What the approval sheet offers and says.
    public struct Prompt: Sendable, Equatable {
        /// "Allow runs on <target> from <client> for this session" (every target but production).
        public var offersSessionAllowance: Bool
        public var isProduction: Bool
        /// Approving opens an SSH connection.
        public var connectsSSH: Bool

        public init(offersSessionAllowance: Bool, isProduction: Bool, connectsSSH: Bool) {
            self.offersSessionAllowance = offersSessionAllowance
            self.isProduction = isProduction
            self.connectsSSH = connectsSSH
        }
    }

    public enum Decision: Sendable, Equatable {
        /// Run without a sheet: a target the user allowed for this connection's session (an SSH
        /// host only while connected).
        case run
        case ask(Prompt)
        /// Don't ask and don't run (the reason goes back to the client).
        case refuse(String)
    }

    public static func decide(_ situation: Situation) -> Decision {
        var connectsSSH = false
        if case .ssh = situation.target {
            switch situation.ssh {
            case .needsLogin:
                return .refuse("This SSH host needs a login (a password or a one-time code), and Runlet never logs in for an AI client. Ask the user to choose Connect… in Runlet first; runs can then reuse that login.")
            case .connected:
                connectsSSH = false
            case .willConnect, nil:
                connectsSSH = true
            }
        }
        if situation.environment == .production {
            return .ask(Prompt(offersSessionAllowance: false, isProduction: true, connectsSSH: connectsSSH))
        }
        // An allowed SSH host that isn't connected still asks: approving connects.
        if situation.allowedForSession, !connectsSSH { return .run }
        return .ask(Prompt(offersSessionAllowance: true, isProduction: false, connectsSSH: connectsSSH))
    }

    /// What `list_targets` says about a target's approvals.
    public static func summary(for target: TargetRef, environment: TargetEnvironment) -> String {
        if environment == .production { return "Asks before every run, with a production warning; can't be allowed for the session." }
        switch target {
        case .ssh: return "Asks before each run and never logs in by itself; the user can allow runs on this host from this client for the rest of the session (they skip the question only while the host is connected)."
        default: return "Asks before each run; the user can allow runs on this target from this client for the rest of the session."
        }
    }
}

/// "Allow runs on <target> from <client> for this session" (#326): the targets one MCP
/// connection may run on without a sheet. Each remembers the target's settings as the sheet
/// showed them, so editing the target (anything but what Runlet refreshes by itself, such as
/// the container id it last found), removing it, or marking it production ends its allowance.
public struct MCPSessionAllowance: Sendable, Equatable {
    private struct Entry: Sendable, Equatable {
        var target: TargetRef
        var settings: TargetSettings
    }

    private var entries: [Entry] = []

    public init() {}

    /// The allowed targets, in the order they were allowed.
    public var targets: [TargetRef] { entries.map(\.target) }
    public var isEmpty: Bool { entries.isEmpty }

    /// Allows `target` with its settings as the sheet showed them; nil (a removed target)
    /// allows nothing.
    public mutating func allow(_ target: TargetRef, settings: TargetSettings?) {
        guard let settings else { return }
        entries.removeAll { $0.target == target }
        entries.append(Entry(target: target, settings: settings))
    }

    /// Whether runs on `target` were allowed and the target is still as it was then. Production
    /// is the policy's to refuse (`MCPApprovalPolicy.decide`).
    public func allows(_ target: TargetRef, in library: TargetLibrary) -> Bool {
        guard let entry = entries.first(where: { $0.target == target }) else { return false }
        return entry.settings == library.settings(of: target)
    }

    /// Drops the targets that were edited or removed since they were allowed, or are production
    /// now. They ask again, even if a later edit puts them back as they were.
    public mutating func prune(_ library: TargetLibrary) {
        entries.removeAll { entry in
            library.settings(of: entry.target) != entry.settings || library.environment(for: entry.target) == .production
        }
    }

    public mutating func removeAll() {
        entries.removeAll()
    }
}

/// A target's saved settings, without what Runlet updates by itself: when it was last opened,
/// its revision, and the container id and image it last found. Two equal values mean nobody
/// edited the target in between.
public enum TargetSettings: Sendable, Hashable {
    case sandbox
    case local(LocalProject)
    case docker(DockerProfile)
    case ssh(SSHProfile)
}

extension TargetLibrary {
    /// The target's settings (`TargetSettings`), or nil when it was removed.
    public func settings(of target: TargetRef) -> TargetSettings? {
        switch target {
        case .sandbox:
            return .sandbox
        case .local(let id):
            guard var project = localProject(id) else { return nil }
            project.revision = 0
            project.lastOpenedAt = nil
            return .local(project)
        case .docker(let id):
            guard var profile = dockerProfile(id) else { return nil }
            profile.revision = 0
            profile.lastOpenedAt = nil
            profile.identity.lastContainerId = nil
            profile.identity.lastImage = nil
            return .docker(profile)
        case .ssh(let id):
            guard var profile = sshProfile(id) else { return nil }
            profile.revision = 0
            profile.lastOpenedAt = nil
            profile.container?.identity.lastContainerId = nil
            profile.container?.identity.lastImage = nil
            return .ssh(profile)
        }
    }
}

/// What `list_targets` returns.
public enum MCPCatalog {
    public struct SandboxInfo: Sendable {
        public var label: String
        public var status: String?

        public init(label: String, status: String? = nil) {
            self.label = label
            self.status = status
        }
    }

    /// Every target, in the order of Runlet's target menu, as JSON for the model.
    /// - Parameter sshState: the local connection state of an SSH profile (no network).
    public static func targets(_ library: TargetLibrary, sandbox: SandboxInfo, sshState: (SSHProfile) -> MCPApprovalPolicy.SSHState) -> MCPJSON {
        var entries: [MCPJSON] = []
        var sandboxEntry: [String: MCPJSON] = [
            "target": "sandbox",
            "name": .string(sandbox.label),
            "kind": "sandbox",
            "environment": "development",
            "description": "A disposable Laravel application with an SQLite database, for experiments.",
            "approval": .string(MCPApprovalPolicy.summary(for: .sandbox, environment: .development)),
        ]
        if let status = sandbox.status { sandboxEntry["status"] = .string(status) }
        entries.append(.object(sandboxEntry))
        let byName: (String, String) -> Bool = { $0.localizedStandardCompare($1) == .orderedAscending }
        for project in library.localProjects.sorted(by: { byName($0.name, $1.name) }) {
            let ref = TargetRef.local(project.id)
            entries.append(entry(ref, library, name: project.name, kind: "local", details: ["folder": .string(project.path)]))
        }
        for profile in library.dockerProfiles.sorted(by: { byName($0.name, $1.name) }) {
            let ref = TargetRef.docker(profile.id)
            entries.append(entry(ref, library, name: profile.name, kind: "docker", details: [
                "container": .string(profile.identity.displayName),
                "directory": .string(profile.workingDirectory),
            ]))
        }
        for profile in library.sshProfiles.sorted(by: { byName($0.name, $1.name) }) {
            let ref = TargetRef.ssh(profile.id)
            var details: [String: MCPJSON] = [
                "host": .string(profile.destinationLabel),
                "directory": .string(profile.container?.workingDirectory ?? profile.remoteDirectory),
            ]
            if let step = profile.container { details["container"] = .string(step.identity.displayName) }
            switch sshState(profile) {
            case .connected: details["connection"] = "connected"
            case .willConnect: details["connection"] = "not connected (approving a run connects with the user's SSH keys or agent)"
            case .needsLogin: details["connection"] = "not connected (needs the user to log in with Connect… in Runlet first)"
            }
            entries.append(entry(ref, library, name: profile.name, kind: "ssh", details: details))
        }
        return ["targets": .array(entries)]
    }

    private static func entry(_ ref: TargetRef, _ library: TargetLibrary, name: String, kind: String, details: [String: MCPJSON]) -> MCPJSON {
        let environment = library.environment(for: ref)
        var object = details
        object["target"] = .string(library.selector(for: ref))
        object["name"] = .string(name)
        object["kind"] = .string(kind)
        object["environment"] = .string(environment.rawValue)
        object["approval"] = .string(MCPApprovalPolicy.summary(for: ref, environment: environment))
        return .object(object)
    }

    /// The message for a target name that doesn't resolve.
    public static func targetProblem(_ query: String, _ match: TargetMatch) -> String? {
        switch match {
        case .found:
            return nil
        case .notFound:
            return "No target named “\(query)”. Use “sandbox”, or a `target` value from list_targets (local:<name>, docker:<name>, ssh:<name>)."
        case .ambiguous(let matches):
            return "“\(query)” matches more than one target: \(matches.joined(separator: "; ")). Use the exact `target` value from list_targets."
        }
    }

    /// A project snippet's id: the target's key and the file's name.
    public static func projectSnippetID(target: TargetRef, fileName: String) -> String {
        target.stableKey + "#" + fileName
    }

    /// The target key and file name of a project snippet id; nil for other ids.
    public static func parseProjectSnippetID(_ id: String) -> (targetKey: String, fileName: String)? {
        guard let hash = id.lastIndex(of: "#") else { return nil }
        let key = String(id[..<hash])
        let file = String(id[id.index(after: hash)...])
        guard !key.isEmpty, !file.isEmpty, !file.contains("/") else { return nil }
        return (key, file)
    }

    /// The first lines of some code, for listings.
    public static func preview(_ code: String, lines: Int = 3, characters: Int = 240) -> String {
        var text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<?php") { text = String(text.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines) }
        let head = text.components(separatedBy: "\n").prefix(lines).joined(separator: "\n")
        return head.count > characters ? String(head.prefix(characters - 1)) + "…" : head
    }
}
