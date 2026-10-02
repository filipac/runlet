# Runlet architecture

Recorded 2026-10-02. This file describes the code in this repository on that date. `plan.md` asks for package versions, the deployment target, and module boundaries to be recorded here.

- The execution, persistence, and language-service layers (`Packages/RunletKit`) are implemented and covered by package tests.
- The native app target (`Runlet/`) is in progress.
- Measurements and prototype-gate results are in [compatibility.md](compatibility.md).
- Requirement-to-evidence status is in [validation.md](validation.md).

## Platform and toolchain

| Item | Value | Where it is set |
| --- | --- | --- |
| Deployment target | macOS 26.0 | `project.yml` (`deploymentTarget`, `MACOSX_DEPLOYMENT_TARGET`, `LSMinimumSystemVersion`); `Package.swift` `.macOS(.v26)` |
| Swift language mode | Swift 6 | `project.yml` `SWIFT_VERSION: 6.0`; `Package.swift` `swift-tools-version: 6.2` |
| Toolchain used | Xcode 27.0, Swift 6.4, on macOS 27.0 arm64 | [compatibility.md](compatibility.md) |
| Project generation | XcodeGen: `project.yml` generates `Runlet.xcodeproj`. Edit `project.yml`, not the generated project. | `project.yml` |
| Swift package | `Packages/RunletKit` with library products `RunletCore`, `RunletExecution`, and `RunletLanguage`. It has no third-party Swift dependencies. | `Packages/RunletKit/Package.swift` |
| Architectures | `ARCHS_STANDARD`. Debug builds only the active architecture. Release builds arm64 and x86_64. | `project.yml` |
| App target concurrency | `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES` (app target only) | `project.yml` |
| Tests | Swift Testing in the three package test targets. A `RunletUITests` target is declared but contains no tests yet. | `Packages/RunletKit/Tests`, `project.yml` |

## Repository layout

```text
project.yml                  XcodeGen spec: Runlet app, RunletUITests, Runlet scheme
Runlet/                      macOS app target (SwiftUI + AppKit), in progress
  App/                       app entry, AppModel (composition), TabModel (per-tab state)
  Editor/                    AppKit code editor and its SwiftUI wrapper
  Features/                  SwiftUI views (tabs, targets, output, settings, history/snippets)
RunletUITests/               UI test target (empty)
Packages/RunletKit/          Swift package: RunletCore, RunletExecution, RunletLanguage + tests
Resources/Runner/            PHP runner: src/Runner.php, build deps (composer.json, build/vendor),
                             generated bundle dist/runlet-runner.php
Resources/Sandbox/laravel/   pinned Laravel sandbox template and runlet-sandbox.json
Resources/LSP/               PHPantom universal binary (fetched) and its license
Tests/Fixtures/              disposable plain, Composer, Laravel, LSP, and Docker fixtures
scripts/                     build, fetch, embed, and fixture scripts
docs/                        architecture, compatibility, validation
```

The plan's suggested layout used three separate packages. This repository uses one package, `Packages/RunletKit`, with three library targets instead.

## Module boundaries

```text
Runlet (app) ──► RunletCore, RunletExecution, RunletLanguage
RunletExecution ──► RunletCore
RunletLanguage  ──► RunletCore
```

`RunletExecution` and `RunletLanguage` do not depend on each other, so PHP execution and language intelligence stay independent. Package targets import only `Foundation` and `Darwin`. AppKit, SwiftUI, and Observation are used only in the app target.

### RunletCore

| File | Contents |
| --- | --- |
| `RunProtocol.swift` | `runProtocolVersion = 1`. `RunRequest` holds `runId`, `tabId`, `documentVersion`, a `TargetSnapshot`, `code`, and an optional `SourceSelection`; `editorLine(forSnippetLine:)` maps runner lines to editor lines. `TargetSnapshot` has `kind` (`sandboxLocal`, `sandboxDocker`, `local`, `docker`), a label, the target ID, the profile revision, the working directory, the PHP executable, and Docker fields. `RunEvent` has `runId`, `sequence`, and `kind`: `started`, `bootstrapped`, `stdout`, `stderr`, `dump`, `result`, `error`, `notice`, `finished`. The file also holds the payload types, `RunErrorStage` (`launch`, `bootstrap`, `parse`, `execute`, `transport`), and `FinishedInfo` (`status` of `completed`/`failed`/`cancelled`, `reason`, `exitCode`, `elapsedMs`, `peakMemory`, `truncation`). |
| `ValueNode.swift` | A bounded value tree. Types are null, bool, int, float, string, array, object, enum, closure, resource, and unknown. Entries are ordered and carry `keyType` (`int`, `string`, or `property`), visibility, and the declaring class. Reference handling uses `referenceId`, `repeated`, and `recursion`. `truncation` gives a reason (`depth`, `children`, `length`, or `budget`). Strings that are not valid UTF-8 are base64 encoded. The file also renders values as plain text for copying. |
| `Models.swift` | `TargetRef`, `LocalProject`, `ContainerIdentity`, `DockerProfile` (with `validate()`), `AppSettings` (decoding tolerates missing keys), `TabState`, `SessionState`, `HistoryEntry`, `Snippet`, `TargetLibrary`, and `matchesSearch`. |
| `JSONStore.swift` | `JSONDocumentStore<T>` (versioned envelope with atomic writes and recovery) and `AppPaths` |
| `ProcessSupervisor.swift` | `ProcessSpec`, `SupervisedProcess` (uses `posix_spawn`), and `runCommand` |
| `ExecutableLocator.swift` | Resolves executables without relying on the terminal `PATH`. It searches the process `PATH`, then Herd, herd-lite, Homebrew, `/usr/local/bin`, `~/.docker/bin`, OrbStack, Rancher Desktop, Docker.app, `/usr/bin`, and `/bin`. |

### RunletExecution

| File | Contents |
| --- | --- |
| `RunnerScript.swift` | `RunLimits` and `RunnerBundle`. `RunnerBundle` assembles the per-run script, generates the nonce, and holds the fixed `php` arguments. |
| `FrameDecoder.swift` | Splits runner stdout into raw output and nonce-framed events |
| `RunSession.swift` | Internal `RunSession` and `RunControl`. Turns one process into sequenced `RunEvent`s and guarantees a single `finished` event. |
| `ExecutionEngine.swift` | The `ExecutionEngine` actor. Also holds the internal adapters `LocalAdapter`, `DockerExecAdapter`, and `DockerSandboxAdapter`, plus `CancelOutcome` and `ExecutionError`. |
| `DockerCLI.swift` | `DockerCLI` (uses the selected Docker context), `ContainerInfo`, and discovery through `docker ps` and `docker inspect` |
| `DockerProfiles.swift` | `DockerProfileResolver`, `ProfileResolution`, `ContainerProbe` with `DockerCLI.probe`, and `workingDirectorySuggestions` |
| `SandboxManager.swift` | `SandboxManifest`, `SandboxRuntime`, and `SandboxManager` (install, reset, runtime choice) |
| `Executables.swift` | `PHPInstallation` and `PHPDiscovery`. Discovery searches `PATH`, the well-known directories, Herd `phpXY` shims, and Homebrew `opt/php*`. It validates each binary with `php -n -r`, records the version and tokenizer availability, and treats PHP 7.4 or newer as supported by the runner. |

### RunletLanguage

| File | Contents |
| --- | --- |
| `LSPTypes.swift` | `JSONValue`, `LSPPosition`, `LSPRange`, `LSPTextEdit`, `LSPDiagnostic`, `CompletionItem`, `HoverInfo`, and `SignatureHelpInfo` |
| `LSPConnection.swift` | JSON-RPC 2.0 with `Content-Length` framing over the child's stdin/stdout. stderr is kept only as a bounded log. Requests have per-request timeouts, and cancelling the calling task sends `$/cancelRequest`. |
| `LanguageServer.swift` | `LanguageWorkspace`, `LanguageServerState`, and `LanguageServerSession` (one PHPantom process). Also the internal `PHPantomConfig` and `ExecutableLocator.minimalEnvironment()`. |
| `LanguageService.swift` | The `LanguageService` actor: one session per workspace, shared by tabs. Also builds scratch URIs. |
| `DocumentMapping.swift` | `ScratchDocumentMapping` (synthetic `<?php\n` line), `TextLineIndex` (converts between UTF-16 offsets and LSP positions), and `SnippetText` (turns LSP snippet syntax into plain text) |

### App target (`Runlet/`, in progress)

- `Editor/` (AppKit):
  - `CodeTextView`: an `NSTextView` subclass with smart substitutions off, auto-indentation, bracket pairing, soft tabs, line comments, and hooks for completion and hover.
  - `EditorController`: owns one tab's scroll view and text view for the tab's lifetime, so undo, selection, scroll position, and input-method state survive SwiftUI updates.
  - `LanguageBinding`: connects a document to a PHPantom session through the scratch URI and the synthetic-tag mapping, and drops diagnostics tagged with an older document version.
  - `CodeEditorView`: the SwiftUI wrapper.
  - `PHPHighlighter`: a single-pass UTF-16 scanner, plus `EditorTheme`.
  - `LineNumberRulerView`: line numbers, a static-diagnostic marker, and an execution-error marker.
  - `EditorPopups`: completion list and info panels.
- `App/` (SwiftUI):
  - `RunletApp`.
  - `AppModel`: composes `AppPaths`, `ExecutionEngine`, `SandboxManager`, and `LanguageService`, and resolves bundle resources. PHPantom comes from `Contents/Helpers/phpantom_lsp`.
  - `TabModel`: per-tab output items, run state, and language state.
- `Features/` (SwiftUI views): in progress.

There are no UI tests or desktop evidence for the app target yet.

## Runner and transport

**Build.** The runner source is `Resources/Runner/src/Runner.php`, written with PHP 7.4-compatible syntax. `scripts/build-runner.php` writes a single file, `Resources/Runner/dist/runlet-runner.php`, that contains:

- The runner.
- nikic/php-parser 5.9.0, with its namespace rewritten from `PhpParser\` to `RunletVendor\PhpParser\`. Builders, pretty printers, and other unused parts are left out.

The scoped parser never collides with a project's own php-parser. Edit `src/`, never `dist/`.

**Per-run script.** `RunnerBundle.script` appends `namespace { \RunletRunner\Runner::main('<base64 JSON>'); }` to the bundle. The request carries:

- `protocolVersion` and `runId`
- `nonce`
- `code`
- `bootstrap` (`"auto"`)
- limits

**Transport.** The whole program is streamed to `php` on stdin, with the arguments `-d display_errors=stderr -d html_errors=0 -d log_errors=0`. Nothing is written into the project or the container, so read-only filesystems and non-root users work. The plan's first candidate was a per-run event file. It was not used, but the event contract is unchanged.

**Event framing.** Events are framed records on stdout:

```text
0x1E "RL1:" <nonce> ":" <decimal byte length> ":" <json> "\n"
```

- The nonce is 16 random bytes in hex, generated per run with `SecRandomCopyBytes`.
- All other stdout and stderr bytes are the application's raw output.
- `FrameDecoder` handles frames and markers split at any byte. It holds back a possible partial marker at the end of a chunk.
- Frames with another nonce stay raw output.
- A truncated or malformed frame becomes a `transport` error.

**Runner frame types.**

- `started`: pid, PHP version and binary, SAPI, working directory, framework, euid
- `bootstrapped`: framework, framework version, `bootstrapMs`
- `dump`
- `result`: `hasValue`, `value`
- `error`
- `notice`
- `runnerFinished`: reason, `elapsedMs`, `peakMemory`, `executeMs`

`RunSession` turns `runnerFinished` into the backend's `finished` event.

**Bootstrap.** Framework detection in `auto` mode:

- `laravel` if `artisan` and `bootstrap/app.php` exist.
- `composer` if `composer.json` or `vendor/autoload.php` exists.
- `plain` otherwise.

Composer and Laravel projects require `vendor/autoload.php`. If it is missing, the runner reports a bootstrap error that tells the user to run `composer install`. For Laravel, the runner requires `bootstrap/app.php`, resolves the console kernel, calls `bootstrap()`, and reports `$app->version()`. Plain directories run without an autoloader, and relative includes resolve against the working directory.

**Snippet compilation** (`SnippetCompiler`):

1. If the code does not start with `<?php` or `<?=` (after whitespace), the runner prepends `<?php ` on the same line, so line numbers do not change. Column numbers for parse errors on line 1 are corrected for the prefix length.
2. The code is parsed with `ParserFactory::createForHostVersion()`. If parsing fails, the runner retries with `"\n;"` appended, which accepts an omitted final semicolon. If that also fails, it reports a `parse` error with the snippet line and column.
3. The runner finds the last top-level statement, looking inside a trailing namespace. A final expression statement (other than `exit`) becomes `return <expr>;`. A final `return` is kept.
4. A sentinel `return \RunletRunner\NoResult::instance();` is appended. It goes inside a trailing braced namespace if there is one, and PHP mode is reopened if the source ends in inline HTML. In the result, `NoResult` means "no implicit result", which is distinct from `null`.
5. Without the tokenizer extension, no implicit result is captured and the runner emits a `notice`.

**Evaluation.** `eval()` runs inside the private static method `Runner::evaluate`, so snippet variables live in their own function scope and never touch runner state. Every run is a new PHP process, so no state carries over between runs.

**Dumps** (`installDumpHandler`):

- `VarDumper::setHandler` is installed on `Symfony\Component\VarDumper\VarDumper` and on any VarDumper class referenced by the files that define the active `dump()`/`dd()`.
- The search follows php-scoper-style aliases up to depth 3, which covers tools loaded with `auto_prepend_file` such as global Ray.
- If no VarDumper and no `dump`/`dd` functions exist, the runner defines its own `dump()` and `dd()`.
- A `dd` call is detected from the backtrace. It is marked `origin: "dd"`, and the run finishes with reason `dd`.

**Values** (`ValueNormalizer`):

- No getters, `__toString`, `__debugInfo`, `__get`, or JSON serialization are invoked.
- Limits: depth 8, 200 children, 64 KiB per string, 20,000 nodes, and 2 MiB per value.
- Objects get reference IDs, and an object seen again is marked `repeated`. Array references are marked `recursion`.
- `var_dump` and `print_r` stay plain text on stdout.

**Errors.** Throwables become `error` events with:

- stage, class, and message (eval paths are rewritten to "snippet")
- `snippetLine` or file and line
- a trace of up to 40 frames, with runner frames removed
- the previous exception

A shutdown function reports fatal errors as `FatalError` with `fatal: true` and reason `fatal`. `exit` and `die` finish with reason `exit`.

## Run lifecycle (`ExecutionEngine`)

1. **Snapshot.** A `RunRequest` captures:
   - the tab ID and document version
   - the code, which is only the selection for Run Selection, with the selection's start position
   - a `TargetSnapshot` with the resolved working directory, PHP executable, container ID, user, and profile revision

   Later edits or target changes cannot redirect an active run.
2. **Admission.** Each tab can have one active run. A second `start` for the same tab throws `ExecutionError.tabBusy`. Docker targets require a located Docker CLI.
3. **Bounded concurrency.** Runs in different tabs execute concurrently, up to `maxConcurrentRuns` (default 4). Further runs wait for a free slot.
4. **Launch.** The adapter builds a `ProcessSpec`: an executable path plus an argument array, with no shell. `SupervisedProcess` then:
   - starts the child with `posix_spawn` in a new process group, with default signal dispositions
   - writes stdin on a background thread, with `SIGPIPE` suppressed
   - reads stdout and stderr on dedicated threads
   - reaps the child on its own thread

   `RUNLET_RUN_ID` is set in the runner's environment for every adapter.
5. **Event pump.** `RunSession` decodes frames and numbers events 1…n. Byte order is preserved within each raw stream, but interleaving between stdout and stderr is not guaranteed.
6. **Output limit.** Up to `RunLimits.maxRawOutputBytes` (8 MiB) of raw stdout plus stderr is kept per run. Further output is still read and discarded, so a full pipe cannot deadlock the process, and `finished.truncation` reports the discarded byte count.
7. **Exactly one `finished`.** It is always the last event:

| Situation | `status` | `reason` |
| --- | --- | --- |
| Snippet completed | completed | `completed` |
| `dd()` | completed | `dd` |
| `exit`/`die` | completed if exit code 0, else failed | `exit` |
| Parse, bootstrap, or execute error | failed | `error` |
| PHP fatal error | failed | `fatal` |
| Stop after launch | cancelled | `cancelled`, or `cancelled: <note>` when the stop could not be confirmed |
| PHP or directory missing, container gone or not running, spawn failure, or process exited before the runner started | failed | `launch-failed` (with a `launch` error) |
| Process ended without `runnerFinished` | failed | `transport-closed` (with a `transport` error) |
| Stop before the process launched | failed | `launch-failed` ("Stopped before launch.") |

For Run Selection, the selection's start line is added to runner line numbers to map them back to the editor. Columns are not adjusted for selections that start mid-line.

## Cancellation (Stop)

`ExecutionEngine.cancel(runId:)` marks the run as cancelled, then calls the adapter's stop operation. It returns a `CancelOutcome`, where `confirmed` is true only when Runlet saw the PHP process end.

| Adapter | Mechanism |
| --- | --- |
| Local (`LocalAdapter`) | The runner leads its own process group. Stop sends `SIGTERM` to the group, waits 1.5 s, sends `SIGKILL` to the group, and gives up after 5 s in total. Child processes started by the snippet are in the same group and stop too. |
| Existing container (`DockerExecAdapter`) | See below. |
| Docker sandbox (`DockerSandboxAdapter`) | The run uses `docker run --rm -i --name runlet-sandbox-<first 8 of runId> --label dev.runlet.owned=sandbox`. Because Runlet owns that container, Stop runs `docker kill` on it, waits 4 s, and then terminates the local client. |

For an existing container, Stop works as follows:

1. Wait up to 2 s for the runner PID from the `started` event.
2. Run a separate `docker exec [--user U] <container> <php> -r <helper> -- <pid> <runId> <signal>`.
3. The helper reads `/proc/<pid>/stat` and treats a missing or zombie process as gone.
4. The helper requires `RUNLET_RUN_ID=<runId>` in `/proc/<pid>/environ`. On a mismatch it does not send a signal.
5. The helper signals with `posix_kill`, falls back to `exec('kill …')`, and otherwise reports `unsupported`.
6. The sequence is `SIGTERM`, a 1.5 s wait, `SIGKILL`, a 3 s wait, then a signal-0 check.

Runlet never uses `docker stop` or `pkill`, so the application container keeps running.

Known limitations, also listed in [compatibility.md](compatibility.md):

- Docker Stop signals only the runner PID, so processes a snippet spawns inside a container may survive.
- In-container Stop needs Linux `/proc`, plus either `posix_kill` or `/bin/sh` with `exec()`. Without them the outcome is reported as unconfirmed.

## Docker targets

- **CLI.** The Docker CLI is found through `ExecutableLocator`. `AppSettings.dockerExecutable` overrides it. The CLI uses the machine's selected Docker context.
- **Discovery.** Running containers are listed with `docker ps -q --no-trunc` and `docker inspect --type container`. Runlet-owned containers (label `dev.runlet.owned`) are excluded.
- **Profiles.** `DockerProfile` stores:
  - a `ContainerIdentity`: Compose project and service labels, the container name as a fallback, and the last container ID and image
  - the working directory
  - the PHP executable (default `php`)
  - an optional user and the temporary directory (default `/tmp`)
  - an optional local source path and language PHP version
  - `autoResolve` and a revision number

  `validate()` rejects relative paths, malformed users, and PHP values that start with `-`.
- **Resolution** (`DockerProfileResolver`):
  - With a Compose identity: one running match resolves, flagged as recreated if its ID changed. Several matches are ambiguous, and the user must choose. No match means not running.
  - Without Compose labels: the same container ID resolves. The same name with a new ID needs confirmation.
  - The resolver never picks a different container silently.
- **Launch.** The snapshotted container ID is inspected again right before launch. Runlet refuses to run if that container was removed or is not running. The command is `docker exec -i --env RUNLET_RUN_ID=<id> --workdir <dir> [--user <user>] <containerId> <php> -d …`. It uses no TTY and keeps the container's environment.
- **Probe.** `DockerCLI.probe` uses only `php -r` inside the container, so no shell utilities are needed. It reports:
  - PHP version and binary
  - user and uid
  - whether the working directory exists and is readable
  - framework
  - whether the temporary directory is writable
  - tokenizer availability
  - how Stop can signal (`posix`, `shell`, or `none`)
  - candidate application directories
- **Working-directory suggestions.** These come from the container's `WorkingDir`, its mount destinations, and common paths.
- **Temporary directory.** The profile's temporary directory is checked by the probe, but it is not passed to `docker exec`, because the runner writes no files.

## Laravel sandbox

- **Template.** `Resources/Sandbox/laravel` holds Laravel 13.34.0, which requires PHP `^8.3`. `scripts/build-sandbox.sh` installs its locked dependencies and builds a pre-migrated SQLite database on the build machine. `runlet-sandbox.json` records `laravelVersion`, `phpConstraint`, `minimumPHP` (8.3), and `dockerImage` (`php:8.4-cli`).
- **Install.** `SandboxManager.ensureInstalled()` copies the immutable template from the bundle into `Sandbox/laravel-<version>/` under Application Support, using a staging directory `.install-<uuid>`. It then:
  - writes a `.env` with a random `APP_KEY`, SQLite, array sessions, a file cache, a sync queue, and the `log` mailer
  - creates the storage directories
  - writes a `.runlet-installed` marker

  `reset()` deletes only that directory and reinstalls it.
- **Runtime choice.** `chooseRuntime` picks the first match from this list:
  1. The preferred PHP, if it is version 8.3 or newer and has the tokenizer.
  2. Otherwise, the newest compatible discovered PHP.
  3. Otherwise, Docker, if its daemon responds. `imagePresent: false` means the first use needs an image download.
  4. Otherwise, `unavailable`, with an explanation.

  The Docker sandbox mounts the installed copy at `/sandbox`.

## Persistence

`AppPaths.standard` is `~/Library/Application Support/Runlet`. If `RUNLET_DATA_DIR` is set and not empty, Runlet uses that directory instead.

```text
<root>/
  State/
    settings.json                 AppSettings
    targets.json                  TargetLibrary (local projects, Docker profiles)
    snippets.json                 personal snippets
    history.json                  execution history
    session.json                  SessionState (tabs, selected tab)
    <name>.last-good.json         previous valid copy
    <name>.corrupt-<timestamp>.json   preserved unreadable file
  Sandbox/laravel-<version>/      writable sandbox install (see above)
  LanguageService/
    config-<hash>/phpantom_lsp/.phpantom.toml   per-workspace PHPantom global config
    basic-workspace/              root for workspaces without local source
  Runs/                           declared in AppPaths; unused (the runner writes no files)
  Logs/                           declared in AppPaths; unused by package code
```

How `JSONDocumentStore` works:

- **Envelope.** Each file is `{ "schemaVersion": 1, "savedAt": …, "data": … }`.
- **Save.** If the current file still decodes, it is first copied to `<name>.last-good.json`. The new data is written to a temporary file in the same directory and moved into place with `rename()`.
- **Load when missing.** If the file is missing, the last-good copy is used, or the default value if there is none.
- **Load when unreadable.** A file that cannot be decoded, or that has a `schemaVersion` newer than this build supports, is moved aside to `<name>.corrupt-<ISO 8601 timestamp>.json`. The last-good copy is restored if it decodes; otherwise the default is used.
- **Recovery notes.** Loading returns recovery notes for display.
- **Settings.** `AppSettings` decoding fills missing keys with defaults.

The package does not implement the plan's session-write debounce (about 500 ms), flush on quit, or history trimming (`AppSettings.historyLimit` defaults to 1000). Those belong to the app layer.

## Language service (PHPantom)

- **Binary.** `Resources/LSP/phpantom_lsp` is a universal binary. It is copied to `Contents/Helpers/phpantom_lsp` in the app bundle.
- **Launch.** PHPantom runs with `--stdio`, with the workspace root as its working directory. Its environment is minimal: `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `LANG`, `LC_ALL`, and `PATH=/usr/bin:/bin`, which has no host PHP. `XDG_CONFIG_HOME` points to an app-owned config home.
- **One process per workspace.** `LanguageService` keeps one `LanguageServerSession` per `LanguageWorkspace`, keyed by kind (`project` or `basic`), root path, and optional PHP version. Tabs acquire and release a session by tab ID, and the server stops when the last tab releases it. Workspaces with different keys never share a process.
- **App-owned global config.** `PHPantomConfig` writes `LanguageService/config-<FNV-1a of kind|root|phpVersion>/phpantom_lsp/.phpantom.toml`. PHPantom reads it as its global config. It sets:
  - an optional `[php] version`
  - `[diagnostics] workspace = false`, `workspace-external = false`
  - `[formatting] pint`, `php-cs-fixer`, `phpcbf = ""`
  - `[phpstan]`, `[phpcs]`, `[mago] command = ""`

  The user's own global PHPantom config is never modified, because PHPantom looks for its global config under `XDG_CONFIG_HOME`. A project's `.phpantom.toml` is read but never modified. It merges on top, so a project that sets a tool command explicitly opts back in.
- **Scratch documents.** Each tab's URI is `file://<root>/.runlet-scratch/tab-<uuid>.php`. PHPantom resolves it against the real project root, and the file is never created on disk. Every change sends the full text with an increasing version number.
- **Line mapping.** If the editor text has no opening tag, `ScratchDocumentMapping` adds `<?php\n` as its own line. Editor line *n* maps to LSP line *n*+1, and columns do not change. Positions inside the synthetic line clamp to (0, 0), so import `additionalTextEdits` land on editor line 0. Both sides use UTF-16 positions, and the client advertises `positionEncodings: ["utf-16"]`.
- **Snippet syntax.** `SnippetText` converts PHPantom's snippet syntax to plain text plus a cursor offset. PHPantom 0.10.0 sends snippet syntax even though the client declares `snippetSupport: false`.
- **Features used.** Completion with resolve, hover, signature help, and pushed diagnostics (`publishDiagnostics` with version support).
- **Crash restart.** After an unexpected exit, the session restarts with a backoff of 300 ms × attempt, up to 5 attempts. It reopens documents from the client's copy of their text. State is reported as `stopped`, `starting`, `ready`, `restarting`, or `failed`. A manual restart resets the attempt counter.
- **No local source.** Docker profiles without a mapped checkout use a `basic` workspace (`LanguageService/basic-workspace`) for core PHP completion. `LanguageWorkspace.sourceLimitations()` describes what is missing: an unmapped source, a missing directory, or a missing `vendor/`.

## Dependency versions

| Component | Version | Pinned by |
| --- | --- | --- |
| nikic/php-parser | 5.9.0 | `Resources/Runner/composer.json` (`^5.6`, Composer platform PHP 7.4.33) and `composer.lock`. Bundled as `RunletVendor\PhpParser` in `dist/runlet-runner.php`. |
| Laravel (sandbox) | laravel/framework 13.34.0 | `Resources/Sandbox/laravel/composer.json` (`^13.17`), `composer.lock`, and `runlet-sandbox.json` |
| Sandbox PHP requirement | `^8.3` (minimum 8.3) | `runlet-sandbox.json` |
| Docker sandbox fallback image | `php:8.4-cli` | `runlet-sandbox.json` (`dockerImage`) |
| PHPantom LSP | 0.10.0 | `scripts/fetch-phpantom.sh`. Release tarballs are checksum-verified and combined with `lipo`. |
| PHPantom aarch64 SHA-256 | `2f445d9708ed15e1714b48271db43741d13a70c674ef5b3ff1a423e51b4f663b` | `scripts/fetch-phpantom.sh` |
| PHPantom x86_64 SHA-256 | `b1c8fffbbc34cba2edc42013f4010794179506eab04a49ee15a07364985bd596` | `scripts/fetch-phpantom.sh` |
| Runner target PHP | 7.4 – 8.5 | [compatibility.md](compatibility.md) |
| Swift packages | none | `Package.swift` |
| Docker test fixtures | `php:8.4-cli`, `php:7.4-cli`, `php:8.2-cli-alpine` | `Tests/Fixtures/docker/compose.yml` |

The build machine needs these tools; end users do not:

- Composer
- PHP 8.0+ for `scripts/build-runner.php`
- PHP 8.3+ for `scripts/build-sandbox.sh` and `scripts/setup-fixtures.sh`, which run `artisan`
- `curl`, `shasum`, and `lipo` for `scripts/fetch-phpantom.sh`

Runlet never runs Composer in a user's project.

## Build and distribution

- **Bundle settings** (`project.yml`): bundle ID `dev.runlet.Runlet`, version 0.1.0 (build 1), category developer tools. The app declares that it can open `public.php-script` files as an editor, with `Alternate` rank.
- **No App Sandbox** (`ENABLE_APP_SANDBOX = NO`). Runlet launches user-selected PHP and Docker executables and reads existing projects, and subprocesses would inherit sandbox restrictions. Runlet's Laravel sandbox is an execution workspace, not an OS security boundary.
- **Hardened runtime** is enabled (`ENABLE_HARDENED_RUNTIME = YES`).
- **Signing.** `CODE_SIGN_STYLE = Manual`, `CODE_SIGN_IDENTITY = "-"` (ad-hoc), and no development team. Local builds need no signing credentials.
- **Post-build phase** (`scripts/embed-resources.sh`):
  - Copies the runner to `Contents/Resources/Runner/runlet-runner.php`.
  - Copies the sandbox template to `Contents/Resources/Sandbox/laravel`. It excludes `.env`, `node_modules`, `.git`, `tests`, logs, compiled views, sessions, cache data, and `bootstrap/cache/*.php`. The phase fails if the sandbox `vendor/` is missing.
  - Copies PHPantom to `Contents/Helpers/phpantom_lsp`, running `scripts/fetch-phpantom.sh` first if the binary is missing.
  - Signs the helper with `codesign --force --options runtime --timestamp=none --sign "$EXPANDED_CODE_SIGN_IDENTITY"` (ad-hoc `-` by default), unless `CODE_SIGNING_ALLOWED=NO`.
  - Copies license notices to `Contents/Resources/Licenses/`: `PHPantom-LICENSE.txt`, `PHP-Parser-LICENSE.txt`, and `Laravel-LICENSE.md`.
- **Not done yet:** Developer ID signing, notarization, a packaging script (`scripts/package.sh`, to be added), and checks on the packaged app.
