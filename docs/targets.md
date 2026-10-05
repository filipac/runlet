# Targets

Every tab runs its code on a target: the place where PHP starts and your application lives. Switch the tab's target, and the same snippet runs in the bundled Laravel sandbox, in a project on your Mac, in a Docker container, or on a server over SSH. The output, dumps, errors, and Stop work the same way everywhere.

<!-- screenshot: the Runlet window with vertical tabs on several targets (the Laravel Sandbox, a local project, a Docker container, and two SSH servers, one marked production), and a Laravel snippet with its output -->

## Kinds of Targets

| Target | Where the code runs | Use it for |
| --- | --- | --- |
| [Laravel Sandbox](laravel-sandbox.md) | A fresh Laravel app on SQLite, bundled with Runlet, with PHP on your Mac or in Docker. | Trying things without a project. |
| [Local project](local-projects.md) | A folder on your Mac, with PHP 7.4 or later: Herd, Homebrew, the `php` on your `PATH`, or Runlet's own PHP. | Projects whose PHP runs on your Mac. |
| [Docker](docker.md) | A running container or Compose service, with the container's own PHP. | Projects that run in Docker, Sail, or OrbStack. |
| [SSH](ssh.md) | A server's own PHP, in your application's folder, or a Docker container on that server. | Staging and production servers. |

**No PHP on your Mac?** Runlet can download its own PHP 8.5.8 (about 26 MB) with the usual Laravel, Symfony, and WordPress extensions, Excimer for profiling, and `mongodb`. Installed PHP always comes first. See [Choosing PHP](local-projects.md#choosing-php).

## Switching a Tab's Target

The target menu in the toolbar shows the tab's target. Click it to pick another one: the sandbox, then your local projects, Docker applications, and SSH hosts, most recently used first.

You can also press <kbd>⌘</kbd><kbd>P</kbd> (Open Anything) and type a target's name. Type `/` to list only projects, or `@` for Docker and SSH targets. <kbd>Return</kbd> switches the current tab, and <kbd>⌘</kbd><kbd>Return</kbd> opens the target in a new tab.

Switching a target never runs code, and never connects to an SSH server. New tabs start on the target in **Settings ▸ General ▸ New Tabs ▸ Default target**: the sandbox, unless you choose another one.

## Adding Targets

| Target | How |
| --- | --- |
| Local project | **File ▸ Open Project…** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>O</kbd>), or `runlet .` in a terminal |
| Docker | **Library ▸ New Docker Profile…** |
| SSH | **Library ▸ New SSH Profile…**, or **Library ▸ Import SSH Hosts from ~/.ssh/config…** |

The target menu has these commands too, and the command palette (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>P</kbd>) finds them by name.

**Settings ▸ Targets** lists every local project, Docker profile, and SSH host, with **Edit…** and a delete button. **Library ▸ Manage Profiles…** opens the Profiles window, where you edit Docker and SSH profiles side by side.

Deleting a target removes only Runlet's entry: the folder, the container, and the server are untouched. Tabs that used it switch to the Laravel Sandbox.

## Choosing a Target

- **To try something** in Laravel, without a project, use the sandbox. It has a `users` table and a `User` factory ready.
- **When PHP runs on your Mac** (Herd, Valet, Homebrew), open the project as a local project.
- **When your app runs in Docker** (Sail, Compose, OrbStack), use a Docker profile. Snippets then get the container's PHP, extensions, environment variables, and network, so a database host such as `mysql` resolves as it does for the app.
- **When the app lives on a server,** use an SSH profile. Give it a local folder with the same checkout, so completion and file links work.

The same project can be several targets: a local project for development, and SSH profiles for staging and production.

## What Every Target Shares

- **A fresh PHP process per run.** The driver boots your application, the snippet runs, and the process ends. Variables don't carry over between runs; use **Open REPL** when you want that.
- **The same output.** Dumps, the returned value, errors, the run inspector, magic comments, and Run History work on every target, and output streams in while the code runs.
- **Nothing written into your project.** Runlet streams its runner to PHP on standard input. It writes no files into your project, container, or server (except the optional [compiled PHP cache](ssh.md#keep-compiled-php-on-the-server) on SSH hosts), and it never runs Composer.
- **Stop** ends the run where it runs: on your Mac, in the container, or on the server.

## Environments and Production

Every target except the sandbox has an environment: **development**, **staging**, or **production**, and an optional colour. A target marked as production shows a red badge, and every run on it asks first:

- <kbd>⌘</kbd><kbd>Return</kbd> runs the code, while <kbd>Return</kbd> and <kbd>Esc</kbd> cancel, so a reflexive Return never runs code on production.
- Project commands, shells, and REPLs on production ask every time, and the Commands panel's Tests group is disabled there.
- When a run shows that the application itself says it's in production, and the target isn't marked, the tab offers **Mark as Production**.

[Environments & Production](environments.md) has the details.

## For developers

- The old readme's "Run it where your app lives" section (#287) is split between this page and [Environments & Production](environments.md); this page was written under [#289](https://github.com/filipac/runlet/issues/289).
- Targets are `TargetRef` (`.sandbox`, `.local`, `.docker`, `.ssh`) in RunletCore; the saved ones are in `TargetLibrary` (`State/targets.json`). The target menu is `TargetMenu` (`MainWindow.swift`), Open Anything's target items are in `Palette.swift`, and Settings ▸ Targets is `TargetSettingsView`.
- The runner's transport (standard input, event framing) is described in [Architecture ▸ Runner and transport](architecture.md#runner-and-transport).
