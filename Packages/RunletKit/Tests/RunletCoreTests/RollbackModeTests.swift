import Foundation
@testable import RunletCore
import Testing

/// Rollback ("dry run") mode (#13): the request flag, the tab's saved toggle, and the runner's
/// reports as the output and AI clients show them.
struct RollbackModeTests {
    static func target() -> TargetSnapshot {
        TargetSnapshot(kind: .local, label: "test", targetId: "t", workingDirectory: "/tmp", phpExecutable: "/usr/bin/php")
    }

    @Test func requestsCarryTheFlagAdditively() throws {
        var request = RunRequest(tabId: UUID(), documentVersion: 1, target: Self.target(), code: "1")
        #expect(request.rollback == false)
        request.rollback = true
        let encoded = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(RunRequest.self, from: encoded).rollback == true)
        // A request encoded before the flag existed decodes as a normal run.
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["rollback"] = nil
        let older = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(RunRequest.self, from: older).rollback == false)
    }

    @Test func tabsSaveTheToggleOnlyWhenOn() throws {
        let on = TabState(title: "Fix", code: "1", rollback: true)
        #expect(try JSONDecoder().decode(TabState.self, from: JSONEncoder().encode(on)).rollback == true)
        let off = TabState(title: "Fix", code: "1", rollback: false)
        #expect(off.rollback == nil)
        let json = try #require(String(data: try JSONEncoder().encode(off), encoding: .utf8))
        #expect(!json.contains("rollback"), "\(json)")
        // Sessions saved before #13 restore with Dry Run off.
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(on)) as? [String: Any])
        object["rollback"] = nil
        #expect(try JSONDecoder().decode(TabState.self, from: JSONSerialization.data(withJSONObject: object)).rollback == nil)
    }

    static func report(_ json: String) throws -> RollbackReport {
        try JSONDecoder().decode(RollbackReport.self, from: Data(json.utf8))
    }

    @Test func aCleanRollbackSaysHowManyStatements() throws {
        let report = try Self.report(#"{"state":"finished","reason":"completed","statements":4,"reads":2,"connections":[{"name":"default","driver":"sqlite","api":"eloquent","status":"rolledBack","writes":2,"reads":1,"saved":0},{"name":"reports","driver":"sqlite","api":"doctrine","status":"rolledBack","writes":2,"reads":1,"saved":0}],"warnings":[]}"#)
        #expect(report.title == "Rolled back 4 statements on default and reports")
        #expect(!report.hasProblems)
        #expect(report.details == ["default (sqlite): rolled back 2 statements; 1 read.", "reports (sqlite): rolled back 2 statements; 1 read."])
        #expect(report.plainText.hasPrefix("Rolled back 4 statements on default and reports\n"))
    }

    @Test func nothingToRollBack() throws {
        let report = try Self.report(#"{"state":"finished","statements":0,"connections":[{"name":"mysql","driver":"mysql","api":"eloquent","status":"rolledBack","writes":0,"reads":3,"saved":0}]}"#)
        #expect(report.title == "Nothing to roll back on mysql")
        #expect(report.details == ["mysql: no changes to roll back; 3 reads."])
        let none = try Self.report(#"{"state":"finished","statements":0,"connections":[]}"#)
        #expect(none.title == "Dry run: no database connection to roll back")
    }

    @Test func implicitCommitsAndUnwrappedConnectionsAreProblems() throws {
        let report = try Self.report(#"""
        {"state":"finished","reason":"completed","statements":1,"reads":1,
         "connections":[{"name":"mariadb","driver":"mariadb","api":"eloquent","status":"rolledBack","writes":3,"reads":1,"saved":2,
                         "commits":[{"how":"implicit","sql":"ALTER TABLE p13_items ADD COLUMN extra INT NULL","reopened":true,"inSnippet":true,"snippetLine":3}]},
                        {"name":"audit","status":"notWrapped","writes":1,"saved":1}],
         "warnings":[{"kind":"implicitCommit","message":"ALTER TABLE … committed the transaction on mariadb","connection":"mariadb","inSnippet":true,"snippetLine":3}],
         "omittedWarnings":2}
        """#)
        #expect(report.title == "Rolled back 1 statement on mariadb · 3 statements saved")
        #expect(report.hasProblems)
        #expect(report.wrapped.map(\.name) == ["mariadb"])
        #expect(report.details.contains("audit: not in the dry run; 1 statement that can change data saved."), "\(report.details)")
        #expect(report.details.first == "mariadb: rolled back 1 statement; 2 statements saved before Runlet's transaction began again; 1 read.")
        #expect(report.warnings?.first?.summary == "A statement committed the transaction on mariadb (an implicit commit).")
        #expect(report.plainText.contains("⚠︎ ALTER TABLE … committed the transaction on mariadb"))
        #expect(report.plainText.contains("(2 more warnings)"))
        #expect(report.connections?.first?.commits?.first?.reopened == true)
    }

    @Test func refusedStatementsAreListedButSavedNothing() throws {
        let report = try Self.report(#"""
        {"state":"finished","reason":"error","statements":1,"reads":0,
         "connections":[{"name":"mariadb","driver":"mariadb","api":"eloquent","status":"rolledBack","writes":1,"reads":0,"saved":0}],
         "warnings":[{"kind":"refused","message":"Runlet refused ALTER TABLE p13_items ADD COLUMN extra INT NULL (line 3) on mariadb before it ran.","connection":"mariadb","sql":"ALTER TABLE p13_items ADD COLUMN extra INT NULL","inSnippet":true,"snippetLine":3}]}
        """#)
        #expect(report.title == "Rolled back 1 statement on mariadb")
        // It never ran: the card isn't a warning.
        #expect(!report.hasProblems)
        let warning = try #require(report.warnings?.first)
        #expect(warning.isRefusal && warning.raisesError)
        #expect(warning.summary == "ALTER TABLE p13_items ADD COLUMN extra INT NULL was refused on mariadb before it ran (line 3): a dry run can't roll it back.")
        #expect(report.plainText.contains("⚠︎ Runlet refused ALTER TABLE"))
        // A kind from a newer runner decodes and shows its message.
        let newer = try Self.report(#"{"state":"finished","connections":[],"warnings":[{"kind":"somethingNew","message":"Something new happened."}]}"#)
        #expect(newer.warnings?.first?.summary == "Something new happened.")
        #expect(newer.warnings?.first?.raisesError == false)
        #expect(newer.hasProblems)
    }

    @Test func aTransactionThatCouldntBeginIsInTheTitle() throws {
        let before = try Self.report(#"""
        {"state":"finished","reason":"error","statements":0,"reads":0,
         "connections":[{"name":"ledger","driver":"sqlite","api":"pdo","status":"rolledBack","writes":0,"reads":0,"saved":0},
                        {"name":"locked","driver":"sqlite","api":"pdo","status":"notStarted","writes":0,"reads":0,"saved":0,"error":"it was already in a transaction"}],
         "warnings":[{"kind":"notStarted","message":"Runlet couldn't begin a transaction on locked: it was already in a transaction. A dry run runs nothing on a connection it can't roll back, so nothing ran.","connection":"locked"}]}
        """#)
        #expect(before.title == "Nothing to roll back on ledger · no transaction on locked")
        #expect(before.hasProblems)
        #expect(before.details.last == "locked (sqlite): no transaction (it was already in a transaction); nothing ran there.")
        #expect(before.warnings?.first?.raisesError == true)
        #expect(before.warnings?.first?.isRefusal == false)
        let only = try Self.report(#"{"state":"finished","statements":0,"connections":[{"name":"sqlite","driver":"sqlite","api":"eloquent","status":"notStarted","writes":0,"saved":0,"error":"no such file"}]}"#)
        #expect(only.title == "Dry run: no transaction on sqlite")
        let mixed = try Self.report(#"{"state":"finished","statements":2,"connections":[{"name":"mysql","status":"rolledBack","writes":2,"saved":0},{"name":"reporting","status":"notStarted","writes":0,"saved":0}]}"#)
        #expect(mixed.title == "Rolled back 2 statements on mysql · no transaction on reporting")
    }

    @Test func statusesFromNewerRunnersDecode() throws {
        let report = try Self.report(#"{"state":"finished","connections":[{"name":"x","status":"somethingNew","writes":1}]}"#)
        #expect(report.connections?.first?.status == .unknown)
    }

    @Test func warningsAndStops() throws {
        let warning = try Self.report(#"{"state":"warning","warning":{"kind":"committed","message":"COMMIT (line 2) committed Runlet's transaction on pgsql","connection":"pgsql","sql":"COMMIT","inSnippet":true,"snippetLine":2}}"#)
        #expect(warning.title == "Dry run: COMMIT (line 2) committed Runlet's transaction on pgsql")
        #expect(warning.details.isEmpty)
        let stopped = RollbackReport.stopped(reason: "cancelled", connections: [.init(name: "mysql", status: .rolledBack)])
        #expect(stopped.title == "Stopped before Runlet rolled back")
        #expect(stopped.details.first?.hasPrefix("The database discards the open transaction when the connection closes") == true)
        #expect(stopped.details.last == "Connections in the dry run: mysql.")
    }

    @Test func aiClientsHearAboutTheDryRun() throws {
        var mcp = MCPRunReport(clientName: "Claude", tabTitle: "Fix", targetLabel: "Sandbox")
        mcp.apply(.rollback(try Self.report(#"{"state":"begun","connections":[]}"#)))
        mcp.apply(.rollback(try Self.report(#"{"state":"warning","warning":{"kind":"notWrapped","message":"INSERT … ran on audit, a connection this dry run doesn't wrap"}}"#)))
        // A refusal reaches the client as the run's error; the outcome lists it again.
        mcp.apply(.rollback(try Self.report(#"{"state":"warning","warning":{"kind":"refused","message":"Runlet refused ALTER TABLE t on mysql before it ran."}}"#)))
        mcp.apply(.rollback(try Self.report(#"{"state":"finished","statements":2,"connections":[{"name":"mysql","driver":"mysql","status":"rolledBack","writes":2,"reads":0,"saved":0}]}"#)))
        #expect(mcp.entries == [
            .notice("Dry run: INSERT … ran on audit, a connection this dry run doesn't wrap"),
            .notice("Rolled back 2 statements on mysql\nmysql: rolled back 2 statements."),
        ])
    }
}

extension RollbackReport.Connection {
    init(name: String, status: Status) {
        self.init(name: name, driver: nil, api: nil, status: status, writes: nil, reads: nil, saved: nil, error: nil, commits: nil)
    }
}
