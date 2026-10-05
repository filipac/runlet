# Safety & Privacy

Runlet runs real code against real applications, some of them in production. So it runs nothing you didn't ask for, asks before every run on production, and keeps your code, data, and credentials on your Mac and your own servers. It has no account and no telemetry.

## Nothing Runs Until You Ask

Your code runs only when:

- you press **Run** (or **Run Selection**, or **Profile Run**);
- you approve an AI client's request, or allowed its sandbox runs for the session ([AI Clients](mcp.md));
- you turned on [auto-run](sandbox-auto-run.md) in a sandbox tab. It never runs on local, Docker, or SSH targets.

Opening a project, a file, or a workspace, switching tabs, and restoring your session never run code. Opening an SQL, Redis, or MongoDB tab, or choosing its connection, doesn't connect or run anything.

The **Commands** pane boots a project to list its commands only while the pane is open, and never on its own for SSH or production targets.

## Production Asks First

Mark a target's environment as production in its project options or profile, and every run asks before it starts:

- The confirmation shows the target, where the code runs, and the code. <kbd>⌘</kbd><kbd>Return</kbd> runs it; <kbd>Return</kbd> and <kbd>Esc</kbd> cancel, so a reflexive Return never runs code on production.
- **Don't ask again for 10 minutes** covers snippet runs on that target only. Project commands, shells, and REPLs on production ask every time, and AI clients' runs too.
- The **Tests** group in the Commands pane is disabled on production, because test suites often reset the database.
- When a run shows that the application says it's in production (Laravel's `APP_ENV`, Symfony's kernel, WordPress's environment type) and the target isn't marked, the tab offers **Mark as Production**. Runlet never changes the marking by itself.
- A red badge marks production targets in the toolbar, the tabs, and the status bar, and **History** keeps a PROD badge on runs made there.

[SSH Targets](ssh.md#production-hosts) has the details.

## Guard Rails for Data and Mail

- **[Dry Run](dry-run.md)** runs a PHP tab inside database transactions that Runlet always rolls back. It isn't a sandbox: mail (unless intercepted), queues, HTTP calls, and files are real. MySQL and MariaDB schema changes are refused, because they would commit at once, and the transaction holds its locks until the run ends. Production still asks first.
- **[Mail interception](run-inspector.md#intercepting-mail)** records the mail a run sends without delivering it, where the framework allows it.
- **[Read-only connections](connections.md#read-only-connections)** let an SQL tab look at data, production data included, without changing it: the database session is read-only, and Runlet refuses statements that could write before sending them.

## Your Code and Data Stay With You

- **Code runs where you choose:** your Mac, a Docker container, or a server you connect to with your own `ssh`. Runlet uploads nothing anywhere else.
- **Nothing is written into your project or container.** Runlet's runner is streamed to PHP on its standard input, and it never runs Composer in your project.
- **On a server,** your code is never written to disk either. The only things Runlet keeps there are its own runner and the application's compiled PHP, in a private cache that speeds up runs. It's on for new SSH profiles, and one switch in the profile turns it off; Runlet then writes nothing on the server.
- **Previews are locked down.** Mail and HTML previews run no JavaScript, load nothing from the network unless you allow remote images, and don't navigate.
- **Logs stay in the Logs window.** Log lines aren't saved, written to the Run Log, or given to AI clients. The Run Log never shows environment values.
- **Notifications** for long runs carry only the run's status, duration, tab title, and target name: never code, output, or errors.

Your tabs, snippets, history, targets, and settings are in `~/Library/Application Support/Runlet`.

## Credentials

- **Database passwords** of saved connections are kept only in your Mac's Keychain, never in Runlet's files.
- **SSH** uses your system `ssh` and `~/.ssh/config`. Runlet stores no SSH passwords, keys, or passphrases.
- **AI clients** can't see or use saved database connections or their passwords.
- **Import from TablePlus**, behind a feature flag in **Settings ▸ Advanced** (off by default), reads TablePlus's connection list only when you click. It copies database passwords only if you tick the box, with macOS asking for each item, and never copies SSH passwords or key passphrases. See [Import From TablePlus](connections.md#import-from-tableplus).

## No Account, No Telemetry

Runlet has no account, no analytics, and sends no crash reports. It contacts the internet only for:

- **Update checks:** one request for the list of releases on GitHub, at launch and once a day, with nothing about you or your Mac. Turn them off in **Settings ▸ General ▸ Updates**. Updates install only when you choose, and only if they're signed with Runlet's key.
- **Runlet's own PHP,** only when you click to download it. It's checked against a SHA-256 checksum built into the app.
- **Remote images** in a preview, only when you allow them for that preview.

## Code You Trust

Some code runs with the same permissions as your snippets, so treat it as you treat your application's code:

- **[Project drivers](drivers.md)** in a project's `.runlet` folder boot the application for every run, and can add commands.
- **AI clients' code** runs only after you approve it on the sheet that shows all of it. Read it as you would a pull request.

## For developers

This page took in the readme's "Safety and privacy" section in [#291](https://github.com/filipac/runlet/issues/291), with the landing page's answers about uploads and running code without asking.

- Explicit execution and the production guard: N14 in [architecture.md](architecture.md#production-guard-n14); the application's reported environment: [#12](https://github.com/filipac/runlet/issues/12).
- Dry Run: [#13](https://github.com/filipac/runlet/issues/13). Notifications: [#26](https://github.com/filipac/runlet/issues/26). MCP: [#43](https://github.com/filipac/runlet/issues/43).
- Saved connections' passwords in the login keychain (service `dev.runlet.Runlet.database`): [#138](https://github.com/filipac/runlet/issues/138); the data folder's layout is in [architecture.md](architecture.md#persistence).
- The SSH cache (`~/.cache/runlet/opcache` and, since [#48](https://github.com/filipac/runlet/issues/48), `~/.cache/runlet/runner`, mode `0700`): [Keep the runner and compiled PHP on the server](ssh.md#keep-the-runner-and-compiled-php-on-the-server). Profiles saved by Runlet 0.1.0 or earlier keep their setting: off, unless turned on.
- Import from TablePlus: [#188](https://github.com/filipac/runlet/issues/188), behind the `tablePlusImport` feature flag.
- In-app updates: [#233](https://github.com/filipac/runlet/issues/233).
