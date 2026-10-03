# Explain a captured SQL query

Implemented under [#4](https://github.com/filipac/runlet/issues/4), with the plan tree from [#170](https://github.com/filipac/runlet/issues/170).

This page is about queries the run inspector captured. In an SQL tab, **Explain Statement** shows the plan of the statement at the caret as a tree with full scans highlighted, and **Explain Analyze** measures it; see [Explain Statement](sql-tabs.md#explain-statement) ([#147](https://github.com/filipac/runlet/issues/147)). The inspector's Explain tab shows its plan with the same plan card.

After a run, open **Queries** and click **Explain** beside a statement, or choose it from the statement's context menu. In **Group Similar**, expand a group to explain an individual statement with that statement's bindings. The same action is available on query rows in the timeline.

Runlet opens an **Explain #N** PHP tab in the same window. It preserves the target that produced the captured query, even if you have since changed the original tab's target. The generated code keeps the SQL placeholders, typed bindings, and connection name separate. It asks for the plan in the format Runlet reads as a tree, and never adds `ANALYZE`:

| Captured driver | EXPLAIN |
| --- | --- |
| MySQL, MariaDB | `EXPLAIN FORMAT=JSON` |
| PostgreSQL | `EXPLAIN (FORMAT JSON)` |
| SQLite | `EXPLAIN QUERY PLAN` |
| not recorded | plain `EXPLAIN`; the rows are the run's result, as before |

The code runs the EXPLAIN through the captured connection, then hands the rows to `\Runlet\explainPlan()`:

```php
$connection = \Illuminate\Support\Facades\DB::connection($connectionName);
$plan = $connection->select($sql, $bindings);
// Runlet shows the plan as a tree, with the database's own output under Raw.
return function_exists('Runlet\explainPlan')
    ? \Runlet\explainPlan($plan, $connection, $connectionName)
    : $plan;
```

After **Run**, the output shows the plan card of [Explain Statement](sql-tabs.md#explain-statement): the steps as a collapsible tree, full scans highlighted and counted, **Raw** for the database's own output, and a line naming the database and its version, the connection, and the database layer. The rows aren't dumped as well.

- **`Runlet\explainPlan($rows, $connection, $connectionName)`** is a runner function you can call from any PHP tab. `$rows` are the EXPLAIN's rows (objects or arrays, or a collection). `$connection` is what they came from: a PDO, an Illuminate (Laravel or Eloquent) or Doctrine DBAL connection, `$wpdb`, or the database's name (`mysql`, `mariadb`, `pgsql`, `sqlite`); without it, Runlet tells the database by the rows' column. It sends nothing to the database: the connection gives the dialect and the server version, which tells MariaDB from MySQL. It returns nothing to show when it shows the card.
- Rows it can't read as a plan, such as MySQL's tabular `EXPLAIN`, PostgreSQL's text plan, or another database's, come back as they are, so the run dumps them as before. Outside Runlet's runner, `function_exists()` is false and the code returns the rows.
- If you write `ANALYZE` into the tab yourself, the statement runs and the card shows its actual rows and times. This is your PHP: unlike Explain Analyze in SQL tabs, Runlet doesn't ask about writes or roll them back here (production targets still ask before every Run).

Opening or restoring the tab does not run it or request a production execution confirmation. Review and edit the code, then press **Run**. Production targets use the usual confirmation, and Cancel leaves the tab idle. Target/profile changes still apply to later explicit runs as they do for any PHP tab.

## Connections and capture limits

- Laravel, Lumen, and Laravel Zero use the captured named database connection through the DB facade. Standalone Eloquent uses its configured model connection resolver.
- Symfony uses the captured connection in its Doctrine registry. WordPress uses the bootstrapped `$wpdb`; its captured SQL already includes the values substituted by WordPress.
- Custom Doctrine and PDO captures open an editable template. Recreate the captured named connection as `$connection` (DBAL) or `$pdo` before running it. Each Run starts a fresh PHP process, so variables and connections created only in the previous snippet are not shared. The template throws a setup error instead of choosing a different connection.
- Explain is disabled when SQL or bindings were truncated, or a binding's original value cannot be recreated (for example, binary/resource/object values). Display-only interpolated SQL is never used to reconstruct executable bindings.
- Other recorded database drivers, including SQL Server, have no Explain generator yet. Their query inspection and copy actions remain available.
- WordPress's SQLite translation layer does not return Explain plans through `$wpdb`, so Explain is disabled for those captures. WordPress on MySQL uses its normal query API.

The database determines whether it can explain a particular statement. Connections, temporary tables, transactions, and session settings created only by the original snippet need to be recreated explicitly in the Explain tab.

## Validation

`QueryExplainTests` checks capture limits, escaping, old/new query decoding, and each driver's EXPLAIN and `Runlet\explainPlan()` call per database layer (#170). `QueryExplainExecutionTests` executes generated PHP with special strings and typed values, shows the plan card for a captured Laravel query on SQLite (the same connection and bindings) and for SQLite PDO plans, explains captured Eloquent and Doctrine DBAL 3/4 queries in fresh processes, runs the WordPress template against a stand-in `$wpdb` with recorded MariaDB output, checks that rows `Runlet\explainPlan()` can't read are returned as they are, runs on PHP 7.4, and verifies the WordPress SQLite limitation against a real capture. `QueryExplainLiveTests` (with `RUNLET_TEST_MYSQL`/`RUNLET_TEST_PGSQL`) explains captured PDO queries on MariaDB 11 and PostgreSQL 14, including a DELETE that must not run, and the same plans through Eloquent (Capsule) and Doctrine DBAL 3/4 connections. `ScenarioUITests.testExplainPreservesCapturedTargetAndWaitsForExplicitProductionRun` covers the Laravel UI flow, retargeting, restoring an idle tab, production cancellation, and a confirmed SQLite plan card.

SQLite, MariaDB 11, and PostgreSQL 14 are the live execution evidence. MySQL's JSON is read by #147's parser, tested on samples in the documented format. WordPress on MySQL and Symfony's Doctrine registry use their documented APIs; the WordPress template is tested against a stand-in `$wpdb`, not a WordPress install on MySQL. Remaining SQL/mail integration gaps stay in [#53](https://github.com/filipac/runlet/issues/53).

API references: [SQLite query plans](https://www.sqlite.org/lang_explain.html), [MySQL EXPLAIN](https://dev.mysql.com/doc/refman/8.4/en/explain.html), [PostgreSQL EXPLAIN](https://www.postgresql.org/docs/current/sql-explain.html), [Laravel connections](https://api.laravel.com/docs/13.x/Illuminate/Database/Connection.html), [Doctrine parameters/results](https://www.doctrine-project.org/projects/doctrine-dbal/en/4.4/reference/data-retrieval-and-manipulation.html), [PDO bindValue](https://www.php.net/manual/en/pdostatement.bindvalue.php), [WordPress get_results](https://developer.wordpress.org/reference/classes/wpdb/get_results/), and [Symfony named connections](https://symfony.com/doc/current/doctrine/multiple_entity_managers.html).
