import Foundation
import Testing
@testable import RunletCore

/// Saved connections opened from this Mac, and connections of all targets (#142): the
/// definition's storage (backward compatible), lookup from every target, validation of this
/// Mac's paths, marking, and that nothing written holds a password.
struct LocalConnectionTests {
    static func connection(_ name: String = "Reporting", scope: TargetRef? = .local(UUID()), connectFrom: DatabaseConnectFrom = .target, driver: DatabaseDriverKind = .pgsql) -> DatabaseConnection {
        DatabaseConnection(name: name, scope: scope, connectFrom: connectFrom, driver: driver, host: driver == .sqlite ? "" : "127.0.0.1", port: driver == .pgsql ? 5433 : nil, database: driver == .sqlite ? "/data/app.sqlite" : "reports", user: "reader")
    }

    @Test func allTargetsAndThisMacRoundTrip() throws {
        let shared = Self.connection("Analytics", scope: nil)
        let data = try JSONEncoder().encode(shared)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["allTargets"] as? Bool == true)
        #expect(object["scope"] == nil, "no target, so a Runlet before #142 leaves it out")
        #expect(object["connectFrom"] as? String == "mac", "all targets always open from this Mac")
        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: data)
        #expect(decoded.scope == nil && decoded.isAllTargets && decoded.opensOnThisMac)
        #expect(!object.keys.contains { $0.lowercased().contains("password") })

        let local = Self.connection(scope: .ssh(UUID()), connectFrom: .thisMac)
        let localObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(local)) as? [String: Any])
        #expect(localObject["connectFrom"] as? String == "mac" && localObject["allTargets"] == nil)
        #expect(try JSONDecoder().decode(DatabaseConnection.self, from: JSONEncoder().encode(local)) == local)

        // A target's connection opened by the target's PHP is stored exactly as before #142.
        let plain = Self.connection(scope: .docker(UUID()))
        let plainObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        #expect(plainObject["connectFrom"] == nil && plainObject["allTargets"] == nil && plainObject["scope"] != nil)
    }

    @Test func connectionsSavedBeforeOpenFromTheTarget() throws {
        let old = #"{"id":"\#(UUID().uuidString)","name":"Legacy","scope":{"docker":{"_0":"\#(UUID().uuidString)"}},"driver":"pgsql","host":"postgres"}"#
        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: Data(old.utf8))
        #expect(decoded.connectFrom == .target && !decoded.opensOnThisMac && !decoded.isAllTargets)

        // An unknown place (a newer Runlet's) leaves the connection out instead of opening it
        // somewhere else; the rest of the library still loads.
        let library = #"{"localProjects":[],"dockerProfiles":[],"sshProfiles":[],"databaseConnections":[\#(old),{"id":"\#(UUID().uuidString)","name":"Tunnel","scope":{"sandbox":{}},"connectFrom":"tunnel","driver":"mysql"},{"id":"\#(UUID().uuidString)","name":"Shared","allTargets":true,"connectFrom":"mac","driver":"sqlite","database":"/tmp/a.sqlite"}]}"#
        let loaded = try JSONDecoder().decode(TargetLibrary.self, from: Data(library.utf8))
        #expect(loaded.databaseConnections.map(\.name) == ["Legacy", "Shared"])
        #expect(loaded.allTargetsDatabaseConnections.map(\.name) == ["Shared"])
    }

    @Test func everyTargetFindsAllTargetsConnections() {
        let project = TargetRef.local(UUID())
        let profile = TargetRef.docker(UUID())
        var library = TargetLibrary()
        let own = library.saveDatabaseConnection(Self.connection("Reporting", scope: project))
        let shared = library.saveDatabaseConnection(Self.connection("Analytics", scope: nil))
        let sharedNamedLikeOwn = library.saveDatabaseConnection(Self.connection("reporting", scope: nil))

        #expect(library.databaseConnections(for: project).map(\.id) == [own.id], "a target's list holds only its own")
        #expect(library.allTargetsDatabaseConnections.map(\.name) == ["Analytics", "reporting"])
        #expect(library.databaseConnections(scope: nil).count == 2)
        // By id: on any target, the sandbox too.
        for target in [project, profile, .sandbox, .ssh(UUID())] {
            #expect(library.databaseConnection(id: shared.id, name: nil, on: target)?.id == shared.id)
        }
        #expect(library.databaseConnection(id: own.id, name: nil, on: profile) == nil, "a target's connection stays on its target")
        // By name (workspaces keep names only): the target's own first, then all targets'.
        #expect(library.databaseConnection(id: nil, name: "Reporting", on: project)?.id == own.id)
        #expect(library.databaseConnection(id: nil, name: "Reporting", on: profile)?.id == sharedNamedLikeOwn.id)
        #expect(library.databaseConnection(id: nil, name: "analytics", on: .sandbox)?.id == shared.id)

        // Removing a target leaves connections of all targets alone.
        let removed = library.removeDatabaseConnections(for: project)
        #expect(removed.map(\.id) == [own.id])
        #expect(library.allTargetsDatabaseConnections.count == 2)
    }

    @Test func normalizedAndValidated() {
        // All targets: always from this Mac; the sandbox can't have its own, but all targets' work there.
        var shared = Self.connection(scope: nil, connectFrom: .target)
        #expect(shared.normalized.connectFrom == .thisMac)
        #expect(shared.validate().isEmpty)
        #expect(Self.connection(scope: .sandbox).validate().contains(.unsupportedTarget))

        // Names are unique among connections of all targets, and per target.
        let other = Self.connection("REPORTING", scope: nil)
        #expect(shared.validate(others: [other]).contains(.duplicateNameAllTargets))
        #expect(Self.connection(scope: .local(UUID())).validate(others: [other]).isEmpty, "a target's connection may share a name with one of all targets")

        // From this Mac, an SQLite file is an absolute path (~ is expanded); relative paths
        // would start in Runlet's empty folder, so they are refused.
        var sqlite = Self.connection(scope: .local(UUID()), connectFrom: .thisMac, driver: .sqlite)
        sqlite.database = "database/app.sqlite"
        #expect(sqlite.validate().contains(.relativePathOnThisMac))
        sqlite.database = "~/data/app.sqlite"
        #expect(sqlite.validate().isEmpty)
        #expect(sqlite.normalized.database == NSHomeDirectory() + "/data/app.sqlite")
        sqlite.database = ":memory:"
        #expect(sqlite.validate().isEmpty)
        sqlite.connectFrom = .target
        sqlite.database = "database/app.sqlite"
        #expect(sqlite.validate().isEmpty, "on the target, relative to the project, as before")
        sqlite.database = "~/data/app.sqlite"
        #expect(sqlite.normalized.database == "~/data/app.sqlite", "the target's paths aren't this Mac's")

        // TLS files and sockets from this Mac: ~ expands too.
        var tls = Self.connection(scope: nil)
        tls.tls = DatabaseTLS(mode: .verifyFull, caFile: "~/certs/ca.pem")
        tls.socket = "~/run/pg"
        #expect(tls.normalized.tls?.caFile == NSHomeDirectory() + "/certs/ca.pem")
        #expect(tls.normalized.socket == NSHomeDirectory() + "/run/pg")
        #expect(tls.validate().isEmpty)
    }

    @Test func markingIsTheStricterOfConnectionAndTabTarget() {
        let production = LocalProject(name: "Live", path: "/tmp/live", environment: .production)
        let library = TargetLibrary(localProjects: [production])
        var shared = Self.connection(scope: nil)
        #expect(library.marking(for: .local(production.id), connection: shared).isProduction, "a production target asks on any connection")
        #expect(!library.marking(for: .sandbox, connection: shared).isProduction)
        shared.environment = .production
        let marking = library.marking(for: .sandbox, connection: shared)
        #expect(marking.isProduction && marking.fromConnection, "a production connection asks on every target")
    }

    @Test func duplicatesKeepTheirPlace() {
        let shared = Self.connection(scope: nil)
        let copy = shared.duplicated(named: "Analytics copy")
        #expect(copy.isAllTargets && copy.id != shared.id)
        let moved = shared.duplicated(named: "Analytics", scope: .docker(UUID()))
        #expect(moved.scope != nil && moved.connectFrom == .thisMac, "a copy for a target keeps opening from this Mac")
    }

    @Test func runRequestsCarryWhereItOpens() throws {
        var request = RunRequest(tabId: UUID(), documentVersion: 1, target: TargetSnapshot(kind: .local, label: "Analytics · this Mac", targetId: "this-mac", workingDirectory: "/tmp", phpExecutable: "php"), code: "")
        request.sqlConnection = Self.connection(scope: nil)
        let decoded = try JSONDecoder().decode(RunRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded.sqlConnection?.opensOnThisMac == true && decoded.sqlConnection?.isAllTargets == true)
    }
}
