import Foundation

/// Why the builder can't write its query yet (#217): a value that isn't valid for its type.
public struct MongoBuilderProblem: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// A member the builder doesn't edit field by field (#217): an operator or stage it has no form
/// for, kept as JSON text in its place so nothing is lost.
public struct MongoRawMember: Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var key: String
    /// The value's JSON, edited as text.
    public var text: String

    public init(key: String, value: MongoJSON) {
        self.key = key
        self.text = value.display
    }

    public init(key: String, text: String) {
        self.key = key
        self.text = text
    }

    public var value: MongoJSON? { try? MongoJSON.parse(text) }

    func member(_ place: String) throws(MongoBuilderProblem) -> MongoJSON.Member {
        do { return .init(key, try MongoJSON.parse(text)) } catch {
            throw MongoBuilderProblem("\(place) “\(key)”: \(error.errorDescription ?? "invalid JSON")")
        }
    }
}

extension MongoJSON {
    /// How a raw block shows JSON: on one line when short, else pretty-printed.
    public var display: String {
        let flat = inline
        return flat.count <= 60 ? flat : pretty(width: 60)
    }
}

// MARK: - Rules

/// One condition of a filter (#217): a field path, an operator, and a typed value.
public struct MongoFilterRule: Equatable, Sendable, Identifiable {
    public enum Operator: String, CaseIterable, Sendable {
        case equals = "$eq", notEquals = "$ne", greater = "$gt", greaterOrEqual = "$gte", less = "$lt", lessOrEqual = "$lte"
        case inList = "$in", notInList = "$nin", exists = "$exists", regex = "$regex", type = "$type"

        public var symbol: String {
            switch self {
            case .equals: "="
            case .notEquals: "≠"
            case .greater: ">"
            case .greaterOrEqual: "≥"
            case .less: "<"
            case .lessOrEqual: "≤"
            case .inList: "in"
            case .notInList: "not in"
            case .exists: "exists"
            case .regex: "regex"
            case .type: "type"
            }
        }

        var takesValue: Bool { ![.inList, .notInList].contains(self) }
    }

    public var id = UUID()
    public var path: String
    public var op: Operator
    /// The value of =, ≠, >, ≥, <, ≤; true or false for exists; the pattern (and options) for
    /// regex; the alias for type.
    public var value: MongoValue
    /// The values of in and not in.
    public var values: [MongoValue]
    /// `=` written `{"$eq": value}`, as read, instead of the bare value.
    public var explicitEquals: Bool

    public init(path: String = "", op: Operator = .equals, value: MongoValue = .string(""), values: [MongoValue] = [], explicitEquals: Bool = false) {
        self.path = path
        self.op = op
        self.value = value
        self.values = values
        self.explicitEquals = explicitEquals
    }

    /// How the rule is written under its path.
    enum Written: Equatable {
        /// `"status": "paid"`
        case bare(MongoJSON)
        /// `"total": { "$gte": 10 }`
        case operators([MongoJSON.Member])

        var json: MongoJSON {
            switch self {
            case .bare(let value): value
            case .operators(let members): .object(members)
            }
        }

        var operators: [MongoJSON.Member] {
            switch self {
            case .bare(let value): [.init("$eq", value)]
            case .operators(let members): members
            }
        }
    }

    /// The rule's JSON; throws while a value isn't valid.
    func written() throws(MongoBuilderProblem) -> Written {
        func valid(_ value: MongoValue) throws(MongoBuilderProblem) -> MongoJSON {
            guard let json = value.json else { throw MongoBuilderProblem("\(path) \(op.symbol): \(value.problem ?? "invalid value")") }
            return json
        }
        switch op {
        case .equals:
            let json = try valid(value)
            return explicitEquals ? .operators([.init("$eq", json)]) : .bare(json)
        case .notEquals, .greater, .greaterOrEqual, .less, .lessOrEqual:
            return .operators([.init(op.rawValue, try valid(value))])
        case .inList, .notInList:
            var elements: [MongoJSON] = []
            for value in values { elements.append(try valid(value)) }
            return .operators([.init(op.rawValue, .array(elements))])
        case .exists:
            return .operators([.init("$exists", .bool(value.text.mongoTrimmed.lowercased() != "false"))])
        case .regex:
            guard value.options.allSatisfy({ "imsxu".contains($0) }) else { throw MongoBuilderProblem("\(path) regex: the options are i, m, s, x, and u.") }
            return .operators([.init("$regex", .string(value.text))] + (value.options.isEmpty ? [] : [.init("$options", .string(value.options))]))
        case .type:
            guard !value.text.mongoTrimmed.isEmpty else { throw MongoBuilderProblem("\(path) type: choose a type.") }
            return .operators([.init("$type", .string(value.text.mongoTrimmed))])
        }
    }

    /// Changes the operator, carrying the value over where it fits: = to in keeps the value as
    /// the list's first; exists starts at true; type at "string".
    public mutating func setOperator(_ new: Operator) {
        guard new != op else { return }
        let old = op
        op = new
        explicitEquals = false
        switch new {
        case .inList, .notInList:
            if values.isEmpty, old.takesValue, ![.exists, .type].contains(old) { values = [value] }
        case .exists:
            value = .bool(true)
        case .type:
            value = .string("string")
        case .regex:
            value = MongoValue(.string, [.exists, .type].contains(old) ? "" : old.takesValue ? value.text : values.first?.text ?? "", options: "")
        default:
            if !old.takesValue { value = values.first ?? .string("") }
            if [.exists, .type, .regex].contains(old) { value = .string(old == .regex ? value.text : "") }
        }
    }
}

// MARK: - Groups

/// A filter's node (#217): a rule, a nested AND/OR/NOR group, or a raw member.
public enum MongoFilterNode: Equatable, Sendable, Identifiable {
    case rule(MongoFilterRule)
    case group(MongoFilterGroup)
    case raw(MongoRawMember)

    public var id: UUID {
        switch self {
        case .rule(let rule): rule.id
        case .group(let group): group.id
        case .raw(let raw): raw.id
        }
    }
}

/// A filter (#217): the root group of a find's `filter` or a `$match` stage, and the AND/OR/NOR
/// groups inside it. The root's conditions are the members of the filter document (an implicit
/// AND); a root of Any or None is written `{"$or": [...]}` or `{"$nor": [...]}`.
public struct MongoFilterGroup: Equatable, Sendable, Identifiable {
    public enum Kind: String, CaseIterable, Sendable {
        case all = "$and", any = "$or", none = "$nor"

        public var title: String {
            switch self {
            case .all: "All of"
            case .any: "Any of"
            case .none: "None of"
            }
        }
    }

    public var id = UUID()
    public var kind: Kind
    /// An All group written as the members of one object (an element of an `$or` array with
    /// several conditions) rather than `"$and": [...]`. Only inside an Any, None, or explicit All group.
    public var implicit: Bool
    public var children: [MongoFilterNode]

    public init(kind: Kind = .all, implicit: Bool = false, children: [MongoFilterNode] = []) {
        self.kind = kind
        self.implicit = implicit
        self.children = children
    }

    /// Whether the group has no conditions (and so isn't written, unless it's the root).
    public var isEmpty: Bool { children.isEmpty }

    // MARK: Writing

    /// The filter document, as the root group. Throws while a value isn't valid.
    public func filterJSON() throws(MongoBuilderProblem) -> MongoJSON {
        if kind == .all { return .object(try objectMembers()) }
        return try explicitMember().map { .object([$0]) } ?? .object([])
    }

    /// The group's conditions as one object's members: rules on the same path share one
    /// operator object (`"total": { "$gte": 10, "$lt": 100 }`); a rule whose operator is already
    /// there goes into an `$and` at the end. A rule without a field isn't written.
    func objectMembers() throws(MongoBuilderProblem) -> [MongoJSON.Member] {
        var members: [MongoJSON.Member] = []
        var rulePaths: [String: Int] = [:]
        var operators: [Int: [MongoJSON.Member]] = [:]
        var overflow: [MongoJSON] = []
        for child in children {
            switch child {
            case .rule(let rule):
                guard !rule.path.isEmpty else { continue }
                let written = try rule.written()
                guard let index = rulePaths[rule.path] else {
                    rulePaths[rule.path] = members.count
                    if case .operators(let list) = written { operators[members.count] = list }
                    members.append(.init(rule.path, written.json))
                    continue
                }
                var existing = operators[index] ?? [.init("$eq", members[index].value)]
                let adding = written.operators
                if adding.contains(where: { new in existing.contains { $0.key == new.key } }) {
                    overflow.append(.object([.init(rule.path, written.json)]))
                } else {
                    existing += adding
                    operators[index] = existing
                    members[index].value = .object(existing)
                }
            case .group(let group):
                if let member = try group.explicitMember() { members.append(member) }
            case .raw(let raw):
                members.append(try raw.member("Filter"))
            }
        }
        if !overflow.isEmpty { members.append(.init("$and", .array(overflow))) }
        return members
    }

    /// `"$or": [ … ]`, or nil for a group without conditions (MongoDB refuses an empty one).
    func explicitMember() throws(MongoBuilderProblem) -> MongoJSON.Member? {
        var branches: [MongoJSON] = []
        for child in children {
            if let branch = try Self.branch(child) { branches.append(branch) }
        }
        return branches.isEmpty ? nil : .init(kind.rawValue, .array(branches))
    }

    /// A node as one element of an explicit group's array.
    static func branch(_ node: MongoFilterNode) throws(MongoBuilderProblem) -> MongoJSON? {
        switch node {
        case .rule(let rule):
            guard !rule.path.isEmpty else { return nil }
            return .object([.init(rule.path, try rule.written().json)])
        case .group(let group):
            if group.kind == .all, group.implicit { return .object(try group.objectMembers()) }
            return try group.explicitMember().map { .object([$0]) }
        case .raw(let raw):
            return .object([try raw.member("Filter")])
        }
    }

    // MARK: Reading

    /// Reads a filter document into rules and groups. A member the builder can't edit (an
    /// unsupported operator such as `$elemMatch`, `$expr`, or `$text`) stays a raw member, so the
    /// group writes exactly what it read. Nil when `json` isn't an object.
    public static func parse(_ json: MongoJSON) -> MongoFilterGroup? {
        guard case .object(let members) = json else { return nil }
        var root: MongoFilterGroup
        if members.count == 1, members[0].key == "$or" || members[0].key == "$nor", let group = parseExplicit(members[0]),
           (try? group.explicitMember()) == members[0] {
            root = group
        } else {
            root = MongoFilterGroup(kind: .all, children: members.flatMap(parseMember))
        }
        if (try? root.filterJSON()) != json {
            root = MongoFilterGroup(kind: .all, children: members.map { .raw(MongoRawMember(key: $0.key, value: $0.value)) })
        }
        return root
    }

    static func parseMember(_ member: MongoJSON.Member) -> [MongoFilterNode] {
        let raw = [MongoFilterNode.raw(MongoRawMember(key: member.key, value: member.value))]
        if Kind(rawValue: member.key) != nil {
            guard let group = parseExplicit(member), (try? group.explicitMember()) == member else { return raw }
            return [.group(group)]
        }
        guard !member.key.isEmpty, !member.key.hasPrefix("$"), let rules = parseCondition(path: member.key, value: member.value) else { return raw }
        let nodes = rules.map(MongoFilterNode.rule)
        guard (try? MongoFilterGroup(children: nodes).objectMembers()) == [member] else { return raw }
        return nodes
    }

    static func parseExplicit(_ member: MongoJSON.Member) -> MongoFilterGroup? {
        guard let kind = Kind(rawValue: member.key), case .array(let elements) = member.value, !elements.isEmpty else { return nil }
        var children: [MongoFilterNode] = []
        for element in elements {
            guard case .object(let members) = element else { return nil }
            let nodes = members.flatMap(parseMember)
            if members.count == 1, nodes.count == 1 {
                children.append(nodes[0])
            } else {
                children.append(.group(MongoFilterGroup(kind: .all, implicit: true, children: nodes)))
            }
        }
        return MongoFilterGroup(kind: kind, children: children)
    }

    /// `"total": { "$gte": 10, "$lt": 100 }` → two rules; `"status": "paid"` → one; nil for an
    /// operator the builder has no form for.
    static func parseCondition(path: String, value: MongoJSON) -> [MongoFilterRule]? {
        guard case .object(let members) = value, !members.isEmpty, members.allSatisfy({ $0.key.hasPrefix("$") }) else {
            return [MongoFilterRule(path: path, value: MongoValue(json: value))]
        }
        let typed = MongoValue(json: value)
        if typed.kind != .json { return [MongoFilterRule(path: path, value: typed)] }
        var rules: [MongoFilterRule] = []
        var index = 0
        while index < members.count {
            let member = members[index]
            guard let op = MongoFilterRule.Operator(rawValue: member.key) else { return nil }
            switch op {
            case .equals:
                rules.append(MongoFilterRule(path: path, value: MongoValue(json: member.value), explicitEquals: true))
            case .notEquals, .greater, .greaterOrEqual, .less, .lessOrEqual:
                rules.append(MongoFilterRule(path: path, op: op, value: MongoValue(json: member.value)))
            case .inList, .notInList:
                guard case .array(let elements) = member.value else { return nil }
                rules.append(MongoFilterRule(path: path, op: op, values: elements.map { MongoValue(json: $0) }))
            case .exists:
                guard case .bool(let flag) = member.value else { return nil }
                rules.append(MongoFilterRule(path: path, op: .exists, value: .bool(flag)))
            case .type:
                guard case .string(let alias) = member.value else { return nil }
                rules.append(MongoFilterRule(path: path, op: .type, value: .string(alias)))
            case .regex:
                guard case .string(let pattern) = member.value else { return nil }
                var options = ""
                if index + 1 < members.count, members[index + 1].key == "$options" {
                    guard case .string(let text) = members[index + 1].value else { return nil }
                    options = text
                    index += 1
                }
                rules.append(MongoFilterRule(path: path, op: .regex, value: MongoValue(.string, pattern, options: options)))
            }
            index += 1
        }
        return rules
    }

    // MARK: Editing

    /// All rules in the group and its subgroups, depth first.
    public var allRules: [MongoFilterRule] {
        children.flatMap { node -> [MongoFilterRule] in
            switch node {
            case .rule(let rule): [rule]
            case .group(let group): group.allRules
            case .raw: []
            }
        }
    }

    /// Adds `rule` to the root group ("Filter by this value"): a rule on the same path and
    /// operator is replaced, else it's appended.
    public mutating func setRule(_ rule: MongoFilterRule) {
        if let index = children.firstIndex(where: { if case .rule(let existing) = $0 { existing.path == rule.path && existing.op == rule.op } else { false } }) {
            var replacement = rule
            replacement.id = children[index].id
            children[index] = .rule(replacement)
        } else {
            children.append(.rule(rule))
        }
    }
}
