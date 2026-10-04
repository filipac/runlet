import Foundation

/// The database driver of a saved connection (#138; SQL Server and custom DSNs, #140).
public enum DatabaseDriverKind: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    /// MySQL and MariaDB (`pdo_mysql`).
    case mysql
    /// PostgreSQL (`pdo_pgsql`).
    case pgsql
    /// An SQLite file on the target (`pdo_sqlite`).
    case sqlite
    /// Microsoft SQL Server (#140): `pdo_sqlsrv`, else `pdo_dblib` (FreeTDS), in the target's
    /// PHP. Runlet's own PHP has neither.
    case sqlsrv
    /// A PDO DSN the user types (#140), for drivers Runlet doesn't model (`oci:`, `odbc:`,
    /// `firebird:`, …). Runlet doesn't parse it; it can't hold a password.
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .mysql: "MySQL / MariaDB"
        case .pgsql: "PostgreSQL"
        case .sqlite: "SQLite file"
        case .sqlsrv: "SQL Server"
        case .custom: "Custom PDO DSN"
        }
    }

    /// The port used when a connection leaves it empty.
    public var defaultPort: Int? {
        switch self {
        case .mysql: 3306
        case .pgsql: 5432
        case .sqlsrv: 1433
        case .sqlite, .custom: nil
        }
    }

    /// MySQL, PostgreSQL, and SQL Server connect to a host; SQLite opens a file; a custom
    /// DSN says where itself.
    public var usesHost: Bool { self == .mysql || self == .pgsql || self == .sqlsrv }

    /// How the database enforces a read-only connection (#139), for the editor and docs.
    public var readOnlyGuard: String {
        switch self {
        case .mysql: "MySQL 5.6.5+ and MariaDB 10.0+ refuse writes and DDL in the session: Runlet sends SET SESSION TRANSACTION READ ONLY right after connecting, and again before each statement."
        case .pgsql: "PostgreSQL refuses writes, DDL, and nextval() in the session: Runlet sets the session's transactions to READ ONLY right after connecting, and again before each statement."
        case .sqlite: "SQLite opens the file read-only (and with PRAGMA query_only), so no statement can write to it."
        case .sqlsrv: "SQL Server has no read-only session Runlet can enforce. Connect as a user with only read permissions (db_datareader) instead."
        case .custom: "Runlet can't make a custom DSN's session read-only. Connect as a database user that can only read instead."
        }
    }
}

/// Where a saved connection is opened (#142): by the target's own PHP (local PHP, `docker
/// exec`, SSH; #138), or by a PHP process on this Mac (Runlet's PHP, else the default PHP from
/// Settings) in an empty folder of Runlet's, with no project code. From this Mac, host names,
/// sockets, SQLite files, and TLS files are this Mac's.
///
/// #143: or from this Mac through an SSH profile's tunnel: Runlet adds a local forward
/// (`127.0.0.1:<free port>` to the connection's host and port, as the SSH server sees them) on
/// that profile's shared connection, and this Mac's PHP connects to the forward. TLS files are
/// still this Mac's; the host and port are the server's.
public enum DatabaseConnectFrom: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case target
    case thisMac = "mac"
    case sshTunnel

    public var id: String { rawValue }
}

/// A database connection the user saved for one target (#138), or for all targets (#142): its
/// definition, never its password. The password lives only in the macOS Keychain (`CredentialStore`, account = `id`)
/// and reaches PHP only inside the runner request on stdin. Definitions are stored in
/// `targets.json` (`TargetLibrary.databaseConnections`); sessions keep a tab's connection id
/// and name, workspaces only its name.
public struct DatabaseConnection: Sendable, Codable, Hashable, Identifiable {
    public static let defaultConnectTimeout = 10
    public static let connectTimeoutRange = 1...300
    public static let maximumNameLength = 100

    public var id: UUID
    /// Unique within the target (or among all-targets connections); shown in the picker,
    /// results, and confirmations.
    public var name: String
    /// The target the connection belongs to; nil for a connection of all targets (#142), which
    /// every SQL tab's picker offers, the sandbox's too, and which always opens from this Mac.
    public var scope: TargetRef?
    /// Where the connection is opened (#142): the target's PHP (the default), or this Mac's.
    /// All-targets connections always open from this Mac (`opensOnThisMac`), directly or
    /// through an SSH tunnel (#143).
    public var connectFrom: DatabaseConnectFrom
    /// #143: the SSH profile whose shared connection carries the tunnel, when `connectFrom` is
    /// `sshTunnel`. A removed profile leaves the id behind: the connection says its profile is
    /// missing and never uses another one by itself.
    public var sshProfile: UUID?
    public var driver: DatabaseDriverKind
    /// MySQL and PostgreSQL: the host name or IP address, resolved where the connection is made
    /// (this Mac for a local project or a connection opened from this Mac, inside the container
    /// for Docker, on the server for SSH).
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
    /// MySQL and PostgreSQL (#140): a Unix socket on the target instead of the host (MySQL:
    /// the socket file; PostgreSQL: its directory, and the port names the socket file).
    public var socket: String?
    /// MySQL `charset=` (nil: utf8mb4) or PostgreSQL `client_encoding` (nil: the server's) (#140).
    public var charset: String?
    /// TLS (#140); nil: the driver's default (MySQL: none; PostgreSQL: prefer; SQL Server: its
    /// ODBC driver's).
    public var tls: DatabaseTLS?
    /// Statements run after connecting, before the user's (#140): `SET search_path TO reports`.
    /// On a read-only connection only reads and session settings that keep it read-only.
    public var initStatements: [String]
    /// Extra DSN options (#140), PostgreSQL and SQL Server.
    public var options: [DatabaseOption]
    /// The PDO DSN of a custom connection (#140), without a password.
    public var dsn: String?
    public var revision: Int

    public init(id: UUID = UUID(), name: String, scope: TargetRef?, connectFrom: DatabaseConnectFrom = .target, driver: DatabaseDriverKind, host: String = "", port: Int? = nil, database: String = "", user: String = "", connectTimeout: Int = DatabaseConnection.defaultConnectTimeout, readOnly: Bool = false, environment: TargetEnvironment? = nil, color: TargetColor? = nil, socket: String? = nil, charset: String? = nil, tls: DatabaseTLS? = nil, initStatements: [String] = [], options: [DatabaseOption] = [], dsn: String? = nil, sshProfile: UUID? = nil, revision: Int = 1) {
        self.id = id
        self.name = name
        self.scope = scope
        self.connectFrom = connectFrom
        self.driver = driver
        self.host = host
        self.port = port
        self.database = database
        self.user = user
        self.connectTimeout = connectTimeout
        self.readOnly = readOnly
        self.environment = environment
        self.color = color
        self.socket = socket
        self.charset = charset
        self.tls = tls
        self.initStatements = initStatements
        self.options = options
        self.dsn = dsn
        self.sshProfile = sshProfile
        self.revision = revision
    }

    enum CodingKeys: String, CodingKey {
        case id, name, scope, driver, host, port, database, user, connectTimeout, readOnly, environment, color
        case socket, charset, tls, initStatements, options, dsn, revision
        case allTargets, connectFrom, sshProfile
    }

    /// Fields added later decode with their defaults (connections saved before #139 are
    /// read-write development connections without a colour; before #140, without options).
    /// An unknown driver or TLS setting (from a newer Runlet) fails, and `TargetLibrary`
    /// leaves that connection out. An all-targets connection (#142) has `"allTargets": true`
    /// and no `scope`, so a Runlet before #142 leaves it out too; one opened from this Mac has
    /// `"connectFrom": "mac"` (an unknown place fails rather than opening it elsewhere). One
    /// opened through an SSH tunnel (#143) has `"connectFrom": "sshTunnel"` and `"sshProfile"`,
    /// so a Runlet before #143 leaves it out rather than connecting directly.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        if (try? c.decodeIfPresent(Bool.self, forKey: .allTargets)) == true {
            scope = nil
        } else {
            scope = try c.decode(TargetRef.self, forKey: .scope)
        }
        connectFrom = try c.decodeIfPresent(DatabaseConnectFrom.self, forKey: .connectFrom) ?? .target
        sshProfile = try? c.decodeIfPresent(UUID.self, forKey: .sshProfile)
        driver = try c.decode(DatabaseDriverKind.self, forKey: .driver)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        database = try c.decodeIfPresent(String.self, forKey: .database) ?? ""
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        connectTimeout = (try? c.decodeIfPresent(Int.self, forKey: .connectTimeout)) ?? Self.defaultConnectTimeout
        readOnly = (try? c.decodeIfPresent(Bool.self, forKey: .readOnly)) ?? false
        environment = try? c.decodeIfPresent(TargetEnvironment.self, forKey: .environment)
        color = try? c.decodeIfPresent(TargetColor.self, forKey: .color)
        socket = try? c.decodeIfPresent(String.self, forKey: .socket)
        charset = try? c.decodeIfPresent(String.self, forKey: .charset)
        // A TLS setting this Runlet can't read (a mode from a newer one) leaves the connection
        // out rather than connecting with less TLS than it asks for.
        tls = try c.decodeIfPresent(DatabaseTLS.self, forKey: .tls)
        initStatements = (try? c.decodeIfPresent([String].self, forKey: .initStatements)) ?? []
        options = (try? c.decodeIfPresent([DatabaseOption].self, forKey: .options)) ?? []
        dsn = try? c.decodeIfPresent(String.self, forKey: .dsn)
        revision = (try? c.decodeIfPresent(Int.self, forKey: .revision)) ?? 1
    }

    /// Leaves out what is at its default (read-write, development, no colour, no options), so
    /// files stay as they were for connections that don't use them.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        if let scope {
            try c.encode(scope, forKey: .scope)
        } else {
            try c.encode(true, forKey: .allTargets)
        }
        if usesSSHTunnel {
            try c.encode(DatabaseConnectFrom.sshTunnel, forKey: .connectFrom)
            try c.encodeIfPresent(sshProfile, forKey: .sshProfile)
        } else if opensOnThisMac {
            try c.encode(DatabaseConnectFrom.thisMac, forKey: .connectFrom)
        }
        try c.encode(driver, forKey: .driver)
        try c.encode(host, forKey: .host)
        try c.encodeIfPresent(port, forKey: .port)
        try c.encode(database, forKey: .database)
        try c.encode(user, forKey: .user)
        try c.encode(connectTimeout, forKey: .connectTimeout)
        if readOnly { try c.encode(true, forKey: .readOnly) }
        if let environment, environment != .development { try c.encode(environment, forKey: .environment) }
        try c.encodeIfPresent(color, forKey: .color)
        try c.encodeIfPresent(socket, forKey: .socket)
        try c.encodeIfPresent(charset, forKey: .charset)
        try c.encodeIfPresent(tls, forKey: .tls)
        if !initStatements.isEmpty { try c.encode(initStatements, forKey: .initStatements) }
        if !options.isEmpty { try c.encode(options, forKey: .options) }
        try c.encodeIfPresent(dsn, forKey: .dsn)
        try c.encode(revision, forKey: .revision)
    }

    /// The connection's environment (nil reads as development).
    public var environmentMarking: TargetEnvironment { environment ?? .development }

    /// A connection of all targets (#142), offered in every SQL tab's picker.
    public var isAllTargets: Bool { scope == nil }

    /// Whether a PHP process on this Mac opens it (#142): connections of all targets always,
    /// a target's when its Connect From says this Mac, directly or through an SSH tunnel (#143).
    public var opensOnThisMac: Bool { scope == nil || connectFrom != .target }

    /// #143: this Mac's PHP opens it through a local forward on an SSH profile's shared
    /// connection (`sshProfile`); the host and port are as that server sees them.
    public var usesSSHTunnel: Bool { connectFrom == .sshTunnel }

    /// Whether it can be used from an SQL tab on `target`: its own target's, or all targets'.
    public func isAvailable(on target: TargetRef) -> Bool { scope == nil || scope == target }

    /// The port the runner uses: the connection's, else the driver's default.
    public var effectivePort: Int? {
        driver.usesHost ? (port ?? driver.defaultPort) : nil
    }

    /// Where it connects, without the user or password: "db.internal:5432/reports",
    /// "127.0.0.1:3306", or the SQLite file.
    public var location: String {
        switch driver {
        case .custom:
            let text = dsn ?? ""
            return text.count > 80 ? String(text.prefix(79)) + "…" : text
        case .sqlite:
            return database
        default:
            if let socket, !socket.isEmpty {
                return "socket \(socket)" + (database.isEmpty ? "" : ", database \(database)")
            }
            let address = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
            return "\(address):\(effectivePort.map(String.init) ?? "")" + (database.isEmpty ? "" : "/\(database)")
        }
    }

    /// Whether it connects through a Unix socket (#140).
    public var usesSocket: Bool { driver.supportsSocket && !(socket ?? "").isEmpty }

    /// "pgsql, db.internal:5432/reports": the driver and where it connects, never a password.
    public var summary: String { "\(driver.rawValue), \(location)" }

    /// Trimmed for saving: SQLite keeps no host or port; a default port is stored as nil;
    /// options the driver doesn't have are dropped (#140): a socket replaces the host (and
    /// MySQL's port), TLS files go with TLS off, empty init statements and options go, and
    /// only a custom connection keeps a DSN.
    public var normalized: DatabaseConnection {
        var copy = self
        func trimmed(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.database = database.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.socket = driver.supportsSocket ? trimmed(socket) : nil
        copy.charset = driver.supportsCharset ? trimmed(charset) : nil
        copy.tls = driver.tlsModes.isEmpty ? nil : tls?.normalized(for: driver)
        // #142: all-targets connections open from this Mac, where `~` names the home folder
        // (PHP doesn't expand it, so Runlet does for this Mac's paths); directly, or through an
        // SSH tunnel (#143).
        if scope == nil, connectFrom == .target { copy.connectFrom = .thisMac }
        // #143: only a tunnel keeps its SSH profile, and it forwards a host and port, never a socket.
        if copy.connectFrom == .sshTunnel {
            copy.socket = nil
        } else {
            copy.sshProfile = nil
        }
        if copy.opensOnThisMac {
            func expanded(_ path: String?) -> String? {
                guard let path, path == "~" || path.hasPrefix("~/") else { return path }
                return (path as NSString).expandingTildeInPath
            }
            if driver == .sqlite, let path = expanded(copy.database) { copy.database = path }
            copy.socket = expanded(copy.socket)
            if var files = copy.tls {
                files.caFile = expanded(files.caFile)
                files.certificateFile = expanded(files.certificateFile)
                files.keyFile = expanded(files.keyFile)
                copy.tls = files
            }
        }
        copy.dsn = driver == .custom ? trimmed(dsn) : nil
        copy.initStatements = initStatements.compactMap { statement in
            var text = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            while text.hasSuffix(";") { text = String(text.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
            return text.isEmpty ? nil : text
        }
        copy.options = driver.supportsOptions
            ? options.map { DatabaseOption(key: $0.key.trimmingCharacters(in: .whitespacesAndNewlines), value: $0.value.trimmingCharacters(in: .whitespacesAndNewlines)) }.filter { !$0.key.isEmpty || !$0.value.isEmpty }
            : []
        if !driver.usesHost {
            copy.host = ""
            copy.port = nil
        } else if copy.socket != nil {
            copy.host = ""
            if driver != .pgsql { copy.port = nil }
        }
        if copy.port == driver.defaultPort { copy.port = nil }
        if driver == .custom { copy.database = "" }
        if copy.environment == .development { copy.environment = nil }
        return copy
    }

    /// A copy for Duplicate: a new id and name, the same definition, and no password (the
    /// Keychain item belongs to the original).
    public func duplicated(named name: String? = nil, scope: TargetRef? = nil) -> DatabaseConnection {
        var copy = self
        copy.id = UUID()
        copy.name = name ?? self.name + " copy"
        if let scope {
            // A copy keeps opening where the original did (#142), through the same tunnel (#143).
            if opensOnThisMac, !usesSSHTunnel { copy.connectFrom = .thisMac }
            copy.scope = scope
        }
        copy.revision = 1
        return copy
    }

    public static let maximumOptions = 30
    public static let maximumInitStatementLength = 4000

    public enum ValidationError: Error, Sendable, Equatable, CustomStringConvertible {
        case emptyName, longName, invalidName, duplicateName
        case emptyHost, invalidHost, invalidPort
        case invalidDatabase, emptyPath, invalidUser, invalidTimeout
        case unsupportedTarget
        // #140
        case emptySocket, invalidSocket, invalidCharset
        case unsupportedTLSMode(DatabaseDriverKind, DatabaseTLSMode)
        case invalidTLSFile(String)
        case certificateWithoutKey
        case tooManyInitStatements, longInitStatement(Int)
        case refusedInitStatement(Int, String)
        case tooManyOptions, invalidOptionKey(String), passwordOption(String), managedOption(String), invalidOptionValue(String)
        case emptyDSN, invalidDSN(String), passwordInDSN
        case readOnlyUnsupported(DatabaseDriverKind)
        // #142
        case relativePathOnThisMac, duplicateNameAllTargets
        // #143
        case tunnelNeedsHost(DatabaseDriverKind), tunnelWithoutProfile, tunnelOption(String)

        public var description: String {
            switch self {
            case .emptyName: "Give the connection a name."
            case .longName: "Use a name of at most \(DatabaseConnection.maximumNameLength) characters."
            case .invalidName: "The name can't contain line breaks or control characters."
            case .duplicateName: "This target already has a connection with this name."
            case .duplicateNameAllTargets: "Another connection for all targets has this name."
            case .emptyHost: "Enter the database server's host name or IP address."
            case .invalidHost: "The host may contain only letters, digits, '.', '-', '_', and ':' (an IPv6 address)."
            case .invalidPort: "The port must be a number from 1 to 65535."
            case .invalidDatabase: "The database name can't contain ';', quotes, line breaks, or control characters."
            case .emptyPath: "Enter the SQLite file's path on the target (absolute, or relative to the project directory)."
            case .invalidUser: "The user name can't contain line breaks or control characters."
            case .invalidTimeout: "The connect timeout must be \(DatabaseConnection.connectTimeoutRange.lowerBound)–\(DatabaseConnection.connectTimeoutRange.upperBound) seconds."
            case .unsupportedTarget: "The Laravel sandbox can't have saved connections yet."
            case .emptySocket: "Enter the Unix socket's path on the target, or connect through a host."
            case .invalidSocket: "The socket must be an absolute path on the target, without ';', quotes, backslashes, or control characters."
            case .invalidCharset: "The charset must be a character set name, such as utf8mb4 or UTF8."
            case .unsupportedTLSMode(let driver, let mode):
                switch driver {
                case .mysql: "MySQL's PDO driver can't express TLS “\(mode.displayName)”: it either requires TLS or doesn't use it, and it checks the host name whenever it checks the certificate. Choose Off, Require, or Verify CA and host name."
                case .sqlsrv: "SQL Server's driver can't express TLS “\(mode.displayName)”. Choose Off, Require, or Verify CA and host name."
                default: "The \(driver.displayName) driver has no TLS setting."
                }
            case .invalidTLSFile(let what): "The \(what) must be an absolute path on the target, without ';', quotes, backslashes, or control characters."
            case .certificateWithoutKey: "Give both the client certificate and its key, or neither."
            case .tooManyInitStatements: "Use at most \(SQLScript.maximumInitStatements) init statements."
            case .longInitStatement(let index): "Init statement \(index) is longer than \(DatabaseConnection.maximumInitStatementLength) characters."
            case .refusedInitStatement(let index, let why): "Init statement \(index) \(why)."
            case .tooManyOptions: "Use at most \(DatabaseConnection.maximumOptions) DSN options."
            case .invalidOptionKey(let key): "“\(key)” isn't a DSN keyword: use letters, digits, and '_'."
            case .passwordOption(let key): "“\(key)” looks like a password. Runlet keeps passwords only in the Keychain: put it in the Password field."
            case .managedOption(let key): "“\(key)” is set from the connection's own fields."
            case .invalidOptionValue(let key): "The value of “\(key)” can't contain ';', braces (SQL Server), line breaks, or control characters."
            case .emptyDSN: "Enter the PDO DSN, such as oci:dbname=//db.internal:1521/XE."
            case .invalidDSN(let why): "The DSN \(why)"
            case .passwordInDSN: "The DSN contains a password. Runlet keeps passwords only in the Keychain: put it in the Password field, and leave it out of the DSN."
            case .readOnlyUnsupported(let driver): driver.readOnlyGuard + " Turn Read-only off to save it."
            case .relativePathOnThisMac: "From this Mac, the SQLite file needs an absolute path (or ~/…): Runlet opens it in an empty folder of its own, not in the project."
            case .tunnelNeedsHost(let driver): "An SSH tunnel forwards a host and port, so \(driver == .sqlite ? "an SQLite file" : "a custom DSN") can't use one. Connect from this Mac or from the target's PHP instead."
            case .tunnelWithoutProfile: "Choose the SSH profile whose connection carries the tunnel."
            case .tunnelOption(let key): "“\(key)” is set by the SSH tunnel: this Mac's PHP connects to the tunnel on 127.0.0.1."
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
            errors.append(scope == nil ? .duplicateNameAllTargets : .duplicateName)
        }
        if driver.usesHost {
            if value.usesSocket {
                // #140: the socket replaces the host (validateOptions checks it).
            } else if driver.supportsSocket, socket != nil {
                // The editor's "Unix socket" is on, with no path yet.
                errors.append(.emptySocket)
            } else if value.host.isEmpty {
                errors.append(.emptyHost)
            } else if value.host.count > 255 || value.host.hasPrefix("-") || value.host.range(of: #"^[A-Za-z0-9._:%\[\]-]+$"#, options: .regularExpression) == nil {
                errors.append(.invalidHost)
            }
            if let port, !(1...65535).contains(port) { errors.append(.invalidPort) }
            if value.database.count > 255 || value.database.range(of: driver == .sqlsrv ? #"[;'"\\{}]"# : #"[;'"\\]"#, options: .regularExpression) != nil || Self.hasControlCharacters(value.database) {
                errors.append(.invalidDatabase)
            }
        } else if driver == .sqlite {
            if value.database.isEmpty {
                errors.append(.emptyPath)
            } else if value.database.count > 4096 || Self.hasControlCharacters(value.database) {
                errors.append(.invalidDatabase)
            } else if value.opensOnThisMac, !value.database.hasPrefix("/"), value.database != ":memory:" {
                errors.append(.relativePathOnThisMac)
            }
        }
        if value.user.count > 255 || Self.hasControlCharacters(value.user) { errors.append(.invalidUser) }
        if !Self.connectTimeoutRange.contains(connectTimeout) { errors.append(.invalidTimeout) }
        if readOnly, !driver.supportsReadOnly { errors.append(.readOnlyUnsupported(driver)) }
        if value.usesSSHTunnel {
            if !driver.usesHost { errors.append(.tunnelNeedsHost(driver)) }
            if value.sshProfile == nil { errors.append(.tunnelWithoutProfile) }
            // libpq connects to hostaddr when it's set: it must stay the tunnel's 127.0.0.1.
            if driver == .pgsql, let option = value.options.first(where: { $0.key.lowercased() == "hostaddr" }) { errors.append(.tunnelOption(option.key)) }
        }
        errors += value.validateOptions()
        return errors
    }

    /// Checks the options of #140 (on the normalized definition): what reaches the DSN can't
    /// add or end DSN entries, and nothing can carry a password.
    func validateOptions() -> [ValidationError] {
        var errors: [ValidationError] = []
        if let socket, !Self.isSafePath(socket) { errors.append(.invalidSocket) }
        if let charset, charset.count > 40 || charset.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) == nil { errors.append(.invalidCharset) }
        if let tls {
            if !driver.tlsModes.contains(tls.mode) { errors.append(.unsupportedTLSMode(driver, tls.mode)) }
            for (path, what) in [(tls.caFile, "CA file"), (tls.certificateFile, "client certificate"), (tls.keyFile, "client key")] {
                if let path, !Self.isSafePath(path) { errors.append(.invalidTLSFile(what)) }
            }
            if (tls.certificateFile == nil) != (tls.keyFile == nil) { errors.append(.certificateWithoutKey) }
        }
        if initStatements.count > SQLScript.maximumInitStatements { errors.append(.tooManyInitStatements) }
        for (index, statement) in initStatements.prefix(SQLScript.maximumInitStatements).enumerated() {
            if statement.count > Self.maximumInitStatementLength {
                errors.append(.longInitStatement(index + 1))
            } else if let why = SQLScript.initStatementRefusal(of: statement, driver: driver == .custom ? nil : driver, readOnly: readOnly && driver.supportsReadOnly) {
                errors.append(.refusedInitStatement(index + 1, why))
            }
        }
        if options.count > Self.maximumOptions { errors.append(.tooManyOptions) }
        for option in options.prefix(Self.maximumOptions) {
            if option.key.count > 64 || option.key.range(of: #"^[A-Za-z][A-Za-z0-9_]*$"#, options: .regularExpression) == nil {
                errors.append(.invalidOptionKey(option.key))
            } else if Self.looksLikePassword(option.key) {
                errors.append(.passwordOption(option.key))
            } else if driver.managedOptionKeys.contains(option.key.lowercased()) {
                errors.append(.managedOption(option.key))
            }
            let forbidden = driver == .sqlsrv ? #"[;{}]"# : #"[;]"#
            if option.value.count > 1024 || option.value.range(of: forbidden, options: .regularExpression) != nil || Self.hasControlCharacters(option.value) {
                errors.append(.invalidOptionValue(option.key))
            }
        }
        if driver == .custom {
            if let dsn {
                if let why = Self.customDSNProblem(dsn) { errors.append(why) }
            } else {
                errors.append(.emptyDSN)
            }
        }
        return errors
    }

    /// A DSN option key that could carry a password (`password`, `PWD`, `sslpassword`,
    /// `passfile`, …).
    static func looksLikePassword(_ key: String) -> Bool {
        key.range(of: "pass|pwd", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Why a custom DSN can't be saved (the runner checks the same, `customDsnProblem`).
    static func customDSNProblem(_ dsn: String) -> ValidationError? {
        if dsn.count > 2048 { return .invalidDSN("is longer than 2048 characters.") }
        if hasControlCharacters(dsn) { return .invalidDSN("can't contain line breaks or control characters.") }
        if dsn.range(of: #"^[A-Za-z][A-Za-z0-9_]*:"#, options: .regularExpression) == nil {
            return .invalidDSN("must start with a PDO driver name and a colon, such as oci: or odbc:.")
        }
        if dsn.lowercased().hasPrefix("uri:") {
            return .invalidDSN("can't be a uri: DSN (Runlet doesn't let PDO read the DSN from a file or URL). Paste the DSN itself.")
        }
        if dsn.range(of: #"(^|[;:\s])\s*(password|passwd|pwd|sslpassword)\s*="#, options: [.regularExpression, .caseInsensitive]) != nil
            || dsn.range(of: #"://[^/@\s;]*:[^/@\s;]*@"#, options: .regularExpression) != nil {
            return .passwordInDSN
        }
        return nil
    }

    /// The PDO driver a custom DSN names (`oci` for `oci:dbname=…`).
    public var customDSNDriver: String? {
        guard driver == .custom, let dsn, let colon = dsn.firstIndex(of: ":") else { return nil }
        return dsn[..<colon].lowercased()
    }

    /// An absolute path that can't end or quote a DSN value.
    static func isSafePath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.count <= 1024 && path.range(of: #"[;'"\\]"#, options: .regularExpression) == nil && !hasControlCharacters(path)
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
    /// #143: the SSH profile that carries the connection's tunnel is stricter than both the
    /// target and the connection: confirmations name that profile as the reason.
    public var fromTunnel: Bool

    public init(environment: TargetEnvironment, color: TargetColor? = nil, fromConnection: Bool = false, fromTunnel: Bool = false) {
        self.environment = environment
        self.color = color
        self.fromConnection = fromConnection
        self.fromTunnel = fromTunnel
    }

    /// The stricter of the target's, the connection's, and (#143) its tunnel's SSH profile's
    /// environment.
    public init(target: TargetEnvironment, targetColor: TargetColor?, connection: DatabaseConnection?, tunnel: TargetEnvironment? = nil) {
        let own = connection?.environmentMarking ?? .development
        let tunnel = tunnel ?? .development
        environment = TargetEnvironment.stricter(TargetEnvironment.stricter(target, own), tunnel)
        fromConnection = own.strictness > target.strictness && own.strictness >= tunnel.strictness
        fromTunnel = tunnel.strictness > target.strictness && tunnel.strictness > own.strictness
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
    /// Whether `target` can have saved database connections of its own: local projects, Docker
    /// profiles, and SSH profiles. The sandbox uses connections of all targets (#142).
    public static func supportsDatabaseConnections(_ target: TargetRef) -> Bool {
        target != .sandbox
    }

    /// The target's own saved connections, by name (not those of all targets).
    public func databaseConnections(for target: TargetRef) -> [DatabaseConnection] {
        databaseConnections.filter { $0.scope == target }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Saved connections of all targets (#142), by name: every SQL tab's picker offers them.
    public var allTargetsDatabaseConnections: [DatabaseConnection] {
        databaseConnections.filter(\.isAllTargets).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The connections of `scope`: a target's own, or (nil) all targets'.
    public func databaseConnections(scope: TargetRef?) -> [DatabaseConnection] {
        scope.map(databaseConnections(for:)) ?? allTargetsDatabaseConnections
    }

    public func databaseConnection(_ id: UUID) -> DatabaseConnection? {
        databaseConnections.first { $0.id == id }
    }

    /// How a run on `target` is marked (#139): with a saved connection, the stricter of the
    /// target's environment and the connection's, and the connection's colour when it has one.
    /// #143: a connection through an SSH tunnel also counts its SSH profile's environment.
    public func marking(for target: TargetRef, connection: DatabaseConnection? = nil) -> EnvironmentMarking {
        EnvironmentMarking(target: environment(for: target), targetColor: color(for: target), connection: connection, tunnel: tunnelProfile(of: connection)?.environment)
    }

    /// #143: the SSH profile that carries a tunnelled connection, when it still exists.
    public func tunnelProfile(of connection: DatabaseConnection?) -> SSHProfile? {
        guard let connection, connection.usesSSHTunnel, let id = connection.sshProfile else { return nil }
        return sshProfile(id)
    }

    /// #143: why a tunnelled connection can't be used now (its SSH profile was removed, or
    /// none is chosen); nil when it can, or when it doesn't use a tunnel. Runlet never picks
    /// another profile by itself.
    public func tunnelProblem(of connection: DatabaseConnection) -> String? {
        guard connection.usesSSHTunnel else { return nil }
        guard connection.sshProfile != nil else {
            return "The saved connection “\(connection.name)” connects through an SSH tunnel, but no SSH profile is chosen. Edit the connection and choose one."
        }
        guard tunnelProfile(of: connection) != nil else {
            return "The SSH profile that carries the tunnel of the saved connection “\(connection.name)” was removed, so nothing ran. Edit the connection and choose another SSH profile; Runlet never picks one by itself."
        }
        return nil
    }

    /// A tab's saved connection: by id when it belongs to `target` or to all targets (#142),
    /// else the connection with that name (a workspace, or a tab moved to another target): the
    /// target's own first, then one of all targets.
    public func databaseConnection(id: UUID?, name: String?, on target: TargetRef) -> DatabaseConnection? {
        if let id, let found = databaseConnection(id), found.isAvailable(on: target) { return found }
        guard let name, !name.isEmpty else { return nil }
        let named = { (connection: DatabaseConnection) in connection.name.caseInsensitiveCompare(name) == .orderedSame }
        return databaseConnections.first { $0.scope == target && named($0) } ?? databaseConnections.first { $0.isAllTargets && named($0) }
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
