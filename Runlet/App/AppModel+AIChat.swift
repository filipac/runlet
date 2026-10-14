import AppKit
import RunletCore

/// The answer being written (#45), apart from the conversation: only the turn that streams
/// redraws while it arrives, and the message field doesn't.
@MainActor
@Observable
final class AIChatLiveAnswer {
    /// The turn it belongs to; nil when nothing streams.
    var turnId: UUID?
    var text = ""
    var isThinking = false
    var answeringModel: String?
    var fallbackFrom: String?
    var fallbackTo: String?

    func start(_ turnId: UUID) {
        self.turnId = turnId
        text = ""
        isThinking = false
        answeringModel = nil
        fallbackFrom = nil
        fallbackTo = nil
    }
}

/// A window's chat (#45): its conversation, the message being written, and the context switches.
/// It lives as long as the window, in memory only, like the window's terminals: conversations
/// hold the tab's code, run output, and project files, so Runlet never writes them to disk, and
/// a new launch starts with none.
@MainActor
@Observable
final class AIChatSession {
    var conversation = AIChatConversation()
    let live = AIChatLiveAnswer()
    /// What's typed in the message field, and the caret (UTF-16).
    var draft = ""
    var cursor = 0
    /// The switches under the field; they stay as set for the next message.
    var choice = AIChatContextChoice()
    /// The files the message mentions, as read, for `filesRoot`.
    var files: [String: AIChatFile.Content] = [:]
    var filesRoot: URL?
    /// The project's files for `@` completion, for `fileIndexRoot`.
    var fileIndex: [String] = []
    var fileIndexRoot: URL?
    /// The highlighted `@` suggestion.
    var suggestion = 0
    /// Esc closed the suggestions of the mention that starts here.
    var dismissedMention: Int?
    /// Bumped when the tab's selection changes in a way the context shows (the editor isn't
    /// observable).
    var selectionTick = 0
    @ObservationIgnored var lastSelection: NSRange?
    /// Context rows opened to show their exact text.
    var expanded: Set<String> = []
    /// A code block's Copy or Insert into Tab just happened (its key), for the button's feedback.
    var copied: String?
    var inserted: String?
    /// What each turn's Send approved, for Try Again: the same disclosure, sent again.
    @ObservationIgnored var disclosures: [UUID: AIDisclosure] = [:]
    /// The code an Insert into Tab button asked for, read once by the command it runs.
    @ObservationIgnored var insertRequest: (key: String, code: String)?
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var indexTask: Task<Void, Never>?

    var isStreaming: Bool { conversation.isStreaming }
}

extension AppModel {
    // MARK: The pane

    /// Whether the trailing column shows the chat (the column and its pane are the same in
    /// every window).
    var isChatShown: Bool { showInspector && inspectorPane == .chat }

    /// Library ▸ Show/Hide Chat: the chat in the trailing column, the message field focused; or
    /// the column hidden when the chat is what it shows.
    func toggleChat() {
        if isChatShown {
            setInspectorVisible(false)
            return
        }
        showChat()
    }

    func showChat() {
        inspectorPane = .chat
        setInspectorVisible(true)
        LibrarySearchFocus.request(.chat)
    }

    /// Whether the chat's message field has the keyboard: ⌘. then stops the chat's answer.
    var chatHasKeyboard: Bool { NSApp.keyWindow?.firstResponder is AIChatMessageTextView }

    var activeChat: AIChatSession? { activeWindow?.chat }

    // MARK: Context

    /// The tab's code, or its selection, as the chat offers it.
    func chatEditorContext(_ tab: TabModel) -> AIChatEditorContext {
        var context = AIChatEditorContext(tabTitle: tab.title, language: tab.language, code: tab.code)
        if let editor = tab.editorIfLoaded {
            let range = editor.selectedRange
            let ns = editor.text as NSString
            if range.length > 0, NSMaxRange(range) <= ns.length {
                let first = Self.lineNumber(of: range.location, in: ns)
                // A selection that ends at a line's start doesn't take that line.
                let endLocation = NSMaxRange(range) > range.location && ns.character(at: NSMaxRange(range) - 1) == 0x0A ? NSMaxRange(range) - 1 : NSMaxRange(range)
                context.selection = AIChatEditorContext.Selection(text: ns.substring(with: range), firstLine: first,
                                                                  lastLine: max(first, Self.lineNumber(of: endLocation, in: ns)))
            }
        }
        return context
    }

    private static func lineNumber(of location: Int, in text: NSString) -> Int {
        var line = 1
        var index = 0
        let end = min(location, text.length)
        while index < end {
            let found = text.range(of: "\n", options: [], range: NSRange(location: index, length: end - index))
            guard found.location != NSNotFound else { break }
            line += 1
            index = NSMaxRange(found)
        }
        return line
    }

    /// The tab's last output as text, its errors as Explain or Fix sends them (paths relative to
    /// the project, never this Mac's folders). Nil before a run.
    func chatOutputContext(_ tab: TabModel) -> AIChatOutputContext? {
        let path = errorDisplayPath(for: tab)
        var hasError = false
        var lines: [String] = []
        for item in tab.output {
            switch item {
            case .header:
                continue
            case .error(_, let error, let line):
                if error.interruptedByStop != true { hasError = true }
                lines.append(ExplainErrorPrompt.errorText(error, line: line, path: path))
            default:
                lines.append(item.plainText(display: tab.shownModelDisplay))
            }
        }
        let text = lines.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return AIChatOutputContext(tabTitle: tab.title, text: text, hasError: hasError)
    }

    /// The folder `@` files come from: the selected tab's project. Nil for the sandbox.
    func chatProjectRoot(in window: WindowModel) -> URL? {
        window.selectedTab.flatMap { projectRoot(for: $0.target) }
    }

    /// What the next message would send, as the message field shows it.
    func chatDraft(in window: WindowModel) -> AIChatDraft {
        let session = window.chat
        _ = session.selectionTick
        let provider = settings.aiProvider
        let tab = window.selectedTab
        let files = AIChatMentions.paths(in: session.draft, activeAt: session.cursor).map { path in
            AIChatFile(path: path, content: session.files[path] ?? .reading)
        }
        return AIChatPrompt.draft(provider: provider, model: settings.aiModel(for: provider), conversation: session.conversation, message: session.draft,
                                  editor: tab.map(chatEditorContext), output: tab.flatMap(chatOutputContext), files: files, choice: session.choice)
    }

    /// The tab's selection changed: the context shows it when something is (or was) selected.
    func chatSelectionChanged(_ tab: TabModel, in window: WindowModel) {
        guard isChatShown, window.selectedTab === tab, let editor = tab.editorIfLoaded else { return }
        let range = editor.selectedRange
        let selection = range.length > 0 ? range : nil
        guard selection != window.chat.lastSelection else { return }
        window.chat.lastSelection = selection
        window.chat.selectionTick += 1
    }

    func setChatContext(_ id: String, included: Bool, in window: WindowModel) {
        let session = window.chat
        switch id {
        case AIChatPrompt.editorPartID: session.choice.includeEditor = included
        case AIChatPrompt.outputPartID: session.choice.includeOutput = included
        default:
            guard id.hasPrefix("file:") else { return }
            let path = String(id.dropFirst(5))
            if included { session.choice.excludedFiles.remove(path) } else { session.choice.excludedFiles.insert(path) }
        }
    }

    // MARK: @ files

    /// The message changed: reads the files it mentions (off the main thread, once each), and
    /// loads the project's file list when a mention is being typed.
    func chatDraftChanged(in window: WindowModel) {
        let session = window.chat
        let root = chatProjectRoot(in: window)
        if session.filesRoot != root {
            session.files = [:]
            session.filesRoot = root
        }
        for path in AIChatMentions.paths(in: session.draft, activeAt: session.cursor) where session.files[path] == nil {
            guard let root else {
                session.files[path] = .unavailable("@ files come from the tab's project folder, and this tab has none.")
                continue
            }
            session.files[path] = .reading
            Task { [weak session] in
                let result = await Task.detached(priority: .userInitiated) { ProjectFiles.read(path, in: root) }.value
                guard let session, session.filesRoot == root else { return }
                switch result {
                case .success(let file): session.files[path] = .text(file.text)
                case .failure(let error): session.files[path] = .unavailable(error.message)
                }
            }
        }
        if let mention = AIChatMentions.active(in: session.draft, cursor: session.cursor) {
            if session.dismissedMention != mention.range.location { loadChatFileIndex(in: window) }
        } else {
            session.dismissedMention = nil
            session.suggestion = 0
        }
    }

    /// Lists the project's files for completion, once per project while the chat is open.
    func loadChatFileIndex(in window: WindowModel) {
        let session = window.chat
        guard let root = chatProjectRoot(in: window), session.fileIndexRoot != root else { return }
        session.fileIndexRoot = root
        session.fileIndex = []
        session.indexTask?.cancel()
        session.indexTask = Task { [weak session] in
            let paths = await Task.detached(priority: .userInitiated) { ProjectFiles.list(in: root) }.value
            guard let session, session.fileIndexRoot == root else { return }
            session.fileIndex = paths
        }
    }

    /// The mention being typed and the files it could be; nil when there's nothing to suggest.
    func chatSuggestions(in window: WindowModel) -> (mention: AIChatMentions.Mention, paths: [String])? {
        let session = window.chat
        guard let mention = AIChatMentions.active(in: session.draft, cursor: session.cursor), session.dismissedMention != mention.range.location,
              chatProjectRoot(in: window) != nil else { return nil }
        let paths = ProjectFiles.rank(session.fileIndex, query: mention.path, limit: 6)
        return paths.isEmpty ? nil : (mention, paths)
    }

    /// Completes the mention being typed with `path` (a click, Tab, or Return in the list).
    func acceptChatSuggestion(_ path: String, in window: WindowModel) {
        let session = window.chat
        guard let mention = AIChatMentions.active(in: session.draft, cursor: session.cursor) else { return }
        let completed = AIChatMentions.complete(session.draft, mention: mention, with: path)
        session.draft = completed.text
        session.cursor = completed.caret
        session.suggestion = 0
        chatDraftChanged(in: window)
    }

    /// The field's @ button: starts a mention at the end of the message.
    func beginChatMention(in window: WindowModel) {
        let session = window.chat
        let needsSpace = !(session.draft.isEmpty || session.draft.last?.isWhitespace == true)
        session.draft += (needsSpace ? " " : "") + "@"
        session.cursor = (session.draft as NSString).length
        session.dismissedMention = nil
        chatDraftChanged(in: window)
        LibrarySearchFocus.request(.chat, selectAll: false)
    }

    // MARK: Sending

    /// Why Send Chat Message can't run, or nil when it can.
    func chatSendDisabledReason(in window: WindowModel?) -> String? {
        guard let window else { return "Send Chat Message works in a window's chat." }
        guard isChatShown else { return "Send Chat Message works while the chat is open." }
        let draft = chatDraft(in: window)
        if let problem = draft.problem { return problem }
        if !hasAIKey(draft.disclosure.provider) { return AIError.missingKey(draft.disclosure.provider).message }
        return nil
    }

    /// Send (the button, ⌘↩ in the message field, or Send Chat Message): the user's consent for
    /// exactly the disclosure under the field. Only while the chat is open, so what's sent is
    /// on screen. The answer streams into the conversation.
    func sendChat(in window: WindowModel) {
        guard chatSendDisabledReason(in: window) == nil else { return }
        let session = window.chat
        let draft = chatDraft(in: window)
        let disclosure = draft.disclosure
        let consent = AIConsent(approving: disclosure)
        let context = draft.contextParts.filter(\.isIncluded).map(\.title)
        let turn = AIChatTurn(question: session.draft.trimmingCharacters(in: .whitespacesAndNewlines), context: context, sent: disclosure.message,
                              provider: disclosure.provider, model: disclosure.model)
        session.conversation.turns.append(turn)
        session.disclosures[turn.id] = disclosure
        session.draft = ""
        session.cursor = 0
        session.files = [:]
        session.choice.excludedFiles = []
        session.expanded = []
        streamChat(turn.id, disclosure, consent: consent, in: session)
    }

    /// Try Again on the last turn when it failed: the same disclosure its Send approved.
    func retryChat(_ turnId: UUID, in window: WindowModel) {
        let session = window.chat
        guard !session.isStreaming, session.conversation.turns.last?.id == turnId, let disclosure = session.disclosures[turnId],
              case .failed = session.conversation.turn(turnId)?.state else { return }
        guard hasAIKey(disclosure.provider) else { return }
        session.conversation.update(turnId) { turn in
            turn.state = .streaming
            turn.answer = ""
        }
        streamChat(turnId, disclosure, consent: AIConsent(approving: disclosure), in: session)
    }

    private func streamChat(_ turnId: UUID, _ disclosure: AIDisclosure, consent: AIConsent, in session: AIChatSession) {
        session.task?.cancel()
        let live = session.live
        live.start(turnId)
        session.task = Task { [weak self, weak session] in
            guard let self else { return }
            do {
                for try await event in self.streamAI(disclosure, consent: consent) {
                    guard let session, live.turnId == turnId else { return }
                    switch event {
                    case .started(let model):
                        live.answeringModel = model.isEmpty ? nil : model
                    case .thinking:
                        live.isThinking = true
                    case .text(let text):
                        live.isThinking = false
                        live.text += text
                    case .fallback(let from, let to):
                        live.fallbackFrom = from
                        live.fallbackTo = to
                        if let to { live.answeringModel = to }
                    case .finished(let finish):
                        self.finishChat(turnId, finish, in: session)
                    }
                }
                guard let session else { return }
                // A cancelled stream just ends: Stop, or a new conversation.
                self.endChatTurn(turnId, state: Task.isCancelled ? .stopped : .complete, in: session)
            } catch {
                guard let session else { return }
                self.failChat(turnId, error, in: session)
            }
        }
    }

    private func finishChat(_ turnId: UUID, _ finish: AIFinish, in session: AIChatSession) {
        if let model = finish.model { session.live.answeringModel = model }
        switch finish.reason {
        case .refusal(let category, let explanation):
            // A declined answer isn't an answer: what arrived is dropped, and isn't sent again.
            let provider = session.conversation.turn(turnId)?.provider ?? settings.aiProvider
            session.live.text = ""
            endChatTurn(turnId, state: .failed(.refused(provider, category: category, explanation: explanation)), in: session)
        case .maxTokens:
            endChatTurn(turnId, state: .cutOff, in: session)
        case .complete, .other:
            endChatTurn(turnId, state: .complete, in: session)
        }
    }

    private func failChat(_ turnId: UUID, _ error: Error, in session: AIChatSession) {
        let provider = session.conversation.turn(turnId)?.provider ?? settings.aiProvider
        if let error = error as? CredentialStoreError {
            alert = AppAlert(title: "Couldn't read the key", message: error.description)
            endChatTurn(turnId, state: .failed(.missingKey(provider)), in: session)
            return
        }
        let failure = AIErrorMapping.transport(error, provider: provider)
        endChatTurn(turnId, state: failure == .cancelled ? .stopped : .failed(failure), in: session)
    }

    /// The turn ends: what arrived moves from the live answer into the conversation, once.
    private func endChatTurn(_ turnId: UUID, state: AIChatTurn.State, in session: AIChatSession) {
        let live = session.live
        guard live.turnId == turnId, session.conversation.turn(turnId)?.isStreaming == true else { return }
        session.conversation.update(turnId) { turn in
            turn.state = state
            turn.answer = state == .complete || state == .stopped || state == .cutOff ? live.text : ""
            turn.answeringModel = live.answeringModel
            turn.fallbackFrom = live.fallbackFrom
            turn.fallbackTo = live.fallbackTo
        }
        live.turnId = nil
        live.text = ""
        session.task = nil
    }

    /// Stop (the button, Stop Chat Answer, or ⌘.): ends the request; what arrived stays,
    /// marked as stopped, and later messages send it as it is.
    func stopChat(in window: WindowModel) {
        window.chat.task?.cancel()
    }

    /// New Chat Conversation: the conversation goes (it isn't kept anywhere); the message being
    /// written and the switches stay.
    func newChatConversation(in window: WindowModel) {
        let session = window.chat
        session.task?.cancel()
        session.live.turnId = nil
        session.live.text = ""
        session.conversation = AIChatConversation()
        session.disclosures = [:]
        session.expanded = []
    }

    /// A window closes: its answer stops, and the conversation goes with it.
    func closeChat(in window: WindowModel) {
        window.chat.task?.cancel()
        window.chat.indexTask?.cancel()
    }

    // MARK: Answers

    /// Insert into Tab: a code block from an answer replaces the tab's selection, or goes in at
    /// the caret, as one undoable edit ("Undo Insert into Tab"). It counts as loaded code, so
    /// sandbox auto-run turns off, and nothing runs; production's confirmations are untouched.
    func insertChatCode(_ code: String, key: String?, in window: WindowModel) {
        guard let tab = window.selectedTab else { return }
        let editor = tab.editor
        let text = AIChatInsertion.text(code, language: tab.language, document: editor.text, selection: editor.selectedRange)
        guard !text.isEmpty else { return }
        tab.setAutoRunEnabled(false)
        editor.insertGenerated(text, actionName: "Insert into Tab")
        if let key {
            window.chat.inserted = key
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak session = window.chat] in
                if session?.inserted == key { session?.inserted = nil }
            }
        }
    }

    /// The code Insert Code into Tab inserts: the block whose button was clicked, or the last
    /// answer's last code block.
    func chatInsertableCode(in window: WindowModel?) -> String? {
        guard let window, window.selectedTab != nil else { return nil }
        return window.chat.insertRequest?.code ?? window.chat.conversation.lastCodeBlock
    }

    func copyChatText(_ text: String, key: String, in window: WindowModel) {
        Pasteboard.copy(text)
        window.chat.copied = key
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak session = window.chat] in
            if session?.copied == key { session?.copied = nil }
        }
    }

    // MARK: Explain or Fix

    /// Explain or Fix's Continue in Chat: its question and answer become a turn of the window's
    /// chat, so a follow-up sends them as earlier turns; the sheet closes and the chat opens.
    /// Nothing is sent.
    func continueExplainErrorInChat() {
        guard let session = explainError, session.phase == .finished, !session.answerText.isEmpty,
              let window = session.windowId.flatMap({ self.window($0) }) ?? window(containing: session.tabId) ?? activeWindow,
              !window.chat.isStreaming else { return }
        let turn = AIChatPrompt.continuing(session.disclosure, answer: session.answerText, answeringModel: session.answeringModel,
                                           title: "Explain or Fix the error in “\(session.tabTitle)”")
        window.chat.conversation.turns.append(turn)
        window.chat.disclosures[turn.id] = session.disclosure
        closeExplainError()
        showChat()
    }
}
