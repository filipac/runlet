import Foundation

/// When an AI client's `run_php` may run (#43). Every run asks the user in Runlet, except
/// sandbox runs from a client the user allowed for this session. Nothing here connects,
/// starts, or runs anything: the app shows the sheet and runs only after Run is pressed.
///
/// - The session allowance exists only for the Laravel sandbox, lasts while that `runlet mcp`
///   process stays connected (and Runlet runs), and is granted only by the user's tick on a
///   sandbox sheet.
/// - Local projects, Docker applications, and SSH hosts always ask.
/// - Production targets always ask with a warning. The production guard's 10-minute grace
///   never applies to MCP runs, and approving one never grants it.
/// - SSH: a host that isn't connected is never connected silently. A profile that logs in by
///   itself (agent or keys) asks, and the sheet says approving will connect; a profile that
///   needs a login (password or 2FA) is refused until the user logs in with Connect….
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
        /// The user ticked "Allow for this session" on an earlier sandbox sheet of this connection.
        public var sandboxAllowedForSession: Bool
        /// Whether the production guard's 10-minute grace is active for the target. MCP runs
        /// ignore it; it is an input only so tests can show that.
        public var productionGraceActive: Bool

        public init(target: TargetRef, environment: TargetEnvironment, ssh: SSHState? = nil, sandboxAllowedForSession: Bool = false, productionGraceActive: Bool = false) {
            self.target = target
            self.environment = environment
            self.ssh = ssh
            self.sandboxAllowedForSession = sandboxAllowedForSession
            self.productionGraceActive = productionGraceActive
        }
    }

    /// What the approval sheet offers and says.
    public struct Prompt: Sendable, Equatable {
        /// "Allow for this session" (sandbox only).
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
        /// Run without a sheet: a sandbox run the user allowed for this session.
        case run
        case ask(Prompt)
        /// Don't ask and don't run (the reason goes back to the client).
        case refuse(String)
    }

    public static func decide(_ situation: Situation) -> Decision {
        let production = situation.environment == .production
        if case .ssh = situation.target {
            if situation.ssh == .needsLogin {
                return .refuse("This SSH host needs a login (a password or a one-time code), and Runlet never logs in for an AI client. Ask the user to choose Connect… in Runlet first; runs can then reuse that login.")
            }
            return .ask(Prompt(offersSessionAllowance: false, isProduction: production, connectsSSH: situation.ssh != .connected))
        }
        if situation.target == .sandbox, !production {
            if situation.sandboxAllowedForSession { return .run }
            return .ask(Prompt(offersSessionAllowance: true, isProduction: false, connectsSSH: false))
        }
        return .ask(Prompt(offersSessionAllowance: false, isProduction: production, connectsSSH: false))
    }

    /// What `list_targets` says about a target's approvals.
    public static func summary(for target: TargetRef, environment: TargetEnvironment) -> String {
        if environment == .production { return "Asks before every run, with a production warning." }
        switch target {
        case .sandbox: return "Asks before each run; the user can allow sandbox runs for the rest of this session."
        case .ssh: return "Asks before every run; never logs in by itself."
        default: return "Asks before every run."
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
