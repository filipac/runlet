# AI Assistance

Runlet can ask an AI model why a run failed and how to fix it, and chat with one about your code, with your own Anthropic or OpenAI API key. You see exactly what would be sent before anything leaves your Mac, nothing is sent until you click **Send**, and Runlet never runs code a model writes.

## Providers and Keys

Runlet works with two providers. You bring the API key: requests go straight from your Mac to the provider, and the provider bills your account. Runlet has no account or subscription of its own.

| Provider | Default model | Get a key |
| --- | --- | --- |
| **Anthropic** | Claude Opus 5.5 (`claude-opus-5-5`) | [platform.claude.com](https://platform.claude.com/settings/keys) |
| **OpenAI** | GPT-6 Astra (`gpt-6-astra`) | [platform.openai.com](https://platform.openai.com/api-keys) |

To add a key:

1. Open **Settings ▸ AI**, or choose **Runlet ▸ AI Settings…**.
2. Paste the key into the provider's **API key** field and click **Save Key**.
3. Click **Test Key**. Runlet asks the provider which models the key can use, which sends the key and nothing else. "The key works" means you're set.

**Send to** at the top of the pane picks the provider that AI features use. You can save a key for each and switch between them.

![Settings ▸ AI with a saved Anthropic key shown masked, a note that the key works, the model and reasoning level for each provider, and the privacy rules](screenshots/ai/settings-light.webp#gh-light-mode-only)
![Settings ▸ AI with a saved Anthropic key shown masked, a note that the key works, the model and reasoning level for each provider, and the privacy rules](screenshots/ai/settings-dark.webp#gh-dark-mode-only)

### Where Keys Are Kept

- **In your Mac's Keychain,** never in Runlet's files or settings. Keychain Access lists them as "Runlet AI key: Anthropic" and "Runlet AI key: OpenAI", each with its masked form.
- **Masked once saved.** Settings shows only the start and the last four characters, such as `sk-ant-…Q2c4`. To change a key, remove it and save the new one.
- **Remove Key…** deletes it from the Keychain. The key itself keeps working at the provider until you revoke it there.
- **Never in a message.** When a provider rejects a key, Runlet says so without repeating it.

After an update, macOS may ask once before Runlet can read a key it saved. Choose **Always Allow**.

### Choosing a Model

Each provider has a **Model** setting. Before you test the key, it offers the provider's current models; after **Test Key**, it lists the ones your account can use, newest first. When the model you chose isn't in that list, Settings warns you.

Larger models explain more carefully and cost more. Smaller ones, such as Claude Haiku 5.5 or GPT-6 Luna, are cheaper and faster. Each provider's pricing page has the prices.

### Choosing a Reasoning Level

Current models think before they answer, and the **Reasoning** setting under each provider's model says how hard. **Default** sends no level, so the model uses its own default; the other choices are the levels that model takes:

| Provider | Levels | Models without one |
| --- | --- | --- |
| **Anthropic** | Low, Medium, High, Extra High, and Max on the current models; Claude Opus 4.6 and Sonnet 4.6 have no Extra High, and Claude Opus 4.5 goes up to High | Claude Haiku 4.5, Sonnet 4.5, and older |
| **OpenAI** | Low to Max on GPT-6 Astra and GPT-6.1 Sol; GPT-6 Luna and GPT-5.5 also take None | GPT-4.1, GPT-4o, and the chat models |

Higher levels take longer and cost more, since the thinking is billed as output. When you switch to a model that doesn't take the level you chose, Runlet sends none. Explain or Fix uses this setting; the chat can choose its own.

## What Is Sent, and When

Every AI feature follows the same rules:

- **Nothing is sent on its own.** Opening a sheet, a run that fails, or an error card sends nothing. A request leaves your Mac only when you click **Send**.
- **You see exactly what's sent:** the provider, the model, every part of the message with a checkbox, and the instructions Runlet adds. Only the parts you leave checked are sent, word for word as shown.
- **Only what the feature shows.** Your other tabs, files you don't name, history, the run inspector's records, saved passwords, and environment values are never sent.
- **Generated code never runs.** A proposed change goes into your tab only when you apply or insert it, and running it is your **Run**, with [production's confirmation](environments.md) as always.

Runlet asks OpenAI not to keep the response for later retrieval. Each provider's own data policy applies to what you send.

## Explain or Fix an Error

When a run fails, the error card has an **Explain or Fix…** button. You can also choose **Run ▸ Explain or Fix Error…** for the tab's last error, or find it in Open Anything.

![The Explain or Fix sheet before sending: the error and the tab's code checked, the source where it was thrown unchecked, where the request goes, and Send to Anthropic](screenshots/ai/explain-disclosure-light.webp#gh-light-mode-only)
![The Explain or Fix sheet before sending: the error and the tab's code checked, the source where it was thrown unchecked, where the request goes, and Send to Anthropic](screenshots/ai/explain-disclosure-dark.webp#gh-dark-mode-only)

The sheet first shows what it would send, in three parts:

| Part | What it holds | Checked |
| --- | --- | --- |
| **The error** | The exception's class and message, where it happened, its cause, and up to 12 frames of the stack trace. Paths are relative to your project. | Yes |
| **The tab's code** | The whole tab, as it was when you opened the sheet. | Yes |
| **The source where it was thrown** | About 30 lines around the line in a project or vendor file, when the error was thrown outside your tab. | No: it's your project's code |

Below them, it says where the request goes, with the model and its size in characters. Uncheck what you'd rather not send, then click **Send to Anthropic** (or **OpenAI**).

The answer appears as the model writes it. **Stop** (<kbd>⌘</kbd><kbd>.</kbd>) ends the request and keeps what arrived, marked as incomplete.

### Applying a Fix

When changing your tab's code fixes the error, the answer ends with a proposed fix, shown as a diff of your tab: removed lines in red, added lines in green.

![Anthropic's explanation of the error, with the proposed fix as a diff of the tab and the Apply Fix button](screenshots/ai/explain-fix-light.webp#gh-light-mode-only)
![Anthropic's explanation of the error, with the proposed fix as a diff of the tab and the Apply Fix button](screenshots/ai/explain-fix-dark.webp#gh-dark-mode-only)

- **Apply Fix** replaces the tab's code with the fix, as one undoable edit. Nothing runs, and [sandbox auto-run](sandbox-auto-run.md) turns off for the tab.
- **Undo Apply Fix**, or **Edit ▸ Undo** in the editor, puts the old code back.
- **The tab changed?** If you edited the tab after asking, **Apply Fix** refuses, since the fix may no longer fit. Close the sheet and click **Explain or Fix…** again to send the code as it is now.
- **No fix?** When the cause is elsewhere (a project file, the database, the environment), the model says what to change instead, and the sheet notes that it proposed no change.

**Copy Answer** copies the whole answer as Markdown. **Ask Again…** goes back to what's sent, so you can check or uncheck parts and send again.

### Without a Key

Without a key for the chosen provider, the sheet still shows what it would send, says that no key is saved, and offers **Open AI Settings…**, which opens **Settings ▸ AI** and leaves the sheet where it is. **Send** stays off until you save a key.

## Chatting About Your Code

The chat sits in the panel next to the editor, beside History, Snippets, Commands, and Database. Ask about the tab's code, its last output, or a file of your project, follow up on the answer, and insert the code it suggests into the tab.

Open it with **Library ▸ Show/Hide Chat** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>I</kbd>), or pick **Chat** at the top of the panel.

![The chat: a question about the tab that names a project file with @, the answer with a code block and its Copy and Insert into Tab buttons, a follow-up and its answer, and what the next message would send](screenshots/ai/chat-light.webp#gh-light-mode-only)
![The chat: a question about the tab that names a project file with @, the answer with a code block and its Copy and Insert into Tab buttons, a follow-up and its answer, and what the next message would send](screenshots/ai/chat-dark.webp#gh-dark-mode-only)

### Asking

Type your question, then click **Send** or press <kbd>⌘</kbd><kbd>Return</kbd>. <kbd>Return</kbd> starts a new line, and <kbd>Esc</kbd> goes back to the editor.

The answer appears as the model writes it. **Stop** (<kbd>⌘</kbd><kbd>.</kbd>) ends it and keeps what arrived. While a run is going on in the tab, <kbd>⌘</kbd><kbd>.</kbd> stops the run unless the message field has the keyboard.

Each message continues the conversation: Runlet sends the earlier messages and their answers again, so the model knows what you're following up on. The pencil button at the top, **New Conversation**, starts over. A message that got no answer (it failed, or you stopped it before any text arrived) stays in the list, and isn't sent again.

### Choosing the Provider, Model, and Reasoning

Under the message field, the chat shows where your next message goes, such as **Anthropic · Claude Opus 5.5** and the reasoning level next to it. Click either to change it; **Library ▸ Chat ▸ Choose Chat Model…** and **Choose Chat Reasoning…** open them too, and **Chat With Anthropic** and **Chat With OpenAI** are in the command palette (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>P</kbd>).

- **Only providers with a key.** A provider without a key in [Settings ▸ AI](#providers-and-keys) is listed but can't be chosen, with how to add one, and the chat never sends to it. If you remove the key of the provider the chat uses, it goes on with the other one; with no key at all, it shows the notice below.
- **The models** are the ones Settings ▸ AI lists for the provider: your account's own after **Test Key**. The reasoning levels are the ones the model takes, and **Default** sends none.
- **The chat's own choice.** It starts from Settings ▸ AI's provider, model, and level, and what you choose here stays for the chat, also after you quit Runlet, without changing Settings ▸ AI.
- **It applies to the next message.** Each answer says who wrote it, and how hard it thought: "Anthropic · Claude Opus 5.5 · effort high". The line below the field names the exact model and level the next message goes to: "To Anthropic · claude-opus-5-5 · effort high · 2,275 characters".

### Switching Mid-Conversation

You can switch to another provider or model at any point. The new one gets the whole conversation as text, with the code, output, and files that went with each earlier message, and goes on as if it had been there all along. What a model keeps for itself, such as its thinking, never goes to another one; the conversation doesn't need it.

Before the first message after a switch, a note says that the whole conversation goes to the new model, and how long it is. The new model reads all of it again, so it's billed again: nothing carries over from the provider or model you switched from.

### Long Conversations

Each model reads only so much at once, its context window: about 1 million tokens for current Claude and GPT-6 models, less for older ones. When the conversation and your message are more than the chosen model reads, the chat says so before sending, and **Send** stays off. Runlet never cuts a conversation short on its own. Instead you can:

- click **Leave Out Earlier Attachments**: later messages send your earlier questions and the answers, but not the code, output, and files that went with them, oldest first, until it fits. A note takes their place, so the model knows something was left out;
- uncheck what goes with this message, or start a new conversation;
- choose a model that reads more.

### What Goes With a Message

Under **Sent with the message**, above the field, the chat lists everything it would send with your message. The arrow next to each part shows its exact text.

| Part | What it holds | Checked |
| --- | --- | --- |
| **The tab's code** | The current tab's code, or only the selected lines when you've selected some. | Yes |
| **The last output** | Everything the tab's last run printed, with its error. Paths are relative to your project. | No |
| **A file you name** | The text of a project file you mention with `@`. | Yes |
| **Earlier messages** | The conversation so far, as it was sent, with the answers. | Always |
| **Instructions Runlet adds** | What Runlet tells the model about itself and how to answer. | Always |

Uncheck what you'd rather not send. The checkboxes stay as you set them for the next message. Below the field, the chat says where the request goes and how long it is: "To Anthropic · 2,275 characters". To keep a conversation short, and cheaper, uncheck the tab's code once the model has seen it, or start a new conversation.

![The message field with a question that names app/Services/InvoiceTotals.php, and above it what would be sent: the tab's code, the last output with its error, and the file, opened to show its exact text](screenshots/ai/chat-disclosure-light.webp#gh-light-mode-only)
![The message field with a question that names app/Services/InvoiceTotals.php, and above it what would be sent: the tab's code, the last output with its error, and the file, opened to show its exact text](screenshots/ai/chat-disclosure-dark.webp#gh-dark-mode-only)

### Project Files

Type `@` and part of a file's name, and the chat suggests files of the tab's project. <kbd>↑</kbd> and <kbd>↓</kbd> choose one, and <kbd>Tab</kbd> or <kbd>Return</kbd> adds it; <kbd>Esc</kbd> closes the suggestions. The **@** button below the field starts a mention too.

```text
Why does @app/Services/InvoiceTotals.php throw for this invoice?
```

The file's text goes with the message, as Runlet read it when you mentioned it. The rules:

- **Only the tab's project.** Files come from the tab's project folder: a local project, or the local folder of a Docker or SSH profile. A sandbox tab has none.
- **Nothing outside it.** Absolute paths, `..`, and links that lead out of the folder are refused.
- **Never secrets.** `.env` files (but `.env.example` is fine), keys and certificates, credentials files such as `auth.json`, and anything in `.git` are never sent.
- **Text only, and not too much.** Files up to 1 MB that are text; Runlet sends the first 20,000 characters of each, and at most 5 files with a message.
- **Suggestions skip `vendor` and `node_modules`.** Type a package file's whole path to send it anyway: `@vendor/laravel/framework/src/Illuminate/Collections/Collection.php`.

A file that can't be sent stays in your message as text, and the list says why it isn't sent.

### Hidden Secrets

Before the chat shows the tab's code, its output, or a file, it hides values that look like secrets: private keys, API keys and tokens of well-known services (OpenAI and Anthropic, Stripe, AWS, GitHub, Slack, Google), Laravel's `APP_KEY`, JSON web tokens, bearer tokens, and passwords in URLs. Each becomes `[hidden by Runlet]`, and the part says how many it hid. The message you type isn't changed.

> [!WARNING]
> Hiding secrets is a safety net, not a guarantee: a password in a variable looks like any other string. Open the parts and check them before you send code that handles credentials.

### Using an Answer

Each code block in an answer has two buttons:

- **Insert into Tab** puts the code at the cursor in the current tab, or over the selection, as one edit that **Edit ▸ Undo Insert into Tab** (<kbd>⌘</kbd><kbd>Z</kbd>) takes back. In a PHP tab that has other code, the block's opening `<?php` tag is left out. Nothing runs, and [sandbox auto-run](sandbox-auto-run.md) turns off for the tab.
- **Copy** copies the code.

**Copy** next to the model's name copies the whole answer as Markdown. **Library ▸ Chat ▸ Insert Chat Code into Tab** inserts the last answer's last code block.

### Conversations Aren't Kept

Each window has a conversation of its own, in memory only. Closing the window or quitting Runlet ends it: Runlet never writes conversations to disk, because they hold your code, your runs' output, and your project's files. Each provider's own data policy applies to what you sent.

### Continuing From Explain or Fix

When [Explain or Fix](#explain-or-fix-an-error) has answered, **Continue in Chat** adds its question and answer to the window's chat and opens it, so you can follow up there. Nothing is sent until you send a message.

### Chat Without a Key

Without a key for either provider, the chat shows the same notice as the sheet, with **Open AI Settings…**, and **Send** stays off. When a message fails, the answer says why, with **Try Again**, which sends the same message and context again, and **Open AI Settings…** when the key or the model is the problem.

## When Something Goes Wrong

Each failure says what happened and what to do next.

| Message | What to do |
| --- | --- |
| Anthropic (or OpenAI) didn't accept the key | Check the key in **Settings ▸ AI** and click **Test Key**, or create a new one. |
| Is limiting requests | Wait the time it names, then click **Try Again**. |
| Is overloaded | Try again in a minute, or choose another model. |
| Needs billing set up | Add credits or a payment method in your provider account. |
| Doesn't offer the model | Choose another model; **Test Key** lists the ones your key can use. |
| The model declined to answer | The provider's safety checks stopped the request. Leave out part of the code, then try again. Anthropic first retries a declined request on another model by itself; the sheet says when that happened. |
| Couldn't reach the provider | Check your internet connection, then **Try Again**. |
| The answer is cut off | It reached its length limit. Ask again with less code. |

## For developers

AI providers are [#368](https://github.com/filipac/runlet/issues/368); Explain or Fix This Error is [#44](https://github.com/filipac/runlet/issues/44); the chat is [#45](https://github.com/filipac/runlet/issues/45). Inline completion ([#46](https://github.com/filipac/runlet/issues/46)) is meant to build on the same layer. Apple's on-device models aren't part of it yet.

| Piece | Where |
| --- | --- |
| Providers, defaults, what each model id accepts (`AIModelTraits`), masked keys and their Keychain label | `RunletCore/AIProvider.swift` |
| Request building (`AIEndpoint`), `AIRequest`, `AIMessage` | `RunletCore/AIRequest.swift` |
| Server-sent events (`SSEDecoder`), both providers' streams (`AIStreamDecoder`), whole answers and model lists (`AIResponseParser`) | `RunletCore/AIStream.swift` |
| `AIError` with its alert text, HTTP and stream error mapping, `retry-after`, key scrubbing (`AIRedaction`) | `RunletCore/AIError.swift` |
| The shared privacy rules: `AIDisclosure`, `AIDisclosurePart`, `AIConsent`, `AITextLimit` | `RunletCore/AIPrivacy.swift` |
| `AIClient` (stream, whole answer, models) and `URLSessionAITransport` | `RunletCore/AIClient.swift` |
| Explain or Fix: the prompt, the disclosure, answer parsing (`AIAnswer`, the `runlet-fix` block), `LineDiff` | `RunletCore/ExplainError.swift` |
| Keys, Test Key, models, and the one place features send (`streamAI`) | `Runlet/App/AppModel+AI.swift` |
| The sheet's session, Send, Stop, Apply Fix, Undo Apply Fix | `Runlet/App/AppModel+ExplainError.swift` |
| Views | `Runlet/Features/AISettingsView.swift`, `ExplainErrorSheet.swift`, the button in `ErrorCard` (`OutputPane.swift`), and the no-key notice both share, `AIMissingKeyNotice.swift` |
| The chat: its conversation and turns (`AIChatConversation`, `AIChatTurn`), the disclosure of the next message (`AIChatPrompt.draft`, with `AIChatLimits`), `@` mentions (`AIChatMentions`), Insert into Tab's text (`AIChatInsertion`), and hidden secrets (`AISecretRedaction`) | `RunletCore/AIChat.swift` |
| `@` files: resolving a mention inside the project, reading it, listing and ranking the project's files | `RunletCore/ProjectFiles.swift` |
| The chat's session per window (`AIChatSession`, `AIChatLiveAnswer`), context, Send, Stop, Try Again, Insert into Tab, Continue in Chat | `Runlet/App/AppModel+AIChat.swift` |
| The chat's pane and its message field (`AIChatMessageField`, an `NSTextView`) | `Runlet/Features/AIChatPane.swift` |

- **The APIs**, as documented in October 2026. Anthropic: `POST /v1/messages` with `x-api-key` and `anthropic-version: 2023-06-01`, `stream: true`, no `thinking` (current models think adaptively), `output_config.effort` only for models that take it, and `fallbacks: "default"` with `anthropic-beta: server-side-fallback-2026-07-01` for the models whose safety classifiers can decline (Claude Opus 5.5, Opus 5, Sonnet 5.5, Fable 5.1), so a declined request is retried on Anthropic's recommended model; an account that rejects that beta gets the same request once more without it. A `refusal` stop reason drops the partial answer. OpenAI: the Responses API, `POST /v1/responses` with `Authorization: Bearer`, `instructions`, `input`, `max_output_tokens`, `stream: true`, `store: false`, and `reasoning.effort` only for reasoning models. Both list models with `GET /v1/models`. Explain or Fix asks for medium effort and at most 16,000 output tokens, thinking included.
- **The defaults** are each provider's own recommended starting model. A cheaper default would be a silent downgrade; the choice is the user's.
- **Keys:** the Keychain service `dev.runlet.Runlet.ai` (with a hash of the data folder for a scratch `RUNLET_DATA_DIR`), one fixed account per provider (`AIProvider.keychainAccount`), labelled with the masked key so Settings can show it without reading the secret. The key is a `SensitiveString`, goes only into a request header, and is scrubbed from provider messages; a 401's message isn't kept at all. Settings files hold only `aiProvider`, `aiAnthropicModel`, and `aiOpenAIModel`, and older files load with the defaults. Debug builds with a scratch `RUNLET_DATA_DIR` keep keys in memory (`RUNLET_CREDENTIALS=keychain` overrides).
- **Consent:** `AIClient.stream` and `complete` refuse a disclosure that differs from what `AIConsent` approved, or that has nothing checked (`AIError.notConfirmed`), before sending anything. Only a Send button's action makes a consent.
- **Debug builds only:** `RUNLET_AI_BASE_URL` sends both providers' requests to another base URL, such as the stand-in `Tests/Fixtures/ai-stub/router.php` under `php -S 127.0.0.1:<port>`, which streams canned answers shaped like both providers' events (`RUNLET_AI_STUB_SCENARIO`, `RUNLET_AI_STUB_LOG`). Release builds ignore the variable. The debug steps are in `Runlet/App/AIDebugSteps.swift`. `scripts/ai_stub.py` starts the stand-in and holds the scratch data both screenshot scripts use: `scripts/ai-screenshots.py` checks the whole flow against it and takes the pull request's screenshots, and `scripts/docs-screenshots.py ai` takes this page's (the sheet alone, with `shot:<name>@sheet`, since the error card behind it shows the project's full path).
- **The answer and the fix:** the instructions ask for the whole corrected code in a `runlet-fix` block, and to refer to it as the proposed fix below rather than write the code twice. The sheet takes the block out of the answer and shows it as the diff; a block in the middle of the answer leaves a note ("The proposed fix is below.") in its place (`AIAnswer.Block.fixMoved`).
- **Opening Settings** goes through `SettingsWindow.open(selecting:)`, which chooses the app menu's Settings… item as ⌘, does: `NSApp.sendAction(showSettingsWindow:)` opens nothing on current macOS, with or without a sheet in front. The palette's Settings…, the mail chip's and the editor's links, and ⌥⌘, use it too.
- **The chat's place:** a pane of the trailing column (`AppModel.InspectorPane.chat`), not a column of its own. It shares the column's toggle, width, and resize handle, and keeps the window's layout to editor, output, and one side panel; the conversation lives on the window's model, so switching panes or tabs keeps it, and an answer goes on streaming meanwhile. A sheet would block the editor, and a popover closes on a click. Show/Hide Chat (`library.toggleChat`, ⇧⌘I) shows it, or hides the column when it shows the chat.
- **Conversations are kept per window, in memory** (`WindowModel.chat`), like the terminals: never in `State/*.json`. They hold code, output, and project files, which Runlet otherwise keeps out of its files (history keeps code, never output). Tinkerwell's chat is per session too.
- **Where messages go** (`AIChatDestination.resolve`): `AppSettings.aiChatProvider`, `aiChatModel(for:)`, and `aiChatEffort(for:)`, the chat's own choice, kept in `State/settings.json` (a choice of the chat, not of one conversation, since conversations aren't kept); nil follows Settings ▸ AI. A provider without a saved key is never resolved to, the draft refuses one (`AIChatPrompt.draft(configured:)`), `AppModel.streamAI` refuses one before reading the Keychain, and `AIClient` refuses a request without a key: tested in `AIChatTests` (`theChatGoesOnlyToAProviderWithAKey`, `aProviderWithoutAKeyIsNeverSentTo`). Losing a key falls back to the other provider without changing the saved choice, so adding the key back restores it.
- **Reasoning levels** are `AIEffort` (`none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`) and `AIEffortChoice` (`.modelDefault`, saved as `"default"`, or a level). `AIModelTraits.effortLevels` holds the levels each model takes, from the providers' model pages (October 2026); unknown models of a family get `low` to `high`. A level the model doesn't take is never sent (`AIEndpoint.body` checks again). Settings ▸ AI's level is `aiAnthropicEffort`/`aiOpenAIEffort`, used by Explain or Fix too.
- **Switching** sends the history as plain user and assistant text (`AIChatConversation.history`): nothing provider-specific is ever kept (thinking deltas aren't stored), and OpenAI's `store: false` stays, so no request relies on server-side state. `AIChatDraft.switchedFrom` drives the note. Tests check the exact bodies for Anthropic → OpenAI, OpenAI → Anthropic, and a model switch (`aSwitchSendsTheWholeConversationAsPlainText`), and `AIStubTests` does it over HTTP.
- **Context windows:** `AIModelTraits.contextTokens` and a cautious estimate of three characters a token (`estimatedTokens`), with room for the answer's 16,000 tokens. `AIChatDraft.overflow` says so; `AIChatConversation.leaveOutAttachments` marks the oldest turns' `attachmentsLeftOut` until `AIChatDraft.fits(with:)`, and `AIChatTurn.sentAgain` sends the message part and a note instead.
- **Each message is a disclosure:** `AIChatPrompt.draft` builds the `AIDisclosure` from the earlier turns (`AIChatConversation.history`: answered turns only, as sent), the context parts, and the typed message last, as `## Message`. The pane shows that disclosure, and Send makes the `AIConsent` for it; Send Chat Message works only while the chat is open. Context parts are fenced, scrubbed (`AISecretRedaction`), and cut to 20,000 characters (`AITextLimit`). The answer streams into `AIChatLiveAnswer`, so only that turn redraws.
- **`@` files** (`ProjectFiles.resolve`): `..` and absolute paths are refused, the path is resolved with `realpath(3)` and must stay inside the project's real folder (so links can't lead out), only regular files are read (a FIFO would block), names that usually hold secrets are refused (`ProjectFiles.isSecret`, checked on both the name used and the one a link leads to), and files over 1 MB or with a NUL byte or invalid UTF-8 aren't sent. The mention still being typed (the caret right after it) isn't read yet. Files are read off the main thread when mentioned, and the text read is what's sent.
- **Tinkerwell's `appFiles()`** is a driver method that lists the application's PHP files (without `vendor`) for its chat's `@` picker. Runlet lists the project's local folder itself (`ProjectFiles.list`), so listing files never boots the application; a target without a local folder (the sandbox, or an SSH profile without one) has no `@` files.
- **Insert into Tab** is `EditorController.insertGenerated`: one undo group ("Insert into Tab"), counted as loaded code, so auto-run turns off (`TabModel.setAutoRunEnabled(false)` too, as Apply Fix does). The menu command `library.chatInsert` takes the block whose button was clicked (`AIChatSession.insertRequest`) or the last code block.
- **⌘.** is `run.stop`, which stops the chat's answer when the chat's message field has the keyboard or no run is going on; `library.chatStop` has no shortcut of its own, since two commands can't share one.
- **The message field** is an `NSTextView`: ⌘↩ is caught in `performKeyEquivalent` while it has the keyboard, and the `@` suggestions' keys in `doCommandBy`. Inline predictions and Writing Tools are off, as in the editor.
- **Debug builds** have the chat's steps in `Runlet/App/AIChatDebugSteps.swift` (`chat`, `chat-type`, `chat-send`, `chat-insert`, `chat-state`, `ai-wait:chat-done`, …). The stand-in answers each turn of a conversation with its own answer (`answers` in the scenario, and `hold_turn` to hold only one of them); `scripts/ai-screenshots.py <app> <out> chat` checks the whole chat against it and takes its pull request's screenshots, and `scripts/docs-screenshots.py ai` takes this page's.
- **Tests** make no network calls and use made-up keys: `AIProviderTests`, `AIRequestTests`, `AIStreamTests`, `AIErrorTests`, `AIClientTests` (a fake transport), `AIPrivacyTests`, `ExplainErrorTests`, `AIChatTests`, and `ProjectFilesTests` in `RunletCoreTests`; `AIStubTests` in `RunletExecutionTests` runs the real `URLSession` transport against the stand-in (streaming, Stop, failures, refusals, and a chat's turns). `RUNLET_TEST_KEYCHAIN=1` adds a round trip through the login keychain under a test-only service, which it deletes.
