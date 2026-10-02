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
/// user's terminal. A remote `docker exec` step (SSH-6) will be an optional field here.
public struct SSHProfile: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// A `~/.ssh/config` alias or a host name, passed to `ssh` unchanged.
    public var host: String
    /// Overrides for the login user, port, and jump host; nil uses what `~/.ssh/config` says.
    public var user: String?
    public var port: Int?
    public var jumpHost: String?
    /// Absolute directory of the application on the server. It may be a symlink (Forge's
    /// `…/current`); the real path PHP reports is mapped too.
    public var remoteDirectory: String
    /// The server's PHP: `php`, a name such as `php8.3`, or an absolute path.
    public var phpExecutable: String
    public var authentication: SSHAuthentication
    /// Minutes an automatically opened shared connection stays open after its last use; nil
    /// keeps it until Disconnect. Connect… logins always stay until Disconnect.
    public var keepAliveMinutes: Int?
    /// `ssh -C`: the runner (about 830 KB per run) compresses several times over.
    public var compression: Bool
    /// The project's checkout on this Mac: completion, file links, snippets, host commands,
    /// facts, and the terminal use it. nil runs in limited mode.
    public var localSourcePath: String?
    /// Language-service PHP target (e.g. "8.3"); nil infers it from the local composer.json.
    public var languagePHPVersion: String?
    /// Per-profile `declare(strict_types=1)` override; nil inherits `AppSettings.strictTypes`.
    public var strictTypes: Bool?
    public var environment: TargetEnvironment
    public var color: TargetColor?
    /// Compare the server's checkout (branch and commit, or `composer.lock`) with the local
    /// folder after Test Connection. Off by default: it reads files on the server.
    public var checkDrift: Bool
    public var revision: Int
    public var lastOpenedAt: Date?

    public init(id: UUID = UUID(), name: String, host: String, user: String? = nil, port: Int? = nil, jumpHost: String? = nil, remoteDirectory: String, phpExecutable: String = "php", authentication: SSHAuthentication = .automatic, keepAliveMinutes: Int? = 10, compression: Bool = true, localSourcePath: String? = nil, languagePHPVersion: String? = nil, strictTypes: Bool? = nil, environment: TargetEnvironment = .development, color: TargetColor? = nil, checkDrift: Bool = false, revision: Int = 1, lastOpenedAt: Date? = nil) {
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
        self.revision = revision
        self.lastOpenedAt = lastOpenedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, host, user, port, jumpHost, remoteDirectory, phpExecutable, authentication, keepAliveMinutes, compression
        case localSourcePath, languagePHPVersion, strictTypes, environment, color, checkDrift, revision, lastOpenedAt
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
        remoteDirectory = try c.decode(String.self, forKey: .remoteDirectory)
        phpExecutable = try c.decodeIfPresent(String.self, forKey: .phpExecutable) ?? d.phpExecutable
        authentication = try c.decodeIfPresent(SSHAuthentication.self, forKey: .authentication) ?? d.authentication
        keepAliveMinutes = c.contains(.keepAliveMinutes) ? try c.decodeIfPresent(Int.self, forKey: .keepAliveMinutes) : d.keepAliveMinutes
        compression = try c.decodeIfPresent(Bool.self, forKey: .compression) ?? d.compression
        localSourcePath = try c.decodeIfPresent(String.self, forKey: .localSourcePath)
        languagePHPVersion = try c.decodeIfPresent(String.self, forKey: .languagePHPVersion)
        strictTypes = try c.decodeIfPresent(Bool.self, forKey: .strictTypes)
        environment = try c.decodeIfPresent(TargetEnvironment.self, forKey: .environment) ?? d.environment
        color = try c.decodeIfPresent(TargetColor.self, forKey: .color)
        checkDrift = try c.decodeIfPresent(Bool.self, forKey: .checkDrift) ?? d.checkDrift
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
        try c.encode(remoteDirectory, forKey: .remoteDirectory)
        try c.encode(phpExecutable, forKey: .phpExecutable)
        try c.encode(authentication, forKey: .authentication)
        // Written as null when the connection stays until Disconnect (missing means the default).
        try c.encode(keepAliveMinutes, forKey: .keepAliveMinutes)
        try c.encode(compression, forKey: .compression)
        try c.encodeIfPresent(localSourcePath, forKey: .localSourcePath)
        try c.encodeIfPresent(languagePHPVersion, forKey: .languagePHPVersion)
        try c.encodeIfPresent(strictTypes, forKey: .strictTypes)
        try c.encode(environment, forKey: .environment)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encode(checkDrift, forKey: .checkDrift)
        try c.encode(revision, forKey: .revision)
        try c.encodeIfPresent(lastOpenedAt, forKey: .lastOpenedAt)
    }

    /// "deploy@app-prod", or just the host when the user comes from `~/.ssh/config`.
    public var destinationLabel: String {
        let base = user.map { "\($0)@\(host)" } ?? host
        return port.map { "\(base):\($0)" } ?? base
    }

    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case emptyName, invalidHost, invalidUser, invalidPort, invalidJumpHost, relativeRemoteDirectory, invalidPHP, invalidKeepAlive

        public var description: String {
            switch self {
            case .emptyName: "Give the profile a name."
            case .invalidHost: "Enter a host name or `~/.ssh/config` alias (no spaces, not starting with `-`)."
            case .invalidUser: "The user may contain only letters, digits, '_', '-', and '.'."
            case .invalidPort: "The port must be a number from 1 to 65535."
            case .invalidJumpHost: "The jump host may not contain spaces or start with `-`."
            case .relativeRemoteDirectory: "The remote directory must be an absolute path (starting with `/`)."
            case .invalidPHP: "Set the server's PHP executable (usually `php`); it can't start with `-`."
            case .invalidKeepAlive: "Keep the connection open for 1 to 1440 minutes, or until Disconnect."
            }
        }
    }

    /// Validates the fields that end up in `ssh` arguments or the remote command line.
    public func validate() -> [ValidationError] {
        var errors: [ValidationError] = []
        func plainWord(_ value: String) -> Bool {
            !value.isEmpty && !value.hasPrefix("-") && value.unicodeScalars.allSatisfy { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }
        }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { errors.append(.emptyName) }
        if !plainWord(host) { errors.append(.invalidHost) }
        if let user, !user.isEmpty, user.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]*$"#, options: .regularExpression) == nil {
            errors.append(.invalidUser)
        }
        if let port, !(1...65535).contains(port) { errors.append(.invalidPort) }
        if let jumpHost, !jumpHost.isEmpty, !plainWord(jumpHost) { errors.append(.invalidJumpHost) }
        if !remoteDirectory.hasPrefix("/") || remoteDirectory.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            errors.append(.relativeRemoteDirectory)
        }
        if phpExecutable.trimmingCharacters(in: .whitespaces).isEmpty || phpExecutable.hasPrefix("-") || phpExecutable.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            errors.append(.invalidPHP)
        }
        if let keepAliveMinutes, !(1...1440).contains(keepAliveMinutes) { errors.append(.invalidKeepAlive) }
        return errors
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
    /// The OpenSSH control socket shared by runs, Stop, probes, Connect…, and Disconnect.
    public var controlPath: String
    public var authentication: SSHAuthentication
    /// ControlPersist for a shared connection that a run opens by itself (automatic
    /// authentication): minutes, nil until Disconnect.
    public var keepAliveMinutes: Int?
    public var compression: Bool

    public init(host: String, user: String? = nil, port: Int? = nil, jumpHost: String? = nil, controlPath: String, authentication: SSHAuthentication = .automatic, keepAliveMinutes: Int? = 10, compression: Bool = true) {
        self.host = host
        self.user = user
        self.port = port
        self.jumpHost = jumpHost
        self.controlPath = controlPath
        self.authentication = authentication
        self.keepAliveMinutes = keepAliveMinutes
        self.compression = compression
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
