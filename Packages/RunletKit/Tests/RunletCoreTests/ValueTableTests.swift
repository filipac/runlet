import Foundation
import Testing
@testable import RunletCore

struct ValueTableTests {
    func node(_ json: String) throws -> ValueNode {
        try JSONDecoder().decode(ValueNode.self, from: Data(json.utf8))
    }

    @Test func listOfArraysBecomesTable() throws {
        let value = try node(#"{"id":1,"type":"array","count":2,"entries":[{"key":"0","keyType":"int","value":{"id":2,"type":"array","entries":[{"key":"name","keyType":"string","value":{"id":3,"type":"string","scalar":"Gear, \"small\""}},{"key":"price","keyType":"string","value":{"id":4,"type":"int","scalar":"90"}}]}},{"key":"1","keyType":"int","value":{"id":5,"type":"array","entries":[{"key":"name","keyType":"string","value":{"id":6,"type":"string","scalar":"Flywheel"}},{"key":"stock","keyType":"string","value":{"id":7,"type":"null"}}]}}]}"#)
        let table = try #require(ValueTable.make(from: value))
        #expect(table.columns == ["name", "price", "stock"])
        #expect(table.rows[0][1].number == 90)
        #expect(table.rows[1][1].isNull)
        #expect(table.csv() == "name,price,stock\r\n\"Gear, \"\"small\"\"\",90,\r\nFlywheel,,null\r\n")
    }

    @Test func collectionOfModelsUsesAttributes() throws {
        let model = #"{"id":3,"type":"object","className":"App\\Models\\Widget","entries":[{"key":"connection","keyType":"property","visibility":"protected","value":{"id":4,"type":"string","scalar":"sqlite"}},{"key":"attributes","keyType":"property","visibility":"protected","value":{"id":5,"type":"array","entries":[{"key":"id","keyType":"string","value":{"id":6,"type":"int","scalar":"1"}},{"key":"name","keyType":"string","value":{"id":7,"type":"string","scalar":"Sprocket"}}]}}]}"#
        let value = try node(#"{"id":1,"type":"object","className":"Illuminate\\Database\\Eloquent\\Collection","entries":[{"key":"items","keyType":"property","visibility":"protected","value":{"id":2,"type":"array","count":1,"entries":[{"key":"0","keyType":"int","value":"# + model + #"}]}}]}"#)
        let table = try #require(ValueTable.make(from: value))
        #expect(table.columns == ["id", "name"])
        #expect(table.rows.first?.map(\.text) == ["1", "Sprocket"])
    }

    @Test func scalarListsAreNotTables() throws {
        #expect(ValueTable.make(from: try node(#"{"id":1,"type":"array","entries":[{"key":"0","keyType":"int","value":{"id":2,"type":"int","scalar":"1"}}]}"#)) == nil)
        #expect(ValueTable.make(from: try node(#"{"id":1,"type":"int","scalar":"1"}"#)) == nil)
    }
}
