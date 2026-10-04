import AppKit
import RunletCore
import SwiftUI

/// The Library's Database pane for a MongoDB tab (#191), like the SQL schema explorer and the
/// Redis key browser: the target and connection, then the database's collections with their
/// estimated counts. Nothing loads by itself: Load Collections, Indexes, and Sample Fields read
/// when pressed (Indexes and Sample Fields into the output; sampled fields also show under their
/// collection and feed completion), and production asks before every read. Open Find Query
/// only opens a tab with a query; nothing runs.
struct MongoExplorer: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    @Bindable private var state = MongoUI.shared
    @State private var search = ""

    var body: some View {
        let choice = model.sqlConnectionChoice(for: tab)
        let key = model.mongoCacheKey(tab)
        let result = state.collections[key]
        VStack(alignment: .leading, spacing: 0) {
            header(choice, key: key, result: result)
            Divider()
            if case .missing(let name) = choice {
                ContentUnavailableView("Missing connection", systemImage: "exclamationmark.triangle", description: Text(SQLConnectionChoice.missingMessage(name)))
            } else if let result {
                list(result, key: key)
            } else {
                placeholder(choice)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mongo-explorer")
    }

    // MARK: Header

    private func header(_ choice: SQLConnectionChoice, key: String, result: SQLResultInfo?) -> some View {
        let missing = if case .missing = choice { true } else { false }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "leaf.fill").foregroundStyle(Color.mongoDB)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.targetLabel(tab.target)).font(.callout.weight(.semibold)).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(connectionText(choice))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let saved = choice.savedConnection { SavedConnectionBadges(connection: saved) }
                    }
                }
                Spacer(minLength: 4)
                if tab.isRunning {
                    ProgressView().controlSize(.small)
                } else if result != nil {
                    Button {
                        model.mongoMetadata("listCollections", tab: tab)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Reload Collections: read the names and estimated counts again (production asks first)")
                    .accessibilityIdentifier("mongo-reload-collections")
                }
                Menu {
                    Button(result == nil ? "Load Collections" : "Reload Collections") { model.mongoMetadata("listCollections", tab: tab) }
                    Button("List Databases") { model.mongoMetadata("listDatabases", tab: tab) }
                        .help("Lists the databases this connection may read, in the output")
                    if result != nil {
                        Divider()
                        Button("Forget Collections") { model.forgetMongoCollections(tab) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(tab.isRunning || missing)
                .accessibilityIdentifier("mongo-explorer-menu")
            }
            if let result {
                Text(status(result, key: key))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityIdentifier("mongo-collections-status")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "The saved connection “Documents” · mongodb, 127.0.0.1:27017/shop"; "The default
    /// connection (mongodb)".
    private func connectionText(_ choice: SQLConnectionChoice) -> String {
        let label = if case .app(nil) = choice { "the default connection (mongodb)" } else { choice.label }
        return label.prefix(1).uppercased() + label.dropFirst() + (choice.savedConnection.map { " · \($0.summary)" } ?? "")
    }

    private func status(_ result: SQLResultInfo, key: String) -> String {
        let count = result.rows.count
        let read = state.collectionsRead[key].map { " · read \($0.formatted(.relative(presentation: .named)))" } ?? ""
        let capped = count >= 100 ? " (the first 100)" : ""
        return "\(count.formatted()) collection\(count == 1 ? "" : "s")\(capped)\(read)"
    }

    // MARK: Before loading

    private func placeholder(_ choice: SQLConnectionChoice) -> some View {
        let saved = choice.savedConnection
        let production = model.isProduction(tab.target)
            ? "; this target is production, so it asks first"
            : model.isProduction(tab.target, connection: saved) ? "; this connection is production, so it asks first" : ""
        return VStack(spacing: 10) {
            Spacer(minLength: 20)
            Image(systemName: "leaf").font(.largeTitle).foregroundStyle(Color.mongoDB)
            Text("Browse the collections").font(.headline)
            Text("Load the collections of \(choice.label) on \(model.targetLabel(tab.target)) to see their names and estimated counts. Runlet \(saved == nil ? "boots the application" : "opens the saved connection (no application code runs)") and reads them on demand, never documents\(production). Indexes and Sample Fields read one collection when you ask; sampling reads at most 50 documents.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Load Collections") { model.mongoMetadata("listCollections", tab: tab) }
                .buttonStyle(.borderedProminent)
                .tint(Color.mongoDB)
                .disabled(tab.isRunning)
                .accessibilityIdentifier("mongo-load-collections")
            Spacer(minLength: 20)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Collections

    private func list(_ result: SQLResultInfo, key: String) -> some View {
        let collections = result.rows.map { MongoCollectionEntry(row: $0) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = query.isEmpty ? collections : collections.filter { $0.name.lowercased().contains(query) }
        let sampled = state.fields[key] ?? [:]
        return VStack(spacing: 0) {
            TextField("Filter collections", text: $search)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .accessibilityIdentifier("mongo-collection-filter")
            if collections.isEmpty {
                ContentUnavailableView("No collections", systemImage: "leaf", description: Text("The connection's database has no collections this user may list."))
            } else if matches.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                List {
                    ForEach(matches) { entry in
                        if let fields = sampled[entry.name] {
                            let id = key + "\u{1F}" + entry.name
                            DisclosureGroup(isExpanded: Binding(get: { state.expanded.contains(id) },
                                                                set: { if $0 { state.expanded.insert(id) } else { state.expanded.remove(id) } })) {
                                ForEach(Array(fields.rows.enumerated()), id: \.offset) { _, row in
                                    MongoFieldRow(tab: tab, name: row.first?.text ?? "", types: row.count > 1 ? row[1].text : "")
                                }
                            } label: {
                                row(entry)
                            }
                        } else {
                            row(entry)
                        }
                    }
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier("mongo-collections")
            }
        }
    }

    private func row(_ entry: MongoCollectionEntry) -> some View {
        MongoCollectionRow(tab: tab, entry: entry, sample: { model.sampleMongoFields(entry.name, tab: tab) })
    }
}

/// One `listCollections` row: name, type, and estimated count.
struct MongoCollectionEntry: Identifiable, Hashable {
    var name: String
    var type: String
    var count: String?
    var id: String { name }

    init(row: [SQLCell]) {
        name = row.first?.text ?? ""
        type = row.count > 1 ? row[1].text : "collection"
        let count = row.count > 2 ? row[2].text : ""
        self.count = count.isEmpty || count == "NULL" ? nil : count
    }

    var countText: String? {
        guard let count else { return nil }
        let value = Int(count).map { $0.formatted() } ?? count
        return "~\(value) doc\(count == "1" ? "" : "s")"
    }
}

/// A collection's row: its icon and name, the estimated count, and Indexes, Sample Fields,
/// and Open Find Query; the same in its context menu with Copy Name.
private struct MongoCollectionRow: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    let entry: MongoCollectionEntry
    var sample: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: entry.type == "view" ? "eye" : entry.type == "timeseries" ? "clock" : "tray.full")
                .foregroundStyle(entry.type == "view" ? Color.purple : Color.mongoDB)
                .frame(width: 16)
            Text(entry.name)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            if entry.type == "view" {
                Text("VIEW")
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .foregroundStyle(.white)
                    .background(Capsule().fill(Color.purple.opacity(0.8)))
            }
            Spacer(minLength: 4)
            if let count = entry.countText {
                Text(count)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Estimated document count, from the collection's statistics")
            }
            Button {
                model.mongoMetadata("getIndexes", collection: entry.name, tab: tab)
            } label: {
                Image(systemName: "list.number")
            }
            .buttonStyle(.borderless)
            .disabled(tab.isRunning)
            .help("Indexes: read the collection's indexes into the output (production asks first)")
            .accessibilityIdentifier("mongo-indexes")
            Button(action: sample) {
                Image(systemName: "text.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .disabled(tab.isRunning)
            .help("Sample Fields: read up to 50 random documents and list their fields and types, here and in the output; completion offers them (production asks first)")
            .accessibilityIdentifier("mongo-sample-fields")
            Button {
                model.openMongoFindQuery(entry.name, from: tab)
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .help("Open Find Query: a find of its first 50 documents in a new MongoDB tab (it doesn't run)")
            .accessibilityIdentifier("mongo-open-find")
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.openMongoFindQuery(entry.name, from: tab) }
        .contextMenu { actions }
        #if DEBUG
        .popover(isPresented: Binding(get: { MongoUI.shared.debugMenuCollection == entry.name }, set: { if !$0 { MongoUI.shared.debugMenuCollection = nil } }), arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 6) { actions }
                .buttonStyle(.plain)
                .padding(10)
                .frame(minWidth: 200, alignment: .leading)
        }
        #endif
        .help(entry.name + "\nDouble-click to open a find query in a new MongoDB tab. Nothing runs until you press Run.")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mongo-collection-row")
    }

    /// The context menu's items.
    @ViewBuilder private var actions: some View {
        Button("Indexes") { model.mongoMetadata("getIndexes", collection: entry.name, tab: tab) }
            .disabled(tab.isRunning)
        Button("Sample Fields", action: sample)
            .disabled(tab.isRunning)
        Button("Open Find Query") { model.openMongoFindQuery(entry.name, from: tab) }
        Divider()
        Button("Copy Name") { Pasteboard.copy(entry.name) }
    }
}

/// A sampled field under its collection: the name and the BSON types seen.
private struct MongoFieldRow: View {
    let tab: TabModel
    let name: String
    let types: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Group {
                if name == "_id" {
                    Image(systemName: "key.fill").foregroundStyle(.yellow)
                } else {
                    Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 14)
            Text(name)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
            Text(Self.displayTypes(types))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { tab.editor.insert(name) }
        .contextMenu {
            Button("Insert Name") { tab.editor.insert(name) }
            Button("Copy Name") { Pasteboard.copy(name) }
        }
        .help("\(name): \(Self.displayTypes(types)) in the sampled documents\nDouble-click to insert the name at the cursor.")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mongo-field-row")
    }

    /// PHP's names for the sampled values: "MongoDB\BSON\ObjectId, string" → "ObjectId, string".
    static func displayTypes(_ text: String) -> String {
        text.split(separator: ",").map { part in
            let type = part.trimmingCharacters(in: .whitespaces)
            switch type {
            case "stdClass": return "object"
            case "NULL": return "null"
            case "double": return "double"
            default: return type.components(separatedBy: "\\").last ?? type
            }
        }.joined(separator: ", ")
    }
}
