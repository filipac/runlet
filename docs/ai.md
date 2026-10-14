# AI Assistance

Runlet can ask an AI model why a run failed and how to fix it, with your own Anthropic or OpenAI API key. You see exactly what would be sent before anything leaves your Mac, nothing is sent until you click **Send**, and Runlet never runs code a model writes.

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

<!-- screenshot: Settings ▸ AI with a saved Anthropic key, masked, after Test Key -->

### Where Keys Are Kept

- **In your Mac's Keychain,** never in Runlet's files or settings. Keychain Access lists them as "Runlet AI key: Anthropic" and "Runlet AI key: OpenAI", each with its masked form.
- **Masked once saved.** Settings shows only the start and the last four characters, such as `sk-ant-…Q2c4`. To change a key, remove it and save the new one.
- **Remove Key…** deletes it from the Keychain. The key itself keeps working at the provider until you revoke it there.
- **Never in a message.** When a provider rejects a key, Runlet says so without repeating it.

After an update, macOS may ask once before Runlet can read a key it saved. Choose **Always Allow**.

### Choosing a Model

Each provider has a **Model** setting. Before you test the key, it offers the provider's current models; after **Test Key**, it lists the ones your account can use, newest first. When the model you chose isn't in that list, Settings warns you.

Larger models explain more carefully and cost more. Smaller ones, such as Claude Haiku 5.5 or GPT-6 Luna, are cheaper and faster. Each provider's pricing page has the prices.

## What Is Sent, and When

Every AI feature follows the same rules:

- **Nothing is sent on its own.** Opening a sheet, a run that fails, or an error card sends nothing. A request leaves your Mac only when you click **Send**.
- **You see exactly what's sent:** the provider, the model, every part of the message with a checkbox, and the instructions Runlet adds. Only the parts you leave checked are sent, word for word as shown.
- **Only what the feature shows.** Your other tabs, files, history, the run inspector's records, saved passwords, and environment values are never sent.
- **Generated code never runs.** A proposed change goes into your tab only when you apply it, and running it is your **Run**, with [production's confirmation](environments.md) as always.

Runlet asks OpenAI not to keep the response for later retrieval. Each provider's own data policy applies to what you send.

## Explain or Fix an Error

When a run fails, the error card has an **Explain or Fix…** button. You can also choose **Run ▸ Explain or Fix Error…** for the tab's last error, or find it in Open Anything.

<!-- screenshot: the Explain or Fix sheet before sending: the error, the tab's code, and the source where it was thrown, each with a checkbox -->

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

<!-- screenshot: the answer with its proposed fix as a diff, and the Apply Fix button -->

- **Apply Fix** replaces the tab's code with the fix, as one undoable edit. Nothing runs, and [sandbox auto-run](sandbox-auto-run.md) turns off for the tab.
- **Undo Apply Fix**, or **Edit ▸ Undo** in the editor, puts the old code back.
- **The tab changed?** If you edited the tab after asking, **Apply Fix** refuses, since the fix may no longer fit. Close the sheet and click **Explain or Fix…** again to send the code as it is now.
- **No fix?** When the cause is elsewhere (a project file, the database, the environment), the model says what to change instead, and the sheet notes that it proposed no change.

**Copy Answer** copies the whole answer as Markdown. **Ask Again…** goes back to what's sent, so you can check or uncheck parts and send again.

### Without a Key

Without a key for the chosen provider, the sheet still shows what it would send, says that no key is saved, and offers **Open AI Settings…**. **Send** stays off until you add one.

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

AI providers are [#368](https://github.com/filipac/runlet/issues/368); Explain or Fix This Error is [#44](https://github.com/filipac/runlet/issues/44). The chat sidebar ([#45](https://github.com/filipac/runlet/issues/45)) and inline completion ([#46](https://github.com/filipac/runlet/issues/46)) are meant to build on the same layer. Apple's on-device models aren't part of it yet.

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
| Views | `Runlet/Features/AISettingsView.swift`, `ExplainErrorSheet.swift`, the button in `ErrorCard` (`OutputPane.swift`) |

- **The APIs**, as documented in October 2026. Anthropic: `POST /v1/messages` with `x-api-key` and `anthropic-version: 2023-06-01`, `stream: true`, no `thinking` (current models think adaptively), `output_config.effort` only for models that take it, and `fallbacks: "default"` with `anthropic-beta: server-side-fallback-2026-07-01` for the models whose safety classifiers can decline (Claude Opus 5.5, Opus 5, Sonnet 5.5, Fable 5.1), so a declined request is retried on Anthropic's recommended model; an account that rejects that beta gets the same request once more without it. A `refusal` stop reason drops the partial answer. OpenAI: the Responses API, `POST /v1/responses` with `Authorization: Bearer`, `instructions`, `input`, `max_output_tokens`, `stream: true`, `store: false`, and `reasoning.effort` only for reasoning models. Both list models with `GET /v1/models`. Explain or Fix asks for medium effort and at most 16,000 output tokens, thinking included.
- **The defaults** are each provider's own recommended starting model. A cheaper default would be a silent downgrade; the choice is the user's.
- **Keys:** the Keychain service `dev.runlet.Runlet.ai` (with a hash of the data folder for a scratch `RUNLET_DATA_DIR`), one fixed account per provider (`AIProvider.keychainAccount`), labelled with the masked key so Settings can show it without reading the secret. The key is a `SensitiveString`, goes only into a request header, and is scrubbed from provider messages; a 401's message isn't kept at all. Settings files hold only `aiProvider`, `aiAnthropicModel`, and `aiOpenAIModel`, and older files load with the defaults. Debug builds with a scratch `RUNLET_DATA_DIR` keep keys in memory (`RUNLET_CREDENTIALS=keychain` overrides).
- **Consent:** `AIClient.stream` and `complete` refuse a disclosure that differs from what `AIConsent` approved, or that has nothing checked (`AIError.notConfirmed`), before sending anything. Only a Send button's action makes a consent.
- **Debug builds only:** `RUNLET_AI_BASE_URL` sends both providers' requests to another base URL, such as the stand-in `Tests/Fixtures/ai-stub/router.php` under `php -S 127.0.0.1:<port>`, which streams canned answers shaped like both providers' events (`RUNLET_AI_STUB_SCENARIO`, `RUNLET_AI_STUB_LOG`). Release builds ignore the variable. The debug steps are in `Runlet/App/AIDebugSteps.swift`; `scripts/ai-screenshots.py` checks the whole flow against the stand-in and takes the pull request's screenshots.
- **Tests** make no network calls and use made-up keys: `AIProviderTests`, `AIRequestTests`, `AIStreamTests`, `AIErrorTests`, `AIClientTests` (a fake transport), `AIPrivacyTests`, and `ExplainErrorTests` in `RunletCoreTests`; `AIStubTests` in `RunletExecutionTests` runs the real `URLSession` transport against the stand-in (streaming, Stop, failures, refusals). `RUNLET_TEST_KEYCHAIN=1` adds a round trip through the login keychain under a test-only service, which it deletes.
