# Command-Line Tool

The `runlet` command opens folders, PHP and SQL files, and workspaces in Runlet from a terminal:

```sh
cd ~/Code/my-app
runlet .
```

It only opens them: nothing runs until you press Run, and the command itself never runs PHP. `runlet mcp` is different: it serves [AI clients](mcp.md), which can ask Runlet to run code, and every such run waits for your approval in Runlet.

## Installing the Tool

Choose **Runlet ▸ Install Command-Line Tool…** (also in **Settings ▸ General ▸ Command-Line Tool**, and in the command palette). Pick a folder and press **Install**. Runlet creates one symbolic link, `<folder>/runlet`, to the tool inside the app, and nothing else.

| Folder | Notes |
| --- | --- |
| `/usr/local/bin` | On every shell's `PATH`. When you can't write to it (usual on Intel Macs without Homebrew), macOS asks for an administrator's password, used only to create the folder and the link. |
| `~/.local/bin` | No password. The window says whether it's on your shell's `PATH` and, if not, which line to add to `~/.zprofile`. |
| Another folder… | Any folder you choose, with the same checks. |

The window shows exactly which link it creates.

- It never replaces a file that isn't Runlet's link. A link to another copy of Runlet is replaced only when you press **Replace**.
- **Remove Link** deletes the link (only if it is one).
- The link points into the app, so the command follows updates. If you move Runlet.app, install it again.

> [!NOTE]
> Open Runlet from the Applications folder before you install the tool. macOS runs a freshly downloaded app from a temporary location, and Runlet won't link to that.

To install it by hand instead:

```sh
ln -s /Applications/Runlet.app/Contents/Helpers/runlet ~/.local/bin/runlet
```

## Opening Folders and Files

```text
runlet                       open the current folder as a project (same as `runlet .`)
runlet <folder>              open a folder as a local project
runlet <file.php>            open a file in a tab; saving writes back to it
runlet <query.sql>           open an SQL file in an SQL tab
runlet <name.runlet>         open a workspace in its own window
runlet -t <target> <file>    open files on a target
runlet -t <target>           open a new tab on a target
runlet -n …                  open in a new window
runlet mcp                   serve AI clients over MCP
runlet --help | --version
```

- **Folders** open as local projects, the same as **File ▸ Open Project…**. A project you already have for that folder is reused. It opens in the current tab when that tab is blank, and in a new tab otherwise. Your home folder and `/` are refused: indexing all of it for completion would take too long.
- **Files** open as from Finder: a file that's already open gets its tab selected. The tab follows the file on disk, and saving writes back to it. `.sql` files open in [SQL tabs](sql-tabs.md).
- **Workspaces** (`.runlet` files) open in their own window, with their tabs' targets.
- **Several paths** open in order. Paths are relative to the current folder, with symbolic links kept as you typed them.

### Choosing a Target

`-t` (or `--target`) opens files, or a new tab, on a target other than the current one:

```sh
runlet -t staging scripts/fix-orders.php
runlet -t docker:shop
```

It takes `sandbox`, a local project's name or folder, or a Docker or SSH profile's name, ignoring case:

- An exact name wins, then a unique prefix (`-t acme`).
- When several targets share a name, write `local:<name>`, `docker:<name>`, or `ssh:<name>`.
- Opening a file on an SSH target never connects to the server.

`--target` can't be combined with folders or workspaces.

### Exit Status

| Status | Means |
| --- | --- |
| `0` | Everything opened. |
| `1` | Runlet reported a problem (printed as `runlet: …`), or didn't answer within 60 seconds. |
| `64` | The command was used wrongly. |
| `69` | Runlet.app couldn't be found. |

> [!NOTE]
> Reading code from standard input (`runlet -`) isn't supported yet.

## AI Clients

`runlet mcp` is an [MCP](https://modelcontextprotocol.io) server for AI clients such as Claude Code and Cursor. Add it to your AI client rather than running it yourself: **Settings ▸ AI Clients** shows the exact setup, and [AI Clients](mcp.md) explains it. Started by hand in a terminal, it explains this and exits.

To open a folder named `mcp`, write `runlet ./mcp`.

## For developers

`runlet -` (code from standard input) is N35, [#38](https://github.com/filipac/runlet/issues/38). The install window's checks were hardened in [#92](https://github.com/filipac/runlet/issues/92).

### Targets and Paths

- `<kind>:<id>` names one target by its id. Relative paths in `--target` are resolved in the current folder.
- Paths are resolved against the shell's current folder (`$PWD`), so Runlet only receives absolute paths.
- A tab blank enough for a folder to open in it holds only `<?php` or nothing, and no file.
- Your home folder and `/` are refused because PHPantom would index all of it.

### How It Reaches the App

The tool finds the Runlet.app it belongs to by following its own link (falling back to the copy Launch Services knows by bundle ID, `dev.runlet.Runlet`), and resolves every path itself.

- **Runlet is running:** the tool posts the request (`OpenRequest`, as JSON) as the distributed notification `dev.runlet.Runlet.cli.open`, addressed to that process's ID, and repeats it every half second until Runlet answers with `dev.runlet.Runlet.cli.opened` (`OpenReply`: the request's ID and any errors). Then it brings Runlet forward through Launch Services, like `open -a`. Distributed notifications stay within your login session; no Apple events are sent, so macOS doesn't ask for Automation access.
- **Runlet isn't running:** the tool launches it through Launch Services with the request as a launch argument (`--runlet-open-request <json>`) and waits for the same answer. `RUNLET_DATA_DIR`, when set, is passed on.
- Runlet handles each request ID once (repeats are answered again without opening anything twice), only in the process the request names, and only after its first window is up, like files opened from Finder. If opening a workspace needs your confirmation first, the answer waits for it.

`runlet mcp` talks to the app over a private Unix socket instead, because its requests and answers (code and output) don't fit notifications; see [mcp.md](mcp.md#security-model).

The parsing, the request and reply formats, target matching, and the install rules are in RunletCore (`CommandLineTool.swift`, `CommandLineInstall.swift`) with package tests. The app side is `Runlet/App/CommandLineRequests.swift`, and the install window is `Runlet/Features/CommandLineToolView.swift`. The tool is the `RunletCLI` target (`RunletCLI/RunletTool.swift`, product `runlet`), copied into `Contents/Helpers` by the app target and signed with it. Runlet Dev's `runlet` opens Runlet Dev.

### Testing

Never install into your real `PATH` while testing. The checks used during development:

- `swift test --filter "CommandLineTool|CommandLineInstall|MCPCatalog"` in `Packages/RunletKit` (temporary folders only; `MCPCatalogTests` covers SSH profiles, ids, and `ssh:` in `--target`).
- `Runlet.app/Contents/Helpers/runlet --help`, `--version`, and argument errors work without the app.
- `RUNLET_CLI_PID=<pid> runlet …` sends requests only to that Runlet process (for example a Debug build started with `RUNLET_DATA_DIR` pointing at scratch data) and doesn't bring it forward.
- Debug builds: `RUNLET_DEBUG_CLI_FOLDER=<scratch folder>` preselects that folder in the install window, so `RUNLET_DEBUG_STEPS` can press Install (`click:cli-install`) and Remove Link (`click:cli-uninstall`) there. With `ghost`, use `press:` instead of `click:` (ghosted windows ignore clicks); `press:settings-cli-install` is Settings' Install… button.
- `scripts/check-cli-window.sh <Debug Runlet.app>` opens the window from Settings and from the menu command, hidden and with scratch data, and checks that Runlet survives ([#92](https://github.com/filipac/runlet/issues/92)).
