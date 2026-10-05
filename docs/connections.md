# Connections

SQL, Redis, and MongoDB tabs run on your application's own connection by default, the one its code uses, so Runlet needs no credentials from you. For any other database, save a connection: Runlet keeps its password in the macOS Keychain and nowhere else.

The **Connection Manager** shows everything Runlet has open right now, from SSH connections to running statements, and closes any of it.

## Saved Connections

Save a connection for a database your application doesn't configure: a read replica, a reporting or legacy database, another service's database, a project without a driver, or your app's database as another user.

Saved connections work in SQL, [Redis](redis.md), and [MongoDB](mongodb.md) tabs. A tab's connection menu offers only connections of its kind: an SQL tab never lists a Redis connection, and a Redis tab never lists an SQL one.

### Creating a Connection

You can create and edit saved connections in several places:

- **New Connection…** and **Edit Connections…** in a tab's connection menu. **New Connection…** switches the tab to the new connection when you save it.
- The **Databases** list in a local project's options, and in the Docker and SSH profile forms.
- **Settings ▸ Databases**, which manages connections that belong to **all targets** and lists every target's connections. Tabs on every target offer the connections of all targets, the sandbox's too.

<!-- screenshot: the connection editor for a PostgreSQL connection, with Test Connection's report -->

| Field | Notes |
| --- | --- |
| **Name** | Unique within the target, or among the connections of all targets. |
| **Available on** | The target, or **All targets**. |
| **Connect from** | **The target's PHP** (the default), **This Mac**, or **This Mac, through SSH profile**. See [below](#from-this-mac-and-for-all-targets). |
| **Driver** | MySQL / MariaDB, PostgreSQL, an SQLite file, SQL Server, a custom PDO DSN, [Redis](redis.md#saved-redis-connections), or [MongoDB](mongodb.md#saved-connections). |
| **Host**, **Port** | The host is resolved where the connection opens, so a Compose service name works for a Docker profile. A Unix socket can replace them. |
| **Database** | Optional for MySQL and PostgreSQL. For SQLite, the file on the target (Runlet opens existing files only). |
| **User**, **Password** | The password is optional, and stored only in the macOS Keychain. |
| **Connect timeout** | Seconds, 10 by default. |
| **Read-only** | See [Read-only connections](#read-only-connections). |
| **Environment**, **Colour** | Development, staging, or production, and a colour, like a target's. See [Environment and colour](#environment-and-colour). |
| **Advanced** | A Unix socket, charset, TLS, init statements, and DSN options. See [Connection options](#connection-options). |

By default, the connection opens in the target's own PHP: the project's PHP on your Mac, the container's for a Docker profile, or the server's for an SSH profile. For an SQL database, that PHP needs the database's PDO driver: the official `php:*-cli` images, for example, have `pdo_sqlite` but not `pdo_mysql` or `pdo_pgsql`. Redis connections need no extension, and MongoDB connections need PHP's `mongodb` extension.

A statement on a saved connection runs no project code: no driver, no autoloader, and no application code share the process that holds the password. Results say where they came from:

```text
via saved connection "Reporting" (pgsql, db.internal:5432/reports)
```

### Testing a Connection

**Test Connection** in the editor opens the connection where its runs do, and reports:

- the server's version, the database, and the user;
- the round trip, and whether the session is encrypted;
- the PHP that opened it, with its PDO drivers. If that PHP lacks the driver, it lists the drivers it has.

Test Connection runs none of your SQL, so it doesn't ask on production.

### From This Mac, and for All Targets

**Connect from: This Mac** suits a database your Mac can reach but the target's PHP can't:

- a port that Docker Desktop, OrbStack, DBngin, or Herd publishes;
- a cloud database whose allow-list has your office;
- a server whose PHP has no `pdo_pgsql`;
- a `php:*-cli` container without the MySQL or PostgreSQL driver, the Docker-based Laravel sandbox among them.

How it works:

- **Which PHP.** The first PHP on your Mac that has the connection's driver: Runlet's own PHP (it has MySQL, PostgreSQL, SQLite, Redis, and MongoDB support), then your default PHP, then every other installed PHP. When it isn't the first, the run header says why. When none has the driver, nothing runs, and the message names the driver and the PHPs it checked.
- **Names and paths are your Mac's.** `localhost` means your Mac, not a container or server. Sockets, SQLite files, and TLS files are paths on your Mac.
- **It runs in an empty folder of Runlet's.** Nothing of the project runs, and nothing is written to its directory.

A connection saved for **All targets** always opens from your Mac. Every tab of its kind lists it under **Saved connections (all targets)**, and its schema is read once for every target.

### Through an SSH Tunnel

**Connect from: This Mac, through SSH profile** suits a database only a server can reach, such as one behind a bastion or a Docker service on the server, when that server's PHP can't open it. Runlet forwards a local port through the SSH profile's connection, and opens the database with your Mac's PHP, as GUI database clients do.

- Choose the **SSH profile**, and enter the host and port **as that server sees them**: `localhost` means the server, and a name such as `db.internal` or a Compose service works.
- MySQL, PostgreSQL, SQL Server, Redis, and MongoDB (without DNS SRV) can use a tunnel. An SQLite file, a custom DSN, and a Unix socket can't.
- The forward listens only on 127.0.0.1, is shared by the connection's runs, and closes 5 minutes after its last use, or when the SSH profile disconnects or Runlet quits.
- **Runlet asks before connecting.** When the SSH profile isn't connected, a run asks **Connect to “bastion” for the SSH tunnel?** and never connects by itself. A profile that logs in with a password or a two-factor code opens **Connect…** in a terminal.
- Everything works through the tunnel: statements, Run All, Explain, Load Next, completion, the Database pane, and Stop.

> [!NOTE]
> With TLS, PostgreSQL's **Verify CA and host name** still checks the server's name through a tunnel. MySQL's driver checks the certificate against `127.0.0.1`, so use **Require**, or a certificate that names 127.0.0.1. For SQL Server, add the DSN option `HostNameInCertificate`.

A run through a tunnel uses the strictest of the target's, the connection's, and the SSH profile's environment. The [SSH targets](ssh.md#sql-tunnels) page explains the shared SSH connection the tunnel uses.

### Read-Only Connections

Turn on **Read-only** to look at data, production data included, without changing it. The bar above the editor shows a **READ-ONLY** badge with a lock, and the output says "in a read-only session".

**On MySQL, MariaDB, PostgreSQL, and SQLite, the database enforces it.** Right after connecting, before any statement of yours, Runlet makes the session read-only and checks that it took; otherwise nothing runs.

| Database | What the database then refuses |
| --- | --- |
| MySQL, MariaDB | `INSERT`, `UPDATE`, `DELETE`, schema changes, and `SELECT … FOR UPDATE` |
| PostgreSQL | Writes to tables, every `CREATE`, `ALTER`, and `DROP`, `FOR UPDATE` and `FOR SHARE`, `nextval()`, and writes from functions |
| SQLite | Every write: the file is opened read-only |

**Runlet refuses before sending,** too: statements that could write, statements that would make the session writable again, and statements it can't classify. The message says why:

```text
This statement can change data or the schema (UPDATE), so Runlet doesn't send it on the
read-only connection “Reporting replica”. Nothing ran.
```

Run All Statements checks every statement first, and runs none of the script if one is refused.

> [!WARNING]
> Read-only is a strong safety net, not a permission system. Functions with side effects called from a `SELECT` aren't detected (MySQL still runs `GET_LOCK()` or a stored function that writes), and behind a transaction-pooling proxy the setting can miss later statements. For a guarantee, connect as a database user that only has read privileges.

**Redis and MongoDB have no read-only session,** so Runlet refuses every command or operation that can write before sending it, in the app and again in the runner. See [Redis](redis.md#read-only-connections) and [MongoDB](mongodb.md#read-only-connections).

Read-only is a setting of saved connections; your application's own connections aren't made read-only. SQL Server and custom DSNs don't support it: connect as a user that can only read instead.

### Connection Options

The editor's **Advanced** section holds what managed databases, local servers, and some schemas need. It opens by itself when a connection uses any of it.

| Option | MySQL / MariaDB | PostgreSQL | SQL Server |
| --- | --- | --- | --- |
| Unix socket | yes | yes (the socket's directory) | — |
| Charset | `utf8mb4` by default | the server's by default | — (UTF-8) |
| TLS modes | Off, Require, Verify CA and host name | Off, Prefer, Require, Verify CA, Verify CA and host name | Off, Require, Verify CA and host name |
| CA, client certificate, client key | yes | yes | — |
| DSN options | — | libpq keywords (`application_name`, …) | DSN keywords (`ApplicationIntent`, …) |
| Init statements | yes | yes | yes |

- **TLS files** are paths where the connection opens: on your Mac, in the container, or on the server. Encrypted client keys aren't supported; decrypt the key (`openssl pkey -in key.pem -out client.key`) and keep the file private.
- **Init statements** run after connecting, before your statement, such as `SET search_path TO reporting, public` or `SET time_zone = '+00:00'`. At most 20, one statement each. They can't control transactions, production confirmations list them, and on a read-only connection they run inside the read-only session.
- **DSN options** that hold a password are refused: "Runlet keeps passwords only in the Keychain: put it in the Password field".
- **SQL Server** needs Microsoft's `pdo_sqlsrv` (with its ODBC driver) or `pdo_dblib` in the target's PHP; Runlet's own PHP has neither. It isn't verified against a live server yet.
- **A custom PDO DSN** (`oci:`, `odbc:`, `firebird:`, …) is for drivers Runlet doesn't model. Type the DSN without a password; the Password field still works.

Redis and MongoDB connections have their own TLS options: see [Redis](redis.md#saved-redis-connections) and [MongoDB](mongodb.md#tls).

### Environment and Colour

Mark a saved connection **development**, **staging**, or **production**, with a colour, like a target. A development project can hold a connection to the production replica: mark that connection as production.

A run uses the stricter of the target's and the connection's marking. So a production connection on a development target asks before every statement, Run All, and Load Schema, exactly as a production target does. The bar above the editor shows the connection's colour and its STAGING, PROD, or READ-ONLY badges, and Run History marks the run with the stricter environment.

### Passwords

A saved connection's password is stored only in your login keychain, never in Runlet's files, logs, Run History, sessions, workspaces, or AI clients' results. Runlet reads it when a run starts (after any production confirmation) and sends it only to the PHP process that opens the connection, on its standard input, never as an argument or environment variable. PHP replaces it with `•••` in everything it reports.

> [!NOTE]
> Runlet isn't signed with an Apple Developer ID yet, so **after an update, macOS may ask once whether Runlet may use the password**. Choose **Always Allow**. **Deny** stops that run: "The password of the saved connection “Reporting” couldn't be read, so nothing ran."

- Deleting a connection deletes its Keychain item.
- Duplicating a connection, or a profile, copies it without the password.
- Workspaces keep only a connection's name, and AI clients never see saved connections.

## Import From TablePlus

**Import from TablePlus…** creates saved connections from the ones TablePlus keeps.

> [!NOTE]
> The import sits behind the feature flag **Import connections from TablePlus** in [Settings ▸ Advanced](settings.md#advanced-feature-flags), off by default. With the flag off, nothing about TablePlus appears. With it on, the button is in **Settings ▸ Databases** and **Edit Connections…**.

Runlet reads TablePlus's connection list only when you click: `~/Library/Application Support/com.tinyapp.TablePlus/Data/Connections.plist` (or the Setapp edition's), or a copy you choose with **Choose File…**. Encrypted `.tableplusconnection` exports can't be read. Nothing connects during the import.

<!-- screenshot: the Import from TablePlus sheet with a few connections selected and the Save for, Already saved, and password options -->

The sheet lists every connection, none selected, with its driver, host, database, user, group, environment tag, TLS, and SSH. Connections Runlet can't import (Cassandra, DynamoDB, Elasticsearch, Oracle, …) are greyed out with the reason. Above the list, choose:

- where to save them (**All targets** by default);
- whether to skip or update connections you already imported;
- whether to copy passwords.

| TablePlus | Runlet |
| --- | --- |
| MySQL, MariaDB, PostgreSQL, SQL Server | The same driver |
| SQLite | An SQLite file, opened from this Mac |
| Redis, MongoDB | A saved [Redis](redis.md#saved-redis-connections) or [MongoDB](mongodb.md#import-from-tableplus) connection |
| Environment tag | production → production; staging and testing → staging; local and development → development |
| Status colour | The nearest Runlet colour |
| Read-only switch | Read-only |
| Over SSH | **This Mac, through SSH profile**: an existing profile for the same server, or a new one per server |
| Anything else | This Mac, since TablePlus connects from your Mac |

**Passwords are opt-in.** With **Also copy passwords from TablePlus's Keychain items** ticked, Runlet reads each imported connection's item, and macOS asks you to allow each one. A copied password goes straight into Runlet's own Keychain item. SSH passwords and key passphrases are never read or copied.

The summary lists what was imported, updated, and skipped, the new SSH profiles, and what needs your attention, such as a missing password. Use **Test Connection** to check a connection.

## Connection Manager

The Connection Manager lists everything Runlet has open right now, in one window, and closes any one of it: SSH connections and tunnels, database sessions, PHP runs, AI clients, and logs it follows.

To open it:

- choose **Window ▸ Connections** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>C</kbd>; change it in **Settings ▸ Shortcuts**);
- click the connection count at the bottom right of a window's status bar;
- or search for "connections" in Open Anything (<kbd>⌘</kbd><kbd>P</kbd>) or the command palette (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>P</kbd>).

Opening it again brings the window to the front. The status bar's count has a tooltip with the counts per kind. At zero, the count stays, dimmed, so the window is always a click away. While runs wait for a free run slot, an hourglass with their number follows the count (see [Queued Runs](#queued-runs)).

<!-- screenshot: the Connection Manager with an SSH connection, its tunnel, a database session, and a PHP run -->

### What It Lists

Rows are grouped by kind. Each row shows what the connection is, where it goes, which tab or feature uses it, when it started, and a production badge when the target, the SSH profile, or the saved connection is marked production.

| Section | Rows | Where it goes |
| --- | --- | --- |
| **SSH Connections** | An SSH profile's shared connection, from **Connect…** or opened by a run. The row says how its login closes: a password or two-factor login stays until you disconnect; an agent or key login closes after the profile's **Keep connection** time, or when Runlet quits. | `user@host:port`, and the jump host |
| **SSH Tunnels** | A forward that a saved connection opens [through an SSH profile](#through-an-ssh-tunnel). The row shows when it opened, when it was last used, and whether a run holds it. | `127.0.0.1:<port> → <host>:<port> through <profile>` |
| **Database Sessions** | Running database work: a statement, Run All, Explain and Explain Analyze, a Load Next page, Load Schema, Show Definition, and the Database pane's Server reads, Cancel Query, and Kill Session. A statement's row shows its first line, and its session id on the server once the database reported it. | The driver, the database, and the connection: the target's application connection, or a saved connection with where it opens (the target's PHP, this Mac, or a tunnel) |
| **PHP Runs** | Runs in progress on every target: the sandbox, local projects, Docker, and SSH. The row shows the code's first line. | The target |
| **AI Clients** | AI clients connected to Runlet's [MCP server](mcp.md), by the name the client reports. | Runlet's MCP server on this Mac |
| **Log Follows** | A log the [Logs window](logs.md) follows in a container or on a server: `docker logs`, `docker exec … tail -F`, or `ssh … tail -F`. Read-only. Files on this Mac open no connection and aren't listed. | `tail -F on <host>`, `docker logs <container> on this Mac`, … |

An SSH connection's row also says what uses it, such as "Used by 1 SSH tunnel, 1 database session, and 1 PHP run": runs on its profile, statements that run there, and tunnels on it. A tunnel's row says which statements use it.

**Database sessions exist only while work runs.** Runlet opens a database connection per statement, in a fresh PHP process, and keeps no idle connections or pool. A database row appears when a statement starts and goes away when it ends.

The list updates by itself as things open and close. It shows only what Runlet already keeps track of: listing never connects, reads, or runs anything, and nothing goes to the network. While the window is open, Runlet checks the SSH profiles' control sockets on your Mac every few seconds, as the status bar's SSH status does, so a shared connection that ended by itself (its keep time ran out, or the network changed) leaves the list.

### Queued Runs

Runlet runs at most four runner processes at once. A further PHP run or SQL statement waits for a free **run slot**. A waiting run has started nothing: no PHP process, no database connection, and no use of an SSH connection or tunnel. So the Connection Manager lists it, but doesn't count it.

- **Its row** stays in its kind's section (PHP Runs or Database Sessions), after the active rows and in the order the runs will start, marked **Queued**. It shows "Queued since 10:42 (12 s)" and its place: "Next to start" or "2nd in line". The section header shows "1 queued" beside its count.
- **The counts** in the status bar and the window's header are of active connections only. While runs wait, the status bar shows an hourglass with their number, the header says "8 active connections, 1 run queued", and the tooltip starts "8 active, 1 queued", with a line per kind ("4 PHP runs, 1 queued").
- **SSH connections and tunnels** don't count queued runs among their users, and closing an SSH connection doesn't warn that they end with it: they haven't used it yet. A tunnel added for a queued statement does count it: the forward was added before the run was queued.
- **When the run gets its slot,** its row becomes an ordinary running row, and its start time is when it actually started.
- **Close** on a queued row takes it out of the queue, as the tab's Stop does. Nothing was launched or sent, so nothing needs cancelling on a server.

The tab says so too. Its status bar shows "Queued · next to start" instead of the timer, an SQL tab's running row says it connects when it starts, and the output and the Run Log say why it waits: "4 runs are going, at most 4 at once; next to start". On Stop, they say "Removed from the queue before it started; nothing was sent." Once it runs, the Run Log says how long it waited.

Database work outside tabs (Load Schema, Load Next, the Database pane's Server section) waits for a slot the same way, but its rows show as running while they wait.

### Closing a Connection

Every row has a **Close** button, and a context menu with **Close**, **Reveal Tab** (selects the tab the connection belongs to, if any), and **Copy Destination**.

| Kind | What Close does | Asks first |
| --- | --- | --- |
| SSH connection | Disconnects the shared connection (`ssh -O exit`), as the profile's **Disconnect** does. The profile's tunnels are removed first. | When runs, statements, or tunnels use it ("they end with it"), or when its login used a password or two-factor code ("you'll have to log in again with Connect…") |
| SSH tunnel | Cancels the forward (`ssh -O cancel`). The SSH connection stays, and the next run adds the tunnel again. | When a run holds it: a statement, a schema read, or Test Connection |
| Database session | Stops the work, as its own Stop does. For a statement, Run All, Explain Analyze, and a Load Next page, Stop [cancels the statement on the server](sql-tabs.md#stopping-a-statement) first. Load Schema and the Server section's reads stop; Show Definition's sheet closes. | Never |
| PHP run | Stops the run, as the tab's Stop does. | Never |
| Log follow | Stops following, as the Logs window's Stop does: the `tail` (or `docker logs`) ends in the container or on the server too. | Never |
| AI client | Drops that client's connection. Its requests waiting for approval are withdrawn, and runs it started finish in their tabs. The MCP server keeps listening, so the client's next tool call connects again. To refuse clients, turn off **Settings ▸ AI Clients ▸ Allow AI clients to connect**. | Never |

Closing never asks the production question: stopping and disconnecting are always allowed. A row whose Close is under way shows **Closing…**.

### No Secrets

Rows show host names, ports, user names, database names, and connection names. They never show a password, a token, a key, or a DSN with credentials. Runlet doesn't put them in, and the list also removes anything that looks like one (`user:password@`, `password=…`, `IDENTIFIED BY '…'`) from every row's text. Tunnels show only `host:port`.

## For developers

The Connection Manager was added under [#180](https://github.com/filipac/runlet/issues/180), with queued runs under [#183](https://github.com/filipac/runlet/issues/183); it lists AI clients of the MCP server ([#43](https://github.com/filipac/runlet/issues/43)) and the Logs window's follows ([#20](https://github.com/filipac/runlet/issues/20)). Saved connections are [#138](https://github.com/filipac/runlet/issues/138), with read-only connections and environments ([#139](https://github.com/filipac/runlet/issues/139)), connection options ([#140](https://github.com/filipac/runlet/issues/140)), connections from this Mac and for all targets ([#142](https://github.com/filipac/runlet/issues/142)), SSH tunnels ([#143](https://github.com/filipac/runlet/issues/143)), the PHP chosen per driver ([#184](https://github.com/filipac/runlet/issues/184)), and the TablePlus import ([#188](https://github.com/filipac/runlet/issues/188), behind the flag of [#187](https://github.com/filipac/runlet/issues/187); Redis [#190](https://github.com/filipac/runlet/issues/190) and MongoDB [#209](https://github.com/filipac/runlet/issues/209) connections), part of the database roadmap [#137](https://github.com/filipac/runlet/issues/137). This page was rewritten for the documentation website in [#290](https://github.com/filipac/runlet/issues/290): the saved connections moved here from [SQL Tabs](sql-tabs.md), which keeps a summary under the old headings, so links such as `sql-tabs.md#through-an-ssh-tunnel` still land on them.

### Connection Manager Internals

An SSH connection's row is the profile's OpenSSH control master; a tunnel's row is a forward on it ([SSH targets](ssh.md#sql-tunnels)).

The model is in `RunletCore` (`ActiveConnections.swift`: `ActiveConnection`, `ActiveConnectionList`, `ConnectionRows`, `ConnectionText`), with unit tests in `ActiveConnectionsTests`. The app's providers are in `Runlet/App/AppModel+Connections.swift`, one per kind, each reading existing state (SSH statuses, `SQLTunnelStore.active`, tabs' run state, the database work it tracks, `MCPStore.connections`). See [architecture.md](architecture.md). `scripts/connection-manager-screenshots.py` drives a Debug build end to end with scratch data and the runlet-fixtures SSH host and databases, and checks that Close cancels the MariaDB statement on the server and removes the tunnel's listener.

Queued runs ([#183](https://github.com/filipac/runlet/issues/183)): `ExecutionEngine` admits each run as it accepts it, to a slot or to the end of its queue, and publishes `RunSlots` (RunletCore: the runs holding a slot since when, and the queue in order) on `slotChanges` after every change; the app follows it (`AppModel.followRunSlots`, into `ConnectionManagerStore.slots`), so nothing polls. `TabRunConnectionProvider` maps a run's `RunSlots.State` onto its row (`ActiveConnection.withSlot`: `isQueued`, `queuePosition`, and `startedAt`); `ActiveConnectionList` leaves queued rows out of `count`, `count(of:)`, and `users(of:)`, and reports them in `queuedCount`. `cancel(runId:)` on a queued run takes it out of the queue (its launch task ends with `finished` cancelled, before any process). Tests: `ActiveConnectionsTests` (mapping, counts, tooltip, usage) and `RunSlotsTests` (one slot and two sleeps, Stop on a queued run, positions). `scripts/queued-runs-screenshots.py` drives a Debug build with six local tabs.

### Saved Connection Internals

- **Fields:** the port defaults to 3306, 5432, or 1433; a Unix socket replaces host and port for MySQL and PostgreSQL. Hosts accept only letters, digits, `.`, `-`, `_`, and `:` (IPv6). Database names may not hold `;`, quotes, or control characters, so nothing can add options to the connection string. An SQLite path on a target is absolute or relative to the project directory; from this Mac, absolute or `~/…` (with **Choose…**). The user is stored with the definition. After saving, the editor shows only that a password is saved, with **Replace…** and **Remove**. The timeout is `PDO::ATTR_TIMEOUT`. **New Connection…** from a sandbox tab creates a connection for all targets; a profile that isn't saved yet gets its connections once it is. **Edit Connections…** also lists the connections of all targets.
- **Test Connection** uses the password typed in the sheet (before saving) or the saved one, and runs the connection's init statements. Its reports read like "Opened from this Mac (Runlet's PHP 8.5.8) in 12 ms (PDO drivers: mysql, pgsql, sqlite)." and "This target's PHP 8.4.1 has no pdo_pgsql driver. It has: sqlite.". It runs no application code and only Runlet's own fixed queries (as #138 decided), and on a read-only connection it runs in the read-only session.
- **No project code:** a statement, Run All, Load Schema, or Test Connection on a saved connection boots the runner with the `plain` bootstrap: no driver, no Composer autoloader, and no application code share the process that holds the password. Such a run doesn't change what Runlet learned about the target (framework, App Info, driver hints, connection names). Results add `, read-only session` for a read-only connection, never a user or password.
- **From this Mac** (#142, #184): the PHP order is Runlet's own PHP when it is installed (Settings ▸ PHP; it has `pdo_mysql`, `pdo_pgsql`, `pdo_sqlite`, phpredis, and ext-mongodb), the default PHP from Settings ▸ PHP, the PHP Runlet picks automatically, then every other installed PHP (Herd, Homebrew, …). The driver needed is `pdo_mysql`, `pdo_pgsql`, `pdo_sqlite`, `pdo_sqlsrv` or `pdo_dblib` for SQL Server, the one a custom DSN names (`oci:` needs `pdo_oci`), or ext-mongodb; a Redis connection needs none (Runlet's own client), so it gets the first PHP. Runlet reads each PHP's PDO drivers and extensions when it looks for PHP (at launch, and when Runlet's PHP is installed or removed), and a default PHP it doesn't list once, the first time a connection needs it; nothing is checked on a run. Messages read "Warehouse · this Mac (Herd PHP 8.4.25, the first PHP here with pdo_sqlsrv or pdo_dblib)", "Runlet's PHP 8.5.8 comes first but has neither pdo_sqlsrv nor pdo_dblib.", and "No PHP on this Mac has pdo_sqlsrv or pdo_dblib, which the saved connection “Warehouse” needs, so nothing ran. Checked Runlet's PHP 8.5.8 and Herd PHP 8.0.30."; without any PHP, the run points to Runlet's PHP, and the editor offers **Download Runlet's PHP…** after a failed test of a driver it has. The process runs in `LocalConnections` in Runlet's data folder, with the `plain` bootstrap; Stop, limits, timeouts, and output are those of local runs. The run header says "Reporting · this Mac (Runlet's PHP 8.5.8)", and so do Run History, the SQL bar, and production confirmations. The password reaches PHP through a local pipe. Production marking (the stricter of the connection's and the tab's target's), read-only, init statements, bound parameters, Run All, Explain, Load Next, Load Schema, completion, and the schema explorer work as for any saved connection. The engine refuses to send a connection that opens from this Mac to a container, a server, or the project's own directory, before anything starts.
- **All targets:** the schema is shared by every target's tabs; production comes from the connection combined with the tab's target; removing a target leaves them alone; deleting one deletes its Keychain item; workspaces find a tab's name in the target's own connections first, then those of all targets.
- **SSH tunnels** (#143): the forward is `ssh -F /dev/null -S <control path> -O forward -L 127.0.0.1:<port>:<host>:<port> -- <host>` on the profile's control master (see [SSH targets](ssh.md#sql-tunnels)), on a port the kernel reports free just before (a port taken meanwhile is retried with another one); it holds only a host and ports, never a user or password. One forward per connection is reused by every run while in use, and cancelled (`-O cancel`) 5 minutes after its last use when no open SQL tab uses the connection (the tab closed or switched connections), when the connection is edited or deleted, when the SSH profile disconnects, and when Runlet quits. Test Connection removes its forward right after the test unless an SQL tab uses the connection. An SSH target's own profile is preselected when you switch to the tunnel there; the editor's row says whether its connection is up; a PostgreSQL `hostaddr` option is refused because the tunnel sets it. Not connected, the question covers a run, Run All, Explain, Load Next, Load Schema, Show Definition, and Test Connection; an agent or key profile then logs in as its runs would (BatchMode); a password or 2FA profile's login from **Connect…** stays until you disconnect. The Server section's reads, Cancel Query, and Kill Session go through the tunnel (their server check still holds); its refresh never asks to connect and stops with "Not connected". Stop's second runner uses the same forward. Run History entries and SQL snippets reopen on the connection (by id, then by name, #149) and run through the tunnel again. TLS: Runlet gives libpq the connection's host and connects to the forward with `hostaddr=127.0.0.1`; MySQL's PDO driver can't be told another name; SQL Server's ODBC driver checks against 127.0.0.1 too (`HostNameInCertificate` is an ODBC Driver 18 option); the editor's TLS section says this for the chosen driver. The production sheet says "The saved connection “Shop” goes through an SSH tunnel on “bastion”, which is marked as production." The tunnel shows in the run header ("Shop · this Mac (Runlet's PHP 8.5.8) through bastion"), the picker ("pgsql, postgres:5432/shop · through bastion"), results (`via saved connection "Shop" (pgsql, postgres:5432/shop through SSH "bastion")`), Test Connection ("Opened from this Mac (Runlet's PHP 8.5.8) through SSH “bastion” (127.0.0.1:50123 → postgres:5432)"), and the Run Log (the `ssh -O forward` line of every run, and the `-O cancel` line in the tabs that used it); a connection error adds that the server connects to the database for it. Removing the SSH profile leaves its tunnelled connections in place: the editor shows **Missing profile** and can't save until you choose another, and runs say the profile was removed; Runlet never picks another profile by itself. The password is never in `ssh`'s arguments. Any process of this Mac can connect to the forward while it exists, as with any SSH tunnel; the database still asks for the password.
- **The password at rest** is a generic password in the login keychain: service `dev.runlet.Runlet.database`, account the connection's id, label `Runlet database: <name>`, comment `Runlet saved database connection`, not synchronizable (never in iCloud Keychain). `targets.json` keeps the definition only; sessions keep the tab's connection id and name; workspaces keep the name only (`"sqlSavedConnection": "Reporting"`). A workspace whose name doesn't resolve shows "The saved connection “Reporting” isn't defined for this target." in the SQL bar, with **New Connection…**, and nothing runs until you choose a connection; the same happens for a deleted connection or a tab moved to a target without it.
- **The password in use** travels in the runner's request on standard input: a local pipe (a local project, or a connection from this Mac), `docker exec -i`, or the `ssh -T` channel. Never as an argument or environment variable, so it isn't in `ps`, `docker inspect`, the server's shell history, or `/proc/<pid>/environ`. The Run Log shows only the script's size. Code read from standard input isn't stored by [Keep compiled PHP](ssh.md)'s opcode file cache (a test checks the cache after a saved-connection run). The runner opens the connection in a function that takes no arguments, with `zend.exception_ignore_args` on, and replaces PDO's error with one that carries only its message. It forgets the password once the connection is open, and replaces it (and its URL-encoded forms) with `•••` in errors, notices, and log lines always, and in results too for passwords of 4 or more characters, so a very short password doesn't garble every result.
- **Lifecycle:** removing a target asks first ("Its 2 saved database connections are deleted too, with their passwords in the Keychain."); cancelling the editor after typing a password writes nothing; a Keychain that refuses a write keeps the definition and says the password wasn't saved. Because Runlet is ad-hoc signed, the login keychain trusts the build that saved the item; macOS's dialog reads like "Runlet wants to use your confidential information stored in “Runlet database: Reporting” in your keychain" and asks for the login keychain password. Developer ID signing ([#24](https://github.com/filipac/runlet/issues/24)) ends these prompts.
- **Development:** with a scratch `RUNLET_DATA_DIR`, Runlet uses its own Keychain service (`dev.runlet.Runlet.database.<8 hex of a hash of the folder>`), and Debug builds keep passwords in memory (`RUNLET_CREDENTIALS=memory`; `RUNLET_CREDENTIALS=keychain` uses that separate service instead), so development runs, screenshots, and tests never read or write the real items.
- **Not covered:** root on the target can read the PHP process's memory, and a saved connection used from a compromised server exposes its password to that server, as the application's own `.env` already does. AI clients' `run_php` can't use saved connections, and `list_targets` doesn't list them.

### Read-Only Enforcement

| Driver | How |
| --- | --- |
| MySQL / MariaDB | `SET SESSION TRANSACTION READ ONLY` (MySQL 5.6.5+, MariaDB 10.0+), checked with `@@session.transaction_read_only` (or `tx_read_only` on older servers). The error is "Cannot execute statement in a READ ONLY transaction". MySQL documents that changing temporary tables with DML stays possible in a read-only session; MariaDB 11 refuses even creating one (tested). Runlet refuses `CREATE TEMPORARY TABLE` and those writes before sending them anyway. |
| PostgreSQL | `SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY`, checked with `SHOW default_transaction_read_only`. Writes to tables other than temporary ones are refused, and every `CREATE`, `ALTER`, and `DROP`, temporary tables included ("cannot execute INSERT in a read-only transaction"). |
| SQLite | The file is opened read-only (`PDO::SQLITE_ATTR_OPEN_FLAGS` with `SQLITE_OPEN_READONLY`, PHP 7.3+; `Pdo\Sqlite` on 8.4+), and `PRAGMA query_only = ON`. Writes fail with "attempt to write a readonly database", even after `PRAGMA query_only = 0`. |

- When the session didn't become read-only, the run stops: "Runlet could not make the session of the read-only connection … read-only, so nothing ran". Before each later statement of a Run All, the runner sends the setting again, so a statement that got past the checks can't leave the session writable for the next one.
- Runlet refuses statements that would make the session writable again: `SET [SESSION|GLOBAL] TRANSACTION … READ WRITE`, `SET [SESSION] transaction_read_only`/`tx_read_only` (also as `@@session.…` and in `SET STATEMENT … FOR`), `SET default_transaction_read_only`, `SET SESSION CHARACTERISTICS`, `BEGIN … READ WRITE`, `START TRANSACTION … READ WRITE`, `RESET ALL` and `RESET` of those settings, `DISCARD ALL`, `PRAGMA query_only` in any form, `ALTER ROLE … SET default_transaction_read_only`, and any call of `set_config()` (which changes settings from inside a `SELECT`). It refuses statements that can write, by the rules of write detection: `INSERT`, `UPDATE`, `DELETE`, DDL, `SET`, `CALL`, `DO`, a writable `WITH`, `SELECT … INTO` (including `INTO OUTFILE`), `FOR UPDATE`, `EXPLAIN ANALYZE` of a write, `PRAGMA name = …` or `PRAGMA name(…)` (except the pragmas that read about a table, such as `table_info(…)`). And it refuses what it can't classify (`USE`, `LISTEN`, `CHECKPOINT`, …), or a second statement after a `;`.
- Reads run, and so does transaction control that doesn't ask for `READ WRITE` (`BEGIN`, `START TRANSACTION`, `COMMIT`, `ROLLBACK`, `SAVEPOINT`, `RELEASE`), which can't change data in a read-only session. Case and comments don't matter, and keywords inside strings and quoted names don't count. On MySQL the statement is read with backslash escapes and executable comments (`/*! … */`, MariaDB's `/*M! … */`); on PostgreSQL with `#` as an operator rather than a comment and `E'…'` strings. The refusal suggests a connection without Read-only. Run All names the first refused statement ("Statement 2 of 4 (line 3) …") and how many more would be. The runner checks again with the same rules before it connects, in case a request reaches it without the app's check.
- **Limits:** connect as a user with read privileges only (`GRANT SELECT …`, or PostgreSQL's `pg_read_all_data` role) for a guarantee. PostgreSQL's read-only transactions refuse writes from functions; MySQL's only refuse table writes, so `GET_LOCK()`, a stored function that writes elsewhere, or a `SELECT … LOCK IN SHARE MODE` lock can still run. `FOR UPDATE` is refused everywhere; `FOR SHARE` and `LOCK IN SHARE MODE` aren't refused by Runlet (PostgreSQL refuses them in a read-only transaction; MySQL takes the shared locks). A session setting lasts for the server connection it was sent on: behind a pooler in transaction mode (PgBouncer, ProxySQL), a later statement may run on another server connection without it, and the setting may stay on a connection the pooler later gives to someone else; use a direct connection or a session-mode pool. The READ-ONLY badge also shows in the connection lists and in each result's source line and a successful Test Connection.

### Connection Option Details

- The Advanced header sums up what is set ("TLS verify-full · 2 init statements · 1 option"). `targets.json` gets a key only for what is set: `socket`, `charset`, `tls` (`mode`, `ca`, `cert`, `key`), `initStatements`, `options`, and `dsn`. Connections saved before load unchanged. A TLS setting this Runlet can't read (from a newer one) leaves that connection out rather than connecting with less TLS than it asks for. Nothing here holds a password.
- **How each option is passed:** MySQL's socket is `unix_socket=<file>` (the port isn't used), PostgreSQL's is `host=<directory>` with the port naming the socket file (`.s.PGSQL.<port>`). Charset is `charset=` in the DSN (MySQL) or `client_encoding` (PostgreSQL); pdo_sqlsrv uses UTF-8. MySQL's CA, certificate, and key are `PDO::MYSQL_ATTR_SSL_CA`, `_CERT`, `_KEY` (`Pdo\Mysql::ATTR_*` on PHP 8.4+), PostgreSQL's `sslrootcert`, `sslcert`, `sslkey`; SQL Server's ODBC driver uses the system's CAs. The timeout is `PDO::ATTR_TIMEOUT` (libpq's `connect_timeout` on PostgreSQL) or `LoginTimeout=` in the DSN (SQL Server). MySQL's PDO DSN has no other keys for DSN options.
- **TLS:** "Driver default" sends no TLS setting: MySQL's PDO then doesn't encrypt, libpq prefers TLS, and Microsoft's ODBC driver 18 encrypts and verifies. MySQL / MariaDB (mysqlnd) encrypt only when an SSL attribute is set, and then check the certificate and the host name together unless `MYSQL_ATTR_SSL_VERIFY_SERVER_CERT` is false; so MySQL has *Require* (an empty CA, verification off: encrypted, not verified) and *Verify CA and host name* (the CA file, else PHP's default CAs from `openssl.cafile` or OpenSSL's), but no *Prefer* and no *Verify CA* alone, which the editor won't save. With either mode the runner checks `Ssl_cipher` after connecting and stops before anything runs if the session isn't encrypted. PostgreSQL (libpq) has all five `sslmode`s; with a CA file, libpq checks the CA under *Require* too. SQL Server (pdo_sqlsrv): *Off* is `Encrypt=no`, *Require* `Encrypt=yes;TrustServerCertificate=yes`, *Verify CA and host name* `Encrypt=yes;TrustServerCertificate=no`; pdo_dblib (FreeTDS) reads TLS from `freetds.conf` (`encryption`), so a connection that sets a TLS mode stops on a target that only has pdo_dblib, and says why.
- Certificate and key files aren't secrets, and Runlet never reads them; the runner checks only that they exist and can be read, so a missing file says so instead of a TLS error. Encrypted keys aren't supported because libpq's `sslpassword` would put the passphrase outside the Keychain, and MySQL's PDO has no setting for it.
- **Init statements** also run for every Run All, Load Schema, and Test Connection, and a trailing `;` is dropped. Transaction control (`BEGIN`, `START TRANSACTION`, `COMMIT`, `ROLLBACK`, `SAVEPOINT`) is refused on every connection, so an init statement can't leave a transaction open or end one. On a read-only connection they run *after* the session is made read-only, so the database refuses any write in them (a function called from a `SELECT` or a `SET @x = f()` included: tested on both servers), and the runner then sends the read-only setting again and checks it before your statement. Runlet also refuses, in the editor and again in the runner before connecting, what it refuses for read-only statements, except session settings that keep the session read-only: `SET search_path`, `SET TIME ZONE`, `SET ROLE`, `SET NAMES`, `SET SESSION sql_mode`, and so on are allowed; `SET default_transaction_read_only`, `SET SESSION TRANSACTION READ WRITE`, `SET SESSION CHARACTERISTICS`, `RESET ALL`, `PRAGMA query_only`, `set_config()`, and server-wide or account changes (`SET GLOBAL`, `SET PERSIST`, `SET PASSWORD`, `SET DEFAULT ROLE`) are not. The production sheet says "The connection's 2 init statements run first"; a failure says "Init statement 1 of the saved connection "Reporting" (…) failed, so nothing of yours ran: …".
- **DSN options** are appended as `key='value'` (PostgreSQL) or `Key=value` (SQL Server). Refused, in the editor and in the runner: keys that look like a password (`password`, `PWD`, `sslpassword`, `passfile`, anything with `pass` or `pwd`); keys the connection's own fields set (`host`, `port`, `dbname`, `user`, `sslmode`, `sslrootcert`, `sslcert`, `sslkey`, `client_encoding`, `connect_timeout`; `Server`, `Database`, `UID`, `Encrypt`, `TrustServerCertificate`, `LoginTimeout`); values with `;` (and braces for SQL Server) or control characters. An option pdo_sqlsrv doesn't know reaches you in its own words ("An invalid keyword 'Bogus' was specified in the DSN string.").
- **SQL Server** connects with `sqlsrv:Server=host,port;Database=…` or `dblib:host=host:port;dbname=…;charset=UTF-8`. Test Connection reports a missing extension ("has neither pdo_sqlsrv nor pdo_dblib, which SQL Server needs. It has: …") or pdo_sqlsrv's own message about its ODBC driver. The schema explorer reads columns through `INFORMATION_SCHEMA`. Read-only isn't available because SQL Server has no read-only session Runlet could enforce: connect as a user with only `db_datareader`. The generated DSNs are checked against pdo_sqlsrv's own keyword parser; a live fixture is [#53](https://github.com/filipac/runlet/issues/53).
- **Custom DSNs:** Runlet doesn't parse them, so the schema explorer reads only what the driver's catalogs answer, and there's no Read-only. The password goes to `new PDO()` as its own argument. Refused: a DSN that holds a password (`password=`, `pwd=`, `passwd=`, `sslpassword=`, or `user:secret@` in a URL), with "Runlet keeps passwords only in the Keychain"; a `uri:` DSN (PDO would read the DSN from a file or URL); line breaks. Test Connection names a missing driver ("has no pdo_oci driver for the DSN. It has: mysql, pgsql, sqlite.").

### Environment and TablePlus

- **Environment and colour** (#139): the production sheet says "The saved connection “Reporting replica” is marked as production" and shows the connection with its badge (and READ-ONLY when it is read-only). A development connection on a production target still asks, because the target is production. The production grace never applies to SQL. The editor's header shows the marking runs will use. On a production connection, a statement doesn't also read the schema; only Load Schema does. Run History uses the connection's colour, else the target's. `targets.json` stores `readOnly`, `environment`, and `color`, left out at their defaults; connections saved before load as read-write development connections without a colour.
- **TablePlus import** (#188): Runlet also reads the group names in `ConnectionGroups.plist` next to `Connections.plist`, and the Setapp edition's folder is `com.tinyapp.TablePlus-setapp`. Nothing is read at launch. **Select All** selects the importable rows; production rows get a red **Production** badge, and MongoDB rows **SRV** and **Replica set** badges. Rows are greyed out for databases Runlet has no connections for (Cassandra, DynamoDB, etcd, Elasticsearch, …), drivers it has no driver for (Oracle and others: create those with a custom PDO DSN), and connections whose host or database Runlet refuses (or, for MongoDB, whose host and connection string it can't read). A connection counts as already saved when it was imported before (Runlet remembers TablePlus's connection id as `importedFrom` in `targets.json`, not a secret) or when one with the same name is saved where it goes; **Update** replaces its definition with TablePlus's (its name too, when no other connection there has TablePlus's name), keeps its password unless one is copied, and leaves it where it was saved.
  - Mapping details: host, port, database, and user carry over, with the driver's default port left empty; a socket becomes a Unix socket (MySQL, PostgreSQL). TLS modes map to Off, Require, Verify CA, or Verify CA and host name (PostgreSQL also Prefer); MySQL's PDO driver has no Verify CA, so TablePlus's Verify CA becomes Verify CA and host name, with a note; a mode Runlet can't read stays at the driver's default, with a note; TLS key and certificate files aren't copied (a note says so). An unknown tag that mentions "prod" is production; any other is development, with a note. Greys get no colour. SQL Server's read-only switch becomes a note; TablePlus's safe mode only leaves a note, since its levels aren't documented. MongoDB takes host, port, database, user, authentication database and mechanism, replica set, read preference, TLS, and SRV from TablePlus's fields or its `mongodb://` / `mongodb+srv://` connection string, which isn't stored ([MongoDB](mongodb.md#import-from-tableplus)).
  - SSH: an existing SSH profile with the same host, port (22 when unset), and user is chosen by default; otherwise **New SSH profile: <name>**, one per SSH server (host, port, and user), shared by every imported connection on it, named after the SSH host (with a number when that name is taken). The sheet lists the profiles it will create and the summary those it created. A key file login gives a key profile with that path as its **Key file** (`ssh -i`; Runlet passes only the path and never reads or copies the key); a password login a **Password or two-factor code** profile (you log in with Connect…); an agent login an agent profile. The profile's folder on the server is `/`, since it's for the tunnel; set the application's folder to run PHP there. It's marked production only when every connection using it is (the least strict of their tags); each connection's own marking still applies. Creating it connects nothing. Any other profile can be picked, or **Don't import over SSH** (straight to the host, with a note). An SRV MongoDB connection can't use a tunnel (DNS names its servers), so it has no picker and connects from this Mac directly, with a note.
  - Passwords: TablePlus keeps database passwords as generic-password items, service `com.tableplus.TablePlus`, account `<connection id>_database`. A copied password goes into Runlet's Keychain item for the connection (`CredentialStore`), as if typed in the editor: never into a file, a log, history, the summary, or an AI client. A missing or empty item, macOS refusing to read it, or a connection without a TablePlus id imports without a password, with a note. A password inside a MongoDB connection string is copied only when the box is ticked (without a Keychain prompt, since it's in TablePlus's file), and otherwise left out with a note; the sheet says which rows have one, never the password. The Mac App Store edition of TablePlus may keep its items where Runlet can't read them. The summary also lists approximated TLS modes, renamed connections, and connections without SSH.
  - Why this is allowed: Runlet never reads credentials from *your application's configuration* to create saved connections. This import is a separate, explicit, user-started copy from another database client on the same Mac: it reads TablePlus's files only when you click, and its Keychain items only when you tick the box, with macOS asking for each.

### Validation

- `TablePlusImportTests` (RunletCore, #188): made-up fixtures in `Tests/Fixtures/tableplus/` (every supported driver, SSH with a key file, a password, and an agent, TLS, a socket, tags, nested groups, unsupported drivers, missing and odd fields, entries that aren't connections, garbage and binary property lists); the mapping (drivers, TLS per driver, tags, colours, read-only); duplicates skipped by default or updated, by TablePlus id and by name; unique names within an import; the scope; an existing SSH profile matched, one new profile shared by a server's connections, the key, password, and agent logins, name clashes, and Don't import over SSH; passwords opt-in through a fake Keychain reader (found, denied, missing, empty, a refused Keychain write); and that no fixture password is in `targets.json`, its last-good copy, `settings.json`, a workspace, or the summary. `FeatureFlagTests` (RunletCore, #187) covers the flag. The Debug app with the fixture folder (`scripts/tableplus-import-screenshots.py`): the flag off, Settings ▸ Advanced, the button, the sheet (a new and an existing SSH profile, a duplicate, production, unsupported rows), the password option, and the summary.
- `LocalConnectionTests` (RunletCore, #142): Connect From and All targets in `targets.json` (written only when used, and left out by an older Runlet), connections saved before #142 opening from the target, an unknown place leaving the connection out, every target (the sandbox too) finding connections of all targets by id and by name after its own, names unique per scope, absolute and `~` paths from this Mac, the stricter marking on every target, and duplicates keeping their place.
- `LocalConnectionLaunchTests` (RunletExecution, host PHP, SQLite, #142): Runlet's PHP chosen first, then the default, then the automatic one, with labels that never show a path; the empty `0700` folder and the local snapshot; the engine refusing a connection from this Mac on a Docker, SSH, or project snapshot for runs, Load Schema, and Test Connection before launching anything; a statement, the schema, and Test Connection (with its PDO drivers) from Runlet's folder with no project code, nothing written to it, and the password in no event; messages that say this Mac (a missing file, a missing driver with Runlet's PHP named, a custom DSN's driver) while a target's connection keeps saying the target. With `RUNLET_TEST_RUNLET_PHP` (a scratch install's `bin/php`), Runlet's PHP reports `mysql`, `pgsql`, and `sqlite`.
- `PHPDriverChoiceTests`, `PHPDriversTests`, and `PHPDriverProbeTests` (#184): the PHP chosen for every kind (MySQL, PostgreSQL, SQLite, SQL Server with `sqlsrv` or `dblib`, a custom DSN by its prefix, MongoDB, and Redis needing nothing) from driver lists, one order for every driver (`MongoLaunch.candidates` is the same list), the reason when it isn't the first PHP, the "no PHP has …" message naming the driver and the PHPs checked, a PHP with unknown drivers tried only as a last resort, the cache (listed installations never probed, an unlisted path probed once even when asked for twice at once, a failed probe not retried, all read again after the installations change), and the probe against host PHP (and Runlet's PHP with `RUNLET_TEST_RUNLET_PHP`: `mysql`, `pgsql`, `sqlite`, phpredis, ext-mongodb, so SQL Server goes elsewhere).
- `SQLLiveFromThisMacTests` (live servers, #142): on MariaDB 11 and PostgreSQL 14 through their published ports, in a `p142_orders` table created by the test, a connection of all targets opened from this Mac runs Test Connection, a statement with a bound value and its schema, Run All in a transaction, Load Schema, Explain, and Load Next; a read-only one refuses a write; a wrong password fails with the password in no event. With `RUNLET_TEST_RUNLET_PHP`, the same runs use Runlet's PHP too.
- `SSHTunnelConnectionTests` (RunletCore, #143): `"connectFrom": "sshTunnel"` and `"sshProfile"` written only for tunnelled connections (files from before encode byte for byte as they did), normalization (no socket; only a tunnel keeps its profile; all targets and duplicates keep the tunnel), validation (SQLite, custom DSNs, no profile, `hostaddr`), a removed profile leaving the connection "missing" and never retargeted, the SSH profile's environment in the stricter marking, and history and snippets finding a tunnelled connection by id, then by name.
- `SSHTunnelTests` (RunletExecution, #143): the `-O forward` / `-O cancel` command lines (`-F /dev/null`, loopback only, IPv6 in brackets; runs keep `ClearAllForwardings=yes`), free loopback ports, the forward lifecycle with a fake master (reused while in use, cancelled after the idle time, a closed tab waiting for the last run, Disconnect and quit, a taken port retried, a changed connection replacing its forward, a missing master reported and forgotten, concurrent runs sharing one forward), the runner's DSNs through a tunnel (PostgreSQL `host=<server>;hostaddr=127.0.0.1`, MySQL and SQL Server on 127.0.0.1, `hostaddr` refused), the Run Log's forward line, and the engine refusing a tunnelled connection without its forward.
- `SQLLiveTunnelTests` (live, #143): the SSH fixture forwards to MariaDB 11 and PostgreSQL 14 by their Compose service names, which this Mac can't resolve: Test Connection, a statement with a bound value, Run All, Load Schema, Show Definition, Explain, Load Next, Stop's server cancel through the same forward, the Database pane's Server section reading the overview and sessions and cancelling a listed query through the forward, PostgreSQL verify-full accepting the certificate's name and refusing an address it doesn't name, a history entry and a snippet running again through the tunnel, the listener owned by `ssh` on 127.0.0.1 only and gone after use or the idle time, and a master that isn't open never opened by the tunnel. Tables are `p143_*`.
- The Debug app, with scratch data, the fixture servers, and passwords in memory: the editor's Available on and Connect From, a connection of all targets with Test Connection naming the PHP and its drivers, the picker of a project and of the sandbox (light and dark), a result from this Mac, and Edit Connections…. Screenshots are in [PR #175](https://github.com/filipac/runlet/pull/175). #143: a connection through the fixture's SSH tunnel (a scratch SSH config, the fixture's key, no agent), its result, Test Connection's report, the picker, and a statement reopened from Run History and run again on the same forward, in [PR #177](https://github.com/filipac/runlet/pull/177).

- `SavedConnectionTests` (RunletCore): `DatabaseConnection` coding and validation (names, hosts, ports, database names, SQLite paths, timeouts), `targets.json` from before saved connections and with a newer Runlet's driver, the cascade when a target is removed, duplicates without passwords, that `targets.json` (and its last-good copy), sessions, workspaces, and the encoded `RunRequest` hold no password, `SensitiveString`'s redaction, the in-memory store, the scratch data folder's Keychain service, and that `list_targets` leaves saved connections out. A real Keychain round trip under a test-only service runs only with `RUNLET_TEST_KEYCHAIN=1`.
- `SQLSavedConnectionTests` (RunletExecution, host PHP, SQLite): a statement, Run All, and the schema through a saved connection, with a project driver whose file and bootstrap leave markers that must not appear; Test Connection, with a stored or a typed password; a Keychain that can't be read stopping the run before PHP starts; every event of successful and failed runs (including the Run Log) scanned for the password; a short password scrubbed from messages only; and PHP 7.4. In the Docker fixtures (`php:8.4-cli`, `php:7.4-cli`): an in-memory SQLite connection and the missing-driver message for PostgreSQL. On the SSH fixture with Keep compiled PHP: a run on the server, the missing-driver message, and an opcode cache that holds no password.
- `SQLLiveDatabaseTests.savedConnections` (live servers): MariaDB 11 and PostgreSQL 14 through saved connections from a plain PHP project: Test Connection's version, database, and user; a statement with its schema; MySQL's error echoing the statement with the password replaced; and a wrong password's error, which holds neither password.
- The Debug app, with scratch data and fixture passwords in memory: the connection editor, a successful Test Connection against the fixture PostgreSQL, the SQL bar's list with application and saved connections, a result from a saved connection, and the schema explorer on it. Screenshots are in [PR #157](https://github.com/filipac/runlet/pull/157).

- `ReadOnlyConnectionTests` (RunletCore): every session-changing form refused, whatever the case and comments; writes and unknown statements refused; reads and plain transaction control allowed; each database's reading (MySQL's backslash escapes and executable comments, PostgreSQL's `#` and `E''` strings); the stricter marking and its colour; connections and `targets.json` saved before this phase decoding unchanged, with nothing at its default written; the run request's flag; Test Connection's summary.
- `SQLReadOnlyConnectionTests` (RunletExecution, host PHP, SQLite): reads, Run All of reads and transaction control, the schema, and Test Connection in a read-only session; the runner refusing writes and session changes (and a whole Run All) before connecting; an `INSERT` sent past both checks failing in SQLite, also after `PRAGMA query_only = 0`, while the same connection without Read-only writes; PHP 7.4; and the runner's rules agreeing with the app's on the same statements.
- `SQLLiveDatabaseTests.readOnlySavedConnections` (live servers): on MariaDB 11 and PostgreSQL 14, reads, the schema, and Test Connection in a read-only session; `INSERT`, `UPDATE`, `CREATE TABLE`, `DROP TABLE`, `SET SESSION TRANSACTION READ WRITE`, and each server's other session changes refused by Runlet; the same writes, a temporary table, `FOR UPDATE`, and `nextval()` sent past the checks failing in the database; a session switched back read-write past the checks being read-only again for Run All's next statement; Run All of reads with and without a transaction; and a script with one write refused whole.
- The Debug app, with scratch data and fixture passwords in memory: the editor with Read-only, a production marking, and a colour after Test Connection; the SQL bar's list with the badges; the production confirmation for a production connection on a development target; its result in a read-only session; Run History marking it as production; and an `UPDATE` refused. Screenshots are in [PR #161](https://github.com/filipac/runlet/pull/161).

- `ConnectionOptionsTests` (RunletCore, #140): connections and `targets.json` saved before keeping their keys; the options round-tripping and written only when set; a TLS setting from a newer Runlet leaving the connection out; normalization per driver (a socket replacing the host, TLS files dropped with TLS off, init statements and options trimmed, the DSN kept only for custom); validation of sockets, charsets, each driver's TLS modes, TLS files, DSN options (password-like and field-managed keys refused), custom DSNs (passwords, `uri:`), Read-only per driver; the init statement rules on read-write and read-only connections; Test Connection's TLS summary.
- `SQLConnectionOptionsTests` (RunletExecution, host PHP 8.4 and 7.4, #140): the DSN and PDO attributes the runner builds for each driver from the real request (MySQL host and socket, `Pdo\Mysql::ATTR_*` on 8.4 and `PDO::MYSQL_ATTR_*` on 7.4, PostgreSQL socket, quoting, TLS files, encoding and options, SQL Server through pdo_sqlsrv and pdo_dblib, custom DSNs, read-only SQLite's open flags); what a driver can't express stopping before connecting, with no password in any event; init statements on every run, Test Connection, and the schema, a failing one, and transaction control refused; init statements keeping a read-only SQLite session read-only, and the runner refusing undoing or writing ones; the runner's and the app's init rules agreeing; a custom SQLite DSN with the schema; and every SQL Server DSN Runlet builds accepted by host PHP's pdo_sqlsrv keyword parser (it then reports its missing ODBC driver), with an unknown keyword reported in pdo_sqlsrv's words.
- `SQLLiveTLSTests` (live servers with TLS, #140): `scripts/setup-fixtures.sh databases` gives both fixtures throwaway certificates (a test CA, a server certificate for `localhost` and `127.0.0.1`, a client certificate, and a second CA that signed nothing, in `runlet-fixtures/tls` under Git's common directory, which every worktree shares, [#176](https://github.com/filipac/runlet/issues/176)) and prints `RUNLET_TEST_TLS`; both still accept plain connections. On PostgreSQL 14: Off reports no encryption; Prefer, Require, Verify CA, and Verify CA and host name encrypt (TLSv1.3); the other CA fails Require, Verify CA, and Verify; a host name the certificate doesn't name (through `hostaddr`) passes Verify CA and fails Verify CA and host name; the client certificate reaches `pg_stat_ssl`; `client_encoding` and `application_name` apply; init statements on a read-only connection set the search path and time zone, a writing function in one is refused by the read-only session, and `SET default_transaction_read_only = off` is refused before connecting. On MariaDB 11: no TLS without a mode; Require and Verify encrypt; the other CA passes Require and fails Verify; a `REQUIRE SSL` user is refused without TLS and admitted with it; a `REQUIRE X509` user needs the client certificate; the charset applies; init statements on a read-only connection, a writing stored function in a `SET` refused by the session, and `SET GLOBAL` refused before connecting. PHP 7.4 encrypts on both (Herd's 7.4.33 build crashes when mysqlnd's certificate check fails, so only successes run there).
- The Debug app, with scratch data, fixture passwords in memory, and the fixture PostgreSQL with TLS: the editor's Advanced section (TLS with a CA and client certificate, init statements, a DSN option) and a successful Test Connection reporting TLSv1.3; the production confirmation listing the init statements; the result showing them applied over TLS; a SQL Server connection and its Test Connection on a PHP with pdo_sqlsrv but no ODBC driver; a custom DSN for a driver the PHP lacks. Light and dark screenshots are in [PR #165](https://github.com/filipac/runlet/pull/165).
