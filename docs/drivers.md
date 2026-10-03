# Framework drivers

A driver boots an application before a snippet runs and decides which variables the snippet
starts with. Runlet picks one driver per run, in a fresh PHP process:

1. **Project drivers** in `<project>/.runlet/*Driver.php`, if any can boot the project.
2. **Built-in drivers**, in this order. The first that recognises the project wins.

| Order | Driver | Recognised by | Reported `framework` | Snippet variables |
| --- | --- | --- | --- | --- |
| 1 | `Runlet\Drivers\LaravelDriver` | `bootstrap/app.php`, plus `artisan` or the `laravel-zero/framework` package | `laravel`, `lumen`, or `laravel-zero` | `$app` |
| 2 | `Runlet\Drivers\WordPressDriver` | `wp-load.php` in the project, `web/wp/` (Bedrock), `public/wp/`, `wordpress/`, or `wp/` | `wordpress` | `$wpdb` |
| 3 | `Runlet\Drivers\SymfonyDriver` | `bin/console`, plus `src/Kernel.php` or `config/bundles.php` | `symfony` | `$kernel`, `$container` |
| 4 | `Runlet\Drivers\ComposerDriver` | `composer.json` or `vendor/autoload.php` | `composer` | none |
| 5 | `Runlet\Drivers\PlainDriver` | anything else | `plain` | none |

The source is `Resources/Runner/src/Drivers.php`, and the [run inspector](#run-inspector)
is in `Resources/Runner/src/Inspector.php`. The runner declares these classes before any
project code loads. Every driver works on PHP 7.4 and later.

## Writing a project driver

Put a class that extends `Runlet\Driver`, or one of the built-in drivers, in a file named
`<Something>Driver.php` inside the project's `.runlet/` folder. Runlet reads the folder
straight from disk, so it still works if `.runlet/` is git-ignored, for example globally.
Inside Docker, the folder must be in the container's working directory (usually through
the project mount). On an SSH host, it must be in the server's directory (committed or
deployed): the runner reads `.runlet/` on the server, and a folder that exists only on your
Mac is not sent.

```php
<?php
// .runlet/AcmeApiDriver.php
use Acme\App;
use Acme\DI;

class AcmeApiDriver extends \Runlet\Driver
{
    public function canBootstrap(string $projectPath): bool
    {
        return is_file($projectPath . '/config/bootstrap.php');
    }

    public function bootstrap(string $projectPath): void
    {
        require __DIR__ . '/boot.php';
    }

    public function variables(): array
    {
        return ['_app' => DI::get(App::class)];
    }

    public function version(): ?string
    {
        return 'Acme Lease API';
    }
}
```

```php
<?php
// .runlet/boot.php: use paths relative to this file, not /var/www, so the same driver
// works on the host and inside the container.
define('BASE_PATH', dirname(__DIR__));
putenv('APP_NAME=Acme Lease API');
$app = require BASE_PATH . '/config/bootstrap.php';
```

`Tests/Fixtures/custom-driver/` contains this example as a working fixture.

### API

| Method | Default | Purpose |
| --- | --- | --- |
| `name(): string` | Short class name | Label shown in Runlet (`bootstrapped.driverName`). |
| `canBootstrap(string $projectPath): bool` | `true` | Whether this driver handles the project. `$projectPath` is the run's working directory. |
| `bootstrap(string $projectPath): void` | Abstract | Boots the application. To report a bootstrap error, throw an exception. |
| `variables(): array` | `[]` | `name => value` pairs that become `$name` in every snippet. Called after `bootstrap()`. |
| `version(): ?string` | `null` | Version label (`bootstrapped.frameworkVersion`). |
| `commands(): array` | `[]` | Commands listed in Runlet's Commands panel. Called after `bootstrap()`, only when the panel lists commands. See [Project commands](#project-commands). |
| `inspect(Inspector $inspector): void` | Detects Eloquent and WordPress | Reports queries, mail, logs, and your own sections for the [run inspector](#run-inspector). Called after `bootstrap()`, before the snippet; never when commands are listed. |
| `preview($value): ?array` | Laravel mail, views, HTML responses | Rendered HTML for a returned or dumped object. See [Previews](#previews). |
| `hostCommands(): array` | `[]` | Commands that run on the Mac in the project's folder. Called before `bootstrap()`. See [Host commands](#host-commands). |
| `sqlConnection(?string $connection)` | `null` (built-in drivers: the framework's connection) | How an [SQL tab](sql-tabs.md) reaches the database: a `\PDO`, a callable, or `null`. Called after `bootstrap()`, only when an SQL tab runs. See [SQL connections](#sql-connections). |
| `sqlConnections(): array` | `[]` (built-in drivers: the configured names) | Connection names for an SQL tab's picker, the default first. See [SQL connections](#sql-connections). |

Helpers for subclasses:

- `consoleCommands(iterable $commands, string $commandPrefix): array` formats Symfony Console commands for `commands()`.
- `inspectEloquent()`, `inspectDoctrine()`, `inspectWordPress()`, and `inspectAutomatically()` record queries for the [run inspector](#run-inspector).
- `log(string $message, ?string $detail = null): void` adds a line to the app's Run Log (Run ▸ Show Run Log), for example a boot step or a timing.
- Override `bootstrapExitHint(): ?string` to explain an `exit()` during `bootstrap()`. The text is appended to Runlet's "called exit() while bootstrapping" error, before the name of the last file loaded. The WordPress driver reports the redirect WordPress tried and who sent it.
- `gitRevision(string $projectPath): ?string` returns `"main @ 3f2a1c9"` for the checkout at `$projectPath`. It reads `.git` directly: loose and packed refs, a detached HEAD (short commit only), and linked worktrees. It runs no `git` command, and returns `null` when there is no readable checkout. A good `version()` for application drivers:

  ```php
  public function version(): ?string
  {
      return $this->gitRevision(dirname(__DIR__)); // the project root, from .runlet/
  }
  ```

  Inside Docker, it needs the `.git` directory to be mounted into the container. A linked worktree whose `.git` file points at a host path can't be read there.

Child methods must keep these signatures, including the return types. PHP rejects an
incompatible declaration with a fatal error, and Runlet reports it as a bootstrap error
that names the driver file.

### Discovery rules

- Runlet loads `vendor/autoload.php` first, if it exists. A driver can then use project
  classes without loading Composer itself. If the application's own bootstrap requires the
  autoloader again, nothing breaks: Composer returns the loader that is already registered.
- Driver files load in name order. Each concrete `Runlet\Driver` subclass declared in a
  `.runlet/` file is a candidate, in the order it was declared. The first candidate whose
  `canBootstrap()` returns `true` boots the project. If none do, built-in detection
  continues as usual.
- Runlet ignores abstract classes and files that do not end in `Driver.php`. A driver can
  extend another driver from `.runlet/` that sorts later, because Runlet resolves the
  parent class from `.runlet/<ClassName>.php`.
- Only files directly in `.runlet/` are drivers. Subfolders are never scanned, so
  `.runlet/snippets/` can hold [project snippets](project-snippets.md) without any of them
  being loaded or run.
- The reported framework is `custom:<ClassName>`. `started.framework` is `custom` while
  project drivers are still pending. `bootstrapped` reports the driver that actually ran.
- Runlet does not load driver files when the run asks for a specific built-in driver
  (see [Choosing a driver explicitly](#choosing-a-driver-explicitly)).

### Errors

Runlet reports errors raised by a project driver at the `bootstrap` stage. The error
names the file, the class, and the method, for example
`Runlet driver AcmeApiDriver (.runlet/AcmeApiDriver.php) failed in bootstrap(): …`. The
error payload also carries `driverFile` and `driverClass`. These cases are covered:

- syntax errors and incompatible signatures (fatal);
- exceptions from any driver method;
- `exit()` during bootstrap.

### Extending a built-in driver

The built-in drivers are ordinary classes, so you can extend them and call `parent::`:

```php
<?php
// .runlet/TenantDriver.php
use App\Services\PriceFormatter;
use Runlet\Drivers\LaravelDriver;

class TenantDriver extends LaravelDriver
{
    public function name(): string
    {
        return 'Tenant Laravel';
    }

    public function bootstrap(string $projectPath): void
    {
        parent::bootstrap($projectPath);
        config(['app.tenant' => 'acme']);
    }

    public function variables(): array
    {
        return parent::variables() + [
            'tenant' => config('app.tenant'),
            'formatter' => $this->app->make(PriceFormatter::class),
        ];
    }
}
```

The built-in drivers expose these members to subclasses:

| Driver | Members |
| --- | --- |
| `Driver` (all drivers) | `consoleCommands($commands, $commandPrefix)` turns Symfony Console commands into `commands()` entries; `inspectEloquent()`, `inspectDoctrine()`, `inspectWordPress()`, and `inspectAutomatically()` for the [run inspector](#run-inspector); `sqlConnection()` and `sqlConnections()` for [SQL tabs](#sql-connections) |
| `LaravelDriver` | `$this->app` (protected); `flavor($projectPath)` returns `laravel`, `lumen`, or `laravel-zero`; overridable `consoleScript($projectPath)`, `inspectLaravelMail()`, and `inspectLaravelLog()` |
| `SymfonyDriver` | `$this->kernel`; overridable `loadEnvironment()` and `kernelClass()` |
| `WordPressDriver` | Overridable `locateLoader()` and `prepareRequest()` |
| `ComposerDriver` | `requireAutoloader($projectPath)` |

## Variables and reporting

Runlet imports driver variables into the snippet's scope before the snippet runs. A snippet
can reassign them, but that does not affect the driver. Runlet skips names that cannot be
PHP variables, as well as `this`, `GLOBALS`, and names starting with `__runlet`, and emits a
notice listing what it skipped.

The `bootstrapped` event reports the following fields. All of them are optional, so older
readers can ignore them.

```json
{
  "framework": "custom:AcmeApiDriver",
  "frameworkVersion": "Acme Lease API",
  "driverName": "AcmeApiDriver",
  "driverFile": ".runlet/AcmeApiDriver.php",
  "variables": { "_app": "Acme\\App" },
  "bootstrapMs": 3
}
```

`variables` maps each name to its class, or to a type (`int`, `float`, `bool`, `string`,
`array`, `null`, `resource`). It is always a JSON object, even when empty, so editor
completion can use it.

## Project commands

The Commands panel lists the commands the active tab's target offers, grouped and
searchable, and opens each one in a terminal with its Run button. The list has three sources:

- **The driver's `commands()`.** `LaravelDriver` lists every visible Artisan command (Lumen
  too, and Laravel Zero with its own binary from composer.json `bin`). `SymfonyDriver` lists
  every visible `bin/console` command of the booted kernel. `WordPressDriver`,
  `ComposerDriver`, and `PlainDriver` list none.
- **Composer scripts** from `composer.json` in the working directory, as
  `composer run-script <name>`, in the "Composer scripts" group. Composer's own event hooks
  (`post-autoload-dump`, `pre-install-cmd`, and the like) are skipped. A
  `scripts-descriptions` entry becomes the description. Runlet reads the file before any
  project code runs, so scripts are listed even when the application cannot boot.
- **The driver's `hostCommands()`**: commands that run on your Mac in the project's folder,
  including for Docker targets. See [Host commands](#host-commands).

Listing commands boots the application in a fresh PHP process, like a run (so it works
the same inside Docker), but runs no snippet. Runlet does it only while the Commands panel
is visible, once for each target it has not listed yet: when the panel opens, or when you
switch to a tab or target that hasn't been listed. Refresh lists the commands again. A
target whose listing failed is not retried until you press Try Again or Refresh. While the
panel is hidden, Runlet never lists commands. SSH hosts and targets marked as production
are never listed by themselves; on production, listing and every command (host commands
included) ask for confirmation first (⌘↩ confirms).

### Adding commands

Return entries keyed by command name. `command` is a shell command line that runs in the
project directory (inside the container for Docker targets, through `sh -lc`).
`description` and `group` are optional. A string value is shorthand for `['command' => …]`.

```php
<?php
// .runlet/AcmeApiDriver.php
class AcmeApiDriver extends \Runlet\Driver
{
    // canBootstrap(), bootstrap(), variables() as above.

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

`commands()` runs after `bootstrap()`, so it can use the booted application. To add to a
built-in driver's list, merge with the parent's entries:

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

A driver for another Symfony Console application can reuse the built-in formatting:
`$this->consoleCommands($application->all(), 'php bin/tool')` skips aliases and hidden
commands, and groups each command by its namespace (`make:model` in "make"; `migrate`
joins "migrate" when `migrate:*` commands exist).

Runlet also accepts a list of entries that each have a `name`. It skips entries without a
name or a command line, and reports them in a notice. Only the first entry with a given
name is kept. Descriptions longer than 500 bytes are shortened.

Set `'needsInput' => true` on a command that requires arguments. Run then types the command
into the terminal without pressing Return, so you can add the arguments. `consoleCommands()`
sets it for every console command with a required argument (`make:model`, for example).

### Host commands

`hostCommands()` declares commands that run **on your Mac**, in the project's folder there,
instead of inside the target. For a local project, that folder is the project directory.
For a Docker or SSH profile, it is the profile's local folder, set in Settings ▸ Targets.
Use it for tools installed on the host: `docker compose`, deploy scripts, or your team's
own CLI. Each entry is one of these:

```php
public function hostCommands(): array
{
    return [
        // A static command, same shape as in commands().
        'up' => ['command' => 'docker compose up -d', 'description' => 'Start the stack'],

        // A tool that prints its own command list as JSON for the folder it runs in.
        'biker' => ['list' => 'biker runlet:commands'],

        // A Symfony Console app (Laravel Zero, …): Runlet reads `mytool list --format=json`
        // and runs each command as `mytool <name>`.
        'mytool' => ['console' => 'mytool'],
    ];
}
```

How host commands are listed and run:

- **When they are listed.** A `list` or `console` source is run each time the Commands
  panel loads or refreshes. It runs with `/bin/sh -c`, in the project folder on your Mac,
  with your login shell's environment: Runlet resolves your PATH and other variables once
  per launch by running `$SHELL -i -l -c env`, so tools in `~/.bin`, Homebrew, or Herd are
  found.
- **The `list` format.** The command must print `{"commands": [{"name": …, "command": …,
  "description"?: …, "group"?: …, "needsInput"?: true}]}`. Output before and after the JSON
  object is ignored, and console style tags (`<fg=gray>…</>`) are removed from descriptions.
  Commands appear in the order the tool lists them, grouped by `group`, or under the
  source's name when there is no `group`.
- **The `console` format.** Hidden commands, `list`, `help`, `completion`, and `_complete`
  are skipped. A command with a required argument gets `needsInput`.
- **Running one.** Run opens a terminal tab with your shell, in the project folder on your
  Mac, and runs the command line there. Runlet never resolves a container for a host
  command, so `biker start` works even while the container is stopped.
- **When the app can't boot.** `hostCommands()` is called **before** `bootstrap()`, so it
  must only return declarations. Host commands stay listed when the application can't
  boot. When the target can't start at all (for example, a stopped container), Runlet uses
  the last declaration it saw for that target. Declarations are saved in
  `State/facts.json`.

A failing source shows its error above the list (for example, `biker: "biker
runlet:commands" exited with code 127: … command not found`). The other commands are still
listed.

### Errors

If `commands()` throws or calls `exit()`, the panel shows the error, which names the
driver file and method (`… failed in commands(): …`), together with the Composer scripts.
A bootstrap error is shown the same way.

### Running a command

The Run button opens a terminal tab:

- **Local projects and the sandbox:** the command line runs in your login shell in the
  project directory. A leading `php` becomes the target's configured PHP binary, so Artisan
  runs on the same PHP as your snippets.
- **Docker profiles:** `docker exec -it [--user …] [--env TMPDIR=…] -w <working directory>
  <container> sh -lc '<command>'`, in the profile's resolved container. Runlet resolves the
  container again when you press Run, and asks you to choose when the container is
  ambiguous or was recreated. It never switches containers on its own.
- **Docker sandbox:** a disposable `docker run --rm -it` container with the sandbox
  mounted, as for sandbox runs.
- **SSH hosts:** listing boots the application on the server and happens only when you ask.
  Project commands run on the server in an SSH terminal tab, using the profile's PHP and
  login-shell PATH. With a container step they run inside that container. Commands needing
  input open a shell with the command typed. Production confirms every listing, command,
  and shell; host commands run on your Mac in the profile's local folder. See [ssh.md](ssh.md).

### Open REPL

The panel's **Open REPL** button (also Library ▸ Open REPL and the command palette) opens the
target's own interactive REPL in a terminal tab, so state carries over between lines. It
doesn't need the command list, so it never boots the application by itself, and nothing
starts until you click it. Runlet picks the REPL from the project's files, not from the
driver:

1. **Tinker**, `php artisan tinker`, when `artisan` and `vendor/laravel/tinker/` exist (the
   sandbox and Laravel applications with laravel/tinker);
2. **PsySH**, `php vendor/bin/psysh`, when the project has it (any framework);
3. **PHP's interactive shell**, `php -a`, otherwise.

For local projects and the sandbox, Runlet checks the folder on your Mac and types the
command into your shell with the target's PHP (`'<php>' artisan tinker`). Docker profiles and
SSH hosts make the same choice inside the container or on the server, in the `sh -lc` that
starts the REPL, with the profile's PHP. Production targets ask every time. A driver can't
change the REPL yet: the runner has no hook for it, and the choice must work before the
application boots. To use another console, add it to `commands()` or `hostCommands()`.

### Tests

Under Open REPL, the panel's **Tests** group runs the project's test suite in a terminal tab:
**Run All**, **File…** (one test file), and **Filter…** (the tests matching `--filter`). Like
Open REPL it doesn't need the command list, and nothing runs until you click. Runlet picks
the runner from the project's files, not from the driver, in this order:

1. **`php artisan test`**, when `artisan`, Laravel's `vendor/nunomaduro/collision/` (which
   provides the command), and `vendor/bin/pest` or `vendor/bin/phpunit` exist, with a
   `phpunit.xml` or `phpunit.xml.dist`. It starts Pest when Pest is installed, else PHPUnit,
   and it's what Laravel's own `composer test` runs.
2. **Pest**, `php vendor/bin/pest`. Pest also runs plain PHPUnit test classes.
3. **PHPUnit**, `php vendor/bin/phpunit`.

The runner needs a PHPUnit configuration in the project folder (`phpunit.xml`,
`phpunit.dist.xml`, or `phpunit.xml.dist`, in PHPUnit's order): it names the test suites,
and without one "run all" has nothing to run. Collision passes only `phpunit.xml` or
`phpunit.xml.dist` to the runner, so a Laravel project with only `phpunit.dist.xml` runs Pest
or PHPUnit directly. For local projects and the sandbox, Runlet checks the folder on your Mac:
the runner, the configuration, and at least one of its `<testsuite>` folders or files. A
project without tests shows no Tests group; the bundled sandbox ships without `tests/`, so it
has none. The runner's own command line is typed into your shell with the target's PHP
(`'<php>' artisan test --filter=checkout`), and File… opens a file picker limited to the
project folder, starting in the first test folder. Docker profiles and SSH hosts choose in
the container or on the server, in the `sh -lc` that starts the tests, with the profile's PHP,
and explain in the tab when the project has no runner (for example, a deploy installed
without dev dependencies). There, File… takes a path relative to the profile's directory.

A file or filter reaches the runner as one argument: a file as given (with `./` in front when
it starts with `-`), a filter as `--filter=<text>`, quoted for the shell. The tab stays open
after the tests finish. **Tests are disabled on production targets**, with the reason in the
group: test suites often reset or migrate the database (`RefreshDatabase`,
`migrate:fresh`), and the test database isn't always a separate one.

### Runner protocol

A request with `"mode": "commands"` bootstraps the project exactly like a run (`started`,
then `bootstrapped` or a bootstrap `error`) and ignores `code`. The runner emits two
`commands` events, then `runnerFinished`:

```json
{"origin": "composer", "source": "Composer", "commands": [{"name": "test", "command": "composer run-script test", "description": "Run the test suite", "group": "composer"}]}
{"origin": "driver", "source": "Laravel", "framework": "laravel", "commands": [{"name": "migrate:status", "command": "php artisan migrate:status", "description": "Show the status of each migration", "group": "migrate"}]}
```

The Composer event comes first, before any project code runs. The driver event is missing
when bootstrap or `commands()` fails. A project driver's event also carries `driverFile`.
Entries may carry `"needsInput": true`.

Between them, right after the driver is chosen and before `bootstrap()`, the runner emits
one `hostCommands` event with the driver's `hostCommands()`. When the driver declares none,
both lists are empty:

```json
{"commands": [{"name": "up", "command": "docker compose up -d", "description": "Start the stack", "group": null}], "sources": [{"name": "biker", "format": "runlet", "list": "biker runlet:commands", "console": null, "description": null}]}
```

A `console` source arrives as `"format": "symfony"`, with `list` set to `<console> list
--format=json`. If `hostCommands()` throws, the event is replaced by a notice.

## SQL connections

[SQL tabs](sql-tabs.md) ([#35](https://github.com/filipac/runlet/issues/35)) run one statement
through the application's own database connection. Runlet boots the project with its driver,
as for a run, and asks the driver for the connection. It never asks for or stores credentials.

```php
/** @return \PDO|callable|null */
public function sqlConnection(?string $connection)

/** @return string[] */
public function sqlConnections(): array
```

`$connection` is the name chosen in the tab, or `null` for the default connection.
`sqlConnection()` returns one of:

| Return | What Runlet does |
| --- | --- |
| a `\PDO` | Prepares the statement on it and executes it (MySQL with native prepares and unbuffered results for the run; the connection's error mode and those attributes are restored afterwards). A result set becomes the table; otherwise `rowCount()` is the affected-row count. |
| a callable `function (string $sql)` | Calls it with the statement. Return the rows (an iterable of associative arrays or objects; a generator is read only up to the row cap) or, for a statement without a result set, the number of affected rows (an `int`). Columns come from the rows' keys, so an empty result has no columns. Use it for a client without PDO. |
| `null` | No connection from this driver. Runlet then uses an Eloquent connection resolver (Laravel, or illuminate/database through Capsule) or `$wpdb` that the application set up, and otherwise stops with a "No SQL connection" message. |

**Errors.** Throw to report a problem, such as an unknown connection name; the SQL tab shows the
message. For a project driver the error names the file and method, as during bootstrap
(`Runlet driver AcmeApiDriver (.runlet/AcmeApiDriver.php) failed in sqlConnection(): …`). A
built-in driver's error is wrapped as "Runlet could not open the "…" connection: …" followed by
the names `sqlConnections()` lists. Returning anything else than a PDO, a callable, or `null` is
an error. If `sqlConnections()` throws, the run continues without names and shows a notice.

**Order.** The booted driver's `sqlConnection()` comes first, so a project driver that defines
it wins over everything else; one that extends a built-in driver can call
`parent::sqlConnection($connection)` for the connections it doesn't handle. A driver without the
method (or one that returns `null`) falls back to the detected Eloquent connection or `$wpdb`.

**Built-in drivers** implement both methods with the same APIs as [Explain](sql-explain.md):

| Driver | `sqlConnection()` | `sqlConnections()` |
| --- | --- | --- |
| `LaravelDriver` | The PDO of `DB::connection($connection)` (Lumen: when the database is set up). A connection without a PDO is refused. | The keys of `config('database.connections')`, `database.default` first |
| `SymfonyDriver` | The `doctrine` registry's `getConnection($connection)`: its PDO, else statements through DBAL. `null` without DoctrineBundle. | The registry's connection names, the default first |
| `WordPressDriver` | `$wpdb->query()`; a connection name is refused (WordPress has one) | none |
| `ComposerDriver`, `PlainDriver` | `null` | none |

**Helpers.** `Runlet\SqlConnections` builds these results for your own driver:

- `SqlConnections::eloquent($database, ?string $connection = null): \PDO`: a DatabaseManager, Capsule manager, connection resolver, or Connection.
- `SqlConnections::doctrine($connection)`: a DBAL 2, 3, or 4 connection; its PDO when it has one, else a callable through `executeQuery()`.
- `SqlConnections::wpdb($wpdb): callable`: runs the statement with `$wpdb->query()` and returns `$wpdb->last_result` or the affected rows.

`Tests/Fixtures/custom-driver/.runlet/AcmeApiDriver.php` provides both forms:

```php
<?php
// .runlet/AcmeApiDriver.php
class AcmeApiDriver extends \Runlet\Driver
{
    // canBootstrap(), bootstrap(), variables() as above.

    public function sqlConnection(?string $connection)
    {
        $database = DI::get(App::class)->database(); // the app's own PDO
        switch ($connection ?? 'main') {
            case 'main':
                return $database;
            case 'archive':
                // A client without PDO: run the statement, return rows or affected rows.
                return static function (string $sql) use ($database) {
                    $statement = $database->query($sql);

                    return $statement->columnCount() > 0 ? $statement->fetchAll(\PDO::FETCH_ASSOC) : $statement->rowCount();
                };
            default:
                throw new \InvalidArgumentException('Acme has no "' . $connection . '" database.');
        }
    }

    public function sqlConnections(): array
    {
        return ['main', 'archive'];
    }
}
```

A driver that extends a built-in one, like `TenantDriver` in `Tests/Fixtures/custom-laravel-driver`:

```php
public function sqlConnection(?string $connection)
{
    if ($connection !== null) {
        return parent::sqlConnection($connection); // Laravel's named connections
    }

    return $this->tenantDatabase(); // the tenant's own PDO as the default
}
```

Both methods run only for SQL tabs: never for PHP runs or command listings. Results are bounded
(1,000 rows, 200 columns, 8 KiB per cell, 8 MiB per result).

## Run inspector

Next to the output, Runlet shows what a run did: the SQL statements it ran, the mail it sent,
log messages, rendered HTML, and sections your driver adds ("Cache", "HTTP calls", "Events"…).
Drivers report all of it to one `Runlet\Inspector` per run. Runlet passes it to
`inspect(Inspector $inspector)` after `bootstrap()` and before the snippet runs; it never
calls `inspect()` when it lists commands. Settings can turn the inspector off, and then
nothing is recorded and `inspect()` is not called.

### What is recorded without any code

| Project | Queries | Mail | Log | How |
| --- | --- | --- | --- | --- |
| Laravel, Lumen, Laravel Zero | Yes | Yes, and [interception](#mail-interception) | Yes | The application's event dispatcher: `QueryExecuted`, `MessageSending`, `MessageLogged`, and `JobQueued` for mail pushed to an asynchronous queue. |
| Eloquent without Laravel (illuminate/database through Capsule, for example in a Slim or PHP-DI app) | Yes | – | – | The connections Eloquent models use, or Capsule's global instance. |
| WordPress | Yes | – | – | `$wpdb` with `SAVEQUERIES`. |
| Symfony | Doctrine connections in the `doctrine` registry | Symfony Mailer, interception on 6.3+ | – | DBAL logging, and `MessageEvent` on the event dispatcher. |
| Standalone Doctrine DBAL, plain PDO | With one line in your driver | – | – | `inspectDoctrine()`, `$inspector->watchPdo()`. |

Detection runs after your driver's `bootstrap()`, so a database layer set up there is found.
It only looks at classes the application already loaded; it never autoloads anything to find
out. Your own `inspect()` replaces the default: call `parent::inspect($inspector)` to keep the
detection, or leave the method empty to record nothing.

### Eloquent without Laravel

A project driver that boots the app's container gets Eloquent's queries automatically. This
is `Tests/Fixtures/eloquent-app/.runlet/ShopDriver.php`:

```php
<?php
use Runlet\Inspector;
use Shop\Cache;

class ShopDriver extends \Runlet\Driver
{
    private $container;

    public function bootstrap(string $projectPath): void
    {
        // Creates Capsule, calls setAsGlobal() and bootEloquent(), registers services.
        $this->container = require $projectPath . '/config/bootstrap.php';
    }

    public function variables(): array
    {
        return ['container' => $this->container];
    }

    public function inspect(Inspector $inspector): void
    {
        parent::inspect($inspector); // Eloquent through Capsule, found automatically

        // A Doctrine DBAL connection Runlet cannot find on its own.
        $this->inspectDoctrine($inspector, $this->container->get('reports'), 'reports');

        // A section of your own.
        Cache::listen(static function (string $operation, string $key, $value) use ($inspector): void {
            $inspector->record('Cache', $operation . ' ' . $key, $value);
        });
    }
}
```

If the app creates its database layer lazily (a container factory that runs on first use),
pass it explicitly: `$this->inspectEloquent($inspector, $this->container->get(Capsule::class))`.
`inspectEloquent()` accepts a Capsule manager, a `DatabaseManager`, or one `Connection`.

How Eloquent queries are captured, and the trade-off:

- **Live (default).** Runlet listens for `QueryExecuted` on the connections' event dispatcher.
  When they have none (Capsule without `setEventDispatcher()`, the usual case) and
  `illuminate/events` is installed, Runlet creates a dispatcher for this run and binds it in
  Capsule's container, so connections opened later get it too. Model events stay off: Eloquent's
  own dispatcher is not changed. Queries arrive as they run, with the snippet line.
- **Query log (fallback).** Without `illuminate/events`, Runlet turns on each connection's
  query log (creating the configured connections first, which opens nothing: PDO connects on
  first use). A query is reported when the next one starts and at the end of the run, so the
  list fills in a step behind. On Laravel 8 and later (`beforeExecuting()`), queries still
  get their snippet line; on older versions they don't.

### Doctrine DBAL

```php
public function inspect(Inspector $inspector): void
{
    parent::inspect($inspector);
    $this->inspectDoctrine($inspector, $this->entityManager->getConnection(), 'default');
}
```

DBAL 2 and 3 get an SQL logger (chained to one the app already set). DBAL 4 gets a timing
middleware around the connection's driver, or around the open driver connection when it is
already connected. `SymfonyDriver` does this for every connection in the `doctrine` registry.

### Plain PDO

The query inspector's [Explain action](sql-explain.md) prepares a new PHP tab and never runs it. Built-in query hooks record an optional `databaseAPI` hint (`eloquent`, `doctrine`, `wordpress`, or `pdo`) along with the connection name. Custom `Inspector::query()` callers can supply the same hint in `$details`; without one, Explain prepares a PDO template that asks the user to recreate the connection explicitly ([#4](https://github.com/filipac/runlet/issues/4)).

PDO cannot be hooked globally, so a driver (or a snippet) opts in per connection:

```php
public function inspect(Inspector $inspector): void
{
    $inspector->watchPdo($this->container->get(PDO::class), 'app');
}
```

`watchPdo()` installs a statement class that reports every `prepare()` + `execute()` with its
bound values and time. It skips connections that already use their own statement class (as
database layers often do) and persistent connections, and it can't see `PDO::query()` or
`PDO::exec()`.

### Custom sections, logs, HTML

```php
public function inspect(Inspector $inspector): void
{
    parent::inspect($inspector);
    $inspector->section('HTTP calls'); // shown even when the run makes none

    $this->container->get(HttpClient::class)->onResponse(function ($request, $response) use ($inspector) {
        $inspector->record('HTTP calls', $request->method() . ' ' . $request->url(), [
            'status' => $response->status(),
            'body' => $response->body(),
        ]);
    });
}
```

A snippet can report too: `\Runlet\Inspector::current()->record('Debug', 'cart', $cart)`.

| Method | Purpose |
| --- | --- |
| `query(string $sql, array $bindings = [], ?float $ms = null, ?string $connection = null, array $details = [])` | One statement in **Queries**. `$details`: `driver` (`mysql`, `pgsql`, `sqlite`…), `rawSql` (the statement with bindings substituted by your database layer), `location` (from `location()`, for a statement reported after it ran). |
| `mail($message, array $details = [])` | One message in **Mail**: a Symfony Mime `Email`, a SwiftMailer message, or an array with `subject`, `from`, `to`, `cc`, `bcc`, `replyTo`, `html`, `text`, `attachments`, `mailer`, `mailable`. `$details` adds `intercepted`, `queued`, `queueConnection`. Inline `cid:` images become `data:` URLs. |
| `log(string $level, string $message, array $context = [], ?string $channel = null)` | One message in **Log**. |
| `html(string $title, string $html, string $section = 'HTML')` | Rendered HTML, previewed in a locked-down web view. |
| `record(string $section, string $title, $value)` | Any value in a section of your own, shown like a dump (bounded, no methods called). |
| `section(string $section)` | Shows a section even when nothing is recorded in it. |
| `watchPdo(\PDO $pdo, string $connection = 'pdo'): bool` | Records a PDO connection's prepared statements (above). |
| `shouldInterceptMail(): bool`, `interceptingMail()` | [Mail interception](#mail-interception). |
| `once(string $key): bool`, `atFinish(callable $callback)`, `location(): array` | Helpers for hooks: attach once, flush something when the run ends, capture where the code running now came from. |
| `Inspector::current()` | The run's inspector, or `null` outside a run. |

No method throws: they are safe inside listeners. Each record carries the snippet line that
caused it, or the first project file outside `vendor/`. If `inspect()` itself throws, Runlet
shows a notice and the run continues.

### Mail interception

**Intercept mail** (Settings ▸ General ▸ Run Inspector, off by default; projects, Docker
profiles, and SSH profiles can override it) asks drivers to record mail without sending it. The output then
says which messages were intercepted, and the run header says interception is on.

- **Laravel:** the `MessageSending` listener returns `false`, so Laravel builds the whole
  message (views, attachments) and then sends nothing. Notifications sent through the mail
  channel are covered too. Mail pushed to an asynchronous queue (`Mail::queue()`, mailables
  that implement `ShouldQueue`, on a connection other than `sync`) is sent later by a queue
  worker, outside the run, so Runlet cannot intercept it; it lists it as "queued" instead.
- **Symfony Mailer 6.3+:** `MessageEvent::reject()`. Older versions are recorded, not
  intercepted.
- **Your driver:** check `$inspector->shouldInterceptMail()`, stop the message, record it with
  `['intercepted' => true]`, and call `$inspector->interceptingMail()` so Runlet knows. When
  interception is on and no driver confirms it, Runlet warns that mail is delivered normally.

Mail sent some other way (a raw SMTP client, an HTTP API such as Mailgun's SDK) is neither
recorded nor intercepted.

### Previews

When a snippet returns or dumps an object with an HTML rendering, the output shows it next to
the value tree, in a web view with JavaScript off, no remote loads (images can be allowed per
preview), and no navigation. `Driver::preview($value)` decides; the default renders Laravel
`Mailable`s (HTML and text bodies, subject), `MailMessage`s, a `Notification`'s `toMail()`
(with an anonymous notifiable; return `$notification->toMail($user)` when it needs a real
one), views, `Htmlable` and `Renderable` objects, and Symfony responses with HTML content.
Rendering runs the application's view code, so its queries appear in the inspector; turn
previews off in Settings to skip it. Override `preview()` to add your own types:

```php
public function preview($value): ?array
{
    if ($value instanceof \Acme\Pdf\Invoice) {
        return ['title' => 'Invoice ' . $value->number(), 'html' => $value->toHtml()];
    }

    return parent::preview($value);
}
```

### Benchmarks

`Runlet\bench()` measures code from any snippet, on every target (the runner defines it; PHP
7.4 or newer, no extension needed) and shows a benchmark card where it ran, plus a
**Benchmarks** section ([#41](https://github.com/filipac/runlet/issues/41)):

```php
Runlet\bench(fn () => Str::slug('Ada Lovelace'), 5000, 'Str::slug()');

Runlet\bench([
    'array_map' => fn () => array_map(fn ($x) => $x * 2, $items),
    'foreach' => function () use ($items) { /* … */ },
], 2000);
```

`bench($callables, int $iterations = 1000, ?string $label = null, ?float $seconds = null)`
takes a callable, or an array of callables keyed by label to compare side by side (at most
20). It takes the same first two arguments as Laravel's `Benchmark::measure()`. Each callable
is called once cold (shown as "First call"), warmed up with up to 1% of the iterations (at
most 10), then timed with `hrtime(true)` up to `$iterations` times. It is bounded: at most
100,000 timed calls per callable, and it stops when the callable has used `$seconds` (1 s by
default, at most 60 s); the card says how many calls ran. Garbage is collected once before the
timed calls, not between them.

The card shows the mean, median, p95, min, max, operations per second, the iterations, the
standard deviation, the first call, and memory: the peak above what was in use before the
timed calls (PHP 8.2+ resets the peak for this; on older PHP the peak shows only when it rose
above the process's earlier peak) and the memory kept per call. Below them, a histogram of
call times from the fastest up to p99, or to the outlier fence (p75 + 3 × IQR) when that is
lower (with median and p95 markers; the slower calls are counted)
and the mean per chunk of calls in run order. A comparison shows each callable's mean as a
bar, how many times slower it is than the fastest, and a table. Timers tick in steps (41.67 ns
on Apple silicon), so the histogram uses one bin per tick when the spread is that narrow, and
the card notes when calls are so short that the timer dominates.

`bench()` returns the numbers too, in milliseconds like Laravel's Benchmark: `mean_ms`,
`median_ms`, `min_ms`, `max_ms`, `p95_ms`, `ops_per_sec`, `iterations`, `memory_peak_bytes`,
and `memory_per_call_bytes` (keyed like `$callables` when it is an array of callables).

**Laravel's `Illuminate\Support\Benchmark`.** `Benchmark::dd()` is recognized from its dump:
Runlet's dump handler sees `Benchmark::dd()` in the backtrace and adds a benchmark card with
the mean of each callable and the iteration count from its arguments; Laravel's own `dd()`
output is still shown. Laravel measures only the mean (to the microsecond), so that card has
no distribution. `Benchmark::measure()` and `Benchmark::value()` return plain numbers and
offer no hook short of replacing Laravel's code, which Runlet doesn't do: swap
`Benchmark::measure(` for `Runlet\bench(` to get the card.

Benchmarks and [profiles](architecture.md#profile-run) are recorded even when Settings turns
the inspector off: the snippet asked for them. Records: `kind` `benchmark` (section
`Benchmarks`) and `profile` (section `Profile`); see [architecture.md](architecture.md).

### Limits

Per run, Runlet records at most 2,000 statements and 2,000 other records, 8 MiB of record
data in total, and 2 MiB per HTML or text body. Values in records are bounded more tightly
than results (depth 6, 100 entries per level, 16 KiB per string, 512 KiB per value). What a
limit leaves out is counted and shown at the end of its section.

Hooks attach after the application boots, so queries the application runs while booting are
not recorded. On Lumen, the database and events are inspected only when the application
resolved them while booting.

## Built-in driver details

**Laravel family.** Each family member boots differently:

- Laravel and Laravel Zero bootstrap through the console kernel, which is how an Artisan
  command boots.
- Lumen constructs its console kernel (facades and console setup), then calls
  `$app->boot()`. Lumen's kernel has an empty `bootstrap()`, and Runlet does not call it.

Runlet detects the flavour from the installed packages before boot and from the
application class after boot. Lumen's version string is reduced to its number. Laravel
Zero reports its application version.

**WordPress.** WordPress expects to load in the global scope. Like WP-CLI, Runlet loads
`wp-load.php` from a function in which WordPress's globals are declared `global`. Any other
variable that the load defines is promoted to a global afterwards. In addition:

- `$_SERVER` gets CLI defaults: `HTTP_HOST=localhost` (or `DOMAIN_CURRENT_SITE`, when
  `wp-config.php` defines it as a literal), `REQUEST_URI=/`, and `REQUEST_METHOD=GET`.
- `WP_USE_THEMES` is `false`.
- The admin APIs (`wp-admin/includes/admin.php`) are loaded, as in WP-CLI.
- With the run inspector on, `SAVEQUERIES` is defined as `true` (unless `wp-config.php`
  mentions it), so the inspector gets each query's time from WordPress's own query log.
  Without it, queries are recorded through the `query` filter, without times.

Before WordPress loads, Runlet registers these hooks:

- `wp_die()` throws `RuntimeException("wp_die(): …")` instead of printing an HTML page.
- WordPress's fatal-error handler is disabled, so a snippet's fatal error never prints an
  error page, pauses a plugin, or emails a recovery link.
- Maintenance mode, the `advanced-cache.php` drop-in, and multisite site-status checks
  are bypassed.
- Runs do not spawn WP-Cron. A snippet can still call `wp_cron()` or `spawn_cron()`.
- If the database is unreachable or WordPress is not installed, Runlet reports a bootstrap
  error.

**Symfony.** Runlet loads `.env` files like the Runtime component does:
`Dotenv::bootEnv()`, or `loadEnv()` on older versions, or `config/bootstrap.php` for 4.x
recipes. It then boots `App\Kernel`, or the kernel declared in `src/Kernel.php`, with
`APP_ENV` (default `dev`) and `APP_DEBUG`. The first run warms `var/cache/<env>`, just as
`bin/console` would.

## Choosing a driver explicitly

The run request's `bootstrap` field defaults to `auto`. It also accepts:

- `custom`: project drivers only. It is an error if none can boot the project.
- `laravel`, `lumen`, or `laravel-zero`: all of these use `LaravelDriver`, which detects
  the flavour itself.
- `wordpress`, `symfony`, `composer`, or `plain`.

An explicit built-in value skips both project drivers and detection.

## Migrating a Tinkerwell driver

Runlet does not load Tinkerwell drivers. Porting one is mostly a rename:

| Tinkerwell (`.tinkerwell/*TinkerwellDriver.php`) | Runlet (`.runlet/*Driver.php`) |
| --- | --- |
| `class X extends TinkerwellDriver` | `class X extends \Runlet\Driver` |
| `extends LaravelTinkerwellDriver` and similar | `extends \Runlet\Drivers\LaravelDriver` and similar |
| `canBootstrap($projectPath)` | `canBootstrap(string $projectPath): bool`; the default is `true` |
| `bootstrap($projectPath)` | `bootstrap(string $projectPath): void` |
| `getAvailableVariables()` | `variables(): array` |
| `appVersion()` | `version(): ?string` |
| `contextMenu()` | No equivalent |

Before:

```php
class MyCustomTinkerwellDriver extends TinkerwellDriver
{
    public function canBootstrap($projectPath) { return true; }
    public function bootstrap($projectPath) { require '/var/www/.tinkerwell/boot.php'; }
    public function getAvailableVariables() { return ['_app' => DI::get(App::class)]; }
    public function appVersion() { return 'My API'; }
}
```

After, in `.runlet/MyApiDriver.php` with `boot.php` moved next to it:

```php
class MyApiDriver extends \Runlet\Driver
{
    public function bootstrap(string $projectPath): void { require __DIR__ . '/boot.php'; }
    public function variables(): array { return ['_app' => DI::get(App::class)]; }
    public function version(): ?string { return 'My API'; }
}
```

Use `__DIR__` instead of an absolute container path, so that the driver runs both on the
host and inside the container.

## Limitations

- **WordPress global scope.** Code that runs while WordPress loads, such as plugin files
  and early hooks, only sees the globals Runlet pre-declares as global. A plugin that
  defines a new top-level variable during load and reads it through `global` during that
  same load can behave differently, exactly as under WP-CLI. Snippets run in their own
  scope: write `global $post;` or use `$GLOBALS` for globals other than `$wpdb`.
- **WordPress multisite.** If `DOMAIN_CURRENT_SITE` comes from environment variables, as
  in Bedrock, set `$_SERVER['HTTP_HOST']` (and `REQUEST_URI` for a subdirectory site) in a
  project driver that extends `WordPressDriver` before calling `parent::bootstrap()`.
- **Driver files are trusted code.** They run with the same permissions as the snippet.
- **No driver for some frameworks.** Testbench, Craft, Drupal, Magento, and other
  frameworks from Tinkerwell's matrix have no built-in driver yet. Use a project driver.
