import Foundation

/// The schema explorer (#21): filtering a connection's tables and columns, describing them,
/// and the code its actions prepare. Nothing here runs anything: the explorer only opens or
/// inserts text.
public enum SQLSchemaExplorer {
    /// One table as the filtered list shows it.
    public struct Match: Sendable, Equatable {
        public var table: SQLSchemaInfo.Table
        /// The columns to show: all of them, or only the matching ones when the filter matched
        /// columns and not the table's name.
        public var columns: [SQLSchemaInfo.Column]
        /// The filter matched only columns, so the table opens expanded to show them.
        public var matchedColumns: Bool
    }

    /// Tables whose name contains `query` (all their columns), then tables with a column whose
    /// name contains it (those columns only), ignoring case. An empty query keeps everything.
    public static func filter(_ tables: [SQLSchemaInfo.Table], query: String) -> [Match] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return tables.map { Match(table: $0, columns: $0.columns, matchedColumns: false) } }
        var byName: [Match] = []
        var byColumn: [Match] = []
        for table in tables {
            if table.name.lowercased().contains(needle) {
                byName.append(Match(table: table, columns: table.columns, matchedColumns: false))
            } else {
                let columns = table.columns.filter { $0.name.lowercased().contains(needle) }
                if !columns.isEmpty { byColumn.append(Match(table: table, columns: columns, matchedColumns: true)) }
            }
        }
        return byName + byColumn
    }

    /// A table or column name as SQL needs it on `driver` (quoted when it must be), like completion.
    public static func quoted(_ name: String, driver: String?) -> String {
        SQLCompletion.qualifiedIdentifier(name, quote: driver == "mysql" ? "`" : "\"", pgsql: driver == "pgsql")
    }

    /// Open in SQL Tab: the table's first rows (`SELECT TOP` on SQL Server).
    public static func selectQuery(table: String, driver: String?, limit: Int = 50) -> String {
        let name = quoted(table, driver: driver)
        switch driver {
        case "sqlsrv", "dblib": return "SELECT TOP \(limit) *\nFROM \(name);"
        case "oci": return "SELECT *\nFROM \(name)\nFETCH FIRST \(limit) ROWS ONLY;"
        default: return "SELECT *\nFROM \(name)\nLIMIT \(limit);"
        }
    }

    /// Open as PHP on Laravel: the query builder for the table, on the tab's connection.
    public static func laravelQuery(table: String, connection: String?, limit: Int = 50) -> String {
        let base = connection.map { "DB::connection(\(phpString($0)))->table(\(phpString(table)))" } ?? "DB::table(\(phpString(table)))"
        return base + "->limit(\(limit))->get();"
    }

    /// Whether a framework has the `DB` facade for Open as PHP.
    public static func hasQueryBuilder(framework: String?) -> Bool {
        ["laravel", "lumen", "laravel-zero"].contains(framework ?? "")
    }

    /// "varchar · NOT NULL · default 'pending' · → customers.id"
    public static func details(of column: SQLSchemaInfo.Column) -> String {
        var parts: [String] = []
        if let type = column.type { parts.append(type) }
        if column.primaryKey == true { parts.append("primary key") }
        if column.nullable == false, column.primaryKey != true { parts.append("NOT NULL") }
        if let value = column.defaultValue { parts.append("default \(value)") }
        if let references = column.references { parts.append("→ \(references)") }
        return parts.joined(separator: " · ")
    }

    /// "~1.2K rows" style estimate, or nil when the database has none.
    public static func rowsText(_ table: SQLSchemaInfo.Table) -> String? {
        guard let rows = table.rows else { return nil }
        let formatted = rows < 10_000 ? rows.formatted() : rows.formatted(.number.notation(.compactName))
        return "~\(formatted) row\(rows == 1 ? "" : "s")"
    }

    /// "UNIQUE (email)", "PRIMARY (order_id, name)", "(status, customer_id)"
    public static func details(of index: SQLSchemaInfo.Index) -> String {
        let kind = index.primary == true ? "PRIMARY " : index.unique == true ? "UNIQUE " : ""
        return kind + "(" + index.columns.joined(separator: ", ") + ")"
    }

    /// A PHP single-quoted string.
    static func phpString(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }
}
