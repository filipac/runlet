import Foundation

/// A mongosh-like query, translated to a MongoDB tab's JSON form (#220). A tokenizer and a
/// parser read a small subset of mongosh as data, never as JavaScript:
///
/// - `db.<collection>.find({…}[, {projection}])`, with `.sort({…})`, `.skip(n)`, and `.limit(n)`
///   after it, in any order and each at most once;
/// - `aggregate([…])`, `countDocuments([{…}])`, `distinct("field"[, {…}])`;
/// - `insertOne({…})`, `insertMany([…])`, `updateOne`/`updateMany({…}, {…})`, and
///   `deleteOne`/`deleteMany({…})` (a filter is required: `{}` matches every document);
/// - `db.getCollection("name")` for a name that isn't an identifier, and dotted names
///   (`db.shop.orders` is the collection `shop.orders`);
/// - relaxed literals: unquoted keys, single-quoted strings, trailing commas, `//` and `/* */`
///   comments, and `ObjectId("…")`, `ISODate("…")`, `NumberDecimal("…")`, and `NumberLong(…)`
///   (with or without `new`), which become Extended JSON.
///
/// Everything else is refused with a message that says what to write instead, and where: other
/// calls and methods, variables, expressions, regular expression and template literals,
/// duplicate keys, options arguments, several statements, and server-side JavaScript (`$where`,
/// `$function`, `$accumulator`, `$code`). The result is checked again by `MongoQuery`, so the
/// translated JSON is what every safety rule sees.
public enum MongoShell {
    /// A translated query: the JSON form, as an order-keeping value and as the text that runs.
    public struct Translation: Equatable, Sendable {
        public var json: MongoJSON
        /// The JSON form, pretty-printed (`MongoJSON.pretty`).
        public var text: String { json.pretty() }
        public var collection: String
        public var operation: String
    }

    /// Why a text isn't a query of the subset, and where (1-based line and column).
    public struct Problem: Error, Equatable, Sendable, LocalizedError {
        public var message: String
        public var line: Int
        public var column: Int

        public init(message: String, line: Int, column: Int) {
            self.message = message
            self.line = line
            self.column = column
        }

        public var errorDescription: String? { "Line \(line), column \(column): \(message)" }

        /// The same problem in a larger text where this one starts at `line` and `column` (Run
        /// Selection: the editor's lines, not the selection's).
        public func offset(line startLine: Int, column startColumn: Int) -> Problem {
            Problem(message: message, line: line + startLine - 1, column: line == 1 ? column + startColumn - 1 : column)
        }
    }

    /// The operations the subset translates, as the JSON form names them.
    public static let methods: [String] = ["find", "aggregate", "countDocuments", "distinct", "insertOne", "insertMany",
                                           "updateOne", "updateMany", "deleteOne", "deleteMany"]

    /// The constructors that become Extended JSON.
    public static let constructors: Set<String> = ["ObjectId", "ISODate", "NumberDecimal", "NumberLong"]

    /// Whether a MongoDB tab's text is meant as mongosh rather than the JSON form: its first
    /// token, after blanks and comments, isn't `{`. A blank text is neither (the JSON form's own
    /// message asks for a query).
    public static func isShell(_ text: String) -> Bool {
        var lexer = Lexer(text)
        guard let token = try? lexer.next() else { return true }
        switch token.kind {
        case .end, .symbol("{"): return false
        default: return true
        }
    }

    /// Translates one mongosh-like query to the JSON form, or says why it can't.
    public static func translate(_ text: String) throws(Problem) -> Translation {
        guard text.utf8.count <= 1_048_576 else {
            throw Problem(message: "A query is at most 1 MiB.", line: 1, column: 1)
        }
        var parser = try Parser(text)
        return try parser.statement()
    }

    // MARK: Tokens

    struct Token: Equatable {
        enum Kind: Equatable {
            case identifier(String)
            case string(String)
            /// The number as a JSON literal (`.5` becomes `0.5`, `5.` becomes `5.0`).
            case number(String)
            case symbol(Character)
            case end
        }
        var kind: Kind
        /// Where it starts, in Unicode scalars.
        var offset: Int

        /// How a message names it: “find”, “)”, the end of the query.
        var shown: String {
            switch kind {
            case .identifier(let name): "“\(name)”"
            case .string: "a string"
            case .number(let literal): "“\(literal)”"
            case .symbol(let symbol): "“\(symbol)”"
            case .end: "the end of the query"
            }
        }
    }

    struct Lexer {
        let scalars: [Unicode.Scalar]
        var index = 0

        init(_ text: String) { scalars = Array(text.unicodeScalars) }

        func problem(_ message: String, at offset: Int) -> Problem {
            var line = 1, column = 1
            var index = 0
            while index < min(offset, scalars.count) {
                let scalar = scalars[index]
                if scalar == "\n" || (scalar == "\r" && (index + 1 >= scalars.count || scalars[index + 1] != "\n")) {
                    line += 1
                    column = 1
                } else if scalar != "\r" {
                    column += 1
                }
                index += 1
            }
            return Problem(message: message, line: line, column: column)
        }

        private func peek(_ ahead: Int = 0) -> Unicode.Scalar? {
            index + ahead < scalars.count ? scalars[index + ahead] : nil
        }

        static func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
            scalar == "_" || scalar == "$" || scalar.properties.isAlphabetic
        }

        static func isIdentifierPart(_ scalar: Unicode.Scalar) -> Bool {
            isIdentifierStart(scalar) || ("0"..."9").contains(scalar) || scalar.properties.numericType != nil
        }

        private static func isDigit(_ scalar: Unicode.Scalar?) -> Bool {
            scalar.map { ("0"..."9").contains($0) } ?? false
        }

        /// Skips white space and comments.
        mutating func skipBlanks() throws(Problem) {
            while let scalar = peek() {
                if scalar.properties.isWhitespace || scalar == "\u{FEFF}" {
                    index += 1
                } else if scalar == "/", peek(1) == "/" {
                    while let next = peek(), next != "\n", next != "\r" { index += 1 }
                } else if scalar == "/", peek(1) == "*" {
                    let start = index
                    index += 2
                    while true {
                        guard let next = peek() else { throw problem("This comment isn't closed with “*/”.", at: start) }
                        if next == "*", peek(1) == "/" { index += 2; break }
                        index += 1
                    }
                } else {
                    return
                }
            }
        }

        mutating func next() throws(Problem) -> Token {
            try skipBlanks()
            let start = index
            guard let scalar = peek() else { return Token(kind: .end, offset: start) }
            switch scalar {
            case "{", "}", "[", "]", "(", ")", ",", ":", ";":
                index += 1
                return Token(kind: .symbol(Character(scalar)), offset: start)
            case ".":
                if peek(1) == ".", peek(2) == "." {
                    throw problem("Spread syntax (“...”) isn't supported: write each value out.", at: start)
                }
                if Self.isDigit(peek(1)) { return Token(kind: .number(try number()), offset: start) }
                index += 1
                return Token(kind: .symbol("."), offset: start)
            case "\"", "'":
                return Token(kind: .string(try string(quote: scalar)), offset: start)
            case "`":
                throw problem("Template strings (`…`) aren't supported: use \"…\" or '…'.", at: start)
            case "-":
                guard Self.isDigit(peek(1)) || (peek(1) == "." && Self.isDigit(peek(2))) else {
                    throw problem("Unexpected “-”: Runlet reads literal values only and doesn't evaluate expressions. Write a negative number as -5.", at: start)
                }
                return Token(kind: .number(try number()), offset: start)
            case "/":
                throw problem("Regular expression literals aren't supported: write {$regex: \"^INV-\", $options: \"i\"}.", at: start)
            default:
                if Self.isDigit(scalar) { return Token(kind: .number(try number()), offset: start) }
                if Self.isIdentifierStart(scalar) {
                    while let next = peek(), Self.isIdentifierPart(next) { index += 1 }
                    var name = String.UnicodeScalarView()
                    name.append(contentsOf: scalars[start..<index])
                    return Token(kind: .identifier(String(name)), offset: start)
                }
                throw problem("Unexpected “\(Character(scalar))”: Runlet reads literal values only and doesn't evaluate expressions.", at: start)
            }
        }

        /// A decimal number, as a JSON literal.
        private mutating func number() throws(Problem) -> String {
            let start = index
            var literal = ""
            if peek() == "-" { literal = "-"; index += 1 }
            func digits() -> String {
                var out = ""
                while let scalar = peek(), Self.isDigit(scalar) { out.unicodeScalars.append(scalar); index += 1 }
                return out
            }
            let whole = digits()
            if whole.count > 1, whole.hasPrefix("0") {
                throw problem("A number can't start with 0: write \(whole.drop { $0 == "0" }.isEmpty ? "0" : String(whole.drop { $0 == "0" })), or \"\(whole)\" for text.", at: start)
            }
            if whole == "0", let next = peek(), "xXoObB".unicodeScalars.contains(next) {
                throw problem("Write numbers in decimal: hexadecimal, octal, and binary literals aren't supported.", at: start)
            }
            literal += whole.isEmpty ? "0" : whole
            if peek() == "." {
                index += 1
                let fraction = digits()
                literal += "." + (fraction.isEmpty ? "0" : fraction)
            }
            if let marker = peek(), marker == "e" || marker == "E" {
                index += 1
                var exponent = "e"
                if let sign = peek(), sign == "+" || sign == "-" { exponent.unicodeScalars.append(sign); index += 1 }
                let power = digits()
                guard !power.isEmpty else { throw problem("This number's exponent has no digits.", at: start) }
                literal += exponent + power
            }
            if let next = peek(), Self.isIdentifierPart(next) || next == "." {
                while let more = peek(), Self.isIdentifierPart(more) || more == "." { index += 1 }
                var text = String.UnicodeScalarView()
                text.append(contentsOf: scalars[start..<index])
                throw problem("“\(String(text))” isn't a number Runlet can read: write a decimal number such as 1000 or 12.5.", at: start)
            }
            return literal
        }

        /// A single- or double-quoted string, with JavaScript's escapes.
        private mutating func string(quote: Unicode.Scalar) throws(Problem) -> String {
            let start = index
            index += 1
            var out = String.UnicodeScalarView()
            while true {
                guard let scalar = peek() else { throw problem("This string isn't closed with \(quote == "'" ? "'" : "\"").", at: start) }
                if scalar == quote { index += 1; return String(out) }
                if scalar == "\n" || scalar == "\r" {
                    throw problem("This string isn't closed on its line: write \\n for a line break.", at: start)
                }
                guard scalar == "\\" else { out.append(scalar); index += 1; continue }
                let escapeStart = index
                index += 1
                guard let escape = peek() else { throw problem("This string isn't closed with \(quote == "'" ? "'" : "\"").", at: start) }
                index += 1
                switch escape {
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "v": out.append("\u{0B}")
                case "'", "\"", "\\", "/": out.append(escape)
                case "0":
                    guard !Self.isDigit(peek()) else { throw problem("Octal escapes aren't supported: write \\u0000 escapes.", at: escapeStart) }
                    out.append("\0")
                case "\n": break
                case "\r": if peek() == "\n" { index += 1 }
                case "x":
                    guard let code = hex(count: 2), let value = Unicode.Scalar(code) else { throw problem("\\x needs two hexadecimal digits.", at: escapeStart) }
                    out.append(value)
                case "u":
                    out.append(try unicodeEscape(at: escapeStart))
                default:
                    throw problem("“\\\(Character(escape))” isn't an escape Runlet knows: write “\\\\\(Character(escape))” for a backslash and “\(Character(escape))”.", at: escapeStart)
                }
            }
        }

        private mutating func hex(count: Int) -> UInt32? {
            guard index + count <= scalars.count else { return nil }
            var text = String.UnicodeScalarView()
            text.append(contentsOf: scalars[index..<index + count])
            guard let value = UInt32(String(text), radix: 16), String(text).allSatisfy(\.isHexDigit) else { return nil }
            index += count
            return value
        }

        /// `\uXXXX` (a surrogate pair is two of them) or `\u{X…}`, after `\u`.
        private mutating func unicodeEscape(at start: Int) throws(Problem) -> Unicode.Scalar {
            if peek() == "{" {
                index += 1
                var digits = String.UnicodeScalarView()
                while let scalar = peek(), scalar != "}" { digits.append(scalar); index += 1 }
                guard peek() == "}", !digits.isEmpty, digits.count <= 6, String(digits).allSatisfy(\.isHexDigit),
                      let code = UInt32(String(digits), radix: 16), let value = Unicode.Scalar(code) else {
                    throw problem("\\u{…} needs a Unicode code point in hexadecimal.", at: start)
                }
                index += 1
                return value
            }
            guard let code = hex(count: 4) else { throw problem("\\u needs four hexadecimal digits.", at: start) }
            if (0xD800...0xDBFF).contains(code) {
                guard peek() == "\\", peek(1) == "u" else { throw problem("A \\u escape of a high surrogate needs its low surrogate.", at: start) }
                index += 2
                guard let low = hex(count: 4), (0xDC00...0xDFFF).contains(low),
                      let value = Unicode.Scalar(0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)) else {
                    throw problem("A \\u escape of a high surrogate needs its low surrogate.", at: start)
                }
                return value
            }
            guard let value = Unicode.Scalar(code) else { throw problem("A lone surrogate (\\u\(String(code, radix: 16, uppercase: true))) isn't text.", at: start) }
            return value
        }
    }

    // MARK: Parsing

    struct Parser {
        var lexer: Lexer
        var token: Token
        static let maxDepth = 256

        init(_ text: String) throws(Problem) {
            lexer = Lexer(text)
            token = try lexer.next()
        }

        func problem(_ message: String, at token: Token) -> Problem {
            lexer.problem(message, at: token.offset)
        }

        mutating func advance() throws(Problem) {
            token = try lexer.next()
        }

        /// The token after the current one, without moving.
        func peek() throws(Problem) -> Token {
            var copy = lexer
            return try copy.next()
        }

        func isSymbol(_ symbol: Character) -> Bool { token.kind == .symbol(symbol) }

        mutating func expect(_ symbol: Character, _ message: @autoclosure () -> String) throws(Problem) {
            guard isSymbol(symbol) else { throw problem(message(), at: token) }
            try advance()
        }

        // MARK: The statement

        mutating func statement() throws(Problem) -> Translation {
            switch token.kind {
            case .identifier("db"): break
            case .identifier("use"):
                throw problem("“use” isn't supported: a MongoDB tab uses its connection's database. Start the query with db., as in db.orders.find({status: \"paid\"}).", at: token)
            case .symbol("{"):
                throw problem("The JSON form can't have comments: remove them, or write the query in mongosh, as in db.orders.find({status: \"paid\"}).", at: token)
            case .end:
                throw problem("Enter a query, such as db.orders.find({status: \"paid\"}).", at: token)
            default:
                throw problem("A mongosh query starts with db.<collection>, as in db.orders.find({status: \"paid\"}).", at: token)
            }
            try advance()
            if isSymbol("[") {
                throw problem("Write db.getCollection(\"name\") for a collection whose name isn't a plain word.", at: token)
            }
            try expect(".", "Expected “.” after db, as in db.orders.find({…}).")

            var names: [String] = []
            var collection: String?
            let method: String
            let methodToken: Token
            while true {
                guard case .identifier(let name) = token.kind else {
                    throw problem(names.isEmpty ? "Expected a collection name after “db.”." : "Expected a method name, such as find, after “.”.", at: token)
                }
                let nameToken = token
                if names.isEmpty, collection == nil, name == "getCollection", try peek().kind == .symbol("(") {
                    try advance()
                    try advance()
                    guard case .string(let named) = token.kind else {
                        throw problem("getCollection takes the collection's name in quotes, as in db.getCollection(\"order-items\").", at: token)
                    }
                    try advance()
                    if isSymbol(",") { try advance() }
                    try expect(")", "getCollection takes one argument: the collection's name.")
                    collection = named
                    try expect(".", "Call a method on the collection, as in db.getCollection(\"\(named)\").find({…}).")
                    continue
                }
                try advance()
                if isSymbol("(") {
                    method = name
                    methodToken = nameToken
                    break
                }
                guard collection == nil, isSymbol(".") else {
                    let named = collection.map { "getCollection(\(MongoJSON.quoted($0)))" } ?? (names + [name]).joined(separator: ".")
                    throw problem("Call a method on the collection, as in db.\(named).find({…}).", at: token)
                }
                names.append(name)
                try advance()
            }
            let name = collection ?? names.joined(separator: ".")
            guard !name.isEmpty else { throw problem(Self.dbMethodMessage(method), at: methodToken) }
            guard Self.methodsSet.contains(method) else { throw problem(Self.methodMessage(method, collection: name), at: methodToken) }
            let arguments = try self.arguments()

            var chain: [(name: String, token: Token, arguments: [(MongoJSON, Token)])] = []
            while isSymbol(".") {
                try advance()
                guard case .identifier(let link) = token.kind else { throw problem("Expected a method name, such as sort, after “.”.", at: token) }
                let linkToken = token
                try advance()
                guard isSymbol("(") else {
                    throw problem("Properties aren't supported: call a method, as in .limit(20).", at: linkToken)
                }
                chain.append((link, linkToken, try self.arguments()))
            }
            if isSymbol(";") { try advance() }
            guard token.kind == .end else {
                if case .identifier = token.kind {
                    throw problem("Only one query runs at a time: select the one to run.", at: token)
                }
                throw problem("Unexpected \(token.shown) after the query.", at: token)
            }

            var members: [MongoJSON.Member] = [.init("collection", .string(name)), .init("operation", .string(method))]
            try translate(method, methodToken, arguments: arguments, into: &members)
            if !chain.isEmpty {
                guard method == "find" else {
                    throw problem(".\(chain[0].name)() works after find() only.", at: chain[0].token)
                }
                try translateCursor(chain, into: &members)
            }
            return Translation(json: .object(members), collection: name, operation: method)
        }

        static let methodsSet = Set(MongoShell.methods)

        /// `db.<method>()`: a database method, not a collection's.
        static func dbMethodMessage(_ method: String) -> String {
            switch method {
            case "dropDatabase":
                "dropDatabase() isn't translated from mongosh. Write it in the JSON form: {\"operation\": \"dropDatabase\", \"database\": \"shop\"}."
            case _ where MongoShell.methods.contains(method):
                "\(method)() is a collection's method: write db.<collection>.\(method)(…), as in db.orders.\(method)(…)."
            default:
                "db.\(method)() isn't supported: a MongoDB tab runs a collection's \(Self.methodList)."
            }
        }

        /// `db.<collection>.<method>()` for a method outside the subset.
        static func methodMessage(_ method: String, collection: String) -> String {
            let json = "{\"collection\": \(MongoJSON.quoted(collection)), \"operation\": \"\(method)\", …}"
            return switch method {
            case "findOne": "findOne() isn't translated from mongosh: write find({…}).limit(1), or the JSON form \(json)."
            case "replaceOne", "drop", "createIndex", "getIndexes": "\(method)() isn't translated from mongosh. Write it in the JSON form: \(json)."
            case "count": "count() isn't supported: write countDocuments({…})."
            default: "\(method)() isn't supported: a mongosh query uses \(Self.methodList)."
            }
        }

        static let methodList = "find, aggregate, countDocuments, distinct, insertOne, insertMany, updateOne, updateMany, deleteOne, or deleteMany"

        // MARK: Methods

        private func object(_ argument: (MongoJSON, Token)?, _ message: String) throws(Problem) -> MongoJSON? {
            guard let argument else { return nil }
            guard case .object = argument.0 else { throw problem(message, at: argument.1) }
            return argument.0
        }

        private func noMore(_ arguments: [(MongoJSON, Token)], than count: Int, _ message: String) throws(Problem) {
            if arguments.count > count { throw problem(message, at: arguments[count].1) }
        }

        private mutating func translate(_ method: String, _ methodToken: Token, arguments: [(MongoJSON, Token)], into members: inout [MongoJSON.Member]) throws(Problem) {
            let filterMessage = "\(method)'s filter is an object, such as {status: \"paid\"}."
            switch method {
            case "find":
                try noMore(arguments, than: 2, "find takes a filter and a projection: use .sort(), .skip(), and .limit() for the rest.")
                if let filter = try object(arguments.first, filterMessage) { members.append(.init("filter", filter)) }
                if let projection = try object(arguments.dropFirst().first, "find's projection is an object, such as {status: 1, total: 1}.") {
                    members.append(.init("projection", projection))
                }
            case "countDocuments":
                try noMore(arguments, than: 1, "countDocuments takes a filter only: its options aren't supported.")
                if let filter = try object(arguments.first, filterMessage) { members.append(.init("filter", filter)) }
            case "distinct":
                guard let field = arguments.first else { throw problem("distinct needs a field's name, as in distinct(\"status\").", at: token(after: methodToken)) }
                guard case .string(let name) = field.0, !name.isEmpty else {
                    throw problem("distinct's first argument is a field's name in quotes, as in distinct(\"status\").", at: field.1)
                }
                try noMore(arguments, than: 2, "distinct takes a field's name and a filter: its options aren't supported.")
                members.append(.init("field", .string(name)))
                if let filter = try object(arguments.dropFirst().first, filterMessage) { members.append(.init("filter", filter)) }
            case "aggregate":
                guard let pipeline = arguments.first, case .array(let stages) = pipeline.0 else {
                    throw problem("aggregate takes one array of stages, as in aggregate([{$match: {status: \"paid\"}}]).", at: arguments.first?.1 ?? token(after: methodToken))
                }
                try noMore(arguments, than: 1, "aggregate takes one array of stages: its options aren't supported.")
                for stage in stages {
                    guard case .object = stage else { throw problem("Each stage of the pipeline is an object, such as {$match: {…}}.", at: pipeline.1) }
                }
                members.append(.init("pipeline", pipeline.0))
            case "insertOne":
                guard let document = try object(arguments.first, "insertOne takes one document, such as {name: \"Sprocket\"}.") else {
                    throw problem("insertOne takes one document, such as {name: \"Sprocket\"}.", at: token(after: methodToken))
                }
                try noMore(arguments, than: 1, "insertOne takes one document: its options aren't supported.")
                members.append(.init("documents", .array([document])))
            case "insertMany":
                guard let documents = arguments.first, case .array(let list) = documents.0 else {
                    throw problem("insertMany takes an array of documents, such as [{name: \"Sprocket\"}, {name: \"Gear\"}].", at: arguments.first?.1 ?? token(after: methodToken))
                }
                try noMore(arguments, than: 1, "insertMany takes an array of documents: its options aren't supported.")
                for document in list {
                    guard case .object = document else { throw problem("Each document of insertMany is an object.", at: documents.1) }
                }
                members.append(.init("documents", documents.0))
            case "updateOne", "updateMany":
                guard arguments.count >= 2 else {
                    throw problem("\(method) takes a filter and an update, as in \(method)({status: \"pending\"}, {$set: {status: \"paid\"}}).", at: arguments.last?.1 ?? token(after: methodToken))
                }
                try noMore(arguments, than: 2, "Options such as upsert aren't supported: \(method) takes a filter and an update.")
                let filter = try object(arguments[0], filterMessage)!
                if case .array = arguments[1].0 {
                    throw problem("Update pipelines aren't supported: use update operators, as in {$set: {status: \"paid\"}}.", at: arguments[1].1)
                }
                let update = try object(arguments[1], "\(method)'s update is an object of update operators, as in {$set: {status: \"paid\"}}.")!
                members.append(.init("filter", filter))
                members.append(.init("update", update))
            case "deleteOne", "deleteMany":
                guard let filter = try object(arguments.first, filterMessage) else {
                    throw problem("\(method) needs a filter, as in \(method)({status: \"cancelled\"}); {} matches every document.", at: token(after: methodToken))
                }
                try noMore(arguments, than: 1, "\(method) takes a filter only: its options aren't supported.")
                members.append(.init("filter", filter))
            default:
                break
            }
        }

        /// Where a missing argument would have been: the `)` after `method(`.
        private func token(after methodToken: Token) -> Token {
            var lexer = self.lexer
            lexer.index = methodToken.offset
            _ = try? lexer.next()
            guard let open = try? lexer.next() else { return methodToken }
            guard let close = try? lexer.next() else { return open }
            return close
        }

        /// find's `.sort()`, `.skip()`, and `.limit()`.
        private func translateCursor(_ chain: [(name: String, token: Token, arguments: [(MongoJSON, Token)])], into members: inout [MongoJSON.Member]) throws(Problem) {
            var seen: [String: MongoJSON] = [:]
            for link in chain {
                switch link.name {
                case "sort", "skip", "limit":
                    guard seen[link.name] == nil else { throw problem(".\(link.name)() is given twice: keep one.", at: link.token) }
                    guard link.arguments.count == 1 else {
                        throw problem(link.name == "sort" ? ".sort() takes one object, such as {placed_at: -1}." : ".\(link.name)() takes one whole number, as in .\(link.name)(20).",
                                      at: link.arguments.dropFirst().first?.1 ?? link.token)
                    }
                    let (value, at) = link.arguments[0]
                    if link.name == "sort" {
                        guard case .object = value else { throw problem(".sort() takes an object, such as {placed_at: -1}.", at: at) }
                    } else {
                        guard case .number(let literal) = value, literal.allSatisfy(\.isNumber) else {
                            throw problem(".\(link.name)() takes a whole number from 0, as in .\(link.name)(20).", at: at)
                        }
                    }
                    seen[link.name] = value
                case "pretty", "toArray":
                    throw problem("Leave out .\(link.name)(): Runlet shows every result as a table and a tree.", at: link.token)
                case "count":
                    throw problem(".count() isn't supported: write countDocuments({…}) instead of find({…}).", at: link.token)
                case "explain":
                    throw problem(".explain() isn't translated from mongosh: write the JSON form with \"explain\": true.", at: link.token)
                default:
                    throw problem(".\(link.name)() isn't supported after find(): use .sort(), .skip(), or .limit().", at: link.token)
                }
            }
            for key in ["sort", "skip", "limit"] {
                if let value = seen[key] { members.append(.init(key, value)) }
            }
        }

        // MARK: Values

        /// `( value, … )`, after the method's name; trailing commas are allowed.
        mutating func arguments() throws(Problem) -> [(MongoJSON, Token)] {
            try expect("(", "Expected “(”.")
            var arguments: [(MongoJSON, Token)] = []
            while !isSymbol(")") {
                let start = token
                arguments.append((try value(depth: 1), start))
                if isSymbol(",") {
                    try advance()
                } else if !isSymbol(")") {
                    throw problem(token.kind == .end ? "This call isn't closed with “)”." : "Expected “,” or “)”, not \(token.shown).", at: token)
                }
            }
            try advance()
            return arguments
        }

        mutating func value(depth: Int) throws(Problem) -> MongoJSON {
            guard depth < Self.maxDepth else { throw problem("The query is nested too deeply.", at: token) }
            let start = token
            switch token.kind {
            case .symbol("{"): return try object(depth: depth)
            case .symbol("["): return try array(depth: depth)
            case .string(let text):
                try advance()
                return .string(text)
            case .number(let literal):
                try advance()
                return .number(literal)
            case .identifier(let name):
                return try identifier(name, start: start, depth: depth)
            case .end:
                throw problem("The query ended early: expected a value.", at: token)
            case .symbol(let symbol):
                throw problem("Expected a value, not “\(symbol)”.", at: token)
            }
        }

        private mutating func identifier(_ name: String, start: Token, depth: Int) throws(Problem) -> MongoJSON {
            switch name {
            case "true": try advance(); return .bool(true)
            case "false": try advance(); return .bool(false)
            case "null": try advance(); return .null
            case "undefined":
                throw problem("undefined isn't a value MongoDB stores: use null, or leave the field out.", at: start)
            case "NaN", "Infinity":
                throw problem("Write \(name) in Extended JSON: {$numberDouble: \"\(name)\"}.", at: start)
            case "function":
                throw problem("Functions aren't supported: Runlet never runs JavaScript.", at: start)
            case "new":
                try advance()
                guard case .identifier(let constructor) = token.kind else { throw problem("Expected a constructor after new, such as new ObjectId(\"…\").", at: token) }
                guard MongoShell.constructors.contains(constructor) else { throw callProblem(constructor, at: token) }
                return try self.constructor(constructor, depth: depth)
            case _ where MongoShell.constructors.contains(name):
                return try constructor(name, depth: depth)
            default:
                let next = try peek()
                if next.kind == .symbol("(") { throw callProblem(name, at: start) }
                if next.kind == .symbol(".") {
                    throw problem("“\(name)” is a variable, and Runlet doesn't evaluate JavaScript: write the value itself.", at: start)
                }
                throw problem("“\(name)” is a variable, and Runlet doesn't evaluate JavaScript. Quote text: \"\(name)\".", at: start)
            }
        }

        private func callProblem(_ name: String, at token: Token) -> Problem {
            if name == "Date" {
                return problem("Date() isn't supported: write dates as ISODate(\"2026-01-01T00:00:00Z\").", at: token)
            }
            return problem("\(name)() isn't supported: Runlet translates only ObjectId, ISODate, NumberDecimal, and NumberLong, and never runs JavaScript. Write other values in Extended JSON, such as {$numberInt: \"5\"}.", at: token)
        }

        private mutating func object(depth: Int) throws(Problem) -> MongoJSON {
            try advance()
            var members: [MongoJSON.Member] = []
            var keys: Set<String> = []
            while !isSymbol("}") {
                let keyToken = token
                let key: String
                var bare = false
                switch token.kind {
                case .identifier(let name): key = name; bare = true
                case .string(let text): key = text
                case .number(let literal): throw problem("Quote a key that is a number: \"\(literal)\".", at: token)
                case .symbol("["): throw problem("Computed keys aren't supported: write the key as text.", at: token)
                case .end: throw problem("This object isn't closed with “}”.", at: token)
                default: throw problem("Expected a field name or “}”, not \(token.shown).", at: token)
                }
                try advance()
                if bare, isSymbol(",") || isSymbol("}") {
                    throw problem("“\(key)” needs a value, as in \(key): 1. Runlet doesn't read variables.", at: keyToken)
                }
                if bare, isSymbol("."), case .identifier = try peek().kind {
                    throw problem("Quote a key with a dot, as in \"\(key).…\": 1.", at: keyToken)
                }
                try expect(":", "Expected “:” after \(keyToken.kind == .identifier(key) ? "“\(key)”" : "the key").")
                if let reason = Self.serverJavaScript[key] {
                    throw problem("\(key) runs JavaScript on the server, which MongoDB tabs don't support: \(reason)", at: keyToken)
                }
                guard keys.insert(key).inserted else {
                    throw problem("“\(key)” is in this object twice: keep one.", at: keyToken)
                }
                members.append(.init(key, try value(depth: depth + 1)))
                if isSymbol(",") {
                    try advance()
                } else if !isSymbol("}") {
                    throw problem(token.kind == .end ? "This object isn't closed with “}”." : "Expected “,” or “}”, not \(token.shown).", at: token)
                }
            }
            try advance()
            return .object(members)
        }

        static let serverJavaScript: [String: String] = [
            "$where": "use $expr with query operators instead.",
            "$function": "use aggregation operators instead.",
            "$accumulator": "use $group's accumulators instead.",
            "$code": "write the value as text.",
        ]

        private mutating func array(depth: Int) throws(Problem) -> MongoJSON {
            try advance()
            var elements: [MongoJSON] = []
            while !isSymbol("]") {
                if isSymbol(",") { throw problem("Empty array elements (“,,”) aren't supported: write null.", at: token) }
                if token.kind == .end { throw problem("This array isn't closed with “]”.", at: token) }
                elements.append(try value(depth: depth + 1))
                if isSymbol(",") {
                    try advance()
                } else if !isSymbol("]") {
                    throw problem(token.kind == .end ? "This array isn't closed with “]”." : "Expected “,” or “]”, not \(token.shown).", at: token)
                }
            }
            try advance()
            return .array(elements)
        }

        // MARK: Constructors

        /// `ObjectId("…")`, `ISODate("…")`, `NumberDecimal("…")`, `NumberLong(…)` as Extended JSON.
        private mutating func constructor(_ name: String, depth: Int) throws(Problem) -> MongoJSON {
            let start = token
            try advance()
            guard isSymbol("(") else { throw problem("\(name) needs its value in parentheses, as in \(Self.example(name)).", at: token) }
            let arguments = try self.arguments()
            guard let argument = arguments.first else { throw problem("\(name)() needs a value, as in \(Self.example(name))\(name == "ObjectId" ? "; leave _id out of an insert, and MongoDB adds one" : "").", at: start) }
            try noMore(arguments, than: 1, "\(name) takes one value, as in \(Self.example(name)).")
            let (value, at) = argument
            switch name {
            case "ObjectId":
                guard case .string(let hex) = value, MongoValue.isObjectId(hex) else {
                    throw problem("ObjectId takes 24 hexadecimal digits in quotes, as in \(Self.example(name)).", at: at)
                }
                return .object([.init("$oid", .string(hex.lowercased()))])
            case "ISODate":
                guard case .string(let text) = value, let date = MongoShell.isoDate(text) else {
                    throw problem("ISODate takes a date in quotes, as in ISODate(\"2026-01-01\") or ISODate(\"2026-01-01T09:30:00Z\").", at: at)
                }
                return MongoShell.extendedDate(date)
            case "NumberDecimal":
                let text: String
                switch value {
                case .string(let string): text = string
                case .number(let literal): text = literal
                default: text = ""
                }
                guard MongoValue.isDecimal(text) else {
                    throw problem("NumberDecimal takes a decimal number in quotes, as in NumberDecimal(\"12.50\").", at: at)
                }
                return .object([.init("$numberDecimal", .string(text))])
            default:
                let text: String
                switch value {
                case .string(let string): text = string
                case .number(let literal): text = literal
                default: text = ""
                }
                guard let number = Int64(text) else {
                    throw problem("NumberLong takes a whole number from -9223372036854775808 to 9223372036854775807, as in NumberLong(\"9007199254740993\").", at: at)
                }
                return .object([.init("$numberLong", .string(String(number)))])
            }
        }

        static func example(_ name: String) -> String {
            switch name {
            case "ObjectId": "ObjectId(\"507f1f77bcf86cd799439011\")"
            case "ISODate": "ISODate(\"2026-01-01T00:00:00Z\")"
            case "NumberDecimal": "NumberDecimal(\"12.50\")"
            default: "NumberLong(\"9007199254740993\")"
            }
        }
    }

    // MARK: Dates

    /// The date of an `ISODate("…")` as mongosh reads it: `2026-01-01`, `2026-01-01T09:30`,
    /// `2026-01-01T09:30:00`, with milliseconds, and `Z` or an offset (`+02:00`, `+0200`); a
    /// space may stand for the `T`. Without a zone, the time is UTC. Nil for anything else, or
    /// a day the month doesn't have.
    public static func isoDate(_ text: String) -> Date? {
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,9}))?)?)?(Z|[+-]\d{2}:?\d{2})?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        var components = DateComponents()
        components.year = Int(group(1)!)
        components.month = Int(group(2)!)
        components.day = Int(group(3)!)
        components.hour = group(4).flatMap(Int.init) ?? 0
        components.minute = group(5).flatMap(Int.init) ?? 0
        components.second = group(6).flatMap(Int.init) ?? 0
        guard let month = components.month, (1...12).contains(month), let hour = components.hour, hour < 24,
              let minute = components.minute, minute < 60, let second = components.second, second < 60 else { return nil }
        var offset = 0
        if let zone = group(8), zone != "Z" {
            let digits = zone.dropFirst().filter(\.isNumber)
            guard let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)), hours < 24, minutes < 60 else { return nil }
            offset = (hours * 3600 + minutes * 60) * (zone.hasPrefix("-") ? -1 : 1)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: components), calendar.component(.day, from: date) == components.day,
              calendar.component(.month, from: date) == month else { return nil }
        let milliseconds = group(7).map { Double("0." + $0)! } ?? 0
        let truncated = (milliseconds * 1000).rounded(.down) / 1000
        return date.addingTimeInterval(truncated - Double(offset))
    }

    /// A date as Extended JSON: `{"$date": "2026-01-01T09:30:00Z"}` (with milliseconds when it
    /// has them) for the years 1970 to 9999, else `{"$date": {"$numberLong": "<milliseconds>"}}`.
    public static func extendedDate(_ date: Date) -> MongoJSON {
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        let year = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date).year ?? 0
        if milliseconds >= 0, year <= 9999 {
            return .object([.init("$date", .string(MongoValue.isoText(date)))])
        }
        return .object([.init("$date", .object([.init("$numberLong", .string(String(Int64(milliseconds))))]))])
    }
}

extension MongoQuery {
    /// A MongoDB tab's query (#220): the JSON form as it is, or a mongosh-like query translated
    /// to it (`MongoShell`). The translated JSON is what `json`, the effect, and every check
    /// see; `mongosh` keeps the text it came from. Nothing is evaluated as JavaScript.
    public init(tabText text: String) throws {
        guard MongoShell.isShell(text) else {
            try self.init(text)
            return
        }
        let translation = try MongoShell.translate(text)
        try self.init(translation.text)
        mongosh = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
