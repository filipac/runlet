import Foundation

/// A tabular view of a value: lists of arrays/objects, Laravel collections, and lists of
/// Eloquent models (their `attributes`). Built from the bounded ValueNode tree only.
public struct ValueTable: Sendable, Equatable {
    public var columns: [String]
    /// Row key (array key / index) shown as the first column.
    public var rowKeys: [String]
    public var rows: [[Cell]]
    /// Rows omitted because of runner limits.
    public var omittedRows: Int

    public struct Cell: Sendable, Equatable {
        public var text: String
        /// Numeric value for sorting, when the cell is an int/float.
        public var number: Double?
        public var isNull: Bool
    }

    public static let maxColumns = 40

    /// Returns a table when the value is a non-empty list whose rows are arrays or objects.
    public static func make(from node: ValueNode) -> ValueTable? {
        guard let (entries, omitted) = rowEntries(of: node), !entries.isEmpty else { return nil }
        var columns: [String] = []
        var seen = Set<String>()
        var rowFields: [[String: ValueNode]] = []
        for entry in entries {
            guard let fields = fields(of: entry.value) else { return nil }
            for (key, _) in fields where !seen.contains(key) && columns.count < maxColumns {
                seen.insert(key)
                columns.append(key)
            }
            rowFields.append(Dictionary(fields, uniquingKeysWith: { first, _ in first }))
        }
        guard !columns.isEmpty else { return nil }
        let rows = rowFields.map { fields in
            columns.map { column -> Cell in
                guard let value = fields[column] else { return Cell(text: "", number: nil, isNull: true) }
                return cell(for: value)
            }
        }
        return ValueTable(columns: columns, rowKeys: entries.map(\.key), rows: rows, omittedRows: omitted)
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

    /// The fields of one row in display order.
    static func fields(of node: ValueNode) -> [(String, ValueNode)]? {
        switch node.type {
        case .array:
            return (node.entries ?? []).map { ($0.key, $0.value) }
        case .object:
            let entries = node.entries ?? []
            // Eloquent models: show their attributes.
            if let attributes = entries.first(where: { $0.key == "attributes" && $0.visibility == "protected" })?.value, attributes.type == .array {
                return (attributes.entries ?? []).map { ($0.key, $0.value) }
            }
            if node.repeated == true { return [("#", node)] }
            let visible = entries.filter { $0.visibility == "public" || $0.visibility == nil }
            return (visible.isEmpty ? entries : visible).map { ($0.key, $0.value) }
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
        default: Cell(text: value.inlineSummary, number: nil, isNull: false)
        }
    }

    /// RFC 4180 CSV with a header row.
    public func csv(includeKeys: Bool = false) -> String {
        func escape(_ field: String) -> String {
            if field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
                return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return field
        }
        var lines = [((includeKeys ? ["#"] : []) + columns).map(escape).joined(separator: ",")]
        for (index, row) in rows.enumerated() {
            let values = row.map { $0.isNull && $0.text.isEmpty ? "" : $0.text }
            lines.append(((includeKeys ? [rowKeys[index]] : []) + values).map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}
