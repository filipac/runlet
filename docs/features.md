# Everything in Runlet

Every feature of Runlet on one page, grouped by what you're doing, with links to the pages that cover them. New to Runlet? Start with the [Quickstart](quickstart.md).

## Execute

- **Targets:** the Laravel sandbox, local projects (PHP 7.4 or later), Docker containers and Compose services, and [SSH servers](ssh.md), with or without a container on the server.
- **PHP** per project or as the default, from Herd, Homebrew, your `PATH`, or Runlet's own PHP 8.5.8. See [Installation](installation.md#your-first-run).
- **[Run, Run Selection, and Stop](running-code.md):** output as it runs, or all at once when it ends, and an output pane that can stay hidden until a run or hide on <kbd>Esc</kbd>.
- **[Sandbox auto-run](sandbox-auto-run.md):** turn it on for a sandbox tab, and it runs 800 ms after you stop typing. It's off by default, shows an **AUTO** badge, and never works on local, Docker, or SSH targets.
- **[Notifications for long runs](run-notifications.md):** a run that takes 10 seconds or more (you choose) and ends while you're in another app posts a notification with its status, duration, tab, and target, never code or output. Click it to get back to the tab.
- **[Dry Run](dry-run.md):** a PHP tab's runs happen in database transactions that Runlet always rolls back, and then say what was rolled back. Statements that would commit the transaction on MySQL and MariaDB (schema changes) are refused before they run, and Runlet warns about what a transaction can't undo.
- **Production asks first:** a target marked as production shows what will run, and where, before every run. See [Production hosts](ssh.md#production-hosts).

## Inspect

- **Output** as Structured, Plain, or Raw; tables for rows and collections; and [string viewers](string-viewers.md) for JSON, long text, images, and HTML.
- **`dump()` and `dd()`** through your project's VarDumper, or Runlet's own when there is none; exceptions with their snippet line and source; and `\Runlet\notice()`, `warning()`, and `error()` cards that never fail the run. Everything a snippet can use is in the [Snippet API](snippet-api.md).
- **The run inspector:** SQL queries with timings, bindings, N+1 hints, and [Explain](sql-explain.md); mail previews and [mail interception](drivers.md#mail-interception); logs; and sections a [project driver](drivers.md) adds.
- **The [log viewer](logs.md)** (<kbd>⌘</kbd><kbd>L</kbd>): Laravel, Symfony, WordPress, and driver logs, parsed and followed as they're written, with level and search filters, the lines the last run wrote, and stack frames that open in your editor. In containers and over SSH, it follows a log only when you click **Follow**.
- **Export** values as JSON, PHP, or Markdown, tables as CSV, and the whole output to a file.

## Measure

- **[Run timings](run-timings.md):** bootstrap, execute, and total time, peak memory, and query time.
- **Timings in the editor** with the `/*?.*/` [magic comment](magic-comments.md#timings).
- **Benchmarks** with [`Runlet\bench()`](drivers.md#benchmarks), and a card for Laravel's `Benchmark::dd()`.
- **Profile Run** (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>R</kbd>) with a native flame graph, through the Excimer extension. Runlet's own PHP includes it.

## Iterate

- **[Magic comments](magic-comments.md):** `//?`, `/*?*/`, `/*?->…*/`, and `/*?.*/`.
- **Completion that knows your project,** with hover, signature help, and diagnostics, plus [code navigation](navigation.md): Go to Definition (<kbd>F12</kbd>, <kbd>⌘</kbd>-click) with a read-only peek into vendor code, Find References (<kbd>⇧</kbd><kbd>F12</kbd>), code actions such as importing a class (<kbd>⌥</kbd><kbd>Return</kbd>), inlay hints, and folding.
- **[Format Code](format-code.md)** (<kbd>⌥</kbd><kbd>⇧</kbd><kbd>⌘</kbd><kbd>F</kbd>) with the bundled Mago formatter: no PHP needed, PER, PSR-12, or Laravel style, magic comments kept in place, and an optional Format before run.
- **[Move and duplicate lines](navigation.md#moving-and-duplicating-lines)** (<kbd>⌥</kbd><kbd>↑</kbd> / <kbd>⌥</kbd><kbd>↓</kbd>, and with <kbd>⇧</kbd>) in every kind of tab, one undo step per press, with a folded block moving as one line.
- **[History](running-code.md#run-history)** (per project or all), [personal snippets](personal-snippets.md) with descriptions, and [project snippets](project-snippets.md) your team commits in `.runlet/snippets`, with [inputs](snippet-inputs.md) for runbooks.
- **[Promote a snippet](promote-snippets.md):** **Save as Artisan Command…** or **Save as Test…** (Pest or PHPUnit) writes the tab's code into the project as a class or test to review, without running it.
- **Open Anything** (<kbd>⌘</kbd><kbd>P</kbd>) for targets, snippets, recent files, and run history, and the **command palette** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>P</kbd>). Every shortcut can be changed. Type `dark`, `light`, or `auto` in Open Anything to switch the appearance. See [Keyboard Shortcuts](keyboard-shortcuts.md).
- **[Tabs](tabs.md):** horizontal or vertical, pinned tabs, several windows, and workspace files. Tabs opened from files follow changes on disk.
- **The Commands pane:** Artisan or console commands, Composer scripts, your own [host commands](drivers.md#host-commands), **[Open REPL](drivers.md#open-repl)** (the target's Tinker, PsySH, or `php -a`), and **[Tests](drivers.md#tests)** (all, one file, or `--filter`, with `php artisan test`, Pest, or PHPUnit), in a terminal that uses your login shell.
- **Databases:** [SQL tabs](sql-tabs.md) on your application's connection or one you save, with a [Connection Manager](connections.md), and [Redis](redis.md) and [MongoDB](mongodb.md) tabs.

## Automate

- **The [`runlet` command](cli.md):** `runlet .` opens the current folder, `runlet file.php` opens a file, and `-t <target>` picks a target.
- **[AI clients](mcp.md):** `runlet mcp` lets Claude Code, Cursor, and other MCP clients ask to run PHP, and Runlet runs it only when you approve.
- **[Project drivers](drivers.md)** in `.runlet/` for applications Runlet doesn't detect.

## For developers

This page is the readme's "Everything in Runlet" list, moved here in [#288](https://github.com/filipac/runlet/issues/288) when the readme became an overview ([#287](https://github.com/filipac/runlet/issues/287)). When a feature is added, add a line here in its group, linked to its page.
