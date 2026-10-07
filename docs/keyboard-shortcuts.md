# Keyboard Shortcuts

Everything in Runlet's menus can be reached from the keyboard. This page lists the default shortcuts, menu by menu, and the two palettes that find everything else: Open Anything (<kbd>⌘</kbd><kbd>P</kbd>) and the command palette (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>P</kbd>).

## Changing Shortcuts

**Settings ▸ Shortcuts** lists every command, grouped like the menus, with a search field for commands or keys:

- **Record** a new shortcut: click it, then press the key combination. <kbd>Esc</kbd> cancels, and <kbd>Delete</kbd> clears the shortcut.
- **Reset to Default** and **Clear Shortcut** are next to a changed command, which shows its default below its name. **Reset All** puts every shortcut back.
- A shortcut used by two commands is marked with a warning: only one of them works.

The menus, the palettes, the tooltips of the toolbar and the window's buttons, and [shortcut tips](#learning-shortcuts) always show your current shortcuts. Commands without a default shortcut, such as **New SQL Tab** or **Fold All**, can get one here.

### Quick Run From Any App

The top of **Settings ▸ Shortcuts** has the [Quick Run](quick-run.md) panel's global shortcut, which works in every app, not only in Runlet. It's off by default; turn on **Open Quick Run from any app**, and press <kbd>⌃</kbd><kbd>⌥</kbd><kbd>R</kbd>, or record another shortcut. See [Quick Run ▸ The Global Shortcut](quick-run.md#the-global-shortcut).

## Learning Shortcuts

When you click a menu item, a toolbar button, or a button in the window for a command that has a shortcut, or choose the command in a palette, a small tip above the status bar shows its shortcut:

![A shortcut tip above the status bar, after a click on the tab layout button: ⌃⌘T is the shortcut for Toggle Vertical Tabs, with Don't Show Again](screenshots/keyboard-shortcuts/shortcut-tip-light.webp#gh-light-mode-only)
![A shortcut tip above the status bar, after a click on the tab layout button: ⌃⌘T is the shortcut for Toggle Vertical Tabs, with Don't Show Again](screenshots/keyboard-shortcuts/shortcut-tip-dark.webp#gh-dark-mode-only)

- **It stays out of the way.** The tip fades after a few seconds, or at your next command, and never takes the keyboard. When the cursor's line is at the bottom of the editor, the tip shows at the top instead. VoiceOver reads it out.
- **Once a day at most** for each command, however often you click it.
- **It stops for good** once you've used the shortcut three times, or when you click **Don't Show Again** on it.
- **Your shortcuts.** The tip shows the shortcut as you set it in **Settings ▸ Shortcuts**. A command without a shortcut has no tip, and pressing a shortcut never shows one.
- **Turning tips off:** **Settings ▸ General ▸ Tips ▸ Show shortcut tips**.
- **What's kept:** how often you ran each command with its shortcut, its menu item, a button, or a palette, and when its tip last showed; never the code, tab, or target. **Settings ▸ General ▸ Command Palette ▸ Clear Command History** clears the counts. Tips you turned off with **Don't Show Again** stay off.

## Open Anything and the Command Palette

**Open Anything** (<kbd>⌘</kbd><kbd>P</kbd>) finds targets, snippets, and recent files, along with a few windows such as Connections and Logs. Choosing a target switches the current tab to it. Choosing a snippet or a file opens it. A prefix narrows the search:

| Type | To search |
| --- | --- |
| `>` | Commands (switches to the command palette) |
| `/` | Local projects |
| `@` | Docker and SSH profiles |
| `#` | Snippets, personal and project |
| `!` | Run History |

**The command palette** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>P</kbd>) runs any command by name, with its shortcut next to it. A command that can't run right now is still listed, with the reason. In the command palette, <kbd>⌫</kbd> in the empty field goes back to Open Anything.

In both, <kbd>Return</kbd> opens the selection, <kbd>⌘</kbd><kbd>Return</kbd> opens it in a new tab, and <kbd>Esc</kbd> closes the palette. Choosing something never runs code.

> [!TIP]
> Type `dark`, `light`, or `auto` in Open Anything to switch Runlet's appearance.

### Frequently Used Commands

The command palette learns which commands you use. With nothing typed, up to five of the commands you choose most often, and most recently, come first under **Frequently Used**, and the rest follow in their usual order. A command that can't run right now isn't moved up.

When you type, the best match still comes first. How often you use a command only decides between equally good matches, or lifts it past one that's barely better. Typing `rename` puts **Rename Tab…** first, however often you use **Run**. The commands Open Anything lists, such as **Pin Tab** and the Appearance commands, follow the same order among themselves; targets, snippets, and files keep their places.

- **Recent use counts most.** A use counts half as much after two weeks, so a command you stopped using drops back after a few weeks.
- **Only choosing counts.** Running a command from a palette is a use. Moving the selection to it isn't, and neither are its menu item and shortcut.
- **Only the command is kept:** which one you chose, and when, never the code, tab, or target it ran on.
- **Starting over:** **Settings ▸ General ▸ Command Palette ▸ Clear Command History** forgets every use, and the palette goes back to its usual order.

## Default Shortcuts

### Runlet

| Command | Shortcut |
| --- | --- |
| Settings… | <kbd>⌘</kbd><kbd>,</kbd> |
| Settings, opened on the Advanced tab | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>,</kbd> |

### File

| Command | Shortcut |
| --- | --- |
| New Window | <kbd>⌘</kbd><kbd>N</kbd> |
| New Tab | <kbd>⌘</kbd><kbd>T</kbd> |
| Duplicate Tab | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>D</kbd> |
| Open… | <kbd>⌘</kbd><kbd>O</kbd> |
| Open Project… | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>O</kbd> |
| Open Project in Editor | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>E</kbd> |
| Close Tab | <kbd>⌘</kbd><kbd>W</kbd> |
| Close Window | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>W</kbd> |
| Save | <kbd>⌘</kbd><kbd>S</kbd> |
| Save Tab As PHP File… | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>S</kbd> |
| Save Workspace As… | <kbd>⌥</kbd><kbd>⇧</kbd><kbd>⌘</kbd><kbd>S</kbd> |

New SQL Tab, New Redis Tab, New MongoDB Tab, Reload from Disk, Save as Artisan Command…, and Save as Test… have no default shortcut.

### Edit

| Command | Shortcut |
| --- | --- |
| Toggle Line Comment | <kbd>⌘</kbd><kbd>/</kbd> |
| Lines ▸ Move Line Up / Down | <kbd>⌥</kbd><kbd>↑</kbd> / <kbd>⌥</kbd><kbd>↓</kbd> |
| Lines ▸ Duplicate Line Up / Down | <kbd>⇧</kbd><kbd>⌥</kbd><kbd>↑</kbd> / <kbd>⇧</kbd><kbd>⌥</kbd><kbd>↓</kbd> |
| Format Code | <kbd>⌥</kbd><kbd>⇧</kbd><kbd>⌘</kbd><kbd>F</kbd> |
| Show Completions | <kbd>⌥</kbd><kbd>Esc</kbd> |
| Go to Definition | <kbd>F12</kbd>, or <kbd>⌘</kbd>-click |
| Find References | <kbd>⇧</kbd><kbd>F12</kbd> |
| Show Code Actions | <kbd>⌥</kbd><kbd>Return</kbd> |
| Code Folding ▸ Fold | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>←</kbd> |
| Code Folding ▸ Unfold | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>→</kbd> |

Find (<kbd>⌘</kbd><kbd>F</kbd>), Undo (<kbd>⌘</kbd><kbd>Z</kbd>), and the other standard macOS editing keys work in the editor too. [Code Navigation](navigation.md) covers moving lines, definitions, and folding.

### Run

| Command | Shortcut |
| --- | --- |
| Run | <kbd>⌘</kbd><kbd>R</kbd> |
| Run Selection | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>R</kbd> |
| Run All Statements (SQL tabs) | <kbd>⌥</kbd><kbd>⇧</kbd><kbd>⌘</kbd><kbd>R</kbd> |
| Explain Statement (SQL tabs) | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>E</kbd> |
| Profile Run | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>R</kbd> |
| Stop | <kbd>⌘</kbd><kbd>.</kbd> |
| Copy Output | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>C</kbd> |
| Clear Output | <kbd>⌘</kbd><kbd>K</kbd> |
| Output: Structured | <kbd>⌃</kbd><kbd>⌘</kbd><kbd>1</kbd> |
| Output: Plain | <kbd>⌃</kbd><kbd>⌘</kbd><kbd>2</kbd> |
| Output: Raw | <kbd>⌃</kbd><kbd>⌘</kbd><kbd>3</kbd> |

### Library

| Command | Shortcut |
| --- | --- |
| Open Anything… | <kbd>⌘</kbd><kbd>P</kbd> |
| Command Palette… | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>P</kbd> |
| Show History | <kbd>⌘</kbd><kbd>Y</kbd> |
| Show Snippets | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>L</kbd> |
| Show Database | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>B</kbd> |
| Show Project Commands | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>K</kbd> |
| Show/Hide History & Snippets | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>L</kbd> |
| Save as Snippet… | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>S</kbd> |
| New Docker Profile… | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>N</kbd> |

### View

| Command | Shortcut |
| --- | --- |
| Toggle Vertical Tabs | <kbd>⌃</kbd><kbd>⌘</kbd><kbd>T</kbd> |
| Wrap Lines | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>W</kbd> |
| Show/Hide Output Pane | <kbd>⌃</kbd><kbd>⌘</kbd><kbd>O</kbd> |
| Move Output Right/Below | <kbd>⌃</kbd><kbd>.</kbd> |
| Show/Hide Terminal | <kbd>⌃</kbd><kbd>`</kbd> |
| New Terminal | <kbd>⌃</kbd><kbd>⇧</kbd><kbd>`</kbd> |
| Show Builder (Redis and MongoDB tabs) | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>B</kbd> |
| Logs | <kbd>⌘</kbd><kbd>L</kbd> |

### Window

| Command | Shortcut |
| --- | --- |
| Connections | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>C</kbd> |
| Quick Run | None; <kbd>⌃</kbd><kbd>⌥</kbd><kbd>R</kbd> from any app when its [global shortcut](quick-run.md#the-global-shortcut) is on |
| Next Tab | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>]</kbd> |
| Previous Tab | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>[</kbd> |
| Reopen Closed Tab | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>T</kbd> |
| Select Tab 1 to 8 | <kbd>⌘</kbd><kbd>1</kbd> to <kbd>⌘</kbd><kbd>8</kbd> |
| Select Last Tab | <kbd>⌘</kbd><kbd>9</kbd> |

## Keys in Lists and Sheets

| Where | Keys |
| --- | --- |
| History and Snippets | <kbd>Return</kbd> or double-click opens the entry (see [History](running-code.md#run-history)), <kbd>⌘</kbd><kbd>Return</kbd> opens it in a new tab, <kbd>⇧</kbd><kbd>Return</kbd> inserts it at the cursor, and <kbd>⌫</kbd> deletes it (a personal snippet asks first). Typing searches. |
| A production confirmation | <kbd>⌘</kbd><kbd>Return</kbd> runs; <kbd>Return</kbd> and <kbd>Esc</kbd> cancel. |
| Renaming a tab | <kbd>Return</kbd> or <kbd>Tab</kbd> keeps the new name, and <kbd>Esc</kbd> the old one. See [Tabs](tabs.md#renaming-a-tab). |
| The editor | <kbd>Esc</kbd> closes completions and value panels, and can also [hide the output pane](running-code.md#showing-and-hiding-the-pane). |
| The Quick Run panel | <kbd>⌘</kbd><kbd>R</kbd> runs, <kbd>⌘</kbd><kbd>.</kbd> stops, <kbd>⌘</kbd><kbd>Return</kbd> opens the code in a tab, and <kbd>Esc</kbd> or <kbd>⌘</kbd><kbd>W</kbd> closes it. See [Quick Run](quick-run.md#keys-in-the-panel). |

## For developers

- Every command, its title, menu category, keywords, and default shortcut are in `CommandCatalog` (`Runlet/App/Commands.swift`). The menus (`RunletCommands` in `Runlet/App/RunletApp.swift`), the command palette, the toolbar's tooltips, and Settings ▸ Shortcuts (`ShortcutSettingsView.swift`) are built from it, so a remapped shortcut updates everywhere. `CommandCatalog` also checks that no two commands share a default shortcut.
- Overrides are saved as `shortcutOverrides` in `settings.json`; `ShortcutResolver` (`Shortcuts.swift`, RunletCore) applies them and finds conflicts.
- The move and duplicate line commands are `LineCommand` (`Runlet/Editor/EditorLineMoves.swift`, [#234](https://github.com/filipac/runlet/issues/234)). Their keys keep their usual meaning outside the editor.
- **Show Inline Value**, **Clear Inline Values**, **Show Run Log**, the Appearance commands, and **Float on Top** are in the catalog, so the command palette and Settings ▸ Shortcuts list them. Show Inline Value and Clear Inline Values are in the Edit menu, and Show Run Log in the Run menu, all without a default shortcut.
- Quick Run's global shortcut ([#25](https://github.com/filipac/runlet/issues/25)) is outside the catalog: `quickRunHotKeyEnabled` and `quickRunHotKey` in the settings, registered with Carbon's `RegisterEventHotKey`, and refused when one of the catalog's effective shortcuts uses the same combo. See [Quick Run ▸ For developers](quick-run.md#for-developers). Window ▸ Quick Run is the catalog's `window.quickRun`, without a default shortcut.
- ⌥⌘, is `AdvancedSettingsTrigger` (`Runlet/App/AppModel+FeatureFlags.swift`), a key monitor outside the catalog, so it can't be remapped. Open Anything's prefixes and keys are in `Runlet/Features/Palette.swift`.
- Usage ranking ([#328](https://github.com/filipac/runlet/issues/328)) is `CommandUsage` (the record) and `CommandRanking` (the order), in `CommandUsage.swift` (RunletCore), tested in `CommandUsageTests`:
  - **Frecency.** A use adds 1 to a command's weight, which halves every 14 days (`CommandUsage.halfLife`). The record keeps at most 200 ids (`capacity`), forgets a weight below 0.01 (one use after about 93 days), and drops ids that are no longer in `CommandCatalog`, at launch and on each use.
  - **Empty search.** Up to 5 enabled commands with a frecency of at least 0.25 (`frequentLimit`, `frequentMinimum`) come first, marked `isFrequent` for the **Frequently Used** label; then the catalog order.
  - **Query.** Rows are sorted by `FuzzyMatch` score as before. Then only the commands are reordered, in the places commands hold, by score plus a boost of `5 × f / (f + 3)` points for frecency `f` (`maxBoost`, `halfBoostFrecency`): always under 5, a quarter of the gap between a title that starts with the query (100) and one where a later word does (80 at most). Disabled commands get no boost.
  - **Storage.** `State/command-usage.json` (`AppModel.commandUsage`), saved half a second after a use and on quit. `PaletteView.choose` records the use, keyed by the row's catalog id (`command.<id>`, or the id of Open Anything's window and Help rows). **Clear Command History** (`AppModel.clearCommandUsage()`) deletes the file and its last-good copy (`JSONDocumentStore.remove()`).
- Shortcut tips ([#345](https://github.com/filipac/runlet/issues/345)) are `ShortcutTipRule`, `ShortcutTipRecord`, `CommandSource`, and `ShortcutTipText`, in `ShortcutTips.swift` (RunletCore), tested in `ShortcutTipsTests`:
  - **The rule.** A tip shows for a `menu`, `toolbar`, `button`, or `palette` source and a command with an effective shortcut; at most once in 24 hours per command (`interval`); never after 3 uses of the shortcut (`learnedAfter`: one use can be a coincidence, by the third it's a habit) or Don't Show Again; and never with `shortcutTips` off.
  - **Where a command comes from.** Every command runs through `AppModel.perform(_:source:in:)` (`Commands.swift`), which hides the tip on screen first. Menu items call `performFromMenu`, which reads `NSApp.currentEvent`: a key down is the shortcut (`keyboard`), anything else a click (`menu`). The Quick Run panel's redirect still applies to those two. Toolbar and window buttons that do what a command does run it with `toolbar` or `button` and their window, which becomes the active window first; their tooltips come from `commandHelp(_:_:detail:)`, so a remapped shortcut shows. Palette rows pass `palette`; debug steps and tours pass `script`, which is never counted. A tab's close button keeps its own action, and counts as Close Tab when it closes the selected, unpinned tab (`closeTabFromButton`).
  - **The tip.** `ShortcutTipPresenter` (`AppModel+ShortcutTips.swift`) holds the tip on screen, an observable of its own, read only by `ShortcutTipHost` (`ShortcutTipView.swift`), an overlay on the tab's editor and output, so it redraws nothing else. `ShortcutTipAnchor`, behind them, tells the presenter where they are: the tip goes to the top when the caret's line (`EditorController.caretLineRectInWindow`) is in their bottom 64 points, and isn't shown when the line is in both places. It hides after 5 seconds, and is announced with `NSAccessibility`'s `announcementRequested`.
  - **Storage.** `State/shortcut-tips.json` (`AppModel.shortcutTipRecord`): per command id, the uses by source, the last tip's date, and Don't Show Again. It's saved half a second after a use and on quit, and drops ids that are no longer in the catalog at launch. An entry that doesn't decode is dropped alone; sources a Runlet doesn't know are kept. Clear Command History keeps only Don't Show Again.
  - **Checks.** `ShortcutTipDebugSteps`: `shortcut-tip:<id>[|<source>]` (a click, without running the command; the tip stays for screenshots), `shortcut-tips:on|off`, `shortcut-tip-key`, `shortcut-tip-menu`, `shortcut-tip-dont-show`, `shortcut-tip-clear`, and `shortcut-tip-state`. Scripted runs show no tip for a click until one of them asks, so other features' screenshots never catch one. `scripts/shortcut-tip-check.py` checks the whole flow in a hidden Debug build and takes the pull request's screenshots.
