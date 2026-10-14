import AppKit
import RunletCore
import SwiftUI

/// The AI chat (#45), a pane of the trailing column next to History, Snippets, Commands, and
/// Database: the window's conversation, then the next message with exactly what goes with it.
/// Nothing is sent until Send, and code from an answer goes into a tab only on Insert into Tab.
struct AIChatPane: View {
    @Environment(AppModel.self) private var model
    let window: WindowModel

    var body: some View {
        let session = window.chat
        VStack(spacing: 0) {
            header(session)
            Divider()
            AIChatTranscript(window: window, session: session, live: session.live)
                .frame(maxHeight: .infinity)
            Divider()
            AIChatComposer(window: window, session: session)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-pane")
        .onAppear {
            model.refreshAIKeyStates()
            model.chatDraftChanged(in: window)
        }
        .onChange(of: window.selectedTab?.id) { model.chatDraftChanged(in: window) }
    }

    private func header(_ session: AIChatSession) -> some View {
        let answered = session.conversation.turns.count
        return HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(answered == 0 ? "New conversation" : answered == 1 ? "1 message" : "\(answered) messages")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("This window's conversation. Runlet keeps it while it runs, never on disk.")
                .accessibilityIdentifier("chat-title")
            Spacer(minLength: 4)
            Button {
                model.perform("app.aiSettings", source: .button, in: window)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("AI Settings…: the provider, its key, and the model")
            .accessibilityLabel("AI Settings…")
            .accessibilityIdentifier("chat-settings")
            Button {
                model.perform("library.chatNew", source: .button, in: window)
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .disabled(session.conversation.isEmpty)
            .help(model.commandHelp("New Conversation", "library.chatNew", detail: "clears this one. Runlet doesn't keep conversations"))
            .accessibilityLabel("New Conversation")
            .accessibilityIdentifier("chat-new")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: The conversation

private struct AIChatTranscript: View {
    let window: WindowModel
    let session: AIChatSession
    let live: AIChatLiveAnswer

    var body: some View {
        if session.conversation.isEmpty {
            ContentUnavailableView {
                Label("Ask About Your Code", systemImage: "bubble.left.and.text.bubble.right")
            } description: {
                Text("Ask about the tab's code, its output, or a project file: type @ and its name. You see what Runlet sends before it sends it, and nothing that comes back runs on its own.")
            }
            .accessibilityIdentifier("chat-empty")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(session.conversation.turns.enumerated()), id: \.element.id) { index, turn in
                            AIChatTurnView(window: window, session: session, turn: turn, number: index + 1,
                                           isLast: index == session.conversation.turns.count - 1)
                        }
                        Color.clear.frame(height: 1).id("chat-end")
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("chat-transcript")
                .onAppear { proxy.scrollTo("chat-end", anchor: .bottom) }
                .onChange(of: session.conversation.turns.count) { proxy.scrollTo("chat-end", anchor: .bottom) }
                .onChange(of: live.text) {
                    if live.turnId != nil { proxy.scrollTo("chat-end", anchor: .bottom) }
                }
            }
        }
    }
}

/// One exchange: the message as typed, what went with it, and the answer.
private struct AIChatTurnView: View {
    @Environment(AppModel.self) private var model
    let window: WindowModel
    let session: AIChatSession
    let turn: AIChatTurn
    let number: Int
    let isLast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            question
            if turn.isStreaming {
                AIChatLiveAnswerView(window: window, session: session, live: session.live, turn: turn, number: number)
            } else {
                AIChatAnswerView(window: window, session: session, turn: turn, text: turn.answer, answeringModel: turn.answeringModel,
                                 fallback: (turn.fallbackFrom, turn.fallbackTo), isThinking: false, number: number, isLast: isLast)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-turn-\(number)")
    }

    private var question: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(turn.question)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !turn.context.isEmpty {
                Label(turn.context.joined(separator: " · "), systemImage: "paperclip")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("Sent with the message")
            }
            AIChatExpandable(session: session, key: "sent-\(turn.id)", title: "What was sent", identifier: "chat-sent-\(number)") {
                AIChatTextBox(text: turn.sent, maxHeight: 180)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.1)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-question-\(number)")
    }
}

/// The answer while it arrives: only this view follows the stream.
private struct AIChatLiveAnswerView: View {
    let window: WindowModel
    let session: AIChatSession
    let live: AIChatLiveAnswer
    let turn: AIChatTurn
    let number: Int

    var body: some View {
        AIChatAnswerView(window: window, session: session, turn: turn, text: live.text, answeringModel: live.answeringModel,
                         fallback: (live.fallbackFrom, live.fallbackTo), isThinking: live.isThinking, number: number, isLast: true)
    }
}

private struct AIChatAnswerView: View {
    @Environment(AppModel.self) private var model
    let window: WindowModel
    let session: AIChatSession
    let turn: AIChatTurn
    let text: String
    let answeringModel: String?
    let fallback: (from: String?, to: String?)
    let isThinking: Bool
    let number: Int
    let isLast: Bool

    private var provider: AIProvider { turn.provider }

    /// "Anthropic · Claude Opus 5.5 · effort high": who wrote it, and how hard it thought.
    private var writtenBy: String {
        let id = answeringModel ?? turn.model
        var label = "\(provider.displayName) · \(model.aiModelName(provider, id))"
        if !AIModelTraits.effortLevels(provider, turn.model).isEmpty {
            label += " · " + (turn.effort.map { "effort \($0.rawValue)" } ?? "default effort")
        }
        return label
    }

    var body: some View {
        let parsed = AIAnswer.parse(text, extractingFix: false)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(writtenBy)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .help("Written by \(provider.displayName)'s \(answeringModel ?? turn.model)")
                    .accessibilityIdentifier("chat-answer-model-\(number)")
                Spacer(minLength: 4)
                if !turn.isStreaming, !text.isEmpty {
                    Button(session.copied == "answer-\(turn.id)" ? "Copied" : "Copy") {
                        model.copyChatText(text, key: "answer-\(turn.id)", in: window)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Copy: the whole answer, as Markdown")
                    .accessibilityIdentifier("chat-copy-\(number)")
                }
            }
            if let to = fallback.to {
                Label("\(model.aiModelName(provider, fallback.from ?? turn.model)) declined, so \(provider.displayName) answered with \(model.aiModelName(provider, to)).",
                      systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if turn.isStreaming, text.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(isThinking ? "Thinking…" : "Waiting for \(provider.displayName)…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("chat-waiting")
            }
            ForEach(Array(parsed.blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .text(let text):
                    Text(ExplainErrorSheet.markdown(text))
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let language, let code, let isOpen):
                    AIChatCodeBlock(window: window, session: session, language: language, code: code, isOpen: isOpen, key: "\(number)-\(index + 1)")
                case .fixMoved:
                    EmptyView()
                }
            }
            state
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-answer-\(number)")
    }

    @ViewBuilder
    private var state: some View {
        switch turn.state {
        case .streaming, .complete:
            EmptyView()
        case .stopped:
            Label(text.isEmpty ? "Stopped before an answer arrived. This message isn't sent again." : "Stopped: the answer is incomplete.", systemImage: "stop.circle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .cutOff:
            Label("The answer reached its length limit and is cut off.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let error):
            VStack(alignment: .leading, spacing: 4) {
                Label(error.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                Text(error.message + " This message isn't sent again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    if isLast {
                        Button("Try Again") { model.retryChat(turn.id, in: window) }
                            .disabled(!model.hasAIKey(provider))
                            .help("Try Again: sends the same message, with the same context, again")
                            .accessibilityIdentifier("chat-retry")
                    }
                    if error.opensSettings {
                        Button("Open AI Settings…") { model.perform("app.aiSettings", source: .button, in: window) }
                            .accessibilityIdentifier("chat-error-open-settings")
                    }
                }
                .controlSize(.small)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat-error-\(number)")
        }
    }
}

/// A code block of an answer, with Copy and Insert into Tab.
private struct AIChatCodeBlock: View {
    @Environment(AppModel.self) private var model
    let window: WindowModel
    let session: AIChatSession
    let language: String?
    let code: String
    /// Still being written.
    let isOpen: Bool
    /// "<turn>-<block>", 1-based.
    let key: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(AIChatInsertion.displayLanguage(language) ?? "code")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button(session.copied == key ? "Copied" : "Copy") { model.copyChatText(code, key: key, in: window) }
                    .help("Copy: the code, to paste anywhere")
                    .accessibilityIdentifier("chat-code-copy-\(key)")
                Button(session.inserted == key ? "Inserted" : "Insert into Tab") {
                    session.insertRequest = (key, code)
                    model.perform("library.chatInsert", source: .button, in: window)
                    session.insertRequest = nil
                }
                .disabled(isOpen || window.selectedTab == nil)
                .help(model.commandHelp("Insert into Tab", "library.chatInsert",
                                        detail: "puts the code at the cursor in “\(window.selectedTab?.title ?? "the tab")”, or over its selection. Nothing runs, and ⌘Z undoes it"))
                .accessibilityIdentifier("chat-code-insert-\(key)")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Divider()
            ScrollView(.horizontal) {
                Text(code.isEmpty ? " " : code)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(8)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-code-\(key)")
    }
}

// MARK: The next message

private struct AIChatComposer: View {
    @Environment(AppModel.self) private var model
    let window: WindowModel
    @Bindable var session: AIChatSession
    @State private var fieldHeight: CGFloat = 36

    var body: some View {
        let draft = model.chatDraft(in: window)
        let provider = draft.disclosure.provider
        let hasKey = model.hasAIKey(provider)
        let suggestions = model.chatSuggestions(in: window)
        VStack(alignment: .leading, spacing: 8) {
            if !hasKey {
                AIMissingKeyNotice(provider: provider, identifier: "chat", compact: true, window: window)
            }
            context(draft)
            if let from = draft.switchedFrom, !draft.disclosure.history.isEmpty, !session.isStreaming {
                switchNote(draft, from: from)
            }
            if let suggestions {
                suggestionList(suggestions.paths)
            }
            field(suggestions: suggestions?.paths ?? [])
            if model.chatDestination != nil {
                pickers
            }
            footer(draft, hasKey: hasKey)
            // Without any key the notice above says it all.
            if let problem = draft.problem, problem != "Type a message.", !session.isStreaming, model.chatDestination != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if draft.overflow != nil, draft.canLeaveOutAttachments {
                        Button("Leave Out Earlier Attachments") { model.leaveOutChatAttachments(in: window) }
                            .controlSize(.small)
                            .help("Leave Out Earlier Attachments: later messages send the earlier messages without the code, output, and files that went with them, oldest first, until the conversation fits. The answers stay. Nothing is sent now.")
                            .accessibilityIdentifier("chat-leave-out")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("chat-problem")
            }
        }
        .padding(10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-composer")
    }

    // MARK: What's sent

    private func context(_ draft: AIChatDraft) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                Text("Sent with the message")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(draft.contextParts) { part in
                    contextRow(part)
                }
                ForEach(draft.unavailableFiles, id: \.path) { file in
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "xmark.circle").foregroundStyle(.orange)
                        Text("\(file.path) isn't sent. \(file.reason)")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("chat-file-unavailable-\(file.path)")
                }
                if draft.contextParts.isEmpty, draft.unavailableFiles.isEmpty {
                    Text(window.selectedTab == nil ? "Only the message." : "Only the message: the tab is empty and has no output.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                history(draft)
                AIChatExpandable(session: session, key: "instructions", title: "Instructions Runlet adds", identifier: "chat-instructions") {
                    AIChatTextBox(text: draft.disclosure.instructions, maxHeight: 140)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 240)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("chat-context")
    }

    private func contextRow(_ part: AIDisclosurePart) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Toggle(isOn: Binding(get: { part.isIncluded }, set: { model.setChatContext(part.id, included: $0, in: window) })) {
                    Text(part.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .toggleStyle(.checkbox)
                .font(.caption)
                .help(part.title)
                .accessibilityIdentifier("chat-context-\(part.id)")
                Spacer(minLength: 4)
                Text(part.text.count.formatted(.number.notation(.compactName)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .help("\(part.text.count.formatted()) characters")
                expandButton(key: part.id, identifier: "chat-context-show-\(part.id)")
            }
            if session.expanded.contains(part.id) {
                AIChatTextBox(text: part.text, maxHeight: 160)
                    .opacity(part.isIncluded ? 1 : 0.45)
            }
            if let note = part.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
        }
    }

    @ViewBuilder
    private func history(_ draft: AIChatDraft) -> some View {
        let messages = draft.disclosure.history
        if !messages.isEmpty || draft.turnsNotSentAgain > 0 {
            let characters = messages.reduce(0) { $0 + $1.text.count }
            let answered = messages.count / 2
            AIChatExpandable(session: session, key: "history",
                             title: answered == 0 ? "No earlier messages" : answered == 1 ? "The earlier message and its answer (\(characters.formatted()) characters)" : "\(answered) earlier messages and their answers (\(characters.formatted()) characters)",
                             identifier: "chat-history") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                        Text(message.role == .user ? "Message" : "Answer")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        AIChatTextBox(text: message.text, maxHeight: 120)
                    }
                }
            }
            if draft.turnsNotSentAgain > 0 {
                Text(draft.turnsNotSentAgain == 1 ? "1 earlier message without an answer isn't sent again." : "\(draft.turnsNotSentAgain) earlier messages without an answer aren't sent again.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func expandButton(key: String, identifier: String) -> some View {
        let expanded = session.expanded.contains(key)
        return Button {
            if expanded { session.expanded.remove(key) } else { session.expanded.insert(key) }
        } label: {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.caption2)
                .frame(width: 12)
        }
        .buttonStyle(.borderless)
        .help(expanded ? "Hide the text" : "Show exactly the text Runlet sends")
        .accessibilityLabel(expanded ? "Hide the Text" : "Show the Text")
        .accessibilityIdentifier(identifier)
    }

    /// The first message after a switch sends the whole conversation to a model that hasn't
    /// read it.
    private func switchNote(_ draft: AIChatDraft, from: AIChatDestination) -> some View {
        let to = draft.disclosure
        let answered = to.history.count / 2
        let characters = draft.historyCharacters
        let fromName = from.provider == to.provider ? model.aiModelName(from.provider, from.model) : "\(from.provider.displayName)'s \(model.aiModelName(from.provider, from.model))"
        return Label {
            Text("The whole conversation goes to \(to.provider.displayName)'s \(model.aiModelName(to.provider, to.model)) with this message: \(answered == 1 ? "the earlier message and its answer" : "\(answered) earlier messages and their answers"), \(characters.formatted()) characters (about \(AIModelTraits.estimatedTokens(characters: characters).formatted()) tokens). It reads them again, and they're billed again: nothing carries over from \(fromName).")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "arrow.triangle.swap").foregroundStyle(.tint)
        }
        .font(.caption)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.1)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat-switch")
    }

    // MARK: Provider, model, and reasoning

    /// Where the next message goes, always on screen: the provider and model, and the reasoning
    /// level when the model takes one. Each opens its picker.
    private var pickers: some View {
        let destination = model.chatDestination
        return HStack(spacing: 10) {
            if let destination {
                Button {
                    session.picker = session.picker == .model ? nil : .model
                } label: {
                    HStack(spacing: 3) {
                        Text("\(destination.provider.displayName) · \(model.aiModelName(destination.provider, destination.model))")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                    }
                }
                .buttonStyle(.borderless)
                .help(model.commandHelp("Choose Chat Model", "library.chatChooseModel", detail: "the provider and model the next message goes to"))
                .accessibilityLabel("Chat Model: \(destination.provider.displayName), \(destination.model)")
                .accessibilityIdentifier("chat-model-picker")
                .popover(isPresented: pickerBinding(.model), arrowEdge: .top) {
                    AIChatModelPopover(window: window, session: session)
                }
                if !destination.effortLevels.isEmpty {
                    Button {
                        session.picker = session.picker == .effort ? nil : .effort
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "gauge.with.dots.needle.50percent")
                            Text(destination.effort?.displayName ?? "Default")
                            Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                        }
                    }
                    .buttonStyle(.borderless)
                    .help(model.commandHelp("Choose Chat Reasoning", "library.chatChooseReasoning", detail: "how hard the model thinks before it answers"))
                    .accessibilityLabel("Reasoning: \(destination.effort?.displayName ?? "Default")")
                    .accessibilityIdentifier("chat-effort-picker")
                    .popover(isPresented: pickerBinding(.effort), arrowEdge: .top) {
                        AIChatEffortPopover(window: window, session: session)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func pickerBinding(_ picker: AIChatPicker) -> Binding<Bool> {
        Binding(get: { session.picker == picker }, set: { if !$0, session.picker == picker { session.picker = nil } })
    }

    // MARK: @ suggestions

    private func suggestionList(_ paths: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(paths.enumerated()), id: \.element) { index, path in
                Button {
                    model.acceptChatSuggestion(path, in: window)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        Text(path)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(index == min(session.suggestion, paths.count - 1) ? Color.accentColor.opacity(0.2) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat-suggestion-\(index)")
            }
            Text("↑↓ choose · Tab or ↩ adds · Esc closes")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.top, 3)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-suggestions")
    }

    // MARK: The field

    private func field(suggestions: [String]) -> some View {
        ZStack(alignment: .topLeading) {
            AIChatMessageField(text: $session.draft, cursor: $session.cursor, height: $fieldHeight, suggestionsShown: !suggestions.isEmpty,
                               onSend: { model.perform("library.chatSend", source: .keyboard, in: window) },
                               onMove: { delta in
                                   session.suggestion = max(0, min(suggestions.count - 1, session.suggestion + delta))
                               },
                               onAccept: {
                                   guard !suggestions.isEmpty else { return }
                                   model.acceptChatSuggestion(suggestions[min(session.suggestion, suggestions.count - 1)], in: window)
                               },
                               onDismiss: {
                                   session.dismissedMention = AIChatMentions.active(in: session.draft, cursor: session.cursor)?.range.location
                               },
                               onEscape: { model.focusSelectedEditor() },
                               onChange: { model.chatDraftChanged(in: window) })
                .frame(height: fieldHeight)
            if session.draft.isEmpty {
                Text(model.chatProjectRoot(in: window) == nil ? "Ask about the tab's code (⌘↩ sends)" : "Ask about the tab's code; @ adds a file (⌘↩ sends)")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.leading, 5)
                    .padding(.top, 2)
                    .allowsHitTesting(false)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
    }

    private func footer(_ draft: AIChatDraft, hasKey: Bool) -> some View {
        let provider = draft.disclosure.provider
        return HStack(spacing: 6) {
            Button {
                model.beginChatMention(in: window)
            } label: {
                Image(systemName: "at")
            }
            .buttonStyle(.borderless)
            .disabled(model.chatProjectRoot(in: window) == nil)
            .help(model.chatProjectRoot(in: window) == nil ? "Add File: @ files come from the tab's project folder, and this tab has none" : "Add File: starts an @ mention; the file's text goes with the message")
            .accessibilityLabel("Add File")
            .accessibilityIdentifier("chat-add-file")
            Text("To \(provider.displayName) · \(AIChatDestination.label(model: draft.disclosure.model, provider: provider, effort: draft.disclosure.effort)) · \(draft.disclosure.characterCount.formatted()) characters")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help("To \(provider.displayName)'s \(draft.disclosure.model): the instructions, the earlier messages, and this one with what's checked above, billed to your \(provider.displayName) account. Nothing is sent before you press Send.")
                .accessibilityIdentifier("chat-destination")
            Spacer(minLength: 4)
            if session.isStreaming {
                Button("Stop") { model.perform("library.chatStop", source: .button, in: window) }
                    .help(model.commandHelp("Stop", "run.stop", detail: "ends the answer; what arrived stays"))
                    .accessibilityIdentifier("chat-stop")
            } else {
                Button("Send") { model.perform("library.chatSend", source: .button, in: window) }
                    .disabled(!draft.canSend || !hasKey)
                    .help("Send: the message, and what's checked above, to \(provider.displayName). ⌘↩ in the message sends too.")
                    .accessibilityIdentifier("chat-send")
            }
        }
        .controlSize(.small)
    }
}

// MARK: The pickers

/// The chat's provider and model (#45): providers without a key show, unavailable, with how to
/// add one; the models are Settings ▸ AI's list for the provider. The choice is the chat's own:
/// Settings ▸ AI stays as it is.
private struct AIChatModelPopover: View {
    @Environment(AppModel.self) private var model
    let window: WindowModel
    let session: AIChatSession

    var body: some View {
        let destination = model.chatDestination
        let choices = AIChatDestination.choices(configured: model.configuredAIProviders)
        VStack(alignment: .leading, spacing: 8) {
            Text("Chat With").font(.headline)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(choices, id: \.provider) { choice in
                    AIChatPickerRow(title: choice.provider.displayName, detail: choice.unavailable, isSelected: destination?.provider == choice.provider,
                                    identifier: "chat-provider-\(choice.provider.rawValue)") {
                        model.perform(choice.provider == .anthropic ? "library.chatWithAnthropic" : "library.chatWithOpenAI", source: .button, in: window)
                    }
                    .disabled(choice.unavailable != nil)
                }
            }
            if let destination {
                Divider()
                Text("\(destination.provider.displayName) Models")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(model.chatModelChoices(destination.provider)) { info in
                            AIChatPickerRow(title: info.displayName, detail: info.displayName == info.id ? nil : info.id, isSelected: info.id == destination.model,
                                            identifier: "chat-model-\(info.id)") {
                                model.setChatModel(info.id)
                                session.picker = nil
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack(alignment: .top, spacing: 8) {
                Text(choices.contains { $0.unavailable != nil }
                     ? "Only providers with a key in Settings ▸ AI can be chosen."
                     : "The chat's own choice: Settings ▸ AI stays as it is. Test Key there lists your account's models.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Open AI Settings…") {
                    session.picker = nil
                    model.perform("app.aiSettings", source: .button, in: window)
                }
                .controlSize(.small)
                .accessibilityIdentifier("chat-picker-open-settings")
            }
        }
        .padding(12)
        .frame(width: 320)
        .onExitCommand { session.picker = nil }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-model-popover")
    }
}

/// The chat's reasoning level (#45): Default, which sends none, and the levels the model takes.
private struct AIChatEffortPopover: View {
    @Environment(AppModel.self) private var model
    let window: WindowModel
    let session: AIChatSession

    var body: some View {
        if let destination = model.chatDestination {
            VStack(alignment: .leading, spacing: 8) {
                Text("Reasoning").font(.headline)
                Text("How hard \(model.aiModelName(destination.provider, destination.model)) thinks before it answers. Higher levels take longer and cost more.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 1) {
                    AIChatPickerRow(title: "Default", detail: "The model's own", isSelected: destination.effort == nil,
                                    identifier: "chat-effort-default") {
                        model.setChatEffort(.modelDefault)
                        session.picker = nil
                    }
                    ForEach(destination.effortLevels, id: \.self) { level in
                        AIChatPickerRow(title: level.displayName, detail: level.rawValue, isSelected: destination.effort == level,
                                        identifier: "chat-effort-\(level.rawValue)") {
                            model.setChatEffort(.level(level))
                            session.picker = nil
                        }
                    }
                }
                Divider()
                Text("Applies to the next message. Settings ▸ AI sets the default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(width: 280)
            .onExitCommand { session.picker = nil }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat-effort-popover")
        }
    }
}

/// A choice in a picker popover: a checkmark when chosen, and a detail on the right.
private struct AIChatPickerRow: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let detail: String?
    let isSelected: Bool
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 12)
                Text(title)
                    .font(.callout)
                    .foregroundStyle(isEnabled ? .primary : .secondary)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 4).fill(isSelected ? Color.accentColor.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

// MARK: Pieces

/// A row that opens to show more, its state on the model (so steps can open it).
private struct AIChatExpandable<Content: View>: View {
    let session: AIChatSession
    let key: String
    let title: String
    let identifier: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        let expanded = session.expanded.contains(key)
        VStack(alignment: .leading, spacing: 3) {
            Button {
                if expanded { session.expanded.remove(key) } else { session.expanded.insert(key) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .frame(width: 12)
                    Text(title)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)
            if expanded { content() }
        }
    }
}

/// Exact text as sent: monospaced, selectable, and scrolling past `maxHeight`.
private struct AIChatTextBox: View {
    let text: String
    let maxHeight: CGFloat

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text.isEmpty ? " " : text)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        }
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }
}

// MARK: The message field

/// The chat's message field (#45), AppKit-backed so its keys work before the text view uses
/// them: ⌘↩ sends; while `@` suggestions show, ↑/↓ choose one, Tab or ↩ adds it, and Esc
/// closes them; otherwise ↩ starts a new line, and Esc gives the keyboard back to the editor.
struct AIChatMessageField: NSViewRepresentable {
    @Binding var text: String
    @Binding var cursor: Int
    @Binding var height: CGFloat
    var suggestionsShown: Bool
    var onSend: () -> Void
    var onMove: (Int) -> Void
    var onAccept: () -> Void
    var onDismiss: () -> Void
    var onEscape: () -> Void
    var onChange: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let textView = AIChatMessageTextView()
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        // Code and paths: no predictions or Writing Tools over what's typed (as in the editor).
        textView.inlinePredictionType = .no
        textView.writingToolsBehavior = .none
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 5
        textView.delegate = context.coordinator
        textView.setAccessibilityIdentifier("chat-message")
        textView.setAccessibilityLabel("Message")
        textView.string = text
        textView.onCommandReturn = { [weak coordinator = context.coordinator] in coordinator?.parent.onSend() }
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? AIChatMessageTextView else { return }
        if textView.string != text {
            // Set from the model (a completed mention, a sent message, a debug step).
            context.coordinator.isUpdating = true
            textView.string = text
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(max(0, cursor), length), length: 0))
            context.coordinator.isUpdating = false
            context.coordinator.updateHeight(textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AIChatMessageField
        var isUpdating = false

        init(_ parent: AIChatMessageField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.cursor = textView.selectedRange().location
            updateHeight(textView)
            parent.onChange()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }
            let location = textView.selectedRange().location
            guard parent.cursor != location else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.parent.cursor = location
                self.parent.onChange()
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if parent.suggestionsShown {
                switch selector {
                case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
                case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
                case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertNewline(_:)): parent.onAccept()
                case #selector(NSResponder.cancelOperation(_:)): parent.onDismiss()
                default: return false
                }
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onEscape()
                return true
            }
            return false
        }

        /// One line to about seven, then it scrolls.
        func updateHeight(_ textView: NSTextView) {
            guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height + textView.textContainerInset.height * 2
            let height = min(120, max(20, ceil(used)))
            guard abs(height - parent.height) > 0.5 else { return }
            DispatchQueue.main.async { [weak self] in self?.parent.height = height }
        }
    }
}

/// The message field's text view: ⌘↩ sends while it has the keyboard, and Show Chat's focus
/// request gives it the keyboard.
final class AIChatMessageTextView: NSTextView {
    var onCommandReturn: (() -> Void)?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        NotificationCenter.default.addObserver(self, selector: #selector(focusRequested(_:)), name: .librarySearchFocusRequested, object: nil)
    }

    /// A TextKit 1 stack, as the editor's, kept by the view.
    private var storage: NSTextStorage?

    convenience init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        self.init(frame: NSRect(x: 0, y: 0, width: 200, height: 20), textContainer: container)
        self.storage = storage
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if window?.firstResponder === self, event.keyCode == 36 || event.keyCode == 76, modifiers == .command, let onCommandReturn {
            onCommandReturn()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        takeFocusIfRequested()
    }

    @objc private func focusRequested(_ notification: Notification) {
        takeFocusIfRequested()
    }

    private func takeFocusIfRequested() {
        guard LibrarySearchFocus.take(.chat, in: window) != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
            self.setSelectedRange(NSRange(location: (self.string as NSString).length, length: 0))
        }
    }
}
