import Foundation

/// Load Next (#146): more rows of a result the row cap cut, a page at a time. A page runs the
/// statement again, in a fresh runner on the same connection with the same bound values, so
/// only plain reads page: `SELECT`, `WITH`, `TABLE`, and `VALUES` statements that
/// `SQLScript.effect` reads as reads and that lock no rows.
///
/// How a page skips the rows already shown:
/// - **The database skips them** (`Mode.append`): Runlet adds `LIMIT <n + 1> OFFSET <shown>` to
///   the end of the statement (SQLite, MySQL, MariaDB, PostgreSQL), or `OFFSET … ROWS FETCH
///   NEXT … ROWS ONLY` after its `ORDER BY` (SQL Server). The statement isn't wrapped in a
///   subquery: MariaDB and MySQL may drop a derived table's `ORDER BY`, MySQL refuses a
///   derived table with two columns of one name, SQLite renames them, and SQL Server refuses
///   `ORDER BY` and `WITH` there. The one extra row says whether more follow.
/// - **The runner skips them** (`Mode.skip`): the statement runs as written and the runner
///   fetches and discards the rows already shown. Always the same rows and columns, but the
///   database produces (and sends) every skipped row again. Used when the statement limits its
///   own rows (`LIMIT`, `OFFSET`, `FETCH`, `TOP`: the work is bounded by that limit), for SQL
///   Server without `ORDER BY` or with `FOR XML`/`FOR JSON`, and for connections whose dialect
///   Runlet doesn't know (a driver's callable, WordPress's `$wpdb`, other PDO drivers).
///
/// Pages are separate runs: rows can shift between pages when the data changes in between, and
/// without `ORDER BY` the database may return rows in another order each time.
public enum SQLPaging {
    /// Rows per page (Settings ▸ General ▸ SQL Results): the first run's row cap and each Load Next.
    public static let defaultPageSize = 1000
    public static let pageSizes = [1000, 2500, 5000, 10_000]
    public static let maxPageSize = 10_000
    /// What a result card keeps across its pages, so the grid stays quick and memory bounded.
    public static let maxLoadedRows = 50_000
    /// Bytes of cells (as the runner counts them) a result card keeps across its pages.
    public static let maxLoadedBytes = 64 * 1024 * 1024

    /// A setting's value as one of `pageSizes` (the nearest smaller one, at least the default).
    public static func normalizedPageSize(_ value: Int?) -> Int {
        guard let value else { return defaultPageSize }
        return pageSizes.last { $0 <= value } ?? defaultPageSize
    }

    /// Why a cut result can't load more rows.
    public enum Refusal: Error, Sendable, Equatable {
        /// The statement can change data (the keyword), so it never runs again by itself.
        case writes(String)
        /// Runlet can't tell what the statement does (what it starts with).
        case unclassified(String)
        /// The statement locks the rows it reads (`FOR SHARE`, `LOCK IN SHARE MODE`, …).
        case locking(String)
        /// A read that isn't a query Runlet can page (`SHOW`, `DESCRIBE`, `EXPLAIN`, `PRAGMA`).
        case notAQuery(String)
        /// One statement of a Run All Statements script (#129) of several.
        case script

        public var message: String {
            switch self {
            case .writes(let keyword):
                "Load Next runs the statement again for each page, so it pages only reads. This statement can change data (\(keyword)), so Runlet won't run it again."
            case .unclassified(let keyword):
                "Load Next runs the statement again for each page, so it pages only statements Runlet can tell are reads" + (keyword.isEmpty ? "." : ", and this one starts with \(keyword).")
            case .locking(let clause):
                "This statement locks the rows it reads (\(clause)), so Load Next won't run it again. Add LIMIT and OFFSET to page it yourself."
            case .notAQuery(let keyword):
                "Load Next pages SELECT, WITH, TABLE, and VALUES statements, not \(keyword)."
            case .script:
                "Load Next pages a statement run on its own: a page runs it again, without the statements before it in the script. Put the caret in this statement and press Run (⌘R) to load more of its rows."
            }
        }
    }

    public enum Mode: String, Sendable, Equatable {
        /// The database skips the rows shown: Runlet adds a row limit to the statement.
        case append
        /// The runner fetches and discards the rows shown: the statement runs as written.
        case skip
    }

    /// The dialect a page's SQL is written for, from the result's PDO driver name.
    public enum Dialect: Sendable, Equatable {
        case sqlite, mysql, pgsql, sqlServer
        /// Another driver, or none known (a callable connection).
        case other

        public init(driver: String?) {
            switch driver?.lowercased() {
            case "sqlite", "sqlite2": self = .sqlite
            case "mysql": self = .mysql
            case "pgsql": self = .pgsql
            case "sqlsrv", "dblib": self = .sqlServer
            default: self = .other
            }
        }
    }

    /// How a statement pages.
    public struct Plan: Sendable, Equatable {
        /// The statement as the first run sent it (without the closing `;`).
        public var statement: String
        public var mode: Mode
        public var dialect: Dialect
        /// The result's driver name (`mysql`, `pgsql`, …), which the runner checks for `append`.
        public var driver: String?
        /// The statement orders its rows (a top-level `ORDER BY`): pages are stable while the
        /// data doesn't change.
        public var ordered: Bool

        /// The page after the first `offset` rows, of at most `size` rows.
        public func page(offset: Int, size: Int) -> Page {
            let size = max(1, size)
            let offset = max(0, offset)
            guard mode == .append else {
                return Page(sql: statement, offset: offset, size: size, skip: offset, driver: nil, added: nil)
            }
            let clause: String
            switch dialect {
            case .sqlServer:
                // The statement has its own ORDER BY (the plan checked), which OFFSET needs.
                clause = "OFFSET \(offset) ROWS FETCH NEXT \(size + 1) ROWS ONLY"
            default:
                clause = "LIMIT \(size + 1) OFFSET \(offset)"
            }
            // On a line of its own, so a `--` comment at the statement's end can't hide it.
            return Page(sql: statement + "\n" + clause, offset: offset, size: size, skip: 0, driver: driver, added: clause)
        }
    }

    /// One page to fetch.
    public struct Page: Sendable, Equatable {
        /// What runs: the statement, with the row limit Runlet added (`append`).
        public var sql: String
        /// Rows shown before this page: the page starts at row `offset + 1`.
        public var offset: Int
        /// Rows the page keeps at most (the runner fetches one more to tell whether more follow).
        public var size: Int
        /// Rows the runner fetches and discards first (`skip`); 0 when the database skips them.
        public var skip: Int
        /// The driver the SQL was written for (`append`); the runner refuses another.
        public var driver: String?
        /// The clause Runlet added, for messages; nil when the statement runs as written.
        public var added: String?

        /// "rows 1,001–2,000"
        public var rowsText: String {
            "rows \((offset + 1).formatted())–\((offset + size).formatted())"
        }
    }

    /// How `statement` pages on a connection with `driver` (the result's), or why it can't.
    public static func plan(for statement: String, driver: String?) -> Result<Plan, Refusal> {
        let string = statement as NSString
        let tokens = SQLScript.tokenize(string).filter { $0.kind != .comment }
        switch SQLScript.effect(tokens: tokens, in: string) {
        case .write(let keyword): return .failure(.writes(keyword))
        case .unknown(let keyword): return .failure(.unclassified(keyword))
        case .read: break
        }
        let words = tokens.filter { $0.kind == .keyword || $0.kind == .word }.map { string.substring(with: $0.range).uppercased() }
        guard let first = words.first else { return .failure(.unclassified("")) }
        guard ["SELECT", "WITH", "TABLE", "VALUES"].contains(first) else { return .failure(.notAQuery(first)) }
        if let clause = lockingClause(words) { return .failure(.locking(clause)) }
        let shape = Shape(tokens: tokens, in: string)
        let dialect = Dialect(driver: driver)
        let mode: Mode = switch dialect {
        case .sqlite, .mysql, .pgsql: shape.limitsRows ? .skip : .append
        case .sqlServer: shape.limitsRows || !shape.ordered || shape.forClause ? .skip : .append
        case .other: .skip
        }
        return .success(Plan(statement: statement, mode: mode, dialect: dialect, driver: driver, ordered: shape.ordered))
    }

    /// `FOR SHARE`, `FOR KEY SHARE`, `FOR NO KEY UPDATE`, or `LOCK IN SHARE MODE` anywhere in the
    /// statement (`FOR UPDATE` is already a write for `SQLScript.effect`).
    static func lockingClause(_ words: [String]) -> String? {
        for (index, word) in words.enumerated() {
            let next = words.dropFirst(index + 1).prefix(3)
            if word == "FOR", let following = next.first {
                if following == "SHARE" { return "FOR SHARE" }
                if following == "UPDATE" { return "FOR UPDATE" }
                if following == "KEY", next.dropFirst().first == "SHARE" { return "FOR KEY SHARE" }
                if following == "NO", Array(next.dropFirst()) == ["KEY", "UPDATE"] { return "FOR NO KEY UPDATE" }
            }
            if word == "LOCK", Array(next) == ["IN", "SHARE", "MODE"] { return "LOCK IN SHARE MODE" }
        }
        return nil
    }

    /// What the statement says at its top level (outside parentheses: subqueries, CTE bodies,
    /// window definitions, function arguments).
    struct Shape {
        /// `ORDER BY`.
        var ordered = false
        /// Its own row limit: `LIMIT`, `OFFSET`, `FETCH`, or `TOP`. A column of that name only
        /// makes Runlet skip rows itself, which is always correct.
        var limitsRows = false
        /// SQL Server's `FOR XML`, `FOR JSON`, or `FOR BROWSE`, which must come last.
        var forClause = false

        init(tokens: [SQLScript.Token], in string: NSString) {
            var depth = 0
            var previous = ""
            for token in tokens {
                let text = string.substring(with: token.range)
                if token.kind == .punctuation {
                    if text == "(" { depth += 1 } else if text == ")" { depth = max(0, depth - 1) }
                    previous = ""
                    continue
                }
                guard depth == 0, token.kind == .keyword || token.kind == .word else {
                    previous = ""
                    continue
                }
                let word = text.uppercased()
                switch word {
                case "BY": if previous == "ORDER" { ordered = true }
                case "LIMIT", "OFFSET", "FETCH", "TOP": limitsRows = true
                case "XML", "JSON", "BROWSE": if previous == "FOR" { forClause = true }
                default: break
                }
                previous = word
            }
        }
    }
}

extension SQLTabRun {
    /// Load Next (#146): one page of `page`'s statement on the tab's connection (or the run's
    /// saved connection), with the first run's bound values (#145), as an `sql` event.
    public static func pageCode(_ page: SQLPaging.Page, connection: String?, bindings: [SQLBinding] = []) -> String {
        let driver = page.driver.map(QueryExplain.phpString) ?? "null"
        return """
        <?php
        // Runlet SQL tab (#146): the next page of a statement's rows.
        return \\RunletRunner\\SqlTab::page(\(QueryExplain.phpString(page.sql)), \(connection.map(QueryExplain.phpString) ?? "null"), \(max(1, page.size)), \(max(0, page.skip)), \(driver), \(phpBindings(bindings)), \(page.added.map(QueryExplain.phpString) ?? "null"));
        """
    }
}
