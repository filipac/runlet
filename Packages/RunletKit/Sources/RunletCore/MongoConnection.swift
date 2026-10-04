import Foundation

public struct MongoConnectionOptions: Sendable, Codable, Hashable {
    public var srv = false
    public var authDatabase = "admin"
    public var authMechanism = ""
    public var replicaSet = ""
    public var readPreference = "primary"

    public init() {}

    public func problem(tunnel: Bool, port: Int?) -> String? {
        if srv && (tunnel || port != nil) { return "SRV cannot use a port or SSH tunnel. Use a direct host for tunnels." }
        if !["", "SCRAM-SHA-1", "SCRAM-SHA-256", "MONGODB-X509"].contains(authMechanism) { return "Choose a supported authentication mechanism." }
        if !["primary", "primaryPreferred", "secondary", "secondaryPreferred", "nearest"].contains(readPreference) { return "Choose a supported read preference." }
        for value in [authDatabase, replicaSet] {
            if value.count > 120 || value.range(of: #"^[A-Za-z0-9_.-]*$"#, options: .regularExpression) == nil { return "Authentication database and replica set accept letters, numbers, dots, dashes and underscores." }
        }
        return nil
    }
}
