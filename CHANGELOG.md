# Changelog

All notable changes to Runlet are recorded here. Dates use ISO format.

## Unreleased

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
