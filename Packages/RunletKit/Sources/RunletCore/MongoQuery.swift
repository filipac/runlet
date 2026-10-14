import CoreFoundation
import Foundation

public struct MongoQuery: Sendable, Equatable {
    public enum Effect: String, Sendable { case read, write, destructive }
    public let json: String
    public let operation: String
    public let collection: String
    /// `dropDatabase`'s database (#207): the query names it, and it must be the connection's.
    public let database: String?
    public let effect: Effect
    /// What a destructive operation does (#191), for its confirmation; nil for the others.
    public let danger: String?
    /// The mongosh-like text this query was translated from (#220), trimmed; nil for the JSON
    /// form. `json` is always the JSON form that runs.
    public internal(set) var mongosh: String?

    public struct Invalid: Error, LocalizedError {
        public let errorDescription: String?
        public init(_ message: String) { errorDescription = message }
    }

    public init(_ text: String) throws {
        guard text.utf8.count <= 1_048_576,
              let data = text.data(using: .utf8),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Invalid("Enter one JSON query object with collection, operation, and arguments. Maximum size: 1 MiB.")
        }
        guard Set(document.keys).isSubset(of: Self.allFields) else { throw Invalid("Unknown query field. Connection credentials and arbitrary commands are not query fields.") }
        guard let operation = document["operation"] as? String,
              Self.operations.contains(operation) else { throw Invalid("Choose a supported MongoDB operation.") }
        guard Set(document.keys).isSubset(of: Self.fields(for: operation)) else { throw Invalid("This operation does not support one of the supplied fields.") }
        let collection = document["collection"] as? String ?? ""
        var database: String?
        if operation == "dropDatabase" {
            // #207: no collection; the database is named, and the runner checks it is the connection's.
            guard let name = document["database"] as? String, Self.isValidDatabaseName(name) else {
                throw Invalid("dropDatabase names the connection's database: {\"operation\": \"dropDatabase\", \"database\": \"shop\"}. admin, local and config can't be dropped.")
            }
            database = name
        } else {
            guard Self.isValidCollectionName(collection) else {
                throw Invalid("Enter a collection name (system collections are not supported).")
            }
        }
        for key in ["filter", "projection", "sort", "replacement", "keys", "collation", "options", "command"] where document[key] != nil {
            guard document[key] is [String: Any] else { throw Invalid("\(key) must be a JSON object.") }
        }
        for key in ["skip", "limit"] {
            if let value = document[key] {
                guard Self.isInteger(value, in: 0...1_000_000) else { throw Invalid("\(key) must be an integer from 0 to 1000000.") }
            }
        }
        if let value = document["maxTimeMS"], !Self.isInteger(value, in: 1...25_000) {
            throw Invalid("maxTimeMS must be an integer from 1 to 25000: Runlet stops reads after 25 seconds.")
        }
        for key in ["unique", "upsert", "ordered", "allowDiskUse", "dropTarget"] {
            if let value = document[key], !Self.isBool(value) { throw Invalid("\(key) must be true or false.") }
        }
        // #220: explain is true (queryPlanner) or a verbosity.
        if let value = document["explain"], !Self.isBool(value), !((value as? String).map(Self.explainVerbosities.contains) ?? false) {
            throw Invalid("explain must be true, false, or a verbosity: queryPlanner, executionStats, or allPlansExecution.")
        }
        if let hint = document["hint"], !Self.isHint(hint) { throw Invalid("hint must be an index name or an index's keys object.") }
        if let filters = document["arrayFilters"], !((filters as? [Any])?.allSatisfy { $0 is [String: Any] } ?? false) {
            throw Invalid("arrayFilters must be an array of filter objects.")
        }
        if let value = document["returnDocument"], !["before", "after"].contains(value as? String ?? "") {
            throw Invalid("returnDocument must be \"before\" or \"after\".")
        }
        if let pipeline = document["pipeline"], !(pipeline is [[String: Any]]) { throw Invalid("pipeline must be an array of stage objects.") }
        if operation == "aggregate", document["pipeline"] == nil { throw Invalid("aggregate requires pipeline.") }
        if operation == "distinct", (document["field"] as? String)?.isEmpty != false { throw Invalid("distinct requires field.") }
        if operation.hasPrefix("insert") {
            guard let documents = document["documents"] as? [[String: Any]], !documents.isEmpty,
                  documents.count <= 1000, operation != "insertOne" || documents.count == 1 else { throw Invalid("Insert requires documents (one for insertOne, at most 1000 for insertMany).") }
        }
        if let update = document["update"] {
            try Self.checkUpdate(update)
        } else if ["updateOne", "updateMany", "findOneAndUpdate"].contains(operation) {
            throw Invalid("Update requires a nonempty update object.")
        }
        if let replacement = document["replacement"] {
            try Self.checkReplacement(replacement)
        } else if ["replaceOne", "findOneAndReplace"].contains(operation) {
            throw Invalid("\(operation) requires replacement.")
        }
        if ["createIndex"].contains(operation), (document["keys"] as? [String: Any])?.isEmpty != false { throw Invalid("createIndex requires keys.") }
        if let options = document["options"] as? [String: Any] {
            let allowed = operation == "createCollection" ? Self.collectionOptions : Self.indexOptions
            guard Set(options.keys).isSubset(of: allowed) else {
                throw Invalid("\(operation)'s options take only \(allowed.sorted().joined(separator: ", ")).")
            }
            if operation == "createIndex", document["unique"] != nil, options["unique"] != nil { throw Invalid("Give unique once: as a field or in options.") }
            if let name = options["name"], (name as? String)?.isEmpty != false { throw Invalid("An index's name is a nonempty string.") }
        }
        if operation == "createIndexes" { try Self.checkIndexes(document["indexes"]) }
        if operation == "dropIndex" || operation == "dropIndexes" { try Self.checkDroppedIndex(document["index"], operation: operation) }
        if operation == "renameCollection" {
            guard let to = document["to"] as? String, Self.isValidCollectionName(to), to != collection else {
                throw Invalid("renameCollection requires to: another collection name in the same database (system collections are not supported).")
            }
        }
        if operation == "runCommand" { try Self.checkCommand(document["command"]) }
        var bulkDestructive = false
        if operation == "bulkWrite" { bulkDestructive = try Self.checkBulk(document["operations"]) }

        let encoded = String(data: try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes]), encoding: .utf8)!
        guard !Self.containsKey(document, keys: ["$where", "$function", "$accumulator", "$code"]) else { throw Invalid("Server-side JavaScript is not supported in MongoDB tabs.") }
        guard MongoRedaction.redact(encoded) == encoded else { throw Invalid("Queries cannot contain MongoDB URIs with credentials.") }
        let writes = Self.containsKey(document["pipeline"] ?? [], keys: ["$out", "$merge"])
        let emptyFilter = (document["filter"] as? [String: Any] ?? [:]).isEmpty
        self.json = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.operation = operation
        self.collection = collection
        self.database = database
        let destructive = Self.alwaysDestructive.contains(operation) || bulkDestructive
            || (Self.destructiveWithoutFilter.contains(operation) && emptyFilter)
        if destructive {
            effect = .destructive
        } else if Self.readOperations.contains(operation) && !writes {
            effect = .read
        } else {
            effect = .write
        }
        danger = destructive ? Self.danger(operation, collection: collection, database: database, document: document) : nil
        let explains = document["explain"] is String || document["explain"] as? Bool == true
        if explains, effect != .read { throw Invalid("Explain is available only for read operations.") }
    }

    public static let readOperations: Set<String> = ["find", "findOne", "aggregate", "countDocuments", "estimatedDocumentCount", "distinct", "getIndexes", "listDatabases",
                                                     "listCollections", "sampleSchema", "collStats", "dbStats", "runCommand"]
    public static let operations = readOperations.union(["insertOne", "insertMany", "updateOne", "updateMany", "deleteOne", "deleteMany", "replaceOne",
                                                         "findOneAndUpdate", "findOneAndReplace", "findOneAndDelete", "bulkWrite", "drop", "createIndex",
                                                         "createIndexes", "dropIndex", "dropIndexes", "renameCollection", "createCollection", "dropDatabase"])
    /// Always ask first (#191, #220): they remove collections, databases, or indexes, or move a
    /// collection's name.
    public static let alwaysDestructive: Set<String> = ["drop", "dropDatabase", "dropIndex", "dropIndexes", "renameCollection"]
    /// Ask first with an empty filter: every document, or (#220) an arbitrary one deleted or replaced.
    public static let destructiveWithoutFilter: Set<String> = ["deleteMany", "updateMany", "deleteOne", "replaceOne", "findOneAndDelete", "findOneAndReplace"]
    /// #220: what `explain` may say besides true and false.
    public static let explainVerbosities: Set<String> = ["queryPlanner", "executionStats", "allPlansExecution"]
    /// #220: createIndex's and createIndexes' index options.
    public static let indexOptions: Set<String> = ["name", "unique", "sparse", "expireAfterSeconds", "partialFilterExpression", "collation", "hidden", "weights",
                                                   "default_language", "language_override", "wildcardProjection", "2dsphereIndexVersion", "bits", "min", "max"]
    /// #220: createCollection's options.
    public static let collectionOptions: Set<String> = ["capped", "size", "max", "validator", "validationLevel", "validationAction", "timeseries",
                                                        "expireAfterSeconds", "collation", "clusteredIndex"]
    /// #220: the commands runCommand runs. Each only reads, and none names a collection to change.
    public static let commands: Set<String> = ["ping", "buildInfo", "hello", "isMaster", "connectionStatus", "serverStatus", "dbStats", "collStats", "listCommands"]
    /// Every field the JSON form knows.
    static let allFields: Set<String> = ["collection", "operation", "filter", "projection", "sort", "limit", "skip", "pipeline", "field", "documents", "update",
                                         "replacement", "keys", "unique", "explain", "database", "collation", "hint", "maxTimeMS", "allowDiskUse", "upsert",
                                         "arrayFilters", "ordered", "returnDocument", "operations", "options", "indexes", "index", "to", "dropTarget", "command"]

    /// A database name MongoDB accepts and Runlet may drop: not admin, local, or config.
    public static func isValidDatabaseName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 63 && name.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\. \"$*<>:|?\0")) == nil
            && !["admin", "local", "config"].contains(name.lowercased())
    }

    /// A collection name Runlet works with: not empty, at most 120 bytes, no NUL, no `system.`.
    public static func isValidCollectionName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 120 && !name.contains("\0") && !name.hasPrefix("system.")
    }

    /// What the operation acts on, for messages: "orders", or "the database “shop”".
    public var subject: String {
        database.map { "the database “\($0)”" } ?? collection
    }

    /// The fields `operation` takes (#217: the query builder writes only these; #220 added the
    /// options mongosh passes).
    public static func fields(for operation: String) -> Set<String> {
        let common: Set<String> = ["collection", "operation"]
        switch operation {
        case "find": return common.union(["filter", "projection", "sort", "skip", "limit", "explain", "collation", "hint", "maxTimeMS", "allowDiskUse"])
        case "findOne": return common.union(["filter", "projection", "sort", "collation", "hint", "maxTimeMS"])
        case "aggregate": return common.union(["pipeline", "explain", "collation", "hint", "maxTimeMS", "allowDiskUse"])
        case "countDocuments": return common.union(["filter", "collation", "hint", "maxTimeMS"])
        case "estimatedDocumentCount": return common.union(["maxTimeMS"])
        case "distinct": return common.union(["filter", "field", "collation", "maxTimeMS"])
        case "insertOne": return common.union(["documents"])
        case "insertMany": return common.union(["documents", "ordered"])
        case "updateOne", "updateMany": return common.union(["filter", "update", "upsert", "arrayFilters", "collation", "hint"])
        case "replaceOne": return common.union(["filter", "replacement", "upsert", "collation", "hint"])
        case "deleteOne", "deleteMany": return common.union(["filter", "collation", "hint"])
        case "findOneAndUpdate": return common.union(["filter", "update", "projection", "sort", "upsert", "returnDocument", "arrayFilters", "collation", "hint", "maxTimeMS"])
        case "findOneAndReplace": return common.union(["filter", "replacement", "projection", "sort", "upsert", "returnDocument", "collation", "hint", "maxTimeMS"])
        case "findOneAndDelete": return common.union(["filter", "projection", "sort", "collation", "hint", "maxTimeMS"])
        case "bulkWrite": return common.union(["operations", "ordered"])
        case "createIndex": return common.union(["keys", "unique", "options"])
        case "createIndexes": return common.union(["indexes"])
        case "dropIndex", "dropIndexes": return common.union(["index"])
        case "renameCollection": return common.union(["to", "dropTarget"])
        case "createCollection": return common.union(["options"])
        case "runCommand": return common.union(["command"])
        case "dropDatabase": return ["operation", "database"]
        default: return common
        }
    }

    // MARK: Checks

    private static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func isInteger(_ value: Any, in range: ClosedRange<Double>) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue.rounded() == number.doubleValue && range.contains(number.doubleValue)
    }

    private static func isHint(_ value: Any) -> Bool {
        if let name = value as? String { return !name.isEmpty }
        return (value as? [String: Any])?.isEmpty == false
    }

    /// An update is update operators (`{"$set": …}`) or (#220) a nonempty pipeline of stage
    /// objects. A document without operators would replace the matched document, so it's refused:
    /// replacing is replaceOne's job.
    private static func checkUpdate(_ update: Any) throws {
        if let stages = update as? [Any] {
            guard !stages.isEmpty, stages.allSatisfy({ ($0 as? [String: Any])?.count == 1 }) else {
                throw Invalid("An update pipeline is a nonempty array of stages, each an object with one stage, such as {\"$set\": {…}}.")
            }
            return
        }
        guard let object = update as? [String: Any], !object.isEmpty else { throw Invalid("Update requires a nonempty update object.") }
        guard object.keys.allSatisfy({ $0.hasPrefix("$") }) else {
            throw Invalid("An update uses update operators, such as {\"$set\": {\"status\": \"paid\"}}. To replace a document, use replaceOne.")
        }
    }

    /// A replacement is a document without update operators.
    private static func checkReplacement(_ replacement: Any) throws {
        guard let object = replacement as? [String: Any] else { throw Invalid("replacement must be a JSON object.") }
        guard !object.keys.contains(where: { $0.hasPrefix("$") }) else {
            throw Invalid("A replacement is a whole document, without update operators such as $set: use an update to change fields.")
        }
    }

    private static func checkIndexes(_ value: Any?) throws {
        guard let indexes = value as? [[String: Any]], (1...64).contains(indexes.count) else {
            throw Invalid("createIndexes requires indexes: an array of 1 to 64 objects, each with key and name.")
        }
        for index in indexes {
            guard (index["key"] as? [String: Any])?.isEmpty == false, (index["name"] as? String)?.isEmpty == false else {
                throw Invalid("Each of createIndexes' indexes has key (an object of fields) and name.")
            }
            guard Set(index.keys).isSubset(of: indexOptions.union(["key"])) else {
                throw Invalid("An index takes key and only \(indexOptions.sorted().joined(separator: ", ")).")
            }
        }
    }

    private static func checkDroppedIndex(_ value: Any?, operation: String) throws {
        if operation == "dropIndexes", value == nil { return }
        if let name = value as? String, !name.isEmpty {
            guard name != "_id_" else { throw Invalid("The _id index can't be dropped.") }
            guard name != "*" || operation == "dropIndexes" else { throw Invalid("dropIndex drops one index: use dropIndexes for every index.") }
            return
        }
        if (value as? [String: Any])?.isEmpty == false, operation == "dropIndex" { return }
        if let names = value as? [Any], operation == "dropIndexes", !names.isEmpty, names.allSatisfy({ ($0 as? String)?.isEmpty == false }) {
            guard !names.contains(where: { $0 as? String == "_id_" }) else { throw Invalid("The _id index can't be dropped.") }
            return
        }
        throw Invalid(operation == "dropIndex"
            ? "dropIndex requires index: an index's name, or its keys object."
            : "dropIndexes takes index: \"*\" for every index but _id's, a name, or an array of names.")
    }

    private static func checkCommand(_ value: Any?) throws {
        guard let command = value as? [String: Any] else { throw Invalid("runCommand requires command: a JSON object.") }
        let names = command.keys.filter(commands.contains)
        guard names.count == 1 else {
            throw Invalid("runCommand runs one of \(commands.sorted().joined(separator: ", ")). For anything else, use its operation.")
        }
        guard !command.keys.contains(where: { $0.hasPrefix("$") || ["comment", "writeConcern", "lsid", "txnNumber", "readConcern"].contains($0) }) else {
            throw Invalid("runCommand's command can't set $-fields, comment, sessions, or concerns.")
        }
    }

    /// bulkWrite's operations (#220), and whether one of them is destructive: a delete, or an
    /// updateMany or replaceOne with an empty filter.
    private static func checkBulk(_ value: Any?) throws -> Bool {
        guard let operations = value as? [[String: Any]], (1...1000).contains(operations.count) else {
            throw Invalid("bulkWrite requires operations: an array of 1 to 1000 objects, such as {\"insertOne\": {\"document\": {…}}}.")
        }
        var destructive = false
        for item in operations {
            guard item.count == 1, let (name, body) = item.first, let fields = body as? [String: Any] else {
                throw Invalid("Each bulkWrite operation is an object with one of insertOne, updateOne, updateMany, replaceOne, deleteOne, or deleteMany.")
            }
            let allowed: Set<String>
            switch name {
            case "insertOne": allowed = ["document"]
            case "updateOne", "updateMany": allowed = ["filter", "update", "upsert", "arrayFilters", "collation", "hint"]
            case "replaceOne": allowed = ["filter", "replacement", "upsert", "collation", "hint"]
            case "deleteOne", "deleteMany": allowed = ["filter", "collation", "hint"]
            default: throw Invalid("bulkWrite takes insertOne, updateOne, updateMany, replaceOne, deleteOne, and deleteMany, not \(name).")
            }
            guard Set(fields.keys).isSubset(of: allowed) else { throw Invalid("bulkWrite's \(name) takes only \(allowed.sorted().joined(separator: ", ")).") }
            for key in ["filter", "collation"] where fields[key] != nil {
                guard fields[key] is [String: Any] else { throw Invalid("bulkWrite's \(name): \(key) must be a JSON object.") }
            }
            if let upsert = fields["upsert"], !isBool(upsert) { throw Invalid("bulkWrite's \(name): upsert must be true or false.") }
            if let hint = fields["hint"], !isHint(hint) { throw Invalid("bulkWrite's \(name): hint must be an index name or keys object.") }
            if let filters = fields["arrayFilters"], !((filters as? [Any])?.allSatisfy { $0 is [String: Any] } ?? false) {
                throw Invalid("bulkWrite's \(name): arrayFilters must be an array of filter objects.")
            }
            let emptyFilter = (fields["filter"] as? [String: Any] ?? [:]).isEmpty
            switch name {
            case "insertOne":
                guard fields["document"] is [String: Any] else { throw Invalid("bulkWrite's insertOne requires document.") }
            case "updateOne", "updateMany":
                guard fields["filter"] != nil, let update = fields["update"] else { throw Invalid("bulkWrite's \(name) requires filter and update.") }
                try checkUpdate(update)
                if name == "updateMany", emptyFilter { destructive = true }
            case "replaceOne":
                guard fields["filter"] != nil, let replacement = fields["replacement"] else { throw Invalid("bulkWrite's replaceOne requires filter and replacement.") }
                try checkReplacement(replacement)
                if emptyFilter { destructive = true }
            default:
                guard fields["filter"] != nil else { throw Invalid("bulkWrite's \(name) requires filter.") }
                destructive = true
            }
        }
        return destructive
    }

    /// The confirmation's sentence for a destructive operation (#191, #220).
    private static func danger(_ operation: String, collection: String, database: String?, document: [String: Any]) -> String {
        switch operation {
        case "drop": return "removes the collection “\(collection)” with all its documents and indexes"
        case "dropDatabase": return "removes the database “\(database ?? "")” with all its collections, documents, and indexes"
        case "deleteMany": return "has an empty filter: it deletes every document of “\(collection)”"
        case "updateMany": return "has an empty filter: it updates every document of “\(collection)”"
        case "deleteOne", "findOneAndDelete": return "has an empty filter: it deletes the first document of “\(collection)” it finds, whichever that is"
        case "replaceOne", "findOneAndReplace": return "has an empty filter: it replaces the first document of “\(collection)” it finds, whichever that is"
        case "dropIndex", "dropIndexes":
            let index = document["index"] ?? "*"
            if let name = index as? String {
                return name == "*" ? "removes every index of “\(collection)” except _id's" : "removes the index “\(name)” of “\(collection)”"
            }
            if let names = index as? [String] { return "removes the indexes \(names.map { "“\($0)”" }.joined(separator: ", ")) of “\(collection)”" }
            return "removes the index of “\(collection)” on those keys"
        case "renameCollection":
            let to = document["to"] as? String ?? ""
            return "renames “\(collection)” to “\(to)”" + (document["dropTarget"] as? Bool == true ? ", and drops an existing “\(to)” first" : "; code that uses “\(collection)” won't find it")
        case "bulkWrite": return "deletes documents of “\(collection)”, or changes them with an empty filter"
        default: return "can't be undone"
        }
    }

    private static func containsKey(_ value: Any, keys: Set<String>) -> Bool {
        if let object = value as? [String: Any] { return object.contains { keys.contains($0.key) || containsKey($0.value, keys: keys) } }
        if let array = value as? [Any] { return array.contains { containsKey($0, keys: keys) } }
        return false
    }

    public func runnerCode(connection: String?, pageSize: Int = 100, offset: Int = 0, confirmed: Bool = false) -> String {
        let payload: [String: Any] = ["query": json, "connection": connection as Any? ?? NSNull(), "pageSize": min(1000, max(1, pageSize)), "offset": max(0, offset), "confirmed": confirmed]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return "\\RunletRunner\\MongoTab::run(json_decode(base64_decode('\(data.base64EncodedString())'), true));"
    }
}

public enum MongoRedaction {
    public static func redact(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?i)(mongodb(?:\+srv)?://)[^\s/\"<>]*@"#, with: "$1[redacted]@", options: .regularExpression)
    }
}
