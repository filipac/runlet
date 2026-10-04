import Foundation

/// The MongoDB query builder's model (#217): a MongoDB tab's JSON query as the builder edits it.
/// It reads a query (`init(json:)`) and writes one (`json()`, `text`) in `MongoQuery`'s form.
///
/// Round trip: a query read and written back is the same JSON, with its members in the same
/// order and its numbers' literals unchanged. What the builder has no form for (an operator,
/// a stage, an update operator, a field the operation doesn't take) is kept as a raw block in
/// its place; anything the builder can't write back exactly is read as raw too.
public struct MongoQueryBuilder: Equatable, Sendable {
    /// The operations the builder offers, reads first.
    public static let operations = ["find", "findOne", "countDocuments", "distinct", "aggregate",
                                    "insertOne", "insertMany", "updateOne", "updateMany", "replaceOne", "deleteOne", "deleteMany"]
    /// The members' order for a query built from scratch.
    public static let canonicalOrder = ["collection", "operation", "database", "filter", "projection", "sort", "skip", "limit", "field",
                                        "pipeline", "update", "replacement", "documents", "keys", "unique", "explain"]

    public var collection: String?
    public var operation: String?
    public var filter: MongoFilterGroup?
    public var projection: [MongoFieldValue]?
    public var sort: [MongoFieldValue]?
    public var skip: MongoValue?
    public var limit: MongoValue?
    /// distinct's field.
    public var field: String?
    public var pipeline: [MongoStage]?
    public var update: [MongoUpdateNode]?
    /// replaceOne's replacement and the inserts' documents, as JSON text.
    public var replacement: String?
    public var documents: String?
    public var explain: Bool?
    /// Members the builder doesn't edit (createIndex's keys, a field the operation doesn't take,
    /// or one it couldn't read), kept as JSON in their place.
    public var extras: [MongoRawMember]
    /// The members' order as read; members added later follow in `canonicalOrder`.
    public var order: [String]

    public init(collection: String? = nil, operation: String? = "find") {
        self.collection = collection
        self.operation = operation
        extras = []
        order = []
    }

    /// A find of `collection`, as "Start from collection…" makes it: an empty filter and a
    /// limit of 50, like Open Find Query.
    public static func start(collection: String) -> MongoQueryBuilder {
        var builder = MongoQueryBuilder(collection: collection, operation: "find")
        builder.filter = MongoFilterGroup()
        builder.limit = .number("50")
        return builder
    }

    public enum ReadError: Error, Equatable, Sendable, LocalizedError {
        case json(MongoJSON.ParseError)
        case notAnObject

        public var errorDescription: String? {
            switch self {
            case .json(let error): "The query isn't valid JSON. \(error.errorDescription ?? "")"
            case .notAnObject: "The query isn't a JSON object: write one object with collection, operation, and its arguments."
            }
        }
    }

    /// Reads a query's text.
    public static func read(_ text: String) -> Result<MongoQueryBuilder, ReadError> {
        do {
            let json = try MongoJSON.parse(text)
            guard case .object = json else { return .failure(.notAnObject) }
            return .success(MongoQueryBuilder(json: json))
        } catch {
            return .failure(.json(error))
        }
    }

    /// Reads a query object (anything else becomes an empty builder).
    public init(json: MongoJSON) {
        self.init(collection: nil, operation: nil)
        guard case .object(let members) = json else { return }
        order = members.map(\.key)
        let operationName = members.first { $0.key == "operation" }?.value.stringValue
        let allowed = operationName.map(MongoQuery.fields(for:)) ?? []
        var seen: Set<String> = []
        for member in members {
            let key = member.key
            let value = member.value
            defer { seen.insert(key) }
            func keep() { extras.append(MongoRawMember(key: key, value: value)) }
            guard !seen.contains(key) else { keep(); continue }
            let takes = allowed.contains(key)
            switch key {
            case "collection":
                if let name = value.stringValue { collection = name } else { keep() }
            case "operation":
                if let name = value.stringValue { operation = name } else { keep() }
            case "filter" where takes:
                if let group = MongoFilterGroup.parse(value) { filter = group } else { keep() }
            case "projection" where takes:
                if let fields = MongoFieldValue.parse(value, expression: true) { projection = fields } else { keep() }
            case "sort" where takes:
                if let fields = MongoFieldValue.parse(value, expression: false) { sort = fields } else { keep() }
            case "skip" where takes: skip = MongoValue(json: value)
            case "limit" where takes: limit = MongoValue(json: value)
            case "field" where takes:
                if let name = value.stringValue { field = name } else { keep() }
            case "pipeline" where takes:
                if let stages = value.elements { pipeline = stages.map(MongoStage.parse) } else { keep() }
            case "update" where takes:
                if let nodes = MongoUpdateNode.parse(value) { update = nodes } else { keep() }
            case "replacement" where takes: replacement = value.pretty(width: 60)
            case "documents" where takes: documents = value.pretty(width: 60)
            case "explain" where takes:
                if case .bool(let flag) = value { explain = flag } else { keep() }
            default: keep()
            }
        }
        // Whatever doesn't write back exactly is kept as it was read.
        if (try? self.json()) != json {
            var raw = MongoQueryBuilder(collection: nil, operation: nil)
            raw.order = order
            for member in members {
                if member.key == "collection", raw.collection == nil, let name = member.value.stringValue { raw.collection = name; continue }
                if member.key == "operation", raw.operation == nil, let name = member.value.stringValue { raw.operation = name; continue }
                raw.extras.append(MongoRawMember(key: member.key, value: member.value))
            }
            self = raw
        }
    }

    // MARK: Writing

    /// The fields the current operation takes; others stay in the builder but aren't written.
    public var allowedFields: Set<String> { operation.map(MongoQuery.fields(for:)) ?? [] }

    /// The query as JSON. Throws while a value isn't valid for its type.
    public func json() throws(MongoBuilderProblem) -> MongoJSON {
        let allowed = allowedFields
        var structured: [String: MongoJSON] = [:]
        if let collection { structured["collection"] = .string(collection) }
        if let operation { structured["operation"] = .string(operation) }
        func put(_ key: String, _ value: MongoJSON?) { if let value, allowed.contains(key) { structured[key] = value } }
        if allowed.contains("filter"), let filter { put("filter", try filter.filterJSON()) }
        if allowed.contains("projection"), let projection { put("projection", try MongoFieldValue.object(projection, place: "Projection")) }
        if allowed.contains("sort"), let sort { put("sort", try MongoFieldValue.object(sort, place: "Sort")) }
        for (key, value) in [("skip", skip), ("limit", limit)] where allowed.contains(key) {
            guard let value else { continue }
            guard let json = value.json else { throw MongoBuilderProblem("\(key.capitalized): \(value.problem ?? "invalid value")") }
            put(key, json)
        }
        put("field", field.map(MongoJSON.string))
        if allowed.contains("pipeline"), let pipeline {
            var stages: [MongoJSON] = []
            for stage in pipeline { if let json = try stage.json() { stages.append(json) } }
            put("pipeline", .array(stages))
        }
        if allowed.contains("update"), let update { put("update", try MongoUpdateNode.object(update)) }
        for (key, text) in [("replacement", replacement), ("documents", documents)] where allowed.contains(key) {
            guard let text else { continue }
            do { put(key, try MongoJSON.parse(text)) } catch { throw MongoBuilderProblem("\(key.capitalized): \(error.errorDescription ?? "invalid JSON")") }
        }
        put("explain", explain.map(MongoJSON.bool))

        var members: [MongoJSON.Member] = []
        var written: Set<String> = []
        var pending = extras
        for key in order {
            if let value = structured[key], !written.contains(key) {
                members.append(.init(key, value))
                written.insert(key)
            } else if let index = pending.firstIndex(where: { $0.key == key }) {
                members.append(try pending.remove(at: index).member("Query field"))
            }
        }
        for key in Self.canonicalOrder where !written.contains(key) {
            if let value = structured[key] {
                members.append(.init(key, value))
                written.insert(key)
            }
        }
        for extra in pending { members.append(try extra.member("Query field")) }
        return .object(members)
    }

    /// The query pretty-printed as the builder writes it into the editor, or nil while a value
    /// isn't valid.
    public var text: String? { (try? json())?.pretty() }

    /// Why the builder can't write yet, or nil.
    public var problem: String? {
        do { _ = try json(); return nil } catch { return error.message }
    }

    /// What isn't written because it's incomplete (a rule without a field, an empty group, …).
    public var incomplete: [String] {
        var notes: [String] = []
        let allowed = allowedFields
        func scan(_ group: MongoFilterGroup, root: Bool) {
            if !root, group.children.isEmpty { notes.append("An empty \(group.kind.title.lowercased()) group isn't written.") }
            for child in group.children {
                switch child {
                case .rule(let rule) where rule.path.isEmpty: notes.append("A rule without a field isn't written.")
                case .group(let nested): scan(nested, root: false)
                default: break
                }
            }
        }
        if allowed.contains("filter"), let filter { scan(filter, root: true) }
        if allowed.contains("pipeline"), let pipeline {
            for (index, stage) in pipeline.enumerated() {
                if !stage.enabled { notes.append("Stage \(index + 1) (\(stage.kind.rawValue)) is disabled, so it isn't written.") }
                if let missing = stage.incomplete { notes.append("Stage \(index + 1) (\(stage.kind.rawValue)) isn't written: \(missing)") }
                if case .match(let group) = stage.body { scan(group, root: true) }
            }
        }
        for list in [allowed.contains("projection") ? projection : nil, allowed.contains("sort") ? sort : nil].compactMap({ $0 }) where list.contains(where: { $0.path.isEmpty }) {
            notes.append("A field without a name isn't written.")
        }
        if allowed.contains("update"), update?.contains(where: { if case .entry(let entry) = $0 { entry.path.isEmpty } else { false } }) == true {
            notes.append("A change without a field isn't written.")
        }
        var unique: [String] = []
        for note in notes where !unique.contains(note) { unique.append(note) }
        return unique
    }

    // MARK: Editing

    /// Changes the operation and gives it what it needs: aggregate starts its pipeline from the
    /// filter, sort, skip, and limit; updates get a `$set`; inserts and replaceOne a document.
    /// Fields the new operation doesn't take stay in the builder (switching back restores them).
    public mutating func setOperation(_ new: String) {
        guard new != operation else { return }
        let old = operation
        operation = new
        let allowed = MongoQuery.fields(for: new)
        if allowed.contains("filter"), filter == nil, ["updateOne", "updateMany", "deleteOne", "deleteMany", "replaceOne"].contains(new) {
            filter = MongoFilterGroup()
        }
        switch new {
        case "aggregate" where pipeline == nil:
            var stages: [MongoStage] = []
            if let filter, !filter.isEmpty { stages.append(MongoStage(.match(filter))) }
            if old == "find" || old == "findOne" {
                if let sort, !sort.isEmpty { stages.append(MongoStage(.sort(sort))) }
                if let skip { stages.append(MongoStage(.skip(skip))) }
                if let limit { stages.append(MongoStage(.limit(limit))) }
                if let projection, !projection.isEmpty { stages.append(MongoStage(.project(projection))) }
            }
            pipeline = stages
        case "distinct" where field == nil: field = ""
        case "updateOne", "updateMany":
            if update == nil { update = [.entry(MongoUpdateEntry())] }
        case "replaceOne" where replacement == nil: replacement = "{}"
        case "insertOne" where documents == nil: documents = "[\n  {}\n]"
        case "insertMany" where documents == nil: documents = "[\n  {},\n  {}\n]"
        default: break
        }
    }

    /// Whether the operation is one the builder offers forms for.
    public var isBuilderOperation: Bool { operation.map(Self.operations.contains) ?? false }

    /// How Runlet treats the query the builder writes: read, write, or destructive (always asks).
    public var effect: MongoQuery.Effect? {
        text.flatMap { try? MongoQuery($0).effect }
    }

    /// Why ⌘R would refuse the written query, if it would.
    public var runProblem: String? {
        guard let text else { return nil }
        do { _ = try MongoQuery(text); return nil } catch { return error.localizedDescription }
    }

    /// Removes extras named `key` (when the builder edits that field itself).
    public mutating func dropExtras(named key: String) {
        extras.removeAll { $0.key == key }
    }
}
