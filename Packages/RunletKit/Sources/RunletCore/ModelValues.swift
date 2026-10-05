import Foundation

// Values | Object for Eloquent models (#307). For a value that holds Eloquent models, the
// runner sends two trees: `value`, the full dump (Object), and `modelValues` (Values), where a
// model is its class and key, its attributes (changed and hidden ones marked), and its loaded
// relations, and a collection, paginator, or list of models is its items with their count.
// The Values tree has its own budget and leaves model internals out, so it holds more rows.

/// How the output shows Eloquent models: by what they hold, or as the whole object.
public enum ModelDisplay: String, Sendable, Codable, CaseIterable, Identifiable {
    /// Class and key, attributes, loaded relations, changed, new, and hidden marks.
    case values
    /// The full dump: connection, table, casts, and every other property.
    case object

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .values: "Values"
        case .object: "Object"
        }
    }
}

extension ResultInfo {
    /// The tree to show: the Values tree when `display` is Values and the value holds models.
    public func node(for display: ModelDisplay) -> ValueNode? {
        display == .values ? (modelValues ?? value) : value
    }
}

extension DumpInfo {
    /// The tree to show: the Values tree when `display` is Values and the value holds models.
    public func node(for display: ModelDisplay) -> ValueNode {
        display == .values ? (modelValues ?? value) : value
    }
}

extension InlineValues.Hit {
    /// The tree to show: the Values tree when `display` is Values and the value holds models.
    public func node(for display: ModelDisplay) -> ValueNode? {
        display == .values ? (modelValues ?? value) : value
    }
}

extension ValueNode {
    /// The class name without its namespace.
    public var shortClassName: String {
        guard let className else { return type == .object ? "object" : type.rawValue }
        return Self.shortClass(className)
    }

    public static func shortClass(_ name: String) -> String {
        name.split(separator: "\\").last.map(String.init) ?? name
    }

    /// A model key for a title: in full up to 12 characters, else its first 8 and "…".
    public static func abbreviatedKey(_ key: String) -> String {
        key.count > 12 ? String(key.prefix(8)) + "…" : key
    }

    /// A model's or a list of models' title in Values mode: `User #1`, `Collection<User> · 312`,
    /// `LengthAwarePaginator<User> · 15 of 312 · page 2 of 21`; nil for other nodes.
    public var modelTitle: String? {
        if let model {
            return shortClassName + (model.key.map { " #" + Self.abbreviatedKey($0) } ?? "")
        }
        guard let collection, let detail = collectionDetail else { return nil }
        return shortClassName + (collection.of.map { "<\(Self.shortClass($0))>" } ?? "") + " " + detail
    }

    /// A list of models' count, and a paginator's total and page: `· 15 of 312 · page 2 of 21`.
    public var collectionDetail: String? {
        guard let collection else { return nil }
        var detail = "· \(collection.count.formatted())"
        if let total = collection.total { detail += " of \(total.formatted())" }
        if let page = collection.page {
            detail += " · page \(page.formatted())" + (collection.lastPage.map { " of \($0.formatted())" } ?? "")
        }
        if collection.hasMore == true { detail += " · more" }
        return detail
    }

    /// Items or attributes of a Values node the runner left out, for a card's subtitle.
    public var omittedText: String? {
        guard let truncation, truncation.omitted > 0, truncation.reason != "length", truncation.reason != "depth" else { return nil }
        return "\(truncation.omitted.formatted()) not shown"
    }
}
