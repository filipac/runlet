import Foundation

/// TablePlus's saved connections, as Import from TablePlus… (#188) reads them.
///
/// TablePlus keeps its connection list in `~/Library/Application Support/com.tinyapp.TablePlus/
/// Data/Connections.plist` (`com.tinyapp.TablePlus-setapp` for the Setapp edition) and its
/// groups in `ConnectionGroups.plist` next to it. Neither format is documented, so the keys
/// come from public sources (TablePlus's docs and open-source tools that read or write the
/// file; the pull request of #188 lists them), and the parser is defensive: unknown keys are
/// ignored, a missing field leaves a note, values may be strings or numbers, and nothing in
/// the file can make it crash. Passwords are never in these files: TablePlus keeps them in
/// the Keychain (`TablePlusKeychainReader`).
public struct TablePlusConnection: Sendable, Hashable, Identifiable {
    /// TablePlus's own id (`ID`, a UUID string). Imported connections remember it
    /// (`DatabaseConnection.importedFrom`) so a later import finds them again. A connection
    /// without one gets `#<index>` and can't be found again by id.
    public var id: String
    public var hasID: Bool
    /// `ConnectionName`.
    public var name: String
    /// `Driver`, as TablePlus spells it ("MySQL", "PostgreSQL", "SQLite", "Redis", …).
    public var driver: String
    /// `DatabaseHost`; with SSH, the host as the SSH server sees it.
    public var host: String
    /// `DatabasePort` (a string in the files seen; empty for the default).
    public var port: Int?
    /// `DatabaseName`.
    public var database: String
    /// `DatabaseUser`.
    public var user: String
    /// `DatabasePath`: an SQLite file.
    public var path: String?
    /// `DatabaseSocket`, when `isUseSocket` is on.
    public var socket: String?
    /// The TablePlus group (`GroupID` resolved through `ConnectionGroups.plist`), nested
    /// groups joined with " / ".
    public var group: String?
    /// The environment tag (`Enviroment`, spelled so by TablePlus; `Environment` is read too):
    /// local, development, testing, staging, production.
    public var environment: String?
    /// `statusColor`: `#RRGGBB`.
    public var statusColor: String?
    /// `isOverSSH` with `ServerAddress`, `ServerPort`, `ServerUser`, and the key settings.
    public var ssh: TablePlusSSH?
    /// `tLSMode`: the index of TablePlus's TLS menu, which differs per driver.
    public var tlsMode: Int?
    /// `TlsKeyPaths`: TLS key and certificate files. Runlet doesn't copy them.
    public var tlsKeyPaths: [String]
    /// `SafeModeLevel` / `safeModeLevel`, when present (its levels aren't documented).
    public var safeModeLevel: Int?
    /// An explicit read-only switch (`isReadOnly` / `ReadOnly`), when present.
    public var readOnly: Bool?
    /// What the entry was missing or had in a shape Runlet doesn't read.
    public var problems: [String]

    public init(id: String, hasID: Bool = true, name: String, driver: String, host: String = "", port: Int? = nil, database: String = "", user: String = "", path: String? = nil, socket: String? = nil, group: String? = nil, environment: String? = nil, statusColor: String? = nil, ssh: TablePlusSSH? = nil, tlsMode: Int? = nil, tlsKeyPaths: [String] = [], safeModeLevel: Int? = nil, readOnly: Bool? = nil, problems: [String] = []) {
        self.id = id
        self.hasID = hasID
        self.name = name
        self.driver = driver
        self.host = host
        self.port = port
        self.database = database
        self.user = user
        self.path = path
        self.socket = socket
        self.group = group
        self.environment = environment
        self.statusColor = statusColor
        self.ssh = ssh
        self.tlsMode = tlsMode
        self.tlsKeyPaths = tlsKeyPaths
        self.safeModeLevel = safeModeLevel
        self.readOnly = readOnly
        self.problems = problems
    }

    /// "db.example.com:5432", the SQLite file, or the socket.
    public var location: String {
        if let path, !path.isEmpty, host.isEmpty { return path }
        if let socket, !socket.isEmpty { return "socket \(socket)" }
        let address = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return port.map { "\(address):\($0)" } ?? address
    }
}

/// A TablePlus connection's SSH settings. Its password or key passphrase is never read.
public struct TablePlusSSH: Sendable, Hashable {
    public enum Login: Sendable, Hashable {
        /// `isUsePrivateKey`: a key file. `path` when TablePlus stores a path
        /// (`ServerPrivateKeyName` starting with `/` or `~/`), else only its name.
        case key(path: String?, name: String?)
        /// TablePlus's default: an SSH password (in TablePlus's Keychain item, never read).
        case password
        /// An SSH agent (`isUseSSHAgent` and similar keys, when present).
        case agent
    }

    /// `ServerAddress`.
    public var host: String
    /// `ServerPort`; nil is 22.
    public var port: Int?
    /// `ServerUser`.
    public var user: String?
    public var login: Login

    public init(host: String, port: Int? = nil, user: String? = nil, login: Login = .password) {
        self.host = host
        self.port = port
        self.user = user
        self.login = login
    }

    /// "deploy@bastion.example.com:2222".
    public var destination: String {
        let base = (user?.isEmpty == false ? "\(user!)@" : "") + host
        return port.map { $0 == 22 ? base : "\(base):\($0)" } ?? base
    }
}

/// Reads `Connections.plist` and `ConnectionGroups.plist` (#188).
public enum TablePlusParser {
    /// Larger files aren't read (a connection list is a few kilobytes per connection).
    public static let maximumFileSize = 32 << 20
    /// At most this many connections are listed.
    public static let maximumConnections = 5000

    public struct Result: Sendable, Equatable {
        public var connections: [TablePlusConnection]
        /// Problems with the file as a whole (not a property list, entries that aren't
        /// connections, too many entries).
        public var problems: [String]

        public init(connections: [TablePlusConnection] = [], problems: [String] = []) {
            self.connections = connections
            self.problems = problems
        }
    }

    /// The connections in `connections` (the contents of `Connections.plist`, or a copy of
    /// it), with groups from `groups` (`ConnectionGroups.plist`) when given.
    public static func parse(connections data: Data, groups: Data? = nil) -> Result {
        guard data.count <= maximumFileSize else {
            return Result(problems: ["The file is larger than \(maximumFileSize >> 20) MB, so it isn't a TablePlus connection list."])
        }
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return Result(problems: ["The file isn't a property list. Choose TablePlus's Connections.plist (a .tableplusconnection export is encrypted, and Runlet can't read it)."])
        }
        let entries: [Any]
        if let array = root as? [Any] {
            entries = array
        } else if let dictionary = root as? [String: Any], let array = (dictionary["Connections"] ?? dictionary["connections"]) as? [Any] {
            entries = array
        } else {
            return Result(problems: ["The file is a property list, but not a list of connections."])
        }
        let groupInfo = groupPaths(groups)
        var result = Result()
        var skipped = 0
        for (index, entry) in entries.enumerated() {
            guard result.connections.count < maximumConnections else {
                result.problems.append("Only the first \(maximumConnections) connections are listed.")
                break
            }
            guard let dictionary = entry as? [String: Any] else {
                skipped += 1
                continue
            }
            result.connections.append(connection(dictionary, index: index, groups: groupInfo))
        }
        if skipped > 0 {
            result.problems.append(skipped == 1 ? "1 entry isn't a connection and was left out." : "\(skipped) entries aren't connections and were left out.")
        }
        return result
    }

    /// Group id → "Parent / Child", and connection id → group id for groups that list their
    /// connections (`Connections`).
    struct Groups {
        var paths: [String: String] = [:]
        var members: [String: String] = [:]
    }

    static func groupPaths(_ data: Data?) -> Groups {
        guard let data, data.count <= maximumFileSize,
              let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return Groups() }
        let entries = (root as? [Any]) ?? ((root as? [String: Any])?["Groups"] as? [Any]) ?? []
        var names: [String: String] = [:]
        var parents: [String: String] = [:]
        var groups = Groups()
        for case let entry as [String: Any] in entries {
            guard let id = string(entry["ID"]), !id.isEmpty else { continue }
            names[id] = clean(string(entry["Name"]) ?? "")
            if let parent = string(entry["GroupID"]), !parent.isEmpty, parent != id { parents[id] = parent }
            for case let member in (entry["Connections"] as? [Any]) ?? [] {
                if let member = string(member) { groups.members[member] = id }
            }
        }
        for id in names.keys {
            var parts: [String] = []
            var current: String? = id
            var seen: Set<String> = []
            while let group = current, !seen.contains(group), parts.count < 16 {
                seen.insert(group)
                if let name = names[group], !name.isEmpty { parts.insert(name, at: 0) }
                current = parents[group]
            }
            if !parts.isEmpty { groups.paths[id] = parts.joined(separator: " / ") }
        }
        return groups
    }

    static func connection(_ entry: [String: Any], index: Int, groups: Groups) -> TablePlusConnection {
        var problems: [String] = []
        let rawID = string(entry["ID"]).map(clean) ?? ""
        let hasID = !rawID.isEmpty
        if !hasID { problems.append("TablePlus's id is missing, so a later import can't recognise it.") }
        let driver = clean(string(entry["Driver"]) ?? string(entry["DatabaseType"]) ?? "")
        if driver.isEmpty { problems.append("The driver is missing.") }
        var name = clean(string(entry["ConnectionName"]) ?? "")
        if name.isEmpty {
            problems.append("The name is missing.")
            name = "Unnamed connection \(index + 1)"
        }
        var connection = TablePlusConnection(id: hasID ? rawID : "#\(index)", hasID: hasID, name: name, driver: driver)
        connection.host = clean(string(entry["DatabaseHost"]) ?? "")
        connection.database = clean(string(entry["DatabaseName"]) ?? "")
        connection.user = clean(string(entry["DatabaseUser"]) ?? "")
        if let raw = entry["DatabasePort"], let text = string(raw).map(clean), !text.isEmpty {
            if let port = Int(text), (1...65535).contains(port) {
                connection.port = port
            } else {
                problems.append("The port “\(text.prefix(20))” isn't a number from 1 to 65535; the driver's default is used.")
            }
        }
        if let path = string(entry["DatabasePath"]).map(clean), !path.isEmpty { connection.path = path }
        if bool(entry["isUseSocket"]) == true, let socket = string(entry["DatabaseSocket"]).map(clean), !socket.isEmpty {
            connection.socket = socket
        }
        let groupID = string(entry["GroupID"]).map(clean).flatMap { $0.isEmpty ? nil : $0 } ?? (hasID ? groups.members[rawID] : nil)
        if let groupID { connection.group = groups.paths[groupID] }
        connection.environment = (string(entry["Enviroment"]) ?? string(entry["Environment"])).map(clean).flatMap { $0.isEmpty ? nil : $0 }
        connection.statusColor = string(entry["statusColor"]).map(clean).flatMap { $0.isEmpty ? nil : $0 }
        connection.tlsMode = int(entry["tLSMode"])
        connection.tlsKeyPaths = ((entry["TlsKeyPaths"] as? [Any]) ?? []).compactMap { string($0).map(clean) }.filter { !$0.isEmpty }
        connection.safeModeLevel = int(entry["SafeModeLevel"]) ?? int(entry["safeModeLevel"])
        connection.readOnly = bool(entry["isReadOnly"]) ?? bool(entry["ReadOnly"]) ?? bool(entry["readOnly"])
        if bool(entry["isOverSSH"]) == true {
            let host = clean(string(entry["ServerAddress"]) ?? "")
            if host.isEmpty {
                problems.append("TablePlus connects over SSH, but the SSH server's address is missing.")
            } else {
                var ssh = TablePlusSSH(host: host)
                if let text = string(entry["ServerPort"]).map(clean), !text.isEmpty {
                    if let port = Int(text), (1...65535).contains(port) {
                        ssh.port = port
                    } else {
                        problems.append("The SSH port “\(text.prefix(20))” isn't a number from 1 to 65535; 22 is used.")
                    }
                }
                ssh.user = string(entry["ServerUser"]).map(clean).flatMap { $0.isEmpty ? nil : $0 }
                if bool(entry["isUsePrivateKey"]) == true {
                    let key = string(entry["ServerPrivateKeyName"]).map(clean).flatMap { $0.isEmpty ? nil : $0 }
                    let isPath = key.map { $0.hasPrefix("/") || $0.hasPrefix("~/") } ?? false
                    ssh.login = .key(path: isPath ? key : nil, name: isPath ? nil : key)
                } else if bool(entry["isUseSSHAgent"]) == true || bool(entry["isUseAgent"]) == true || bool(entry["ServerUseAgent"]) == true {
                    ssh.login = .agent
                }
                connection.ssh = ssh
            }
        }
        connection.problems = problems
        return connection
    }

    // MARK: Values

    /// A string from a string or a number.
    static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: text
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: number.intValue
        case let text as String: Int(text.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    /// true/false from a Bool, a number (0 or not), or a string ("1", "true", "yes").
    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let number as NSNumber: number.boolValue
        case let text as String:
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "1", "true", "yes": true
            case "0", "false", "no", "": false
            default: nil
            }
        default: nil
        }
    }

    /// Trimmed, without control characters, at most 4096 characters.
    static func clean(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "\u{2028}" && $0 != "\u{2029}" }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces).prefix(4096).description
    }
}
