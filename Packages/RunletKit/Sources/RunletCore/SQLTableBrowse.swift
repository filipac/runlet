import Foundation

/// Browse Table (#151): the schema explorer opens one table in the result window, a page at a
/// time, sorted and filtered on the server. This writes each page's SELECT; nothing here runs.
///
/// Safety rules:
/// - Names (the table, its columns, the sort column) come from the schema's column list only,
///   never from text the user typed, and are always quoted for the dialect (a quote inside a
///   name is doubled).
/// - Filter values are always bound (`SQLBinding`), never written into the SQL. A value that
///   doesn't fit the column's type (letters for an integer column) is refused before anything
///   runs, as is an operator the column's type doesn't support (ordering booleans, comparing
///   JSON or binary values).
/// - Paging is `LIMIT … OFFSET …` (SQLite, MySQL, MariaDB, PostgreSQL) or `OFFSET … ROWS FETCH
///   NEXT … ROWS ONLY` (SQL Server), with Runlet's own numbers; each page asks for one row more
///   than it shows, to tell whether another page follows.
/// - Without a sort, pages follow the primary key, so they are stable while the data stays the
///   same; a sort on another column adds the primary key after it.
public enum SQLTableBrowse {
    /// Rows per page.
    public static let pageSizes = [25, 50, 100, 250, 500, 1000]
    public static let defaultPageSize = 100
    /// Columns a page reads at most (the runner keeps 200 per row).
    public static let maxColumns = 200

    // MARK: Dialects

    /// The databases Browse Table writes SQL for.
    public enum Dialect: String, Sendable, Equatable, CaseIterable {
        case mysql, pgsql, sqlite, sqlServer

        /// The schema's PDO driver; a callable connection has none, except WordPress's `$wpdb`,
        /// which is MySQL. Nil for other databases (Oracle, a driver's own callable).
        public init?(driver: String?, source: String? = nil) {
            switch driver?.lowercased() {
            case "mysql": self = .mysql
            case "pgsql": self = .pgsql
            case "sqlite", "sqlite2": self = .sqlite
            case "sqlsrv", "dblib": self = .sqlServer
            case nil where source == "WordPress $wpdb": self = .mysql
            default: return nil
            }
        }

        /// "PostgreSQL"
        public var displayName: String {
            switch self {
            case .mysql: "MySQL"
            case .pgsql: "PostgreSQL"
            case .sqlite: "SQLite"
            case .sqlServer: "SQL Server"
            }
        }

        /// A name, always quoted: `` `a``b` `` (MySQL), `[a]]b]` (SQL Server), `"a""b"` (others).
        public func quote(_ name: String) -> String {
            switch self {
            case .mysql: "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
            case .sqlServer: "[" + name.replacingOccurrences(of: "]", with: "]]") + "]"
            case .pgsql, .sqlite: "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
        }

        /// A table as the schema names it: on PostgreSQL and SQL Server, `schema.table` outside
        /// the default schema (`SqlSchema`), so the part before the first dot is the schema.
        public func table(_ name: String) -> String {
            switch self {
            case .pgsql, .sqlServer:
                let parts = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty { return quote(parts[0]) + "." + quote(parts[1]) }
                return quote(name)
            case .mysql, .sqlite:
                return quote(name)
            }
        }

        /// `LIMIT 101 OFFSET 200`, or SQL Server's `OFFSET 200 ROWS FETCH NEXT 101 ROWS ONLY`.
        func limit(_ rows: Int, offset: Int) -> String {
            switch self {
            case .sqlServer: "OFFSET \(offset) ROWS FETCH NEXT \(rows) ROWS ONLY"
            default: "LIMIT \(rows) OFFSET \(offset)"
            }
        }
    }

    // MARK: Column types

    /// What a column holds, from the type name the schema reports: how its values are typed when
    /// bound, and which filters and edits it takes.
    public enum ColumnKind: String, Sendable, Equatable {
        case integer
        /// DECIMAL, NUMERIC: exact; bound as text so every digit stays.
        case decimal
        /// FLOAT, REAL, DOUBLE: approximate.
        case float
        case boolean
        case text
        /// DATE, TIME, DATETIME, TIMESTAMP, YEAR.
        case temporal
        case binary
        case json
        case uuid
        /// Anything else (arrays, geometry, ranges, an unknown or missing type).
        case other

        /// - Parameter dialect: SQL Server's `bit` is 0 or 1, MySQL's a bit string.
        public init(type: String?, dialect: Dialect? = nil) {
            let raw = (type ?? "").lowercased()
            // `varchar(255)` → `varchar`; `int(11) unsigned` → `int`.
            var name = raw.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
            for word in [" unsigned", " signed", " zerofill"] { name = name.replacingOccurrences(of: word, with: "") }
            name = name.trimmingCharacters(in: .whitespaces)
            if name.isEmpty || raw.hasSuffix("[]") || name.hasPrefix("_") { self = .other; return } // PostgreSQL arrays
            if name == "bit", dialect == .sqlServer { self = .integer; return }
            switch name {
            case "int", "integer", "bigint", "smallint", "tinyint", "mediumint", "int2", "int4", "int8", "serial", "bigserial", "smallserial", "long":
                self = .integer
            case "decimal", "numeric", "number", "dec", "fixed", "money", "smallmoney":
                self = .decimal
            case "float", "real", "double", "double precision", "float4", "float8":
                self = .float
            case "boolean", "bool":
                self = .boolean
            case "date", "time", "datetime", "datetime2", "smalldatetime", "datetimeoffset", "timestamp", "year", "timetz", "timestamptz",
                 "time with time zone", "time without time zone", "timestamp with time zone", "timestamp without time zone":
                self = .temporal
            case "blob", "tinyblob", "mediumblob", "longblob", "bytea", "binary", "varbinary", "image", "bit", "bit varying", "varbit", "rowversion":
                self = .binary
            case "json", "jsonb":
                self = .json
            case "uuid", "uniqueidentifier":
                self = .uuid
            case "enum", "set", "citext", "name", "string", "clob":
                self = .text
            default:
                if name.hasSuffix(" int") || name.hasSuffix("integer") {
                    self = .integer // SQLite's "unsigned big int", "big int"
                } else if name.contains("char") || name.contains("text") || name.contains("clob") {
                    self = .text
                } else if name.hasPrefix("timestamp") || name.hasPrefix("datetime") {
                    self = .temporal
                } else if name.contains("blob") {
                    self = .binary
                } else {
                    self = .other
                }
            }
        }

        /// "integer", "decimal number", …, for messages.
        public var displayName: String {
            switch self {
            case .integer: "integer"
            case .decimal: "decimal"
            case .float: "floating-point"
            case .boolean: "boolean"
            case .text: "text"
            case .temporal: "date and time"
            case .binary: "binary"
            case .json: "JSON"
            case .uuid: "UUID"
            case .other: "other"
            }
        }

        /// Whether `col = ''` makes sense: "is empty" is `IS NULL OR = ''` for text, `IS NULL`
        /// for the rest (PostgreSQL refuses `''` for an integer, MySQL would match 0).
        var holdsText: Bool { self == .text }

        /// Whether an UPDATE also checks this column's original value (the optimistic check):
        /// values that read back as the database compares them. Approximate numbers, JSON,
        /// binary, and unknown types are checked by their primary key only.
        public var comparesExactly: Bool {
            switch self {
            case .integer, .decimal, .boolean, .text, .temporal, .uuid: true
            case .float, .binary, .json, .other: false
            }
        }

        /// The typed value for `text` in a column of this kind: integers as integers (a value
        /// past 64 bits as decimal text), decimals as their digits, booleans as `true`/`false`
        /// (also 1/0, t/f, yes/no), everything else as text. Nil when it doesn't fit.
        public func value(_ text: String) -> SQLParameterValue? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            switch self {
            case .integer:
                if let integer = Int(trimmed.hasPrefix("+") ? String(trimmed.dropFirst()) : trimmed) { return .integer(integer) }
                return trimmed.range(of: #"^[+-]?[0-9]+$"#, options: .regularExpression) != nil ? .decimal(trimmed) : nil
            case .decimal, .float:
                return trimmed.range(of: #"^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil ? .decimal(trimmed) : nil
            case .boolean:
                switch trimmed.lowercased() {
                case "true", "t", "1", "yes", "y", "on": return .boolean(true)
                case "false", "f", "0", "no", "n", "off": return .boolean(false)
                default: return nil
                }
            case .binary:
                return nil
            case .text, .temporal, .json, .uuid, .other:
                return .text(text)
            }
        }

        /// Why `text` doesn't fit, for messages.
        public func problem(_ text: String) -> String {
            switch self {
            case .integer: "“\(text)” isn't a whole number"
            case .decimal, .float: "“\(text)” isn't a number"
            case .boolean: "“\(text)” isn't true or false"
            case .binary: "Runlet doesn't edit or filter binary values"
            default: "“\(text)” doesn't fit"
            }
        }
    }

    // MARK: Pages

    /// A server-side filter rule: a column of the table, one of the result window's operators,
    /// and its value.
    public struct Filter: Sendable, Equatable {
        public var column: String
        public var op: ValueTableFilter.Operator
        public var value: String

        public init(column: String, op: ValueTableFilter.Operator, value: String = "") {
            self.column = column
            self.op = op
            self.value = value
        }

        /// The rule needs a value and has none yet: it is left out until it has one.
        public var isIncomplete: Bool { !op.isUnary && value.isEmpty }
    }

    /// The sort: a column of the table, ascending or descending.
    public struct Sort: Sendable, Equatable {
        public var column: String
        public var ascending: Bool

        public init(column: String, ascending: Bool = true) {
            self.column = column
            self.ascending = ascending
        }
    }

    /// One page to read.
    public struct Request: Sendable, Equatable {
        /// As the schema names it.
        public var table: String
        /// The table's columns, in the schema's order; a page reads the first `maxColumns`.
        public var columns: [SQLSchemaInfo.Column]
        public var dialect: Dialect
        public var sort: Sort?
        public var filters: [Filter]
        /// Rows before the page.
        public var offset: Int
        public var pageSize: Int
        /// The connection binds values (a PDO). A callable connection reads pages without them,
        /// so filters that need a value are refused there.
        public var bindsValues: Bool

        public init(table: String, columns: [SQLSchemaInfo.Column], dialect: Dialect, sort: Sort? = nil, filters: [Filter] = [], offset: Int = 0, pageSize: Int = SQLTableBrowse.defaultPageSize, bindsValues: Bool = true) {
            self.table = table
            self.columns = columns
            self.dialect = dialect
            self.sort = sort
            self.filters = filters
            self.offset = offset
            self.pageSize = pageSize
            self.bindsValues = bindsValues
        }

        /// The columns a page reads.
        public var readColumns: [SQLSchemaInfo.Column] { Array(columns.prefix(SQLTableBrowse.maxColumns)) }

        /// The primary key's columns, in the table's order.
        public var primaryKey: [String] { columns.filter { $0.primaryKey == true }.map(\.name) }
    }

    /// A page's SELECT and its bound values.
    public struct Query: Sendable, Equatable {
        public var sql: String
        public var bindings: [SQLBinding]
        /// Rows the page shows at most (the SELECT asks for one more).
        public var pageSize: Int
        public var offset: Int
        /// The rows come in a stable order: a sort or the primary key.
        public var ordered: Bool

        /// "rows 101–200"
        public var rowsText: String {
            "rows \((offset + 1).formatted())–\((offset + pageSize).formatted())"
        }

        /// The SQL with its values as a comment, for the production confirmation.
        public var display: String {
            bindings.isEmpty ? sql : sql + "\n-- " + bindings.enumerated().map { "?\($0.offset + 1) = \($0.element.value.display(limit: 60))" }.joined(separator: ", ")
        }
    }

    /// Why a page can't be read as asked.
    public enum Refusal: Error, Sendable, Equatable, CustomStringConvertible {
        /// The table has no columns in the schema.
        case noColumns(String)
        /// A filter or the sort names a column the table doesn't have (the schema changed).
        case unknownColumn(String)
        /// The column's type doesn't take the operator.
        case unsupported(column: String, op: ValueTableFilter.Operator, kind: ColumnKind)
        /// The value doesn't fit the column's type.
        case invalidValue(column: String, value: String, kind: ColumnKind)
        /// A filter with a value on a connection that can't bind values.
        case cannotBind(column: String)

        public var description: String {
            switch self {
            case .noColumns(let table):
                "The schema lists no columns for \(table). Reload the schema, then browse the table again."
            case .unknownColumn(let column):
                "The table has no column \(column) in the schema Runlet read. Reload the schema, then browse the table again."
            case .unsupported(let column, let op, let kind):
                switch kind {
                case .binary: "\(column) holds binary values, which Runlet doesn't filter by value: use “is empty or NULL” or “isn't empty”."
                case .boolean: "\(column) is a boolean: filter it with = or ≠ (\(op.title) isn't supported)."
                case .json: "\(column) holds JSON, which databases don't compare as text: filter it with “contains” (\(op.title) isn't supported)."
                default: "\(column) (\(kind.displayName)) can't be filtered with \(op.title)."
                }
            case .invalidValue(let column, let value, let kind):
                "The filter on \(column) can't run: \(kind.problem(value)). \(column) is a\(kind == .integer ? "n" : "") \(kind.displayName) column, and Runlet binds the value as one."
            case .cannotBind(let column):
                "The filter on \(column) needs a bound value, and this connection runs statements through a callable that can't bind values. Runlet never writes values into the SQL. Filter with “is empty or NULL” or “isn't empty”, or query the table in an SQL tab."
            }
        }
    }

    /// The page's SELECT, or why it can't be written.
    public static func query(_ request: Request) -> Result<Query, Refusal> {
        let dialect = request.dialect
        let columns = request.readColumns
        guard !columns.isEmpty else { return .failure(.noColumns(request.table)) }
        var bindings: [SQLBinding] = []
        var conditions: [String] = []
        for filter in request.filters where !filter.isIncomplete {
            guard let column = request.columns.first(where: { $0.name == filter.column }) else { return .failure(.unknownColumn(filter.column)) }
            switch condition(filter, column: column, dialect: dialect) {
            case .failure(let refusal):
                return .failure(refusal)
            case .success(let (sql, values)):
                if !values.isEmpty, !request.bindsValues { return .failure(.cannotBind(column: column.name)) }
                for value in values { bindings.append(SQLBinding(target: .position(bindings.count + 1), value: value)) }
                conditions.append(sql)
            }
        }
        var order: [String] = []
        if let sort = request.sort {
            guard request.columns.contains(where: { $0.name == sort.column }) else { return .failure(.unknownColumn(sort.column)) }
            order.append("\(dialect.quote(sort.column)) \(sort.ascending ? "ASC" : "DESC")")
        }
        for key in request.primaryKey where key != request.sort?.column {
            order.append("\(dialect.quote(key)) \(request.sort?.ascending == false ? "DESC" : "ASC")")
        }
        let ordered = !order.isEmpty
        if order.isEmpty, dialect == .sqlServer {
            order.append("(SELECT NULL)") // OFFSET … FETCH needs an ORDER BY.
        }
        let size = max(1, request.pageSize)
        let offset = max(0, request.offset)
        var sql = "SELECT " + columns.map { dialect.quote($0.name) }.joined(separator: ", ") + "\nFROM " + dialect.table(request.table)
        if !conditions.isEmpty { sql += "\nWHERE " + conditions.joined(separator: "\n  AND ") }
        if !order.isEmpty { sql += "\nORDER BY " + order.joined(separator: ", ") }
        sql += "\n" + dialect.limit(size + 1, offset: offset)
        return .success(Query(sql: sql, bindings: bindings, pageSize: size, offset: offset, ordered: ordered))
    }

    /// One filter as a condition and the values it binds. Rules follow the result window's
    /// operators (`ValueTableFilter.matches`): NULL matches "doesn't contain" and ≠; "contains"
    /// ignores case where the database's LIKE does (ILIKE on PostgreSQL).
    static func condition(_ filter: Filter, column: SQLSchemaInfo.Column, dialect: Dialect) -> Result<(String, [SQLParameterValue]), Refusal> {
        let kind = ColumnKind(type: column.type, dialect: dialect)
        let name = dialect.quote(column.name)
        switch filter.op {
        case .isEmpty:
            return .success((kind.holdsText ? "(\(name) IS NULL OR \(name) = '')" : "\(name) IS NULL", []))
        case .isNotEmpty:
            return .success((kind.holdsText ? "(\(name) IS NOT NULL AND \(name) <> '')" : "\(name) IS NOT NULL", []))
        case .contains, .doesNotContain:
            guard kind != .binary else { return .failure(.unsupported(column: column.name, op: filter.op, kind: kind)) }
            let pattern = SQLParameterValue.text("%" + likeEscaped(filter.value, dialect: dialect) + "%")
            if filter.op == .contains { return .success(("\(likeExpression(name, kind: kind, dialect: dialect)) ESCAPE '!'", [pattern])) }
            return .success(("(\(name) IS NULL OR \(likeExpression(name, kind: kind, dialect: dialect, negated: true)) ESCAPE '!')", [pattern]))
        case .equals, .doesNotEqual, .lessThan, .lessOrEqual, .greaterThan, .greaterOrEqual:
            switch kind {
            case .binary, .json:
                return .failure(.unsupported(column: column.name, op: filter.op, kind: kind))
            case .boolean where filter.op != .equals && filter.op != .doesNotEqual:
                return .failure(.unsupported(column: column.name, op: filter.op, kind: kind))
            default:
                break
            }
            guard let value = kind.value(filter.value) else { return .failure(.invalidValue(column: column.name, value: filter.value, kind: kind)) }
            let comparison: String = switch filter.op {
            case .equals: "\(name) = ?"
            case .doesNotEqual: "(\(name) IS NULL OR \(name) <> ?)"
            case .lessThan: "\(name) < ?"
            case .lessOrEqual: "\(name) <= ?"
            case .greaterThan: "\(name) > ?"
            default: "\(name) >= ?"
            }
            return .success((comparison, [value]))
        }
    }

    /// `name LIKE ?`: ILIKE on PostgreSQL (with a cast to text for other types, which PostgreSQL
    /// doesn't compare with LIKE); SQL Server casts other types to NVARCHAR.
    static func likeExpression(_ name: String, kind: ColumnKind, dialect: Dialect, negated: Bool = false) -> String {
        let not = negated ? "NOT " : ""
        switch dialect {
        case .pgsql: return kind == .text ? "\(name) \(not)ILIKE ?" : "CAST(\(name) AS TEXT) \(not)ILIKE ?"
        case .sqlServer: return kind == .text ? "\(name) \(not)LIKE ?" : "CAST(\(name) AS NVARCHAR(MAX)) \(not)LIKE ?"
        case .mysql, .sqlite: return "\(name) \(not)LIKE ?"
        }
    }

    /// A LIKE pattern's literal text: `!` escapes `%`, `_`, and itself (and SQL Server's `[`),
    /// with `ESCAPE '!'` (a backslash would depend on MySQL's SQL mode).
    static func likeEscaped(_ text: String, dialect: Dialect) -> String {
        var escaped = ""
        for character in text {
            if character == "!" || character == "%" || character == "_" || (dialect == .sqlServer && character == "[") { escaped.append("!") }
            escaped.append(character)
        }
        return escaped
    }
}

extension SQLTabRun {
    /// Browse Table (#151): one page of a table (`SqlTab::browse`), as an `sql` event whose
    /// `truncated` says whether another page follows. `driver` is the schema's PDO driver, which
    /// the runner checks the connection against (nil for a callable connection).
    public static func browseCode(_ query: SQLTableBrowse.Query, connection: String?, driver: String?) -> String {
        """
        <?php
        // Runlet Browse Table (#151): one page of a table.
        return \\RunletRunner\\SqlTab::browse(\(QueryExplain.phpString(query.sql)), \(connection.map(QueryExplain.phpString) ?? "null"), \(max(1, query.pageSize)), \(driver.map(QueryExplain.phpString) ?? "null"), \(phpBindings(query.bindings)));
        """
    }
}
