# Validation evidence

**Historical execution evidence.** The counts and last-run results below predate later suites and are not current totals or a fresh verification. Audit/coverage refresh: [#54](https://github.com/filipac/runlet/issues/54). Current test sources may cover previously listed gaps; inspect and run them before closing that issue. This documentation audit executed no package or UI tests.

`plan.md` asks for a requirement-to-evidence table for M01–M22 and for the end-to-end acceptance scenarios. It also asks to keep CLI/test proof separate from rendered-desktop proof and packaged-app proof. This file covers all three.

Recorded 2026-10-02 on macOS 27.0 (arm64), Xcode 27.0, Swift 6.4, Docker 29.4.0, from the test sources and the runs listed under [Evidence types](#evidence-types). Re-run the commands in [Reproducing the evidence](#reproducing-the-evidence) to refresh it.

## Evidence types

| Type | What it is | Current state |
| --- | --- | --- |
| **CLI/tests** | Swift Testing tests in `Packages/RunletKit/Tests`, run with `swift test`. They execute real PHP (on the host and in Docker containers) and the pinned PHPantom binary. Nothing is mocked except where a test says so (for example a wrapper script that makes `docker ps` report a vanished container). | 86 tests in 12 top-level suites (table below). The last full run had 70 passing; `LaravelCompletionTests` (15) and `RapidEditTests` (1) were added afterwards and pass when run on their own (`swift test --filter RunletLanguageTests`: 28 passed). |
| **Desktop** | XCUITests in the `RunletUITests` target. They launch the built Debug app with an isolated `RUNLET_DATA_DIR` and drive it through accessibility: real key events into the AppKit editor, menu shortcuts, clicks, and assertions on rendered output. `ScenarioUITests` seeds saved targets as the same versioned JSON the app writes, instead of driving file pickers. Its Docker scenarios run only with `TEST_RUNNER_RUNLET_DOCKER_FIXTURES=1` and the fixture containers running. | `RunletUITests` 6 tests and `ScenarioUITests` 7 tests. Last full run (`build/uiall.log`): 13 passed, 0 failed, with the two Docker scenarios executed (not skipped). `VisualTourUITests` is an opt-in screenshot tour with no behavioral assertions; it is not counted as evidence. |
| **Packaged** | `scripts/package.sh` builds a universal Release `Runlet.app` into `dist/`, verifies it, and runs the packaged binary's headless self-test (`Runlet --self-test [--docker]`), which uses the bundle's own resources and `Contents/Helpers/phpantom_lsp`. | `dist/Runlet.app` (universal, ad-hoc signed, hardened runtime), `Runlet.zip`, `Runlet.dmg`, and `self-test.json`. `Runlet --self-test --docker` passed all five checks natively on arm64 and under Rosetta (`arch -x86_64`). The app has not been launched from Finder by a test, and it is not Developer ID signed or notarized. |

## Status values

| Status | Meaning |
| --- | --- |
| Verified | Every part of the requirement has passing evidence at the levels that apply to it: package tests for backend behavior and a UI test for what the user does in the window. |
| Verified with gaps | The core behavior is verified at every level that applies. The listed sub-items have no automated evidence. |
| Partially verified | Significant parts of the requirement have no automated evidence. |
| Pending | No evidence. |

## Reproducing the evidence

One-time preparation, from the repository root and in this order. The Laravel fixture is copied from the built sandbox template, so build the sandbox first.

```bash
scripts/fetch-phpantom.sh
```

```bash
scripts/build-sandbox.sh
```

```bash
scripts/setup-fixtures.sh docker
```

The Docker sandbox tests and scenarios also need the sandbox image:

```bash
docker pull php:8.4-cli
```

### Package tests

Run the whole package suite:

```bash
cd Packages/RunletKit && swift test
```

Run one area, for example the Laravel completion tests (scenario 15):

```bash
cd Packages/RunletKit && swift test --filter LaravelCompletion
```

Suites whose prerequisites are missing are **skipped, not failed**. A green run on a machine without Docker or PHP does not prove those paths, so check the output for skipped suites.

| Suite | Tests | Needs | If missing |
| --- | --- | --- | --- |
| `RunletCoreTests.PersistenceTests` | 6 | nothing | — |
| `RunletCoreTests.ValueTableTests` | 3 | nothing | — |
| `RunletExecutionTests.FrameDecoderTests` | 5 | nothing | — |
| `RunletExecutionTests.ResolverTests` | 4 | nothing | — |
| `RunletExecutionTests.LocalRunTests` | 17 | host `php` (`runsOnPHP74` also needs Herd `php74`) | skipped |
| `RunletExecutionTests.LocalLaravelTests` | 3 | host PHP 8.3+ and `Tests/Fixtures/laravel-app/vendor` | skipped |
| `RunletExecutionTests.DockerRunTests` | 7 | a running Docker engine and the `runlet-fixtures` containers | skipped without Docker; **fails** if Docker runs but the fixtures are not started |
| `RunletExecutionTests.SandboxAndRecreationTests` | 13 | Nested suites. `SandboxManagerTests` (5): `scripts/build-sandbox.sh`, and host PHP for the two that run code. `DockerSandboxTests` (3, one with two argument cases): Docker, the built sandbox, and the `php:8.4-cli` image. `ComposeRecreationTests` (1): Docker, the Laravel fixture, and `php:8.4-cli`; it uses its own Compose project (`runlet-fixtures-recreate`) and leaves `runlet-fixtures` alone. `ContainerListingTests` (1): Docker. `PHPDiscoveryTests` (3): host PHP for one. | skipped per nested suite or test |
| `RunletCoreTests.SSHModelTests` | 5 | nothing | — |
| `RunletCoreTests.ProductionGuardTests` | 4 | nothing | — |
| `RunletExecutionTests.SSHUnitTests` | 8 | `/bin/sh`, `/bin/bash`, `/bin/zsh` (others are skipped inside the test) | — |
| `RunletExecutionTests.LocalCheckoutTests` | 5 | nothing | — |
| `RunletExecutionTests.SSHRunTests` | 10 | Docker, `/usr/bin/ssh`, and `/usr/bin/ssh-keygen`. Starts the `runlet-fixtures` service `ssh` itself (built from `Tests/Fixtures/docker/ssh` on first use, which needs the network once). Uses a throwaway key, its own `ssh -F` config and `known_hosts`, and no agent; never reads `~/.ssh`. | skipped without Docker or ssh |
| `RunletCoreTests.BenchmarkRecordTests`, `ProfilerDetectionTests`, `FlameGraphTests` | 16 | nothing | — |
| `RunletExecutionTests.BenchmarkRunnerTests` | 7 | host `php` (the Profile Run refusal test returns early when the host PHP loads Excimer) | skipped |
| `RunletExecutionTests.LaravelBenchmarkTests` | 2 | host `php` and `Tests/Fixtures/laravel-app/vendor` | skipped |
| `RunletExecutionTests.ProfileRunDockerTests` | 3 | Docker and the `runlet-fixtures` service `profiler` (PHP 8.4 with Excimer and SPX, built from `Tests/Fixtures/docker/profiler` on first use, which needs the network once). Finds it by its Compose labels only. | skipped |
| `RunletExecutionTests.FixturesOnlyDockerTests` | 5 | `/bin/sh` and `awk` only: a recording stand-in plays Docker. `testSupportDockerGoesThroughTheWrapper` also needs Docker. | that one test skipped |
| `RunletLanguageTests.MappingTests` | 4 | nothing | — |
| `RunletLanguageTests.PHPantomTests` | 8 | `Resources/LSP/phpantom_lsp`. Two tests also use the Laravel fixture. | skipped without the binary; the two fixture tests fail without the fixture |
| `RunletLanguageTests.LaravelCompletionTests` | 15 | `Resources/LSP/phpantom_lsp` and `Tests/Fixtures/laravel-app/vendor` | skipped |
| `RunletLanguageTests.RapidEditTests` | 1 | `Resources/LSP/phpantom_lsp` | skipped |

**Only Runlet's containers.** Every package test that runs Docker uses `TestSupport.docker`, which runs the real Docker CLI only through `Tests/Fixtures/docker/fixtures-only-docker` ([#80](https://github.com/filipac/runlet/issues/80)). The wrapper lets through only the `runlet-fixtures` and `runlet-fixtures-recreate` Compose projects and Runlet's own sandbox containers:

- `ps` lists only those containers, with one label-filtered `ps` per project or label.
- `inspect`, `exec`, `cp`, `pause`, `unpause`, `kill`, and `rm` take only those containers, by full ID, name, or ID prefix, and pass Docker their full IDs. Docker therefore never resolves an argument to another container, for example one named like a fixture's short ID.
- To `inspect`, any other container doesn't exist. The other commands refuse it. The wrapper never asks Docker about another container, not even whether it exists.
- `run` needs Runlet's sandbox label, and `compose` needs one of those projects. Everything else except `version`, `context`, and `image` is refused.

So a plain `swift test` never lists, inspects, or execs into your own containers, whatever `docker` is first on `PATH`. There is no opt-out, because no test needs other containers. The tests find the real CLI the way the app does: `PATH`, then the usual install folders, skipping the wrapper itself. They give it to the wrapper through a small generated `docker` launcher. Set `RUNLET_REAL_DOCKER` to use another CLI:

```bash
cd Packages/RunletKit && RUNLET_REAL_DOCKER=/usr/local/bin/docker swift test
```

`FixturesOnlyDockerTests` proves this with a recording stand-in for Docker (`Tests/Fixtures/docker/recording-docker`), placed behind the wrapper the same way. The stand-in has a fixture, a sandbox container, a container of another Compose project, and one named like the fixture's short ID. Its call log shows that discovery, profile resolution, `inspect`, `exec`, `cp`, `pause`, `kill`, and `rm` never hand Docker another container, and that every `ps` is label-filtered. The suite also checks that `TestSupport.docker` is the wrapper. The earlier setup, a `docker` symlink to the wrapper first on `PATH`, is no longer needed.

Without the fixture containers, but with Docker running:

- These fail and ask you to start the fixtures: `DockerRunTests`, `DockerDriverTests`, `DockerCommandsTests`, `ProjectREPLDockerTests`, `MagicCommentDockerTests`, `StrictTypesDockerTests`, and the Docker test in `TargetInspectorTests`.
- `ProfileRunDockerTests` is skipped.
- `SSHRunTests` and `MagicCommentSSHTests` start the `ssh` service themselves.
- The Docker sandbox, Compose recreation, and container listing suites don't use the fixture containers.

Without Docker, all of these are skipped. The exception is `FixturesOnlyDockerTests`: only its `TestSupport.docker` check needs Docker.

For the app, set `dockerExecutable` to the script in a scratch `RUNLET_DATA_DIR`'s settings. The Profile Run checks for [#41](https://github.com/filipac/runlet/issues/41) used it with a Docker profile for the `profiler` service (Compose project `runlet-fixtures`, service `profiler`, `/var/www/html`, which mounts `Tests/Fixtures/laravel-app`). Start that service with `docker compose -p runlet-fixtures -f Tests/Fixtures/docker/compose.yml up -d profiler`.

### Running from Xcode

The generated `Runlet` scheme runs with **Metal API Validation off** (`project.yml`, `enableGPUValidationMode: disabled`, [#85](https://github.com/filipac/runlet/issues/85)). Core Animation's own line drawing (`CA::CG::DrawLines` on the `CA::CG::Queue` thread) sometimes issues a Metal draw with zero instances. A normal launch ignores it, but with validation on, Xcode stops on `instanceCount(0) must be non-zero`. To debug GPU issues, turn validation back on in Product ▸ Scheme ▸ Edit Scheme ▸ Run ▸ Diagnostics; `xcodegen generate` resets it.

### UI tests (rendered app)

The scheme turns off automatic screenshots and screen recordings. Generate the project, then run the UI tests. `TEST_RUNNER_RUNLET_DOCKER_FIXTURES=1` tells the sandboxed test runner that the Docker fixtures are up; without it the two Docker scenarios are skipped.

```bash
xcodegen generate
```

```bash
TEST_RUNNER_RUNLET_DOCKER_FIXTURES=1 xcodebuild -project Runlet.xcodeproj -scheme Runlet -configuration Debug -derivedDataPath build/DerivedData -resultBundlePath build/uiall.xcresult -only-testing:RunletUITests test
```

Optional screenshot tour (renders Runlet's own windows to PNG; uses a fake Docker CLI so no real containers appear):

```bash
TEST_RUNNER_RUNLET_SNAPSHOT_DIR="$PWD/build/tour" xcodebuild -project Runlet.xcodeproj -scheme Runlet -configuration Debug -derivedDataPath build/DerivedData -only-testing:RunletUITests/VisualTourUITests test
```

### Packaged app

Build, verify, and self-test the universal app (`RUNLET_SELFTEST_DOCKER=1` adds the Docker sandbox check):

```bash
RUNLET_SELFTEST_DOCKER=1 scripts/package.sh
```

Re-run the packaged self-test natively and under Rosetta. Each run uses a throwaway data directory:

```bash
RUNLET_DATA_DIR="$(mktemp -d)" dist/Runlet.app/Contents/MacOS/Runlet --self-test --docker
```

```bash
RUNLET_DATA_DIR="$(mktemp -d)" arch -x86_64 dist/Runlet.app/Contents/MacOS/Runlet --self-test --docker
```

Stop the disposable Docker fixtures afterwards:

```bash
docker compose -p runlet-fixtures down
```

### Packaged self-test results

Both runs exited 0 with `"ok": true`. Times are the self-test's own measurements in milliseconds.

| Check | What it proves | arm64 | x86_64 (Rosetta) |
| --- | --- | --- | --- |
| `resources` | Runner, sandbox template (manifest and `vendor/autoload.php`), and an executable PHPantom are found inside the bundle | ok | ok |
| `sandbox-install` | The bundled template installs into app-owned storage (`RUNLET_DATA_DIR/Sandbox/laravel-13.34.0`) | ok, 1474 ms | ok, 1292 ms |
| `sandbox-run-local` | `collect([1, 2, 3])->sum()` runs in the installed sandbox with host PHP 8.4.25 and Laravel 13.34.0, result `6` | ok, 134 ms | ok, 146 ms |
| `sandbox-run-docker` | The same snippet runs in the Docker sandbox (`php:8.4-cli`, PHP 8.4.26), result `6` | ok, 525 ms | ok, 479 ms |
| `phpantom-completion` | The bundled PHPantom starts from `Contents/Helpers` with `PATH=/usr/bin:/bin` and completes `collect([1])->ma` with `map` (11 items) | ok, 428 ms (server startup 31 ms) | ok, 530 ms (server startup 63 ms) |

`scripts/package.sh` also checked `codesign --verify --deep --strict`, that the app executable and `phpantom_lsp` both contain `x86_64` and `arm64`, that the runner, sandbox manifest, sandbox `vendor/autoload.php`, and PHPantom license are bundled, and that no sandbox `.env` is bundled. The signature is ad-hoc (`Signature=adhoc`, no team identifier).

Package-test latency figures for native and Docker runs are in [compatibility.md](compatibility.md). Latency in the rendered app has not been measured separately.

## Must-have capabilities (M01–M22)

Package test names are `Suite.test`. UI test names are `RunletUITests.test…` and `ScenarioUITests.test…`. "Self-test" refers to the packaged-app checks above.

| ID | Capability | CLI/test evidence | Desktop evidence (UI tests) | Packaged evidence | Not yet evidenced | Status |
| --- | --- | --- | --- | --- | --- | --- |
| M01 | Laravel sandbox | `SandboxManagerTests.ensureInstalledCreatesConfiguredWritableSandbox` (app-owned install, own `APP_KEY`, SQLite, log mailer, writable storage, template untouched), `.runsLaravelInInstalledSandboxWithLocalPHP`, `.installsAndRunsFromPackagedTemplateShape`, `.resetRemovesOnlySandboxOwnedDataAndLeavesTemplateUntouched`; `LocalLaravelTests.collectionsHelpersValidationAndViews` (collections, `validator`, `Str`, `Blade::render`), `.bootstrapsLaravelAndQueriesModels` (container resolution) | `RunletUITests.testSandboxRunShowsResultDumpsAndVersions`: a new tab with no project runs a collection snippet (result 12) with two dumps. `ScenarioUITests.testManyApplicationsInSeparateTabs`: sandbox tab returns `sandbox:13.34.0`. | Self-test `sandbox-install` and `sandbox-run-local` | The `Http` client is not exercised. Reset Sandbox is not driven from the UI. | Verified with gaps |
| M02 | Sandbox runtime | `SandboxManagerTests.chooseRuntimePrefersCompatibleLocalPHP` (compatible local PHP first, prerelease and tokenizer rules, unavailable reasons, unresponsive Docker); `DockerSandboxTests.sandboxRunsInDockerWithoutHostPHP` (falls back to Docker with no installations, runs in `php:8.4-cli`, writes persist in the host install, then the same data is visible with host PHP) | `ScenarioUITests.testSandboxInDocker` (sandbox runtime set to Docker: PHP 8.4, Laravel 13.34.0, `(Docker)` in the run header); every other sandbox UI test uses local PHP | Self-test `sandbox-run-local` and `sandbox-run-docker`, arm64 and Rosetta | The first-use image download explanation and **Download** button (`needsImage`) are not exercised, because the image was already present. No test ran on a machine without host PHP. | Verified with gaps |
| M03 | Local projects | `LocalRunTests.plainDirectoryIncludesRelativeFiles`, `.composerAutoloader`, `.missingVendorIsReportedAsBootstrapError`; `LocalLaravelTests.bootstrapsLaravelAndQueriesModels`, `.applicationSourceEditsAppearOnNextRun` | `ScenarioUITests.testManyApplicationsInSeparateTabs`: a Laravel project (service + model query → `$14.50`) and a Composer project (`Hi, Runlet!`); a project file edit is visible on the next run (`edit-one`, then `edit-two`) | None | The **Open Project…** directory picker is not driven (projects are seeded). A plain directory is not run from the UI. | Verified with gaps |
| M04 | PHP selection | `PHPDiscoveryTests.discoverFindsHostPHP` (PATH default first), `.inspectRejectsNonPHPExecutables`, `.preferredSkipsPrereleasesAndRespectsMinimum`; `LocalRunTests.runsOnPHP74` (explicit binary per target, version reported); `SandboxManagerTests.chooseRuntimePrefersCompatibleLocalPHP` (an incompatible preference is not used) | The status bar shows the active PHP version after a run (`testSandboxRunShowsResultDumpsAndVersions`) | Self-test discovers host PHP 8.4.25 | Settings ▸ PHP (global default) and the per-project override (`ProjectSettingsSheet`) are not driven; no UI test runs a project with a non-default PHP. | Partially verified |
| M05 | Existing Docker applications | `DockerRunTests.discoversFixtureContainersWithComposeLabels`, `.runsLaravelInsideContainerWithItsEnvironment`, `.explicitUserOverride`, `.restrictedNonRootReadOnlyContainer`; `ContainerListingTests.listingToleratesContainerRemovedBetweenPsAndInspect` | `ScenarioUITests.testDockerProfilesRunAndStop`: Compose-identified profiles run in the `laravel` container (its `FIXTURE_SERVICE` environment and SQLite data) and in the restricted container | None | Listing and selecting a container, and setting the directory and PHP, in the Docker profile editor (profiles are seeded). | Verified with gaps |
| M06 | Saved Docker profiles | `PersistenceTests.dockerProfileValidation`, `.roundTripsWithVersionedEnvelope` (store mechanics); `DockerDirectoryTests` and `DockerDirectoryFixtureTests` (Browse… for the working directory: listing, `docker exec` command line, failure messages, which container is listed; the `laravel` and `restricted` fixtures) | `ScenarioUITests.testTargetSwitcherSearchesProfiles`: ⌘P search `catal` leaves one of two saved profiles; Return switches the tab to it; nothing runs. `testDockerProfilesRunAndStop` reopens saved profiles with user and temporary directory. | None | Creating, editing, and saving a profile in the editor. No test saves and reloads `TargetLibrary` or unit-tests `matchesSearch`. The local source mapping field is not exercised. Browse… was checked in a Debug build against fixture containers ([#112](https://github.com/filipac/runlet/pull/112)), not by a UI test. | Partially verified |
| M07 | Container recreation | `ComposeRecreationTests.recreatedComposeServiceResolvesToReplacementAndNameOnlyNeedsConfirmation` (real `docker compose up --force-recreate`: Compose identity resolves to the replacement, a run snapshotted against the old container fails at launch, a name-only identity needs confirmation); `ResolverTests` (4); `DockerRunTests.resolvesComposeIdentityAndAmbiguousReplicas`, `.refusesToRunInRemovedContainer` | None | None | The container-choice sheet shown for ambiguous or name-only matches. | Verified with gaps |
| M08 | Native multiline editor | None (app code) | All UI tests type into the AppKit editor (`code-editor`) with real key events, select all and delete, and select with the keyboard (`testRunSelectionOnly`). Code survives tab switches (`testManyApplicationsInSeparateTabs`, `testRestartRestoresTabsWithoutRunning`). Return accepts a completion (`testCompletionPopupForTaglessSnippet`). Debug step `editor-check` ([#113](https://github.com/filipac/runlet/issues/113)): only the pair at the caret is highlighted after typing after a bracket, deleting one, undo and redo, and edits elsewhere, on an off-screen editor. The same step ([#114](https://github.com/filipac/runlet/issues/114)): text loaded, inserted, or reloaded into an empty editor, loaded after a settings change, inserted at the end, or put back by undo and redo has the editor's font, paragraph style, and color, and the same line heights as a newly opened editor | None | Highlighting, auto-indentation, bracket pairing, comment toggle, find and replace, undo and redo, and input methods have no automated assertions. | Partially verified |
| M09 | Run actions | `LocalRunTests.runtimeErrorInSelectionMapsToEditorLine` | ⌘R in every UI test; ⇧⌘R runs only the selection (`testRunSelectionOnly`: the unselected `throw` does not run, result 42). The run header names the target (`output-header` contains `Fixture Laravel`, `Fixture Composer`, `Sandbox`, `Fixture App`, `(Docker)`). | None | Toolbar Run and Run Selection buttons are not clicked (shortcuts are used). | Verified |
| M10 | PHP output | `LocalRunTests.finalExpressionAndEcho`, `.resultSemantics`, `.dumpsKeepExecutionOrderAndDDTerminates`, `.outputRobustness` (stderr), `.exitCodeIsReported` | `testSandboxRunShowsResultDumpsAndVersions` (two dump cards and the final value); `ScenarioUITests.testOutputModesAndTable` (`echo` in Raw, dump in Plain); `testDockerProfilesRunAndStop` (dump of an environment variable) | Self-test runs show the final value | `var_dump`, `dd`, and stderr rendering are not asserted in the UI. | Verified with gaps |
| M11 | Structured inspection | `LocalRunTests.outputRobustness` (object cycle marked `repeated`, 500 elements cut to 200, invalid UTF-8 sent as base64); `PersistenceTests.valueNodeDecodingAndPlainText`; `ValueTableTests` (3) | `testOutputModesAndTable`: a list-of-rows result switches to the Table view (`value-table`) | None | The depth limit (8) and 2 MiB budget are untested. Expanding nested or cyclic values in the UI is not asserted. | Verified with gaps |
| M12 | Errors | `LocalRunTests.parseErrorMapsToLineAndRecovers`, `.runtimeErrorInSelectionMapsToEditorLine` (line and column), `.missingVendorIsReportedAsBootstrapError`, `.fatalErrorIsReported`, `.strictTypesNamespacesAndDeclarations`, `.launchFailureProducesSingleFinished`; `DockerRunTests.refusesToRunInRemovedContainer` | `RunletUITests.testErrorsMapToLinesAndRecover`: an error card with a `line 2` link, then the corrected snippet runs (result 3). Debug step `editor-check` ([#87](https://github.com/filipac/runlet/issues/87)): the failed line's red background clears after typing above or inside it, deleting it, undo and redo, and a new failure, on an off-screen editor; bracket matches and syntax colors stay | None | Runtime and bootstrap errors are not asserted in the UI (only a parse error). `editor-check` is a Debug-build step, not part of the UI test run. | Verified with gaps |
| M13 | Cancellation | `LocalRunTests.stopTerminatesLocalRunAndChildren`; `DockerRunTests.stopKillsRunnerButNotContainer` (root and restricted containers: runner gone, container running, under 5 s); `DockerSandboxTests.stopEndsDockerSandboxRunAndRemovesItsContainer`, `.stopRightAfterLaunchStopsSandboxContainer` (Stop before the container exists, `sleep` and busy loop) | `RunletUITests.testStopLongRunningRun` (local: ⌘. ends as Stopped in under 6 s, then the editor runs again); `ScenarioUITests.testDockerProfilesRunAndStop` (restricted container: Stopped in under 6 s, no "may still be running" warning, the container serves the next run) | None | Docker sandbox Stop from the UI. Processes a snippet spawns inside an existing container are not guaranteed to stop (known limitation, untested). | Verified with gaps |
| M14 | Tabs | `LocalRunTests.secondRunInSameTabIsRejectedButOtherTabsRunConcurrently` | ⌘T creates a tab (`testRestartRestoresTabsWithoutRunning`); switching between three tabs with different targets keeps each tab's code and results (`testManyApplicationsInSeparateTabs`, two rounds) | None | Rename, duplicate, close, and close other tabs are not driven. | Partially verified |
| M15 | Session persistence | `PersistenceTests.roundTripsWithVersionedEnvelope`, `.corruptFileIsPreservedAndLastGoodIsRestored`, `.newerSchemaIsNotSilentlyOverwritten`, `.settingsTolerateMissingKeys` | `RunletUITests.testRestartRestoresTabsWithoutRunning`: after quit and relaunch both tabs and their code are back and no run output appears. Every `ScenarioUITests` test starts from a saved session with local, Docker, or sandbox targets. | None | The recovery alert for a corrupt state file is not shown in a UI test. A target changed in the UI is not checked after relaunch. | Verified with gaps |
| M16 | Execution history | None (app-layer logic) | `ScenarioUITests.testHistoryAndSnippetsPersist`: a run appears in history (⌘Y); double-clicking restores its code without running; history survives relaunch | None | Search, delete, clear, the retention limit, and status display. | Partially verified |
| M17 | Personal snippets | None (app-layer logic) | `testHistoryAndSnippetsPersist`: ⌥⌘S saves a labeled snippet; it is listed after relaunch (⇧⌘L) | None | Editing, searching, opening a snippet into a tab, and the visible target association. | Partially verified |
| M18 | PHPantom editor intelligence | `PHPantomTests.taglessScratchCompletionUsesProjectRootWithoutWritingFiles`, `.importEditsMapBackToEditorCoordinates`, `.hoverSignatureHelpAndDiagnosticRangesWithUnicode`, `.workspacesAreIsolatedAndRespectProjectConfiguration`, `.crashedServerRestartsAndRestoresDocuments`; `MappingTests` (4); `LaravelCompletionTests` (15); `RapidEditTests.latestDiagnosticsReflectFinalText` | `RunletUITests.testCompletionPopupForTaglessSnippet`: the completion list appears for a tagless `array_ma`, and Return inserts `array_map` | Self-test `phpantom-completion` | Hover and signature popups, diagnostic underlines, and gutter markers in the window. A completion's `use` import applied in the editor. Mapped Docker source (it uses the same project-workspace path). | Verified with gaps |
| M19 | Completion without host PHP | `PHPantomTests.runsWithoutHostPHPOnPath`, `.basicWorkspaceOffersCorePHPCompletion`, `.externalAnalyzersAreNotLaunchedImplicitly` | None | Self-test `phpantom-completion` starts the bundled universal binary from `Contents/Helpers` with `PATH=/usr/bin:/bin` (arm64 and Rosetta) | `LanguageWorkspace.sourceLimitations()` (missing source or `vendor/`) and its "PHPantom (limited)" status have no test. The basic-workspace fallback for a Docker profile without source is not shown in a UI test. | Verified with gaps |
| M20 | Basic preferences | `PersistenceTests.settingsTolerateMissingKeys` | The output display mode picker (`testOutputModesAndTable`). A seeded `sandboxRuntime` setting is honored (`testSandboxInDocker`). | None | Appearance, font size, indentation, output-pane layout and resizing, default PHP, and default target are not asserted. The visual tour opens every Settings tab but asserts nothing. | Partially verified |
| M21 | Copy and files | `PersistenceTests.valueNodeDecodingAndPlainText` (plain-text rendering used by Copy Output) | `ScenarioUITests.testOpenEditAndSaveFileWithoutRunning`: a `.php` file passed at launch opens in a tab, ⌘S writes the edit, and neither opening nor saving runs it (its marker file is never created) | None | Copy Output (pasteboard) is not asserted. The Open PHP File and Save As panels are not driven. | Partially verified |
| M22 | Run status | `LocalRunTests.finalExpressionAndEcho` (one last `finished`), `LocalLaravelTests.bootstrapsLaravelAndQueriesModels` (framework version), `LocalRunTests.runsOnPHP74` (PHP version), `DockerRunTests.stopKillsRunnerButNotContainer` (`cancelled`); every `finished` carries `elapsedMs` | The status bar shows `PHP …` and `Laravel 13.34.0` after a run (`testSandboxRunShowsResultDumpsAndVersions`); a stopped run ends as `Stopped` (`testStopLongRunningRun`, `testDockerProfilesRunAndStop`) | Self-test reports PHP and Laravel versions | The running indicator with elapsed time and the failed state in the status bar are not asserted. | Verified with gaps |

## End-to-end acceptance scenarios

| # | Scenario | CLI/test evidence | Desktop evidence (UI tests) | Packaged evidence | Not yet evidenced | Status |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Sandbox | `SandboxManagerTests.runsLaravelInInstalledSandboxWithLocalPHP`, `LocalLaravelTests.collectionsHelpersValidationAndViews` | `RunletUITests.testSandboxRunShowsResultDumpsAndVersions`: launch without a project, collection result 12, two dump cards, PHP and Laravel 13.34.0 in the status bar | Self-test `sandbox-install`, `sandbox-run-local` | — | Verified |
| 2 | Native Laravel | `LocalLaravelTests.bootstrapsLaravelAndQueriesModels`, `.applicationSourceEditsAppearOnNextRun`; `LocalRunTests.runsOnPHP74` (a target's own PHP binary) | `ScenarioUITests.testManyApplicationsInSeparateTabs`: resolves `PriceFormatter` from the container, queries `Widget` through a scope (`$14.50`), and shows a project edit on the next run | None | Opening the project through the directory picker and choosing its PHP binary in the UI | Verified with gaps |
| 3 | Composer | `LocalRunTests.composerAutoloader`, `.runsOnPHP74` | `testManyApplicationsInSeparateTabs`: `(new Acme\Greeter('Hi'))->greet('Runlet')` → `Hi, Runlet!` | None | Opening the project through the directory picker | Verified with gaps |
| 4 | Docker | `DockerRunTests.runsLaravelInsideContainerWithItsEnvironment` (environment variable, SQLite data, collection result) | `ScenarioUITests.testDockerProfilesRunAndStop`: a saved Compose profile runs with the container's environment and data | None | Choosing the container and directory in the profile editor, and saving and reopening a profile through the UI (profiles are seeded). The UI test returns an imploded string rather than inspecting a collection. | Partially verified |
| 5 | Many applications | `LocalRunTests.secondRunInSameTabIsRejectedButOtherTabsRunConcurrently`. Runs are bound to a `TargetSnapshot` taken at Run time. | `testManyApplicationsInSeparateTabs`: Laravel, Composer, and sandbox tabs, two rounds of switching; each result and run-header label belongs to its own tab and never shows another tab's result. `testDockerProfilesRunAndStop` switches between two Docker tabs. | None | Local and Docker tabs switched in the same session | Verified with gaps |
| 6 | Container recreation | `ComposeRecreationTests.recreatedComposeServiceResolvesToReplacementAndNameOnlyNeedsConfirmation` (real `--force-recreate`), `ResolverTests` (4), `DockerRunTests.resolvesComposeIdentityAndAmbiguousReplicas` | None | None | Reopening the profile in the app and the container-choice sheet when the match is ambiguous | Verified with gaps |
| 7 | Restricted container | `DockerRunTests.restrictedNonRootReadOnlyContainer` (uid 1000, read-only root and `/app`, `TMPDIR=/scratch`, `tempnam` works), `.explicitUserOverride`, `.stopKillsRunnerButNotContainer` | `testDockerProfilesRunAndStop`: the profile with user `1000:1000` and temporary directory `/scratch` prints `1000 7.4` and runs a class from the read-only mount | None | — | Verified |
| 8 | Selection and errors | `LocalRunTests.runtimeErrorInSelectionMapsToEditorLine` (line, and column on the selection's first line), `.parseErrorMapsToLineAndRecovers` | `RunletUITests.testRunSelectionOnly`, `.testErrorsMapToLinesAndRecover` (parse error linked to line 2, fixed, rerun) | None | A runtime error inside a selection, shown at the right editor line in the UI | Verified with gaps |
| 9 | Stop | `LocalRunTests.stopTerminatesLocalRunAndChildren`, `DockerRunTests.stopKillsRunnerButNotContainer`, `DockerSandboxTests.stopEndsDockerSandboxRunAndRemovesItsContainer`, `.stopRightAfterLaunchStopsSandboxContainer` | `RunletUITests.testStopLongRunningRun` (local), `ScenarioUITests.testDockerProfilesRunAndStop` (Docker, container keeps serving runs) | None | Docker sandbox Stop from the UI. Children a snippet spawns inside an existing container. | Verified with gaps |
| 10 | Recovery | `PersistenceTests.roundTripsWithVersionedEnvelope`, `.corruptFileIsPreservedAndLastGoodIsRestored`, `.newerSchemaIsNotSilentlyOverwritten` | `RunletUITests.testRestartRestoresTabsWithoutRunning` (tabs and code restored, nothing runs); `ScenarioUITests.testHistoryAndSnippetsPersist` (history and snippets after relaunch; restoring history does not run code); saved profiles are reloaded on every scenario launch | None | — | Verified |
| 11 | Output robustness | `LocalRunTests.outputRobustness` (cycles, invalid UTF-8 and binary bytes, a forged frame, large arrays, several dumps, stderr), `.largeOutputIsBoundedWithoutDeadlock`, `.dumpsKeepExecutionOrderAndDDTerminates`, all five `FrameDecoderTests` | Several dumps in order (`testSandboxRunShowsResultDumpsAndVersions`); Raw, Plain, and Structured modes (`testOutputModesAndTable`) | None | Cyclic, binary, large, and `dd` output inspected in the window | Verified with gaps |
| 12 | Docker-only setup | `DockerSandboxTests.sandboxRunsInDockerWithoutHostPHP`; `PHPantomTests.runsWithoutHostPHPOnPath`, `.basicWorkspaceOffersCorePHPCompletion`, `.externalAnalyzersAreNotLaunchedImplicitly`; existing-container runs use only the Docker CLI (`DockerRunTests`) | `ScenarioUITests.testSandboxInDocker`; `testDockerProfilesRunAndStop` | Self-test `sandbox-run-docker` and `phpantom-completion` (`PATH=/usr/bin:/bin`), arm64 and Rosetta | A full run on a machine with no host PHP at all (host PHP was installed but not used for these runs). The fallback explanation for a Docker profile without mapped source. | Verified with gaps |
| 13 | Unsaved scratch intelligence | `PHPantomTests.taglessScratchCompletionUsesProjectRootWithoutWritingFiles`, `.importEditsMapBackToEditorCoordinates`, `.hoverSignatureHelpAndDiagnosticRangesWithUnicode`; `MappingTests` (4); `RapidEditTests.latestDiagnosticsReflectFinalText` (31 rapid edits: the last diagnostics describe the final text and version) | `RunletUITests.testCompletionPopupForTaglessSnippet` | Self-test `phpantom-completion` | Hover, signature help, diagnostic ranges, and import edits shown in the window. `LanguageBinding`'s dropping of older-version diagnostics has no isolated test. | Verified with gaps |
| 14 | Language-service isolation and recovery | `PHPantomTests.workspacesAreIsolatedAndRespectProjectConfiguration` (conflicting `App\Thing` classes, PHP target 8.2 in one workspace, project `.phpantom.toml` unchanged), `.crashedServerRestartsAndRestoresDocuments` | None | None | Tabs from two projects in the window. Running a snippet while PHPantom restarts (separate processes, but untested). | Partially verified |
| 15 | Laravel completion | `LaravelCompletionTests` (16): facades, scopes, builder chains, relations (every declaration style), casts, attributes, collection element types, helpers, `config()` keys, signature help, provider macros, and the in-memory model copies; `EloquentOverlayTests` (12) for the copies themselves; `PHPantomTests.taglessScratchCompletionUsesProjectRootWithoutWritingFiles`. Rerun on 2026-10-03 for [#55](https://github.com/filipac/runlet/issues/55). Results and unsupported cases are in [compatibility.md](compatibility.md#laravel-completion-scenario-15-phpantom-0100-laravel-13340). | None for Laravel cases | None | Unsupported in PHPantom 0.10.0: element types after `keyBy()`/`groupBy()` on Eloquent collections ([#117](https://github.com/filipac/runlet/issues/117)). Relations with only a native `HasMany`-style return type and the last `casts()` entry without a trailing comma work through Runlet's model copies; the tests also pin PHPantom's own behavior without them. Provider macros were already supported (the earlier test workspace lacked `bootstrap/providers.php`). Not run against a real user application (local or Docker); the fixture is the sandbox template plus fixture models. | Verified with gaps |

## Open gaps from the historical validation snapshot

All gaps below (and the unverified table sub-items) are tracked by [#54](https://github.com/filipac/runlet/issues/54) unless a more specific issue is linked. They must be rechecked against newer source/tests before being treated as still absent.

- **Signing and notarization** ([#24](https://github.com/filipac/runlet/issues/24)). `scripts/package.sh` supports a Developer ID identity (`RUNLET_SIGN_IDENTITY`) and notarization (`RUNLET_NOTARY_PROFILE`), but neither has been run; it needs a Developer ID certificate. The current package is ad-hoc signed and was verified only on the build machine (arm64 natively and x86_64 under Rosetta). No Intel Mac was tested.
- **Packaged app in the UI.** The packaged evidence is the headless self-test. No test launches `dist/Runlet.app` from Finder or drives its window; the UI tests drive the Debug build.
- **Snippet child processes in containers.** Stop in an existing container signals the runner PID only. Processes a snippet spawns inside the container are not guaranteed to stop, and no test covers them. Local Stop is tested with a child process (it signals the process group). The Docker sandbox stops its whole Runlet-owned container, but no test spawns a child there.
- **Laravel completion gaps** ([#117](https://github.com/filipac/runlet/issues/117)) (scenario 15, PHPantom 0.10.0): `keyBy()` and `groupBy()` on Eloquent collections lose the element type. Native-typed relations and the last `casts()` entry without a trailing comma are worked around by Runlet's model copies until PHPantom fixes them ([#55](https://github.com/filipac/runlet/issues/55)). See [compatibility.md](compatibility.md#phpantom-upstream-report-drafts).
- **Dogfooding.** No acceptance scenario has been run against the user's own Laravel, Composer, or Docker applications; all evidence uses the fixtures.
- **UI coverage gaps** listed in the tables: tab rename/duplicate/close, the Docker profile editor, the container-choice sheet, Copy Output, the Open/Save panels, hover/signature/diagnostic popups, preferences other than the output mode and sandbox runtime, and history/snippet search and editing.
- **Untested code.** `LanguageWorkspace.sourceLimitations()`, `matchesSearch`, `TargetLibrary` save and reload, and the `Http` client in the sandbox have no tests.
- **Latency.** Package-test and self-test timings are recorded; latency in the rendered app is not measured.

Resolved since the previous version of this file: Stop before launch now finishes as `cancelled`; selection errors map columns on the selection's first line; the Docker profile's temporary directory is passed as `TMPDIR`; `SandboxManager`, `DockerSandboxAdapter`, and `PHPDiscovery` have tests; a real Compose recreation is tested; history, snippets, file open and save, and Copy Output are implemented.
