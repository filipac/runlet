import Foundation

// MARK: - Bound parameters (#145)

/// The type a placeholder's value is bound with (`PDOStatement::bindValue`).
public enum SQLParameterType: String, Sendable, Hashable, CaseIterable, Codable {
    /// `PDO::PARAM_STR`.
    case text
    /// `PDO::PARAM_INT`.
    case integer
    /// The number as typed, bound as `PDO::PARAM_STR` (PDO has no decimal type), so a
    /// `DECIMAL` column keeps every digit; the database converts it.
    case decimal
    /// `PDO::PARAM_BOOL`.
    case boolean
    /// `PDO::PARAM_NULL`.
    case null

    public var displayName: String {
        switch self {
        case .text: "Text"
        case .integer: "Integer"
        case .decimal: "Decimal"
        case .boolean: "Boolean"
        case .null: "NULL"
        }
    }

    /// The word `-- @param` lines and history use.
    public var word: String { rawValue }

    /// A type word in a `-- @param` line, ignoring case: `text`, `integer`, `decimal`,
    /// `boolean`, `null`, or a common alias (`string`, `int`, `number`, `bool`, …).
    public init?(word: String) {
        switch word.lowercased() {
        case "text", "string", "str", "varchar", "char": self = .text
        case "integer", "int", "bigint", "smallint": self = .integer
        case "decimal", "number", "numeric", "float", "double", "real": self = .decimal
        case "boolean", "bool": self = .boolean
        case "null": self = .null
        default: return nil
        }
    }
}

/// A value for one placeholder.
public enum SQLParameterValue: Sendable, Hashable {
    case text(String)
    case integer(Int)
    /// The number as typed (trimmed), sent as text.
    case decimal(String)
    case boolean(Bool)
    case null

    public var type: SQLParameterType {
        switch self {
        case .text: .text
        case .integer: .integer
        case .decimal: .decimal
        case .boolean: .boolean
        case .null: .null
        }
    }

    /// How confirmations and the output show it: `'it''s'` (quoted as SQL would), `42`,
    /// `19.99`, `true`, `NULL`. Long text is shortened to `limit` characters.
    public func display(limit: Int = 120) -> String {
        switch self {
        case .text(let value):
            let visible = SQLParameters.visible(value)
            let short = visible.count > limit ? String(visible.prefix(limit)) + "…" : visible
            return "'" + short.replacingOccurrences(of: "'", with: "''") + "'"
        case .integer(let value): return String(value)
        case .decimal(let value): return value
        case .boolean(let value): return value ? "true" : "false"
        case .null: return "NULL"
        }
    }

    /// The text a form field starts with.
    public var editableText: String {
        switch self {
        case .text(let value), .decimal(let value): value
        case .integer(let value): String(value)
        case .boolean(let value): value ? "true" : "false"
        case .null: ""
        }
    }

    /// The runner's type name (`SqlTab::bind`).
    var runnerType: String {
        switch self {
        case .text: "str"
        case .integer: "int"
        case .decimal: "decimal"
        case .boolean: "bool"
        case .null: "null"
        }
    }

    /// The value as a PHP literal for the runner's request. It is data in a PHP array, bound
    /// with `bindValue`; it never becomes part of the SQL text.
    var phpLiteral: String {
        switch self {
        case .text(let value), .decimal(let value): SnippetInputs.phpString(value)
        case .integer(let value): SnippetInputs.phpInt(value)
        case .boolean(let value): value ? "true" : "false"
        case .null: "null"
        }
    }
}

/// One value a run needs: a `:name` (once for the whole run, however often it is used) or one
/// `?` of one statement.
public struct SQLParameter: Sendable, Hashable, Identifiable {
    public enum Key: Sendable, Hashable {
        /// `:name`, without the colon.
        case named(String)
        /// The `index`th `?` (1-based) of statement `statement` (0-based in the run).
        case positional(statement: Int, index: Int)
    }

    public var key: Key
    /// The tab line of its first use.
    public var line: Int
    /// How often it appears (a name can appear several times; MySQL refuses that, see the runner).
    public var uses: Int

    public var id: Key { key }

    /// `:name` or `?2`.
    public var placeholder: String {
        switch key {
        case .named(let name): ":" + name
        case .positional(_, let index): "?\(index)"
        }
    }

    public var statement: Int? {
        if case .positional(let statement, _) = key { return statement }
        return nil
    }
}

/// A placeholder Runlet can't bind, found before anything runs.
public struct SQLParameterProblem: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        /// `:name` and `?` in one statement, which PDO refuses.
        case mixed
        /// `$1`: PDO binds only `?` and `:name`.
        case numbered(String)
        /// A name with characters PDO doesn't read as part of it (`:café`, `:a$b`).
        case invalidName(String)
    }

    public var kind: Kind
    public var line: Int
    /// 1-based index and count in Run All; nil for one statement.
    public var statement: (index: Int, count: Int)?

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.line == rhs.line && lhs.statement?.index == rhs.statement?.index && lhs.statement?.count == rhs.statement?.count
    }

    public var title: String { "Runlet can't bind these placeholders" }

    public var description: String {
        let place = statement.map { "Statement \($0.index) of \($0.count) (line \(line))" } ?? "Line \(line)"
        switch kind {
        case .mixed:
            return "\(place) mixes :name and ? placeholders. PDO, which binds the values, refuses that in one statement: use one kind. Nothing ran."
        case .numbered(let text):
            return "\(place) has \(text), a numbered placeholder. Runlet binds values through PDO, which reads :name and ? placeholders: write \(text) as :name or ?. Nothing ran."
        case .invalidName(let text):
            return "\(place) has \(text), which PDO doesn't read as one placeholder: names use the letters A–Z, digits, and _. Nothing ran."
        }
    }
}

/// The placeholders of the statements a run sends.
public struct SQLParameterScan: Sendable, Equatable {
    /// One per value, in the order of first use; a name used by several statements once.
    public var parameters: [SQLParameter]
    /// Per statement, in order: the keys its placeholders bind.
    public var statementKeys: [[SQLParameter.Key]]
    /// Per statement: how often it uses each name.
    public var statementUses: [[String: Int]]
    /// The first placeholder Runlet can't bind; such a run is refused before the sheet.
    public var problem: SQLParameterProblem?

    public init(parameters: [SQLParameter] = [], statementKeys: [[SQLParameter.Key]] = [], statementUses: [[String: Int]] = [], problem: SQLParameterProblem? = nil) {
        self.parameters = parameters
        self.statementKeys = statementKeys
        self.statementUses = statementUses
        self.problem = problem
    }

    public var isEmpty: Bool { parameters.isEmpty }

    /// `?`s in more than one statement: the sheet names their statement.
    public var positionalSpansStatements: Bool {
        Set(parameters.compactMap(\.statement)).count > 1
    }

    /// The values each statement binds, in order (empty for statements without placeholders).
    /// Nil when a value is missing.
    public func bindings(_ values: [SQLParameter.Key: SQLParameterValue]) -> [[SQLBinding]]? {
        var result: [[SQLBinding]] = []
        for (statement, keys) in statementKeys.enumerated() {
            var bindings: [SQLBinding] = []
            for key in keys {
                guard let value = values[key] else { return nil }
                switch key {
                case .named(let name):
                    let uses = statementUses.indices.contains(statement) ? statementUses[statement][name] ?? 1 : 1
                    bindings.append(SQLBinding(target: .name(name), value: value, uses: uses))
                case .positional(_, let index):
                    bindings.append(SQLBinding(target: .position(index), value: value))
                }
            }
            result.append(bindings)
        }
        return result
    }
}

/// One `bindValue` call: a name or a 1-based position, and its typed value.
public struct SQLBinding: Sendable, Hashable {
    public enum Target: Sendable, Hashable {
        case name(String)
        case position(Int)
    }

    public var target: Target
    public var value: SQLParameterValue
    /// How often a name appears in its statement (the runner refuses repeats on MySQL).
    public var uses: Int

    public init(target: Target, value: SQLParameterValue, uses: Int = 1) {
        self.target = target
        self.value = value
        self.uses = uses
    }

    /// The runner's entry: `['name' => 'id', 'type' => 'int', 'value' => 42]`.
    var phpEntry: String {
        let head = switch target {
        case .name(let name): "'name' => \(SnippetInputs.phpString(name))"
        case .position(let index): "'position' => \(index)"
        }
        return "[\(head), 'type' => '\(value.runnerType)', 'value' => \(value.phpLiteral)\(uses > 1 ? ", 'uses' => \(uses)" : "")]"
    }
}

/// A `-- @param` line's preset: the type and, optionally, the value the sheet starts with.
public struct SQLParameterPreset: Sendable, Hashable {
    public var type: SQLParameterType
    /// The value as typed, nil when the line gives none.
    public var text: String?

    public init(type: SQLParameterType, text: String? = nil) {
        self.type = type
        self.text = text
    }
}

/// Placeholders (#145): finding them, presets from `-- @param` comments, and history text.
/// Nothing here runs SQL.
public enum SQLParameters {
    // MARK: Finding placeholders

    /// The placeholders of `statements`, read with the shared lexer: nothing inside strings,
    /// comments, or quoted names counts; `::` casts and `:=` aren't placeholders, and `??` is
    /// PDO's escape for a literal `?` (PostgreSQL's JSON operators). A name is one value for
    /// the whole run; each statement's `?`s are its own. `driver`, when known, reads the text
    /// as that database does (MySQL's backslash escapes, PostgreSQL's `#` operators).
    public static func scan(_ statements: [SQLScript.Statement], driver: DatabaseDriverKind? = nil) -> SQLParameterScan {
        var scan = SQLParameterScan()
        var namedIndex: [String: Int] = [:]
        let count = statements.count
        for (statementIndex, statement) in statements.enumerated() {
            let string = statement.text as NSString
            let tokens = SQLScript.tokenize(string, backslashEscapes: driver == .mysql, hashComments: driver != .pgsql)
            var keys: [SQLParameter.Key] = []
            var uses: [String: Int] = [:]
            var named = false
            var positional = 0
            func problem(_ kind: SQLParameterProblem.Kind, _ location: Int) -> SQLParameterProblem {
                SQLParameterProblem(kind: kind, line: line(of: location, in: string, from: statement.startLine), statement: count > 1 ? (statementIndex + 1, count) : nil)
            }
            var index = 0
            while index < tokens.count {
                let token = tokens[index]
                index += 1
                guard token.kind == .placeholder else { continue }
                let text = string.substring(with: token.range)
                let tokenLine = line(of: token.range.location, in: string, from: statement.startLine)
                if text == "?" {
                    // `??`: PDO sends one literal `?`.
                    if index < tokens.count, tokens[index].kind == .placeholder, tokens[index].range.location == NSMaxRange(token.range),
                       string.substring(with: tokens[index].range) == "?" {
                        index += 1
                        continue
                    }
                    positional += 1
                    let key = SQLParameter.Key.positional(statement: statementIndex, index: positional)
                    keys.append(key)
                    scan.parameters.append(SQLParameter(key: key, line: tokenLine, uses: 1))
                    if named, scan.problem == nil { scan.problem = problem(.mixed, token.range.location) }
                } else if text.hasPrefix(":") {
                    let name = String(text.dropFirst())
                    guard isBindableName(name) else {
                        if scan.problem == nil { scan.problem = problem(.invalidName(text), token.range.location) }
                        continue
                    }
                    named = true
                    if positional > 0, scan.problem == nil { scan.problem = problem(.mixed, token.range.location) }
                    let key = SQLParameter.Key.named(name)
                    if namedIndex[name] == nil {
                        namedIndex[name] = scan.parameters.count
                        scan.parameters.append(SQLParameter(key: key, line: tokenLine, uses: 1))
                    }
                    if !keys.contains(key) { keys.append(key) }
                    uses[name, default: 0] += 1
                } else {
                    if scan.problem == nil { scan.problem = problem(.numbered(text), token.range.location) }
                }
            }
            scan.statementKeys.append(keys)
            scan.statementUses.append(uses)
            // `uses`: the most a statement repeats the name (MySQL refuses repeats).
            for (name, count) in uses {
                if let position = namedIndex[name] { scan.parameters[position].uses = max(scan.parameters[position].uses, count) }
            }
        }
        return scan
    }

    /// PDO's placeholder names: `[A-Za-z0-9_]+`.
    static func isBindableName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    private static func line(of location: Int, in string: NSString, from startLine: Int) -> Int {
        var line = startLine
        var index = 0
        while index < location {
            if string.character(at: index) == 10 { line += 1 }
            index += 1
        }
        return line
    }

    // MARK: Presets

    /// What `-- @param` comments preset, and the lines that couldn't be read.
    public struct Presets: Sendable, Equatable {
        public var values: [SQLParameter.Key: SQLParameterPreset] = [:]
        public var problems: [String] = []

        public init(values: [SQLParameter.Key: SQLParameterPreset] = [:], problems: [String] = []) {
            self.values = values
            self.problems = problems
        }
    }

    /// Presets from `-- @param` comments: `-- @param :name <type> [value]` anywhere in `text`
    /// (the tab) presets that name; `-- @param ?N <type> [value]` in a statement's own
    /// comments presets that statement's Nth `?`. The first line for a placeholder wins.
    /// Types: text, integer, decimal, boolean, null (and aliases such as int or bool). The
    /// value is the rest of the line, or a quoted string: `'it''s'` (SQL) or `"a\nb"` (JSON).
    public static func presets(in text: String, statements: [SQLScript.Statement]) -> Presets {
        var presets = Presets()
        func read(_ comments: [String], statement: Int?) {
            for comment in comments {
                for line in declarations(in: comment) {
                    switch parseDeclaration(line) {
                    case .success(let (placeholder, preset)):
                        if placeholder.hasPrefix("?") {
                            guard let statement, let index = Int(placeholder.dropFirst()), index > 0 else { continue }
                            let key = SQLParameter.Key.positional(statement: statement, index: index)
                            if presets.values[key] == nil { presets.values[key] = preset }
                        } else if statement == nil {
                            let key = SQLParameter.Key.named(String(placeholder.drop { $0 == ":" }))
                            if presets.values[key] == nil { presets.values[key] = preset }
                        }
                    case .failure(let message):
                        if statement == nil { presets.problems.append("@param \(line): \(message)") }
                    }
                }
            }
        }
        read(comments(in: text), statement: nil)
        for (index, statement) in statements.enumerated() {
            read(comments(in: statement.text), statement: index)
        }
        return presets
    }

    private static func comments(in text: String) -> [String] {
        let string = text as NSString
        return SQLScript.tokenize(string).filter { $0.kind == .comment }.map { string.substring(with: $0.range) }
    }

    /// The text after `@param` on each line of a comment.
    static func declarations(in comment: String) -> [String] {
        var body = Substring(comment)
        if body.hasPrefix("--") { body = body.dropFirst(2) } else if body.hasPrefix("#") { body = body.dropFirst() } else if body.hasPrefix("/*") {
            body = body.dropFirst(2)
            if body.hasSuffix("*/") { body = body.dropLast(2) }
        }
        return body.split(whereSeparator: \.isNewline).compactMap { rawLine in
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("*") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            guard line.hasPrefix("@param") else { return nil }
            let rest = line.dropFirst(6)
            guard let first = rest.first, first.isWhitespace else { return nil }
            return rest.trimmingCharacters(in: .whitespaces)
        }
    }

    /// `:name <type> [value]` or `?N <type> [value]` (the text after `@param`).
    static func parseDeclaration(_ declaration: String) -> Result<(String, SQLParameterPreset), DeclarationError> {
        let parts = declaration.split(maxSplits: 2, whereSeparator: \.isWhitespace).map(String.init)
        guard let first = parts.first else { return .failure(DeclarationError("Write it like @param :id integer 42.")) }
        var placeholder = first
        if placeholder.hasPrefix("?") {
            guard let index = Int(placeholder.dropFirst()), index > 0 else {
                return .failure(DeclarationError("Number a ? placeholder: ?1 is the statement's first ?."))
            }
        } else {
            if !placeholder.hasPrefix(":") { placeholder = ":" + placeholder }
            guard isBindableName(String(placeholder.dropFirst())) else {
                return .failure(DeclarationError("“\(first)” isn't a placeholder name (letters A–Z, digits, and _)."))
            }
        }
        guard parts.count > 1 else { return .failure(DeclarationError("The type is missing after \(placeholder): text, integer, decimal, boolean, or null.")) }
        guard let type = SQLParameterType(word: parts[1]) else {
            return .failure(DeclarationError("“\(parts[1])” is not a type. Use text, integer, decimal, boolean, or null."))
        }
        guard parts.count > 2, type != .null else { return .success((placeholder, SQLParameterPreset(type: type))) }
        guard let value = unquoted(parts[2]) else { return .failure(DeclarationError("The value's closing quote is missing.")) }
        return .success((placeholder, SQLParameterPreset(type: type, text: value)))
    }

    public struct DeclarationError: Error, Sendable, Equatable {
        public var message: String
        init(_ message: String) { self.message = message }
    }

    /// A preset's value: `'it''s'` (SQL quotes), `"a\nb"` (a JSON string), or bare text.
    static func unquoted(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("\"") {
            guard let data = "[\(text)]".data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [String], let value = array.first else { return nil }
            return value
        }
        if text.hasPrefix("'") {
            var value = ""
            var characters = text.dropFirst()
            while let character = characters.first {
                characters = characters.dropFirst()
                if character == "'" {
                    if characters.first == "'" {
                        value.append("'")
                        characters = characters.dropFirst()
                        continue
                    }
                    return characters.trimmingCharacters(in: .whitespaces).isEmpty ? value : nil
                }
                value.append(character)
            }
            return nil
        }
        return text
    }

    // MARK: History

    /// What Run History keeps for a run with values: the statement (or script) with a
    /// `-- @param` line per value, so the history shows them and reopening the entry presets
    /// the sheet with them. Names go first; each statement's `?` values go right before it.
    /// `statements` have ranges in `text`; `start` is where the kept text starts in it.
    public static func historyCode(_ text: String, start: Int, end: Int, statements: [SQLScript.Statement], scan: SQLParameterScan, values: [SQLParameter.Key: SQLParameterValue]) -> String {
        let string = text as NSString
        var pieces: [String] = []
        let named = scan.parameters.filter { if case .named = $0.key { return true } else { return false } }
        var header = named.compactMap { parameter in values[parameter.key].map { declaration(parameter.placeholder, $0) } }
        var cursor = start
        for (index, statement) in statements.enumerated() {
            let positional = scan.parameters.filter { $0.statement == index }
            guard !positional.isEmpty else { continue }
            let lines = positional.compactMap { parameter in values[parameter.key].map { declaration(parameter.placeholder, $0) } }
            let location = max(start, statement.range.location)
            if location == start {
                header += lines
                continue
            }
            var before = string.substring(with: NSRange(location: cursor, length: location - cursor))
            // On a line of their own, so they stay the statement's leading comment.
            let atLineStart = location == 0 || [10, 13].contains(string.character(at: location - 1))
            if !atLineStart {
                while before.last == " " || before.last == "\t" { before.removeLast() }
                before += "\n"
            }
            pieces.append(before)
            pieces.append(lines.joined(separator: "\n") + "\n")
            cursor = location
        }
        pieces.append(string.substring(with: NSRange(location: cursor, length: max(0, end - cursor))))
        let body = pieces.joined()
        return header.isEmpty ? body : header.joined(separator: "\n") + "\n" + body
    }

    /// `-- @param :status text paid`
    public static func declaration(_ placeholder: String, _ value: SQLParameterValue) -> String {
        switch value {
        case .null: return "-- @param \(placeholder) null"
        case .text(let text): return "-- @param \(placeholder) text \(presetText(text))"
        default: return "-- @param \(placeholder) \(value.type.word) \(value.editableText)"
        }
    }

    /// Bare when it reads back the same; otherwise a JSON string on one line.
    static func presetText(_ text: String) -> String {
        let bare = !text.isEmpty && text == text.trimmingCharacters(in: .whitespaces) && !text.hasPrefix("'") && !text.hasPrefix("\"")
            && !text.unicodeScalars.contains(where: SnippetInputs.needsEscape)
        if bare { return text }
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if SnippetInputs.needsEscape(scalar), scalar.value <= 0xFFFF {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// Text with control characters shown as escapes, for one-line display.
    static func visible(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: SnippetInputs.needsEscape) else { return text }
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if SnippetInputs.needsEscape(scalar) { out += String(format: "\\u{%X}", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }
}

// MARK: - The values sheet's form

/// The values sheet's state (#145): a type and a value per placeholder, prefilled from the
/// tab's last values or `-- @param` presets, and the values it makes.
public struct SQLParameterForm: Sendable, Equatable {
    public struct Field: Sendable, Equatable, Identifiable {
        public var parameter: SQLParameter
        public var type: SQLParameterType
        /// Text, integer, and decimal fields.
        public var text: String
        /// Boolean fields.
        public var flag: Bool

        public var id: SQLParameter.Key { parameter.key }
    }

    public var fields: [Field]

    /// Each field starts with `remembered` (the tab's last value for it), else its preset,
    /// else empty text.
    public init(scan: SQLParameterScan, presets: [SQLParameter.Key: SQLParameterPreset] = [:], remembered: (SQLParameter) -> SQLParameterValue? = { _ in nil }) {
        fields = scan.parameters.map { parameter in
            if let value = remembered(parameter) {
                if case .boolean(let flag) = value { return Field(parameter: parameter, type: .boolean, text: "", flag: flag) }
                return Field(parameter: parameter, type: value.type, text: value.editableText, flag: false)
            }
            if let preset = presets[parameter.key] {
                var flag = false
                if preset.type == .boolean, let text = preset.text, case .success(let value) = SQLParameterForm.parse(text, as: .boolean), case .boolean(let parsed) = value { flag = parsed }
                return Field(parameter: parameter, type: preset.type, text: preset.type == .boolean ? "" : preset.text ?? "", flag: flag)
            }
            return Field(parameter: parameter, type: .text, text: "", flag: false)
        }
    }

    public struct ParseError: Error, Sendable, Equatable {
        public var message: String
    }

    /// Reads typed text as a value of `type`. Text is kept as typed; numbers are trimmed.
    public static func parse(_ text: String, as type: SQLParameterType) -> Result<SQLParameterValue, ParseError> {
        switch type {
        case .text:
            return .success(.text(text))
        case .null:
            return .success(.null)
        case .boolean:
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "1", "yes", "on", "t": return .success(.boolean(true))
            case "false", "0", "no", "off", "f": return .success(.boolean(false))
            default: return .failure(ParseError(message: "Use true or false."))
            }
        case .integer:
            switch SnippetInput.Kind.int.parse(text) {
            case .success(.int(let value)): return .success(.integer(value))
            case .failure(let error): return .failure(ParseError(message: error.message))
            default: return .failure(ParseError(message: "Enter a whole number, like 42."))
            }
        case .decimal:
            switch SnippetInput.Kind.float.parse(text) {
            case .success: return .success(.decimal(text.trimmingCharacters(in: .whitespaces)))
            case .failure(let error): return .failure(ParseError(message: error.message.replacingOccurrences(of: "a float", with: "a number")))
            }
        }
    }

    public func value(of field: Field) -> Result<SQLParameterValue, ParseError> {
        field.type == .boolean ? .success(.boolean(field.flag)) : Self.parse(field.text, as: field.type)
    }

    /// Why the field isn't valid, or nil.
    public func error(for field: Field) -> String? {
        if case .failure(let error) = value(of: field) { return error.message }
        return nil
    }

    /// Every value, or nil while a field isn't valid.
    public var values: [SQLParameter.Key: SQLParameterValue]? {
        var values: [SQLParameter.Key: SQLParameterValue] = [:]
        for field in fields {
            guard case .success(let value) = value(of: field) else { return nil }
            values[field.parameter.key] = value
        }
        return values
    }

    public var isValid: Bool { values != nil }

    /// Sets a field as the sheet would: `type` when given, then the text (a boolean reads
    /// true or false). False when there is no such placeholder. `placeholder` is `:name`,
    /// `?N`, or `?N@S` (the Nth `?` of statement S, 1-based, in Run All).
    @discardableResult
    public mutating func set(_ placeholder: String, type: SQLParameterType? = nil, text: String? = nil) -> Bool {
        guard let index = fields.firstIndex(where: { Self.matches($0.parameter, placeholder) }) else { return false }
        if let type { fields[index].type = type }
        if let text {
            if fields[index].type == .boolean {
                guard case .success(.boolean(let flag)) = Self.parse(text, as: .boolean) else { return false }
                fields[index].flag = flag
            } else {
                fields[index].text = text
            }
        }
        return true
    }

    static func matches(_ parameter: SQLParameter, _ placeholder: String) -> Bool {
        switch parameter.key {
        case .named(let name):
            return placeholder == ":" + name || placeholder == name
        case .positional(let statement, let index):
            let parts = placeholder.dropFirst(placeholder.hasPrefix("?") ? 1 : 0).split(separator: "@").map(String.init)
            guard let wanted = parts.first.flatMap(Int.init), wanted == index else { return false }
            return parts.count == 1 ? true : Int(parts[1]) == statement + 1
        }
    }
}

// MARK: - Remembered values

/// The values a tab used last (#145), in memory for this session only: by name for `:name`,
/// and by statement text and position for `?`, so another statement's `?` doesn't inherit them.
public struct SQLParameterMemory: Sendable, Equatable {
    public private(set) var values: [String: SQLParameterValue] = [:]

    public init() {}

    static func key(_ parameter: SQLParameter, statements: [SQLScript.Statement]) -> String {
        switch parameter.key {
        case .named(let name):
            return ":" + name
        case .positional(let statement, let index):
            let text = statements.indices.contains(statement) ? statements[statement].text.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            return "?\(index)\u{1F}" + text
        }
    }

    public func value(for parameter: SQLParameter, statements: [SQLScript.Statement]) -> SQLParameterValue? {
        values[Self.key(parameter, statements: statements)]
    }

    public mutating func remember(_ values: [SQLParameter.Key: SQLParameterValue], scan: SQLParameterScan, statements: [SQLScript.Statement]) {
        for parameter in scan.parameters {
            if let value = values[parameter.key] { self.values[Self.key(parameter, statements: statements)] = value }
        }
    }
}
