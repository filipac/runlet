# Redis

A Redis tab runs Redis commands, one per line, on your application's own Redis connection or on a Redis connection you saved. Each reply shows as a structured card: hashes, lists, sets, sorted sets, and streams as tables, strings with the [string viewers](string-viewers.md), and errors in red.

```text
SET greeting "hello world"
HGETALL user:42
ZRANGE leaderboard 0 9 REV WITHSCORES
```

With a Redis tab selected, the Database pane browses keys with `SCAN` (never `KEYS`) and reads the server's details. Nothing runs by itself, dangerous commands always ask, and production asks before every run.

Redis tabs work like [SQL tabs](sql-tabs.md): the same [saved connections](connections.md#saved-connections), opened from the target, from this Mac, or through an SSH tunnel; read-only and environment marking; Run History and snippets that remember the connection; and the [Connection Manager](connections.md#connection-manager).

![A Redis tab after Run All: a string, a hash's fields and values, a list, a sorted set with its scores, and the error that stopped the run](screenshots/redis/replies-light.webp#gh-light-mode-only)
![A Redis tab after Run All: a string, a hash's fields and values, a list, a sorted set with its scores, and the error that stopped the run](screenshots/redis/replies-dark.webp#gh-dark-mode-only)

## Creating a Redis Tab

- Choose **File ▸ New Redis Tab** (also in the command palette). The new tab uses the current tab's target.
- Choose **Switch to Redis** in a tab's context menu, and **Switch to PHP** to go back. A connection of another kind, such as an SQL connection, doesn't carry over.
- Open a `.redis` file. **Save As** saves a Redis tab as a `.redis` file.

The tab has a red **REDIS** badge, and a Redis bar above the editor with the connection, **Run All**, **In a Transaction**, the **Builder** button, and what <kbd>⌘</kbd><kbd>R</kbd> will do.

## Running Commands

Type one command per line, quoted the way `redis-cli` quotes. A line that starts with `#` is a comment:

```text
# Strings with spaces need quotes
SET greeting "hello world"
SET note 'it\'s here'
SET bytes "\x00\xff line one\nline two"
```

Double quotes understand `\n`, `\r`, `\t`, `\"`, `\\`, and `\xHH` for any byte, so binary values survive. Single quotes understand `\'`. The editor [completes](#completion) commands, options, and key names, and hovering a command shows its syntax.

### Running One Command

**Run** (<kbd>⌘</kbd><kbd>R</kbd>) runs the command on the caret's line, or the selected one. On a blank or comment line, it runs the next command below, or the last one above. A selection that holds several commands is refused: Run runs one.

### Run All

**Run All** (<kbd>⌥</kbd><kbd>⇧</kbd><kbd>⌘</kbd><kbd>R</kbd>, or the bar's button) runs every command of the selection, or of the tab, in order on one connection.

It **stops at the first error**, and says which commands didn't run. The commands before the error stay done: Redis has no rollback.

### In a Transaction

The **In a Transaction** checkbox (off by default, saved with the tab) wraps Run All in `MULTI` and `EXEC`. Redis queues every command, then runs them all, and each command's reply comes from `EXEC`.

- A command Redis refuses to queue, such as one with a syntax error, discards the whole transaction, so nothing runs.
- While it's on, typed `MULTI`, `EXEC`, `DISCARD`, `WATCH`, and `UNWATCH` are refused. Turn it off to run your own transaction.

`SELECT n` switches the database for the rest of the run, and the card says which database each reply came from.

## Replies

| Reply | Shown as |
| --- | --- |
| Bulk string | The value, with the string viewers (JSON, URL-encoded, Base64, …). Bytes that aren't UTF-8 show as hex. |
| Integer, double, boolean | `(integer) 5`, `(double) 1.5`, `(true)` |
| Status | `OK`, `PONG`, in green |
| Nil | `(nil)` |
| `HGETALL`, `HSCAN`, `CONFIG GET`, `HRANDFIELD … WITHVALUES` | A field and value table |
| `ZRANGE … WITHSCORES` (and `ZRANGEBYSCORE`, `ZREVRANGE`, `ZPOPMIN`, `ZPOPMAX`, `ZSCAN`, …) | A member and score table, sorted by number |
| `SMEMBERS`, `SINTER`, `SUNION`, `SDIFF`, `SSCAN`, RESP3 sets | A member table |
| `LRANGE` and other lists | A value table, numbered from the range's start |
| `XRANGE`, `XREVRANGE`, `XREAD` | An entry table: the id, and one column per field |
| `SCAN` | A key table, and the next cursor |
| Nested replies (`COMMAND INFO`, `XINFO`, …) | A value tree |
| Error | The error, in red. Run All stops there. |

Tables have the output's filter, **Copy CSV**, **Export CSV…**, and **Open in Window**. **Copy** on a card copies the reply as `redis-cli` would print it.

### Large Replies and Load More

A reply keeps at most the **Rows per page** of **Settings ▸ General ▸ SQL Results** (1,000 by default) elements per level, twice as many for field and value or member and score pairs. A top-level string keeps 512 KiB, a nested string 8 KiB, and the whole reply 8 MiB. The card says how many elements it left out.

Runlet still reads the whole reply from Redis, so a huge `LRANGE 0 -1` is slow. Read big keys in pages instead:

- **`SCAN`, `HSCAN`, `SSCAN`, `ZSCAN`:** **Load More** runs the command again from the reply's cursor and adds the rows to the card, until the cursor is `0`.
- **`LRANGE`, `ZRANGE`, and `ZREVRANGE` by index:** when the limit cut the reply, **Load More** reads the elements after the ones shown.

Each page runs on the same connection, and production asks first.

## Connections

The bar's connection menu offers your application's Redis connections and your saved Redis connections. Choosing one never connects or runs anything.

### The Application's Connections

By default, a Redis tab uses your application's own connection, so Runlet needs no credentials. The run boots the application on its target and asks its [driver](drivers.md#redis-connections) for the connection:

- **Laravel:** `Redis::connection('<name>')`: the default connection, or a key of `config('database.redis')` such as `default` or `cache`, which the menu lists after a run. Commands are sent raw, so the connection's key prefix and serializer don't apply. Redis Cluster connections aren't supported yet.
- **A project driver** can return its own connection from `redisConnection()`: a phpredis `Redis`, a Predis client, a Laravel connection, or a callable.

### Saved Redis Connections

**New Connection…** in a Redis tab's connection menu starts a connection of the **Redis** kind, or choose **Redis** as the driver in any connection editor. Besides the fields every [saved connection](connections.md#saved-connections) has, it has:

| Field | Notes |
| --- | --- |
| **Host**, **Port** | Port 6379 by default. Or a **Unix socket**, under Advanced. |
| **Database number** | 0 by default. |
| **User (ACL)**, **Password** | The user is optional. The password is stored only in the macOS Keychain. |
| **TLS** | Under Advanced: **Off**, **Require** (encrypted, but the certificate isn't checked), or **Verify CA and host name**, with an optional CA file, client certificate, and client key. |

![The connection editor for a saved Redis connection, with its database number, user, and password, and Test Connection's report: the Redis version, the database, the user, and the round trip](screenshots/redis/connection-editor-light.webp#gh-light-mode-only)
![The connection editor for a saved Redis connection, with its database number, user, and password, and Test Connection's report: the Redis version, the database, the user, and the round trip](screenshots/redis/connection-editor-dark.webp#gh-dark-mode-only)

Runlet opens a saved Redis connection with its own small Redis client, so no PHP extension is needed. It works with the target's PHP, Runlet's PHP, and any PHP 7.4 or later on your Mac; TLS needs PHP's `openssl` extension. The run boots no project code.

**Test Connection** sends `PING` and reports the Redis version, the database, the user, the round trip, and whether the connection is encrypted.

[Import from TablePlus](connections.md#import-from-tableplus) brings in TablePlus's Redis connections too: the host, port, database number, user, TLS (as **Require**; choose **Verify CA and host name** under Advanced if you want it), SSH, and the environment tag.

## Command Builder

The **Command Builder** helps with command names, argument order, and options. It writes the command into the tab as text, so the editor always shows exactly what runs, and the builder itself never runs anything.

Open it with the bar's **Builder** button, **View ▸ Show Builder**, or <kbd>⌥</kbd><kbd>⌘</kbd><kbd>B</kbd>. It sits beside the editor; drag its edge to resize it. (In a MongoDB tab, the same command opens the [Query Builder](mongodb.md#query-builder).)

![The Command Builder beside a Redis tab, listing the string commands with their summaries, and WRITE marks on the commands that write](screenshots/redis/command-builder-light.webp#gh-light-mode-only)
![The Command Builder beside a Redis tab, listing the string commands with their summaries, and WRITE marks on the commands that write](screenshots/redis/command-builder-dark.webp#gh-dark-mode-only)

1. **Pick a command.** Search by name or summary (`zrange`, `expire`, `stream`). Commands are grouped by data type (strings, hashes, lists, sets, sorted sets, streams, keys, server), and marked **WRITE**, **DANGEROUS**, or **BLOCKS**, the way every run checks them. **Another command…** gives a form of raw arguments for a command Runlet has no syntax for.
2. **Fill in the form.** It follows the command's syntax, shown under its name as Redis's docs write it:
   - a field per value, and checkboxes for options (`NX`, `GET`, `REV`, `WITHSCORES`);
   - a choice where options exclude each other (`EX | PX | EXAT | PXAT | KEEPTTL`, `BYSCORE | BYLEX`);
   - groups you turn on (`LIMIT offset count`, `XADD`'s trimming);
   - rows you add and remove for repeated arguments (`HSET` field and value pairs, `ZADD` score and member pairs, `XREAD STREAMS` key and id pairs). `numkeys` is counted for you.

   Numbers are checked, and durations show their unit, common values, and what they come to (`3600` = 60 min). An empty field is left out; a field's **Empty String** writes `""`. Key names complete from the key browser's last scan of the tab's connection; typing never reads anything from Redis.
3. **Check the preview.** It's the exact line, quoted the way the tab reads it (`"two words"`, `\n` for a line break), with how Runlet will treat it (a read, a write, dangerous, or refused on a read-only connection) and what's missing.
4. **Insert it.** **Insert** puts the line on a new line after the caret's (or on the caret's line when it's blank). **Replace Line** puts it in place of the caret's command, keeping its indentation. Each is one edit that **Undo** takes back.

Then <kbd>⌘</kbd><kbd>R</kbd> runs it, with the usual read-only refusals, dangerous-command confirmations, and production rules.

![ZRANGE's form in the Command Builder with BYSCORE, REV, LIMIT, and WITHSCORES, its preview, and the line Insert added to the tab](screenshots/redis/zrange-form-light.webp#gh-light-mode-only)
![ZRANGE's form in the Command Builder with BYSCORE, REV, LIMIT, and WITHSCORES, its preview, and the line Insert added to the tab](screenshots/redis/zrange-form-dark.webp#gh-dark-mode-only)

**Read Line** (the builder's text button, and opening the builder) reads the command on the caret's line into the form. Options can be in any order and case: `set k v ex 60 nx` reads as `SET k v NX EX 60`. Words the form can't place stay as raw arguments, written after the others, so nothing is lost, and a command typed halfway fills what it has. A line the builder can't read (an unclosed quote, or bytes that aren't UTF-8) leaves the form fresh and the text untouched.

The builder knows the syntax of about 150 commands: the common ones of every data type, including `ZRANGE`'s `BYSCORE`, `BYLEX`, `REV`, and `LIMIT`, `XADD`, `XRANGE`, `XREAD`, `XINFO`, and Redis 7.4's hash-field expiry; `SCAN`, `HSCAN`, `SSCAN`, and `ZSCAN`; and server commands such as `INFO`, `DBSIZE`, `MEMORY USAGE`, `CONFIG GET`, and `SLOWLOG GET`.

## Completion

Redis tabs complete as you type: two characters of a word show what fits there, and **Show Completions** (<kbd>⌃</kbd><kbd>Space</kbd> or <kbd>⌥</kbd><kbd>Esc</kbd>) shows the list anywhere. <kbd>Return</kbd> or <kbd>Tab</kbd> inserts the selected item, and <kbd>Esc</kbd> closes the list.

> [!NOTE]
> Typing never sends anything to Redis. The list comes from Runlet's command table, and from key names Runlet already read.

| What | Where, and how |
| --- | --- |
| **Commands** | At the start of a line, with their syntax as Redis's docs write it (`ZRANGE key start stop [BYSCORE \| BYLEX] [REV] [LIMIT offset count] [WITHSCORES]`), their summary, and **WRITE**, **DANGEROUS**, and **BLOCKS** marks. Commands Runlet has a syntax for come first, then the other commands it knows, with how it treats them. Streaming commands (`SUBSCRIBE`, `MONITOR`, …) aren't offered, since Redis tabs refuse them. The list follows your case: `zr` → `zrange`. |
| **Subcommands** | A container command (`CLIENT`, `CONFIG`, `XINFO`, `MEMORY`, `OBJECT`, `SLOWLOG`, …) inserts its name and a space, and lists its subcommands: `CLIENT LIST`, `CLIENT KILL`, `XINFO STREAM`, … |
| **Options** | The ones the syntax allows at the caret, in order: `ZRANGE key 0 -1` offers `BYSCORE`, `BYLEX`, `REV`, `LIMIT`, and `WITHSCORES`; `SET key value` offers `NX`, `XX`, `GET`, `EX`, `PX`, `EXAT`, `PXAT`, and `KEEPTTL`; `SCAN 0` offers `MATCH`, `COUNT`, and `TYPE`. An option already used, or one another excludes (`NX` after `XX`), isn't offered, and none is where a value goes (`SET key \|`, where `NX` would be the value). Each shows its syntax, such as `EX seconds`. |
| **Values** | `INFO`'s sections, `SCAN … TYPE`'s types, and common `CONFIG GET` parameters. |
| **Key names** | Where a key goes (`GET`, `HGETALL`, `DEL a b`, `RENAME a`, `ZUNIONSTORE dst 2 a`, `XREAD STREAMS`, `MEMORY USAGE`, …), from what Runlet already read for the tab's connection and database. Keys of the command's type come first (`HGETALL` lists hashes first) when the key browser read their type. A name is inserted quoted the way the tab reads it (`"my key"`); inside a quote you opened, it's escaped for that quote, and the caret goes after the closing one. |

**Hover** a command or subcommand to see its syntax, its summary, its group, and how Runlet treats it.

![Completion after HGETALL, listing the hash keys from the key browser's scan first, then the other keys](screenshots/redis/completion-light.webp#gh-light-mode-only)
![Completion after HGETALL, listing the hash keys from the key browser's scan first, then the other keys](screenshots/redis/completion-dark.webp#gh-dark-mode-only)

### Loading Keys for Completion

Key names come from the [key browser](#key-browser)'s last scan, from keys this tab's replies listed (`SCAN`, `KEYS`, `RANDOMKEY`), and from **Load Keys for Completion…**:

- It's the list's last item where a key goes. Show Completions shows it when nothing else fits.
- It runs **one** `SCAN 0 MATCH <prefix>* COUNT 1000` in the tab's database, with what you typed as the prefix (its `*`, `?`, `[`, `]`, and `\` escaped). It reads key names only: no types, TTLs, or `INFO`. Production asks first.
- When that scan didn't reach the end of the database, the item becomes **Load More Keys for Completion…** and continues from its cursor. It isn't offered once every key with the prefix is known.

Loaded names stay in memory while Runlet runs, and the Run Log notes each load. The tab's database is the saved connection's database number; for an application connection, it's the database of the tab's last reply (0 before any).

## Key Browser

With a Redis tab selected, the **Database** pane (**Library ▸ Database**, <kbd>⇧</kbd><kbd>⌘</kbd><kbd>B</kbd>) shows the tab's connection, with **Keys** and **Server**. Everything reads on demand only, and production asks first.

![The key browser in the Database pane: a database's keys with their types and TTLs, and a hash key's memory usage](screenshots/redis/key-browser-light.webp#gh-light-mode-only)
![The key browser in the Database pane: a database's keys with their types and TTLs, and a hash key's memory usage](screenshots/redis/key-browser-dark.webp#gh-dark-mode-only)

1. Pick the **database**. The menu lists as many as `CONFIG GET databases` reports, with the number of keys in each one that has some.
2. Type a **pattern**, `SCAN`'s `MATCH`: `*`, `?`, `[ab]`. Optionally pick a **type**.
3. **Scan** reads one page with `SCAN … COUNT 200`, never `KEYS`, with each key's type and TTL. **Load More** continues from the cursor until the scan is complete.

> [!NOTE]
> A `SCAN` may return a key twice, and keys added meanwhile may be missed: Redis's cursors promise only that keys present the whole time show up.

A key's context menu has:

| Item | What it does |
| --- | --- |
| **Open Value** (or double-click) | Reads the value by its type, at most a page of elements (`GET`, `HSCAN` for a hash, `SSCAN` for a set, `LRANGE`, `ZRANGE … WITHSCORES`, `XRANGE`), and shows the reply card in a sheet. Its **Insert Command** puts that read on its own line in the tab. |
| **Memory Usage** | Reads `MEMORY USAGE`, `OBJECT ENCODING`, and the length. |
| **Copy Key** | Copies the name. |
| **Insert Command** | Opens the [Command Builder](#command-builder) with the key filled in: the read for its type (`GET`, `HGETALL`, `LRANGE 0 -1`, `SMEMBERS`, `ZRANGE 0 -1 WITHSCORES`, `XRANGE - +`), `TTL`, `EXPIRE…`, `PERSIST`, `DEL`, or `RENAME…`. |

Neither **Insert Command** runs anything. A huge hash or set is never read in one call.

## Server Details

**Server** in the Database pane shows the server of the tab's connection. **Read Server Details** reads `INFO` and `CLIENT LIST`:

- the version, mode, uptime, clients, and memory, in one line;
- the `INFO` sections;
- every connected client, with its address, name, user, database, last command, age, idle time, and whether it's blocked. The pane's own client is marked **(this panel)**.

![Server details: the version, uptime, clients, and memory, and the connected clients, one of them blocked, with Kill…](screenshots/redis/server-details-light.webp#gh-light-mode-only)
![Server details: the version, uptime, clients, and memory, and the connected clients, one of them blocked, with Kill…](screenshots/redis/server-details-dark.webp#gh-dark-mode-only)

**Kill…** on a client always asks first, on every connection. Runlet then checks, with a fresh connection, that it reached the same server, that the client isn't the panel's own or its own, and that it's still the client listed, and sends `CLIENT KILL ID`. The outcome shows in the panel and in the tab's Run Log.

## History and Snippets

Run History keeps a Redis run's commands, with passwords as `•••`, and its connection: an application connection's name, or a saved connection's name. Opening an entry or a Redis snippet opens a Redis tab on that connection, and never runs it.

Snippets saved from a Redis tab are Redis snippets, with a **REDIS** badge and a connection picker. **Save Snippet to Project…** writes a `.runlet/snippets/<name>.redis` file, so a team can share runbooks through git:

```text
# @title Inspect a user's session
# @description The session hash and how long it lives
# @connection cache
# @input string $user "User id" = "42"
HGETALL session:$user
TTL session:$user
```

A leading block of `#` lines holds `@title`, `@description`, `@connection`, and `@input`; then come the commands, one per line. An input's value fills `$name` in unquoted arguments, or `${name}` when a letter, digit, or `_` follows it (`${user}_lock`). The whole argument is written back as one Redis argument, quoted when it needs to be, so a value with spaces, quotes, or line breaks never splits it or starts another command. Placeholders inside quotes stay text. Personal Redis snippets take `@input` lines too. See [Redis snippets](project-snippets.md#redis-snippets) and [snippet inputs](snippet-inputs.md).

![The input form of a Redis snippet, with a User id field and the argument it fills](screenshots/redis/snippet-inputs-light.webp#gh-light-mode-only)
![The input form of a Redis snippet, with a User id field and the argument it fills](screenshots/redis/snippet-inputs-dark.webp#gh-dark-mode-only)

## Safety

- **Nothing runs by itself.** Opening, importing, or restoring a Redis tab never runs it. Redis tabs never auto-run, and AI clients can't run them.
- **Production asks before every run,** every Load More page, and every key browser and server read. The confirmation shows the commands (passwords as `•••`), warns about those that can write, and says whether Run All runs in `MULTI` and `EXEC`.
- **Passwords are hidden.** A saved connection's password stays in the Keychain. A password you type (`AUTH`, `HELLO … AUTH`, `MIGRATE … AUTH` or `AUTH2`, `ACL SETUSER … >secret`, `CONFIG SET requirepass` or `masterauth`) shows as `•••` in Run History, the output, confirmations, the Connection Manager, and AI clients' snippet tools.

### Dangerous Commands

These commands always ask first, on every connection, production or not, naming the command and what it does:

`FLUSHALL`, `FLUSHDB`, `KEYS` (use `SCAN` or the key browser), `DEBUG`, `SHUTDOWN`, `SAVE`, `CONFIG SET`, `CONFIG REWRITE`, `SCRIPT FLUSH`, `CLIENT KILL`, `MIGRATE`, `SWAPDB`, `REPLICAOF` and `SLAVEOF`, `FAILOVER`, `MODULE LOAD` and `UNLOAD`, `ACL SETUSER` and `DELUSER`, `FUNCTION FLUSH` and `DELETE`, and `CLUSTER RESET`, `FAILOVER`, `FORGET`, and `FLUSHSLOTS`.

![The confirmation before FLUSHDB runs on a saved connection, with Cancel and Run FLUSHDB](screenshots/redis/flushdb-confirmation-light.webp#gh-light-mode-only)
![The confirmation before FLUSHDB runs on a saved connection, with Cancel and Run FLUSHDB](screenshots/redis/flushdb-confirmation-dark.webp#gh-dark-mode-only)

### Read-Only Connections

Redis has no read-only session. So on a [read-only connection](connections.md#read-only-connections), Runlet refuses, before anything is sent, every command that isn't a read, connection state (`AUTH`, `SELECT`, `PING`, …), or transaction control, and every command it doesn't know. It checks in the app, and again in the runner, which also asks the server's `COMMAND INFO` and refuses what the server marks as a write. One refused command refuses the whole Run All.

> [!TIP]
> For a guarantee, connect as an ACL user that can only read (`+@read`).

### Streaming Commands

`SUBSCRIBE`, `PSUBSCRIBE`, `SSUBSCRIBE`, `MONITOR`, `SYNC`, `PSYNC`, and `CLIENT REPLY` are refused: a Redis tab reads one reply per command. Use `redis-cli` for those.

### Stopping a Command

**Stop** ends the run, which closes its connection. Redis drops a client blocked in `BLPOP`, `BRPOP`, `XREAD BLOCK`, `WAIT`, … at once. Runlet doesn't also send `CLIENT KILL`: a closed connection is enough for a blocked client, and `CLIENT KILL` can't interrupt a long-running command, such as a Lua script or `KEYS` on a large database, either.

## Limitations

- Pub/Sub and `MONITOR` streaming are refused.
- Redis Cluster and Sentinel connections aren't supported.
- Completion knows only the commands in Runlet's table, not commands and modules the connected server adds.

## For developers

Redis tabs were implemented under [#190](https://github.com/filipac/runlet/issues/190), with completion ([#206](https://github.com/filipac/runlet/issues/206)), the Command Builder ([#218](https://github.com/filipac/runlet/issues/218)), project snippets ([#205](https://github.com/filipac/runlet/issues/205)), and New Redis Tab in the File menu ([#214](https://github.com/filipac/runlet/issues/214)). History and snippets remember the connection as SQL tabs do ([#149](https://github.com/filipac/runlet/issues/149)), and the TablePlus import ([#188](https://github.com/filipac/runlet/issues/188)) maps Redis rows. The MongoDB Query Builder shares the builder's command and place ([#217](https://github.com/filipac/runlet/issues/217)). This page was rewritten for the documentation website in [#290](https://github.com/filipac/runlet/issues/290).

- **Raw commands:** a Laravel connection's commands go through phpredis's `rawCommand()` or Predis's `executeRaw()`, which is why the key prefix and serializer don't apply. A Redis Cluster connection is refused (Cluster is a later feature).
- **Runlet's client** for saved connections uses plain PHP sockets (`tcp://`, `tls://`, `unix://`), then `AUTH` (a password, or an ACL user and password) and `SELECT`.
- **Passwords** reach PHP only inside the runner's request on standard input; the runner forgets the password once connected, replaces it with `•••` in everything it reports, and scrubs typed passwords from its events.
- **Stop vs. SQL:** SQL tabs send `KILL QUERY` on Stop ([#144](https://github.com/filipac/runlet/issues/144)); Redis tabs don't send `CLIENT KILL`, for the reasons above.
- **AI clients:** `run_php` runs PHP only, and the app refuses to run a Redis tab's text as PHP.
- **Read-only:** the app's table is derived from Redis's command flags; the runner checks `COMMAND INFO` as well.
- **Kill client:** the fresh runner compares INFO's `run_id` to make sure it reached the same server, and the client's address to make sure it's the one listed.
- **The builder** knows about 150 commands from `RedisCommandSpecs` (RunletCore), shared with completion (#206). Completion uses the builder's specs and agrees with the classification table on command names.
- **Snippets:** `.redis` files share `DatabaseSnippetHeader` with `.mongodb` files.
- **Not yet:** refining completion from the server's `COMMAND DOCS`, for commands and modules Runlet's table doesn't know.

The pull requests' screenshots, taken before the documentation website:

- [#190](https://github.com/filipac/runlet/issues/190): [a Redis tab](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-190/redis-tab-v2.png), [the connection editor](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-190/redis-editor.png), [the FLUSHDB confirmation](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-190/redis-danger.png), [a read-only connection refusing SET](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-190/redis-readonly.png), [the key browser](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-190/redis-keys-v2.png), [Open Value on a stream](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-190/redis-value-v2.png), [the server panel](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-190/redis-server.png), and [Kill Client's confirmation](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-190/redis-kill.png).
- [#218](https://github.com/filipac/runlet/issues/218): [the command list](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-218/redis-builder-picker.png), [ZRANGE's form](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-218/redis-builder-form-zrange.png), [HSET's form](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-218/redis-builder-form-hset.png), and [built commands inserted and run](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-218/redis-builder-inserted-ran.png).
- [#206](https://github.com/filipac/runlet/issues/206): [commands](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-206/redis-complete-commands.png), [subcommands](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-206/redis-complete-client.png), [options](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-206/redis-complete-options.png), [keys](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-206/redis-complete-keys.png), [Load Keys for Completion](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-206/redis-complete-load-offer.png) and [the keys it read](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-206/redis-complete-loaded.png), and [hover](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-206/redis-hover.png).
- [#205](https://github.com/filipac/runlet/issues/205): [the input form](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-205/redis-snippet-inputs-205-dark.png) and [Redis snippets in Open Anything](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-205/redis-snippet-palette-205.png).

### Validation

- `RedisCompletionTests` (RunletCore, #206): commands at the start of a line (syntax, summary, marks, case, refused commands left out), nothing in comments or after a closed quote, containers and their subcommands, the options each position allows (used and excluded ones left out, none where a value goes), suggested values, key positions per command family (strings, keys, hashes, lists, sets, sorted sets with `numkeys`, streams with `STREAMS`, the server's key commands) and positions that aren't, keys of the command's type first and each once, quoting of key names (spaces, quotes, line breaks, backslashes, Unicode; unquoted, in double and single quotes, with the paired closing quote) read back exactly, Load Keys for Completion's item and pattern, the keys known per database, hover, and that completion uses the builder's specs and agrees with the classification table on command names.
- `RedisTabTests` (RunletCore): `redis-cli` quoting (escapes, bytes, broken quotes), what Run and Run All send (caret, selection, comments), passwords redacted in typed commands, the command table (reads, writes, connection, transaction, streaming, unknown, dangerous) and read-only refusals, every reply type and how it's shown, Load More's next command and merged pages, the generated PHP (byte-exact, passwords marked), the `redis` connection kind (validation, normalization, encoding), family gating of pickers and connection resolution, tab state and history, and the TablePlus mapping. `TablePlusImportTests` imports the fixture's Redis row.
- `RedisCommandBuilderTests` (RunletCore, #218): every command spec is in the classification table with the same class; the syntax as Redis's docs write it; the command list's groups and search; form → command line for SET (options), HSET (pairs), ZRANGE (BYSCORE REV LIMIT WITHSCORES), XADD, SCAN, EXPIRE, and numkeys; hand-typed lines of every family reading back into the form and rendering the same line; quoting (spaces, quotes, line breaks, tabs, backslashes, empty strings, Unicode) through the parser; options in any order and case; unplaced words kept raw; lines typed halfway; repeated arguments, `numkeys`, and `STREAMS`; each word's role (command, token, key, value); Insert, Replace Line, and Read Line on the caret's line; the key browser's items by type.
- `RedisCommandTableTests` (RunletExecution, host PHP): the runner's command lists match the app's.
- `RedisLiveTests` (RunletExecution, the Redis fixture: `scripts/setup-fixtures.sh databases` prints `RUNLET_TEST_REDIS` and `RUNLET_TEST_REDIS_TLS`): a saved connection from the target, from this Mac, and through the SSH fixture's tunnel (plain and TLS, to the Compose service name), with every reply type and another database; Run All stopping at an error and `MULTI`/`EXEC`; read-only and streaming refusals before anything is sent; passwords never in any event (an echoed password, a typed `AUTH`, a wrong password); TLS with the fixture's CA (verified, a wrong CA refused, Require) and an ACL user Redis itself limits to reads; the key browser's SCAN pages, Open Value, and Memory Usage; the server panel and Kill Client's refusals; Stop ending a `BLPOP 0` (Redis drops the blocked client) and Kill Client ending another; application connections through a driver's callable and Laravel's `Redis::connection()` with phpredis.
- `RedisLiveTests.loadKeysForCompletionReadsNamesOnly` (#206): Load Keys for Completion's SCAN on the fixture, key names only (no types, TTLs, or INFO), the prefix's glob characters escaped, and a key with a space inserted as completion quotes it runs as that key.
- `RedisLiveTests.builtCommandsRunAsShown` (#218): the lines the builder writes for SET, HSET, ZADD, ZRANGE, XADD, SCAN, EXPIRE, and GET run on the fixture as shown, and a value with spaces, quotes, a line break, a tab, a backslash, and Unicode comes back from Redis exactly.
- `RedisSnippetsTests` (RunletCore, #205): the `#` header (title continuation, `@label`, a comment block without tags staying in the commands, unreadable `@input`s), the same `DatabaseSnippetHeader` as `.mongodb` files, inputs filled as quoted arguments (whole, part of an argument, `${name}`, a quoted part after it), values with spaces, quotes, line breaks, tabs, backslashes, `#`, NUL, and Unicode parsing back to exactly one argument with the value's bytes (also as a command's name), placeholders in quotes, undeclared, or malformed staying text, comment and unreadable lines untouched, line endings kept, every value kind, `.redis` files loading, saving, and reading back the same, personal copies keeping `# @input` lines, and connections resolving by name within the Redis family (`(saved)`, missing).
- The Debug app with a scratch data folder (see `RedisDebugSteps`, `RedisBuilderDebugSteps`, and `RedisCompletionDebugSteps`): the screenshots above; `redis-builder:undo-check` checks that Insert and Replace Line are each one Undo step; `redis-type`, `redis-complete…`, `redis-hover`, and `redis-load-keys` drive completion (typing, the list, hover, and Load Keys for Completion with production's question).
