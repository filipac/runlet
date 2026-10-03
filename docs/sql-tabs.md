# SQL tabs

Implemented under [#35](https://github.com/filipac/runlet/issues/35), with completion ([#128](https://github.com/filipac/runlet/issues/128)), Run All Statements ([#129](https://github.com/filipac/runlet/issues/129)), and SQL snippets ([#130](https://github.com/filipac/runlet/issues/130)).

An SQL tab is a scratch SQL client for the tab's target. Each statement runs through the application's own database connection, the one its code uses, so Runlet never asks for or stores database credentials.

## Creating an SQL tab

- **File ▸ New SQL Tab** (also in the command palette). The tab uses the current tab's target.
- **Switch Tab Language (PHP/SQL)** in the Window menu and the command palette, or **Switch to SQL** / **Switch to PHP** in a tab's context menu. Switching runs nothing.
- **Open a `.sql` file** with File ▸ Open…, from Finder, or with `runlet report.sql`. The tab follows the file like a PHP file tab, and Save As writes `.sql`.

The language is saved with the tab, in the session, in `.runlet` workspaces (`"language": "sql"`), and in run history. Sessions, workspaces, and history from before SQL tabs open as PHP. Duplicate Tab and Reopen Closed Tab keep the language and the connection.

An SQL tab has an SQL highlighter (keywords, strings, comments, numbers, placeholders, function names, quoted identifiers, and table names after `FROM`, `JOIN`, `INTO`, `UPDATE`, and `TABLE`). Toggle Line Comment uses `--`. It has no PHPantom: SQL text gets no PHP diagnostics or PHP completion, and the status bar shows **SQL** instead of the language server. SQL tabs have their own [completion](#completion).

## Running a statement

Run (⌘R) sends **one statement**:

1. **A selection**, if there is one, whatever Settings ▸ General says about running selections. It must hold exactly one statement.
2. Otherwise **the statement at the caret**: the one the caret is in; else the one that ended earlier on the caret's line (so the caret right after `;` runs that statement); else the next one; else the last one. A tab with a single statement runs it wherever the caret is.

Run Selection (⇧⌘R) needs a selection. Statements are separated by semicolons outside strings, quoted identifiers, comments (`--`, `#`, `/* */`), and PostgreSQL dollar-quoted bodies. A comment on the line where a statement ended belongs to that line, not to the next statement. The output notes which lines ran and on which connection.

**Several statements in one run are refused** before anything runs, with a message: select a single statement or put the caret in one. A script therefore never runs halfway. As a second guard, the runner prepares the statement natively (MySQL's emulated prepares are turned off for the run; PostgreSQL prepares one statement), so the database itself rejects a second statement the splitter missed. SQLite's PDO runs only the first statement of a prepared text. To run a whole script, use [Run All Statements](#run-all-statements). Client commands such as MySQL's `DELIMITER` are not supported.

Statements are sent as written, without bindings. Strings follow standard SQL (`'it''s'`); MySQL's backslash escapes inside strings can confuse the statement splitter. PostgreSQL's `?` JSON operators need `??` with PDO, as in PHP code.

## Run All Statements

**Run ▸ Run All Statements** (⌥⇧⌘R), the **Run All** button in the SQL bar, or the command palette runs every statement of the selection, or of the whole tab without one ([#129](https://github.com/filipac/runlet/issues/129)):

- **In order, on one connection, in one PHP process.** Statements are split the same way as for Run (semicolons outside strings, quoted identifiers, comments, and dollar-quoted bodies). Each statement gets its own result card, titled **Statement 2 of 5** with its line, its text, and its rows or affected-row count.
- **Stop at the first error.** The failing statement's card says which statement and line failed and why, and which statements did not run.
- **In a Transaction** (the SQL bar's checkbox, on by default, saved with the tab). The script runs in one transaction: committed after the last statement (the output says so), rolled back when a statement fails ("Rolled back the transaction: statements 1–2 were undone."). Turned off, each statement commits on its own, and the statements before a failure stay.
  - A PDO connection uses `beginTransaction()`, `commit()`, and `rollBack()`. A callable connection (WordPress's `$wpdb`, Doctrine without PDO, a project driver's callable) gets `BEGIN`, `COMMIT`, and `ROLLBACK` statements through the callable.
  - **MySQL and MariaDB commit some statements at once**, with everything before them, even inside a transaction: `CREATE`, `ALTER`, `DROP`, `RENAME`, `TRUNCATE`, `GRANT`, `REVOKE`, `LOCK`, and table maintenance (`CREATE`/`DROP TEMPORARY TABLE` don't). When a script holds any, the output says so before the first statement runs. Runlet opens a new transaction after each of them, so a later failure rolls back only the statements after the last one, and the message says which statements stay. PostgreSQL and SQLite roll back DDL too.
  - A script that manages its own transaction (`BEGIN`, `START TRANSACTION`, `COMMIT`, `ROLLBACK`, `SAVEPOINT`, `RELEASE`, `END`) is refused while In a Transaction is on, before anything runs: turn it off to run the script as written. Statements that can't run inside a transaction (PostgreSQL's `VACUUM` or `CREATE INDEX CONCURRENTLY`) need it off too.
- **Production asks once**, listing every statement with its line and a red warning on each that can change data (see [Safety](#safety)).
- Run History keeps the script, from its first statement to its last, as one SQL entry.

Run (⌘R) still runs one statement and refuses a selection with several; Run All is always a separate, explicit action.

## Results

- A statement that returns rows shows a table: its columns in order (duplicate names kept, e.g. two `id` columns of a join), the rows, the row count, and the time the runner measured for executing and fetching. The table has the Table view's filter, sorting, row and cell copy, Copy CSV, and Export CSV. Copy Output and Copy Output as Markdown include it (tab-separated, or a Markdown table).
- Any other statement shows the number of rows it affected (`INSERT`, `UPDATE`, `DELETE`; DDL usually reports 0).
- A line under the result names the driver (`sqlite`, `mysql`, `pgsql`, …), the connection, and where the connection came from (for example `via Laravel DB::connection()`).

**Limits.** At most 1,000 rows per statement, at most 200 columns, 8 KiB per text cell, and 8 MiB of cells per result. A cut result says so (“Runlet shows at most 1,000 rows … add a LIMIT, or page with OFFSET”); the rows after the limit are not fetched, and MySQL results are read unbuffered for the run. PostgreSQL's driver still loads a whole result into PHP memory before Runlet reads its first rows, so use `LIMIT` on large tables. Bytes that aren't UTF-8 text show as binary (size and the first 32 bytes in hex), `NULL` as `NULL`.

Errors from the database (a syntax error, a missing table) show as the run's error. They never point at lines of Runlet's generated PHP.

## Completion

SQL tabs complete as you type (two letters of a word, or `.` after a table or alias) and on Show Completions (⌃Space or ⌥Esc) ([#128](https://github.com/filipac/runlet/issues/128)):

- **Keywords and functions, always**, with no connection: `SELECT`, `ORDER BY`, `LEFT JOIN`, `IS NOT NULL`, … and common functions (`COUNT()`, `COALESCE()`, `SUM()`, …; the caret goes between the parentheses). Keywords follow the case you type, or the statement's.
- **Tables** after `FROM` (and its commas), `JOIN`, `UPDATE`, `INTO`, `TABLE`, and `DESCRIBE`.
- **Columns** of the tables the statement names, first, wherever columns fit (`SELECT`, `WHERE`, `ON`, `INSERT INTO t (`, …), with the table and type in the list. `alias.` and `table.` list that table's columns (`FROM orders o` … `o.`); `schema.` lists a PostgreSQL schema's tables. Before `FROM`, every column is offered once.
- Names that need quotes are inserted quoted: backticks on MySQL, double quotes elsewhere (spaces, reserved words, and PostgreSQL names with capitals).
- Nothing is offered inside strings, comments, or quoted identifiers, in numbers, or after a `:name` placeholder or `@variable`.

**The schema.** Tables and columns come from the connection the tab uses, read through the same resolution as a statement (the project's driver first, then the built-in framework connections). The SQL bar's schema menu shows what completion knows ("3 tables", "No schema") and has **Load Schema** / **Reload Schema** and **Forget Schema** (also **Load SQL Schema** in the palette). Runlet reads it:

- when you choose **Load Schema**: in a fresh runner, apart from the tab's output; production targets ask first, every time;
- **with a statement you run**: the first successful Run or Run All on a connection in a session also reads its schema, after the statements, in the same process. On production targets this never happens; use Load Schema there.

Only names and types are read, never rows: `information_schema.COLUMNS` on MySQL and MariaDB (the current database), `information_schema.columns` on PostgreSQL (the schemas on the search path; others as `schema.table`), `INFORMATION_SCHEMA.COLUMNS` on SQL Server, and `sqlite_master` with `pragma_table_info` on SQLite. A callable connection tries those catalogs in turn. A project driver can return the schema itself with `sqlSchema()` ([drivers.md](drivers.md#sql-connections)), for an API or database Runlet can't query that way. At most 2,000 tables and 50,000 columns are kept. The schema stays in memory per target and connection until Forget Schema, an edit of the target, or quitting; it is never saved. A schema that can't be read never fails a run: the menu shows why, and later runs don't retry (Load Schema does).

## Snippets

SQL tabs save **SQL snippets** ([#130](https://github.com/filipac/runlet/issues/130)). **Save as Snippet…** (⌥⌘S) from an SQL tab saves the selection or the tab as an SQL snippet ("Save SQL Snippet"); saving to the project writes a `.sql` file in `.runlet/snippets/`. SQL snippets show an **SQL** badge in the Snippets panel and open as SQL tabs (or switch the current tab to SQL, per Settings ▸ General ▸ History & Snippets). Opening never runs them, and they have no `@input`s. History's Save as Snippet, Duplicate, and Copy to Personal keep the language. See [personal snippets](personal-snippets.md) and [project snippets](project-snippets.md#sql-snippets).

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
- **No MCP.** AI clients' `run_php` runs PHP only. It never reuses a tab that was switched to SQL, and the app refuses to run an SQL tab's text as PHP from any caller. MCP's snippet tools report a snippet's `language`, and `add_snippet` can save an SQL snippet; none of them run anything.
- **Production always asks.** On a production target, every SQL run shows the confirmation (⌘↩ confirms), even during a 10-minute grace for snippet runs. The sheet shows the statement and the connection. When the statement can write (or Runlet can't tell), a red warning names why, for example `UPDATE`, `DROP`, `SELECT … INTO`, `FOR UPDATE, which locks rows`, or `EXPLAIN ANALYZE … DELETE`. Run All Statements asks once and lists every statement in order, each with its line and its own warning, and says whether the script runs in a transaction. Load Schema asks too, and a run on production never reads the schema by itself.
- **Development and staging targets don't ask**, for reads or writes: an SQL tab is a scratch client, like the PHP tabs that can write to the same database. Run History keeps every statement that ran.

**Write detection is best-effort.** A statement counts as read-only only when it starts with `SELECT`, `SHOW`, `DESCRIBE`, `EXPLAIN` (without `ANALYZE`), `VALUES`, `TABLE`, `WITH`, or `PRAGMA` without `=`, and holds no `INSERT`, `UPDATE`, `DELETE`, `MERGE`, `INTO`, `CREATE`, `DROP`, `ALTER`, or `TRUNCATE` outside strings and comments. Everything else gets a warning. Functions with side effects called from a `SELECT` (`nextval()`, stored procedures, locks) are not detected. On production the confirmation is shown for every statement anyway.

## Validation

- `SQLTabTests` (RunletCore): tab language decoding and persistence (sessions, workspaces, history), statement splitting and scope, write detection, the generated PHP's escaping of quotes, backslashes, `$`, and control characters, result decoding and summaries, and that SQL ignores the production grace. Run All: the statements of a selection or the tab, transaction statements, implicit commits, and per-statement results.
- `SQLCompletionTests` (RunletCore): keywords without a schema, nothing inside strings, comments, or quoted names, tables after `FROM`/`JOIN`/`UPDATE`/`INTO`, columns of the statement's tables, aliases and `schema.` qualifiers, quoting per driver, only the statement at the caret, and schema decoding.
- `SQLScriptExecutionTests` (RunletExecution, host PHP): Run All in order with a result per statement; commit and rollback on PDO and callable connections; earlier statements kept without a transaction; on PHP 7.4; WordPress `$wpdb`.
- `SQLSchemaExecutionTests` (RunletExecution, host PHP): the schema through a project driver's PDO and callable, a driver's own `sqlSchema()`, Laravel, Eloquent through Capsule, Doctrine DBAL 3 and 4, and WordPress; a run that reads it along; a schema that can't be read never failing the run; the error for a callable without a catalog.
- `ProjectSnippetsTests`, `PersistenceTests`, and `MCPToolArgumentTests` (RunletCore): SQL snippets' metadata comments, listing, saving, and file names; personal snippets' language decoding (old libraries load as PHP); `add_snippet`'s `language`.
- `SQLTabExecutionTests` (RunletExecution, host PHP): a project driver's PDO and callable connections, names and errors (`custom-driver`); the driver's method winning over the built-in Laravel connection (`custom-laravel-driver`); Laravel connections, named connections, unknown names, and database errors (`laravel-app`, in a scratch copy); Eloquent through Capsule found without a driver method (`eloquent-app`); Doctrine DBAL 3 and 4 through `SqlConnections::doctrine()`; WordPress `$wpdb` on SQLite; the row cap, binary and long cells; the refusal on plain, Composer, and Symfony-without-Doctrine projects; and a run on Herd's PHP 7.4.
- The Debug app, with scratch data: a sandbox SQL tab running `INSERT`, `SELECT`, and `UPDATE`; the production confirmation on a never-connected production SSH profile; the unknown-connection and no-connection messages; a `.sql` file opened without running; the several-statements refusal. Screenshots are in [PR #120](https://github.com/filipac/runlet/pull/120).
- The Debug app, with a scratch SQLite project: Run All committing three statements, a failing script rolled back, completion of an alias's columns from the schema a run read, the production confirmations for Run All and Load Schema, SQL snippets in the Snippets panel, and Save SQL Snippet. Screenshots are in [PR #131](https://github.com/filipac/runlet/pull/131).

Live MySQL, MariaDB, PostgreSQL, and SQL Server servers were not exercised by these tests: their statements, transactions (including MySQL's implicit commits), and catalog queries follow PDO's documented API and the databases' documented `information_schema`. SQLite covers every code path that doesn't depend on the dialect.
