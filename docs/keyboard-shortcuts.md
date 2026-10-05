# Keyboard Shortcuts

Everything in Runlet's menus can be reached from the keyboard. This page lists the default shortcuts, menu by menu, and the two palettes that find everything else: Open Anything (<kbd>⌘</kbd><kbd>P</kbd>) and the command palette (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>P</kbd>).

## Changing Shortcuts

**Settings ▸ Shortcuts** lists every command, grouped like the menus, with a search field for commands or keys:

- **Record** a new shortcut: click it, then press the key combination. <kbd>Esc</kbd> cancels, and <kbd>Delete</kbd> clears the shortcut.
- **Reset to Default** and **Clear Shortcut** are next to a changed command, which shows its default below its name. **Reset All** puts every shortcut back.
- A shortcut used by two commands is marked with a warning: only one of them works.

The menus, the palettes, and the toolbar's tooltips always show your current shortcuts. Commands without a default shortcut, such as **New SQL Tab** or **Fold All**, can get one here.

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

## For developers

- Every command, its title, menu category, keywords, and default shortcut are in `CommandCatalog` (`Runlet/App/Commands.swift`). The menus (`RunletCommands` in `Runlet/App/RunletApp.swift`), the command palette, the toolbar's tooltips, and Settings ▸ Shortcuts (`ShortcutSettingsView.swift`) are built from it, so a remapped shortcut updates everywhere. `CommandCatalog` also checks that no two commands share a default shortcut.
- Overrides are saved as `shortcutOverrides` in `settings.json`; `ShortcutResolver` (`Shortcuts.swift`, RunletCore) applies them and finds conflicts.
- The move and duplicate line commands are `LineCommand` (`Runlet/Editor/EditorLineMoves.swift`, [#234](https://github.com/filipac/runlet/issues/234)). Their keys keep their usual meaning outside the editor.
- **Show Inline Value**, **Clear Inline Values**, **Show Run Log**, the Appearance commands, and **Float on Top** are in the catalog, so the command palette and Settings ▸ Shortcuts list them. Show Inline Value, Clear Inline Values, and Show Run Log have no menu item.
- ⌥⌘, is `AdvancedSettingsTrigger` (`Runlet/App/AppModel+FeatureFlags.swift`), a key monitor outside the catalog, so it can't be remapped. Open Anything's prefixes and keys are in `Runlet/Features/Palette.swift`.
