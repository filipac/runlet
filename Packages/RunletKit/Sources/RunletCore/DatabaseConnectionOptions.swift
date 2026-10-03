import Foundation

/// How a saved connection uses TLS (#140), named as libpq names its `sslmode`s. Not every
/// driver can express every mode: `DatabaseDriverKind.tlsModes` lists the ones it can.
public enum DatabaseTLSMode: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    /// No TLS.
    case disable
    /// TLS when the server offers it, else plain (PostgreSQL only).
    case prefer
    /// TLS, without checking the server's certificate.
    case require
    /// TLS, checking that a trusted CA signed the server's certificate, but not its host name
    /// (PostgreSQL only).
    case verifyCA = "verify-ca"
    /// TLS, checking the certificate's CA and that it names the host.
    case verifyFull = "verify-full"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .disable: "Off"
        case .prefer: "Prefer"
        case .require: "Require (not verified)"
        case .verifyCA: "Verify CA"
        case .verifyFull: "Verify CA and host name"
        }
    }

    /// The certificate files matter only when TLS can be on.
    public var usesFiles: Bool { self != .disable }
}

/// A saved connection's TLS settings (#140): the mode and, for MySQL and PostgreSQL, the CA,
/// client certificate, and client key files. The files are paths where the connection is
/// opened (the target's PHP); they aren't secrets, and Runlet never reads them.
public struct DatabaseTLS: Sendable, Codable, Hashable {
    public var mode: DatabaseTLSMode
    public var caFile: String?
    public var certificateFile: String?
    public var keyFile: String?

    public init(mode: DatabaseTLSMode, caFile: String? = nil, certificateFile: String? = nil, keyFile: String? = nil) {
        self.mode = mode
        self.caFile = caFile
        self.certificateFile = certificateFile
        self.keyFile = keyFile
    }

    enum CodingKeys: String, CodingKey {
        case mode, caFile = "ca", certificateFile = "cert", keyFile = "key"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(DatabaseTLSMode.self, forKey: .mode)
        caFile = try? c.decodeIfPresent(String.self, forKey: .caFile)
        certificateFile = try? c.decodeIfPresent(String.self, forKey: .certificateFile)
        keyFile = try? c.decodeIfPresent(String.self, forKey: .keyFile)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encodeIfPresent(caFile, forKey: .caFile)
        try c.encodeIfPresent(certificateFile, forKey: .certificateFile)
        try c.encodeIfPresent(keyFile, forKey: .keyFile)
    }

    /// Without the files when they don't apply, and empty paths as nil.
    func normalized(for driver: DatabaseDriverKind) -> DatabaseTLS {
        var copy = self
        func trimmed(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        if mode.usesFiles, driver.supportsTLSFiles {
            copy.caFile = trimmed(caFile)
            copy.certificateFile = trimmed(certificateFile)
            copy.keyFile = trimmed(keyFile)
        } else {
            copy.caFile = nil
            copy.certificateFile = nil
            copy.keyFile = nil
        }
        return copy
    }
}

/// One extra DSN option (#140): a libpq keyword for PostgreSQL (`application_name`,
/// `target_session_attrs`, …) or a DSN keyword for SQL Server (`APP`, `ApplicationIntent`,
/// …), appended to the DSN. Never a password (`DatabaseConnection.validate` refuses those).
public struct DatabaseOption: Sendable, Codable, Hashable {
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

extension DatabaseDriverKind {
    /// The TLS modes the driver's PDO can express (#140). MySQL's (mysqlnd) either asks for
    /// TLS or doesn't, and checks the host name whenever it checks the certificate; SQL
    /// Server's the same; PostgreSQL's libpq has all five.
    public var tlsModes: [DatabaseTLSMode] {
        switch self {
        case .pgsql: DatabaseTLSMode.allCases
        case .mysql, .sqlsrv: [.disable, .require, .verifyFull]
        case .sqlite, .custom: []
        }
    }

    /// Whether a connection can name a CA file and a client certificate and key.
    public var supportsTLSFiles: Bool { self == .mysql || self == .pgsql }

    /// Whether the driver connects through a Unix socket instead of a host and port.
    public var supportsSocket: Bool { self == .mysql || self == .pgsql }

    /// Whether the connection sets the session's character set (MySQL `charset=`, PostgreSQL
    /// `client_encoding`).
    public var supportsCharset: Bool { self == .mysql || self == .pgsql }

    /// Whether extra DSN options are appended (PostgreSQL's libpq keywords, SQL Server's DSN
    /// keywords). MySQL's PDO DSN has no other keys.
    public var supportsOptions: Bool { self == .pgsql || self == .sqlsrv }

    /// Whether the database can enforce a read-only session (#139).
    public var supportsReadOnly: Bool { self == .mysql || self == .pgsql || self == .sqlite }

    /// Whether the connection has a user and a password (SQLite files have neither).
    public var usesCredentials: Bool { self != .sqlite }

    /// DSN keys set from the connection's own fields, so extra options can't set them.
    var managedOptionKeys: Set<String> {
        switch self {
        case .pgsql: ["host", "port", "dbname", "user", "sslmode", "sslrootcert", "sslcert", "sslkey", "client_encoding", "connect_timeout"]
        case .sqlsrv: ["server", "database", "uid", "encrypt", "trustservercertificate", "logintimeout"]
        default: []
        }
    }

    /// What the editor says about the TLS modes the driver can and can't express.
    public var tlsNote: String {
        switch self {
        case .mysql: "MySQL's PDO driver either requires TLS or doesn't use it, and checks the host name whenever it checks the certificate, so it has no Prefer or Verify CA. With Require or Verify, Runlet also checks that the session is encrypted before anything runs."
        case .pgsql: "Passed to libpq as sslmode, sslrootcert, sslcert, and sslkey. Encrypted client keys aren't supported: their passphrase would have to leave the Keychain."
        case .sqlsrv: "Passed to pdo_sqlsrv as Encrypt and TrustServerCertificate; the ODBC driver checks the certificate against the system's CAs. pdo_dblib (FreeTDS) takes TLS from freetds.conf instead, so set Driver default when the target uses it."
        case .sqlite, .custom: ""
        }
    }
}

extension SQLScript {
    /// The most init statements a saved connection runs (#140).
    public static let maximumInitStatements = 20

    /// Why a saved connection's init statement (#140) can't run, after "This statement": nil
    /// when it can. Every connection refuses an empty one, several statements in one, and
    /// transaction control (an init statement can't leave a transaction open, or commit one).
    /// A read-only connection (#139) also refuses what `readOnlyRefusal` refuses, except
    /// session settings (`SET search_path …`, `SET time_zone …`) that keep the session
    /// read-only and change nothing server-wide (`SET GLOBAL`, `SET PERSIST`, `SET PASSWORD`,
    /// `SET DEFAULT ROLE`). The runner sends init statements after the read-only setting, so
    /// the database refuses writes in them, and checks the setting again afterwards. The
    /// runner applies the same rules (`SqlReadOnly::initRefusal`).
    public static func initStatementRefusal(of statement: String, driver: DatabaseDriverKind?, readOnly: Bool) -> String? {
        for reading in readings(of: statement, driver: driver) {
            let string = reading.text as NSString
            let tokens = tokenize(string, backslashEscapes: reading.backslashEscapes, hashComments: reading.hashComments)
            if let refusal = initStatementRefusal(tokens: tokens, in: string, readOnly: readOnly) {
                return refusal
            }
        }
        return nil
    }

    static func initStatementRefusal(tokens all: [Token], in string: NSString, readOnly: Bool) -> String? {
        let tokens = all.filter { $0.kind != .comment }
        guard !tokens.isEmpty else { return "has no statement" }
        if let semicolon = tokens.firstIndex(where: { $0.kind == .semicolon }), tokens[(semicolon + 1)...].contains(where: { $0.kind != .semicolon }) {
            return "holds several statements (give each its own line)"
        }
        let words = firstWords(tokens: tokens, in: string, count: 3)
        if let control = transactionControl(words: words) {
            return "begins or ends a transaction (\(control)), which an init statement can't do"
        }
        guard readOnly else { return nil }
        if words.first == "SET" {
            let names = tokens.filter { $0.kind == .keyword || $0.kind == .word }.map { String(string.substring(with: $0.range).uppercased().drop { $0 == "@" }) }
            if let server = names.first(where: { ["GLOBAL", "PERSIST", "PERSIST_ONLY", "PASSWORD"].contains($0) || $0.hasPrefix("GLOBAL.") || $0.hasPrefix("PERSIST.") }) {
                return "changes a server-wide setting or an account (SET … \(server.split(separator: ".").first.map(String.init) ?? server))"
            }
            if words.count > 2, words[1] == "DEFAULT", words[2] == "ROLE" {
                return "changes an account (SET DEFAULT ROLE)"
            }
            if let phrase = readOnlySessionChange(tokens: tokens, in: string) {
                return SQLReadOnlyRefusal.sessionChange(phrase).predicate
            }
            return nil
        }
        return readOnlyRefusal(tokens: tokens, in: string)?.predicate
    }
}
