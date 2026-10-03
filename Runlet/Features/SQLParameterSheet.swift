import RunletCore
import SwiftUI

/// The values sheet (#145): before a statement (or Run All script) with placeholders runs, one
/// row per `:name` (once, however often it is used) or `?`, each with a type and a value,
/// prefilled with the tab's last values or the text's `-- @param` presets. Run (↩) binds them;
/// Cancel (Esc) runs nothing.
struct SQLParameterSheet: View {
    @Environment(AppModel.self) private var model
    @Bindable var request: SQLParameterRequest
    @FocusState private var focused: SQLParameter.Key?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let preview = request.preview { statement(preview) }
            if !request.problems.isEmpty { problems }
            fields
            footer
        }
        .padding(20)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onExitCommand { model.cancelSQLParameters(request) }
        .accessibilityIdentifier("sql-parameters-sheet")
        .onAppear {
            focused = request.form.fields.first { $0.type != .boolean && $0.type != .null }?.id
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "curlybraces.square")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(request.title)
                    .font(.headline)
                Text(request.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    private func statement(_ text: String) -> some View {
        let preview = ProductionGrace.preview(of: text)
        return ScrollView {
            Text(preview.text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 110)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        .accessibilityIdentifier("sql-parameters-statement")
    }

    /// `-- @param` lines that couldn't be read, so nothing is ignored silently.
    private var problems: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(request.problems.count == 1 ? "One @param line could not be read:" : "\(request.problems.count) @param lines could not be read:",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
            ForEach(Array(request.problems.enumerated()), id: \.offset) { _, problem in
                Text(problem)
                    .font(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sql-parameters-problems")
    }

    private var fields: some View {
        ScrollView {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                ForEach($request.form.fields) { $field in
                    GridRow {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(field.parameter.placeholder)
                                .font(.body.monospaced().weight(.semibold))
                            Text(request.caption(for: field.parameter))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .gridColumnAlignment(.trailing)
                        .frame(minWidth: 90, alignment: .trailing)
                        Picker("Type of \(field.parameter.placeholder)", selection: $field.type) {
                            ForEach(SQLParameterType.allCases, id: \.self) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("sql-parameter-type-\(field.parameter.placeholder)")
                        VStack(alignment: .leading, spacing: 3) {
                            control($field)
                            if let error = shownError(field) {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .accessibilityIdentifier("sql-parameter-error-\(field.parameter.placeholder)")
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 340)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func control(_ field: Binding<SQLParameterForm.Field>) -> some View {
        let placeholder = field.wrappedValue.parameter.placeholder
        switch field.wrappedValue.type {
        case .boolean:
            Toggle(isOn: field.flag) {
                Text(field.wrappedValue.flag ? "true" : "false").font(.body.monospaced())
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("sql-parameter-\(placeholder)")
        case .null:
            Text("NULL")
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("sql-parameter-\(placeholder)")
        case .text, .integer, .decimal:
            TextField(placeholder, text: field.text, prompt: Text(prompt(for: field.wrappedValue.type)))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(field.wrappedValue.type == .text ? .body : .body.monospacedDigit())
                .autocorrectionDisabled()
                .focused($focused, equals: field.wrappedValue.id)
                .accessibilityIdentifier("sql-parameter-\(placeholder)")
        }
    }

    /// An empty number field just disables Run; what was typed is explained.
    private func shownError(_ field: SQLParameterForm.Field) -> String? {
        guard !field.text.isEmpty else { return nil }
        return request.form.error(for: field)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Label("Bound by the database driver, never written into the SQL.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Runlet sends the values apart from the statement and binds each with PDOStatement::bindValue and its type. The tab remembers them until you quit.")
            Spacer(minLength: 8)
            Button("Cancel", role: .cancel) { model.cancelSQLParameters(request) }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("sql-parameters-cancel")
            Button(request.actionTitle) { model.confirmSQLParameters(request) }
                .keyboardShortcut(.defaultAction)
                .disabled(!request.form.isValid)
                .accessibilityIdentifier("sql-parameters-run")
        }
    }

    private func prompt(for type: SQLParameterType) -> String {
        switch type {
        case .integer: "Whole number"
        case .decimal: "Number, like 19.99"
        default: "Text (empty is an empty string)"
        }
    }
}
