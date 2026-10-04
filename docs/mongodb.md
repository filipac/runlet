# MongoDB tabs

Tracked by [#191](https://github.com/filipac/runlet/issues/191); the remaining
scope is tracked in [#207](https://github.com/filipac/runlet/issues/207). Choose
**File ▸ New MongoDB Tab** (also in the command palette, [#214](https://github.com/filipac/runlet/issues/214))
for an empty MongoDB tab on the current tab's target, titled "MongoDB 1", "MongoDB 2", …;
right-click a tab (in the tab bar or the vertical tabs) and choose **Switch to MongoDB**;
or open a `.mongodb` file. The tab shows a
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

The PHP must have `ext-mongodb`. From this Mac, Runlet probes its PHPs in this
order and uses the first that has it: **Runlet's own PHP** (Settings ▸ PHP; build
php-8.5.8-r3 and later include mongodb 2.5.3,
[#212](https://github.com/filipac/runlet/issues/212)), the default PHP from
Settings ▸ PHP, the PHP Runlet picks automatically, then every other installed PHP
(including Herd). An older build of Runlet's PHP (r2) has no mongodb, so it is
skipped until you click **Update** in Settings ▸ PHP. With none, the run says so
and points to Settings ▸ PHP. Test Connection names the PHP that opened it. On a
target, a missing extension suggests **Connect from this Mac** or installing it
there.

Application connections use Laravel MongoDB's `DB::connection(name)` and
`getMongoClient()->getManager()`. **Default connection (mongodb)** uses Laravel's
`mongodb` connection; **Other Connection…** names another.
Alternatively, a project driver can implement `mongoConnection(?string $name)`
returning `['manager' => $manager, 'database' => 'your_database']`. Application
credentials are never imported into saved definitions.

## Import from TablePlus

**Import from TablePlus…** ([#209](https://github.com/filipac/runlet/issues/209), behind
its feature flag; see [Import from TablePlus](sql-tabs.md#import-from-tableplus)) imports
TablePlus's MongoDB connections (driver `Mongo` or `MongoDB`) as saved MongoDB
connections. TablePlus connects to MongoDB with a connection URL, so the import reads a
`mongodb://` or `mongodb+srv://` string (in `DatabaseHost`, or a URL key) into the fields,
and otherwise TablePlus's host, port, database and user fields. **The string itself is
never stored.**

| TablePlus | Runlet |
| --- | --- |
| Host and port | The first host and its port (27017 when unset). A seed list's other hosts are named in a note; with a replica set the driver finds them, through an SSH tunnel it connects to the first only. |
| `mongodb+srv` | **DNS SRV** on, no port, TLS on by default |
| Path database | Database; also the authentication database when the string has a user and no `authSource` (MongoDB's rule), except for SRV, which uses admin |
| `authSource`, `authMechanism` | Authentication database (default admin) and mechanism. Only SCRAM-SHA-1 and SCRAM-SHA-256 are kept; X.509, LDAP, Kerberos and AWS (`$external`) leave a note. |
| `replicaSet`, `readPreference` | Replica set; read preference (one of the five, matched without case; another leaves a note) |
| `tls` / `ssl`, TablePlus's TLS menu | TLS on (verified) or off. TablePlus's menu isn't documented for MongoDB, so any setting reads as on, with a note. `tlsInsecure` and CA or client certificate files leave notes: Runlet always verifies against the system's trust store. |
| Other options | `retryWrites`, `w`, `appName` and the timeouts are dropped quietly; others (`directConnection`, …) are named in a note. Values of options that can hold secrets are never kept. |
| Over SSH | An existing or new SSH profile, as for SQL rows. **SRV can't use a tunnel**, so an SRV row is imported to connect from this Mac directly, with a note: to tunnel, enter one member's host and port, turn SRV off, and choose the profile. |

A password inside the string is treated like TablePlus's Keychain password: copied into
Runlet's Keychain only with **Also copy passwords** (no Keychain prompt, since it's in
the file), otherwise left out with a note. If TablePlus's Keychain item for a MongoDB
connection holds a whole connection string, only its password is copied. A string Runlet
can't read (a password with an unencoded `/`, for example) imports nothing from it, and a
row without a readable host is greyed out. TablePlus's MongoDB keys aren't documented: the
pull request of #209 lists the public sources and the keys read defensively.

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
project-snippet files, real
SSH/SRV/TLS/replica-set validation. Runlet's own PHP has ext-mongodb since build r3
([#212](https://github.com/filipac/runlet/issues/212)). The Laravel
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
