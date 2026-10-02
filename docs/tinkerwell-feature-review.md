# Tinkerwell feature review for the Runlet MVP

Reviewed 2026-10-02. Sources: every page in the Tinkerwell 5 docs navigation (Getting Started, Setup Guides, Basic Usage, Advanced Usage, Extending, Troubleshooting), the [changelog](https://tinkerwell.app/changelog), and the [command palette feature page](https://tinkerwell.app/features/command-palette). Runlet's status comes from `plan.md`, `CHANGELOG.md`, `docs/validation.md`, `docs/drivers.md`, and the app code, not from the feature list in the request.

**Out of scope:** AI chat and completion, MCP, Vapor, Laravel Cloud, Forge, Kubernetes, SSH and remote targets (including Homestead and WSL2), licensing, the PhpStorm plugin, and deep Herd integration. They stay in `plan.md` as deferred work and are not reviewed here.

**Effort:** S is about a day or less. M is 2–4 days. L is a week or more.

## 1. Summary

Runlet already covers the core of the Tinkerwell workflow: tabs, sandbox, local and Docker targets, Run and Run Selection, Stop, structured and plain output, tables with CSV export, history, personal snippets, and completion. In some areas it goes further, for example Docker profiles, workspaces, and running without host PHP. The biggest gaps are in **keyboard-driven control of the app**, not in execution:

1. **Add a real command palette.** Today's ⌘P palette only switches targets. Tinkerwell users expect one fuzzy search box for every command, snippet, project, and connection, with `#`, `/`, and `@` category prefixes. *(M)*
2. **Let users change shortcuts.** Tinkerwell lets you remap every shortcut in Settings. It even removed ⌘S-to-run and told users to remap it themselves. Runlet's shortcuts are hard-coded. Build this on the same command registry as the palette. *(M)*
3. **Make tab handling safe and complete.** ⌘W currently throws away a tab's code without asking and with no undo. Add Reopen Closed Tab, Close Tabs to the Right, ⌘1–⌘9, and ⌃Tab. *(S)*
4. **Support project snippets** in `.runlet/snippets/*.php` with `@label` and `@description`, so teams can share them through git. Runlet already reads `.runlet/` for drivers. *(S–M)*
5. **Fill in small daily-use gaps:** keyboard-first history and snippets, a strict-types toggle, output-pane toggles, editor font, line height and wrapping, opening dump and error locations in the user's IDE, a `runlet .` terminal command, and output export. *(S each, editor preferences M)*

Keep magic comments, SQL inspection, HTML and mail previews, the log viewer, Xdebug, auto-run, formatting, themes, and Vim mode as the first post-MVP wave. They are valuable but larger, or they need a product decision first.

## 2. Feature table

Status: **Have**, **Partial**, or **Missing**. Recommendation: **MVP-must**, **MVP-should**, **Later**, or **Skip**.

### Command palette and keyboard

| Tinkerwell feature | What it does | Runlet today | Rec. | Rationale and effort |
| --- | --- | --- | --- | --- |
| Command palette / Open Anything ([docs](https://tinkerwell.app/docs/5/basic-usage/command-palette), [feature page](https://tinkerwell.app/features/command-palette)) | One fuzzy search over recent folders, connections, snippets, and app commands (including mouse-only ones). | **Partial.** The ⌘P Switch Target palette (`Features/TargetSwitcher.swift`) lists only the sandbox, local projects, and Docker profiles. It matches each search word as a substring (`matchesSearch` in `RunletCore/Models.swift`) and sorts by last use, not relevance. It has no commands, snippets, or history. | MVP-must | This is the main way to drive the app from the keyboard. It needs a command registry, which shortcut customization also needs. **M** |
| Search categories `#` `/` `@` ([docs](https://tinkerwell.app/docs/5/basic-usage/command-palette)) | The prefix narrows results to snippets, folders, or connections. | **Missing** | MVP-must | Cheap once the palette exists. Map `#` to snippets, `/` to local projects, `@` to Docker profiles (Runlet's equivalent of connections), and `>` to commands. **S** |
| Palette commands, e.g. "Open default Laravel" and "Toggle Debugging" ([changelog](https://tinkerwell.app/changelog), [Xdebug](https://tinkerwell.app/docs/5/advanced-usage/debugging-with-xdebug)) | Runs any app action by name. | **Missing.** Actions are only in menus and the toolbar (`App/RunletApp.swift`). | MVP-must | Part of the palette item. **—** |
| Customizable shortcuts ([docs](https://tinkerwell.app/docs/5/advanced-usage/shortcuts)) | Settings list every shortcut. Click one and press new keys to rebind it. | **Missing.** Shortcuts are fixed `.keyboardShortcut` values in `RunletCommands`, and the toolbar help text repeats them as literal strings. | MVP-must | Requested by the user. Tinkerwell relies on it for muscle-memory conflicts (it dropped ⌘S-to-run for this reason). Uses the same registry as the palette. **M** |
| Vim mode (keymap in the installed app; not in the public docs, see `plan.md` §6) | Modal Vim editing. | **Missing** | Later | NSTextView has no Vim layer, so Runlet would have to build one. Worth it only if the user lives in Vim. **L** |

### Running code

| Tinkerwell feature | What it does | Runlet today | Rec. | Rationale and effort |
| --- | --- | --- | --- | --- |
| Run with ⌘R ([docs](https://tinkerwell.app/docs/5/basic-usage/evaluating-code)) | Runs the editor's code. | **Have.** Run, Run Selection (⇧⌘R), and Stop (⌘.). | — | — |
| Prefer the selection when running ([changelog](https://tinkerwell.app/changelog)) | Run uses the selected text if there is any. | **Have.** Settings ▸ General ▸ "Run prefers selection". | — | — |
| Auto-run ("Auto evaluate script") ([settings](https://tinkerwell.app/docs/5/getting-started/settings)) | Reruns the code on every change. Tinkerwell turns it off for remote targets. | **Missing.** `plan.md` makes manual runs the default on purpose. | Later | Dangerous against real databases. If added, allow it only for the sandbox, with a debounce. **S** |
| Strict types toggle ([changelog](https://tinkerwell.app/changelog), 5.x) | Applies `declare(strict_types=1)` to every run on every backend. | **Partial.** A snippet can declare strict types itself (the runner is tested for this), but there is no setting. | MVP-should | Small: the runner adds the declaration. Make it a global setting with a per-target override. **S** |
| Prettify code and format before run ([shortcuts](https://tinkerwell.app/docs/5/advanced-usage/shortcuts), [changelog](https://tinkerwell.app/changelog)) | Formats the code manually, or automatically before each run, with a quote-style option. | **Missing.** External formatters are disabled in PHPantom. | Later | Needs a formatter choice that works without host PHP. **M** |
| Default project ([sandbox guide](https://tinkerwell.app/docs/5/setup-guides/using-the-laravel-sandbox)) | New tabs open a chosen project instead of the sandbox. | **Have.** Settings ▸ General ▸ New Tabs ▸ Default target (sandbox, project, or Docker profile). | — | — |
| Project-specific PHP ([docs](https://tinkerwell.app/docs/5/advanced-usage/project-specific-php)) | Choose the PHP binary per project from the footer. | **Have.** `ProjectSettingsSheet` has a PHP picker. The footer is not clickable. | Later | Making the status-bar PHP version open the picker is optional polish. **S** |
| Real-time vs. buffered output ([changelog](https://tinkerwell.app/changelog)) | Streams output while the code runs. | **Have.** Run events are applied as they arrive (`AppModel.run`). | — | — |
| Time, memory, and start time ([changelog](https://tinkerwell.app/changelog)) | The footer tooltip shows the run's time, memory, and start time. | **Have.** Elapsed time is in the status bar, and the finished card shows peak memory. | — | — |
| Framework detection and custom drivers ([evaluating code](https://tinkerwell.app/docs/5/basic-usage/evaluating-code), [custom drivers](https://tinkerwell.app/docs/5/extending-tinkerwell/custom-drivers)) | Detects the framework automatically, and supports project or global driver classes with predefined variables. | **Have (in progress).** Built-in Laravel, WordPress, Symfony, Composer, and plain drivers. Project drivers load from `.runlet/*Driver.php`, and their variables are passed to completion (`docs/drivers.md`). There are no global drivers. | Later | Global drivers (`~/Library/Application Support/Runlet/Drivers`) are a small follow-up. **S** |
| Xdebug ([docs](https://tinkerwell.app/docs/5/advanced-usage/debugging-with-xdebug)) | Turns on step debugging for a tab so the IDE stops at breakpoints. Tinkerwell supports this only with Herd. | **Missing** | Later | Useful, but needs per-target environment variables or INI settings and Docker path mappings. **M** |
| Collision errors ([docs](https://tinkerwell.app/docs/5/advanced-usage/collision)) | Error output with a stack trace and the offending code. | **Have (equivalent).** Error cards show the stage, the message, a line/column link, and the stack trace (`OutputPane.swift`). | Skip | Showing a few source lines for project-file frames could come later. |

### Output

| Tinkerwell feature | What it does | Runlet today | Rec. | Rationale and effort |
| --- | --- | --- | --- | --- |
| Detail Dive cards and CLI mode ([docs](https://tinkerwell.app/docs/5/basic-usage/detail-dive)) | Structured, expandable cards per dump, or a classic tinker transcript. | **Have.** Structured, Plain, and Raw modes, plus a collapsed / first-level / expand-all preference. | — | Add a "Cycle output mode" command for the palette and shortcuts (Tinkerwell uses ⇧⌘C). **S** |
| Table view and CSV ([docs](https://tinkerwell.app/docs/5/basic-usage/detail-dive), [table mode](https://tinkerwell.app/features/table-mode)) | Shows collections as a table and saves them as CSV. | **Have.** Sort, filter, Copy CSV, and Export CSV (`ValueTableView`). | — | — |
| Copy a table row as JSON or a PHP array ([docs](https://tinkerwell.app/docs/5/basic-usage/detail-dive)) | Right-click a row to copy it. | **Missing** | MVP-should | A small context menu. **S** |
| Copy output, copy as Markdown, save output to a file ([changelog](https://tinkerwell.app/changelog)) | Copy the output (also as Markdown), or save it to a file. | **Partial.** Copy Output (⌥⌘C) copies plain text. There is no Markdown copy and no save to file. | MVP-should | Add "Save Output As…" (.txt or .md) and "Copy as Markdown". **S** |
| Clear output ([shortcuts](https://tinkerwell.app/docs/5/advanced-usage/shortcuts)) | Empties the output pane. | **Have** (⌘K) | — | — |
| Open the dump's file in your editor ([docs](https://tinkerwell.app/docs/5/basic-usage/detail-dive)) | Clicking a project file path opens it at that line in your editor (PhpStorm, VS Code, Sublime, Zed, …). | **Partial.** Links jump to snippet lines in Runlet's own editor. Project-file stack frames show only the file name. | MVP-should | Add a "Preferred editor" setting and URL-scheme handlers. Map Docker paths through the profile's `localSourcePath`. Add an "Open Project in Editor" command. **S–M** |
| SQL query inspection ([docs](https://tinkerwell.app/docs/5/basic-usage/detail-dive)) | Lists the queries a run executed, with bindings. | **Missing.** Deferred in `plan.md`. | Later (first post-MVP) | Fits well: `LaravelDriver` can call `DB::listen` and send structured events. **M** |
| HTML preview of views and mailables ([docs](https://tinkerwell.app/docs/5/basic-usage/detail-dive)) | Renders the HTML. Rerunning refreshes the preview. | **Missing.** Deferred. | Later | A sandboxed WKWebView sheet. **M** |
| Object graph ([docs](https://tinkerwell.app/docs/5/basic-usage/detail-dive)) | Shows nested data as clickable graph nodes. | **Missing** | Skip | The expandable tree already covers this need. |
| Magic comments ([docs](https://tinkerwell.app/docs/5/advanced-usage/magic-comments)) | `//?`, `/*?->count()*/`, and `/*?.*/` show inline values and timings in the editor. | **Missing.** Deferred. | Later (first post-MVP) | Tinkerwell's signature feature. The AST runner makes it possible, but source mapping and inline decorations are real work. **L** |

### History and snippets

| Tinkerwell feature | What it does | Runlet today | Rec. | Rationale and effort |
| --- | --- | --- | --- | --- |
| History ([docs](https://tinkerwell.app/docs/5/basic-usage/history)) | ⌘Y opens a keyboard-driven list with search. Return loads into the current tab, ⌘Return into a new tab. | **Partial.** ⌘Y opens the History side panel (`LibraryInspector.swift`) with search, delete, clear, Save as Snippet, and Copy. Double-click opens in a new tab, and the context menu offers the current tab. There is no Return / ⌘Return flow, and the search field is not focused on open. | MVP-should | Make the panel keyboard-first. History should also be searchable from the palette. **S** |
| History retention ([changelog](https://tinkerwell.app/changelog)) | Configurable size (default 150). | **Have.** Settings ▸ General ▸ History: 50–10,000 runs, default 1,000, with Clear History. | — | — |
| Personal snippets ([docs](https://tinkerwell.app/docs/5/basic-usage/snippets)) | Save the whole editor or the selection with a label. Search, then Return or ⌘Return. | **Have.** ⌥⌘S saves the selection or the whole tab. Snippets can be edited, duplicated, deleted, and searched. ⇧⌘L opens the panel. | — | Same keyboard-first fix as History. |
| Snippet bound to a project or connection ([changelog](https://tinkerwell.app/changelog)) | Opening the snippet also opens its target. ⇧Return pastes it into the current tab regardless. | **Partial.** Snippets store an optional target. "Open in New Tab" uses it, but "Open in Current Tab" only replaces the code. Snippets have no description field. | MVP-should | Opening a snippet should offer to switch to its target, plus an "Insert at Cursor" action and a description field. **S** |
| Project snippets ([docs](https://tinkerwell.app/docs/5/basic-usage/snippets), [feature page](https://tinkerwell.app/features/snippets)) | PHP files in `.tinkerwell/snippets` with `@label` and `@description`, shared through git. | **Missing** | MVP-should (high) | Runlet already reads `.runlet/` for drivers, so `.runlet/snippets/` is the natural place. **S–M** |

### Tabs, files, and windows

| Tinkerwell feature | What it does | Runlet today | Rec. | Rationale and effort |
| --- | --- | --- | --- | --- |
| New, close, and switch tabs ([docs](https://tinkerwell.app/docs/5/basic-usage/tabs)) | ⌘T and ⌘W; ⌃Tab and ⌘⌥←/→ to switch; ⌘1–⌘9 to jump to a tab. | **Partial.** ⌘T, ⌘W, and ⇧⌘] / ⇧⌘[ exist. There is no ⌘1–⌘9 and no ⌃Tab. | MVP-must | Standard and cheap. **S** |
| Rename, duplicate, close others ([changelog](https://tinkerwell.app/changelog)) | Double-click to rename; duplicate with ⇧⌘D; close others or close to the right. | **Partial.** Rename, Duplicate (⇧⌘D), and Close Other Tabs are in the context menus (`MainWindow.swift`, `VerticalTabs.swift`). There is no Close Tabs to the Right. | MVP-must | Bundle with the other tab fixes. **S** |
| Ask before closing a tab ([changelog](https://tinkerwell.app/changelog)) | Optional confirmation, skipped for empty tabs. | **Missing.** `AppModel.closeTab` discards the code immediately. Only closing a window asks first. | MVP-must | Prevents data loss. Prefer **Reopen Closed Tab (⇧⌘T)** over a dialog, and make the confirmation optional. **S** |
| Tab restore ([changelog](https://tinkerwell.app/changelog)) | Tabs come back after a restart. | **Have.** Windows and tabs are restored without running anything (`docs/validation.md`, M15). | — | — |
| Open and save files ([changelog](https://tinkerwell.app/changelog)) | Save a tab as a file. | **Have.** Open (⌘O), Save (⌘S), Save As, `.runlet` workspaces, and Finder or CLI opening. | — | — |
| Watch file (installed app; see `plan.md` §6) | Follows a file that is edited elsewhere. | **Missing.** File-backed tabs do not notice changes on disk, so ⌘S can overwrite someone else's edits. | MVP-should | At minimum: reload automatically if the tab has no unsaved edits, otherwise ask. Auto-run on change can come later. **S** |
| Terminal launcher ([CLI helper](https://tinkerwell.app/docs/5/advanced-usage/cli-helper)) | `tinkerwell [path]` opens that directory as a project. | **Partial.** The app binary accepts `.php` and `.runlet` arguments. It does not handle directories, and there is no `runlet` command on PATH. | MVP-should | Add `runlet [path]` (directory → project tab, file → tab) and Settings ▸ Install Command-Line Tool. **S–M** |
| Recent folders in the Dock menu ([changelog](https://tinkerwell.app/changelog)) | Right-click the Dock icon to open a recent project. | **Missing** | Later | **S** |

### Layout and editor preferences

| Tinkerwell feature | What it does | Runlet today | Rec. | Rationale and effort |
| --- | --- | --- | --- | --- |
| Horizontal or vertical split; toggle the layout with ⌃. ([settings](https://tinkerwell.app/docs/5/getting-started/settings), [shortcuts](https://tinkerwell.app/docs/5/advanced-usage/shortcuts)) | Output to the right or below the editor. | **Partial.** Settings ▸ General ▸ Output pane (right or below). No command or shortcut. | MVP-should | Add a "Swap Output Position" command. **S** |
| Toggle the output pane; auto-hide output ([shortcuts](https://tinkerwell.app/docs/5/advanced-usage/shortcuts), [changelog](https://tinkerwell.app/changelog)) | Hide or show the output (⌥⇧⌘O). Auto-hide hides it until a run, and Esc hides it again. | **Missing** | MVP-should (toggle), Later (auto-hide) | Gives the editor full width when writing longer snippets. **S** |
| Hide the toolbar ([shortcuts](https://tinkerwell.app/docs/5/advanced-usage/shortcuts)) | Minimal interface. | **Have (system).** The standard macOS View ▸ Hide Toolbar command. Not covered by UI tests. | — | — |
| Fullscreen, pin window (installed app; `plan.md` §6) | Fullscreen, and keep the window above other apps. | **Fullscreen: Have (system). Pin: Missing.** | Later | A floating level on the window is quick to add; useful next to an IDE. **S** |
| Themes and custom theme files ([custom themes](https://tinkerwell.app/docs/5/advanced-usage/custom-themes)) | Many editor themes, plus Monaco-format JSON files in `~/.config/tinkerwell/themes`. | **Partial.** System, Light, or Dark appearance. Syntax colors are fixed (`PHPHighlighter.swift`). | Later (themes), Skip (Monaco JSON) | A few built-in syntax themes are enough. Don't copy Tinkerwell's file format. **M** |
| Font family, font size, ligatures, line height ([settings](https://tinkerwell.app/docs/5/getting-started/settings), [changelog](https://tinkerwell.app/changelog)) | Editor typography. | **Partial.** Font size only (9–28 pt). The font is fixed to the system monospaced font, and line height is fixed at 1.15 (`EditorController.swift`). No ligatures. | MVP-should | Add a monospaced font picker and line height. Ligatures are a single text attribute. **M** for all three |
| Word wrap (installed app; `plan.md` §6) | Soft-wraps long lines. | **Missing.** The editor always scrolls horizontally (`CodeTextView.configureForCode`). | MVP-should | View ▸ Wrap Lines. Check the line-number ruler with wrapped lines. **S** |
| Indentation guides ([changelog](https://tinkerwell.app/changelog)) | Vertical guide lines at each indent level. | **Missing** (tab width and spaces/tabs are settings). | Later | Custom drawing in the layout manager. **M** |
| Trigger completion ([shortcuts](https://tinkerwell.app/docs/5/advanced-usage/shortcuts)) | Opens completion manually. | **Have** (⌃Space, ⌥Esc). | — | — |
| Reindex / language-server status ([autocompletion](https://tinkerwell.app/docs/5/setup-guides/autocompletion)) | Click the status to reindex. | **Have.** Status-bar PHPantom state and Library ▸ Restart Language Server. | — | — |

### Logs, panels, and extending

| Tinkerwell feature | What it does | Runlet today | Rec. | Rationale and effort |
| --- | --- | --- | --- | --- |
| Log viewer ([docs](https://tinkerwell.app/docs/5/advanced-usage/log-viewer)) | Pick a log file, filter by level, search, and poll for updates. | **Missing.** Deferred in `plan.md`. | Later | Needs file access for both local and Docker targets. **M** |
| Information panels ([panels](https://tinkerwell.app/docs/5/extending-tinkerwell/panels)) | App info such as version, environment, and cache/driver status, from the footer. | **Partial.** The status bar and vertical tabs show the runtime, PHP, framework or driver, and version. | Later | A Laravel "About" panel could come later. **M** |
| Custom panels ([panels](https://tinkerwell.app/docs/5/extending-tinkerwell/panels)) | `.tinkerwell/panels/*Panel.php` and `appPanels()` key/value tables. | **Missing** | Later | Could become a `panels()` method on `Runlet\Driver` once drivers are stable. **M** |

### Deferred or out of scope (not reviewed)

AI chat and AI completion, MCP server, Vapor, Laravel Cloud, Forge, Kubernetes, SSH and Docker over SSH, Homestead and WSL2 (both rely on SSH), licensing, the PhpStorm plugin, Herd integration, and Tinkerwell Wrapped. Tinkerwell's Sail, DDEV, Lando, and Warden support is covered by Runlet's Docker profiles.

## 3. Prioritized MVP backlog

The IDs continue after `plan.md`'s M01–M22. Items B01–B04 are MVP-must; the rest are MVP-should, in priority order.

| ID | Capability | Acceptance criteria | Effort |
| --- | --- | --- | --- |
| B01 | Command registry and palette | Every menu and toolbar action is registered once, with an ID, title, category, default shortcut, and enabled state. ⇧⌘P opens a palette listing every command with its current shortcut and whether it is enabled. Matching is fuzzy (subsequence, ranked by relevance and then recent use), so `rsel` finds "Run Selection". Return runs the chosen command and Esc closes the palette. Disabled commands are shown dimmed with the reason. Opening the palette never runs code. Toolbar help text and menus read shortcuts from the registry. | M |
| B02 | Open Anything (⌘P) | ⌘P searches the sandbox, local projects, Docker profiles, personal and project snippets, and recently opened files in one fuzzy list, grouped by kind. `#` limits results to snippets, `/` to local projects, `@` to Docker profiles, and `>` to commands, so ⇧⌘P is the same palette with `>` already typed. Return uses the item in the current tab and ⌘Return opens it in a new tab. Choosing a snippet loads its code and offers its target, but never runs it. Arrow keys move the selection. Esc clears the query first, then closes. | S (after B01) |
| B03 | Custom shortcuts | Settings ▸ Shortcuts lists every registered command with a search field. Click a shortcut and press keys to record a new one. Conflicts are shown and must be resolved. A command's shortcut can be cleared. "Reset to Defaults" works per command and for all. Changes apply immediately to menus, the toolbar help text, and the palette, and survive a restart. Editor keys that are not menu commands (⌃Space) are listed as fixed. | M |
| B04 | Safe, complete tab handling | ⇧⌘T reopens the last closed tab (code, title, target, and file) from a stack of at least 20, during the session. The tab context menu has Close Tabs to the Right. ⌘1–⌘8 select tabs 1–8 and ⌘9 the last tab. ⌃Tab and ⌃⇧Tab cycle tabs in both tab layouts. An optional setting, "Ask before closing a tab with code", confirms ⌘W on tabs that are not empty. Closing a tab never runs code. | S |
| B05 | Project snippets | Runlet loads `<project>/.runlet/snippets/*.php` for a local project, or for a Docker profile's `localSourcePath`. A docblock's `@label` and `@description` become the title and subtitle; without them, the filename is the title and the rest of the file is the code. Project snippets appear in the Snippets panel and in ⌘P under a project badge, in file order, and are read-only in the UI. "Save to Project Snippets…" writes a new file. Files are reloaded when the folder changes. Loading a snippet never runs it. | S–M |
| B06 | Keyboard-first History and Snippets | ⌘Y and ⇧⌘L open their panel with the search field focused. ↑/↓ move the selection, Return loads into the current tab, ⌘Return opens a new tab, and ⇧Return inserts at the cursor. Snippets get an optional description. Opening a snippet that has a target in the current tab asks whether to switch the tab to that target. None of these actions run code. | S |
| B07 | Strict types | Settings ▸ Running has "Declare strict_types=1 for every run" (default off). Project options and Docker profiles can override it (inherit, on, or off). The runner applies it to full runs and selection runs on local, Docker, and sandbox targets without changing the editor's text or line mapping. A snippet that already declares strict types is not changed. | S |
| B08 | Layout commands | View ▸ Toggle Output Pane hides and restores the output pane, keeping its size. View ▸ Swap Output Position switches between right and below (default ⌃.). View ▸ Cycle Output Mode switches between Structured, Plain, and Raw. All three are registry commands with shortcuts that can be changed. A finished run while the output is hidden shows a status-bar badge rather than reopening the pane. | S |
| B09 | Editor typography and wrapping | Settings ▸ Editor offers a monospaced font family (installed fixed-pitch fonts, default system mono), line height (1.0–2.0), ligatures on/off, and soft wrap. View ▸ Wrap Lines (⌥Z) toggles wrapping for the session. The line-number ruler, diagnostics underlines, completion popup, and go-to-line positions stay correct with each setting. | M |
| B10 | Open in external editor | Settings ▸ General ▸ Preferred editor: PhpStorm, VS Code, Cursor, Zed, Sublime Text, Nova, or none. Project file paths in dump cards and stack frames become links that open the file at that line. Container paths for Docker targets are mapped through `localSourcePath`; if there is no mapping, the path is shown as plain text with an explanation. An "Open Project in Editor" command opens the tab's project root. | S–M |
| B11 | Terminal launcher | Settings ▸ General ▸ "Install Command-Line Tool" installs a `runlet` script (into `/usr/local/bin` after asking for permission, or prints instructions for `~/.local/bin`). `runlet` and `runlet .` open the current directory as a local project in a new tab. `runlet <dir>`, `runlet <file.php>`, and `runlet <workspace.runlet>` behave the same way. If the app is already running, the existing app is reused. Nothing runs automatically. | S–M |
| B12 | Output export | Run ▸ Save Output As… writes the current output mode to `.txt`, or Markdown with fenced code blocks to `.md`. "Copy Output as Markdown" goes next to Copy Output. Table rows have a context menu with Copy Row as JSON and Copy Row as PHP Array, with keys preserved. | S |
| B13 | External file changes | A tab backed by a file notices when that file changes on disk. With no unsaved edits it reloads silently. With unsaved edits it shows "Reload / Keep Mine". ⌘S never overwrites a newer file on disk without asking. A reload never runs code. | S |

Suggested order: B01 → B02 → B04 → B03 → B05 → B06, then B07–B13 in any order. B02 and B03 depend on B01.

**First post-MVP wave** (from the table): SQL inspector (M), magic comments (L), HTML and mail preview (M), log viewer (M), Xdebug for local and Docker targets (M), sandbox-only auto-run (S), formatting and format-before-run (M), syntax themes (M), global drivers (S), and Vim mode (L, only if requested).

## 4. What Runlet does that Tinkerwell doesn't

- **Docker profiles.** Profiles survive container recreation using Compose project and service identity, ask when several replicas match, and support a non-root user, a custom tmp directory, and a local source mapping. Stop kills only the run inside the container and leaves the container running.
- **No host PHP needed.** A Docker-backed sandbox and the native PHPantom language server work without PHP on the Mac. Tinkerwell needs local PHP 8.1+ for its language server.
- **Multiple windows and `.runlet` workspace files** that store tabs and portable target definitions.
- **Vertical tabs** that show each tab's runtime, PHP version, framework or driver, and last run status.
- **A Raw output mode** that shows exactly the bytes PHP wrote, next to Structured and Plain.
- **Driver variables in completion.** Variables a driver injects (`$app`, project-driver variables) are offered by completion.
- **Run Selection is always available** as its own command, separate from the "Run prefers selection" setting.
- **Code never runs implicitly.** Opening, saving, restoring, loading history, and switching targets never run code.

## 5. Open questions

1. **Palette shortcuts.** Tinkerwell's own docs disagree: the command palette page says ⌘P, but the shortcuts page and the Xdebug guide use ⇧⌘P and give ⌘P to Prettify. Is the proposal of ⌘P for Open Anything and ⇧⌘P for commands (as in VS Code) right?
2. **History in the palette.** Should history entries appear in ⌘P by default, or only after a prefix (for example `!`) to keep results short?
3. **Snippet folder.** Should Runlet also read `.tinkerwell/snippets/` (read-only) to make migration easy, or only `.runlet/snippets/`?
4. **Closing tabs.** Is Reopen Closed Tab enough, or do you want the confirmation dialog on by default?
5. **Vim mode.** Do you need it for the MVP? It is the most expensive item here (L).
6. **Auto-run.** Do you want it at all? If so, should it be limited to the sandbox?
7. **External editors.** Which editors should B10 support first?
8. **Magic comments and SQL inspection.** These are Tinkerwell's best-known features. Should one of them move into the MVP? SQL inspection is the cheaper of the two.
9. **CLI install location.** `/usr/local/bin` needs an admin prompt. Is a user-level path with instructions acceptable?
