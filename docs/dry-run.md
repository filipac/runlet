# Dry Run

**Dry Run** runs a PHP tab inside database transactions that Runlet always rolls back. Try a data fix on real data, look at what it did, and keep nothing. It works on every target: the sandbox, local projects, Docker, and SSH.

```php
use App\Models\Order;

// With Dry Run on, these changes are rolled back when the run ends.
Order::where('status', 'pending')
    ->where('created_at', '<', now()->subMonth())
    ->update(['status' => 'expired']);

Order::where('status', 'expired')->count(); // sees the change
```

> [!WARNING]
> A dry run is a database transaction, not a sandbox. Mail, queued jobs, HTTP calls, files, and caches are real. See [What a Dry Run Doesn't Cover](#what-a-dry-run-doesnt-cover).

## Turning It On

Click **Dry Run** in a PHP tab's toolbar, or choose **Run ▸ Dry Run (Roll Back Database Changes)** (also in the command palette). Turning it on runs nothing.

While it's on:

- the toolbar reads **DRY RUN** in orange;
- a bar above the editor says "Dry run: database changes are rolled back", with **Turn Off**;
- each run's header ends with "dry run: database changes are rolled back".

Dry Run belongs to the tab, and is saved with it in your session and in workspaces. Run, Run Selection, Profile Run, sandbox auto-run, and an AI client's runs in that tab are all dry runs. SQL, Redis, and MongoDB tabs don't have it: an SQL tab's **Run All** has its own **In a Transaction** box.

![A PHP tab with Dry Run on: the orange DRY RUN button, the bar above the editor, and the Dry run card at the end of the output, which rolled back one statement](screenshots/dry-run/dry-run-light.webp#gh-light-mode-only)
![A PHP tab with Dry Run on: the orange DRY RUN button, the bar above the editor, and the Dry run card at the end of the output, which rolled back one statement](screenshots/dry-run/dry-run-dark.webp#gh-dark-mode-only)

## What Happens

1. After the application boots, and before any of the snippet runs, Runlet begins a transaction on every database connection the framework's driver knows ([see below](#which-connections)).
2. The snippet runs as usual, and sees its own changes.
3. When the run ends, however it ends (it returned, threw, called `exit()` or `dd()`, or hit a fatal error), Runlet rolls every transaction back.
4. The output ends with a **Dry run** card, with one line per connection: "Rolled back 3 statements on mysql", or "Nothing to roll back on mysql" when the snippet only read. Statements that could change data are counted apart from reads, and warnings are listed.

Runlet's own `BEGIN` and `ROLLBACK`, savepoints, `SET`, and `USE` aren't counted, and Runlet's own statements stay out of the Queries section. Counting works whether the run inspector is on or off.

**Stop** ends PHP before Runlet can roll back. The database discards the open transaction when the connection closes, so nothing is saved, and the card says "Stopped before Runlet rolled back". A statement still running on the server when you stop may finish first, and holds its locks until it does.

## Which Connections

| Application | Connections in the dry run |
| --- | --- |
| Laravel, Lumen, Laravel Zero | Every connection the database manager has open. On Laravel 9.49 and later, also every connection the snippet opens later, such as `DB::connection('reporting')`. On older versions, the open ones and the default connection. |
| Eloquent without Laravel (Capsule) | The same, through Capsule's database manager. Without an event dispatcher, the open connections and the default one. |
| Symfony | Every connection of the `doctrine` registry. Beginning a transaction connects it. |
| WordPress | `$wpdb` (MySQL, MariaDB, or the SQLite Database Integration drop-in), and the PDO connection SQL tabs open from `wp-config.php`, if something opens it during the run. |
| A project driver | What its [`rollbackConnections()`](driver-databases.md#rollback-connections) returns: Eloquent, Doctrine DBAL, `$wpdb`, or PDO connections. |

A dry run runs nothing on a connection it can't roll back: if a transaction can't begin, the run stops ([see below](#a-transaction-that-cant-begin)). Connections Runlet leaves out on purpose are notes in the card, not stops: MongoDB connections in Laravel (`mongodb/laravel-mongodb`) aren't SQL databases, and an object a driver returns that Runlet can't wrap is skipped.

Laravel's own transactions (`DB::transaction()`, or `beginTransaction()` and `commit()` in the snippet or in the application) become savepoints inside Runlet's transaction, so they're rolled back too. Callbacks that wait for a commit (`DB::afterCommit()`, and jobs and events dispatched "after commit") never run, because nothing commits.

## Statements a Dry Run Refuses

MySQL and MariaDB (and SingleStore) commit the open transaction before and after schema changes and a few other statements: `CREATE`, `ALTER`, `DROP`, `RENAME`, `TRUNCATE`, `LOCK TABLES`, `UNLOCK TABLES`, `GRANT`, `REVOKE`, `ANALYZE`, `OPTIMIZE`, and `REPAIR TABLE`, `FLUSH`, `RESET`, `SET autocommit = 1`, and `START TRANSACTION` or `BEGIN` themselves. That statement, and everything the snippet changed on the connection before it, would be saved.

So where Runlet sees such a statement before it reaches the server, it **refuses** it:

- The statement doesn't run. The snippet gets a `Runlet\DryRunRefused` exception on the line that ran it, shown as an error card that names the statement and the connection, says why, and says to turn off Dry Run to run it.
- Nothing is saved: the run ends (unless the snippet catches the exception), and everything is rolled back as usual.
- The **Dry run** card lists the refused statement, marked with a raised hand.

Where Runlet sees statements first:

| Connection | An implicit commit is |
| --- | --- |
| Laravel and Eloquent (Capsule) connections, on later Laravel 8 releases and every version since | Refused before it runs |
| Doctrine DBAL 2, 3, and 4 (4 needs PHP 8.1 or later) | Refused before it runs |
| WordPress's `$wpdb`; on the SQLite drop-in, `START TRANSACTION` too, since it commits the open transaction there as on MySQL | Refused before it runs |
| A plain PDO (a driver's own, or the WordPress PDO for SQL tabs), older Laravel, and statements a driver reports itself | Warned about after it ran ([see Warnings](#warnings)) |

These still run as usual:

- temporary tables (`CREATE TEMPORARY TABLE`, `DROP TEMPORARY TABLE`), which commit nothing;
- the framework's own transactions (`DB::transaction()`, `DB::beginTransaction()`, Doctrine's `beginTransaction()`), which nest inside Runlet's as savepoints;
- anything on PostgreSQL and SQLite, which roll schema changes back like anything else;
- anything after the code itself committed Runlet's transaction ([see Warnings](#warnings)): it's saved anyway.

> [!NOTE]
> Runlet judges a statement by its first keyword, so several statements sent in one call (`DB::unprepared('INSERT …; ALTER TABLE …')`) are judged by the first.

## A Transaction That Can't Begin

A dry run runs nothing on a connection it can't roll back:

- **Before the snippet.** If a transaction can't begin on a connection (the server is down, or a PDO is already in a transaction), the run stops before any of the snippet runs. The error card names the connection and the database's reason, and ends with "Rollback mode: nothing ran." Transactions that did begin on other connections are rolled back, and the **Dry run** card says "no transaction on" that connection.
- **A connection that joins later,** such as Laravel's `DB::connection('reporting')`, or the WordPress PDO for SQL tabs. If its transaction can't begin, the snippet stops where it opened the connection, with a `Runlet\DryRunRefused` exception. A snippet that catches it can't use the connection anyway: Runlet refuses every statement on it.

Turn off Dry Run to run without a transaction.

## Warnings

Runlet warns on the line that did it, and again in the card, when something can't be rolled back:

- **Implicit commits Runlet sees too late.** On the connections the table above warns about, Runlet sees a statement only after it ran. It's saved, and so is everything the snippet changed on that connection before it. Runlet then begins a new transaction at once, so what follows is still rolled back: "Rolled back 1 statement on ledger · 2 statements saved".
- **Commits in the code.** A `COMMIT` statement, or `DB::commit()` without the snippet's own `DB::beginTransaction()`, commits Runlet's transaction: what came before is saved, and so is what comes after. A `ROLLBACK` in the snippet undoes what came before, but what comes after is saved.
- **Connections outside the dry run.** A statement that can change data on a connection the driver didn't list is saved, and Runlet names the connection.

## What a Dry Run Doesn't Cover

A dry run is a database transaction, not a sandbox:

- **Mail** is sent, unless **Intercept Mail** is on (the output's mail chip, or the target's Mail option); Runlet then intercepts it in the same run.
- **Queued jobs** on Redis, SQS, or another queue are pushed. The `database` queue on a wrapped connection is rolled back, and the `sync` queue runs in the run, inside the transaction.
- **HTTP calls, files, caches, Redis, search indexes, and other services** keep what the snippet did to them.
- **Other database connections:** ones the driver doesn't know, and connections opened outside the framework, such as a raw `new PDO(...)` in the snippet.
- **Code that runs after the run:** WordPress's `shutdown` hooks and PHP destructors run after Runlet rolled back, outside the transaction.

## Locks and Long Runs

The transaction lasts the whole run. Rows the snippet changes stay locked until the run ends, and on MySQL and MariaDB, so do rows it reads with `FOR UPDATE` or that its updates scan. A long dry run on a busy database can make other requests wait or time out. SQLite locks the whole file for writes, and WordPress's SQLite drop-in takes that lock at once.

On PostgreSQL, a failed statement aborts the transaction: until the run ends, later statements fail with "current transaction is aborted", where they would have run outside a dry run.

## Production

Dry Run doesn't skip the [production confirmation](environments.md): a dry run on a production target still asks. The confirmation says it's a dry run ("Dry-run this code on production?", **Dry Run on Production**) and what isn't rolled back.

It offers no "don't ask again for 10 minutes": a grace granted for a dry run would also let a normal run through without asking. A grace granted for a normal run covers dry runs too.

## For developers

Dry Run was added under [#13](https://github.com/filipac/runlet/issues/13); the WordPress PDO connection for SQL tabs that it also wraps is [#208](https://github.com/filipac/runlet/issues/208). The driver hook is [`rollbackConnections()`](driver-databases.md#rollback-connections).

- **Request.** The runner's request carries `"rollback": true`, for snippet runs only (never for commands, App Info, or a saved SQL connection).
- **Events.** The runner emits `rollback` events: `begun` (the connections, and `watching` when new Laravel connections join), `warning` (one, with the statement and its location; `refused` for a statement Runlet stopped before it ran), and `finished` (each connection's status, the statements that could change data, how many were saved, reads, and what ended its transaction). The full event shapes are in [Database Hooks ▸ Runner Protocol](driver-databases.md#runner-protocol).
- **Where statements are refused first:** Laravel and Eloquent connections whose illuminate/database has `Connection::beforeExecuting()`; Doctrine DBAL 2 and 3 through Runlet's SQL logger, and DBAL 4 through Runlet's driver middleware; WordPress's `$wpdb` through its `query` filter. Statements are counted through the run inspector's hooks (`Inspector::query()`).
- **Production.** `ProductionConfirmation.allowsGrace` is false for a dry run (`AppModel+Production.swift`).
