# SQL tabs

Implemented under [#35](https://github.com/filipac/runlet/issues/35), with completion ([#128](https://github.com/filipac/runlet/issues/128)), Run All Statements ([#129](https://github.com/filipac/runlet/issues/129)), SQL snippets ([#130](https://github.com/filipac/runlet/issues/130)), the schema explorer and result window ([#21](https://github.com/filipac/runlet/issues/21)), and saved connections ([#138](https://github.com/filipac/runlet/issues/138), part of the database roadmap [#137](https://github.com/filipac/runlet/issues/137)).

An SQL tab is a scratch SQL client for the tab's target. By default each statement runs through the application's own database connection, the one its code uses, so it needs no credentials from Runlet. You can also [save a connection](#saved-connections) yourself for a database the application doesn't configure. That is opt-in: its password is stored only in the macOS Keychain, read when a statement runs, and sent only to the PHP process that opens the connection, on that process's standard input. It is never written to Runlet's files, logs, Run History, sessions, workspaces, or AI clients' results. Runlet never reads credentials from your application's configuration to create saved connections.

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

- **While a statement runs**, the output says where and for how long ("Running on the default connection… 1.2 s", or "Running 3 statements on …" for Run All) with a **Stop** button, and the SQL bar shows a spinner ([#162](https://github.com/filipac/runlet/issues/162)). Runlet stays usable meanwhile: the statement runs in the runner process, and the app only waits for its events.
- A statement that returns rows shows a table: its columns in order (duplicate names kept, e.g. two `id` columns of a join), the rows, the row count, and the time the runner measured for executing and fetching. The table is a native grid that draws only the rows on screen, so a thousand rows show at once and scroll smoothly ([#162](https://github.com/filipac/runlet/issues/162)). It grows with its rows up to 400 points, then scrolls inside; a vertical scroll that starts where the grid can't move (its rows fit, or it is at its top or bottom) scrolls the output instead.
  - **Filter rows** keeps the rows with a cell that contains the text ("12 of 1,000"); click a header to sort, numbers as numbers, NULLs last. Drag a header's edge to resize a column.
  - Select rows and press ⌘C to copy them tab-separated. The context menu has Copy Value, Copy Row (or rows), Copy Row as CSV, and for one row Copy Row as JSON and Copy Row as PHP Array.
  - **Copy CSV** and **Export CSV…** write the rows shown. **Open in Window** ([result window](#result-window)) opens the table with the same filter and sort.
  - Copy Output and Copy Output as Markdown include the rows (tab-separated, or a Markdown table); the card's copy button copies them tab-separated.
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

## Schema explorer

**Library ▸ Database** (⇧⌘B, Show Database in the palette) shows the database of the current tab's target ([#21](https://github.com/filipac/runlet/issues/21)): an SQL tab's connection, or the default connection for a PHP tab.

- **Tables and views**, each with its column count and, on MySQL, MariaDB, and PostgreSQL, the database's estimate of its rows. Views carry a VIEW badge.
- **Columns** when a table is expanded: the type, the primary key (a key icon), the foreign key's target (`→ customers.id`), NOT NULL, and the default. Then the table's **indexes**, with their columns, UNIQUE, or PRIMARY.
- **Filter** by table or column name: tables whose name matches come first; tables matched by a column show just those columns.
- **Actions**, none of which runs anything:
  - **Open in SQL Tab** (double-click a table, or its ↗ button): `SELECT * FROM <table> LIMIT 50` in a new SQL tab named after the table, on the same target and connection (`SELECT TOP 50` on SQL Server).
  - **Open as PHP (Query Builder)**, on Laravel, Lumen, and Laravel Zero: `DB::table('<table>')->limit(50)->get();` (with `DB::connection(…)` for a named connection) in a new PHP tab.
  - **Insert Name** (double-click a column) at the cursor, quoted like completion quotes it, and **Copy Name** or **Copy table.column**.

It shows the same schema completion uses (see [The schema](#completion)), so nothing loads by itself. Before the schema is read, the pane explains what Load Schema does and has the button. On production the button asks first, every time. Running a statement on a non-production connection also fills it. Reload and Forget are in the pane's header.

**What is read.** With the tables and columns, the catalog query reads each column's nullability, default, and primary key, and then indexes and foreign keys in two more catalog queries. It reads `information_schema` (`COLUMNS`, `TABLES`, `STATISTICS`, `KEY_COLUMN_USAGE`) on MySQL and MariaDB, `information_schema` with `pg_constraint`, `pg_index`, and `pg_class` (row estimates from `reltuples`) on PostgreSQL, and `pragma_table_info`, `pragma_index_list`, and `pragma_foreign_key_list` on SQLite. On SQL Server only the columns' details are read, with no indexes or foreign keys. When indexes or foreign keys can't be read (a database without those catalogs, or permissions), the tables and columns still show, with a note. Bounds: 2,000 tables, 50,000 columns, and 20,000 index columns. A project driver's `sqlSchema()` can return these details too ([drivers.md](drivers.md#schema-for-completion)).

## Result window

**Open in Window** above any result table opens it in its own resizable window ([#21](https://github.com/filipac/runlet/issues/21)). That covers an SQL tab's rows and a PHP collection shown in the Table view. The window is titled with the tab, and the statement for Run All, plus the row count. It shows the result the run already produced: opening it runs nothing.

- **Search all columns**, and **Add Filter** rules per column: contains, doesn't contain, =, ≠, <, ≤, >, ≥, is empty or NULL, and isn't empty. All rules must match.
  - Text comparisons ignore case.
  - =, ≠, <, and > compare as numbers when both sides are numbers, else as text, so ISO dates order correctly.
  - NULL never equals, contains, or compares, but it matches ≠, doesn't contain, and is empty.
- **Columns**: click a header to sort, numbers as numbers, with NULLs last either way. Drag a header's edge to resize a column, or the header to reorder. The Columns menu hides and shows columns.
- **Rows**: select rows and press ⌘C to copy them tab-separated. The context menu has Copy Value, Filter: column = value / ≠ value (or is empty) for the clicked cell, Copy Row (or rows), Copy Row as CSV, and for one row Copy Row as JSON and Copy Row as PHP Array. The grid is the output's ([#162](https://github.com/filipac/runlet/issues/162)).
- The footer counts what is shown ("11 of 50 rows · 5 columns"). **Copy CSV** and **Export CSV…** write the rows and columns shown.

Result windows aren't saved or restored; closing one drops its copy of the rows.

## Snippets

SQL tabs save **SQL snippets** ([#130](https://github.com/filipac/runlet/issues/130)). **Save as Snippet…** (⌥⌘S) from an SQL tab saves the selection or the tab as an SQL snippet ("Save SQL Snippet"); saving to the project writes a `.sql` file in `.runlet/snippets/`. SQL snippets show an **SQL** badge in the Snippets panel and open as SQL tabs (or switch the current tab to SQL, per Settings ▸ General ▸ History & Snippets). Opening never runs them, and they have no `@input`s. History's Save as Snippet, Duplicate, and Copy to Personal keep the language. See [personal snippets](personal-snippets.md) and [project snippets](project-snippets.md#sql-snippets).

## Connections

The bar above the editor picks the connection. Its list has two parts:

- **Application connections**: **Default connection**, or a name from the application's configuration. After a run, the list shows the connection names the project's driver reports (Laravel's `database.connections`, Doctrine's connection names), with the default first. **Other Connection…** takes any name. Only the name is stored with the tab. An unknown name fails with the driver's message and the list of known connections.
- **Saved connections**: the ones you [saved](#saved-connections) for this target, then **New Connection…** and **Edit Connections…**.

Choosing a connection never connects or runs anything.

Runlet finds the connection in this order, in the same fresh PHP process that boots the application for a run:

1. **The project's driver**: `sqlConnection()` of a [project driver](drivers.md#sql-connections) in `.runlet/`, or of the built-in driver it extends.
2. **The built-in framework connections**, through the same APIs as [Explain](sql-explain.md):
   - Laravel, Lumen, Laravel Zero: `DB::connection($name)`'s PDO.
   - Symfony: the `doctrine` registry's connection (`getConnection($name)`), its PDO when it has one, else statements through DBAL.
   - WordPress: `$wpdb->query()` (one connection; a name is refused).
   - Any project whose code set up Eloquent (illuminate/database through Capsule) or `$wpdb`, even with a project driver that has no `sqlConnection()`.
3. Otherwise the run stops with **No SQL connection**: the project's driver provides none and the application set up no Eloquent connection or `$wpdb`. Runlet never guesses credentials. Plain PHP and Composer projects, and Symfony without DoctrineBundle, get this message. To use SQL tabs there, [save a connection](#saved-connections) for the target, or add `sqlConnection()` to a project driver.

Any PDO driver works. MySQL/MariaDB, PostgreSQL, and SQLite are the expected ones; the automated tests use SQLite (see [Validation](#validation)). A Laravel connection without a PDO (for example MongoDB) is refused with a message.

## Saved connections

Local projects, Docker profiles, and SSH profiles can each keep **saved database connections** ([#138](https://github.com/filipac/runlet/issues/138)), for a database the application doesn't configure (a read replica, a reporting or legacy database, another service's database), a project with no driver, or the application's database with another user. The Laravel sandbox has none yet ([#142](https://github.com/filipac/runlet/issues/142)).

**Where.** A target's **Databases** list: in a local project's options, in the Docker and SSH profile forms (the sheets and the Profiles window), and in **Edit Connections…** in the SQL bar's list. **New Connection…** there opens the editor and switches the SQL tab to the new connection when you save it. A profile that isn't saved yet gets its connections once it is.

**Fields.**

| Field | Notes |
| --- | --- |
| Name | Unique within the target. Shown in the list, results, the output's first line, and production confirmations. |
| Driver | MySQL / MariaDB (`mysql`), PostgreSQL (`pgsql`), an SQLite file (`sqlite`), SQL Server (`sqlsrv`), or a custom PDO DSN (`custom`) ([#140](https://github.com/filipac/runlet/issues/140); see [Connection options](#connection-options)). |
| Host, Port | The port defaults to 3306, 5432, or 1433. A Unix socket can replace them (MySQL and PostgreSQL). The host is resolved where the connection is made (below), so a Compose service name works for a Docker profile, and a server-local database for an SSH profile. Only letters, digits, `.`, `-`, `_`, and `:` (IPv6) are accepted. |
| Database | Optional for MySQL and PostgreSQL. No `;`, quotes, or control characters, so nothing can add options to the connection string. For SQLite, the file on the target: absolute, or relative to the project directory; Runlet opens existing files only. |
| User | Stored with the definition. |
| Password | Optional. Stored only in the macOS Keychain. A secure field; after saving, the editor shows only that a password is saved, with **Replace…** and **Remove**. |
| Connect timeout | Seconds, default 10 (`PDO::ATTR_TIMEOUT`). |
| Read-only | Off by default. The database refuses writes in the connection's session, and Runlet refuses statements that could write before sending them. See [Read-only connections](#read-only-connections). |
| Environment, Colour | Development (default), staging, or production, and a colour, like a target's. Runs use the stricter of the connection's and the target's marking. See [Environment and colour](#environment-and-colour). |
| Advanced | Unix socket, charset, TLS, init statements, and DSN options. See [Connection options](#connection-options). |

**Where the connection is made.** In the target's own PHP, the same place statements run today: the project's PHP on this Mac, the container's PHP for a Docker profile (`docker exec`), the server's PHP for an SSH profile (or its container's). That PHP needs the PDO driver: the official `php:*-cli` images, for example, have `pdo_sqlite` but not `pdo_mysql` or `pdo_pgsql`. Opening it from this Mac instead is [#142](https://github.com/filipac/runlet/issues/142).

**Test Connection** in the editor opens the connection on the target, with the password typed in the sheet (before saving) or the saved one, runs the connection's [init statements](#connection-options), and reports the server's version, the current database and user, the round trip, and whether the session is encrypted (with the TLS version and cipher), or the error. If the target's PHP lacks the PDO driver, it says so and lists the drivers it has ("This target's PHP 8.4.1 has no pdo_pgsql driver. It has: sqlite."). It runs no application code and none of your SQL beyond the init statements, so it doesn't ask on production.

**No project code runs.** A statement, Run All, Load Schema, or Test Connection on a saved connection boots the runner with the `plain` bootstrap: no driver, no Composer autoloader, no application code shares the process that holds the password. Such a run doesn't change what Runlet learned about the target (framework, App Info, driver hints, connection names). SQL tabs, Run All, Load Schema, completion, and the [schema explorer](#schema-explorer) work on saved connections; **Open as PHP (Query Builder)** is hidden for them, because Runlet never generates PHP that contains a password.

**Results** say where they came from: `via saved connection "Reporting" (pgsql, db.internal:5432/reports)`, with `, read-only session` for a [read-only](#read-only-connections) one, never with a user or password. Run History keeps the statement, as for any SQL run.

**The password.**

- **At rest.** A generic password in the login keychain: service `dev.runlet.Runlet.database`, account the connection's id, label `Runlet database: <name>`, comment `Runlet saved database connection`, not synchronizable (never in iCloud Keychain). `targets.json` keeps the definition only; sessions keep the tab's connection id and name; workspaces keep the name only.
- **In use.** Runlet reads it when a run starts (after any production confirmation), puts it in the runner's request, and sends that to PHP on its standard input: a local pipe, `docker exec -i`, or the `ssh -T` channel. Never as an argument or environment variable, so it isn't in `ps`, `docker inspect`, the server's shell history, or `/proc/<pid>/environ`. The Run Log shows only the script's size. Code read from standard input isn't stored by [Keep compiled PHP](ssh.md)'s opcode file cache (a test checks the cache after a saved-connection run).
- **In PHP.** The runner opens the connection in a function that takes no arguments, with `zend.exception_ignore_args` on, and replaces PDO's error with one that carries only its message. It forgets the password once the connection is open, and replaces it (and its URL-encoded forms) with `•••` in everything it reports: errors, notices, and log lines always; results too for passwords of 4 or more characters, so a very short password doesn't garble every result.
- **Lifecycle.** Deleting a connection deletes its Keychain item; removing a target asks first ("Its 2 saved database connections are deleted too, with their passwords in the Keychain.") and deletes them. Duplicating a connection, or a Docker or SSH profile, copies the definitions without passwords. Cancelling the editor after typing a password writes nothing. A Keychain that refuses a write keeps the definition and says the password wasn't saved.
- **Prompts.** Runlet is ad-hoc signed, so the login keychain trusts the build that saved the item. **After an update, macOS may ask once whether Runlet may use the password**, with a dialog like "Runlet wants to use your confidential information stored in “Runlet database: Reporting” in your keychain", which asks for your login keychain password: choose **Always Allow** so it doesn't ask again until the next update. **Deny** stops that run with "The password of the saved connection “Reporting” couldn't be read, so nothing ran." Developer ID signing ([#24](https://github.com/filipac/runlet/issues/24)) ends these prompts.
- **Development.** With a scratch `RUNLET_DATA_DIR`, Runlet uses its own Keychain service (`dev.runlet.Runlet.database.<8 hex of a hash of the folder>`), and Debug builds keep passwords in memory (`RUNLET_CREDENTIALS=memory`; `RUNLET_CREDENTIALS=keychain` uses that separate service instead), so development runs, screenshots, and tests never read or write the real items.
- **Not covered.** Root on the target can read the PHP process's memory, and a saved connection used from a compromised server exposes its password to that server, as the application's own `.env` already does.

**Workspaces** keep a tab's saved connection by name only (`"sqlSavedConnection": "Reporting"`). Opening one on a Mac whose target has no connection of that name shows "The saved connection “Reporting” isn't defined for this target." in the SQL bar, with **New Connection…**; a statement isn't run until you choose a connection. The same happens for a tab whose connection was deleted, or a tab moved to a target without a connection of that name.

**AI clients** never see saved connections: `run_php` can't use them, and `list_targets` doesn't list them.

### Read-only connections

Turn on **Read-only** in a saved connection's editor to look at data, production data included, without changing it ([#139](https://github.com/filipac/runlet/issues/139)). The SQL bar, its list, and the Databases lists show a **READ-ONLY** badge with a lock; the output's first line says "in a read-only session", and so does each result's source line and a successful Test Connection.

**The database enforces it.** Right after connecting, before any statement of yours, the runner makes the session read-only and asks the database whether it took. If it didn't, the run stops: "Runlet could not make the session of the read-only connection … read-only, so nothing ran". Before each later statement of a Run All, the runner sends the setting again, so a statement that got past the checks below can't leave the session writable for the next one.

| Driver | How | What the database then refuses |
| --- | --- | --- |
| MySQL / MariaDB | `SET SESSION TRANSACTION READ ONLY` (MySQL 5.6.5+, MariaDB 10.0+), checked with `@@session.transaction_read_only` (or `tx_read_only` on older servers) | `INSERT`, `UPDATE`, `DELETE`, DDL, and `SELECT … FOR UPDATE` ("Cannot execute statement in a READ ONLY transaction"). MySQL documents that changing temporary tables with DML stays possible in a read-only session; MariaDB 11 refuses even creating one (tested). Runlet refuses `CREATE TEMPORARY TABLE` and those writes before sending them anyway. |
| PostgreSQL | `SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY`, checked with `SHOW default_transaction_read_only` | Writes to tables other than temporary ones, every `CREATE`, `ALTER`, and `DROP` (temporary tables included), `SELECT … FOR UPDATE`/`FOR SHARE`, `nextval()`, and writes from functions ("cannot execute INSERT in a read-only transaction"). |
| SQLite | The file is opened read-only (`PDO::SQLITE_ATTR_OPEN_FLAGS` with `SQLITE_OPEN_READONLY`, PHP 7.3+; `Pdo\Sqlite` on 8.4+), and `PRAGMA query_only = ON` | Every write to the file ("attempt to write a readonly database"), even after `PRAGMA query_only = 0`. |

**Runlet refuses before sending.** A session can switch itself back to read-write, and some writes get past some databases, so on a read-only connection Runlet refuses, before anything runs, statements that:

- would make the session writable again: `SET [SESSION|GLOBAL] TRANSACTION … READ WRITE`, `SET [SESSION] transaction_read_only`/`tx_read_only` (also as `@@session.…` and in `SET STATEMENT … FOR`), `SET default_transaction_read_only`, `SET SESSION CHARACTERISTICS`, `BEGIN … READ WRITE`, `START TRANSACTION … READ WRITE`, `RESET ALL` and `RESET` of those settings, `DISCARD ALL`, `PRAGMA query_only` in any form, `ALTER ROLE … SET default_transaction_read_only`, and any call of `set_config()` (which changes settings from inside a `SELECT`);
- can write, by the same rules as [write detection](#safety): `INSERT`, `UPDATE`, `DELETE`, DDL, `SET`, `CALL`, `DO`, a writable `WITH`, `SELECT … INTO` (including `INTO OUTFILE`), `FOR UPDATE`, `EXPLAIN ANALYZE` of a write, `PRAGMA name = …` or `PRAGMA name(…)` (except the pragmas that read about a table, such as `table_info(…)`);
- Runlet can't classify (`USE`, `LISTEN`, `CHECKPOINT`, …), or hold a second statement after a `;`.

Reads run, and so does transaction control that doesn't ask for `READ WRITE` (`BEGIN`, `START TRANSACTION`, `COMMIT`, `ROLLBACK`, `SAVEPOINT`, `RELEASE`), which can't change data in a read-only session. Case and comments don't matter, and keywords inside strings and quoted names don't count. Runlet reads the statement as the connection's database would: with MySQL's backslash escapes and executable comments (`/*! … */`, MariaDB's `/*M! … */`) on MySQL, and with `#` as an operator rather than a comment and `E'…'` strings on PostgreSQL. The message says why and what to do: "This statement can change data or the schema (UPDATE), so Runlet doesn't send it on the read-only connection “Reporting replica”. Nothing ran." with a suggestion to use a connection without Read-only. **Run All Statements** checks every statement first and runs none of the script if one is refused, naming the first ("Statement 2 of 4 (line 3) …") and how many more would be. The runner checks again with the same rules before it even connects, in case a request reaches it without the app's check.

**Limits.** Read-only is a strong safety net, not a permission system. For a guarantee, connect as a database user that only has read privileges (`GRANT SELECT …`, or PostgreSQL's `pg_read_all_data` role).

- **Functions with side effects** called from a `SELECT` aren't detected by Runlet. PostgreSQL's read-only transactions refuse their writes; MySQL's only refuse table writes, so `GET_LOCK()`, a stored function that writes elsewhere, or a `SELECT … LOCK IN SHARE MODE` lock can still run.
- **Locks.** `SELECT … FOR UPDATE` is refused everywhere; `FOR SHARE` and `LOCK IN SHARE MODE` aren't refused by Runlet (PostgreSQL refuses them in a read-only transaction; MySQL takes the shared locks).
- **Connection poolers.** A session setting lasts for the server connection it was sent on. Behind a pooler in transaction mode (PgBouncer, ProxySQL), a later statement may run on another server connection, without the setting, and the setting may stay on a connection the pooler later gives to someone else. Use a direct connection or a session-mode pool, or a read-only user.
- **Application connections** (the ones the application configures) aren't made read-only; this setting is for saved connections.

### Connection options

The editor's **Advanced** section ([#140](https://github.com/filipac/runlet/issues/140)) holds what managed databases, local servers, and some schemas need. It opens by itself when a connection uses any of it, and its header sums up what is set ("TLS verify-full · 2 init statements · 1 option"). Everything is optional; `targets.json` gets a key only for what is set, and connections saved before load unchanged.

| Option | MySQL / MariaDB | PostgreSQL | SQL Server |
| --- | --- | --- | --- |
| Unix socket (replaces the host) | `unix_socket=<file>`; the port isn't used | `host=<directory>`; the port names the socket file (`.s.PGSQL.<port>`) | — |
| Charset | `charset=` in the DSN (default `utf8mb4`) | `client_encoding` (default: the server's) | — (pdo_sqlsrv uses UTF-8) |
| TLS modes | Off, Require, Verify CA and host name | Off, Prefer, Require, Verify CA, Verify CA and host name (libpq's `sslmode`) | Off, Require, Verify CA and host name |
| CA, client certificate, client key | `PDO::MYSQL_ATTR_SSL_CA`, `_CERT`, `_KEY` (`Pdo\Mysql::ATTR_*` on PHP 8.4+) | `sslrootcert`, `sslcert`, `sslkey` | — (the ODBC driver uses the system's CAs) |
| Connect timeout | `PDO::ATTR_TIMEOUT` | `PDO::ATTR_TIMEOUT` (libpq's `connect_timeout`) | `LoginTimeout=` in the DSN |
| DSN options | — (MySQL's PDO DSN has no other keys) | libpq keywords (`application_name`, `target_session_attrs`, `hostaddr`, `options`, …) | DSN keywords (`APP`, `ApplicationIntent`, `MultiSubnetFailover`, …) |
| Init statements | yes | yes | yes |

**TLS.** "Driver default" sends no TLS setting: MySQL's PDO then doesn't encrypt, libpq prefers TLS, and Microsoft's ODBC driver 18 encrypts and verifies. The other modes, per driver:

- **MySQL / MariaDB** (mysqlnd): encryption starts only when an SSL attribute is set, and once it does, mysqlnd checks the certificate and the host name together unless `MYSQL_ATTR_SSL_VERIFY_SERVER_CERT` is false. So MySQL has *Require* (an empty CA, verification off: encrypted, not verified) and *Verify CA and host name* (the CA file, else PHP's default CAs from `openssl.cafile` or OpenSSL's), but no *Prefer* and no *Verify CA* alone; the editor says so and won't save them. With either mode the runner checks `Ssl_cipher` after connecting and stops before anything runs if the session isn't encrypted.
- **PostgreSQL** (libpq): all five `sslmode`s. With a CA file, libpq checks the CA under *Require* too, as under *Verify CA*.
- **SQL Server** (pdo_sqlsrv): *Off* is `Encrypt=no`, *Require* `Encrypt=yes;TrustServerCertificate=yes`, *Verify CA and host name* `Encrypt=yes;TrustServerCertificate=no`. pdo_dblib (FreeTDS) reads TLS from `freetds.conf` (`encryption`), so a connection that sets a TLS mode stops on a target that only has pdo_dblib, and says why.

Certificate and key files are **paths where the connection is opened**: on this Mac for a local project, in the container for a Docker profile, on the server for an SSH profile. They aren't secrets, and Runlet never reads them; the runner checks only that they exist and can be read, so a missing file says so instead of a TLS error. **Encrypted client keys aren't supported**: libpq's `sslpassword` would put the key's passphrase outside the Keychain, and MySQL's PDO has no setting for it. Decrypt the key (`openssl pkey -in key.pem -out client.key`) and keep the file private.

**Init statements** run after connecting, before the statement, every Run All, Load Schema, and Test Connection: `SET search_path TO reporting, public`, `SET time_zone = '+00:00'`, `SET NAMES utf8mb4`. One statement each (a trailing `;` is dropped); at most 20. They count as part of the connection:

- **No transaction control** on any connection: `BEGIN`, `START TRANSACTION`, `COMMIT`, `ROLLBACK`, `SAVEPOINT` are refused, so an init statement can't leave a transaction open or end one.
- **On a read-only connection** they run *after* the session is made read-only, so the database refuses any write in them (a function called from a `SELECT` or a `SET @x = f()` included: tested on both servers), and the runner then sends the read-only setting again and checks it before your statement. Runlet also refuses, in the editor and again in the runner before connecting, what it refuses for [read-only](#read-only-connections) statements, except session settings that keep the session read-only: `SET search_path`, `SET TIME ZONE`, `SET ROLE`, `SET NAMES`, `SET SESSION sql_mode`, and so on are allowed; `SET default_transaction_read_only`, `SET SESSION TRANSACTION READ WRITE`, `SET SESSION CHARACTERISTICS`, `RESET ALL`, `PRAGMA query_only`, `set_config()`, and server-wide or account changes (`SET GLOBAL`, `SET PERSIST`, `SET PASSWORD`, `SET DEFAULT ROLE`) are not.
- **On production** the confirmation sheet lists them above the statement ("The connection's 2 init statements run first").
- A failing init statement stops the run before anything of yours runs: "Init statement 1 of the saved connection "Reporting" (…) failed, so nothing of yours ran: …".

**DSN options** are appended to the DSN as `key='value'` (PostgreSQL) or `Key=value` (SQL Server). Refused, in the editor and in the runner: keys that look like a password (`password`, `PWD`, `sslpassword`, `passfile`, anything with `pass` or `pwd`), with "Runlet keeps passwords only in the Keychain: put it in the Password field"; keys the connection's own fields set (`host`, `port`, `dbname`, `user`, `sslmode`, `sslrootcert`, `sslcert`, `sslkey`, `client_encoding`, `connect_timeout`; `Server`, `Database`, `UID`, `Encrypt`, `TrustServerCertificate`, `LoginTimeout`); values with `;` (and braces for SQL Server) or control characters. An option pdo_sqlsrv doesn't know reaches you in its own words ("An invalid keyword 'Bogus' was specified in the DSN string.").

**SQL Server** connects with Microsoft's `pdo_sqlsrv` (`sqlsrv:Server=host,port;Database=…`), which also needs Microsoft's ODBC driver, or else with `pdo_dblib` (FreeTDS, `dblib:host=host:port;dbname=…;charset=UTF-8`). Runlet's own PHP has neither, so it works where the target's PHP does; Test Connection reports a missing extension ("has neither pdo_sqlsrv nor pdo_dblib, which SQL Server needs. It has: …") or pdo_sqlsrv's own message about its ODBC driver. The schema explorer reads columns through `INFORMATION_SCHEMA`. Read-only isn't available: SQL Server has no read-only session Runlet could enforce, so connect as a user with only `db_datareader`. **Not yet verified against a live SQL Server**: the generated DSNs are checked against pdo_sqlsrv's own keyword parser, and a fixture is [#53](https://github.com/filipac/runlet/issues/53).

**Custom PDO DSN** is for drivers Runlet doesn't model (`oci:`, `odbc:`, `firebird:`, …), or a DSN option it doesn't offer: type the DSN; the user and password fields work as for the other drivers (the password from the Keychain, as `new PDO()`'s own argument). Runlet doesn't parse the DSN, so the schema explorer reads only what the driver's catalogs answer, and there's no Read-only. Refused: a DSN that holds a password (`password=`, `pwd=`, `passwd=`, `sslpassword=`, or `user:secret@` in a URL), with "Runlet keeps passwords only in the Keychain"; a `uri:` DSN (PDO would read the DSN from a file or URL); line breaks. Test Connection names the PDO driver the target's PHP lacks ("has no pdo_oci driver for the DSN. It has: mysql, pgsql, sqlite.").

**Storage.** `targets.json` keeps `socket`, `charset`, `tls` (`mode`, `ca`, `cert`, `key`), `initStatements`, `options`, and `dsn`, each only when set. A TLS setting this Runlet can't read (from a newer one) leaves that connection out rather than connecting with less TLS than it asks for. Nothing here holds a password, so the runner's scrubbing is unchanged.

### Environment and colour

A saved connection can be marked **development**, **staging**, or **production**, with a **colour**, like a target ([#139](https://github.com/filipac/runlet/issues/139)). A development project can hold a connection to the production replica: mark that connection as production.

- **The stricter marking applies.** A run on a saved connection uses the stricter of the target's environment and the connection's (development < staging < production). A production connection on a development or staging target asks before every statement, Run All, and Load Schema, exactly as a production target does; the sheet says "The saved connection “Reporting replica” is marked as production" and shows the connection with its badge (and READ-ONLY when it is read-only). A development connection on a production target still asks, because the target is production. The production grace never applies to SQL.
- **Badges.** The SQL bar shows the connection's colour, its STAGING or PROD badge, and READ-ONLY; so do the SQL bar's list and the Databases lists. The editor's header shows the marking runs will use.
- **Run History** marks the run with the stricter environment and the connection's colour (else the target's), so a statement on a production connection is listed as production.
- **Nothing reads by itself.** On a production connection, a statement run doesn't also read the schema; only Load Schema does, after its confirmation.
- **Test Connection doesn't ask**, on a production target or a production connection alike: it runs none of your SQL and no application code, only Runlet's own fixed queries (as #138 decided), and on a read-only connection it runs in the read-only session.
- **Stored** in `targets.json` with the definition (`readOnly`, `environment`, `color`), left out at their defaults; connections saved before this phase load as read-write development connections without a colour.

## Safety

- **Nothing runs by itself.** Opening, importing, or restoring an SQL tab (sessions, workspaces, `.sql` files, history, Reopen Closed Tab) never runs it, and switching a tab's language runs nothing.
- **No auto-run.** Sandbox auto-run ([#30](https://github.com/filipac/runlet/issues/30)) is PHP-only: the toggle is hidden on SQL tabs, and switching a tab to SQL turns it off.
- **No MCP.** AI clients' `run_php` runs PHP only. It never reuses a tab that was switched to SQL, and the app refuses to run an SQL tab's text as PHP from any caller. MCP's snippet tools report a snippet's `language`, and `add_snippet` can save an SQL snippet; none of them run anything.
- **Production always asks.** On a production target, every SQL run shows the confirmation (⌘↩ confirms), even during a 10-minute grace for snippet runs. The sheet shows the statement and the connection; for a saved connection it names it and where it connects, and says it is opened from the target rather than through the application. A saved connection uses the stricter of its own marking and its target's ([Environment and colour](#environment-and-colour)): on a production target, or when the connection itself is marked production, its statements, Run All, and Load Schema ask. When the statement can write (or Runlet can't tell), a red warning names why, for example `UPDATE`, `DROP`, `SELECT … INTO`, `FOR UPDATE, which locks rows`, or `EXPLAIN ANALYZE … DELETE`. Run All Statements asks once and lists every statement in order, each with its line and its own warning, and says whether the script runs in a transaction. Load Schema asks too, and a run on production never reads the schema by itself.
- **The schema explorer and result window run nothing.** Their actions open a tab with a query, insert a name, or show rows a run already returned. Load Schema in the explorer asks on production like the SQL bar's.
- **Saved connections boot no project code** and keep their passwords out of everything Runlet writes or reports (see [Saved connections](#saved-connections)).
- **Read-only saved connections** run in a session the database keeps read-only, and Runlet refuses writing and session-changing statements before sending them (see [Read-only connections](#read-only-connections)).
- **Init statements** count as part of a saved connection: production confirmations list them, and on read-only connections they run in the read-only session under the same refusals (see [Connection options](#connection-options)).
- **Development and staging targets don't ask**, for reads or writes: an SQL tab is a scratch client, like the PHP tabs that can write to the same database. Run History keeps every statement that ran.

**Write detection is best-effort.** A statement counts as read-only only when it starts with `SELECT`, `SHOW`, `DESCRIBE`, `EXPLAIN` (without `ANALYZE`), `VALUES`, `TABLE`, `WITH`, or `PRAGMA` without `=` (and without an argument in parentheses, except the pragmas that read about a table or index, such as `table_info(…)`), and holds no `INSERT`, `UPDATE`, `DELETE`, `MERGE`, `INTO`, `CREATE`, `DROP`, `ALTER`, or `TRUNCATE` outside strings and comments. Everything else gets a warning. Functions with side effects called from a `SELECT` (`nextval()`, stored procedures, locks) are not detected. On production the confirmation is shown for every statement anyway.

## Validation

- `SQLTabTests` (RunletCore): tab language decoding and persistence (sessions, workspaces, history), statement splitting and scope, write detection, the generated PHP's escaping of quotes, backslashes, `$`, and control characters, result decoding and summaries, and that SQL ignores the production grace. Run All: the statements of a selection or the tab, transaction statements, implicit commits, and per-statement results.
- `SQLCompletionTests` (RunletCore): keywords without a schema, nothing inside strings, comments, or quoted names, tables after `FROM`/`JOIN`/`UPDATE`/`INTO`, columns of the statement's tables, aliases and `schema.` qualifiers, quoting per driver, only the statement at the caret, and schema decoding.
- `SQLScriptExecutionTests` (RunletExecution, host PHP): Run All in order with a result per statement; commit and rollback on PDO and callable connections; earlier statements kept without a transaction; on PHP 7.4; WordPress `$wpdb`.
- `SQLSchemaExecutionTests` (RunletExecution, host PHP): the schema through a project driver's PDO and callable, a driver's own `sqlSchema()`, Laravel, Eloquent through Capsule, Doctrine DBAL 3 and 4, and WordPress; a run that reads it along; a schema that can't be read never failing the run; the error for a callable without a catalog.
- `SQLSchemaExplorerTests` (RunletCore): the explorer's filter, the queries its actions prepare (per driver, Laravel's query builder with escaping), column and index descriptions, and the result window's search, filter rules (numbers, text, ISO dates, NULL), number-aware sorting with NULLs last, and CSV/TSV of the shown rows.
- `SQLSchemaDetailsTests` (RunletExecution, host PHP): on SQLite through a PDO and a callable, views, primary keys (including a composite one), a foreign key, defaults, NOT NULL, and unique and multi-column indexes; a driver's detailed `sqlSchema()`; and PHP 7.4.
- `SQLLiveDatabaseTests` (RunletExecution, live servers): MariaDB 11 and PostgreSQL 14 in throwaway fixture containers (`scripts/setup-fixtures.sh databases`, which prints `RUNLET_TEST_MYSQL` and `RUNLET_TEST_PGSQL`). It checks the schema details (keys, foreign keys, indexes, views, defaults, and row estimates), a statement with its schema, MariaDB's implicit commit in Run All (the notice, and only the statements after it rolled back), and PostgreSQL rolling back DDL with the rest. These tests skip without the variables.
- `ProjectSnippetsTests`, `PersistenceTests`, and `MCPToolArgumentTests` (RunletCore): SQL snippets' metadata comments, listing, saving, and file names; personal snippets' language decoding (old libraries load as PHP); `add_snippet`'s `language`.
- `SQLTabExecutionTests` (RunletExecution, host PHP): a project driver's PDO and callable connections, names and errors (`custom-driver`); the driver's method winning over the built-in Laravel connection (`custom-laravel-driver`); Laravel connections, named connections, unknown names, and database errors (`laravel-app`, in a scratch copy); Eloquent through Capsule found without a driver method (`eloquent-app`); Doctrine DBAL 3 and 4 through `SqlConnections::doctrine()`; WordPress `$wpdb` on SQLite; the row cap, binary and long cells; the refusal on plain, Composer, and Symfony-without-Doctrine projects; and a run on Herd's PHP 7.4.
- The Debug app, with scratch data: a sandbox SQL tab running `INSERT`, `SELECT`, and `UPDATE`; the production confirmation on a never-connected production SSH profile; the unknown-connection and no-connection messages; a `.sql` file opened without running; the several-statements refusal. Screenshots are in [PR #120](https://github.com/filipac/runlet/pull/120).
- The Debug app, with a scratch SQLite project: Run All committing three statements, a failing script rolled back, completion of an alias's columns from the schema a run read, the production confirmations for Run All and Load Schema, SQL snippets in the Snippets panel, and Save SQL Snippet. Screenshots are in [PR #131](https://github.com/filipac/runlet/pull/131).
- The Debug app, with a scratch SQLite project: the Database pane before loading, after a run, filtered by a column name, and an explorer table opened in a new SQL tab. Then that result in a result window with two filter rules and a sort, in light and dark. Screenshots are in [PR #134](https://github.com/filipac/runlet/pull/134).

- `SavedConnectionTests` (RunletCore): `DatabaseConnection` coding and validation (names, hosts, ports, database names, SQLite paths, timeouts), `targets.json` from before saved connections and with a newer Runlet's driver, the cascade when a target is removed, duplicates without passwords, that `targets.json` (and its last-good copy), sessions, workspaces, and the encoded `RunRequest` hold no password, `SensitiveString`'s redaction, the in-memory store, the scratch data folder's Keychain service, and that `list_targets` leaves saved connections out. A real Keychain round trip under a test-only service runs only with `RUNLET_TEST_KEYCHAIN=1`.
- `SQLSavedConnectionTests` (RunletExecution, host PHP, SQLite): a statement, Run All, and the schema through a saved connection, with a project driver whose file and bootstrap leave markers that must not appear; Test Connection, with a stored or a typed password; a Keychain that can't be read stopping the run before PHP starts; every event of successful and failed runs (including the Run Log) scanned for the password; a short password scrubbed from messages only; and PHP 7.4. In the Docker fixtures (`php:8.4-cli`, `php:7.4-cli`): an in-memory SQLite connection and the missing-driver message for PostgreSQL. On the SSH fixture with Keep compiled PHP: a run on the server, the missing-driver message, and an opcode cache that holds no password.
- `SQLLiveDatabaseTests.savedConnections` (live servers): MariaDB 11 and PostgreSQL 14 through saved connections from a plain PHP project: Test Connection's version, database, and user; a statement with its schema; MySQL's error echoing the statement with the password replaced; and a wrong password's error, which holds neither password.
- The Debug app, with scratch data and fixture passwords in memory: the connection editor, a successful Test Connection against the fixture PostgreSQL, the SQL bar's list with application and saved connections, a result from a saved connection, and the schema explorer on it. Screenshots are in [PR #157](https://github.com/filipac/runlet/pull/157).

- `SQLTabTests` and `OutputTableLayoutTests` (RunletCore), `RunTimingTests.sqlResultsArriveWithTheirTable` (RunletExecution) ([#162](https://github.com/filipac/runlet/issues/162)): a result's table is built once, where its event is decoded (off the main thread), rebuilt only when its rows change, and never encoded; the largest result (1,000 rows × 200 columns) decodes with its table on a task of its own; an `sql` event read by `RunSession` arrives with its table; the grid's height and which scrolls go to the output.
- The Debug app, with a scratch SQLite project (#162): main-thread stalls (`RUNLET_DEBUG_TIMING`'s `longest` and `lagMax`) and scrolling (`scroll-check`) for results of 50, 333, and 1,000 rows and 1,000 rows × 31 columns, before and after the grid; a slow recursive CTE with tab switches while it runs; the card's filter and sort (`table-filter`, `table-sort`, `table-state`); a PHP collection's Table view. Numbers and screenshots are in [PR #163](https://github.com/filipac/runlet/pull/163).

- `ReadOnlyConnectionTests` (RunletCore): every session-changing form refused, whatever the case and comments; writes and unknown statements refused; reads and plain transaction control allowed; each database's reading (MySQL's backslash escapes and executable comments, PostgreSQL's `#` and `E''` strings); the stricter marking and its colour; connections and `targets.json` saved before this phase decoding unchanged, with nothing at its default written; the run request's flag; Test Connection's summary.
- `SQLReadOnlyConnectionTests` (RunletExecution, host PHP, SQLite): reads, Run All of reads and transaction control, the schema, and Test Connection in a read-only session; the runner refusing writes and session changes (and a whole Run All) before connecting; an `INSERT` sent past both checks failing in SQLite, also after `PRAGMA query_only = 0`, while the same connection without Read-only writes; PHP 7.4; and the runner's rules agreeing with the app's on the same statements.
- `SQLLiveDatabaseTests.readOnlySavedConnections` (live servers): on MariaDB 11 and PostgreSQL 14, reads, the schema, and Test Connection in a read-only session; `INSERT`, `UPDATE`, `CREATE TABLE`, `DROP TABLE`, `SET SESSION TRANSACTION READ WRITE`, and each server's other session changes refused by Runlet; the same writes, a temporary table, `FOR UPDATE`, and `nextval()` sent past the checks failing in the database; a session switched back read-write past the checks being read-only again for Run All's next statement; Run All of reads with and without a transaction; and a script with one write refused whole.
- The Debug app, with scratch data and fixture passwords in memory: the editor with Read-only, a production marking, and a colour after Test Connection; the SQL bar's list with the badges; the production confirmation for a production connection on a development target; its result in a read-only session; Run History marking it as production; and an `UPDATE` refused. Screenshots are in [PR #161](https://github.com/filipac/runlet/pull/161).

- `ConnectionOptionsTests` (RunletCore, #140): connections and `targets.json` saved before keeping their keys; the options round-tripping and written only when set; a TLS setting from a newer Runlet leaving the connection out; normalization per driver (a socket replacing the host, TLS files dropped with TLS off, init statements and options trimmed, the DSN kept only for custom); validation of sockets, charsets, each driver's TLS modes, TLS files, DSN options (password-like and field-managed keys refused), custom DSNs (passwords, `uri:`), Read-only per driver; the init statement rules on read-write and read-only connections; Test Connection's TLS summary.
- `SQLConnectionOptionsTests` (RunletExecution, host PHP 8.4 and 7.4, #140): the DSN and PDO attributes the runner builds for each driver from the real request (MySQL host and socket, `Pdo\Mysql::ATTR_*` on 8.4 and `PDO::MYSQL_ATTR_*` on 7.4, PostgreSQL socket, quoting, TLS files, encoding and options, SQL Server through pdo_sqlsrv and pdo_dblib, custom DSNs, read-only SQLite's open flags); what a driver can't express stopping before connecting, with no password in any event; init statements on every run, Test Connection, and the schema, a failing one, and transaction control refused; init statements keeping a read-only SQLite session read-only, and the runner refusing undoing or writing ones; the runner's and the app's init rules agreeing; a custom SQLite DSN with the schema; and every SQL Server DSN Runlet builds accepted by host PHP's pdo_sqlsrv keyword parser (it then reports its missing ODBC driver), with an unknown keyword reported in pdo_sqlsrv's words.
- `SQLLiveTLSTests` (live servers with TLS, #140): `scripts/setup-fixtures.sh databases` gives both fixtures throwaway certificates (a test CA, a server certificate for `localhost` and `127.0.0.1`, a client certificate, and a second CA that signed nothing, in the gitignored `Tests/Fixtures/docker/tls`) and prints `RUNLET_TEST_TLS`; both still accept plain connections. On PostgreSQL 14: Off reports no encryption; Prefer, Require, Verify CA, and Verify CA and host name encrypt (TLSv1.3); the other CA fails Require, Verify CA, and Verify; a host name the certificate doesn't name (through `hostaddr`) passes Verify CA and fails Verify CA and host name; the client certificate reaches `pg_stat_ssl`; `client_encoding` and `application_name` apply; init statements on a read-only connection set the search path and time zone, a writing function in one is refused by the read-only session, and `SET default_transaction_read_only = off` is refused before connecting. On MariaDB 11: no TLS without a mode; Require and Verify encrypt; the other CA passes Require and fails Verify; a `REQUIRE SSL` user is refused without TLS and admitted with it; a `REQUIRE X509` user needs the client certificate; the charset applies; init statements on a read-only connection, a writing stored function in a `SET` refused by the session, and `SET GLOBAL` refused before connecting. PHP 7.4 encrypts on both (Herd's 7.4.33 build crashes when mysqlnd's certificate check fails, so only successes run there).
- The Debug app, with scratch data, fixture passwords in memory, and the fixture PostgreSQL with TLS: the editor's Advanced section (TLS with a CA and client certificate, init statements, a DSN option) and a successful Test Connection reporting TLSv1.3; the production confirmation listing the init statements; the result showing them applied over TLS; a SQL Server connection and its Test Connection on a PHP with pdo_sqlsrv but no ODBC driver; a custom DSN for a driver the PHP lacks. Light and dark screenshots are in [PR #165](https://github.com/filipac/runlet/pull/165).

MariaDB 11 and PostgreSQL 14 were exercised live by `SQLLiveDatabaseTests` and `SQLLiveTLSTests`. MySQL 8 itself and SQL Server were not run: MySQL uses the same `information_schema` queries as MariaDB, and SQL Server's catalog query follows its documented `INFORMATION_SCHEMA`.
