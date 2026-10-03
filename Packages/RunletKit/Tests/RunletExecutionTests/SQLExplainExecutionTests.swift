import Foundation
@testable import RunletCore
import Testing
@testable import RunletExecution

extension Array where Element == RunEvent {
    /// Explain Statement's `sqlPlan` event (#147).
    var sqlPlan: SQLPlanInfo? {
        for event in self { if case .sqlPlan(let info) = event.kind { return info } }
        return nil
    }
}

/// Explain Statement in SQL tabs (#147) through the runner with host PHP and SQLite: the plan
/// tree, that plain Explain never runs the statement, Explain Analyze's refusals, saved and
/// read-only connections, callables, and PHP 7.4.
@Suite(.serialized, .enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct SQLExplainExecutionTests {
    func explain(_ sql: String, connection: String? = nil, mode: SQLExplain.Mode = .plan, bindings: [SQLBinding] = [], in directory: String, php: String? = nil) async throws -> [RunEvent] {
        try await TestSupport.run(SQLExplain.code(statement: sql, connection: connection, mode: mode, bindings: bindings), target: DriverSupport.target(directory, php: php), magicComments: false)
    }

    func count(_ table: String, in directory: URL) throws -> String {
        let php = Process()
        php.executableURL = URL(fileURLWithPath: DriverSupport.php)
        php.arguments = ["-r", "echo (new PDO('sqlite:' . $argv[1]))->query('SELECT COUNT(*) FROM ' . $argv[2])->fetchColumn();", directory.appendingPathComponent("data/shop.sqlite").path, table]
        let output = Pipe()
        php.standardOutput = output
        try php.run()
        php.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// A saved SQLite connection's project (`data/shop.sqlite`), with an index on orders.
    func project() throws -> URL {
        let directory = try SQLSavedConnectionTests.project()
        let php = Process()
        php.executableURL = URL(fileURLWithPath: DriverSupport.php)
        php.arguments = ["-r", "(new PDO('sqlite:' . $argv[1]))->exec('CREATE INDEX orders_customer ON orders (customer_id)');", directory.appendingPathComponent("data/shop.sqlite").path]
        try php.run()
        php.waitUntilExit()
        return directory
    }

    @Test func projectDriverSQLitePlan() async throws {
        let fixture = DriverSupport.fixture("custom-driver")
        let events = try await explain("SELECT tenant FROM leases WHERE rent > 1000 ORDER BY tenant", in: fixture)
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.sqlResult == nil, "Explain shows a plan, not rows")
        let info = try #require(events.sqlPlan)
        #expect(info.driver == "sqlite" && info.dialect == "sqlite" && info.format == "rows")
        #expect(info.explained == "EXPLAIN QUERY PLAN")
        #expect(info.analyze == false)
        #expect(info.source == "AcmeApiDriver::sqlConnection()")
        #expect(info.connections == ["main", "archive"])
        #expect(info.serverVersion?.isEmpty == false)
        let plan = try #require(info.plan, "\(info.parseError ?? "")")
        #expect(plan.nodes.first?.operation == "SCAN")
        #expect(plan.nodes.first?.table == "leases")
        #expect(plan.nodes.first?.fullScan == true)
        #expect(plan.nodes.contains { $0.operation.contains("ORDER BY") })
        #expect(events.finished?.status == .completed)
    }

    @Test func plainExplainNeverRunsTheStatement() async throws {
        let directory = try project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = SQLSavedConnectionTests.connection()
        for statement in ["DELETE FROM orders", "UPDATE customers SET email = 'x'", "INSERT INTO orders (customer_id, total) VALUES (1, 1)", "DROP TABLE orders"] {
            let events = try await SQLSavedConnectionTests.run(SQLExplain.code(statement: statement, connection: nil, mode: .plan), connection: connection, in: directory)
            #expect(events.errors.isEmpty, "\(statement): \(events.errors)")
            #expect(events.sqlPlan?.plan != nil, "\(statement)")
        }
        #expect(try count("orders", in: directory) == "2")
        #expect(try count("customers WHERE email = 'x'", in: directory) == "0")

        // A second statement after a `;` is never run: SQLite compiles only the first.
        let two = try await SQLSavedConnectionTests.run(SQLExplain.code(statement: "SELECT 1; DELETE FROM orders", connection: nil, mode: .plan), connection: connection, in: directory)
        #expect(two.sqlPlan != nil || !two.errors.isEmpty)
        #expect(try count("orders", in: directory) == "2")

        // An index lookup isn't a full scan; the saved connection says where the plan came from.
        let lookup = try await SQLSavedConnectionTests.run(SQLExplain.code(statement: "SELECT * FROM orders WHERE customer_id = 1", connection: nil, mode: .plan), connection: connection, in: directory)
        let info = try #require(lookup.sqlPlan)
        #expect(info.saved == true && info.connection == "Reporting")
        #expect(info.plan?.nodes.first?.index == "orders_customer")
        #expect(info.plan?.fullScans.isEmpty == true)
        #expect(SQLSavedConnectionTests.markers(in: directory).isEmpty, "a saved connection's Explain runs no project code")
    }

    @Test func refusals() async throws {
        let directory = try project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = SQLSavedConnectionTests.connection()

        let analyze = try await SQLSavedConnectionTests.run(SQLExplain.code(statement: "SELECT * FROM orders", connection: nil, mode: .analyze), connection: connection, in: directory)
        #expect(analyze.sqlPlan == nil)
        #expect(analyze.errors.first?.message.contains("SQLite has no EXPLAIN ANALYZE") == true, "\(analyze.errors)")

        let already = try await SQLSavedConnectionTests.run(SQLExplain.code(statement: "/* x */ EXPLAIN QUERY PLAN SELECT 1", connection: nil, mode: .plan), connection: connection, in: directory)
        #expect(already.errors.first?.message.contains("already starts with EXPLAIN") == true, "\(already.errors)")
        let mariadbAnalyze = try await SQLSavedConnectionTests.run(SQLExplain.code(statement: "analyze select 1", connection: nil, mode: .plan), connection: connection, in: directory)
        #expect(mariadbAnalyze.errors.first?.message.contains("already starts with ANALYZE") == true)

        // A callable connection's database is unknown.
        let fixture = DriverSupport.fixture("custom-driver")
        let callable = try await explain("SELECT 1", connection: "archive", in: fixture)
        #expect(callable.sqlPlan == nil)
        #expect(callable.errors.first?.message.contains("runs statements through a callable") == true, "\(callable.errors)")
    }

    @Test func readOnlyConnection() async throws {
        let directory = try project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let readOnly = SQLReadOnlyConnectionTests.readOnly()

        // Plain Explain works on a read-only connection, even of a write: it never runs it.
        let plan = try await SQLSavedConnectionTests.run(SQLExplain.code(statement: "DELETE FROM orders WHERE total < 10", connection: nil, mode: .plan), connection: readOnly, in: directory)
        #expect(plan.errors.isEmpty, "\(plan.errors)")
        #expect(plan.sqlPlan?.plan?.nodes.first?.fullScan == true)
        #expect(try count("orders", in: directory) == "2")

        // Explain Analyze of a write is refused before connecting.
        let analyze = try await SQLSavedConnectionTests.run(SQLExplain.code(statement: "DELETE FROM orders", connection: nil, mode: .analyze), connection: readOnly, in: directory)
        #expect(analyze.errors.first?.message.contains("refused it on the read-only connection") == true, "\(analyze.errors)")
        #expect(try count("orders", in: directory) == "2")
    }

    /// Bound values (#145) reach the EXPLAIN as they reach Run; a callable can't bind them.
    @Test func boundValues() async throws {
        let directory = try project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let positional = try await SQLSavedConnectionTests.run(SQLExplain.code(statement: "SELECT * FROM orders WHERE customer_id = ? AND total > ?", connection: nil, mode: .plan, bindings: [SQLBinding(target: .position(1), value: .integer(1)), SQLBinding(target: .position(2), value: .decimal("5.5"))]), connection: SQLSavedConnectionTests.connection(), in: directory)
        #expect(positional.errors.isEmpty, "\(positional.errors)")
        #expect(positional.sqlPlan?.plan?.nodes.first?.index == "orders_customer")
        let named = try await SQLSavedConnectionTests.run(SQLExplain.code(statement: "SELECT * FROM orders WHERE customer_id = :customer", connection: nil, mode: .plan, bindings: [SQLBinding(target: .name("customer"), value: .integer(1))]), connection: SQLSavedConnectionTests.connection(), in: directory)
        #expect(named.errors.isEmpty, "\(named.errors)")
        #expect(named.sqlPlan?.plan?.nodes.first?.index == "orders_customer")

        let callable = try await explain("SELECT ? AS x", connection: "archive", bindings: [SQLBinding(target: .position(1), value: .integer(1))], in: DriverSupport.fixture("custom-driver"))
        #expect(callable.errors.first?.message.contains("can't bind values") == true, "\(callable.errors)")
    }

    @Test(.enabled(if: TestSupport.herdPHP74 != nil, "requires Herd's PHP 7.4"))
    func php74() async throws {
        let directory = try project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = SQLSavedConnectionTests.connection()
        let (engine, _) = try SQLSavedConnectionTests.engine(for: connection)
        var request = RunRequest(tabId: UUID(), documentVersion: 1, target: DriverSupport.target(directory.path, php: TestSupport.herdPHP74), code: SQLExplain.code(statement: "SELECT * FROM orders WHERE total > 1", connection: nil, mode: .plan), inspector: RunInspectorOptions(), magicComments: false)
        request.sqlConnection = connection
        var events: [RunEvent] = []
        for await event in try await engine.start(request) { events.append(event) }
        #expect(events.started?.phpVersion?.hasPrefix("7.4") == true)
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.sqlPlan?.plan?.nodes.first?.fullScan == true)
    }
}
