import Foundation
@testable import RunletCore
import Testing

/// CSV for Export Query to CSV and Import CSV (#152): RFC 4180 parsing with lines, delimiter and
/// header detection, the mapping by name, bound values, batches, limits, and export lines.
struct SQLCSVTests {
    static let columns = [SQLSchemaInfo.Column(name: "id", type: "integer", primaryKey: true), SQLSchemaInfo.Column(name: "full_name", type: "text"), SQLSchemaInfo.Column(name: "qty", type: "integer")]

    @Test func parsesQuotesLineBreaksAndLines() {
        let text = "\u{FEFF}id,note\r\n1,\"a, b\"\r\n2,\"say \"\"hi\"\"\"\n\n3,\"two\nlines\"\n4,\n"
        let (records, more) = CSVText.records(in: text, delimiter: ",")
        #expect(!more)
        #expect(records.map(\.fields) == [["id", "note"], ["1", "a, b"], ["2", "say \"hi\""], ["3", "two\nlines"], ["4", ""]])
        #expect(records.map(\.line) == [1, 2, 3, 5, 7], "blank lines are skipped; a quoted line break counts")
        let limited = CSVText.records(in: text, delimiter: ",", limit: 2)
        #expect(limited.records.count == 2)
        #expect(limited.more)
        #expect(CSVText.records(in: "a,b", delimiter: ",").records.map(\.fields) == [["a", "b"]], "no final line break")
    }

    @Test func detectsTheDelimiter() {
        #expect(CSVText.detectDelimiter(in: "a;b;c\n1;2;3\n4;5;6\n") == ";")
        #expect(CSVText.detectDelimiter(in: "a\tb\n1\t2\n") == "\t")
        #expect(CSVText.detectDelimiter(in: "name,note\nx,\"a;b;c\"\ny,\"d;e\"\n") == ",", "delimiters inside quotes don't count")
        #expect(CSVText.detectDelimiter(in: "one column\nvalue\n") == ",")
    }

    @Test func detectsTheHeaderAndMapsByName() throws {
        let plan = try SQLCSVImport.parse("Qty,Full Name,ID\n3,Ada,1\n", table: "people", tableColumns: Self.columns, driver: "pgsql")
        #expect(plan.hasHeader)
        #expect(plan.csvColumns == ["Qty", "Full Name", "ID"])
        #expect(plan.mapping == [2, 1, 0])
        #expect(plan.insertStatement == "INSERT INTO people (id, full_name, qty) VALUES (?, ?, ?)")
        #expect(plan.preview() == [["1", "Ada", "3"]])

        let numbersBelowText = try SQLCSVImport.parse("a,b,c\n1,x,2\n", table: "people", tableColumns: Self.columns, driver: nil)
        #expect(numbersBelowText.hasHeader, "text over numbers")
        var bare = try SQLCSVImport.parse("1,Ada,3\n2,Grace,\n", table: "people", tableColumns: Self.columns, driver: "mysql")
        #expect(!bare.hasHeader)
        #expect(bare.mapping == [0, 1, 2], "in order without a header")
        #expect(bare.csvColumns == ["Column 1", "Column 2", "Column 3"])
        #expect(bare.preview() == [["1", "Ada", "3"], ["2", "Grace", nil]])
        bare.emptyIsNull = false
        #expect(bare.preview().last == ["2", "Grace", ""])
        bare.mapping = [0, nil, 2]
        #expect(bare.insertStatement == "INSERT INTO people (id, qty) VALUES (?, ?)")
        #expect(bare.rowPlaceholders == "(?, ?)")
        bare.mapping = [nil, nil, nil]
        #expect(bare.problem != nil)
    }

    @Test func quotesNamesForTheDriver() throws {
        let columns = [SQLSchemaInfo.Column(name: "order"), SQLSchemaInfo.Column(name: "Total Price")]
        let mysql = try SQLCSVImport.parse("order,Total Price\n1,2\n", table: "shop orders", tableColumns: columns, driver: "mysql")
        #expect(mysql.insertStatement == "INSERT INTO `shop orders` (`order`, `Total Price`) VALUES (?, ?)")
        let pgsql = try SQLCSVImport.parse("order,Total Price\n1,2\n", table: "public.orders", tableColumns: columns, driver: "pgsql")
        #expect(pgsql.insertStatement == #"INSERT INTO public.orders ("order", "Total Price") VALUES (?, ?)"#)
    }

    @Test func batchesCarryBoundValuesAsData() throws {
        var csv = "id,full_name,qty\n"
        for id in 1...2500 { csv += "\(id),\"O'Brien \(id)\",\(id % 3 == 0 ? "" : "\(id)")\n" }
        let plan = try SQLCSVImport.parse(csv, table: "people", tableColumns: Self.columns, driver: "sqlite")
        let batches = plan.batches()
        #expect(batches.count == 3)
        let first = try #require(try JSONSerialization.jsonObject(with: Data(batches[0].utf8)) as? [[Any]])
        #expect(first.count == 1000)
        #expect(first[2][0] as? String == "3")
        #expect(first[2][2] is NSNull, "empty is NULL by default")
        #expect(first[0][1] as? String == "O'Brien 1")
        #expect(plan.line(ofRow: 1) == 2)
        #expect(plan.line(ofRow: 2500) == 2501)
        #expect(plan.line(ofRow: 2501) == nil)
        let code = plan.code(connection: "reporting")
        #expect(code.contains(#"\RunletRunner\SqlCsv::import("INSERT INTO people (id, full_name, qty) VALUES", "(?, ?, ?)", 3, "reporting");"#))
        #expect(!code.contains("Brien"), "the rows travel beside the code, as data")
        #expect(batches[0].hasPrefix(#"[["1","O'Brien 1","1"],"#))
        #expect(plan.historyCode(fileName: "people.csv") == "-- Import CSV: \(2500.formatted()) rows from people.csv into people, in one transaction\nINSERT INTO people (id, full_name, qty) VALUES (?, ?, ?);")
    }

    @Test func refusesFilesPastTheLimits() throws {
        var csv = "id\n"
        for id in 0...SQLCSVImport.maxRows { csv += "\(id)\n" }
        #expect(throws: SQLCSVImport.Problem.tooManyRows) { try SQLCSVImport.parse(csv, table: "t", tableColumns: [SQLSchemaInfo.Column(name: "id")], driver: nil) }
        #expect(throws: SQLCSVImport.Problem.empty) { try SQLCSVImport.parse("\n\n", table: "t", tableColumns: [SQLSchemaInfo.Column(name: "id")], driver: nil) }
        let big = FileManager.default.temporaryDirectory.appendingPathComponent("p152-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: big) }
        FileManager.default.createFile(atPath: big.path, contents: Data(count: SQLCSVImport.maxFileBytes + 1))
        #expect(throws: SQLCSVImport.Problem.tooLarge(bytes: SQLCSVImport.maxFileBytes + 1)) { try SQLCSVImport.read(big, table: "t", tableColumns: [], driver: nil) }
    }

    @Test func exportLinesFollowTheOptions() {
        let row: [SQLCell] = [.int(1), .null, .string(""), .string("a,b"), .string("\\N"), .double(2.5), .binary(bytes: 2, hexPrefix: "00FF"), .bool(true)]
        #expect(SQLCSVExport.line(row, options: SQLCSVExportOptions()) == "1,,\"\",\"a,b\",\\N,2.5,0x00FF,true\r\n")
        #expect(SQLCSVExport.line(row, options: SQLCSVExportOptions(delimiter: .semicolon, null: .backslashN)) == "1;\\N;;a,b;\"\\N\";2.5;0x00FF;true\r\n")
        #expect(SQLCSVExport.line([.string("tab\there")], options: SQLCSVExportOptions(delimiter: .tab)) == "\"tab\there\"\r\n")
        #expect(SQLCSVExport.header(["id", "a;b"], options: SQLCSVExportOptions(delimiter: .semicolon)) == "id;\"a;b\"\r\n")
        // Copy CSV of a result keeps the same quoting.
        #expect(CSVText.field("x\"y") == "\"x\"\"y\"")
        #expect(SQLCSVExport.suggestedFileName("orders: 2026/10") == "orders- 2026-10.csv")
        #expect(SQLCSVExport.code(statement: "SELECT \"a\"", connection: nil).contains(#"\RunletRunner\SqlCsv::export("SELECT \"a\"", null, [])"#))
    }

    @Test func theWriterReplacesTheFileOnlyWhenComplete() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("p152-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("out.csv")
        try Data("old\r\n".utf8).write(to: destination)
        let stopped = try SQLCSVExportWriter(destination: destination, options: SQLCSVExportOptions())
        try stopped.write(SQLExportFrame(columns: ["a"]))
        try stopped.write(SQLExportFrame(rows: [[.int(1)]], total: 1))
        stopped.abandon()
        #expect(try String(contentsOf: destination, encoding: .utf8) == "old\r\n", "Stop leaves the file that was there")
        #expect(!FileManager.default.fileExists(atPath: stopped.partial.path))
        let done = try SQLCSVExportWriter(destination: destination, options: SQLCSVExportOptions())
        try done.write(SQLExportFrame(columns: ["a"]))
        try done.write(SQLExportFrame(rows: [[.int(1)], [.int(2)]], total: 2))
        try done.write(SQLExportFrame(total: 2, done: true))
        try done.finish()
        #expect(try String(contentsOf: destination, encoding: .utf8) == "a\r\n1\r\n2\r\n")
        #expect(done.rows == 2)
        #expect(done.bytes == 9)
    }
}
