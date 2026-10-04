import CoreGraphics
import Foundation
import Testing
@testable import RunletCore

/// The relations diagram (#153): relations and graphs from a loaded schema, the layout, Copy Join,
/// and the SVG export.
struct SQLRelationsTests {
    typealias Table = SQLSchemaInfo.Table
    typealias Column = SQLSchemaInfo.Column

    /// A small shop: orders reference customers; order lines reference orders and products;
    /// shipments reference an order line by its composite key; employees reference themselves;
    /// addresses reference customers; reviews reference products.
    static let shop = SQLSchemaInfo(driver: "sqlite", tables: [
        Table(name: "addresses", columns: [Column(name: "id", primaryKey: true), Column(name: "customer_id", references: "customers.id"), Column(name: "city")],
              foreignKeys: [.init(name: "0", columns: ["customer_id"], references: "customers", referencedColumns: ["id"])]),
        Table(name: "customers", columns: [Column(name: "id", type: "integer", primaryKey: true), Column(name: "email", type: "text"), Column(name: "name", type: "text")]),
        Table(name: "employees", columns: [Column(name: "id", primaryKey: true), Column(name: "manager_id", references: "employees.id"), Column(name: "name")],
              foreignKeys: [.init(name: "employees_manager", columns: ["manager_id"], references: "employees", referencedColumns: ["id"])]),
        Table(name: "order_lines", columns: [Column(name: "order_id", primaryKey: true, references: "orders.id"), Column(name: "line_no", primaryKey: true), Column(name: "product_id", references: "products.id"), Column(name: "qty")],
              indexes: [.init(name: "pk", columns: ["order_id", "line_no"], unique: true, primary: true)],
              foreignKeys: [.init(name: "0", columns: ["product_id"], references: "products", referencedColumns: ["id"]),
                            .init(name: "1", columns: ["order_id"], references: "orders", referencedColumns: ["id"])]),
        Table(name: "orders", columns: [Column(name: "id", type: "integer", primaryKey: true), Column(name: "customer_id", type: "integer", references: "customers.id"),
                                        Column(name: "sold_by", references: "employees.id"), Column(name: "status", type: "text")],
              foreignKeys: [.init(name: "0", columns: ["customer_id"], references: "customers", referencedColumns: ["id"]),
                            .init(name: "1", columns: ["sold_by"], references: "employees", referencedColumns: ["id"])]),
        Table(name: "products", columns: [Column(name: "id", primaryKey: true), Column(name: "sku"), Column(name: "title")]),
        Table(name: "reviews", columns: [Column(name: "id", primaryKey: true), Column(name: "product_id", references: "products.id")],
              foreignKeys: [.init(name: "0", columns: ["product_id"], references: "products", referencedColumns: ["id"])]),
        Table(name: "shipments", columns: [Column(name: "id", primaryKey: true), Column(name: "order_id", references: "order_lines.order_id"), Column(name: "line_no", references: "order_lines.line_no")],
              foreignKeys: [.init(name: "0", columns: ["order_id", "line_no"], references: "order_lines", referencedColumns: ["order_id", "line_no"])]),
    ])

    // MARK: Relations

    @Test func relationsFromNamedConstraints() {
        let relations = SQLRelations.relations(in: Self.shop)
        #expect(relations.map(\.summary) == [
            "addresses.customer_id → customers.id",
            "employees.manager_id → employees.id",
            "order_lines.order_id → orders.id",
            "order_lines.product_id → products.id",
            "orders.customer_id → customers.id",
            "orders.sold_by → employees.id",
            "reviews.product_id → products.id",
            "shipments(order_id, line_no) → order_lines(order_id, line_no)",
        ])
        let composite = relations.last!
        #expect(composite.isComposite && composite.isComplete)
        #expect(composite.label == "order_id → order_id\nline_no → line_no", "one line, every column pair")
        #expect(relations[1].isSelfReference)
        #expect(relations[1].displayName == "employees_manager")
        #expect(relations[0].displayName == nil, "SQLite numbers its constraints")
    }

    @Test func relationsFromColumnReferencesAlone() {
        // A driver's sqlSchema() gives only each column's references: columns that together
        // reference a composite primary key are one relation; two keys to one table stay two.
        let schema = SQLSchemaInfo(tables: [
            Table(name: "lines", columns: [Column(name: "order_id", primaryKey: true), Column(name: "no", primaryKey: true)]),
            Table(name: "notes", columns: [Column(name: "id"), Column(name: "line_no", references: "lines.no"), Column(name: "line_order", references: "lines.order_id")]),
            Table(name: "users", columns: [Column(name: "id", primaryKey: true)]),
            Table(name: "messages", columns: [Column(name: "sender_id", references: "users.id"), Column(name: "recipient_id", references: "users.id"), Column(name: "owner", references: "users")]),
        ])
        let relations = SQLRelations.relations(in: schema)
        #expect(relations.map(\.summary) == [
            "messages.owner → users.id",
            "messages.recipient_id → users.id",
            "messages.sender_id → users.id",
            "notes(line_order, line_no) → lines(order_id, no)",
        ])
    }

    @Test func missingReferencedTablesAndUnknownColumns() {
        let schema = SQLSchemaInfo(tables: [
            Table(name: "invoices", columns: [Column(name: "id", primaryKey: true), Column(name: "account_id", references: "billing.accounts.id")],
                  foreignKeys: [.init(name: "invoices_account", columns: ["account_id"], references: "billing.accounts", referencedColumns: ["id"])]),
            Table(name: "payments", columns: [Column(name: "invoice_id", references: "invoices")],
                  foreignKeys: [.init(name: "0", columns: ["invoice_id"], references: "invoices")]),
            Table(name: "refunds", columns: [Column(name: "ledger", references: "ledger")],
                  foreignKeys: [.init(name: "0", columns: ["ledger"], references: "ledger")]),
        ])
        let relations = SQLRelations.relations(in: schema)
        #expect(relations.map(\.summary) == ["invoices.account_id → billing.accounts.id", "payments.invoice_id → invoices.id", "refunds.ledger → ledger.?"],
                "SQLite's REFERENCES invoices means its primary key")
        #expect(relations[2].isComplete == false)
        #expect(SQLRelations.join(relations[2], joining: "ledger", driver: "sqlite") == nil)

        let graph = try! #require(SQLRelations.graph(of: "invoices", in: schema, hops: 1))
        #expect(graph.nodes.map(\.name) == ["invoices", "billing.accounts", "payments"])
        #expect(graph.node("billing.accounts")?.isMissing == true)
        let layout = SQLRelationsLayout.make(graph)
        #expect(layout.box("billing.accounts")?.rows == [.init(name: "id"), .init(name: "", note: "not in the loaded schema")])
        #expect(SQLRelations.graph(of: "nothing", in: schema, hops: 1) == nil)
    }

    @Test func schemaQualifiedNamesOnPostgreSQL() {
        let schema = SQLSchemaInfo(driver: "pgsql", tables: [
            Table(name: "customers", columns: [Column(name: "id", primaryKey: true)]),
            Table(name: "sales.Orders", columns: [Column(name: "id", primaryKey: true), Column(name: "customerId", references: "customers.id")],
                  foreignKeys: [.init(name: "orders_customer", columns: ["customerId"], references: "customers", referencedColumns: ["id"])]),
            Table(name: "sales.customers", columns: [Column(name: "id", primaryKey: true)]),
            Table(name: "audit.events", columns: [Column(name: "order_id", references: "sales.Orders.id")],
                  foreignKeys: [.init(name: "events_order", columns: ["order_id"], references: "sales.Orders", referencedColumns: ["id"])]),
        ])
        let graph = try! #require(SQLRelations.graph(of: "sales.orders", in: schema, hops: 1))
        #expect(graph.focus == "sales.Orders", "found ignoring case")
        #expect(graph.nodes.map(\.name) == ["sales.Orders", "customers", "audit.events"], "customers is not sales.customers")
        let toCustomers = graph.relations.first { $0.to == "customers" }!
        #expect(SQLRelations.join(toCustomers, joining: "customers", driver: "pgsql") == #"JOIN customers ON customers.id = sales."Orders"."customerId""#)
        let fromEvents = graph.relations.first { $0.from == "audit.events" }!
        #expect(SQLRelations.join(fromEvents, joining: "audit.events", driver: "pgsql") == #"JOIN audit.events ON audit.events.order_id = sales."Orders".id"#)
    }

    // MARK: Graphs

    @Test func oneHop() throws {
        let graph = try #require(SQLRelations.graph(of: "orders", in: Self.shop, hops: 1))
        #expect(graph.nodes.map(\.name) == ["orders", "customers", "employees", "order_lines"])
        #expect(graph.nodes.map(\.side) == [.focus, .referenced, .referenced, .referencing])
        #expect(graph.nodes.map(\.hop) == [0, 1, 1, 1])
        // The employees self-reference comes along, since both ends are in the graph.
        #expect(graph.relations.map(\.summary) == [
            "employees.manager_id → employees.id",
            "order_lines.order_id → orders.id",
            "orders.customer_id → customers.id",
            "orders.sold_by → employees.id",
        ])
    }

    @Test func twoHops() throws {
        let graph = try #require(SQLRelations.graph(of: "orders", in: Self.shop, hops: 2))
        #expect(graph.nodes.map(\.name) == ["orders", "customers", "employees", "addresses", "order_lines", "products", "shipments"])
        let addresses = try #require(graph.node("addresses"))
        #expect(addresses.hop == 2 && addresses.side == .referenced && addresses.via == "customers", "reached from customers, on its side")
        #expect(graph.node("products")?.side == .referencing && graph.node("shipments")?.via == "order_lines")
        #expect(graph.node("reviews") == nil, "three hops away")
        #expect(graph.relations.count == 7)
    }

    @Test func selfReferenceAsFocus() throws {
        let graph = try #require(SQLRelations.graph(of: "employees", in: Self.shop, hops: 1))
        #expect(graph.nodes.map(\.name) == ["employees", "orders"])
        let layout = SQLRelationsLayout.make(graph)
        let loop = try #require(layout.edges.first { $0.relation?.isSelfReference == true })
        #expect(loop.isLoop)
        let box = try #require(layout.box("employees"))
        #expect(loop.start.x == box.frame.maxX && loop.end.x == box.frame.maxX, "a loop on the focus's right side")
        #expect(loop.control1.x > box.frame.maxX)
        #expect(loop.start.y != loop.end.y, "from manager_id to id")
    }

    // MARK: Layout

    @Test func layoutIsLayeredAndDeterministic() throws {
        let graph = try #require(SQLRelations.graph(of: "orders", in: Self.shop, hops: 2))
        let layout = SQLRelationsLayout.make(graph)
        #expect(layout == SQLRelationsLayout.make(graph), "the same layout every time")
        func x(_ name: String) throws -> CGFloat { try #require(layout.box(name)).frame.midX }
        #expect(try x("addresses") < x("customers"))
        #expect(try x("customers") < x("orders"))
        #expect(try x("customers") == x("employees"))
        #expect(try x("orders") < x("order_lines"))
        #expect(try x("order_lines") < x("products"))
        #expect(try x("products") == x("shipments"))
        // Nothing overlaps.
        for a in layout.boxes {
            for b in layout.boxes where a.id < b.id { #expect(!a.frame.intersects(b.frame), "\(a.id) and \(b.id)") }
            #expect(a.frame.minX >= 0 && a.frame.maxX <= layout.size.width && a.frame.maxY <= layout.size.height)
        }
        // Keys only: orders shows id, customer_id, sold_by, and a note for status.
        #expect(layout.box("orders")?.rows.map { $0.note ?? $0.name } == ["id", "customer_id", "sold_by", "1 more column"])
        #expect(layout.box("orders")?.rows.first?.isPrimaryKey == true && layout.box("orders")?.rows[1].isForeignKey == true)
        let all = SQLRelationsLayout.make(graph, allColumns: true)
        #expect(all.box("orders")?.rows.map(\.name) == ["id", "customer_id", "sold_by", "status"])
        // The composite key is one line with both pairs, between the two rows' middle.
        let composite = try #require(layout.edges.first { $0.relation?.isComposite == true })
        #expect(composite.label == "order_id → order_id\nline_no → line_no")
        let lines = try #require(layout.box("order_lines"))
        #expect(composite.end.y == (lines.rowCenter(0) + lines.rowCenter(1)) / 2)
        #expect(composite.start.x > composite.end.x, "shipments is right of order_lines")
    }

    /// A focus with `referencing` tables that reference it and `referenced` it references.
    func star(referencing: Int, referenced: Int, hop2: Int = 0) -> SQLSchemaInfo {
        var tables = [Table(name: "hub", columns: [Column(name: "id", primaryKey: true)] + (0..<referenced).map { Column(name: "p\($0)_id", references: "parent_\(String(format: "%02d", $0)).id") })]
        tables += (0..<referenced).map { Table(name: "parent_\(String(format: "%02d", $0))", columns: [Column(name: "id", primaryKey: true)]) }
        tables += (0..<referencing).map { Table(name: "child_\(String(format: "%02d", $0))", columns: [Column(name: "id", primaryKey: true), Column(name: "hub_id", references: "hub.id")]) }
        tables += (0..<hop2).map { Table(name: "grandchild_\(String(format: "%02d", $0))", columns: [Column(name: "child_id", references: "child_00.id")]) }
        return SQLSchemaInfo(driver: "mysql", tables: tables)
    }

    @Test func fiftyRelatedTablesStayExpanded() throws {
        let graph = try #require(SQLRelations.graph(of: "hub", in: star(referencing: 40, referenced: 10), hops: 1))
        #expect(graph.relatedCount == 50)
        let layout = SQLRelationsLayout.make(graph)
        #expect(layout.groups.isEmpty && layout.boxes.count == 51)
    }

    @Test func collapsesPastFiftyAndExpandsOnRequest() throws {
        let graph = try #require(SQLRelations.graph(of: "hub", in: star(referencing: 60, referenced: 3, hop2: 5), hops: 2))
        #expect(graph.relatedCount == 68)
        let layout = SQLRelationsLayout.make(graph)
        // Hop 1 shares the 50 first: 3 referenced and 47 referencing; hop 2 gets nothing.
        #expect(layout.boxes.count == 51)
        #expect(layout.groups.map(\.id) == ["referencing-1", "referencing-2"])
        #expect(layout.groups.map(\.tables.count) == [13, 5])
        #expect(layout.groups[0].tables.first == "child_47", "the first tables by name stay")
        #expect(layout.hiddenCount == 18)
        #expect(layout.summary == "69 tables · 68 foreign keys · 18 collapsed")
        // One dashed line per group and table, standing for all their keys.
        let groupLines = layout.edges.filter { $0.relation == nil }
        #expect(groupLines.map(\.id) == ["group\u{1F}referencing-1\u{1F}hub", "group\u{1F}referencing-2\u{1F}child_00"])
        #expect(groupLines.map(\.count) == [13, 5] && groupLines.allSatisfy { $0.label == nil })
        #expect(layout == SQLRelationsLayout.make(graph))

        let expanded = SQLRelationsLayout.make(graph, expanded: ["referencing-1"])
        #expect(expanded.groups.map(\.id) == ["referencing-2"], "expanding shows the group, and keeps the others as they were")
        #expect(expanded.boxes.count == 64)
        #expect(expanded.box("child_59") != nil && expanded.box("parent_02") != nil)
    }

    @Test func fairShares() {
        #expect(SQLRelationsLayout.fairShares([3, 60], budget: 50) == [3, 47])
        #expect(SQLRelationsLayout.fairShares([30, 30], budget: 50) == [25, 25])
        #expect(SQLRelationsLayout.fairShares([30, 31, 5], budget: 50) == [23, 22, 5])
        #expect(SQLRelationsLayout.fairShares([2, 2], budget: 10) == [2, 2])
        #expect(SQLRelationsLayout.fairShares([4, 4], budget: 0) == [0, 0])
    }

    // MARK: Copy Join

    @Test func joinsPerDriver() throws {
        let relations = SQLRelations.relations(in: Self.shop)
        let orders = try #require(relations.first { $0.summary == "orders.customer_id → customers.id" })
        #expect(SQLRelations.join(orders, joining: "customers", driver: "sqlite") == "JOIN customers ON customers.id = orders.customer_id")
        #expect(SQLRelations.join(orders, joining: "orders", driver: "mysql") == "JOIN orders ON orders.customer_id = customers.id")
        let composite = try #require(relations.first { $0.isComposite })
        #expect(SQLRelations.join(composite, joining: "order_lines", driver: "pgsql")
            == "JOIN order_lines ON order_lines.order_id = shipments.order_id AND order_lines.line_no = shipments.line_no")
        let manager = try #require(relations.first { $0.isSelfReference })
        #expect(SQLRelations.join(manager, joining: "employees", driver: "sqlite") == "JOIN employees AS manager ON manager.id = employees.manager_id")
        #expect(SQLRelations.join(manager, joining: "employees", driver: "oci") == "JOIN employees manager ON manager.id = employees.manager_id")
        #expect(SQLRelations.join(orders, joining: "products", driver: "sqlite") == nil)

        // Quoting as the explorer quotes: keywords, spaces, and upper case on PostgreSQL.
        let odd = SQLRelations.Relation(from: "Order Lines", columns: ["order"], to: "Orders", referencedColumns: ["Id"])
        #expect(SQLRelations.join(odd, joining: "Orders", driver: "mysql") == "JOIN Orders ON Orders.Id = `Order Lines`.`order`")
        #expect(SQLRelations.join(odd, joining: "Orders", driver: "pgsql") == #"JOIN "Orders" ON "Orders"."Id" = "Order Lines"."order""#)
        #expect(SQLRelations.join(odd, joining: "Order Lines", driver: "sqlsrv") == #"JOIN "Order Lines" ON "Order Lines"."order" = Orders.Id"#)
        let parent = SQLRelations.Relation(from: "nodes", columns: ["parent"], to: "nodes", referencedColumns: ["id"])
        #expect(SQLRelations.join(parent, joining: "nodes", driver: "sqlite") == "JOIN nodes AS parent ON parent.id = nodes.parent")
    }

    @Test func copyJoinAddsTheTableFurtherOut() throws {
        let graph = try #require(SQLRelations.graph(of: "orders", in: Self.shop, hops: 2))
        let lines = try #require(graph.relations.first { $0.from == "order_lines" && $0.to == "orders" })
        #expect(SQLRelations.joinedTable(lines, in: graph) == "order_lines", "orders is the focus")
        let customers = try #require(graph.relations.first { $0.from == "orders" })
        #expect(SQLRelations.joinedTable(customers, in: graph) == "customers")
        let addresses = try #require(graph.relations.first { $0.from == "addresses" })
        #expect(SQLRelations.joinedTable(addresses, in: graph) == "addresses", "hop 2 joins onto hop 1")
    }

    // MARK: SVG

    @Test func svgIsWellFormedXML() throws {
        var schema = Self.shop
        schema.tables.append(Table(name: "odd<&>\"'names", columns: [Column(name: "a&b", type: "text<1>", references: "orders.id")]))
        let graph = try #require(SQLRelations.graph(of: "orders", in: schema, hops: 2))
        let layout = SQLRelationsLayout.make(graph, allColumns: true)
        let svg = SQLRelationsSVG.render(layout)
        let data = try #require(svg.data(using: .utf8))
        let parser = XMLParser(data: data)
        let counter = ElementCounter()
        parser.delegate = counter
        #expect(parser.parse(), "\(parser.parserError.map { "\($0)" } ?? "")")
        #expect(counter.counts["svg"] == 1)
        #expect(counter.counts["path"] == layout.edges.count)
        #expect(counter.counts["polygon"] == layout.edges.count)
        #expect(counter.counts["g", default: 0] >= layout.boxes.count)
        #expect(counter.texts.contains("odd<&>\"'names"), "names are escaped, then read back")
        #expect(svg.contains(#"width="\#(SQLRelationsSVG.n(layout.size.width))""#))
        #expect(svg == SQLRelationsSVG.render(layout), "deterministic")
        // Group boxes for collapsed tables.
        let star = try #require(SQLRelations.graph(of: "hub", in: star(referencing: 60, referenced: 0), hops: 1))
        let collapsed = SQLRelationsSVG.render(SQLRelationsLayout.make(star))
        let starParser = XMLParser(data: Data(collapsed.utf8))
        #expect(starParser.parse())
        #expect(collapsed.contains("+10 more") && collapsed.contains("tables referencing it"))
    }

    @Test func numbersIgnoreTheLocale() {
        #expect(SQLRelationsSVG.n(12) == "12")
        #expect(SQLRelationsSVG.n(12.345) == "12.3")
        #expect(SQLRelationsSVG.n(-0.04) == "0" || SQLRelationsSVG.n(-0.04) == "-0")
        #expect(SQLRelationsSVG.escape("a\u{1}b") == "a\u{FFFD}b")
    }

    final class ElementCounter: NSObject, XMLParserDelegate {
        var counts: [String: Int] = [:]
        var texts: [String] = []
        private var current = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            counts[elementName, default: 0] += 1
            if elementName == "text" { current = "" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { current += string }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            if elementName == "text" { texts.append(current) }
        }
    }
}
