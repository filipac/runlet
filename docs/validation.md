# Validation evidence

`plan.md` asks for a requirement-to-evidence table for M01–M22 and for the end-to-end acceptance scenarios. It also asks to keep CLI/test proof separate from rendered-desktop proof and packaged-app proof. This file covers all three.

Recorded 2026-10-02.

## Evidence types

| Type | Meaning | Current state |
| --- | --- | --- |
| **CLI/tests** | Swift Testing tests in `Packages/RunletKit/Tests`, run with `swift test`. They execute real PHP (local and in Docker containers) and the pinned PHPantom binary. No mocked execution. | 54 tests in 8 suites (see below) |
| **Desktop** | Behavior observed in the rendered native app built from `project.yml` | **None yet.** The app UI (`Runlet/`) is in progress, and `RunletUITests` has no tests. |
| **Packaged** | Behavior observed in an installed `.app`: resources resolved from the bundle, PHPantom started from `Contents/Helpers`, app launched from Finder | **None yet.** `scripts/package.sh` does not exist yet. |

## Status values

| Status | Meaning |
| --- | --- |
| Verified (CLI/tests) | Every part of the requirement that can be checked below the UI is covered by passing tests, and nothing UI-specific remains. |
| Partially verified | Some parts have test evidence. Other parts, beyond the UI, have none. |
| Pending app UI | The backend behavior is covered by tests. The rest depends on the native UI, which is not finished. |
| Pending | No evidence yet. |

These statuses come from the test sources and from the passing results recorded in [compatibility.md](compatibility.md) and `CHANGELOG.md`. Re-run the commands below to refresh them.

## Reproducing the evidence

One-time preparation. Run these from the repository root, in this order.

The Laravel fixture is copied from the built sandbox template, so build the sandbox first:

```bash
scripts/fetch-phpantom.sh
```

```bash
scripts/build-sandbox.sh
```

```bash
scripts/setup-fixtures.sh docker
```

Run the whole package suite:

```bash
cd Packages/RunletKit && swift test
```

Run one suite, for example the Docker tests:

```bash
cd Packages/RunletKit && swift test --filter DockerRunTests
```

Stop the disposable Docker fixtures afterwards:

```bash
docker compose -p runlet-fixtures down
```

Suites whose prerequisites are missing are **skipped, not failed**. A green run on a machine without Docker or PHP does not prove those paths, so check the output for skipped suites.

| Suite | Tests | Needs | If missing |
| --- | --- | --- | --- |
| `RunletCoreTests.PersistenceTests` | 6 | nothing | — |
| `RunletExecutionTests.FrameDecoderTests` | 5 | nothing | — |
| `RunletExecutionTests.ResolverTests` | 4 | nothing | — |
| `RunletExecutionTests.LocalRunTests` | 17 | host `php` (`runsOnPHP74` also needs Herd `php74`) | skipped |
| `RunletExecutionTests.LocalLaravelTests` | 3 | host PHP 8.3+ and `Tests/Fixtures/laravel-app/vendor` | skipped |
| `RunletExecutionTests.DockerRunTests` | 7 | a running Docker engine and the `runlet-fixtures` containers | skipped without Docker; **fails** if Docker runs but the fixtures are not started |
| `RunletLanguageTests.MappingTests` | 4 | nothing | — |
| `RunletLanguageTests.PHPantomTests` | 8 | `Resources/LSP/phpantom_lsp`. Two tests also use the Laravel fixture. | skipped without the binary; the two fixture tests fail without the fixture |

Fixture containers (`Tests/Fixtures/docker/compose.yml`):

- `laravel`: `php:8.4-cli`, root user, the Laravel fixture mounted at `/var/www/html`.
- `restricted`: `php:7.4-cli`, uid 1000, read-only root filesystem, read-only `/app` mount, writable tmpfs at `/scratch`.
- `replicas`: two replicas of `php:8.2-cli-alpine`.

Latency is recorded separately for native and Docker runs in [compatibility.md](compatibility.md). Laravel runs take about 90–140 ms locally and about 150–250 ms through `docker exec`. Latency has not been measured in the desktop or packaged app.

## Must-have capabilities (M01–M22)

Test names are `Suite.test`. "Desktop" and "Packaged" give the evidence of that type. Where they say "None", no such evidence exists yet.

| ID | Capability | CLI/test evidence | Not yet evidenced | Desktop | Packaged | Status |
| --- | --- | --- | --- | --- | --- | --- |
| M01 | Laravel sandbox | `LocalLaravelTests.collectionsHelpersValidationAndViews` (collections, `validator`, `Str`, `Blade::render`); `LocalLaravelTests.bootstrapsLaravelAndQueriesModels` (container resolution via `app()`, Laravel 13.34.0 reported). Both run against `Tests/Fixtures/laravel-app`, a copy of the pinned sandbox template. | No test runs `SandboxManager.ensureInstalled`/`reset` or runs code from the installed Application Support copy. HTTP client usage is not exercised. A new tab without a project depends on the UI. | None | None | Partially verified |
| M02 | Sandbox runtime | `DockerRunTests.runsLaravelInsideContainerWithItsEnvironment` runs the pinned Laravel version in `php:8.4-cli`, the fallback image, through `docker exec`. Local PHP selection is covered under M04. | `SandboxManager.chooseRuntime`, `DockerSandboxAdapter` (`docker run --rm`), and its `docker kill` Stop have no tests. There is no evidence yet for the first-use image download explanation (`SandboxRuntime.docker(imagePresent:)`). | None | None | Partially verified |
| M03 | Local projects | `LocalRunTests.plainDirectoryIncludesRelativeFiles`, `LocalRunTests.composerAutoloader`, `LocalRunTests.missingVendorIsReportedAsBootstrapError`, `LocalLaravelTests.bootstrapsLaravelAndQueriesModels`, `LocalLaravelTests.applicationSourceEditsAppearOnNextRun` | Directory picker (UI) | None | None | Pending app UI |
| M04 | PHP selection | `LocalRunTests.runsOnPHP74` (an explicit PHP binary per target; the reported version is checked) | `PHPDiscovery` (detection and validation) has no test. The global default and per-project override exist only as model fields (`AppSettings.defaultPHPExecutable`, `LocalProject.phpExecutable`). Version display is UI. | None | None | Partially verified |
| M05 | Existing Docker applications | `DockerRunTests.discoversFixtureContainersWithComposeLabels`, `DockerRunTests.runsLaravelInsideContainerWithItsEnvironment` (container environment variables and fixture database), `DockerRunTests.explicitUserOverride`, `DockerRunTests.restrictedNonRootReadOnlyContainer` (probe and run) | Container list, selection, and directory/PHP fields (UI) | None | None | Pending app UI |
| M06 | Saved Docker profiles | `PersistenceTests.dockerProfileValidation`; `PersistenceTests.roundTripsWithVersionedEnvelope` (store mechanics, tested with `SessionState`) | No test saves and reloads `TargetLibrary`. Profile search (`matchesSearch`) has no test. Save, search, and reopen are UI. | None | None | Partially verified |
| M07 | Container recreation | `ResolverTests.composeIdentitySurvivesRecreation`, `ResolverTests.replicasAreAmbiguous`, `ResolverTests.nameOnlyReplacementNeedsConfirmation`, `ResolverTests.stoppedContainersDoNotResolve`, `DockerRunTests.resolvesComposeIdentityAndAmbiguousReplicas`, `DockerRunTests.refusesToRunInRemovedContainer` | Recreation is simulated by changing `lastContainerId`. No test performs a real `docker compose up --force-recreate`. The replacement prompt is UI. | None | None | Pending app UI |
| M08 | Native multiline editor | None. The code exists in `Runlet/Editor/` (`CodeTextView`, `EditorController`, `PHPHighlighter`, `LineNumberRulerView`). | Highlighting, indentation, brackets, comments, find/replace, undo/redo, input methods, and state preserved across SwiftUI updates and tab switches | None | None | Pending app UI |
| M09 | Run actions | `LocalRunTests.runtimeErrorInSelectionMapsToEditorLine` (only the selection is submitted; its runner lines map to editor lines) | Run and Run Selection buttons, Cmd+R, and the visible target label (UI) | None | None | Pending app UI |
| M10 | PHP output | `LocalRunTests.finalExpressionAndEcho`, `LocalRunTests.resultSemantics`, `LocalRunTests.dumpsKeepExecutionOrderAndDDTerminates`, `LocalRunTests.outputRobustness` (stderr), `LocalRunTests.exitCodeIsReported` | No test asserts `var_dump` output specifically (it is plain stdout). Rendering is UI. | None | None | Pending app UI |
| M11 | Structured inspection | `LocalRunTests.outputRobustness` (object cycle marked `repeated`, a 500-element array cut to 200 children, invalid UTF-8 sent as base64); `PersistenceTests.valueNodeDecodingAndPlainText` | No test covers the depth limit (8) or the 2 MiB value budget. Expandable view is UI. | None | None | Pending app UI |
| M12 | Errors | `LocalRunTests.parseErrorMapsToLineAndRecovers`, `LocalRunTests.runtimeErrorInSelectionMapsToEditorLine`, `LocalRunTests.missingVendorIsReportedAsBootstrapError`, `LocalRunTests.fatalErrorIsReported`, `LocalRunTests.strictTypesNamespacesAndDeclarations` (`TypeError`), `LocalRunTests.launchFailureProducesSingleFinished`, `DockerRunTests.refusesToRunInRemovedContainer` | Showing errors with their source lines in the editor (UI) | None | None | Pending app UI |
| M13 | Cancellation | `LocalRunTests.stopTerminatesLocalRunAndChildren` (under 5 s; a background child of the snippet is gone). `DockerRunTests.stopKillsRunnerButNotContainer` runs on the root Laravel container and on the non-root, read-only PHP 7.4 container: the runner PID is gone, the container is still running, and Stop takes under 5 s. | Docker sandbox Stop (`docker kill`) has no test. A usable editor after Stop is UI. Known limitation: Docker Stop signals only the runner PID. | None | None | Pending app UI |
| M14 | Tabs | `LocalRunTests.secondRunInSameTabIsRejectedButOtherTabsRunConcurrently` (one run per tab, concurrent runs across tabs, events stay with their run) | Create, switch, rename, duplicate, and close tabs (UI) | None | None | Pending app UI |
| M15 | Session persistence | `PersistenceTests.roundTripsWithVersionedEnvelope` (tabs with code and target), `PersistenceTests.corruptFileIsPreservedAndLastGoodIsRestored`, `PersistenceTests.newerSchemaIsNotSilentlyOverwritten`, `PersistenceTests.settingsTolerateMissingKeys` | Restoring after an app restart without running code. Session-write debounce and flush on quit. | None | None | Pending app UI |
| M16 | Execution history | None. Only the `HistoryEntry` model exists. | Saving, search, restore without running, retention limit, clear history | None | None | Pending |
| M17 | Personal snippets | None. Only the `Snippet` model exists. | Save, label, edit, search, reopen, visible target association | None | None | Pending |
| M18 | PHPantom editor intelligence | `PHPantomTests.taglessScratchCompletionUsesProjectRootWithoutWritingFiles`, `PHPantomTests.importEditsMapBackToEditorCoordinates`, `PHPantomTests.hoverSignatureHelpAndDiagnosticRangesWithUnicode`, `PHPantomTests.workspacesAreIsolatedAndRespectProjectConfiguration`, `PHPantomTests.crashedServerRestartsAndRestoresDocuments`, `MappingTests.syntheticTagAddsOneLineWithoutShiftingColumns`, `MappingTests.existingOpenTagIsUsedAsIs`, `MappingTests.lineIndexUsesUTF16AndHandlesLineEndings`, `MappingTests.snippetSyntaxBecomesPlainText` | Completion, hover, and signature popups and diagnostic markers in the editor (UI). Mapped Docker source has no dedicated test (it uses the same project-workspace path). | None | None | Pending app UI |
| M19 | Completion without host PHP | `PHPantomTests.runsWithoutHostPHPOnPath`, `PHPantomTests.basicWorkspaceOffersCorePHPCompletion`, `PHPantomTests.externalAnalyzersAreNotLaunchedImplicitly` | `LanguageWorkspace.sourceLimitations()` (missing source or vendor messages) has no test. Showing those messages is UI. Starting PHPantom from `Contents/Helpers` is packaged-app only. | None | None | Pending app UI |
| M20 | Basic preferences | `PersistenceTests.settingsTolerateMissingKeys` (`AppSettings` holds appearance, font size, indentation, output layout, default PHP, and default target) | Settings UI, resizable output pane, applying the settings | None | None | Pending app UI |
| M21 | Copy and files | `PersistenceTests.valueNodeDecodingAndPlainText` covers the plain-text rendering only. | Copy output, open and save PHP files, and the rule that saving never runs code | None | None | Pending |
| M22 | Run status | `LocalRunTests.finalExpressionAndEcho` (sequence numbers, a single last `finished`), `LocalLaravelTests.bootstrapsLaravelAndQueriesModels` (framework version), `LocalRunTests.runsOnPHP74` (PHP version), `DockerRunTests.stopKillsRunnerButNotContainer` (`cancelled` status). Every `finished` event carries `elapsedMs`. | Ready, running, stopped, and failed status and elapsed time in the window (UI) | None | None | Pending app UI |

## End-to-end acceptance scenarios

| # | Scenario | CLI/test evidence | Not yet evidenced | Desktop | Packaged | Status |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Sandbox | `LocalLaravelTests.collectionsHelpersValidationAndViews` (collection/helper result, several dumps in order), `LocalLaravelTests.bootstrapsLaravelAndQueriesModels` (Laravel version), on a copy of the sandbox template | Launching without a project. The installed sandbox (`SandboxManager`). Showing the Laravel and PHP versions. | None | None | Partially verified |
| 2 | Native Laravel | `LocalLaravelTests.bootstrapsLaravelAndQueriesModels` (resolve a service, query fixture models), `LocalLaravelTests.applicationSourceEditsAppearOnNextRun`. Each target uses its own PHP binary (`LocalRunTests.runsOnPHP74`). | Opening the project and choosing its PHP in the UI | None | None | Pending app UI |
| 3 | Composer | `LocalRunTests.composerAutoloader`, `LocalRunTests.runsOnPHP74` | Opening the project in the UI | None | None | Pending app UI |
| 4 | Docker | `DockerRunTests.runsLaravelInsideContainerWithItsEnvironment` (container environment variable, SQLite fixture data, collection result) | Choosing the container and directory in the UI. Saving and reopening a profile (no persistence test for `TargetLibrary`). | None | None | Partially verified |
| 5 | Many applications | `LocalRunTests.secondRunInSameTabIsRejectedButOtherTabsRunConcurrently` (events stay with their run). Runs are bound to a `TargetSnapshot` taken at Run time. | Switching tabs repeatedly across local and Docker targets. Run labels in the UI. | None | None | Pending app UI |
| 6 | Container recreation | `ResolverTests.composeIdentitySurvivesRecreation`, `ResolverTests.nameOnlyReplacementNeedsConfirmation`, `ResolverTests.replicasAreAmbiguous`, `DockerRunTests.resolvesComposeIdentityAndAmbiguousReplicas` | A real Compose recreation (it is simulated). Reopening a saved profile. The selection prompt when the match is ambiguous. | None | None | Partially verified |
| 7 | Restricted container | `DockerRunTests.restrictedNonRootReadOnlyContainer` (uid 1000, read-only root filesystem and `/app`, `/scratch` writable according to the probe); `DockerRunTests.explicitUserOverride` (a configured `--user`); `DockerRunTests.stopKillsRunnerButNotContainer` (restricted container) | Configuring the user and temporary directory in a profile through the UI. The profile's temporary directory is probed but not used, because the runner writes no files. | None | None | Pending app UI |
| 8 | Selection and errors | `LocalRunTests.runtimeErrorInSelectionMapsToEditorLine`, `LocalRunTests.parseErrorMapsToLineAndRecovers` | Correct editor lines shown in the UI. Column mapping for selections that start mid-line is not implemented (only lines are offset). | None | None | Pending app UI |
| 9 | Stop | `LocalRunTests.stopTerminatesLocalRunAndChildren`, `DockerRunTests.stopKillsRunnerButNotContainer` | Stop from the UI. Docker sandbox Stop. Child processes of a snippet inside a container are not guaranteed to stop. | None | None | Pending app UI |
| 10 | Recovery | `PersistenceTests.roundTripsWithVersionedEnvelope`, `PersistenceTests.corruptFileIsPreservedAndLastGoodIsRestored`, `PersistenceTests.newerSchemaIsNotSilentlyOverwritten` | Restarting the app, history and snippets (not implemented), confirming that no code runs automatically | None | None | Partially verified |
| 11 | Output robustness | `LocalRunTests.outputRobustness` (cycles, invalid UTF-8 and binary bytes, a forged frame, large arrays, several dumps, stderr), `LocalRunTests.largeOutputIsBoundedWithoutDeadlock`, `LocalRunTests.dumpsKeepExecutionOrderAndDDTerminates` (`dd` ends with `finished`), and all five `FrameDecoderTests` | Inspecting these values in the UI | None | None | Pending app UI |
| 12 | Docker-only setup | `PHPantomTests.runsWithoutHostPHPOnPath`, `PHPantomTests.basicWorkspaceOffersCorePHPCompletion`, `PHPantomTests.externalAnalyzersAreNotLaunchedImplicitly`. Docker execution uses only the Docker CLI (`DockerRunTests`). | Running the sandbox through Docker (`DockerSandboxAdapter`, untested). A full run on a machine without host PHP (the tests ran on a machine that had PHP). The fallback message in the UI. | None | None | Partially verified |
| 13 | Unsaved scratch intelligence | `PHPantomTests.taglessScratchCompletionUsesProjectRootWithoutWritingFiles`, `PHPantomTests.importEditsMapBackToEditorCoordinates`, `PHPantomTests.hoverSignatureHelpAndDiagnosticRangesWithUnicode`, all four `MappingTests` | Ignoring stale diagnostics during rapid edits (`LanguageBinding` drops older versions, untested). Applying edits in the editor. | None | None | Partially verified |
| 14 | Language-service isolation and recovery | `PHPantomTests.workspacesAreIsolatedAndRespectProjectConfiguration` (conflicting `App\Thing` classes, PHP target 8.2 for one workspace, project `.phpantom.toml` unchanged), `PHPantomTests.crashedServerRestartsAndRestoresDocuments` | Tabs from two projects in the UI. Running a snippet while PHPantom restarts (the two are separate processes, but this is not tested). | None | None | Pending app UI |
| 15 | Laravel completion | `PHPantomTests.taglessScratchCompletionUsesProjectRootWithoutWritingFiles` (model attributes from migrations, builder chain, model methods), `PHPantomTests.importEditsMapBackToEditorCoordinates` (class import). Results are in [compatibility.md](compatibility.md). | Facade calls, scopes, casts, and collection element types. A real local or Docker application rather than the fixture. | None | None | Partially verified |

## Gaps found while compiling this table

- **Stop before launch.** If Stop arrives before the PHP process launches, the run finishes as `failed` / `launch-failed`, not `cancelled`.
- **Unused temporary directory.** `DockerProfile.temporaryDirectory` is validated and probed but never passed to `docker exec`, because the runner writes no files.
- **Selection columns.** `SourceSelection.startColumn` is not used for error mapping, so errors on the first line of a selection that starts mid-line report snippet-relative columns.
- **Untested components.** `SandboxManager`, `DockerSandboxAdapter`, `PHPDiscovery`, and `LanguageWorkspace.sourceLimitations()` have no tests.
- **Not implemented.** History, snippets, file open/save, and copy output have models or helpers but no implementation or tests.
- **Stale test count.** `CHANGELOG.md` mentions 32 passing integration tests. The suite now has 54 tests.
