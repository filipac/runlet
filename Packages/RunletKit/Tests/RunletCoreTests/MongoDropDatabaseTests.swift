import Foundation
@testable import RunletCore
import Testing

/// `dropDatabase` (#207): supported behind the shared danger sheet; the query names the
/// connection's database.
struct MongoDropDatabaseTests {
    @Test func parsesAsDestructiveWithItsDatabase() throws {
        let query = try MongoQuery(#"{"operation":"dropDatabase","database":"p207_scratch"}"#)
        #expect(query.effect == .destructive && query.database == "p207_scratch" && query.collection.isEmpty)
        #expect(query.subject == "the database “p207_scratch”")
        #expect(query.danger == "removes the database “p207_scratch” with all its collections, documents, and indexes")
        let confirmation = try #require(DatabaseDangerConfirmation.mongo(query, line: 2, database: "p207_scratch", connection: "the saved connection “Docs” (mongodb, 127.0.0.1:27017/p207_scratch)", tabId: UUID()) {})
        #expect(confirmation.title == "Run dropDatabase on the database “p207_scratch”, on the saved connection “Docs” (mongodb, 127.0.0.1:27017/p207_scratch)?")
        #expect(confirmation.confirmTitle == "Run dropDatabase" && confirmation.items.first?.sentence.hasPrefix("Line 2: dropDatabase removes the database") == true)
    }

    @Test(arguments: [
        #"{"operation":"dropDatabase"}"#,
        #"{"operation":"dropDatabase","database":""}"#,
        #"{"operation":"dropDatabase","database":"admin"}"#,
        #"{"operation":"dropDatabase","database":"Local"}"#,
        #"{"operation":"dropDatabase","database":"a.b"}"#,
        #"{"operation":"dropDatabase","database":"a/b"}"#,
        #"{"operation":"dropDatabase","database":"shop","collection":"orders"}"#,
        #"{"operation":"dropDatabase","database":"shop","filter":{}}"#,
        #"{"operation":"dropDatabase","database":5}"#,
    ])
    func refusesWithoutAValidDatabase(json: String) {
        #expect(throws: MongoQuery.Invalid.self) { try MongoQuery(json) }
    }

    @Test func otherOperationsStillNeedACollection() {
        #expect(throws: MongoQuery.Invalid.self) { try MongoQuery(#"{"operation":"find","database":"shop"}"#) }
        #expect(throws: MongoQuery.Invalid.self) { try MongoQuery(#"{"operation":"find","collection":"orders","database":"shop"}"#) }
    }
}
