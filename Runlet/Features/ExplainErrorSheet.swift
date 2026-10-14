import AppKit
import RunletCore
import SwiftUI

/// Explain or Fix This Error's sheet (#44), in the window that asked. Closing it any way but
/// its buttons (Esc) closes the session and stops a request still streaming.
struct ExplainErrorSheetModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    let windowId: UUID

    func body(content: Content) -> some View {
        content.sheet(item: presented) { session in
            ExplainErrorSheet(session: session)
        }
    }

    private var presented: Binding<ExplainErrorSession?> {
        Binding(
            get: {
                guard let session = model.explainError, session.windowId == nil || session.windowId == windowId else { return nil }
                return session
            },
            set: { value in
                if value == nil, let session = model.explainError, session.windowId == nil || session.windowId == windowId {
                    model.closeExplainError()
                }
            }
        )
    }
}

/// A review step, then the answer, in one sheet (one sheet at a time per window): first exactly
/// what would be sent, part by part, with the provider and the model; then the streamed
/// explanation and, when the model proposes one, the fix as a diff with Apply Fix.
struct ExplainErrorSheet: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: ExplainErrorSession

    private var provider: AIProvider { session.disclosure.provider }
    private var modelName: String { model.aiModelName(provider, session.answeringModel ?? session.disclosure.model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch session.phase {
            case .review:
                review
            case .streaming, .finished, .failed:
                answer
            }
            footer
        }
        .padding(20)
        .frame(width: 620)
        .onExitCommand { model.closeExplainError() }
        .alert(item: $session.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("explain-error-sheet")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var title: String {
        switch session.phase {
        case .review: "Ask \(provider.displayName) about this error?"
        case .streaming: "Explaining the error…"
        case .finished: session.applied == nil ? "\(provider.displayName)'s explanation" : "Fix applied to “\(session.tabTitle)”"
        case .failed: "No answer"
        }
    }

    private var subtitle: String {
        switch session.phase {
        case .review:
            "Runlet sends only what's checked below, to \(provider.displayName)'s \(modelName), when you press Send. Nothing is sent before that, and nothing runs."
        case .streaming:
            "\(modelName) is answering. Stop ends the request."
        case .finished:
            session.applied == nil
                ? "\(modelName) answered. “\(session.tabTitle)” is unchanged unless you apply a fix."
                : "Nothing ran. Undo Apply Fix, or Edit ▸ Undo in the editor, puts the old code back."
        case .failed:
            session.error.map { "\($0.title). \($0.message)" } ?? "The request failed."
        }
    }

    // MARK: Review

    private var hasKey: Bool { model.hasAIKey(provider) }

    private var review: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !hasKey {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "key.slash").foregroundStyle(.orange)
                    Text("No \(provider.displayName) key is saved. Add one in Settings ▸ AI; Runlet keeps it in your Mac's Keychain.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Open AI Settings…") { model.perform("app.aiSettings", source: .button) }
                        .controlSize(.small)
                        .accessibilityIdentifier("explain-error-open-settings")
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("explain-error-no-key")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(session.disclosure.parts) { part in
                        partView(part)
                    }
                    DisclosureGroup("Instructions Runlet adds") {
                        codeBox(session.disclosure.instructions, maxHeight: 160)
                            .padding(.top, 4)
                    }
                    .font(.callout)
                    .accessibilityIdentifier("explain-error-instructions")
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: 420)
            Text("To \(provider.displayName) · \(session.disclosure.model) · \(session.disclosure.characterCount.formatted()) characters, billed to your \(provider.displayName) account")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("explain-error-destination")
        }
    }

    private func partView(_ part: AIDisclosurePart) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { part.isIncluded }, set: { model.setExplainErrorPart(part.id, included: $0) })) {
                Text(part.title)
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("explain-error-part-\(part.id)")
            codeBox(part.text, maxHeight: 150)
                .opacity(part.isIncluded ? 1 : 0.45)
            if let note = part.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if !part.isIncluded {
                Text("Not sent.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func codeBox(_ text: String, maxHeight: CGFloat) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    // MARK: Answer

    private var answer: some View {
        let parsed = session.answer
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if session.phase == .streaming, session.answerText.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(session.isThinking ? "Thinking…" : "Waiting for \(provider.displayName)…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("explain-error-waiting")
                    }
                    if let fallback = session.fallback {
                        Label("\(model.aiModelName(provider, fallback.from ?? session.disclosure.model)) declined, so \(provider.displayName) answered with \(model.aiModelName(provider, fallback.to ?? "another model")).", systemImage: "arrow.triangle.branch")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(parsed.blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                    if session.phase == .streaming, parsed.isWritingFix {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Writing a fix…").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if session.stopped {
                        Label("Stopped: the answer is incomplete.", systemImage: "stop.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if session.stopReason == .maxTokens {
                        Label("The answer reached its length limit and is cut off.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if session.phase == .finished, let fix = session.proposedFix {
                        fixView(fix)
                    } else if session.phase == .finished, !session.stopped, session.stopReason == .complete, parsed.fix == nil {
                        Text("No change to the tab's code was proposed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("explain-error-no-fix")
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.trailing, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 440)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: session.answerText) {
                if session.phase == .streaming { proxy.scrollTo("end", anchor: .bottom) }
            }
            .accessibilityIdentifier("explain-error-answer")
        }
    }

    @ViewBuilder
    private func blockView(_ block: AIAnswer.Block) -> some View {
        switch block {
        case .text(let text):
            Text(Self.markdown(text))
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .code(_, let code, _):
            codeBox(code, maxHeight: 200)
        case .fixMoved:
            Label("The proposed fix is below.", systemImage: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Inline Markdown (code, emphasis, links), keeping line breaks; lists and headings show as
    /// written.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private func fixView(_ fix: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Proposed fix").font(.callout.weight(.semibold))
                Text("for “\(session.tabTitle)”").font(.callout).foregroundStyle(.secondary)
                if session.applied != nil {
                    Label("Applied", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("explain-error-applied")
                }
            }
            LineDiffView(rows: LineDiff.rows(from: session.codeSent, to: fix))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("explain-error-fix")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            switch session.phase {
            case .review:
                Spacer()
                Button("Cancel", role: .cancel) { model.closeExplainError() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("explain-error-cancel")
                Button("Send to \(provider.displayName)") { model.sendExplainError() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.disclosure.isEmpty || !hasKey)
                    .accessibilityIdentifier("explain-error-send")
            case .streaming:
                Text("To \(provider.displayName) · \(session.disclosure.model)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { model.stopExplainError() }
                    .keyboardShortcut(".", modifiers: .command)
                    .accessibilityIdentifier("explain-error-stop")
            case .finished:
                Button(session.copied ? "Copied" : "Copy Answer") { model.copyExplainErrorAnswer() }
                    .accessibilityIdentifier("explain-error-copy")
                Button("Ask Again…") { model.reviewExplainError() }
                    .accessibilityIdentifier("explain-error-review")
                Spacer()
                if session.proposedFix != nil {
                    if session.applied == nil {
                        Text("Nothing runs. ⌘Z undoes it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Done", role: .cancel) { model.closeExplainError() }
                            .keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("explain-error-done")
                        Button("Apply Fix") { model.applyExplainErrorFix() }
                            .keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("explain-error-apply")
                    } else {
                        Button("Undo Apply Fix") { model.undoExplainErrorFix() }
                            .accessibilityIdentifier("explain-error-undo")
                        Button("Done") { model.closeExplainError() }
                            .keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("explain-error-done")
                    }
                } else {
                    Button("Done") { model.closeExplainError() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("explain-error-done")
                }
            case .failed:
                Button("Edit Request…") { model.reviewExplainError() }
                    .accessibilityIdentifier("explain-error-review")
                if session.error?.opensSettings == true {
                    Button("Open AI Settings…") { model.perform("app.aiSettings", source: .button) }
                        .accessibilityIdentifier("explain-error-open-settings")
                }
                Spacer()
                Button("Done", role: .cancel) { model.closeExplainError() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("explain-error-done")
                Button("Try Again") { model.sendExplainError() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasKey || session.disclosure.isEmpty)
                    .accessibilityIdentifier("explain-error-retry")
            }
        }
    }
}

/// A diff of the tab's code and a proposed change (#44): removed lines red, added lines green,
/// with their line numbers, and unchanged stretches folded.
struct LineDiffView: View {
    let rows: [LineDiff.Row]

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    rowView(row)
                }
            }
            .padding(.vertical, 4)
            // At least the sheet's width, so a changed line's color spans the box.
            .frame(minWidth: 580, alignment: .leading)
        }
        .frame(maxHeight: 240)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        .accessibilityIdentifier("explain-error-diff")
    }

    @ViewBuilder
    private func rowView(_ row: LineDiff.Row) -> some View {
        switch row {
        case .gap(let count):
            Text(count == 1 ? "⋯ 1 unchanged line" : "⋯ \(count) unchanged lines")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
        case .line(let change, let old, let new):
            let (sign, text, tint): (String, String, Color?) = switch change {
            case .same(let text): (" ", text, nil)
            case .removed(let text): ("−", text, .red)
            case .added(let text): ("+", text, .green)
            }
            HStack(spacing: 6) {
                Text(old.map(String.init) ?? "").frame(width: 28, alignment: .trailing).foregroundStyle(.tertiary)
                Text(new.map(String.init) ?? "").frame(width: 28, alignment: .trailing).foregroundStyle(.tertiary)
                Text(sign).foregroundStyle(tint ?? .secondary)
                Text(text.isEmpty ? " " : text)
                    .fixedSize(horizontal: true, vertical: false)
                    .textSelection(.enabled)
            }
            .font(.system(.caption, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((tint ?? .clear).opacity(0.14))
        }
    }
}
