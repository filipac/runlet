# Redis tabs

A Redis tab ([#190](https://github.com/filipac/runlet/issues/190)) runs Redis commands, one per line, on your application's own Redis connection or on a Redis connection you saved, and shows each reply as a structured card: strings with the [string viewers](string-viewers.md), hashes, lists, sets, sorted sets with scores, and streams as tables, and errors in red. The Database pane becomes a **key browser** (SCAN with a pattern, never `KEYS`) and a **server panel** (INFO and the connected clients). Nothing runs by itself, dangerous commands always ask, and production asks before every run.

Redis tabs work like [SQL tabs](sql-tabs.md): the same saved connections (with a `Redis` kind), Connect From (the target, this Mac, an SSH tunnel), read-only and environment marking, Run History and snippets that remember the connection, and the [Connection Manager](connections.md).

![A Redis tab with string, hash, list, sorted-set, and error replies](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-190/redis-tab.png)

## Creating a Redis tab

- **File ▸ New Redis Tab** opens an empty Redis tab on the current tab's target.
- **Switch to Redis** in a tab's context menu turns any tab into a Redis tab (and **Switch to PHP** back). A connection of another kind (an SQL connection) doesn't carry over.
- `.redis` files open as Redis tabs, and **Save As** saves a Redis tab as a `.redis` file.

The tab gets a red **REDIS** badge and a Redis bar above the editor: the connection, **Run All**, **In a Transaction**, and what ⌘R does.

## Running commands

Type one command per line, quoted the way `redis-cli` quotes: `SET greeting "hello world"`, `'single quotes'` (with `\'`), and in double quotes `\n`, `\r`, `\t`, `\"`, `\\`, and `\xHH` for any byte, so binary values survive. A line that starts with `#` is a comment.

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

![The key browser with types, TTLs, and memory usage](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-190/redis-keys.png)

- Pick the **database** (the menu lists `CONFIG GET databases`' count, with the number of keys of each database that has some), a **pattern** (`SCAN`'s `MATCH`: `*`, `?`, `[ab]`), and optionally a **type**.
- **Scan** reads one page with `SCAN … COUNT 200` (never `KEYS`), with each key's type and TTL; **Load More** continues from the cursor until the scan is complete. A `SCAN` may return a key twice, and keys added meanwhile may be missed.
- A key's context menu: **Open Value** (also a double-click) reads it by its type, at most a page of elements (`GET`; `HSCAN` for a hash and `SSCAN` for a set, never one call for a huge key; `LRANGE`, `ZRANGE … WITHSCORES`, `XRANGE`), and shows the reply card in a sheet; **Memory Usage** reads `MEMORY USAGE`, `OBJECT ENCODING`, and the length; **Copy Key**; **Insert Command** puts the command that reads the key on its own line in the tab, without running it.

![Open Value on a stream](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-190/redis-value.png)

Everything reads on demand only, and production asks first.

## Server panel

**Read Server Details** reads `INFO` and `CLIENT LIST`: the version, mode, uptime, clients, and memory in one line, the INFO sections, and every connected client with its address, name, user, database, last command, age, idle time, and whether it's blocked.

![The server panel with a blocked client](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-190/redis-server.png)

**Kill…** on a client asks first, always, on every connection. A fresh runner then checks that it reached the same server (INFO's `run_id`), that the client isn't the panel's own or its own, and that it's still the client listed (same address), and sends `CLIENT KILL ID`. The outcome shows in the panel and in the tab's Run Log.

![Kill Client's confirmation](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-190/redis-kill.png)

## History and snippets

Run History keeps a Redis run's commands (passwords as `•••`) and its connection: an application connection's name, or a saved connection's name ([#149](https://github.com/filipac/runlet/issues/149)). Opening an entry or a Redis snippet opens a Redis tab on that connection. Snippets saved from a Redis tab are Redis snippets, with a **REDIS** badge and a connection picker.

## Not yet

- Pub/Sub and `MONITOR` streaming (refused today).
- Redis Cluster and Sentinel connections.
- Project snippets as `.redis` files in `.runlet/snippets`.
- Completion of commands and keys.

## Validation

- `RedisTabTests` (RunletCore): `redis-cli` quoting (escapes, bytes, broken quotes), what Run and Run All send (caret, selection, comments), passwords redacted in typed commands, the command table (reads, writes, connection, transaction, streaming, unknown, dangerous) and read-only refusals, every reply type and how it's shown, Load More's next command and merged pages, the generated PHP (byte-exact, passwords marked), the `redis` connection kind (validation, normalization, encoding), family gating of pickers and connection resolution, tab state and history, and the TablePlus mapping. `TablePlusImportTests` imports the fixture's Redis row.
- `RedisCommandTableTests` (RunletExecution, host PHP): the runner's command lists match the app's.
- `RedisLiveTests` (RunletExecution, the Redis fixture: `scripts/setup-fixtures.sh databases` prints `RUNLET_TEST_REDIS` and `RUNLET_TEST_REDIS_TLS`): a saved connection from the target and from this Mac with every reply type and another database; Run All stopping at an error and `MULTI`/`EXEC`; read-only and streaming refusals before anything is sent; passwords never in any event (an echoed password, a typed `AUTH`, a wrong password); TLS with the fixture's CA (verified, a wrong CA refused, Require) and an ACL user Redis itself limits to reads; the key browser's SCAN pages, Open Value, and Memory Usage; the server panel and Kill Client's refusals; Stop ending a `BLPOP 0` (Redis drops the blocked client) and Kill Client ending another; application connections through a driver's callable and Laravel's `Redis::connection()` with phpredis.
- The Debug app with a scratch data folder (see `RedisDebugSteps`): the screenshots above.
