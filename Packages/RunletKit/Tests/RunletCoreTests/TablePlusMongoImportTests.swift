import Foundation
import Testing
@testable import RunletCore

/// Import from TablePlus… for MongoDB connections (#209): connection strings, fields, SRV, TLS,
/// SSH, and passwords from a connection string or the fake Keychain reader. Only made-up
/// fixtures (`Tests/Fixtures/tableplus/`) and inline data; nothing reads TablePlus's real files
/// or the Keychain.
struct TablePlusMongoImportTests {
    typealias Fixtures = TablePlusImportTests

    static func id(_ n: Int) -> String { Fixtures.id(n) }

    static func row(_ plan: TablePlusImportPlan, _ n: Int) throws -> TablePlusImportRow {
        try #require(plan.row(id(n)))
    }

    /// One TablePlus entry, parsed and mapped.
    static func row(_ entry: [String: Any]) throws -> TablePlusImportRow {
        var entry = entry
        entry["ID"] = entry["ID"] ?? "m1"
        entry["ConnectionName"] = entry["ConnectionName"] ?? "Mongo"
        entry["Driver"] = entry["Driver"] ?? "Mongo"
        let data = try PropertyListSerialization.data(fromPropertyList: [entry], format: .xml, options: 0)
        return TablePlusImportRow(try #require(TablePlusParser.parse(connections: data).connections.first))
    }

    // MARK: Connection strings

    @Test func readsAConnectionStringWithoutKeepingSecrets() throws {
        let uri = try #require(MongoConnectionString("mongodb://app%2Buser:fixture-uri-p%40ss@h1.example.com:27018,h2.example.com,[::1]:27020/orders?replicaSet=rs0&authSource=users&tlsCertificateKeyFilePassword=fixture-uri-keypass&authMechanismProperties=AWS_SESSION_TOKEN:fixture-uri-token&retryWrites=true"))
        #expect(!uri.srv)
        #expect(uri.hosts == [.init(host: "h1.example.com", port: 27018), .init(host: "h2.example.com"), .init(host: "::1", port: 27020)])
        #expect(uri.hosts.map(\.label) == ["h1.example.com:27018", "h2.example.com", "[::1]:27020"])
        #expect(uri.user == "app+user")
        #expect(uri.password?.revealed() == "fixture-uri-p@ss")
        #expect(uri.database == "orders")
        #expect(uri.options["replicaset"] == "rs0" && uri.options["authsource"] == "users")
        #expect(uri.options["tlscertificatekeyfilepassword"] == "" && uri.options["authmechanismproperties"] == "", "secret values aren't kept")
        #expect(uri.optionNames == ["replicaSet", "authSource", "tlsCertificateKeyFilePassword", "authMechanismProperties", "retryWrites"])
        #expect(uri.problems.isEmpty)
        #expect(!String(describing: uri).contains("fixture-uri"))

        let srv = try #require(MongoConnectionString("MONGODB+SRV://cluster0.example.net/?authSource=admin"))
        #expect(srv.srv && srv.hosts == [.init(host: "cluster0.example.net")] && srv.database == nil && srv.user == nil)
        // Options right after the host, without "/".
        #expect(MongoConnectionString("mongodb://h.example.com?tls=true")?.flag("tls") == true)
        // An unencoded "@" in the password: the last "@" ends it.
        let at = try #require(MongoConnectionString("mongodb://u:fixture@uri@h.example.com/db"))
        #expect(at.password?.revealed() == "fixture@uri" && at.hosts.map(\.host) == ["h.example.com"])
        #expect(MongoConnectionString("postgres://u:p@h/db") == nil)
        #expect(MongoConnectionString("") == nil)
    }

    @Test func unreadableConnectionStringsKeepNothing() throws {
        // An unencoded "/" in the password: nothing of it may become a host, database, or option.
        for text in ["mongodb://u:fixture-un/readable@h.example.com/db", "mongodb://u:fixture-un/re?adable@h.example.com", "mongodb://me@corp:fixture-un/readable@h.example.com/db"] {
            let uri = try #require(MongoConnectionString(text))
            #expect(uri.hosts.isEmpty && uri.database == nil && uri.options.isEmpty, "\(text)")
            #expect(uri.problems == [MongoConnectionString.unreadable])
            let row = try Self.row(["DatabaseHost": text])
            #expect(!row.canImport && row.reason?.contains("no host or connection string") == true)
            let described = String(describing: row)
            #expect(!described.contains("fixture-un") && !described.contains("adable"), "\(text)")
        }
        let port = try #require(MongoConnectionString("mongodb://h.example.com:99999"))
        #expect(port.hosts == [.init(host: "h.example.com")])
        #expect(port.problems.count == 1 && !port.problems[0].contains("99999"))
        let socket = try #require(MongoConnectionString("mongodb://%2Ftmp%2Fmongodb-27017.sock/db"))
        #expect(socket.hosts.isEmpty && socket.problems.contains { $0.contains("Unix socket") })
        let long = try #require(MongoConnectionString("mongodb://" + String(repeating: "a", count: 9000)))
        #expect(long.hosts.isEmpty && long.problems.count == 1)
    }

    // MARK: Fixture rows

    @Test func mapsTheFixturesMongoDBRows() throws {
        let plan = try Fixtures.plan()
        func mongo(_ row: TablePlusImportRow) throws -> MongoConnectionOptions { try #require(row.connection?.mongo) }

        // Plain: TablePlus's fields.
        let events = try Self.row(plan, 11)
        let plain = try #require(events.connection)
        #expect(plain.driver == .mongodb && plain.host == "mongo.acme.example.com" && plain.port == nil && plain.database == "events")
        #expect(plain.mongo == MongoConnectionOptions(), "admin, primary, no SRV")
        #expect(plain.tls == nil && plain.connectFrom == .thisMac && plain.importedFrom == "tableplus:" + Self.id(11))
        #expect(events.notes.isEmpty && !events.usesTLS && !events.usesSSH)

        // A connection string in the host field: a seed list, an authentication database, a
        // replica set, and a read preference. The host is the first one, never the string.
        let orders = try Self.row(plan, 19)
        #expect(orders.source.host == "mongo-1.acme.example.com" && orders.source.port == 27018)
        #expect(orders.source.mongo?.fromConnectionString == true && orders.source.mongo?.moreHosts == ["mongo-2.acme.example.com:27018", "mongo-3.acme.example.com:27018"])
        let ordersConnection = try #require(orders.connection)
        #expect(ordersConnection.host == "mongo-1.acme.example.com" && ordersConnection.port == 27018 && ordersConnection.database == "orders" && ordersConnection.user == "orders_app")
        let ordersOptions = try mongo(orders)
        #expect(ordersOptions.authDatabase == "accounts" && ordersOptions.replicaSet == "rs-orders" && ordersOptions.readPreference == "secondaryPreferred" && !ordersOptions.srv)
        #expect(orders.isProduction)
        #expect(orders.notes.count == 1 && orders.notes[0].contains("3 hosts") && orders.notes[0].contains("replica set"), "retryWrites and w need no note: \(orders.notes)")

        // SRV, the user from TablePlus's field: no port, TLS on by default.
        let atlas = try Self.row(plan, 20)
        let atlasConnection = try #require(atlas.connection)
        #expect(try mongo(atlas).srv && atlasConnection.host == "cluster0.abcde.mongodb.example.net" && atlasConnection.port == nil)
        #expect(atlasConnection.database == "analytics" && atlasConnection.user == "atlas_reader")
        #expect(try mongo(atlas).authDatabase == "admin")
        #expect(atlasConnection.tls == nil && atlas.usesTLS)
        #expect(atlasConnection.location == "cluster0.abcde.mongodb.example.net/analytics (SRV)")
        #expect(atlas.notes.isEmpty, "\(atlas.notes)")

        // TLS from TablePlus's menu, a CA file, read-only.
        let audit = try Self.row(plan, 21)
        #expect(audit.connection?.tls == DatabaseTLS(mode: .verifyFull) && audit.usesTLS)
        #expect(audit.connection?.readOnly == true)
        #expect(audit.notes.contains { $0.contains("TLS for it (setting 1)") })
        #expect(audit.notes.contains { $0.contains("CA or client certificate files") })

        // SSH: like SQL rows (TablePlusImportTests covers the profile rules).
        let sessions = try Self.row(plan, 22)
        #expect(sessions.usesSSH && plan.defaultSSHChoice(for: sessions, in: TargetLibrary()) == .newProfile)

        // A connection string under a URL key: TLS, SCRAM-SHA-256, the path's database as the
        // authentication database; directConnection isn't kept.
        let search = try Self.row(plan, 23)
        let searchConnection = try #require(search.connection)
        #expect(searchConnection.host == "search.acme.example.com" && searchConnection.port == 27019 && searchConnection.database == "catalog" && searchConnection.user == "search_ro")
        #expect(try mongo(search).authMechanism == "SCRAM-SHA-256" && mongo(search).authDatabase == "catalog")
        #expect(searchConnection.tls == DatabaseTLS(mode: .verifyFull))
        #expect(search.notes == ["TablePlus's connection string also sets directConnection; Runlet doesn't keep it."])

        // A connection string with a password: parsed, never shown or kept in the row.
        let inventory = try Self.row(plan, 24)
        let inventoryConnection = try #require(inventory.connection)
        #expect(inventoryConnection.host == "inventory.example.com" && inventoryConnection.port == nil && inventoryConnection.user == "inventory")
        #expect(try mongo(inventory).authDatabase == "admin" && inventoryConnection.tls == DatabaseTLS(mode: .disable))
        #expect(inventory.source.mongo?.password?.revealed() == "fixture-tp-Pa55-inventory!")
        #expect(!String(describing: inventory).contains("fixture-tp-Pa55"))
        #expect(!String(describing: plan).contains("fixture-tp-Pa55") && !String(describing: plan).contains("mongodb://"))

        // SRV over SSH: imported without SSH, with a note; no profile is suggested.
        let reports = try Self.row(plan, 25)
        #expect(reports.canImport && !reports.usesSSH && reports.source.ssh != nil)
        #expect(plan.defaultSSHChoice(for: reports, in: TargetLibrary()) == nil)
        #expect(reports.notes.contains { $0.contains("can't go through an SSH tunnel") })
    }

    @Test func importsMongoDBRowsWithSSHGroupsAndDuplicates() throws {
        let plan = try Fixtures.plan()
        let mongoIDs: Set<String> = Set([11, 19, 20, 21, 22, 23, 24, 25].map(Self.id))
        var library = TargetLibrary()
        let options = TablePlusImportOptions(selected: mongoIDs.union([Self.id(3)]))
        let planned = plan.newProfiles(options: options, library: library)
        #expect(planned.count == 1 && planned[0].rowIDs == [Self.id(3), Self.id(22)], "one profile per server, shared with SQL rows")
        let outcome = TablePlusImport.apply(plan, options: options, library: &library, passwords: [:], credentials: InMemoryCredentialStore())
        #expect(outcome.summary.imported.count == 9 && outcome.summary.skipped.isEmpty)
        #expect(library.databaseConnections.allSatisfy { $0.validate(others: library.databaseConnections).isEmpty })

        func saved(_ name: String) throws -> DatabaseConnection { try #require(library.databaseConnections.first { $0.name == name }) }
        let sessions = try saved("Acme Sessions")
        #expect(sessions.usesSSHTunnel && sessions.sshProfile == outcome.createdProfiles.first && sessions.host == "10.0.0.20")
        let reports = try saved("Atlas Reports")
        #expect(reports.connectFrom == .thisMac && reports.sshProfile == nil && reports.mongo?.srv == true)
        #expect(reports.environment == .production && reports.isAllTargets)
        #expect(outcome.summary.imported.first { $0.name == "Atlas Reports" }?.details == ["mongodb, reports.abcde.mongodb.example.net/reports (SRV) · production"])
        #expect(outcome.summary.needsAttention.first { $0.name == "Atlas Reports" }?.details.contains { $0.contains("SSH tunnel") } == true)

        // targets.json keeps the options, never a connection string.
        let encoded = String(decoding: try JSONEncoder().encode(library), as: UTF8.self)
        #expect(encoded.contains("\"replicaSet\":\"rs-orders\"") && encoded.contains("\"srv\":true"))
        #expect(!encoded.contains("mongodb://") && !encoded.contains("mongodb+srv://") && !encoded.contains("fixture-tp-Pa55"))

        // A second import recognises them by TablePlus's id; Update keeps their ids.
        let again = TablePlusImport.apply(plan, options: TablePlusImportOptions(selected: mongoIDs), library: &library, passwords: [:], credentials: InMemoryCredentialStore())
        #expect(again.summary.imported.isEmpty && again.summary.skipped.count == 8)
        let ordersID = try saved("Acme Orders").id
        let updated = TablePlusImport.apply(plan, options: TablePlusImportOptions(selected: mongoIDs, duplicates: .update), library: &library, passwords: [:], credentials: InMemoryCredentialStore())
        #expect(updated.summary.updated.count == 8 && library.databaseConnection(ordersID)?.revision == 2)
    }

    // MARK: Passwords

    @Test func connectionStringPasswordsFollowTheOptIn() throws {
        let plan = try Fixtures.plan()
        let reader = try Fixtures.reader()
        let selected: Set<String> = [Self.id(19), Self.id(24)]

        // Off: nothing is read or copied; the connection string's password is dropped with a note.
        var library = TargetLibrary()
        let credentials = InMemoryCredentialStore()
        var options = TablePlusImportOptions(selected: selected)
        #expect(plan.passwordRequests(options: options, library: library).isEmpty)
        let off = TablePlusImport.apply(plan, options: options, library: &library, passwords: [:], credentials: credentials)
        #expect(credentials.accounts.isEmpty && off.summary.passwordsCopied == 0)
        #expect(off.summary.needsAttention.first { $0.name == "Example Inventory" }?.details.contains { $0.contains("includes a password; it wasn't copied") } == true)

        // On: the Keychain is asked only for the row without a password of its own.
        library = TargetLibrary()
        let copied = InMemoryCredentialStore()
        options.copyPasswords = true
        let requests = plan.passwordRequests(options: options, library: library)
        #expect(requests == [Self.id(19)])
        let passwords = TablePlusImport.readPasswords(requests, reader: reader)
        #expect(reader.requestedIDs == [Self.id(19)], "the connection string's password needs no Keychain item")
        let on = TablePlusImport.apply(plan, options: options, library: &library, passwords: passwords, credentials: copied)
        func saved(_ name: String) throws -> DatabaseConnection { try #require(library.databaseConnections.first { $0.name == name }) }
        #expect(try copied.read(saved("Acme Orders").id)?.revealed() == "fixture-tp-Pa55-orders")
        #expect(try copied.read(saved("Example Inventory").id)?.revealed() == "fixture-tp-Pa55-inventory!")
        #expect(copied.label(try saved("Example Inventory").id) == "Runlet database: Example Inventory")
        #expect(on.summary.passwordsCopied == 2)
        #expect(!on.summary.needsAttention.contains { $0.details.contains { $0.lowercased().contains("password") } })

        for text in [String(decoding: try JSONEncoder().encode(library), as: UTF8.self), String(describing: on.summary), String(describing: off.summary)] {
            #expect(!text.contains("fixture-tp-Pa55"))
        }
    }

    @Test func aKeychainItemHoldingAConnectionStringGivesOnlyItsPassword() throws {
        let plan = try Fixtures.plan()
        let id = Self.id(11)
        let options = TablePlusImportOptions(selected: [id], copyPasswords: true)
        var library = TargetLibrary()
        let credentials = InMemoryCredentialStore()
        let reader = FakeTablePlusKeychainReader([id: .found(SensitiveString("mongodb://events:fixture-kc-inner@mongo.acme.example.com/events"))])
        let outcome = TablePlusImport.apply(plan, options: options, library: &library, passwords: TablePlusImport.readPasswords([id], reader: reader), credentials: credentials)
        let saved = try #require(library.databaseConnections.first)
        #expect(try credentials.read(saved.id)?.revealed() == "fixture-kc-inner")
        #expect(outcome.summary.needsAttention.first?.details.contains { $0.contains("holds a connection string; only its password") } == true)

        var other = TargetLibrary()
        let none = InMemoryCredentialStore()
        let bare = FakeTablePlusKeychainReader([id: .found(SensitiveString("mongodb+srv://cluster0.example.net/events"))])
        let without = TablePlusImport.apply(plan, options: options, library: &other, passwords: TablePlusImport.readPasswords([id], reader: bare), credentials: none)
        #expect(none.accounts.isEmpty && without.summary.passwordsCopied == 0)
        #expect(without.summary.needsAttention.first?.details.contains { $0.contains("without a password") } == true)
    }

    // MARK: Fields and odd input

    @Test func fieldsSeedListsAndUnconfirmedKeys() throws {
        // A seed list and options in TablePlus's host field.
        let seeds = try Self.row(["DatabaseHost": "h1.example.com:27017,h2.example.com:27017?replicaSet=rs1&authSource=users", "DatabaseUser": "app"])
        #expect(seeds.connection?.host == "h1.example.com" && seeds.connection?.port == nil)
        #expect(seeds.connection?.mongo?.replicaSet == "rs1" && seeds.connection?.mongo?.authDatabase == "users")
        #expect(seeds.notes.first?.contains("2 hosts (also h2.example.com:27017)") == true)

        // The shape a TablePlus issue (#2525) shows: options after an SRV host, and a port.
        let srv = try Self.row(["DatabaseHost": "cluster1.example.net?retryWrites=true&w=majority", "isUseSRV": 1, "DatabasePort": "27017"])
        #expect(srv.connection?.mongo?.srv == true && srv.connection?.host == "cluster1.example.net" && srv.connection?.port == nil)
        #expect(srv.notes.contains { $0.contains("SRV connection has no port") })

        // Unconfirmed field keys, read when present; values are matched without case.
        let keyed = try Self.row(["DatabaseHost": "db.example.com", "AuthSource": "reporting", "ReplicaSet": "rs2", "ReadPreference": "Nearest", "AuthMechanism": "scram-sha-1"])
        #expect(keyed.connection?.mongo == {
            var options = MongoConnectionOptions()
            options.authDatabase = "reporting"
            options.replicaSet = "rs2"
            options.readPreference = "nearest"
            options.authMechanism = "SCRAM-SHA-1"
            return options
        }())

        // What Runlet's MongoDB connections can't do leaves notes and safe defaults.
        let odd = try Self.row(["DatabaseURL": "mongodb://u@db.example.com/?authSource=%24external&authMechanism=MONGODB-X509&readPreference=fastest&replicaSet=rs%200&tls=true&tlsInsecure=true&tlsCAFile=%2Fca.pem"])
        let options = try #require(odd.connection?.mongo)
        #expect(options.authDatabase == "admin" && options.authMechanism == "" && options.readPreference == "primary" && options.replicaSet == "")
        #expect(odd.connection?.tls == DatabaseTLS(mode: .verifyFull))
        for part in ["$external", "MONGODB-X509", "“fastest”", "replica set name", "tlsInsecure", "certificate files"] {
            #expect(odd.notes.contains { $0.contains(part) }, "\(part): \(odd.notes)")
        }
        #expect(odd.connection?.validate().isEmpty == true)

        // No host anywhere, or a user name and password in the host field: greyed out.
        let empty = try Self.row([:])
        #expect(!empty.canImport && empty.reason == "Runlet found no host or connection string it can read for it. Create it with New Connection…, entering the host (not a URI).")
        let userinfo = try Self.row(["DatabaseHost": "u:fixture-hostfield@db.example.com"])
        #expect(!userinfo.canImport && !String(describing: userinfo).contains("fixture-hostfield"))
        // TablePlus's driver name "MongoDB" works too, and SSH settings on a socket-less row.
        #expect(try Self.row(["Driver": "MongoDB", "DatabaseHost": "db.example.com"]).connection?.driver == .mongodb)
    }

    @Test func otherDriversNeverShowAURLsPassword() throws {
        let row = try Self.row(["Driver": "MySQL", "DatabaseHost": "mysql://u:fixture-sql-url@db.example.com:3306/shop"])
        #expect(row.source.host == "mysql://db.example.com:3306/shop")
        #expect(row.source.problems.contains { $0.contains("left the user name and any password out") })
        #expect(!String(describing: row).contains("fixture-sql-url"))
    }

    @Test func unsupportedDriversSayWhy() {
        for driver in ["Cassandra", "DynamoDB", "etcd", "ElasticSearch"] {
            let row = TablePlusImportRow(TablePlusConnection(id: "x", name: driver, driver: driver, host: "db.example.com"))
            #expect(!row.canImport)
            #expect(row.reason == "Runlet has no \(driver) connections: it connects to SQL databases (through PHP's PDO), Redis, and MongoDB.")
        }
        let snowflake = TablePlusImportRow(TablePlusConnection(id: "s", name: "Snow", driver: "Snowflake", host: "acct.example.com"))
        #expect(snowflake.reason?.hasPrefix("Runlet has no driver for Snowflake. It imports MySQL, MariaDB, PostgreSQL, SQLite, SQL Server, Redis, and MongoDB") == true)
        #expect(TablePlusMapping.driver("Mongo").driver == .mongodb && TablePlusMapping.driver("MongoDB").driver == .mongodb)
    }
}
