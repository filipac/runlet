import Foundation
import RunletCore
@testable import RunletExecution
import Testing

/// #220: mongosh queries, translated to the JSON form, run on the `mongo:7` fixture
/// (`RUNLET_TEST_MONGODB`) as the JSON they became: each method of the subset, find's chain, and
/// the constructors' Extended JSON (ObjectId, ISODate, NumberDecimal, NumberLong). The runner
/// gets only the translation, so it applies its own checks to it. Only a `p220_` collection in
/// `p220_tests` is used, and dropped at the end.
@Suite(.serialized, .live(.mongo), .enabled(if: LiveServers.mongo != nil))
struct MongoShellLiveTests {
    private func run(_ mongosh: String, confirmed: Bool = false) async throws -> [RunEvent] {
        let value = try #require(LiveServers.mongo)
        let parts = value.components(separatedBy: "|")
        let url = try #require(URLComponents(string: parts[0]))
        let connection = DatabaseConnection(name: "Mongo fixture", scope: .local(UUID()), driver: .mongodb, host: "127.0.0.1", port: url.port, database: "p220_tests", user: parts[1])
        let query = try MongoQuery(tabText: mongosh)
        #expect(query.mongosh != nil)
        let directory = try DriverSupport.temporaryDirectory("mongosh")
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await SQLSavedConnectionTests.run(query.runnerCode(connection: nil, pageSize: 100, confirmed: confirmed), connection: connection, in: directory, password: parts[2])
    }

    /// Runs mongosh on the fixture as its JSON, on `database`, read-only or not, confirmed or not.
    private func shell(_ mongosh: String, database: String = "p220_tests", readOnly: Bool = false, confirmed: Bool = false) async throws -> [RunEvent] {
        let value = try #require(LiveServers.mongo)
        let parts = value.components(separatedBy: "|")
        let url = try #require(URLComponents(string: parts[0]))
        let connection = DatabaseConnection(name: "Mongo fixture", scope: .local(UUID()), driver: .mongodb, host: "127.0.0.1", port: url.port, database: database, user: parts[1], readOnly: readOnly)
        let query = try MongoQuery(tabText: mongosh)
        let directory = try DriverSupport.temporaryDirectory("mongosh")
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await SQLSavedConnectionTests.run(query.runnerCode(connection: nil, pageSize: 100, confirmed: confirmed), connection: connection, in: directory, password: parts[2])
    }

    private func column(_ events: [RunEvent], _ name: String) -> [SQLCell] {
        guard let result = events.sqlResult, let index = result.columns.firstIndex(of: name) else { return [] }
        return result.rows.map { $0[index] }
    }

    @Test func mongoshQueriesRunAsTheirJSON() async throws {
        let orders = "p220_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let inserted = try await run("""
            db.\(orders).insertMany([
              {n: 1, status: 'paid', customer: ObjectId('66a000000000000000000001'), total: NumberDecimal('120.50'), at: ISODate('2026-03-01T09:00:00Z'), weight: NumberLong(500)},
              {n: 2, status: "pending", customer: ObjectId("66a000000000000000000002"), total: NumberDecimal("80.00"), at: ISODate("2026-04-01"), weight: NumberLong("750")},
              {n: 3, status: 'shipped', customer: ObjectId('66a000000000000000000001'), total: NumberDecimal('300.00'), at: ISODate('2026-05-01 11:00:00+02:00'), weight: NumberLong(250),},
            ])
            """)
        #expect(inserted.errors.isEmpty, "\(inserted.errors)")
        #expect(try await run("db.\(orders).insertOne({n: 4, status: 'void', total: NumberDecimal('15.00'), at: ISODate('2025-12-31T23:59:59.500Z'), note: 'it\\'s late'})").errors.isEmpty)

        // find: the constructors match the stored types; projection, sort, skip, and limit.
        func numbers(_ mongosh: String) async throws -> [SQLCell] {
            let events = try await run(mongosh)
            #expect(events.errors.isEmpty, "\(mongosh): \(events.errors)")
            return column(events, "n")
        }
        #expect(try await numbers("db.\(orders).find({status: 'paid'}, {n: 1, _id: 0})") == [.int(1)])
        #expect(try await numbers("db.\(orders).find({customer: ObjectId('66a000000000000000000001')}, {n: 1}).sort({n: 1})") == [.int(1), .int(3)])
        #expect(try await numbers("db.\(orders).find({total: {$gt: NumberDecimal('80.00')}}, {n: 1}).sort({n: 1})") == [.int(1), .int(3)])
        #expect(try await numbers("db.\(orders).find({at: {$lt: ISODate('2026-01-01')}}, {n: 1})") == [.int(4)])
        #expect(try await numbers("db.\(orders).find({at: ISODate('2026-05-01T09:00:00Z')}, {n: 1})") == [.int(3)], "+02:00 is converted to UTC")
        #expect(try await numbers("db.\(orders).find({weight: {$gte: NumberLong('500')}}, {n: 1}).sort({n: 1})") == [.int(1), .int(2)])
        #expect(try await numbers("db.\(orders).find({note: \"it's late\"}, {n: 1})") == [.int(4)])
        #expect(try await numbers("db.\(orders).find({}, {n: 1, _id: 0}).limit(2).skip(1).sort({n: -1})") == [.int(3), .int(2)])

        // countDocuments, distinct, aggregate.
        #expect(column(try await run("db.\(orders).countDocuments({status: {$ne: 'void'}})"), "count") == [.int(3)])
        #expect(Set(column(try await run("db.\(orders).distinct('status', {n: {$lte: 3}})"), "value")) == [.string("paid"), .string("pending"), .string("shipped")])
        let grouped = try await run("""
            db.\(orders).aggregate([
              {$match: {status: {$in: ['paid', 'shipped']}}},  // two orders of one customer
              {$group: {_id: '$customer', orders: {$sum: 1}, total: {$sum: '$total'}}},
            ])
            """)
        #expect(grouped.errors.isEmpty, "\(grouped.errors)")
        #expect(column(grouped, "orders") == [.int(2)])

        // updateOne, updateMany, deleteOne, deleteMany.
        #expect(try await run("db.\(orders).updateOne({n: 2}, {$set: {status: 'paid'}})").errors.isEmpty)
        #expect(try await run("db.\(orders).updateMany({status: 'paid'}, {$inc: {revision: 1}})").errors.isEmpty)
        #expect(try await numbers("db.\(orders).find({revision: 1}, {n: 1}).sort({n: 1})") == [.int(1), .int(2)])
        #expect(try await run("db.\(orders).deleteOne({n: 4})").errors.isEmpty)
        #expect(try await run("db.\(orders).deleteMany({status: 'shipped'})").errors.isEmpty)
        #expect(try await numbers("db.\(orders).find({}, {n: 1}).sort({n: 1})") == [.int(1), .int(2)])

        // deleteMany({}) is destructive: the runner refuses it without the confirmation.
        let unconfirmed = try await run("db.\(orders).deleteMany({})")
        #expect(unconfirmed.errors.contains { $0.message.contains("Confirm MongoDB deleteMany") }, "\(unconfirmed.errors)")
        #expect(try await numbers("db.\(orders).find({}, {n: 1})").count == 2)
        #expect(try await run("db.\(orders).deleteMany({})", confirmed: true).errors.isEmpty)
        #expect(try await numbers("db.\(orders).find({}, {n: 1})") == [])

        // Clean up with the JSON form (drop isn't in the mongosh subset).
        let value = try #require(LiveServers.mongo)
        let parts = value.components(separatedBy: "|")
        let url = try #require(URLComponents(string: parts[0]))
        let connection = DatabaseConnection(name: "Mongo fixture", scope: .local(UUID()), driver: .mongodb, host: "127.0.0.1", port: url.port, database: "p220_tests", user: parts[1])
        let drop = try MongoQuery(#"{"collection": "\#(orders)", "operation": "drop"}"#)
        let directory = try DriverSupport.temporaryDirectory("mongosh")
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try await SQLSavedConnectionTests.run(drop.runnerCode(connection: nil, confirmed: true), connection: connection, in: directory, password: parts[2]).errors.isEmpty)
    }
    /// The owner's grown subset: every new operation and option runs on the fixture as its JSON;
    /// read-only connections refuse the changes, and destructive ones need the confirmation.
    @Test func theGrownSubsetRunsOnTheFixture() async throws {
        let c = "p220_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        func ok(_ mongosh: String, confirmed: Bool = false) async throws -> [RunEvent] {
            let events = try await shell(mongosh, confirmed: confirmed)
            #expect(events.errors.isEmpty, "\(mongosh): \(events.errors)")
            return events
        }
        let inserted = try await ok("db.\(c).insert([{n: 1, status: 'new', qty: [1, 2]}, {n: 2, status: 'new', city: 'Oslo'}, {n: 3, status: 'void', city: 'oslo'}], {ordered: false})")
        #expect(column(inserted, "inserted") == [.int(3)])

        // Reads and their options.
        #expect(column(try await ok("db.\(c).findOne({status: 'new'}, {n: 1, _id: 0}, {sort: {n: -1}})"), "n") == [.int(2)])
        #expect(column(try await ok("db.\(c).find({city: 'oslo'}, {n: 1}).collation({locale: 'en', strength: 2}).hint({_id: 1}).maxTimeMS(5000).allowDiskUse().batchSize(2).sort({n: 1}).pretty()"), "n") == [.int(2), .int(3)])
        #expect(try await ok("db.\(c).find({n: 1}).explain('executionStats')").scannableText.joined().contains("executionStats"))
        #expect(try await ok("db.\(c).explain().aggregate([{$match: {n: 1}}])").scannableText.joined().contains("queryPlanner"))
        #expect(column(try await ok("db.\(c).count({status: 'new'})"), "count") == [.int(2)])
        #expect(column(try await ok("db.\(c).find({status: 'new'}).sort({n: 1}).count()"), "count") == [.int(2)])
        #expect(column(try await ok("db.\(c).countDocuments({}, {skip: 1, limit: 1})"), "count") == [.int(1)])
        #expect(column(try await ok("db.\(c).estimatedDocumentCount()"), "count") == [.int(3)])
        #expect(Set(column(try await ok("db.\(c).distinct('city', {}, {collation: {locale: 'en', strength: 2}})"), "value")).count == 1)

        // Indexes.
        #expect(try await ok("db.\(c).createIndex({n: 1}, {unique: true})").errors.isEmpty)
        #expect(try await ok("db.\(c).createIndexes([{status: 1}, {status: 1, n: -1}])").errors.isEmpty)
        let indexes = column(try await ok("db.\(c).getIndexes()"), "name")
        #expect(Set(indexes) == [.string("_id_"), .string("n_1"), .string("status_1"), .string("status_1_n_-1")], "\(indexes)")
        let duplicate = try await shell("db.\(c).insertOne({n: 1})")
        #expect(!duplicate.errors.isEmpty, "the unique index holds")

        // findOneAndUpdate, findOneAndReplace, findOneAndDelete, with upsert and returnDocument.
        #expect(column(try await ok("db.\(c).findOneAndUpdate({n: 1}, {$set: {status: 'picked'}}, {returnNewDocument: true, projection: {status: 1, _id: 0}})"), "status") == [.string("picked")])
        #expect(column(try await ok("db.\(c).findOneAndUpdate({n: 9}, {$set: {status: 'new'}}, {upsert: true, returnDocument: 'after'})"), "n") == [.int(9)])
        #expect(column(try await ok("db.\(c).findOneAndReplace({n: 2}, {n: 2, status: 'replaced'}, {returnDocument: 'before'})"), "status") == [.string("new")])
        #expect(column(try await ok("db.\(c).findOneAndDelete({n: 9})"), "n") == [.int(9)])
        let missing = try await ok("db.\(c).findOneAndDelete({n: 99})")
        #expect(missing.sqlResult?.rows.isEmpty != false)
        #expect(missing.scannableText.joined().contains("No document matched the filter. Nothing changed."))

        // Updates: a pipeline, arrayFilters, upsert, and the legacy update() and remove().
        #expect(try await ok("db.\(c).updateOne({n: 1}, [{$set: {double: {$multiply: ['$n', 2]}}}])").errors.isEmpty)
        #expect(column(try await ok("db.\(c).find({n: 1})"), "double") == [.int(2)])
        #expect(try await ok("db.\(c).updateMany({qty: {$exists: true}}, {$set: {'qty.$[q]': 0}}, {arrayFilters: [{q: {$gte: 2}}]})").errors.isEmpty)
        #expect(column(try await ok("db.\(c).find({n: 1})"), "qty") == [.string("[1, 0]")])
        let upserted = try await ok("db.\(c).updateOne({n: 4}, {$set: {status: 'new'}}, {upsert: true})")
        #expect(column(upserted, "upserted") == [.int(1)])
        #expect(try await ok("db.\(c).update({n: 3}, {n: 3, status: 'whole'})").errors.isEmpty)
        #expect(column(try await ok("db.\(c).find({n: 3})"), "status") == [.string("whole")])
        #expect(column(try await ok("db.\(c).remove({n: 4}, true)"), "deleted") == [.int(1)])

        // bulkWrite with a delete is destructive: refused without the confirmation, run with it.
        let bulk = "db.\(c).bulkWrite([{insertOne: {document: {n: 10}}}, {updateOne: {filter: {n: 10}, update: {$set: {status: 'bulk'}}}}, {deleteOne: {filter: {n: 3}}}])"
        #expect(try await shell(bulk).errors.contains { $0.message.contains("Confirm MongoDB bulkWrite") })
        let bulked = try await ok(bulk, confirmed: true)
        #expect(column(bulked, "inserted") == [.int(1)] && column(bulked, "modified") == [.int(1)] && column(bulked, "deleted") == [.int(1)])

        // Statistics and commands that read.
        #expect(column(try await ok("db.\(c).stats()"), "ns") == [.string("p220_tests.\(c)")])
        #expect(try await ok("db.stats()").sqlResult?.columns.contains("collections") == true)
        #expect(try await ok("db.runCommand({ping: 1})").sqlResult?.columns == ["ok"])
        #expect(try await ok("db.version()").sqlResult?.columns.contains("version") == true)
        #expect(try await ok("show collections").scannableText.joined().contains(c))
        #expect(try await ok("show dbs").errors.isEmpty)

        // Read-only connections refuse every change, before it reaches the server.
        for change in ["db.\(c).insert({n: 20})", "db.\(c).findOneAndUpdate({n: 1}, {$set: {a: 1}})", "db.\(c).findOneAndDelete({n: 1})",
                       "db.\(c).bulkWrite([{insertOne: {document: {}}}])", "db.\(c).createIndex({city: 1})", "db.\(c).createIndexes([{city: 1}])",
                       "db.\(c).dropIndex('n_1')", "db.\(c).dropIndexes()", "db.\(c).renameCollection('\(c)_x')", "db.createCollection('\(c)_y')",
                       "db.\(c).update({n: 1}, {$set: {a: 1}})", "db.\(c).remove({n: 1})", "db.\(c).replaceOne({n: 1}, {n: 1})"] {
            let refused = try await shell(change, readOnly: true, confirmed: true)
            #expect(refused.scannableText.joined().contains("Read-only"), "\(change)")
        }
        #expect(try await shell("db.\(c).find().explain()", readOnly: true).errors.isEmpty)

        // Index and collection changes: destructive ones need the confirmation.
        #expect(try await shell("db.\(c).dropIndex('status_1')").errors.contains { $0.message.contains("Confirm MongoDB dropIndex") })
        #expect(try await ok("db.\(c).dropIndex('status_1')", confirmed: true).errors.isEmpty)
        #expect(try await ok("db.\(c).dropIndexes()", confirmed: true).errors.isEmpty)
        #expect(column(try await ok("db.\(c).getIndexes()"), "name") == [.string("_id_")])
        #expect(try await shell("db.\(c).renameCollection('\(c)_renamed')").errors.contains { $0.message.contains("Confirm MongoDB renameCollection") })
        #expect(try await ok("db.\(c).renameCollection('\(c)_renamed')", confirmed: true).errors.isEmpty)
        #expect(column(try await ok("db.\(c)_renamed.countDocuments()"), "count") == [.int(3)])
        #expect(try await ok("db.createCollection('\(c)_capped', {capped: true, size: 4096})").errors.isEmpty)
        #expect(column(try await ok("db.\(c)_capped.stats()"), "capped") == [.bool(true)])
        for name in ["\(c)_renamed", "\(c)_capped"] { #expect(try await ok("db.\(name).drop()", confirmed: true).errors.isEmpty) }

        // dropDatabase names its database, which must be the connection's.
        let scratch = "p220_drop_" + UUID().uuidString.prefix(8).lowercased()
        #expect(try await shell("db.items.insertOne({a: 1})", database: scratch).errors.isEmpty)
        let other = try await shell("db.getSiblingDB('p220_tests').dropDatabase()", database: scratch, confirmed: true)
        #expect(other.errors.contains { $0.message.contains("but the connection's database is “\(scratch)”") }, "\(other.errors)")
        #expect(try await shell("db.getSiblingDB('\(scratch)').dropDatabase()", database: scratch).errors.contains { $0.message.contains("Confirm MongoDB dropDatabase") })
        #expect(try await shell("db.getSiblingDB('\(scratch)').dropDatabase()", database: scratch, confirmed: true).errors.isEmpty)
        #expect(!(try await ok("show dbs").scannableText.joined().contains(scratch)))
    }
}
