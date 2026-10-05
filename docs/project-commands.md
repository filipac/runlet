# Project Commands

The Commands panel lists what you can run in the tab's project, such as Artisan or `bin/console` commands and Composer scripts, and runs each one in a terminal tab below the editor, on the tab's target. It also opens the project's REPL and runs its tests. A project driver can add commands of its own.

## The Commands Panel

Choose **Library ▸ Show Project Commands** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>K</kbd>), or pick **Commands** in the History & Snippets panel. The list is grouped and searchable, and has three sources:

- **The framework's commands:** every visible Artisan command in Laravel and Lumen, a Laravel Zero application's commands (through its own binary), and every visible `bin/console` command in Symfony. WordPress, Composer, and plain PHP projects have none.
- **Composer scripts** from the project's `composer.json`, as `composer run-script <name>`, in the "Composer scripts" group. Composer's own event hooks (`post-autoload-dump`, `pre-install-cmd`, and the like) are skipped, and a `scripts-descriptions` entry becomes the description. They're listed even when the application can't boot.
- **A project driver's commands,** and its **host commands**, which run on your Mac. See [Adding Commands](#adding-commands).

Click a command's Run button to run it in a terminal tab. Its context menu also has **Copy Command** and **Copy Name**. A command that needs arguments, such as `make:model`, is typed into the terminal without pressing Return, so you can add them.

Above the list, the driver's snippet variables (such as `$app`) are shown: click one to insert it at the caret.

<!-- screenshot: the Commands panel for a Laravel project: grouped Artisan commands, the Composer scripts group, Open REPL, and the Tests group -->

### When Commands Are Listed

Listing commands boots the application in a fresh PHP process, like a run, but runs no snippet. So Runlet lists them only while the Commands panel is open: once per target, when the panel opens, or when you switch to a tab or target it hasn't listed yet. **Refresh** lists them again. A target whose listing failed isn't tried again until you press **Try Again** or **Refresh**.

- **SSH hosts** are listed only when you click **List Commands on `<host>`**, since listing boots the application on the server.
- **Production targets** are never listed by themselves. Listing, and every command (host commands too), asks first: <kbd>⌘</kbd><kbd>Return</kbd> confirms.

## Where Commands Run

| Target | How a command runs |
| --- | --- |
| Local project, sandbox | In your login shell, in the project's folder. A leading `php` becomes the target's PHP, so Artisan runs on the same PHP as your snippets. |
| Docker profile | Inside the profile's container, in its working directory and as its user. Runlet finds the container again when you press Run, and asks you to choose when it's ambiguous or was recreated. |
| Laravel Sandbox in Docker | In a disposable container with the sandbox mounted, as for sandbox runs. |
| SSH host | On the server, in the profile's directory, with the profile's PHP and your login shell's `PATH`, or inside the container of a profile's container step. A command that needs input opens a shell with the command typed. See [SSH](ssh.md#commands-shells-and-repls). |

Host commands always run on your Mac. The terminal tab stays open when a command ends, so you can read its output.

## Open REPL

**Open REPL**, in the panel (also **Library ▸ Open REPL** and the command palette), opens the target's own interactive REPL in a terminal tab, so state carries over from line to line. It doesn't need the command list, so it never boots the application by itself, and nothing starts until you click. Runlet picks the REPL from the project's files:

1. **Tinker** (`php artisan tinker`), when `artisan` and `vendor/laravel/tinker/` exist: the sandbox, and Laravel applications with laravel/tinker;
2. **PsySH** (`php vendor/bin/psysh`), when the project has it, whatever the framework;
3. **PHP's interactive shell** (`php -a`) otherwise.

On Docker and SSH targets, the same choice happens inside the container or on the server, with the profile's PHP. Production targets ask every time.

> [!NOTE]
> A driver can't change the REPL yet: the choice has to work before the application boots. To offer another console, add it to `commands()` or `hostCommands()`.

## Tests

Under Open REPL, the **Tests** group runs the project's test suite in a terminal tab:

- **Run All** runs every test.
- **File…** runs one test file. On your Mac, it opens a file picker in the project's first test folder; on Docker and SSH targets, it takes a path relative to the profile's directory.
- **Filter…** runs the tests matching a name or pattern (`--filter`).

Like Open REPL, it doesn't need the command list, and nothing runs until you click. Runlet picks the runner from the project's files, in this order:

1. **`php artisan test`**, when the project has `artisan`, Laravel's Collision package (which provides the command), and Pest or PHPUnit, with a `phpunit.xml` or `phpunit.xml.dist`. It starts Pest when Pest is installed, else PHPUnit, as Laravel's own `composer test` does.
2. **Pest** (`php vendor/bin/pest`), which also runs plain PHPUnit test classes.
3. **PHPUnit** (`php vendor/bin/phpunit`).

The runner needs a PHPUnit configuration in the project's folder (`phpunit.xml`, `phpunit.dist.xml`, or `phpunit.xml.dist`), and at least one of its test suites' folders or files. A project without tests has no Tests group: the bundled sandbox ships without tests, so it has none. On Docker and SSH targets, the tab explains when the project has no runner, for example a deploy installed without dev dependencies.

> [!WARNING]
> **Tests are disabled on production targets,** with the reason in the group: test suites often reset or migrate the database (`RefreshDatabase`, `migrate:fresh`), and the test database isn't always a separate one.

## Adding Commands

A [project driver](drivers.md) adds commands with `commands()`. Return entries keyed by name: `command` is a shell command line that runs in the project's folder (inside the container for Docker targets), and `description` and `group` are optional. A string is short for `['command' => …]`.

```php
<?php
// .runlet/AcmeApiDriver.php
class AcmeApiDriver extends \Runlet\Driver
{
    // canBootstrap(), bootstrap(), variables() as in Writing a Project Driver.

    public function commands(): array
    {
        return [
            'acme:routes' => [
                'command' => 'php bin/acme routes',
                'description' => 'List the routes of ' . DI::get(App::class)->name(),
                'group' => 'acme',
            ],
            'health' => 'php bin/acme health',
        ];
    }
}
```

`commands()` runs after `bootstrap()`, so it can use the booted application. To add to a built-in driver's commands, merge with the parent's:

```php
<?php
// .runlet/OpsDriver.php
class OpsDriver extends \Runlet\Drivers\LaravelDriver
{
    public function commands(): array
    {
        return parent::commands() + [
            'deploy' => ['command' => './vendor/bin/envoy run deploy', 'description' => 'Deploy to production', 'group' => 'ops'],
            'horizon:pause' => 'php artisan horizon:pause',
        ];
    }
}
```

- Set `'needsInput' => true` on a command that needs arguments: Run types it into the terminal without pressing Return.
- A driver for another Symfony Console application can reuse Runlet's formatting: `$this->consoleCommands($application->all(), 'php bin/tool')` skips aliases and hidden commands, sets `needsInput` for commands with a required argument, and groups each command by its namespace (`make:model` in "make"; `migrate` joins "migrate" when `migrate:*` commands exist).
- A list of entries that each have a `name` works too. Entries without a name or a command line are skipped, with a notice; only the first entry with a given name is kept; descriptions longer than 500 bytes are shortened.

If `commands()` throws or calls `exit()`, the panel shows the error, naming the driver file and method (`… failed in commands(): …`), with the Composer scripts. A boot error shows the same way.

## Host Commands

`hostCommands()` declares commands that run **on your Mac**, in the project's folder there, instead of on the target. For a local project, that's the project's folder; for a Docker or SSH profile, its local source or local folder. Use it for tools installed on your Mac: `docker compose`, deploy scripts, or your team's own CLI.

```php
public function hostCommands(): array
{
    return [
        // A static command, as in commands().
        'up' => ['command' => 'docker compose up -d', 'description' => 'Start the stack'],

        // A tool that prints its own command list as JSON for the folder it runs in.
        'biker' => ['list' => 'biker runlet:commands'],

        // A Symfony Console app (Laravel Zero, …): Runlet reads `mytool list --format=json`
        // and runs each command as `mytool <name>`.
        'mytool' => ['console' => 'mytool'],
    ];
}
```

- **Listing.** A `list` or `console` source runs each time the panel loads or refreshes, with `/bin/sh -c`, in the project's folder on your Mac, with your login shell's environment, so tools in `~/.bin`, Homebrew, or Herd are found.
- **The `list` format.** The command prints `{"commands": [{"name": …, "command": …, "description"?: …, "group"?: …, "needsInput"?: true}]}`. Output around the JSON object is ignored, and console style tags (`<fg=gray>…</>`) are removed from descriptions. Commands keep the tool's order, grouped by `group`, or under the source's name.
- **The `console` format.** Hidden commands, `list`, `help`, `completion`, and `_complete` are skipped. A command with a required argument gets `needsInput`.
- **Running one** opens a terminal tab with your shell, in the project's folder on your Mac. Runlet never looks for a container for a host command, so `biker start` works even while the container is stopped.
- **When the app can't boot.** `hostCommands()` is called before `bootstrap()`, so it must only return declarations. Host commands stay listed when the application can't boot, and when the target can't start at all (a stopped container), Runlet uses the last declaration it saw for that target.

A failing source shows its error above the list, for example `biker: "biker runlet:commands" exited with code 127: … command not found`. The other commands are still listed.

## For developers

**Runner protocol.** A request with `"mode": "commands"` boots the project exactly like a run (`started`, then `bootstrapped` or a boot `error`) and ignores `code`. The runner emits two `commands` events, then `runnerFinished`:

```json
{"origin": "composer", "source": "Composer", "commands": [{"name": "test", "command": "composer run-script test", "description": "Run the test suite", "group": "composer"}]}
{"origin": "driver", "source": "Laravel", "framework": "laravel", "commands": [{"name": "migrate:status", "command": "php artisan migrate:status", "description": "Show the status of each migration", "group": "migrate"}]}
```

The Composer event comes first, before any project code runs. The driver event is missing when the boot or `commands()` fails. A project driver's event also carries `driverFile`. Entries may carry `"needsInput": true`.

Between them, right after the driver is chosen and before `bootstrap()`, the runner emits one `hostCommands` event with the driver's `hostCommands()` (both lists empty when it declares none):

```json
{"commands": [{"name": "up", "command": "docker compose up -d", "description": "Start the stack", "group": null}], "sources": [{"name": "biker", "format": "runlet", "list": "biker runlet:commands", "console": null, "description": null}]}
```

A `console` source arrives as `"format": "symfony"`, with `list` set to `<console> list --format=json`. If `hostCommands()` throws, the event is replaced by a notice. Right after it comes one `logPaths` event ([Log Paths](drivers.md#log-paths)).

- Composer scripts are read from `composer.json` in the working directory before any project code runs. Your login shell's environment for host commands is resolved once per launch with `$SHELL -i -l -c env`. Host command declarations are saved in `State/facts.json`.
- Docker commands run as `docker exec -it [--user …] [--env TMPDIR=…] -w <working directory> <container> sh -lc '<command>'`; the sandbox in Docker uses a disposable `docker run --rm -it` container. SSH commands are described in [SSH ▸ For developers](ssh.md#for-developers).
- **Open REPL** (`ProjectREPL`): for local projects and the sandbox, Runlet checks the folder on your Mac and types the command into your shell with the target's PHP (`'<php>' artisan tinker`); Docker and SSH targets choose in the `sh -lc` that starts the REPL. The runner has no REPL hook.
- **Tests** (`ProjectTests`, [#40](https://github.com/filipac/runlet/issues/40)): Collision passes only `phpunit.xml` or `phpunit.xml.dist` to the runner, so a Laravel project with only `phpunit.dist.xml` runs Pest or PHPUnit directly. For local projects and the sandbox, Runlet checks the runner, the configuration, and at least one `<testsuite>` folder or file on your Mac, and types the runner's command line into your shell (`'<php>' artisan test --filter=checkout`). A file or filter reaches the runner as one argument: a file as given (with `./` in front when it starts with `-`), a filter as `--filter=<text>`, quoted for the shell. `ProjectTests.isAllowed(on:)` disables the group on production.
- The panel is `ProjectCommandsView`; the listing and running are in `AppModel+Commands.swift`, the Tests group in `AppModel+Tests.swift`. This page was split out of `drivers.md` under [#289](https://github.com/filipac/runlet/issues/289).
