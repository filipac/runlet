# Runlet: ideas for the next release(s)

Written 2026-10-02, after 0.0.1. Inputs:

- Runlet: `plan.md`, `CHANGELOG.md`, `docs/tinkerwell-feature-review.md` (its built items are not repeated as new ideas), `docs/drivers.md`, `docs/architecture.md`, `docs/compatibility.md`, `Runlet/App/Commands.swift`, and the code under `Runlet/` and `Packages/RunletKit/`.
- Tinkerwell: every page in the v5 docs navigation, the changelog (5.x, 4.x, 3.x), the feature pages, two v2/v4 pages, a Tinkerwell blog post, and the public driver repository (`beyondcode/tinkerwell`). See [Sources](#6-sources).

**Conventions**

- **Priority:** P1 is next release, P2 the one after, P3 later or on demand.
- **Size:** S is about a day or less, M is 2–4 days, L is a week or more. These are rough guesses.
- **"Guess"** marks anything about Tinkerwell that its docs don't say outright, and any Runlet assumption that needs checking.
- Every idea keeps Runlet's rules: nothing runs without an explicit Run. Runlet never execs into a container, or opens a remote connection, unless the user asked for it. Docker and remote targets are always explicit.

## 1. Summary

The user expects SSH to come next, so it leads the list and has its own design section ([§3](#3-ssh-targets--design-proposal)).

1. **SSH targets** (P1, L, phased; [§3](#3-ssh-targets--design-proposal)). Covers plain hosts from `~/.ssh/config` (including jump hosts) and Docker on a remote host. Runs use the system `/usr/bin/ssh`, so agents, 1Password, ProxyJump, and ControlMaster work with no extra code. Each host gets a local project folder for completion. Production profiles get guard rails. The runner is streamed over stdin, so nothing is uploaded to the server.
2. **Target environments and production guard** (P1, S–M; N14). Adds per-target colours, a production flag with a red badge, a confirmation before each run, and stricter defaults. SSH needs this first, and Docker and local targets benefit too.
3. **SQL query inspector** (P1, M; N01). This is Tinkerwell's most practical inspector. Runlet needs one driver hook and one new run event (SQL, bindings, time, snippet line), plus duplicate (N+1) hints.
4. **Mail and HTML preview** (P1, M; N02). Mailables, notifications, and views render in a locked-down `WKWebView` (no JavaScript, no remote loads). Mail sent during a run is captured, so you can see it without sending it.
5. **Magic comments** (P1, L; N11). Supports `//?`, `/*?*/`, `/*?->count()*/`, and `/*?.*/` timings, with inline values in the editor. This is Tinkerwell's signature feature. Runlet's AST runner and streaming can show values while the code is still running, whereas Tinkerwell needs buffered output.
6. **Finish the 0.0.1 leftovers** (P1, S each; N04, N33, N39). Copy a table row as JSON or a PHP array, Copy as Markdown, Save Output As…, keyboard-first History and Snippets, file watching, and a `runlet` command-line tool.
7. **Signed, notarized builds and auto-update** (P1, M; N40). 0.0.1 is ad-hoc signed, so Gatekeeper blocks downloaded copies. Tinkerwell ships an updater.
8. **Log viewer** (P2, M; N27). Reads Laravel and Monolog logs from local projects, Docker bind mounts, and SSH hosts, with follow, level filter, search, and links from stack traces to files.

**Suggested order.** Next release: N14 (environments), SSH-1 to SSH-4 (a usable SSH target), N01, N04, N33, N39, N40. Release after: SSH-5 to SSH-7, N02, N11, N27, N03.

## 2. Gap table

**Have:** Runlet has it. **Partial:** some of it. **No:** missing. Tinkerwell sources: [v5 docs](https://tinkerwell.app/docs/5/getting-started/about) unless a row cites the changelog (`cl x.y`) or `plan.md`'s inspection of the installed app.

### Getting started and settings

| Tinkerwell feature | Runlet | Notes |
| --- | --- | --- |
| macOS, Windows, and Linux apps | Partial | macOS only, by design. |
| PHP auto-detection, Herd and Homebrew paths | Have | `PHPDiscovery` searches PATH, Herd `phpXY` shims, and Homebrew. |
| Language server needs local PHP 8.1+ | Better | PHPantom is native, so completion works with no host PHP. |
| Layout: output right or below (⌃.) | Have | `output.swapPosition`. |
| Themes | Partial | System, Light, or Dark only; syntax colours are fixed (N32). |
| Font, size, ligatures, line height | Have | — |
| Auto evaluate (on by default in Tinkerwell; off on SSH) | No | Deliberately off. N17 offers a sandbox-only opt-in. |
| Default project instead of the sandbox | Have | — |
| Forge API key, site sync | No | N24, after SSH. |
| OpenAI and other AI provider keys | No | AI was excluded from the MVP. AI ideas are an optional group (N44–N47). |
| PhpStorm plugin | No | Skip (§5). The `runlet` CLI and URL scheme (N35, N39) cover "send code to Runlet". |

### Setup guides (targets)

| Tinkerwell feature | Runlet | Notes |
| --- | --- | --- |
| Laravel sandbox | Have | Pinned Laravel 13.34, reset, Docker fallback. Tinkerwell updates its sandbox with each release. |
| SSH connections: label, folder, keys, passphrase, password, agent, 1Password | No | §3. |
| SSH ProxyJump (bastion) with `~/.ssh/config` import (cl 5.11, 5.12) | No | §3. The system `ssh` handles ProxyJump with no extra code. |
| Connection colours, coloured status bar (cl 2.21, 5.14) | No | N14. |
| Sail | Have | Through Docker profiles (non-root user). N22 adds presets. |
| Homestead (SSH into the VM) | No | §3 covers it as a plain SSH host. |
| Docker: pick a running container, detect the working directory | Have | Profiles with Compose identity, recreation handling, and a probe. |
| Custom `docker exec` flags (cl 5.10) | Partial | User, workdir, tmp, and PHP fields exist; free-form flags don't. N21. |
| Custom Docker tmp directory (cl 5.14) | Have | — |
| Docker auto-connect (cl 4.20, 5.10) | Have | `autoResolve`. |
| Docker over SSH (cl 4.0) | No | §3: the remote-container step. |
| DDEV, Lando, Warden | Have | Generic Docker. N22 adds presets. |
| Kubernetes: contexts, searchable pods, custom kubeconfig, remote over SSH | No | N23 (P3). |
| Laravel Vapor | No | Skip (§5). |
| Laravel Cloud | No | Skip (§5). |
| WSL2 | No | Skip (Windows). |
| Completion: indexing, fuzzy matching, chains | Have | PHPantom. |
| Remote completion via a local checkout | Partial | Docker `localSourcePath` with bind-mount detection; SSH in §3.10. |
| Laravel magic methods through IDE Helper | Have | PHPantom infers Laravel without IDE Helper (see `compatibility.md`). |
| Reindex from the status bar | Have | Restart Language Server. |
| AI completion (OpenAI, Anthropic, Mistral; on typing, idle, or demand) | No | N47 (optional). |

### Basic usage

| Tinkerwell feature | Runlet | Notes |
| --- | --- | --- |
| Run (⌘R), run selection | Have | Plus a separate Run Selection and a "prefer selection" setting. |
| Built-in frameworks: Craft, Drupal 7/8, Kirby, Laravel, Laravel Zero, Magento 1/2, Moodle, October, PrestaShop, Statamic, TYPO3, WordPress, plus Symfony, Shopware, Lumen, Testbench, Radicle in the public repo | Partial | Runlet has Laravel, Lumen, Laravel Zero, WordPress (including Bedrock), Symfony, Composer, and plain PHP. Statamic probably works through Laravel (guess). N25. |
| "No framework detected" notice (can be disabled) | Partial | The status bar shows "Composer" or "Plain", with no explicit notice. |
| Detail Dive cards, expansion preference | Have | — |
| CLI mode | Have | Plain mode, plus Raw. |
| Table view, CSV export | Have | Sort, filter, Copy CSV, Export CSV. |
| Copy a table row as JSON or a PHP array | Have | N04: row context menu (JSON, PHP array, CSV). |
| Graph view | No | Skip (§5). |
| HTML view of views, mailables, `MailMessage`; rerun refreshes it | Have | N02: previews in result and dump cards; Run refreshes them. Plus mail capture and interception. |
| SQL query inspection (Laravel, WordPress; SQL Server since cl 4.13) | Have | N01: Laravel, Eloquent without Laravel, Doctrine DBAL 2–4, WordPress, opt-in PDO; any database those layers drive. |
| `dump`/`dd` file links open in an editor (VS Code, PhpStorm, Sublime, TextMate, Nova, Zed, BBEdit) | Have | PhpStorm, VS Code (and variants), Cursor, Zed, Sublime, TextMate, and a custom command (covers Nova and BBEdit). |
| Tabs: ⌘T, ⌘W, ⌘1–9, ⌃Tab, ⌥⌘←/→, ⌘PgUp/PgDn | Partial | ⌘1–9 and ⇧⌘[ ] work; ⌃Tab and ⌥⌘←/→ don't. N32. |
| Rename, duplicate, close others, close to the right, middle-click close (cl 3.23, 4.20) | Partial | Everything but middle-click. |
| Ask before closing a tab (cl 2.24) | Partial | Runlet offers Reopen Closed Tab (⇧⌘T) instead. |
| Open Anything with `#`, `/`, `@`; fuzzy search across history too (cl 5.0.2) | Have | Palette with `#`, `/`, `@`, `>`, and `!` (history, current project first). Done (N33). |
| History: ⌘Y, arrow keys, Return (current tab), ⌘Return (new tab), configurable size | Have | Panel with search, project scope, dedupe, and a limit; ⌘Y focuses the search, ↑/↓, ↩ (per setting), ⌘↩, ⇧↩ insert. Done (N33). |
| Create a snippet from history | Have | — |
| Personal snippets: labels, edit, keyboard | Have | ⇧⌘L focuses the search; same keys as History (N33). |
| Snippets bound to a connection or folder, filter by it (cl 3.8) | Partial | A target is stored and used by "Open in New Tab". |
| Project snippets in `.tinkerwell/snippets` with `@label`/`@description` | Have | `.runlet/snippets`. N34 adds a `.tinkerwell` fallback. |
| Dynamic snippets from drivers (cl 3.3, deprecated in 3.31) | No | N16 is the modern equivalent. |

### Advanced usage

| Tinkerwell feature | Runlet | Notes |
| --- | --- | --- |
| Custom themes (Monaco JSON in `~/.config/tinkerwell/themes`) | No | N32 adds built-in themes. Skip the Monaco format (§5). |
| Remappable shortcuts | Have | — |
| Prettify, plus format-before-run and quote style (cl 4.4, 4.14) | No | N31. |
| Toggle output, toggle toolbar, CLI-mode toggle | Have | ⌃⌘O, the system toolbar toggle, ⌃⌘1–3. |
| Toggle logs (⌘L), toggle AI chat (⇧⌘L) | No | N27 and N46. |
| Magic comments `//?`, `/*?*/`, `/*?->x()*/`, `/*?.*/` (timing); editor highlighting (cl 4.17) | No | N11. |
| Auto log and "live code coverage" (cl 3.0, homepage) | No | N12. |
| Collision errors, per-project `usesCollision()` | Partial | Runlet's own error cards show the stage, trace, and links, but no source excerpt. N07. |
| Project-specific PHP from the footer, aliases, remote PHP path | Have | Project Options; the footer isn't clickable. SSH PHP path in §3. |
| Log viewer: file dropdown, level filter, search, polling, framework defaults, driver log paths, nested folders | No | N27. |
| CLI helper `tinkerwell [path]` (macOS) | Have | `runlet [folder\|file\|workspace]`, `--target`, `--new-window`; Install Command-Line Tool…. Done (N39, [cli.md](cli.md)). |
| AI chat: providers, context toggles, `@` files, per-tab conversation | No | N46 (optional). |
| Xdebug "Toggle Debugging" (Herd only) | No | N13. |
| MCP server (`evaluate-local-php-code`, `evaluate-remote-php-code`, `get-remote-connections`, `get-snippets`, `add-snippet`) | No | N44 (optional). |

### Extending

| Tinkerwell feature | Runlet | Notes |
| --- | --- | --- |
| Project drivers in `.tinkerwell/*TinkerwellDriver.php` | Have | `.runlet/*Driver.php`, plus `commands()` and `hostCommands()`. |
| Global drivers (`~/.config/tinkerwell`, which win over local ones) | No | N25. |
| `getAvailableVariables()`, `appVersion()` | Have | `variables()` (also fed to completion) and `version()`. |
| `usesCollision()` | n/a | Runlet has no Collision. |
| `injectQueryLogging($code)` (public repo) | Better | `Driver::inspect(Inspector $inspector)`: queries, mail, logs, HTML, and custom sections. |
| `logFilesPath()` (public repo) | No | N27. |
| `appPanels()`, `.tinkerwell/panels/*Panel.php`, the Laravel "About" panel | No | N26. |
| `appFiles()` for AI chat context (public repo) | No | N46 (optional). |

### Troubleshooting, distribution, and other changelog items

| Tinkerwell feature | Runlet | Notes |
| --- | --- | --- |
| Config, log, and updater paths; settings reset | Partial | `State/` with last-good and corrupt copies. `Logs/` is unused, and there's no diagnostics export. N40. |
| Auto-updater | No | N40. |
| Recovery from corrupt settings (cl 5.8) | Have | `JSONDocumentStore`. |
| Strict-types toggle (cl 5.15) | Have | Plus per-target overrides. |
| Copy as Markdown (cl 5.11), save output to a file (cl 3.18) | Have | N04. |
| Real-time vs. buffered output (cl 2.14) | Have | Always streams. |
| Time, memory, and start time in the footer (cl 3.21, 4.6) | Partial | Elapsed time and peak memory; no bootstrap/execute split and no start time. N08. |
| PHP version in the footer for every target (cl 5.10) | Have | — |
| Import `use` statements (cl 4.14) | Have | Completion edits; no code action yet (N30). |
| Indentation guides (cl 5.2) | No | N32. |
| HEREDOC highlighting (cl 4.11) | Partial | Approximated. |
| Links in CLI output open in the browser (cl 5.4.1) | Have | N04. |
| Multi-cursor (cl 3.22) | No | No dedicated commands. N32. |
| Recent folders in the Dock menu (cl 3.5) | Have | The Dock menu lists recent projects (local and Docker). Done (N39). |
| Recent connections (cl 5.0.2) | Have | The palette sorts targets by `lastOpenedAt`. |
| Auto-hide output, Esc hides it (cl 3.6) | Partial | Show/hide output exists; no auto-hide. |
| Custom Carbon caster (cl 3.8) | No | N05. |
| Herd integration: site actions, `herd tinker`, Herd `php.ini` | Partial | Herd PHP is discovered; there's no per-site isolation. N22. |
| Tinkerwell Wrapped (cl 5.7) | No | Skip (§5). |

## 3. SSH targets — design proposal

### 3.1 Requirements from the user

| Area | Requirement |
| --- | --- |
| Server types | (a) Plain SSH hosts from `~/.ssh/config`, including jump hosts. (b) Docker on a remote host: SSH to a server, then `docker exec` into a container there. Model (b) as an SSH profile with an optional remote-container step. It reuses the Docker profile ideas: Compose project and service labels, an explicit choice when the container is ambiguous, and never switching containers silently. Forge, Ploi, and Kubernetes are later options only. |
| Authentication | ssh-agent and the 1Password SSH agent, key files in `~/.ssh`, and **interactive password and 2FA prompts**. Runlet never handles or stores the secret. |
| Production | A per-profile production flag with a red badge on the tab card and target menu, a confirmation before each run (with "don't ask again for 10 minutes"), and stricter defaults: nothing auto-loads or auto-runs code, including the Commands pane and facts detection. An optional read-only or safe mode, documented honestly: PHP writes can't truly be prevented. |
| Local project per host | Every SSH profile, and its optional container step, has a **local source folder on this Mac**, like Docker's `localSourcePath`. It is first-class (§3.10): it powers completion, path mapping, drivers and facts, snippets, host commands, the editor, and the terminal. Runlet suggests a folder automatically and can warn about branch or commit drift. Without a folder, the profile works in limited mode. |

### 3.2 What Tinkerwell documents about SSH

| Topic | What the docs say | Source | Runlet design |
| --- | --- | --- | --- |
| Creating connections | Open from the toolbar or Action ▸ Connect via SSH. Fields: label, remote host info, and the remote application folder. You can "preload existing connections". The footer shows `SSH - <label>`. Clicking the icon again disconnects. | v5 and v2 SSH pages | A profile with a host alias, directory, PHP, optional container step, and local folder. A tab card chip and status-bar label. |
| Key auth | Private key file with a passphrase field ("for password-protected keys, not server passwords"). The private and public key must be in the same folder. | Troubleshooting | Key files are used through `ssh` itself; Runlet never reads key files. |
| Password auth | The WSL2 guide connects with "Authentication: Password-based". `plan.md` saw password fields in the installed app. | WSL guide | Interactive login in a terminal tab that sets up a ControlMaster (§3.6). |
| ssh-agent and 1Password | Agents are supported. You must select **any** key file so the agent is triggered. Needs `SSH_AUTH_SOCK` and `IdentityAgent` in `~/.ssh/config`. `IdentityFile` must be an absolute path (no `~`), and the setting must be spelled `HostName`. The blog says 1Password works only with ED25519 keys. | v5 SSH page, blog | Works with no special handling, because OpenSSH reads the config and talks to the agent. |
| Jump hosts | ProxyJump (bastion) support, "auto-imported" from `~/.ssh/config` (5.11). Config changes are detected without a restart (5.12). | Changelog | OpenSSH applies `ProxyJump` from the config. An optional `-J` override per profile. |
| PHP binary | Remote runs use the `php` alias by default; a path or alias can be set per connection. Compound paths and paths with spaces were fixed in 5.13 and 5.14. | Project-specific PHP, changelog | `phpExecutable` per profile and per container step, with the probe listing candidates. |
| Project path | You must select the correct remote application folder. Forge zero-downtime deployments are detected, and Tinkerwell offers to switch to the `current` symlink (5.8). | v5 SSH page, changelog | `remoteDirectory`. The probe resolves symlinks, and path mapping accepts both the `current/` path and the resolved `releases/<id>/` path (§3.10). |
| Forge | A Forge API key in settings imports the sites you can connect to. Moved to Forge API v2 in 5.17; the token needs the `server:view` scope. | Settings, v2 docs, changelog | Later (N24). |
| Ploi | No documented integration found. | Search | Later (N24). |
| Vapor and Laravel Cloud | Separate runtimes, not SSH: `vapor.yml` with `vapor env:list` (dump only, no return values), and an API token for Cloud. | Setup guides | Out of scope (§5). |
| Per-connection settings | Label, colour (the palette's `@` lists "connections with custom colors"; coloured status bar in 2.21; colour kept in tabs in 5.14), duplicate (2.21), PHP path, local project path for completion, Kubernetes config path, and a "custom path for Tinkerwell data in remote connections" (3.15). | Various | Production flag, colour, PHP, local folder, container step, safe mode, drift check. |
| Docker over SSH | Connect via SSH, then pick the PHP container as you would locally (4.0). | Docker guide, changelog | The remote-container step (§3.7). |
| How code gets there and runs | **Not documented.** Guess: Tinkerwell uploads support files to a remote data directory and runs the remote PHP in the app folder. Evidence: the 3.15 "custom path for Tinkerwell data" item, and `plan.md`'s "temporary upload location". | — | Runlet streams the runner to `php` on stdin; nothing is written on the server (§3.7). |
| How output comes back | **Not documented for SSH.** A global real-time vs. buffered setting exists (2.14), and magic comments need buffered output. | — | Same nonce-framed event protocol over the SSH channel's stdout, with stderr kept separate. |
| Timeouts | **Not documented.** | — | Connect 10 s, keep-alive 15 s × 3, listings 120 s, probes 10–15 s (§3.5). |
| SSH implementation | **Not documented.** Guess: a built-in SSH library, not the system `ssh`. Evidence: a dummy key file is needed to trigger the agent, ED25519 only with 1Password, absolute `IdentityFile` paths, and the exact `HostName` spelling. | — | The system `/usr/bin/ssh` (§3.5). |
| Safety | "Auto evaluation is disabled on SSH connections" to avoid harming production. | v5 SSH page, settings | Runlet never auto-runs anything. Production profiles add confirmation and guard rails (§3.13). |
| AI and MCP | `evaluate-remote-php-code` and `get-remote-connections`. The MCP server establishes SSH connections automatically. | MCP page | If Runlet ever adds MCP (N44), it never opens a connection without in-app approval. |

### 3.3 Design overview

```text
Tab ─► TargetRef.ssh(id) ─► AppModel.snapshot(for:) ─► TargetSnapshot(kind: .ssh, ssh: SSHEndpoint, [container…])
                                                            │
ExecutionEngine.prepare(target:) ── .ssh ──► SSHExecAdapter ─┤ plain host:   ssh -T … host -- /bin/sh -c 'cd DIR && export RUNLET_RUN_ID=… && exec PHP -d …'
                                                            └ container:    DockerCLI(transport: .ssh) → DockerExecAdapter (unchanged)
stdin: RunnerBundle.script(…)   stdout: nonce frames + raw output   stderr: raw stderr   Stop: ssh … php -r signalHelper
Local folder on this Mac ─► PHPantom workspace, TargetInspector.staticFacts, .runlet/snippets, hostCommands(), editor links, terminal
```

**Key decision: use the system OpenSSH client (`/usr/bin/ssh`), not an SSH library.** This gives the following for free, exactly as the user's terminal behaves:

- `~/.ssh/config`, including `Include`, `Match`, `ProxyJump`, and `ProxyCommand`;
- ssh-agent, the 1Password agent (approval prompts appear in 1Password's own UI), and hardware keys;
- `known_hosts` and `ControlMaster` multiplexing;
- macOS `UseKeychain` for key passphrases.

Runlet stores no keys and no passwords, and holds no crypto code. The cost is handling the remote shell and argument quoting carefully (§3.5).

### 3.4 Data model (`Packages/RunletKit/Sources/RunletCore`)

```swift
// Models.swift
public enum TargetRef { case sandbox, local(UUID), docker(UUID), ssh(UUID) }   // stableKey "ssh:<uuid>"

public struct SSHProfile: Codable, Hashable, Identifiable {
    var id: UUID; var name: String
    var host: String              // ~/.ssh/config alias or hostname, passed to ssh unchanged
    var user: String?; var port: Int?; var jumpHost: String?   // nil = whatever ssh config says
    var remoteDirectory: String   // absolute; may be a symlink (…/current)
    var phpExecutable: String     // "php"; validated like DockerProfile (no leading "-", no control chars)
    var container: RemoteContainerStep?   // optional docker exec step on the host
    var localSourcePath: String?          // first-class, §3.10
    var languagePHPVersion: String?; var strictTypes: Bool?
    var environment: TargetEnvironment    // .development / .staging / .production (N14), plus a colour
    var safeMode: SafeModeOptions?        // §3.13, optional
    var checkDrift: Bool                  // §3.10, off by default
    var compression: Bool                 // ssh -C, on by default (§3.14)
    var revision: Int; var lastOpenedAt: Date?
}

public struct RemoteContainerStep: Codable, Hashable {
    var identity: ContainerIdentity       // same type as Docker profiles: Compose project/service, name, last ID/image
    var workingDirectory: String; var phpExecutable: String
    var user: String?; var temporaryDirectory: String
    var dockerCommand: String             // "docker", or "sudo -n docker" (passwordless sudo only)
}
```

- `TargetLibrary` gains `sshProfiles`, with `strictTypes(for:global:)` and `localSourcePath` lookups like Docker's.
- `RunProtocol.swift`: `TargetSnapshot.Kind` gains `.ssh`. The snapshot gains an optional `ssh: SSHEndpoint` (host, user, port, jump, control path, compression, and the resolved real directory). The existing `containerId`, `containerName`, `image`, `user`, and `temporaryDirectory` fields carry the container step. All additions are optional Codable fields, so `runProtocolVersion` stays at 1.
- `Workspace.swift`: `WorkspaceTarget.ssh(SSHDefinition)` holds the host alias, directory, PHP, container identity, and the local folder as a relative path. Workspace files then name hosts; note this in the save dialog, since host names are infrastructure details even though they aren't secrets.

### 3.5 Transport: how Runlet calls `ssh`

- **New file `RunletExecution/SSH.swift`.** `SSHEndpoint.arguments(for: .run | .control | .interactive)` builds the argv, and `RemoteShell.script(_:)` POSIX-quotes words using the same rules as `ProjectCommandLauncher.shellQuote`.
- **Options on every non-interactive call:**
  - `-o BatchMode=yes` (never prompts) and `-o StrictHostKeyChecking=yes` (never accepts an unknown key);
  - `-o ConnectTimeout=10`, `-o ServerAliveInterval=15`, `-o ServerAliveCountMax=3` (a dead link ends a run with a transport error after about 45 s instead of hanging);
  - `-S <controlPath>`, plus `-o ControlMaster=auto -o ControlPersist=10m` for key or agent profiles, or `ControlMaster=no` for profiles that must log in interactively (§3.6);
  - `-T`, `-C` when compression is on, `-J` only when the profile overrides it, and `-o LogLevel=ERROR` to keep banners out of the run's stderr (verify that it suppresses the pre-auth banner).

  Runlet never passes `-F`, so the user's config always applies.
- **Remote command.** The command is always `/bin/sh -c '<script>'`. The script is POSIX `cd <dir> && export RUNLET_RUN_ID=<uuid> [TMPDIR=…] && exec <php> -d display_errors=stderr -d html_errors=0 -d log_errors=0`, with every word quoted. `ssh` joins its arguments into one string for the user's login shell. Wrapping everything in single quotes for `/bin/sh` works in bash, zsh, fish, and dash. csh and tcsh login shells need testing (risk: `!` history expansion).
- **Control socket.** `~/Library/Application Support/Runlet/SSH/<first 8 hex of profile id>.sock` (a new `AppPaths.ssh`), in a 0700 folder. A short name matters because macOS limits Unix socket paths to 104 bytes, and OpenSSH's `%C` hash (40 characters) would push long home paths past it. Use `ssh -O check` for status and `ssh -O exit` for Disconnect.
- **Listing hosts.** Parse `Host` lines without wildcards from `~/.ssh/config`, following `Include`. For each alias, `ssh -G <alias>` (which makes no connection) shows the effective `hostname`, `user`, `port`, `proxyjump`, and `identityagent` read-only in the form. The list is re-read whenever the profile editor opens, so no restart is needed (Tinkerwell 5.12 parity).
- **Exit-code mapping.** Mirror `CHANGELOG` "Clearer launch failures for Docker profiles". `ssh` exit 255 plus stderr gives plain-language reasons:
  - "Host key verification failed" leads to Connect…;
  - "Permission denied" leads to "not logged in; Connect…";
  - "Could not resolve hostname" and "Connection timed out" are network problems;
  - "Control socket connect … No such file" means the login expired; Connect… again.

  A `cd` failure means the directory is missing on the host. Exit 127 means PHP is not on that path.

### 3.6 Authentication, host keys, and connection status

| Method | How it works | User experience |
| --- | --- | --- |
| ssh-agent, 1Password, key files without a passphrase, `UseKeychain` | `BatchMode=yes` succeeds, and the first run opens a ControlMaster by itself (`ControlMaster=auto`). | Nothing to do. 1Password shows its own approval prompt; ControlPersist keeps later runs prompt-free for 10 minutes. |
| Password, keyboard-interactive or 2FA (OTP, Duo), key passphrase not in an agent | A **Connect…** action opens a terminal tab (the existing `TerminalPanel` and `TerminalRequest` with an `executable` argv) running `ssh -M -S <ctl> -o ControlPersist=<N> -N -f <host>`. The user types the password or code **into OpenSSH**. Once authenticated, `-f` backgrounds the master, the tab shows "exited 0", and Runlet marks the profile connected. Runs then use `-S <ctl> -o ControlMaster=no -o BatchMode=yes`. | A **Connect** button in the profile and a banner on the tab ("Not connected to app-prod. Connect…"). When the master expires or the network changes, the next run fails fast with the same banner. Disconnect sends `ssh -O exit`. |
| Unknown or changed host key | Every non-interactive call refuses (`StrictHostKeyChecking=yes`). Connect… is the only place a host key can be accepted, and the user answers OpenSSH's own fingerprint prompt in the terminal. | A clear "Verify host key" banner. A *changed* key shows OpenSSH's warning verbatim, and Runlet offers nothing to bypass it. |

**Password and 2FA: the two options considered.**

- **A. Interactive ControlMaster login in a Runlet terminal tab (recommended).**
  - OpenSSH handles every prompt type: password, multi-step keyboard-interactive, OTP, passphrase, host key, and FIDO touch messages.
  - The secret passes from the keyboard through the pty to `ssh`, exactly as in Terminal.app. Runlet never parses, stores, or logs it.
  - It reuses the terminal panel, which already handles command tabs and exit status.
  - Cost: the user re-authenticates when the master expires. Make `ControlPersist` configurable per profile (default 10 minutes; offer "until Disconnect").
- **B. `SSH_ASKPASS` helper with a native prompt.** Set `SSH_ASKPASS_REQUIRE=force` and point `SSH_ASKPASS` at a bundled helper that asks the app for a secure-field dialog.
  - Nicer UI, but the secret does pass through Runlet's processes (the dialog, IPC, and the helper's stdout). That breaks the "never handles the secret" requirement.
  - Host-key yes/no questions also go through askpass, which invites a reflexive "yes".
  - It still needs ControlMaster to avoid prompting on every run, and it needs a separately signed helper plus IPC.
  - **Not recommended.** Reconsider only if users find the terminal flow awkward. Even then, never offer "save password".

**Connection status.**

- `ssh -O check` reports Connected, Not connected, or Expired in the profile list and on the tab card.
- Runlet never opens an SSH connection at launch or when tabs are restored. The first connection happens on an explicit action: Run, Test Connection, Connect, List Commands, or Shell.
- This also avoids a surprise 1Password prompt every time the app starts.

### 3.7 Running code and streaming output

- **Plain host.** `SSHExecAdapter.prepare(target:runId:script:)` sits next to `DockerExecAdapter` in `ExecutionEngine.swift`. It builds the argv from §3.5 and returns `PreparedLaunch(spec:stop:)`. Its `ProcessSpec` has `standardInput: script`, which is the unchanged `RunnerBundle.script(…)` (the 826 KB `dist/runlet-runner.php` plus the request).
  - The runner arrives on stdin, as it does for local and Docker runs, so **nothing is written on the server**. Read-only homes and project folders work.
  - `RunSession` and `FrameDecoder` are unchanged. `ssh -T` keeps stdout and stderr on separate channels, so framing, raw output, the 8 MiB cap, and the single `finished` event behave as they do locally.
  - Text that a login script prints (a `.bashrc` that echoes) arrives as raw stdout. It is visible but harmless, because frames carry the nonce.
- **Docker on the host (container step).** Give `DockerCLI` a transport: `DockerCLI(transport: .local | .ssh(SSHEndpoint))`. Its `spec(arguments, stdin:)` then produces `ssh … host -- /bin/sh -c '<dockerCommand> <quoted args>'`.
  - Everything built on `spec` works unchanged over SSH: `runningContainers`, `inspect`, `DockerProfileResolver.resolve`, `probe`, `detectFacts`, `phpVersion`, `DockerExecAdapter.prepare`, and `stopInContainer`.
  - So the container step gets the same Compose identity, recreation handling, `ContainerChoiceSheet` for ambiguous replicas, and the re-check right before launch, without any of it being reimplemented.
  - Alternative considered: `DOCKER_HOST=ssh://host`. Docker's own SSH helper also uses the system `ssh`, but it can't share Runlet's control socket or Connect flow, so password and 2FA users couldn't use it. Rejected.
  - The remote user needs Docker access. `dockerCommand` may be `sudo -n docker` (passwordless sudo only); `sudo` prompts can't work in BatchMode.
- **Snapshot.** `AppModel.snapshot(for:)` gains `case .ssh`. It requires a live control socket for interactive-auth profiles; otherwise it raises the "Connect…" banner through `TargetResolutionError`. It resolves the container step like `.docker` does (an ambiguous match raises a `ContainerChoice` and never runs) and records the real working directory from the probe.

### 3.8 Stop

- **Plain host.**
  - The runner reports its PID in `started`.
  - `ssh … -- /bin/sh -c '<php> -r <signalHelper> -- <pid> <runId> <sig>'` reuses `DockerExecAdapter.signalHelper`, moved to a shared `RemoteSignal`. Before signalling, it checks `/proc/<pid>/environ` for `RUNLET_RUN_ID=<runId>`, so a reused PID is never signalled.
  - The sequence matches Docker: SIGTERM, wait 1.5 s, SIGKILL, wait 3 s, then a signal-0 check.
  - Because the remote command ends in `exec php`, PHP should become the leader of the sshd session's process group. The helper can then confirm `pgrp == pid` in `/proc/<pid>/stat` and signal `-pid`, which also stops processes the snippet spawned. That is better than Docker today. Verify on Ubuntu, Debian, and Alpine hosts.
- **Container step.** `stopInContainer` runs unchanged through the SSH-transport `DockerCLI`. The container keeps running.
- **Limits.** Killing the local `ssh` client alone is not enough: without a pty the remote PHP doesn't reliably get SIGHUP, so the helper is required.
  - Hosts without `/proc` (BSD or macOS servers) report "Stop unconfirmed" instead of signalling unverified PIDs.
  - Forcing a pty (`-tt`) to get SIGHUP is rejected: it merges stderr into stdout and rewrites newlines, which would corrupt raw output.

### 3.9 Test Connection, probe, and facts (no project code)

- **Test Connection** runs `SSHProbe`, a `php -n -r` program like `ContainerProbe`, through the control socket. It reports:
  - PHP version and binary, plus other PHP binaries found (`/usr/bin/php8.*`, `php8.3`);
  - user and uid;
  - whether the directory exists and is readable, and its realpath (for Forge-style `current` symlinks);
  - the framework, from file checks;
  - whether the tmp directory is writable, and whether the tokenizer is available;
  - how Stop can signal (`posix`, `shell`, or `none`, and whether `/proc` exists);
  - candidate app directories (`~/*/current`, `/var/www/*`, `/home/*/*` containing `artisan` or `composer.json`);
  - `composer.json` `name`, and the git `remote.origin.url` and `HEAD` when drift checking is on.

  Nothing in the project runs: `-n` skips php.ini, and the code only reads files.
- **Facts** (`AppModel.detectFacts(for:)`):
  - With a local folder: `TargetInspector.staticFacts(projectRoot: local)`, read on this Mac with no network. Tab cards fill in immediately.
  - Without a local folder: the shared `detectFacts` PHP program (now `RemoteFacts.script`, used by Docker and SSH), run over SSH.
  - The remote PHP version is fetched only once a connection exists. For production profiles, only after an explicit Test Connection or the first confirmed run.
- **BatchMode everywhere** for probes, facts, listings, and Stop. No call except Connect… can show a prompt.

### 3.10 Local project folder per host (first-class)

**Where it lives.** `SSHProfile.localSourcePath` is one folder per profile, shared by the plain host and the container step. It maps to whichever runtime root the run uses: `remoteDirectory` (and its realpath) for a plain host, or the container's working directory for the container step.

**What it powers, and the code it reuses:**

| Feature | With a local folder | Without one (limited mode) |
| --- | --- | --- |
| Completion and diagnostics | `AppModel.languageWorkspace(for:)` returns `LanguageWorkspace(kind: .project, rootPath: local, phpVersion: languagePHPVersion ?? remote PHP from facts)`. The scratch URI `<root>/.runlet-scratch/tab-<uuid>.php` is never written, and `ScratchDocumentMapping` applies, as for local and Docker targets. | The `.basic` workspace. `DiagnosticFilter.visible(…, limitedWorkspace: true)` drops false "unknown symbol" diagnostics, and `LanguageWorkspace.sourceLimitations()` explains why ("Set a local folder for project completion"). |
| Driver variables in completion | The run's `bootstrapped.variables` become hidden `@var` lines, and their classes resolve against the local source (`$app`, or a project driver's `$_app`). | Only type names; members don't resolve. |
| Framework and driver facts | `TargetInspector.staticFacts` on the local folder (including `.runlet/*Driver.php` name and version literals). No network needed. | `RemoteFacts.script` over SSH, after connecting. |
| Project snippets | `AppModel.projectRoot(for:)` returns the local folder, so `ProjectSnippets` loads `.runlet/snippets/*.php` and "Save Snippet to Project…" works. | None. A later option is a read-only list from the server on explicit Refresh. |
| Host commands | `hostCommands()` run on this Mac in the local folder, through `HostCommandLister` and `HostShellEnvironment` (deploy scripts, `git pull`, the team's CLI). Declarations come from the last run or listing, as for Docker (`State/facts.json`). | Hidden, with the hint "needs a local folder". |
| Open Project in Editor | `AppModel.projectFolder(for:)` returns the local folder. | Disabled, with the reason. |
| Terminal | New shells start in the local folder (`AppModel+Terminal` working-directory logic). "+ ▸ Shell on <host>" opens the remote shell (§3.11). | New shells start in home. |
| File links in output | A new `EditorPathMapping` case, `.remote(roots: [remoteDirectory, realpath, container working dir], localRoot:)`, maps dump cards, error cards, and stack frames to local files, which open through `openInExternalEditor`. Forge-style releases: PHP reports *resolved* paths (`…/releases/2026…/app/…`), so the run's `started.workingDirectory` (a realpath) is added as a root, and both `current/` and `releases/<id>/` map to the same local file. | Plain text, with the reason "Set a local folder to open server files" (same pattern as Docker's unmapped message). |

**Suggesting a folder.** The profile form and Test Connection both suggest one. Like Docker's bind-mount `noteSourceSuggestion`, the suggestion is applied only with a click. Signals, strongest first:

1. The remote `git remote.origin.url`, normalized (`git@github.com:org/app.git` ≈ `https://github.com/org/app`), matched against local repositories in Runlet's known targets (local projects and Docker sources), recent folders, and a shallow scan of common roots (`~/Code`, `~/Projects`, `~/Sites`, `~/Herd`) that reads only `.git/config`.
2. `composer.json` `name` matched against local `composer.json` files.
3. The directory name: the remote basename, or the site folder for `/home/forge/<site>/current`.

**Drift warning (optional, off by default; `checkDrift`).**

- Off by default because it runs `git` on the server. When on, Runlet runs `git -C <dir> rev-parse --abbrev-ref HEAD` and `git -C <dir> rev-parse HEAD` over SSH after each connect, and compares them with the local folder.
- Deployments without `.git` (zero-downtime releases) fall back to comparing `sha1_file('composer.lock')` remotely (`php -n -r`) with the local copy.
- The result is a yellow banner: "Local checkout `feature/x` @abc123 differs from the server `main` @def456. Completion and file links may not match." It never blocks a run.

### 3.11 Drivers, project commands, host commands, terminal

- **Drivers work unchanged on the server.** The runner reads `.runlet/*Driver.php` from the **remote** working directory, so drivers that are committed or deployed just work. This includes `commands()`, `variables()`, and the declarations from `hostCommands()`.
  - Gap: a `.runlet/` folder that is git-ignored and exists only locally (the documented global-ignore case) isn't on the server.
  - Option (SSH-9): "Send local `.runlet` drivers with each run". The request carries the driver sources; the runner `eval`s them after rewriting `__DIR__` and `__FILE__` tokens to `<remote dir>/.runlet`.
  - Limit: single-file drivers only, since a `require __DIR__.'/boot.php'` helper wouldn't exist remotely. The same mechanism serves global drivers (N25).
- **Project commands (Commands pane).**
  - Listing boots the application on the server, which runs project code. For SSH profiles the pane **never lists by itself**: it shows "List commands on <host>", and production profiles also confirm.
  - Running a command: `ProjectCommandLauncher.terminalRequest` gains an `.ssh` case. It opens a command tab with argv `ssh -t -S <ctl> <host> '/bin/sh -c "cd <dir> && <command>"'`, with `php` replaced by the profile's PHP (as `localCommandLine` does). The container step uses `ssh -t … docker exec -it … sh -lc '<command>'`.
  - `needsInput` commands open an interactive remote shell and type the command without Return.
  - Production profiles confirm each command, showing the command line and the host.
- **Host commands** always run on the Mac in the local folder (§3.10). They never touch the server unless the command itself does, as `ssh`-based deploy tools do.
- **Terminal "+" menu.**
  - "Shell on <host>": `ssh -t -S <ctl> <host>`, then `cd <dir> && exec $SHELL -l`.
  - "Shell in <container> on <host>": `ssh -t … docker exec -it …`, with bash if available, else sh.
  - Both resolve like a run and never substitute a different container.

### 3.12 Profile UI

- **Profiles window.** Generalize `DockerProfileManager` into one Profiles window with a Docker / SSH switch in the list. It keeps the same pattern: draft until Save (↩ or ⌘S), Revert, Save / Don't Save / Cancel on switch or close, Duplicate, and Use in Current Tab.
- **`SSHProfileForm` fields.**
  - Host: a combo box of `~/.ssh/config` aliases, with the effective `ssh -G` values shown read-only below it.
  - Remote directory, with Suggest (from probe candidates) and the realpath shown.
  - PHP, picked from discovered binaries.
  - **Run inside a container on this host**: a container picker listing remote containers with their Compose identity, the working directory with suggestions, user, tmp, and the Docker command.
  - **Local folder**: a folder picker, the suggestions from §3.10, and a "Use for Completion" button.
  - Language PHP version and strict types.
  - **Environment**: development, staging, or production, plus a colour.
  - Safe mode, drift check, compression, and keep-alive duration.
  - Test Connection, and Connect… or Disconnect.
- **Elsewhere.**
  - The target menu gets an "SSH" section with status dots.
  - The palette's `@` prefix (Tinkerwell's "connections") covers Docker and SSH. Add commands for New SSH Profile…, Connect, and Disconnect.
  - Vertical tab cards: a runtime chip "SSH" (or "SSH · Docker"), a second line `user@host:dir`, and a red **PRODUCTION** chip when flagged (`VerticalTabs.swift`).
  - Settings ▸ Targets lists SSH profiles.
  - Workspace files embed SSH definitions (§3.4).

### 3.13 Production guard rails and safe mode

This is part of N14 and applies to every target kind. For SSH it is required.

**When a profile is marked production:**

- **Badges.** A red PRODUCTION chip on the tab card and horizontal tab, a red dot and label in the target menu and palette rows, and a red stripe in the status bar (`MainWindow.StatusBar`).
- **Confirm before each run.**
  - The sheet shows the profile, `user@host`, the directory, the container if any, and the first 12 lines of what will run (the selection when Run Selection is used), with the line count.
  - The default button is "Run on Production" and needs ⌘↩; a plain ↩ only cancels.
  - "Don't ask again for 10 minutes on this profile" is kept in memory only. It resets on relaunch and when the profile is edited.
  - The same sheet covers remote project commands and the "List commands" boot.
- **Stricter defaults.**
  - Runlet never connects on its own; facts come only from the local folder.
  - The Commands pane never auto-lists.
  - Auto-run (N17) can't be enabled.
  - Snippets opened from history or the palette land in a tab without running, as today.
  - History marks production runs.
- **Environment detection.** `bootstrapped` gains an optional `environment` field (`$app->environment()` for Laravel). When a run reports `production` on a profile that isn't flagged, Runlet shows a one-click "Mark as production" banner.

**Safe mode (optional, per profile, off by default, suggested for production).**

| What it does | Mechanism | What it can't guarantee |
| --- | --- | --- |
| Rolls back database writes | `LaravelDriver` begins a transaction on the default connection (or connections listed in the profile) before the snippet and always rolls back afterwards. The output reports "rolled back". | Writes on other connections or through raw PDO. MySQL implicit commits (DDL, `TRUNCATE`, `LOCK TABLES`) end the transaction early. Non-transactional engines (MyISAM). A snippet calling `DB::commit()` without its own `beginTransaction()` commits the outer transaction. **Long runs hold row locks on production tables**, so show a warning when a safe-mode run passes 5 s. |
| Intercepts mail, notifications, and queued jobs | `Mail::fake()`, `Notification::fake()`, `Queue::fake()` (the fakes ship in `laravel/framework`). The run inspector (N03) lists what was intercepted. | Mail sent through a different client, and Redis or SQS pushes made without the queue manager. |
| Blocks outgoing HTTP through Laravel's client | `Http::preventStrayRequests()` | Raw curl, Guzzle instances created directly, sockets. |
| Disables process execution | `-d disable_functions=exec,shell_exec,system,passthru,proc_open,popen,pcntl_exec` on the `php` command line. This is enforced by PHP itself. | Nothing else (files, cache, Redis, S3). |
| Uses a read-only database connection | Optional `config(['database.default' => '<name>'])` pointing at a replica or a read-only user the project already defines. | This is the **only real guarantee**, and only if that database user lacks write grants. |

The UI always says "Safe mode is a safety net, not a sandbox", and links to this table. Other frameworks can implement a `safeMode()` driver hook later; WordPress and Doctrine can wrap a transaction the same way.

### 3.14 Performance

- **Payload.** Each run streams the 826 KB runner bundle plus the request. Rough guesses to measure: about 0.1 s at 100 Mbit/s, about 0.7 s at 10 Mbit/s, about 7 s at 1 Mbit/s. PHP source compresses well, so `ssh -C` (on by default) should cut this several times over (guess: 4–6×).
- **Handshake.** Without multiplexing, each run pays for TCP, the key exchange, and authentication (guess: 0.2–1 s, plus the agent prompt). With ControlMaster, a new session should cost tens of milliseconds (guess). Runs, Stop, probes, and listings all share one master per profile. Runlet's `maxConcurrentRuns` (4), plus Stop and listings, stays under OpenSSH's default `MaxSessions` of 10.
- **Optional runner cache (opt-in per profile, off by default).** This writes to the server, which breaks the "nothing written" principle; that is why it is opt-in.
  - Store the bundle once in `${XDG_CACHE_HOME:-~/.cache}/runlet/runner-<sha256>.php`: folder 0700, file 0600, written atomically through `php -n -r` (`tempnam` plus `rename`), never in the project.
  - Each run then sends a small stub. It checks `hash_file('sha256')` and the file owner before `require`, then calls `\RunletRunner\Runner::main(…)`.
  - On a mismatch (exit 86), Runlet falls back to streaming and rewrites the cache.
  - Read-only homes fall back to streaming.
  - Recommendation: ship streaming plus `-C` first. Measure on the user's real servers by adding an `--ssh <profile>` timing check to `Runlet --self-test`. Add the cache only if the payload costs more than about 300 ms.
- **Facts and fast feedback.** With a local folder, tab cards never wait for the network.

### 3.15 Implementation plan

| Milestone | Scope | Size |
| --- | --- | --- |
| **SSH-1 Core** | `SSHProfile`, `TargetRef.ssh`, `TargetSnapshot.Kind.ssh`, `SSHEndpoint` and `RemoteShell` quoting, `SSHExecAdapter` (stream, framing, exit-code mapping), shared `RemoteSignal` Stop, ControlMaster for key and agent auth, `SSHProbe` with Test Connection, and a minimal profile sheet. Fixture: a disposable `php-cli` + `openssh-server` container on `127.0.0.1:2222` with a throwaway key and a temporary `HOME` and `known_hosts`. Tests cover run, dump, `dd`, exit, fatal, Stop (including spawned children), concurrency, dead link, unknown host key, and a read-only home. | M |
| **SSH-2 Interactive auth** | Connect… and Disconnect through a terminal tab with ControlMaster, `-O check` status, banners, expiry handling. Live package test: a password-auth fixture driven through a pty (`script(1)`, as in `ShellIntegrationLiveTests`). | M |
| **SSH-3 Local folder** | Language workspace, the `.remote` `EditorPathMapping` (including releases realpaths), `staticFacts`, project snippets, host commands, Open in Editor, terminal start folder, suggestions (git remote, composer name, folder name), drift check. | M |
| **SSH-4 Production guard** | Built as N14 for all targets: flag, colour, badges, confirm sheet with the 10-minute grace, stricter defaults, environment detection. | S–M |
| **SSH-5 Commands and shells** | Remote project commands with confirmation, "List commands on <host>", Shell on host, `needsInput`. | M |
| **SSH-6 Remote Docker** | `DockerCLI` SSH transport, container picker, resolver and `ContainerChoiceSheet` reuse, container-step Stop and path mapping. | M |
| **SSH-7 UI and integration** | Profiles window (Docker + SSH), `~/.ssh/config` import, palette `@`, Settings ▸ Targets, workspace files, a fake `ssh` CLI for screenshot tours (never real servers; see the fake-docker approach). | M |
| SSH-8 Safe mode (optional) | Laravel transaction rollback, fakes, `disable_functions`, connection override, lock warning. | M |
| SSH-9 Extras (optional) | Runner cache, local driver injection, self-test timing. | S–M |

SSH-1 to SSH-4 make a usable first release (plain hosts, any auth, local completion, production guard). SSH-5 to SSH-7 complete the feature.

**Status (2026-10-02).** N14 and SSH-1 to SSH-7 are implemented (SSH-8 safe mode and SSH-9 extras are not); the user guide is [ssh.md](ssh.md). Where the code differs from this design:

- **Stop** signals every process whose environment carries the run's `RUNLET_RUN_ID` (the runner plus whatever the snippet started, even after `setsid`) instead of checking `pgrp == pid` and signalling the group. Docker profiles keep the runner-only helper.
- **Status** comes from connecting to the control socket on this Mac, not `ssh -O check`, so checking never starts `ssh` (no `Match exec` or `ProxyCommand` from `~/.ssh/config` runs at launch). Disconnect still uses `ssh -O exit`.
- **ControlPersist**: Connect… logins always stay until Disconnect (user decision) and outlive Runlet restarts; masters that agent/key runs open keep the per-profile time (10 minutes by default, or until Disconnect).
- **Facts without a local folder** are never fetched in the background; the server's PHP version and framework come from Test Connection and runs.
- **Drift** reads the server's `.git` files and a CRC-32 of `composer.lock` with the read-only PHP probe (no `git` runs on the server), after Connect…, Test Connection, and the first run of a session.
- **Connect…** forces `StrictHostKeyChecking=ask`; helper PHP code (probe, Stop) travels base64-encoded so any login shell's quoting leaves it intact.
- **SSH-7 (UI and integration)**: the Docker Profiles window became the Profiles window (`ProfileManager`: Docker and SSH sections instead of a Docker / SSH switch; the same draft, Save/Revert, and unsaved-changes model; the scene id `docker-profiles` is kept). `~/.ssh/config` import is a sheet with `ssh -G` summaries, an optional directory, and an environment guessed from the alias. Settings ▸ Targets gained Import and Manage Profiles… for SSH (and SSH hosts in the default-target picker); ⌘P's `@` shows SSH hosts with their container; workspace files embed SSH profiles including the container step; palette commands: Manage Profiles…, Import SSH Hosts…, Open Shell on SSH Host, Connect, Disconnect. The screenshot fake is `Tests/Fixtures/fake-ssh/ssh` (Debug `RUNLET_SSH_EXECUTABLE`), a loopback that runs commands on this Mac.
- **Not done (optional milestones)**: SSH-8 safe mode and SSH-9 extras (runner cache, local driver injection, self-test timing). Both need runner changes.
- **Commands panel**: SSH hosts list only on request (production asks; password hosts offer Connect… first), host commands run in the local folder.
- **SSH-5 (commands and shells)**: commands run as `ssh -t` (BatchMode, strict host keys, the shared connection) with `/bin/sh -lc 'cd <dir> …; <command>'` instead of `/bin/sh -c "cd <dir> && <command>"`, so login PATH additions apply; needs-input commands open `exec "$SHELL" -l` in the directory and type the command. Shell on Host is in the terminal "+" menu, the target menu, the Commands panel, and the palette. Production asks before every command, listing, and shell (a new `GuardedAction.shell`); the grace stays snippet-only.
- **Not done yet**: the `bootstrapped.environment` "Mark as production?" banner (it needs a runner change) and marking production runs in History.
- **Profile form (after user testing)**: Directory gained Detect (home folder plus application folders, read-only `php -r`) and Browse… (a folder picker on the server, symlinks kept); validation checks the saved (trimmed) values and explains an empty field and `~`; Connect… from the sheet works before the profile can be saved and reopens the sheet after the login.
- **SSH-6 (Docker on the host)**: as designed (`DockerCLI` with an SSH transport, the unchanged resolver and adapter, `ContainerChoiceSheet`, Stop through the container), with these details: the container step is resolved only on explicit actions (run, command, shell, Test Connection, List Containers), never on open; the server directory stays required (Detect, Browse…, drift, and the bind-mount path mapping use it) but the server needs no PHP of its own; the snapshot gained `dockerCommand` and `localFolderRoot`; recording the resolved container ID doesn't count as an edit; and the shared resolver now keeps a replica the user chose (before, every run with several replicas asked again). Remote Docker is tested with a fake `docker` on the SSH fixture rather than docker-in-docker.
- **Open questions answered**: servers are Linux (Stop degrades to "unconfirmed" without `/proc`); the 10-minute grace covers snippet runs only; production badges are always red, and the per-target colour is separate. csh/tcsh login shells remain untested.

### 3.16 Later options and open questions

- **Later:** Forge and Ploi site import (N24; Forge API v2 with the `server:view` scope, zero-downtime `current` detection), Kubernetes (N23, the same transport idea with `kubectl exec -i`), and Docker contexts (N21).
- **Open questions:**
  - Are any servers non-Linux? Stop needs `/proc` to be confirmed.
  - Does anyone use csh or tcsh as a login shell?
  - Should the 10-minute grace also cover remote project commands?
  - What `ControlPersist` default is acceptable for 2FA hosts?
  - Should production profiles keep their badge colour fixed (red) or allow customizing it?

## 4. Other ideas by theme

P1 and P2 ideas have full entries. P3 ideas are in a table at the end of each theme, with the same fields.

### A. See what a run did ("run inspector")

#### N01 · SQL query inspector — P1 · M

- **What.** An Output ▸ **Queries** tab next to the output, showing a count and total time. Each query shows its connection, SQL with highlighted bindings, a readable interpolated form, the time, and the snippet line that caused it. Repeated statements are grouped ("37× same query", hinting at N+1). The tab offers Copy SQL, Copy with bindings, and **Explain**, which opens `DB::select('EXPLAIN …')` in a new tab without running it.
- **Why.** "What did Eloquent actually do?" is the most common Laravel scratchpad question. Tinkerwell offers it for Laravel and WordPress (and SQL Server since 4.13).
- **Fit.**
  - New driver hook `Runlet\Driver::instrument(\Runlet\Recorder $r): void`, called after `bootstrap()` and before the snippet (`Resources/Runner/src/Drivers.php`).
  - `LaravelDriver` listens for `QueryExecuted` and uses `substituteBindingsIntoRawSql` when the grammar has it, as Tinkerwell's public driver does. `WordPressDriver` defines `SAVEQUERIES` before load and reads `$wpdb->queries` at the end (verify against `wp-config` overrides).
  - The recorder emits `record` frames through `Channel::emit`. Add one generic `RunEvent.Kind.record(RecordInfo{category, snippetLine, payload})` in `RunProtocol.swift`, so N02 and N03 reuse it.
  - `TabModel.apply(_:)` stores the records per run, and `OutputPane.swift` gets a segmented header.
  - `RunRequest` already carries per-run flags such as `strictTypes`; add `record: [categories]` the same way (`RunnerBundle.script`).
- **Risks.** Volume: cap at about 2,000 queries per run and bound bindings with `ValueNormalizer` limits, reporting truncation. Explain is a separate, explicit run. Symfony/Doctrine needs DBAL middleware configured at kernel build time (P3), though project drivers can still record through `$r`.

#### N02 · Mail capture and HTML, view, and mailable preview — P1 · M

- **What.**
  - Returning or dumping a Mailable, a `MailMessage`, a View, an `Htmlable`, or a Symfony `Response` shows **Preview**: the rendered HTML in a sheet or window, with a Text/HTML switch and a Run Again button. Tinkerwell's preview also reruns with ⌘R.
  - A **Mail** tab lists mail sent during the run (`MessageSending`): to, subject, HTML, text, and attachment names.
- **Why.** Developing emails and Blade output without sending mail or opening routes. It is a headline Tinkerwell feature.
- **Fit.**
  - The runner renders only these known types, and only when "Render previews" is on (default on). Rendering is what returning a mailable means, but it does run view code, so its queries show up in N01.
  - It emits `record(category: "html")` with HTML capped at about 2 MiB.
  - The preview is a `WKWebView` with `allowsContentJavaScript = false` and a `WKContentRuleList` that blocks every non-`data:` load. "Load remote images" is a per-preview toggle, because emails contain tracking pixels.
  - The mail listener lives in `LaravelDriver::instrument`. Optional per-target "Intercept mail" (the `array` mailer) is shown as a chip; it is also part of safe mode (§3.13).
- **Risks.** Rendering executes view code, so keep it off for production targets unless asked. No JavaScript, no network.

**Status (2026-10-02).** N01, N02, and N04 are implemented ([drivers.md](drivers.md#run-inspector)). Where the code differs from these entries:

- **API.** The hook is `Driver::inspect(Runlet\Inspector $inspector)`, and the inspector is more than a recorder: `query()`, `mail()`, `log()`, `html()`, and `record($section, $title, $value)` for sections a driver defines, plus `watchPdo()`. Database detection (Eloquent with or without Laravel, Doctrine DBAL 2–4, WordPress) is a set of helpers every driver inherits, so project drivers for non-Laravel apps get queries too. Log messages (N03's Log tab) came along for Laravel.
- **Protocol.** Instead of one `record(category, snippetLine, payload)` event, the runner sends `inspector` (sections, interception), `record` (with a `section` and a `kind`), and `recordLimit`; the app folds them into one `RunEvent.Kind.inspector`. The `record` request flag is `inspector: {enabled, interceptMail, previews}`.
- **Previews** are not `record(category: "html")` events: they travel on the `result` and `dump` they belong to, so the preview sits on its value's card (Preview, Tree, Table). `Driver::preview()` decides, so project drivers can add types.
- **Mail interception** uses `MessageSending` listeners that return `false` (the message is built, then not sent) instead of swapping in the `array` mailer, which would miss mailers resolved during boot and named mailers. It is off by default and visible (header chip, run label, output lines, Mail banner); mail on asynchronous queues can't be intercepted and is listed as queued.
- **Not built:** Explain (opening `EXPLAIN …` in a new tab), Symfony Doctrine and Mailer without a fixture to test against (the code is there, untested), and SQL Server specifics.

#### N03 · Run recorder: logs, HTTP calls, jobs, and events during a run — P2 · M

- **What.** More inspector tabs: **Log** (`MessageLogged`, with level, message, and context), **HTTP** (`Http` client `RequestSending`, `ResponseReceived`, `ConnectionFailed`: method, URL, status, duration, with `Authorization` and cookie headers redacted), and **Jobs** (`JobQueued` in recent Laravel versions, verify the minimum version: class, queue, connection). An optional **Events** tab is off by default because it's noisy.
- **Why.** It goes beyond Tinkerwell, which has only SQL: a Telescope-like view of one run without installing Telescope.
- **Fit.** The same `instrument()` and `record` pipeline as N01. Categories are opt-in in Settings ▸ Output.
- **Risks.** Redaction and size caps. These are listeners only; they never change behaviour, except intercepting fakes when safe mode is on.

### B. Output and visualisation

#### N04 · Output export leftovers — P1 · S

- **What.** Table row context menu: Copy Row as JSON, Copy Row as PHP Array (keys kept). Copy Output as Markdown (fenced blocks; cards as headings). Run ▸ Save Output As… (`.txt` or `.md`). URLs in Plain and Raw output become links.
- **Why.** Tinkerwell parity (Detail Dive row copy, 5.11 Markdown, 3.18 save to file, 5.4.1 links). This was B12 in the earlier review and was not built.
- **Fit.** `ValueTableView` and `OutputPane.swift`, `TabModel.outputText(for:)`, new registry commands in `Commands.swift`, and `NSDataDetector` for links.
- **Risks.** None.

#### N05 · Readable values: built-in summaries and driver casters — P2 · M

- **What.** Collapsed one-line summaries for common types:
  - `DateTimeInterface` and Carbon (ISO date and timezone);
  - enums (`Status::Active = 'active'`);
  - Eloquent models (`App\Models\User #12`, then attributes, loaded relations, and dirty state);
  - collections (count);
  - `Stringable`, UUID, and Money-like value objects through driver casters.

  A driver can add `casters(): array` (class => closure returning a scalar or array) for domain types.
- **Why.** Raw object trees of Carbon or models are long and noisy. Tinkerwell added a custom Carbon caster (3.8).
- **Fit.** `ValueNormalizer::objectNode` in `Runner.php` gets an allowlist that may call trusted core methods (`format`, `->value`). `ValueNode` gets an optional `summary`. `ValueTreeView` shows it.
- **Risks.** The plan's rule is "no getters or `__toString` on arbitrary objects". Keep the allowlist to core and framework classes; driver casters are project code the user wrote.

#### N06 · Specialized viewers — P2 · S

- **What.** A string that is valid JSON gets a "JSON" toggle (tree view plus Copy Pretty). Long strings open in a viewer with wrapping and search. Base64 PNG, JPEG, or SVG data shows an image preview. A string that looks like HTML offers N02's preview.
- **Why.** API responses (`Http::get()->body()`) are strings today.
- **Fit.** `ValueContentView` in `OutputPane.swift`, Swift-side only, with no runner changes.
- **Risks.** Detection must be cheap and bounded (it already applies to strings capped at 64 KiB).

#### N07 · Source excerpts in error cards — P2 · S

- **What.** Error cards and stack frames show about 5 lines of source around project-file frames, read from the host path (local projects, or Docker and SSH local folders through `EditorPathMapping`).
- **Why.** Tinkerwell's Collision integration shows code context. This is the cheap equivalent.
- **Fit.** `OutputPane.swift` error card, `EditorPathMapping.resolve`.
- **Risks.** The local file may differ from the remote one (drift). Label it "local copy".

#### N08 · Timing breakdown — P2 · S

- **What.** The finished card and status-bar tooltip show bootstrap, execute, and total time, peak memory, start time, and time spent in queries (N01).
- **Why.** Shows whether the snippet or the framework boot is slow. Tinkerwell shows time, memory, and start time.
- **Fit.** The runner already reports `bootstrapped.bootstrapMs` and `runnerFinished.executeMs`. Carry them into `FinishedInfo` and show them.
- **Risks.** None.

**P3**

| ID | Idea | What and why | Fit | Size | Risks |
| --- | --- | --- | --- | --- | --- |
| N09 | Charts from tables | Bar or line chart of a table's numeric column against another column, for quick reports. Beyond Tinkerwell. | Swift Charts over `ValueTable` in `ValueTableView`. | M | Only for small, bounded tables. |
| N10 | Output history per tab and diff | Keep the last 5 outputs per tab, switch between them, and diff two results (for example before and after a code change). | `TabModel` keeps per-run `OutputItem`s, with a text diff of `ValueNode.plainText`. | M | Memory: cap it, and never persist results by default. |

### C. Inline debugging

#### N11 · Magic comments — P1 · L

- **What.**
  - `//?` at the end of a line shows that line's value. `/*?*/` inside an expression shows the intermediate value. `/*?->count()*/` shows a projection without changing the chain. `/*?.*/` shows the elapsed time at that point.
  - Values appear as dim inline text after the line. Hovering shows the full value tree.
  - Repeated hits (loops) show `×N`, the last value, and a list.
  - Values stream in while the code runs; Tinkerwell requires buffered output. Highlight magic comments in the editor (Tinkerwell 4.17).
- **Why.** Tinkerwell's signature feature. Inspect without adding `dump()` calls or temporary variables.
- **Fit.**
  - `SnippetCompiler` finds magic comments with the tokenizer and parser, and wraps the target expression by **inserting text at byte offsets**: `\RunletRunner\Probe::at(<id>, <expr>)`, or `->tap()`-style for `/*?->x()*/`.
  - It doesn't pretty-print, because the bundled php-parser omits the printers (`scripts/build-runner.php`), and because offset insertion keeps line numbers.
  - `Probe::at` emits `record(category: "inline", id, line, value)` with a small depth limit.
  - `EditorController` draws ghost text after the line end (custom drawing in the layout-manager pass, next to the diagnostics underlines). `LineNumberRulerView` gets a hit marker. Values map through `RunRequest.editorLine(forSnippetLine:)`, so Run Selection works.
- **Risks.**
  - Inserting into expressions must not change evaluation order or reference semantics. Fixture-test against `&$x`, `static fn`, named arguments, and nullsafe chains.
  - Projections (`->count()`) are user code and may run queries; that is expected.
  - Cap the events per probe (for example the first 100 hits, then counts only).

#### N13 · Xdebug "Debug Run" — P2 · M

- **What.** Run ▸ Debug Run (or a per-tab toggle) starts the run with Xdebug triggered, so the IDE stops at breakpoints in project files.
- **Why.** Tinkerwell supports this only with Herd. Runlet can do local and Docker, and SSH later.
- **Fit.**
  - The adapters add `-d xdebug.mode=debug -d xdebug.start_with_request=yes`, plus `-d xdebug.client_host=host.docker.internal` for Docker. Set `PHP_IDE_CONFIG=serverName=<profile>` so PhpStorm's path mappings work.
  - The probe reports whether Xdebug is loaded; the command is disabled with a reason if not.
- **Risks.** Breakpoints in the eval'd snippet don't work; say so. Never enable it implicitly. For SSH it needs a reverse tunnel (`ssh -R 9003:localhost:9003`): P3.

**P3**

| ID | Idea | What and why | Fit | Size | Risks |
| --- | --- | --- | --- | --- | --- |
| N12 | Execution coverage and Auto Log | Gutter marks for executed lines with hit counts. Auto Log logs every top-level statement's value (Tinkerwell 3.0 "automatic code coverage"). | Builds on N11's statement instrumentation and ruler markers. | M | Output volume; off by default. |

### D. Safety and running

#### N14 · Target environments and production guard — P1 · S–M

- **What.** Every target (local, Docker, SSH) gets an environment (development, staging, production) and a colour. Tabs, the status bar, and the target menu show them. Production adds confirm-before-run and the stricter defaults in §3.13. `bootstrapped.environment` triggers a "Mark as production?" banner.
- **Why.** It is needed before SSH, and it makes Docker containers that point at shared databases safer. Tinkerwell has connection colours and a coloured status bar.
- **Fit.** `LocalProject`, `DockerProfile`, and `SSHProfile` get `environment` and `color` (optional Codable fields). The confirmation sits in `AppModel.run` before `snapshot(for:)`. Chips go in `VerticalTabs.swift`, the stripe in `MainWindow.StatusBar`. Add `environment` to the Laravel `bootstrapped` payload.
- **Risks.** Confirmation fatigue; the 10-minute grace and ⌘↩ default address it.

#### N15 · Rollback ("dry run") mode — P2 · M

- **What.** A per-tab toggle that runs the snippet inside a database transaction and always rolls back, showing "rolled back N statements". It is the database part of §3.13 safe mode, available on any target.
- **Why.** Lets you try data fixes on real data safely. Beyond Tinkerwell.
- **Fit.** `LaravelDriver` with a `rollback` request flag. Count statements through N01.
- **Risks.** Same limits as §3.13: implicit commits, other connections, locks held during long runs.

#### N16 · Parameterised snippets — P2 · M

- **What.** Snippet docblocks declare inputs, for example `@input int $userId "User ID"` or `@input string $email`. Opening the snippet shows a small form; values are inserted as PHP literals (`var_export`) at the top of the new tab. It never runs.
- **Why.** Team runbooks ("refund order #…") without hand-editing code. This is the modern version of Tinkerwell's dynamic snippets.
- **Fit.** `ProjectSnippets.swift` metadata parsing, a sheet in `LibraryInspector.swift`. Personal snippets too.
- **Risks.** Literal generation must escape correctly; use `var_export` semantics on the Swift side and test them.

#### N20 · "Start the stack" from the failure banner — P2 · S

- **What.** When a Docker profile's container isn't running, the error banner offers the project's start command. That is a `hostCommands()` entry flagged `'start' => true`, for example `docker compose up -d` or the team CLI's `start`. It is one explicit click and runs in a terminal tab.
- **Why.** Uses the existing host-commands pieces. Beyond Tinkerwell.
- **Fit.** `hostCommands` metadata (`ProjectCommand` gets `role`), the `tab.targetIssue` banner in `MainWindow.swift`, and `openTerminal`.
- **Risks.** Runs only on click, on the Mac, in the local folder.

**P3**

| ID | Idea | What and why | Fit | Size | Risks |
| --- | --- | --- | --- | --- | --- |
| N17 | Sandbox-only auto-run | Opt-in per tab, sandbox only, debounced (800 ms). An "AUTO" chip shows; it never applies after a restore. Tinkerwell auto-evaluates by default. | Debounced `AppModel.run` from the editor change handler. | S | Exception to "explicit Run", so sandbox only, off by default, never for Docker, SSH, or production. |
| N18 | Per-target prelude | `.runlet/prelude.php` or a profile field runs before every snippet (`auth()->loginUsingId(1)`). A visible chip shows it. | The runner request gets `prelude` code, evaluated in the snippet scope. | S | Hidden behaviour; always show the chip. |
| N19 | Stateful REPL in the terminal | The Commands pane gets "Open REPL": `php artisan tinker` or psysh in a terminal tab on the target, for state between runs. | `ProjectCommandLauncher` with a synthetic command. | S | None; it's the user's own REPL. |

### E. Other targets

#### N21 · Docker contexts and custom exec flags — P2 · S

- **What.** A Docker profile can name a Docker context (local Colima, OrbStack, remote) and extra `docker exec` flags from a validated allowlist (`--env K=V`, `--privileged` refused).
- **Why.** Tinkerwell 5.10 exec flags; several Docker engines on one Mac.
- **Fit.** `DockerCLI` passes `--context`. `DockerProfile` gets `context` and `extraEnv`.
- **Risks.** Validation, so no flag injection.

#### N22 · Sail, DDEV, and Lando presets; Herd isolation — P2 · S

- **What.** Opening a project folder detects `.ddev/config.yaml`, `.lando.yml`, or a Sail `docker-compose.yml` (`laravel.test`), and offers a prefilled Docker profile. Examples (verify each): Sail uses user `sail` and `/var/www/html`; DDEV uses service `web` and `/var/www/html`; Lando uses `appserver` and `/app`. For Herd projects, use the site's isolated PHP (`herd which-php`; verify the command).
- **Why.** Fewer setup steps. Tinkerwell relies on generic Docker and Herd's own integration.
- **Fit.** `FilePanels.openProject` → `AppModel.openProject(at:)`, then `DockerProfile.newDraft()` prefilled. Herd goes into `PHPDiscovery`.
- **Risks.** A preset only prefills a draft; the user saves it.

**P3**

| ID | Idea | What and why | Fit | Size | Risks |
| --- | --- | --- | --- | --- | --- |
| N23 | Kubernetes | Profile: kubeconfig, context, namespace, label selector, and container (a selector survives pod churn, like Compose identity). Runs use `kubectl exec -i … php -d … -` with stdin streaming. Tinkerwell has searchable pods and remote kubeconfig. | A new adapter that copies the `DockerExecAdapter` pattern; a resolver that requires a choice when several pods match, unless "replicas are interchangeable" is ticked. | M | Same explicit-target rules; Stop through `kubectl exec` with the signal helper. |
| N24 | Forge and Ploi import | Import servers and sites as SSH profiles (Forge API v2 token with `server:view` in the Keychain), detect `current` symlinks, and set the site user. | Needs §3. A sheet that creates `SSHProfile` drafts. | M | Store the token in the Keychain only; import never connects. |

### F. Drivers and extensibility

#### N25 · Global drivers, Testbench, and a driver gallery — P2 · S

- **What.**
  - `~/Library/Application Support/Runlet/Drivers/*Driver.php` drivers apply to every target. They are **sent in the run request**, so they also work in Docker and SSH targets without mounts.
  - A built-in `TestbenchDriver` for Laravel package work (Tinkerwell 4.21).
  - A docs gallery of ported drivers (Craft, Drupal, Magento 2, Shopware, TYPO3) added on demand.
- **Why.** Tinkerwell has global drivers that win over project ones, and a broad framework matrix.
- **Fit.** `RunnerBundle.script` adds `drivers: [{name, source}]`, which the runner `eval`s before project drivers. This shares the injection code with §3.11. Testbench goes in `Drivers.php`.
- **Risks.** `__DIR__` inside eval'd drivers: rewrite it or document that only single-file drivers are supported. Decide precedence (Tinkerwell lets global drivers win; Runlet should let project drivers win and say so).

#### N26 · App info panels — P2 · M

- **What.** Clicking the framework chip (status bar or tab card) opens an "App Info" popover. Laravel shows `artisan about --json` (environment, debug, cache, and drivers). A driver can add `panels(): array` of sections with key/value rows. It loads only on click, because it boots the app.
- **Why.** Tinkerwell has panels (`appPanels()`, `.tinkerwell/panels`), and it helps you check the environment before you run.
- **Fit.** Runner `mode: "panels"`, like `mode: "commands"` (`ProjectCommands.swift`). A popover view.
- **Risks.** Boots project code, so only on click, and production profiles confirm (§3.13).

### G. Logs and data

#### N27 · Log viewer — P2 · M

- **What.** View ▸ Logs (Tinkerwell uses ⌘L). Pick a file: Laravel `storage/logs/*.log` (nested folders included), driver `logPaths()`, or for Docker the container's stdout (`docker logs --follow --tail 500`). Parse Monolog entries, including multi-line traces and the JSON formatter. Filter by level, search, follow, and turn stack frames into editor links. Add "Logs written by this run" from N03.
- **Why.** Tinkerwell has a log viewer with polling. Reading logs next to the scratchpad saves a terminal round-trip.
- **Fit.**
  - Local projects, and Docker or SSH with a local folder where the logs are inside a bind mount, read **host files** directly. No exec is needed; follow with a `DispatchSource` file watcher that handles rotation.
  - Docker without a mount uses `docker logs` or `docker exec tail -F`, and SSH uses `ssh tail -F`. Both run only after the user clicks Follow.
  - A new `LogViewer.swift` panel; `EditorPathMapping` for links.
- **Risks.** Large files: tail-read and bound the memory. Remote follow is an explicit action and stops when the panel closes.

#### N28 · Database schema browser — P2 · M

- **What.** A Database pane: connections, tables with approximate row counts, and columns and indexes. Clicking a table opens a new tab with `DB::table('x')->limit(50)->get()`, which doesn't run.
- **Why.** Faster than recalling column names. Beyond Tinkerwell. Completion can later use the column names.
- **Fit.** Runner `mode: "schema"` through `Schema::getTables()` and `getColumns()` (Laravel 11+; older versions need `information_schema` queries). Cache per target like the Commands pane, loading only when the pane is shown.
- **Risks.** It boots the app, so the same rules apply as for the Commands pane, and production confirms.

**P3**

| ID | Idea | What and why | Fit | Size | Risks |
| --- | --- | --- | --- | --- | --- |
| N29 | SQL tabs | A tab whose language is SQL, run through the target's own connection (`DB::connection()->select()`), with table output. A scratch SQL client without credentials. | A new tab "language" flag, an SQL highlighter, and the runner wrapping the SQL in a PHP snippet. | M–L | Writes are possible, so production confirms. |

### H. Editor and language

#### N30 · PHPantom navigation: definition, references, inlay hints, code actions — P2 · S–M

- **What.**
  - ⌘-click or F12 goes to the definition. A project file opens in the external editor at its line; vendor code opens in a read-only peek.
  - Find References lists results in a popover.
  - Inlay hints show parameter names and inferred types.
  - Code actions offer "Import class" and similar fixes.
  - Folding.
- **Why.** PHPantom 0.10 already advertises all of these (`compatibility.md`); Runlet uses only completion, hover, signature help, and diagnostics.
- **Fit.** New requests in `LSPConnection` and `LanguageServer.swift`, mapped through `ScratchDocumentMapping` and `EditorPathMapping`. Presentation in `EditorController` and `EditorPopups.swift`.
- **Risks.** Positions on hidden prefix lines; reuse the mapping tests.

**P3**

| ID | Idea | What and why | Fit | Size | Risks |
| --- | --- | --- | --- | --- | --- |
| N31 | Format snippet | Format on demand and optionally before each run (Tinkerwell has prettify, format-before-run, and quote style). Needs a formatter that works without host PHP. Candidate: bundle **Mago** (a Rust PHP toolchain with a formatter; verify the licence and stability). PHPantom already knows a `[mago]` tool command; check whether formatting can go through it. Alternative: the project's Pint, run on the target explicitly. | A bundled binary like PHPantom; a `textDocument/formatting` request. | M | Never format implicitly unless the user opts in. |
| N32 | Editor polish | Built-in syntax themes (a few light and dark, not the Monaco format), indentation guides, multi-cursor commands (add next occurrence), ⌃Tab and ⌥⌘←/→ tab switching, middle-click to close. | `PHPHighlighter` and `EditorTheme`, `CodeTextView`, `Commands.swift`. | M | Multi-cursor on NSTextView is real work; check its multiple-selection support first. |

### I. History, snippets, and sharing

#### N33 · Keyboard-first History and Snippets, history in ⌘P — P1 · S

- **What.** ⌘Y and ⇧⌘L focus the search field. ↑ and ↓ move the selection, Return loads into the current tab, ⌘Return opens a new tab, and ⇧Return inserts at the cursor. History appears in ⌘P behind a `!` prefix.
- **Why.** Tinkerwell's history and snippets are keyboard-driven. This was B06 in the earlier review and is still open.
- **Fit.** `LibraryInspector.swift` (`onKeyPress`), and the `Palette.swift` and `PaletteQuery` prefixes.
- **Risks.** None. It loads code only.
- **Status.** Done (see CHANGELOG, 2026-10-02). In the list itself, ⌫ deletes and selects the next row, and typing continues the search.

#### N34 · Tinkerwell migration — P2 · S

- **What.** Read `.tinkerwell/snippets/*.php` read-only when there is no `.runlet/snippets`. Import personal snippets from Tinkerwell's `snippets.json` (Application Support/Tinkerwell, per the paths page; the format is undocumented, so treat this as a guess). Point to the driver porting table in `drivers.md`.
- **Why.** Makes switching easier for the user and their team.
- **Fit.** `ProjectSnippets.swift` fallback folder; an import sheet.
- **Risks.** Parse defensively and never modify Tinkerwell's files.

**P3**

| ID | Idea | What and why | Fit | Size | Risks |
| --- | --- | --- | --- | --- | --- |
| N35 | Share and send code | A `runlet://new?code=…&target=…` URL opens a new tab and never runs. Copy as a link for chat. `pbpaste \| runlet -` (with N39's CLI) sends code from an IDE's "external tool". | `CFBundleURLTypes`, `AppDelegate.open`. | S | The code sits in the URL; it is user-initiated. Never auto-select production targets from a link. |
| N36 | Promote a snippet | "Save as Artisan Command…" or "Save as Pest Test…" turns the snippet into a class or test file in the local project, for review. Turns scratch code into real code. | A template plus a save panel. | M | Writes only through a save panel. |

### J. Testing and performance

| ID | Idea | What and why | Fit | Size | Pri | Risks |
| --- | --- | --- | --- | --- | --- | --- |
| N37 | Tests group in the Commands pane | Detect Pest or PHPUnit (`vendor/bin/pest`, `vendor/bin/phpunit`, `artisan test`). Run all, a file, or `--filter` (`needsInput`) in a terminal tab. | The Composer-scripts reader in `Runner.php`, `ProjectCommand` groups. | S | P3 | None. |
| N38 | Benchmark and profile | `Runlet\bench(fn, n)` shows min, mean, and p95 plus memory; a nice card for Laravel's `Benchmark::measure`. "Profile Run" uses Excimer or SPX when loaded (shown in the probe) and renders a flame graph. | A runner helper plus a `record` category; a flame-graph view. | M–L | P3 | Profilers are optional extensions; disable the command when missing. |

### K. Native macOS and distribution

#### N39 · `runlet` CLI, file watching, Dock recents, pinned window — P1 · S each

- **What.**
  - Settings ▸ Install Command-Line Tool. `runlet [dir|file|workspace]` opens a project tab for a directory; a file or workspace opens as today. This is B11.
  - File-backed tabs reload silently when unchanged and offer "Reload / Keep Mine" when edited. ⌘S never overwrites a newer file. This is B13.
  - The Dock menu lists recent projects.
  - Window ▸ Float on Top.
- **Why.** Tinkerwell parity: the CLI helper, Dock recents (3.5), and Watch File.
- **Fit.** `AppDelegate.open(_:)` handles directories. `NSFilePresenter` or `DispatchSource` for file tabs. `applicationDockMenu`. `NSWindow.level`.
- **Risks.** The CLI install needs admin rights for `/usr/local/bin`; offer `~/.local/bin` with instructions.
- **Status.** Done (see CHANGELOG and [cli.md](cli.md)). The tool is a small Swift binary in `Contents/Helpers`, not a script: it reaches the running app with a distributed notification and waits for the answer, so it can report errors and supports `--target` and `--new-window`. Opened files are recent documents; the Dock menu lists recent projects (local and Docker). Float on Top lasts for the launch.

#### N40 · Developer ID signing, notarization, auto-update, diagnostics — P1 · M

- **What.** Sign and notarize releases (`scripts/package.sh` already supports `RUNLET_SIGN_IDENTITY` and `RUNLET_NOTARY_PROFILE`). Add Sparkle 2 updates (EdDSA-signed appcast). Help ▸ Export Diagnostics writes versions, PHP discovery, Docker status, a PHPantom log tail, and a redacted settings summary.
- **Why.** 0.0.1 is ad-hoc signed, and Gatekeeper is expected to block downloaded copies (`architecture.md`). Tinkerwell ships an updater (its paths page lists the updater cache).
- **Fit.** `project.yml` (a Sparkle package, an exact version), and `AppPaths.logs`, which is unused today.
- **Risks.** Key management for the appcast. Diagnostics must never include code, history, or hostnames without asking.

#### N41 · Quick Run panel — P2 · M

- **What.** A global hotkey (configurable, off by default) opens a floating Spotlight-style panel with a one-line or small editor on the default target. ⌘R runs it and shows the result inline, and "Open in Tab" moves the code to a tab.
- **Why.** Quick conversions and helpers (`Str::slug`, dates, `bcrypt`) without switching windows. Beyond Tinkerwell.
- **Fit.** An `NSPanel` (non-activating, like `PopupPanel`), reusing `CodeTextView` and the run pipeline. The sandbox is the default target.
- **Risks.** Never allow a production target in the panel.

#### N42 · Notifications for long runs — P2 · S

- **What.** When a run longer than 10 s finishes while Runlet is in the background, post a notification (status and duration). Clicking it focuses the tab.
- **Why.** Long data fixes and imports.
- **Fit.** `UNUserNotificationCenter` in `AppModel.run`'s finish handling.
- **Risks.** Never include output or code in the notification.

**P3**

| ID | Idea | What and why | Fit | Size | Risks |
| --- | --- | --- | --- | --- | --- |
| N43 | Shortcuts, Services, Spotlight | App Intents: "Open snippet X in Runlet" and "Run sandbox snippet" (sandbox only). A Services menu item, "Open Selection in Runlet". CoreSpotlight indexing of snippet labels. | App Intents, `NSServices`, CoreSpotlight. | M | Automation can't run non-sandbox targets. |

### L. AI-assisted features (optional; AI was excluded from the MVP)

Present these only if the user wants AI. None of them may run code without the same explicit Run or approval.

| ID | Idea | What and why | Fit | Size | Pri | Risks |
| --- | --- | --- | --- | --- | --- | --- |
| N44 | MCP server | `Runlet --mcp` (stdio) talks to the running app over a local socket. Tools: `list_targets`, `list_snippets`, `get_snippet`, `add_snippet`, `run_php(target, code)`, `get_last_output`. Tinkerwell has five similar tools. Every `run_php` call shows an in-app approval sheet (code plus target), with an optional "allow for this session" on the sandbox only. | The same `ExecutionEngine`; an approval sheet like §3.13's. | M | P2 (optional) | Never opens SSH connections or runs on production without approval; Tinkerwell's MCP auto-connects SSH, Runlet should not. |
| N45 | Explain or fix this error | A button on error cards sends the error, the snippet, and optionally the frame's source to a model, and shows the explanation or a proposed diff, applied only on click. Native option: Apple's on-device Foundation Models on macOS 26 (private, free; PHP quality unverified), or a bring-your-own API key. | An error-card action, a provider abstraction, and the Keychain for keys. | M | P3 (optional) | Privacy: show exactly what is sent; never send automatically. |
| N46 | Chat sidebar | A chat with per-message context toggles (editor, output, `@` local files) and "Insert into tab". Tinkerwell parity, including `appFiles()`. | A sidebar next to the History & Snippets panel. | L | P3 (optional) | As above; never run generated code automatically. |
| N47 | AI inline completion | Ghost-text suggestions on demand (on typing or idle as an option), with caching. | Editor ghost text, shared with N11's drawing. | L | P3 (optional) | Cost and latency; keep separate from PHPantom. |

## 5. Out of scope / not worth it

| Tinkerwell feature | Why skip |
| --- | --- |
| Laravel Vapor | Serverless: no return values (`dump()` only), Vapor CLI login, slow round trips. The user parked it. Revisit only for a concrete need. |
| Laravel Cloud | An API-token execution model (environment commands), no logs. The user parked it. |
| Windows, Linux, WSL2 | Runlet is native macOS by design. |
| Homestead as a separate guide | It's just an SSH host (§3). |
| PhpStorm plugin | A separate product with its own licensing. The `runlet` CLI, URL scheme, and external-editor links cover the useful part (sending code to Runlet, jumping back to the IDE). |
| Graph view | The expandable tree and table cover the need. A node graph adds UI without new information. |
| Monaco JSON theme files | Tinkerwell's format exists because of its Monaco/Electron editor. A few built-in themes (N32) are enough. |
| Vim keymap | L-sized for NSTextView. Only if the user asks. |
| Collision toggle and `usesCollision()` | Runlet's error cards already structure errors. N07 adds the useful part (source excerpts). |
| ⌘S to run | Tinkerwell itself removed it (4.9). |
| Language-server port setting, "welcome tab" | Electron and Phpactor specifics with no Runlet equivalent. |
| Tinkerwell Wrapped, freemium, licence activation, onboarding tour | Not product value for a personal tool. Licensing is a separate business decision. |
| Auto-evaluate as the default | Conflicts with "nothing runs without an explicit Run". Only N17's sandbox-only opt-in. |
| Driver `contextMenu()` and dynamic snippets | Deprecated by Tinkerwell (3.31). N16 replaces them. |
| Custom `php.ini` per Herd version | Herd already applies its own `php.ini` to its binaries; Runlet runs those binaries. |

## 6. Sources

Tinkerwell v5 docs (all read; none failed to load, though several pages are short):

- Getting started: [about](https://tinkerwell.app/docs/5/getting-started/about), [installation](https://tinkerwell.app/docs/5/getting-started/installation), [settings](https://tinkerwell.app/docs/5/getting-started/settings), [PhpStorm plugin](https://tinkerwell.app/docs/5/getting-started/phpstorm-plugin)
- Setup guides: [Laravel sandbox](https://tinkerwell.app/docs/5/setup-guides/using-the-laravel-sandbox), [SSH](https://tinkerwell.app/docs/5/setup-guides/ssh), [Sail](https://tinkerwell.app/docs/5/setup-guides/sail), [Homestead](https://tinkerwell.app/docs/5/setup-guides/laravel-homestead), [Docker](https://tinkerwell.app/docs/5/setup-guides/docker), [Kubernetes](https://tinkerwell.app/docs/5/setup-guides/kubernetes), [Vapor](https://tinkerwell.app/docs/5/setup-guides/vapor), [Laravel Cloud](https://tinkerwell.app/docs/5/setup-guides/laravel-cloud), [WSL](https://tinkerwell.app/docs/5/setup-guides/wsl), [autocompletion](https://tinkerwell.app/docs/5/setup-guides/autocompletion)
- Basic usage: [evaluating code](https://tinkerwell.app/docs/5/basic-usage/evaluating-code), [Detail Dive](https://tinkerwell.app/docs/5/basic-usage/detail-dive), [tabs](https://tinkerwell.app/docs/5/basic-usage/tabs), [command palette](https://tinkerwell.app/docs/5/basic-usage/command-palette), [history](https://tinkerwell.app/docs/5/basic-usage/history), [snippets](https://tinkerwell.app/docs/5/basic-usage/snippets)
- Advanced usage: [custom themes](https://tinkerwell.app/docs/5/advanced-usage/custom-themes), [shortcuts](https://tinkerwell.app/docs/5/advanced-usage/shortcuts), [magic comments](https://tinkerwell.app/docs/5/advanced-usage/magic-comments), [Collision](https://tinkerwell.app/docs/5/advanced-usage/collision), [project-specific PHP](https://tinkerwell.app/docs/5/advanced-usage/project-specific-php), [log viewer](https://tinkerwell.app/docs/5/advanced-usage/log-viewer), [CLI helper](https://tinkerwell.app/docs/5/advanced-usage/cli-helper), [AI assistant](https://tinkerwell.app/docs/5/advanced-usage/ai-assistant), [Xdebug](https://tinkerwell.app/docs/5/advanced-usage/debugging-with-xdebug), [MCP server](https://tinkerwell.app/docs/5/advanced-usage/mcp-server)
- Extending and troubleshooting: [custom drivers](https://tinkerwell.app/docs/5/extending-tinkerwell/custom-drivers), [panels](https://tinkerwell.app/docs/5/extending-tinkerwell/panels), [blank screen](https://tinkerwell.app/docs/5/troubleshooting/blank-screen), [troubleshooting](https://tinkerwell.app/docs/5/troubleshooting/troubleshooting), [paths](https://tinkerwell.app/docs/5/troubleshooting/paths)

Other Tinkerwell pages:

- [Changelog](https://tinkerwell.app/changelog) (5.x, 4.x, 3.x), [homepage](https://tinkerwell.app/), [What's new in Tinkerwell 5](https://tinkerwell.app/whats-new-in-tinkerwell-5), [Tinkerwell for Laravel](https://tinkerwell.app/tinkerwell-for-laravel)
- Feature pages: [Detail Dive](https://tinkerwell.app/features/detail-dive), [magic comments](https://tinkerwell.app/features/magic-comments), [log viewer](https://tinkerwell.app/features/logviewer), [table mode](https://tinkerwell.app/features/table-mode), [Herd integration](https://tinkerwell.app/features/laravel-herd-integration), [AI](https://tinkerwell.app/features/ai), [REPL](https://tinkerwell.app/features/repl), [snippets](https://tinkerwell.app/features/snippets), [themes](https://tinkerwell.app/features/themes), [command palette](https://tinkerwell.app/features/command-palette)
- Older docs and blog: [v4 settings](https://tinkerwell.app/docs/4/getting-started/settings), [v4 SSH](https://tinkerwell.app/docs/4/setup-guides/ssh), [v2 SSH](https://tinkerwell.app/docs/2/basic-usage/ssh), [v3 SSH (index text only)](https://tinkerwell.app/docs/3/basic-usage/ssh), [1Password SSH agent blog post](https://tinkerwell.app/blog/how-to-set-up-the-1password-ssh-agent-for-secure-ssh-connections)
- Public driver repository: [beyondcode/tinkerwell](https://github.com/beyondcode/tinkerwell) (`src/Drivers/TinkerwellDriver.php`, `LaravelTinkerwellDriver.php`, `src/Panels/LaravelPanel.php`)
- Search used for the Forge API v2 scope and for Ploi (no Tinkerwell–Ploi integration found): [Tinkerwell changelog](https://tinkerwell.app/changelog), [Ploi docs](https://ploi.io/documentation/server)
