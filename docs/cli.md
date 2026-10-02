# The `runlet` command

`runlet` opens folders, PHP files, and workspaces in Runlet from a terminal. It only opens them: nothing runs until you press Run, and the tool itself never runs PHP.

## Install

Runlet ▸ Install Command-Line Tool… (also in Settings ▸ General ▸ Command-Line Tool, and in the Command Palette). Pick a folder and press Install. Runlet creates one symbolic link, `<folder>/runlet`, to the tool inside the app (`Runlet.app/Contents/Helpers/runlet`), and nothing else:

| Folder | Notes |
| --- | --- |
| `/usr/local/bin` | On every shell's `PATH` by default. If the folder isn't writable by you (the usual case without Homebrew on Intel), macOS asks for an administrator password; the privileged step only creates the folder and the link. |
| `~/.local/bin` | No password. The window says whether it's on your shell's `PATH` and, if not, which line to add to `~/.zprofile` (`export PATH="$HOME/.local/bin:$PATH"`). |
| Another folder… | Any folder you choose, with the same checks. |

The window shows exactly which link it will create. It never replaces a file that isn't Runlet's link; a link to another copy of Runlet is replaced only when you press Replace. Remove Link deletes the link (only if it is one). Because the command is a link into the app, it follows updates of that copy; if you move Runlet.app, install again. Run Runlet from the Applications folder first: macOS runs a freshly downloaded app from a temporary location, and the window refuses to link to that.

To install by hand instead:

```bash
ln -s /Applications/Runlet.app/Contents/Helpers/runlet ~/.local/bin/runlet
```

## Use

```text
runlet                       open the current folder as a project (same as `runlet .`)
runlet <folder>              open a folder as a local project in a new tab
runlet <file.php>            open a file in a tab; saving writes back to it
runlet <name.runlet>         open a workspace in its own window
runlet -t <target> <file>    open files on a target
runlet -t <target>           open a new tab on a target
runlet -n …                  open in a new window
runlet --help | --version
```

- **Folders** become local projects, the same as Open Project…: an already saved project for that folder is reused. The project opens in the current tab when that tab is blank (only `<?php` or nothing, no file), otherwise in a new tab. Your home folder and `/` are refused, because PHPantom would index all of it.
- **Files** open as with Finder: a file that is already open gets its tab selected. The tab follows the file on disk (see the CHANGELOG entry "Tabs follow their files on disk").
- **Workspaces** (`.runlet`) open in their own window and keep their tabs' targets; `--target` can't be combined with them or with folders.
- **`--target`** takes `sandbox`, a local project's name or folder path, or a Docker profile's name, ignoring case. An exact name wins, then a unique prefix (`-t acme`). When a project and a profile share a name, write `local:<name>` or `docker:<name>`. Relative paths are resolved in the current folder.
- Several paths open in order. Paths are resolved against the shell's current folder (`$PWD`, so symbolic links are kept as typed).
- `-` (code from standard input) is not supported yet (N35, [#38](https://github.com/filipac/runlet/issues/38)).

Exit status: 0 when everything opened; 1 when Runlet reported a problem (printed as `runlet: …`) or didn't answer within 60 seconds; 64 for a usage error; 69 when Runlet.app can't be found.

## How it reaches the app

The tool finds the Runlet.app it belongs to by following its own link (falling back to the copy Launch Services knows by bundle ID, `dev.runlet.Runlet`), and resolves every path itself, so Runlet only receives absolute paths.

- **Runlet is running:** the tool posts the request (`OpenRequest`, as JSON) as the distributed notification `dev.runlet.Runlet.cli.open`, addressed to that process's ID, and repeats it every half second until Runlet answers with `dev.runlet.Runlet.cli.opened` (`OpenReply`: the request's ID and any errors). Then it brings Runlet forward through Launch Services, like `open -a`. Distributed notifications stay within your login session; no Apple events are sent, so macOS doesn't ask for Automation access.
- **Runlet isn't running:** the tool launches it through Launch Services with the request as a launch argument (`--runlet-open-request <json>`) and waits for the same answer. `RUNLET_DATA_DIR`, when set, is passed on.
- Runlet handles each request ID once (repeats are answered again without opening anything twice), only in the process the request names, and only after its first window is up, like files opened from Finder. If opening a workspace needs your confirmation first, the answer waits for it.

The parsing, the request and reply formats, target matching, and the install rules are in RunletCore (`CommandLineTool.swift`, `CommandLineInstall.swift`) with package tests. The app side is `Runlet/App/CommandLineRequests.swift`; the tool is the `RunletCLI` target (`RunletCLI/RunletTool.swift`, product `runlet`), copied into `Contents/Helpers` by the app target and signed with it.

## Testing

Never install into your real `PATH` while testing. The checks used during development:

- `swift test --filter "CommandLineTool|CommandLineInstall"` in `Packages/RunletKit` (temporary folders only).
- `Runlet.app/Contents/Helpers/runlet --help`, `--version`, and argument errors work without the app.
- `RUNLET_CLI_PID=<pid> runlet …` sends requests only to that Runlet process (for example a Debug build started with `RUNLET_DATA_DIR` pointing at scratch data) and doesn't bring it forward.
- Debug builds: `RUNLET_DEBUG_CLI_FOLDER=<scratch folder>` preselects that folder in the install window, so `RUNLET_DEBUG_STEPS` can press Install (`click:cli-install`) and Remove Link (`click:cli-uninstall`) there.
