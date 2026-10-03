# Runlet: completed next-release ideas

Reconciled 2026-10-02 under [#3](https://github.com/filipac/runlet/issues/3). Evidence below comes from `CHANGELOG.md` and source/test inspection; this audit did not run tests or prove release signing. See [next-release-ideas.md](next-release-ideas.md) for every remaining scope and issue.

## Completed scope and evidence

| Original ID | Completed behavior | Implementation evidence | Changelog entry |
| --- | --- | --- | --- |
| SSH-1 | SSH profiles, streamed runs, shared connections, probes, Stop | `Packages/RunletKit/Sources/RunletExecution/SSH.swift`, `SSHProbe.swift`, `RunletCore/SSHProfile.swift`, `SSHRunTests.swift` | SSH targets: run snippets on a server (SSH-1) |
| SSH-2 | Interactive Connect/Disconnect, persistent password/2FA login | `Runlet/App/AppModel+SSH.swift`, `Runlet/Features/SSHConnectionViews.swift`, `SSHTerminalTests.swift` | SSH: Connect… and Disconnect for passwords and 2FA (SSH-2) |
| SSH-3 | Local checkout completion, snippets, path mapping and drift | `RunletExecution/LocalCheckout.swift`, `RunletCore/EditorLinks.swift`, `LocalCheckoutTests.swift` | SSH: the local folder, suggestions, and drift (SSH-3) |
| SSH-4 / N14 (core) | Environments/colors, production badges, confirmation/grace and stricter defaults | `Runlet/App/AppModel+Production.swift`, `RunletCore/ProductionGuard.swift`, `ProductionGuardTests.swift` | Target environments and the production guard (N14, SSH-4) |
| N14 (environment and history) | The runner reports the application's environment in `bootstrapped` (Laravel, Lumen, Laravel Zero, Symfony, WordPress, and a project driver's `environment()`); a tab offers Mark as Production (saved as a target edit, nothing runs) or Dismiss (remembered per target) when the app says production and the target isn't marked, and shows an informational note for production targets whose app says local; History keeps the target's marking, colour, and the reported environment as a snapshot, with badges drawn from it ([#12](https://github.com/filipac/runlet/issues/12)) | `Resources/Runner/src/Drivers.php` (`environment()`), `Runner.php` (`driverEnvironment`), `RunletCore/AppEnvironment.swift`, `RunProtocol.swift`, `Models.swift` (`HistoryEntry`), `Runlet/App/AppModel+Production.swift`, `Runlet/Features/ProductionViews.swift` (`AppEnvironmentBanner`), `LibraryInspector.swift`; `AppEnvironmentTests.swift`, `DriverTests.swift`, `SandboxAndRecreationTests.swift`; Debug app screenshots in [#121](https://github.com/filipac/runlet/pull/121); [compatibility notes](compatibility.md#application-environment-and-production-history-12) | Production guard: app environment and history ([#12](https://github.com/filipac/runlet/issues/12)) |
| SSH-5 | Remote commands, interactive shells and production confirmations | `RunletExecution/ProjectCommands.swift`, `Runlet/App/AppModel+Commands.swift`, `SSH.swift` | SSH: project commands and shells on the server (SSH-5) |
| SSH-6 | Remote Docker discovery/resolution, runs, commands, shells and Stop | `RunletExecution/DockerCLI.swift`, `SSH.swift`, `SSHDockerTests.swift` | SSH: Docker on the server (SSH-6) |
| SSH-7 | Unified Profiles UI, SSH config import, palette/workspace/settings integration | `Runlet/Features/ProfileManager.swift`, `SSHConfigImport.swift`, `RunletExecution/SSHConfigHosts.swift`, `RunletCore/Workspace.swift` | Profiles window for Docker and SSH, ~/.ssh/config import (SSH-7) |
| N01 (core) | Query inspection, bindings, timing, duplicate/N+1 grouping and copy actions | `Resources/Runner/src/Inspector.php`, `Runlet/Features/InspectorViews.swift`, `RunletCore/QueryAnalysis.swift`, `InspectorTests.swift` | Run inspector in the output pane; Run inspector: driver API |
| N01 (Explain) | Prepare an idle PHP Explain tab from a captured query, with original target, typed bindings, and connection; explicit Run keeps production confirmation ([#4](https://github.com/filipac/runlet/issues/4)) | `RunletCore/QueryExplain.swift`, `Runlet/App/AppModel+Inspector.swift`, `QueryExplainTests.swift`, `QueryExplainExecutionTests.swift`, `ScenarioUITests.testExplainPreservesCapturedTargetAndWaitsForExplicitProductionRun`; see [validation scope](sql-explain.md#validation) | Explain captured SQL in a new tab |
| N17 | Opt-in per sandbox tab; 800 ms edit debounce, visible AUTO, full-tab evaluation, no persisted opt-in or runs on code loads ([#30](https://github.com/filipac/runlet/issues/30)) | `Runlet/App/TabModel.swift`, `AppModel.swift`, `Runlet/Editor/EditorController.swift`, `RunletUITests/SandboxAutoRunUITests.swift`; see [guide and validation](sandbox-auto-run.md) | Sandbox-only auto-run |
| N02 | Mail capture/interception and restricted HTML/mail/view previews | `Resources/Runner/src/Drivers.php`, `Inspector.php`, `Runlet/Features/HTMLPreview.swift`, `InspectorViews.swift`, `InspectorTests.swift` | Run inspector in the output pane; Run inspector: driver API |
| N03 (part) | Laravel log records and queued mail/notification records | `Resources/Runner/src/Drivers.php` inspectLaravelLog/inspectLaravelMail | Run inspector: driver API, queries without Laravel, mail and previews |
| N04 | Row JSON/PHP/CSV copy, Markdown, Save Output As and clickable URLs | `RunletCore/OutputExport.swift`, `Runlet/Features/OutputPane.swift`, `Runlet/App/AppModel+Inspector.swift`, `OutputExportTests.swift` | Output export: rows as JSON or PHP, Markdown, Save Output As…, links |
| N05 (part) | DateTime/Carbon, backed enum, closure summaries and array counts | `Resources/Runner/src/Runner.php` ValueNormalizer, `RunletCore/ValueNode.swift` inlineSummary | Execution engine / runner value normalization |
| N06 | Bounded JSON trees with exact numeric literals and Copy Pretty, searchable/wrapping long text, PNG/JPEG/SVG previews, and detected HTML using the restricted viewer ([#7](https://github.com/filipac/runlet/issues/7)) | `RunletCore/StringViewers.swift`, `Runlet/Features/StringViewers.swift`, `OutputPane.swift`; `StringViewersTests.swift`, native viewer tests in `RunletUITests.swift`; [guide](string-viewers.md) | Specialized viewers |
| N08 | Finished output and status tooltip show available bootstrap/execute phases, host total/start time, peak memory, and query time; missing phases remain unavailable ([#9](https://github.com/filipac/runlet/issues/9)) | `RunletCore/RunProtocol.swift`, `RunletExecution/RunSession.swift`, `Runlet/App/TabModel.swift`, `Runlet/Features/OutputPane.swift`, `MainWindow.swift`; `RunTimingTests.swift`, `LocalRunTests.swift`, `PersistenceTests.swift`, `RunletUITests.testTimingBreakdownAndStatusDetails`; [guide](run-timings.md) | Run timing breakdown |
| N11 | Magic comments: `//?`, `/*?*/`, `/*?->projection*/`, `/*?.*/`; values streamed while the code runs on every target; dim inline values with `×N`, a hover panel with the value tree and hits, highlighting, gutter markers, Run Selection mapping; refused placements reported without changing the run; settings to turn them off or show values when the run ends | `Resources/Runner/src/MagicComments.php`, `Runner.php` (`SnippetCompiler`), `RunletCore/InlineValues.swift`, `RunletExecution/RunSession.swift`, `Runlet/Editor/InlineValueOverlay.swift`, `MagicCommentTests.swift` (semantics fixtures run with and without the comments; streaming locally, in a container, and over SSH), `InlineValuesTests.swift`; Debug app screenshots in [#74](https://github.com/filipac/runlet/pull/74) | Magic comments ([#10](https://github.com/filipac/runlet/issues/10)) |
| N29 | SQL tabs: a PHP/SQL tab language (New SQL Tab, Switch Tab Language, `.sql` files; kept in sessions, workspaces, and history; old files load as PHP), an SQL highlighter with no PHPantom, one statement per run (the selection or the statement at the caret; several refused), the application's own connection with a picker (the project driver's `sqlConnection()` first, then Laravel, Symfony Doctrine, WordPress `$wpdb`, or a detected Eloquent connection; otherwise a clear refusal, never credentials), result tables or affected rows with a row cap, no auto-run or MCP, and a production confirmation that always asks and warns on writes ([#35](https://github.com/filipac/runlet/issues/35)) | `RunletCore/SQLTabs.swift`, `Resources/Runner/src/SqlTab.php`, `Drivers.php` (`sqlConnection()`, `SqlConnections`), `Runlet/App/AppModel+SQL.swift`, `Runlet/Editor/SQLHighlighter.swift`, `Runlet/Features/SQLTabViews.swift`; `SQLTabTests.swift`, `SQLTabExecutionTests.swift`; Debug app screenshots in [#120](https://github.com/filipac/runlet/pull/120); [guide](sql-tabs.md) | SQL tabs ([#35](https://github.com/filipac/runlet/issues/35)) |
| N33 | Keyboard-first History/Snippets and ! history in Open Anything | `Runlet/Features/LibraryKeyboard.swift`, `LibraryInspector.swift`, `Palette.swift`, `LibraryKeyboardUITests.swift` | Keyboard-first History and Snippets, history in ⌘P |
| N38 | `Runlet\bench()` with bounded statistics, memory, distribution and comparison cards; Laravel `Benchmark::dd()` cards; Excimer/SPX detection in discovery, probes and runs; Profile Run with Excimer and a native flame graph; disabled with a reason without Excimer. SPX is detected but deliberately not used (it profiles only processes started with `SPX_ENABLED=1` and writes its reports to files) | `Resources/Runner/src/Benchmark.php`, `Profiler.php`, `RunletCore/Benchmarks.swift`, `Profiling.swift`, `Runlet/App/AppModel+Profiling.swift`, `Runlet/Features/BenchmarkViews.swift`, `FlameGraphView.swift`, `BenchmarkProfileTests.swift`, `BenchmarkProfileRunnerTests.swift` | Benchmark and profile ([#41](https://github.com/filipac/runlet/issues/41)) |
| N39 | CLI install/opening, watched file tabs, Dock recents and Float on Top | `RunletCLI/RunletTool.swift`, `Runlet/App/FileSync.swift`, `DockMenu.swift`, `Commands.swift`, `RunletCore/FileWatcher.swift` | The runlet command-line tool; Tabs follow their files on disk; Float on Top, recent projects in the Dock |
| N40 (part) | Signing/notary inputs supported by packaging script | `scripts/package.sh` | Packaging, target switcher, fixes; actual releases remain documented as ad-hoc signed |
| N19 | Open REPL: the target's Tinker, PsySH, or `php -a` in a terminal tab (Commands pane, Library menu, palette), on local, sandbox, Docker, SSH, and SSH-plus-container targets; production asks every time ([#32](https://github.com/filipac/runlet/issues/32)) | `RunletExecution/ProjectREPL.swift`, `Runlet/App/AppModel+Commands.swift` (`openREPL`), `Runlet/Features/ProjectCommandsView.swift`, `RunletCore/ProductionGuard.swift` (`GuardedAction.repl`), `ProjectREPLTests.swift` (unit, sandbox Tinker, fixture Docker container, SSH fixture), `ProductionGuardTests.swift` | Open REPL in the terminal (#32) |
| N37 | Tests group in the Commands pane: Run All, File…, and Filter… (`--filter`, one quoted argument) in a terminal tab with `php artisan test` (Laravel with Collision), else Pest, else PHPUnit, each with a PHPUnit configuration; local projects and the sandbox checked on this Mac (runner, configuration, and its test suites), Docker, SSH, and SSH-plus-container targets choose on the target; disabled on production targets ([#40](https://github.com/filipac/runlet/issues/40)) | `RunletExecution/ProjectTests.swift`, `Runlet/App/AppModel+Tests.swift`, `Runlet/Features/ProjectCommandsView.swift` (`testsGroup`, `TestsPrompt`), `ProjectTestsTests.swift` (detection layouts, `sh`/`dash`/`bash`/`zsh` quoting, per-target requests, the production rule, `artisan test` in the Laravel fixture, the SSH fixture, the fixture Docker container) | Tests group in the Commands pane (#40) |
| N26 | App Info: the framework chip (status bar and tab cards) and Library ▸ Show App Info open a popover with Laravel's `artisan about` data (in-process), Symfony's and WordPress's details, PHP, and the driver's `panels()`; bounded, secrets redacted in the runner and the app, cached per target with its age and Refresh, loaded only on that click, production confirms every load, SSH connects only then ([#19](https://github.com/filipac/runlet/issues/19)) | `Resources/Runner/src/Panels.php`, `Runner.php` (`mode: "panels"`), `Drivers.php` (`Driver::panels()`), `RunletCore/AppInfo.swift`, `RunletExecution/AppInfoLoader.swift`, `Runlet/App/AppModel+AppInfo.swift`, `Runlet/Features/AppInfoViews.swift`, `RunletCore/ProductionGuard.swift` (`GuardedAction.appInfo`); tests `AppInfoTests.swift` (decoding, bounds, redaction, open policy), `ProductionGuardTests.swift`, `AppInfoRunnerTests.swift` (sandbox, Laravel fixture and project driver, Symfony, WordPress, custom driver on PHP 8.4 and 7.4, bounds, failures, the fixture Docker container, the SSH fixture); Debug app screenshots in [#123](https://github.com/filipac/runlet/pull/123) | App Info panels ([#19](https://github.com/filipac/runlet/issues/19)) |
| N44 | MCP server: `runlet mcp` (stdio, MCP 2026-07-28 plus `initialize`-based revisions) with `list_targets`, `list_snippets`, `get_snippet`, `add_snippet`, `run_php`, `get_last_output` over a private Unix socket; an in-app approval sheet for every run; "Allow for this session" for the sandbox only; production always asks without the grace; SSH never connects silently; off by default (Settings ▸ AI Clients) | `RunletCLI/MCPCommand.swift`, `RunletCore/MCPServer.swift`, `MCPTools.swift`, `MCPBridge.swift`, `MCPAppClient.swift`, `MCPApproval.swift`, `MCPRunReport.swift`, `Runlet/App/AppModel+MCP.swift`, `Runlet/Features/MCPViews.swift`; tests `MCPServerTests.swift`, `MCPBridgeTests.swift`, `MCPApprovalTests.swift`; end-to-end `scripts/mcp-e2e/` ([mcp.md](mcp.md#testing)) | MCP server for AI clients ([#43](https://github.com/filipac/runlet/issues/43)) |
| SSH performance follow-up (part) | Opt-in server PHP opcode/file cache; session driver and WordPress URL reuse | `RunletExecution/SSH.swift`, `RunletCore/SSHProfile.swift`, `Resources/Runner/src/Runner.php` | Keep compiled PHP on the server; Remembered for the session: driver and WordPress site URL |
| DOC12 | Browse… for a local Docker profile's working directory: lists folders only in the selected container, only when clicked, with the profile's PHP and user (read-only `php -r` over `docker exec`); stopped, removed, ambiguous, and recreated containers follow the profile's identity rules; permission denied, missing folders, and a missing PHP or user are explained; symlinks are kept; unreadable folders can't be chosen; saving runs no snippet code ([#62](https://github.com/filipac/runlet/issues/62)) | `RunletExecution/DockerDirectories.swift`, `RemoteDirectories.swift`, `Runlet/Features/DockerProfileEditor.swift`, `RemoteDirectoryBrowser.swift`; `DockerDirectoryTests.swift` (unit, and the `laravel` and `restricted` fixture containers); Debug app screenshots in [#112](https://github.com/filipac/runlet/pull/112) | Browse directories in Docker profiles ([#62](https://github.com/filipac/runlet/issues/62)) |
| DOC06 | Laravel completion with PHPantom 0.10.0: the four documented gaps reproduced in focused tests with a broader model workspace. Relations with only a native return type and the last `casts()` entry without a trailing comma complete through in-memory model copies (nothing written to the project); macros from registered service providers were already supported; `keyBy`/`groupBy` on Eloquent collections recorded as a PHPantom gap with an upstream report draft ([#55](https://github.com/filipac/runlet/issues/55)) | `RunletLanguage/EloquentOverlay.swift`, `RunletLanguage/LanguageServer.swift` (`modelOverlays`), `EloquentOverlayTests.swift`, `LaravelCompletionTests.swift` (with and without the copies); [compatibility.md](compatibility.md#laravel-completion-scenario-15-phpantom-0100-laravel-13340) | Laravel completion: native-typed relations and casts() without a trailing comma |
| N16 | Parameterised snippets: typed `@input` declarations (`int`, `float`, `string`, `bool`; label, default, choices) in project and personal snippet docblocks, with unreadable ones listed instead of dropped; an input form before every snippet open or insert (Snippets panel, Open Anything); values inserted as one-line PHP literals with `var_export` semantics, placeholder assignments filled in place; never runs; MCP `get_snippet` returns the inputs ([#14](https://github.com/filipac/runlet/issues/14)) | `RunletCore/SnippetInputs.swift`, `RunletCore/ProjectSnippets.swift`, `Runlet/App/AppModel+SnippetInputs.swift`, `Runlet/Features/SnippetInputSheet.swift`, `LibraryInspector.swift`, `AppModel+MCP.swift`; `SnippetInputsTests.swift`, `SnippetInputsPHPTests.swift` (literals evaluated by a local PHP and compared with `var_export`); end-to-end `scripts/snippet-input-screenshots.py`; Debug app screenshots in [#122](https://github.com/filipac/runlet/pull/122); [guide](snippet-inputs.md) | Parameterised snippets ([#14](https://github.com/filipac/runlet/issues/14)) |
| DOC03 | Optional personal snippet descriptions: save/edit, library and palette display/search, MCP reads/search, and preservation when duplicated or copied from a project | `RunletCore/Models.swift`, `Runlet/App/AppModel.swift`, `AppModel+MCP.swift`, `Runlet/Features/Sheets.swift`, `LibraryInspector.swift`, `Palette.swift`; `PersistenceTests.swift`, `LibraryKeyboardUITests.swift`; [guide](personal-snippets.md) | Personal snippet descriptions ([#52](https://github.com/filipac/runlet/issues/52)) |
| DOC11 | Opt-in Settings ▸ General ▸ Output switches: the output pane hidden until a run starts in the tab (hidden again by Clear Output; per tab, never saved) and Escape in the editor hiding it until the next run, after completions, hover/signature/inline-value panels, the find bar, and input methods; ⌘. stays Stop. The pane reappears at the saved layout and split fraction; both off by default ([#60](https://github.com/filipac/runlet/issues/60)) | `RunletCore/OutputPaneVisibility.swift`, `RunletCore/Models.swift`, `Runlet/App/AppModel+OutputPane.swift`, `Runlet/Editor/CodeTextView.swift`, `Runlet/Features/MainWindow.swift`, `SettingsView.swift`; `OutputPaneVisibilityTests.swift`; Debug app screenshots in [#111](https://github.com/filipac/runlet/pull/111); [compatibility notes](compatibility.md#output-pane-hide-until-a-run-escape-hides-it-60) | Output: hide until a run, Escape hides ([#60](https://github.com/filipac/runlet/issues/60)) |

Paths abbreviated as `RunletCore/`, `RunletExecution/`, and `RunletLanguage/` are under `Packages/RunletKit/Sources/`; named package test files are under `Packages/RunletKit/Tests/` and UI tests under `RunletUITests/`.

## Partial ideas: remaining issues

- N03: Run recorder: HTTP calls, general jobs, and optional events — [#5](https://github.com/filipac/runlet/issues/5).
- N05: Readable values: built-in summaries and driver casters — [#6](https://github.com/filipac/runlet/issues/6).
- N08: Timing breakdown — [#9](https://github.com/filipac/runlet/issues/9).
- N40: Developer ID signing, notarization, auto-update, diagnostics — [#24](https://github.com/filipac/runlet/issues/24).
- DOC04: Validate remaining SQL and mail inspector integrations — [#53](https://github.com/filipac/runlet/issues/53).
- N29: SQL tabs: completion ([#128](https://github.com/filipac/runlet/issues/128)), multi-statement scripts ([#129](https://github.com/filipac/runlet/issues/129)), and snippets that keep their language ([#130](https://github.com/filipac/runlet/issues/130)).
- SSH08: Optional safe mode for SSH and other targets — [#47](https://github.com/filipac/runlet/issues/47).
- SSH09-CACHE: Optional SSH runner payload cache — [#48](https://github.com/filipac/runlet/issues/48).
- SSH09-TIMING: Add explicit SSH timing checks to the packaged self-test — [#49](https://github.com/filipac/runlet/issues/49).
- N25: Global drivers, Testbench, and a driver gallery — [#18](https://github.com/filipac/runlet/issues/18).
- DOC06: `keyBy`/`groupBy` element types on Eloquent collections, and retiring the model-copy workarounds once PHPantom fixes them — [#117](https://github.com/filipac/runlet/issues/117).

The opcode cache is implemented; the hashed runner-payload cache is not. DBAL 3/4 and Symfony HTML-response tests already exist; remaining Symfony Doctrine/Mailer, DBAL 2 and SQL Server integration evidence belongs to DOC04. Core N02 is complete; those coverage gaps are not evidence that previews are absent.

## Original completed idea entries

These are the original proposals, retained for provenance. The implementation/evidence table above takes precedence over proposal wording and implementation guesses.

### N38 · Benchmark and profile

Issue: [#41](https://github.com/filipac/runlet/issues/41) · P3 · M–L · deferred

**Status:** Implemented in [#41](https://github.com/filipac/runlet/issues/41) (2026-10-03); see the table above. `Benchmark::measure()` has no hook, so `Runlet\bench()` takes its arguments instead, and `Benchmark::dd()` is recognized from its dump. SPX is detected but not used, for the reason in the table.

- **What.** `Runlet\bench(fn, n)` shows min, mean, and p95 plus memory; a nice card for Laravel's `Benchmark::measure`. "Profile Run" uses Excimer or SPX when loaded (shown in the probe) and renders a flame graph.
- **Fit.** A runner helper plus a `record` category; a flame-graph view.
- **Risks.** Profilers are optional extensions; disable the command when missing.

**Acceptance:** Provide bounded benchmark statistics and explicit optional-extension profiling with a flame graph; disable profiling with a reason when an extension is missing.

### N16 · Parameterised snippets

Issue: [#14](https://github.com/filipac/runlet/issues/14) · P2 · M

**Status:** Implemented in [#14](https://github.com/filipac/runlet/issues/14) (2026-10-03); see the table above and [snippet-inputs.md](snippet-inputs.md). Strings with control characters use a one-line double-quoted literal instead of `var_export`'s multi-line or concatenated form; the value is the same.

- **What.** Snippet docblocks declare inputs, for example `@input int $userId "User ID"` or `@input string $email`. Opening the snippet shows a small form; values are inserted as PHP literals (`var_export`) at the top of the new tab. It never runs.
- **Why.** Team runbooks ("refund order #…") without hand-editing code. This is the modern version of Tinkerwell's dynamic snippets.
- **Fit.** `ProjectSnippets.swift` metadata parsing, a sheet in `LibraryInspector.swift`. Personal snippets too.
- **Risks.** Literal generation must escape correctly; use `var_export` semantics on the Swift side and test them.

**Acceptance:** Parse typed snippet inputs, present an input form, and generate escaped PHP literals without running the snippet.

### N02 · Mail capture and HTML, view, and mailable preview

- **What.**
  - Returning or dumping a Mailable, a `MailMessage`, a View, an `Htmlable`, or a Symfony `Response` shows **Preview**: the rendered HTML in a sheet or window, with a Text/HTML switch and a Run Again button. Tinkerwell's preview also reruns with ⌘R.
  - A **Mail** tab lists mail sent during the run (`MessageSending`): to, subject, HTML, text, and attachment names.
- **Why.** Developing emails and Blade output without sending mail or opening routes. It is a headline Tinkerwell feature.
- **Fit.**
  - The runner renders only these known types, and only when "Render previews" is on (default on). Rendering is what returning a mailable means, but it does run view code, so its queries show up in N01.
  - It emits `record(category: "html")` with HTML capped at about 2 MiB.
  - The preview is a `WKWebView` with `allowsContentJavaScript = false` and a `WKContentRuleList` that blocks every non-`data:` load. "Load remote images" is a per-preview toggle, because emails contain tracking pixels.
  - The mail listener lives in `LaravelDriver::instrument`. Optional per-target "Intercept mail" (the `array` mailer) is shown as a chip; it is also part of safe mode (§3.13).
- **Risks.** Rendering executes view code, so keep it off for production targets unless asked. No JavaScript, no network.

### N04 · Output export leftovers

- **What.** Table row context menu: Copy Row as JSON, Copy Row as PHP Array (keys kept). Copy Output as Markdown (fenced blocks; cards as headings). Run ▸ Save Output As… (`.txt` or `.md`). URLs in Plain and Raw output become links.
- **Why.** Tinkerwell parity (Detail Dive row copy, 5.11 Markdown, 3.18 save to file, 5.4.1 links). This was B12 in the earlier review and was not built.
- **Fit.** `ValueTableView` and `OutputPane.swift`, `TabModel.outputText(for:)`, new registry commands in `Commands.swift`, and `NSDataDetector` for links.
- **Risks.** None.

### N19 · Stateful REPL in the terminal

Issue: [#32](https://github.com/filipac/runlet/issues/32) · P3 · S · deferred

**Audit status:** Implemented 2026-10-03 in [#32](https://github.com/filipac/runlet/issues/32) (see the table above). Instead of a synthetic `ProjectCommand`, `ProjectREPL` builds the terminal request beside `ProjectCommandLauncher`, and the REPL is chosen by the project's files (Tinker, else PsySH, else `php -a`).

- **What.** The Commands pane gets "Open REPL": `php artisan tinker` or psysh in a terminal tab on the target, for state between runs.
- **Fit.** `ProjectCommandLauncher` with a synthetic command.
- **Risks.** None; it's the user's own REPL.

**Acceptance:** Offer Open REPL in the Commands pane, opening the target's own tinker/psysh session only on request.

### N37 · Tests group in the Commands pane

Issue: [#40](https://github.com/filipac/runlet/issues/40) · P3 · S · deferred

**Audit status:** Implemented 2026-10-03 in [#40](https://github.com/filipac/runlet/issues/40) (see the table above). Instead of driver `ProjectCommand` groups from the runner's Composer-scripts reader, `ProjectTests` builds the terminal request beside `ProjectCommandLauncher`, like Open REPL (N19), so the group works without listing (which boots the application) and on every target. The runner is chosen by the project's files: `php artisan test` (needs Collision, Pest or PHPUnit, and `phpunit.xml` or `phpunit.xml.dist`), else Pest, else PHPUnit (with `phpunit.xml`, `phpunit.dist.xml`, or `phpunit.xml.dist`). Tests are disabled on production targets rather than confirmed, since suites often reset the database.

- **What.** Detect Pest or PHPUnit (`vendor/bin/pest`, `vendor/bin/phpunit`, `artisan test`). Run all, a file, or `--filter` (`needsInput`) in a terminal tab.
- **Fit.** The Composer-scripts reader in `Runner.php`, `ProjectCommand` groups.
- **Risks.** None.

**Acceptance:** Detect Pest/PHPUnit/Artisan tests and offer all/file/filter launch actions in terminal tabs on the chosen target.
### N26 · App info panels

Issue: [#19](https://github.com/filipac/runlet/issues/19) · P2 · M

**Audit status:** Implemented 2026-10-03 in [#19](https://github.com/filipac/runlet/issues/19) (see the table above). `artisan about` is read in-process from the command's data provider (no Artisan or Composer process), Symfony and WordPress get small built-in sections, and a PHP section comes with every target. Secrets are redacted by key and by value, in the runner and again in the app.

- **What.** Clicking the framework chip (status bar or tab card) opens an "App Info" popover. Laravel shows `artisan about --json` (environment, debug, cache, and drivers). A driver can add `panels(): array` of sections with key/value rows. It loads only on click, because it boots the app.
- **Why.** Tinkerwell has panels (`appPanels()`, `.tinkerwell/panels`), and it helps you check the environment before you run.
- **Fit.** Runner `mode: "panels"`, like `mode: "commands"` (`ProjectCommands.swift`). A popover view.
- **Risks.** Boots project code, so only on click, and production profiles confirm (the archived SSH production/safe-mode design).

**Acceptance:** Load driver-defined App Info panels only on click, with production confirmation and bounded key/value sections.

### N33 · Keyboard-first History and Snippets, history in ⌘P

- **What.** ⌘Y and ⇧⌘L focus the search field. ↑ and ↓ move the selection, Return loads into the current tab, ⌘Return opens a new tab, and ⇧Return inserts at the cursor. History appears in ⌘P behind a `!` prefix.
- **Why.** Tinkerwell's history and snippets are keyboard-driven. This was B06 in the earlier review and is still open.
- **Fit.** `LibraryInspector.swift` (`onKeyPress`), and the `Palette.swift` and `PaletteQuery` prefixes.
- **Risks.** None. It loads code only.

### N39 · `runlet` CLI, file watching, Dock recents, pinned window

- **What.**
  - Settings ▸ Install Command-Line Tool. `runlet [dir|file|workspace]` opens a project tab for a directory; a file or workspace opens as today. This is B11.
  - File-backed tabs reload silently when unchanged and offer "Reload / Keep Mine" when edited. ⌘S never overwrites a newer file. This is B13.
  - The Dock menu lists recent projects.
  - Window ▸ Float on Top.
- **Why.** Tinkerwell parity: the CLI helper, Dock recents (3.5), and Watch File.
- **Fit.** `AppDelegate.open(_:)` handles directories. `NSFilePresenter` or `DispatchSource` for file tabs. `applicationDockMenu`. `NSWindow.level`.
- **Risks.** The CLI install needs admin rights for `/usr/local/bin`; offer `~/.local/bin` with instructions.

### N11 · Magic comments

Issue: [#10](https://github.com/filipac/runlet/issues/10) · P1 · L

**Status:** Done in [#10](https://github.com/filipac/runlet/issues/10) (2026-10-03). The shipped design follows this proposal; differences: hits are `inline` events of their own (not inspector records), so they show whether or not the run inspector is on, and placements where a call would change the code are refused with a reason. See [compatibility.md](compatibility.md#magic-comments-10).

- **What.**
  - `//?` at the end of a line shows that line's value. `/*?*/` inside an expression shows the intermediate value. `/*?->count()*/` shows a projection without changing the chain. `/*?.*/` shows the elapsed time at that point.
  - Values appear as dim inline text after the line. Hovering shows the full value tree.
  - Repeated hits (loops) show `×N`, the last value, and a list.
  - Values stream in while the code runs; Tinkerwell requires buffered output. Highlight magic comments in the editor (Tinkerwell 4.17).
- **Why.** Tinkerwell's signature feature. Inspect without adding `dump()` calls or temporary variables.
- **Fit.**
  - `SnippetCompiler` finds magic comments with the tokenizer and parser, and wraps the target expression by **inserting text at byte offsets**: `\RunletRunner\Probe::at(<id>, <expr>)`, or `->tap()`-style for `/*?->x()*/`.
  - It doesn't pretty-print, because the bundled php-parser omits the printers (`scripts/build-runner.php`), and because offset insertion keeps line numbers.
  - `Probe::at` emits `record(category: "inline", id, line, value)` with a small depth limit.
  - `EditorController` draws ghost text after the line end (custom drawing in the layout-manager pass, next to the diagnostics underlines). `LineNumberRulerView` gets a hit marker. Values map through `RunRequest.editorLine(forSnippetLine:)`, so Run Selection works.
- **Risks.**
  - Inserting into expressions must not change evaluation order or reference semantics. Fixture-test against `&$x`, `static fn`, named arguments, and nullsafe chains.
  - Projections (`->count()`) are user code and may run queries; that is expected.
  - Cap the events per probe (for example the first 100 hits, then counts only).

**Acceptance:** Support all documented magic-comment forms, streaming inline values, loop hit counts, and selection mapping without changing PHP evaluation order/reference semantics.

### N14 · Production guard: detect application environment and mark history

Issue: [#12](https://github.com/filipac/runlet/issues/12) · P1 · S–M

**Status:** Done in [#12](https://github.com/filipac/runlet/issues/12) (2026-10-03), completing N14 with the core guard above. Decisions: production names are `production`, `prod`, `prd`, and `live` (whole name, any case); the reverse case (a production target whose app says `local`, `development`, or `dev`) is an informational note with Dismiss only; dismissals are kept per target in `facts.json`; WordPress reports `production` when `WP_ENVIRONMENT_TYPE` isn't set, as WordPress itself does. See [ssh.md](ssh.md#production-hosts) and [compatibility.md](compatibility.md#application-environment-and-production-history-12).

**Audit status:** Partial: per-target environments/colors, red badges, confirmations, snippet-only grace and stricter command defaults are implemented.

Only the bootstrapped environment detection / Mark as production banner and historical production-run marking remain. Store a run-time environment snapshot so editing a target later does not relabel old runs.

**Acceptance:** Report the application environment in the bootstrapped protocol, offer Mark as production when appropriate, and persist/display the environment of a historical run as a snapshot.

## Implemented MVP additions from the older review

The earlier B01–B13 review is superseded by [tinkerwell-feature-review.md](tinkerwell-feature-review.md). Delivered scope: command registry/palette and Open Anything, shortcut remapping, reopen/close-right/numbered tab commands, project snippets, keyboard-first library, strict types, layout commands, typography/wrap, external-editor links, CLI, output export, and file watching. Evidence is in the corresponding CHANGELOG entries and app/package sources. B04 close confirmation and B05 snippet-folder watching remain tracked separately. B06 personal descriptions are now implemented in [#52](https://github.com/filipac/runlet/issues/52).

Completed plan.md nice-to-haves: tables/search/sort/CSV, core SQL and HTML/mail inspection, project snippets, palette, streamed real-time output, shortcut remapping, colors/recents, close-right and watched files, output export, ligatures/appearance/pinning, sandbox reset, terminal/IDE links, framework-driver SDK, non-Laravel SQL tracing, and SSH/remote Docker. They are no longer an active post-MVP backlog.

## Historical Tinkerwell gap comparison

This comparison predates reconciliation and is retained as research context. Status claims in this historical table are superseded by the evidence above and the issue index. In particular SSH, connection colors, remote Docker, CLI, export, and previews are implemented.


**Have:** Runlet has it. **Partial:** some of it. **No:** missing. Tinkerwell sources: [v5 docs](https://tinkerwell.app/docs/5/getting-started/about) unless a row cites the changelog (`cl x.y`) or `plan.md`'s inspection of the installed app.

### Getting started and settings

| Tinkerwell feature | Runlet | Notes |
| --- | --- | --- |
| macOS, Windows, and Linux apps | Partial | macOS only, by design. |
| PHP auto-detection, Herd and Homebrew paths | Have | `PHPDiscovery` searches PATH, Herd `phpXY` shims, and Homebrew. |
| Language server needs local PHP 8.1+ | Better | PHPantom is native, so completion works with no host PHP. |
| Layout: output right or below (⌃.) | Have | `output.swapPosition`. |
| Themes | Partial | System, Light, or Dark only; syntax colours are fixed (N32). |
| Font, size, ligatures, line height | Have | — |
| Auto evaluate (on by default in Tinkerwell; off on SSH) | Opt-in | Off by default; sandbox tabs may explicitly enable auto-run ([#30](https://github.com/filipac/runlet/issues/30)). Never persisted or available for local/Docker/SSH targets. |
| Default project instead of the sandbox | Have | — |
| Forge API key, site sync | No | N24, after SSH. |
| OpenAI and other AI provider keys | No | AI was excluded from the MVP. AI ideas are an optional group (N44–N47). |
| PhpStorm plugin | No | Skip (§5). The `runlet` CLI and URL scheme (N35, N39) cover "send code to Runlet". |

### Setup guides (targets)

| Tinkerwell feature | Runlet | Notes |
| --- | --- | --- |
| Laravel sandbox | Have | Pinned Laravel 13.34, reset, Docker fallback. Tinkerwell updates its sandbox with each release. |
| SSH connections: label, folder, keys, passphrase, password, agent, 1Password | No | §3. |
| SSH ProxyJump (bastion) with `~/.ssh/config` import (cl 5.11, 5.12) | No | §3. The system `ssh` handles ProxyJump with no extra code. |
| Connection colours, coloured status bar (cl 2.21, 5.14) | No | N14. |
| Sail | Have | Through Docker profiles (non-root user). N22 adds presets. |
| Homestead (SSH into the VM) | No | §3 covers it as a plain SSH host. |
| Docker: pick a running container, detect the working directory | Have | Profiles with Compose identity, recreation handling, and a probe. |
| Custom `docker exec` flags (cl 5.10) | Partial | User, workdir, tmp, and PHP fields exist; free-form flags don't. N21. |
| Custom Docker tmp directory (cl 5.14) | Have | — |
| Docker auto-connect (cl 4.20, 5.10) | Have | `autoResolve`. |
| Docker over SSH (cl 4.0) | No | §3: the remote-container step. |
| DDEV, Lando, Warden | Have | Generic Docker. N22 adds presets. |
| Kubernetes: contexts, searchable pods, custom kubeconfig, remote over SSH | No | N23 (P3). |
| Laravel Vapor | No | Skip (§5). |
| Laravel Cloud | No | Skip (§5). |
| WSL2 | No | Skip (Windows). |
| Completion: indexing, fuzzy matching, chains | Have | PHPantom. |
| Remote completion via a local checkout | Partial | Docker `localSourcePath` with bind-mount detection; SSH in §3.10. |
| Laravel magic methods through IDE Helper | Have | PHPantom infers Laravel without IDE Helper (see `compatibility.md`). |
| Reindex from the status bar | Have | Restart Language Server. |
| AI completion (OpenAI, Anthropic, Mistral; on typing, idle, or demand) | No | N47 (optional). |

### Basic usage

| Tinkerwell feature | Runlet | Notes |
| --- | --- | --- |
| Run (⌘R), run selection | Have | Plus a separate Run Selection and a "prefer selection" setting. |
| Built-in frameworks: Craft, Drupal 7/8, Kirby, Laravel, Laravel Zero, Magento 1/2, Moodle, October, PrestaShop, Statamic, TYPO3, WordPress, plus Symfony, Shopware, Lumen, Testbench, Radicle in the public repo | Partial | Runlet has Laravel, Lumen, Laravel Zero, WordPress (including Bedrock), Symfony, Composer, and plain PHP. Statamic probably works through Laravel (guess). N25. |
| "No framework detected" notice (can be disabled) | Partial | The status bar shows "Composer" or "Plain", with no explicit notice. |
| Detail Dive cards, expansion preference | Have | — |
| CLI mode | Have | Plain mode, plus Raw. |
| Table view, CSV export | Have | Sort, filter, Copy CSV, Export CSV. |
| Copy a table row as JSON or a PHP array | Have | N04: row context menu (JSON, PHP array, CSV). |
| Graph view | No | Skip (§5). |
| HTML view of views, mailables, `MailMessage`; rerun refreshes it | Have | N02: previews in result and dump cards; Run refreshes them. Plus mail capture and interception. |
| SQL query inspection (Laravel, WordPress; SQL Server since cl 4.13) | Have | N01: Laravel, Eloquent without Laravel, Doctrine DBAL 2–4, WordPress, opt-in PDO; any database those layers drive. |
| `dump`/`dd` file links open in an editor (VS Code, PhpStorm, Sublime, TextMate, Nova, Zed, BBEdit) | Have | PhpStorm, VS Code (and variants), Cursor, Zed, Sublime, TextMate, and a custom command (covers Nova and BBEdit). |
| Tabs: ⌘T, ⌘W, ⌘1–9, ⌃Tab, ⌥⌘←/→, ⌘PgUp/PgDn | Partial | ⌘1–9 and ⇧⌘[ ] work; ⌃Tab and ⌥⌘←/→ don't. N32. |
| Rename, duplicate, close others, close to the right, middle-click close (cl 3.23, 4.20) | Partial | Everything but middle-click. |
| Ask before closing a tab (cl 2.24) | Partial | Runlet offers Reopen Closed Tab (⇧⌘T) instead. |
| Open Anything with `#`, `/`, `@`; fuzzy search across history too (cl 5.0.2) | Have | Palette with `#`, `/`, `@`, `>`, and `!` (history, current project first). Done (N33). |
| History: ⌘Y, arrow keys, Return (current tab), ⌘Return (new tab), configurable size | Have | Panel with search, project scope, dedupe, and a limit; ⌘Y focuses the search, ↑/↓, ↩ (per setting), ⌘↩, ⇧↩ insert. Done (N33). |
| Create a snippet from history | Have | — |
| Personal snippets: labels, edit, keyboard | Have | ⇧⌘L focuses the search; same keys as History (N33). |
| Snippets bound to a connection or folder, filter by it (cl 3.8) | Partial | A target is stored and used by "Open in New Tab". |
| Project snippets in `.tinkerwell/snippets` with `@label`/`@description` | Have | `.runlet/snippets`. N34 adds a `.tinkerwell` fallback. |
| Dynamic snippets from drivers (cl 3.3, deprecated in 3.31) | No | N16 is the modern equivalent. |

### Advanced usage

| Tinkerwell feature | Runlet | Notes |
| --- | --- | --- |
| Custom themes (Monaco JSON in `~/.config/tinkerwell/themes`) | No | N32 adds built-in themes. Skip the Monaco format (§5). |
| Remappable shortcuts | Have | — |
| Prettify, plus format-before-run and quote style (cl 4.4, 4.14) | No | N31. |
| Toggle output, toggle toolbar, CLI-mode toggle | Have | ⌃⌘O, the system toolbar toggle, ⌃⌘1–3. |
| Toggle logs (⌘L), toggle AI chat (⇧⌘L) | No | N27 and N46. |
| Magic comments `//?`, `/*?*/`, `/*?->x()*/`, `/*?.*/` (timing); editor highlighting (cl 4.17) | Have | N11, [#10](https://github.com/filipac/runlet/issues/10). |
| Auto log and "live code coverage" (cl 3.0, homepage) | No | N12. |
| Collision errors, per-project `usesCollision()` | Partial | Runlet's own error cards show the stage, trace, and links, but no source excerpt. N07. |
| Project-specific PHP from the footer, aliases, remote PHP path | Have | Project Options; the footer isn't clickable. SSH PHP path in §3. |
| Log viewer: file dropdown, level filter, search, polling, framework defaults, driver log paths, nested folders | No | N27. |
| CLI helper `tinkerwell [path]` (macOS) | Have | `runlet [folder\|file\|workspace]`, `--target`, `--new-window`; Install Command-Line Tool…. Done (N39, [cli.md](cli.md)). |
| AI chat: providers, context toggles, `@` files, per-tab conversation | No | N46 (optional). |
| Xdebug "Toggle Debugging" (Herd only) | No | N13. |
| MCP server (`evaluate-local-php-code`, `evaluate-remote-php-code`, `get-remote-connections`, `get-snippets`, `add-snippet`) | Have | `runlet mcp` with six tools and an approval for every run. Done (N44, [mcp.md](mcp.md)). |

### Extending

| Tinkerwell feature | Runlet | Notes |
| --- | --- | --- |
| Project drivers in `.tinkerwell/*TinkerwellDriver.php` | Have | `.runlet/*Driver.php`, plus `commands()` and `hostCommands()`. |
| Global drivers (`~/.config/tinkerwell`, which win over local ones) | No | N25. |
| `getAvailableVariables()`, `appVersion()` | Have | `variables()` (also fed to completion) and `version()`. |
| `usesCollision()` | n/a | Runlet has no Collision. |
| `injectQueryLogging($code)` (public repo) | Better | `Driver::inspect(Inspector $inspector)`: queries, mail, logs, HTML, and custom sections. |
| `logFilesPath()` (public repo) | No | N27. |
| `appPanels()`, `.tinkerwell/panels/*Panel.php`, the Laravel "About" panel | Have | `panels(): array` and App Info (N26, [#19](https://github.com/filipac/runlet/issues/19)): the framework chip opens `artisan about`, Symfony, WordPress, and PHP details plus the driver's sections. |
| `appFiles()` for AI chat context (public repo) | No | N46 (optional). |

### Troubleshooting, distribution, and other changelog items

| Tinkerwell feature | Runlet | Notes |
| --- | --- | --- |
| Config, log, and updater paths; settings reset | Partial | `State/` with last-good and corrupt copies. `Logs/` is unused, and there's no diagnostics export. N40. |
| Auto-updater | No | N40. |
| Recovery from corrupt settings (cl 5.8) | Have | `JSONDocumentStore`. |
| Strict-types toggle (cl 5.15) | Have | Plus per-target overrides. |
| Copy as Markdown (cl 5.11), save output to a file (cl 3.18) | Have | N04. |
| Real-time vs. buffered output (cl 2.14) | Have | Always streams. |
| Time, memory, and start time in the footer (cl 3.21, 4.6) | Partial | Elapsed time and peak memory; no bootstrap/execute split and no start time. N08. |
| PHP version in the footer for every target (cl 5.10) | Have | — |
| Import `use` statements (cl 4.14) | Have | Completion edits; no code action yet (N30). |
| Indentation guides (cl 5.2) | No | N32. |
| HEREDOC highlighting (cl 4.11) | Partial | Approximated. |
| Links in CLI output open in the browser (cl 5.4.1) | Have | N04. |
| Multi-cursor (cl 3.22) | No | No dedicated commands. N32. |
| Recent folders in the Dock menu (cl 3.5) | Have | The Dock menu lists recent projects (local and Docker). Done (N39). |
| Recent connections (cl 5.0.2) | Have | The palette sorts targets by `lastOpenedAt`. |
| Auto-hide output, Esc hides it (cl 3.6) | Have | Opt-in: hide the output pane until a run, and Escape hides it (DOC11, [#60](https://github.com/filipac/runlet/issues/60)). |
| Custom Carbon caster (cl 3.8) | No | N05. |
| Herd integration: site actions, `herd tinker`, Herd `php.ini` | Partial | Herd PHP is discovered; there's no per-site isolation. N22. |
| Tinkerwell Wrapped (cl 5.7) | No | Skip (§5). |

## 3. SSH targets — design proposal

Historical design moved from the active ideas file because SSH-1 through SSH-7 are implemented. It includes proposed optional behavior for context; SSH-8/SSH-9, environment detection, and History marking are **not completed** and are tracked in the issue links above. The current behavior is documented in [ssh.md](ssh.md). The changelog and code supersede this proposal, including the newer opcode cache and quit behavior.


### 3.1 Requirements from the user

| Area | Requirement |
| --- | --- |
| Server types | (a) Plain SSH hosts from `~/.ssh/config`, including jump hosts. (b) Docker on a remote host: SSH to a server, then `docker exec` into a container there. Model (b) as an SSH profile with an optional remote-container step. It reuses the Docker profile ideas: Compose project and service labels, an explicit choice when the container is ambiguous, and never switching containers silently. Forge, Ploi, and Kubernetes are later options only. |
| Authentication | ssh-agent and the 1Password SSH agent, key files in `~/.ssh`, and **interactive password and 2FA prompts**. Runlet never handles or stores the secret. |
| Production | A per-profile production flag with a red badge on the tab card and target menu, a confirmation before each run (with "don't ask again for 10 minutes"), and stricter defaults: nothing auto-loads or auto-runs code, including the Commands pane and facts detection. An optional read-only or safe mode, documented honestly: PHP writes can't truly be prevented. |
| Local project per host | Every SSH profile, and its optional container step, has a **local source folder on this Mac**, like Docker's `localSourcePath`. It is first-class (§3.10): it powers completion, path mapping, drivers and facts, snippets, host commands, the editor, and the terminal. Runlet suggests a folder automatically and can warn about branch or commit drift. Without a folder, the profile works in limited mode. |

### 3.2 What Tinkerwell documents about SSH

| Topic | What the docs say | Source | Runlet design |
| --- | --- | --- | --- |
| Creating connections | Open from the toolbar or Action ▸ Connect via SSH. Fields: label, remote host info, and the remote application folder. You can "preload existing connections". The footer shows `SSH - <label>`. Clicking the icon again disconnects. | v5 and v2 SSH pages | A profile with a host alias, directory, PHP, optional container step, and local folder. A tab card chip and status-bar label. |
| Key auth | Private key file with a passphrase field ("for password-protected keys, not server passwords"). The private and public key must be in the same folder. | Troubleshooting | Key files are used through `ssh` itself; Runlet never reads key files. |
| Password auth | The WSL2 guide connects with "Authentication: Password-based". `plan.md` saw password fields in the installed app. | WSL guide | Interactive login in a terminal tab that sets up a ControlMaster (§3.6). |
| ssh-agent and 1Password | Agents are supported. You must select **any** key file so the agent is triggered. Needs `SSH_AUTH_SOCK` and `IdentityAgent` in `~/.ssh/config`. `IdentityFile` must be an absolute path (no `~`), and the setting must be spelled `HostName`. The blog says 1Password works only with ED25519 keys. | v5 SSH page, blog | Works with no special handling, because OpenSSH reads the config and talks to the agent. |
| Jump hosts | ProxyJump (bastion) support, "auto-imported" from `~/.ssh/config` (5.11). Config changes are detected without a restart (5.12). | Changelog | OpenSSH applies `ProxyJump` from the config. An optional `-J` override per profile. |
| PHP binary | Remote runs use the `php` alias by default; a path or alias can be set per connection. Compound paths and paths with spaces were fixed in 5.13 and 5.14. | Project-specific PHP, changelog | `phpExecutable` per profile and per container step, with the probe listing candidates. |
| Project path | You must select the correct remote application folder. Forge zero-downtime deployments are detected, and Tinkerwell offers to switch to the `current` symlink (5.8). | v5 SSH page, changelog | `remoteDirectory`. The probe resolves symlinks, and path mapping accepts both the `current/` path and the resolved `releases/<id>/` path (§3.10). |
| Forge | A Forge API key in settings imports the sites you can connect to. Moved to Forge API v2 in 5.17; the token needs the `server:view` scope. | Settings, v2 docs, changelog | Later (N24). |
| Ploi | No documented integration found. | Search | Later (N24). |
| Vapor and Laravel Cloud | Separate runtimes, not SSH: `vapor.yml` with `vapor env:list` (dump only, no return values), and an API token for Cloud. | Setup guides | Out of scope (§5). |
| Per-connection settings | Label, colour (the palette's `@` lists "connections with custom colors"; coloured status bar in 2.21; colour kept in tabs in 5.14), duplicate (2.21), PHP path, local project path for completion, Kubernetes config path, and a "custom path for Tinkerwell data in remote connections" (3.15). | Various | Production flag, colour, PHP, local folder, container step, safe mode, drift check. |
| Docker over SSH | Connect via SSH, then pick the PHP container as you would locally (4.0). | Docker guide, changelog | The remote-container step (§3.7). |
| How code gets there and runs | **Not documented.** Guess: Tinkerwell uploads support files to a remote data directory and runs the remote PHP in the app folder. Evidence: the 3.15 "custom path for Tinkerwell data" item, and `plan.md`'s "temporary upload location". | — | Runlet streams the runner to `php` on stdin; nothing is written on the server (§3.7). |
| How output comes back | **Not documented for SSH.** A global real-time vs. buffered setting exists (2.14), and magic comments need buffered output. | — | Same nonce-framed event protocol over the SSH channel's stdout, with stderr kept separate. |
| Timeouts | **Not documented.** | — | Connect 10 s, keep-alive 15 s × 3, listings 120 s, probes 10–15 s (§3.5). |
| SSH implementation | **Not documented.** Guess: a built-in SSH library, not the system `ssh`. Evidence: a dummy key file is needed to trigger the agent, ED25519 only with 1Password, absolute `IdentityFile` paths, and the exact `HostName` spelling. | — | The system `/usr/bin/ssh` (§3.5). |
| Safety | "Auto evaluation is disabled on SSH connections" to avoid harming production. | v5 SSH page, settings | Runlet never auto-runs SSH targets. Sandbox tabs have a separate per-tab opt-in ([#30](https://github.com/filipac/runlet/issues/30)). Production profiles add confirmation and guard rails (§3.13). |
| AI and MCP | `evaluate-remote-php-code` and `get-remote-connections`. The MCP server establishes SSH connections automatically. | MCP page | Runlet's MCP server (N44, [mcp.md](mcp.md)) never opens a connection without in-app approval. |

### 3.3 Design overview

```text
Tab ─► TargetRef.ssh(id) ─► AppModel.snapshot(for:) ─► TargetSnapshot(kind: .ssh, ssh: SSHEndpoint, [container…])
                                                            │
ExecutionEngine.prepare(target:) ── .ssh ──► SSHExecAdapter ─┤ plain host:   ssh -T … host -- /bin/sh -c 'cd DIR && export RUNLET_RUN_ID=… && exec PHP -d …'
                                                            └ container:    DockerCLI(transport: .ssh) → DockerExecAdapter (unchanged)
stdin: RunnerBundle.script(…)   stdout: nonce frames + raw output   stderr: raw stderr   Stop: ssh … php -r signalHelper
Local folder on this Mac ─► PHPantom workspace, TargetInspector.staticFacts, .runlet/snippets, hostCommands(), editor links, terminal
```

**Key decision: use the system OpenSSH client (`/usr/bin/ssh`), not an SSH library.** This gives the following for free, exactly as the user's terminal behaves:

- `~/.ssh/config`, including `Include`, `Match`, `ProxyJump`, and `ProxyCommand`;
- ssh-agent, the 1Password agent (approval prompts appear in 1Password's own UI), and hardware keys;
- `known_hosts` and `ControlMaster` multiplexing;
- macOS `UseKeychain` for key passphrases.

Runlet stores no keys and no passwords, and holds no crypto code. The cost is handling the remote shell and argument quoting carefully (§3.5).

### 3.4 Data model (`Packages/RunletKit/Sources/RunletCore`)

```swift
// Models.swift
public enum TargetRef { case sandbox, local(UUID), docker(UUID), ssh(UUID) }   // stableKey "ssh:<uuid>"

public struct SSHProfile: Codable, Hashable, Identifiable {
    var id: UUID; var name: String
    var host: String              // ~/.ssh/config alias or hostname, passed to ssh unchanged
    var user: String?; var port: Int?; var jumpHost: String?   // nil = whatever ssh config says
    var remoteDirectory: String   // absolute; may be a symlink (…/current)
    var phpExecutable: String     // "php"; validated like DockerProfile (no leading "-", no control chars)
    var container: RemoteContainerStep?   // optional docker exec step on the host
    var localSourcePath: String?          // first-class, §3.10
    var languagePHPVersion: String?; var strictTypes: Bool?
    var environment: TargetEnvironment    // .development / .staging / .production (N14), plus a colour
    var safeMode: SafeModeOptions?        // §3.13, optional
    var checkDrift: Bool                  // §3.10, off by default
    var compression: Bool                 // ssh -C, on by default (§3.14)
    var revision: Int; var lastOpenedAt: Date?
}

public struct RemoteContainerStep: Codable, Hashable {
    var identity: ContainerIdentity       // same type as Docker profiles: Compose project/service, name, last ID/image
    var workingDirectory: String; var phpExecutable: String
    var user: String?; var temporaryDirectory: String
    var dockerCommand: String             // "docker", or "sudo -n docker" (passwordless sudo only)
}
```

- `TargetLibrary` gains `sshProfiles`, with `strictTypes(for:global:)` and `localSourcePath` lookups like Docker's.
- `RunProtocol.swift`: `TargetSnapshot.Kind` gains `.ssh`. The snapshot gains an optional `ssh: SSHEndpoint` (host, user, port, jump, control path, compression, and the resolved real directory). The existing `containerId`, `containerName`, `image`, `user`, and `temporaryDirectory` fields carry the container step. All additions are optional Codable fields, so `runProtocolVersion` stays at 1.
- `Workspace.swift`: `WorkspaceTarget.ssh(SSHDefinition)` holds the host alias, directory, PHP, container identity, and the local folder as a relative path. Workspace files then name hosts; note this in the save dialog, since host names are infrastructure details even though they aren't secrets.

### 3.5 Transport: how Runlet calls `ssh`

- **New file `RunletExecution/SSH.swift`.** `SSHEndpoint.arguments(for: .run | .control | .interactive)` builds the argv, and `RemoteShell.script(_:)` POSIX-quotes words using the same rules as `ProjectCommandLauncher.shellQuote`.
- **Options on every non-interactive call:**
  - `-o BatchMode=yes` (never prompts) and `-o StrictHostKeyChecking=yes` (never accepts an unknown key);
  - `-o ConnectTimeout=10`, `-o ServerAliveInterval=15`, `-o ServerAliveCountMax=3` (a dead link ends a run with a transport error after about 45 s instead of hanging);
  - `-S <controlPath>`, plus `-o ControlMaster=auto -o ControlPersist=10m` for key or agent profiles, or `ControlMaster=no` for profiles that must log in interactively (§3.6);
  - `-T`, `-C` when compression is on, `-J` only when the profile overrides it, and `-o LogLevel=ERROR` to keep banners out of the run's stderr (verify that it suppresses the pre-auth banner).

  Runlet never passes `-F`, so the user's config always applies.
- **Remote command.** The command is always `/bin/sh -c '<script>'`. The script is POSIX `cd <dir> && export RUNLET_RUN_ID=<uuid> [TMPDIR=…] && exec <php> -d display_errors=stderr -d html_errors=0 -d log_errors=0`, with every word quoted. `ssh` joins its arguments into one string for the user's login shell. Wrapping everything in single quotes for `/bin/sh` works in bash, zsh, fish, and dash. csh and tcsh login shells need testing (risk: `!` history expansion).
- **Control socket.** `~/Library/Application Support/Runlet/SSH/<first 8 hex of profile id>.sock` (a new `AppPaths.ssh`), in a 0700 folder. A short name matters because macOS limits Unix socket paths to 104 bytes, and OpenSSH's `%C` hash (40 characters) would push long home paths past it. Use `ssh -O check` for status and `ssh -O exit` for Disconnect.
- **Listing hosts.** Parse `Host` lines without wildcards from `~/.ssh/config`, following `Include`. For each alias, `ssh -G <alias>` (which makes no connection) shows the effective `hostname`, `user`, `port`, `proxyjump`, and `identityagent` read-only in the form. The list is re-read whenever the profile editor opens, so no restart is needed (Tinkerwell 5.12 parity).
- **Exit-code mapping.** Mirror `CHANGELOG` "Clearer launch failures for Docker profiles". `ssh` exit 255 plus stderr gives plain-language reasons:
  - "Host key verification failed" leads to Connect…;
  - "Permission denied" leads to "not logged in; Connect…";
  - "Could not resolve hostname" and "Connection timed out" are network problems;
  - "Control socket connect … No such file" means the login expired; Connect… again.

  A `cd` failure means the directory is missing on the host. Exit 127 means PHP is not on that path.

### 3.6 Authentication, host keys, and connection status

| Method | How it works | User experience |
| --- | --- | --- |
| ssh-agent, 1Password, key files without a passphrase, `UseKeychain` | `BatchMode=yes` succeeds, and the first run opens a ControlMaster by itself (`ControlMaster=auto`). | Nothing to do. 1Password shows its own approval prompt; ControlPersist keeps later runs prompt-free for 10 minutes. |
| Password, keyboard-interactive or 2FA (OTP, Duo), key passphrase not in an agent | A **Connect…** action opens a terminal tab (the existing `TerminalPanel` and `TerminalRequest` with an `executable` argv) running `ssh -M -S <ctl> -o ControlPersist=<N> -N -f <host>`. The user types the password or code **into OpenSSH**. Once authenticated, `-f` backgrounds the master, the tab shows "exited 0", and Runlet marks the profile connected. Runs then use `-S <ctl> -o ControlMaster=no -o BatchMode=yes`. | A **Connect** button in the profile and a banner on the tab ("Not connected to app-prod. Connect…"). When the master expires or the network changes, the next run fails fast with the same banner. Disconnect sends `ssh -O exit`. |
| Unknown or changed host key | Every non-interactive call refuses (`StrictHostKeyChecking=yes`). Connect… is the only place a host key can be accepted, and the user answers OpenSSH's own fingerprint prompt in the terminal. | A clear "Verify host key" banner. A *changed* key shows OpenSSH's warning verbatim, and Runlet offers nothing to bypass it. |

**Password and 2FA: the two options considered.**

- **A. Interactive ControlMaster login in a Runlet terminal tab (recommended).**
  - OpenSSH handles every prompt type: password, multi-step keyboard-interactive, OTP, passphrase, host key, and FIDO touch messages.
  - The secret passes from the keyboard through the pty to `ssh`, exactly as in Terminal.app. Runlet never parses, stores, or logs it.
  - It reuses the terminal panel, which already handles command tabs and exit status.
  - Cost: the user re-authenticates when the master expires. Make `ControlPersist` configurable per profile (default 10 minutes; offer "until Disconnect").
- **B. `SSH_ASKPASS` helper with a native prompt.** Set `SSH_ASKPASS_REQUIRE=force` and point `SSH_ASKPASS` at a bundled helper that asks the app for a secure-field dialog.
  - Nicer UI, but the secret does pass through Runlet's processes (the dialog, IPC, and the helper's stdout). That breaks the "never handles the secret" requirement.
  - Host-key yes/no questions also go through askpass, which invites a reflexive "yes".
  - It still needs ControlMaster to avoid prompting on every run, and it needs a separately signed helper plus IPC.
  - **Not recommended.** Reconsider only if users find the terminal flow awkward. Even then, never offer "save password".

**Connection status.**

- `ssh -O check` reports Connected, Not connected, or Expired in the profile list and on the tab card.
- Runlet never opens an SSH connection at launch or when tabs are restored. The first connection happens on an explicit action: Run, Test Connection, Connect, List Commands, or Shell.
- This also avoids a surprise 1Password prompt every time the app starts.

### 3.7 Running code and streaming output

- **Plain host.** `SSHExecAdapter.prepare(target:runId:script:)` sits next to `DockerExecAdapter` in `ExecutionEngine.swift`. It builds the argv from §3.5 and returns `PreparedLaunch(spec:stop:)`. Its `ProcessSpec` has `standardInput: script`, which is the unchanged `RunnerBundle.script(…)` (the 826 KB `dist/runlet-runner.php` plus the request).
  - The runner arrives on stdin, as it does for local and Docker runs, so **nothing is written on the server**. Read-only homes and project folders work.
  - `RunSession` and `FrameDecoder` are unchanged. `ssh -T` keeps stdout and stderr on separate channels, so framing, raw output, the 8 MiB cap, and the single `finished` event behave as they do locally.
  - Text that a login script prints (a `.bashrc` that echoes) arrives as raw stdout. It is visible but harmless, because frames carry the nonce.
- **Docker on the host (container step).** Give `DockerCLI` a transport: `DockerCLI(transport: .local | .ssh(SSHEndpoint))`. Its `spec(arguments, stdin:)` then produces `ssh … host -- /bin/sh -c '<dockerCommand> <quoted args>'`.
  - Everything built on `spec` works unchanged over SSH: `runningContainers`, `inspect`, `DockerProfileResolver.resolve`, `probe`, `detectFacts`, `phpVersion`, `DockerExecAdapter.prepare`, and `stopInContainer`.
  - So the container step gets the same Compose identity, recreation handling, `ContainerChoiceSheet` for ambiguous replicas, and the re-check right before launch, without any of it being reimplemented.
  - Alternative considered: `DOCKER_HOST=ssh://host`. Docker's own SSH helper also uses the system `ssh`, but it can't share Runlet's control socket or Connect flow, so password and 2FA users couldn't use it. Rejected.
  - The remote user needs Docker access. `dockerCommand` may be `sudo -n docker` (passwordless sudo only); `sudo` prompts can't work in BatchMode.
- **Snapshot.** `AppModel.snapshot(for:)` gains `case .ssh`. It requires a live control socket for interactive-auth profiles; otherwise it raises the "Connect…" banner through `TargetResolutionError`. It resolves the container step like `.docker` does (an ambiguous match raises a `ContainerChoice` and never runs) and records the real working directory from the probe.

### 3.8 Stop

- **Plain host.**
  - The runner reports its PID in `started`.
  - `ssh … -- /bin/sh -c '<php> -r <signalHelper> -- <pid> <runId> <sig>'` reuses `DockerExecAdapter.signalHelper`, moved to a shared `RemoteSignal`. Before signalling, it checks `/proc/<pid>/environ` for `RUNLET_RUN_ID=<runId>`, so a reused PID is never signalled.
  - The sequence matches Docker: SIGTERM, wait 1.5 s, SIGKILL, wait 3 s, then a signal-0 check.
  - Because the remote command ends in `exec php`, PHP should become the leader of the sshd session's process group. The helper can then confirm `pgrp == pid` in `/proc/<pid>/stat` and signal `-pid`, which also stops processes the snippet spawned. That is better than Docker today. Verify on Ubuntu, Debian, and Alpine hosts.
- **Container step.** `stopInContainer` runs unchanged through the SSH-transport `DockerCLI`. The container keeps running.
- **Limits.** Killing the local `ssh` client alone is not enough: without a pty the remote PHP doesn't reliably get SIGHUP, so the helper is required.
  - Hosts without `/proc` (BSD or macOS servers) report "Stop unconfirmed" instead of signalling unverified PIDs.
  - Forcing a pty (`-tt`) to get SIGHUP is rejected: it merges stderr into stdout and rewrites newlines, which would corrupt raw output.

### 3.9 Test Connection, probe, and facts (no project code)

- **Test Connection** runs `SSHProbe`, a `php -n -r` program like `ContainerProbe`, through the control socket. It reports:
  - PHP version and binary, plus other PHP binaries found (`/usr/bin/php8.*`, `php8.3`);
  - user and uid;
  - whether the directory exists and is readable, and its realpath (for Forge-style `current` symlinks);
  - the framework, from file checks;
  - whether the tmp directory is writable, and whether the tokenizer is available;
  - how Stop can signal (`posix`, `shell`, or `none`, and whether `/proc` exists);
  - candidate app directories (`~/*/current`, `/var/www/*`, `/home/*/*` containing `artisan` or `composer.json`);
  - `composer.json` `name`, and the git `remote.origin.url` and `HEAD` when drift checking is on.

  Nothing in the project runs: `-n` skips php.ini, and the code only reads files.
- **Facts** (`AppModel.detectFacts(for:)`):
  - With a local folder: `TargetInspector.staticFacts(projectRoot: local)`, read on this Mac with no network. Tab cards fill in immediately.
  - Without a local folder: the shared `detectFacts` PHP program (now `RemoteFacts.script`, used by Docker and SSH), run over SSH.
  - The remote PHP version is fetched only once a connection exists. For production profiles, only after an explicit Test Connection or the first confirmed run.
- **BatchMode everywhere** for probes, facts, listings, and Stop. No call except Connect… can show a prompt.

### 3.10 Local project folder per host (first-class)

**Where it lives.** `SSHProfile.localSourcePath` is one folder per profile, shared by the plain host and the container step. It maps to whichever runtime root the run uses: `remoteDirectory` (and its realpath) for a plain host, or the container's working directory for the container step.

**What it powers, and the code it reuses:**

| Feature | With a local folder | Without one (limited mode) |
| --- | --- | --- |
| Completion and diagnostics | `AppModel.languageWorkspace(for:)` returns `LanguageWorkspace(kind: .project, rootPath: local, phpVersion: languagePHPVersion ?? remote PHP from facts)`. The scratch URI `<root>/.runlet-scratch/tab-<uuid>.php` is never written, and `ScratchDocumentMapping` applies, as for local and Docker targets. | The `.basic` workspace. `DiagnosticFilter.visible(…, limitedWorkspace: true)` drops false "unknown symbol" diagnostics, and `LanguageWorkspace.sourceLimitations()` explains why ("Set a local folder for project completion"). |
| Driver variables in completion | The run's `bootstrapped.variables` become hidden `@var` lines, and their classes resolve against the local source (`$app`, or a project driver's `$_app`). | Only type names; members don't resolve. |
| Framework and driver facts | `TargetInspector.staticFacts` on the local folder (including `.runlet/*Driver.php` name and version literals). No network needed. | `RemoteFacts.script` over SSH, after connecting. |
| Project snippets | `AppModel.projectRoot(for:)` returns the local folder, so `ProjectSnippets` loads `.runlet/snippets/*.php` and "Save Snippet to Project…" works. | None. A later option is a read-only list from the server on explicit Refresh. |
| Host commands | `hostCommands()` run on this Mac in the local folder, through `HostCommandLister` and `HostShellEnvironment` (deploy scripts, `git pull`, the team's CLI). Declarations come from the last run or listing, as for Docker (`State/facts.json`). | Hidden, with the hint "needs a local folder". |
| Open Project in Editor | `AppModel.projectFolder(for:)` returns the local folder. | Disabled, with the reason. |
| Terminal | New shells start in the local folder (`AppModel+Terminal` working-directory logic). "+ ▸ Shell on <host>" opens the remote shell (§3.11). | New shells start in home. |
| File links in output | A new `EditorPathMapping` case, `.remote(roots: [remoteDirectory, realpath, container working dir], localRoot:)`, maps dump cards, error cards, and stack frames to local files, which open through `openInExternalEditor`. Forge-style releases: PHP reports *resolved* paths (`…/releases/2026…/app/…`), so the run's `started.workingDirectory` (a realpath) is added as a root, and both `current/` and `releases/<id>/` map to the same local file. | Plain text, with the reason "Set a local folder to open server files" (same pattern as Docker's unmapped message). |

**Suggesting a folder.** The profile form and Test Connection both suggest one. Like Docker's bind-mount `noteSourceSuggestion`, the suggestion is applied only with a click. Signals, strongest first:

1. The remote `git remote.origin.url`, normalized (`git@github.com:org/app.git` ≈ `https://github.com/org/app`), matched against local repositories in Runlet's known targets (local projects and Docker sources), recent folders, and a shallow scan of common roots (`~/Code`, `~/Projects`, `~/Sites`, `~/Herd`) that reads only `.git/config`.
2. `composer.json` `name` matched against local `composer.json` files.
3. The directory name: the remote basename, or the site folder for `/home/forge/<site>/current`.

**Drift warning (optional, off by default; `checkDrift`).**

- Off by default because it runs `git` on the server. When on, Runlet runs `git -C <dir> rev-parse --abbrev-ref HEAD` and `git -C <dir> rev-parse HEAD` over SSH after each connect, and compares them with the local folder.
- Deployments without `.git` (zero-downtime releases) fall back to comparing `sha1_file('composer.lock')` remotely (`php -n -r`) with the local copy.
- The result is a yellow banner: "Local checkout `feature/x` @abc123 differs from the server `main` @def456. Completion and file links may not match." It never blocks a run.

### 3.11 Drivers, project commands, host commands, terminal

- **Drivers work unchanged on the server.** The runner reads `.runlet/*Driver.php` from the **remote** working directory, so drivers that are committed or deployed just work. This includes `commands()`, `variables()`, and the declarations from `hostCommands()`.
  - Gap: a `.runlet/` folder that is git-ignored and exists only locally (the documented global-ignore case) isn't on the server.
  - Option (SSH-9): "Send local `.runlet` drivers with each run". The request carries the driver sources; the runner `eval`s them after rewriting `__DIR__` and `__FILE__` tokens to `<remote dir>/.runlet`.
  - Limit: single-file drivers only, since a `require __DIR__.'/boot.php'` helper wouldn't exist remotely. The same mechanism serves global drivers (N25).
- **Project commands (Commands pane).**
  - Listing boots the application on the server, which runs project code. For SSH profiles the pane **never lists by itself**: it shows "List commands on <host>", and production profiles also confirm.
  - Running a command: `ProjectCommandLauncher.terminalRequest` gains an `.ssh` case. It opens a command tab with argv `ssh -t -S <ctl> <host> '/bin/sh -c "cd <dir> && <command>"'`, with `php` replaced by the profile's PHP (as `localCommandLine` does). The container step uses `ssh -t … docker exec -it … sh -lc '<command>'`.
  - `needsInput` commands open an interactive remote shell and type the command without Return.
  - Production profiles confirm each command, showing the command line and the host.
- **Host commands** always run on the Mac in the local folder (§3.10). They never touch the server unless the command itself does, as `ssh`-based deploy tools do.
- **Terminal "+" menu.**
  - "Shell on <host>": `ssh -t -S <ctl> <host>`, then `cd <dir> && exec $SHELL -l`.
  - "Shell in <container> on <host>": `ssh -t … docker exec -it …`, with bash if available, else sh.
  - Both resolve like a run and never substitute a different container.

### 3.12 Profile UI

- **Profiles window.** Generalize `DockerProfileManager` into one Profiles window with a Docker / SSH switch in the list. It keeps the same pattern: draft until Save (↩ or ⌘S), Revert, Save / Don't Save / Cancel on switch or close, Duplicate, and Use in Current Tab.
- **`SSHProfileForm` fields.**
  - Host: a combo box of `~/.ssh/config` aliases, with the effective `ssh -G` values shown read-only below it.
  - Remote directory, with Suggest (from probe candidates) and the realpath shown.
  - PHP, picked from discovered binaries.
  - **Run inside a container on this host**: a container picker listing remote containers with their Compose identity, the working directory with suggestions, user, tmp, and the Docker command.
  - **Local folder**: a folder picker, the suggestions from §3.10, and a "Use for Completion" button.
  - Language PHP version and strict types.
  - **Environment**: development, staging, or production, plus a colour.
  - Safe mode, drift check, compression, and keep-alive duration.
  - Test Connection, and Connect… or Disconnect.
- **Elsewhere.**
  - The target menu gets an "SSH" section with status dots.
  - The palette's `@` prefix (Tinkerwell's "connections") covers Docker and SSH. Add commands for New SSH Profile…, Connect, and Disconnect.
  - Vertical tab cards: a runtime chip "SSH" (or "SSH · Docker"), a second line `user@host:dir`, and a red **PRODUCTION** chip when flagged (`VerticalTabs.swift`).
  - Settings ▸ Targets lists SSH profiles.
  - Workspace files embed SSH definitions (§3.4).

### 3.13 Production guard rails and safe mode

This is part of N14 and applies to every target kind. For SSH it is required.

**When a profile is marked production:**

- **Badges.** A red PRODUCTION chip on the tab card and horizontal tab, a red dot and label in the target menu and palette rows, and a red stripe in the status bar (`MainWindow.StatusBar`).
- **Confirm before each run.**
  - The sheet shows the profile, `user@host`, the directory, the container if any, and the first 12 lines of what will run (the selection when Run Selection is used), with the line count.
  - The default button is "Run on Production" and needs ⌘↩; a plain ↩ only cancels.
  - "Don't ask again for 10 minutes on this profile" is kept in memory only. It resets on relaunch and when the profile is edited.
  - The same sheet covers remote project commands and the "List commands" boot.
- **Stricter defaults.**
  - Runlet never connects on its own; facts come only from the local folder.
  - The Commands pane never auto-lists.
  - Auto-run (N17) can't be enabled.
  - Snippets opened from history or the palette land in a tab without running, as today.
  - History marks production runs.
- **Environment detection.** `bootstrapped` gains an optional `environment` field (`$app->environment()` for Laravel). When a run reports `production` on a profile that isn't flagged, Runlet shows a one-click "Mark as production" banner.

**Safe mode (optional, per profile, off by default, suggested for production).**

| What it does | Mechanism | What it can't guarantee |
| --- | --- | --- |
| Rolls back database writes | `LaravelDriver` begins a transaction on the default connection (or connections listed in the profile) before the snippet and always rolls back afterwards. The output reports "rolled back". | Writes on other connections or through raw PDO. MySQL implicit commits (DDL, `TRUNCATE`, `LOCK TABLES`) end the transaction early. Non-transactional engines (MyISAM). A snippet calling `DB::commit()` without its own `beginTransaction()` commits the outer transaction. **Long runs hold row locks on production tables**, so show a warning when a safe-mode run passes 5 s. |
| Intercepts mail, notifications, and queued jobs | `Mail::fake()`, `Notification::fake()`, `Queue::fake()` (the fakes ship in `laravel/framework`). The run inspector (N03) lists what was intercepted. | Mail sent through a different client, and Redis or SQS pushes made without the queue manager. |
| Blocks outgoing HTTP through Laravel's client | `Http::preventStrayRequests()` | Raw curl, Guzzle instances created directly, sockets. |
| Disables process execution | `-d disable_functions=exec,shell_exec,system,passthru,proc_open,popen,pcntl_exec` on the `php` command line. This is enforced by PHP itself. | Nothing else (files, cache, Redis, S3). |
| Uses a read-only database connection | Optional `config(['database.default' => '<name>'])` pointing at a replica or a read-only user the project already defines. | This is the **only real guarantee**, and only if that database user lacks write grants. |

The UI always says "Safe mode is a safety net, not a sandbox", and links to this table. Other frameworks can implement a `safeMode()` driver hook later; WordPress and Doctrine can wrap a transaction the same way.

### 3.14 Performance

- **Payload.** Each run streams the 826 KB runner bundle plus the request. Rough guesses to measure: about 0.1 s at 100 Mbit/s, about 0.7 s at 10 Mbit/s, about 7 s at 1 Mbit/s. PHP source compresses well, so `ssh -C` (on by default) should cut this several times over (guess: 4–6×).
- **Handshake.** Without multiplexing, each run pays for TCP, the key exchange, and authentication (guess: 0.2–1 s, plus the agent prompt). With ControlMaster, a new session should cost tens of milliseconds (guess). Runs, Stop, probes, and listings all share one master per profile. Runlet's `maxConcurrentRuns` (4), plus Stop and listings, stays under OpenSSH's default `MaxSessions` of 10.
- **Optional runner cache (opt-in per profile, off by default).** This writes to the server, which breaks the "nothing written" principle; that is why it is opt-in.
  - Store the bundle once in `${XDG_CACHE_HOME:-~/.cache}/runlet/runner-<sha256>.php`: folder 0700, file 0600, written atomically through `php -n -r` (`tempnam` plus `rename`), never in the project.
  - Each run then sends a small stub. It checks `hash_file('sha256')` and the file owner before `require`, then calls `\RunletRunner\Runner::main(…)`.
  - On a mismatch (exit 86), Runlet falls back to streaming and rewrites the cache.
  - Read-only homes fall back to streaming.
  - Recommendation: ship streaming plus `-C` first. Measure on the user's real servers by adding an `--ssh <profile>` timing check to `Runlet --self-test`. Add the cache only if the payload costs more than about 300 ms.
- **Facts and fast feedback.** With a local folder, tab cards never wait for the network.

### 3.15 Implementation plan

| Milestone | Scope | Size |
| --- | --- | --- |
| **SSH-1 Core** | `SSHProfile`, `TargetRef.ssh`, `TargetSnapshot.Kind.ssh`, `SSHEndpoint` and `RemoteShell` quoting, `SSHExecAdapter` (stream, framing, exit-code mapping), shared `RemoteSignal` Stop, ControlMaster for key and agent auth, `SSHProbe` with Test Connection, and a minimal profile sheet. Fixture: a disposable `php-cli` + `openssh-server` container on `127.0.0.1:2222` with a throwaway key and a temporary `HOME` and `known_hosts`. Tests cover run, dump, `dd`, exit, fatal, Stop (including spawned children), concurrency, dead link, unknown host key, and a read-only home. | M |
| **SSH-2 Interactive auth** | Connect… and Disconnect through a terminal tab with ControlMaster, `-O check` status, banners, expiry handling. Live package test: a password-auth fixture driven through a pty (`script(1)`, as in `ShellIntegrationLiveTests`). | M |
| **SSH-3 Local folder** | Language workspace, the `.remote` `EditorPathMapping` (including releases realpaths), `staticFacts`, project snippets, host commands, Open in Editor, terminal start folder, suggestions (git remote, composer name, folder name), drift check. | M |
| **SSH-4 Production guard** | Built as N14 for all targets: flag, colour, badges, confirm sheet with the 10-minute grace, stricter defaults, environment detection. | S–M |
| **SSH-5 Commands and shells** | Remote project commands with confirmation, "List commands on <host>", Shell on host, `needsInput`. | M |
| **SSH-6 Remote Docker** | `DockerCLI` SSH transport, container picker, resolver and `ContainerChoiceSheet` reuse, container-step Stop and path mapping. | M |
| **SSH-7 UI and integration** | Profiles window (Docker + SSH), `~/.ssh/config` import, palette `@`, Settings ▸ Targets, workspace files, a fake `ssh` CLI for screenshot tours (never real servers; see the fake-docker approach). | M |
| SSH-8 Safe mode (optional) | Laravel transaction rollback, fakes, `disable_functions`, connection override, lock warning. | M |
| SSH-9 Extras (optional) | Runner cache, local driver injection, self-test timing. | S–M |

SSH-1 to SSH-4 make a usable first release (plain hosts, any auth, local completion, production guard). SSH-5 to SSH-7 complete the feature.

**Status (2026-10-02).** N14 and SSH-1 to SSH-7 are implemented (SSH-8 safe mode and SSH-9 extras are not); the user guide is [ssh.md](ssh.md). Where the code differs from this design:

- **Stop** signals every process whose environment carries the run's `RUNLET_RUN_ID` (the runner plus whatever the snippet started, even after `setsid`) instead of checking `pgrp == pid` and signalling the group. Docker profiles keep the runner-only helper.
- **Status** comes from connecting to the control socket on this Mac, not `ssh -O check`, so checking never starts `ssh` (no `Match exec` or `ProxyCommand` from `~/.ssh/config` runs at launch). Disconnect still uses `ssh -O exit`.
- **ControlPersist**: Connect… logins always stay until Disconnect (user decision) and outlive Runlet restarts; masters that agent/key runs open keep the per-profile time (10 minutes by default, or until Disconnect).
- **Facts without a local folder** are never fetched in the background; the server's PHP version and framework come from Test Connection and runs.
- **Drift** reads the server's `.git` files and a CRC-32 of `composer.lock` with the read-only PHP probe (no `git` runs on the server), after Connect…, Test Connection, and the first run of a session.
- **Connect…** forces `StrictHostKeyChecking=ask`; helper PHP code (probe, Stop) travels base64-encoded so any login shell's quoting leaves it intact.
- **SSH-7 (UI and integration)**: the Docker Profiles window became the Profiles window (`ProfileManager`: Docker and SSH sections instead of a Docker / SSH switch; the same draft, Save/Revert, and unsaved-changes model; the scene id `docker-profiles` is kept). `~/.ssh/config` import is a sheet with `ssh -G` summaries, an optional directory, and an environment guessed from the alias. Settings ▸ Targets gained Import and Manage Profiles… for SSH (and SSH hosts in the default-target picker); ⌘P's `@` shows SSH hosts with their container; workspace files embed SSH profiles including the container step; palette commands: Manage Profiles…, Import SSH Hosts…, Open Shell on SSH Host, Connect, Disconnect. The screenshot fake is `Tests/Fixtures/fake-ssh/ssh` (Debug `RUNLET_SSH_EXECUTABLE`), a loopback that runs commands on this Mac.
- **Remaining optional milestones:** SSH-8 safe mode, SSH-9 runner-payload cache and self-test timing, and local driver injection (N25) have issues in the active index. The newer server opcode/file cache is implemented and is a different cache.
- **Commands panel**: SSH hosts list only on request (production asks; password hosts offer Connect… first), host commands run in the local folder.
- **SSH-5 (commands and shells)**: commands run as `ssh -t` (BatchMode, strict host keys, the shared connection) with `/bin/sh -lc 'cd <dir> …; <command>'` instead of `/bin/sh -c "cd <dir> && <command>"`, so login PATH additions apply; needs-input commands open `exec "$SHELL" -l` in the directory and type the command. Shell on Host is in the terminal "+" menu, the target menu, the Commands panel, and the palette. Production asks before every command, listing, and shell (a new `GuardedAction.shell`); the grace stays snippet-only.
- **Not done yet**: the `bootstrapped.environment` "Mark as production?" banner (it needs a runner change) and marking production runs in History.
- **Profile form (after user testing)**: Directory gained Detect (home folder plus application folders, read-only `php -r`) and Browse… (a folder picker on the server, symlinks kept); validation checks the saved (trimmed) values and explains an empty field and `~`; Connect… from the sheet works before the profile can be saved and reopens the sheet after the login.
- **SSH-6 (Docker on the host)**: as designed (`DockerCLI` with an SSH transport, the unchanged resolver and adapter, `ContainerChoiceSheet`, Stop through the container), with these details: the container step is resolved only on explicit actions (run, command, shell, Test Connection, List Containers), never on open; the server directory stays required (Detect, Browse…, drift, and the bind-mount path mapping use it) but the server needs no PHP of its own; the snapshot gained `dockerCommand` and `localFolderRoot`; recording the resolved container ID doesn't count as an edit; and the shared resolver now keeps a replica the user chose (before, every run with several replicas asked again). Remote Docker is tested with a fake `docker` on the SSH fixture rather than docker-in-docker.
- **Open questions answered**: servers are Linux (Stop degrades to "unconfirmed" without `/proc`); the 10-minute grace covers snippet runs only; production badges are always red, and the per-target colour is separate. csh/tcsh login shells remain untested.

### 3.16 Later options and open questions

- **Later:** Forge and Ploi site import (N24; Forge API v2 with the `server:view` scope, zero-downtime `current` detection), Kubernetes (N23, the same transport idea with `kubectl exec -i`), and Docker contexts (N21).
- **Open questions:**
  - Are any servers non-Linux? Stop needs `/proc` to be confirmed.
  - Does anyone use csh or tcsh as a login shell?
  - Should the 10-minute grace also cover remote project commands?
  - What `ControlPersist` default is acceptable for 2FA hosts?
  - Should production profiles keep their badge colour fixed (red) or allow customizing it?
