import Foundation
import Testing
@testable import RunletCore

/// Saved database connections (#138): the definition, its validation and storage, the
/// credential stores, and that no document Runlet writes or sends ever holds a password.
struct SavedConnectionTests {
    static let password = "fixture-Pa55word;'\"\\ü"

    static func connection(_ name: String = "Reporting", target: TargetRef = .local(UUID()), driver: DatabaseDriverKind = .pgsql) -> DatabaseConnection {
        DatabaseConnection(name: name, scope: target, driver: driver, host: driver == .sqlite ? "" : "127.0.0.1", port: driver == .pgsql ? 5433 : nil, database: driver == .sqlite ? "database/app.sqlite" : "reports", user: "reader")
    }

    func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("runlet-saved-\(UUID().uuidString)", isDirectory: true).appendingPathComponent(name)
    }

    // MARK: Definition

    @Test func codingRoundTripsAndOldFieldsDefault() throws {
        let original = Self.connection()
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(DatabaseConnection.self, from: data) == original)
        let keys = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        #expect(!keys.contains { $0.lowercased().contains("password") })

        let minimal = #"{"id":"\#(UUID().uuidString)","name":"Legacy","scope":{"ssh":{"_0":"\#(UUID().uuidString)"}},"driver":"mysql"}"#
        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: Data(minimal.utf8))
        #expect(decoded.connectTimeout == DatabaseConnection.defaultConnectTimeout)
        #expect(decoded.revision == 1)
        #expect(decoded.host.isEmpty && decoded.user.isEmpty)
        #expect(decoded.effectivePort == 3306)
    }

    @Test func summaryNeverHoldsUserOrPassword() {
        let pgsql = Self.connection()
        #expect(pgsql.summary == "pgsql, 127.0.0.1:5433/reports")
        var mysql = Self.connection(driver: .mysql)
        mysql.database = ""
        #expect(mysql.summary == "mysql, 127.0.0.1:3306")
        var ipv6 = Self.connection()
        ipv6.host = "::1"
        #expect(ipv6.location == "[::1]:5433/reports")
        #expect(Self.connection(driver: .sqlite).summary == "sqlite, database/app.sqlite")
    }

    @Test func validation() {
        let target = TargetRef.docker(UUID())
        var connection = Self.connection(target: target)
        #expect(connection.validate().isEmpty)

        connection.name = "  "
        #expect(connection.validate().contains(.emptyName))
        connection.name = "Two\nlines"
        #expect(connection.validate().contains(.invalidName))
        connection.name = String(repeating: "x", count: 101)
        #expect(connection.validate().contains(.longName))
        connection.name = "reporting"
        let other = Self.connection("Reporting", target: target)
        #expect(connection.validate(others: [other]).contains(.duplicateName))
        #expect(connection.validate(others: [Self.connection("Reporting", target: .local(UUID()))]).isEmpty)
        // The connection itself isn't a duplicate of its saved version.
        #expect(connection.validate(others: [connection]).isEmpty)

        connection.host = ""
        #expect(connection.validate().contains(.emptyHost))
        for host in ["db;dbname=x", "db host", "-oProxy", "db'"] {
            connection.host = host
            #expect(connection.validate().contains(.invalidHost), "\(host)")
        }
        for host in ["db.internal", "10.0.0.5", "::1", "[::1]", "my_db-1", "mariadb"] {
            connection.host = host
            #expect(!connection.validate().contains(.invalidHost), "\(host)")
        }
        connection.port = 0
        #expect(connection.validate().contains(.invalidPort))
        connection.port = 65536
        #expect(connection.validate().contains(.invalidPort))
        connection.port = 6432
        for database in ["a;host=evil", "it's", "a\"b", "a\\b", "tab\there"] {
            connection.database = database
            #expect(connection.validate().contains(.invalidDatabase), "\(database)")
        }
        connection.database = ""
        #expect(connection.validate().isEmpty, "a server connection may leave the database empty")
        connection.user = "bad\nuser"
        #expect(connection.validate().contains(.invalidUser))
        connection.user = "reader"
        connection.connectTimeout = 0
        #expect(connection.validate().contains(.invalidTimeout))
        connection.connectTimeout = 10

        var sqlite = Self.connection(driver: .sqlite)
        sqlite.database = " "
        #expect(sqlite.validate().contains(.emptyPath))
        sqlite.database = "/var/data/app;v2.sqlite"
        #expect(sqlite.validate().isEmpty, "a file path may hold any printable character")
        #expect(DatabaseConnection(name: "S", scope: .sandbox, driver: .sqlite, database: "a.sqlite").validate().contains(.unsupportedTarget))
    }

    @Test func normalizedTrimsAndDropsDefaults() {
        var connection = Self.connection(driver: .mysql)
        connection.name = "  Replica "
        connection.port = 3306
        connection.host = " 127.0.0.1 "
        let normalized = connection.normalized
        #expect(normalized.name == "Replica")
        #expect(normalized.port == nil)
        #expect(normalized.host == "127.0.0.1")
        var sqlite = Self.connection(driver: .sqlite)
        sqlite.host = "leftover"
        sqlite.port = 1
        #expect(sqlite.normalized.host.isEmpty && sqlite.normalized.port == nil)
    }

    @Test func duplicateGetsNewIdentityAndNoPassword() throws {
        let store = InMemoryCredentialStore()
        let original = Self.connection()
        try store.set(SensitiveString(Self.password), for: original.id, label: "Runlet database: Reporting")
        let copy = original.duplicated()
        #expect(copy.id != original.id)
        #expect(copy.name == "Reporting copy")
        #expect(copy.driver == original.driver && copy.host == original.host && copy.user == original.user)
        #expect(try store.read(copy.id) == nil)
        let moved = original.duplicated(named: "Reporting", scope: .ssh(UUID()))
        #expect(moved.name == "Reporting" && moved.scope != original.scope)
    }

    // MARK: Library

    @Test func libraryResolvesCascadesAndKeepsOldFilesLoading() throws {
        let project = LocalProject(name: "Shop", path: "/tmp/shop")
        let docker = DockerProfile(name: "API", identity: ContainerIdentity(containerName: "api"), workingDirectory: "/app")
        var library = TargetLibrary(localProjects: [project], dockerProfiles: [docker])
        let first = library.saveDatabaseConnection(Self.connection("Reporting", target: .local(project.id)))
        library.saveDatabaseConnection(Self.connection("Archive", target: .local(project.id), driver: .mysql))
        let other = library.saveDatabaseConnection(Self.connection("Reporting", target: .docker(docker.id)))
        #expect(library.databaseConnections(for: .local(project.id)).map(\.name) == ["Archive", "Reporting"])

        var edited = first
        edited.host = "10.0.0.2"
        #expect(library.saveDatabaseConnection(edited).revision == 2)

        // By id on its own target; by name elsewhere (a tab moved, a workspace); else nil.
        #expect(library.databaseConnection(id: first.id, name: "Reporting", on: .local(project.id))?.id == first.id)
        #expect(library.databaseConnection(id: first.id, name: "reporting", on: .docker(docker.id))?.id == other.id)
        #expect(library.databaseConnection(id: nil, name: "Missing", on: .local(project.id)) == nil)

        let removed = library.removeDatabaseConnections(for: .local(project.id))
        #expect(Set(removed.map(\.name)) == ["Archive", "Reporting"])
        #expect(library.databaseConnections.map(\.id) == [other.id])
        #expect(library.removeDatabaseConnection(other.id)?.id == other.id)
        #expect(library.databaseConnections.isEmpty)

        // targets.json from before saved connections, and one with a newer Runlet's driver.
        let old = #"{"localProjects":[],"dockerProfiles":[]}"#
        #expect(try JSONDecoder().decode(TargetLibrary.self, from: Data(old.utf8)).databaseConnections.isEmpty)
        let scope = #"{"local":{"_0":"\#(project.id.uuidString)"}}"#
        let newer = #"{"localProjects":[],"databaseConnections":[{"id":"\#(UUID().uuidString)","name":"Future","scope":\#(scope),"driver":"oracle"},{"id":"\#(UUID().uuidString)","name":"Kept","scope":\#(scope),"driver":"sqlite","database":"a.sqlite"}]}"#
        #expect(try JSONDecoder().decode(TargetLibrary.self, from: Data(newer.utf8)).databaseConnections.map(\.name) == ["Kept"])
    }

    @Test func targetsFileHoldsDefinitionsNeverPasswords() throws {
        let store = JSONDocumentStore<TargetLibrary>(url: tempURL("targets.json"))
        let credentials = InMemoryCredentialStore()
        let project = LocalProject(name: "Shop", path: "/tmp/shop")
        var library = TargetLibrary(localProjects: [project])
        let saved = library.saveDatabaseConnection(Self.connection(target: .local(project.id)))
        try credentials.set(SensitiveString(Self.password), for: saved.id, label: "Runlet database: \(saved.name)")
        try store.save(library)
        try store.save(library)
        let folder = store.url.deletingLastPathComponent()
        for file in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            let text = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            #expect(!text.contains("fixture-Pa55word"), "\(file)")
            #expect(!text.lowercased().contains("password"), "\(file)")
            #expect(text.contains("Reporting"), "\(file)")
        }
        #expect(store.load(default: TargetLibrary()).value.databaseConnections == [saved])
    }

    // MARK: Requests, sessions, workspaces

    @Test func runRequestEncodesTheDefinitionWithoutAPassword() throws {
        let connection = Self.connection()
        let target = TargetSnapshot(kind: .local, label: "Shop", targetId: "x", workingDirectory: "/tmp", phpExecutable: "php")
        var request = RunRequest(tabId: UUID(), documentVersion: 1, target: target, code: SQLTabRun.code(statement: "SELECT 1", connection: nil))
        request.sqlConnection = connection
        let data = try JSONEncoder().encode(request)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("Pa55word"))
        #expect(!text.lowercased().contains("password"))
        #expect(!request.code.contains("127.0.0.1") && !request.code.contains("reader"), "the generated PHP holds no definition")
        let decoded = try JSONDecoder().decode(RunRequest.self, from: data)
        #expect(decoded.sqlConnection == connection)
        // Requests from before saved connections.
        var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old["sqlConnection"] = nil
        #expect(try JSONDecoder().decode(RunRequest.self, from: JSONSerialization.data(withJSONObject: old)).sqlConnection == nil)
    }

    @Test func sessionsKeepTheIdAndNameOnly() throws {
        let connection = Self.connection()
        let tab = TabState(title: "SQL 1", code: "SELECT 1", target: connection.scope!, language: .sql, sqlSavedConnection: connection.id, sqlSavedConnectionName: connection.name)
        let session = SessionState(tabs: [tab])
        let data = try JSONEncoder().encode(session)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("127.0.0.1") && !text.contains("reader") && !text.lowercased().contains("password"))
        let decoded = try JSONDecoder().decode(SessionState.self, from: data)
        #expect(decoded.tabs.first?.sqlSavedConnection == connection.id)
        #expect(decoded.tabs.first?.sqlSavedConnectionName == "Reporting")
        // Sessions from before saved connections.
        let old = #"{"tabs":[{"id":"\#(UUID().uuidString)","title":"T","code":"","target":{"sandbox":{}},"selection":{"location":0,"length":0},"createdAt":0,"language":"sql","sqlConnection":"mysql"}]}"#
        let legacy = try JSONDecoder().decode(SessionState.self, from: Data(old.utf8))
        #expect(legacy.tabs.first?.sqlSavedConnection == nil && legacy.tabs.first?.sqlConnection == "mysql")
    }

    @Test func workspacesKeepTheNameOnly() throws {
        let tab = WorkspaceTab(title: "SQL", code: "SELECT 1", target: .sandbox, language: .sql, sqlConnection: "ignored", sqlSavedConnection: "Reporting")
        #expect(tab.sqlConnection == nil)
        let document = WorkspaceDocument(tabs: [tab], selectedIndex: 0)
        let text = String(decoding: try document.encoded(), as: UTF8.self)
        #expect(text.contains(#""sqlSavedConnection" : "Reporting""#))
        #expect(!text.lowercased().contains("password") && !text.contains("127.0.0.1"))
        let decoded = try WorkspaceDocument.read(from: document.encoded())
        #expect(decoded.tabs.first?.sqlSavedConnection == "Reporting")
    }

    @Test func schemaKeysSeparateApplicationAndSavedConnections() {
        let id = UUID()
        #expect(SQLConnectionRef.app(nil).key == "app:")
        #expect(SQLConnectionRef.app("mysql").key == "app:mysql")
        #expect(SQLConnectionRef.saved(id).key == "saved:" + id.uuidString)
        #expect(SQLConnectionRef.saved(id).isSaved && !SQLConnectionRef.app(nil).isSaved)
    }

    @Test func resultsAndTestsDescribeTheConnection() throws {
        let saved = try JSONDecoder().decode(SQLResultInfo.self, from: Data(#"{"columns":["a"],"rows":[[1]],"driver":"pgsql","connection":"Reporting","saved":true,"source":"saved connection \"Reporting\" (pgsql, 127.0.0.1:5433/reports)"}"#.utf8))
        #expect(saved.originText == "via saved connection \"Reporting\" (pgsql, 127.0.0.1:5433/reports)")
        let app = SQLResultInfo(driver: "sqlite", source: "Laravel DB::connection()")
        #expect(app.originText == "sqlite · default connection · via Laravel DB::connection()")

        let maria = SQLConnectionTestInfo(driver: "mysql", serverVersion: "11.4.2-MariaDB-ubu2404", database: "shop", user: "root@%", roundTripMs: 0.42)
        #expect(maria.summary == "Connected: MariaDB 11.4.2-ubu2404 · database shop · user root@% · 0.4 ms round trip")
        #expect(SQLConnectionTestInfo(driver: "pgsql", serverVersion: "14.12", database: "shop", user: "postgres").summary == "Connected: PostgreSQL 14.12 · database shop · user postgres")
    }

    // MARK: Secrets

    @Test func sensitiveStringNeverPrints() {
        let secret = SensitiveString(Self.password)
        #expect("\(secret)" == "•••")
        #expect(String(describing: secret) == "•••")
        #expect(!String(reflecting: secret).contains("Pa55word"))
        var dumped = ""
        dump(secret, to: &dumped)
        #expect(!dumped.contains("Pa55word"))
        #expect(Mirror(reflecting: secret).children.isEmpty)
        struct Holder { var password: SensitiveString }
        var holder = ""
        dump(Holder(password: secret), to: &holder)
        #expect(!holder.contains("Pa55word"))
        #expect(!"\(Holder(password: secret))".contains("Pa55word"))
        #expect(secret.revealed() == Self.password)
    }

    @Test func inMemoryStore() throws {
        let store = InMemoryCredentialStore()
        let id = UUID()
        #expect(!store.exists(id))
        #expect(try store.read(id) == nil)
        try store.set(SensitiveString("one"), for: id, label: "Runlet database: A")
        try store.set(SensitiveString("two"), for: id, label: "Runlet database: B")
        #expect(store.exists(id))
        #expect(try store.read(id)?.revealed() == "two")
        #expect(store.label(id) == "Runlet database: B")
        try store.delete(id)
        try store.delete(id)
        #expect(!store.exists(id))
        store.failsWrites = true
        #expect(throws: CredentialStoreError.self) { try store.set(SensitiveString("x"), for: id, label: "x") }
    }

    @Test func scratchDataFoldersUseTheirOwnKeychainService() {
        let standard = AppPaths(root: URL(fileURLWithPath: "/Users/someone/Library/Application Support/Runlet"))
        #expect(KeychainCredentialStore.service(for: standard, standard: standard) == "dev.runlet.Runlet.database")
        let scratch = KeychainCredentialStore.service(for: AppPaths(root: URL(fileURLWithPath: "/private/tmp/runlet-shots")), standard: standard)
        #expect(scratch.hasPrefix("dev.runlet.Runlet.database."))
        #expect(scratch.count == "dev.runlet.Runlet.database.".count + 8)
        #expect(scratch == KeychainCredentialStore.service(for: AppPaths(root: URL(fileURLWithPath: "/private/tmp/runlet-shots/")), standard: standard))
        #expect(scratch != KeychainCredentialStore.service(for: AppPaths(root: URL(fileURLWithPath: "/private/tmp/other")), standard: standard))
    }

    /// The real Keychain, under a test-only service, only with RUNLET_TEST_KEYCHAIN=1 (it writes
    /// to the login keychain, then deletes what it wrote). Never part of a normal test run.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUNLET_TEST_KEYCHAIN"] == "1", "set RUNLET_TEST_KEYCHAIN=1 to use the login keychain"))
    func keychainRoundTrip() throws {
        let store = KeychainCredentialStore(service: "dev.runlet.Runlet.database.tests-\(UUID().uuidString.prefix(8))")
        let id = UUID()
        defer { try? store.delete(id) }
        #expect(!store.exists(id))
        try store.set(SensitiveString(Self.password), for: id, label: "Runlet database: test")
        #expect(store.exists(id))
        #expect(try store.read(id)?.revealed() == Self.password)
        try store.set(SensitiveString("replaced"), for: id, label: "Runlet database: test")
        #expect(try store.read(id)?.revealed() == "replaced")
        try store.delete(id)
        #expect(!store.exists(id))
        #expect(try store.read(id) == nil)
    }
}

/// AI clients never learn about saved connections (#138): `list_targets` lists targets only.
struct SavedConnectionMCPTests {
    @Test func listTargetsLeavesSavedConnectionsOut() throws {
        let project = LocalProject(name: "Shop", path: "/tmp/shop")
        var library = TargetLibrary(localProjects: [project])
        library.saveDatabaseConnection(DatabaseConnection(name: "Reporting replica", scope: .local(project.id), driver: .pgsql, host: "db.internal", database: "reports", user: "reader"))
        let json = MCPCatalog.targets(library, sandbox: .init(label: "Laravel Sandbox 12"), sshState: { _ in .willConnect })
        let text = String(describing: json)
        #expect(text.contains("Shop"))
        #expect(!text.contains("Reporting replica") && !text.contains("db.internal") && !text.contains("reader"))
    }
}
