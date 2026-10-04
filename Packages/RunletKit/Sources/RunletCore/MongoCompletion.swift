import Foundation

public enum MongoCompletion {
    public static func suggestions(in text: String, caret: Int, fields: [String], collections: [String]) -> SQLCompletion.Result? {
        let string = text as NSString
        let end = min(max(0, caret), string.length)
        var start: Int?
        var escaped = false
        for offset in 0..<end {
            let character = string.character(at: offset)
            if escaped { escaped = false; continue }
            if character == 92 && start != nil { escaped = true; continue }
            if character == 34 { start = start == nil ? offset + 1 : nil }
        }
        guard let start else { return nil }
        let prefix = string.substring(with: NSRange(location: start, length: end - start))
        guard !prefix.contains("\\") else { return nil }
        let items = Set(fields + collections + Array(MongoQuery.operations) + ["collection", "operation", "filter", "projection", "sort", "limit", "skip", "pipeline", "documents", "update"])
            .filter { $0.lowercased().hasPrefix(prefix.lowercased()) }
            .sorted()
            .prefix(100)
            .map { value in
                let data = try! JSONSerialization.data(withJSONObject: [value])
                let quoted = String(decoding: data, as: UTF8.self)
                let escaped = String(quoted.dropFirst(2).dropLast(2))
                return SQLCompletion.Item(label: value, insertText: escaped, kind: fields.contains(value) ? .column : collections.contains(value) ? .table : .keyword,
                                          detail: fields.contains(value) ? "sampled MongoDB field" : "MongoDB", rank: 0)
            }
        return SQLCompletion.Result(anchor: start, prefix: prefix, items: Array(items))
    }
}
