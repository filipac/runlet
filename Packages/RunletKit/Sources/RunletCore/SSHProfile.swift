import Foundation

/// What kind of environment a target is (N14). Production targets get a red badge, a
/// confirmation before each run, and stricter defaults (nothing loads or connects by itself).
public enum TargetEnvironment: String, Sendable, Codable, CaseIterable, Hashable {
    case development
    case staging
    case production

    public var displayName: String {
        switch self {
        case .development: "Development"
        case .staging: "Staging"
        case .production: "Production"
        }
    }

    /// Unknown values (written by a newer Runlet) read as development instead of failing
    /// the whole target library.
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = TargetEnvironment(rawValue: value) ?? .development
    }

    /// Development < staging < production.
    public var strictness: Int {
        switch self {
        case .development: 0
        case .staging: 1
        case .production: 2
        }
    }

    /// The stricter of two markings (#139: a target's and its saved connection's).
    public static func stricter(_ a: TargetEnvironment, _ b: TargetEnvironment) -> TargetEnvironment {
        b.strictness > a.strictness ? b : a
    }
}

/// A target's accent colour, shown on tab cards, the target menu, and the status bar.
public enum TargetColor: String, Sendable, Codable, CaseIterable, Hashable {
    case red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, brown, gray

    public var displayName: String { rawValue.capitalized }

    /// Unknown values read as gray instead of failing the whole target library.
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = TargetColor(rawValue: value) ?? .gray
    }
}

/// How runs on an SSH host authenticate. Runlet never sees, stores, or logs a secret: OpenSSH
/// handles every prompt, and runs reuse one shared connection (an OpenSSH ControlMaster).
public enum SSHAuthentication: String, Sendable, Codable, CaseIterable, Hashable {
    /// ssh-agent, the 1Password agent, key files without a passphrase, or keys whose
    /// passphrase is in the macOS keychain: OpenSSH logs in without asking (`BatchMode`), and
    /// the first run opens the shared connection by itself.
    case automatic
    /// Password, keyboard-interactive, or 2FA (or a key passphrase that no agent holds): the
    /// user logs in once with Connect… (OpenSSH's own prompts in a terminal tab), and runs
    /// reuse that connection until Disconnect. Runs never try to log in themselves.
    case interactive

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = SSHAuthentication(rawValue: value) ?? .automatic
    }
}

/// A saved SSH host: snippets run with the server's PHP in `remoteDirectory`, through the
/// system OpenSSH client (`/usr/bin/ssh`), so `~/.ssh/config` (aliases, `ProxyJump`,
/// `IdentityAgent`, `Include`, `Match`), agents, and `known_hosts` behave exactly as in the
/// user's terminal. With `container`, runs `docker exec` into a container on that host instead.
public struct SSHProfile: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// A `~/.ssh/config` alias or a host name, passed to `ssh` unchanged.
    public var host: String
    /// Overrides for the login user, port, and jump host; nil uses what `~/.ssh/config` says.
    public var user: String?
    public var port: Int?
    public var jumpHost: String?
    /// A private key file on this Mac (`ssh -i`), as Import from TablePlus… sets it (#188);
    /// nil uses what `~/.ssh/config` and the agent offer. Runlet passes only the path: it never
    /// reads or copies the key, and OpenSSH (or the agent) handles its passphrase.
    public var identityFile: String?
    /// Absolute directory of the application on the server. It may be a symlink (Forge's
    /// `…/current`); the real path PHP reports is mapped too.
    public var remoteDirectory: String
    /// The server's PHP: `php`, a name such as `php8.3`, or an absolute path.
    public var phpExecutable: String
    public var authentication: SSHAuthentication
    /// Minutes an automatically opened shared connection stays open after its last use; nil
    /// keeps it until Disconnect. Connect… logins always stay until Disconnect.
    public var keepAliveMinutes: Int?
    /// `ssh -C`: the runner (about 1.7 MB, sent when the server doesn't keep it) compresses
    /// about five times over.
    public var compression: Bool
    /// Keep the runner and compiled PHP on the server: runs enable PHP's opcode cache with a
    /// file cache in a private folder (`~/.cache/runlet/opcache`, mode 0700), so the project's
    /// files aren't recompiled on every run, and (#48) keep Runlet's runner by its hash in
    /// `~/.cache/runlet/runner`, so a run sends only its request. On for new profiles (#68); a
    /// profile saved without the key (before #68, or switched off) reads as off, so servers
    /// already in use don't change. Not with a container step.
    public var keepCompiledPHP: Bool = true
    /// The project's checkout on this Mac: completion, file links, snippets, host commands,
    /// facts, and the terminal use it. nil runs in limited mode.
    public var localSourcePath: String?
    /// Language-service PHP target (e.g. "8.3"); nil infers it from the local composer.json.
    public var languagePHPVersion: String?
    /// Per-profile `declare(strict_types=1)` override; nil inherits `AppSettings.strictTypes`.
    public var strictTypes: Bool?
    /// Per-profile mail interception override; nil inherits `AppSettings.interceptMail`.
    public var interceptMail: Bool?
    public var environment: TargetEnvironment
    public var color: TargetColor?
    /// Compare the server's checkout (branch and commit, or `composer.lock`) with the local
    /// folder after Test Connection. Off by default: it reads files on the server.
    public var checkDrift: Bool
    /// Optional: run inside a Docker container on this host (`docker exec` over SSH) instead
    /// of with the host's PHP. The container is resolved like a Docker profile's.
    public var container: RemoteContainerStep?
    public var revision: Int
    public var lastOpenedAt: Date?

    public init(id: UUID = UUID(), name: String, host: String, user: String? = nil, port: Int? = nil, jumpHost: String? = nil, remoteDirectory: String, phpExecutable: String = "php", authentication: SSHAuthentication = .automatic, keepAliveMinutes: Int? = 10, compression: Bool = true, localSourcePath: String? = nil, languagePHPVersion: String? = nil, strictTypes: Bool? = nil, environment: TargetEnvironment = .development, color: TargetColor? = nil, checkDrift: Bool = false, container: RemoteContainerStep? = nil, identityFile: String? = nil, revision: Int = 1, lastOpenedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.user = user
        self.port = port
        self.jumpHost = jumpHost
        self.remoteDirectory = remoteDirectory
        self.phpExecutable = phpExecutable
        self.authentication = authentication
        self.keepAliveMinutes = keepAliveMinutes
        self.compression = compression
        self.localSourcePath = localSourcePath
        self.languagePHPVersion = languagePHPVersion
        self.strictTypes = strictTypes
        self.environment = environment
        self.color = color
        self.checkDrift = checkDrift
        self.container = container
        self.identityFile = identityFile
        self.revision = revision
        self.lastOpenedAt = lastOpenedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, host, user, port, jumpHost, identityFile, remoteDirectory, phpExecutable, authentication, keepAliveMinutes, compression, keepCompiledPHP
        case localSourcePath, languagePHPVersion, strictTypes, interceptMail, environment, color, checkDrift, container, revision, lastOpenedAt
    }

    /// Tolerates missing keys so profiles saved by earlier builds keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SSHProfile(name: "", host: "", remoteDirectory: "")
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        user = try c.decodeIfPresent(String.self, forKey: .user)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        jumpHost = try c.decodeIfPresent(String.self, forKey: .jumpHost)
        identityFile = try? c.decodeIfPresent(String.self, forKey: .identityFile)
        remoteDirectory = try c.decode(String.self, forKey: .remoteDirectory)
        phpExecutable = try c.decodeIfPresent(String.self, forKey: .phpExecutable) ?? d.phpExecutable
        authentication = try c.decodeIfPresent(SSHAuthentication.self, forKey: .authentication) ?? d.authentication
        keepAliveMinutes = c.contains(.keepAliveMinutes) ? try c.decodeIfPresent(Int.self, forKey: .keepAliveMinutes) : d.keepAliveMinutes
        compression = try c.decodeIfPresent(Bool.self, forKey: .compression) ?? d.compression
        // Not `d.keepCompiledPHP`: a missing key means a profile saved before it was on by
        // default (#68), which stays off.
        keepCompiledPHP = try c.decodeIfPresent(Bool.self, forKey: .keepCompiledPHP) ?? false
        localSourcePath = try c.decodeIfPresent(String.self, forKey: .localSourcePath)
        languagePHPVersion = try c.decodeIfPresent(String.self, forKey: .languagePHPVersion)
        strictTypes = try c.decodeIfPresent(Bool.self, forKey: .strictTypes)
        interceptMail = try c.decodeIfPresent(Bool.self, forKey: .interceptMail)
        environment = try c.decodeIfPresent(TargetEnvironment.self, forKey: .environment) ?? d.environment
        color = try c.decodeIfPresent(TargetColor.self, forKey: .color)
        checkDrift = try c.decodeIfPresent(Bool.self, forKey: .checkDrift) ?? d.checkDrift
        container = try c.decodeIfPresent(RemoteContainerStep.self, forKey: .container)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? d.revision
        lastOpenedAt = try c.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(host, forKey: .host)
        try c.encodeIfPresent(user, forKey: .user)
        try c.encodeIfPresent(port, forKey: .port)
        try c.encodeIfPresent(jumpHost, forKey: .jumpHost)
        try c.encodeIfPresent(identityFile, forKey: .identityFile)
        try c.encode(remoteDirectory, forKey: .remoteDirectory)
        try c.encode(phpExecutable, forKey: .phpExecutable)
        try c.encode(authentication, forKey: .authentication)
        // Written as null when the connection stays until Disconnect (missing means the default).
        try c.encode(keepAliveMinutes, forKey: .keepAliveMinutes)
        try c.encode(compression, forKey: .compression)
        // Always written, so "off" is explicit (a missing key also reads as off).
        try c.encode(keepCompiledPHP, forKey: .keepCompiledPHP)
        try c.encodeIfPresent(localSourcePath, forKey: .localSourcePath)
        try c.encodeIfPresent(languagePHPVersion, forKey: .languagePHPVersion)
        try c.encodeIfPresent(strictTypes, forKey: .strictTypes)
        try c.encodeIfPresent(interceptMail, forKey: .interceptMail)
        try c.encode(environment, forKey: .environment)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encode(checkDrift, forKey: .checkDrift)
        try c.encodeIfPresent(container, forKey: .container)
        try c.encode(revision, forKey: .revision)
        try c.encodeIfPresent(lastOpenedAt, forKey: .lastOpenedAt)
    }

    /// "deploy@app-prod", or just the host when the user comes from `~/.ssh/config`.
    public var destinationLabel: String {
        let base = user.map { "\($0)@\(host)" } ?? host
        return port.map { "\(base):\($0)" } ?? base
    }

    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case emptyName, invalidHost, invalidUser, invalidPort, invalidJumpHost, invalidIdentityFile, missingRemoteDirectory, relativeRemoteDirectory, tildeRemoteDirectory, invalidPHP, invalidKeepAlive
        case missingContainer, relativeContainerDirectory, invalidContainerPHP, invalidContainerUser, relativeContainerTemporaryDirectory, invalidDockerCommand

        public var description: String {
            switch self {
            case .emptyName: "Give the profile a name."
            case .invalidHost: "Enter a host name or `~/.ssh/config` alias (no spaces, not starting with `-`)."
            case .invalidUser: "The user may contain only letters, digits, '_', '-', and '.'."
            case .invalidPort: "The port must be a number from 1 to 65535."
            case .invalidJumpHost: "The jump host may not contain spaces or start with `-`."
            case .invalidIdentityFile: "The key file must be a path on this Mac (starting with `/` or `~/`), without line breaks."
            case .missingRemoteDirectory: "Enter the application's folder on the server, such as `/var/www/app`. Detect and Browse… find it on the server for you."
            case .relativeRemoteDirectory: "The remote directory must be an absolute path (starting with `/`)."
            case .tildeRemoteDirectory: "Runlet doesn't expand `~` on the server. Enter the full path (such as `/home/forge/app`), or click Detect to replace `~` with the server's home folder."
            case .invalidPHP: "Set the server's PHP executable (usually `php`); it can't start with `-`."
            case .invalidKeepAlive: "Keep the connection open for 1 to 1440 minutes, or until Disconnect."
            case .missingContainer: "Choose the container on this host (List Containers), or turn off running inside a container."
            case .relativeContainerDirectory: "The container's working directory must be an absolute path."
            case .invalidContainerPHP: "Set the container's PHP executable (usually `php`); it can't start with `-`."
            case .invalidContainerUser: "The execution user may contain only letters, digits, '_', '-', '.', and an optional ':group'."
            case .relativeContainerTemporaryDirectory: "The container's temporary directory must be an absolute path."
            case .invalidDockerCommand: "Use `docker`, an absolute path to it, or `sudo -n docker` (passwordless sudo only: runs can't answer a sudo prompt)."
            }
        }

        /// The directory problems, which the form shows under the Directory field.
        public static let directoryErrors: [ValidationError] = [.missingRemoteDirectory, .relativeRemoteDirectory, .tildeRemoteDirectory]
        /// Problems that stop `ssh` itself (Connect… works without a name or directory).
        public static let connectionErrors: [ValidationError] = [.invalidHost, .invalidUser, .invalidPort, .invalidJumpHost, .invalidIdentityFile]
    }

    /// Validates the fields that end up in `ssh` arguments or the remote command line, as they
    /// are saved (`normalized`: surrounding whitespace and a trailing `/` don't count).
    public func validate() -> [ValidationError] {
        let profile = normalized
        var errors: [ValidationError] = []
        func plainWord(_ value: String) -> Bool {
            !value.isEmpty && !value.hasPrefix("-") && value.unicodeScalars.allSatisfy { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }
        }
        if profile.name.isEmpty { errors.append(.emptyName) }
        if !plainWord(profile.host) { errors.append(.invalidHost) }
        if let user = profile.user, user.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]*$"#, options: .regularExpression) == nil {
            errors.append(.invalidUser)
        }
        if let port = profile.port, !(1...65535).contains(port) { errors.append(.invalidPort) }
        if let jumpHost = profile.jumpHost, !plainWord(jumpHost) { errors.append(.invalidJumpHost) }
        if let identityFile = profile.identityFile, !Self.isValidIdentityFile(identityFile) { errors.append(.invalidIdentityFile) }
        let directory = profile.remoteDirectory
        if directory.isEmpty {
            errors.append(.missingRemoteDirectory)
        } else if directory.hasPrefix("~") {
            errors.append(.tildeRemoteDirectory)
        } else if !directory.hasPrefix("/") || directory.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            errors.append(.relativeRemoteDirectory)
        }
        if profile.phpExecutable.isEmpty || profile.phpExecutable.hasPrefix("-") || profile.phpExecutable.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            errors.append(.invalidPHP)
        }
        if let keepAliveMinutes = profile.keepAliveMinutes, !(1...1440).contains(keepAliveMinutes) { errors.append(.invalidKeepAlive) }
        if let container = profile.container { errors += container.validate() }
        return errors
    }

    /// The profile as it is saved: whitespace (including a pasted newline) trimmed around
    /// every text field, blank optional fields cleared, and a trailing `/` dropped from the
    /// directory.
    public var normalized: SSHProfile {
        func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
        func optional(_ value: String?) -> String? { value.map(trimmed).flatMap { $0.isEmpty ? nil : $0 } }
        var result = self
        result.name = trimmed(result.name)
        result.host = trimmed(result.host)
        result.user = optional(result.user)
        result.jumpHost = optional(result.jumpHost)
        result.identityFile = optional(result.identityFile)
        result.remoteDirectory = Self.normalizedDirectory(result.remoteDirectory)
        result.phpExecutable = trimmed(result.phpExecutable)
        result.languagePHPVersion = optional(result.languagePHPVersion)
        result.localSourcePath = optional(result.localSourcePath)
        result.container = result.container?.normalized
        return result
    }

    /// A key file path `ssh -i` can take as one argument: absolute or `~/…`, at most 1024
    /// characters, without control characters (#188).
    public static func isValidIdentityFile(_ path: String) -> Bool {
        (path.hasPrefix("/") || path.hasPrefix("~/")) && path.count <= 1024
            && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0 == "\u{2028}" || $0 == "\u{2029}" }
    }

    /// `path` trimmed, without trailing slashes (`/` stays `/`).
    public static func normalizedDirectory(_ path: String) -> String {
        var result = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }

    /// `~` or `~/rest` with `~` replaced by the server's home folder; other paths unchanged.
    public static func expandingTilde(_ path: String, home: String) -> String {
        let trimmed = normalizedDirectory(path)
        guard trimmed == "~" || trimmed.hasPrefix("~/") else { return trimmed }
        let base = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        return normalizedDirectory(base + trimmed.dropFirst())
    }
}

/// Everything a run, Stop, or probe needs to reach an SSH host, captured in the run's
/// `TargetSnapshot`. Arguments are built by `SSHClient` (RunletExecution).
public struct SSHEndpoint: Sendable, Codable, Hashable {
    /// Passed to `ssh` unchanged (an alias from `~/.ssh/config` or a host name).
    public var host: String
    public var user: String?
    public var port: Int?
    public var jumpHost: String?
    /// `ssh -i` (#188): a key file on this Mac; nil leaves keys to `~/.ssh/config` and the agent.
    public var identityFile: String?
    /// The OpenSSH control socket shared by runs, Stop, probes, Connect…, and Disconnect.
    public var controlPath: String
    public var authentication: SSHAuthentication
    /// ControlPersist for a shared connection that a run opens by itself (automatic
    /// authentication): minutes, nil until Disconnect.
    public var keepAliveMinutes: Int?
    public var compression: Bool
    /// Runs on the host's PHP use a private opcode file cache and the runner kept on the
    /// server (`SSHProfile.keepCompiledPHP`, #48).
    public var keepCompiledPHP: Bool?

    public init(host: String, user: String? = nil, port: Int? = nil, jumpHost: String? = nil, identityFile: String? = nil, controlPath: String, authentication: SSHAuthentication = .automatic, keepAliveMinutes: Int? = 10, compression: Bool = true, keepCompiledPHP: Bool? = nil) {
        self.host = host
        self.user = user
        self.port = port
        self.jumpHost = jumpHost
        self.identityFile = identityFile
        self.controlPath = controlPath
        self.authentication = authentication
        self.keepAliveMinutes = keepAliveMinutes
        self.compression = compression
        self.keepCompiledPHP = keepCompiledPHP
    }

    /// "deploy@app-prod" (or the host alone when `~/.ssh/config` picks the user).
    public var displayName: String {
        let base = user.map { "\($0)@\(host)" } ?? host
        return port.map { "\(base):\($0)" } ?? base
    }
}

/// Where OpenSSH control sockets live. macOS limits Unix socket paths to 104 bytes, and
/// OpenSSH binds a temporary name 17 bytes longer before renaming it, so Runlet uses short
/// names (`<first 8 hex of the profile id>.sock`) in a 0700 folder, falling back to the
/// per-user temporary directory when the data folder's path is too long.
public enum SSHControlPaths {
    /// Longest socket path Runlet uses (104 − 1 for the terminator − 17 for OpenSSH's
    /// temporary suffix − a margin).
    public static let maximumLength = 80

    /// The control socket for `profileId` under `directory` (or the fallback folder).
    public static func socketPath(for profileId: UUID, in directory: URL) -> String {
        let name = String(profileId.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased() + ".sock"
        let preferred = directory.appendingPathComponent(name).path
        if preferred.utf8.count <= maximumLength { return preferred }
        return fallbackDirectory.appendingPathComponent(name).path
    }

    /// The per-user temporary directory (`/var/folders/…/T/`, private to this user).
    public static var fallbackDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("runlet-ssh", isDirectory: true)
    }

    /// Creates the socket's folder with mode 0700 (and tightens an existing one).
    public static func prepareDirectory(for socketPath: String) throws {
        let directory = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
    }
}


/// The optional `docker exec` step of an SSH profile: a container on the SSH host, found by
/// its Compose project and service (or its name) like a Docker profile's, and never switched
/// silently. Docker runs on the server through the profile's SSH connection.
public struct RemoteContainerStep: Sendable, Codable, Hashable {
    public var identity: ContainerIdentity
    /// The application's directory inside the container.
    public var workingDirectory: String
    public var phpExecutable: String
    /// `docker exec --user` (e.g. `www-data` or `1000:1000`); nil uses the container's user.
    public var user: String?
    /// Exported as TMPDIR for each run (Runlet itself writes nothing there).
    public var temporaryDirectory: String
    /// How Docker is called on the server: `docker`, an absolute path, or `sudo -n docker`
    /// (passwordless sudo only, since runs can't answer a prompt).
    public var dockerCommand: String

    public init(identity: ContainerIdentity = ContainerIdentity(), workingDirectory: String = "/var/www/html", phpExecutable: String = "php", user: String? = nil, temporaryDirectory: String = "/tmp", dockerCommand: String = "docker") {
        self.identity = identity
        self.workingDirectory = workingDirectory
        self.phpExecutable = phpExecutable
        self.user = user
        self.temporaryDirectory = temporaryDirectory
        self.dockerCommand = dockerCommand
    }

    enum CodingKeys: String, CodingKey { case identity, workingDirectory, phpExecutable, user, temporaryDirectory, dockerCommand }

    /// Tolerates missing keys (only the identity matters).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RemoteContainerStep()
        identity = try c.decodeIfPresent(ContainerIdentity.self, forKey: .identity) ?? d.identity
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory) ?? d.workingDirectory
        phpExecutable = try c.decodeIfPresent(String.self, forKey: .phpExecutable) ?? d.phpExecutable
        user = try c.decodeIfPresent(String.self, forKey: .user)
        temporaryDirectory = try c.decodeIfPresent(String.self, forKey: .temporaryDirectory) ?? d.temporaryDirectory
        dockerCommand = try c.decodeIfPresent(String.self, forKey: .dockerCommand) ?? d.dockerCommand
    }

    /// Whether a container was chosen (Compose service or container name).
    public var hasIdentity: Bool { identity.composeService != nil || identity.containerName != nil }

    /// The Docker command's words (`["sudo", "-n", "docker"]`).
    public var dockerWords: [String] { dockerCommand.split(whereSeparator: \.isWhitespace).map(String.init) }

    /// Trimmed, blank optional fields cleared, trailing slashes dropped.
    public var normalized: RemoteContainerStep {
        func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
        var result = self
        result.workingDirectory = SSHProfile.normalizedDirectory(result.workingDirectory)
        result.phpExecutable = trimmed(result.phpExecutable)
        result.user = result.user.map(trimmed).flatMap { $0.isEmpty ? nil : $0 }
        result.temporaryDirectory = SSHProfile.normalizedDirectory(result.temporaryDirectory)
        result.dockerCommand = result.dockerWords.joined(separator: " ")
        return result
    }

    public func validate() -> [SSHProfile.ValidationError] {
        let step = normalized
        var errors: [SSHProfile.ValidationError] = []
        if !step.hasIdentity { errors.append(.missingContainer) }
        if !step.workingDirectory.hasPrefix("/") { errors.append(.relativeContainerDirectory) }
        if step.phpExecutable.isEmpty || step.phpExecutable.hasPrefix("-") || step.phpExecutable.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            errors.append(.invalidContainerPHP)
        }
        if let user = step.user, user.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]*(:[A-Za-z0-9_][A-Za-z0-9_.-]*)?$"#, options: .regularExpression) == nil {
            errors.append(.invalidContainerUser)
        }
        if !step.temporaryDirectory.hasPrefix("/") { errors.append(.relativeContainerTemporaryDirectory) }
        if !Self.isValidDockerCommand(step.dockerWords) { errors.append(.invalidDockerCommand) }
        return errors
    }

    /// `docker` or `podman`, by name or absolute path, optionally after `sudo -n`.
    static func isValidDockerCommand(_ words: [String]) -> Bool {
        var rest = words[...]
        if rest.first == "sudo" {
            guard rest.count == 3, rest.dropFirst().first == "-n" else { return false }
            rest = rest.dropFirst(2)
        }
        guard rest.count == 1, let program = rest.first else { return false }
        let name = (program as NSString).lastPathComponent
        let safe = program.range(of: #"^[A-Za-z0-9_./+-]+$"#, options: .regularExpression) != nil
        return safe && ["docker", "podman"].contains(name) && (program.hasPrefix("/") || program == name)
    }

    /// "acme-shop/app · /var/www/html".
    public var summary: String { "\(identity.displayName) · \(workingDirectory)" }
}
