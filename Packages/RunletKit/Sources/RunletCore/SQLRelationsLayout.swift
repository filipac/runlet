import CoreGraphics
import Foundation

/// The relations diagram's layout (#153): deterministic, in points, shared by the window, its PNG
/// export, and the SVG export. Layered: the focus in the middle column, the tables it references
/// to its left, the tables that reference it to its right, and hop 2 tables one column further
/// out. A column of more than `Metrics.maxColumnTables` tables wraps into several. Beyond `limit`
/// related tables, each side keeps a fair share and the rest collapse into a "+N more" group that
/// expands on click.
public struct SQLRelationsLayout: Sendable, Equatable {
    /// Sizes in points. Widths are estimated from character counts in the monospaced fonts the
    /// window draws with (SF Mono's advance is 0.6 em), so the layout needs no text measuring.
    public enum Metrics {
        public static let headerHeight: CGFloat = 28
        public static let rowHeight: CGFloat = 18
        public static let bottomPadding: CGFloat = 6
        public static let titleFontSize: CGFloat = 12
        public static let columnFontSize: CGFloat = 11
        public static let typeFontSize: CGFloat = 10
        public static let labelFontSize: CGFloat = 9.5
        public static let labelLineHeight: CGFloat = 13
        public static let minBoxWidth: CGFloat = 160
        public static let maxBoxWidth: CGFloat = 320
        public static let groupSize = CGSize(width: 200, height: 46)
        public static let boxGap: CGFloat = 22
        public static let margin: CGFloat = 32
        public static let minColumnGap: CGFloat = 120
        public static let maxColumnGap: CGFloat = 300
        public static let loopReach: CGFloat = 34
        /// Tables per column at most: a bigger column wraps into several, further out.
        public static let maxColumnTables = 12

        /// Text width, a little over SF Mono's 0.6 em advance so nothing truncates.
        static func width(_ text: String, size: CGFloat) -> CGFloat { CGFloat(text.count) * size * 0.62 }
    }

    /// One line of a table's box.
    public struct Row: Sendable, Equatable {
        public var name: String
        public var type: String?
        public var isPrimaryKey: Bool
        public var isForeignKey: Bool
        /// A note instead of a column ("4 more columns", "not in the loaded schema").
        public var note: String?

        public init(name: String, type: String? = nil, isPrimaryKey: Bool = false, isForeignKey: Bool = false, note: String? = nil) {
            self.name = name
            self.type = type
            self.isPrimaryKey = isPrimaryKey
            self.isForeignKey = isForeignKey
            self.note = note
        }
    }

    public struct Box: Sendable, Equatable, Identifiable {
        public var node: SQLRelations.Node
        public var frame: CGRect
        public var rows: [Row]

        public var id: String { node.name }

        /// The vertical centre of row `index`.
        public func rowCenter(_ index: Int) -> CGFloat {
            frame.minY + Metrics.headerHeight + Metrics.rowHeight * CGFloat(index) + Metrics.rowHeight / 2
        }
    }

    /// Tables collapsed beyond the limit, in one column.
    public struct Group: Sendable, Equatable, Identifiable {
        /// `referenced-1`, `referencing-2`, …
        public var id: String
        public var side: SQLRelations.Side
        public var hop: Int
        public var tables: [String]
        public var frame: CGRect

        /// "+12 more"
        public var title: String { "+\(tables.count) more" }
        /// "tables it references", "tables referencing it", "two hops out"
        public var subtitle: String {
            hop >= 2 ? "two hops out" : side == .referenced ? "tables it references" : "tables referencing it"
        }
    }

    /// A foreign key line, a cubic curve from the referencing table to the referenced one.
    public struct Edge: Sendable, Equatable, Identifiable {
        public var id: String
        /// Nil for a collapsed group's line (it stands for `count` keys).
        public var relation: SQLRelations.Relation?
        public var count: Int
        public var start: CGPoint
        public var control1: CGPoint
        public var control2: CGPoint
        public var end: CGPoint
        /// The column pairs, one per line; nil for a group's line.
        public var label: String?
        public var labelFrame: CGRect
        /// A self-reference, or two tables in one column: the curve loops out at the side.
        public var isLoop: Bool

        /// The point halfway along the curve.
        public static func midpoint(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> CGPoint {
            CGPoint(x: (p0.x + 3 * p1.x + 3 * p2.x + p3.x) / 8, y: (p0.y + 3 * p1.y + 3 * p2.y + p3.y) / 8)
        }

        /// The arrowhead at `end`, pointing into the referenced table: its tip and two corners.
        public var arrowhead: [CGPoint] {
            let dx = end.x - control2.x, dy = end.y - control2.y
            let length = max((dx * dx + dy * dy).squareRoot(), 0.001)
            let ux = dx / length, uy = dy / length
            let back = CGPoint(x: end.x - ux * 8, y: end.y - uy * 8)
            return [end, CGPoint(x: back.x - uy * 4, y: back.y + ux * 4), CGPoint(x: back.x + uy * 4, y: back.y - ux * 4)]
        }
    }

    public var graph: SQLRelations.Graph
    public var size: CGSize
    public var boxes: [Box]
    public var groups: [Group]
    public var edges: [Edge]
    public var allColumns: Bool

    public var focus: String { graph.focus }
    /// Tables in collapsed groups.
    public var hiddenCount: Int { groups.reduce(0) { $0 + $1.tables.count } }
    public func box(_ name: String) -> Box? { boxes.first { $0.id == name } }
    public func group(containing table: String) -> Group? { groups.first { $0.tables.contains(table) } }

    /// "6 tables · 7 foreign keys · 12 more collapsed"
    public var summary: String {
        let tables = graph.nodes.count, keys = graph.relations.count
        var text = "\(tables) table\(tables == 1 ? "" : "s") · \(keys) foreign key\(keys == 1 ? "" : "s")"
        if hiddenCount > 0 { text += " · \(hiddenCount) collapsed" }
        return text
    }

    /// Lays out `graph`: key columns only (primary, foreign, and referenced), or every column.
    /// `expanded` holds the group ids shown in full; past `limit` related tables the others
    /// collapse.
    public static func make(_ graph: SQLRelations.Graph, allColumns: Bool = false, expanded: Set<String> = [], limit: Int = 50) -> SQLRelationsLayout {
        let layers = layers(of: graph)
        let caps = caps(for: layers.map { ($0.key, $0.nodes.count) }, hop: { $0.hop }, related: graph.relatedCount, limit: limit)

        // What each column shows.
        var columns: [[Item]] = []
        var groups: [Group] = []
        for layer in layers {
            let id = "\(layer.key.side.rawValue)-\(layer.key.hop)"
            let cap = expanded.contains(id) ? layer.nodes.count : caps[layer.key] ?? layer.nodes.count
            var items = layer.nodes.prefix(cap).map { Item.box(makeBox($0, graph: graph, allColumns: allColumns)) }
            let hidden = layer.nodes.dropFirst(cap).map(\.name)
            if !hidden.isEmpty {
                let group = Group(id: id, side: layer.key.side, hop: layer.key.hop, tables: hidden, frame: CGRect(origin: .zero, size: Metrics.groupSize))
                groups.append(group)
                items.append(.group(group))
            }
            // A tall column wraps outwards: the first tables next to the focus.
            let wrapped = wrap(items)
            columns += layer.key.side == .referenced ? wrapped.reversed() : wrapped
        }

        // Which column each table or group is in, for the gaps' widths.
        var columnOf: [String: Int] = [:]
        for (index, items) in columns.enumerated() {
            for item in items {
                switch item {
                case .box(let box): columnOf[box.id] = index
                case .group(let group): for table in group.tables { columnOf[table] = index }
                }
            }
        }
        // Each gap holds the labels drawn in it: halfway between neighbouring columns, or next
        // to the outer table of a line that passes other columns.
        let focusColumn = columnOf[graph.focus] ?? 0
        var gaps = Array(repeating: Metrics.minColumnGap, count: max(columns.count - 1, 0))
        for relation in graph.relations {
            guard let a = columnOf[relation.from], let b = columnOf[relation.to], a != b else { continue }
            let label = labelSize(relation.label).width
            let gap: Int, width: CGFloat
            if abs(a - b) == 1 {
                (gap, width) = (min(a, b), label + 48)
            } else {
                let outer = abs(a - focusColumn) >= abs(b - focusColumn) ? a : b
                let other = outer == a ? b : a
                (gap, width) = (outer < other ? outer : outer - 1, label + 36)
            }
            gaps[gap] = min(max(gaps[gap], width), Metrics.maxColumnGap)
        }

        // Positions: columns side by side, each centred vertically, boxes centred in their column.
        let widths = columns.map { $0.map(\.width).max() ?? 0 }
        let heights = columns.map { items in items.map(\.height).reduce(0, +) + Metrics.boxGap * CGFloat(max(items.count - 1, 0)) }
        let tallest = heights.max() ?? 0
        var boxes: [Box] = []
        var x: CGFloat = 0
        for (index, items) in columns.enumerated() {
            var y = (tallest - heights[index]) / 2
            for item in items {
                let origin = CGPoint(x: x + (widths[index] - item.width) / 2, y: y)
                switch item {
                case .box(var box):
                    box.frame.origin = origin
                    boxes.append(box)
                case .group(let group):
                    if let at = groups.firstIndex(where: { $0.id == group.id }) { groups[at].frame.origin = origin }
                }
                y += item.height + Metrics.boxGap
            }
            x += widths[index] + (index < gaps.count ? gaps[index] : 0)
        }

        let edges = makeEdges(graph, boxes: boxes, groups: groups, columnOf: columnOf, focusColumn: focusColumn)
        var layout = SQLRelationsLayout(graph: graph, size: .zero, boxes: boxes, groups: groups, edges: edges, allColumns: allColumns)
        layout.fit()
        return layout
    }

    // MARK: Columns

    struct LayerKey: Hashable {
        var side: SQLRelations.Side
        var hop: Int
    }

    struct Layer {
        var key: LayerKey
        var nodes: [SQLRelations.Node]
    }

    /// The non-empty columns, left to right: hop 2 and hop 1 referenced tables, the focus, then
    /// hop 1 and hop 2 referencing tables. Hop 1 columns by name; hop 2 columns by the position
    /// of the table they were reached from, then by name, so lines cross less.
    static func layers(of graph: SQLRelations.Graph) -> [Layer] {
        let keys = [LayerKey(side: .referenced, hop: 2), LayerKey(side: .referenced, hop: 1), LayerKey(side: .focus, hop: 0),
                    LayerKey(side: .referencing, hop: 1), LayerKey(side: .referencing, hop: 2)]
        var layers: [LayerKey: [SQLRelations.Node]] = [:]
        for node in graph.nodes { layers[LayerKey(side: node.side, hop: node.hop), default: []].append(node) }
        for side in [SQLRelations.Side.referenced, .referencing] {
            let parents = layers[LayerKey(side: side, hop: 1)] ?? []
            let position = Dictionary(parents.enumerated().map { ($1.name, $0) }, uniquingKeysWith: { a, _ in a })
            layers[LayerKey(side: side, hop: 2)]?.sort {
                (position[$0.via ?? ""] ?? Int.max, $0.name.lowercased(), $0.name) < (position[$1.via ?? ""] ?? Int.max, $1.name.lowercased(), $1.name)
            }
        }
        return keys.compactMap { key in layers[key].flatMap { $0.isEmpty ? nil : Layer(key: key, nodes: $0) } }
    }

    /// How many tables each column shows: all of them up to `limit` related tables; past it, hop 1
    /// columns share the limit fairly, and hop 2 columns share what is left.
    static func caps<Key: Hashable>(for counts: [(Key, Int)], hop: (Key) -> Int, related: Int, limit: Int) -> [Key: Int] {
        var caps = Dictionary(counts, uniquingKeysWith: { a, _ in a })
        guard related > limit else { return caps }
        var budget = max(limit, 0)
        for wanted in [1, 2] {
            let layer = counts.filter { hop($0.0) == wanted }
            let shares = fairShares(layer.map(\.1), budget: budget)
            for (index, entry) in layer.enumerated() { caps[entry.0] = shares[index] }
            budget -= shares.reduce(0, +)
        }
        return caps
    }

    /// Water-filling: the largest even share each count gets within `budget`, then what's left
    /// one by one to the first counts still wanting more.
    static func fairShares(_ counts: [Int], budget: Int) -> [Int] {
        guard counts.reduce(0, +) > budget else { return counts }
        var level = 0
        while counts.map({ min($0, level + 1) }).reduce(0, +) <= budget { level += 1 }
        var shares = counts.map { min($0, level) }
        var left = budget - shares.reduce(0, +)
        for index in shares.indices where left > 0 && counts[index] > shares[index] {
            shares[index] += 1
            left -= 1
        }
        return shares
    }

    /// A column's items in balanced columns of at most `Metrics.maxColumnTables`.
    static func wrap(_ items: [Item]) -> [[Item]] {
        guard items.count > Metrics.maxColumnTables else { return [items] }
        let count = (items.count + Metrics.maxColumnTables - 1) / Metrics.maxColumnTables
        let size = (items.count + count - 1) / count
        return stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }

    enum Item {
        case box(Box)
        case group(Group)

        var width: CGFloat {
            switch self {
            case .box(let box): box.frame.width
            case .group(let group): group.frame.width
            }
        }

        var height: CGFloat {
            switch self {
            case .box(let box): box.frame.height
            case .group(let group): group.frame.height
            }
        }
    }

    // MARK: Boxes

    /// A table's box: its key columns (primary, foreign, and those the graph's keys reference),
    /// or all of them, with a note for the rest. A table outside the loaded schema shows the
    /// columns keys reference.
    static func makeBox(_ node: SQLRelations.Node, graph: SQLRelations.Graph, allColumns: Bool) -> Box {
        var rows: [Row] = []
        let referenced = Set(graph.relations.filter { $0.to == node.name }.flatMap(\.referencedColumns))
        let foreign = Set(graph.relations.filter { $0.from == node.name }.flatMap(\.columns))
        if let table = node.table {
            let declaredForeign = Set((table.foreignKeys ?? []).flatMap(\.columns) + table.columns.filter { $0.references != nil }.map(\.name)).union(foreign)
            let primary = Set(SQLRelations.primaryKey(table))
            let shown = table.columns.filter { allColumns || primary.contains($0.name) || declaredForeign.contains($0.name) || referenced.contains($0.name) }
            rows = shown.map { Row(name: $0.name, type: $0.type, isPrimaryKey: primary.contains($0.name), isForeignKey: declaredForeign.contains($0.name)) }
            let rest = table.columns.count - shown.count
            if rest > 0 { rows.append(Row(name: "", note: "\(rest) more column\(rest == 1 ? "" : "s")")) }
        } else {
            var seen = Set<String>()
            for relation in graph.relations where relation.to == node.name {
                for column in relation.referencedColumns where seen.insert(column).inserted { rows.append(Row(name: column)) }
            }
            for relation in graph.relations where relation.from == node.name {
                for column in relation.columns where seen.insert(column).inserted { rows.append(Row(name: column, isForeignKey: true)) }
            }
            rows.append(Row(name: "", note: "not in the loaded schema"))
        }
        let title = Metrics.width(node.name, size: Metrics.titleFontSize) + 42 + (node.table?.isView == true ? 40 : 0)
        let widest = rows.map { row in
            row.note.map { Metrics.width($0, size: Metrics.typeFontSize) + 32 }
                ?? Metrics.width(row.name, size: Metrics.columnFontSize) + (row.type.map { Metrics.width($0, size: Metrics.typeFontSize) + 8 } ?? 0) + 56
        }.max() ?? 0
        let width = min(max(Metrics.minBoxWidth, title, widest).rounded(.up), Metrics.maxBoxWidth)
        let height = Metrics.headerHeight + Metrics.rowHeight * CGFloat(rows.count) + Metrics.bottomPadding
        return Box(node: node, frame: CGRect(x: 0, y: 0, width: width, height: height), rows: rows)
    }

    /// A label's size: its longest line, one line per column pair.
    static func labelSize(_ label: String) -> CGSize {
        let lines = label.split(separator: "\n", omittingEmptySubsequences: false)
        let longest = lines.map(\.count).max() ?? 0
        return CGSize(width: (CGFloat(longest) * Metrics.labelFontSize * 0.6 + 12).rounded(.up), height: CGFloat(lines.count) * Metrics.labelLineHeight + 6)
    }

    // MARK: Edges

    private struct End {
        var frame: CGRect
        var y: CGFloat
        var column: Int
    }

    static func makeEdges(_ graph: SQLRelations.Graph, boxes: [Box], groups: [Group], columnOf: [String: Int], focusColumn: Int = 0) -> [Edge] {
        let boxByName = Dictionary(boxes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let groupOf = Dictionary(groups.flatMap { group in group.tables.map { ($0, group) } }, uniquingKeysWith: { a, _ in a })
        func rowY(_ box: Box, _ columns: [String]) -> CGFloat {
            let indices = columns.compactMap { name in box.rows.firstIndex { $0.note == nil && $0.name == name } }
            guard let first = indices.min(), let last = indices.max() else { return box.frame.minY + Metrics.headerHeight / 2 }
            return (box.rowCenter(first) + box.rowCenter(last)) / 2
        }
        var edges: [Edge] = []
        var loops: [String: Int] = [:]
        // The focus loops on a side without tables: the right, unless only the right has some.
        let focusLoopSide = boxes.contains { $0.node.side == .referencing } && !boxes.contains { $0.node.side == .referenced } ? -1 : 1
        var groupLines: [String: (from: End, to: End, count: Int)] = [:]
        for relation in graph.relations {
            let fromBox = boxByName[relation.from], toBox = boxByName[relation.to]
            if let fromBox, let toBox {
                let from = End(frame: fromBox.frame, y: rowY(fromBox, relation.columns), column: columnOf[relation.from] ?? 0)
                let to = End(frame: toBox.frame, y: rowY(toBox, relation.referencedColumns), column: columnOf[relation.to] ?? 0)
                let outward = fromBox.node.isFocus ? focusLoopSide : fromBox.node.side == .referenced ? -1 : 1
                let loopKey = (relation.isSelfReference || from.column == to.column) ? "\(relation.from)\u{1F}\(outward)" : nil
                let loopIndex = loopKey.map { key in loops[key, default: 0] }
                if let loopKey { loops[loopKey, default: 0] += 1 }
                var line = edge(id: relation.id, relation: relation, count: 1, from: from, to: to, label: relation.label, loop: loopIndex.map { (outward, $0) })
                if !line.isLoop, abs(from.column - to.column) > 1 {
                    // A line past other columns: its label next to the outer table, just above the line.
                    let fromOuter = abs(from.column - focusColumn) >= abs(to.column - focusColumn)
                    let point = fromOuter ? line.start : line.end
                    let inward: CGFloat = (fromOuter ? line.end.x : line.start.x) > point.x ? 1 : -1
                    line.labelFrame.origin = CGPoint(x: point.x + inward * 8 + (inward > 0 ? 0 : -line.labelFrame.width), y: point.y - line.labelFrame.height - 1)
                }
                edges.append(line)
                continue
            }
            // A line to a collapsed group: one per group and table, standing for all its keys.
            let fromGroup = fromBox == nil ? groupOf[relation.from] : nil
            let toGroup = toBox == nil ? groupOf[relation.to] : nil
            // Lines between two collapsed tables aren't drawn.
            if (fromBox == nil && fromGroup == nil) || (toBox == nil && toGroup == nil) || (fromGroup != nil && toGroup != nil) { continue }
            func end(_ box: Box?, _ group: Group?, _ name: String) -> End? {
                if let box { return End(frame: box.frame, y: box.frame.minY + Metrics.headerHeight / 2, column: columnOf[name] ?? 0) }
                if let group { return End(frame: group.frame, y: group.frame.midY, column: columnOf[name] ?? 0) }
                return nil
            }
            guard let from = end(fromBox, fromGroup, relation.from), let to = end(toBox, toGroup, relation.to) else { continue }
            let key = "group\u{1F}" + (fromGroup?.id ?? relation.from) + "\u{1F}" + (toGroup?.id ?? relation.to)
            groupLines[key] = (from, to, (groupLines[key]?.count ?? 0) + 1)
        }
        for (key, line) in groupLines {
            guard line.from.column != line.to.column else { continue }
            edges.append(edge(id: key, relation: nil, count: line.count, from: line.from, to: line.to, label: nil, loop: nil))
        }
        return edges.sorted { $0.id < $1.id }
    }

    /// The curve between two ends: across the gap between their columns, or (`loop`: the side,
    /// -1 left or 1 right, and how many loops that table has there already) out and back.
    private static func edge(id: String, relation: SQLRelations.Relation?, count: Int, from: End, to: End, label: String?, loop: (side: Int, index: Int)?) -> Edge {
        let start: CGPoint, end: CGPoint, control1: CGPoint, control2: CGPoint
        if let loop {
            let side = CGFloat(loop.side)
            let fromX = side > 0 ? from.frame.maxX : from.frame.minX
            let toX = side > 0 ? to.frame.maxX : to.frame.minX
            let reach = Metrics.loopReach + CGFloat(loop.index) * 14
            let outer = side > 0 ? max(fromX, toX) + reach : min(fromX, toX) - reach
            var fromY = from.y, toY = to.y
            if abs(toY - fromY) < 12 {
                fromY -= 4
                toY += 4
            }
            start = CGPoint(x: fromX, y: fromY)
            end = CGPoint(x: toX, y: toY)
            let spread: CGFloat = abs(toY - fromY) < 20 ? 14 : 0
            control1 = CGPoint(x: outer, y: fromY - (toY >= fromY ? spread : -spread))
            control2 = CGPoint(x: outer, y: toY + (toY >= fromY ? spread : -spread))
        } else {
            let rightward = from.frame.midX < to.frame.midX
            start = CGPoint(x: rightward ? from.frame.maxX : from.frame.minX, y: from.y)
            end = CGPoint(x: rightward ? to.frame.minX : to.frame.maxX, y: to.y)
            let reach = max(36, abs(end.x - start.x) * 0.45) * (rightward ? 1 : -1)
            control1 = CGPoint(x: start.x + reach, y: start.y)
            control2 = CGPoint(x: end.x - reach, y: end.y)
        }
        let middle = Edge.midpoint(start, control1, control2, end)
        let size = label.map(labelSize) ?? .zero
        var labelFrame = CGRect(x: middle.x - size.width / 2, y: middle.y - size.height / 2, width: size.width, height: size.height)
        if let loop {
            // Beyond the loop's outermost point, so it covers neither the loop nor the table.
            labelFrame.origin.x = loop.side > 0 ? middle.x + 4 : middle.x - 4 - size.width
        }
        return Edge(id: id, relation: relation, count: count, start: start, control1: control1, control2: control2, end: end, label: label, labelFrame: labelFrame, isLoop: loop != nil)
    }

    // MARK: Bounds

    /// Moves everything so the drawing starts at the margin, and sets `size`.
    mutating func fit() {
        var bounds = CGRect.null
        for box in boxes { bounds = bounds.union(box.frame) }
        for group in groups { bounds = bounds.union(group.frame) }
        for edge in edges {
            for point in [edge.start, edge.control1, edge.control2, edge.end] { bounds = bounds.union(CGRect(origin: point, size: .zero)) }
            if edge.label != nil { bounds = bounds.union(edge.labelFrame) }
        }
        guard !bounds.isNull else { return }
        let dx = Metrics.margin - bounds.minX, dy = Metrics.margin - bounds.minY
        func moved(_ point: CGPoint) -> CGPoint { CGPoint(x: (point.x + dx).rounded(toPlaces: 1), y: (point.y + dy).rounded(toPlaces: 1)) }
        func moved(_ rect: CGRect) -> CGRect { CGRect(origin: moved(rect.origin), size: rect.size) }
        for index in boxes.indices { boxes[index].frame = moved(boxes[index].frame) }
        for index in groups.indices { groups[index].frame = moved(groups[index].frame) }
        for index in edges.indices {
            edges[index].start = moved(edges[index].start)
            edges[index].control1 = moved(edges[index].control1)
            edges[index].control2 = moved(edges[index].control2)
            edges[index].end = moved(edges[index].end)
            edges[index].labelFrame = moved(edges[index].labelFrame)
        }
        size = CGSize(width: (bounds.width + Metrics.margin * 2).rounded(.up), height: (bounds.height + Metrics.margin * 2).rounded(.up))
    }
}

private extension CGFloat {
    func rounded(toPlaces places: Int) -> CGFloat {
        let factor = CGFloat(pow(10, Double(places)))
        return (self * factor).rounded() / factor
    }
}
