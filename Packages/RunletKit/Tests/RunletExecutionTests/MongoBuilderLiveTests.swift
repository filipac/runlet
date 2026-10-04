import Foundation
import RunletCore
@testable import RunletExecution
import Testing

/// #217: queries the MongoDB query builder writes run as written on the `mongo:7` fixture
/// (`RUNLET_TEST_MONGODB`): typed values (ObjectId, UTC dates, Decimal128, Int64, regex, null),
/// every filter operator and group, projection, sort, skip and limit, the aggregation stage
/// cards, and the update operators. Only a `p217_` collection in `p217_tests` is used.
@Suite(.serialized, .live(.mongo), .enabled(if: LiveServers.mongo != nil))
struct MongoBuilderLiveTests {
    private func run(_ builder: MongoQueryBuilder, confirmed: Bool = false) async throws -> [RunEvent] {
        let value = try #require(LiveServers.mongo)
        let parts = value.components(separatedBy: "|")
        let url = try #require(URLComponents(string: parts[0]))
        let connection = DatabaseConnection(name: "Mongo fixture", scope: .local(UUID()), driver: .mongodb, host: "127.0.0.1", port: url.port, database: "p217_tests", user: parts[1])
        let text = try #require(builder.text, "\(builder.problem ?? "")")
        // What the builder writes reads back as the same query.
        #expect(try MongoQueryBuilder.read(text).get().text == text)
        let query = try MongoQuery(text)
        let directory = try DriverSupport.temporaryDirectory("mongo-builder")
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await SQLSavedConnectionTests.run(query.runnerCode(connection: nil, pageSize: 100, confirmed: confirmed), connection: connection, in: directory, password: parts[2])
    }

    private func column(_ events: [RunEvent], _ name: String) -> [SQLCell] {
        guard let result = events.sqlResult, let index = result.columns.firstIndex(of: name) else { return [] }
        return result.rows.map { $0[index] }
    }

    private func rule(_ path: String, _ op: MongoFilterRule.Operator = .equals, _ value: MongoValue = .null, values: [MongoValue] = []) -> MongoFilterNode {
        .rule(MongoFilterRule(path: path, op: op, value: value, values: values))
    }

    @Test func builderQueriesRunAsWritten() async throws {
        let orders = "p217_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let customers = orders + "_customers"
        var insertCustomers = MongoQueryBuilder(collection: customers, operation: "insertMany")
        insertCustomers.documents = #"[{"_id": {"$oid": "66a000000000000000000001"}, "name": "Ana", "city": "Cluj"}, {"_id": {"$oid": "66a000000000000000000002"}, "name": "Bo", "city": "Iasi"}]"#
        #expect(try await run(insertCustomers).errors.isEmpty)
        var insert = MongoQueryBuilder(collection: orders, operation: "insertMany")
        insert.documents = """
        [
          {"n": 1, "status": "paid", "customer": {"$oid": "66a000000000000000000001"}, "total": {"$numberDecimal": "120.50"}, "at": {"$date": "2026-03-01T09:00:00Z"}, "tags": ["web"], "weight": {"$numberLong": "500"}, "note": "first"},
          {"n": 2, "status": "pending", "customer": {"$oid": "66a000000000000000000002"}, "total": {"$numberDecimal": "80.00"}, "at": {"$date": "2026-04-01T09:00:00Z"}, "tags": ["gift", "web"], "weight": {"$numberLong": "750"}, "note": null},
          {"n": 3, "status": "shipped", "customer": {"$oid": "66a000000000000000000001"}, "total": {"$numberDecimal": "300.00"}, "at": {"$date": "2026-05-01T09:00:00Z"}, "tags": ["priority"], "weight": {"$numberLong": "250"}},
          {"n": 4, "status": "void", "customer": {"$oid": "66a000000000000000000002"}, "total": {"$numberDecimal": "15.00"}, "at": {"$date": "2025-12-31T23:59:59Z"}, "tags": [], "weight": {"$numberLong": "100"}, "note": "Late"}
        ]
        """
        let inserted = try await run(insert)
        #expect(inserted.errors.isEmpty, "\(inserted.errors)")

        // find: typed values and every operator, an Any-of group, projection, sort, limit.
        func find(_ children: [MongoFilterNode], kind: MongoFilterGroup.Kind = .all) async throws -> [SQLCell] {
            var builder = MongoQueryBuilder(collection: orders, operation: "find")
            builder.filter = MongoFilterGroup(kind: kind, children: children)
            builder.projection = [MongoFieldValue(path: "n"), MongoFieldValue(path: "_id", value: .number("0"))]
            builder.sort = [MongoFieldValue(path: "n", value: .number("1"))]
            builder.limit = .number("10")
            let events = try await run(builder)
            #expect(events.errors.isEmpty, "\(events.errors)")
            #expect(events.sqlResult?.columns == ["n"] || events.sqlResult?.rows.isEmpty == true, "#228: the projection")
            return column(events, "n")
        }
        #expect(try await find([rule("status", .equals, .string("paid"))]) == [.int(1)])
        #expect(try await find([rule("status", .notEquals, .string("void"))]) == [.int(1), .int(2), .int(3)])
        #expect(try await find([rule("total", .greater, MongoValue(.decimal, "80.00"))]) == [.int(1), .int(3)])
        #expect(try await find([rule("total", .greaterOrEqual, MongoValue(.decimal, "80"))]) == [.int(1), .int(2), .int(3)])
        #expect(try await find([rule("at", .less, MongoValue(.date, "2026-01-01T00:00:00Z"))]) == [.int(4)])
        #expect(try await find([rule("at", .lessOrEqual, MongoValue(.date, "2026-03-01T09:00:00Z"))]) == [.int(1), .int(4)])
        #expect(try await find([rule("customer", .equals, MongoValue(.objectId, "66a000000000000000000002"))]) == [.int(2), .int(4)])
        #expect(try await find([rule("status", .inList, values: [.string("paid"), .string("shipped")])]) == [.int(1), .int(3)])
        #expect(try await find([rule("tags", .notInList, values: [.string("web")])]) == [.int(3), .int(4)])
        #expect(try await find([rule("note", .exists, .bool(false))]) == [.int(3)])
        #expect(try await find([rule("note", .equals, .null)]) == [.int(2), .int(3)])
        #expect(try await find([rule("note", .regex, MongoValue(.string, "^l", options: "i"))]) == [.int(4)])
        #expect(try await find([rule("note", .type, .string("string"))]) == [.int(1), .int(4)])
        #expect(try await find([rule("weight", .greaterOrEqual, MongoValue(.long, "500"))]) == [.int(1), .int(2)])
        #expect(try await find([rule("n", .equals, MongoValue(.regex, "x"))]) == [])
        #expect(try await find([rule("status", .equals, .string("paid")), rule("tags", .equals, .string("priority"))], kind: .any) == [.int(1), .int(3)])
        #expect(try await find([rule("status", .equals, .string("paid")), rule("tags", .equals, .string("priority"))], kind: .none) == [.int(2), .int(4)])
        #expect(try await find([
            rule("total", .greaterOrEqual, MongoValue(.decimal, "15")),
            rule("total", .less, MongoValue(.decimal, "200")),
            .group(MongoFilterGroup(kind: .any, children: [rule("tags", .equals, .string("gift")), .group(MongoFilterGroup(kind: .all, implicit: true, children: [rule("status", .equals, .string("void")), rule("note", .exists, .bool(true))]))])),
        ]) == [.int(2), .int(4)])

        // skip, countDocuments, distinct. #228: a descending sort and the projection reach the
        // server (they were dropped with Stop's operation tag).
        var paged = MongoQueryBuilder(collection: orders, operation: "find")
        paged.sort = [MongoFieldValue(path: "n", value: .number("-1"))]
        paged.skip = .number("1")
        paged.limit = .number("2")
        paged.projection = [MongoFieldValue(path: "n"), MongoFieldValue(path: "_id", value: .number("0"))]
        #expect(column(try await run(paged), "n") == [.int(3), .int(2)])
        var count = paged
        count.setOperation("countDocuments")
        count.filter = MongoFilterGroup(children: [rule("status", .notEquals, .string("void"))])
        #expect(column(try await run(count), "count") == [.int(3)])
        var distinct = count
        distinct.setOperation("distinct")
        distinct.field = "status"
        #expect(Set(column(try await run(distinct), "value")) == [.string("paid"), .string("pending"), .string("shipped")])

        // aggregate: $match, $lookup, $unwind, $group, $sort, $project, $addFields, $limit, $skip, $count, and a JSON stage.
        var aggregate = MongoQueryBuilder(collection: orders, operation: "aggregate")
        aggregate.pipeline = [
            MongoStage(.match(MongoFilterGroup(children: [rule("status", .notEquals, .string("void"))]))),
            MongoStage(.lookup(MongoLookupStage(from: customers, localField: "customer", foreignField: "_id", output: "buyer"))),
            MongoStage(.unwind(MongoUnwindStage(path: "buyer"))),
            MongoStage(.group(MongoGroupStage(key: .field("buyer.city"), accumulators: [
                MongoAccumulator(name: "orders", op: "$count", argument: MongoValue(.json, "{}")),
                MongoAccumulator(name: "revenue", op: "$sum", argument: .field("total")),
                MongoAccumulator(name: "numbers", op: "$push", argument: .field("n")),
                MongoAccumulator(name: "first", op: "$min", argument: .field("at")),
            ]))),
            MongoStage(.sort([MongoFieldValue(path: "_id", value: .number("1"))])),
            MongoStage(.addFields([MongoFieldValue(path: "city", value: .field("_id"))], alias: false)),
            MongoStage(.project([MongoFieldValue(path: "_id", value: .number("0")), MongoFieldValue(path: "city"), MongoFieldValue(path: "orders"), MongoFieldValue(path: "revenue")])),
            MongoStage(.raw(#"{"$set": {"source": "builder"}}"#)),
            MongoStage(.limit(.number("5"))),
        ]
        var disabled = MongoStage(.skip(.number("100")))
        disabled.enabled = false
        aggregate.pipeline?.append(disabled)
        let grouped = try await run(aggregate)
        #expect(grouped.errors.isEmpty, "\(grouped.errors)")
        #expect(column(grouped, "city") == [.string("Cluj"), .string("Iasi")])
        #expect(column(grouped, "orders") == [.int(2), .int(1)])
        #expect(column(grouped, "revenue") == [.string("420.50"), .string("80.00")])
        var counted = MongoQueryBuilder(collection: orders, operation: "aggregate")
        counted.pipeline = [MongoStage(.sort([MongoFieldValue(path: "n", value: .number("1"))])), MongoStage(.skip(.number("1"))), MongoStage(.unwind(MongoUnwindStage(path: "tags", includeArrayIndex: "i", preserveNullAndEmptyArrays: true))), MongoStage(.count("rows"))]
        #expect(column(try await run(counted), "rows") == [.int(4)])

        // updateMany: $set (a date), $inc, $unset, $push, $pull; then what changed.
        var update = MongoQueryBuilder(collection: orders, operation: "updateMany")
        update.filter = MongoFilterGroup(children: [rule("status", .inList, values: [.string("paid"), .string("pending")])])
        update.update = [
            .entry(MongoUpdateEntry(op: .set, path: "checked_at", value: MongoValue(.date, "2026-10-04T09:30:00Z"))),
            .entry(MongoUpdateEntry(op: .inc, path: "revision", value: .number("2"))),
            .entry(MongoUpdateEntry(op: .unset, path: "note")),
            .entry(MongoUpdateEntry(op: .push, path: "labels", value: .string("checked"))),
            .entry(MongoUpdateEntry(op: .pull, path: "tags", value: .string("gift"))),
        ]
        #expect(update.effect == .write)
        let updated = try await run(update)
        #expect(updated.errors.isEmpty, "\(updated.errors)")
        #expect(column(updated, "modified") == [.int(2)])
        var check = MongoQueryBuilder(collection: orders, operation: "find")
        check.filter = MongoFilterGroup(children: [rule("checked_at", .equals, MongoValue(.date, "2026-10-04T09:30:00Z")), rule("revision", .equals, .number("2")),
                                                   rule("note", .exists, .bool(false)), rule("labels", .equals, .string("checked")), rule("tags", .notInList, values: [.string("gift")])])
        check.projection = [MongoFieldValue(path: "n"), MongoFieldValue(path: "_id", value: .number("0"))]
        check.sort = [MongoFieldValue(path: "n", value: .number("1"))]
        #expect(column(try await run(check), "n") == [.int(1), .int(2)])

        // deleteOne with an ObjectId-typed filter, then drop both collections.
        var delete = MongoQueryBuilder(collection: customers, operation: "deleteOne")
        delete.filter = MongoFilterGroup(children: [rule("_id", .equals, MongoValue(.objectId, "66a000000000000000000002"))])
        #expect(column(try await run(delete), "deleted") == [.int(1)])
        for name in [orders, customers] {
            let drop = MongoQueryBuilder(json: .object([.init("collection", .string(name)), .init("operation", .string("drop"))]))
            #expect(drop.effect == .destructive)
            #expect(try await run(drop, confirmed: true).errors.isEmpty)
        }
    }
}
