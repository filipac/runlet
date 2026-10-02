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

The source is `Resources/Runner/src/Drivers.php`. The runner declares these classes before
any project code loads. Every driver works on PHP 7.4 and later.

## Writing a project driver

Put a class that extends `Runlet\Driver`, or one of the built-in drivers, in a file named
`<Something>Driver.php` inside the project's `.runlet/` folder. Runlet reads the folder
straight from disk, so it still works if `.runlet/` is git-ignored, for example globally.
Inside Docker, the folder must be in the container's working directory (usually through
the project mount).

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
| `Driver` (all drivers) | `consoleCommands($commands, $commandPrefix)` turns Symfony Console commands into `commands()` entries |
| `LaravelDriver` | `$this->app` (protected); `flavor($projectPath)` returns `laravel`, `lumen`, or `laravel-zero`; overridable `consoleScript($projectPath)` |
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
searchable, and opens each one in a terminal with its Run button. The list has two sources:

- **The driver's `commands()`.** `LaravelDriver` lists every visible Artisan command (Lumen
  too, and Laravel Zero with its own binary from composer.json `bin`). `SymfonyDriver` lists
  every visible `bin/console` command of the booted kernel. `WordPressDriver`,
  `ComposerDriver`, and `PlainDriver` list none.
- **Composer scripts** from `composer.json` in the working directory, as
  `composer run-script <name>`, in the "Composer scripts" group. Composer's own event hooks
  (`post-autoload-dump`, `pre-install-cmd`, and the like) are skipped. A
  `scripts-descriptions` entry becomes the description. Runlet reads the file before any
  project code runs, so scripts are listed even when the application cannot boot.

Listing commands boots the application in a fresh PHP process, like a run (so it works
the same inside Docker), but runs no snippet. Runlet does it only when the panel opens for
a target it has not listed yet, or when you press Refresh. It never lists commands in the
background, at launch, or when you switch targets.

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
