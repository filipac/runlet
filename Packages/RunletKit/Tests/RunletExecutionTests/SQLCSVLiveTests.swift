import Foundation
@testable import RunletCore
import Testing
@testable import RunletExecution

/// Export Query to CSV and Import CSV (#152) against live MariaDB 11 and PostgreSQL 14, through
/// `RUNLET_TEST_MYSQL` / `RUNLET_TEST_PGSQL`: 100,000 rows generated on the server stream in
/// bounded frames with steady memory, Stop cancels an export on the server and leaves no file,
/// and imports insert in one transaction, roll back at the first error, coerce empty fields to
/// NULL, and are refused on a read-only saved connection. The tests use their own `p152_` table.
@Suite(.serialized, .enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct SQLCSVLiveTests {
    typealias Server = SQLLiveDatabaseTests.Server

    /// `count` rows generated on the server: `n`, a label, a decimal, and NULL for every 10th.
    static func generated(_ server: Server, count: Int) -> String {
        server.dialect == "mysql"
            ? "SELECT seq AS n, CONCAT('row ', seq) AS label, seq / 4 AS amount, IF(seq % 10 = 0, NULL, seq % 7) AS bucket FROM seq_1_to_\(count) ORDER BY seq"
            : "SELECT n, 'row ' || n AS label, n / 4.0 AS amount, CASE WHEN n % 10 = 0 THEN NULL ELSE n % 7 END AS bucket FROM generate_series(1, \(count)) AS n ORDER BY n"
    }

    /// Runs an export through the engine and writes its frames as the app does.
    static func export(_ server: Server, _ statement: String, in directory: URL, options: SQLCSVExportOptions = SQLCSVExportOptions()) async throws -> (events: [RunEvent], writer: SQLCSVExportWriter) {
        let writer = try SQLCSVExportWriter(destination: directory.appendingPathComponent("export.csv"), options: options)
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
        let request = RunRequest(tabId: UUID(), documentVersion: 1, target: DriverSupport.target(directory.path), code: SQLCSVExport.code(statement: statement, connection: nil), inspector: RunInspectorOptions(), magicComments: false)
        var events: [RunEvent] = []
        for await event in try await engine.start(request) {
            if case .sqlExport(let frame) = event.kind {
                try writer.write(frame)
                // The app holds one frame at a time: keep only the frame's size here.
                events.append(RunEvent(runId: event.runId, sequence: event.sequence, kind: .sqlExport(SQLExportFrame(columns: frame.columns, total: frame.total, done: frame.done, driver: frame.driver, bytes: frame.rows.map { $0.count }))))
            } else {
                events.append(event)
            }
        }
        if events.errors.isEmpty, events.sqlExportFrames.last?.done == true { try writer.finish() } else { writer.abandon() }
        return (events, writer)
    }

    @Test(.enabled(if: !SQLLiveDatabaseTests.servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"), .timeLimit(.minutes(3)))
    func exportsAHundredThousandRowsWithSteadyMemory() async throws {
        for server in SQLLiveDatabaseTests.servers {
            let directory = try server.project()
            defer { try? FileManager.default.removeItem(at: directory) }
            let (small, _) = try await Self.export(server, Self.generated(server, count: 10), in: directory)
            #expect(small.errors.isEmpty, "\(server.dialect): \(small.errors)")
            let (events, writer) = try await Self.export(server, Self.generated(server, count: 100_000), in: directory)
            #expect(events.errors.isEmpty, "\(server.dialect): \(events.errors)")
            let frames = events.sqlExportFrames
            #expect(frames.first?.columns == ["n", "label", "amount", "bucket"])
            #expect(frames.last?.done == true)
            #expect(frames.last?.total == 100_000, "\(server.dialect)")
            // Every frame holds at most 1,000 rows; the writer held one at a time.
            let sizes = frames.compactMap(\.bytes)
            #expect(sizes.count >= 100 && sizes.allSatisfy { $0 <= 1000 }, "\(server.dialect): \(sizes.max() ?? 0)")
            #expect(writer.largestFrame <= 1000)
            #expect(writer.rows == 100_000)
            // The runner's memory doesn't grow with the rows: within 8 MiB of a 10-row export's.
            let peak = try #require(events.finished?.peakMemory)
            let baseline = try #require(small.finished?.peakMemory)
            #expect(peak - baseline < 8 * 1024 * 1024, "\(server.dialect): peak \(peak) bytes, baseline \(baseline)")
            // The file: a header and 100,000 lines, each row as the result shows it.
            let text = try String(contentsOf: writer.destination, encoding: .utf8)
            let lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
            #expect(lines.count == 100_001, "\(server.dialect)")
            #expect(lines.first == "n,label,amount,bucket")
            #expect(lines[1].hasPrefix("1,row 1,"), "\(server.dialect): \(lines[1])")
            #expect(lines[10].hasPrefix("10,row 10,") && lines[10].hasSuffix(","), "\(server.dialect): every 10th bucket is NULL: \(lines[10])")
            #expect(lines.last?.hasPrefix("100000,row 100000,") == true)
            print("#152 \(server.dialect): 100,000 rows, \(writer.bytes) bytes, \(frames.count) frames, runner peak \(peak / 1024) KiB (10 rows: \(baseline / 1024) KiB)")
        }
    }

    @Test(.enabled(if: !SQLLiveDatabaseTests.servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"), .timeLimit(.minutes(2)))
    func stopCancelsAnExportOnTheServerAndLeavesNoFile() async throws {
        for server in SQLLiveDatabaseTests.servers {
            let directory = try server.project()
            defer { try? FileManager.default.removeItem(at: directory) }
            let destination = directory.appendingPathComponent("big.csv")
            let writer = try SQLCSVExportWriter(destination: destination, options: SQLCSVExportOptions())
            let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
            // Far more rows than a test waits for, sorted so the server works before the first row.
            let request = RunRequest(tabId: UUID(), documentVersion: 1, target: DriverSupport.target(directory.path), code: SQLCSVExport.code(statement: Self.generated(server, count: 20_000_000), connection: nil), inspector: RunInspectorOptions(), magicComments: false)
            var events: [RunEvent] = []
            var outcome: CancelOutcome?
            let started = ContinuousClock.now
            var stoppedAt: ContinuousClock.Instant?
            for await event in try await engine.start(request) {
                if case .sqlExport(let frame) = event.kind { try writer.write(frame) }
                events.append(event)
                let waited = ContinuousClock.now - started
                if outcome == nil, stoppedAt == nil, writer.rows >= 3000 || (events.contains { if case .sqlSession = $0.kind { true } else { false } } && waited > .seconds(2)) {
                    stoppedAt = .now
                    outcome = await engine.cancel(runId: request.runId)
                }
            }
            writer.abandon()
            #expect(events.finished?.status == .cancelled, "\(server.dialect): \(events.errors)")
            #expect(stoppedAt.map { ContinuousClock.now - $0 < .seconds(6) } == true, "\(server.dialect): Stop is quick")
            // #144: the server cancels the statement, or (between two of PostgreSQL's FETCHes) the
            // session runs nothing at that moment; either way the runner stops and its connection
            // closes with it.
            let server144 = outcome?.server?.outcome
            #expect(server144 == .cancelled || server144 == .idle, "\(server.dialect): \(String(describing: outcome?.server))")
            print("#152 \(server.dialect): Stop after \(writer.rows) rows; server cancel: \(server144.map(\.rawValue) ?? "none")")
            #expect(events.sqlExportFrames.last?.done != true)
            #expect(!FileManager.default.fileExists(atPath: destination.path), "\(server.dialect): no export file")
            #expect(!FileManager.default.fileExists(atPath: writer.partial.path), "\(server.dialect): no partial file")
        }
    }

    /// `p152_items`: an id, a required name, an optional integer, and a unique code.
    static func setupImport(_ server: Server) throws {
        _ = try server.exec("DROP TABLE IF EXISTS p152_items")
        if server.dialect == "mysql" {
            _ = try server.exec("CREATE TABLE p152_items (id INT PRIMARY KEY, name VARCHAR(40) NOT NULL, qty INT NULL, code VARCHAR(10) NULL UNIQUE) ENGINE=InnoDB")
        } else {
            _ = try server.exec("CREATE TABLE p152_items (id INT PRIMARY KEY, name VARCHAR(40) NOT NULL, qty INT NULL, code VARCHAR(10) NULL UNIQUE)")
        }
        _ = try server.exec("INSERT INTO p152_items (id, name) VALUES (1, 'existing')")
    }

    static let columns = [SQLSchemaInfo.Column(name: "id", type: "int", primaryKey: true), SQLSchemaInfo.Column(name: "name", type: "varchar"), SQLSchemaInfo.Column(name: "qty", type: "int"), SQLSchemaInfo.Column(name: "code", type: "varchar")]

    func importCSV(_ server: Server, _ csv: String, emptyIsNull: Bool = true, saved: DatabaseConnection? = nil) async throws -> (SQLCSVImport, [RunEvent]) {
        var plan = try SQLCSVImport.parse(csv, table: "p152_items", tableColumns: Self.columns, driver: server.dialect)
        plan.emptyIsNull = emptyIsNull
        let directory = try saved == nil ? server.project() : SQLSavedConnectionTests.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        return (plan, try await SQLCSVExecutionTests.runImport(plan, connection: saved, in: directory, password: server.password))
    }

    @Test(.enabled(if: !SQLLiveDatabaseTests.servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func importsInOneTransactionAndRollsBackAtTheFirstError() async throws {
        for server in SQLLiveDatabaseTests.servers {
            try Self.setupImport(server)
            var csv = "code,name,id,qty\n"
            for id in 2...2501 { csv += "c\(id),item \(id),\(id),\(id % 9)\n" }
            let (plan, events) = try await importCSV(server, csv)
            #expect(plan.mapping == [2, 1, 3, 0], "\(server.dialect): mapped by name")
            #expect(events.errors.isEmpty, "\(server.dialect): \(events.errors)")
            #expect(events.sqlImportReports.last?.done == true)
            #expect(events.sqlImportReports.last?.inserted == 2500)
            #expect(try server.exec("SELECT COUNT(*) FROM p152_items") == "2501")

            // A duplicate code at row 1,800: nothing of this file stays.
            try Self.setupImport(server)
            var bad = "id,name,code\n"
            for id in 2...2501 { bad += "\(id),item \(id),\(id == 1801 ? "c5" : "c\(id)")\n" }
            let (badPlan, failed) = try await importCSV(server, bad)
            let report = try #require(failed.sqlImportReports.last, "\(server.dialect)")
            #expect(report.failedRow == 1800, "\(server.dialect): \(report)")
            #expect(report.rolledBack == true)
            #expect(badPlan.line(ofRow: 1800) == 1801)
            #expect(failed.errors.first?.message.contains("Row 1800 failed") == true, "\(server.dialect): \(failed.errors)")
            #expect(failed.finished?.status == .failed)
            #expect(try server.exec("SELECT COUNT(*) FROM p152_items") == "1", "\(server.dialect): rolled back")
        }
    }

    @Test(.enabled(if: !SQLLiveDatabaseTests.servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func emptyFieldsAreNullWhenAsked() async throws {
        for server in SQLLiveDatabaseTests.servers {
            try Self.setupImport(server)
            let csv = "id,name,qty\n2,a,\n3,b,4\n"
            // '' isn't an integer: MariaDB's strict mode and PostgreSQL refuse it.
            let (_, refused) = try await importCSV(server, csv, emptyIsNull: false)
            #expect(refused.sqlImportReports.last?.failedRow == 1, "\(server.dialect): \(refused.errors)")
            #expect(try server.exec("SELECT COUNT(*) FROM p152_items") == "1")
            let (_, imported) = try await importCSV(server, csv, emptyIsNull: true)
            #expect(imported.errors.isEmpty, "\(server.dialect): \(imported.errors)")
            #expect(try server.exec("SELECT COUNT(*) FROM p152_items WHERE qty IS NULL") == "2", "\(server.dialect): the existing row and row 2")
            #expect(try server.exec("SELECT qty FROM p152_items WHERE id = 3") == "4", "\(server.dialect): text bound into an integer column")
        }
    }

    @Test(.enabled(if: !SQLLiveDatabaseTests.servers.isEmpty, "set RUNLET_TEST_MYSQL or RUNLET_TEST_PGSQL"))
    func readOnlySavedConnectionsRefuseImports() async throws {
        for server in SQLLiveDatabaseTests.servers {
            try Self.setupImport(server)
            var (connection, _) = SQLLiveDatabaseTests.saved(server)
            connection.readOnly = true
            let (_, events) = try await importCSV(server, "id,name\n2,a\n", saved: connection)
            #expect(events.errors.first?.className == "RunletRunner\\SqlReadOnlyRefused", "\(server.dialect): \(events.errors)")
            #expect(try server.exec("SELECT COUNT(*) FROM p152_items") == "1")
            // A writable saved connection imports.
            connection.readOnly = false
            let (_, imported) = try await importCSV(server, "id,name\n2,a\n", saved: connection)
            #expect(imported.errors.isEmpty, "\(server.dialect): \(imported.errors)")
            #expect(try server.exec("SELECT COUNT(*) FROM p152_items") == "2")
        }
    }
}
