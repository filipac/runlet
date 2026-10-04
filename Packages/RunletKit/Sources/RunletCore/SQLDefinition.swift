import Foundation

/// Show Definition (#148): the definition (DDL) of one table or view, as the runner's
/// `sqlDefinition` event reports it (`Resources/Runner/src/SqlDefinition.php`). The runner only
/// reads the catalog; the schema explorer shows the DDL in a read-only sheet.
public struct SQLDefinitionInfo: Sendable, Codable, Equatable {
    /// The table or view, as the schema explorer named it.
    public var table: String
    /// `table`, `view`, `partitioned table`, `materialized view`, or `foreign table`.
    public var kind: String?
    /// The DDL: one or more statements, each ending in `;`.
    public var sql: String
    /// How it was read: `SHOW CREATE TABLE`, `SHOW CREATE VIEW`, `sqlite_master`, `pg_catalog`.
    public var how: String?
    /// PostgreSQL: rebuilt from the catalog by Runlet, as the database has no SHOW CREATE.
    public var reconstructed: Bool?
    /// What was left out or couldn't be read.
    public var notes: [String]?
    /// The PDO driver (`mysql`, `pgsql`, `sqlite`).
    public var driver: String?
    /// The server and its version, e.g. "MariaDB 11.4.2", when the connection is a PDO.
    public var server: String?
    /// Where the connection came from (`Laravel DB::connection()`, a saved connection, …).
    public var source: String?
    /// The application connection's name (nil: the default), or a saved connection's name.
    public var connection: String?
    public var saved: Bool?
    public var elapsedMs: Double?

    public init(table: String, kind: String? = nil, sql: String, how: String? = nil, reconstructed: Bool? = nil, notes: [String]? = nil, driver: String? = nil, server: String? = nil, source: String? = nil, connection: String? = nil, saved: Bool? = nil, elapsedMs: Double? = nil) {
        self.table = table
        self.kind = kind
        self.sql = sql
        self.how = how
        self.reconstructed = reconstructed
        self.notes = notes
        self.driver = driver
        self.server = server
        self.source = source
        self.connection = connection
        self.saved = saved
        self.elapsedMs = elapsedMs
    }

    public var isView: Bool { kind?.hasSuffix("view") == true }
}

/// Show Definition (#148): the runner code that reads a definition, and the text its sheet shows
/// (and Copy and Open in SQL Tab carry).
public enum SQLDefinition {
    /// The runner code: one table's or view's definition on the tab's connection, nothing
    /// else. A saved connection (#138) comes with the run's request, so `connection` is nil.
    public static func code(table: String, connection: String?) -> String {
        """
        <?php
        // Runlet schema explorer (#148): a table's or view's definition, read from the catalog. Nothing else runs.
        return \\RunletRunner\\SqlTab::definition(\(QueryExplain.phpString(table)), \(connection.map(QueryExplain.phpString) ?? "null"));
        """
    }

    /// "orders (definition)": Open in SQL Tab's title.
    public static func tabTitle(_ table: String) -> String {
        "\(table) (definition)"
    }

    /// The sheet's text: a comment header (what, where from, how, when, and that nothing ran),
    /// then the DDL. `connection` is the explorer's label for it ("the default
    /// connection", "the saved connection “Reporting”").
    public static func document(_ info: SQLDefinitionInfo, connection: String, target: String, readAt: Date, calendar: Calendar = .current) -> String {
        let database = info.server ?? databaseName(info.driver)
        let how = info.how.map { " (\($0))" } ?? ""
        var header = [
            "Definition of \(info.kind ?? "table") \(info.table) from \(database)\(how).",
            "Read \(timestamp(readAt, calendar: calendar)) through \(connection) on \(target).",
        ]
        header += info.notes ?? []
        header.append("Not run: Runlet only read the catalog, and nothing runs until you press Run.")
        let comments = header.flatMap { wrapped($0, width: 100) }.map { "-- " + $0 }
        return comments.joined(separator: "\n") + "\n\n" + info.sql.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// "MySQL or MariaDB", "PostgreSQL", "SQLite", or the driver's name.
    public static func databaseName(_ driver: String?) -> String {
        switch driver {
        case "mysql": "MySQL or MariaDB"
        case "pgsql": "PostgreSQL"
        case "sqlite", "sqlite2": "SQLite"
        case let other?: other
        case nil: "the database"
        }
    }

    /// "2026-10-04 14:03"
    static func timestamp(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
    }

    /// `text` in lines of at most `width` characters, broken at spaces.
    static func wrapped(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            if !line.isEmpty, line.count + 1 + word.count > width {
                lines.append(line)
                line = String(word)
            } else {
                line += line.isEmpty ? String(word) : " " + word
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines.isEmpty ? [""] : lines
    }
}
