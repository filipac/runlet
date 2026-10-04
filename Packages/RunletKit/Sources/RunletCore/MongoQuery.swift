import CoreFoundation
import Foundation

public struct MongoQuery: Sendable, Equatable {
    public enum Effect: String, Sendable { case read, write, destructive }
    public let json: String
    public let operation: String
    public let collection: String
    public let effect: Effect

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
        let allowed: Set<String> = ["collection", "operation", "filter", "projection", "sort", "limit", "skip", "pipeline", "field", "documents", "update", "replacement", "keys", "unique", "explain"]
        guard Set(document.keys).isSubset(of: allowed) else { throw Invalid("Unknown query field. Connection credentials and arbitrary commands are not query fields.") }
        guard let operation = document["operation"] as? String,
              Self.operations.contains(operation) else { throw Invalid("Choose a supported MongoDB operation.") }
        guard Set(document.keys).isSubset(of: Self.fields(for: operation)) else { throw Invalid("This operation does not support one of the supplied fields.") }
        let collection = document["collection"] as? String ?? ""
        guard !collection.isEmpty, collection.utf8.count <= 120, !collection.contains("\0"), !collection.hasPrefix("system.") else {
            throw Invalid("Enter a collection name (system collections are not supported).")
        }
        for key in ["filter", "projection", "sort", "update", "replacement", "keys"] where document[key] != nil {
            guard document[key] is [String: Any] else { throw Invalid("\(key) must be a JSON object.") }
        }
        for key in ["skip", "limit"] {
            if let value = document[key] {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.rounded() == number.doubleValue,
                      number.doubleValue >= 0, number.doubleValue <= 1_000_000 else { throw Invalid("\(key) must be an integer from 0 to 1000000.") }
            }
        }
        for key in ["explain", "unique"] {
            if let value = document[key] {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw Invalid("\(key) must be true or false.") }
            }
        }
        if let pipeline = document["pipeline"], !(pipeline is [[String: Any]]) { throw Invalid("pipeline must be an array of stage objects.") }
        if operation == "aggregate", document["pipeline"] == nil { throw Invalid("aggregate requires pipeline.") }
        if operation == "distinct", (document["field"] as? String)?.isEmpty != false { throw Invalid("distinct requires field.") }
        if operation.hasPrefix("insert") {
            guard let documents = document["documents"] as? [[String: Any]], !documents.isEmpty,
                  documents.count <= 1000, operation != "insertOne" || documents.count == 1 else { throw Invalid("Insert requires documents (one for insertOne, at most 1000 for insertMany).") }
        }
        if operation.hasPrefix("update"), (document["update"] as? [String: Any])?.isEmpty != false { throw Invalid("Update requires a nonempty update object.") }
        if operation == "replaceOne", document["replacement"] == nil { throw Invalid("replaceOne requires replacement.") }
        if operation == "createIndex", (document["keys"] as? [String: Any])?.isEmpty != false { throw Invalid("createIndex requires keys.") }
        let encoded = String(data: try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes]), encoding: .utf8)!
        guard !Self.containsKey(document, keys: ["$where", "$function", "$accumulator", "$code"]) else { throw Invalid("Server-side JavaScript is not supported in MongoDB tabs.") }
        guard MongoRedaction.redact(encoded) == encoded else { throw Invalid("Queries cannot contain MongoDB URIs with credentials.") }
        let writes = Self.containsKey(document["pipeline"] ?? [], keys: ["$out", "$merge"])
        let emptyFilter = (document["filter"] as? [String: Any] ?? [:]).isEmpty
        self.json = encoded
        self.operation = operation
        self.collection = collection
        if operation == "drop" || ((operation == "deleteMany" || operation == "updateMany") && emptyFilter) {
            effect = .destructive
        } else if Self.readOperations.contains(operation) && !writes {
            effect = .read
        } else {
            effect = .write
        }
        if document["explain"] as? Bool == true, effect != .read { throw Invalid("Explain is available only for read operations.") }
    }

    public static let readOperations: Set<String> = ["find", "findOne", "aggregate", "countDocuments", "distinct", "getIndexes"]
    public static let operations = readOperations.union(["insertOne", "insertMany", "updateOne", "updateMany", "deleteOne", "deleteMany", "replaceOne", "drop", "createIndex"])

    private static func fields(for operation: String) -> Set<String> {
        let common: Set<String> = ["collection", "operation"]
        switch operation {
        case "find": return common.union(["filter", "projection", "sort", "skip", "limit", "explain"])
        case "findOne": return common.union(["filter", "projection", "sort"])
        case "aggregate": return common.union(["pipeline", "explain"])
        case "countDocuments": return common.union(["filter"])
        case "distinct": return common.union(["filter", "field"])
        case "insertOne", "insertMany": return common.union(["documents"])
        case "updateOne", "updateMany": return common.union(["filter", "update"])
        case "replaceOne": return common.union(["filter", "replacement"])
        case "deleteOne", "deleteMany": return common.union(["filter"])
        case "createIndex": return common.union(["keys", "unique"])
        default: return common
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
