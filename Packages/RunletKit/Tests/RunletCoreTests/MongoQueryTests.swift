import Foundation
@testable import RunletCore
import Testing

struct MongoQueryTests {
    @Test(arguments: ["find", "findOne", "countDocuments", "getIndexes"])
    func reads(operation: String) throws {
        let query = try MongoQuery("{\"collection\":\"p191_orders\",\"operation\":\"\(operation)\"}")
        #expect(query.effect == .read)
        #expect(query.operation == operation)
    }

    @Test(arguments: [
        #"{"operation":"distinct","field":"status"}"#,
        #"{"operation":"aggregate","pipeline":[{"$match":{"status":"paid"}},{"$group":{"_id":"$status","total":{"$sum":1}}}]}"#,
        #"{"operation":"find","filter":{"_id":{"$oid":"507f1f77bcf86cd799439011"},"date":{"$date":"2026-01-01T00:00:00Z"},"total":{"$numberDecimal":"12.50"},"size":{"$numberLong":"9223372036854775807"},"name":{"$regularExpression":{"pattern":"^a","options":"i"}}},"projection":{"status":1},"sort":{"_id":1},"skip":2,"limit":10,"explain":true}"#
    ])
    func structuredReads(fields: String) throws {
        let query = try makeQuery(fields)
        #expect(query.effect == .read)
        #expect(try MongoQuery(query.json) == query)
    }

    @Test(arguments: [
        #"{"operation":"insertOne","documents":[{"name":"Sprocket"}]}"#,
        #"{"operation":"insertMany","documents":[{"name":"Sprocket"},{"name":"Gear"}]}"#,
        #"{"operation":"updateOne","update":{"$set":{"status":"paid"}}}"#,
        #"{"operation":"updateMany","filter":{"status":"pending"},"update":{"$set":{"status":"paid"}}}"#,
        #"{"operation":"replaceOne","replacement":{"status":"paid"}}"#,
        #"{"operation":"deleteOne"}"#,
        #"{"operation":"deleteMany","filter":{"status":"cancelled"}}"#,
        #"{"operation":"createIndex","keys":{"status":1},"unique":false}"#,
        #"{"operation":"aggregate","pipeline":[{"$out":"p191_export"}]}"#,
        #"{"operation":"aggregate","pipeline":[{"$merge":{"into":"p191_export"}}]}"#,
        #"{"operation":"aggregate","pipeline":[{"$facet":{"nested":[{"$out":"p191_export"}]}}]}"#
    ])
    func writes(fields: String) throws {
        #expect(try makeQuery(fields).effect == .write)
    }

    @Test(arguments: [
        #"{"operation":"drop"}"#,
        #"{"operation":"deleteMany"}"#,
        #"{"operation":"deleteMany","filter":{}}"#,
        #"{"operation":"updateMany","filter":{},"update":{"$set":{"status":"paid"}}}"#,
        #"{"operation":"updateMany","update":{"$set":{"status":"paid"}}}"#
    ])
    func destructive(fields: String) throws {
        #expect(try makeQuery(fields).effect == .destructive)
    }

    @Test(arguments: [
        #"{"operation":"eval"}"#,
        #"{"operation":"dropDatabase"}"#,
        #"{"operation":"find","password":"secret"}"#,
        #"{"operation":"find","filter":[]}"#,
        #"{"operation":"find","filter":null}"#,
        #"{"operation":"find","limit":true}"#,
        #"{"operation":"find","limit":-1}"#,
        #"{"operation":"find","limit":1.5}"#,
        #"{"operation":"find","skip":1000001}"#,
        #"{"operation":"find","explain":1}"#,
        #"{"operation":"find","filter":{"$where":"return true"}}"#,
        #"{"operation":"find","filter":{"url":"mongodb://user:secret@localhost"}}"#,
        #"{"operation":"aggregate","pipeline":[{"$project":{"value":{"$function":{}}}}]}"#,
        #"{"operation":"aggregate","pipeline":[{"$out":"p191_export"}],"explain":true}"#,
        #"{"operation":"aggregate","pipeline":{}}"#,
        #"{"operation":"aggregate"}"#,
        #"{"operation":"distinct"}"#,
        #"{"operation":"insertOne","documents":[]}"#,
        #"{"operation":"insertOne","documents":[{},{}]}"#,
        #"{"operation":"insertMany","documents":[1]}"#,
        #"{"operation":"updateOne","update":{}}"#,
        #"{"operation":"replaceOne"}"#,
        #"{"operation":"createIndex","keys":{}}"#,
        #"{"operation":"deleteMany","limit":1}"#,
        #"{"operation":"drop","filter":{"status":"cancelled"}}"#
    ])
    func refusesInvalidOrAmbiguousQueries(fields: String) {
        #expect(throws: MongoQuery.Invalid.self) { try makeQuery(fields) }
    }

    @Test(arguments: ["", "[]", "null", "db.orders.find({})", "{} {}", #"{"operation":"find","collection":"system.users"}"#, #"{"operation":"find","collection":""}"#])
    func refusesInvalidDocuments(text: String) {
        #expect(throws: MongoQuery.Invalid.self) { try MongoQuery(text) }
    }

    @Test func rejectsOversizedInput() {
        #expect(throws: MongoQuery.Invalid.self) { try MongoQuery(String(repeating: " ", count: 1_048_577)) }
    }

    @Test func redactsURIs() {
        #expect(MongoRedaction.redact("failed mongodb://alice:p%40ss@localhost/db") == "failed mongodb://[redacted]@localhost/db")
        #expect(MongoRedaction.redact("MONGODB+SRV://alice:secret@example.test/db") == "MONGODB+SRV://[redacted]@example.test/db")
        #expect(MongoRedaction.redact("mongodb://localhost/db") == "mongodb://localhost/db")
    }

    @Test func preservesCompoundSortOrder() throws {
        let source = #"{"collection":"p191_orders","operation":"find","sort":{"z":1,"a":-1}}"#
        #expect(try MongoQuery(source).json == source)
    }

    @Test func generatedCodeKeepsUserInputAsData() throws {
        let query = try MongoQuery(#"{"collection":"p191_orders","operation":"find","filter":{"name":"'); phpinfo(); //"}}"#)
        let code = query.runnerCode(connection: "application", pageSize: 2000, offset: -2)
        #expect(!code.contains("phpinfo"))
        let encoded = try #require(code.components(separatedBy: "'").dropFirst().first)
        let data = try #require(Data(base64Encoded: encoded))
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(payload["query"] as? String == query.json)
        #expect(payload["pageSize"] as? Int == 1000)
        #expect(payload["offset"] as? Int == 0)
        #expect(payload["confirmed"] as? Bool == false)
    }

    private func makeQuery(_ fields: String) throws -> MongoQuery {
        let data = try #require(fields.data(using: .utf8))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["collection"] = "p191_orders"
        return try MongoQuery(String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }
}
