# Runlet: Tinkerwell feature inventory and MVP plan

Research date: 2 October 2026.

**Historical specification, reconciled under [#3](https://github.com/filipac/runlet/issues/3).** The MVP and many post-MVP features have shipped in 0.0.1/0.1.0. This inventory, acceptance criteria and handoff describe the original design; they are not untracked TODOs or instructions to rebuild delivered features. Follow [AGENTS.md](AGENTS.md), the [issue-linked active backlog](docs/next-release-ideas.md), and [completed scope/evidence](docs/done-next-release-ideas.md). Verification gaps remain explicit in [validation.md](docs/validation.md).

## Product direction

**Product name: Runlet.** Build an application-aware PHP scratchpad with three first-class execution modes in the MVP:

1. **Laravel sandbox:** open the app and run PHP/Laravel code immediately, without selecting a project.
2. **Local projects:** open an existing project and run code with its application context using local PHP.
3. **Docker applications:** run code inside existing PHP containers, with saved profiles for the many applications the user works on.

Laravel Vapor, Laravel Cloud, and Laravel Forge are outside the MVP and are not priorities for this product. SSH, Kubernetes, AI, MCP, and advanced framework integrations are later possibilities.

**MVP language server: PHPantom LSP.** Use its native binary for PHP completion and diagnostics in the sandbox, local projects, and locally mapped Docker projects. Keep PHP/Docker execution separate from language intelligence. [PHPantom documentation](https://phpantom-dev.github.io/phpantom_lsp/latest/)

**Primary platform and stack: native macOS using Swift, SwiftUI, and AppKit, developed in Xcode.** macOS is the current priority. A possible Windows version may reuse execution contracts and assets, but will need its own interface and platform integration.

The complete Tinkerwell inventory below is retained as a reference. Inclusion in the inventory does **not** mean inclusion in the MVP; the MVP requirements and later backlog define the proposed implementation scope.

## Research and evidence

Tinkerwell is an **application-aware PHP scratchpad**: an editor, a framework bootstrapper, several execution backends, and a rich result inspector. A version with nearly complete parity needs all four.

The investigation inspected the installed **Tinkerwell 5.17.0**, its menus, settings, and connection dialogs, and tested Laravel execution, magic comments, tables, object graphs, mail previews, and SQL inspection. The installed sandbox used **Laravel 13.16.1 and PHP 8.4.25**. The latest published Tinkerwell release found during the investigation was 5.17.2, bundling Laravel 13.23.0. “Latest Laravel” means the version bundled with a particular Tinkerwell release, rather than an independently updated framework installation. [Release notes](https://tinkerwell.app/changelog)

Execution tests used harmless snippets in a separate sandbox tab, including an in-memory SQLite database and a mailable rendered without sending email. Remote and cloud integrations were inspected or researched but were not exercised against the user's servers. Tinkerwell was returned to the original sandbox tab; verification runs remain in its execution history.

The following inventory describes parity requirements derived from the installed application, official documentation, release notes, and public framework drivers. Recommendations beyond observed or documented behavior are identified separately.

## Complete feature inventory

### 1. PHP execution and the default Laravel environment

| Feature                        | What the implementation should support                                                                                                    |
| ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------- |
| Immediate scratchpad           | Start typing and running PHP without creating a project or writing a PHP opening tag.                                                     |
| Bundled Laravel sandbox        | Ship a complete, bootstrapped Laravel application with Composer dependencies and usable configuration.                                    |
| Laravel APIs                   | Expose helpers, collections, facades, the service container, HTTP client, validation, views, and other installed framework functionality. |
| Existing project context       | Open a directory and execute code with its dependencies, configuration, services, models, and application bootstrap loaded.               |
| Manual execution               | Run button and configurable shortcut; Tinkerwell defaults to Cmd/Ctrl+R.                                                                  |
| Selected-code execution        | Run the selection independently; optionally make the normal Run action prefer selected code.                                              |
| Automatic evaluation           | Optionally rerun local code when it changes. Tinkerwell disables automatic evaluation for remote connections.                             |
| Expression results             | Display the final expression's value, alongside explicit output from `echo`, `dump`, `var_dump`, and `dd`.                                |
| Repeated editing and execution | Allow users to change snippets and application code and rerun without manually restarting a terminal REPL.                                |
| Output delivery                | Buffered results and real-time output, with process cancellation.                                                                         |
| Strict types                   | A setting that applies `declare(strict_types=1)` to execution across supported backends.                                                  |
| Runtime measurements           | Execution duration, memory usage, and script start time.                                                                                  |
| Custom default project         | Allow new tabs to open a chosen project instead of the bundled sandbox.                                                                   |

Sources: [Running code](https://tinkerwell.app/docs/5/basic-usage/evaluating-code), [Laravel Sandbox](https://tinkerwell.app/docs/5/setup-guides/using-the-laravel-sandbox).

The investigation confirmed that `collect([1, 2, 3])->map(fn ($n) => $n * 2)->sum()` returns `12` immediately.

For access to Laravel's features, **bootstrap Laravel itself rather than implementing its APIs in the desktop application**. Databases, queues, Redis, mail delivery, and other services still need suitable configuration. The sandbox should provide sensible defaults and clearly display which drivers are active. “Sandbox” describes the scratch application; operating-system or container isolation is a separate design decision.

### 2. PHP runtime selection and framework support

| Feature                       | What the implementation should support                                                    |
| ----------------------------- | ----------------------------------------------------------------------------------------- |
| PHP discovery                 | Detect an installed PHP executable, validate it, and show its version.                    |
| Global PHP configuration      | A default executable path for local execution.                                            |
| Project-specific PHP          | Remember a separate executable or alias for each project.                                 |
| Remote PHP selection          | Configure the PHP executable on each SSH connection.                                      |
| Runtime visibility            | Show the active framework, PHP version, directory, and execution target in the interface. |
| Automatic framework detection | Detect recognizable project files and choose the appropriate bootstrap driver.            |
| Plain Composer projects       | Load `vendor/autoload.php` when no framework driver matches.                              |
| Unsupported-project feedback  | Explain detection failures, with an option to suppress the notification.                  |
| Custom framework drivers      | Allow application-specific bootstrap logic and additional frameworks.                     |
| Laravel package development   | Support Orchestra Testbench projects, not just complete Laravel applications.             |

Tinkerwell's documentation and public driver repository collectively cover:

- Laravel, Laravel Zero, Lumen, Symfony, and Testbench.
- WordPress, Radicle, Craft CMS, Statamic, Kirby, and October CMS.
- Drupal 7/8, TYPO3, and Moodle.
- Magento/Magento 2, Shopware, and PrestaShop.
- A specialized Infection driver.

Treat this as a **compatibility matrix to validate by framework version**, rather than a promise that every historical version works identically. The documentation and public driver repository do not list exactly the same variants. [Framework documentation](https://tinkerwell.app/docs/5/basic-usage/evaluating-code), [public drivers](https://github.com/beyondcode/tinkerwell/tree/main/src/Drivers)

Keep the PHP runtime for execution separate from the runtime needed by the language server. Tinkerwell can execute remotely while still requiring local PHP for completion. [Project-specific PHP](https://tinkerwell.app/docs/5/advanced-usage/project-specific-php), [installation requirements](https://tinkerwell.app/docs/5/getting-started/installation)

Tinkerwell's current completion documentation identifies Phpactor cache paths, rather than Intelephense. This is reference behavior; our MVP uses PHPantom and does not inherit Tinkerwell's local-PHP requirement for its language server. [Tinkerwell autocompletion](https://tinkerwell.app/docs/5/setup-guides/autocompletion)

### 3. Local, remote, container, and cloud execution

| Target or feature         | What the implementation should support                                                                       |
| ------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Local machine             | Execute in the selected directory using the selected PHP binary.                                             |
| SSH                       | Host, port, username, remote application directory, and PHP path.                                            |
| SSH authentication        | Passwords, private keys, and encrypted-key passphrases.                                                      |
| SSH agents                | Work with configured agents, including tools such as 1Password.                                              |
| SSH-config import         | Import existing hosts and connection settings from the user's SSH configuration.                             |
| Connection management     | Named connections, groups, colors, search, recent connections, editing, duplication, and connection testing. |
| Bastion hosts             | ProxyJump connections through an intermediate host.                                                          |
| Agent forwarding          | A configurable forwarding option.                                                                            |
| Temporary upload location | A writable remote directory for execution support files.                                                     |
| Remote completion mapping | Associate a remote connection with a local checkout for indexing.                                            |
| Docker                    | Discover running containers, select the PHP container, and configure its working directory.                  |
| Docker conveniences       | Detect the working directory, refresh containers, and remember automatic connection settings.                |
| Docker execution options  | Custom `docker exec` flags, execution user, and writable temporary directory.                                |
| Docker through SSH        | Execute inside a container on a connected remote host.                                                       |
| Laravel Sail              | Use its PHP container and working directory through Docker support.                                          |
| DDEV/Lando/Warden         | Work through the underlying Docker containers.                                                               |
| Kubernetes                | Select configuration, context, and pod; detect or configure the application directory.                       |
| Remote Kubernetes         | Connect through SSH and use the remote host's Kubernetes configuration.                                      |
| Laravel Vapor             | Detect `vapor.yml`, discover environments, and execute in the selected environment.                          |
| Laravel Cloud             | Configure an API token, discover applications/environments, and execute there.                               |
| Laravel Forge             | Import servers/sites through the Forge API and handle deployment paths, including current-release symlinks.  |
| Homestead/VMs             | Connect to the VM through SSH.                                                                               |
| Windows WSL2              | Support projects running inside WSL2 through the appropriate SSH or Docker path.                             |

These are separate execution adapters, even when they share the editor and result interface. Sources: [SSH](https://tinkerwell.app/docs/5/setup-guides/ssh), [Docker](https://tinkerwell.app/docs/5/setup-guides/docker), [Kubernetes](https://tinkerwell.app/docs/5/setup-guides/kubernetes), [Vapor](https://tinkerwell.app/docs/5/setup-guides/vapor), [Laravel Cloud](https://tinkerwell.app/docs/5/setup-guides/laravel-cloud), [WSL2](https://tinkerwell.app/docs/5/setup-guides/wsl).

Backend differences to preserve in a parity implementation:

- Vapor's documentation requires explicit `dump()` output rather than relying on the final expression's value.
- The Laravel Cloud guide currently says its application log viewer is unavailable.
- Capabilities such as previews, streaming, and cancellation should be declared by each backend so the interface can explain their availability accurately.

### 4. Result inspection and export

| Feature                 | What the implementation should support                                                   |
| ----------------------- | ---------------------------------------------------------------------------------------- |
| Plain CLI output        | A familiar textual representation of execution results.                                  |
| Structured output cards | Separate cards for individual dumps/results, with type information and source locations. |
| Expandable objects      | Explore nested properties, arrays, collections, visibility, and references.              |
| Expansion preferences   | Collapsed output, first-level expansion, or deeper automatic expansion.                  |
| Table preview           | Convert suitable arrays and collections into rows and columns.                           |
| Table interaction       | Search/filter data and provide column sorting controls.                                  |
| CSV export              | Export tabular results directly to a file.                                               |
| Row copying             | Copy a row as JSON or a PHP array.                                                       |
| Object graph            | Display nested structures as expandable graph nodes.                                     |
| HTML preview            | Render Laravel views and mailables in a preview window.                                  |
| Preview refresh         | Rerun the snippet while the preview remains open and update its contents.                |
| SQL inspection          | Capture and display queries executed by the snippet, including bindings.                 |
| Output copying          | Copy results, including a Markdown representation where supported.                       |
| File export             | Save the textual output to a file.                                                       |
| Editor navigation       | Open the originating project file at the dump/error location in the preferred editor.    |

Tables, row-copy actions, graphs, mail rendering, and SQL tracing were verified locally. [Detail Dive documentation](https://tinkerwell.app/docs/5/basic-usage/detail-dive)

For a new SQL implementation, preserve the SQL template and bindings separately; optionally also provide a readable interpolated form. The current guide's SQL Server exclusion is outdated: release 4.13.0 added Microsoft SQL Server query logging. [Release notes](https://tinkerwell.app/changelog)

### 5. Inline debugging and diagnostics

| Feature                       | What the implementation should support                                                   |
| ----------------------------- | ---------------------------------------------------------------------------------------- |
| End-of-line magic comments    | `//?` displays the value associated with that line inside the editor.                    |
| Inline magic comments         | `/*?*/` inspects intermediate values within expressions.                                 |
| Method/property inspection    | Comments such as `/*?->count()*/` inspect a chain without restructuring the snippet.     |
| Timing checkpoints            | `/*?.*/` displays elapsed time at that point.                                            |
| Repeated observations         | Show multiple values/timings when an instrumented expression runs in a loop or callback. |
| Automatic inline logging      | An Auto Log mode that instruments eligible lines automatically.                          |
| Execution coverage indicators | Mark lines reached during execution.                                                     |
| Inline errors                 | Display diagnostics alongside the affected code.                                         |
| Detailed exception output     | Exception type, message, stack trace, and relevant source context.                       |
| Collision integration         | Configurable enhanced error rendering globally and per framework/project.                |
| Xdebug handoff                | Enable debugging for a tab and trigger the listening IDE's debugger.                     |

Magic comments currently require buffered output in Tinkerwell. A replacement should define how instrumentation interacts with streaming, formatting, selections, and source-line mapping. [Magic comments](https://tinkerwell.app/docs/5/advanced-usage/magic-comments)

Tinkerwell's documented Xdebug workflow depends on Laravel Herd and uses breakpoints in the IDE. Replicating that workflow means triggering Xdebug correctly; a full debugger interface inside the application would be additional scope. [Xdebug documentation](https://tinkerwell.app/docs/5/advanced-usage/debugging-with-xdebug), [Collision](https://tinkerwell.app/docs/5/advanced-usage/collision)

### 6. Editor and workspace experience

| Feature                         | What the implementation should support                                                                                |
| ------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| Full multiline PHP editor       | Syntax highlighting, indentation, comments, bracket matching, folding, find/replace, and multiple selections/cursors. |
| Language-server completion      | Classes, functions, variables, properties, methods, constants, and chained calls.                                     |
| Project indexing                | Index application dependencies and source; show indexing status and allow reindexing.                                 |
| Remote completion               | Index the associated local checkout for remote execution.                                                             |
| Laravel magic-method completion | Recognize generated IDE-helper information or provide equivalent Laravel-aware indexing.                              |
| Import assistance               | Insert missing `use` statements through code actions.                                                                 |
| PHP formatting                  | Manual formatting, optional formatting before execution, and configurable quote style.                                |
| Multiple tabs                   | Independent code, project, connection, and output context per tab.                                                    |
| Tab management                  | Create, rename, duplicate, switch, close others, and close tabs to the right.                                         |
| Session restoration             | Restore working tabs and their context after restart.                                                                 |
| File workflows                  | Open/save PHP files and a Watch File workflow for externally edited files.                                            |
| Command palette                 | Fuzzy search across commands, recent projects, connections, and snippets.                                             |
| Search categories               | Filters such as `#` snippets, `/` folders, and `@` connections.                                                       |
| Keyboard configuration          | Searchable, remappable application and editor shortcuts; Vim keymap option.                                           |
| Layout                          | Resizable editor/output split with horizontal and vertical layouts.                                                   |
| Minimal interface               | Hide toolbar/output, automatically hide output, fullscreen, and pin the window.                                       |
| Appearance                      | Light/dark themes, system color detection, fonts, ligatures, font size, and line height.                              |
| Editor display preferences      | Line numbers, wrapping, indentation width/guides, and magic-comment highlighting.                                     |
| Custom themes                   | Load user-defined editor and application colors from theme files.                                                     |

The installed application exposes a Monaco-style editor's extensive command set through shortcut settings. Completion needs careful handling of Laravel's dynamic methods. [Autocompletion](https://tinkerwell.app/docs/5/setup-guides/autocompletion), [tabs](https://tinkerwell.app/docs/5/basic-usage/tabs), [command palette](https://tinkerwell.app/docs/5/basic-usage/command-palette), [custom themes](https://tinkerwell.app/docs/5/advanced-usage/custom-themes)

### 7. History and reusable snippets

| Feature                | What the implementation should support                                                         |
| ---------------------- | ---------------------------------------------------------------------------------------------- |
| Execution history      | Persist previous runs and search their code.                                                   |
| Configurable retention | Let users choose the history limit; the inspected installation was configured for 320 entries. |
| History restoration    | Load an entry into the current tab or open it in another tab.                                  |
| Personal snippets      | Save the entire editor or a selected section with a label.                                     |
| Snippet editing        | Update existing snippets and organize their project associations.                              |
| Context-bound snippets | Associate a snippet with a local project or remote connection.                                 |
| History-to-snippet     | Turn a previous execution into a reusable snippet.                                             |
| Project snippets       | Load PHP files from `.tinkerwell/snippets`, with `@label` and `@description` metadata.         |
| Team sharing           | Share project snippets through the repository.                                                 |
| Fast navigation        | Search, keyboard selection, and opening in current/new tabs.                                   |

The history page still mentions a fixed 50-entry limit, but the installed settings expose a configurable limit. [History](https://tinkerwell.app/docs/5/basic-usage/history), [snippets](https://tinkerwell.app/docs/5/basic-usage/snippets)

### 8. Logs, information panels, and extensibility

| Feature                      | What the implementation should support                                                                                       |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Application log viewer       | Discover and open log files for the active project/connection.                                                               |
| Log filtering                | Search entries and filter by severity.                                                                                       |
| Live logs                    | Automatic refresh or configurable remote polling.                                                                            |
| Nested log directories       | Discover logs within subdirectories.                                                                                         |
| Framework-specific log paths | Allow drivers to specify where logs live.                                                                                    |
| Application information      | Framework/PHP versions, environment, debug mode, URL, locale, timezone, and maintenance status.                              |
| Configuration panels         | Show cache status and active database, mail, queue, session, and logging drivers.                                            |
| Custom panels                | Application-defined panels containing titled sections and key/value tables.                                                  |
| Custom driver discovery      | Load project-local and global driver classes.                                                                                |
| Bootstrap extensions         | Detection, bootstrap, predefined variables, framework version, query logging, log paths, panels, and AI-referenceable files. |

Tinkerwell combines panels supplied by drivers with panels in `.tinkerwell/panels`. Its public workbench provides concrete driver and panel interfaces for designing an extension API. [Log viewer](https://tinkerwell.app/docs/5/advanced-usage/log-viewer), [panels](https://tinkerwell.app/docs/5/extending-tinkerwell/panels), [custom drivers](https://tinkerwell.app/docs/5/extending-tinkerwell/custom-drivers), [public workbench](https://github.com/beyondcode/tinkerwell)

### 9. AI assistance and MCP

| Feature                  | What the implementation should support                                      |
| ------------------------ | --------------------------------------------------------------------------- |
| AI chat sidebar          | Generate, explain, debug, optimize, and refactor snippets conversationally. |
| Controlled context       | Per-message inclusion of editor content and execution output.               |
| Explicit file references | Use `@` to attach chosen project files to the conversation.                 |
| Conversation context     | Maintain the conversation for the active tab/session.                       |
| Bring-your-own-key       | Configure provider credentials and models.                                  |
| Separate providers       | Independent provider/model settings for chat and completion.                |
| Provider compatibility   | OpenAI, Anthropic, Mistral, and configurable OpenAI-compatible endpoints.   |
| AI completion            | Suggestions on typing, after idle time, or on demand.                       |
| Completion caching       | Reduce repeated provider requests and show activity/status.                 |
| Provider diagnostics     | Connection checks and clear authentication/model/request errors.            |
| MCP server               | Expose execution and snippet management to external clients.                |
| MCP setup                | Client configuration helpers and a copyable manual configuration.           |

Tinkerwell's documented MCP tools are `evaluate-local-php-code`, `evaluate-remote-php-code`, `get-remote-connections`, `get-snippets`, and `add-snippet`. The MCP server can operate without configuring Tinkerwell's own AI provider. [AI chat](https://tinkerwell.app/docs/5/advanced-usage/ai-assistant), [AI completion](https://tinkerwell.app/docs/5/setup-guides/autocompletion), [MCP](https://tinkerwell.app/docs/5/advanced-usage/mcp-server)

A replacement should use the same execution engine for UI and MCP calls and make the requested execution target explicit in every call.

### 10. Desktop and developer-tool integration

| Feature                     | What the implementation should support                                                                        |
| --------------------------- | ------------------------------------------------------------------------------------------------------------- |
| Desktop platforms           | macOS Intel/Apple Silicon, Windows, and Linux for broad parity.                                               |
| Terminal launcher           | Open a project from its directory or a supplied path; Tinkerwell's standalone helper is documented for macOS. |
| Laravel Herd integration    | Detect PHP runtimes and project isolation, respect relevant configuration, and support opening Herd sites.    |
| IDE launching               | Open projects and source locations in the user's preferred editor.                                            |
| PhpStorm integration        | A companion plugin for local/SSH execution, query inspection, and table results.                              |
| Preferences and diagnostics | Persistent settings, language-server diagnostics, logs, and recoverable configuration errors.                 |
| Distribution                | Update checks, release information, and application/runtime compatibility management.                         |
| Commercial features         | License activation and entitlement management if the product requires them.                                   |

Herd also launches Tinkerwell through site actions, global shortcuts, and `herd tinker`. The PhpStorm plugin is a separate integration surface. [Herd integration](https://tinkerwell.app/features/laravel-herd-integration), [CLI helper](https://tinkerwell.app/docs/5/advanced-usage/cli-helper), [PhpStorm plugin](https://tinkerwell.app/docs/5/getting-started/phpstorm-plugin)

## Architecture for eventual broad parity

Build these as distinct components:

1. **Desktop editor:** tabs, commands, settings, snippets, history, and previews.
2. **PHP execution engine:** framework bootstrap, snippet evaluation, output capture, instrumentation, and cancellation.
3. **Execution adapters:** local process and Docker first; optional SSH, Kubernetes, and other backends later.
4. **Structured result protocol:** typed values, dump events, source locations, SQL events, HTML previews, errors, and measurements.
5. **Language service:** PHPantom LSP process management, completion, diagnostics, hover/signature help, document synchronization, and path mapping; richer navigation and code actions can follow.
6. **Integration layer:** optional AI providers, MCP, terminal launcher, IDE plugins, and framework extensions.

The structured result protocol deserves early attention: tables, graphs, previews, magic comments, and SQL inspection depend on information that plain stdout cannot reliably preserve.

The original broad-parity build order was core execution/editor first, structured inspection and Docker/SSH second, then advanced integrations. The revised MVP below brings **Docker into the first release alongside local projects and the sandbox**.

Additional sandbox recommendations beyond the parity inventory: version pinning, a reset command, disposable SQLite data, and visible service configuration.

## MVP requirements

### Outcome

The first release should replace the user's everyday scratchpad workflow: open a local PHP project or choose an existing Docker application, write a multiline snippet, run it in the right context, inspect the result, and keep useful code for later. Opening the app without a project should provide the Laravel sandbox immediately after its runtime is available.

### Initial assumptions

- **Native macOS first**, using SwiftUI for the application and AppKit for the code editor. Keep execution contracts and assets reusable; future Windows/Linux interfaces and adapters are separate work.
- **Laravel first**, plus plain PHP and Composer projects. Other framework bootstrappers follow later.
- **Local PHP and Docker are both execution backends.** A local project does not require Docker. A Docker project does not require host PHP for execution.
- **PHPantom is the MVP language server.** Bundle a tested native release; basic language intelligence does not require host PHP or a separate tooling container. Project source and installed dependency files must be locally readable for full project completion.
- **One bundled, pinned Laravel version** for the sandbox in each release. Display the actual Laravel/PHP versions instead of claiming they update independently.
- **Manual execution by default** for all three modes. Automatic evaluation is a later convenience.
- **Fresh execution context per run** as the proposed MVP behavior. Reevaluate the submitted snippet rather than retaining variable/class state between runs. Saved application data and external side effects still persist normally.
- Use the machine's selected Docker context initially. Additional contexts and remote Docker hosts are later scope.

### Must-have capabilities and acceptance criteria

| ID  | Capability                   | Acceptance criteria                                                                                                                                                                                                                                                                                      |
| --- | ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| M01 | Laravel sandbox              | New scratch tabs work without a project; Laravel helpers, collections, container resolution, validation, HTTP APIs, and view rendering are available through a bootstrapped application.                                                                                                                 |
| M02 | Sandbox runtime              | Use compatible local PHP when available; provide a Docker-backed sandbox path when local PHP is unavailable. Explain any required first-use image download.                                                                                                                                              |
| M03 | Local projects               | A directory picker opens a project; Laravel bootstrap loads providers, configuration, and models; generic Composer projects load their autoloader; plain PHP directories remain usable without an autoloader.                                                                                            |
| M04 | PHP selection                | Detect local PHP; allow a global default and per-project override; validate compatibility and show the active version.                                                                                                                                                                                   |
| M05 | Existing Docker applications | List running containers, select one, set the application directory and PHP executable, then run inside that container with its environment and access to its configured services.                                                                                                                        |
| M06 | Saved Docker profiles        | Save a name, container/service identity, working directory, PHP path, execution user, writable temporary directory, and optional local source mapping. Search and reopen profiles quickly.                                                                                                               |
| M07 | Container recreation         | Resolve a saved profile after container recreation using stable Compose project/service labels where available; prompt for a replacement when identity is ambiguous. Never silently execute in a different container.                                                                                    |
| M08 | Native multiline editor      | An AppKit-based PHP editor supports highlighting, indentation, brackets, comments, find/replace, selection, undo/redo, and native text input. Integrate it into SwiftUI without resetting document state on view updates.                                                                                |
| M09 | Run actions                  | Run the full snippet or only its selection through a button and keyboard shortcut. Explicitly label the active target.                                                                                                                                                                                   |
| M10 | PHP output                   | Preserve stdout/stderr and display the final expression value, `echo`, `dump`, `var_dump`, and `dd`; handle multiple dumps in their execution order.                                                                                                                                                     |
| M11 | Structured inspection        | Expand arrays, collections, and objects with type information. Bound depth/size and represent references/cycles without freezing.                                                                                                                                                                        |
| M12 | Errors                       | Show parse/runtime/bootstrap errors with messages and relevant source lines. Recover so a corrected snippet can run immediately.                                                                                                                                                                         |
| M13 | Cancellation                 | Stop a long-running local or Docker execution and regain a usable editor. Target the runner process rather than stopping the application container.                                                                                                                                                      |
| M14 | Tabs                         | Each tab retains its snippet and execution profile independently; create, switch, rename, duplicate, and close tabs.                                                                                                                                                                                     |
| M15 | Session persistence          | Restore unsaved code and selected targets after restart; require an explicit Run action after restoration.                                                                                                                                                                                               |
| M16 | Execution history            | Save timestamp, code, target label, and success/failure status; search and restore prior code without executing it automatically.                                                                                                                                                                        |
| M17 | Personal snippets            | Save, label, edit, search, and reopen snippets. Keep target association explicit and visible.                                                                                                                                                                                                            |
| M18 | PHPantom editor intelligence | Provide PHP/project class and member completion, hover, signature help, and live diagnostics through PHPantom. Support unsaved scratch tabs, the sandbox, native local projects, and mapped Docker source; map positions and completion edits correctly.                                                 |
| M19 | Completion without host PHP  | Run the bundled native PHPantom binary on the host even when execution uses Docker. Read locally available project/dependency sources; report missing source/vendor files and offer basic PHP completion when necessary. No language-service packages are installed in the user's application container. |
| M20 | Basic preferences            | Light/dark appearance, font size, indentation, a resizable output pane, default PHP, and default project.                                                                                                                                                                                                |
| M21 | Copy and files               | Copy output and open/save snippets as PHP files. Saving must not execute code.                                                                                                                                                                                                                           |
| M22 | Run status                   | Show ready/running/stopped/failed state, elapsed time, framework version, and PHP version where available.                                                                                                                                                                                               |

For a Docker container without a mapped local checkout, execution remains supported. Completion should fall back to basic PHP suggestions with a visible explanation; downloading or synchronizing arbitrary container source is outside the MVP.

### PHPantom LSP integration

**Decision:** use PHPantom for the MVP, behind a small language-service adapter. It is a Rust language server distributed as native binaries, with standard LSP communication over stdin/stdout. The MIT license permits redistribution with the required notice; include notices for bundled third-party components as applicable. The project is actively developed, so ship a tested stable release rather than tracking `main` or downloading an unpinned latest binary. [Installation](https://phpantom-dev.github.io/phpantom_lsp/latest/installation/), [editor setup](https://phpantom-dev.github.io/phpantom_lsp/latest/editor-setup/), [license](https://github.com/PHPantom-dev/phpantom_lsp/blob/main/LICENSE)

The implementation should support:

- **Desktop integration:** bridge the editor's LSP client to a backend-managed `phpantom_lsp` process. Keep protocol messages separate from stderr logs. Initialize capabilities, synchronize open/change/close events, and handle shutdown, crashes, restart, and request cancellation.
- **Project isolation:** use one server session per workspace/configuration, reused by tabs in the same workspace. Separate sandbox and application projects so suggestions cannot leak across them; associate responses with the current tab, document version, and target.
- **Scratch documents:** present unsaved snippets as stable PHP documents associated with the chosen workspace. If snippets omit `<?php`, synthesize it only for the language service and map diagnostic ranges, hover positions, and completion text edits back to the editor. Verify this with the chosen PHPantom release; use an app-owned temporary-file strategy if virtual documents are insufficient. Do not write scratch files into the user's project.
- **MVP editor surface:** completion, hover, signature help, and open-document diagnostics. Keep execution errors visibly distinct from static diagnostics. Do not block Run because a static diagnostic exists. Preserve PHPDoc/generic type information where supplied by PHPantom.
- **Laravel coverage:** test built-in completion for facades, Eloquent relationships/scopes/casts, query-builder chains, and collections in the bundled sandbox and representative projects. PHPantom documents Laravel-aware inference without requiring IDE Helper or live database access; validate actual coverage instead of promising every dynamically registered member. [PHPantom features](https://phpantom-dev.github.io/phpantom_lsp/latest/)
- **Source availability:** use the real local project root, its Composer metadata, and installed dependencies. For Docker, analyze the mapped local checkout while executing in the container. A checkout with `vendor` present only in a Docker volume may have limited dependency completion; show that limitation. A later dependency-mirroring feature can address it.
- **Version/configuration handling:** align the language-service PHP target with project constraints or a profile override, rather than the host's execution binary. Respect existing `.phpantom.toml` configuration. Test how the app supplies overrides without rewriting user repositories or global settings. PHP-version/indexing changes may require a server restart. [Configuration](https://phpantom-dev.github.io/phpantom_lsp/latest/configuration/)
- **Predictable Docker-only behavior:** use core native analysis for the MVP. Disable automatically discovered external analyzers/formatters in the app's server configuration; verify the configuration mechanism during the integration spike. PHPStan, PHPCS, Pint, and similar subprocess tools can require PHP and container-aware command routing, so defer them to optional later integrations. [External-tool configuration](https://phpantom-dev.github.io/phpantom_lsp/latest/configuration/)
- **Packaging and readiness:** package Apple Silicon and Intel macOS binaries with the desktop release and verify signing/execution on supported machines. Display server readiness and failures; do not make all editing wait for a full background workspace scan. Measure startup, memory, and completion latency on the user's projects before setting budgets.

This is a documented integration plan, not an implemented or benchmarked integration. PHPantom's advertised performance figures should not be treated as our application's measured performance.

### Docker profile details

The user has many Docker applications, so target switching and persistence are core functionality rather than polish.

| Field                       | Purpose                                                                                                                            |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| Profile name                | Human-readable application label.                                                                                                  |
| Associated local project    | Optional source directory for indexing and host/container path mapping.                                                            |
| Container identity          | Compose project/service labels when present, with container name as a fallback.                                                    |
| Container working directory | Directory containing the application and its installed dependencies.                                                               |
| PHP executable              | Default `php`, with an override for unusual images.                                                                                |
| Execution user              | Support images that require a non-root user, including Sail.                                                                       |
| Temporary directory         | Writable location for the runner; default to `/tmp`, but permit an override.                                                       |
| Connection preference       | Remember whether opening this profile should resolve its Docker target automatically; this must not automatically run the snippet. |

Working-directory detection should suggest candidates from container metadata and mounts, while allowing manual correction. Docker discovery must not depend on a local Compose file or on PHP being installed on the host.

### Deliberately deferred

- SSH, bastion hosts, Kubernetes, and remote Docker orchestration.
- Laravel Vapor, Cloud, and Forge.
- AI chat, AI completion, and MCP.
- Magic comments, automatic coverage, and timing checkpoints.
- SQL inspector, tables/CSV export, object graphs, and HTML/mail preview UI.
- Dedicated application-log viewer and custom information panels.
- Custom-driver SDK and the wider CMS/framework matrix.
- IDE plugins, deep Herd integration, custom theme files, and commercial licensing.

Laravel APIs can still be called from a snippet even when a dedicated inspector or preview interface is deferred. For example, users can render a view and inspect its HTML string, run Eloquent queries and inspect collections, or use `Http` with configured networking.

## Plan

Implement Runlet as a macOS-first PHP scratchpad with a shared editor and result inspector for the Laravel sandbox, native local projects, and existing Docker applications. Prioritize dependable bootstrapping, clear target selection, saved Docker profiles, and fast repeat execution.

### Scope

- **In:** Laravel sandbox; local PHP/Composer/Laravel projects; existing local Docker containers; PHP selection; multiline editor; PHPantom completion/hover/signature help/live diagnostics; manual/selected execution; structured dumps; errors; cancellation; tabs; history; personal snippets; basic appearance and file operations.
- **Out:** Vapor/Cloud/Forge; SSH/Kubernetes; AI/MCP; full framework parity; advanced inspectors; application-log tooling; IDE plugins; licensing; Windows/Linux release packaging.

### Original action items: disposition

Execution/result contracts, runner/local adapter, sandbox, Docker discovery/profiles, editor/output, PHPantom, and persistence are implemented; see [completed scope](docs/done-next-release-ideas.md), `CHANGELOG.md`, and [architecture.md](docs/architecture.md). The original checkbox list is retired rather than treated as new work.

Representative-project validation, edge-case/UI coverage, packaged-app dogfooding and rendered latency measurement remain subject to [#54](https://github.com/filipac/runlet/issues/54). The existing validation record is historical evidence, not a fresh test run. Release signing/updating is [#24](https://github.com/filipac/runlet/issues/24).

### Original setup questions: disposition

The repository is `filipac/runlet`, the minimum platform is macOS 26, and pinned runtime/dependency choices and compatibility evidence are recorded in `docs/compatibility.md` and `docs/architecture.md`. Remaining real-application and compatibility validation is tracked in [#54](https://github.com/filipac/runlet/issues/54) and [#117](https://github.com/filipac/runlet/issues/117).

### MVP architecture decisions

- **Keep the UI separate from process execution.** The desktop backend launches PHP or Docker commands and sends structured results to the editor.
- **Use one PHP runner for all MVP modes.** Local and Docker adapters supply the working directory, PHP executable, environment, and transport; framework bootstrap stays in the runner.
- **Use a framed event protocol.** Arbitrary application output must not corrupt machine-readable results. Maintain a distinct channel or robust framing for execution events and ordinary stdout/stderr.
- **Use parsed PHP for final-expression capture.** Avoid string heuristics that break on closures, comments, multiline statements, declarations, and opening tags. Record line mappings when wrapping selected code.
- **Use mature value-dumping tools.** Preserve object metadata and reference identity while enforcing output/depth limits. Plain JSON serialization is insufficient for arbitrary PHP objects.
- **Store sandbox writes in app-owned user data.** The packaged application assets should remain immutable; temporary files, compiled views, SQLite data, and caches need writable locations.
- **Keep PHPantom independent of execution.** Run the bundled native LSP binary on the host; run snippets through local PHP or Docker. Use local workspace sources for analysis and host/container mappings for source navigation. No tooling container is required for core completion. Retain an adapter boundary so future server upgrades or replacement do not change execution contracts.
- **Do not install tooling into application projects.** Prepare the runner in app-owned temporary locations. Generic Composer loading and supported framework bootstrap should work without adding project dependencies.
- **Pass commands as argument arrays.** Handle executable paths, project directories, Docker users, and temporary paths without shell interpolation. Expose the necessary Docker options as validated profile fields.
- **Cancel the actual execution.** Killing the host `docker exec` client alone may leave PHP running inside the container. Track the runner and ensure Stop terminates that run without stopping the user's application container.
- **Associate every response with its run and tab.** Prevent old results from replacing newer ones or crossing between application profiles.
- **Persist code, not automatic execution.** Restoring tabs, snippets, and history should never rerun code implicitly.

These are proposed implementation decisions, not claims about Tinkerwell's private internals.

### End-to-end acceptance scenarios

1. **Sandbox:** launch without a project; run a collection/helper snippet; see the final value; inspect multiple explicit dumps; see Laravel/PHP versions.
2. **Native Laravel:** open a local project, choose its PHP binary, resolve an application service, query fixture data through its models, edit project code, and observe the edit on the next run.
3. **Composer:** open a generic project and instantiate a class loaded from its Composer autoloader.
4. **Docker:** choose a running container and application directory; execute with its configured database/service environment; inspect a collection; save and reopen the profile.
5. **Many applications:** keep different local/Docker projects open in separate tabs; switch between them repeatedly; verify every result and run label belongs to the intended target.
6. **Container recreation:** recreate a Compose service and reopen its saved profile; resolve the replacement correctly or request a new selection when ambiguous.
7. **Restricted container:** execute as a configured non-root user with a custom writable temporary directory and a read-only application mount.
8. **Selection and errors:** run only a selection; display correct editor lines for syntax/runtime failures; fix the snippet and rerun successfully.
9. **Stop:** cancel a long-running local run and a Docker run; verify their runner processes end while the application container stays running.
10. **Recovery:** restart the desktop app; restore code/tabs/profiles; reopen history and snippets; confirm no code executes automatically.
11. **Output robustness:** inspect nested/cyclic objects, binary or invalid-UTF-8 data, large arrays, multiple dumps, stdout/stderr, and `dd` termination without losing completion status.
12. **Docker-only setup:** run the sandbox and an existing container without host PHP; obtain PHPantom completion/diagnostics when local source and dependencies are mapped, and a clear fallback when they are unavailable. Confirm that no external PHP analyzer or formatter is launched implicitly.
13. **Unsaved scratch intelligence:** type a tagless multiline snippet; verify completion, hover, signature help, diagnostic ranges, and inserted imports/text edits refer to the visible code. Edit rapidly and confirm stale diagnostics do not overwrite newer ones.
14. **Language-service isolation and recovery:** use tabs from two projects with conflicting class names and different PHP targets; verify correct suggestions in each, then stop/crash the LSP process and confirm restart restores intelligence while snippet execution remains usable.
15. **Laravel completion:** verify representative facade calls, Eloquent relation/scope/builder chains, model casts, and collection element types in the pinned sandbox and a real local/Docker application; record unsupported dynamic cases explicitly.

## Implementation handoff for another agent

### How to use this specification

The MVP requirements, implementation contracts below, and acceptance scenarios define Runlet's first release. The Tinkerwell inventory describes reference features; do not implement the whole inventory. Nice-to-haves are backlog, not release requirements. PHPantom is the selected language server. Sandbox, native local projects, and existing Docker applications are all required.

This is enough to begin implementation, with deliberate prototype gates for unresolved behavior. It is not evidence that the PHP runner, Docker cancellation, or PHPantom integration already work. Record prototype results and compatibility limits before building the rest of the app around them.

### Implementation defaults and component boundaries

Use **Swift, SwiftUI, and AppKit** as the primary implementation, developed in **Xcode** with **Swift Package Manager** for reusable modules and dependencies. This native macOS direction supersedes the earlier Electron default. Record package versions, deployment target, and module boundaries in `docs/architecture.md`. Existing repository conventions can inform the layout; do not silently substitute a web desktop stack for the selected native direction.

#### Recommended tech stack

| Layer                    | Choice                                             | Guidance for implementation agents                                                                                                                             |
| ------------------------ | -------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language and development | Swift, Xcode, Swift Package Manager                | Use typed domain models, versioned Codable schemas, reusable packages, and reproducible Xcode build/test settings.                                             |
| Application interface    | SwiftUI                                            | Implement windows, toolbars, target selection, tabs, settings, history/snippets, and result inspection; use AppKit where finer macOS control is needed.        |
| Code editor              | AppKit text system, initially NSTextView/TextKit   | Embed through NSViewRepresentable; preserve each tab's text, undo history, selection, and scroll state. Add PHP-specific editor behavior and LSP presentation. |
| Process supervision      | Foundation Process and Pipe with Swift concurrency | Launch local PHP, Docker CLI, and PHPantom with executable URLs and argument arrays; consume streams asynchronously and supervise termination.                 |
| PHP intelligence         | PHPantom native binary                             | Launch independently of PHP execution; package a pinned binary for each supported platform/architecture.                                                       |
| Execution                | App-owned PHP runner                               | Launch through local PHP or Docker adapters; keep framework bootstrap and result capture shared.                                                               |
| Persistence              | Versioned JSON via Codable                         | Follow the atomic-write/recovery contracts below; evaluate SQLite later if history/search requirements justify it.                                             |
| Tests                    | Swift Testing/XCTest and Xcode UI tests            | Test reusable services independently and verify native editing, focus, shortcuts, restoration, and packaged app behavior.                                      |
| Packaging                | Xcode build/archive and macOS app bundle           | Target Apple Silicon and Intel; use matching LSP assets per architecture, or a tested universal build. Configure signing/notarization for direct distribution. |

**Why native macOS:** the user prioritizes macOS over sharing a single interface across platforms. SwiftUI and AppKit provide the intended native application structure and text input integration. Foundation supports running and monitoring subprocesses with working directories, environment variables, and standard streams. PHPantom and the PHP runner remain external executables; they do not need to be rewritten in Swift. This is an architectural recommendation, not a measured claim about Runlet's eventual memory usage or speed. [NSViewRepresentable](https://developer.apple.com/documentation/swiftui/nsviewrepresentable), [NSTextView](https://developer.apple.com/documentation/appkit/nstextview), [Process](https://developer.apple.com/documentation/foundation/process), [Pipe](https://developer.apple.com/documentation/foundation/pipe)

**Tradeoff:** an AppKit text view provides native editing primitives, not a complete PHP IDE editor. Syntax highlighting, line numbers, indentation, bracket handling, completion presentation, hover/signature UI, and diagnostic decorations need implementation or integration with a suitable native editor component. Validate that work early. A possible Windows version will require a separate UI and platform services; do not promise that SwiftUI views can be reused there.

#### Native editor prototype gate

Before building the complete interface, demonstrate a native editor inside SwiftUI that can:

- Edit a multiline PHP scratch document with line numbers, highlighting, indentation, bracket insertion, and native find/replace.
- Preserve undo/redo, selection, focus, and scroll position across SwiftUI updates and tab switches. Disable smart quotes/dashes and prose spell correction for code. Handle input-method composition and Unicode without corrupting text or applying completion edits to stale ranges.
- Present PHPantom completion, hover, signature help, and diagnostics, including synthetic PHP opening-tag mapping and additional import edits.
- Keep editing responsive while processing output and LSP events. Test a substantial snippet/document and bounded large output; do not promise performance from framework choice alone.

Use NSViewRepresentable with an explicit coordinator for native editor events. Treat the document/session as durable state rather than recreating the text view on every update. Evaluate maintained AppKit editor components if they reduce this work, recording their licensing, compatibility, and integration limits. A basic SwiftUI TextEditor alone is not the intended code editor. If the prototype exposes a serious limitation, document it before changing the architecture.

#### Distribution and sandbox policy

Target direct distribution of a signed and notarized macOS application rather than making Mac App Store publication an MVP requirement. Plan initially for an application without Apple's App Sandbox, because Runlet launches user-selected PHP/Docker executables and accesses existing application projects. App Sandbox requires a separate access/entitlement design, and subprocesses inherit the parent's sandbox restrictions. Keep this distinct from Runlet's **Laravel sandbox**, which is an execution workspace rather than an OS security boundary. Hardened runtime, signing, and notarization are separate packaging concerns. Missing distribution credentials should not prevent a locally installable development/test build. [Apple App Sandbox](https://developer.apple.com/documentation/security/app-sandbox), [Process sandbox inheritance](https://developer.apple.com/documentation/foundation/process)

#### macOS first, portable component design

- Put PHP/Docker executable discovery, paths, process creation/termination, and resource lookup behind service protocols. Keep AppKit/SwiftUI dependencies in the macOS application layer.
- Keep PHP evaluation, Docker profile resolution, run/value schemas, persistence schemas, and LSP document mapping independent of macOS UI APIs.
- Reuse the PHP runner, pinned sandbox assets, protocol/value/persistence definitions, fixtures, and behavioral specifications in a future Windows implementation. Swift service modules may be reusable where platform support permits, but both the Windows UI and process integration need deliberate implementation and validation.
- Resolve executables correctly when launched from Finder, where environment/PATH may differ from a terminal. Preserve explicit executable overrides and test paths containing spaces.
- Resolve PHPantom and runner/sandbox resources through the application bundle and writable app-support locations; test process startup from the installed app, not only from Xcode. Include matching architecture binaries and required license notices.
- Treat Windows process cancellation, executable/path handling, and optional WSL workflows as dedicated adapter work. Revalidate Docker access and resource packaging on Linux. Neither platform is a release requirement for the first MVP.
- Keep process work, stream reads, indexing coordination, and heavy result normalization off the main actor; update UI state on the main actor. Bound output and LSP concurrency. Do not call blocking process waits or perform synchronous pipe draining on the UI thread.

Use a single repository with these responsibilities; exact folder names may follow existing conventions:

```text
Runlet.xcodeproj/               macOS application build, signing, and resources
Runlet/App/                     application lifecycle and dependency composition
Runlet/Features/                SwiftUI tabs, targets, output, settings, history/snippets
Runlet/Editor/                  AppKit editor, SwiftUI wrapper, LSP presentation
Packages/RunletCore/            domain models, validated Codable schemas, persistence
Packages/RunletExecution/       local/Docker adapters and run/process state machines
Packages/RunletLanguage/        PHPantom lifecycle, LSP transport and source mapping
Resources/Runner/              app-owned PHP runner and dependency build
Resources/Sandbox/             pinned Laravel project and runtime configuration
Resources/LSP/                 architecture-specific PHPantom binaries and notices
Tests/Fixtures/                disposable plain-PHP, Composer, Laravel, Docker apps
RunletUITests/                 native app and editing workflow checks
docs/                          architecture, compatibility, validation evidence
```

SwiftUI views and the AppKit editor own presentation and native input. Service protocols/actors own filesystem access, PHP/Docker/LSP processes, persistence, and validated requests. Expose typed operations such as `startRun`, `cancelRun`, `listTargets`, and `saveSnippet` to presentation models rather than launching commands from views. Keep mutable run/session state isolated, handle stream backpressure, and make cancellation/termination cleanup explicit. Render ordinary output as text; dedicated HTML previews remain deferred.

Use a maintained PHP AST parser for snippet transformation, with `nikic/php-parser` as the initial candidate. Verify its runtime and parsed-syntax compatibility against the supported PHP matrix before pinning it. Resolve runner dependencies independently of application dependencies: test projects with a conflicting parser/dumper version and use a scoped dependency build or another proven approach where needed. Never run Composer installation in the user's project to make Runlet work. [PHP-Parser](https://github.com/nikic/PHP-Parser)

### Execution contract

Each accepted run snapshots the tab ID, document version, code/selection, target profile revision, working directory, and PHP executable. Assign a unique `runId`. Later edits or target changes cannot redirect an active run. Allow one active run per tab; reject a second Run until the first completes or is stopped. Runs in different tabs may execute concurrently, with a small bounded worker limit.

Use a new PHP CLI process for every run. Bootstrap in this order:

1. Set the target working directory and initialize Runlet's event/error handling.
2. For Laravel, load the project's autoloader and application bootstrap, then perform the supported console bootstrap so providers, configuration, helpers, and models are available.
3. For a generic Composer project, load its existing `vendor/autoload.php`. If Composer dependencies are expected but absent, report the missing dependency installation.
4. For a plain PHP directory without Composer/framework markers, execute without an application autoloader. Explicit includes in the snippet still resolve relative to the selected working directory.
5. Evaluate only the submitted snippet, capture output/results, finalize, and clean up app-owned run files.

Runner implementation must prove that namespaces, declarations, imports, strict types, and dependency loading coexist correctly. Do not wrap snippets in a transformation that silently makes valid top-level PHP constructs invalid. Keep the application's environment/bootstrap behavior intact rather than parsing `.env` in the SwiftUI layer.

Define visible result behavior explicitly:

| Snippet behavior                                             | Required outcome                                                                                                               |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------ |
| Final top-level expression, such as `collect([1, 2])->sum()` | Evaluate once and show its value; an omitted final semicolon is accepted when the expression is otherwise valid.               |
| Final assignment, such as `$value = 42;`                     | Show the assignment expression's value.                                                                                        |
| Explicit top-level `return $value;`                          | Show the returned value.                                                                                                       |
| Final declaration, `if`, or loop with no returned expression | Complete successfully with no implicit result.                                                                                 |
| Expression returns `null`                                    | Display `null`, distinct from no implicit result.                                                                              |
| `echo`, stderr, or `var_dump`                                | Preserve textual output.                                                                                                       |
| `dump`                                                       | Show an ordered structured dump when supported; always preserve a readable fallback.                                           |
| `dd`                                                         | Show the dump and complete with an explicit `dd` termination reason.                                                           |
| `exit`/`die`                                                 | Retain available output and show termination/exit code; synthesize completion from process exit if no final event was emitted. |
| Parse, bootstrap, runtime, or fatal error                    | Show the error stage and original snippet/project location when available; the next run starts cleanly.                        |

Run Selection evaluates the selection independently. Its variables/imports do not come from unselected code. Map selection errors back to the original editor range. Preserve AST/source mappings separately from LSP document mappings, including multibyte text and the editor's character-position convention.

### Run events and value schema

Define runtime-validated, versioned schemas before UI implementation. The minimum contracts are:

```text
RunRequest = protocolVersion, runId, tabId, documentVersion,
             targetSnapshot, code, optionalSelectionRange

RunEvent = protocolVersion, runId, sequence, type, payload

type = started | stdout | stderr | dump | result | error | finished

finished = status(completed | failed | cancelled), reason,
           optionalExitCode, elapsedMs, optionalTruncationSummary

ValueNode = id, type, optionalClassName, optionalScalar,
            optionalEntries, optionalReferenceId, optionalTruncation
```

Arrays must preserve ordered keys and key types. Object nodes retain class/type information, property visibility where available, and reference IDs for cycles/repeated objects. Do not invoke arbitrary getters, `__toString`, or JSON serialization just to inspect a result. Treat `var_dump` as text unless a proven capture mechanism supplies structured information; do not parse its printed text into objects.

Emit exactly one backend-level terminal `finished` event per accepted run, including launch failure, fatal exit, cancellation, and missing runner events. Do not report success merely because transport closed. Associate errors with `stage = launch | bootstrap | parse | execute | transport`. Include a mapped file/range where available.

Keep raw application stdout/stderr separate from machine events. **Initial transport candidate:** a run-specific append-only event file in the writable run directory, with raw process output on its normal streams. For Docker, prove a reader can stream that file using available container capabilities without requiring extra installed utilities. Handle partial writes and bound file growth. If another transport performs better, retain the same event contract and demonstrate that binary output cannot corrupt it. This transport choice must pass the prototype gate before the editor depends on it.

Assign sequence numbers to normalized delivery events. Preserve structured-dump order and each raw stream's byte order; do not promise exact interleaving between independently delivered stdout/stderr. Start with configurable limits of **8 MiB captured raw output per run, 2 MiB per structured value, depth 8, and 200 children per expanded node**. These are proposed defaults to tune with fixtures. Display truncation and keep draining or safely discarding further output so a full buffer cannot deadlock the process.

### Docker identity, lifecycle, and Stop

Use the selected local Docker context and discover containers through structured CLI output/inspection. Save stable Compose project/service identifiers where present, plus the last container identity for diagnostics. With multiple matching replicas, require an explicit selection; do not choose the first match. A saved name alone must not silently reconnect to an unrelated replacement. Snapshot and recheck the resolved container ID when starting the run.

Probe the selected PHP executable, working directory, writable temporary directory, execution user, and available termination mechanism. Create a unique Runlet-owned directory per run. Copy or stream only the runner's required assets; do not depend on the host checkout being mounted. Execute with argument arrays, without a TTY, and preserve the container's application environment. Account for Docker's user, working-directory, and stdin options in the adapter.

Local cancellation must signal the tracked runner/process group where supported. Docker cancellation must signal the tracked runner **inside the same container** using a separate control operation. Record a per-run identifier as well as its PID to avoid killing a reused or unrelated PID. Begin with graceful termination, allow approximately 1.5 seconds, then force termination if supported; aim to regain control within 5 seconds. Confirm the PHP process ended before displaying a successful stop. If a container disappears or cannot be controlled, display the actual outcome.

Do not use `docker stop`, blanket `pkill php`, or container-wide process termination. Child processes explicitly spawned by a snippet need documented cancellation behavior; killing the runner alone does not establish that every descendant stopped. Prove the supported strategy on a minimal container and a non-root container, without assuming `pcntl`, `posix`, `ps`, or `kill` binaries are always available. An unsupported capability must be reported rather than silently ignored.

Clean only Runlet-owned files after completion/stop. Track abandoned run directories and remove them on later reconnection when ownership is verifiable. On quit, stop managed active runs and LSP processes; restart restores editing state without rerunning code. Code is executed with the target application's permissions and may alter its data; cancellation does not roll back application changes.

### PHPantom prototype gate

Before committing to the editor bridge, prove the following against the **pinned release binary**, not only upstream documentation:

1. A tagless unsaved scratch document obtains project class/member completion while using the real workspace root. Prefer an in-memory file URI under that root with no disk write, if supported; otherwise prove an app-owned temporary-document mapping works.
2. Diagnostic positions and completion edits, including additional import edits, map correctly across synthetic opening tags and Unicode text. Keep source files read-only for the MVP's scratch workflow.
3. A project with a different PHP target, existing `.phpantom.toml`, and vendor files resolves correctly without altering repository/global configuration.
4. The app can suppress automatic external analyzer/formatter execution through a supported configuration mechanism. If the pinned release cannot do this without repository changes, implement a narrow, documented adapter/upstream change or select a suitable PHPantom release; do not claim Docker-only language intelligence is complete with the issue unresolved.
5. Two workspaces do not share suggestions incorrectly, and a stopped/crashed server can restart without losing tab text or preventing execution.

Record actual supported LSP capabilities and the tested Laravel cases in `docs/compatibility.md`. Provide a visible degraded state for missing local dependencies. Advanced refactoring and external analysis remain later scope even when the server advertises them.

### Persistence and interface behavior

Use a versioned app-owned JSON store initially, with atomic replacement, a recoverable last-good copy, and bounded history. Separate snippets/profiles/settings from frequently saved session buffers. Debounce session writes by roughly 500 ms and flush on orderly quit. Preserve a corrupt file for diagnosis and recover valid data where possible rather than overwriting it silently. No database server is required.

Persist stable profile IDs and revisions, tab text and cursor/selection, local project paths, language-service preferences, and snippet metadata. History stores code, target label/ID, timestamp, and final status; begin with the latest 1,000 entries and a clear-history action. Result payload persistence is optional and should not block the MVP.

The main window needs a visible target selector, tab bar, PHP editor, Run/Run Selection/Stop controls, and resizable result pane. Target details and onboarding cover local directory/PHP selection and Docker container/directory/user/tmp/source mapping. Settings and searchable history/snippets can be compact dialogs or side panels. Use Cmd+R for Run, an explicit Run Selection action, and a visible Stop shortcut/action; show configured bindings in the interface.

Editing, saving, opening files, restoring history, switching profiles, and reconnecting containers must never execute code automatically. If a profile becomes unavailable, keep the code and show the target-resolution failure. Replacing the target must be an explicit action.

### Milestones and evidence required

| Milestone                         | Deliverable                                                                                                              | Exit evidence                                                                                                                                                                                              |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0. Repository and risk prototypes | Xcode application, Swift package boundaries, provisional PHP/Laravel matrix, native-editor/runner/LSP/Docker prototypes. | Native text/undo/input behavior, actual completion/diagnostics, real final-expression/dump/error behavior, valid scratch LSP mapping/configuration, and proven Docker Stop; record unresolved constraints. |
| 1. Local vertical slice           | A usable editor runs plain PHP, Composer, and Laravel snippets and inspects results.                                     | Fixture-based launch/bootstrap/AST/output/error tests; a rendered app demonstration with corrected-error recovery.                                                                                         |
| 2. Default sandbox                | Pinned Laravel with writable per-user SQLite/cache/mail defaults, using local PHP or Docker fallback.                    | First launch without a project; no-host-PHP execution and local sandbox sources for PHPantom; actual displayed versions.                                                                                   |
| 3. Existing Docker applications   | Discovery, saved profiles, user/tmp/source mappings, recreation, and cancellation.                                       | Disposable Compose/non-root/read-only fixtures; process-level evidence that Stop leaves the application container running.                                                                                 |
| 4. Daily workflow                 | PHPantom editor intelligence, tabs, profiles, session restoration, history, snippets, preferences, files.                | Isolation/Unicode/stale-response tests plus restart/save/reopen UI evidence.                                                                                                                               |
| 5. Installable MVP                | Packaged macOS app for supported architectures with resources and notices.                                               | All acceptance scenarios traced to evidence or an explicit blocker; packaged launch, resource resolution, PHPantom startup, and Docker-only checks.                                                        |

Build tests where they protect these contracts: parser/source mapping, protocol robustness, value bounds/references, profile resolution, process cancellation, persistence recovery, and LSP mappings. Use disposable fixtures for integration tests; do not use the user's application databases as destructive test fixtures. Keep tests focused on behavior rather than duplicating UI implementation.

Provide repeatable commands for development, focused tests, integration fixtures, and packaging in the repository README. Maintain a requirement-to-evidence table for M01–M22. Report native and Docker measurements separately; distinguish CLI proof, rendered desktop behavior, and packaged-app proof. A screenshot of a mock result is not evidence that PHP execution works.

The supported PHP/Laravel range, minimum macOS version, selected dependency versions, and signing/notarization availability are still decisions to record during setup. Missing signing credentials may limit distribution polish, but must not prevent producing a locally installable test build. The repository location remains the only user-specific setup input; an existing repository's instructions and conventions take precedence over the suggested layout.

### Historical implementation prompt

Retained for provenance. It is superseded by the current issue-first policy and delivered-feature record; do not execute it as a fresh backlog.

> Implement Runlet as a native macOS application using Swift, SwiftUI, AppKit, Xcode, and Swift Package Manager. Read the MVP requirements and implementation handoff first; treat the Tinkerwell inventory and nice-to-haves as reference/backlog. Preserve the three MVP targets: bundled Laravel sandbox, native local projects, and existing Docker applications. Use PHPantom LSP and the documented native implementation defaults. Begin with milestone 0 and prove native editor/undo/input behavior, runner/result transport, Docker cancellation, and unsaved PHPantom document/configuration behavior before building the full UI. Implement in the milestone order, keep requirement-to-evidence records, and validate with disposable fixtures and the real packaged desktop app. Record compatibility choices and demonstrated limitations. Do not expand into Vapor/Cloud/Forge, AI/MCP, remote targets, advanced inspectors, or a Windows UI. Continue through the installable MVP and report incomplete requirements explicitly rather than substituting mocks.

## Post-MVP ideas: issue-backed disposition

The former nice-to-haves mixed implemented behavior with proposals. Delivered features moved to [done-next-release-ideas.md](docs/done-next-release-ideas.md). All remaining actionable proposals are indexed in [next-release-ideas.md](docs/next-release-ideas.md), including the following plan-specific scope:

- PHPantom navigation: definition, references, inlay hints, code actions: [#22](https://github.com/filipac/runlet/issues/22).
- Format snippet: [#36](https://github.com/filipac/runlet/issues/36).
- Editor polish: [#37](https://github.com/filipac/runlet/issues/37).
- Sail, DDEV, and Lando presets; Herd isolation: [#17](https://github.com/filipac/runlet/issues/17).
- App info panels: [#19](https://github.com/filipac/runlet/issues/19).
- Global drivers, Testbench, and a driver gallery: [#18](https://github.com/filipac/runlet/issues/18).
- Parameterised snippets: [#14](https://github.com/filipac/runlet/issues/14).
- Benchmark and profile: [#41](https://github.com/filipac/runlet/issues/41).
- Developer ID signing, notarization, auto-update, diagnostics: [#24](https://github.com/filipac/runlet/issues/24).
- Follow PHPantom fixes for Laravel inference gaps: [#117](https://github.com/filipac/runlet/issues/117) (the rest of [#55](https://github.com/filipac/runlet/issues/55) is done).
- Optional external analysis routed through the selected runtime: [#56](https://github.com/filipac/runlet/issues/56).
- Optional dependency mirroring for Docker-only completion sources: [#57](https://github.com/filipac/runlet/issues/57).
- Target groups and pinned or favorite projects: [#58](https://github.com/filipac/runlet/issues/58).
- Optional sandbox versions, services, and disposable fixture data: [#59](https://github.com/filipac/runlet/issues/59).
- Optional output auto-hide and Escape behavior: [#60](https://github.com/filipac/runlet/issues/60).

Vapor/Cloud, Windows/Linux/WSL, object graph UI, dedicated IDE plugins, Vim and licensing/account infrastructure remain reference or rejected scope unless explicitly requested. Forge/Ploi and Kubernetes have deferred ideas in the active index, not release commitments. Monaco theme files are skipped in favor of built-in syntax themes.

## MVP completion boundary

The MVP is complete when the user can reliably work in the **sandbox, native local projects, and multiple existing Docker applications**, run and stop snippets, inspect output and errors, use PHPantom completion/hover/signature help/live diagnostics with the available local source, and recover tabs/history/snippets after restart. Docker-backed execution and core language intelligence must both work without host PHP.

Advanced inspectors, AI, remote/cloud integrations, and broad framework parity should not delay that release.
