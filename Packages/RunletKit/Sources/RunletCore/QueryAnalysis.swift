import Foundation

/// SQL text helpers for the query inspector. Display only: nothing here builds SQL to run.
public enum SQLText {
    /// Inlines bindings for reading: `?` placeholders in order, and `:name` placeholders
    /// for named bindings. Placeholders inside quoted strings, quoted identifiers, and
    /// comments are left alone, and `??` stays a literal `?` (Laravel's escape for
    /// PostgreSQL's JSON operators).
    public static func interpolate(_ sql: String, bindings: [QueryRecord.Binding], driver: String? = nil) -> String {
        guard !bindings.isEmpty else { return sql }
        let positional = bindings.filter { $0.name == nil }
        let named = Dictionary(bindings.compactMap { binding in binding.name.map { ($0, binding) } }, uniquingKeysWith: { first, _ in first })
        let backslashEscapes = driver == "mysql" || driver == "mariadb"
        let characters = Array(sql)
        var output = ""
        output.reserveCapacity(sql.count + bindings.count * 8)
        var next = 0
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "'", "\"", "`":
                let end = quotedEnd(characters, from: index, quote: character, backslashEscapes: backslashEscapes && character != "`")
                output.append(contentsOf: characters[index..<end])
                index = end
                continue
            case "-" where index + 1 < characters.count && characters[index + 1] == "-":
                let end = characters[index...].firstIndex(of: "\n") ?? characters.count
                output.append(contentsOf: characters[index..<end])
                index = end
                continue
            case "/" where index + 1 < characters.count && characters[index + 1] == "*":
                var end = index + 2
                while end + 1 < characters.count, !(characters[end] == "*" && characters[end + 1] == "/") { end += 1 }
                end = min(characters.count, end + 2)
                output.append(contentsOf: characters[index..<end])
                index = end
                continue
            case "?":
                if index + 1 < characters.count, characters[index + 1] == "?" {
                    output.append("?")
                    index += 2
                    continue
                }
                if next < positional.count {
                    output.append(positional[next].sqlLiteral(driver: driver))
                    next += 1
                } else {
                    output.append("?")
                }
                index += 1
                continue
            case ":" where !named.isEmpty:
                // `::` is a PostgreSQL cast, never a parameter.
                if index + 1 < characters.count, characters[index + 1] == ":" {
                    output.append("::")
                    index += 2
                    continue
                }
                var end = index + 1
                while end < characters.count, characters[end].isLetter || characters[end].isNumber || characters[end] == "_" { end += 1 }
                let name = String(characters[(index + 1)..<end])
                if let binding = named[name] {
                    output.append(binding.sqlLiteral(driver: driver))
                    index = end
                    continue
                }
            default:
                break
            }
            output.append(character)
            index += 1
        }
        return output
    }

    /// The end (exclusive) of a quoted string or identifier that starts at `start`.
    private static func quotedEnd(_ characters: [Character], from start: Int, quote: Character, backslashEscapes: Bool) -> Int {
        var index = start + 1
        while index < characters.count {
            let character = characters[index]
            if backslashEscapes, character == "\\" {
                index += 2
                continue
            }
            if character == quote {
                // A doubled quote is an escaped quote.
                if index + 1 < characters.count, characters[index + 1] == quote {
                    index += 2
                    continue
                }
                return index + 1
            }
            index += 1
        }
        return characters.count
    }

    /// The statement's shape: literals become `?`, `IN (…)` lists one `?`, whitespace is
    /// collapsed, and keywords are lowercased. Statements with the same shape are "similar".
    public static func fingerprint(_ sql: String) -> String {
        var text = sql
        let replacements: [(String, String)] = [
            (#"'(?:[^'\\]|\\.|'')*'"#, "?"),
            (#"\b-?\d+(?:\.\d+)?\b"#, "?"),
            (#"\(\s*\?(?:\s*,\s*\?)*\s*\)"#, "(?)"),
            (#"\s+"#, " "),
        ]
        for (pattern, replacement) in replacements {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Whether the statement reads rows (SELECT, or a WITH … SELECT).
    public static func isSelect(_ sql: String) -> Bool {
        let head = sql.drop { $0.isWhitespace || $0 == "(" }.prefix(6).lowercased()
        return head.hasPrefix("select") || head.hasPrefix("with")
    }
}

/// One recorded statement with the keys the analysis groups by, computed once.
public struct QueryEntry: Sendable, Equatable {
    public var index: Int
    public var query: QueryRecord
    /// `SQLText.fingerprint(query.sql)`: similar statements share it.
    public var fingerprint: String
    /// `query.interpolatedSQL`: identical statements (SQL and bindings) share it.
    public var statement: String

    public init(index: Int, query: QueryRecord) {
        self.index = index
        self.query = query
        fingerprint = SQLText.fingerprint(query.sql)
        statement = query.interpolatedSQL
    }
}

/// Totals, groups of similar statements, and hints for one run's queries.
public struct QueryAnalysis: Sendable, Equatable {
    /// Similar statements run at least this many times (with different bindings) suggest an N+1.
    public static let nPlusOneThreshold = 3

    public enum Hint: Sendable, Equatable, Hashable {
        /// The same statement with the same bindings ran `count` times.
        case duplicate(count: Int)
        /// A similar SELECT ran `count` times with different bindings: likely one query per
        /// row of an earlier result (N+1). Eager loading fetches them together.
        case nPlusOne(count: Int)
    }

    public struct Group: Sendable, Equatable, Identifiable {
        public var fingerprint: String
        /// Record indexes of the statements in this group, in run order.
        public var indices: [Int]
        public var totalMs: Double
        /// How many different binding sets (exact statements) ran.
        public var distinctStatements: Int
        /// The largest number of times one exact statement ran.
        public var maxRepeats: Int
        public var hints: [Hint]

        public var id: String { fingerprint }
        public var count: Int { indices.count }
    }

    public var count: Int
    public var totalMs: Double
    /// Index of the slowest timed statement.
    public var slowestIndex: Int?
    /// Groups of similar statements, in order of their first execution.
    public var groups: [Group]
    private var groupByIndex: [Int: Int]

    public init(_ queries: [(index: Int, query: QueryRecord)]) {
        self.init(entries: queries.map { QueryEntry(index: $0.index, query: $0.query) })
    }

    public init(entries queries: [QueryEntry]) {
        count = queries.count
        totalMs = queries.compactMap(\.query.timeMs).reduce(0, +)
        slowestIndex = queries.filter { $0.query.timeMs != nil }.max { ($0.query.timeMs ?? 0) < ($1.query.timeMs ?? 0) }?.index
        var order: [String] = []
        var members: [String: [QueryEntry]] = [:]
        for entry in queries {
            if members[entry.fingerprint] == nil { order.append(entry.fingerprint) }
            members[entry.fingerprint, default: []].append(entry)
        }
        var groups: [Group] = []
        var groupByIndex: [Int: Int] = [:]
        for key in order {
            let entries = members[key] ?? []
            var repeats: [String: Int] = [:]
            for entry in entries { repeats[entry.statement, default: 0] += 1 }
            let maxRepeats = repeats.values.max() ?? 1
            var hints: [Hint] = []
            if maxRepeats > 1 { hints.append(.duplicate(count: maxRepeats)) }
            if entries.count >= Self.nPlusOneThreshold, repeats.count > 1, let first = entries.first, SQLText.isSelect(first.query.sql) {
                hints.append(.nPlusOne(count: entries.count))
            }
            for entry in entries { groupByIndex[entry.index] = groups.count }
            groups.append(Group(fingerprint: key, indices: entries.map(\.index), totalMs: entries.compactMap(\.query.timeMs).reduce(0, +), distinctStatements: repeats.count, maxRepeats: maxRepeats, hints: hints))
        }
        self.groups = groups
        self.groupByIndex = groupByIndex
    }

    /// The group of similar statements a record belongs to.
    public func group(of index: Int) -> Group? {
        groupByIndex[index].map { groups[$0] }
    }

    /// Groups with a duplicate or N+1 hint.
    public var flaggedGroups: [Group] { groups.filter { !$0.hints.isEmpty } }

    /// How many times the exact statement of `record` (SQL and bindings) ran in this run.
    public static func identicalCount(of record: QueryRecord, in queries: [(index: Int, query: QueryRecord)]) -> Int {
        let key = record.interpolatedSQL
        return queries.filter { $0.query.interpolatedSQL == key }.count
    }
}

extension QueryAnalysis.Hint {
    /// Short label for a badge.
    public var label: String {
        switch self {
        case .duplicate(let count): "\(count)× identical"
        case .nPlusOne(let count): "N+1? \(count)×"
        }
    }

    /// Explanation for a tooltip or the summary.
    public var explanation: String {
        switch self {
        case .duplicate(let count):
            "The same statement with the same bindings ran \(count) times. Cache the result or run it once."
        case .nPlusOne(let count):
            "A similar SELECT ran \(count) times with different bindings, which usually means one query per row of an earlier result (N+1). Eager loading (with() in Eloquent) fetches them in one query."
        }
    }
}
