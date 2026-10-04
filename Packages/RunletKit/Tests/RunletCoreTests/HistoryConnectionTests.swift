import Foundation
import Testing
@testable import RunletCore

/// Run History and SQL snippets remember the SQL connection (#149): the reference's storage
/// (old history and snippet libraries decode unchanged, nothing beyond names is written), the
/// lookup and fallback rules, history merging, search terms, the Connection filter, and the
/// project snippets' `@connection` line.
struct HistoryConnectionTests {
    let project = TargetRef.local(UUID())
    let profile = TargetRef.docker(UUID())

    static func connection(_ name: String, scope: TargetRef?) -> DatabaseConnection {
        DatabaseConnection(name: name, scope: scope, connectFrom: scope == nil ? .thisMac : .target, driver: .pgsql, host: "db.internal", port: 5432, database: "reports", user: "reader")
    }

    func entry(_ code: String, connection: SQLConnectionReference?, target: TargetRef? = nil, at seconds: TimeInterval = 0, language: TabLanguage = .sql) -> HistoryEntry {
        HistoryEntry(runId: UUID(), timestamp: Date(timeIntervalSince1970: seconds), code: code, target: target ?? project, targetLabel: "orders", status: .completed, reason: "completed", elapsedMs: 4, language: language, connection: connection)
    }

    // MARK: Storage

    @Test func everyKindRoundTripsWithNamesOnly() throws {
        let saved = Self.connection("Reporting", scope: project)
        let shared = Self.connection("Analytics", scope: nil)
        let references: [SQLConnectionReference] = [.application(nil), .application("reporting"), SQLConnectionReference(saved), SQLConnectionReference(shared), .saved(name: "Reporting"), .named("reporting")]
        for reference in references {
            let data = try JSONEncoder().encode(reference)
            #expect(try JSONDecoder().decode(SQLConnectionReference.self, from: data) == reference)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(Set(object.keys).isSubset(of: ["kind", "name", "id", "allTargets"]), "\(object)")
        }
        #expect(SQLConnectionReference(shared) == .saved(name: "Analytics", id: shared.id, allTargets: true))
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(SQLConnectionReference(saved))) as? [String: Any])
        #expect(object["allTargets"] == nil, "only written for a connection of all targets")
    }

    /// The whole entry holds the connection's name and id, never its host, user, database, or
    /// password.
    @Test func historyHoldsNoConnectionDetails() throws {
        let saved = Self.connection("Reporting", scope: project)
        let encoded = try #require(String(data: JSONEncoder().encode(entry("select 1", connection: SQLConnectionReference(saved))), encoding: .utf8))
        #expect(encoded.contains("Reporting") && encoded.contains(saved.id.uuidString))
        for detail in ["db.internal", "reader", "reports", "5432", "password", "pgsql"] {
            #expect(!encoded.contains(detail), "\(detail) in \(encoded)")
        }
    }

    @Test func historySavedBeforeConnectionsDecodesWithout() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","runId":"\(UUID().uuidString)","timestamp":0,"code":"select 1","target":{"sandbox":{}},"targetLabel":"Sandbox","status":"completed","reason":"completed","elapsedMs":5,"language":"sql"},
         {"id":"\(UUID().uuidString)","runId":"\(UUID().uuidString)","timestamp":0,"code":"app()","target":{"sandbox":{}},"targetLabel":"Sandbox","status":"completed","reason":"completed","elapsedMs":5}]
        """
        let entries = try JSONDecoder().decode([HistoryEntry].self, from: Data(json.utf8))
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.connection == nil })
        #expect(entries[0].language == .sql && entries[1].language == nil)
        // An entry without a connection writes no key, as before.
        let reencoded = try #require(String(data: JSONEncoder().encode(entries), encoding: .utf8))
        #expect(!reencoded.contains("connection"))
    }

    /// A connection a newer Runlet records in a way this one doesn't know is dropped; the entry
    /// (and the rest of the history) still loads.
    @Test func unknownConnectionKindsAreLeftOut() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","runId":"\(UUID().uuidString)","timestamp":0,"code":"select 1","target":{"sandbox":{}},"targetLabel":"Sandbox","status":"completed","reason":"completed","elapsedMs":5,"language":"sql","connection":{"kind":"tunnel","name":"x"}},
         {"id":"\(UUID().uuidString)","runId":"\(UUID().uuidString)","timestamp":0,"code":"select 2","target":{"sandbox":{}},"targetLabel":"Sandbox","status":"completed","reason":"completed","elapsedMs":5,"language":"sql","connection":{"kind":"saved"}}]
        """
        let entries = try JSONDecoder().decode([HistoryEntry].self, from: Data(json.utf8))
        #expect(entries.map(\.code) == ["select 1", "select 2"])
        #expect(entries.allSatisfy { $0.connection == nil })
    }

    @Test func phpRunsNeverRecordAConnection() {
        #expect(entry("app()", connection: .application("mysql"), language: .php).connection == nil)
        #expect(entry("select 1", connection: .application(nil)).connection == .application(nil))
    }

    @Test func snippetsKeepAConnectionByNameOnly() throws {
        let saved = Self.connection("Reporting", scope: project)
        let snippet = Snippet(label: "Revenue", code: "select 1", language: .sql, connection: SQLConnectionReference(saved))
        #expect(snippet.connection == .saved(name: "Reporting"), "no id, so the snippet works on other targets and Macs")
        #expect(Snippet(label: "x", code: "select 1", language: .sql, connection: .application(nil)).connection == nil, "the default connection is what every SQL tab starts on")
        #expect(Snippet(label: "x", code: "1", connection: .application("mysql")).connection == nil, "PHP snippets have none")
        let decoded = try JSONDecoder().decode(Snippet.self, from: JSONEncoder().encode(snippet))
        #expect(decoded == snippet)

        // Libraries saved before #149, and connections this Runlet can't read.
        let old = #"[{"id":"\#(UUID().uuidString)","label":"Old","code":"select 1","createdAt":0,"updatedAt":0,"language":"sql"},{"id":"\#(UUID().uuidString)","label":"Newer","code":"select 2","createdAt":0,"updatedAt":0,"language":"sql","connection":{"kind":"future"}}]"#
        let snippets = try JSONDecoder().decode([Snippet].self, from: Data(old.utf8))
        #expect(snippets.map(\.label) == ["Old", "Newer"])
        #expect(snippets.allSatisfy { $0.connection == nil })
        #expect(!(String(data: try JSONEncoder().encode(snippets), encoding: .utf8) ?? "").contains("connection"))
    }

    // MARK: Lookup and fallback

    @Test func savedConnectionsResolveByIdThenByName() {
        var library = TargetLibrary()
        let own = library.saveDatabaseConnection(Self.connection("Reporting", scope: project))
        let otherTargets = library.saveDatabaseConnection(Self.connection("Billing", scope: profile))
        let shared = library.saveDatabaseConnection(Self.connection("Analytics", scope: nil))

        // By id on its own target; a connection of all targets on any target.
        #expect(library.resolve(SQLConnectionReference(own), on: project) == .saved(own))
        #expect(library.resolve(SQLConnectionReference(shared), on: profile) == .saved(shared))
        #expect(library.resolve(SQLConnectionReference(shared), on: .sandbox) == .saved(shared))

        // Renamed since the run: still found by id.
        var renamed = own
        renamed.name = "Reports"
        renamed = library.saveDatabaseConnection(renamed)
        #expect(library.resolve(.saved(name: "Reporting", id: own.id), on: project) == .saved(renamed))

        // Another target's own connection is never used, not even by id.
        #expect(library.resolve(SQLConnectionReference(otherTargets), on: project) == .missing("Billing"))

        // Deleted: by name, the target's own first, then one of all targets.
        let gone = SQLConnectionReference.saved(name: "analytics", id: UUID())
        #expect(library.resolve(gone, on: project) == .saved(shared))
        let sameNameOwn = library.saveDatabaseConnection(Self.connection("Analytics", scope: project))
        #expect(library.resolve(gone, on: project) == .saved(sameNameOwn))
        #expect(library.resolve(gone, on: profile) == .saved(shared))
        #expect(library.resolve(.saved(name: "Nowhere", id: UUID()), on: project) == .missing("Nowhere"))
        #expect(library.resolve(.saved(name: "Reporting"), on: profile) == .missing("Reporting"), "a snippet's name finds no other target's connection")
    }

    @Test func applicationAndBareNames() {
        var library = TargetLibrary()
        #expect(library.resolve(.application(nil), on: project) == .application(nil))
        #expect(library.resolve(.application("reporting"), on: project) == .application("reporting"))
        // A bare project-snippet name: the application's connection unless a saved one has it.
        #expect(library.resolve(.named("reporting"), on: project) == .application("reporting"))
        let saved = library.saveDatabaseConnection(Self.connection("Reporting", scope: project))
        #expect(library.resolve(.named("reporting"), on: project) == .saved(saved))
        #expect(library.resolve(.named("reporting"), on: profile) == .application("reporting"))
        // An application name is kept even when a saved connection has it.
        #expect(library.resolve(.application("Reporting"), on: project) == .application("Reporting"))
    }

    @Test func theMissingNote() {
        #expect(SQLConnectionReference.missingNote("Reporting", source: "entry") == "The connection “Reporting” from this entry no longer exists; using the default connection.")
        #expect(SQLConnectionReference.missingNote("Reporting", source: "snippet").contains("from this snippet"))
    }

    // MARK: History

    @Test func theSameStatementOnAnotherConnectionIsItsOwnEntry() {
        let reporting = SQLConnectionReference.application("reporting")
        var history = HistoryLog.recording(entry("select * from orders", connection: .application(nil), at: 1), into: [], limit: 10)
        history = HistoryLog.recording(entry("select * from orders", connection: reporting, at: 2), into: history, limit: 10)
        #expect(history.map(\.connection) == [reporting, .application(nil)])

        // Again on Reporting: that entry moves up, keeping its id.
        let id = history[0].id
        history = HistoryLog.recording(entry("select * from orders ", connection: reporting, at: 3), into: history, limit: 10)
        #expect(history.count == 2 && history[0].id == id && history[0].timestamp == Date(timeIntervalSince1970: 3))

        // A saved connection is the same entry after a rename (its id).
        let saved = Self.connection("Reporting", scope: project)
        history = HistoryLog.recording(entry("select 1", connection: SQLConnectionReference(saved), at: 4), into: history, limit: 10)
        var renamed = saved
        renamed.name = "Reports"
        history = HistoryLog.recording(entry("select 1", connection: SQLConnectionReference(renamed), at: 5), into: history, limit: 10)
        #expect(history.count == 3 && history[0].connection?.title == "Reports")
    }

    @Test func anEntryFromBeforeConnectionsIsReplaced() {
        let legacy = entry("select 1", connection: nil, at: 1)
        let history = HistoryLog.recording(entry("select 1", connection: .application("reporting"), at: 2), into: [legacy], limit: 10)
        #expect(history.count == 1 && history[0].id == legacy.id && history[0].connection == .application("reporting"))
        #expect(HistoryLog.collapsingDuplicates([entry("select 1", connection: .application("a")), entry("select 1", connection: .application("b")), entry("select 1", connection: .application("a"))]).count == 2)
    }

    @Test func theConnectionFilter() {
        let shared = Self.connection("Analytics", scope: nil)
        var renamed = shared
        renamed.name = "Analytics (old)"
        let history = [
            entry("select 1", connection: .application(nil), at: 1),
            entry("select 2", connection: .application("reporting"), at: 2),
            entry("select 3", connection: SQLConnectionReference(renamed), at: 3),
            entry("select 4", connection: SQLConnectionReference(shared), at: 4),
            entry("select 5", connection: nil, at: 5),
            entry("app()", connection: nil, at: 6, language: .php),
        ]
        let choices = HistoryLog.connections(in: history)
        // Each connection once, with its newest name, by title.
        #expect(choices.map(\.title) == ["Analytics", "Default connection", "reporting"])
        #expect(HistoryLog.filtered(history, connection: nil).count == 6)
        #expect(HistoryLog.filtered(history, connection: SQLConnectionReference(shared).identity).map(\.code) == ["select 3", "select 4"])
        #expect(HistoryLog.filtered(history, connection: SQLConnectionReference.application(nil).identity).map(\.code) == ["select 1"], "older SQL runs and PHP runs have no connection to filter by")
        #expect(HistoryLog.connections(in: [entry("select 1", connection: .application(nil))]).count == 1)
    }

    @Test func searchTermsAndTitles() {
        #expect(SQLConnectionReference.application(nil).title == "Default connection")
        #expect(SQLConnectionReference.application("reporting").title == "reporting")
        #expect(SQLConnectionReference.saved(name: "Reporting", id: UUID()).title == "Reporting")
        #expect(SQLConnectionReference.named("reporting").title == "reporting")
        // The History pane searches the title with the code and target.
        let row = entry("select count(*) from orders", connection: .saved(name: "Reporting", id: UUID()))
        #expect(matchesSearch("orders report", in: row.code, row.targetLabel, row.connection?.title ?? ""))
        #expect(!matchesSearch("billing", in: row.code, row.targetLabel, row.connection?.title ?? ""))
    }

    // MARK: Project snippets

    private func parse(_ contents: String) -> ProjectSnippet {
        ProjectSnippets.parse(contents, fileURL: URL(fileURLWithPath: "/project/.runlet/snippets/revenue.sql"))
    }

    @Test func projectSnippetsReadTheirConnection() {
        let snippet = parse("""
        -- @label Monthly revenue
        -- @connection reporting

        SELECT sum(total) FROM orders;
        """)
        #expect(snippet.label == "Monthly revenue")
        #expect(snippet.connection == .named("reporting"))
        #expect(snippet.code == "SELECT sum(total) FROM orders;")

        // Alone, it is metadata too; `(saved)` means only a saved connection.
        let alone = parse("-- @connection Reporting replica (saved)\nselect 1;")
        #expect(alone.connection == .saved(name: "Reporting replica"))
        #expect(alone.code == "select 1;" && alone.label == "revenue")

        // In a docblock, as `@label` can be.
        let docblock = parse("/**\n * @label Revenue\n * @connection  analytics \n */\nselect 1;")
        #expect(docblock.connection == .named("analytics") && docblock.code == "select 1;")

        // An empty value, and PHP snippets, have none.
        #expect(parse("-- @label X\n-- @connection\nselect 1;").connection == nil)
        let php = ProjectSnippets.parse("<?php\n/**\n * @label X\n * @connection reporting\n */\n\nDB::select('select 1');", fileURL: URL(fileURLWithPath: "/project/.runlet/snippets/x.php"))
        #expect(php.connection == nil && php.label == "X")
        let phpOnlyConnection = ProjectSnippets.parse("<?php\n/** @connection reporting */\necho 1;", fileURL: URL(fileURLWithPath: "/project/.runlet/snippets/y.php"))
        #expect(phpOnlyConnection.code.contains("@connection"), "in PHP, a docblock with only @connection is code")
    }

    @Test func savingWritesTheConnectionAndReadsItBack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-149-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let app = try ProjectSnippets.save(label: "Monthly revenue", description: "By month", code: "SELECT 1;", projectRoot: root, language: .sql, connection: .application("reporting"))
        let appText = try String(contentsOf: app, encoding: .utf8)
        #expect(appText == "-- @label Monthly revenue\n-- @description By month\n-- @connection reporting\n\nSELECT 1;\n")

        let saved = try ProjectSnippets.save(label: "Replica", description: nil, code: "SELECT 2;", projectRoot: root, language: .sql, connection: SQLConnectionReference(Self.connection("Reporting replica", scope: project)))
        let savedText = try String(contentsOf: saved, encoding: .utf8)
        #expect(savedText.contains("-- @connection Reporting replica (saved)\n"))
        #expect(!savedText.contains("db.internal") && !savedText.contains("reader"))

        let loaded = ProjectSnippets.load(projectRoot: root)
        #expect(loaded.first { $0.label == "Monthly revenue" }?.connection == .named("reporting"))
        #expect(loaded.first { $0.label == "Replica" }?.connection == .saved(name: "Reporting replica"))
        #expect(loaded.allSatisfy { !$0.code.contains("@connection") })

        // No line for the default connection, and none in PHP files.
        #expect(!ProjectSnippets.fileContents(label: "X", description: nil, code: "select 1", language: .sql, connection: .application(nil)).contains("@connection"))
        #expect(!ProjectSnippets.fileContents(label: "X", description: nil, code: "1", language: .php, connection: .application("reporting")).contains("@connection"))
        // Only a connection: the header is just that line.
        #expect(ProjectSnippets.fileContents(label: "", description: nil, code: "select 1", language: .sql, connection: .named("reporting")) == "-- @connection reporting\n\nselect 1\n")
    }
}
