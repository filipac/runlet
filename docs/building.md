# Building Runlet

Runlet is open source, and you can build it yourself. It's a native macOS app written in Swift 6 with SwiftUI and AppKit, plus a PHP runner and a bundled Laravel sandbox. This page takes you from a fresh clone to a running Debug build and passing tests. How the pieces fit together is in [Architecture](architecture.md).

## What You're Building

- **The app and its packages.** The Xcode project is generated from `project.yml` with XcodeGen. Reusable code lives in the Swift package `Packages/RunletKit` (`RunletCore`, `RunletExecution`, `RunletLanguage`), which has no third-party Swift dependencies; the app adds SwiftTerm for its terminal.
- **The PHP runner.** One bundled PHP file (`Resources/Runner`), built with a scoped nikic/php-parser, is streamed to the target's PHP on standard input and reports back through nonce-framed events. It runs on PHP 7.4 to 8.5 and boots the framework through its drivers.
- **Language intelligence** comes from the PHPantom language server, bundled as a universal binary. **Format Code** uses the Mago formatter, bundled the same way.
- **The MCP server** has no third-party code and listens on a private Unix socket.
- **Tests:** more than 500 Swift Testing package tests (some run real PHP, Docker, and a disposable OpenSSH container), XCUITests that drive the rendered app, and a self-test of the packaged app.

## Prerequisites

- A Mac that runs Xcode 27; development so far used macOS 27. The app you build runs on macOS 15 or later.
- Xcode 27 (Swift 6.4 toolchain).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen).
- Composer and PHP, on the build machine only, to build the PHP runner, the bundled Laravel sandbox, and the test fixtures:
  - The sandbox and fixture scripts run `artisan`, which needs PHP 8.3 or later.
  - The runner build needs PHP 8.0 or later.
- Docker (Docker Desktop or OrbStack), optional. You need it only for Docker targets, the Docker-backed sandbox fallback, and the Docker integration tests.

> [!NOTE]
> Runlet's users need neither Composer nor PHP to run the app, and Runlet never runs Composer in a user's project.

## One-Time Setup

Run these from the repository root, in this order.

1. Download PHPantom 0.10.0 for both architectures, verify the checksums, and build the universal binary at `Resources/LSP/phpantom_lsp`:

   ```bash
   scripts/fetch-phpantom.sh
   ```

2. Download Mago 1.51.2 (the formatter behind Format Code) for both architectures, verify the checksums, and build the universal binary at `Resources/Formatter/mago`. The build runs this itself when the binary is missing:

   ```bash
   scripts/fetch-mago.sh
   ```

3. Install the pinned Laravel sandbox dependencies and build its pre-migrated SQLite database:

   ```bash
   scripts/build-sandbox.sh
   ```

4. Prepare the disposable test fixtures. The Laravel fixture is copied from the sandbox, so run this after `build-sandbox.sh`:

   ```bash
   scripts/setup-fixtures.sh
   ```

To also start the Docker fixture containers, pass `docker`, and stop them when you're done:

```bash
scripts/setup-fixtures.sh docker
docker compose -p runlet-fixtures down
```

## Generating the Xcode Project

Generate `Runlet.xcodeproj` from `project.yml`. Run this again after you change `project.yml`, or add or remove source files:

```bash
xcodegen generate
```

## Building and Running

The build signs the app ad-hoc, so you need no signing credentials. A build phase embeds the runner, the sandbox, and PHPantom into the app bundle; it fails if you haven't run `scripts/build-sandbox.sh`.

```bash
xcodebuild -project Runlet.xcodeproj -scheme Runlet -configuration Debug build
```

A Debug build, which is what Xcode's Run builds, is **Runlet Dev**. It runs next to the Runlet installed in Applications, even at the same time, and shares nothing with it:

| | Installed Runlet (releases) | Runlet Dev (Debug builds) |
|---|---|---|
| Bundle id | `dev.runlet.Runlet` | `dev.runlet.Runlet.dev` |
| Name and icon | Runlet | Runlet Dev, with a DEV badge |
| Data | `~/Library/Application Support/Runlet` | `~/Library/Application Support/Runlet Dev` |
| Settings (UserDefaults), saved database passwords (Keychain), MCP socket | its own | its own |

`RUNLET_DATA_DIR` points either one at another folder; tests and screenshots use a scratch one. The `runlet` command inside each app talks to that app.

> [!TIP]
> To start Runlet Dev with your tabs, targets, snippets, and history, quit both apps and run `scripts/copy-data-to-dev.sh` once. Saved database passwords aren't copied: enter them again in Runlet Dev.

## Rebuilding the PHP Runner

The app ships `Resources/Runner/dist/runlet-runner.php`, which is generated. After you edit anything in `Resources/Runner/src`, install the build dependencies:

```bash
composer install --working-dir=Resources/Runner
```

Then regenerate the bundle:

```bash
php scripts/build-runner.php
```

## Running the Tests

```bash
scripts/test.sh fast
```

`fast` runs the package tests in parallel, without the ones that need Docker or the fixture databases, in about 45 seconds. `scripts/test.sh full` runs all of them in about 70 seconds. Suites that need host PHP, the Laravel fixture, Docker, or the PHPantom binary are skipped when those are missing. The fixtures and each suite's prerequisites are in [validation.md](validation.md#package-tests).

> [!NOTE]
> A fresh checkout needs `scripts/build-sandbox.sh` and `scripts/setup-fixtures.sh` before the tests.

## Packaging

`scripts/package.sh` builds a universal, verified, self-tested `dist/Runlet.app` with a zip and a DMG. Set `RUNLET_SELFTEST_DOCKER=1` to include the Docker sandbox check. Releasing, including signing the update and the appcast, is in [Releasing](releasing.md); `scripts/update-e2e.py` tests in-app updates end to end with local builds.

## Previewing the Docs

This documentation is built from `docs/` with VitePress. You need Node only to preview it:

```bash
npm ci
npm run docs:dev
```

See [Writing Docs](writing-docs.md) for how pages are written and added.

## For developers

This page was the readme's Development section until [#287](https://github.com/filipac/runlet/issues/287). Runlet Dev is [#267](https://github.com/filipac/runlet/issues/267). Contributing and Testing pages, and the rest of the Development category in this voice, are [#293](https://github.com/filipac/runlet/issues/293).
