# SQL tabs

Implemented under [#35](https://github.com/filipac/runlet/issues/35).

An SQL tab is a scratch SQL client for the tab's target. Each statement runs through the application's own database connection, the one its code uses, so Runlet never asks for or stores database credentials.

## Creating an SQL tab

- **File ▸ New SQL Tab** (also in the command palette). The tab uses the current tab's target.
- **Switch Tab Language (PHP/SQL)** in the Window menu and the command palette, or **Switch to SQL** / **Switch to PHP** in a tab's context menu. Switching runs nothing.
- **Open a `.sql` file** with File ▸ Open…, from Finder, or with `runlet report.sql`. The tab follows the file like a PHP file tab, and Save As writes `.sql`.

The language is saved with the tab, in the session, in `.runlet` workspaces (`"language": "sql"`), and in run history. Sessions, workspaces, and history from before SQL tabs open as PHP. Duplicate Tab and Reopen Closed Tab keep the language and the connection.

An SQL tab has an SQL highlighter (keywords, strings, comments, numbers, placeholders, function names, quoted identifiers, and table names after `FROM`, `JOIN`, `INTO`, `UPDATE`, and `TABLE`). Toggle Line Comment uses `--`. It has no PHPantom: SQL text gets no PHP diagnostics or completion, and the status bar shows **SQL** instead of the language server. Completion for SQL is tracked in [#128](https://github.com/filipac/runlet/issues/128).

## Running a statement

Run (⌘R) sends **one statement**:

1. **A selection**, if there is one, whatever Settings ▸ General says about running selections. It must hold exactly one statement.
2. Otherwise **the statement at the caret**: the one the caret is in; else the one that ended earlier on the caret's line (so the caret right after `;` runs that statement); else the next one; else the last one. A tab with a single statement runs it wherever the caret is.

Run Selection (⇧⌘R) needs a selection. Statements are separated by semicolons outside strings, quoted identifiers, comments (`--`, `#`, `/* */`), and PostgreSQL dollar-quoted bodies. A comment on the line where a statement ended belongs to that line, not to the next statement. The output notes which lines ran and on which connection.

**Several statements in one run are refused** before anything runs, with a message: select a single statement or put the caret in one. A script therefore never runs halfway. As a second guard, the runner prepares the statement natively (MySQL's emulated prepares are turned off for the run; PostgreSQL prepares one statement), so the database itself rejects a second statement the splitter missed. SQLite's PDO runs only the first statement of a prepared text. Running whole scripts is tracked in [#129](https://github.com/filipac/runlet/issues/129). Client commands such as MySQL's `DELIMITER` are not supported.

Statements are sent as written, without bindings. Strings follow standard SQL (`'it''s'`); MySQL's backslash escapes inside strings can confuse the statement splitter. PostgreSQL's `?` JSON operators need `??` with PDO, as in PHP code.

## Results

- A statement that returns rows shows a table: its columns in order (duplicate names kept, e.g. two `id` columns of a join), the rows, the row count, and the time the runner measured for executing and fetching. The table has the Table view's filter, sorting, row and cell copy, Copy CSV, and Export CSV. Copy Output and Copy Output as Markdown include it (tab-separated, or a Markdown table).
- Any other statement shows the number of rows it affected (`INSERT`, `UPDATE`, `DELETE`; DDL usually reports 0).
- A line under the result names the driver (`sqlite`, `mysql`, `pgsql`, …), the connection, and where the connection came from (for example `via Laravel DB::connection()`).

**Limits.** At most 1,000 rows per statement, at most 200 columns, 8 KiB per text cell, and 8 MiB of cells per result. A cut result says so (“Runlet shows at most 1,000 rows … add a LIMIT, or page with OFFSET”); the rows after the limit are not fetched, and MySQL results are read unbuffered for the run. PostgreSQL's driver still loads a whole result into PHP memory before Runlet reads its first rows, so use `LIMIT` on large tables. Bytes that aren't UTF-8 text show as binary (size and the first 32 bytes in hex), `NULL` as `NULL`.

Errors from the database (a syntax error, a missing table) show as the run's error. They never point at lines of Runlet's generated PHP.

## Connections

The bar above the editor picks the connection: **Default connection**, or a name from the application's configuration. After a run, the menu lists the connection names the project's driver reports (Laravel's `database.connections`, Doctrine's connection names), with the default first. **Other Connection…** takes any name. Only the name is stored with the tab. An unknown name fails with the driver's message and the list of known connections.

Runlet finds the connection in this order, in the same fresh PHP process that boots the application for a run:

1. **The project's driver**: `sqlConnection()` of a [project driver](drivers.md#sql-connections) in `.runlet/`, or of the built-in driver it extends.
2. **The built-in framework connections**, through the same APIs as [Explain](sql-explain.md):
   - Laravel, Lumen, Laravel Zero: `DB::connection($name)`'s PDO.
   - Symfony: the `doctrine` registry's connection (`getConnection($name)`), its PDO when it has one, else statements through DBAL.
   - WordPress: `$wpdb->query()` (one connection; a name is refused).
   - Any project whose code set up Eloquent (illuminate/database through Capsule) or `$wpdb`, even with a project driver that has no `sqlConnection()`.
3. Otherwise the run stops with **No SQL connection**: the project's driver provides none and the application set up no Eloquent connection or `$wpdb`. Runlet never guesses credentials. Plain PHP and Composer projects, and Symfony without DoctrineBundle, get this message. Add `sqlConnection()` to a project driver to use SQL tabs there.

Any PDO driver works. MySQL/MariaDB, PostgreSQL, and SQLite are the expected ones; the automated tests use SQLite (see [Validation](#validation)). A Laravel connection without a PDO (for example MongoDB) is refused with a message.

## Safety

- **Nothing runs by itself.** Opening, importing, or restoring an SQL tab (sessions, workspaces, `.sql` files, history, Reopen Closed Tab) never runs it, and switching a tab's language runs nothing.
- **No auto-run.** Sandbox auto-run ([#30](https://github.com/filipac/runlet/issues/30)) is PHP-only: the toggle is hidden on SQL tabs, and switching a tab to SQL turns it off.
- **No MCP.** AI clients' `run_php` runs PHP only. It never reuses a tab that was switched to SQL, and the app refuses to run an SQL tab's text as PHP from any caller.
- **Production always asks.** On a production target, every SQL run shows the confirmation (⌘↩ confirms), even during a 10-minute grace for snippet runs. The sheet shows the statement and the connection. When the statement can write (or Runlet can't tell), a red warning names why, for example `UPDATE`, `DROP`, `SELECT … INTO`, `FOR UPDATE, which locks rows`, or `EXPLAIN ANALYZE … DELETE`.
- **Development and staging targets don't ask**, for reads or writes: an SQL tab is a scratch client, like the PHP tabs that can write to the same database. Run History keeps every statement that ran.

**Write detection is best-effort.** A statement counts as read-only only when it starts with `SELECT`, `SHOW`, `DESCRIBE`, `EXPLAIN` (without `ANALYZE`), `VALUES`, `TABLE`, `WITH`, or `PRAGMA` without `=`, and holds no `INSERT`, `UPDATE`, `DELETE`, `MERGE`, `INTO`, `CREATE`, `DROP`, `ALTER`, or `TRUNCATE` outside strings and comments. Everything else gets a warning. Functions with side effects called from a `SELECT` (`nextval()`, stored procedures, locks) are not detected. On production the confirmation is shown for every statement anyway.

## Validation

- `SQLTabTests` (RunletCore): tab language decoding and persistence (sessions, workspaces, history), statement splitting and scope, write detection, the generated PHP's escaping of quotes, backslashes, `$`, and control characters, result decoding and summaries, and that SQL ignores the production grace.
- `SQLTabExecutionTests` (RunletExecution, host PHP): a project driver's PDO and callable connections, names and errors (`custom-driver`); the driver's method winning over the built-in Laravel connection (`custom-laravel-driver`); Laravel connections, named connections, unknown names, and database errors (`laravel-app`, in a scratch copy); Eloquent through Capsule found without a driver method (`eloquent-app`); Doctrine DBAL 3 and 4 through `SqlConnections::doctrine()`; WordPress `$wpdb` on SQLite; the row cap, binary and long cells; and the refusal on plain, Composer, and Symfony-without-Doctrine projects.
- The Debug app, with scratch data: a sandbox SQL tab running `INSERT`, `SELECT`, and `UPDATE`; the production confirmation on a never-connected production SSH profile; the unknown-connection and no-connection messages; a `.sql` file opened without running; the several-statements refusal. Screenshots are in [PR #120](https://github.com/filipac/runlet/pull/120).

Live MySQL, MariaDB, and PostgreSQL servers were not exercised by these tests; their behavior follows PDO's documented API (native prepares, `columnCount()`, `rowCount()`).
