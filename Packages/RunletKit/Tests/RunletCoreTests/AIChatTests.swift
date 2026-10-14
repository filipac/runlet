import Foundation
import Testing
@testable import RunletCore

/// #45: the chat's disclosure (context parts with switches, earlier turns, caps, and hidden
/// secrets), its conversation, `@` mentions, and Insert into Tab's text.
struct AIChatTests {
    static let editor = AIChatEditorContext(tabTitle: "Invoice", language: .php, code: "<?php\n\n$lines = [1999, 2500];\necho array_sum($lines);\n")

    static func draft(_ message: String = "Why is the total wrong?", conversation: AIChatConversation = AIChatConversation(),
                      editor: AIChatEditorContext? = editor, output: AIChatOutputContext? = nil, files: [AIChatFile] = [],
                      choice: AIChatContextChoice = AIChatContextChoice(), provider: AIProvider = .anthropic, model: String = "claude-opus-5-5",
                      configured: Set<AIProvider> = [.anthropic]) -> AIChatDraft {
        AIChatPrompt.draft(provider: provider, model: model, configured: configured, conversation: conversation, message: message,
                           editor: editor, output: output, files: files, choice: choice)
    }

    static func answered(_ question: String, _ answer: String, state: AIChatTurn.State = .complete) -> AIChatTurn {
        AIChatTurn(question: question, context: [], sent: "## Message\n\n" + question, provider: .anthropic, model: "claude-opus-5-5",
                   answer: answer, state: state)
    }

    @Test func theMessageGoesLastWithTheContextOnItsSwitches() {
        let output = AIChatOutputContext(tabTitle: "Invoice", text: "4499", hasError: false)
        let file = AIChatFile(path: "app/Models/Order.php", content: .text("<?php\n\nclass Order {}\n"))
        let draft = Self.draft(output: output, files: [file], choice: AIChatContextChoice(includeEditor: true, includeOutput: false))
        #expect(draft.canSend)
        let parts = draft.disclosure.parts
        #expect(parts.map(\.id) == ["editor", "output", "file:app/Models/Order.php", "message"])
        #expect(parts[0].title == "The tab's PHP code (“Invoice”)")
        #expect(parts[0].text == "```php\n<?php\n\n$lines = [1999, 2500];\necho array_sum($lines);\n```")
        #expect(parts[0].isIncluded && !parts[1].isIncluded && parts[2].isIncluded)
        #expect(parts[3].text == "Why is the total wrong?")
        // Only what's switched on is sent, word for word, the message last.
        let message = draft.disclosure.message
        #expect(message.hasPrefix("## The tab's PHP code (“Invoice”)\n\n```php\n<?php"))
        #expect(!message.contains("4499"))
        #expect(message.contains("## app/Models/Order.php\n\n```php\n<?php\n\nclass Order {}\n```"))
        #expect(message.hasSuffix("## Message\n\nWhy is the total wrong?"))
        #expect(draft.contextParts.count == 3)
        #expect(draft.disclosure.instructions == AIChatPrompt.instructions)
        #expect(draft.disclosure.maxOutputTokens == AIChatLimits.maxOutputTokens)
    }

    @Test func aSelectionIsSentInsteadOfTheWholeTab() {
        var editor = Self.editor
        editor.selection = AIChatEditorContext.Selection(text: "echo array_sum($lines);", firstLine: 4, lastLine: 4)
        #expect(Self.draft(editor: editor).disclosure.parts[0].title == "The selected PHP code (line 4 of “Invoice”)")
        editor.selection = AIChatEditorContext.Selection(text: "$lines = [1999, 2500];\necho array_sum($lines);", firstLine: 3, lastLine: 4)
        let part = Self.draft(editor: editor).disclosure.parts[0]
        #expect(part.title == "The selected PHP code (lines 3–4 of “Invoice”)")
        #expect(part.text == "```php\n$lines = [1999, 2500];\necho array_sum($lines);\n```")
        // A blank selection is no selection; an empty tab and empty output are no parts at all.
        editor.selection = AIChatEditorContext.Selection(text: "  ", firstLine: 1, lastLine: 1)
        #expect(Self.draft(editor: editor).disclosure.parts[0].title == "The tab's PHP code (“Invoice”)")
        let empty = Self.draft(editor: AIChatEditorContext(tabTitle: "Scratch", language: .sql, code: "\n"),
                               output: AIChatOutputContext(tabTitle: "Scratch", text: " ", hasError: false))
        #expect(empty.disclosure.parts.map(\.id) == ["message"])
        let sql = Self.draft(editor: AIChatEditorContext(tabTitle: "Orders", language: .sql, code: "select 1"))
        #expect(sql.disclosure.parts[0].title == "The tab's SQL code (“Orders”)")
        #expect(sql.disclosure.parts[0].text.hasPrefix("```sql\n"))
    }

    @Test func anErrorIsNamedInTheOutputsTitle() {
        let output = AIChatOutputContext(tabTitle: "Invoice", text: "DomainException: Invoice line is negative", hasError: true)
        let part = Self.draft(output: output, choice: AIChatContextChoice(includeOutput: true)).disclosure.parts[1]
        #expect(part.title == "The last output, with its error (“Invoice”)")
        #expect(part.isIncluded)
        #expect(part.text == "```text\nDomainException: Invoice line is negative\n```")
    }

    @Test func earlierTurnsAreSentAgainOnlyWithAnAnswer() {
        var conversation = AIChatConversation(turns: [
            Self.answered("First?", "First answer."),
            Self.answered("Stopped?", "Half an ans", state: .stopped),
            Self.answered("Failed?", "", state: .failed(.overloaded(.anthropic, retryAfter: nil))),
            Self.answered("Stopped early?", "", state: .stopped),
            Self.answered("Long?", "Cut off here", state: .cutOff),
        ])
        #expect(conversation.history == [
            AIMessage(.user, "## Message\n\nFirst?"), AIMessage(.assistant, "First answer."),
            AIMessage(.user, "## Message\n\nStopped?"), AIMessage(.assistant, "Half an ans"),
            AIMessage(.user, "## Message\n\nLong?"), AIMessage(.assistant, "Cut off here"),
        ])
        let draft = Self.draft("And now?", conversation: conversation)
        #expect(draft.turnsNotSentAgain == 2)
        let request = draft.disclosure.request(stream: true)
        #expect(request.messages.count == 7)
        #expect(request.messages.last == AIMessage(.user, draft.disclosure.message))
        // Earlier turns count toward what's disclosed, and the consent covers them: a changed
        // history is a different request.
        #expect(draft.disclosure.characterCount > draft.disclosure.message.count + AIChatPrompt.instructions.count)
        let consent = AIConsent(approving: draft.disclosure)
        conversation.turns.removeFirst()
        #expect(!consent.covers(Self.draft("And now?", conversation: conversation).disclosure))
    }

    @Test func sendIsOffUntilTheMessageCanGo() {
        #expect(Self.draft("  \n").problem == "Type a message.")
        let streaming = AIChatConversation(turns: [Self.answered("First?", "Arriv", state: .streaming)])
        #expect(Self.draft(conversation: streaming).problem == "Wait for the answer, or stop it.")
        #expect(streaming.history.isEmpty)
        let reading = Self.draft(files: [AIChatFile(path: "app/Models/Order.php", content: .reading)])
        #expect(reading.problem == "Runlet is still reading the files the message mentions.")
        let long = String(repeating: "x", count: 30_000)
        let turns = (0..<8).map { Self.answered("Q\($0)", long) }
        // What's too long depends on the model: Claude Opus 5.5 reads 1M tokens, Claude Haiku
        // 4.5 200K, and neither offers to leave anything out of answers without attachments.
        #expect(Self.draft(conversation: AIChatConversation(turns: turns)).canSend)
        let haiku = Self.draft(conversation: AIChatConversation(turns: (0..<30).map { Self.answered("Q\($0)", long) }), model: "claude-haiku-4-5")
        #expect(haiku.problem?.hasPrefix("This is more than claude-haiku-4-5 reads at once") == true)
        #expect(haiku.problem?.hasSuffix("Send less, or start a new conversation.") == true)
        #expect(!haiku.canSend && !haiku.canLeaveOutAttachments)
    }

    @Test func filesAreCappedAndUnreadableOnesAreListed() {
        var files = (1...6).map { AIChatFile(path: "app/F\($0).php", content: .text("<?php // \($0)")) }
        files.insert(AIChatFile(path: ".env", content: .unavailable(ProjectFileError.secret.message)), at: 0)
        let draft = Self.draft(files: files, choice: AIChatContextChoice(excludedFiles: ["app/F2.php"]))
        let fileParts = draft.disclosure.parts.filter { $0.id.hasPrefix("file:") }
        #expect(fileParts.map(\.title) == ["app/F1.php", "app/F2.php", "app/F3.php", "app/F4.php", "app/F5.php"])
        #expect(fileParts.map(\.isIncluded) == [true, false, true, true, true])
        #expect(draft.unavailableFiles == [AIChatUnavailableFile(path: ".env", reason: ProjectFileError.secret.message),
                                           AIChatUnavailableFile(path: "app/F6.php", reason: "A message sends at most 5 files.")])
        #expect(draft.canSend)
        #expect(!draft.disclosure.message.contains("app/F2.php"))
        #expect(AIChatPrompt.fenceLanguage(path: "resources/views/home.blade.php") == "blade")
        #expect(AIChatPrompt.fenceLanguage(path: "config/app.php") == "php")
        #expect(AIChatPrompt.fenceLanguage(path: "README") == "")
    }

    @Test func longContextIsCutAndSecretsAreHidden() {
        let code = "<?php\n$key = 'sk-ant-api03-EXAMPLE-not-a-real-key-000000';\n" + String(repeating: "echo 1;\n", count: 5_000)
        let part = Self.draft(editor: AIChatEditorContext(tabTitle: "Keys", language: .php, code: code)).disclosure.parts[0]
        #expect(!part.text.contains("sk-ant-api03"))
        #expect(part.text.contains("$key = '[hidden by Runlet]';"))
        #expect(part.text.contains("more characters left out]"))
        #expect(part.note?.contains("Only the first") == true)
        #expect(part.note?.hasSuffix("Runlet hid 1 value that looks like a secret.") == true)
        #expect(part.text.count < AIChatLimits.maxPartCharacters + 100)
    }

    @Test func secretShapesAreHiddenAndCodeIsNot() {
        let samples = [
            "-----BEGIN RSA PRIVATE KEY-----\nMIIEow\n-----END RSA PRIVATE KEY-----",
            "OPENAI=sk-proj-abcdefghijklmnopqrstuvwxyz012345",
            "STRIPE=sk_live_abcdefghijklmnop1234",
            "AWS=AKIAABCDEFGHIJKLMNOP",
            "GH=ghp_abcdefghijklmnopqrstuvwxyz0123456789",
            "SLACK=xoxb-123456789012-abcdefghij",
            "G=AIzaSyA-abcdefghijklmnopqrstuvwxyz012345",
            "JWT=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijklmnopqrstuv",
            "APP_KEY=base64:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ=",
            "Authorization: Bearer abcdefghijklmnopqrstuvwxyz",
            "DATABASE_URL=mysql://shop:s3cret@db.example.com/shop",
        ]
        for sample in samples {
            let (text, count) = AISecretRedaction.redact(sample)
            #expect(count == 1, "\(sample) → \(text)")
            #expect(text.contains(AISecretRedaction.placeholder), "\(sample) → \(text)")
        }
        #expect(AISecretRedaction.redact("DATABASE_URL=mysql://shop:s3cret@db.example.com/shop").text == "DATABASE_URL=mysql://shop:[hidden by Runlet]@db.example.com/shop")
        #expect(AISecretRedaction.redact("Authorization: Bearer abcdefghijklmnopqrstuvwxyz").text == "Authorization: Bearer [hidden by Runlet]")
        for code in ["$task-runner = 1;", "User::where('email', 'alice@example.com')->first();", "https://example.com/orders", "$sk = 'sk-short';", "Http::withToken($token)"] {
            #expect(AISecretRedaction.redact(code) == (code, 0), "\(code)")
        }
    }

    @Test func mentionsAreProjectPaths() {
        let text = "Compare @app/Models/Order.php with @app/Models/User.php. Mail alice@example.com about @app/Models/Order.php, and @"
        #expect(AIChatMentions.paths(in: text) == ["app/Models/Order.php", "app/Models/User.php"])
        let mentions = AIChatMentions.mentions(in: text)
        #expect(mentions.map(\.path) == ["app/Models/Order.php", "app/Models/User.php", "app/Models/Order.php", ""])
        #expect((text as NSString).substring(with: mentions[1].range) == "@app/Models/User.php")
        // The mention being typed (the caret right after it) isn't one yet.
        let typing = "Look at @app/Mo"
        #expect(AIChatMentions.paths(in: typing, activeAt: (typing as NSString).length).isEmpty)
        #expect(AIChatMentions.paths(in: typing, activeAt: 3) == ["app/Mo"])
        #expect(AIChatMentions.paths(in: "@config/app.php ", activeAt: 16) == ["config/app.php"])
    }

    @Test func theMentionBeingTypedCompletes() throws {
        let text = "Look at @app/Mo"
        let active = try #require(AIChatMentions.active(in: text, cursor: (text as NSString).length))
        #expect(active.path == "app/Mo")
        #expect(active.range == NSRange(location: 8, length: 7))
        let completed = AIChatMentions.complete(text, mention: active, with: "app/Models/Order.php")
        #expect(completed.text == "Look at @app/Models/Order.php ")
        #expect(completed.caret == (completed.text as NSString).length)
        // A bare @ asks for any file; text after the caret keeps its space.
        let bare = "@ and more"
        let at = try #require(AIChatMentions.active(in: bare, cursor: 1))
        #expect(at.path.isEmpty)
        let inserted = AIChatMentions.complete(bare, mention: at, with: "routes/web.php")
        #expect(inserted.text == "@routes/web.php and more")
        #expect(inserted.caret == 16)
        #expect(AIChatMentions.active(in: "alice@example.com", cursor: 17) == nil)
        #expect(AIChatMentions.active(in: "@app/Models/User.php is it", cursor: 26) == nil)
        // A sentence's period after the path is typed too.
        #expect(AIChatMentions.active(in: "see @app.", cursor: 9)?.path == "app.")
    }

    @Test func insertingKeepsOneOpeningTag() {
        let block = "<?php\n\n$total = array_sum($charges);"
        // Over the whole tab, or into an empty one: as it is.
        #expect(AIChatInsertion.text(block, language: .php, document: "<?php\necho 1;", selection: NSRange(location: 0, length: 13)) == block)
        #expect(AIChatInsertion.text(block, language: .php, document: "", selection: NSRange(location: 0, length: 0)) == block)
        // At the caret among other code: without the tag, and a line break before the code
        // that follows on the same line.
        let document = "<?php\n\necho $total;\n"
        #expect(AIChatInsertion.text(block, language: .php, document: document, selection: NSRange(location: 7, length: 0)) == "$total = array_sum($charges);\n")
        #expect(AIChatInsertion.text(block, language: .php, document: document, selection: NSRange(location: 20, length: 0)) == "$total = array_sum($charges);")
        // Other languages keep everything.
        #expect(AIChatInsertion.text("select 1;", language: .sql, document: "select 2;", selection: NSRange(location: 9, length: 0)) == "select 1;")
        #expect(AIChatInsertion.displayLanguage("runlet-fix") == "php")
        #expect(AIChatInsertion.displayLanguage("") == nil)
    }

    @Test func aRunletFixBlockStaysCodeInTheChat() {
        let answer = "Leave refunds out:\n\n```runlet-fix\n<?php echo 1;\n```\n\nThat's it."
        let parsed = AIAnswer.parse(answer, extractingFix: false)
        #expect(parsed.fix == nil)
        #expect(parsed.blocks == [.text("Leave refunds out:"), .code(language: "runlet-fix", "<?php echo 1;", isOpen: false), .text("That's it.")])
        #expect(AIAnswer.parse(answer).fix == "<?php echo 1;")
        let conversation = AIChatConversation(turns: [Self.answered("Fix?", answer), Self.answered("Thanks", "You're welcome.")])
        #expect(conversation.lastCodeBlock == nil)
        #expect(AIChatConversation(turns: [Self.answered("Fix?", answer)]).lastCodeBlock == "<?php echo 1;")
    }

    @Test func theChatGoesOnlyToAProviderWithAKey() {
        var settings = AppSettings()
        let both: Set<AIProvider> = [.anthropic, .openai]
        // Without a choice of its own, the chat follows Settings ▸ AI.
        #expect(AIChatDestination.resolve(settings, configured: both) == AIChatDestination(provider: .anthropic, model: "claude-opus-5-5"))
        // Its own choice, which leaves Settings ▸ AI as it is.
        settings.aiChatProvider = .openai
        settings.setAIChatModel("gpt-6-luna", for: .openai)
        #expect(AIChatDestination.resolve(settings, configured: both) == AIChatDestination(provider: .openai, model: "gpt-6-luna"))
        #expect(settings.aiProvider == .anthropic && settings.aiModel(for: .openai) == "gpt-6-astra")
        // OpenAI's key is removed: the chat goes to the provider that still has one, and back
        // to its choice once the key is saved again.
        #expect(AIChatDestination.resolve(settings, configured: [.anthropic]) == AIChatDestination(provider: .anthropic, model: "claude-opus-5-5"))
        #expect(AIChatDestination.resolve(settings, configured: both)?.provider == .openai)
        settings.aiProvider = .openai
        settings.aiChatProvider = nil
        #expect(AIChatDestination.resolve(settings, configured: [.anthropic])?.provider == .anthropic)
        // No key at all: nowhere.
        #expect(AIChatDestination.resolve(settings, configured: []) == nil)
        // The picker lists both; the one without a key says how to add it.
        let choices = AIChatDestination.choices(configured: [.anthropic])
        #expect(choices.map(\.provider) == [.anthropic, .openai])
        #expect(choices.map(\.unavailable) == [nil, "Add a key in Settings ▸ AI"])
        settings.setAIChatModel(nil, for: .openai)
        #expect(settings.aiChatModel(for: .openai) == "gpt-6-astra")
    }

    @Test func aProviderWithoutAKeyIsNeverSentTo() async {
        let draft = Self.draft(provider: .openai, model: "gpt-6-astra", configured: [.anthropic])
        #expect(draft.problem == "Add an OpenAI key in Settings ▸ AI to chat with OpenAI.")
        #expect(!draft.canSend)
        #expect(Self.draft(configured: []).problem == "Add an Anthropic key in Settings ▸ AI to chat with Anthropic.")
        // Even past the draft, the client refuses before a byte goes out.
        let transport = FakeAITransport([])
        var error: Error?
        do {
            for try await _ in AIClient(transport: transport).stream(draft.disclosure, consent: AIConsent(approving: draft.disclosure), key: nil) {}
        } catch let caught {
            error = caught
        }
        #expect(error as? AIError == .missingKey(.openai))
        #expect(transport.requests.isEmpty)
    }

    @Test func switchingProvidersSendsEarlierTurnsAsPlainText() throws {
        var first = Self.answered("Why is the total wrong?", "Refunds throw.\n\n```php\necho 1;\n```")
        first.answeringModel = "claude-opus-5-5"
        let conversation = AIChatConversation(turns: [first])
        let draft = Self.draft("And in dollars?", conversation: conversation, editor: nil, provider: .openai, model: "gpt-6-astra",
                               configured: [.anthropic, .openai])
        #expect(draft.canSend)
        #expect(draft.disclosure.provider == .openai && draft.disclosure.model == "gpt-6-astra")
        let request = draft.disclosure.request(stream: true)
        #expect(request.messages == [AIMessage(.user, first.sent), AIMessage(.assistant, first.answer), AIMessage(.user, "## Message\n\nAnd in dollars?")])
        // OpenAI gets plain role-and-text messages: nothing of Anthropic's, such as thinking.
        let body = try #require(try JSONSerialization.jsonObject(with: AIEndpoint.body(request)) as? [String: Any])
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.map { Set($0.keys) } == Array(repeating: ["role", "content"], count: 3))
        #expect(input.map { $0["content"] is String } == [true, true, true])
        let text = String(decoding: try AIEndpoint.body(request), as: UTF8.self)
        for opaque in ["thinking", "signature", "fallbacks", "claude-opus"] { #expect(!text.contains(opaque), "\(opaque)") }
        #expect(body["model"] as? String == "gpt-6-astra")
    }

    /// A conversation with context in its first message: the tab's code went with it.
    static func conversation(by provider: AIProvider, model: String) -> AIChatConversation {
        let first = Self.draft("Why is the total wrong?", provider: provider, model: model, configured: [provider])
        let turn = AIChatTurn(question: "Why is the total wrong?", context: first.contextParts.map(\.title), sent: first.disclosure.message,
                              provider: provider, model: model, answer: "Refunds throw.", state: .complete, messagePart: "## Message\n\nWhy is the total wrong?")
        return AIChatConversation(turns: [turn])
    }

    /// The exact request body a draft sends, as JSON.
    static func body(_ draft: AIChatDraft) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: AIEndpoint.body(draft.disclosure.request(stream: true))) as? [String: Any])
    }

    @Test(arguments: [(AIProvider.anthropic, "claude-opus-5-5", AIProvider.openai, "gpt-6-astra"),
                      (AIProvider.openai, "gpt-6-astra", AIProvider.anthropic, "claude-opus-5-5"),
                      (AIProvider.anthropic, "claude-opus-5-5", AIProvider.anthropic, "claude-haiku-5-5")])
    func aSwitchSendsTheWholeConversationAsPlainText(from: AIProvider, fromModel: String, to: AIProvider, toModel: String) throws {
        let conversation = Self.conversation(by: from, model: fromModel)
        let draft = Self.draft("And in dollars?", conversation: conversation, provider: to, model: toModel, configured: [.anthropic, .openai])
        #expect(draft.canSend)
        #expect(draft.switchedFrom == AIChatDestination(provider: from, model: fromModel))
        #expect(draft.historyCharacters == conversation.turns[0].sent.count + "Refunds throw.".count)
        let body = try Self.body(draft)
        #expect(body["model"] as? String == toModel)
        let messages = try #require(body[to == .anthropic ? "messages" : "input"] as? [[String: Any]])
        // Every earlier message with what went with it (the tab's code), the answer as plain
        // assistant text, and the new message: plain role-and-text entries only.
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        #expect(messages.map { Set($0.keys) } == Array(repeating: ["role", "content"], count: 3))
        let earlier = try #require(messages[0]["content"] as? String)
        #expect(earlier.contains("## The tab's PHP code (“Invoice”)") && earlier.contains("echo array_sum($lines);"))
        #expect(earlier.hasSuffix("## Message\n\nWhy is the total wrong?"))
        #expect(messages[1]["content"] as? String == "Refunds throw.")
        #expect((messages[2]["content"] as? String)?.hasSuffix("## Message\n\nAnd in dollars?") == true)
        // Nothing tied to the model that wrote the answer, and no stored server-side state.
        let text = String(decoding: try AIEndpoint.body(draft.disclosure.request(stream: true)), as: UTF8.self)
        for opaque in ["thinking", "signature", "redacted", "reasoning_item", "encrypted", "previous_response_id", "rs_"] {
            #expect(!text.contains(opaque), "\(opaque)")
        }
        if to == .openai { #expect(body["store"] as? Bool == false) }
        // Once the new model answered, the next message isn't a switch.
        var answered = conversation
        answered.turns.append(AIChatTurn(question: "And in dollars?", context: [], sent: draft.disclosure.message, provider: to, model: toModel,
                                         answer: "$41.99", state: .complete))
        #expect(Self.draft("Thanks", conversation: answered, provider: to, model: toModel, configured: [.anthropic, .openai]).switchedFrom == nil)
        // Without a switch there's no note either.
        #expect(Self.draft("Again?", conversation: conversation, provider: from, model: fromModel, configured: [from]).switchedFrom == nil)
    }

    @Test func aConversationTooLongForTheModelSaysSoAndCanLeaveOutAttachments() throws {
        // gpt-4o reads 128,000 tokens: about 384,000 characters with the answer's room.
        let code = String(repeating: "$total += 1;\n", count: 1_500)
        let editor = AIChatEditorContext(tabTitle: "Invoice", language: .php, code: code)
        var conversation = AIChatConversation()
        for index in 0..<30 {
            let draft = Self.draft("Q\(index)", conversation: conversation, editor: editor, provider: .openai, model: "gpt-4o", configured: [.openai])
            conversation.turns.append(AIChatTurn(question: "Q\(index)", context: draft.contextParts.filter(\.isIncluded).map(\.title), sent: draft.disclosure.message,
                                                 provider: .openai, model: "gpt-4o", answer: "A\(index)", state: .complete, messagePart: "## Message\n\nQ\(index)"))
        }
        let tooLong = Self.draft("And now?", conversation: conversation, editor: editor, provider: .openai, model: "gpt-4o", configured: [.openai])
        let overflow = try #require(tooLong.overflow)
        #expect(overflow.limit == 128_000 && overflow.tokens > overflow.limit)
        #expect(!tooLong.canSend && tooLong.canLeaveOutAttachments)
        #expect(tooLong.problem?.hasPrefix("This is more than gpt-4o reads at once") == true)
        #expect(tooLong.problem?.contains("Leave out what was sent with earlier messages") == true)
        // The same conversation fits a model that reads more.
        #expect(Self.draft("And now?", conversation: conversation, editor: editor, provider: .openai, model: "gpt-6-astra", configured: [.openai]).canSend)

        // Leaving out attachments, oldest first, until it fits; never silently.
        var trimmed = conversation
        let changed = trimmed.leaveOutAttachments { tooLong.fits(with: $0) }
        #expect(changed > 0 && changed < 30)
        let leftOut = trimmed.turns.prefix(changed).filter { $0.attachmentsLeftOut }.count
        #expect(leftOut == changed)
        #expect(!trimmed.turns[changed].attachmentsLeftOut)
        #expect(trimmed.turns[0].sentAgain == "## Message\n\nQ0\n\n[Runlet left out what was sent with this message: The tab's PHP code (“Invoice”).]")
        #expect(trimmed.history[0] == AIMessage(.user, trimmed.turns[0].sentAgain))
        #expect(trimmed.history[1] == AIMessage(.assistant, "A0"))
        let fits = Self.draft("And now?", conversation: trimmed, editor: editor, provider: .openai, model: "gpt-4o", configured: [.openai])
        #expect(fits.canSend && fits.overflow == nil)
        #expect(fits.disclosure.history.first?.text.contains("[Runlet left out") == true)
    }

    @Test func settingsKeepTheChatsChoiceAndOlderFilesLoad() throws {
        var settings = AppSettings()
        #expect(settings.aiChatProvider == nil)
        settings.aiChatProvider = .openai
        settings.setAIChatModel("gpt-6.1-sol", for: .openai)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.aiChatProvider == .openai)
        #expect(decoded.aiChatModel(for: .openai) == "gpt-6.1-sol")
        #expect(decoded.aiChatModel(for: .anthropic) == "claude-opus-5-5")
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"aiProvider": "openai"}"#.utf8))
        #expect(old.aiChatProvider == nil && old.aiChatModel(for: .openai) == "gpt-6-astra")
        let odd = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"aiChatProvider": "gemini", "aiChatAnthropicModel": "", "aiChatOpenAIModel": 3}"#.utf8))
        #expect(odd.aiChatProvider == nil)
        #expect(odd.aiChatModel(for: .anthropic) == "claude-opus-5-5" && odd.aiChatModel(for: .openai) == "gpt-6-astra")
    }

    @Test func explainOrFixContinuesAsAFirstTurn() {
        let disclosure = AIDisclosure(provider: .openai, model: "gpt-6-astra", instructions: "Explain.",
                                      parts: [AIDisclosurePart(id: "error", title: "The error", text: "Boom"),
                                              AIDisclosurePart(id: "source", title: "The source", text: "secret", isIncluded: false)],
                                      maxOutputTokens: 100)
        let turn = AIChatPrompt.continuing(disclosure, answer: "It failed.", answeringModel: "gpt-6-astra", title: "Explain or Fix: DomainException")
        #expect(turn.sent == "## The error\n\nBoom")
        #expect(turn.context == ["The error"])
        #expect(turn.isSentAgain)
        #expect(AIChatConversation(turns: [turn]).history == [AIMessage(.user, "## The error\n\nBoom"), AIMessage(.assistant, "It failed.")])
    }
}
