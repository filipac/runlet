import Foundation

/// A MongoDB connection string (#209): `mongodb://[user[:password]@]host[:port][,host[:port]…]
/// [/[database]][?options]`, or `mongodb+srv://[user[:password]@]host[/[database]][?options]`, as
/// MongoDB's connection string specification describes it. TablePlus connects to MongoDB with a
/// connection URL (its maintainers say so in TablePlus's issues #1050 and #1005), so Import from
/// TablePlus reads one into a saved connection's fields. Runlet never stores the string itself.
///
/// The password, when there is one, is kept only as a `SensitiveString` for the import's password
/// opt-in. Values of options that can carry a secret aren't kept, and problems never quote the
/// string or any part of it.
public struct MongoConnectionString: Sendable, Hashable {
    public struct Host: Sendable, Hashable {
        /// Without brackets for an IPv6 address.
        public var host: String
        public var port: Int?

        public init(host: String, port: Int? = nil) {
            self.host = host
            self.port = port
        }

        /// "mongo-1.example.com:27018", "[::1]:27017".
        public var label: String {
            let address = host.contains(":") ? "[\(host)]" : host
            return port.map { "\(address):\($0)" } ?? address
        }
    }

    /// `mongodb+srv`.
    public var srv = false
    /// The seed list, in order.
    public var hosts: [Host] = []
    public var user: String?
    public var password: SensitiveString?
    /// The path's database (also the authentication database when `authSource` isn't given).
    public var database: String?
    /// Options by lower-cased name, values percent-decoded. An option whose value can carry a
    /// secret (`authMechanismProperties`, `tlsCertificateKeyFilePassword`, …) keeps an empty value.
    public var options: [String: String] = [:]
    /// The options' names as written, in order (for notes).
    public var optionNames: [String] = []
    /// What couldn't be read. Never quotes the string.
    public var problems: [String] = []

    public static let maximumLength = 8192
    static let maximumHosts = 64
    static let maximumOptions = 64

    /// Whether `text` starts with `mongodb://` or `mongodb+srv://` (any case).
    public static func isConnectionString(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(16).lowercased()
        return lower.hasPrefix("mongodb://") || lower.hasPrefix("mongodb+srv://")
    }

    /// nil when `text` isn't a MongoDB connection string. A string Runlet can't read gives no
    /// hosts and a problem.
    public init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isConnectionString(text) else { return nil }
        srv = text.lowercased().hasPrefix("mongodb+srv://")
        guard text.count <= Self.maximumLength else {
            problems.append("TablePlus's connection string is longer than \(Self.maximumLength) characters, so Runlet doesn't read it.")
            return
        }
        guard let schemeEnd = text.range(of: "://") else { return }
        let rest = text[schemeEnd.upperBound...]

        // The hosts end at the first "/"; the user name and password are before the last "@" there.
        let slash = rest.firstIndex(of: "/")
        var authority = slash.map { rest[..<$0] } ?? rest
        var tail: Substring = slash.map { rest[rest.index(after: $0)...] } ?? ""
        var userinfo: Substring?
        if let at = authority.lastIndex(of: "@") {
            userinfo = authority[..<at]
            authority = authority[authority.index(after: at)...]
        }
        var query: Substring?
        // Options right after the hosts, without the "/" the specification asks for.
        if let mark = authority.firstIndex(of: "?") {
            query = authority[authority.index(after: mark)...]
            authority = authority[..<mark]
        } else if let mark = tail.firstIndex(of: "?") {
            query = tail[tail.index(after: mark)...]
            tail = tail[..<mark]
        }
        // An "@" after the hosts means a user name or password with an unencoded "/": read
        // nothing rather than take part of it for a database or an option.
        if tail.contains("@") || (query?.contains("@") ?? false) {
            problems.append(Self.unreadable)
            return
        }

        if let userinfo {
            let parts = userinfo.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let name = Self.decoded(parts[0])
            user = name.isEmpty ? nil : TablePlusParser.clean(name)
            if parts.count > 1 {
                let secret = Self.decoded(parts[1], clean: false)
                password = secret.isEmpty ? nil : SensitiveString(secret)
            }
        }

        let (hosts, hostProblems) = Self.hosts(authority)
        self.hosts = hosts
        problems += hostProblems
        if hosts.isEmpty, hostProblems.isEmpty { problems.append("TablePlus's connection string names no host.") }

        let database = Self.decoded(tail)
        self.database = database.isEmpty ? nil : database

        if let query { (options, optionNames) = Self.options(query) }
    }

    static let unreadable = "TablePlus's connection string isn't one Runlet can read (a user name or password with an unencoded “/” or “@”?), so its host and options weren't imported."

    /// "host[:port],host[:port]…", as in a connection string or TablePlus's host field. Unix
    /// sockets (a path) are left out with a note.
    static func hosts<S: StringProtocol>(_ list: S) -> (hosts: [Host], problems: [String]) {
        var hosts: [Host] = []
        var problems: [String] = []
        var badPort = false
        for item in list.split(separator: ",").prefix(maximumHosts) {
            let entry = decoded(item.trimmingCharacters(in: .whitespaces))
            guard !entry.isEmpty else { continue }
            if entry.hasPrefix("/") || entry.hasSuffix(".sock") {
                problems.append("TablePlus connects through a Unix socket; Runlet's MongoDB connections connect to a host and port.")
                continue
            }
            var host = entry
            var port: Substring?
            if entry.hasPrefix("[") {
                guard let close = entry.firstIndex(of: "]") else {
                    problems.append("A host in TablePlus's MongoDB settings isn't one Runlet can read.")
                    continue
                }
                host = String(entry[entry.index(after: entry.startIndex)..<close])
                let after = entry[entry.index(after: close)...]
                if after.hasPrefix(":") { port = after.dropFirst() }
            } else if entry.filter({ $0 == ":" }).count == 1, let colon = entry.firstIndex(of: ":") {
                host = String(entry[..<colon])
                port = entry[entry.index(after: colon)...]
            }
            var number: Int?
            if let port, !port.isEmpty {
                if let value = Int(port), (1...65535).contains(value) {
                    number = value
                } else {
                    badPort = true
                }
            }
            if !host.isEmpty { hosts.append(Host(host: TablePlusParser.clean(host), port: number)) }
        }
        if badPort { problems.append("A port in TablePlus's MongoDB settings isn't a number from 1 to 65535; the default is used.") }
        return (hosts, problems)
    }

    /// Option names whose values can carry a secret: their values aren't kept.
    static func isSecretOption(_ name: String) -> Bool {
        name == "authmechanismproperties" || name.contains("password") || name.contains("secret") || name.contains("token") || name == "pwd"
    }

    /// "name=value&name=value" (or ";"-separated): values by lower-cased name, and the names as
    /// written. Only option-like names (letters, digits, "_") are read.
    static func options<S: StringProtocol>(_ query: S) -> (options: [String: String], names: [String]) {
        var options: [String: String] = [:]
        var names: [String] = []
        for pair in query.split(whereSeparator: { $0 == "&" || $0 == ";" }).prefix(maximumOptions) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = decoded(parts[0])
            guard name.count <= 64, name.range(of: #"^[A-Za-z][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else { continue }
            let key = name.lowercased()
            let value = isSecretOption(key) || parts.count < 2 ? "" : decoded(parts[1])
            if options[key] == nil { names.append(name) }
            options[key] = value
        }
        return (options, names)
    }

    /// Percent-decoded (as written when it isn't valid percent-encoding).
    static func decoded<S: StringProtocol>(_ text: S, clean: Bool = true) -> String {
        let value = String(text).removingPercentEncoding ?? String(text)
        return clean ? TablePlusParser.clean(value) : value
    }

    /// `true`/`false` (also `1`/`0`, `yes`/`no`) of an option.
    public func flag(_ name: String) -> Bool? { Self.flag(name, in: options) }

    static func flag(_ name: String, in options: [String: String]) -> Bool? {
        guard let value = options[name.lowercased()], !value.isEmpty else { return nil }
        return TablePlusParser.bool(value)
    }

    /// A non-empty option.
    static func value(_ name: String, in options: [String: String]) -> String? {
        options[name.lowercased()].flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// A TablePlus MongoDB connection's settings beyond host, port, database, and user (#209), from
/// its connection string or its fields. Read only for MongoDB connections.
public struct TablePlusMongo: Sendable, Hashable {
    /// `mongodb+srv`.
    public var srv = false
    /// Whether the settings came from a connection string.
    public var fromConnectionString = false
    /// The seed list's other hosts ("host:port"); the connection uses the first.
    public var moreHosts: [String] = []
    public var authSource: String?
    public var authMechanism: String?
    public var replicaSet: String?
    public var readPreference: String?
    /// `tls=` or `ssl=`.
    public var tls: Bool?
    /// `tlsInsecure`, `tlsAllowInvalidCertificates`, or `tlsAllowInvalidHostnames`.
    public var tlsInsecure = false
    /// `tlsCAFile` or `tlsCertificateKeyFile` (their paths aren't kept).
    public var tlsFiles = false
    /// The connection string's other options, by name (their values aren't kept).
    public var otherOptions: [String] = []
    /// The connection string's password. The import copies it, into Runlet's Keychain only, when
    /// the user ticks "Also copy passwords"; nothing else reads it.
    public var password: SensitiveString?

    public init(srv: Bool = false, fromConnectionString: Bool = false, moreHosts: [String] = [], authSource: String? = nil, authMechanism: String? = nil, replicaSet: String? = nil, readPreference: String? = nil, tls: Bool? = nil, tlsInsecure: Bool = false, tlsFiles: Bool = false, otherOptions: [String] = [], password: SensitiveString? = nil) {
        self.srv = srv
        self.fromConnectionString = fromConnectionString
        self.moreHosts = moreHosts
        self.authSource = authSource
        self.authMechanism = authMechanism
        self.replicaSet = replicaSet
        self.readPreference = readPreference
        self.tls = tls
        self.tlsInsecure = tlsInsecure
        self.tlsFiles = tlsFiles
        self.otherOptions = otherOptions
        self.password = password
    }

    /// Options the import maps, and ones it drops without a note (the driver's defaults do).
    static let mappedOptions: Set<String> = ["authsource", "authmechanism", "replicaset", "readpreference", "tls", "ssl", "tlsinsecure", "tlsallowinvalidcertificates", "tlsallowinvalidhostnames", "tlscafile", "tlscertificatekeyfile", "tlscertificatekeyfilepassword", "sslcafile", "sslpemkeyfile", "sslpemkeypassword"]
    static let quietOptions: Set<String> = ["retrywrites", "retryreads", "w", "wtimeoutms", "journal", "appname", "connecttimeoutms", "sockettimeoutms", "serverselectiontimeoutms", "maxpoolsize", "minpoolsize", "maxidletimems", "waitqueuetimeoutms", "heartbeatfrequencyms", "localthresholdms", "compressors", "zlibcompressionlevel"]
}

extension TablePlusParser {
    /// Keys TablePlus might keep a MongoDB connection's URL under. TablePlus's MongoDB settings
    /// aren't documented; none of these is confirmed, so the import also reads a URL in
    /// `DatabaseHost` and the fields.
    static let mongoURLKeys = ["DatabaseURL", "DatabaseUrl", "DatabaseURI", "DatabaseUri", "ConnectionURL", "ConnectionUrl", "ConnectionString", "URL", "Url", "URI", "Uri"]

    /// A MongoDB connection's settings (#209): from its connection string (a URL key, or a URL in
    /// `DatabaseHost`), else from its fields, where the host may hold a seed list and options
    /// after "?". Fills `connection`'s host, port, database, and user from the string.
    static func readMongo(_ entry: [String: Any], into connection: inout TablePlusConnection, problems: inout [String]) {
        func text(_ keys: [String]) -> String? {
            keys.lazy.compactMap { string(entry[$0]).map(clean) }.first { !$0.isEmpty }
        }
        // Unconfirmed field keys, read defensively; a connection string's options win.
        var mongo = TablePlusMongo(
            srv: ["isUseSRV", "isSRV", "UseSRV", "isUseSrv"].contains { bool(entry[$0]) == true },
            authSource: text(["AuthSource", "authSource", "AuthDatabase", "DatabaseAuthSource"]),
            authMechanism: text(["AuthMechanism", "authMechanism"]),
            replicaSet: text(["ReplicaSet", "replicaSet"]),
            readPreference: text(["ReadPreference", "readPreference"]))

        // The raw values, not cleaned: a password may hold any character.
        let rawURL = mongoURLKeys.lazy.compactMap { string(entry[$0]) }.first { MongoConnectionString.isConnectionString($0) }
        let rawHost = string(entry["DatabaseHost"]) ?? ""
        var uri: MongoConnectionString?
        if let rawURL {
            uri = MongoConnectionString(rawURL)
            // TablePlus's host field may also hold the URL, or a host: the URL's hosts win.
            if MongoConnectionString.isConnectionString(rawHost) { connection.host = "" }
        } else if MongoConnectionString.isConnectionString(rawHost) {
            uri = MongoConnectionString(rawHost)
            connection.host = ""
        }

        if let uri {
            mongo.fromConnectionString = true
            mongo.srv = mongo.srv || uri.srv
            problems += uri.problems
            mongo.password = uri.password
            if let first = uri.hosts.first {
                connection.host = first.host
                if let port = first.port { connection.port = port }
                mongo.moreHosts = uri.hosts.dropFirst().map(\.label)
            } else if !uri.problems.isEmpty {
                connection.host = ""
                connection.port = nil
            }
            if let user = uri.user { connection.user = user }
            if let database = uri.database { connection.database = database }
            let options = uri.options
            func option(_ name: String) -> String? { MongoConnectionString.value(name, in: options) }
            // Without authSource, MongoDB authenticates against the path's database (else admin).
            mongo.authSource = option("authsource") ?? mongo.authSource ?? (uri.user != nil && !uri.srv ? uri.database : nil)
            mongo.authMechanism = option("authmechanism") ?? mongo.authMechanism
            mongo.replicaSet = option("replicaset") ?? mongo.replicaSet
            mongo.readPreference = option("readpreference") ?? mongo.readPreference
            mongo.tls = uri.flag("tls") ?? uri.flag("ssl")
            mongo.tlsInsecure = ["tlsInsecure", "tlsAllowInvalidCertificates", "tlsAllowInvalidHostnames"].contains { uri.flag($0) == true }
            mongo.tlsFiles = ["tlscafile", "tlscertificatekeyfile", "sslcafile", "sslpemkeyfile"].contains { options[$0] != nil }
            mongo.otherOptions = uri.optionNames.filter {
                let key = $0.lowercased()
                return !TablePlusMongo.mappedOptions.contains(key) && !TablePlusMongo.quietOptions.contains(key)
            }
        } else if connection.host.contains("@") {
            // "user:password@host" in the host field: never take part of it for the host.
            problems.append("TablePlus's host field isn't one Runlet can read (it holds a user name, and perhaps a password), so the host wasn't imported.")
            connection.host = ""
        } else if !connection.host.isEmpty {
            // A seed list, or options after "?" (as TablePlus's host field has been seen to hold).
            var host = Substring(connection.host)
            if let mark = host.firstIndex(of: "?") {
                let options = MongoConnectionString.options(host[host.index(after: mark)...]).options
                host = host[..<mark]
                mongo.authSource = MongoConnectionString.value("authSource", in: options) ?? mongo.authSource
                mongo.replicaSet = MongoConnectionString.value("replicaSet", in: options) ?? mongo.replicaSet
                mongo.readPreference = MongoConnectionString.value("readPreference", in: options) ?? mongo.readPreference
                mongo.authMechanism = MongoConnectionString.value("authMechanism", in: options) ?? mongo.authMechanism
                mongo.tls = MongoConnectionString.flag("tls", in: options) ?? MongoConnectionString.flag("ssl", in: options)
            }
            if host.contains(",") || host.contains(":") || host.hasPrefix("[") {
                let (hosts, hostProblems) = MongoConnectionString.hosts(host)
                problems += hostProblems
                if let first = hosts.first {
                    connection.host = first.host
                    if let port = first.port { connection.port = port }
                    mongo.moreHosts = hosts.dropFirst().map(\.label)
                } else {
                    connection.host = ""
                }
            } else {
                connection.host = String(host)
            }
        }
        if mongo.srv {
            if connection.port != nil {
                problems.append("An SRV connection has no port (DNS names the servers), so TablePlus's port is left out.")
                connection.port = nil
            }
            if !mongo.moreHosts.isEmpty {
                problems.append("An SRV connection names one host; Runlet uses the first, \(connection.host).")
                mongo.moreHosts = []
            }
        }
        connection.mongo = mongo
    }
}
