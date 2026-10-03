# Explain a captured SQL query

Implemented under [#4](https://github.com/filipac/runlet/issues/4).

This page is about queries the run inspector captured. In an SQL tab, **Explain Statement** shows the plan of the statement at the caret as a tree with full scans highlighted, and **Explain Analyze** measures it; see [Explain Statement](sql-tabs.md#explain-statement) ([#147](https://github.com/filipac/runlet/issues/147)). The inspector's Explain tab still shows the database's rows as the run's result; showing #147's plan tree there is tracked in [#170](https://github.com/filipac/runlet/issues/170).

After a run, open **Queries** and click **Explain** beside a statement, or choose it from the statement's context menu. In **Group Similar**, expand a group to explain an individual statement with that statement's bindings. The same action is available on query rows in the timeline.

Runlet opens an **Explain #N** PHP tab in the same window. It preserves the target that produced the captured query, even if you have since changed the original tab's target. The generated code keeps the SQL placeholders, typed bindings, and connection name separate. It uses `EXPLAIN QUERY PLAN` for SQLite and plain `EXPLAIN` for MySQL/MariaDB and PostgreSQL; it never adds `ANALYZE`.

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

`QueryExplainTests` checks capture limits, escaping, and old/new query decoding. `QueryExplainExecutionTests` executes generated PHP with special strings and typed values, requests actual SQLite PDO plans, explains captured Eloquent and Doctrine DBAL 3/4 queries in fresh processes, and verifies the WordPress SQLite limitation against a real capture. `ScenarioUITests.testExplainPreservesCapturedTargetAndWaitsForExplicitProductionRun` covers the Laravel UI flow, retargeting, restoring an idle tab, production cancellation, and a confirmed SQLite plan.

SQLite is the live execution evidence for this change. MySQL/PostgreSQL dialects, WordPress, and Symfony connection templates use their documented APIs; this change does not establish new live coverage for all of those integrations. Remaining SQL/mail integration gaps stay in [#53](https://github.com/filipac/runlet/issues/53).

API references: [SQLite query plans](https://www.sqlite.org/lang_explain.html), [MySQL EXPLAIN](https://dev.mysql.com/doc/refman/8.4/en/explain.html), [PostgreSQL EXPLAIN](https://www.postgresql.org/docs/current/sql-explain.html), [Laravel connections](https://api.laravel.com/docs/13.x/Illuminate/Database/Connection.html), [Doctrine parameters/results](https://www.doctrine-project.org/projects/doctrine-dbal/en/4.4/reference/data-retrieval-and-manipulation.html), [PDO bindValue](https://www.php.net/manual/en/pdostatement.bindvalue.php), [WordPress get_results](https://developer.wordpress.org/reference/classes/wpdb/get_results/), and [Symfony named connections](https://symfony.com/doc/current/doctrine/multiple_entity_managers.html).
