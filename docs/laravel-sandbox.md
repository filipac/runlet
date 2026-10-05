# Laravel Sandbox

The Laravel Sandbox is a fresh Laravel application bundled with Runlet, ready in the first tab. Use it to try Laravel's APIs, Eloquent, collections, or a package's idea without opening a project. It needs no setup and no database server: it runs on SQLite.

```php
use App\Models\User;

User::factory()->count(3)->create();

User::query()->latest()->pluck('email');
```

## What's Inside

The sandbox is Laravel 13.34.0, with:

- **A SQLite database,** already migrated: the `users`, `cache`, and `jobs` tables, with the `User` model and its factory.
- **Settings for trying things:** `APP_ENV=local` with debug on, array sessions, the file cache, the `sync` queue (jobs run at once, in the run), and the `log` mailer (mail goes to the log, not to anyone).
- **Its own random `APP_KEY`,** made when Runlet installs the sandbox on your Mac.

Snippets get `$app`, as in any Laravel project, and everything that works in a Laravel project works here: the [run inspector](driver-inspector.md) records the queries, mail, and logs, an [SQL tab](sql-tabs.md) on the sandbox opens its SQLite database, and the Commands panel lists its Artisan commands. **Open REPL** opens Tinker.

The sandbox is always a development target: it can't be marked as staging or production.

## Which PHP It Uses

The sandbox needs PHP 8.3 or later with the tokenizer extension, or Docker. Choose in **Settings ▸ Sandbox ▸ Run sandbox with**:

| Option | What runs the sandbox |
| --- | --- |
| **Automatic** (the default) | A compatible PHP on your Mac, else a disposable Docker container. |
| **Local PHP** | A compatible PHP on your Mac only. |
| **Docker** | A disposable `php:8.4-cli` container, even when your Mac has PHP. |

On your Mac, the sandbox prefers the default PHP from **Settings ▸ PHP** when it is 8.3 or later, then the first compatible PHP Runlet found (the `php` on your `PATH` first, stable releases before betas). [Runlet's own PHP](local-projects.md#choosing-php) comes last, so PHP you installed always wins.

In Docker, each run starts a new container with the sandbox mounted, and removes it afterwards. The first Docker run needs the image, a one-time download of a few hundred megabytes: Runlet offers **Download Docker Image**, and reuses the image for every run after that.

## Resetting the Sandbox

To start over, choose **Reset Sandbox…** in the target menu, or in **Settings ▸ Sandbox**. Runlet deletes the sandbox's own data (its SQLite database, cache, sessions, logs, and compiled views) and puts back a fresh copy of Laravel. Your projects, Docker and SSH targets, snippets, and history are not touched.

**Settings ▸ Sandbox ▸ Location** shows where the sandbox lives on your Mac, with **Reveal in Finder**.

> [!NOTE]
> Each Laravel version of the sandbox has its own folder. When a Runlet update brings a newer Laravel, the sandbox starts fresh, and what you created in the old one stays in its old folder.

## Auto-Run

In a sandbox tab, Runlet can run the whole tab each time you stop typing. Click **Auto-run** in the toolbar to turn it on for that tab: the button reads **AUTO** while it's on. Click it again to turn it off.

![Sandbox auto-run turned on, with nothing run yet](screenshots/sandbox-auto-run-idle.png)

Turning auto-run on doesn't run the code that's already in the editor. Your next edit does:

- **800 ms after your last edit,** Runlet runs the whole tab, whatever is selected, and whatever Run prefers.
- **Runs never overlap.** An edit during a run waits for it to finish, then the latest code runs.
- **Run and Run Selection** cancel the pending automatic run and run as usual.
- **Stop** stops the current run and cancels the pending one.
- **Empty code doesn't run,** and errors show in the output as usual: fix the code, and the next edit runs it again.

![A sandbox auto-run's result, refreshed after an edit](screenshots/sandbox-auto-run-light.png#gh-light-mode-only)
![A sandbox auto-run's result, refreshed after an edit](screenshots/sandbox-auto-run-dark.png#gh-dark-mode-only)

### When Auto-Run Turns Off

Auto-run belongs to one tab and starts off. It turns off when the tab's code is replaced, and it is never saved:

- New, duplicated, and reopened tabs, tabs restored with your session, and tabs from a workspace start with it off.
- Loading code from History, a snippet, an import, or a file on disk turns it off.
- Switching the tab's target turns it off, even when you switch back to the sandbox. Switching the tab to SQL turns it off too.

Auto-run is only for the sandbox. Local projects, Docker and SSH targets, production targets, and SQL tabs don't have it.

> [!WARNING]
> Only your edits trigger an automatic run: opening, restoring, or selecting a tab never does. But sandbox code can still have side effects, such as writing files or calling HTTP APIs. Read the code before you turn auto-run on.

## For developers

The sandbox:

- **Template.** `Resources/Sandbox/laravel` holds Laravel 13.34.0 (`^8.3`). `scripts/build-sandbox.sh` installs its locked dependencies and builds the pre-migrated SQLite database on the build machine; `scripts/embed-resources.sh` copies it into the app without `.env`, `tests/`, logs, compiled views, and caches (so the sandbox has no Tests group). `runlet-sandbox.json` records `laravelVersion`, `phpConstraint`, `minimumPHP` (8.3), and `dockerImage` (`php:8.4-cli`).
- **Install and reset.** `SandboxManager.ensureInstalled()` (RunletExecution) copies the template into `Sandbox/laravel-<version>/` under Runlet's data folder through a staging folder, writes the `.env` (`SandboxManager.environmentFile()`), creates the storage folders, and writes a `.runlet-installed` marker. `reset()` deletes only that folder and installs it again. More in [Architecture ▸ Laravel sandbox](architecture.md#laravel-sandbox).
- **Runtime.** `SandboxManager.chooseRuntime` follows `SandboxRuntimePreference` (`automatic`, `localPHP`, `docker`). Docker runs use `DockerSandboxAdapter`: `docker run --rm -i --init` with the label `dev.runlet.owned=sandbox` and the sandbox mounted at `/sandbox`; Stop kills that container ([Architecture ▸ Cancellation](architecture.md#cancellation-stop)).

Auto-run was implemented under [#30](https://github.com/filipac/runlet/issues/30) (this page replaces `sandbox-auto-run.md`, which now points here):

- `TabModel` keeps the opt-in and the cancellable 800 ms task outside `TabState`, so sessions and workspaces never store it; `EditorController` marks programmatic loads apart from editor edits; `AppModel` cancels pending work on Run, Stop, and close, and checks again across asynchronous preparation that the tab is still a sandbox tab. The delay uses Swift's cancellable [Task.sleep](https://developer.apple.com/documentation/swift/task/sleep(for:tolerance:clock:)).
- An AI client's run (MCP) keeps its `RunObserver` callbacks and disarms a pending auto-run when an explicit run begins.
- **Validation** (2026-10-03, the Debug app with the sandbox on local PHP): six `SandboxAutoRunUITests` scenarios plus the Run Selection and Stop scenarios, and the `ProductionGuardTests` package tests, also after merging the REPL work and MCP. The native scenarios cover opt-in without an immediate run, rapid edits coalescing, full-tab evaluation with a selection, Run cancelling a pending evaluation, turning it off, per-tab state, session restore, queued edits without overlap (checked with a PHP file lock), Stop, close, and reopen, disk reloads, loading History into an enabled tab, target eligibility and reset, and the production confirmation. They use a scratch `RUNLET_DATA_DIR`, real editor events, and PHP marker files rather than the toolbar alone. Docker and SSH tabs were checked for the option's absence; the Docker-backed sandbox and workspace import weren't run in that pass (workspace and session tabs are built from `TabState`, which has no opt-in). After merging MCP, 19 production and MCP policy and report tests passed, and `scripts/mcp-e2e/driver.py` passed all 31 checks.

Reproduce the UI checks after `xcodegen generate`:

```sh
xcodebuild -project Runlet.xcodeproj -scheme Runlet -configuration Debug \
  -derivedDataPath build/DerivedData \
  -only-testing:RunletUITests/SandboxAutoRunUITests \
  -only-testing:RunletUITests/RunletUITests/testRunSelectionOnly \
  -only-testing:RunletUITests/RunletUITests/testStopLongRunningRun test
```

```sh
swift test --package-path Packages/RunletKit --filter ProductionGuardTests
```
