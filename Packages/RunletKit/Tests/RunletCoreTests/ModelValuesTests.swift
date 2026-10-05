import Foundation
import Testing
@testable import RunletCore

/// Values | Object for Eloquent models (#307): the Values tree as the runner sends it, its
/// titles, table, plain text, inline summaries, exports, and the remembered choice.
struct ModelValuesTests {
    func node(_ json: String) throws -> ValueNode {
        try JSONDecoder().decode(ValueNode.self, from: Data(json.utf8))
    }

    static func string(_ text: String) -> ValueNode {
        var node = ValueNode(id: 0, type: .string, scalar: text)
        node.length = text.utf8.count
        return node
    }

    static func int(_ value: Int) -> ValueNode { ValueNode(id: 0, type: .int, scalar: String(value)) }

    static func attribute(_ key: String, _ value: ValueNode, hidden: Bool = false, dirty: Bool = false, original: ValueNode? = nil) -> ValueNode.Entry {
        ValueNode.Entry(key: key, keyType: "attribute", hidden: hidden ? true : nil, dirty: dirty ? true : nil, original: original, value: value)
    }

    static func model(_ className: String, key: String?, exists: Bool = true, dirty: Int? = nil, _ entries: [ValueNode.Entry]) -> ValueNode {
        var node = ValueNode(id: 0, type: .object, className: className, entries: entries)
        node.model = ValueNode.ModelInfo(key: key, keyName: "id", exists: exists, dirty: dirty)
        node.count = entries.count
        return node
    }

    static func collection(_ className: String = "Illuminate\\Database\\Eloquent\\Collection", of: String?, _ items: [ValueNode], total: Int? = nil, truncation: ValueNode.Truncation? = nil) -> ValueNode {
        var node = ValueNode(id: 0, type: .object, className: className, entries: items.enumerated().map { ValueNode.Entry(key: String($0.offset), keyType: "int", value: $0.element) })
        let count = total ?? items.count
        node.collection = ValueNode.CollectionInfo(count: count, of: of)
        node.count = count
        node.truncation = truncation
        return node
    }

    /// Alice (changed, with a loaded relation), Bob, and a new model; a hidden password.
    static var users: ValueNode {
        let widgets = collection(of: "App\\Models\\Widget", [model("App\\Models\\Widget", key: "7", [attribute("id", int(7)), attribute("name", string("Gear"))])])
        let alice = model("App\\Models\\User", key: "1", dirty: 1, [
            attribute("id", int(1)),
            attribute("name", string("Alice"), dirty: true, original: string("Bob")),
            attribute("password", string("not-a-hash"), hidden: true),
            ValueNode.Entry(key: "widgets", keyType: "relation", value: widgets),
        ])
        let bob = model("App\\Models\\User", key: "2", [attribute("id", int(2)), attribute("name", string("Bob")), attribute("password", string("x"), hidden: true)])
        let new = model("App\\Models\\User", key: nil, exists: false, [attribute("name", string("Dave"))])
        return collection(of: "App\\Models\\User", [alice, bob, new], total: 5, truncation: ValueNode.Truncation(reason: "budget", omitted: 2))
    }

    @Test func decodesTheRunnersValuesTree() throws {
        // As ModelValues.php writes it: `model`, `collection`, attribute and relation entries,
        // the hidden and changed marks with the original value, and the rows limit.
        let value = try node(#"""
        {"id":1,"type":"object","className":"Illuminate\\Database\\Eloquent\\Collection","referenceId":"9","collection":{"count":312,"of":"App\\Models\\Pair"},"count":312,
         "entries":[{"key":"0","keyType":"int","value":{"id":2,"type":"object","className":"App\\Models\\Pair","referenceId":"10",
           "model":{"exists":true,"keyName":"id","key":"6ac415590f30855a540e9a82","dirty":1},"count":3,
           "entries":[{"key":"symbol","keyType":"attribute","dirty":true,"original":{"id":3,"type":"string","length":2,"scalar":"S1"},"value":{"id":4,"type":"string","length":7,"scalar":"CHANGED"}},
                      {"key":"secret","keyType":"attribute","hidden":true,"value":{"id":5,"type":"string","length":1,"scalar":"x"}},
                      {"key":"trades","keyType":"relation","value":{"id":6,"type":"object","className":"Illuminate\\Database\\Eloquent\\Collection","collection":{"count":0},"count":0,"entries":[]}}]}}],
         "truncation":{"reason":"rows","omitted":311,"limit":1}}
        """#)
        #expect(value.collection == ValueNode.CollectionInfo(count: 312, of: "App\\Models\\Pair"))
        #expect(value.truncation == ValueNode.Truncation(reason: "rows", omitted: 311, limit: 1))
        let pair = try #require(value.entries?.first?.value)
        #expect(pair.model == ValueNode.ModelInfo(key: "6ac415590f30855a540e9a82", keyName: "id", exists: true, dirty: 1))
        let symbol = try #require(pair.entries?.first)
        #expect(symbol.keyType == "attribute" && symbol.dirty == true && symbol.original?.scalar == "S1" && symbol.value.scalar == "CHANGED")
        #expect(pair.entries?[1].hidden == true)
        #expect(pair.entries?[2].keyType == "relation" && pair.entries?[2].value.collection?.count == 0)
        // An Object tree has neither.
        let object = try node(#"{"id":1,"type":"object","className":"App\\Models\\User","entries":[]}"#)
        #expect(object.model == nil && object.collection == nil && object.modelTitle == nil)
    }

    @Test func titlesNameTheClassKeyAndCount() {
        let users = Self.users
        #expect(users.modelTitle == "Collection<User> · 5")
        #expect(users.typeLabel == "Collection<User> · 5")
        #expect(users.omittedText == "2 not shown")
        #expect(users.inlineSummary == "Collection<User> · 5")
        let alice = users.entries![0].value
        #expect(alice.modelTitle == "User #1")
        #expect(alice.inlineSummary == "User #1 {…}")
        #expect(users.entries![2].value.inlineSummary == "User (new) {…}")
        // A long key, a BSON ObjectId's hex, is shortened in the title only.
        let pair = Self.model("App\\Models\\Pair", key: "6ac415590f30855a540e9a82", [])
        #expect(pair.modelTitle == "Pair #6ac41559…")
        // A paginator: the page's items, the total, and the page.
        var page = Self.collection("Illuminate\\Pagination\\LengthAwarePaginator", of: "App\\Models\\User", [alice])
        page.collection = ValueNode.CollectionInfo(count: 15, of: "App\\Models\\User", total: 312, page: 2, lastPage: 21, perPage: 15)
        #expect(page.modelTitle == "LengthAwarePaginator<User> · 15 of 312 · page 2 of 21")
        var cursor = Self.collection("Illuminate\\Pagination\\CursorPaginator", of: nil, [alice])
        cursor.collection = ValueNode.CollectionInfo(count: 1, perPage: 1, hasMore: true)
        #expect(cursor.modelTitle == "CursorPaginator · 1 · more")
    }

    @Test func tableRowsAreTheModelsAttributesAndRelations() throws {
        let table = try #require(ValueTable.make(from: Self.users))
        #expect(table.columns == ["id", "name", "password", "widgets"])
        #expect(table.rows.count == 3)
        // The Table and the Tree agree on what the runner left out.
        #expect(table.omittedRows == 2)
        #expect(table.rows.count + table.omittedRows == Self.users.collection?.count)
        #expect(table.rows[0].map(\.text) == ["1", "Alice", "not-a-hash", "Collection<Widget> · 1"])
        #expect(table.rows[2][1].text == "Dave" && table.rows[2][0].isNull)
        #expect(table.rowFields[0].map(\.keyType) == ["attribute", "attribute", "attribute", "relation"])
        // An array of models is a table too.
        var list = ValueNode(id: 0, type: .array, entries: Self.users.entries)
        list.count = 3
        #expect(ValueTable.make(from: list)?.rows.count == 3)
    }

    @Test func plainTextMarksChangedHiddenAndNewModels() {
        let text = Self.users.plainText()
        #expect(text.hasPrefix("Collection<User> · 5 [\n  0 => User #1 {\n    id: 1\n"))
        #expect(text.contains("    name (changed, was \"Bob\"): \"Alice\"\n"))
        #expect(text.contains("    password (hidden): \"not-a-hash\"\n"))
        #expect(text.contains("    widgets: Collection<Widget> · 1 [\n      0 => Widget #7 {\n"))
        #expect(text.contains("  2 => User (new) {\n    name: \"Dave\"\n  }\n"))
        #expect(text.hasSuffix("  … 2 more\n]"))
    }

    @Test func inlineSummariesMatchTheValuesTree() {
        let users = Self.users
        // The key is in the title, so it isn't repeated in the attributes.
        #expect(users.entries![0].value.compactSummary() == #"User #1 {name: "Alice", password: "not-a-hash"}"#)
        #expect(users.entries![2].value.compactSummary() == #"User (new) {name: "Dave"}"#)
        #expect(users.compactSummary().hasPrefix("Collection<User>(5) [User #1 {"))
        #expect(users.compactSummary().hasSuffix(", …] (5)"))
    }

    @Test func exportsKeepAttributesAndListItems() {
        let json = ValueExport.json(Self.users, pretty: false)
        #expect(json.hasPrefix(#"[{"id":1,"name":"Alice","password":"not-a-hash","widgets":[{"id":7,"name":"Gear"}]},{"id":2"#))
        let php = ValueExport.php(Self.users)
        #expect(php.hasPrefix("/* Illuminate\\Database\\Eloquent\\Collection */ [\n    /* App\\Models\\User */ [\n        'id' => 1,\n"))
    }

    @Test func eachSurfacePicksTheTreeOfTheChoice() throws {
        let object = ValueNode(id: 1, type: .object, className: "Illuminate\\Database\\Eloquent\\Collection")
        let values = Self.users
        let result = ResultInfo(hasValue: true, value: object, modelValues: values)
        #expect(result.node(for: .values) == values)
        #expect(result.node(for: .object) == object)
        // Without models there is one tree, whatever the choice.
        let plain = ResultInfo(hasValue: true, value: object)
        #expect(plain.node(for: .values) == object)
        let dump = try JSONDecoder().decode(DumpInfo.self, from: Data(#"{"index":1,"origin":"dump","value":{"id":1,"type":"int","scalar":"3"}}"#.utf8))
        #expect(dump.modelValues == nil && dump.node(for: .values).scalar == "3")

        // Inline values: the line's summary follows the choice.
        var inline = InlineValues()
        inline.apply(.hit(InlineHit(probe: 1, line: 2, kind: "value", hit: 1, value: object, modelValues: values)), editorLine: { $0 })
        #expect(inline.summary(onLine: 2, display: .values)?.plainText.hasPrefix("Collection<User>(5) [User #1") == true)
        #expect(inline.summary(onLine: 2, display: .object)?.plainText == "Collection")
        #expect(inline.probes(onLine: 2).first?.last?.node(for: .values) == values)
    }

    @Test func theChoiceIsSavedWithTheTabAndHasASettingsDefault() throws {
        #expect(AppSettings().modelDisplay == .values)
        // Settings saved before #307 show Values.
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"fontSize":14}"#.utf8))
        #expect(old.modelDisplay == .values)
        var settings = AppSettings()
        settings.modelDisplay = .object
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.modelDisplay == .object)

        // A tab follows Settings until its cards switch it, then keeps its choice.
        let tab = TabState(title: "Users", code: "User::all();")
        #expect(tab.modelDisplay == nil)
        let switched = TabState(title: "Users", code: "User::all();", modelDisplay: .object)
        let restored = try JSONDecoder().decode(TabState.self, from: JSONEncoder().encode(switched))
        #expect(restored.modelDisplay == .object)
        let earlier = try JSONDecoder().decode(TabState.self, from: JSONEncoder().encode(tab))
        #expect(earlier.modelDisplay == nil)
    }
}
