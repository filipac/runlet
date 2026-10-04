import Foundation
@testable import RunletCore
import Testing

/// What a PHP on this Mac can open connections with, and what a saved connection needs (#184).
struct PHPDriversTests {
    @Test func probeOutputIsParsedFromItsLastJSONLine() {
        let output = "Welcome to this shell\n{\"pdo\":[\"MySQL\",\"sqlite\",\"sqlsrv\"],\"extensions\":[\"redis\"]}\n"
        let drivers = PHPDrivers.parse(output)
        #expect(drivers == PHPDrivers(pdo: ["mysql", "sqlite", "sqlsrv"], extensions: ["redis"]))
        #expect(PHPDrivers.parse("{\"pdo\":[],\"extensions\":[]}") == PHPDrivers())
        #expect(PHPDrivers.parse("PHP Warning: something") == nil)
        #expect(PHPDrivers.parse("") == nil)
        // The probe asks PDO and the two client extensions, and nothing else.
        #expect(PHPDrivers.probeCode.contains("PDO::getAvailableDrivers()"))
        #expect(PHPDrivers.probeCode.contains("'redis', 'mongodb'"))
    }

    private func connection(_ driver: DatabaseDriverKind, dsn: String? = nil) -> DatabaseConnection {
        var connection = DatabaseConnection(name: "C", scope: nil, connectFrom: .thisMac, driver: driver, host: "127.0.0.1")
        connection.dsn = dsn
        return connection
    }

    @Test func eachKindNeedsItsDriver() {
        #expect(PHPDriverRequirement(connection(.mysql)) == .pdo(["mysql"]))
        #expect(PHPDriverRequirement(connection(.pgsql)) == .pdo(["pgsql"]))
        #expect(PHPDriverRequirement(connection(.sqlite)) == .pdo(["sqlite"]))
        #expect(PHPDriverRequirement(connection(.sqlsrv)) == .pdo(["sqlsrv", "dblib"]))
        #expect(PHPDriverRequirement(connection(.custom, dsn: "oci:dbname=//db.internal:1521/XE")) == .pdo(["oci"]))
        #expect(PHPDriverRequirement(connection(.custom, dsn: "ODBC:Driver={FreeTDS};Server=db")) == .pdo(["odbc"]))
        #expect(PHPDriverRequirement(connection(.custom, dsn: nil)) == PHPDriverRequirement.none)
        #expect(PHPDriverRequirement(connection(.redis)) == PHPDriverRequirement.none)
        #expect(PHPDriverRequirement(connection(.mongodb)) == .phpExtension("mongodb"))
    }

    @Test func requirementsAreMetByTheRightDrivers() {
        let runlet = PHPDrivers(pdo: ["mysql", "pgsql", "sqlite"], extensions: ["redis", "mongodb"])
        let dblib = PHPDrivers(pdo: ["dblib", "mysql"])
        let bare = PHPDrivers()
        #expect(PHPDriverRequirement.pdo(["mysql"]).isMet(by: runlet))
        #expect(!PHPDriverRequirement.pdo(["sqlsrv", "dblib"]).isMet(by: runlet))
        #expect(PHPDriverRequirement.pdo(["sqlsrv", "dblib"]).isMet(by: dblib), "FreeTDS will do for SQL Server")
        #expect(PHPDriverRequirement.phpExtension("mongodb").isMet(by: runlet))
        #expect(!PHPDriverRequirement.phpExtension("mongodb").isMet(by: dblib))
        #expect(PHPDriverRequirement.none.isMet(by: bare), "Redis needs nothing")
        #expect(!PHPDriverRequirement.pdo(["oci"]).isMet(by: runlet))
    }

    @Test func namesForMessages() {
        #expect(PHPDriverRequirement.pdo(["sqlsrv", "dblib"]).name == "pdo_sqlsrv or pdo_dblib")
        #expect(PHPDriverRequirement.pdo(["oci"]).name == "pdo_oci")
        #expect(PHPDriverRequirement.phpExtension("mongodb").name == "ext-mongodb")
        #expect(PHPDriverRequirement.pdo(["sqlsrv", "dblib"]).missing(plural: false) == "has neither pdo_sqlsrv nor pdo_dblib")
        #expect(PHPDriverRequirement.pdo(["oci"]).missing(plural: true) == "have no pdo_oci")
    }
}
