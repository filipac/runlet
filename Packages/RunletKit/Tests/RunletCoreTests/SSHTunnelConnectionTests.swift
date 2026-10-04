import Foundation
import Testing
@testable import RunletCore

/// Saved connections through an SSH profile's tunnel (#143): the definition's storage (older
/// files unchanged, an older Runlet leaving tunnelled ones out), normalization, validation,
/// the "profile missing" state, and production marking with the SSH profile's environment.
struct SSHTunnelConnectionTests {
    static let bastion = SSHProfile(name: "bastion", host: "bastion", remoteDirectory: "/srv/app")

    static func tunnelled(_ name: String = "Shop", scope: TargetRef? = .local(UUID()), profile: UUID? = SSHTunnelConnectionTests.bastion.id, driver: DatabaseDriverKind = .pgsql) -> DatabaseConnection {
        DatabaseConnection(name: name, scope: scope, connectFrom: .sshTunnel, driver: driver, host: driver.usesHost ? "postgres" : "", database: driver == .sqlite ? "/data/a.sqlite" : "shop", user: "reader", sshProfile: profile)
    }

    @Test func tunnelRoundTripsAndOldFilesStayTheSame() throws {
        let connection = Self.tunnelled()
        let data = try JSONEncoder().encode(connection)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["connectFrom"] as? String == "sshTunnel")
        #expect(object["sshProfile"] as? String == Self.bastion.id.uuidString)
        #expect(!object.keys.contains { $0.lowercased().contains("password") })
        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: data)
        #expect(decoded == connection && decoded.usesSSHTunnel && decoded.opensOnThisMac)

        // Connections from before #143 encode exactly as they did: no new keys.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for old in [
            #"{"connectTimeout":10,"database":"reports","driver":"pgsql","host":"postgres","id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Legacy","revision":3,"scope":{"docker":{"_0":"7F9619FF-8B86-D011-B42D-00C04FC964FF"}},"user":"reader"}"#,
            #"{"connectFrom":"mac","connectTimeout":10,"database":"reports","driver":"mysql","host":"127.0.0.1","id":"6F9619FF-8B86-D011-B42D-00C04FC964FE","name":"Mac","port":3307,"revision":1,"scope":{"local":{"_0":"7F9619FF-8B86-D011-B42D-00C04FC964FE"}},"user":"root"}"#,
            #"{"allTargets":true,"connectFrom":"mac","connectTimeout":10,"database":"/tmp/a.sqlite","driver":"sqlite","host":"","id":"6F9619FF-8B86-D011-B42D-00C04FC964FD","name":"Shared","revision":1,"user":""}"#,
        ] {
            let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: Data(old.utf8))
            let encoded = String(decoding: try encoder.encode(decoded), as: UTF8.self)
            #expect(encoded == old)
        }
    }

    @Test func theLibraryKeepsTunnelledConnections() throws {
        var library = TargetLibrary()
        library.sshProfiles = [Self.bastion]
        library.saveDatabaseConnection(Self.tunnelled())
        let reloaded = try JSONDecoder().decode(TargetLibrary.self, from: JSONEncoder().encode(library))
        #expect(reloaded.databaseConnections.first?.usesSSHTunnel == true)
        #expect(reloaded.databaseConnections.first?.sshProfile == Self.bastion.id)
    }

    /// Run History and SQL snippets (#149) find a tunnelled connection by id, then by name, on
    /// the tab's target, and it keeps its tunnel (nothing connects until a run).
    @Test func historyAndSnippetsRestoreATunnelledConnection() {
        var library = TargetLibrary()
        library.sshProfiles = [Self.bastion]
        let project = TargetRef.local(UUID())
        let own = library.saveDatabaseConnection(Self.tunnelled("Shop", scope: project))
        let shared = library.saveDatabaseConnection(Self.tunnelled("Warehouse", scope: nil))

        #expect(library.resolve(SQLConnectionReference(own), on: project) == .saved(own))
        #expect(library.resolve(.saved(name: "shop", id: UUID()), on: project) == .saved(own), "by name when the id is unknown")
        #expect(library.resolve(.named("Warehouse"), on: .sandbox) == .saved(shared), "all targets, the sandbox too")
        #expect(library.resolve(SQLConnectionReference(own), on: .docker(UUID())) == .missing("Shop"), "never another target's own")
        if case .saved(let found) = library.resolve(SQLConnectionReference(own).forSnippet!, on: project) {
            #expect(found.usesSSHTunnel && found.sshProfile == Self.bastion.id)
        } else {
            Issue.record("a snippet's reference finds the connection")
        }
    }

    @Test func normalizationKeepsOnlyWhatATunnelUses() {
        var connection = Self.tunnelled()
        connection.socket = "/var/run/postgresql"
        let normalized = connection.normalized
        #expect(normalized.socket == nil, "a tunnel forwards a host and port")
        #expect(normalized.sshProfile == Self.bastion.id && normalized.host == "postgres")

        var direct = Self.tunnelled()
        direct.connectFrom = .thisMac
        #expect(direct.normalized.sshProfile == nil, "only a tunnel keeps its SSH profile")

        // A connection of all targets can go through a tunnel too; it stays one.
        let shared = Self.tunnelled(scope: nil).normalized
        #expect(shared.connectFrom == .sshTunnel && shared.isAllTargets && shared.opensOnThisMac)
        // Duplicates keep the tunnel.
        let copy = Self.tunnelled().duplicated(named: "Copy", scope: .docker(UUID()))
        #expect(copy.connectFrom == .sshTunnel && copy.sshProfile == Self.bastion.id)
    }

    @Test func validation() {
        #expect(Self.tunnelled().validate().isEmpty)
        #expect(Self.tunnelled(profile: nil).validate().contains(.tunnelWithoutProfile))
        #expect(Self.tunnelled(driver: .sqlite).validate().contains(.tunnelNeedsHost(.sqlite)))
        var custom = Self.tunnelled(driver: .custom)
        custom.dsn = "oci:dbname=//db:1521/XE"
        #expect(custom.validate().contains(.tunnelNeedsHost(.custom)))
        var hostaddr = Self.tunnelled()
        hostaddr.options = [DatabaseOption(key: "hostaddr", value: "10.0.0.5")]
        #expect(hostaddr.validate().contains(.tunnelOption("hostaddr")), "libpq would connect there instead of the tunnel")
        // Without a tunnel, hostaddr stays a plain libpq option.
        hostaddr.connectFrom = .thisMac
        #expect(hostaddr.validate().isEmpty)
        #expect(SSHTunnelConnectionTests.tunnelled(driver: .mysql).validate().isEmpty)
        #expect(DatabaseConnection.ValidationError.tunnelNeedsHost(.sqlite).description.contains("SQLite"))
    }

    @Test func aRemovedProfileLeavesTheConnectionMissingItsTunnel() {
        var library = TargetLibrary()
        library.sshProfiles = [Self.bastion]
        let connection = library.saveDatabaseConnection(Self.tunnelled())
        #expect(library.tunnelProblem(of: connection) == nil)
        #expect(library.tunnelProfile(of: connection)?.name == "bastion")

        library.sshProfiles = []
        let problem = library.tunnelProblem(of: connection) ?? ""
        #expect(problem.contains("was removed") && problem.contains("never picks one by itself"), "\(problem)")
        #expect(library.databaseConnection(connection.id)?.sshProfile == Self.bastion.id, "never retargeted")
        #expect(library.tunnelProblem(of: Self.tunnelled(profile: nil))?.contains("no SSH profile is chosen") == true)
        #expect(library.tunnelProblem(of: LocalConnectionTests.connection()) == nil)
    }

    @Test func productionCountsTheTunnelsProfile() {
        var library = TargetLibrary()
        var production = Self.bastion
        production.environment = .production
        library.sshProfiles = [production]
        let project = TargetRef.local(UUID())
        let connection = Self.tunnelled(scope: project)

        let marking = library.marking(for: project, connection: connection)
        #expect(marking.isProduction && marking.fromTunnel && !marking.fromConnection)

        // The connection's own marking is named when it's at least as strict.
        var marked = connection
        marked.environment = .production
        let both = library.marking(for: project, connection: marked)
        #expect(both.isProduction && both.fromConnection && !both.fromTunnel)

        // Without the tunnel, the profile doesn't count.
        var direct = connection
        direct.connectFrom = .thisMac
        #expect(!library.marking(for: project, connection: direct).isProduction)

        // Staging profile, development connection: staging.
        var staging = Self.bastion
        staging.environment = .staging
        library.sshProfiles = [staging]
        #expect(library.marking(for: project, connection: connection).environment == .staging)
    }

    @Test func routeSummary() {
        let route = SQLTunnelRoute(localPort: 50123, remoteHost: "postgres", remotePort: 5432, profileId: UUID(), profileName: "bastion")
        #expect(route.summary == "127.0.0.1:50123 → postgres:5432 through bastion")
        let v6 = SQLTunnelRoute(localPort: 50124, remoteHost: "fd00::5", remotePort: 3306, profileId: UUID(), profileName: "bastion")
        #expect(v6.summary == "127.0.0.1:50124 → [fd00::5]:3306 through bastion")
    }
}
