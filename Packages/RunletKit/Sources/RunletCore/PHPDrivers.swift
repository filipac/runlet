import Foundation

/// What a PHP on this Mac can open connections with (#184): its PDO drivers and the client
/// extensions saved connections use. Read once per installation, with PHP discovery, so a run
/// never probes its PHP.
public struct PHPDrivers: Sendable, Codable, Hashable {
    /// `PDO::getAvailableDrivers()`, lowercased: `mysql`, `pgsql`, `sqlite`, `sqlsrv`, `dblib`,
    /// `oci`, `odbc`, …; empty without PDO.
    public var pdo: [String]
    /// The extensions among `PHPDrivers.extensionNames` it loads.
    public var extensions: [String]

    public init(pdo: [String] = [], extensions: [String] = []) {
        self.pdo = pdo.map { $0.lowercased() }
        self.extensions = extensions.map { $0.lowercased() }
    }

    /// The client extensions worth knowing about: phpredis and the MongoDB driver.
    public static let extensionNames = ["redis", "mongodb"]

    /// PHP that prints this struct as JSON on one line (for `php -r`; PHP 5.4+). It reads the
    /// PHP's own php.ini (extensions load there); the caller turns off auto_prepend_file and
    /// auto_append_file.
    public static let probeCode = "echo json_encode(array('pdo' => class_exists('PDO') ? PDO::getAvailableDrivers() : array(), 'extensions' => array_values(array_filter(array('" + extensionNames.joined(separator: "', '") + "'), 'extension_loaded'))));"

    /// The probe's JSON: the last line of output that decodes (login scripts may print first).
    public static func parse(_ output: String) -> PHPDrivers? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), let drivers = try? JSONDecoder().decode(PHPDrivers.self, from: Data(trimmed.utf8)) else { continue }
            return PHPDrivers(pdo: drivers.pdo, extensions: drivers.extensions)
        }
        return nil
    }
}

/// What a saved connection needs from the PHP that opens it from this Mac (#184).
public enum PHPDriverRequirement: Sendable, Equatable {
    /// Nothing: a Redis connection uses Runlet's own RESP client in the runner.
    case none
    /// One of these PDO drivers, in the runner's order of preference (SQL Server: `sqlsrv`,
    /// else `dblib`).
    case pdo([String])
    /// A PHP extension (`mongodb`).
    case phpExtension(String)

    /// What `connection` needs: `pdo_mysql`, `pdo_pgsql`, `pdo_sqlite`, `pdo_sqlsrv` or
    /// `pdo_dblib`, the driver a custom DSN names (`oci:` needs `pdo_oci`), or ext-mongodb.
    public init(_ connection: DatabaseConnection) {
        switch connection.driver {
        case .mysql: self = .pdo(["mysql"])
        case .pgsql: self = .pdo(["pgsql"])
        case .sqlite: self = .pdo(["sqlite"])
        case .sqlsrv: self = .pdo(["sqlsrv", "dblib"])
        case .custom: self = connection.customDSNDriver.map { .pdo([$0]) } ?? .none
        case .redis: self = .none
        case .mongodb: self = .phpExtension("mongodb")
        }
    }

    /// Whether a PHP with `drivers` has what the connection needs.
    public func isMet(by drivers: PHPDrivers) -> Bool {
        switch self {
        case .none: true
        case .pdo(let names): names.contains { drivers.pdo.contains($0) }
        case .phpExtension(let name): drivers.extensions.contains(name)
        }
    }

    /// "pdo_sqlsrv or pdo_dblib", "pdo_oci", "ext-mongodb"; empty for none.
    public var name: String {
        switch self {
        case .none: ""
        case .pdo(let names): names.map { "pdo_\($0)" }.joined(separator: " or ")
        case .phpExtension(let name): "ext-\(name)"
        }
    }

    /// "has neither pdo_sqlsrv nor pdo_dblib", "have no pdo_oci" (`plural`: several PHPs).
    public func missing(plural: Bool) -> String {
        let verb = plural ? "have" : "has"
        if case .pdo(let names) = self, names.count == 2 {
            return "\(verb) neither pdo_\(names[0]) nor pdo_\(names[1])"
        }
        return "\(verb) no \(name)"
    }
}
