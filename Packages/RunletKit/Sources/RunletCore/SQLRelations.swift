import Foundation

/// The relations diagram (#153): a table, the tables it references, and the tables that reference
/// it, one or two hops out, built only from a loaded schema (`SQLSchemaInfo`). Nothing here reads
/// or runs anything: the diagram only draws, and Copy Join prepares text.
public enum SQLRelations {
    /// One foreign key: `from`'s `columns` reference `to`'s `referencedColumns`, pair by pair. A
    /// composite key is one relation.
    public struct Relation: Sendable, Equatable, Hashable, Identifiable {
        /// The referencing table, as the schema names it.
        public var from: String
        public var columns: [String]
        /// The referenced table: the schema's name for it, or the name the key gives when the
        /// table isn't in the loaded schema.
        public var to: String
        /// Empty when neither the catalog nor the referenced table's primary key names them.
        public var referencedColumns: [String]
        /// The constraint's name, when the catalog gave one.
        public var name: String?

        public init(from: String, columns: [String], to: String, referencedColumns: [String], name: String? = nil) {
            self.from = from
            self.columns = columns
            self.to = to
            self.referencedColumns = referencedColumns
            self.name = name
        }

        public var id: String { [from, name ?? columns.joined(separator: ","), to].joined(separator: "\u{1F}") }
        public var isSelfReference: Bool { from == to }
        public var isComposite: Bool { columns.count > 1 }
        /// Every column has its referenced column, so a JOIN can be written.
        public var isComplete: Bool { !columns.isEmpty && columns.count == referencedColumns.count }

        /// One line per column pair: "customer_id → id".
        public var label: String {
            guard isComplete else { return columns.joined(separator: ", ") + " → ?" }
            return zip(columns, referencedColumns).map { "\($0) → \($1)" }.joined(separator: "\n")
        }

        /// "orders.customer_id → customers.id", composite keys as "(a, b) → (x, y)".
        public var summary: String {
            func list(_ table: String, _ names: [String]) -> String {
                names.count == 1 ? "\(table).\(names[0])" : "\(table)(\(names.joined(separator: ", ")))"
            }
            return list(from, columns) + " → " + list(to, referencedColumns.isEmpty ? ["?"] : referencedColumns)
        }

        /// The constraint's name, unless SQLite's catalog only numbered it.
        public var displayName: String? {
            guard let name, !name.allSatisfy(\.isNumber) else { return nil }
            return name
        }
    }

    /// Every foreign key of a schema, sorted. From each table's `foreignKeys` when the catalog
    /// named the constraints, else from its columns' `references`: columns that together reference
    /// a table's whole composite primary key are one relation, every other column its own.
    public static func relations(in schema: SQLSchemaInfo) -> [Relation] {
        let resolver = Resolver(schema)
        var relations: [Relation] = []
        for table in schema.tables {
            if let keys = table.foreignKeys, !keys.isEmpty {
                for key in keys where !key.columns.isEmpty {
                    let target = resolver.name(key.references) ?? key.references
                    var referenced = key.referencedColumns ?? []
                    if referenced.count != key.columns.count {
                        let primary = resolver.table(target).map(primaryKey) ?? []
                        referenced = primary.count == key.columns.count ? primary : []
                    }
                    relations.append(Relation(from: table.name, columns: key.columns, to: target, referencedColumns: referenced, name: key.name))
                }
                continue
            }
            relations += columnRelations(of: table, resolver: resolver)
        }
        return relations.sorted { ($0.from, $0.to, $0.columns.joined(separator: ",")) < ($1.from, $1.to, $1.columns.joined(separator: ",")) }
    }

    /// A table's relations from its columns' `references` (`table.column`, or `table`).
    private static func columnRelations(of table: SQLSchemaInfo.Table, resolver: Resolver) -> [Relation] {
        var byTarget: [(target: String, pairs: [(column: String, referenced: String?)])] = []
        for column in table.columns {
            guard let reference = column.references, !reference.isEmpty else { continue }
            let target: String
            var referenced: String?
            if let whole = resolver.name(reference) {
                target = whole
            } else if let dot = reference.lastIndex(of: ".") {
                let name = String(reference[..<dot])
                target = resolver.name(name) ?? name
                referenced = String(reference[reference.index(after: dot)...])
            } else {
                target = reference
            }
            if let at = byTarget.firstIndex(where: { $0.target == target }) {
                byTarget[at].pairs.append((column.name, referenced))
            } else {
                byTarget.append((target, [(column.name, referenced)]))
            }
        }
        var relations: [Relation] = []
        for (target, pairs) in byTarget {
            let primary = resolver.table(target).map(primaryKey) ?? []
            let referenced = pairs.compactMap(\.referenced)
            if pairs.count > 1, referenced.count == pairs.count, Set(referenced).count == pairs.count, Set(referenced) == Set(primary) {
                // Together they reference the whole composite primary key: one relation, in the key's order.
                let ordered = primary.compactMap { key in pairs.first { $0.referenced == key }?.column }
                relations.append(Relation(from: table.name, columns: ordered, to: target, referencedColumns: primary))
                continue
            }
            for pair in pairs {
                let columns = pair.referenced.map { [$0] } ?? (primary.count == 1 ? primary : [])
                relations.append(Relation(from: table.name, columns: [pair.column], to: target, referencedColumns: columns))
            }
        }
        return relations
    }

    /// A table's primary key columns, in the primary index's order when it has one.
    static func primaryKey(_ table: SQLSchemaInfo.Table) -> [String] {
        if let index = table.indexes?.first(where: { $0.primary == true }), !index.columns.isEmpty { return index.columns }
        return table.columns.filter { $0.primaryKey == true }.map(\.name)
    }

    /// Finds a referenced table by its exact name, then ignoring case and identifier quotes.
    /// Unlike `SQLSchemaInfo.table(named:)`, never by suffix: `customers` isn't `sales.customers`.
    struct Resolver {
        let byName: [String: SQLSchemaInfo.Table]
        let byLowercased: [String: SQLSchemaInfo.Table]

        init(_ schema: SQLSchemaInfo) {
            var byName: [String: SQLSchemaInfo.Table] = [:]
            var byLowercased: [String: SQLSchemaInfo.Table] = [:]
            for table in schema.tables {
                if byName[table.name] == nil { byName[table.name] = table }
                if byLowercased[table.name.lowercased()] == nil { byLowercased[table.name.lowercased()] = table }
            }
            self.byName = byName
            self.byLowercased = byLowercased
        }

        func table(_ name: String) -> SQLSchemaInfo.Table? {
            if let table = byName[name] { return table }
            let unquoted = name.split(separator: ".", omittingEmptySubsequences: false).map { SQLCompletion.unquoted(String($0)) }.joined(separator: ".")
            return byName[unquoted] ?? byLowercased[unquoted.lowercased()]
        }

        func name(_ name: String) -> String? { table(name)?.name }
    }

    // MARK: Graph

    /// Where a table sits: the focus in the middle, the tables it references on one side, the
    /// tables that reference it on the other. Hop 2 tables take the side of the table they were
    /// reached from.
    public enum Side: String, Sendable, CaseIterable {
        case referenced, focus, referencing
    }

    public struct Node: Sendable, Equatable, Identifiable {
        public var name: String
        public var hop: Int
        public var side: Side
        /// The hop 1 table a hop 2 table was reached from (it orders the hop 2 column).
        public var via: String?
        /// Nil when the table isn't in the loaded schema (another schema or database, or more
        /// tables than Runlet keeps).
        public var table: SQLSchemaInfo.Table?

        public var id: String { name }
        public var isMissing: Bool { table == nil }
        public var isFocus: Bool { hop == 0 }
    }

    public struct Graph: Sendable, Equatable {
        public var focus: String
        public var hops: Int
        /// The focus first, then each side's tables by hop and name.
        public var nodes: [Node]
        /// The relations between the graph's tables, self-references included.
        public var relations: [Relation]

        public func node(_ name: String) -> Node? { nodes.first { $0.name == name } }
        /// Tables other than the focus.
        public var relatedCount: Int { nodes.count - 1 }
    }

    /// The focus table's graph, `hops` (1 or 2) out; nil when the schema has no such table.
    /// `relations` are the schema's, when the caller already has them.
    public static func graph(of focus: String, in schema: SQLSchemaInfo, hops: Int, relations all: [Relation]? = nil) -> Graph? {
        let resolver = Resolver(schema)
        guard let focusTable = resolver.table(focus) else { return nil }
        let all = all ?? relations(in: schema)
        var outgoing: [String: [Relation]] = [:]
        var incoming: [String: [Relation]] = [:]
        for relation in all where !relation.isSelfReference {
            outgoing[relation.from, default: []].append(relation)
            incoming[relation.to, default: []].append(relation)
        }
        let byName = { (a: String, b: String) in (a.lowercased(), a) < (b.lowercased(), b) }
        var nodes: [String: Node] = [focusTable.name: Node(name: focusTable.name, hop: 0, side: .focus, table: focusTable)]
        var firstHop: [Node] = []
        let referenced = Set((outgoing[focusTable.name] ?? []).map(\.to)).sorted(by: byName)
        let referencing = Set((incoming[focusTable.name] ?? []).map(\.from)).sorted(by: byName)
        for (names, side) in [(referenced, Side.referenced), (referencing, Side.referencing)] {
            for name in names where nodes[name] == nil {
                let node = Node(name: name, hop: 1, side: side, table: resolver.table(name))
                nodes[name] = node
                firstHop.append(node)
            }
        }
        if hops >= 2 {
            for parent in firstHop {
                let neighbours = Set((outgoing[parent.name] ?? []).map(\.to) + (incoming[parent.name] ?? []).map(\.from)).sorted(by: byName)
                for name in neighbours where nodes[name] == nil {
                    nodes[name] = Node(name: name, hop: 2, side: parent.side, via: parent.name, table: resolver.table(name))
                }
            }
        }
        let sideOrder: [Side: Int] = [.focus: 0, .referenced: 1, .referencing: 2]
        let ordered = nodes.values.sorted {
            (sideOrder[$0.side] ?? 0, $0.hop, $0.name.lowercased(), $0.name) < (sideOrder[$1.side] ?? 0, $1.hop, $1.name.lowercased(), $1.name)
        }
        let edges = all.filter { nodes[$0.from] != nil && nodes[$0.to] != nil }
        return Graph(focus: focusTable.name, hops: hops, nodes: ordered, relations: edges)
    }

    // MARK: Copy Join

    /// The table Copy Join adds for a relation in a graph: the one further from the focus, else
    /// the referenced table (a self-reference joins the referenced row under an alias).
    public static func joinedTable(_ relation: Relation, in graph: Graph?) -> String {
        guard let graph, let from = graph.node(relation.from), let to = graph.node(relation.to) else { return relation.to }
        return from.hop > to.hop ? relation.from : relation.to
    }

    /// `JOIN customers ON customers.id = orders.customer_id`, one `AND` per further column pair,
    /// with names quoted for `driver` as the explorer quotes them. A self-reference joins the
    /// table again under an alias named after its key (`manager` for `manager_id`). Nil when a
    /// referenced column isn't known.
    public static func join(_ relation: Relation, joining table: String, driver: String?) -> String? {
        guard relation.isComplete, table == relation.to || table == relation.from else { return nil }
        let joinsReferenced = table == relation.to
        let other = joinsReferenced ? relation.from : relation.to
        let joinedColumns = joinsReferenced ? relation.referencedColumns : relation.columns
        let otherColumns = joinsReferenced ? relation.columns : relation.referencedColumns
        let quotedTable = SQLSchemaExplorer.quoted(table, driver: driver)
        var head = "JOIN \(quotedTable)"
        var joinedName = quotedTable
        if relation.isSelfReference {
            let alias = column(selfJoinAlias(relation, joinsReferenced: joinsReferenced), driver: driver)
            head += (driver == "oci" ? " " : " AS ") + alias
            joinedName = alias
        }
        let otherName = SQLSchemaExplorer.quoted(other, driver: driver)
        let conditions = zip(joinedColumns, otherColumns).map { "\(joinedName).\(column($0, driver: driver)) = \(otherName).\(column($1, driver: driver))" }
        return head + " ON " + conditions.joined(separator: " AND ")
    }

    /// A self-join's alias: the key's name without `_id` (`manager_id` → `manager`), else `parent`
    /// for the referenced row and `child` for the referencing one.
    static func selfJoinAlias(_ relation: Relation, joinsReferenced: Bool) -> String {
        let fallback = joinsReferenced ? "parent" : "child"
        guard joinsReferenced, relation.columns.count == 1, let key = relation.columns.first else { return fallback }
        var alias = key
        for suffix in ["_id", "_ID", "Id", "ID"] where alias.hasSuffix(suffix) && alias.count > suffix.count {
            alias = String(alias.dropLast(suffix.count))
            break
        }
        let table = relation.to.split(separator: ".").last.map(String.init) ?? relation.to
        if alias == key || alias.lowercased() == table.lowercased() || alias.isEmpty { return fallback }
        return alias
    }

    /// A column name as SQL needs it on `driver` (never split at a dot).
    static func column(_ name: String, driver: String?) -> String {
        SQLCompletion.identifier(name, quote: driver == "mysql" ? "`" : "\"", pgsql: driver == "pgsql")
    }
}
