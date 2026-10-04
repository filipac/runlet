import Foundation
import RunletCore
import Testing

/// The Database pane's Server section (#150): the runner's report as the app reads it, merging a
/// refresh, the statements and refusal rules of Cancel Query and Kill Session, the refresh rule,
/// and the texts.
struct SQLServerPanelTests {
    /// A MariaDB report as the runner emits it (fields the runner leaves out are absent).
    static let mariadb = """
    {"driver":"mysql","source":"saved connection \\"Shop\\" (mysql, 127.0.0.1:3306/shop)","connection":"Shop","saved":true,"parts":["overview","sizes","sessions"],"sessionId":42,"server":"8e838e25949b8d86",
     "overview":{"product":"MariaDB","version":"11.8.9","versionText":"11.8.9-MariaDB-ubu2404 (mariadb.org binary distribution)","database":"shop","user":"app@%","uptimeSeconds":93784,"connections":7,"tls":true,"tlsVersion":"TLSv1.3","tlsCipher":"TLS_AES_256_GCM_SHA384"},
     "sizes":{"database":"shop","databaseBytes":13107200,"dataBytes":10485760,"indexBytes":2621440,"tableCount":12,"viewCount":2,"tables":[{"name":"orders","engine":"InnoDB","rows":120000,"dataBytes":8388608,"indexBytes":2097152,"totalBytes":10485760},{"name":"customers","engine":"InnoDB","rows":4000,"dataBytes":1572864,"indexBytes":524288,"totalBytes":2097152}],"how":"information_schema.TABLES","estimated":true,"notes":["InnoDB sizes and row counts are the server's estimates (ANALYZE TABLE refreshes them)."]},
     "sessions":{"list":[
        {"id":77,"user":"worker","host":"10.0.0.5:51234","database":"shop","command":"Query","state":"User sleep","active":true,"seconds":12,"transactionSeconds":30,"query":"SELECT SLEEP(30) /* nightly */"},
        {"id":42,"user":"app","host":"10.0.0.9:40000","database":"shop","command":"Query","state":"Filling schema table","active":true,"seconds":0,"own":true,"query":"SELECT ID FROM information_schema.PROCESSLIST"},
        {"id":80,"user":"app","host":"10.0.0.9:40002","database":"shop","command":"Sleep","seconds":95,"blockedBy":[77]}],
      "visibility":"all","endOthers":true},
     "elapsedMs":18.4}
    """

    static func decode(_ json: String = mariadb) throws -> SQLServerInfo {
        try JSONDecoder().decode(SQLServerInfo.self, from: Data(json.utf8))
    }

    @Test func decodesTheRunnersReport() throws {
        let info = try Self.decode()
        #expect(info.overview?.server == "MariaDB 11.8.9")
        #expect(info.overview?.tlsText == "TLSv1.3 (TLS_AES_256_GCM_SHA384)")
        #expect(info.sizes?.tables.map(\.qualifiedName) == ["orders", "customers"])
        #expect(info.sizes?.largestBytes == 10_485_760)
        #expect(info.sessions?.list.count == 3)
        #expect(info.sessions?.list[1].isOwn == true)
        #expect(info.sessions?.list[2].isIdle == true && info.sessions?.list[0].isIdle == false)
        #expect(info.sessions?.list[2].blockedBy == [77])
        #expect(info.error(for: .sizes) == nil)
        #expect(SQLServerInfo.Overview(tls: false).tlsText == "not encrypted")
        #expect(SQLServerInfo.Overview().tlsText == nil)
    }

    @Test func postgresTablesKeepTheirSchemaUnlessPublic() {
        #expect(SQLServerInfo.TableSize(name: "orders", schema: "public").qualifiedName == "orders")
        #expect(SQLServerInfo.TableSize(name: "events", schema: "audit").qualifiedName == "audit.events")
    }

    @Test func aRefreshOfTheSessionsKeepsTheOtherPartsAndTakesItsOwnSessionAndServer() throws {
        let first = try Self.decode()
        var newer = SQLServerInfo(driver: "mysql", connection: "Shop", saved: true, parts: [.sessions], sessionId: 51, server: "8e838e25949b8d86",
                                  sessions: .init(list: [.init(id: 51, user: "app", own: true)], visibility: "all"))
        let merged = first.merged(with: newer)
        #expect(merged.overview == first.overview && merged.sizes == first.sizes)
        #expect(merged.sessions?.list.map(\.id) == [51])
        #expect(merged.sessionId == 51)
        #expect(Set(merged.parts ?? []) == Set(SQLServerInfo.Part.allCases))

        // An overview read alone doesn't touch the list nor the session it was read with.
        newer = SQLServerInfo(driver: "mysql", parts: [.overview], sessionId: 60, server: "ffff", overview: .init(product: "MariaDB", version: "11.8.10"), errors: nil)
        let again = merged.merged(with: newer)
        #expect(again.overview?.version == "11.8.10")
        #expect(again.sessionId == 51 && again.server == "8e838e25949b8d86")

        // A part that failed this time replaces the old one with its error.
        newer = SQLServerInfo(driver: "mysql", parts: [.sizes], sessionId: 61, server: "8e838e25949b8d86", errors: ["sizes": "SELECT command denied"])
        let failed = again.merged(with: newer)
        #expect(failed.sizes == nil && failed.error(for: .sizes) == "SELECT command denied")
        #expect(failed.sessions == again.sessions)
    }

    @Test func statementsPerDatabase() {
        #expect(SQLServerPanel.statement(.cancel, driver: "mysql", session: 4711) == "KILL QUERY 4711")
        #expect(SQLServerPanel.statement(.kill, driver: "mysql", session: 4711) == "KILL 4711")
        #expect(SQLServerPanel.statement(.cancel, driver: "pgsql", session: 88) == "SELECT pg_cancel_backend(88)")
        #expect(SQLServerPanel.statement(.kill, driver: "pgsql", session: 88) == "SELECT pg_terminate_backend(88)")
        #expect(SQLServerPanel.statement(.kill, driver: "sqlite", session: 1) == nil)
        #expect(SQLServerPanel.statement(.kill, driver: "sqlsrv", session: 57) == nil, "SQL Server isn't supported")
        #expect(SQLServerPanel.statement(.kill, driver: "mysql", session: 0) == nil)
    }

    @Test func thePanelsOwnSessionIsAlwaysRefused() throws {
        let info = try Self.decode()
        let own = try #require(info.sessions?.list.first { $0.isOwn })
        for action in SQLServerAction.allCases {
            #expect(SQLServerPanel.refusal(action, session: own, info: info)?.contains("panel's own") == true)
            guard case .failure = SQLServerPanel.plan(action, session: own, info: info) else {
                Issue.record("\(action) on the panel's own session must be refused")
                continue
            }
        }
        // Also by id, should a row lose its flag.
        var unflagged = own
        unflagged.own = nil
        #expect(SQLServerPanel.refusal(.kill, session: unflagged, info: info) != nil)
    }

    @Test func otherSessionsGetAPlanWithTheChecksTheRunnerMakes() throws {
        var info = try Self.decode()
        let worker = try #require(info.sessions?.list.first { $0.id == 77 })
        guard case .success(let kill) = SQLServerPanel.plan(.kill, session: worker, info: info) else {
            Issue.record("kill refused")
            return
        }
        #expect(kill == SQLServerActionPlan(action: .kill, dialect: "mysql", session: 77, statement: "KILL 77", server: "8e838e25949b8d86", listedBy: 42, user: "worker", started: ""))
        #expect(kill.shortStatement == "KILL 77")
        guard case .success(let cancel) = SQLServerPanel.plan(.cancel, session: worker, info: info) else {
            Issue.record("cancel refused")
            return
        }
        #expect(cancel.statement == "KILL QUERY 77")

        // Idle: nothing to cancel, but it can be killed.
        let idle = try #require(info.sessions?.list.first { $0.id == 80 })
        #expect(SQLServerPanel.refusal(.cancel, session: idle, info: info)?.contains("idle") == true)
        #expect(SQLServerPanel.refusal(.kill, session: idle, info: info) == nil)

        // No fingerprint of the server: nothing is offered.
        info.server = nil
        #expect(SQLServerPanel.refusal(.kill, session: worker, info: info)?.contains("identify the server") == true)

        // SQLite and SQL Server: no actions.
        info.server = "abc"
        info.driver = "sqlite"
        #expect(SQLServerPanel.refusal(.kill, session: worker, info: info)?.contains("MySQL, MariaDB, and PostgreSQL only") == true)
        info.driver = "sqlsrv"
        #expect(SQLServerPanel.refusal(.cancel, session: worker, info: info) != nil)
    }

    @Test func postgresPlansCarryTheBackendStart() {
        let session = SQLServerInfo.Session(id: 900, user: "report", state: "active", active: true, started: "2026-10-04 08:39:26.632339+00")
        let info = SQLServerInfo(driver: "pgsql", sessionId: 901, server: "01b5486314cbec6d", sessions: .init(list: [session]))
        guard case .success(let plan) = SQLServerPanel.plan(.kill, session: session, info: info) else {
            Issue.record("refused")
            return
        }
        #expect(plan.started == "2026-10-04 08:39:26.632339+00" && plan.user == "report")
        #expect(plan.statement == "SELECT pg_terminate_backend(900)" && plan.shortStatement == "pg_terminate_backend(900)")
        // A role's hidden state (no pg_read_all_stats) isn't idle: Cancel is offered.
        let hidden = SQLServerInfo.Session(id: 902, user: "other")
        #expect(!hidden.isIdle && hidden.stateText == "state hidden")
        #expect(SQLServerPanel.refusal(.cancel, session: hidden, info: info) == nil)
    }

    @Test func runnerCodeQuotesItsArguments() {
        #expect(SQLServerPanel.code(parts: [.overview, .sessions], connection: nil).contains(#"SqlTab::server(["overview", "sessions"], null);"#))
        #expect(SQLServerPanel.code(parts: [.sizes], connection: "a \"$b\"").contains(#"SqlTab::server(["sizes"], "a \"\$b\"");"#))
        let plan = SQLServerActionPlan(action: .kill, dialect: "pgsql", session: 9, statement: "SELECT pg_terminate_backend(9)", server: "f00", listedBy: 3, user: "o'brien", started: "2026-10-04 08:00:00+00")
        #expect(SQLServerPanel.code(plan, connection: "pgsql").contains(#"SqlTab::serverAction("kill", "pgsql", 9, "SELECT pg_terminate_backend(9)", "pgsql", "f00", 3, "o'brien", "2026-10-04 08:00:00+00");"#))
    }

    @Test func refreshIsNeverOfferedOnProduction() {
        #expect(SQLServerPanel.refreshIntervals(isProduction: true).isEmpty)
        #expect(SQLServerPanel.refreshIntervals(isProduction: false) == [5, 10, 30])
    }

    @Test func formatting() {
        #expect(SQLServerPanel.bytes(0) == "0 B")
        #expect(SQLServerPanel.bytes(512) == "512 B")
        #expect(SQLServerPanel.bytes(1536) == "1.5 KB")
        #expect(SQLServerPanel.bytes(13_107_200) == "13 MB")
        #expect(SQLServerPanel.bytes(3_435_973_837) == "3.2 GB")
        #expect(SQLServerPanel.duration(0) == "0 s")
        #expect(SQLServerPanel.duration(45.9) == "45 s")
        #expect(SQLServerPanel.duration(720) == "12 min")
        #expect(SQLServerPanel.duration(3600) == "1 h")
        #expect(SQLServerPanel.duration(11_520) == "3 h 12 min")
        #expect(SQLServerPanel.duration(93_784) == "1 d 2 h")
        #expect(SQLServerPanel.count(1_234_567) == "1,234,567")
        #expect(SQLServerPanel.count(12) == "12")
        #expect(SQLServerPanel.oneLine("SELECT *\n  FROM orders\n\tWHERE id = 1") == "SELECT * FROM orders WHERE id = 1")
        #expect(SQLServerPanel.oneLine(String(repeating: "x", count: 400)).count == 301)
    }

    @Test func theConfirmationNamesTheSessionItsUserItsStartAndTheStatement() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let readAt = Date(timeIntervalSince1970: 1_791_100_000) // 07:46:40 UTC
        let info = try Self.decode()
        let worker = try #require(info.sessions?.list.first { $0.id == 77 })
        #expect(SQLServerPanel.sessionLine(worker, readAt: readAt, calendar: calendar) == "worker@10.0.0.5:51234 · database shop · Query · User sleep for 12 s (since about 07:46:28) · in a transaction for 30 s")
        guard case .success(let plan) = SQLServerPanel.plan(.kill, session: worker, info: info) else { return }
        #expect(SQLServerPanel.confirmationTitle(plan) == "Kill session 77?")
        let text = SQLServerPanel.confirmationText(plan, connection: "the saved connection “Shop”", openedFrom: "acme", isProduction: true, readOnly: true)
        #expect(text.contains("sends KILL 77 only after checking that it reached the server the list came from and that session 77 is still worker's"))
        #expect(text.contains("its open transaction is rolled back"))
        #expect(text.contains("read-only, but this changes no data"))
        #expect(text.contains("This connection is production."))
        #expect(text.hasSuffix("Runlet asks before every cancel and kill, on every connection."))
        guard case .success(let cancel) = SQLServerPanel.plan(.cancel, session: worker, info: info) else { return }
        #expect(SQLServerPanel.confirmationTitle(cancel) == "Cancel the statement of session 77?")
        #expect(!SQLServerPanel.confirmationText(cancel, connection: "c", openedFrom: "t", isProduction: false, readOnly: false).contains("production"))
    }

    @Test func actionReports() throws {
        func report(_ json: String) throws -> SQLServerActionReport {
            try JSONDecoder().decode(SQLServerActionReport.self, from: Data(json.utf8))
        }
        let killed = try report(#"{"action":"kill","outcome":"killed","driver":"mysql","session":77,"statement":"KILL 77","verified":true,"elapsedMs":57.6}"#)
        #expect(killed.message == "Killed session 77 (KILL 77): it's gone from the server's list.")
        #expect(killed.succeeded)
        let cancelled = try report(#"{"action":"cancel","outcome":"cancelled","driver":"pgsql","session":88,"statement":"SELECT pg_cancel_backend(88)","verified":false}"#)
        #expect(cancelled.message.hasPrefix("Cancelled the statement of session 88 (pg_cancel_backend(88)). Runlet couldn't watch it stop"))
        let refused = try report(#"{"action":"kill","outcome":"refused","driver":"mysql","session":42,"statement":"KILL 42","detail":"session 42 is the one the panel read the list with"}"#)
        #expect(refused.message == "Runlet didn't send KILL 42: session 42 is the one the panel read the list with.")
        #expect(!refused.succeeded)
        let unknown = try report(#"{"action":"kill","outcome":"exploded","driver":"mysql","session":1,"statement":"KILL 1"}"#)
        #expect(unknown.outcome == .failed)
        let still = SQLServerActionReport(action: .kill, outcome: .stillRunning, driver: "mysql", session: 5, statement: "KILL 5", state: "Killed", elapsedMs: 2000)
        #expect(still.message == "The server accepted KILL 5, but session 5 was still listed 2.0 s later (Killed). The server finishes ending it, and undoing its changes, on its own.")
        #expect(SQLServerActionReport(action: .cancel, outcome: .idle, driver: "pgsql", session: 5, statement: "SELECT pg_cancel_backend(5)", state: "idle in transaction").message == "Session 5 ran no statement (idle in transaction), so there was nothing to cancel. Nothing was sent.")
        #expect(SQLServerActionReport(action: .kill, outcome: .alreadyEnded, driver: "pgsql", session: 5, statement: "x").message == "Session 5 had already ended on the server.")
        #expect(SQLServerActionReport(action: .kill, outcome: .timedOut, driver: "pgsql", session: 5, statement: "SELECT pg_terminate_backend(5)").message.contains("within 15 s"))
        #expect(SQLServerActionReport(action: .kill, outcome: .failed, driver: "mysql", session: 5, statement: "KILL 5", detail: "Lost connection.").message == "KILL 5 failed: Lost connection.")
        // The Run Log names the action and the outcome, never the session's statement.
        #expect(killed.logMessage(connection: "the default connection") == "Database pane: Kill Session on session 77 (KILL 77) through the default connection: killed")
    }

    @Test func sessionsFilterAndDescribeThemselves() throws {
        let info = try Self.decode()
        let worker = try #require(info.sessions?.list.first)
        #expect(worker.matches("nightly") && worker.matches("WORKER") && worker.matches("77") && worker.matches(" "))
        #expect(!worker.matches("p150"))
        #expect(worker.stateText == "Query · User sleep")
        #expect(worker.userAndHost == "worker@10.0.0.5:51234")
        #expect(SQLServerInfo.Session(id: 1).userAndHost == "unknown user")
        #expect(SQLServerInfo.Session(id: 1, query: "x", queryBytes: 9000).queryTruncated)
    }
}
