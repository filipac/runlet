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

In a sandbox tab, Runlet can run the whole tab each time you stop typing: click **Auto-run** in the toolbar to turn it on for that tab. It's off by default, never runs the code that's already there, and only the sandbox has it. See [Sandbox Auto-Run](sandbox-auto-run.md).

## For developers

The sandbox:

- **Template.** `Resources/Sandbox/laravel` holds Laravel 13.34.0 (`^8.3`). `scripts/build-sandbox.sh` installs its locked dependencies and builds the pre-migrated SQLite database on the build machine; `scripts/embed-resources.sh` copies it into the app without `.env`, `tests/`, logs, compiled views, and caches (so the sandbox has no Tests group). `runlet-sandbox.json` records `laravelVersion`, `phpConstraint`, `minimumPHP` (8.3), and `dockerImage` (`php:8.4-cli`).
- **Install and reset.** `SandboxManager.ensureInstalled()` (RunletExecution) copies the template into `Sandbox/laravel-<version>/` under Runlet's data folder through a staging folder, writes the `.env` (`SandboxManager.environmentFile()`), creates the storage folders, and writes a `.runlet-installed` marker. `reset()` deletes only that folder and installs it again. More in [Architecture ▸ Laravel sandbox](architecture.md#laravel-sandbox).
- **Runtime.** `SandboxManager.chooseRuntime` follows `SandboxRuntimePreference` (`automatic`, `localPHP`, `docker`). Docker runs use `DockerSandboxAdapter`: `docker run --rm -i --init` with the label `dev.runlet.owned=sandbox` and the sandbox mounted at `/sandbox`; Stop kills that container ([Architecture ▸ Cancellation](architecture.md#cancellation-stop)).

Auto-run, which runs a sandbox tab as you type, has its own page: [Sandbox Auto-Run](sandbox-auto-run.md).
