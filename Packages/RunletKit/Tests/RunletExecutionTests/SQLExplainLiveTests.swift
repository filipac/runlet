import Foundation
@testable import RunletCore
import Testing
@testable import RunletExecution

/// Explain Statement (#147) against live MariaDB and PostgreSQL servers: plan trees from their
/// JSON, that plain Explain never runs the statement, Explain Analyze (PostgreSQL rolls a
/// write back; MySQL and MariaDB refuse writes), and read-only saved connections (#139). They
/// run only when `RUNLET_TEST_MYSQL` / `RUNLET_TEST_PGSQL` are set (see SQLLiveDatabaseTests).
/// Tables are `p147_customers` and `p147_items`, created again by each test.
@Suite(.serialized, .enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct SQLExplainLiveTests {
    typealias Server = SQLLiveDatabaseTests.Server
    static var servers: [Server] { SQLLiveDatabaseTests.servers }

    static func setup(_ server: Server) throws {
        let mysql = server.dialect == "mysql"
        var statements = [
            "DROP TABLE IF EXISTS p147_items",
            "DROP TABLE IF EXISTS p147_customers",
            mysql
                ? "CREATE TABLE p147_customers (id INT AUTO_INCREMENT PRIMARY KEY, email VARCHAR(190) NOT NULL, country VARCHAR(2)) ENGINE=InnoDB"
                : "CREATE TABLE p147_customers (id SERIAL PRIMARY KEY, email VARCHAR(190) NOT NULL, country VARCHAR(2))",
            mysql
                ? "CREATE TABLE p147_items (id INT AUTO_INCREMENT PRIMARY KEY, customer_id INT NOT NULL, sku VARCHAR(40), qty INT) ENGINE=InnoDB"
                : "CREATE TABLE p147_items (id SERIAL PRIMARY KEY, customer_id INT NOT NULL, sku VARCHAR(40), qty INT)",
            "CREATE INDEX p147_items_customer ON p147_items (customer_id)",
        ]
        let customers = (1...1000).map { "('c\($0)@example.test', '\($0 % 2 == 0 ? "RO" : "UK")')" }.joined(separator: ", ")
        let items = (1...2000).map { "(\($0 % 1000 + 1), 'SKU\($0)', \($0))" }.joined(separator: ", ")
        statements.append("INSERT INTO p147_customers (email, country) VALUES \(customers)")
        statements.append("INSERT INTO p147_items (customer_id, sku, qty) VALUES \(items)")
        statements += mysql ? ["ANALYZE TABLE p147_customers", "ANALYZE TABLE p147_items"] : ["ANALYZE p147_customers", "ANALYZE p147_items"]
        for statement in statements { _ = try server.exec(statement) }
    }

    /// Explain through the application's connection (a project driver's PDO).
    func explain(_ server: Server, _ sql: String, mode: SQLExplain.Mode = .plan) async throws -> [RunEvent] {
        let directory = try server.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await TestSupport.run(SQLExplain.code(statement: sql, connection: nil, mode: mode), target: DriverSupport.target(directory.path), magicComments: false)
    }

    func items(_ server: Server) throws -> String {
        try server.exec("SELECT COUNT(*) FROM p147_items")
    }

    static let join = "SELECT c.email, SUM(i.qty) FROM p147_customers c JOIN p147_items i ON i.customer_id = c.id WHERE c.country = 'UK' GROUP BY c.email ORDER BY 2 DESC"

    @Test(.enabled(if: !servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func plansFromJSON() async throws {
        for server in Self.servers {
            try Self.setup(server)
            let label = server.dialect
            let mysql = server.dialect == "mysql"

            let scan = try await explain(server, "SELECT * FROM p147_customers WHERE country = 'UK'")
            #expect(scan.errors.isEmpty, "\(label): \(scan.errors)")
            let info = try #require(scan.sqlPlan, "\(label)")
            #expect(info.format == "json", "\(label)")
            #expect(info.explained == (mysql ? "EXPLAIN FORMAT=JSON" : "EXPLAIN (FORMAT JSON)"), "\(label)")
            if mysql { #expect(["mysql", "mariadb"].contains(info.dialect ?? ""), "\(label): \(info.dialect ?? "")") }
            let plan = try #require(info.plan, "\(label): \(info.parseError ?? "") \(info.raw ?? "")")
            let node = try #require(plan.nodes.first { $0.table?.hasPrefix("p147_customers") == true })
            #expect(node.fullScan, "\(label): \(plan.text)")
            #expect(node.rows != nil && node.cost != nil, "\(label): \(plan.text)")
            #expect(info.originText.contains(mysql ? "Maria" : "PostgreSQL"), "\(label): \(info.originText)")

            let join = try #require(try await explain(server, Self.join).sqlPlan?.plan, "\(label)")
            #expect(join.nodes.count >= 3, "\(label): \(join.text)")
            #expect(join.totalCost != nil, "\(label)")

            // A primary key lookup uses the index and isn't a full scan.
            let lookup = try #require(try await explain(server, "SELECT * FROM p147_customers WHERE id = 3").sqlPlan?.plan, "\(label)")
            #expect(lookup.nodes.contains { $0.index != nil && $0.table?.hasPrefix("p147_customers") == true }, "\(label): \(lookup.text)")
            #expect(lookup.fullScans.isEmpty, "\(label): \(lookup.text)")

            // Plain Explain of writes never runs them.
            for statement in ["DELETE FROM p147_items WHERE qty < 50", "UPDATE p147_items SET qty = 0", "INSERT INTO p147_items (customer_id, sku, qty) VALUES (1, 'x', 1)"] {
                let events = try await explain(server, statement)
                #expect(events.errors.isEmpty, "\(label) \(statement): \(events.errors)")
                #expect(events.sqlPlan?.plan != nil, "\(label) \(statement): \(events.sqlPlan?.parseError ?? "")")
            }
            #expect(try items(server) == "2000", "\(label)")
            #expect(try server.exec("SELECT COUNT(*) FROM p147_items WHERE qty = 0") == "0", "\(label)")

            // A second statement is refused by the database's native prepare, not run.
            let two = try await explain(server, "SELECT 1; DELETE FROM p147_items")
            #expect(two.sqlPlan == nil && !two.errors.isEmpty, "\(label)")
            #expect(try items(server) == "2000", "\(label)")
        }
    }

    @Test(.enabled(if: !servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func explainAnalyze() async throws {
        for server in Self.servers {
            try Self.setup(server)
            let label = server.dialect
            let mysql = server.dialect == "mysql"

            let read = try await explain(server, Self.join, mode: .analyze)
            #expect(read.errors.isEmpty, "\(label): \(read.errors)")
            let info = try #require(read.sqlPlan, "\(label)")
            #expect(info.analyze == true, "\(label)")
            let plan = try #require(info.plan, "\(label): \(info.parseError ?? "")")
            #expect(plan.analyzed, "\(label)")
            #expect(plan.nodes.contains { $0.actualRows != nil }, "\(label): \(plan.text)")
            if mysql {
                #expect(info.rolledBack == nil, "\(label)")
            } else {
                #expect(info.explained == "EXPLAIN (ANALYZE, FORMAT JSON)", "\(label)")
                #expect(info.rolledBack == true, "\(label)")
                #expect(plan.executionMs != nil, "\(label)")
            }

            let delete = try await explain(server, "DELETE FROM p147_items WHERE qty < 50", mode: .analyze)
            if mysql {
                // MySQL and MariaDB: refused, nothing ran.
                #expect(delete.sqlPlan == nil, "\(label)")
                #expect(delete.errors.first?.message.contains("Runlet runs only reading statements that way") == true, "\(label): \(delete.errors)")
            } else {
                // PostgreSQL: the DELETE ran in a transaction that was rolled back.
                #expect(delete.errors.isEmpty, "\(label): \(delete.errors)")
                let deleted = try #require(delete.sqlPlan?.plan, "\(label)")
                #expect(deleted.nodes.first?.operation == "Delete", "\(label): \(deleted.text)")
                #expect(deleted.nodes.last?.actualRows == 49, "\(label): \(deleted.text)")
                #expect(delete.sqlPlan?.rolledBack == true, "\(label)")
            }
            #expect(try items(server) == "2000", "\(label): the write was undone or never ran")
        }
    }

    @Test(.enabled(if: !servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func readOnlySavedConnection() async throws {
        let live = SQLLiveDatabaseTests()
        for server in Self.servers {
            try Self.setup(server)
            let label = server.dialect

            // Plain Explain of a read works in a read-only session. Of a write, PostgreSQL
            // explains it too (it never runs); MySQL and MariaDB refuse to (error 1792), and
            // Runlet says why.
            let read = try await live.runSaved(server, SQLExplain.code(statement: Self.join, connection: nil, mode: .plan))
            #expect(read.errors.isEmpty, "\(label): \(read.errors)")
            #expect(read.sqlPlan?.saved == true, "\(label)")
            #expect(read.sqlPlan?.plan != nil, "\(label): \(read.sqlPlan?.parseError ?? "")")
            let plan = try await live.runSaved(server, SQLExplain.code(statement: "DELETE FROM p147_items WHERE qty < 50", connection: nil, mode: .plan))
            if server.dialect == "mysql" {
                #expect(plan.errors.first?.message.contains("read-only session") == true, "\(label): \(plan.errors)")
            } else {
                #expect(plan.errors.isEmpty, "\(label): \(plan.errors)")
                #expect(plan.sqlPlan?.plan?.nodes.first?.operation == "Delete", "\(label)")
            }

            // Explain Analyze of a read works; of a write it's refused before connecting.
            let analyzed = try await live.runSaved(server, SQLExplain.code(statement: Self.join, connection: nil, mode: .analyze))
            #expect(analyzed.errors.isEmpty, "\(label): \(analyzed.errors)")
            #expect(analyzed.sqlPlan?.plan?.analyzed == true, "\(label)")
            let write = try await live.runSaved(server, SQLExplain.code(statement: "DELETE FROM p147_items", connection: nil, mode: .analyze))
            #expect(write.errors.first?.message.contains("refused it on the read-only connection") == true, "\(label): \(write.errors)")
            #expect(try items(server) == "2000", "\(label)")
        }
    }
}
