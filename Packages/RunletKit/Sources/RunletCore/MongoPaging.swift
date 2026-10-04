import Foundation

/// Load More under a MongoDB result (#207), like SQL's Load Next and Redis's Load More: the next
/// page of a find, aggregate, or distinct is read with a skip offset and appended to the result
/// card's table and to its Extended JSON tree, instead of replacing them.
public enum MongoPaging {
    /// The most documents a result card keeps across its pages (the SQL card's row limit).
    public static let maxLoadedDocuments = SQLPaging.maxLoadedRows
    /// Table columns across the pages: documents have no fixed shape, so a page can add fields.
    public static let maxColumns = 200

    /// `base` with `page`'s rows after its own. Documents differ in their fields: a field the page
    /// adds becomes a column at the end, empty (null) in the rows before; the page's rows follow
    /// the merged columns. Timing adds up; `pages` counts the pages. Nil when either isn't a
    /// MongoDB document result.
    public static func appending(_ base: SQLResultInfo, page: SQLResultInfo) -> SQLResultInfo? {
        guard base.hasResultSet, page.hasResultSet, base.driver == "mongodb", page.driver == "mongodb" else { return nil }
        var columns = base.columns
        for column in page.columns where !columns.contains(column) && columns.count < maxColumns {
            columns.append(column)
        }
        let added = columns.count - base.columns.count
        var rows = base.rows
        if added > 0 {
            rows = rows.map { $0 + Array(repeating: SQLCell.null, count: added) }
        }
        let positions = columns.map { column in page.columns.firstIndex(of: column) }
        for row in page.rows {
            rows.append(positions.map { index in index.flatMap { row.indices.contains($0) ? row[$0] : nil } ?? .null })
        }
        var merged = SQLResultInfo(columns: columns, rows: rows, truncated: page.truncated, truncation: page.truncation,
                                   omittedColumns: base.omittedColumns, elapsedMs: page.elapsedMs.map { $0 + (base.elapsedMs ?? 0) } ?? base.elapsedMs,
                                   connection: base.connection, driver: base.driver, source: base.source, connections: base.connections,
                                   maxRows: base.maxRows, statement: base.statement, saved: base.saved,
                                   bytes: (base.bytes ?? 0) + (page.bytes ?? 0))
        merged.pages = (base.pages ?? 1) + 1
        return merged
    }

    /// The Extended JSON tree (`MongoTab::emit`'s dump: a list of documents) with `page`'s
    /// documents after its own, numbered on (`100 =>`, `101 =>`, …). The page's node ids move past
    /// the tree's, so expanding a document never expands another. Nil when either isn't a list,
    /// or the tree was cut (its last documents aren't there to follow).
    public static func appending(_ base: DumpInfo, page: DumpInfo) -> DumpInfo? {
        guard base.value.type == .array, page.value.type == .array, base.value.truncation == nil else { return nil }
        let existing = base.value.entries ?? []
        let offset = maxId(base.value) + 1
        var entries = existing
        for (index, entry) in (page.value.entries ?? []).enumerated() {
            var moved = entry
            moved.key = String(existing.count + index)
            moved.keyType = "int"
            moved.value = renumbered(entry.value, by: offset)
            entries.append(moved)
        }
        var merged = base
        merged.value.entries = entries
        merged.value.count = entries.count
        merged.value.truncation = page.value.truncation
        return merged
    }

    private static func maxId(_ node: ValueNode) -> Int {
        (node.entries ?? []).reduce(node.id) { max($0, maxId($1.value)) }
    }

    private static func renumbered(_ node: ValueNode, by offset: Int) -> ValueNode {
        var node = node
        node.id += offset
        node.entries = node.entries?.map { entry in
            var entry = entry
            entry.value = renumbered(entry.value, by: offset)
            return entry
        }
        return node
    }

    /// The documents the next page asks for: a page, or what is left under the card's limit;
    /// nil at the limit.
    public static func nextPageSize(loaded: Int, pageSize: Int) -> Int? {
        let left = maxLoadedDocuments - loaded
        return left > 0 ? min(pageSize, left) : nil
    }

    /// Under the card: "Documents 1–200 in 2 pages; more may follow." / "…: the end."
    public static func status(loaded: Int, pages: Int, more: Bool) -> String {
        let range = loaded == 0 ? "No documents" : "Documents 1–\(loaded.formatted())"
        let paged = pages > 1 ? " in \(pages.formatted()) pages" : ""
        return range + paged + (more ? "; more may follow." : ": the end.")
    }
}
