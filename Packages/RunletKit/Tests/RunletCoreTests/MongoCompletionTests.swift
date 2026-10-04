import RunletCore
import Testing

struct MongoCompletionTests {
    @Test func sampledNamesAreLocalSuggestions() {
        let text = #"{"filter":{"sta"#
        let suggestions = MongoCompletion.suggestions(in: text, caret: text.utf16.count, fields: ["status", "total"], collections: ["orders"])
        #expect(suggestions?.items.map(\.label) == ["status"])
        #expect(suggestions?.prefix == "sta")
        #expect(MongoCompletion.suggestions(in: "{}", caret: 2, fields: ["status"], collections: []) == nil)
    }

    @Test func fieldNamesAreJSONEscaped() {
        let suggestions = MongoCompletion.suggestions(in: "\"odd", caret: 4, fields: ["odd\"name"], collections: [])
        #expect(suggestions?.items.first?.insertText == "odd\\\"name")
    }
}
