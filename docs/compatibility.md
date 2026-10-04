# Compatibility and prototype-gate evidence

Laravel inference gaps that need PHPantom fixes are tracked in [#117](https://github.com/filipac/runlet/issues/117), and additional compatibility validation in [#54](https://github.com/filipac/runlet/issues/54). This file records its original evidence; the documentation audit did not rerun it. The [Laravel completion](#laravel-completion-scenario-15-phpantom-0100-laravel-13340) section was rerun and updated for [#55](https://github.com/filipac/runlet/issues/55) on 2026-10-03.

Recorded 2026-10-02 on macOS 27.0 (arm64), Xcode 27.0, Swift 6.4, Docker 29.4.0.

## PHP runner

Framework detection and project drivers (`.runlet/*Driver.php`) are documented in
[drivers.md](drivers.md).

| Item | Choice / result |
| --- | --- |
| Supported target PHP | 7.4 – 8.5 (decision: PHP 7.4 floor) |
| Parser | nikic/php-parser 5.9.0, scoped to `RunletVendor\PhpParser`, bundled into `Resources/Runner/dist/runlet-runner.php` |
| Transport | Whole runner streamed to `php` on stdin; events are nonce-framed records on stdout (`0x1E RL1:<nonce>:<len>:<json>\n`). No files are written into projects or containers, so read-only filesystems and non-root users work. |
| Verified runtimes | Herd PHP 7.4.33 and 8.4.25 locally; `php:7.4-cli` (uid 1000, read-only root FS, read-only app mount), `php:8.4-cli`, `php:8.2-cli-alpine` via `docker exec` |
| Laravel | 13.34.0 (pinned sandbox + fixture app): bootstrap ≈ 40 ms, full run ≈ 90–140 ms locally; ≈ 150–250 ms via `docker exec` |
| Required extensions | `tokenizer` for final-expression capture (falls back to running without implicit results, with a notice). `json` and `pcre` are core. No `pcntl`/`posix` needed. |
| Run inspector | `Inspector.php` keeps PHP 7.4 syntax; the DBAL 4 middleware (PHP 8.1 syntax) is evaluated only when DBAL 4 is in use. Verified with Laravel 13.34 (queries, mail, interception, logs, previews), illuminate/database 8.83 + illuminate/events on PHP 7.4 and 8.4, illuminate/database 13.34 without events (query-log fallback), Doctrine DBAL 3.10 and 4.5, WordPress 7.1 on SQLite, and Symfony 8.1 responses (`InspectorTests`). |
| `dump()`/`dd()` | Hooks the project's VarDumper and any VarDumper behind a pre-existing global `dump()` (e.g. php.ini `auto_prepend_file` tools such as global Ray, including php-scoper aliases). Without var-dumper, Runlet defines `dump()`/`dd()`. |

### App Info ([#19](https://github.com/filipac/runlet/issues/19))

`Panels.php` keeps PHP 7.4 syntax (checked with Herd PHP 7.4.33 and 8.4.25). Verified with
`AppInfoRunnerTests`: the Laravel 13.34 sandbox and fixture (in-process `about` data, also in
the `runlet-fixtures` `laravel` container), a project driver extending `LaravelDriver`,
Symfony 8.1, WordPress 7.1 on SQLite, the custom-driver fixture (also on PHP 7.4), the SSH
fixture, bounds, and `panels()` failures.

| Framework | What App Info reads |
| --- | --- |
| Laravel 9.21 and later, Laravel Zero with `about` | `AboutCommand::gatherApplicationInformation()` and its static `$data`, through reflection, in the booted application. Laravel's `about` asks Composer for its version by running `composer -V`; Runlet constructs the command with an `Illuminate\Support\Composer` whose `getVersion()` returns null when that method has no declared return type (every version so far), and leaves the row out. If a later Laravel declares one, the container's Composer is used and the version is shown. If reading the data fails, App Info falls back to the configuration rows and says so in a note. |
| Lumen, Laravel before 9.21 | `config()` values and `$app->environment()`, `version()`, `isDownForMaintenance()` when present. |
| Symfony | `Kernel::VERSION`, `END_OF_MAINTENANCE`, `END_OF_LIFE`, and the kernel's getters (`getCharset()`, `getBuildDir()` only where they exist). |
| WordPress | `get_bloginfo()`, `wp_get_environment_type()` (5.5+), `site_url()`, `home_url()`, `wp_get_theme()`, options, `wp-config.php` constants, and `$wpdb->db_server_info()` (or `db_version()`). Keys and salts are constants App Info never reads. |

### Benchmarks and Profile Run ([#41](https://github.com/filipac/runlet/issues/41))

| Item | Requirement / result |
| --- | --- |
| `Runlet\bench()` | Every target: plain PHP 7.4+ in the runner, no extension. `hrtime(true)` timing; memory peaks need PHP 8.2+ (`memory_reset_peak_usage()`), older PHP reports the peak only when it rose above the process's earlier peak. Verified on Herd PHP 8.4.25 and 7.4.33 (host) and PHP 8.4.26 in Docker. |
| Laravel `Benchmark::dd()` | Recognized from its dump on Laravel 13.34 (sandbox and `laravel-app` fixture). `Benchmark::measure()` and `value()` are not observed (they only return numbers); use `Runlet\bench()`. |
| Profile Run | Needs the **Excimer** extension in the target's PHP ([mediawiki.org/wiki/Excimer](https://www.mediawiki.org/wiki/Excimer); Linux, BSD, or macOS; packages `php-excimer` from deb.sury.org or remirepo, `pie install wikimedia/excimer`, or `pecl install excimer`). Verified with Excimer 1.2.6 on PHP 8.4.26 (`php:8.4-cli` with `pecl install excimer`, the runlet-fixtures `profiler` service). Wall-clock sampling at 1 ms by default; CPU-time sampling is not available on macOS. |
| SPX | Detected (version shown) but not used for Profile Run: SPX profiles only processes started with `SPX_ENABLED=1` and writes reports to `spx.data_dir` or stderr, with no API that hands them to the running script. Checked with SPX 0.4.22. |
| Detection | PHP discovery (with the PHP's own php.ini, `auto_prepend_file` off), the Docker profile Test, SSH Test Connection, and every run's `started` frame. |
| Runlet's own PHP | Build `r2` and later include Excimer ([#79](https://github.com/filipac/runlet/issues/79)), so Profile Run works with no other PHP installed. Build `r1` had neither Excimer nor SPX; Settings ▸ PHP offers the update. |

### Runlet's own PHP ([#2](https://github.com/filipac/runlet/issues/2))

When no installed PHP fits, Runlet offers to download its own PHP (Settings ▸ PHP, or a banner
above a sandbox or local tab). It is a static PHP CLI built with
[static-php-cli](https://github.com/crazywhalecc/static-php-cli) from
`scripts/php-runtime/craft.yml` by `.github/workflows/php-runtime.yml`, one archive per CPU type,
published as a pre-release tagged `php-<version>-r<build>`.

| Item | Value |
| --- | --- |
| Version | PHP 8.5.8 (`RunletPHPRelease.current`, build `r2`) |
| Extensions | bcmath, bz2, calendar, ctype, curl, dom, excimer, exif, fileinfo, filter, ftp, gd, gmp, iconv, intl, mbstring (with mbregex), mysqli, mysqlnd, opcache, openssl, pcntl, pdo, pdo_mysql, pdo_pgsql, pdo_sqlite, pgsql, phar, posix, readline, redis, session, simplexml, soap, sockets, sodium, sqlite3, tokenizer, xml, xmlreader, xmlwriter, zip, zlib |
| Not included | Xdebug and other Zend extensions, SPX, imagick, swoole, APCu, and PECL extensions beyond redis and excimer; projects that need them should use an installed PHP. |
| Location | `~/Library/Application Support/Runlet/PHP/8.5.8-r2/bin/php` (with `licenses/` and `README.txt`) |
| Updates | When a newer Runlet pins a newer build, an installed older build keeps working and Settings ▸ PHP shows "Update to r2" with what changed. Update downloads and verifies the new build, moves the default PHP and projects' PHP from the old binary to the new one, and removes the old folder. |
| Trust | Downloaded only on request, checked against the SHA-256 pinned in the app, and must run and report the expected version before it is installed. |

Known limitations:
- `var_dump`/`print_r` stay textual (not parsed into structures), by design.
- Snippet child processes: local Stop signals the runner's process group (verified). In an
  existing container (`docker exec`), Stop signals the runner PID only; children a snippet spawns
  inside the container are not guaranteed to stop (not tested). The Docker sandbox is different:
  Runlet owns that container (`docker run --rm --init`), so Stop kills the whole container.
- Cancellation in an existing container requires `posix_kill` or `/bin/sh` + `exec()` in the
  container; if neither exists, Stop reports that the PHP process may still be running.

### Magic comments ([#10](https://github.com/filipac/runlet/issues/10))

Recorded 2026-10-03 with Herd PHP 8.4.25 and 7.4.33, the Laravel 13.34.0 sandbox, the
`runlet-fixtures` `restricted` container, and the disposable SSH fixture.

| Form | Shows |
| --- | --- |
| `//?` at the end of a line | The value of what ends right before it on that line: an expression statement's value (an assignment's assigned value; `$i++; //?` shows `$i` after the increment), a `return`'s value, or `echo`'s argument (a list when there are several). After a sub-expression on a line of a multi-line expression, that sub-expression; after a trailing comma, the item before it. On a line without a value (`foreach (…) { //?`, `} //?`, a line of its own) it shows `✓` when the line is reached. |
| `/*?*/` | The largest expression that ends right before it: `$a * $b /*?*/ + 1` shows `$a * $b`, and `$a + ($b /*?*/)` shows `$b`. After an arrow function's body, `yield`, `print`, or `throw`, their operand. After a statement (`foo(); /*?*/`), its value. |
| `/*?->chain*/`, `/*??->chain*/` | A projection of the value before it (`/*?->count()*/`, `/*?->first()->name*/`); the code still gets the value itself. A projection is user code: it runs only for the hits whose values are sent (so it may query a database), sees variables by value, and an exception it throws is shown instead of a value. |
| `/*?.*/` | Milliseconds since the previous `/*?.*/` hit of the run, or since the snippet started. After an expression, measured once the expression has its value; between statements, at that point. |

A line that runs more than once shows `×N` and the latest value; hovering (or Edit ▸ Show
Inline Value) shows the value tree and every hit. The first 100 hits of each comment carry
values; later ones are counted, with a value sampled about four times a second, and the final
count arrives when the run ends. Values are bounded (depth 5, 100 children per level, 8 KiB
strings, 256 KiB each) and stop after 16 MiB per run (counts continue). They stream while the
code runs on every target (verified locally, in a container, and over SSH). Text that looks like
a magic comment inside a string, heredoc, another comment, or inline HTML is not one; `#?` and
`//? note` are ordinary comments.

**What the code does doesn't change.** Probes are calls inserted around expressions at byte
offsets on the same lines; the code is never re-printed. Every expression is still evaluated
once and in order; references are kept (by-reference arguments, `=&`, `foreach (… as &$v)`,
by-reference returns and generators); nullsafe chains still short-circuit; `match`, ternaries,
string interpolation, named arguments, `fn`/`static fn`/closures, generators, destructuring,
compound assignments, and `??=` behave the same. `MagicCommentTests` runs each fixture with and
without its magic comments and requires the same output, results, dumps, and errors (PHP 8.4,
plus a PHP 7.4 subset).

**Not shown.** The code runs as written, one notice lists them, and the line shows a short
reason (the full one on hover):

- assignment and destructuring targets (`$x /*?*/ = 1`, `[$a /*?*/, $b] = …`), `foreach`
  variables, `global`/`static`/`unset`, parameters, and closure `use` variables;
- a variable, element, or property checked by `isset()`, `empty()`, or the left side of `??`;
- constant expressions: parameter and property defaults, constants, enum cases, attributes;
- the start of a `"{$…}"` interpolation (put the comment after the string);
- by-reference array items (`[&$x /*?*/]`);
- a nullsafe chain followed by a plain link (`$a?->b() /*?*/ ->c()`): put it before `?->` or
  after the chain;
- a variable, element, or property passed to a method on an object, through a dynamic name, or
  to a class Runlet hasn't loaded, because the parameter might be by reference (classes are never
  autoloaded to find out). Other expressions passed there (`$o->m($a + 1 /*?*/)`) are fine, and
  so are arguments of functions and of loaded or snippet-declared classes;
- projections and `/*?.*/` around a value taken by reference, and `exit` without an argument.

Known limitations: a call that returns by reference, passed straight to a by-reference parameter
of a method Runlet can't resolve, would lose the reference when wrapped (`$o->m(ref() /*?*/)`);
with soft wrap on, a long line may leave no room for its values (hover or Show Inline Value still
shows them); without soft wrap, values after long lines may need horizontal scrolling.

The next run clears the values. Until then, a line edited since the run loses its values, and
lines above or below an edit keep theirs, moved with their text. Values never start a run, and
opening, importing, or restoring code never runs it.

**Settings ▸ General ▸ Magic Comments ▸ Show values of magic comments** (on by default): turned
off, magic comments are ordinary comments. Runlet adds nothing to the code it runs on any target
(no probes, so no overhead and no notices about placements), and the editor doesn't highlight
them or show values. When values appear follows Settings ▸ General ▸ Output (below), which
replaced the *Show values while the code runs* switch.

Profile Run ([#41](https://github.com/filipac/runlet/issues/41)) never inserts probes, whatever
the setting, so the flame graph shows only the code as written.

### Output: realtime or at once ([#82](https://github.com/filipac/runlet/issues/82))

**Settings ▸ General ▸ Output**: **Realtime** (the default) shows printed output, dumps,
magic-comment values, and the inspector's records as the code runs. **At once** shows a run's
output together when it ends: completed, failed, `dd()`, `exit`, or stopped (what arrived before
Stop is shown). The status bar (running, elapsed time) and Stop stay live; the Run Log too. The
app holds the output, so it works the same on every target (sandbox, local, Docker, SSH) and the
PHP process holds nothing. A saved *Show values while the code runs* turned off (magic comments,
#10) reads as At once. AI clients over MCP get the full result in both modes.

In both modes the tab updates at most ten times a second, less often while drawing is slow. A
printed output in Structured shows its last 5,000 lines, and Structured shows the last 1,000
cards (**Show All** shows every card of the run); Plain and Raw, Copy Output, and Save Output
have everything.

Verified with a Debug build (scratch data, local PHP 8.4 and the SSH fixture): a slow loop
mid-run and finished in each mode, the Settings section, and the timing of large outputs (5,000
dumps, 200,000 echoed lines, output near the 8 MiB limit, one large dump, a steady stream of
3,000 dumps). Covered by unit tests only: holding and replay order for every way a run ends,
Clear Output while holding, the settings migration, batching and pacing, and the MCP report in
At once mode. Docker targets were not run end to end for #82 (the gate is target-independent).

### SQL tabs ([#35](https://github.com/filipac/runlet/issues/35))

Guide: [sql-tabs.md](sql-tabs.md). An SQL tab's statement runs in the same runner process as a
snippet, through the connection the project's driver provides ([drivers.md](drivers.md#sql-connections)).

| Project | Connection | Evidence |
| --- | --- | --- |
| Laravel 13.34 (sandbox, `laravel-app` fixture) | `DB::connection($name)`'s PDO; names from `database.connections`, default first | `SQLTabExecutionTests` (SQLite: SELECT, UPDATE, named and unknown connections, database errors); Debug app on the sandbox (INSERT, SELECT, UPDATE) |
| Laravel with a project driver extending `LaravelDriver` | The driver's `sqlConnection()` first, `parent::sqlConnection()` for the rest | `SQLTabExecutionTests` (`custom-laravel-driver`) |
| Project driver (`Runlet\Driver`) | `sqlConnection()` returning a PDO or a callable | `SQLTabExecutionTests` (`custom-driver`, SQLite in memory) |
| illuminate/database through Capsule, no driver method | Eloquent's connection resolver | `SQLTabExecutionTests` (`eloquent-app`, illuminate/database 8.83, SQLite) |
| Doctrine DBAL 3.10 and 4.5 | `SqlConnections::doctrine()`: the native PDO | `SQLTabExecutionTests` (`eloquent-app`, `eloquent-app-modern`) |
| Symfony with DoctrineBundle | The `doctrine` registry's connection | Uses the same helper as the DBAL tests; the Symfony fixture has no DoctrineBundle, so it is not run end to end |
| Symfony without DoctrineBundle, Composer, plain PHP | None: "No SQL connection" | `SQLTabExecutionTests` (`symfony-app`, `composer`, `plain`) |
| WordPress 7.1 on SQLite | `$wpdb->query()` | `SQLTabExecutionTests` (SELECT; a connection name is refused) |

Databases: SQLite (3.x, through PHP's PDO) is the live evidence. MySQL/MariaDB and PostgreSQL go
through the same PDO calls (native prepares, `columnCount()`, `rowCount()`, `getColumnMeta()`)
but were not run against live servers in this change. MySQL runs with emulated prepares and
buffered results off for the statement; pdo_pgsql still loads a whole result before Runlet reads
it. The runner code keeps PHP 7.4 syntax; the tests ran on Herd PHP 8.4, and one (a project
driver's callable connection) on Herd PHP 7.4.33. Docker and SSH targets use the unchanged run path (the statement is a generated snippet);
they were not run end to end with SQL tabs, except the production confirmation, which appears
before any connection (checked with a never-connected production SSH profile).

**Run All Statements, completion's schema, and SQL snippets** ([#128](https://github.com/filipac/runlet/issues/128),
[#129](https://github.com/filipac/runlet/issues/129), [#130](https://github.com/filipac/runlet/issues/130)):

| Connection | Run All (transaction) | Schema | Evidence |
| --- | --- | --- | --- |
| Project driver PDO (SQLite file) | `beginTransaction()`/`commit()`/`rollBack()` | `sqlite_master` + `pragma_table_info` | `SQLScriptExecutionTests` (also on Herd PHP 7.4.33), `SQLSchemaExecutionTests`; Debug app |
| Project driver callable (SQLite) | `BEGIN`/`COMMIT`/`ROLLBACK` through the callable | catalogs tried in turn; SQLite's answers | `SQLScriptExecutionTests`, `SQLSchemaExecutionTests` (`custom-driver` `archive`) |
| Project driver `sqlSchema()` | — | the driver's own tables and columns | `SQLSchemaExecutionTests` |
| Laravel 13.34 (`laravel-app`) | PDO | `sqlite_master` | `SQLSchemaExecutionTests` |
| illuminate/database through Capsule; Doctrine DBAL 3.10 and 4.5 | PDO | `sqlite_master` | `SQLSchemaExecutionTests` (`eloquent-app`, `eloquent-app-modern`) |
| WordPress 7.1 on SQLite (`$wpdb`) | `BEGIN`/`COMMIT`/`ROLLBACK` through `$wpdb->query()` | `information_schema` (MySQL), else `sqlite_master` | `SQLScriptExecutionTests` (reads only), `SQLSchemaExecutionTests` |

Live servers ([#21](https://github.com/filipac/runlet/issues/21)): MariaDB 11 and PostgreSQL 14,
in throwaway `runlet-fixtures` containers (`scripts/setup-fixtures.sh databases`), through host PHP
8.4's `pdo_mysql` and `pdo_pgsql` (`SQLLiveDatabaseTests`). Covered: the schema explorer's details
(keys, composite primary keys, foreign keys, indexes, views, defaults, and row estimates), a
statement with its schema, MariaDB's implicit commit in Run All, and PostgreSQL rolling back DDL.
MySQL 8 itself (the same `information_schema` queries as MariaDB) and SQL Server
(`INFORMATION_SCHEMA`; columns' details only) were not run against live servers.
Show Definition ([#148](https://github.com/filipac/runlet/issues/148)) was run on the same MariaDB 11
and PostgreSQL 14 (`SQLDefinitionLiveTests`) and on SQLite through a PDO, a callable, and a saved
connection, also on Herd PHP 7.4 (`SQLDefinitionTests`). Its PostgreSQL reconstruction needs
PostgreSQL 12 or later (`pg_attribute.attgenerated`); MySQL 8's `SHOW CREATE` was not run live;
SQL Server isn't supported. The Database pane's Server section ([#150](https://github.com/filipac/runlet/issues/150)) was run on the same MariaDB 11 and PostgreSQL 14 (`SQLServerPanelLiveTests`, with a user without `PROCESS`, `pg_read_all_stats`, or `pg_signal_backend`) and on SQLite, also on Herd PHP 7.4 (`SQLServerPanelRunnerTests`); MySQL 8's lock waits (`performance_schema.data_lock_waits`) were not run live, and SQL Server isn't supported. Saved data: `TabState.sqlTransaction` is written only when
off, and `Snippet.language` only for SQL snippets, so sessions and snippet libraries from
earlier versions load unchanged (`PersistenceTests`).

**Saved connections** ([#138](https://github.com/filipac/runlet/issues/138); guide:
[sql-tabs.md](sql-tabs.md#saved-connections)). A saved connection is opened by the target's own
PHP with the `plain` bootstrap (no project code), so it needs that PHP's PDO driver. Its
password lives in the login keychain and reaches PHP only in the runner request on stdin.

| Target and database | Result | Evidence |
| --- | --- | --- |
| Local project, SQLite file (Herd PHP 8.4 and 7.4.33) | A statement, Run All in a transaction, the schema with its foreign key, Test Connection; no project code loaded; no event holds the password | `SQLSavedConnectionTests` |
| Plain PHP project (no driver), MariaDB 11 and PostgreSQL 14 | Test Connection (version, database, user), a statement with its schema, indexes; a wrong password's error without either password; MySQL's echoed statement with the password replaced | `SQLLiveDatabaseTests.savedConnections` (live fixture containers, host PHP 8.4) |
| Docker `php:8.4-cli` and `php:7.4-cli` fixtures | In-memory SQLite works; PostgreSQL says "This target's PHP … has no pdo_pgsql driver. It has: sqlite." | `SQLSavedConnectionDockerTests` |
| SSH fixture (PHP 8.4 over `ssh -T`, Keep compiled PHP on) | In-memory SQLite on the server; the missing-driver message; the opcode file cache holds no password | `SQLSavedConnectionSSHTests` |
| Debug app, local project, fixture PostgreSQL 14 | Editor, Test Connection, the SQL bar's list, a result, and the schema explorer | Screenshots in [PR #157](https://github.com/filipac/runlet/pull/157) |

Not run: MySQL 8 itself (MariaDB uses the same `pdo_mysql` code path), a server-side MySQL or
PostgreSQL connection from Docker or SSH (the fixture images lack `pdo_mysql`/`pdo_pgsql`, and
adding them to the shared SSH fixture image is [#160](https://github.com/filipac/runlet/issues/160)), and the real Keychain in the
automated tests (they use an in-memory store; `RUNLET_TEST_KEYCHAIN=1` runs one round trip
under a test-only service). Saved data: `targets.json` gains `databaseConnections` only when
there is one, sessions `sqlSavedConnection`/`sqlSavedConnectionName`, and workspaces
`sqlSavedConnection` (a name); files from earlier versions load unchanged, and a connection
with a driver this version doesn't know is left out rather than failing the file
(`SavedConnectionTests`).

**Saved connections from this Mac, and for all targets** ([#142](https://github.com/filipac/runlet/issues/142); guide:
[sql-tabs.md](sql-tabs.md#from-this-mac-and-for-all-targets)). A connection that opens from this
Mac (and every connection of all targets) runs in a local PHP process in an empty folder of
Runlet's, with the `plain` bootstrap: Runlet's own PHP 8.5 when installed (it has `pdo_mysql`,
`pdo_pgsql`, and `pdo_sqlite`; `scripts/php-runtime/craft.yml`), else the default PHP from
Settings. So the target's PHP needs no driver, and the Laravel sandbox (local or Docker) can use them.

| PHP and database | Result | Evidence |
| --- | --- | --- |
| Host PHP 8.4 (Herd), SQLite file outside any project | A statement and its schema, Load Schema, Test Connection with its PDO drivers; nothing written to Runlet's folder; no event holds the password | `LocalConnectionLaunchTests` |
| Host PHP 8.4 (Herd), MariaDB 11 and PostgreSQL 14 through their published ports | Test Connection, a bound statement, Run All, Load Schema, Explain, Load Next; read-only refusing a write; a wrong password without it in any event | `SQLLiveFromThisMacTests` (live fixture containers) |
| A PHP without the driver | "This Mac's PHP … has no pdo_pgsql driver. It has: sqlite. Download Runlet's PHP in Settings ▸ PHP …"; a custom DSN's missing driver says Runlet's PHP lacks it too | `LocalConnectionLaunchTests.messagesSayThisMac` |
| Debug app, fixture MariaDB 11 and PostgreSQL 14 | The editor, Test Connection naming the PHP, the pickers of a project and the sandbox, a result | Screenshots in [PR #175](https://github.com/filipac/runlet/pull/175) |

Not run: Runlet's own PHP in the automated tests unless `RUNLET_TEST_RUNLET_PHP` names a scratch
install (they skip otherwise, so the owner's install is never used), and SQL Server from this Mac
(Runlet's PHP has neither `pdo_sqlsrv` nor `pdo_dblib`; a default PHP that has one works as on a
target). Saved data: `targets.json` gains `allTargets` and `connectFrom` only on connections
that use them; a Runlet before #142 leaves connections of all targets out (they have no
`scope`) and an unknown `connectFrom` leaves a connection out rather than opening it elsewhere
(`LocalConnectionTests`).

**Saved connections through an SSH profile's tunnel** ([#143](https://github.com/filipac/runlet/issues/143); guide:
[sql-tabs.md](sql-tabs.md#through-an-ssh-tunnel), [ssh.md](ssh.md#sql-tunnels)). A local forward on
the profile's OpenSSH control master (`ssh -O forward` / `-O cancel`, macOS's `/usr/bin/ssh`), and
this Mac's PHP connecting to it.

| Setup | Result | Evidence |
| --- | --- | --- |
| Fixture OpenSSH (Debian, PHP 8.4) forwarding to MariaDB 11 and PostgreSQL 14 by Compose service name; host PHP 8.4 (Herd) | Test Connection, a bound statement, Run All, Load Schema, Show Definition, Explain, Load Next, Stop's server cancel through the same forward; the listener `ssh`'s, on 127.0.0.1 only, gone after use and after the idle time; history and snippets running again through it | `SQLLiveTunnelTests` (live fixture containers) |
| PostgreSQL 14 with TLS verify-full through the tunnel | The certificate's name (`postgres`) accepted through `hostaddr=127.0.0.1`; an address it doesn't name refused | `SQLLiveTunnelTests.postgresVerifiesTheServersNameThroughTheTunnel` |
| A master that isn't open | The tunnel refuses and opens nothing | `SQLLiveTunnelTests`, `SSHTunnelTests` |
| Debug app, fixture SSH host and PostgreSQL 14 | A result through the tunnel, the editor, Test Connection, the picker, a statement reopened from Run History reusing the forward; Disconnect removing it | Screenshots in [PR #177](https://github.com/filipac/runlet/pull/177) |

Not run: MySQL's TLS verification through a tunnel against a certificate without `127.0.0.1`
(it fails by design; the fixture's certificate names 127.0.0.1), SQL Server through a tunnel,
jump hosts (`-J`, which `-O forward` doesn't use: the forward rides the existing master), and a
password or 2FA profile's tunnel (the same `-O forward` on a master Connect… opened; the ask's
Connect… path opens the terminal as the SSH banner does). Saved data: `targets.json` gains
`"connectFrom": "sshTunnel"` and `"sshProfile"` only on tunnelled connections; a Runlet before
#143 leaves them out (`SSHTunnelConnectionTests`).

**Read-only saved connections and their own environment** ([#139](https://github.com/filipac/runlet/issues/139); guide:
[sql-tabs.md](sql-tabs.md#read-only-connections)). The runner makes the session read-only right
after connecting and checks it; Runlet and the runner refuse writing and session-changing
statements before sending them.

| Database and PHP | How the database enforces it | Evidence |
| --- | --- | --- |
| MariaDB 11.8 (host PHP 8.4, `pdo_mysql`) | `SET SESSION TRANSACTION READ ONLY`, checked with `@@session.transaction_read_only`: `INSERT`, `UPDATE`, `CREATE`/`DROP TABLE`, `CREATE TEMPORARY TABLE`, and `FOR UPDATE` fail with error 1792; a session switched back past the checks is read-only again for Run All's next statement | `SQLLiveDatabaseTests.readOnlySavedConnections` |
| PostgreSQL 14 (host PHP 8.4, `pdo_pgsql`) | `SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY`, checked with `SHOW default_transaction_read_only`: the same writes, temporary tables, `FOR UPDATE`, and `nextval()` fail with SQLSTATE 25006 | `SQLLiveDatabaseTests.readOnlySavedConnections` |
| SQLite (Herd PHP 8.4 and 7.4.33) | The file opened with `SQLITE_OPEN_READONLY` (`PDO::SQLITE_ATTR_OPEN_FLAGS`, PHP 7.3+; `Pdo\Sqlite::ATTR_OPEN_FLAGS` first on 8.4+) and `PRAGMA query_only = ON`: an `INSERT` fails ("attempt to write a readonly database"), also after `PRAGMA query_only = 0` | `SQLReadOnlyConnectionTests` |
| MySQL 5.6.5+ / MariaDB 10.0+ (documented) | Read-only sessions exist from these versions; older servers fail the run with the database's error and nothing runs. `tx_read_only` is checked when `transaction_read_only` doesn't exist (MySQL before 5.7.20, MariaDB before 11.1). | Not run |

Not run: MySQL 8 itself (MySQL documents that DML on temporary tables stays possible in a
read-only session; Runlet refuses it before sending), and connection poolers in transaction mode
(a session setting doesn't follow the client there; the guide says to use a read-only user).
Saved data: `targets.json` gains `readOnly`, `environment`, and `color` on a saved connection
only when they aren't at their defaults; connections from earlier versions load as read-write
development connections without a colour (`ReadOnlyConnectionTests`).

**Connection options: TLS, socket, charset, init statements, SQL Server, custom DSNs**
([#140](https://github.com/filipac/runlet/issues/140); guide:
[sql-tabs.md](sql-tabs.md#connection-options)). Certificate and key files are paths where the
target's PHP runs; Runlet never reads them.

| Database and PHP | Result | Evidence |
| --- | --- | --- |
| PostgreSQL 14 with TLS (host PHP 8.4 and Herd 7.4.33, `pdo_pgsql`) | Off unencrypted; Prefer, Require, Verify CA, and Verify CA and host name on TLSv1.3; a CA that didn't sign the server fails Require (libpq checks a given CA), Verify CA, and Verify; a name the certificate lacks (`hostaddr`) passes Verify CA and fails Verify; the client certificate reaches `pg_stat_ssl`; `client_encoding` and `application_name`; init statements on a read-only connection, a writing function in one refused by the session | `SQLLiveTLSTests` (fixture with throwaway certificates) |
| MariaDB 11.8 with TLS (host PHP 8.4 and Herd 7.4.33, `pdo_mysql`/mysqlnd) | No TLS without a mode (mysqlnd encrypts only when an SSL attribute is set); Require and Verify on TLSv1.3; the other CA passes Require and fails Verify; `REQUIRE SSL` and `REQUIRE X509` users; `charset=latin1`; init statements on a read-only connection, a writing stored function in a `SET` refused by the session | `SQLLiveTLSTests` |
| Herd PHP 7.4.33, MySQL verification failure | The PHP process crashes (SIGTRAP) when mysqlnd's certificate check fails; Runlet reports the runner ending. A PHP build bug (successes work) | Observed with raw PDO; not part of the tests |
| SQL Server, host PHP 8.4 with `pdo_sqlsrv` 5.13 and no ODBC driver | Every DSN Runlet builds (TLS Off, Require, Verify, the default; `APP`, `MultiSubnetFailover`) passes pdo_sqlsrv's keyword parser and reaches its "requires the Microsoft ODBC Driver" error; an unknown keyword is reported in pdo_sqlsrv's words; pdo_dblib DSNs are checked as text | `SQLConnectionOptionsTests` |
| SQLite through a custom DSN (host PHP 8.4) | A statement, the schema, Test Connection; a driver the PHP lacks is named with the ones it has | `SQLConnectionOptionsTests` |

Not run: SQL Server itself (**unverified** until a fixture exists, [#53](https://github.com/filipac/runlet/issues/53)), pdo_dblib, Unix sockets
(the fixtures' sockets aren't reachable from this Mac; the DSNs are checked as text), MySQL 8,
and MySQL's Require against a server without TLS (mysqlnd is expected to refuse; the runner's
`Ssl_cipher` check stops the run either way). Saved data: `targets.json` gains `socket`,
`charset`, `tls`, `initStatements`, `options`, and `dsn` on a saved connection only when set;
connections from earlier versions load unchanged, and a `tls` this version can't read leaves the
connection out (`ConnectionOptionsTests`).

### Output pane: hide until a run, Escape hides it ([#60](https://github.com/filipac/runlet/issues/60))

Two switches in **Settings ▸ General ▸ Output**, both off by default, so nothing changes unless
you turn them on:

- **Hide the output pane until a run.** A tab that hasn't run shows the editor alone. When a run
  starts in it (Run, Run Selection, Profile Run, an approved AI client run, or the sandbox
  auto-run you turned on for the tab), the pane appears right of or below the editor, at the
  saved split position. Clear Output on a tab that isn't running hides it again, and switching
  tabs shows or hides it with the tab. Show/Hide Output Pane (⌃⌘O) shows or hides it for the
  current tab until its next run; Move Output Right/Below shows it in its new place. This state
  is per tab and never saved: opened and restored tabs start hidden, and opening, importing, or
  restoring code never runs it.
- **Escape hides the output pane.** Escape in the editor hides the tab's pane until its next run
  (or Show/Hide Output Pane), without changing the saved Show/Hide setting, so a habitual Escape
  never leaves later runs without output. It only acts on the Escape key alone and only when
  nothing else wanted it: an open completion list, signature or hover popup, or inline-value
  panel closes first, as before; a visible find bar or text being composed (input methods) keeps
  Escape; ⌘. (also a cancel key to AppKit) still means Stop; and the palette, sheets, and the
  terminal have their own key focus, so Escape there never reaches the editor. With the pane
  already hidden, Escape does what it did before.

Neither switch changes where the pane goes or how big it is: it reappears at the saved layout
and split fraction (`editorSplitRight` / `editorSplitBottom`), which only dragging the divider
changes.

Verified with a Debug build and scratch data (sandbox, PHPantom), with the settings seeded in the
scratch `settings.json`: a restored tab hidden before its run; the pane appearing on the right at
the saved 58% and below at the saved 55% after Run; Escape closing the completion list first and
the inline-value panel first, then hiding the pane; ⌘. not hiding it; the next run showing it at
the same size; a new tab hidden; Clear Output hiding it; Show/Hide showing an empty pane; and the
split fractions and Show/Hide setting unchanged in `settings.json` afterwards. With both switches
off, the pane shows before a run and Escape leaves it. Escape was sent with the DEBUG step
`editor-key:escape`, which hands a key press to the editor's `keyDown` (the path a real key
takes from there), not through the window server. Covered by unit tests only: settings decoding
and defaults, and the visibility rules for every event (`OutputPaneVisibilityTests`). Not
checked end to end: hover and signature popups, a find bar, or input-method composition during
Escape; Escape in the palette, sheets, or the terminal (they have their own focus); and runs
started by an AI client.

### Application environment and production history ([#12](https://github.com/filipac/runlet/issues/12))

The runner adds `environment` to the `bootstrapped` event (PHP 7.4 syntax; a runner without it
simply leaves the key out, and the app reads its absence as "not reported"). What each driver
reports:

| Driver | Environment | Verified with |
| --- | --- | --- |
| Laravel | `app()->environment()`: `APP_ENV` (a process environment variable wins over `.env`), else `app.env` | Laravel 13.34.0: the bundled sandbox (`local`), the `laravel-app` fixture (`local`, and `production` with `APP_ENV=production` in the process environment) |
| Lumen | `app()->environment()` | A stub application only (`LaravelFamilyDriverTests`) |
| Laravel Zero | `app()->environment()` | A stub application without the method only: nothing is reported, and the run is unaffected |
| Symfony | The kernel's environment (`APP_ENV`, default `dev`) | Symfony 8.1 fixture (`dev`) |
| WordPress | `wp_get_environment_type()` (5.5+): `WP_ENVIRONMENT_TYPE`, else `production` | WordPress 7.1 fixture: `production` when unset, `local` from the process environment |
| Plain PHP, Composer | None | `plain` and `composer` fixtures |
| Project drivers | `environment()`, with or without `: ?string` | Composer fixture with `.runlet` drivers on PHP 8.4.25 and Herd PHP 7.4.33; a throwing `environment()` leaves a Run Log line and the run completes |

Production names are `production`, `prod`, `prd`, and `live` (the whole name, any case); local
names, for the informational note on production targets, are `local`, `development`, and `dev`.

Verified with a Debug build (bundle id `dev.runlet.Runlet.prshots`), scratch data, and two
copies of the `laravel-app` fixture under `build/` (one with `APP_ENV=production` in its `.env`),
on PHP 8.4.25: the local project shows no notice; the production copy shows the Mark as
Production notice after its first run, which ran without a confirmation as before; Mark as
Production saves the target as production (badge, red status bar), and the next run asks
first; History shows the earlier run without a badge and the confirmed run with PROD, both
with `env production`, after the target was marked; Dismiss hides each notice, and after a
relaunch neither returns (the dismissals are in `facts.json`); a production target whose app
reports `local` shows the informational note with Dismiss only; restoring the session ran
nothing. Covered by unit tests only: decoding of the new field and of older payloads and
history files, the name rules, every marking × reported × dismissed combination, and the
history snapshot when the same code runs again (`AppEnvironmentTests`). Not run end to end:
Docker and SSH targets (the field and the notice don't depend on the target kind; the runner
is the same), the History tooltip (hover), real Lumen and Laravel Zero applications, and
Symfony's `prod` environment.

## PHPantom 0.10.0 prototype gate

Binary: release tarballs for `aarch64-apple-darwin` and `x86_64-apple-darwin`, SHA-256 pinned in
`scripts/fetch-phpantom.sh`, combined into a universal binary. Launched with `PATH=/usr/bin:/bin`
(no host PHP) and `XDG_CONFIG_HOME` pointing to an app-owned directory.

| Gate | Result | Evidence |
| --- | --- | --- |
| 1. Tagless unsaved scratch document with project completion, no disk writes | Pass. An in-memory `file://<root>/.runlet-scratch/tab-<id>.php` URI resolves against the real root; nothing is created on disk. | `PHPantomTests.taglessScratchCompletionUsesProjectRootWithoutWritingFiles` |
| 2. Positions/edits across synthetic tag and Unicode | Pass. Synthetic `<?php\n` occupies its own line, so only lines shift; both sides use UTF-16. Import `additionalTextEdits` map to editor line 0. | `importEditsMapBackToEditorCoordinates`, `hoverSignatureHelpAndDiagnosticRangesWithUnicode`, `MappingTests` |
| 3. Different PHP target, existing `.phpantom.toml`, vendor files, no repo/global changes | Pass. Per-session `[php] version` is written to the app-owned config home; the project's `.phpantom.toml` is read but never modified. | `workspacesAreIsolatedAndRespectProjectConfiguration` |
| 4. Suppress external analyzers/formatters | Pass. App config sets `phpstan/phpcs/mago` commands and formatter paths to `""` and disables workspace diagnostics. Control experiment: with an empty config plus a project `.phpantom.toml` `workspace = true`, PHPantom launched the project's `vendor/bin/phpstan`; with Runlet's config it did not. A project that explicitly sets a tool **command** in its own `.phpantom.toml` would still override this (explicit project opt-in). | `externalAnalyzersAreNotLaunchedImplicitly` |
| 5. Isolation and crash recovery | Pass. One process per workspace key; a killed server restarts automatically and re-opens documents from the client's copy. | `workspacesAreIsolatedAndRespectProjectConfiguration`, `crashedServerRestartsAndRestoresDocuments` |

Server capabilities advertised by 0.10.0: completion (+resolve), hover, signature help,
definition, type definition, implementation, references, document highlight/symbols, workspace
symbols, code actions, code lens, formatting, on-type formatting, rename, document links,
folding, semantic tokens, inlay hints, selection ranges. Runlet's MVP uses completion, resolve,
hover, signature help, and pushed diagnostics.

Observed quirks:
- Completion `insertText` uses snippet syntax (`PriceFormatter()$0`) even when the client
  declares `snippetSupport: false`; Runlet converts snippets to plain text (`SnippetText`).
  Required parameters are placeholders (`split(${1:\$pattern})$0`, `DateTimeZone(${1:\$timezone})$0`
  after `new`); methods with only optional parameters get `trim()$0` but list them in the label
  (`trim($characters = ...)`); built-in functions get `array_map()$0` with no parameter list in
  the label. Calls are inserted as `name()` without placeholder text (`CompletionInsertion`).
- Startup on the Laravel fixture: initialize ≈ 0.7 s cold, completion ≈ 20 ms.

### Laravel completion (scenario 15; PHPantom 0.10.0, Laravel 13.34.0)

Recorded by `Packages/RunletKit/Tests/RunletLanguageTests/LaravelCompletionTests.swift` (16
tests, all passing on 2026-10-03 for [#55](https://github.com/filipac/runlet/issues/55)). The tests
assert what PHPantom actually returns. Where it falls short, the test asserts the observed result
and carries an `// Unsupported in PHPantom 0.10.0:` comment, so a PHPantom upgrade that changes
the behavior fails the test and this table must be updated.

The tests use sessions as the app opens them, with Runlet's [model copies](#runlets-model-copies).
Where a copy works around a PHPantom gap, the test also checks a session without them
(`modelOverlays: false`) and asserts the PHPantom behavior. "Supported (Runlet)" in the table
means supported because of the copies.

Workspaces used:

- **Fixture:** `Tests/Fixtures/laravel-app`. It is a copy of the pinned sandbox template (same
  `vendor/`, config, and `User` model) plus `App\Models\Widget` (`$fillable`, `casts()` with
  `'price' => 'integer'`, `scopeExpensive`, a `widgets` migration) and `App\Services\PriceFormatter`.
  Results on the fixture therefore also describe the sandbox.
- **Model workspace:** the fixture has no relations, and its only cast matches its column type.
  `ModelWorkspace` (in the same test file) builds a temporary project whose `vendor` is a symlink
  to the fixture's. It has `Gadget`, `Part`, `Manual`, `Tag`, and `Gizmo` models (relations with a
  generic `@return`, with no return type, and with only a native `HasMany`, `HasOne`,
  `BelongsToMany`, or `BelongsTo`; `casts()` with and without a trailing comma, single-line and
  multi-line; a `$casts` property), `bootstrap/providers.php` registering `AppServiceProvider`
  (`Collection::macro('whisper', …)`, `Str::macro('shoutCase', …)`), and an
  `UnregisteredServiceProvider` with its own macro. Migrations in this temporary workspace were
  not picked up for attribute inference (cause not investigated), so its tests rely on casts and
  relations only.

All snippets are tagless, as typed in a scratch tab, and use runtime aliases (`DB`, `Cache`,
`Str`) without `use` statements. Test names below are `LaravelCompletionTests.<test>`.

| Area | Case (snippet → expectation) | Result | Test |
| --- | --- | --- | --- |
| Facades | `DB::table('widgets')->` → query-builder methods (`where`, `orderBy`, `get`, `first`, `pluck`, `paginate`); `get` is `Collection<int, stdClass>`. The fully qualified facade gives the same list. | Supported | `facadeQueryBuilderChainOffersBuilderMethods` |
| Facades | `Cache::` → `get`, `put`, `remember`; hover on `Cache::get(` shows the facade's `@method` signature | Supported | `cacheFacadeStaticMethods` |
| Facades | `Str::` → `slug`, `limit`; hover shows the method's PHPDoc summary | Supported | `strStaticMethods` |
| Facades | Return types through facades: `Cache::store()->get`, `DB::connection()->table`, `Http::get(…)->json` | Supported | `facadeAccessorReturnTypesChain` |
| Eloquent scopes | `scopeExpensive` is offered as `expensive()` on `Widget::query()->` (detail `Builder<Widget>`) and statically (`Widget::exp` → `expensive`). `Widget::query()->expensive()->` → `get`, `first`, `where`; `…->get()->first()->` → `price`, `name` | Supported | `localScopeIsOfferedAndKeepsTheBuilderChain` |
| Eloquent builder | `Widget::where('price', '>', 1)->` → `orderBy`, `with`, the scope. Terminal calls resolve to the model: `->orderBy()->first()`, `->with()->where()->get()->first()`, `->latest()->paginate()->first()`, `findOrFail`, `firstWhere`, `create`. Dynamic `whereName('x')->` is treated as a builder call. Item details show the unsubstituted template (`first` is `TModel\|null`), but the chain itself resolves. | Supported | `builderChainFromStaticWhere` |
| Eloquent relations | Relations with a generic PHPDoc (`@return HasMany<Part, $this>`) or with no return type (`return $this->hasMany(Part::class)`) resolve the related model through the property (`->partsGeneric->first()->`), after `with()`, and as a relation builder (`->partsGeneric()->` → `where`, `get`, `first`). An untyped `belongsTo` resolves the parent model, including its casts. | Supported | `relationsResolveTheRelatedModel` |
| Eloquent relations | A relation declared with only the native return type (`public function parts(): HasMany`, the style of `make:model` and the Laravel docs) resolves the related model: `->parts` is `Collection<Part>`, `->parts->first()->`, `with('parts')`, and `->parts()->first()->` offer Part's members, and `parts()` is `HasMany<Part>`. Also checked for `HasOne`, `BelongsToMany`, and `BelongsTo` (`Part::first()->maker->` → Gadget's `is_active` as `bool`). PHPantom alone reads a bare `HasMany` (`->parts` is `Collection<Model>`, only base `Model` members); see [report draft 1](#1-relations-with-only-a-native-return-type-lose-the-related-model). | Supported (Runlet) | `relationsResolveTheRelatedModel` |
| Attributes | Columns from migrations, with types: `Widget::first()->` → `price` (`int`), `name` (`string`), `id` (`int`), `created_at` (`Carbon`); hover on `$w->price` shows `int` | Supported | `modelAttributesFromMigrationWithTypes` |
| Casts | A cast that changes the type is reported with its source (`source: cast …`): `datetime` → `Carbon` (sandbox `User::email_verified_at`), `boolean` → `bool`, `array` → `array`, `decimal:2` → `float`, `integer` → `int`. Read from a `casts()` method whose array has a trailing comma, and from the `$casts` property. | Supported | `castsDefineAttributeTypes`, `modelAttributesFromMigrationWithTypes` |
| Casts | The **last** entry of a `casts()` return array without a trailing comma (single-line or multi-line) is read: the fixture's `['price' => 'integer']` gives `source: cast \`integer\``, `Gizmo::m_two` is offered, and `Manual::published_at` is `Carbon` from `datetime`. PHPantom alone ignores that entry: `price` comes from the migration column (`source: database column`), and an attribute that exists only in such an entry is unknown (no completion, no hover); see [report draft 2](#2-the-last-casts-entry-without-a-trailing-comma-is-ignored). The `$casts` property was never affected. | Supported (Runlet) | `castsDefineAttributeTypes`, `modelAttributesFromMigrationWithTypes` |
| Collections | `Widget::all()->first()->` → `price` (`int`), `name`; `Widget::all()` is `Collection<int, Widget>`. The element type survives `filter(fn …)`, `sortBy()->values()`, `cursor()`, and `lazy()`, and reaches closure parameters (`map(fn ($w) => $w->`, `each(function ($w) { $w-> })`) and `foreach` variables. | Supported | `eloquentCollectionElementType` |
| Collections | `Widget::all()->keyBy('id')` is `Collection<array-key, mixed>`, so `->first()->` offers only base `Model` members, no `price`. `groupBy('id')` gives `Collection<array-key, Collection<int, mixed>>`. Every subclass of `Illuminate\Support\Collection` is affected, the Eloquent collection included; `Illuminate\Support\Collection` and `LazyCollection` themselves keep the element type (`Collection<array-key, Widget>`), so `Widget::all()->toBase()->keyBy('id')->first()->` offers `price`. Runlet has no workaround; see [report draft 3](#3-keyby-and-groupby-lose-the-element-type-on-collection-subclasses). | **Unsupported** (PHPantom) | `eloquentCollectionElementType` |
| Collections | `collect([new App\Services\PriceFormatter])->first()->` → exactly `format` (`string`); hover is `PriceFormatter\|null` | Supported | `collectHelperElementType` |
| Helpers | `app(App\Services\PriceFormatter::class)->` and `resolve(…::class)->` → exactly `format`. `str('a')->slug`, `now()->format`, and `auth()->user()->` (the `User` model's `email`) also resolve. | Supported | `containerHelpersResolveClassStrings` |
| Helpers | `config('app.` → configuration keys as full dotted labels (`app.name`, `app.timezone`, nested `app.maintenance.driver`); `config('` lists keys from every config file (`database.default`, `cache.default`). Requested explicitly, as with Ctrl-Space in the editor, because `'` and `.` are not completion triggers. | Supported | `configKeyCompletion` |
| Signature help | `Str::limit('abc', ` → `($value, $limit = 100, $end = '...', $preserveWords = false): string`, four parameter ranges, per-parameter docblock types (`string`, `int`, `string`, `bool`), active parameter 1. The label omits the method name (cosmetic). | Supported | `strLimitSignatureHelp` |
| Macros | A macro registered in the same snippet (`Collection::macro('shout', …); collect()->sh`) is offered | Supported | `macros` |
| Macros | A macro registered in a service provider's `boot()` is offered when the provider is registered: `Collection::macro('whisper', …)` in `AppServiceProvider` (listed in `bootstrap/providers.php`) gives `collect()->whisper()` and `Gadget::all()->whisper()`, and `Str::macro('shoutCase', …)` gives `Str::shoutCase`. PHPantom reads providers from `bootstrap/providers.php`, `config/app.php`, and package providers in `vendor/composer/installed.json`, plus the classes they reference. A provider that is not registered (and so never boots) is not read, so its macros are not offered. Earlier results listed this as unsupported because the test workspace had no `bootstrap/providers.php`; PHPantom 0.10.0 already supported it. The fixture and the sandbox register `AppServiceProvider`. | Supported | `macros` |
| Model methods | `$w->save`, … | Supported | `PHPantomTests.taglessScratchCompletionUsesProjectRootWithoutWritingFiles` |
| Classes | Class completion with an automatic `use` import mapped to editor line 0 | Supported | `PHPantomTests.importEditsMapBackToEditorCoordinates` |

Not covered yet:

- A real user application (local or Docker) rather than the sandbox-derived fixture, which plan
  scenario 15 asks for.
- The rendered editor: only array-function completion is checked by a UI test
  (`RunletUITests.testCompletionPopupForTaglessSnippet`). The Laravel cases above are checked at
  the language-service level, through the same scratch-document mapping the editor uses.
- Other dynamic members (custom Eloquent builders, attribute accessors, `Attribute` mutators,
  `__call` forwarding in user classes, packages that register macros at runtime).

### Runlet's model copies

PHPantom 0.10.0 misreads two common Eloquent model shapes (report drafts 1 and 2 below). Runlet
works around both without patching PHPantom and without writing anything
(`Packages/RunletKit/Sources/RunletLanguage/EloquentOverlay.swift`, [#55](https://github.com/filipac/runlet/issues/55)):

- **When.** Each time a project workspace's server starts (including restarts), Runlet reads
  the PHP files under the project's Composer `autoload.psr-4` directories (or `app/` when there
  are none), skipping `vendor`, `node_modules`, hidden directories, `storage`, and
  `bootstrap/cache`. At most 5,000 files are read, none larger than 1 MB, and at most 1,000
  copies are opened.
- **What changes.** A copy is made only when a file has one of the two shapes:
  - A relation method that declares only a native relation return type (`HasOne`, `HasMany`,
    `BelongsTo`, `BelongsToMany`, `MorphOne`, `MorphMany`, `MorphToMany`, `HasManyThrough`,
    `HasOneThrough`, plain or qualified), has no `@return` tag, and whose body calls the
    matching `$this->hasMany(Related::class …)` builder, checked the way PHPantom checks it. The
    copy replaces `: HasMany` with spaces of the same width, so PHPantom infers
    `HasMany<Related>` from the body, as it does for methods without a return type.
  - A `casts()` method whose returned array has no comma after its last entry. The copy adds
    the comma.

  Both changes are equivalent PHP. Relations with a generic `@return`, nullable or union
  types, `MorphTo`, and calls without a `::class` argument are left alone. Comments, strings,
  and heredocs are skipped; a file the scanner cannot read to the end is left alone.
- **How.** The copies are sent with `textDocument/didOpen` under the files' own URIs, so they
  replace the disk version in that session only. Their diagnostics are never shown (the editor
  shows diagnostics for its own scratch URI only). The project is not modified
  (`LaravelCompletionTests.modelCopiesStayInMemory` compares every file before and after).
- **Cost.** Files are pre-filtered with a byte search before they are decoded. In a debug test
  build, scanning the Laravel framework's `src` (1,705 files, 7.5 MB, as a stand-in for a large
  project) took 0.33 s and produced no copies. A generated project with 300 models, each
  needing a copy, reached ready in 0.06 s (0.02 s without copies), and its first completion
  took 0.25 s (0.44 s without; PHPantom's cold start varies).
- **Freshness.** Runlet does not send file-change notifications to PHPantom, so a model edited
  on disk is seen after Restart Language Server, as for any other project file; the copies are
  rebuilt then.
- **Retiring them.** When a PHPantom release fixes a gap, the `modelOverlays: false` check in
  the tests fails, and the matching rewrite should be removed ([#117](https://github.com/filipac/runlet/issues/117)).

### PHPantom upstream report drafts

Drafts for the owner to file in the PHPantom repository; nothing has been filed. Reproduced with
PHPantom 0.10.0 (`phpantom_lsp --version`; release binaries pinned in `scripts/fetch-phpantom.sh`)
on macOS, Laravel 13.34.0. The cause notes refer to the 0.10.0 source.

#### 1. Relations with only a native return type lose the related model

A Laravel app (`composer.json` with `"App\\": "app/"`):

```php
<?php
// app/Models/Post.php
namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\HasMany;

class Post extends Model
{
    public function comments(): HasMany
    {
        return $this->hasMany(Comment::class);
    }
}
```

```php
<?php
// app/Models/Comment.php
namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class Comment extends Model
{
    public function post()
    {
        return $this->belongsTo(Post::class);
    }
}
```

```php
<?php
// any other file
\App\Models\Post::first()->comments->first()->   // complete here
```

- **Expected:** `$post->comments` is `Collection<int, Comment>` (or `Collection<Comment>`, as for
  a method without a return type), and the completion offers `Comment` members (`post`).
- **Actual:** hover on `->comments` shows `Collection<Model>`; the completion offers only
  `Illuminate\Database\Eloquent\Model` members. Removing `: HasMany` makes it work, as does a
  `@return HasMany<Comment, $this>` docblock.
- **Why it matters:** `make:model` stubs and the Laravel documentation declare relations this
  way, without generics.
- **Cause (0.10.0 source):** `parser/classes.rs` calls `infer_relationship_from_method` only when
  `return_type.is_none()`, so a native relation type without generics is never refined from
  the body. A fix: also infer from the body when the declared type is a bare relation class and
  the inferred relation has the same class.

#### 2. The last `casts()` entry without a trailing comma is ignored

```php
class Gizmo extends Model
{
    protected function casts(): array
    {
        return ['is_active' => 'boolean', 'released_at' => 'datetime'];
    }
}

Gizmo::first()->   // complete here
```

- **Expected:** `is_active` (`bool`) and `released_at` (`Carbon`).
- **Actual:** only `is_active`. The last entry is dropped whenever no comma follows it,
  single-line or multi-line (`'released_at' => 'datetime'\n];`). The `$casts` property form is
  not affected.
- **Cause (0.10.0 source):** `extract_casts_definitions` in
  `virtual_members/laravel/model_extraction.rs` passes the text from the first `[` after
  `return` to the end of the method body to `parse_casts_array`. That text ends with `}`, not
  `]`, so `strip_suffix(']')` does nothing, and the last comma-separated segment
  (`'released_at' => 'datetime'];\n    }`) has a value that is not a string literal. With a
  trailing comma, the leftover segment has no `=>` and is skipped, which hides the bug. A fix:
  cut the text at the matching `]`, or read the array from the AST.

#### 3. `keyBy` and `groupBy` lose the element type on Collection subclasses

```php
<?php
namespace App;

/**
 * @template TKey of array-key
 * @template TValue
 * @extends \Illuminate\Support\Collection<TKey, TValue>
 */
class MyCollection extends \Illuminate\Support\Collection {}

class Item { public function itemMethod(): int { return 1; } }

/** @var \App\MyCollection<int, \App\Item> $c */
$k = $c->keyBy('id');   // hover $k
$g = $c->groupBy('id'); // hover $g
```

- **Expected:** `$k` is `MyCollection<array-key, Item>` and `$g` is
  `MyCollection<array-key, MyCollection<int, Item>>`, as for `\Illuminate\Support\Collection`
  and `LazyCollection` themselves.
- **Actual:** `MyCollection<array-key, mixed>` and `MyCollection<array-key, MyCollection<int, mixed>>`.
  `keyBy(fn ($i) => 1)` gives `MyCollection<int, mixed>`. Renaming the template
  (`@template TModel`, as `Illuminate\Database\Eloquent\Collection` does) gives the same result,
  so `Model::all()->keyBy('id')->first()->` offers only base `Model` members. Methods returning
  `static` or `static<int, TValue>` without a method-level `@template` (`values()`, `sortBy()`,
  `unique()`, `chunk()`) keep the element type on the same subclass.
- **Notes:** `keyBy` and `groupBy` are declared on `Illuminate\Support\Enumerable` with a
  method-level `@template` and a conditional key type (`static<($keyBy is (array|string) ?
  array-key : …), TValue>`), and inherited through `{@inheritDoc}`. A hand-written interface,
  class, and subclass with the same docblocks (no Laravel) did **not** reproduce it, so the
  trigger is something else in the framework's `Collection`; it was not isolated further.
