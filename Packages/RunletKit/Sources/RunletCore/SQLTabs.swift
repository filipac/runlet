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

    public static func tokenize(_ string: NSString) -> [Token] {
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
            if (c == 45 && i + 1 < length && buffer[i + 1] == 45) || (c == 35 && !(i + 1 < length && (buffer[i + 1] == 62 || buffer[i + 1] == 45))) {
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
    /// Inside a reading statement: keywords that make it write (a writable CTE, `SELECT … INTO`).
    static let embeddedWrites: Set<String> = ["INSERT", "UPDATE", "DELETE", "MERGE", "INTO", "CREATE", "DROP", "ALTER", "TRUNCATE"]

    public static func effect(of statement: String) -> Effect {
        let string = statement as NSString
        let tokens = tokenize(string).filter { $0.kind != .comment }
        let words = tokens.enumerated().compactMap { index, token -> (index: Int, word: String)? in
            token.kind == .keyword || token.kind == .word ? (index, string.substring(with: token.range).uppercased()) : nil
        }
        guard let first = words.first?.word else { return .unknown("") }
        if writingKeywords.contains(first) { return .write(first) }
        guard readingKeywords.contains(first) else { return .unknown(first) }
        switch first {
        case "PRAGMA":
            let assigns = tokens.contains { $0.kind == .punctuation && string.substring(with: $0.range) == "=" }
            return assigns ? .write("PRAGMA … =") : .read
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
/// the connection through the project's driver and reports an `sql` event.
public enum SQLTabRun {
    /// Rows a result returns at most; the result says when there were more.
    public static let defaultMaxRows = 1000

    public static func code(statement: String, connection: String?, maxRows: Int = defaultMaxRows) -> String {
        """
        <?php
        // Runlet SQL tab (#35): one statement through the application's own database connection.
        return \\RunletRunner\\SqlTab::run(\(QueryExplain.phpString(statement)), \(connection.map(QueryExplain.phpString) ?? "null"), \(max(1, maxRows)));
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
    /// Column names, in order (duplicates kept, e.g. two `id` columns of a join).
    public var columns: [String]
    public var rows: [[SQLCell]]
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

    public init(columns: [String] = [], rows: [[SQLCell]] = [], truncated: Bool? = nil, truncation: String? = nil, omittedColumns: Int? = nil, affectedRows: Int? = nil, elapsedMs: Double? = nil, connection: String? = nil, driver: String? = nil, source: String? = nil, connections: [String]? = nil, maxRows: Int? = nil) {
        self.columns = columns
        self.rows = rows
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
    }

    enum CodingKeys: String, CodingKey {
        case columns, rows, truncated, truncation, omittedColumns, affectedRows, elapsedMs, connection, driver, source, connections, maxRows
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

    /// The rows as a sortable, filterable table (the output's Table view).
    public var table: ValueTable {
        let fields = rows.map { row in
            zip(columns, row).map { ValueTable.Field(key: $0.0, keyType: "string", value: $0.1.valueNode) }
        }
        let cells = rows.map { row in
            row.map { ValueTable.Cell(text: $0.text, number: $0.number, isNull: $0 == .null) }
        }
        return ValueTable(columns: columns, rowKeys: rows.indices.map { String($0 + 1) }, rows: cells, rowFields: fields, omittedRows: 0)
    }

    /// Tab-separated text for Copy Output.
    public var plainText: String {
        var lines = ["SQL: " + summary + (elapsedText.map { " in " + $0 } ?? "")]
        if hasResultSet, !columns.isEmpty {
            lines.append(columns.joined(separator: "\t"))
            for row in rows { lines.append(row.map(\.text).joined(separator: "\t")) }
        }
        return lines.joined(separator: "\n")
    }

    /// A Markdown table for Copy Output as Markdown.
    public var markdown: String {
        var text = "### SQL: " + MarkdownText.inline(summary) + (elapsedText.map { " (\($0))" } ?? "")
        guard hasResultSet, !columns.isEmpty else { return text }
        func cell(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
        }
        text += "\n\n| " + columns.map(cell).joined(separator: " | ") + " |\n|" + columns.map { _ in " --- |" }.joined()
        for row in rows { text += "\n| " + row.map { cell($0.text) }.joined(separator: " | ") + " |" }
        return text
    }
}
