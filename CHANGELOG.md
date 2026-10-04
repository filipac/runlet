# Changelog

All notable changes to Runlet are recorded here. Dates use ISO format.

## Unreleased

### 2026-10-04 — Show Relations: a table's foreign key diagram ([#153](https://github.com/filipac/runlet/issues/153))

- **A diagram from the loaded schema.** **Show Relations** (a table's context menu in the
  Database pane, or its new diagram button) opens a window with the table in the middle, the
  tables it references on the left, and the tables that reference it on the right, one or two
  hops out. It draws the schema the pane already loaded: nothing is read and nothing runs. If
  the schema is forgotten, the window offers Load Schema, which asks on production.
- **Keys and columns.** Boxes show primary, foreign, and referenced key columns with their types
  (**All Columns** shows every one). Each foreign key is one labelled line (`customer_id → id`);
  a composite key is one line listing every pair, and a self-reference loops back on its table.
  Tables outside the loaded schema show dashed.
- **Re-centre, Back, Forward.** Click a table to centre on it; its menu has Open in SQL Tab and
  Show Definition.
- **Copy Join and Insert Join.** Select a key to see its `JOIN … ON …` (every pair of a composite
  key joined by `AND`, a self-join under an alias, names quoted for the database), then copy it or
  insert it into the current SQL tab. Nothing runs.
- **Readable when large.** Columns wrap past 12 tables; up to 50 related tables all show, and
  past that the rest collapse into "+N more" boxes that expand on click. Zoom, pinch, and Zoom to
  Fit.
- **Export** as PNG or SVG (the SVG is made from the layout, with a dark variant).
- **For developers.** The schema reader now also reports each table's foreign key constraints
  (`foreignKeys`), so a composite key is one relation; column `references` are unchanged.
  `SQLRelations`, `SQLRelationsLayout`, and `SQLRelationsSVG` in RunletCore; the
  `relations` window in `Runlet/Features/RelationsDiagram.swift`; `relations-*` DEBUG steps;
  `scripts/relations-diagram-screenshots.py`.

### 2026-10-04 — `\Runlet\notice()`, `warning()`, and `error()` cards, and a snippet API reference ([#196](https://github.com/filipac/runlet/issues/196))

- **Your own cards.** `\Runlet\notice($message, $context)`, `\Runlet\warning(…)`, and
  `\Runlet\error($messageOrThrowable, $context)` put blue notice, orange warning, and red error
  cards in the output, with a link to the snippet line that called them (or the first project
  file outside `vendor/`) and `$context` as a collapsed value. With a caught `Throwable`, the
  error card shows its class, where it was thrown, its cause, and its stack trace. They work on
  every target and PHP 7.4+, whether the run inspector is on or off. `Inspector::notice()` is
  now public, and `Inspector::warning()` and `Inspector::error()` do the same; Runlet's own
  notices are unchanged.
- **Never a failure.** An error card doesn't end the run or mark it failed: the run's status,
  Run History, and notifications for long runs ignore it. The run's footer counts the warnings
  and errors ("2 warnings, 1 error"). MCP results include each card as a line ("Warning
  (line 3): …") and in `structuredContent.messages`.
- **Bounded and scrubbed.** A message keeps 16 KB, a run shows at most 200 cards (8 MB), then
  one notice says how many were left out; a saved connection's password is replaced by `•••`.
  The functions never throw. `trigger_error()` keeps PHP's or the framework's behaviour.
- **Completion.** `\Runlet\` completes and hovers in the editor (functions and the inspector's
  public methods), from an in-memory stub PHPantom gets at every start; a test keeps it in
  step with the runner.
- **One reference.** [docs/snippet-api.md](docs/snippet-api.md) covers everything a snippet can
  use: output, magic comments, the `Runlet\` functions, the run inspector, snippet inputs, and
  driver variables. Linked from the readme and the driver guide.
- **For developers.** `Resources/Runner/src/SnippetMessages.php`; the `notice` event gains
  `level`, `user`, a location, `context`, and `exception`, decoded as
  `RunEvent.Kind.snippetMessage` (a plain `{message}` stays a notice). Tests:
  `SnippetMessageRunnerTests`, `SnippetMessageRemoteTests` (Docker and SSH fixtures),
  `SnippetMessageTests`, and `RunletAPIStubTests`.

### 2026-10-04 — WordPress mail in the run inspector, with Intercept Mail ([#192](https://github.com/filipac/runlet/issues/192))

- **`wp_mail()` in the Mail section.** WordPress runs list every message a snippet or a plugin
  sends: To, Cc, Bcc, From, Reply-To, the subject, the HTML or text body for the preview,
  attachments with their sizes, and inline images. **Sent by** names the plugin, must-use
  plugin, or theme that called `wp_mail()` (with its file and line), or the core function
  (`WordPress core: wp_new_user_notification()`). A message that `wp_mail_failed` reports shows
  as **Failed**, in red, with PHPMailer's error.
- **Intercept Mail for WordPress.** With interception on (the same setting and overrides as
  Laravel and Symfony), a `pre_wp_mail` filter stops each message before PHPMailer on
  WordPress 5.7+, and `wp_mail()` tells its caller the mail was sent. The hooks go in before
  `wp-load.php`, so mail sent while WordPress boots is covered, and no file is added to the
  project. Runlet confirms interception only when it is guaranteed; otherwise its warning, and
  the mail chip, say why: an older WordPress, "A plugin (acme-smtp) replaces wp_mail(); Runlet
  can't stop its mail.", or another `pre_wp_mail` callback that could send mail itself. Mail
  that WP-Cron or Action Scheduler sends later is outside the run. See
  [docs/drivers.md](docs/drivers.md) ▸ *WordPress mail*.
- **For driver authors.** `Inspector::mail()` takes `caller`, `error`, and `location`, and
  `Inspector::cannotInterceptMail($reason)` puts the driver's reason into Runlet's warning.
- **Tests.** Execution tests on the WordPress fixture (recorded fields, interception with an
  empty test sink, sending to the sink, core senders, failures, a must-use plugin that replaces
  `wp_mail()`, boot-time mail, another `pre_wp_mail` callback, PHP 7.4) and on a Docker target,
  the new `wordpress` service of the `runlet-fixtures` Compose project. A test mail sink
  replaces PHPMailer's transport, and a guard fails the run if it isn't in place, so no test
  sends mail.

### 2026-10-04 — Feature flags, and importing saved connections from TablePlus ([#187](https://github.com/filipac/runlet/issues/187), [#188](https://github.com/filipac/runlet/issues/188))

- **Settings ▸ Advanced, hidden until you ask.** Press ⌥⌘, (or hold ⌥ while choosing
  Settings…) and Settings opens on a new Advanced tab with **feature flags**: hidden or
  experimental features, each with a description and a switch, all off by default. The tab stays
  until **Hide Advanced Settings**. Flags are saved in `settings.json` (`featureFlags`); older
  files load with every flag off, and flags this Runlet doesn't know are kept. Turning a flag off
  hides its feature and deletes nothing it made. Debug builds also take
  `RUNLET_FEATURE_FLAGS=a,b`. Settings is a little wider (600 pt; 640 with Advanced) so every
  tab fits in its toolbar. See [docs/settings.md](docs/settings.md).
- **Import from TablePlus…** (the first flag, **Import connections from TablePlus**): in
  Settings ▸ Databases and Edit Connections. Runlet reads TablePlus's connection list
  (`Connections.plist`, with its groups) when you click, or a copy you choose, and lists every
  connection, none selected: name, driver, host, database, user, group, environment tag, TLS, and
  SSH. Redis, MongoDB, Cassandra, and other drivers Runlet can't open are greyed out with the
  reason. The selected connections become saved connections for all targets (or one target)
  that connect from this Mac: MySQL and MariaDB, PostgreSQL, SQLite files, and SQL Server, with
  their socket, TLS mode, colour, and read-only switch; TablePlus's **production** tag makes them
  production. Connections imported before (Runlet remembers TablePlus's id) or with a name already
  saved are skipped, or updated if you choose. Nothing connects; a summary lists what was
  imported, updated, skipped, and needs attention.
- **SSH profiles from TablePlus's SSH settings.** A connection TablePlus opens over SSH connects
  through an SSH profile's tunnel ([#143](https://github.com/filipac/runlet/issues/143)): an
  existing profile with the same host, port, and user, else a **new SSH profile** the import
  creates, one per server, shared by its connections and named after the host. Key file logins
  give the profile that **Key file** (a new field in the SSH profile form, passed as `ssh -i`;
  Runlet never reads the key), password logins a Connect… profile, agent logins an agent
  profile. A row can also use another profile or no SSH. The new profile is production only when
  all its connections are. TablePlus's SSH passwords and key passphrases are never copied.
- **Passwords only if you ask.** "Also copy passwords from TablePlus's Keychain items" is off by
  default. When ticked, macOS asks for each item, and each password goes straight into Runlet's
  own Keychain item for the connection, never into a file, log, or AI client. A denied or missing
  item imports the connection without a password, with a note. Development runs, tests, and
  screenshots use made-up fixtures (`Tests/Fixtures/tableplus`, `RUNLET_TABLEPLUS_DIR` in Debug
  builds) and a fake Keychain reader. See
  [docs/sql-tabs.md](docs/sql-tabs.md#import-from-tableplus).

### 2026-10-04 — The mail chip shows the mail mode and switches it ([#193](https://github.com/filipac/runlet/issues/193))

- **Always shown.** The output header's mail chip now shows on every PHP tab, not only while
  mail is intercepted: **Intercepting Mail** (orange), **Sending Mail** (grey, or red on a
  production target), or a dimmed **Mail: inspector off** when the run inspector is off. It
  follows the tab's target and the settings as they change. SQL tabs don't show it.
- **Switch from the chip.** Its popover says where the mode comes from (the target's options, or
  the default in Settings ▸ General ▸ Run Inspector) and has the target editor's **Mail** picker:
  Default, Intercept (record, don't send), or Send. The choice is saved as the target's Mail
  option, as the editor saves it, and applies from the next run. **Open Settings…** opens
  Settings ▸ General; with the inspector off, **Turn On Run Inspector** turns it on. The sandbox,
  which has no option of its own, keeps the switch for the default in Settings.
- **Production asks first.** Switching a production target that intercepts mail to sending asks
  for confirmation in the popover. Intercept never asks.
- **Support from the runs.** After a run on the target asked for interception, the popover says
  whether a driver confirmed it, or quotes the run's warning that it isn't confirmed for this
  project's driver. There is no list of drivers, so drivers that learn to intercept (WordPress,
  [#192](https://github.com/filipac/runlet/issues/192)) show as confirmed without changes here.
- **For developers.** `TargetLibrary.mailInterception(for:global:runInspector:)` in RunletCore
  (`MailInterception.swift`, with tests) gives the mode, its source, and the production rule.
  Debug steps `target:<name>`, `run-inspector:on|off`, `mail-chip:on|off|choose:<option>`, and
  `mail-chip-state` take the screenshots. See [docs/drivers.md](docs/drivers.md#the-mail-chip).

### 2026-10-04 — Development: live cancel tests can't hang the test run ([#182](https://github.com/filipac/runlet/issues/182))

- **Every process wait in the live database tests has a deadline.** `waitUntilExit()` on a
  Swift-concurrency thread can block for good when `run()` happened on another thread (`run()`,
  an `await`, then the wait), which is how `killingOnlyTheProcessLeavesMariaDBRunning` once hung
  a whole `swift test --no-parallel` run. A new test helper, `TestProcess`, learns of the exit
  from `terminationHandler`: async callers wait through a continuation, sync helpers and `defer`
  cleanup on a timed signal. It collects output while the process runs and stops one that
  overstays with SIGTERM, then SIGKILL.
- **A stall fails the test and names the step.** `Server.exec` (30 seconds), the cancel tests'
  process-list checks (10 seconds), the session holders, and the plain-client control test throw
  a timeout such as `the mysql process-list check for p144_… did not finish within 10.0 seconds`.
  Waiting for a run's database session is bounded too. Tests only; the app is unchanged.

### 2026-10-04 — Development: fixture databases survive setup from another worktree ([#176](https://github.com/filipac/runlet/issues/176))

- `scripts/setup-fixtures.sh databases` keeps the throwaway TLS certificates in one folder that
  every worktree shares, `runlet-fixtures/tls` in Git's common directory (the main checkout's
  `.git`), and Compose mounts it through `RUNLET_FIXTURE_TLS`. Running the script from another
  worktree no longer recreates the shared MariaDB and PostgreSQL containers: their ports,
  sessions, and certificates stay, and `RUNLET_TEST_TLS` is the same everywhere. The first run
  takes over the worktree's `Tests/Fixtures/docker/tls` from before. To make new certificates,
  stop the databases, delete the folder, and run the script again. See
  [docs/validation.md](docs/validation.md).

### 2026-10-04 — Connection Manager ([#180](https://github.com/filipac/runlet/issues/180))

- **Everything Runlet has open, in one window.** **Window ▸ Connections** (⇧⌘C), Open Anything,
  or the new connection count in every window's status bar (its tooltip has the counts per kind;
  dimmed at zero) open the Connection Manager. It groups SSH profiles' shared connections, SSH
  tunnels of saved connections ([#143](https://github.com/filipac/runlet/issues/143)), database
  sessions of running SQL work (statements, Run All, Explain, Load Next, Load Schema, Show
  Definition, and the Database pane's Server reads and actions), PHP runs on every target, and
  AI clients connected over MCP. Each row says what it is, where it goes, which tab or feature
  uses it, since when, and whether it is production; an SSH connection says what uses it (runs,
  statements, tunnels), a statement shows its session id on the server.
- **Close per row.** An SSH connection disconnects as the profile's Disconnect does, and asks
  first when runs, statements, or tunnels use it or when its login used a password or 2FA. A
  tunnel is cancelled (`-O cancel`), asking first while a run holds it. A database session or
  PHP run stops as the tab's Stop does, with #144's server-side cancel. An AI client is
  disconnected while the MCP server keeps listening. Closing never asks the production question.
  The context menu also has Reveal Tab.
- **Observes, never polls.** The list is built from state Runlet already keeps and updates as
  things open and close; it never connects, reads, or runs anything. Database sessions exist
  only while a statement runs, and the window says so. No passwords, tokens, or DSNs with
  credentials appear in it.
- **For developers.** The model and close rules are in RunletCore (`ActiveConnections.swift`,
  with tests); SQL runs report their database session as a `sqlSession` event; debug steps and
  `scripts/connection-manager-screenshots.py` drive it end to end. See
  [docs/connections.md](docs/connections.md).

### 2026-10-04 — Saved connections through an SSH profile's tunnel ([#143](https://github.com/filipac/runlet/issues/143))

Part of the database roadmap ([#137](https://github.com/filipac/runlet/issues/137)).

- **Connect from: This Mac, through SSH profile.** A saved connection can reach a database
  only a server can (behind a bastion, a Docker service on the server) when that server's PHP
  can't open it. Runlet adds a local forward on the SSH profile's existing shared connection
  (`ssh -F /dev/null -S <control socket> -O forward -L 127.0.0.1:<free port>:<host>:<port>`) and
  opens the connection with this Mac's PHP against it, as connections from this Mac do. The
  host and port are as the server sees them. Works for MySQL/MariaDB, PostgreSQL, and SQL
  Server; statements, Run All, bound parameters, Explain, Load Next, Load Schema, completion,
  the schema explorer, Show Definition, and Stop's server cancel (its second runner goes
  through the same forward) all use it.
- **The forward exists only while needed.** It listens only on 127.0.0.1, on a port the kernel
  reports free (a port taken meanwhile is retried), and is reused while in use. Runlet cancels
  it (`-O cancel`) 5 minutes after its last use, when no SQL tab uses the connection, when the
  connection changes, before Disconnect, and on quit. Runs keep `ClearAllForwardings=yes`.
- **Never connected silently.** A tunnel whose SSH profile isn't connected asks first; agent and
  key profiles then connect as their runs would, password and 2FA profiles open Connect….
- **TLS.** PostgreSQL's verify-full still checks the server's name (Runlet passes `host` with
  `hostaddr=127.0.0.1`); MySQL and SQL Server check against 127.0.0.1, which the editor and the
  docs explain.
- **Same rules.** The password stays in the Keychain and reaches only the local PHP, on stdin,
  never `ssh`'s arguments. Production uses the stricter of the target's, the connection's, and
  the SSH profile's environment, and names the profile when it decides. The Run Log shows each
  run's forward and the cancel lines; a removed SSH profile leaves its connections marked
  "Missing profile", never switched to another one. Older `targets.json` files are unchanged.
- Docs: [SQL tabs](docs/sql-tabs.md#through-an-ssh-tunnel), [SSH targets](docs/ssh.md#sql-tunnels),
  architecture, compatibility, and the AI clients' security model.

### 2026-10-04 — The Database pane's Server section: version, sizes, and sessions ([#150](https://github.com/filipac/runlet/issues/150))

Part of the database roadmap ([#137](https://github.com/filipac/runlet/issues/137)).

- **A Server section** in the Library's Database pane (Tables | Server) shows the server of the
  tab's connection: its version, current database and user, uptime, connections, and TLS; the
  database's size and its 20 largest tables with data and index sizes and estimated rows; and
  its sessions, with user, host, database, state, time, open transaction, lock waits ("waits
  for #4711"), and statement. MySQL and MariaDB, PostgreSQL, and SQLite (no sessions); SQL
  Server and callable connections say they aren't supported.
- **Read on demand only**, in a fresh runner, through application connections, saved
  connections, and connections that open from this Mac. Only the catalog and the server's
  status are read, never rows. Production asks before every read. Each part fails on its own,
  and the section says what missing privileges hide (`PROCESS`, `pg_read_all_stats`) or forbid.
- **Cancel Query and Kill Session** on a session always ask, on every connection, naming the
  session, its user, when its statement started, the statement, and what Runlet sends
  (`KILL QUERY`/`KILL`, `pg_cancel_backend`/`pg_terminate_backend`). Runlet first checks that
  its connection reached the server the list came from (Stop's fingerprint, #144) and that the
  session is still the listed one, and never cancels or kills the panel's own session. The
  section shows what the server reported, and the tab's Run Log records the action. Read-only
  connections may cancel and kill: it changes no data.
- **Refresh** of the sessions every 5, 10, or 30 seconds is off by default, never offered on
  production, and turns itself off when the section hides, the tab or connection changes, or
  Runlet goes to the background.
- Docs: [SQL tabs ▸ Server details and sessions](docs/sql-tabs.md#server-details-and-sessions),
  its safety notes, and the architecture.

### 2026-10-04 — Run History and SQL snippets remember the connection ([#149](https://github.com/filipac/runlet/issues/149))

Part of the database roadmap ([#137](https://github.com/filipac/runlet/issues/137)).

- **Run History records the connection** an SQL run used: an application connection's name
  (or the default connection), or a saved connection's id and its name at the time. Never a
  password or any other part of its definition. Rows show it after the target ("orders ·
  Reporting"), the search matches it, and a **Connection** filter appears when the runs shown
  used more than one connection. The same statement on another connection is its own entry.
  History from before loads unchanged, without a connection.
- **Opening an entry** (Open, Open in New Tab, Load in Current Tab, Open Anything) puts the SQL
  tab on its connection, and **Save as Snippet** keeps it. A saved connection is found by id
  when it belongs to the tab's target or to all targets, else by name (the target's own first,
  then one of all targets); another target's own connection is never used. One that no longer
  exists leaves the tab on the default connection, with a note in the SQL bar: "The connection
  “Archive” from this entry no longer exists; using the default connection." Restoring never
  runs anything, and production marking follows the connection the tab ends up on.
- **SQL snippets can remember a connection**, by name only so they work on other targets and
  Macs: Save SQL Snippet keeps the tab's connection (a checkbox turns it off), Edit… changes
  or removes it, Duplicate and Copy to Personal keep it, and the Snippets panel shows it as a
  badge. Opening a snippet opens the tab on its connection, or on the default one with the same
  note.
- **Project SQL snippets** read and write `-- @connection reporting` (a saved connection with
  that name, else the application's connection) and `-- @connection Reporting (saved)` (only a
  saved connection). See [project snippets](docs/project-snippets.md#connections).
- MCP's `get_snippet` returns the name of an SQL snippet's connection as `connection`, nothing
  more.
- Docs: [SQL tabs ▸ Snippets and History](docs/sql-tabs.md#history), [project
  snippets](docs/project-snippets.md#connections), [personal snippets](docs/personal-snippets.md),
  [MCP](docs/mcp.md), [architecture](docs/architecture.md). Tests: `HistoryConnectionTests`.

### 2026-10-04 — Schema explorer: Show Definition for a table or view ([#148](https://github.com/filipac/runlet/issues/148))

Part of the database roadmap ([#137](https://github.com/filipac/runlet/issues/137)).

- **Show Definition** in the Library's Database pane (a table's or view's context menu, or its
  new document button) opens a resizable sheet titled with the object and its kind ("orders ·
  table") and the connection and database. It shows a spinner while it reads the definition, then
  the definition read-only and selectable, in the editor's font and SQL colours, under a comment
  header that says where it came from, how it was read, when, and that nothing ran. Errors and
  databases without definitions show in the sheet. **Copy** copies the whole text; **Open in SQL
  Tab** opens it in a new SQL tab ("orders (definition)") on the same target and connection, with
  the output pane hidden, and it doesn't run; **Done** (or Esc) closes it. The sheet is never
  saved and runs nothing. Production asks first, before anything is read, as Load Schema does
  ("Read a definition on production?"); read-only and saved connections work, since it's a
  catalog read, and a saved connection that opens from this Mac, or one of all targets, reads it
  on this Mac ([#142](https://github.com/filipac/runlet/issues/142)).
- **The runner reads one table's or view's definition (DDL)** from the catalog, in a fresh
  process, and reads nothing else: MySQL and MariaDB `SHOW CREATE TABLE` / `SHOW CREATE VIEW`
  plus the table's triggers; SQLite's own `CREATE` statement from `sqlite_master` plus its
  indexes and triggers; on PostgreSQL, which has no `SHOW CREATE`, a `CREATE TABLE` that Runlet
  rebuilds from `pg_catalog` (columns with types, defaults, identity, collation, NOT NULL;
  `pg_get_constraintdef()`, `pg_get_indexdef()`, triggers, comments, partitioning, and the enum
  types its columns use) and `pg_get_viewdef()` for views, marked as reconstructed. SQL Server and
  a project driver's `sqlSchema()` connection without a catalog say they can't show one.

### 2026-10-04 — SQL tabs: Stop cancels the running statement on the database server ([#144](https://github.com/filipac/runlet/issues/144))

Part of the database roadmap ([#137](https://github.com/filipac/runlet/issues/137)).

- **Stop ends the statement on the server too.** Before, Stop only ended the runner's PHP
  process: MySQL and MariaDB kept executing a long statement until they wrote to the closed
  connection, and PostgreSQL usually finished it, holding its locks. Now a run notes its
  connection's session id right after connecting, and Stop first starts a short second runner
  on the same target and connection that sends `KILL QUERY <id>` (MySQL, MariaDB),
  `SELECT pg_cancel_backend(<pid>)` (PostgreSQL), or `KILL <spid>` (SQL Server, untested live),
  then stops the runner as before. This covers Run, Run All, Load Next pages, and Explain
  Analyze, on application connections (the application boots again) and saved connections (no
  project code; the password from the Keychain, on stdin), locally, in Docker, over SSH, and for
  connections that open from this Mac (#142: the same local PHP in Runlet's empty folder).
- **Checks before it sends:** the second connection must reach the same database server (a
  fingerprint of host and port, or PostgreSQL's start time), and the session must belong to the
  same user and still run something. It never sends anything but the dialect's cancel statement.
- **The output says what happened:** "Cancelled the statement on the server (KILL QUERY 4711).",
  or why not (the statement had already finished, the user may not cancel the session, the
  server was still undoing the change 1.5 s later, the second runner couldn't connect). Every
  cancel is in the Run Log. Load Next's card adds it to "Stopped.".
- **No error card for your own Stop:** the database's answer to the cancel (MySQL/MariaDB 1317
  "Query execution was interrupted", PostgreSQL 57014 "canceling statement due to user
  request") shows as a grey "Interrupted by Stop." line, which for Run All also says which
  statement and what was rolled back. Plain output and the Run Log keep the database's words.
  Other errors, cancels that aren't Stop's, and failed cancels keep the red card.
- **Stop never asks,** on production either, and waits at most 8 seconds for the second runner.
  Read-only connections allow the cancel. Run All in a transaction is rolled back, and the
  output says so.
- SQLite and callable connections (`$wpdb`, Doctrine without PDO, a driver's callable) keep
  Stop as it was. Quitting Runlet stops every run at the same time, each with its server cancel.
- Tests: `SQLCancelTests`, `SQLCancelInterruptionTests`, `SQLCancelControlTests`, `SQLCancelExecutionTests` (SQLite, PHP 7.4, a hanging second runner,
  Docker, SSH), and `SQLCancelLiveTests` (MariaDB 11 and PostgreSQL 14: `SLEEP(30)` and
  `pg_sleep(30)` gone from the process list within seconds, saved and read-only connections,
  Run All rolled back, Load Next, Explain Analyze, the checks, and a refused cancel).

### 2026-10-04 — Saved connections: connect from this Mac, and connections for every target ([#142](https://github.com/filipac/runlet/issues/142))

Part of the database roadmap ([#137](https://github.com/filipac/runlet/issues/137)).

- **Connect from: This Mac.** A saved connection can open from this Mac instead of the target's
  PHP: for a port Docker Desktop, OrbStack, DBngin, or Herd publishes, a cloud database that
  allows your office, or a server or `php:*-cli` container without `pdo_mysql`/`pdo_pgsql`. It
  runs in Runlet's own PHP when installed (it has `pdo_mysql`, `pdo_pgsql`, and `pdo_sqlite`),
  else the default PHP from Settings, in an empty folder of Runlet's with no project code, so
  nothing is written to the project. Host names are resolved on this Mac (`localhost` is this
  Mac), and sockets, SQLite files, and TLS files are this Mac's paths, with **Choose…** and `~/…`.
- **All targets.** A saved connection can belong to all targets. Every SQL tab's picker lists it
  under *Saved connections (all targets)*, the Laravel sandbox's too, and it always opens from
  this Mac. **Settings ▸ Databases** manages these and lists every target's connections; Edit
  Connections… in the SQL bar shows both. A schema read once serves every target's tabs.
- **Says where.** The run header, Run History, the SQL bar, and production confirmations say
  "this Mac (Runlet's PHP 8.5.8)". Test Connection reports the PHP that opened the connection
  and its PDO drivers. A missing PHP or driver says what this Mac's PHP has and points to
  Runlet's PHP; the editor offers **Download Runlet's PHP…** after a failed test.
- **The same rules.** Production marking (the stricter of the connection's and the tab's
  target's), read-only, init statements, bound parameters, Run All, Explain, Load Next, Load
  Schema, completion, and the schema explorer work on these connections. The password still
  lives only in the Keychain and reaches PHP only on standard input; Runlet refuses to send a
  connection that opens from this Mac to a container, a server, or the project's directory.
- Saved data: `targets.json` gains `connectFrom` and `allTargets` only on connections that use
  them. Workspaces keep names only; a name finds the target's own connection first, then one of
  all targets.

### 2026-10-04 — SQL tabs: Load Next loads more rows past the 1,000-row cap ([#146](https://github.com/filipac/runlet/issues/146))

Part of the database roadmap ([#137](https://github.com/filipac/runlet/issues/137)).

- **Load Next 1,000** under a result the row cap (or the 8 MiB bound) cut runs the statement
  again for the following rows and adds them to the same table, so the card's filter, sort, and
  CSV cover every loaded row. The card counts the pages ("First 2,000 rows in 2 pages") and says
  when the result ends. A page shows its progress and can be stopped; nothing is added then.
- **Only plain reads page:** `SELECT`, `WITH`, `TABLE`, and `VALUES` statements that lock no
  rows. Writes (`UPDATE … RETURNING`), locking reads (`FOR SHARE`, `LOCK IN SHARE MODE`),
  statements Runlet can't classify, and one statement of a Run All script never run again; the
  card says why.
- **How a page skips rows:** Runlet adds `LIMIT … OFFSET …` to the end of the statement (SQLite,
  MySQL, MariaDB, PostgreSQL) or `OFFSET … FETCH` after SQL Server's `ORDER BY`, without
  wrapping it in a subquery (MariaDB drops a subquery's `ORDER BY`). A statement with its own
  `LIMIT`, and connections whose dialect Runlet doesn't know, run as written while the runner
  skips the rows already shown. The card notes that rows can shift between pages when the data
  changes, and that `ORDER BY` gives stable pages.
- **Like a run:** a page uses the same target, connection, and bound values; production asks
  again ("Load the next page on production?"); read-only connections stay read-only; Run History
  keeps each page as its own entry (`-- Load Next: rows 1,001–2,000`).
- **Result windows** show the pages loaded later, have Load Next too, and now search, filter,
  and sort off the main thread, so typing stays quick with 50,000 rows.
- **Settings ▸ General ▸ SQL Results ▸ Rows per page** (1,000 by default, up to 10,000) sets the
  first run's cap and each page. A card keeps at most 50,000 rows (fewer of a wide result).

### 2026-10-04 — SQL tabs: a parameters drawer under the editor, with values set before running ([#168](https://github.com/filipac/runlet/issues/168))

Follow-up to bound parameters ([#145](https://github.com/filipac/runlet/issues/145)), part of the
database roadmap ([#137](https://github.com/filipac/runlet/issues/137)).

- **A parameters drawer** under an SQL tab's editor lists the placeholders of the statement Run
  would send (the selection, or the statement at the caret): each `:name` once and each `?` in
  order, with its line, type, and value. It follows the text and the caret a moment after you
  stop typing, hides when there are no placeholders, and collapses to one line ("2 parameters:
  :min_rent = 1000, :skip = 'Linus'").
- **Values are set before running** and stay with the tab for the session, also when their
  placeholder goes away and comes back; a `?` keeps its value while you edit its statement, and
  a renamed `:name` keeps its own. `-- @param` comments preset the rows (marked **@param**) and
  follow the comment until you set a value.
- **Run, Run All, and Explain use the drawer's values** without a sheet. A missing or invalid
  value stops the run before anything runs: the drawer opens on it, focuses its field, and says
  why. The drawer's **Statement | All Statements** switch shows the values Run All needs; Run All
  switches to it when one is missing. The values sheet is gone.
- **Keyboard:** Tab and ⇧Tab move between fields, ↩ (or ⌘R) runs, Esc returns to the editor.
- **Write as @param Comments** puts the drawer's values in the tab as `-- @param` lines (one
  edit, which Undo takes back), rewriting a placeholder's existing line.
- Safety is unchanged: values are bound, never written into the SQL; production confirmations
  list them; read-only connections refuse writes; Run History keeps them as `-- @param` lines.
- Placeholders after a `#` count on SQL Server (`#temp` tables) and custom DSN connections
  ([#140](https://github.com/filipac/runlet/issues/140)).
- Splitting a large SQL tab into statements is linear now: a tab of 4,000 statements took over
  a second per Run, and now takes milliseconds.

### 2026-10-04 — The inspector's Explain shows the plan tree ([#170](https://github.com/filipac/runlet/issues/170))

Follow-up of Explain Statement ([#147](https://github.com/filipac/runlet/issues/147)), part of the
database roadmap ([#137](https://github.com/filipac/runlet/issues/137)).

- **The Explain tab** that the run inspector's Queries section opens
  ([#4](https://github.com/filipac/runlet/issues/4)) now shows its plan with Explain Statement's
  **plan card** after Run: the steps as a collapsible tree, full scans highlighted and counted,
  Raw for the database's own output, and the database, version, and connection under it.
- The generated code asks for `EXPLAIN FORMAT=JSON` on MySQL and MariaDB and
  `EXPLAIN (FORMAT JSON)` on PostgreSQL (SQLite keeps `EXPLAIN QUERY PLAN`), through the same
  database layer, connection, and bindings as before (Laravel, Eloquent, Doctrine DBAL, `$wpdb`,
  PDO). It still never adds `ANALYZE`, and opening the tab still never runs it.
- **`Runlet\explainPlan($rows, $connection)`**, a new runner function, shows EXPLAIN rows as the
  plan card from any PHP tab. It tells MariaDB from MySQL by the connection's server version and
  sends nothing to the database; rows it can't read (MySQL's tabular EXPLAIN, PostgreSQL's text
  plan) are returned as they are. Captures without a recorded driver keep a plain `EXPLAIN` and
  show its rows.

### 2026-10-04 — Explain Statement with a plan view in SQL tabs ([#147](https://github.com/filipac/runlet/issues/147))

Phase 9 of the database roadmap ([#137](https://github.com/filipac/runlet/issues/137)).

- **Explain Statement** (Run ▸ Explain Statement, ⌥⌘E, the SQL bar's **Explain** button, or the
  command palette) shows the database's plan for the selected statement, or the one at the
  caret, on the tab's connection, application or saved. **The statement doesn't run**: Runlet
  sends `EXPLAIN FORMAT=JSON` (MySQL, MariaDB), `EXPLAIN (FORMAT JSON)` (PostgreSQL), or
  `EXPLAIN QUERY PLAN` (SQLite) in front of it, prepared natively so a second statement is
  refused rather than run.
- **A plan tree** in the output: each step indented under the one that uses it, with its
  operation, table, index, the database's estimated rows and cost, and its conditions;
  collapsible steps. **Full scans are highlighted** (MySQL's `access_type: ALL`, PostgreSQL's
  Seq Scan, SQLite's `SCAN` without an index) and counted. **Raw** shows the database's own
  output. Copy gives the tree as indented text.
- **Explain Analyze** (Run ▸ Explain Analyze…, or the Explain button's menu) runs the statement
  and adds the rows and time of each step. A statement that can change data asks first
  ("EXPLAIN ANALYZE runs the DELETE"). PostgreSQL runs it in a transaction that Runlet rolls
  back. MySQL and MariaDB refuse writes under Explain Analyze (they commit DDL at once and can't
  roll back non-transactional tables), as do read-only connections; SQLite has no EXPLAIN
  ANALYZE. Production asks before every Explain, with the `EXPLAIN ANALYZE … DELETE` warning
  for a write.
- **Placeholders** use the values sheet and binding of bound parameters
  ([#145](https://github.com/filipac/runlet/issues/145)).
- SQL Server and connections whose database Runlet doesn't know (a driver's callable) say so
  and run nothing. The run inspector's Explain ([#4](https://github.com/filipac/runlet/issues/4))
  shows the same plan tree since [#170](https://github.com/filipac/runlet/issues/170).

### 2026-10-04 — Saved connections: TLS, socket, charset, init statements, SQL Server, custom DSNs ([#140](https://github.com/filipac/runlet/issues/140))

- **Advanced options in the connection editor.** A saved connection can connect through a Unix
  socket (MySQL's socket file, PostgreSQL's socket directory), set its charset (MySQL `charset`,
  PostgreSQL `client_encoding`), use TLS, run init statements, and add DSN options (libpq
  keywords for PostgreSQL, DSN keywords for SQL Server). They sit in an **Advanced** section that
  opens by itself when a connection uses them, with a one-line summary.
- **TLS per driver.** PostgreSQL has libpq's five modes with a CA, client certificate, and key.
  MySQL and MariaDB have Off, Require (encrypted, not verified), and Verify CA and host name,
  with the same files: mysqlnd can't prefer TLS or check the CA without the host name, and the
  editor says so. With Require or Verify on MySQL, Runlet checks the session is encrypted before
  anything runs. SQL Server has Off, Require, and Verify (`Encrypt`, `TrustServerCertificate`).
  The files are paths where the target's PHP runs; Runlet never reads them, and checks only that
  they exist. Encrypted client keys aren't supported (their passphrase would leave the Keychain).
- **Test Connection says whether the connection is encrypted** ("· TLSv1.3", with the cipher
  below), and how many init statements ran.
- **Init statements** (`SET search_path TO reporting, public`, `SET time_zone = '+00:00'`) run
  after connecting, before every statement, Run All, Load Schema, and Test Connection. They can't
  begin or end a transaction. On a read-only connection they run in the read-only session, so the
  database refuses writes in them, and Runlet checks the session is still read-only afterwards;
  Runlet also refuses, in the editor and again in the runner, anything the read-only rules refuse
  except session settings that keep it read-only (no `SET GLOBAL`, `SET PERSIST`, `SET PASSWORD`).
  Production confirmations list them.
- **SQL Server** saved connections, through Microsoft's `pdo_sqlsrv` (or `pdo_dblib`) in the
  target's PHP; Test Connection names a missing extension or ODBC driver. Not yet verified against
  a live SQL Server ([#53](https://github.com/filipac/runlet/issues/53)).
- **Custom PDO DSN** connections for drivers Runlet doesn't model (`oci:`, `odbc:`, `firebird:`),
  with the password still in the Keychain.
- **No option can carry a password.** DSN options that look like one (`password`, `PWD`,
  `sslpassword`, `passfile`, …) and custom DSNs with `password=`, `pwd=`, or `user:secret@` are
  refused ("put it in the Password field"), in the editor and again in the runner. Read-only is
  unavailable for SQL Server and custom DSNs, which have no read-only session Runlet can enforce.
- Saved data: `targets.json` gains `socket`, `charset`, `tls`, `initStatements`, `options`, and
  `dsn` on a connection only when set; earlier files load unchanged.
- Fixtures: `scripts/setup-fixtures.sh databases` gives the MariaDB and PostgreSQL fixtures
  throwaway TLS certificates (in the gitignored `Tests/Fixtures/docker/tls`) and prints
  `RUNLET_TEST_TLS`; plain connections keep working. New tests: `ConnectionOptionsTests`,
  `SQLConnectionOptionsTests`, and the live `SQLLiveTLSTests`.

### 2026-10-04 — Bound parameters in SQL tabs ([#145](https://github.com/filipac/runlet/issues/145))

Phase 7 of the database roadmap ([#137](https://github.com/filipac/runlet/issues/137)).

- **Statements with `:name` or `?` placeholders run with values you give them.** Run and Run
  All first show a sheet with a row per placeholder (each `:name` once, each `?` in order), a
  type (text, integer, decimal, boolean, or NULL), and a value. ↩ runs, Esc runs nothing; a
  value that doesn't fit its type keeps Run disabled. Statements without placeholders run
  without the sheet, as before.
- **Bound, never written into the SQL.** The values go with the statement in the run's request
  on standard input, and the runner binds each with `PDOStatement::bindValue` and its PDO type
  after preparing the statement natively. Decimals are sent as text so a `DECIMAL` column keeps
  every digit.
- **Placeholders are read like statements are split:** nothing in strings, comments, quoted
  names, or dollar-quoted bodies counts; `::` casts, `:=`, and PDO's `??` escape (PostgreSQL's
  JSON operators) aren't placeholders. Mixing `:name` and `?` in one statement, numbered `$1`
  placeholders, and names PDO reads differently are refused before anything runs.
- **Run All** asks once: a name used by several statements gets one value; each statement's `?`s
  are its own.
- **Prefilled.** Each tab remembers its last values for this session (in memory only, never
  saved), and `-- @param :name <type> [value]` comments preset the sheet.
- **Where binding isn't possible, nothing runs:** callable connections (WordPress's `$wpdb`,
  Doctrine without a PDO, a driver's callable) refuse statements with placeholders, and MySQL
  and MariaDB refuse a name used twice in one statement, each with a message saying what to do.
- **Safety.** Production confirmations list the values next to the statement; write detection
  and read-only refusals still read the statement text; the output's first line names the
  values; Run History keeps them as `-- @param` lines before the statement, so running the entry
  again asks with the same values.
- Debug builds: the steps `sql-param`, `sql-params`, and `sql-history`, and
  `scripts/sql-parameter-screenshots.py`.

### 2026-10-03 — SQL tabs stay responsive; fast result tables ([#162](https://github.com/filipac/runlet/issues/162))

- **Large results no longer freeze Runlet.** An SQL result (and a PHP value's Table view) was
  drawn as a SwiftUI view per cell, all at once: 0.9 s of a blocked main thread for 333 rows,
  1.3 s for 1,000 rows, and about 10 s for 1,000 rows of 31 columns, while nothing else in the
  app responded. Output tables now use a native grid that makes views only for the rows on
  screen (the result window's, which they now share): the longest stall when a 1,000-row result
  arrives is about 60–100 ms, close to a one-row result's, and scrolling it takes 2.6 ms a step
  instead of 22 ms (5.5 ms instead of 73 ms for the wide one).
- **The grid** grows with its rows up to 400 points, then scrolls inside; a vertical scroll it
  can't take (its rows fit, or it is at its top or bottom) scrolls the output. It keeps the
  filter, header sorting, ⌘C, Copy CSV, Export CSV, and Open in Window, which now opens with the
  card's filter and sort; Copy CSV and Export CSV write the rows shown. The context menu copies a
  value, rows, or a row as CSV, JSON, or a PHP array.
- **Built once.** A result's table is built where its event is decoded, off the main thread, not
  on every redraw; filtering and sorting run on another thread when they change, and the card's
  copy text is made only on Copy.
- **A running state for SQL tabs.** While a statement or Run All runs, the output says where and
  for how long ("Running on the default connection… 1.2 s") with a Stop button, and the SQL bar
  shows a spinner. PHP tabs are unchanged.
- Debug builds: `RUNLET_DEBUG_TIMING` adds `lag` and `lagMax` (how long the main queue kept a
  ping waiting, as it would a click), and the steps `scroll-check`, `table-filter`, `table-sort`,
  and `table-state` measure and drive output tables.

### 2026-10-03 — Read-only saved connections, and their own environment ([#139](https://github.com/filipac/runlet/issues/139))

Phase 2 of the database roadmap ([#137](https://github.com/filipac/runlet/issues/137)).

- **Read-only saved connections, enforced by the database.** A saved connection's editor has a
  **Read-only** switch. Right after connecting, before any statement of yours, the runner makes
  the session read-only and checks that the database took it: `SET SESSION TRANSACTION READ ONLY`
  on MySQL 5.6.5+ and MariaDB 10.0+, `SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY` on
  PostgreSQL, and on SQLite the file is opened read-only (`SQLITE_OPEN_READONLY`, PHP 7.3+) with
  `PRAGMA query_only = ON`. Run All sends the setting again before each statement. A database
  that doesn't take it stops the run before anything else runs.
- **Runlet refuses before sending** what would write or switch the session back: `SET … TRANSACTION
  READ WRITE`, `SET transaction_read_only`/`tx_read_only`, `SET default_transaction_read_only`,
  `SET SESSION CHARACTERISTICS`, `BEGIN`/`START TRANSACTION … READ WRITE`, `RESET ALL`, `DISCARD
  ALL`, `PRAGMA query_only`, `set_config()`, and every statement that write detection marks as
  writing or can't classify. Reads and plain `BEGIN`/`COMMIT`/`ROLLBACK` run. The statement is
  checked as the connection's database reads it (MySQL's backslash escapes and `/*! … */`
  comments, PostgreSQL's `#` operator and `E'…'` strings). The alert says why and suggests a
  connection without Read-only; Run All runs none of a script with a refused statement. The
  runner checks again with the same rules before it connects.
- **Seen everywhere:** a READ-ONLY badge with a lock in the SQL bar, its list, and the Databases
  lists; "in a read-only session" in the output's first line, each result's source, and Test
  Connection's report.
- **Environment and colour per saved connection.** Development, staging, or production, and a
  colour, like targets. A run uses the stricter of the target's and the connection's marking, so
  a production connection on a development target asks before every statement, Run All, and Load
  Schema; the sheet says the connection is marked as production. The SQL bar shows the
  connection's colour and badge, Run History marks its runs, and a statement on it never reads
  the schema by itself. Test Connection still doesn't ask (it runs only Runlet's own queries).
- **Write detection:** `PRAGMA name(value)` now counts as a write, except the pragmas that read
  about a table or index (`table_info(…)`, `index_list(…)`, …).
- **Saved data:** `readOnly`, `environment`, and `color` are written only when set; connections
  saved before load as read-write development connections without a colour.
- **Limits, documented:** functions with side effects in a `SELECT` (MySQL), shared locks, drivers
  without a guard, and connection poolers in transaction mode. For a guarantee, use a database
  user that can only read.
- Tests: `ReadOnlyConnectionTests` (RunletCore), `SQLReadOnlyConnectionTests` (host PHP 8.4 and
  7.4, SQLite, including an `INSERT` sent past both checks and the runner's rules matching the
  app's), and `SQLLiveDatabaseTests.readOnlySavedConnections` (MariaDB 11, PostgreSQL 14). Docs:
  sql-tabs.md (Read-only connections, Environment and colour), architecture.md, compatibility.md.

### 2026-10-03 — Saved database connections, with passwords in the Keychain ([#138](https://github.com/filipac/runlet/issues/138))

Phase 1 of the database roadmap ([#137](https://github.com/filipac/runlet/issues/137)). It revises
the credentials principle: "Runlet never asks for or stores database credentials" becomes
"Runlet uses your application's own database connection and needs no credentials for it. You can
also save a connection yourself; that is opt-in, and its password is stored only in the macOS
Keychain." Detected connections work as before. The entries below this one are kept as written.

- **Saved connections per target.** Local projects, Docker profiles, and SSH profiles get a
  **Databases** list (in the project's options and the profile forms) and the SQL bar's list gets
  **New Connection…** and **Edit Connections…**. A connection has a name, a driver (MySQL/MariaDB,
  PostgreSQL, or an SQLite file), host and port, database (or the SQLite file on the target), user,
  an optional password, and a connect timeout. Hosts and database names are checked so they can't
  add options to the connection string. The Laravel sandbox has none yet (#142).
- **The SQL bar's list** has two parts: *Application connections* (the default, the names the
  driver reported, Other Connection…) and *Saved connections*. Choosing one runs nothing.
- **Test Connection** opens the connection in the target's PHP and reports the server's version,
  the database, the user, and the round trip, or the error. A missing PDO driver is named with
  the drivers the target's PHP has. It runs none of your SQL and no application code, so it
  doesn't ask on production.
- **Where it connects:** in the target's own PHP, like a statement today (this Mac, the container,
  or the server), so Compose service names and server-local databases work. A saved connection's
  run boots no project code (the `plain` bootstrap) and teaches Runlet nothing about the target.
- **SQL tabs, Run All, Load Schema, completion, and the schema explorer** work on saved
  connections; schemas are kept per connection (`app:<name>` / `saved:<id>`), and editing or
  deleting a connection forgets its schema. **Open as PHP (Query Builder)** is hidden for them:
  Runlet never generates PHP that contains a password. Results say `via saved connection
  "Reporting" (pgsql, db.internal:5432/reports)`.
- **The password** is a generic password in the login keychain (not synchronizable, service
  `dev.runlet.Runlet.database`, account = the connection's id). It is read when a run starts,
  after any production confirmation, and sent only inside the runner's request on stdin (a local
  pipe, `docker exec -i`, or `ssh -T`), never as an argument, environment variable, or file. It is
  never in `targets.json`, sessions, workspaces (which keep the connection's name only), Run
  History, the Run Log, output, notices, errors, or AI clients' results. The runner opens the
  connection without the password in any stack frame, rethrows PDO's errors with their message
  only, forgets the password once connected, and replaces it with `•••` in what it reports.
- **Lifecycle.** Deleting a connection deletes its Keychain item; removing a target says how many
  connections go with it and deletes their items. Duplicating a connection or a profile copies
  definitions without passwords. Cancelling the editor keeps nothing.
- **Production:** a saved connection follows its target. On a production target, its statements,
  Run All, and Load Schema ask, and the sheet names the saved connection and where it connects.
- **Ad-hoc signing:** after an update macOS may ask once whether Runlet may use a saved password
  (choose Always Allow); Deny stops that run before PHP starts. Developer ID signing (#24) ends
  this. Development runs with a scratch `RUNLET_DATA_DIR` use their own Keychain service, and
  Debug builds keep passwords in memory (`RUNLET_CREDENTIALS=memory`).
- **The "No SQL connection" message** now suggests saving a connection for the target, next to a
  project driver's `sqlConnection()`.
- Tests: `SavedConnectionTests`, `SQLSavedConnectionTests` (host PHP 8.4 and 7.4, Docker, SSH with
  Keep compiled PHP), and `SQLLiveDatabaseTests.savedConnections` (MariaDB 11, PostgreSQL 14);
  every event of successful and failed runs is scanned for the password. Docs: sql-tabs.md
  (Saved connections), drivers.md, architecture.md, compatibility.md, mcp.md, ssh.md.

### 2026-10-03 — Promote a snippet ([#39](https://github.com/filipac/runlet/issues/39))

- **File ▸ Save as Artisan Command…** and **File ▸ Save as Test…** turn the current tab's code
  (or its selection) into a file in the tab's project, for you to review and commit. Both are in
  the Command Palette, and in the Snippets panel's context menu for personal and project snippets.
  - A command is a `make:command`-style class in `app/Console/Commands` (`app/Commands` on Laravel
    Zero), with an `app:<name>` signature and the snippet in `handle()`.
  - A test is a Pest test when the project uses Pest, else a PHPUnit class extending the project's
    `Tests\TestCase`, in `tests/Feature`.
- The file is written only through a save panel that starts in the project's folder with the name
  filled in, asks before replacing a file, and refuses names that can't hold the class. The
  namespace follows the chosen folder through `composer.json`'s PSR-4 map. A sheet afterwards
  offers the external editor or Finder. Nothing runs: no Artisan, no tests, no PHP.
- The snippet's code is rearranged, not rewritten:
  - `use` imports (with the tab's own for a selection), `declare(strict_types)`, and top-level
    functions, classes, enums, and constants move out of the method; `namespace` is dropped.
  - Magic comments are removed; other comments stay.
  - The result is `dump()`ed by a command and assigned to `$result` in a test, with a TODO to
    assert it.
  - `@input`s become arguments, options, and flags with typed casts in a command, and their
    defaults in a test.
  - Lines inside strings, heredocs, and inline HTML keep their exact text when the code is
    re-indented.
- The commands are disabled with a reason for SQL tabs, the sandbox, and Docker or SSH profiles
  without a local folder; Save as Artisan Command… also outside Laravel, Lumen, and Laravel Zero.
- Guide: [promote a snippet](docs/promote-snippets.md).

### 2026-10-03 — DMG: Applications shortcut ([#158](https://github.com/filipac/runlet/issues/158))

- The DMG now shows an **Applications** shortcut next to Runlet.app, so you install by dragging
  one onto the other. `scripts/package.sh` copies the app into the DMG with `ditto` (keeping
  its signature), then mounts the finished DMG to check the shortcut and the app's signature,
  and fails if either is wrong. The zip is unchanged.

### 2026-10-03 — Format Code ([#36](https://github.com/filipac/runlet/issues/36))

- **Edit ▸ Format Code** (⌥⇧⌘F, also in the command palette) formats the current PHP tab with
  [Mago](https://github.com/carthage-software/mago)'s formatter, now bundled with Runlet. It needs
  no PHP, never runs the code, and never connects to the target.
  - It formats the whole tab as one undo step and replaces only the changed part, so the caret
    stays on the same code and the view doesn't jump.
  - Snippets without `<?php` and a last expression without a semicolon stay that way.
  - Magic comments stay after the same code. When formatting would change what one shows
    (Mago drops "redundant" parentheses, so `$a + ($b /*?*/)` would show `$a + $b`), the code is
    left as it is and the tab says which comment.
  - A syntax error leaves the code unchanged and shows the formatter's message above the editor
    until the next edit or Dismiss.
  - SQL tabs aren't formatted; the command is disabled there with the reason.
  - Formatting never starts the sandbox's automatic run.
- **Settings ▸ Editor ▸ Formatting**: the style (PER Coding Style, PSR-12, or Laravel (Pint)) and
  the quotes (single or double). Indentation follows the editor's tab width and spaces setting;
  the target's PHP version, when known, decides where trailing commas go (PHP 7.4 when unknown).
- **Format before run** (same section, off by default): Run and Profile Run format a PHP tab
  first, then run the formatted code. Never Run Selection, the sandbox's automatic runs, SQL tabs,
  or code being opened, imported, or restored. Code that can't be formatted runs as written.
- Mago 1.51.2 (MIT OR Apache-2.0) is pinned in `scripts/fetch-mago.sh`, which checks the SHA-256 of
  both release tarballs and builds a universal binary at `Resources/Formatter/mago` (not in git).
  The build embeds and signs it as `Contents/Helpers/mago` with its MIT notice
  (`Contents/Resources/Licenses/Mago-LICENSE.txt`); `scripts/package.sh` checks both architectures,
  the version, and the notice; the packaged self-test formats a snippet with it. The app grows by
  about 54 MB.
- Runlet runs the binary itself instead of asking PHPantom (`textDocument/formatting`): Runlet's
  PHPantom configuration turns its formatters off, and PHPantom would otherwise pick a project's
  Pint or PHP-CS-Fixer, which need PHP. A project's own `mago.toml` or Pint config isn't used.
- Guide: [docs/format-code.md](docs/format-code.md).


### 2026-10-03 — Notifications for long runs ([#26](https://github.com/filipac/runlet/issues/26))

- A run that took at least 10 seconds and ends while Runlet isn't the active app, or while the
  tab's window is minimized, posts a macOS notification.
  - It covers Run, Run Selection, Profile Run, an SQL tab's Run and Run All Statements, and runs an
    AI client asked for over MCP. So does a run that couldn't start after a long wait (an SSH
    connection that timed out, for example).
  - Stopped runs and sandbox auto-runs never notify. App Info, schema loads, command lists, and
    terminal commands aren't runs and don't either.
  - The time counts from pressing Run (or confirming or approving it) until the run ends, including
    connecting to the target.
- The notification says only how the run ended (completed, failed, ended unexpectedly, or couldn't
  start), how long it took, the tab's title, and the target's name: never code, output, error
  messages, SQL, or values. A tab's newer notification replaces its older one.
- Clicking it brings Runlet forward with the window and tab that ran, un-minimizing the window. If
  the tab was closed, Runlet only comes forward.
- **Settings ▸ General ▸ Notifications**: **Notify when a long run finishes in the background** (on
  by default) and **Notify after** (10 seconds, 30 seconds, 1 minute, or 5 minutes). Settings files
  from earlier versions load with these defaults.
- macOS asks for permission the first time there is a notification to show, or when you turn the
  switch on. When notifications are off for Runlet, Settings says so, and **Open Notification
  Settings…** opens System Settings ▸ Notifications (it changes nothing there).
- Debug builds started by the step and screenshot scripts print the notification they would post
  (`RUNLET_DEBUG_NOTIFICATION:`) instead of posting it, and never ask macOS for permission. New
  Debug steps: `notifications:<state>`, `notification-click`, and `notification-state`.
- Guide: [docs/run-notifications.md](docs/run-notifications.md).

### 2026-10-03 — Switch appearance from Open Anything ([#135](https://github.com/filipac/runlet/issues/135))

- Three commands switch the app's appearance: **Appearance: Auto (System)**, **Appearance:
  Light**, and **Appearance: Dark**. They are also in **View ▸ Appearance**, and have no default
  shortcut (Settings ▸ Shortcuts can give them one).
- Open Anything (⌘P) finds them by `appearance`, `theme`, `dark`, `light`, `auto`, `system`, and
  `mode`, with `>` like every command and also in its plain results. Type `dark` and press Return
  to switch. Other searches list targets, snippets, and files as before.
- Choosing one works like the picker in Settings ▸ General ▸ Appearance: it applies at once, is
  saved, and Settings shows it. Nothing runs and no tab reloads.
- The setting now also sets the whole app's appearance, so the palette, the completion list, and
  the hover and signature popups follow it too. Before, they followed the Mac. Dark on a light Mac
  gives dark popups, and Auto follows the Mac again.
- In the palette, a checked command shows a checkmark. The current appearance says "Current"; on/off
  commands still say "On".
- Debug builds: the `palette-return` step chooses the palette's selected row, and
  `appearance-state` prints the setting, the saved value, and each window's appearance.

### 2026-10-03 — SQL schema explorer and result window ([#21](https://github.com/filipac/runlet/issues/21))

- **Library ▸ Database** (⇧⌘B) shows the current tab's database: an SQL tab's connection, or the
  default one for PHP tabs.
  - Tables and views, with row estimates on MySQL, MariaDB, and PostgreSQL.
  - Each table expands to its columns (type, primary key, foreign key target, NOT NULL, default)
    and its indexes.
  - A filter finds tables by name, or by a column's name.
- Its actions never run anything:
  - **Open in SQL Tab** (double-click) writes `SELECT * FROM <table> LIMIT 50` in a new SQL tab
    named after the table.
  - **Open as PHP** on Laravel writes `DB::table('<table>')->limit(50)->get();`.
  - **Insert Name** and **Copy Name** use the same quoting as completion.
- It shows the schema completion uses, so loading stays explicit. Use Load Schema in the pane (on
  production it asks first) or run a statement on a non-production connection. Reload and Forget
  are in the pane.
- The schema now carries details:
  - nullability, defaults, and primary keys with the columns;
  - views and row estimates;
  - indexes and foreign keys, read from MySQL/MariaDB's `information_schema`, PostgreSQL's
    `pg_index`/`pg_constraint`, or SQLite's `pragma_index_list`/`pragma_foreign_key_list`.

  When indexes or foreign keys can't be read, tables and columns still load, with a note. A
  driver's `sqlSchema()` can return the same details in a per-table form; the plain form still
  works.
- **Open in Window** on any result table (SQL rows, or a PHP collection in the Table view) opens a
  large, resizable **result window**. It shows the result the run already produced and runs
  nothing; closing it drops the rows.
  - Search across columns, and filter rules per column (contains, =, ≠, <, ≤, >, ≥, empty/NULL)
    that compare numbers as numbers and dates as text.
  - Sort by a header, with NULLs last. Columns can be resized, reordered, and hidden.
  - ⌘C copies the selected rows; the context menu copies a value or row, or filters by a value.
  - Copy CSV and Export CSV write the rows and columns shown.
- The Library's pane picker shows icons when the library is too narrow for four names.
- **Fixtures.** `scripts/setup-fixtures.sh databases` starts throwaway MariaDB 11 and PostgreSQL 14
  containers. Live tests now cover the schema details, Run All's transactions (MariaDB's implicit
  commits, PostgreSQL's DDL rollback), and statements; until now these databases were checked only
  against their documentation.
- Runner: `SqlSchema.php`. Debug builds add the `schema-expand:`, `schema-search:`,
  `schema-open:`, and `result-window`/`result-filter:`/`result-sort:`/`result-search:`/
  `result-hide:`/`result-state` steps.

## 0.3.0 — 2026-10-03

SQL tabs: run SQL through the application's own database connection, with no credentials. They
have completion from the connection's schema, Run All Statements in a transaction, and SQL
snippets. Production targets ask before every SQL run.

Also new:
- App Info for a target (the framework's details, like `php artisan about`).
- Parameterised snippets that ask for their inputs.
- A Tests group in the Commands pane.
- A production guard that notices when the application says it runs in production, and History
  that keeps how each run's target was marked.
- Settings (off by default) to hide the output pane until a run and to hide it with Escape.
- Browse… for directories in Docker containers.

Editor fixes (scrolling, line numbers, sticky highlights, fonts), Laravel completion fixes, and
install steps that call `/usr/bin/xattr` by its full path. Ad-hoc signed, universal arm64 + x86_64.

### 2026-10-03 — SQL tabs: completion ([#128](https://github.com/filipac/runlet/issues/128))

- SQL tabs complete as you type (two letters, or `.` after a table or alias) and on Show
  Completions: keywords, phrases (`ORDER BY`, `LEFT JOIN`, `IS NOT NULL`, …), and common functions
  (`COUNT()` with the caret inside) always, with no connection; keywords follow the case you type.
- With the connection's schema: tables after `FROM`, `JOIN`, `UPDATE`, `INTO`, and `TABLE`; the
  columns of the statement's tables first, with their table and type; `alias.` and `table.` list
  that table's columns, `schema.` a PostgreSQL schema's tables. Names that need quotes are
  inserted quoted (backticks on MySQL). Nothing is offered inside strings, comments, or quoted
  names.
- The SQL bar's schema menu ("3 tables", "No schema") has Load Schema, Reload Schema, and Forget
  Schema (also Load SQL Schema in the palette). Load Schema reads the schema in a fresh runner,
  apart from the tab's output, and production targets confirm it every time. The first successful
  Run or Run All on a connection also reads it, after the statements, except on production.
- Only table and column names and types are read: `information_schema` on MySQL, MariaDB,
  PostgreSQL, and SQL Server, `sqlite_master` on SQLite; a callable connection tries each in turn.
  Drivers can return the schema themselves with the new optional `sqlSchema(?string $connection)`.
  At most 2,000 tables and 50,000 columns; kept in memory per target and connection until Forget
  Schema, a target edit, or quitting, never saved. A schema that can't be read never fails a run.
- Runner: `SqlTab::schema()`, a `schema` flag on `run()` and `runAll()`, and an `sqlSchema` event.
  Debug builds add the `sql-schema:load|forget|state` step.

### 2026-10-03 — SQL tabs: Run All Statements ([#129](https://github.com/filipac/runlet/issues/129))

- **Run ▸ Run All Statements** (⌥⇧⌘R), the SQL bar's **Run All**, or the palette runs every
  statement of the selection (or the tab) in order, on one connection, in one PHP process. Each
  statement gets its own result card ("Statement 2 of 5", its line and text). Runlet stops at the
  first error and says which statement failed, what was rolled back, and what didn't run.
- **In a Transaction** (the SQL bar's checkbox, on by default, saved with the tab): committed after
  the last statement, rolled back when one fails. PDO connections use PDO's transactions;
  callables get `BEGIN`, `COMMIT`, and `ROLLBACK`. MySQL and MariaDB commit DDL and some other
  statements at once: the output says so before running, and Runlet opens a new transaction after
  each, so a failure rolls back only what came after. Scripts with their own `BEGIN`, `COMMIT`,
  `ROLLBACK`, or `SAVEPOINT` are refused while it is on.
- On production, Run All asks once and lists every statement with its line and its own write
  warning, and whether it runs in a transaction. Run (⌘R) still runs one statement and refuses
  several. History keeps the script as one SQL entry.
- Runner: `SqlTab::runAll()`, `SqlStatementFailed`, and `statement` on `sql` events. Debug builds
  add the `sql-run-all` and `sql-transaction:on|off` steps.

### 2026-10-03 — SQL snippets ([#130](https://github.com/filipac/runlet/issues/130))

- Save as Snippet from an SQL tab saves an SQL snippet ("Save SQL Snippet"); saving to the project
  writes `.runlet/snippets/<slug>.sql` with `-- @label` and `-- @description` lines. SQL
  snippets show an SQL badge and open as SQL tabs (or switch the current tab); opening never runs
  them, and they have no `@input`s.
- Project snippets can be `.sql` files, listed with the PHP ones; metadata is the first run of
  `--` comment lines with `@label` or `@description` (or a `/** */` docblock).
- Personal snippets store `"language": "sql"`; PHP snippets don't write the key, so existing
  libraries load unchanged. Duplicate, Copy to Personal, and History's Save as Snippet keep the
  language.
- MCP: `list_snippets` and `get_snippet` return `language`; `add_snippet` takes an optional
  `language` (`php` or `sql`). `run_php` still never runs SQL.

### 2026-10-03 — Production guard: app environment and history ([#12](https://github.com/filipac/runlet/issues/12))

- Runs report the environment the application says it is in, in the `bootstrapped` event:
  `app()->environment()` for Laravel, Lumen, and Laravel Zero, the kernel's environment for
  Symfony, and `wp_get_environment_type()` for WordPress. Plain PHP and Composer projects
  report none. Only the name is read, and the Run Log's "Booted …" line shows it.
- Project drivers can report it with a new optional `environment()` method (no native return
  type, so drivers that already had a method of that name keep loading; a throwing
  `environment()` is a Run Log line and the run continues). See `docs/drivers.md`.
- When the application says `production`, `prod`, `prd`, or `live` and the target isn't marked
  production, the tab shows a notice: the run that revealed it didn't ask first, **Mark as
  Production** marks the target as its settings would (the badge and confirmations apply from
  the next run; nothing runs), and **Dismiss** hides the notice for that target, also after a
  restart. A target marked production whose application says `local`, `development`, or `dev`
  gets an informational note with Dismiss only. Runlet never changes a marking by itself.
- History keeps, for each run, how its target was marked (environment and colour) and the
  environment the application reported. Rows show a PROD (or STAGING) badge and the colour from
  that snapshot, so editing the target later doesn't relabel earlier runs; the status line and
  tooltip show the reported environment, and searching History for `production` finds them.
  History saved by earlier versions loads unchanged, without badges.
- Opening, importing, or restoring code still never runs it, and production confirmations are
  unchanged.

### 2026-10-03 — App Info panels ([#19](https://github.com/filipac/runlet/issues/19))

- Click the framework chip, in the status bar or on a vertical tab card, to open **App Info**
  for the tab's target: key/value sections that show where a snippet will run. Library ▸
  Show App Info and the command palette open it too. The status bar's chip reads "App Info"
  until the framework is known.
- Laravel shows what `php artisan about` shows (environment, debug mode, URL, maintenance
  mode, caches, drivers, storage links, and sections packages add), read in the booted
  application instead of running Artisan; Runlet doesn't run `composer --version`, so the
  Composer version is left out. Lumen and Laravel before 9.21 get the same rows from the
  configuration. Symfony shows its version and support dates, environment, debug, charset,
  kernel, and folders; WordPress its version, environment type, URLs, theme, multisite,
  plugins, debug constants, and database. Every target gets a PHP section (version, memory
  limit, OPcache, Xdebug, time zone, php.ini, PDO drivers, extensions).
- Drivers add their own sections with `panels(): array` (`'Title' => ['Label' => value]`),
  shown after Runlet's. A failing `panels()` keeps the built-in sections and shows the error.
  See [drivers.md](docs/drivers.md#app-info); `Tests/Fixtures/custom-driver/` has an example.
- Values that look like secrets are never shown or copied (`••••••` with a lock): by label
  (password, secret, token, key, salt, credential, …) and by value (credentials in URLs and
  DSNs, `password=` pairs, Laravel `base64:` keys, JWTs, private keys, known API token
  formats). The rule runs in the runner and again in the app. App Info is bounded (20
  sections, 100 rows each, 2,000 bytes a value, 256 KB in all), and paths are shown relative to
  the project or with `~`.
- App Info boots the application, so it loads only on that click (or Refresh), never on open,
  import, or restore. The result is kept per target, with its age, until Refresh or an edit of
  the target. Production targets confirm every load (⌘↩), outside the snippet-run grace; SSH
  hosts are reached only then, under the usual connection rules. Boot errors and timeouts show
  in the popover with Try Again.
- Runner: `mode: "panels"` and two `panels` events (built-in, then the driver's); new
  `Resources/Runner/src/Panels.php`. Debug builds add the `app-info[:card|off]` and
  `app-info-state` steps.

### 2026-10-03 — SQL tabs ([#35](https://github.com/filipac/runlet/issues/35))

- **SQL tabs.** File ▸ New SQL Tab, Switch Tab Language (PHP/SQL) in the Window menu, the palette, and a tab's context menu, or open a `.sql` file (File ▸ Open…, Finder, `runlet query.sql`). The language is kept in sessions, workspaces, duplicates, Reopen Closed Tab, and run history; files from before load as PHP. SQL tabs have an SQL highlighter and `--` comments, and no PHPantom (no PHP diagnostics or completion on SQL).
- **One statement per run, through the application's own connection.** Run sends the selected statement, or the statement at the caret. A selection with several statements is refused before anything runs, and the runner prepares natively, so the database rejects a second statement too. Rows show as a sortable, filterable table (Copy/Export CSV, row copy) with the row count and time; other statements show the rows they affected. At most 1,000 rows, 200 columns, 8 KiB per cell, and 8 MiB per result; a cut result says so.
- **Connections without credentials.** The bar above the editor picks the default connection or a named one (the names the driver reported after a run, or any name). Runlet asks the project's driver first, then uses Laravel's `DB::connection()`, Symfony's Doctrine registry, WordPress's `$wpdb`, or an Eloquent connection the application set up. Projects with none (plain PHP, Composer, Symfony without Doctrine) get a clear "No SQL connection" message. Runlet never asks for or stores database credentials.
- **Driver API.** `sqlConnection(?string $connection)` returns a `PDO`, a callable that returns rows or an affected-row count, or `null`; `sqlConnections()` lists names for the picker. The built-in Laravel, Symfony, and WordPress drivers implement both, and `Runlet\SqlConnections` has helpers for Eloquent, Doctrine DBAL, and `$wpdb`. See [drivers.md](docs/drivers.md#sql-connections).
- **Safety.** Opening, importing, or restoring an SQL tab never runs it; SQL tabs never auto-run, can't be profiled, and are never run by AI clients' `run_php`. On production every SQL run asks (the 10-minute grace doesn't apply), showing the statement, the connection, and a warning when it can write (`UPDATE`, DDL, `SELECT … INTO`, `FOR UPDATE`, `EXPLAIN ANALYZE …`). Write detection is best-effort; development and staging targets don't ask.
- Guide: [sql-tabs.md](docs/sql-tabs.md). Follow-ups: SQL completion ([#128](https://github.com/filipac/runlet/issues/128)), multi-statement scripts ([#129](https://github.com/filipac/runlet/issues/129)), snippets with a language ([#130](https://github.com/filipac/runlet/issues/130)).

### 2026-10-03 — Parameterised snippets ([#14](https://github.com/filipac/runlet/issues/14))

- Snippet docblocks can declare inputs: `@input <type> $<name> ["Label"] [= default] [{choice, …}]`
  with the types `int`, `float`, `string`, and `bool`, for example
  `@input int $orderId "Order ID"` or `@input string $reason = "duplicate" {duplicate, fraudulent}`.
  Project snippets read them from the metadata docblock, personal snippets from a docblock at the
  start of their code. Lines Runlet can't read are listed with the reason (an orange badge in the
  Snippets panel, a notice in the form) and left out; nothing fails silently.
- Opening such a snippet (Snippets panel, ⇧↩ Insert, Open Anything) first shows a form with one
  field per input: a text field, a menu for choices, or a checkbox, starting at the default and
  validated as you type (an `int` must be a whole number in PHP's 64-bit range; a `float` refuses
  `INF`, `NAN`, and hex). Cancel opens nothing; snippets without inputs open as before.
- Open puts each value on its own line, `$orderId = 1042;`, after the opening tag, docblocks, and
  `use` imports. An assignment to the input in the snippet's opening lines is a placeholder and
  gets the value in place instead of a second assignment. The tab never runs on its own; Run
  and production confirmations work as before.
- The literals are generated in Swift with `var_export` semantics: ints and floats exactly as PHP
  writes them (`-9223372036854775807-1`, `1.0E+25`, `-0.0`), strings single-quoted with `\` and
  `\'` escaped, and strings with control characters double-quoted on one line (`"a\nb"`, `"\x00"`,
  `"\u{202E}"`). A test evaluates about 9,000 literals with a local PHP and compares the values
  and the `var_export` text.
- Copy to Personal Snippets keeps a project snippet's `@input` lines. MCP `get_snippet` returns a
  parameterised snippet's `inputs` (and `input_problems`). See
  [docs/snippet-inputs.md](docs/snippet-inputs.md).

### 2026-10-03 — Gutter line numbers line up on blank lines ([#124](https://github.com/filipac/runlet/issues/124))

- The line number of a blank line sat lower than the others (3 points at the default 13-point font and 1.15 line height, 4 at 17 points and 1.5), and so did the empty last line's after a blank line; an empty editor's only number sat about a point high. A blank line's only glyph is its newline, which TextKit places at the bottom of the line, and the gutter put the number on that glyph. Every number now sits on its line's text baseline, at every font, size, and line height, with soft wrap on or off; the execution-error dot and the magic-comment bars move with it.
- All numbers also sit up to half a point higher than before: exactly on the text's baseline rather than just below it.
- Debug builds: `editor-check` also compares each line number with its line's text baseline (for a blank line, where typed text would sit): blank lines and the empty last line at two font sizes and line heights, an empty editor, soft wrap, and the Monaco and Menlo fonts with an emoji line.

### 2026-10-03 — Tests group in the Commands pane ([#40](https://github.com/filipac/runlet/issues/40))

- The Commands pane has a **Tests** group under Open REPL: **Run All**, **File…** (one test
  file), and **Filter…** (the tests matching `--filter`), each in a terminal tab on the tab's
  target, in the project's folder, with the target's PHP. The tab stays open after the tests
  finish. Like Open REPL it works without listing commands first, and nothing runs until you
  click: opening, importing, or restoring code never runs tests.
- Runlet picks the runner from the project's files: **`php artisan test`** when `artisan`,
  Laravel's Collision (`vendor/nunomaduro/collision`), Pest or PHPUnit, and `phpunit.xml` or
  `phpunit.xml.dist` exist (it starts Pest when installed, else PHPUnit); else **Pest**
  (`php vendor/bin/pest`); else **PHPUnit** (`php vendor/bin/phpunit`), each with `phpunit.xml`,
  `phpunit.dist.xml`, or `phpunit.xml.dist`. The pane names it, e.g. "php artisan test ·
  PHPUnit".
- Local projects and the sandbox are checked on your Mac, including the configuration's
  `<testsuite>` folders: a project without tests shows no Tests group (the bundled sandbox
  ships without `tests/`). File… opens a file picker limited to the project's folder,
  starting in its first test folder. Docker profiles, SSH hosts, and SSH container steps
  choose in the container or on the server, say so in the pane, take File… as a path, and
  explain in the tab when the project has no runner (e.g. a deploy without dev dependencies).
- Filter… and the remote File… are inline prompts with a preview of the command. A file or
  filter reaches the runner as one argument (`--filter=<text>`, quoted; `./` before a path
  that starts with `-`); spaces, quotes, `$`, and backticks pass through unchanged.
- **Disabled on production targets**, with the reason in the pane: "Tests can reset the
  database; they're disabled on production targets." Test suites often reset or migrate the
  database (`RefreshDatabase`, `migrate:fresh`). The Artisan `test` command and a
  `composer test` script stay in the command list and ask first, like every command there.
- SSH connects only on the click, under the same rules as Open REPL (a password or two-factor
  host must be connected first).
- Tests: `ProjectTestsTests` covers detection for each layout, the selection script under `sh`
  and `dash`, quoting through `sh`, `dash`, `bash`, `zsh`, and the SSH wrapping, the exact
  request per target kind, the production rule, and picked files outside the project. Live
  runs: `php artisan test --filter` in the Laravel fixture and in the fixture Docker
  container, and a stand-in PHPUnit on the SSH fixture (the filter arrives as one argument,
  in the profile's directory).

### 2026-10-03 — Code loaded into an empty tab uses the editor font ([#114](https://github.com/filipac/runlet/issues/114))

- Code loaded into an empty editor (a new tab, then Open, a History or Snippets entry, or a file reload) was drawn in the system's proportional font (Helvetica), with tab stops and line heights that did not match the line numbers, until the editor settings were applied again. Text put into the editor now always gets the editor's font, line height, tab stops, and color, whatever the editor held before.
- Undo no longer brings text back in the font, size, or line height it had before a settings change.
- Debug builds: `editor-check` also checks loading, inserting, and reloading into an empty editor, loading after a settings change, inserting at the end, and undo and redo, comparing each character's attributes and the line heights with a newly opened editor's.

### 2026-10-03 — Workflow: `in progress` label on issues ([#125](https://github.com/filipac/runlet/issues/125))

- `AGENTS.md`: opening a draft pull request adds the `in progress` label to the issues it will close; the label comes off as soon as no agent works on the issue (when the pull request is ready for review, or when the work stops).

### 2026-10-03 — Laravel completion: native-typed relations and casts() without a trailing comma ([#55](https://github.com/filipac/runlet/issues/55))

- Relations declared with only a native return type (`public function posts(): HasMany`, as
  `make:model` and the Laravel docs write them) complete the related model:
  `$user->posts->first()->` offers Post's attributes and relations, and `posts()` is
  `HasMany<Post>`. PHPantom 0.10.0 found the related model only for relations with a generic
  `@return` or with no return type.
- The last entry of a `casts()` array without a trailing comma is read, so its attribute
  completes with the cast type (`source: cast`). PHPantom 0.10.0 dropped it.
- How: when the language server starts, Runlet reads the project's model sources and opens
  adjusted copies in memory under the files' own paths (the return type blanked to spaces, the
  missing comma added), only for files with one of these two shapes. Nothing is written to the
  project. A model edited on disk is seen after Restart Language Server, as before.
- Macros registered in a service provider's `boot()` were already offered when the provider is
  registered (`bootstrap/providers.php`, as in every Laravel 11+ app). The earlier
  "unsupported" result came from a test project without that file; the tests now cover it.
- `keyBy()` and `groupBy()` on Eloquent collections still lose the model type. It is a PHPantom
  bug with no workaround in Runlet; the report draft is in `docs/compatibility.md`, and the
  follow-up is [#117](https://github.com/filipac/runlet/issues/117).

### 2026-10-03 — Bracket-match highlight no longer sticks after typing ([#113](https://github.com/filipac/runlet/issues/113))

- Typing after an opening bracket, or deleting one, could leave the other bracket of the pair highlighted until that character was deleted. The editor now removes the previous pair's highlight wherever the edit moved it, so only the pair at the caret is highlighted.
- The bracket match and the failed line's red (#87) are each found through a marker attribute of their own, looked up only where every edit has moved them, not across the whole document.
- Debug builds: `editor-check` also checks typing after a bracket, moving the caret, deleting a bracket, undo and redo, and edits elsewhere in the text.

### 2026-10-03 — A failed line's red background no longer sticks ([#87](https://github.com/filipac/runlet/issues/87))

- When a run failed, the line's red background could stay after you edited above the line, typed inside it, deleted it, or used undo and redo, even after later successful runs, sometimes on part of a line that never failed. The editor now clears it wherever the edits moved it. Bracket matches and syntax colors stay as they were.
- Debug builds: the `editor-check` step (`RUNLET_DEBUG_STEPS`) checks these cases on an off-screen editor and prints `RUNLET_DEBUG_EDITOR_CHECK` lines.

### 2026-10-03 — Output: hide until a run, Escape hides ([#60](https://github.com/filipac/runlet/issues/60))

- Two switches in Settings ▸ General ▸ Output, both off by default, so nothing changes unless you
  turn them on.
- **Hide the output pane until a run**: a tab that hasn't run shows the editor alone. Starting a
  run (Run, Run Selection, Profile Run, an approved AI client run, or sandbox auto-run) shows the
  pane right of or below the editor, where it was and at its saved size. Clear Output on a tab
  that isn't running hides it again, and switching tabs shows or hides it with the tab. Show/Hide
  Output Pane (⌃⌘O) shows or hides it for the current tab. This is per tab and never saved:
  opened and restored tabs start hidden, and nothing runs when code is opened or restored.
- **Escape hides the output pane**: Escape in the editor hides the tab's output pane until its
  next run or Show/Hide Output Pane, without changing the saved Show/Hide setting. Completions,
  hover and signature popups, and inline-value panels still close first, a visible find bar or
  text being composed keeps Escape, and ⌘. still stops a run. The palette, sheets, and the
  terminal have their own focus, so Escape there is unchanged.
- Neither switch moves or resizes the pane: the saved layout and divider position are used as
  they are. Show/Hide Output Pane and Move Output Right/Below work as before.
- Debug builds have an `editor-key:<key>` step that hands a key press to the current tab's editor
  while Runlet stays in the background, for screenshots and checks.

### 2026-10-03 — Browse directories in Docker profiles ([#62](https://github.com/filipac/runlet/issues/62))

- Docker profiles have **Browse…** next to the working directory, as SSH profiles do. It opens
  the folder picker on the container selected in the list: path field, breadcrumb, up and home,
  Laravel/Symfony/WordPress/Composer/.runlet badges, and hidden folders on request.
- It lists folder names only, with a read-only `php -r` run by `docker exec` as the profile's
  execution user with its PHP, so a folder that lists is one runs can open. It runs only when you
  click Browse… or open a folder. Opening or editing a profile still lists containers without
  exec'ing into any of them, and saving runs no snippet code.
- It lists only in the selected container. That container is checked again before every
  listing, and the profile's identity rules apply: a recreated Compose service is followed with a
  notice, as runs follow it. Several replicas, a recreated container known only by its name, or
  a stopped or removed container are errors that send you back to the container list.
- Errors are explained: a folder the user can't open (permission denied), a missing folder, a
  file instead of a folder, a missing PHP or execution user, and a container that isn't running.
  A subfolder the user can't open is marked with a lock and can't be chosen.
- Paths are kept exactly as chosen: absolute, with `.` and `..` resolved by name and symlinks
  (such as Debian's `/bin → usr/bin` or a Forge-style `current`) kept, not resolved.
- The SSH profile's container step uses the same container listing, so its errors now name the
  container and the user ("doesn't exist in …").
- DEBUG steps `browse:<path>` and `browse:select:<folder>` drive the open folder picker for
  screenshots.

### 2026-10-03 — Docker tests touch only runlet-fixtures containers ([#80](https://github.com/filipac/runlet/issues/80))

- A plain `swift test` no longer lists, inspects, or execs into the developer's own
  containers. `TestSupport.docker`, the Docker CLI of every package test that runs Docker,
  now runs the real CLI only through `Tests/Fixtures/docker/fixtures-only-docker`, which lets
  through only the `runlet-fixtures` and `runlet-fixtures-recreate` Compose projects and
  Runlet's own sandbox containers. It no longer takes whatever `docker` is first on `PATH`.
  The tests find the real CLI as the app does (`PATH`, then the usual install folders);
  `RUNLET_REAL_DOCKER` picks another. There is no opt-out, since no test needs other
  containers.
- `TestSupport` hands the wrapper to Docker through a small generated `docker` launcher. Tests
  that run the CLI's executable themselves (in a terminal, a `Process`, or a wrapping script)
  go through the wrapper as well.
- The wrapper is stricter. A container argument must be a full ID, a name, or an ID prefix of
  one of those containers, and the wrapper passes Docker the full ID. Docker therefore can't
  resolve a short ID to another container that has that name. The wrapper no longer asks
  Docker whether some other container exists. To `inspect`, another container doesn't exist
  ("No such object", as for one that is gone), and `exec`, `cp`, `pause`, `unpause`, `kill`,
  and `rm` refuse it. Each call lists the allowed containers once, with label-filtered
  `docker ps` only. `cp` treats absolute and `./` paths as local, as Docker does. The wrapper
  refuses to wrap itself, for example through an old `docker` symlink to it on `PATH`.
- `FixturesOnlyDockerTests` proves it with a recording stand-in for Docker
  (`Tests/Fixtures/docker/recording-docker`) placed behind the wrapper the same way. The
  stand-in has a fixture, a sandbox container, a container of another Compose project, and
  one named like the fixture's short ID. Discovery, profile resolution, `inspect`, `exec`
  (probes, PHP version, runs), `cp`, `pause`, `kill`, and `rm` never hand Docker another
  container. Every `ps` it gets is label-filtered, and other commands are refused. The tests
  also check that `TestSupport.docker` is the wrapper.

### 2026-10-03 — Editor no longer opens scrolled sideways ([#78](https://github.com/filipac/runlet/issues/78))

- A tab now opens with column 1 just right of the line-number gutter. Before, with soft
  wrap off and a line wider than the editor, a restored tab (and any tab opened with its
  code, such as Explain, history, or snippet tabs) started scrolled right by the gutter's
  width, so the start of every line was hidden until you scrolled back or moved the caret.
- Cause: the editor's scroll view extends the clip view under the gutter and sets the clip
  view's left inset to the gutter's width while laying out, but AppKit doesn't move the
  scroll position with it. A new editor's first layout left the position at the old edge.
  The same thing hid about a column when the gutter widened past 99 lines. `clipsToBounds`
  (#64) wasn't involved: the bug shows without it too.
- The editor's scroll view (`EditorScrollView`) now keeps the distance from the text's
  leading and top edges when those insets change. A position you scrolled to yourself is
  kept. The workaround that scrolled generated Explain tabs to their start (#4) is gone.
- Regression check: `scripts/check-editor-scroll.sh <Debug Runlet.app>` opens long files in
  a fresh launch, then restores them, switches tabs, and changes the tab layout and window
  size, hidden and with scratch data. After each change, the new DEBUG step `editor-scroll`
  prints every loaded editor's horizontal offset, and all of them must be 0.

### 2026-10-03 — Install steps: call /usr/bin/xattr by its full path ([#105](https://github.com/filipac/runlet/issues/105))

- The first-launch command is now `/usr/bin/xattr -dr com.apple.quarantine /Applications/Runlet.app` in the README and on the website. A Python `xattr` from pip, pyenv, or Homebrew earlier on `PATH` doesn't support `-r`.

## 0.2.2 — 2026-10-03

Runlet now has its app icon (a Liquid Glass icon on macOS 26), and the README and website show it; the first-launch steps describe Privacy & Security ▸ Open Anyway (ad-hoc signed, universal arm64 + x86_64).

### 2026-10-03 — App icon ([#101](https://github.com/filipac/runlet/issues/101))

- Runlet.app has an icon: the Runlet mark from the README and website (a purple gradient with
  a white play triangle and a cursor bar) instead of the generic app icon, in Finder, the
  Dock, Launchpad, and the About panel. `project.yml` already named an `AppIcon`, but there
  was no asset catalog, so nothing was compiled into the app.
- It is an Icon Composer icon, `Runlet/AppIcon.icon`, so on macOS 26 it is drawn in Liquid
  Glass and follows the icon style chosen in System Settings ▸ Appearance (default, dark,
  tinted, or clear). actool also renders the flat images in `Assets.car` and `AppIcon.icns`
  from it.
- A classic `Runlet/Assets.xcassets/AppIcon.appiconset` (16–512 pt at @1x and @2x) follows
  Apple's macOS icon template: an 824 px rounded square with continuous corners and a soft
  shadow on the 1024 px canvas, with each size drawn at its own pixel size so 16 and 32 px
  stay sharp. While `AppIcon.icon` exists, actool uses that instead; the classic set is the
  fallback if it is removed.
- `scripts/app-icon/make-app-icon.swift` generates both from `website/assets/favicon.svg`;
  run it again when the mark changes.
- The README and the website show the new icon, which looks a little different from the flat
  mark. The README's header image, the site's header and footer logos, its favicons (16, 32,
  and 48 px PNGs in place of the SVG), the `apple-touch-icon`, and the Open Graph image
  (`og.jpg`) all use it. `scripts/app-icon/export-web-icons.swift` renders these images from
  `Runlet/AppIcon.icon` with Icon Composer's `ictool`, in macOS's default style: 1024, 512,
  and 224 px images with the macOS icon margins and shadow, favicons and the logo drawn
  directly at their size, and a 180 px `apple-touch-icon` filled to the edges.
  `scripts/website-screenshots/brand.swift` now draws only `og.jpg`.

### 2026-10-03 — Install steps: Open Anyway in Privacy & Security ([#99](https://github.com/filipac/runlet/issues/99))

- The README's First launch steps and the website's install steps and FAQ no longer tell you to
  right-click Runlet.app ▸ Open, which doesn't get past Gatekeeper for an app that isn't
  notarized since macOS 15. They now say to open Runlet once, then click **Open Anyway** next to
  the message about Runlet in System Settings ▸ Privacy & Security and confirm, or to run
  `xattr -dr com.apple.quarantine /Applications/Runlet.app` in Terminal, as the 0.2.1 release
  notes do.

## 0.2.1 — 2026-10-03

Fixes the crash when opening Install Command-Line Tool from Settings and the no-PHP banner flashing at launch; a reworked README (ad-hoc signed, universal arm64 + x86_64).

### 2026-10-03 — Install Command-Line Tool no longer crashes from Settings ([#92](https://github.com/filipac/runlet/issues/92))

- Runlet 0.2.0 could crash when Settings ▸ General ▸ Command-Line Tool ▸ Install… opened the
  Command-Line Tool window. The window followed its content through the hosting controller's
  preferred size, so AppKit resized it from inside its own layout pass whenever the content's
  height changed (the shell's PATH arriving, a hint wrapping onto another line, the result of
  Install or Remove Link). That is the pattern behind AppKit's "Update Constraints" loop
  exception. The window is now sized by hand: the content reports its natural size and the
  window follows it after the layout pass, keeping its top edge. Settings opens the window
  after its click is handled rather than during it.
- The crash didn't reproduce on macOS 27 (Debug, optimized arm64, and optimized x86_64 under
  Rosetta, from Settings and the menu, with folders that are missing, read-only, a file, or
  hold a dangling link). The reporting Mac's crash report will confirm the cause.
- `scripts/check-cli-window.sh <Debug Runlet.app> [runs]` opens the window from Settings and
  from the menu command with scratch data (and a preselected scratch folder), and fails if
  Runlet doesn't survive. New `CommandLineInstall` tests cover a folder this user can't write,
  missing folders, a file where the folder should be, dangling links, and odd PATH values; no
  trap was found in those paths or in the administrator-password step.

### 2026-10-03 — README: positioning and clarity ([#95](https://github.com/filipac/runlet/issues/95))

- `readme.md` now leads with what Runlet is and why to use it: a native macOS PHP scratchpad
  for running code inside real projects ("Run PHP anywhere. Inspect everything. Experiment
  insanely fast."), a screenshot, the download, and four short workflows, followed by who it's
  for and how it compares with Tinker, temporary routes or scripts, `dd()`, and IDE scratch
  files.
- New sections for magic comments, running inside real applications, the run inspector, targets
  and the production guard, benchmarks and Profile Run, and AI clients over MCP (approvals and
  safeguards). A grouped feature overview (Execute, Inspect, Measure, Iterate, Automate) and the
  supported environments replace the flat feature list; development, documentation, and
  license details move lower and are kept.
- Installation spells out the requirements (macOS 26 or later, one universal app), that
  releases are ad-hoc signed and not notarized, the Gatekeeper steps and why removing the
  quarantine flag works, checksums, updating, and that there is no Homebrew cask.
- Three new screenshots in `website/assets/shots` (light and dark, 1200 and 2400 px): magic
  comments in the Laravel sandbox, a Profile Run flame graph on Runlet's own PHP, and the MCP
  approval sheet for a production SSH target. They were taken from a Debug build with its own
  bundle identifier, hidden, with scratch data, a fake Docker CLI, and the fake ssh fixture; the
  approval was declined, so nothing connected anywhere.

### 2026-10-03 — No-PHP banner no longer flashes at launch ([#91](https://github.com/filipac/runlet/issues/91))

- On a Mac with PHP, the "No PHP was found on this Mac… Download PHP" banner no longer shows
  for a moment at launch. Runlet now waits for its first PHP scan to finish before it offers
  its own PHP; after the scan the banner appears only if no usable PHP was found, as before.
- The sandbox stays "Preparing sandbox…" until that first scan finishes, so it can't briefly
  choose Docker or report no PHP. A run started meanwhile, in the sandbox or in a local project
  without its own PHP, waits for the scan instead of failing with "No PHP".
- Settings ▸ PHP shows "Scanning…" rather than "No PHP installations were found", and the
  project PHP picker shows "checking…" rather than "none found", until the first scan finishes.
- Debug builds: `RUNLET_DEBUG_DISCOVERY_DELAY=<seconds>` delays the first scan, to check what
  launch shows meanwhile; the `state` debug step reports the scan and the banner offer.

## 0.2.0 — 2026-10-03

An MCP server for AI clients, magic comments, benchmarks and Profile Run with flame graphs, Open REPL, sandbox-only auto-run, Explain for captured SQL, string viewers, a run timing breakdown, realtime or at-once output with much faster large output, and Runlet's own downloadable PHP (with Excimer) for Macs without PHP (ad-hoc signed, universal arm64 + x86_64).

### 2026-10-03 — Output realtime or at once ([#82](https://github.com/filipac/runlet/issues/82))

- Settings ▸ General ▸ **Output**: **Realtime** (the default) or **At once**. At once shows a
  run's printed output, dumps, result, errors, magic-comment values, and the inspector's
  queries, mail, logs, benchmarks, and profile together when it ends: completed, failed, `dd()`,
  `exit`, or stopped (what arrived before Stop is shown). The status bar, elapsed time, Stop, and
  the Run Log stay live; while it runs the output says "Output appears when the run ends". The
  app holds the output, so every target behaves the same, and AI clients over MCP get the full
  result in both modes.
- It replaces the magic comments' **Show values while the code runs** switch (#10). A saved
  "off" becomes At once; older settings files open with Realtime.
- Large output keeps up: before, 5,000 `dump()` calls or 200,000 echoed lines took minutes to
  appear and froze the window. The tab now takes events in batches (at most ten updates a
  second, fewer while drawing is slow), printed output is drawn a piece at a time, and the same
  runs show within a few hundred milliseconds of finishing. Structured shows the last 5,000
  lines of a printed output and the last 1,000 cards (**Show All** shows every card); Plain and
  Raw now use a native text view that appends new output, follows the end while scrolled to the
  bottom, and has Find. Plain, Raw, Copy Output, and Save Output always have everything.
- New DEBUG step `wait-run[:<seconds>]`: waits for the selected tab's run and prints its timings.

### 2026-10-03 — Specialized string viewers ([#7](https://github.com/filipac/runlet/issues/7))

- Structured strings offer JSON trees with Copy Pretty, searchable/wrapping text, PNG/JPEG/SVG images, and restricted HTML previews. Long strings open in Text; the original Tree stays available. Recognition and raster decoding are bounded, and incomplete strings retain their truncation notice. See [the viewer guide](docs/string-viewers.md).

### 2026-10-03 — Run timing breakdown ([#9](https://github.com/filipac/runlet/issues/9))

- Finished output shows **Bootstrap**, **Execute**, and **Started** alongside labeled total time, peak memory, and query time. Hover the finished row or status to see the complete breakdown, including unavailable phases.
- Completion events preserve runner phase timings through normal, error, cancellation, and transport-close paths. Old completion records remain readable. Query metrics survive Clear Output in the status tooltip and reset for the next run. See [the timing guide](docs/run-timings.md).

### 2026-10-03 — Runlet's PHP r2 with Excimer ([#79](https://github.com/filipac/runlet/issues/79))

- Runlet's own PHP is now build `php-8.5.8-r2`, which adds the **Excimer** extension, so Profile
  Run works on a Mac with no other PHP installed. Same PHP 8.5.8 and extensions otherwise.
- **Updating from r1:** an installed older build keeps working, and Settings ▸ PHP ▸ Runlet's PHP
  shows "PHP 8.5.8 (r1) installed · Update to r2. Adds Excimer, so Profile Run works." Update
  downloads and verifies r2, moves the default PHP and projects' PHP from the old binary to the
  new one (also if Runlet quit in between), and removes r1. Nothing downloads without a click.
- Remove now clears the default PHP and projects' PHP that pointed at any build of Runlet's PHP.

### 2026-10-03 — Xcode runs no longer stop on a Metal validation assert ([#85](https://github.com/filipac/runlet/issues/85))

- Running from Xcode stopped at random on `instanceCount(0) must be non-zero`, raised by Metal API Validation while Core Animation replayed a line stroke with nothing to draw. Normal launches were unaffected. The `Runlet` scheme now runs with Metal API Validation off; turn it back on in Edit Scheme when debugging GPU issues.
- The benchmark charts and the flame graph skip drawing at zero size, and the flame graph skips the hover outline on frames too small to show it, so Runlet's own views never ask for an empty stroke.

### 2026-10-03 — Magic comments ([#10](https://github.com/filipac/runlet/issues/10))

- Magic comments show values in the editor while the code runs, without `dump()` calls or
  temporary variables. `//?` at the end of a line shows the line's value (an assignment's
  value, a `return`, an `echo`; `✓` on a line without a value, such as `foreach (…) { //?`).
  `/*?*/` right after an expression shows that value, `/*?->count()*/` (any `->` or `?->`
  chain) shows a projection while the code keeps the value itself, and `/*?.*/` shows the
  milliseconds since the previous one (or since the snippet started).
- Values appear as dim text after the line, `×N` and the latest value for lines that run more
  than once. Hovering them (or Edit ▸ Show Inline Value) opens a panel with the value tree and
  the list of hits. Magic comments are highlighted, and the gutter marks lines whose comments
  ran. Values stream in while the code runs, on every target, and map back to the right lines
  for Run Selection. Edit ▸ Clear Inline Values and Clear Output remove them.
- Adding magic comments never changes what the code does. The runner inserts probe calls at
  byte offsets on the same lines (it never re-prints the code), keeps references
  (by-reference arguments, `=&`, `foreach (… as &$v)`, by-reference returns and yields) and
  nullsafe short-circuits, and refuses places where a call would change the code: assignment
  targets, `isset()`/`empty()`/`??` operands, constant expressions, the start of `"{$…}"`, and
  variables passed to methods that might take them by reference. Refused comments get one
  notice and a short reason on their line; the code runs as written. Semantics fixtures run
  each snippet with and without its magic comments and require the same results (PHP 8.4 and
  7.4).
- Limits: the first 100 hits of each comment carry values, later hits are counted with a value
  sampled about four times a second, and values stop after 16 MiB per run. Projections run
  only for hits whose values are sent, and may query a database.
- The next run clears values; a line edited since the run loses its values, and other lines
  keep theirs, moved with their text. Values never start a run.
- Settings ▸ General ▸ Magic Comments: **Show values of magic comments** turned off makes them
  ordinary comments: runs get no probes on any target, and the editor neither highlights them
  nor shows values. **Show values while the code runs** turned off shows a run's values
  together when it ends (also after a failure or Stop); the app holds them, so the runner and
  every target work as before. Both are on by default. Profile Run never inserts probes, so
  its flame graph shows only the code as written.
- A comment after the final expression (`1 + 1; // note`) no longer hides its result.
- New DEBUG steps for screenshots: `selection:<first>-<last>` and `inline:<line>|off`.

### 2026-10-03 — Benchmark and profile ([#41](https://github.com/filipac/runlet/issues/41))

- `Runlet\bench($callables, $iterations = 1000, $label = null, $seconds = null)` measures code
  in any snippet, on every target (PHP 7.4+, no extension): a cold call, a short warm-up, then
  up to 100,000 calls timed with `hrtime(true)`, stopping early when a callable has used its
  time budget (1 s by default, at most 60 s). It returns the numbers in milliseconds and shows
  a benchmark card where it ran and in a new **Benchmarks** section: mean, median, p95, min,
  max, throughput, iterations, standard deviation, the first call, the peak memory and the
  memory kept per call, a histogram of call times with median and p95 markers, and the times
  in run order. An array of callables keyed by label is compared side by side.
- Laravel's `Benchmark::dd()` shows the same card, with the averages Laravel measures: Runlet
  recognizes its dump. `Benchmark::measure()` only returns numbers, so `Runlet\bench()` takes
  the same arguments.
- **Run ▸ Profile Run** (⌥⌘R, and in the Command Palette) runs the tab like Run, with the
  same production confirmation, and samples the snippet with the Excimer extension (wall
  time, every millisecond). The **Profile** section draws a native flame graph: hover a frame
  for its function, file and line, samples and share; click to zoom in, Reset to zoom out,
  and search to highlight frames. It also lists the hottest functions and copies the samples
  as collapsed stacks. Stacks are bounded (4,000 stacks of up to 200 frames), and the view
  says when something was folded.
- Profile Run is disabled, with the reason, when the target's PHP doesn't load Excimer; the
  Command Palette still lists it with that reason. PHP discovery (Settings ▸ PHP), the Docker
  profile's Test, SSH Test Connection, and every run report which profilers a PHP loads. SPX
  is detected but not used: it profiles only processes started with `SPX_ENABLED=1` and
  writes its reports to files. A PHP without Excimer stops a Profile Run before anything
  runs.
- The editor no longer marks `Runlet\bench()` or `Runlet\Inspector` as unknown: the runner
  defines them when it runs.
- Testing: a disposable runlet-fixtures `profiler` service (PHP 8.4 with Excimer and SPX), and
  `Tests/Fixtures/docker/fixtures-only-docker`, the real Docker CLI limited to Runlet's
  disposable containers, for running the app or `swift test` against real Docker. Debug
  builds add `flame:hover|zoom|search|reset` and `profiles:<name>` steps for screenshots.

### 2026-10-03 — Personal snippet descriptions ([#52](https://github.com/filipac/runlet/issues/52))

- Save Snippet and Edit Snippet support an optional description. Descriptions appear in the Snippets panel and Open Anything, and both search them. Blank descriptions are removed; older snippet libraries load without migration.
- Duplicate and Copy to Personal preserve descriptions. MCP `list_snippets` searches and returns personal descriptions, and `get_snippet` returns them when present. Saving, editing, copying, and opening snippets never runs their code. See [the guide](docs/personal-snippets.md).

### 2026-10-03 — Sandbox-only auto-run ([#30](https://github.com/filipac/runlet/issues/30))

- Sandbox tabs offer **Auto-run** in the toolbar. Explicitly enabling it shows **AUTO** and evaluates the whole tab after 800 ms without editor edits; enabling alone never runs the existing code. Changes during a run wait for completion, with no overlapping executions.
- Auto-run is off by default and never saved in sessions or workspaces. Switching targets, loading code, reopening a closed tab, or restarting requires a fresh opt-in. Local, Docker, SSH, and production targets have no auto-run option. Stop, explicit Run, disabling auto-run, and closing the tab cancel pending automatic execution.
- See [the sandbox auto-run guide](docs/sandbox-auto-run.md) for behavior and validation.

### 2026-10-03 — MCP server ([#43](https://github.com/filipac/runlet/issues/43))

- AI clients such as Claude Code, Claude Desktop, and Cursor can use Runlet through
  `runlet mcp`, the bundled tool started with the argument `mcp`. Its tools: `list_targets`,
  `list_snippets`, `get_snippet`, `add_snippet` (saves only), `run_php(target, code)`, and
  `get_last_output`. Results read like the output pane: output, dumps, the result, errors
  with the line in the code sent, the duration, and the target, plus the same as
  structured data.
- Every `run_php` shows a sheet in Runlet's window, brought forward, with the client's name,
  the target and where it runs, and all of the code. ⌘↩ runs; ↩ or Esc cancels, and the
  client hears that nothing ran. A request nobody answers expires after 5 minutes. A request
  the client cancels is withdrawn; a run that started finishes in its tab.
- "Allow sandbox runs from <client> for this session" is offered only for the Laravel
  sandbox. It lasts until that client disconnects or Runlet quits, and Settings can revoke
  it. Local projects and Docker applications always ask.
- Production targets always ask, with a red warning and Run on Production. The 10-minute
  "don't ask again" never applies to AI clients, and approving their runs never grants it.
- SSH hosts are never connected silently: the sheet says when pressing Run connects, and a
  host that needs a password or a one-time code is refused until you log in with Connect….
- Approved runs open in a tab named after the client, with a note saying who asked, and
  are recorded in History. Listing, reading, and saving snippets, starting Runlet, and
  restoring tabs never run code.
- Settings ▸ AI Clients turns the server on (it is off by default), shows its status and the
  connected clients, and gives the Claude Code command and the `mcpServers` JSON for this
  copy of Runlet.
- The app listens only on a Unix socket in `<data folder>/MCP` (folder 0700, socket 0600),
  never on the network. Both ends check that the other runs as the same user
  (`getpeereid`), and messages are size-limited. `RUNLET_DATA_DIR` moves the socket with the
  data. If Runlet isn't running, `runlet mcp` starts it in the background on the first call.
- The protocol is MCP 2026-07-28 (per-request metadata, `server/discover`), with
  `initialize`-based clients served on 2025-11-25, 2025-06-18, 2025-03-26, or 2024-11-05.
  No third-party code.
- `runlet --target` (and the MCP tools) now also find SSH profiles (`ssh:<name>`) and take
  `<kind>:<id>` when two targets share a name. Opening a file on an SSH host never connects.
  `runlet mcp` started by hand in a terminal explains itself and exits; a folder named
  `mcp` opens as `runlet ./mcp`.
- Debug builds: the steps `mcp:on|off`, `mcp-wait`, `mcp-approve[:session]`, `mcp-decline`,
  and `mcp-state`; `RUNLET_DEBUG_MCP_APPROVAL_TIMEOUT` and `RUNLET_DEBUG_APP_PATH`;
  `RUNLET_MCP_NO_LAUNCH` for the tool. `scripts/mcp-e2e/driver.py` checks the whole flow
  against a hidden Debug build with scratch data. Documentation:
  [docs/mcp.md](docs/mcp.md).

### 2026-10-03 — Open REPL in the terminal ([#32](https://github.com/filipac/runlet/issues/32))

- The Commands pane has **Open REPL** (also Library ▸ Open REPL and the command palette): the
  target's own interactive REPL in a terminal tab, so variables and state carry over from
  one line to the next. It works without listing commands first, and it starts only when
  clicked: opening, importing, or restoring code never opens one.
- Runlet picks the REPL from the project's files: **Tinker** (`php artisan tinker`) when
  `artisan` and `vendor/laravel/tinker/` exist (the sandbox and Laravel apps), else the
  project's **PsySH** (`php vendor/bin/psysh`), else **PHP's interactive shell** (`php -a`,
  titled "PHP shell"). The pane shows which one, e.g. "Tinker · php artisan tinker".
- Every kind of target, run the way project commands are: local projects and the sandbox type
  the command into your shell in the project folder with the target's PHP; Docker profiles
  use `docker exec -it` with the profile's user, working directory, and TMPDIR, in the
  resolved container; the Docker sandbox a disposable `docker run --rm -it`; SSH hosts an
  `ssh -t` through the shared connection (`cd` to the profile's directory, the profile's
  PHP), or `docker exec -it` in the container step's container on the server. Docker and SSH
  targets choose the REPL on the target, in the same `sh` that starts it, and set the tab's
  title ("Tinker · app-prod") once they have. The tab stays open after the REPL exits.
- SSH connects only on the click, with the usual rules: a password or two-factor host must be
  connected with Connect… first (the button is disabled until then).
- Production targets ask before every REPL (⌘↩ confirms). The 10-minute grace for snippet
  runs never applies, and confirming a REPL doesn't grant it: once a REPL is open, every line
  typed into it runs without another question.
- Debug builds: a new `terminal:<text>` step types into the selected terminal tab (`\n` is
  Return, `\c` a comma).

### 2026-10-03 — Explain captured SQL in a new tab ([#4](https://github.com/filipac/runlet/issues/4))

- Added Explain to query rows, their context menus, and expanded similar-query groups. It prepares a new PHP tab with the captured run target, SQL placeholders, typed bindings, and named connection; opening or restoring it never executes it. Explicit Run keeps the normal production confirmation.
- SQLite requests a query plan; MySQL/MariaDB and PostgreSQL use plain EXPLAIN. Laravel/Eloquent, Symfony, and WordPress use their captured database API. Custom DBAL/PDO templates require recreating the connection explicitly. Incomplete captures and unsupported drivers cannot generate a misleading plan request. See [the Explain guide](docs/sql-explain.md) for connection requirements and validation scope.

### 2026-10-03 — Website: "No PHP? No problem." ([#67](https://github.com/filipac/runlet/issues/67))

- The website has a new section right after the hero about Runlet's own PHP (#2): Runlet
  runs PHP on a Mac with no PHP and no Docker. One click downloads a self-contained PHP
  8.5.8 (about 26 MB), checked against the SHA-256 pinned in the app before it's installed,
  and installed PHP always comes first. A collage of four app screenshots tells the story
  (the banner, the download in progress, Settings ▸ PHP, and a run), in light and dark,
  with four numbered steps under it. The nav's Features link now starts there.
- Copy that said the sandbox needs installed PHP or Docker now mentions Runlet's PHP: the
  sandbox card, the install steps, the requirements, and the FAQ, which also answers "Do I
  need PHP installed?".
- `scripts/website-screenshots/shoot-own-php.sh` makes the collage: a Debug build on a Mac
  that seems to have no PHP and no Docker (`RUNLET_DEBUG_HIDE_SYSTEM_PHP=1`, a fake Docker
  CLI, a scratch data folder at a neutral path), with the release archive served slowly on
  localhost so the download shows in progress. `own-php-collage.swift` lays out the shots.
  `render-section.swift` renders a part of the page with WebKit at a given width and
  appearance, and reports anything wider than the viewport.

### 2026-10-03 — Keep compiled PHP on the server: on for new SSH profiles ([#68](https://github.com/filipac/runlet/issues/68))

- New SSH profiles start with **Speed ▸ Keep compiled PHP on the server** turned on: New
  SSH Profile, the Profiles window's **+**, hosts imported from `~/.ssh/config`, and hosts
  first opened from a workspace file. Runs keep PHP's compiled files in a private cache on
  the server (`~/.cache/runlet/opcache`, mode 0700), and edited files are still picked up.
- Saved profiles keep their setting. A profile saved without it (by 0.1.0 or earlier, where
  it was off unless turned on) stays off, and switching it off is now saved explicitly.
- Turn it off in the profile and Runlet writes nothing on the server. It still applies only
  to the server's PHP, not with a container step. The help text under the toggle, the SSH
  profile header ("only the compiled-PHP cache (Speed) is kept on the server"), `docs/ssh.md`,
  and the website's "nothing is written on the server" lines say so.
- Debug builds: a new `scroll:<accessibility identifier>` step scrolls an element to the
  middle of its scroll view, for screenshots of controls low in a sheet's form.

### 2026-10-03 — Runlet's own PHP when none is installed ([#2](https://github.com/filipac/runlet/issues/2))

- When no installed PHP fits, Runlet offers to download its own self-contained **PHP 8.5.8**
  from Settings ▸ PHP ("Runlet's PHP") or from a banner above a sandbox or local-project tab.
  It works without Herd, Homebrew, or Docker. It is downloaded only on that click, for this
  Mac's CPU only, checked against the SHA-256 pinned in the app, and must run before it is
  installed in Application Support.
- It is only a fallback: installed PHP (Herd, Homebrew, `PATH`) is always preferred, and
  Runlet's PHP comes last in the list. It can also be chosen as the default or for a project,
  and removed again.
- The build is static-php-cli's "common" extensions plus mysqli (WordPress), intl, sodium,
  and readline (`scripts/php-runtime/craft.yml`). `.github/workflows/php-runtime.yml` builds
  it for Apple silicon and Intel, and publishes it as a `php-8.5.8-r1` pre-release that never
  becomes the "Latest" release.
- The banner and Settings show the download's progress. A failed download says why, and
  the banner offers Try Again.
- The editor's gutter no longer draws its edge line up through the banners above the
  editor (this banner, SSH, Docker, and the sandbox image): views stopped clipping to
  their bounds by default in macOS 14, so the editor's scroll view and ruler now do.
- Debug builds: `RUNLET_DEBUG_HIDE_SYSTEM_PHP=1` behaves as on a Mac without PHP, and
  `RUNLET_DEBUG_PHP_URL` fetches the archive from elsewhere (a CI artifact served locally)
  before the release exists; it must still match the pinned checksum. New debug steps:
  `settings-tab:<name>`, `frame:<window>=<size>`, and `shot:<name>@<window>`.

### 2026-10-03 — Pull request workflow ([#65](https://github.com/filipac/runlet/issues/65))

- `AGENTS.md` describes how work reaches `main`: one branch per issue, a draft pull request
  opened early, incremental commits, screenshots for UI changes, and the new
  `ready to review` label when the work is finished.

### 2026-10-02 — Keep pane dividers out of the title bar ([#1](https://github.com/filipac/runlet/issues/1))

- Clip the main window's content and its editor/output area to their bounds so pane backgrounds and dividers cannot draw behind the toolbar, window buttons, or horizontal tab strip. Applies to both horizontal and vertical tabs.

### 2026-10-02 — Issue-first work tracking and backlog reconciliation ([#3](https://github.com/filipac/runlet/issues/3))

- Added repository-wide `AGENTS.md` instructions to track work in labeled GitHub issues before implementation or adding TODOs.
- Reconciled release ideas against the changelog/code, archived completed scope in `docs/done-next-release-ideas.md`, and linked outstanding and partial scope to GitHub issues.
- Updated the historical MVP plan/review and stale SSH command/snippet guide references; preserved historical validation evidence without claiming a fresh test run.

## 0.1.0 — 2026-10-02

SSH targets, the production guard, the run inspector, the Run Log, and many fixes since 0.0.1 (ad-hoc signed, universal arm64 + x86_64).

### 2026-10-02 — Keep compiled PHP on the server (SSH)

- SSH profiles have an opt-in **Speed ▸ Keep compiled PHP on the server**. Runs then use
  PHP's opcode cache with a file cache in `~/.cache/runlet/opcache` (mode 0700, only the
  SSH user), so big apps such as WordPress with many plugins don't recompile every file on
  each run.
- Timestamps are checked on every run, so edits are picked up. When the folder can't be
  created or PHP has no opcache extension, runs go on uncached.
- Only Runlet's runs use the cache; the server's PHP settings are untouched. It's off by
  default because it writes to the server, and not offered with a container step.
- The Run Log's WordPress boot line shows the file cache when it is in use.

### 2026-10-02 — Remembered for the session: driver and WordPress site URL

- Runs remember what they worked out per target until Runlet quits, and the runner reuses
  it once it checks it still applies:
  - the built-in driver it chose, while no `.runlet` driver is added or edited;
  - a WordPress site URL, while wp-config.php has the same modification time and size.
    This skips the wp-config.php evaluation and database lookup, about 50 ms per run.
- The Run Log says "remembered for this session". A run that fails while booting forgets
  that target's values, so the next run detects everything again.

### 2026-10-02 — Where WordPress's boot time goes

- The Run Log has a WordPress boot breakdown:
  - time per phase: core and must-use plugins, plugins, `plugins_loaded` hooks, theme,
    user and init setup, `init` hooks, `wp_loaded` hooks, and Runlet's admin APIs;
  - the slowest plugins to load, by folder;
  - whether PHP's opcode cache is on for the command line. It is usually off
    (`opcache.enable_cli`), so every run compiles every file the site loads, while web
    requests keep them compiled.

### 2026-10-02 — Quitting really quits; SSH connects on the first run

- Quitting closes the shared SSH connections that runs opened by themselves (profiles using
  ssh-agent, 1Password, or keys). Nothing stays connected after Runlet quits, and the next
  launch shows Disconnected until the first run on that host connects. Logins made with
  Connect… (passwords, 2FA) still stay open until Disconnect.
- Quitting never waits more than 4 seconds for runs, language servers, or SSH connections to
  stop, so Runlet can't be left "Running in Background" after ⌘Q.

### 2026-10-02 — Profiles window for Docker and SSH, `~/.ssh/config` import (SSH-7)

- **Library ▸ Manage Profiles…** opens one Profiles window (formerly Docker Profiles) for every
  Docker and SSH profile: the list has Docker and SSH Hosts sections (SSH rows show the
  connection status, read on this Mac, and the environment); the left side edits the selected
  profile with its usual form. Same model as before: a draft until Save (↩/⌘S), Revert,
  Save / Don't Save / Cancel on switching or closing; + creates either kind (hold for the menu)
  or imports hosts; ⋯ duplicates, uses in the current tab, or connects and disconnects.
- **Import SSH Hosts from ~/.ssh/config…** (Library menu, the Profiles window, Settings ▸
  Targets, the command palette): the config's `Host` aliases with their `ssh -G` summary;
  tick hosts, optionally enter each directory (or use Detect later), and check the
  environment, preselected from words such as `prod` and `staging` in the alias or host
  name. Nothing connects.
- Settings ▸ Targets: Import and Manage Profiles… for SSH hosts, which also show when they're
  connected; SSH hosts can be the default target for new tabs (a new tab never connects).
- Debug builds: `RUNLET_SSH_EXECUTABLE` replaces `/usr/bin/ssh`. `Tests/Fixtures/fake-ssh/ssh` is
  a loopback fake for screenshot tours (made-up `ssh -G`, a fake shared connection and password
  prompt, commands run on this Mac; never a server), and the visual tour uses it with a made-up
  SSH config and adds a Profiles-window shot.
- Tests: the import helpers (environment guess, `ssh -G` with a test config) and the fake ssh
  driving a run, Test Connection, status, and Disconnect.

### 2026-10-02 — SSH: Docker on the server (SSH-6)

- SSH profiles can **run inside a Docker container on the host**: turn it on in "Docker on
  This Host", click **List Containers…** (lists the server's running containers over SSH,
  grouped by Compose project), and choose one. Runs use `docker exec` into it through the
  profile's SSH connection (no prompts, strict host keys, the shared login), with the
  container's PHP, user, working directory, and TMPDIR, and an optional `sudo -n docker`.
- The container is found the way Docker profiles find theirs: by Compose project and
  service (or name), checked again right before launch, and never switched silently; several
  replicas or a replaced container ask which one to use (the chosen replica stays chosen while
  it runs, also for Docker profiles).
- Stop signals PHP inside the container on the server; the container keeps running. Test
  Connection also finds the container and probes it (a server without PHP of its own is
  fine). Browse… lists folders inside the container.
- File links map container paths to the local folder through the server directory's bind
  mount. Project commands run inside the container (`docker exec -it` over `ssh -t`); the
  terminal's + menu offers a shell in the container and one on the server itself.
- Tab cards show "SSH · Docker", the target's container appears in the production
  confirmation, ⌘P, Settings ▸ Targets, and the status bar, and workspace files carry the
  container step (by Compose identity or name, never an ID).
- Docker problems on the server are explained (Docker not found, no permission on the Docker
  socket, sudo asking for a password, daemon not running).
- Tests: a fake `docker` installed on the SSH fixture (made-up containers that are folders
  of the fixture) covers listing, resolution (replicas, recreation, a replaced name-only
  container), runs, Stop, a vanished container, probes, facts, folder listings, command
  listing, and a project command in the container; plus unit tests for the model,
  validation, workspaces, and path mapping.

### 2026-10-02 — SSH: project commands and shells on the server (SSH-5)

- Commands listed for an SSH host now run **on the server**: a terminal tab runs `ssh -t`
  (still BatchMode, strict host keys, and the shared connection: no password prompts, no
  unknown host keys) with `/bin/sh -lc 'cd <directory> …; <command>'`, a leading `php`
  replaced by the profile's PHP. The login shell's profile applies, so Composer's global bin
  and similar PATH additions work. A missing directory is explained in the tab. Commands
  that need arguments open a login shell in the directory with the command typed.
- **Shell on Host**: a login shell on the server in the profile's directory, from the
  terminal's + menu, the target menu, the Commands panel, the Library menu, and the command
  palette ("Open Shell on SSH Host"). Terminal tabs running `ssh` show a server icon.
- Commands panel for SSH hosts: "List Commands on <host>" (Connect… first for a password
  host that isn't logged in), a note when the host is production, and a server icon on
  commands that run there.
- Production hosts ask before every command, every listing, and every shell (the 10-minute
  grace covers snippet runs only).
- Tests: the exact terminal argv runs under `script(1)` against the SSH fixture (odd
  directory names, the server's PHP, a missing directory, a login shell, an unknown host
  key), plus unit tests of the argv and its quoting, including the container form.

### 2026-10-02 — Run Log, and why an app exits while booting

- **Run ▸ Show Run Log** is a toggle, also in the palette and the output pane's share menu, and
  available in release builds too. It shows a log under the output for the current run:
  - the exact launch command as one shell line (`/usr/bin/ssh …`, `docker exec …`, or the
    local PHP), the working directory, and the runner script's size on stdin;
  - the driver the runner chose and why, boot time, and variables;
  - stderr, errors, and how the process ended (status, reason, exit code, time).

  Environment values are never shown. Copy copies the whole log.
- An `exit()` during bootstrap now explains itself. The error names the project file loaded
  last, usually the plugin, config file, or bootstrap script that exited. For WordPress, it
  also gives the redirect WordPress tried (URL, status, and the file and line that sent it),
  with advice for an `install.php` redirect (WordPress found no installation in the database
  wp-config.php points to, as the command line sees it) and for forced-HTTPS or
  canonical-host redirects.
- WordPress runs present the site's real host and scheme instead of `http://localhost`, so
  canonical-host and force-HTTPS code (page caches such as W3 Total Cache, SSL plugins) no
  longer redirects and exits. The host comes from `WP_HOME`/`WP_SITEURL` (or
  `DOMAIN_CURRENT_SITE` as wp-config.php really defines them. wp-config.php is evaluated in a
  separate PHP process, the way WP-CLI does it: the line that loads WordPress is removed,
  `__DIR__`/`__FILE__` point at the real file, and output is discarded. That means
  conditionals, environment variables, and included files count, and commented-out or
  local-only definitions don't. Without those constants, the `home` option is read from
  MySQL/MariaDB with the real database settings (one read-only query). The config is read as
  text, ignoring comments, when the probe can't run, and `home` is applied once WordPress
  connects as a last resort. Plugins that cache the host early, such as W3 Total Cache, see
  the right one. The request used, and where it came from, is in the Run Log.
- Drivers can add Run Log lines with `$this->log()` and explain exits with
  `bootstrapExitHint()`.

### 2026-10-02 — Website

- `website/`: a one-page site for https://filipac.github.io/runlet/ (plain HTML, CSS, and a
  small script; system fonts, automatic light and dark, no trackers or external requests):
  run anywhere, run inspector, editor and completion, drivers and commands, more features,
  open source, install (with the steps for an ad-hoc signed build), and FAQ. The "Early
  preview" badge is one element near the top of `index.html`.
- Screenshots are real windows of a Debug build with demo content, in light and dark (WebP,
  1200 and 2400 px wide), plus an Open Graph image and icons. No personal data: a demo
  Laravel project, made-up Docker containers, and the `runlet-fixtures` SSH host under
  `app.example.com` / `shop.example.com`.
- `.github/workflows/pages.yml` deploys `website/` to GitHub Pages on pushes to `main` that
  change it (and on demand). Pages must use "GitHub Actions" as its source.
- `scripts/website-screenshots/shoot.sh` regenerates the screenshots: it builds the app with
  its own bundle identifier, seeds a scratch `RUNLET_DATA_DIR`, and runs it hidden in the
  background, so nothing appears on screen and your Runlet data, `~/.ssh`, and containers are
  never touched.
- Debug builds: `RUNLET_DEBUG_STEPS` gains screenshot steps in `DebugSteps.swift`: `ghost`
  (windows keep drawing but stay invisible, click-through, and out of the Dock),
  `appearance:`, `frame:`, `scale:`, `caret:`, `palette:`, `complete`, `segment:`,
  `command:`, and `shot:<name>` (the main window with its sheet, palette, and popups composited
  into one PNG, web previews and terminals included).

### 2026-10-02 — MIT license and readme overview

- Runlet is licensed under the MIT License (`LICENSE`).
- The readme now opens with an overview, features, install instructions (including opening
  an ad-hoc signed build), and license notes, ahead of the existing development guide.

### 2026-10-02 — SSH profiles: directory validation, Detect, and Browse…

- Fixed: the SSH profile's Directory could look filled in while Save stayed disabled. The
  field was empty and showed its gray example (`/var/www/app`), which read like a value.
  The placeholder now says "Absolute path on the server", and the message says what is
  wrong: empty ("enter the application's folder… Detect and Browse… find it"), relative, or
  starting with `~` (Runlet doesn't expand `~` on the server). Every value is checked as it is
  saved (surrounding whitespace, a pasted newline, and a trailing `/` don't count), with unit
  tests for the validator.
- **Detect** next to Directory connects (BatchMode, through the shared connection) and runs
  a read-only PHP check: it fills an empty Directory with your home folder on the server
  (or replaces a leading `~`), and a popover lists the home folder first, then folders that
  look like PHP applications (`artisan`, `bin/console`, `wp-config.php`, `composer.json`,
  `.runlet`), with Forge's `current` symlinks kept. A wrong PHP still finds the home folder.
- **Browse…** opens a folder picker on the server: a path field (`~` works), breadcrumb,
  enclosing folder and home, double-click to enter, badges for PHP applications, symlinks
  shown and kept as chosen, hidden folders on request, and inline errors (permission
  denied, missing folder, not connected, unreachable host). Nothing is written.
- Password and 2FA profiles: Connect… from the profile sheet (or Detect's popover) no longer
  needs a savable profile. The sheet steps aside for the login in the terminal and reopens
  with your values once it succeeds.
- Tests: fixture tests for Detect and listing (home folder, symlinked `current`, a folder
  name with quotes, `$`, and backticks, permission denied, missing folders, files, relative
  paths, a missing PHP, and an unknown host key).

### 2026-10-02 — Output export: rows as JSON or PHP, Markdown, Save Output As…, links

- Table view: right-click a row for **Copy Row as JSON**, **Copy Row as PHP Array** (keys
  kept, types kept: numbers, booleans, null, nested arrays), Copy Row as CSV, and Copy Cell.
- Result and dump cards: next to Copy, a menu copies the value as JSON, PHP, or Markdown.
- **Copy Output as Markdown** (Run menu, command palette, and the output header's export
  menu): each card becomes a heading with its content in a fenced block, tabular values become
  Markdown tables, followed by the run inspector's queries and mail.
- **Run ▸ Save Output As…**: saves the output as Markdown (`.md`), plain text, or raw
  stdout/stderr (`.txt`), picked in the save panel.
- Web links (`http`, `https`, `mailto`, written with their scheme) in stdout/stderr cards and
  in the Plain and Raw transcripts are clickable and open in the default browser.

### 2026-10-02 — Run inspector in the output pane: queries, mail, logs, previews; mail interception setting

- The output pane gets a row of sections once a run reports any: **Output**, **Queries**,
  **Mail**, **Log**, and the driver's own sections (Cache, HTTP calls, …), each with its
  count. Clear Output clears them too.
- **Queries:** count, total time, and repeated statements at the top; each statement with
  its time (the slowest in orange), connection, the snippet line that ran it (click to go
  there), and the SQL with its bindings inlined for reading. Expand a row for the SQL with
  placeholders and the typed bindings. Copy SQL, Copy SQL with Bindings, Copy Bindings as
  JSON. Statements run again with the same bindings are flagged "identical"; a similar
  SELECT run 3 or more times with different bindings is flagged "N+1?" with an eager-loading
  hint, and the hint chips filter the list to that statement. Group Similar shows one row per
  statement shape. The finished line adds "N queries (x ms)".
- **Mail:** each message with its status (sent, intercepted, or queued), headers, mailable,
  mailer, attachments, and a preview. Mail also appears in the output stream as one line
  each ("Mail intercepted (not sent): “Welcome” to ada@example.com"), which opens the section.
- **Previews:** a returned or dumped mailable, mail notification, view, `Htmlable`, or HTML
  response shows its rendering first (Preview, Tree, Table). Previews use a `WKWebView` with
  JavaScript off, nothing loaded but `data:` URLs (blocked by a content rule list and a
  Content Security Policy; remote images can be allowed per preview), no navigation (clicked
  links open in the browser), with HTML, Text, and Source views and Open in Window.
- **Settings ▸ General ▸ Run Inspector:** Record queries, mail, and logs (on), **Intercept
  mail** (off by default, as `docs/next-release-ideas.md` N02 suggests: interception changes
  what a run does), and Preview returned mail, views, and HTML (on). Local projects, Docker
  profiles, and SSH profiles can override Intercept mail (Default / Intercept / Send). While it applies,
  the output header shows an orange "Intercepting Mail" chip, the run header says "mail
  intercepted", intercepted messages are marked in the output and the Mail section, and a
  warning appears when the project's driver can't intercept mail. Run ▸ Toggle Mail
  Interception, Show Queries, and Show Mail are in the command palette and remappable.
- Fixed: without a VarDumper (no `symfony/var-dumper` and no global dump tool), `dump()` and
  `dd()` reported line 1 instead of the line that called them: frames inside the runner's own
  evaluated fallback `dump()` counted as the snippet. Only code evaluated on the snippet's
  `eval()` line counts now.
- Debug builds: `RUNLET_DEBUG_STEPS` gains `project:<dir>`, `code:<file>`, `run`,
  `section:<name>`, and `intercept:on|off`.

### 2026-10-02 — Run inspector: driver API, queries without Laravel, mail and previews in the runner

- Drivers get a run inspector (`Runlet\Inspector`, in the new `Resources/Runner/src/Inspector.php`):
  a new `Driver::inspect(Inspector $inspector)` hook runs after `bootstrap()` and before the
  snippet (never when commands are listed) and reports SQL queries, mail, log messages, HTML,
  and sections of the driver's own (`record('Cache', 'hit users', $value)`). Snippets reach it
  through `Inspector::current()`. Its methods never throw; a throwing `inspect()` is a notice
  and the run continues. Documented in `docs/drivers.md` ("Run inspector").
- Queries are found without any driver code where possible: Laravel (the app's events),
  **Eloquent without Laravel** (Capsule, as in Slim or PHP-DI apps: live `QueryExecuted`
  events, adding a dispatcher for the run when the connections have none, or the query log
  without illuminate/events), WordPress (`$wpdb` with `SAVEQUERIES`), and Symfony's Doctrine
  connections. Drivers can call `inspectEloquent()`, `inspectDoctrine()` (DBAL 2, 3, and 4),
  and `inspectWordPress()` themselves, and `$inspector->watchPdo($pdo)` records a plain PDO
  connection's prepared statements. Each record carries the snippet line that caused it.
- Laravel's driver also records mail (`MessageSending`, with subject, addresses, HTML and text
  bodies, attachments), log messages, and mail pushed to an asynchronous queue. With mail
  interception requested, its `MessageSending` listener returns `false`: the message is built
  and recorded, never sent. Symfony Mailer is recorded too (and intercepted on 6.3+).
- Returned or dumped mailables, mail notifications, views, `Htmlable`/`Renderable` objects,
  and HTML Symfony responses carry a rendered HTML preview (`Driver::preview()`, overridable).
- Protocol: run requests carry `inspector` options (`enabled`, `interceptMail`, `previews`)
  and new limits (2,000 queries, 2,000 other records, 8 MiB of records, 2 MiB per body); new
  frames `inspector`, `record`, and `recordLimit`; `result` and `dump` gain `preview`. The app
  decodes them into `RunEvent.Kind.inspector` (`RunInspection`, `QueryAnalysis` with duplicate
  and N+1 hints) and drops records past the limits itself if a driver bypasses the runner's.
- Fixtures: `Tests/Fixtures/eloquent-app` (Capsule with illuminate/events and DBAL 3, PHP 7.4
  compatible) and `eloquent-app-modern` (illuminate/database 13 without events, DBAL 4),
  installed by `scripts/setup-fixtures.sh`.
### 2026-10-02 — `gitRevision()` driver helper

- `Runlet\Driver::gitRevision($projectPath)` returns `"main @ 3f2a1c9"` (or just the short
  commit for a detached HEAD). It reads the `.git` files directly, including packed refs and
  linked worktrees, and runs no `git` command, so it works well as `version()`, which tab
  cards, the status bar, and the Commands pane show. Documented in docs/drivers.md, with
  tests for each git layout.

### 2026-10-02 — Driver variables in the Commands pane

- The Commands pane header lists the driver's snippet variables (`variables()`) for the
  current target, each with its class, e.g. `$_app App`. Clicking one inserts it at the
  editor's cursor (undoable). The tooltip shows the full class.
- Loading commands now teaches completion the driver's variables too, not only runs.

### 2026-10-02 — Target environments and the production guard (N14, SSH-4)

- Every target (local projects, Docker profiles, SSH profiles) has an environment —
  development, staging, or production — and an optional colour, in the project options and
  both profile forms. Workspaces keep an SSH profile's environment.
- Production targets show a red PRODUCTION badge next to the target menu, on tab cards (with
  a red stripe) and horizontal tabs, in the target menu, ⌘P, and Settings ▸ Targets, and a
  red-tinted status bar. Staging gets an orange badge; a colour draws a stripe on tab cards
  and the status bar.
- Each run on a production target asks first, showing the target, where it runs, and the
  first 12 lines of the code or selection. ⌘↩ runs it; ↩ and Esc cancel. "Don't ask again
  for 10 minutes" covers snippet runs on that target only, lives in memory, and ends on
  quit or when the target is edited.
- Project commands on production always ask, every time: listing (it boots the app), each
  command, and host commands run for that target on this Mac.
- Stricter defaults: the Commands panel never lists a production target by itself, and
  Runlet doesn't look inside a production Docker container for tab facts (it reads the
  local source instead).

### 2026-10-02 — SSH: the local folder, suggestions, and drift (SSH-3)

- An SSH profile's local folder (its checkout on this Mac) powers the same features as a
  local project: PHPantom completion and diagnostics, framework and driver facts read from
  local files (no network), project snippets and Save Snippet to Project…, host commands,
  Open Project in Editor, and the terminal's start folder. Without one, the profile runs in
  limited mode and says why.
- File links in output map server paths to the local folder, from both the profile's
  directory and the real path PHP reports, so Forge-style `…/current` and
  `…/releases/<id>/` paths open the same local file.
- Folder suggestions for profiles without a local folder: folders Runlet knows plus a
  shallow scan of `~/Code`, `~/Projects`, `~/Sites`, `~/Herd`, and similar, matched by the
  server's git remote, `composer.json` name (both after Test Connection), or folder name
  (including Forge site folders). Offered above the editor ("Use for Completion") and in
  the profile; never applied on its own.
- Optional drift warning (off by default): after Connect…, Test Connection, and the first
  run of a session, Runlet compares the local folder's branch and commit (or
  `composer.lock`, for deployments without `.git`) with the server's, read by the same
  read-only PHP check (no `git` runs on the server), and shows a yellow banner when they
  differ. It never blocks a run.
- Test Connection also reports the server checkout's git remote, branch, commit, and a
  `composer.lock` CRC-32.

### 2026-10-02 — SSH: Connect… and Disconnect for passwords and 2FA (SSH-2)

- SSH profiles that log in with a password, keyboard-interactive answers, a one-time code,
  or a key passphrase no agent holds use **Connect…**: a terminal tab runs
  `ssh -M -N -f` with Runlet's control socket, and OpenSSH asks its own questions there.
  Runlet never reads, stores, or logs what you type. Once logged in, ssh moves to the
  background, the tab closes, and runs reuse the login without prompts.
- The login stays until **Disconnect** (`ssh -O exit`; asks first when runs are in
  progress). Quitting Runlet doesn't end it, and Runlet finds it again after a restart.
  When the network drops it shows "Login ended" and the next run asks to Connect again.
- Status (Connected, Not connected, Login ended) is read from the control socket on this Mac,
  so checking never starts `ssh` or contacts the server. It shows in the status bar, the
  target menu, and the profile; a banner above the editor offers Connect… when a
  password profile isn't connected, while a login is in progress, and after a run failed
  for a reason Connect… fixes.
- Unknown host keys: Connect… forces OpenSSH's fingerprint question
  (`StrictHostKeyChecking=ask`, whatever `~/.ssh/config` says), so a key is only ever added
  by your answer. Runs still refuse unknown keys.
- New commands: Connect to SSH Host… and Disconnect from SSH Host (Library menu and the
  command palette). The profile sheet saves and closes before Connect… so you can type in
  the terminal. Debug step runner: `connect:<profile>`, `disconnect:<profile>`,
  `select:<tab>`, and `run`.

### 2026-10-02 — SSH targets: run snippets on a server (SSH-1)

- New target kind: **SSH hosts**. Library ▸ New SSH Profile… (also in the target menu,
  the command palette, and Settings ▸ Targets) saves a host (a `~/.ssh/config` alias or a
  host name, with optional user, port, and jump-host overrides), the application's
  directory on the server, the server's PHP, and an optional local folder. Tabs, ⌘P, the
  target menu, tab cards ("SSH" chip, `user@host:directory`), the status bar, workspaces,
  and history know them. Saving or opening a profile never connects.
- Runs use the system `/usr/bin/ssh`, so `~/.ssh/config` (aliases, `ProxyJump`,
  `IdentityAgent`, `Include`), ssh-agent, the 1Password agent, key files, `known_hosts`, and
  `UseKeychain` work as in Terminal. Runlet stores no keys or passwords. The runner is
  streamed to the server's PHP on stdin (nothing is written on the server), with
  `BatchMode=yes`, `StrictHostKeyChecking=yes` (never accepts an unknown host key), short
  connect and keep-alive timeouts, `LogLevel=ERROR` (no login banner in the output), and
  compression. Output, dumps, `dd`, `exit`, fatals, and limits behave as in local runs.
- One shared OpenSSH connection (ControlMaster) per profile serves runs, Stop, and Test
  Connection: agent and key profiles open it on the first run and keep it for 10 minutes
  (configurable, or until Disconnect). Sockets live in `Application Support/Runlet/SSH`.
- Stop on a server signals the runner and everything the snippet started (every process
  carrying the run's `RUNLET_RUN_ID`), after checking `/proc`, with Docker's
  SIGTERM/SIGKILL timing. Servers without `/proc` are left alone and the stop is reported
  as unconfirmed.
- `ssh` failures are explained in plain words (unknown or changed host key, rejected keys,
  unresolvable or unreachable host, lost connection, missing directory, PHP not found),
  with OpenSSH's own message kept below.
- Test Connection runs one read-only `php -r` on the server: PHP version and binary, user,
  OS, the directory and its real path (Forge's `current`), framework, tokenizer, Stop
  support, round-trip time, and the application folders and PHP binaries it finds.
- The Commands panel never lists an SSH host's commands by itself ("List Commands on
  <host>"); host commands run on this Mac in the local folder. Running server-side commands
  from the panel comes later.
- Tests: a disposable `runlet-fixtures` service `ssh` (OpenSSH + PHP 8.4, `127.0.0.1:2222`
  only) that the SSH tests start when needed, with a throwaway key, their own `ssh -F`
  config and `known_hosts`, and no agent. They cover runs, dumps, `dd`, exit, fatals,
  quoting, Stop with children, concurrent runs, a dead link, unknown host keys, rejected
  logins, and Test Connection. Debug builds read `RUNLET_SSH_CONFIG` instead of
  `~/.ssh/config`, and `RUNLET_DEBUG_STEPS` gained `ssh:new`/`ssh:<name>`.
- Docs: new [docs/ssh.md](docs/ssh.md); architecture and drivers updated.

### 2026-10-02 — The `runlet` command-line tool

- `runlet` opens things in Runlet from a terminal: `runlet` or `runlet .` opens the current
  folder as a local project, `runlet <folder>` another folder, `runlet <file.php>` a file
  (saving writes back to it), and `runlet <name.runlet>` a workspace. `-t/--target` opens
  files (or, alone, a new tab) on `sandbox`, a project, or a Docker profile, by name or
  folder; `-n/--new-window` opens a new window. Folders reuse an already saved project and a
  blank current tab. Nothing runs. See [docs/cli.md](docs/cli.md).
- Runlet ▸ Install Command-Line Tool… (also Settings ▸ General ▸ Command-Line Tool and the
  Command Palette) creates one symbolic link to the tool in a folder you pick:
  `/usr/local/bin` (macOS asks for an administrator password when needed), `~/.local/bin`
  (with a note when it isn't on your shell's `PATH`), or another folder. It shows the exact
  link first, never replaces a file that isn't Runlet's link, and replaces a link to another
  copy of Runlet only on Replace. Remove Link deletes it.
- The tool talks to the running Runlet with a distributed notification and waits for its
  answer, so it prints what couldn't be opened (an unknown target, an unreadable file) and
  exits with a status. When Runlet isn't running, it starts it through Launch Services.
- A folder dropped on Runlet's Dock icon (or `open -a Runlet <folder>`) now opens as a
  project too.
- The tool is the new `RunletCLI` target, copied into `Contents/Helpers/runlet`;
  `scripts/package.sh` checks it (universal, `--version`), and so does
  `Runlet --self-test`.

### 2026-10-02 — Float on Top, recent projects in the Dock

- Window ▸ Float on Top keeps the current window above other apps' windows, for example
  next to a browser while you try things. It is per window, has a checkmark in the menu,
  shows "On" in the Command Palette, can get a shortcut in Settings ▸ Shortcuts, and lasts
  until you turn it off or quit.
- The Dock icon's menu lists recently used projects: local projects and Docker profiles,
  most recent first. Choosing one opens it in the current tab when that tab is blank, or in
  a new tab. Nothing runs.
- Commands can now be on/off items (`AppCommand.isChecked`), shown with a checkmark.

### 2026-10-02 — Tabs follow their files on disk

- A tab opened from a file now notices when another app changes, replaces (an atomic save,
  as editors and `git` do), deletes, or restores that file. Contents are compared, so a
  `touch` or Runlet's own save changes nothing.
  - No unsaved edits: the tab reloads silently, keeping the caret and scroll position
    (⌘Z brings the previous code back).
  - Unsaved edits: a banner offers Reload or Keep Mine. Keep Mine keeps the tab's code, and
    the next ⌘S replaces the file without asking again.
  - The file is gone: a banner says so; the code stays, the tab counts as unsaved, and Save
    writes it back.
  - A file tab restored from the last session whose file now differs gets the Reload /
    Keep Mine banner, since unsaved edits and a change made while Runlet was closed look
    the same.
- ⌘S never silently replaces a file that changed on disk: it asks first (Save Anyway /
  Cancel). Cancelling no longer opens a Save As panel for a tab that has a file.
- File ▸ Reload from Disk (also in the palette) shows the file's version in the current tab.
- Opened and saved PHP files are now added to the recent documents, so Open Anything (⌘P)
  lists them under Recent; before, only workspaces were.
- Files are checked again whenever Runlet becomes active, in case an event was missed.
  Nothing is ever written or run without the user.

### 2026-10-02 — Keyboard-first History and Snippets, history in ⌘P

- Show History (⌘Y) and Show Snippets (⇧⌘L) now put the keyboard in the pane's search
  field, with its text selected. While typing, the best match is selected, ↑ and ↓ move the
  selection, ↩ opens it where Settings ▸ General says (like double-click), ⌘↩ opens it in a
  new tab, and ⇧↩ inserts it at the cursor (without its `<?php` tag). After opening, the
  editor gets the keyboard. Esc clears the search, and a second esc goes back to the editor.
- In the list itself (Tab from the search field, or a click), ↩ opens, ⌘↩ and ⇧↩ work the
  same way, ⌫ deletes (History at once; personal snippets after asking) and selects the
  next row, and typing a letter continues the search.
- Open Anything (⌘P) searches History behind a `!` prefix: runs on the current tab's
  target come first, the code itself is searched, and ↩ / ⌘↩ open an entry like the History
  pane does. Nothing runs.
- `LibraryKeyboardUITests` covers these keys, `!` in ⌘P, and a file tab following its file.
  It compiles with the suite but hasn't been run yet (the UI suite takes over the keyboard).
- Debug builds: `RUNLET_DEBUG_STEPS` gains `perform:<command>`, `key:<keys>`, `type:<text>`,
  `state` (focus and tabs), `open:<path>`, and file steps (`write`, `replace`, `remove`), in
  `DebugSteps.swift`. Key events are queued like real ones.

### 2026-10-02 — Docs: next-release ideas and SSH design

- `docs/next-release-ideas.md`: a prioritized list of post-0.0.1 ideas from a full review of
  Tinkerwell's v5 docs and changelog, with a Tinkerwell→Runlet gap table, ideas grouped by
  theme (each with behaviour, fit in Runlet's code, size, safety notes, and priority), what
  to skip, and sources. Includes a detailed SSH targets design: system `ssh` with
  ControlMaster, password/2FA through a terminal login, an optional remote `docker exec`
  step, a local project folder per host, production guard rails, and milestones.

## 0.0.1 — 2026-10-02

First public build (ad-hoc signed, universal arm64 + x86_64).

### 2026-10-02 — Editor/output split is remembered

- The divider between the editor and the output pane keeps its position across launches,
  saved separately for output on the right and output below
  (`editorSplitRight`/`editorSplitBottom`, the editor's share). SwiftUI's split views
  couldn't restore a position, so the panes use Runlet's own `PaneSplit`. It has a
  draggable divider, keeps the same minimum sizes, and saves the position when a drag ends.

### 2026-10-02 — ⌘W closes an open palette

- With the command palette open, Close Tab (⌘W) and Close Window (⇧⌘W) now close the palette,
  like a popover, instead of acting on the window behind it.

### 2026-10-02 — Command palette: click outside to close, ⌘P / ⇧⌘P switch modes, better matches

- Open Anything (⌘P) and the Command Palette (⇧⌘P) float over the window in a panel instead
  of a sheet. A click anywhere outside closes the palette, and the click goes no further
  (like a popover's), so it can't also close a tab or press Run. Esc still closes it, and so
  does switching to another window or app.
- While the palette is open, the Command Palette shortcut switches it to commands and the
  Open Anything shortcut switches it back, keeping the typed text (minus a `/`, `@`, or `#`
  prefix). The shortcut of the mode already showing closes it. Both go through the menu
  commands, so remapped shortcuts work.
- Command mode is no longer a `>` in the search field. ⇧⌘P used to open with that `>`
  selected, so the first key typed replaced it and the palette silently switched to Open
  Anything. A "Commands" chip beside the field now shows the mode, the search starts empty,
  and the caret sits after the text with nothing selected, also after a mode switch. Typing
  `>` first in Open Anything still switches to commands (the `>` is consumed), and ⌫ in an
  empty command search goes back.
- Fixed rows showing another result's content: typing `>dock` listed four rows titled New
  Window, New Tab, Duplicate Tab, and Open…, because rows were identified by position. Rows
  now follow their item, and ↩ runs the highlighted row, so Manage Docker Profiles… opens
  from the palette again.
- Better matching, here and in Settings ▸ Shortcuts. Each word of the query must match on
  its own. Titles match by prefix, word start, substring, or pieces that start successive
  words (`vt` → Toggle Vertical Tabs, `mdp` → Manage Docker Profiles…), and rank first.
  Subtitles and keywords match only at a word start or as a substring, no longer as letters
  scattered across unrelated words. `dock` now lists New Docker Profile… and Manage Docker
  Profiles… first and no longer matches New Window.
- Debug builds: `RUNLET_DEBUG_PALETTE=anything|commands` drives the palette at launch with
  key and mouse events sent only to Runlet, through the menus' own shortcuts. It opens,
  types, switches modes, closes, and clicks outside, logging each step to stderr and taking
  snapshots when `RUNLET_SNAPSHOT_DIR` is set, then quits. Use it with `RUNLET_DATA_DIR`;
  it needs Runlet to stay frontmost while it runs.

### 2026-10-02 — Focus stays in Runlet after closing Settings or Docker Profiles

- Closing Settings, the Docker Profiles window, or any other Runlet window could hand
  focus to another app. macOS activates the next window on screen, which was another
  app's whenever one sat between the closing window and Runlet's main window. Runlet now
  makes its frontmost remaining window key just before the window closes. Sheets and
  alerts are left to AppKit.
- Debug step runner: added `activate`, `settings`, `profiles`, `close`, and `report`
  (activation plus key and main windows), used to reproduce this.

### 2026-10-02 — No duplicate History entries

- Running code that is already in History, on the same target, moves that entry to the
  top with the latest status, time, and duration instead of adding a copy. Leading and
  trailing whitespace is ignored when comparing code. The same code on another target stays
  a separate entry.
- Existing duplicates are collapsed when History loads, keeping the newest of each.

### 2026-10-02 — Clearer launch failures for Docker profiles

- When `docker exec` cannot start PHP, its own message (printed on stdout, exit code 127)
  now becomes the error, in runs and in the Commands pane, instead of only "exited with
  code 127". Two cases get a plain-language explanation first:
  - "chdir to cwd" means the working directory doesn't exist in this container, so the
    profile probably points at the wrong container or directory;
  - "executable file not found" means PHP isn't on that path.

### 2026-10-02 — Where History and Snippets entries open

- New setting, Settings ▸ General ▸ History & Snippets ▸ "Double-click opens in", for
  double-click and Return in the History and Snippets panes:
  - **This tab if it's empty and on the same target, else a new tab** (the default). A blank
    tab (no file, not running, nothing but `<?php`) takes the code, and an automatic
    "Tab N" title becomes the entry's name. Snippets saved for any target fit every tab.
  - **Always a new tab** (the previous behavior).
  - **Always the current tab.** It replaces the code (⌘Z undoes it) and switches the tab
    to the entry's target. A running tab gets a new tab instead.
- Opening still only loads code; nothing runs until you press Run. The explicit "Load in
  Current Tab" and "Open in New Tab" buttons are unchanged, and the panes' hints describe
  the chosen behavior.

### 2026-10-02 — Fix: crash when opening the History & Snippets panel

- Opening the panel could crash intermittently, mostly with vertical tabs: AppKit threw
  "more Update Constraints in Window passes than there are views in the window". SwiftUI's
  `.inspector` split view re-sent the window toolbar items on every layout pass while
  opening. The panel is now a plain resizable trailing column. Its width is remembered
  (`libraryPanelWidth`, 260–480 pt), and it never animates, so the toolbar stays put.
  Replaying the reporter's saved layout used to crash in 1–2 of every 6 runs; it ran clean
  18 times with the fix.
- The Commands pane no longer requires 300 pt, which was more than the panel's 260 pt
  minimum.
- Debug builds: `RUNLET_DEBUG_STEPS` replays UI steps at launch, then quits. Steps are
  `inspector:<pane>|off`, `tabs:vertical|horizontal`, `snapshot`, and `wait`, run 1.5 s
  apart. `RUNLET_DEBUG_INSPECTOR=<pane>` is shorthand for `inspector:<pane>,snapshot`. Use
  them with `RUNLET_DATA_DIR` (scratch data) and `RUNLET_SNAPSHOT_DIR` to reproduce layout
  bugs without UI scripting.

### 2026-10-02 — History by project; Commands pane polish

- The History pane has **This Project / All Projects** sub-tabs. It shows only the current
  tab's project by default. The empty state offers "Show All Projects", and the footer counts
  both scopes.
- The Commands pane lists each unlisted target by itself while the pane is visible,
  including after you switch to a new tab or project; no manual Refresh is needed. Failed
  listings are not retried automatically. The pane now stays pinned to the top of a tall
  inspector.

### 2026-10-02 — Host commands (biker and other host CLIs)

- New driver hook, `hostCommands()`. It declares commands that run **on the Mac** in the
  project's folder (for Docker profiles, the profile's local source folder) instead of
  inside the target. An entry is one of:
  - a static command (`'up' => 'docker compose up -d'`);
  - a list source that prints Runlet's command JSON (`'biker' => ['list' => 'biker
    runlet:commands']`);
  - a Symfony Console app (`'tool' => ['console' => 'tool']`), read through
    `tool list --format=json`.
- Sources are listed each time the Commands pane loads or refreshes. They run with the
  user's login-shell environment, resolved once with `$SHELL -i -l -c env`, so `~/.bin`,
  Homebrew, and Herd tools are found. Output around the JSON is ignored, and console style
  tags are stripped.
- The runner reports host commands before `bootstrap()`, and the app remembers each
  target's declaration in `State/facts.json`. Host commands therefore stay available when
  the app can't boot or the container is stopped (`biker start`). Running a host command
  never resolves a container.
- Commands can set `needsInput` (required arguments). Run then types the command without
  pressing Return: in the user's shell, or in an interactive `sh -l` inside the container.
  `consoleCommands()` sets it for Artisan or console commands with required arguments.
- Host commands show a laptop marker in the Commands pane, and failing sources show their
  error above the list.

### 2026-10-02 — Terminal commands wait for the shell; command tabs stay open

- Commands opened in a terminal tab (project commands) are typed only once the shell
  reports its first prompt, never into a question an rc file asks while it loads (e.g.
  dotenv's "Source it? ([y]es/[N]o…)", which used to swallow the first character and leave
  `quote>`). zsh gets a temporary `ZDOTDIR` whose startup files source yours unchanged
  (your `ZDOTDIR`, history file, and options are restored) plus a one-shot `precmd` hook;
  bash a `--rcfile` that reads the login profile files plus a one-shot `PROMPT_COMMAND`;
  fish a one-shot `fish_prompt` handler. The hook writes a private escape sequence that
  Runlet consumes; nothing is printed during startup and plain shell tabs are unchanged.
- If the shell hasn't reported after 15 s, a bar above the terminal offers Run Now /
  Don't Run instead of typing blindly; answering the shell's question later still runs it.
  Other shells keep the output heuristic (zsh and fish are no longer typed into after a
  timeout).
- Command tabs (including `docker exec … sh -lc <cmd>` for Docker targets) stay open after
  the command exits: `— Process exited with code N —` (red when non-zero), a check or
  warning mark on the tab, and Run Again / Close above the terminal (Run Again also in the
  tab's context menu). Return closes a finished command tab. Plain and container shells
  still close when they exit cleanly.
- ⌘W (Close Tab, or your remapped shortcut) closes the focused terminal tab when the
  terminal has keyboard focus, asking first only while a program is running; closing the
  last one hides the panel and returns focus to the editor. Elsewhere ⌘W closes the editor
  tab as before.
- 19 new package tests: marker scanning across chunk boundaries, launch arguments and
  environment per shell, script installation, and live zsh/bash/fish sessions under
  `script(1)` with temporary dotfiles (an rc-file `read -q` holds the marker back until
  answered; `ZDOTDIR`, `PROMPT_COMMAND`, and helper names are cleaned up).

### 2026-10-02 — Docker profile manager window

- Library ▸ **Manage Docker Profiles…** (also in ⇧⌘P, the toolbar target menu, and
  Settings ▸ Targets; no default shortcut, assign one in Settings ▸ Shortcuts) opens one
  window for all Docker profiles: the profile list on the right (search, running/not
  running dot, container, local source folder, tabs using it) with + / − and Duplicate /
  Use in Current Tab; the left side is the same editor as the profile sheet.
- Edits stay a draft until Save (↩ or ⌘S); Revert restores the saved values. Switching
  profiles, adding one, or closing the window with unsaved changes asks Save / Don't Save /
  Cancel. Deleting uses the usual confirmation, and tabs using the profile switch to the
  sandbox as before. The single-profile sheet is unchanged.

### 2026-10-02 — Project commands pane

- History & Snippets panel gains a **Commands** pane (⇧⌘K, also in the palette): every
  Artisan / Symfony console command, Composer scripts, and `.runlet` driver `commands()`,
  searchable and grouped; ▶ runs one in a terminal tab (local, or `docker exec` into the
  resolved container). Commands load only when the pane is shown or on Refresh.

### 2026-10-02 — Tab cards complete without a run

- Targets are inspected without running project code: framework/driver and versions
  from files (`.runlet/*Driver.php` name/version literals, Laravel/Symfony version
  constants in vendor, WordPress `version.php`), and a Docker container's PHP version via
  `php -n -r 'echo PHP_VERSION;'` (php.ini disabled; nothing from the project runs).
- Detected facts and driver variables persist across launches (`State/facts.json`); a
  real run still refines them.

### 2026-10-02 — Managing targets

- Delete a Docker profile or remove a local project from the target menu
  ("Delete “name”…"), the command palette ("Delete Current Target…"), or the new
  Settings ▸ Targets tab (Edit/Delete for every saved target). Only Runlet's entry is
  removed; folders and containers are untouched, and affected tabs keep their code.
- Wired project snippets into ⌘P (`#`), and added "Save Snippet to Project…" and
  "Toggle Strict Types" commands.

### 2026-10-02 — Accurate completion for Docker profiles

- Local source for completion is detected from the container's bind mount: the Docker
  profile editor fills it in when a container is picked, and existing profiles without
  one get a "Use for Completion" banner (explicit click).
- Limited workspaces (no local source) no longer show false "class/function not found"
  warnings; syntax errors still show.
- Diagnostics on Runlet's hidden lines (synthetic `<?php`, `@var` declarations for driver
  variables) are dropped instead of appearing on line 1; errors at the hidden trailing
  `;` move to the end of the last line.
### 2026-10-02 — Tab card chips stay inside the card

- Vertical tabs: a chip wider than the card (a long framework or `.runlet` driver name)
  now truncates with "…" at every sidebar width instead of running past the card's right
  edge. `FlowLayout` proposes the row width to a subview that doesn't fit and never places
  it wider than the row; the chip's icon stays visible while its text shrinks.
- The driver chip no longer repeats itself: when the reported "version" is really a name
  that matches the driver ("Hellorider Lease API" / "Hellorider Lease-API"), only the
  driver name is shown. Real versions still show ("Laravel 13.34"); the tooltip keeps both.
- The second line of a Docker tab shows the profile name, adding `project/service` (or the
  container name) only when it says something new: `microservice`, not
  `microservice · hellorider-lease-api/microservice`. Hover shows the full identity.

### 2026-10-02 — Command palette, Open Anything, custom shortcuts, tab commands

- Command registry (`Runlet/App/Commands.swift`): every action has an id, title,
  category, default shortcut, and enabled state; menus, palettes, toolbar help, and
  Settings ▸ Shortcuts are built from it.
- ⇧⌘P Command Palette (fuzzy, shows shortcuts, ↩ runs) and ⌘P Open Anything (targets,
  snippets, recent files; `>` commands, `/` projects, `@` Docker, `#` snippets; ⌘↩ opens
  in a new tab; never runs code). Replaces the target switcher.
- Settings ▸ Shortcuts: record, clear, reset, Reset All, conflict warnings; overrides
  are saved in settings and update menus immediately.
- Tabs: ⇧⌘T reopens closed tabs (with their code), Close Tabs to the Right, ⌘1–⌘8 /
  ⌘9 (last), Rename Tab command. Output: show/hide pane (⌃⌘O), move right/below (⌃.),
  Structured/Plain/Raw (⌃⌘1–3). History & Snippets panel toggle (⌥⌘L).
### 2026-10-02 — Strict types and project snippets

- Strict types (B07): Settings ▸ General ▸ Running ▸ "Declare strict_types=1 for every
  run" (default off), with a Default / On / Off override in Project Options and in the
  Docker profile editor. The runner inserts `declare(strict_types=1);` on the opening
  tag's line, so line numbers and parse-error columns don't change; code that declares
  strict_types itself (either value) is left alone. Applies to full and selection runs on
  local, Docker, and sandbox targets; the output header shows `strict_types=1` when on.
  `RunRequest.strictTypes` carries it to the runner (`"strictTypes": true`).
- Project snippets (B05): `<project>/.runlet/snippets/*.php` (a local project's folder or a
  Docker profile's local source) with `@label` and `@description` in the first docblock,
  Tinkerwell-compatible. The Snippets panel shows a read-only "Project snippets — <name>"
  section for the active tab's target with Open in Current/New Tab, Copy Code, Copy to
  Personal Snippets, Reveal in Finder, and a reload button. Save Snippet can write to
  "Project (.runlet/snippets)" and asks before replacing a file. Nothing in
  `.runlet/snippets/` is loaded as a driver or run. See docs/project-snippets.md.
- 27 new package tests (strict types locally, on PHP 7.4, and in Docker; snippet parsing,
  loading, and writing; the snippets folder is ignored by driver discovery).
### 2026-10-02 — Editor typography, soft wrap, and open in external editor

- Settings ▸ Editor: font family (installed fixed-pitch fonts, including ones such as
  JetBrains Mono and Hack that don't set the monospace trait; default System
  Monospaced, falling back to it when a chosen font is missing), line height 1.0–2.0
  with a live highlighted preview, ligatures on/off, and soft wrap. Editors re-apply
  the settings in place, so undo, selection, and scroll position survive.
- Ligatures: programming fonts draw them through contextual alternates (`calt`), which
  the `.ligature` attribute doesn't control, so "off" also disables `calt` and common
  ligatures for the editor font. Verified with Fira Code, JetBrains Mono, and Iosevka.
- Soft wrap wraps to the visible width (the macOS 26 clip view extends under the ruler,
  so its content insets are subtracted), hides the horizontal scroller, never splits an
  operator such as `->` or `=>` across rows, and follows window resizes. The line-number
  ruler numbers logical lines, drawing each number (and diagnostic marker) on a line's
  first row, including when the view is scrolled into the middle of a wrapped line;
  numbers now sit on the text baseline at every line height.
- Open in external editor: Settings ▸ Editor ▸ External Editor offers the installed
  editors among PhpStorm, VS Code (also Insiders, VSCodium), Cursor, Zed (also Preview),
  Sublime Text, and TextMate, plus a custom command (`{file}`, `{line}`; split into
  arguments and launched without a shell), with a Test button that opens the current
  project. Files open at their line through each editor's URL scheme
  (`phpstorm://open?file=…&line=…`, `vscode://file/…:line`, `zed://file/…:line`,
  `subl://open?url=…`, `txmt://open?url=…`) when the app registers it, else its bundled
  command-line tool; folders open with the app.
- Output: file paths outside the snippet in dump cards, error cards, and stack-trace
  frames are links that open at their line (or reveal in Finder when no editor is set),
  with Reveal in Finder and Copy Path in their context menus. Docker paths map from the
  profile's working directory to its local source folder (Docker-sandbox paths to the
  installed sandbox); unmappable or missing paths stay plain text with the reason in the
  tooltip. Snippet-line links still go to the editor.
- `AppModel.toggleSoftWrap()` and `AppModel.openProjectInEditor(for:)` for the Wrap Lines
  and Open Project in Editor commands.
- Package: `RunletCore/EditorLinks.swift` (`ExternalEditor`, URL and CLI-argument
  builders, custom-command splitting, `EditorPathMapping`) with 16 tests.
### 2026-10-02 — Project commands

- Commands panel (`ProjectCommandsView`): lists every command the active tab's target
  offers (all visible Artisan commands for Laravel/Lumen/Laravel Zero, `bin/console`
  commands for Symfony, a `.runlet` project driver's own commands, and Composer scripts),
  searchable and grouped by namespace, with a Run button (▶) that opens the command in a
  terminal tab: the project directory for local and sandbox targets (with the target's
  PHP), `docker exec -it … sh -lc` into the profile's resolved container for Docker. Without
  a terminal panel the command is copied instead.
- Listing boots the application like a run, so it happens only when the panel opens for a
  target that was never listed, or on Refresh; results are cached per target. Composer
  scripts are read before any project code runs and stay listed if the app cannot boot.
- Driver API: `Runlet\Driver::commands()` (name-keyed `command`/`description`/`group`
  entries, or a command-line string), plus `consoleCommands()` for Symfony Console apps.
  Project drivers extend the built-in lists with `parent::commands() + [...]`.
- Runner protocol: request `mode: "commands"` and `commands` events (see docs/drivers.md);
  `ExecutionEngine.listCommands(target:)` returns a `ProjectCommandCatalog`.
- 22 new tests (Laravel, Symfony, Laravel Zero stub, custom and extending project
  drivers, Composer scripts, failures, timeout and cancel, terminal requests, Docker
  `custom`/`laravel`/`restricted` services, PHP 7.4).
### 2026-10-02 — Terminal panel

- Integrated terminal: a bottom panel per window with its own tabs (toolbar button,
  "+" for a new shell, × to close, chevron to hide), resizable by its top edge; height
  and shown/hidden state are remembered. Sessions live only while Runlet runs.
- Runs your own shell, untouched: the account's login shell (`-zsh`, `-bash`, …) with your
  profile and rc files, in the selected tab's project / sandbox / Docker source directory.
  Runlet adds only `TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM=Runlet`, and
  `LANG` when missing; no prompt or rc changes.
- Docker targets: "+" menu ▸ Shell in <profile> Container (`docker exec -it`, bash if
  available, else sh), resolving the container like a run — never a different one silently.
- Tab titles follow the program's title (OSC); closing asks only while a program other
  than the shell is in the foreground; closing a window or quitting hangs up its shells.
- Light/dark colors follow the app appearance, editor font size, 10,000 lines of
  scrollback, copy/paste and mouse selection; optional Option-as-Meta in the "+" menu.
- `AppModel.openTerminal` (`TerminalRequest`) lets features open terminal tabs that run a
  command in the user's shell or a direct argv; `toggleTerminal()` / `newTerminal()` for
  menu commands.
- Uses SwiftTerm 1.11.2 (MIT; license bundled). 8 new package tests for shell/environment
  resolution.

### 2026-10-02 — Completion popup and CPU fixes

- Fixed a feedback loop that made the completion footer flicker and kept Runlet and
  PHPantom busy (high CPU): resolving an item re-announced the selection, which
  resolved it again, indefinitely. Items now resolve once, only on real selection changes.
- Completion rows are single-line with tail truncation (no clipped second line), the
  popup sizes to its content (320–680 pt), and the selected row uses white text.
- Document sync to PHPantom is coalesced (~120 ms) while typing and flushed before
  completion, hover, and signature-help requests.
- Docs: Tinkerwell feature review (docs/tinkerwell-feature-review.md).

### 2026-10-02 — Framework drivers

- Runner auto-detects the driver per run: project drivers in `.runlet/*Driver.php`
  (read from disk, so a globally git-ignored `.runlet/` works), then Laravel / Lumen /
  Laravel Zero, WordPress (classic, Bedrock, `public/wp`), Symfony, Composer, plain PHP.
- Runlet driver API: `Runlet\Driver` (`name`, `canBootstrap`, `bootstrap`, `variables`,
  `version`) and extendable built-ins `Runlet\Drivers\{Laravel,WordPress,Symfony,
  Composer,Plain}Driver`. Injected variables (`$app`, `$wpdb`, `$kernel`/`$container`,
  project-defined) reach the snippet and, after a run, completion. See docs/drivers.md.
- WordPress boots like WP-CLI (globals preserved), with `wp_die` as an exception, no
  recovery-mode emails, no spawned WP-Cron; Symfony loads `.env` and boots the kernel.
- Docker profile probe recognises `.runlet` drivers, WordPress, and Symfony.
- 21 new driver tests (custom driver locally and in Docker, ordering, failures,
  WordPress on SQLite, Symfony, Lumen/Laravel Zero); 112 package tests passing.

### 2026-10-02 — Vertical tabs and driver variables in completion

- Tabs can be horizontal or vertical (Settings ▸ General, View ▸ Vertical Tabs ⌃⌘T,
  toolbar); the choice persists. Vertical tabs are cards showing the target, runtime
  (Docker / Local / Sandbox), PHP version, framework or `.runlet` driver and version,
  run status; drag to reorder, double-click to rename.
- Variables a driver injects (e.g. `$app`, a project driver's `$_app`) are declared to
  PHPantom as hidden `@var` lines after a run, so they complete in tagless snippets.
- The status bar shows the driver name; the Output header compacts on narrow panes.
- Vertical tab sidebar is compact by default (~190 pt), resizable by dragging its edge
  (140–420 pt), and remembers its width; cards use two short chips (runtime + PHP,
  framework/driver) with full versions in tooltips.

### 2026-10-02 — Windows and workspaces

- Multiple windows, each with its own tabs (⌘N); all windows and tabs are restored on
  relaunch without running anything. Closing the last window keeps Runlet running.
- `.runlet` workspace files: Save Workspace As… (⌥⇧⌘S), Open… (⌘O, also Finder/CLI).
  Workspaces embed their targets (local projects with relative paths, Docker profile
  definitions without machine-specific container IDs); on open, existing targets are
  matched and missing ones are added only after confirmation.
- Workspace windows behave like documents: edited dot, ⌘S saves, closing asks; closing
  an untitled window with unsaved scratch code asks too.
- Session format now stores windows; older single-window sessions still load.

### 2026-10-02 — Packaging, target switcher, fixes

- `scripts/package.sh`: universal Release build, verification, zip + DMG; packaged
  `Runlet --self-test [--docker]` passes natively and under Rosetta.
- ⌘P Switch Target palette (search sandbox, projects, Docker profiles).
- `Runlet file.php` / Finder opens files in tabs; the main window now appears on
  document launches; saving never executes code.
- Fixed: Docker sandbox Stop pressed before the container existed was lost (now
  `--init`, retried `docker kill`, `rm -f` fallback); container listing failed when a
  container vanished between `ps` and `inspect`. Found by new sandbox/recreation tests
  (real Compose `--force-recreate`, Docker sandbox without host PHP, sandbox reset).

### 2026-10-02 — Native app (milestones 1–4, in progress)

- Native macOS app (SwiftUI + AppKit): persistent per-tab AppKit editors with PHP
  highlighting, line numbers, auto-indent, bracket pairing, comment toggle, find bar;
  Writing Tools and smart substitutions disabled for code.
- Tabs (new/rename/duplicate/close/close others), target menu (sandbox, local projects,
  Docker profiles), Run / Run Selection / Stop, status bar with elapsed time, PHP and
  framework versions, and PHPantom state.
- Output pane: ordered stdout/stderr, dump cards with line links, expandable value
  trees, error cards with stage, line/column navigation and stack traces.
- PHPantom in the editor: completion popup (with `use` import edits), hover, signature
  help, diagnostics underlines and gutter markers. Tagless snippets get a hidden `<?php`
  line and a trailing `;` for the language service only.
- Docker profile editor (container discovery, Compose identity, working-directory
  suggestions, probe), settings (appearance, editor, PHP, Docker, sandbox), history and
  snippets inspector, explicit container choice after recreation/ambiguity.
- Runs prefer the user's default `php` on PATH and avoid prerelease PHP builds.
- Output display modes like Tinkerwell's: Structured (cards + expandable trees), Plain
  (CLI-style transcript), Raw (exact stdout/stderr bytes); value expansion preference
  (collapsed / first level / all); Table view for tabular values (arrays of rows,
  collections, Eloquent model lists) with sorting, filtering, Copy/Export CSV.
- Sandbox runtime preference: Automatic / Local PHP / Docker.
- Seeded scenario UI tests: many applications in tabs, Docker profiles (restricted
  container, Stop keeps the container running), sandbox in Docker, output modes and
  table, history/snippet persistence without execution.
- Stop before launch now ends as `cancelled`; selection errors map columns too.
- XCUITest suite driving the real app (6 passing): sandbox run, error mapping and
  recovery, Run Selection, Stop, restart restoration without execution, completion.
  Automatic test screen recordings are disabled.

### 2026-10-02 — Execution engine (milestones 0–1, 3)

- `RunletKit` Swift package: `RunletCore` (protocol, value tree, targets/profiles/
  settings/history/snippet models, atomic JSON store with last-good recovery) and
  `RunletExecution` (posix_spawn supervisor with process groups, frame decoder,
  run sessions, local / `docker exec` / disposable Docker sandbox adapters).
- Exactly one terminal `finished` event per run, including launch failure, fatal exit,
  `exit()`/`dd()`, cancellation, and lost transport.
- Stop: local runs signal the runner's process group (snippet children included);
  Docker runs signal the runner inside the same container through a PHP helper that
  verifies the run's `RUNLET_RUN_ID` before signaling — the container keeps running.
- Docker discovery via `docker inspect`, Compose-label profile resolution (recreation,
  ambiguous replicas, name-only confirmation), and in-container probing using PHP only.
- Runner hooks whichever VarDumper the active `dump()` uses, including php-scoper aliases
  from `auto_prepend_file` tools such as global Ray.
- Fixtures (`Tests/Fixtures`, `scripts/setup-fixtures.sh`) and integration tests covering plain/Composer/Laravel, PHP 7.4, read-only non-root containers, output
  robustness and limits, selection line mapping, concurrency, and Stop.

### 2026-10-02 — Milestone 0: repository and risk prototypes (in progress)

- Repository initialized; `plan.md` holds the product plan and MVP requirements.
- Decisions recorded: macOS 26 minimum, runner compatible with PHP 7.4+ targets,
  official `php:8.4-cli` image for the Docker-backed sandbox, PHPantom 0.10.0 pinned.
- PHP runner (`Resources/Runner/src/Runner.php`) with nonce-framed event protocol on
  stdout, AST-based final-expression capture (nikic/php-parser 5.9.0, scoped as
  `RunletVendor\PhpParser`), bounded value normalization (no getters/`__toString`),
  dump/dd interception, parse/bootstrap/execute/fatal error reporting.
- Runner bundler (`scripts/build-runner.php`) producing one self-contained file that is
  streamed to `php` on stdin, so nothing is written into projects or containers.
  Verified on PHP 7.4.33, 8.2 (Alpine), and 8.4.25, locally and via `docker exec` into
  a read-only, non-root container.
- Pinned Laravel 13.34.0 sandbox skeleton (`Resources/Sandbox/laravel`).
- `scripts/fetch-phpantom.sh` downloads and checksum-verifies PHPantom 0.10.0 for both
  architectures and builds a universal binary.
