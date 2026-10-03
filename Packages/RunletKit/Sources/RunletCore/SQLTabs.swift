import Foundation

/// A tab's language (#35): PHP (the default) or SQL. Sessions, workspaces, and history saved
/// before SQL tabs existed, and values a newer Runlet may add, decode as PHP.
public enum TabLanguage: String, Sendable, Codable, Hashable, CaseIterable {
    case php, sql

    public init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw.flatMap(TabLanguage.init(rawValue:)) ?? .php
    }

    public var displayName: String { self == .php ? "PHP" : "SQL" }

    /// `.sql` files open as SQL tabs; every other file as PHP.
    public static func forFile(_ url: URL) -> TabLanguage {
        url.pathExtension.lowercased() == "sql" ? .sql : .php
    }
}

// MARK: - SQL scripts

/// SQL tabs (#35): a small, dialect-tolerant SQL lexer, shared by the highlighter, statement
/// splitting, and write detection. It works on UTF-16 units so ranges map onto the editor.
/// It is best-effort: correctness of execution never depends on it alone (the runner also
/// asks the database to prepare a single statement).
public enum SQLScript {
    public enum TokenKind: Sendable, Equatable {
        /// A reserved word (`SELECT`, `FROM`, …).
        case keyword
        /// Any other bare word: a table, column, or function name.
        case word
        /// `"name"` or `` `name` ``.
        case quotedIdentifier
        /// `'text'` or a PostgreSQL dollar-quoted body.
        case string
        case number
        /// `-- …`, `# …`, `/* … */`.
        case comment
        /// `?`, `:name`, `$1`.
        case placeholder
        case semicolon
        case punctuation
    }

    public struct Token: Sendable, Equatable {
        public var range: NSRange
        public var kind: TokenKind
    }

    /// Reserved words coloured as keywords (upper case).
    public static let keywords: Set<String> = [
        "ADD", "ALL", "ALTER", "ANALYZE", "AND", "ANY", "AS", "ASC", "BEGIN", "BETWEEN", "BY", "CASCADE", "CASE", "CAST",
        "CHECK", "COLLATE", "COLUMN", "COMMIT", "CONFLICT", "CONSTRAINT", "CREATE", "CROSS", "CURRENT_DATE",
        "CURRENT_TIME", "CURRENT_TIMESTAMP", "DATABASE", "DEFAULT", "DELETE", "DESC", "DESCRIBE", "DISTINCT", "DO",
        "DROP", "DUPLICATE", "ELSE", "END", "ESCAPE", "EXCEPT", "EXISTS", "EXPLAIN", "FALSE", "FETCH", "FOR", "FOREIGN",
        "FROM", "FULL", "GRANT", "GROUP", "HAVING", "IF", "IGNORE", "ILIKE", "IN", "INDEX", "INNER", "INSERT", "INTERSECT",
        "INTERVAL", "INTO", "IS", "JOIN", "KEY", "LATERAL", "LEFT", "LIKE", "LIMIT", "LOCK", "MERGE", "NATURAL", "NOT",
        "NULL", "NULLS", "OFFSET", "ON", "OR", "ORDER", "OUTER", "OVER", "PARTITION", "PRAGMA", "PRIMARY", "QUERY",
        "RECURSIVE", "REFERENCES", "RENAME", "REPLACE", "RETURNING", "REVOKE", "RIGHT", "ROLLBACK", "ROW", "ROWS",
        "SCHEMA", "SELECT", "SET", "SHOW", "TABLE", "TABLES", "TEMPORARY", "THEN", "TO", "TRUE", "TRUNCATE", "UNION",
        "UNIQUE", "UNLOCK", "UPDATE", "USE", "USING", "VALUES", "VIEW", "WHEN", "WHERE", "WINDOW", "WITH",
    ]

    /// Literal constants coloured like PHP's `true`/`null`.
    public static let constants: Set<String> = ["NULL", "TRUE", "FALSE"]

    public static func tokenize(_ text: String) -> [Token] {
        tokenize(text as NSString)
    }

    /// - Parameters:
    ///   - backslashEscapes: `\'` doesn't end a string (MySQL's default); the editor's lexer
    ///     doesn't treat it so, and the read-only check (#139) tries both.
    ///   - hashComments: `#` starts a comment (MySQL); PostgreSQL reads it as an operator.
    public static func tokenize(_ string: NSString, backslashEscapes: Bool = false, hashComments: Bool = true) -> [Token] {
        let length = string.length
        var buffer = [unichar](repeating: 0, count: length)
        string.getCharacters(&buffer, range: NSRange(location: 0, length: length))
        var tokens: [Token] = []

        func isIdentStart(_ c: unichar) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c >= 0x80 }
        func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }
        func isIdent(_ c: unichar) -> Bool { isIdentStart(c) || isDigit(c) || c == 36 /* $ */ }
        func isSpace(_ c: unichar) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 12 }
        func add(_ start: Int, _ end: Int, _ kind: TokenKind) {
            tokens.append(Token(range: NSRange(location: start, length: end - start), kind: kind))
        }
        /// The end of a quoted run starting at `start` (the opening quote), where a doubled
        /// quote is an escaped one; the text's end when it is unterminated.
        func quoted(_ start: Int, _ quote: unichar) -> Int {
            var i = start + 1
            while i < length {
                if backslashEscapes, quote == 39, buffer[i] == 92 { i += 2; continue }
                if buffer[i] == quote {
                    if i + 1 < length, buffer[i + 1] == quote { i += 2; continue }
                    return i + 1
                }
                i += 1
            }
            return length
        }

        var i = 0
        while i < length {
            let c = buffer[i]
            if isSpace(c) { i += 1; continue }
            let start = i
            // Comments: -- to the end of the line; # (MySQL) except PostgreSQL's #> and #- operators.
            if (c == 45 && i + 1 < length && buffer[i + 1] == 45) || (hashComments && c == 35 && !(i + 1 < length && (buffer[i + 1] == 62 || buffer[i + 1] == 45))) {
                while i < length && buffer[i] != 10 { i += 1 }
                add(start, i, .comment)
                continue
            }
            if c == 47, i + 1 < length, buffer[i + 1] == 42 {
                i += 2
                while i < length && !(buffer[i] == 42 && i + 1 < length && buffer[i + 1] == 47) { i += 1 }
                i = min(length, i + 2)
                add(start, i, .comment)
                continue
            }
            switch c {
            case 39: // 'string'
                i = quoted(start, 39)
                add(start, i, .string)
            case 34, 96: // "identifier", `identifier`
                i = quoted(start, c)
                add(start, i, .quotedIdentifier)
            case 59:
                i += 1
                add(start, i, .semicolon)
            case 63: // ?
                i += 1
                add(start, i, .placeholder)
            case 36: // $1, $$body$$, $tag$body$tag$
                var j = i + 1
                if j < length, isDigit(buffer[j]) {
                    while j < length && isDigit(buffer[j]) { j += 1 }
                    i = j
                    add(start, i, .placeholder)
                    break
                }
                while j < length && (isIdentStart(buffer[j]) || isDigit(buffer[j])) { j += 1 }
                if j < length, buffer[j] == 36, j == i + 1 || isIdentStart(buffer[i + 1]) {
                    let tag = Array(buffer[i...j])
                    var k = j + 1
                    var end = length
                    while k + tag.count <= length {
                        if buffer[k] == 36, Array(buffer[k..<(k + tag.count)]) == tag { end = k + tag.count; break }
                        k += 1
                    }
                    i = end
                    add(start, i, .string)
                } else {
                    i += 1
                    add(start, i, .punctuation)
                }
            case 58: // :name placeholders; :: casts and := are punctuation.
                if i + 1 < length, isIdentStart(buffer[i + 1]), !(i > 0 && buffer[i - 1] == 58) {
                    i += 1
                    while i < length && isIdent(buffer[i]) { i += 1 }
                    add(start, i, .placeholder)
                } else {
                    i += 1
                    add(start, i, .punctuation)
                }
            default:
                if isDigit(c) || (c == 46 && i + 1 < length && isDigit(buffer[i + 1])) {
                    i += 1
                    while i < length && (isDigit(buffer[i]) || buffer[i] == 46 || isIdentStart(buffer[i])) {
                        // 1e-5 / 1E+5
                        if (buffer[i] == 101 || buffer[i] == 69), i + 1 < length, buffer[i + 1] == 43 || buffer[i + 1] == 45 { i += 1 }
                        i += 1
                    }
                    add(start, i, .number)
                } else if isIdentStart(c) || c == 64 /* @var */ {
                    i += 1
                    while i < length && (isIdent(buffer[i]) || buffer[i] == 64) { i += 1 }
                    let word = string.substring(with: NSRange(location: start, length: i - start)).uppercased()
                    add(start, i, keywords.contains(word) ? .keyword : .word)
                } else {
                    i += 1
                    add(start, i, .punctuation)
                }
            }
        }
        return tokens
    }

    // MARK: Statements

    /// One statement of an SQL text: its text (without the closing `;`), its UTF-16 range in
    /// the text it came from, and its first line (1-based).
    public struct Statement: Sendable, Equatable {
        public var text: String
        public var range: NSRange
        public var startLine: Int

        public init(text: String, range: NSRange, startLine: Int) {
            self.text = text
            self.range = range
            self.startLine = startLine
        }
    }

    /// The statements in `text`, split at semicolons outside strings, quoted identifiers,
    /// comments, and dollar-quoted bodies. Parts holding only comments are left out. A
    /// statement starts at its first token (a leading comment included), except a comment on
    /// the line where the previous statement ended, which belongs to that line.
    public static func statements(in text: String) -> [Statement] {
        let string = text as NSString
        var statements: [Statement] = []
        var first: Int?
        var last = 0
        var hasCode = false
        var previousEnd: Int?
        func close() {
            if let start = first, hasCode {
                let range = NSRange(location: start, length: last - start)
                statements.append(Statement(text: string.substring(with: range), range: range, startLine: line(of: start, in: string)))
            }
            first = nil
            hasCode = false
        }
        for token in tokenize(string) {
            if token.kind == .semicolon {
                close()
                previousEnd = NSMaxRange(token.range)
                continue
            }
            if first == nil, token.kind == .comment, let end = previousEnd,
               string.rangeOfCharacter(from: .newlines, options: [], range: NSRange(location: end, length: token.range.location - end)).location == NSNotFound {
                // `select 1; -- note`: the note stays with `select 1`'s line.
                previousEnd = NSMaxRange(token.range)
                continue
            }
            if first == nil { first = token.range.location }
            last = NSMaxRange(token.range)
            if token.kind != .comment { hasCode = true }
        }
        close()
        return statements
    }

    private static func line(of location: Int, in string: NSString) -> Int {
        var line = 1
        var index = 0
        while index < location {
            let range = string.rangeOfCharacter(from: .newlines, options: [], range: NSRange(location: index, length: location - index))
            if range.location == NSNotFound { break }
            // \r\n counts once.
            if string.character(at: range.location) == 13, range.location + 1 < string.length, string.character(at: range.location + 1) == 10 {
                index = range.location + 2
            } else {
                index = range.location + 1
            }
            if index <= location { line += 1 }
        }
        return line
    }

    /// Why an SQL tab has nothing (or too much) to run.
    public enum ScopeError: Error, Sendable, Equatable, CustomStringConvertible {
        case empty
        case nothingSelected
        case multipleStatements(count: Int)

        public var title: String {
            switch self {
            case .empty: "No SQL to run"
            case .nothingSelected: "Nothing selected"
            case .multipleStatements: "Run one statement at a time"
            }
        }

        public var description: String {
            switch self {
            case .empty:
                "This tab has no SQL statement to run (only blank lines or comments)."
            case .nothingSelected:
                "Select the statement to run, or press Run to run the statement at the caret."
            case .multipleStatements(let count):
                "The selection holds \(count) SQL statements. Runlet runs one statement per run, so a script never runs halfway: select a single statement, or put the caret in one and press Run without a selection."
            }
        }
    }

    /// What Run sends from an SQL tab (#35). With a selection, the selected text, which must
    /// hold exactly one statement. Without one, the statement at the caret: the statement the
    /// caret is in, else the one that ended earlier on the caret's line, else the next one,
    /// else the last one. A text with a single statement always runs that statement.
    /// Run Selection (`selectionOnly`) needs a selection.
    public static func statementToRun(in text: String, selection: NSRange, selectionOnly: Bool = false) -> Result<Statement, ScopeError> {
        let string = text as NSString
        // Clamped by hand: NSIntersectionRange turns a caret at the very end into {0, 0}.
        let location = min(max(0, selection.location), string.length)
        let selection = NSRange(location: location, length: min(max(0, selection.length), string.length - location))
        if selection.length > 0 {
            let selected = string.substring(with: selection)
            let found = statements(in: selected)
            guard found.count <= 1 else { return .failure(.multipleStatements(count: found.count)) }
            guard var statement = found.first else { return .failure(.empty) }
            statement.range.location += selection.location
            statement.startLine = line(of: statement.range.location, in: string)
            return .success(statement)
        }
        if selectionOnly { return .failure(.nothingSelected) }
        let all = statements(in: text)
        guard !all.isEmpty else { return .failure(.empty) }
        if all.count == 1 { return .success(all[0]) }
        let caret = selection.location
        if let inside = all.first(where: { caret >= $0.range.location && caret <= NSMaxRange($0.range) }) {
            return .success(inside)
        }
        let caretLine = line(of: caret, in: string)
        if let before = all.last(where: { NSMaxRange($0.range) <= caret }), line(of: NSMaxRange(before.range), in: string) == caretLine {
            return .success(before)
        }
        return .success(all.first(where: { $0.range.location >= caret }) ?? all[all.count - 1])
    }

    /// Run All Statements (#129): the statements of the selection, or of the whole text
    /// without one, with ranges and lines in `text`.
    public static func statementsToRunAll(in text: String, selection: NSRange) -> Result<[Statement], ScopeError> {
        let string = text as NSString
        let location = min(max(0, selection.location), string.length)
        let selection = NSRange(location: location, length: min(max(0, selection.length), string.length - location))
        guard selection.length > 0 else {
            let all = statements(in: text)
            return all.isEmpty ? .failure(.empty) : .success(all)
        }
        let found = statements(in: string.substring(with: selection)).map { statement -> Statement in
            var statement = statement
            statement.range.location += selection.location
            statement.startLine = line(of: statement.range.location, in: string)
            return statement
        }
        return found.isEmpty ? .failure(.empty) : .success(found)
    }

    /// Statements that start, end, or mark a transaction. Run All in a transaction (#129)
    /// refuses scripts with them: the script would fight Runlet's own transaction.
    static let transactionKeywords: Set<String> = ["BEGIN", "START", "COMMIT", "ROLLBACK", "END", "SAVEPOINT", "RELEASE", "ABORT"]

    /// The keyword when `statement` controls a transaction itself (`BEGIN`, `COMMIT`, …).
    public static func transactionControl(of statement: String) -> String? {
        transactionControl(words: firstWords(of: statement, count: 2))
    }

    static func transactionControl(words: [String]) -> String? {
        guard let first = words.first else { return nil }
        switch first {
        case "START": return words.count > 1 && words[1] == "TRANSACTION" ? "START TRANSACTION" : nil
        case "END": return words.count == 1 || ["TRANSACTION", "WORK"].contains(words[1]) ? "END" : nil
        default: return transactionKeywords.contains(first) ? first : nil
        }
    }

    /// Statements MySQL and MariaDB (and Oracle) commit at once, with everything before them,
    /// even inside a transaction: DDL, account and lock statements, table maintenance.
    /// `CREATE`/`DROP TEMPORARY TABLE` don't.
    public static func commitsImplicitly(_ statement: String) -> Bool {
        let words = firstWords(of: statement, count: 2)
        guard let first = words.first else { return false }
        if ["CREATE", "DROP"].contains(first), words.count > 1, words[1] == "TEMPORARY" { return false }
        return ["CREATE", "ALTER", "DROP", "RENAME", "TRUNCATE", "GRANT", "REVOKE", "LOCK", "UNLOCK", "ANALYZE", "OPTIMIZE", "REPAIR", "LOAD", "FLUSH", "INSTALL", "UNINSTALL"].contains(first)
    }

    /// The first `count` words of a statement (keywords and names, upper-cased), skipping comments.
    static func firstWords(of statement: String, count: Int) -> [String] {
        let string = statement as NSString
        return firstWords(tokens: tokenize(string), in: string, count: count)
    }

    static func firstWords(tokens: [Token], in string: NSString, count: Int) -> [String] {
        tokens.lazy
            .filter { $0.kind == .keyword || $0.kind == .word || $0.kind == .semicolon }
            .prefix { $0.kind != .semicolon }
            .prefix(count)
            .map { string.substring(with: $0.range).uppercased() }
    }

    // MARK: Writes

    /// Whether a statement can change data (#35). Best-effort and conservative: a statement is
    /// read-only only when it starts with a reading keyword and contains no keyword that
    /// writes. Functions with side effects (`nextval()`, stored procedures called from a
    /// SELECT, …) are not detected.
    public enum Effect: Sendable, Equatable {
        case read
        /// The keyword (or phrase) that can change data or the schema.
        case write(String)
        /// The statement starts with a keyword Runlet does not classify.
        case unknown(String)

        public var isRead: Bool { self == .read }

        /// The production confirmation's warning; nil for reads.
        public var warning: String? {
            switch self {
            case .read: nil
            case .write(let keyword): "This statement can change data or the schema (\(keyword))."
            case .unknown(let keyword): keyword.isEmpty
                ? "Runlet can't tell whether this statement changes data."
                : "Runlet can't tell whether this statement changes data (it starts with \(keyword))."
            }
        }
    }

    static let readingKeywords: Set<String> = ["SELECT", "SHOW", "DESCRIBE", "DESC", "EXPLAIN", "VALUES", "TABLE", "WITH", "PRAGMA"]
    static let writingKeywords: Set<String> = [
        "INSERT", "UPDATE", "DELETE", "REPLACE", "MERGE", "UPSERT", "CREATE", "ALTER", "DROP", "TRUNCATE", "RENAME",
        "GRANT", "REVOKE", "COMMENT", "LOCK", "UNLOCK", "CALL", "EXEC", "EXECUTE", "DO", "COPY", "LOAD", "IMPORT",
        "VACUUM", "REINDEX", "CLUSTER", "REFRESH", "ATTACH", "DETACH", "OPTIMIZE", "REPAIR", "ANALYZE", "FLUSH",
        "PURGE", "KILL", "HANDLER", "SET", "RESET", "SECURITY", "INSTALL", "UNINSTALL", "SHUTDOWN",
    ]
    /// SQLite pragmas whose argument names what to read about (`PRAGMA table_info(users)`);
    /// with any other pragma an argument in parentheses sets it.
    static let argumentReadingPragmas: Set<String> = [
        "TABLE_INFO", "TABLE_XINFO", "TABLE_LIST", "INDEX_INFO", "INDEX_XINFO", "INDEX_LIST", "FOREIGN_KEY_LIST",
        "FOREIGN_KEY_CHECK", "INTEGRITY_CHECK", "QUICK_CHECK",
    ]
    /// Inside a reading statement: keywords that make it write (a writable CTE, `SELECT … INTO`).
    static let embeddedWrites: Set<String> = ["INSERT", "UPDATE", "DELETE", "MERGE", "INTO", "CREATE", "DROP", "ALTER", "TRUNCATE"]

    public static func effect(of statement: String) -> Effect {
        let string = statement as NSString
        return effect(tokens: tokenize(string), in: string)
    }

    /// `effect(of:)` on tokens of `string` (the read-only check tokenizes in several ways).
    static func effect(tokens: [Token], in string: NSString) -> Effect {
        let tokens = tokens.filter { $0.kind != .comment }
        let words = tokens.enumerated().compactMap { index, token -> (index: Int, word: String)? in
            token.kind == .keyword || token.kind == .word ? (index, string.substring(with: token.range).uppercased()) : nil
        }
        guard let first = words.first?.word else { return .unknown("") }
        if writingKeywords.contains(first) { return .write(first) }
        guard readingKeywords.contains(first) else { return .unknown(first) }
        switch first {
        case "PRAGMA":
            let assigns = tokens.contains { $0.kind == .punctuation && string.substring(with: $0.range) == "=" }
            if assigns { return .write("PRAGMA … =") }
            // `PRAGMA name(value)` sets `name`, except for the pragmas that read about a table
            // or index (`table_info(users)`, #139).
            if let open = tokens.firstIndex(where: { $0.kind == .punctuation && string.substring(with: $0.range) == "(" }) {
                // The pragma's name is the word right before the parenthesis (`main.table_info(…)`).
                let name = words.last(where: { $0.index < open })?.word ?? ""
                return argumentReadingPragmas.contains(name) ? .read : .write("PRAGMA … (…)")
            }
            return .read
        case "EXPLAIN":
            // EXPLAIN ANALYZE runs the statement it explains (PostgreSQL, MySQL 8).
            guard words.dropFirst().prefix(3).contains(where: { $0.word == "ANALYZE" }) else { return .read }
            if let inner = words.first(where: { embeddedWrites.contains($0.word) && $0.word != "INTO" }) {
                return .write("EXPLAIN ANALYZE … \(inner.word)")
            }
            return .read
        default:
            for (position, entry) in words.enumerated().dropFirst() where embeddedWrites.contains(entry.word) {
                let previous = position > 0 ? words[position - 1].word : ""
                if entry.word == "UPDATE", previous == "FOR" || previous == "KEY" { return .write("FOR UPDATE, which locks rows") }
                if entry.word == "INTO" { return .write("\(first) … INTO") }
                return .write(entry.word)
            }
            return .read
        }
    }
}

// MARK: - Running

/// Builds the PHP that runs an SQL tab's statement (#35). The statement and connection name
/// are PHP string literals (escaped like Explain's, #4); the runner's `SqlTab::run()` resolves
/// the application's connection through the project's driver, or opens the run's saved
/// connection (#138, which this code never contains), and reports an `sql` event.
public enum SQLTabRun {
    /// Rows a result returns at most; the result says when there were more.
    public static let defaultMaxRows = 1000

    /// - Parameter schema: read the connection's tables and columns after the statement ran (#128).
    /// The connection is the application's, by name, unless the run carries a saved connection
    /// (#138, `RunRequest.sqlConnection`): then the runner opens that one, and this code (which
    /// never holds a definition or password) is the same.
    public static func code(statement: String, connection: String?, maxRows: Int = defaultMaxRows, schema: Bool = false) -> String {
        """
        <?php
        // Runlet SQL tab (#35): one statement on the tab's connection.
        return \\RunletRunner\\SqlTab::run(\(QueryExplain.phpString(statement)), \(connection.map(QueryExplain.phpString) ?? "null"), \(max(1, maxRows))\(schema ? ", true" : ""));
        """
    }

    /// Test Connection (#138): opens the run's saved connection and reports the server's
    /// version, the current database and user, and the round trip. No statement of the user's.
    public static let testCode = """
        <?php
        // Runlet SQL tab (#138): Test Connection for a saved connection.
        return \\RunletRunner\\SqlTab::test();
        """

    /// Load Schema (#128): the connection's tables and columns, nothing else.
    public static func schemaCode(connection: String?) -> String {
        """
        <?php
        // Runlet SQL tab (#128): the connection's tables and columns, for completion.
        return \\RunletRunner\\SqlTab::schema(\(connection.map(QueryExplain.phpString) ?? "null"));
        """
    }

    /// Run All Statements (#129): every statement in order, on one connection, optionally in
    /// one transaction. Each statement carries its first line, and whether MySQL commits it
    /// at once (`SQLScript.commitsImplicitly`).
    public static func scriptCode(statements: [SQLScript.Statement], connection: String?, transaction: Bool, maxRows: Int = defaultMaxRows, schema: Bool = false) -> String {
        let items = statements.map { statement in
            "    ['sql' => \(QueryExplain.phpString(statement.text)), 'line' => \(statement.startLine)\(SQLScript.commitsImplicitly(statement.text) ? ", 'implicitCommit' => true" : "")],"
        }
        return """
        <?php
        // Runlet SQL tab (#129): every statement in order, stopping at the first error.
        return \\RunletRunner\\SqlTab::runAll([
        \(items.joined(separator: "\n"))
        ], \(connection.map(QueryExplain.phpString) ?? "null"), \(max(1, maxRows)), \(transaction ? "true" : "false")\(schema ? ", true" : ""));
        """
    }
}

/// One cell of an SQL result: JSON null, bool, number, or string; or an object for a value
/// the runner shortened (`text` + `omittedBytes`) or that is not UTF-8 text (`binary` + `hex`).
public enum SQLCell: Sendable, Codable, Equatable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case clipped(String, omittedBytes: Int)
    case binary(bytes: Int, hexPrefix: String)

    private enum Keys: String, CodingKey { case text, omittedBytes, binary, hex }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() { self = .null; return }
        if let value = try? single.decode(Bool.self) { self = .bool(value); return }
        if let value = try? single.decode(Int64.self) { self = .int(value); return }
        if let value = try? single.decode(Double.self) { self = .double(value); return }
        if let value = try? single.decode(String.self) { self = .string(value); return }
        let object = try decoder.container(keyedBy: Keys.self)
        if let bytes = try object.decodeIfPresent(Int.self, forKey: .binary) {
            self = .binary(bytes: bytes, hexPrefix: try object.decodeIfPresent(String.self, forKey: .hex) ?? "")
        } else {
            self = .clipped(try object.decodeIfPresent(String.self, forKey: .text) ?? "", omittedBytes: try object.decodeIfPresent(Int.self, forKey: .omittedBytes) ?? 0)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var single = encoder.singleValueContainer()
            try single.encodeNil()
        case .bool(let value):
            var single = encoder.singleValueContainer()
            try single.encode(value)
        case .int(let value):
            var single = encoder.singleValueContainer()
            try single.encode(value)
        case .double(let value):
            var single = encoder.singleValueContainer()
            try single.encode(value)
        case .string(let value):
            var single = encoder.singleValueContainer()
            try single.encode(value)
        case .clipped(let text, let omitted):
            var object = encoder.container(keyedBy: Keys.self)
            try object.encode(text, forKey: .text)
            try object.encode(omitted, forKey: .omittedBytes)
        case .binary(let bytes, let hex):
            var object = encoder.container(keyedBy: Keys.self)
            try object.encode(bytes, forKey: .binary)
            try object.encode(hex, forKey: .hex)
        }
    }

    /// The text shown in a result table.
    public var text: String {
        switch self {
        case .null: "NULL"
        case .bool(let value): value ? "true" : "false"
        case .int(let value): String(value)
        case .double(let value): value.rounded() == value && abs(value) < 1e15 ? String(format: "%.1f", value) : String(value)
        case .string(let value): value
        // -1: the runner read a stream only up to its limit, so the full size is unknown.
        case .clipped(let text, let omitted): text + (omitted < 0 ? "… (truncated)" : "… (\(ByteCountFormatter.string(fromByteCount: Int64(omitted), countStyle: .memory)) more)")
        case .binary(let bytes, let hex): bytes < 0
            ? "0x\(hex)… (binary, over 8 KB)"
            : "0x\(hex)\(bytes * 2 > hex.count ? "…" : "") (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)) binary)"
        }
    }

    public var number: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }

    var valueNode: ValueNode {
        switch self {
        case .null: ValueNode(id: 0, type: .null)
        case .bool(let value): ValueNode(id: 0, type: .bool, scalar: value ? "true" : "false")
        case .int(let value): ValueNode(id: 0, type: .int, scalar: String(value))
        case .double(let value): ValueNode(id: 0, type: .float, scalar: String(value))
        case .string(let value): ValueNode(id: 0, type: .string, scalar: value)
        case .clipped, .binary: ValueNode(id: 0, type: .string, scalar: text)
        }
    }
}

/// The runner's `sql` event (#35): a statement's result set, or the rows it affected.
public struct SQLResultInfo: Sendable, Codable, Equatable {
    /// Which statement of a Run All Statements run (#129) this result belongs to.
    public struct StatementInfo: Sendable, Codable, Equatable {
        /// 1-based.
        public var index: Int
        public var count: Int
        /// The statement's first line in the tab.
        public var line: Int
        /// The statement (the runner shortens long ones).
        public var text: String?

        public init(index: Int, count: Int, line: Int, text: String? = nil) {
            self.index = index
            self.count = count
            self.line = line
            self.text = text
        }

        /// "Statement 2 of 5 · line 7"
        public var title: String { "Statement \(index) of \(count) · line \(line)" }
    }

    /// Column names, in order (duplicates kept, e.g. two `id` columns of a join).
    public var columns: [String] { didSet { table = Self.makeTable(columns: columns, rows: rows) } }
    public var rows: [[SQLCell]] { didSet { table = Self.makeTable(columns: columns, rows: rows) } }
    /// The rows as a sortable, filterable table (the output's grid, the result window), built
    /// once with the result (#162): where the `sql` event is decoded, off the main thread, and
    /// again only when `columns` or `rows` change. Not part of the event.
    public private(set) var table: ValueTable
    /// The statement returned more rows than `rows` holds (`truncation` says which limit).
    public var truncated: Bool?
    /// `rows` (the row cap) or `bytes` (the result size cap).
    public var truncation: String?
    /// Columns past the column cap, left out of every row.
    public var omittedColumns: Int?
    /// Set for statements without a result set (INSERT, UPDATE, DDL, …).
    public var affectedRows: Int?
    /// Executing and fetching, measured by the runner.
    public var elapsedMs: Double?
    /// The connection name the tab chose; nil for the default connection.
    public var connection: String?
    /// The database driver (`sqlite`, `mysql`, `pgsql`, …), when known.
    public var driver: String?
    /// Where the connection came from, e.g. "Laravel DB::connection()" or "AcmeApiDriver::sqlConnection()".
    public var source: String?
    /// Connection names the project's driver lists for the tab's picker.
    public var connections: [String]?
    /// The row cap the run used.
    public var maxRows: Int?
    /// Run All Statements (#129): the statement this result belongs to; nil for a single run.
    public var statement: StatementInfo?
    /// The statement ran on a saved connection (#138): `connection` is its name and `source`
    /// says `saved connection "Reporting" (pgsql, db.internal:5432/reports)`.
    public var saved: Bool?

    public init(columns: [String] = [], rows: [[SQLCell]] = [], truncated: Bool? = nil, truncation: String? = nil, omittedColumns: Int? = nil, affectedRows: Int? = nil, elapsedMs: Double? = nil, connection: String? = nil, driver: String? = nil, source: String? = nil, connections: [String]? = nil, maxRows: Int? = nil, statement: StatementInfo? = nil, saved: Bool? = nil) {
        self.columns = columns
        self.rows = rows
        table = Self.makeTable(columns: columns, rows: rows)
        self.truncated = truncated
        self.truncation = truncation
        self.omittedColumns = omittedColumns
        self.affectedRows = affectedRows
        self.elapsedMs = elapsedMs
        self.connection = connection
        self.driver = driver
        self.source = source
        self.connections = connections
        self.maxRows = maxRows
        self.statement = statement
        self.saved = saved
    }

    enum CodingKeys: String, CodingKey {
        case columns, rows, truncated, truncation, omittedColumns, affectedRows, elapsedMs, connection, driver, source, connections, maxRows, statement, saved
    }

    /// Statements without a result set come without `columns` and `rows`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        columns = try c.decodeIfPresent([String].self, forKey: .columns) ?? []
        rows = try c.decodeIfPresent([[SQLCell]].self, forKey: .rows) ?? []
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated)
        truncation = try c.decodeIfPresent(String.self, forKey: .truncation)
        omittedColumns = try c.decodeIfPresent(Int.self, forKey: .omittedColumns)
        affectedRows = try c.decodeIfPresent(Int.self, forKey: .affectedRows)
        elapsedMs = try c.decodeIfPresent(Double.self, forKey: .elapsedMs)
        connection = try c.decodeIfPresent(String.self, forKey: .connection)
        driver = try c.decodeIfPresent(String.self, forKey: .driver)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        connections = try c.decodeIfPresent([String].self, forKey: .connections)
        maxRows = try c.decodeIfPresent(Int.self, forKey: .maxRows)
        statement = try? c.decodeIfPresent(StatementInfo.self, forKey: .statement)
        saved = try? c.decodeIfPresent(Bool.self, forKey: .saved)
        table = Self.makeTable(columns: columns, rows: rows)
    }

    /// The line under a result: `via saved connection "Reporting" (pgsql, db.internal:5432/reports)`
    /// (#138), or "sqlite · default connection · via Laravel DB::connection()".
    public var originText: String {
        if saved == true {
            return source.map { "via \($0)" } ?? "via saved connection “\(connection ?? "")”"
        }
        let connection = connection.map { "connection “\($0)”" } ?? "default connection"
        return [driver, connection, source.map { "via \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    public var hasResultSet: Bool { affectedRows == nil }

    /// "3 rows", "1 row affected", "First 1,000 rows (more not shown)".
    public var summary: String {
        if let affected = affectedRows {
            return "\(affected.formatted()) row\(affected == 1 ? "" : "s") affected"
        }
        let count = rows.count
        if truncated == true {
            return truncation == "bytes"
                ? "First \(count.formatted()) row\(count == 1 ? "" : "s") (result size limit; more not shown)"
                : "First \(count.formatted()) row\(count == 1 ? "" : "s") (more not shown)"
        }
        return "\(count.formatted()) row\(count == 1 ? "" : "s")"
    }

    /// "3.2 ms"
    public var elapsedText: String? {
        elapsedMs.map { $0 < 10 ? String(format: "%.2f ms", $0) : String(format: "%.0f ms", $0) }
    }

    static func makeTable(columns: [String], rows: [[SQLCell]]) -> ValueTable {
        var fields: [[ValueTable.Field]] = []
        var cells: [[ValueTable.Cell]] = []
        fields.reserveCapacity(rows.count)
        cells.reserveCapacity(rows.count)
        for row in rows {
            fields.append(zip(columns, row).map { ValueTable.Field(key: $0.0, keyType: "string", value: $0.1.valueNode) })
            cells.append(row.map { ValueTable.Cell(text: $0.text, number: $0.number, isNull: $0 == .null) })
        }
        return ValueTable(columns: columns, rowKeys: rows.indices.map { String($0 + 1) }, rows: cells, rowFields: fields, omittedRows: 0)
    }

    /// Tab-separated text for Copy Output.
    public var plainText: String {
        var lines = ["SQL" + (statement.map { " (\($0.title))" } ?? "") + ": " + summary + (elapsedText.map { " in " + $0 } ?? "")]
        if let text = statement?.text { lines.append(text) }
        if hasResultSet, !columns.isEmpty {
            lines.append(columns.joined(separator: "\t"))
            for row in rows { lines.append(row.map(\.text).joined(separator: "\t")) }
        }
        return lines.joined(separator: "\n")
    }

    /// A Markdown table for Copy Output as Markdown.
    public var markdown: String {
        var text = "### SQL" + (statement.map { " — " + MarkdownText.inline($0.title) } ?? "") + ": " + MarkdownText.inline(summary) + (elapsedText.map { " (\($0))" } ?? "")
        if let statement = statement?.text { text += "\n\n" + MarkdownText.fence(statement, language: "sql") }
        guard hasResultSet, !columns.isEmpty else { return text }
        func cell(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
        }
        text += "\n\n| " + columns.map(cell).joined(separator: " | ") + " |\n|" + columns.map { _ in " --- |" }.joined()
        for row in rows { text += "\n| " + row.map { cell($0.text) }.joined(separator: " | ") + " |" }
        return text
    }
}

/// Test Connection's report (#138, the runner's `sqlTest` event).
public struct SQLConnectionTestInfo: Sendable, Codable, Equatable {
    public var driver: String?
    public var serverVersion: String?
    /// The current database (an SQLite file's path).
    public var database: String?
    public var user: String?
    /// Opening the connection.
    public var connectMs: Double?
    /// One `SELECT 1` round trip after connecting.
    public var roundTripMs: Double?
    public var phpVersion: String?
    /// The session is read-only (#139): the runner applied it and the database confirmed it.
    public var readOnly: Bool?
    /// Whether the server says the session is encrypted (#140); nil when the driver can't tell.
    public var tls: Bool?
    /// The TLS protocol and cipher, when encrypted (#140).
    public var tlsVersion: String?
    public var tlsCipher: String?
    /// SQL Server opened through `dblib` (FreeTDS) rather than `pdo_sqlsrv` (#140).
    public var pdoDriver: String?
    /// How many init statements ran first (#140).
    public var initStatements: Int?

    public init(driver: String? = nil, serverVersion: String? = nil, database: String? = nil, user: String? = nil, connectMs: Double? = nil, roundTripMs: Double? = nil, phpVersion: String? = nil, readOnly: Bool? = nil, tls: Bool? = nil, tlsVersion: String? = nil, tlsCipher: String? = nil, pdoDriver: String? = nil, initStatements: Int? = nil) {
        self.driver = driver
        self.serverVersion = serverVersion
        self.database = database
        self.user = user
        self.connectMs = connectMs
        self.roundTripMs = roundTripMs
        self.phpVersion = phpVersion
        self.readOnly = readOnly
        self.tls = tls
        self.tlsVersion = tlsVersion
        self.tlsCipher = tlsCipher
        self.pdoDriver = pdoDriver
        self.initStatements = initStatements
    }

    /// "Connected: PostgreSQL 14.12 · database shop · user postgres · 3.1 ms round trip ·
    /// TLSv1.3"
    public var summary: String {
        let product: String
        switch driver {
        case "mysql": product = serverVersion.map { $0.localizedCaseInsensitiveContains("mariadb") ? "MariaDB \($0.replacingOccurrences(of: "-MariaDB", with: "", options: .caseInsensitive))" : "MySQL \($0)" } ?? "MySQL"
        case "pgsql": product = "PostgreSQL" + (serverVersion.map { " " + $0 } ?? "")
        case "sqlite": product = "SQLite" + (serverVersion.map { " " + $0 } ?? "")
        case "sqlsrv", "dblib": product = "SQL Server" + (serverVersion.map { " " + $0 } ?? "") + (pdoDriver == "dblib" ? " (pdo_dblib)" : "")
        default: product = [driver, serverVersion].compactMap { $0 }.joined(separator: " ")
        }
        var parts = ["Connected: \(product)"]
        if let database, !database.isEmpty { parts.append("database \(database)") }
        if let user, !user.isEmpty { parts.append("user \(user)") }
        if let roundTripMs { parts.append(String(format: roundTripMs < 10 ? "%.1f ms round trip" : "%.0f ms round trip", roundTripMs)) }
        if readOnly == true { parts.append("read-only session") }
        switch tls {
        case true?: parts.append(tlsVersion.flatMap { $0.isEmpty ? nil : $0 } ?? "TLS")
        case false?: parts.append("not encrypted")
        case nil: break
        }
        return parts.joined(separator: " · ")
    }

    /// "TLSv1.3, TLS_AES_256_GCM_SHA384" when encrypted (#140).
    public var tlsDetail: String? {
        guard tls == true else { return nil }
        let parts = [tlsVersion, tlsCipher].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "TLS" : parts.joined(separator: ", ")
    }
}

// MARK: - Schema (#128)

/// The runner's `sqlSchema` event (#128): a connection's tables and their columns, for SQL
/// completion. Only names and types; never rows. Kept in memory per target and connection.
public struct SQLSchemaInfo: Sendable, Codable, Equatable {
    public struct Column: Sendable, Codable, Equatable, Hashable {
        public var name: String
        /// The database's type name, lower case (`integer`, `varchar`, …), when known.
        public var type: String?
        /// Schema explorer (#21): whether NULL is allowed, when known.
        public var nullable: Bool?
        /// The default as the catalog spells it (`'pending'`, `now()`, …), shortened.
        public var defaultValue: String?
        public var primaryKey: Bool?
        /// The foreign key's target, `table.column` (or `table` when the column isn't named).
        public var references: String?

        public init(name: String, type: String? = nil, nullable: Bool? = nil, defaultValue: String? = nil, primaryKey: Bool? = nil, references: String? = nil) {
            self.name = name
            self.type = type
            self.nullable = nullable
            self.defaultValue = defaultValue
            self.primaryKey = primaryKey
            self.references = references
        }

        enum CodingKeys: String, CodingKey {
            case name, type, nullable, defaultValue = "default", primaryKey, references
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            nullable = try? c.decodeIfPresent(Bool.self, forKey: .nullable)
            defaultValue = try? c.decodeIfPresent(String.self, forKey: .defaultValue)
            primaryKey = try? c.decodeIfPresent(Bool.self, forKey: .primaryKey)
            references = try? c.decodeIfPresent(String.self, forKey: .references)
        }
    }

    /// Schema explorer (#21): an index and its columns, in order.
    public struct Index: Sendable, Codable, Equatable, Hashable {
        public var name: String
        public var columns: [String]
        public var unique: Bool?
        public var primary: Bool?

        public init(name: String, columns: [String], unique: Bool? = nil, primary: Bool? = nil) {
            self.name = name
            self.columns = columns
            self.unique = unique
            self.primary = primary
        }
    }

    public struct Table: Sendable, Codable, Equatable {
        /// As SQL names it in this connection (`schema.table` outside the default schema).
        public var name: String
        public var columns: [Column]
        /// Schema explorer (#21): `view` for views; nil for tables.
        public var kind: String?
        /// The database's estimate of the row count (MySQL, MariaDB, PostgreSQL), when it has one.
        public var rows: Int64?
        /// Nil when the indexes weren't read (SQLite's rowid primary key has none).
        public var indexes: [Index]?

        public init(name: String, columns: [Column] = [], kind: String? = nil, rows: Int64? = nil, indexes: [Index]? = nil) {
            self.name = name
            self.columns = columns
            self.kind = kind
            self.rows = rows
            self.indexes = indexes
        }

        enum CodingKeys: String, CodingKey {
            case name, columns, kind, rows, indexes
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            columns = try c.decodeIfPresent([Column].self, forKey: .columns) ?? []
            kind = try? c.decodeIfPresent(String.self, forKey: .kind)
            rows = try? c.decodeIfPresent(Int64.self, forKey: .rows)
            indexes = try? c.decodeIfPresent([Index].self, forKey: .indexes)
        }

        public var isView: Bool { kind == "view" }
    }

    /// The tab's connection name; nil for the default connection.
    public var connection: String?
    public var driver: String?
    /// Where the connection came from, as for results ("Laravel DB::connection()").
    public var source: String?
    /// How the schema was read: "information_schema", "sqlite_master", "AcmeDriver::sqlSchema()".
    public var how: String?
    public var tables: [Table]
    /// More tables or columns than Runlet keeps (2,000 tables, 50,000 columns).
    public var truncated: Bool?
    /// Reading failed; `tables` is empty.
    public var error: String?
    public var elapsedMs: Double?
    /// Details that couldn't be read (indexes, foreign keys), while tables and columns were.
    public var notes: [String]?

    public init(connection: String? = nil, driver: String? = nil, source: String? = nil, how: String? = nil, tables: [Table] = [], truncated: Bool? = nil, error: String? = nil, elapsedMs: Double? = nil, notes: [String]? = nil) {
        self.connection = connection
        self.driver = driver
        self.source = source
        self.how = how
        self.tables = tables
        self.truncated = truncated
        self.error = error
        self.elapsedMs = elapsedMs
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case connection, driver, source, how, tables, truncated, error, elapsedMs, notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connection = try c.decodeIfPresent(String.self, forKey: .connection)
        driver = try c.decodeIfPresent(String.self, forKey: .driver)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        how = try c.decodeIfPresent(String.self, forKey: .how)
        tables = try c.decodeIfPresent([Table].self, forKey: .tables) ?? []
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        elapsedMs = try c.decodeIfPresent(Double.self, forKey: .elapsedMs)
        notes = try? c.decodeIfPresent([String].self, forKey: .notes)
    }

    public var columnCount: Int { tables.reduce(0) { $0 + $1.columns.count } }

    /// "12 tables, 87 columns"
    public var summary: String {
        let tables = tables.count, columns = columnCount
        return "\(tables.formatted()) table\(tables == 1 ? "" : "s"), \(columns.formatted()) column\(columns == 1 ? "" : "s")" + (truncated == true ? " (more not read)" : "")
    }

    /// A table by name, ignoring case and identifier quotes.
    public func table(named name: String) -> Table? {
        let wanted = SQLCompletion.unquoted(name).lowercased()
        return tables.first { $0.name.lowercased() == wanted }
            ?? tables.first { $0.name.lowercased().hasSuffix("." + wanted) }
    }
}
