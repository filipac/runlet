import Foundation
import Testing
@testable import RunletCore

/// #45: the chat's disclosure (context parts with switches, earlier turns, caps, and hidden
/// secrets), its conversation, `@` mentions, and Insert into Tab's text.
struct AIChatTests {
    static let editor = AIChatEditorContext(tabTitle: "Invoice", language: .php, code: "<?php\n\n$lines = [1999, 2500];\necho array_sum($lines);\n")

    static func draft(_ message: String = "Why is the total wrong?", conversation: AIChatConversation = AIChatConversation(),
                      editor: AIChatEditorContext? = editor, output: AIChatOutputContext? = nil, files: [AIChatFile] = [],
                      choice: AIChatContextChoice = AIChatContextChoice()) -> AIChatDraft {
        AIChatPrompt.draft(provider: .anthropic, model: "claude-opus-5-5", conversation: conversation, message: message,
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
        let tooLong = Self.draft(conversation: AIChatConversation(turns: turns))
        #expect(tooLong.problem?.hasPrefix("The conversation is too long to send again") == true)
        #expect(!tooLong.canSend)
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
