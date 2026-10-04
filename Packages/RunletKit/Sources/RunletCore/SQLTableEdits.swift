import Foundation

/// Browse Table's row edits (#151): changed cells, added rows, and deleted rows, pending in the
/// result window until the user reviews them as SQL and applies them. Nothing here runs.
///
/// Rules:
/// - Only a table (never a view) with a primary key, on a connection that isn't read-only
///   (#139) and binds values (a PDO, not a callable), can be edited.
/// - Each change becomes one statement: `UPDATE … SET … WHERE <primary key> = ?`, `INSERT`, or
///   `DELETE … WHERE <primary key> = ?`, with every value bound and every name quoted
///   (`SQLTableBrowse.Dialect.quote`). Values are typed by the column (`ColumnKind.value`);
///   NULL is explicit and refused for NOT NULL columns.
/// - The optimistic check: an UPDATE's WHERE also holds the original value of each column it
///   changes (`IS NULL` for NULL) when the column's type reads back exactly
///   (`ColumnKind.comparesExactly`), so a row someone else changed in the meantime isn't found
///   and Apply rolls back. A DELETE finds its row by the primary key only.
/// - Apply runs the statements in one transaction, deletions first, then updates, then
///   insertions; each must affect exactly one row (`SqlTable::apply` in the runner).
public enum SQLTableEdits {
    // MARK: Who can edit

    /// Why a table's rows can't be edited; Browse Table shows them read-only then.
    public enum Refusal: Sendable, Equatable, CustomStringConvertible {
        case view
        case noPrimaryKey
        /// A read-only saved connection (#139), by name.
        case readOnlyConnection(String)
        /// A callable connection (WordPress's `$wpdb`, a driver's callable), by its source.
        case callable(String)
        /// A database Browse Table doesn't write SQL for.
        case unknownDialect(String?)
        /// The primary key is past the columns a page reads.
        case primaryKeyNotRead
        /// A primary key column holds binary values, which Runlet doesn't bind.
        case binaryPrimaryKey(String)

        public var description: String {
            switch self {
            case .view: "This is a view: Browse Table edits tables only."
            case .noPrimaryKey: "This table has no primary key, so Runlet can't tell one row from another. Browse Table edits only tables with a primary key."
            case .readOnlyConnection(let name): "The saved connection “\(name)” is read-only: Browse Table never edits through it."
            case .callable(let source): "This connection (\(source)) runs statements through a callable, which can't bind values. Runlet never writes values into the SQL, so it shows the rows read-only."
            case .unknownDialect(let driver): "Runlet doesn't write SQL for \(driver ?? "this") connections, so it shows the rows read-only."
            case .primaryKeyNotRead: "The primary key isn't among the first \(SQLTableBrowse.maxColumns) columns a page reads, so Runlet can't find the rows to change."
            case .binaryPrimaryKey(let column): "The primary key column \(column) holds binary values, which Runlet doesn't bind, so it shows the rows read-only."
            }
        }
    }

    /// Why the table can't be edited, or nil when it can.
    /// - Parameters:
    ///   - driver: the schema's PDO driver; nil for a callable connection.
    ///   - source: where the connection comes from (`SQLSchemaInfo.source`).
    ///   - readOnlyConnection: the saved connection's name when it is read-only (#139).
    public static func refusal(table: SQLSchemaInfo.Table, driver: String?, source: String?, readOnlyConnection: String?) -> Refusal? {
        if table.isView { return .view }
        if let readOnlyConnection { return .readOnlyConnection(readOnlyConnection) }
        if driver == nil { return .callable(source ?? "a driver's callable") }
        guard let dialect = SQLTableBrowse.Dialect(driver: driver) else { return .unknownDialect(driver) }
        let key = table.columns.filter { $0.primaryKey == true }
        guard !key.isEmpty else { return .noPrimaryKey }
        let read = Set(table.columns.prefix(SQLTableBrowse.maxColumns).map(\.name))
        guard key.allSatisfy({ read.contains($0.name) }) else { return .primaryKeyNotRead }
        if let binary = key.first(where: { SQLTableBrowse.ColumnKind(type: $0.type, dialect: dialect) == .binary }) { return .binaryPrimaryKey(binary.name) }
        return nil
    }

    // MARK: Pending changes

    /// A value typed in Browse Table: text (typed by its column when applied), or NULL.
    public enum Value: Sendable, Hashable {
        case null
        case text(String)

        /// "NULL", or the text.
        public var text: String {
            switch self {
            case .null: "NULL"
            case .text(let text): text
            }
        }
    }

    /// The changes pending in a Browse Table window. Rows are indices into the page's rows;
    /// columns are indices into the page's columns.
    public struct Changes: Sendable, Equatable {
        /// Changed cells of existing rows.
        public private(set) var cells: [Int: [Int: Value]] = [:]
        public private(set) var deletedRows: Set<Int> = []
        /// Added rows: the values given; the other columns take their defaults.
        public private(set) var newRows: [[Int: Value]] = []

        public init() {}

        public var isEmpty: Bool { cells.isEmpty && deletedRows.isEmpty && newRows.isEmpty }

        /// Statements Apply would run.
        public var count: Int { deletedRows.count + cells.keys.filter { !deletedRows.contains($0) }.count + newRows.count }

        /// "2 changed rows, 1 new, 1 deleted"
        public var summary: String {
            let changed = cells.keys.filter { !deletedRows.contains($0) }.count
            var parts: [String] = []
            if changed > 0 { parts.append("\(changed) changed row\(changed == 1 ? "" : "s")") }
            if !newRows.isEmpty { parts.append("\(newRows.count) new") }
            if !deletedRows.isEmpty { parts.append("\(deletedRows.count) deleted") }
            return parts.isEmpty ? "No changes" : parts.joined(separator: ", ")
        }

        /// The value pending for a cell of an existing row, if it changed.
        public func value(row: Int, column: Int) -> Value? { cells[row]?[column] }

        /// Sets a cell of an existing row; setting it back to what the page read drops the change.
        public mutating func set(row: Int, column: Int, to value: Value, original: SQLCell) {
            var rowCells = cells[row] ?? [:]
            if Self.same(value, original) {
                rowCells[column] = nil
            } else {
                rowCells[column] = value
            }
            cells[row] = rowCells.isEmpty ? nil : rowCells
        }

        public mutating func revert(row: Int, column: Int) {
            cells[row]?[column] = nil
            if cells[row]?.isEmpty == true { cells[row] = nil }
        }

        /// Marks rows for deletion (their changed cells go).
        public mutating func delete(rows: some Sequence<Int>) {
            for row in rows {
                deletedRows.insert(row)
                cells[row] = nil
            }
        }

        public mutating func restore(row: Int) {
            deletedRows.remove(row)
        }

        /// Adds an empty row and returns its index in `newRows`.
        @discardableResult
        public mutating func addRow() -> Int {
            newRows.append([:])
            return newRows.count - 1
        }

        /// Sets (or, with nil, clears back to the column's default) a cell of an added row.
        public mutating func setNew(row: Int, column: Int, to value: Value?) {
            guard newRows.indices.contains(row) else { return }
            newRows[row][column] = value
        }

        public mutating func removeNewRow(_ row: Int) {
            guard newRows.indices.contains(row) else { return }
            newRows.remove(at: row)
        }

        /// The value is what the cell already holds.
        static func same(_ value: Value, _ original: SQLCell) -> Bool {
            switch (value, original) {
            case (.null, .null): true
            case (.text(let text), .string(let string)): text == string
            case (.text(let text), .int(let int)): text.trimmingCharacters(in: .whitespaces) == String(int)
            case (.text(let text), .bool(let bool)): text.trimmingCharacters(in: .whitespaces).lowercased() == (bool ? "true" : "false")
            case (.text(let text), .double): text == original.text
            default: false
            }
        }
    }

    /// Why a cell can't be edited: a value Runlet didn't read in full (text over 8 KB, binary).
    public static func cellProblem(_ cell: SQLCell, column: SQLSchemaInfo.Column, dialect: SQLTableBrowse.Dialect) -> String? {
        if SQLTableBrowse.ColumnKind(type: column.type, dialect: dialect) == .binary { return "\(column.name) holds binary values, which Runlet doesn't edit." }
        switch cell {
        case .clipped: return "This value is longer than Runlet reads (8 KB), so it can't be edited here. Change it with an UPDATE in an SQL tab."
        case .binary: return "This value isn't text, so Runlet doesn't edit it."
        default: return nil
        }
    }

    /// Why a typed value can't go into a column, or nil when it can.
    public static func valueProblem(_ value: Value, column: SQLSchemaInfo.Column, dialect: SQLTableBrowse.Dialect) -> String? {
        let kind = SQLTableBrowse.ColumnKind(type: column.type, dialect: dialect)
        switch value {
        case .null:
            return column.nullable == false ? "\(column.name) is NOT NULL, so it can't be set to NULL." : nil
        case .text(let text):
            return kind.value(text) == nil ? "\(kind.problem(text)): \(column.name) is a\(kind == .integer ? "n" : "") \(kind.displayName) column." : nil
        }
    }

    // MARK: Statements

    /// One statement of Apply.
    public struct Statement: Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable {
            case update, insert, delete
        }

        public var kind: Kind
        public var sql: String
        /// `?` values, in order.
        public var bindings: [SQLBinding]
        /// MySQL and MariaDB count only the rows an UPDATE changed: when it reports none, the
        /// runner counts the rows of the same WHERE to tell an unchanged row from a missing one.
        public var verifySQL: String?
        public var verifyBindings: [SQLBinding]
        /// "row 3 · id = 7", "new row 1"
        public var label: String

        /// "-- ?1 = 'Ada', ?2 = 7": the values, as Review Changes, the production confirmation,
        /// and Run History show them.
        public var valuesLine: String? {
            bindings.isEmpty ? nil : "-- " + bindings.enumerated().map { "?\($0.offset + 1) = \($0.element.value.display(limit: 200))" }.joined(separator: ", ")
        }

        /// The SQL and its values.
        public var display: String { valuesLine.map { sql + "\n" + $0 } ?? sql }
    }

    /// Why the changes can't become statements (a value that doesn't fit, a row Runlet can't find).
    public struct Problem: Error, Sendable, Equatable, CustomStringConvertible {
        public var description: String

        public init(_ description: String) {
            self.description = description
        }
    }

    /// Apply's statements for `changes` on the page `rows` of `columns` (the page's columns, in
    /// order; `table`'s primary key among them): deletions, then updates, then insertions.
    /// `offset` is the page's first row, for labels.
    public static func statements(_ changes: Changes, table: String, columns: [SQLSchemaInfo.Column], rows: [[SQLCell]], dialect: SQLTableBrowse.Dialect, offset: Int = 0) -> Result<[Statement], Problem> {
        let key = columns.indices.filter { columns[$0].primaryKey == true }
        guard !key.isEmpty else { return .failure(Problem(Refusal.noPrimaryKey.description)) }
        let name = dialect.table(table)
        var statements: [Statement] = []

        /// The row's WHERE: its primary key, and `checked` columns' original values.
        func whereClause(_ row: Int, checked: [Int] = []) -> Result<(sql: String, bindings: [SQLParameterValue], label: String), Problem> {
            guard rows.indices.contains(row) else { return .failure(Problem("Row \(offset + row + 1) isn't on the page any more. Reload the page.")) }
            var conditions: [String] = []
            var values: [SQLParameterValue] = []
            var keyText: [String] = []
            for column in key + checked.filter({ !key.contains($0) }) {
                let cell = column < rows[row].count ? rows[row][column] : .null
                let kind = SQLTableBrowse.ColumnKind(type: columns[column].type, dialect: dialect)
                let quoted = dialect.quote(columns[column].name)
                if cell == .null {
                    if key.contains(column) { return .failure(Problem("Row \(offset + row + 1) has no value for its primary key column \(columns[column].name), so Runlet can't find it.")) }
                    conditions.append("\(quoted) IS NULL")
                    continue
                }
                guard let value = original(cell, kind: kind) else {
                    return .failure(Problem("Row \(offset + row + 1)'s \(columns[column].name) isn't a value Runlet read in full, so Runlet can't find the row by it."))
                }
                conditions.append("\(quoted) = ?")
                values.append(value)
                if key.contains(column) { keyText.append("\(columns[column].name) = \(value.display(limit: 40))") }
            }
            return .success((conditions.joined(separator: " AND "), values, "row \(offset + row + 1) · " + keyText.joined(separator: ", ")))
        }

        func positional(_ values: [SQLParameterValue], from start: Int = 0) -> [SQLBinding] {
            values.enumerated().map { SQLBinding(target: .position(start + $0.offset + 1), value: $0.element) }
        }

        func typed(_ value: Value, column: Int, row: String) -> Result<SQLParameterValue, Problem> {
            if let problem = valueProblem(value, column: columns[column], dialect: dialect) { return .failure(Problem("\(row.prefix(1).uppercased() + row.dropFirst()): \(problem)")) }
            switch value {
            case .null: return .success(.null)
            case .text(let text):
                guard let typed = SQLTableBrowse.ColumnKind(type: columns[column].type, dialect: dialect).value(text) else { return .failure(Problem("\(row): \(columns[column].name)")) }
                return .success(typed)
            }
        }

        for row in changes.deletedRows.sorted() {
            switch whereClause(row) {
            case .failure(let problem): return .failure(problem)
            case .success(let found):
                statements.append(Statement(kind: .delete, sql: "DELETE FROM \(name)\nWHERE \(found.sql)", bindings: positional(found.bindings), verifySQL: nil, verifyBindings: [], label: found.label))
            }
        }
        for row in changes.cells.keys.sorted() where !changes.deletedRows.contains(row) {
            guard let changed = changes.cells[row], !changed.isEmpty else { continue }
            let edited = changed.keys.sorted()
            let checked = edited.filter { SQLTableBrowse.ColumnKind(type: columns[$0].type, dialect: dialect).comparesExactly }
            let found: (sql: String, bindings: [SQLParameterValue], label: String)
            switch whereClause(row, checked: checked) {
            case .failure(let problem): return .failure(problem)
            case .success(let value): found = value
            }
            var assignments: [String] = []
            var values: [SQLParameterValue] = []
            for column in edited {
                switch typed(changed[column] ?? .null, column: column, row: found.label) {
                case .failure(let problem): return .failure(problem)
                case .success(let value):
                    assignments.append("\(dialect.quote(columns[column].name)) = ?")
                    values.append(value)
                }
            }
            let verify = dialect == .mysql ? "SELECT COUNT(*) FROM \(name)\nWHERE \(found.sql)" : nil
            statements.append(Statement(kind: .update, sql: "UPDATE \(name)\nSET \(assignments.joined(separator: ", "))\nWHERE \(found.sql)",
                                        bindings: positional(values + found.bindings), verifySQL: verify, verifyBindings: verify == nil ? [] : positional(found.bindings), label: found.label))
        }
        for (index, values) in changes.newRows.enumerated() {
            let label = "new row \(index + 1)"
            var names: [String] = []
            var bound: [SQLParameterValue] = []
            for column in values.keys.sorted() where columns.indices.contains(column) {
                switch typed(values[column] ?? .null, column: column, row: label) {
                case .failure(let problem): return .failure(problem)
                case .success(let value):
                    names.append(dialect.quote(columns[column].name))
                    bound.append(value)
                }
            }
            let sql: String
            if names.isEmpty {
                sql = dialect == .mysql ? "INSERT INTO \(name) () VALUES ()" : "INSERT INTO \(name) DEFAULT VALUES"
            } else {
                sql = "INSERT INTO \(name) (\(names.joined(separator: ", ")))\nVALUES (\(Array(repeating: "?", count: names.count).joined(separator: ", ")))"
            }
            statements.append(Statement(kind: .insert, sql: sql, bindings: positional(bound), verifySQL: nil, verifyBindings: [], label: label))
        }
        return .success(statements)
    }

    /// A cell the page read, as the value that finds it again; nil for values Runlet didn't read
    /// in full (clipped text, binary).
    static func original(_ cell: SQLCell, kind: SQLTableBrowse.ColumnKind) -> SQLParameterValue? {
        switch cell {
        case .null: return .null
        case .bool(let value): return .boolean(value)
        case .int(let value): return kind == .boolean ? .boolean(value != 0) : .integer(Int(value))
        case .double(let value): return .decimal(String(value))
        case .string(let text):
            switch kind {
            case .integer: return kind.value(text) ?? .text(text)
            case .decimal: return .decimal(text)
            case .boolean: return kind.value(text) ?? .text(text)
            default: return .text(text)
            }
        case .clipped, .binary: return nil
        }
    }

    // MARK: What the grid shows

    /// Pending changes as the grid marks them: changed cells, rows to delete, and new rows
    /// (indices into the display table's rows; columns into its columns).
    public struct Marks: Sendable, Equatable {
        public struct Cell: Sendable, Hashable {
            public var row: Int
            public var column: Int

            public init(row: Int, column: Int) {
                self.row = row
                self.column = column
            }
        }

        public var changed: Set<Cell> = []
        public var deleted: Set<Int> = []
        public var added: Set<Int> = []

        public init() {}
    }

    /// The page with its pending changes, for the grid: changed cells show their new values,
    /// rows to delete stay (marked), and new rows follow the page's rows, keyed `+1`, `+2`, with
    /// `DEFAULT` where the column takes its default. Row keys count from `offset + 1`.
    public static func display(columns: [String], rows: [[SQLCell]], offset: Int, changes: Changes) -> (table: ValueTable, marks: Marks) {
        var table = SQLResultInfo.makeTable(columns: columns, rows: rows, firstKey: offset + 1)
        var marks = Marks()
        marks.deleted = Set(changes.deletedRows.filter { $0 < rows.count })
        for (row, cells) in changes.cells where row < table.rows.count {
            for (column, value) in cells where column < table.rows[row].count {
                table.rows[row][column] = cell(value)
                marks.changed.insert(Marks.Cell(row: row, column: column))
            }
        }
        for (index, values) in changes.newRows.enumerated() {
            let row = table.rows.count
            table.rowKeys.append("+\(index + 1)")
            table.rows.append(columns.indices.map { values[$0].map(cell) ?? ValueTable.Cell(text: "DEFAULT", isNull: true) })
            table.rowFields.append([])
            marks.added.insert(row)
        }
        return (table, marks)
    }

    private static func cell(_ value: Value) -> ValueTable.Cell {
        switch value {
        case .null: ValueTable.Cell(text: "NULL", isNull: true)
        case .text(let text): ValueTable.Cell(text: text)
        }
    }

    // MARK: History

    /// What Run History keeps of an Apply (#149): one SQL script, each statement with its
    /// values as `-- @param` lines (#145), so reopening it shows them.
    public static func historyCode(_ statements: [Statement], table: String) -> String {
        var lines = ["-- Browse Table: \(statements.count == 1 ? "1 change" : "\(statements.count) changes") to \(table), applied in one transaction"]
        for statement in statements {
            for (index, binding) in statement.bindings.enumerated() {
                lines.append(SQLParameters.declaration("?\(index + 1)", binding.value))
            }
            lines.append(statement.sql + ";")
        }
        return lines.joined(separator: "\n")
    }
}

extension SQLTabRun {
    /// Apply in Browse Table (#151): the reviewed statements in one transaction
    /// (`SqlTab::applyEdits`), each of which must affect exactly one row. `driver` is the
    /// schema's PDO driver, which the runner checks the connection against.
    public static func applyCode(_ statements: [SQLTableEdits.Statement], connection: String?, driver: String?) -> String {
        let items = statements.enumerated().map { index, statement in
            var item = "    ['kind' => '\(statement.kind.rawValue)', 'sql' => \(QueryExplain.phpString(statement.sql)), 'line' => \(index + 1), 'label' => \(QueryExplain.phpString(statement.label)), 'params' => \(phpBindings(statement.bindings))"
            if let verify = statement.verifySQL {
                item += ", 'verify' => \(QueryExplain.phpString(verify)), 'verifyParams' => \(phpBindings(statement.verifyBindings))"
            }
            return item + "],"
        }
        return """
        <?php
        // Runlet Browse Table (#151): reviewed changes, in one transaction.
        return \\RunletRunner\\SqlTab::applyEdits([
        \(items.joined(separator: "\n"))
        ], \(connection.map(QueryExplain.phpString) ?? "null"), \(driver.map(QueryExplain.phpString) ?? "null"));
        """
    }
}
