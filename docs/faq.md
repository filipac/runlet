# FAQ

Short answers to the questions people ask most, with links to the pages that say more.

## Is Runlet Really Free?

Yes. There is no paid version, no trial, and no account. Runlet is open source under the MIT License.

## Is It Ready for Daily Use?

Runlet is an early preview, built quickly with AI assistance. Expect rough edges. If something breaks or feels off, please [open an issue on GitHub](https://github.com/filipac/runlet/issues): it helps a lot.

## Why Does macOS Say It Can't Check Runlet for Malicious Software?

Runlet is ad-hoc signed and not notarized by Apple yet, so macOS blocks it the first time you open it. Allow it once:

1. Open Runlet. macOS says it can't verify the app.
2. Open **System Settings ▸ Privacy & Security**, click **Open Anyway** next to the message about Runlet, and confirm.

Or remove the quarantine flag in Terminal:

```sh
/usr/bin/xattr -dr com.apple.quarantine /Applications/Runlet.app
```

You do this once: updates installed from inside Runlet remove the flag themselves. If you prefer, [build Runlet from source](building.md). See [Opening Runlet the First Time](installation.md#opening-runlet-the-first-time).

## Does Runlet Upload My Code Anywhere?

No. Code runs on the target you pick: your Mac, a Docker container, or a server you connect to with your own `ssh`. Your code reaches PHP on its standard input and is never written to disk. On a server, the only things kept are Runlet's runner and the application's compiled PHP, in a private cache that you can turn off.

Runlet has no telemetry, and stores no SSH keys or SSH passwords. Passwords of saved database connections go only into your Mac's Keychain. See [Safety & Privacy](safety-and-privacy.md).

## Will It Run Code Without Asking?

No. Your snippets run when you press Run. Opening a project, switching tabs, or restoring a session doesn't run them, and opening an SQL, Redis, or MongoDB tab or choosing its connection doesn't connect or run anything.

The Commands pane boots a project to list its commands only while the pane is open, and never on its own for SSH or production targets. Production targets confirm every run and every project command.

## Can an AI Agent Run Code With Runlet?

Only with your approval. Claude Code, Cursor, and other MCP clients can ask Runlet to run PHP, and Runlet shows you the code and the target first. You can let a client run on one target without asking for the rest of its session, but never on a production target. See [AI Clients](mcp.md).

## Do I Need PHP Installed?

No. If your Mac has no PHP, Runlet offers to download its own: a self-contained PHP 8.5.8, about 26 MB, checked against a SHA-256 checksum built into the app, and kept in Runlet's data folder. The sandbox and your local projects run on it, without Herd, Homebrew, or Docker. If you have PHP installed, Runlet uses yours first.

## Which PHP Versions Does It Support?

Your projects can use PHP 7.4 or newer, locally, in Docker, or over SSH. The bundled Laravel sandbox needs PHP 8.3 or newer: without it on your Mac, Runlet offers to download its own PHP 8.5.8, or runs the sandbox in a `php:8.4-cli` container. See [Supported Versions](supported-versions.md).

## Can I Use It With Frameworks Other Than Laravel?

Yes. Symfony, WordPress, Lumen, Laravel Zero, and plain Composer projects work out of the box, and a [project driver](drivers.md) in `.runlet/` can boot anything else.

## Do Variables Carry Over Between Runs?

No. Each run is a fresh PHP process: the application boots, then your snippet runs. When you want state that carries over, use **Open REPL** in the Commands pane, which opens the target's Tinker, PsySH, or `php -a`.

## How Do I Update?

Choose **Runlet ▸ Check for Updates…**, then **Install and Relaunch**. Runlet also checks by itself at launch and once a day, and installs nothing until you choose. It checks the update's signature first, removes the quarantine flag so macOS doesn't ask again, and puts back the version you had if the new one doesn't start. In **Settings ▸ General ▸ Updates**, choose the Stable or Beta channel, or turn the automatic checks off.

Runlet 0.3.0 and older (and 0.4.0 betas 1 to 6) can't update themselves: download the newest release and replace the app once. Your tabs, snippets, history, and targets stay in `~/Library/Application Support/Runlet`. See [Updating Runlet](installation.md#updating-runlet) and the [Release Notes](release-notes.md).

## Something Doesn't Work. Where Do I Start?

[Troubleshooting](troubleshooting.md) covers the usual problems. If Runlet crashed, [Reading a Crash Log](crash-logs.md) shows how to turn the report into something useful for an issue.

## For developers

The landing page's nine questions (`website/index.html`, `#faq`) are all here, with links to the pages that say more; the landing page keeps its own copy, so change both when an answer changes. The questions about AI agents, variables between runs, and where to start come from the docs. This page was added in [#291](https://github.com/filipac/runlet/issues/291).
