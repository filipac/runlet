import Foundation
import Security

// MARK: - Mapping

/// How a TablePlus connection becomes a Runlet saved connection (#188).
public enum TablePlusMapping {
    /// Runlet's driver for TablePlus's `Driver`, or why it can't be imported.
    public static func driver(_ raw: String) -> (driver: DatabaseDriverKind?, reason: String?) {
        let key = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        switch key {
        case "mysql", "mariadb": return (.mysql, nil)
        case "postgresql", "postgres", "pgsql": return (.pgsql, nil)
        case "sqlite", "sqlite3": return (.sqlite, nil)
        case "sqlserver", "microsoftsqlserver", "mssql": return (.sqlsrv, nil)
        case "": return (nil, "TablePlus doesn't say which driver it uses.")
        case "redis": return (.redis, nil) // #190
        case "mongodb", "mongo": return (.mongodb, nil) // #209
        case "cassandra", "scylladb", "dynamodb", "etcd", "elasticsearch", "opensearch":
            return (nil, "Runlet has no \(raw) connections: it connects to SQL databases (through PHP's PDO), Redis, and MongoDB.")
        default:
            return (nil, "Runlet has no driver for \(raw). It imports MySQL, MariaDB, PostgreSQL, SQLite, SQL Server, Redis, and MongoDB; create another SQL database's connection with New Connection… (a custom PDO DSN).")
        }
    }

    /// Runlet's environment for TablePlus's tag: production stays production, staging and
    /// testing are staging, local and development are development (nil). An unknown tag that
    /// mentions "prod" is production; any other reads as development, with a note.
    public static func environment(_ tag: String?) -> (environment: TargetEnvironment?, note: String?) {
        guard let tag, !tag.isEmpty else { return (nil, nil) }
        switch tag.lowercased() {
        case "production", "prod": return (.production, nil)
        case "staging", "stage", "testing", "test": return (.staging, nil)
        case "local", "development", "dev", "none": return (nil, nil)
        default:
            if tag.lowercased().contains("prod") { return (.production, "TablePlus's tag “\(tag)” was read as production.") }
            return (nil, "TablePlus's tag “\(tag)” isn't one Runlet knows; the connection is marked development.")
        }
    }

    /// The Runlet colour nearest to TablePlus's `#RRGGBB` status colour; nil for greys
    /// (TablePlus's default status colours among them) and for anything else.
    public static func color(_ hex: String?) -> TargetColor? {
        guard var text = hex?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = Int(text, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255, g = Double((value >> 8) & 0xFF) / 255, b = Double(value & 0xFF) / 255
        let maximum = max(r, g, b), minimum = min(r, g, b)
        let delta = maximum - minimum
        guard maximum > 0, delta / maximum >= 0.25, delta >= 0.12 else { return nil }
        var hue: Double
        if maximum == r {
            hue = (g - b) / delta
        } else if maximum == g {
            hue = (b - r) / delta + 2
        } else {
            hue = (r - g) / delta + 4
        }
        hue = (hue * 60).truncatingRemainder(dividingBy: 360)
        if hue < 0 { hue += 360 }
        // Dark oranges and reds read as brown.
        if (15..<45).contains(hue), maximum < 0.55 { return .brown }
        switch hue {
        case ..<15, 345...: return .red
        case ..<40: return .orange
        case ..<65: return .yellow
        case ..<156: return .green
        case ..<175: return .mint
        case ..<195: return .teal
        case ..<230: return .blue
        case ..<260: return .indigo
        case ..<300: return .purple
        default: return .pink
        }
    }

    /// TLS from TablePlus's `tLSMode`, the index of its TLS menu, which differs per driver (as
    /// the open-source importer the pull request cites reads it). Unknown values leave TLS at
    /// the driver's default, with a note.
    public static func tls(mode: Int?, rawDriver: String, driver: DatabaseDriverKind) -> (tls: DatabaseTLS?, note: String?) {
        guard let mode, mode != 0 else { return (nil, nil) }
        let unknown = "TablePlus's TLS setting (\(mode)) isn't one Runlet reads; TLS is left at the driver's default. Check it in the connection's Advanced section."
        let mariadb = rawDriver.lowercased().contains("maria")
        switch driver {
        case .pgsql:
            switch mode {
            case 1: return (DatabaseTLS(mode: .disable), nil)
            case 2: return (DatabaseTLS(mode: .require), nil)
            case 3: return (DatabaseTLS(mode: .prefer), "TablePlus's TLS setting (3) was read as Prefer. Check it in the connection's Advanced section.")
            case 4: return (DatabaseTLS(mode: .verifyCA), nil)
            case 5: return (DatabaseTLS(mode: .verifyFull), nil)
            default: return (nil, unknown)
            }
        case .mysql where mariadb:
            switch mode {
            case 1: return (DatabaseTLS(mode: .require), nil)
            case 2: return (DatabaseTLS(mode: .verifyFull), nil)
            default: return (nil, unknown)
            }
        case .mysql:
            switch mode {
            case 1: return (DatabaseTLS(mode: .disable), nil)
            case 2: return (DatabaseTLS(mode: .require), nil)
            case 3: return (DatabaseTLS(mode: .verifyFull), "TablePlus verifies the CA only; MySQL's PDO driver also checks the host name, so Runlet uses Verify CA and host name.")
            case 4: return (DatabaseTLS(mode: .verifyFull), nil)
            default: return (nil, unknown)
            }
        case .sqlsrv:
            return (nil, unknown)
        case .redis:
            // #190: TablePlus's Redis TLS menu isn't documented; any setting reads as Require.
            return (DatabaseTLS(mode: .require), "TablePlus uses TLS for it; Runlet encrypts without verifying the certificate (Require). Choose Verify CA and host name in the connection's Advanced section to check it.")
        case .mongodb:
            // #209: TablePlus's MongoDB TLS menu isn't documented either; any setting reads as on.
            // Runlet's MongoDB connections are either plain or verified (#202).
            return (DatabaseTLS(mode: .verifyFull), "TablePlus uses TLS for it (setting \(mode)); Runlet's MongoDB connection verifies the server's certificate and host name against the system's trust store. Check it in the connection's editor.")
        case .sqlite, .custom:
            return (nil, nil)
        }
    }
}

// MARK: - Rows

/// One TablePlus connection in the import sheet: what it becomes, or why it can't be imported.
public struct TablePlusImportRow: Sendable, Identifiable, Equatable {
    public var id: String { source.id }
    public let source: TablePlusConnection
    /// The saved connection it becomes, from this Mac (the scope and an SSH tunnel are set when
    /// importing). nil when it can't be imported.
    public let connection: DatabaseConnection?
    /// Why it can't be imported (an unsupported driver, a field Runlet refuses).
    public let reason: String?
    /// What needs a look after importing (approximations, missing fields).
    public let notes: [String]
    public let environment: TargetEnvironment

    public var canImport: Bool { connection != nil }
    public var isProduction: Bool { environment == .production }
    /// Whether TablePlus reaches the database over SSH (SQLite files never use it here, and an
    /// SRV MongoDB connection can't: #209).
    public var usesSSH: Bool { source.ssh != nil && connection?.driver.usesHost == true && connection?.mongo?.srv != true }
    /// TLS on, or, for an SRV MongoDB connection, left at its default (on).
    public var usesTLS: Bool {
        if let tls = connection?.tls { return tls.mode != .disable }
        return connection?.mongo?.srv == true
    }

    public init(_ source: TablePlusConnection) {
        self.source = source
        var notes = source.problems.filter { !$0.hasPrefix("The driver is missing") }
        let (environment, environmentNote) = TablePlusMapping.environment(source.environment)
        self.environment = environment ?? .development
        if let environmentNote { notes.append(environmentNote) }
        let (driver, why) = TablePlusMapping.driver(source.driver)
        guard let driver else {
            connection = nil
            reason = why
            self.notes = notes
            return
        }
        var name = source.name
        if name.count > DatabaseConnection.maximumNameLength {
            name = String(name.prefix(DatabaseConnection.maximumNameLength))
            notes.append("The name was shortened to \(DatabaseConnection.maximumNameLength) characters.")
        }
        var connection = DatabaseConnection(name: name, scope: nil, connectFrom: .thisMac, driver: driver, importedFrom: source.hasID ? TablePlusImport.sourceKey(source.id) : nil)
        connection.environment = environment
        connection.color = TablePlusMapping.color(source.statusColor)
        if driver == .sqlite {
            let path = source.path ?? (source.host.isEmpty ? source.database : "")
            connection.database = path
            if source.ssh != nil { notes.append("TablePlus lists SSH for it, but an SQLite file opens on this Mac; it's imported without SSH.") }
        } else {
            connection.host = source.host
            connection.port = source.port
            connection.database = source.database
            // #190: a Redis database is a number; anything else reads as database 0.
            if driver == .redis, !connection.database.isEmpty, Int(connection.database.trimmingCharacters(in: .whitespaces)) == nil {
                notes.append("TablePlus's database “\(connection.database)” isn't a Redis database number; the connection uses database 0.")
                connection.database = ""
            }
            connection.user = source.user
            if let socket = source.socket {
                if driver.supportsSocket {
                    connection.socket = socket
                } else {
                    notes.append("TablePlus uses the socket \(socket); Runlet's \(driver.displayName) driver connects through the host instead.")
                }
            }
            if driver == .mongodb {
                notes += Self.mapMongo(source, into: &connection)
            } else {
                let (tls, tlsNote) = TablePlusMapping.tls(mode: source.tlsMode, rawDriver: source.driver, driver: driver)
                connection.tls = tls
                if let tlsNote { notes.append(tlsNote) }
                if !source.tlsKeyPaths.isEmpty {
                    notes.append("TablePlus uses TLS key or certificate files; add them in the connection's Advanced section (Runlet doesn't copy them).")
                }
            }
        }
        if source.readOnly == true {
            if driver.supportsReadOnly {
                connection.readOnly = true
            } else {
                notes.append("TablePlus marks it read-only. " + driver.readOnlyGuard)
            }
        } else if let level = source.safeModeLevel, level > 0 {
            notes.append("TablePlus asks before running statements on it (safe mode \(level)). Runlet didn't turn on Read-only; turn it on in the editor to have writes refused.")
        }
        let errors = connection.validate().filter { $0 != .duplicateName && $0 != .duplicateNameAllTargets }
        if errors.isEmpty {
            self.connection = connection.normalized
            reason = nil
        } else if driver == .mongodb, errors.contains(.emptyHost) {
            // #209: TablePlus may keep the URL where Runlet can't read it.
            self.connection = nil
            reason = "Runlet found no host or connection string it can read for it. Create it with New Connection…, entering the host (not a URI)."
        } else {
            self.connection = nil
            reason = "Runlet can't save it as it is: " + errors.map(\.description).joined(separator: " ")
        }
        self.notes = notes
    }

    /// #209: a MongoDB connection's settings (`MongoConnectionOptions` and TLS); returns the notes.
    /// Runlet keeps one host, SCRAM logins, the five read preferences, and TLS on (verified) or off.
    static func mapMongo(_ source: TablePlusConnection, into connection: inout DatabaseConnection) -> [String] {
        let mongo = source.mongo ?? TablePlusMongo()
        var options = MongoConnectionOptions()
        var notes: [String] = []
        let pattern = #"^[A-Za-z0-9_.-]{1,120}$"#
        options.srv = mongo.srv
        if let auth = mongo.authSource {
            if auth.range(of: pattern, options: .regularExpression) != nil {
                options.authDatabase = auth
            } else if auth == "$external" {
                notes.append("TablePlus authenticates against $external (X.509, LDAP, Kerberos, or AWS), which Runlet's MongoDB connections don't support; the authentication database is admin.")
            } else {
                notes.append("TablePlus's authentication database isn't a name Runlet accepts (letters, digits, '.', '-', '_'); admin is used.")
            }
        }
        if let mechanism = mongo.authMechanism {
            switch mechanism.uppercased() {
            case "SCRAM-SHA-1", "SCRAM-SHA-256": options.authMechanism = mechanism.uppercased()
            case "DEFAULT": break
            default: notes.append("TablePlus logs in with \(mechanism.prefix(40)); Runlet's MongoDB connections log in with SCRAM (the default is used), so check the login.")
            }
        }
        if let replicaSet = mongo.replicaSet {
            if replicaSet.range(of: pattern, options: .regularExpression) != nil {
                options.replicaSet = replicaSet
            } else {
                notes.append("TablePlus's replica set name isn't one Runlet accepts (letters, digits, '.', '-', '_'); it's left out.")
            }
        }
        if let preference = mongo.readPreference {
            let known = ["primary", "primaryPreferred", "secondary", "secondaryPreferred", "nearest"]
            if let match = known.first(where: { $0.caseInsensitiveCompare(preference) == .orderedSame }) {
                options.readPreference = match
            } else {
                notes.append("TablePlus's read preference “\(preference.prefix(40))” isn't one Runlet knows; primary is used.")
            }
        }
        if !mongo.moreHosts.isEmpty {
            let others = mongo.moreHosts.prefix(3).joined(separator: ", ") + (mongo.moreHosts.count > 3 ? ", …" : "")
            let first = MongoConnectionString.Host(host: connection.host, port: connection.port).label
            var note = "TablePlus lists \(mongo.moreHosts.count + 1) hosts (also \(others)); Runlet's connection uses the first, \(first)"
            if source.ssh != nil {
                note += ". Through the SSH tunnel it connects to that host only."
            } else if !options.replicaSet.isEmpty {
                note += ". With the replica set, the driver finds the other members from it."
            } else {
                note += ". Add the replica set name if they're one replica set."
            }
            notes.append(note)
        }
        // TLS: the connection string's tls/ssl, else TablePlus's TLS menu; an SRV connection's default is on.
        if let tls = mongo.tls {
            connection.tls = DatabaseTLS(mode: tls ? .verifyFull : .disable)
        } else {
            let (tls, note) = TablePlusMapping.tls(mode: source.tlsMode, rawDriver: source.driver, driver: .mongodb)
            connection.tls = tls
            if let note { notes.append(note) }
        }
        if mongo.tlsInsecure, connection.tls?.mode != .disable {
            notes.append("TablePlus skips checking the server's certificate (tlsInsecure); Runlet's MongoDB connection always checks it and the host name.")
        }
        if mongo.tlsFiles || !source.tlsKeyPaths.isEmpty {
            notes.append("TablePlus uses TLS CA or client certificate files; Runlet's MongoDB connections use the system's trust store and send no client certificate, and don't copy the files.")
        }
        if !mongo.otherOptions.isEmpty {
            let names = mongo.otherOptions.prefix(6).joined(separator: ", ") + (mongo.otherOptions.count > 6 ? ", …" : "")
            notes.append("TablePlus's connection string also sets \(names); Runlet doesn't keep \(mongo.otherOptions.count == 1 ? "it" : "them").")
        }
        if mongo.srv, let ssh = source.ssh {
            notes.append("TablePlus lists SSH (\(ssh.destination)), but an SRV connection can't go through an SSH tunnel, so it connects from this Mac directly. To use the tunnel, enter one member's host and port, turn SRV off, and choose the SSH profile in the editor.")
        }
        connection.mongo = options
        return notes
    }
}

// MARK: - SSH

/// An SSH server as TablePlus names it (host, port, user), to match an existing SSH profile
/// or share one new profile between connections.
public struct TablePlusSSHServer: Sendable, Hashable, Comparable {
    public var host: String
    public var port: Int
    public var user: String

    public init(_ ssh: TablePlusSSH) {
        host = ssh.host.lowercased()
        port = ssh.port ?? 22
        user = ssh.user ?? ""
    }

    /// Same host (ignoring case), port (22 when unset), and user.
    public func matches(_ profile: SSHProfile) -> Bool {
        profile.host.trimmingCharacters(in: .whitespaces).lowercased() == host && (profile.port ?? 22) == port && (profile.user ?? "") == user
    }

    public static func < (a: Self, b: Self) -> Bool {
        (a.host, a.port, a.user) < (b.host, b.port, b.user)
    }
}

/// Where an imported connection that TablePlus opens over SSH goes.
public enum TablePlusSSHChoice: Sendable, Hashable {
    /// Through a new SSH profile, shared by every connection on the same server.
    case newProfile
    /// Through an existing SSH profile.
    case existing(UUID)
    /// Without SSH: from this Mac straight to the host.
    case direct
}

/// An SSH profile the import creates (one per server).
public struct TablePlusNewProfile: Sendable, Identifiable, Equatable {
    public var id: TablePlusSSHServer { server }
    public var server: TablePlusSSHServer
    /// The profile as it will be saved (a new id each time the plan is worked out).
    public var profile: SSHProfile
    /// The TablePlus connections that use it.
    public var rowIDs: [String]
    /// How it logs in, and what to check.
    public var notes: [String]
}

public enum TablePlusDuplicatePolicy: String, Sendable, CaseIterable, Identifiable {
    case skip, update
    public var id: String { rawValue }
}

/// What the user chose in the sheet.
public struct TablePlusImportOptions: Sendable, Equatable {
    /// TablePlus ids of the rows to import; none by default.
    public var selected: Set<String> = []
    /// nil: all targets (the default).
    public var scope: TargetRef?
    public var duplicates: TablePlusDuplicatePolicy = .skip
    /// Off by default: copy database passwords from TablePlus's Keychain items.
    public var copyPasswords = false
    /// Per row; a row without an entry uses `TablePlusImportPlan.defaultSSHChoice`.
    public var sshChoices: [String: TablePlusSSHChoice] = [:]

    public init(selected: Set<String> = [], scope: TargetRef? = nil, duplicates: TablePlusDuplicatePolicy = .skip, copyPasswords: Bool = false, sshChoices: [String: TablePlusSSHChoice] = [:]) {
        self.selected = selected
        self.scope = scope
        self.duplicates = duplicates
        self.copyPasswords = copyPasswords
        self.sshChoices = sshChoices
    }
}

// MARK: - Plan

/// Every connection found in TablePlus's list, ready for the sheet.
public struct TablePlusImportPlan: Sendable, Equatable {
    public var rows: [TablePlusImportRow]
    /// Problems with the file as a whole.
    public var problems: [String]

    public init(_ parsed: TablePlusParser.Result) {
        rows = parsed.connections.map(TablePlusImportRow.init)
        problems = parsed.problems
    }

    public func row(_ id: String) -> TablePlusImportRow? { rows.first { $0.id == id } }

    /// Existing SSH profiles with the row's SSH host, port, and user, by name.
    public func matchingProfiles(for row: TablePlusImportRow, in library: TargetLibrary) -> [SSHProfile] {
        guard row.usesSSH, let ssh = row.source.ssh else { return [] }
        let server = TablePlusSSHServer(ssh)
        return library.sshProfiles.filter { server.matches($0) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// An existing profile on the same server, else a new profile (or, when TablePlus's SSH
    /// settings can't make one, no SSH). nil for a row without SSH.
    public func defaultSSHChoice(for row: TablePlusImportRow, in library: TargetLibrary) -> TablePlusSSHChoice? {
        guard row.usesSSH, let ssh = row.source.ssh else { return nil }
        if let profile = matchingProfiles(for: row, in: library).first { return .existing(profile.id) }
        return Self.profileProblem(ssh) == nil ? .newProfile : .direct
    }

    /// The row's choice: the user's, when it still applies, else the default.
    public func sshChoice(for row: TablePlusImportRow, options: TablePlusImportOptions, in library: TargetLibrary) -> TablePlusSSHChoice? {
        guard let fallback = defaultSSHChoice(for: row, in: library), let ssh = row.source.ssh else { return nil }
        switch options.sshChoices[row.id] {
        case .existing(let id)? where library.sshProfile(id) != nil: return .existing(id)
        case .newProfile? where Self.profileProblem(ssh) == nil: return .newProfile
        case .direct?: return .direct
        default: return fallback
        }
    }

    /// Why TablePlus's SSH settings can't make an SSH profile; nil when they can.
    public static func profileProblem(_ ssh: TablePlusSSH) -> String? {
        var probe = SSHProfile(name: "probe", host: ssh.host, user: ssh.user, port: ssh.port, remoteDirectory: "/")
        if case .key(let path?, _) = ssh.login { probe.identityFile = path }
        let errors = probe.validate().filter { SSHProfile.ValidationError.connectionErrors.contains($0) }
        return errors.isEmpty ? nil : errors.map(\.description).joined(separator: " ")
    }

    /// A saved connection the row would duplicate: one imported from the same TablePlus
    /// connection before (in any scope), else one with the same name in `scope`.
    public func duplicate(of row: TablePlusImportRow, scope: TargetRef?, in library: TargetLibrary) -> DatabaseConnection? {
        if row.source.hasID {
            let key = TablePlusImport.sourceKey(row.source.id)
            if let found = library.databaseConnections.first(where: { $0.importedFrom == key }) { return found }
        }
        let name = row.connection?.name ?? row.source.name
        return library.databaseConnections(scope: scope).first { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The rows the import works on, in order: selected, importable, and not skipped as
    /// duplicates. `existing` is the connection an update replaces.
    public func work(options: TablePlusImportOptions, library: TargetLibrary) -> [(row: TablePlusImportRow, existing: DatabaseConnection?)] {
        rows.compactMap { row in
            guard options.selected.contains(row.id), row.canImport else { return nil }
            let existing = duplicate(of: row, scope: options.scope, in: library)
            if existing != nil, options.duplicates == .skip { return nil }
            return (row, existing)
        }
    }

    /// The SSH profiles the import creates: one per server among the rows it imports whose
    /// choice is a new profile. Named after the SSH host, without clashing with existing
    /// profiles or each other; production only when every connection using it is (the least
    /// strict of their environments).
    public func newProfiles(options: TablePlusImportOptions, library: TargetLibrary) -> [TablePlusNewProfile] {
        var order: [TablePlusSSHServer] = []
        var byServer: [TablePlusSSHServer: [TablePlusImportRow]] = [:]
        for (row, _) in work(options: options, library: library) {
            guard sshChoice(for: row, options: options, in: library) == .newProfile, let ssh = row.source.ssh else { continue }
            let server = TablePlusSSHServer(ssh)
            if byServer[server] == nil { order.append(server) }
            byServer[server, default: []].append(row)
        }
        var taken = Set(library.sshProfiles.map { $0.name.lowercased() })
        return order.map { server in
            let rows = byServer[server] ?? []
            let ssh = rows[0].source.ssh!
            let name = Self.uniqueName(ssh.host, taken: taken)
            taken.insert(name.lowercased())
            let environment = rows.map(\.environment).min { $0.strictness < $1.strictness } ?? .development
            var profile = SSHProfile(name: name, host: ssh.host, user: ssh.user, port: ssh.port.flatMap { $0 == 22 ? nil : $0 }, remoteDirectory: "/", environment: environment)
            var notes: [String] = []
            switch ssh.login {
            case .key(let path, let keyName):
                profile.authentication = .automatic
                if let path {
                    profile.identityFile = path
                    notes.append("Logs in with the key \(path) (Runlet passes only the path; your agent or OpenSSH asks for its passphrase).")
                } else {
                    notes.append("TablePlus logs in with the key “\(keyName ?? "key")” but doesn't say where its file is. The profile uses your SSH agent and ~/.ssh/config; set its key file if it needs one.")
                }
            case .password:
                profile.authentication = .interactive
                notes.append("Logs in with a password at Connect…; TablePlus's SSH password isn't copied.")
            case .agent:
                profile.authentication = .automatic
                notes.append("Logs in with your SSH agent.")
            }
            notes.append("Its folder on the server is / (it's for the tunnel). Set the application's folder to run PHP there.")
            return TablePlusNewProfile(server: server, profile: profile, rowIDs: rows.map(\.id), notes: notes)
        }
    }

    static func uniqueName(_ base: String, taken: Set<String>) -> String {
        var name = base
        var number = 2
        while taken.contains(name.lowercased()) {
            name = "\(base) \(number)"
            number += 1
        }
        return name
    }

    /// TablePlus ids whose database passwords the import reads when asked to: the rows it
    /// imports whose driver has a password and that have TablePlus's id. A MongoDB connection
    /// string's own password (#209) needs no Keychain item.
    public func passwordRequests(options: TablePlusImportOptions, library: TargetLibrary) -> [String] {
        guard options.copyPasswords else { return [] }
        return work(options: options, library: library).compactMap { row, _ in
            row.source.hasID && row.connection?.driver.usesCredentials == true && row.source.mongo?.password == nil ? row.id : nil
        }
    }
}

// MARK: - Passwords

/// What reading a TablePlus Keychain item gave.
public enum TablePlusPasswordResult: Sendable, Equatable {
    case found(SensitiveString)
    /// No item for the connection (or an empty one).
    case missing
    /// macOS didn't allow it (Deny, or the keychain password was wrong).
    case denied
    case failed(String)
}

/// Reads the database password TablePlus keeps for a connection (#188). Only Import from
/// TablePlus… uses it, only when the user ticks "Also copy passwords", and only for the
/// connections being imported. SSH passwords and key passphrases are never read.
public protocol TablePlusKeychainReader: Sendable {
    /// May show macOS's Keychain prompt; call it off the main thread.
    func databasePassword(forConnection id: String) -> TablePlusPasswordResult
}

/// The login keychain's generic-password items TablePlus writes: service
/// `com.tableplus.TablePlus`, account `<connection id>_database` (as the open-source tool the
/// pull request cites updates them). When that item isn't there (another TablePlus edition),
/// it looks for the account in a service whose name mentions TablePlus. macOS asks the user to
/// allow each item.
public struct SecurityTablePlusKeychainReader: TablePlusKeychainReader {
    public static let service = "com.tableplus.TablePlus"

    public init() {}

    public static func account(for id: String) -> String { id + "_database" }

    public func databasePassword(forConnection id: String) -> TablePlusPasswordResult {
        let account = Self.account(for: id)
        let result = read(service: Self.service, account: account)
        guard result == .missing else { return result }
        // Find the item's service by its attributes (no prompt), then read it.
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess, let list = items as? [[String: Any]] else { return .missing }
        let services = list.compactMap { $0[kSecAttrService as String] as? String }.filter { $0.localizedCaseInsensitiveContains("tableplus") && $0 != Self.service }
        for service in services {
            let other = read(service: service, account: account)
            if other != .missing { return other }
        }
        return .missing
    }

    private func read(service: String, account: String) -> TablePlusPasswordResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var data: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &data)
        switch status {
        case errSecSuccess:
            guard let data = data as? Data else { return .missing }
            let text = String(decoding: data, as: UTF8.self)
            return text.isEmpty ? .missing : .found(SensitiveString(text))
        case errSecItemNotFound:
            return .missing
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            return .denied
        default:
            return .failed((SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)")
        }
    }
}

/// Fixed answers instead of the Keychain, for tests and Debug runs with fixture files
/// (`RUNLET_TABLEPLUS_DIR`): it never touches a keychain. Records which ids were asked for.
public final class FakeTablePlusKeychainReader: TablePlusKeychainReader, @unchecked Sendable {
    private let lock = NSLock()
    private let answers: [String: TablePlusPasswordResult]
    private var asked: [String] = []

    public init(_ answers: [String: TablePlusPasswordResult]) {
        self.answers = answers
    }

    /// `{"<id>": "password" | {"denied": true} | {"error": "…"}}`; ids not listed are missing.
    public convenience init(fixture data: Data) {
        var answers: [String: TablePlusPasswordResult] = [:]
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (id, value) in object {
                if let text = value as? String {
                    answers[id] = text.isEmpty ? .missing : .found(SensitiveString(text))
                } else if let entry = value as? [String: Any] {
                    if entry["denied"] as? Bool == true { answers[id] = .denied }
                    if let error = entry["error"] as? String { answers[id] = .failed(error) }
                }
            }
        }
        self.init(answers)
    }

    public func databasePassword(forConnection id: String) -> TablePlusPasswordResult {
        lock.lock()
        defer { lock.unlock() }
        asked.append(id)
        return answers[id] ?? .missing
    }

    public var requestedIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return asked
    }
}

// MARK: - Import

/// What an import did, for the sheet's summary. Never holds a password.
public struct TablePlusImportSummary: Sendable, Equatable {
    public struct Entry: Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var details: [String]

        public init(id: String, name: String, details: [String] = []) {
            self.id = id
            self.name = name
            self.details = details
        }
    }

    public var imported: [Entry] = []
    public var updated: [Entry] = []
    public var skipped: [Entry] = []
    /// Imported or updated connections with something to check (a missing password, an
    /// approximation, no SSH).
    public var needsAttention: [Entry] = []
    public var createdProfiles: [Entry] = []
    public var passwordsCopied = 0

    public init() {}
}

/// Applies the user's choices (#188): adds the SSH profiles and saved connections to the
/// library and the copied passwords to the credential store. Nothing connects.
public enum TablePlusImport {
    /// `importedFrom` of a connection imported from TablePlus.
    public static func sourceKey(_ id: String) -> String { "tableplus:" + id }

    /// Reads the passwords for `ids` through `reader` (macOS may ask once per item). Call it
    /// off the main thread.
    public static func readPasswords(_ ids: [String], reader: TablePlusKeychainReader) -> [String: TablePlusPasswordResult] {
        var results: [String: TablePlusPasswordResult] = [:]
        for id in ids { results[id] = reader.databasePassword(forConnection: id) }
        return results
    }

    public struct Outcome: Sendable {
        public var summary: TablePlusImportSummary
        /// Saved connections that were added or replaced (the app forgets their schemas and
        /// password state).
        public var savedConnections: [UUID]
        public var createdProfiles: [UUID]
    }

    public static func apply(_ plan: TablePlusImportPlan, options: TablePlusImportOptions, library: inout TargetLibrary, passwords: [String: TablePlusPasswordResult], credentials: CredentialStore) -> Outcome {
        var summary = TablePlusImportSummary()
        var saved: [UUID] = []
        let original = library
        let work = plan.work(options: options, library: original)
        let workIDs = Set(work.map(\.row.id))

        // Selected rows the import leaves out.
        for row in plan.rows where options.selected.contains(row.id) && !workIDs.contains(row.id) {
            if !row.canImport {
                summary.skipped.append(.init(id: row.id, name: row.source.name, details: [row.reason ?? "It can't be imported."]))
            } else if let existing = plan.duplicate(of: row, scope: options.scope, in: original) {
                let why = existing.importedFrom == row.connection?.importedFrom && existing.importedFrom != nil
                    ? "Imported before as “\(existing.name)”; duplicates are skipped."
                    : "A saved connection named “\(existing.name)” already exists \(existing.isAllTargets ? "for all targets" : "for this target"); duplicates are skipped."
                summary.skipped.append(.init(id: row.id, name: row.source.name, details: [why]))
            }
        }

        // New SSH profiles, one per server.
        var profileFor: [TablePlusSSHServer: UUID] = [:]
        var createdProfiles: [UUID] = []
        for planned in plan.newProfiles(options: options, library: original) {
            library.sshProfiles.append(planned.profile)
            profileFor[planned.server] = planned.profile.id
            createdProfiles.append(planned.profile.id)
            let users = planned.rowIDs.compactMap { plan.row($0)?.source.name }
            summary.createdProfiles.append(.init(id: planned.profile.id.uuidString, name: planned.profile.name, details: ["\(planned.profile.destinationLabel), \(planned.profile.environment.displayName.lowercased()), for \(users.joined(separator: ", "))."] + planned.notes))
        }

        var takenNames: [String: Set<String>] = [:]
        func taken(_ scope: TargetRef?) -> Set<String> {
            takenNames[scope.map(\.stableKey) ?? "*"] ?? Set(library.databaseConnections(scope: scope).map { $0.name.lowercased() })
        }
        func take(_ name: String, _ scope: TargetRef?) {
            var names = taken(scope)
            names.insert(name.lowercased())
            takenNames[scope.map(\.stableKey) ?? "*"] = names
        }

        for (row, existing) in work {
            guard var connection = row.connection else { continue }
            var notes = row.notes
            // Where it opens from: this Mac, directly or through an SSH profile.
            switch plan.sshChoice(for: row, options: options, in: original) {
            case .existing(let id)?:
                connection.connectFrom = .sshTunnel
                connection.sshProfile = id
            case .newProfile?:
                if let ssh = row.source.ssh, let id = profileFor[TablePlusSSHServer(ssh)] {
                    connection.connectFrom = .sshTunnel
                    connection.sshProfile = id
                }
            case .direct?:
                notes.append("Imported without SSH: it connects from this Mac straight to \(connection.location).")
            case nil:
                break
            }
            if connection.usesSSHTunnel, connection.socket != nil {
                if connection.host.isEmpty { connection.host = "127.0.0.1" }
                notes.append("TablePlus uses a socket on the SSH server; the tunnel forwards a host and port, so it connects to \(connection.host):\(connection.effectivePort.map(String.init) ?? "") on the server. Check it.")
                connection.socket = nil
            }
            let scope = existing?.scope ?? options.scope
            connection.scope = scope
            if let existing {
                connection.id = existing.id
                // An update keeps its name unless TablePlus's is free in its scope.
                let others = library.databaseConnections(scope: scope).filter { $0.id != existing.id }.map { $0.name.lowercased() }
                if others.contains(connection.name.lowercased()) { connection.name = existing.name }
            } else {
                let base = connection.name
                connection.name = TablePlusImportPlan.uniqueName(base, taken: taken(scope))
                if connection.name != base { notes.append("Renamed from “\(base)”, which another imported connection has.") }
            }
            let errors = connection.validate(others: library.databaseConnections)
            guard errors.isEmpty else {
                summary.skipped.append(.init(id: row.id, name: row.source.name, details: ["Runlet can't save it as it is: " + errors.map(\.description).joined(separator: " ")]))
                continue
            }
            let stored = library.saveDatabaseConnection(connection)
            take(stored.name, scope)
            saved.append(stored.id)

            func save(_ secret: SensitiveString) {
                do {
                    try credentials.set(secret, for: stored.id, label: "Runlet database: \(stored.name)")
                    summary.passwordsCopied += 1
                } catch {
                    notes.append("Its password couldn't be saved in Runlet's Keychain: \(error)")
                }
            }
            if stored.driver.usesCredentials, let secret = row.source.mongo?.password {
                // #209: a MongoDB connection string's password, like a Keychain item's: copied only
                // when asked, and only into Runlet's Keychain.
                if options.copyPasswords {
                    save(secret)
                } else {
                    notes.append("TablePlus's connection string includes a password; it wasn't copied. Tick “Also copy passwords” to copy it into Runlet's Keychain, or enter it in the editor.")
                }
            } else if options.copyPasswords, stored.driver.usesCredentials {
                switch row.source.hasID ? passwords[row.id] : nil {
                case .found(let secret)? where stored.driver == .mongodb && MongoConnectionString.isConnectionString(secret.revealed()):
                    // TablePlus may keep a MongoDB connection's URL in its Keychain item: copy only
                    // the URL's password, never the URL.
                    if let inner = MongoConnectionString(secret.revealed())?.password {
                        save(inner)
                        notes.append("TablePlus's Keychain item holds a connection string; only its password was copied. Check the host and options in the editor.")
                    } else {
                        notes.append("TablePlus's Keychain item holds a connection string without a password; imported without a password. Check the host and options in the editor.")
                    }
                case .found(let secret)?:
                    save(secret)
                case .missing?:
                    notes.append(existing != nil ? "TablePlus has no saved password for it; its password in Runlet is unchanged." : "Imported without a password: TablePlus has no saved password for it. Enter it in the editor.")
                case .denied?:
                    notes.append("Imported without a password: macOS didn't allow reading TablePlus's Keychain item. Enter it in the editor.")
                case .failed(let why)?:
                    notes.append("Imported without a password: TablePlus's Keychain item couldn't be read (\(why)). Enter it in the editor.")
                case nil:
                    notes.append(row.source.hasID ? "Imported without a password." : "Imported without a password: TablePlus's id is missing, so its Keychain item can't be found.")
                }
            }

            let entry = TablePlusImportSummary.Entry(id: row.id, name: stored.name, details: [Self.detail(stored, library: library)])
            if existing != nil { summary.updated.append(entry) } else { summary.imported.append(entry) }
            if !notes.isEmpty { summary.needsAttention.append(.init(id: row.id, name: stored.name, details: notes)) }
        }
        return Outcome(summary: summary, savedConnections: saved, createdProfiles: createdProfiles)
    }

    /// "pgsql, db.example.com:5432/shop · production · through SSH “bastion”".
    static func detail(_ connection: DatabaseConnection, library: TargetLibrary) -> String {
        var parts = [connection.summary]
        if connection.environmentMarking != .development { parts.append(connection.environmentMarking.displayName.lowercased()) }
        if connection.readOnly { parts.append("read-only") }
        if let profile = library.tunnelProfile(of: connection) { parts.append("through SSH “\(profile.name)”") }
        return parts.joined(separator: " · ")
    }
}
