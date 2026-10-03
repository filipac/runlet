import RunletCore
import SwiftUI

/// The parameters drawer under an SQL tab's editor (#168): when what the next run sends has
/// `:name` or `?` placeholders, one row per value (a name once, each `?` in order) with the
/// line it is on, its type, and its value, set before running. Rows follow the text and the
/// caret shortly after the editor settles; values set here stay with the tab for the session.
/// It collapses to a one-line summary and hides without placeholders.
///
/// Keyboard: Tab and ⇧Tab move between the fields, Return runs (Run, or Run All while the
/// drawer shows all statements), ⌘R runs as everywhere, Escape returns to the editor.
struct SQLParameterDrawerView: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    @FocusState private var focused: SQLParameter.Key?

    static let rowHeight: CGFloat = 28
    static let headerHeight: CGFloat = 30
    /// Rows shown before the list scrolls.
    static let visibleRows: CGFloat = 5.5

    var body: some View {
        let drawer = model.sqlParameterDrawer(for: tab)
        let driver = model.sqlDriver(for: model.sqlConnectionChoice(for: tab), target: tab.target)
        let content = drawer.content
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if !content.isEmpty {
                    Divider()
                    header(drawer, content)
                    if !drawer.collapsed {
                        if let problem = content.problem {
                            notice(problem.description, systemImage: "exclamationmark.triangle.fill", identifier: "sql-parameters-problem")
                        }
                        if !content.presetProblems.isEmpty {
                            notice((content.presetProblems.count == 1 ? "A @param line could not be read: " : "\(content.presetProblems.count) @param lines could not be read: ") + content.presetProblems.joined(separator: "; "),
                                   systemImage: "exclamationmark.triangle.fill", identifier: "sql-parameters-preset-problems")
                        }
                        if !content.rows.isEmpty { rows(drawer, content) }
                    }
                } else {
                    // Keeps the view (and its refresh on appear) without taking room.
                    Color.clear.frame(height: 0)
                }
            }
            .background {
                if !content.isEmpty {
                    ZStack {
                        Color(nsColor: .windowBackgroundColor)
                        Color.teal.opacity(0.06)
                    }
                }
            }
            .onExitCommand { tab.editor.focus() }
            .onChange(of: drawer.focusRequest) { _, request in
                guard let request else { return }
                // The rows may only just have appeared (the drawer was collapsed or hidden).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    proxy.scrollTo(request.key)
                    focused = request.key
                }
            }
        }
        .onChange(of: focused) { _, key in model.sqlParameterDrawer(for: tab).focusedRow = key }
        .onAppear { model.refreshSQLParameters(tab) }
        .onChange(of: driver) { model.refreshSQLParameters(tab) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sql-parameters-drawer")
    }

    // MARK: Header

    private func header(_ drawer: SQLParameterDrawer, _ content: SQLParameterDrawerModel.Content) -> some View {
        HStack(spacing: 8) {
            Button {
                drawer.collapsed.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(drawer.collapsed ? 0 : 90))
                        .frame(width: 10)
                    Image(systemName: "curlybraces.square").foregroundStyle(.teal)
                    Text("Parameters").fontWeight(.semibold)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(drawer.collapsed ? "Show the parameters" : "Collapse to one line")
            .accessibilityIdentifier("sql-parameters-toggle")
            if drawer.collapsed {
                Text(content.summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(content.summary)
                    .accessibilityIdentifier("sql-parameters-summary")
            } else if let note = drawer.note {
                Label(note, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(note)
                    .accessibilityIdentifier("sql-parameters-note")
            } else {
                Label(scopeCaption(drawer, content), systemImage: "lock.shield")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help("Runlet sends the values apart from the statement and binds each with PDOStatement::bindValue and its type. The tab remembers what you set here until you quit; values from -- @param comments follow the comments.")
            }
            Spacer(minLength: 4)
            if content.statementCount > 1 {
                Picker("Values for", selection: Binding(get: { drawer.scope }, set: { scope in
                    drawer.setScope(scope)
                })) {
                    Text("Statement").tag(SQLParameterDrawerModel.Scope.statement)
                    Text("All Statements").tag(SQLParameterDrawerModel.Scope.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("Statement: the values Run needs (the selection, or the statement at the caret). All Statements: the values Run All Statements needs. Return in a field runs the one shown.")
                .accessibilityIdentifier("sql-parameters-scope")
            }
            Button {
                model.runFromSQLParameterDrawer(tab)
            } label: {
                Label(drawer.scope == .all ? "Run All" : "Run", systemImage: drawer.scope == .all ? "play.square.stack" : "play.fill")
            }
            .buttonStyle(.borderless)
            .disabled(tab.isRunning)
            .help(drawer.scope == .all ? "Run All Statements with these values (↩ in a field)" : "Run the statement with these values (↩ in a field, or ⌘R)")
            .accessibilityIdentifier("sql-parameters-run")
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: Self.headerHeight)
    }

    /// "Values for line 3, bound, never written into the SQL"
    private func scopeCaption(_ drawer: SQLParameterDrawer, _ content: SQLParameterDrawerModel.Content) -> String {
        let count = content.rows.count == 1 ? "1 value" : "\(content.rows.count) values"
        let place = drawer.scope == .all ? "for all statements" : "for this statement"
        return "\(count) \(place), bound, never written into the SQL"
    }

    private func notice(_ text: String, systemImage: String, identifier: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.orange)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: 20)
            .accessibilityIdentifier(identifier)
    }

    // MARK: Rows

    private func rows(_ drawer: SQLParameterDrawer, _ content: SQLParameterDrawerModel.Content) -> some View {
        let height = min(CGFloat(content.rows.count), Self.visibleRows) * Self.rowHeight
        let highlighted = drawer.note == nil ? nil : drawer.focusRequest?.key
        return ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(content.rows) { row in
                    rowView(row, drawer: drawer, namesStatements: content.namesStatements, highlighted: highlighted == row.id)
                        .id(row.id)
                }
            }
        }
        // Shrinks to one row when the editor's pane is short; the editor keeps the rest.
        .frame(minHeight: Self.rowHeight, maxHeight: height)
    }

    private func rowView(_ row: SQLParameterRow, drawer: SQLParameterDrawer, namesStatements: Bool, highlighted: Bool) -> some View {
        let placeholder = row.parameter.placeholder
        return HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(placeholder)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                Text(caption(row, namesStatements: namesStatements))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: 170, alignment: .leading)
            .help(row.label(namesStatements: namesStatements))
            Picker("Type of \(placeholder)", selection: Binding(get: { row.draft.type }, set: { type in
                edit(row, in: drawer) { $0.set(type: type) }
            })) {
                ForEach(SQLParameterType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 92)
            .accessibilityIdentifier("sql-parameter-type-\(placeholder)")
            control(row, drawer: drawer)
            status(row)
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .background(highlighted ? Color.orange.opacity(0.14) : Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sql-parameter-row-\(placeholder)")
    }

    @ViewBuilder
    private func control(_ row: SQLParameterRow, drawer: SQLParameterDrawer) -> some View {
        let placeholder = row.parameter.placeholder
        switch row.draft.type {
        case .boolean:
            Toggle(isOn: Binding(get: { row.draft.flag }, set: { flag in edit(row, in: drawer) { $0.flag = flag } })) {
                Text(row.draft.flag ? "true" : "false").font(.callout.monospaced())
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("sql-parameter-\(placeholder)")
        case .null:
            Text("NULL")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("sql-parameter-\(placeholder)")
        case .text, .integer, .decimal:
            TextField(placeholder, text: Binding(get: { row.draft.text }, set: { text in edit(row, in: drawer) { $0.text = text } }), prompt: Text(prompt(for: row)))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(row.draft.type == .text ? .callout : .callout.monospacedDigit())
                .autocorrectionDisabled()
                .focused($focused, equals: row.id)
                .onSubmit { model.runFromSQLParameterDrawer(tab) }
                .frame(minWidth: 80, maxWidth: .infinity)
                .accessibilityIdentifier("sql-parameter-\(placeholder)")
        }
    }

    /// What's wrong with a value, or where it came from.
    @ViewBuilder
    private func status(_ row: SQLParameterRow) -> some View {
        if row.isSet, let error = row.draft.error {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 170, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                .help(error)
                .accessibilityIdentifier("sql-parameter-error-\(row.parameter.placeholder)")
        } else if row.source == .preset {
            Text("@param")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().strokeBorder(Color.secondary.opacity(0.4)))
                .help("From a -- @param comment in the tab. A value you set here replaces it until you quit.")
        }
    }

    /// Changes the row's current value (not the one this view was drawn with). A field writes
    /// its text back when it gets the focus: that changes nothing, so a missing value stays
    /// missing until something is typed.
    private func edit(_ row: SQLParameterRow, in drawer: SQLParameterDrawer, _ change: (inout SQLParameterDraft) -> Void) {
        let current = drawer.content.rows.first { $0.id == row.id }?.draft ?? row.draft
        var draft = current
        change(&draft)
        guard draft != current else { return }
        drawer.set(row.id, draft: draft)
    }

    /// "line 3", "line 3 · used 2 times", or "statement 2 · line 7".
    private func caption(_ row: SQLParameterRow, namesStatements: Bool) -> String {
        if namesStatements, let statement = row.parameter.statement { return "statement \(statement + 1) · line \(row.parameter.line)" }
        return "line \(row.parameter.line)" + (row.parameter.uses > 1 ? " · used \(row.parameter.uses) times" : "")
    }

    private func prompt(for row: SQLParameterRow) -> String {
        switch row.draft.type {
        case .integer: return row.isSet ? "Whole number" : "Not set: a whole number"
        case .decimal: return row.isSet ? "Number, like 19.99" : "Not set: a number, like 19.99"
        default: return row.isSet ? "Empty string" : "Not set"
        }
    }
}
