import Foundation

/// Completion in Redis tabs (#206): command names at the start of a line (with their syntax,
/// summary, and how every run treats them), a container's subcommands, the option words the
/// command's grammar allows next, values Runlet suggests (INFO sections, `SCAN … TYPE`'s types),
/// and, in key positions, key names Runlet already read. It reads the caret's line with
/// `RedisScript`'s tokeniser and places the words with the command builder's matcher
/// (`RedisCommandForm.parseWithRoles`) over `RedisCommandSpecs` (#218), so completion and the
/// builder read a line the same way. Nothing here talks to Redis: typing never sends anything.
public enum RedisCompletion {
    // MARK: Keys Runlet already read

    /// A key name Runlet read before, and where from.
    public struct KnownKey: Sendable, Equatable, Hashable {
        public enum Source: String, Sendable, Hashable, CaseIterable {
            /// The key browser's last scan of this connection and database.
            case keyBrowser
            /// Load Keys for Completion's scan.
            case loaded
            /// A reply in this tab (SCAN, KEYS, RANDOMKEY).
            case reply

            public var label: String {
                switch self {
                case .keyBrowser: "key browser"
                case .loaded: "loaded for completion"
                case .reply: "a reply in this tab"
                }
            }
        }

        public var name: String
        /// `TYPE`'s answer, when the key browser read it.
        public var type: String?
        public var source: Source

        public init(name: String, type: String? = nil, source: Source) {
            self.name = name
            self.type = type
            self.source = source
        }
    }

    /// The keys completion offers for database `db`: the key browser's last scan when it read
    /// that database, the keys Load Keys for Completion read there, and the keys this tab's
    /// replies named in it (a reply whose database isn't known counts). Key names whose bytes
    /// aren't UTF-8 are left out (a tab's text can't hold them).
    public static func knownKeys(db: Int, browser: (db: Int, keys: [RedisKeyEntry])?, loaded: [String], replies: [RedisReplyInfo]) -> [KnownKey] {
        var keys: [KnownKey] = []
        if let browser, browser.db == db {
            keys += browser.keys.compactMap { entry in entry.key.map { KnownKey(name: $0, type: entry.type, source: .keyBrowser) } }
        }
        keys += loaded.map { KnownKey(name: $0, source: .loaded) }
        for reply in replies where reply.db == nil || reply.db == db {
            keys += Self.keys(in: reply).map { KnownKey(name: $0, source: .reply) }
        }
        return keys
    }

    /// The key names a reply lists: `SCAN`'s keys, `KEYS`, and `RANDOMKEY`.
    public static func keys(in reply: RedisReplyInfo) -> [String] {
        func text(_ value: RedisValue) -> String? {
            if case .string(let text) = value { return text }
            return nil
        }
        switch RedisCommands.key(reply.argv) {
        case "SCAN":
            guard let elements = reply.reply.elements, elements.count == 2 else { return [] }
            return elements[1].elements?.compactMap(text) ?? []
        case "KEYS":
            return reply.reply.elements?.compactMap(text) ?? []
        case "RANDOMKEY":
            return text(reply.reply).map { [$0] } ?? []
        default:
            return []
        }
    }

    // MARK: Load Keys for Completion

    /// The list's action item: an action (`loadKeysAction`) instead of text.
    public struct KeyLoadOffer: Sendable, Equatable {
        public var title: String
        public var detail: String

        public init(title: String, detail: String) {
            self.title = title
            self.detail = detail
        }
    }

    /// The `action` of the Load Keys for Completion item.
    public static let loadKeysAction = "redis.load-keys"

    /// Load Keys for Completion's SCAN `COUNT`: one SCAN call, which reads about this many of
    /// the database's keys.
    public static let loadCount = 1000

    /// The SCAN `MATCH` pattern for keys that start with `prefix`: its glob characters
    /// (`*`, `?`, `[`, `]`, `\`) escaped, then `*`.
    public static func loadPattern(prefix: String) -> String {
        var pattern = ""
        for character in prefix {
            if "*?[]\\".contains(character) { pattern.append("\\") }
            pattern.append(character)
        }
        return pattern + "*"
    }

    // MARK: The caret's word

    /// The word at the caret and the complete words before it on its line.
    public struct Context: Sendable, Equatable {
        /// UTF-16 offset where the word being completed starts: its opening quote, if any.
        public var anchor: Int
        /// The word typed so far, without its quote and escapes.
        public var prefix: String
        /// The quote the word opens with (`"` or `'`).
        public var quote: Character?
        /// The closing quote is right after the caret (the editor pairs quotes).
        public var closingQuoteFollows: Bool
        /// The line's complete words before it, unquoted: the command's name first.
        public var words: [String]
    }

    /// The caret's word, or nil where nothing completes: a comment line, right after a closing
    /// quote, a word that isn't quoted the way `redis-cli` reads it, or a line before it that
    /// Runlet can't read.
    public static func context(in text: String, caret: Int) -> Context? {
        let string = text as NSString
        let caret = min(max(0, caret), string.length)
        let line = string.lineRange(for: NSRange(location: caret, length: 0))
        let before = string.substring(with: NSRange(location: line.location, length: caret - line.location)) as NSString
        let tokens = RedisScript.tokenize(before)
        if tokens.first?.kind == .comment { return nil }
        var words: [String] = []
        var anchor = caret
        var current: String?
        for (index, token) in tokens.enumerated() {
            let raw = before.substring(with: token.range)
            if index == tokens.count - 1, NSMaxRange(token.range) == before.length {
                current = raw
                anchor = line.location + token.range.location
                break
            }
            guard case .success(let parsed) = RedisScript.parse(raw), parsed.count == 1 else { return nil }
            words.append(String(decoding: parsed[0], as: UTF8.self))
        }
        var prefix = ""
        var quote: Character?
        if let current {
            if let first = current.first, first == "\"" || first == "'" {
                // A closed quote is a finished word; an open one is read as if closed here.
                if case .success = RedisScript.parse(current) { return nil }
                guard case .success(let parsed) = RedisScript.parse(current + String(first)), parsed.count == 1 else { return nil }
                prefix = String(decoding: parsed[0], as: UTF8.self)
                quote = first
            } else {
                guard !current.contains("\""), !current.contains("'") else { return nil }
                prefix = current
            }
        }
        let next = caret < string.length ? string.character(at: caret) : nil
        let closing = quote.map { next == $0.utf16.first } ?? false
        return Context(anchor: anchor, prefix: prefix, quote: quote, closingQuoteFollows: closing, words: words)
    }

    // MARK: What the grammar allows next

    /// An option word and the syntax of the option it starts.
    public struct Option: Sendable, Equatable, Hashable {
        public var token: String
        /// `EX seconds`, `NX | XX`, `LIMIT offset count`.
        public var syntax: String
    }

    /// What a command's grammar allows at the word after `words`.
    public struct Expectation: Sendable, Equatable {
        public var command: RedisCommandSpec
        /// A key name can go here.
        public var key: Bool
        /// The value argument that goes here (`seconds`, `section`), when it isn't a key.
        public var value: RedisArgument?
        /// The option words allowed here, in the syntax's order.
        public var options: [Option]
    }

    /// A word no command takes as a token or a number: where the builder's matcher puts it
    /// says what goes at that position.
    private static let probe = "\u{1}"

    /// What goes at the word after `words` (the command's name first), from the command's spec
    /// and the builder's matcher; nil for a command Runlet has no syntax for.
    public static func expectation(after words: [String]) -> Expectation? {
        guard let (spec, nameWords) = RedisCommandSpecs.spec(for: words), words.count >= nameWords else { return nil }
        let here = words.count
        func role(_ line: [String]) -> RedisArgumentRole? {
            let roles = RedisCommandForm.parseWithRoles(line).roles
            return here < roles.count ? roles[here] : nil
        }
        let alone = role(words + [probe])
        // A word followed by another: `BLPOP a |` can be another key before the timeout.
        let followed = role(words + [probe, probe])
        var value: RedisArgument?
        if case .value(let name) = alone { value = argument(named: name, in: spec.arguments) }
        // An option word is allowed when some way of finishing the line reads it as one: the
        // matcher reads `XADD s MAXLEN` as an id until the words after MAXLEN say otherwise.
        let options = options(of: spec).filter { option in
            (0...3).contains { role(words + [option.token] + Array(repeating: probe, count: $0)) == .token }
        }
        return Expectation(command: spec, key: alone == .key || followed == .key, value: value, options: options)
    }

    /// Every option word of a spec, with the syntax of the option it starts: its own (`EX
    /// seconds`), or for a bare word the top-level argument it belongs to (`NX | XX`).
    static func options(of spec: RedisCommandSpec) -> [Option] {
        var options: [Option] = []
        var seen = Set<String>()
        func walk(_ argument: RedisArgument, top: RedisArgument) {
            if let token = argument.token, seen.insert(token.uppercased()).inserted {
                let source = argument.kind == .pureToken ? top : argument
                options.append(Option(token: token, syntax: bare(source.syntax)))
            }
            for child in argument.children { walk(child, top: top) }
        }
        for argument in spec.arguments { walk(argument, top: argument) }
        return options
    }

    private static func argument(named name: String, in arguments: [RedisArgument]) -> RedisArgument? {
        var found: RedisArgument?
        func walk(_ list: [RedisArgument]) {
            for argument in list {
                if argument.name == name, argument.isValue, found == nil || (found?.suggestions.isEmpty == true && !argument.suggestions.isEmpty) {
                    found = argument
                }
                walk(argument.children)
            }
        }
        walk(arguments)
        return found
    }

    /// A syntax without the brackets around all of it: `[LIMIT offset count]` → `LIMIT offset count`.
    static func bare(_ syntax: String) -> String {
        for (open, close) in [("[", "]"), ("<", ">")] where syntax.hasPrefix(open) && syntax.hasSuffix(close) && syntax.count >= 2 {
            var depth = 0
            var wraps = true
            for (index, character) in syntax.enumerated() {
                if String(character) == open { depth += 1 }
                if String(character) == close { depth -= 1 }
                if depth == 0, index < syntax.count - 1 { wraps = false; break }
            }
            if wraps { return bare(String(syntax.dropFirst().dropLast())) }
        }
        return syntax
    }

    // MARK: The command table

    /// A command completion offers: Runlet's syntax for it, when it has one, and how every run
    /// classifies it.
    public struct Command: Sendable, Equatable {
        /// `GET`, or `CLIENT KILL` for a container's subcommand.
        public var name: String
        public var spec: RedisCommandSpec?
        public var info: RedisCommands.Info

        public var words: [String] { name.split(separator: " ").map(String.init) }

        /// The arguments' syntax as Redis's docs write it (empty without a spec, or without
        /// arguments): `key start stop [BYSCORE | BYLEX] [REV] [LIMIT offset count] [WITHSCORES]`.
        public var argumentSyntax: String { spec?.arguments.map(\.syntax).joined(separator: " ") ?? "" }

        /// WRITE, DANGEROUS, BLOCKS: what the builder's list shows.
        public var badges: [String] { RedisCompletion.badges(info) }
    }

    /// Every command and subcommand Runlet knows, but the ones it refuses (streaming): those
    /// `RedisCommandSpecs` has a syntax for (the builder's, #218), and the rest of `RedisCommands`'
    /// classification table (#190), by name. Containers (`CLIENT`) are listed by their
    /// subcommands (`CLIENT LIST`).
    public static let commands: [Command] = {
        var names = Set(RedisCommandSpecs.all.map(\.tableKey))
        names.formUnion(RedisCommands.reads)
        names.formUnion(RedisCommands.connection)
        names.formUnion(RedisCommands.transaction)
        names.formUnion(RedisCommands.writes)
        names.formUnion(RedisCommands.dangerous.keys)
        names.formUnion(RedisCommands.blocking)
        names.subtract(RedisCommands.streaming)
        // A container on its own (COMMAND) is offered as the container.
        names.subtract(RedisCommands.containers)
        return names.sorted().map { key in
            let words = key.split(separator: "|").map(String.init)
            return Command(name: words.joined(separator: " "), spec: RedisCommandSpecs.byKey[key], info: RedisCommands.classify(words))
        }
    }()

    /// A container's subcommands (`CLIENT` → `CLIENT GETNAME`, `CLIENT INFO`, …), by name.
    public static func subcommands(of container: String) -> [Command] {
        let container = container.uppercased()
        return commands.filter { $0.words.count == 2 && $0.words[0] == container }
    }

    /// WRITE (a write, or a command Runlet doesn't know), DANGEROUS, BLOCKS.
    public static func badges(_ info: RedisCommands.Info) -> [String] {
        var badges: [String] = []
        if info.dangerous { badges.append("DANGEROUS") }
        if info.access == .write || info.access == .unknown { badges.append("WRITE") }
        if info.blocking { badges.append("BLOCKS") }
        return badges
    }

    // MARK: Suggestions

    /// The completions at `caret` (a UTF-16 offset), or nil where nothing completes. `keys` are
    /// the keys Runlet already read for the tab's connection and database; `loadOffer` adds Load
    /// Keys for Completion to key positions.
    public static func suggestions(in text: String, caret: Int, keys: [KnownKey] = [], loadOffer: KeyLoadOffer? = nil) -> SQLCompletion.Result? {
        guard let context = context(in: text, caret: caret) else { return nil }
        let caret = min(max(0, caret), (text as NSString).length)
        let typed = (text as NSString).substring(with: NSRange(location: context.anchor, length: caret - context.anchor))
        let words = context.words
        var items: [SQLCompletion.Item] = []
        if words.isEmpty {
            guard context.quote == nil else { return nil }
            items = commandItems(lowercase: isLowercase(context.prefix, fallback: nil))
        } else if words.count == 1, RedisCommands.containers.contains(words[0].uppercased()) {
            guard context.quote == nil else { return nil }
            let lowercase = isLowercase(context.prefix, fallback: words[0])
            items = subcommands(of: words[0]).map { commandItem($0, label: $0.words[1], lowercase: lowercase) }
        } else {
            guard let expectation = expectation(after: words) else { return nil }
            if context.quote == nil {
                let lowercase = isLowercase(context.prefix, fallback: words[0])
                items += expectation.options.map { option in
                    var item = SQLCompletion.Item(label: lowercase ? option.token.lowercased() : option.token, kind: .option,
                                                  detail: option.syntax == option.token ? "option" : option.syntax, rank: 1)
                    item.documentation = "\(expectation.command.name) \(expectation.command.arguments.map(\.syntax).joined(separator: " "))"
                    return item
                }
                if let value = expectation.value {
                    items += value.suggestions.map { SQLCompletion.Item(label: $0, kind: .value, detail: value.name, rank: 0) }
                }
            }
            if expectation.key {
                items += keyItems(keys, context: context, type: expectation.command.group.keyType)
                if let loadOffer {
                    var item = SQLCompletion.Item(label: loadOffer.title, insertText: "", kind: .action, detail: loadOffer.detail, rank: 9)
                    item.action = loadKeysAction
                    item.documentation = "Typing never reads anything from Redis: this runs one SCAN, now."
                    items.append(item)
                }
            }
        }
        return items.isEmpty ? nil : SQLCompletion.Result(anchor: context.anchor, prefix: typed, items: items)
    }

    /// Lower case when the typed word is (`zr` → `zrange`), else when the line's command is.
    private static func isLowercase(_ prefix: String, fallback: String?) -> Bool {
        if prefix.lowercased() != prefix.uppercased() { return prefix == prefix.lowercased() }
        guard let fallback, fallback.lowercased() != fallback.uppercased() else { return false }
        return fallback == fallback.lowercased()
    }

    /// Commands Runlet has a syntax for first, then the others; containers insert their name
    /// and a space, and list their subcommands next.
    private static func commandItems(lowercase: Bool) -> [SQLCompletion.Item] {
        var items: [SQLCompletion.Item] = []
        for command in commands where command.words.count == 1 {
            items.append(commandItem(command, label: command.name, lowercase: lowercase))
        }
        for container in RedisCommands.containers.sorted() {
            let subcommands = subcommands(of: container)
            let label = lowercase ? container.lowercased() : container
            var item = SQLCompletion.Item(label: label, insertText: label + " ", kind: .command,
                                          detail: subcommands.prefix(5).map { $0.words[1] }.joined(separator: " | ") + (subcommands.count > 5 ? " | …" : ""),
                                          rank: subcommands.contains { $0.spec != nil } ? 0 : 1)
            item.documentation = "\(subcommands.count) subcommands: type one after it."
            item.reopens = true
            items.append(item)
        }
        return items
    }

    private static func commandItem(_ command: Command, label: String, lowercase: Bool) -> SQLCompletion.Item {
        let label = lowercase ? label.lowercased() : label
        let syntax = command.argumentSyntax
        var item = SQLCompletion.Item(label: label, kind: .command, detail: syntax.isEmpty ? nil : syntax, rank: command.spec == nil ? 1 : 0)
        item.documentation = summary(command)
        item.badges = command.badges
        return item
    }

    /// The command's summary, and why it's dangerous.
    static func summary(_ command: Command) -> String {
        var parts: [String] = []
        if let spec = command.spec { parts.append(spec.summary) }
        if let danger = command.info.danger { parts.append("Dangerous: it \(danger). Run always asks first.") }
        if command.spec == nil { parts.append(accessText(command.info.access) + "; Runlet has no syntax for its arguments.") }
        return parts.joined(separator: " ")
    }

    private static func accessText(_ access: RedisCommands.Access) -> String {
        switch access {
        case .read: "Reads only"
        case .connection: "Connection state"
        case .transaction: "Transaction control"
        case .write: "Can write: a read-only connection refuses it"
        case .streaming: "Streams replies: Redis tabs refuse it"
        case .unknown: "Unknown to Runlet, so it counts as a write"
        }
    }

    /// Key names, keys of the command's type first (the key browser's `TYPE`), each once.
    private static func keyItems(_ keys: [KnownKey], context: Context, type: String?) -> [SQLCompletion.Item] {
        let order = KnownKey.Source.allCases
        let sorted = keys.enumerated().sorted { (order.firstIndex(of: $0.element.source) ?? 0, $0.offset) < (order.firstIndex(of: $1.element.source) ?? 0, $1.offset) }
        var seen = Set<String>()
        var items: [SQLCompletion.Item] = []
        for (_, key) in sorted where seen.insert(key.name).inserted {
            guard let (insert, filter) = insertion(of: key.name, context: context) else { continue }
            let rank = type == nil || key.type == nil ? 1 : key.type == type ? 0 : 2
            var item = SQLCompletion.Item(label: label(key.name), insertText: insert, kind: .key,
                                          detail: [key.type, key.source.label].compactMap { $0 }.joined(separator: " · "), rank: rank)
            item.filterText = filter
            items.append(item)
        }
        return items
    }

    /// A key as the list shows it: control characters as escapes.
    private static func label(_ name: String) -> String {
        name.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } ? RedisScript.quoted(name) : name
    }

    /// What replaces the typed word for key `name`, and what the typed word is matched against:
    /// quoted the way `redis-cli` reads it (`"two words"`); inside a quote the word was opened
    /// with, escaped for that quote, closed unless the closing quote already follows.
    static func insertion(of name: String, context: Context) -> (insert: String, filter: String)? {
        switch context.quote {
        case nil:
            return (RedisScript.quoted(name), name)
        case "'":
            // Single quotes only escape `\'`: a name with a backslash or a control character
            // needs double quotes.
            guard !name.contains("\\"), !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
            let body = "'" + name.replacingOccurrences(of: "'", with: "\\'")
            return (body + (context.closingQuoteFollows ? "" : "'"), body)
        default:
            let quoted = RedisScript.quoted(name)
            let inner = quoted.hasPrefix("\"") ? String(quoted.dropFirst().dropLast()) : quoted
            let body = "\"" + inner
            return (body + (context.closingQuoteFollows ? "" : "\""), body)
        }
    }

    // MARK: Hover

    /// What hovering the command (or subcommand) at `index` shows: its syntax, summary, group,
    /// and how Runlet treats it, as Markdown; nil elsewhere.
    public static func hover(in text: String, at index: Int) -> String? {
        let string = text as NSString
        guard index >= 0, index < string.length else { return nil }
        let line = string.lineRange(for: NSRange(location: index, length: 0))
        let lineText = string.substring(with: line) as NSString
        let tokens = RedisScript.tokenize(lineText)
        let offset = index - line.location
        guard let position = tokens.firstIndex(where: { NSLocationInRange(offset, $0.range) }), position <= 1,
              tokens[position].kind == .command else { return nil }
        let words = tokens.prefix(2).map { lineText.substring(with: $0.range).uppercased() }
        let first = words[0]
        if RedisCommands.containers.contains(first) {
            if words.count > 1, tokens[1].kind == .command, let command = commands.first(where: { $0.name == first + " " + words[1] }) {
                return describe(command)
            }
            let names = subcommands(of: first).map { $0.words[1] }
            if position == 0, !names.isEmpty {
                return "```\n\(first) <subcommand>\n```\nSubcommands: \(names.joined(separator: ", "))."
            }
        }
        guard position == 0, let command = commands.first(where: { $0.name == first }) else { return nil }
        return describe(command)
    }

    /// `ZRANGE key start stop …` in a code block, the summary, then the group and class.
    static func describe(_ command: Command) -> String {
        let syntax = command.argumentSyntax
        var lines = ["```", syntax.isEmpty ? command.name : command.name + " " + syntax, "```", summary(command)]
        var facts: [String] = []
        if let group = command.spec?.group { facts.append(group.title) }
        if command.spec != nil { facts.append(accessText(command.info.access)) }
        if command.info.blocking { facts.append("waits on the server; Stop ends it") }
        if !facts.isEmpty { lines.append(facts.joined(separator: " · ")) }
        return lines.joined(separator: "\n")
    }
}
