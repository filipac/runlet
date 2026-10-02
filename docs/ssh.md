# SSH targets

Runlet can run snippets with a server's own PHP, in the application's folder on the server,
over SSH. An SSH target works like a local project or a Docker profile: pick it in the
target menu (or with ⌘P), press Run, and the output, dumps, errors, and Stop behave the
same.

This guide covers what is available today: plain SSH hosts from `~/.ssh/config`, including
jump hosts, with keys, agents, passwords, or two-factor codes. Running inside a Docker
container on a remote host, remote project commands and shells, and a combined profiles
window come later (see [next-release-ideas.md §3.15](next-release-ideas.md#315-implementation-plan)).

## Create a profile

Use **Library ▸ New SSH Profile…** (also in the target menu and the command palette).

| Field | What to enter |
| --- | --- |
| Name | Shown in the target menu, tabs, and history. |
| Host | An alias from `~/.ssh/config` (the list button shows them) or a host name. Runlet passes it to `ssh` unchanged, so your config's `HostName`, `User`, `Port`, `ProxyJump`, `IdentityFile`, and `IdentityAgent` apply. Below the field, Runlet shows what `ssh -G` says the alias resolves to (this reads the config; it doesn't connect). |
| Override user, port, or jump host | Optional. Leave empty to use `~/.ssh/config`. |
| Directory | The application's folder on the server, as an absolute path, e.g. `/home/forge/example.com/current`. A symlink is fine. |
| PHP executable | `php`, a name such as `php8.3`, or an absolute path. Test Connection lists the PHP binaries it finds. |
| Authentication | **SSH agent, 1Password, or key files**, or **Password or two-factor code**. See [Logging in](#logging-in). |
| Keep connection | Agent and key profiles only: how long the shared connection stays open after the last run (10 minutes by default). |
| Compress the connection | `ssh -C`, on by default. Each run sends Runlet's runner (about 830 KB), which compresses well. |
| Local folder | The project's checkout on your Mac. See [Local folder](#local-folder). |
| Strict types, PHP version for completion | As for local projects and Docker profiles. |

Saving, opening, or switching to a profile never connects to the server, and neither does
launching Runlet or restoring tabs. Runlet connects only when you press **Run**, **Test
Connection**, or **Connect…**, or list commands.

## How a run works

Runlet uses the system OpenSSH client, `/usr/bin/ssh`, so everything works as it does in
your terminal. For each run it starts:

```text
ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes … -S <control socket> -- <host> \
    "/bin/sh -c 'cd <directory> && export RUNLET_RUN_ID=<id> && exec <php> -d display_errors=stderr …'"
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
**Keep connection** time without use. With 1Password, approve the request in 1Password's
window.

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

## Stop

Stop works like Stop for a Docker container: Runlet waits for the runner's process ID,
then runs a small PHP program over a second SSH session that signals only processes whose
environment carries this run's `RUNLET_RUN_ID`, the runner and anything the snippet
started, even if they left its process group. It sends `SIGTERM`, waits 1.5 seconds,
sends `SIGKILL`, waits 3 seconds, then checks.

Stop needs Linux `/proc`. On a server without it (BSD, macOS), Runlet signals nothing it
can't verify and reports the stop as unconfirmed: PHP may keep running until it finishes.

## Local folder

The local folder is the project's checkout on your Mac. Without one, the profile works in
limited mode: completion knows only PHP itself, and file paths in output stay plain text.

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
  `RunletExecution/SSH.swift` (`SSHClient`, `RemoteShell`, `SSHFailure`, `SSHExecAdapter`,
  `RemoteSignal`), `SSHProbe.swift`, `SSHConfigHosts.swift`, and in the app
  `AppModel+SSH.swift` and `Features/SSHProfileEditor.swift`.
- Tests: `SSHUnitTests` (no server) and `SSHRunTests`, which start the disposable
  `runlet-fixtures` service `ssh` (OpenSSH + PHP 8.4 on `127.0.0.1:2222` only; see
  `Tests/Fixtures/docker/ssh/`). They generate a throwaway key per run, pass their own config
  with `ssh -F`, use their own `known_hosts` and no agent, and never read `~/.ssh`.
- Debug builds read `RUNLET_SSH_CONFIG`: a config file used instead of `~/.ssh/config` (for
  screenshots and checks that must not touch your own SSH setup).
