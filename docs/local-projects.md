# Local Projects

A local project is a folder on your Mac that Runlet runs PHP in. Open a Laravel, Symfony, WordPress, or Composer project, and every snippet runs inside it, with the PHP you choose: Herd, Homebrew, the `php` on your `PATH`, or Runlet's own.

## Opening a Project

Choose **File ▸ Open Project…** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>O</kbd>) and pick the project's folder: the one with `artisan`, `bin/console`, `wp-config.php`, or `composer.json`. The current tab switches to the project. From a terminal, the [`runlet` command](cli.md) does the same:

```sh
cd ~/Code/shop
runlet .
```

Runlet remembers the project. Opening the same folder again reuses it, and the target menu and Open Anything (<kbd>⌘</kbd><kbd>P</kbd>) list it from then on, most recently used first.

Then write a snippet and press <kbd>⌘</kbd><kbd>R</kbd>. Runlet detects the framework and boots it for every run, so the snippet starts with your application ready:

```php
use App\Models\Order;

Order::query()->where('status', 'paid')->sum('total');
```

[Frameworks](frameworks.md) lists what Runlet detects and what each framework's snippets start with.

## Project Options

To change a project's settings, choose **Project Options…** in the target menu, or **Edit…** next to it in **Settings ▸ Targets**.

| Option | What it does |
| --- | --- |
| **Name** | Shown in the target menu, tabs, and history. It starts as the folder's name. |
| **PHP** | The PHP for this project's runs. **Default** uses the default from **Settings ▸ PHP**. See [Choosing PHP](#choosing-php). |
| **PHP version for completion** | The PHP version completion and diagnostics assume. Leave it empty to read it from `composer.json`. |
| **Strict types** | Whether runs declare `strict_types=1`. **Default** follows **Settings ▸ General ▸ Running**. |
| **Mail** | **Intercept** records mail without sending it; **Send** sends it. **Default** follows **Settings ▸ General ▸ Run Inspector**. See [Mail interception](driver-inspector.md#mail-interception). |
| **Environment** and **Colour** | Development, staging, or production, and a colour for the project's tabs and status bar. See [Environments & Production](environments.md). |
| **Databases** | Database connections you save for this project, for [SQL tabs](connections.md#saved-connections). They're saved at once, apart from the options above. |

**Remove Project…** removes the project from Runlet. The folder itself is untouched, and tabs that used the project switch to the Laravel Sandbox.

## Choosing PHP

Runlet looks for PHP when it launches: every `php` on your `PATH`, Herd's PHP versions, and Homebrew's `php` formulas. **Settings ▸ PHP ▸ Discovered Installations** lists what it found, with **Rescan** for PHP you installed since.

A project's runs use, in this order:

1. the PHP in the project's options;
2. the **Default PHP** in **Settings ▸ PHP**;
3. automatically, the first PHP 7.4 or later with the tokenizer extension that Runlet found: your `php` on `PATH` first, stable releases before betas.

To use a PHP Runlet didn't find, click **Choose Executable…** under the PHP picker and pick the binary. Runlet checks that it's a working PHP, and tells you when it's older than 7.4, the oldest version Runlet runs.

### Runlet's Own PHP

If your Mac has no PHP, Runlet offers to download its own: click **Download PHP 8.5.8** in the banner above the editor, or in **Settings ▸ PHP ▸ Runlet's PHP**. It's a self-contained PHP for your Mac's processor (about 26 MB), with the usual extensions for Laravel, Symfony, and WordPress (including `mysqli`, `intl`, and `sodium`), `mongodb`, and Excimer for **Profile Run**.

- Runlet downloads it only when you click, and checks it against its published checksum.
- It lives in Runlet's data folder. **Settings ▸ PHP** shows it, updates it, and removes it.
- Runlet uses it only when no installed PHP fits, unless you pick it as the default or in a project's options.

## What Runs on Your Mac

A local project runs the PHP you chose, in the project's folder, as your user. The runner arrives on PHP's standard input: Runlet writes no files into your project, and it never runs Composer there. If `vendor/` is missing, the run says to run `composer install`.

Because the project is on your Mac, Runlet reads it directly:

- **Completion and diagnostics** index the project (PHPantom), without running its code. Models, relations, and columns complete as you type.
- **Framework detection** for the tab card and status bar reads the project's files, without running anything.
- **The Commands panel** lists the project's commands while it's open (never for a production target), and runs them in a terminal tab in the project's folder.
- **File links** in dumps, errors, and stack traces open at their line in your editor.
- **Project snippets** in `.runlet/snippets/` and **project drivers** in `.runlet/` are read from the folder. See [Project Snippets](project-snippets.md) and [Project Drivers](drivers.md).

**Stop** ends PHP and everything the snippet started, such as a child process from `exec()` or `proc_open()`.

## For developers

- A local project is `LocalProject` in `TargetLibrary` (`State/targets.json`): name, path, `phpExecutable`, `languagePHPVersion`, `strictTypes`, `interceptMail`, `environment`, `color`, and a revision. `AppModel.openProject(at:)` reuses a saved project for the same path; `saveProject` bumps the revision and revokes a production grace (`targetEdited`). The options sheet is `ProjectSettingsSheet` (`Sheets.swift`).
- The PHP order is in `AppModel`'s target snapshot (`project.phpExecutable ?? settings.defaultPHPExecutable ?? bestPHP`); discovery is `PHPDiscovery` (`RunletExecution/Executables.swift`): `PATH` (including Herd's `bin`), `~/Library/Application Support/Herd/bin/phpNN`, and `/opt/homebrew/opt/php*` and `/usr/local/opt/php*`. `PHPDiscovery.preferred` needs PHP 7.4+ with the tokenizer. Runlet's own PHP is `RunletPHPStore`, listed last ([#2](https://github.com/filipac/runlet/issues/2)); its build and extensions are in [compatibility.md](compatibility.md).
- Local runs use `LocalAdapter`: the runner leads its own process group, and Stop sends `SIGTERM` to the group, then `SIGKILL` ([Architecture ▸ Cancellation](architecture.md#cancellation-stop)).
- This page was added under [#289](https://github.com/filipac/runlet/issues/289).
