import Foundation

/// One filter rule of the result window (#21): a column, an operator, and a value.
public struct ValueTableFilter: Sendable, Equatable, Identifiable {
    public enum Operator: String, Sendable, CaseIterable, Identifiable {
        case contains, doesNotContain, equals, doesNotEqual, lessThan, lessOrEqual, greaterThan, greaterOrEqual, isEmpty, isNotEmpty

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .contains: "contains"
            case .doesNotContain: "doesn't contain"
            case .equals: "="
            case .doesNotEqual: "≠"
            case .lessThan: "<"
            case .lessOrEqual: "≤"
            case .greaterThan: ">"
            case .greaterOrEqual: "≥"
            case .isEmpty: "is empty or NULL"
            case .isNotEmpty: "isn't empty"
            }
        }

        /// The operator needs no value.
        public var isUnary: Bool { self == .isEmpty || self == .isNotEmpty }
    }

    public var id: UUID
    public var column: Int
    public var op: Operator
    public var value: String

    public init(id: UUID = UUID(), column: Int, op: Operator = .contains, value: String = "") {
        self.id = id
        self.column = column
        self.op = op
        self.value = value
    }

    /// Text comparisons ignore case. `=`, `≠`, `<`, `>`, … compare as numbers when the cell
    /// and the value are both numbers, else as text (so ISO dates order correctly). NULL never
    /// equals, contains, or compares; it matches `≠`, "doesn't contain", and "is empty".
    public func matches(_ cell: ValueTable.Cell) -> Bool {
        let empty = cell.isNull || cell.text.isEmpty
        switch op {
        case .isEmpty: return empty
        case .isNotEmpty: return !empty
        default: break
        }
        // An empty value doesn't filter yet (the rule is being typed).
        guard !value.isEmpty else { return true }
        if cell.isNull { return op == .doesNotContain || op == .doesNotEqual }
        let text = cell.text
        switch op {
        case .contains: return text.localizedCaseInsensitiveContains(value)
        case .doesNotContain: return !text.localizedCaseInsensitiveContains(value)
        case .equals: return compare(cell) == .orderedSame
        case .doesNotEqual: return compare(cell) != .orderedSame
        case .lessThan: return compare(cell) == .orderedAscending
        case .lessOrEqual: return compare(cell) != .orderedDescending
        case .greaterThan: return compare(cell) == .orderedDescending
        case .greaterOrEqual: return compare(cell) != .orderedAscending
        case .isEmpty, .isNotEmpty: return true
        }
    }

    /// The cell against the value.
    private func compare(_ cell: ValueTable.Cell) -> ComparisonResult {
        if let number = cell.number ?? Double(cell.text), let wanted = Double(value.trimmingCharacters(in: .whitespaces)) {
            return number < wanted ? .orderedAscending : number > wanted ? .orderedDescending : .orderedSame
        }
        return cell.text.compare(value, options: [.caseInsensitive, .numeric])
    }
}

/// The result window's view of a table (#21): a search across every column, filter rules
/// (all must match), and a sort. It only picks and orders rows; the table is unchanged.
public struct ValueTableQuery: Sendable, Equatable {
    public var search: String
    public var filters: [ValueTableFilter]
    /// A column index; nil keeps the result's own order.
    public var sortColumn: Int?
    public var ascending: Bool

    public init(search: String = "", filters: [ValueTableFilter] = [], sortColumn: Int? = nil, ascending: Bool = true) {
        self.search = search
        self.filters = filters
        self.sortColumn = sortColumn
        self.ascending = ascending
    }

    public var isFiltered: Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty || filters.contains { $0.op.isUnary || !$0.value.isEmpty }
    }

    /// The indices of the rows to show, in order. NULLs sort last either way; equal values keep
    /// the result's order.
    public func rowIndices(in table: ValueTable) -> [Int] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        var indices = table.rows.indices.filter { index in
            let row = table.rows[index]
            if !needle.isEmpty, !row.contains(where: { $0.text.localizedCaseInsensitiveContains(needle) }) { return false }
            return filters.allSatisfy { filter in filter.column < row.count ? filter.matches(row[filter.column]) : true }
        }
        if let column = sortColumn, column >= 0 {
            indices.sort { lhs, rhs in
                let a = column < table.rows[lhs].count ? table.rows[lhs][column] : ValueTable.Cell(text: "", number: nil, isNull: true)
                let b = column < table.rows[rhs].count ? table.rows[rhs][column] : ValueTable.Cell(text: "", number: nil, isNull: true)
                if a.isNull != b.isNull { return b.isNull }
                let order: ComparisonResult
                if let x = a.number, let y = b.number {
                    order = x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
                } else {
                    order = a.text.localizedStandardCompare(b.text)
                }
                if order == .orderedSame { return lhs < rhs }
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
        }
        return indices
    }
}

extension ValueTable {
    /// RFC 4180 CSV of some rows and columns (the result window's filtered rows).
    public func csv(rows indices: [Int], columns visible: [Int]? = nil) -> String {
        let columnIndices = visible ?? Array(columns.indices)
        func escape(_ field: String) -> String {
            field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
        }
        var lines = [columnIndices.map { escape(columns[$0]) }.joined(separator: ",")]
        for index in indices {
            let row = rows[index]
            lines.append(columnIndices.map { $0 < row.count ? escape(row[$0].isNull && row[$0].text.isEmpty ? "" : row[$0].text) : "" }.joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Tab-separated rows (no header) for copying selected rows.
    public func tsv(rows indices: [Int], columns visible: [Int]? = nil) -> String {
        let columnIndices = visible ?? Array(columns.indices)
        return indices.map { index in
            columnIndices.map { $0 < rows[index].count ? rows[index][$0].text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") : "" }.joined(separator: "\t")
        }.joined(separator: "\n")
    }
}
