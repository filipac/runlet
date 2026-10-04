import RunletCore
import SwiftUI

/// The command builder's place beside a Redis tab's editor (#218): the panel while it is open.
struct RedisCommandBuilderSlot: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel

    var body: some View {
        let state = model.redisBuilder(for: tab)
        if state.isOpen {
            RedisCommandBuilderPanel(tab: tab, state: state)
        }
    }
}

/// The command builder (#218): a searchable command list grouped by data type, a form made
/// from the command's syntax, and the exact line it writes. Insert puts the line after the
/// caret's, Replace Line in place of it, each one undoable edit. It never runs anything: ⌘R
/// runs the line from the editor, with read-only refusals and confirmations as usual.
struct RedisCommandBuilderPanel: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    @Bindable var state: RedisBuilderState

    var body: some View {
        // The panel's frame is shared with MongoDB's Query Builder (#217): `BuilderPanel`.
        BuilderPanel(identifier: "redis-builder", width: state.width, range: 280...560, note: state.note, commitWidth: { state.width = $0 }) {
            header
        } content: {
            if state.showsPicker || state.form == nil {
                RedisCommandPicker(tab: tab, state: state)
            } else if state.form != nil {
                RedisCommandFormView(tab: tab, state: state)
                Divider()
                RedisBuilderPreview(tab: tab, state: state)
            }
        }
    }

    private var header: some View {
        BuilderHeader(systemImage: "hammer.fill", color: .red, title: "Command Builder") {
            if !state.showsPicker, state.form != nil {
                Button {
                    state.showsPicker = true
                } label: {
                    Image(systemName: "list.bullet")
                }
                .help("Choose another command")
                .accessibilityLabel("Commands")
                .accessibilityIdentifier("redis-builder-commands")
            }
            Button {
                model.readRedisBuilderLine(tab)
            } label: {
                Image(systemName: "text.viewfinder")
            }
            .help("Read Line: put the command on the caret's line into the form. A line the builder can't read leaves the form fresh and the text unchanged.")
            .accessibilityLabel("Read Line")
            .accessibilityIdentifier("redis-builder-read")
            Button {
                model.toggleRedisBuilder(tab)
            } label: {
                Image(systemName: "xmark")
            }
            .help("Close the Command Builder (⌥⌘B)")
            .accessibilityLabel("Close")
            .accessibilityIdentifier("redis-builder-close")
        }
    }
}

// MARK: - Picker

/// The command list: search by name or summary, grouped by data type, writes and dangerous
/// commands marked. Any other command gets a form of raw arguments.
struct RedisCommandPicker: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    @Bindable var state: RedisBuilderState
    @FocusState private var searchFocused: Bool

    var body: some View {
        let groups = RedisCommandSpecs.grouped(matching: state.search)
        VStack(spacing: 0) {
            TextField("Search commands", text: $state.search, prompt: Text("Search: ZRANGE, expire, stream…"))
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit {
                    if let first = groups.first?.commands.first {
                        model.chooseRedisBuilderCommand(tab, spec: first)
                    } else if !state.search.trimmingCharacters(in: .whitespaces).isEmpty {
                        model.chooseRedisBuilderCommand(tab, spec: nil, rawName: state.search)
                    }
                }
                .padding(8)
                .accessibilityIdentifier("redis-builder-search")
            List {
                ForEach(groups, id: \.group) { entry in
                    Section(entry.group.title) {
                        ForEach(entry.commands) { spec in
                            row(spec)
                        }
                    }
                }
                let name = state.search.trimmingCharacters(in: .whitespaces)
                if RedisCommandSpecs.spec(named: name) == nil {
                    Section("Other") {
                        Button {
                            model.chooseRedisBuilderCommand(tab, spec: nil, rawName: name)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name.isEmpty ? "Another command…" : name.uppercased())
                                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                                Text("A command without a syntax in Runlet: its name and raw arguments.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("redis-builder-raw")
                    }
                }
            }
            .listStyle(.sidebar)
            .accessibilityIdentifier("redis-builder-list")
        }
        .onAppear { searchFocused = true }
    }

    private func row(_ spec: RedisCommandSpec) -> some View {
        Button {
            model.chooseRedisBuilderCommand(tab, spec: spec)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(spec.name).font(.system(.callout, design: .monospaced).weight(.semibold))
                    RedisClassBadges(info: spec.info, showsRead: false)
                }
                Text(spec.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(spec.syntax)
        .accessibilityIdentifier("redis-builder-command-\(spec.name)")
    }
}

/// Small capsules for how Runlet treats a command: WRITE, DANGEROUS, BLOCKS (and READ).
struct RedisClassBadges: View {
    let info: RedisCommands.Info
    var showsRead = true

    var body: some View {
        HStack(spacing: 3) {
            if info.dangerous {
                badge("DANGEROUS", .red, help: "Dangerous: \(info.name) \(info.danger ?? "is dangerous"). Run always asks first, on every connection.")
            }
            switch info.access {
            case .write:
                badge("WRITE", .orange, help: "Can change data or the server. A read-only connection refuses it.")
            case .unknown:
                badge("UNKNOWN", .gray, help: "Runlet doesn't know whether it writes, so it counts as a write. A read-only connection refuses it.")
            case .streaming:
                badge("STREAMS", .gray, help: "Streams replies, which Redis tabs don't read yet: Runlet refuses it.")
            case .connection where showsRead:
                badge("CONNECTION", .blue, help: "Changes only this connection's state.")
            case .read where showsRead && !info.dangerous:
                badge("READ", .green, help: "Reads only.")
            default:
                EmptyView()
            }
            if info.blocking {
                badge("BLOCKS", .purple, help: "Waits on the server; Stop ends it.")
            }
        }
    }

    private func badge(_ text: String, _ color: Color, help: String) -> some View {
        BuilderBadge(text: text, color: color, help: help)
    }
}

// MARK: - Form

/// The form of the chosen command: one field (or group) per argument of its syntax.
struct RedisCommandFormView: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    @Bindable var state: RedisBuilderState

    var body: some View {
        let keys = model.redisBuilderKeys(for: tab)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let form = state.form {
                    title(form)
                    if let spec = form.spec {
                        RedisArgumentsEditor(arguments: spec.arguments, values: valuesBinding, keys: keys.keys)
                        if !form.extra.isEmpty { extraEditor(title: "Arguments the builder couldn't place", note: "Written after the others, as they are.") }
                    } else {
                        rawEditor
                    }
                    if !keys.keys.isEmpty {
                        Text("Key fields complete from the key browser's last scan (db\(keys.db ?? 0), \(keys.keys.count.formatted()) key\(keys.keys.count == 1 ? "" : "s")). Typing reads nothing from Redis.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("redis-builder-form")
    }

    @ViewBuilder
    private func title(_ form: RedisCommandForm) -> some View {
        if let spec = form.spec {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(spec.name).font(.system(.title3, design: .monospaced).weight(.semibold))
                    Text(spec.group.title).font(.caption).foregroundStyle(.secondary)
                    RedisClassBadges(info: spec.info, showsRead: false)
                }
                Text(spec.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(spec.syntax)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("redis-builder-syntax")
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Raw command").font(.title3.weight(.semibold))
                Text("Runlet has no syntax for this command: type its name and arguments. Each field is one argument, quoted for you.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var valuesBinding: Binding<[RedisArgumentValue]> {
        Binding(get: { state.form?.values ?? [] }, set: { state.form?.values = $0 })
    }

    private var rawEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            RedisFieldRow(label: Text("command")) {
                TextField("Command", text: Binding(get: { state.form?.rawName ?? "" }, set: { state.form?.rawName = $0 }), prompt: Text("CLUSTER INFO"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityIdentifier("redis-builder-raw-name")
            }
            extraEditor(title: "Arguments", note: nil)
        }
    }

    private func extraEditor(title: String, note: String?) -> some View {
        let rows = Binding<[String]>(get: { state.form?.extra ?? [] }, set: { state.form?.extra = $0 })
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let note { Text(note).font(.caption2).foregroundStyle(.secondary) }
            ForEach(rows.wrappedValue.indices, id: \.self) { index in
                HStack(spacing: 4) {
                    TextField("argument", text: Binding(get: { index < rows.wrappedValue.count ? rows.wrappedValue[index] : "" },
                                                        set: { if index < rows.wrappedValue.count { rows.wrappedValue[index] = $0 } }))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Button {
                        if index < rows.wrappedValue.count { rows.wrappedValue.remove(at: index) }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this argument")
                }
            }
            Button {
                rows.wrappedValue.append("")
            } label: {
                Label("Add Argument", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityIdentifier("redis-builder-add-extra")
        }
    }
}

/// A label column and a field.
struct RedisFieldRow<Field: View>: View {
    let label: Text
    @ViewBuilder var field: Field

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            label
                .font(.callout)
                .lineLimit(1)
                .frame(width: 92, alignment: .leading)
            field
        }
    }
}

/// A run of arguments (a command's, or a block's): `numkeys` shows its count; the others
/// get editors.
struct RedisArgumentsEditor: View {
    let arguments: [RedisArgument]
    @Binding var values: [RedisArgumentValue]
    let keys: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(arguments.indices, id: \.self) { index in
                let argument = arguments[index]
                if argument.kind == .count {
                    let counted = index + 1 < values.count ? values[index + 1].rows.filter { $0.value != nil }.count : 0
                    RedisFieldRow(label: RedisArgumentLabel.text(argument)) {
                        Text("\(counted), counted from the \(index + 1 < arguments.count ? arguments[index + 1].name : "values")s")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    RedisArgumentEditor(argument: argument, value: binding(index), keys: keys)
                }
            }
        }
    }

    private func binding(_ index: Int) -> Binding<RedisArgumentValue> {
        Binding(get: { index < values.count ? values[index] : .empty(arguments[index]) },
                set: { if index < values.count { values[index] = $0 } })
    }
}

/// How an argument is labelled: its token in bold, then its name.
enum RedisArgumentLabel {
    static func text(_ argument: RedisArgument) -> Text {
        if argument.kind == .pureToken { return Text(argument.token ?? argument.name).font(.system(.callout, design: .monospaced).weight(.semibold)) }
        if let token = argument.token {
            return Text("\(Text(token).font(.system(.callout, design: .monospaced).weight(.semibold))) \(Text(argument.name).foregroundStyle(.secondary))")
        }
        return Text(argument.name)
    }

    /// A one-of's choice: its token (`EX`, `NX`), or its name (`id`).
    static func choice(_ argument: RedisArgument) -> String {
        argument.token ?? argument.name
    }
}

/// One argument's editor, by its kind: a check box for an option, a choice, a group (on/off,
/// or rows to add and remove), or a value field.
struct RedisArgumentEditor: View {
    let argument: RedisArgument
    @Binding var value: RedisArgumentValue
    let keys: [String]

    var body: some View {
        switch argument.kind {
        case .pureToken:
            if argument.isOptional {
                Toggle(isOn: $value.isOn) {
                    RedisArgumentLabel.text(argument)
                }
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("redis-builder-token-\(argument.token ?? argument.name)")
            } else {
                RedisArgumentLabel.text(argument)
            }
        case .count:
            EmptyView()
        case .oneOf:
            oneOf
        case .block:
            block
        case .key, .string, .integer, .double, .pattern, .unixTime:
            if argument.isMultiple {
                multipleValues
            } else {
                RedisFieldRow(label: RedisArgumentLabel.text(argument)) {
                    RedisValueField(argument: argument, value: rowValue(0), keys: keys)
                }
            }
        }
    }

    // MARK: One of

    private var choiceBinding: Binding<Int> {
        Binding(get: { value.isOn || !argument.isOptional ? (value.rows.first?.choice ?? 0) : -1 },
                set: { choice in
                    if choice < 0 {
                        value.isOn = false
                    } else {
                        value.isOn = true
                        if value.rows.isEmpty { value.rows = [.empty(argument)] }
                        value.rows[0].choice = choice
                    }
                })
    }

    @ViewBuilder
    private var oneOf: some View {
        let titles = argument.children.map(RedisArgumentLabel.choice)
        // Segmented for a few short choices (NX | XX), a menu otherwise (EX | PX | …, BYSCORE | BYLEX).
        let segmented = titles.count + (argument.isOptional ? 1 : 0) <= 4 && titles.joined().count <= 10
        VStack(alignment: .leading, spacing: 6) {
            RedisFieldRow(label: argument.token.map { Text($0).font(.system(.callout, design: .monospaced).weight(.semibold)) } ?? Text(argument.name)) {
                Picker(argument.name, selection: choiceBinding) {
                    if argument.isOptional { Text("—").tag(-1) }
                    ForEach(titles.indices, id: \.self) { index in
                        Text(titles[index]).tag(index)
                    }
                }
                .labelsHidden()
                .modifier(RedisChoiceStyle(segmented: segmented))
                .fixedSize()
                .help(argument.syntax)
                .accessibilityIdentifier("redis-builder-choice-\(argument.name)")
            }
            if value.isOn || !argument.isOptional, let row = value.rows.first, argument.children.indices.contains(row.choice) {
                let branch = argument.children[row.choice]
                if branch.kind != .pureToken {
                    RedisArgumentEditor(argument: Self.required(branch), value: branchValue(row.choice), keys: keys)
                        .padding(.leading, 14)
                }
            }
        }
    }

    /// A one-of's branch is required once chosen.
    private static func required(_ argument: RedisArgument) -> RedisArgument {
        var copy = argument
        copy.isOptional = false
        return copy
    }

    private func branchValue(_ choice: Int) -> Binding<RedisArgumentValue> {
        Binding(get: {
            guard let row = value.rows.first, choice < row.children.count else { return .empty(argument.children[choice]) }
            return row.children[choice]
        }, set: { newValue in
            guard !value.rows.isEmpty, choice < value.rows[0].children.count else { return }
            value.rows[0].children[choice] = newValue
        })
    }

    // MARK: Blocks

    @ViewBuilder
    private var block: some View {
        if argument.isMultiple {
            blockRows
        } else if argument.isOptional {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $value.isOn) {
                    argument.token.map { Text($0).font(.system(.callout, design: .monospaced).weight(.semibold)) } ?? Text(argument.name)
                }
                .toggleStyle(.checkbox)
                .help(argument.syntax)
                .accessibilityIdentifier("redis-builder-block-\(argument.name)")
                if value.isOn {
                    RedisArgumentsEditor(arguments: argument.children, values: childrenBinding(0), keys: keys)
                        .padding(.leading, 18)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if let token = argument.token {
                    Text(token).font(.system(.callout, design: .monospaced).weight(.semibold))
                }
                RedisArgumentsEditor(arguments: argument.children, values: childrenBinding(0), keys: keys)
                    .padding(.leading, argument.token == nil ? 0 : 14)
            }
        }
    }

    /// Rows of a repeated block (field/value pairs, score/member, key/id), with Add and Remove.
    private var blockRows: some View {
        let columns = argument.children
        let inline = columns.allSatisfy { $0.isValue && $0.token == nil && !$0.isMultiple }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let token = argument.token {
                    Text(token).font(.system(.callout, design: .monospaced).weight(.semibold))
                }
                if inline {
                    ForEach(columns.indices, id: \.self) { column in
                        Text(columns[column].name).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(width: 18, height: 1)
                } else {
                    Text(argument.name).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(value.rows.indices, id: \.self) { row in
                HStack(alignment: .top, spacing: 4) {
                    if inline {
                        ForEach(columns.indices, id: \.self) { column in
                            RedisValueField(argument: columns[column], value: cellValue(row: row, column: column), keys: keys)
                        }
                    } else {
                        RedisArgumentsEditor(arguments: columns, values: childrenBinding(row), keys: keys)
                    }
                    removeButton(row)
                }
            }
            addButton("Add \(inline ? columns.map(\.name).joined(separator: " and ") : argument.name)") {
                value.rows.append(.empty(argument))
            }
        }
        .accessibilityIdentifier("redis-builder-rows-\(argument.name)")
    }

    private func childrenBinding(_ row: Int) -> Binding<[RedisArgumentValue]> {
        Binding(get: { row < value.rows.count ? value.rows[row].children : argument.children.map(RedisArgumentValue.empty) },
                set: { if row < value.rows.count { value.rows[row].children = $0 } })
    }

    private func cellValue(row: Int, column: Int) -> Binding<String?> {
        Binding(get: {
            guard row < value.rows.count, column < value.rows[row].children.count else { return nil }
            return value.rows[row].children[column].rows.first?.value
        }, set: { newValue in
            guard row < value.rows.count, column < value.rows[row].children.count else { return }
            if value.rows[row].children[column].rows.isEmpty { value.rows[row].children[column].rows = [.init()] }
            value.rows[row].children[column].rows[0].value = newValue
        })
    }

    // MARK: Values

    private func rowValue(_ row: Int) -> Binding<String?> {
        Binding(get: { row < value.rows.count ? value.rows[row].value : nil },
                set: { newValue in
                    while value.rows.count <= row { value.rows.append(.init()) }
                    value.rows[row].value = newValue
                })
    }

    private var multipleValues: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                RedisArgumentLabel.text(argument).font(.callout)
                if argument.isOptional { Text("optional").font(.caption2).foregroundStyle(.tertiary) }
            }
            ForEach(value.rows.indices, id: \.self) { row in
                HStack(spacing: 4) {
                    RedisValueField(argument: argument, value: rowValue(row), keys: keys)
                    removeButton(row)
                }
            }
            addButton("Add \(argument.name)") { value.rows.append(.init()) }
        }
        .accessibilityIdentifier("redis-builder-rows-\(argument.name)")
    }

    @ViewBuilder
    private func removeButton(_ row: Int) -> some View {
        if value.rows.count > 1 {
            Button {
                if row < value.rows.count { value.rows.remove(at: row) }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this row")
        } else {
            Color.clear.frame(width: 14, height: 1)
        }
    }

    private func addButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus.circle")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .accessibilityIdentifier("redis-builder-add-\(argument.name)")
    }
}

/// Segmented for a few short choices, else a menu.
private struct RedisChoiceStyle: ViewModifier {
    let segmented: Bool

    func body(content: Content) -> some View {
        if segmented {
            content.pickerStyle(.segmented)
        } else {
            content.pickerStyle(.menu)
        }
    }
}

/// One value's field: monospaced text (several lines for strings), key names from the key
/// browser's last scan, suggested values (INFO sections, SCAN types), and for durations a
/// unit and common values. An empty field is left out; "Empty String" writes `""`.
struct RedisValueField: View {
    let argument: RedisArgument
    @Binding var value: String?
    let keys: [String]

    var body: some View {
        HStack(spacing: 4) {
            TextField(argument.name, text: text, prompt: Text(prompt), axis: argument.kind == .string ? .vertical : .horizontal)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .lineLimit(argument.kind == .string ? 1...4 : 1...1)
                .textInputSuggestions {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Text(suggestion).textInputCompletion(suggestion)
                    }
                }
                .contextMenu {
                    Button("Empty String (\"\")") { value = "" }
                    Button("Clear") { value = nil }
                }
                .help(help)
                .accessibilityIdentifier("redis-builder-field-\(argument.name)")
            if let unit = argument.unit {
                Menu {
                    ForEach(Self.presets, id: \.0) { preset in
                        Button(preset.0) { value = String(unit == .seconds ? preset.1 : preset.1 * 1000) }
                    }
                } label: {
                    Text(unit == .seconds ? "s" : "ms").font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Common durations")
            }
            if let note = durationNote {
                Text(note).font(.caption2).foregroundStyle(.secondary).fixedSize()
            }
        }
    }

    static let presets: [(String, Int)] = [("1 minute", 60), ("10 minutes", 600), ("1 hour", 3600), ("1 day", 86400), ("1 week", 604_800), ("30 days", 2_592_000)]

    private var text: Binding<String> {
        Binding(get: { value ?? "" }, set: { value = $0.isEmpty ? nil : $0 })
    }

    private var prompt: String {
        if value == "" { return "\"\" (empty string)" }
        if let placeholder = argument.placeholder { return placeholder }
        return argument.isOptional ? "optional" : argument.name
    }

    private var help: String {
        var parts = ["\(argument.name): \(Self.kindName(argument.kind))"]
        if argument.isOptional { parts.append("optional; left out when empty") }
        if argument.kind == .key, !keys.isEmpty { parts.append("completes from the key browser's last scan") }
        return parts.joined(separator: " · ")
    }

    private static func kindName(_ kind: RedisArgument.Kind) -> String {
        switch kind {
        case .key: "a key"
        case .integer: "a whole number"
        case .double: "a number (inf, +inf, -inf too)"
        case .pattern: "a pattern: * any characters, ? one, [ab] a set"
        case .unixTime: "a Unix time"
        default: "text"
        }
    }

    /// Key names (or the argument's suggested values) that start with what's typed.
    private var suggestions: [String] {
        let typed = value ?? ""
        let pool = argument.kind == .key ? keys : argument.suggestions
        guard !pool.isEmpty else { return [] }
        let matching = typed.isEmpty ? pool : pool.filter { $0.range(of: typed, options: [.caseInsensitive, .anchored]) != nil || $0.localizedCaseInsensitiveContains(typed) }
        return Array(matching.filter { $0 != typed }.prefix(50))
    }

    /// "= 1 h" next to a duration.
    private var durationNote: String? {
        guard let unit = argument.unit, argument.kind == .integer, let text = value, let number = Int64(text), number > 0 else { return nil }
        let milliseconds = unit == .seconds ? number * 1000 : number
        let formatted = RedisKeyEntry.ttlText(milliseconds)
        return formatted == text + " s" || formatted == text + " ms" ? nil : "= " + formatted
    }
}

// MARK: - Preview

/// The line the builder writes, quoted as the Redis tab reads it, with how Runlet will treat
/// it, what's missing, and Insert and Replace Line.
struct RedisBuilderPreview: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    @Bindable var state: RedisBuilderState

    var body: some View {
        if let form = state.form {
            let rendered = form.render()
            let info = RedisCommands.classify(rendered.arguments)
            let line = rendered.arguments.map(RedisScript.quoted).joined(separator: " ")
            let canWrite = !form.nameWords.isEmpty && !rendered.issues.contains(where: \.isBlocking)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Preview").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    RedisClassBadges(info: info)
                }
BuilderPreviewBox(text: line, emphasis: info.dangerous ? .danger : info.access == .read ? .read : .write, identifier: "redis-builder-preview")
                ForEach(rendered.issues, id: \.self) { issue in
                    Label(issue.message, systemImage: issue.isBlocking ? "exclamationmark.circle.fill" : "info.circle")
                        .font(.caption)
                        .foregroundStyle(issue.isBlocking ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if info.dangerous {
                    Label("Run asks first: \(info.name) \(info.danger ?? "is dangerous").", systemImage: "exclamationmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let saved = model.sqlConnectionChoice(for: tab).savedConnection, saved.readOnly, !info.allowedReadOnly {
                    Label("The connection “\(saved.name)” is read-only: Run would refuse this command.", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button {
                        model.writeRedisBuilder(tab, replace: false)
                    } label: {
                        Label("Insert", systemImage: "text.insert")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canWrite)
                    .help("Insert the command on a new line after the caret's line (on it, when it's blank). One edit: Undo takes it back. Nothing runs.")
                    .accessibilityIdentifier("redis-builder-insert")
                    Button {
                        model.writeRedisBuilder(tab, replace: true)
                    } label: {
                        Label("Replace Line", systemImage: "arrow.left.arrow.right")
                    }
                    .disabled(!canWrite || !model.redisBuilderCanReplace(tab))
                    .help("Replace the command on the caret's line with this one. One edit: Undo takes it back. Nothing runs.")
                    .accessibilityIdentifier("redis-builder-replace")
                    Spacer(minLength: 0)
                    Button {
                        Pasteboard.copy(line)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .disabled(line.isEmpty)
                    .help("Copy the command")
                    .accessibilityLabel("Copy")
                }
                .controlSize(.small)
                Text("Nothing runs from here: ⌘R runs the caret's line, with the usual confirmations.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("redis-builder-footer")
        }
    }
}

#if DEBUG
/// DEBUG step `redis-key-menu:<key>` (#218): a key's context menu, with the Insert Command
/// submenu open, as a popover a snapshot can draw.
struct RedisKeyMenuPreview: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    let entry: RedisKeyEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Open Value")
            Text("Memory Usage")
            Divider()
            Text("Copy Key")
            HStack {
                Text("Insert Command")
                Spacer()
                Image(systemName: "chevron.right").font(.caption)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.2)))
            VStack(alignment: .leading, spacing: 5) {
                ForEach(entry.builderCommands) { command in
                    Button(command.title) {
                        model.openRedisBuilder(tab, key: entry, command: command)
                        model.redisBuilders.debugMenuKey = nil
                    }
                    .buttonStyle(.plain)
                    .font(.system(.callout, design: .monospaced))
                }
            }
            .padding(.leading, 16)
        }
        .padding(10)
        .frame(minWidth: 220, alignment: .leading)
    }
}
#endif
