import Foundation
@testable import RunletCore
import Testing
@testable import RunletExecution

/// The relations diagram (#153) on live MariaDB and PostgreSQL: the catalog's foreign key
/// constraints (a composite key, a self-reference, two keys to one table) and the graph built from
/// them. `p153_` tables only, created again each run. Runs only when `RUNLET_TEST_MYSQL` /
/// `RUNLET_TEST_PGSQL` are set (see `SQLLiveDatabaseTests`).
@Suite(.serialized, .enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct SQLRelationsLiveTests {
    typealias Server = SQLLiveDatabaseTests.Server

    static func setup(_ server: Server) throws {
        let mysql = server.dialect == "mysql"
        let engine = mysql ? " ENGINE=InnoDB" : ""
        let statements = [
            "DROP TABLE IF EXISTS p153_shipments, p153_order_lines, p153_orders, p153_employees, p153_customers",
            "CREATE TABLE p153_customers (id INT PRIMARY KEY, email VARCHAR(190) NOT NULL UNIQUE)\(engine)",
            "CREATE TABLE p153_employees (id INT PRIMARY KEY, manager_id INT, CONSTRAINT p153_employees_manager FOREIGN KEY (manager_id) REFERENCES p153_employees (id))\(engine)",
            "CREATE TABLE p153_orders (id INT PRIMARY KEY, customer_id INT NOT NULL, billing_email VARCHAR(190), sold_by INT, approved_by INT,"
                + " CONSTRAINT p153_orders_customer FOREIGN KEY (customer_id) REFERENCES p153_customers (id),"
                + " CONSTRAINT p153_orders_billing FOREIGN KEY (billing_email) REFERENCES p153_customers (email),"
                + " CONSTRAINT p153_orders_seller FOREIGN KEY (sold_by) REFERENCES p153_employees (id),"
                + " CONSTRAINT p153_orders_approver FOREIGN KEY (approved_by) REFERENCES p153_employees (id))\(engine)",
            "CREATE TABLE p153_order_lines (order_id INT NOT NULL, line_no INT NOT NULL, PRIMARY KEY (order_id, line_no),"
                + " CONSTRAINT p153_lines_order FOREIGN KEY (order_id) REFERENCES p153_orders (id))\(engine)",
            "CREATE TABLE p153_shipments (id INT PRIMARY KEY, line_no INT NOT NULL, order_id INT NOT NULL,"
                + " CONSTRAINT p153_shipments_line FOREIGN KEY (order_id, line_no) REFERENCES p153_order_lines (order_id, line_no))\(engine)",
        ]
        for statement in statements { _ = try server.exec(statement) }
    }

    @Test(.enabled(if: !SQLLiveDatabaseTests.servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func foreignKeyConstraints() async throws {
        for server in SQLLiveDatabaseTests.servers {
            try Self.setup(server)
            let directory = try server.project()
            defer { try? FileManager.default.removeItem(at: directory) }
            let schema = try await ExecutionEngine(bundle: TestSupport.bundle, docker: nil).loadSQLSchema(target: DriverSupport.target(directory.path), connection: nil)
            let label = server.dialect
            #expect(schema.notes == nil, "\(label): \(schema.notes ?? [])")
            let shipments = try #require(schema.table(named: "p153_shipments"), "\(label)")
            #expect(shipments.foreignKeys == [.init(name: "p153_shipments_line", columns: ["order_id", "line_no"], references: "p153_order_lines", referencedColumns: ["order_id", "line_no"])],
                    "\(label): one constraint, in the key's order: \(shipments.foreignKeys ?? [])")
            let orders = try #require(schema.table(named: "p153_orders"))
            #expect(orders.foreignKeys?.map(\.name).sorted() == ["p153_orders_approver", "p153_orders_billing", "p153_orders_customer", "p153_orders_seller"], "\(label)")
            #expect(orders.foreignKeys?.first { $0.name == "p153_orders_billing" }?.referencedColumns == ["email"], "\(label)")

            let relations = SQLRelations.relations(in: schema).filter { $0.from.hasPrefix("p153_") }
            #expect(relations.map(\.summary) == [
                "p153_employees.manager_id → p153_employees.id",
                "p153_order_lines.order_id → p153_orders.id",
                "p153_orders.billing_email → p153_customers.email",
                "p153_orders.customer_id → p153_customers.id",
                "p153_orders.approved_by → p153_employees.id",
                "p153_orders.sold_by → p153_employees.id",
                "p153_shipments(order_id, line_no) → p153_order_lines(order_id, line_no)",
            ], "\(label)")
            let graph = try #require(SQLRelations.graph(of: "p153_order_lines", in: schema, hops: 2))
            #expect(graph.nodes.map(\.name) == ["p153_order_lines", "p153_orders", "p153_customers", "p153_employees", "p153_shipments"], "\(label)")
            let composite = try #require(graph.relations.first { $0.isComposite })
            #expect(SQLRelations.join(composite, joining: SQLRelations.joinedTable(composite, in: graph), driver: schema.driver)
                == "JOIN p153_shipments ON p153_shipments.order_id = p153_order_lines.order_id AND p153_shipments.line_no = p153_order_lines.line_no", "\(label)")
        }
    }
}
