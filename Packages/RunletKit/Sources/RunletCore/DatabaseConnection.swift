import Foundation

/// The database driver of a saved connection (#138). DB3 (#140) adds more.
public enum DatabaseDriverKind: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    /// MySQL and MariaDB (`pdo_mysql`).
    case mysql
    /// PostgreSQL (`pdo_pgsql`).
    case pgsql
    /// An SQLite file on the target (`pdo_sqlite`).
    case sqlite

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .mysql: "MySQL / MariaDB"
        case .pgsql: "PostgreSQL"
        case .sqlite: "SQLite file"
        }
    }

    /// The port used when a connection leaves it empty.
    public var defaultPort: Int? {
        switch self {
        case .mysql: 3306
        case .pgsql: 5432
        case .sqlite: nil
        }
    }

    /// MySQL and PostgreSQL connect to a host; SQLite opens a file.
    public var usesHost: Bool { self != .sqlite }

    /// How the database enforces a read-only connection (#139), for the editor and docs.
    public var readOnlyGuard: String {
        switch self {
        case .mysql: "MySQL 5.6.5+ and MariaDB 10.0+ refuse writes and DDL in the session: Runlet sends SET SESSION TRANSACTION READ ONLY right after connecting, and again before each statement."
        case .pgsql: "PostgreSQL refuses writes, DDL, and nextval() in the session: Runlet sets the session's transactions to READ ONLY right after connecting, and again before each statement."
        case .sqlite: "SQLite opens the file read-only (and with PRAGMA query_only), so no statement can write to it."
        }
    }
}

/// A database connection the user saved for one target (#138): its definition, never its
/// password. The password lives only in the macOS Keychain (`CredentialStore`, account = `id`)
/// and reaches PHP only inside the runner request on stdin. Definitions are stored in
/// `targets.json` (`TargetLibrary.databaseConnections`); sessions keep a tab's connection id
/// and name, workspaces only its name.
public struct DatabaseConnection: Sendable, Codable, Hashable, Identifiable {
    public static let defaultConnectTimeout = 10
    public static let connectTimeoutRange = 1...300
    public static let maximumNameLength = 100

    public var id: UUID
    /// Unique within the target; shown in the picker, results, and confirmations.
    public var name: String
    /// The target the connection belongs to.
    public var scope: TargetRef
    public var driver: DatabaseDriverKind
    /// MySQL and PostgreSQL: the host name or IP address, resolved where the connection is made
    /// (this Mac for a local project, inside the container for Docker, on the server for SSH).
    public var host: String
    /// nil: the driver's default port.
    public var port: Int?
    /// The database name; for SQLite, the file on the target (absolute, or relative to the
    /// project directory).
    public var database: String
    public var user: String
    /// Seconds (`PDO::ATTR_TIMEOUT`).
    public var connectTimeout: Int
    /// Read-only (#139): the runner makes the session read-only right after connecting (the
    /// database refuses writes), and Runlet refuses writing and session-changing statements
    /// before sending them (`SQLScript.readOnlyRefusal`).
    public var readOnly: Bool
    /// The connection's own environment (#139; nil: development). A run uses the stricter of
    /// the target's and the connection's (`TargetLibrary.marking(for:connection:)`).
    public var environment: TargetEnvironment?
    /// The connection's colour (#139), shown in the SQL bar and its picker.
    public var color: TargetColor?
    public var revision: Int

    public init(id: UUID = UUID(), name: String, scope: TargetRef, driver: DatabaseDriverKind, host: String = "", port: Int? = nil, database: String = "", user: String = "", connectTimeout: Int = DatabaseConnection.defaultConnectTimeout, readOnly: Bool = false, environment: TargetEnvironment? = nil, color: TargetColor? = nil, revision: Int = 1) {
        self.id = id
        self.name = name
        self.scope = scope
        self.driver = driver
        self.host = host
        self.port = port
        self.database = database
        self.user = user
        self.connectTimeout = connectTimeout
        self.readOnly = readOnly
        self.environment = environment
        self.color = color
        self.revision = revision
    }

    enum CodingKeys: String, CodingKey {
        case id, name, scope, driver, host, port, database, user, connectTimeout, readOnly, environment, color, revision
    }

    /// Fields added later decode with their defaults (connections saved before #139 are
    /// read-write development connections without a colour). An unknown driver (from a newer
    /// Runlet) fails, and `TargetLibrary` leaves that connection out.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        scope = try c.decode(TargetRef.self, forKey: .scope)
        driver = try c.decode(DatabaseDriverKind.self, forKey: .driver)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        database = try c.decodeIfPresent(String.self, forKey: .database) ?? ""
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        connectTimeout = (try? c.decodeIfPresent(Int.self, forKey: .connectTimeout)) ?? Self.defaultConnectTimeout
        readOnly = (try? c.decodeIfPresent(Bool.self, forKey: .readOnly)) ?? false
        environment = try? c.decodeIfPresent(TargetEnvironment.self, forKey: .environment)
        color = try? c.decodeIfPresent(TargetColor.self, forKey: .color)
        revision = (try? c.decodeIfPresent(Int.self, forKey: .revision)) ?? 1
    }

    /// Leaves out what is at its default (read-write, development, no colour), so files stay
    /// as they were for connections that don't use them.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(scope, forKey: .scope)
        try c.encode(driver, forKey: .driver)
        try c.encode(host, forKey: .host)
        try c.encodeIfPresent(port, forKey: .port)
        try c.encode(database, forKey: .database)
        try c.encode(user, forKey: .user)
        try c.encode(connectTimeout, forKey: .connectTimeout)
        if readOnly { try c.encode(true, forKey: .readOnly) }
        if let environment, environment != .development { try c.encode(environment, forKey: .environment) }
        try c.encodeIfPresent(color, forKey: .color)
        try c.encode(revision, forKey: .revision)
    }

    /// The connection's environment (nil reads as development).
    public var environmentMarking: TargetEnvironment { environment ?? .development }

    /// The port the runner uses: the connection's, else the driver's default.
    public var effectivePort: Int? {
        driver.usesHost ? (port ?? driver.defaultPort) : nil
    }

    /// Where it connects, without the user or password: "db.internal:5432/reports",
    /// "127.0.0.1:3306", or the SQLite file.
    public var location: String {
        guard driver.usesHost else { return database }
        let address = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(address):\(effectivePort.map(String.init) ?? "")" + (database.isEmpty ? "" : "/\(database)")
    }

    /// "pgsql, db.internal:5432/reports": the driver and where it connects, never a password.
    public var summary: String { "\(driver.rawValue), \(location)" }

    /// Trimmed for saving: SQLite keeps no host or port; a default port is stored as nil.
    public var normalized: DatabaseConnection {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.database = database.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        if !driver.usesHost {
            copy.host = ""
            copy.port = nil
        } else if copy.port == driver.defaultPort {
            copy.port = nil
        }
        if copy.environment == .development { copy.environment = nil }
        return copy
    }

    /// A copy for Duplicate: a new id and name, the same definition, and no password (the
    /// Keychain item belongs to the original).
    public func duplicated(named name: String? = nil, scope: TargetRef? = nil) -> DatabaseConnection {
        var copy = self
        copy.id = UUID()
        copy.name = name ?? self.name + " copy"
        copy.scope = scope ?? self.scope
        copy.revision = 1
        return copy
    }

    public enum ValidationError: Error, Sendable, Equatable, CustomStringConvertible {
        case emptyName, longName, invalidName, duplicateName
        case emptyHost, invalidHost, invalidPort
        case invalidDatabase, emptyPath, invalidUser, invalidTimeout
        case unsupportedTarget

        public var description: String {
            switch self {
            case .emptyName: "Give the connection a name."
            case .longName: "Use a name of at most \(DatabaseConnection.maximumNameLength) characters."
            case .invalidName: "The name can't contain line breaks or control characters."
            case .duplicateName: "This target already has a connection with this name."
            case .emptyHost: "Enter the database server's host name or IP address."
            case .invalidHost: "The host may contain only letters, digits, '.', '-', '_', and ':' (an IPv6 address)."
            case .invalidPort: "The port must be a number from 1 to 65535."
            case .invalidDatabase: "The database name can't contain ';', quotes, line breaks, or control characters."
            case .emptyPath: "Enter the SQLite file's path on the target (absolute, or relative to the project directory)."
            case .invalidUser: "The user name can't contain line breaks or control characters."
            case .invalidTimeout: "The connect timeout must be \(DatabaseConnection.connectTimeoutRange.lowerBound)–\(DatabaseConnection.connectTimeoutRange.upperBound) seconds."
            case .unsupportedTarget: "The Laravel sandbox can't have saved connections yet."
            }
        }
    }

    /// Checks the (normalized) definition: what the runner puts in a PDO DSN must not be able
    /// to add DSN options, so hosts and database names are restricted. `others` are the
    /// target's other connections (for unique names).
    public func validate(others: [DatabaseConnection] = []) -> [ValidationError] {
        let value = normalized
        var errors: [ValidationError] = []
        if scope == .sandbox { errors.append(.unsupportedTarget) }
        if value.name.isEmpty {
            errors.append(.emptyName)
        } else if value.name.count > Self.maximumNameLength {
            errors.append(.longName)
        } else if Self.hasControlCharacters(value.name) {
            errors.append(.invalidName)
        } else if others.contains(where: { $0.id != id && $0.scope == scope && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(value.name) == .orderedSame }) {
            errors.append(.duplicateName)
        }
        if driver.usesHost {
            if value.host.isEmpty {
                errors.append(.emptyHost)
            } else if value.host.count > 255 || value.host.hasPrefix("-") || value.host.range(of: #"^[A-Za-z0-9._:%\[\]-]+$"#, options: .regularExpression) == nil {
                errors.append(.invalidHost)
            }
            if let port, !(1...65535).contains(port) { errors.append(.invalidPort) }
            if value.database.count > 255 || value.database.range(of: #"[;'"\\]"#, options: .regularExpression) != nil || Self.hasControlCharacters(value.database) {
                errors.append(.invalidDatabase)
            }
        } else {
            if value.database.isEmpty {
                errors.append(.emptyPath)
            } else if value.database.count > 4096 || Self.hasControlCharacters(value.database) {
                errors.append(.invalidDatabase)
            }
        }
        if value.user.count > 255 || Self.hasControlCharacters(value.user) { errors.append(.invalidUser) }
        if !Self.connectTimeoutRange.contains(connectTimeout) { errors.append(.invalidTimeout) }
        return errors
    }

    static func hasControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0 == "\u{2028}" || $0 == "\u{2029}" }
    }
}

/// How a run is marked (#139): the stricter of its target's environment and its saved
/// connection's, so a production connection on a development target asks before every SQL
/// action, and the colour that goes with it.
public struct EnvironmentMarking: Sendable, Equatable {
    public var environment: TargetEnvironment
    public var color: TargetColor?
    /// The saved connection's marking is stricter than the target's: confirmations name the
    /// connection as the reason.
    public var fromConnection: Bool

    public init(environment: TargetEnvironment, color: TargetColor? = nil, fromConnection: Bool = false) {
        self.environment = environment
        self.color = color
        self.fromConnection = fromConnection
    }

    public init(target: TargetEnvironment, targetColor: TargetColor?, connection: DatabaseConnection?) {
        let own = connection?.environmentMarking ?? .development
        environment = TargetEnvironment.stricter(target, own)
        fromConnection = own.strictness > target.strictness
        color = connection?.color ?? targetColor
    }

    public var isProduction: Bool { environment == .production }
}

/// Which connection an SQL tab uses (#138): one the application configures (by name; nil is
/// its default connection) or one the user saved for the target. Schema caches key on it.
public enum SQLConnectionRef: Sendable, Hashable {
    case app(String?)
    case saved(UUID)

    /// `app:<name>` / `saved:<uuid>`.
    public var key: String {
        switch self {
        case .app(let name): "app:" + (name ?? "")
        case .saved(let id): "saved:" + id.uuidString
        }
    }

    public var isSaved: Bool {
        if case .saved = self { return true }
        return false
    }

    /// The application connection's name (nil for a saved connection or the default).
    public var appName: String? {
        if case .app(let name) = self { return name }
        return nil
    }
}

extension TargetLibrary {
    /// Whether `target` can have saved database connections: local projects, Docker profiles,
    /// and SSH profiles (the sandbox not yet, #142).
    public static func supportsDatabaseConnections(_ target: TargetRef) -> Bool {
        target != .sandbox
    }

    /// The target's saved connections, by name.
    public func databaseConnections(for target: TargetRef) -> [DatabaseConnection] {
        databaseConnections.filter { $0.scope == target }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func databaseConnection(_ id: UUID) -> DatabaseConnection? {
        databaseConnections.first { $0.id == id }
    }

    /// How a run on `target` is marked (#139): with a saved connection, the stricter of the
    /// target's environment and the connection's, and the connection's colour when it has one.
    public func marking(for target: TargetRef, connection: DatabaseConnection? = nil) -> EnvironmentMarking {
        EnvironmentMarking(target: environment(for: target), targetColor: color(for: target), connection: connection)
    }

    /// A tab's saved connection: by id when it still belongs to `target`, else the target's
    /// connection with that name (a workspace, or a tab moved to another target).
    public func databaseConnection(id: UUID?, name: String?, on target: TargetRef) -> DatabaseConnection? {
        if let id, let found = databaseConnection(id), found.scope == target { return found }
        guard let name, !name.isEmpty else { return nil }
        return databaseConnections.first { $0.scope == target && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Adds or replaces a connection (a replaced one gets the next revision). Returns it as saved.
    @discardableResult
    public mutating func saveDatabaseConnection(_ connection: DatabaseConnection) -> DatabaseConnection {
        var saved = connection.normalized
        if let index = databaseConnections.firstIndex(where: { $0.id == connection.id }) {
            saved.revision = databaseConnections[index].revision + 1
            databaseConnections[index] = saved
        } else {
            databaseConnections.append(saved)
        }
        return saved
    }

    /// Removes one connection; returns it (its Keychain item is the caller's to delete).
    @discardableResult
    public mutating func removeDatabaseConnection(_ id: UUID) -> DatabaseConnection? {
        guard let index = databaseConnections.firstIndex(where: { $0.id == id }) else { return nil }
        return databaseConnections.remove(at: index)
    }

    /// Removes every connection of a target that is being removed; returns them so their
    /// Keychain items can be deleted.
    @discardableResult
    public mutating func removeDatabaseConnections(for target: TargetRef) -> [DatabaseConnection] {
        let removed = databaseConnections.filter { $0.scope == target }
        databaseConnections.removeAll { $0.scope == target }
        return removed
    }
}

/// Decodes a list, leaving out elements that fail (a saved connection from a newer Runlet).
struct LossyList<Element: Decodable>: Decodable {
    var elements: [Element]

    /// Accepts any value, so the container moves past an element that didn't decode.
    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else if (try? container.decode(Skip.self)) == nil {
                break
            }
        }
        self.elements = elements
    }
}
