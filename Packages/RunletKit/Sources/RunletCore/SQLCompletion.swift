import Foundation

/// Completion in SQL tabs (#128): keywords and common functions always; table and column
/// names from a schema the user loaded (or that a run read), per target and connection. It
/// reads the statement at the caret with the shared lexer (`SQLScript`), so strings, comments,
/// and quoted identifiers are never completed into.
public enum SQLCompletion {
    public enum Kind: Sendable, Equatable {
        case keyword, function, table, column
    }

    public struct Item: Sendable, Equatable {
        /// What the list shows and filters on.
        public var label: String
        /// What replaces the typed word: the label, quoted when the name needs it, or a
        /// function call with its parentheses.
        public var insertText: String
        /// The caret's offset in `insertText` after inserting (inside a call's parentheses);
        /// nil puts it at the end.
        public var cursor: Int?
        public var kind: Kind
        /// "users · varchar", "table · 4 columns", "keyword".
        public var detail: String?
        /// Lower ranks list first: the columns of the statement's tables, then keywords, then tables.
        public var rank: Int

        public init(label: String, insertText: String? = nil, cursor: Int? = nil, kind: Kind, detail: String? = nil, rank: Int) {
            self.label = label
            self.insertText = insertText ?? label
            self.cursor = cursor
            self.kind = kind
            self.detail = detail
            self.rank = rank
        }
    }

    public struct Result: Sendable, Equatable {
        /// UTF-16 offset where the word being completed starts.
        public var anchor: Int
        /// The typed part of the word (from `anchor` to the caret).
        public var prefix: String
        public var items: [Item]
    }

    /// Functions most databases share, inserted as `NAME()` with the caret inside.
    public static let functions: [String] = [
        "ABS", "AVG", "CEIL", "COALESCE", "CONCAT", "COUNT", "DATE", "EXTRACT", "FLOOR", "GROUP_CONCAT", "IFNULL",
        "JSON_EXTRACT", "LAG", "LEAD", "LENGTH", "LOWER", "MAX", "MIN", "NOW", "NULLIF", "RANK", "ROUND", "ROW_NUMBER",
        "STRING_AGG", "SUBSTR", "SUBSTRING", "SUM", "TRIM", "UPPER",
    ]

    /// Phrases offered as one item, so `or` finds `ORDER BY`.
    public static let phrases: [String] = [
        "DELETE FROM", "GROUP BY", "INNER JOIN", "INSERT INTO", "IS NOT NULL", "IS NULL", "LEFT JOIN", "ORDER BY",
        "PRIMARY KEY", "UNION ALL",
    ]

    /// Keywords after which a table name comes.
    static let tableKeywords: Set<String> = ["FROM", "JOIN", "UPDATE", "INTO", "TABLE", "DESCRIBE"]

    /// The completions at `caret` (a UTF-16 offset) in `text`, or nil where nothing should be
    /// offered: inside a string, comment, or quoted identifier, in a number, after a
    /// placeholder's `:` or a variable's `@`, or after `x.` when `x` is no known table.
    public static func suggestions(in text: String, caret: Int, schema: SQLSchemaInfo?) -> Result? {
        let string = text as NSString
        let caret = min(max(0, caret), string.length)
        let tokens = SQLScript.tokenize(string)
        for token in tokens where [.string, .comment, .quotedIdentifier].contains(token.kind) {
            let start = token.range.location, end = NSMaxRange(token.range)
            if caret <= start { break }
            if caret < end || (caret == end && isOpen(token, in: string)) { return nil }
        }

        var anchor = caret
        while anchor > 0, isIdentifier(string.character(at: anchor - 1)) { anchor -= 1 }
        let prefix = string.substring(with: NSRange(location: anchor, length: caret - anchor))
        if let first = prefix.utf16.first, first >= 48 && first <= 57 { return nil }
        if anchor > 0, [58, 64, 36].contains(string.character(at: anchor - 1)) { return nil } // :name, @var, $1

        // The statement around the caret (between semicolons), without comments and the word
        // being typed.
        let semicolons = tokens.filter { $0.kind == .semicolon }
        let start = semicolons.last { NSMaxRange($0.range) <= caret }.map { NSMaxRange($0.range) } ?? 0
        let end = semicolons.first { $0.range.location >= caret }?.range.location ?? string.length
        let context = tokens.filter { token in
            let location = token.range.location, max = NSMaxRange(token.range)
            guard token.kind != .comment, token.kind != .semicolon, location >= start, max <= end else { return false }
            return !(location < caret && max > caret) && !(location == anchor && max == caret)
        }
        let words = context.map { string.substring(with: $0.range) }
        let references = tableReferences(context, words)
        // Keywords follow the typed word's case, else the statement's last keyword.
        let lowercase: Bool
        if prefix.lowercased() != prefix.uppercased() {
            lowercase = prefix == prefix.lowercased()
        } else if let keyword = context.lastIndex(where: { $0.kind == .keyword && $0.range.location < anchor }) {
            lowercase = words[keyword] == words[keyword].lowercased()
        } else {
            lowercase = false
        }
        let quote: Character = schema?.driver == "mysql" ? "`" : "\""
        let pgsql = schema?.driver == "pgsql"

        // `alias.` or `table.`: that table's columns; `schema.`: that schema's tables.
        if anchor > 0, string.character(at: anchor - 1) == 46 {
            guard let qualifierIndex = context.lastIndex(where: { NSMaxRange($0.range) == anchor - 1 }),
                  [.word, .keyword, .quotedIdentifier].contains(context[qualifierIndex].kind) else { return nil }
            let qualifier = unquoted(words[qualifierIndex])
            let tableName = references.first { $0.alias?.lowercased() == qualifier.lowercased() }?.table ?? qualifier
            if let table = schema?.table(named: tableName) {
                let items = table.columns.map { column in
                    Item(label: column.name, insertText: identifier(column.name, quote: quote, pgsql: pgsql), kind: .column,
                         detail: [table.name, column.type].compactMap { $0 }.joined(separator: " · "), rank: 0)
                }
                return Result(anchor: anchor, prefix: prefix, items: items)
            }
            let inSchema = (schema?.tables ?? []).compactMap { table -> Item? in
                guard table.name.lowercased().hasPrefix(qualifier.lowercased() + ".") else { return nil }
                let name = String(table.name.dropFirst(qualifier.count + 1))
                return Item(label: name, insertText: identifier(name, quote: quote, pgsql: pgsql), kind: .table, detail: tableDetail(table), rank: 0)
            }
            return inSchema.isEmpty ? nil : Result(anchor: anchor, prefix: prefix, items: inSchema)
        }

        var items: [Item] = []
        let wantsTable = expectsTable(context, words, before: anchor)
        let tables = schema?.tables ?? []
        if wantsTable {
            items += tables.map { Item(label: $0.name, insertText: qualifiedIdentifier($0.name, quote: quote, pgsql: pgsql), kind: .table, detail: tableDetail($0), rank: 0) }
        } else {
            let referenced = references.compactMap { schema?.table(named: $0.table) }
            var seen = Set<String>()
            for table in referenced {
                for column in table.columns where seen.insert(column.name.lowercased()).inserted {
                    items.append(Item(label: column.name, insertText: identifier(column.name, quote: quote, pgsql: pgsql), kind: .column,
                                      detail: [table.name, column.type].compactMap { $0 }.joined(separator: " · "), rank: 0))
                }
            }
            if referenced.isEmpty, (schema?.columnCount ?? 0) <= 5000 {
                // Before FROM: every column, once, so `SELECT em` finds `email`.
                for table in tables {
                    for column in table.columns where seen.insert(column.name.lowercased()).inserted {
                        items.append(Item(label: column.name, insertText: identifier(column.name, quote: quote, pgsql: pgsql), kind: .column,
                                          detail: [table.name, column.type].compactMap { $0 }.joined(separator: " · "), rank: 2))
                    }
                }
            }
            items += tables.map { Item(label: $0.name, insertText: qualifiedIdentifier($0.name, quote: quote, pgsql: pgsql), kind: .table, detail: tableDetail($0), rank: 2) }
        }
        let keywordRank = wantsTable ? 3 : 1
        func cased(_ word: String) -> String { lowercase ? word.lowercased() : word }
        items += phrases.map { Item(label: cased($0), kind: .keyword, detail: "keywords", rank: keywordRank) }
        items += SQLScript.keywords.sorted().map { Item(label: cased($0), kind: .keyword, detail: "keyword", rank: keywordRank) }
        items += functions.map { name in
            let call = cased(name) + "()"
            return Item(label: cased(name), insertText: call, cursor: (call as NSString).length - 1, kind: .function, detail: "function", rank: keywordRank)
        }
        return Result(anchor: anchor, prefix: prefix, items: items)
    }

    /// A name without its identifier quotes (`"users"`, `` `users` ``, `[users]`).
    public static func unquoted(_ name: String) -> String {
        guard name.count >= 2, let first = name.first, let last = name.last else { return name }
        if (first == "\"" && last == "\"") || (first == "`" && last == "`") {
            return String(name.dropFirst().dropLast()).replacingOccurrences(of: String(first) + String(first), with: String(first))
        }
        if first == "[" && last == "]" { return String(name.dropFirst().dropLast()) }
        return name
    }

    /// A name as SQL needs it: bare when it is a plain lower-case-safe word, else quoted.
    static func identifier(_ name: String, quote: Character, pgsql: Bool) -> String {
        let plain = name.unicodeScalars.first.map { CharacterSet.letters.contains($0) || $0 == "_" } == true
            && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }
        if plain, !SQLScript.keywords.contains(name.uppercased()), !(pgsql && name != name.lowercased()) { return name }
        return String(quote) + name.replacingOccurrences(of: String(quote), with: String(quote) + String(quote)) + String(quote)
    }

    /// `schema.table`, each part quoted on its own when needed.
    static func qualifiedIdentifier(_ name: String, quote: Character, pgsql: Bool) -> String {
        name.split(separator: ".", maxSplits: 1).map { identifier(String($0), quote: quote, pgsql: pgsql) }.joined(separator: ".")
    }

    private static func tableDetail(_ table: SQLSchemaInfo.Table) -> String {
        "table · \(table.columns.count) column\(table.columns.count == 1 ? "" : "s")"
    }

    private static func isIdentifier(_ c: unichar) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c >= 0x80
    }

    /// An unterminated string, quoted identifier, or block comment, or a line comment (which
    /// goes on to the end of its line): a caret at its end is still inside it.
    private static func isOpen(_ token: SQLScript.Token, in string: NSString) -> Bool {
        let text = string.substring(with: token.range)
        switch token.kind {
        case .comment:
            return !text.hasPrefix("/*") || !(text.count >= 4 && text.hasSuffix("*/"))
        case .string where text.hasPrefix("$"):
            return !(text.count >= 4 && text.hasSuffix("$"))
        case .string, .quotedIdentifier:
            guard text.count >= 2, let first = text.first else { return true }
            // An even run of closing quotes is escaped quotes, not the end.
            let closing = text.dropFirst().reversed().prefix { $0 == first }.count
            return closing % 2 == 0
        default:
            return false
        }
    }

    /// Tables the statement names after FROM (and its commas), JOIN, UPDATE, INTO, and TABLE,
    /// with their aliases (`users u`, `users AS u`).
    static func tableReferences(_ tokens: [SQLScript.Token], _ words: [String]) -> [(table: String, alias: String?)] {
        var references: [(table: String, alias: String?)] = []
        func isName(_ index: Int) -> Bool {
            index < tokens.count && (tokens[index].kind == .word || tokens[index].kind == .quotedIdentifier)
        }
        var index = 0
        while index < tokens.count {
            let keyword = tokens[index].kind == .keyword ? words[index].uppercased() : ""
            guard tableKeywords.contains(keyword) else { index += 1; continue }
            var next = index + 1
            while isName(next) {
                var table = unquoted(words[next])
                next += 1
                if next + 1 < tokens.count, words[next] == ".", isName(next + 1) {
                    table += "." + unquoted(words[next + 1])
                    next += 2
                }
                var alias: String?
                if next < tokens.count, tokens[next].kind == .keyword, words[next].uppercased() == "AS", isName(next + 1) {
                    alias = unquoted(words[next + 1])
                    next += 2
                } else if isName(next) {
                    alias = unquoted(words[next])
                    next += 1
                }
                references.append((table, alias))
                guard keyword == "FROM", next < tokens.count, words[next] == "," else { break }
                next += 1
            }
            index = max(next, index + 1)
        }
        return references
    }

    /// Whether a table name comes next: right after FROM, JOIN, UPDATE, INTO, TABLE, or
    /// DESCRIBE, or after a comma in a FROM list.
    static func expectsTable(_ tokens: [SQLScript.Token], _ words: [String], before anchor: Int) -> Bool {
        guard let last = tokens.lastIndex(where: { NSMaxRange($0.range) <= anchor }) else { return false }
        if tokens[last].kind == .keyword { return tableKeywords.contains(words[last].uppercased()) }
        guard words[last] == "," else { return false }
        // FROM a, b, |: the nearest keyword before the comma is FROM.
        let keyword = tokens[..<last].lastIndex { $0.kind == .keyword }
        return keyword.map { words[$0].uppercased() == "FROM" } ?? false
    }
}
