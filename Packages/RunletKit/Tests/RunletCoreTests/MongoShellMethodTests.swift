import Foundation
@testable import RunletCore
import Testing

/// #220, the owner's "as feature rich as possible": every method and option of the grown
/// mongosh subset, as the JSON it becomes, how Runlet classifies it (read, write, destructive),
/// and what the danger sheet says.
struct MongoShellMethodTests {
    private func json(_ text: String) throws -> String {
        try MongoShell.translate(text).json.inline
    }

    private func query(_ text: String) throws -> MongoQuery {
        try MongoQuery(tabText: text)
    }

    // MARK: Reads

    @Test func findOptionsAndCursorMethods() throws {
        #expect(try json("db.orders.findOne({status: 'paid'}, {total: 1}, {sort: {placed_at: -1}, maxTimeMS: 500})")
            == #"{ "collection": "orders", "operation": "findOne", "filter": { "status": "paid" }, "projection": { "total": 1 }, "sort": { "placed_at": -1 }, "maxTimeMS": 500 }"#)
        #expect(try json("db.orders.find({}, {}, {sort: {n: 1}, skip: 5, limit: 10, collation: {locale: 'en', strength: 2}, hint: 'n_1', maxTimeMS: 1000, allowDiskUse: true, batchSize: 50})")
            == #"{ "collection": "orders", "operation": "find", "filter": {}, "projection": {}, "sort": { "n": 1 }, "skip": 5, "limit": 10, "collation": { "locale": "en", "strength": 2 }, "hint": "n_1", "maxTimeMS": 1000, "allowDiskUse": true }"#)
        #expect(try json("db.orders.find({a: 1}).collation({locale: 'fr'}).hint({a: 1}).maxTimeMS(2000).allowDiskUse().batchSize(10).pretty().toArray()")
            == #"{ "collection": "orders", "operation": "find", "filter": { "a": 1 }, "collation": { "locale": "fr" }, "hint": { "a": 1 }, "maxTimeMS": 2000, "allowDiskUse": true }"#)
        #expect(try json("db.orders.find().allowDiskUse(false)") == #"{ "collection": "orders", "operation": "find", "allowDiskUse": false }"#)
    }

    @Test(arguments: [
        ("db.orders.find({a: 1}).explain()", #""explain": true"#),
        ("db.orders.find({a: 1}).explain('executionStats')", #""explain": "executionStats""#),
        ("db.orders.find({a: 1}).explain(true)", #""explain": "allPlansExecution""#),
        ("db.orders.explain().find({a: 1})", #""explain": true"#),
        ("db.orders.explain('queryPlanner').find({a: 1}).limit(5)", #""limit": 5, "explain": "queryPlanner""#),
        ("db.orders.aggregate([{$match: {a: 1}}]).explain('executionStats')", #""explain": "executionStats""#),
        ("db.orders.aggregate([{$match: {a: 1}}], {explain: true})", #""explain": true"#),
        ("db.orders.explain().aggregate([{$match: {a: 1}}])", #""explain": true"#),
    ])
    func explain(text: String, expected: String) throws {
        let translated = try json(text)
        #expect(translated.contains(expected), "\(translated)")
        #expect(try query(text).effect == .read)
    }

    @Test func aggregateOptionsAndNoOps() throws {
        #expect(try json("db.orders.aggregate([{$match: {a: 1}}], {allowDiskUse: true, collation: {locale: 'en'}, hint: 'a_1', maxTimeMS: 100, batchSize: 5, cursor: {}}).pretty().toArray()")
            == #"{ "collection": "orders", "operation": "aggregate", "pipeline": [{ "$match": { "a": 1 } }], "collation": { "locale": "en" }, "hint": "a_1", "maxTimeMS": 100, "allowDiskUse": true }"#)
        #expect(try json("db.orders.aggregate([], {explain: false})") == #"{ "collection": "orders", "operation": "aggregate", "pipeline": [] }"#)
    }

    @Test func counts() throws {
        #expect(try json("db.orders.count({status: 'paid'})") == #"{ "collection": "orders", "operation": "countDocuments", "filter": { "status": "paid" } }"#)
        #expect(try json("db.orders.count()") == #"{ "collection": "orders", "operation": "countDocuments" }"#)
        #expect(try json("db.orders.countDocuments({a: 1}, {hint: 'a_1', maxTimeMS: 50})")
            == #"{ "collection": "orders", "operation": "countDocuments", "filter": { "a": 1 }, "hint": "a_1", "maxTimeMS": 50 }"#)
        // skip and limit count part of the matches: the aggregation drivers run.
        #expect(try json("db.orders.countDocuments({a: 1}, {skip: 10, limit: 5, collation: {locale: 'en'}})")
            == #"{ "collection": "orders", "operation": "aggregate", "pipeline": [{ "$match": { "a": 1 } }, { "$skip": 10 }, { "$limit": 5 }, { "$count": "count" }], "collation": { "locale": "en" } }"#)
        #expect(try json("db.orders.countDocuments({}, {limit: 3})")
            == #"{ "collection": "orders", "operation": "aggregate", "pipeline": [{ "$match": {} }, { "$limit": 3 }, { "$count": "count" }] }"#)
        // find(…).count() counts the find's matches; sort and the projection don't change a count.
        #expect(try json("db.orders.find({status: 'paid'}, {total: 1}).sort({n: 1}).hint({status: 1}).count()")
            == #"{ "collection": "orders", "operation": "countDocuments", "filter": { "status": "paid" }, "hint": { "status": 1 } }"#)
        #expect(try json("db.orders.estimatedDocumentCount()") == #"{ "collection": "orders", "operation": "estimatedDocumentCount" }"#)
        #expect(try json("db.orders.estimatedDocumentCount({maxTimeMS: 100})") == #"{ "collection": "orders", "operation": "estimatedDocumentCount", "maxTimeMS": 100 }"#)
        #expect(try json("db.orders.distinct('city', {}, {collation: {locale: 'en', strength: 1}})")
            == #"{ "collection": "orders", "operation": "distinct", "field": "city", "filter": {}, "collation": { "locale": "en", "strength": 1 } }"#)
        for text in ["db.orders.count()", "db.orders.estimatedDocumentCount()", "db.orders.countDocuments({}, {limit: 3})", "db.orders.find().count()"] {
            #expect(try query(text).effect == .read, "\(text)")
        }
    }

    @Test func metadataReads() throws {
        #expect(try json("db.orders.getIndexes()") == #"{ "collection": "orders", "operation": "getIndexes" }"#)
        #expect(try json("db.orders.stats()") == #"{ "collection": "orders", "operation": "collStats" }"#)
        let metadata = [
            ("show collections", #"{ "collection": "metadata", "operation": "listCollections" }"#),
            ("show tables;", #"{ "collection": "metadata", "operation": "listCollections" }"#),
            ("show dbs", #"{ "collection": "metadata", "operation": "listDatabases" }"#),
            ("show databases", #"{ "collection": "metadata", "operation": "listDatabases" }"#),
            ("db.getCollectionNames()", #"{ "collection": "metadata", "operation": "listCollections" }"#),
            ("db.getCollectionInfos()", #"{ "collection": "metadata", "operation": "listCollections" }"#),
            ("db.stats()", #"{ "collection": "metadata", "operation": "dbStats" }"#),
            ("db.serverStatus()", #"{ "collection": "metadata", "operation": "runCommand", "command": { "serverStatus": 1 } }"#),
            ("db.version()", #"{ "collection": "metadata", "operation": "runCommand", "command": { "buildInfo": 1 } }"#),
            ("db.hello()", #"{ "collection": "metadata", "operation": "runCommand", "command": { "hello": 1 } }"#),
            ("db.isMaster()", #"{ "collection": "metadata", "operation": "runCommand", "command": { "isMaster": 1 } }"#),
            ("db.runCommand({ping: 1})", #"{ "collection": "metadata", "operation": "runCommand", "command": { "ping": 1 } }"#),
            ("db.runCommand('buildInfo')", #"{ "collection": "metadata", "operation": "runCommand", "command": { "buildInfo": 1 } }"#),
            ("db.runCommand({collStats: 'orders', scale: 1024})", #"{ "collection": "metadata", "operation": "runCommand", "command": { "collStats": "orders", "scale": 1024 } }"#),
            ("db.adminCommand({listDatabases: 1})", #"{ "collection": "metadata", "operation": "listDatabases" }"#),
            ("db.adminCommand({serverStatus: 1, repl: 0})", #"{ "collection": "metadata", "operation": "runCommand", "command": { "serverStatus": 1, "repl": 0 } }"#),
        ]
        for (text, expected) in metadata {
            #expect(try json(text) == expected, "\(text)")
            #expect(try query(text).effect == .read, "\(text)")
        }
        #expect(try query("db.orders.getIndexes()").effect == .read)
        #expect(try query("db.orders.stats()").effect == .read)
    }

    // MARK: Writes

    @Test func insertsAndLegacyInsert() throws {
        #expect(try json("db.orders.insertMany([{a: 1}, {a: 2}], {ordered: false})")
            == #"{ "collection": "orders", "operation": "insertMany", "documents": [{ "a": 1 }, { "a": 2 }], "ordered": false }"#)
        #expect(try json("db.orders.insert({a: 1})") == #"{ "collection": "orders", "operation": "insertOne", "documents": [{ "a": 1 }] }"#)
        #expect(try json("db.orders.insert([{a: 1}, {a: 2}], {ordered: true})")
            == #"{ "collection": "orders", "operation": "insertMany", "documents": [{ "a": 1 }, { "a": 2 }], "ordered": true }"#)
        #expect(try query("db.orders.insert({a: 1})").effect == .write)
    }

    @Test func updatesWithOptionsAndPipelines() throws {
        #expect(try json("db.orders.updateOne({_id: 1}, {$set: {status: 'paid'}}, {upsert: true})")
            == #"{ "collection": "orders", "operation": "updateOne", "filter": { "_id": 1 }, "update": { "$set": { "status": "paid" } }, "upsert": true }"#)
        #expect(try json("db.orders.updateMany({status: 'paid'}, {$set: {'items.$[i].shipped': true}}, {arrayFilters: [{'i.qty': {$gt: 0}}], collation: {locale: 'en'}, hint: {status: 1}})")
            == #"{ "collection": "orders", "operation": "updateMany", "filter": { "status": "paid" }, "update": { "$set": { "items.$[i].shipped": true } }, "arrayFilters": [{ "i.qty": { "$gt": 0 } }], "collation": { "locale": "en" }, "hint": { "status": 1 } }"#)
        #expect(try json("db.orders.updateOne({_id: 1}, [{$set: {total: {$add: ['$subtotal', '$tax']}}}])")
            == #"{ "collection": "orders", "operation": "updateOne", "filter": { "_id": 1 }, "update": [{ "$set": { "total": { "$add": ["$subtotal", "$tax"] } } }] }"#)
        #expect(try query("db.orders.updateOne({_id: 1}, [{$set: {total: 1}}])").effect == .write)
        #expect(try query("db.orders.updateOne({}, {$set: {a: 1}}, {upsert: true})").effect == .write)
        #expect(try query("db.orders.updateMany({}, [{$set: {a: 1}}])").effect == .destructive)
    }

    @Test func legacyUpdateAndRemove() throws {
        #expect(try json("db.orders.update({a: 1}, {$inc: {n: 1}})") == #"{ "collection": "orders", "operation": "updateOne", "filter": { "a": 1 }, "update": { "$inc": { "n": 1 } } }"#)
        #expect(try json("db.orders.update({a: 1}, {$inc: {n: 1}}, {multi: true, upsert: true})")
            == #"{ "collection": "orders", "operation": "updateMany", "filter": { "a": 1 }, "update": { "$inc": { "n": 1 } }, "upsert": true }"#)
        // A document without operators replaces the match, as the mongo shell's update() did.
        #expect(try json("db.orders.update({a: 1}, {a: 1, b: 2})") == #"{ "collection": "orders", "operation": "replaceOne", "filter": { "a": 1 }, "replacement": { "a": 1, "b": 2 } }"#)
        #expect(try json("db.orders.remove({status: 'void'})") == #"{ "collection": "orders", "operation": "deleteMany", "filter": { "status": "void" } }"#)
        #expect(try json("db.orders.remove({status: 'void'}, true)") == #"{ "collection": "orders", "operation": "deleteOne", "filter": { "status": "void" } }"#)
        #expect(try json("db.orders.remove({status: 'void'}, {justOne: true, collation: {locale: 'en'}})")
            == #"{ "collection": "orders", "operation": "deleteOne", "filter": { "status": "void" }, "collation": { "locale": "en" } }"#)
        #expect(try query("db.orders.remove({})").effect == .destructive)
        #expect(try query("db.orders.remove({}, true)").effect == .destructive)
        #expect(try query("db.orders.update({}, {a: 1})").effect == .destructive)
    }

    @Test func replaceAndDeleteOptions() throws {
        #expect(try json("db.orders.replaceOne({_id: 7}, {name: 'Gear', price: 4}, {upsert: true, hint: '_id_'})")
            == #"{ "collection": "orders", "operation": "replaceOne", "filter": { "_id": 7 }, "replacement": { "name": "Gear", "price": 4 }, "upsert": true, "hint": "_id_" }"#)
        #expect(try json("db.orders.deleteOne({a: 1}, {collation: {locale: 'en'}, hint: {a: 1}})")
            == #"{ "collection": "orders", "operation": "deleteOne", "filter": { "a": 1 }, "collation": { "locale": "en" }, "hint": { "a": 1 } }"#)
        #expect(try query("db.orders.replaceOne({_id: 7}, {a: 1})").effect == .write)
        #expect(try query("db.orders.replaceOne({}, {a: 1})").effect == .destructive)
        #expect(try query("db.orders.deleteOne({a: 1})").effect == .write)
        #expect(try query("db.orders.deleteOne({})").effect == .destructive)
    }

    @Test func findOneAndModify() throws {
        #expect(try json("db.orders.findOneAndUpdate({status: 'new'}, {$set: {status: 'picked'}}, {sort: {placed_at: 1}, projection: {n: 1}, returnNewDocument: true, upsert: true})")
            == #"{ "collection": "orders", "operation": "findOneAndUpdate", "filter": { "status": "new" }, "projection": { "n": 1 }, "sort": { "placed_at": 1 }, "update": { "$set": { "status": "picked" } }, "upsert": true, "returnDocument": "after" }"#)
        #expect(try json("db.orders.findOneAndUpdate({a: 1}, {$inc: {n: 1}}, {returnNewDocument: false, arrayFilters: [], maxTimeMS: 10})")
            == #"{ "collection": "orders", "operation": "findOneAndUpdate", "filter": { "a": 1 }, "update": { "$inc": { "n": 1 } }, "returnDocument": "before", "arrayFilters": [], "maxTimeMS": 10 }"#)
        #expect(try json("db.orders.findOneAndReplace({a: 1}, {a: 1, b: 2}, {returnDocument: 'after', collation: {locale: 'en'}})")
            == #"{ "collection": "orders", "operation": "findOneAndReplace", "filter": { "a": 1 }, "replacement": { "a": 1, "b": 2 }, "returnDocument": "after", "collation": { "locale": "en" } }"#)
        #expect(try json("db.orders.findOneAndDelete({status: 'void'}, {sort: {placed_at: 1}})")
            == #"{ "collection": "orders", "operation": "findOneAndDelete", "filter": { "status": "void" }, "sort": { "placed_at": 1 } }"#)
        #expect(try query("db.orders.findOneAndUpdate({}, {$set: {a: 1}})").effect == .write)
        #expect(try query("db.orders.findOneAndUpdate({a: 1}, [{$set: {a: 2}}])").effect == .write)
        #expect(try query("db.orders.findOneAndReplace({a: 1}, {b: 1})").effect == .write)
        #expect(try query("db.orders.findOneAndReplace({}, {b: 1})").effect == .destructive)
        #expect(try query("db.orders.findOneAndDelete({a: 1})").effect == .write)
        #expect(try query("db.orders.findOneAndDelete({})").effect == .destructive)
    }

    @Test func bulkWrite() throws {
        let text = """
            db.orders.bulkWrite([
              {insertOne: {document: {n: 1}}},
              {updateOne: {filter: {n: 1}, update: {$set: {a: 1}}, upsert: true}},
              {updateMany: {filter: {a: 1}, update: [{$set: {b: 2}}], arrayFilters: [], hint: 'a_1'}},
              {replaceOne: {filter: {n: 2}, replacement: {n: 2, c: 3}, collation: {locale: 'en'}}},
            ], {ordered: false})
            """
        #expect(try json(text) == #"{ "collection": "orders", "operation": "bulkWrite", "operations": [{ "insertOne": { "document": { "n": 1 } } }, { "updateOne": { "filter": { "n": 1 }, "update": { "$set": { "a": 1 } }, "upsert": true } }, { "updateMany": { "filter": { "a": 1 }, "update": [{ "$set": { "b": 2 } }], "arrayFilters": [], "hint": "a_1" } }, { "replaceOne": { "filter": { "n": 2 }, "replacement": { "n": 2, "c": 3 }, "collation": { "locale": "en" } } }], "ordered": false }"#)
        #expect(try query(text).effect == .write)
        // A delete, or an unfiltered updateMany or replaceOne, makes the whole bulkWrite destructive.
        #expect(try query("db.orders.bulkWrite([{insertOne: {document: {n: 1}}}, {deleteOne: {filter: {n: 1}}}])").effect == .destructive)
        #expect(try query("db.orders.bulkWrite([{deleteMany: {filter: {status: 'void'}}}])").effect == .destructive)
        #expect(try query("db.orders.bulkWrite([{updateMany: {filter: {}, update: {$set: {a: 1}}}}])").effect == .destructive)
        #expect(try query("db.orders.bulkWrite([{replaceOne: {filter: {}, replacement: {a: 1}}}])").effect == .destructive)
        #expect(try query("db.orders.bulkWrite([{updateOne: {filter: {}, update: {$set: {a: 1}}}}])").effect == .write)
    }

    // MARK: Indexes and collections

    @Test func indexes() throws {
        #expect(try json("db.orders.createIndex({email: 1}, {unique: true})")
            == #"{ "collection": "orders", "operation": "createIndex", "keys": { "email": 1 }, "options": { "name": "email_1", "unique": true } }"#)
        #expect(try json("db.orders.createIndex({status: 1, placed_at: -1})")
            == #"{ "collection": "orders", "operation": "createIndex", "keys": { "status": 1, "placed_at": -1 }, "options": { "name": "status_1_placed_at_-1" } }"#)
        #expect(try json("db.orders.createIndex({body: 'text'}, {name: 'search', background: true, weights: {body: 2}, default_language: 'english'})")
            == #"{ "collection": "orders", "operation": "createIndex", "keys": { "body": "text" }, "options": { "name": "search", "default_language": "english", "weights": { "body": 2 } } }"#)
        #expect(try json("db.orders.createIndex({at: 1}, {expireAfterSeconds: 3600, partialFilterExpression: {status: 'void'}, sparse: true, hidden: false})")
            == #"{ "collection": "orders", "operation": "createIndex", "keys": { "at": 1 }, "options": { "name": "at_1", "expireAfterSeconds": 3600, "hidden": false, "partialFilterExpression": { "status": "void" }, "sparse": true } }"#)
        #expect(try json("db.orders.createIndexes([{a: 1}, {b: -1, c: 1}], {sparse: true})")
            == #"{ "collection": "orders", "operation": "createIndexes", "indexes": [{ "key": { "a": 1 }, "name": "a_1", "sparse": true }, { "key": { "b": -1, "c": 1 }, "name": "b_-1_c_1", "sparse": true }] }"#)
        #expect(try json("db.orders.dropIndex('email_1')") == #"{ "collection": "orders", "operation": "dropIndex", "index": "email_1" }"#)
        #expect(try json("db.orders.dropIndex({email: 1})") == #"{ "collection": "orders", "operation": "dropIndex", "index": { "email": 1 } }"#)
        #expect(try json("db.orders.dropIndexes()") == #"{ "collection": "orders", "operation": "dropIndexes", "index": "*" }"#)
        #expect(try json("db.orders.dropIndexes('a_1')") == #"{ "collection": "orders", "operation": "dropIndexes", "index": "a_1" }"#)
        #expect(try json("db.orders.dropIndexes(['a_1', 'b_-1'])") == #"{ "collection": "orders", "operation": "dropIndexes", "index": ["a_1", "b_-1"] }"#)
        for text in ["db.orders.createIndex({email: 1})", "db.orders.createIndexes([{a: 1}])"] { #expect(try query(text).effect == .write, "\(text)") }
        for text in ["db.orders.dropIndex('email_1')", "db.orders.dropIndex({email: 1})", "db.orders.dropIndexes()", "db.orders.dropIndexes(['a_1'])"] {
            #expect(try query(text).effect == .destructive, "\(text)")
        }
        #expect(throws: MongoQuery.Invalid.self) { try MongoQuery(tabText: "db.orders.dropIndex('_id_')") }
        #expect(throws: MongoQuery.Invalid.self) { try MongoQuery(tabText: "db.orders.dropIndexes(['a_1', '_id_'])") }
    }

    @Test func collections() throws {
        #expect(try json("db.orders.drop()") == #"{ "collection": "orders", "operation": "drop" }"#)
        #expect(try json("db.orders.renameCollection('orders_2025')") == #"{ "collection": "orders", "operation": "renameCollection", "to": "orders_2025" }"#)
        #expect(try json("db.orders.renameCollection('orders_2025', true)") == #"{ "collection": "orders", "operation": "renameCollection", "to": "orders_2025", "dropTarget": true }"#)
        #expect(try json("db.createCollection('events', {capped: true, size: 1048576, max: 1000, validator: {$jsonSchema: {required: ['at']}}, validationAction: 'warn'})")
            == #"{ "collection": "events", "operation": "createCollection", "options": { "capped": true, "size": 1048576, "max": 1000, "validator": { "$jsonSchema": { "required": ["at"] } }, "validationAction": "warn" } }"#)
        #expect(try json("db.createCollection('events')") == #"{ "collection": "events", "operation": "createCollection" }"#)
        #expect(try json("db.getSiblingDB('shop').dropDatabase()") == #"{ "operation": "dropDatabase", "database": "shop" }"#)
        #expect(try query("db.createCollection('events')").effect == .write)
        for text in ["db.orders.drop()", "db.orders.renameCollection('x')", "db.getSiblingDB('shop').dropDatabase()"] {
            #expect(try query(text).effect == .destructive, "\(text)")
        }
        let dropped = try query("db.getSiblingDB('shop').dropDatabase()")
        #expect(dropped.database == "shop")
        #expect(throws: MongoQuery.Invalid.self) { try MongoQuery(tabText: "db.getSiblingDB('admin').dropDatabase()") }
        #expect(throws: MongoQuery.Invalid.self) { try MongoQuery(tabText: "db.orders.renameCollection('orders')") }
        #expect(throws: MongoQuery.Invalid.self) { try MongoQuery(tabText: "db.orders.renameCollection('system.views')") }
    }

    // MARK: Safety

    /// Each new destructive operation's confirmation names what it does, and shows the JSON.
    @Test(arguments: [
        ("db.orders.dropIndex('email_1')", "dropIndex removes the index “email_1” of “orders”."),
        ("db.orders.dropIndex({email: 1})", "dropIndex removes the index of “orders” on those keys."),
        ("db.orders.dropIndexes()", "dropIndexes removes every index of “orders” except _id's."),
        ("db.orders.dropIndexes(['a_1', 'b_1'])", "dropIndexes removes the indexes “a_1”, “b_1” of “orders”."),
        ("db.orders.renameCollection('orders_2025')", "renameCollection renames “orders” to “orders_2025”; code that uses “orders” won't find it."),
        ("db.orders.renameCollection('archive', true)", "renameCollection renames “orders” to “archive”, and drops an existing “archive” first."),
        ("db.orders.deleteOne({})", "deleteOne has an empty filter: it deletes the first document of “orders” it finds, whichever that is."),
        ("db.orders.replaceOne({}, {a: 1})", "replaceOne has an empty filter: it replaces the first document of “orders” it finds, whichever that is."),
        ("db.orders.findOneAndDelete({})", "findOneAndDelete has an empty filter: it deletes the first document of “orders” it finds, whichever that is."),
        ("db.orders.findOneAndReplace({}, {a: 1})", "findOneAndReplace has an empty filter: it replaces the first document of “orders” it finds, whichever that is."),
        ("db.orders.bulkWrite([{deleteOne: {filter: {a: 1}}}])", "bulkWrite deletes documents of “orders”, or changes them with an empty filter."),
        ("db.orders.remove({})", "deleteMany has an empty filter: it deletes every document of “orders”."),
        ("db.getSiblingDB('shop').dropDatabase()", "dropDatabase removes the database “shop” with all its collections, documents, and indexes."),
    ])
    func dangerSheet(text: String, sentence: String) throws {
        let query = try query(text)
        #expect(query.effect == .destructive)
        let danger = try #require(DatabaseDangerConfirmation.mongo(query, line: 1, database: "shop", connection: "the default connection", tabId: UUID(), perform: {}))
        #expect(danger.items[0].sentence == "Line 1: " + sentence)
        #expect(danger.items[0].text.hasPrefix("{ "))
        #expect(!danger.items[0].text.contains("\n"))
    }

    /// Read-only connections refuse every operation that isn't a read; these are the reads.
    @Test func onlyReadsPassReadOnly() throws {
        let reads = ["db.orders.find()", "db.orders.findOne()", "db.orders.find().explain('executionStats')", "db.orders.count()", "db.orders.estimatedDocumentCount()",
                     "db.orders.distinct('a')", "db.orders.getIndexes()", "db.orders.stats()", "db.stats()", "db.runCommand({ping: 1})", "show dbs", "show collections",
                     "db.orders.aggregate([{$group: {_id: '$a'}}])", "db.orders.countDocuments({}, {limit: 2})"]
        for text in reads { #expect(try query(text).effect == .read, "\(text)") }
        let changes = ["db.orders.insert({a: 1})", "db.orders.update({a: 1}, {$set: {b: 1}})", "db.orders.remove({a: 1})", "db.orders.findOneAndUpdate({a: 1}, {$set: {b: 1}})",
                       "db.orders.findOneAndDelete({a: 1})", "db.orders.bulkWrite([{insertOne: {document: {}}}])", "db.orders.createIndex({a: 1})",
                       "db.orders.createIndexes([{a: 1}])", "db.createCollection('x')", "db.orders.aggregate([{$out: 'copy'}])", "db.orders.dropIndex('a_1')",
                       "db.orders.renameCollection('x')", "db.orders.drop()"]
        for text in changes { #expect(try query(text).effect != .read, "\(text)") }
    }

    @Test func explainIsForReadsOnly() {
        // The JSON form refuses explain on a write, whatever the verbosity.
        #expect(throws: MongoQuery.Invalid.self) { try MongoQuery(#"{"collection": "o", "operation": "aggregate", "pipeline": [{"$out": "x"}], "explain": "executionStats"}"#) }
        #expect(throws: MongoQuery.Invalid.self) { try MongoQuery(tabText: "db.orders.find().maxTimeMS(60000)") }
    }
    /// The JSON form checks the new operations and options itself, written by hand or translated.
    @Test(arguments: [
        #"{"collection":"o","operation":"updateOne","filter":{},"update":{"status":"paid"}}"#,
        #"{"collection":"o","operation":"updateMany","filter":{},"update":[]}"#,
        #"{"collection":"o","operation":"replaceOne","filter":{},"replacement":{"$set":{"a":1}}}"#,
        #"{"collection":"o","operation":"findOneAndUpdate","filter":{}}"#,
        #"{"collection":"o","operation":"findOneAndReplace","filter":{},"replacement":{},"returnDocument":"new"}"#,
        #"{"collection":"o","operation":"find","explain":"verbose"}"#,
        #"{"collection":"o","operation":"find","maxTimeMS":0}"#,
        #"{"collection":"o","operation":"find","hint":""}"#,
        #"{"collection":"o","operation":"countDocuments","skip":1}"#,
        #"{"collection":"o","operation":"createIndex","keys":{"a":1},"options":{"storageEngine":{}}}"#,
        #"{"collection":"o","operation":"createIndex","keys":{"a":1},"unique":true,"options":{"unique":true}}"#,
        #"{"collection":"o","operation":"createIndexes","indexes":[{"key":{"a":1}}]}"#,
        #"{"collection":"o","operation":"createIndexes","indexes":[]}"#,
        #"{"collection":"o","operation":"dropIndex","index":"*"}"#,
        #"{"collection":"o","operation":"dropIndex"}"#,
        #"{"collection":"o","operation":"dropIndexes","index":[]}"#,
        #"{"collection":"o","operation":"renameCollection"}"#,
        #"{"collection":"o","operation":"createCollection","options":{"viewOn":"x"}}"#,
        #"{"collection":"metadata","operation":"runCommand","command":{"drop":"o"}}"#,
        #"{"collection":"metadata","operation":"runCommand","command":{"ping":1,"buildInfo":1}}"#,
        #"{"collection":"metadata","operation":"runCommand","command":{"ping":1,"$db":"admin"}}"#,
        #"{"collection":"o","operation":"bulkWrite","operations":[]}"#,
        #"{"collection":"o","operation":"bulkWrite","operations":[{"insertOne":{"document":{}},"deleteOne":{"filter":{}}}]}"#,
        #"{"collection":"o","operation":"bulkWrite","operations":[{"updateOne":{"filter":{},"update":{"a":1}}}]}"#,
        #"{"collection":"o","operation":"bulkWrite","operations":[{"deleteMany":{}}]}"#,
        #"{"collection":"o","operation":"bulkWrite","operations":[{"insertOne":{"document":{"$where":"1"}}}]}"#,
    ])
    func theJSONFormChecksTheNewOperations(text: String) {
        #expect(throws: MongoQuery.Invalid.self) { try MongoQuery(text) }
    }
}
