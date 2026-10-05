# Explain a Captured Query

When a run's **Queries** list shows a slow statement, **Explain** opens its plan in a new tab: the same SQL, with the same bindings, on the connection and target it ran on. Nothing runs until you press Run.

This page is about queries a run captured. To explain a statement you write yourself, use [Explain Statement](sql-tabs.md#explain-statement) in an SQL tab.

## Explaining a Query

1. Run a snippet, then open **Queries** in the output pane.
2. Click **Explain** beside a statement, or choose it from the statement's context menu. Query rows in the timeline have **Explain** too. With **Group Similar** on, expand a group to explain one statement with its own bindings.
3. Runlet opens an **Explain #N** PHP tab in the same window. Read the code, edit it if you like, and press **Run** (<kbd>⌘</kbd><kbd>R</kbd>).

The new tab keeps the target the query ran on, even if you changed the original tab's target since. After that, it's an ordinary PHP tab: change its target, and later runs use the new one.

![A run's Queries list with Explain beside the statement, and the Explain #1 tab it opened next to the snippet's tab](screenshots/sql-explain/explain-tab-light.webp#gh-light-mode-only)
![A run's Queries list with Explain beside the statement, and the Explain #1 tab it opened next to the snippet's tab](screenshots/sql-explain/explain-tab-dark.webp#gh-dark-mode-only)

> [!NOTE]
> Opening or restoring an Explain tab never runs it. On a production target, Run asks first as usual, and **Cancel** leaves the tab idle.

## The Explain Tab

The tab holds PHP you can read before it runs. For a query a Laravel application ran on MySQL, it looks like this:

```php
// Review this plan request, then press Run.
// Opening or restoring this tab never runs it.
$sql = "EXPLAIN FORMAT=JSON select * from `orders` where `status` = ? limit 20";
$bindings = [
    0 => "paid",
];
$connectionName = "mysql";
$connection = \Illuminate\Support\Facades\DB::connection($connectionName);
$plan = $connection->select($sql, $bindings);
// Runlet shows the plan as a tree, with the database's own output under Raw.
return function_exists('Runlet\explainPlan')
    ? \Runlet\explainPlan($plan, $connection, $connectionName)
    : $plan;
```

The SQL keeps its placeholders, and the bindings (with their types) and the connection's name stay separate, as the run captured them. Runlet asks for the plan in a format it can show as a tree, and never adds `ANALYZE`:

| Captured driver | Explain |
| --- | --- |
| MySQL, MariaDB | `EXPLAIN FORMAT=JSON` |
| PostgreSQL | `EXPLAIN (FORMAT JSON)` |
| SQLite | `EXPLAIN QUERY PLAN` |
| Not recorded | Plain `EXPLAIN`; its rows are the run's result |

> [!WARNING]
> If you add `ANALYZE` to the SQL yourself, the statement runs, and the card shows its actual rows and times. This is your PHP: unlike [Explain Analyze](sql-tabs.md#explain-analyze) in SQL tabs, Runlet doesn't ask about writes or roll them back. A production target still asks before every run.

## Reading the Plan

After Run, the output shows the plan card that SQL tabs use, instead of dumping the rows:

- the plan's steps as a tree, which you can collapse;
- full scans highlighted and counted;
- **Raw**, for the database's own output;
- a line naming the database and its version, the connection, and the database layer.

![The plan card of an explained SQLite query: SCAN users marked as a full scan, then a temporary B-tree for the ORDER BY](screenshots/sql-explain/plan-card-light.webp#gh-light-mode-only)
![The plan card of an explained SQLite query: SCAN users marked as a full scan, then a temporary B-tree for the ORDER BY](screenshots/sql-explain/plan-card-dark.webp#gh-dark-mode-only)

## Showing a Plan From Any Tab

The Explain tab ends with a call to `Runlet\explainPlan()`, and any PHP tab can call it with rows of its own:

```php
use Illuminate\Support\Facades\DB;

$rows = DB::select('EXPLAIN FORMAT=JSON SELECT * FROM orders WHERE status = ?', ['paid']);

return \Runlet\explainPlan($rows, DB::connection());
```

`Runlet\explainPlan($rows, $connection = null, $connectionName = null)` shows the plan card and sends nothing to the database:

- **`$rows`** are the EXPLAIN's rows: objects, arrays, or a collection.
- **`$connection`** is where they came from: a PDO, a Laravel or Eloquent connection, a Doctrine DBAL connection, `$wpdb`, or the database's name (`mysql`, `mariadb`, `pgsql`, `sqlite`). Runlet reads the dialect and the server version from it, which tells MariaDB from MySQL. Without it, Runlet tells the database by the rows' columns.
- Rows it can't read as a plan, such as MySQL's tabular `EXPLAIN`, PostgreSQL's text plan, or another database's, come back as they are, so the run dumps them.

Outside Runlet's runner, the function doesn't exist, which is why the Explain tab checks `function_exists()` and returns the rows instead. The [Snippet API](snippet-api.md) lists Runlet's other functions.

## Connections

The Explain tab opens the connection the query used:

| Captured from | The tab uses |
| --- | --- |
| Laravel, Lumen, Laravel Zero | The captured connection, through the `DB` facade |
| Eloquent without Laravel | Eloquent's configured connection resolver |
| Symfony | The captured connection of the Doctrine registry |
| WordPress | `$wpdb`. Its captured SQL already holds the values WordPress substituted. |
| Doctrine DBAL or PDO of your own | An editable template: set up the connection as `$connection` (DBAL) or `$pdo` first |

Each Run starts a fresh PHP process, so a connection that only the original snippet created isn't there. The template stops with a setup error until you create it; it never picks another connection.

The same goes for anything else the original snippet set up: temporary tables, transactions, and session settings need to be created again in the Explain tab. Whether a statement can be explained at all is up to the database.

## When Explain Isn't Available

**Explain** is disabled, with the reason, when:

- the captured SQL or a binding was truncated;
- a binding's value can't be recreated, such as binary data, a resource, or an object (Runlet never rebuilds bindings from the display-only SQL with values filled in);
- the query ran on another database, such as SQL Server (its other query actions still work);
- WordPress ran it through its SQLite translation layer, which doesn't return plans through `$wpdb`. WordPress on MySQL works.

## For developers

The inspector's Explain was implemented under [#4](https://github.com/filipac/runlet/issues/4), and the plan card in Explain tabs under [#170](https://github.com/filipac/runlet/issues/170). The card is SQL tabs' Explain Statement ([#147](https://github.com/filipac/runlet/issues/147)). This page was rewritten for the documentation website in [#290](https://github.com/filipac/runlet/issues/290).

| Piece | Where |
| --- | --- |
| The tab's code per connection style, the EXPLAIN prefix per driver, and the reasons Explain is unavailable | `QueryExplain` in `Packages/RunletKit/Sources/RunletCore/QueryExplain.swift` (`code(for:style:)`, `unavailableReason(for:)`) |
| Which style a captured query gets (Laravel, Eloquent, Symfony's Doctrine, manual Doctrine, WordPress, PDO) | `AppModel.explainStyle(for:in:)` in `Runlet/App/AppModel+Inspector.swift` |
| Opening the idle **Explain #N** tab on the query's target | `AppModel.explain(_:from:index:)`; the target is the tab's `inspectionTarget`, the target of the run that captured the query |
| The Explain button in Queries, Group Similar, and the timeline | `QueryExplainButton` in `Runlet/Features/InspectorViews.swift` |
| `Runlet\explainPlan()` and the plan parser | The runner's `explainPlan()` and `SqlExplain::fromRows()`; it emits the `sqlPlan` event, shared with Explain Statement. The architecture notes: [architecture.md](architecture.md) |

- Opening Explain is an editing action: only the normal Run executes the tab. Restoring it, and later target or profile changes, work as for any PHP tab.
- WordPress's template is generated only for captures without separate bindings, since `$wpdb` reports the SQL it executed with the values substituted.
- MySQL's JSON is read by #147's parser, tested on samples in the documented format.

### Validation

- `QueryExplainTests` checks the capture limits, escaping, decoding of old and new query records, and each driver's EXPLAIN and `Runlet\explainPlan()` call per database layer (#170).
- `QueryExplainExecutionTests` runs the generated PHP with special strings and typed values; shows the plan card for a captured Laravel query on SQLite (the same connection and bindings) and for SQLite PDO plans; explains captured Eloquent and Doctrine DBAL 3 and 4 queries in fresh processes; runs the WordPress template against a stand-in `$wpdb` with recorded MariaDB output; checks that rows `Runlet\explainPlan()` can't read are returned as they are; runs on PHP 7.4; and verifies the WordPress SQLite limitation against a real capture.
- `QueryExplainLiveTests` (with `RUNLET_TEST_MYSQL` and `RUNLET_TEST_PGSQL`) explains captured PDO queries on MariaDB 11 and PostgreSQL 14, including a `DELETE` that must not run, and the same plans through Eloquent (Capsule) and Doctrine DBAL 3 and 4 connections.
- `ScenarioUITests.testExplainPreservesCapturedTargetAndWaitsForExplicitProductionRun` covers the Laravel flow in the app: retargeting, restoring an idle tab, cancelling on production, and a confirmed SQLite plan card.

SQLite, MariaDB 11, and PostgreSQL 14 are the live execution evidence. WordPress on MySQL and Symfony's Doctrine registry use their documented APIs; the WordPress template is tested against a stand-in `$wpdb`, not a WordPress install on MySQL. The remaining SQL and mail integration gaps are tracked in [#53](https://github.com/filipac/runlet/issues/53).

API references: [SQLite query plans](https://www.sqlite.org/lang_explain.html), [MySQL EXPLAIN](https://dev.mysql.com/doc/refman/8.4/en/explain.html), [PostgreSQL EXPLAIN](https://www.postgresql.org/docs/current/sql-explain.html), [Laravel connections](https://api.laravel.com/docs/13.x/Illuminate/Database/Connection.html), [Doctrine parameters and results](https://www.doctrine-project.org/projects/doctrine-dbal/en/4.4/reference/data-retrieval-and-manipulation.html), [PDO bindValue](https://www.php.net/manual/en/pdostatement.bindvalue.php), [WordPress get_results](https://developer.wordpress.org/reference/classes/wpdb/get_results/), and [Symfony named connections](https://symfony.com/doc/current/doctrine/multiple_entity_managers.html).
