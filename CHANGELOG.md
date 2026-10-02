# Changelog

All notable changes to Runlet are recorded here. Dates use ISO format.

## Unreleased

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
