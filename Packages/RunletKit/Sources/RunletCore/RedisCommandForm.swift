import Foundation

/// The command builder's value for one argument of a `RedisCommandSpec` (#218), the same tree
/// as the argument: whether an optional part is on (a pure token, a choice, a block), and one
/// row per repetition with its value, its choice, and its parts' values.
public struct RedisArgumentValue: Sendable, Equatable, Hashable {
    public struct Row: Sendable, Equatable, Hashable {
        /// A value argument's text: nil when the field is empty, `""` for an explicit empty
        /// string (`SET key ""`).
        public var value: String?
        /// A one-of argument's branch.
        public var choice: Int
        /// A block's parts, or a one-of's branches, in the spec's order.
        public var children: [RedisArgumentValue]

        public init(value: String? = nil, choice: Int = 0, children: [RedisArgumentValue] = []) {
            self.value = value
            self.choice = choice
            self.children = children
        }

        public static func empty(_ argument: RedisArgument) -> Row {
            switch argument.kind {
            case .oneOf, .block: Row(children: argument.children.map(RedisArgumentValue.empty))
            default: Row()
            }
        }

        /// Nothing typed or turned on in it.
        public var isBlank: Bool { value == nil && children.allSatisfy(\.isBlank) }
    }

    /// An optional pure token, choice, or block is on. Value arguments are on when they hold
    /// a value; required arguments always are.
    public var isOn: Bool
    public var rows: [Row]

    public init(isOn: Bool, rows: [Row]) {
        self.isOn = isOn
        self.rows = rows
    }

    public static func empty(_ argument: RedisArgument) -> Self {
        Self(isOn: !argument.isOptional, rows: [Row.empty(argument)])
    }

    /// No value typed anywhere in it (on/off toggles aside).
    public var isBlank: Bool { rows.allSatisfy(\.isBlank) }
}

/// How each word of a command line is used (#218, and completion's key positions, #206).
public enum RedisArgumentRole: Sendable, Equatable, Hashable {
    /// The command's name, and a container's subcommand.
    case command
    /// An option or keyword (`EX`, `WITHSCORES`, `LIMIT`).
    case token
    /// A key name.
    case key
    /// Another value: the argument's name (`seconds`, `member`).
    case value(String)
    /// `numkeys`: how many of the next argument follow.
    case count
    /// A word the spec doesn't place.
    case unknown
}

/// A Redis command as the builder's form (#218): a spec and a value per argument, or, for a
/// command Runlet has no syntax for, its name and raw arguments. It renders the exact command
/// line (quoted as `RedisScript.parse` reads it) and reads one back: a line typed by hand fills
/// the form, and words it can't place stay raw (`extra`), written after the others, so nothing
/// is lost. Nothing here runs anything.
public struct RedisCommandForm: Sendable, Equatable {
    /// Nil: a command without a spec, built from `rawName` and `extra`.
    public var spec: RedisCommandSpec?
    /// The command's words for a form without a spec (`CLUSTER INFO`).
    public var rawName: String
    /// One per argument of the spec.
    public var values: [RedisArgumentValue]
    /// Arguments the form couldn't place (or every argument of a command without a spec),
    /// written last, as they are.
    public var extra: [String]

    public init(spec: RedisCommandSpec) {
        self.spec = spec
        rawName = ""
        values = spec.arguments.map(RedisArgumentValue.empty)
        extra = []
    }

    /// A form of raw arguments for a command without a spec.
    public init(rawName: String, arguments: [String] = []) {
        spec = nil
        self.rawName = rawName
        values = []
        extra = arguments
    }

    /// A problem with a field: blocking ones (a missing key, a number that isn't one) keep the
    /// builder from writing the command.
    public struct Issue: Sendable, Equatable, Hashable {
        public var message: String
        public var isBlocking: Bool

        public init(_ message: String, blocking: Bool = true) {
            self.message = message
            isBlocking = blocking
        }
    }

    /// The command's words: the spec's name, or the raw name split at spaces.
    public var nameWords: [String] {
        spec?.words ?? rawName.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    /// The command line's arguments, the name first, and what's wrong with the form.
    public func render() -> (arguments: [String], issues: [Issue]) {
        var renderer = Renderer()
        var arguments = nameWords
        if arguments.isEmpty { renderer.issues.append(Issue("Choose a command.")) }
        if let spec { arguments += renderer.sequence(spec.arguments, values) }
        arguments += extra
        return (arguments, renderer.issues)
    }

    public var arguments: [String] { render().arguments }
    public var issues: [Issue] { render().issues }

    /// The line the builder writes into the tab: each argument as `redis-cli` quotes it.
    public var line: String { arguments.map(RedisScript.quoted).joined(separator: " ") }

    /// Whether the builder may write the line: a command, and no blocking issue.
    public var canWrite: Bool { !nameWords.isEmpty && !render().issues.contains(where: \.isBlocking) }

    /// How Runlet will treat the line when it runs: read, write, dangerous, …
    public var info: RedisCommands.Info { RedisCommands.classify(arguments) }

    // MARK: Reading a command line

    /// The form for a command line's arguments (the name first): the spec's, filled from the
    /// arguments, or raw arguments for a command without one.
    public static func parse(_ arguments: [String]) -> RedisCommandForm {
        parseWithRoles(arguments).form
    }

    /// The form and how each argument is used.
    public static func parseWithRoles(_ arguments: [String]) -> (form: RedisCommandForm, roles: [RedisArgumentRole]) {
        guard let (spec, count) = RedisCommandSpecs.spec(for: arguments) else {
            let name = arguments.first.map { $0.uppercased() } ?? ""
            return (RedisCommandForm(rawName: name, arguments: Array(arguments.dropFirst())), arguments.isEmpty ? [] : [.command] + Array(repeating: .unknown, count: arguments.count - 1))
        }
        let words = Array(arguments.dropFirst(count))
        let best = Matcher(words: words).match(spec.arguments)
        var form = RedisCommandForm(spec: spec)
        form.values = best.values
        form.extra = Array(words[best.consumed...])
        let roles = Array(repeating: RedisArgumentRole.command, count: count) + best.roles + Array(repeating: .unknown, count: words.count - best.consumed)
        return (form, roles)
    }

    /// The form for a line of a Redis tab; nil when it holds no command (blank, a comment), or
    /// can't be read (a quote isn't closed, bytes that aren't UTF-8).
    public static func parse(line: String) -> Result<RedisCommandForm, ReadError> {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .failure(.blank) }
        guard !trimmed.hasPrefix("#") else { return .failure(.comment) }
        switch RedisScript.parse(trimmed) {
        case .failure(let error):
            return .failure(.unreadable(error.description))
        case .success(let arguments):
            guard !arguments.isEmpty else { return .failure(.blank) }
            var strings: [String] = []
            for argument in arguments {
                guard let text = String(bytes: argument, encoding: .utf8) else {
                    return .failure(.unreadable("It holds bytes that aren't UTF-8 (\\x…), which the builder's fields can't show."))
                }
                strings.append(text)
            }
            return .success(parse(strings))
        }
    }

    public enum ReadError: Error, Sendable, Equatable {
        case blank
        case comment
        case unreadable(String)
    }

    // MARK: Prefilling

    /// The spec's form with `arguments` (after the name) placed, e.g. `["key", "0", "-1"]` for LRANGE.
    public static func prefilled(_ name: String, _ arguments: [String]) -> RedisCommandForm {
        parse(name.split(separator: " ").map(String.init) + arguments)
    }
}

// MARK: - Rendering

private struct Renderer {
    var issues: [RedisCommandForm.Issue] = []

    mutating func sequence(_ arguments: [RedisArgument], _ values: [RedisArgumentValue]) -> [String] {
        var words: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let value = index < values.count ? values[index] : .empty(argument)
            if argument.kind == .count, index + 1 < arguments.count {
                // numkeys: the number of the next argument's values.
                let next = arguments[index + 1]
                let nextValue = index + 1 < values.count ? values[index + 1] : .empty(next)
                let rows = renderRows(next, nextValue) ?? []
                words.append(String(rows.count))
                words += tokenized(next, rows)
                index += 2
                continue
            }
            if let rows = renderRows(argument, value) { words += tokenized(argument, rows) }
            index += 1
        }
        return words
    }

    /// The argument's words: its rows after its token, or with the token before each row.
    private func tokenized(_ argument: RedisArgument, _ rows: [[String]]) -> [String] {
        if argument.kind == .pureToken { return rows.isEmpty ? [] : [argument.token ?? argument.name] }
        guard !rows.isEmpty else { return [] }
        if argument.tokenEachRow, let token = argument.token { return rows.flatMap { [token] + $0 } }
        return (argument.token.map { [$0] } ?? []) + rows.flatMap { $0 }
    }

    /// Each row's words (without the argument's token); nil when the argument is left out.
    private mutating func renderRows(_ argument: RedisArgument, _ value: RedisArgumentValue) -> [[String]]? {
        switch argument.kind {
        case .pureToken:
            return argument.isOptional && !value.isOn ? nil : [[]]
        case .count:
            return [[]]
        case .oneOf:
            if argument.isOptional, !value.isOn { return nil }
            return value.rows.map { row in
                let choice = min(max(0, row.choice), argument.children.count - 1)
                var branch = argument.children[choice]
                branch.isOptional = false
                let branchValue = choice < row.children.count ? row.children[choice] : .empty(branch)
                return tokenized(branch, renderRows(branch, branchValue) ?? [])
            }
        case .block:
            if argument.isOptional, !value.isOn { return nil }
            var rows = value.rows
            if argument.isMultiple, rows.count > 1 {
                // Blank rows (one added and left empty) are skipped, unless all of them are.
                let filled = rows.filter { !$0.isBlank }
                rows = filled.isEmpty ? [rows[0]] : filled
            }
            if argument.isColumnwise {
                // STREAMS key [key …] id [id …]: every key, then every id.
                var columns: [[String]] = Array(repeating: [], count: argument.children.count)
                for row in rows {
                    for (index, child) in argument.children.enumerated() {
                        let text = index < row.children.count ? row.children[index].rows.first?.value : nil
                        if let word = renderValue(child, text, required: true) { columns[index].append(word) }
                    }
                }
                return [columns.flatMap { $0 }]
            }
            return rows.map { sequence(argument.children, $0.children) }
        case .key, .string, .integer, .double, .pattern, .unixTime:
            if argument.isMultiple {
                let given = value.rows.compactMap(\.value)
                if given.isEmpty {
                    if argument.isOptional { return nil }
                    issues.append(.init("Fill in \(argument.name)."))
                    return []
                }
                return given.compactMap { renderValue(argument, $0, required: true) }.map { [$0] }
            }
            guard let text = value.rows.first?.value else {
                if !argument.isOptional { issues.append(.init("Fill in \(argument.name).")) }
                return nil
            }
            guard let word = renderValue(argument, text, required: true) else { return nil }
            return [[word]]
        }
    }

    /// A value's word, checked against its type; nil when it is missing.
    private mutating func renderValue(_ argument: RedisArgument, _ text: String?, required: Bool) -> String? {
        guard let text else {
            if required { issues.append(.init("Fill in \(argument.name).")) }
            return nil
        }
        switch argument.kind {
        case .integer, .unixTime:
            if Int64(text) == nil, UInt64(text) == nil { issues.append(.init("\(argument.name) must be a whole number.")) }
        case .double:
            if !RedisCommandForm.isScore(text) { issues.append(.init("\(argument.name) must be a number.")) }
        case .key:
            if text.isEmpty { issues.append(.init("The \(argument.name) is the empty key name \"\".", blocking: false)) }
        case .string:
            if text.isEmpty { issues.append(.init("\(argument.name) is an empty string \"\".", blocking: false)) }
        default:
            break
        }
        return text
    }
}

extension RedisCommandForm {
    /// A number Redis reads as a double: `1.5`, `-3`, `1e3`, `inf`, `+inf`, `-inf`.
    static func isScore(_ text: String) -> Bool {
        let lower = text.lowercased()
        if ["inf", "+inf", "-inf", "infinity", "+infinity", "-infinity"].contains(lower) { return true }
        guard let value = Double(text) else { return false }
        return !value.isNaN
    }
}

// MARK: - Matching a line to a spec

/// A backtracking matcher of a command's words to its spec: options in any order (Redis reads
/// them so), repeated arguments up to the next option word or to `numkeys`, `STREAMS key …
/// id …` split in half, and missing words at the end of the line (a command typed halfway).
/// The best match places the most words, then misses the fewest, and the first found wins a
/// tie (repeated arguments take as many words as they can); the words after it stay raw.
private final class Matcher {
    struct Best {
        var consumed: Int
        var missing: Int
        var values: [RedisArgumentValue]
        var roles: [RedisArgumentRole]
    }

    typealias Done = (_ index: Int, _ value: RedisArgumentValue, _ missing: Int, _ roles: [RedisArgumentRole]) -> Bool
    typealias SequenceDone = (_ index: Int, _ values: [RedisArgumentValue], _ missing: Int, _ roles: [RedisArgumentRole]) -> Bool

    static let budget = 50_000

    let words: [String]
    let upper: [String]
    private var steps = 0
    private var best: Best?

    init(words: [String]) {
        self.words = words
        upper = words.map { $0.uppercased() }
    }

    func match(_ arguments: [RedisArgument]) -> Best {
        let empty = arguments.map(RedisArgumentValue.empty)
        _ = sequence(arguments, at: 0, index: 0, values: empty, missing: 0, roles: [], stops: [], topLevel: true) { _, _, _, _ in false }
        return best ?? Best(consumed: 0, missing: 0, values: empty, roles: [])
    }

    /// Keeps the better match; true when it places every word and misses none (search ends).
    private func consider(_ index: Int, _ values: [RedisArgumentValue], _ missing: Int, _ roles: [RedisArgumentRole]) -> Bool {
        if let best, best.consumed > index || (best.consumed == index && best.missing <= missing) { return false }
        best = Best(consumed: index, missing: missing, values: values, roles: roles)
        return index == words.count && missing == 0
    }

    private func overBudget() -> Bool {
        steps += 1
        return steps > Self.budget
    }

    /// The words that end a repetition: the tokens the arguments after it start with.
    private func following(_ arguments: [RedisArgument], from start: Int, _ stops: Set<String>) -> Set<String> {
        guard start < arguments.count else { return stops }
        return arguments[start...].reduce(into: stops) { $0.formUnion($1.leadingTokens) }
    }

    private static func off(_ argument: RedisArgument) -> RedisArgumentValue {
        var value = RedisArgumentValue.empty(argument)
        value.isOn = false
        return value
    }

    // swiftlint:disable:next function_parameter_count
    private func sequence(_ arguments: [RedisArgument], at position: Int, index: Int, values: [RedisArgumentValue], missing: Int,
                          roles: [RedisArgumentRole], stops: Set<String>, topLevel: Bool, done: SequenceDone) -> Bool {
        if overBudget() { return true }
        if topLevel {
            // Stopping here leaves the rest of the words raw.
            let required = arguments[position...].filter { !$0.isOptional }.count
            if consider(index, values, missing + required, roles) { return true }
            if position == arguments.count { return false }
        } else if position == arguments.count {
            return done(index, values, missing, roles)
        }
        let argument = arguments[position]

        // Options that start with a token, in any order.
        if argument.isOptional, !argument.leadingTokens.isEmpty {
            var end = position
            while end < arguments.count, arguments[end].isOptional, !arguments[end].leadingTokens.isEmpty { end += 1 }
            return options(arguments, run: Array(position..<end), used: [], index: index, values: values, missing: missing, roles: roles,
                           stops: following(arguments, from: end, stops)) { i, v, m, r in
                self.sequence(arguments, at: end, index: i, values: v, missing: m, roles: r, stops: stops, topLevel: topLevel, done: done)
            }
        }

        // numkeys, then exactly that many of the next argument.
        if argument.kind == .count, position + 1 < arguments.count {
            let next = arguments[position + 1]
            guard index < words.count else {
                return sequence(arguments, at: position + 2, index: index, values: values, missing: missing + 1, roles: roles, stops: stops, topLevel: topLevel, done: done)
            }
            guard let count = Int(words[index]), count >= 0 else { return false }
            return value(next, index: index + 1, exact: count, stops: following(arguments, from: position + 2, stops)) { i, v, m, r in
                var values = values
                values[position + 1] = v
                return self.sequence(arguments, at: position + 2, index: i, values: values, missing: missing + m, roles: roles + [.count] + r, stops: stops, topLevel: topLevel, done: done)
            }
        }

        if index < words.count {
            let found = self.argument(argument, index: index, stops: following(arguments, from: position + 1, stops)) { i, v, m, r in
                var values = values
                values[position] = v
                return self.sequence(arguments, at: position + 1, index: i, values: values, missing: missing + m, roles: roles + r, stops: stops, topLevel: topLevel, done: done)
            }
            if found { return true }
        }
        if argument.isOptional {
            var values = values
            values[position] = Self.off(argument)
            return sequence(arguments, at: position + 1, index: index, values: values, missing: missing, roles: roles, stops: stops, topLevel: topLevel, done: done)
        }
        if index >= words.count {
            // The line ends before this argument: it stays empty.
            return sequence(arguments, at: position + 1, index: index, values: values, missing: missing + 1, roles: roles, stops: stops, topLevel: topLevel, done: done)
        }
        return false
    }

    /// A run of optional arguments that start with tokens, matched in any order.
    // swiftlint:disable:next function_parameter_count
    private func options(_ arguments: [RedisArgument], run: [Int], used: Set<Int>, index: Int, values: [RedisArgumentValue], missing: Int,
                         roles: [RedisArgumentRole], stops: Set<String>, done: SequenceDone) -> Bool {
        if overBudget() { return true }
        if index < words.count {
            let word = upper[index]
            for position in run where !used.contains(position) && arguments[position].leadingTokens.contains(word) {
                var required = arguments[position]
                required.isOptional = false
                // An option's values end at another option of the run.
                let others = run.filter { $0 != position }.reduce(into: stops) { $0.formUnion(arguments[$1].leadingTokens) }
                let found = argument(required, index: index, stops: others) { i, v, m, r in
                    var values = values
                    var value = v
                    value.isOn = true
                    values[position] = value
                    return self.options(arguments, run: run, used: used.union([position]), index: i, values: values, missing: missing + m, roles: roles + r, stops: stops, done: done)
                }
                if found { return true }
            }
        }
        var values = values
        for position in run where !used.contains(position) { values[position] = Self.off(arguments[position]) }
        return done(index, values, missing, roles)
    }

    /// One argument at `index` (the caller leaves an optional one out).
    private func argument(_ argument: RedisArgument, index: Int, stops: Set<String>, done: Done) -> Bool {
        if overBudget() { return true }
        switch argument.kind {
        case .pureToken:
            guard index < words.count, upper[index] == argument.token?.uppercased() else { return false }
            return done(index + 1, RedisArgumentValue(isOn: true, rows: [.init()]), 0, [.token])
        case .count:
            return false
        case .oneOf:
            var start = index
            var roles: [RedisArgumentRole] = []
            if let token = argument.token {
                guard index < words.count, upper[index] == token.uppercased() else { return false }
                start += 1
                roles.append(.token)
                if start >= words.count {
                    // `AGGREGATE` at the end of the line: the choice is missing.
                    return done(start, RedisArgumentValue(isOn: true, rows: [.empty(argument)]), 1, roles)
                }
            }
            // Token branches first, so `$` is the `$` choice rather than an id that says `$`.
            let order = argument.children.indices.sorted {
                (argument.children[$0].leadingTokens.isEmpty ? 1 : 0, $0) < (argument.children[$1].leadingTokens.isEmpty ? 1 : 0, $1)
            }
            for choice in order where start < words.count {
                var branch = argument.children[choice]
                branch.isOptional = false
                let found = self.argument(branch, index: start, stops: stops) { i, v, m, r in
                    var row = RedisArgumentValue.Row.empty(argument)
                    row.choice = choice
                    row.children[choice] = v
                    return done(i, RedisArgumentValue(isOn: true, rows: [row]), m, roles + r)
                }
                if found { return true }
            }
            return false
        case .block:
            var start = index
            var roles: [RedisArgumentRole] = []
            if let token = argument.token {
                guard index < words.count, upper[index] == token.uppercased() else { return false }
                start += 1
                roles.append(.token)
            }
            if argument.isColumnwise { return columns(argument, index: start, roles: roles, done: done) }
            return blockRows(argument, index: start, rows: [], missing: 0, roles: roles, stops: stops, done: done)
        case .key, .string, .integer, .double, .pattern, .unixTime:
            return value(argument, index: index, exact: nil, stops: stops, done: done)
        }
    }

    /// A block's rows: one, then (for a repeated block) more while the words allow.
    // swiftlint:disable:next function_parameter_count
    private func blockRows(_ argument: RedisArgument, index: Int, rows: [RedisArgumentValue.Row], missing: Int, roles: [RedisArgumentRole],
                           stops: Set<String>, done: Done) -> Bool {
        let empty = argument.children.map(RedisArgumentValue.empty)
        return sequence(argument.children, at: 0, index: index, values: empty, missing: 0, roles: [], stops: stops, topLevel: false) { i, values, m, r in
            let rows = rows + [RedisArgumentValue.Row(children: values)]
            let missing = missing + m
            let roles = roles + r
            if argument.isMultiple, m == 0, i > index, i < self.words.count, !stops.contains(self.upper[i]) {
                if self.blockRows(argument, index: i, rows: rows, missing: missing, roles: roles, stops: stops, done: done) { return true }
            }
            return done(i, RedisArgumentValue(isOn: true, rows: rows), missing, roles)
        }
    }

    /// A value argument: once (after its token), or repeated (`exact` times for numkeys, else
    /// up to the next option word, as many as possible first), or `TOKEN value [TOKEN value …]`.
    private func value(_ argument: RedisArgument, index: Int, exact: Int?, stops: Set<String>, done: Done) -> Bool {
        let role: RedisArgumentRole = argument.kind == .key ? .key : .value(argument.name)
        if argument.tokenEachRow, let token = argument.token?.uppercased() {
            var rows: [RedisArgumentValue.Row] = []
            var roles: [RedisArgumentRole] = []
            var i = index
            var missing = 0
            while i < words.count, upper[i] == token {
                if i + 1 < words.count {
                    rows.append(.init(value: words[i + 1]))
                    roles += [.token, role]
                    i += 2
                } else {
                    rows.append(.init())
                    roles.append(.token)
                    missing += 1
                    i += 1
                }
            }
            guard !rows.isEmpty else { return false }
            return done(i, RedisArgumentValue(isOn: true, rows: rows), missing, roles)
        }
        var start = index
        var roles: [RedisArgumentRole] = []
        if let token = argument.token {
            guard index < words.count, upper[index] == token.uppercased() else { return false }
            start += 1
            roles.append(.token)
        }
        guard argument.isMultiple else {
            guard start < words.count else {
                // `EX` at the end of the line: the seconds are missing.
                return done(start, RedisArgumentValue(isOn: true, rows: [.init()]), 1, roles)
            }
            return done(start + 1, RedisArgumentValue(isOn: true, rows: [.init(value: words[start])]), 0, roles + [role])
        }
        if let exact {
            let available = max(0, min(exact, words.count - start))
            let rows = available == 0 ? [RedisArgumentValue.Row()] : (0..<available).map { RedisArgumentValue.Row(value: words[start + $0]) }
            return done(start + available, RedisArgumentValue(isOn: true, rows: rows), exact - available, roles + Array(repeating: role, count: available))
        }
        var most = 0
        while start + most < words.count, !stops.contains(upper[start + most]) { most += 1 }
        if most == 0 {
            // A repeated argument at the end of the line: its first value is missing.
            guard start >= words.count else { return false }
            return done(start, RedisArgumentValue(isOn: true, rows: [.init()]), 1, roles)
        }
        // As many as possible first, then fewer (BLPOP key [key …] timeout).
        for count in stride(from: most, through: 1, by: -1) {
            let rows = (0..<count).map { RedisArgumentValue.Row(value: words[start + $0]) }
            if done(start + count, RedisArgumentValue(isOn: true, rows: rows), 0, roles + Array(repeating: role, count: count)) { return true }
        }
        return false
    }

    /// `STREAMS key [key …] id [id …]`: the rest of the line, keys in its first half.
    private func columns(_ argument: RedisArgument, index: Int, roles: [RedisArgumentRole], done: Done) -> Bool {
        let remaining = words.count - index
        let width = argument.children.count
        guard width > 0 else { return false }
        guard remaining > 0 else {
            return done(index, RedisArgumentValue(isOn: true, rows: [.empty(argument)]), width, roles)
        }
        let rowCount = (remaining + width - 1) / width
        var rows: [RedisArgumentValue.Row] = []
        var columnRoles = Array(repeating: RedisArgumentRole.unknown, count: remaining)
        for row in 0..<rowCount {
            var children: [RedisArgumentValue] = []
            for (column, child) in argument.children.enumerated() {
                let offset = column * rowCount + row
                let text: String? = offset < remaining ? words[index + offset] : nil
                if offset < remaining { columnRoles[offset] = child.kind == .key ? .key : .value(child.name) }
                children.append(RedisArgumentValue(isOn: true, rows: [.init(value: text)]))
            }
            rows.append(.init(children: children))
        }
        return done(words.count, RedisArgumentValue(isOn: true, rows: rows), rowCount * width - remaining, roles + columnRoles)
    }
}

// MARK: - Writing into the tab

/// Where the builder (#218) writes in a Redis tab, and what it reads back: the caret's line.
public enum RedisBuilderText {
    /// One replacement in the tab's text: one undoable edit.
    public struct Edit: Sendable, Equatable {
        public var range: NSRange
        public var replacement: String
        /// Where the caret goes: the end of the written command.
        public var caret: Int
    }

    /// The caret's line: its range without the line break, and its number (1-based).
    public static func caretLine(in text: String, at location: Int) -> (range: NSRange, number: Int) {
        let string = text as NSString
        let location = min(max(0, location), string.length)
        var start = 0, end = 0, contentsEnd = 0
        string.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
        let before = string.substring(to: start)
        let number = before.reduce(into: 1) { count, character in if character.isNewline { count += 1 } }
        return (NSRange(location: start, length: contentsEnd - start), number)
    }

    /// Insert: the command on a new line after the caret's line, or on that line when it is blank.
    public static func insert(_ command: String, in text: String, at location: Int) -> Edit {
        let (range, _) = caretLine(in: text, at: location)
        let content = (text as NSString).substring(with: range)
        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            return Edit(range: range, replacement: command, caret: range.location + (command as NSString).length)
        }
        let end = NSMaxRange(range)
        return Edit(range: NSRange(location: end, length: 0), replacement: "\n" + command, caret: end + 1 + (command as NSString).length)
    }

    /// Replace Line: the command in place of the caret's command line (its indentation stays);
    /// on a blank line, written there. Nil on a comment line.
    public static func replace(_ command: String, in text: String, at location: Int) -> Edit? {
        let (range, _) = caretLine(in: text, at: location)
        let content = (text as NSString).substring(with: range)
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return insert(command, in: text, at: location) }
        if trimmed.hasPrefix("#") { return nil }
        let leading = (content as NSString).range(of: trimmed).location
        let target = NSRange(location: range.location + (leading == NSNotFound ? 0 : leading), length: (trimmed as NSString).length)
        return Edit(range: target, replacement: command, caret: target.location + (command as NSString).length)
    }

    /// What the caret's line holds, for Read Line.
    public static func read(_ text: String, at location: Int) -> (line: Int, result: Result<RedisCommandForm, RedisCommandForm.ReadError>) {
        let (range, number) = caretLine(in: text, at: location)
        return (number, RedisCommandForm.parse(line: (text as NSString).substring(with: range)))
    }
}

// MARK: - Key browser

/// One of a key's Insert Command items in the key browser (#218): the builder opens with it.
public struct RedisKeyCommand: Sendable, Equatable, Identifiable {
    /// The menu item: `GET`, `LRANGE 0 -1`, `EXPIRE…`.
    public var title: String
    public var form: RedisCommandForm
    public var id: String { title }
}

extension RedisKeyEntry {
    /// The key browser's Insert Command items: the command that reads the key by its type
    /// (`GET`, `HGETALL`, `LRANGE 0 -1`, `SMEMBERS`, `ZRANGE 0 -1 WITHSCORES`, `XRANGE - +`, or
    /// `TYPE` when it isn't known), then `TTL`, `EXPIRE`, `PERSIST`, `DEL`, and `RENAME`. Empty
    /// for a key whose bytes aren't UTF-8 (the builder's fields hold text).
    public var builderCommands: [RedisKeyCommand] {
        guard let key else { return [] }
        let read: (String, [String]) = switch type {
        case "string": ("GET", [key])
        case "hash": ("HGETALL", [key])
        case "list": ("LRANGE", [key, "0", "-1"])
        case "set": ("SMEMBERS", [key])
        case "zset": ("ZRANGE", [key, "0", "-1", "WITHSCORES"])
        case "stream": ("XRANGE", [key, "-", "+"])
        default: ("TYPE", [key])
        }
        let readTitle = ([read.0] + read.1.dropFirst()).joined(separator: " ")
        return [
            RedisKeyCommand(title: readTitle, form: .prefilled(read.0, read.1)),
            RedisKeyCommand(title: "TTL", form: .prefilled("TTL", [key])),
            RedisKeyCommand(title: "EXPIRE…", form: .prefilled("EXPIRE", [key])),
            RedisKeyCommand(title: "PERSIST", form: .prefilled("PERSIST", [key])),
            RedisKeyCommand(title: "DEL", form: .prefilled("DEL", [key])),
            RedisKeyCommand(title: "RENAME…", form: .prefilled("RENAME", [key])),
        ]
    }
}
