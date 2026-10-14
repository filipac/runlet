import Foundation
@testable import RunletCore
import Testing

/// The mongosh-like subset of MongoDB tabs (#220): each method, chaining, the relaxed literals,
/// the constructors, and the refusals, with where they point.
struct MongoShellTests {
    /// The translation on one line.
    private func json(_ text: String) throws -> String {
        try MongoShell.translate(text).json.inline
    }

    private func problem(_ text: String) -> MongoShell.Problem? {
        do {
            _ = try MongoShell.translate(text)
            return nil
        } catch {
            return error
        }
    }

    // MARK: Methods

    @Test func findWithFilterAndProjection() throws {
        #expect(try json(#"db.orders.find({status: "paid"}, {status: 1, total: 1})"#)
            == #"{ "collection": "orders", "operation": "find", "filter": { "status": "paid" }, "projection": { "status": 1, "total": 1 } }"#)
        #expect(try json("db.orders.find()") == #"{ "collection": "orders", "operation": "find" }"#)
        #expect(try json("db.orders.find({})") == #"{ "collection": "orders", "operation": "find", "filter": {} }"#)
    }

    @Test func findChainsSortSkipAndLimitInAnyOrder() throws {
        let expected = #"{ "collection": "orders", "operation": "find", "filter": { "status": "paid" }, "sort": { "placed_at": -1, "_id": 1 }, "skip": 40, "limit": 20 }"#
        #expect(try json(#"db.orders.find({status: "paid"}).sort({placed_at: -1, _id: 1}).skip(40).limit(20)"#) == expected)
        #expect(try json(#"db.orders.find({status: "paid"}).limit(20).skip(40).sort({placed_at: -1, _id: 1});"#) == expected)
        #expect(try json("""
            db.orders
              .find({status: "paid"})
              .limit(20)
              .sort({placed_at: -1, _id: 1})
              .skip(40)
            """) == expected)
    }

    @Test func aggregateKeepsNestedArraysAndObjects() throws {
        let text = """
            db.orders.aggregate([
              {$match: {status: {$in: ["paid", "shipped"]}, total: {$gte: 10.5}}},
              {$group: {_id: "$customer.city", total: {$sum: "$total"}, items: {$push: {sku: "$sku", qty: "$qty"}}}},
              {$sort: {total: -1}},
              {$limit: 5},
            ])
            """
        let translation = try MongoShell.translate(text)
        #expect(translation.operation == "aggregate")
        #expect(translation.json.inline == #"{ "collection": "orders", "operation": "aggregate", "pipeline": [{ "$match": { "status": { "$in": ["paid", "shipped"] }, "total": { "$gte": 10.5 } } }, { "$group": { "_id": "$customer.city", "total": { "$sum": "$total" }, "items": { "$push": { "sku": "$sku", "qty": "$qty" } } } }, { "$sort": { "total": -1 } }, { "$limit": 5 }] }"#)
        // One stage per line, as the query builder writes it.
        #expect(translation.text.contains("\"pipeline\": [\n    {\n      \"$match\""), "\(translation.text)")
        #expect(translation.text.contains("\n    { \"$sort\": { \"total\": -1 } },\n    { \"$limit\": 5 }\n  ]"), "\(translation.text)")
    }

    @Test func countAndDistinct() throws {
        #expect(try json("db.orders.countDocuments()") == #"{ "collection": "orders", "operation": "countDocuments" }"#)
        #expect(try json("db.orders.countDocuments({status: 'paid'})") == #"{ "collection": "orders", "operation": "countDocuments", "filter": { "status": "paid" } }"#)
        #expect(try json("db.orders.distinct('status')") == #"{ "collection": "orders", "operation": "distinct", "field": "status" }"#)
        #expect(try json("db.orders.distinct('customer.city', {status: 'paid'})")
            == #"{ "collection": "orders", "operation": "distinct", "field": "customer.city", "filter": { "status": "paid" } }"#)
    }

    @Test func inserts() throws {
        #expect(try json(#"db.products.insertOne({name: "Sprocket", price: NumberDecimal("4.20")})"#)
            == #"{ "collection": "products", "operation": "insertOne", "documents": [{ "name": "Sprocket", "price": { "$numberDecimal": "4.20" } }] }"#)
        #expect(try json(#"db.products.insertMany([{name: "Sprocket"}, {name: "Gear",},])"#)
            == #"{ "collection": "products", "operation": "insertMany", "documents": [{ "name": "Sprocket" }, { "name": "Gear" }] }"#)
    }

    @Test func updatesAndDeletes() throws {
        #expect(try json(#"db.orders.updateOne({_id: ObjectId("507f1f77bcf86cd799439011")}, {$set: {status: "paid"}})"#)
            == #"{ "collection": "orders", "operation": "updateOne", "filter": { "_id": { "$oid": "507f1f77bcf86cd799439011" } }, "update": { "$set": { "status": "paid" } } }"#)
        #expect(try json(#"db.orders.updateMany({status: "pending"}, {$inc: {attempts: 1}, $set: {status: "retry"}})"#)
            == #"{ "collection": "orders", "operation": "updateMany", "filter": { "status": "pending" }, "update": { "$inc": { "attempts": 1 }, "$set": { "status": "retry" } } }"#)
        #expect(try json(#"db.orders.deleteOne({_id: 7})"#) == #"{ "collection": "orders", "operation": "deleteOne", "filter": { "_id": 7 } }"#)
        #expect(try json(#"db.orders.deleteMany({status: "cancelled"})"#) == #"{ "collection": "orders", "operation": "deleteMany", "filter": { "status": "cancelled" } }"#)
    }

    @Test func collectionNames() throws {
        #expect(try MongoShell.translate("db.getCollection('order-items').find()").collection == "order-items")
        #expect(try MongoShell.translate(#"db.getCollection("order items",).countDocuments({})"#).collection == "order items")
        // mongosh reads db.a.b as the collection “a.b”.
        #expect(try MongoShell.translate("db.shop.orders.find()").collection == "shop.orders")
        #expect(try MongoShell.translate("db.$orders_2026.find()").collection == "$orders_2026")
    }

    // MARK: Literals

    @Test func relaxedLiterals() throws {
        #expect(try json("""
            db.orders.find({
              'status': 'paid',      // single quotes
              "note": 'it\\'s "fine"',
              $or: [{a: 1,}, {b: 2},],
              nested: {deep: {deeper: [1, [2, [3]]]}},
            },)
            """) == #"{ "collection": "orders", "operation": "find", "filter": { "status": "paid", "note": "it's \"fine\"", "$or": [{ "a": 1 }, { "b": 2 }], "nested": { "deep": { "deeper": [1, [2, [3]]] } } } }"#)
    }

    @Test func numbersKeepTheirLiterals() throws {
        #expect(try json("db.t.find({a: -5, b: 12.50, c: 1e3, d: -2.5E-3, e: 0, f: -0.25, g: .5, h: 5., i: 9007199254740993})")
            == #"{ "collection": "t", "operation": "find", "filter": { "a": -5, "b": 12.50, "c": 1e3, "d": -2.5e-3, "e": 0, "f": -0.25, "g": 0.5, "h": 5.0, "i": 9007199254740993 } }"#)
    }

    @Test func stringsMayHoldParenthesesCommentsAndEscapes() throws {
        #expect(try json(#"db.t.find({a: "f(x)", b: 'http://example.com/a', c: "/* not a comment */", d: "x) .limit(5)", e: "tab\there", f: "é\u{1F600}\x41", g: "😀", h: '\\d+'})"#)
            == #"{ "collection": "t", "operation": "find", "filter": { "a": "f(x)", "b": "http://example.com/a", "c": "/* not a comment */", "d": "x) .limit(5)", "e": "tab\there", "f": "é😀A", "g": "😀", "h": "\\d+" } }"#)
    }

    @Test func commentsAnywhere() throws {
        #expect(try json("""
            // Paid orders
            /* the newest first */
            db /* here */ . orders // and here
              .find({status: /* inline */ "paid"}) // trailing
              .limit(5) ;
            // after
            """) == #"{ "collection": "orders", "operation": "find", "filter": { "status": "paid" }, "limit": 5 }"#)
    }

    @Test func constructorsBecomeExtendedJSON() throws {
        #expect(try json(#"db.t.find({a: ObjectId("507F1F77BCF86CD799439011"), b: new ObjectId('507f1f77bcf86cd799439011')})"#)
            == #"{ "collection": "t", "operation": "find", "filter": { "a": { "$oid": "507f1f77bcf86cd799439011" }, "b": { "$oid": "507f1f77bcf86cd799439011" } } }"#)
        #expect(try json(#"db.t.find({a: NumberDecimal("12.50"), b: NumberDecimal(0.1), c: NumberLong(42), d: NumberLong("-9223372036854775808")})"#)
            == #"{ "collection": "t", "operation": "find", "filter": { "a": { "$numberDecimal": "12.50" }, "b": { "$numberDecimal": "0.1" }, "c": { "$numberLong": "42" }, "d": { "$numberLong": "-9223372036854775808" } } }"#)
    }

    @Test(arguments: [
        ("2026-01-01", #"{ "$date": "2026-01-01T00:00:00Z" }"#),
        ("2026-03-01T09:30", #"{ "$date": "2026-03-01T09:30:00Z" }"#),
        ("2026-03-01T09:30:15Z", #"{ "$date": "2026-03-01T09:30:15Z" }"#),
        ("2026-03-01 09:30:15.250", #"{ "$date": "2026-03-01T09:30:15.250Z" }"#),
        ("2026-03-01T09:30:00+02:00", #"{ "$date": "2026-03-01T07:30:00Z" }"#),
        ("2026-03-01T00:30:00-0130", #"{ "$date": "2026-03-01T02:00:00Z" }"#),
        ("1969-12-31T23:59:59Z", #"{ "$date": { "$numberLong": "-1000" } }"#),
    ])
    func isoDates(text: String, expected: String) throws {
        let translation = try MongoShell.translate("db.t.find({at: ISODate('\(text)')})")
        #expect(translation.json["filter"]?["at"]?.inline == expected)
    }

    @Test func translatedQueriesPassTheJSONFormsChecks() throws {
        let query = try MongoQuery(tabText: #"  db.orders.find({placed_at: {$gte: ISODate("2026-01-01")}}).sort({placed_at: -1}).limit(20)  "#)
        #expect(query.operation == "find")
        #expect(query.collection == "orders")
        #expect(query.effect == .read)
        #expect(query.mongosh == #"db.orders.find({placed_at: {$gte: ISODate("2026-01-01")}}).sort({placed_at: -1}).limit(20)"#)
        // The JSON that runs is the translation, and reads back as the same query.
        #expect(try MongoQuery(query.json).json == query.json)
        #expect(query.json.hasPrefix("{\n  \"collection\": \"orders\",\n  \"operation\": \"find\""))

        let json = try MongoQuery(tabText: #"{"collection": "orders", "operation": "find"}"#)
        #expect(json.mongosh == nil)
        #expect(json.json == #"{"collection": "orders", "operation": "find"}"#)
    }

    @Test func translatedWritesAreClassifiedLikeTheJSONForm() throws {
        #expect(try MongoQuery(tabText: "db.orders.insertOne({a: 1})").effect == .write)
        #expect(try MongoQuery(tabText: "db.orders.deleteOne({})").effect == .destructive)
        #expect(try MongoQuery(tabText: "db.orders.deleteOne({status: 'x'})").effect == .write)
        #expect(try MongoQuery(tabText: "db.orders.deleteMany({status: 'x'})").effect == .write)
        #expect(try MongoQuery(tabText: "db.orders.deleteMany({})").effect == .destructive)
        #expect(try MongoQuery(tabText: "db.orders.updateMany({}, {$set: {a: 1}})").effect == .destructive)
        #expect(try MongoQuery(tabText: "db.orders.aggregate([{$match: {}}, {$out: 'export'}])").effect == .write)
        let danger = try #require(DatabaseDangerConfirmation.mongo(try MongoQuery(tabText: "db.orders.deleteMany({})"), line: 1, database: "shop", connection: "the default connection", tabId: UUID(), perform: {}))
        #expect(danger.items[0].text == #"{ "collection": "orders", "operation": "deleteMany", "filter": {} }"#)
    }

    @Test func theJSONFormsOwnChecksStillApply() {
        #expect(throws: MongoQuery.Invalid.self) { try MongoQuery(tabText: "db.orders.find().limit(2000000)") }
        #expect(throws: MongoQuery.Invalid.self) { try MongoQuery(tabText: "db.getCollection('system.users').find()") }
        #expect(throws: MongoQuery.Invalid.self) { try MongoQuery(tabText: "db.orders.insertMany([])") }
        #expect(throws: MongoQuery.Invalid.self) { try MongoQuery(tabText: "db.orders.find({url: 'mongodb://alice:secret@db.example.com'})") }
    }

    // MARK: Which form

    @Test(arguments: [
        ("db.orders.find()", true),
        ("  \n// paid\ndb.orders.find()", true),
        ("use shop", true),
        (#"{"collection": "orders", "operation": "find"}"#, false),
        ("\n\n  {\"collection\": \"orders\"}", false),
        ("// a JSON query\n{\"collection\": \"orders\"}", false),
        ("", false),
        ("   \n", false),
        ("/* never closed", true),
    ])
    func isShell(text: String, expected: Bool) {
        #expect(MongoShell.isShell(text) == expected)
    }

    // MARK: Refusals

    @Test(arguments: [
        // Other calls and JavaScript.
        ("db.t.find({a: Date()})", "Date() isn't supported: write dates as ISODate"),
        ("db.t.find({a: new Date('2026-01-01')})", "Date() isn't supported"),
        ("db.t.find({a: foo()})", "foo() isn't supported: Runlet translates only ObjectId, ISODate, NumberDecimal, and NumberLong"),
        ("db.t.find({a: NumberInt(5)})", "NumberInt() isn't supported"),
        ("db.t.find({a: Math.max(1, 2)})", "“Math” is a variable"),
        ("db.t.find({a: paid})", "“paid” is a variable, and Runlet doesn't evaluate JavaScript. Quote text: \"paid\"."),
        ("db.t.find(filter)", "“filter” is a variable"),
        ("db.t.find({a: function () { return 1 }})", "Functions aren't supported"),
        ("db.t.find({a: undefined})", "undefined isn't a value MongoDB stores"),
        ("db.t.find({a: NaN})", "{$numberDouble: \"NaN\"}"),
        ("db.t.find({a: 1 + 2})", "Unexpected “+”"),
        ("db.t.find({a: /^INV-/i})", "Regular expression literals aren't supported: write {$regex:"),
        ("db.t.find({a: `x`})", "Template strings"),
        ("db.t.find({...base})", "Spread syntax"),
        ("db.t.find({status})", "“status” needs a value"),
        ("db.t.find({[key]: 1})", "Computed keys aren't supported"),
        ("db.t.find({customer.city: 'Oslo'})", "Quote a key with a dot"),
        ("db.t.find({a: 1, a: 2})", "“a” is in this object twice"),
        ("db.t.find({a: [1,,2]})", "Empty array elements"),
        ("db.t.find({a: 0x1F})", "Write numbers in decimal"),
        ("db.t.find({a: 007})", "A number can't start with 0"),
        ("db.t.find({a: 1_000})", "isn't a number Runlet can read"),
        ("db.t.find({a: 'unclosed})", "This string isn't closed"),
        ("db.t.find({a: '\\d'})", "isn't an escape Runlet knows"),
        // Server-side JavaScript.
        ("db.t.find({$where: 'this.a > 1'})", "$where runs JavaScript on the server, which MongoDB tabs don't support: use $expr"),
        ("db.t.aggregate([{$addFields: {x: {$function: {body: 'f', args: [], lang: 'js'}}}}])", "$function runs JavaScript on the server"),
        ("db.t.aggregate([{$group: {_id: 1, x: {$accumulator: {}}}}])", "$accumulator runs JavaScript"),
        // Statements and methods.
        ("use shop", "“use” isn't supported"),
        ("const x = 1", "A mongosh query starts with db.<collection>"),
        ("db.orders", "Call a method on the collection"),
        ("db.orders.find", "Call a method on the collection"),
        ("db['orders'].find()", "db.getCollection"),
        ("db.orders.find(); db.orders.find()", "Only one query runs at a time"),
        ("db.orders.find()\ndb.orders.countDocuments()", "Only one query runs at a time"),
        ("db.orders.find()[0]", "Unexpected “[” after the query"),
        ("db.dropDatabase()", "Name the database, so Runlet can check it's the connection's: db.getSiblingDB(\"shop\").dropDatabase()."),
        ("db.find({})", "find() is a collection's method"),
        // Arguments and chains.
        ("db.orders.find('paid')", "find's filter is an object"),
        ("db.orders.find().limit(5).limit(6)", "limit is given twice: keep one."),
        ("db.orders.find({}, {}, {limit: 5}).limit(6)", "limit is given twice"),
        ("db.orders.find({}, {a: 1}, {projection: {b: 1}})", "projection is given twice"),
        ("db.orders.find().limit(-1)", ".limit() takes a whole number from 0"),
        ("db.orders.find().skip(1.5)", ".skip() takes a whole number from 0"),
        ("db.orders.find().sort('a')", ".sort() takes an object"),
        ("db.orders.find().size", "Properties aren't supported"),
        ("db.orders.aggregate([{$match: {}}]).limit(5)", ".limit() isn't supported after aggregate(): put it in the pipeline"),
        ("db.orders.aggregate({$match: {}})", "aggregate takes one array of stages"),
        ("db.orders.aggregate([1])", "Each stage of the pipeline is an object"),
        ("db.orders.distinct()", "distinct needs a field's name"),
        ("db.orders.distinct(5)", "distinct's first argument is a field's name in quotes"),
        ("db.orders.insertOne()", "insertOne takes one document"),
        ("db.orders.insertMany({a: 1})", "insertMany takes an array of documents"),
        ("db.orders.updateOne({a: 1})", "updateOne takes a filter and an update"),
        ("db.orders.deleteMany()", "deleteMany needs a filter, as in deleteMany({status: \"cancelled\"}); {} matches every document."),
        // Constructors.
        ("db.t.find({_id: ObjectId()})", "ObjectId() needs a value"),
        ("db.t.find({_id: ObjectId('123')})", "ObjectId takes 24 hexadecimal digits"),
        ("db.t.find({at: ISODate()})", "ISODate() needs a value"),
        ("db.t.find({at: ISODate('yesterday')})", "ISODate takes a date in quotes"),
        ("db.t.find({at: ISODate('2026-02-30')})", "ISODate takes a date in quotes"),
        ("db.t.find({n: NumberLong(1.5)})", "NumberLong takes a whole number"),
        ("db.t.find({n: NumberLong('9223372036854775808')})", "NumberLong takes a whole number"),
        ("db.t.find({n: NumberDecimal('twelve')})", "NumberDecimal takes a decimal number"),
        ("db.t.find({n: NumberDecimal('1', '2')})", "NumberDecimal takes one value"),
        // Options and cursor methods Runlet never takes.
        ("db.orders.find().comment('x')", ".comment(): Runlet sets each operation's comment itself, so Stop can find it"),
        ("db.orders.find({}, {}, {comment: 'x'})", "find's option comment: Runlet sets each operation's comment itself"),
        ("db.orders.find({}, {}, {noCursorTimeout: true})", "find's option noCursorTimeout isn't supported. It takes allowDiskUse, collation, hint, limit, maxTimeMS, projection, skip, sort."),
        ("db.orders.find({}, {}, {limit: -1})", "find's option limit is a whole number from 0."),
        ("db.orders.insertOne({a: 1}, {writeConcern: {w: 1}})", "Runlet writes with the connection's write concern"),
        ("db.orders.aggregate([], {let: {x: 1}})", "let isn't supported: write the values into the query."),
        ("db.orders.updateOne({a: 1}, {$set: {b: 1}}, {session: 1})", "Sessions and transactions aren't supported."),
        ("db.orders.find().forEach()", ".forEach() runs JavaScript, which MongoDB tabs never run"),
        ("db.orders.find().readPref('secondary')", ".readPref() isn't supported after find(): use .sort(), .skip(), .limit(), .collation(), .hint(), .maxTimeMS(), .allowDiskUse(), or .explain()."),
        ("db.orders.find().skip(5).count()", "count() ignores skip, as in mongosh: write countDocuments(filter, {skip: …, limit: …})"),
        ("db.orders.find().count(true)", "count() takes no arguments here"),
        ("db.orders.find().explain('verbose')", "explain takes queryPlanner, executionStats, or allPlansExecution."),
        ("db.orders.find().explain().explain()", "explain is given twice"),
        ("db.orders.explain().countDocuments({})", "explain() goes before find() or aggregate()"),
        ("db.orders.findOne({}).pretty()", ".pretty() works after find() and aggregate() only."),
        ("db.orders.updateOne({a: 1}, {b: 2})", "updateOne's update uses update operators, as in {$set: {status: \"paid\"}}. To replace the whole document, use replaceOne."),
        ("db.orders.updateOne({a: 1}, [])", "An update pipeline is an array of stages"),
        ("db.orders.replaceOne({a: 1}, {$set: {b: 2}})", "replaceOne's replacement is a whole document, without update operators"),
        ("db.orders.update({a: 1}, {b: 2}, {multi: true})", "A replacement document can't update several documents"),
        ("db.orders.update({a: 1}, {$set: {b: 2}}, true, true)", "write the options as an object, such as {upsert: true, multi: true}"),
        ("db.orders.remove()", "remove needs a filter"),
        ("db.orders.findOneAndUpdate({a: 1}, {$set: {b: 1}}, {returnDocument: 'new'})", "findOneAndUpdate's option returnDocument is \"before\" or \"after\"."),
        ("db.orders.findOneAndUpdate({a: 1}, {$set: {b: 1}}, {returnDocument: 'after', returnNewDocument: true})", "Give returnDocument or returnNewDocument, not both."),
        ("db.orders.findOneAndReplace({a: 1}, {b: 1}, {arrayFilters: []})", "findOneAndReplace's option arrayFilters isn't supported."),
        ("db.orders.findOneAndDelete()", "findOneAndDelete needs a filter"),
        ("db.orders.bulkWrite([])", "bulkWrite takes an array of operations"),
        ("db.orders.bulkWrite([{insertMany: {documents: []}}])", "bulkWrite takes insertOne, updateOne, updateMany, replaceOne, deleteOne, and deleteMany, not insertMany."),
        ("db.orders.bulkWrite([{updateOne: {filter: {}, update: {b: 1}}}])", "bulkWrite's updateOne's update uses update operators"),
        ("db.orders.bulkWrite([{deleteOne: {}}])", "bulkWrite's deleteOne takes {filter: {…}}"),
        ("db.orders.bulkWrite([{insertOne: {document: {a: 1}, writeConcern: {}}}])", "bulkWrite's insertOne: Runlet writes with the connection's write concern"),
        ("db.orders.createIndex({a: 1}, {unique: true}, 'majority')", "commitQuorum isn't supported"),
        ("db.orders.createIndex({a: true})", "An index's keys are 1, -1, or a kind such as \"text\" or \"2dsphere\": a isn't."),
        ("db.orders.createIndex({})", "createIndex takes the index's keys"),
        ("db.orders.createIndex({a: 1}, {storageEngine: {}})", "createIndex's option storageEngine isn't supported."),
        ("db.orders.createIndexes([{a: 1}, {b: 1}], {name: 'x'})", "One name can't name several indexes"),
        ("db.orders.dropIndex('*')", "dropIndex drops one index: use dropIndexes() for all of them."),
        ("db.orders.dropIndexes(5)", "dropIndexes takes nothing (every index but _id's), an index's name, or an array of names."),
        ("db.orders.renameCollection('x', 'yes')", "renameCollection's dropTarget is true or false."),
        ("db.orders.stats(1024)", "stats() takes no options in Runlet"),
        ("db.orders.ensureIndex({a: 1})", "ensureIndex() was removed from mongosh: use createIndex()."),
        ("db.orders.mapReduce()", "mapReduce runs JavaScript"),
        ("db.eval('1')", "db.eval() runs JavaScript"),
        ("db.stats(1024)", "db.stats() takes no options in Runlet"),
        ("db.getCollectionInfos({name: 'x'})", "takes no filter in Runlet"),
        ("db.getName()", "db.getName() isn't supported. On the database, Runlet runs getCollectionNames"),
        ("db.runCommand({find: 'orders'})", "runCommand runs only commands that read: buildInfo, collStats, connectionStatus, dbStats, hello, isMaster, listCommands, ping, serverStatus, and listDatabases. For find, use db.<collection>.find(…)."),
        ("db.adminCommand({shutdown: 1})", "adminCommand runs only commands that read"),
        ("db.runCommand({ping: 1, comment: 'x'})", "ping's field comment isn't supported here."),
        ("db.runCommand({listDatabases: 1, nameOnly: true})", "listDatabases takes no options in Runlet."),
        ("db.getSiblingDB('other').orders.find()", "getSiblingDB works only as db.getSiblingDB(\"other\").dropDatabase()"),
        ("db.getSiblingDB('other').dropDatabase(1)", "dropDatabase() takes no arguments."),
        ("show users", "show users isn't supported: show takes collections, tables, dbs, or databases."),
        ("show collections; show dbs", "Only one query runs at a time"),
        // Unclosed.
        ("db.t.find({a: 1)", "Expected “,” or “}”"),
        ("db.t.find({a: [1, 2})", "Expected “,” or “]”"),
        ("db.t.find({a: 1}", "This call isn't closed with “)”"),
        ("db.t.find({a: 1", "This object isn't closed with “}”"),
        ("db.t.find({a: 1}) /* never", "This comment isn't closed"),
        ("// only a comment", "Enter a query"),
    ])
    func refusals(text: String, message: String) throws {
        let problem = try #require(self.problem(text), "\(text) was translated")
        #expect(problem.message.contains(message), "\(text): \(problem.message)")
    }

    @Test func problemsSayWhere() throws {
        let problem = try #require(self.problem("""
            db.orders.find({
              status: "paid",
              $where: "this.total > 10"
            })
            """))
        #expect(problem.line == 3)
        #expect(problem.column == 3)
        #expect(problem.errorDescription?.hasPrefix("Line 3, column 3: $where runs JavaScript") == true)
        let call = try #require(self.problem("db.orders.find({at: Date()})"))
        #expect((call.line, call.column) == (1, 21))
        // Run Selection: a selection that starts on line 4, column 9 of the tab.
        #expect(call.offset(line: 4, column: 9) == MongoShell.Problem(message: call.message, line: 4, column: 29))
        let second = try #require(self.problem("db.a.find({\n b: x })"))
        #expect(second.offset(line: 4, column: 9) == MongoShell.Problem(message: second.message, line: 5, column: 5))
    }

    @Test func firstLineSkipsComments() {
        #expect(MongoShell.firstLine("// Everything\n/* the danger\nsheet asks */\n\n  db.orders.deleteMany({})") == 5)
        #expect(MongoShell.firstLine("db.orders.find()") == 1)
        #expect(MongoShell.firstLine("   ") == 1)
    }

    @Test func aRefusalNeverRunsAnything() throws {
        // A refused query is an error from MongoQuery(tabText:), so the app never builds a run.
        #expect(throws: MongoShell.Problem.self) { try MongoQuery(tabText: "db.orders.find({$where: 'sleep(1000)'})") }
        #expect(throws: MongoShell.Problem.self) { try MongoQuery(tabText: "db.orders.find({}); db.orders.drop()") }
    }
    // MARK: Snippets and the query builder

    @Test func snippetInputsFillMongoshPlaceholders() throws {
        let code = """
            // @title Customer's orders
            // @input string $customer "Customer" = "Customer 3"
            // @input int $limit "How many" = 10
            db.orders.find({
              'customer.name': {$input: 'customer'},
              note: '{"$input": "customer"}',  // a placeholder inside a string stays text
              /* {$input: "limit"} in a comment stays too */
              status: "paid",
            }).limit({"$input": "limit"})
            """
        let filled = MongoSnippets.substitute(code, values: ["customer": .string("O'Brien \"Co\""), "limit": .int(5)])
        #expect(filled.contains(#"'customer.name': "O'Brien \"Co\"","#), "\(filled)")
        #expect(filled.contains(#"note: '{"$input": "customer"}',"#))
        #expect(filled.contains(#"/* {$input: "limit"} in a comment stays too */"#))
        #expect(filled.hasSuffix(".limit(5)"))
        let query = try MongoQuery(tabText: MongoSnippets.parse(filled).body)
        #expect(query.json.contains(#""customer.name": "O'Brien \"Co\"""#))
        #expect(query.json.contains(#""limit": 5"#))
    }

    @Test func theQueryBuilderSkipsMongoshArguments() {
        // A mongosh query's objects are its arguments, not JSON queries the builder may rewrite.
        #expect(MongoBuilderText.blocks(in: #"db.orders.find({status: "paid"}, {total: 1}).sort({total: -1})"#).isEmpty)
        #expect(MongoBuilderText.blocks(in: "db.orders.find({a: ')', b: \"(\", c: `)`}) // )\n/* ( */").isEmpty)
        let text = "db.orders.find({a: 1})\n\n{\"collection\": \"orders\", \"operation\": \"find\"}\n"
        let blocks = MongoBuilderText.blocks(in: text)
        #expect(blocks.count == 1)
        #expect((text as NSString).substring(with: blocks[0].range).hasPrefix("{\"collection\""))
        #expect(MongoBuilderText.target(in: "db.orders.find({a: 1})", selection: NSRange(location: 17, length: 0)) == .none)
        // An unclosed call hides nothing after it from the JSON queries before it.
        #expect(MongoBuilderText.blocks(in: "{\"a\": 1}\ndb.orders.find({").count == 1)
    }
}
