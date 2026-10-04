import Foundation
@testable import RunletCore
import Testing
@testable import RunletExecution

/// MongoDB TLS, X.509, replica sets, and SRV (#207). Live against the `mongo-tls` fixture (TLS
/// required; `RUNLET_TEST_MONGODB_TLS`, with the throwaway certificates of `RUNLET_TEST_TLS`) and
/// the single-node replica set `rs0` (`RUNLET_TEST_MONGODB_RS`). SRV needs DNS records, so its
/// URI building is checked without connecting. Data lives in `p207_` collections.
@Suite(.serialized, .enabled(if: TestSupport.hasPHP))
struct MongoTLSLiveTests {
    static let environment = ProcessInfo.processInfo.environment
    static var tlsFolder: URL? { environment["RUNLET_TEST_TLS"].map { URL(fileURLWithPath: $0) } }
    static var hasTLS: Bool { environment["RUNLET_TEST_MONGODB_TLS"] != nil && tlsFolder != nil }
    static var hasReplicaSet: Bool { environment["RUNLET_TEST_MONGODB_RS"] != nil }

    /// The TLS fixture as a saved connection: TLS verified against the fixture CA.
    static func tlsConnection(mode: DatabaseTLSMode = .verifyFull, ca: String? = "ca.crt", cert: String? = nil, key: String? = nil, x509: Bool = false) throws -> (DatabaseConnection, String) {
        let parts = try #require(environment["RUNLET_TEST_MONGODB_TLS"]).components(separatedBy: "|")
        let url = try #require(URLComponents(string: parts[0]))
        let folder = try #require(tlsFolder)
        var connection = DatabaseConnection(name: "Mongo TLS fixture", scope: .local(UUID()), driver: .mongodb, host: "127.0.0.1", port: url.port, database: "p207_tests", user: x509 ? "" : parts[1])
        connection.tls = DatabaseTLS(mode: mode, caFile: ca.map { folder.appendingPathComponent($0).path }, certificateFile: cert.map { folder.appendingPathComponent($0).path }, keyFile: key.map { folder.appendingPathComponent($0).path })
        var mongo = MongoConnectionOptions()
        if x509 { mongo.authMechanism = MongoConnectionOptions.x509 }
        connection.mongo = mongo
        connection.connectTimeout = 3
        return (connection.normalized, x509 ? "" : parts[2])
    }

    static func run(_ json: String, _ connection: DatabaseConnection, password: String, target: TargetSnapshot? = nil, confirmed: Bool = false) async throws -> [RunEvent] {
        let directory = try DriverSupport.temporaryDirectory("mongo-tls")
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try MongoServerLiveTests.engine(connection, password: password)
        return try await MongoServerLiveTests.run(json, connection: connection, target: target ?? DriverSupport.target(directory.path), engine: engine, confirmed: confirmed)
    }

    static let roundTrip = #"{"collection":"p207_tls","operation":"find","limit":1}"#

    @Test(.enabled(if: hasTLS, "set RUNLET_TEST_MONGODB_TLS and RUNLET_TEST_TLS (scripts/setup-fixtures.sh databases)"))
    func verifiesTheServerAgainstTheCAFile() async throws {
        let (connection, password) = try Self.tlsConnection()
        #expect(connection.validate().isEmpty, "\(connection.validate())")
        let inserted = try await Self.run(#"{"collection":"p207_tls","operation":"insertOne","documents":[{"tls":true}]}"#, connection, password: password)
        #expect(inserted.errors.isEmpty, "\(inserted.errors)")
        let found = try await Self.run(Self.roundTrip, connection, password: password)
        #expect(found.errors.isEmpty && found.sqlResult?.rows.count == 1, "\(found.errors)")
        #expect(!found.scannableText.joined().contains(password))
        // Verify CA (no host name check) works too.
        let (verifyCA, _) = try Self.tlsConnection(mode: .verifyCA)
        let ca = try await Self.run(Self.roundTrip, verifyCA, password: password)
        #expect(ca.errors.isEmpty, "\(ca.errors)")
    }

    @Test(.enabled(if: hasTLS, "set RUNLET_TEST_MONGODB_TLS and RUNLET_TEST_TLS (scripts/setup-fixtures.sh databases)"))
    func refusesAServerAnotherCASigned() async throws {
        let (wrong, password) = try Self.tlsConnection(ca: "other-ca.crt")
        let events = try await Self.run(Self.roundTrip, wrong, password: password)
        #expect(events.errors.contains { $0.message.contains("MongoDB find failed") }, "\(events.errors)")
        #expect(events.sqlResult == nil)
        #expect(!events.scannableText.joined().contains(password))
        // The server requires TLS: without it, nothing connects.
        let (plain, _) = try Self.tlsConnection(mode: .disable, ca: nil)
        let refused = try await Self.run(Self.roundTrip, plain, password: password)
        #expect(!refused.errors.isEmpty && refused.sqlResult == nil, "\(refused.errors)")
        // A missing CA file says which file, before connecting.
        var (missing, _) = try Self.tlsConnection()
        missing.tls?.caFile = "/nonexistent/p207-ca.crt"
        let unreadable = try await Self.run(Self.roundTrip, missing, password: password)
        #expect(unreadable.errors.contains { $0.message.contains("The TLS CA file isn't readable where the connection opens: /nonexistent/p207-ca.crt") }, "\(unreadable.errors)")
    }

    @Test(.enabled(if: hasTLS, "set RUNLET_TEST_MONGODB_TLS and RUNLET_TEST_TLS (scripts/setup-fixtures.sh databases)"))
    func x509AuthenticatesWithTheClientCertificate() async throws {
        // Certificate and key in two files (the runner combines them into a private temporary file).
        let (separate, _) = try Self.tlsConnection(cert: "client.crt", key: "client.key", x509: true)
        #expect(separate.validate().isEmpty, "\(separate.validate())")
        let found = try await Self.run(Self.roundTrip, separate, password: "")
        #expect(found.errors.isEmpty && found.sqlResult != nil, "\(found.errors)")
        // One PEM with both.
        let folder = try #require(Self.tlsFolder)
        let scratch = try DriverSupport.temporaryDirectory("mongo-x509")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let combined = scratch.appendingPathComponent("client.pem")
        try (try Data(contentsOf: folder.appendingPathComponent("client.crt")) + Data(contentsOf: folder.appendingPathComponent("client.key"))).write(to: combined)
        var (single, _) = try Self.tlsConnection(x509: true)
        single.tls?.certificateFile = combined.path
        single.user = "CN=runlet-fixture-client"
        let listed = try await Self.run(#"{"collection":"metadata","operation":"listDatabases"}"#, single.normalized, password: "")
        #expect(listed.errors.isEmpty && listed.sqlResult?.rows.isEmpty == false, "\(listed.errors)")
        // The server panel reads as the certificate's user (clusterMonitor).
        let engine = try MongoServerLiveTests.engine(separate, password: "")
        let report = try await engine.loadMongoServer(target: DriverSupport.target(scratch.path), connection: nil, saved: separate)
        #expect(report.status?.version?.hasPrefix("7.") == true && report.errors == nil, "\(report)")
        // Without a client certificate, X.509 isn't valid.
        let (noCertificate, _) = try Self.tlsConnection(x509: true)
        #expect(noCertificate.validate().contains(.invalidDSN("X.509 authentication needs TLS with a client certificate.")))
    }

    @Test(.enabled(if: hasTLS && SSHFixture.available, "requires the TLS fixture, Docker, and OpenSSH"))
    func verifiesThroughAnSSHTunnel() async throws {
        var (connection, password) = try Self.tlsConnection()
        connection.name = "Mongo TLS through bastion"
        connection.connectFrom = .sshTunnel
        connection.sshProfile = SQLLiveTunnelTests.profileId
        connection.host = "mongo-tls"
        connection.port = 27017
        connection = connection.normalized
        let bastion = try await SQLLiveTunnelTests.Bastion.open()
        let (lease, target) = try await bastion.lease(connection)
        do {
            // The tunnel connects to 127.0.0.1, which the fixture's certificate names.
            let found = try await Self.run(Self.roundTrip, connection, password: password, target: target)
            #expect(found.errors.isEmpty && found.sqlResult != nil, "\(found.errors)")
        } catch {
            Issue.record("\(error)")
        }
        await bastion.manager.release(lease, cancelWhenUnused: true)
        await bastion.close()
    }

    /// The replica set as a saved connection (no authentication).
    static func replicaSet(_ name: String = "rs0", readPreference: String) throws -> DatabaseConnection {
        let value = try #require(environment["RUNLET_TEST_MONGODB_RS"])
        let url = try #require(URLComponents(string: value))
        var connection = DatabaseConnection(name: "Mongo replica set", scope: .local(UUID()), driver: .mongodb, host: "127.0.0.1", port: url.port, database: "p207_tests", user: "")
        var mongo = MongoConnectionOptions()
        mongo.replicaSet = name
        mongo.readPreference = readPreference
        connection.mongo = mongo
        connection.connectTimeout = 2
        return connection.normalized
    }

    @Test(.enabled(if: hasReplicaSet, "set RUNLET_TEST_MONGODB_RS (scripts/setup-fixtures.sh databases)"))
    func replicaSetDiscoveryAndReadPreferences() async throws {
        let primary = try Self.replicaSet(readPreference: "primary")
        let inserted = try await Self.run(#"{"collection":"p207_rs","operation":"insertOne","documents":[{"rs":true}]}"#, primary, password: "")
        #expect(inserted.errors.isEmpty, "\(inserted.errors)")
        for preference in ["primaryPreferred", "secondaryPreferred", "nearest"] {
            let read = try await Self.run(#"{"collection":"p207_rs","operation":"find","limit":1}"#, try Self.replicaSet(readPreference: preference), password: "")
            #expect(read.errors.isEmpty && read.sqlResult?.rows.count == 1, "\(preference): \(read.errors)")
        }
        // One member, the primary: a secondary-only read finds no server.
        let secondary = try await Self.run(#"{"collection":"p207_rs","operation":"find","limit":1}"#, try Self.replicaSet(readPreference: "secondary"), password: "")
        #expect(!secondary.errors.isEmpty && secondary.sqlResult == nil, "\(secondary.errors)")
        // Another replica set name: the driver refuses the member.
        let other = try await Self.run(#"{"collection":"p207_rs","operation":"find","limit":1}"#, try Self.replicaSet("rs9", readPreference: "primary"), password: "")
        #expect(!other.errors.isEmpty && other.sqlResult == nil, "\(other.errors)")
        // The server panel names the replica set and the member's state.
        let directory = try DriverSupport.temporaryDirectory("mongo-rs")
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try MongoServerLiveTests.engine(primary, password: "")
        let report = try await engine.loadMongoServer(target: DriverSupport.target(directory.path), connection: nil, saved: primary)
        #expect(report.summary.contains("replica set rs0 PRIMARY"), "\(report.summary)")
        #expect(report.replica?.me == "127.0.0.1:27207", "\(String(describing: report.replica))")
    }

    /// SRV can't be tested live without DNS records: the URI and options are checked without connecting.
    @Test func srvAndTLSOptionsWithoutConnecting() async throws {
        let directory = try DriverSupport.temporaryDirectory("mongo-uri")
        defer { try? FileManager.default.removeItem(at: directory) }
        func options(_ definition: String) async throws -> [String: Any] {
            let code = "echo json_encode(\\RunletRunner\\MongoTab::clientOptions(json_decode('\(definition)', true), 'p207-secret'));"
            let request = RunRequest(tabId: UUID(), documentVersion: 1, target: DriverSupport.target(directory.path), code: code, magicComments: false)
            let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
            var events: [RunEvent] = []
            for await event in try await engine.start(request) { events.append(event) }
            withExtendedLifetime(engine) {}
            if !events.errors.isEmpty { return ["error": events.errors[0].message] }
            let decoded = try JSONSerialization.jsonObject(with: Data(events.stdout.utf8))
            let array = try #require(decoded as? [Any])
            var result = try #require(array[1] as? [String: Any])
            result["uri"] = array[0]
            return result
        }
        let srv = try await options(#"{"host":"cluster0.example.net","user":"app","mongo":{"srv":true,"authDatabase":"admin","replicaSet":"","readPreference":"secondaryPreferred"}}"#)
        #expect(srv["uri"] as? String == "mongodb+srv://cluster0.example.net", "\(srv)")
        #expect(srv["readPreference"] as? String == "secondaryPreferred" && srv["username"] as? String == "app" && srv["authSource"] as? String == "admin")
        #expect(srv["tls"] == nil, "SRV turns TLS on by itself")
        let tunnelled = try await options(#"{"host":"cluster0.example.net","mongo":{"srv":true},"tunnel":{"port":40000}}"#)
        #expect(tunnelled["error"] as? String == "SRV cannot use an SSH tunnel.")
        let direct = try await options(#"{"host":"db.internal","port":27018,"tunnel":{"port":40000},"tls":{"mode":"verify-ca","ca":"/etc/hosts"}}"#)
        #expect(direct["uri"] as? String == "mongodb://127.0.0.1:40000" && direct["directConnection"] as? Bool == true)
        #expect(direct["tls"] as? Bool == true && direct["tlsAllowInvalidHostnames"] as? Bool == true && direct["tlsCAFile"] as? String == "/etc/hosts")
        let x509 = try await options(#"{"host":"db.internal","user":"CN=app","mongo":{"authMechanism":"MONGODB-X509"},"tls":{"mode":"verify-full","cert":"/etc/hosts"}}"#)
        #expect(x509["authMechanism"] as? String == "MONGODB-X509" && x509["authSource"] as? String == "$external" && x509["username"] as? String == "CN=app" && x509["password"] == nil)
        #expect(x509["tlsCertificateKeyFile"] as? String == "/etc/hosts")
        let noCertificate = try await options(#"{"host":"db.internal","mongo":{"authMechanism":"MONGODB-X509"},"tls":{"mode":"verify-full"}}"#)
        #expect(noCertificate["error"] as? String == "X.509 authentication needs TLS with a client certificate.")
        let insecure = try await options(#"{"host":"db.internal","tls":{"mode":"require"}}"#)
        #expect(insecure["error"] as? String == "Unsupported MongoDB TLS mode.", "verification is never turned off")
        let ipv6 = try await options(#"{"host":"::1","port":27017}"#)
        #expect(ipv6["uri"] as? String == "mongodb://[::1]:27017")
    }
}
