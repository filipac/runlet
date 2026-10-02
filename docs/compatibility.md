# Compatibility and prototype-gate evidence

Recorded 2026-10-02 on macOS 27.0 (arm64), Xcode 27.0, Swift 6.4, Docker 29.4.0.

## PHP runner

| Item | Choice / result |
| --- | --- |
| Supported target PHP | 7.4 – 8.5 (decision: PHP 7.4 floor) |
| Parser | nikic/php-parser 5.9.0, scoped to `RunletVendor\PhpParser`, bundled into `Resources/Runner/dist/runlet-runner.php` |
| Transport | Whole runner streamed to `php` on stdin; events are nonce-framed records on stdout (`0x1E RL1:<nonce>:<len>:<json>\n`). No files are written into projects or containers, so read-only filesystems and non-root users work. |
| Verified runtimes | Herd PHP 7.4.33 and 8.4.25 locally; `php:7.4-cli` (uid 1000, read-only root FS, read-only app mount), `php:8.4-cli`, `php:8.2-cli-alpine` via `docker exec` |
| Laravel | 13.34.0 (pinned sandbox + fixture app): bootstrap ≈ 40 ms, full run ≈ 90–140 ms locally; ≈ 150–250 ms via `docker exec` |
| Required extensions | `tokenizer` for final-expression capture (falls back to running without implicit results, with a notice). `json` and `pcre` are core. No `pcntl`/`posix` needed. |
| `dump()`/`dd()` | Hooks the project's VarDumper and any VarDumper behind a pre-existing global `dump()` (e.g. php.ini `auto_prepend_file` tools such as global Ray, including php-scoper aliases). Without var-dumper, Runlet defines `dump()`/`dd()`. |

Known limitations:
- `var_dump`/`print_r` stay textual (not parsed into structures), by design.
- Snippet child processes: local Stop signals the runner's process group (verified). In Docker,
  Stop signals the runner PID only; children a snippet spawns inside a container are not
  guaranteed to stop.
- Cancellation in Docker requires `posix_kill` or `/bin/sh` + `exec()` in the container; if neither
  exists, Stop reports that the PHP process may still be running.

## PHPantom 0.10.0 prototype gate

Binary: release tarballs for `aarch64-apple-darwin` and `x86_64-apple-darwin`, SHA-256 pinned in
`scripts/fetch-phpantom.sh`, combined into a universal binary. Launched with `PATH=/usr/bin:/bin`
(no host PHP) and `XDG_CONFIG_HOME` pointing to an app-owned directory.

| Gate | Result | Evidence |
| --- | --- | --- |
| 1. Tagless unsaved scratch document with project completion, no disk writes | Pass. An in-memory `file://<root>/.runlet-scratch/tab-<id>.php` URI resolves against the real root; nothing is created on disk. | `PHPantomTests.taglessScratchCompletionUsesProjectRootWithoutWritingFiles` |
| 2. Positions/edits across synthetic tag and Unicode | Pass. Synthetic `<?php\n` occupies its own line, so only lines shift; both sides use UTF-16. Import `additionalTextEdits` map to editor line 0. | `importEditsMapBackToEditorCoordinates`, `hoverSignatureHelpAndDiagnosticRangesWithUnicode`, `MappingTests` |
| 3. Different PHP target, existing `.phpantom.toml`, vendor files, no repo/global changes | Pass. Per-session `[php] version` is written to the app-owned config home; the project's `.phpantom.toml` is read but never modified. | `workspacesAreIsolatedAndRespectProjectConfiguration` |
| 4. Suppress external analyzers/formatters | Pass. App config sets `phpstan/phpcs/mago` commands and formatter paths to `""` and disables workspace diagnostics. Control experiment: with an empty config plus a project `.phpantom.toml` `workspace = true`, PHPantom launched the project's `vendor/bin/phpstan`; with Runlet's config it did not. A project that explicitly sets a tool **command** in its own `.phpantom.toml` would still override this (explicit project opt-in). | `externalAnalyzersAreNotLaunchedImplicitly` |
| 5. Isolation and crash recovery | Pass. One process per workspace key; a killed server restarts automatically and re-opens documents from the client's copy. | `workspacesAreIsolatedAndRespectProjectConfiguration`, `crashedServerRestartsAndRestoresDocuments` |

Server capabilities advertised by 0.10.0: completion (+resolve), hover, signature help,
definition, type definition, implementation, references, document highlight/symbols, workspace
symbols, code actions, code lens, formatting, on-type formatting, rename, document links,
folding, semantic tokens, inlay hints, selection ranges. Runlet's MVP uses completion, resolve,
hover, signature help, and pushed diagnostics.

Observed quirks:
- Completion `insertText` uses snippet syntax (`PriceFormatter()$0`) even when the client
  declares `snippetSupport: false`; Runlet converts snippets to plain text (`SnippetText`).
- Startup on the Laravel fixture: initialize ≈ 0.7 s cold, completion ≈ 20 ms.

### Laravel completion (sandbox / fixture, Laravel 13.34.0)

| Case | Result |
| --- | --- |
| Model attributes inferred from migrations (`$widget->price`, `->name`) | Supported |
| Eloquent builder chain (`Widget::query()->where(...)->first()->`) | Supported |
| Model methods (`save`, …) | Supported |
| Class completion with automatic `use` import | Supported |
| Built-in function signature help (`str_replace`) with parameter docs | Supported |
| Facade static calls, scopes, casts, collection element types | To be recorded during dogfooding (see `docs/validation.md`) |
