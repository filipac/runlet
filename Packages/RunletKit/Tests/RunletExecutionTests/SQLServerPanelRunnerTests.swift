import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// The Database pane's Server section (#150) through the runner, with host PHP: SQLite's overview
/// and sizes through a project's PDO and a saved connection (no project code runs), the parts read
/// apart, SQLite's missing sessions, the refusals (a callable, an action on SQLite), and PHP 7.4.
/// Live MariaDB and PostgreSQL are in `SQLServerPanelLiveTests`.
@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct SQLServerPanelRunnerTests {
    static func load(_ directory: URL, parts: [SQLServerInfo.Part] = SQLServerInfo.Part.allCases, connection: String? = nil, php: String? = nil) async throws -> SQLServerInfo {
        try await ExecutionEngine(bundle: TestSupport.bundle, docker: nil).loadSQLServerInfo(target: DriverSupport.target(directory.path, php: php), parts: parts, connection: connection)
    }

    @Test func sqliteOverviewSizesAndNoSessions() async throws {
        let directory = try SQLDefinitionTests.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let info = try await Self.load(directory)
        #expect(info.driver == "sqlite" && info.source == "ShopDriver::sqlConnection()", "\(info)")
        #expect(info.errors == nil, "\(info.errors ?? [:])")
        let overview = try #require(info.overview)
        #expect(overview.product == "SQLite" && overview.version?.first?.isNumber == true, "\(overview)")
        #expect(overview.database?.hasSuffix("/shop.sqlite") == true, "\(overview.database ?? "-")")
        #expect(overview.tls == nil && overview.uptimeSeconds == nil)
        let sizes = try #require(info.sizes)
        #expect((sizes.databaseBytes ?? 0) >= 4096, "\(sizes)")
        #expect(sizes.tableCount == 2 && sizes.viewCount == 1, "\(sizes)")
        if sizes.how == "dbstat" {
            #expect(Set(sizes.tables.map(\.name)) == ["customers", "orders"], "\(sizes.tables)")
            #expect(sizes.tables.allSatisfy { ($0.totalBytes ?? 0) == ($0.dataBytes ?? 0) + ($0.indexBytes ?? 0) })
        } else {
            #expect(sizes.how == "page_count" && sizes.tables.isEmpty)
            #expect(sizes.notes?.first?.contains("dbstat") == true)
        }
        let sessions = try #require(info.sessions)
        #expect(sessions.list.isEmpty && sessions.visibility == "none")
        #expect(sessions.notes?.first?.hasPrefix("SQLite has no server and no sessions") == true)
        #expect(info.sessionId == nil && info.server == nil, "SQLite has no session to protect")
        #expect(try SQLDefinitionTests.count("customers", in: directory) == "1", "nothing changed")
    }

    @Test func partsAreReadApart() async throws {
        let directory = try SQLDefinitionTests.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let info = try await Self.load(directory, parts: [.overview])
        #expect(info.parts == [.overview])
        #expect(info.overview != nil && info.sizes == nil && info.sessions == nil)
    }

    @Test func aCallableConnectionIsNotAvailable() async throws {
        let directory = try SQLDefinitionTests.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await Self.load(directory, connection: "callable")
            Issue.record("a callable can't be read")
        } catch let error as SQLServerLoadError {
            #expect(error.description.contains("this connection is a callable from ShopDriver::sqlConnection()"), "\(error)")
        }
    }

    @Test func aSavedSQLiteConnectionRunsNoProjectCode() async throws {
        let directory = try SQLSavedConnectionTests.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = SQLSavedConnectionTests.connection()
        let (engine, _) = try SQLSavedConnectionTests.engine(for: connection)
        let info = try await engine.loadSQLServerInfo(target: DriverSupport.target(directory.path), connection: "ignored", saved: connection)
        #expect(info.saved == true && info.connection == "Reporting")
        #expect(info.sizes?.tableCount == 2)
        #expect(SQLSavedConnectionTests.markers(in: directory).isEmpty, "no project code ran")
        #expect(!SQLSavedConnectionTests.leaks(String(reflecting: info)))
    }

    /// The runner refuses an action whose connection isn't the kind the list came from, and
    /// statements that aren't Runlet's own.
    @Test func actionsOnSQLiteAndForeignStatementsAreRefused() async throws {
        let directory = try SQLDefinitionTests.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
        let target = DriverSupport.target(directory.path)
        let plan = SQLServerActionPlan(action: .kill, dialect: "mysql", session: 12, statement: "KILL 12", server: "abc", listedBy: 3, user: "app", started: "")
        let report = await engine.runSQLServerAction(plan, target: target, connection: nil)
        #expect(report.outcome == .failed && report.detail?.contains("sqlite connection now") == true, "\(report)")
        var foreign = plan
        foreign.statement = "DROP TABLE customers"
        let refused = await engine.runSQLServerAction(foreign, target: target, connection: nil)
        #expect(refused.outcome == .refused && refused.detail?.contains("only its own kill statement") == true, "\(refused)")
        #expect(refused.statement == "DROP TABLE customers", "the report names what was asked for")
        #expect(try SQLDefinitionTests.count("customers", in: directory) == "1", "nothing ran")
    }

    @Test(.enabled(if: TestSupport.herdPHP74 != nil, "requires Herd's PHP 7.4"))
    func runsOnPHP74() async throws {
        let directory = try SQLDefinitionTests.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let info = try await Self.load(directory, php: TestSupport.herdPHP74!)
        #expect(info.overview?.product == "SQLite" && info.sizes?.tableCount == 2 && info.errors == nil, "\(info)")
    }
}
