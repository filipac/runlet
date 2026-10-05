# Supported Versions

Which versions of PHP and your frameworks Runlet works with, what it was checked against, and what Runlet's own PHP includes. What you need to install Runlet, and the short version of this page, are in [Installation](installation.md#requirements).

## PHP

Your projects can run on **PHP 7.4 to 8.5**, on your Mac, in a container, or on a server. Runlet's runner keeps PHP 7.4 syntax, so the same snippet API works on every version.

| Needs | Why |
| --- | --- |
| `tokenizer` | To show the last expression's value as the result. Without it, snippets still run, without an implicit result, and a notice says so. |
| `json`, `pcre` | Always part of PHP. |

Nothing else is required: no `pcntl` or `posix`, and no write access. Runlet writes no files into your project or container, so read-only file systems and non-root users work too.

Checked with:

- Herd PHP 7.4.33 and 8.4.25 on a Mac;
- the `php:7.4-cli` image as a non-root user, with a read-only root file system and a read-only project folder;
- the `php:8.4-cli` and `php:8.2-cli-alpine` images.

### What Depends on the PHP Version

| Feature | Version |
| --- | --- |
| Benchmarks' memory peak | Exact on PHP 8.2 and later. On older PHP, it shows only when it rose above the process's earlier peak. |
| Profile Run | Any PHP with the Excimer extension. See [Profiling](#profiling). |
| Magic comments | Every version. They were checked on PHP 8.4, and a subset on PHP 7.4. |

## Runlet's Own PHP

When your Mac has no PHP, Runlet offers to download its own: **PHP 8.5.8**, a self-contained command-line PHP of about 26 MB, built for Apple silicon and Intel. The Laravel sandbox and your local projects can run on it.

It includes these extensions: bcmath, bz2, calendar, ctype, curl, dom, excimer, exif, fileinfo, filter, ftp, gd, gmp, iconv, intl, mbstring, mongodb, mysqli, mysqlnd, opcache, openssl, pcntl, pdo, pdo_mysql, pdo_pgsql, pdo_sqlite, pgsql, phar, posix, readline, redis, session, simplexml, soap, sockets, sodium, sqlite3, tokenizer, xml, xmlreader, xmlwriter, zip, and zlib.

It doesn't include Xdebug or other Zend extensions, SPX, imagick, swoole, APCu, or PECL extensions beyond redis, excimer, and mongodb. For a project that needs them, use a PHP you install.

- **Trust:** it's downloaded only when you click, checked against a SHA-256 checksum built into the app, and must run and report the expected version before Runlet installs it.
- **Where:** `~/Library/Application Support/Runlet/PHP/`, with its licenses.
- **Updates:** when a newer Runlet comes with a newer build, the one you have keeps working, and **Settings ▸ PHP** offers the update with what changed. Updating moves your default PHP and your projects' PHP to the new build and removes the old one.
- PHP you installed yourself (Herd, Homebrew, or the `php` on your `PATH`) always comes first.

## Frameworks

Runlet detects these and boots them for every run. Anything else boots through a [project driver](drivers.md).

| Framework | Checked with | Notes |
| --- | --- | --- |
| Laravel | 13.34.0 (the sandbox) | Queries, mail and its interception, logs, previews, App Info, and the environment. |
| Lumen, Laravel Zero | Not with a real application yet | Detected and booted like Laravel. On Lumen, the database and events are inspected when the application resolved them while booting. |
| Eloquent without Laravel | illuminate/database 8.83 (PHP 7.4 and 8.4) and 13.34 | Queries, through a project driver that boots the application. |
| Doctrine DBAL | 3.10 and 4.5 | Queries, with one line in a project driver. DBAL 2 is handled like 3, but wasn't checked. |
| Symfony | 8.1 | Queries on the Doctrine connections, and Symfony Mailer's mail. Mail interception needs Symfony Mailer 6.3 or later. |
| WordPress | 7.1, on SQLite and MariaDB 11 | Queries through `$wpdb`, and `wp_mail()`. Mail interception needs WordPress 5.7 or later, and the environment type 5.5 or later. |

What the run inspector records for each one is in [Installation](installation.md#supported-environments).

### App Info

The framework chip opens **App Info**, read from the booted application:

| Framework | What it shows |
| --- | --- |
| Laravel 9.21 and later, Laravel Zero with `about` | The same data as `php artisan about`. Composer's version is left out, because getting it would run Composer. |
| Lumen, Laravel before 9.21 | The configuration, environment, version, and maintenance mode. |
| Symfony | The kernel's version, its end of maintenance and end of life, and its settings. |
| WordPress | The site's details, URLs, theme, options, `wp-config.php` constants, and the database server's version. Keys and salts are never read. |

### The Application's Environment

When a run boots the application, Runlet reads the environment the application says it's in, and offers to [mark the target as production](safety-and-privacy.md#production-asks-first) when it says so:

| Framework | Environment |
| --- | --- |
| Laravel, Lumen, Laravel Zero | `app()->environment()`: `APP_ENV`, where a process environment variable wins over `.env` |
| Symfony | The kernel's environment (`APP_ENV`, `dev` by default) |
| WordPress 5.5 and later | `wp_get_environment_type()`: `WP_ENVIRONMENT_TYPE`, and `production` when it isn't set |
| Project drivers | The driver's `environment()` |
| Plain PHP, Composer projects | None |

`production`, `prod`, `prd`, and `live` count as production (the whole name, in any case); `local`, `development`, and `dev` as local.

## Profiling

[Profile Run](benchmarks.md#profile-run) needs the **Excimer** extension in the target's PHP: on Linux, BSD, or macOS. Runlet's own PHP includes it. It was checked with Excimer 1.2.6 on PHP 8.4.

- Profile Run samples wall-clock time, every millisecond. CPU-time sampling isn't available on macOS.
- SPX is detected, and its version shown, but Runlet can't use it: it profiles only processes started with `SPX_ENABLED=1`, and writes its reports to files.
- **Settings ▸ PHP**, a Docker profile's **Test**, and an SSH profile's **Test Connection** show which profilers a PHP loads.

[`\Runlet\bench()`](benchmarks.md) needs no extension.

## Known Limitations

- `var_dump()` and `print_r()` output stays text: Runlet doesn't turn it into expandable values. Use `dump()` or return the value.
- **Stop in a running container** stops Runlet's PHP process, but processes your snippet started inside the container may keep running. Stopping needs `posix_kill` or a shell with `exec()` in the container; without either, Runlet says the PHP process may still be running. The Docker sandbox is different: Runlet owns that container, so Stop removes all of it.
- On your Mac, Stop signals the run's whole process group, so the processes it started stop too.

More, per framework: [Framework Drivers](drivers.md).

## For developers

This page is the user-facing part of [compatibility.md](compatibility.md), which keeps the evidence: what was verified, when, and with which tests, recorded 2026-10-02 on macOS 27.0 (arm64), Xcode 27.0, Swift 6.4, and Docker 29.4.0. Added in [#291](https://github.com/filipac/runlet/issues/291). Additional compatibility validation is tracked in [#54](https://github.com/filipac/runlet/issues/54), and Laravel inference gaps that need PHPantom fixes in [#117](https://github.com/filipac/runlet/issues/117).

- **The PHP 7.4 floor** was a decision for the runner, which is parsed with nikic/php-parser 5.9.0 (scoped to `RunletVendor\PhpParser`) and bundled into `Resources/Runner/dist/runlet-runner.php`. The whole runner is streamed to `php` on standard input, and events come back as nonce-framed records on standard output.
- **Timing on the Laravel fixture:** bootstrap about 40 ms and a full run about 90 to 140 ms locally; about 150 to 250 ms through `docker exec`.
- **The run inspector** (`Inspector.php`) keeps PHP 7.4 syntax; the DBAL 4 middleware (PHP 8.1 syntax) is evaluated only when DBAL 4 is in use (`InspectorTests`).
- **`dump()` and `dd()`** hook the project's VarDumper, and any VarDumper behind a pre-existing global `dump()` (php.ini `auto_prepend_file` tools such as global Ray, including php-scoper aliases). Without var-dumper, Runlet defines them.
- **App Info** (`Panels.php`, [#19](https://github.com/filipac/runlet/issues/19)): Laravel's data comes from `AboutCommand::gatherApplicationInformation()` and its static `$data`, through reflection. Laravel's `about` asks Composer for its version by running `composer -V`; Runlet constructs the command with an `Illuminate\Support\Composer` whose `getVersion()` returns null, and leaves the row out. If reading the data fails, App Info falls back to the configuration rows and says so.
- **Runlet's own PHP** ([#2](https://github.com/filipac/runlet/issues/2)) is built with static-php-cli from `scripts/php-runtime/craft.yml` by `.github/workflows/php-runtime.yml`, one archive per CPU type, published as a pre-release tagged `php-<version>-r<build>`. The current build is `r3` (`RunletPHPRelease.current`), which added mongodb 2.5.3 ([#212](https://github.com/filipac/runlet/issues/212)); `r2` added Excimer ([#79](https://github.com/filipac/runlet/issues/79)). It lives in `~/Library/Application Support/Runlet/PHP/8.5.8-r3/bin/php`, with `licenses/` and `README.txt`.
- **The environment** ([#12](https://github.com/filipac/runlet/issues/12)) is the runner's `environment` in the `bootstrapped` event; a project driver's throwing `environment()` leaves a Run Log line and the run completes.
- **Stop:** local Stop signals the runner's process group. In an existing container (`docker exec`), Stop signals the runner's PID only. The Docker sandbox runs with `docker run --rm --init`, so Stop kills the whole container.
- **Completion** comes from PHPantom 0.10.0; its prototype gate and Laravel completion results are in [compatibility.md](compatibility.md#phpantom-0100-prototype-gate).
