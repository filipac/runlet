import Foundation
import Testing
@testable import RunletCore

/// The parameters drawer's model (#168): rows from the text and the caret, prefilled from
/// the tab's memory and `-- @param` comments, values kept across edits and statement switches.
struct SQLParameterDrawerTests {
    static let script = """
    -- Leases at or above a rent
    SELECT tenant, rent FROM leases
    WHERE rent >= :min_rent AND tenant <> :skip;

    SELECT id FROM leases WHERE id IN (?, ?);

    SELECT count(*) FROM leases;
    """

    /// The caret at the start of `line` (1-based).
    func caret(_ text: String, line: Int) -> NSRange {
        var location = 0
        for (index, part) in text.components(separatedBy: "\n").enumerated() where index < line - 1 {
            location += (part as NSString).length + 1
        }
        return NSRange(location: location, length: 0)
    }

    /// `update` and `set` outside `#expect`, which can't call a mutating method.
    func update(_ drawer: inout SQLParameterDrawerModel, text: String, selection: NSRange, driver: DatabaseDriverKind?) -> Bool {
        drawer.update(text: text, selection: selection, driver: driver)
    }

    func set(_ drawer: inout SQLParameterDrawerModel, _ placeholder: String, type: SQLParameterType? = nil, text: String? = nil) -> Bool {
        drawer.set(placeholder, type: type, text: text)
    }

    func placeholders(_ drawer: SQLParameterDrawerModel) -> [String] {
        drawer.content.rows.map(\.parameter.placeholder)
    }

    func texts(_ drawer: SQLParameterDrawerModel) -> [String] {
        drawer.content.rows.map { $0.isSet ? $0.draft.text : "-" }
    }

    @Test func rowsFollowTheCaretAndHideWithoutPlaceholders() {
        let text = Self.script
        var drawer = SQLParameterDrawerModel()
        #expect(update(&drawer, text: text, selection: caret(text, line: 3), driver: nil))
        #expect(placeholders(drawer) == [":min_rent", ":skip"])
        #expect(drawer.content.rows.map(\.parameter.line) == [3, 3])
        #expect(drawer.content.statementCount == 3)
        #expect(!drawer.content.isEmpty)
        // Nothing changed: no work, no change.
        #expect(!update(&drawer, text: text, selection: caret(text, line: 3), driver: nil))

        drawer.update(text: text, selection: caret(text, line: 5), driver: nil)
        #expect(placeholders(drawer) == ["?1", "?2"])
        #expect(drawer.content.rows.map(\.parameter.line) == [5, 5])

        drawer.update(text: text, selection: caret(text, line: 7), driver: nil)
        #expect(drawer.content.isEmpty)
        #expect(drawer.content.summary == "No parameters")

        // A selection is what Run sends.
        let selected = (text as NSString).range(of: "rent >= :min_rent")
        drawer.update(text: text, selection: selected, driver: nil)
        #expect(placeholders(drawer) == [":min_rent"])
        // Several statements selected: Run refuses, the drawer shows nothing.
        drawer.update(text: text, selection: NSRange(location: 0, length: (text as NSString).length), driver: nil)
        #expect(drawer.content.isEmpty)
    }

    @Test func rowsArePrefilledFromParamCommentsUntilSetInTheDrawer() {
        var text = "-- @param :status text paid\n-- @param :limit integer\nSELECT * FROM orders WHERE status = :status LIMIT :limit"
        var drawer = SQLParameterDrawerModel()
        drawer.update(text: text, selection: NSRange(location: (text as NSString).length, length: 0), driver: nil)
        #expect(drawer.content.rows.map(\.source) == [.preset, .preset])
        #expect(drawer.content.rows.map(\.draft.type) == [.text, .integer])
        #expect(texts(drawer) == ["paid", "-"])
        #expect(drawer.content.firstIssue?.parameter.placeholder == ":limit")
        #expect(drawer.content.summary == "2 parameters: :status = 'paid', :limit not set")

        // The comment changes: the row follows it.
        text = text.replacingOccurrences(of: "text paid", with: "text open")
        drawer.update(text: text, selection: NSRange(location: 0, length: 0), driver: nil)
        #expect(texts(drawer) == ["open", "-"])

        // Set in the drawer: it wins over the comment from then on.
        #expect(set(&drawer, ":status", text: "void"))
        #expect(set(&drawer, ":limit", text: "10"))
        #expect(drawer.content.rows.map(\.source) == [.typed, .typed])
        text = text.replacingOccurrences(of: "text open", with: "text closed")
        drawer.update(text: text, selection: NSRange(location: 0, length: 0), driver: nil)
        #expect(texts(drawer) == ["void", "10"])
        #expect(drawer.content.firstIssue == nil)
        #expect(SQLParameterRows.values(drawer.content.rows) == [.named("status"): .text("void"), .named("limit"): .integer(10)])
        #expect(drawer.content.summary == "2 parameters: :status = 'void', :limit = 10")

        // An emptied text field is an empty string, not a missing value.
        #expect(set(&drawer, ":status", text: ""))
        #expect(drawer.content.rows[0].value == .text(""))
        // A number that isn't one is reported.
        #expect(set(&drawer, ":limit", text: "ten"))
        #expect(drawer.content.firstIssue?.issue == "Enter a whole number, like 42.")
        #expect(drawer.content.summary.hasSuffix(":limit not valid"))
    }

    @Test func valuesStayWhenPlaceholdersGoAwayAndComeBack() {
        let with = "SELECT * FROM t WHERE a = :a AND b = :b"
        let without = "SELECT * FROM t WHERE a = :a"
        var drawer = SQLParameterDrawerModel()
        drawer.update(text: with, selection: NSRange(location: 0, length: 0), driver: nil)
        drawer.set(":a", type: .integer, text: "1")
        drawer.set(":b", text: "x")
        drawer.update(text: without, selection: NSRange(location: 0, length: 0), driver: nil)
        #expect(placeholders(drawer) == [":a"])
        drawer.update(text: with, selection: NSRange(location: 0, length: 0), driver: nil)
        #expect(texts(drawer) == ["1", "x"])
        #expect(drawer.content.rows[0].draft.type == .integer)

        // A name keeps its value in another statement of the tab.
        let two = "SELECT :a;\nDELETE FROM t WHERE b = :b"
        drawer.update(text: two, selection: NSRange(location: (two as NSString).length, length: 0), driver: nil)
        #expect(placeholders(drawer) == [":b"])
        #expect(texts(drawer) == ["x"])
    }

    @Test func questionMarksKeepTheirValuesWhileTheStatementIsEdited() {
        var text = "SELECT * FROM t WHERE a = ? AND b = ?;\nSELECT ? FROM u"
        var drawer = SQLParameterDrawerModel()
        drawer.update(text: text, selection: NSRange(location: 3, length: 0), driver: nil)
        drawer.set("?1", type: .integer, text: "7")
        drawer.set("?2", text: "seven")

        // Typing in the statement changes its text; the values follow their positions.
        text = text.replacingOccurrences(of: "b = ?;", with: "b = ? ORDER BY a;")
        drawer.update(text: text, selection: NSRange(location: 3, length: 0), driver: nil)
        #expect(texts(drawer) == ["7", "seven"])
        text = text.replacingOccurrences(of: "ORDER BY a;", with: "AND c = ? ORDER BY a;")
        drawer.update(text: text, selection: NSRange(location: 3, length: 0), driver: nil)
        #expect(placeholders(drawer) == ["?1", "?2", "?3"])
        #expect(texts(drawer) == ["7", "seven", "-"])

        // The other statement's ? is its own; switching back finds the values again.
        drawer.update(text: text, selection: NSRange(location: (text as NSString).length, length: 0), driver: nil)
        #expect(placeholders(drawer) == ["?1"])
        #expect(texts(drawer) == ["-"])
        drawer.set("?1", text: "u")
        drawer.update(text: text, selection: NSRange(location: 3, length: 0), driver: nil)
        #expect(texts(drawer) == ["7", "seven", "-"])

        // Edited right after the caret moved there (one update for both): carried over too.
        drawer.update(text: text, selection: NSRange(location: (text as NSString).length, length: 0), driver: nil)
        text = text.replacingOccurrences(of: "SELECT * FROM t", with: "SELECT a FROM t")
        drawer.update(text: text, selection: NSRange(location: 3, length: 0), driver: nil)
        #expect(texts(drawer) == ["7", "seven", "-"])

        // A new statement typed before it shifts the places: nothing is carried, the texts still match.
        text = "SELECT 1;\n" + text
        drawer.update(text: text, selection: NSRange(location: 14, length: 0), driver: nil)
        #expect(texts(drawer) == ["7", "seven", "-"])
    }

    @Test func aRenamedNameKeepsItsValue() {
        var text = "SELECT * FROM t WHERE a = :min AND b = :b"
        var drawer = SQLParameterDrawerModel()
        drawer.update(text: text, selection: NSRange(location: 0, length: 0), driver: nil)
        drawer.set(":min", type: .integer, text: "1000")
        text = text.replacingOccurrences(of: ":min", with: ":min_rent")
        drawer.update(text: text, selection: NSRange(location: 0, length: 0), driver: nil)
        #expect(placeholders(drawer) == [":min_rent", ":b"])
        #expect(texts(drawer) == ["1000", "-"])
        #expect(drawer.content.rows[0].draft.type == .integer)

        // A removed name isn't a rename: :b doesn't take :min_rent's value.
        text = "SELECT * FROM t WHERE b = :b"
        drawer.update(text: text, selection: NSRange(location: 0, length: 0), driver: nil)
        #expect(texts(drawer) == ["-"])
    }

    @Test func allStatementsShowsEveryValueRunAllNeeds() {
        let text = Self.script
        var drawer = SQLParameterDrawerModel()
        drawer.update(text: text, selection: caret(text, line: 3), driver: nil)
        drawer.set(":min_rent", type: .integer, text: "1000")
        drawer.update(text: text, selection: caret(text, line: 5), driver: nil)
        drawer.set("?2", type: .integer, text: "3")

        drawer.setScope(.all)
        #expect(drawer.scope == .all)
        #expect(placeholders(drawer) == [":min_rent", ":skip", "?1", "?2"])
        #expect(texts(drawer) == ["1000", "-", "-", "3"])
        #expect(drawer.content.namesStatements == false)
        #expect(drawer.content.firstIssue?.parameter.placeholder == ":skip")
        // Values set here are the statement's own too.
        #expect(set(&drawer, "?1@2", type: .integer, text: "1"))
        drawer.setScope(.statement)
        #expect(texts(drawer) == ["1", "3"])

        // ?s in several statements: rows name their statement.
        let positional = "SELECT ?;\nSELECT ?, ?"
        drawer.setScope(.all)
        drawer.update(text: positional, selection: NSRange(location: 0, length: 0), driver: nil)
        #expect(drawer.content.namesStatements)
        #expect(drawer.content.rows.map { $0.label(namesStatements: true) } == ["?1 (statement 1)", "?1 (statement 2)", "?2 (statement 2)"])
    }

    @Test func showsWhatPDOCantBindAndReadsTheTextAsTheDatabaseWould() {
        var drawer = SQLParameterDrawerModel()
        drawer.update(text: "SELECT * FROM t WHERE id = $1", selection: NSRange(location: 0, length: 0), driver: .pgsql)
        #expect(drawer.content.rows.isEmpty)
        #expect(drawer.content.problem?.kind == .numbered("$1"))
        #expect(!drawer.content.isEmpty)

        drawer.update(text: "SELECT 1 # :mask", selection: NSRange(location: 0, length: 0), driver: .mysql)
        #expect(drawer.content.isEmpty)
        drawer.update(text: "SELECT 1 # :mask", selection: NSRange(location: 0, length: 0), driver: .pgsql)
        #expect(placeholders(drawer) == [":mask"])

        // Unreadable `-- @param` lines are listed while there are placeholders.
        drawer.update(text: "-- @param :id whatever 1\nSELECT :id", selection: NSRange(location: 0, length: 0), driver: nil)
        #expect(drawer.content.presetProblems.count == 1)
    }

    @Test func theRunReadsTheDrawersMemory() {
        let text = "SELECT * FROM t WHERE a = :a AND b = ?"
        var drawer = SQLParameterDrawerModel()
        drawer.update(text: text, selection: NSRange(location: 0, length: 0), driver: nil)
        #expect(drawer.content.problem?.kind == .mixed)

        let fine = "-- @param :b text preset\nSELECT * FROM t WHERE a = :a AND b = :b"
        drawer.update(text: fine, selection: NSRange(location: 0, length: 0), driver: nil)
        drawer.set(":a", type: .null)
        let statements = SQLScript.statements(in: fine)
        let scan = SQLParameters.scan(statements)
        let rows = drawer.rows(for: scan, statements: statements, text: fine)
        #expect(SQLParameterRows.values(rows) == [.named("a"): .null, .named("b"): .text("preset")])
    }
}
