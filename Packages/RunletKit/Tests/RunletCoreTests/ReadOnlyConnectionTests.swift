import Foundation
import Testing
@testable import RunletCore

/// Read-only saved connections and their own environment marking (#139): which statements a
/// read-only connection refuses before sending them, the stricter-of marking, and decoding of
/// connections saved before this phase.
struct ReadOnlyConnectionTests {
    // MARK: Refusals

    @Test func sessionChangesAreRefusedWhateverTheCaseOrComments() {
        let changes: [(String, String)] = [
            ("SET SESSION TRANSACTION READ WRITE", "SET TRANSACTION READ WRITE"),
            ("set session transaction read write", "SET TRANSACTION READ WRITE"),
            ("SET TRANSACTION READ WRITE", "SET TRANSACTION READ WRITE"),
            ("/* undo */ SET  SESSION\n TRANSACTION -- now\n READ /* x */ WRITE", "SET TRANSACTION READ WRITE"),
            ("SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED, READ WRITE", "SET TRANSACTION READ WRITE"),
            ("SET GLOBAL TRANSACTION READ WRITE", "SET TRANSACTION READ WRITE"),
            ("SET transaction_read_only = 0", "SET transaction_read_only"),
            ("SET SESSION transaction_read_only = OFF", "SET transaction_read_only"),
            ("set @@session.transaction_read_only=0", "SET transaction_read_only"),
            ("SET @@tx_read_only = 0", "SET tx_read_only"),
            ("SET SESSION tx_read_only = 0", "SET tx_read_only"),
            ("SET `transaction_read_only` = 0", "SET transaction_read_only"),
            ("SET STATEMENT transaction_read_only=0 FOR INSERT INTO t VALUES (1)", "SET transaction_read_only"),
            ("SET default_transaction_read_only = off", "SET default_transaction_read_only"),
            ("SET default_transaction_read_only TO DEFAULT", "SET default_transaction_read_only"),
            ("SET LOCAL transaction_read_only = off", "SET transaction_read_only"),
            ("SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE", "SET SESSION CHARACTERISTICS … READ WRITE"),
            ("SET SESSION CHARACTERISTICS AS TRANSACTION ISOLATION LEVEL SERIALIZABLE", "SET SESSION CHARACTERISTICS"),
            ("BEGIN READ WRITE", "BEGIN … READ WRITE"),
            ("begin transaction isolation level serializable, read write", "BEGIN … READ WRITE"),
            ("BEGIN ISOLATION LEVEL READ COMMITTED READ WRITE", "BEGIN … READ WRITE"),
            ("START TRANSACTION READ WRITE", "START TRANSACTION READ WRITE"),
            ("start transaction with consistent snapshot, read write", "START TRANSACTION READ WRITE"),
            ("RESET ALL", "RESET ALL"),
            ("reset default_transaction_read_only", "RESET default_transaction_read_only"),
            ("RESET transaction_read_only", "RESET transaction_read_only"),
            ("DISCARD ALL", "DISCARD ALL"),
            ("PRAGMA query_only = 0", "PRAGMA query_only"),
            ("pragma QUERY_ONLY=false", "PRAGMA query_only"),
            ("PRAGMA main.query_only = OFF", "PRAGMA query_only"),
            ("PRAGMA query_only(0)", "PRAGMA query_only"),
            ("PRAGMA query_only", "PRAGMA query_only"),
            ("SELECT set_config('default_transaction_read_only', 'off', false)", "set_config()"),
            ("select SET_CONFIG('transaction_read_only', 'off', true)", "set_config()"),
            ("ALTER ROLE reader SET default_transaction_read_only = off", "ALTER … SET default_transaction_read_only"),
        ]
        for (sql, phrase) in changes {
            #expect(SQLScript.readOnlyRefusal(of: sql) == .sessionChange(phrase), "\(sql)")
        }
        let message = SQLReadOnlyRefusal.sessionChange("SET TRANSACTION READ WRITE").message(connection: "Replica")
        #expect(message.hasPrefix("This statement would make the read-only session writable again (SET TRANSACTION READ WRITE), so Runlet doesn't send it on the read-only connection “Replica”. Nothing ran."))
        #expect(message.contains("use a saved connection without Read-only"))
        #expect(SQLReadOnlyRefusal.title(connection: "Replica") == "“Replica” is read-only")
    }

    @Test func writesAndUnknownStatementsAreRefused() {
        let writes: [(String, SQLReadOnlyRefusal)] = [
            ("INSERT INTO t VALUES (1)", .write("INSERT")),
            ("  -- note\n update t set a = 1", .write("UPDATE")),
            ("delete from t", .write("DELETE")),
            ("CREATE TABLE x (id int)", .write("CREATE")),
            ("create temporary table x (id int)", .write("CREATE")),
            ("DROP TABLE x", .write("DROP")),
            ("TRUNCATE x", .write("TRUNCATE")),
            ("with gone as (delete from t returning *) select * from gone", .write("DELETE")),
            ("select * into outfile '/tmp/x' from t", .write("SELECT … INTO")),
            ("select * from t for update", .write("FOR UPDATE, which locks rows")),
            ("explain analyze delete from t", .write("EXPLAIN ANALYZE … DELETE")),
            ("PRAGMA user_version = 3", .write("PRAGMA … =")),
            ("PRAGMA journal_mode(DELETE)", .write("PRAGMA … (…)")),
            ("SET SESSION TRANSACTION READ ONLY", .write("SET")),
            ("SET search_path TO reports", .write("SET")),
            ("RESET search_path", .write("RESET")),
            ("CALL refresh()", .write("CALL")),
            ("DO $$ BEGIN PERFORM 1; END $$", .write("DO")),
            ("USE other", .unknown("USE")),
            ("CHECKPOINT", .unknown("CHECKPOINT")),
            ("LISTEN jobs", .unknown("LISTEN")),
            ("select 1; delete from t", .unknown("several statements")),
        ]
        for (sql, refusal) in writes {
            #expect(SQLScript.readOnlyRefusal(of: sql) == refusal, "\(sql)")
        }
        #expect(SQLReadOnlyRefusal.write("INSERT").predicate == "can change data or the schema (INSERT)")
        #expect(SQLReadOnlyRefusal.write("SET").predicate.hasPrefix("changes the session's settings (SET)"))
        #expect(SQLReadOnlyRefusal.unknown("USE").predicate == "starts with USE, and Runlet can't tell whether it changes data")
        let script = SQLReadOnlyRefusal.write("INSERT").message(connection: "Replica", index: 2, count: 4, line: 3, others: 1)
        #expect(script.hasPrefix("Statement 2 of 4 (line 3) can change data or the schema (INSERT), so Runlet runs none of the script on the read-only connection “Replica”. Nothing ran. One more statement would be refused too."))
    }

    @Test func readsAndPlainTransactionControlRun() {
        for sql in ["select * from orders", "SELECT 'insert into t' AS text, \"delete\" FROM t -- drop table t", "SHOW TABLES", "describe orders",
                    "explain select 1", "explain analyze select 1", "with x as (select 1) select * from x", "values (1)", "table orders",
                    "PRAGMA table_info(orders)", "pragma main.index_list('orders')", "PRAGMA foreign_key_list(orders)",
                    "SELECT @@transaction_read_only", "SELECT @@session.tx_read_only", "SHOW default_transaction_read_only",
                    "SHOW transaction_read_only", "select current_setting('transaction_read_only')", "SELECT 'READ WRITE'",
                    "BEGIN", "begin transaction", "START TRANSACTION", "START TRANSACTION READ ONLY", "BEGIN READ ONLY",
                    "COMMIT", "ROLLBACK", "SAVEPOINT a", "RELEASE SAVEPOINT a", "END", "select 1;", "-- only a note"] {
            #expect(SQLScript.readOnlyRefusal(of: sql) == nil, "\(sql)")
        }
    }

    /// What the databases read differently from the editor's lexer.
    @Test func eachDatabasesReadingCounts() {
        // MySQL: a backslash escapes the quote, so INTO OUTFILE is code there.
        let backslash = #"SELECT 'x\'' INTO OUTFILE '/tmp/x' -- '"#
        #expect(SQLScript.readOnlyRefusal(of: backslash, driver: .mysql) != nil)
        #expect(SQLScript.readOnlyRefusal(of: backslash) != nil)
        // MySQL runs what is in an executable comment.
        #expect(SQLScript.readOnlyRefusal(of: "SELECT * FROM t /*!50000 INTO OUTFILE '/tmp/x' */", driver: .mysql) == .write("SELECT … INTO"))
        #expect(SQLScript.readOnlyRefusal(of: "SELECT 1 /*M!100000 , set_config('a', 'b', false) */", driver: .mysql) == .sessionChange("set_config()"))
        // PostgreSQL: # is an operator, not a comment.
        let hash = "SELECT 1 # 0, set_config('default_transaction_read_only', 'off', false)"
        #expect(SQLScript.readOnlyRefusal(of: hash, driver: .pgsql) == .sessionChange("set_config()"))
        #expect(SQLScript.readOnlyRefusal(of: hash) == .sessionChange("set_config()"))
        // …and E'' strings take backslash escapes.
        #expect(SQLScript.readOnlyRefusal(of: #"SELECT E'x\'' , set_config('default_transaction_read_only', 'off', false) -- '"#, driver: .pgsql) == .sessionChange("set_config()"))
        // A MySQL # comment with a write keyword stays a comment on MySQL.
        #expect(SQLScript.readOnlyRefusal(of: "SELECT 1 # we delete nothing", driver: .mysql) == nil)
        #expect(SQLScript.readOnlyRefusal(of: #"SELECT 'C:\path', 'a\\b' FROM t"#, driver: .mysql) == nil)
    }

    // MARK: Marking

    @Test func theStricterMarkingApplies() {
        let id = UUID()
        let target = TargetRef.local(id)
        var library = TargetLibrary()
        library.localProjects = [LocalProject(id: id, name: "Shop", path: "/tmp/shop", color: .blue)]
        var connection = DatabaseConnection(name: "Replica", scope: target, driver: .pgsql, host: "db")

        #expect(library.marking(for: target) == EnvironmentMarking(environment: .development, color: .blue))
        #expect(library.marking(for: target, connection: connection) == EnvironmentMarking(environment: .development, color: .blue))

        connection.environment = .production
        connection.color = .red
        let production = library.marking(for: target, connection: connection)
        #expect(production == EnvironmentMarking(environment: .production, color: .red, fromConnection: true))
        #expect(production.isProduction)

        connection.environment = .staging
        #expect(library.marking(for: target, connection: connection).environment == .staging)

        // A production target stays production with a development connection.
        library.localProjects[0].environment = .production
        connection.environment = nil
        connection.color = nil
        #expect(library.marking(for: target, connection: connection) == EnvironmentMarking(environment: .production, color: .blue, fromConnection: false))
        connection.environment = .production
        #expect(library.marking(for: target, connection: connection).fromConnection == false, "the target is already production")

        #expect(TargetEnvironment.stricter(.staging, .production) == .production)
        #expect(TargetEnvironment.stricter(.production, .development) == .production)
        #expect(TargetEnvironment.stricter(.development, .staging) == .staging)
    }

    // MARK: Storage

    @Test func connectionsSavedBeforeThisPhaseDecodeAsBefore() throws {
        let legacy = #"{"id":"\#(UUID().uuidString)","name":"Legacy","scope":{"local":{"_0":"\#(UUID().uuidString)"}},"driver":"pgsql","host":"db","database":"shop","user":"u","connectTimeout":10,"revision":3}"#
        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: Data(legacy.utf8))
        #expect(decoded.readOnly == false)
        #expect(decoded.environment == nil && decoded.environmentMarking == .development)
        #expect(decoded.color == nil)
        #expect(decoded.revision == 3)
        // Re-encoded, it keeps the same keys: nothing at its default is written.
        let keys = Set(try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]).keys)
        #expect(keys == ["id", "name", "scope", "driver", "host", "database", "user", "connectTimeout", "revision"])

        var marked = decoded
        marked.readOnly = true
        marked.environment = .production
        marked.color = .orange
        let data = try JSONEncoder().encode(marked)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["readOnly"] as? Bool == true)
        #expect(object["environment"] as? String == "production")
        #expect(object["color"] as? String == "orange")
        #expect(try JSONDecoder().decode(DatabaseConnection.self, from: data) == marked)

        // Unknown values from a newer Runlet don't drop the connection.
        let newer = #"{"id":"\#(UUID().uuidString)","name":"N","scope":{"local":{"_0":"\#(UUID().uuidString)"}},"driver":"mysql","readOnly":"maybe","environment":"qa","color":"ultraviolet"}"#
        let lenient = try JSONDecoder().decode(DatabaseConnection.self, from: Data(newer.utf8))
        #expect(lenient.readOnly == false && lenient.environmentMarking == .development && lenient.color == .gray)
    }

    @Test func aTargetsFileFromBeforeLoadsUnchanged() throws {
        let target = UUID()
        let file = #"""
        {"localProjects":[{"id":"\#(target.uuidString)","name":"Shop","path":"/tmp/shop","revision":1}],
         "databaseConnections":[{"id":"\#(UUID().uuidString)","name":"Reporting","scope":{"local":{"_0":"\#(target.uuidString)"}},"driver":"mysql","host":"127.0.0.1","database":"shop","user":"reader","connectTimeout":10,"revision":1}]}
        """#
        let library = try JSONDecoder().decode(TargetLibrary.self, from: Data(file.utf8))
        let connection = try #require(library.databaseConnections.first)
        #expect(connection.readOnly == false && connection.environment == nil && connection.color == nil)
        #expect(library.marking(for: .local(target), connection: connection).environment == .development)
    }

    @Test func normalizedStoresDevelopmentAsNilAndDuplicatesKeepTheMarking() {
        var connection = DatabaseConnection(name: "R", scope: .local(UUID()), driver: .sqlite, database: "a.sqlite", readOnly: true, environment: .development, color: .teal)
        #expect(connection.normalized.environment == nil)
        connection.environment = .production
        let copy = connection.duplicated()
        #expect(copy.readOnly && copy.environment == .production && copy.color == .teal)
    }

    @Test func runRequestsCarryTheReadOnlyFlag() throws {
        var request = RunRequest(tabId: UUID(), documentVersion: 1, target: TargetSnapshot(kind: .local, label: "Shop", targetId: "x", workingDirectory: "/tmp", phpExecutable: "php"), code: "<?php")
        request.sqlConnection = DatabaseConnection(name: "R", scope: .local(UUID()), driver: .sqlite, database: "a.sqlite", readOnly: true)
        let decoded = try JSONDecoder().decode(RunRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded.sqlConnection?.readOnly == true)
    }

    @Test func testReportsSayTheSessionIsReadOnly() {
        let info = SQLConnectionTestInfo(driver: "pgsql", serverVersion: "14.23", database: "shop", user: "reader", roundTripMs: 1.25, readOnly: true)
        #expect(info.summary == "Connected: PostgreSQL 14.23 · database shop · user reader · 1.2 ms round trip · read-only session")
    }
}
