# Building Runlet

Runlet is open source, and you can build it yourself. It's a native macOS app written in Swift 6 with SwiftUI and AppKit, plus a PHP runner and a bundled Laravel sandbox. This page takes you from a fresh clone to a running Debug build. Running the tests is in [Testing](testing.md), and how the pieces fit together is in [Architecture](architecture.md).

## What You're Building

- **The app and its packages.** The Xcode project is generated from `project.yml` with XcodeGen. Reusable code lives in the Swift package `Packages/RunletKit` (`RunletCore`, `RunletExecution`, `RunletLanguage`), which has no third-party Swift dependencies. The app adds SwiftTerm for its terminal and Sparkle for updates.
- **The PHP runner.** One bundled PHP file (`Resources/Runner`), built with a scoped nikic/php-parser, is streamed to the target's PHP on standard input and reports back through nonce-framed events. It runs on PHP 7.4 to 8.5 and boots the framework through its drivers.
- **Language intelligence** comes from the PHPantom language server, bundled as a universal binary. **Format Code** uses the Mago formatter, bundled the same way.
- **The MCP server** has no third-party code and listens on a private Unix socket.
- **Tests:** more than 1,500 Swift Testing package tests (some run real PHP, Docker, and a disposable OpenSSH container), XCUITests that drive the rendered app, and a self-test of the packaged app.

## Prerequisites

| Tool | What it's for |
| --- | --- |
| **Xcode 27** (Swift 6.4) | Building the app. Development so far used macOS 27; the app you build runs on macOS 15 or later. |
| **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** | Generating `Runlet.xcodeproj` from `project.yml`. |
| **Composer and PHP** | Building the PHP runner, the bundled Laravel sandbox, and the test fixtures, on this Mac only. The sandbox and fixture scripts run `artisan`, which needs PHP 8.3 or later; the runner build needs PHP 8.0 or later. |
| **Docker** (Docker Desktop or OrbStack), optional | Docker targets, the Docker-backed sandbox fallback, and the Docker integration tests. |
| **Node 20 or later**, optional | Previewing this documentation. |

With Homebrew, install the command-line tools in one go:

```sh
brew install xcodegen composer php
```

The fetch scripts also use `curl`, `shasum`, and `lipo`, which come with macOS and Xcode.

> [!NOTE]
> Runlet's users need neither Composer nor PHP to run the app, and Runlet never runs Composer in a user's project.

## Getting the Code

```sh
git clone https://github.com/filipac/runlet.git
cd runlet
```

Run every command on this page from the repository root.

## One-Time Setup

The downloaded binaries and installed dependencies are gitignored, so a fresh clone, and every new git worktree, needs these steps once, in this order:

1. Download PHPantom 0.10.0 for both architectures, verify the checksums, and build the universal binary at `Resources/LSP/phpantom_lsp`:

   ```sh
   scripts/fetch-phpantom.sh
   ```

2. Download Mago 1.51.2 (the formatter behind Format Code) the same way, into `Resources/Formatter/mago`:

   ```sh
   scripts/fetch-mago.sh
   ```

3. Install the pinned Laravel sandbox's dependencies and build its pre-migrated SQLite database:

   ```sh
   scripts/build-sandbox.sh
   ```

4. Prepare the test fixtures. The Laravel fixture is a copy of the sandbox, so run this after `build-sandbox.sh`:

   ```sh
   scripts/setup-fixtures.sh
   ```

The build runs the two fetch scripts itself when a binary is missing, but the tests need the binaries before that. Both scripts do nothing when the pinned version is already there. The Docker and database fixtures that some tests need are in [Testing](testing.md#setting-up-the-fixtures).

## Generating the Xcode Project

The repository includes the generated `Runlet.xcodeproj`. Generate it again from `project.yml` after you change `project.yml`, or add or remove source files:

```sh
xcodegen generate
```

Edit `project.yml`, never the generated project: the next `xcodegen generate` replaces it.

## Building and Running

The build signs the app ad-hoc, so you need no signing credentials. A build phase embeds the runner, the sandbox, PHPantom, and Mago into the app bundle; it fails if you haven't run `scripts/build-sandbox.sh`.

```sh
xcodebuild -project Runlet.xcodeproj -scheme Runlet -configuration Debug \
  -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Runlet.app
```

Or open `Runlet.xcodeproj` in Xcode, pick the **Runlet** scheme, and press <kbd>⌘</kbd><kbd>R</kbd>.

### Runlet Dev

A Debug build, which is what Xcode's Run builds, is **Runlet Dev**. It runs next to the Runlet installed in Applications, even at the same time, and shares nothing with it:

| | Installed Runlet (releases) | Runlet Dev (Debug builds) |
|---|---|---|
| Bundle id | `dev.runlet.Runlet` | `dev.runlet.Runlet.dev` |
| Name and icon | Runlet | Runlet Dev, with a DEV badge |
| Data | `~/Library/Application Support/Runlet` | `~/Library/Application Support/Runlet Dev` |
| Settings (UserDefaults), saved database passwords (Keychain), MCP socket | its own | its own |

`RUNLET_DATA_DIR` points either one at another folder; tests and screenshots use a scratch one. The `runlet` command inside each app talks to that app.

<!-- screenshot: Runlet and Runlet Dev side by side in the Dock, the DEV badge visible -->

### Using Your Data in Runlet Dev

To start Runlet Dev with your tabs, settings, targets, snippets, and history, quit both apps and copy them once:

```sh
scripts/copy-data-to-dev.sh
```

The script only reads the installed Runlet's data. It refuses while either app runs, and moves Runlet Dev's previous state aside (`State.before-copy-<time>`) instead of replacing it. Saved database passwords aren't copied: enter them again in Runlet Dev with **Edit Connection**. The sandbox, Runlet's own PHP, and caches aren't copied either; Runlet Dev sets them up itself.

### Running From Xcode

The generated **Runlet** scheme runs with Metal API Validation off. Core Animation's own line drawing sometimes issues a Metal draw with zero instances: a normal launch ignores it, but with validation on, Xcode stops on `instanceCount(0) must be non-zero`. To debug GPU issues, turn validation back on in **Product ▸ Scheme ▸ Edit Scheme ▸ Run ▸ Diagnostics**; `xcodegen generate` turns it off again.

## Rebuilding the PHP Runner

The app ships `Resources/Runner/dist/runlet-runner.php`, which is generated and committed. After you edit anything in `Resources/Runner/src`, install the build dependencies once:

```sh
composer install --working-dir=Resources/Runner
```

Then regenerate the bundle, and commit it with your change:

```sh
php scripts/build-runner.php
```

Edit `src/`, never `dist/`.

## Running the Tests

```sh
scripts/test.sh fast
```

`fast` runs the package tests in parallel, without the ones that need Docker or the fixture databases, in under a minute. `scripts/test.sh full` runs all of them. [Testing](testing.md) has the fixtures, the options, and how to check the app itself.

## Packaging

`scripts/package.sh` builds a universal (arm64 and x86_64), verified, self-tested `dist/Runlet.app`, with a zip and a DMG:

```sh
scripts/package.sh
```

| Variable | Effect |
| --- | --- |
| `RUNLET_SELFTEST_DOCKER=1` | The self-test also runs the Docker sandbox. |
| `RUNLET_DIST_DIR` | Writes the output to another folder instead of `dist/`. |
| `RUNLET_STRIP=1` or `0` | Strips the executables' local symbols, or keeps them. By default, a stable version (an empty `RUNLET_PRERELEASE` in `project.yml`) is stripped and a beta isn't. |
| `RUNLET_SIGN_IDENTITY`, `RUNLET_NOTARY_PROFILE` | A Developer ID identity, and a `notarytool` keychain profile that also notarizes the DMG. Without them, the app is signed ad-hoc. Releases don't use them yet. |

Releasing, including signing the update and the appcast, is in [Releasing](releasing.md); `scripts/update-e2e.py` tests in-app updates end to end with local builds.

## Previewing the Docs

This documentation is built from `docs/` with VitePress. You need Node only to preview it:

```sh
npm ci
npm run docs:dev
```

See [Writing Docs](writing-docs.md) for how pages are written and added.

## For developers

This page was the readme's Development section until [#287](https://github.com/filipac/runlet/issues/287). Runlet Dev is [#267](https://github.com/filipac/runlet/issues/267), and its icon and per-bundle-id settings [#269](https://github.com/filipac/runlet/issues/269). Metal API Validation is off in the scheme since [#85](https://github.com/filipac/runlet/issues/85). The Development category in this voice, with Contributing and Testing, is [#293](https://github.com/filipac/runlet/issues/293).

| Piece | Where |
| --- | --- |
| Versions, bundle ids, the name, icon, and data folder per bundle id, the scheme | `project.yml` |
| The build phase that embeds the runner, sandbox, PHPantom, Mago, and licenses | `scripts/embed-resources.sh` |
| Pinned versions and checksums of PHPantom and Mago | `scripts/fetch-phpantom.sh`, `scripts/fetch-mago.sh` |
| The runner's bundler | `scripts/build-runner.php` |
| Copying the installed app's state into Runlet Dev | `scripts/copy-data-to-dev.sh` |
| Packaging, stripping, dSYMs, and the checks | `scripts/package.sh` ([Architecture](architecture.md#packaging-scriptspackagesh)) |
