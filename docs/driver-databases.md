# Database Hooks

SQL, Redis, and MongoDB tabs use your application's own connections by default, so Runlet needs no credentials from you. It boots the project with its driver, as for a run, and asks the driver for the connection. The built-in Laravel, Symfony, and WordPress drivers answer by themselves; a project driver answers with the hooks on this page. Dry Run asks the driver which connections to roll back.

A connection you [save yourself](connections.md#saved-connections) opens with Runlet's own client instead: it boots none of your project's code and calls none of these hooks.

## SQL Connections

```php
/** @return \PDO|callable|null */
public function sqlConnection(?string $connection)

/** @return string[] */
public function sqlConnections(): array
```

`sqlConnections()` lists the connection names for an SQL tab's picker, the default first. `sqlConnection()` gets the name chosen in the tab, or `null` for the default, and returns one of:

| Return | What Runlet does |
| --- | --- |
| A `\PDO` | Prepares the statement on it and executes it. A result set becomes the table; otherwise `rowCount()` is the affected-row count. |
| A callable `function (string $sql)` | Calls it with the statement. Return the rows (an iterable of associative arrays or objects; a generator is read only up to the row limit), or, for a statement without a result set, the number of affected rows as an `int`. Columns come from the rows' keys, so an empty result has no columns. Use it for a client without PDO. |
| `null` | No connection from this driver. Runlet then uses an Eloquent connection (Laravel, or illuminate/database through Capsule) or `$wpdb` that the application set up, and otherwise stops with a "No SQL connection" message. |

Here's a driver with both kinds:

```php
<?php
// .runlet/AcmeApiDriver.php
class AcmeApiDriver extends \Runlet\Driver
{
    // canBootstrap(), bootstrap(), variables() as in Writing a Project Driver.

    public function sqlConnection(?string $connection)
    {
        $database = DI::get(App::class)->database(); // the app's own PDO
        switch ($connection ?? 'main') {
            case 'main':
                return $database;
            case 'archive':
                // A client without PDO: run the statement, return rows or affected rows.
                return static function (string $sql) use ($database) {
                    $statement = $database->query($sql);

                    return $statement->columnCount() > 0 ? $statement->fetchAll(\PDO::FETCH_ASSOC) : $statement->rowCount();
                };
            default:
                throw new \InvalidArgumentException('Acme has no "' . $connection . '" database.');
        }
    }

    public function sqlConnections(): array
    {
        return ['main', 'archive'];
    }
}
```

A driver that extends a built-in one can hand the names it doesn't handle to the parent:

```php
public function sqlConnection(?string $connection)
{
    if ($connection !== null) {
        return parent::sqlConnection($connection); // Laravel's named connections
    }

    return $this->tenantDatabase(); // the tenant's own PDO as the default
}
```

- **Order.** The booted driver's `sqlConnection()` comes first, so a project driver that defines it wins over everything else. A driver without the method, or one that returns `null`, falls back to the detected Eloquent connection or `$wpdb`.
- **Errors.** Throw to report a problem, such as an unknown connection name: the SQL tab shows the message. A project driver's error names the file and method, as during boot (`Runlet driver AcmeApiDriver (.runlet/AcmeApiDriver.php) failed in sqlConnection(): …`). Returning anything other than a PDO, a callable, or `null` is an error. If `sqlConnections()` throws, the run goes on without names and shows a notice.
- **When they run.** Both methods run only for SQL tabs, never for PHP runs or command listings. Results are bounded: 1,000 rows (or the rows-per-page setting), 200 columns, 8 KiB per cell, and 8 MiB per result.
- **Run All Statements** calls `sqlConnection()` once and runs every statement on what it returns. In a transaction, a PDO gets `beginTransaction()`, `commit()`, and `rollBack()`; a callable gets `BEGIN`, `COMMIT`, and `ROLLBACK` as statements, so use a callable for a database without them with **In a Transaction** off.

### Built-in Drivers

| Driver | `sqlConnection()` | `sqlConnections()` |
| --- | --- | --- |
| Laravel | The PDO of `DB::connection($connection)` (on Lumen, when the database is set up). A connection without a PDO is refused. | The keys of `config('database.connections')`, `database.default` first |
| Symfony | The `doctrine` registry's `getConnection($connection)`: its PDO, else statements through DBAL. `null` without DoctrineBundle. | The registry's connection names, the default first |
| WordPress | A PDO opened from `wp-config.php`'s own settings when an SQL feature first needs it, else `$wpdb->query()`, with the reason ([WordPress Connection](#wordpress-connection)). The `wpdb` connection always runs through `$wpdb`; other names are refused, since WordPress has one database. | None |
| Composer, plain PHP | `null` | None |

### Helpers

`Runlet\SqlConnections` builds these results for your own driver:

- `SqlConnections::eloquent($database, ?string $connection = null): \PDO` takes a `DatabaseManager`, a Capsule manager, a connection resolver, or a `Connection`.
- `SqlConnections::doctrine($connection)` takes a DBAL 2, 3, or 4 connection, and returns its PDO when it has one, else a callable through `executeQuery()`.
- `SqlConnections::wpdb($wpdb): callable` runs the statement with `$wpdb->query()`, and returns `$wpdb->last_result` or the affected rows.

## WordPress Connection

The WordPress driver gives SQL tabs a real PDO connection, opened with the site's own settings, as Laravel's connection uses its `.env`. Runlet reads them inside the target's PHP after WordPress booted: it never asks for, sees, or stores them.

The connection opens only when an SQL feature needs it (a statement, Load Schema, Browse Table, Import CSV, Explain, Show Definition, the Server section, Stop's cancel), never while WordPress boots, and once per run. With it, WordPress gets what a callable can't offer: bound values, Browse Table with filters and edits, Import CSV, Explain, Load Next paged by the database, Run All with PDO transactions, Show Definition, and on MySQL and MariaDB, the Server section and Stop cancelling the statement on the server.

- **MySQL and MariaDB** (`$wpdb` is WordPress's `wpdb`, or Query Monitor's `QM_DB`): `pdo_mysql` with `DB_NAME`, `DB_USER`, `DB_PASSWORD`, and `DB_HOST`, read the way WordPress reads it: `host`, `host:port`, `host:/path/to.sock`, `:/path/to.sock`, `[::1]`, and `[::1]:3306`. As with mysqli, `localhost` (or no host) goes through the socket. The session gets `$wpdb`'s charset and collation, and the server's `sql_mode` without the modes `wpdb` removes, so writes behave as they do in WordPress.
- **TLS.** `MYSQL_CLIENT_FLAGS` with `MYSQLI_CLIENT_SSL`, or any of the `MYSQL_SSL_CA`, `MYSQL_SSL_CAPATH`, `MYSQL_SSL_CERT`, `MYSQL_SSL_KEY`, and `MYSQL_SSL_CIPHER` constants hosts define, turn TLS on. The server's certificate is checked as mysqlnd does, and a session that isn't encrypted is refused. `MYSQLI_CLIENT_COMPRESS` compresses.
- **The SQLite Database Integration drop-in** (a `db.php` whose `$wpdb` is `WP_SQLite_DB`, or `DB_ENGINE` set to `sqlite`): `pdo_sqlite` on its file, with foreign keys on, as the drop-in opens it. Statements are SQLite's, not the MySQL that `$wpdb` translates; the schema lists the drop-in's own `_wp_sqlite_*` tables too, and tables created through PDO aren't in the drop-in's MySQL catalog. Choose the `wpdb` connection for MySQL syntax.

**Falling back.** When Runlet can't open the PDO, statements run through `$wpdb->query()`, and results, the Run Log, and the connection picker say why: "WordPress ($wpdb, because …)". The reasons:

- `RUNLET_WPDB_ONLY` is defined and true in `wp-config.php`: Runlet doesn't try PDO.
- A `db.php` drop-in Runlet doesn't recognise replaces `wpdb` (HyperDB, LudicrousDB, Multi-DB, SharDB, or your own class): it may route queries to other servers or, on a multisite, split the databases.
- `$wpdb` connected with another `DB_NAME`, `DB_HOST`, or `DB_USER` than `wp-config.php` defines.
- The PHP has no `pdo_mysql` (or no `pdo_sqlite` for the SQLite drop-in), or the drop-in's file doesn't exist.
- The constants aren't text, hold what a DSN can't (`;` in `DB_NAME`), or name a TLS file that can't be read.
- PDO can't connect while `$wpdb` did (a CA mysqli never checks, a password only the drop-in knows), or the session can't be set up like `$wpdb`'s. The reason quotes PDO's message.

The `wpdb` connection (**Other Connection… ▸ wpdb**) always runs through `$wpdb`. A project driver that extends the WordPress driver can return `SqlConnections::wpdb($GLOBALS['wpdb'])` from `sqlConnection()` to do the same for every tab.

> [!NOTE]
> The database password never leaves PHP: Runlet replaces it with `•••` in every error, notice, and Run Log line, and nothing of it reaches the app, Run History, or AI clients. Query results are your site's data and aren't changed, as in its PHP tabs.

## Schema for Completion

SQL completion and the schema explorer need the connection's tables and columns. Runlet reads them through `sqlConnection()`, from the database's catalog: `information_schema` on MySQL, MariaDB, PostgreSQL, and SQL Server, and `sqlite_master` on SQLite (a callable is tried with each in turn). When your connection can't answer those queries, such as an API or a callable over another client, return the schema yourself:

```php
public function sqlSchema(?string $connection): ?array
{
    return [
        'invoices' => ['id' => 'uuid', 'amount' => 'money'], // column => type
        'tags' => ['name'],                                   // or just the names
    ];
}
```

For the schema explorer's details, describe a table in full instead: `columns` (name => type, or name => details: `type`, `nullable`, `default`, `primaryKey`, and `references` as `table.column`), `indexes` (`name`, `columns`, `unique`, `primary`), `rows` (an estimate), and `kind` (`view`). Both forms can be mixed:

```php
public function sqlSchema(?string $connection): ?array
{
    return [
        'invoices' => [
            'columns' => [
                'id' => ['type' => 'uuid', 'nullable' => false, 'primaryKey' => true],
                'customer' => ['type' => 'uuid', 'references' => 'customers.id'],
                'note' => 'text',
            ],
            'indexes' => [['name' => 'invoices_customer', 'columns' => ['customer']]],
            'rows' => 1200,
        ],
        'open_invoices' => ['columns' => ['id' => 'uuid'], 'kind' => 'view'],
        'tags' => ['name'],
    ];
}
```

- Return `null` (the default) to let Runlet read the catalog. It then also reads nullability, defaults, primary keys, indexes, and foreign keys on MySQL, MariaDB, PostgreSQL, and SQLite ([schema explorer](sql-tabs.md#schema-explorer)). If those can't be read, the tables and columns still load, with a note.
- The relations diagram draws a declared `references` as one key per column, except that columns which together reference a table's whole composite primary key are one key.
- With `sqlSchema()` overridden and a callable from `sqlConnection()`, the explorer's **Show Definition** says there is no catalog to read a definition from.
- `sqlSchema()` runs only when you load the schema (from the SQL bar or the Database pane), or after a statement ran in an SQL tab (on production, never without your confirmation). Its errors show in the SQL bar's schema menu and the Database pane, and never fail a run.

## Redis Connections

[Redis tabs](redis.md) send commands through the application's own Redis connection the same way:

```php
/** @return mixed  a phpredis \Redis, a Predis client, a Laravel Redis connection, a callable, or null */
public function redisConnection(?string $connection)

/** @return string[] */
public function redisConnections(): array
```

- `redisConnection()` gets the name chosen in the tab, or `null` for the default. Return a phpredis `\Redis`, a Predis client, a Laravel `Illuminate\Redis\Connections\Connection`, or a callable `function (array $argv)` that sends the command and returns its reply as PHP values (`null` for nil, ints, strings, arrays). Return `null` when the driver has no Redis connection, and Runlet says so. Throw to report a problem, such as an unknown name.
- `redisConnections()` lists the names for the tab's picker, the default first.
- The Laravel driver returns `Redis::connection($connection)`, and the keys of `config('database.redis')` (without `client`, `options`, and `clusters`), `default` first. Commands go out raw, so the connection's prefix and serializer don't apply. A `RedisCluster` connection is refused.

## MongoDB Connections

[MongoDB tabs](mongodb.md) use Laravel MongoDB's connections by default. A project driver can implement `mongoConnection(?string $name)` and return `['manager' => $manager, 'database' => 'your_database']`, where `$manager` is a `MongoDB\Driver\Manager`. The target's PHP needs the `mongodb` extension.

## Rollback Connections

With a tab's [Dry Run](dry-run.md) on, Runlet calls `rollbackConnections()` after `inspect()` and before the snippet, begins a transaction on every connection it returns, and rolls each back when the run ends, whatever ended it. Return a list, or `name => connection`:

| Connection | How Runlet wraps it |
| --- | --- |
| Laravel's or Capsule's `DatabaseManager` (or the Capsule `Manager`) | Every open connection, and every connection opened later during the run (through `Illuminate\Database\Events\ConnectionEstablished`: Laravel 9.49 and later, with an event dispatcher); without that, the open connections and the default one. Each is rolled back to the level it was at before. |
| An `Illuminate\Database\Connection` | `beginTransaction()`, then `rollBack()` to its earlier level. |
| A Doctrine DBAL `Connection` (2, 3, or 4), or a Doctrine connection registry | `beginTransaction()`, then `rollBack()` down to the earlier nesting level. Runlet hooks its queries for counting if `inspect()` didn't. |
| WordPress's `$wpdb` | `START TRANSACTION`, then `ROLLBACK`, through `$wpdb->query()`. |
| A `\PDO` | `beginTransaction()`, then `rollBack()`. Counted only through `watchPdo()` (prepared statements). One already in a transaction stops the run, because Runlet can't nest a transaction on a plain PDO. |

The default finds what `inspect()` finds by itself: the connection resolver Eloquent models use (Laravel's `DatabaseManager`) or Capsule's global instance, and `$wpdb`. The Laravel driver adds the application's `db` manager, and the Symfony driver every connection of the `doctrine` registry by name. Add your own to the default:

```php
public function rollbackConnections(): array
{
    return parent::rollbackConnections() + ['reports' => $this->container->get('reports')];
}
```

`automaticRollbackConnections()` returns that default too, for an override that starts from it.

- **Names.** The key names a Doctrine, `$wpdb`, or PDO connection in the dry run's report; Eloquent connections keep their own names. Runlet matches statements to connections by object, else by name, so give a connection the name its queries are recorded under in `inspect()`.
- **Counting.** Statements are counted through the [run inspector's](driver-inspector.md) hooks, so call the `inspect*()` helpers, or `$inspector->query()` for your own database layer, with the same connection name.
- **Nothing to roll back.** Return `[]` to keep a driver's connections out of dry runs: the card then says there was nothing to roll back.
- **Failures stop the run.** Throwing stops the run before the snippet, with your message and "Rollback mode: nothing ran.": a dry run never runs code it can't wrap. So does a connection whose transaction can't begin; the transactions that did begin are rolled back. A connection that joins later and can't begin throws `Runlet\DryRunRefused` where the snippet opened it, and every later statement on it is refused.
- **Left out.** A Laravel `mongodb` connection, and an object Runlet can't wrap, are left out with a note in the card: they aren't stops.
- **Implicit commits.** MySQL and MariaDB statements that commit implicitly (DDL, `LOCK TABLES`, `START TRANSACTION`, …) are refused before they run where Runlet sees them first: Eloquent connections, Doctrine DBAL connections, and `$wpdb`. The snippet gets `Runlet\DryRunRefused`, and the report a refused warning ([details](dry-run.md#statements-a-dry-run-refuses)). On a plain PDO, and for statements your driver reports through `$inspector->query()`, Runlet sees them only after they ran: it warns, and begins a new transaction on that connection at once, so what follows is still rolled back.

## For developers

SQL tabs were added under [#35](https://github.com/filipac/runlet/issues/35), saved connections under [#138](https://github.com/filipac/runlet/issues/138), Run All Statements under [#129](https://github.com/filipac/runlet/issues/129), SQL completion under [#128](https://github.com/filipac/runlet/issues/128), the schema explorer under [#21](https://github.com/filipac/runlet/issues/21), Show Definition under [#148](https://github.com/filipac/runlet/issues/148), the relations diagram under [#153](https://github.com/filipac/runlet/issues/153), the WordPress connection under [#208](https://github.com/filipac/runlet/issues/208), Redis tabs under [#190](https://github.com/filipac/runlet/issues/190), MongoDB tabs under [#191](https://github.com/filipac/runlet/issues/191), and Dry Run under [#13](https://github.com/filipac/runlet/issues/13). This page was split out of `drivers.md` under [#289](https://github.com/filipac/runlet/issues/289); `drivers.md` keeps short sections with the old anchors.

- The driver methods are in `Resources/Runner/src/Drivers.php` (`SqlConnections` too); the statement runner is `SqlTab.php`, saved connections `SqlConnect.php`, the WordPress connection `WordPressDatabase.php`, the catalog reader `SqlSchema.php`, Redis tabs `RedisTab.php`, MongoDB tabs `MongoTab.php`, and dry runs `Rollback.php`. Built-in drivers implement the SQL methods with the same APIs as [Explain](sql-explain.md).
- **PDO details.** With a `\PDO`, MySQL uses native prepares and unbuffered results for the run; the connection's error mode and those attributes are restored afterwards. A built-in driver's error is wrapped as "Runlet could not open the "…" connection: …" followed by the names `sqlConnections()` lists.
- **phpredis and Predis.** Runlet uses phpredis's `rawCommand()` with `Redis::OPT_REPLY_LITERAL`, so status replies stay text and errors come from `getLastError()`; Predis's `executeRaw()`; and a Laravel connection's `client()`.
- **WordPress connection.** `DB_HOST` is parsed as `wpdb::parse_db_host()` parses it; `localhost` uses `DB_HOST`'s socket, else `mysqli.default_socket`, and a socket after another host is ignored. The session runs `SET NAMES … COLLATE …` and drops `NO_ZERO_DATE`, `ONLY_FULL_GROUP_BY`, `STRICT_TRANS_TABLES`, `STRICT_ALL_TABLES`, `TRADITIONAL`, and `ANSI` from `sql_mode`, through the `incompatible_sql_modes` filter; WordPress sets no session time zone, and neither does Runlet. TLS maps to `PDO::MYSQL_ATTR_SSL_*`; the certificate is checked when `MYSQLI_CLIENT_SSL_VERIFY_SERVER_CERT` is set, or when a CA is given without `MYSQLI_CLIENT_SSL_DONT_VERIFY_SERVER_CERT`. The SQLite drop-in's file is `FQDB`, else `DB_DIR` or `wp-content/database/`, and `DB_FILE` or `.ht.sqlite`. The password is read from `DB_PASSWORD` inside a function that takes no arguments, with `zend.exception_ignore_args` on; PDO's errors are rethrown with their message only, and from then on every error, notice, and Run Log line replaces it (and its URL-encoded and slashed forms) with `•••`.
- **Dry runs.** The connection kinds are wrapped in `Rollback.php`; implicit commits are refused through `Connection::beforeExecuting()` (Eloquent), Runlet's SQL logger (DBAL 2 and 3) or driver middleware (DBAL 4), and `$wpdb`'s `query` filter.

### Runner Protocol

The request has `"rollback": true` for a dry run (snippet runs only: never for commands, App Info, or a saved SQL connection). The runner emits `rollback` events:

- `{"state": "begun", "connections": [{"name", "driver", "api", "status": "open"}], "watching": bool}` once the transactions are open, before the snippet;
- `{"state": "warning", "warning": {"kind", "message", "connection", "sql", "inSnippet", "snippetLine"}}` as soon as something can't be rolled back (`implicitCommit`, `committed`, `rolledBackEarly`, `notWrapped`, `notStarted`), or Runlet refused a statement before it ran (`refused`: the snippet got `Runlet\DryRunRefused`, and nothing was saved). The app reads an unknown kind as its message;
- `{"state": "finished", "reason", "statements", "reads", "connections": [{"name", "driver", "api", "status", "writes", "reads", "saved", "error"?, "commits"?}], "warnings", "notes"?}` after the run, where `status` is `rolledBack`, `committed`, `ended` (the code rolled back early), `lost` (the transaction was gone and Runlet didn't see why), `failed` (Runlet's rollback threw; the database discards the transaction when PHP exits), `notStarted`, or `notWrapped` (statements on a connection outside the dry run), and `statements` counts the statements that could change data whose changes were rolled back.

A run that Stop ends gets no `finished` event; the app reports it.
