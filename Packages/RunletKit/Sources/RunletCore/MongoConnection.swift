import Foundation

public struct MongoConnectionOptions: Sendable, Codable, Hashable {
    public var srv = false
    public var authDatabase = "admin"
    public var authMechanism = ""
    public var replicaSet = ""
    public var readPreference = "primary"

    public init() {}

    /// SCRAM with a password, or X.509 with the TLS client certificate (#207).
    public static let mechanisms = ["", "SCRAM-SHA-1", "SCRAM-SHA-256", x509]
    public static let x509 = "MONGODB-X509"

    /// X.509 authenticates with the client certificate: TLS on, and a certificate file.
    public func x509Problem(tls: DatabaseTLS?) -> String? {
        guard authMechanism == Self.x509 else { return nil }
        guard let tls, tls.mode != .disable, tls.certificateFile != nil else {
            return "X.509 authentication needs TLS with a client certificate."
        }
        return nil
    }

    public func problem(tunnel: Bool, port: Int?) -> String? {
        if srv && (tunnel || port != nil) { return "SRV cannot use a port or SSH tunnel. Use a direct host for tunnels." }
        if !Self.mechanisms.contains(authMechanism) { return "Choose a supported authentication mechanism." }
        if !["primary", "primaryPreferred", "secondary", "secondaryPreferred", "nearest"].contains(readPreference) { return "Choose a supported read preference." }
        for value in [authDatabase, replicaSet] {
            if value.count > 120 || value.range(of: #"^[A-Za-z0-9_.-]*$"#, options: .regularExpression) == nil { return "Authentication database and replica set accept letters, numbers, dots, dashes and underscores." }
        }
        return nil
    }
}
