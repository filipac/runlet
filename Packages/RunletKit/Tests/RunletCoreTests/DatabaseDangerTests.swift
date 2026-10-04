import Foundation
@testable import RunletCore
import Testing

/// The shared database danger confirmation (#190, #191) and the MongoDB tab's picker filtering.
struct DatabaseDangerTests {
    private let tabId = UUID()
    private let cache = "the saved connection “Cache” (redis, 127.0.0.1:6379/0)"
    private let documents = "the saved connection “Documents” (mongodb, 127.0.0.1:27017/shop)"

    private func redisItem(_ line: Int, _ arguments: [String]) -> DatabaseDangerConfirmation.Item {
        let info = RedisCommands.classify(arguments)
        return .init(line: line, name: info.name, text: arguments.joined(separator: " "), danger: info.danger ?? "is dangerous")
    }

    @Test func redisWordingIsUnchanged() {
        let one = DatabaseDangerConfirmation(family: .redis, tabId: tabId, connection: cache, items: [redisItem(3, ["FLUSHDB"])], perform: {})
        #expect(one.title == "Run FLUSHDB on the saved connection “Cache” (redis, 127.0.0.1:6379/0)?")
        #expect(one.confirmTitle == "Run FLUSHDB")
        #expect(one.explanation == "Runlet asks before every dangerous Redis command, on every connection.")
        #expect(one.identifier == "redis-danger")
        #expect(one.items[0].sentence == "Line 3: FLUSHDB deletes every key in the current database.")
        #expect(one.items[0].text == "FLUSHDB")

        let two = DatabaseDangerConfirmation(family: .redis, tabId: tabId, connection: cache, items: [redisItem(1, ["KEYS", "*"]), redisItem(2, ["FLUSHDB"]), redisItem(4, ["KEYS", "user:*"])], perform: {})
        #expect(two.title == "Run FLUSHDB, KEYS on the saved connection “Cache” (redis, 127.0.0.1:6379/0)?")
        #expect(two.confirmTitle == "Run Commands")
        #expect(two.items.map(\.line) == [1, 2, 4])
    }

    @Test func confirmationRunsOnlyWhenPerformed() {
        var ran = 0
        let confirmation = DatabaseDangerConfirmation(family: .redis, tabId: tabId, connection: cache, items: [redisItem(1, ["FLUSHALL"])], perform: { ran += 1 })
        #expect(ran == 0)
        confirmation.perform()
        #expect(ran == 1)
    }

    @Test func mongoDropNamesCollectionDatabaseAndConnection() throws {
        let query = try MongoQuery("{\n  \"collection\": \"orders\",\n  \"operation\": \"drop\"\n}")
        let confirmation = try #require(DatabaseDangerConfirmation.mongo(query, line: 2, database: "shop", connection: documents, tabId: tabId, perform: {}))
        #expect(confirmation.family == .mongodb)
        #expect(confirmation.tabId == tabId)
        #expect(confirmation.title == "Run drop on the collection “orders” in the database “shop”, on the saved connection “Documents” (mongodb, 127.0.0.1:27017/shop)?")
        #expect(confirmation.confirmTitle == "Run drop")
        #expect(confirmation.explanation == "Runlet asks before every dangerous MongoDB operation, on every connection.")
        #expect(confirmation.identifier == "mongo-danger")
        #expect(confirmation.items.count == 1)
        #expect(confirmation.items[0].sentence == "Line 2: drop removes the collection “orders” with all its documents and indexes.")
        // The query on one line in the operation box.
        #expect(confirmation.items[0].text == "{ \"collection\": \"orders\", \"operation\": \"drop\" }")
    }

    @Test func mongoUnfilteredWritesConfirmAndFilteredOnesDont() throws {
        let deleteAll = try MongoQuery(#"{"collection":"orders","operation":"deleteMany","filter":{}}"#)
        let delete = try #require(DatabaseDangerConfirmation.mongo(deleteAll, line: 1, database: nil, connection: "the default connection", tabId: tabId, perform: {}))
        // An application connection's database is known only to the application.
        #expect(delete.title == "Run deleteMany on the collection “orders” in the connection's database, on the default connection?")
        #expect(delete.items[0].sentence == "Line 1: deleteMany has an empty filter: it deletes every document of “orders”.")

        let updateAll = try MongoQuery(#"{"collection":"orders","operation":"updateMany","update":{"$set":{"archived":true}}}"#)
        let update = try #require(DatabaseDangerConfirmation.mongo(updateAll, line: nil, database: "", connection: documents, tabId: tabId, perform: {}))
        #expect(update.items[0].sentence == "updateMany has an empty filter: it updates every document of “orders”.")
        #expect(update.destination == "the collection “orders” in the connection's database")

        for text in [#"{"collection":"orders","operation":"deleteMany","filter":{"status":"void"}}"#,
                     #"{"collection":"orders","operation":"updateMany","filter":{"status":"void"},"update":{"$set":{"archived":true}}}"#,
                     #"{"collection":"orders","operation":"deleteOne","filter":{}}"#,
                     #"{"collection":"orders","operation":"find","filter":{}}"#] {
            let query = try MongoQuery(text)
            #expect(query.danger == nil)
            #expect(DatabaseDangerConfirmation.mongo(query, line: 1, database: "shop", connection: documents, tabId: tabId, perform: {}) == nil)
        }
    }

    @Test func mongoQueryStartLine() {
        let text = "\n\n  {\n  \"collection\": \"orders\"\n}\n\n{\"collection\": \"items\"}"
        #expect(MongoQuery.startLine(in: text) == 3)
        let second = (text as NSString).range(of: "\n\n{").location
        #expect(MongoQuery.startLine(in: text, from: second) == 7)
        #expect(MongoQuery.startLine(in: "{}") == 1)
        #expect(MongoQuery.startLine(in: "  \n  ") == 1)
    }

    @Test func findTemplateIsAReadThatParses() throws {
        let template = MongoQuery.findTemplate(collection: "orders")
        let query = try MongoQuery(template)
        #expect(query.operation == "find" && query.collection == "orders" && query.effect == .read)
        #expect(template.contains("\"limit\": 50"))
        // Quotes and backslashes in a name stay inside the JSON string.
        let odd = try MongoQuery(MongoQuery.findTemplate(collection: #"we"ird\name"#))
        #expect(odd.collection == #"we"ird\name"#)
    }

    @Test func mongoPickerOffersOnlyMongoConnections() {
        var library = TargetLibrary()
        let target = TargetRef.local(UUID())
        let other = TargetRef.local(UUID())
        let mongo = DatabaseConnection(name: "Documents", scope: target, driver: .mongodb, host: "127.0.0.1", database: "shop")
        let sql = DatabaseConnection(name: "Reporting", scope: target, driver: .mysql, host: "127.0.0.1", database: "shop")
        let redis = DatabaseConnection(name: "Cache", scope: target, driver: .redis, host: "127.0.0.1")
        let elsewhere = DatabaseConnection(name: "Elsewhere", scope: other, driver: .mongodb, host: "127.0.0.1", database: "shop")
        let shared = DatabaseConnection(name: "Shared Documents", scope: nil, driver: .mongodb, host: "127.0.0.1", database: "shop")
        let sharedSQL = DatabaseConnection(name: "Shared SQL", scope: nil, driver: .pgsql, host: "127.0.0.1", database: "shop")
        for connection in [mongo, sql, redis, elsewhere, shared, sharedSQL] { library.saveDatabaseConnection(connection) }

        let picker = library.pickerConnections(for: target, language: .mongodb)
        #expect(picker.target.map(\.id) == [mongo.id])
        #expect(picker.allTargets.map(\.id) == [shared.id])
        // The other families' pickers never offer MongoDB connections.
        let sqlPicker = library.pickerConnections(for: target, language: .sql)
        #expect(sqlPicker.target.map(\.id) == [sql.id] && sqlPicker.allTargets.map(\.id) == [sharedSQL.id])
        #expect(library.pickerConnections(for: target, language: .redis).target.map(\.id) == [redis.id])
        #expect(library.pickerConnections(for: target, language: .redis).allTargets.isEmpty)
        #expect(library.pickerConnections(for: target, language: .php).target.map(\.id) == [sql.id])
        #expect(library.pickerConnections(for: other, language: .mongodb).target.map(\.id) == [elsewhere.id])
    }
}
