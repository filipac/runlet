import Foundation
@testable import RunletCore
import Testing

/// #217: the MongoDB query builder's model, both directions against `MongoQuery`'s JSON form.
struct MongoJSONTests {
    @Test func keepsOrderAndNumberLiterals() throws {
        let text = #"{"z": 1.50, "a": -2e3, "m": [0, 10, 1E+2], "s": "x\"y\\z\n\u00e9\ud83d\ude00/", "t": true, "f": false, "n": null}"#
        let json = try MongoJSON.parse(text)
        #expect(json.members?.map(\.key) == ["z", "a", "m", "s", "t", "f", "n"])
        #expect(json["z"] == .number("1.50"))
        #expect(json["a"] == .number("-2e3"))
        #expect(json["m"] == .array([.number("0"), .number("10"), .number("1E+2")]))
        #expect(json["s"] == .string("x\"y\\z\né😀/"))
        #expect(try MongoJSON.parse(json.inline) == json)
        #expect(try MongoJSON.parse(json.pretty()) == json)
        #expect(json["s"]?.inline == #""x\"y\\z\né😀/""#)
    }

    @Test(arguments: [
        ("", 1, 1), ("{", 1, 2), ("{\"a\": 1,}", 1, 9), ("{\n  \"a\": tru\n}", 2, 8), ("[1 2]", 1, 4), ("{\"a\": 01}", 1, 8),
        ("{\"a\": \"\n\"}", 1, 8), ("{} {}", 1, 4), ("{\"a\": 1} // c", 1, 10), ("\"\\x\"", 1, 3)
    ])
    func refusesInvalidJSON(text: String, line: Int, column: Int) {
        #expect(throws: MongoJSON.ParseError.self) { try MongoJSON.parse(text) }
        do { _ = try MongoJSON.parse(text) } catch {
            #expect(error.line == line && error.column == column, "\(error)")
        }
    }

    @Test func prettyPrintsLikeTheDocs() throws {
        let json = try MongoJSON.parse(#"{"collection":"orders","operation":"find","filter":{"status":"paid"},"projection":{"status":1,"total":1},"sort":{"total":-1,"_id":1},"limit":20}"#)
        #expect(json.pretty() == """
        {
          "collection": "orders",
          "operation": "find",
          "filter": { "status": "paid" },
          "projection": { "status": 1, "total": 1 },
          "sort": { "total": -1, "_id": 1 },
          "limit": 20
        }
        """)
        let long = try MongoJSON.parse(#"{"pipeline":[{"$match":{"status":"paid"}}],"filter":{"customer.city":{"$in":["Cluj-Napoca","Bucharest","Timisoara","Iasi"]},"status":"paid"},"e":{},"l":[]}"#)
        #expect(long.pretty() == """
        {
          "pipeline": [
            { "$match": { "status": "paid" } }
          ],
          "filter": {
            "customer.city": {
              "$in": ["Cluj-Napoca", "Bucharest", "Timisoara", "Iasi"]
            },
            "status": "paid"
          },
          "e": {},
          "l": []
        }
        """)
    }
}

struct MongoBuilderValueTests {
    @Test func writesExtendedJSON() throws {
        func written(_ value: MongoValue) -> String? { value.json?.inline }
        #expect(written(.string("paid")) == #""paid""#)
        #expect(written(.number("12.5")) == "12.5")
        #expect(written(.number("-3")) == "-3")
        #expect(written(.bool(true)) == "true")
        #expect(written(MongoValue(.bool, "false")) == "false")
        #expect(written(.null) == "null")
        #expect(written(MongoValue(.date, "2026-01-01T00:00:00Z")) == #"{ "$date": "2026-01-01T00:00:00Z" }"#)
        #expect(written(MongoValue(.objectId, "507f1f77bcf86cd799439011")) == #"{ "$oid": "507f1f77bcf86cd799439011" }"#)
        #expect(written(MongoValue(.decimal, "12.50")) == #"{ "$numberDecimal": "12.50" }"#)
        #expect(written(MongoValue(.long, "9223372036854775807")) == #"{ "$numberLong": "9223372036854775807" }"#)
        #expect(written(MongoValue(.regex, "^paid", options: "i")) == #"{ "$regularExpression": { "pattern": "^paid", "options": "i" } }"#)
        #expect(written(.field("total")) == #""$total""#)
        #expect(written(MongoValue(.input, "customer")) == #"{ "$input": "customer" }"#)
        #expect(written(MongoValue(.json, #"{"$binary": {"base64": "aGk=", "subType": "00"}}"#)) == #"{ "$binary": { "base64": "aGk=", "subType": "00" } }"#)
    }

    @Test(arguments: [
        MongoValue(.number, "12,5"), MongoValue(.number, ""), MongoValue(.bool, "yes"), MongoValue(.date, "2026-13-01"), MongoValue(.date, "yesterday"),
        MongoValue(.objectId, "507f1f77bcf86cd79943901"), MongoValue(.objectId, "507f1f77bcf86cd79943901z"), MongoValue(.decimal, "12.5.0"),
        MongoValue(.long, "9223372036854775808"), MongoValue(.regex, "a", options: "g"), MongoValue(.field, ""), MongoValue(.input, " "), MongoValue(.json, "{a: 1}")
    ])
    func refusesInvalidValues(value: MongoValue) {
        #expect(value.json == nil)
        #expect(value.problem?.isEmpty == false)
    }

    @Test func readsTypedValuesBack() throws {
        let cases: [(String, MongoValue.Kind)] = [
            (#""paid""#, .string), ("12.50", .number), ("true", .bool), ("null", .null),
            (#"{"$date": "2026-01-01T09:30:00.250Z"}"#, .date), (#"{"$oid": "507F1F77BCF86CD799439011"}"#, .objectId),
            (#"{"$numberDecimal": "NaN"}"#, .decimal), (#"{"$numberLong": "-5"}"#, .long),
            (#"{"$regularExpression": {"pattern": "^a", "options": "im"}}"#, .regex), (#"{"$input": "limit"}"#, .input),
            (#"{"$date": {"$numberLong": "1767225600000"}}"#, .json), (#"{"$numberInt": "5"}"#, .json), ("[1, 2]", .json),
            (#"{"city": "Cluj"}"#, .json), (#"{"$regularExpression": {"options": "i", "pattern": "^a"}}"#, .json)
        ]
        for (text, kind) in cases {
            let json = try MongoJSON.parse(text)
            let value = MongoValue(json: json)
            #expect(value.kind == kind, "\(text)")
            #expect(value.json == json, "round trip of \(text)")
        }
        #expect(MongoValue(json: .string("$total"), expression: true) == .field("total"))
        #expect(MongoValue(json: .string("$$ROOT"), expression: true).kind == .string)
        #expect(MongoValue(json: .string("$total")).kind == .string)
    }

    @Test func datesAreWrittenInUTC() throws {
        let date = try #require(MongoValue.date(from: "2026-03-01T10:15:00+02:00"))
        #expect(MongoValue.isoText(date) == "2026-03-01T08:15:00Z")
        #expect(MongoValue.isoText(date.addingTimeInterval(0.25)) == "2026-03-01T08:15:00.250Z")
        #expect(MongoValue(.date, "2026-03-01T10:15:00+02:00").json != nil)
        #expect(MongoValue.empty(.date).text.hasSuffix("T00:00:00Z"))
    }

    @Test func kindsFromSampledTypes() {
        #expect(MongoValue.kind(forSampledTypes: "ObjectId") == .objectId)
        #expect(MongoValue.kind(forSampledTypes: "MongoDB\\BSON\\UTCDateTime") == .date)
        #expect(MongoValue.kind(forSampledTypes: "null, Decimal128") == .decimal)
        #expect(MongoValue.kind(forSampledTypes: "int, double") == .number)
        #expect(MongoValue.kind(forSampledTypes: "Int64") == .long)
        #expect(MongoValue.kind(forSampledTypes: "bool") == .bool)
        #expect(MongoValue.kind(forSampledTypes: "object") == .json)
        #expect(MongoValue.kind(forSampledTypes: "string") == .string)
        #expect(MongoValue.kind(forSampledTypes: "null") == .null)
    }

    @Test func convertsBetweenKinds() {
        #expect(MongoValue.number("12").converted(to: .decimal) == MongoValue(.decimal, "12"))
        #expect(MongoValue.string("x").converted(to: .json).json == .string("x"))
        #expect(MongoValue.string("a").converted(to: .null) == .null)
        #expect(MongoValue(.date, "2026-01-01T00:00:00Z").converted(to: .string) == .string("2026-01-01T00:00:00Z"))
    }
}

struct MongoBuilderFilterTests {
    private func filter(_ text: String) throws -> (MongoJSON, MongoFilterGroup) {
        let json = try MongoJSON.parse(text)
        return (json, try #require(MongoFilterGroup.parse(json)))
    }

    private func rule(_ path: String, _ op: MongoFilterRule.Operator, _ value: MongoValue = .string(""), values: [MongoValue] = []) -> MongoFilterNode {
        .rule(MongoFilterRule(path: path, op: op, value: value, values: values))
    }

    @Test func writesEveryOperator() throws {
        let group = MongoFilterGroup(children: [
            rule("status", .equals, .string("paid")),
            rule("kind", .notEquals, .string("test")),
            rule("total", .greater, .number("10")),
            rule("items", .greaterOrEqual, .number("1")),
            rule("placed_at", .less, MongoValue(.date, "2026-01-01T00:00:00Z")),
            rule("price", .lessOrEqual, MongoValue(.decimal, "99.90")),
            rule("customer.city", .inList, values: [.string("Cluj"), .string("Iasi")]),
            rule("_id", .notInList, values: [MongoValue(.objectId, "507f1f77bcf86cd799439011")]),
            rule("deleted_at", .exists, .bool(false)),
            rule("email", .regex, MongoValue(.string, "@example\\.com$", options: "i")),
            rule("note", .type, .string("string")),
        ])
        #expect(try group.filterJSON().inline == #"{ "status": "paid", "kind": { "$ne": "test" }, "total": { "$gt": 10 }, "items": { "$gte": 1 }, "placed_at": { "$lt": { "$date": "2026-01-01T00:00:00Z" } }, "price": { "$lte": { "$numberDecimal": "99.90" } }, "customer.city": { "$in": ["Cluj", "Iasi"] }, "_id": { "$nin": [{ "$oid": "507f1f77bcf86cd799439011" }] }, "deleted_at": { "$exists": false }, "email": { "$regex": "@example\\.com$", "$options": "i" }, "note": { "$type": "string" } }"#)
        let read = try #require(MongoFilterGroup.parse(try group.filterJSON()))
        #expect(read.allRules.map(\.op) == MongoFilterRule.Operator.allCases)
        #expect(try read.filterJSON() == group.filterJSON())
    }

    @Test(arguments: [
        #"{}"#,
        #"{"status": "paid"}"#,
        #"{"total": {"$gte": 10, "$lt": 100}, "status": {"$eq": "paid"}}"#,
        #"{"_id": {"$oid": "507f1f77bcf86cd799439011"}, "at": {"$date": "2026-01-01T00:00:00Z"}}"#,
        #"{"$or": [{"status": "paid"}, {"total": {"$gt": 100}, "vip": true}]}"#,
        #"{"$nor": [{"status": "void"}]}"#,
        #"{"status": "paid", "$or": [{"a": 1}, {"$and": [{"b": 2}, {"c": {"$exists": true}}]}]}"#,
        #"{"$and": [{"a": 1}, {"a": 2}]}"#,
        #"{"name": {"$regex": "^a"}, "tags": {"$in": []}}"#,
        #"{"customer": {"city": "Cluj", "zip": "400000"}}"#,
        #"{"customer.name": {"$input": "customer"}, "status": "paid"}"#,
        #"{"$or": [{}, {"a": 1}]}"#,
    ])
    func roundTripsSupportedFilters(text: String) throws {
        let (json, group) = try filter(text)
        #expect(try group.filterJSON() == json)
        let raw = group.children.filter { if case .raw = $0 { true } else { false } }
        #expect(raw.isEmpty, "no raw blocks in \(text)")
    }

    @Test(arguments: [
        (#"{"tags": {"$elemMatch": {"a": 1}}, "status": "paid"}"#, ["tags"]),
        (#"{"$expr": {"$gt": ["$a", "$b"]}}"#, ["$expr"]),
        (#"{"$text": {"$search": "coffee"}, "n": {"$size": 2}}"#, ["$text", "n"]),
        (#"{"a": {"$options": "i", "$regex": "x"}}"#, ["a"]),
        (#"{"a": {"$exists": 1}}"#, ["a"]),
        (#"{"a": {"$gt": 1, "$gt": 2}}"#, ["a"]),
        (#"{"$or": []}"#, ["$or"]),
        (#"{"": 1}"#, [""]),
    ])
    func keepsUnsupportedPartsRaw(text: String, raw: [String]) throws {
        let (json, group) = try filter(text)
        #expect(try group.filterJSON() == json)
        let keys = group.children.compactMap { if case .raw(let member) = $0 { member.key } else { nil } }
        #expect(keys == raw)
    }

    @Test func duplicateKeysStayAsRead() throws {
        let (json, group) = try filter(#"{"a": {"$gt": 1}, "b": 2, "a": {"$lt": 5}}"#)
        #expect(try group.filterJSON() == json)
        #expect(group.children.allSatisfy { if case .raw = $0 { true } else { false } })
    }

    @Test func groupsAndMerging() throws {
        var root = MongoFilterGroup(kind: .any, children: [
            rule("status", .equals, .string("paid")),
            .group(MongoFilterGroup(kind: .all, implicit: true, children: [rule("total", .greater, .number("100")), rule("vip", .equals, .bool(true))])),
            .group(MongoFilterGroup(kind: .none, children: [rule("country", .equals, .string("RO"))])),
            .group(MongoFilterGroup(kind: .all, children: [])),
            rule("", .equals, .string("ignored")),
        ])
        #expect(try root.filterJSON().inline == #"{ "$or": [{ "status": "paid" }, { "total": { "$gt": 100 }, "vip": true }, { "$nor": [{ "country": "RO" }] }] }"#)
        root.kind = .all
        #expect(try root.filterJSON().inline == #"{ "status": "paid", "$and": [{ "total": { "$gt": 100 } }, { "vip": true }], "$nor": [{ "country": "RO" }] }"#)
        // Rules on one path share an operator object; = becomes $eq there; a repeated operator goes to $and.
        let merged = MongoFilterGroup(children: [rule("total", .equals, .number("5")), rule("total", .less, .number("9")), rule("total", .less, .number("7"))])
        #expect(try merged.filterJSON().inline == #"{ "total": { "$eq": 5, "$lt": 9 }, "$and": [{ "total": { "$lt": 7 } }] }"#)
        #expect(try MongoFilterGroup(kind: .any).filterJSON() == .object([]))
    }

    @Test func invalidValuesStopWriting() {
        let group = MongoFilterGroup(children: [rule("_id", .equals, MongoValue(.objectId, "nope"))])
        #expect(throws: MongoBuilderProblem.self) { try group.filterJSON() }
        let list = MongoFilterGroup(children: [rule("n", .inList, values: [.number("1"), .number("x")])])
        #expect(throws: MongoBuilderProblem.self) { try list.filterJSON() }
    }

    @Test func changingOperatorsCarriesValues() {
        var rule = MongoFilterRule(path: "status", value: .string("paid"))
        rule.setOperator(.inList)
        #expect(rule.values == [.string("paid")])
        rule.setOperator(.equals)
        #expect(rule.value == .string("paid"))
        rule.setOperator(.regex)
        #expect(rule.value.text == "paid")
        rule.setOperator(.exists)
        #expect(rule.value == .bool(true))
        rule.setOperator(.type)
        #expect(rule.value == .string("string"))
        rule.setOperator(.notEquals)
        #expect(rule.value == .string(""))
    }

    @Test func filterByValueReplacesTheSameRule() {
        var group = MongoFilterGroup(children: [rule("status", .equals, .string("open"))])
        group.setRule(MongoFilterRule(path: "status", value: .string("paid")))
        group.setRule(MongoFilterRule(path: "total", value: .number("10")))
        #expect(group.allRules.map(\.value) == [.string("paid"), .number("10")])
    }
}

struct MongoBuilderStageTests {
    private func roundTrip(_ text: String) throws -> MongoStage {
        let json = try MongoJSON.parse(text)
        let stage = MongoStage.parse(json)
        #expect(try stage.json() == json, "\(text)")
        return stage
    }

    @Test func readsEveryStage() throws {
        let cases: [(String, MongoStage.Kind)] = [
            (#"{"$match": {"status": "paid", "total": {"$gte": 10}}}"#, .match),
            (#"{"$project": {"status": 1, "_id": 0, "total": "$amount", "n": {"$size": "$items"}}}"#, .project),
            (#"{"$group": {"_id": "$customer", "total": {"$sum": "$total"}, "avg": {"$avg": "$total"}, "min": {"$min": "$total"}, "max": {"$max": "$total"}, "n": {"$count": {}}, "ids": {"$push": "$_id"}}}"#, .group),
            (#"{"$group": {"_id": null, "n": {"$sum": 1}}}"#, .group),
            (#"{"$group": {"_id": {"city": "$customer.city", "status": "$status"}, "n": {"$sum": 1}}}"#, .group),
            (#"{"$group": {"_id": {"$year": "$placed_at"}, "n": {"$sum": 1}}}"#, .group),
            (#"{"$sort": {"total": -1, "_id": 1}}"#, .sort),
            (#"{"$limit": 10}"#, .limit),
            (#"{"$skip": 20}"#, .skip),
            (#"{"$unwind": "$items"}"#, .unwind),
            (#"{"$unwind": {"path": "$items", "includeArrayIndex": "i", "preserveNullAndEmptyArrays": true}}"#, .unwind),
            (#"{"$unwind": {"path": "$items"}}"#, .unwind),
            (#"{"$lookup": {"from": "customers", "localField": "customer_id", "foreignField": "_id", "as": "customer"}}"#, .lookup),
            (#"{"$addFields": {"net": {"$subtract": ["$total", "$tax"]}, "source": "web"}}"#, .addFields),
            (#"{"$set": {"total": "$amount"}}"#, .set),
            (#"{"$count": "orders"}"#, .count),
        ]
        for (text, kind) in cases {
            let stage = try roundTrip(text)
            #expect(stage.kind == kind, "\(text)")
        }
        let group = try roundTrip(#"{"$group": {"_id": {"city": "$customer.city"}, "n": {"$sum": 1}}}"#)
        guard case .group(let body) = group.body, case .fields(let fields) = body.key else { Issue.record("fields key"); return }
        #expect(fields.map(\.path) == ["customer.city"])
    }

    @Test(arguments: [
        #"{"$facet": {"a": [{"$count": "n"}]}}"#,
        #"{"$lookup": {"from": "c", "let": {"x": "$x"}, "pipeline": [], "as": "y"}}"#,
        #"{"$lookup": {"as": "customer", "from": "customers", "localField": "a", "foreignField": "b"}}"#,
        #"{"$group": {"n": {"$sum": 1}, "_id": null}}"#,
        #"{"$group": {"_id": null, "n": 1}}"#,
        #"{"$unwind": {"path": "items"}}"#,
        #"{"$match": {"a": 1}, "$limit": 1}"#,
        #"{"$sample": {"size": 3}}"#,
        #"{"$count": 1}"#,
    ])
    func keepsOtherStagesRaw(text: String) throws {
        let stage = try roundTrip(text)
        #expect(stage.kind == .raw)
    }

    @Test func buildsStages() throws {
        var group = MongoGroupStage(key: .field("customer.city"), accumulators: [
            MongoAccumulator(name: "orders", op: "$sum", argument: .number("1")),
            MongoAccumulator(name: "revenue", op: "$sum", argument: .field("total")),
            MongoAccumulator(name: "", op: "$sum", argument: .number("1")),
        ])
        #expect(try MongoStage(.group(group)).json()?.inline == #"{ "$group": { "_id": "$customer.city", "orders": { "$sum": 1 }, "revenue": { "$sum": "$total" } } }"#)
        group.accumulators[0].setOperator("$count")
        #expect(group.accumulators[0].argument.json == .object([]))
        group.key = .all
        #expect(try MongoStage(.group(group)).json()?.inline == #"{ "$group": { "_id": null, "orders": { "$count": {} }, "revenue": { "$sum": "$total" } } }"#)
        #expect(try MongoStage(.unwind(MongoUnwindStage(path: "items", preserveNullAndEmptyArrays: true))).json()?.inline == #"{ "$unwind": { "path": "$items", "preserveNullAndEmptyArrays": true } }"#)
        #expect(try MongoStage(.lookup(MongoLookupStage(from: "customers", localField: "customer_id", foreignField: "_id", output: "customer"))).json()?.inline
            == #"{ "$lookup": { "from": "customers", "localField": "customer_id", "foreignField": "_id", "as": "customer" } }"#)
        #expect(try MongoStage(.lookup(MongoLookupStage(from: "customers"))).json() == nil)
        #expect(MongoStage(.lookup(MongoLookupStage(from: "customers"))).incomplete != nil)
        var disabled = MongoStage.new(.limit)
        disabled.enabled = false
        #expect(try disabled.json() == nil)
        #expect(MongoStage.new(.raw).duplicated.id != MongoStage.new(.raw).id)
        for kind in MongoStage.Kind.allCases where ![.unwind, .lookup].contains(kind) {
            #expect(try MongoStage.new(kind).json() != nil, "\(kind)")
            #expect(MongoStage.new(kind).kind == kind)
        }
        #expect(throws: MongoBuilderProblem.self) { try MongoStage(.raw("{ nope")).json() }
    }
}

struct MongoBuilderUpdateTests {
    @Test func writesUpdateOperators() throws {
        let nodes: [MongoUpdateNode] = [
            .entry(MongoUpdateEntry(op: .set, path: "status", value: .string("paid"))),
            .entry(MongoUpdateEntry(op: .inc, path: "visits", value: .number("1"))),
            .entry(MongoUpdateEntry(op: .set, path: "paid_at", value: MongoValue(.date, "2026-01-02T03:04:05Z"))),
            .entry(MongoUpdateEntry(op: .unset, path: "draft")),
            .entry(MongoUpdateEntry(op: .push, path: "tags", value: .string("vip"))),
            .entry(MongoUpdateEntry(op: .pull, path: "tags", value: .string("new"))),
            .entry(MongoUpdateEntry(op: .set, path: "", value: .string("skipped"))),
            .raw(MongoRawMember(key: "$rename", text: #"{"old": "new"}"#)),
        ]
        let json = try MongoUpdateNode.object(nodes)
        #expect(json.inline == #"{ "$set": { "status": "paid", "paid_at": { "$date": "2026-01-02T03:04:05Z" } }, "$inc": { "visits": 1 }, "$unset": { "draft": "" }, "$push": { "tags": "vip" }, "$pull": { "tags": "new" }, "$rename": { "old": "new" } }"#)
        let read = try #require(MongoUpdateNode.parse(json))
        #expect(try MongoUpdateNode.object(read) == json)
        #expect(read.filter { if case .raw = $0 { true } else { false } }.count == 1)
        var entry = MongoUpdateEntry(op: .set, path: "n", value: .string("x"))
        entry.setOperator(.inc)
        #expect(entry.value == .number("1"))
        entry.setOperator(.unset)
        #expect(entry.value == .string(""))
    }

    @Test(arguments: [
        #"{"$set": {"a": 1}, "$currentDate": {"at": true}}"#,
        #"{"$push": {"tags": {"$each": ["a", "b"]}}, "$pull": {"items": {"qty": {"$lt": 1}}}}"#,
        #"{"$unset": {"a": 1, "b": true}}"#,
        #"{"$set": {"a": 1}, "$inc": {"b": 1}, "$set": {"c": 2}}"#,
        #"{"$set": {}}"#,
    ])
    func roundTripsUpdates(text: String) throws {
        let json = try MongoJSON.parse(text)
        let nodes = try #require(MongoUpdateNode.parse(json))
        #expect(try MongoUpdateNode.object(nodes) == json)
    }
}

struct MongoQueryBuilderTests {
    /// Hand-written queries the builder supports: read and written back, they're the same JSON
    /// in the same order; pretty-printed the builder's way, the same text.
    static let supported = [
        #"{"collection": "orders", "operation": "find", "filter": {"status": "paid", "total": {"$gte": 10}}, "projection": {"status": 1, "total": 1, "_id": 0}, "sort": {"total": -1, "_id": 1}, "skip": 20, "limit": 10}"#,
        #"{"operation": "find", "collection": "orders", "limit": 5, "filter": {"$or": [{"status": "paid"}, {"vip": true}]}}"#,
        #"{"collection": "orders", "operation": "findOne", "filter": {"_id": {"$oid": "507f1f77bcf86cd799439011"}}}"#,
        #"{"collection": "orders", "operation": "countDocuments", "filter": {"placed_at": {"$gte": {"$date": "2026-01-01T00:00:00Z"}}}}"#,
        #"{"collection": "orders", "operation": "distinct", "field": "customer.city", "filter": {"status": "paid"}}"#,
        #"{"collection": "orders", "operation": "aggregate", "pipeline": [{"$match": {"status": "paid"}}, {"$lookup": {"from": "customers", "localField": "customer_id", "foreignField": "_id", "as": "customer"}}, {"$unwind": "$customer"}, {"$group": {"_id": "$customer.city", "revenue": {"$sum": "$total"}, "orders": {"$count": {}}}}, {"$sort": {"revenue": -1}}, {"$limit": 5}], "explain": false}"#,
        #"{"collection": "orders", "operation": "updateMany", "filter": {"status": "pending"}, "update": {"$set": {"status": "paid", "price": {"$numberDecimal": "12.50"}}, "$inc": {"version": 1}}}"#,
        #"{"collection": "orders", "operation": "updateOne", "filter": {"_id": {"$oid": "507f1f77bcf86cd799439011"}}, "update": {"$unset": {"draft": ""}, "$push": {"tags": "vip"}, "$pull": {"tags": "new"}}}"#,
        #"{"collection": "orders", "operation": "replaceOne", "filter": {"n": 1}, "replacement": {"n": 1, "status": "paid"}}"#,
        #"{"collection": "orders", "operation": "insertMany", "documents": [{"n": 1}, {"n": 2, "at": {"$date": "2026-01-01T00:00:00Z"}}]}"#,
        #"{"collection": "orders", "operation": "deleteMany", "filter": {"status": "void"}}"#,
        #"{"collection": "orders", "operation": "createIndex", "keys": {"status": 1}, "unique": true}"#,
        #"{"operation": "dropDatabase", "database": "shop"}"#,
        #"{"collection": "orders", "operation": "find", "filter": {"customer.name": {"$input": "customer"}}, "limit": {"$input": "limit"}}"#,
    ]

    @Test(arguments: supported)
    func roundTripsHandWrittenQueries(text: String) throws {
        let json = try MongoJSON.parse(text)
        let builder = try MongoQueryBuilder.read(text).get()
        #expect(try builder.json() == json)
        let pretty = try #require(builder.text)
        #expect(try MongoQueryBuilder.read(pretty).get().text == pretty)
        #expect(pretty == json.pretty())
        if builder.isBuilderOperation {
            #expect(builder.extras.isEmpty, "\(builder.extras.map(\.key))")
        }
    }

    @Test func keepsUnsupportedPartsAndOrder() throws {
        let text = #"{"limit": 3, "operation": "find", "comment": "x", "collection": "orders", "filter": {"tags": {"$all": ["a", "b"]}, "status": "paid"}, "pipeline": []}"#
        let builder = try MongoQueryBuilder.read(text).get()
        #expect(builder.extras.map(\.key) == ["comment", "pipeline"])
        #expect(builder.order == ["limit", "operation", "comment", "collection", "filter", "pipeline"])
        #expect(try builder.json() == MongoJSON.parse(text))
        guard case .raw(let raw) = builder.filter?.children.first else { Issue.record("raw $all"); return }
        #expect(raw.key == "tags")
    }

    @Test func fieldsTheOperationDoesntTakeStayRaw() throws {
        let text = #"{"collection": "orders", "operation": "countDocuments", "filter": {}, "sort": {"a": 1}}"#
        var builder = try MongoQueryBuilder.read(text).get()
        #expect(builder.sort == nil)
        #expect(builder.extras.map(\.key) == ["sort"])
        builder.filter?.children.append(.rule(MongoFilterRule(path: "status", value: .string("paid"))))
        #expect(builder.text?.contains("\"sort\": { \"a\": 1 }") == true)
    }

    @Test func unreadableTextAndNonObjects() {
        guard case .failure(.json(let error)) = MongoQueryBuilder.read("{\"collection\": \"orders\",\n  \"operation\": }") else { Issue.record("json error"); return }
        #expect(error.line == 2)
        #expect(MongoQueryBuilder.read("[1]") == .failure(.notAnObject))
        let raw = MongoQueryBuilder(json: .object([.init("collection", .number("1")), .init("operation", .string("find"))]))
        #expect(raw.extras.map(\.key) == ["collection"])
        #expect((try? raw.json()) == .object([.init("collection", .number("1")), .init("operation", .string("find"))]))
    }

    @Test func buildsQueriesFromScratch() throws {
        var builder = MongoQueryBuilder.start(collection: "orders")
        #expect(builder.text == "{\n  \"collection\": \"orders\",\n  \"operation\": \"find\",\n  \"filter\": {},\n  \"limit\": 50\n}")
        builder.filter?.children = [
            .rule(MongoFilterRule(path: "status", value: .string("paid"))),
            .rule(MongoFilterRule(path: "placed_at", op: .greaterOrEqual, value: MongoValue(.date, "2026-01-01T00:00:00Z"))),
        ]
        builder.projection = [MongoFieldValue(path: "status"), MongoFieldValue(path: "_id", value: .number("0"))]
        builder.sort = [MongoFieldValue(path: "placed_at", value: .number("-1"))]
        builder.skip = .number("10")
        #expect(builder.text == """
        {
          "collection": "orders",
          "operation": "find",
          "filter": {
            "status": "paid",
            "placed_at": { "$gte": { "$date": "2026-01-01T00:00:00Z" } }
          },
          "projection": { "status": 1, "_id": 0 },
          "sort": { "placed_at": -1 },
          "skip": 10,
          "limit": 50
        }
        """)
        #expect(builder.effect == .read)
        #expect(builder.runProblem == nil)
        // count: only the filter is written; switching back restores the rest.
        builder.setOperation("countDocuments")
        #expect(try builder.json().members?.map(\.key) == ["collection", "operation", "filter"])
        #expect(try MongoQuery(builder.text!).effect == .read)
        builder.setOperation("find")
        #expect(builder.text?.contains("\"limit\": 50") == true)
        // aggregate starts from the find.
        builder.setOperation("aggregate")
        #expect(builder.pipeline?.map(\.kind) == [.match, .sort, .skip, .limit, .project])
        #expect(try MongoQuery(builder.text!).operation == "aggregate")
        builder.setOperation("distinct")
        #expect(builder.runProblem != nil)
        builder.field = "customer.city"
        #expect(builder.runProblem == nil)
        builder.setOperation("updateMany")
        #expect(builder.update?.count == 1)
        #expect(builder.runProblem != nil, "an empty update is refused")
        builder.update = [.entry(MongoUpdateEntry(op: .set, path: "status", value: .string("archived")))]
        #expect(builder.effect == .write)
        builder.filter = MongoFilterGroup()
        #expect(builder.effect == .destructive)
        builder.setOperation("insertOne")
        #expect(try MongoQuery(builder.text!).effect == .write)
        builder.setOperation("replaceOne")
        #expect(builder.replacement == "{}")
        #expect(builder.runProblem == nil)
    }

    @Test func invalidValuesStopWritingWithAReason() {
        var builder = MongoQueryBuilder.start(collection: "orders")
        builder.filter?.children = [.rule(MongoFilterRule(path: "_id", value: MongoValue(.objectId, "123")))]
        #expect(builder.text == nil)
        #expect(builder.problem?.contains("24 hexadecimal") == true)
        builder.filter?.children = [.rule(MongoFilterRule(path: "", value: .string("x"))), .group(MongoFilterGroup(kind: .any))]
        #expect(builder.text != nil)
        #expect(builder.incomplete.count == 2)
    }

    @Test func everyStageAndOperatorIsAcceptedByMongoQuery() throws {
        var builder = MongoQueryBuilder(collection: "orders", operation: "aggregate")
        builder.pipeline = MongoStage.Kind.allCases.map { MongoStage.new($0) }
        builder.pipeline?[6] = MongoStage(.unwind(MongoUnwindStage(path: "items")))
        builder.pipeline?[7] = MongoStage(.lookup(MongoLookupStage(from: "customers", localField: "customer_id", foreignField: "_id", output: "customer")))
        let text = try #require(builder.text)
        let query = try MongoQuery(text)
        #expect(query.effect == .read)
        #expect(try MongoQueryBuilder.read(text).get().text == text)
    }
}

struct MongoBuilderTextTests {
    @Test func findsTheQueries() {
        let text = "// @title Two\n{\"a\": \"}\", \"b\": {\"c\": 1}}\n\n{\"d\": 2}\n{\"e\":"
        let blocks = MongoBuilderText.blocks(in: text)
        #expect(blocks.count == 3)
        #expect(blocks.map(\.closed) == [true, true, false])
        let ns = text as NSString
        #expect(ns.substring(with: blocks[1].range) == "{\"d\": 2}")
        #expect(MongoBuilderText.target(in: text, selection: NSRange(location: 20, length: 0)) == .query(blocks[0].range))
        #expect(MongoBuilderText.target(in: text, selection: NSRange(location: NSMaxRange(blocks[1].range), length: 0)) == .query(blocks[1].range))
        #expect(MongoBuilderText.target(in: text, selection: NSRange(location: ns.length, length: 0)) == .unclosed(blocks[2].range))
        #expect(MongoBuilderText.target(in: text, selection: NSRange(location: 2, length: 0)) == .none)
        #expect(MongoBuilderText.target(in: text, selection: blocks[1].range) == .query(blocks[1].range))
        #expect(MongoBuilderText.target(in: "\n\n  {\"a\": 1}\n\n", selection: NSRange(location: 0, length: 0)) == .query(NSRange(location: 4, length: 8)))
        #expect(MongoBuilderText.line(of: blocks[1].range.location, in: text) == 4)
    }

    @Test func rewritesOnlyWhatChanged() {
        let text = "{\"x\": 0}\n\n{\n  \"a\": 1,\n  \"b\": 2\n}\n"
        let range = NSRange(location: 10, length: (text as NSString).length - 11)
        let query = "{\n  \"a\": 1,\n  \"b\": 25,\n  \"c\": 3\n}"
        let caret = NSRange(location: 15, length: 0)
        let edit = MongoBuilderText.rewrite(range, with: query, in: text, selection: caret)
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        #expect(result == "{\"x\": 0}\n\n" + query + "\n")
        #expect(edit.range.location > range.location)
        #expect(edit.selection == caret)
        #expect((result as NSString).substring(with: edit.query) == query)
        // A selected query stays selected.
        let selected = MongoBuilderText.rewrite(range, with: query, in: text, selection: range)
        #expect(selected.selection == edit.query)
    }

    @Test func insertsNewQueries() {
        let blank = MongoBuilderText.insert("{}", in: "  \n")
        #expect(blank.range == NSRange(location: 0, length: 3) && blank.replacement == "{}\n")
        let end = MongoBuilderText.insert("{\"b\": 1}", in: "{\"a\": 1}")
        #expect(end.replacement == "\n\n{\"b\": 1}\n")
        #expect(end.selection.location == 10)
        let after = MongoBuilderText.insert("{\"b\": 1}", in: "{\"a\": 1}\n\n{\"c\": 1}\n", after: NSRange(location: 0, length: 8))
        let result = ("{\"a\": 1}\n\n{\"c\": 1}\n" as NSString).replacingCharacters(in: after.range, with: after.replacement)
        #expect(result == "{\"a\": 1}\n\n{\"b\": 1}\n\n{\"c\": 1}\n")
        #expect((result as NSString).substring(with: after.query) == "{\"b\": 1}")
    }

    @Test func debouncesWrites() {
        var schedule = MongoBuilderSchedule(delay: 0.4)
        let start = Date(timeIntervalSince1970: 0)
        #expect(!schedule.isDue(at: start))
        schedule.change(at: start)
        schedule.change(at: start.addingTimeInterval(0.2))
        schedule.change(at: start.addingTimeInterval(0.35))
        #expect(!schedule.isDue(at: start.addingTimeInterval(0.6)))
        #expect(schedule.isDue(at: start.addingTimeInterval(0.75)))
        schedule.clear()
        #expect(!schedule.isPending)
    }
}
