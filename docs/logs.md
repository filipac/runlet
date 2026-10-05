# Log Viewer

The Logs window shows a target's logs next to the scratchpad: Laravel's, Symfony's, WordPress's, a project driver's, or a container's output. It reads Monolog entries with their stack traces, filters them by level, words, or the last run, follows new lines as they're written, and opens stack frames in your editor.

Reading logs never runs code. Files on your Mac are read directly. A log in a container or on a server is read only after you click **Follow**, and only with `tail` or `docker logs`.

<!-- screenshot: the Logs window on a Laravel project, with the source list, an error entry opened with its stack trace, and Last Run on -->

## Opening the Logs Window

- Choose **View ▸ Logs** (<kbd>⌘</kbd><kbd>L</kbd>), or **Logs** in Open Anything (<kbd>⌘</kbd><kbd>P</kbd>) or the command palette (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>P</kbd>).
- In the run inspector's **Log** section, click **Show in Logs Window**. It opens with **Last Run** on.

The window opens on the current tab's target; the menu at its top left switches to another target. The sources are on the left, the entries on the right. There is one Logs window.

## Where Logs Come From

| Target | Sources |
| --- | --- |
| Local project, Laravel sandbox | Files in the project folder: `storage/logs/**/*.log` (four folders deep), `var/log/**/*.log`, `wp-content/debug.log`, and the files a project driver declares. |
| Docker profile with a local folder | The same files in the local folder, which the container mounts. After **Follow**: **Container output** (`docker logs`), and files inside the container. |
| Docker profile without a local folder | After **Follow**: Laravel's, Symfony's, and WordPress's usual log files under the profile's working directory, the driver's files, and **Container output**. Files that may not exist are marked *If it exists*. |
| SSH profile | After **Follow**: the same files under the profile's directory on the server. |
| SSH profile with a container | After **Follow**: files in the container on the server, and its **Container output**. |

An SSH profile's local folder is a copy of the project, so its logs are your Mac's, not the server's: the Logs window doesn't list them.

- **Find Logs** looks for more `*.log` files in the container or on the server: in `storage/logs` and `var/log` (four folders deep), `wp-content/debug.log`, and the driver's folders. It reads file names only, and asks first like **Follow** does.
- **Other Path…** opens a file Runlet doesn't know: relative to the project folder on your Mac, or an absolute path in the container or on the server.

### A Project Driver's Log Files

A [project driver](drivers.md#log-paths) can declare where its application logs. Runlet learns them when it lists the target's commands (**Library ▸ Show Project Commands**), and remembers them, also after a relaunch. The Logs window never asks the driver by itself, because that would boot the application.

When a project has a `.runlet` driver whose log files aren't known yet, the window offers **Load the Driver's Log Paths**. That lists the project's commands as the Commands panel does, and production targets ask first.

## Reading and Following

### Files on Your Mac

A file opens at its end: the last 512 KB, and the list says so when the file is larger. Then Runlet watches it, and new lines appear as they're written. Rotations and truncations are handled:

- **Truncated** (`> laravel.log`, or `copytruncate`): the file is read from its start again, with a note.
- **Rotated** (renamed away and created again): the old file's last lines come first, then the new file, with a note.
- **Removed:** noted, and the path is watched until a file is there again.

**Stop** ends the watching, and **Follow** starts it again from where it stopped. **Reload** reads the end of the file again.

### Containers and Servers

A log in a container or on a server is read only after you click **Follow**. Runlet then runs `tail -F` there (through `docker exec`, or your SSH connection), or `docker logs --follow` for **Container output**, starting with the last 500 lines.

**Stop**, closing the Logs window, or quitting Runlet ends the command there too: nothing keeps running in the container or on the server.

Before a follow, and before **Find Logs**:

- **An SSH host that isn't connected** asks first. Hosts that log in with an agent or keys then connect the way runs do; for a password or a two-factor code, **Connect…** opens a terminal, and you click **Follow** again once you're logged in.
- **A production target** asks: *Follow this log on production?* Following only reads, but log lines can hold personal data and secrets. Files on your Mac never ask, since nothing connects.

While a follow runs, the [Connection Manager](connections.md) lists it under **Log Follows**, and its **Close** is the same as **Stop**.

## Entries

Runlet reads these formats:

| Format | Example |
| --- | --- |
| Monolog's line format (Laravel, Symfony) | `[2026-10-04 10:22:33] local.ERROR: Division by zero {"exception":"[object] (…)` |
| Monolog's JSON format, and other JSON loggers | `{"message":"Job failed","level_name":"ERROR","channel":"queue","datetime":"…"}` |
| PHP's error log (WordPress's `debug.log`) | `[04-Oct-2026 10:22:33 UTC] PHP Warning:  Undefined variable …` |
| Anything else | `WARNING: [pool www] child 12 said into stderr` |

A row shows the time, level, channel, and message, with the context dimmed. Stack traces and continuation lines belong to their entry. Click a row to open the entry: its message, its context (indented when it's JSON), and its extra fields.

- **Copy Entry** (the row's button or context menu) copies the entry exactly as it is in the file. The context menu also has **Copy Message**, **Copy Context**, and **Open** for the first stack frames.
- The window keeps the last 5,000 entries. The footer counts the older ones it dropped.

## Filtering

- **Level:** *Error and Up* shows errors, critical, alert, and emergency entries. *All Levels* also shows lines without a level.
- **Search:** every word you type must appear in the entry, its trace, or its context, in any case.
- **Last Run:** only what the last run on the target wrote, from any tab. For a file on your Mac, that's the part of the file the run added, so it works whatever time zone your application logs in. For a follow, it's the lines that arrived during the run.

**Pause** keeps the list still while a follow goes on reading, and the footer counts the new entries; **Resume** shows them. **Clear** empties the list. The log itself is never changed.

> [!NOTE]
> Last Run marks where the files end when a run starts once the Logs window has been opened in this session. Before that, or for a log that isn't followed, Last Run shows the entries whose time falls within the run. Laravel writes times without a time zone, which Runlet reads in your Mac's time zone, so an application that logs in UTC may not match.

## Opening Stack Frames

File locations in an open entry are links: `#3 /app/User.php(42): …`, `at /app/User.php:42`, `/app/User.php on line 42`, and JSON's `"file": "/app/User.php:42"`. Paths in a container or on a server map to the profile's local folder.

- **A project file** opens at its line in your editor (**Settings ▸ Editor**).
- **Vendor code, a file outside the project, or any file when no editor is set** opens in a read-only peek next to the entry, with **Open in** your editor and **Reveal in Finder**. For Docker and SSH targets, the peek says it shows the local copy, and where the target sees the file.
- **A snippet's own line** (`eval()'d code(5)`) opens in the latest tab that ran on the target.
- A location with no counterpart on your Mac stays plain text.

## Privacy

Log lines can contain secrets. They stay in the Logs window: Runlet doesn't save them, doesn't write them to its Run Log, and doesn't give them to AI clients.

## Not Included Yet

- `docker logs` lines are shown as the container wrote them, without Docker's timestamps.
- One source follows at a time.

## For developers

The log viewer was added in [#20](https://github.com/filipac/runlet/issues/20); a driver's log paths without the Commands panel first, and remembered across launches, in [#271](https://github.com/filipac/runlet/issues/271).

### Following

Files on this Mac are watched with a kqueue watcher on the file and its folder, plus a check every two seconds for file systems that send no events. Only what was added is read; a burst of more than 4 MB is read from its last 4 MB, with a note.

| Source | Command |
| --- | --- |
| Container output, Docker profile | `docker logs --follow --tail 500 <container>` |
| File in a Docker profile's container | `docker exec -i [--user <profile user>] <container> /bin/sh -c 'tail -n 500 -F -- <path> …'` |
| File on an SSH host | `ssh … <host> /bin/sh -c 'tail -n 500 -F -- <path> …'`, through the profile's shared connection |
| File in a container on an SSH host | `ssh … <host> /bin/sh -c 'exec docker exec -i <container> /bin/sh -c …'` |
| Container output on an SSH host | `ssh … <host> /bin/sh -c 'docker logs --follow --tail 500 <container> …'` |

The container is the one runs use (the profile's identity); when it needs a choice, run a snippet once to choose it. Each command reads its standard input, which Runlet keeps open while following. Stop closes it: the command then kills its own `tail`, and Runlet ends the local `docker` or `ssh` client after a moment. Killing only the client wouldn't be enough: without a terminal a remote `tail` gets no hang-up, and a process started with `docker exec` outlives its client. The shared SSH connection stays for the profile's other work.

Without a local folder, a Docker profile lists `storage/logs/laravel.log`, `var/log/prod.log` and `dev.log`, and `wp-content/debug.log` as *If it exists*, or only the framework's file once a run reported the framework.

### Parsing and Bounds

- Monolog's line format: time, channel, level, message, context, extra. Laravel's exception and its `[stacktrace]` lines, and any line that isn't a new entry, belong to the entry before.
- JSON: one entry per line; `msg`, `level` names, and `time`/`timestamp` of other JSON loggers are read too.
- PHP's error log: the level comes from PHP's error kind, as Monolog's error handler files them; `Stack trace:` and `#n` lines belong to the entry.
- Other lines: one entry per line, with a level when one is written near its start; indented and `#n` lines join it.
- Laravel's multi-line exception in the context is shown as written, with the JSON string's `\\` read as `\`.
- Memory: the last 5,000 entries, at most 2,000 lines and 256 KB per entry, 32 KB per line, and 48 MB in all.
- Last Run on a file: Runlet notes where the target's log files end when a run starts and ends, for the files the window found for that target, and reads that part again. For a follow, the lines that arrived during the run and two seconds after it.

### Code and Tests

| Piece | Where |
| --- | --- |
| Levels, entries, line classification, message/context split, frames, times | `RunletCore/LogParsing.swift` |
| The bounded entry buffer, filters, the run window | `RunletCore/LogBuffer.swift` |
| Tail reads, the file follower, discovery | `RunletCore/LogFiles.swift` |
| Remote command lines and the stoppable process follower | `RunletExecution/LogFollow.swift` |
| The driver hook | `Resources/Runner/src/Drivers.php` (`logPaths()`), `Runner.php` (`emitLogPaths`), `ProjectCommandCatalog.logPaths`; remembered as `DriverLogPathMemory` in `facts.json` |
| The window, sources, follows, run marks, Connection Manager rows | `Runlet/App/AppModel+Logs.swift`, `Runlet/Features/LogViewer.swift` |
| Frame links | `FrameSourceResolver` (`RunletCore/FrameSource.swift`, from [#8](https://github.com/filipac/runlet/issues/8)) and the peek (`ExcerptPeek`, `CodePeekView` in `Runlet/Features/SourceExcerptViews.swift`) |
| Debug steps and screenshots | `Runlet/App/LogDebugSteps.swift` (`logs-load-driver`, `logs-wait:commands`, `logs-state`), `scripts/logs-screenshots.py` |

Tests: `LogViewerTests.swift` (parsing of the line, JSON, and PHP error formats, malformed input, offsets, bounds, filters; tail reads; following with truncation, rotation, and removal on temporary files; discovery), `LogFollowTests.swift` (the command lines; live follows that check nothing is left running: a shell on this Mac, `docker exec … tail -F` and `docker logs` in the runlet-fixtures Laravel container, `ssh … tail -F` and Find Logs on the runlet-fixtures SSH host), `DriverLogPathsTests.swift`, and the fixtures-only Docker wrapper's `logs` in `FixturesOnlyDockerTests.swift`.
