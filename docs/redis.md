# Redis tabs

A Redis tab ([#190](https://github.com/filipac/runlet/issues/190)) runs Redis commands, one per line, on your application's own Redis connection or on a Redis connection you saved, and shows each reply as a structured card: strings with the [string viewers](string-viewers.md), hashes, lists, sets, sorted sets with scores, and streams as tables, and errors in red. The Database pane becomes a **key browser** (SCAN with a pattern, never `KEYS`) and a **server panel** (INFO and the connected clients). Nothing runs by itself, dangerous commands always ask, and production asks before every run.

Redis tabs work like [SQL tabs](sql-tabs.md): the same saved connections (with a `Redis` kind), Connect From (the target, this Mac, an SSH tunnel), read-only and environment marking, Run History and snippets that remember the connection, and the [Connection Manager](connections.md).

![A Redis tab with string, hash, list, sorted-set, and error replies](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-190/redis-tab-v2.png)

## Creating a Redis tab

- **File ▸ New Redis Tab** (also in the command palette) opens an empty Redis tab on the current tab's target.
- **Switch to Redis** in a tab's context menu turns any tab into a Redis tab (and **Switch to PHP** back). A connection of another kind (an SQL connection) doesn't carry over.
- `.redis` files open as Redis tabs, and **Save As** saves a Redis tab as a `.redis` file.

The tab gets a red **REDIS** badge and a Redis bar above the editor: the connection, **Run All**, **In a Transaction**, and what ⌘R does.

## Running commands

Type one command per line, quoted the way `redis-cli` quotes: `SET greeting "hello world"`, `'single quotes'` (with `\'`), and in double quotes `\n`, `\r`, `\t`, `\"`, `\\`, and `\xHH` for any byte, so binary values survive. A line that starts with `#` is a comment. The editor [completes](#completion) commands, options, and key names, and hovering a command shows its syntax.

- **⌘R** runs the command on the caret's line, or the selected one. On a blank or comment line it runs the next command below (or the last one above). A selection that holds several commands is refused: Run runs one.
- **Run All** (⌥⇧⌘R, or the bar's button) runs every command of the selection, or of the tab, in order on one connection. It **stops at the first error**, says which commands didn't run, and that the ones before stay (Redis has no rollback).
- **In a Transaction** wraps Run All in `MULTI`/`EXEC`: Redis queues every command, then runs them all; each command's reply comes from `EXEC`. A command Redis refuses to queue (a syntax error) discards the whole transaction, so nothing runs. Typed `MULTI`, `EXEC`, `DISCARD`, `WATCH`, and `UNWATCH` are refused while it's on; turn it off to run your own transaction.
- `SELECT n` switches the database for the rest of the run; the card says which database each reply came from.

### Replies

| Reply | Shown as |
| --- | --- |
| Bulk string | The value, with the string viewers (JSON, URL-encoded, Base64, …); bytes that aren't UTF-8 show as hex |
| Integer, double, boolean | `(integer) 5`, `(double) 1.5`, `(true)` |
| Status | `OK`, `PONG`, in green |
| Nil | `(nil)` |
| `HGETALL`, `HSCAN`, `CONFIG GET`, `HRANDFIELD … WITHVALUES` | A field / value table |
| `ZRANGE … WITHSCORES` (and `ZRANGEBYSCORE`, `ZREVRANGE`, `ZPOPMIN`, `ZPOPMAX`, `ZSCAN`, …) | A member / score table, sorted by number |
| `SMEMBERS`, `SINTER`, `SUNION`, `SDIFF`, `SSCAN`, RESP3 sets | A member table |
| `LRANGE` and other lists | A value table, numbered from the range's start |
| `XRANGE`, `XREVRANGE`, `XREAD` | An entry table: the id and one column per field |
| `SCAN` | A key table and the next cursor |
| Nested replies (`COMMAND INFO`, `XINFO`, …) | A value tree |
| Error | The error, in red; Run All stops there |

Tables have the output's filter, **Copy CSV**, **Export CSV…**, and **Open in Window**. **Copy** on a card copies `redis-cli`'s text of the reply.

### Large replies and Load More

A reply keeps at most the **rows per page** of Settings (1,000 by default) elements per level (twice as many for field/value and member/score pairs), a top-level string 512 KiB, a nested string 8 KiB, and 8 MiB in all; the card says how many elements weren't kept. Runlet still reads the whole reply from Redis, so a huge `LRANGE 0 -1` is slow; read big keys in pages:

- `SCAN`, `HSCAN`, `SSCAN`, `ZSCAN`: **Load More** runs the command again from the reply's cursor and adds the rows to the card, until the cursor is `0`.
- `LRANGE`, `ZRANGE`, and `ZREVRANGE` by index: when the cap cut the reply, **Load More** reads the elements after the ones shown.

Each page runs on the same connection, and production asks first.

## Connections

The bar's connection menu offers the application's Redis connections and your saved Redis connections; an SQL tab's menu never offers a Redis connection, nor a Redis tab's an SQL one.

### The application's connections

Like SQL tabs, the default is the application's own connection, which needs no credentials from Runlet. The run boots the application on its target and asks the [driver](drivers.md#redis-connections) for the connection:

- **Laravel**: `Redis::connection('<name>')`, the default connection or a key of `config('database.redis')` (`default`, `cache`, …), which the menu lists after a run. Commands are sent raw: through phpredis's `rawCommand()` or Predis's `executeRaw()`, so the connection's key prefix and serializer don't apply. A Redis Cluster connection is refused (Cluster is a later feature).
- **A project driver** can return its own connection from `redisConnection()`: a phpredis `Redis`, a Predis client, a Laravel connection, or a callable.

### Saved Redis connections

**New Connection…** in a Redis tab's menu starts a connection of the **Redis** kind (or choose **Redis** as the driver in any connection editor). It has:

- **Host** and **Port** (6379 by default), or a **Unix socket** (Advanced);
- **Database number** (0 by default);
- **User (ACL)**, optional, and a **Password**, which is stored only in the macOS Keychain;
- **TLS** (Advanced): Off, Require (encrypted, the certificate isn't checked), or Verify CA and host name, with an optional CA file, client certificate, and client key;
- **Connect from** the target's PHP, this Mac, or this Mac through an SSH profile's tunnel; **Read-only**; the **environment** and **colour**.

![The connection editor with the Redis kind and Test Connection's result](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-190/redis-editor.png)

A saved Redis connection is opened by **Runlet's own Redis client** in the runner: plain PHP sockets (`tcp://`, `tls://`, `unix://`), `AUTH` (password, or ACL user and password), and `SELECT`. No PHP extension is needed, so it works with the target's PHP, Runlet's PHP, and any PHP 7.4 or later on this Mac; TLS needs PHP's `openssl`. **Test Connection** sends `PING` and reports the Redis version, the database, the user, the round trip, and whether the connection is encrypted. The run boots no project code.

**Import from TablePlus** (#188) imports TablePlus's Redis connections as saved Redis connections: host, port, database number, user, TLS (as Require; choose Verify in Advanced), SSH, and the environment tag.

## Safety

- **Nothing runs by itself.** Opening, importing, or restoring a Redis tab never runs it, Redis tabs never auto-run, and AI clients can't run them (`run_php` runs PHP only, and the app refuses to run a Redis tab's text as PHP).
- **Dangerous commands always ask**, on every connection, production or not, naming the command and what it does: `FLUSHALL`, `FLUSHDB`, `KEYS` (use `SCAN` or the key browser), `DEBUG`, `SHUTDOWN`, `SAVE`, `CONFIG SET`, `CONFIG REWRITE`, `SCRIPT FLUSH`, `CLIENT KILL`, `MIGRATE`, `SWAPDB`, `REPLICAOF`/`SLAVEOF`, `FAILOVER`, `MODULE LOAD`/`UNLOAD`, `ACL SETUSER`/`DELUSER`, `FUNCTION FLUSH`/`DELETE`, and `CLUSTER RESET`/`FAILOVER`/`FORGET`/`FLUSHSLOTS`.

  ![The dangerous-command confirmation for FLUSHDB](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-190/redis-danger.png)
- **Production asks before every run**, every Load More page, and every key browser and server panel read. The confirmation shows the commands (passwords as `•••`), warns about those that can write, and says whether Run All runs in `MULTI`/`EXEC`.
- **Read-only connections.** Redis has no read-only session, so Runlet refuses, before anything is sent, every command that isn't a read, connection state (`AUTH`, `SELECT`, `PING`, …), or transaction control, and every command it doesn't know: in the app (a built-in table derived from Redis's command flags), and again in the runner, which also asks the server's `COMMAND INFO` and refuses what the server flags as a write. One refused command refuses the whole Run All. For a guarantee, connect as an ACL user that can only read (`+@read`).

  ![A read-only connection refusing SET](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-190/redis-readonly.png)
- **Streaming commands are refused**: `SUBSCRIBE`, `PSUBSCRIBE`, `SSUBSCRIBE`, `MONITOR`, `SYNC`, `PSYNC`, and `CLIENT REPLY` (a Redis tab reads one reply per command; use `redis-cli` for those).
- **Passwords.** A saved connection's password lives only in the Keychain and reaches PHP only inside the runner request on standard input; the runner forgets it once connected and replaces it with `•••` in everything it reports. A password you type (`AUTH`, `HELLO … AUTH`, `MIGRATE … AUTH`/`AUTH2`, `ACL SETUSER … >secret`, `CONFIG SET requirepass|masterauth`) shows as `•••` in Run History, the output, confirmations, the Connection Manager, and AI clients' snippet tools, and the runner scrubs it from its events.
- **Stop** ends the runner process, which closes its connection: Redis drops a client blocked in `BLPOP`, `BRPOP`, `XREAD BLOCK`, `WAIT`, …, at once. Runlet doesn't also send `CLIENT KILL` (as SQL tabs send `KILL QUERY`, #144): a closed connection is enough for a blocked client, and a long-running command (a Lua script, `KEYS` on a large database) can't be interrupted by `CLIENT KILL` either.

## Key browser

With a Redis tab selected, the **Database** pane (⇧⌘B) shows the tab's connection's **Keys** and **Server**.

![The key browser with types, TTLs, and memory usage](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-190/redis-keys-v2.png)

- Pick the **database** (the menu lists `CONFIG GET databases`' count, with the number of keys of each database that has some), a **pattern** (`SCAN`'s `MATCH`: `*`, `?`, `[ab]`), and optionally a **type**.
- **Scan** reads one page with `SCAN … COUNT 200` (never `KEYS`), with each key's type and TTL; **Load More** continues from the cursor until the scan is complete. A `SCAN` may return a key twice, and keys added meanwhile may be missed.
- A key's context menu: **Open Value** (also a double-click) reads it by its type, at most a page of elements (`GET`; `HSCAN` for a hash and `SSCAN` for a set, never one call for a huge key; `LRANGE`, `ZRANGE … WITHSCORES`, `XRANGE`), and shows the reply card in a sheet; **Memory Usage** reads `MEMORY USAGE`, `OBJECT ENCODING`, and the length; **Copy Key**; **Insert Command** opens the [Command Builder](#command-builder) with the key filled in: the read for its type (`GET`, `HGETALL`, `LRANGE 0 -1`, `SMEMBERS`, `ZRANGE 0 -1 WITHSCORES`, `XRANGE - +`), `TTL`, `EXPIRE…`, `PERSIST`, `DEL`, or `RENAME…`. Open Value's **Insert Command** puts the paged read on its own line in the tab. Neither runs anything.

![Open Value on a stream](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-190/redis-value-v2.png)

Everything reads on demand only, and production asks first.

## Command Builder

The **Command Builder** ([#218](https://github.com/filipac/runlet/issues/218)) helps with command names, argument order, and options. Everything it builds is written into the tab as text, so the editor always shows exactly what runs, and the builder itself never runs anything. Open it with the Redis bar's **Builder** button, **View ▸ Show Builder**, or ⌥⌘B (the same command opens a MongoDB tab's [Query Builder](mongodb.md#query-builder), [#217](https://github.com/filipac/runlet/issues/217)); it sits beside the editor (drag its edge to resize it).

![The command list, grouped by data type, with write and dangerous commands marked](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-218/redis-builder-picker.png)

- **The command list**: search by name or summary (`zrange`, `expire`, `stream`); commands are grouped by data type (strings, hashes, lists, sets, sorted sets, streams, keys, server), and marked **WRITE**, **DANGEROUS**, or **BLOCKS** from the same table every run is checked with. **Another command…** gives a form of raw arguments for a command Runlet has no syntax for.
- **The form** follows the command's syntax (shown under its name, as Redis's docs write it): a field per value, check boxes for options (`NX`, `GET`, `REV`, `WITHSCORES`), a choice where options exclude each other (`EX | PX | EXAT | PXAT | KEEPTTL`, `BYSCORE | BYLEX`), groups you turn on (`LIMIT offset count`, `XADD`'s trimming), and rows you add and remove for repeated arguments (`HSET` field/value pairs, `ZADD` score/member pairs, `XREAD STREAMS` key/id pairs). `numkeys` is counted for you. Numbers are checked; durations show their unit, common values, and what they come to (`3600` = 60 min). An empty field is left out; a field's **Empty String** writes `""`.
- **Key names** complete from the key browser's last scan of the tab's connection. Typing never reads anything from Redis.
- **The preview** is the exact line, quoted the way the tab reads it (`"two words"`, `\n` for a line break), with how Runlet will treat it (read, write, dangerous, or refused on a read-only connection) and what's missing.
- **Insert** puts the line on a new line after the caret's (on the caret's line when it's blank); **Replace Line** puts it in place of the caret's command (its indentation stays). Each is one edit: **Undo** takes it back. Then ⌘R runs it with the usual read-only refusals, dangerous-command confirmations, and production rules.

| ZRANGE with BYSCORE, REV, LIMIT, and WITHSCORES | HSET with several pairs |
| --- | --- |
| ![ZRANGE's form](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-218/redis-builder-form-zrange.png) | ![HSET's form](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-218/redis-builder-form-hset.png) |

**Read Line** (the builder's text-view button, and opening the builder) reads the command on the caret's line into the form. Options can be in any order and case (`set k v ex 60 nx` reads as `SET k v NX EX 60`); words the form can't place stay as raw arguments, written after the others, so nothing is lost; a command typed halfway fills what it has. A line the builder can't read (a quote that isn't closed, bytes that aren't UTF-8) leaves the form fresh and the text untouched.

![Built commands inserted into the tab and run](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-218/redis-builder-inserted-ran.png)

The builder knows the syntax of about 150 commands: the common ones of every data type (including `ZRANGE`'s `BYSCORE`/`BYLEX`/`REV`/`LIMIT`, `XADD`, `XRANGE`, `XREAD`, `XINFO`, and Redis 7.4's hash-field expiry), `SCAN`, `HSCAN`, `SSCAN`, and `ZSCAN`, and the server's commands such as `INFO`, `DBSIZE`, `MEMORY USAGE`, `CONFIG GET`, and `SLOWLOG GET` (`RedisCommandSpecs` in RunletCore, shared with completion, [#206](https://github.com/filipac/runlet/issues/206)).

## Completion

Redis tabs complete as you type ([#206](https://github.com/filipac/runlet/issues/206)): two characters of a word show what fits there, and Show Completions (⌃Space or ⌥Esc) shows the list anywhere. Return or Tab inserts the selected item; Escape closes the list. **Typing never sends anything to Redis**: the list comes from Runlet's command table and from key names Runlet already read.

- **Commands** at the start of a line, with their arguments as Redis's docs write them (`ZRANGE` shows `key start stop [BYSCORE | BYLEX] [REV] [LIMIT offset count] [WITHSCORES]`), their summary under the list, and **WRITE**, **DANGEROUS**, and **BLOCKS** marks, as the command builder shows them. Commands Runlet has a syntax for come first; the other commands of the table every run is checked with follow, with how Runlet treats them. Streaming commands (`SUBSCRIBE`, `MONITOR`, …) aren't offered: Redis tabs refuse them. The list follows your case (`zr` → `zrange`).
- **Subcommands**: a container (`CLIENT`, `CONFIG`, `XINFO`, `MEMORY`, `OBJECT`, `SLOWLOG`, …) inserts its name and a space and lists its subcommands (`CLIENT LIST`, `CLIENT KILL`, `XINFO STREAM`, …).
- **Options** the command's syntax allows at the caret, in the syntax's order: `ZRANGE key 0 -1` offers `BYSCORE`, `BYLEX`, `REV`, `LIMIT`, and `WITHSCORES`; `SET key value` offers `NX`, `XX`, `GET`, `EX`, `PX`, `EXAT`, `PXAT`, `KEEPTTL`; `SCAN 0` offers `MATCH`, `COUNT`, `TYPE`. An option already used, or one the other excludes (`NX` after `XX`), isn't offered again, and where a value goes (`SET key |`, where `NX` would be the value) none is. Each option shows its syntax (`EX seconds`, `LIMIT offset count`).
- **Values** Runlet suggests: `INFO`'s sections, `SCAN … TYPE`'s types, and common `CONFIG GET` parameters.
- **Key names** where a key goes (`GET`, `HGETALL`, `DEL a b`, `RENAME a`, `ZUNIONSTORE dst 2 a`, `XREAD STREAMS`, `MEMORY USAGE`, …), only from what Runlet already read for the tab's connection and database: the [key browser](#key-browser)'s last scan, Load Keys for Completion, and the keys this tab's replies listed (`SCAN`, `KEYS`, `RANDOMKEY`). Keys of the command's type come first (`HGETALL` lists hashes first) when the key browser read their type. A name is inserted quoted the way the tab reads it (`"my key"`); inside a quote you opened, it's escaped for that quote and the caret goes after the closing one.
- **Load Keys for Completion…**, the list's last item in a key position (Show Completions shows it when nothing else fits), runs **one** `SCAN 0 MATCH <typed prefix>* COUNT 1000` in the tab's database (the prefix's `*`, `?`, `[`, `]`, and `\` escaped), key names only (no `TYPE`, `PTTL`, or `INFO`), and shows the list again with them. Production asks first. When that SCAN didn't reach the end of the database, the item becomes **Load More Keys for Completion…** and continues from its cursor. It isn't offered once every key with the prefix is known: an earlier load reached the end, or the key browser's complete scan of a pattern that covers it (`*`, `user:*`). Loaded names stay in memory while Runlet runs; the Run Log notes each load.

The tab's database is the saved connection's database number; for an application connection, the database of the tab's last reply (0 before any).

| Commands, with syntax and marks | Subcommands |
| --- | --- |
| ![Commands starting with ZR](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-206/redis-complete-commands.png) | ![CLIENT's subcommands](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-206/redis-complete-client.png) |
| **Options** | **Keys from the key browser's scan, hashes first** |
| ![ZRANGE's BY options](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-206/redis-complete-options.png) | ![Keys after HGETALL](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-206/redis-complete-keys.png) |
| **Load Keys for Completion** | **…and the keys it read** |
| ![The Load Keys for Completion item](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-206/redis-complete-load-offer.png) | ![Keys loaded for completion](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-206/redis-complete-loaded.png) |

**Hover** a command (or a subcommand) to see its syntax, its summary, its group, and how Runlet treats it.

![Hovering ZRANGE](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-206/redis-hover.png)

## Server panel

**Read Server Details** reads `INFO` and `CLIENT LIST`: the version, mode, uptime, clients, and memory in one line, the INFO sections, and every connected client with its address, name, user, database, last command, age, idle time, and whether it's blocked.

![The server panel with a blocked client](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-190/redis-server.png)

**Kill…** on a client asks first, always, on every connection. A fresh runner then checks that it reached the same server (INFO's `run_id`), that the client isn't the panel's own or its own, and that it's still the client listed (same address), and sends `CLIENT KILL ID`. The outcome shows in the panel and in the tab's Run Log.

![Kill Client's confirmation](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-190/redis-kill.png)

## History and snippets

Run History keeps a Redis run's commands (passwords as `•••`) and its connection: an application connection's name, or a saved connection's name ([#149](https://github.com/filipac/runlet/issues/149)). Opening an entry or a Redis snippet opens a Redis tab on that connection. Snippets saved from a Redis tab are Redis snippets, with a **REDIS** badge and a connection picker.

**Project snippets** ([#205](https://github.com/filipac/runlet/issues/205)) are `.runlet/snippets/*.redis` files: a leading block of `#` lines with `# @title`, `# @description`, `# @connection`, and `# @input`, then commands one per line, so a team can share runbooks through git. Inputs fill `$name` (or `${name}`) in unquoted arguments, and the argument is written back as one quoted Redis argument, so a value never splits it or starts another command. Opening one opens a Redis tab on its connection and never runs it; **Save Snippet to Project…** from a Redis tab writes one. Personal Redis snippets take `# @input` lines too. See [project snippets ▸ Redis snippets](project-snippets.md#redis-snippets).

| The input form | Open Anything |
| --- | --- |
| ![The input form for a Redis snippet](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-205/redis-snippet-inputs-205-dark.png) | ![Redis snippets in Open Anything](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-205/redis-snippet-palette-205.png) |

## Not yet

- Pub/Sub and `MONITOR` streaming (refused today).
- Redis Cluster and Sentinel connections.
- Refining completion from the connected server's `COMMAND DOCS` (commands and modules Runlet's table doesn't know).

## Validation

- `RedisCompletionTests` (RunletCore, #206): commands at the start of a line (syntax, summary, marks, case, refused commands left out), nothing in comments or after a closed quote, containers and their subcommands, the options each position allows (used and excluded ones left out, none where a value goes), suggested values, key positions per command family (strings, keys, hashes, lists, sets, sorted sets with `numkeys`, streams with `STREAMS`, the server's key commands) and positions that aren't, keys of the command's type first and each once, quoting of key names (spaces, quotes, line breaks, backslashes, Unicode; unquoted, in double and single quotes, with the paired closing quote) read back exactly, Load Keys for Completion's item and pattern, the keys known per database, hover, and that completion uses the builder's specs and agrees with the classification table on command names.
- `RedisTabTests` (RunletCore): `redis-cli` quoting (escapes, bytes, broken quotes), what Run and Run All send (caret, selection, comments), passwords redacted in typed commands, the command table (reads, writes, connection, transaction, streaming, unknown, dangerous) and read-only refusals, every reply type and how it's shown, Load More's next command and merged pages, the generated PHP (byte-exact, passwords marked), the `redis` connection kind (validation, normalization, encoding), family gating of pickers and connection resolution, tab state and history, and the TablePlus mapping. `TablePlusImportTests` imports the fixture's Redis row.
- `RedisCommandBuilderTests` (RunletCore, #218): every command spec is in the classification table with the same class; the syntax as Redis's docs write it; the command list's groups and search; form → command line for SET (options), HSET (pairs), ZRANGE (BYSCORE REV LIMIT WITHSCORES), XADD, SCAN, EXPIRE, and numkeys; hand-typed lines of every family reading back into the form and rendering the same line; quoting (spaces, quotes, line breaks, tabs, backslashes, empty strings, Unicode) through the parser; options in any order and case; unplaced words kept raw; lines typed halfway; repeated arguments, `numkeys`, and `STREAMS`; each word's role (command, token, key, value); Insert, Replace Line, and Read Line on the caret's line; the key browser's items by type.
- `RedisCommandTableTests` (RunletExecution, host PHP): the runner's command lists match the app's.
- `RedisLiveTests` (RunletExecution, the Redis fixture: `scripts/setup-fixtures.sh databases` prints `RUNLET_TEST_REDIS` and `RUNLET_TEST_REDIS_TLS`): a saved connection from the target, from this Mac, and through the SSH fixture's tunnel (plain and TLS, to the Compose service name), with every reply type and another database; Run All stopping at an error and `MULTI`/`EXEC`; read-only and streaming refusals before anything is sent; passwords never in any event (an echoed password, a typed `AUTH`, a wrong password); TLS with the fixture's CA (verified, a wrong CA refused, Require) and an ACL user Redis itself limits to reads; the key browser's SCAN pages, Open Value, and Memory Usage; the server panel and Kill Client's refusals; Stop ending a `BLPOP 0` (Redis drops the blocked client) and Kill Client ending another; application connections through a driver's callable and Laravel's `Redis::connection()` with phpredis.
- `RedisLiveTests.loadKeysForCompletionReadsNamesOnly` (#206): Load Keys for Completion's SCAN on the fixture, key names only (no types, TTLs, or INFO), the prefix's glob characters escaped, and a key with a space inserted as completion quotes it runs as that key.
- `RedisLiveTests.builtCommandsRunAsShown` (#218): the lines the builder writes for SET, HSET, ZADD, ZRANGE, XADD, SCAN, EXPIRE, and GET run on the fixture as shown, and a value with spaces, quotes, a line break, a tab, a backslash, and Unicode comes back from Redis exactly.
- `RedisSnippetsTests` (RunletCore, #205): the `#` header (title continuation, `@label`, a comment block without tags staying in the commands, unreadable `@input`s), the same `DatabaseSnippetHeader` as `.mongodb` files, inputs filled as quoted arguments (whole, part of an argument, `${name}`, a quoted part after it), values with spaces, quotes, line breaks, tabs, backslashes, `#`, NUL, and Unicode parsing back to exactly one argument with the value's bytes (also as a command's name), placeholders in quotes, undeclared, or malformed staying text, comment and unreadable lines untouched, line endings kept, every value kind, `.redis` files loading, saving, and reading back the same, personal copies keeping `# @input` lines, and connections resolving by name within the Redis family (`(saved)`, missing).
- The Debug app with a scratch data folder (see `RedisDebugSteps`, `RedisBuilderDebugSteps`, and `RedisCompletionDebugSteps`): the screenshots above; `redis-builder:undo-check` checks that Insert and Replace Line are each one Undo step; `redis-type`, `redis-complete…`, `redis-hover`, and `redis-load-keys` drive completion (typing, the list, hover, and Load Keys for Completion with production's question).
