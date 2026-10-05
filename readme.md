<p align="center">
  <img src="website/assets/app-icon-224.png" width="112" height="112" alt="Runlet icon">
</p>

<h1 align="center">Runlet</h1>

<p align="center">
  <strong>A native macOS PHP scratchpad for running code inside your real projects.</strong><br>
  Run PHP anywhere. Inspect everything. Experiment insanely fast.
</p>

<p align="center">
  <a href="https://github.com/filipac/runlet/releases/latest"><strong>Download for macOS</strong></a>
  &nbsp;·&nbsp; <a href="https://runletapp.dev/docs/"><strong>Documentation</strong></a>
  &nbsp;·&nbsp; <a href="https://runletapp.dev/">Website</a>
  &nbsp;·&nbsp; <a href="https://runletapp.dev/docs/installation">Install notes</a>
</p>

<p align="center">
  macOS 15 or later · Apple silicon and Intel · Free and open source (MIT) · Early preview
</p>

Open a Laravel, Symfony, or WordPress project, write a few lines of PHP, and press ⌘R. The snippet runs inside your application, with its models, services, configuration, and database connection ready, on your Mac, in a Docker container, or on a server over SSH. Runlet shows the result next to your code, along with the SQL it ran, the mail it sent, and the logs it wrote.

**Stop creating temporary routes, commands and `dd()` calls just to answer a question about your application.**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="website/assets/shots/magic-comments-dark-2400.webp">
  <img src="website/assets/shots/magic-comments-light-2400.webp" alt="Runlet running a snippet in the Laravel sandbox. Magic comments show values at the end of their lines: 190 ms for creating five users, the first User model, its email, a count of 5, and ×5 with the latest slug inside a loop. The output pane shows the result collection, 7 queries, and the run's timings.">
</picture>

Runlet isn't an IDE. Keep writing your app in PhpStorm, VS Code, or Zed; Runlet sits next to your editor as the place where you try things out, and file paths in its output open at their line in your editor.

> **Early preview.** Runlet was built quickly with AI assistance. Expect rough edges, and please [report issues](https://github.com/filipac/runlet/issues).

## Install

Download the `.dmg` from [Releases](https://github.com/filipac/runlet/releases/latest) and drag Runlet to Applications. It's an early release and not notarized yet, so macOS asks before the first launch: open **System Settings ▸ Privacy & Security** and click **Open Anyway**. After that, Runlet updates itself. Requirements, the first launch, updates, and the `runlet` command: [Installation](https://runletapp.dev/docs/installation).

## Documentation

The documentation is at **[runletapp.dev/docs](https://runletapp.dev/docs/)**, built from the Markdown in [`docs/`](docs/):

- **Getting Started:** [Introduction](https://runletapp.dev/docs/) (what Runlet is, and where it fits next to Tinker and `dd()`), [Installation](https://runletapp.dev/docs/installation).
- **The Basics:** [tabs](https://runletapp.dev/docs/tabs), [personal](https://runletapp.dev/docs/personal-snippets) and [project snippets](https://runletapp.dev/docs/project-snippets), [snippet inputs](https://runletapp.dev/docs/snippet-inputs), [promoting a snippet](https://runletapp.dev/docs/promote-snippets), [settings](https://runletapp.dev/docs/settings).
- **Writing Code:** the [snippet API](https://runletapp.dev/docs/snippet-api) (output, magic comments, `Runlet\bench()`), [code navigation](https://runletapp.dev/docs/navigation), [Format Code](https://runletapp.dev/docs/format-code), [string viewers](https://runletapp.dev/docs/string-viewers).
- **Targets:** [SSH](https://runletapp.dev/docs/ssh) (and production hosts), [sandbox auto-run](https://runletapp.dev/docs/sandbox-auto-run), [Dry Run](https://runletapp.dev/docs/dry-run).
- **Frameworks & Drivers:** [framework drivers](https://runletapp.dev/docs/drivers): detection, project drivers, the run inspector, mail interception, and benchmarks.
- **Databases:** [SQL tabs](https://runletapp.dev/docs/sql-tabs), [Explain](https://runletapp.dev/docs/sql-explain), [connections](https://runletapp.dev/docs/connections) (saved connections, the TablePlus import, and the Connection Manager), [Redis](https://runletapp.dev/docs/redis), [MongoDB](https://runletapp.dev/docs/mongodb).
- **Inspecting Runs:** the [log viewer](https://runletapp.dev/docs/logs), [run timings](https://runletapp.dev/docs/run-timings), [notifications for long runs](https://runletapp.dev/docs/run-notifications).
- **Integrations:** the [`runlet` command](https://runletapp.dev/docs/cli), [AI clients (MCP)](https://runletapp.dev/docs/mcp).
- **Help:** [reading a crash log](https://runletapp.dev/docs/crash-logs).
- **Development:** [building Runlet](https://runletapp.dev/docs/building), [architecture](https://runletapp.dev/docs/architecture), [writing docs](https://runletapp.dev/docs/writing-docs), [changelog entries](https://runletapp.dev/docs/changelog), [releasing](https://runletapp.dev/docs/releasing).

The [CHANGELOG](CHANGELOG.md) has every change. Maintainers' notes that aren't on the site stay in `docs/`: [compatibility evidence](docs/compatibility.md), [validation](docs/validation.md), the [next-release ideas](docs/next-release-ideas.md), and the original [product plan](plan.md).

## Development

Runlet is a native macOS app written in Swift 6 with SwiftUI and AppKit. To build it from source, follow **[Building Runlet](https://runletapp.dev/docs/building)** ([`docs/building.md`](docs/building.md) on GitHub): the prerequisites, one-time setup, the PHP runner, generating the Xcode project, building (a Debug build runs as *Runlet Dev*), the package tests, and packaging. How the pieces fit together is in [Architecture](https://runletapp.dev/docs/architecture).

## Contributing and planned work

Bug reports and ideas are welcome in [Issues](https://github.com/filipac/runlet/issues). For code, follow [AGENTS.md](AGENTS.md): find or create a labeled GitHub issue before implementation or adding TODOs. A change users notice updates its page in `docs/` in the same pull request ([Writing Docs](https://runletapp.dev/docs/writing-docs)). The [next-release ideas](docs/next-release-ideas.md) link remaining work to issues; [completed ideas](docs/done-next-release-ideas.md) preserve implementation evidence and design history.

## License

[MIT](LICENSE). Bundled third-party components keep their own licenses: SwiftTerm (MIT), Sparkle (MIT), PHPantom, Mago (MIT or Apache-2.0; the MIT notice ships), nikic/php-parser (BSD-3-Clause), and the Laravel sandbox (MIT). Their notices ship in `Runlet.app/Contents/Resources/Licenses`.
