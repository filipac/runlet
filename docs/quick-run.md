# Quick Run

Quick Run is a small floating panel for a line or two of PHP: a slug, a date, a hash, a quick look at a model. Open it from any app, press <kbd>⌘</kbd><kbd>R</kbd>, read the result, and press <kbd>Esc</kbd>, without switching to Runlet's window.

![The Quick Run panel on the Laravel Sandbox: App\Models\User::first() and its result, the first user in the Values view, and Open in Tab](screenshots/quick-run/result-light.webp#gh-light-mode-only)
![The Quick Run panel on the Laravel Sandbox: App\Models\User::first() and its result, the first user in the Values view, and Open in Tab](screenshots/quick-run/result-dark.webp#gh-dark-mode-only)

## Opening Quick Run

Open the panel from Runlet with **Window ▸ Quick Run**, from the command palette (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>P</kbd>), or by typing `quick run` in Open Anything (<kbd>⌘</kbd><kbd>P</kbd>). To open it from any app, turn on its [global shortcut](#the-global-shortcut).

The panel floats above every app's windows, near the top of the screen with the pointer, like Spotlight. It takes the keyboard without bringing Runlet's windows forward, so the app you were in stays where it was. Drag the panel by its title to move it; it opens there again until Runlet quits.

## Running Code

Type PHP in the panel's editor, then press <kbd>⌘</kbd><kbd>R</kbd>. As in a tab, the last expression is the result, so you need no `return` or `echo`:

```php
Str::slug('Hello World')
```

```php
now()->addDays(3)->toDateString()
```

The editor has PHP highlighting and completion, and grows with your code up to ten lines. Nothing else runs it: opening the panel, typing, and the code it kept from last time never run anything. <kbd>⌘</kbd><kbd>.</kbd> stops a run.

The result shows below the editor, compactly:

- **The value,** as a tree. Eloquent models show what they hold, in the [Values view](running-code.md#eloquent-models-values-or-object), with **Values | Object** to switch.
- **An error,** with its class, message, and line. Click the line to put the cursor there.
- **Printed output** and `dump()` calls, in the order they happened.

The footer says how the run ended and how long it took. Runs work as a tab's do: the same runner, settings, and limits, and magic comments show their values in the editor. Each run goes into [History](#history).

![The Quick Run panel after a failed run: a date the first line printed, and an InvalidFormatException on line 2](screenshots/quick-run/error-light.webp#gh-light-mode-only)
![The Quick Run panel after a failed run: a date the first line printed, and an InvalidFormatException on line 2](screenshots/quick-run/error-dark.webp#gh-dark-mode-only)

## Choosing a Target

The panel runs on the Laravel Sandbox. To run on one of your projects instead, choose it in the target menu next to the title: it lists the sandbox, your local projects, Docker profiles, and SSH hosts. The panel keeps its target until you choose another.

A staging target shows its **STAGING** badge and runs as usual.

### Never on Production

> [!WARNING]
> Quick Run never runs code on a production target.

- **The target menu leaves out** every target marked as production, and every target whose application said it runs in production on its last run (see [When the Application Says It's Production](environments.md#when-the-application-says-its-production)).
- **<kbd>⌘</kbd><kbd>R</kbd> checks again.** If the panel's target was marked as production after you chose it, the panel says so in red, and nothing runs. Choose another target.
- **To run the code there anyway,** use [Open in Tab](#open-in-tab): in the tab, a run on production asks first, as every run on production does.

## Open in Tab

**Open in Tab** (<kbd>⌘</kbd><kbd>Return</kbd>) moves the code into a new tab in Runlet's window, with its target and the last run's result, including its queries, mail, logs, HTTP requests, jobs, and events in the [run inspector](run-inspector.md). Runlet's window comes forward; when none is open, a new one opens. Nothing runs.

The panel closes, and starts empty next time, on the same target.

## Closing the Panel

<kbd>Esc</kbd>, <kbd>⌘</kbd><kbd>W</kbd>, or the panel's close button closes it. The panel keeps its code and its last result for next time, and Runlet keeps the code and the target when it quits. A run goes on after you close the panel; open it again to see the result.

## History

Every run from the panel goes into [History](running-code.md#run-history), like a tab's, marked with a bolt. Search History for `quick run` to find them. Opening one opens it in a tab, as with any History entry.

## The Global Shortcut

A global shortcut opens Quick Run from any app. It's off by default; turn it on in **Settings ▸ Shortcuts**, at the top:

- **Open Quick Run from any app** turns it on or off. The shortcut is <kbd>⌃</kbd><kbd>⌥</kbd><kbd>R</kbd> until you record another.
- **Record** a new one: click it, then press the key combination. It needs <kbd>⌘</kbd>, <kbd>⌃</kbd>, or <kbd>⌥</kbd>. <kbd>Esc</kbd> cancels.

Press the shortcut in any app to open the panel; press it again while the panel has the keyboard to close it. Runlet needs no Accessibility permission for it: macOS tells Runlet about this one shortcut, and never about other keys you type.

![Settings ▸ Shortcuts: Open Quick Run from any app turned on, with ⌃⌥R and Record, and the note that the shortcut works from every app](screenshots/settings/quick-run-shortcut-light.webp#gh-light-mode-only)
![Settings ▸ Shortcuts: Open Quick Run from any app turned on, with ⌃⌥R and Record, and the note that the shortcut works from every app](screenshots/settings/quick-run-shortcut-dark.webp#gh-dark-mode-only)

When the shortcut can't work, Settings says why, in orange, and Runlet leaves it alone:

| Reason | What to do |
| --- | --- |
| Another app already uses it as a global shortcut. | Record another one, or change it in that app. |
| macOS uses it for one of its own shortcuts. | Record another one, or turn macOS's off in **System Settings ▸ Keyboard ▸ Keyboard Shortcuts**. |
| One of Runlet's commands uses it. | Record another one, or change that command's shortcut in the list below. |

## Keys in the Panel

| To | Press |
| --- | --- |
| Run | <kbd>⌘</kbd><kbd>R</kbd> |
| Stop | <kbd>⌘</kbd><kbd>.</kbd> |
| Open in Tab | <kbd>⌘</kbd><kbd>Return</kbd> |
| Close | <kbd>Esc</kbd> or <kbd>⌘</kbd><kbd>W</kbd> |
| Show completions | <kbd>⌃</kbd><kbd>Space</kbd> |

## For developers

Quick Run is [#25](https://github.com/filipac/runlet/issues/25) (N41 in [done-next-release-ideas.md](done-next-release-ideas.md)).

| Piece | Where |
| --- | --- |
| The rules: `QuickRunDraft`, `QuickRun.offeredTargets` (no production, no reported production), `refusal(for:in:reportedEnvironment:)`, `restored`, `handoff` (Open in Tab) | `RunletCore/QuickRun.swift` |
| The global shortcut: `GlobalHotKey` (key code, combo, Carbon modifiers), `GlobalHotKeyStatus`, the `GlobalHotKeyRegistering` protocol, and `GlobalHotKeyController` (register, re-register, unregister, conflicts) | `RunletCore/QuickRun.swift` |
| Settings `quickRunHotKeyEnabled` (false) and `quickRunHotKey` (⌃⌥R, key code 15); the session's `quickRun` draft; `HistoryEntry.quickRun` | `RunletCore/Models.swift` |
| The panel's state (`QuickRunModel`) and actions: `showQuickRun`, `toggleQuickRun`, `runQuickRun`, `openQuickRunInTab`, `applyQuickRunHotKey` | `Runlet/App/AppModel+QuickRun.swift` |
| The panel: `QuickRunPanel` (a borderless, non-activating, floating `NSPanel`), `QuickRunPanelController`, `QuickRunView`, and `QuickRunEditorStyle` | `Runlet/Features/QuickRunPanel.swift` |
| Carbon's `RegisterEventHotKey` (`CarbonHotKeyRegistrar`), and the Debug builds' stand-in (`DebugHotKeyRegistrar`) | `Runlet/App/GlobalHotKeys.swift` |
| Settings ▸ Shortcuts' section (`QuickRunHotKeySettings`) | `Runlet/Features/ShortcutSettingsView.swift` |
| Tests | `QuickRunTests` and `QuickRunHotKeyTests` (RunletCoreTests) |

- **The panel's tab.** The panel holds an ordinary `TabModel` that is in no window (`isQuickRun`), with its own `EditorController` (the gutter hidden, soft wrap on) and language binding. Runs go through `AppModel.startRun`, so History, the runner, magic comments, and the inspector's limits are a tab's; `startRun` records `quickRun: true` in the History entry. A panel run posts no long-run notification (`runEnded` needs a window), and Format before run doesn't apply to it. Open in Tab moves that same tab, with its editor, undo history, output, and inspector, into the window (`AppModel.adopt(_:into:)`), and the panel makes a new tab next time.
- **Production, twice.** The picker offers `quickRunTargets`; `runQuickRun` checks `quickRunRefusal` when ⌘R is pressed, and `startRun` checks it again for a Quick Run tab after preparing the target, right before the launch. The panel shows the refusal live, so a target marked production while it's open says so at once. Staging needs no confirmation, as in tabs.
- **Keys.** `QuickRunPanel.performKeyEquivalent` takes ⌘R, ⌘↩, ⌘., and ⌘W, and sends the editing keys (⌘X, ⌘C, ⌘V, ⌘A, ⌘Z, ⇧⌘Z, ⌘/) to the editor: Runlet may not be the active app while the panel has the keyboard. While it has the keyboard, `AppModel.perform` also sends the menus' Run to the panel, Stop and Close to the panel, and makes the other run commands beep, so a menu key never runs a tab behind the panel. There is no Run button: only ⌘R runs.
- **The hotkey.** `RegisterEventHotKey` with `kEventHotKeyExclusive`, so another app's registration fails with `eventHotKeyExistsErr` instead of firing in both; `CopySymbolicHotKeys` tells whether macOS uses the combo. The controller also refuses a combo one of Runlet's commands uses (it would take the keys from it, even in Runlet), and re-applies when the setting or `shortcutOverrides` change. Recording releases the shortcut, so pressing it records it. Quitting unregisters it.
- **Checks without taking the keyboard.** Debug builds launched with any `RUNLET_DEBUG_*` variable never register a global shortcut (`DebugHotKeyRegistrar`) and never let the panel become key (`QuickRunPanel.mayTakeKeyboard`): it's shown with `orderFrontRegardless`. The steps are `quick-run:open|close|type:<code>|clear|key:<key>|run|target:<name>|mark:<name>=<environment>|open-in-tab|state|hotkey:on|off|hotkey-conflict|hotkey-system|hotkey-press|hotkey-state` and `quick-run-wait` (`QuickRunDebugSteps`); `quick-run:key` hands a press to the panel's `performKeyEquivalent`, then its editor. `quick-run:state` prints whether the panel is key and whether Runlet is the active app, which a check expects to be false.
- **Screenshots:** `scripts/docs-screenshots.py quick-run settings/quick-run-shortcut`. The shot step draws the panel on its own (`shot:<name>@Quick Run`), its material blended within the window.
