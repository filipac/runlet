import Foundation

/// A tabular view of a value: lists of arrays/objects, Laravel collections, and lists of
/// Eloquent models (their `attributes`). Built from the bounded ValueNode tree only.
public struct ValueTable: Sendable, Equatable {
    public var columns: [String]
    /// Row key (array key / index) shown as the first column.
    public var rowKeys: [String]
    public var rows: [[Cell]]
    /// Each row's own fields, in the row's order, for copying a row with its keys and types.
    public var rowFields: [[Field]]
    /// Rows omitted because of runner limits.
    public var omittedRows: Int

    /// One field of a row: its key and its value.
    public struct Field: Sendable, Equatable {
        public var key: String
        /// int | string | property | field
        public var keyType: String
        public var value: ValueNode
    }

    public struct Cell: Sendable, Equatable {
        public var text: String
        /// Numeric value for sorting, when the cell is an int/float.
        public var number: Double?
        public var isNull: Bool

        public init(text: String, number: Double? = nil, isNull: Bool = false) {
            self.text = text
            self.number = number
            self.isNull = isNull
        }
    }

    public static let maxColumns = 40

    /// Returns a table when the value is a non-empty list whose rows are arrays or objects.
    public static func make(from node: ValueNode) -> ValueTable? {
        guard let (entries, omitted) = rowEntries(of: node), !entries.isEmpty else { return nil }
        var columns: [String] = []
        var seen = Set<String>()
        var rowFields: [[String: ValueNode]] = []
        var orderedFields: [[Field]] = []
        for entry in entries {
            guard let fields = fields(of: entry.value) else { return nil }
            for (key, _, _) in fields where !seen.contains(key) && columns.count < maxColumns {
                seen.insert(key)
                columns.append(key)
            }
            rowFields.append(Dictionary(fields.map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first }))
            orderedFields.append(fields.map { Field(key: $0.0, keyType: $0.2, value: $0.1) })
        }
        guard !columns.isEmpty else { return nil }
        let rows = rowFields.map { fields in
            columns.map { column -> Cell in
                guard let value = fields[column] else { return Cell(text: "", number: nil, isNull: true) }
                return cell(for: value)
            }
        }
        return ValueTable(columns: columns, rowKeys: entries.map(\.key), rows: rows, rowFields: orderedFields, omittedRows: omitted)
    }

    /// The list of rows: an array's entries, or a Collection's `items`.
    static func rowEntries(of node: ValueNode) -> ([ValueNode.Entry], Int)? {
        switch node.type {
        case .array:
            return (node.entries ?? [], node.truncation?.omitted ?? 0)
        case .object:
            if let items = node.entries?.first(where: { $0.key == "items" && $0.keyType == "property" })?.value, items.type == .array {
                return (items.entries ?? [], items.truncation?.omitted ?? 0)
            }
            return nil
        default:
            return nil
        }
    }

    /// The fields of one row in display order: key, value, and key type.
    static func fields(of node: ValueNode) -> [(String, ValueNode, String)]? {
        switch node.type {
        case .array:
            return (node.entries ?? []).map { ($0.key, $0.value, $0.keyType) }
        case .object:
            let entries = node.entries ?? []
            // Eloquent models: show their attributes.
            if let attributes = entries.first(where: { $0.key == "attributes" && $0.visibility == "protected" })?.value, attributes.type == .array {
                return (attributes.entries ?? []).map { ($0.key, $0.value, $0.keyType) }
            }
            if node.repeated == true { return [("#", node, "string")] }
            let visible = entries.filter { $0.visibility == "public" || $0.visibility == nil }
            return (visible.isEmpty ? entries : visible).map { ($0.key, $0.value, "string") }
        default:
            return nil
        }
    }

    static func cell(for value: ValueNode) -> Cell {
        switch value.type {
        case .null: Cell(text: "null", number: nil, isNull: true)
        case .int, .float: Cell(text: value.scalar ?? "", number: Double(value.scalar ?? ""), isNull: false)
        case .string: Cell(text: value.displayString, number: nil, isNull: false)
        case .bool: Cell(text: value.scalar ?? "", number: nil, isNull: false)
        // #6: a driver caster's summary line is what the object shows as.
        case .object where value.isCast && value.summary != nil: Cell(text: value.summary ?? "", number: nil, isNull: false)
        default: Cell(text: value.inlineSummary, number: nil, isNull: false)
        }
    }

    /// The header and one row as CSV.
    public func csv(rowAt index: Int) -> String {
        ValueTable(columns: columns, rowKeys: [rowKeys[index]], rows: [rows[index]], rowFields: [rowFields[index]], omittedRows: 0).csv()
    }

    /// RFC 4180 CSV with a header row.
    public func csv(includeKeys: Bool = false) -> String {
        // The same quoting as Export Query to CSV (#152).
        func escape(_ field: String) -> String { CSVText.field(field) }
        var lines = [((includeKeys ? ["#"] : []) + columns).map(escape).joined(separator: ",")]
        for (index, row) in rows.enumerated() {
            let values = row.map { $0.isNull && $0.text.isEmpty ? "" : $0.text }
            lines.append(((includeKeys ? [rowKeys[index]] : []) + values).map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}
