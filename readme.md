# Runlet

> **Early preview.** Runlet was built quickly with AI assistance. Expect rough edges, and please [report issues](https://github.com/filipac/runlet/issues).

A native macOS scratchpad for PHP: run snippets against a bundled Laravel sandbox, your local projects, Docker containers, or servers over SSH, and see structured results, SQL queries, mail, and logs. Free and open source (MIT).

## Features

- **Run anywhere:** a bundled Laravel sandbox (local PHP or a `php:8.4-cli` container), local projects on any PHP 7.4+, running Docker / Compose containers, and SSH servers. That includes jump hosts, ssh-agent and 1Password logins, and password or 2FA logins that stay connected until you disconnect.
- **Framework drivers:** Laravel, Lumen, Laravel Zero, WordPress, Symfony, and Composer projects are detected automatically. Project drivers in `.runlet/` can boot any app and add variables, commands, host commands, and inspector sections. See [docs/drivers.md](docs/drivers.md).
- **Run inspector:**
  - structured output (Structured / Plain / Raw);
  - SQL queries with timings, bindings, N+1 hints, and [Explain in a new PHP tab](docs/sql-explain.md), with Laravel or plain Eloquent, Doctrine, or WordPress;
  - mail and HTML previews in a locked-down viewer, optional mail interception, and logs;
  - export as JSON, PHP, CSV, or Markdown.
- **Editor:** PHPantom completion that knows your project (including Docker and SSH targets with a local checkout), horizontal or vertical tabs, multiple windows and workspace files, ⌘P Open Anything and ⇧⌘P Command Palette, customizable shortcuts.
- **Library:** History (per project or all), personal and project snippets, and a Commands pane with Artisan or console commands, Composer scripts, your own host CLIs, and Open REPL (the target's Tinker, PsySH, or `php -a` in a terminal tab).
- **Integrated terminal** using your login shell. Commands wait for the shell to be ready.
- **Sandbox auto-run:** [opt in per tab](docs/sandbox-auto-run.md) to run after 800 ms without edits. Off by default, with a visible AUTO indicator; never restored or offered on local, Docker, or SSH targets.
- **Safety:** execution requires Run or explicit sandbox auto-run opt-in, and production targets ask before every run. See [docs/ssh.md](docs/ssh.md) for SSH and production guards.

## Install

Download the latest `.dmg` or `.zip` from [Releases](https://github.com/filipac/runlet/releases). Requires macOS 26 or later (Apple silicon or Intel).

No PHP installed? Runlet uses the PHP from Herd or Homebrew when it finds one. Otherwise it offers to download its own PHP 8.5 (Settings ▸ PHP), a self-contained build with the usual Laravel, Symfony, and WordPress extensions ([#2](https://github.com/filipac/runlet/issues/2)).

Builds are ad-hoc signed and not notarized. The first time, right-click Runlet.app ▸ Open, or run:

```sh
xattr -dr com.apple.quarantine /Applications/Runlet.app
```

The optional `runlet` command-line tool can be installed from Runlet ▸ Install Command-Line Tool…; see [docs/cli.md](docs/cli.md).

## Development

Runlet is a native macOS PHP scratchpad written in Swift with SwiftUI and AppKit. The Xcode project is generated from `project.yml` with XcodeGen. Reusable code lives in the Swift package `Packages/RunletKit`. See [docs/architecture.md](docs/architecture.md) for details.

### Prerequisites

- macOS 26 or later. Development so far used macOS 27.
- Xcode 27 (Swift 6.4 toolchain).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen).
- Composer and PHP, needed only on the build machine to build the PHP runner, the bundled Laravel sandbox, and the test fixtures:
  - The sandbox and fixture scripts run `artisan`, which needs PHP 8.3 or later.
  - The runner build needs PHP 8.0 or later.
  - End users need neither, and Runlet never runs Composer in a user's project.
- Docker (Docker Desktop or OrbStack), optional. You need it only for Docker targets, the Docker-backed sandbox fallback, and the Docker integration tests.

### One-time setup

Run these from the repository root.

Download PHPantom 0.10.0 for both architectures, verify the checksums, and build the universal binary at `Resources/LSP/phpantom_lsp`:

```bash
scripts/fetch-phpantom.sh
```

Install the pinned Laravel sandbox dependencies and build its pre-migrated SQLite database:

```bash
scripts/build-sandbox.sh
```

Prepare the disposable test fixtures. The Laravel fixture is copied from the sandbox, so run this after `build-sandbox.sh`:

```bash
scripts/setup-fixtures.sh
```

To also start the Docker fixture containers, pass `docker`:

```bash
scripts/setup-fixtures.sh docker
```

Stop the Docker fixture containers when you are done:

```bash
docker compose -p runlet-fixtures down
```

### Rebuilding the PHP runner

The app ships `Resources/Runner/dist/runlet-runner.php`, which is generated. After editing anything in `Resources/Runner/src`, install the build dependencies:

```bash
composer install --working-dir=Resources/Runner
```

Then regenerate the bundle:

```bash
php scripts/build-runner.php
```

### Generating the Xcode project

Run this again after changing `project.yml` or adding or removing source files:

```bash
xcodegen generate
```

### Building

The build signs the app ad-hoc, so no signing credentials are needed. A build phase embeds the runner, the sandbox, and PHPantom into the app bundle. It fails if `scripts/build-sandbox.sh` has not been run.

```bash
xcodebuild -project Runlet.xcodeproj -scheme Runlet -configuration Debug build
```

Runlet keeps its data in `~/Library/Application Support/Runlet`. Set `RUNLET_DATA_DIR` to use another directory.

### Package tests

```bash
cd Packages/RunletKit && swift test
```

Suites that need host PHP, the Laravel fixture, Docker, or the PHPantom binary are skipped when those are missing. See [docs/validation.md](docs/validation.md) for each suite's prerequisites.

### Packaging

`scripts/package.sh` builds a universal, verified, self-tested `dist/Runlet.app` with zip and DMG (set `RUNLET_SELFTEST_DOCKER=1` to include the Docker sandbox check).

### Documentation

- [docs/architecture.md](docs/architecture.md): platform, module boundaries, runner protocol, persistence, PHPantom integration, dependency versions, distribution.
- [docs/cli.md](docs/cli.md): the `runlet` command-line tool (install, usage, how it reaches the app).
- [docs/compatibility.md](docs/compatibility.md): supported PHP and Laravel versions, prototype-gate results, known limitations.
- [docs/validation.md](docs/validation.md): requirement-to-evidence tables for M01–M22 and the acceptance scenarios.
- [plan.md](plan.md): product plan and MVP requirements.
- [CHANGELOG.md](CHANGELOG.md): change history.

## License

[MIT](LICENSE). Bundled third-party components keep their own licenses: SwiftTerm (MIT), PHPantom, nikic/php-parser (BSD-3-Clause), and the Laravel sandbox (MIT). Their notices ship in `Runlet.app/Contents/Resources/Licenses`.

## Contributing and planned work

Follow [AGENTS.md](AGENTS.md): find or create a labeled GitHub issue before implementation or adding TODOs. The [next-release ideas](docs/next-release-ideas.md) link remaining work to issues; [completed ideas](docs/done-next-release-ideas.md) preserve implementation evidence and design history.
