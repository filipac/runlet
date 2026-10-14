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
}
