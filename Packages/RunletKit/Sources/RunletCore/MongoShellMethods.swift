import Foundation

/// The methods of the mongosh subset (#220) and how each becomes the JSON form: the collection's
/// methods, their options arguments, find's and aggregate's cursor methods, `explain`, and the
/// database's methods. Each checks its arguments and says what to write instead when one isn't
/// supported; `MongoQuery` checks the result again.
extension MongoShell.Parser {
    typealias Argument = (MongoJSON, MongoShell.Token)
    typealias Translation = MongoShell.Translation

    /// The JSON query being built: the collection, the operation, and its fields, written in one
    /// order whatever order the mongosh had them in.
    struct Query {
        var collection: String
        var operation: String
        var fields: [String: MongoJSON] = [:]

        static let order = ["field", "filter", "projection", "sort", "skip", "limit", "pipeline", "documents", "update", "replacement", "operations", "keys",
                            "unique", "indexes", "index", "to", "dropTarget", "options", "command", "upsert", "returnDocument", "arrayFilters", "ordered",
                            "collation", "hint", "maxTimeMS", "allowDiskUse", "explain"]

        var translation: Translation {
            var members: [MongoJSON.Member] = [.init("collection", .string(collection)), .init("operation", .string(operation))]
            for key in Self.order { if let value = fields[key] { members.append(.init(key, value)) } }
            return Translation(json: .object(members), collection: collection, operation: operation)
        }
    }

    /// What an option's value must be.
    enum OptionKind {
        case object, bool, wholeNumber, hint, array, returnDocument, string
        /// Kept as written; the server checks it.
        case any
        /// Accepted and left out: it changes nothing Runlet shows (batchSize) or nothing at all
        /// (createIndex's background since MongoDB 4.2).
        case ignored

        var description: String {
            switch self {
            case .object: "an object"
            case .bool: "true or false"
            case .wholeNumber: "a whole number from 0"
            case .hint: "an index's name or its keys object"
            case .array: "an array"
            case .returnDocument: "\"before\" or \"after\""
            case .string: "a string"
            case .any, .ignored: "anything"
            }
        }

        func accepts(_ value: MongoJSON) -> Bool {
            switch (self, value) {
            case (.object, .object), (.bool, .bool), (.array, .array), (.hint, .object), (.any, _), (.ignored, _): true
            case (.string, .string(let text)): !text.isEmpty
            case (.wholeNumber, .number(let literal)): literal.allSatisfy(\.isNumber)
            case (.hint, .string(let name)): !name.isEmpty
            case (.returnDocument, .string(let text)): text == "before" || text == "after"
            default: false
            }
        }
    }

    /// Options Runlet never takes, and why.
    static let refusedOptions: [String: String] = [
        "comment": "Runlet sets each operation's comment itself, so Stop can find it on the server: leave comment out.",
        "writeConcern": "Runlet writes with the connection's write concern: leave writeConcern out.",
        "readConcern": "Runlet reads with the connection's read concern: leave readConcern out.",
        "readPreference": "Runlet reads with the connection's read preference: set it in the connection.",
        "session": "Sessions and transactions aren't supported.",
        "let": "let isn't supported: write the values into the query.",
        "bypassDocumentValidation": "Runlet doesn't bypass document validation.",
    ]

    // MARK: Helpers

    func object(_ argument: Argument?, _ message: String) throws(MongoShell.Problem) -> MongoJSON? {
        guard let argument else { return nil }
        guard case .object = argument.0 else { throw problem(message, at: argument.1) }
        return argument.0
    }

    func noMore(_ arguments: [Argument], than count: Int, _ message: String) throws(MongoShell.Problem) {
        if arguments.count > count { throw problem(message, at: arguments[count].1) }
    }

    /// The members of an options argument, checked against `kinds`; ignored ones are left out.
    func options(_ argument: Argument?, of method: String, _ kinds: [String: OptionKind]) throws(MongoShell.Problem) -> [String: MongoJSON] {
        guard let argument else { return [:] }
        guard case .object(let members) = argument.0 else {
            throw problem("\(method)'s options are an object, such as {\(kinds.keys.sorted().first ?? "upsert"): …}.", at: argument.1)
        }
        var picked: [String: MongoJSON] = [:]
        for member in members {
            if let reason = Self.refusedOptions[member.key] { throw problem("\(method)'s option \(member.key): \(reason)", at: argument.1) }
            guard let kind = kinds[member.key] else {
                let taken = kinds.filter { if case .ignored = $0.value { false } else { true } }.keys.sorted()
                throw problem("\(method)'s option \(member.key) isn't supported." + (taken.isEmpty ? " It takes no options." : " It takes \(taken.joined(separator: ", ")).") , at: argument.1)
            }
            guard kind.accepts(member.value) else { throw problem("\(method)'s option \(member.key) is \(kind.description).", at: argument.1) }
            if case .ignored = kind { continue }
            picked[member.key] = member.value
        }
        return picked
    }

    /// Puts `values` into the query, refusing one given twice (an option and a cursor method).
    func merge(_ values: [String: MongoJSON], into query: inout Query, at token: MongoShell.Token) throws(MongoShell.Problem) {
        for (key, value) in values {
            guard query.fields[key] == nil else { throw problem("\(key) is given twice: keep one.", at: token) }
            query.fields[key] = value
        }
    }

    /// An update: update operators, or a pipeline of stages. A document without operators would
    /// replace the matched one, as mongosh refuses too.
    func update(_ argument: Argument, of method: String) throws(MongoShell.Problem) -> MongoJSON {
        switch argument.0 {
        case .array(let stages):
            guard !stages.isEmpty, stages.allSatisfy({ $0.members?.count == 1 }) else {
                throw problem("An update pipeline is an array of stages, each an object with one stage, such as [{$set: {total: {$sum: \"$items.price\"}}}].", at: argument.1)
            }
            return argument.0
        case .object(let members) where !members.isEmpty:
            guard members.allSatisfy({ $0.key.hasPrefix("$") }) else {
                throw problem("\(method)'s update uses update operators, as in {$set: {status: \"paid\"}}. To replace the whole document, use replaceOne.", at: argument.1)
            }
            return argument.0
        default:
            throw problem("\(method)'s update is an object of update operators, as in {$set: {status: \"paid\"}}, or a pipeline.", at: argument.1)
        }
    }

    /// A replacement: a whole document, without update operators.
    func replacement(_ argument: Argument, of method: String) throws(MongoShell.Problem) -> MongoJSON {
        guard case .object(let members) = argument.0 else { throw problem("\(method)'s replacement is a document, such as {name: \"Sprocket\", price: 4}.", at: argument.1) }
        guard !members.contains(where: { $0.key.hasPrefix("$") }) else {
            throw problem("\(method)'s replacement is a whole document, without update operators: to change fields, use updateOne.", at: argument.1)
        }
        return argument.0
    }

    /// The required filter of a write, whose `{}` matches everything.
    func requiredFilter(_ arguments: [Argument], of call: Call) throws(MongoShell.Problem) -> MongoJSON {
        guard let filter = try object(arguments.first, "\(call.name)'s filter is an object, such as {status: \"cancelled\"}.") else {
            throw problem("\(call.name) needs a filter, as in \(call.name)({status: \"cancelled\"}); {} matches every document.", at: token(after: call.token))
        }
        return filter
    }

    static let writeOptions: [String: OptionKind] = ["upsert": .bool, "arrayFilters": .array, "collation": .object, "hint": .hint]
    static let methodList = "find, findOne, aggregate, countDocuments, estimatedDocumentCount, count, distinct, insertOne, insertMany, updateOne, updateMany, replaceOne, deleteOne, deleteMany, findOneAndUpdate, findOneAndReplace, findOneAndDelete, bulkWrite, createIndex, createIndexes, getIndexes, dropIndex, dropIndexes, drop, renameCollection, or stats"

    // MARK: The collection's methods

    func collectionMethod(_ collection: String, _ first: Call, chain: [Call]) throws(MongoShell.Problem) -> Translation {
        var call = first
        var chain = chain
        var explain: MongoJSON?
        // db.orders.explain([verbosity]).find(…) or .aggregate(…).
        if call.name == "explain" {
            explain = try explainValue(call)
            guard let next = chain.first, next.name == "find" || next.name == "aggregate" else {
                throw problem("explain() goes before find() or aggregate(), as in db.\(collection).explain().find({…}).", at: chain.first?.token ?? call.token)
            }
            call = next
            chain.removeFirst()
        }
        var query = Query(collection: collection, operation: call.name)
        let args = call.arguments
        let filterMessage = "\(call.name)'s filter is an object, such as {status: \"paid\"}."
        switch call.name {
        case "find":
            try noMore(args, than: 3, "find takes a filter, a projection, and options.")
            query.fields["filter"] = try object(args.first, filterMessage)
            query.fields["projection"] = try object(args.dropFirst().first, "find's projection is an object, such as {status: 1, total: 1}.")
            if let options = args.dropFirst(2).first {
                try merge(try self.options(options, of: "find", ["sort": .object, "skip": .wholeNumber, "limit": .wholeNumber, "projection": .object, "collation": .object,
                                                                  "hint": .hint, "maxTimeMS": .wholeNumber, "allowDiskUse": .bool, "batchSize": .ignored]), into: &query, at: options.1)
            }
            try cursor(&query, chain, explain: explain)
            return query.translation
        case "findOne":
            try noMore(args, than: 3, "findOne takes a filter, a projection, and options.")
            query.fields["filter"] = try object(args.first, filterMessage)
            query.fields["projection"] = try object(args.dropFirst().first, "findOne's projection is an object, such as {status: 1, total: 1}.")
            if let options = args.dropFirst(2).first {
                try merge(try self.options(options, of: "findOne", ["projection": .object, "sort": .object, "collation": .object, "hint": .hint, "maxTimeMS": .wholeNumber]), into: &query, at: options.1)
            }
        case "aggregate":
            guard let pipeline = args.first, case .array(let stages) = pipeline.0 else {
                throw problem("aggregate takes one array of stages, as in aggregate([{$match: {status: \"paid\"}}]).", at: args.first?.1 ?? token(after: call.token))
            }
            try noMore(args, than: 2, "aggregate takes an array of stages and options.")
            for stage in stages where stage.members?.count != 1 {
                throw problem("Each stage of the pipeline is an object with one stage, such as {$match: {…}}.", at: pipeline.1)
            }
            query.fields["pipeline"] = pipeline.0
            if let options = args.dropFirst().first {
                var picked = try self.options(options, of: "aggregate", ["allowDiskUse": .bool, "collation": .object, "hint": .hint, "maxTimeMS": .wholeNumber,
                                                                         "explain": .bool, "batchSize": .ignored, "cursor": .ignored])
                if picked["explain"] == .bool(false) { picked["explain"] = nil }
                try merge(picked, into: &query, at: options.1)
            }
            try aggregateCursor(&query, chain, explain: explain, at: call.token)
            return query.translation
        case "countDocuments", "count":
            // count() is countDocuments(), which counts exactly (#220).
            query.operation = "countDocuments"
            try noMore(args, than: 2, "\(call.name) takes a filter and options.")
            let filter = try object(args.first, filterMessage)
            query.fields["filter"] = filter
            if let options = args.dropFirst().first {
                var picked = try self.options(options, of: call.name, ["skip": .wholeNumber, "limit": .wholeNumber, "collation": .object, "hint": .hint, "maxTimeMS": .wholeNumber])
                let skip = picked.removeValue(forKey: "skip")
                let limit = picked.removeValue(forKey: "limit")
                if skip != nil || limit != nil {
                    // Counting part of the matches is the aggregation drivers run for countDocuments.
                    query.operation = "aggregate"
                    query.fields["filter"] = nil
                    var stages: [MongoJSON] = [.object([.init("$match", filter ?? .object([]))])]
                    if let skip { stages.append(.object([.init("$skip", skip)])) }
                    if let limit { stages.append(.object([.init("$limit", limit)])) }
                    stages.append(.object([.init("$count", .string("count"))]))
                    query.fields["pipeline"] = .array(stages)
                }
                try merge(picked, into: &query, at: options.1)
            }
        case "estimatedDocumentCount":
            try noMore(args, than: 1, "estimatedDocumentCount takes options only.")
            if let options = args.first {
                try merge(try self.options(options, of: "estimatedDocumentCount", ["maxTimeMS": .wholeNumber]), into: &query, at: options.1)
            }
        case "distinct":
            guard let field = args.first else { throw problem("distinct needs a field's name, as in distinct(\"status\").", at: token(after: call.token)) }
            guard case .string(let name) = field.0, !name.isEmpty else {
                throw problem("distinct's first argument is a field's name in quotes, as in distinct(\"status\").", at: field.1)
            }
            try noMore(args, than: 3, "distinct takes a field's name, a filter, and options.")
            query.fields["field"] = .string(name)
            query.fields["filter"] = try object(args.dropFirst().first, filterMessage)
            if let options = args.dropFirst(2).first {
                try merge(try self.options(options, of: "distinct", ["collation": .object, "maxTimeMS": .wholeNumber]), into: &query, at: options.1)
            }
        case "insertOne":
            guard let document = try object(args.first, "insertOne takes one document, such as {name: \"Sprocket\"}.") else {
                throw problem("insertOne takes one document, such as {name: \"Sprocket\"}.", at: token(after: call.token))
            }
            try noMore(args, than: 2, "insertOne takes a document and options.")
            _ = try options(args.dropFirst().first, of: "insertOne", [:])
            query.fields["documents"] = .array([document])
        case "insertMany":
            guard let documents = args.first, case .array(let list) = documents.0 else {
                throw problem("insertMany takes an array of documents, such as [{name: \"Sprocket\"}, {name: \"Gear\"}].", at: args.first?.1 ?? token(after: call.token))
            }
            for document in list where document.members == nil { throw problem("Each document of insertMany is an object.", at: documents.1) }
            try noMore(args, than: 2, "insertMany takes an array of documents and options.")
            query.fields["documents"] = documents.0
            try merge(try options(args.dropFirst().first, of: "insertMany", ["ordered": .bool]), into: &query, at: call.token)
        case "insert":
            // The legacy insert(): one document or an array of them.
            guard let documents = args.first else { throw problem("insert takes a document or an array of documents.", at: token(after: call.token)) }
            try noMore(args, than: 2, "insert takes documents and options.")
            switch documents.0 {
            case .object:
                query.operation = "insertOne"
                query.fields["documents"] = .array([documents.0])
                _ = try options(args.dropFirst().first, of: "insert", [:])
            case .array(let list) where list.allSatisfy({ $0.members != nil }) && !list.isEmpty:
                query.operation = "insertMany"
                query.fields["documents"] = documents.0
                try merge(try options(args.dropFirst().first, of: "insert", ["ordered": .bool]), into: &query, at: call.token)
            default:
                throw problem("insert takes a document or an array of documents.", at: documents.1)
            }
        case "updateOne", "updateMany":
            guard args.count >= 2 else {
                throw problem("\(call.name) takes a filter and an update, as in \(call.name)({status: \"pending\"}, {$set: {status: \"paid\"}}).", at: args.last?.1 ?? token(after: call.token))
            }
            try noMore(args, than: 3, "\(call.name) takes a filter, an update, and options.")
            query.fields["filter"] = try object(args[0], filterMessage)
            query.fields["update"] = try update(args[1], of: call.name)
            try merge(try options(args.dropFirst(2).first, of: call.name, Self.writeOptions), into: &query, at: call.token)
        case "update":
            // The legacy update(): {multi: true} updates every match, and a document without
            // operators replaces the match, as it did in the mongo shell.
            guard args.count >= 2 else { throw problem("update takes a filter and an update.", at: args.last?.1 ?? token(after: call.token)) }
            try noMore(args, than: 3, "update takes a filter, an update, and options; write the options as an object, such as {upsert: true, multi: true}.")
            query.fields["filter"] = try object(args[0], filterMessage)
            var picked = try options(args.dropFirst(2).first, of: "update", Self.writeOptions.merging(["multi": .bool]) { first, _ in first })
            let multi = picked.removeValue(forKey: "multi") == .bool(true)
            if let members = args[1].0.members, !members.isEmpty, !members.contains(where: { $0.key.hasPrefix("$") }) {
                guard !multi else { throw problem("A replacement document can't update several documents: use update operators, such as {$set: …}, with multi.", at: args[1].1) }
                query.operation = "replaceOne"
                query.fields["replacement"] = try replacement(args[1], of: "update")
                picked["arrayFilters"] = nil
            } else {
                query.operation = multi ? "updateMany" : "updateOne"
                query.fields["update"] = try update(args[1], of: "update")
            }
            try merge(picked, into: &query, at: call.token)
        case "replaceOne":
            guard args.count >= 2 else {
                throw problem("replaceOne takes a filter and a document, as in replaceOne({_id: 7}, {name: \"Gear\", price: 4}).", at: args.last?.1 ?? token(after: call.token))
            }
            try noMore(args, than: 3, "replaceOne takes a filter, a document, and options.")
            query.fields["filter"] = try object(args[0], filterMessage)
            query.fields["replacement"] = try replacement(args[1], of: "replaceOne")
            try merge(try options(args.dropFirst(2).first, of: "replaceOne", ["upsert": .bool, "collation": .object, "hint": .hint]), into: &query, at: call.token)
        case "deleteOne", "deleteMany":
            query.fields["filter"] = try requiredFilter(args, of: call)
            try noMore(args, than: 2, "\(call.name) takes a filter and options.")
            try merge(try options(args.dropFirst().first, of: call.name, ["collation": .object, "hint": .hint]), into: &query, at: call.token)
        case "remove":
            // The legacy remove(): every match, or one with justOne.
            query.fields["filter"] = try requiredFilter(args, of: call)
            try noMore(args, than: 2, "remove takes a filter and justOne.")
            var justOne = false
            if let second = args.dropFirst().first {
                if case .bool(let flag) = second.0 {
                    justOne = flag
                } else {
                    var picked = try options(second, of: "remove", ["justOne": .bool, "collation": .object, "hint": .hint])
                    justOne = picked.removeValue(forKey: "justOne") == .bool(true)
                    try merge(picked, into: &query, at: second.1)
                }
            }
            query.operation = justOne ? "deleteOne" : "deleteMany"
        case "findOneAndUpdate", "findOneAndReplace":
            guard args.count >= 2 else {
                throw problem("\(call.name) takes a filter and \(call.name == "findOneAndUpdate" ? "an update" : "a document").", at: args.last?.1 ?? token(after: call.token))
            }
            try noMore(args, than: 3, "\(call.name) takes a filter, \(call.name == "findOneAndUpdate" ? "an update" : "a document"), and options.")
            query.fields["filter"] = try object(args[0], filterMessage)
            if call.name == "findOneAndUpdate" {
                query.fields["update"] = try update(args[1], of: call.name)
            } else {
                query.fields["replacement"] = try replacement(args[1], of: call.name)
            }
            var kinds: [String: OptionKind] = ["projection": .object, "sort": .object, "upsert": .bool, "returnDocument": .returnDocument, "returnNewDocument": .bool,
                                               "collation": .object, "hint": .hint, "maxTimeMS": .wholeNumber]
            if call.name == "findOneAndUpdate" { kinds["arrayFilters"] = .array }
            try merge(try returnDocument(try options(args.dropFirst(2).first, of: call.name, kinds), at: call.token), into: &query, at: call.token)
        case "findOneAndDelete":
            query.fields["filter"] = try requiredFilter(args, of: call)
            try noMore(args, than: 2, "findOneAndDelete takes a filter and options.")
            try merge(try options(args.dropFirst().first, of: "findOneAndDelete", ["projection": .object, "sort": .object, "collation": .object, "hint": .hint, "maxTimeMS": .wholeNumber]),
                      into: &query, at: call.token)
        case "bulkWrite":
            guard let operations = args.first, case .array(let list) = operations.0, !list.isEmpty else {
                throw problem("bulkWrite takes an array of operations, such as [{insertOne: {document: {…}}}, {deleteOne: {filter: {…}}}].", at: args.first?.1 ?? token(after: call.token))
            }
            try noMore(args, than: 2, "bulkWrite takes an array of operations and options.")
            for item in list { try bulkOperation(item, at: operations.1) }
            query.fields["operations"] = operations.0
            try merge(try options(args.dropFirst().first, of: "bulkWrite", ["ordered": .bool]), into: &query, at: call.token)
        case "createIndex":
            guard let keys = args.first, let members = keys.0.members, !members.isEmpty else {
                throw problem("createIndex takes the index's keys, as in createIndex({email: 1}).", at: args.first?.1 ?? token(after: call.token))
            }
            try noMore(args, than: 2, "createIndex takes keys and options; commitQuorum isn't supported.")
            query.fields["keys"] = keys.0
            var picked = try options(args.dropFirst().first, of: "createIndex", Self.indexKinds)
            if picked["name"] == nil { picked["name"] = .string(try Self.indexName(members, problem: { message in problem(message, at: keys.1) })) }
            query.fields["options"] = .object(Self.sortedIndexOptions(picked))
        case "createIndexes":
            guard let list = args.first, case .array(let patterns) = list.0, !patterns.isEmpty, patterns.allSatisfy({ $0.members?.isEmpty == false }) else {
                throw problem("createIndexes takes an array of keys objects, as in createIndexes([{email: 1}, {placed_at: -1}]).", at: args.first?.1 ?? token(after: call.token))
            }
            try noMore(args, than: 2, "createIndexes takes keys and options; commitQuorum isn't supported.")
            let picked = try options(args.dropFirst().first, of: "createIndexes", Self.indexKinds)
            if picked["name"] != nil, patterns.count > 1 { throw problem("One name can't name several indexes: create them one at a time.", at: args[1].1) }
            var indexes: [MongoJSON] = []
            for pattern in patterns {
                var index = picked
                if index["name"] == nil { index["name"] = .string(try Self.indexName(pattern.members ?? [], problem: { message in problem(message, at: list.1) })) }
                indexes.append(.object([.init("key", pattern)] + Self.sortedIndexOptions(index)))
            }
            query.fields["indexes"] = .array(indexes)
        case "getIndexes":
            if let extra = args.first { throw problem("getIndexes() takes no arguments.", at: extra.1) }
        case "dropIndex":
            guard let index = args.first, args.count == 1 else {
                throw problem("dropIndex takes one index: its name, as in dropIndex(\"email_1\"), or its keys, as in dropIndex({email: 1}).", at: args.dropFirst().first?.1 ?? token(after: call.token))
            }
            switch index.0 {
            case .string(let name) where !name.isEmpty && name != "*": query.fields["index"] = index.0
            case .object(let members) where !members.isEmpty: query.fields["index"] = index.0
            case .string("*"): throw problem("dropIndex drops one index: use dropIndexes() for all of them.", at: index.1)
            default: throw problem("dropIndex takes an index's name or its keys object.", at: index.1)
            }
        case "dropIndexes":
            try noMore(args, than: 1, "dropIndexes takes an index's name or an array of names.")
            switch args.first?.0 {
            case nil: query.fields["index"] = .string("*")
            case .string(let name)? where !name.isEmpty: query.fields["index"] = .string(name)
            case .array(let names)? where !names.isEmpty && names.allSatisfy({ ($0.stringValue ?? "").isEmpty == false }): query.fields["index"] = .array(names)
            default: throw problem("dropIndexes takes nothing (every index but _id's), an index's name, or an array of names.", at: args[0].1)
            }
        case "drop":
            if let extra = args.first { throw problem("drop() takes no arguments.", at: extra.1) }
        case "renameCollection":
            guard let target = args.first, case .string(let name) = target.0, !name.isEmpty else {
                throw problem("renameCollection takes the new name, as in renameCollection(\"orders_2025\").", at: args.first?.1 ?? token(after: call.token))
            }
            try noMore(args, than: 2, "renameCollection takes the new name and dropTarget.")
            query.fields["to"] = .string(name)
            if let drop = args.dropFirst().first {
                guard case .bool(let flag) = drop.0 else { throw problem("renameCollection's dropTarget is true or false.", at: drop.1) }
                if flag { query.fields["dropTarget"] = .bool(true) }
            }
        case "stats":
            if let extra = args.first { throw problem("stats() takes no options in Runlet: sizes are in bytes.", at: extra.1) }
            query.operation = "collStats"
        case "ensureIndex":
            throw problem("ensureIndex() was removed from mongosh: use createIndex().", at: call.token)
        case "mapReduce":
            throw problem("mapReduce runs JavaScript, which MongoDB tabs never run: use aggregate().", at: call.token)
        default:
            throw problem("\(call.name)() isn't supported: a mongosh query uses \(Self.methodList).", at: call.token)
        }
        if let link = chain.first {
            if ["find", "aggregate"].contains(link.name) { throw problem("Only one query runs at a time: select the one to run.", at: link.token) }
            throw problem(".\(link.name)() works after find() and aggregate() only.", at: link.token)
        }
        if explain != nil { throw problem("explain() works with find() and aggregate() only.", at: call.token) }
        return query.translation
    }

    /// `returnNewDocument` (the mongo shell's) as `returnDocument`.
    func returnDocument(_ options: [String: MongoJSON], at token: MongoShell.Token) throws(MongoShell.Problem) -> [String: MongoJSON] {
        var options = options
        if let legacy = options.removeValue(forKey: "returnNewDocument") {
            guard options["returnDocument"] == nil else { throw problem("Give returnDocument or returnNewDocument, not both.", at: token) }
            options["returnDocument"] = .string(legacy == .bool(true) ? "after" : "before")
        }
        return options
    }

    /// `explain()`'s verbosity: none is the query planner's; true is allPlansExecution, as in mongosh.
    func explainValue(_ call: Call) throws(MongoShell.Problem) -> MongoJSON {
        try noMore(call.arguments, than: 1, "explain takes one verbosity.")
        switch call.arguments.first?.0 {
        case nil, .bool(false)?: return .bool(true)
        case .bool(true)?: return .string("allPlansExecution")
        case .string(let verbosity)? where MongoQuery.explainVerbosities.contains(verbosity): return .string(verbosity)
        default: throw problem("explain takes queryPlanner, executionStats, or allPlansExecution.", at: call.arguments[0].1)
        }
    }

    /// find's cursor methods: sort, skip, limit, collation, hint, maxTimeMS, allowDiskUse, and
    /// explain; batchSize, pretty, and toArray change nothing Runlet shows; count() turns the find
    /// into countDocuments.
    func cursor(_ query: inout Query, _ chain: [Call], explain: MongoJSON?) throws(MongoShell.Problem) {
        var counted: Call?
        if let explain { query.fields["explain"] = explain }
        for link in chain {
            let args = link.arguments
            func one(_ kind: OptionKind, _ example: String) throws(MongoShell.Problem) -> MongoJSON {
                guard args.count == 1, kind.accepts(args[0].0) else {
                    throw problem(".\(link.name)() takes \(kind.description), as in .\(link.name)(\(example)).", at: args.dropFirst().first?.1 ?? args.first?.1 ?? link.token)
                }
                return args[0].0
            }
            var value: MongoJSON?
            switch link.name {
            case "sort": value = try one(.object, "{placed_at: -1}")
            case "skip", "limit": value = try one(.wholeNumber, "20")
            case "collation": value = try one(.object, "{locale: \"en\", strength: 2}")
            case "hint": value = try one(.hint, "{status: 1}")
            case "maxTimeMS": value = try one(.wholeNumber, "5000")
            case "allowDiskUse":
                value = args.isEmpty ? .bool(true) : try one(.bool, "true")
            case "explain":
                guard query.fields["explain"] == nil else { throw problem("explain is given twice: keep one.", at: link.token) }
                value = try explainValue(link)
            case "batchSize":
                _ = try one(.wholeNumber, "100")
                continue
            case "pretty", "toArray":
                if let extra = args.first { throw problem(".\(link.name)() takes no arguments.", at: extra.1) }
                continue
            case "count":
                if let extra = args.first { throw problem("count() takes no arguments here: it counts the find's matches.", at: extra.1) }
                counted = link
                continue
            case "comment":
                throw problem(".comment(): " + (Self.refusedOptions["comment"] ?? ""), at: link.token)
            case "forEach", "map":
                throw problem(".\(link.name)() runs JavaScript, which MongoDB tabs never run: the result shows every document.", at: link.token)
            case "size", "itcount", "length":
                throw problem(".\(link.name)() isn't supported: write countDocuments({…}).", at: link.token)
            default:
                throw problem(".\(link.name)() isn't supported after find(): use .sort(), .skip(), .limit(), .collation(), .hint(), .maxTimeMS(), .allowDiskUse(), or .explain().", at: link.token)
            }
            guard query.fields[link.name] == nil else { throw problem("\(link.name) is given twice: keep one.", at: link.token) }
            query.fields[link.name] = value
        }
        if let counted {
            // find(…).count() is countDocuments: mongosh's count ignores skip, limit, sort, and the
            // projection; skip and limit would make that a surprise, so they're refused.
            for key in ["skip", "limit", "explain"] where query.fields[key] != nil {
                throw problem("count() ignores \(key), as in mongosh: write countDocuments(filter, {skip: …, limit: …}) to count part of the matches.", at: counted.token)
            }
            query.operation = "countDocuments"
            query.fields["projection"] = nil
            query.fields["sort"] = nil
            query.fields["allowDiskUse"] = nil
        }
    }

    /// aggregate's cursor: explain, and pretty and toArray, which change nothing Runlet shows.
    func aggregateCursor(_ query: inout Query, _ chain: [Call], explain: MongoJSON?, at token: MongoShell.Token) throws(MongoShell.Problem) {
        if let explain {
            guard query.fields["explain"] == nil else { throw problem("explain is given twice: keep one.", at: token) }
            query.fields["explain"] = explain
        }
        for link in chain {
            switch link.name {
            case "pretty", "toArray":
                if let extra = link.arguments.first { throw problem(".\(link.name)() takes no arguments.", at: extra.1) }
            case "explain":
                guard query.fields["explain"] == nil else { throw problem("explain is given twice: keep one.", at: link.token) }
                query.fields["explain"] = try explainValue(link)
            case "forEach", "map":
                throw problem(".\(link.name)() runs JavaScript, which MongoDB tabs never run: the result shows every document.", at: link.token)
            default:
                throw problem(".\(link.name)() isn't supported after aggregate(): put it in the pipeline, as a stage such as {$limit: 20}.", at: link.token)
            }
        }
    }

    /// One of bulkWrite's operations, in mongosh's form: `{insertOne: {document: …}}`,
    /// `{updateOne: {filter: …, update: …}}`, … The JSON form takes the same shape.
    func bulkOperation(_ item: MongoJSON, at token: MongoShell.Token) throws(MongoShell.Problem) {
        guard let members = item.members, members.count == 1, let body = members[0].value.members else {
            throw problem("Each bulkWrite operation is an object with one of insertOne, updateOne, updateMany, replaceOne, deleteOne, or deleteMany.", at: token)
        }
        let name = members[0].key
        let allowed: Set<String>
        switch name {
        case "insertOne": allowed = ["document"]
        case "updateOne", "updateMany": allowed = ["filter", "update", "upsert", "arrayFilters", "collation", "hint"]
        case "replaceOne": allowed = ["filter", "replacement", "upsert", "collation", "hint"]
        case "deleteOne", "deleteMany": allowed = ["filter", "collation", "hint"]
        default: throw problem("bulkWrite takes insertOne, updateOne, updateMany, replaceOne, deleteOne, and deleteMany, not \(name).", at: token)
        }
        for member in body where !allowed.contains(member.key) {
            if let reason = Self.refusedOptions[member.key] { throw problem("bulkWrite's \(name): \(reason)", at: token) }
            throw problem("bulkWrite's \(name) takes \(allowed.sorted().joined(separator: ", ")), not \(member.key).", at: token)
        }
        let fields = Dictionary(body.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        switch name {
        case "insertOne":
            guard fields["document"]?.members != nil else { throw problem("bulkWrite's insertOne takes {document: {…}}.", at: token) }
        case "updateOne", "updateMany":
            guard fields["filter"]?.members != nil, let update = fields["update"] else { throw problem("bulkWrite's \(name) takes {filter: {…}, update: {…}}.", at: token) }
            _ = try self.update((update, token), of: "bulkWrite's \(name)")
        case "replaceOne":
            guard fields["filter"]?.members != nil, let replacement = fields["replacement"] else { throw problem("bulkWrite's replaceOne takes {filter: {…}, replacement: {…}}.", at: token) }
            _ = try self.replacement((replacement, token), of: "bulkWrite's replaceOne")
        default:
            guard fields["filter"]?.members != nil else { throw problem("bulkWrite's \(name) takes {filter: {…}}; {} matches every document.", at: token) }
        }
    }

    // MARK: Indexes

    /// createIndex's options (`MongoQuery.indexOptions`); background has done nothing since
    /// MongoDB 4.2, so it's accepted and left out.
    static let indexKinds: [String: OptionKind] = ["name": .string, "unique": .bool, "sparse": .bool, "expireAfterSeconds": .wholeNumber, "partialFilterExpression": .object,
                                                   "collation": .object, "hidden": .bool, "weights": .object, "default_language": .string, "language_override": .string,
                                                   "wildcardProjection": .object, "2dsphereIndexVersion": .wholeNumber, "bits": .wholeNumber, "min": .any, "max": .any,
                                                   "background": .ignored]

    /// MongoDB's name for an index on `keys`, as mongosh makes it: `email_1`, `status_1_placed_at_-1`, `body_text`.
    static func indexName(_ keys: [MongoJSON.Member], problem: (String) -> MongoShell.Problem) throws(MongoShell.Problem) -> String {
        var parts: [String] = []
        for member in keys {
            switch member.value {
            case .number(let literal):
                let number = Double(literal) ?? 0
                parts.append(member.key + "_" + (number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : literal))
            case .string(let kind): parts.append(member.key + "_" + kind)
            default: throw problem("An index's keys are 1, -1, or a kind such as \"text\" or \"2dsphere\": \(member.key) isn't.")
            }
        }
        return parts.joined(separator: "_")
    }

    /// Index options with the name first.
    static func sortedIndexOptions(_ options: [String: MongoJSON]) -> [MongoJSON.Member] {
        let names = options.keys.sorted { ($0 == "name" ? 0 : 1, $0) < ($1 == "name" ? 0 : 1, $1) }
        return names.map { MongoJSON.Member($0, options[$0]!) }
    }

    // MARK: The database's methods

    func databaseMethod(_ call: Call, chain: [Call]) throws(MongoShell.Problem) -> Translation {
        if let link = chain.first { throw problem(".\(link.name)() isn't supported after db.\(call.name)().", at: link.token) }
        let args = call.arguments
        func none() throws(MongoShell.Problem) {
            if let extra = args.first { throw problem("db.\(call.name)() takes no arguments here.", at: extra.1) }
        }
        switch call.name {
        case "getCollectionNames", "getCollectionInfos":
            if let extra = args.first { throw problem("db.\(call.name)() takes no filter in Runlet: filter the result table instead.", at: extra.1) }
            return metadata("listCollections")
        case "createCollection":
            guard let name = args.first, case .string(let collection) = name.0, MongoQuery.isValidCollectionName(collection) else {
                throw problem("createCollection takes the new collection's name, as in db.createCollection(\"orders\").", at: args.first?.1 ?? token(after: call.token))
            }
            try noMore(args, than: 2, "createCollection takes a name and options.")
            var query = Query(collection: collection, operation: "createCollection")
            let kinds: [String: OptionKind] = ["capped": .bool, "size": .wholeNumber, "max": .wholeNumber, "validator": .object, "validationLevel": .string,
                                               "validationAction": .string, "timeseries": .object, "expireAfterSeconds": .wholeNumber, "collation": .object, "clusteredIndex": .object]
            let picked = try options(args.dropFirst().first, of: "createCollection", kinds)
            // In the order written.
            let options = (args.dropFirst().first?.0.members ?? []).filter { picked[$0.key] != nil }
            if !options.isEmpty { query.fields["options"] = .object(options) }
            return query.translation
        case "stats":
            if let extra = args.first { throw problem("db.stats() takes no options in Runlet: sizes are in bytes.", at: extra.1) }
            return metadata("dbStats")
        case "serverStatus":
            try none()
            return metadata("runCommand", [.init("command", .object([.init("serverStatus", .number("1"))]))])
        case "version":
            try none()
            return metadata("runCommand", [.init("command", .object([.init("buildInfo", .number("1"))]))])
        case "hello", "isMaster":
            try none()
            return metadata("runCommand", [.init("command", .object([.init(call.name, .number("1"))]))])
        case "runCommand", "adminCommand":
            return try runCommand(call)
        case "dropDatabase":
            throw problem("Name the database, so Runlet can check it's the connection's: db.getSiblingDB(\"shop\").dropDatabase().", at: call.token)
        case "eval":
            throw problem("db.eval() runs JavaScript, which MongoDB tabs never run.", at: call.token)
        case _ where Self.collectionMethods.contains(call.name):
            throw problem("\(call.name)() is a collection's method: write db.<collection>.\(call.name)(…), as in db.orders.\(call.name)(…).", at: call.token)
        default:
            throw problem("db.\(call.name)() isn't supported. On the database, Runlet runs getCollectionNames, getCollectionInfos, createCollection, stats, serverStatus, version, hello, runCommand, and adminCommand.", at: call.token)
        }
    }

    static let collectionMethods: Set<String> = ["find", "findOne", "aggregate", "countDocuments", "estimatedDocumentCount", "count", "distinct", "insertOne", "insertMany",
                                                 "updateOne", "updateMany", "replaceOne", "deleteOne", "deleteMany", "findOneAndUpdate", "findOneAndReplace",
                                                 "findOneAndDelete", "bulkWrite", "createIndex", "createIndexes", "getIndexes", "dropIndex", "dropIndexes", "drop",
                                                 "renameCollection", "insert", "update", "remove"]

    /// `db.runCommand({…})` and `db.adminCommand({…})`: the read-only commands of
    /// `MongoQuery.commands`, and listDatabases.
    func runCommand(_ call: Call) throws(MongoShell.Problem) -> Translation {
        guard let argument = call.arguments.first, call.arguments.count == 1 else {
            throw problem("\(call.name) takes one command, as in db.\(call.name)({ping: 1}).", at: call.arguments.dropFirst().first?.1 ?? token(after: call.token))
        }
        let command: [MongoJSON.Member]
        switch argument.0 {
        case .string(let name): command = [.init(name, .number("1"))]
        case .object(let members) where !members.isEmpty: command = members
        default: throw problem("\(call.name) takes a command object, such as {ping: 1}.", at: argument.1)
        }
        let name = command[0].key
        if name == "listDatabases" {
            guard command.count == 1 else { throw problem("listDatabases takes no options in Runlet.", at: argument.1) }
            return metadata("listDatabases")
        }
        guard MongoQuery.commands.contains(name) else {
            let hint = Self.collectionMethods.contains(name) ? " For \(name), use db.<collection>.\(name)(…)." : ""
            throw problem("\(call.name) runs only commands that read: \(MongoQuery.commands.sorted().joined(separator: ", ")), and listDatabases.\(hint)", at: argument.1)
        }
        for member in command.dropFirst() {
            if member.key.hasPrefix("$") || Self.refusedOptions[member.key] != nil || ["lsid", "txnNumber"].contains(member.key) || MongoQuery.commands.contains(member.key) {
                throw problem("\(name)'s field \(member.key) isn't supported here.", at: argument.1)
            }
        }
        return metadata("runCommand", [.init("command", .object(command))])
    }
}
