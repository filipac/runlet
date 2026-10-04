# Connection Manager

The Connection Manager ([#180](https://github.com/filipac/runlet/issues/180)) lists everything Runlet has open right now, in one place, and closes any one of them.

Open it in any of these ways:

- Click the connection count in a window's status bar (bottom right). Its tooltip has the counts per kind. At zero the count stays, dimmed, so the window is always a click away. While runs wait for a free run slot, an hourglass with their number follows the count (see [Queued runs](#queued-runs)).
- Choose **Window ▸ Connections** (⇧⌘C; change it in Settings ▸ Shortcuts).
- Search for "connections" in Open Anything (⌘P), or run the command from the Command Palette.

It is one window. Opening it again brings it to the front.

## What it lists

The list is grouped by kind. Each row shows what the connection is, where it goes, which tab or feature uses it, when it started, and a production badge when the target, the SSH profile, or the saved connection is marked production.

| Section | Rows | Where it goes |
| --- | --- | --- |
| **SSH Connections** | An SSH profile's shared connection (OpenSSH control master), from Connect… or opened by a run. The row says how its login closes: a password or 2FA login stays until you disconnect; an agent or key login closes after the profile's Keep connection time, or when Runlet quits. | `user@host:port`, and the jump host |
| **SSH Tunnels** | A forward that a saved connection opens through an SSH profile ([#143](https://github.com/filipac/runlet/issues/143); see [SQL tunnels](ssh.md#sql-tunnels)). The row shows when it opened, when it was last used, and whether a run holds it. | `127.0.0.1:<port> → <host>:<port> through <profile>` |
| **Database Sessions** | Running SQL work: a statement, Run All, Explain and Explain Analyze, a Load Next page, Load Schema, Show Definition, and the Database pane's Server reads, Cancel Query, and Kill Session. A statement's row shows its first line and the session id on the server once the database reported it. | The driver, the database, and the connection: the application's connection of a target, or a saved connection with where it opens (the target's PHP, this Mac, or through an SSH profile's tunnel) |
| **PHP Runs** | Runs in progress on every target: the sandbox, local projects, Docker, and SSH. The row shows the code's first line. | The target |
| **AI Clients** | AI clients connected to Runlet's MCP server ([#43](https://github.com/filipac/runlet/issues/43)), by the name the client reports. | Runlet's MCP server on this Mac |
| **Log Follows** | A log the [Logs window](logs.md) follows in a container or on a server ([#20](https://github.com/filipac/runlet/issues/20)): `docker logs`, `docker exec … tail -F`, or `ssh … tail -F`. Read-only; files on this Mac open no connection and aren't listed. | `tail -F on <host>`, `docker logs <container> on this Mac`, … |

An SSH connection's row also says what uses it ("Used by 1 SSH tunnel, 1 database session, and 1 PHP run"): runs on its profile, statements that run there, and tunnels on it. A tunnel's row says which statements use it.

**Database sessions exist only while work runs.** Runlet opens a database connection per statement, in a fresh PHP process, and keeps no idle connections or pool. So a database row appears when a statement starts and goes away when it ends.

The list updates by itself as things open and close. It only shows state Runlet already keeps: listing never connects, reads, or runs anything. While the window is open, it looks at the SSH profiles' control sockets on this Mac every few seconds (a local check, like the status bar's SSH status), so a shared connection that ended by itself (its keep time, a network change) leaves the list. Nothing goes to the network.

## Queued runs

Runlet runs at most four runner processes at once. A further run (a PHP run or an SQL tab's statement) waits for a free **run slot** ([#183](https://github.com/filipac/runlet/issues/183)). A waiting run has started nothing: no PHP process, no database connection, and no use of an SSH connection or tunnel. So the Connection Manager lists it, but doesn't count it:

- Its row stays in its kind's section (PHP Runs or Database Sessions), after the active rows and in the order the runs will start, marked **Queued**. It shows "Queued since 10:42 (12 s)" and its place: "Next to start" or "2nd in line". The section header shows "1 queued" beside its count.
- The status bar count and the window's header count active connections only. While runs wait, the status bar shows an hourglass with their number, the header says "8 active connections, 1 run queued", and the tooltip starts "8 active, 1 queued" with a line per kind ("4 PHP runs, 1 queued").
- An SSH connection's or a tunnel's "Used by" doesn't include queued runs, and Close on an SSH connection doesn't say they end with it: they haven't used it yet. (A tunnel added for a queued statement still says the run holds it: the forward was added before the run was queued.)
- When the run gets its slot, its row becomes an ordinary running row, and "since" restarts at the time it actually started.
- **Close** on a queued row takes it out of the queue, as the tab's Stop does. Nothing was launched or sent, so there is nothing to cancel on a server.

The tab says so too: its status bar shows "Queued · next to start" instead of the timer, an SQL tab's running row says it connects when it starts, and the output and the Run Log say why it waits ("4 runs are going, at most 4 at once; next to start") and, on Stop, "Removed from the queue before it started; nothing was sent." Once it runs, the Run Log says how long it waited.

Database work outside tabs (Load Schema, Load Next, the Database pane's Server section) waits for a slot the same way, but its rows are listed as running while they wait.

## Close

Every row has a **Close** button and a context menu with Close, **Reveal Tab** (selects the tab the connection belongs to, when there is one), and Copy Destination.

| Kind | What Close does | Asks first |
| --- | --- | --- |
| SSH connection | Disconnects the shared connection (`ssh -O exit`), as the profile's **Disconnect** does. The profile's tunnels are removed first. | When runs, statements, or tunnels use it ("they end with it"), or when its login used a password or 2FA ("you'll have to log in again with Connect…") |
| SSH tunnel | Cancels the forward (`ssh -O cancel`). The SSH connection stays, and the next run adds the tunnel again. | When a run holds it (a statement, a schema read, Test Connection) |
| Database session | Stops the work as its own Stop does. For a statement, Run All, Explain Analyze, and a Load Next page, Stop [cancels the statement on the server](sql-tabs.md#stopping-a-statement) first. Load Schema and the Server section's reads stop; Show Definition's sheet closes. | Never |
| PHP run | Stops the run, as the tab's Stop does. | Never |
| Log follow | Stops following, as the Logs window's Stop does: the `tail` (or `docker logs`) ends in the container or on the server too. | Never |
| AI client | Drops that client's connection. Its requests waiting for approval are withdrawn, and runs it started finish in their tabs. The MCP server keeps listening, so the client's next tool call connects again. To refuse clients, turn off Settings ▸ AI Clients ▸ Allow AI clients to connect. | Never |

Closing never asks the production question: stopping and disconnecting are always allowed. A row whose Close is under way shows **Closing…**.

## No secrets

Rows show host names, ports, user names, database names, and connection names. They never show a password, a token, a key, or a DSN with credentials: Runlet doesn't put them in, and the list removes anything that looks like one (`user:password@`, `password=…`, `IDENTIFIED BY '…'`) from every row's text. Tunnels show only `host:port`.

## For developers

The model is in `RunletCore` (`ActiveConnections.swift`: `ActiveConnection`, `ActiveConnectionList`, `ConnectionRows`, `ConnectionText`), with unit tests in `ActiveConnectionsTests`. The app's providers are in `Runlet/App/AppModel+Connections.swift`, one per kind, each reading existing state (SSH statuses, `SQLTunnelStore.active`, tabs' run state, the database work it tracks, `MCPStore.connections`). See [architecture.md](architecture.md). `scripts/connection-manager-screenshots.py` drives a Debug build end to end with scratch data and the runlet-fixtures SSH host and databases, and checks that Close cancels the MariaDB statement on the server and removes the tunnel's listener.

Queued runs (#183): `ExecutionEngine` admits each run as it accepts it, to a slot or to the end of its queue, and publishes `RunSlots` (RunletCore: the runs holding a slot since when, and the queue in order) on `slotChanges` after every change; the app follows it (`AppModel.followRunSlots`, into `ConnectionManagerStore.slots`), so nothing polls. `TabRunConnectionProvider` maps a run's `RunSlots.State` onto its row (`ActiveConnection.withSlot`: `isQueued`, `queuePosition`, and `startedAt`); `ActiveConnectionList` leaves queued rows out of `count`, `count(of:)`, and `users(of:)`, and reports them in `queuedCount`. `cancel(runId:)` on a queued run takes it out of the queue (its launch task ends with `finished` cancelled, before any process). Tests: `ActiveConnectionsTests` (mapping, counts, tooltip, usage) and `RunSlotsTests` (one slot and two sleeps, Stop on a queued run, positions). `scripts/queued-runs-screenshots.py` drives a Debug build with six local tabs.
