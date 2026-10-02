# Changelog

All notable changes to Runlet are recorded here. Dates use ISO format.

## Unreleased

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
