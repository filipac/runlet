import Foundation

// MARK: - CSV text (#152)

/// RFC 4180 CSV, shared by Copy/Export CSV of a result (`ValueTable.csv`), Export Query to CSV,
/// and Import CSV (#152).
public enum CSVText {
    /// A field as CSV writes it: quoted (with quotes doubled) when it holds the delimiter, a
    /// quote, CR, or LF.
    public static func field(_ text: String, delimiter: Character = ",") -> String {
        guard text.contains(where: { $0 == delimiter || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// One record of a CSV text: its fields and the line it starts on (1-based; a quoted field
    /// can span lines).
    public struct Record: Sendable, Equatable {
        public var fields: [String]
        public var line: Int

        public init(fields: [String], line: Int) {
            self.fields = fields
            self.line = line
        }
    }

    /// The records of `text`, RFC 4180: fields split at `delimiter`, `"…"` quoting with `""`
    /// for a quote, CRLF, LF, or CR line ends, line breaks inside quotes kept. A byte-order mark
    /// is dropped; blank lines are skipped. Stops after `limit` records (the next one, when
    /// there is one, is left out and `more` says so).
    public static func records(in text: String, delimiter: Character, limit: Int = .max) -> (records: [Record], more: Bool) {
        var records: [Record] = []
        var fields: [String] = []
        var field = ""
        var quoted = false
        var fieldStarted = false
        var line = 1
        var recordLine = 1
        var characters = text.makeIterator()
        var pending: Character? = nil
        if text.first == "\u{FEFF}" { _ = characters.next() }

        func endRecord() -> Bool {
            fields.append(field)
            field = ""
            fieldStarted = false
            if !(fields.count == 1 && fields[0].isEmpty) {
                if records.count >= limit { return false }
                records.append(Record(fields: fields, line: recordLine))
            }
            fields = []
            return true
        }

        while let character = pending ?? characters.next() {
            pending = nil
            if quoted {
                if character == "\"" {
                    if let next = characters.next() {
                        if next == "\"" {
                            field.append("\"")
                        } else {
                            quoted = false
                            pending = next
                        }
                    } else {
                        quoted = false
                    }
                } else {
                    if character == "\n" || character == "\r\n" || character == "\r" { line += 1 }
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where !fieldStarted:
                quoted = true
                fieldStarted = true
            case delimiter:
                fields.append(field)
                field = ""
                fieldStarted = false
            case "\n", "\r\n", "\r":
                if !endRecord() { return (records, true) }
                line += 1
                recordLine = line
            default:
                field.append(character)
                fieldStarted = true
            }
        }
        if !field.isEmpty || !fields.isEmpty || fieldStarted {
            if !endRecord() { return (records, true) }
        }
        return (records, false)
    }

    /// The delimiter a CSV text most likely uses: of comma, semicolon, tab, and `|`, the one
    /// that splits its first lines into the same number of fields (more than one), the most
    /// fields winning ties. Comma when none does.
    public static func detectDelimiter(in text: String) -> Character {
        let sample = String(text.prefix(64 * 1024))
        var best: (delimiter: Character, fields: Int, consistent: Bool) = (",", 1, false)
        for delimiter in [",", ";", "\t", "|"] as [Character] {
            let lines = records(in: sample, delimiter: delimiter, limit: 20).records
            guard let first = lines.first?.fields.count, first > 1 else { continue }
            // The last sampled record may be cut by the sample's end.
            let checked = lines.count > 2 ? lines.dropLast() : lines[...]
            let consistent = checked.allSatisfy { $0.fields.count == first }
            if (consistent && !best.consistent) || (consistent == best.consistent && first > best.fields) {
                best = (delimiter, first, consistent)
            }
        }
        return best.delimiter
    }
}

// MARK: - Export Query to CSV (#152)

/// Export Query to CSV's options (#152), chosen in its sheet.
public struct SQLCSVExportOptions: Sendable, Equatable, Codable {
    public enum Delimiter: String, Sendable, Codable, CaseIterable {
        case comma, semicolon, tab

        public var character: Character {
            switch self {
            case .comma: ","
            case .semicolon: ";"
            case .tab: "\t"
            }
        }

        public var title: String {
            switch self {
            case .comma: "Comma (,)"
            case .semicolon: "Semicolon (;)"
            case .tab: "Tab"
            }
        }
    }

    /// How NULL is written: an empty field, or `\N` (MySQL's `LOAD DATA`, PostgreSQL's `COPY`).
    public enum NullStyle: String, Sendable, Codable, CaseIterable {
        case empty, backslashN

        public var text: String { self == .empty ? "" : "\\N" }
        public var title: String { self == .empty ? "Empty field" : "\\N" }
    }

    public var delimiter: Delimiter
    /// A first line with the column names.
    public var header: Bool
    public var null: NullStyle

    public init(delimiter: Delimiter = .comma, header: Bool = true, null: NullStyle = .empty) {
        self.delimiter = delimiter
        self.header = header
        self.null = null
    }
}

/// One frame of Export Query to CSV (#152, the runner's `sqlExport` event): first the columns,
/// then rows in frames of at most 1,000 rows (and about 256 KB of cells), then `done`. Cells
/// are whole values: no text is shortened, and bytes that aren't UTF-8 come as hex.
public struct SQLExportFrame: Sendable, Codable, Equatable {
    public var columns: [String]?
    public var rows: [[SQLCell]]?
    /// Rows sent so far, this frame's included.
    public var total: Int?
    /// The last frame: every row was sent.
    public var done: Bool?
    public var driver: String?
    public var elapsedMs: Double?
    /// The statement's cell bytes in this frame, as the runner counted them.
    public var bytes: Int?

    public init(columns: [String]? = nil, rows: [[SQLCell]]? = nil, total: Int? = nil, done: Bool? = nil, driver: String? = nil, elapsedMs: Double? = nil, bytes: Int? = nil) {
        self.columns = columns
        self.rows = rows
        self.total = total
        self.done = done
        self.driver = driver
        self.elapsedMs = elapsedMs
        self.bytes = bytes
    }
}

public enum SQLCSVExport {
    /// A value as the result shows it, except NULL (the sheet's choice) and binary (all of its
    /// bytes, as `0x` and upper-case hex).
    public static func text(_ cell: SQLCell, options: SQLCSVExportOptions) -> String {
        switch cell {
        case .null: options.null.text
        case .binary(_, let hex): "0x" + hex
        case .clipped(let text, _): text
        default: cell.text
        }
    }

    /// One CSV line (with its CRLF). A text cell that reads like the NULL marker is quoted, so
    /// `\N` stays apart from NULL.
    public static func line(_ cells: [SQLCell], options: SQLCSVExportOptions) -> String {
        let delimiter = options.delimiter.character
        return cells.map { cell in
            let text = text(cell, options: options)
            if cell != .null, options.null == .backslashN, text == "\\N" { return "\"\\N\"" }
            if cell != .null, options.null == .empty, text.isEmpty { return "\"\"" }
            return CSVText.field(text, delimiter: delimiter)
        }.joined(separator: String(delimiter)) + "\r\n"
    }

    public static func header(_ columns: [String], options: SQLCSVExportOptions) -> String {
        columns.map { CSVText.field($0, delimiter: options.delimiter.character) }.joined(separator: String(options.delimiter.character)) + "\r\n"
    }

    /// Export Query to CSV: every row of `statement` on the tab's connection, streamed as
    /// `sqlExport` frames. `bindings` are the statement's bound values (#145).
    public static func code(statement: String, connection: String?, bindings: [SQLBinding] = []) -> String {
        """
        <?php
        // Runlet SQL tab (#152): every row of a read statement, streamed for Export Query to CSV.
        return \\RunletRunner\\SqlCsv::export(\(QueryExplain.phpString(statement)), \(connection.map(QueryExplain.phpString) ?? "null"), \(SQLTabRun.phpBindings(bindings)));
        """
    }

    /// Why a statement can't be exported, or nil: Load Next's rules (#146), a plain read that
    /// is a query (`SELECT`, `WITH`, `TABLE`, `VALUES`) and doesn't lock rows.
    public static func refusal(of statement: String) -> String? {
        switch SQLPaging.plan(for: statement, driver: nil) {
        case .success: return nil
        case .failure(let refusal):
            switch refusal {
            case .writes(let keyword): return "Export Query to CSV runs read statements only. This one can change data (\(keyword)), so Runlet won't run it for an export."
            case .unclassified(let keyword): return "Export Query to CSV runs statements Runlet can tell are reads" + (keyword.isEmpty ? "." : ", and this one starts with \(keyword).")
            case .locking(let clause): return "This statement locks the rows it reads (\(clause)), so Runlet won't run it for an export."
            case .notAQuery(let keyword): return "Export Query to CSV exports SELECT, WITH, TABLE, and VALUES statements, not \(keyword)."
            case .script, .resultSets: return refusal.message
            }
        }
    }

    /// A file name for the save panel: the tab's title, or "query".
    public static func suggestedFileName(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "query" : cleaned) + ".csv"
    }
}

/// Writes Export Query to CSV's frames to a file (#152) as they arrive: into a hidden file next
/// to the destination, moved over it when the export is complete. Stop or an error deletes it,
/// so the destination never holds a partial export (and a file it replaces stays until then).
/// Only one frame is held at a time.
public final class SQLCSVExportWriter {
    public let destination: URL
    public let options: SQLCSVExportOptions
    /// The partial file while the export runs.
    public let partial: URL
    public private(set) var rows = 0
    /// Bytes written to the file.
    public private(set) var bytes = 0
    public private(set) var columns: [String]?
    /// The largest frame's rows, for the export's tests (#152: memory stays bounded).
    public private(set) var largestFrame = 0
    private var handle: FileHandle?

    public init(destination: URL, options: SQLCSVExportOptions) throws {
        self.destination = destination
        self.options = options
        partial = Self.partialURL(for: destination)
        try? FileManager.default.removeItem(at: partial)
        guard FileManager.default.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o644]) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: partial.path])
        }
        handle = try FileHandle(forWritingTo: partial)
    }

    /// `.orders.csv.runlet-export` in the destination's folder.
    public static func partialURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent("." + destination.lastPathComponent + ".runlet-export")
    }

    public func write(_ frame: SQLExportFrame) throws {
        var text = ""
        if let columns = frame.columns, self.columns == nil {
            self.columns = columns
            if options.header { text += SQLCSVExport.header(columns, options: options) }
        }
        if let frameRows = frame.rows {
            largestFrame = max(largestFrame, frameRows.count)
            for row in frameRows { text += SQLCSVExport.line(row, options: options) }
            rows += frameRows.count
        }
        guard !text.isEmpty, let handle else { return }
        let data = Data(text.utf8)
        try handle.write(contentsOf: data)
        bytes += data.count
    }

    /// Closes the file and moves it to the destination, replacing a file there.
    public func finish() throws {
        try handle?.close()
        handle = nil
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: destination)
        }
    }

    /// Stop or an error: the partial file is deleted.
    public func abandon() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: partial)
    }
}

// MARK: - Import CSV (#152)

/// Import CSV (#152): a CSV file parsed on this Mac, mapped onto an existing table's columns,
/// and sent to the runner in batches of bound values for one transaction.
public struct SQLCSVImport: Sendable, Equatable {
    /// Files larger than this are refused before they're read. The rows travel in the run's
    /// request on stdin, which the runner holds several times over while it decodes it (an 8 MiB
    /// file peaks at about 65 MiB, measured): that keeps an import under PHP's default 128 MiB
    /// memory_limit, after an application booted too.
    public static let maxFileBytes = 8 * 1024 * 1024
    /// Data rows imported at most.
    public static let maxRows = 100_000
    /// Rows per batch sent to the runner.
    public static let batchRows = 1_000

    /// Why a file can't be imported.
    public enum Problem: Error, Sendable, Equatable, CustomStringConvertible {
        case tooLarge(bytes: Int)
        case tooManyRows
        case notText
        case empty

        public var description: String {
            switch self {
            case .tooLarge(let bytes):
                "The file is \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)). Import CSV reads files up to \(ByteCountFormatter.string(fromByteCount: Int64(SQLCSVImport.maxFileBytes), countStyle: .file)); split it, or load it with the database's own tool (LOAD DATA, COPY)."
            case .tooManyRows:
                "The file has more than \(SQLCSVImport.maxRows.formatted()) rows. Import CSV imports at most \(SQLCSVImport.maxRows.formatted()) rows at a time; split it, or load it with the database's own tool (LOAD DATA, COPY)."
            case .notText:
                "The file isn't UTF-8 text. Save it as UTF-8 CSV and try again."
            case .empty:
                "The file has no rows."
            }
        }
    }

    /// The file's records, as read.
    public var records: [CSVText.Record]
    public var delimiter: Character
    /// The first record holds column names.
    public var hasHeader: Bool
    /// The table, as SQL names it in this connection.
    public var table: String
    /// The table's columns (from the schema).
    public var tableColumns: [SQLSchemaInfo.Column]
    /// For each table column, the CSV column it takes (nil: not imported, so its default applies).
    public var mapping: [Int?]
    /// Empty fields are imported as NULL rather than empty text.
    public var emptyIsNull: Bool
    /// The connection's PDO driver, for quoting names.
    public var driver: String?

    public init(records: [CSVText.Record], delimiter: Character, hasHeader: Bool, table: String, tableColumns: [SQLSchemaInfo.Column], mapping: [Int?]? = nil, emptyIsNull: Bool = true, driver: String?) {
        self.records = records
        self.delimiter = delimiter
        self.hasHeader = hasHeader
        self.table = table
        self.tableColumns = tableColumns
        self.emptyIsNull = emptyIsNull
        self.driver = driver
        self.mapping = []
        self.mapping = mapping ?? autoMapping()
    }

    /// Reads and parses a file: refused past the size limit, or when it isn't UTF-8.
    public static func read(_ url: URL, table: String, tableColumns: [SQLSchemaInfo.Column], driver: String?) throws -> SQLCSVImport {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > maxFileBytes { throw Problem.tooLarge(bytes: size) }
        let data = try Data(contentsOf: url)
        if data.count > maxFileBytes { throw Problem.tooLarge(bytes: data.count) }
        guard let text = String(data: data, encoding: .utf8) else { throw Problem.notText }
        return try parse(text, table: table, tableColumns: tableColumns, driver: driver)
    }

    /// Parses CSV text: the delimiter and header are detected.
    public static func parse(_ text: String, delimiter: Character? = nil, table: String, tableColumns: [SQLSchemaInfo.Column], driver: String?) throws -> SQLCSVImport {
        let delimiter = delimiter ?? CSVText.detectDelimiter(in: text)
        let (records, more) = CSVText.records(in: text, delimiter: delimiter, limit: maxRows + 1)
        guard !records.isEmpty else { throw Problem.empty }
        if more || records.count > maxRows + 1 { throw Problem.tooManyRows }
        let header = looksLikeHeader(records, tableColumns: tableColumns)
        if !header, records.count > maxRows { throw Problem.tooManyRows }
        return SQLCSVImport(records: records, delimiter: delimiter, hasHeader: header, table: table, tableColumns: tableColumns, driver: driver)
    }

    /// A first record whose fields name table columns, or that is all text over records with
    /// numbers, is a header.
    static func looksLikeHeader(_ records: [CSVText.Record], tableColumns: [SQLSchemaInfo.Column]) -> Bool {
        guard let first = records.first?.fields else { return false }
        let names = Set(tableColumns.map { normalized($0.name) })
        if first.contains(where: { names.contains(normalized($0)) }) { return true }
        guard records.count > 1 else { return false }
        let numeric: (String) -> Bool = { Double($0.trimmingCharacters(in: .whitespaces)) != nil }
        return !first.contains(where: numeric) && records[1].fields.contains(where: numeric)
    }

    static func normalized(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The CSV's column names: the header's, or "Column 1", "Column 2", ….
    public var csvColumns: [String] {
        let width = records.map(\.fields.count).max() ?? 0
        let names = hasHeader ? records.first?.fields ?? [] : []
        return (0..<width).map { index in
            index < names.count && !names[index].trimmingCharacters(in: .whitespaces).isEmpty ? names[index] : "Column \(index + 1)"
        }
    }

    /// Each table column takes the CSV column of the same name (ignoring case, spaces, and
    /// punctuation); without a header, the CSV's columns in order.
    public func autoMapping() -> [Int?] {
        let csv = csvColumns
        if hasHeader {
            let keys = csv.map(Self.normalized)
            return tableColumns.map { column in keys.firstIndex(of: Self.normalized(column.name)) }
        }
        return tableColumns.indices.map { $0 < csv.count ? $0 : nil }
    }

    /// The data records (the header left out).
    public var dataRecords: ArraySlice<CSVText.Record> { hasHeader ? records.dropFirst() : records[...] }

    public var rowCount: Int { dataRecords.count }

    /// The mapped columns, in the table's order.
    public var importedColumns: [(column: SQLSchemaInfo.Column, csvIndex: Int)] {
        zip(tableColumns, mapping).compactMap { column, index in index.map { (column, $0) } }
    }

    /// Why the import can't start, or nil.
    public var problem: String? {
        if importedColumns.isEmpty { return "Choose the CSV column for at least one of the table's columns." }
        if rowCount == 0 { return "The file has no rows to import" + (hasHeader ? " after its header." : ".") }
        if rowCount > Self.maxRows { return Problem.tooManyRows.description }
        return nil
    }

    /// One record's bound values, in `importedColumns`' order: a missing field is NULL, and an
    /// empty one too with `emptyIsNull`.
    public func values(_ record: CSVText.Record) -> [String?] {
        importedColumns.map { _, index in
            guard index < record.fields.count else { return nil }
            let field = record.fields[index]
            return emptyIsNull && field.isEmpty ? nil : field
        }
    }

    /// `INSERT INTO "orders" ("id", "name") VALUES`
    public var insertPrefix: String {
        "INSERT INTO \(SQLSchemaExplorer.quoted(table, driver: driver)) (\(importedColumns.map { Self.quotedColumn($0.column.name, driver: driver) }.joined(separator: ", "))) VALUES"
    }

    /// `(?, ?)`: one row's placeholders.
    public var rowPlaceholders: String {
        "(" + Array(repeating: "?", count: importedColumns.count).joined(separator: ", ") + ")"
    }

    /// The statement the preview shows: one row's INSERT. The runner sends several rows'
    /// placeholders in one statement, with the same columns.
    public var insertStatement: String { insertPrefix + " " + rowPlaceholders }

    /// A column name, quoted when it must be (as the schema explorer quotes names).
    static func quotedColumn(_ name: String, driver: String?) -> String {
        SQLCompletion.identifier(name, quote: driver == "mysql" ? "`" : "\"", pgsql: driver == "pgsql")
    }

    /// Where the import starts and how much it carries, for Run History (never the data):
    /// `-- Import CSV: 1,234 rows from orders.csv into orders, in one transaction`.
    public func historyCode(fileName: String) -> String {
        "-- Import CSV: \(rowCount.formatted()) row\(rowCount == 1 ? "" : "s") from \(fileName) into \(table), in one transaction\n\(insertStatement);"
    }

    /// The batches of bound values the runner gets, as JSON arrays of rows (`null` for NULL).
    public func batches(size: Int = SQLCSVImport.batchRows) -> [String] {
        let data = Array(dataRecords)
        return stride(from: 0, to: data.count, by: max(1, size)).map { start in
            let rows = data[start..<min(data.count, start + max(1, size))].map(values)
            let json = (try? JSONSerialization.data(withJSONObject: rows.map { $0.map { $0 as Any? ?? NSNull() } }, options: [])) ?? Data("[]".utf8)
            return String(decoding: json, as: UTF8.self)
        }
    }

    /// The line of data row `row` (1-based), for an error the runner reports.
    public func line(ofRow row: Int) -> Int? {
        let data = dataRecords
        guard row >= 1, row <= data.count else { return nil }
        return data[data.startIndex + row - 1].line
    }

    /// Import CSV's PHP: the INSERT's parts. The rows go in the run's request beside it
    /// (`RunRequest.sqlBatches`, from `batches()`), as data the snippet compiler never parses.
    /// The runner inserts every row in one transaction and rolls it back at the first error.
    public func code(connection: String?) -> String {
        """
        <?php
        // Runlet SQL tab (#152): Import CSV, every row in one transaction; the rows come with the request.
        return \\RunletRunner\\SqlCsv::import(\(QueryExplain.phpString(insertPrefix)), \(QueryExplain.phpString(rowPlaceholders)), \(importedColumns.count), \(connection.map(QueryExplain.phpString) ?? "null"));
        """
    }

    /// The first rows as the import binds them, for the preview.
    public func preview(rows: Int = 5) -> [[String?]] {
        dataRecords.prefix(rows).map(values)
    }
}

/// Import CSV's progress and outcome (#152, the runner's `sqlImport` event).
public struct SQLImportReport: Sendable, Codable, Equatable {
    /// Rows inserted so far (in the transaction, which a failure rolls back).
    public var inserted: Int
    /// Every row was inserted and the transaction committed.
    public var done: Bool?
    /// The import failed: the data row (1-based) that failed, when known.
    public var failedRow: Int?
    /// The database's message.
    public var message: String?
    /// The transaction was rolled back (on a failure).
    public var rolledBack: Bool?
    public var elapsedMs: Double?
    public var driver: String?

    public init(inserted: Int, done: Bool? = nil, failedRow: Int? = nil, message: String? = nil, rolledBack: Bool? = nil, elapsedMs: Double? = nil, driver: String? = nil) {
        self.inserted = inserted
        self.done = done
        self.failedRow = failedRow
        self.message = message
        self.rolledBack = rolledBack
        self.elapsedMs = elapsedMs
        self.driver = driver
    }
}
