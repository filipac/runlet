import Foundation
@testable import RunletCore
import Testing

/// Every result set of a statement (#154): the `resultSet` of an `sql` event, the card's title,
/// and Load Next's refusal for one of several results.
struct SQLResultSetsTests {
    @Test func decodesAndTitlesResultSets() throws {
        let json = #"{"columns":["id"],"rows":[[1]],"resultSet":{"index":2,"count":3},"statement":{"index":1,"count":2,"line":4}}"#
        let result = try JSONDecoder().decode(SQLResultInfo.self, from: Data(json.utf8))
        #expect(result.resultSet == SQLResultInfo.ResultSetInfo(index: 2, count: 3))
        #expect(result.title == "Statement 1 of 2 · Result 2 of 3")
        #expect(result.plainText.hasPrefix("SQL (Statement 1 of 2 · line 4 · Result 2 of 3): 1 row"))
        #expect(result.markdown.hasPrefix("### SQL — Statement 1 of 2 · line 4 · Result 2 of 3: 1 row"))

        let partial = try JSONDecoder().decode(SQLResultInfo.self, from: Data(#"{"affectedRows":2,"resultSet":{"index":1}}"#.utf8))
        #expect(partial.title == "Result 1")
        #expect(partial.summary == "2 rows affected")

        let single = try JSONDecoder().decode(SQLResultInfo.self, from: Data(#"{"columns":["a"],"rows":[]}"#.utf8))
        #expect(single.resultSet == nil)
        #expect(single.title == "SQL")
        // Round trip: the field is part of the event.
        let encoded = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(SQLResultInfo.self, from: encoded).resultSet == result.resultSet)
    }

    @Test func loadNextRefusesOneOfSeveralResults() {
        let refusal = SQLPaging.Refusal.resultSets
        #expect(refusal.repeatsStatement)
        #expect(refusal.message.contains("returned several"))
    }
}
