# Building Runlet

Runlet is a native macOS app written in Swift 6 with SwiftUI and AppKit, and it's open source. This page shows how to build it from source and run its tests. How the pieces fit together is in [Architecture](architecture.md).

Under the hood:

- **App and packages.** The Xcode project is generated from `project.yml` with XcodeGen. Reusable code lives in the Swift package `Packages/RunletKit` (`RunletCore`, `RunletExecution`, `RunletLanguage`), which has no third-party Swift dependencies; the app adds SwiftTerm for its terminal.
- **PHP runner.** One bundled PHP file (`Resources/Runner`), built with a scoped nikic/php-parser, is streamed to the target's PHP on standard input and reports back through nonce-framed events. It runs on PHP 7.4 to 8.5 and boots the framework through its drivers.
- **Language intelligence** comes from the PHPantom language server, bundled as a universal binary. **Format Code** uses the Mago formatter, bundled the same way.
- **MCP server** with no third-party code, behind a private Unix socket.
- **Tests:** more than 500 Swift Testing package tests (some run real PHP, Docker, and a disposable OpenSSH container), XCUITests that drive the rendered app, and a self-test of the packaged app.

## Prerequisites

- A Mac that runs Xcode 27; development so far used macOS 27. The app you build runs on macOS 15 or later.
- Xcode 27 (Swift 6.4 toolchain).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen).
- Composer and PHP, needed only on the build machine to build the PHP runner, the bundled Laravel sandbox, and the test fixtures:
  - The sandbox and fixture scripts run `artisan`, which needs PHP 8.3 or later.
  - The runner build needs PHP 8.0 or later.
  - End users need neither, and Runlet never runs Composer in a user's project.
- Docker (Docker Desktop or OrbStack), optional. You need it only for Docker targets, the Docker-backed sandbox fallback, and the Docker integration tests.

## One-Time Setup

Run these from the repository root.

Download PHPantom 0.10.0 for both architectures, verify the checksums, and build the universal binary at `Resources/LSP/phpantom_lsp`:

```bash
scripts/fetch-phpantom.sh
```

Download Mago 1.51.2 (the formatter behind Format Code) for both architectures, verify the checksums, and build the universal binary at `Resources/Formatter/mago`. The build runs this itself when the binary is missing:

```bash
scripts/fetch-mago.sh
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

## Rebuilding the PHP Runner

The app ships `Resources/Runner/dist/runlet-runner.php`, which is generated. After editing anything in `Resources/Runner/src`, install the build dependencies:

```bash
composer install --working-dir=Resources/Runner
```

Then regenerate the bundle:

```bash
php scripts/build-runner.php
```

## Generating the Xcode Project

Run this again after changing `project.yml` or adding or removing source files:

```bash
xcodegen generate
```

## Building

The build signs the app ad-hoc, so no signing credentials are needed. A build phase embeds the runner, the sandbox, and PHPantom into the app bundle. It fails if `scripts/build-sandbox.sh` has not been run.

```bash
xcodebuild -project Runlet.xcodeproj -scheme Runlet -configuration Debug build
```

A Debug build, which is what Xcode's Run builds, is **Runlet Dev** ([#267](https://github.com/filipac/runlet/issues/267)). It runs next to the Runlet installed in Applications, even at the same time, without sharing anything:

| | Installed Runlet (releases) | Runlet Dev (Debug builds) |
|---|---|---|
| Bundle id | `dev.runlet.Runlet` | `dev.runlet.Runlet.dev` |
| Name and icon | Runlet | Runlet Dev, with a DEV badge |
| Data | `~/Library/Application Support/Runlet` | `~/Library/Application Support/Runlet Dev` |
| Settings (UserDefaults), saved database passwords (Keychain), MCP socket | its own | its own |

`RUNLET_DATA_DIR` still points either one at another folder (tests and screenshots use a scratch one). The `runlet` command inside each app talks to that app. To start Runlet Dev with your tabs, targets, snippets, and history, quit both apps and run `scripts/copy-data-to-dev.sh` once. Saved database passwords aren't copied: enter them again in Runlet Dev.

## Package Tests

```bash
scripts/test.sh fast
```

`fast` runs the package tests in parallel, without the ones that need Docker or the fixture databases, in about 45 seconds. `scripts/test.sh full` runs all of them in about 70 seconds. A fresh checkout needs `scripts/build-sandbox.sh` and `scripts/setup-fixtures.sh` first. Suites that need host PHP, the Laravel fixture, Docker, or the PHPantom binary are skipped when those are missing. See [validation.md](validation.md#package-tests) for the fixtures and each suite's prerequisites.

## Packaging

`scripts/package.sh` builds a universal, verified, self-tested `dist/Runlet.app` with zip and DMG (set `RUNLET_SELFTEST_DOCKER=1` to include the Docker sandbox check). Releasing, including signing the update and the appcast, is in [Releasing](releasing.md); `scripts/update-e2e.py` tests in-app updates end to end with local builds.

## Previewing the Docs

The documentation you're reading is built from `docs/` with VitePress. Node is needed only to preview it:

```bash
npm ci
npm run docs:dev
```

See [Writing Docs](writing-docs.md) for how pages are written and added.

## For developers

This page was moved from the readme's Development section in [#287](https://github.com/filipac/runlet/issues/287). Its rewrite in the docs voice, with Contributing and Testing pages, is [#293](https://github.com/filipac/runlet/issues/293).
