import Foundation

/// A path and its value (#217): a projection's field (1, 0, or an expression), a sort key (1 or
/// −1), or an `$addFields` field.
public struct MongoFieldValue: Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var path: String
    public var value: MongoValue

    public init(path: String = "", value: MongoValue = .number("1")) {
        self.path = path
        self.value = value
    }

    /// The fields as one object; a field without a path isn't written.
    static func object(_ fields: [MongoFieldValue], place: String) throws(MongoBuilderProblem) -> MongoJSON {
        var members: [MongoJSON.Member] = []
        for field in fields where !field.path.isEmpty {
            guard let json = field.value.json else { throw MongoBuilderProblem("\(place) \(field.path): \(field.value.problem ?? "invalid value")") }
            members.append(.init(field.path, json))
        }
        return .object(members)
    }

    /// Reads an object's members; nil when it isn't an object or one can't be edited as a field.
    static func parse(_ json: MongoJSON, expression: Bool) -> [MongoFieldValue]? {
        guard case .object(let members) = json, members.allSatisfy({ !$0.key.isEmpty }) else { return nil }
        let fields = members.map { MongoFieldValue(path: $0.key, value: MongoValue(json: $0.value, expression: expression)) }
        guard (try? object(fields, place: "")) == json else { return nil }
        return fields
    }
}

/// `$group` (#217): what to group by, and the accumulated fields.
public struct MongoGroupStage: Equatable, Sendable {
    public enum Key: Equatable, Sendable {
        /// `"_id": null`: one group of all documents.
        case all
        /// `"_id": "$status"`
        case field(String)
        /// `"_id": { "status": "$status", "city": "$customer.city" }`
        case fields([MongoGroupField])
        /// Any other expression, as JSON.
        case expression(MongoValue)
    }

    public var key: Key
    public var accumulators: [MongoAccumulator]

    public init(key: Key = .all, accumulators: [MongoAccumulator] = []) {
        self.key = key
        self.accumulators = accumulators
    }

    func json() throws(MongoBuilderProblem) -> MongoJSON {
        let id: MongoJSON
        switch key {
        case .all: id = .null
        case .field(let path): id = path.isEmpty ? .null : .string("$" + path)
        case .fields(let fields): id = .object(fields.filter { !$0.name.isEmpty && !$0.path.isEmpty }.map { .init($0.name, .string("$" + $0.path)) })
        case .expression(let value):
            guard let json = value.json else { throw MongoBuilderProblem("$group _id: \(value.problem ?? "invalid value")") }
            id = json
        }
        var members: [MongoJSON.Member] = [.init("_id", id)]
        for accumulator in accumulators where !accumulator.name.isEmpty {
            guard let argument = accumulator.argument.json else { throw MongoBuilderProblem("$group \(accumulator.name): \(accumulator.argument.problem ?? "invalid value")") }
            members.append(.init(accumulator.name, .object([.init(accumulator.op, argument)])))
        }
        return .object(members)
    }

    static func parse(_ json: MongoJSON) -> MongoGroupStage? {
        guard case .object(let members) = json, members.first?.key == "_id" else { return nil }
        let key: Key
        switch members[0].value {
        case .null: key = .all
        case .string(let text) where text.hasPrefix("$") && !text.hasPrefix("$$") && text.count > 1: key = .field(String(text.dropFirst()))
        case .object(let fields) where !fields.isEmpty && fields.allSatisfy({ field in
            !field.key.isEmpty && !field.key.hasPrefix("$") && (field.value.stringValue.map { $0.hasPrefix("$") && !$0.hasPrefix("$$") && $0.count > 1 } ?? false)
        }):
            key = .fields(fields.map { MongoGroupField(name: $0.key, path: String($0.value.stringValue!.dropFirst())) })
        default: key = .expression(MongoValue(json: members[0].value, expression: true))
        }
        var accumulators: [MongoAccumulator] = []
        for member in members.dropFirst() {
            guard !member.key.isEmpty, case .object(let body) = member.value, body.count == 1, body[0].key.hasPrefix("$") else { return nil }
            accumulators.append(MongoAccumulator(name: member.key, op: body[0].key, argument: MongoValue(json: body[0].value, expression: true)))
        }
        return MongoGroupStage(key: key, accumulators: accumulators)
    }
}

/// One field of a `$group` key: its name in `_id`, and the field it takes.
public struct MongoGroupField: Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    public var path: String
    public init(name: String = "", path: String = "") {
        self.name = name
        self.path = path
    }
}

/// An accumulated field of `$group`: `"total": { "$sum": "$total" }`.
public struct MongoAccumulator: Equatable, Sendable, Identifiable {
    public static let operators = ["$sum", "$avg", "$min", "$max", "$count", "$push", "$addToSet", "$first", "$last"]
    public var id = UUID()
    public var name: String
    public var op: String
    public var argument: MongoValue

    public init(name: String = "", op: String = "$sum", argument: MongoValue = .number("1")) {
        self.name = name
        self.op = op
        self.argument = argument
    }

    /// Changes the accumulator; `$count` takes `{}`.
    public mutating func setOperator(_ new: String) {
        guard new != op else { return }
        op = new
        if new == "$count" {
            argument = MongoValue(.json, "{}")
        } else if argument.kind == .json, argument.text.mongoTrimmed == "{}" {
            argument = new == "$sum" ? .number("1") : .field("")
        }
    }
}

/// `$unwind`: `"$items"`, or the object form with its options.
public struct MongoUnwindStage: Equatable, Sendable {
    public var path: String
    public var includeArrayIndex: String
    public var preserveNullAndEmptyArrays: Bool?
    /// Written as an object even without options, as read.
    public var objectForm: Bool

    public init(path: String = "", includeArrayIndex: String = "", preserveNullAndEmptyArrays: Bool? = nil, objectForm: Bool = false) {
        self.path = path
        self.includeArrayIndex = includeArrayIndex
        self.preserveNullAndEmptyArrays = preserveNullAndEmptyArrays
        self.objectForm = objectForm
    }

    var json: MongoJSON {
        let reference = MongoJSON.string("$" + path)
        guard objectForm || !includeArrayIndex.isEmpty || preserveNullAndEmptyArrays != nil else { return reference }
        var members: [MongoJSON.Member] = [.init("path", reference)]
        if !includeArrayIndex.isEmpty { members.append(.init("includeArrayIndex", .string(includeArrayIndex))) }
        if let preserveNullAndEmptyArrays { members.append(.init("preserveNullAndEmptyArrays", .bool(preserveNullAndEmptyArrays))) }
        return .object(members)
    }

    static func parse(_ json: MongoJSON) -> MongoUnwindStage? {
        func path(_ value: MongoJSON?) -> String? {
            guard let text = value?.stringValue, text.hasPrefix("$"), !text.hasPrefix("$$"), text.count > 1 else { return nil }
            return String(text.dropFirst())
        }
        if let path = path(json) { return MongoUnwindStage(path: path) }
        guard case .object = json, let reference = path(json["path"]) else { return nil }
        var stage = MongoUnwindStage(path: reference, objectForm: true)
        if let index = json["includeArrayIndex"] {
            guard let name = index.stringValue else { return nil }
            stage.includeArrayIndex = name
        }
        if let preserve = json["preserveNullAndEmptyArrays"] {
            guard case .bool(let flag) = preserve else { return nil }
            stage.preserveNullAndEmptyArrays = flag
        }
        return stage
    }
}

/// `$lookup` with `from`, `localField`, `foreignField`, and `as` (the pipeline form stays raw JSON).
public struct MongoLookupStage: Equatable, Sendable {
    public var from: String
    public var localField: String
    public var foreignField: String
    public var output: String

    public init(from: String = "", localField: String = "", foreignField: String = "", output: String = "") {
        self.from = from
        self.localField = localField
        self.foreignField = foreignField
        self.output = output
    }

    var json: MongoJSON {
        .object([.init("from", .string(from)), .init("localField", .string(localField)), .init("foreignField", .string(foreignField)), .init("as", .string(output))])
    }

    static func parse(_ json: MongoJSON) -> MongoLookupStage? {
        guard case .object(let members) = json, members.map(\.key) == ["from", "localField", "foreignField", "as"],
              let from = members[0].value.stringValue, let local = members[1].value.stringValue,
              let foreign = members[2].value.stringValue, let output = members[3].value.stringValue else { return nil }
        return MongoLookupStage(from: from, localField: local, foreignField: foreign, output: output)
    }
}

/// An aggregation stage card (#217). A disabled stage isn't written: it stays in the builder
/// (while it's open) and can be enabled again.
public struct MongoStage: Equatable, Sendable, Identifiable {
    public enum Kind: String, CaseIterable, Sendable {
        case match = "$match", project = "$project", group = "$group", sort = "$sort", limit = "$limit", skip = "$skip"
        case unwind = "$unwind", lookup = "$lookup", addFields = "$addFields", set = "$set", count = "$count", raw = "JSON"
    }

    public enum Body: Equatable, Sendable {
        case match(MongoFilterGroup)
        case project([MongoFieldValue])
        case group(MongoGroupStage)
        case sort([MongoFieldValue])
        case limit(MongoValue)
        case skip(MongoValue)
        case unwind(MongoUnwindStage)
        case lookup(MongoLookupStage)
        /// `$addFields`, or its alias `$set` (`alias` true).
        case addFields([MongoFieldValue], alias: Bool)
        case count(String)
        /// Any other stage, as JSON text of the whole stage object.
        case raw(String)
    }

    public var id = UUID()
    public var enabled = true
    public var body: Body

    public init(_ body: Body, enabled: Bool = true) {
        self.body = body
        self.enabled = enabled
    }

    public var kind: Kind {
        switch body {
        case .match: .match
        case .project: .project
        case .group: .group
        case .sort: .sort
        case .limit: .limit
        case .skip: .skip
        case .unwind: .unwind
        case .lookup: .lookup
        case .addFields(_, let alias): alias ? .set : .addFields
        case .count: .count
        case .raw: .raw
        }
    }

    /// A new stage of `kind`, as Add Stage makes it.
    public static func new(_ kind: Kind) -> MongoStage {
        switch kind {
        case .match: MongoStage(.match(MongoFilterGroup()))
        case .project: MongoStage(.project([]))
        case .group: MongoStage(.group(MongoGroupStage(accumulators: [MongoAccumulator(name: "count", op: "$sum", argument: .number("1"))])))
        case .sort: MongoStage(.sort([]))
        case .limit: MongoStage(.limit(.number("10")))
        case .skip: MongoStage(.skip(.number("0")))
        case .unwind: MongoStage(.unwind(MongoUnwindStage()))
        case .lookup: MongoStage(.lookup(MongoLookupStage()))
        case .addFields: MongoStage(.addFields([], alias: false))
        case .set: MongoStage(.addFields([], alias: true))
        case .count: MongoStage(.count("count"))
        case .raw: MongoStage(.raw("{ \"$sample\": { \"size\": 10 } }"))
        }
    }

    /// A copy with new identities (Duplicate).
    public var duplicated: MongoStage {
        var copy = self
        copy.id = UUID()
        return copy
    }

    /// What's missing before the stage is written ("choose a field"); a stage with this isn't written.
    public var incomplete: String? {
        switch body {
        case .unwind(let unwind) where unwind.path.isEmpty: "Choose the array field to unwind."
        case .lookup(let lookup) where [lookup.from, lookup.localField, lookup.foreignField, lookup.output].contains(""): "Fill in the collection, both fields, and the output field."
        case .count(let name) where name.isEmpty: "Name the count's field."
        default: nil
        }
    }

    /// The stage object, or nil when it's disabled or incomplete. Throws while a value isn't valid.
    func json() throws(MongoBuilderProblem) -> MongoJSON? {
        guard enabled, incomplete == nil else { return nil }
        let value: MongoJSON
        switch body {
        case .match(let filter): value = try filter.filterJSON()
        case .project(let fields): value = try MongoFieldValue.object(fields, place: "$project")
        case .group(let group): value = try group.json()
        case .sort(let fields): value = try MongoFieldValue.object(fields, place: "$sort")
        case .limit(let number), .skip(let number):
            guard let json = number.json else { throw MongoBuilderProblem("\(kind.rawValue): \(number.problem ?? "invalid value")") }
            value = json
        case .unwind(let unwind): value = unwind.json
        case .lookup(let lookup): value = lookup.json
        case .addFields(let fields, _): value = try MongoFieldValue.object(fields, place: kind.rawValue)
        case .count(let name): value = .string(name)
        case .raw(let text):
            do { return try MongoJSON.parse(text) } catch { throw MongoBuilderProblem("JSON stage: \(error.errorDescription ?? "invalid JSON")") }
        }
        return .object([.init(kind.rawValue, value)])
    }

    /// Reads one pipeline stage; one the builder has no card for, or can't write back exactly,
    /// stays a JSON stage.
    public static func parse(_ json: MongoJSON) -> MongoStage {
        let raw = MongoStage(.raw(json.display))
        guard case .object(let members) = json, members.count == 1, let kind = Kind(rawValue: members[0].key) else { return raw }
        let value = members[0].value
        let body: Body?
        switch kind {
        case .match: body = MongoFilterGroup.parse(value).map(Body.match)
        case .project: body = MongoFieldValue.parse(value, expression: true).map(Body.project)
        case .group: body = MongoGroupStage.parse(value).map(Body.group)
        case .sort: body = MongoFieldValue.parse(value, expression: false).map(Body.sort)
        case .limit: body = .limit(MongoValue(json: value))
        case .skip: body = .skip(MongoValue(json: value))
        case .unwind: body = MongoUnwindStage.parse(value).map(Body.unwind)
        case .lookup: body = MongoLookupStage.parse(value).map(Body.lookup)
        case .addFields, .set: body = MongoFieldValue.parse(value, expression: true).map { .addFields($0, alias: kind == .set) }
        case .count: body = value.stringValue.map(Body.count)
        case .raw: body = nil
        }
        guard let body else { return raw }
        let stage = MongoStage(body)
        return (try? stage.json()) == json ? stage : raw
    }
}

// MARK: - Updates

/// One change of an update (#217): `$set`, `$unset`, `$inc`, `$push`, or `$pull` of a field.
public struct MongoUpdateEntry: Equatable, Sendable, Identifiable {
    public enum Operator: String, CaseIterable, Sendable {
        case set = "$set", unset = "$unset", inc = "$inc", push = "$push", pull = "$pull"
    }

    public var id = UUID()
    public var op: Operator
    public var path: String
    /// The value; `$unset` writes it as read, or `""`.
    public var value: MongoValue

    public init(op: Operator = .set, path: String = "", value: MongoValue = .string("")) {
        self.op = op
        self.path = path
        self.value = value
    }

    public mutating func setOperator(_ new: Operator) {
        guard new != op else { return }
        op = new
        if new == .unset { value = .string("") }
        if new == .inc, value.kind != .number { value = .number("1") }
    }
}

/// An update's part: a change, or a member the builder has no form for (`$rename`, …), as JSON.
public enum MongoUpdateNode: Equatable, Sendable, Identifiable {
    case entry(MongoUpdateEntry)
    case raw(MongoRawMember)

    public var id: UUID {
        switch self {
        case .entry(let entry): entry.id
        case .raw(let raw): raw.id
        }
    }

    /// The update document: changes grouped under their operator, in the order the operators
    /// first appear. A change without a field isn't written.
    static func object(_ nodes: [MongoUpdateNode]) throws(MongoBuilderProblem) -> MongoJSON {
        var members: [MongoJSON.Member] = []
        var operators: [String: Int] = [:]
        for node in nodes {
            switch node {
            case .entry(let entry):
                guard !entry.path.isEmpty else { continue }
                guard let value = entry.value.json else { throw MongoBuilderProblem("\(entry.op.rawValue) \(entry.path): \(entry.value.problem ?? "invalid value")") }
                if let index = operators[entry.op.rawValue], case .object(var fields) = members[index].value {
                    fields.append(.init(entry.path, value))
                    members[index].value = .object(fields)
                } else {
                    operators[entry.op.rawValue] = members.count
                    members.append(.init(entry.op.rawValue, .object([.init(entry.path, value)])))
                }
            case .raw(let raw):
                members.append(try raw.member("Update"))
            }
        }
        return .object(members)
    }

    /// Reads an update document; nil when it isn't an object.
    static func parse(_ json: MongoJSON) -> [MongoUpdateNode]? {
        guard case .object(let members) = json else { return nil }
        var nodes: [MongoUpdateNode] = []
        for member in members {
            if let op = MongoUpdateEntry.Operator(rawValue: member.key), case .object(let fields) = member.value, !fields.isEmpty,
               fields.allSatisfy({ !$0.key.isEmpty }) {
                nodes += fields.map { .entry(MongoUpdateEntry(op: op, path: $0.key, value: MongoValue(json: $0.value))) }
            } else {
                nodes.append(.raw(MongoRawMember(key: member.key, value: member.value)))
            }
        }
        if (try? object(nodes)) != json {
            nodes = members.map { .raw(MongoRawMember(key: $0.key, value: $0.value)) }
        }
        return nodes
    }
}
