# AI clients (MCP server)

Runlet includes an [MCP](https://modelcontextprotocol.io) server, so AI clients such as Claude Code, Claude Desktop, and Cursor can work with it ([#43](https://github.com/filipac/runlet/issues/43)). A client can list your targets and snippets, save snippets, run PHP, and read the output. Every run asks you first, in Runlet. Only Laravel sandbox runs can skip the question, and only after you allow them for the rest of that client's session.

## Turn it on

Settings ▸ AI Clients ▸ **Allow AI clients to connect**. It is off by default: AI clients can only reach Runlet after you turn it on once. Even then, nothing runs without your approval.

While it is on, Runlet listens on a private Unix socket on this Mac and never on the network (see [Security model](#security-model)). The same Settings tab lists the connected clients and gives the exact client configuration for your copy of Runlet.

## Set up a client

The server is the `runlet` tool inside the app, started with the argument `mcp`. The examples use `/Applications/Runlet.app`; Settings ▸ AI Clients shows the path of the copy you are running.

**Claude Code** (user scope, so every project sees it):

```bash
claude mcp add --transport stdio --scope user runlet -- /Applications/Runlet.app/Contents/Helpers/runlet mcp
```

**Claude Desktop**: Settings ▸ Developer ▸ Edit Config opens `~/Library/Application Support/Claude/claude_desktop_config.json`. **Cursor** reads `~/.cursor/mcp.json` (every project) or `.cursor/mcp.json` in a project. Add Runlet next to any servers already there, then restart the client:

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

Other MCP clients take the same command and argument. The tool talks to the copy of Runlet it belongs to. If you move Runlet.app, update the path.

- **Runlet isn't running.** On the first tool call, `runlet mcp` starts Runlet in the background, the way `runlet` does from a terminal. Starting Runlet never runs code: it restores your tabs without running them, and a run still waits for your approval.
- **The MCP server is off.** The call fails with a message asking you to turn it on in Settings ▸ AI Clients. The client can show you that message.
- `runlet mcp` reads JSON-RPC on standard input. Started by hand in a terminal, it explains that and exits. A folder named `mcp` opens as `runlet ./mcp`.

## Tools

| Tool | Arguments | What it does |
| --- | --- | --- |
| `list_targets` | none | Lists the Laravel sandbox, local projects, Docker applications, and SSH hosts. Each entry has its `target` value (what the other tools take), its environment (development, staging, production), its folder, container, or host, how runs there are approved, and, for SSH hosts, whether they are connected (checked on this Mac; nothing is contacted). |
| `list_snippets` | `target`, `query` (both optional) | Personal snippets (id, label, target, the first lines). With `target`, the snippets saved for that target or for any target, plus that project's shared snippets (`.runlet/snippets`, [project-snippets.md](project-snippets.md)). `query` keeps entries whose label or code contains every word. |
| `get_snippet` | `id` | A snippet's full code, label, and target. A personal snippet can also be found by its exact label. Reading never runs it. |
| `add_snippet` | `label`, `code`, `target` (optional) | Saves a personal snippet in Runlet's Snippets list. It only saves; nothing runs. |
| `run_php` | `target`, `code` | Asks you to approve the run, runs it, and returns the result. See below. |
| `get_last_output` | none | The most recent `run_php` run from any client: its output, or its progress while it still runs. It is useful when a client stopped waiting before a run finished. |

**Targets** are named like `runlet --target` names them ([cli.md](cli.md)): `sandbox`, `local:<name>`, `docker:<name>`, or `ssh:<name>`. A project can also be named by its folder, and any target by `<kind>:<id>` when two share a name. Names are matched ignoring case: an exact name wins, otherwise a unique prefix. A name that matches several targets is an error that lists them. `list_targets` always gives values that resolve to exactly one target.

**`run_php` results.** The text reads like the output pane: where the run happened (the target and the Runlet tab), PHP and framework versions, printed output, `dump()`/`dd()` values with their line, the value of the last expression (as in Tinker), errors with the line in the code that was sent, and how the run ended, with its duration. `structuredContent` has the same as data: `target`, `tab`, `client`, `status` (`completed`, `failed`, `cancelled`, or `running`), `reason`, `durationMs`, `exitCode`, `php`, `framework`, `output`, `dumps` (`value`, `line`), `result` (`value`, `type`), `errors` (`class`, `message`, `stage`, `line`, `file`, `fileLine`), and `truncated`. A run that failed, and a request that was declined, expired, or refused, comes back as a tool error (`isError: true`) the model can read. Text is capped at 60,000 characters; the Runlet tab keeps everything.

The code may start with `<?php` or not. Code is at most 200 KB, so the approval sheet can show all of it.

## Approvals

Every `run_php` request shows a sheet in Runlet's window, brought to the front. It shows:

- the client's name, as the client reports it (`clientInfo`; shown for information only and never used to decide anything);
- the target, its environment badge, and where the code runs (a folder, a container, or `user@host:directory`);
- all of the code.

**Run** (⌘↩) runs exactly that code on exactly that target. **Cancel** (↩ or Esc) tells the client you declined, and nothing runs.

The rules:

- **Sandbox.** The sheet offers **Allow sandbox runs from <client> for this session**. Once ticked, later sandbox runs from that client run without a sheet until the client disconnects (its `runlet mcp` process ends, for example when you quit the client or start a new session) or Runlet quits. It applies to that one connection: another client, or the same client after reconnecting, asks again. Settings ▸ AI Clients shows the allowance and can revoke it. Only the sandbox ever offers it.
- **Local projects and Docker applications** always ask. There is no session allowance.
- **Production targets** always ask, with a red production warning and a **Run on Production** button. The production guard's 10-minute "don't ask again" never applies to AI clients, and approving an AI client's run never starts one.
- **SSH hosts** are never connected silently. If the host isn't connected and its profile logs in by itself (an agent or keys), the sheet says that pressing Run connects over SSH, and Cancel connects to nothing. If the profile needs a login (a password or a one-time code), the request is refused without a sheet: Runlet never logs in for an AI client. Log in with Connect… first; runs then reuse that login.
- **No answer.** A sheet waits 5 minutes; then the request expires and the client is told nothing ran.
- **One at a time.** Requests wait in line, and each gets its own sheet: approving one approves nothing else. A client can have at most 4 requests waiting.
- **The client cancels** (for example after its own timeout): a request still waiting is withdrawn and its sheet closes. A run that already started finishes in its tab, and `get_last_output` returns it.
- **Changes while waiting.** If the target is removed or changes environment, or its SSH connection state changes, while the sheet is up, pressing Run doesn't run anything. The client is told to try again, and the next request asks with the new facts.

**Where runs appear.** An approved run opens in a tab named after the client, in the window that showed the sheet, so you see what ran and its output. The next run from that client reuses the tab while you haven't edited it, and opens a new tab otherwise. The output starts with a line saying which client asked and how the run was approved. Runs are recorded in History like any other run. Like every tab, MCP tabs are restored at launch without running.

**Opening never runs.** Listing targets or snippets, reading or saving a snippet, starting Runlet, and restoring tabs never run code. Only an approved `run_php` (or a sandbox run you allowed for the session) does.

## Security model

- **No network.** The app listens only on a Unix domain socket: `~/Library/Application Support/Runlet/MCP/runlet.sock`, in a folder with mode `0700`, with socket mode `0600`. When the data folder's path is too long for a socket (a deep `RUNLET_DATA_DIR`), the socket goes to a folder named after the data folder in the per-user temporary directory (`/var/folders/…/T/runlet-mcp-<hash>/`), with the same modes.
- **Only you.** The app checks each connecting process's user with `getpeereid` and drops other users. `runlet mcp` checks that the socket and its folder belong to you, that the folder is private, and that the process listening runs as you. Processes running as your user can reach the socket, just as they could run PHP themselves. The approval sheet protects you from an AI client acting without your consent. It doesn't protect you from malware already running as you.
- **Approvals live in the app.** Nothing in a message can approve a run. The approval and the session allowance belong to the app's record of each socket connection, which a crafted request can't name or reuse. A target name is resolved once, in the app, and the sheet shows the resolved target; the run uses that target.
- **Bounded messages.** Messages from the client are at most 4 MB, messages from `runlet mcp` to the app at most 1 MB, and answers at most 8 MB; a larger message closes the connection or is answered with an error. At most 16 clients can connect, with 8 calls each in progress.
- **Only one listener.** A second copy of Runlet on the same data folder doesn't take over a live socket, and a file at the socket's path that isn't Runlet's socket is never removed.
- **What a client learns** is what the tools return: target names, project folders, container names, SSH users and hosts, snippet code, and run output. Turn the server off in Settings ▸ AI Clients to disconnect every client.
- **Standard output** of `runlet mcp` carries only MCP messages. Diagnostics go to standard error.

## Protocol and transport

- **stdio.** `runlet mcp` reads newline-delimited JSON-RPC 2.0 on standard input and writes one message per line on standard output. It exits when its input ends, withdrawing any request that still waits for approval.
- **Revisions.** It is a dual-era server, as the 2026-07-28 specification describes. Requests that carry `io.modelcontextprotocol/protocolVersion` (with `clientCapabilities`, and optionally `clientInfo`) in `_meta` are served statelessly under 2026-07-28: `server/discover`, `resultType: "complete"`, `serverInfo` in each result's `_meta`, `ttlMs`/`cacheScope` on `tools/list`, and `UnsupportedProtocolVersionError` (-32022) for other versions. Clients that start with `initialize` get the revision they ask for when it is 2025-11-25, 2025-06-18, 2025-03-26, or 2024-11-05, and 2025-11-25 otherwise. `structuredContent` is included from 2025-06-18 on.
- **Capabilities.** Tools only: no resources, prompts, logging, or list-change notifications.
- **Progress and cancellation.** A `tools/call` with a `progressToken` gets `notifications/progress` when its state changes ("Waiting for the user to approve the run in Runlet", "Running on …") and every 15 seconds while it waits, so clients that reset their timeout on progress keep waiting. `notifications/cancelled` stops a call; it gets no response.
- **Client timeouts** are the client's. Claude Code waits a long time by default (`MCP_TOOL_TIMEOUT`). A client that gives up earlier cancels the request, and `get_last_output` fetches a run that started anyway.
- **Errors.** An unknown tool or malformed request is a JSON-RPC error; invalid arguments, a target that doesn't resolve, a declined or expired request, and a failed run are tool results with `isError: true`.
- **App bridge.** `runlet mcp` and the app exchange `MCPBridge` messages over the socket (JSON, one per line): `hello`, `client`, `call`, and `cancel` from the tool; `welcome`, `status`, `result`, and `refused` from the app. A tool from a different version of Runlet is refused with a message.

The implementation needs no third-party code. The protocol core, the socket, the approval policy, and the reports are in RunletCore (`MCPServer.swift`, `MCPTools.swift`, `MCPJSON.swift`, `MCPBridge.swift`, `MCPAppClient.swift`, `MCPApproval.swift`, `MCPRunReport.swift`). The tool is `RunletCLI/MCPCommand.swift`. The app side is `Runlet/App/AppModel+MCP.swift`, with the sheet and Settings tab in `Runlet/Features/MCPViews.swift`.

## Testing

Never register a development build in your real client configuration. The checks used during development:

- **Unit tests:** `swift test --filter MCP` in `Packages/RunletKit`. They cover JSON-RPC framing (partial lines, several messages per read, oversized and invalid messages), `initialize` and per-request version handling, `server/discover`, `tools/list` schemas, `tools/call` routing, errors, cancellation, progress, argument checks, the socket (modes, peer checks, stale and foreign files, oversized messages, round trips, cancellation, a vanished app), the approval policy across every target, environment, and SSH state, target matching and selectors, the target listing, and run reports. Socket tests use scratch folders under `/tmp`.
- **End to end:** `python3 scripts/mcp-e2e/driver.py <Debug Runlet.app> <scratch folder>` builds scratch data (a local project in the scratch folder and three made-up SSH hosts), starts the app hidden (the `ghost` debug step, so nothing shows on screen) with `RUNLET_DATA_DIR`, and drives two `runlet mcp` processes with JSON-RPC lines. `scripts/mcp-e2e/steps.txt` answers the sheets with Debug-only steps and takes screenshots. It never touches your Runlet data, `~/.ssh`, a server, or Docker: SSH requests are never approved and the app uses `Tests/Fixtures/fake-ssh/ssh`. A second launch shortens the approval timeout to 4 seconds to check expiry. Build first with `xcodebuild -project Runlet.xcodeproj -scheme Runlet -configuration Debug -derivedDataPath build/DerivedData PRODUCT_BUNDLE_IDENTIFIER=dev.runlet.Runlet.prshots build`.
- **Debug-only switches:** the steps `mcp:on|off`, `mcp-wait[:<seconds>]` (waits until a sheet is on screen), `mcp-approve`, `mcp-approve:session`, `mcp-decline`, and `mcp-state`; `RUNLET_DEBUG_MCP_APPROVAL_TIMEOUT=<seconds>`; and `RUNLET_DEBUG_APP_PATH`, which shows another app path in Settings (for screenshots). Release builds never answer a sheet by themselves. `RUNLET_MCP_NO_LAUNCH=1` makes `runlet mcp` report that Runlet isn't running instead of starting it.

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
