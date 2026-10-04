import Foundation
@testable import RunletCore
import Testing
@testable import RunletExecution

/// The Database pane's Server section (#150) against live MariaDB 11 and PostgreSQL 14 (the
/// fixture containers, through `RUNLET_TEST_MYSQL` / `RUNLET_TEST_PGSQL`): the overview, sizes
/// that include the test's own `p150_orders`, a session list with the test's own victim session
/// and the panel's own, Cancel Query and Kill Session of that victim (verified gone), the
/// runner's refusals (the panel's own session, another server, a session that isn't the listed
/// one any more), a read-only saved connection, and the `p150_limited` user, who sees only part of
/// the list and may not end others' sessions.
///
/// Other suites and other people's sessions share these servers, so every Cancel and Kill here
/// targets only a session this test opened itself, found by a unique marker in its statement.
@Suite(.serialized, .enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct SQLServerPanelLiveTests {
    typealias Server = SQLLiveDatabaseTests.Server
    static let limited = (user: "p150_limited", password: "p150-fixture")

    /// `p150_orders` (about a megabyte, analyzed) and `p150_limited`, created idempotently.
    static func setup(_ server: Server) throws {
        let mysql = server.dialect == "mysql"
        let statements = mysql ? [
            "CREATE TABLE IF NOT EXISTS p150_orders (id INT PRIMARY KEY, status VARCHAR(20) NOT NULL, note VARCHAR(255) NOT NULL, KEY p150_orders_status (status)) ENGINE=InnoDB",
            "INSERT IGNORE INTO p150_orders (id, status, note) SELECT seq, IF(seq % 3 = 0, 'paid', 'open'), REPEAT('x', 200) FROM seq_1_to_4000",
            "ANALYZE TABLE p150_orders",
            "CREATE USER IF NOT EXISTS p150_limited@'%' IDENTIFIED BY 'p150-fixture'",
            "GRANT SELECT ON shop.p150_orders TO p150_limited@'%'",
        ] : [
            "CREATE TABLE IF NOT EXISTS p150_orders (id INT PRIMARY KEY, status VARCHAR(20) NOT NULL, note VARCHAR(255) NOT NULL)",
            "CREATE INDEX IF NOT EXISTS p150_orders_status ON p150_orders (status)",
            "INSERT INTO p150_orders (id, status, note) SELECT n, CASE WHEN n % 3 = 0 THEN 'paid' ELSE 'open' END, repeat('x', 200) FROM generate_series(1, 4000) n ON CONFLICT (id) DO NOTHING",
            "ANALYZE p150_orders",
            "DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'p150_limited') THEN CREATE ROLE p150_limited LOGIN PASSWORD 'p150-fixture'; END IF; END $$",
            "GRANT CONNECT ON DATABASE shop TO p150_limited",
        ]
        for statement in statements { _ = try server.exec(statement) }
    }

    static func marker() -> String { "p150_victim_" + UUID().uuidString.prefix(8).lowercased() }

    /// A session of the test's own that sleeps 30 s, marked so the list and the checks find it.
    final class Victim: @unchecked Sendable {
        let process = Process()
        let output = Pipe()
        let marker: String

        init(_ server: Server, marker: String, user: String? = nil, password: String? = nil) throws {
            self.marker = marker
            let sleep = server.dialect == "mysql" ? "SELECT SLEEP(30) /* \(marker) */" : "SELECT pg_sleep(30) /* \(marker) */"
            process.executableURL = URL(fileURLWithPath: DriverSupport.php)
            process.arguments = ["-r", """
                $p = new PDO($argv[1], $argv[2], $argv[3], [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
                try { $p->query($argv[4]); echo 'finished'; } catch (Throwable $e) { echo $e->getMessage(); }
                """, server.dsn, user ?? server.user, password ?? server.password, sleep]
            process.standardOutput = output
            process.standardError = output
            try process.run()
        }

        /// What the victim's client saw, once it ended (at most `within`).
        func result(within: Duration = .seconds(5)) async -> String? {
            let deadline = ContinuousClock.now + within
            while process.isRunning, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            guard !process.isRunning else { return nil }
            return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }

        /// Ends the victim: its process, and its session on the server (found by its marker only).
        func end(_ server: Server) {
            if process.isRunning { process.terminate() }
            let ids = (try? server.exec(server.dialect == "mysql"
                ? "SELECT ID FROM information_schema.PROCESSLIST WHERE INFO LIKE '%\(marker)%' AND INFO NOT LIKE '%PROCESSLIST%' AND ID <> CONNECTION_ID()"
                : "SELECT pid FROM pg_stat_activity WHERE query LIKE '%\(marker)%' AND query NOT LIKE '%pg_stat_activity%' AND pid <> pg_backend_pid()")) ?? ""
            for id in ids.split(separator: "\n").compactMap({ Int($0) }) {
                _ = try? server.exec(server.dialect == "mysql" ? "KILL \(id)" : "SELECT pg_terminate_backend(\(id))")
            }
        }
    }

    /// Starts a victim and waits until the server runs its statement.
    static func victim(_ server: Server, user: String? = nil, password: String? = nil) async throws -> Victim {
        let victim = try Victim(server, marker: marker(), user: user, password: password)
        let deadline = ContinuousClock.now + .seconds(5)
        while try await SQLCancelLiveTests.running(server, marker: victim.marker) == 0 {
            guard ContinuousClock.now < deadline else {
                victim.end(server)
                throw SQLServerLoadError("the victim session never showed up")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return victim
    }

    static func read(_ server: Server, engine: ExecutionEngine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil), parts: [SQLServerInfo.Part] = SQLServerInfo.Part.allCases, target: TargetSnapshot? = nil, saved: DatabaseConnection? = nil) async throws -> SQLServerInfo {
        if let target { return try await engine.loadSQLServerInfo(target: target, parts: parts, connection: nil, saved: saved) }
        let directory = try server.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await engine.loadSQLServerInfo(target: DriverSupport.target(directory.path), parts: parts, connection: nil, saved: saved)
    }

    /// Runs `plan` through the project's application connection.
    static func act(_ plan: SQLServerActionPlan, _ server: Server) async throws -> SQLServerActionReport {
        let directory = try server.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        return await ExecutionEngine(bundle: TestSupport.bundle, docker: nil).runSQLServerAction(plan, target: DriverSupport.target(directory.path), connection: nil)
    }

    static func plan(_ action: SQLServerAction, _ victim: Victim, in info: SQLServerInfo) throws -> SQLServerActionPlan {
        let session = try #require(info.sessions?.list.first { $0.query?.contains(victim.marker) == true && !$0.isOwn }, "the victim is listed")
        switch SQLServerPanel.plan(action, session: session, info: info) {
        case .success(let plan): return plan
        case .failure(let refusal): throw refusal
        }
    }

    @Test(.enabled(if: !SQLLiveDatabaseTests.servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func overviewAndSizes() async throws {
        for server in SQLLiveDatabaseTests.servers {
            try Self.setup(server)
            let info = try await Self.read(server, parts: [.overview, .sizes])
            let label = server.dialect
            #expect(info.errors == nil, "\(label): \(info.errors ?? [:])")
            #expect(info.driver == server.dialect && info.sessions == nil, "\(label)")
            let overview = try #require(info.overview, "\(label)")
            #expect(overview.product == (server.dialect == "mysql" ? "MariaDB" : "PostgreSQL"), "\(label): \(overview)")
            #expect(overview.version?.first?.isNumber == true && overview.versionText != nil, "\(label): \(overview)")
            #expect(overview.database == "shop", "\(label)")
            #expect(overview.user?.hasPrefix(server.user) == true, "\(label): \(overview.user ?? "-")")
            #expect((overview.uptimeSeconds ?? 0) > 0 && (overview.connections ?? 0) >= 1, "\(label): \(overview)")
            #expect(overview.tls != nil, "\(label): TLS is known")
            let sizes = try #require(info.sizes, "\(label)")
            #expect(sizes.database == "shop" && (sizes.databaseBytes ?? 0) > 0, "\(label): \(sizes)")
            #expect(sizes.tables.count <= 20 && (sizes.tableCount ?? 0) >= 1, "\(label)")
            #expect(sizes.tables.map { $0.totalBytes ?? 0 } == sizes.tables.map { $0.totalBytes ?? 0 }.sorted(by: >), "\(label): largest first")
            let orders = try #require(sizes.tables.first { $0.name == "p150_orders" }, "\(label): \(sizes.tables.map(\.name))")
            #expect((orders.dataBytes ?? 0) >= 500_000 && (orders.indexBytes ?? 0) > 0, "\(label): \(orders)")
            if server.dialect == "mysql" {
                #expect(orders.totalBytes == (orders.dataBytes ?? 0) + (orders.indexBytes ?? 0) && orders.engine == "InnoDB", "\(label): \(orders)")
            } else {
                #expect((orders.totalBytes ?? 0) >= (orders.dataBytes ?? 0) + (orders.indexBytes ?? 0) && orders.schema == "public", "\(label): \(orders)")
            }
            #expect((orders.rows ?? 0) > 3000, "\(label): an estimate after ANALYZE: \(orders)")
            #expect(sizes.estimated == true && sizes.notes?.isEmpty == false, "\(label)")
        }
    }

    @Test(.enabled(if: !SQLLiveDatabaseTests.servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func sessionsListTheVictimAndThePanelsOwnThenCancelAndKillIt() async throws {
        for server in SQLLiveDatabaseTests.servers {
            let label = server.dialect
            // Cancel Query: the statement stops, the session stays (until its client leaves).
            let first = try await Self.victim(server)
            defer { first.end(server) }
            let info = try await Self.read(server, parts: [.sessions])
            let sessions = try #require(info.sessions, "\(label)")
            #expect(sessions.visibility == "all" && sessions.endOthers == true, "\(label): \(sessions)")
            let own = try #require(sessions.list.first { $0.isOwn }, "\(label): the panel's own session is marked")
            #expect(own.id == info.sessionId && info.server?.count == 16, "\(label)")
            let listed = try #require(sessions.list.first { $0.query?.contains(first.marker) == true }, "\(label)")
            #expect(listed.isActive && !listed.isOwn && listed.user == server.user && listed.host != nil && listed.database == "shop", "\(label): \(listed)")
            #expect((listed.seconds ?? -1) >= 0, "\(label)")
            if server.dialect == "pgsql" { #expect(listed.started != nil && listed.queryStarted != nil, "\(label)") }
            #expect(SQLServerPanel.refusal(.kill, session: own, info: info) != nil, "\(label): the panel's own is refused in the app")

            let cancel = try Self.plan(.cancel, first, in: info)
            let cancelled = try await Self.act(cancel, server)
            #expect(cancelled.outcome == .cancelled && cancelled.verified == true, "\(label): \(cancelled)")
            #expect(cancelled.statement == (server.dialect == "mysql" ? "KILL QUERY \(listed.id)" : "SELECT pg_cancel_backend(\(listed.id))"))
            let client = await first.result()
            #expect(client?.contains(server.dialect == "mysql" ? "1317" : "canceling statement due to user request") == true, "\(label): \(client ?? "still running")")
            #expect(try await SQLCancelLiveTests.gone(server, marker: first.marker), "\(label)")

            // Kill Session: the session ends.
            let second = try await Self.victim(server)
            defer { second.end(server) }
            let again = try await Self.read(server, parts: [.sessions])
            let kill = try Self.plan(.kill, second, in: again)
            let killed = try await Self.act(kill, server)
            #expect(killed.outcome == .killed && killed.verified == true, "\(label): \(killed)")
            #expect(killed.message.hasPrefix("Killed session \(kill.session) ("), "\(label)")
            let ended = await second.result()
            #expect(ended?.contains("finished") == false && ended?.isEmpty == false, "\(label): \(ended ?? "still running")")
            let row = server.dialect == "mysql"
                ? "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE ID = \(kill.session)"
                : "SELECT COUNT(*) FROM pg_stat_activity WHERE pid = \(kill.session)"
            #expect(try server.exec(row) == "0", "\(label): the session is gone")
        }
    }

    @Test(.enabled(if: !SQLLiveDatabaseTests.servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func theRunnerRefusesThePanelsOwnSessionAnotherServerAndAStaleRow() async throws {
        for server in SQLLiveDatabaseTests.servers {
            let label = server.dialect
            let victim = try await Self.victim(server)
            defer { victim.end(server) }
            let info = try await Self.read(server, parts: [.sessions])
            let listedBy = try #require(info.sessionId)
            let kill = try Self.plan(.kill, victim, in: info)

            // The session the list was read with, sent anyway (the app never offers it).
            var own = kill
            own.session = listedBy
            own.statement = SQLServerPanel.statement(.kill, driver: server.dialect, session: listedBy) ?? ""
            let ownReport = try await Self.act(own, server)
            #expect(ownReport.outcome == .refused && ownReport.detail?.contains("the one the panel read the list with") == true, "\(label): \(ownReport)")

            // Another server's fingerprint.
            var elsewhere = kill
            elsewhere.server = "0000000000000000"
            let other = try await Self.act(elsewhere, server)
            #expect(other.outcome == .refused && other.detail?.contains("another database server") == true, "\(label): \(other)")

            // The row isn't the listed session any more: another user, or (PostgreSQL) another backend start.
            var stale = kill
            if server.dialect == "mysql" { stale.user = "somebody_else" } else { stale.started = "2001-01-01 00:00:00+00" }
            let staleReport = try await Self.act(stale, server)
            #expect(staleReport.outcome == .refused && (staleReport.detail?.contains("not somebody_else") == true || staleReport.detail?.contains("another session now") == true), "\(label): \(staleReport)")

            // A statement that isn't Runlet's own.
            var foreign = kill
            foreign.statement = "SELECT 1"
            #expect(try await Self.act(foreign, server).outcome == .refused, "\(label)")

            #expect(try await SQLCancelLiveTests.running(server, marker: victim.marker) == 1, "\(label): the victim still runs: nothing was sent")
        }
    }

    /// Read-only saved connections (#139) may cancel and kill: it changes no data. The password
    /// appears in no report.
    @Test(.enabled(if: !SQLLiveDatabaseTests.servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func aReadOnlySavedConnectionReadsAndKills() async throws {
        for server in SQLLiveDatabaseTests.servers {
            let label = server.dialect
            var (connection, store) = SQLLiveDatabaseTests.saved(server)
            connection.readOnly = true
            let directory = try SQLSavedConnectionTests.project()
            defer { try? FileManager.default.removeItem(at: directory) }
            let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil, credentials: store)
            let target = DriverSupport.target(directory.path)
            let victim = try await Self.victim(server)
            defer { victim.end(server) }
            let info = try await Self.read(server, engine: engine, target: target, saved: connection)
            #expect(info.saved == true && info.connection == "Reporting replica" && info.errors == nil, "\(label): \(info.errors ?? [:])")
            let plan = try Self.plan(.kill, victim, in: info)
            let report = await engine.runSQLServerAction(plan, target: target, connection: nil, saved: connection)
            #expect(report.outcome == .killed, "\(label): \(report)")
            #expect(!String(reflecting: info).contains(server.password) && !String(reflecting: report).contains(server.password), "\(label)")
            #expect(SQLSavedConnectionTests.markers(in: directory).isEmpty, "\(label): no project code ran")
        }
    }

    /// `p150_limited` has no PROCESS (MariaDB) or pg_read_all_stats (PostgreSQL): the panel says
    /// what is missing, and the server refuses to end the victim, which keeps running.
    @Test(.enabled(if: !SQLLiveDatabaseTests.servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func aUserWithoutThePrivilegeSeesPartOfTheListAndMayNotEndOthers() async throws {
        for server in SQLLiveDatabaseTests.servers {
            let label = server.dialect
            try Self.setup(server)
            var (connection, store) = SQLLiveDatabaseTests.saved(server, password: Self.limited.password)
            connection.user = Self.limited.user
            let directory = try SQLSavedConnectionTests.project()
            defer { try? FileManager.default.removeItem(at: directory) }
            let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil, credentials: store)
            let target = DriverSupport.target(directory.path)
            let victim = try await Self.victim(server)
            defer { victim.end(server) }
            let info = try await Self.read(server, engine: engine, target: target, saved: connection)
            let sessions = try #require(info.sessions, "\(label): \(info.errors ?? [:])")
            #expect(sessions.endOthers == false, "\(label): \(sessions)")
            if server.dialect == "mysql" {
                #expect(sessions.visibility == "own", "\(label)")
                #expect(sessions.list.allSatisfy { $0.user == Self.limited.user }, "\(label): \(sessions.list.map(\.user))")
                #expect(sessions.notes?.contains { $0.contains("needs the PROCESS privilege") } == true, "\(label): \(sessions.notes ?? [])")
            } else {
                #expect(sessions.visibility == "partial", "\(label)")
                #expect(sessions.notes?.contains { $0.contains("pg_read_all_stats") } == true, "\(label): \(sessions.notes ?? [])")
                #expect(sessions.list.contains { $0.user == server.user && $0.query == nil }, "\(label): others' sessions show without their statements")
            }
            // The victim's id, as the panel of a user who may see it would list it.
            let full = try await Self.read(server, parts: [.sessions])
            var plan = try Self.plan(.kill, victim, in: full)
            plan.server = info.server ?? plan.server
            plan.listedBy = info.sessionId ?? 0
            plan.started = ""
            let report = await engine.runSQLServerAction(plan, target: target, connection: nil, saved: connection)
            #expect(report.outcome == .refused, "\(label): \(report)")
            #expect(report.detail?.contains(server.dialect == "mysql" ? "CONNECTION ADMIN" : "pg_signal_backend") == true, "\(label): \(report.detail ?? "-")")
            #expect(try await SQLCancelLiveTests.running(server, marker: victim.marker) == 1, "\(label): the victim still runs")
        }
    }
}
