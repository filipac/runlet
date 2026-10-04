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
comments and multiple statements are not supported. A mongosh-like subset translated
to this form is a separate, optional idea:
[#220](https://github.com/filipac/runlet/issues/220).

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
| `dropDatabase` | `database` (the connection's database), no `collection` ([#207](https://github.com/filipac/runlet/issues/207)) |

Use BSON Extended JSON for special values: `{"$oid":"507f1f77bcf86cd799439011"}`,
`{"$date":"2026-01-01T00:00:00Z"}`, `{"$numberLong":"9223372036854775807"}`,
`{"$numberDecimal":"12.50"}`, and
`{"$regularExpression":{"pattern":"^paid","options":"i"}}`. JavaScript
constructors and server-side JavaScript operators are refused.

Results have a top-level table and a canonical Extended JSON tree. The tree keeps
the type tags. The table shows the values readably
([#207](https://github.com/filipac/runlet/issues/207)):

| Extended JSON | Table cell |
| --- | --- |
| `{"$oid": "…"}` | `ObjectId("…")` |
| `{"$date": …}` | `2026-01-01 00:00:00.000+00:00` (UTC, as SQL tabs show dates) |
| `$numberInt`, `$numberLong` | the number |
| `$numberDouble`, `$numberDecimal` | the exact text, such as `12.50` |
| `$binary` | `BinData(0, "aGVsbG8=")`; subtype 3 or 4 of 16 bytes as `UUID("…")`; long values as their size |
| `$timestamp`, `$regularExpression`, `$minKey`, `$maxKey` | `Timestamp({ t: 1, i: 2 })`, `/^paid/i`, `MinKey`, `MaxKey` |
| a document or array | mongosh-like text: `{ name: "Customer 1", since: ISODate("2026-01-01T00:00:00.000Z") }` |

`explain: true` on find/aggregate returns query-planner output as JSON. Sample
Fields names types as BSON does: `ObjectId`, `UTCDateTime`, `Decimal128`, `Binary`,
`object`, `array`, `string`, `int`, `double`, `bool`, `null`.

**Load More**, under a full page of a find, aggregate or distinct (where SQL's
Load Next is, [#207](https://github.com/filipac/runlet/issues/207)), reads the
next page of the captured query on the same connection, in a fresh runner, and
**appends** it: its rows to the table, its documents to the tree. Documents have
no fixed shape, so a field a page adds becomes a column at the end, empty in the
rows before. The tree keys documents by their position in the result; when a
page's tree was cut at the dump's 200-children limit, it keeps each page's first
documents (0–199, then 1000–1199, …) and says how many more weren't shown. The
card says "Documents 1–2,000 in 2 pages; more may follow." Load More asks again on
production, can be stopped while it loads, is listed in the Connection Manager,
and is a Run History entry of its own. ⌘R runs the query from the first page
again; changing the query or connection, or clearing the output, ends paging. Use
a stable sort with a unique tiebreaker: pages are separate reads, not a snapshot.
Limits are the configured page size (at most 1,000 documents), 50,000 documents
per card, 200 table columns and 4 MiB of document JSON per page. `distinct` also
has MongoDB's command-result limit. Explicit `limit: 0` returns no documents.

## Query builder

The **Query Builder** ([#217](https://github.com/filipac/runlet/issues/217)) builds a tab's
JSON query with forms, and writes it into the tab: the editor always shows exactly what ⌘R
runs, and the builder never runs anything. Open it with the MongoDB bar's **Builder** button,
**View ▸ Show Builder**, or ⌥⌘B (the same command opens a Redis tab's
[Command Builder](redis.md), #218). It sits beside the editor, where the Command Builder sits;
drag its edge to resize it.

It has forms for **find, findOne, countDocuments, distinct, aggregate**, and the writes
**insertOne, insertMany, updateOne, updateMany, replaceOne, deleteOne, deleteMany** (marked ✎ in
the Operation menu; a WRITE or DESTRUCTIVE badge shows beside it and in the preview):

- **Collection**: typed, or chosen from the collections the Database pane loaded.
- **Filter**: rules of a field, an operator, and a value. Operators: `=`, `≠`, `>`, `≥`, `<`,
  `≤` (`$eq` … `$lte`), `in` and `not in` (a list of values), `exists`, `regex` (with the `i`,
  `m`, `s`, `x` options), and `type` (`$type`'s aliases). Fields come from the collection's
  sampled fields, with their types; type any path, nested ones too (`customer.city`). Rules
  are grouped in **All of**, **Any of**, and **None of** groups (`$and`, `$or`, `$nor`), nested
  as deep as needed. Rules on one field share one operator object
  (`"total": { "$gte": 10, "$lt": 100 }`).
- **Typed values** write Extended JSON: a **date** picker in UTC (`{"$date": "2026-03-01T09:30:00Z"}`),
  an **ObjectId** checked as it's typed (24 hexadecimal digits, `{"$oid": …}`), **Decimal128**
  (`{"$numberDecimal": "12.50"}`, exactly as typed), **Int64** (`{"$numberLong": …}`), numbers,
  true or false, null, strings, a **regex** value (`{"$regularExpression": …}`), a **snippet
  input** (`{"$input": "name"}`, [Snippets](#snippets)), or any JSON. Choosing a sampled field
  sets the value's type from the field's (an `ObjectId` field gets an ObjectId input, a
  `UTCDateTime` field a date picker). A value that isn't valid yet (a short ObjectId, a number
  with a comma) is outlined, and the builder doesn't write until it is; the note says why.
- **Projection** (Include or Exclude per field, or an expression), **Sort** (fields in order,
  ascending or descending, with ↑ and ↓ to reorder), **Skip** and **Limit**, distinct's
  **Field**, and find's and aggregate's **Explain**.
- **Pipeline**: stage cards for `$match` (the same filter form), `$project`, `$group` (group by
  nothing, a field, several fields, or an expression; accumulated fields with `$sum`, `$avg`,
  `$min`, `$max`, `$count`, `$push`, `$addToSet`, `$first`, `$last`), `$sort`, `$limit`,
  `$skip`, `$unwind` (with the index field and "keep documents without the array"), `$lookup`
  (from a loaded collection; its foreign field from that collection's sampled fields),
  `$addFields` and `$set`, `$count`, and a **JSON stage** for anything else. Cards can be moved
  up and down, duplicated, removed, and **disabled**: a disabled stage isn't written, and stays
  in the builder while it's open (a hand edit of the text reads the query again without it).
  Switching a find to aggregate starts the pipeline from its filter, sort, skip, limit, and
  projection.
- **Update**: changes with `$set`, `$unset`, `$inc`, `$push`, and `$pull`, typed like filter
  values. **Replacement** (replaceOne) and **Documents** (the inserts) are JSON.

**Writing.** Every change rewrites the query in the tab, pretty-printed, once the builder has
been still for 0.4 s: typing a value is one edit, and each edit is one Undo step ("Undo Query
Builder"). Only the query the builder read is rewritten, and only the part that changed, so the
lines around it, the caret, and the scroll position stay. A tab can hold several queries (⌘R
runs the selected one): the builder works on the selected query, or the one at the caret. A
rule, field, or change without a field name isn't written until it has one, and an empty
group isn't written (MongoDB refuses one); the preview says so. Fields an operation doesn't take
stay in the builder, unwritten, and come back when you switch back. The preview under the form
shows the query, how Runlet treats it, and why ⌘R would refuse it (an update without changes,
distinct without its field, a write on a read-only connection). **Insert as New Query** adds a
copy after it, which the builder then edits; **Select** (with several queries) selects it so ⌘R
runs it alone.

**Reading.** Opening the builder reads the selected query, or the one at the caret, into the
forms; so does **Read Query** in its header, editing the text (shortly after you stop), and
moving the caret to another query. Reading never changes the text: the text changes only when
you change something in the builder. A query read and written back is the same JSON, with its
members in the same order and its numbers' literals (`1.50` stays `1.50`). What the builder has
no form for (operators such as `$elemMatch`, `$expr`, `$text`, `$all`, `$size`; stages such as
`$facet` or `$lookup` with a pipeline; update operators such as `$rename`; fields such as
createIndex's `keys`) stays a **JSON block** in its place, editable as text, so nothing is
lost. A query that isn't valid JSON (or isn't closed) shows why, with **Start from Collection**:
it adds a new find of the chosen collection after it, and leaves the text it couldn't read as
it is. A blank tab offers the same.

**Fields and collections** come from the Database pane's caches: Load Collections and Sample
Fields ([Collection explorer](#collection-explorer)). The builder never reads the server by
itself; without sampled fields it offers **Sample Fields**, which reads like the pane's button
(production asks first).

**Filter by This Value.** A cell of a find's or an aggregate's result table has **Filter by
This Value in the Query Builder** in its context menu: it adds `field = value` to the filter
(an aggregate's last `$match`, after the stages that made the field), typed from the cell
(an ObjectId, a UTC date, a Decimal128 or Int64 by the field's sampled type) and written like
any other change. Documents and arrays aren't offered.

Running is unchanged: ⌘R runs the editor's query, with read-only refusals, the confirmation of
destructive operations, and production's question. "Copy as mongosh" and "Copy as Laravel
query" were left out: [#220](https://github.com/filipac/runlet/issues/220) tracks a mongosh-like
subset.

## Connections

Saved definitions use host/port, database, username, authentication database
(default admin), mechanism, replica set and read preference. DNS SRV selects
`mongodb+srv` and cannot use an explicit port or SSH tunnel. Enter a host, not a
URI: passwords are stored only in the Keychain, never in saved URI text.

Scope and connect-from target/this Mac/SSH tunnel follow existing saved
connections. Tunnels force `directConnection=true` and connect only to their
local forward.

**TLS** ([#207](https://github.com/filipac/runlet/issues/207)), under Advanced, like
SQL's TLS options (#140): **Off**, **Verify CA** (the CA only,
`tlsAllowInvalidHostnames`), or **Verify CA and host name**. The driver always
checks the certificate, against the **CA certificate** file when one is set, else
the system's trust store; verification is never turned off. A **client certificate**
and **client key** are for servers that require one, and for X.509: a PEM with both
can go in Client certificate alone; two files are combined into a private (0600)
temporary file that the runner removes when it ends. Encrypted keys aren't
supported. Files are paths where the connection opens (this Mac, or the target);
one that isn't readable there is named before connecting. Through a tunnel the
driver connects to 127.0.0.1: Verify CA and host name needs a certificate that
names it; Verify CA doesn't. SRV turns TLS on by default.

**X.509 (client certificate)** authentication (`MONGODB-X509`, against
`$external`) uses the TLS client certificate: TLS must be on with one. Leave the
password empty; the user name is optional (the certificate's subject).

**Replica sets.** With a replica set name, the driver discovers the members from
the host and reads where the read preference says (primary, primaryPreferred,
secondary, secondaryPreferred, nearest). A tunnel reaches one member only, with a
direct connection.

**SRV** (`mongodb+srv`) is resolved by the driver when it connects; it needs DNS
SRV and TXT records, so Runlet's tests check the URI and options it builds
without connecting (`MongoTab::clientOptions`), not a live SRV lookup.

The PHP must have `ext-mongodb`. From this Mac, Runlet uses the first PHP, in
this order, that has it (read when Runlet looks for PHP, not on each run, #184): **Runlet's own PHP** (Settings ▸ PHP; build
php-8.5.8-r3 and later include mongodb 2.5.3,
[#212](https://github.com/filipac/runlet/issues/212)), the default PHP from
Settings ▸ PHP, the PHP Runlet picks automatically, then every other installed PHP
(including Herd). An older build of Runlet's PHP (r2) has no mongodb, so it is
skipped until you click **Update** in Settings ▸ PHP. With none, the run says so
and points to Settings ▸ PHP. Test Connection names the PHP that opened it. On a
target, a missing extension suggests **Connect from this Mac** or installing it
there.

Application connections use Laravel MongoDB's `DB::connection(name)` and
`getClient()->getManager()` (laravel-mongodb 5.2 and later; `getMongoClient()` on
older versions). **Default connection (mongodb)** uses Laravel's
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

## Server section

The Database pane has **Collections** and **Server**, like the SQL pane's Tables
and Server (#150) and Redis's Keys and Server
([#207](https://github.com/filipac/runlet/issues/207)). **Read Server Details**
reads the server the tab's reads go to, in a fresh runner: a `serverStatus`
summary (version, uptime, connections, memory, storage engine, operation counters)
with the replica set state `hello` reports (anyone may read it), and the server's
operations from `$currentOp`: opid, kind, namespace, running time, client, users,
application name, and the command, shortened and scrubbed of credentials. A filter
narrows them; **Hide Runlet's** hides operations Runlet's runs tagged. Without the
inprog privilege, the list has the user's own operations, and says so. The panel's
own read is marked "(this panel)"; the server's own threads (Checkpointer, …) are
marked "server thread". Nothing reads by itself; production asks before every
read; a refresh interval (5, 15 or 60 s) is off by default and never offered on
production, and stops when the section hides.

**Kill…** on an operation always asks first, on every connection, in the shared
danger sheet: it names the operation, its kind and namespace, client, user and
running time, and the connection, and shows the command. The panel's own read and
server threads are refused. The confirmed `killOp` runs in a fresh runner, which
checks that it reached the server the list came from, that the operation is still
the one listed (same namespace and kind), and that it isn't Runlet's own. The
outcome shows under the button row and in the Run Log.

## Stop

Every operation a MongoDB tab sends carries `comment: "runlet:<run id>"` (MongoDB
4.4 and later) and runs on one selected server
([#207](https://github.com/filipac/runlet/issues/207)), like SQL tabs' #144. On
**Stop**, a second short runner opens the same connection (an application
connection by booting the application again; a saved one with its password on
stdin), checks it reached the same server (its process id), finds this user's
operations with that tag with `currentOp`, refuses another user's, sends `killOp`,
and watches them end; then the runner is stopped as before. Stop never asks, on
production either. The output shows the grey "Interrupted by Stop." line and
"Killed the operation on the server (killOp 4711)."; when the operation had already
finished, or Runlet couldn't kill it, it says that instead. It works on the target,
from this Mac, and through an SSH tunnel, and for Load More's pages. A write may
have taken effect before it was killed.

## Snippets

Project snippets of MongoDB tabs are `.runlet/snippets/*.mongodb` files
([#207](https://github.com/filipac/runlet/issues/207)), and personal snippets of
MongoDB tabs use the same text: a leading block of `//` lines with metadata, then
one JSON query.

```
// @title Paid orders of a customer
// @description The newest first
// @connection Documents (saved)
// @input string $customer "Customer" = "Customer 3"
// @input int $limit "How many" = 10

{
  "collection": "orders",
  "operation": "find",
  "filter": { "customer.name": { "$input": "customer" }, "status": "paid" },
  "sort": { "placed_at": -1, "_id": 1 },
  "limit": { "$input": "limit" }
}
```

- `@title` (or `@label`, as PHP and SQL snippets call it) and `@description` may
  continue on following `//` lines; `@connection` works as for SQL snippets (#149):
  a bare name, or `Name (saved)` for a saved connection only.
- `@input` lines are [snippet inputs](snippet-inputs.md) (`string`, `int`, `float`,
  `bool`, labels, defaults, choices). Their values fill `{"$input": "name"}`
  placeholders **as JSON values**: a string quoted and escaped, a number, true or
  false, never spliced as text. A placeholder written inside a string stays text,
  and the query keeps its layout and key order. The form previews the JSON each
  placeholder becomes.
- The block is the first run of `//` lines and counts only with one of these tags.
  Opening a snippet opens a MongoDB tab on its connection, with the query only;
  nothing runs. Saving a MongoDB tab to the project writes this format; copying a
  project snippet to personal snippets keeps its `@input` lines.
- `.redis` files ([#205](https://github.com/filipac/runlet/issues/205)) use the same
  keys after `#` (`DatabaseSnippetHeader` reads both); see
  [project snippets ▸ Redis snippets](project-snippets.md#redis-snippets).

## Safety and current scope

Read-only checks in both app and runner refuse insert/update/delete/replace,
drop, index creation and pipelines containing `$out`/`$merge`. MongoDB has no
per-session read-only mode: use read-only database roles for server enforcement.
`drop`, unfiltered `deleteMany` and unfiltered `updateMany` always ask first, on
every connection, in the same confirmation as Redis's dangerous commands: it names
the operation, the collection, the database and the connection, and shows the
query's line and text. Production asks again after it.

`dropDatabase` ([#207](https://github.com/filipac/runlet/issues/207)) is written
`{"operation": "dropDatabase", "database": "shop"}`. The name must be the
connection's database (the app checks a saved connection's before asking, the
runner every connection's); admin, local and config are refused. It always asks in
the danger sheet, which names the database and the connection; production asks
again after it; read-only refuses it. Neither `drop` nor `dropDatabase` asks to type
the name in the sheet, consistent with Redis's `FLUSHALL`: naming the database in
the query is that check.
Production asks separately for every query/metadata read; PHP's grace does not apply.

Saved runs use the plain bootstrap and stdin-only credentials. Passwords and
MongoDB URI userinfo are scrubbed from results. Driver failures emit generic
messages and a numeric code, with no arguments or previous exception. MCP cannot
run these tabs or access saved definitions/passwords. A compromised target can
still inspect its process memory, as described by the database security model.

History and snippets retain connection references, not definitions. The
Connection Manager lists MongoDB runs and Load More's pages; Stop kills the
operation on the server first (see [Stop](#stop)). Reads keep their 25-second
server limit.

Runlet's own PHP has ext-mongodb since build r3
([#212](https://github.com/filipac/runlet/issues/212)). Not done: a mongosh-like
query subset ([#220](https://github.com/filipac/runlet/issues/220), optional).

## Validation

The `mongo:7` fixture binds a random loopback port in the databases profile.
Start only it with `docker compose -f Tests/Fixtures/docker/compose.yml --profile
databases up -d mongo`. `scripts/setup-fixtures.sh databases` prints
`RUNLET_TEST_MONGODB='mongodb://127.0.0.1:PORT|runlet|runlet-fixture'`.
Run `scripts/test.sh full --filter Mongo` with that variable set (it runs the tests in
parallel, with an empty `SSH_AUTH_SOCK`; see [validation.md](validation.md#package-tests)).
Live tests use only `p191_`, `p207_`, and `p217_` databases and collections, so they run
alongside the other live suites.

[#207](https://github.com/filipac/runlet/issues/207) adds two `mongo:7` services to
the databases profile: `mongo-tls` (TLS required with the shared throwaway
certificates, `RUNLET_FIXTURE_TLS`; an X.509 user for the fixture's client
certificate `CN=runlet-fixture-client`) and `mongo-rs` (the single-node replica set
`rs0`, announced and published as 127.0.0.1:27207, initiated by the script). The
script prints `RUNLET_TEST_MONGODB_TLS` and `RUNLET_TEST_MONGODB_RS`, with
`RUNLET_TEST_TLS` for the certificates. The suites:

- `MongoServerLiveTests`: Stop kills the operation (a correlated `$lookup` over
  10,000 documents) on the target, from this Mac, and through the SSH fixture's
  tunnel; the Server section's report, Kill Op's refusals and kill.
- `MongoTLSLiveTests`: TLS verified against the CA (and Verify CA), refused with
  another CA, without TLS, or with a missing file; X.509 with two files and one PEM,
  and the panel as that user; TLS through the tunnel; replica-set discovery and read
  preferences; the SRV and TLS options without connecting.
- `MongoLaravelLiveTests`, with `RUNLET_TEST_LARAVEL_MONGODB` set to a Laravel
  application with `mongodb/laravel-mongodb` whose `mongodb` connection reaches the
  fixture: a scratch copy of `Tests/Fixtures/laravel-app` after `composer require
  mongodb/laravel-mongodb` and a `mongodb` entry in `config/database.php` (never
  committed). It's skipped, saying so, without it.
- `MongoBuilderLiveTests` ([#217](https://github.com/filipac/runlet/issues/217)): queries the
  query builder writes (every filter operator and group, typed values, projection, sort, skip
  and limit, the stage cards, the update operators) run as written, in `p217_tests`; it also
  checks [#228](https://github.com/filipac/runlet/issues/228) (find's projection and sort).
- Unit tests: `MongoPagingTests`, `MongoServerTests`, `MongoDropDatabaseTests`,
  `MongoSnippetsTests`, and the query builder's `MongoJSONTests`, `MongoBuilderValueTests`,
  `MongoBuilderFilterTests`, `MongoBuilderStageTests`, `MongoBuilderUpdateTests`,
  `MongoQueryBuilderTests` (round trips of hand-written queries), `MongoBuilderTextTests`, and
  `MongoBuilderResultCellTests`. `DatabaseDangerTests` covers the shared confirmation's Redis and
MongoDB wording and the MongoDB picker's family filter. App snapshots use a scratch
`RUNLET_DATA_DIR` and the Debug steps `mongo-tab`, `mongo-explorer`,
`mongo-sample:<collection>`, `mongo-next-page` (Load More), `mongo-confirm:yes|no`,
`mongo-menu:<collection>`, `mongo-state`, and for #207 `mongo-section:collections|server`,
`mongo-server`, `mongo-kill:runlet|<opid>`, `mongo-kill-confirm:yes|no`,
`mongo-server-state`, and `db-field:mongoAuth=<mechanism>`, and for #217 the
`mongo-builder…` steps (`MongoBuilderDebugSteps`: open, read, set a query as if built in the
forms, Start from Collection, a burst of changes, the undo check, Filter by This Value, scroll);
`scripts/mongo-builder-screenshots.py` seeds `p217_shop` and takes the builder's screenshots
with these checks. No XCUITest runs.
