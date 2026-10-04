import RunletCore
import SwiftUI

/// The form a parameterised snippet shows before it opens (#14): one field per `@input`, with
/// its label, a control for its type, its default, and validation. Open puts the values at the
/// top of the code as PHP literals; Cancel opens nothing. Nothing runs either way.
struct SnippetInputSheet: View {
    @Environment(AppModel.self) private var model
    @Bindable var request: SnippetInputRequest
    @FocusState private var focused: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !request.problems.isEmpty { problems }
            if !request.form.inputs.isEmpty {
                fields
                preview
            }
            footer
        }
        .padding(20)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("snippet-inputs-sheet")
        .onAppear {
            focused = request.form.inputs.first { $0.choices.isEmpty && $0.kind != .bool }?.name
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(request.title)
                    .font(.headline)
                    .lineLimit(2)
                if let summary = request.summary {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(request.source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    /// Declarations that could not be read, so nothing fails silently.
    private var problems: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(request.problems.count == 1 ? "One @input line could not be read and is left out:" : "\(request.problems.count) @input lines could not be read and are left out:",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
            ForEach(Array(request.problems.enumerated()), id: \.offset) { _, problem in
                Text(problem.description)
                    .font(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("snippet-inputs-problems")
    }

    private var fields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            ForEach(request.form.inputs, id: \.name) { input in
                GridRow {
                    Text(input.label)
                        .gridColumnAlignment(.trailing)
                        .lineLimit(2)
                        .frame(maxWidth: 150, alignment: .trailing)
                        .help("$\(input.name)")
                    VStack(alignment: .leading, spacing: 3) {
                        control(for: input)
                        caption(for: input)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func control(for input: SnippetInput) -> some View {
        if !input.choices.isEmpty {
            Picker(input.label, selection: selection(input)) {
                ForEach(Array(input.choices.enumerated()), id: \.offset) { index, choice in
                    Text(choice.editableText).tag(index)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("snippet-input-\(input.name)")
        } else if input.kind == .bool {
            Toggle(isOn: flag(input)) {
                Text(request.form.flags[input.name] == true ? "true" : "false")
                    .font(.body.monospaced())
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("snippet-input-\(input.name)")
        } else {
            TextField(input.label, text: text(input), prompt: Text(prompt(for: input.kind)))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(input.kind == .string ? .body : .body.monospacedDigit())
                .autocorrectionDisabled()
                .focused($focused, equals: input.name)
                .accessibilityIdentifier("snippet-input-\(input.name)")
        }
    }

    @ViewBuilder
    private func caption(for input: SnippetInput) -> some View {
        // An empty number field just disables Open; what was typed is explained.
        if !(request.form.texts[input.name] ?? "").isEmpty, let error = request.form.error(for: input) {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityIdentifier("snippet-input-error-\(input.name)")
        } else {
            Text("$\(input.name) · \(input.kind.rawValue)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    /// #207: a MongoDB snippet's placeholders and the JSON they become.
    private var mongoAssignments: [String] {
        request.form.inputs.map { input in
            guard case .success(let value) = request.form.value(of: input) else { return "{\"$input\": \"\(input.name)\"} → …" }
            return "{\"$input\": \"\(input.name)\"} → " + MongoSnippets.jsonLiteral(value)
        }
    }

    /// The PHP the values become, as they will appear in the code.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(request.language == .mongodb ? "Fill the query's {\"$input\": \"…\"} placeholders as JSON values:" : "Inserted at the top of the code as PHP literals:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text((request.language == .mongodb ? mongoAssignments : request.form.assignments).joined(separator: "\n"))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.25)))
                .accessibilityIdentifier("snippet-inputs-preview")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Label("Nothing runs: you can check the code first.", systemImage: "play.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Cancel", role: .cancel) { model.cancelSnippetInputs(request) }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("snippet-inputs-cancel")
            Button(request.actionTitle) { model.confirmSnippetInputs(request) }
                .keyboardShortcut(.defaultAction)
                .disabled(!request.form.isValid)
                .accessibilityIdentifier("snippet-inputs-open")
        }
    }

    private func prompt(for kind: SnippetInput.Kind) -> String {
        switch kind {
        case .int: "Whole number"
        case .float: "Number"
        case .string, .bool: "Text"
        }
    }

    private func text(_ input: SnippetInput) -> Binding<String> {
        Binding(get: { request.form.texts[input.name] ?? "" }, set: { request.form.texts[input.name] = $0 })
    }

    private func flag(_ input: SnippetInput) -> Binding<Bool> {
        Binding(get: { request.form.flags[input.name] ?? false }, set: { request.form.flags[input.name] = $0 })
    }

    private func selection(_ input: SnippetInput) -> Binding<Int> {
        Binding(get: { request.form.selections[input.name] ?? 0 }, set: { request.form.selections[input.name] = $0 })
    }
}

/// Shows that a snippet asks for inputs (or has `@input` lines that can't be read) in the
/// Snippets panel.
struct SnippetInputsBadge: View {
    let inputs: SnippetInputSet

    var body: some View {
        if !inputs.inputs.isEmpty {
            Label(inputs.inputs.count == 1 ? "1 input" : "\(inputs.inputs.count) inputs", systemImage: "slider.horizontal.3")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.purple)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.purple.opacity(0.12)))
                .help("Asks for " + inputs.inputs.map { "$\($0.name) (\($0.kind.rawValue))" }.joined(separator: ", ") + " before it opens. Nothing runs.")
                .accessibilityIdentifier("snippet-inputs-badge")
        }
        if !inputs.problems.isEmpty {
            Label(inputs.problems.count == 1 ? "1 input problem" : "\(inputs.problems.count) input problems", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.orange.opacity(0.12)))
                .help(inputs.problems.map(\.description).joined(separator: "\n"))
                .accessibilityIdentifier("snippet-input-problems-badge")
        }
    }
}
