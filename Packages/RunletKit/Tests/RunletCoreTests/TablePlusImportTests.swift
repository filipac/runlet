import Foundation
import Testing
@testable import RunletCore

/// Import from TablePlus… (#188): parsing TablePlus's files, mapping connections, duplicates,
/// SSH profiles, and copying passwords through a fake Keychain reader. Only made-up fixtures in
/// `Tests/Fixtures/tableplus/`; nothing here reads TablePlus's real files or the Keychain.
struct TablePlusImportTests {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/tableplus", isDirectory: true)

    static func id(_ n: Int) -> String { String(format: "7A1F0C00-0000-4000-8000-%012d", n) }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: folder.appendingPathComponent(name))
    }

    static func parsed() throws -> TablePlusParser.Result {
        TablePlusParser.parse(connections: try data("Connections.plist"), groups: try data("ConnectionGroups.plist"))
    }

    static func plan() throws -> TablePlusImportPlan { TablePlusImportPlan(try parsed()) }

    static func reader() throws -> FakeTablePlusKeychainReader {
        FakeTablePlusKeychainReader(fixture: try data("keychain-fixture.json"))
    }

    func connection(_ result: TablePlusParser.Result, _ n: Int) throws -> TablePlusConnection {
        try #require(result.connections.first { $0.id == Self.id(n) })
    }

    // MARK: Parsing

    @Test func parsesEveryFieldAndIgnoresUnknownKeys() throws {
        let result = try Self.parsed()
        #expect(result.connections.count == 17)
        #expect(result.problems == ["1 entry isn't a connection and was left out."])

        let shop = try connection(result, 1)
        #expect(shop.name == "Acme Shop (production)")
        #expect(shop.driver == "MySQL")
        #expect(shop.host == "db.acme.example.com" && shop.port == 3306 && shop.database == "shop" && shop.user == "shop_ro")
        #expect(shop.environment == "production")
        #expect(shop.statusColor == "#E5484D")
        #expect(shop.group == "Clients / Acme")
        #expect(shop.tlsMode == 2)
        #expect(shop.ssh == nil)
        #expect(shop.problems.isEmpty)

        let reports = try connection(result, 3)
        #expect(reports.ssh == TablePlusSSH(host: "bastion.example.com", port: 22, user: "deploy", login: .key(path: "~/.ssh/acme_deploy", name: nil)))
        let blog = try connection(result, 5)
        #expect(blog.ssh == TablePlusSSH(host: "web1.example.com", port: 2222, user: "forge", login: .password))
        #expect(try connection(result, 15).ssh?.login == .agent)

        let sqlite = try connection(result, 7)
        #expect(sqlite.path == "/Users/someone/Projects/acme/database/database.sqlite")
        #expect(sqlite.group == "Local")
        #expect(try connection(result, 9).socket == "/tmp/mysql.sock")
        // A socket path without isUseSocket isn't used.
        #expect(shop.socket == nil)
        // The port as a number works too.
        #expect(try connection(result, 18).port == 3306)
        #expect(try connection(result, 18).readOnly == true)
    }

    @Test func missingAndOddFieldsLeaveNotes() throws {
        let result = try Self.parsed()
        let legacy = try connection(result, 13)
        #expect(legacy.port == nil)
        #expect(legacy.problems.contains { $0.contains("not-a-port") })
        #expect(legacy.tlsKeyPaths.count == 2)

        let nameless = try #require(result.connections.first { !$0.hasID })
        #expect(nameless.id == "#13")
        #expect(nameless.name == "No id or driver")
        #expect(nameless.driver.isEmpty)
        #expect(nameless.problems.contains { $0.contains("id is missing") })
        #expect(nameless.problems.contains { $0.contains("driver is missing") })
    }

    @Test func garbageNeverCrashes() throws {
        let garbage = TablePlusParser.parse(connections: try Self.data("garbage.plist"))
        #expect(garbage.connections.isEmpty)
        #expect(garbage.problems.first?.contains("isn't a property list") == true)
        let dictionary = TablePlusParser.parse(connections: try Self.data("not-a-list.plist"))
        #expect(dictionary.connections.isEmpty)
        #expect(dictionary.problems == ["The file is a property list, but not a list of connections."])
        #expect(TablePlusParser.parse(connections: Data()).connections.isEmpty)
        // Groups that aren't groups are ignored.
        let ungrouped = TablePlusParser.parse(connections: try Self.data("Connections.plist"), groups: try Self.data("garbage.plist"))
        #expect(ungrouped.connections.count == 17)
        #expect(ungrouped.connections.allSatisfy { $0.group == nil })
        // Binary property lists read the same.
        let binary = TablePlusParser.parse(connections: try Self.data("binary-Connections.plist"))
        #expect(binary.connections.map(\.name) == ["Acme Shop (production)", "Acme Shop (staging)", "Acme Reports"])
        // Odd value types, a dictionary wrapper, and a group cycle.
        let odd: [String: Any] = ["Connections": [
            ["ID": 42, "ConnectionName": ["not", "a", "string"], "Driver": "PostgreSQL", "DatabasePort": 5432.0, "isOverSSH": "yes", "ServerAddress": "", "tLSMode": "4", "GroupID": "g1"],
            ["ID": "x", "ConnectionName": "Line\nbreak\u{0}", "Driver": 7, "isUseSocket": true, "DatabaseSocket": 12],
        ]]
        let groups: [[String: Any]] = [["ID": "g1", "Name": "One", "GroupID": "g2"], ["ID": "g2", "Name": "Two", "GroupID": "g1"]]
        let parsed = TablePlusParser.parse(
            connections: try PropertyListSerialization.data(fromPropertyList: odd, format: .binary, options: 0),
            groups: try PropertyListSerialization.data(fromPropertyList: groups, format: .binary, options: 0))
        #expect(parsed.connections.count == 2)
        let first = parsed.connections[0]
        #expect(first.id == "42" && first.name == "Unnamed connection 1" && first.port == 5432 && first.tlsMode == 4)
        #expect(first.ssh == nil)
        #expect(first.problems.contains { $0.contains("SSH server's address is missing") })
        #expect(first.group == "Two / One")
        #expect(parsed.connections[1].name == "Linebreak")
        #expect(parsed.connections[1].socket == "12")
        #expect(TablePlusImportRow(parsed.connections[1]).reason?.contains("no driver for 7") == true)
    }

    // MARK: Mapping

    @Test func mapsEverySupportedDriver() throws {
        let plan = try Self.plan()
        func mapped(_ n: Int) throws -> DatabaseConnection { try #require(plan.row(Self.id(n))?.connection) }

        let shop = try mapped(1)
        #expect(shop.driver == .mysql && shop.host == "db.acme.example.com" && shop.port == nil && shop.database == "shop" && shop.user == "shop_ro")
        #expect(shop.environment == .production)
        #expect(shop.color == .red)
        #expect(shop.tls == DatabaseTLS(mode: .require))
        #expect(shop.connectFrom == .thisMac && shop.scope == nil)
        #expect(shop.importedFrom == "tableplus:" + Self.id(1))
        #expect(plan.row(Self.id(1))?.isProduction == true)

        let staging = try mapped(2)
        #expect(staging.driver == .mysql && staging.port == 3307)
        #expect(staging.environment == .staging)
        #expect(staging.color == .orange)
        #expect(staging.tls == DatabaseTLS(mode: .require), "MariaDB's menu: 1 is Require")

        let reports = try mapped(3)
        #expect(reports.driver == .pgsql && reports.tls == DatabaseTLS(mode: .verifyFull))
        #expect(reports.color == .blue)

        let sqlite = try mapped(7)
        #expect(sqlite.driver == .sqlite && sqlite.database == "/Users/someone/Projects/acme/database/database.sqlite" && sqlite.host.isEmpty)

        let warehouse = try mapped(8)
        #expect(warehouse.driver == .sqlsrv && warehouse.environment == .staging && warehouse.port == nil)
        #expect(warehouse.color == .green)

        let socket = try mapped(9)
        #expect(socket.socket == "/tmp/mysql.sock" && socket.host.isEmpty)
        #expect(socket.environment == nil && socket.color == nil, "local is development; TablePlus's grey is no colour")

        let replica = try mapped(18)
        #expect(replica.readOnly)
        #expect(try mapped(17).name == "Example Blog")
    }

    @Test func unsupportedDriversAndOddRowsSayWhy() throws {
        let plan = try Self.plan()
        for n in [11, 12] {
            let row = try #require(plan.row(Self.id(n)))
            #expect(!row.canImport)
            #expect(row.reason?.contains("isn't an SQL database") == true)
        }
        // #190: Redis connections import now, as Redis connections.
        let cache = try #require(plan.row(Self.id(10)))
        #expect(cache.canImport && cache.connection?.driver == .redis && cache.isProduction, "\(String(describing: cache.reason))")
        #expect(cache.connection?.host == "cache.acme.example.com" && cache.connection?.port == nil, "6379 is Redis's default port")
        let nameless = try #require(plan.rows.first { !$0.source.hasID })
        #expect(!nameless.canImport && nameless.reason == "TablePlus doesn't say which driver it uses.")

        let legacy = try #require(plan.row(Self.id(13)))
        #expect(legacy.canImport)
        #expect(legacy.environment == .production, "an unknown tag mentioning prod is production")
        #expect(legacy.notes.contains { $0.contains("Prod-EU") })
        #expect(legacy.notes.contains { $0.contains("TLS setting (9)") })
        #expect(legacy.notes.contains { $0.contains("key or certificate files") })
        #expect(legacy.connection?.tls == nil)

        let oracle = TablePlusImportRow(TablePlusConnection(id: "o", name: "Oracle", driver: "Oracle", host: "ora.example.com"))
        #expect(oracle.reason?.contains("no driver for Oracle") == true)
        // A host Runlet refuses can't be imported.
        let bad = TablePlusImportRow(TablePlusConnection(id: "b", name: "Bad", driver: "MySQL", host: "db.example.com;port=1"))
        #expect(!bad.canImport && bad.reason?.contains("can't save it") == true)
        // SQL Server can't be read-only.
        let sqlsrv = TablePlusImportRow(TablePlusConnection(id: "s", name: "S", driver: "Microsoft SQL Server", host: "s.example.com", readOnly: true))
        #expect(sqlsrv.connection?.readOnly == false && sqlsrv.notes.contains { $0.contains("read-only") })
    }

    @Test func environmentTlsAndColourRules() {
        #expect(TablePlusMapping.environment("Production").environment == .production)
        #expect(TablePlusMapping.environment("prod").environment == .production)
        #expect(TablePlusMapping.environment("testing").environment == .staging)
        #expect(TablePlusMapping.environment("local").environment == nil)
        #expect(TablePlusMapping.environment(nil).environment == nil)
        #expect(TablePlusMapping.environment("qa").note != nil)
        #expect(TablePlusMapping.tls(mode: 1, rawDriver: "PostgreSQL", driver: .pgsql).tls == DatabaseTLS(mode: .disable))
        #expect(TablePlusMapping.tls(mode: 4, rawDriver: "PostgreSQL", driver: .pgsql).tls == DatabaseTLS(mode: .verifyCA))
        let mysqlCA = TablePlusMapping.tls(mode: 3, rawDriver: "MySQL", driver: .mysql)
        #expect(mysqlCA.tls == DatabaseTLS(mode: .verifyFull) && mysqlCA.note != nil)
        #expect(TablePlusMapping.tls(mode: 2, rawDriver: "MariaDB", driver: .mysql).tls == DatabaseTLS(mode: .verifyFull))
        #expect(TablePlusMapping.tls(mode: 0, rawDriver: "MySQL", driver: .mysql).tls == nil)
        #expect(TablePlusMapping.tls(mode: 1, rawDriver: "SQLServer", driver: .sqlsrv).note != nil)
        #expect(TablePlusMapping.color("#F8F8F8") == nil)
        #expect(TablePlusMapping.color("#686B6F") == nil)
        #expect(TablePlusMapping.color("nonsense") == nil)
        #expect(TablePlusMapping.color("#8E4EC6") == .purple)
    }

    // MARK: Duplicates

    @Test func duplicatesAreSkippedByDefaultOrUpdated() throws {
        let plan = try Self.plan()
        let credentials = InMemoryCredentialStore()
        var library = TargetLibrary()
        // Imported before (by TablePlus's id), and one with the same name.
        var before = try #require(plan.row(Self.id(1))?.connection)
        before.name = "Shop renamed in Runlet"
        before.host = "old.acme.example.com"
        let earlier = library.saveDatabaseConnection(before)
        let sameName = library.saveDatabaseConnection(DatabaseConnection(name: "acme shop (staging)", scope: nil, connectFrom: .thisMac, driver: .pgsql, host: "other.example.com"))
        try credentials.set(SensitiveString("kept-fixture-secret"), for: sameName.id, label: "x")

        #expect(plan.duplicate(of: try #require(plan.row(Self.id(1))), scope: nil, in: library)?.id == earlier.id)
        #expect(plan.duplicate(of: try #require(plan.row(Self.id(2))), scope: nil, in: library)?.id == sameName.id)
        #expect(plan.duplicate(of: try #require(plan.row(Self.id(2))), scope: .local(UUID()), in: library) == nil, "same name in another scope isn't a duplicate")

        var options = TablePlusImportOptions(selected: [Self.id(1), Self.id(2), Self.id(7)])
        #expect(options.duplicates == .skip)
        var skipLibrary = library
        let skipped = TablePlusImport.apply(plan, options: options, library: &skipLibrary, passwords: [:], credentials: credentials)
        #expect(skipped.summary.imported.map(\.name) == ["Local SQLite"])
        #expect(skipped.summary.skipped.map(\.name) == ["Acme Shop (production)", "Acme Shop (staging)"])
        #expect(skipped.summary.skipped[0].details.first?.contains("Imported before") == true)
        #expect(skipLibrary.databaseConnection(earlier.id)?.host == "old.acme.example.com")

        options.duplicates = .update
        let updated = TablePlusImport.apply(plan, options: options, library: &library, passwords: [:], credentials: credentials)
        #expect(Set(updated.summary.updated.map(\.name)) == ["Acme Shop (production)", "Acme Shop (staging)"])
        let shop = try #require(library.databaseConnection(earlier.id))
        #expect(shop.host == "db.acme.example.com" && shop.name == "Acme Shop (production)" && shop.revision == earlier.revision + 1)
        let staging = try #require(library.databaseConnection(sameName.id))
        #expect(staging.driver == .mysql && staging.importedFrom == "tableplus:" + Self.id(2))
        #expect(try credentials.read(sameName.id)?.revealed() == "kept-fixture-secret", "an update without copying passwords keeps the password")
        #expect(library.databaseConnections.count == 3)

        // A third import recognises all three by TablePlus's id.
        let again = TablePlusImport.apply(plan, options: TablePlusImportOptions(selected: [Self.id(1), Self.id(2), Self.id(7)]), library: &library, passwords: [:], credentials: credentials)
        #expect(again.summary.imported.isEmpty && again.summary.skipped.count == 3)
    }

    @Test func namesStayUniqueWithinAnImport() throws {
        let plan = try Self.plan()
        var library = TargetLibrary()
        // Two TablePlus connections named "Example Blog".
        let options = TablePlusImportOptions(selected: [Self.id(5), Self.id(17)], sshChoices: [Self.id(5): .direct])
        let outcome = TablePlusImport.apply(plan, options: options, library: &library, passwords: [:], credentials: InMemoryCredentialStore())
        #expect(outcome.summary.imported.map(\.name) == ["Example Blog", "Example Blog 2"])
        #expect(Set(library.databaseConnections.map(\.name)).count == 2)
    }

    @Test func scopeIsAllTargetsByDefaultOrOneTarget() throws {
        let plan = try Self.plan()
        let project = LocalProject(name: "Acme", path: "/tmp/acme")
        var library = TargetLibrary(localProjects: [project])
        _ = TablePlusImport.apply(plan, options: TablePlusImportOptions(selected: [Self.id(1)]), library: &library, passwords: [:], credentials: InMemoryCredentialStore())
        #expect(library.databaseConnections.first?.isAllTargets == true)
        var other = TargetLibrary(localProjects: [project])
        _ = TablePlusImport.apply(plan, options: TablePlusImportOptions(selected: [Self.id(1)], scope: .local(project.id)), library: &other, passwords: [:], credentials: InMemoryCredentialStore())
        let saved = try #require(other.databaseConnections.first)
        #expect(saved.scope == .local(project.id) && saved.connectFrom == .thisMac)
    }

    @Test func nothingIsImportedUnlessSelectedAndUnsupportedRowsAreSkipped() throws {
        let plan = try Self.plan()
        var library = TargetLibrary()
        let none = TablePlusImport.apply(plan, options: TablePlusImportOptions(), library: &library, passwords: [:], credentials: InMemoryCredentialStore())
        #expect(none.summary == TablePlusImportSummary())
        #expect(library.databaseConnections.isEmpty && library.sshProfiles.isEmpty)
        let unsupported = TablePlusImport.apply(plan, options: TablePlusImportOptions(selected: [Self.id(11)]), library: &library, passwords: [:], credentials: InMemoryCredentialStore())
        #expect(unsupported.summary.skipped.first?.details.first?.contains("isn't an SQL database") == true)
        #expect(library.databaseConnections.isEmpty)
    }

    // MARK: SSH

    @Test func sshMatchesAnExistingProfile() throws {
        let plan = try Self.plan()
        let bastion = SSHProfile(name: "Bastion", host: "Bastion.example.com", user: "deploy", remoteDirectory: "/srv")
        let wrongUser = SSHProfile(name: "Bastion root", host: "bastion.example.com", user: "root", remoteDirectory: "/srv")
        var library = TargetLibrary(sshProfiles: [wrongUser, bastion])
        let reports = try #require(plan.row(Self.id(3)))
        #expect(plan.matchingProfiles(for: reports, in: library).map(\.id) == [bastion.id])
        #expect(plan.defaultSSHChoice(for: reports, in: library) == .existing(bastion.id))
        let options = TablePlusImportOptions(selected: [Self.id(3), Self.id(4)])
        #expect(plan.newProfiles(options: options, library: library).isEmpty)
        let outcome = TablePlusImport.apply(plan, options: options, library: &library, passwords: [:], credentials: InMemoryCredentialStore())
        #expect(outcome.createdProfiles.isEmpty && library.sshProfiles.count == 2)
        #expect(library.databaseConnections.allSatisfy { $0.connectFrom == .sshTunnel && $0.sshProfile == bastion.id })
        #expect(outcome.summary.imported.first?.details.first?.contains("through SSH “Bastion”") == true)
    }

    @Test func oneNewProfilePerServerSharedByItsConnections() throws {
        let plan = try Self.plan()
        var library = TargetLibrary(sshProfiles: [SSHProfile(name: "bastion.example.com", host: "elsewhere.example.com", remoteDirectory: "/srv")])
        let options = TablePlusImportOptions(selected: [Self.id(3), Self.id(4), Self.id(5), Self.id(15)])
        let reports = try #require(plan.row(Self.id(3)))
        #expect(plan.defaultSSHChoice(for: reports, in: library) == .newProfile)
        let planned = plan.newProfiles(options: options, library: library)
        #expect(planned.count == 3)
        let bastion = try #require(planned.first { $0.server.host == "bastion.example.com" })
        #expect(bastion.rowIDs == [Self.id(3), Self.id(4)])
        #expect(bastion.profile.name == "bastion.example.com 2", "the name doesn't clash with an existing profile")
        #expect(bastion.profile.identityFile == "~/.ssh/acme_deploy" && bastion.profile.authentication == .automatic)
        #expect(bastion.profile.user == "deploy" && bastion.profile.port == nil)
        #expect(bastion.profile.environment == .staging, "production only when every connection using it is")
        #expect(bastion.profile.validate().isEmpty)

        let web = try #require(planned.first { $0.server.host == "web1.example.com" })
        #expect(web.profile.authentication == .interactive && web.profile.identityFile == nil && web.profile.port == 2222)
        #expect(web.notes.contains { $0.contains("password at Connect…") })
        let ops = try #require(planned.first { $0.server.host == "ops.example.com" })
        #expect(ops.profile.authentication == .automatic && ops.profile.identityFile == nil)
        #expect(ops.profile.environment == .production)

        let outcome = TablePlusImport.apply(plan, options: options, library: &library, passwords: [:], credentials: InMemoryCredentialStore())
        #expect(outcome.createdProfiles.count == 3 && library.sshProfiles.count == 4)
        #expect(outcome.summary.createdProfiles.map(\.name) == ["bastion.example.com 2", "web1.example.com", "ops.example.com"])
        let created = try #require(library.sshProfiles.first { $0.name == "bastion.example.com 2" })
        let tunnelled = library.databaseConnections.filter { $0.sshProfile == created.id }
        #expect(Set(tunnelled.map(\.name)) == ["Acme Reports", "Acme Billing"])
        #expect(tunnelled.allSatisfy { $0.usesSSHTunnel && $0.host.hasSuffix(".internal.example.com") })
        // The profile encodes its key path, and nothing secret.
        let text = String(decoding: try JSONEncoder().encode(created), as: UTF8.self)
        #expect(text.contains("acme_deploy") && !text.lowercased().contains("password"))
    }

    @Test func choosingNotToUseSSHOrAnotherProfile() throws {
        let plan = try Self.plan()
        let other = SSHProfile(name: "Jump", host: "jump.example.net", remoteDirectory: "/srv")
        var library = TargetLibrary(sshProfiles: [other])
        let options = TablePlusImportOptions(selected: [Self.id(5), Self.id(6)], sshChoices: [Self.id(5): .direct, Self.id(6): .existing(other.id)])
        #expect(plan.newProfiles(options: options, library: library).isEmpty)
        let outcome = TablePlusImport.apply(plan, options: options, library: &library, passwords: [:], credentials: InMemoryCredentialStore())
        let blog = try #require(library.databaseConnections.first { $0.name == "Example Blog" })
        #expect(blog.connectFrom == .thisMac && blog.sshProfile == nil)
        #expect(outcome.summary.needsAttention.first { $0.name == "Example Blog" }?.details.contains { $0.contains("without SSH") } == true)
        let analytics = try #require(library.databaseConnections.first { $0.name == "Example Analytics" })
        #expect(analytics.sshProfile == other.id)
        // A choice of a profile that no longer exists falls back to the default.
        let stale = TablePlusImportOptions(selected: [Self.id(6)], sshChoices: [Self.id(6): .existing(UUID())])
        #expect(plan.sshChoice(for: try #require(plan.row(Self.id(6))), options: stale, in: TargetLibrary()) == .newProfile)
        // SSH settings that can't make a profile import without SSH by default.
        let odd = TablePlusImportRow(TablePlusConnection(id: "x", name: "Odd", driver: "MySQL", host: "db.example.com", ssh: TablePlusSSH(host: "-oProxyCommand=evil", user: "me")))
        #expect(TablePlusImportPlan.profileProblem(odd.source.ssh!) != nil)
    }

    // MARK: Passwords

    @Test func passwordsAreOptInAndGoOnlyToTheCredentialStore() throws {
        let plan = try Self.plan()
        let reader = try Self.reader()
        let credentials = InMemoryCredentialStore()
        var library = TargetLibrary()
        let selected: Set<String> = [Self.id(1), Self.id(2), Self.id(3), Self.id(6), Self.id(7), Self.id(9), Self.id(18)]
        var options = TablePlusImportOptions(selected: selected)
        #expect(!options.copyPasswords)
        #expect(plan.passwordRequests(options: options, library: library).isEmpty)

        options.copyPasswords = true
        let requests = plan.passwordRequests(options: options, library: library)
        #expect(Set(requests) == selected.subtracting([Self.id(7)]), "SQLite files have no password")
        let passwords = TablePlusImport.readPasswords(requests, reader: reader)
        #expect(reader.requestedIDs == requests)
        let outcome = TablePlusImport.apply(plan, options: options, library: &library, passwords: passwords, credentials: credentials)

        func saved(_ name: String) throws -> DatabaseConnection { try #require(library.databaseConnections.first { $0.name == name }) }
        #expect(try credentials.read(saved("Acme Shop (production)").id)?.revealed() == "fixture-tp-Pa55-acme-shop")
        #expect(try credentials.read(saved("Example Analytics").id)?.revealed() == "fixture-tp-Pa55-analytics")
        #expect(credentials.label(try saved("Acme Shop (staging)").id) == "Runlet database: Acme Shop (staging)")
        #expect(outcome.summary.passwordsCopied == 3)
        // Denied, missing, and empty items: imported without a password, with a note.
        #expect(!credentials.exists(try saved("Acme Reports").id))
        #expect(outcome.summary.needsAttention.first { $0.name == "Acme Reports" }?.details.contains { $0.contains("macOS didn't allow") } == true)
        #expect(outcome.summary.needsAttention.first { $0.name == "Local MySQL socket" }?.details.contains { $0.contains("no saved password") } == true)
        #expect(!credentials.exists(try saved("Acme Read Replica").id))
        #expect(credentials.accounts.count == 3)

        // No password reaches the library, its encoding, or the summary.
        let encoded = String(decoding: try JSONEncoder().encode(library), as: UTF8.self)
        let summary = String(describing: outcome.summary)
        for text in [encoded, summary] {
            #expect(!text.contains("fixture-tp-Pa55"))
            #expect(!text.lowercased().contains("password\":"))
        }
        #expect(!encoded.lowercased().contains("password"))
    }

    @Test func passwordOfAnUpdateReplacesTheOldOneOnlyWhenFound() throws {
        let plan = try Self.plan()
        let credentials = InMemoryCredentialStore()
        var library = TargetLibrary()
        _ = TablePlusImport.apply(plan, options: TablePlusImportOptions(selected: [Self.id(1), Self.id(9)]), library: &library, passwords: [:], credentials: credentials)
        let shop = try #require(library.databaseConnections.first { $0.name == "Acme Shop (production)" })
        let socket = try #require(library.databaseConnections.first { $0.name == "Local MySQL socket" })
        try credentials.set(SensitiveString("old-shop"), for: shop.id, label: "x")
        try credentials.set(SensitiveString("old-socket"), for: socket.id, label: "x")
        let options = TablePlusImportOptions(selected: [Self.id(1), Self.id(9)], duplicates: .update, copyPasswords: true)
        let passwords = TablePlusImport.readPasswords(plan.passwordRequests(options: options, library: library), reader: try Self.reader())
        let outcome = TablePlusImport.apply(plan, options: options, library: &library, passwords: passwords, credentials: credentials)
        #expect(try credentials.read(shop.id)?.revealed() == "fixture-tp-Pa55-acme-shop")
        #expect(try credentials.read(socket.id)?.revealed() == "old-socket")
        #expect(outcome.summary.needsAttention.first { $0.name == "Local MySQL socket" }?.details.contains { $0.contains("unchanged") } == true)
    }

    @Test func aRefusedKeychainWriteKeepsTheConnection() throws {
        let plan = try Self.plan()
        let credentials = InMemoryCredentialStore()
        credentials.failsWrites = true
        var library = TargetLibrary()
        let options = TablePlusImportOptions(selected: [Self.id(1)], copyPasswords: true)
        let outcome = TablePlusImport.apply(plan, options: options, library: &library, passwords: [Self.id(1): .found(SensitiveString("fixture-tp-x"))], credentials: credentials)
        #expect(library.databaseConnections.count == 1)
        #expect(outcome.summary.passwordsCopied == 0)
        #expect(outcome.summary.needsAttention.first?.details.contains { $0.contains("couldn't be saved") } == true)
    }

    @Test func noFixturePasswordInStoredDocuments() throws {
        let plan = try Self.plan()
        let credentials = InMemoryCredentialStore()
        var library = TargetLibrary()
        let options = TablePlusImportOptions(selected: Set(plan.rows.map(\.id)), copyPasswords: true)
        let passwords = TablePlusImport.readPasswords(plan.passwordRequests(options: options, library: library), reader: try Self.reader())
        let outcome = TablePlusImport.apply(plan, options: options, library: &library, passwords: passwords, credentials: credentials)
        #expect(outcome.summary.passwordsCopied == 4)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-tableplus-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let paths = AppPaths(root: folder)
        try JSONDocumentStore<TargetLibrary>(url: paths.targets).save(library)
        try JSONDocumentStore<TargetLibrary>(url: paths.targets).save(library)
        var settings = AppSettings()
        settings.setEnabled(.tablePlusImport, true)
        try JSONDocumentStore<AppSettings>(url: paths.settings).save(settings)
        let workspace = WorkspaceDocument(tabs: library.databaseConnections.map { WorkspaceTab(title: $0.name, code: "SELECT 1", target: .sandbox, language: .sql, sqlSavedConnection: $0.name) }, selectedIndex: 0)
        try JSONEncoder().encode(workspace).write(to: folder.appendingPathComponent("acme.runlet"))
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        var scanned = 0
        for file in files where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            #expect(!text.contains("fixture-tp-Pa55"), "\(file.lastPathComponent)")
            scanned += 1
        }
        #expect(scanned >= 3)
        #expect(!String(describing: outcome.summary).contains("fixture-tp-Pa55"))
    }
}
