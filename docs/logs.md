# Log viewer

The Logs window shows a target's logs next to the scratchpad: Laravel's, Symfony's, WordPress's,
a project driver's, or a container's output. It parses Monolog entries, groups stack traces into
their entry, filters by level, search, and the last run, follows new lines as they're written,
and opens stack frames in your editor ([#20](https://github.com/filipac/runlet/issues/20)).

Reading logs never runs code. Files on this Mac are read directly. A log in a container or on a
server is read only after you click **Follow**, and only with `tail -F` or `docker logs`; Stop,
or closing the window, ends it there too.

## Opening it

- **View ▸ Logs** (⌘L), or **Logs** in Open Anything (⌘P) and the command palette (⇧⌘P).
- The run inspector's **Log** section has **Show in Logs Window**, which opens it with **Last Run** on.

The window opens on the current tab's target; the menu at its top left switches to any other
target. There is one Logs window. Its source list is on the left, the entries on the right.

## Where logs come from

| Target | On This Mac | In the container or on the server (after Follow) |
| --- | --- | --- |
| Local project, sandbox | `storage/logs/**/*.log` (nested folders, four deep), `var/log/**/*.log`, `wp-content/debug.log`, and the driver's [`logPaths()`](drivers.md#log-paths), in the project folder. | — |
| Docker profile with a local folder | The same files in the local folder, which is the container's bind mount. | **Container output** (`docker logs`), files Find Logs found, and absolute container paths typed in Other Path…. |
| Docker profile without a local folder | — | `storage/logs/laravel.log`, `var/log/prod.log` and `dev.log`, `wp-content/debug.log` (marked *If it exists*, or only the framework's once a run reported it), the driver's paths, Find Logs' results, and **Container output**. Paths are under the profile's working directory. |
| SSH profile | — | The same files under the profile's directory on the server, followed with `ssh … tail -F`. |
| SSH profile with a container step | — | Files in the container on the server (`docker exec -i … tail -F` through SSH), and **Container output** there. |

An SSH profile's local folder is a copy of the project, so its logs are this Mac's, not the
server's: the viewer doesn't list them.

- **Find Logs** lists the `*.log` files of `storage/logs` and `var/log` (four folders deep),
  `wp-content/debug.log`, and the driver's folders in the container or on the server. It reads
  file names only (`find`), and asks like Follow does (below).
- **Other Path…** opens a file Runlet doesn't know: relative to the project folder on this Mac, or
  absolute (in the container, or on the server).
- A driver's `logPaths()` comes from the target's last **Commands** list (Library ▸ Commands).
  The Logs window never asks the driver itself, since that would boot the application.

## Reading and following

**Files on this Mac** are read from their end, at most the last 512 KB (the list says so when the
file is larger), and then watched right away: a kqueue watcher on the file and its folder, plus a
check every two seconds for file systems that send no events. The watcher reads only what was
added:

- appended lines appear at once (a burst of more than 4 MB is read from its last 4 MB, with a note);
- **truncation** (`copytruncate`, `> laravel.log`): the file is read from its start again, with a note;
- **rotation** (the file renamed away and a new one created): the old file's last unread lines
  come first, then the new file from its start, with a note;
- **removal**: noted; the path is watched until a file is there again.

Stop ends the watching; Follow starts it again from where it stopped. Reload reads the end again.

**Containers and servers** are read only after **Follow**:

| Source | Command |
| --- | --- |
| Container output, Docker profile | `docker logs --follow --tail 500 <container>` |
| File in a Docker profile's container | `docker exec -i [--user <profile user>] <container> /bin/sh -c 'tail -n 500 -F -- <path> …'` |
| File on an SSH host | `ssh … <host> /bin/sh -c 'tail -n 500 -F -- <path> …'` through the profile's shared connection |
| File in a container on an SSH host | `ssh … <host> /bin/sh -c 'exec docker exec -i <container> /bin/sh -c …'` |
| Container output on an SSH host | `ssh … <host> /bin/sh -c 'docker logs --follow --tail 500 <container> …'` |

The container is the one runs use (the profile's identity); when it needs a choice, run a
snippet once to choose it. Each command reads its standard input, which Runlet keeps open while
following. **Stop** (or closing the Logs window, or quitting) closes it: the command then kills its
own `tail`, and Runlet ends the local `docker` or `ssh` client after a moment. Killing only the
client wouldn't be enough: without a terminal a remote `tail` gets no hang-up, and a process
started with `docker exec` outlives its client. The shared SSH connection stays for the
profile's other work.

Before a remote follow (and Find Logs):

- an SSH profile that isn't connected asks first, as a saved connection's tunnel does: agent and
  key profiles then connect the way their runs do; password and 2FA profiles open Connect… in a
  terminal, and you click Follow again once logged in;
- a **production** target asks: *Follow this log on production?* It reads only, but log lines can
  hold personal data and secrets. Files on this Mac never ask: nothing connects.

While a remote follow runs, the [Connection Manager](connections.md) lists it under **Log
Follows** (with the SSH connection it uses), and its **Close** is Stop.

## Entries

| Format | Example | Read as |
| --- | --- | --- |
| Monolog line format | `[2026-10-04 10:22:33] local.ERROR: Division by zero {"exception":"[object] (…)` | Time, channel, level, message, context, extra. Laravel's exception and its `[stacktrace]` lines, and any line that isn't a new entry, belong to the entry before. |
| Monolog JSON formatter | `{"message":"Job failed","context":{…},"level":400,"level_name":"ERROR","channel":"queue","datetime":"…"}` | One entry per line; also `msg`, `level` names, and `time`/`timestamp` of other JSON loggers. |
| PHP's error log (WordPress `debug.log`) | `[04-Oct-2026 10:22:33 UTC] PHP Warning:  Undefined variable …` | Level from PHP's error kind (as Monolog's error handler files them); `Stack trace:` and `#n` lines belong to it. |
| Anything else | `WARNING: [pool www] child 12 said into stderr` | One entry per line, with a level when one is written near its start; indented and `#n` lines join it. |

A row shows the time, the level, the channel, the message, and the context dimmed. A click opens
an entry: its message, its context (indented when it is JSON; Laravel's multi-line exception as
written, with the JSON string's `\\` read as `\`), and its extra. **Copy Entry** (the row's button
or context menu) copies the entry exactly as it is in the file; the context menu also has Copy
Message, Copy Context, and Open for its first frames.

**Memory is bounded**: the last 5,000 entries are kept (the footer counts the older ones
dropped), at most 2,000 lines and 256 KB per entry, 32 KB per line, and 48 MB in all.

## Filters

- **Level**: *Error and Up* shows error, critical, alert, and emergency. *All Levels* also shows
  lines without a level.
- **Search**: every word must appear in the entry (its trace and context too), in any case.
- **Last Run**: the logs written by the last run on the target, from any tab:
  - for a file on this Mac, the part of the file the run added: Runlet notes where the target's
    log files end when a run starts and ends, and reads that part again. This needs no times, so
    it works whatever time zone the application logs in. It is noted once the Logs window has been
    opened in this session, for the files it found for that target;
  - for a remote follow, the lines that arrived while following during the run (and two seconds
    after it);
  - otherwise, entries whose own time falls in the run. Times without a zone (Laravel's default)
    are read in this Mac's time zone, so an application that logs in UTC may not match.

**Pause** keeps the list still while a follow goes on reading (the footer counts the new
entries); **Resume** shows them. **Clear** empties the list; the log itself is never changed.

## Stack frames

File locations in an open entry are links: `#3 /app/User.php(42): …`, `at /app/User.php:42`,
`/app/User.php on line 42`, and the JSON formatter's `"file": "/app/User.php:42"`. A link opens
the file at its line in the external editor (Settings ▸ Editor; with none, Finder shows it),
through the same path mapping as the output's file links: a container's or server's path opens
in the profile's local folder. A location with no counterpart on this Mac stays plain text. A
snippet's own line (`… : eval()'d code(5)`) opens the line in the latest tab that ran on the
target.

## Privacy

Log lines can contain secrets. They stay in the Logs window: Runlet doesn't save them, doesn't
write them to its own Run Log, and doesn't give them to AI clients (there is no MCP tool for
logs).

## Not included

- Frames don't open the read-only peek of [code navigation](navigation.md), which belongs to an
  editor; they open the external editor.
- `docker logs` lines are shown as the container wrote them, without Docker's timestamps.
- Following several logs at once: one source follows at a time.

## For developers

| Piece | Where |
| --- | --- |
| Levels, entries, line classification, message/context split, frames, times | `RunletCore/LogParsing.swift` |
| The bounded entry buffer, filters, the run window | `RunletCore/LogBuffer.swift` |
| Tail reads, the file follower, discovery | `RunletCore/LogFiles.swift` |
| Remote command lines and the stoppable process follower | `RunletExecution/LogFollow.swift` |
| The driver hook | `Resources/Runner/src/Drivers.php` (`logPaths()`), `Runner.php` (`emitLogPaths`), `ProjectCommandCatalog.logPaths` |
| The window, sources, follows, run marks, Connection Manager rows | `Runlet/App/AppModel+Logs.swift`, `Runlet/Features/LogViewer.swift` |
| Debug steps and screenshots | `Runlet/App/LogDebugSteps.swift`, `scripts/logs-screenshots.py` |

Tests: `LogViewerTests.swift` (parsing of the line, JSON, and PHP error formats, malformed
input, offsets, bounds, filters; tail reads; following with truncation, rotation, and removal on
temporary files; discovery), `LogFollowTests.swift` (the command lines; live follows that check
nothing is left running: a shell on this Mac, `docker exec … tail -F` and `docker logs` in the
runlet-fixtures Laravel container, `ssh … tail -F` and Find Logs on the runlet-fixtures SSH host),
`DriverLogPathsTests.swift`, and the fixtures-only Docker wrapper's `logs` in
`FixturesOnlyDockerTests.swift`.
