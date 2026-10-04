import Foundation
@testable import RunletCore
import Testing

/// Load More under a MongoDB result (#207): pages append to the table and to the tree.
struct MongoPagingTests {
    private func result(_ columns: [String], _ rows: [[SQLCell]], elapsed: Double = 2) -> SQLResultInfo {
        SQLResultInfo(columns: columns, rows: rows, elapsedMs: elapsed, connection: "Docs", driver: "mongodb", source: "MongoDB find", maxRows: 2, saved: true, bytes: 10)
    }

    @Test func pagesAppendRowsAndUnionColumns() throws {
        let base = result(["_id", "status"], [[.string("ObjectId(\"a\")"), .string("paid")], [.string("ObjectId(\"b\")"), .null]])
        let page = result(["_id", "total", "status"], [[.string("ObjectId(\"c\")"), .int(30), .string("pending")]], elapsed: 3)
        let merged = try #require(MongoPaging.appending(base, page: page))
        #expect(merged.columns == ["_id", "status", "total"])
        #expect(merged.rows == [
            [.string("ObjectId(\"a\")"), .string("paid"), .null],
            [.string("ObjectId(\"b\")"), .null, .null],
            [.string("ObjectId(\"c\")"), .string("pending"), .int(30)],
        ])
        #expect(merged.pages == 2)
        #expect(merged.elapsedMs == 5)
        #expect(merged.bytes == 20)
        #expect(merged.connection == "Docs" && merged.saved == true && merged.driver == "mongodb")
        #expect(merged.table.rows.count == 3)
        #expect(merged.summary.contains("3 rows in 2 pages"))
        let third = try #require(MongoPaging.appending(merged, page: result(["_id"], [[.string("ObjectId(\"d\")")]])))
        #expect(third.pages == 3 && third.rows.last == [.string("ObjectId(\"d\")"), .null, .null])
    }

    @Test func onlyMongoResultsAppend() {
        var sql = result(["id"], [[.int(1)]])
        sql.driver = "mysql"
        #expect(MongoPaging.appending(sql, page: result(["id"], [[.int(2)]])) == nil)
        #expect(MongoPaging.appending(result(["id"], [[.int(2)]]), page: SQLResultInfo(affectedRows: 1, driver: "mongodb")) == nil)
    }

    @Test func columnsStayCapped() throws {
        let base = result((0..<MongoPaging.maxColumns).map { "f\($0)" }, [])
        let merged = try #require(MongoPaging.appending(base, page: result(["extra", "f0"], [[.int(1), .int(2)]])))
        #expect(merged.columns.count == MongoPaging.maxColumns)
        #expect(merged.rows == [[.int(2)] + Array(repeating: .null, count: MongoPaging.maxColumns - 1)])
    }

    private func documents(_ names: [String], firstId: Int) -> DumpInfo {
        var id = firstId
        func next() -> Int { id += 1; return id }
        let entries = names.enumerated().map { index, name in
            ValueNode.Entry(key: String(index), keyType: "int", value: ValueNode(id: next(), type: .array, entries: [
                ValueNode.Entry(key: "name", keyType: "string", value: ValueNode(id: next(), type: .string, scalar: name)),
            ]))
        }
        var root = ValueNode(id: firstId, type: .array, entries: entries)
        root.count = entries.count
        return DumpInfo(index: 0, origin: "dump", label: "MongoDB documents · Extended JSON", value: root)
    }

    @Test func treesAppendDocumentsWithFreshIds() throws {
        let base = documents(["a", "b"], firstId: 1)
        let page = documents(["c"], firstId: 1)
        let merged = try #require(MongoPaging.appending(base, page: page))
        #expect(merged.value.count == 3)
        #expect(merged.value.entries?.map(\.key) == ["0", "1", "2"])
        #expect(merged.value.entries?.last?.value.entries?.first?.value.scalar == "c")
        func ids(_ node: ValueNode) -> [Int] { [node.id] + (node.entries ?? []).flatMap { ids($0.value) } }
        let all = ids(merged.value)
        #expect(Set(all).count == all.count, "node ids stay unique: \(all)")
        #expect(merged.label == base.label)
    }

    @Test func cutOrScalarTreesDontAppend() {
        var cut = documents(["a"], firstId: 1)
        cut.value.truncation = .init(reason: "children", omitted: 5)
        #expect(MongoPaging.appending(cut, page: documents(["b"], firstId: 1)) == nil)
        let scalar = DumpInfo(index: 0, origin: "dump", value: ValueNode(id: 1, type: .string, scalar: "x"))
        #expect(MongoPaging.appending(documents(["a"], firstId: 1), page: scalar) == nil)
    }

    @Test func statusAndLimits() {
        #expect(MongoPaging.status(loaded: 100, pages: 1, more: true) == "Documents 1–100; more may follow.")
        #expect(MongoPaging.status(loaded: 150, pages: 2, more: false) == "Documents 1–150 in 2 pages: the end.")
        #expect(MongoPaging.nextPageSize(loaded: 100, pageSize: 100) == 100)
        #expect(MongoPaging.nextPageSize(loaded: MongoPaging.maxLoadedDocuments - 10, pageSize: 100) == 10)
        #expect(MongoPaging.nextPageSize(loaded: MongoPaging.maxLoadedDocuments, pageSize: 100) == nil)
    }
}
