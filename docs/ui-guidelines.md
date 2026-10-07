# Interface Guidelines

How Runlet's windows, sheets, prompts, and words look and behave, so a feature built by anyone, person or AI agent, feels like the rest of the app. The rules come from the code as it is: where the code disagrees with itself, this page says which pattern wins.

Before you build a view, find the closest existing one and copy it. The names in this page point to good examples.

- **New code follows this page.** Old code that doesn't is listed under [What Not to Copy](#what-not-to-copy); fix it only when your issue covers it.
- **When nothing here fits,** follow the macOS conventions the app already uses, and add the new rule to this page in the same pull request.

## Choosing the Surface

| You need to… | Use | Example |
| --- | --- | --- |
| Confirm something risky: code that runs on production, a run an AI client asks for, a write to a server | A **sheet** where <kbd>Return</kbd> cancels and <kbd>⌘</kbd><kbd>Return</kbd> confirms | `ProductionConfirmationSheet`, `MCPApprovalSheet` |
| Confirm deleting or closing something of the user's own (a profile, a connection, a pinned tab) | An **`NSAlert`** from model code, or **`.confirmationDialog`** from a view | Closing a pinned tab (`AppModel+Tabs.swift`), Delete Profile… |
| Report an error with nothing to choose | **`model.alert = AppAlert(title:message:)`**, shown with an OK button by `MainWindow` | Anything that failed after the user asked for it |
| Collect a few values, or show a review step | A **sheet** | `SnippetInputSheet`, `PromotedFileSheet` |
| Edit a profile or a connection | A **large sheet** with a header, a grouped `Form`, and a footer | `DockerProfileEditor`, `DatabaseConnectionEditor` |
| Show details next to a control, or ask for one value | A **popover** | App Info, the mail chip, Logs |
| Show something live without leaving the window | A **read-only popover peek** | `TerminalPeekView`, `CodePeekView` |
| Tell the user about a state of the current tab | A **banner** above the editor | File sync, the production banner |
| Explain an empty pane or list | **`ContentUnavailableView`** | No History Yet |
| Flag a bad field | **Inline red text** under the field | `DockerProfileEditor` |

## Sheets

### Presenting

The model owns what a sheet shows, and the sheet follows the model:

- **The pending value lives on the model** (a request, a confirmation), not in `@State` of the view that asked.
- **The sheet belongs to one window.** A computed `Binding` returns the value only when its `windowId` is nil or the window's own, and its setter turns `nil` into the model's cancel or decline. `SchemaDefinitionSheet`, `SQLCSVSheets`, and `MainWindow` show the pattern.
- **One sheet at a time per window.** When a sheet needs a production confirmation, the confirmation replaces the sheet's content (`SQLCSVConfirmingSheet`) instead of stacking a second sheet.
- **Complex sheets are a `ViewModifier`,** attached in `MainWindow`.

### Layout

A compact sheet, which is most of them:

```swift
VStack(alignment: .leading, spacing: 12) {
    HStack(alignment: .top, spacing: 12) {
        Image(systemName: "square.and.arrow.down")
            .font(.title2)
            .foregroundStyle(.tint)
            .frame(width: 28)
        VStack(alignment: .leading, spacing: 4) {
            Text("Import the snippets?").font(.headline)
            Text("Runlet adds 3 snippets to this project. Nothing runs.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    // Content…
    HStack {
        Spacer()
        Button("Cancel", role: .cancel) { model.cancelImport() }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("import-cancel")
        Button("Import") { model.confirmImport() }
            .keyboardShortcut(.defaultAction)
            .disabled(!isValid)
            .accessibilityIdentifier("import-confirm")
    }
}
.padding(20)
.frame(width: 520)
.accessibilityElement(children: .contain)
.accessibilityIdentifier("import-sheet")
```

- **Spacing and size:** `VStack(alignment: .leading, spacing: 12)`, `.padding(20)`, and a fixed width between 460 and 640. Add `.fixedSize(horizontal: false, vertical: true)` when the height should follow the text.
- **The header:** a plain title is `Text(…).font(.headline)`. A richer one is an `HStack(alignment: .top, spacing: 12)` with a symbol and a `VStack(spacing: 4)` of a headline and a `.callout`, `.secondary` explanation.
  - **Symbols:** confirmations use a filled red symbol at `.system(size: 28)`. Informational sheets use `.font(.title2)`, `.foregroundStyle(.tint)`, and `.frame(width: 28)`.
- **The footer:** `HStack { secondary or destructive actions  Spacer()  caption  Cancel  Primary }`.
  - Actions such as **Delete Profile…** sit on the left, before the `Spacer`.
  - A hint such as "⌘↩ confirms" or "Nothing runs: you can check the code first." is a `.caption`, `.secondary` text just left of the buttons.
- **A large sheet** (an editor with a form) is a `VStack(spacing: 0)`:
  1. A header with padding 20 horizontal and 14 vertical, then a `Divider`.
  2. The content, usually `Form { … }.formStyle(.grouped)`.
  3. A `Divider`, then a footer with padding 20 horizontal and 12 vertical.
  4. A fixed `width` and `height`.
- **Code and previews** show in a monospaced `.callout` or `.caption` text with `.textSelection(.enabled)`, inside `.padding(8)` on `RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08))`, with a `maxHeight` so long code scrolls.
- **Captions** that explain are `.font(.caption)`, `.foregroundStyle(.secondary)`, and `.fixedSize(horizontal: false, vertical: true)`. Say what happens, and what never happens: "Nothing is sent until you review it."

### Keys

| Kind of sheet | Cancel | Confirm | Escape |
| --- | --- | --- | --- |
| **Ordinary** (most sheets) | `Button("Cancel", role: .cancel)` with `.keyboardShortcut(.cancelAction)` | `.keyboardShortcut(.defaultAction)`, disabled until valid | Cancels |
| **Risky** (production, AI client runs, a statement that writes) | `.keyboardShortcut(.defaultAction)`, so <kbd>Return</kbd> alone cancels | `role: .destructive`, `.keyboardShortcut(.return, modifiers: .command)`, `.tint(.red)` on production; a "⌘↩ confirms" caption | `.onExitCommand { model.cancel… }` |
| **Staged edits** (Apply changes to a table) | `.cancelAction` | <kbd>⌘</kbd><kbd>Return</kbd>, `.buttonStyle(.borderedProminent)`, `.tint(.red)` on production | Cancels |
| **Long-running work** (an import or export) | **Stop** with `.keyboardShortcut(".", modifiers: .command)` | — | Ignored while the job runs |

On a risky sheet, mark the default with the comment the other ones use: `// ↩ alone cancels: the safe choice is the default.`

## Confirmations

- **Model code asks with `NSAlert`** and gets a `Bool` back (`runModal()`, or `beginSheetModal` for a window). **A view asks with `.confirmationDialog`** (the profile editors add `titleVisibility: .visible`).
- **The title is a short question in sentence case**, with names in curly quotes: "Close pinned tab?", "Delete the SSH profile “Staging”?", "Run this code on production?"
- **The message says what is touched, what isn't, and how to undo it:** "The folder isn't touched.", "This can't be undone.", "Reopen Closed Tab (⇧⌘T) brings it back, pinned."
- **Buttons are verbs in Title Case, never OK or Yes:** **Delete Profile**, **Remove Project**, **Disconnect**, **Save Anyway**, **Close**. The verb comes first and **Cancel** second, so AppKit gives Cancel the <kbd>Esc</kbd> key.
- **Deleting** sets `alertStyle = .warning` and `hasDestructiveAction = true` on the verb button (`role: .destructive` in SwiftUI).
- **Unsaved changes** ask **Save**, **Don't Save**, **Cancel** (`ProfileManager`).
- **Don't add "Don't ask again" checkboxes to alerts.** A time-limited or session allowance is a two-line `Toggle` on the sheet itself, scoped as narrowly as possible: "Don't ask again for 10 minutes for this target (snippet runs only)" on the production sheet, and the session allowance on the AI client sheet.
- **Production keeps its warning everywhere.** The explanation starts "<Target> is marked as production.", the confirm button says "… on Production", and nothing grants production a silent pass.
- **Inside a popover,** confirm inline in a red box instead of opening an alert over it (the mail chip's **Keep Intercepting** and **Send Mail**).

## Popovers

- **Info and control popovers** have an explicit width (330 to 440) and padding 8 to 14. They have a headline, `.callout` text, captions, and a `Divider` before a footer row.
- **Small form popovers** have a headline, a caption, a `TextField` with `.onSubmit(commit)`, and `HStack { Spacer()  Cancel  Primary }`, with `.defaultAction` on the primary.
- **Peeks** are read-only and sized to their content: `CodePeekView` is 680×360, and `TerminalPeekView` sizes itself between 420×180 and 900×480. <kbd>Esc</kbd> closes them (`.onExitCommand`). Offer a way to promote the peek to the real thing, like **Open in Terminal**.
- **The edge** gives the popover room: `.bottom` under header and toolbar controls, `.top` above the status bar, `.trailing` beside sidebar and list rows.
- **Closing:** an action closes its popover by setting its flag to false. A binding routes `nil` to the model's cancel, as sheets do.
- **In the editor,** popovers are AppKit: an `NSPopover` with `.transient` behavior and `animates = false`, which gives the keyboard back to the text view when it closes. Completion and hover info use the non-activating `PopupPanel`.

## Errors, Warnings, Banners, and Empty States

- **An inline error** is `Label(message, systemImage: "exclamationmark.triangle.fill")` in `.font(.caption)` and `.foregroundStyle(.red)`, with `.textSelection(.enabled)`. Under a form field, use `exclamationmark.circle.fill`. Editors count what's left in the footer: "1 issue to fix".
- **A warning** is orange: `exclamationmark.triangle.fill` with `.orange`. Red is for errors, danger, and production.
- **A failed run** shows the output pane's `ErrorCard` (`xmark.octagon.fill`, red).
- **A callout box** in a sheet is `.padding(10)` on `RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.1))`.
- **A banner** above the editor is `HStack(spacing: 8) { symbol  text  Spacer()  small buttons }` with `.padding(.horizontal, 10)`, `.padding(.vertical, 6)`, and `.background(tint.opacity(0.12))`.
  - Its identifier ends in `-banner`, and it uses `.accessibilityElement(children: .contain)`.
  - It's dismissed with a **Dismiss** button or a borderless `xmark` with `.help("Dismiss")`.
  - Start from `Banner` in `MainWindow.swift`.
- **An empty state** is a `ContentUnavailableView`:
  - The title is in Title Case ("No History Yet"), and the description is a full sentence ("This run made no requests through the HTTP clients Runlet watches.").
  - Add actions where there's something to do, with identifiers. When the actions row gets cut off, wrap it in an `HStack` with `.fixedSize()`.
  - Search without results uses `ContentUnavailableView.search(text:)`. A failed load uses `exclamationmark.triangle` and a **Try Again** action.

## Rows and Tooltips

- **Never put `.help` on a whole row that contains buttons; put the row's tooltip on its label.** A row-wide `.help`, with `.accessibilityElement(children: .combine)`, replaces the tooltips of every button, menu, badge, and chip in the row. Put it on the name and summary, or on a `Group` of the symbol and title, as the tab cards do (`tabButton` in `MainWindow.swift`, `card` in `VerticalTabs.swift`).
- **A button's tooltip starts with its action's name,** as the context menu says it, then says what happens in plain words, and what doesn't: "Open in SQL Tab: write a SELECT of its first 50 rows in a new SQL tab. Nothing runs until you press Run." Leave out internals; production still asks, but the tooltip doesn't say so.
- **One order** for a row's buttons, its context menu (the buttons' actions first), and its named accessibility actions, most used first. Declare `.accessibilityAction(named:)` in reverse: SwiftUI lists the last one first.
- **Buttons on hover** are an option for dense explorer lists, where every row has the same few actions: the SQL tables and MongoDB collections of the Database pane. The name gets the row's whole width, and `rowHoverButtons` (`InspectorList.swift`) lays the buttons over the row's summary while the pointer is over it, so the name never moves. The row keeps the pointer in its own `@State`, has the actions as named accessibility actions, and adds a DEBUG step that shows its buttons for screenshots (`schema-hover:<table>`, `mongo-hover:<collection>`). Other rows keep their buttons visible.

## Settings

- **Panes:** each is a `Tab("General", systemImage:)` holding a `Form { … }.formStyle(.grouped)`.
- **Sections:** use `Section("Title Case")`. A section that needs a note uses `footer:` with `.caption`, `.secondary` text.
- **Toggles and pickers** have a title and a one-line explanation: `Toggle(isOn:) { Text("Insert spaces instead of tabs"); Text("…") }`. Pickers with few choices use `.radioGroup` or `.segmented`.
- **A setting that depends on another** is `.disabled(…)` and indented with `.padding(.leading, 18)`.
- **Destructive actions** use `LabeledContent { Button("Clear History…", role: .destructive) }` and a `.confirmationDialog`.
- **Identifiers** start with `settings-`.
- **New settings** go in `AppSettings`, with a doc comment naming their Settings path and issue. Its tolerant decoding falls back per key, so older settings files keep loading. Experimental work hides behind a `FeatureFlag` (Settings ▸ Advanced).

## Focus and Keys

- **Rename fields** take the keyboard with the whole name selected, so typing replaces it.
  - <kbd>Return</kbd> or <kbd>Tab</kbd> commits, <kbd>Esc</kbd> cancels, and clicking elsewhere commits.
  - An empty name keeps the old one, and the keyboard goes back where it was.
  - Reuse `TabRenameField`.
- **Forms** focus their first field when they appear (`@FocusState` set in `.onAppear`).
- **Inline prompts** use `.focused`, `.onSubmit(submit)`, and `.onExitCommand(perform: cancel)`.
- **<kbd>Return</kbd> is the safe choice** on anything risky. <kbd>Esc</kbd> always cancels or closes, except while a job is running.
- **Debug and hidden launches never take focus** or become the key window (see [Checking the App](testing.md#checking-the-app)).

## Wording

| What | Rule | Example |
| --- | --- | --- |
| Buttons, menu items, commands, section headers, empty-state titles | Title Case | **Close Other Tabs**, **Run on Production**, "No History Yet" |
| Form labels, toggles, tooltips, captions, messages, alert and confirmation titles | Sentence case | "Insert spaces instead of tabs", "Close pinned tab?" |
| More UI follows (a dialog, sheet, or save panel) | End with the ellipsis character **…**, never `...` | **Rename Tab…**, **Delete “Staging”…** |
| Something in progress | Ends with **…** | "Stopping…", "Reading the value…" |
| Names of the user's things | Curly quotes | the saved connection “Cache” |
| Menu paths | **▸** | Settings ▸ General ▸ Output |
| Lists in one line | " · " | PRODUCTION · Docker · shop |
| Errors | A statement without a period for the title; full sentences that say what to do next for the message. Contractions, no "Error:", no "Please", no exclamation marks | Title "Couldn't save the output", message "Choose another folder, or check its permissions." |
| Disabled commands | One sentence that names the command | "Explain Statement works in SQL tabs." |
| Tooltips (`.help`) | A short phrase without a period. Add a period only when it's more than one sentence. A command's shortcut goes in parentheses, from `model.shortcut(for:)`, because shortcuts can be remapped | "New Tab (⌘T)" |
| Placeholders | A short noun or verb phrase | "Filter tables and columns" |
| Who acts | Runlet is the subject, and the Mac is "this Mac" | "Runlet asks before it connects.", "the PHP on this Mac" |
| Reassurance | Say what doesn't happen | "Nothing runs now.", "Starting Runlet never runs code." |
| Spelling | American in the UI, as macOS: Color, Center | |
| Finder | **Reveal in Finder** | |
| Closing a sheet with nothing to save | **Done** | |

Write UI text with contractions ("isn't", "can't", "Couldn't"); the app uses them almost four times as often as the long forms. Docs name UI elements exactly as the UI spells them.

## Commands and Shortcuts

Every action the user can trigger by menu, shortcut, or Open Anything is an `AppCommand` in `CommandCatalog` (`Runlet/App/Commands.swift`). Menus, Open Anything, toolbar tooltips, and **Settings ▸ Shortcuts** are all built from it.

- **`id` is `category.camelCase`** (`tabs.rename`, `run.sqlExplainAnalyze`) and **never changes**: shortcut overrides, What's New tours, and debug steps (`perform:<id>`) refer to it.
- **`title` is Title Case.** Use `menuTitle` when the menu needs an ellipsis that Open Anything doesn't ("Explain Analyze…").
- **`category`, `defaultShortcut`, and `keywords`** (space-separated synonyms for Open Anything).
- **`isEnabled`, `disabledReason`, `isChecked`, and `checkedLabel`** are closures. A disabled command shows in Open Anything only with a `disabledReason`.
- **Add a comment above it citing the issue** (`// #285: …`), and put it in a menu with `item("<id>")` in `RunletCommands`.
- **`CommandCatalog.problems()`** (run by `--self-test`) catches repeated ids and conflicting default shortcuts.

## Visual Tokens

| Token | Use |
| --- | --- |
| `.secondary`, `.tertiary` | Explanations, captions, metadata |
| `.red` | Errors, danger, production |
| `.orange` | Warnings, staging, conflicts |
| `.tint` / `Color.accentColor` | Informational symbols, selection |
| `.headline` | Sheet and popover titles |
| `.callout` | Body text in sheets and popovers |
| `.caption`, `.caption2` | Captions, metadata, row details |
| `.system(…, design: .monospaced)` | Code, SQL, output; `.monospacedDigit()` for numbers that change |
| Corner radius 6 | Boxes and callouts (4 or 5 for small chips) |
| Spacing 4, 6, 8; padding 8, 10, 20 | Rows, boxes, sheets |
| `.controlSize(.small)` | Buttons and pickers in panes, headers, and toolbars |
| `.buttonStyle(.borderless)` | Icon buttons in rows and headers |
| Environment badges | `EnvironmentBadge`: an uppercase capsule, red **PRODUCTION**, orange **STAGING**, and `ReadOnlyBadge` |

| Symbol | Means |
| --- | --- |
| `shippingbox` | The Laravel sandbox |
| `folder` | A local project |
| `cube.box` | Docker |
| `server.rack` | SSH |
| `exclamationmark.triangle.fill` | A warning (orange) or an inline error (red) |
| `exclamationmark.octagon.fill` | Danger |
| `doc.on.doc` | Copy |
| `arrow.clockwise` | Refresh, Try Again |
| `info.circle` | More information |

## Accessibility Identifiers

Every control a person can use gets an `.accessibilityIdentifier`. Debug steps (`click:`, `press:`, `scroll:`, `search:`), screenshot scripts, What's New tours, and UI tests find views by them.

- **kebab-case, `<feature>-<element>`:** `production-confirm`, `csv-export-sheet`, `settings-appearance`. Don't add `-button`.
- **A sheet's root** gets `-sheet` or `-confirmation`, and `.accessibilityElement(children: .contain)`.
- **Dynamic parts go at the end:** `environment-badge-\(environment.rawValue)`.
- **Never rename an identifier** that a script, a docs shot, a What's New tour (`.tourAnchor`), or a test uses. Search `scripts/` and `Runlet/WhatsNew.json` first.

## Debug Steps

Each feature can be driven and photographed without touching anyone's keyboard. A new feature with UI adds its own steps:

1. Create `Runlet/App/<Feature>DebugSteps.swift`, wrapped in `#if DEBUG`. Its doc comment starts "RUNLET_DEBUG_STEPS for <feature> (#N)" and lists each step.
2. Write `enum <Feature>DebugSteps { static func run(_ name: String, _ argument: String, model: AppModel) -> Bool }`.
3. Chain it from the default case of `DebugSteps.run`, or from its parent feature's steps.
4. Name the steps `feature-verb` (`rename-begin`), and add a `<feature>-state` step that prints a `RUNLET_DEBUG_STATE:` line.
5. Add a check or screenshot script in `scripts/` when the pull request needs one (`scripts/tab-rename-check.py` is a complete example).

[Checking the App](testing.md#checking-the-app) explains how to launch the app with steps.

## Shared Pieces

Reuse these before writing your own:

| Piece | For |
| --- | --- |
| `ProductionConfirmationSheet` | Any run or action on production |
| `DatabaseDangerSheet` | Any dangerous database operation (FLUSHDB, Kill Op, …) |
| `EnvironmentBadge`, `ReadOnlyBadge`, `TargetEnvironmentFields` | Showing and editing a target's environment |
| `Banner` | A banner above the editor |
| `StableInspectorList`, `InspectorActions`, `Binding.ignoringEqualWrites` | Lists in the inspector and sidebars that must not jump or flicker; the header of `InspectorList.swift` explains the rules |
| `rowHoverButtons` | A dense explorer row's buttons, shown over its summary while the pointer is over it ([Rows and Tooltips](#rows-and-tooltips)) |
| `TabRenameField` | Renaming in place |
| `CodePeekView`, `TerminalPeekView` | Read-only peeks |
| `ChipButtonStyle` | Small chip buttons in headers |
| `AppAlert` | Errors |

`ResizableSheet` (`SchemaDefinitionSheet.swift`), `CopyableCode` (`MCPViews.swift`, Copy turns into Copied), and the private `notice` helpers are worth sharing: make them internal and move them to a shared file when a second feature needs them.

## What Not to Copy

The code has older patterns that this page doesn't follow. Don't copy them into new code:

- **Risky confirmations where <kbd>Return</kbd> doesn't cancel,** or whose confirm button has no shortcut (`DatabaseDangerSheet`, `RedisKillSheet`, the server action sheet). New risky sheets follow [Keys](#keys).
- **`RedisKillSheet`** duplicates `DatabaseDangerSheet`, which MongoDB's Kill Op already uses.
- **Sheets in `Sheets.swift` without `.cancelAction` or a root identifier** (`ContainerChoiceSheet`, `SaveSnippetSheet`, `ProjectSettingsSheet`).
- **Header symbols of other sizes** (24, 26, 30, `.largeTitle`): use 28 for confirmations, and `.title2` in a 28-point frame for information.
- **"Could not …" and "Cannot …"** in new text: write "Couldn't …" and "Can't …".
- **Sentence-case empty-state titles** ("No queries", "No tab").
- **"Show in Finder"**, **"Close"** or **"OK"** to dismiss a sheet, and identifiers that end in `-button`.
- **Tooltips with a hard-coded shortcut** ("Copy Output (⌥⌘C)" typed in the string): build them from `model.shortcut(for:)` (`shortcutHint` in `SettingsView.swift`).
- **Sheet padding other than 20.**
- **A `.help` on a whole row,** with `.accessibilityElement(children: .combine)`. Rows without buttons still have one (`HistoryRow`, `SnippetRow`, `PHPInstallationRow`), and it hides their badges' own tooltips. New rows put the tooltip on their label ([Rows and Tooltips](#rows-and-tooltips)).
- **Context-menu stand-ins:** the DEBUG-only popovers in `TabContextMenu.swift` and `SchemaExplorer.swift` exist for screenshots. Use real context menus.

## For developers

- This page and the conventions in [AGENTS.md](../AGENTS.md): [#330](https://github.com/filipac/runlet/issues/330). The rules were taken from the code in October 2026; when you change a convention, change this page in the same pull request.
- The docs style guide is [Writing Docs](writing-docs.md); the workflow is [Contributing](contributing.md); app checks and screenshots are in [Testing](testing.md#checking-the-app).
