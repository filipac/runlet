import Foundation

// The chat sidebar (#45), built on the AI layer (#368) and its privacy rules (`AIPrivacy.swift`):
//
// - Each message is an `AIDisclosure` the user sees before sending: the instructions, the earlier
//   turns that go again, and the new message's parts (the editor, the last output, `@` files, and
//   what the user typed), each context part with its own switch. `AIChatPrompt.draft` builds it;
//   the app sends it only with the `AIConsent` a Send makes.
// - Context is capped (`AIChatLimits`) and scrubbed of values shaped like secrets
//   (`AISecretRedaction`), and the disclosure shows the result: what's shown is what's sent.
// - Conversations live in memory, one per window, and are never written to disk: they hold the
//   tab's code, run output, and project files.
// - Answers are text. Code from one goes into a tab only on Insert into Tab (`AIChatInsertion`),
//   as an undoable edit, and never runs.

/// Limits of what a chat message sends (#45).
public enum AIChatLimits {
    /// Each context part (the editor, the output, one file) is cut to this many characters, with
    /// a note saying so, as Explain or Fix's parts are.
    public static let maxPartCharacters = ExplainErrorPrompt.maxPartCharacters
    /// `@` files a message sends; later mentions are listed as not sent.
    public static let maxFiles = 5
    /// A file larger than this isn't read at all.
    public static let maxFileBytes = 1024 * 1024
    /// Room for the model's thinking and an answer with code.
    public static let maxOutputTokens = 16_000
}

/// Where the chat's next message goes (#45): a provider with a saved key, and its model. The
/// chat chooses its own (`AppSettings.aiChatProvider`, `aiChatModel(for:)`) without changing
/// Settings ▸ AI, and never a provider without a key: when the one it chose has none (its key
/// was removed), it uses Settings ▸ AI's provider, or the other one, and nothing when none has.
public struct AIChatDestination: Sendable, Equatable {
    public var provider: AIProvider
    public var model: String
    /// The reasoning level as chosen (the chat's, or Settings ▸ AI's).
    public var effortChoice: AIEffortChoice

    public init(provider: AIProvider, model: String, effortChoice: AIEffortChoice = .modelDefault) {
        self.provider = provider
        self.model = model
        self.effortChoice = effortChoice
    }

    /// The level the request sends: nil for Default, or for a level this model doesn't take.
    public var effort: AIEffort? { AIModelTraits.effort(effortChoice, provider, model) }

    /// The levels the picker offers for this model; empty hides it.
    public var effortLevels: [AIEffort] { AIModelTraits.effortLevels(provider, model) }

    /// `configured`: the providers with a saved key.
    public static func resolve(_ settings: AppSettings, configured: Set<AIProvider>) -> AIChatDestination? {
        let order = [settings.aiChatProvider, settings.aiProvider].compactMap { $0 } + AIProvider.allCases
        guard let provider = order.first(where: configured.contains) else { return nil }
        return AIChatDestination(provider: provider, model: settings.aiChatModel(for: provider), effortChoice: settings.aiChatEffort(for: provider))
    }

    /// "claude-opus-5-5 · effort high", "gpt-6-astra · default effort", or the model alone
    /// when it takes no level: what the disclosure and each answer name.
    public static func label(model: String, provider: AIProvider, effort: AIEffort?) -> String {
        guard !AIModelTraits.effortLevels(provider, model).isEmpty else { return model }
        return model + " · " + (effort.map { "effort \($0.rawValue)" } ?? "default effort")
    }

    /// The providers the chat's picker lists, each with why it can't be chosen (nil when it
    /// can): every provider, so the one without a key shows how to add one.
    public static func choices(configured: Set<AIProvider>) -> [(provider: AIProvider, unavailable: String?)] {
        AIProvider.allCases.map { provider in
            (provider, configured.contains(provider) ? nil : "Add a key in Settings ▸ AI")
        }
    }
}

/// One exchange of a chat (#45): the message as typed and as sent, and the answer.
public struct AIChatTurn: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable {
        /// The answer is arriving.
        case streaming
        case complete
        /// Stop was pressed: `answer` is what arrived.
        case stopped
        /// The answer reached its length limit.
        case cutOff
        /// No answer: the request failed, or the model declined.
        case failed(AIError)
    }

    public let id: UUID
    /// What the user typed.
    public var question: String
    /// The titles of the context parts that went with it ("The tab's PHP code (“Invoice”)",
    /// "app/Models/Order.php").
    public var context: [String]
    /// The user's message exactly as sent (`AIDisclosure.message`). Later turns send it again.
    public var sent: String
    public var provider: AIProvider
    /// The model asked.
    public var model: String
    public var answer: String
    public var state: State
    /// The model that answered, from the stream.
    public var answeringModel: String?
    /// Anthropic's safety checks declined the chosen model, and `fallbackTo` answered.
    public var fallbackFrom: String?
    public var fallbackTo: String?
    /// The model is thinking before it writes.
    public var isThinking: Bool
    /// The reasoning level sent with it; nil when none was (the model's own default).
    public var effort: AIEffort?
    /// The typed message as sent, without what went with it ("## Message" and the text).
    public var messagePart: String
    /// What went with the message is no longer sent again ("Leave Out Earlier Attachments"):
    /// later messages send the message, and a note naming what was left out.
    public var attachmentsLeftOut: Bool

    public init(id: UUID = UUID(), question: String, context: [String], sent: String, provider: AIProvider, model: String,
                answer: String = "", state: State = .streaming, effort: AIEffort? = nil, messagePart: String? = nil) {
        self.id = id
        self.question = question
        self.context = context
        self.sent = sent
        self.provider = provider
        self.model = model
        self.answer = answer
        self.state = state
        self.isThinking = false
        self.effort = effort
        self.messagePart = messagePart ?? ""
        self.attachmentsLeftOut = false
    }

    /// The message as later turns send it again: as it was sent, or, once its attachments are
    /// left out, the message and a note that says what was.
    public var sentAgain: String {
        guard attachmentsLeftOut, !context.isEmpty else { return sent }
        let note = "[Runlet left out what was sent with this message: \(context.joined(separator: ", ")).]"
        return messagePart.isEmpty ? note : messagePart + "\n\n" + note
    }

    /// Whether leaving out its attachments would make it shorter.
    public var hasAttachmentsToLeaveOut: Bool { isSentAgain && !attachmentsLeftOut && !context.isEmpty }

    /// Whether later messages send this turn again: it has an answer (complete, stopped, or cut
    /// off). A failed or empty turn is shown, never sent again.
    public var isSentAgain: Bool {
        switch state {
        case .complete, .stopped, .cutOff: !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .streaming, .failed: false
        }
    }

    public var isStreaming: Bool { state == .streaming }
}

/// A window's conversation (#45): kept in memory while Runlet runs, never on disk.
public struct AIChatConversation: Sendable, Equatable {
    public var turns: [AIChatTurn]

    public init(turns: [AIChatTurn] = []) {
        self.turns = turns
    }

    public var isEmpty: Bool { turns.isEmpty }
    public var isStreaming: Bool { turns.contains(where: \.isStreaming) }

    /// The earlier turns a new message sends, in order: each answered turn's message as it was
    /// sent, and its answer.
    public var history: [AIMessage] {
        turns.filter(\.isSentAgain).flatMap { [AIMessage(.user, $0.sentAgain), AIMessage(.assistant, $0.answer)] }
    }

    /// The provider and model of the last turn that's sent again: a message to another one
    /// sends the whole conversation to a model that hasn't read it.
    public var lastAnswered: (provider: AIProvider, model: String)? {
        turns.last(where: \.isSentAgain).map { ($0.provider, $0.model) }
    }

    /// Leaves out what went with earlier messages, oldest first, until `fits` says the
    /// conversation fits (or every one is left out). Returns how many turns changed.
    @discardableResult
    public mutating func leaveOutAttachments(until fits: (AIChatConversation) -> Bool) -> Int {
        var changed = 0
        for index in turns.indices where !fits(self) && turns[index].hasAttachmentsToLeaveOut {
            turns[index].attachmentsLeftOut = true
            changed += 1
        }
        return changed
    }

    public func turn(_ id: UUID) -> AIChatTurn? { turns.first { $0.id == id } }

    /// Changes one turn; nothing when it's gone (a new conversation started meanwhile).
    public mutating func update(_ id: UUID, _ change: (inout AIChatTurn) -> Void) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        change(&turns[index])
    }

    /// The last code block of the last answer, for Insert into Tab without picking one.
    public var lastCodeBlock: String? {
        for turn in turns.reversed() where !turn.answer.isEmpty {
            for block in AIAnswer.parse(turn.answer, extractingFix: false).blocks.reversed() {
                if case .code(_, let code, false) = block { return code }
            }
            return nil
        }
        return nil
    }
}

/// The tab's code, as the chat offers it (#45).
public struct AIChatEditorContext: Sendable, Equatable {
    public var tabTitle: String
    public var language: TabLanguage
    public var code: String
    /// The selection, when there is one: it's sent instead of the whole tab.
    public var selection: Selection?

    public struct Selection: Sendable, Equatable {
        public var text: String
        /// 1-based editor lines.
        public var firstLine: Int
        public var lastLine: Int

        public init(text: String, firstLine: Int, lastLine: Int) {
            self.text = text
            self.firstLine = firstLine
            self.lastLine = lastLine
        }
    }

    public init(tabTitle: String, language: TabLanguage, code: String, selection: Selection? = nil) {
        self.tabTitle = tabTitle
        self.language = language
        self.code = code
        self.selection = selection
    }
}

/// The tab's last output, as text (#45).
public struct AIChatOutputContext: Sendable, Equatable {
    public var tabTitle: String
    public var text: String
    /// The run ended with an error, which the text includes.
    public var hasError: Bool

    public init(tabTitle: String, text: String, hasError: Bool) {
        self.tabTitle = tabTitle
        self.text = text
        self.hasError = hasError
    }
}

/// A file a message mentions with `@`, read or not (#45).
public struct AIChatFile: Sendable, Equatable {
    /// The path as mentioned, relative to the project.
    public var path: String
    public var content: Content

    public enum Content: Sendable, Equatable {
        /// Still being read: the message can't be sent yet.
        case reading
        case text(String)
        /// Can't be sent, and why.
        case unavailable(String)
    }

    public init(path: String, content: Content) {
        self.path = path
        self.content = content
    }
}

/// The switches under the message field (#45): they stay as set for the next message.
public struct AIChatContextChoice: Sendable, Equatable {
    public var includeEditor: Bool
    public var includeOutput: Bool
    /// `@` files switched off: mentioned, but not sent.
    public var excludedFiles: Set<String>

    public init(includeEditor: Bool = true, includeOutput: Bool = false, excludedFiles: Set<String> = []) {
        self.includeEditor = includeEditor
        self.includeOutput = includeOutput
        self.excludedFiles = excludedFiles
    }
}

/// A mentioned file that isn't sent, and why (#45).
public struct AIChatUnavailableFile: Sendable, Equatable {
    public var path: String
    public var reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

/// What the next message would send, and whether it can (#45).
public struct AIChatDraft: Sendable, Equatable {
    public var disclosure: AIDisclosure
    /// Mentioned files that aren't sent, and why.
    public var unavailableFiles: [AIChatUnavailableFile]
    /// Why Send is off, in one sentence; nil when it can send.
    public var problem: String?
    /// Earlier turns that aren't sent again (failed or empty), for the disclosure's note.
    public var turnsNotSentAgain: Int
    /// The request is longer than the model reads: what it would take (estimated, with room for
    /// the answer), and the model's context window, in tokens.
    public var overflow: Overflow?

    public struct Overflow: Sendable, Equatable {
        public var tokens: Int
        public var limit: Int
    }

    /// Leaving out what went with earlier messages could make it shorter.
    public var canLeaveOutAttachments: Bool
    /// The earlier turns were answered by another provider or model: the whole conversation
    /// goes to this one, which reads, and bills, all of it again.
    public var switchedFrom: AIChatDestination?

    public init(disclosure: AIDisclosure, unavailableFiles: [AIChatUnavailableFile] = [], problem: String? = nil, turnsNotSentAgain: Int = 0,
                canLeaveOutAttachments: Bool = false, switchedFrom: AIChatDestination? = nil) {
        self.disclosure = disclosure
        self.unavailableFiles = unavailableFiles
        self.problem = problem
        self.turnsNotSentAgain = turnsNotSentAgain
        self.canLeaveOutAttachments = canLeaveOutAttachments
        self.switchedFrom = switchedFrom
    }

    /// Characters of the earlier turns, as sent again.
    public var historyCharacters: Int { disclosure.history.reduce(0) { $0 + $1.text.count } }

    /// Whether this draft's message, with `conversation` as its earlier turns, fits the model's
    /// context window (estimated, with room for the answer).
    public func fits(with conversation: AIChatConversation) -> Bool {
        var request = disclosure
        request.history = conversation.history
        return AIModelTraits.estimatedTokens(characters: request.characterCount) + request.maxOutputTokens
            <= AIModelTraits.contextTokens(request.provider, request.model)
    }

    /// The context parts (everything but the typed message), for the switches.
    public var contextParts: [AIDisclosurePart] { disclosure.parts.filter { $0.id != AIChatPrompt.messagePartID } }

    public var canSend: Bool { problem == nil }
}

public enum AIChatPrompt {
    /// The part that holds what the user typed: always sent, last, without a switch.
    public static let messagePartID = "message"
    public static let editorPartID = "editor"
    public static let outputPartID = "output"

    public static func filePartID(_ path: String) -> String { "file:" + path }

    public static let instructions = """
    You're the assistant in the chat sidebar of Runlet, a scratchpad app for macOS where a developer runs PHP \
    snippets, and SQL, Redis, or MongoDB queries, in a Laravel sandbox or in their own projects. Each message may \
    include the code in their editor tab, its last output, or files from their project, under headings that say \
    what they are; earlier messages may have included them too.

    Answer briefly, in Markdown: inline code in backticks, and code in fenced code blocks with a language, like \
    ```php. Code meant for the tab is a snippet Runlet can run as it is (a PHP tab may start with <?php), with only \
    what the change needs. Runlet never runs your code: the developer reads it, inserts it into a tab, and runs it \
    themselves.
    """

    /// The next message's disclosure: the earlier turns, the context parts (each with its
    /// switch), and the typed message last. `files` are the message's `@` mentions, in order.
    /// It goes to `provider`'s `model`, and can't be sent unless `configured` (the providers
    /// with a saved key) holds the provider. Earlier turns go as plain text whichever provider
    /// and model wrote them: nothing tied to a model, such as its thinking, is ever kept.
    public static func draft(provider: AIProvider, model: String, effort: AIEffort? = nil, configured: Set<AIProvider>, conversation: AIChatConversation,
                             message: String, editor: AIChatEditorContext?, output: AIChatOutputContext?, files: [AIChatFile],
                             choice: AIChatContextChoice) -> AIChatDraft {
        var parts: [AIDisclosurePart] = []
        var unavailable: [AIChatUnavailableFile] = []
        var reading = false

        if let editor {
            let selected = editor.selection.flatMap { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            let code = selected?.text ?? editor.code
            if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let language = editor.language.displayName
                let title: String
                if let selected {
                    let lines = selected.firstLine == selected.lastLine ? "line \(selected.firstLine)" : "lines \(selected.firstLine)–\(selected.lastLine)"
                    title = "The selected \(language) code (\(lines) of “\(editor.tabTitle)”)"
                } else {
                    title = "The tab's \(language) code (“\(editor.tabTitle)”)"
                }
                parts.append(contextPart(id: editorPartID, title: title, text: code, fence: fenceLanguage(editor.language), included: choice.includeEditor))
            }
        }
        if let output, !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let title = output.hasError ? "The last output, with its error (“\(output.tabTitle)”)" : "The last output (“\(output.tabTitle)”)"
            parts.append(contextPart(id: outputPartID, title: title, text: output.text, fence: "text", included: choice.includeOutput))
        }
        var sentFiles = 0
        for file in files {
            switch file.content {
            case .reading:
                reading = true
            case .unavailable(let reason):
                unavailable.append(AIChatUnavailableFile(path: file.path, reason: reason))
            case .text(let text):
                guard sentFiles < AIChatLimits.maxFiles else {
                    unavailable.append(AIChatUnavailableFile(path: file.path, reason: "A message sends at most \(AIChatLimits.maxFiles) files."))
                    continue
                }
                sentFiles += 1
                parts.append(contextPart(id: filePartID(file.path), title: file.path, text: text, fence: fenceLanguage(path: file.path),
                                         included: !choice.excludedFiles.contains(file.path)))
            }
        }
        let typed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append(AIDisclosurePart(id: messagePartID, title: "Message", text: typed))

        let disclosure = AIDisclosure(provider: provider, model: model, instructions: instructions, history: conversation.history, parts: parts,
                                      maxOutputTokens: AIChatLimits.maxOutputTokens,
                                      effort: effort.flatMap { AIModelTraits.effortLevels(provider, model).contains($0) ? $0 : nil })
        let tokens = AIModelTraits.estimatedTokens(characters: disclosure.characterCount) + disclosure.maxOutputTokens
        let limit = AIModelTraits.contextTokens(provider, model)
        let canLeaveOut = conversation.turns.contains(where: \.hasAttachmentsToLeaveOut)
        var problem: String?
        if !configured.contains(provider) {
            problem = "Add an \(provider.displayName) key in Settings ▸ AI to chat with \(provider.displayName)."
        } else if conversation.isStreaming {
            problem = "Wait for the answer, or stop it."
        } else if typed.isEmpty {
            problem = "Type a message."
        } else if reading {
            problem = "Runlet is still reading the files the message mentions."
        } else if tokens > limit {
            // Never cut silently: say so, and offer to leave out what went with earlier messages.
            problem = "This is more than \(model) reads at once: about \(tokens.formatted()) tokens with room for the answer, and it reads \(limit.formatted())."
                + (canLeaveOut ? " Leave out what was sent with earlier messages, send less, or start a new conversation." : " Send less, or start a new conversation.")
        }
        let notSentAgain = conversation.turns.filter { !$0.isSentAgain && !$0.isStreaming }.count
        var switched: AIChatDestination?
        if let last = conversation.lastAnswered, last.provider != provider || last.model != model {
            switched = AIChatDestination(provider: last.provider, model: last.model)
        }
        var draft = AIChatDraft(disclosure: disclosure, unavailableFiles: unavailable, problem: problem, turnsNotSentAgain: notSentAgain,
                                canLeaveOutAttachments: canLeaveOut, switchedFrom: switched)
        if tokens > limit { draft.overflow = AIChatDraft.Overflow(tokens: tokens, limit: limit) }
        return draft
    }

    /// A context part: secrets hidden, cut to the limit, in a fenced block, with a note for each.
    static func contextPart(id: String, title: String, text: String, fence: String, included: Bool) -> AIDisclosurePart {
        let redacted = AISecretRedaction.redact(text)
        let clamped = AITextLimit.clamp(redacted.text, limit: AIChatLimits.maxPartCharacters)
        var notes: [String] = []
        if let note = clamped.note { notes.append(note) }
        if redacted.count > 0 {
            notes.append(redacted.count == 1 ? "Runlet hid 1 value that looks like a secret." : "Runlet hid \(redacted.count) values that look like secrets.")
        }
        return AIDisclosurePart(id: id, title: title, text: MarkdownText.fence(clamped.text, language: fence), isIncluded: included,
                                note: notes.isEmpty ? nil : notes.joined(separator: " "))
    }

    public static func fenceLanguage(_ language: TabLanguage) -> String {
        switch language {
        case .php: "php"
        case .sql: "sql"
        case .redis: "redis"
        case .mongodb: "json"
        }
    }

    /// The code fence's language for a file, from its extension.
    public static func fenceLanguage(path: String) -> String {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name.hasSuffix(".blade.php") { return "blade" }
        switch (name as NSString).pathExtension {
        case "php": return "php"
        case "js", "mjs", "cjs": return "js"
        case "ts": return "ts"
        case "vue": return "vue"
        case "json": return "json"
        case "yml", "yaml": return "yaml"
        case "xml": return "xml"
        case "sql": return "sql"
        case "md": return "markdown"
        case "css", "scss": return (name as NSString).pathExtension
        case "html", "htm": return "html"
        case "sh", "bash", "zsh": return "sh"
        case "ini", "env": return "ini"
        case "neon": return "neon"
        default: return ""
        }
    }

    /// What Explain or Fix asked and answered, as a turn the chat goes on from ("Continue in
    /// Chat"): the message as it was sent, and the answer.
    public static func continuing(_ disclosure: AIDisclosure, answer: String, answeringModel: String?, title: String) -> AIChatTurn {
        var turn = AIChatTurn(question: title, context: disclosure.parts.filter(\.isIncluded).map(\.title), sent: disclosure.message,
                              provider: disclosure.provider, model: disclosure.model, answer: answer, state: .complete)
        turn.answeringModel = answeringModel
        return turn
    }
}

/// `@` mentions in a chat message (#45): `@app/Models/Order.php` sends that project file. Offsets
/// are UTF-16, as in the text view.
public enum AIChatMentions {
    /// An `@` that starts a word (not in an email address), then path characters. A trailing
    /// period ends the sentence, not the path.
    private static let pattern = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_@./-])@([\p{L}\p{N}_./-]*)"#)

    public struct Mention: Sendable, Equatable {
        /// The `@` and the path.
        public var range: NSRange
        public var path: String
    }

    public static func mentions(in text: String) -> [Mention] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            var path = ns.substring(with: match.range(at: 1))
            while path.hasSuffix(".") { path.removeLast() }
            return Mention(range: NSRange(location: match.range.location, length: 1 + (path as NSString).length), path: path)
        }
    }

    /// The paths a message mentions, in order and without repeats. The mention the caret is at
    /// the end of (still being typed) isn't one yet.
    public static func paths(in text: String, activeAt cursor: Int? = nil) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []
        for mention in mentions(in: text) where !mention.path.isEmpty {
            if let cursor, cursor == NSMaxRange(mention.range) { continue }
            if seen.insert(mention.path).inserted { paths.append(mention.path) }
        }
        return paths
    }

    /// The mention being typed: the caret is right after it. Its query is the text after `@`.
    public static func active(in text: String, cursor: Int) -> Mention? {
        let ns = text as NSString
        guard cursor > 0, cursor <= ns.length else { return nil }
        for mention in mentions(in: text) where mention.range.location < cursor {
            // The whole match, trailing periods included, up to the caret.
            var end = NSMaxRange(mention.range)
            while end < ns.length, ns.character(at: end) == 0x2E { end += 1 }
            if end == cursor {
                return Mention(range: NSRange(location: mention.range.location, length: cursor - mention.range.location),
                               path: ns.substring(with: NSRange(location: mention.range.location + 1, length: cursor - mention.range.location - 1)))
            }
        }
        return nil
    }

    /// The text with `mention` replaced by `@path ` (a space after, so the next word starts),
    /// and the caret after it.
    public static func complete(_ text: String, mention: Mention, with path: String) -> (text: String, caret: Int) {
        let ns = text as NSString
        let after = NSMaxRange(mention.range)
        let followedBySpace = after < ns.length && CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(ns.character(at: after)) ?? " ")
        let insert = "@" + path + (followedBySpace ? "" : " ")
        let result = ns.replacingCharacters(in: mention.range, with: insert)
        return (result, mention.range.location + (insert as NSString).length + (followedBySpace ? 1 : 0))
    }
}

/// Code from an answer, ready for Insert into Tab (#45). It replaces the tab's selection, or
/// goes in at the caret.
public enum AIChatInsertion {
    /// A PHP tab keeps its own `<?php` tag: when other code stays around the insertion, the
    /// block's opening tag goes (as ⇧↩ from History does). In an empty tab, or over all of it,
    /// the block goes in as it is. Code inserted in front of more code on the same line gets a
    /// line break after it.
    public static func text(_ code: String, language: TabLanguage, document: String, selection: NSRange) -> String {
        let ns = document as NSString
        let location = min(max(0, selection.location), ns.length)
        let range = NSRange(location: location, length: min(max(0, selection.length), ns.length - location))
        let remaining = ns.replacingCharacters(in: range, with: "")
        var text = code
        if language == .php, !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = HistoryLog.insertable(code)
        }
        let end = NSMaxRange(range)
        if end < ns.length, !text.isEmpty, !text.hasSuffix("\n") {
            let next = ns.character(at: end)
            if next != 0x0A, next != 0x0D, text.contains("\n") || range.location == 0 || ns.character(at: range.location - 1) == 0x0A {
                text += "\n"
            }
        }
        return text
    }

    /// The code fence's language as Runlet shows it: Explain or Fix's `runlet-fix` is PHP.
    public static func displayLanguage(_ info: String?) -> String? {
        guard let info, !info.isEmpty else { return nil }
        return info == ExplainErrorPrompt.fixInfoString ? "php" : info
    }
}

/// Hides values in chat context that look like secrets (#45): private keys, API keys and
/// tokens of well-known shapes, Laravel's `APP_KEY`, JSON web tokens, bearer tokens, and
/// passwords in URLs. A rough net, not a guarantee: the disclosure shows what's left.
public enum AISecretRedaction {
    public static let placeholder = "[hidden by Runlet]"

    private static let rules: [(NSRegularExpression, String)] = [
        (#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#, placeholder),
        // Anthropic, OpenAI, and other `sk-` keys (a word of its own, so `task-runner` stays).
        (#"(?<![A-Za-z0-9])sk-[A-Za-z0-9_\-]{20,}"#, placeholder),
        (#"(?<![A-Za-z0-9])(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{16,}"#, placeholder),
        (#"(?<![A-Za-z0-9])(?:AKIA|ASIA)[0-9A-Z]{16}(?![0-9A-Z])"#, placeholder),
        (#"(?<![A-Za-z0-9])(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}"#, placeholder),
        (#"(?<![A-Za-z0-9])github_pat_[A-Za-z0-9_]{22,}"#, placeholder),
        (#"(?<![A-Za-z0-9])xox[abprs]-[A-Za-z0-9-]{10,}"#, placeholder),
        (#"(?<![A-Za-z0-9])AIza[0-9A-Za-z_\-]{35}"#, placeholder),
        (#"(?<![A-Za-z0-9])eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#, placeholder),
        // Laravel's APP_KEY and other base64 keys.
        (#"base64:[A-Za-z0-9+/]{32,}={0,2}"#, "base64:" + placeholder),
        (#"(?i)(bearer\s+)[A-Za-z0-9._~+/\-]{16,}=*"#, "$1" + placeholder),
        // mysql://user:secret@host
        (#"(?<=://)([^\s/:@]+):([^\s/@]+)@"#, "$1:" + placeholder + "@"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// The text with every match replaced, and how many there were.
    public static func redact(_ text: String) -> (text: String, count: Int) {
        var text = text
        var count = 0
        for (regex, template) in rules {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.numberOfMatches(in: text, range: range)
            guard matches > 0 else { continue }
            count += matches
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
        }
        return (text, count)
    }
}
