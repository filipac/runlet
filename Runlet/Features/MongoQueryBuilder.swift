import AppKit
import RunletCore
import SwiftUI

/// The query builder's place beside a MongoDB tab's editor (#217): the panel while it is open,
/// where Redis tabs have their Command Builder (#218).
struct MongoQueryBuilderSlot: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel

    var body: some View {
        let state = model.mongoBuilder(for: tab)
        if state.isOpen {
            MongoQueryBuilderPanel(tab: tab, state: state)
        }
    }
}

/// What the forms offer: the explorer's cached collections and sampled fields (#207). Nothing
/// here reads the server.
struct MongoBuilderContext {
    var collections: [String] = []
    var fields: [MongoSampledField] = []
    /// Sampled fields of other collections (`$lookup`'s foreign field).
    var fieldsOf: (String) -> [MongoSampledField] = { _ in [] }

    func types(of path: String) -> String? {
        fields.first { $0.name == path }?.types
    }
}

/// The query builder (#217): the tab's JSON query as forms (collection, operation, filter rules
/// and groups, projection, sort, skip and limit, aggregation stage cards, update changes), and
/// what it writes. Every change rewrites the query in the tab, one undoable edit; parts it has
/// no form for stay as JSON. It never runs anything: ⌘R runs the query from the editor, with
/// the usual read-only refusals, confirmations, and production questions.
struct MongoQueryBuilderPanel: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    @Bindable var state: MongoBuilderState

    var body: some View {
        BuilderPanel(identifier: "mongo-builder", width: state.width, range: 300...640, note: state.note, commitWidth: { state.width = $0 }) {
            header
        } content: {
            switch state.phase {
            case .ready where state.builder != nil:
                MongoBuilderForm(tab: tab, state: state, builder: Binding(get: { state.builder ?? MongoQueryBuilder() }, set: { state.builder = $0 }))
                Divider()
                MongoBuilderFooter(tab: tab, state: state)
            default:
                MongoBuilderStartView(tab: tab, state: state)
            }
        }
    }

    private var header: some View {
        BuilderHeader(systemImage: "hammer.fill", color: .mongoDB, title: "Query Builder") {
            Button {
                model.readMongoBuilder(tab)
            } label: {
                Image(systemName: "text.viewfinder")
            }
            .help("Read Query: read the selected query, or the one at the caret, into the builder. Reading never changes the text.")
            .accessibilityLabel("Read Query")
            .accessibilityIdentifier("mongo-builder-read")
            Button {
                model.toggleMongoBuilder(tab)
            } label: {
                Image(systemName: "xmark")
            }
            .help("Close the Query Builder (⌥⌘B)")
            .accessibilityLabel("Close")
            .accessibilityIdentifier("mongo-builder-close")
        }
    }
}

// MARK: - Start

/// A blank tab, or a query the builder can't read: Start from Collection inserts a find of the
/// chosen collection as a new query. A query it can't read is left as it is.
struct MongoBuilderStartView: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    @Bindable var state: MongoBuilderState
    @State private var collection = ""

    var body: some View {
        let collections = model.mongoBuilderCollections(tab)
        let unreadable: String? = if case .unreadable(let why) = state.phase { why } else { nil }
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: unreadable == nil ? "leaf" : "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(unreadable == nil ? Color.mongoDB : Color.orange)
                Text(unreadable == nil ? "Build a query" : "The query can't be read").font(.headline)
                Text(unreadable.map { "\($0) Fix it in the editor and the builder reads it again, or start a new query: it's added after this one, which stays as it is." }
                     ?? "The tab has no query at the caret. Choose a collection to start a find; the builder writes it into the tab, and every change after it. Nothing runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mongo-builder-start-message")
                MongoNameField(text: $collection, prompt: "Collection", options: collections, identifier: "mongo-builder-start-collection")
                Button("Start from Collection") { model.startMongoBuilder(tab, collection: collection.trimmingCharacters(in: .whitespaces)) }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.mongoDB)
                    .disabled(collection.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("mongo-builder-start")
                if collections.isEmpty {
                    Button("Load Collections") { model.mongoMetadata("listCollections", tab: tab) }
                        .disabled(tab.isRunning)
                        .help("Reads the collection names into the Database pane, so the builder can offer them (production asks first)")
                    Text("The builder offers the collections and sampled fields the Database pane has read; it never reads the server by itself.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .onAppear { if collection.isEmpty { collection = collections.first ?? "" } }
        .accessibilityIdentifier("mongo-builder-start-view")
    }
}

// MARK: - Form

struct MongoBuilderForm: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    @Bindable var state: MongoBuilderState
    @Binding var builder: MongoQueryBuilder

    var body: some View {
        let context = MongoBuilderContext(collections: model.mongoBuilderCollections(tab), fields: model.mongoBuilderFields(tab, collection: builder.collection),
                                          fieldsOf: { [model, tab] in model.mongoBuilderFields(tab, collection: $0) })
        let allowed = builder.allowedFields
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    target(context).id("mongo-builder-top")
                    if builder.isBuilderOperation {
                        if allowed.contains("field") {
                            MongoBuilderSection(title: "Field", identifier: "mongo-builder-field") {
                                MongoFieldPathField(path: Binding(get: { builder.field ?? "" }, set: { builder.field = $0 }), context: context, prompt: "Field whose distinct values to list")
                            }
                        }
                        if allowed.contains("filter") { filterSection(context) }
                        if allowed.contains("pipeline") { pipelineSection(context) }
                        if allowed.contains("update") { updateSection(context) }
                        if allowed.contains("projection") { projectionSection(context) }
                        if allowed.contains("sort") { sortSection(context) }
                        if allowed.contains("limit") || allowed.contains("skip") { pagingSection }
                        if allowed.contains("replacement") { jsonSection("Replacement", text: $builder.replacement, identifier: "mongo-builder-replacement", help: "The whole new document, as JSON. Extended JSON for special values.") }
                        if allowed.contains("documents") { jsonSection("Documents", text: $builder.documents, identifier: "mongo-builder-documents", help: "A JSON array of documents: one for insertOne, at most 1,000 for insertMany.") }
                        if allowed.contains("explain") {
                            Toggle("Explain (query planner output instead of documents)", isOn: Binding(get: { builder.explain ?? false }, set: { builder.explain = $0 ? true : (builder.order.contains("explain") ? false : nil) }))
                                .toggleStyle(.checkbox)
                                .font(.callout)
                                .accessibilityIdentifier("mongo-builder-explain")
                        }
                    } else {
                        Text("The builder has forms for find, findOne, countDocuments, distinct, aggregate, and the inserts, updates, replaceOne, and deletes. This operation's fields are kept as JSON.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !builder.extras.isEmpty {
                        MongoBuilderSection(title: "Kept as JSON", identifier: "mongo-builder-extras",
                                            help: "Fields the builder has no form for, or that this operation doesn't take: written as they are.") {
                            ForEach($builder.extras) { $extra in
                                MongoRawBlockEditor(raw: $extra, caption: allowed.contains(extra.key) || !MongoQuery.fields(for: "find").union(MongoQuery.fields(for: "aggregate")).contains(extra.key) ? nil : "\(builder.operation ?? "This operation") doesn't take \(extra.key): ⌘R would refuse it.") {
                                    builder.extras.removeAll { $0.id == extra.id }
                                }
                            }
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            #if DEBUG
            // DEBUG step `mongo-builder-scroll:<section>`: scrolls the form to a section.
            .onChange(of: state.debugScrollTarget) { _, target in
                if let target { proxy.scrollTo(target, anchor: .top) }
                state.debugScrollTarget = nil
            }
            #endif
        }
        .accessibilityIdentifier("mongo-builder-form")
    }

    // MARK: Collection and operation

    private func target(_ context: MongoBuilderContext) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if builder.operation != "dropDatabase" {
                HStack(spacing: 6) {
                    Text("Collection").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                    MongoNameField(text: Binding(get: { builder.collection ?? "" }, set: { builder.collection = $0 }), prompt: "orders", options: context.collections, identifier: "mongo-builder-collection")
                }
            }
            HStack(spacing: 6) {
                Text("Operation").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                Picker("Operation", selection: Binding(get: { builder.operation ?? "" }, set: { new in builder.setOperation(new) })) {
                    Section("Read") {
                        ForEach(["find", "findOne", "countDocuments", "distinct", "aggregate"], id: \.self) { Text($0).tag($0) }
                    }
                    Section("Write") {
                        ForEach(["insertOne", "insertMany", "updateOne", "updateMany", "replaceOne", "deleteOne", "deleteMany"], id: \.self) { Text("\($0)  ✎").tag($0) }
                    }
                    if let operation = builder.operation, !MongoQueryBuilder.operations.contains(operation) {
                        Text(operation).tag(operation)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("mongo-builder-operation")
                MongoEffectBadge(effect: builder.effect)
                Spacer(minLength: 0)
            }
            if context.fields.isEmpty, let collection = builder.collection, !collection.isEmpty, builder.isBuilderOperation {
                HStack(spacing: 6) {
                    Image(systemName: "text.magnifyingglass").foregroundStyle(.secondary)
                    Text("No sampled fields for \(collection): type paths, or sample them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Sample Fields") { model.sampleMongoFields(collection, tab: tab) }
                        .controlSize(.small)
                        .disabled(tab.isRunning)
                        .help("Reads up to 50 random documents of \(collection) and lists their fields and types, in the Database pane and the output, so the builder offers them with typed inputs (production asks first)")
                        .accessibilityIdentifier("mongo-builder-sample")
                }
            }
        }
    }

    // MARK: Sections

    private func filterSection(_ context: MongoBuilderContext) -> some View {
        MongoBuilderSection(title: "Filter", identifier: "mongo-builder-filter") {
            MongoFilterGroupEditor(group: Binding(get: { builder.filter ?? MongoFilterGroup() }, set: { builder.filter = $0 }), context: context, depth: 0, remove: nil)
        }
    }

    private func projectionSection(_ context: MongoBuilderContext) -> some View {
        MongoBuilderSection(title: "Projection", identifier: "mongo-builder-projection", help: "Fields to include (1) or exclude (0). Without any, documents come whole.") {
            MongoFieldListEditor(fields: Binding(get: { builder.projection ?? [] }, set: { builder.projection = $0.isEmpty && !builder.order.contains("projection") ? nil : $0 }), mode: .projection, context: context)
        }
    }

    private func sortSection(_ context: MongoBuilderContext) -> some View {
        MongoBuilderSection(title: "Sort", identifier: "mongo-builder-sort", help: "Sorted by the first field, then the next. Add a unique field (_id) last for stable pages.") {
            MongoFieldListEditor(fields: Binding(get: { builder.sort ?? [] }, set: { builder.sort = $0.isEmpty && !builder.order.contains("sort") ? nil : $0 }), mode: .sort, context: context)
        }
    }

    private var pagingSection: some View {
        MongoBuilderSection(title: "Skip and limit", identifier: "mongo-builder-paging") {
            HStack(spacing: 10) {
                MongoCountField(title: "Skip", value: $builder.skip, identifier: "mongo-builder-skip")
                MongoCountField(title: "Limit", value: $builder.limit, identifier: "mongo-builder-limit")
                Spacer(minLength: 0)
            }
        }
    }

    private func pipelineSection(_ context: MongoBuilderContext) -> some View {
        MongoBuilderSection(title: "Pipeline", identifier: "mongo-builder-pipeline", help: "Stages run in order. A disabled stage isn't written; it stays here while the builder is open.") {
            MongoPipelineEditor(stages: Binding(get: { builder.pipeline ?? [] }, set: { builder.pipeline = $0 }), context: context)
        }
    }

    private func updateSection(_ context: MongoBuilderContext) -> some View {
        MongoBuilderSection(title: "Update", identifier: "mongo-builder-update", help: "What changes in each matched document.") {
            MongoUpdateEditor(nodes: Binding(get: { builder.update ?? [] }, set: { builder.update = $0 }), context: context)
        }
    }

    private func jsonSection(_ title: String, text: Binding<String?>, identifier: String, help: String) -> some View {
        MongoBuilderSection(title: title, identifier: identifier, help: help) {
            MongoJSONTextField(text: Binding(get: { text.wrappedValue ?? "" }, set: { text.wrappedValue = $0 }), identifier: identifier + "-text")
        }
    }
}

/// A titled part of the form.
struct MongoBuilderSection<Content: View, Accessory: View>: View {
    var title: String
    var identifier: String
    var help: String?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var accessory: () -> Accessory

    init(title: String, identifier: String, help: String? = nil, @ViewBuilder content: @escaping () -> Content, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.title = title
        self.identifier = identifier
        self.help = help
        self.content = content
        self.accessory = accessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                if let help {
                    Image(systemName: "questionmark.circle").font(.caption2).foregroundStyle(.tertiary).help(help)
                }
                Spacer(minLength: 0)
                accessory()
            }
            content()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
        .id(identifier)
    }
}

/// READ, WRITE, or DESTRUCTIVE beside the operation.
struct MongoEffectBadge: View {
    var effect: MongoQuery.Effect?

    var body: some View {
        switch effect {
        case .read: BuilderBadge(text: "READ", color: .green, help: "Reads only.")
        case .write: BuilderBadge(text: "WRITE", color: .orange, help: "Changes data. A read-only connection refuses it; production asks first.")
        case .destructive: BuilderBadge(text: "DESTRUCTIVE", color: .red, help: "Drops a collection or changes every document: Run always asks first, on every connection.")
        case nil: EmptyView()
        }
    }
}

// MARK: - Inputs

/// A text field with a menu of known names (collections, or anything else); typing any name works.
struct MongoNameField: View {
    @Binding var text: String
    var prompt: String
    var options: [String]
    var identifier: String

    var body: some View {
        HStack(spacing: 2) {
            TextField(prompt, text: $text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .accessibilityIdentifier(identifier)
            if !options.isEmpty {
                Menu {
                    ForEach(options, id: \.self) { option in
                        Button(option) { text = option }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Choose one the Database pane has read")
                .accessibilityIdentifier(identifier + "-menu")
            }
        }
    }
}

/// A field path: typed (nested paths such as `customer.city` work) or chosen from the
/// collection's sampled fields, with their types. Choosing one can set the value's type.
struct MongoFieldPathField: View {
    @Binding var path: String
    var context: MongoBuilderContext
    var prompt = "field"
    var fields: [MongoSampledField]?
    var picked: ((MongoSampledField) -> Void)? = nil

    var body: some View {
        let list = fields ?? context.fields
        HStack(spacing: 2) {
            TextField(prompt, text: $path, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .help(context.types(of: path).map { "\(path): \(MongoSampledField(name: path, types: $0).displayTypes) in the sampled documents" } ?? "A field path; dots reach into embedded documents (customer.city).")
                .accessibilityIdentifier("mongo-builder-path")
            if !list.isEmpty {
                Menu {
                    ForEach(list, id: \.self) { field in
                        Button("\(field.name)   \(field.displayTypes)") {
                            path = field.name
                            picked?(field)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sampled fields, with the types seen")
            }
        }
    }
}

/// Skip or limit: a whole number, or empty to leave it out (a snippet input or other JSON shows as JSON).
struct MongoCountField: View {
    var title: String
    @Binding var value: MongoValue?
    var identifier: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.callout)
            if let current = value, current.kind != .number {
                MongoValueEditor(value: Binding(get: { current }, set: { value = $0 }), kinds: [.number, .input, .json])
                    .frame(width: 140)
            } else {
                TextField("none", text: Binding(get: { value?.text ?? "" }, set: { new in
                    let digits = new.trimmingCharacters(in: .whitespaces)
                    value = digits.isEmpty ? nil : .number(digits)
                }), prompt: Text("none"))
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .frame(width: 70)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(value?.json == nil && value != nil ? Color.orange : Color.clear))
                .help(value?.problem ?? "Empty leaves it out.")
                .accessibilityIdentifier(identifier)
            }
        }
    }
}

/// A typed value (#217): a menu of types, then the input the type needs — a date picker (in
/// UTC), an ObjectId checked as it's typed, a number, true or false, null, a regex with its
/// options, a field reference, a snippet input, or JSON. It writes Extended JSON.
struct MongoValueEditor: View {
    @Binding var value: MongoValue
    var kinds: [MongoValue.Kind] = MongoValue.Kind.literals
    var fields: [MongoSampledField] = []

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(kinds, id: \.self) { kind in
                    Button {
                        value = value.converted(to: kind)
                    } label: {
                        if kind == value.kind { Label(kind.title, systemImage: "checkmark") } else { Text(kind.title) }
                    }
                }
            } label: {
                Text(Self.short(value.kind))
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("The value's type: \(value.kind.title). Written as Extended JSON.")
            .accessibilityIdentifier("mongo-builder-kind")
            input
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(value.problem == nil ? Color.clear : Color.orange))
                .help(value.problem ?? help)
        }
    }

    private var help: String {
        switch value.kind {
        case .date: "A date and time in UTC, written {\"$date\": \"\(value.text)\"}."
        case .objectId: "24 hexadecimal digits, written {\"$oid\": …}."
        case .decimal: "Written {\"$numberDecimal\": …}, exactly as typed."
        case .long: "A 64-bit integer, written {\"$numberLong\": …}."
        case .regex: "A regular expression, written {\"$regularExpression\": …}."
        case .field: "A field of the documents, written \"$\(value.text)\"."
        case .input: "A snippet input's placeholder, {\"$input\": …}, filled when the snippet runs."
        case .json: "Any JSON value; Extended JSON for special types."
        default: value.kind.title
        }
    }

    static func short(_ kind: MongoValue.Kind) -> String {
        switch kind {
        case .string: "abc"
        case .number: "123"
        case .bool: "T/F"
        case .null: "null"
        case .date: "date"
        case .objectId: "oid"
        case .decimal: "dec"
        case .long: "i64"
        case .regex: "/re/"
        case .field: "$fld"
        case .input: "input"
        case .json: "{ }"
        }
    }

    @ViewBuilder private var input: some View {
        switch value.kind {
        case .null:
            Text("null").font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        case .bool:
            Picker("", selection: Binding(get: { value.text.lowercased() == "false" ? "false" : "true" }, set: { value.text = $0 })) {
                Text("true").tag("true")
                Text("false").tag("false")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 0)
        case .date:
            DatePicker("", selection: Binding(get: { MongoValue.date(from: value.text) ?? Date() }, set: { value.text = MongoValue.isoText($0) }),
                       displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                .accessibilityIdentifier("mongo-builder-date")
            Text("UTC").font(.caption2).foregroundStyle(.secondary).fixedSize()
            Spacer(minLength: 0)
        case .regex:
            TextField("pattern", text: $value.text, prompt: Text("^pattern"))
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
            MongoRegexOptions(options: $value.options)
        case .field:
            MongoFieldPathField(path: $value.text, context: MongoBuilderContext(fields: fields), prompt: "field")
        case .json:
            MongoJSONTextField(text: $value.text, identifier: "mongo-builder-json-value")
        default:
            TextField(value.kind.title, text: $value.text, prompt: Text(Self.prompt(value.kind)))
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: value.kind == .string ? .default : .monospaced))
                .accessibilityIdentifier("mongo-builder-value")
        }
    }

    static func prompt(_ kind: MongoValue.Kind) -> String {
        switch kind {
        case .objectId: "507f1f77bcf86cd799439011"
        case .decimal: "12.50"
        case .number, .long: "42"
        case .input: "input name"
        default: "value"
        }
    }
}

/// A regex's options as small toggles: i (ignore case), m, s, x.
struct MongoRegexOptions: View {
    @Binding var options: String

    var body: some View {
        HStack(spacing: 1) {
            ForEach(["i", "m", "s", "x"], id: \.self) { option in
                let on = options.contains(option)
                Button(option) {
                    var set = Set(options)
                    if on { set.remove(Character(option)) } else { set.insert(Character(option)) }
                    options = String(set.sorted())
                }
                .buttonStyle(.plain)
                .font(.system(.caption, design: .monospaced).weight(on ? .bold : .regular))
                .frame(width: 16, height: 18)
                .background(RoundedRectangle(cornerRadius: 3).fill(on ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.08)))
                .help(["i": "Ignore case", "m": "^ and $ match at line breaks", "s": ". matches line breaks", "x": "Ignore whitespace in the pattern"][option] ?? option)
            }
        }
    }
}

/// JSON typed as text, checked as it's typed.
struct MongoJSONTextField: View {
    @Binding var text: String
    var identifier: String

    var body: some View {
        let problem: String? = {
            do { _ = try MongoJSON.parse(text); return nil } catch { return error.localizedDescription }
        }()
        VStack(alignment: .leading, spacing: 2) {
            TextField("JSON", text: $text, prompt: Text("{}"), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1...12)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(problem == nil ? Color.clear : Color.orange))
                .accessibilityIdentifier(identifier)
            if let problem {
                Text(problem).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A part the builder has no form for, kept as JSON: its key and value, editable as text.
struct MongoRawBlockEditor: View {
    @Binding var raw: MongoRawMember
    var caption: String?
    var remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "curlybraces").foregroundStyle(.secondary).font(.caption)
                Text(raw.key.isEmpty ? "\"\"" : raw.key).font(.system(.callout, design: .monospaced).weight(.semibold))
                Text("JSON").font(.system(size: 8.5, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                MongoRemoveButton(help: "Remove \(raw.key) from the query", action: remove)
            }
            MongoJSONTextField(text: $raw.text, identifier: "mongo-builder-raw")
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
        .help("Kept as JSON: the builder has no form for \(raw.key), so it's written exactly as it is here.")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mongo-builder-raw-block")
    }
}

struct MongoRemoveButton: View {
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel("Remove")
    }
}

// MARK: - Filter

/// A filter group (#217): All of, Any of, or None of its rules and nested groups. The root is
/// the filter document; nested groups are written `$and`, `$or`, `$nor`.
struct MongoFilterGroupEditor: View {
    @Binding var group: MongoFilterGroup
    var context: MongoBuilderContext
    var depth: Int
    var remove: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Picker("Match", selection: Binding(get: { group.kind }, set: { kind in
                    group.kind = kind
                    if kind != .all { group.implicit = false }
                })) {
                    ForEach(MongoFilterGroup.Kind.allCases, id: \.self) { kind in Text(kind.title).tag(kind) }
                }
                .labelsHidden()
                .fixedSize()
                .help(depth == 0 ? "All of: every condition (the filter's fields). Any of: at least one ($or). None of: none ($nor)." : "This group's conditions: all ($and), any ($or), or none ($nor).")
                .accessibilityIdentifier("mongo-builder-group-kind")
                Text(group.children.isEmpty ? (depth == 0 ? "every document" : "(empty, not written)") : "")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Menu {
                    Button("Rule") { group.children.append(.rule(MongoFilterRule())) }
                    Button("Any-of Group") { group.children.append(.group(MongoFilterGroup(kind: .any, children: [.rule(MongoFilterRule())]))) }
                    Button("All-of Group") { group.children.append(.group(MongoFilterGroup(kind: .all, implicit: group.kind != .all, children: [.rule(MongoFilterRule())]))) }
                    Button("None-of Group") { group.children.append(.group(MongoFilterGroup(kind: .none, children: [.rule(MongoFilterRule())]))) }
                    Divider()
                    Button("JSON Condition") { group.children.append(.raw(MongoRawMember(key: "$expr", text: "{ \"$gt\": [\"$total\", 0] }"))) }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a rule or a group")
                .accessibilityIdentifier("mongo-builder-add-rule")
                if let remove { MongoRemoveButton(help: "Remove the group", action: remove) }
            }
            ForEach($group.children) { $node in
                row($node)
            }
        }
        .padding(depth == 0 ? 0 : 6)
        .background(depth == 0 ? nil : RoundedRectangle(cornerRadius: 6).fill(Color.mongoDB.opacity(0.05)))
        .overlay(alignment: .leading) {
            if depth > 0 { Rectangle().fill(Color.mongoDB.opacity(0.5)).frame(width: 2) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(depth == 0 ? "mongo-builder-filter-root" : "mongo-builder-group")
    }

    @ViewBuilder
    private func row(_ node: Binding<MongoFilterNode>) -> some View {
        let id = node.wrappedValue.id
        let delete = { group.children.removeAll { $0.id == id } }
        switch node.wrappedValue {
        case .rule:
            MongoFilterRuleRow(rule: Binding(get: { if case .rule(let rule) = node.wrappedValue { rule } else { MongoFilterRule() } }, set: { node.wrappedValue = .rule($0) }),
                               context: context, remove: delete)
        case .group:
            AnyView(MongoFilterGroupEditor(group: Binding(get: { if case .group(let nested) = node.wrappedValue { nested } else { MongoFilterGroup() } }, set: { node.wrappedValue = .group($0) }),
                                           context: context, depth: depth + 1, remove: delete))
        case .raw:
            MongoRawBlockEditor(raw: Binding(get: { if case .raw(let raw) = node.wrappedValue { raw } else { MongoRawMember(key: "", text: "null") } }, set: { node.wrappedValue = .raw($0) }),
                                caption: nil, remove: delete)
        }
    }
}

/// A rule: field, operator, value. Choosing a sampled field types the value by the field's type.
struct MongoFilterRuleRow: View {
    @Binding var rule: MongoFilterRule
    var context: MongoBuilderContext
    var remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // On one line when it fits; else the value goes under the field. A date picker
            // (which doesn't shrink) always goes under it.
            if rule.op.isValueOperator, rule.value.kind == .date {
                twoLines
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        pathField.frame(minWidth: 96, maxWidth: 150)
                        operatorMenu
                        valueInput
                        MongoRemoveButton(help: "Remove the rule", action: remove)
                    }
                    twoLines
                }
            }
            if rule.op == .inList || rule.op == .notInList { listEditor }
            if rule.path.isEmpty {
                Text("Choose a field: a rule without one isn't written.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mongo-builder-rule")
    }

    private var twoLines: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                pathField
                operatorMenu
                MongoRemoveButton(help: "Remove the rule", action: remove)
            }
            HStack(spacing: 4) { valueInput }.padding(.leading, 14)
        }
    }

    private var pathField: some View {
        MongoFieldPathField(path: $rule.path, context: context, picked: { field in
            let kind = MongoValue.kind(forSampledTypes: field.types)
            if rule.op.isValueOperator, rule.value.text.isEmpty || rule.value.kind != kind { rule.value = MongoValue.empty(kind) }
        })
    }

    private var operatorMenu: some View {
        Menu {
            ForEach(MongoFilterRule.Operator.allCases, id: \.self) { op in
                Button(op.symbol) { rule.setOperator(op) }
            }
        } label: {
            Text(rule.op.symbol).font(.system(.callout, design: .monospaced).weight(.semibold)).frame(minWidth: 20)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("The operator: = ≠ > ≥ < ≤ ($eq … $lte), in and not in ($in, $nin), exists, regex, type")
        .accessibilityIdentifier("mongo-builder-operator")
    }

    @ViewBuilder private var valueInput: some View {
        if rule.op.isValueOperator {
            MongoValueEditor(value: $rule.value, fields: context.fields)
        } else {
            operatorInput
        }
    }

    @ViewBuilder private var operatorInput: some View {
        switch rule.op {
        case .exists:
            Picker("", selection: Binding(get: { rule.value.text.lowercased() != "false" }, set: { rule.value = .bool($0) })) {
                Text("yes").tag(true)
                Text("no").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 0)
        case .type:
            Picker("", selection: $rule.value.text) {
                ForEach(MongoTypeAliases.all + (MongoTypeAliases.all.contains(rule.value.text) ? [] : [rule.value.text]), id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 0)
        case .regex:
            TextField("pattern", text: $rule.value.text, prompt: Text("^pattern"))
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
            MongoRegexOptions(options: $rule.value.options)
        default:
            Text("\(rule.values.count) value\(rule.values.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var listEditor: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(rule.values.indices), id: \.self) { index in
                HStack(spacing: 4) {
                    MongoValueEditor(value: Binding(get: { rule.values.indices.contains(index) ? rule.values[index] : .string("") },
                                                    set: { if rule.values.indices.contains(index) { rule.values[index] = $0 } }), fields: context.fields)
                    MongoRemoveButton(help: "Remove the value") { if rule.values.indices.contains(index) { rule.values.remove(at: index) } }
                }
            }
            Button {
                let kind = context.types(of: rule.path).map(MongoValue.kind(forSampledTypes:)) ?? rule.values.last?.kind ?? .string
                rule.values.append(MongoValue.empty(kind))
            } label: {
                Label("Value", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.leading, 24)
    }
}

extension MongoFilterRule.Operator {
    /// Whether the operator takes one typed value (= ≠ > ≥ < ≤).
    var isValueOperator: Bool { [.equals, .notEquals, .greater, .greaterOrEqual, .less, .lessOrEqual].contains(self) }
}

// MARK: - Fields (projection, sort, $project, $addFields)

struct MongoFieldListEditor: View {
    enum Mode { case projection, sort, expression }
    @Binding var fields: [MongoFieldValue]
    var mode: Mode
    var context: MongoBuilderContext

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach($fields) { $field in
                HStack(spacing: 4) {
                    MongoFieldPathField(path: $field.path, context: context, prompt: mode == .expression ? "new field" : "field")
                        .frame(minWidth: 96, maxWidth: mode == .expression ? 130 : .infinity)
                    control($field)
                    if mode == .sort {
                        Button { move(field.id, by: -1) } label: { Image(systemName: "arrow.up") }
                            .buttonStyle(.borderless).disabled(fields.first?.id == field.id).help("Sort by this one earlier")
                        Button { move(field.id, by: 1) } label: { Image(systemName: "arrow.down") }
                            .buttonStyle(.borderless).disabled(fields.last?.id == field.id).help("Sort by this one later")
                    }
                    MongoRemoveButton(help: "Remove \(field.path)") { fields.removeAll { $0.id == field.id } }
                }
            }
            HStack(spacing: 8) {
                Button {
                    fields.append(MongoFieldValue(path: "", value: mode == .expression ? .field("") : .number("1")))
                } label: {
                    Label(mode == .sort ? "Sort Field" : "Field", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                if mode != .expression, !context.fields.isEmpty {
                    Menu("Sampled") {
                        ForEach(context.fields.filter { field in !fields.contains { $0.path == field.name } }, id: \.self) { field in
                            Button("\(field.name)   \(field.displayTypes)") { fields.append(MongoFieldValue(path: field.name, value: .number("1"))) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Add a sampled field")
                }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func control(_ field: Binding<MongoFieldValue>) -> some View {
        let value = field.wrappedValue.value
        switch mode {
        case .projection where value == .number("1") || value == .number("0") || value.kind == .bool:
            Picker("", selection: Binding(get: { value.json == .number("0") || value.json == .bool(false) ? 0 : 1 }, set: { field.wrappedValue.value = .number($0 == 1 ? "1" : "0") })) {
                Text("Include").tag(1)
                Text("Exclude").tag(0)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Menu {
                Button("Expression") { field.wrappedValue.value = .field(field.wrappedValue.path) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Project an expression instead (a field reference or JSON)")
        case .sort where value == .number("1") || value == .number("-1"):
            Picker("", selection: Binding(get: { value == .number("-1") ? -1 : 1 }, set: { field.wrappedValue.value = .number($0 == 1 ? "1" : "-1") })) {
                Text("Asc").tag(1)
                Text("Desc").tag(-1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Ascending (1) or descending (−1)")
            Spacer(minLength: 0)
        default:
            MongoValueEditor(value: field.value, kinds: mode == .sort ? [.number, .json] : MongoValue.Kind.expressions, fields: context.fields)
        }
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = fields.firstIndex(where: { $0.id == id }), fields.indices.contains(index + offset) else { return }
        fields.swapAt(index, index + offset)
    }
}

// MARK: - Pipeline

struct MongoPipelineEditor: View {
    @Binding var stages: [MongoStage]
    var context: MongoBuilderContext

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if stages.isEmpty {
                Text("No stages: aggregate returns the documents as they are.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                MongoStageCard(stage: Binding(get: { stages.first { $0.id == stage.id } ?? stage }, set: { new in
                    if let at = stages.firstIndex(where: { $0.id == stage.id }) { stages[at] = new }
                }), index: index, count: stages.count, context: context, move: { offset in
                    guard let at = stages.firstIndex(where: { $0.id == stage.id }), stages.indices.contains(at + offset) else { return }
                    stages.swapAt(at, at + offset)
                }, duplicate: {
                    if let at = stages.firstIndex(where: { $0.id == stage.id }) { stages.insert(stages[at].duplicated, at: at + 1) }
                }, remove: {
                    stages.removeAll { $0.id == stage.id }
                })
            }
            Menu {
                ForEach(MongoStage.Kind.allCases, id: \.self) { kind in
                    Button(kind == .raw ? "JSON Stage" : kind.rawValue) { stages.append(MongoStage.new(kind)) }
                }
            } label: {
                Label("Add Stage", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .controlSize(.small)
            .accessibilityIdentifier("mongo-builder-add-stage")
        }
    }
}

/// A stage card: its kind, Enabled, Move Up and Down, Duplicate, Remove, then its form.
struct MongoStageCard: View {
    @Binding var stage: MongoStage
    var index: Int
    var count: Int
    var context: MongoBuilderContext
    var move: (Int) -> Void
    var duplicate: () -> Void
    var remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 17, height: 17)
                    .background(Circle().fill(stage.enabled ? Color.mongoDB : Color.secondary))
                Text(stage.kind == .raw ? "JSON stage" : stage.kind.rawValue).font(.system(.callout, design: .monospaced).weight(.semibold))
                Spacer(minLength: 0)
                Toggle("", isOn: $stage.enabled)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help(stage.enabled ? "Enabled: written into the query. Uncheck to leave it out while keeping it here." : "Disabled: not in the query. Check to write it again.")
                    .accessibilityIdentifier("mongo-builder-stage-enabled")
                Button { move(-1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0).help("Move the stage up")
                Button { move(1) } label: { Image(systemName: "arrow.down") }.disabled(index == count - 1).help("Move the stage down")
                Menu {
                    Button("Duplicate", action: duplicate)
                    Button("Remove", role: .destructive, action: remove)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .buttonStyle(.borderless)
            if stage.enabled {
                MongoStageBody(stage: $stage, context: context)
                if let missing = stage.incomplete {
                    Text("Not written yet: \(missing)").font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Disabled: not in the query.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.18)))
        .opacity(stage.enabled ? 1 : 0.65)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mongo-builder-stage")
        .id("mongo-builder-stage-\(index + 1)")
    }
}

struct MongoStageBody: View {
    @Binding var stage: MongoStage
    var context: MongoBuilderContext

    var body: some View {
        switch stage.body {
        case .match(let group):
            AnyView(MongoFilterGroupEditor(group: Binding(get: { group }, set: { stage.body = .match($0) }), context: context, depth: 0, remove: nil))
        case .project(let fields):
            MongoFieldListEditor(fields: Binding(get: { fields }, set: { stage.body = .project($0) }), mode: .projection, context: context)
        case .group(let group):
            MongoGroupStageEditor(group: Binding(get: { group }, set: { stage.body = .group($0) }), context: context)
        case .sort(let fields):
            MongoFieldListEditor(fields: Binding(get: { fields }, set: { stage.body = .sort($0) }), mode: .sort, context: context)
        case .limit(let value):
            MongoValueEditor(value: Binding(get: { value }, set: { stage.body = .limit($0) }), kinds: [.number, .input, .json])
        case .skip(let value):
            MongoValueEditor(value: Binding(get: { value }, set: { stage.body = .skip($0) }), kinds: [.number, .input, .json])
        case .unwind(let unwind):
            MongoUnwindEditor(unwind: Binding(get: { unwind }, set: { stage.body = .unwind($0) }), context: context)
        case .lookup(let lookup):
            MongoLookupEditor(lookup: Binding(get: { lookup }, set: { stage.body = .lookup($0) }), context: context)
        case .addFields(let fields, let alias):
            MongoFieldListEditor(fields: Binding(get: { fields }, set: { stage.body = .addFields($0, alias: alias) }), mode: .expression, context: context)
        case .count(let name):
            HStack {
                Text("Output field").font(.caption).foregroundStyle(.secondary)
                TextField("count", text: Binding(get: { name }, set: { stage.body = .count($0) })).textFieldStyle(.roundedBorder).font(.system(.callout, design: .monospaced))
            }
        case .raw(let text):
            MongoJSONTextField(text: Binding(get: { text }, set: { stage.body = .raw($0) }), identifier: "mongo-builder-raw-stage")
        }
    }
}

struct MongoGroupStageEditor: View {
    @Binding var group: MongoGroupStage
    var context: MongoBuilderContext

    private enum KeyMode: String, CaseIterable { case all = "All documents", field = "A field", fields = "Fields", expression = "Expression" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Group by").font(.caption).foregroundStyle(.secondary)
                Picker("Group by", selection: Binding(get: { mode }, set: setMode)) {
                    ForEach(KeyMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("_id: null (one group), one field, several fields ({ name: \"$field\" }), or any expression")
                Spacer(minLength: 0)
            }
            keyEditor
            Text("Fields").font(.caption).foregroundStyle(.secondary)
            ForEach($group.accumulators) { $accumulator in
                HStack(spacing: 4) {
                    TextField("name", text: $accumulator.name, prompt: Text("name"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                        .frame(width: 84)
                    Menu {
                        ForEach(MongoAccumulator.operators, id: \.self) { op in Button(op) { accumulator.setOperator(op) } }
                    } label: {
                        Text(accumulator.op).font(.system(.callout, design: .monospaced))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    if accumulator.op == "$count" {
                        Text("{}").font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    } else {
                        MongoValueEditor(value: $accumulator.argument, kinds: MongoValue.Kind.expressions, fields: context.fields)
                    }
                    MongoRemoveButton(help: "Remove \(accumulator.name)") { group.accumulators.removeAll { $0.id == accumulator.id } }
                }
            }
            Button {
                group.accumulators.append(MongoAccumulator(name: "", op: "$sum", argument: .field("")))
            } label: {
                Label("Accumulator", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }

    private var mode: KeyMode {
        switch group.key {
        case .all: .all
        case .field: .field
        case .fields: .fields
        case .expression: .expression
        }
    }

    private func setMode(_ mode: KeyMode) {
        switch mode {
        case .all: group.key = .all
        case .field: group.key = .field(context.fields.first { $0.name != "_id" }?.name ?? "")
        case .fields: group.key = .fields([MongoGroupField()])
        case .expression: group.key = .expression(MongoValue(.json, "{ \"$year\": \"$date\" }"))
        }
    }

    @ViewBuilder private var keyEditor: some View {
        switch group.key {
        case .all:
            Text("\"_id\": null — one group of every document").font(.caption).foregroundStyle(.secondary)
        case .field(let path):
            MongoFieldPathField(path: Binding(get: { path }, set: { group.key = .field($0) }), context: context)
        case .fields(let fields):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(fields) { field in
                    HStack(spacing: 4) {
                        TextField("name", text: Binding(get: { field.name }, set: { name in updateKeyField(field.id) { $0.name = name } }), prompt: Text("name"))
                            .textFieldStyle(.roundedBorder).font(.system(.callout, design: .monospaced)).frame(width: 84)
                        Text(":").foregroundStyle(.secondary)
                        MongoFieldPathField(path: Binding(get: { field.path }, set: { path in
                            updateKeyField(field.id) { item in
                                if item.name.isEmpty || item.name == item.path.components(separatedBy: ".").last { item.name = path.components(separatedBy: ".").last ?? path }
                                item.path = path
                            }
                        }), context: context)
                        MongoRemoveButton(help: "Remove") { if case .fields(var list) = group.key { list.removeAll { $0.id == field.id }; group.key = .fields(list) } }
                    }
                }
                Button {
                    if case .fields(var list) = group.key { list.append(MongoGroupField()); group.key = .fields(list) }
                } label: {
                    Label("Field", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        case .expression(let value):
            MongoValueEditor(value: Binding(get: { value }, set: { group.key = .expression($0) }), kinds: MongoValue.Kind.expressions, fields: context.fields)
        }
    }

    private func updateKeyField(_ id: UUID, _ change: (inout MongoGroupField) -> Void) {
        guard case .fields(var list) = group.key, let index = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[index])
        group.key = .fields(list)
    }
}

struct MongoUnwindEditor: View {
    @Binding var unwind: MongoUnwindStage
    var context: MongoBuilderContext

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Array").font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                MongoFieldPathField(path: $unwind.path, context: context, prompt: "items", fields: context.fields.filter { $0.types.contains("array") || $0.types.contains("PackedArray") }.nilIfEmpty)
            }
            HStack(spacing: 4) {
                Text("Index field").font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                TextField("optional", text: $unwind.includeArrayIndex, prompt: Text("optional")).textFieldStyle(.roundedBorder).font(.system(.callout, design: .monospaced))
            }
            Toggle("Keep documents without the array", isOn: Binding(get: { unwind.preserveNullAndEmptyArrays ?? false }, set: { unwind.preserveNullAndEmptyArrays = $0 ? true : (unwind.objectForm && unwind.preserveNullAndEmptyArrays != nil ? false : nil) }))
                .toggleStyle(.checkbox)
                .font(.callout)
                .help("preserveNullAndEmptyArrays")
        }
    }
}

struct MongoLookupEditor: View {
    @Binding var lookup: MongoLookupStage
    var context: MongoBuilderContext

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("From") { MongoNameField(text: $lookup.from, prompt: "customers", options: context.collections, identifier: "mongo-builder-lookup-from") }
            row("Local field") { MongoFieldPathField(path: $lookup.localField, context: context, prompt: "customer_id") }
            row("Foreign field") { MongoFieldPathField(path: $lookup.foreignField, context: context, prompt: "_id", fields: context.fieldsOf(lookup.from).nilIfEmpty ?? []) }
            row("As") {
                TextField("customer", text: $lookup.output, prompt: Text("customer")).textFieldStyle(.roundedBorder).font(.system(.callout, design: .monospaced))
            }
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
            content()
        }
    }
}

// MARK: - Update

struct MongoUpdateEditor: View {
    @Binding var nodes: [MongoUpdateNode]
    var context: MongoBuilderContext

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach($nodes) { $node in
                let id = node.id
                switch node {
                case .entry(let entry):
                    MongoUpdateRow(entry: Binding(get: { entry }, set: { node = .entry($0) }), context: context) { nodes.removeAll { $0.id == id } }
                case .raw(let raw):
                    MongoRawBlockEditor(raw: Binding(get: { raw }, set: { node = .raw($0) }), caption: nil) { nodes.removeAll { $0.id == id } }
                }
            }
            Button {
                nodes.append(.entry(MongoUpdateEntry()))
            } label: {
                Label("Change", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityIdentifier("mongo-builder-add-change")
        }
    }
}

struct MongoUpdateRow: View {
    @Binding var entry: MongoUpdateEntry
    var context: MongoBuilderContext
    var remove: () -> Void

    var body: some View {
        Group {
            if entry.op != .unset, entry.value.kind == .date {
                twoLines
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        operatorMenu
                        pathField.frame(minWidth: 90, maxWidth: 140)
                        valueInput
                        MongoRemoveButton(help: "Remove the change", action: remove)
                    }
                    twoLines
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mongo-builder-change")
    }

    private var twoLines: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                operatorMenu
                pathField
                MongoRemoveButton(help: "Remove the change", action: remove)
            }
            HStack(spacing: 4) { valueInput }.padding(.leading, 14)
        }
    }

    private var operatorMenu: some View {
        Menu {
            ForEach(MongoUpdateEntry.Operator.allCases, id: \.self) { op in Button(op.rawValue) { entry.setOperator(op) } }
        } label: {
            Text(entry.op.rawValue).font(.system(.callout, design: .monospaced).weight(.semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("$set a value, $unset (remove) the field, $inc (add to) a number, $push onto or $pull from an array")
    }

    private var pathField: some View {
        MongoFieldPathField(path: $entry.path, context: context, picked: { field in
            if entry.op == .set { entry.value = MongoValue.empty(MongoValue.kind(forSampledTypes: field.types)) }
        })
    }

    @ViewBuilder private var valueInput: some View {
        if entry.op == .unset {
            Text("removed").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        } else {
            MongoValueEditor(value: $entry.value, kinds: entry.op == .inc ? [.number, .decimal, .long] : MongoValue.Kind.literals, fields: context.fields)
        }
    }
}

// MARK: - Footer

/// The query the builder wrote, how Runlet will treat it, what isn't written yet, and Insert as
/// New Query; the same place as the Command Builder's preview (#218).
struct MongoBuilderFooter: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    @Bindable var state: MongoBuilderState

    var body: some View {
        if let builder = state.builder {
            let text = builder.text
            let effect = builder.effect
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Query").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if let lines = state.lines {
                        Text(lines.count == 1 ? "line \(lines.lowerBound)" : "lines \(lines.lowerBound)–\(lines.upperBound)").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    MongoEffectBadge(effect: effect)
                }
                ScrollView {
                    BuilderPreviewBox(text: text ?? "", emphasis: effect == .destructive ? .danger : effect == .write ? .write : .read, identifier: "mongo-builder-preview")
                }
                .frame(maxHeight: 96)
                .id(text)
                if let problem = builder.problem {
                    issue("Not written yet: \(problem)", blocking: true)
                }
                ForEach(builder.incomplete, id: \.self) { issue($0, blocking: false) }
                if let refusal = builder.runProblem {
                    issue("⌘R would refuse it: \(refusal)", blocking: true)
                }
                if effect == .destructive {
                    Label("Run asks first: it \(builder.operation == "drop" ? "drops the collection" : "changes every document").", systemImage: "exclamationmark.octagon.fill")
                        .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if let saved = model.sqlConnectionChoice(for: tab).savedConnection, saved.readOnly, effect != .read, effect != nil {
                    Label("The connection “\(saved.name)” is read-only: Run would refuse this query.", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button {
                        model.insertMongoBuilderQuery(tab)
                    } label: {
                        Label("Insert as New Query", systemImage: "text.insert")
                    }
                    .disabled(text == nil)
                    .help("Insert a copy of this query after it, as a new query the builder then edits. One edit: Undo takes it back. Nothing runs.")
                    .accessibilityIdentifier("mongo-builder-insert")
                    if model.mongoBuilderHasSeveralQueries(tab) {
                        Button("Select") { model.selectMongoBuilderQuery(tab) }
                            .help("Select this query in the editor: with several queries in the tab, ⌘R runs the selected one")
                            .accessibilityIdentifier("mongo-builder-select")
                    }
                    Spacer(minLength: 0)
                    Button {
                        if let text { Pasteboard.copy(text) }
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .disabled(text == nil)
                    .help("Copy the query")
                    .accessibilityLabel("Copy")
                }
                .controlSize(.small)
                Text("Every change is written into the tab, one Undo step each. Nothing runs from here: ⌘R runs the query, with the usual confirmations.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mongo-builder-footer")
        }
    }

    private func issue(_ text: String, blocking: Bool) -> some View {
        Label(text, systemImage: blocking ? "exclamationmark.circle.fill" : "info.circle")
            .font(.caption)
            .foregroundStyle(blocking ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension Array {
    /// nil for an empty array (to fall back to another list).
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}
