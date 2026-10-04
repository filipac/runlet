import Foundation
@testable import RunletCore
import Testing
@testable import RunletExecution

extension Array where Element == RunEvent {
    /// Export Query to CSV's frames (#152), in order.
    var sqlExportFrames: [SQLExportFrame] {
        compactMap { if case .sqlExport(let frame) = $0.kind { return frame } else { return nil } }
    }

    /// Import CSV's reports (#152), in order.
    var sqlImportReports: [SQLImportReport] {
        compactMap { if case .sqlImport(let report) = $0.kind { return report } else { return nil } }
    }
}

/// Export Query to CSV and Import CSV (#152) through the runner, with host PHP and SQLite saved
/// connections: frames written to a file with the sheet's options, values as the result shows
/// them (NULL, binary as hex, quoting), one transaction for an import with a rollback that names
/// the row, read-only refusal, and PHP 7.4.
@Suite(.serialized, .enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct SQLCSVExecutionTests {
    /// A project with `data/shop.sqlite` and a `p152_items` table of awkward values.
    static func project() throws -> URL {
        let directory = try SQLSavedConnectionTests.project()
        try sqlite(directory, """
            CREATE TABLE p152_items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, note TEXT, qty INTEGER, price REAL, raw BLOB);
            INSERT INTO p152_items VALUES (1, 'bolt', NULL, 5, 0.25, NULL);
            INSERT INTO p152_items VALUES (2, 'nut, hex', 'say "hi"', 7, 2.0, X'00FF10');
            INSERT INTO p152_items VALUES (3, 'two
            lines', '', NULL, NULL, NULL);
            INSERT INTO p152_items VALUES (4, '\\N', 'ünïcode', 0, -1.5, NULL);
            """)
        return directory
    }

    static func sqlite(_ directory: URL, _ sql: String) throws {
        let php = Process()
        php.executableURL = URL(fileURLWithPath: DriverSupport.php)
        php.arguments = ["-r", "$p = new PDO('sqlite:' . $argv[1], null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]); $p->exec($argv[2]);", directory.appendingPathComponent("data/shop.sqlite").path, sql]
        try php.run()
        php.waitUntilExit()
    }

    static func count(_ directory: URL, _ table: String = "p152_items") throws -> Int {
        let php = Process()
        let pipe = Pipe()
        php.executableURL = URL(fileURLWithPath: DriverSupport.php)
        php.arguments = ["-r", "$p = new PDO('sqlite:' . $argv[1]); echo $p->query('SELECT COUNT(*) FROM ' . $argv[2])->fetchColumn();", directory.appendingPathComponent("data/shop.sqlite").path, table]
        php.standardOutput = pipe
        try php.run()
        php.waitUntilExit()
        return Int(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)) ?? -1
    }

    /// Runs an import as the app does: the INSERT's parts as code, the rows in the request.
    static func runImport(_ plan: SQLCSVImport, connection: DatabaseConnection?, in directory: URL, php: String? = nil, password: String? = SQLSavedConnectionTests.password) async throws -> [RunEvent] {
        let engine: ExecutionEngine
        if let connection {
            engine = try SQLSavedConnectionTests.engine(password: password, for: connection).0
        } else {
            engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
        }
        var request = RunRequest(tabId: UUID(), documentVersion: 1, target: DriverSupport.target(directory.path, php: php), code: plan.code(connection: nil), inspector: RunInspectorOptions(), magicComments: false)
        request.sqlConnection = connection
        request.sqlBatches = plan.batches()
        var events: [RunEvent] = []
        for await event in try await engine.start(request) { events.append(event) }
        return events
    }

    /// Runs an export and writes its frames as the app does.
    static func export(_ statement: String, options: SQLCSVExportOptions, connection: DatabaseConnection, in directory: URL, php: String? = nil) async throws -> (events: [RunEvent], csv: String, writer: SQLCSVExportWriter) {
        let destination = directory.appendingPathComponent("export.csv")
        let writer = try SQLCSVExportWriter(destination: destination, options: options)
        let events = try await SQLSavedConnectionTests.run(SQLCSVExport.code(statement: statement, connection: nil), connection: connection, in: directory, php: php)
        for frame in events.sqlExportFrames { try writer.write(frame) }
        guard events.errors.isEmpty, events.sqlExportFrames.last?.done == true else {
            writer.abandon()
            return (events, "", writer)
        }
        try writer.finish()
        return (events, try String(contentsOf: destination, encoding: .utf8), writer)
    }

    @Test func exportWritesEveryRowWithTheSheetsOptions() async throws {
        let directory = try Self.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = SQLSavedConnectionTests.connection()
        let (events, csv, writer) = try await Self.export("SELECT id, name, note, qty, price, raw FROM p152_items ORDER BY id", options: SQLCSVExportOptions(), connection: connection, in: directory)
        #expect(events.errors.isEmpty, "\(events.errors)")
        let frames = events.sqlExportFrames
        #expect(frames.first?.columns == ["id", "name", "note", "qty", "price", "raw"])
        #expect(frames.last?.done == true)
        #expect(frames.last?.total == 4)
        #expect(csv == "id,name,note,qty,price,raw\r\n"
            + "1,bolt,,5,0.25,\r\n"
            + "2,\"nut, hex\",\"say \"\"hi\"\"\",7,2,0x00FF10\r\n"
            + "3,\"two\nlines\",\"\",,,\r\n"
            + "4,\\N,ünïcode,0,-1.5,\r\n")
        #expect(writer.rows == 4)
        #expect(!FileManager.default.fileExists(atPath: writer.partial.path), "the partial file became the export")
        // Nothing of the export is output, and the run carries no `sql` result.
        #expect(events.sqlResults.isEmpty)
        #expect(events.stdout.isEmpty)

        let (_, tabbed, _) = try await Self.export("SELECT id, note, name FROM p152_items WHERE id IN (1, 4) ORDER BY id", options: SQLCSVExportOptions(delimiter: .tab, header: false, null: .backslashN), connection: connection, in: directory)
        #expect(tabbed == "1\t\\N\tbolt\r\n4\tünïcode\t\"\\N\"\r\n", "NULL is \\N; the text \\N is quoted")
    }

    @Test func exportRefusesAStatementWithoutRowsAndTheAppRefusesWrites() async throws {
        let directory = try Self.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (events, _, writer) = try await Self.export("PRAGMA user_version = 3", options: SQLCSVExportOptions(), connection: SQLSavedConnectionTests.connection(), in: directory)
        #expect(events.errors.first?.className == "RunletRunner\\SqlExportRefused", "\(events.errors)")
        #expect(!FileManager.default.fileExists(atPath: writer.partial.path))
        #expect(!FileManager.default.fileExists(atPath: writer.destination.path), "nothing is left behind")
        #expect(SQLCSVExport.refusal(of: "DELETE FROM p152_items") != nil)
        #expect(SQLCSVExport.refusal(of: "SELECT * FROM p152_items FOR UPDATE") != nil)
        #expect(SQLCSVExport.refusal(of: "SHOW TABLES") != nil)
        #expect(SQLCSVExport.refusal(of: "CALL report()") != nil)
        #expect(SQLCSVExport.refusal(of: "WITH a AS (SELECT 1) SELECT * FROM a") == nil)
    }

    static func importPlan(_ csv: String, emptyIsNull: Bool = true) throws -> SQLCSVImport {
        let columns = [SQLSchemaInfo.Column(name: "id", type: "integer", primaryKey: true), SQLSchemaInfo.Column(name: "name", type: "text", nullable: false), SQLSchemaInfo.Column(name: "note", type: "text"), SQLSchemaInfo.Column(name: "qty", type: "integer")]
        var plan = try SQLCSVImport.parse(csv, table: "p152_items", tableColumns: columns, driver: "sqlite")
        plan.emptyIsNull = emptyIsNull
        return plan
    }

    @Test func importInsertsEveryRowInOneTransaction() async throws {
        let directory = try Self.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let plan = try Self.importPlan("ID;Name;Qty\n10;washer;3\n11;\"spring; coil\";\n12;pin;8\n")
        #expect(plan.delimiter == ";")
        #expect(plan.hasHeader)
        #expect(plan.mapping == [0, 1, nil, 2], "by name, ignoring case; note isn't in the file")
        #expect(plan.insertStatement == "INSERT INTO p152_items (id, name, qty) VALUES (?, ?, ?)")
        let events = try await Self.runImport(plan, connection: SQLSavedConnectionTests.connection(), in: directory)
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.sqlImportReports.last == SQLImportReport(inserted: 3, done: true, elapsedMs: events.sqlImportReports.last?.elapsedMs, driver: "sqlite"))
        #expect(try Self.count(directory) == 7)
    }

    @Test func importRollsBackAtTheFirstErrorAndNamesTheRow() async throws {
        let directory = try Self.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 1,500 good rows, then id 1 again (taken), then more: the second batch fails at its fifth row.
        var csv = "id,name\n"
        for id in 100..<1104 { csv += "\(id),item \(id)\n" }
        csv += "1,duplicate\n"
        for id in 2000..<2500 { csv += "\(id),item \(id)\n" }
        let plan = try Self.importPlan(csv)
        #expect(plan.rowCount == 1505)
        let events = try await Self.runImport(plan, connection: SQLSavedConnectionTests.connection(), in: directory)
        let failure = try #require(events.sqlImportReports.last)
        #expect(failure.failedRow == 1005)
        #expect(failure.rolledBack == true)
        #expect(plan.line(ofRow: 1005) == 1006, "the header is line 1")
        #expect(events.errors.first?.className == "RunletRunner\\SqlImportFailed")
        #expect(events.errors.first?.message.contains("Row 1005 failed") == true, "\(events.errors)")
        #expect(events.errors.first?.message.contains("no rows were imported") == true)
        #expect(events.finished?.status == .failed)
        #expect(try Self.count(directory) == 4, "nothing stays")
    }

    @Test func emptyFieldsBecomeNullOrStayEmpty() async throws {
        let directory = try Self.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.sqlite(directory, "CREATE TABLE p152_strict (id INTEGER PRIMARY KEY, name TEXT NOT NULL, qty INTEGER CHECK (qty IS NULL OR typeof(qty) = 'integer'))")
        let columns = [SQLSchemaInfo.Column(name: "id"), SQLSchemaInfo.Column(name: "name"), SQLSchemaInfo.Column(name: "qty")]
        var plan = try SQLCSVImport.parse("id,name,qty\n1,a,\n2,b,4\n", table: "p152_strict", tableColumns: columns, driver: "sqlite")
        #expect(plan.preview() == [["1", "a", nil], ["2", "b", "4"]])
        plan.emptyIsNull = false
        #expect(plan.preview() == [["1", "a", ""], ["2", "b", "4"]])
        let refused = try await Self.runImport(plan, connection: SQLSavedConnectionTests.connection(), in: directory)
        #expect(refused.sqlImportReports.last?.failedRow == 1, "'' isn't an integer")
        #expect(try Self.count(directory, "p152_strict") == 0)
        plan.emptyIsNull = true
        let imported = try await Self.runImport(plan, connection: SQLSavedConnectionTests.connection(), in: directory)
        #expect(imported.errors.isEmpty, "\(imported.errors)")
        #expect(try Self.count(directory, "p152_strict") == 2)
    }

    @Test func readOnlyConnectionsRefuseImports() async throws {
        let directory = try Self.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        var connection = SQLSavedConnectionTests.connection()
        connection.readOnly = true
        let plan = try Self.importPlan("id,name\n50,x\n")
        let events = try await Self.runImport(plan, connection: connection, in: directory)
        #expect(events.errors.first?.className == "RunletRunner\\SqlReadOnlyRefused", "\(events.errors)")
        #expect(events.sqlImportReports.isEmpty, "refused before the connection opened")
        #expect(try Self.count(directory) == 4)
        // Exports are reads: a read-only connection runs them.
        let (exported, csv, _) = try await Self.export("SELECT id FROM p152_items ORDER BY id", options: SQLCSVExportOptions(header: false), connection: connection, in: directory)
        #expect(exported.errors.isEmpty, "\(exported.errors)")
        #expect(csv == "1\r\n2\r\n3\r\n4\r\n")
    }

    /// The largest import Runlet takes (8 MiB) uses a fraction of PHP's default 128 MiB
    /// memory_limit: the batches travel in the request as JSON text, apart from the code, and are
    /// decoded one at a time.
    @Test(.timeLimit(.minutes(2))) func theLargestImportFitsPHPsDefaultMemoryLimit() async throws {
        let directory = try Self.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.sqlite(directory, "CREATE TABLE p152_big (id INTEGER PRIMARY KEY, name TEXT NOT NULL, note TEXT, qty INTEGER)")
        var csv = "id,name,note,qty\n"
        let note = String(repeating: "lorem ipsum ", count: 3)
        for id in 1...SQLCSVImport.maxRows { csv += "\(id),\"part \(id), \\\"zinc\\\"\",\(note)\(id),\(id % 97)\n" }
        #expect(csv.utf8.count <= SQLCSVImport.maxFileBytes && csv.utf8.count > 7 * 1024 * 1024, "\(csv.utf8.count)")
        let columns = ["id", "name", "note", "qty"].map { SQLSchemaInfo.Column(name: $0) }
        let plan = try SQLCSVImport.parse(csv, table: "p152_big", tableColumns: columns, driver: "sqlite")
        #expect(plan.rowCount == SQLCSVImport.maxRows)
        let events = try await Self.runImport(plan, connection: SQLSavedConnectionTests.connection(), in: directory)
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.sqlImportReports.last?.inserted == SQLCSVImport.maxRows)
        #expect(try Self.count(directory, "p152_big") == SQLCSVImport.maxRows)
        let peak = try #require(events.finished?.peakMemory)
        // Measured: about 65 MiB (18 MiB of it the runner itself), well under 128 MiB.
        #expect(peak < 80 * 1024 * 1024, "peak \(peak)")
        print("#152 import: \(SQLCSVImport.maxRows) rows, \(csv.utf8.count) bytes of CSV, runner peak \(peak / 1024 / 1024) MiB")
    }

    @Test func runsOnPHP74() async throws {
        let php74 = try #require(TestSupport.herdPHP74)
        let directory = try Self.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = SQLSavedConnectionTests.connection()
        let (events, csv, _) = try await Self.export("SELECT id, raw FROM p152_items WHERE id = 2", options: SQLCSVExportOptions(), connection: connection, in: directory, php: php74)
        #expect(events.started?.phpVersion?.hasPrefix("7.4") == true)
        #expect(csv == "id,raw\r\n2,0x00FF10\r\n", "\(events.errors)")
        let plan = try Self.importPlan("id,name\n60,a\n60,b\n")
        let failed = try await Self.runImport(plan, connection: connection, in: directory, php: php74)
        #expect(failed.sqlImportReports.last?.failedRow == 2, "\(failed.errors)")
        #expect(try Self.count(directory) == 4)
    }
}
