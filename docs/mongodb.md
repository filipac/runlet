# MongoDB tabs

Tracked by [#191](https://github.com/filipac/runlet/issues/191). Right-click a tab
and choose **Switch to MongoDB**, or open a `.mongodb` file. Use **New MongoDB
Connection…** in its connection menu. Opening, restoring, or selecting never runs
a query.

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

**Load More** repeats the captured read with a skip offset, replacing output with
the next page, and asks again on production. Changing the query or connection
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
`getMongoClient()->getManager()`. Edit the name in the bar (default mongodb).
Alternatively, a project driver can implement `mongoConnection(?string $name)`
returning `['manager' => $manager, 'database' => 'your_database']`. Application
credentials are never imported into saved definitions.

## Collection explorer

The Database pane's **Load Collections** reads up to 100 names/types and estimated
counts. **Indexes** and **Sample Fields** put details in output; sampling reads
at most 50 documents. Sampled fields feed local completion without further reads.
**Open Find Query** edits without running. The menu lists authorized databases.
Every read asks on production. Caches stay in memory, separated by target,
connection and saved-connection revision.

## Safety and current scope

Read-only checks in both app and runner refuse insert/update/delete/replace,
drop, index creation and pipelines containing `$out`/`$merge`. MongoDB has no
per-session read-only mode: use read-only database roles for server enforcement.
`drop`, unfiltered `deleteMany` and unfiltered `updateMany` always require a
confirmation naming the operation and collection. `dropDatabase` is unsupported.
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

Remaining under [#191](https://github.com/filipac/runlet/issues/191): serverStatus/
currentOp/killOp and live cancellation tests, server-side Stop, TablePlus MongoDB
URI/SSH import mapping, project-snippet files, and real SSH/SRV/TLS/replica-set
validation. The Laravel adapter is implemented; live application tests exercise
the project-driver hook rather than installing laravel-mongodb. These are not
claimed as completed in this slice.

## Validation

The `mongo:7` fixture binds a random loopback port in the databases profile.
Start only it with `docker compose -f Tests/Fixtures/docker/compose.yml --profile
databases up -d mongo`. `scripts/setup-fixtures.sh databases` prints
`RUNLET_TEST_MONGODB='mongodb://127.0.0.1:PORT|runlet|runlet-fixture'`.
Run `SSH_AUTH_SOCK= swift test --no-parallel --filter Mongo` in
`Packages/RunletKit` with that variable set. Live tests use only `p191_` databases
and collections. App snapshots use a scratch `RUNLET_DATA_DIR`; no XCUITest runs.
