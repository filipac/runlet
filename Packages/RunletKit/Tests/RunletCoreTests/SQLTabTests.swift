import Foundation
import Testing
@testable import RunletCore

/// SQL tabs (#35): the tab language, statement scope, write detection, generated PHP, and
/// result decoding.
struct SQLTabTests {
    // MARK: Language and persistence

    @Test func tabsSavedBeforeSQLTabsDecodeAsPHP() throws {
        let id = UUID()
        let old = #"{"id":"\#(id.uuidString)","title":"Old","code":"1","target":{"sandbox":{}},"selection":{"location":0,"length":0},"createdAt":0}"#
        let decoded = try JSONDecoder().decode(TabState.self, from: Data(old.utf8))
        #expect(decoded.language == .php)
        #expect(decoded.sqlConnection == nil)
        #expect(decoded.id == id)
    }

    @Test func sqlTabRoundTripsWithItsConnection() throws {
        let tab = TabState(title: "Users", code: "select 1", language: .sql, sqlConnection: "reporting")
        let decoded = try JSONDecoder().decode(TabState.self, from: JSONEncoder().encode(tab))
        #expect(decoded == tab)
        let session = try JSONDecoder().decode(SessionState.self, from: JSONEncoder().encode(SessionState(tabs: [tab])))
        #expect(session.tabs.first?.language == .sql)
        #expect(session.tabs.first?.sqlConnection == "reporting")
    }

    @Test func unknownLanguagesDecodeAsPHP() throws {
        let decoded = try JSONDecoder().decode([TabLanguage].self, from: Data(#"["sql","php","python",3]"#.utf8))
        #expect(decoded == [.sql, .php, .php, .php])
        #expect(TabLanguage.forFile(URL(fileURLWithPath: "/tmp/report.SQL")) == .sql)
        #expect(TabLanguage.forFile(URL(fileURLWithPath: "/tmp/report.php")) == .php)
    }

    @Test func workspacesKeepSQLTabsAndOldFilesStayPHP() throws {
        let document = WorkspaceDocument(tabs: [
            WorkspaceTab(title: "PHP", code: "1", target: .sandbox),
            WorkspaceTab(title: "SQL", code: "select 1", target: .sandbox, language: .sql, sqlConnection: "sqlite"),
            WorkspaceTab(title: "Explicit PHP", code: "2", target: .sandbox, language: .php),
        ], selectedIndex: 1)
        let data = try document.encoded()
        let json = String(decoding: data, as: UTF8.self)
        // PHP tabs write no language, so their files are unchanged.
        #expect(json.components(separatedBy: "\"language\"").count == 2)
        let read = try WorkspaceDocument.read(from: data)
        #expect(read.tabs.map(\.language) == [nil, .sql, nil])
        #expect(read.tabs[1].sqlConnection == "sqlite")
        let old = try WorkspaceDocument(tabs: [WorkspaceTab(title: "t", code: "1", target: .sandbox)], selectedIndex: 0).encoded()
        #expect(!String(decoding: old, as: UTF8.self).contains("language"))
        #expect(try WorkspaceDocument.read(from: old).tabs.first?.language == nil)
    }

    @Test func historyKeepsSQLAndPHPRunsOfTheSameTextApart() {
        let php = HistoryEntry(runId: UUID(), code: "select 1", target: .sandbox, targetLabel: "S", status: .completed, reason: "completed", elapsedMs: 1)
        let sql = HistoryEntry(runId: UUID(), code: "select 1", target: .sandbox, targetLabel: "S", status: .completed, reason: "completed", elapsedMs: 1, language: .sql)
        let history = HistoryLog.recording(sql, into: [php], limit: 10)
        #expect(history.count == 2)
        #expect(HistoryLog.recording(sql, into: history, limit: 10).count == 2)
        #expect(HistoryEntry(runId: UUID(), code: "1", target: .sandbox, targetLabel: "S", status: .completed, reason: "c", elapsedMs: 1, language: .php).language == nil)
    }

    // MARK: Lexer and statements

    @Test func splitsAtSemicolonsOutsideStringsCommentsAndQuotedBodies() {
        let text = """
        -- the users
        SELECT ';' AS semi, "a;b", `c;d` FROM users WHERE note = 'it''s; fine';
        /* ; */ UPDATE t SET x = $$a;b$$, y = $tag$c;d$tag$ WHERE id = $1 ; # mysql ; comment
        SELECT 1
        ;;
        -- only a comment;
        """
        let statements = SQLScript.statements(in: text)
        #expect(statements.count == 3)
        #expect(statements[0].text.hasPrefix("-- the users\nSELECT"))
        #expect(statements[0].text.hasSuffix("'it''s; fine'"))
        #expect(statements[0].startLine == 1)
        #expect(statements[1].text.hasPrefix("/* ; */ UPDATE"))
        #expect(statements[1].text.hasSuffix("$1"))
        #expect(statements[1].startLine == 3)
        // A comment on the line where a statement ended stays with that line.
        #expect(statements[2].text == "SELECT 1")
        #expect(statements[2].startLine == 4)
    }

    @Test func postgresOperatorsAndCastsAreNotCommentsOrPlaceholders() {
        let tokens = SQLScript.tokenize("select data #> '{a}', data #- '{b}', id::text, :name, ?")
        let kinds = tokens.map(\.kind)
        #expect(!kinds.contains(.comment))
        #expect(kinds.filter { $0 == .placeholder }.count == 2)
        #expect(SQLScript.statements(in: "select data #> '{a;b}' from t").count == 1)
    }

    @Test func unterminatedQuotesRunToTheEnd() {
        #expect(SQLScript.statements(in: "select 'open; select 2").count == 1)
        #expect(SQLScript.statements(in: "select \"open; select 2").count == 1)
        #expect(SQLScript.statements(in: "select 1 /* open; select 2").count == 1)
    }

    @Test func runsTheSelectionWhenItHoldsOneStatement() throws {
        let text = "select 1;\nselect 2;\nselect 3;"
        let range = (text as NSString).range(of: "select 2;")
        let statement = try SQLScript.statementToRun(in: text, selection: range).get()
        #expect(statement.text == "select 2")
        #expect(statement.startLine == 2)
        #expect(statement.range.location == range.location)
    }

    @Test func refusesASelectionWithSeveralStatements() {
        let text = "select 1;\nselect 2;"
        let result = SQLScript.statementToRun(in: text, selection: NSRange(location: 0, length: (text as NSString).length))
        #expect(result == .failure(.multipleStatements(count: 2)))
        if case .failure(let error) = result { #expect(error.description.contains("one statement per run")) }
        #expect(SQLScript.statementToRun(in: text, selection: NSRange(location: 0, length: 0), selectionOnly: true) == .failure(.nothingSelected))
        #expect(SQLScript.statementToRun(in: " -- nothing\n", selection: NSRange(location: 0, length: 0)) == .failure(.empty))
        #expect(SQLScript.statementToRun(in: text, selection: NSRange(location: 0, length: 3)).map(\.text) == .success("sel"))
    }

    @Test func runsTheStatementAtTheCaret() throws {
        let text = "select 1;\n\nselect 2; -- two\n\n\nselect 3"
        func run(at needle: String, offset: Int = 0) throws -> String {
            let location = (text as NSString).range(of: needle).location + offset
            return try SQLScript.statementToRun(in: text, selection: NSRange(location: location, length: 0)).get().text
        }
        #expect(try run(at: "select 1") == "select 1")
        #expect(try run(at: "select 2", offset: 3) == "select 2")
        // Right after a semicolon, or later on that line: the statement that just ended.
        #expect(try run(at: "; -- two", offset: 1) == "select 2")
        #expect(try run(at: "-- two", offset: 4) == "select 2")
        // On a blank line between statements: the next one.
        #expect(try run(at: "\n\n\nselect 3", offset: 1) == "select 3")
        #expect(try SQLScript.statementToRun(in: text, selection: NSRange(location: (text as NSString).length, length: 0)).get().text == "select 3")
        // A single statement runs wherever the caret is.
        #expect(try SQLScript.statementToRun(in: "\n\nselect 9;\n\n", selection: NSRange(location: 0, length: 0)).get().text == "select 9")
    }

    // MARK: Writes

    @Test func detectsStatementsThatCanWrite() {
        let writes: [(String, String)] = [
            ("insert into t values (1)", "INSERT"),
            ("  -- note\n UPDATE t SET a = 1", "UPDATE"),
            ("delete from t", "DELETE"),
            ("REPLACE INTO t VALUES (1)", "REPLACE"),
            ("merge into t using s on (t.id = s.id) when matched then delete", "MERGE"),
            ("create table x (id int)", "CREATE"),
            ("ALTER TABLE x ADD y int", "ALTER"),
            ("drop table x", "DROP"),
            ("truncate x", "TRUNCATE"),
            ("grant all on x to y", "GRANT"),
            ("set global max_connections = 1", "SET"),
            ("with gone as (delete from t returning *) select * from gone", "DELETE"),
            ("select * into backup from t", "SELECT … INTO"),
            ("select * from t for update", "FOR UPDATE, which locks rows"),
            ("explain analyze delete from t", "EXPLAIN ANALYZE … DELETE"),
            ("pragma user_version = 3", "PRAGMA … ="),
            ("call refresh_stats()", "CALL"),
        ]
        for (sql, keyword) in writes {
            #expect(SQLScript.effect(of: sql) == .write(keyword), "\(sql)")
            #expect(SQLScript.effect(of: sql).warning?.contains(keyword) == true)
        }
    }

    @Test func readsHaveNoWarning() {
        for sql in ["select replace(name, 'a', 'b') from users", "SHOW TABLES", "describe users", "explain select * from t",
                    "explain analyze select 1", "with x as (select 1) select * from x", "values (1), (2)", "pragma table_info(users)",
                    "(select 1) union (select 2)", "select 'delete from t' as text, \"update\" from t -- drop table t"] {
            #expect(SQLScript.effect(of: sql) == .read, "\(sql)")
            #expect(SQLScript.effect(of: sql).warning == nil)
        }
        #expect(SQLScript.effect(of: "vacuum") == .write("VACUUM"))
        #expect(SQLScript.effect(of: "begin") == .unknown("BEGIN"))
        #expect(SQLScript.effect(of: "begin").warning?.contains("can't tell") == true)
        #expect(SQLScript.effect(of: "-- nothing") == .unknown(""))
    }

    // MARK: Generated PHP

    @Test func generatedPHPEscapesTheStatementAndConnection() {
        let sql = "select '$name', \"a\\b\", 'it''s'\n\t-- \u{0}"
        let code = SQLTabRun.code(statement: sql, connection: "rep\"orting$x", maxRows: 25)
        #expect(code.hasPrefix("<?php\n"))
        #expect(code.contains(#"\RunletRunner\SqlTab::run("select '\$name', \"a\\b\", 'it''s'\n\t-- \x00", "rep\"orting\$x", 25);"#))
        #expect(SQLTabRun.code(statement: "select 1", connection: nil).contains(#"SqlTab::run("select 1", null, 1000);"#))
        #expect(SQLTabRun.code(statement: "select 1", connection: nil, maxRows: 0).contains(", 1);"))
    }

    // MARK: Results

    @Test func decodesResultsWithEveryCellKind() throws {
        let json = #"""
        {"columns":["id","name","id","price","blob","long","flag"],
         "rows":[[1,"Ada",7,1.5,{"binary":40,"hex":"89504E47"},{"text":"abc","omittedBytes":5000},true],
                 [2,null,8,2,null,"x",false]],
         "truncated":true,"truncation":"rows","elapsedMs":1.234,"connection":null,"driver":"sqlite",
         "source":"Laravel DB::connection()","connections":["sqlite","mysql"],"maxRows":2}
        """#
        let result = try JSONDecoder().decode(SQLResultInfo.self, from: Data(json.utf8))
        #expect(result.columns == ["id", "name", "id", "price", "blob", "long", "flag"])
        #expect(result.rows[0] == [.int(1), .string("Ada"), .int(7), .double(1.5), .binary(bytes: 40, hexPrefix: "89504E47"), .clipped("abc", omittedBytes: 5000), .bool(true)])
        #expect(result.rows[1][1] == .null)
        #expect(result.hasResultSet)
        #expect(result.summary == "First 2 rows (more not shown)")
        #expect(result.elapsedText == "1.23 ms")
        #expect(result.connections == ["sqlite", "mysql"])
        let table = result.table
        // Duplicate column names stay separate columns.
        #expect(table.columns.count == 7)
        #expect(table.rows[1][1].isNull)
        #expect(table.rows[0][3].number == 1.5)
        #expect(table.rows[0][4].text.contains("binary"))
        #expect(table.rowKeys == ["1", "2"])
        #expect(result.plainText.contains("id\tname\tid"))
        #expect(result.markdown.contains("| id | name | id |"))
        #expect(try JSONDecoder().decode(SQLResultInfo.self, from: JSONEncoder().encode(result)) == result)
    }

    @Test func affectedRowsAndSizeTruncationSummaries() throws {
        let update = try JSONDecoder().decode(SQLResultInfo.self, from: Data(#"{"affectedRows":3,"driver":"sqlite"}"#.utf8))
        #expect(!update.hasResultSet)
        #expect(update.summary == "3 rows affected")
        #expect(SQLResultInfo(affectedRows: 1).summary == "1 row affected")
        #expect(SQLResultInfo(columns: ["a"], rows: [[.int(1)]], truncated: true, truncation: "bytes").summary.contains("size limit"))
        #expect(SQLResultInfo(columns: ["a"], rows: []).summary == "0 rows")
    }

    @Test func productionAlwaysAsksForSQLEvenDuringAGrace() {
        var grace = ProductionGrace()
        grace.grant(.sandbox)
        let run = grace.needsConfirmation(.run, on: .sandbox, environment: .production)
        let sql = grace.needsConfirmation(.sql, on: .sandbox, environment: .production)
        let development = grace.needsConfirmation(.sql, on: .sandbox, environment: .development)
        #expect(!run)
        #expect(sql)
        #expect(!development)
    }
}
