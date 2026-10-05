# SSH

An SSH profile runs snippets on a server, with the server's own PHP, in your application's folder there. Pick it in the target menu, press Run, and the output, dumps, errors, and Stop work as they do on your Mac.

Runlet uses your Mac's own `ssh` and your `~/.ssh/config`, so hosts, jump hosts, keys, ssh-agent, and 1Password work as they do in Terminal. Password and two-factor logins work too. Runlet never stores a password or a key.

## Creating an SSH Profile

Choose **Library ▸ New SSH Profile…** (also in the target menu and the command palette), click **+** in the Profiles window, or [import hosts from `~/.ssh/config`](#importing-hosts-from-sshconfig). Then fill in the form:

| Field | What to enter |
| --- | --- |
| **Name** | Shown in the target menu, tabs, and history, such as "Shop production". |
| **Host** | An alias from `~/.ssh/config` (the list button shows them) or a host name. Your config's user, port, `ProxyJump`, keys, and `IdentityAgent` apply, and Runlet shows below the field what the alias resolves to. |
| **User**, **Port**, **Jump host**, **Key file** | Optional overrides. Leave them empty to use `~/.ssh/config`. |
| **Directory** | The application's folder on the server, as an absolute path, such as `/home/forge/example.com/current`. A symlink is fine. See [Finding the Directory](#finding-the-directory). |
| **PHP executable** | `php`, a name such as `php8.3`, or an absolute path. Test Connection lists the PHP binaries it finds. |
| **Strict types**, **Mail** | As in a local project's [options](local-projects.md#project-options). Intercepting mail (recorded, not sent) suits production hosts. |
| **Keep the runner and compiled PHP on the server** | On for new profiles. See [Keep the Runner and Compiled PHP on the Server](#keep-the-runner-and-compiled-php-on-the-server). |
| **Docker on This Host** | Optional: run inside a container on the server. See [Docker on the Server](#docker-on-the-server). |
| **Authentication** | **SSH agent, 1Password, or key files**, or **Password or two-factor code**. See [Logging In](#logging-in). |
| **Keep connection** | For agent and key logins: how long the shared connection stays open after the last run, from 10 minutes (the default) to **Until I disconnect**. |
| **Compress the connection** | `ssh -C`, on by default. It shrinks what runs send: Runlet's runner (about 1.7 MB, when the server doesn't keep it) compresses to about 320 KB. |
| **Local folder**, **PHP version for completion** | The project's checkout on your Mac. See [Local Folder](#local-folder). |
| **Environment**, **Databases** | See [Environments & Production](environments.md) and [saved connections](connections.md#saved-connections). |

![The Profiles window with an SSH profile: its host, directory, and PHP, and Keep the runner and compiled PHP on the server turned on](screenshots/ssh/profile-editor-light.webp#gh-light-mode-only)
![The Profiles window with an SSH profile: its host, directory, and PHP, and Keep the runner and compiled PHP on the server turned on](screenshots/ssh/profile-editor-dark.webp#gh-dark-mode-only)

The form checks each value as you type. Spaces around a value and a trailing `/` don't matter, and an empty field only shows a grey example.

> [!NOTE]
> Saving, opening, or switching to an SSH profile never connects, and neither do launching Runlet or restoring tabs. Runlet connects only when you press **Run**, **Test Connection**, **Detect**, **Browse…**, or **Connect…**, or ask the Commands panel to list the host's commands.

### Finding the Directory

- **Detect** connects (without prompts, like Test Connection) and runs a short PHP check that only reads folder names. It fills in your home folder if Directory is empty, and lists folders that look like PHP applications (with `artisan`, `bin/console`, `wp-config.php`, `composer.json`, or a `.runlet` folder) in `~/*`, `~/*/current`, `/var/www/*`, `/srv/*`, `/home/*/*`, and `/opt/*`. Click one to use it.
- **Browse…** opens a folder picker on the server. Type a path (`~` works there) or click through folders. Folders that look like PHP applications have badges, and symlinks show where they point. It writes nothing.
- **Symlinks stay as you chose them,** so a profile on Forge's `current` follows the next release.
- **Runlet doesn't expand `~`** in the Directory field: type the full path, or click Detect, which replaces a leading `~` with your home folder.

For a password or two-factor profile, log in first: Detect offers **Connect…**, and the form comes back with your values once you've logged in.

## Importing Hosts from ~/.ssh/config

**Library ▸ Import SSH Hosts from ~/.ssh/config…** (also in the Profiles window's **+**, **Settings ▸ Targets**, and the command palette) lists the `Host` aliases of your config, with what each resolves to (`user@hostname:port`, and the jump host). Wildcard patterns are skipped, and `Include` is followed.

Tick the hosts to add. For each, enter the application's directory now, or leave it empty and use **Detect** later, and check the suggested environment: Runlet suggests production or staging from words in the alias or host name, such as `prod` or `staging`. Aliases that already have a profile are shown but skipped.

Importing reads your config only and connects nowhere. (`Match exec` lines in your config do run, as they do for `ssh -G` in Terminal.)

## The Profiles Window

**Library ▸ Manage Profiles…** (also in the target menu, **Settings ▸ Targets**, and the command palette) shows every Docker and SSH profile. The list has a Docker section and an SSH Hosts section, with each host's connection status and environment; the form beside it edits the selected profile.

- Edits stay a draft until **Save** (<kbd>Return</kbd> or <kbd>⌘</kbd><kbd>S</kbd>); **Revert** goes back. Switching profiles or closing the window with unsaved changes asks first.
- **+** creates a Docker or SSH profile, or imports SSH hosts. **−** deletes the selected profile from Runlet: the server is untouched. **⋯** duplicates it, uses it in the current tab, or connects and disconnects.
- **Connect…** logs in with the profile's current values, saved or not, in a terminal tab of the main window.

## Logging In

### Keys, Agents, and 1Password

With **SSH agent, 1Password, or key files**, logins need no extra steps: keys in ssh-agent or the 1Password SSH agent, key files without a passphrase, and keys whose passphrase macOS keeps (`UseKeychain`). With 1Password, approve the request in 1Password's window.

The first run opens a shared connection, and later runs reuse it: each run then starts in tens of milliseconds, and 1Password asks only once. The connection closes after the **Keep connection** time without use.

A profile can name a **Key file** on your Mac. Runlet passes only its path to `ssh`: it never reads or copies the key, and OpenSSH or your agent asks for its passphrase.

### Password or Two-Factor Code

For servers that ask for a password, a one-time code (OTP, Duo), or the passphrase of a key no agent holds:

1. Set the profile's **Authentication** to **Password or two-factor code**.
2. Click **Connect…**: in the banner above the editor, the target menu, the profile, or the command palette ("Connect to SSH Host…").
3. A terminal tab opens below the editor, and OpenSSH asks its questions there, exactly as in Terminal. What you type goes straight to `ssh`: Runlet never reads, stores, or logs it.
4. Once you're logged in, the tab closes, and the status bar and the profile show **Connected**.

Runs then reuse that login. They never try to log in themselves: a run on a disconnected profile stops at once with **Connect…**, without contacting the server.

The login stays until you choose **Disconnect** (in the target menu, the profile, or the command palette), even when you quit Runlet: after a restart, Runlet finds it again. It also ends when the network drops or the Mac sleeps long enough for the server to give up; the status then says **Login ended**, and the next run asks you to connect again. A wrong password keeps the terminal tab open, so you can read OpenSSH's message. Disconnecting while runs are in progress asks first, since they end with the connection.

### Host Keys

Runlet never accepts a host key by itself. A run on a host that isn't in your `~/.ssh/known_hosts` yet fails with "isn't in your known hosts yet" and offers **Connect…**: the terminal tab shows OpenSSH's own fingerprint question, and only your answer adds the key. A changed host key is refused with OpenSSH's own warning, and Runlet offers no way around it.

Agent and key profiles can use **Connect…** too, for example to accept a new server's host key once.

## Test Connection

**Test Connection** in the profile logs in without prompts and runs one short PHP check in the directory, which only reads files. Your snippet and the project's code don't run. It shows:

- the PHP version and binary, the login user, and the server's operating system;
- whether the directory exists and is readable, and its real path (for symlinks such as Forge's `current`);
- the framework or `.runlet` driver, found from files;
- whether the tokenizer is there, and how Stop can signal PHP;
- the round-trip time;
- other application folders and PHP binaries on the server, each with a button to use it.

## How Runs Work

- **Nothing is written on the server** unless you keep the runner there. Without [Keep the Runner and Compiled PHP on the Server](#keep-the-runner-and-compiled-php-on-the-server), Runlet's runner streams to PHP on its standard input with every run, so read-only homes and project folders work. With it (on for new profiles), Runlet writes only into `~/.cache/runlet` on the server, and a run that can't write there still works.
- **A run never asks for anything,** and never accepts an unknown host key.
- **A dead network link** ends a run after about 45 seconds, instead of hanging.
- **Any login shell works:** bash, zsh, dash, and fish. (csh and tcsh are untested.) Text a login script prints, such as an `echo` in `.bashrc`, shows up in the output.
- **Project drivers** in `.runlet/` are read from the server's directory, so commit or deploy them: a `.runlet/` folder that exists only on your Mac isn't sent.

## Keep the Runner and Compiled PHP on the Server

Two things make a run on a server slower than one on your Mac: Runlet sends its runner, about 1.7 MB, with every run, and PHP compiles every file the application loads (thousands for WordPress with plugins; the Run Log's "WordPress boot" line shows how long that takes). With **Keep the runner and compiled PHP on the server**, on for new profiles, the server keeps both in a private cache:

- **The runner, in `~/.cache/runlet/runner`.** A run then sends only its own code, a few kilobytes. On a slow connection that saves most of the time a run takes: about 1.3 seconds per run at 2 Mbit/s upload, and 0.3 seconds at 10 Mbit/s, with **Compress the connection** on.
- **PHP's compiled files, in `~/.cache/runlet/opcache`.** Runs reuse them. Edited files are still compiled again, because PHP checks their timestamps on every run.

The first run after you install or update Runlet sends the runner and keeps it there. Later runs, also after you restart Runlet, use the kept copy.

- **Private.** Both folders are readable only by the SSH user (mode `0700`, files `0600`).
- **Checked before every run.** Runlet uses the kept runner only when it's a regular file (not a symlink), owned by the SSH user and private to it, in a folder no one else can write, and when its SHA-256 hash is the one Runlet expects. Otherwise the run sends the runner again, and keeps the new copy.
- **Your code and passwords stay off the disk.** The run's own code, and a [saved connection](#saved-database-connections)'s password, still arrive on standard input, which neither cache stores.
- **A run never fails because of the cache.** When it can't be used (a read-only home, a full disk, or PHP without the opcache extension), runs go on without it, and the runner streams as it would with the setting off.
- **Three runners at most.** Runlet keeps the three it used last, so updates don't pile up.
- **Only Runlet's runs** use the cache: the server's `php.ini`, PHP-FPM, WP-CLI, and cron are not affected.
- **Not with a Docker container step.** The setting isn't offered there, and the runner streams into the container with every run.

The Run Log's launch line says what each run sent, such as "4,020 bytes on stdin: the request; the runner (8da5a95574a7) is read from ~/.cache/runlet/runner on the server".

### Clearing the Cache

Delete the folder on the server at any time; the next run fills it again:

```sh
rm -rf ~/.cache/runlet
```

Turn the setting off if nothing may be written on the server: every run then sends the runner, and Runlet writes nothing there. Profiles saved by Runlet 0.1.0 or earlier keep their setting: off, unless you turned it on.

## Docker on the Server

For an application that runs in Docker on the server, turn on **Run inside a Docker container on this host** in the profile's **Docker on This Host** section. Runs then use `docker exec` into that container, through the profile's SSH connection, instead of the server's own PHP.

| Field | What to enter |
| --- | --- |
| **Container** | Click **List Containers…**: Runlet lists the server's running containers, grouped by Compose project. Choose the application's container. |
| **Working directory** | The application's folder inside the container. It's filled in from the container, the menu suggests its mounts, and **Browse…** lists its folders. |
| **PHP executable**, **Execution user**, **Temporary directory** | As in a [Docker profile](docker.md#creating-a-docker-profile): `php`, an optional `docker exec --user`, and the folder exported as `TMPDIR`. |
| **Docker command** | How the server calls Docker: `docker`, an absolute path, or `sudo -n docker` when your login may use Docker only through passwordless sudo. |

It works like a [Docker profile](docker.md), over SSH:

- **The container is found again before each run,** by its Compose project and service (or its name). When several replicas match, or a container without Compose labels was replaced, Runlet asks which one to use, and never switches silently.
- **Stop** signals PHP inside the container. The container keeps running.
- **Test Connection** also finds the container and checks PHP inside it. A server without PHP of its own is fine, since only the container's PHP runs (but Detect, Browse… for the server directory, and the drift warning need PHP on the server).
- **File links** map container paths to your local folder, through the server directory's mount into the container (for example, `/var/www/html/app/User.php` → `/home/forge/shop/app/User.php` on the server → `~/Code/shop/app/User.php`).
- **The server directory stays part of the profile:** Detect, Browse…, and the drift warning use it, and it fills itself in from the container's mount when it's empty.
- **Commands and Open REPL** run inside the container. The terminal's **+** menu has **Shell in `<container>` on `<host>`** (bash if the container has it, else sh) and **Shell on `<host>`** for the server itself.
- **Docker problems are explained:** Docker not found as the Docker command, no permission on the Docker socket, sudo asking for a password (a run can't answer it), or the Docker daemon not running.

## Commands, Shells, and REPLs

- **Project commands.** The Commands panel lists an SSH host's commands only when you click **List Commands on `<host>`**: listing boots the application on the server, as a run does. Each command then runs on the server, in a terminal tab below the editor, in the profile's directory and with its PHP. A login shell's `PATH` applies, so Composer's global tools and PHP version managers are found. See [Project Commands](project-commands.md).
- **Shell on Host** opens your login shell on the server, in the profile's directory: from the terminal's **+** menu, the target menu, the Commands panel's terminal button, or the command palette ("Open Shell on SSH Host").
- **Open REPL** opens the project's REPL on the server: Tinker, else PsySH, else `php -a`.
- **Tests** run the project's test suite on the server: `php artisan test`, Pest, or PHPUnit.

Like runs, commands never ask for a password and never accept an unknown host key. A password or two-factor host must be connected with **Connect…** first. On production hosts, listing, every command, a shell, and a REPL ask first, and Tests are disabled.

## Local Folder

The local folder is the project's checkout on your Mac. It's optional, but it powers what Runlet reads from your Mac:

| Feature | With a local folder | Without one |
| --- | --- | --- |
| Completion and diagnostics | Your project's classes, and the variables your driver injects. | PHP's own functions and classes only. |
| The tab card's framework and driver | Read from the local files, with no network. | From Test Connection and runs. |
| Project snippets | `.runlet/snippets/` in the local folder, and **Save Snippet to Project…**. | None. |
| Host commands | A driver's host commands run on your Mac, in the local folder. | Listed with "needs a local folder". |
| Open Project in Editor | Opens the local folder. | Disabled. |
| Terminal | New shells start in the local folder. | New shells start in your home folder. |
| File links | Server paths open the matching local file in your editor, also for Forge-style `…/current` and `…/releases/<id>/` paths. | Plain text. |
| Source in error cards | The lines around a server path, from the local file, marked **local copy** ([source excerpts](snippet-api.md#source-excerpts)). | "Source not available here". |

**Suggestions.** When a profile has no local folder, Runlet looks for one on your Mac and offers it with **Use for Completion**, above the editor and in the profile. It never applies one on its own. It looks at folders Runlet already knows, and at `~/Code`, `~/Projects`, `~/Sites`, `~/Herd`, `~/Developer`, `~/src`, `~/dev`, and `~/www`, reading only `.git/config` and `composer.json`. The best matches have the same Git remote as the server's checkout, then the same `composer.json` name (both after Test Connection), then the same folder name.

**Drift warning.** Turn on **Warn when the local folder differs from the server** to compare the two after Connect…, Test Connection, and the first run of a session. A difference shows a yellow banner, such as "Your local checkout (feature/x @abc1234) differs from forge@shop (main @def5678)…", with **Check Again**. It never blocks a run. It's off by default because it reads files on the server (its `.git` files, or `composer.lock` for deployments without Git), with a read-only PHP check.

## Saved Database Connections

A database connection you [save](connections.md#saved-connections) for an SSH profile opens on the server, in the server's PHP (or the container's), so a database that listens only on the server works. That PHP needs `pdo_mysql` or `pdo_pgsql`; Test Connection lists the drivers it has.

The password travels on the SSH connection's standard input, never on the server's command line, so it isn't in the server's `ps`, shell history, or logs. Such a run boots none of the project's code.

A connection can also [open from your Mac](connections.md#from-this-mac-and-for-all-targets): **Connect from: This Mac** never goes to the server, and **Connect from: This Mac, through SSH profile** uses an SQL tunnel.

### SQL Tunnels

When the server reaches the database but its PHP can't open it, a saved connection can go [through an SSH tunnel](connections.md#through-an-ssh-tunnel). Runlet adds a port forward to the profile's shared connection, and your Mac's PHP opens the database through it.

- **Loopback only.** The forward listens on `127.0.0.1` on your Mac, on a free port. As with any SSH tunnel, other processes on your Mac can connect to that port while it exists; the database still asks for its password.
- **Only while needed.** One forward per saved connection, reused by its runs, and removed 5 minutes after its last use, when no open SQL tab uses it, when you edit or delete the connection, when you disconnect, and when Runlet quits.
- **Never connected silently.** If the profile isn't connected, the run asks first ("Connect to “bastion” for the SSH tunnel?"). A password or two-factor profile opens **Connect…**, and you run again once you're logged in.
- **The Run Log** shows when a tunnel is added, reused, or removed, such as `127.0.0.1:50123 → postgres:5432 through bastion`.
- **Production.** A tunnel through a production profile asks before every run, and the confirmation names the profile.

The [Connection Manager](connections.md) lists open tunnels, and closes them.

## Stop

Stop ends the run's PHP on the server, and everything the snippet started there, even processes that left its process group. Runlet signals only processes of this run: `SIGTERM` first, then `SIGKILL` if they don't end.

Stop needs Linux's `/proc`. On a server without it (BSD, macOS), Runlet signals nothing it can't verify and reports the stop as unconfirmed: PHP may keep running until it finishes.

## Connection Manager

**Window ▸ Connections** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>C</kbd>), or the connection count in the status bar, opens the [Connection Manager](connections.md). It lists every profile's open shared connection, since when it's open, and what uses it (runs, statements, tunnels). Its **Close** is the profile's Disconnect, and asks first when something uses the connection or when its login needed a password or a code. It reads the connections on your Mac only, and never connects.

## Production Hosts

Mark live servers as production in the profile's **Environment**. Every run then asks first (<kbd>⌘</kbd><kbd>Return</kbd> runs), and listing commands, each command, a shell, and a REPL ask every time. Tests are disabled. [Environments & Production](environments.md) has the details, including **Mark as Production** for an application that says it's in production.

## Troubleshooting

Runlet explains `ssh` failures in plain words, with OpenSSH's own message below:

| Message | What to do |
| --- | --- |
| isn't in your known hosts yet | Click **Connect…**, and compare the fingerprint OpenSSH shows with the server's. |
| The host key … changed | Find out why. If the server was rebuilt, remove the old key with `ssh-keygen -R <host>` in Terminal, then use Connect… to check the new one. |
| didn't accept a key from your SSH agent or key files | Try `ssh <host>` in Terminal. If the server needs a password or a code, set the profile's authentication to **Password or two-factor code**, and click Connect…. |
| Not connected / The login … has ended | Click **Connect…**. |
| could not be resolved / couldn't reach | Check the host, your VPN, and your network. |
| The directory … doesn't exist | Fix the profile's directory: Test Connection lists the applications it finds. |
| PHP was not found as … | Set the PHP executable: Test Connection lists the PHP binaries it finds. |
| Docker was not found on … | Set the profile's Docker command to an absolute path, or install Docker on the server. |
| may not use Docker (permission denied on the Docker socket) | Add your login to the `docker` group, or set the Docker command to `sudo -n docker` if passwordless sudo is allowed. |
| Several running containers … match | Choose the container in the sheet that opens: it stays chosen while it runs. |
| The SSH session … ended before the runner finished | The connection dropped, or PHP was killed on the server (for example, by the out-of-memory killer). |
| Runlet could not open the saved connection … The SSH server of "…" connects to the database for the tunnel | The [tunnel](#sql-tunnels) reached the server, but the server couldn't reach the database. Check the host and port as the server sees them (`ssh <host> nc -z <db host> <port>` in Terminal), and that the server allows TCP forwarding (`AllowTcpForwarding`). |
| The SSH tunnel couldn't listen on a free port | Five free ports were taken before `ssh` could use them: run again. |

## What Runlet Stores

- **The profile,** in Runlet's data folder: the host, overrides (including a key file's path), directory, PHP, options, and local folder. Never a key, a password, or a passphrase.
- **The shared connections' control sockets,** in Runlet's data folder (or, when its path is very long, in your temporary folder).
- **Workspaces** (`.runlet` files) name the host and directory of their SSH tabs: details of your infrastructure, but no secrets.
- **On the server,** with [Keep the Runner and Compiled PHP on the Server](#keep-the-runner-and-compiled-php-on-the-server): Runlet's runner and PHP's compiled files in `~/.cache/runlet`. Nothing else.

## For developers

Code: `RunletCore/SSHProfile.swift` (profile, endpoint, control paths), `RunletCore/ProductionGuard.swift`, `RunletCore/AppEnvironment.swift`; `RunletExecution/SSH.swift` (`SSHClient`, `RemoteShell`, `SSHFailure`, `SSHExecAdapter`, `RemoteSignal`), `SSHTunnel.swift` (`SSHForwardSpec`, `SSHTunnelManager`; the app's side is `AppModel+SQLTunnels.swift`), `ProjectREPL.swift`, `ProjectTests.swift`, `SSHProbe.swift`, `LocalCheckout.swift` (drift and folder suggestions), `SSHConfigHosts.swift`; in the app `AppModel+SSH.swift`, `AppModel+Production.swift`, `Features/SSHProfileEditor.swift`, `SSHContainerStepViews.swift`, `SSHConnectionViews.swift`, and `ProductionViews.swift`. The design and the later milestones are in [done-next-release-ideas.md §3](done-next-release-ideas.md#3-ssh-targets--design-proposal), and a summary in [Architecture ▸ SSH targets](architecture.md#ssh-targets). Saved connections over SSH were added under [#138](https://github.com/filipac/runlet/issues/138), connections from this Mac under [#142](https://github.com/filipac/runlet/issues/142), SQL tunnels under [#143](https://github.com/filipac/runlet/issues/143), key files under [#188](https://github.com/filipac/runlet/issues/188), and the Connection Manager under [#180](https://github.com/filipac/runlet/issues/180). This page was made concise under [#289](https://github.com/filipac/runlet/issues/289).

**A run.** For each run, Runlet starts the system OpenSSH client, `/usr/bin/ssh`:

```text
ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes … -S <control socket> -- <host> \
    "/bin/sh -c 'cd <directory> || exit 2; RUNLET_RUN_ID=<id>; export RUNLET_RUN_ID; exec <php> -d display_errors=stderr …'"
```

- `-T` keeps stdout and stderr apart, so raw output, framing, and the 8 MiB output limit work as they do locally. `BatchMode=yes` never prompts; `StrictHostKeyChecking=yes` never accepts an unknown key; `LogLevel=ERROR` keeps the server's banner out of the output. `ServerAliveInterval=15` and `ServerAliveCountMax=3` end a dead link after about 45 seconds. The remote command is always `/bin/sh -c '…'` with every word quoted.
- Runs, Stop, and Test Connection share one OpenSSH ControlMaster per profile. Agent and key profiles use `ControlMaster=auto` with `ControlPersist=<minutes>m` (or `yes`). Runlet checks the connection's status when an SSH tab appears and when you switch back to Runlet; OpenSSH counts that as use, so the Keep connection timer starts again. Interactive (password and 2FA) profiles use `ControlMaster=no`, and a run refuses to start until Connect… opened the socket.
- **Connect…** runs `ssh -M -S <control socket> -o ControlPersist=yes -o StrictHostKeyChecking=ask -N -f <host>` in a terminal tab (`StrictHostKeyChecking=ask` whatever the config says). After authentication, `-f` moves the master to the background and the tab's process exits, so the tab closes. **Disconnect** runs `ssh -O exit`. The status comes from the control socket, so checking it never contacts the server; a login ends when the server gives up after about 45 seconds without an answer.
- **The form** checks each value the way it is saved (trimmed, without a trailing `/`). The resolved values under Host come from `ssh -G`, which reads the config and doesn't connect.
- **Detect** and **Browse…** go through the shared connection, as Test Connection does, and Browse… lists one folder at a time. Import shows `ssh -G`'s `user@hostname:port` and jump host for each alias; an imported profile without a directory shows one issue until it has one.

**Opcode cache.** With **Keep the runner and compiled PHP on the server** (`SSHProfile.keepCompiledPHP`), each run creates `~/.cache/runlet/opcache` with mode `0700` and starts PHP with `-d opcache.enable_cli=1 -d opcache.file_cache=<that folder> -d opcache.file_cache_only=1 -d opcache.validate_timestamps=1 -d opcache.revalidate_freq=0`. A test checks the folder after a run with a saved connection's password, to confirm the request never reaches it.

**Runner cache** ([#48](https://github.com/filipac/runlet/issues/48)). The same setting keeps the runner in `~/.cache/runlet/runner/<sha256>.php` (`RunletExecution/SSHRunnerCache.swift`; the attempts in `ExecutionEngine.launch` and `RunSession.pump`). The setting was reused rather than given a toggle of its own: it already meant "Runlet may write into a private `~/.cache/runlet`", on for new profiles and off for old ones, so one switch still answers "may Runlet write on this server?", and turning it off still writes nothing.

- **The script.** After the directory check, `RUNLET_RUN_ID`, and the opcode cache's `set -- -d …`, it runs `command -v <php> >/dev/null 2>&1 || exec <php> "$@" -d …` (a missing PHP is reported as without the cache), then `{ <php> -n -r 'eval(stream_get_contents(STDIN, (int) fgets(STDIN)));' -- "$(id -u)" || echo '<miss program>'; } | exec <php> "$@" -d …`. A runner killed by a signal now ends the shell with 128 + the signal instead of the signal itself, and `SSHFailure` explains 137 as a kill (for example the out-of-memory killer) and other signals by number (re-raising the signal was tried, but it can't tell `exit(130)` from SIGINT). The words have no backslashes, which fish reads as escapes inside single quotes.
- **stdin** is the loader's length on a line, the loader (`SSHRunnerCache.loaderBody`, PHP 7.4 syntax, only core functions, PCRE, and hash, since `-n` loads no extensions) with `$mode`, `$hash`, `$size`, and `$keep` set, then the payload: the request (`use`), or the runner and the request (`save`). `RunnerBundle.request(in:)` splits the engine's script, which always starts with the runner. The loader reads all of stdin and writes the runner's program, the runner then the request, byte for byte what a streamed run sends, into the pipe; the runner's PHP reads it as standard input, so it is still "Standard input code", and errors, frames, raw output, `exit()`, and limits are unchanged. The runner's PHP is no longer the session's first process, but Stop never relied on that: it signals by PID and `RUNLET_RUN_ID`, and the loader carries the run ID too.
- **Checks (`use`).** `~/.cache/runlet` (followed) and `runner` (not followed) are directories owned by `id -u` and not group- or world-writable; the file's `lstat` is a regular file; the opened handle's `fstat` is the same inode, owned by the login, mode `0600` or stricter, of the expected size; and the SHA-256 of the bytes read matches. Those same bytes go into the pipe, so nothing can change between the check and the run. A file older than an hour is touched, for the cleanup's order.
- **Saving (`save`).** The loader checks the runner's SHA-256, makes the folder (`umask 077`, `mkdir -p`), checks it as above, writes `.<hash>.<pid>.<random>.tmp` with `fopen(…, 'x')` (never through a symlink), `chmod 0600`, renames it over `<hash>.php`, keeps the three most recently used runners, and removes temporary files older than ten minutes. It saves before writing the program, inside `try`, and any failure only skips the save: a loader that dies before writing gets the shell's `|| echo`, never a half program.
- **A miss** writes `SSHRunnerCache.missProgram` (`<?php fwrite(STDERR, "Runlet: runner cache miss" . PHP_EOL); exit(75);`) instead of the program. `RunSession.pump` holds an attempt's output until the runner's first frame (`0x1E RL1:<nonce>:`, or 1 MiB); when the attempt ends first with exit 75 and the marker, nothing of it is shown, and the engine launches the next attempt and attaches it, so Stop reaches it: `use` → `save` → `stream` (no loader). Stop during an attempt finishes the run as cancelled instead.
- **No extra round trip.** Runs try `use` first, also the first run after a restart, since a server usually keeps the runner from an earlier session; a miss costs one more `ssh` exchange through the shared connection. `RunnerCacheMemory` (per engine, keyed by the control path and the runner's hash) skips `use` for ten minutes after a miss that follows a completed save with no hit since (a home where saving doesn't last), and streams without the loader for ten minutes after the loader itself failed. A single exchange that asks for the runner mid-stream was considered: it needs stdin kept open and a marker parsed out of the output before the frames, for a gain only on misses.
- **Container step.** Not cached: `keepCompiledPHP` is nil for a profile with a container, and `docker exec -i` streams as before. Caching would need PHP on the host (the loader) or a cache inside the container, whose home may be read-only or recreated.

**Measurements** (2026-10-06; the SSH fixture, PHP 8.4 on Linux arm64 in OrbStack, on an M5 Max; runs of `1 + 1` through the shared connection, through a relay that shapes the uplink and adds a 40 ms round trip, median of five):

| | Runner bundle | gzip -6 | A hit's stdin | On the wire, per run |
| --- | --- | --- | --- | --- |
| Bytes | 1,672,164 | 316,208 (zlib in `ssh -C`: 20 ms of CPU on this Mac per run) | 4,020 (loader 3,333, request 682) | streamed: 1,675,152, or 318,950 with `-C`; hit: 5,156, or about 350 with `-C` (the loader repeats, so the connection's compression keeps it in its window) |

| Uplink | Streamed, no `-C` | Hit, no `-C` | Streamed, `-C` | Hit, `-C` |
| --- | --- | --- | --- | --- |
| Unshaped | 168 ms | 188 ms | 186 ms | 176 ms |
| 50 Mbit/s | 492 ms | 189 ms | 230 ms | 169 ms |
| 10 Mbit/s | 1,581 ms | 187 ms | 473 ms | 190 ms |
| 2 Mbit/s | 6,951 ms | 199 ms | 1,513 ms | 195 ms |

- **Compression alone** (`ssh -C`, already the default) cuts the bytes by 81% but leaves 1.3 s per run at 2 Mbit/s and 0.28 s at 10 Mbit/s, and costs 20 ms of zlib per run on the Mac; the cache takes those to about 0.2 s, close to an unshaped run. So the cache keeps compression on, rather than compressing the runner itself on a miss.
- **Server cost of a hit.** On the fixture, `php -n` starts in 4.6 ms, reading the runner takes 0.07 ms, and its SHA-256 7.5 ms (PHP's own SHA-256; `sha256sum` takes 1.3 ms, SHA-1 1.6 ms, xxh128 0.06 ms); the whole loader adds about 11 ms before the runner's PHP has its program, against 24.5 ms for PHP to compile the runner. Directly on loopback, without the relay, the medians of 15 runs were 63 ms streamed and 77 ms hit without `-C`, and 80 ms streamed and 57 ms hit with it: a hit is slower only on a link where 1.7 MB costs nothing and compression is off. The full SHA-256 stays: it is a few milliseconds of the server's CPU, and the checks around it make the bytes that run the bytes that were checked.

**Saved connections.** The password travels inside the runner's request on the `ssh -T` channel's standard input. The server's root user can still read the PHP process's memory while the statement runs, as it can read the application's own `.env`. A connection set to **Connect from: This Mac**, or saved for all targets, opens in a PHP process on this Mac, so its password stays on this Mac and the host is resolved here.

**SQL tunnels.** Runlet adds a local forward to the profile's existing control master:

```text
ssh -F /dev/null -o BatchMode=yes -o LogLevel=ERROR -S <control socket> \
    -O forward -L 127.0.0.1:<free port>:<db host>:<db port> -- <host>
```

- Every run, probe, Stop, and Connect… still passes `ClearAllForwardings=yes`; only `-O forward` and `-O cancel` on the control master add and remove forwards. Those two talk only to the local master, so they read no configuration (`-F /dev/null`): a `LocalForward` or `ClearAllForwardings` in `~/.ssh/config` can't add forwards to the request or clear Runlet's.
- The forward binds `127.0.0.1` explicitly, so the master listens on loopback whatever `GatewayPorts` says. The port is one the kernel reports free just before; if another process takes it meanwhile, OpenSSH says "Port forwarding failed" and Runlet retries with another port (up to 5). The `-L` argument holds a host and two ports, never a user or password, so it may show in `ps`. The database's password reaches only this Mac's PHP, on its standard input.
- Each run (statements, Run All, Explain, Load Next, Load Schema, Show Definition, Test Connection, and Stop's cancel runner) holds the forward while it runs, and re-sends `-O forward`, which OpenSSH answers at once for a forward it has and which puts it back on a master that was restarted. It is cancelled with `-O cancel` 5 minutes after its last use, when no open SQL tab uses the connection, when the connection is edited or deleted, before Disconnect (which then runs `ssh -O exit`), and when Runlet quits (also on password and 2FA logins, which stay connected). Test Connection removes its forward at once unless an SQL tab uses the connection.
- An agent or key profile that isn't connected logs in as its runs would (BatchMode, `ControlMaster=auto`, its Keep connection time); the tunnel never opens a master by itself.
- The Run Log shows each run's `-O forward` line ("Added" or "Reused" the tunnel) and the `-O cancel` line with the reason, in the tabs that used it. macOS's unified log (subsystem `dev.runlet.Runlet`, category `ssh-tunnel`) records every add, reuse, and cancel too. None of them holds a secret.
- Disconnect counts SQL tabs running through the profile's tunnel among the runs it warns about. The app keeps the active forwards in `SQLTunnelStore.active` (the connection, the profile, the ports and host, when it opened and was last used, and whether a statement uses it) with `closeSQLTunnel(_:force:)`; the Connection Manager lists and closes them. Removing the profile leaves tunnelled connections of other targets in place, marked as missing their profile; Runlet never switches them to another profile.

**Docker on the host.** Docker is called on the server as `ssh … -- <host> "/bin/sh -c 'docker exec -i --env RUNLET_RUN_ID=… --workdir <dir> <container> php …'"`, with the same SSH options as a plain run. Runlet doesn't use `DOCKER_HOST=ssh://…`, which couldn't share the login of a password or two-factor profile. The profile keeps the container's Compose project and service (or its name), never only its ID; each run lists the server's containers (`docker ps`, `docker inspect`) and resolves the profile again, and right before launch checks that the container still exists and runs. Stop runs `docker exec … php -r …` on the server, checking the run's `RUNLET_RUN_ID` first. File links map through the bind mount of the server directory into the container, or through the container's working directory when the server directory isn't mounted. Commands and Open REPL use `<docker> exec -it [--user] [--env TMPDIR] -w <container directory> <container> sh -lc '…'` over `ssh -t`. Docker problems are explained: Docker not found as the Docker command, no permission on the Docker socket, sudo asking for a password, or the daemon not running.

**Commands.** A listed command runs as:

```text
ssh -t -o BatchMode=yes -o StrictHostKeyChecking=yes … -S <control socket> -- <host> \
    "/bin/sh -lc 'cd <directory> || …; php8.3 artisan migrate:status'"
```

- The command runs in the profile's directory, with a leading `php` replaced by the profile's PHP executable. `sh -l` reads `/etc/profile` and `~/.profile` first. `-t` gives the command a terminal (colours, prompts, progress bars), with the same batch options as a run. A command that needs arguments opens a login shell in the directory with the command typed, so you can complete it and press Return. The tab stays open when the command ends; Run Again repeats it.
- Shell on Host runs `exec "$SHELL" -l` in the directory; if the directory can't be opened, the shell starts in the home folder and says so.
- Open REPL works without listing commands first, uses the profile's PHP, and is chosen on the server in the `sh -lc`: Tinker (`php artisan tinker`) when `artisan` and `vendor/laravel/tinker/` exist, PsySH (`php vendor/bin/psysh`), else `php -a` with a one-line note:

  ```text
  ssh -t -o BatchMode=yes -o StrictHostKeyChecking=yes … -S <control socket> -- <host> \
      "/bin/sh -lc 'cd <directory> || …; if [ -f artisan ] && [ -d vendor/laravel/tinker ]; then … exec php8.3 artisan tinker; fi; …'"
  ```

  The tab is titled "REPL · <host>" until the server has chosen, then "Tinker · <host>", "PsySH · <host>", or "PHP shell · <host>", and stays open after you leave the REPL. Opening or restoring a tab never starts a REPL.
- Tests (Run All, File…, Filter…) are chosen on the server the same way: `php artisan test` (Laravel with Collision), else `vendor/bin/pest`, else `vendor/bin/phpunit`, each only with a `phpunit.xml`, `phpunit.dist.xml`, or `phpunit.xml.dist`, run with the profile's PHP (inside the container with a container step). File… takes a path relative to the profile's directory, and a file or filter is passed as one quoted argument. When the server has no runner (a deploy installed with `composer install --no-dev`), the tab says so and nothing runs. The tab is titled "Tests · <host>" until the server has chosen, then "artisan test · <host>", "pest --filter=checkout · <host>", …. On production hosts the group shows "Tests can reset the database; they're disabled on production targets."
- On production hosts, "Don't ask again for 10 minutes" covers snippet runs only. A REPL never uses or grants that grace.

**Stop.** Runlet waits for the runner's process ID, then runs a small PHP program over a second SSH session that signals only processes whose environment carries this run's `RUNLET_RUN_ID` (the runner and anything the snippet started, even after `setsid`): `SIGTERM`, 1.5 seconds, `SIGKILL`, 3 seconds, then a check. Killing the local `ssh` alone wouldn't stop PHP: without a pty the remote side gets no SIGHUP, and a shared connection keeps the session open.

**Local folder.** Server paths map under the profile's directory and the run's reported real path, and a root ending in `/current` also covers every `releases/<id>/` beside it. Folder suggestions read folders one and two levels deep; the server's Git remote counts `git@github.com:org/app.git` and `https://github.com/org/app` as the same; the folder name is the server folder's, or the site folder for `/home/forge/<site>/current` (also its first label, so `shop.example.com` matches `shop`). The drift check reads the server's `.git` files (branch and commit) with the same read-only PHP check as Test Connection, so no `git` runs on the server; deployments without `.git` compare a CRC-32 of `composer.lock`.

**Storage.** Profiles are in `State/targets.json`. Control sockets are `~/Library/Application Support/Runlet/SSH/<8 hex>.sock` (a 0700 folder); macOS limits socket paths to 104 bytes, so a data folder with a very long path falls back to a folder in the per-user temporary directory.

**Tests.** `SSHUnitTests`, `SSHModelTests`, `SSHTunnelTests`, `LocalCheckoutTests`, `ProductionGuardTests`, and `AppEnvironmentTests` (no server); `SSHRunnerCacheScriptTests` (the script, stdin, and `RunnerCacheMemory`) and `SSHRunnerCacheLocalTests` (the loader and the attempts on this Mac through `fake-ssh`, with a scratch `HOME`: fill and hit, tampered runners, a folder others can write, a read-only folder, the cleanup, a PHP that refuses `-n`, a missing PHP); `SQLLiveTunnelTests` (the fixture forwarding to the `databases` services by name); and `SSHRunTests`, which start the disposable `runlet-fixtures` service `ssh` (OpenSSH and PHP 8.4 on `127.0.0.1:2222` only; see `Tests/Fixtures/docker/ssh/`). They generate a throwaway key per run, pass their own config with `ssh -F`, use their own `known_hosts` and no agent, and never read `~/.ssh`. The runner cache's live tests (`runnerCache…`, `stopEndsARunThatUsedTheCachedRunner`) give `runlet` a `~/.cache` with `SSHFixture.Environment.withHomeCache`, which removes it before the test returns. The remote-Docker tests install `Tests/Fixtures/docker/ssh/fake-docker` as the fixture's `docker` (with made-up containers that are folders of the fixture), so no Docker runs inside the fixture and no real container is touched.

**Debug builds** read `RUNLET_SSH_CONFIG`, a config file used instead of `~/.ssh/config` (for screenshots and checks that must not touch your own SSH setup), and `RUNLET_SSH_EXECUTABLE`, a program used instead of `/usr/bin/ssh`. For screenshot tours, `Tests/Fixtures/fake-ssh/ssh` is a "loopback" fake: it answers `ssh -G` with made-up values, keeps a fake shared connection (a Unix socket) for Connect… (after a made-up password prompt) and Disconnect, and runs everything else on this Mac, so tour profiles point their directory at a local fixture folder. It never reads `~/.ssh` or opens a network connection. `VisualTourUITests` uses it with a made-up config.

What is still open for SSH is listed in [next-release-ideas.md](next-release-ideas.md).
