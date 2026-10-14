#if DEBUG
import AppKit
import RunletCore

/// RUNLET_DEBUG_STEPS for the AI chat (#45), so a conversation, its disclosure, `@` files, and
/// Insert into Tab can be checked and photographed without a keyboard. Point the app at the
/// local stand-in (`RUNLET_AI_BASE_URL`, `Tests/Fixtures/ai-stub/router.php` under `php -S`) and
/// save a made-up key with `ai-key:` (`AIDebugSteps`): a scratch `RUNLET_DATA_DIR` keeps it in
/// memory.
///
/// - `chat` shows the chat in the trailing column, as Show/Hide Chat does; `chat:off` hides it.
/// - `chat-type:<text>` sets the message (`\n` is a new line, `\c` a comma), the caret at its
///   end, as typing does; `chat-caret:<offset>` moves the caret.
/// - `chat-include:<part id>=on|off` (`editor`, `output`, `file:<path>`) switches context.
/// - `chat-expand:<key>` opens a context row (a part id, `history`, or `instructions`), and
///   `chat-collapse` closes them all.
/// - `chat-accept[:<n>]` adds the highlighted (or the n-th, from 0) `@` suggestion, and
///   `chat-mention` presses the @ button.
/// - `chat-send`, `chat-stop`, `chat-new`, and `chat-retry` press Send, Stop, New Conversation,
///   and the last turn's Try Again. `chat-insert[:<turn>-<block>]` presses a code block's Insert
///   into Tab (the last answer's last block without an argument). `chat-continue` presses
///   Explain or Fix's Continue in Chat.
/// - `chat-provider:<provider>`, `chat-model:<model id>`, and `chat-effort:default|<level>` set
///   where the next message goes, as the pickers do (a provider without a key is refused);
///   `chat-picker:model|effort|off` opens or closes a picker. `chat-leave-out` presses Leave Out
///   Earlier Attachments.
/// - `chat-select:<first line>-<last line>` selects lines in the current tab, as the editor does.
/// - `chat-state` prints a `RUNLET_DEBUG_STATE:` line: the conversation's turns and states, the
///   draft's parts and whether they're on, its characters, the files, the suggestions, the
///   problem, and the tab's code and auto-run.
/// - `ai-wait:chat-text|chat-done|chat-files|chat-index[:<seconds>]` (`AIDebugSteps.reached`)
///   holds the steps until answer text arrived, the answer ended, the mentioned files were read,
///   or the project's file list is loaded.
@MainActor
enum AIChatDebugSteps {
    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        guard name == "chat" || name.hasPrefix("chat-") else { return false }
        guard let window = model.activeWindow else { return true }
        let session = window.chat
        switch name {
        case "chat":
            if argument == "off" { model.setInspectorVisible(false) } else { model.showChat() }
        case "chat-type":
            session.draft = argument.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\c", with: ",")
            session.cursor = (session.draft as NSString).length
            model.chatDraftChanged(in: window)
        case "chat-caret":
            session.cursor = min(Int(argument) ?? 0, (session.draft as NSString).length)
            model.chatDraftChanged(in: window)
        case "chat-include":
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { model.setChatContext(parts[0], included: parts[1] == "on", in: window) }
        case "chat-expand":
            session.expanded.insert(argument)
        case "chat-collapse":
            session.expanded = []
        case "chat-accept":
            if let suggestions = model.chatSuggestions(in: window) {
                let index = Int(argument) ?? session.suggestion
                if suggestions.paths.indices.contains(index) { model.acceptChatSuggestion(suggestions.paths[index], in: window) }
            }
        case "chat-mention":
            model.beginChatMention(in: window)
        case "chat-send":
            model.perform("library.chatSend", source: .script, in: window)
        case "chat-stop":
            model.perform("library.chatStop", source: .script, in: window)
        case "chat-new":
            model.perform("library.chatNew", source: .script, in: window)
        case "chat-retry":
            if let last = session.conversation.turns.last { model.retryChat(last.id, in: window) }
        case "chat-insert":
            if !argument.isEmpty, let code = codeBlock(argument, in: session) { session.insertRequest = (argument, code) }
            model.perform("library.chatInsert", source: .script, in: window)
            session.insertRequest = nil
        case "chat-continue":
            model.continueExplainErrorInChat()
        case "chat-select":
            let lines = argument.split(separator: "-").compactMap { Int($0) }
            if let tab = window.selectedTab, let first = lines.first {
                let editor = tab.editor
                let ns = editor.text as NSString
                let start = offset(ofLine: first, in: ns)
                let end = offset(ofLine: (lines.last ?? first) + 1, in: ns)
                editor.textView.setSelectedRange(NSRange(location: start, length: max(0, end - start)))
            }
        case "chat-provider":
            if let provider = AIProvider(rawValue: argument) { model.setChatProvider(provider) }
        case "chat-model":
            model.setChatModel(argument)
        case "chat-effort":
            if argument == "default" { model.setChatEffort(.modelDefault) } else if let level = AIEffort(rawValue: argument) { model.setChatEffort(.level(level)) }
        case "chat-picker":
            session.picker = argument == "model" ? .model : argument == "effort" ? .effort : nil
        case "chat-leave-out":
            model.leaveOutChatAttachments(in: window)
        case "chat-state":
            AIDebugSteps.log(state(model, window: window))
        default:
            return false
        }
        return true
    }

    /// For `ai-wait`.
    static func reached(_ condition: String, model: AppModel) -> Bool? {
        guard let window = model.activeWindow else { return nil }
        let session = window.chat
        switch condition.split(separator: ":").first.map(String.init) ?? "" {
        case "chat-text": return !session.live.text.isEmpty || !(session.conversation.turns.last?.answer.isEmpty ?? true)
        case "chat-done": return session.conversation.turns.last.map { !$0.isStreaming } ?? false
        case "chat-files": return !session.files.values.contains(.reading)
        case "chat-index": return session.fileIndexRoot != nil && !session.fileIndex.isEmpty
        default: return nil
        }
    }

    /// A code block by "<turn>-<block>" (1-based, counting every block of the answer).
    private static func codeBlock(_ key: String, in session: AIChatSession) -> String? {
        let numbers = key.split(separator: "-").compactMap { Int($0) }
        guard numbers.count == 2, session.conversation.turns.indices.contains(numbers[0] - 1) else { return nil }
        let blocks = AIAnswer.parse(session.conversation.turns[numbers[0] - 1].answer, extractingFix: false).blocks
        guard blocks.indices.contains(numbers[1] - 1), case .code(_, let code, _) = blocks[numbers[1] - 1] else { return nil }
        return code
    }

    private static func offset(ofLine line: Int, in text: NSString) -> Int {
        var current = 1
        var index = 0
        while current < line, index < text.length {
            let found = text.range(of: "\n", options: [], range: NSRange(location: index, length: text.length - index))
            guard found.location != NSNotFound else { return text.length }
            index = NSMaxRange(found)
            current += 1
        }
        return min(index, text.length)
    }

    static func state(_ model: AppModel, window: WindowModel) -> String {
        let session = window.chat
        let draft = model.chatDraft(in: window)
        let turns = session.conversation.turns.map { turn -> String in
            let state = switch turn.state {
            case .streaming: "streaming(\(session.live.text.count))"
            case .complete: "complete"
            case .stopped: "stopped"
            case .cutOff: "cutOff"
            case .failed(let error): "failed(\(error.title))"
            }
            let blocks = AIAnswer.parse(turn.answer, extractingFix: false).blocks.filter { if case .code = $0 { true } else { false } }.count
            return "\(state):\(turn.answer.count)c:\(blocks)code:\(turn.provider.rawValue)/\(turn.model)/\(turn.effort?.rawValue ?? "default")"
        }
        let parts = draft.contextParts.map { "\($0.id)=\($0.isIncluded ? "on" : "off")" }.joined(separator: ",")
        let files = session.files.keys.sorted().map { path -> String in
            switch session.files[path] {
            case .reading: "\(path)=reading"
            case .text(let text): "\(path)=\(text.count)c"
            case .unavailable(let reason): "\(path)=unavailable(\(reason))"
            case nil: path
            }
        }.joined(separator: ",")
        let suggestions = model.chatSuggestions(in: window)?.paths.joined(separator: ",") ?? "-"
        let destination = model.chatDestination.map { "\($0.provider.rawValue)/\($0.model)/\($0.effort?.rawValue ?? "default")" } ?? "none"
        var line = "chat shown=\(model.isChatShown) pane=\(model.inspectorPane) to=\(destination) configured=\(model.configuredAIProviders.map(\.rawValue).sorted())"
        line += " picker=\(session.picker.map { "\($0)" } ?? "-") switch=\(draft.switchedFrom.map { "\($0.provider.rawValue)/\($0.model)" } ?? "-")"
        line += " overflow=\(draft.overflow.map { "\($0.tokens)/\($0.limit)" } ?? "-") leftOut=\(session.conversation.turns.filter(\.attachmentsLeftOut).count)"
        line += " sends=\(draft.disclosure.provider.rawValue)/\(draft.disclosure.model)/\(draft.disclosure.effort?.rawValue ?? "default")"
        line += " turns=[\(turns.joined(separator: " "))] history=\(draft.disclosure.history.count)"
        line += " parts=[\(parts)] notSent=\(draft.unavailableFiles.map(\.path)) chars=\(draft.disclosure.characterCount) files=[\(files)]"
        line += " index=\(session.fileIndex.count) suggestions=[\(suggestions)] problem=\(draft.problem ?? "-") canSend=\(draft.canSend) key=\(model.hasAIKey(draft.disclosure.provider))"
        if let tab = window.selectedTab {
            line += " tab=\(tab.title) code=\(tab.code.count)c autoRun=\(tab.autoRunEnabled) undo=\(tab.editorIfLoaded?.textView.undoManager?.undoActionName ?? "-")"
        }
        return line
    }
}
#endif
