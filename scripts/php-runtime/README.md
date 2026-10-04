# Runlet's PHP runtime ([#2](https://github.com/filipac/runlet/issues/2))

Runlet offers to download its own static PHP CLI when no installed PHP fits. These files
build it:

- `craft.yml`: the PHP version and extensions for [static-php-cli](https://github.com/crazywhalecc/static-php-cli).
  It includes static-php-cli's "common" set plus mysqli, intl, sodium, readline, excimer
  (for Profile Run, since build r2, #79), and mongodb (for MongoDB connections from this Mac,
  since build r3, #191, #212).
  Libraries are built from source, because the prebuilt SQLite lacks
  `SQLITE_ENABLE_COLUMN_METADATA`, which static-php-cli's sqlite3 sanity check requires.
- `package.sh`: turns `buildroot/bin/php` into
  `runlet-php-<version>-<build>-macos-<arch>.tar.gz` (plus `.sha256`), ad-hoc signed, with
  `licenses/` and `README.txt`.
- `.github/workflows/php-runtime.yml`: builds both architectures on GitHub-hosted macOS
  runners. Pushing a `php-<version>-r<build>` tag publishes them as a pre-release that never
  becomes "Latest".

## Releasing a new build

The current build is **php-8.5.8-r3** (CI run 37209074875), pinned in
`RunletPHPRelease.current` ([#212](https://github.com/filipac/runlet/issues/212)). It adds
`mongodb` 2.5.3 ([#191](https://github.com/filipac/runlet/issues/191)), so MongoDB connections
from this Mac use Runlet's PHP first.

1. Change `craft.yml` if needed, and push a new tag such as `php-8.5.8-r4`.
2. Each build job uploads its archive as a run artifact (`runlet-php-arm64`,
   `runlet-php-x86_64`); the release job publishes those same files once both are built.
   Copy each archive's URL, SHA-256 (from the `.sha256` file), and size into
   `RunletPHPRelease.current` (`Packages/RunletKit/Sources/RunletCore/RunletPHP.swift`).
   An architecture still at the placeholder checksum is not offered.
   Set `changes` to one sentence saying what the build adds: Macs with an older build see it next
   to Update in Settings ▸ PHP, and updating moves saved PHP paths to the new build.
3. Install it from Settings ▸ PHP in a Debug build, with `RUNLET_DEBUG_HIDE_SYSTEM_PHP=1`
   and a scratch `RUNLET_DATA_DIR`. To try an archive before the release is published,
   serve the artifact locally and point `RUNLET_DEBUG_PHP_URL` at it (Debug builds only;
   the pinned checksum still has to match):

   ```sh
   gh run download <run id> -n runlet-php-arm64 -D dist
   (cd dist && python3 -m http.server 18765 --bind 127.0.0.1)
   # then launch Runlet with
   # RUNLET_DEBUG_PHP_URL=http://127.0.0.1:18765/runlet-php-8.5.8-r4-macos-arm64.tar.gz
   ```

## Building locally

Published archives always come from CI. Building on a Mac with the **macOS 27 SDK**
(Xcode 27) fails at the moment: PostgreSQL's `libpq` calls `memset_s`, which that SDK no
longer declares by default (`src/port/explicit_bzero.c`). The CI runners use the stable SDK.
To try a build locally anyway:

```sh
mkdir build-php && cd build-php
curl -fsSL https://github.com/crazywhalecc/static-php-cli/releases/download/2.8.5/spc-macos-aarch64.tar.gz | tar -xz
cp ../scripts/php-runtime/craft.yml . && ./spc craft
../scripts/php-runtime/package.sh . 8.5.8 r0 arm64 ../dist
```

`spc doctor` may install build tools such as `bison` with Homebrew.
