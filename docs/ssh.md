# SSH targets

Runlet can run snippets with a server's own PHP, in the application's folder on the server,
over SSH. An SSH target works like a local project or a Docker profile: pick it in the
target menu (or with ⌘P), press Run, and the output, dumps, errors, and Stop behave the
same.

This guide covers SSH hosts from `~/.ssh/config`, including jump hosts, with keys,
agents, passwords, or two-factor codes; running inside a Docker container on such a host;
project commands and shells there; and the Profiles window. What is still open is listed in
[next-release-ideas.md §3.15](next-release-ideas.md#315-implementation-plan).

## Create a profile

Use **Library ▸ New SSH Profile…** (also in the target menu and the command palette), the
**+** menu of the Profiles window, or [import hosts from `~/.ssh/config`](#import-hosts-from-sshconfig).

| Field | What to enter |
| --- | --- |
| Name | Shown in the target menu, tabs, and history. |
| Host | An alias from `~/.ssh/config` (the list button shows them) or a host name. Runlet passes it to `ssh` unchanged, so your config's `HostName`, `User`, `Port`, `ProxyJump`, `IdentityFile`, and `IdentityAgent` apply. Below the field, Runlet shows what `ssh -G` says the alias resolves to (this reads the config; it doesn't connect). |
| Override user, port, or jump host | Optional. Leave empty to use `~/.ssh/config`. |
| Directory | The application's folder on the server, as an absolute path, e.g. `/home/forge/example.com/current`. A symlink is fine. **Detect** fills in your home folder on the server and lists the folders that look like PHP applications (home first); **Browse…** opens a folder picker on the server. See [Finding the directory](#finding-the-directory). |
| PHP executable | `php`, a name such as `php8.3`, or an absolute path. Test Connection lists the PHP binaries it finds. |
| Authentication | **SSH agent, 1Password, or key files**, or **Password or two-factor code**. See [Logging in](#logging-in). |
| Keep connection | Agent and key profiles only: how long the shared connection stays open after the last run (10 minutes by default). |
| Compress the connection | `ssh -C`, on by default. Each run sends Runlet's runner (about 830 KB), which compresses well. |
| Local folder | The project's checkout on your Mac. See [Local folder](#local-folder). |
| Strict types, mail, PHP version for completion | As for local projects and Docker profiles. Mail can be intercepted per profile (recorded, not sent; see [Mail interception](drivers.md#mail-interception)), which suits production hosts. |

Saving, opening, or switching to a profile never connects to the server, and neither does
launching Runlet or restoring tabs. Runlet connects only when you press **Run**, **Test
Connection**, **Detect**, **Browse…**, or **Connect…**, or list commands.

The form checks each value as you type, the way it is saved: spaces around a value (a
pasted newline too) and a trailing `/` don't matter. An empty field only shows a gray
example; it isn't filled in.

### Finding the directory

- **Detect** connects (as Test Connection does: no prompts, through the shared connection)
  and runs a short PHP check that only reads folder names. If Directory is empty, it fills in
  your home folder; a popover lists the home folder first, then folders that look like PHP
  applications (`artisan`, `bin/console`, `wp-config.php`, `composer.json`, or a `.runlet`
  folder) in `~/*`, `~/*/current`, `/var/www/*`, `/srv/*`, `/home/*/*`, and `/opt/*`. Click one to
  use it. Forge-style `current` symlinks are kept as they are.
- **Browse…** opens a folder picker on the server: type a path (`~` works there) or click
  through folders (double-click enters a folder), with the enclosing folder, home, and a
  breadcrumb. Folders that look like PHP applications carry badges; symlinks show where they
  point and are kept as chosen, so a profile on `current` follows the next release. Hidden
  folders appear on request. It lists one folder at a time and writes nothing.
- Runlet doesn't expand `~` in the Directory field (PHP runs with the path as written). Type
  the full path, or click Detect, which replaces a leading `~` with your home folder.
- For a password or two-factor profile, log in first: Detect offers **Connect…**. The sheet
  steps aside while you log in in the terminal and comes back afterwards with your values,
  even when the profile can't be saved yet.

## The Profiles window

**Library ▸ Manage Profiles…** (also in the target menu, Settings ▸ Targets, and the command
palette) opens one window for every Docker and SSH profile: the list on the right has a
Docker section and an SSH Hosts section (with each host's connection status, read on this
Mac, and its environment), and the left side edits the selected profile with the same form
as its sheet.

- Edits stay a draft until **Save** (↩ or ⌘S); **Revert** goes back. Switching profiles,
  creating, duplicating, importing, or closing the window with unsaved changes asks Save /
  Don't Save / Cancel.
- **+** creates a Docker or SSH profile (click: the kind you're looking at; hold for the
  menu) or imports SSH hosts; **−** deletes the selected profile from Runlet (servers and
  containers are untouched); **⋯** duplicates it, uses it in the current tab, or connects and
  disconnects.
- **Connect…** in an SSH profile here logs in with the profile's current values (saved or
  not) in a terminal tab of the main window; the Profiles window stays open.

## Import hosts from ~/.ssh/config

**Import SSH Hosts from ~/.ssh/config…** (Library menu, the Profiles window's **+**, Settings
▸ Targets, the command palette) lists the `Host` aliases of your config (wildcard patterns
skipped, `Include` followed), each with what `ssh -G` says it resolves to
(`user@hostname:port`, the jump host). Tick the hosts to add; for each, enter the application's
directory now or leave it empty and use **Detect** later (an imported profile without a
directory shows one issue until it has one), and check the **environment**: hosts whose alias
or host name contains `prod`, `production`, `live`, or `prd` start as production, `staging`,
`stage`, `stg`, `uat`, `preprod`, or `qa` as staging. Aliases that already have a profile are
shown but skipped. Importing reads the config file only; nothing connects (`ssh -G` doesn't,
though `Match exec` lines in your config do run, as they do for `ssh -G` in Terminal).

## How a run works

Runlet uses the system OpenSSH client, `/usr/bin/ssh`, so everything works as it does in
your terminal. For each run it starts:

```text
ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes … -S <control socket> -- <host> \
    "/bin/sh -c 'cd <directory> || exit 2; RUNLET_RUN_ID=<id>; export RUNLET_RUN_ID; exec <php> -d display_errors=stderr …'"
```

- The runner is streamed to PHP on stdin. **Nothing is written on the server**, so read-only
  homes and project folders work.
- `-T` keeps stdout and stderr apart, so raw output, framing, and the 8 MiB output limit work
  as they do locally. Text that a login script prints (a `.bashrc` that echoes) shows up as
  raw output.
- `BatchMode=yes`: a run never asks for anything. `StrictHostKeyChecking=yes`: a run never
  accepts an unknown host key. `LogLevel=ERROR` keeps the server's login banner out of the
  output.
- Runs, Stop, and Test Connection share one connection per profile (an OpenSSH
  ControlMaster), so after the first run each run starts in tens of milliseconds and
  1Password asks for approval only once.
- A dead network link ends a run after about 45 seconds (`ServerAliveInterval=15`,
  `ServerAliveCountMax=3`) instead of hanging.
- The remote command is always `/bin/sh -c '…'` with every word quoted, so bash, zsh, dash,
  and fish login shells all work. csh and tcsh are untested.

`.runlet` drivers are read from the **server's** directory, so committed or deployed drivers
work as they do locally.

## Logging in

**SSH agent, 1Password, or key files.** Keys in ssh-agent or the 1Password SSH agent, key
files without a passphrase, and keys whose passphrase macOS keeps (`UseKeychain`) work with
no extra steps. The first run opens the shared connection by itself; it closes after the
**Keep connection** time without use. (Runlet checks the connection's status when an SSH
tab appears and when you switch back to Runlet; OpenSSH counts that as use, so the timer
starts again.) With 1Password, approve the request in 1Password's window.

**Password or two-factor code.** For servers that ask for a password, a keyboard-interactive
answer, a one-time code (OTP, Duo), or the passphrase of a key that no agent holds:

1. Set the profile's authentication to **Password or two-factor code**.
2. Click **Connect…** (in the banner above the editor, the target menu, the profile, or the
   command palette's "Connect to SSH Host…").
3. A terminal tab opens below the editor and runs
   `ssh -M -S <control socket> -o ControlPersist=yes -o StrictHostKeyChecking=ask -N -f <host>`.
   **OpenSSH** asks its questions there, exactly as in Terminal: the password, the code, an
   unknown host key's fingerprint. What you type goes from the keyboard through the terminal
   to `ssh`; Runlet never reads, stores, or logs it.
4. Once you're logged in, `ssh` moves to the background and the tab closes. The status bar
   and the profile show **Connected**.

Runs then reuse that login (`ControlMaster=no`, `BatchMode=yes`); they never try to log in
themselves, so a run on a disconnected profile stops at once with "Not connected" and a
**Connect…** button, without contacting the server.

The login stays until you **Disconnect** (target menu, profile, or command palette), which
runs `ssh -O exit`. It is not tied to Runlet: quitting Runlet leaves it open, and after a
restart Runlet finds it again (the status comes from the control socket, so checking it
never contacts the server). It also ends when the network drops or the Mac sleeps long
enough for the server to give up (about 45 seconds without an answer); the status then
says **Login ended**, and the next run asks you to Connect again. A wrong password keeps the
terminal tab open so you can read OpenSSH's message.

**Disconnect** while runs are in progress asks first, since they end with the connection.

If a run says the server rejected your keys, or the host key isn't known yet, see
[Troubleshooting](#troubleshooting).

## Host keys

Runlet never accepts a host key by itself. A run against a host that isn't in
`~/.ssh/known_hosts` fails with "isn't in your known hosts yet" and offers **Connect…**: the
terminal tab shows OpenSSH's own fingerprint question (`StrictHostKeyChecking=ask`, whatever
your config says), and only your answer adds the key. A changed host key is refused with
OpenSSH's own warning, and Runlet offers no way around it.

Connect… works for agent and key profiles too, for example to accept a new server's host
key once; their runs then reuse that connection until you disconnect.

## Test Connection

**Test Connection** in the profile logs in without prompts and runs one short `php -r` in
the directory that only reads files. Your snippet and the project's code don't run. It shows:

- PHP version and binary, the login user, and the server's OS;
- whether the directory exists and is readable, and its real path (for symlinks such as
  Forge's `current`);
- the framework or `.runlet` driver, found from files;
- whether the tokenizer is available and how Stop can signal PHP;
- the round-trip time;
- other application folders (`~/*/current`, `/var/www/*`, `/srv/*`, `/home/*/*`) and PHP
  binaries (`/usr/bin/php8.*`, …), each with a button to use it.

## Docker on the server

For applications that run in Docker on the server, turn on **Run inside a Docker container
on this host** in the profile (section "Docker on This Host"). Runs then use `docker exec`
into that container, through the profile's SSH connection, instead of the server's own PHP.

| Field | What to enter |
| --- | --- |
| Container | Click **List Containers…**: Runlet runs `docker ps` and `docker inspect` on the server and lists the running containers, grouped by Compose project. Choose the application's container. |
| Working directory | The application's directory inside the container (filled in from the container; the menu suggests its mounts; **Browse…** lists folders inside the container). |
| PHP executable, Execution user, Temporary directory | As in a Docker profile: `php`, an optional `docker exec --user`, and the directory exported as `TMPDIR`. |
| Docker command | How the server calls Docker: `docker`, an absolute path, or `sudo -n docker` when the login may use Docker only through passwordless sudo (a run can't answer a sudo prompt). |

How it works:

- Docker is called on the server as `ssh … -- <host> "/bin/sh -c 'docker exec -i --env RUNLET_RUN_ID=… --workdir <dir> <container> php …'"`,
  with the same SSH options as a plain run (no prompts, no unknown host keys, the shared
  connection). Runlet doesn't use `DOCKER_HOST=ssh://…`, which couldn't share the login of a
  password or two-factor profile.
- **The container is found like a Docker profile's.** The profile keeps the container's
  Compose project and service (or its name when it has no Compose labels), never just its
  ID. Each run lists the server's containers and resolves the profile again: a recreated
  Compose container is found by its labels; when several replicas match, or a container
  without Compose labels was replaced, Runlet asks which one to use and never switches
  silently. The container you choose stays chosen while it runs.
- Right before launch, Runlet checks again that the container still exists and runs.
- **Stop** signals PHP inside the container (`docker exec … php -r …` on the server, checking
  the run's `RUNLET_RUN_ID` first); the container keeps running.
- **Test Connection** also finds the container and runs the read-only container probe in it
  (PHP, user, working directory, framework, temporary directory, Stop). A server without PHP
  of its own is fine: only the container's PHP runs. (Detect, Browse… for the server
  directory, and the drift check do need PHP on the server.)
- **File links**: PHP reports container paths. Runlet maps them to the local folder through
  the bind mount of the server directory into the container (for example
  `/var/www/html/app/User.php` → server `/home/forge/shop/app/User.php` → your
  `~/Code/shop/app/User.php`), or through the container's working directory when the server
  directory isn't mounted.
- **Commands and shells**: project commands run inside the container
  (`docker exec -it … sh -lc '<command>'` over `ssh -t`); the terminal's **+** menu offers
  "Shell in <container> on <host>" (bash if the container has it, else sh) and "Shell on
  <host>" for the server itself.
- The server directory stays part of the profile: Detect and Browse… use it, the drift check
  reads it, and it fills itself in from the container's bind mount when you choose a
  container with the directory still empty.
- Docker problems are explained: Docker not found as the Docker command, no permission on
  the Docker socket (add the login to the `docker` group, or use `sudo -n docker`), sudo
  asking for a password, or the Docker daemon not running.

## Commands and shells

**Project commands.** The Commands panel lists an SSH host's commands only when you click
**List Commands on <host>** (a password or two-factor host asks you to Connect… first).
Listing boots the application on the server, as a run does. Each command then runs **on the
server** in a terminal tab below the editor (rows show a server icon; host commands, with a
laptop icon, run on your Mac in the local folder):

```text
ssh -t -o BatchMode=yes -o StrictHostKeyChecking=yes … -S <control socket> -- <host> \
    "/bin/sh -lc 'cd <directory> || …; php8.3 artisan migrate:status'"
```

- The command runs in the profile's directory, with a leading `php` replaced by the profile's
  PHP executable. `sh -l` reads `/etc/profile` and `~/.profile` first, so tools your login adds
  to PATH (Composer's global bin, a PHP version manager) are found.
- `-t` gives the command a terminal (colours, prompts, progress bars), but like a run it never
  asks for a password or accepts an unknown host key, and it reuses the shared connection.
- A command that needs arguments opens a login shell on the server in the directory with the
  command typed, so you can complete it and press Return.
- The tab stays open when the command ends, so you can read its output; Run Again repeats it.

**Shell on Host.** Opens a login shell on the server in the profile's directory (your login
shell, `exec "$SHELL" -l`), from the terminal's **+** menu ("Shell on <host>"), the target
menu, the Commands panel's terminal button, or the command palette ("Open Shell on SSH
Host"). If the directory can't be opened, the shell starts in your home folder and says so.

**Production hosts** ask every time before listing commands, before each command, and before
opening a shell; "Don't ask again for 10 minutes" covers snippet runs only.

## Stop

Stop works like Stop for a Docker container: Runlet waits for the runner's process ID,
then runs a small PHP program over a second SSH session that signals only processes whose
environment carries this run's `RUNLET_RUN_ID`, the runner and anything the snippet
started, even if they left its process group. It sends `SIGTERM`, waits 1.5 seconds,
sends `SIGKILL`, waits 3 seconds, then checks.

Stop needs Linux `/proc`. On a server without it (BSD, macOS), Runlet signals nothing it
can't verify and reports the stop as unconfirmed: PHP may keep running until it finishes.

## Local folder

The local folder is the project's checkout on your Mac. It is optional but first-class:

| Feature | With a local folder | Without one (limited mode) |
| --- | --- | --- |
| Completion and diagnostics | PHPantom indexes the local folder, as for a local project (PHP version from the profile or the local `composer.json`). Variables your driver injects (`$app`, …) resolve their classes. | PHP's own functions and classes only; the status bar says why. |
| Framework and driver on the tab card | Read from the local files, with no network. | From Test Connection and runs. |
| Project snippets | `.runlet/snippets/*.php` in the local folder, and Save Snippet to Project…. | None. |
| Host commands | A driver's `hostCommands()` run on your Mac in the local folder (after the Commands panel listed the host's commands once). | Listed with "needs a local folder". |
| Open Project in Editor | Opens the local folder. | Disabled, with the reason. |
| Terminal | New shells start in the local folder. | New shells start in your home folder. |
| File links in output | Server paths in dumps, errors, and stack traces open the matching local file in your editor. Both the profile's directory and the real path PHP reports map, so Forge-style `…/current` and `…/releases/<id>/` paths (any release) open the same local file. | Plain text, with "Set a local folder in the SSH profile". |

**Suggestions.** When a profile has no local folder, Runlet looks for one on your Mac and
offers it with a **Use for Completion** button above the editor and in the profile (it is
never applied on its own). It looks at folders Runlet already knows (local projects, Docker
and SSH profiles) and at `~/Code`, `~/Projects`, `~/Sites`, `~/Herd`, `~/Developer`, `~/src`,
`~/dev`, and `~/www`, one and two levels deep, reading only `.git/config` and
`composer.json`. Matches, strongest first:

1. the same git remote as the server's checkout (`git@github.com:org/app.git` and
   `https://github.com/org/app` count as the same), after Test Connection;
2. the same `composer.json` `name`, after Test Connection;
3. the same folder name: the server folder's name, or the site folder for
   `/home/forge/<site>/current` (also its first label, so `shop.example.com` matches `shop`).

**Drift warning** (optional, off by default). With **Warn when the local folder differs
from the server** on, Runlet compares the local folder with the server's checkout after
Connect…, Test Connection, and the first run of a session. It reads the server's `.git`
files (branch and commit) with the same read-only PHP check as Test Connection, so no `git`
runs on the server. Deployments without `.git` (zero-downtime releases) compare a CRC-32 of
`composer.lock` instead. A difference shows a yellow banner ("Your local checkout (feature/x
@abc1234) differs from forge@shop (main @def5678)…") with Check Again. It never blocks a run.
It is off by default because it reads files on the server.

## Production hosts

Every target (local projects, Docker profiles, and SSH profiles) has an **Environment**
(development, staging, or production) and an optional **colour**, set in the project
options or the profile. Mark live systems as production:

- **Badges.** A red PRODUCTION badge in the toolbar next to the target menu, on the tab card
  (with a red stripe) and the horizontal tab, in the target menu, the ⌘P list, and Settings
  ▸ Targets; the status bar turns red. Staging shows an orange badge. A colour draws a stripe
  on tab cards and along the status bar.
- **Confirmation before each run.** Run and Run Selection show what will run (the target,
  `user@host:directory`, and the first 12 lines of the code or selection, with the line
  count). **⌘↩ runs it; ↩ and Esc cancel**, so a reflexive Return never runs code on
  production.
- **Don't ask again for 10 minutes** (a checkbox in the confirmation) skips the question for
  **snippet runs on that target only**. It lives in memory: it ends after 10 minutes, when
  Runlet quits, and when the target's settings are saved.
- **Project commands always ask**, every time: listing commands (which boots the
  application), each command run from the Commands panel, host commands that run on
  your Mac for that target, and a shell on the server.
- **Stricter defaults.** The Commands panel never lists a production target by itself, and
  Runlet doesn't look inside a production Docker container for facts (it reads the local
  folder instead). SSH hosts never connect by themselves anyway.

## Troubleshooting

Runlet explains `ssh` failures in plain words and keeps OpenSSH's message below:

| Message | What to do |
| --- | --- |
| isn't in your known hosts yet | Click **Connect…** and compare the fingerprint OpenSSH shows with the server's. |
| The host key … changed | Find out why. If the server was rebuilt, remove the old key with `ssh-keygen -R <host>` in Terminal, then Connect… to check the new one. |
| didn't accept a key from your SSH agent or key files | Check `ssh <host>` in Terminal. If the server needs a password or a code, switch the profile's authentication to Password or two-factor code and Connect…. |
| Not connected / The login … has ended | Click **Connect…**. |
| could not be resolved / couldn't reach | Check the host, your VPN, and your network. |
| The directory … doesn't exist | Fix the profile's directory; Test Connection lists the applications it finds. |
| PHP was not found as … | Set the PHP executable; Test Connection lists the PHP binaries it finds. |
| Docker was not found on … | Set the profile's Docker command (an absolute path), or install Docker on the server. |
| may not use Docker (permission denied on the Docker socket) | Add the login to the `docker` group, or set the Docker command to `sudo -n docker` if passwordless sudo is allowed. |
| Several running containers … match | Choose the container in the sheet that opens; it stays chosen while it runs. |
| The SSH session … ended before the runner finished | The connection dropped, or PHP was killed on the server (for example by the out-of-memory killer). |

## What Runlet stores

- The profile in `State/targets.json`: host, overrides, directory, PHP, options, and the
  local folder. No keys, passwords, or passphrases, ever.
- Control sockets in `~/Library/Application Support/Runlet/SSH/<8 hex>.sock` (a 0700 folder).
  macOS limits socket paths to 104 bytes, so a data folder with a very long path falls back
  to a folder in your per-user temporary directory.
- Workspace files (`.runlet`) name the host and directory of SSH tabs, which are
  infrastructure details but no secrets.

## For developers

- Code: `RunletCore/SSHProfile.swift` (profile, endpoint, control paths),
  `RunletCore/ProductionGuard.swift` (the production confirmation rules),
  `RunletExecution/SSH.swift` (`SSHClient`, `RemoteShell`, `SSHFailure`, `SSHExecAdapter`,
  `RemoteSignal`), `SSHProbe.swift`, `LocalCheckout.swift` (drift and folder suggestions),
  `SSHConfigHosts.swift`, and in the app `AppModel+SSH.swift`, `AppModel+Production.swift`,
  `Features/SSHProfileEditor.swift`, `SSHConnectionViews.swift`, and `ProductionViews.swift`.
  The design and the later milestones are in
  [next-release-ideas.md §3](next-release-ideas.md#3-ssh-targets--design-proposal).
- Tests: `SSHUnitTests`, `SSHModelTests`, `LocalCheckoutTests`, and `ProductionGuardTests`
  (no server), and `SSHRunTests`, which start the disposable
  `runlet-fixtures` service `ssh` (OpenSSH + PHP 8.4 on `127.0.0.1:2222` only; see
  `Tests/Fixtures/docker/ssh/`). They generate a throwaway key per run, pass their own config
  with `ssh -F`, use their own `known_hosts` and no agent, and never read `~/.ssh`. The
  remote-Docker tests install `Tests/Fixtures/docker/ssh/fake-docker` as the fixture's
  `docker` (with made-up containers that are folders of the fixture), so no Docker runs
  inside the fixture and no real container is touched.
- Debug builds read `RUNLET_SSH_CONFIG`: a config file used instead of `~/.ssh/config` (for
  screenshots and checks that must not touch your own SSH setup), and
  `RUNLET_SSH_EXECUTABLE`: a program used instead of `/usr/bin/ssh`. For screenshot tours,
  `Tests/Fixtures/fake-ssh/ssh` is a "loopback" fake: it answers `ssh -G` with made-up
  values, keeps a fake shared connection (a Unix socket) for Connect… (after a made-up
  password prompt) and Disconnect, and runs everything else **on this Mac**, so tour profiles
  point their directory at a local fixture folder. It never reads `~/.ssh` or opens a network
  connection. `VisualTourUITests` uses it with a made-up config.
