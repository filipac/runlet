# AI Clients (MCP)

Runlet is a controlled way for AI tools to run PHP against your real projects. Claude Code, Claude Desktop, Cursor, and other [MCP](https://modelcontextprotocol.io) clients can propose PHP to run, while Runlet keeps every run visible and under your control. It isn't shell access for the agent: every run is a PHP snippet you have read, on a target you can see.

## How It Works

1. You turn it on in **Settings ▸ AI Clients** (it's off by default), and add `runlet mcp` to your client.
2. The client can list your targets and snippets, read and save snippets, and ask to run PHP.
3. Every run request opens a sheet in Runlet with the client's name, the target and its environment, where the code runs (a folder, a container, or `user@host:directory`), and all of the code. **Run** (<kbd>⌘</kbd><kbd>Return</kbd>) runs exactly that code on exactly that target. **Cancel** tells the client that nothing ran.
4. The client gets the output, dumps, result, and errors with their lines. The run also opens in a Runlet tab and is recorded in History.

![The approval sheet "Run code from Claude Code on production?", with the production warning, the client, the target, where the code runs, the code, and Cancel and Run on Production](screenshots/mcp/approval-sheet-light.webp#gh-light-mode-only)
![The approval sheet "Run code from Claude Code on production?", with the production warning, the client, the target, where the code runs, the code, and Cancel and Run on Production](screenshots/mcp/approval-sheet-dark.webp#gh-dark-mode-only)

> [!WARNING]
> Approved code runs with the same power as any snippet you run yourself. Read it as you would a pull request.

## Turning It On

Open **Settings ▸ AI Clients** and turn on **Allow AI clients to connect**. Until you do, AI clients can't reach Runlet; even then, nothing runs without your approval.

The same tab gives the exact client setup for your copy of Runlet, lists the connected clients, and shows any sandbox allowance you gave (and lets you revoke it). The [Connection Manager](connections.md#connection-manager) (**Window ▸ Connections**) lists connected clients too, and its **Close** drops one client's connection; that client connects again on its next call.

## Setting Up a Client

The server is the `runlet` command inside the app, started with `mcp`. The examples use `/Applications/Runlet.app`; **Settings ▸ AI Clients** shows the path of the copy you're running.

**Claude Code**, for every project:

```sh
claude mcp add --transport stdio --scope user runlet -- /Applications/Runlet.app/Contents/Helpers/runlet mcp
```

**Claude Desktop** reads `~/Library/Application Support/Claude/claude_desktop_config.json` (**Settings ▸ Developer ▸ Edit Config**). **Cursor** reads `~/.cursor/mcp.json` for every project, or `.cursor/mcp.json` in one. Add Runlet next to the servers already there, then restart the client:

```json
{
  "mcpServers": {
    "runlet": {
      "command": "/Applications/Runlet.app/Contents/Helpers/runlet",
      "args": ["mcp"]
    }
  }
}
```

Other MCP clients take the same command and argument. If you move Runlet.app, update the path.

- **When Runlet isn't running,** the client's first call starts it in the background. Starting Runlet never runs code: it restores your tabs without running them, and a run still waits for your approval.
- **When the setting is off,** calls fail with a message that asks you to turn it on in **Settings ▸ AI Clients**. The client can show you that message.

## What a Client Can Do

| Tool | What it does |
| --- | --- |
| `list_targets` | Lists the Laravel sandbox, local projects, Docker applications, and SSH hosts: each one's name, environment, folder, container, or host, how its runs are approved, and whether an SSH host is connected. Nothing is contacted to find out. |
| `list_snippets` | Lists your personal snippets, and a project's [shared snippets](project-snippets.md). It can search their labels, descriptions, and code. |
| `get_snippet` | Reads a snippet's code, label, description, and target. For a [snippet with inputs](snippet-inputs.md), it also lists the inputs, so the client can fill them in. |
| `add_snippet` | Saves a personal snippet, PHP or SQL. Nothing runs. |
| `run_php` | Asks you to approve a run, runs it, and returns the result. |
| `get_last_output` | The latest `run_php` run from any client: its output, or its progress while it still runs. |

Reading, listing, and saving never run code. Only an approved `run_php`, or a sandbox run you allowed for the session, does. `run_php` runs PHP only: never an SQL, Redis, or MongoDB tab.

**Targets** are named the way the [command-line tool](cli.md#choosing-a-target) names them: `sandbox`, `local:<name>`, `docker:<name>`, or `ssh:<name>`, ignoring case. A project can also be named by its folder. A name that matches several targets is an error that lists them, and `list_targets` always gives names that match exactly one.

**`run_php` results** read like the output pane: where the run happened, the PHP and framework versions, printed output, dumps with their lines, the value of the last expression, errors with their line in the code that was sent, your `\Runlet\notice()`, `warning()`, and `error()` cards, and how the run ended. The text is capped at 60,000 characters; the Runlet tab keeps everything. Results never include the [run inspector](run-inspector.md)'s sections (queries, mail, logs, HTTP requests, jobs, or events): they stay in Runlet's window ([What AI Clients Get](safety-and-privacy.md#what-ai-clients-get)). The code may start with `<?php` or not, and can be up to 200 KB, so the sheet can show all of it.

## Approving Runs

Every `run_php` request brings Runlet's window to the front with a sheet that shows:

- the client's name, as the client reports it (for your information; it never decides anything);
- the target, its environment badge, and where the code runs;
- all of the code.

**Run** (<kbd>⌘</kbd><kbd>Return</kbd>) runs exactly that code on exactly that target. **Cancel** (<kbd>Return</kbd> or <kbd>Esc</kbd>) tells the client you declined, and nothing runs.

### The Rules

- **The Laravel sandbox** is the only target that can skip the question. Tick **Allow sandbox runs from** *client* **for this session**, and that client's later sandbox runs go ahead without a sheet until it disconnects (for example, when you quit it or start a new session) or Runlet quits. Another client, or the same one after reconnecting, asks again.
- **Local projects and Docker applications** ask every time.
- **Production targets** ask every time, with a red warning and a **Run on Production** button. The production guard's 10-minute "don't ask again" never applies to AI clients.
- **SSH hosts are never connected silently.** When pressing Run would connect, the sheet says so, and Cancel connects to nothing. A host that needs a password or a one-time code is refused without a sheet: Runlet never logs in for an AI client. Log in with **Connect…** first, and runs reuse that login.
- **No answer:** a sheet waits 5 minutes. Then the request expires, and the client is told nothing ran.
- **One at a time:** requests wait in line, each with its own sheet, and approving one approves nothing else. A client can have at most 4 requests waiting.
- **The client gives up:** a request still waiting is withdrawn and its sheet closes. A run that already started finishes in its tab, and `get_last_output` returns it.
- **Something changed:** if the target is removed, changes environment, or its SSH connection changes while the sheet is up, Run doesn't run anything. The client is told to try again, and the next request asks with the new facts.

### Where Runs Appear

An approved run opens in a tab named after the client, in the window that showed the sheet, so you see what ran and its output. The client's next run reuses that tab while you haven't edited it, and opens a new one otherwise. The output starts with a line that says which client asked and how the run was approved. Runs are recorded in History like any other, and the tabs are restored at launch without running.

## Security Model

- **No network.** Runlet listens only on a private Unix socket on your Mac, never on a network port.
- **Only you.** Runlet accepts only processes running as your user, and `runlet mcp` checks that the socket belongs to you and is private. Any process running as you can reach it, just as it could run PHP itself: the approval sheet protects you from an AI client acting without your consent, not from malware already running as you.
- **Approvals live in the app.** Nothing in a request can approve a run, or reuse another connection's sandbox allowance. Runlet resolves the target name once, shows that target on the sheet, and runs on it.
- **What a client learns** is what the tools return: target names, project folders, container names, SSH users and hosts, snippet code, and run output.
- **Database credentials stay out of reach.** Clients can't list, use, or read [saved database connections](connections.md#saved-connections) or their passwords, `runlet mcp` never reads the Keychain, and an SQL snippet shows at most the name of the connection it opens on. Passwords typed in Redis snippets show as `•••`.
- **Off means off.** Turn the setting off in **Settings ▸ AI Clients** to disconnect every client.

[Safety & Privacy](safety-and-privacy.md) covers the rest of Runlet.

## For developers

The MCP server is N44, added in [#43](https://github.com/filipac/runlet/issues/43). This page took in the readme's "AI clients (MCP)" section in [#291](https://github.com/filipac/runlet/issues/291).

### Tool Details

| Tool | Arguments | Notes |
| --- | --- | --- |
| `list_targets` | none | Each entry has its `target` value (what the other tools take), its environment (development, staging, production), its folder, container, or host, how runs there are approved, and, for SSH hosts, whether they are connected (checked on this Mac). |
| `list_snippets` | `target`, `query` (both optional) | Personal snippets (id, label, optional description, target, `language`, the first lines). With `target`, the snippets saved for that target or for any target, plus that project's shared snippets (`.runlet/snippets`). `query` keeps entries whose label, description, or code contains every word. |
| `get_snippet` | `id` | A personal snippet can also be found by its exact label. `language` is `php`, or `sql` for [SQL snippets](sql-tabs.md#snippets), which `run_php` can't run. An SQL snippet that remembers a connection ([#149](https://github.com/filipac/runlet/issues/149)) returns its name as `connection`: only the name, never the connection's definition. A [parameterised snippet](snippet-inputs.md) also returns `inputs` (`name`, `type`, and `label`, `default`, and `choices` when declared) and, for declarations Runlet can't read, `input_problems`; the client assigns the inputs when it runs the code with `run_php`. |
| `add_snippet` | `label`, `code`, `target` and `language` (`php` or `sql`; both optional) | With `language: "sql"`, an SQL snippet that opens as an SQL tab. |
| `run_php` | `target`, `code` | See below. |
| `get_last_output` | none | Useful when a client stopped waiting before a run finished. |

Targets can also be named `<kind>:<id>` when two share a name. Names are matched ignoring case: an exact name wins, otherwise a unique prefix.

**`run_php` results.** `structuredContent` has the text's content as data: `target`, `tab`, `client`, `status` (`completed`, `failed`, `cancelled`, or `running`), `reason`, `durationMs`, `exitCode`, `php`, `framework`, `output`, `dumps` (`value`, `line`), `result` (`value`, `type`), `errors` (`class`, `message`, `stage`, `line`, `file`, `fileLine`), `messages` for `\Runlet\notice()`, `warning()`, and `error()` cards (`level`, `message`, `line`, `file`, `fileLine`, `class`, `context`; only when there are any, and never counted as errors; see [snippet-api.md](snippet-api.md#notices-warnings-and-errors)), and `truncated`. A run that failed, and a request that was declined, expired, or refused, comes back as a tool error (`isError: true`) the model can read.

**Sessions.** The sandbox allowance belongs to one `runlet mcp` connection: it ends when that process ends.

**Other tabs.** MongoDB tabs ([#191](https://github.com/filipac/runlet/issues/191)) follow the same boundary: `run_php` can't run their text or access saved database credentials. Saved MongoDB passwords use Keychain storage and the runner's standard input; connection settings accept hosts rather than credential-bearing URIs. Read-only is enforced by the app and the runner's operation checks, not a MongoDB session mode; use read-only roles for server enforcement. See [MongoDB](mongodb.md). Saved connections from this Mac, of all targets ([#142](https://github.com/filipac/runlet/issues/142)), and through an SSH profile's tunnel ([#143](https://github.com/filipac/runlet/issues/143); no tool adds, lists, or uses a forward) are covered the same way as [#138](https://github.com/filipac/runlet/issues/138)'s. Redis snippets' typed passwords (`AUTH`, `HELLO … AUTH`, …) show as `•••` in `list_snippets` and `get_snippet` ([#190](https://github.com/filipac/runlet/issues/190)), and `run_php` never runs a Redis tab.

### Socket and Limits

- **The socket:** `~/Library/Application Support/Runlet/MCP/runlet.sock`, in a folder with mode `0700`, with socket mode `0600`. When the data folder's path is too long for a socket (a deep `RUNLET_DATA_DIR`), it goes to a folder named after the data folder in the per-user temporary directory (`/var/folders/…/T/runlet-mcp-<hash>/`), with the same modes. Runlet Dev has its own data folder, so its own socket.
- **Peer checks:** the app checks each connecting process's user with `getpeereid` and drops other users. `runlet mcp` checks that the socket and its folder belong to you, that the folder is private, and that the process listening runs as you.
- **Approvals:** the approval and the session allowance belong to the app's record of each socket connection, which a crafted request can't name or reuse.
- **Bounded messages:** messages from the client are at most 4 MB, messages from `runlet mcp` to the app at most 1 MB, and answers at most 8 MB; a larger message closes the connection or is answered with an error. At most 16 clients can connect, with 8 calls each in progress.
- **Only one listener:** a second copy of Runlet on the same data folder doesn't take over a live socket, and a file at the socket's path that isn't Runlet's socket is never removed.
- **Standard output** of `runlet mcp` carries only MCP messages. Diagnostics go to standard error.

### Protocol and Transport

- **stdio.** `runlet mcp` reads newline-delimited JSON-RPC 2.0 on standard input and writes one message per line on standard output. It exits when its input ends, withdrawing any request that still waits for approval.
- **Revisions.** It is a dual-era server, as the 2026-07-28 specification describes. Requests that carry `io.modelcontextprotocol/protocolVersion` (with `clientCapabilities`, and optionally `clientInfo`) in `_meta` are served statelessly under 2026-07-28: `server/discover`, `resultType: "complete"`, `serverInfo` in each result's `_meta`, `ttlMs`/`cacheScope` on `tools/list`, and `UnsupportedProtocolVersionError` (-32022) for other versions. Clients that start with `initialize` get the revision they ask for when it is 2025-11-25, 2025-06-18, 2025-03-26, or 2024-11-05, and 2025-11-25 otherwise. `structuredContent` is included from 2025-06-18 on.
- **Capabilities.** Tools only: no resources, prompts, logging, or list-change notifications.
- **Progress and cancellation.** A `tools/call` with a `progressToken` gets `notifications/progress` when its state changes ("Waiting for the user to approve the run in Runlet", "Running on …") and every 15 seconds while it waits, so clients that reset their timeout on progress keep waiting. `notifications/cancelled` stops a call; it gets no response.
- **Client timeouts** are the client's. Claude Code waits a long time by default (`MCP_TOOL_TIMEOUT`). A client that gives up earlier cancels the request, and `get_last_output` fetches a run that started anyway.
- **Errors.** An unknown tool or malformed request is a JSON-RPC error; invalid arguments, a target that doesn't resolve, a declined or expired request, and a failed run are tool results with `isError: true`.
- **App bridge.** `runlet mcp` and the app exchange `MCPBridge` messages over the socket (JSON, one per line): `hello`, `client`, `call`, and `cancel` from the tool; `welcome`, `status`, `result`, and `refused` from the app. A tool from a different version of Runlet is refused with a message.

The implementation needs no third-party code. The protocol core, the socket, the approval policy, and the reports are in RunletCore (`MCPServer.swift`, `MCPTools.swift`, `MCPJSON.swift`, `MCPBridge.swift`, `MCPAppClient.swift`, `MCPApproval.swift`, `MCPRunReport.swift`). The tool is `RunletCLI/MCPCommand.swift`. The app side is `Runlet/App/AppModel+MCP.swift`, with the sheet and Settings tab in `Runlet/Features/MCPViews.swift`. The Connection Manager's client rows came with [#180](https://github.com/filipac/runlet/issues/180).

### Testing

Never register a development build in your real client configuration. The checks used during development:

- **Unit tests:** `swift test --filter MCP` in `Packages/RunletKit`. They cover JSON-RPC framing (partial lines, several messages per read, oversized and invalid messages), `initialize` and per-request version handling, `server/discover`, `tools/list` schemas, `tools/call` routing, errors, cancellation, progress, argument checks, the socket (modes, peer checks, stale and foreign files, oversized messages, round trips, cancellation, a vanished app), the approval policy across every target, environment, and SSH state, target matching and selectors, the target listing, and run reports. Socket tests use scratch folders under `/tmp`.
- **End to end:** `python3 scripts/mcp-e2e/driver.py <Debug Runlet.app> <scratch folder>` builds scratch data (a local project in the scratch folder and three made-up SSH hosts), starts the app hidden (the `ghost` debug step, so nothing shows on screen) with `RUNLET_DATA_DIR`, and drives two `runlet mcp` processes with JSON-RPC lines. `scripts/mcp-e2e/steps.txt` answers the sheets with Debug-only steps and takes screenshots. It never touches your Runlet data, `~/.ssh`, a server, or Docker: SSH requests are never approved and the app uses `Tests/Fixtures/fake-ssh/ssh`. A second launch shortens the approval timeout to 4 seconds to check expiry. Build first with `xcodebuild -project Runlet.xcodeproj -scheme Runlet -configuration Debug -derivedDataPath build/DerivedData PRODUCT_BUNDLE_IDENTIFIER=dev.runlet.Runlet.prshots build`.
- **Debug-only switches:** the steps `mcp:on|off`, `mcp-wait[:<seconds>]` (waits until a sheet is on screen), `mcp-approve`, `mcp-approve:session`, `mcp-decline`, and `mcp-state`; `mcp-ask:<client>|<target>|<code>`, which shows the sheet for a made-up client with no `runlet mcp` process (the docs' screenshot, [#304](https://github.com/filipac/runlet/issues/304)); `RUNLET_DEBUG_MCP_APPROVAL_TIMEOUT=<seconds>`; and `RUNLET_DEBUG_APP_PATH`, which shows another app path in Settings (for screenshots). Release builds never answer a sheet by themselves. `RUNLET_MCP_NO_LAUNCH=1` makes `runlet mcp` report that Runlet isn't running instead of starting it.

**Verified end to end** (2026-10-03, Debug build, scratch data):

- `initialize` and `tools/list`, plus `server/discover` and an unsupported version on a 2026-07-28 client
- `list_targets`; `add_snippet`, `get_snippet`, and `list_snippets`
- an approved sandbox run (result, dump line, tab) and a declined sandbox run
- the session allowance: the next sandbox run runs without a sheet, and its exception comes back with its line
- a second client still being asked for the sandbox
- an SSH host that needs a login, refused without a sheet
- an unconnected SSH host's sheet ("connects"), withdrawn when the client cancels
- the production sheet, declined
- an approved local-project run, and `get_last_output`
- expiry after the (shortened) timeout
- standard output carrying only JSON-RPC, and the tool exiting at the end of its input

**Covered only by unit tests:** starting Runlet when it isn't running (with a stand-in launcher; the end-to-end check sets `RUNLET_MCP_NO_LAUNCH` so a visible copy never starts), the socket's fallback path for long data folders, and the 8-calls-per-client limit's neighbours (duplicate request ids).

**Not exercised:** real AI clients (Claude Code, Claude Desktop, and Cursor were not configured against a development build); approving runs on SSH hosts or Docker applications through MCP (they use the same run path as the Run button after approval); a `runlet` from another version of Runlet being refused; and the connection and call limits.
