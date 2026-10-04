import Foundation
@testable import RunletCore
import Testing

/// MongoDB's Stop on the server and Server section (#207), without a server.
struct MongoServerTests {
    static let tag = "runlet:0b6c7f1e-2d3a-4c5b-8e9f-0a1b2c3d4e5f"

    @Test func stopPlansKillOpByTheRunsTag() throws {
        let session = SQLSessionInfo(driver: "mongodb", id: 0, saved: true, server: "0123456789abcdef", tag: Self.tag)
        let plan = try #require(SQLCancel.plan(for: session))
        #expect(plan.dialect == "mongodb" && plan.statement == "killOp" && plan.tag == Self.tag && plan.noun == "operation")
        let code = SQLCancel.code(plan, session: session)
        #expect(code.contains(#"\RunletRunner\MongoTab::cancel("runlet:0b6c7f1e-2d3a-4c5b-8e9f-0a1b2c3d4e5f", null, "0123456789abcdef");"#), "\(code)")
        #expect(session.logMessage == "MongoDB operations tagged \(Self.tag): Stop finds them with currentOp and kills them with killOp")
        #expect(session.managerText == "Operations tagged \(Self.tag)")
        // No tag (a server before 4.4) or a tag Runlet didn't make: Stop ends the runner only.
        #expect(SQLCancel.plan(for: SQLSessionInfo(driver: "mongodb", id: 0)) == nil)
        #expect(SQLCancel.plan(for: SQLSessionInfo(driver: "mongodb", id: 0, tag: "runlet:x'); evil();")) == nil)
        #expect(SQLCancel.plan(driver: "mongodb", session: 5) == nil)
        // SQL sessions are unchanged.
        #expect(SQLCancel.plan(for: SQLSessionInfo(driver: "mysql", id: 7))?.statement == "KILL QUERY 7")
        #expect(SQLSessionInfo(driver: "pgsql", id: 7).managerText == "Database session 7")
    }

    @Test func killOpsErrorReadsAsInterruptedByStop() {
        let killed = RunErrorInfo(stage: .execute, message: "MongoDB aggregate failed. Check the connection, permissions, and query shape. Driver code: 11601")
        #expect(SQLCancel.isCancellationError(killed, driver: "mongodb"))
        #expect(!SQLCancel.isCancellationError(RunErrorInfo(stage: .execute, message: "MongoDB find failed. … Driver code: 50"), driver: "mongodb"), "maxTimeMS isn't Stop")
        #expect(!SQLCancel.isCancellationError(killed, driver: "mysql"))
        #expect(SQLCancel.interruptedText(killed) == "Interrupted by Stop.")
    }

    @Test func reportsSayKilledOperations() {
        var report = SQLCancelReport(outcome: .cancelled, driver: "mongodb", session: 0, statement: "killOp 4711", verified: true)
        #expect(report.message == "Killed the operation on the server (killOp 4711).")
        report.outcome = .idle
        #expect(report.message == "The operation had already finished on the server, so there was nothing to kill.")
        report.outcome = .refused
        report.detail = "operation 4711 runs as another MongoDB user"
        #expect(report.message.hasPrefix("Runlet didn't kill the operation on the server: operation 4711 runs as another MongoDB user. It keeps running"))
        report.outcome = .timedOut
        #expect(report.message.contains("didn't answer within 8 s"))
    }

    @Test func serverReportDecodesAndSummarises() throws {
        let json = """
        {"server":"0123456789abcdef","host":"127.0.0.1:27017","listedBy":"runlet:x:panel",
         "replica":{"setName":"rs0","state":"PRIMARY","primary":"127.0.0.1:27207"},
         "status":{"version":"7.0.14","uptime":11580,"connections":{"current":12,"available":838848,"totalCreated":40},"memory":{"residentMB":151,"virtualMB":2600},"storageEngine":"wiredTiger","opcounters":{"insert":3,"query":9}},
         "operations":[{"opid":"4711","numeric":true,"op":"command","ns":"shop.orders","client":"172.18.0.1:50000","users":["runlet@admin"],"active":true,"micros":12400000,"comment":"runlet:abc","command":"{\\"aggregate\\":\\"orders\\"}"},
                       {"opid":"4712","numeric":true,"op":"command","ns":"admin.$cmd.aggregate","own":true,"micros":300}],
         "ownOnly":false}
        """
        let report = try JSONDecoder().decode(MongoServerReport.self, from: Data(json.utf8))
        #expect(report.summary == "MongoDB 7.0.14 · up 3 h 13 min · 12 connections (\(838_848.formatted()) available) · 151 MB resident · replica set rs0 PRIMARY")
        let operation = try #require(report.operations?.first)
        #expect(operation.runningText == "running 12.4 s" && operation.isRunlet && operation.title == "command on shop.orders")
        #expect(report.operations?.last?.runningText == "running 0 ms")
        #expect(MongoServerPanel.refusal(try #require(report.operations?.last)) != nil)
        #expect(MongoServerPanel.refusal(operation) == nil)
        let code = MongoServerPanel.killCode(operation, report: report, connection: nil)
        #expect(code == #"\RunletRunner\MongoTab::killOp(4711, "0123456789abcdef", "runlet:x:panel", "shop.orders", "command", null);"#, "\(code)")
        var mongos = operation
        mongos.opid = "shard01:4711"
        mongos.numeric = nil
        #expect(MongoServerPanel.killCode(mongos, report: report, connection: "mongodb").hasPrefix(#"\RunletRunner\MongoTab::killOp("shard01:4711", "#))
        let standalone = MongoServerReport(server: "x", listedBy: "y", status: .init(version: "7.0.14"))
        #expect(standalone.summary == "MongoDB 7.0.14 · standalone")
        #expect(MongoServerReport.duration(42) == "42 s" && MongoServerReport.duration(90_000) == "1 d 1 h")
    }

    @Test func killOpAlwaysConfirmsInTheDangerSheet() {
        let operation = MongoServerReport.Operation(opid: "4711", op: "update", ns: "shop.orders", client: "10.0.0.5:5000", users: ["app@admin"], micros: 3_000_000, command: "{\"q\":{}}")
        let confirmation = DatabaseDangerConfirmation.mongoKill(operation, connection: "the saved connection “Docs” (mongodb, db:27017/shop)", isProduction: true, tabId: UUID()) {}
        #expect(confirmation.title == "Kill operation 4711 (update on shop.orders) through the saved connection “Docs” (mongodb, db:27017/shop)?")
        #expect(confirmation.confirmTitle == "Kill Op" && confirmation.identifier == "mongo-kill" && confirmation.family == .mongodb)
        let item = confirmation.items[0]
        #expect(item.name == "killOp" && item.text == "{\"q\":{}}")
        #expect(item.danger.contains("client 10.0.0.5:5000") && item.danger.contains("as app@admin") && item.danger.contains("running 3.0 s"))
        #expect(item.danger.contains("what it already wrote stays") && item.danger.hasSuffix("on a production connection"))
        // The query confirmations keep their wording.
        let drop = DatabaseDangerConfirmation.mongo(try! MongoQuery(#"{"collection":"orders","operation":"drop"}"#), line: 1, database: "shop", connection: "c", tabId: UUID()) {}
        #expect(drop?.confirmTitle == "Run drop" && drop?.identifier == "mongo-danger")
        #expect(MongoServerPanel.refreshIntervals(isProduction: true).isEmpty && !MongoServerPanel.refreshIntervals(isProduction: false).isEmpty)
    }
}
