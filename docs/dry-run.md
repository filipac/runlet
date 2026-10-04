# Dry Run: roll back a run's database changes

**Dry Run** ([#13](https://github.com/filipac/runlet/issues/13)) runs a PHP tab inside database
transactions that Runlet always rolls back. Try a data fix on real data, look at what it did,
and keep nothing. It works on every target: the sandbox, local projects, Docker, and SSH.

## Turning it on

- The **Dry Run** button in the toolbar of a PHP tab, or **Run ▸ Dry Run (Roll Back Database
  Changes)** (also in the command palette). It is saved with the tab, in sessions and
  workspaces. Turning it on, opening a tab, or restoring a session runs nothing.
- While it is on, the toolbar reads **DRY RUN** in orange, a bar above the editor says
  "Dry run: database changes are rolled back" (with **Turn Off**), and each run's header ends
  with "dry run: database changes are rolled back".
- Run, Run Selection, Profile Run, sandbox auto-run, and an AI client's `run_php` in that tab are
  all dry runs. SQL, Redis, and MongoDB tabs don't have it: SQL tabs keep Run All's **In a
  Transaction** box.

## What happens

1. After the application boots, Runlet begins a transaction on every database connection its
   driver knows (see below), before any of the snippet runs.
2. The snippet runs as usual and sees its own changes.
3. When the run ends, however it ends (it returned, threw, called `exit()` or `dd()`, or hit a
   fatal error), Runlet rolls every one of them back.
4. The output ends with a **Dry run** card: "Rolled back 3 statements on mysql", one line per
   connection (statements that could change data, and reads), and any warnings. "Nothing to roll
   back on mysql" means the snippet only read.

Statements are counted through the [run inspector](drivers.md#run-inspector)'s hooks, whether the
inspector is on or off. Reads (`SELECT`, `SHOW`, …) are counted apart from the statements that
can change data; `SET`, `USE`, savepoints, and Runlet's own `BEGIN` and `ROLLBACK` aren't
counted, and Runlet's own statements stay out of the Queries section.

**Stop** kills PHP before Runlet can roll back. The database discards the open transaction when
the connection closes, so nothing is saved; the card says "Stopped before Runlet rolled back". A
statement still running on the server when you stop may finish first, and holds its locks until
it does.

## Which connections

| Application | Connections in the dry run |
| --- | --- |
| Laravel, Lumen, Laravel Zero | Every connection the database manager has open, and on Laravel 10+ every connection the snippet opens later (Laravel's `ConnectionEstablished` event), such as `DB::connection('reporting')`. Older versions: the open ones and the default connection. |
| Eloquent without Laravel (Capsule) | The same, through Capsule's database manager. Without an event dispatcher, the open connections and the default. |
| Symfony | Every connection of the `doctrine` registry (beginning a transaction connects it). |
| WordPress | `$wpdb` (MySQL, MariaDB, or the SQLite Database Integration drop-in), and the PDO connection SQL tabs open from `wp-config.php` (#208) if something opens it during the run. |
| Your driver | What its [`rollbackConnections()`](drivers.md#rollback-connections-dry-runs) returns: Eloquent, Doctrine DBAL, `$wpdb`, or PDO connections. |

A connection whose transaction can't begin (the server is down, say) is reported, and the run goes
on: nothing changes there through the dry run's connection. MongoDB connections in Laravel
(`mongodb/laravel-mongodb`) aren't SQL databases; they're left out, and the card says so. If the
driver's `rollbackConnections()` throws, nothing runs.

Laravel's nested transactions (`DB::transaction()`, `beginTransaction()`/`commit()` in the
snippet or in the application) become savepoints inside Runlet's transaction, so they are rolled
back too. Callbacks that wait for a commit (`DB::afterCommit()`, jobs and events dispatched
"after commit") never run, because nothing commits.

## Warnings

Runlet warns, on the line that did it and again in the card, when something can't be rolled back:

- **Implicit commits.** MySQL and MariaDB commit the open transaction before and after schema
  changes and a few other statements: `CREATE`, `ALTER`, `DROP`, `RENAME`, `TRUNCATE`,
  `LOCK TABLES`, `UNLOCK TABLES`, `GRANT`, `REVOKE`, `ANALYZE`/`OPTIMIZE`/`REPAIR TABLE`,
  `FLUSH`, `RESET`, `SET autocommit = 1`, and `START TRANSACTION`/`BEGIN` themselves (temporary
  tables aren't affected). The statement and everything the snippet changed on that connection
  before it are saved. Runlet then begins a new transaction at once, so what follows is still
  rolled back: "Rolled back 1 statement on mysql · 2 statements saved". PostgreSQL and SQLite
  roll schema changes back like anything else.
- **Commits in the code.** A `COMMIT` statement, or `DB::commit()` without the snippet's own
  `DB::beginTransaction()`, commits Runlet's transaction: what came before is saved, and so is
  what comes after. A `ROLLBACK` of the snippet's undoes what came before, but what comes after
  is saved.
- **Connections the dry run doesn't wrap.** A statement that can change data on a connection
  Runlet didn't begin a transaction on (one the driver didn't list, or one whose transaction
  couldn't begin) is saved, and Runlet names the connection.

## What a dry run doesn't cover

A dry run is a database transaction, not a sandbox:

- **Mail** is sent unless **Intercept Mail** is on (the output's mail chip, or the target's Mail
  option); Runlet intercepts it in the same run.
- **Queued jobs** on Redis, SQS, or another queue are pushed (the `database` queue on a wrapped
  connection is rolled back; the `sync` queue runs in the run, inside the transaction).
- **HTTP calls, files, caches, Redis, search indexes, and other services** keep what the snippet
  did to them.
- **Other database connections**: ones the driver doesn't know, and connections opened outside
  the framework (a raw `new PDO(...)` in the snippet).
- **Code that runs after the run**: WordPress's `shutdown` hooks and PHP destructors run after
  Runlet rolled back, outside the transaction.

## Locks and long runs

The transaction lasts the whole run. Rows the snippet changes (and, on MySQL and MariaDB, rows it
reads with `FOR UPDATE` or that its updates scan) stay locked until the run ends, so a long dry
run on a busy database can make other requests wait or time out; SQLite locks the whole file for
writes (WordPress's SQLite drop-in takes the lock at once). On PostgreSQL, a failed statement
aborts the transaction: until the run ends, later statements fail with "current transaction is
aborted", where they would have run outside a dry run.

## Production

Dry Run doesn't skip the [production guard](../readme.md#run-it-where-your-app-lives): a run on a
target marked as production still asks. The confirmation says it is a dry run ("Dry-run this
code on production?", **Dry Run on Production**) and what isn't rolled back, and it offers no
"don't ask again for 10 minutes": a grace granted for a dry run would also let a normal run
through without asking. A grace granted for a normal run covers dry runs too.

## For drivers and the runner

The request carries `"rollback": true` (snippet runs only). The runner's `rollback` events are
`begun` (the connections, `watching` when new Laravel connections join), `warning` (one, with the
statement and its location), and `finished` (each connection's status, statements that could
change data, how many were saved, reads, and what ended its transaction). See
[docs/drivers.md](drivers.md#rollback-connections-dry-runs) for the driver hook.
