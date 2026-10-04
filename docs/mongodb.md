# MongoDB tabs

Tracked by [#191](https://github.com/filipac/runlet/issues/191); the remaining
scope is tracked in [#207](https://github.com/filipac/runlet/issues/207). Right-click
a tab and choose **Switch to MongoDB**, or open a `.mongodb` file. The tab shows a
green **MONGODB** badge, like the SQL and REDIS badges. Opening, restoring, or
selecting never runs a query.

The bar above the editor works like the SQL and Redis bars: the connection button
opens the shared connection picker, which lists only MongoDB connections:
**Default connection (mongodb)** and **Other Connection…** for the application's
own, then the target's saved connections and those of all targets, **New
Connection…** and **Edit Connections…**. A saved connection that is missing here
gets a **New Connection…** row under the bar. Choosing a connection never connects
or runs anything.

## Queries and results

Write one JSON query per tab, or select one complete object and press ⌘R. This is
the issue's structured-form fallback, not JavaScript/mongosh. Relaxed JSON,
comments and multiple statements are not supported.

```json
{
  "collection": "orders",
  "operation": "find",
  "filter": { "status": "paid" },
  "projection": { "status": 1, "total": 1 },
  "sort": { "total": -1, "_id": 1 },
  "limit": 20
}
```

| Operation | Additional fields |
| --- | --- |
| `find` | `filter`, `projection`, `sort`, `skip`, `limit`, `explain` |
| `findOne` | `filter`, `projection`, `sort` |
| `aggregate` | `pipeline`, `explain` |
| `countDocuments` | `filter` |
| `distinct` | `filter`, `field` |
| `insertOne`, `insertMany` | `documents` array (one for insertOne, at most 1,000) |
| `updateOne`, `updateMany` | `filter`, `update` |
| `replaceOne` | `filter`, `replacement` |
| `deleteOne`, `deleteMany` | `filter` |
| `createIndex` | `keys`, optional `unique` |
| `drop`, `getIndexes`, `sampleSchema` | none |
| `listDatabases`, `listCollections` | none; use `"collection": "metadata"` |

Use BSON Extended JSON for special values: `{"$oid":"507f1f77bcf86cd799439011"}`,
`{"$date":"2026-01-01T00:00:00Z"}`, `{"$numberLong":"9223372036854775807"}`,
`{"$numberDecimal":"12.50"}`, and
`{"$regularExpression":{"pattern":"^paid","options":"i"}}`. JavaScript
constructors and server-side JavaScript operators are refused.

Results have a top-level table and a canonical Extended JSON tree. Numeric BSON
values display as exact text in the table; ObjectIds are named and the tree keeps
type tags. `explain: true` on find/aggregate returns query-planner output as JSON.

**Next Page**, under a full page of a find, aggregate or distinct (where SQL's
Load Next is), repeats the captured read with a skip offset, replacing the output
with the next page; the card says which documents it shows. It asks again on
production. ⌘R runs the query from the first page again. Changing the query or connection
invalidates the page. Use a stable sort with a unique tiebreaker: pages are
separate reads, not a snapshot. Limits are the configured page size (at most
1,000 documents), 200 table columns and 4 MiB of document JSON. `distinct` also
has MongoDB's command-result limit. Explicit `limit: 0` returns no documents.

## Connections

Saved definitions use host/port, database, username, authentication database
(default admin), mechanism, replica set and read preference. DNS SRV selects
`mongodb+srv` and cannot use an explicit port or SSH tunnel. Enter a host, not a
URI: passwords are stored only in the Keychain, never in saved URI text.

Scope and connect-from target/this Mac/SSH tunnel follow existing saved
connections. Tunnels force `directConnection=true` and connect only to their
local forward. TLS verifies certificate and hostname against system trust; a
tunnel's certificate must name `127.0.0.1`. Custom TLS files and client-certificate
authentication are not exposed in this slice.

The PHP must have `ext-mongodb`. From this Mac, Runlet probes installed PHPs
(including Herd) and chooses one that has it. Missing extensions suggest
**Connect from this Mac** or installing the extension on the target. The static
PHP recipe adds mongodb, but **php-8.5.8-r3 still needs to be built and released**.
This PR builds/publishes no PHP binary; verified download metadata remains r2.

Application connections use Laravel MongoDB's `DB::connection(name)` and
`getMongoClient()->getManager()`. **Default connection (mongodb)** uses Laravel's
`mongodb` connection; **Other Connection…** names another.
Alternatively, a project driver can implement `mongoConnection(?string $name)`
returning `['manager' => $manager, 'database' => 'your_database']`. Application
credentials are never imported into saved definitions.

## Collection explorer

The Database pane works like the SQL schema explorer: a header with the target, the
connection and its badges, then **Load Collections**, which reads up to 100
collection names and types with estimated counts (never documents). Collections
are listed by name, with a filter. Each row has buttons, and a context menu, for
**Indexes** and **Sample Fields** (both read one collection into the output;
sampling reads at most 50 documents), **Open Find Query** (a new MongoDB tab on
the same connection with a find of the first 50 documents; nothing runs; a
double-click does the same) and **Copy Name**. Sampled fields show under their
collection and feed local completion without further reads. The header's menu
reloads, lists authorized databases, or forgets the collections. Nothing reads by
itself, and every read asks on production. Caches stay in memory, separated by
target, connection and saved-connection revision.

## Safety and current scope

Read-only checks in both app and runner refuse insert/update/delete/replace,
drop, index creation and pipelines containing `$out`/`$merge`. MongoDB has no
per-session read-only mode: use read-only database roles for server enforcement.
`drop`, unfiltered `deleteMany` and unfiltered `updateMany` always ask first, on
every connection, in the same confirmation as Redis's dangerous commands: it names
the operation, the collection, the database and the connection, and shows the
query's line and text. Production asks again after it. `dropDatabase` is unsupported.
Production asks separately for every query/metadata read; PHP's grace does not apply.

Saved runs use the plain bootstrap and stdin-only credentials. Passwords and
MongoDB URI userinfo are scrubbed from results. Driver failures emit generic
messages and a numeric code, with no arguments or previous exception. MCP cannot
run these tabs or access saved definitions/passwords. A compromised target can
still inspect its process memory, as described by the database security model.

History and personal snippets retain connection references, not definitions.
Connection Manager lists MongoDB runs; Stop ends the runner. **Server-side Stop
is not implemented**: supported reads have a 25-second server limit, and a stopped
write may already have taken effect.

Remaining scope is tracked in [#207](https://github.com/filipac/runlet/issues/207):
serverStatus/currentOp/killOp and live cancellation tests, server-side Stop,
TablePlus MongoDB URI/SSH import mapping, project-snippet files, real
SSH/SRV/TLS/replica-set validation, and a bundled PHP with ext-mongodb. The Laravel
adapter is implemented; live application tests exercise the project-driver hook
rather than installing laravel-mongodb.

## Validation

The `mongo:7` fixture binds a random loopback port in the databases profile.
Start only it with `docker compose -f Tests/Fixtures/docker/compose.yml --profile
databases up -d mongo`. `scripts/setup-fixtures.sh databases` prints
`RUNLET_TEST_MONGODB='mongodb://127.0.0.1:PORT|runlet|runlet-fixture'`.
Run `SSH_AUTH_SOCK= swift test --no-parallel --filter Mongo` in
`Packages/RunletKit` with that variable set. Live tests use only `p191_` databases
and collections. `DatabaseDangerTests` covers the shared confirmation's Redis and
MongoDB wording and the MongoDB picker's family filter. App snapshots use a scratch
`RUNLET_DATA_DIR` and the Debug steps `mongo-tab`, `mongo-explorer`,
`mongo-sample:<collection>`, `mongo-next-page`, `mongo-confirm:yes|no`,
`mongo-menu:<collection>` and `mongo-state`; no XCUITest runs.
