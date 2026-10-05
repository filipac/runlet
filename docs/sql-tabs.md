# SQL Tabs

An SQL tab is a scratch SQL client for its tab's target. By default, a statement runs through your application's own database connection, the one its code uses, so Runlet needs no credentials from you:

```sql
SELECT id, email, created_at
FROM users
ORDER BY created_at DESC
LIMIT 10;
```

For a database your application doesn't configure, you can [save a connection](#saved-connections) yourself. Its password is kept only in the macOS Keychain.

> [!NOTE]
> Nothing in an SQL tab runs by itself. Opening, restoring, or switching to an SQL tab, and choosing its connection, never connects or runs anything.

## Creating an SQL Tab

- Choose **File ▸ New SQL Tab** (also in the command palette). The new tab uses the current tab's target.
- Switch an existing tab with **Window ▸ Switch Tab Language (PHP/SQL)**, or **Switch to SQL** in the tab's context menu.
- Open a `.sql` file with **File ▸ Open…**, from Finder, or with `runlet report.sql`. The tab follows the file, and Save As writes `.sql`.

The tab's language is saved with your session, in workspaces, and in run history. **Duplicate Tab** and **Reopen Closed Tab** keep the language and the connection. **New SQL Tab** has no default shortcut; give it one in **Settings ▸ Shortcuts**.

SQL tabs highlight keywords, strings, comments, numbers, placeholders, function names, quoted identifiers, and table names, and **Toggle Line Comment** uses `--`. They have their own [completion](#completion) instead of PHP's, and the status bar shows **SQL**.

## Running Statements

### Running One Statement

**Run** (<kbd>⌘</kbd><kbd>R</kbd>) sends one statement:

1. **The selection**, if there is one. It must hold exactly one statement.
2. Otherwise, **the statement at the caret**. With the caret right after a `;`, that's the statement that just ended.

**Run Selection** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>R</kbd>) needs a selection. Statements are separated by semicolons outside strings, quoted identifiers, comments (`--`, `#`, `/* */`), and PostgreSQL's dollar-quoted bodies. The output says which lines ran, and on which connection.

When the selection holds several statements, nothing runs, so a script never runs halfway. Use [Run All Statements](#run-all-statements) for that.

> [!NOTE]
> Client commands such as MySQL's `DELIMITER` aren't supported. Write strings the standard way (`'it''s'`): MySQL's backslash escapes inside strings can confuse the statement splitter.

### Run All Statements

**Run ▸ Run All Statements** (<kbd>⌥</kbd><kbd>⇧</kbd><kbd>⌘</kbd><kbd>R</kbd>), or **Run All** in the SQL bar, runs every statement of the selection, or of the whole tab:

- **In order, on one connection.** Each statement gets its own result card, such as **Statement 2 of 5**, with its line, its text, and its rows or affected-row count.
- **It stops at the first error.** The failing statement's card says which statement failed and why, and which statements didn't run.
- **In a transaction**, with the **In a Transaction** checkbox in the SQL bar (on by default, saved with the tab). The script is committed after its last statement and rolled back when a statement fails: "Rolled back the transaction: statements 1–2 were undone." With the checkbox off, each statement commits on its own.

> [!WARNING]
> MySQL and MariaDB commit some statements at once, with everything before them, even inside a transaction: `CREATE`, `ALTER`, `DROP`, `RENAME`, `TRUNCATE`, `GRANT`, `REVOKE`, `LOCK`, and table maintenance. When a script holds one, the output says so before the first statement runs, and a later failure rolls back only the statements after it. PostgreSQL and SQLite roll back schema changes too.

A script that manages its own transaction (`BEGIN`, `COMMIT`, `ROLLBACK`, `SAVEPOINT`, …) is refused while **In a Transaction** is on: turn it off to run the script as written. Statements that can't run inside a transaction, such as PostgreSQL's `VACUUM`, need it off too.

Run History keeps the whole script as one entry. **Run** (<kbd>⌘</kbd><kbd>R</kbd>) still runs one statement: Run All is always a separate action.

### Stopping a Statement

**Stop** (<kbd>⌘</kbd><kbd>.</kbd>, or the running row's button) ends a statement on the database server too, not only in Runlet. That matters: MySQL and MariaDB keep executing a long `UPDATE` after its client goes away, and PostgreSQL usually finishes the statement while holding its locks.

Runlet sends the database's own cancel (`KILL QUERY` on MySQL and MariaDB, `pg_cancel_backend()` on PostgreSQL) from a second, short-lived connection, after checking that it reached the same server and the same session. The output says what happened: "Cancelled the statement on the server (KILL QUERY 4711).", or why it couldn't. A statement you stopped shows a grey "Interrupted by Stop." line instead of an error card.

- Stop waits at most 8 seconds for the cancel, then stops the run anyway.
- Stop never asks, on production too: it only stops what you already confirmed.
- In a Run All transaction, the cancelled statement fails like any failing statement, and the transaction is rolled back.
- Cancelling your own statement needs no privilege on MySQL, MariaDB, or PostgreSQL.
- SQLite needs no server cancel: stopping the run stops the database too.

> [!WARNING]
> Behind a transaction-pooling proxy (PgBouncer in transaction mode, ProxySQL), a session id can belong to another client's connection by the time you press Stop. Runlet's checks make cancelling someone else's statement unlikely, not impossible.

The [Connection Manager](connections.md) (**Window ▸ Connections**, <kbd>⇧</kbd><kbd>⌘</kbd><kbd>C</kbd>) lists every statement that runs, with its connection, tab, and session id, and its **Close** is the same Stop. Runlet opens a database connection per statement and keeps no idle ones.

## Bound Parameters

A statement can use `:name` and `?` placeholders, such as one copied from the Queries inspector or from your application's code. You give the values in the parameters drawer under the editor, and the database driver binds them:

```sql
-- @param :status text paid
SELECT id, total FROM orders WHERE status = :status AND total > :minimum;
SELECT * FROM orders WHERE id IN (?, ?);
```

### The Parameters Drawer

When the statement the next Run would send has placeholders, a drawer opens at the bottom of the editor. It has one row per value: each `:name` once, however often the statement uses it, and each `?` in order (`?1`, `?2`, …). Each row has a type and a value:

| Type | Use it for |
| --- | --- |
| Text | Strings, as typed. An empty field is an empty string. |
| Integer | Whole numbers (64-bit). Use it for `LIMIT ?` on MySQL. |
| Decimal | Numbers such as `19.99` or `1e3`. They're sent as text, so a `DECIMAL` column keeps every digit. PostgreSQL may need a cast: `CAST(:price AS numeric) + 1`. |
| Boolean | A checkbox. MySQL stores it as 1 or 0. |
| NULL | No value. |

- **It follows the text and the caret.** The rows update a moment after you stop typing. Values stay with the tab, even when a placeholder goes away for a while, and a `:name` you rename keeps its value.
- **Missing values.** A row is *not set* until you type in it or a `-- @param` comment gives its value. A value that doesn't fit its type (`12a` as an integer) says why in red.
- **Collapse** the drawer with its chevron to one line, such as "2 parameters: :min_rent = 1000, :skip = 'Linus'".
- **Keyboard.** <kbd>Tab</kbd> and <kbd>⇧</kbd><kbd>Tab</kbd> move between fields, <kbd>Return</kbd> (or <kbd>⌘</kbd><kbd>R</kbd>) runs, and <kbd>Esc</kbd> returns to the editor.

Run uses the drawer's values right away, without asking. When a value is missing or doesn't fit, nothing runs: the drawer focuses that field and says why ("Set a value for :skip to run.").

With several statements in the tab, the drawer's **Statement | All Statements** switch shows the values that Run or Run All Statements needs. A name used by several statements is one row; each statement's `?`s are rows of their own.

### Writing Values as Comments

Values you type last until Runlet quits; they're never saved to a file. To keep them with the SQL (in a saved file, a snippet, or for a colleague), click **Write as @param Comments** in the drawer. Runlet writes them as comments, in one edit you can undo:

```sql
-- @param :status text paid
-- @param :minimum decimal 100
SELECT id, total FROM orders WHERE status = :status AND total > :minimum;
```

A `-- @param` comment presets its row (marked **@param**). Write `-- @param :name <type> [value]` anywhere in the tab, or `-- @param ?2 <type> [value]` in a statement's own leading comments for its second `?`. The types are `text`, `integer`, `decimal`, `boolean`, and `null` (or `string`, `int`, `number`, `bool`, …). The value is the rest of the line, or a quoted string: `'it''s'`, or `"two\nlines"` as JSON. A value you set in the drawer wins over the comment.

### What Counts as a Placeholder

`?` and `:name` (letters, digits, and `_`) count; nothing inside strings, comments, or quoted names does. PostgreSQL's `::` casts and MySQL's `:=` aren't placeholders, and `??` stands for a literal `?`, so PostgreSQL's `?` JSON operators are written `??`, `??|`, and `??&`, as in PHP code.

Runlet refuses, before anything runs:

- `:name` and `?` in the same statement;
- numbered placeholders such as PostgreSQL's `$1`;
- names PDO reads differently, such as `:café`;
- on MySQL and MariaDB, one name in several places of a statement (`WHERE a = :id OR b = :id`): give each place its own name, or use `?`.

Connections that can't bind values (WordPress's `$wpdb` fallback, Doctrine without a PDO connection, a project driver's callable) refuse statements with placeholders. Runlet never writes values into the SQL instead. On WordPress, use `$wpdb->prepare()` in a PHP tab.

### Values and Safety

- Values never become part of the SQL text: a value of `'; DROP TABLE orders; --` is just text.
- A [read-only connection](#read-only-connections) still refuses `UPDATE … = :value`: write detection reads the statement, whatever the values.
- Production confirmations list the values next to the statement, and the output's first line names them.
- Run History keeps the values with the statement, as `-- @param` lines, so opening the entry again presets the drawer.

> [!WARNING]
> Values are no more hidden than literals typed into a statement. Don't put secrets in them on a shared Mac.

## Results

While a statement runs, the output shows where and for how long ("Running on the default connection… 1.2 s") with a **Stop** button. Runlet stays responsive meanwhile.

A statement that returns rows shows a table with its columns in order, the rows, the row count, and the time it took. Duplicate column names (two `id` columns of a join) are kept. Any other statement shows how many rows it affected.

- **Filter rows** keeps the rows with a cell that contains your text ("12 of 1,000"). Click a header to sort (numbers as numbers, NULLs last), and drag its edge to resize the column.
- **Copy:** select rows and press <kbd>⌘</kbd><kbd>C</kbd> for tab-separated text. The context menu has Copy Value, Copy Row, Copy Row as CSV, and for one row, Copy Row as JSON and Copy Row as PHP Array.
- **Copy CSV** and **Export CSV…** write the rows shown. **Open in Window** opens the [result window](#the-result-window).

A line under the result names the driver (`sqlite`, `mysql`, `pgsql`, …), the connection, and where it came from, such as `via Laravel DB::connection()`. Database errors show as the run's error.

A statement that returns several result sets, such as a MySQL stored procedure (`CALL stock_report()`), shows one card per result: "Result 1 of 2", "Result 2 of 2".

**Limits.** Runlet shows at most 1,000 rows per statement (change it in **Settings ▸ General ▸ SQL Results ▸ Rows per page**: up to 10,000), 200 columns, 8 KiB per text cell, and 8 MiB per result. A cut read statement offers [Load Next](#loading-more-rows). Binary values show their size and first bytes in hex.

> [!TIP]
> PostgreSQL's driver loads a whole result into PHP's memory before Runlet reads the first rows, so add `LIMIT` when you query a large table.

### Loading More Rows

When the row limit cut a result, **Load Next 1,000** under the table runs the statement again for the following rows, and adds them to the same table. Filtering, sorting, and CSV export then cover every loaded row: "First 2,000 rows in 2 pages (more not shown)", and at the end, "End of the result: all 2,600 rows, in 3 pages."

- **Only plain reads page:** statements that start with `SELECT`, `WITH`, `TABLE`, or `VALUES`, can't write, and lock no rows. Writes such as `UPDATE … RETURNING`, locking reads (`FOR UPDATE`), and `SHOW`, `EXPLAIN`, or `PRAGMA` never page; the card says why. A statement of a multi-statement Run All doesn't page either: run it on its own.
- **Each page is a separate run,** on the same target and connection, with the same bound values. If the tab moved to another target or its saved connection changed, Load Next asks you to run the statement again.
- **Production asks again** for every page: "Load the next page on production (rows 1,001–2,000)?"
- Run History keeps each page as an entry, ending with a line such as `-- Load Next: rows 1,001–2,000`.

> [!WARNING]
> Rows can shift between pages when the data changes, and without `ORDER BY` the database may return rows in a different order each time. Add `ORDER BY` on a unique key for stable pages.

A card keeps at most 50,000 rows, 500,000 cells, and 64 MiB; then it suggests narrowing the statement or paging with `LIMIT` and `OFFSET` yourself.

### The Result Window

**Open in Window** above any result table opens it in a resizable window of its own. It works for an SQL tab's rows and for a PHP collection shown as a table, and it never runs anything: it shows rows the run already returned.

- **Search** all columns, and **Add Filter** rules per column: contains, doesn't contain, =, ≠, <, ≤, >, ≥, is empty or NULL, and isn't empty. Text comparisons ignore case, and numbers compare as numbers.
- **Columns:** sort, resize, drag to reorder, and hide or show them from the **Columns** menu.
- **Rows:** <kbd>⌘</kbd><kbd>C</kbd> copies them tab-separated. The context menu adds **Filter: column = value** for the clicked cell.
- The footer counts what's shown ("11 of 50 rows · 5 columns"), and **Copy CSV** and **Export CSV…** write it. A window opened from a cut result has **Load Next** too.

Result windows aren't saved with your session.

### Exporting a Whole Query

**Run ▸ Export Query to CSV…** writes every row of a read statement to a CSV file on your Mac, with no row limit. Under a cut result, **Export All Rows…** does the same. (A card's own Copy CSV and Export CSV… write only the rows it holds.)

The sheet has the delimiter (comma, semicolon, or tab), a header row, and how NULL is written: an empty field, or `\N` as MySQL's `LOAD DATA` and PostgreSQL's `COPY` read it. Values are written in full, as UTF-8 with RFC 4180 quoting.

- Only statements that [Load Next](#loading-more-rows) would page can be exported. Placeholders take their values from the drawer.
- The rows stream to the file as the database sends them, so a large export doesn't fill Runlet's memory. The sheet counts the rows and bytes, and **Stop** cancels the statement on the server.
- The file appears only when every row arrived: a stopped or failed export leaves no partial file, and a file you chose to replace stays as it was.
- The rows go only to the file, never to the output, the run log, or an AI client. Run History records the statement with a line such as `-- Export Query to CSV: 100,000 rows to orders.csv`.

## Explain Statement

**Run ▸ Explain Statement** (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>E</kbd>), or **Explain** in the SQL bar, shows the database's plan for the selected statement or the one at the caret. **It never runs the statement**: Runlet puts the database's own `EXPLAIN` in front of it and sends that alone.

| Database | Explain | Explain Analyze |
| --- | --- | --- |
| MySQL 5.6+ | `EXPLAIN FORMAT=JSON` | `EXPLAIN ANALYZE` (8.0.18+), reading statements only |
| MariaDB | `EXPLAIN FORMAT=JSON` | `ANALYZE FORMAT=JSON`, reading statements only |
| PostgreSQL | `EXPLAIN (FORMAT JSON)` | `EXPLAIN (ANALYZE, FORMAT JSON)`, in a transaction that's rolled back |
| SQLite | `EXPLAIN QUERY PLAN` | none |

The output shows the plan as a tree: each step's operation (Seq Scan, Hash Join, Index lookup, …), its table and index, the estimated rows and cost, and its conditions. Collapse a step with its chevron, or **Collapse All**.

- **Full scans are highlighted:** a step that reads every row of a table gets an orange row and a FULL SCAN badge, and the card counts them. On a small table, a full scan is often the cheapest plan.
- **Raw** shows the database's own output. Copy gives the tree as indented text.
- Placeholders take their values from the [parameters drawer](#bound-parameters).
- Production asks before an Explain, like every SQL action, although the statement doesn't run.

Other databases, and connections whose database Runlet doesn't know, say so and run nothing: write `EXPLAIN` in the tab and Run it instead. A statement that already starts with `EXPLAIN` or `DESCRIBE` is refused: run it with Run.

### Explain Analyze

**Run ▸ Explain Analyze…** (also in the Explain button's menu) **runs the statement**, and shows the plan with what happened: the rows each step returned and its time, and on PostgreSQL, the planning and execution time.

- **A statement that can change data asks first** ("EXPLAIN ANALYZE runs the DELETE"), with Cancel as the default.
- **PostgreSQL** runs it in a transaction that Runlet rolls back, so a write's changes don't stay; the card says **Rolled back**. Sequences it advanced, and anything it did outside the database, do stay.
- **MySQL and MariaDB refuse writes** under Explain Analyze, because Runlet couldn't undo them. Reads run as written.
- **SQLite** has no `EXPLAIN ANALYZE`.

## Completion

SQL tabs complete as you type (after two letters, or `.` after a table or alias), and on **Show Completions** (<kbd>⌃</kbd><kbd>Space</kbd>):

- **Keywords and functions, always,** even with no connection: `SELECT`, `LEFT JOIN`, `IS NOT NULL`, `COUNT()`, `COALESCE()`, … Keywords follow the case you type.
- **Tables** after `FROM`, `JOIN`, `UPDATE`, `INTO`, `TABLE`, and `DESCRIBE`.
- **Columns** of the tables the statement names, first, wherever a column fits. `alias.` and `table.` list that table's columns (`FROM orders o` … `o.`), and `schema.` lists a PostgreSQL schema's tables.
- Names that need quotes are inserted quoted: backticks on MySQL, double quotes elsewhere.

Tables and columns come from the schema of the tab's connection. Runlet reads it, names and types only, never rows:

- when you choose **Load Schema** in the SQL bar's schema menu (production asks first, every time);
- along with the first successful run on a connection, except on production.

The schema stays in memory until you choose **Forget Schema**, edit the target, or quit Runlet. A schema that can't be read never fails a run; the menu says why.

## Schema Explorer

**Library ▸ Database** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>B</kbd>) shows the database of the current tab's target: an SQL tab's connection, or the default connection of a PHP tab. It shows the same schema [completion](#completion) uses, so nothing loads until you choose **Load Schema** or run a statement.

- **Tables and views,** each with its column count and, on MySQL, MariaDB, and PostgreSQL, the estimated number of rows.
- **Columns** of an expanded table: the type, the primary key, a foreign key's target (`→ customers.id`), NOT NULL, and the default. Then the table's indexes.
- **Filter** by table or column name.

None of its actions runs anything by itself:

| Action | What it does |
| --- | --- |
| **Open in SQL Tab** (double-click a table) | Opens `SELECT * FROM <table> LIMIT 50` in a new SQL tab, without running it. |
| [**Browse Table**](#browsing-and-editing-a-table) | Opens the table's rows in a window, a page at a time, where you can edit them. |
| [**Show Definition**](#showing-a-definition) | Shows the table's or view's `CREATE` statement. |
| [**Show Relations**](#showing-relations) | Draws the table and the tables its foreign keys connect it to. |
| [**Import CSV…**](#importing-csv) | Inserts the rows of a CSV file into the table. |
| **Open as PHP (Query Builder)** | On Laravel: opens `DB::table('<table>')->limit(50)->get();` in a new PHP tab. |
| **Insert Name** (double-click a column) | Inserts the name at the cursor, quoted as completion quotes it. **Copy Name** and **Copy table.column** copy it. |

### Browsing and Editing a Table

**Browse Table** opens a table in a window of its own, titled "orders · Browse", on the pane's target and connection. It reads one page when it opens, and another when you ask.

- **Pages on the server.** A page holds 25 to 1,000 rows (100 by default). **Previous** and **Next** are in the footer, which says which rows show ("Rows 101–200"), and **Reload** reads the page again.
- **Order.** Pages follow the primary key, so they stay stable. Click a header to sort on the server; click it again to reverse.
- **Filters on the server.** **Add Filter** adds a rule for a column, and **Apply Filters** (<kbd>⌘</kbd><kbd>Return</kbd>) reads the first page with them. Values are bound, never written into the SQL, and checked against the column's type first ("“seven” isn't a whole number").

On a table with a primary key, you can edit rows. Nothing is sent while you edit: changed cells show in orange, rows to delete are struck through in red, and new rows show in green.

- **Edit Value** (double-click a cell) shows the column's type, NOT NULL, and default. **NULL** is a checkbox; the text "NULL" is text. The context menu also has **Set to NULL** and **Revert**.
- **Add Row** adds an empty row. Columns left on **Default** get the database's default, such as an auto-increment key. **Delete Row** marks the selected rows.
- Text longer than 8 KB and binary values can't be edited.

**Review Changes** lists the exact statements **Apply** will run, with their values:

```sql
DELETE FROM "products"
WHERE "id" = ?
-- ?1 = 5
UPDATE "products"
SET "price" = ?
WHERE "id" = ? AND "price" = ?
-- ?1 = 129.90, ?2 = 2, ?3 = 26.9
INSERT INTO "products" ("name", "category", "price")
VALUES (?, ?, ?)
-- ?1 = 'Reading light Gale', ?2 = 'Lighting', ?3 = 79.90
```

**Apply** runs them in one transaction. Each statement must change exactly one row. An `UPDATE` also checks the old value of each column it changes, so if someone else changed the row since you read it, nothing is applied: Runlet rolls everything back, and the footer says which change failed and why. **Discard** drops your pending changes; closing the window does too.

Rows are read-only for views, tables without a primary key, [read-only connections](#read-only-connections), and connections that can't bind values. On production, every read asks first, and **Apply** always asks, listing every statement. Every Apply is one entry in Run History; reading pages isn't recorded.

### Showing a Definition

**Show Definition** reads a table's or view's definition from the database's catalog and shows it in a sheet. No rows are read, and nothing is changed or run.

| Database | How |
| --- | --- |
| MySQL, MariaDB | `SHOW CREATE TABLE` or `SHOW CREATE VIEW`, and `SHOW CREATE TRIGGER` for the table's triggers: the server's own text. |
| SQLite | The `CREATE` statement as it was written, then the object's indexes and triggers. |
| PostgreSQL 12+ | Rebuilt from `pg_catalog`, since PostgreSQL has no `SHOW CREATE`: columns, constraints, partitioning, indexes, triggers, comments, and the enum types the columns use. Owners, privileges, policies, and rules are left out. |

A comment header above the definition says what was read, from which server, and that nothing ran. **Copy** copies it, and **Open in SQL Tab** opens it in a new tab without running it. SQL Server isn't supported yet.

### Showing Relations

**Show Relations** opens a diagram of one table: the table in the middle, the tables it references on the left, and the tables that reference it on the right. It's drawn from the schema the Database pane already loaded, so it reads and runs nothing.

- **1 Hop** shows the tables one foreign key away; **2 Hops** adds the tables connected to those.
- Each table shows its keys and the columns other tables reference; **All Columns** shows every column.
- **Click a table** to centre the diagram on it. **Back** and **Forward** go through the tables you centred on.
- **Click a key's label** to select it. The footer shows its join, such as `JOIN customers ON customers.id = orders.customer_id`, with **Copy Join** and **Insert Join**, which inserts it into the SQL tab without running it.
- **Export** saves the diagram as a PNG image or an SVG drawing.

### Server Details and Sessions

The Database pane's **Server** section (the **Tables | Server** switch) shows the database server of the same connection. Nothing is read until you click **Read Server Details**:

- **Server:** the product and version, the current database and user, uptime, the number of connections, and whether the connection is encrypted.
- **Sizes:** the database's size, and its 20 largest tables with their data and index sizes.
- **Sessions:** who is connected, active ones first: the user and host, the state, how long it has run, how long its transaction has been open, what it waits for ("waits for #4711"), and its statement. The pane's own session is marked **THIS PANEL**.

A session's menu has **Cancel Query…**, which stops its statement and keeps the session, and **Kill Session…**, which ends it (the server rolls back its open transaction). **They always ask**, on every connection, and never act on the pane's own session. Runlet checks that the session is still the one listed before it sends anything.

Each part is read separately, so a missing privilege hides only what it covers, and the section says what you can't see. The Sessions header can refresh the list every 5, 10, or 30 seconds; it stops when the section hides or Runlet goes to the background, and isn't offered on production. MySQL, MariaDB, PostgreSQL, and SQLite are supported.

### Importing CSV

**Import CSV…** in a table's context menu inserts the rows of a CSV file into that table:

1. **Choose a file.** Runlet reads UTF-8 files up to 8 MiB and 100,000 rows. It detects the delimiter and whether the first row is a header; you can change both.
2. **Map the columns.** Each column takes the CSV column of the same name, or the CSV's columns in order. Choose **Don't import** to leave a column to its default. **Empty fields are NULL** is on by default.
3. **Preview** the first five rows and the `INSERT` statement.
4. **Import.** Every row is inserted with bound values, in **one transaction**. At the first error, everything is rolled back, and the sheet names the failing line: "Line 213 of parts.csv (row 212) failed: … Duplicate entry '5' for key 'PRIMARY'."

Imports are refused on read-only connections and into views, and production asks first with the row count and the table. For larger files, use the database's own loader (`LOAD DATA`, `COPY`).

## Snippets

**Save as Snippet…** (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>S</kbd>) in an SQL tab saves an SQL snippet. Saved to the project, it's a `.sql` file in `.runlet/snippets/`. SQL snippets show an **SQL** badge in the Snippets panel and open as SQL tabs, never running. See [personal snippets](personal-snippets.md) and [project snippets](project-snippets.md#sql-snippets).

A snippet can remember its connection: these are Runlet's saved queries. The **Save SQL Snippet** sheet has **Open on the saved connection “Reporting”**, on by default. Runlet stores only the connection's name, so the snippet works on other targets and Macs.

## History

Run History keeps each statement with the connection it ran on, by name, never its host, user, or password:

- Rows show the connection after the target: "orders · Reporting".
- Search matches the connection's name, and a **Connection** menu shows one connection's runs.
- The same statement on another connection is an entry of its own.
- Opening an entry puts the SQL tab on its connection. Restoring never runs anything.

### Which Connection Opens

An entry or a snippet opens on its connection as it's found on the tab's target: an application connection by its name; a saved connection of that target or of all targets, by name (ignoring case). Another target's own connection is never used. When the connection doesn't exist there, the tab uses the default connection, and the SQL bar says so: "The connection “Archive” from this entry no longer exists; using the default connection."

## Connections

The SQL bar above the editor picks the tab's connection. Choosing one never connects or runs anything. Its list has two parts:

- **Application connections:** **Default connection**, or a connection your application configures. After a run, the list shows the names the framework reports, such as Laravel's `database.connections`. **Other Connection…** takes any name.
- **Saved connections:** the ones [you saved](#saved-connections) for this target or for all targets, then **New Connection…** and **Edit Connections…**.

Runlet finds an application connection inside your app, in the same PHP process that boots it for a run:

1. A [project driver's](drivers.md#sql-connections) `sqlConnection()`.
2. The framework's own connection: Laravel's `DB::connection()`, Symfony's Doctrine connection, or WordPress's database from `wp-config.php` (through PDO, or `$wpdb` when PDO isn't possible). Code that sets up Eloquent through Capsule, or `$wpdb`, works too.
3. Otherwise, the run stops with **No SQL connection**. Runlet never guesses credentials: [save a connection](#saved-connections) for the target, or add `sqlConnection()` to a project driver.

Any PDO driver works. MySQL, MariaDB, PostgreSQL, and SQLite are the usual ones.

## Saved Connections

Save a connection for a database your application doesn't configure: a read replica, a reporting or legacy database, or a project without a driver. **New Connection…** in the SQL bar creates one, and the tab switches to it when you save it. Its password is kept only in the macOS Keychain, and a statement on it runs no project code. The [Connections](connections.md#saved-connections) page has every field and option.

### From This Mac, and for All Targets

A saved connection opens in the target's PHP by default. **Connect from: This Mac** opens it with a PHP on your Mac instead, for a database your Mac can reach but the target can't. A connection saved for **All targets** shows in every SQL tab, the sandbox's too. See [From This Mac, and for All Targets](connections.md#from-this-mac-and-for-all-targets).

### Through an SSH Tunnel

**Connect from: This Mac, through SSH profile** reaches a database only a server can reach, such as one behind a bastion, through a local port forwarded over the SSH profile's connection. Runlet asks before it connects. See [Through an SSH Tunnel](connections.md#through-an-ssh-tunnel).

### Read-Only Connections

A read-only connection lets you look at data, production data included, without changing it. MySQL, MariaDB, PostgreSQL, and SQLite refuse writes in its session, and Runlet refuses statements that could write before sending them. See [Read-Only Connections](connections.md#read-only-connections).

### Connection Options

The connection editor's **Advanced** section has a Unix socket, the charset, TLS, init statements such as `SET search_path TO reporting, public`, and DSN options. See [Connection Options](connections.md#connection-options).

### Import From TablePlus

**Import from TablePlus…** creates saved connections from the ones TablePlus keeps. It's behind a feature flag in **Settings ▸ Advanced**. See [Import From TablePlus](connections.md#import-from-tableplus).

## Safety

- **Nothing runs by itself.** Opening, importing, or restoring an SQL tab never runs it. SQL tabs have no auto-run, and AI clients can't run SQL.
- **Production always asks.** On a production target, or with a connection marked production, every statement, Run All, Load Schema, Explain, and Load Next page shows the confirmation (<kbd>⌘</kbd><kbd>Return</kbd> confirms), even during a production grace period for PHP snippets. It shows the statement, the connection, and its bound values, and a red warning when the statement can write: `UPDATE`, `DROP`, `SELECT … INTO`, `FOR UPDATE, which locks rows`, …
- **Development and staging don't ask**, for reads or writes: an SQL tab is a scratch client, like the PHP tabs that can write to the same database. Run History keeps every statement that ran.
- **Reading tools read only when you ask:** Load Schema, Show Definition, the Server section, and Browse Table. Show Relations reads nothing.
- **Changes you review:** Browse Table applies only the statements Review Changes showed, in one transaction. Import CSV inserts in one transaction.
- **Saved connections** boot no project code and keep their passwords out of everything Runlet writes. SSH tunnels never connect by themselves.

**Write detection is best-effort.** Runlet treats a statement as a read only when it starts with `SELECT`, `SHOW`, `DESCRIBE`, `EXPLAIN` (without `ANALYZE`), `VALUES`, `TABLE`, `WITH`, or a reading `PRAGMA`, and holds no `INSERT`, `UPDATE`, `DELETE`, `MERGE`, `INTO`, `CREATE`, `DROP`, `ALTER`, or `TRUNCATE` outside strings and comments. Functions with side effects called from a `SELECT` aren't detected. On production, the confirmation shows for every statement anyway.

## For developers

SQL tabs were implemented under [#35](https://github.com/filipac/runlet/issues/35), with completion ([#128](https://github.com/filipac/runlet/issues/128)), Run All Statements ([#129](https://github.com/filipac/runlet/issues/129)), SQL snippets ([#130](https://github.com/filipac/runlet/issues/130)), the schema explorer and result window ([#21](https://github.com/filipac/runlet/issues/21)), bound parameters ([#145](https://github.com/filipac/runlet/issues/145)) and their drawer ([#168](https://github.com/filipac/runlet/issues/168)), Explain Statement ([#147](https://github.com/filipac/runlet/issues/147)), Stop that cancels the statement on the server ([#144](https://github.com/filipac/runlet/issues/144)), Load Next ([#146](https://github.com/filipac/runlet/issues/146)), Show Definition ([#148](https://github.com/filipac/runlet/issues/148)), Run History and SQL snippets that remember the connection ([#149](https://github.com/filipac/runlet/issues/149)), the Server section ([#150](https://github.com/filipac/runlet/issues/150)), Browse Table ([#151](https://github.com/filipac/runlet/issues/151)), CSV export and import ([#152](https://github.com/filipac/runlet/issues/152)), the relations diagram ([#153](https://github.com/filipac/runlet/issues/153)), several result sets ([#154](https://github.com/filipac/runlet/issues/154)), the native result grid ([#162](https://github.com/filipac/runlet/issues/162)), and the Connection Manager ([#180](https://github.com/filipac/runlet/issues/180)). Saved connections are [#138](https://github.com/filipac/runlet/issues/138), with read-only connections and environments ([#139](https://github.com/filipac/runlet/issues/139)), connection options ([#140](https://github.com/filipac/runlet/issues/140)), connections from this Mac and for all targets ([#142](https://github.com/filipac/runlet/issues/142)), SSH tunnels ([#143](https://github.com/filipac/runlet/issues/143)), the PHP chosen per driver ([#184](https://github.com/filipac/runlet/issues/184)), and the TablePlus import ([#188](https://github.com/filipac/runlet/issues/188), behind the flag of [#187](https://github.com/filipac/runlet/issues/187); Redis [#190](https://github.com/filipac/runlet/issues/190) and MongoDB [#209](https://github.com/filipac/runlet/issues/209) connections), part of the database roadmap [#137](https://github.com/filipac/runlet/issues/137). WordPress's own PDO connection is [#208](https://github.com/filipac/runlet/issues/208); New Redis and MongoDB Tab in the File menu are [#214](https://github.com/filipac/runlet/issues/214). This page was rewritten for the documentation website in [#287](https://github.com/filipac/runlet/issues/287); the detail below is what the user text leaves out. The saved connections' text, their internals, and their tests moved to [Connections](connections.md#for-developers) in [#290](https://github.com/filipac/runlet/issues/290); the headings above keep their anchors.

### Tabs and Running

- The language is saved as `"language": "sql"` with the tab in the session, in `.runlet` workspaces, and in run history. Sessions, workspaces, and history from before SQL tabs open as PHP. SQL text gets no PHPantom: no PHP diagnostics or PHP completion.
- A selection runs whatever Settings ▸ General says about running selections. The statement at the caret is the one the caret is in; else the one that ended earlier on the caret's line; else the next one; else the last one. A tab with a single statement runs it wherever the caret is. A comment on the line where a statement ended belongs to that line, not to the next statement.
- Several statements are refused before anything runs. As a second guard, the runner prepares the statement natively (MySQL's emulated prepares are turned off for the run; PostgreSQL prepares one statement), so the database itself rejects a second statement the splitter missed. SQLite's PDO runs only the first statement of a prepared text. A statement without placeholders is sent as written.
- Run All runs in one PHP process, split the same way as Run. A PDO connection (WordPress's own from `wp-config.php` too, #208) uses `beginTransaction()`, `commit()`, and `rollBack()`; a callable connection (WordPress's `$wpdb` fallback or `wpdb` connection, Doctrine without PDO, a project driver's callable) gets `BEGIN`, `COMMIT`, and `ROLLBACK` statements through the callable. `CREATE`/`DROP TEMPORARY TABLE` don't commit at once on MySQL; after a statement that does, Runlet opens a new transaction, and the failure message says which statements stay. On Stop, the transaction is rolled back by the runner when it is still alive, otherwise by the database when the runner's connection closes; statements MySQL committed at once stay. The refused transaction statements are `BEGIN`, `START TRANSACTION`, `COMMIT`, `ROLLBACK`, `SAVEPOINT`, `RELEASE`, and `END`; `CREATE INDEX CONCURRENTLY` also needs the checkbox off. Production asks once, listing every statement with its line and a red warning on each that can change data. A missing placeholder value stops the script before anything runs.

### Parameter Binding

- **Binding:** Text and Decimal bind as `PDO::PARAM_STR` (PDO has no decimal type; the database converts it), Integer as `PDO::PARAM_INT`, Boolean as `PDO::PARAM_BOOL`, NULL as `PDO::PARAM_NULL`. The values go with the statement in the run's request on PHP's standard input, as data in a PHP array of the generated call (`SqlTab::run(<sql>, …, [['name' => 'status', 'type' => 'str', 'value' => 'paid']])`), and the runner binds each one with `PDOStatement::bindValue` after preparing the statement natively (emulated prepares off), so the database receives the values apart from the statement.
- **The drawer** sits above the status bar, or above the output pane when that is below the editor. A row shows the placeholder, its line ("used 2 times" for a repeated name), its type, and its value. It updates later in a very large tab, so typing stays smooth, with the same detection Run uses. While you edit a statement, its `?` values stay with their positions. The list scrolls after five rows and shrinks when the editor's pane is short. Once set, an emptied Text field is an empty string, and says so; `1,5` as a decimal says why it doesn't fit. The drawer's **Run** button does what ↩ does; ↩ runs Run All while the drawer shows all statements.
- **Prefilled values** are kept per tab for the session: by name for `:name`, in any statement of the tab, and for `?` by the statement's text and position, so another statement's `?` doesn't inherit a value. They live in memory only, never in the session, a workspace, or a file. A `-- @param` preset follows the comment when you change it; a comment with a type and no value sets the row's type only; the first line for a placeholder wins; a line Runlet can't read is named in the drawer, and its row isn't preset.
- **Write as @param Comments** (the button with the text-insert icon) rewrites a placeholder's own `-- @param` line, or adds a line before the statement that uses it (a `?`'s in its own statement's comments). Rows without a value are left out, and so are placeholders declared in a `/* … */` or `#` comment.
- **All Statements:** `?` rows say their statement and line (`?1 · statement 2 · line 3`) when several statements have them. Run All checks every value before anything runs; when one is missing, the drawer switches to All Statements and focuses it. Explain Statement (#147) takes its values from the drawer as Run does.
- **The lexer** is the statement splitter's: `:name` is letters A–Z, digits, and `_`, as PDO reads them. On a saved connection, or once a run or Load Schema reported the driver, the text is read as that database reads it (MySQL's backslash escapes, PostgreSQL's `#` operator). PDO's message for mixed kinds is "mixed named and positional parameters"; `:a$b` is another name PDO reads differently. Different statements of a script may use different kinds.
- **Where binding fails:** callable connections are WordPress's `$wpdb` when Runlet couldn't open WordPress's PDO (or the `wpdb` connection), Doctrine without a PDO, and a project driver's callable; Run All refuses the whole script. WordPress binds through the PDO connection it opens from `wp-config.php` ([WordPress's connection](drivers.md#wordpress-connection)). MySQL's message for a repeated name is "Give each place its own name (:id, :id_2), or use ? placeholders"; PostgreSQL and SQLite bind it once. If PDO reads the statement differently from Runlet (a placeholder inside something PDO takes for a string or a comment, such as a `#` comment on PHP before 8.4), binding fails with PDO's message.
- **Texts:** production confirmations list "Bound values · 3: `:status 'paid' text`, …" (Run All once, below the statements); the output's first line reads "SQL from line 3 on the default connection, with :status = 'paid' and :minimum = 100 bound."; Run History writes `-- @param :status text paid`, and runs with different values are separate entries.

### Results, Load Next, and Export

- While a statement runs, the SQL bar shows a spinner (#162); Run All says "Running 3 statements on …". The statement runs in the runner process; the app only waits for its events. The time shown is what the runner measured for executing and fetching.
- The grid is native and draws only the rows on screen (#162). It grows with its rows up to 400 points, then scrolls inside; a vertical scroll that starts where the grid can't move (its rows fit, or it's at its top or bottom) scrolls the output instead. Copy Output and Copy Output as Markdown include the rows (tab-separated, or a Markdown table); the card's copy button copies them tab-separated. DDL usually reports 0 affected rows.
- **Several result sets** (#154): a SQL Server batch shows several too, and Run All titles them "Statement 2 of 3 · Result 1 of 2". A result without columns (a procedure's `UPDATE`) shows the rows it affected. MySQL's own status of the `CALL` (no columns, nothing changed) is left out, so a procedure with two `SELECT`s shows two tables, and a procedure without a result shows the rows its last statement affected, as one plain card. The row and byte limits apply to all of a statement's results together. When a later result fails (a procedure's `SIGNAL`), the results read before it still show, titled "Result 1" (Runlet can't know how many there would have been), then the error. Each result has its own Copy CSV, Export CSV…, and result window. SQLite and PostgreSQL return one result per statement. `CALL` counts as a statement that can write.
- **Limits:** Rows per page is 1,000, 2,500, 5,000, or 10,000. The rows after the limit aren't fetched, and MySQL results are read unbuffered for the run. Other cut results say why the rows stop. Bytes that aren't UTF-8 text show as binary (size and the first 32 bytes in hex), `NULL` as `NULL`. Errors never point at lines of Runlet's generated PHP.
- **Load Next** (#146) also appears when the 8 MiB bound cut a result. `CALL` can't be classified, so it doesn't page; nor does one of several result sets (#154). How a page skips the rows already shown:
  - On SQLite, MySQL, MariaDB, and PostgreSQL, Runlet adds `LIMIT 1001 OFFSET 1000` (one row more than a page, to tell whether more follow) on a line of its own after the statement, so the database skips the rows. The statement isn't wrapped in a subquery: MariaDB and MySQL may drop a derived table's `ORDER BY` (MariaDB 11 returns `1, 2, 3, …` for `SELECT * FROM (SELECT id FROM t ORDER BY id DESC) p LIMIT 5`), MySQL refuses a derived table with two columns of one name (a join's two `id` columns), and SQLite renames them. A trailing `LIMIT` after a `UNION` applies to the whole union, as in the first run.
  - On SQL Server, a statement with its own `ORDER BY` gets `OFFSET 1000 ROWS FETCH NEXT 1001 ROWS ONLY`.
  - Otherwise the runner skips the rows: the statement runs as written, and the runner fetches and discards the rows already shown before keeping the next page. It does this when the statement limits its own rows (`LIMIT`, `OFFSET`, `FETCH`, `TOP`), on SQL Server without `ORDER BY` or with `FOR XML`/`FOR JSON`, and for connections whose SQL dialect it doesn't know (a project driver's callable, WordPress's `$wpdb` fallback, other PDO drivers). WordPress's own PDO connection (#208) pages in the database. PostgreSQL's driver loads the whole result into PHP memory, as for the first run.
  - If the database refuses the added clause, the card shows its error and the clause, and suggests adding `LIMIT` and `OFFSET` yourself. If the connection's driver changed since the first run, or a page's columns differ from the result's, nothing is added and the card says to run the statement again.
- A page runs in a fresh runner, with the values bound again for every page (not read from the drawer again); a read-only connection stays read-only; a production page's confirmation shows the statement as it runs (with the added `LIMIT`) and its values. While a page loads, the card shows which rows and a **Stop** button; Stop, a new run, or Clear Output ends the page and adds nothing, and Stop cancels the page's statement on the server first. A new run or Clear Output also ends paging for the old result. Each page is at most Rows per page and 8 MiB; a card's 500,000 cells mean fewer rows of a wide result. Result windows opened from the card show later pages, with Load Next and Stop in their footer.
- **Export Query to CSV** (#152) is refused before the sheet opens for anything Load Next wouldn't page; **Export All Rows…** under a result reuses that run's values. Binary values are written as `0x` and hex, line ends are CRLF; an empty text value is written `""` (with empty-field NULLs), and a text value `\N` is quoted (with `\N` NULLs), so they stay apart from NULL. **Export…** asks where to save, then, on production, asks once for the whole export. The runner sends rows in frames of at most 1,000 rows (or about 256 KB) and Runlet writes each frame as it arrives and holds one at a time, so 100,000 rows take the same runner memory as 10. MySQL and MariaDB read unbuffered; PostgreSQL reads through a cursor (`DECLARE … CURSOR FOR` the statement, then `FETCH FORWARD 1000`) in a transaction that only reads and is rolled back at the end; SQLite and SQL Server step through the rows; a project driver's callable (WordPress's `$wpdb` fallback) returns its rows at once, so memory follows its result. The file is written next to the destination under a hidden name and moved into place when every row arrived. The Run Log logs the runner script's size only; the Connection Manager lists the export while it runs, and its Close is Stop. A read-only connection exports in its read-only session.

### Server-Side Cancel

- **How:** right after connecting, before your statement, the run notes its connection's session id on the server (MySQL/MariaDB `CONNECTION_ID()`, PostgreSQL `pg_backend_pid()`, SQL Server `@@SPID`). On Stop, Runlet starts a second, short runner on the same target with the same connection and sends `KILL QUERY <id>` (MySQL, MariaDB), `SELECT pg_cancel_backend(<pid>)` (PostgreSQL), or `KILL <spid>` (SQL Server, which ends the whole session; not tested against a live server yet). Then it stops the first runner. With an application connection, the second runner boots the application again and opens the same connection; with a saved connection, it opens the connection again (its password from the Keychain, on standard input) and boots no project code. Over SSH and in Docker it runs where the statement ran; for a saved connection that opens from this Mac it uses the same PHP on this Mac, in Runlet's empty folder.
- **Checks:** the second runner sends the cancel only when its connection reached the same database server (a list of hosts, a load balancer, or a failover could lead elsewhere, where the id is someone else's), and the session belongs to the same database user and still runs something.
- **The answer:** the database answers the cancel with an error (MySQL and MariaDB 1317 "Query execution was interrupted", PostgreSQL 57014 "canceling statement due to user request"). When Stop sent the cancel and the server took it, that error shows as the grey line; for Run All it also says which statement was interrupted and what was rolled back ("Interrupted by Stop: statement 2 of 3 (line 4). Rolled back the transaction: statement 1 was undone. Statement 3 did not run."). The database's words stay in Plain output, the line's tooltip, and the Run Log. Any other error, a cancel that wasn't your Stop (another session's `KILL QUERY`, a statement timeout), and a cancel that failed keep the red card; the same goes for Load Next pages and Explain Analyze. The other outcomes: the statement had already finished, the session was gone, "the database user may not cancel session 4711 (You are not owner of thread 4711)…", the statement still running 1.5 s after the server took the cancel (MySQL undoing a large change), or the second runner couldn't connect. Each is in the Run Log with the session id; a production cancel is recorded there too.
- `KILL QUERY` and `pg_cancel_backend` on your own session work in a read-only session. In a Run All transaction, Stop gives the runner up to half a second to roll back on its own; if it was already gone, the database rolls back the open transaction when it notices the closed connection. Another user's session needs `CONNECTION_ADMIN` or `SUPER` (MySQL), membership in the role or `pg_signal_backend` (PostgreSQL), or `ALTER ANY CONNECTION` (SQL Server, which needs it for every `KILL`). There is no server cancel for SQLite, callable connections (WordPress's `$wpdb` fallback, Doctrine without PDO, a driver's callable), and other PDO drivers; WordPress on MySQL or MariaDB cancels through its PDO connection (#208). A run that hadn't connected yet is just stopped. Session pooling and direct connections aren't affected by the pooler caveat.
- The Connection Manager (#180) lists a statement, Run All, Explain, Load Next page, Load Schema, Show Definition, and Server read as a database session: the statement's first line, the driver, database, and connection (and where a saved connection opens), the tab, since when, and the session id. SSH tunnels of saved connections are listed with what uses them.

### Explain Plans

- Explain runs on the tab's connection, application or saved. A saved connection with a custom DSN (#140) explains when its PDO driver is one of the four; SQL Server (`SET SHOWPLAN_XML`), other PDO drivers, and connections whose database Runlet doesn't know (a project driver's callable, Doctrine without a PDO) aren't supported. WordPress explains through its PDO connection (#208); its `$wpdb` fallback is MySQL. MariaDB is told apart from MySQL by its server version.
- Costs are in the database's own units; SQLite's query plan has no estimates, so its tree shows the steps only. Full scans are MySQL's and MariaDB's `access_type: ALL`, PostgreSQL's Seq Scan, SQLite's `SCAN` without an index, and MySQL's "Table scan on" (scans of MySQL's own temporary tables aren't counted). Raw is the JSON, MySQL's text tree, or SQLite's rows; when Runlet can't read a plan as a tree (an unexpected format, or a plan over 4 MiB), the card opens on Raw and says why. Copy, Copy Output, and Copy Output as Markdown give the tree as indented text; a line under the card names the database and its version, the connection, and where it came from. Run History keeps the statement with a first line saying it was explained, not run.
- MariaDB's `ANALYZE` statement is refused like `EXPLAIN` and `DESCRIBE`. Read-only connections (#139) explain reads; PostgreSQL also explains a write there without running it, while MySQL and MariaDB refuse to explain a write in a read-only session (error 1792), and Runlet says so. The production question is "Explain this statement on production?".
- Explain Analyze has no default shortcut. It asks for every statement Run would warn about on production (write detection is best-effort) and for statements Runlet can't classify. MySQL and MariaDB refuse writes because they commit DDL at once and can't roll back non-transactional (MyISAM) tables. Read-only connections refuse it for a write before connecting. Production always asks, with the `EXPLAIN ANALYZE … DELETE` warning for a write, and then doesn't ask a second time. When Runlet already knows the connection's database (a saved connection's driver, or a schema it read), it refuses what that database would refuse before asking.

### Completion and Schema Reads

- Show Completions is also ⌥Esc. Functions put the caret between the parentheses; keywords follow the case you type, or the statement's. Tables are offered after `FROM` and its commas. Columns show their table and type in the list; before `FROM`, every column is offered once. Names are quoted for spaces, reserved words, and PostgreSQL names with capitals. Nothing is offered inside strings, comments, quoted identifiers, numbers, or after a `:name` placeholder or `@variable`.
- The schema is read through the same resolution as a statement (the project's driver first, then the built-in framework connections). The schema menu shows "3 tables" or "No schema", with Load Schema / Reload Schema and Forget Schema (also **Load SQL Schema** in the palette). Load Schema runs in a fresh runner, apart from the tab's output. The first successful Run or Run All on a connection in a session reads its schema after the statements, in the same process.
- Catalogs: `information_schema.COLUMNS` on MySQL and MariaDB (the current database), `information_schema.columns` on PostgreSQL (the schemas on the search path; others as `schema.table`), `INFORMATION_SCHEMA.COLUMNS` on SQL Server, and `sqlite_master` with `pragma_table_info` on SQLite. A callable connection tries those catalogs in turn. A project driver can return the schema itself with `sqlSchema()` ([drivers.md](drivers.md#sql-connections)). At most 2,000 tables and 50,000 columns are kept, per target and connection, in memory only; an edit of the target forgets it. After a schema that can't be read, later runs don't retry (Load Schema does).
- The Database pane also reads each column's nullability, default, and primary key, then indexes and foreign keys in two more catalog queries: `information_schema` (`COLUMNS`, `TABLES`, `STATISTICS`, `KEY_COLUMN_USAGE`) on MySQL and MariaDB; `information_schema` with `pg_constraint`, `pg_index`, and `pg_class` (row estimates from `reltuples`) on PostgreSQL; `pragma_table_info`, `pragma_index_list`, and `pragma_foreign_key_list` on SQLite. Foreign keys keep their constraint, so a composite key is one relation (#153). SQL Server reads only the columns' details. When indexes or foreign keys can't be read (no catalogs, or permissions), the tables and columns still show with a note. Bounds: 2,000 tables, 50,000 columns, and 20,000 index columns. A driver's `sqlSchema()` can return these details too ([drivers.md](drivers.md#schema-for-completion)).

### Schema Explorer Internals

- The pane's filter puts tables whose name matches first; tables matched by a column show just those columns. Views carry a VIEW badge; indexes show their columns, UNIQUE, or PRIMARY. Before the schema is read, the pane explains what Load Schema does; on production its button asks every time; Reload and Forget are in its header.
- **Actions:** Open in SQL Tab is also a table's ↗ button and names the tab after the table, on the same target and connection (`SELECT TOP 50` on SQL Server). Browse Table, Show Definition, and Show Relations are also a grid, document, and diagram button. Open as PHP (Query Builder) is on Laravel, Lumen, and Laravel Zero, with `DB::connection(…)` for a named connection, and hidden for saved connections, because Runlet never generates PHP that contains a password.
- **Browse Table** (#151) opens on an application connection or a saved one (on the target, from this Mac, or through an SSH tunnel), each read in a fresh PHP process, like Load Next, so it never holds a session open between pages. Pages use `LIMIT … OFFSET …` (SQLite, MySQL, MariaDB, PostgreSQL) or `OFFSET … ROWS FETCH NEXT … ROWS ONLY` (SQL Server), asking for one row more; page sizes are 25, 50, 100, 250, 500, or 1,000; the footer also reads "Rows 26–31 of 31". Columns are the schema's, by name; a table with more than 200 columns shows the first 200. A sort is `ORDER BY` the column, then the primary key; a table without a primary key comes in the database's order, which can change between pages. Filters use the result window's operators, and the cell menu's Filter items add rules; a rule without a value yet is left out. Each value is typed by its column: a whole number for integer columns, a number for decimal ones, true or false for booleans, text otherwise.

  | Rule | SQL |
  | --- | --- |
  | contains, doesn't contain | `LIKE ? ESCAPE '!'` with `%value%` (`%`, `_`, and `!` in the value are literal); `ILIKE` on PostgreSQL, with other types cast to text; SQL Server casts other types to `NVARCHAR`. "Doesn't contain" also matches NULL |
  | =, ≠, <, ≤, >, ≥ | `= ?`, `<> ?` (≠ also matches NULL), `< ?`, … |
  | is empty or NULL, isn't empty | `IS NULL OR = ''` for text columns, `IS NULL` for the rest (and the opposite) |

  Case follows the database: MySQL and MariaDB compare most text without case; PostgreSQL's `=` doesn't (its contains uses `ILIKE`). Binary columns take only the empty rules; JSON takes contains and the empty rules; booleans take = and ≠.
- **Editing:** new rows show DEFAULT where the database fills the column. Edit Value shows what the page read; a value is checked against its column when you set it (a number for a decimal column, NULL refused for NOT NULL), and setting a cell back to what the page read drops the change. Binary columns can't be edited. While changes are pending, paging, sorting, filtering, and Reload wait. Review Changes lists each statement with what it changes ("row 3 · id = 7"): deletions first, then updates, then insertions; **Copy SQL** copies them with their values as `-- @param` lines. A failed Apply says, for example, "Change 2 of 2 (row 1 · id = 1): row not found: it was changed or deleted by someone else since the page was read"; pending changes stay. After a commit, the footer reports the rows affected and the page is read again.
- **Finding the row:** an `UPDATE` or `DELETE` finds its row by the primary key, and an `UPDATE` also checks the original value of each column it changes (`IS NULL` for NULL). Columns whose values don't read back exactly (floating-point numbers, JSON, binary, and types Runlet doesn't know) are checked by the key only. MySQL and MariaDB count only the rows an `UPDATE` changes, so when one reports none, Runlet counts the rows of the same `WHERE` in the transaction: one means the row is there and unchanged; none means it's gone.
- **Production and read-only:** reads ask "Read rows 1–100 of orders on production?" with the `SELECT` and its values; Apply lists every statement, its values, and what it changes, like Run All, and the page isn't read again by itself afterwards (Reload asks). Development and staging don't ask. The question shows in the main window of the tab the table was opened from; the browse window says so. Callable connections are read-only (WordPress only when it fell back to `$wpdb`, #208); should a change reach the runner on a read-only connection, it refuses it before connecting. Run History gets `-- Browse Table: 3 changes to orders`, then each statement with its values as `-- @param` lines, for every Apply, committed or rolled back (#149). Stop in the footer cancels a read or Apply on the server (#144); a stopped Apply commits nothing. The Connection Manager (#180) lists them. SQL Server pages with `OFFSET … FETCH` (not tested against a live server). Callable connections (WordPress's `$wpdb` fallback as MySQL, a driver's callable) browse read-only and filter only with the empty rules; WordPress's own PDO connection (#208) browses, filters, and edits like any PDO. Oracle and other drivers aren't supported. Table and column names come from the schema, never from what you type, and are always quoted (`"name"`, `` `name` ``, `[name]`, with the quote doubled inside); on PostgreSQL and SQL Server a `schema.table` outside the default schema is quoted part by part. If the table changed since the schema was read, the read fails or the window shows the rows read-only; reload the schema and browse again.
- **Show Definition** (#148) reads in a fresh PHP process, the way Load Schema reads names: on the target, where the application boots (a saved connection boots nothing), or on this Mac for a saved connection that opens there and for connections of all targets (#142). The sheet's subtitle names the connection, where it opens, and the server ("The saved connection “Shop” on acme · SQLite 3.45.2", or "… on this Mac (Runlet's PHP 8.5.8) · …"), and a badge says how it was read ("Read with SHOW CREATE TABLE", "Reconstructed from pg_catalog"). The definition is read-only and selectable, in the editor's font, line height, and SQL colours, and scrolls both ways without wrapping. The header says what was read, from which server and how, through which connection, when, and that nothing ran. The sheet is resizable (at least 720 × 480 points) and never saved with the session. Copy includes the header; Open in SQL Tab names the tab "orders (definition)" with the output pane hidden until a run, which on most databases would fail because the table exists. **Done** (↩) or Esc closes the sheet and stops a read still under way.
  - MySQL and MariaDB give columns, keys, foreign keys, checks, engine, charset, collation, partitioning, and comment; a view's definer and query. SQLite's indexes for PRIMARY KEY and UNIQUE have no SQL of their own; the table's definition says them. PostgreSQL's reconstruction is a `CREATE TABLE` with each column's type, collation, identity or generated expression, default, and NOT NULL; constraints from `pg_get_constraintdef()`; `INHERITS` and `PARTITION BY`; indexes from `pg_get_indexdef()` (not those behind a constraint); triggers from `pg_get_triggerdef()`; table and column comments; and the `CREATE TYPE … AS ENUM` of enum types its columns use. A view is `CREATE OR REPLACE VIEW … AS` around `pg_get_viewdef()`. The sequences behind `serial` columns are left out.
  - SQL Server and other drivers say Runlet doesn't show their definitions. A callable connection is tried as MySQL, then PostgreSQL, then SQLite; a driver that lists tables with `sqlSchema()` over a callable has no catalog to read, and Show Definition says so. Production asks "Read a definition on production?"; read-only connections work. The name reaches the catalog as a bound value on PDO; a callable gets a quoted literal for the dialect tried; `SHOW CREATE` uses quoted identifiers. A definition longer than 2 MB is cut, with a note.
- **Show Relations** (#153) opens in a window of its own and is never saved with the session. If the schema is forgotten while it's open, it offers Load Schema, which asks on production. *2 Hops* adds tables one column further out on the same side. Boxes show the primary key (a key icon), foreign keys (an arrow), and referenced columns with their types, and how many columns they leave out; views carry a VIEW badge. A referenced table that isn't in the loaded schema (another schema or database, or past the 2,000 tables) shows dashed, with only the referenced columns. One line per foreign key, arrow at the referenced table, labelled with the column pairs (`customer_id → id`); a composite key is one line with every pair; a self-reference (`employees.manager_id → employees.id`) loops back on its table's free side. Right-click a table for Browse Table, Open in SQL Tab (its first 50 rows, not run), Show Definition, and Copy Name; right-click a label for Copy Join, Insert Join, and **Copy Reverse Join**. The join adds the table further from the centre, with every pair of a composite key joined by `AND`; a self-reference joins the table again under an alias named after its key (`JOIN employees AS manager ON manager.id = employees.manager_id`); names are quoted for the connection's database. Insert Join goes on a line of its own in the current SQL tab (or the tab the diagram came from). A column holds at most 12 tables; up to 50 related tables all show; past 50, tables one hop away get the room first, shared evenly between the two sides, and the rest of each column collapse into a **+N more** box with a dashed line, which expands on a click. Zoom with the toolbar or a pinch; **Zoom to Fit**. PNG export is at twice the screen's resolution, in the window's appearance; the SVG is made from the layout, with light colours and a dark variant for viewers that follow the system's appearance.
- **The Server section** (#150) reads in a fresh PHP process, like Load Schema and Show Definition (on the target; a saved connection boots nothing; on this Mac for a connection that opens there and for connections of all targets). Server shows the full version text on hover, and the TLS version and cipher or "not encrypted"; SQLite shows its version, the file, and the journal mode. Sizes adds data and index sizes, free space, the number of tables and views, bars for data and indexes, and the engine. Sessions show the session id, database, MySQL's command and state or PostgreSQL's state and application, and the statement's first 4 KB (the whole text on hover, and Copy Statement); a filter field and **Hide idle** narrow the list, and the panel's own session always stays. Read All reads everything again; the Sessions header's ↻ reads only the sessions.

  | Database | Server | Sizes | Sessions |
  | --- | --- | --- | --- |
  | MySQL, MariaDB | `VERSION()`, `DATABASE()`, `CURRENT_USER()`, `SHOW GLOBAL STATUS` (`Uptime`, `Threads_connected`), `SHOW SESSION STATUS` (`Ssl_cipher`) | `information_schema.TABLES` (InnoDB's sizes and rows are estimates; `ANALYZE TABLE` refreshes them) | `information_schema.PROCESSLIST`; open transactions from `INNODB_TRX`, lock waits from `INNODB_LOCK_WAITS` (MariaDB) or `performance_schema.data_lock_waits` (MySQL 8), when readable |
  | PostgreSQL | `version()`, `current_database()`, `current_user`, `pg_postmaster_start_time()`, `pg_stat_ssl` | `pg_database_size()`, and per table `pg_table_size()` (data with TOAST), `pg_indexes_size()`, `pg_total_relation_size()`, `reltuples` | `pg_stat_activity` (client backends; background processes are counted in a note), `pg_blocking_pids()` |
  | SQLite | `sqlite_version()`, `PRAGMA database_list`, `journal_mode` | `page_count × page_size`; per table from the `dbstat` table when SQLite has it, else the file's size only | None: SQLite has no server; the file is opened by the runner's own PHP |

  Without MySQL's `PROCESS` privilege, "You see only your own sessions" (with the number connected in all); without PostgreSQL's `pg_read_all_stats` role, other roles' sessions show without their state and statement; without `CONNECTION ADMIN`/`CONNECTION_ADMIN`/`SUPER` (MySQL, MariaDB) or `pg_signal_backend` (PostgreSQL), "You can cancel and kill only your own sessions". A session's ⋯ menu also has Copy Statement and Copy Session ID. The confirmation names the session's id, user and host, database, state, how long it has run and since about when, its statement, the exact statement Runlet sends, and what it does; ⌘↩ confirms, Esc or **Don't Send** sends nothing. Runlet sends only `KILL QUERY <id>` and `KILL <id>` (MySQL, MariaDB) or `SELECT pg_cancel_backend(<pid>)` and `SELECT pg_terminate_backend(<pid>)` (PostgreSQL). A fresh runner sends it only when it reached the server the list came from (Stop's server fingerprint), the session isn't the one the list was read with nor the runner's own, and it is still the one listed: the same user, and on PostgreSQL, whose process ids are reused, the same start time. The menu disables both actions on the panel's own session, Runlet refuses them with the reason, and the runner refuses them again. A banner reports cancelled or killed (and whether Runlet saw it end), still running after 2 s, already ended, idle (nothing to cancel), refused (with the database's words), or failed; the row is marked KILLED or CANCELLED until the sessions are read again. The tab's Run Log records the action, its statement, and its outcome, never the session's statement text. Read-only connections (#139) may cancel and kill. SQL Server and callable connections aren't supported; WordPress's own PDO connection (#208) has the section. The refresh interval turns itself off when the Server section hides (another section or pane, or the Library closed), the tab or its connection changes, or Runlet goes to the background. Production asks "Read server details on production?" before every read.
- **Import CSV** (#152) also detects `|` as a delimiter; a first row is a header when it names a column of the table, or is text above rows with numbers. RFC 4180 quoting is understood, line breaks inside quotes included, and blank lines are skipped. Columns match ignoring case, spaces, and punctuation; a field missing from a short row is NULL. The preview's statement looks like `INSERT INTO parts (id, name, qty) VALUES (?, ?, ?)`, with the first row's values. Rows are inserted several per `INSERT` (up to 500, and at most 999 placeholders); a savepoint before each statement lets Runlet find the failing row on SQLite, MySQL, MariaDB, and PostgreSQL. MySQL and MariaDB can't roll back tables without transactions (MyISAM). On a read-only connection (#139) the menu item says so before anything is read, and the runner refuses the `INSERT` too. Production asks "Import 1,200 rows into parts on production?" with the file, the statement, and the connection. Stop cancels the statement on the server; nothing is committed. The rows go to the runner inside its request, as batches of JSON data beside the code, on the same standard input as every run; the snippet compiler never parses them, and the runner decodes one batch at a time. The 8 MiB limit keeps the runner under PHP's default 128 MiB `memory_limit` (an 8 MiB file peaks at about 65 MiB), with room for an application that boots first. Run History gets `-- Import CSV: 1,200 rows from parts.csv into parts, in one transaction` and the `INSERT` statement, never the data; the rows aren't output, logged, or sent to MCP clients.
- **The result window** (#21) is titled with the tab (and the statement for Run All) and the row count. =, ≠, <, and > compare as numbers when both sides are numbers, else as text, so ISO dates order correctly; NULL never equals, contains, or compares, but matches ≠, doesn't contain, and is empty. The context menu has Copy Value, Filter: column = value / ≠ value (or is empty), Copy Row (or rows), Copy Row as CSV, and for one row Copy Row as JSON and Copy Row as PHP Array. The grid is the output's (#162). Search, filters, and sorting over loaded pages (#146) are worked out off the main thread, so typing stays quick with 50,000 rows. Closing a window drops its copy of the rows.

### Snippets, History, and Lookup

- SQL snippets (#130) are saved with **Save as Snippet…** as "Save SQL Snippet"; they open as SQL tabs or switch the current tab to SQL, per Settings ▸ General ▸ History & Snippets, and have no `@input`s. History's Save as Snippet, Duplicate, and Copy to Personal keep the language. A personal snippet stores its connection's name and kind (`"connection": {"kind": "saved", "name": "Reporting"}` in `State/snippets.json`); a project snippet gets an `-- @connection reporting` line ([format](project-snippets.md#connections)); nothing else about the connection is written, and the default connection isn't stored. A snippet whose connection doesn't resolve says "The connection “Reporting” from this snippet no longer exists; using the default connection." The Snippets panel shows the connection as a badge, the search matches its name, **Edit…** changes or removes it, and Duplicate and Copy to Personal keep it.
- Run History (#149) stores an application connection's name (or the default connection), or a saved connection's id and its name at the time. Entries recorded before #149 have no connection and behave as before; PHP runs never have one. The row's help says which kind of connection it is. The Connection menu appears when the runs shown (This Project or All Projects) used more than one connection; a saved connection renamed since is one choice, under its newest name; entries without a connection show only under All Connections. Running a statement again on the same connection moves its entry up; an entry from before #149 is replaced by the statement's next run. Open, Open in New Tab, Load in Current Tab, and Open Anything's `!` scope put the tab on the entry's connection, and the tab's marking (production, colour, read-only) follows the connection it ends up on.
- **Lookup:** an application connection keeps its name; Runlet can't check it before a run (the names come from the application's configuration), and an unknown name fails at Run with the driver's message and the list of known connections. A saved connection is found by id when it belongs to the tab's target or to all targets; else by name (ignoring case), the target's own connection first, then one of all targets, the rule workspaces use. Snippets have no id, so they go straight to the name. A bare name from a project snippet (`-- @connection reporting`) is a saved connection with that name, found the same way, else the application's connection with that name. The "no longer exists" note goes away when you choose a connection or close it with ×.
- After a run, the picker shows how each connection that ran this session was opened ("Last run: WordPress (PDO from wp-config)", "Last run: WordPress ($wpdb, because …)", #208). **Other Connection…** stores only the name. The built-in connections: Laravel, Lumen, and Laravel Zero use `DB::connection($name)`'s PDO; Symfony uses the `doctrine` registry's connection (`getConnection($name)`), its PDO when it has one, else statements through DBAL; WordPress opens a PDO connection from `wp-config.php`'s own settings when an SQL feature first needs it (MySQL and MariaDB, or the SQLite Database Integration drop-in's file), else uses `$wpdb->query()` with the reason ([WordPress's connection](drivers.md#wordpress-connection)); the `wpdb` connection always runs through `$wpdb`, and other names are refused. Eloquent through Capsule and `$wpdb` are found even with a project driver that has no `sqlConnection()`. Plain PHP and Composer projects, and Symfony without DoctrineBundle, get **No SQL connection**. A Laravel connection without a PDO (for example MongoDB) is refused with a message. The automated tests use SQLite (see [Validation](#validation)).

### Safety Details

- **Safety details:** sandbox auto-run ([#30](https://github.com/filipac/runlet/issues/30)) is PHP-only: its toggle is hidden on SQL tabs, and switching a tab to SQL turns it off. AI clients' `run_php` runs PHP only; it never reuses a tab that was switched to SQL, and the app refuses to run an SQL tab's text as PHP from any caller. MCP's snippet tools report a snippet's `language`, and `add_snippet` can save an SQL snippet; none of them run anything. For a saved connection, the production sheet names it, where it connects, and that it is opened from the target (or from this Mac, #142, or through an SSH tunnel, #143) rather than through the application; through a tunnel, the SSH profile's marking counts too. Run All's sheet says whether the script runs in a transaction. Write detection treats `PRAGMA` as a read only without `=` and without an argument in parentheses, except the pragmas that read about a table or index, such as `table_info(…)`; `nextval()`, stored procedures, and locks called from a `SELECT` aren't detected.

### Validation

- `SQLTabTests` (RunletCore): tab language decoding and persistence (sessions, workspaces, history), statement splitting and scope, write detection, the generated PHP's escaping of quotes, backslashes, `$`, and control characters, result decoding and summaries, and that SQL ignores the production grace. Run All: the statements of a selection or the tab, transaction statements, implicit commits, and per-statement results.
- `SQLCompletionTests` (RunletCore): keywords without a schema, nothing inside strings, comments, or quoted names, tables after `FROM`/`JOIN`/`UPDATE`/`INTO`, columns of the statement's tables, aliases and `schema.` qualifiers, quoting per driver, only the statement at the caret, and schema decoding.
- `SQLScriptExecutionTests` (RunletExecution, host PHP): Run All in order with a result per statement; commit and rollback on PDO and callable connections; earlier statements kept without a transaction; on PHP 7.4; WordPress `$wpdb`.
- `SQLSchemaExecutionTests` (RunletExecution, host PHP): the schema through a project driver's PDO and callable, a driver's own `sqlSchema()`, Laravel, Eloquent through Capsule, Doctrine DBAL 3 and 4, and WordPress; a run that reads it along; a schema that can't be read never failing the run; the error for a callable without a catalog.
- `SQLResultSetsTests` (RunletCore) and `SQLResultSetsLiveTests` (live MariaDB and PostgreSQL, #154): `resultSet` decoding and titles; a procedure with two `SELECT`s, a `SELECT` and an `UPDATE`, and none; the row cap across results; the results before a failing one; Run All's titles; PostgreSQL's single result.
- `SQLCSVTests` (RunletCore), `SQLCSVExecutionTests` (host PHP, SQLite saved connections), and `SQLCSVLiveTests` (live MariaDB and PostgreSQL, #152): CSV parsing, delimiter and header detection, mapping, bound values and batches, the limits, export lines and the file writer; an export's values and options, a refusal that leaves no file, 100,000 generated rows in frames of at most 1,000 with the runner's memory flat, Stop cancelling an export on the server and deleting its partial file; imports in one transaction, the rollback naming the failing row, empty fields as NULL, read-only refusal, the largest import's memory, and PHP 7.4.
- `SQLSchemaExplorerTests` (RunletCore): the explorer's filter, the queries its actions prepare (per driver, Laravel's query builder with escaping), column and index descriptions, and the result window's search, filter rules (numbers, text, ISO dates, NULL), number-aware sorting with NULLs last, and CSV/TSV of the shown rows.
- `SQLSchemaDetailsTests` (RunletExecution, host PHP): on SQLite through a PDO and a callable, views, primary keys (including a composite one), a foreign key, defaults, NOT NULL, and unique and multi-column indexes; a driver's detailed `sqlSchema()`; and PHP 7.4.
- `HistoryConnectionTests` (RunletCore, #149): history entries and snippets with and without a connection (older JSON, unknown kinds dropped, nothing but names and ids written), the lookup and fallback rules, history merging per connection, the Connection filter's choices, search, and project snippets' `@connection` parse and write round trip.
- `SQLRelationsTests` (RunletCore, #153): relations from named constraints and from columns' `references` alone (a composite primary key's columns as one relation, two keys to one table as two), missing referenced tables and unknown referenced columns, schema-qualified PostgreSQL names (never matched by suffix), graphs one and two hops out, a self-reference, the layered layout (deterministic, no overlaps, key columns or all, wrapped columns), the 50-table threshold, collapsed groups and expanding one, Copy Join per driver (quoting, composite keys, self-join aliases, Oracle's alias without `AS`), and the SVG export as well-formed XML with escaped names.
- `SQLSchemaDetailsTests` and `SQLRelationsLiveTests` (RunletExecution, #153): each table's foreign key constraints on SQLite through a PDO and a callable (a composite key, a self-reference, `REFERENCES t` without a column), none from a driver's `sqlSchema()`, and on MariaDB 11 and PostgreSQL 14 in `p153_` tables (a composite key in the key's order, a key to a unique column, two keys to one table), with the graph and the composite join built from them.
- The Debug app, with a scratch SQLite file through a saved connection (`scripts/relations-diagram-screenshots.py`): the explorer row's menu, the diagram centred on a table (one and two hops), re-centred on a composite key and a self-reference, Back and Forward, a key's menu, Copy Join (the clipboard put back), Insert Join into the SQL tab, dark mode with all columns, 56 referencing tables collapsed past 50 and expanded, and both exports. Screenshots are in [PR #199](https://github.com/filipac/runlet/pull/199).
- `SQLDefinitionDocumentTests` (RunletCore, #148): Show Definition's generated PHP and its escaping, the tab's title, the header (server, how, connection, time, notes, "Not run"), wrapping, and the event's decoding.
- `SQLDefinitionTests` (RunletExecution, host PHP, #148): on SQLite through a PDO and a callable, a table with a foreign key, a check, two indexes, and a trigger, and a view; nothing changed; an unknown name, also with quotes in it; a driver's `sqlSchema()` over a callable refused; a saved SQLite connection running no project code; a connection of all targets reading from this Mac, in Runlet's empty folder, and refused on a container, a server, and the project's directory; the PostgreSQL reconstruction from catalog rows recorded on PostgreSQL 14 (and from rows for a partitioned, unlogged table with identity and generated columns, a partition, a foreign table with parents and a trigger, quotes and backslashes in comments and enum labels, a view with options and comments, and a materialized view with an index); PHP 7.4.
- `SQLDefinitionLiveTests` (live servers, #148): on MariaDB 11 and PostgreSQL 14, in `p148_` tables, an enum, and a view created by the test, `SHOW CREATE TABLE` with its keys, foreign key, check, comment, and trigger, `SHOW CREATE VIEW`, the reconstructed PostgreSQL table, a `serial` table and the view, nothing changed, read-only saved connections, and a read-only connection of all targets opened from this Mac.
- `SQLTableBrowseTests` and `SQLTableEditsTests` (RunletCore, #151): Browse Table's page SQL per dialect (quoting with the quote doubled, `schema.table`, paging, the primary key's order and a sort's tie-breaker, SQL Server's `ORDER BY (SELECT NULL)`), filters per operator and column type with typed bound values (an injection attempt stays a value, LIKE's wildcards escaped), refusals (unknown columns, unsupported operators, values that don't fit, a callable's values), column types from type names; who may edit (views, no primary key, read-only and callable connections, binary keys, a key past 200 columns), pending changes, the UPDATE/INSERT/DELETE statements with the optimistic check and MySQL's count, NULL and NOT NULL, composite keys, Run History's script, and the generated PHP.
- `SQLTableBrowseExecutionTests` (RunletExecution, host PHP, SQLite, #151): pages with one row more, sort and filters on the server, values that stay data, the runner refusing anything but a SELECT for its dialect, a callable browsing without values, changes applied in one transaction (each affecting one row), a row changed or deleted by another session and a failing change rolling everything back, other kinds and callable connections refused, and a read-only saved connection browsing but never applying.
- `SQLTableBrowseLiveTests` (live servers, #151): on MariaDB 11 and PostgreSQL 14, in a `p151_items` table created by the test and read through the schema, pages, a sort, typed filters (`ILIKE` ignoring case), edits, a NULL, an insertion taking the key's default, and a deletion in one transaction (MariaDB's unchanged UPDATE told apart by its count), a row another session changed or deleted rolling back, and a read-only saved connection refusing Apply.
- The Debug app, with a scratch SQLite catalog through saved connections (`scripts/table-browser-screenshots.py`): a filtered, sorted second page; edits marked in the grid (light and dark); Edit Value refusing a value; Review Changes; Apply and the page read again; a rollback after another tab changed a row; a table without a primary key and a read-only connection; and the production question before Apply, cancelled.
- `SQLServerPanelTests` (RunletCore, #150): the `sqlServer` report's decoding, merging a sessions-only refresh (the list's own session and server fingerprint come from the read that listed it), the statements per database (none for SQLite and SQL Server), the refusals (the panel's own session, by flag and by id; no server fingerprint; Cancel on an idle session), plans with the listed user and PostgreSQL's backend start, the generated PHP's escaping, no refresh on production, sizes, durations and counts, the confirmation's texts, and every action outcome's message and Run Log line.
- `SQLServerPanelRunnerTests` (RunletExecution, host PHP, #150): SQLite's overview and sizes (`dbstat`, or the file's size with a note) and no sessions, parts read apart, a callable refused, a saved SQLite connection running no project code, an action on SQLite and a statement that isn't Runlet's own refused with nothing changed, and PHP 7.4.
- `SQLServerPanelLiveTests` (live servers, #150): on MariaDB 11 and PostgreSQL 14, the overview and sizes including the test's own `p150_orders` (data, indexes, estimated rows, largest first); a session list with the test's own victim (`SLEEP(30)`/`pg_sleep(30)` marked with a unique id) and the panel's own session; Cancel Query and Kill Session of the victim, verified gone on the server and seen by its client; the runner's refusals of the panel's own session, another server's fingerprint, a stale row (another user, another backend start), and a foreign statement, with the victim still running; a read-only saved connection reading and killing, with no password in any report; and the `p150_limited` user, who sees only its own sessions (MariaDB) or others' without statements (PostgreSQL), and whose kill of another user's session the server refuses. Every cancel and kill targets only the test's own sessions.
- The Debug app, with the fixture MariaDB 11 and PostgreSQL 14 through saved connections (passwords in memory) and the script's own marked sessions (`scripts/server-panel-screenshots.py`): the Server section before and after a read, the sessions filtered to `p150` with a lock wait, Kill Session's confirmation and result (the Run Log lines), Cancel Query declined, a refresh interval that stops when the section hides, the production question with no refresh, PostgreSQL in dark mode, a role without `pg_signal_backend` refused by the server, a user without `PROCESS`, and the panel's own session refused. Screenshots are in [PR #178](https://github.com/filipac/runlet/pull/178).
- The Debug app, with a scratch SQLite file and the fixture PostgreSQL 14 through saved connections (passwords in memory): a table row's menu items, Show Definition's sheet for an SQLite table (Copy, with the clipboard put back) and view (resized to below its minimum, then Open in SQL Tab with the output pane hidden), and the production question and sheet for a PostgreSQL table (light and dark) (`scripts/sql-definition-screenshots.py`, which also checks the sheet's state, that no tab opens by itself, what was read, and that nothing changed). Screenshots are in [PR #173](https://github.com/filipac/runlet/pull/173).
- `SQLLiveDatabaseTests` (RunletExecution, live servers): MariaDB 11 and PostgreSQL 14 in throwaway fixture containers (`scripts/setup-fixtures.sh databases`, which prints `RUNLET_TEST_MYSQL` and `RUNLET_TEST_PGSQL`). It checks the schema details (keys, foreign keys, indexes, views, defaults, and row estimates), a statement with its schema, MariaDB's implicit commit in Run All (the notice, and only the statements after it rolled back), and PostgreSQL rolling back DDL with the rest. These tests skip without the variables.
- `SQLParameterTests` (RunletCore, #145): placeholders found and not found (strings, comments, quoted names, dollar quotes, `::`, `:=`, `??`, `???`, MySQL's backslash escapes, PostgreSQL's `#`), mixed kinds, `$1`, and unbindable names refused; Run All sharing names and numbering each statement's `?`s; `@param` presets and unreadable lines; the drafts' types and validation, and the rows' prefill order (#168); remembered values; history text that presets the drawer again; and the generated PHP holding the values as data. SQL Server's `#temp` tables and custom DSNs don't hide placeholders after a `#`.
- `SQLParameterDrawerTests` (RunletCore, #168): the drawer's rows following the caret and the selection and hiding without placeholders; `-- @param` presets that follow the comment until a value is set; values kept when placeholders go away and come back, across statements, for `?`s while their statement is edited (also right after the caret moved there), and for a renamed `:name`; All Statements sharing values with the statement view and naming statements; problems and the driver's reading; writing values as `-- @param` lines (new lines, a rewritten line, `?`s in their own statement also after a statement on the same line, a block comment left alone); the run reading the drawer's memory; and statement lines counted once, so a tab of 4,000 statements updates in milliseconds.
- `SQLParameterExecutionTests` (RunletExecution, host PHP, SQLite, #145): named and positional placeholders with every type and NULL; a text value that looks like SQL staying data; Run All sharing a name in one transaction; callable connections refusing a statement and a whole script before anything runs; a read-only saved connection refusing a write with values and running a read; PHP 7.4.
- `SQLParameterLiveTests` (live servers, #145): on MariaDB 11 and PostgreSQL 14, in a `p145_items` table created by the test, every type through `:name` and `?`, decimals compared exactly, Run All with a shared name committing and a failing script rolling back what its values wrote, MySQL refusing a repeated name while PostgreSQL binds it, PostgreSQL's `??|` and `??` operators beside a placeholder, and a saved connection binding too.
- The Debug app, with a scratch copy of the `custom-driver` fixture: the drawer for `:name` placeholders (light and dark), Write as @param Comments (and one Undo step, on an editor of its own), collapsed, following the caret to `?` placeholders, Run with a missing value focusing the field, typing it, Tab and ⇧Tab, ↩ running from the drawer, Esc back to the editor, All Statements with a `-- @param` preset and Run All stopping at a missing value (dark), and the production confirmation listing the values for a production saved connection (`scripts/sql-parameter-screenshots.py`, which also checks the drawer's state, the keyboard, and the Run History entries). `sql-params:timing` measured a drawer update on a 189 KB tab of 4,000 statements at 34 ms in a Debug build. Screenshots are in [PR #166](https://github.com/filipac/runlet/pull/166) (the values sheet it replaced) and [PR #169](https://github.com/filipac/runlet/pull/169).
- `SQLPlanTests` (RunletCore, #147): plan trees from EXPLAIN output recorded on the fixture MariaDB 11 (`FORMAT=JSON`: a full scan, a join under a filesort, a union with a materialized subquery, a DELETE, "No tables used", and `ANALYZE FORMAT=JSON`), PostgreSQL 14 (`FORMAT JSON`, plain and `ANALYZE`, a DELETE), and SQLite 3.45 (`EXPLAIN QUERY PLAN` rows, nested, covering indexes, and the pre-3.36 wording); MySQL 8 samples in its documented formats (JSON with string costs and ordering/grouping wrappers, a union, JSON version 2, and `EXPLAIN ANALYZE`'s text tree); full scans; the event's decoding, Raw text, and copy text; the generated PHP; and the refusals and warnings made before anything is sent.
- `SQLExplainExecutionTests` (RunletExecution, host PHP, SQLite, #147): a plan through a project driver's PDO; plain Explain of `DELETE`, `UPDATE`, `INSERT`, and `DROP TABLE` changing nothing; a second statement after `;` never running; an index lookup that isn't a full scan; no project code for a saved connection; Explain Analyze refused on SQLite; `EXPLAIN`/`ANALYZE` statements and callables refused; a read-only connection explaining a write and refusing Explain Analyze of it; bound values; PHP 7.4.
- `SQLExplainLiveTests` (live servers, #147): on MariaDB 11 and PostgreSQL 14, in `p147_` tables created by the test, plan trees from JSON with full scans and an index lookup, plain Explain of writes changing nothing, a second statement refused, Explain Analyze of a read with actual rows, of a DELETE rolled back on PostgreSQL and refused on MariaDB, and a read-only saved connection (MariaDB's error 1792 for a write's plain Explain).
- The Debug app, with a scratch SQLite file and the fixture PostgreSQL 14 through saved connections (passwords in memory): the SQLite tree, the PostgreSQL tree with two full scans (light and dark), Raw, Explain Analyze rolled back, and the question for Explain Analyze of a DELETE (`scripts/sql-explain-screenshots.py`, which also checks nothing was deleted). Screenshots are in [PR #167](https://github.com/filipac/runlet/pull/167).
- `SQLPagingTests` (RunletCore, #146): writes, locking reads, `SHOW`/`DESCRIBE`/`EXPLAIN`/`PRAGMA`, and unclassified statements refused; plain reads, CTEs, unions, and placeholders paging; the added `LIMIT … OFFSET …` per dialect (one extra row, on a line of its own after a trailing comment); `ORDER BY` and `LIMIT` read only at the top level (not in a CTE, a subquery, or a window); statements with their own `LIMIT`/`OFFSET`/`FETCH`/`TOP`, SQL Server without `ORDER BY` or with `FOR JSON`, callables, and other drivers skipped by the runner; SQL Server's `OFFSET … FETCH`; the generated PHP; a page appended to a result (only its rows added to the table, the same table as one result of every row, the summary, the timing, bytes, and pages); a page with other columns refused; the row, cell, and byte limits; the Rows per page setting.
- `SQLPagingExecutionTests` (RunletExecution, host PHP, SQLite, #146): pages the database skips appended to the end in order; a statement with its own LIMIT and a callable connection skipped by the runner; named and positional values bound again for every page; a page written for another driver and a refused clause failing with the runner's message; a read-only saved connection paging a read and refusing a write; PHP 7.4.
- `SQLPagingLiveTests` (live servers, #146): on MariaDB 11 and PostgreSQL 14, in a `p146_readings` table of 2,500 rows created by the test, `ORDER BY id DESC` across three pages to the end, a CTE, a join with two `id` columns, bound values across pages, a statement with its own `LIMIT`, and a read-only saved connection paging and refusing a write.
- The Debug app, with a scratch SQLite file through saved connections (`scripts/sql-paging-screenshots.py`, which also checks the pages, Run History's entries, and that an `UPDATE … RETURNING` ran once): a capped result with Load Next, the next page where it starts (light and dark), the end of the result, the result window filtered across every loaded row, a larger page size, a write's cut result without Load Next, and the production confirmation for a page (cancelled). With 60,000 rows of 6 columns and 10,000 rows per page, appending a page stalled the main thread at most 22–36 ms (`wait-page`'s `lagMax`), scrolling 50,000 rows took 2.6 ms per step on average (`scroll-check`), typing in the result window's search over 50,000 rows at most 14 ms (it took 230 ms per update when the window filtered on the main thread), and memory grew about 28 MB per 10,000 rows. Numbers and screenshots are in [PR #172](https://github.com/filipac/runlet/pull/172).
- `SQLCancelTests` and `SQLCancelInterruptionTests` (RunletCore, #144): the cancel statement per dialect (none for SQLite and other drivers), the second runner's PHP, the `sqlSession` and `sqlCancel` events' decoding, every outcome's message with Run All's transaction, and which errors count as the database's answer to Stop (MySQL/MariaDB 1317, PostgreSQL 57014 "due to user request"; not a statement timeout, `max_execution_time`, another dialect's error, or SQL Server) with the "Interrupted by Stop" line, also for Run All and Load Next's wrappers. `SQLCancelControlTests` (RunletExecution): the error is held while the cancel runs and marked only when the server took it.
- `SQLCancelExecutionTests` (RunletExecution, host PHP, #144): SQLite (an application and a saved connection) reporting no session, so Stop ends the runner as before; the second runner refusing a connection of another kind; a second runner that hangs, stopped after 8 s with the run; PHP 7.4. `SQLCancelDockerTests` and `SQLCancelSSHTests`: the second runner runs in the same container and on the same SSH server.
- `SQLCancelLiveTests` (live servers, #144): on MariaDB 11 and PostgreSQL 14, `SELECT SLEEP(30)` / `SELECT pg_sleep(30)` stopped within a few seconds, gone from `information_schema.PROCESSLIST` / `pg_stat_activity`, and its error marked as interrupted by Stop (while another session's `KILL QUERY` / `pg_cancel_backend` keeps the error card), through an application connection, a saved one, and a read-only saved one; Run All in a transaction rolled back; a Load Next page and Explain Analyze; the checks (a gone session, an idle one, a statement that isn't the cancel, another server's fingerprint); a user who may not cancel another user's session (MariaDB's error 1095, PostgreSQL's other-user check) leaving the statement running; and, as a control, MariaDB still running the statement of a client process that was only killed. Every process these tests start (host PHP for `Server.exec`, the process-list checks, the session holders, the control's client) goes through `TestProcess`, which learns of the exit from `terminationHandler`, never `waitUntilExit()`, and has a deadline: a stall fails the test with a timeout naming the step, and a process that overstays gets SIGTERM, then SIGKILL (#182).
- `ProjectSnippetsTests`, `PersistenceTests`, and `MCPToolArgumentTests` (RunletCore): SQL snippets' metadata comments, listing, saving, and file names; personal snippets' language decoding (old libraries load as PHP); `add_snippet`'s `language`.
- `SQLTabExecutionTests` (RunletExecution, host PHP): a project driver's PDO and callable connections, names and errors (`custom-driver`); the driver's method winning over the built-in Laravel connection (`custom-laravel-driver`); Laravel connections, named connections, unknown names, and database errors (`laravel-app`, in a scratch copy); Eloquent through Capsule found without a driver method (`eloquent-app`); Doctrine DBAL 3 and 4 through `SqlConnections::doctrine()`; WordPress's own PDO on the SQLite drop-in and `$wpdb` as the `wpdb` connection; the row cap, binary and long cells; the refusal on plain, Composer, and Symfony-without-Doctrine projects; and a run on Herd's PHP 7.4.
- `WordPressPDOTests` (RunletExecution, host PHP, [#208](https://github.com/filipac/runlet/issues/208)): `DB_HOST` read as WordPress's own `wpdb::parse_db_host()` reads it (compared with the fixture's `class-wpdb.php` for `host`, `host:port`, `host:/socket`, `:/socket`, `[::1]`, `[::1]:port`, a bare IPv6 address, and malformed forms); the DSN mysqli would use for each (mysqli's default socket for `localhost`, the socket ignored for a remote host, IPv6 in brackets, no charset without `DB_CHARSET`); TLS from `MYSQL_CLIENT_FLAGS` (`MYSQLI_CLIENT_SSL`, `_DONT_VERIFY_SERVER_CERT`, `_VERIFY_SERVER_CERT`, `_COMPRESS`) and `MYSQL_SSL_CA` / `_CAPATH` / `_CERT` / `_KEY` / `_CIPHER`; every fallback's reason (`RUNLET_WPDB_ONLY`, HyperDB, LudicrousDB on a multisite, an unknown `$wpdb` class, Query Monitor's drop-in accepted, a missing `pdo_mysql` or `pdo_sqlite` simulated, `$wpdb` on another `DB_HOST`, missing constants, values a DSN can't hold, an unreadable CA); the SQLite drop-in's file (`FQDB`, `DB_ENGINE`), PHP 7.4. On the WordPress fixture: the default connection through PDO and `wpdb` through `$wpdb`; in a clone with a `p208_items` table, bound values, Load Schema, Browse Table with value filters and edits, Import CSV, Explain with a bound value, Load Next paged by the database, Run All committed and rolled back, and Show Definition; `RUNLET_WPDB_ONLY` keeping `$wpdb`, its refusals, and the app's MySQL dialect for it.
- `WordPressPDOLiveTests` (live MariaDB 11, #208): a clone of the WordPress fixture without the SQLite drop-in, installed with `wp_install()` into `p208_wp` as the `p208_wp` user (mail stopped): the same features through PDO, plus the Database pane's Server section and Stop's `KILL QUERY`; a session with `$wpdb`'s charset, collation, and sql_mode; `DB_HOST` as `[::1]:port` through a forwarder on IPv6 loopback; TLS from `MYSQLI_CLIENT_SSL`, verified with the fixture CA as `MYSQL_SSL_CA`, and the other CA falling back to `$wpdb` with PDO's reason; an unknown drop-in, a `DB_PASSWORD` PDO is refused with (while the drop-in's `$wpdb` connects), and `RUNLET_WPDB_ONLY` falling back; and the raw output of 21 runs (results, errors, Explain, the Server section, the schema, a snippet's exception, a bootstrap that fails) holding neither password, with a message that repeats `DB_PASSWORD` showing `•••`. A socket `DB_HOST` has no fixture and is covered by `WordPressPDOTests`.
- The Debug app, with scratch data and two WordPress sites on the fixture MariaDB (#208): a result "via WordPress (PDO from wp-config)", the picker's "Last run" line, a statement with two bound values, Browse Table with two edits and Review Changes, and a site whose custom `db.php` drop-in keeps `$wpdb`, with the reason under its result and in the picker. Screenshots are in [PR #211](https://github.com/filipac/runlet/pull/211).
- The Debug app, with scratch data: a sandbox SQL tab running `INSERT`, `SELECT`, and `UPDATE`; the production confirmation on a never-connected production SSH profile; the unknown-connection and no-connection messages; a `.sql` file opened without running; the several-statements refusal. Screenshots are in [PR #120](https://github.com/filipac/runlet/pull/120).
- The Debug app, with a scratch SQLite project: Run All committing three statements, a failing script rolled back, completion of an alias's columns from the schema a run read, the production confirmations for Run All and Load Schema, SQL snippets in the Snippets panel, and Save SQL Snippet. Screenshots are in [PR #131](https://github.com/filipac/runlet/pull/131).
- The Debug app, with a scratch SQLite project: the Database pane before loading, after a run, filtered by a column name, and an explorer table opened in a new SQL tab. Then that result in a result window with two filter rules and a sort, in light and dark. Screenshots are in [PR #134](https://github.com/filipac/runlet/pull/134).
- Saved connections (from the target, from this Mac, and through SSH tunnels), read-only connections, connection options, and the TablePlus import have their tests listed under [Connections](connections.md#validation).

- `SQLTabTests` and `OutputTableLayoutTests` (RunletCore), `RunTimingTests.sqlResultsArriveWithTheirTable` (RunletExecution) ([#162](https://github.com/filipac/runlet/issues/162)): a result's table is built once, where its event is decoded (off the main thread), rebuilt only when its rows change, and never encoded; the largest result (1,000 rows × 200 columns) decodes with its table on a task of its own; an `sql` event read by `RunSession` arrives with its table; the grid's height and which scrolls go to the output.
- The Debug app, with a scratch SQLite project (#162): main-thread stalls (`RUNLET_DEBUG_TIMING`'s `longest` and `lagMax`) and scrolling (`scroll-check`) for results of 50, 333, and 1,000 rows and 1,000 rows × 31 columns, before and after the grid; a slow recursive CTE with tab switches while it runs; the card's filter and sort (`table-filter`, `table-sort`, `table-state`); a PHP collection's Table view. Numbers and screenshots are in [PR #163](https://github.com/filipac/runlet/pull/163).

MariaDB 11 and PostgreSQL 14 were exercised live by `SQLLiveDatabaseTests` and `SQLLiveTLSTests`. MySQL 8 itself and SQL Server were not run: MySQL uses the same `information_schema` queries as MariaDB, and SQL Server's catalog query follows its documented `INFORMATION_SCHEMA`.
