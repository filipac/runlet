import Foundation
@testable import RunletCore
import Testing

/// Stop cancels an SQL tab's statement on the server (#144): the plan per dialect, the second
/// runner's PHP, the events, and what the output says.
struct SQLCancelTests {
    @Test func planPerDialect() throws {
        let mysql = try #require(SQLCancel.plan(driver: "mysql", session: 4711))
        #expect(mysql.dialect == "mysql")
        #expect(mysql.statement == "KILL QUERY 4711")
        #expect(mysql.shortText == "KILL QUERY 4711")
        #expect(!mysql.endsSession)

        let pgsql = try #require(SQLCancel.plan(driver: "pgsql", session: 812))
        #expect(pgsql.statement == "SELECT pg_cancel_backend(812)")
        #expect(pgsql.shortText == "pg_cancel_backend(812)")

        // SQL Server has no KILL QUERY: KILL ends the session (untested live, #53).
        for driver in ["sqlsrv", "dblib", "SQLSRV"] {
            let plan = try #require(SQLCancel.plan(driver: driver, session: 57), "\(driver)")
            #expect(plan.dialect == "sqlsrv")
            #expect(plan.statement == "KILL 57")
            #expect(plan.endsSession)
        }
    }

    @Test func noPlanWithoutAServerSession() {
        // SQLite runs in the runner's process: stopping it is enough.
        #expect(SQLCancel.plan(driver: "sqlite", session: 1) == nil)
        #expect(SQLCancel.plan(driver: "oci", session: 1) == nil)
        #expect(SQLCancel.plan(driver: nil, session: 1) == nil)
        #expect(SQLCancel.plan(driver: "mysql", session: 0) == nil)
        #expect(SQLCancel.plan(driver: "pgsql", session: -3) == nil)
    }

    @Test func cancelCodeCarriesOnlyTheSessionTheConnectionNameAndTheFingerprint() throws {
        let session = SQLSessionInfo(driver: "mysql", id: 4711, connection: "report\"ing $x", server: "abc123")
        let plan = try #require(SQLCancel.plan(for: session))
        let code = SQLCancel.code(plan, session: session)
        #expect(code.hasPrefix("<?php\n"))
        #expect(code.contains(#"\RunletRunner\SqlTab::cancel("mysql", 4711, "KILL QUERY 4711", "report\"ing \$x", "abc123");"#), "\(code)")
        // The default (or a saved) connection has no name, and an unknown server no fingerprint.
        let saved = SQLSessionInfo(driver: "pgsql", id: 9, saved: true)
        let savedCode = SQLCancel.code(try #require(SQLCancel.plan(for: saved)), session: saved)
        #expect(savedCode.contains(#"SqlTab::cancel("pgsql", 9, "SELECT pg_cancel_backend(9)", null, "");"#), "\(savedCode)")
    }

    @Test func sessionEventDecodes() throws {
        let json = #"{"driver":"pgsql","id":812,"connection":"reporting","transaction":true,"server":"f00d","extra":1}"#
        let session = try JSONDecoder().decode(SQLSessionInfo.self, from: Data(json.utf8))
        #expect(session == SQLSessionInfo(driver: "pgsql", id: 812, connection: "reporting", transaction: true, server: "f00d"))
        #expect(session.logMessage == "Database session 812 (pgsql): Stop cancels its statement with SELECT pg_cancel_backend(812)")
        let sqlite = SQLSessionInfo(driver: "sqlite", id: 1)
        #expect(sqlite.logMessage.hasSuffix("Stop ends the runner only"))
    }

    @Test func reportDecodesAndUnknownOutcomesFail() throws {
        let json = #"{"outcome":"stillRunning","driver":"mysql","session":4711,"statement":"KILL QUERY 4711","state":"Killed, rollback","elapsedMs":1520.5,"verified":true}"#
        let report = try JSONDecoder().decode(SQLCancelReport.self, from: Data(json.utf8))
        #expect(report.outcome == .stillRunning)
        #expect(report.state == "Killed, rollback")
        #expect(!report.succeeded)
        let future = #"{"outcome":"somethingNew","driver":"mysql","session":1,"statement":"KILL QUERY 1"}"#
        #expect(try JSONDecoder().decode(SQLCancelReport.self, from: Data(future.utf8)).outcome == .failed)
    }

    @Test func messages() {
        func report(_ outcome: SQLCancelReport.Outcome, driver: String = "mysql", detail: String? = nil, transaction: Bool? = nil) -> SQLCancelReport {
            let plan = SQLCancel.plan(driver: driver, session: 4711)!
            return SQLCancelReport(outcome: outcome, driver: driver, session: 4711, statement: plan.statement, detail: detail, state: outcome == .stillRunning ? "Killed" : nil, transaction: transaction, elapsedMs: 1500)
        }
        #expect(report(.cancelled).message == "Cancelled the statement on the server (KILL QUERY 4711).")
        #expect(report(.cancelled, driver: "pgsql").message == "Cancelled the statement on the server (pg_cancel_backend(4711)).")
        #expect(report(.cancelled, driver: "sqlsrv").message.contains("SQL Server's KILL ended the session"))
        #expect(report(.cancelled).succeeded && report(.idle).succeeded && report(.alreadyEnded).succeeded)
        #expect(report(.stillRunning).message == "The server accepted KILL QUERY 4711, but the statement was still running 1.5 s later (Killed). The database finishes cancelling it, and undoing its changes, on its own.")
        #expect(report(.idle).message == "The statement had already finished on the server (session 4711 was idle), so there was nothing to cancel.")
        #expect(report(.alreadyEnded).message == "Session 4711 had already ended on the server, so there was no statement to cancel.")

        let refused = report(.refused, detail: "the database user may not cancel session 4711 (You are not owner of thread 4711).")
        #expect(refused.message == "Runlet didn't cancel the statement on the server: the database user may not cancel session 4711 (You are not owner of thread 4711). It keeps running until it ends or the database notices the closed connection.")
        #expect(!refused.succeeded)
        #expect(report(.refused, driver: "pgsql", detail: "nope").message.hasSuffix("It may run to its end: PostgreSQL usually notices the closed connection only then."))
        #expect(report(.failed, detail: "SQLSTATE[HY000] [2002] Connection refused").message.hasPrefix("Runlet couldn't cancel the statement on the server (KILL QUERY 4711): SQLSTATE[HY000] [2002] Connection refused. "))
        #expect(report(.failed).message.hasPrefix("Runlet couldn't cancel the statement on the server (KILL QUERY 4711). "))
        #expect(report(.timedOut).message.hasPrefix("Runlet couldn't cancel the statement on the server: the second runner didn't answer within 8 s."))
    }

    @Test func runAllInATransactionSaysWhatHappensToIt() {
        let plan = SQLCancel.plan(driver: "mysql", session: 1)!
        let mysql = SQLCancelReport(outcome: .cancelled, driver: "mysql", session: 1, statement: plan.statement, transaction: true)
        #expect(mysql.message.hasSuffix(" The open transaction is rolled back (statements MySQL committed at once stay)."))
        let pgsql = SQLCancelReport(outcome: .cancelled, driver: "pgsql", session: 1, statement: "SELECT pg_cancel_backend(1)", transaction: true)
        #expect(pgsql.message.hasSuffix(" The open transaction is rolled back."))
        let failed = SQLCancelReport(outcome: .refused, driver: "pgsql", session: 1, statement: "SELECT pg_cancel_backend(1)", transaction: true)
        #expect(failed.message.hasSuffix(" The database rolls back the open transaction once the statement ends and it notices the closed connection."))
        let single = SQLCancelReport(outcome: .cancelled, driver: "pgsql", session: 1, statement: "SELECT pg_cancel_backend(1)")
        #expect(!single.message.contains("transaction"))
    }

    @Test func cancelEventKindHasAName() {
        let report = SQLCancelReport(outcome: .cancelled, driver: "mysql", session: 1, statement: "KILL QUERY 1")
        #expect(RunEvent.Kind.sqlCancel(report).typeName == "sqlCancel")
    }
}
