import Foundation

// MARK: - Explain Statement (#147)

/// Explain Statement in SQL tabs (#147): what Runlet sends and how it reads the answer. Plain
/// Explain asks the database for the statement's plan and never runs the statement; Explain
/// Analyze runs it (guarded in the app and the runner). The runner's `SqlTab::explain()`
/// chooses the dialect's EXPLAIN from the connection's driver:
///
/// | Database | Explain | Explain Analyze |
/// | --- | --- | --- |
/// | MySQL 5.6+ | `EXPLAIN FORMAT=JSON` | `EXPLAIN ANALYZE` (8.0.18+, a text tree); reads only |
/// | MariaDB | `EXPLAIN FORMAT=JSON` | `ANALYZE FORMAT=JSON`; reads only |
/// | PostgreSQL | `EXPLAIN (FORMAT JSON)` | `EXPLAIN (ANALYZE, FORMAT JSON)` in a transaction that is rolled back |
/// | SQLite | `EXPLAIN QUERY PLAN` | none |
///
/// SQL Server and connections whose dialect Runlet doesn't know (a driver's callable) are
/// refused with a message.
public enum SQLExplain {
    public enum Mode: String, Sendable, Codable, Equatable {
        /// The plan only; the statement doesn't run.
        case plan
        /// The plan with what happened: the statement runs.
        case analyze

        public var title: String { self == .plan ? "Explain" : "Explain Analyze" }
    }

    /// Words that already make a statement an EXPLAIN (or, for MariaDB's ANALYZE, run it).
    static let explainingWords: Set<String> = ["EXPLAIN", "DESCRIBE", "DESC", "ANALYZE"]

    /// Why Explain Statement refuses `statement` before anything is sent, or nil.
    public static func refusal(of statement: String) -> String? {
        guard let first = SQLScript.firstWords(of: statement, count: 1).first, explainingWords.contains(first) else { return nil }
        return first == "ANALYZE"
            ? "This statement starts with ANALYZE, which runs it (MariaDB) or updates statistics. Explain Statement adds the database's own EXPLAIN: remove ANALYZE, or press Run to run the statement as written."
            : "This statement is already an \(first == "EXPLAIN" ? "EXPLAIN" : "\(first) (EXPLAIN)"). Explain Statement adds the database's own EXPLAIN itself: remove \(first), or press Run to run the statement as written."
    }

    /// Explain Analyze runs `statement`. A statement that can write (or that Runlet can't
    /// classify) needs the tab's confirmation, is refused on MySQL, MariaDB, SQLite, and
    /// read-only connections, and runs in a rolled-back transaction on PostgreSQL. Nil for reads.
    public static func analyzeWrite(of statement: String) -> SQLScript.Effect? {
        let effect = SQLScript.effect(of: statement)
        return effect.isRead ? nil : effect
    }

    /// "the DELETE", "a statement starting with LISTEN", "this statement".
    public static func analyzedStatement(_ effect: SQLScript.Effect) -> String {
        switch effect {
        case .read: "the statement"
        case .write(let keyword): keyword.contains(" ") ? "a statement that can change data (\(keyword))" : "the \(keyword)"
        case .unknown(let keyword): keyword.isEmpty ? "this statement" : "a statement starting with \(keyword)"
        }
    }

    /// The production confirmation's warning for Explain Analyze: the existing
    /// `EXPLAIN ANALYZE … DELETE` warning of `SQLScript.effect`.
    public static func productionWarning(analyzing statement: String) -> String? {
        if let warning = SQLScript.effect(of: "EXPLAIN ANALYZE " + statement).warning { return warning }
        if case .unknown = SQLScript.effect(of: statement) {
            return "Runlet can't tell whether this statement changes data; Explain Analyze runs it."
        }
        return nil
    }

    /// The PHP an Explain run sends: the statement and connection name are PHP string literals,
    /// as for Run (#35); a saved connection (#138) travels in the run request, never here.
    /// `bindings` are the statement's bound values (#145), from the same values sheet as Run,
    /// handed to `PDOStatement::bindValue` and never part of the SQL.
    public static func code(statement: String, connection: String?, mode: Mode, bindings: [SQLBinding] = []) -> String {
        """
        <?php
        // Runlet SQL tab (#147): \(mode == .plan ? "the plan of one statement; the statement doesn't run" : "Explain Analyze of one statement; the statement runs").
        return \\RunletRunner\\SqlTab::explain(\(QueryExplain.phpString(statement)), \(connection.map(QueryExplain.phpString) ?? "null"), \(mode == .analyze ? "true" : "false")\(bindings.isEmpty ? "" : ", " + SQLTabRun.phpBindings(bindings)));
        """
    }
}

/// A query plan in one shape for every database (#147), parsed from the database's own output
/// (`SQLPlanParser`). Nodes are kept flat, in tree order, so a view can collapse a subtree by
/// skipping `descendants` rows instead of building nested views.
public struct SQLPlan: Sendable, Equatable {
    public struct Node: Sendable, Equatable, Identifiable {
        /// The node's position in `nodes`.
        public var id: Int
        public var depth: Int
        public var parent: Int?
        /// How many nodes follow this one in its subtree.
        public var descendants: Int
        /// What the database does: "Seq Scan", "Full table scan", "SEARCH", "Nested loop", …
        public var operation: String
        public var table: String?
        /// The index used, when there is one.
        public var index: String?
        /// The database's estimate of the rows the node returns (per loop where the database
        /// says so: PostgreSQL, MySQL's `rows_examined_per_scan`).
        public var rows: Double?
        /// The database's cost estimate, in its own units (PostgreSQL's total cost; MySQL's
        /// read + evaluation cost or the query block's cost; MariaDB's cost).
        public var cost: Double?
        /// Explain Analyze: rows the node returned (per loop on PostgreSQL and MySQL).
        public var actualRows: Double?
        /// Explain Analyze: milliseconds the node took (per loop on PostgreSQL and MySQL).
        public var actualMs: Double?
        public var loops: Double?
        /// Conditions, keys, and notes ("Filter: (qty > 100)", "Sort key: …").
        public var details: [String]
        /// A full scan of a table: MySQL's `access_type: ALL`, PostgreSQL's Seq Scan, SQLite's
        /// SCAN without an index, MySQL's tree "Table scan on".
        public var fullScan: Bool

        public init(id: Int = 0, depth: Int = 0, parent: Int? = nil, descendants: Int = 0, operation: String, table: String? = nil, index: String? = nil, rows: Double? = nil, cost: Double? = nil, actualRows: Double? = nil, actualMs: Double? = nil, loops: Double? = nil, details: [String] = [], fullScan: Bool = false) {
            self.id = id
            self.depth = depth
            self.parent = parent
            self.descendants = descendants
            self.operation = operation
            self.table = table
            self.index = index
            self.rows = rows
            self.cost = cost
            self.actualRows = actualRows
            self.actualMs = actualMs
            self.loops = loops
            self.details = details
            self.fullScan = fullScan
        }

        /// "Seq Scan on orders o using orders_status"
        public var title: String {
            // SQLite's steps are upper case: "SEARCH c USING INDEX items_customer".
            let shouting = operation == operation.uppercased()
            var text = operation
            let words = Set(operation.split(separator: " ").map(String.init))
            if let table, !words.contains(table) { text += (shouting ? " " : " on ") + table }
            if let index, !words.contains(index) {
                text += (shouting ? (index.contains("KEY") ? " USING " : " USING INDEX ") : " using ") + index
            }
            return text
        }

        /// "rows 25 · cost 7.90 · actual 25 rows, 0.048 ms × 1"
        public var metrics: String {
            var parts: [String] = []
            if let rows { parts.append("rows " + SQLPlan.format(rows)) }
            if let cost { parts.append("cost " + SQLPlan.formatCost(cost)) }
            if actualRows != nil || actualMs != nil {
                var actual = "actual"
                if let actualRows { actual += " " + SQLPlan.format(actualRows) + " row" + (actualRows == 1 ? "" : "s") }
                if let actualMs { actual += (actualRows == nil ? " " : ", ") + SQLPlan.format(actualMs, decimals: 3) + " ms" }
                if let loops, loops != 1 { actual += " × " + SQLPlan.format(loops) }
                parts.append(actual)
            }
            return parts.joined(separator: " · ")
        }
    }

    /// Which database's format the plan came from.
    public enum Dialect: String, Sendable, Codable, Equatable {
        case mysql, mariadb, pgsql, sqlite

        public var displayName: String {
            switch self {
            case .mysql: "MySQL"
            case .mariadb: "MariaDB"
            case .pgsql: "PostgreSQL"
            case .sqlite: "SQLite"
            }
        }
    }

    public var dialect: Dialect
    public var nodes: [Node]
    /// The plan's total cost estimate, when the database gives one.
    public var totalCost: Double?
    /// Explain Analyze on PostgreSQL: planning and execution time.
    public var planningMs: Double?
    public var executionMs: Double?
    public var analyzed: Bool

    public init(dialect: Dialect, nodes: [Node], totalCost: Double? = nil, planningMs: Double? = nil, executionMs: Double? = nil, analyzed: Bool = false) {
        self.dialect = dialect
        self.nodes = nodes
        self.totalCost = totalCost
        self.planningMs = planningMs
        self.executionMs = executionMs
        self.analyzed = analyzed
    }

    public var fullScans: [Node] { nodes.filter(\.fullScan) }

    /// "6 steps · 2 full scans · cost 7.90"
    public var summary: String {
        var parts = ["\(nodes.count) step\(nodes.count == 1 ? "" : "s")"]
        let scans = fullScans.count
        if scans > 0 { parts.append("\(scans) full scan\(scans == 1 ? "" : "s")") }
        if let totalCost { parts.append("cost " + Self.formatCost(totalCost)) }
        if let executionMs { parts.append("executed in " + Self.format(executionMs, decimals: 3) + " ms") }
        return parts.joined(separator: " · ")
    }

    /// The plan as indented text (Copy Output).
    public var text: String {
        nodes.map { node in
            let indent = String(repeating: "  ", count: node.depth)
            var line = indent + "-> " + node.title
            let metrics = node.metrics
            if !metrics.isEmpty { line += "  (" + metrics + ")" }
            if node.fullScan { line += "  [full scan]" }
            for detail in node.details { line += "\n" + indent + "     " + detail }
            return line
        }.joined(separator: "\n")
    }

    /// Builds a plan from a tree, numbering its nodes in order.
    init(dialect: Dialect, tree: [TreeNode], totalCost: Double? = nil, planningMs: Double? = nil, executionMs: Double? = nil, analyzed: Bool = false) {
        var nodes: [Node] = []
        func add(_ tree: TreeNode, depth: Int, parent: Int?) {
            var node = tree.node
            node.id = nodes.count
            node.depth = depth
            node.parent = parent
            nodes.append(node)
            let index = node.id
            for child in tree.children { add(child, depth: depth + 1, parent: index) }
            nodes[index].descendants = nodes.count - index - 1
        }
        for root in tree { add(root, depth: 0, parent: nil) }
        self.init(dialect: dialect, nodes: nodes, totalCost: totalCost, planningMs: planningMs, executionMs: executionMs, analyzed: analyzed)
    }

    /// A node and its children while parsing.
    struct TreeNode {
        var node: Node
        var children: [TreeNode] = []
    }

    /// Costs in the database's units: "1,234", "7.90", "0.0190".
    static func formatCost(_ value: Double) -> String {
        if value >= 1000 { return Int64(value.rounded()).formatted() }
        return String(format: value >= 1 || value == 0 ? "%.2f" : "%.4f", value)
    }

    /// "3.20 ms", "120 ms"
    static func formatMs(_ value: Double) -> String {
        String(format: value < 10 ? "%.2f ms" : "%.0f ms", value)
    }

    /// "25", "1,200", "0.5", "7.90" with `decimals`.
    static func format(_ value: Double, decimals: Int? = nil) -> String {
        if let decimals { return String(format: "%.\(decimals)f", value) }
        if value.rounded() == value, abs(value) < 1e15 { return Int64(value).formatted() }
        return String(format: value < 10 ? "%.2f" : "%.1f", value)
    }
}

/// The runner's `sqlPlan` event (#147): the database's own output for Explain Statement, the
/// connection it came from, and (decoded here, once, off the main thread) the parsed plan.
public struct SQLPlanInfo: Sendable, Codable, Equatable {
    /// `mysql`, `pgsql`, `sqlite`: the PDO driver.
    public var driver: String?
    /// `mysql`, `mariadb`, `pgsql`, `sqlite`.
    public var dialect: String?
    /// `json` (MySQL, MariaDB, PostgreSQL), `tree` (MySQL's EXPLAIN ANALYZE), or `rows`
    /// (SQLite's EXPLAIN QUERY PLAN).
    public var format: String?
    public var analyze: Bool?
    /// What the runner put before the statement: `EXPLAIN FORMAT=JSON`, `EXPLAIN (ANALYZE, FORMAT JSON)`, …
    public var explained: String?
    /// The database's own output (JSON or text); for SQLite, `rows` instead.
    public var raw: String?
    /// SQLite: `[id, parent, detail]` per row.
    public var rows: [[SQLCell]]?
    /// The raw output was longer than Runlet keeps.
    public var rawTruncated: Bool?
    /// PostgreSQL's Explain Analyze ran in a transaction the runner rolled back.
    public var rolledBack: Bool?
    public var serverVersion: String?
    public var elapsedMs: Double?
    public var connection: String?
    public var source: String?
    public var connections: [String]?
    public var saved: Bool?

    /// The parsed plan; nil when the output couldn't be read (`parseError` says why).
    public private(set) var plan: SQLPlan?
    public private(set) var parseError: String?

    enum CodingKeys: String, CodingKey {
        case driver, dialect, format, analyze, explained, raw, rows, rawTruncated, rolledBack, serverVersion, elapsedMs, connection, source, connections, saved
    }

    public init(driver: String? = nil, dialect: String? = nil, format: String? = nil, analyze: Bool? = nil, explained: String? = nil, raw: String? = nil, rows: [[SQLCell]]? = nil, rawTruncated: Bool? = nil, rolledBack: Bool? = nil, serverVersion: String? = nil, elapsedMs: Double? = nil, connection: String? = nil, source: String? = nil, connections: [String]? = nil, saved: Bool? = nil) {
        self.driver = driver
        self.dialect = dialect
        self.format = format
        self.analyze = analyze
        self.explained = explained
        self.raw = raw
        self.rows = rows
        self.rawTruncated = rawTruncated
        self.rolledBack = rolledBack
        self.serverVersion = serverVersion
        self.elapsedMs = elapsedMs
        self.connection = connection
        self.source = source
        self.connections = connections
        self.saved = saved
        parse()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        driver = try c.decodeIfPresent(String.self, forKey: .driver)
        dialect = try c.decodeIfPresent(String.self, forKey: .dialect)
        format = try c.decodeIfPresent(String.self, forKey: .format)
        analyze = try? c.decodeIfPresent(Bool.self, forKey: .analyze)
        explained = try? c.decodeIfPresent(String.self, forKey: .explained)
        raw = try c.decodeIfPresent(String.self, forKey: .raw)
        rows = try? c.decodeIfPresent([[SQLCell]].self, forKey: .rows)
        rawTruncated = try? c.decodeIfPresent(Bool.self, forKey: .rawTruncated)
        rolledBack = try? c.decodeIfPresent(Bool.self, forKey: .rolledBack)
        serverVersion = try? c.decodeIfPresent(String.self, forKey: .serverVersion)
        elapsedMs = try? c.decodeIfPresent(Double.self, forKey: .elapsedMs)
        connection = try c.decodeIfPresent(String.self, forKey: .connection)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        connections = try? c.decodeIfPresent([String].self, forKey: .connections)
        saved = try? c.decodeIfPresent(Bool.self, forKey: .saved)
        parse()
    }

    private mutating func parse() {
        do {
            plan = try SQLPlanParser.parse(self)
            parseError = nil
        } catch {
            plan = nil
            parseError = "\(error)"
        }
    }

    public var isAnalyze: Bool { analyze == true }

    /// The database's own output as text: the JSON or tree, or SQLite's rows as a table.
    public var rawText: String {
        if let raw { return raw + (rawTruncated == true ? "\n… (Runlet keeps the first 4 MiB of a plan)" : "") }
        guard let rows else { return "" }
        return (["id\tparent\tdetail"] + rows.map { $0.map(\.text).joined(separator: "\t") }).joined(separator: "\n")
    }

    /// "MariaDB 11.8.9", "PostgreSQL 14.23", "SQLite 3.45.2"
    public var databaseName: String {
        let name = SQLPlan.Dialect(rawValue: dialect ?? "")?.displayName ?? driver ?? "the database"
        guard let version = serverVersion?.split(separator: "-").first.map(String.init), !version.isEmpty else { return name }
        // MariaDB behind old clients reports "5.5.5-10.11.6-MariaDB".
        if dialect == "mariadb", version == "5.5.5", let real = serverVersion?.split(separator: "-").dropFirst().first { return name + " " + real }
        return name + " " + (version.split(separator: " ").first.map(String.init) ?? version)
    }

    /// The line under the plan, like a result's (#35): "MariaDB 11.8.9 · default connection · via …".
    public var originText: String {
        if saved == true {
            return [databaseName, source.map { "via \($0)" } ?? "via saved connection “\(connection ?? "")”"].joined(separator: " · ")
        }
        let connection = connection.map { "connection “\($0)”" } ?? "default connection"
        return [databaseName, connection, source.map { "via \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    /// Copy Output.
    public var plainText: String {
        var lines = ["\(isAnalyze ? "Explain Analyze" : "Explain"): " + (plan?.summary ?? "plan not read") + (elapsedMs.map { " in " + SQLPlan.formatMs($0) } ?? "")]
        if let plan { lines.append(plan.text) } else { lines.append(rawText) }
        if rolledBack == true { lines.append("(Ran in a transaction that Runlet rolled back.)") }
        return lines.joined(separator: "\n")
    }

    /// Copy Output as Markdown.
    public var markdown: String {
        var text = "### " + (isAnalyze ? "Explain Analyze" : "Explain") + ": " + MarkdownText.inline(plan?.summary ?? "plan not read")
        text += "\n\n" + MarkdownText.fence(plan?.text ?? rawText, language: "text")
        if rolledBack == true { text += "\n\n_Ran in a transaction that Runlet rolled back._" }
        return text
    }
}

/// Why a plan couldn't be read.
public struct SQLPlanParseError: Error, CustomStringConvertible, Equatable {
    public var description: String
}

/// Reads the databases' EXPLAIN output into `SQLPlan` (#147).
public enum SQLPlanParser {
    public static func parse(_ info: SQLPlanInfo) throws -> SQLPlan {
        if info.rawTruncated == true {
            throw SQLPlanParseError(description: "The plan was longer than Runlet keeps, so it can't be read as a tree. Raw shows its beginning.")
        }
        let analyzed = info.analyze == true
        switch (info.dialect ?? info.driver ?? "", info.format ?? "") {
        case ("sqlite", _):
            return sqlite(rows: info.rows ?? [])
        case ("pgsql", _):
            return try postgres(json: info.raw ?? "", analyzed: analyzed)
        case (_, "tree"):
            return mysqlTree(info.raw ?? "", analyzed: analyzed)
        case ("mysql", _), ("mariadb", _):
            return try mysql(json: info.raw ?? "", dialect: info.dialect == "mariadb" ? .mariadb : .mysql, analyzed: analyzed)
        default:
            throw SQLPlanParseError(description: "Runlet can't read plans of \(info.driver ?? "this database").")
        }
    }

    // MARK: Helpers

    static func json(_ text: String) throws -> Any {
        guard let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw SQLPlanParseError(description: "The database's plan isn't valid JSON.")
        }
        return value
    }

    /// A number from JSON: MySQL writes costs and percentages as strings ("1.20").
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber where !(number === kCFBooleanTrue || number === kCFBooleanFalse): number.doubleValue
        case let string as String: Double(string.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String: string.isEmpty ? nil : string
        case let number as NSNumber: number.stringValue
        case let strings as [Any]: strings.compactMap { string($0) }.joined(separator: ", ")
        default: nil
        }
    }

    // MARK: PostgreSQL

    /// `EXPLAIN (FORMAT JSON)`: `[{"Plan": {…, "Plans": […]}, "Planning Time": …, "Execution Time": …}]`.
    public static func postgres(json text: String, analyzed: Bool = false) throws -> SQLPlan {
        let value = try json(text)
        let top = (value as? [Any])?.first as? [String: Any] ?? value as? [String: Any]
        guard let top, let root = top["Plan"] as? [String: Any] else {
            throw SQLPlanParseError(description: "PostgreSQL's plan has no \"Plan\".")
        }
        let tree = postgresNode(root)
        return SQLPlan(dialect: .pgsql, tree: [tree], totalCost: number(root["Total Cost"]), planningMs: number(top["Planning Time"]), executionMs: number(top["Execution Time"]), analyzed: analyzed || top["Execution Time"] != nil)
    }

    static func postgresNode(_ object: [String: Any]) -> SQLPlan.TreeNode {
        let type = string(object["Node Type"]) ?? "Node"
        var operation = type
        switch type {
        case "Aggregate":
            switch string(object["Strategy"]) {
            case "Hashed": operation = "HashAggregate"
            case "Sorted": operation = "GroupAggregate"
            case "Mixed": operation = "MixedAggregate"
            default: break
            }
        case "ModifyTable":
            operation = string(object["Operation"]) ?? type
        case "SetOp":
            if let command = string(object["Command"]) { operation = "SetOp " + command }
        default:
            if let join = string(object["Join Type"]), join != "Inner", type.hasSuffix("Join") || type == "Nested Loop" {
                operation = type.hasSuffix(" Join") ? String(type.dropLast(5)) + " \(join) Join" : "\(type) \(join) Join"
            }
        }
        if object["Parallel Aware"] as? Bool == true { operation = "Parallel " + operation }
        if string(object["Scan Direction"]) == "Backward" { operation += " Backward" }
        var table: String?
        if let relation = string(object["Relation Name"]) {
            var name = relation
            if let schema = string(object["Schema"]), schema != "public" { name = schema + "." + relation }
            if let alias = string(object["Alias"]), alias != relation { name += " " + alias }
            table = name
        } else {
            table = string(object["CTE Name"]) ?? string(object["Function Name"])
        }
        var details: [String] = []
        if let name = string(object["Subplan Name"]) { details.append(name) }
        for key in ["Index Cond", "Recheck Cond", "Hash Cond", "Merge Cond", "Join Filter", "Filter", "Sort Key", "Group Key", "Presorted Key", "One-Time Filter", "Cache Key"] {
            if let value = string(object[key]) { details.append("\(key): \(value)") }
        }
        for key in ["Rows Removed by Filter", "Rows Removed by Index Recheck", "Rows Removed by Join Filter", "Heap Fetches"] {
            if let value = number(object[key]), value > 0 { details.append("\(key): \(SQLPlan.format(value))") }
        }
        if let method = string(object["Sort Method"]) {
            details.append("Sort Method: \(method)" + (number(object["Sort Space Used"]).map { ", \(SQLPlan.format($0)) kB" } ?? ""))
        }
        if object["Actual Loops"] != nil, number(object["Actual Loops"]) == 0 { details.append("Never executed") }
        let node = SQLPlan.Node(
            operation: operation,
            table: table,
            index: string(object["Index Name"]),
            rows: number(object["Plan Rows"]),
            cost: number(object["Total Cost"]),
            actualRows: number(object["Actual Rows"]),
            actualMs: number(object["Actual Total Time"]),
            loops: number(object["Actual Loops"]),
            details: details,
            fullScan: type == "Seq Scan"
        )
        let children = (object["Plans"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }.map(postgresNode)
        return SQLPlan.TreeNode(node: node, children: children)
    }

    // MARK: MySQL and MariaDB JSON

    /// `EXPLAIN FORMAT=JSON` (MySQL 5.6+, MariaDB), MariaDB's `ANALYZE FORMAT=JSON`, and MySQL
    /// 8.3+'s `explain_json_format_version=2` (an iterator tree of `operation` and `inputs`).
    public static func mysql(json text: String, dialect: SQLPlan.Dialect = .mysql, analyzed: Bool = false) throws -> SQLPlan {
        guard let root = try json(text) as? [String: Any] else {
            throw SQLPlanParseError(description: "The plan isn't a JSON object.")
        }
        if root["query_block"] == nil, root["operation"] != nil {
            return SQLPlan(dialect: dialect, tree: [mysqlIterator(root)], totalCost: number(root["estimated_total_cost"]), analyzed: analyzed)
        }
        guard let block = root["query_block"] as? [String: Any] else {
            throw SQLPlanParseError(description: "The plan has no \"query_block\".")
        }
        let tree = mysqlBlock(block, title: nil, top: true)
        let cost = number(block["cost"]) ?? number((block["cost_info"] as? [String: Any])?["query_cost"])
        var executionMs = number(block["r_total_time_ms"])
        if executionMs != nil, let optimization = number((root["query_optimization"] as? [String: Any])?["r_total_time_ms"]) { executionMs! += optimization }
        return SQLPlan(dialect: dialect, tree: tree, totalCost: cost, executionMs: executionMs, analyzed: analyzed || block["r_loops"] != nil)
    }

    /// The keys that hold more of the plan, in the order they are shown.
    static let mysqlStructure = [
        "message", "union_result", "ordering_operation", "grouping_operation", "duplicates_removal", "windowing", "filesort", "read_sorted_file",
        "temporary_table", "buffer_result", "nested_loop", "table", "block-nl-join", "materialized", "materialized_from_subquery",
        "query_specifications", "attached_subqueries", "subqueries", "select_list_subqueries", "having_subqueries", "order_by_subqueries",
        "group_by_subqueries", "optimized_away_subqueries", "update_value_subqueries", "query_block",
    ]

    /// A query block: a node of its own ("Select #2", "UNION #3", "Subquery #2") above what it
    /// holds; the outermost block shows its contents directly.
    static func mysqlBlock(_ block: [String: Any], title: String?, top: Bool = false) -> [SQLPlan.TreeNode] {
        let contents = mysqlContents(block)
        if top { return contents }
        let id = number(block["select_id"]).map { Int($0) }
        var label = string(block["operation"]) ?? title ?? "Select"
        if let id { label += " #\(id)" }
        var details: [String] = []
        if let having = string(block["having_condition"]) { details.append("Having: " + having) }
        if let outer = string(block["outer_ref_condition"]) { details.append("Outer reference: " + outer) }
        let node = SQLPlan.Node(operation: label, cost: number(block["cost"]) ?? number((block["cost_info"] as? [String: Any])?["query_cost"]), actualMs: number(block["r_total_time_ms"]), loops: number(block["r_loops"]), details: details)
        return [SQLPlan.TreeNode(node: node, children: contents)]
    }

    /// What an object holds: tables, operations, and subqueries, each a node.
    static func mysqlContents(_ object: [String: Any]) -> [SQLPlan.TreeNode] {
        var nodes: [SQLPlan.TreeNode] = []
        for key in mysqlStructure {
            guard let value = object[key] else { continue }
            switch key {
            case "message":
                if let message = string(value) { nodes.append(SQLPlan.TreeNode(node: SQLPlan.Node(operation: message))) }
            case "query_block":
                // A block nested in an operation (a subquery's, a union member's).
                if let block = value as? [String: Any] { nodes += mysqlBlock(block, title: object["dependent"] as? Bool == true ? "Dependent subquery" : nil) }
            case "nested_loop":
                let members = (value as? [Any] ?? []).compactMap { $0 as? [String: Any] }.flatMap(mysqlContents)
                if members.count > 1 {
                    nodes.append(SQLPlan.TreeNode(node: SQLPlan.Node(operation: "Nested loop join"), children: members))
                } else {
                    nodes += members
                }
            case "table":
                if let table = value as? [String: Any] { nodes.append(mysqlTable(table)) }
            case "query_specifications", "attached_subqueries", "subqueries", "select_list_subqueries", "having_subqueries", "order_by_subqueries", "group_by_subqueries", "optimized_away_subqueries", "update_value_subqueries":
                let title: String? = key == "query_specifications" ? nil : "Subquery"
                for entry in (value as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
                    if let block = entry["query_block"] as? [String: Any] {
                        nodes += mysqlBlock(block, title: entry["dependent"] as? Bool == true ? "Dependent subquery" : title.map { key == "optimized_away_subqueries" ? "Optimized-away subquery" : $0 })
                    } else {
                        nodes += mysqlContents(entry)
                    }
                }
            default:
                guard let operation = value as? [String: Any] else { continue }
                nodes.append(mysqlOperation(key, operation))
            }
        }
        return nodes
    }

    /// Sorting, grouping, temporary tables, unions, and other wrappers.
    static func mysqlOperation(_ key: String, _ object: [String: Any]) -> SQLPlan.TreeNode {
        var details: [String] = []
        var operation: String
        var table: String?
        var fullScan = false
        switch key {
        case "union_result":
            operation = "Union result"
            table = string(object["table_name"])
            if string(object["access_type"]) == "ALL" { details.append("Reads the union's temporary table") }
        case "ordering_operation":
            operation = object["using_filesort"] as? Bool == true ? "Sort (filesort)" : "Ordering"
        case "grouping_operation":
            operation = "Group"
        case "duplicates_removal":
            operation = "Remove duplicates"
        case "windowing":
            operation = "Window"
        case "filesort":
            operation = "Sort (filesort)"
        case "read_sorted_file":
            operation = "Read sorted file"
        case "temporary_table":
            operation = "Temporary table"
        case "buffer_result":
            operation = "Buffer result"
        case "block-nl-join":
            operation = "Block nested loop join"
            if let type = string(object["join_type"]) { details.append("Join type: " + type) }
        case "materialized", "materialized_from_subquery":
            operation = "Materialize"
        default:
            operation = key.replacingOccurrences(of: "_", with: " ").capitalized
        }
        if let sortKey = string(object["sort_key"]) { details.append("Sort key: " + sortKey) }
        if object["using_temporary_table"] as? Bool == true { details.append("Using a temporary table") }
        if let condition = string(object["attached_condition"]) { details.append("Condition: " + condition) }
        if let rows = number(object["r_output_rows"]) { details.append("Output rows: " + SQLPlan.format(rows)) }
        let children = mysqlContents(object)
        // A block nested loop join wraps the table it joins: show that table's access here.
        if key == "block-nl-join", children.count == 1, children[0].children.isEmpty {
            var joined = children[0].node
            joined.details = details + joined.details
            joined.operation = "Block nested loop join: " + joined.operation
            fullScan = joined.fullScan
            return SQLPlan.TreeNode(node: joined, children: [])
        }
        let node = SQLPlan.Node(operation: operation, table: table, cost: number((object["cost_info"] as? [String: Any])?["sort_cost"]), actualMs: number(object["r_total_time_ms"]), loops: number(object["r_loops"]), details: details, fullScan: fullScan)
        return SQLPlan.TreeNode(node: node, children: children)
    }

    /// How a table is read, by `access_type`.
    static func mysqlAccess(_ type: String?) -> String {
        switch type {
        case "ALL": "Full table scan"
        case "hash_ALL": "Hash join, full table scan"
        case "index": "Full index scan"
        case "hash_index": "Hash join, full index scan"
        case "range": "Index range scan"
        case "hash_range": "Hash join, index range scan"
        case "ref": "Index lookup"
        case "hash_ref": "Hash join, index lookup"
        case "eq_ref": "Unique index lookup"
        case "ref_or_null": "Index lookup (or NULL)"
        case "const": "Single row (constant)"
        case "system": "Single row (system)"
        case "fulltext": "Full-text search"
        case "index_merge": "Index merge"
        case "unique_subquery": "Unique subquery lookup"
        case "index_subquery": "Subquery index lookup"
        case nil: "Table"
        case let other?: other
        }
    }

    static func mysqlTable(_ table: [String: Any]) -> SQLPlan.TreeNode {
        if let message = string(table["message"]), table["table_name"] == nil {
            return SQLPlan.TreeNode(node: SQLPlan.Node(operation: message))
        }
        let access = string(table["access_type"])
        var operation = mysqlAccess(access)
        if table["update"] != nil || table["delete"] != nil {
            operation = (table["delete"] != nil ? "Delete" : "Update") + ": " + operation.prefix(1).lowercased() + operation.dropFirst()
        } else if table["insert"] != nil {
            operation = "Insert"
        }
        var details: [String] = []
        if let message = string(table["message"]) { details.append(message) }
        if let condition = string(table["attached_condition"]) { details.append("Condition: " + condition) }
        if let index = string(table["index_condition"]) { details.append("Index condition: " + index) }
        if let parts = string(table["used_key_parts"]) { details.append("Key parts: " + parts) }
        if let ref = string(table["ref"]) { details.append("Ref: " + ref) }
        if let possible = string(table["possible_keys"]), table["key"] == nil { details.append("Possible keys (none used): " + possible) }
        if table["using_index"] as? Bool == true { details.append("Using index (covering)") }
        if table["using_join_buffer"] != nil, let buffer = string(table["using_join_buffer"]) { details.append("Join buffer: " + buffer) }
        if let filtered = number(table["filtered"]), filtered < 100 { details.append("Filtered: " + SQLPlan.format(filtered) + "%") }
        if let rows = number(table["rows_produced_per_join"]) { details.append("Rows per join: " + SQLPlan.format(rows)) }
        if let merge = table["index_merge"] as? [String: Any], let first = merge.keys.sorted().first { details.append("Index merge: " + first) }
        var cost: Double?
        if let info = table["cost_info"] as? [String: Any] {
            if let read = number(info["read_cost"]), let eval = number(info["eval_cost"]) { cost = read + eval } else { cost = number(info["prefix_cost"]) }
        } else {
            cost = number(table["cost"])
        }
        var actualMs: Double?
        if let total = number(table["r_total_time_ms"]) {
            actualMs = total
        } else if let tableMs = number(table["r_table_time_ms"]) {
            actualMs = tableMs + (number(table["r_other_time_ms"]) ?? 0)
        }
        let node = SQLPlan.Node(
            operation: operation,
            table: string(table["table_name"]),
            index: string(table["key"]),
            rows: number(table["rows_examined_per_scan"]) ?? number(table["rows"]),
            cost: cost,
            actualRows: number(table["r_rows"]),
            actualMs: actualMs,
            loops: number(table["r_loops"]),
            details: details,
            fullScan: access == "ALL" || access == "hash_ALL"
        )
        var inside = table
        inside["message"] = nil
        return SQLPlan.TreeNode(node: node, children: mysqlContents(inside))
    }

    /// MySQL 8.3+'s JSON format version 2: `{"operation": "Table scan on t", "access_type": "table", "inputs": […]}`.
    static func mysqlIterator(_ object: [String: Any]) -> SQLPlan.TreeNode {
        var operation = string(object["operation"]) ?? "Step"
        var details: [String] = []
        if let condition = string(object["condition"]) {
            // "Filter: (c.country = 'UK')": the condition goes to the details.
            if let colon = operation.range(of: ": ") { operation = String(operation[..<colon.lowerBound]) }
            details.append("Condition: " + condition)
        }
        let node = SQLPlan.Node(
            operation: operation,
            table: string(object["table_name"]),
            index: string(object["index_name"]),
            rows: number(object["estimated_rows"]),
            cost: number(object["estimated_total_cost"]),
            actualRows: number(object["actual_rows"]),
            actualMs: number(object["actual_last_row_ms"]),
            loops: number(object["actual_loops"]),
            details: details,
            fullScan: (string(object["access_type"]) == "table" || operation.hasPrefix("Table scan on")) && !(string(object["table_name"]) ?? "").hasPrefix("<")
        )
        let children = (object["inputs"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }.map(mysqlIterator)
        return SQLPlan.TreeNode(node: node, children: children)
    }

    // MARK: MySQL's tree (EXPLAIN ANALYZE)

    /// MySQL 8.0.18+'s `EXPLAIN ANALYZE` (and `FORMAT=TREE`): one line per step, indented by
    /// four spaces a level:
    /// `-> Table scan on t1  (cost=1.15 rows=9) (actual time=0.081..0.093 rows=9 loops=1)`.
    public static func mysqlTree(_ text: String, analyzed: Bool = true) -> SQLPlan {
        var roots: [SQLPlan.TreeNode] = []
        // The path of open nodes: (indent, node).
        var stack: [(indent: Int, node: SQLPlan.TreeNode)] = []
        func close(downTo indent: Int) {
            while let last = stack.last, last.indent >= indent {
                stack.removeLast()
                if stack.isEmpty { roots.append(last.node) } else { stack[stack.count - 1].node.children.append(last.node) }
            }
        }
        for line in text.components(separatedBy: "\n") {
            let indent = line.prefix { $0 == " " }.count
            let content = line.dropFirst(indent)
            guard content.hasPrefix("->") else {
                // A long condition continues on the next line.
                let more = content.trimmingCharacters(in: .whitespaces)
                if !more.isEmpty, !stack.isEmpty {
                    let last = stack.count - 1
                    if stack[last].node.node.details.isEmpty { stack[last].node.node.details.append(more) } else { stack[last].node.node.details[stack[last].node.node.details.count - 1] += " " + more }
                }
                continue
            }
            close(downTo: indent)
            stack.append((indent, SQLPlan.TreeNode(node: mysqlTreeNode(content.dropFirst(2).trimmingCharacters(in: .whitespaces)))))
        }
        close(downTo: 0)
        return SQLPlan(dialect: .mysql, tree: roots, totalCost: roots.first?.node.cost, analyzed: analyzed)
    }

    static func mysqlTreeNode(_ line: String) -> SQLPlan.Node {
        var operation = line
        var rows: Double?, cost: Double?, actualRows: Double?, actualMs: Double?, loops: Double?
        var details: [String] = []
        // Trailing "(cost=… rows=…)" and "(actual time=a..b rows=… loops=…)" groups, last first.
        while operation.hasSuffix(")"), let open = operation.range(of: " (", options: .backwards) {
            let group = operation[open.upperBound..<operation.index(before: operation.endIndex)]
            let fields = Dictionary(group.split(separator: " ").compactMap { part -> (String, String)? in
                let pair = part.split(separator: "=", maxSplits: 1)
                return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
            }, uniquingKeysWith: { first, _ in first })
            if group.hasPrefix("cost=") || group.hasPrefix("rows=") {
                cost = fields["cost"].flatMap { Double($0) }
                rows = fields["rows"].flatMap { Double($0) }
            } else if group.hasPrefix("actual time=") || group.hasPrefix("actual rows=") {
                actualMs = fields["time"].flatMap { $0.components(separatedBy: "..").last }.flatMap { Double($0) }
                actualRows = fields["rows"].flatMap { Double($0) }
                loops = fields["loops"].flatMap { Double($0) }
            } else if group == "never executed" {
                details.append("Never executed")
            } else {
                break
            }
            operation = String(operation[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        var table: String?
        var index: String?
        if let on = operation.range(of: " on ") {
            // "Index lookup on i using idx (customer_id=c.id)": the step, its table and index,
            // and what is left (the lookup's key) as a detail.
            var rest = Substring(operation[on.upperBound...])
            operation = String(operation[..<on.lowerBound])
            table = rest.split(separator: " ").first.map(String.init)
            rest = rest.dropFirst(table?.count ?? 0)
            if rest.hasPrefix(" using ") {
                rest = rest.dropFirst(7)
                index = rest.split(separator: " ").first.map(String.init)
                rest = rest.dropFirst(index?.count ?? 0)
            }
            let remainder = rest.trimmingCharacters(in: .whitespaces)
            if !remainder.isEmpty { details.insert(remainder, at: 0) }
        } else if let colon = operation.range(of: ": ") {
            // Long conditions stay in the details: "Filter: (t.a = 1)".
            details.insert(String(operation[colon.upperBound...]), at: 0)
            operation = String(operation[..<colon.lowerBound])
        }
        let fullScan = operation == "Table scan" && !(table ?? "").hasPrefix("<")
        return SQLPlan.Node(operation: operation, table: table, index: index, rows: rows, cost: cost, actualRows: actualRows, actualMs: actualMs, loops: loops, details: details, fullScan: fullScan)
    }

    // MARK: SQLite

    /// `EXPLAIN QUERY PLAN` rows `[id, parent, detail]`: "SCAN orders", "SEARCH c USING INDEX
    /// … (id=?)", "USE TEMP B-TREE FOR ORDER BY". SQLite gives no row or cost estimates. Rows
    /// from SQLite before 3.24 have no parent and stay flat.
    public static func sqlite(rows: [[SQLCell]]) -> SQLPlan {
        var nodes: [(id: Int64, parent: Int64, tree: SQLPlan.TreeNode)] = []
        for row in rows {
            guard row.count >= 3 else { continue }
            let id: Int64 = if case .int(let value) = row[0] { value } else { Int64(nodes.count + 1) }
            let parent: Int64 = if case .int(let value) = row[1] { value } else { 0 }
            nodes.append((id, parent, SQLPlan.TreeNode(node: sqliteNode(row[2].text))))
        }
        // Attach children to parents, from the last row up, so each subtree is complete first.
        var attached = Set<Int>()
        for index in nodes.indices.reversed() where nodes[index].parent != 0 {
            if let parent = nodes[..<index].lastIndex(where: { $0.id == nodes[index].parent }) {
                nodes[parent].tree.children.insert(nodes[index].tree, at: 0)
                attached.insert(index)
            }
        }
        let roots = nodes.indices.filter { !attached.contains($0) }.map { nodes[$0].tree }
        return SQLPlan(dialect: .sqlite, tree: roots)
    }

    static func sqliteNode(_ detail: String) -> SQLPlan.Node {
        var words = detail.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = words.first, first == "SCAN" || first == "SEARCH" else {
            return SQLPlan.Node(operation: detail)
        }
        words.removeFirst()
        // SQLite before 3.36 wrote "SCAN TABLE orders".
        if words.first == "TABLE" { words.removeFirst() }
        if words.starts(with: ["CONSTANT", "ROW"]) { return SQLPlan.Node(operation: detail) }
        var table = words.isEmpty ? nil : words.removeFirst()
        // "SCAN orders AS o" (older SQLite).
        if words.first == "AS", words.count > 1 {
            words.removeFirst()
            table = (table ?? "") + " " + words.removeFirst()
        }
        var index: String?
        var details: [String] = []
        var rest = words.joined(separator: " ")
        for prefix in ["USING COVERING INDEX ", "USING INDEX ", "USING AUTOMATIC COVERING INDEX ", "USING AUTOMATIC PARTIAL COVERING INDEX ", "USING AUTOMATIC INDEX "] where rest.hasPrefix(prefix) {
            let after = rest.dropFirst(prefix.count)
            let name = after.prefix { $0 != " " }
            index = String(name)
            if prefix.contains("COVERING") { details.append(prefix.contains("AUTOMATIC") ? "Automatic covering index" : "Covering index") } else if prefix.contains("AUTOMATIC") { details.append("Automatic index") }
            rest = after.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
            break
        }
        for key in ["USING INTEGER PRIMARY KEY", "USING PRIMARY KEY", "USING ROWID SEARCH"] where rest.hasPrefix(key) {
            index = String(key.dropFirst(6))
            rest = rest.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            break
        }
        if !rest.isEmpty { details.append(rest) }
        let subquery = table.map { $0.hasPrefix("(") || $0.uppercased() == "SUBQUERY" } ?? true
        return SQLPlan.Node(operation: first, table: table, index: index, details: details, fullScan: first == "SCAN" && index == nil && !subquery)
    }
}
