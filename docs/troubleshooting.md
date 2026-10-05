# Troubleshooting

When a run doesn't do what you expect, start with the Run Log: it shows exactly how Runlet started PHP and what happened. The sections below cover the usual problems, in the order you'd meet them.

## See How a Run Started: the Run Log

Turn on **Show Run Log** in the output pane's share menu, or in the command palette (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>P</kbd>). A log appears under the output, for the current run:

- the exact command that started PHP, as one shell line (the local `php`, `docker exec …`, or `ssh …`), and the working directory;
- the driver Runlet chose to boot your application, and why, with the boot time;
- what PHP wrote to its error stream, and how the process ended: status, exit code, and time.

**Copy** copies the whole log, for an issue or to run the command yourself in Terminal. The Run Log never shows environment values.

## Runlet Doesn't Open

The first time, macOS blocks Runlet because Apple hasn't notarized it yet. Allow it once in **System Settings ▸ Privacy & Security** with **Open Anyway**. See [Opening Runlet the First Time](installation.md#opening-runlet-the-first-time).

If Runlet quits unexpectedly, see [Reading a Crash Log](crash-logs.md).

## PHP Isn't Found, or It's the Wrong Version

- **No PHP on your Mac:** click **Download PHP 8.5.8** in the banner above the editor, or use **Settings ▸ PHP**. See [Installation](installation.md#your-first-run).
- **The wrong PHP:** **Settings ▸ PHP** lists the PHP installations Runlet found (Herd, Homebrew, and your `PATH`) and sets the default. A project can use another PHP in its options.
- **The Laravel sandbox** needs PHP 8.3 or later on your Mac, Runlet's own PHP, or Docker.
- **On an SSH server,** set the PHP executable in the profile; **Test Connection** lists the PHP binaries it finds. See [SSH Targets](ssh.md#troubleshooting).

[Supported Versions](supported-versions.md) lists the PHP versions and extensions Runlet needs.

## The Application Doesn't Boot

The error card says where booting failed. When the application calls `exit()` while it boots, the error names the project file loaded last: usually the plugin, configuration file, or bootstrap script that exited.

- **WordPress** often exits with a redirect. The error gives the redirect WordPress tried (its URL and status, and the file and line that sent it), with advice for the usual causes: a redirect to `install.php` means WordPress found no installation in the database `wp-config.php` points to, as the command line sees it.
- **A project Runlet doesn't recognize** boots as a plain Composer or PHP project. Write a [project driver](drivers.md) to boot it.
- The Run Log shows which driver booted the project, and why.

## A Run Shows No Result

- **The last statement isn't an expression.** `echo`, `foreach`, and other statements give no result. Put the value you want to see last, or `return` it.
- **`\Runlet\notice()` and its siblings return nothing,** so as the last line they make the result `null`.
- **The target's PHP lacks `tokenizer`.** A notice says so: snippets still run, without an implicit result. `return` the value instead.

## Queries, Mail, or Logs Are Missing

- **The run inspector is off.** Turn on **Settings ▸ General ▸ Run Inspector ▸ Record queries, mail, and logs**. The mail chip in the output's header says **Mail: inspector off** when it is.
- **The framework isn't covered.** What's recorded without setup depends on the framework; see the table in [Installation](installation.md#supported-environments). The **Log** section lists log messages on Laravel, Lumen, and Laravel Zero; the [Log Viewer](logs.md) reads every framework's log files.
- **It happened while the application booted.** Runlet starts recording right before your snippet runs.
- **A section reached its limit.** Its end says how many records it left out. See [Limits](run-inspector.md#limits).

## Mail Was Delivered Although Interception Is On

- **The mail was queued.** Mail pushed to an asynchronous queue is sent later by a queue worker, outside the run. Runlet lists it as **QUEUED** and can't stop it.
- **The driver can't confirm interception.** The Mail section and the mail chip say so, with the reason: for example, Symfony Mailer before 6.3, WordPress before 5.7, or a WordPress plugin that replaces `wp_mail()`.
- **It wasn't sent through the framework.** A raw SMTP client or a mail service's HTTP SDK is neither recorded nor intercepted.

See [Intercepting Mail](run-inspector.md#intercepting-mail).

## Profile Run Is Disabled

The target's PHP doesn't load the Excimer extension; the menu item's tooltip and the command palette say which PHP. Install Excimer, or use Runlet's own PHP, which includes it. See [Installing Excimer](benchmarks.md#installing-excimer).

A Profile Run that shows "No samples" finished within one millisecond. Repeat the work in a loop.

## Magic Comments Show Nothing

- **They're turned off** in **Settings ▸ General ▸ Magic Comments**.
- **The line wasn't reached,** or the run failed before it.
- **Runlet can't show a value there** without changing what the code does, such as an assignment's target or a variable inside `isset()`. The line shows a short reason (hover for the full one), and a notice lists every such place.
- **You edited the line** after the run: edited lines lose their values until the next run.

## Output Is Long or Slow

- The **Structured** view shows the last 1,000 cards and the last 5,000 lines of printed output. **Show All** shows every card; **Plain** and **Raw**, **Copy Output**, and **Save Output As…** always have everything.
- A run that prints a lot updates the pane a few times a second, so the window stays responsive. To see the output once at the end instead, choose **At once** in **Settings ▸ General ▸ Output**.

## Stop Doesn't Stop Everything

On your Mac, Stop ends the run and the processes it started. In a running container, processes your snippet started inside the container may keep running, and Stop needs `posix_kill` or a shell in the container. See [Known Limitations](supported-versions.md#known-limitations).

An SQL statement stopped on MySQL, MariaDB, or PostgreSQL is cancelled on the server too. See [Stopping a Statement](sql-tabs.md#stopping-a-statement).

## SSH and Docker

- **SSH:** Runlet explains `ssh` failures in plain words, with OpenSSH's own message below. [SSH Targets](ssh.md#troubleshooting) lists each message and what to do.
- **Several containers match** a Docker profile: choose the container in the sheet that opens. Runlet never silently picks a different one.

## Completion Stops Working

Choose **Library ▸ Restart Language Server**. Completion comes from a language server that indexes your project, and this starts it again.

## The Sandbox Is Broken

**Library ▸ Reset Sandbox…** restores the Laravel sandbox to a fresh copy. Only the sandbox's own data is removed.

## The Logs Window Is Empty

- **A log in a container or on a server** is read only after you click **Follow**.
- **A project driver's log files** are known once Runlet has listed the project's commands. Click **Load the Driver's Log Paths**.
- **Another file:** use **Find Logs**, or **Other Path…**.

See [Log Viewer](logs.md).

## No Notification After a Long Run

Check **Settings ▸ General ▸ Notifications**: the switch, **Notify after**, and the permission macOS reports under it. A run doesn't notify when you stopped it, when it was a sandbox auto-run, or when you were looking at Runlet as it ended. See [Notifications for Long Runs](run-notifications.md).

## `runlet: command not found`

The folder you installed the command into isn't on your shell's `PATH`. **Runlet ▸ Install Command-Line Tool…** says so, and which line to add to `~/.zprofile`. If you moved Runlet.app, install the command again. See [Command-Line Tool](cli.md#installing-the-tool).

## An AI Client Can't Reach Runlet

- **Turn it on** in **Settings ▸ AI Clients**: it's off by default, and the client's message says so.
- **You moved Runlet.app:** update the path in the client's configuration. **Settings ▸ AI Clients** shows the current one.
- **An SSH host that needs a password or a code** is refused: log in with **Connect…** first.

See [AI Clients](mcp.md).

## Settings or Tabs Look Reset

Runlet keeps a copy of each file of its own state from before the last save. When a file can't be read, Runlet moves it aside as `<name>.corrupt-<date>.json` in `~/Library/Application Support/Runlet/State`, and opens the last good copy instead. Nothing is deleted.

## Reporting a Problem

[Open an issue on GitHub](https://github.com/filipac/runlet/issues) with:

- the Runlet version (**Runlet ▸ About Runlet**) and your macOS version;
- what you did, what you expected, and what happened;
- the Run Log, for a run that went wrong, and the crash report, if Runlet crashed.

> [!WARNING]
> Run Logs and crash reports can contain paths, host names, and error text from your projects. Read them before you post them.

## For developers

This page was added in [#291](https://github.com/filipac/runlet/issues/291).

- The Run Log is `RunLogView` in `Runlet/Features/OutputPane.swift`, filled by `TabModel.appendRunLog`; drivers add lines with `$this->log()` and explain exits with `bootstrapExitHint()` ([drivers.md](drivers.md)). Its menu command is `run.toggleRunLog` (in the command palette, not in the Run menu, although the Run Log's close button's tooltip mentions Run ▸ Show Run Log).
- State files and their recovery (`JSONDocumentStore`: `<name>.last-good.json`, `<name>.corrupt-<ISO 8601 timestamp>.json`): [architecture.md](architecture.md#persistence).
- Output pacing and the Structured view's limits: [architecture.md](architecture.md) ("Applying events").
