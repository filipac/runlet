import Foundation
@testable import RunletCore
import Testing

struct MongoConnectionTests {
    @Test func encodingAndLegacyDefaults() throws {
        let old = DatabaseConnection(name: "SQL", scope: nil, connectFrom: .thisMac, driver: .mysql, host: "localhost")
        let oldData = try JSONEncoder().encode(old)
        #expect(!String(decoding: oldData, as: UTF8.self).contains("mongo"))
        #expect(try JSONDecoder().decode(DatabaseConnection.self, from: oldData) == old)
        var mongo = DatabaseConnection(name: "Documents", scope: .local(UUID()), driver: .mongodb, host: "localhost", database: "p191_test")
        mongo.mongo = MongoConnectionOptions()
        mongo.mongo?.replicaSet = "rs0"
        let data = try JSONEncoder().encode(mongo)
        #expect(try JSONDecoder().decode(DatabaseConnection.self, from: data) == mongo)
        #expect(mongo.validate().isEmpty)
        #expect(mongo.effectivePort == 27017)
    }

    @Test func tunnelAndCredentialValidation() {
        var connection = DatabaseConnection(name: "Documents", scope: nil, driver: .mongodb, host: "mongodb://user:secret@localhost")
        #expect(!connection.validate().isEmpty)
        connection.host = "localhost"
        connection.mongo = MongoConnectionOptions()
        connection.mongo?.srv = true
        connection.connectFrom = .sshTunnel
        connection.sshProfile = UUID()
        #expect(!connection.validate().isEmpty)
        connection.mongo?.srv = false
        #expect(connection.validate().isEmpty)
    }

    @Test func familiesAndLanguage() throws {
        #expect(DatabaseDriverKind.mongodb.family == .mongodb)
        #expect(!DatabaseDriverKind.kinds(of: .sql).contains(.mongodb))
        #expect(TabLanguage.mongodb.connectionFamily == .mongodb)
        #expect(TabLanguage.forFile(URL(fileURLWithPath: "/tmp/example.mongodb")) == .mongodb)
        #expect(try JSONDecoder().decode(TabLanguage.self, from: Data("\"unknown\"".utf8)) == .php)
        var library = TargetLibrary()
        let connection = DatabaseConnection(name: "Shared", scope: nil, driver: .mongodb, host: "localhost")
        library.saveDatabaseConnection(connection)
        #expect(library.databaseConnection(id: connection.id, name: connection.name, on: .sandbox, family: .sql) == nil)
        #expect(library.databaseConnection(id: connection.id, name: connection.name, on: .sandbox, family: .mongodb) != nil)
    }

    @Test func productionNeverUsesGrace() {
        var grace = ProductionGrace()
        grace.grant(.sandbox)
        let asks = grace.needsConfirmation(.mongodb, on: .sandbox, environment: .production)
        #expect(asks)
    }
}
