# Runlet: ideas for the next release(s)

Reconciled 2026-10-02 against `CHANGELOG.md` (through 0.1.0), source code, and existing test sources. Migration: [#3](https://github.com/filipac/runlet/issues/3). This audit did not execute the application or rerun its tests.

GitHub issues are the source of truth for outstanding work. This file is an index and preserves the original proposal details. Follow [AGENTS.md](../AGENTS.md): find or create an issue before adding work, and label every issue. Completed scope and historical SSH design moved to [done-next-release-ideas.md](done-next-release-ideas.md). The old Tinkerwell comparison was research context, not a list of implementation commitments.

**Priority:** P1 = next-release candidate, P2 = following-release candidate, P3 = later/on demand. **Size:** S ≈ a day or less, M ≈ 2–4 days, L ≈ a week or more; original estimates, not promises. Optional/deferred issues record ideas without authorizing implementation. Skipped ideas at the end have no issues.

Nothing runs without explicit Run or approval. Docker/SSH targets and connections stay explicit; sandbox-only auto-run requires a deliberate per-tab opt-in ([#30](https://github.com/filipac/runlet/issues/30)). API/dependency choices in the original proposals require fresh verification when implemented.

## Issue index

Existing work is also tracked in [#1 — tab sidebar/title-bar overlap](https://github.com/filipac/runlet/issues/1) (`bug`, `area:macos`, `priority:P1`) and [#2 — bundled PHP runtime](https://github.com/filipac/runlet/issues/2) (`enhancement`, `area:runtime`, `priority:P2`). These were reused and labeled rather than duplicated.

| ID | Remaining work | Priority / size | Issue |
| --- | --- | --- | --- |
| N03 | Run recorder: HTTP calls, general jobs, and optional events | P2 · M | [#5](https://github.com/filipac/runlet/issues/5) |
| N05 | Readable values: built-in summaries and driver casters | P2 · M | [#6](https://github.com/filipac/runlet/issues/6) |
| N07 | Source excerpts in error cards | P2 · S | [#8](https://github.com/filipac/runlet/issues/8) |
| N09 | Charts from tables | P3 · M; deferred | [#27](https://github.com/filipac/runlet/issues/27) |
| N10 | Output history per tab and diff | P3 · M; deferred | [#28](https://github.com/filipac/runlet/issues/28) |
| N12 | Execution coverage and Auto Log | P3 · M; deferred | [#29](https://github.com/filipac/runlet/issues/29) |
| N13 | Xdebug "Debug Run" | P2 · M | [#11](https://github.com/filipac/runlet/issues/11) |
| N14 | Production guard: detect application environment and mark history | P1 · S–M | [#12](https://github.com/filipac/runlet/issues/12) |
| N15 | Rollback ("dry run") mode | P2 · M | [#13](https://github.com/filipac/runlet/issues/13) |
| N18 | Per-target prelude | P3 · S; deferred | [#31](https://github.com/filipac/runlet/issues/31) |
| N20 | "Start the stack" from the failure banner | P2 · S | [#15](https://github.com/filipac/runlet/issues/15) |
| N21 | Docker contexts and custom exec flags | P2 · S | [#16](https://github.com/filipac/runlet/issues/16) |
| N22 | Sail, DDEV, and Lando presets; Herd isolation | P2 · S | [#17](https://github.com/filipac/runlet/issues/17) |
| N23 | Kubernetes | P3 · M; deferred | [#33](https://github.com/filipac/runlet/issues/33) |
| N24 | Forge and Ploi import | P3 · M; deferred | [#34](https://github.com/filipac/runlet/issues/34) |
| N25 | Global drivers, Testbench, and a driver gallery | P2 · S | [#18](https://github.com/filipac/runlet/issues/18) |
| N26 | App info panels | P2 · M | [#19](https://github.com/filipac/runlet/issues/19) |
| N27 | Log viewer | P2 · M | [#20](https://github.com/filipac/runlet/issues/20) |
| N28 | Database schema browser | P2 · M | [#21](https://github.com/filipac/runlet/issues/21) |
| N29 | SQL tabs | P3 · M–L; deferred | [#35](https://github.com/filipac/runlet/issues/35) |
| N30 | PHPantom navigation: definition, references, inlay hints, code actions | P2 · S–M | [#22](https://github.com/filipac/runlet/issues/22) |
| N31 | Format snippet | P3 · M; deferred | [#36](https://github.com/filipac/runlet/issues/36) |
| N32 | Editor polish | P3 · M; deferred | [#37](https://github.com/filipac/runlet/issues/37) |
| N34 | Tinkerwell migration | P2 · S | [#23](https://github.com/filipac/runlet/issues/23) |
| N35 | Share and send code | P3 · S; deferred | [#38](https://github.com/filipac/runlet/issues/38) |
| N36 | Promote a snippet | P3 · M; deferred | [#39](https://github.com/filipac/runlet/issues/39) |
| N40 | Developer ID signing, notarization, auto-update, diagnostics | P1 · M | [#24](https://github.com/filipac/runlet/issues/24) |
| N41 | Quick Run panel | P2 · M | [#25](https://github.com/filipac/runlet/issues/25) |
| N42 | Notifications for long runs | P2 · S | [#26](https://github.com/filipac/runlet/issues/26) |
| N43 | Shortcuts, Services, Spotlight | P3 · M; deferred | [#42](https://github.com/filipac/runlet/issues/42) |
| N45 | Explain or fix this error | P3 · M; optional, deferred | [#44](https://github.com/filipac/runlet/issues/44) |
| N46 | Chat sidebar | P3 · L; optional, deferred | [#45](https://github.com/filipac/runlet/issues/45) |
| N47 | AI inline completion | P3 · L; optional, deferred | [#46](https://github.com/filipac/runlet/issues/46) |
| DOC01 | Optional confirmation before closing a tab with code | P2 · S; optional | [#50](https://github.com/filipac/runlet/issues/50) |
| DOC02 | Reload project snippets when their folder changes | P2 · S | [#51](https://github.com/filipac/runlet/issues/51) |
| DOC04 | Validate remaining SQL and mail inspector integrations | P2 · M | [#53](https://github.com/filipac/runlet/issues/53) |
| DOC05 | Refresh validation evidence and close documented acceptance gaps | P2 · M | [#54](https://github.com/filipac/runlet/issues/54) |
| DOC06b | Follow PHPantom fixes for Laravel inference gaps (`keyBy`/`groupBy`; retire the model-copy workarounds) | P3 · S; deferred | [#117](https://github.com/filipac/runlet/issues/117) |
| DOC07 | Optional external analysis routed through the selected runtime | P3 · M; optional, deferred | [#56](https://github.com/filipac/runlet/issues/56) |
| DOC08 | Optional dependency mirroring for Docker-only completion sources | P3 · M; optional, deferred | [#57](https://github.com/filipac/runlet/issues/57) |
| DOC09 | Target groups and pinned or favorite projects | P3 · M; deferred | [#58](https://github.com/filipac/runlet/issues/58) |
| DOC10 | Optional sandbox versions, services, and disposable fixture data | P3 · M; optional, deferred | [#59](https://github.com/filipac/runlet/issues/59) |
| SSH08 | Optional safe mode for SSH and other targets | P2 · M; optional | [#47](https://github.com/filipac/runlet/issues/47) |
| SSH09-CACHE | Optional SSH runner payload cache | P3 · M; optional, deferred | [#48](https://github.com/filipac/runlet/issues/48) |
| SSH09-TIMING | Add explicit SSH timing checks to the packaged self-test | P3 · S; optional, deferred | [#49](https://github.com/filipac/runlet/issues/49) |

## Remaining proposal details

### N03 · Run recorder: HTTP calls, general jobs, and optional events

Issue: [#5](https://github.com/filipac/runlet/issues/5) · P2 · M

**Audit status:** Partial: Laravel MessageLogged records and queued-mail detection already exist.

- **What.** Remaining inspector tabs: **HTTP** (`Http` client `RequestSending`, `ResponseReceived`, `ConnectionFailed`: method, URL, status, duration, with `Authorization` and cookie headers redacted), and **Jobs** (`JobQueued` in recent Laravel versions, verify the minimum version: class, queue, connection). An optional **Events** tab is off by default because it's noisy.
- **Why.** It goes beyond Tinkerwell, which has only SQL: a Telescope-like view of one run without installing Telescope.
- **Fit.** Use the existing `Driver::inspect(Inspector $inspector)` and inspector sections/records pipeline. Categories are opt-in in Settings ▸ Output.
- **Risks.** Redaction and size caps. These are listeners only; they never change behaviour, except intercepting fakes when safe mode is on.

**Acceptance:** Add bounded, opt-in HTTP records with redacted authorization/cookie headers, general queued-job records, and an optional Events section. Preserve the existing Log and Mail behavior.

### N05 · Readable values: built-in summaries and driver casters

Issue: [#6](https://github.com/filipac/runlet/issues/6) · P2 · M

**Audit status:** Partial: DateTimeInterface/Carbon summaries, enums with backing values, closure summaries, and array counts already exist.

Complete Eloquent model and collection summaries and add driver-defined casters for trusted domain types. Date/time and enum rendering are already implemented; do not rebuild them. Preserve the no-arbitrary-getters rule.

**Acceptance:** Show useful model identity, attributes/loaded relations/dirty state and collection counts. Add an explicit driver caster API without invoking arbitrary getters or __toString.

### N07 · Source excerpts in error cards

Issue: [#8](https://github.com/filipac/runlet/issues/8) · P2 · S

**Audit status:** Not implemented.

- **What.** Error cards and stack frames show about 5 lines of source around project-file frames, read from the host path (local projects, or Docker and SSH local folders through `EditorPathMapping`).
- **Why.** Tinkerwell's Collision integration shows code context. This is the cheap equivalent.
- **Fit.** `OutputPane.swift` error card, `EditorPathMapping.resolve`.
- **Risks.** The local file may differ from the remote one (drift). Label it "local copy".

**Acceptance:** Show source context for mapped project frames, with clickable locations; label remote source as a local copy and handle missing files.

### N09 · Charts from tables

Issue: [#27](https://github.com/filipac/runlet/issues/27) · P3 · M · deferred

**Audit status:** Not implemented.

- **What.** Bar or line chart of a table's numeric column against another column, for quick reports. Beyond Tinkerwell.
- **Fit.** Swift Charts over `ValueTable` in `ValueTableView`.
- **Risks.** Only for small, bounded tables.

**Acceptance:** Plot bounded table numeric columns as bar/line charts without altering the underlying result.

### N10 · Output history per tab and diff

Issue: [#28](https://github.com/filipac/runlet/issues/28) · P3 · M · deferred

**Audit status:** Not implemented.

- **What.** Keep the last 5 outputs per tab, switch between them, and diff two results (for example before and after a code change).
- **Fit.** `TabModel` keeps per-run `OutputItem`s, with a text diff of `ValueNode.plainText`.
- **Risks.** Memory: cap it, and never persist results by default.

**Acceptance:** Keep at most five bounded results per tab and allow switching and textual diffing; do not persist result contents by default.

### N12 · Execution coverage and Auto Log

Issue: [#29](https://github.com/filipac/runlet/issues/29) · P3 · M · deferred

**Audit status:** Not implemented.

- **What.** Gutter marks for executed lines with hit counts. Auto Log logs every top-level statement's value (Tinkerwell 3.0 "automatic code coverage").
- **Fit.** Builds on N11's statement instrumentation and ruler markers (done in [#10](https://github.com/filipac/runlet/issues/10); see `Resources/Runner/src/MagicComments.php` and `Runlet/Editor/InlineValueOverlay.swift`).
- **Risks.** Output volume; off by default.

**Acceptance:** Show opt-in executed-line hit counts and automatic top-level value logs, with bounded output and correct source mapping.

### N13 · Xdebug "Debug Run"

Issue: [#11](https://github.com/filipac/runlet/issues/11) · P2 · M

**Audit status:** Not implemented.

- **What.** Run ▸ Debug Run (or a per-tab toggle) starts the run with Xdebug triggered, so the IDE stops at breakpoints in project files.
- **Why.** Tinkerwell supports this only with Herd. Runlet can do local and Docker, and SSH later.
- **Fit.**
  - The adapters add `-d xdebug.mode=debug -d xdebug.start_with_request=yes`, plus `-d xdebug.client_host=host.docker.internal` for Docker. Set `PHP_IDE_CONFIG=serverName=<profile>` so PhpStorm's path mappings work.
  - The probe reports whether Xdebug is loaded; the command is disabled with a reason if not.
- **Risks.** Breakpoints in the eval'd snippet don't work; say so. Never enable it implicitly. For SSH it needs a reverse tunnel (`ssh -R 9003:localhost:9003`): P3.

**Acceptance:** Provide an explicit Debug Run with per-target Xdebug configuration, IDE mapping and a reason when unavailable. Document eval breakpoint limitations; SSH tunneling is later scope.

### N14 · Production guard: detect application environment and mark history

Issue: [#12](https://github.com/filipac/runlet/issues/12) · P1 · S–M

**Audit status:** Partial: per-target environments/colors, red badges, confirmations, snippet-only grace and stricter command defaults are implemented.

Only the bootstrapped environment detection / Mark as production banner and historical production-run marking remain. Store a run-time environment snapshot so editing a target later does not relabel old runs.

**Acceptance:** Report the application environment in the bootstrapped protocol, offer Mark as production when appropriate, and persist/display the environment of a historical run as a snapshot.

### N15 · Rollback ("dry run") mode

Issue: [#13](https://github.com/filipac/runlet/issues/13) · P2 · M

**Audit status:** Not implemented.

- **What.** A per-tab toggle that runs the snippet inside a database transaction and always rolls back, showing "rolled back N statements". It is the database part of the archived SSH production/safe-mode design safe mode, available on any target.
- **Why.** Lets you try data fixes on real data safely. Beyond Tinkerwell.
- **Fit.** `LaravelDriver` with a `rollback` request flag. Count statements through N01.
- **Risks.** Same limits as the archived SSH production/safe-mode design: implicit commits, other connections, locks held during long runs.

**Acceptance:** Always roll back supported database transactions after runs, including errors/cancellation where feasible, show rollback status, and document implicit commits, other connections, and long-held locks.

### N18 · Per-target prelude

Issue: [#31](https://github.com/filipac/runlet/issues/31) · P3 · S · deferred

**Audit status:** Not implemented.

- **What.** `.runlet/prelude.php` or a profile field runs before every snippet (`auth()->loginUsingId(1)`). A visible chip shows it.
- **Fit.** The runner request gets `prelude` code, evaluated in the snippet scope.
- **Risks.** Hidden behaviour; always show the chip.

**Acceptance:** Apply an explicit per-target prelude in the snippet scope with a visible indicator and accurate error mapping.

### N20 · "Start the stack" from the failure banner

Issue: [#15](https://github.com/filipac/runlet/issues/15) · P2 · S

**Audit status:** Not implemented.

- **What.** When a Docker profile's container isn't running, the error banner offers the project's start command. That is a `hostCommands()` entry flagged `'start' => true`, for example `docker compose up -d` or the team CLI's `start`. It is one explicit click and runs in a terminal tab.
- **Why.** Uses the existing host-commands pieces. Beyond Tinkerwell.
- **Fit.** `hostCommands` metadata (`ProjectCommand` gets `role`), the `tab.targetIssue` banner in `MainWindow.swift`, and `openTerminal`.
- **Risks.** Runs only on click, on the Mac, in the local folder.

**Acceptance:** Recognize a host-command start role and offer it on stopped-container failures; launch only after a click in a local terminal at the mapped checkout.

### N21 · Docker contexts and custom exec flags

Issue: [#16](https://github.com/filipac/runlet/issues/16) · P2 · S

**Audit status:** Not implemented.

- **What.** A Docker profile can name a Docker context (local Colima, OrbStack, remote) and extra `docker exec` flags from a validated allowlist (`--env K=V`, `--privileged` refused).
- **Why.** Tinkerwell 5.10 exec flags; several Docker engines on one Mac.
- **Fit.** `DockerCLI` passes `--context`. `DockerProfile` gets `context` and `extraEnv`.
- **Risks.** Validation, so no flag injection.

**Acceptance:** Persist a named Docker context and validated additional exec environment options, consistently across resolution, probe, run, commands and Stop; reject privileged/unsafe flag injection.

### N22 · Sail, DDEV, and Lando presets; Herd isolation

Issue: [#17](https://github.com/filipac/runlet/issues/17) · P2 · S

**Audit status:** Not implemented.

- **What.** Opening a project folder detects `.ddev/config.yaml`, `.lando.yml`, or a Sail `docker-compose.yml` (`laravel.test`), and offers a prefilled Docker profile. Examples (verify each): Sail uses user `sail` and `/var/www/html`; DDEV uses service `web` and `/var/www/html`; Lando uses `appserver` and `/app`. For Herd projects, use the site's isolated PHP (`herd which-php`; verify the command).
- **Why.** Fewer setup steps. Tinkerwell relies on generic Docker and Herd's own integration.
- **Fit.** `FilePanels.openProject` → `AppModel.openProject(at:)`, then `DockerProfile.newDraft()` prefilled. Herd goes into `PHPDiscovery`.
- **Risks.** A preset only prefills a draft; the user saves it.
- **Additional source:** plan.md also proposes Warden discovery/presets on demand.

**Acceptance:** Detect Sail/DDEV/Lando project metadata and offer unsaved profile drafts. Resolve site-isolated Herd PHP explicitly and verify actual tool commands before implementation. Include on-demand Warden presets from plan.md after verifying its project conventions.

### N23 · Kubernetes

Issue: [#33](https://github.com/filipac/runlet/issues/33) · P3 · M · deferred

**Audit status:** Not implemented.

- **What.** Profile: kubeconfig, context, namespace, label selector, and container (a selector survives pod churn, like Compose identity). Runs use `kubectl exec -i … php -d … -` with stdin streaming. Tinkerwell has searchable pods and remote kubeconfig.
- **Fit.** A new adapter that copies the `DockerExecAdapter` pattern; a resolver that requires a choice when several pods match, unless "replicas are interchangeable" is ticked.
- **Risks.** Same explicit-target rules; Stop through `kubectl exec` with the signal helper.

**Acceptance:** Support explicit kubeconfig/context/namespace/container selection, stable pod resolution, streamed runs and confirmed Stop without silently selecting ambiguous replicas.

### N24 · Forge and Ploi import

Issue: [#34](https://github.com/filipac/runlet/issues/34) · P3 · M · deferred

**Audit status:** Not implemented.

- **What.** Import servers and sites as SSH profiles (Forge API v2 token with `server:view` in the Keychain), detect `current` symlinks, and set the site user.
- **Fit.** Needs the archived SSH design. A sheet that creates `SSHProfile` drafts.
- **Risks.** Store the token in the Keychain only; import never connects.

**Acceptance:** Import Forge/Ploi server/site drafts with least-privilege tokens stored in Keychain; detect current-directory symlinks and never connect during import.

### N25 · Global drivers, Testbench, and a driver gallery

Issue: [#18](https://github.com/filipac/runlet/issues/18) · P2 · S

**Audit status:** Not implemented.

- **What.**
  - `~/Library/Application Support/Runlet/Drivers/*Driver.php` drivers apply to every target. They are **sent in the run request**, so they also work in Docker and SSH targets without mounts.
  - A built-in `TestbenchDriver` for Laravel package work (Tinkerwell 4.21).
  - A docs gallery of ported drivers (Craft, Drupal, Magento 2, Shopware, TYPO3) added on demand.
- **Why.** Tinkerwell has global drivers that win over project ones, and a broad framework matrix.
- **Fit.** `RunnerBundle.script` adds `drivers: [{name, source}]`, which the runner `eval`s before project drivers. This shares the injection code with the archived SSH driver design. Testbench goes in `Drivers.php`.
- **Risks.** `__DIR__` inside eval'd drivers: rewrite it or document that only single-file drivers are supported. Decide precedence (Tinkerwell lets global drivers win; Runlet should let project drivers win and say so).

**Acceptance:** Load global single-file drivers for local/Docker/SSH runs, define precedence in favor of project drivers, support explicit local-only SSH driver injection, and add Testbench/gallery entries on demand.

### N26 · App info panels

Issue: [#19](https://github.com/filipac/runlet/issues/19) · P2 · M

**Audit status:** Not implemented.

- **What.** Clicking the framework chip (status bar or tab card) opens an "App Info" popover. Laravel shows `artisan about --json` (environment, debug, cache, and drivers). A driver can add `panels(): array` of sections with key/value rows. It loads only on click, because it boots the app.
- **Why.** Tinkerwell has panels (`appPanels()`, `.tinkerwell/panels`), and it helps you check the environment before you run.
- **Fit.** Runner `mode: "panels"`, like `mode: "commands"` (`ProjectCommands.swift`). A popover view.
- **Risks.** Boots project code, so only on click, and production profiles confirm (the archived SSH production/safe-mode design).

**Acceptance:** Load driver-defined App Info panels only on click, with production confirmation and bounded key/value sections.

### N27 · Log viewer

Issue: [#20](https://github.com/filipac/runlet/issues/20) · P2 · M

**Audit status:** Not implemented.

- **What.** View ▸ Logs (Tinkerwell uses ⌘L). Pick a file: Laravel `storage/logs/*.log` (nested folders included), driver `logPaths()`, or for Docker the container's stdout (`docker logs --follow --tail 500`). Parse Monolog entries, including multi-line traces and the JSON formatter. Filter by level, search, follow, and turn stack frames into editor links. Add "Logs written by this run" from N03.
- **Why.** Tinkerwell has a log viewer with polling. Reading logs next to the scratchpad saves a terminal round-trip.
- **Fit.**
  - Local projects, and Docker or SSH with a local folder where the logs are inside a bind mount, read **host files** directly. No exec is needed; follow with a `DispatchSource` file watcher that handles rotation.
  - Docker without a mount uses `docker logs` or `docker exec tail -F`, and SSH uses `ssh tail -F`. Both run only after the user clicks Follow.
  - A new `LogViewer.swift` panel; `EditorPathMapping` for links.
- **Risks.** Large files: tail-read and bound the memory. Remote follow is an explicit action and stops when the panel closes.

**Acceptance:** Discover and follow local/remote/container logs on request with rotation handling, level/search filters and mapped frame links; bound memory and stop remote following when closed.

### N28 · Database schema browser

Issue: [#21](https://github.com/filipac/runlet/issues/21) · P2 · M

**Audit status:** Not implemented.

- **What.** A Database pane: connections, tables with approximate row counts, and columns and indexes. Clicking a table opens a new tab with `DB::table('x')->limit(50)->get()`, which doesn't run.
- **Why.** Faster than recalling column names. Beyond Tinkerwell. Completion can later use the column names.
- **Fit.** Runner `mode: "schema"` through `Schema::getTables()` and `getColumns()` (Laravel 11+; older versions need `information_schema` queries). Cache per target like the Commands pane, loading only when the pane is shown.
- **Risks.** It boots the app, so the same rules apply as for the Commands pane, and production confirms.

**Acceptance:** Load a guarded schema catalog with tables/columns/indexes and open a table query in a new tab without executing it.

### N29 · SQL tabs

Issue: [#35](https://github.com/filipac/runlet/issues/35) · P3 · M–L · deferred

**Audit status:** Not implemented.

- **What.** A tab whose language is SQL, run through the target's own connection (`DB::connection()->select()`), with table output. A scratch SQL client without credentials.
- **Fit.** A new tab "language" flag, an SQL highlighter, and the runner wrapping the SQL in a PHP snippet.
- **Risks.** Writes are possible, so production confirms.

**Acceptance:** Add explicit SQL-language tabs using the selected application connection and table output; confirm production execution, including writes.

### N30 · PHPantom navigation: definition, references, inlay hints, code actions

Issue: [#22](https://github.com/filipac/runlet/issues/22) · P2 · S–M

**Audit status:** Not implemented.

- **What.**
  - ⌘-click or F12 goes to the definition. A project file opens in the external editor at its line; vendor code opens in a read-only peek.
  - Find References lists results in a popover.
  - Inlay hints show parameter names and inferred types.
  - Code actions offer "Import class" and similar fixes.
  - Folding.
- **Why.** PHPantom 0.10 already advertises all of these (`compatibility.md`); Runlet uses only completion, hover, signature help, and diagnostics.
- **Fit.** New requests in `LSPConnection` and `LanguageServer.swift`, mapped through `ScratchDocumentMapping` and `EditorPathMapping`. Presentation in `EditorController` and `EditorPopups.swift`.
- **Risks.** Positions on hidden prefix lines; reuse the mapping tests.

**Acceptance:** Add definition/peek, references, inlay hints, code actions and folding with hidden-line/path mapping. Treat rename, workspace-symbol/type-hierarchy navigation and multi-file refactoring from plan.md as deferred extensions requiring reviewable edits.

### N31 · Format snippet

Issue: [#36](https://github.com/filipac/runlet/issues/36) · P3 · M · deferred

**Audit status:** Not implemented.

- **What.** Format on demand and optionally before each run (Tinkerwell has prettify, format-before-run, and quote style). Needs a formatter that works without host PHP. Candidate: bundle **Mago** (a Rust PHP toolchain with a formatter; verify the licence and stability). PHPantom already knows a `[mago]` tool command; check whether formatting can go through it. Alternative: the project's Pint, run on the target explicitly.
- **Fit.** A bundled binary like PHPantom; a `textDocument/formatting` request.
- **Risks.** Never format implicitly unless the user opts in.

**Acceptance:** Provide explicit snippet formatting that works without host PHP; verify formatter licensing/stability and require opt-in for before-run formatting.

### N32 · Editor polish

Issue: [#37](https://github.com/filipac/runlet/issues/37) · P3 · M · deferred

**Audit status:** Not implemented.

- **What.** Built-in syntax themes (a few light and dark, not the Monaco format), indentation guides, multi-cursor commands (add next occurrence), ⌃Tab and ⌥⌘←/→ tab switching, middle-click to close.
- **Fit.** `PHPHighlighter` and `EditorTheme`, `CodeTextView`, `Commands.swift`.
- **Risks.** Multi-cursor on NSTextView is real work; check its multiple-selection support first.

**Acceptance:** Add syntax themes, indentation guides, multiple-selection commands, requested tab-switch shortcuts and middle-click close, with consistent behavior in both layouts. Include optional status-bar PHP picker polish from the older review.

### N34 · Tinkerwell migration

Issue: [#23](https://github.com/filipac/runlet/issues/23) · P2 · S

**Audit status:** Not implemented.

- **What.** Read `.tinkerwell/snippets/*.php` read-only when there is no `.runlet/snippets`. Import personal snippets from Tinkerwell's `snippets.json` (Application Support/Tinkerwell, per the paths page; the format is undocumented, so treat this as a guess). Point to the driver porting table in `drivers.md`.
- **Why.** Makes switching easier for the user and their team.
- **Fit.** `ProjectSnippets.swift` fallback folder; an import sheet.
- **Risks.** Parse defensively and never modify Tinkerwell's files.

**Acceptance:** Read Tinkerwell project snippets only as a fallback and import personal snippets defensively, without modifying Tinkerwell files.

### N35 · Share and send code

Issue: [#38](https://github.com/filipac/runlet/issues/38) · P3 · S · deferred

**Audit status:** Not implemented.

- **What.** A `runlet://new?code=…&target=…` URL opens a new tab and never runs. Copy as a link for chat. `pbpaste | runlet -` (with N39's CLI) sends code from an IDE's "external tool".
- **Fit.** `CFBundleURLTypes`, `AppDelegate.open`.
- **Risks.** The code sits in the URL; it is user-initiated. Never auto-select production targets from a link.

**Acceptance:** Support runlet://new links and runlet - stdin code, opening only and never implicitly running or selecting production targets.

### N36 · Promote a snippet

Issue: [#39](https://github.com/filipac/runlet/issues/39) · P3 · M · deferred

**Audit status:** Not implemented.

- **What.** "Save as Artisan Command…" or "Save as Pest Test…" turns the snippet into a class or test file in the local project, for review. Turns scratch code into real code.
- **Fit.** A template plus a save panel.
- **Risks.** Writes only through a save panel.

**Acceptance:** Generate reviewable Artisan command/Pest test files from a snippet through a save panel without executing code.

### N40 · Developer ID signing, notarization, auto-update, diagnostics

Issue: [#24](https://github.com/filipac/runlet/issues/24) · P1 · M

**Audit status:** Partial: package.sh already accepts signing/notary credentials, but releases are documented as ad-hoc signed. Sparkle and diagnostic export are absent.

- **What.** Sign and notarize releases (`scripts/package.sh` already supports `RUNLET_SIGN_IDENTITY` and `RUNLET_NOTARY_PROFILE`). Add Sparkle 2 updates (EdDSA-signed appcast). Help ▸ Export Diagnostics writes versions, PHP discovery, Docker status, a PHPantom log tail, and a redacted settings summary.
- **Why.** 0.0.1 is ad-hoc signed, and Gatekeeper is expected to block downloaded copies (`architecture.md`). Tinkerwell ships an updater (its paths page lists the updater cache).
- **Fit.** `project.yml` (a Sparkle package, an exact version), and `AppPaths.logs`, which is unused today.
- **Risks.** Key management for the appcast. Diagnostics must never include code, history, or hostnames without asking.

**Acceptance:** Produce and verify Developer ID signed/notarized releases, add signed Sparkle updates, and provide redacted diagnostic export without silently including code/history/hostnames.

### N41 · Quick Run panel

Issue: [#25](https://github.com/filipac/runlet/issues/25) · P2 · M

**Audit status:** Not implemented.

- **What.** A global hotkey (configurable, off by default) opens a floating Spotlight-style panel with a one-line or small editor on the default target. ⌘R runs it and shows the result inline, and "Open in Tab" moves the code to a tab.
- **Why.** Quick conversions and helpers (`Str::slug`, dates, `bcrypt`) without switching windows. Beyond Tinkerwell.
- **Fit.** An `NSPanel` (non-activating, like `PopupPanel`), reusing `CodeTextView` and the run pipeline. The sandbox is the default target.
- **Risks.** Never allow a production target in the panel.

**Acceptance:** Open a configurable global-hotkey Quick Run panel, run only on explicit Command-R, and move code into a regular tab; disallow production targets.

### N42 · Notifications for long runs

Issue: [#26](https://github.com/filipac/runlet/issues/26) · P2 · S

**Audit status:** Not implemented.

- **What.** When a run longer than 10 s finishes while Runlet is in the background, post a notification (status and duration). Clicking it focuses the tab.
- **Why.** Long data fixes and imports.
- **Fit.** `UNUserNotificationCenter` in `AppModel.run`'s finish handling.
- **Risks.** Never include output or code in the notification.

**Acceptance:** Notify on background runs exceeding ten seconds, showing only status/duration and focusing the correct tab when clicked.

### N43 · Shortcuts, Services, Spotlight

Issue: [#42](https://github.com/filipac/runlet/issues/42) · P3 · M · deferred

**Audit status:** Not implemented.

- **What.** App Intents: "Open snippet X in Runlet" and "Run sandbox snippet" (sandbox only). A Services menu item, "Open Selection in Runlet". CoreSpotlight indexing of snippet labels.
- **Fit.** App Intents, `NSServices`, CoreSpotlight.
- **Risks.** Automation can't run non-sandbox targets.

**Acceptance:** Add requested App Intents/Services/Spotlight integration, limiting automated execution to sandbox and keeping selection-opening actions nonexecuting.

### N45 · Explain or fix this error

Issue: [#44](https://github.com/filipac/runlet/issues/44) · P3 · M · optional · deferred

**Audit status:** Not implemented.

- **What.** A button on error cards sends the error, the snippet, and optionally the frame's source to a model, and shows the explanation or a proposed diff, applied only on click. Native option: Apple's on-device Foundation Models on macOS 26 (private, free; PHP quality unverified), or a bring-your-own API key.
- **Fit.** An error-card action, a provider abstraction, and the Keychain for keys.
- **Risks.** Privacy: show exactly what is sent; never send automatically.

**Acceptance:** Show exactly what error/snippet/source context is sent, request it only on click, and apply proposed changes only after an explicit action.

### N46 · Chat sidebar

Issue: [#45](https://github.com/filipac/runlet/issues/45) · P3 · L · optional · deferred

**Audit status:** Not implemented.

- **What.** A chat with per-message context toggles (editor, output, `@` local files) and "Insert into tab". Tinkerwell parity, including `appFiles()`.
- **Fit.** A sidebar next to the History & Snippets panel.
- **Risks.** As above; never run generated code automatically.

**Acceptance:** Provide provider/context controls and Insert into Tab, with explicit data disclosure and no automatic execution of generated code.

### N47 · AI inline completion

Issue: [#46](https://github.com/filipac/runlet/issues/46) · P3 · L · optional · deferred

**Audit status:** Not implemented.

- **What.** Ghost-text suggestions on demand (on typing or idle as an option), with caching.
- **Fit.** Editor ghost text, shared with N11's drawing.
- **Risks.** Cost and latency; keep separate from PHPantom.

**Acceptance:** Provide on-demand ghost text with bounded caching and explicit idle/typing opt-ins; share privacy/provider rules with other AI features.

### DOC01 · Optional confirmation before closing a tab with code

Issue: [#50](https://github.com/filipac/runlet/issues/50) · P2 · S · optional

**Audit status:** Remaining scope identified during documentation audit.

Add a persisted Ask before closing a tab with code preference and apply it consistently to single/bulk close. Reopen Closed Tab (20 entries), close-right and Command-1–9 already exist; tab cycling belongs to N32. Closing must not execute code.

**Acceptance:** Add a persisted Ask before closing a tab with code preference and apply it consistently to single/bulk close. Reopen Closed Tab (20 entries), close-right and Command-1–9 already exist; tab cycling belongs to N32. Closing must not execute code.

### DOC02 · Reload project snippets when their folder changes

Issue: [#51](https://github.com/filipac/runlet/issues/51) · P2 · S

**Audit status:** Remaining scope identified during documentation audit.

Watch the mapped .runlet/snippets folder and update metadata/code on create/edit/atomic replace/delete, including SSH local folders. ProjectSnippetCache currently reloads manually; a FileWatcher for file-backed editor tabs is already implemented. Preserve selection and never execute snippets.

**Acceptance:** Watch the mapped .runlet/snippets folder and update metadata/code on create/edit/atomic replace/delete, including SSH local folders. ProjectSnippetCache currently reloads manually; a FileWatcher for file-backed editor tabs is already implemented. Preserve selection and never execute snippets.

### DOC04 · Validate remaining SQL and mail inspector integrations

Issue: [#53](https://github.com/filipac/runlet/issues/53) · P2 · M

**Audit status:** Remaining scope identified during documentation audit.

Add disposable fixtures and focused integration coverage for Symfony Doctrine/Mailer hooks, DBAL 2, and SQL Server-specific binding/inspection behavior. DBAL 3/4 and Symfony HTML responses already have tests in InspectorTests.swift; do not call those missing. Verify selected test suites actually execute their fixtures and update documented support/gaps.

**Acceptance:** Add disposable fixtures and focused integration coverage for Symfony Doctrine/Mailer hooks, DBAL 2, and SQL Server-specific binding/inspection behavior. DBAL 3/4 and Symfony HTML responses already have tests in InspectorTests.swift; do not call those missing. Verify selected test suites actually execute their fixtures and update documented support/gaps.

### DOC05 · Refresh validation evidence and close documented acceptance gaps

Issue: [#54](https://github.com/filipac/runlet/issues/54) · P2 · M

**Audit status:** Remaining scope identified during documentation audit.

Reconcile docs/validation.md with current package/UI tests and logs. Re-run applicable fixtures and record pass/skip counts; test the packaged app UI and remaining documented user flows, measure rendered latency, and verify container child-process Stop. Review existing TabLayoutUITests, LibraryKeyboardUITests, DockerProfileManagerUITests and other added suites before claiming coverage is absent. Keep unproven Intel hardware, no-host-PHP setup and real-application dogfooding explicitly unverified. Signing belongs to N40 and PHPantom inference limitations to DOC06b.

**Acceptance:** Reconcile docs/validation.md with current package/UI tests and logs. Re-run applicable fixtures and record pass/skip counts; test the packaged app UI and remaining documented user flows, measure rendered latency, and verify container child-process Stop. Review existing TabLayoutUITests, LibraryKeyboardUITests, DockerProfileManagerUITests and other added suites before claiming coverage is absent. Keep unproven Intel hardware, no-host-PHP setup and real-application dogfooding explicitly unverified. Signing belongs to N40 and PHPantom inference limitations to DOC06b.

### DOC06b · Follow PHPantom fixes for Laravel inference gaps

Issue: [#117](https://github.com/filipac/runlet/issues/117) · P3 · S · deferred

**Status:** Remaining scope of DOC06 ([#55](https://github.com/filipac/runlet/issues/55)), whose completed scope is in [done-next-release-ideas.md](done-next-release-ideas.md).

PHPantom 0.10.0 loses the element type after `keyBy()`/`groupBy()` on Eloquent collections (no Runlet workaround), and misreads relations with only a native return type and `casts()` arrays without a trailing comma (worked around by Runlet's in-memory model copies). The upstream report drafts are in [compatibility.md](compatibility.md#phpantom-upstream-report-drafts); the owner files them.

**Acceptance:** After a PHPantom upgrade, update the `modelOverlays: false` checks in `LaravelCompletionTests`, remove each `EloquentOverlay` rewrite whose gap is fixed, and update compatibility.md. `keyBy`/`groupBy` keep the model type once PHPantom fixes it.

### DOC07 · Optional external analysis routed through the selected runtime

Issue: [#56](https://github.com/filipac/runlet/issues/56) · P3 · M · optional · deferred

**Audit status:** Remaining scope identified during documentation audit.

Add explicit project opt-ins for PHPStan/Larastan, PHPCS or Mago diagnostics, with runtime-aware local/Docker/SSH commands and path mapping. Preserve the current rule that language-service startup never launches project tooling implicitly.

**Acceptance:** Add explicit project opt-ins for PHPStan/Larastan, PHPCS or Mago diagnostics, with runtime-aware local/Docker/SSH commands and path mapping. Preserve the current rule that language-service startup never launches project tooling implicitly.

### DOC08 · Optional dependency mirroring for Docker-only completion sources

Issue: [#57](https://github.com/filipac/runlet/issues/57) · P3 · M · optional · deferred

**Audit status:** Remaining scope identified during documentation audit.

Offer explicit bounded dependency/source mirroring when vendor exists only in a container volume, with correct workspace mapping and freshness. Keep limited-mode explanations and never execute/connect merely to open a tab.

**Acceptance:** Offer explicit bounded dependency/source mirroring when vendor exists only in a container volume, with correct workspace mapping and freshness. Keep limited-mode explanations and never execute/connect merely to open a tab.

### DOC09 · Target groups and pinned or favorite projects

Issue: [#58](https://github.com/filipac/runlet/issues/58) · P3 · M · deferred

**Audit status:** Remaining scope identified during documentation audit.

Add saved target groups/favorites and navigation for them. Colors, palette recency, Dock recents and automatic profile resolution already exist and are not outstanding scope.

**Acceptance:** Add saved target groups/favorites and navigation for them. Colors, palette recency, Dock recents and automatic profile resolution already exist and are not outstanding scope.

### DOC10 · Optional sandbox versions, services, and disposable fixture data

Issue: [#59](https://github.com/filipac/runlet/issues/59) · P3 · M · optional · deferred

**Audit status:** Remaining scope identified during documentation audit.

Offer sandbox version selection and explicit configurable services/fixture seeding. The pinned sandbox, reset, Docker fallback and image download already exist. Keep all effects restricted to Runlet-owned sandbox data.

**Acceptance:** Offer sandbox version selection and explicit configurable services/fixture seeding. The pinned sandbox, reset, Docker fallback and image download already exist. Keep all effects restricted to Runlet-owned sandbox data.

### SSH08 · Optional safe mode for SSH and other targets

Issue: [#47](https://github.com/filipac/runlet/issues/47) · P2 · M · optional

**Audit status:** Remaining scope identified during documentation audit.

Reuse N15 rollback; add explicit notifications/queue fakes, Laravel HTTP blocking, process-function restrictions and read-only connection selection, with visible mode/limitations and a long-run lock warning. Mail interception already exists. Safe mode is not a sandbox.

**Acceptance:** Reuse N15 rollback; add explicit notifications/queue fakes, Laravel HTTP blocking, process-function restrictions and read-only connection selection, with visible mode/limitations and a long-run lock warning. Mail interception already exists. Safe mode is not a sandbox.

### SSH09-CACHE · Optional SSH runner payload cache

Issue: [#48](https://github.com/filipac/runlet/issues/48) · P3 · M · optional · deferred

**Audit status:** Remaining scope identified during documentation audit.

Cache the runner bundle by hash in a private per-user folder, validate hash/owner before loading, and fall back to streaming on mismatch/read-only storage. Measure payload costs first. Existing per-profile opcode/file caching in SSH.swift (Keep compiled PHP on the server, on for new profiles since #68) caches compiled PHP; it does not cache the runner payload.

**Acceptance:** Cache the runner bundle by hash in a private per-user folder, validate hash/owner before loading, and fall back to streaming on mismatch/read-only storage. Measure payload costs first. Existing per-profile opcode/file caching in SSH.swift (Keep compiled PHP on the server, on for new profiles since #68) caches compiled PHP; it does not cache the runner payload.

### SSH09-TIMING · Add explicit SSH timing checks to the packaged self-test

Issue: [#49](https://github.com/filipac/runlet/issues/49) · P3 · S · optional · deferred

**Audit status:** Remaining scope identified during documentation audit.

Add an explicit --ssh <profile> self-test timing option that measures transport/payload/bootstrap costs using the chosen profile. Never contact a server during the default self-test.

**Acceptance:** Add an explicit --ssh <profile> self-test timing option that measures transport/payload/bootstrap costs using the chosen profile. Never contact a server during the default self-test.

## Out of scope / not worth it

These are retained decisions, not TODOs or issue-backed commitments.


| Tinkerwell feature | Why skip |
| --- | --- |
| Laravel Vapor | Serverless: no return values (`dump()` only), Vapor CLI login, slow round trips. The user parked it. Revisit only for a concrete need. |
| Laravel Cloud | An API-token execution model (environment commands), no logs. The user parked it. |
| Windows, Linux, WSL2 | Runlet is native macOS by design. |
| Homestead as a separate guide | It's just an SSH host (the implemented SSH target). |
| PhpStorm plugin | A separate product with its own licensing. The `runlet` CLI, URL scheme, and external-editor links cover the useful part (sending code to Runlet, jumping back to the IDE). |
| Graph view | The expandable tree and table cover the need. A node graph adds UI without new information. |
| Monaco JSON theme files | Tinkerwell's format exists because of its Monaco/Electron editor. A few built-in themes (N32) are enough. |
| Vim keymap | L-sized for NSTextView. Only if the user asks. |
| Collision toggle and `usesCollision()` | Runlet's error cards already structure errors. N07 adds the useful part (source excerpts). |
| ⌘S to run | Tinkerwell itself removed it (4.9). |
| Language-server port setting, "welcome tab" | Electron and Phpactor specifics with no Runlet equivalent. |
| Tinkerwell Wrapped, freemium, licence activation, onboarding tour | Not product value for a personal tool. Licensing is a separate business decision. |
| Auto-evaluate as the default | Conflicts with "nothing runs without an explicit Run". Only N17's sandbox-only opt-in. |
| Driver `contextMenu()` and dynamic snippets | Deprecated by Tinkerwell (3.31). N16 (parameterised snippets, done in [#14](https://github.com/filipac/runlet/issues/14)) replaces them. |
| Custom `php.ini` per Herd version | Herd already applies its own `php.ini` to its binaries; Runlet runs those binaries. |

## Research sources

Original research sources (not re-fetched during this code audit):


Tinkerwell v5 docs (all read; none failed to load, though several pages are short):

- Getting started: [about](https://tinkerwell.app/docs/5/getting-started/about), [installation](https://tinkerwell.app/docs/5/getting-started/installation), [settings](https://tinkerwell.app/docs/5/getting-started/settings), [PhpStorm plugin](https://tinkerwell.app/docs/5/getting-started/phpstorm-plugin)
- Setup guides: [Laravel sandbox](https://tinkerwell.app/docs/5/setup-guides/using-the-laravel-sandbox), [SSH](https://tinkerwell.app/docs/5/setup-guides/ssh), [Sail](https://tinkerwell.app/docs/5/setup-guides/sail), [Homestead](https://tinkerwell.app/docs/5/setup-guides/laravel-homestead), [Docker](https://tinkerwell.app/docs/5/setup-guides/docker), [Kubernetes](https://tinkerwell.app/docs/5/setup-guides/kubernetes), [Vapor](https://tinkerwell.app/docs/5/setup-guides/vapor), [Laravel Cloud](https://tinkerwell.app/docs/5/setup-guides/laravel-cloud), [WSL](https://tinkerwell.app/docs/5/setup-guides/wsl), [autocompletion](https://tinkerwell.app/docs/5/setup-guides/autocompletion)
- Basic usage: [evaluating code](https://tinkerwell.app/docs/5/basic-usage/evaluating-code), [Detail Dive](https://tinkerwell.app/docs/5/basic-usage/detail-dive), [tabs](https://tinkerwell.app/docs/5/basic-usage/tabs), [command palette](https://tinkerwell.app/docs/5/basic-usage/command-palette), [history](https://tinkerwell.app/docs/5/basic-usage/history), [snippets](https://tinkerwell.app/docs/5/basic-usage/snippets)
- Advanced usage: [custom themes](https://tinkerwell.app/docs/5/advanced-usage/custom-themes), [shortcuts](https://tinkerwell.app/docs/5/advanced-usage/shortcuts), [magic comments](https://tinkerwell.app/docs/5/advanced-usage/magic-comments), [Collision](https://tinkerwell.app/docs/5/advanced-usage/collision), [project-specific PHP](https://tinkerwell.app/docs/5/advanced-usage/project-specific-php), [log viewer](https://tinkerwell.app/docs/5/advanced-usage/log-viewer), [CLI helper](https://tinkerwell.app/docs/5/advanced-usage/cli-helper), [AI assistant](https://tinkerwell.app/docs/5/advanced-usage/ai-assistant), [Xdebug](https://tinkerwell.app/docs/5/advanced-usage/debugging-with-xdebug), [MCP server](https://tinkerwell.app/docs/5/advanced-usage/mcp-server)
- Extending and troubleshooting: [custom drivers](https://tinkerwell.app/docs/5/extending-tinkerwell/custom-drivers), [panels](https://tinkerwell.app/docs/5/extending-tinkerwell/panels), [blank screen](https://tinkerwell.app/docs/5/troubleshooting/blank-screen), [troubleshooting](https://tinkerwell.app/docs/5/troubleshooting/troubleshooting), [paths](https://tinkerwell.app/docs/5/troubleshooting/paths)

Other Tinkerwell pages:

- [Changelog](https://tinkerwell.app/changelog) (5.x, 4.x, 3.x), [homepage](https://tinkerwell.app/), [What's new in Tinkerwell 5](https://tinkerwell.app/whats-new-in-tinkerwell-5), [Tinkerwell for Laravel](https://tinkerwell.app/tinkerwell-for-laravel)
- Feature pages: [Detail Dive](https://tinkerwell.app/features/detail-dive), [magic comments](https://tinkerwell.app/features/magic-comments), [log viewer](https://tinkerwell.app/features/logviewer), [table mode](https://tinkerwell.app/features/table-mode), [Herd integration](https://tinkerwell.app/features/laravel-herd-integration), [AI](https://tinkerwell.app/features/ai), [REPL](https://tinkerwell.app/features/repl), [snippets](https://tinkerwell.app/features/snippets), [themes](https://tinkerwell.app/features/themes), [command palette](https://tinkerwell.app/features/command-palette)
- Older docs and blog: [v4 settings](https://tinkerwell.app/docs/4/getting-started/settings), [v4 SSH](https://tinkerwell.app/docs/4/setup-guides/ssh), [v2 SSH](https://tinkerwell.app/docs/2/basic-usage/ssh), [v3 SSH (index text only)](https://tinkerwell.app/docs/3/basic-usage/ssh), [1Password SSH agent blog post](https://tinkerwell.app/blog/how-to-set-up-the-1password-ssh-agent-for-secure-ssh-connections)
- Public driver repository: [beyondcode/tinkerwell](https://github.com/beyondcode/tinkerwell) (`src/Drivers/TinkerwellDriver.php`, `LaravelTinkerwellDriver.php`, `src/Panels/LaravelPanel.php`)
- Search used for the Forge API v2 scope and for Ploi (no Tinkerwell–Ploi integration found): [Tinkerwell changelog](https://tinkerwell.app/changelog), [Ploi docs](https://ploi.io/documentation/server)
