import Foundation
import Testing
@testable import RunletCore

/// Bound parameters in SQL tabs (#145): finding placeholders, rows and drafts (#168),
/// `-- @param` presets, remembered values, history text, and the generated PHP.
struct SQLParameterTests {
    func statement(_ text: String, line: Int = 1) -> SQLScript.Statement {
        SQLScript.Statement(text: text, range: NSRange(location: 0, length: (text as NSString).length), startLine: line)
    }

    func scan(_ text: String, driver: DatabaseDriverKind? = nil) -> SQLParameterScan {
        SQLParameters.scan([statement(text)], driver: driver)
    }

    /// `draft.set` outside `#expect`, which can't call a mutating method.
    func set(_ draft: inout SQLParameterDraft, type: SQLParameterType? = nil, text: String? = nil) -> Bool {
        draft.set(type: type, text: text)
    }

    func placeholders(_ text: String, driver: DatabaseDriverKind? = nil) -> [String] {
        scan(text, driver: driver).parameters.map(\.placeholder)
    }

    // MARK: Detection

    @Test func findsNamedAndPositionalPlaceholders() {
        let named = scan("SELECT * FROM orders\nWHERE customer_id = :customer AND status = :status\n  AND id > :customer")
        #expect(named.parameters.map(\.placeholder) == [":customer", ":status"])
        #expect(named.parameters.map(\.line) == [2, 2])
        #expect(named.parameters.map(\.uses) == [2, 1])
        #expect(named.statementKeys == [[.named("customer"), .named("status")]])
        #expect(named.problem == nil)

        let positional = scan("UPDATE orders SET status = ? WHERE id = ?")
        #expect(positional.parameters.map(\.placeholder) == ["?1", "?2"])
        #expect(positional.statementKeys == [[.positional(statement: 0, index: 1), .positional(statement: 0, index: 2)]])
        #expect(scan("SELECT 1").isEmpty)
    }

    @Test func placeholdersInStringsCommentsAndQuotedNamesDontCount() {
        #expect(placeholders("SELECT ':nope', '?', \"col?\", `odd:name` FROM t -- :later ?\n/* :x ? */ WHERE a = :a # why?") == [":a"])
        #expect(placeholders("SELECT $$ :body ? $$, $tag$ ? $tag$ WHERE id = ?") == ["?1"])
    }

    @Test func castsAssignmentsAndPDOEscapesAreNotPlaceholders() {
        // PostgreSQL casts and MySQL's := assignment.
        #expect(placeholders("SELECT created_at::date, id::text FROM t WHERE id = :id") == [":id"])
        #expect(placeholders("SELECT @n := @n + 1 FROM t") == [])
        // `??` is PDO's escape for PostgreSQL's ? operators (`?|`, `?&`, `?`).
        #expect(placeholders("SELECT data ??| array['a'], data ??& array['b'], data ?? 'k' FROM t WHERE id = ?") == ["?1"])
        #expect(placeholders("SELECT data #> '{a}', data #- '{b}' FROM t", driver: .pgsql) == [])
        #expect(scan("SELECT ??").isEmpty)
        // `???` is an escaped `?` followed by a placeholder, as PDO reads it.
        #expect(placeholders("SELECT data ??? FROM t") == ["?1"])
    }

    @Test func readsTheStatementAsItsDatabaseWould() {
        // MySQL's backslash escape keeps `:x` inside the string; elsewhere `\'` ends it.
        #expect(placeholders(#"SELECT 'it\'s :x' FROM t WHERE id = :id"#, driver: .mysql) == [":id"])
        // PostgreSQL reads # as an operator, so what follows it counts.
        #expect(placeholders("SELECT 1 # :mask", driver: .pgsql) == [":mask"])
        #expect(placeholders("SELECT 1 # :mask", driver: .mysql) == [])
    }

    @Test func refusesWhatPDOCantBind() {
        let mixed = scan("SELECT * FROM t\nWHERE a = :a AND b = ?")
        #expect(mixed.problem?.kind == .mixed)
        #expect(mixed.problem?.line == 2)
        #expect(mixed.problem?.description.contains("mixes :name and ? placeholders") == true)
        #expect(scan("SELECT ? , :a").problem?.kind == .mixed)

        let numbered = scan("SELECT * FROM t WHERE id = $1")
        #expect(numbered.problem?.kind == .numbered("$1"))
        #expect(numbered.problem?.description.contains("write $1 as :name or ?") == true)

        let accented = scan("SELECT :café")
        #expect(accented.problem?.kind == .invalidName(":café"))
        #expect(scan("SELECT :a$b").problem?.kind == .invalidName(":a$b"))
    }

    @Test func runAllSharesNamesAndKeepsEachStatementsQuestionMarks() {
        let text = "INSERT INTO t (a, b) VALUES (:a, ?);\nUPDATE t SET b = :b WHERE a = :a;\nSELECT ?, ? FROM t;\nSELECT 1"
        let statements = SQLScript.statements(in: text)
        let scan = SQLParameters.scan(statements)
        // The first statement mixes; the problem names it.
        #expect(scan.problem?.kind == .mixed)
        #expect(scan.problem?.description.hasPrefix("Statement 1 of 4 (line 1)") == true)

        let fixed = SQLParameters.scan(SQLScript.statements(in: "INSERT INTO t (a) VALUES (:a);\nUPDATE t SET b = :b WHERE a = :a;\nSELECT ?, ? FROM t;\nSELECT ? FROM t;\nSELECT 1"))
        #expect(fixed.problem == nil)
        #expect(fixed.parameters.map(\.placeholder) == [":a", ":b", "?1", "?2", "?1"])
        #expect(fixed.parameters.map(\.statement) == [nil, nil, 2, 2, 3])
        #expect(fixed.parameters.map(\.line) == [1, 2, 3, 3, 4])
        #expect(fixed.positionalSpansStatements)
        #expect(fixed.statementKeys == [
            [.named("a")],
            [.named("b"), .named("a")],
            [.positional(statement: 2, index: 1), .positional(statement: 2, index: 2)],
            [.positional(statement: 3, index: 1)],
            [],
        ])
        let values: [SQLParameter.Key: SQLParameterValue] = [
            .named("a"): .integer(1), .named("b"): .text("x"),
            .positional(statement: 2, index: 1): .null, .positional(statement: 2, index: 2): .boolean(true),
            .positional(statement: 3, index: 1): .decimal("1.50"),
        ]
        let bindings = try? #require(fixed.bindings(values))
        #expect(bindings?.map(\.count) == [1, 2, 2, 1, 0])
        #expect(bindings?[1].map(\.target) == [.name("b"), .name("a")])
        #expect(bindings?[2].map(\.target) == [.position(1), .position(2)])
        #expect(bindings?[3].first?.value == .decimal("1.50"))
        // A missing value makes no bindings.
        var missing = values
        missing[.named("b")] = nil
        #expect(fixed.bindings(missing) == nil)
    }

    @Test func usesCountRepeatsWithinOneStatement() {
        let scan = SQLParameters.scan(SQLScript.statements(in: "SELECT :a, :a, :b;\nSELECT :b"))
        #expect(scan.parameters.map(\.uses) == [2, 1])
        let bindings = scan.bindings([.named("a"): .integer(1), .named("b"): .integer(2)])
        #expect(bindings?[0].map(\.uses) == [2, 1])
        #expect(bindings?[1].map(\.uses) == [1])
    }

    // MARK: Presets

    @Test func paramCommentsPresetTypesAndValues() {
        let text = """
        -- @param :status text paid
        -- @param customer integer 42
        /* @param :since decimal 19.50
         * @param :flag bool true */
        SELECT * FROM orders WHERE status = :status AND customer_id = :customer;
        -- @param ?2 null
        -- @param ?1 text 'it''s here'
        -- @param :status text ignored, the first line wins
        SELECT ?, ? FROM t;
        """
        let statements = SQLScript.statements(in: text)
        let presets = SQLParameters.presets(in: text, statements: statements)
        #expect(presets.problems.isEmpty, "\(presets.problems)")
        #expect(presets.values[.named("status")] == SQLParameterPreset(type: .text, text: "paid"))
        #expect(presets.values[.named("customer")] == SQLParameterPreset(type: .integer, text: "42"))
        #expect(presets.values[.named("since")] == SQLParameterPreset(type: .decimal, text: "19.50"))
        #expect(presets.values[.named("flag")] == SQLParameterPreset(type: .boolean, text: "true"))
        #expect(presets.values[.positional(statement: 1, index: 1)] == SQLParameterPreset(type: .text, text: "it's here"))
        #expect(presets.values[.positional(statement: 1, index: 2)] == SQLParameterPreset(type: .null))
        // A ? preset belongs to its statement only.
        #expect(presets.values[.positional(statement: 0, index: 1)] == nil)
    }

    @Test func unreadableParamLinesAreReported() {
        let text = "-- @param :id number\n-- @param :x whatever 1\n-- @param ? text a\n-- @param :y text \"open\n-- @paramx :z text\nSELECT :id"
        let presets = SQLParameters.presets(in: text, statements: SQLScript.statements(in: text))
        #expect(presets.values[.named("id")] == SQLParameterPreset(type: .decimal))
        #expect(presets.problems.count == 3, "\(presets.problems)")
        #expect(presets.problems[0].contains("“whatever” is not a type"))
        #expect(presets.problems[1].contains("Number a ? placeholder"))
        #expect(presets.problems[2].contains("closing quote"))
    }

    // MARK: Rows and drafts

    @Test func rowsStartWithRememberedThenPresetThenNotSet() {
        let statements = [statement("SELECT :a, :b, :c, :d, :e")]
        let scan = SQLParameters.scan(statements)
        let presets: [SQLParameter.Key: SQLParameterPreset] = [
            .named("a"): SQLParameterPreset(type: .integer, text: "1"),
            .named("b"): SQLParameterPreset(type: .boolean, text: "yes"),
            .named("c"): SQLParameterPreset(type: .integer, text: "3"),
            // A type without a value isn't a value.
            .named("e"): SQLParameterPreset(type: .integer),
        ]
        var memory = SQLParameterMemory()
        memory.set(SQLParameterDraft(.text("remembered")), for: SQLParameterMemory.key(scan.parameters[2], statements: statements))
        let rows = SQLParameterRows.make(scan, statements: statements, presets: presets, memory: memory)
        #expect(rows.map(\.source) == [.preset, .preset, .typed, .none, .preset])
        #expect(rows.map(\.draft.type) == [.integer, .boolean, .text, .text, .integer])
        #expect(rows.map(\.draft.text) == ["1", "", "remembered", "", ""])
        #expect(rows[1].draft.flag)
        #expect(rows.map(\.isSet) == [true, true, true, false, false])
        #expect(rows.map(\.issue) == [nil, nil, nil, "Not set", "Not set"])
        #expect(SQLParameterRows.values(rows) == nil)
        #expect(SQLParameterRows.values(Array(rows.prefix(3))) == [.named("a"): .integer(1), .named("b"): .boolean(true), .named("c"): .text("remembered")])
    }

    @Test func draftsValidateEachType() {
        var draft = SQLParameterDraft()
        #expect(set(&draft, type: .integer, text: "12a"))
        #expect(draft.error == "Enter a whole number, like 42.")
        #expect(set(&draft, text: " -7 "))
        #expect(draft.value == .success(.integer(-7)))
        #expect(set(&draft, type: .decimal, text: "1,5"))
        #expect(draft.error == "Use a dot for decimals, like 1.5.")
        #expect(set(&draft, text: " 19.990 "))
        #expect(draft.value == .success(.decimal("19.990")))
        #expect(set(&draft, type: .boolean, text: "false"))
        #expect(!set(&draft, text: "maybe"))
        #expect(draft.value == .success(.boolean(false)))
        #expect(set(&draft, type: .null))
        #expect(draft.value == .success(.null))
        #expect(set(&draft, type: .text, text: "  spaced  "))
        #expect(draft.value == .success(.text("  spaced  ")))
        // An empty text is an empty string once the row is set.
        #expect(SQLParameterDraft(type: .text).value == .success(.text("")))
        #expect(SQLParameterDraft(.boolean(true)) == SQLParameterDraft(type: .boolean, flag: true))
        #expect(SQLParameterDraft(.integer(4)) == SQLParameterDraft(type: .integer, text: "4"))
    }

    @Test func rowsAreAddressedByPlaceholderAndStatement() {
        let scan = SQLParameters.scan(SQLScript.statements(in: "SELECT ?;\nSELECT ?, ?;\nSELECT :name"))
        let match = { (placeholder: String) in scan.parameters.filter { SQLParameterRows.matches($0, placeholder) }.map(\.key) }
        #expect(match("?1@2") == [.positional(statement: 1, index: 1)])
        #expect(match("?2") == [.positional(statement: 1, index: 2)])
        #expect(match("?1") == [.positional(statement: 0, index: 1), .positional(statement: 1, index: 1)])
        #expect(match(":name") == [.named("name")])
        #expect(match("name") == [.named("name")])
    }

    @Test func memoryKeepsNamesAcrossStatementsAndQuestionMarksPerStatement() {
        let first = [statement("SELECT * FROM t WHERE a = :a")]
        var memory = SQLParameterMemory()
        memory.set(SQLParameterDraft(.integer(5)), for: SQLParameterMemory.key(SQLParameters.scan(first).parameters[0], statements: first))
        let other = [statement("DELETE FROM t WHERE a = :a")]
        #expect(memory.draft(for: SQLParameterMemory.key(SQLParameters.scan(other).parameters[0], statements: other)) == SQLParameterDraft(.integer(5)))

        let positional = [statement("SELECT ? FROM t")]
        memory.set(SQLParameterDraft(.text("x")), for: SQLParameterMemory.key(SQLParameters.scan(positional).parameters[0], statements: positional))
        let spaced = [statement("  SELECT ? FROM t\n")]
        #expect(memory.draft(for: SQLParameterMemory.key(SQLParameters.scan(spaced).parameters[0], statements: spaced)) == SQLParameterDraft(.text("x")))
        let different = [statement("SELECT ? FROM u")]
        #expect(memory.draft(for: SQLParameterMemory.key(SQLParameters.scan(different).parameters[0], statements: different)) == nil)
    }

    /// The values `-- @param` lines give a script, as the drawer reads them.
    func presetValues(_ text: String) -> [SQLParameter.Key: SQLParameterValue]? {
        let statements = SQLScript.statements(in: text)
        let rows = SQLParameterRows.make(SQLParameters.scan(statements), statements: statements, presets: SQLParameters.presets(in: text, statements: statements).values, memory: SQLParameterMemory())
        return SQLParameterRows.values(rows)
    }

    // MARK: Display, history, and the generated PHP

    @Test func valuesDisplayAsSQLWould() {
        #expect(SQLParameterValue.text("it's").display() == "'it''s'")
        #expect(SQLParameterValue.text("a\nb").display() == "'a\\nb'")
        #expect(SQLParameterValue.text(String(repeating: "x", count: 10)).display(limit: 4) == "'xxxx…'")
        #expect(SQLParameterValue.integer(-3).display() == "-3")
        #expect(SQLParameterValue.decimal("19.990").display() == "19.990")
        #expect(SQLParameterValue.boolean(true).display() == "true")
        #expect(SQLParameterValue.null.display() == "NULL")
    }

    @Test func historyKeepsTheValuesAsParamLinesThatPresetTheDrawerAgain() {
        let text = "SELECT * FROM orders WHERE status = :status AND total > :total"
        let statements = SQLScript.statements(in: text)
        let scan = SQLParameters.scan(statements)
        let values: [SQLParameter.Key: SQLParameterValue] = [.named("status"): .text("it's \"paid\"\n"), .named("total"): .decimal("10.5")]
        let history = SQLParameters.historyCode(text, start: 0, end: (text as NSString).length, statements: statements, scan: scan, values: values)
        #expect(history == """
        -- @param :status text "it's \\"paid\\"\\n"
        -- @param :total decimal 10.5
        SELECT * FROM orders WHERE status = :status AND total > :total
        """)
        // Reopened from history, the lines preset the same values.
        let reopened = SQLScript.statements(in: history)
        #expect(presetValues(history) == values)
        // The statement still runs as written: the lines are its leading comment.
        #expect(reopened.count == 1)
        #expect(SQLScript.effect(of: reopened[0].text) == .read)
    }

    @Test func runAllHistoryPutsEachStatementsQuestionMarksBeforeIt() {
        let text = "-- report\nSELECT :a; SELECT ? FROM t;\nSELECT 2;\nSELECT ?, ?"
        let statements = SQLScript.statements(in: text)
        let scan = SQLParameters.scan(statements)
        let values: [SQLParameter.Key: SQLParameterValue] = [
            .named("a"): .boolean(true),
            .positional(statement: 1, index: 1): .integer(7),
            .positional(statement: 3, index: 1): .null,
            .positional(statement: 3, index: 2): .text(""),
        ]
        let history = SQLParameters.historyCode(text, start: statements[0].range.location, end: NSMaxRange(statements[3].range), statements: statements, scan: scan, values: values)
        #expect(history == """
        -- @param :a boolean true
        -- report
        SELECT :a;
        -- @param ?1 integer 7
        SELECT ? FROM t;
        SELECT 2;
        -- @param ?1 null
        -- @param ?2 text ""
        SELECT ?, ?
        """)
        #expect(SQLScript.statements(in: history).count == 4)
        #expect(presetValues(history) == values)
    }

    @Test func generatedPHPCarriesValuesAsDataNotSQL() {
        let sql = "SELECT * FROM t WHERE a = :a AND b = :b"
        let tricky = "'; DROP TABLE t; -- $x \\ \n ?>"
        let code = SQLTabRun.code(statement: sql, connection: nil, bindings: [
            SQLBinding(target: .name("a"), value: .text(tricky), uses: 2),
            SQLBinding(target: .name("b"), value: .null),
        ])
        #expect(code.contains(#"SqlTab::run("SELECT * FROM t WHERE a = :a AND b = :b", null, 1000, false, [['name' => 'a', 'type' => 'str', 'value' => "'; DROP TABLE t; -- \$x \\ \n ?>", 'uses' => 2], ['name' => 'b', 'type' => 'null', 'value' => null]]);"#), "\(code)")
        // Without values, the code is what it was before #145.
        #expect(SQLTabRun.code(statement: "SELECT 1", connection: nil, schema: true) == SQLTabRun.code(statement: "SELECT 1", connection: nil, schema: true, bindings: []))
        #expect(SQLTabRun.code(statement: "SELECT 1", connection: "x").hasSuffix(#"SqlTab::run("SELECT 1", "x", 1000);"#))

        let positional = SQLTabRun.code(statement: "SELECT ?, ?, ?", connection: nil, schema: true, bindings: [
            SQLBinding(target: .position(1), value: .integer(Int.min)),
            SQLBinding(target: .position(2), value: .decimal("1.50")),
            SQLBinding(target: .position(3), value: .boolean(false)),
        ])
        #expect(positional.contains("true, [['position' => 1, 'type' => 'int', 'value' => -9223372036854775807-1], ['position' => 2, 'type' => 'decimal', 'value' => '1.50'], ['position' => 3, 'type' => 'bool', 'value' => false]]);"), "\(positional)")

        let statements = SQLScript.statements(in: "SELECT :a;\nSELECT 1")
        let script = SQLTabRun.scriptCode(statements: statements, connection: nil, transaction: true, bindings: [[SQLBinding(target: .name("a"), value: .integer(1))], []])
        #expect(script.contains("['sql' => \"SELECT :a\", 'line' => 1, 'params' => [['name' => 'a', 'type' => 'int', 'value' => 1]]],"), "\(script)")
        #expect(script.contains("['sql' => \"SELECT 1\", 'line' => 2],"), "\(script)")
    }
}
