# Changelog

All notable changes to Runlet are recorded here. Dates use ISO format.

## Unreleased

### 2026-10-02 — SSH: the local folder, suggestions, and drift (SSH-3)

- An SSH profile's local folder (its checkout on this Mac) powers the same features as a
  local project: PHPantom completion and diagnostics, framework and driver facts read from
  local files (no network), project snippets and Save Snippet to Project…, host commands,
  Open Project in Editor, and the terminal's start folder. Without one, the profile runs in
  limited mode and says why.
- File links in output map server paths to the local folder, from both the profile's
  directory and the real path PHP reports, so Forge-style `…/current` and
  `…/releases/<id>/` paths open the same local file.
- Folder suggestions for profiles without a local folder: folders Runlet knows plus a
  shallow scan of `~/Code`, `~/Projects`, `~/Sites`, `~/Herd`, and similar, matched by the
  server's git remote, `composer.json` name (both after Test Connection), or folder name
  (including Forge site folders). Offered above the editor ("Use for Completion") and in
  the profile; never applied on its own.
- Optional drift warning (off by default): after Connect…, Test Connection, and the first
  run of a session, Runlet compares the local folder's branch and commit (or
  `composer.lock`, for deployments without `.git`) with the server's, read by the same
  read-only PHP check (no `git` runs on the server), and shows a yellow banner when they
  differ. It never blocks a run.
- Test Connection also reports the server checkout's git remote, branch, commit, and a
  `composer.lock` CRC-32.

### 2026-10-02 — SSH: Connect… and Disconnect for passwords and 2FA (SSH-2)

- SSH profiles that log in with a password, keyboard-interactive answers, a one-time code,
  or a key passphrase no agent holds use **Connect…**: a terminal tab runs
  `ssh -M -N -f` with Runlet's control socket, and OpenSSH asks its own questions there.
  Runlet never reads, stores, or logs what you type. Once logged in, ssh moves to the
  background, the tab closes, and runs reuse the login without prompts.
- The login stays until **Disconnect** (`ssh -O exit`; asks first when runs are in
  progress). Quitting Runlet doesn't end it, and Runlet finds it again after a restart.
  When the network drops it shows "Login ended" and the next run asks to Connect again.
- Status (Connected, Not connected, Login ended) is read from the control socket on this Mac,
  so checking never starts `ssh` or contacts the server. It shows in the status bar, the
  target menu, and the profile; a banner above the editor offers Connect… when a
  password profile isn't connected, while a login is in progress, and after a run failed
  for a reason Connect… fixes.
- Unknown host keys: Connect… forces OpenSSH's fingerprint question
  (`StrictHostKeyChecking=ask`, whatever `~/.ssh/config` says), so a key is only ever added
  by your answer. Runs still refuse unknown keys.
- New commands: Connect to SSH Host… and Disconnect from SSH Host (Library menu and the
  command palette). The profile sheet saves and closes before Connect… so you can type in
  the terminal. Debug step runner: `connect:<profile>`, `disconnect:<profile>`,
  `select:<tab>`, and `run`.

### 2026-10-02 — SSH targets: run snippets on a server (SSH-1)

- New target kind: **SSH hosts**. Library ▸ New SSH Profile… (also in the target menu,
  the command palette, and Settings ▸ Targets) saves a host (a `~/.ssh/config` alias or a
  host name, with optional user, port, and jump-host overrides), the application's
  directory on the server, the server's PHP, and an optional local folder. Tabs, ⌘P, the
  target menu, tab cards ("SSH" chip, `user@host:directory`), the status bar, workspaces,
  and history know them. Saving or opening a profile never connects.
- Runs use the system `/usr/bin/ssh`, so `~/.ssh/config` (aliases, `ProxyJump`,
  `IdentityAgent`, `Include`), ssh-agent, the 1Password agent, key files, `known_hosts`, and
  `UseKeychain` work as in Terminal. Runlet stores no keys or passwords. The runner is
  streamed to the server's PHP on stdin (nothing is written on the server), with
  `BatchMode=yes`, `StrictHostKeyChecking=yes` (never accepts an unknown host key), short
  connect and keep-alive timeouts, `LogLevel=ERROR` (no login banner in the output), and
  compression. Output, dumps, `dd`, `exit`, fatals, and limits behave as in local runs.
- One shared OpenSSH connection (ControlMaster) per profile serves runs, Stop, and Test
  Connection: agent and key profiles open it on the first run and keep it for 10 minutes
  (configurable, or until Disconnect). Sockets live in `Application Support/Runlet/SSH`.
- Stop on a server signals the runner and everything the snippet started (every process
  carrying the run's `RUNLET_RUN_ID`), after checking `/proc`, with Docker's
  SIGTERM/SIGKILL timing. Servers without `/proc` are left alone and the stop is reported
  as unconfirmed.
- `ssh` failures are explained in plain words (unknown or changed host key, rejected keys,
  unresolvable or unreachable host, lost connection, missing directory, PHP not found),
  with OpenSSH's own message kept below.
- Test Connection runs one read-only `php -r` on the server: PHP version and binary, user,
  OS, the directory and its real path (Forge's `current`), framework, tokenizer, Stop
  support, round-trip time, and the application folders and PHP binaries it finds.
- The Commands panel never lists an SSH host's commands by itself ("List Commands on
  <host>"); host commands run on this Mac in the local folder. Running server-side commands
  from the panel comes later.
- Tests: a disposable `runlet-fixtures` service `ssh` (OpenSSH + PHP 8.4, `127.0.0.1:2222`
  only) that the SSH tests start when needed, with a throwaway key, their own `ssh -F`
  config and `known_hosts`, and no agent. They cover runs, dumps, `dd`, exit, fatals,
  quoting, Stop with children, concurrent runs, a dead link, unknown host keys, rejected
  logins, and Test Connection. Debug builds read `RUNLET_SSH_CONFIG` instead of
  `~/.ssh/config`, and `RUNLET_DEBUG_STEPS` gained `ssh:new`/`ssh:<name>`.
- Docs: new [docs/ssh.md](docs/ssh.md); architecture and drivers updated.

### 2026-10-02 — Docs: next-release ideas and SSH design

- `docs/next-release-ideas.md`: a prioritized list of post-0.0.1 ideas from a full review of
  Tinkerwell's v5 docs and changelog, with a Tinkerwell→Runlet gap table, ideas grouped by
  theme (each with behaviour, fit in Runlet's code, size, safety notes, and priority), what
  to skip, and sources. Includes a detailed SSH targets design: system `ssh` with
  ControlMaster, password/2FA through a terminal login, an optional remote `docker exec`
  step, a local project folder per host, production guard rails, and milestones.

## 0.0.1 — 2026-10-02

First public build (ad-hoc signed, universal arm64 + x86_64).

### 2026-10-02 — Editor/output split is remembered

- The divider between the editor and the output pane keeps its position across launches,
  saved separately for output on the right and output below
  (`editorSplitRight`/`editorSplitBottom`, the editor's share). SwiftUI's split views
  couldn't restore a position, so the panes use Runlet's own `PaneSplit`. It has a
  draggable divider, keeps the same minimum sizes, and saves the position when a drag ends.

### 2026-10-02 — ⌘W closes an open palette

- With the command palette open, Close Tab (⌘W) and Close Window (⇧⌘W) now close the palette,
  like a popover, instead of acting on the window behind it.

### 2026-10-02 — Command palette: click outside to close, ⌘P / ⇧⌘P switch modes, better matches

- Open Anything (⌘P) and the Command Palette (⇧⌘P) float over the window in a panel instead
  of a sheet. A click anywhere outside closes the palette, and the click goes no further
  (like a popover's), so it can't also close a tab or press Run. Esc still closes it, and so
  does switching to another window or app.
- While the palette is open, the Command Palette shortcut switches it to commands and the
  Open Anything shortcut switches it back, keeping the typed text (minus a `/`, `@`, or `#`
  prefix). The shortcut of the mode already showing closes it. Both go through the menu
  commands, so remapped shortcuts work.
- Command mode is no longer a `>` in the search field. ⇧⌘P used to open with that `>`
  selected, so the first key typed replaced it and the palette silently switched to Open
  Anything. A "Commands" chip beside the field now shows the mode, the search starts empty,
  and the caret sits after the text with nothing selected, also after a mode switch. Typing
  `>` first in Open Anything still switches to commands (the `>` is consumed), and ⌫ in an
  empty command search goes back.
- Fixed rows showing another result's content: typing `>dock` listed four rows titled New
  Window, New Tab, Duplicate Tab, and Open…, because rows were identified by position. Rows
  now follow their item, and ↩ runs the highlighted row, so Manage Docker Profiles… opens
  from the palette again.
- Better matching, here and in Settings ▸ Shortcuts. Each word of the query must match on
  its own. Titles match by prefix, word start, substring, or pieces that start successive
  words (`vt` → Toggle Vertical Tabs, `mdp` → Manage Docker Profiles…), and rank first.
  Subtitles and keywords match only at a word start or as a substring, no longer as letters
  scattered across unrelated words. `dock` now lists New Docker Profile… and Manage Docker
  Profiles… first and no longer matches New Window.
- Debug builds: `RUNLET_DEBUG_PALETTE=anything|commands` drives the palette at launch with
  key and mouse events sent only to Runlet, through the menus' own shortcuts. It opens,
  types, switches modes, closes, and clicks outside, logging each step to stderr and taking
  snapshots when `RUNLET_SNAPSHOT_DIR` is set, then quits. Use it with `RUNLET_DATA_DIR`;
  it needs Runlet to stay frontmost while it runs.

### 2026-10-02 — Focus stays in Runlet after closing Settings or Docker Profiles

- Closing Settings, the Docker Profiles window, or any other Runlet window could hand
  focus to another app. macOS activates the next window on screen, which was another
  app's whenever one sat between the closing window and Runlet's main window. Runlet now
  makes its frontmost remaining window key just before the window closes. Sheets and
  alerts are left to AppKit.
- Debug step runner: added `activate`, `settings`, `profiles`, `close`, and `report`
  (activation plus key and main windows), used to reproduce this.

### 2026-10-02 — No duplicate History entries

- Running code that is already in History, on the same target, moves that entry to the
  top with the latest status, time, and duration instead of adding a copy. Leading and
  trailing whitespace is ignored when comparing code. The same code on another target stays
  a separate entry.
- Existing duplicates are collapsed when History loads, keeping the newest of each.

### 2026-10-02 — Clearer launch failures for Docker profiles

- When `docker exec` cannot start PHP, its own message (printed on stdout, exit code 127)
  now becomes the error, in runs and in the Commands pane, instead of only "exited with
  code 127". Two cases get a plain-language explanation first:
  - "chdir to cwd" means the working directory doesn't exist in this container, so the
    profile probably points at the wrong container or directory;
  - "executable file not found" means PHP isn't on that path.

### 2026-10-02 — Where History and Snippets entries open

- New setting, Settings ▸ General ▸ History & Snippets ▸ "Double-click opens in", for
  double-click and Return in the History and Snippets panes:
  - **This tab if it's empty and on the same target, else a new tab** (the default). A blank
    tab (no file, not running, nothing but `<?php`) takes the code, and an automatic
    "Tab N" title becomes the entry's name. Snippets saved for any target fit every tab.
  - **Always a new tab** (the previous behavior).
  - **Always the current tab.** It replaces the code (⌘Z undoes it) and switches the tab
    to the entry's target. A running tab gets a new tab instead.
- Opening still only loads code; nothing runs until you press Run. The explicit "Load in
  Current Tab" and "Open in New Tab" buttons are unchanged, and the panes' hints describe
  the chosen behavior.

### 2026-10-02 — Fix: crash when opening the History & Snippets panel

- Opening the panel could crash intermittently, mostly with vertical tabs: AppKit threw
  "more Update Constraints in Window passes than there are views in the window". SwiftUI's
  `.inspector` split view re-sent the window toolbar items on every layout pass while
  opening. The panel is now a plain resizable trailing column. Its width is remembered
  (`libraryPanelWidth`, 260–480 pt), and it never animates, so the toolbar stays put.
  Replaying the reporter's saved layout used to crash in 1–2 of every 6 runs; it ran clean
  18 times with the fix.
- The Commands pane no longer requires 300 pt, which was more than the panel's 260 pt
  minimum.
- Debug builds: `RUNLET_DEBUG_STEPS` replays UI steps at launch, then quits. Steps are
  `inspector:<pane>|off`, `tabs:vertical|horizontal`, `snapshot`, and `wait`, run 1.5 s
  apart. `RUNLET_DEBUG_INSPECTOR=<pane>` is shorthand for `inspector:<pane>,snapshot`. Use
  them with `RUNLET_DATA_DIR` (scratch data) and `RUNLET_SNAPSHOT_DIR` to reproduce layout
  bugs without UI scripting.

### 2026-10-02 — History by project; Commands pane polish

- The History pane has **This Project / All Projects** sub-tabs. It shows only the current
  tab's project by default. The empty state offers "Show All Projects", and the footer counts
  both scopes.
- The Commands pane lists each unlisted target by itself while the pane is visible,
  including after you switch to a new tab or project; no manual Refresh is needed. Failed
  listings are not retried automatically. The pane now stays pinned to the top of a tall
  inspector.

### 2026-10-02 — Host commands (biker and other host CLIs)

- New driver hook, `hostCommands()`. It declares commands that run **on the Mac** in the
  project's folder (for Docker profiles, the profile's local source folder) instead of
  inside the target. An entry is one of:
  - a static command (`'up' => 'docker compose up -d'`);
  - a list source that prints Runlet's command JSON (`'biker' => ['list' => 'biker
    runlet:commands']`);
  - a Symfony Console app (`'tool' => ['console' => 'tool']`), read through
    `tool list --format=json`.
- Sources are listed each time the Commands pane loads or refreshes. They run with the
  user's login-shell environment, resolved once with `$SHELL -i -l -c env`, so `~/.bin`,
  Homebrew, and Herd tools are found. Output around the JSON is ignored, and console style
  tags are stripped.
- The runner reports host commands before `bootstrap()`, and the app remembers each
  target's declaration in `State/facts.json`. Host commands therefore stay available when
  the app can't boot or the container is stopped (`biker start`). Running a host command
  never resolves a container.
- Commands can set `needsInput` (required arguments). Run then types the command without
  pressing Return: in the user's shell, or in an interactive `sh -l` inside the container.
  `consoleCommands()` sets it for Artisan or console commands with required arguments.
- Host commands show a laptop marker in the Commands pane, and failing sources show their
  error above the list.

### 2026-10-02 — Terminal commands wait for the shell; command tabs stay open

- Commands opened in a terminal tab (project commands) are typed only once the shell
  reports its first prompt, never into a question an rc file asks while it loads (e.g.
  dotenv's "Source it? ([y]es/[N]o…)", which used to swallow the first character and leave
  `quote>`). zsh gets a temporary `ZDOTDIR` whose startup files source yours unchanged
  (your `ZDOTDIR`, history file, and options are restored) plus a one-shot `precmd` hook;
  bash a `--rcfile` that reads the login profile files plus a one-shot `PROMPT_COMMAND`;
  fish a one-shot `fish_prompt` handler. The hook writes a private escape sequence that
  Runlet consumes; nothing is printed during startup and plain shell tabs are unchanged.
- If the shell hasn't reported after 15 s, a bar above the terminal offers Run Now /
  Don't Run instead of typing blindly; answering the shell's question later still runs it.
  Other shells keep the output heuristic (zsh and fish are no longer typed into after a
  timeout).
- Command tabs (including `docker exec … sh -lc <cmd>` for Docker targets) stay open after
  the command exits: `— Process exited with code N —` (red when non-zero), a check or
  warning mark on the tab, and Run Again / Close above the terminal (Run Again also in the
  tab's context menu). Return closes a finished command tab. Plain and container shells
  still close when they exit cleanly.
- ⌘W (Close Tab, or your remapped shortcut) closes the focused terminal tab when the
  terminal has keyboard focus, asking first only while a program is running; closing the
  last one hides the panel and returns focus to the editor. Elsewhere ⌘W closes the editor
  tab as before.
- 19 new package tests: marker scanning across chunk boundaries, launch arguments and
  environment per shell, script installation, and live zsh/bash/fish sessions under
  `script(1)` with temporary dotfiles (an rc-file `read -q` holds the marker back until
  answered; `ZDOTDIR`, `PROMPT_COMMAND`, and helper names are cleaned up).

### 2026-10-02 — Docker profile manager window

- Library ▸ **Manage Docker Profiles…** (also in ⇧⌘P, the toolbar target menu, and
  Settings ▸ Targets; no default shortcut, assign one in Settings ▸ Shortcuts) opens one
  window for all Docker profiles: the profile list on the right (search, running/not
  running dot, container, local source folder, tabs using it) with + / − and Duplicate /
  Use in Current Tab; the left side is the same editor as the profile sheet.
- Edits stay a draft until Save (↩ or ⌘S); Revert restores the saved values. Switching
  profiles, adding one, or closing the window with unsaved changes asks Save / Don't Save /
  Cancel. Deleting uses the usual confirmation, and tabs using the profile switch to the
  sandbox as before. The single-profile sheet is unchanged.

### 2026-10-02 — Project commands pane

- History & Snippets panel gains a **Commands** pane (⇧⌘K, also in the palette): every
  Artisan / Symfony console command, Composer scripts, and `.runlet` driver `commands()`,
  searchable and grouped; ▶ runs one in a terminal tab (local, or `docker exec` into the
  resolved container). Commands load only when the pane is shown or on Refresh.

### 2026-10-02 — Tab cards complete without a run

- Targets are inspected without running project code: framework/driver and versions
  from files (`.runlet/*Driver.php` name/version literals, Laravel/Symfony version
  constants in vendor, WordPress `version.php`), and a Docker container's PHP version via
  `php -n -r 'echo PHP_VERSION;'` (php.ini disabled; nothing from the project runs).
- Detected facts and driver variables persist across launches (`State/facts.json`); a
  real run still refines them.

### 2026-10-02 — Managing targets

- Delete a Docker profile or remove a local project from the target menu
  ("Delete “name”…"), the command palette ("Delete Current Target…"), or the new
  Settings ▸ Targets tab (Edit/Delete for every saved target). Only Runlet's entry is
  removed; folders and containers are untouched, and affected tabs keep their code.
- Wired project snippets into ⌘P (`#`), and added "Save Snippet to Project…" and
  "Toggle Strict Types" commands.

### 2026-10-02 — Accurate completion for Docker profiles

- Local source for completion is detected from the container's bind mount: the Docker
  profile editor fills it in when a container is picked, and existing profiles without
  one get a "Use for Completion" banner (explicit click).
- Limited workspaces (no local source) no longer show false "class/function not found"
  warnings; syntax errors still show.
- Diagnostics on Runlet's hidden lines (synthetic `<?php`, `@var` declarations for driver
  variables) are dropped instead of appearing on line 1; errors at the hidden trailing
  `;` move to the end of the last line.
### 2026-10-02 — Tab card chips stay inside the card

- Vertical tabs: a chip wider than the card (a long framework or `.runlet` driver name)
  now truncates with "…" at every sidebar width instead of running past the card's right
  edge. `FlowLayout` proposes the row width to a subview that doesn't fit and never places
  it wider than the row; the chip's icon stays visible while its text shrinks.
- The driver chip no longer repeats itself: when the reported "version" is really a name
  that matches the driver ("Hellorider Lease API" / "Hellorider Lease-API"), only the
  driver name is shown. Real versions still show ("Laravel 13.34"); the tooltip keeps both.
- The second line of a Docker tab shows the profile name, adding `project/service` (or the
  container name) only when it says something new: `microservice`, not
  `microservice · hellorider-lease-api/microservice`. Hover shows the full identity.

### 2026-10-02 — Command palette, Open Anything, custom shortcuts, tab commands

- Command registry (`Runlet/App/Commands.swift`): every action has an id, title,
  category, default shortcut, and enabled state; menus, palettes, toolbar help, and
  Settings ▸ Shortcuts are built from it.
- ⇧⌘P Command Palette (fuzzy, shows shortcuts, ↩ runs) and ⌘P Open Anything (targets,
  snippets, recent files; `>` commands, `/` projects, `@` Docker, `#` snippets; ⌘↩ opens
  in a new tab; never runs code). Replaces the target switcher.
- Settings ▸ Shortcuts: record, clear, reset, Reset All, conflict warnings; overrides
  are saved in settings and update menus immediately.
- Tabs: ⇧⌘T reopens closed tabs (with their code), Close Tabs to the Right, ⌘1–⌘8 /
  ⌘9 (last), Rename Tab command. Output: show/hide pane (⌃⌘O), move right/below (⌃.),
  Structured/Plain/Raw (⌃⌘1–3). History & Snippets panel toggle (⌥⌘L).
### 2026-10-02 — Strict types and project snippets

- Strict types (B07): Settings ▸ General ▸ Running ▸ "Declare strict_types=1 for every
  run" (default off), with a Default / On / Off override in Project Options and in the
  Docker profile editor. The runner inserts `declare(strict_types=1);` on the opening
  tag's line, so line numbers and parse-error columns don't change; code that declares
  strict_types itself (either value) is left alone. Applies to full and selection runs on
  local, Docker, and sandbox targets; the output header shows `strict_types=1` when on.
  `RunRequest.strictTypes` carries it to the runner (`"strictTypes": true`).
- Project snippets (B05): `<project>/.runlet/snippets/*.php` (a local project's folder or a
  Docker profile's local source) with `@label` and `@description` in the first docblock,
  Tinkerwell-compatible. The Snippets panel shows a read-only "Project snippets — <name>"
  section for the active tab's target with Open in Current/New Tab, Copy Code, Copy to
  Personal Snippets, Reveal in Finder, and a reload button. Save Snippet can write to
  "Project (.runlet/snippets)" and asks before replacing a file. Nothing in
  `.runlet/snippets/` is loaded as a driver or run. See docs/project-snippets.md.
- 27 new package tests (strict types locally, on PHP 7.4, and in Docker; snippet parsing,
  loading, and writing; the snippets folder is ignored by driver discovery).
### 2026-10-02 — Editor typography, soft wrap, and open in external editor

- Settings ▸ Editor: font family (installed fixed-pitch fonts, including ones such as
  JetBrains Mono and Hack that don't set the monospace trait; default System
  Monospaced, falling back to it when a chosen font is missing), line height 1.0–2.0
  with a live highlighted preview, ligatures on/off, and soft wrap. Editors re-apply
  the settings in place, so undo, selection, and scroll position survive.
- Ligatures: programming fonts draw them through contextual alternates (`calt`), which
  the `.ligature` attribute doesn't control, so "off" also disables `calt` and common
  ligatures for the editor font. Verified with Fira Code, JetBrains Mono, and Iosevka.
- Soft wrap wraps to the visible width (the macOS 26 clip view extends under the ruler,
  so its content insets are subtracted), hides the horizontal scroller, never splits an
  operator such as `->` or `=>` across rows, and follows window resizes. The line-number
  ruler numbers logical lines, drawing each number (and diagnostic marker) on a line's
  first row, including when the view is scrolled into the middle of a wrapped line;
  numbers now sit on the text baseline at every line height.
- Open in external editor: Settings ▸ Editor ▸ External Editor offers the installed
  editors among PhpStorm, VS Code (also Insiders, VSCodium), Cursor, Zed (also Preview),
  Sublime Text, and TextMate, plus a custom command (`{file}`, `{line}`; split into
  arguments and launched without a shell), with a Test button that opens the current
  project. Files open at their line through each editor's URL scheme
  (`phpstorm://open?file=…&line=…`, `vscode://file/…:line`, `zed://file/…:line`,
  `subl://open?url=…`, `txmt://open?url=…`) when the app registers it, else its bundled
  command-line tool; folders open with the app.
- Output: file paths outside the snippet in dump cards, error cards, and stack-trace
  frames are links that open at their line (or reveal in Finder when no editor is set),
  with Reveal in Finder and Copy Path in their context menus. Docker paths map from the
  profile's working directory to its local source folder (Docker-sandbox paths to the
  installed sandbox); unmappable or missing paths stay plain text with the reason in the
  tooltip. Snippet-line links still go to the editor.
- `AppModel.toggleSoftWrap()` and `AppModel.openProjectInEditor(for:)` for the Wrap Lines
  and Open Project in Editor commands.
- Package: `RunletCore/EditorLinks.swift` (`ExternalEditor`, URL and CLI-argument
  builders, custom-command splitting, `EditorPathMapping`) with 16 tests.
### 2026-10-02 — Project commands

- Commands panel (`ProjectCommandsView`): lists every command the active tab's target
  offers (all visible Artisan commands for Laravel/Lumen/Laravel Zero, `bin/console`
  commands for Symfony, a `.runlet` project driver's own commands, and Composer scripts),
  searchable and grouped by namespace, with a Run button (▶) that opens the command in a
  terminal tab: the project directory for local and sandbox targets (with the target's
  PHP), `docker exec -it … sh -lc` into the profile's resolved container for Docker. Without
  a terminal panel the command is copied instead.
- Listing boots the application like a run, so it happens only when the panel opens for a
  target that was never listed, or on Refresh; results are cached per target. Composer
  scripts are read before any project code runs and stay listed if the app cannot boot.
- Driver API: `Runlet\Driver::commands()` (name-keyed `command`/`description`/`group`
  entries, or a command-line string), plus `consoleCommands()` for Symfony Console apps.
  Project drivers extend the built-in lists with `parent::commands() + [...]`.
- Runner protocol: request `mode: "commands"` and `commands` events (see docs/drivers.md);
  `ExecutionEngine.listCommands(target:)` returns a `ProjectCommandCatalog`.
- 22 new tests (Laravel, Symfony, Laravel Zero stub, custom and extending project
  drivers, Composer scripts, failures, timeout and cancel, terminal requests, Docker
  `custom`/`laravel`/`restricted` services, PHP 7.4).
### 2026-10-02 — Terminal panel

- Integrated terminal: a bottom panel per window with its own tabs (toolbar button,
  "+" for a new shell, × to close, chevron to hide), resizable by its top edge; height
  and shown/hidden state are remembered. Sessions live only while Runlet runs.
- Runs your own shell, untouched: the account's login shell (`-zsh`, `-bash`, …) with your
  profile and rc files, in the selected tab's project / sandbox / Docker source directory.
  Runlet adds only `TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM=Runlet`, and
  `LANG` when missing; no prompt or rc changes.
- Docker targets: "+" menu ▸ Shell in <profile> Container (`docker exec -it`, bash if
  available, else sh), resolving the container like a run — never a different one silently.
- Tab titles follow the program's title (OSC); closing asks only while a program other
  than the shell is in the foreground; closing a window or quitting hangs up its shells.
- Light/dark colors follow the app appearance, editor font size, 10,000 lines of
  scrollback, copy/paste and mouse selection; optional Option-as-Meta in the "+" menu.
- `AppModel.openTerminal` (`TerminalRequest`) lets features open terminal tabs that run a
  command in the user's shell or a direct argv; `toggleTerminal()` / `newTerminal()` for
  menu commands.
- Uses SwiftTerm 1.11.2 (MIT; license bundled). 8 new package tests for shell/environment
  resolution.

### 2026-10-02 — Completion popup and CPU fixes

- Fixed a feedback loop that made the completion footer flicker and kept Runlet and
  PHPantom busy (high CPU): resolving an item re-announced the selection, which
  resolved it again, indefinitely. Items now resolve once, only on real selection changes.
- Completion rows are single-line with tail truncation (no clipped second line), the
  popup sizes to its content (320–680 pt), and the selected row uses white text.
- Document sync to PHPantom is coalesced (~120 ms) while typing and flushed before
  completion, hover, and signature-help requests.
- Docs: Tinkerwell feature review (docs/tinkerwell-feature-review.md).

### 2026-10-02 — Framework drivers

- Runner auto-detects the driver per run: project drivers in `.runlet/*Driver.php`
  (read from disk, so a globally git-ignored `.runlet/` works), then Laravel / Lumen /
  Laravel Zero, WordPress (classic, Bedrock, `public/wp`), Symfony, Composer, plain PHP.
- Runlet driver API: `Runlet\Driver` (`name`, `canBootstrap`, `bootstrap`, `variables`,
  `version`) and extendable built-ins `Runlet\Drivers\{Laravel,WordPress,Symfony,
  Composer,Plain}Driver`. Injected variables (`$app`, `$wpdb`, `$kernel`/`$container`,
  project-defined) reach the snippet and, after a run, completion. See docs/drivers.md.
- WordPress boots like WP-CLI (globals preserved), with `wp_die` as an exception, no
  recovery-mode emails, no spawned WP-Cron; Symfony loads `.env` and boots the kernel.
- Docker profile probe recognises `.runlet` drivers, WordPress, and Symfony.
- 21 new driver tests (custom driver locally and in Docker, ordering, failures,
  WordPress on SQLite, Symfony, Lumen/Laravel Zero); 112 package tests passing.

### 2026-10-02 — Vertical tabs and driver variables in completion

- Tabs can be horizontal or vertical (Settings ▸ General, View ▸ Vertical Tabs ⌃⌘T,
  toolbar); the choice persists. Vertical tabs are cards showing the target, runtime
  (Docker / Local / Sandbox), PHP version, framework or `.runlet` driver and version,
  run status; drag to reorder, double-click to rename.
- Variables a driver injects (e.g. `$app`, a project driver's `$_app`) are declared to
  PHPantom as hidden `@var` lines after a run, so they complete in tagless snippets.
- The status bar shows the driver name; the Output header compacts on narrow panes.
- Vertical tab sidebar is compact by default (~190 pt), resizable by dragging its edge
  (140–420 pt), and remembers its width; cards use two short chips (runtime + PHP,
  framework/driver) with full versions in tooltips.

### 2026-10-02 — Windows and workspaces

- Multiple windows, each with its own tabs (⌘N); all windows and tabs are restored on
  relaunch without running anything. Closing the last window keeps Runlet running.
- `.runlet` workspace files: Save Workspace As… (⌥⇧⌘S), Open… (⌘O, also Finder/CLI).
  Workspaces embed their targets (local projects with relative paths, Docker profile
  definitions without machine-specific container IDs); on open, existing targets are
  matched and missing ones are added only after confirmation.
- Workspace windows behave like documents: edited dot, ⌘S saves, closing asks; closing
  an untitled window with unsaved scratch code asks too.
- Session format now stores windows; older single-window sessions still load.

### 2026-10-02 — Packaging, target switcher, fixes

- `scripts/package.sh`: universal Release build, verification, zip + DMG; packaged
  `Runlet --self-test [--docker]` passes natively and under Rosetta.
- ⌘P Switch Target palette (search sandbox, projects, Docker profiles).
- `Runlet file.php` / Finder opens files in tabs; the main window now appears on
  document launches; saving never executes code.
- Fixed: Docker sandbox Stop pressed before the container existed was lost (now
  `--init`, retried `docker kill`, `rm -f` fallback); container listing failed when a
  container vanished between `ps` and `inspect`. Found by new sandbox/recreation tests
  (real Compose `--force-recreate`, Docker sandbox without host PHP, sandbox reset).

### 2026-10-02 — Native app (milestones 1–4, in progress)

- Native macOS app (SwiftUI + AppKit): persistent per-tab AppKit editors with PHP
  highlighting, line numbers, auto-indent, bracket pairing, comment toggle, find bar;
  Writing Tools and smart substitutions disabled for code.
- Tabs (new/rename/duplicate/close/close others), target menu (sandbox, local projects,
  Docker profiles), Run / Run Selection / Stop, status bar with elapsed time, PHP and
  framework versions, and PHPantom state.
- Output pane: ordered stdout/stderr, dump cards with line links, expandable value
  trees, error cards with stage, line/column navigation and stack traces.
- PHPantom in the editor: completion popup (with `use` import edits), hover, signature
  help, diagnostics underlines and gutter markers. Tagless snippets get a hidden `<?php`
  line and a trailing `;` for the language service only.
- Docker profile editor (container discovery, Compose identity, working-directory
  suggestions, probe), settings (appearance, editor, PHP, Docker, sandbox), history and
  snippets inspector, explicit container choice after recreation/ambiguity.
- Runs prefer the user's default `php` on PATH and avoid prerelease PHP builds.
- Output display modes like Tinkerwell's: Structured (cards + expandable trees), Plain
  (CLI-style transcript), Raw (exact stdout/stderr bytes); value expansion preference
  (collapsed / first level / all); Table view for tabular values (arrays of rows,
  collections, Eloquent model lists) with sorting, filtering, Copy/Export CSV.
- Sandbox runtime preference: Automatic / Local PHP / Docker.
- Seeded scenario UI tests: many applications in tabs, Docker profiles (restricted
  container, Stop keeps the container running), sandbox in Docker, output modes and
  table, history/snippet persistence without execution.
- Stop before launch now ends as `cancelled`; selection errors map columns too.
- XCUITest suite driving the real app (6 passing): sandbox run, error mapping and
  recovery, Run Selection, Stop, restart restoration without execution, completion.
  Automatic test screen recordings are disabled.

### 2026-10-02 — Execution engine (milestones 0–1, 3)

- `RunletKit` Swift package: `RunletCore` (protocol, value tree, targets/profiles/
  settings/history/snippet models, atomic JSON store with last-good recovery) and
  `RunletExecution` (posix_spawn supervisor with process groups, frame decoder,
  run sessions, local / `docker exec` / disposable Docker sandbox adapters).
- Exactly one terminal `finished` event per run, including launch failure, fatal exit,
  `exit()`/`dd()`, cancellation, and lost transport.
- Stop: local runs signal the runner's process group (snippet children included);
  Docker runs signal the runner inside the same container through a PHP helper that
  verifies the run's `RUNLET_RUN_ID` before signaling — the container keeps running.
- Docker discovery via `docker inspect`, Compose-label profile resolution (recreation,
  ambiguous replicas, name-only confirmation), and in-container probing using PHP only.
- Runner hooks whichever VarDumper the active `dump()` uses, including php-scoper aliases
  from `auto_prepend_file` tools such as global Ray.
- Fixtures (`Tests/Fixtures`, `scripts/setup-fixtures.sh`) and integration tests covering plain/Composer/Laravel, PHP 7.4, read-only non-root containers, output
  robustness and limits, selection line mapping, concurrency, and Stop.

### 2026-10-02 — Milestone 0: repository and risk prototypes (in progress)

- Repository initialized; `plan.md` holds the product plan and MVP requirements.
- Decisions recorded: macOS 26 minimum, runner compatible with PHP 7.4+ targets,
  official `php:8.4-cli` image for the Docker-backed sandbox, PHPantom 0.10.0 pinned.
- PHP runner (`Resources/Runner/src/Runner.php`) with nonce-framed event protocol on
  stdout, AST-based final-expression capture (nikic/php-parser 5.9.0, scoped as
  `RunletVendor\PhpParser`), bounded value normalization (no getters/`__toString`),
  dump/dd interception, parse/bootstrap/execute/fatal error reporting.
- Runner bundler (`scripts/build-runner.php`) producing one self-contained file that is
  streamed to `php` on stdin, so nothing is written into projects or containers.
  Verified on PHP 7.4.33, 8.2 (Alpine), and 8.4.25, locally and via `docker exec` into
  a read-only, non-root container.
- Pinned Laravel 13.34.0 sandbox skeleton (`Resources/Sandbox/laravel`).
- `scripts/fetch-phpantom.sh` downloads and checksum-verifies PHPantom 0.10.0 for both
  architectures and builds a universal binary.
