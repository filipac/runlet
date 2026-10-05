import Foundation
import Testing
@testable import RunletCore

/// Driver casters (#6): a cast object's node, its raw object, and how the summaries, the table,
/// and plain text show it. The runner's side is `DriverCasterTests`.
struct ValueCastTests {
    func node(_ json: String) throws -> ValueNode {
        try JSONDecoder().decode(ValueNode.self, from: Data(json.utf8))
    }

    /// `Acme\Money` as `AcmeApiDriver`'s caster shows it, with the raw object.
    static let money = #"{"id":2,"type":"object","className":"Acme\\Money","referenceId":"12","summary":"EUR 12.50","count":2,"entries":[{"key":"amount","keyType":"field","value":{"id":3,"type":"int","scalar":"1250"}},{"key":"currency","keyType":"field","value":{"id":4,"type":"string","scalar":"EUR","length":3}}],"cast":{"by":"AcmeApiDriver","raw":{"id":5,"type":"object","className":"Acme\\Money","referenceId":"12","count":2,"entries":[{"key":"cents","keyType":"property","visibility":"private","value":{"id":6,"type":"int","scalar":"1250"}},{"key":"currency","keyType":"property","visibility":"private","value":{"id":7,"type":"string","scalar":"EUR","length":3}}]}}}"#

    @Test func decodesTheCastAndItsRawObject() throws {
        let money = try node(Self.money)
        let cast = try #require(money.cast)
        #expect(money.isCast)
        #expect(cast.by == "AcmeApiDriver")
        #expect(cast.type == nil && cast.error == nil)
        #expect(cast.raw?.entries?.map(\.key) == ["cents", "currency"])
        #expect(cast.raw?.entries?.first?.visibility == "private")
        #expect(cast.help == "Shown by AcmeApiDriver's caster. Click to show the raw object.")
        #expect(money.entries?.map(\.keyType) == ["field", "field"])

        // It survives a round trip (history and the result window keep values).
        let encoded = try JSONEncoder().encode(money)
        #expect(try JSONDecoder().decode(ValueNode.self, from: encoded) == money)
        // Nodes without a cast stay as they were.
        #expect(try node(#"{"id":1,"type":"int","scalar":"1"}"#).cast == nil)
    }

    @Test func aFailedCasterLeavesTheObjectAsRunletSeesIt() throws {
        let failed = try node(#"{"id":1,"type":"object","className":"Acme\\Rate","referenceId":"3","count":1,"entries":[{"key":"pair","keyType":"property","visibility":"private","value":{"id":2,"type":"string","scalar":"EURUSD","length":6}}],"cast":{"by":"AcmeApiDriver","type":"Acme\\Priced","error":"RuntimeException: rates unavailable"}}"#)
        #expect(!failed.isCast)
        #expect(failed.cast?.raw == nil)
        #expect(failed.cast?.help == "AcmeApiDriver's caster for Acme\\Priced couldn't show this object (RuntimeException: rates unavailable), so it shows as Runlet sees it.")
        #expect(failed.plainText() == "Acme\\Rate #3 {\n  -pair: \"EURUSD\"\n}")
        // The raw object left out by the value's size limit.
        let large = try node(#"{"id":1,"type":"object","className":"Acme\\Money","summary":"EUR 1","cast":{"by":"AcmeApiDriver"}}"#)
        #expect(large.cast?.help == "Shown by AcmeApiDriver's caster. The raw object was left out: the value is too large.")
    }

    @Test func summariesAndPlainTextShowTheCastersView() throws {
        let money = try node(Self.money)
        #expect(money.inlineSummary == "Acme\\Money #12 EUR 12.50")
        #expect(money.compactSummary() == "Money EUR 12.50")
        #expect(money.plainText() == "Acme\\Money #12 EUR 12.50 {\n  amount: 1250\n  currency: \"EUR\"\n}")

        // Fields without a summary line read like a model's attributes inline.
        let email = try node(#"{"id":1,"type":"object","className":"Acme\\EmailAddress","referenceId":"4","count":2,"entries":[{"key":"address","keyType":"field","value":{"id":2,"type":"string","scalar":"ada@example.com","length":15}},{"key":"verified","keyType":"field","value":{"id":3,"type":"bool","scalar":"true"}}],"cast":{"by":"AcmeApiDriver"}}"#)
        #expect(email.compactSummary() == "EmailAddress {address: \"ada@example.com\", verified: true}")
        // Without the cast, an object's properties stay a count.
        var plain = email
        plain.cast = nil
        #expect(plain.compactSummary() == "EmailAddress {2}")
    }

    @Test func tablesUseTheCastersSummaryAndFields() throws {
        let order = #"{"id":%d,"type":"object","className":"Acme\\Order","referenceId":"%d","count":2,"entries":[{"key":"number","keyType":"field","value":{"id":%d,"type":"int","scalar":"%d"}},{"key":"total","keyType":"field","value":"# + Self.money + #"}],"cast":{"by":"AcmeApiDriver"}}"#
        let rows = [String(format: order, 10, 20, 11, 1001), String(format: order, 30, 40, 31, 1002)]
        let list = try node(#"{"id":1,"type":"array","count":2,"entries":[{"key":"0","keyType":"int","value":"# + rows[0] + #"},{"key":"1","keyType":"int","value":"# + rows[1] + #"}]}"#)
        let table = try #require(ValueTable.make(from: list))
        #expect(table.columns == ["number", "total"])
        #expect(table.rows.map { $0.map(\.text) } == [["1001", "EUR 12.50"], ["1002", "EUR 12.50"]])
    }
}
