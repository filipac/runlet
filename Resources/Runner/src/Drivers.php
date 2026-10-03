<?php

declare(strict_types=1);

/*
 * Runlet driver API, declared by the runner before anything from the project loads.
 *
 * A driver boots one kind of application for a run and hands variables to the snippet.
 * Runlet ships the built-in drivers below; a project adds its own in
 * `<project>/.runlet/*Driver.php` by extending Runlet\Driver or a built-in driver.
 * See docs/drivers.md.
 *
 * This file must stay compatible with PHP 7.4 syntax and runtime.
 */

namespace Runlet;

/**
 * Base class for every Runlet driver.
 *
 * Runlet calls, in order: canBootstrap(), bootstrap(), variables(), version(), name(),
 * environment(), and then inspect() before a snippet runs, commands() when it lists the
 * project's commands instead, or panels() for App Info. Each run is a fresh PHP process, so a
 * driver boots exactly once per run.
 */
abstract class Driver
{
    use InspectsDatabases;

    /** Name shown in Runlet's status bar. Defaults to the short class name. */
    public function name(): string
    {
        $class = get_class($this);
        $separator = strrpos($class, '\\');

        return $separator === false ? $class : substr($class, $separator + 1);
    }

    /**
     * Whether this driver can boot the project at $projectPath (the run's working
     * directory). Project drivers default to true.
     */
    public function canBootstrap(string $projectPath): bool
    {
        return true;
    }

    /** Boots the application. Throw to report a bootstrap error. */
    abstract public function bootstrap(string $projectPath): void;

    /**
     * Variables available in every snippet, as name => value. Called after bootstrap().
     *
     * @return array<string, mixed>
     */
    public function variables(): array
    {
        return [];
    }

    /** Application or framework version shown next to the driver name, if any. */
    public function version(): ?string
    {
        return null;
    }

    /**
     * The application's environment name ("local", "staging", "production", …), if it has
     * one. Called after bootstrap(). Runlet compares it with how the target is marked: when
     * the application says production and the target isn't marked production, the tab offers
     * to mark it. Return the name only, never other configuration. Throwing is noted in the
     * Run Log; the run continues without an environment.
     *
     * No native return type, so project drivers written before this hook (with their own
     * environment() method) keep loading; overrides may declare `: ?string`.
     *
     * @return string|null
     */
    public function environment()
    {
        return null;
    }

    /**
     * Commands listed in Runlet's Commands panel, keyed by name. Called after bootstrap(),
     * only when the panel loads commands, never during a snippet run. Each entry is
     *
     *     'name' => ['command' => 'php artisan name', 'description' => '…', 'group' => 'ns']
     *
     * where `command` is a shell command line run in the project directory (inside the
     * container for Docker targets), and `description` and `group` are optional. A string
     * value is shorthand for `['command' => …]`. Extend a built-in driver's list with
     * `parent::commands() + [...]` or array_merge(). Composer scripts are added by Runlet.
     *
     * @return array<string, array{command: string, description?: string|null, group?: string|null}|string>
     */
    public function commands(): array
    {
        return [];
    }

    /**
     * Commands that run on the Mac, in the project's folder there (for Docker targets, the
     * profile's local source folder), instead of inside the target: tools installed on the
     * host such as `docker compose` or your own CLIs. Same entries as commands(), plus
     * command sources, tools Runlet asks for their commands each time the list loads:
     *
     *     'up'    => ['command' => 'docker compose up -d', 'description' => 'Start the stack'],
     *     // Prints {"commands": [{"name", "command", "description"?, "group"?, "needsInput"?}]}
     *     'tools' => ['list' => 'mytool runlet:commands'],
     *     // A Symfony Console app (Laravel Zero, Artisan-style): reads `mytool list --format=json`
     *     'mytool' => ['console' => 'mytool'],
     *
     * Command lines run in your login shell's environment (PATH included). Called before
     * bootstrap(), so these commands are listed even when the application cannot boot:
     * return declarations only, without running anything.
     *
     * @return array<string, array{command?: string, list?: string, console?: string, description?: string|null, group?: string|null}|string>
     */
    public function hostCommands(): array
    {
        return [];
    }

    /**
     * SQL tabs (#35): how a statement from an SQL tab reaches this application's database.
     * `$connection` is the name chosen in the tab, or null for the default connection.
     * Return one of:
     *
     *  - a \PDO: Runlet prepares and runs the statement on it;
     *  - a callable `function (string $sql)` that runs the statement and returns its rows (an
     *    iterable of associative arrays or objects) or, for a statement without a result
     *    set, the number of affected rows (an int);
     *  - null when this driver has no connection for SQL tabs. Runlet then uses an Eloquent
     *    connection or WordPress's $wpdb if the application set one up, and otherwise says
     *    that the project has no SQL connection. Runlet never asks for credentials.
     *
     * Throw to report a problem, such as an unknown connection name: the tab shows the
     * message. Called after bootstrap(), only when an SQL tab runs. The built-in drivers
     * return the application's own connection (Laravel's DB::connection(), Symfony's
     * Doctrine registry, WordPress's $wpdb); SqlConnections has helpers for your own.
     *
     * @return \PDO|callable|null
     */
    public function sqlConnection(?string $connection)
    {
        return null;
    }

    /**
     * SQL tabs (#35): the names of the application's database connections, the default
     * first, for the tab's connection picker. Called when an SQL tab runs; return [] to list
     * none (the tab can still name a connection).
     *
     * @return string[]
     */
    public function sqlConnections(): array
    {
        return [];
    }

    /**
     * SQL tabs (#128): the tables and columns of a connection, for completion. Return null
     * (the default) and Runlet reads them through sqlConnection(): information_schema on
     * MySQL, MariaDB, PostgreSQL, and SQL Server, sqlite_master on SQLite. Return them
     * yourself when your connection is a callable Runlet can't query that way:
     *
     *     return ['users' => ['id' => 'integer', 'email' => 'varchar'], 'orders' => ['id', 'total']];
     *
     * (column => type, or a list of column names). Called only when the user loads the
     * schema in an SQL tab, or after a statement ran there.
     *
     * @return array<string, array<int|string, string>>|null
     */
    public function sqlSchema(?string $connection): ?array
    {
        return null;
    }

    /**
     * Extra sections for Runlet's App Info popover (#19), shown after its own (the framework's
     * details and PHP). Called after bootstrap(), only when the user opens App Info, never
     * during a snippet run. Keyed by section title, each holding `label => value` rows; a value
     * is a string, number, bool, null, or a list of strings:
     *
     *     'Tenant' => ['Name' => 'acme', 'Workers' => 3, 'Features' => ['beta', 'new-ui']],
     *
     * Runlet bounds the sections and hides secret-looking values (see docs/drivers.md).
     * Extend a built-in driver's with `parent::panels() + [...]`.
     *
     * @return array<string, array<string, mixed>>
     */
    public function panels(): array
    {
        return [];
    }

    /**
     * Run inspector hook: called after bootstrap() and before the snippet runs (never when
     * Runlet lists commands). Report what the run does through $inspector: SQL queries,
     * mail, log messages, HTML, or sections of your own. Runlet turns anything this method
     * throws into a notice; the run continues.
     *
     * The default finds Eloquent connections (Laravel, or illuminate/database through
     * Capsule) and WordPress's $wpdb. Call parent::inspect() to keep that when you add your
     * own hooks, or override it with an empty method to record nothing.
     */
    public function inspect(Inspector $inspector): void
    {
        $this->inspectAutomatically($inspector);
    }

    /** What inspect() detects by default: Eloquent and WordPress. */
    protected function inspectAutomatically(Inspector $inspector): void
    {
        $this->inspectEloquent($inspector);
        $this->inspectWordPress($inspector);
    }

    /**
     * Rendered HTML for a value the snippet returned or dumped, shown as a preview next to
     * its value tree. Called only for objects, and only while Settings ▸ Output renders
     * previews. Return null for values without a preview. The default renders Laravel
     * mailables, mail notifications (MailMessage, or a Notification's toMail()), views,
     * Htmlable and Renderable objects, and HTML Symfony responses. Rendering runs the
     * application's view code; Runlet reports anything it throws on the preview.
     *
     * @param mixed $value
     * @return array{html: string, title?: string, subject?: string, text?: string, kind?: string}|null
     */
    public function preview($value): ?array
    {
        if (!is_object($value)) {
            return null;
        }
        $class = get_class($value);
        if ($value instanceof \Illuminate\Notifications\Notification && method_exists($value, 'toMail')
            && class_exists('Illuminate\Notifications\AnonymousNotifiable')) {
            try {
                $mail = $value->toMail(new \Illuminate\Notifications\AnonymousNotifiable());
            } catch (\Throwable $error) {
                throw new \RuntimeException($class . '::toMail() needs a notifiable for the preview (' . $error->getMessage() . '). Return $notification->toMail($user) instead.', 0, $error);
            }
            $preview = is_object($mail) ? $this->preview($mail) : null;

            return $preview === null ? null : ['title' => $class] + $preview;
        }
        if ($value instanceof \Illuminate\Mail\Mailable) {
            $text = null;
            if (method_exists($value, 'renderForAssertions')) {
                // Laravel 10+: the HTML and plain-text bodies, as the mail would carry them.
                $method = new \ReflectionMethod($value, 'renderForAssertions');
                if (PHP_VERSION_ID < 80100) {
                    $method->setAccessible(true);
                }
                [$html, $text] = $method->invoke($value);
            } else {
                $html = $value->render();
            }
            $subject = isset($value->subject) && is_scalar($value->subject) ? (string) $value->subject : null;

            return array_filter(['kind' => 'mail', 'title' => $class, 'subject' => $subject, 'html' => (string) $html, 'text' => $text === null || $text === '' ? null : (string) $text], 'is_string');
        }
        if ($value instanceof \Illuminate\Notifications\Messages\MailMessage) {
            $text = null;
            if (isset($value->markdown) && is_string($value->markdown) && class_exists('Illuminate\Mail\Markdown') && class_exists('Illuminate\Container\Container')) {
                try {
                    $text = (string) \Illuminate\Container\Container::getInstance()->make('Illuminate\Mail\Markdown')->renderText($value->markdown, $value->data());
                } catch (\Throwable $error) {
                    $text = null;
                }
            }
            $subject = isset($value->subject) && is_scalar($value->subject) ? (string) $value->subject : null;

            return array_filter(['kind' => 'mail', 'title' => $class, 'subject' => $subject, 'html' => (string) $value->render(), 'text' => $text], 'is_string');
        }
        if ($value instanceof \Illuminate\Contracts\View\View) {
            $name = method_exists($value, 'name') ? (string) $value->name() : $class;

            return ['kind' => 'view', 'title' => $name, 'html' => (string) $value->render()];
        }
        if ($value instanceof \Symfony\Component\HttpFoundation\Response) {
            $type = (string) $value->headers->get('Content-Type', '');
            $content = $value->getContent();
            if (!is_string($content) || ($type !== '' ? stripos($type, 'html') === false : !preg_match('/^\s*</', $content))) {
                return null;
            }

            return ['kind' => 'response', 'title' => $class . ' ' . $value->getStatusCode(), 'html' => $content];
        }
        if ($value instanceof \Illuminate\Contracts\Support\Htmlable) {
            return ['kind' => 'html', 'title' => $class, 'html' => (string) $value->toHtml()];
        }
        if ($value instanceof \Illuminate\Contracts\Support\Renderable) {
            return ['kind' => 'html', 'title' => $class, 'html' => (string) $value->render()];
        }

        return null;
    }


    /**
     * Describes Symfony Console commands (Artisan, bin/console, ...) for commands():
     * aliases and hidden commands are skipped, and each command is grouped by its
     * namespace (`make:model` in "make"; `migrate` joins "migrate" when `migrate:*` exists).
     *
     * @param iterable<mixed> $commands name => Symfony\Component\Console\Command\Command, as from Application::all()
     * @param string $commandPrefix the console invocation, e.g. "php artisan"
     * @return array<string, array{command: string, description: string|null, group: string|null, needsInput?: bool}>
     */
    protected function consoleCommands(iterable $commands, string $commandPrefix): array
    {
        $descriptions = [];
        $needsInput = [];
        foreach ($commands as $key => $command) {
            if (!is_object($command) || !method_exists($command, 'getName')) {
                continue;
            }
            $name = (string) $command->getName();
            // Application::all() lists every alias as its own key.
            if ($name === '' || (is_string($key) && $key !== $name) || isset($descriptions[$name])) {
                continue;
            }
            if (method_exists($command, 'isHidden') && $command->isHidden()) {
                continue;
            }
            $description = method_exists($command, 'getDescription') ? trim((string) $command->getDescription()) : '';
            $descriptions[$name] = $description === '' ? null : $description;
            if (method_exists($command, 'getDefinition')) {
                foreach ($command->getDefinition()->getArguments() as $argument) {
                    if ($argument->isRequired()) {
                        $needsInput[$name] = true;
                        break;
                    }
                }
            }
        }
        ksort($descriptions, SORT_STRING);

        $namespaces = [];
        foreach (array_keys($descriptions) as $name) {
            $colon = strpos((string) $name, ':');
            if ($colon !== false && $colon > 0) {
                $namespaces[substr((string) $name, 0, $colon)] = true;
            }
        }

        $result = [];
        foreach ($descriptions as $name => $description) {
            $name = (string) $name;
            $colon = strpos($name, ':');
            if ($colon !== false && $colon > 0) {
                $group = substr($name, 0, $colon);
            } else {
                $group = isset($namespaces[$name]) ? $name : null;
            }
            $argument = preg_match('/^[A-Za-z0-9:._-]+$/', $name) ? $name : escapeshellarg($name);
            $result[$name] = ['command' => $commandPrefix . ' ' . $argument, 'description' => $description, 'group' => $group];
            if (isset($needsInput[$name])) {
                // Required arguments: Runlet types the command without running it.
                $result[$name]['needsInput'] = true;
            }
        }

        return $result;
    }

    /**
     * Explains an exit() during bootstrap, e.g. a redirect the application tried to send.
     * Appended to Runlet's "called exit() while bootstrapping" error; null when unknown.
     */
    public function bootstrapExitHint(): ?string
    {
        return null;
    }

    /** Adds a line to the app's Run Log (Run ▸ Show Run Log), e.g. a boot step or a timing. */
    protected function log(string $message, ?string $detail = null): void
    {
        \RunletRunner\Runner::log('driver', $message, $detail);
    }

    /**
     * "main @ 3f2a1c9" for the git checkout at $projectPath, read from the `.git` files
     * (HEAD, loose refs, packed-refs; linked worktrees too) without running git. A detached
     * HEAD gives just the short commit. Null when there is no readable checkout, e.g. a
     * container image without the `.git` directory. Useful in version():
     *
     *     public function version(): ?string { return $this->gitRevision(dirname(__DIR__)); }
     */
    protected function gitRevision(string $projectPath): ?string
    {
        $gitDir = rtrim($projectPath, '/') . '/.git';
        if (is_file($gitDir)) {
            // A linked worktree: ".git" is a file with "gitdir: <path>".
            $pointer = @file_get_contents($gitDir);
            if ($pointer === false || !preg_match('/^gitdir:\s*(.+)$/m', $pointer, $match)) {
                return null;
            }
            $gitDir = trim($match[1]);
            if ($gitDir !== '' && $gitDir[0] !== '/') {
                $gitDir = rtrim($projectPath, '/') . '/' . $gitDir;
            }
        }
        $head = @file_get_contents($gitDir . '/HEAD');
        if ($head === false) {
            return null;
        }
        $head = trim($head);
        if (preg_match('/^[0-9a-f]{40,64}$/', $head)) {
            return substr($head, 0, 7);
        }
        if (!preg_match('#^ref:\s*(refs/\S+)$#', $head, $match)) {
            return null;
        }
        $ref = $match[1];
        $branch = preg_replace('#^refs/heads/#', '', $ref);
        // Shared refs live in the common directory of a linked worktree.
        $commonDir = $gitDir;
        $common = @file_get_contents($gitDir . '/commondir');
        if ($common !== false && trim($common) !== '') {
            $common = trim($common);
            $commonDir = $common[0] === '/' ? $common : $gitDir . '/' . $common;
        }
        $commit = null;
        foreach ([$gitDir, $commonDir] as $dir) {
            $loose = @file_get_contents($dir . '/' . $ref);
            if ($loose !== false && preg_match('/^[0-9a-f]{40,64}/', trim($loose), $sha)) {
                $commit = $sha[0];
                break;
            }
        }
        if ($commit === null) {
            $packed = @file_get_contents($commonDir . '/packed-refs');
            if ($packed !== false && preg_match('/^([0-9a-f]{40,64}) ' . preg_quote($ref, '/') . '$/m', $packed, $sha)) {
                $commit = $sha[1];
            }
        }

        return $commit === null ? $branch : $branch . ' @ ' . substr($commit, 0, 7);
    }
}

/**
 * SQL tabs (#35): ready-made sqlConnection() results for common database layers. The
 * built-in drivers use them, and a project driver can too:
 *
 *     public function sqlConnection(?string $connection)
 *     {
 *         return SqlConnections::doctrine($this->container->get('reports'));
 *     }
 */
final class SqlConnections
{
    /**
     * An Eloquent connection's PDO: `$database` is a DatabaseManager, a Capsule manager, a
     * connection resolver, or one Connection; `$connection` names one (null: the default).
     *
     * @param object $database
     */
    public static function eloquent($database, ?string $connection = null): \PDO
    {
        $resolved = $database;
        if (is_object($resolved) && !method_exists($resolved, 'getPdo') && method_exists($resolved, 'connection')) {
            $resolved = $resolved->connection($connection);
        }
        if (!is_object($resolved) || !method_exists($resolved, 'getPdo')) {
            throw new \InvalidArgumentException('SqlConnections::eloquent() needs a database manager, a connection resolver, or a Connection.');
        }
        $pdo = $resolved->getPdo();
        if (!$pdo instanceof \PDO) {
            $name = method_exists($resolved, 'getName') ? (string) $resolved->getName() : ($connection ?? 'default');
            throw new \RuntimeException('The ' . $name . ' connection has no PDO, so SQL tabs can\'t run statements on it.');
        }

        return $pdo;
    }

    /**
     * A Doctrine DBAL connection (DBAL 2, 3, or 4): its PDO when it has one, otherwise a
     * callable that runs the statement through DBAL.
     *
     * @param object $connection
     * @return \PDO|callable
     */
    public static function doctrine($connection)
    {
        $native = null;
        try {
            if (method_exists($connection, 'getNativeConnection')) {
                $native = $connection->getNativeConnection(); // DBAL 3.3+
            } elseif (method_exists($connection, 'getWrappedConnection')) {
                $native = $connection->getWrappedConnection(); // DBAL 2: a PDO for pdo_* drivers
            }
        } catch (\LogicException $error) {
            $native = null; // A driver whose native connection DBAL doesn't expose.
        }
        if ($native instanceof \PDO) {
            return $native;
        }

        return static function (string $sql) use ($connection) {
            $result = $connection->executeQuery($sql);
            if ($result->columnCount() === 0) {
                return $result->rowCount();
            }

            return (static function () use ($result) {
                if (method_exists($result, 'fetchAssociative')) {
                    while (($row = $result->fetchAssociative()) !== false) {
                        yield $row;
                    }
                } else {
                    while (($row = $result->fetch(\PDO::FETCH_ASSOC)) !== false) {
                        yield $row;
                    }
                }
            })();
        };
    }

    /**
     * WordPress's $wpdb: a callable that runs the statement with $wpdb->query(). WordPress
     * reports affected rows for INSERT, UPDATE, DELETE, and REPLACE, nothing for DDL, and
     * rows for everything else.
     *
     * @param object $wpdb
     */
    public static function wpdb($wpdb): callable
    {
        return static function (string $sql) use ($wpdb) {
            // wpdb::query() classifies a statement by its first word, so leading comments go.
            $sql = (string) preg_replace('~^(\s*(--[^\n]*(\n|$)|#[^\n]*(\n|$)|/\*.*?\*/))+~s', '', $sql);
            $suppressed = method_exists($wpdb, 'suppress_errors') ? $wpdb->suppress_errors(true) : null;
            try {
                $returned = $wpdb->query($sql);
            } finally {
                if ($suppressed !== null) {
                    $wpdb->suppress_errors($suppressed);
                }
            }
            if ($returned === false) {
                $error = isset($wpdb->last_error) && is_string($wpdb->last_error) ? $wpdb->last_error : '';
                throw new \RuntimeException($error !== '' ? $error : 'WordPress could not run the statement.');
            }
            if (preg_match('/^\s*(create|alter|truncate|drop|insert|delete|update|replace)\s/i', $sql)) {
                return is_int($returned) ? $returned : 0;
            }

            return isset($wpdb->last_result) && is_array($wpdb->last_result) ? $wpdb->last_result : [];
        };
    }
}

namespace Runlet\Drivers;

use Runlet\Driver;
use Runlet\Inspector;
use Runlet\SqlConnections;

/** A directory without Composer or framework markers: nothing is loaded. */
class PlainDriver extends Driver
{
    public function name(): string
    {
        return 'PHP';
    }

    public function bootstrap(string $projectPath): void
    {
    }
}

/** Any Composer project: loads vendor/autoload.php. */
class ComposerDriver extends Driver
{
    public function name(): string
    {
        return 'Composer';
    }

    public function canBootstrap(string $projectPath): bool
    {
        return is_file($projectPath . '/composer.json') || is_file($projectPath . '/vendor/autoload.php');
    }

    public function bootstrap(string $projectPath): void
    {
        $this->requireAutoloader($projectPath);
    }

    /** Loads the project's Composer autoloader, or explains how to install it. */
    protected function requireAutoloader(string $projectPath): void
    {
        $autoload = $projectPath . '/vendor/autoload.php';
        if (!is_file($autoload)) {
            throw new \RuntimeException('Composer dependencies are not installed: ' . $autoload . ' is missing. Run `composer install` in the project.');
        }
        require_once $autoload;
    }
}

/**
 * Laravel, Lumen, and Laravel Zero: loads bootstrap/app.php and bootstraps it like an
 * Artisan command does, so providers, config, facades, and helpers are ready.
 */
class LaravelDriver extends ComposerDriver
{
    /** @var object|null The application returned by bootstrap/app.php. */
    protected $app;
    /** @var string|null */
    private $projectPath;

    public function name(): string
    {
        switch ($this->flavor($this->projectPath ?? '.')) {
            case 'lumen':
                return 'Lumen';
            case 'laravel-zero':
                return 'Laravel Zero';
            default:
                return 'Laravel';
        }
    }

    public function canBootstrap(string $projectPath): bool
    {
        if (!is_file($projectPath . '/bootstrap/app.php')) {
            return false;
        }

        // Laravel and Lumen ship `artisan`; Laravel Zero apps name their entry script themselves.
        return is_file($projectPath . '/artisan') || self::hasPackage($projectPath, 'laravel-zero/framework');
    }

    /**
     * Which Laravel-family framework the project uses: "laravel", "lumen", or "laravel-zero".
     * After bootstrap() this comes from the application class, before it from installed packages.
     */
    public function flavor(string $projectPath): string
    {
        if (is_object($this->app)) {
            if (is_a($this->app, 'Laravel\Lumen\Application')) {
                return 'lumen';
            }
            if (is_a($this->app, 'LaravelZero\Framework\Application')) {
                return 'laravel-zero';
            }

            return 'laravel';
        }
        if (self::hasPackage($projectPath, 'laravel/lumen-framework')) {
            return 'lumen';
        }
        if (self::hasPackage($projectPath, 'laravel-zero/framework')) {
            return 'laravel-zero';
        }

        return 'laravel';
    }

    public function bootstrap(string $projectPath): void
    {
        $this->projectPath = $projectPath;
        $this->requireAutoloader($projectPath);

        $app = require $projectPath . '/bootstrap/app.php';
        if (!is_object($app) || !method_exists($app, 'make')) {
            throw new \RuntimeException('bootstrap/app.php did not return a Laravel application.');
        }
        $this->app = $app;

        if ($this->flavor($projectPath) === 'lumen') {
            // Lumen's console kernel has an empty bootstrap(): constructing it prepares the
            // console environment (facades, URL generation), and boot() boots the providers.
            if (method_exists($app, 'bound') && $app->bound('Illuminate\Contracts\Console\Kernel')) {
                $app->make('Illuminate\Contracts\Console\Kernel');
            }
            if (method_exists($app, 'boot')) {
                $app->boot();
            }

            return;
        }

        // Laravel and Laravel Zero; the kernel skips bootstrappers that already ran.
        $app->make('Illuminate\Contracts\Console\Kernel')->bootstrap();
    }

    /** @return array<string, mixed> */
    public function variables(): array
    {
        return $this->app === null ? [] : ['app' => $this->app];
    }

    /** SQL tabs (#35): the PDO of DB::connection($connection), the application's own. */
    public function sqlConnection(?string $connection)
    {
        $database = $this->resolveService('db');

        return $database === null ? null : SqlConnections::eloquent($database, $connection);
    }

    /** SQL tabs (#35): the keys of config('database.connections'), database.default first. */
    public function sqlConnections(): array
    {
        $config = $this->resolveService('config');
        if ($config === null || !method_exists($config, 'get')) {
            return [];
        }
        $names = array_map('strval', array_keys((array) $config->get('database.connections', [])));
        $default = $config->get('database.default');
        if (is_string($default) && $default !== '') {
            $names = array_merge([$default], array_values(array_diff($names, [$default])));
        }

        return $names;
    }

    /** A service of the booted application, or null when it has none (a Lumen app without the database, …). */
    private function resolveService(string $id)
    {
        if (!is_object($this->app) || !method_exists($this->app, 'make')) {
            return null;
        }
        // Lumen binds core services lazily: bound() is false until first use, make() works.
        $isLumen = is_a($this->app, 'Laravel\Lumen\Application');
        if (!$isLumen && method_exists($this->app, 'bound') && !$this->app->bound($id)) {
            return null;
        }
        try {
            return $this->app->make($id);
        } catch (\Throwable $error) {
            if ($isLumen) {
                return null;
            }
            throw $error;
        }
    }

    /**
     * Queries (the application's database manager), mail, and log messages, through the
     * application's event dispatcher. With mail interception on, MessageSending listeners
     * return false, so Laravel builds each message but sends nothing.
     */
    public function inspect(Inspector $inspector): void
    {
        // Only services the application already resolved: inspecting never boots more of it.
        $resolved = function (string $id): bool {
            return is_object($this->app) && method_exists($this->app, 'resolved') && $this->app->resolved($id);
        };
        if ($resolved('db')) {
            $this->inspectEloquent($inspector, $this->app->make('db'));
        }
        parent::inspect($inspector);
        if (!$resolved('events')) {
            return;
        }
        $events = $this->app->make('events');
        if (is_object($events) && method_exists($events, 'listen')) {
            $this->inspectLaravelMail($inspector, $events);
            $this->inspectLaravelLog($inspector, $events);
        }
    }

    /**
     * Mail sent during the run (MessageSending), intercepted when the run asks for it, and
     * mail pushed to an asynchronous queue, which a worker sends later and Runlet cannot stop.
     *
     * @param object $events the application's event dispatcher
     */
    protected function inspectLaravelMail(Inspector $inspector, $events): void
    {
        if (!$inspector->once('laravel-mail:' . spl_object_id($events))) {
            return;
        }
        $inspector->section(Inspector::MAIL);
        $intercept = $inspector->shouldInterceptMail();
        $events->listen('Illuminate\Mail\Events\MessageSending', static function ($event) use ($inspector, $intercept) {
            $data = isset($event->data) && is_array($event->data) ? $event->data : [];
            $details = ['intercepted' => $intercept];
            foreach (['__laravel_mailable', '__laravel_notification'] as $key) {
                if (isset($data[$key]) && is_string($data[$key])) {
                    $details['mailable'] = $data[$key];
                }
            }
            if (isset($data['mailer']) && is_string($data['mailer'])) {
                $details['mailer'] = $data['mailer'];
            }
            if (isset($event->message) && is_object($event->message)) {
                $inspector->mail($event->message, $details);
            }

            // false stops Laravel from sending; null lets the next listener decide.
            return $intercept ? false : null;
        });
        if ($intercept) {
            $inspector->interceptingMail();
        }
        $events->listen('Illuminate\Queue\Events\JobQueued', static function ($event) use ($inspector): void {
            $job = $event->job ?? null;
            $connection = isset($event->connectionName) && is_string($event->connectionName) ? $event->connectionName : null;
            if (!is_object($job) || $connection === 'sync') {
                return;
            }
            $mailable = null;
            if (is_a($job, 'Illuminate\Mail\SendQueuedMailable') && isset($job->mailable) && is_object($job->mailable)) {
                $mailable = get_class($job->mailable);
            } elseif (is_a($job, 'Illuminate\Notifications\SendQueuedNotifications') && isset($job->notification) && is_object($job->notification)) {
                if (is_array($job->channels ?? null) && !in_array('mail', $job->channels, true)) {
                    return;
                }
                $mailable = get_class($job->notification);
            }
            if ($mailable === null) {
                return;
            }
            $subject = isset($job->mailable->subject) && is_scalar($job->mailable->subject) ? (string) $job->mailable->subject : null;
            $inspector->mail(array_filter([
                'subject' => $subject,
                'mailable' => $mailable,
                'queued' => true,
                'queueConnection' => $connection,
                'queue' => isset($event->queue) && is_string($event->queue) ? $event->queue : null,
                'to' => isset($job->mailable->to) && is_array($job->mailable->to) ? $job->mailable->to : null,
            ], static function ($value): bool {
                return $value !== null;
            }));
        });
    }

    /** @param object $events the application's event dispatcher */
    protected function inspectLaravelLog(Inspector $inspector, $events): void
    {
        if (!$inspector->once('laravel-log:' . spl_object_id($events))) {
            return;
        }
        $inspector->section(Inspector::LOG);
        $events->listen('Illuminate\Log\Events\MessageLogged', static function ($event) use ($inspector): void {
            $message = $event->message ?? '';
            $inspector->log(
                is_scalar($event->level ?? null) ? (string) $event->level : 'log',
                is_scalar($message) ? (string) $message : (is_object($message) ? get_class($message) : gettype($message)),
                isset($event->context) && is_array($event->context) ? $event->context : []
            );
        });
    }

    public function version(): ?string
    {
        if (!is_object($this->app) || !method_exists($this->app, 'version')) {
            return null;
        }
        $version = (string) $this->app->version();
        // Lumen reports "Lumen (10.0.4) (Laravel Components ^10.0)".
        if (preg_match('/^Lumen \(([^)]+)\)/', $version, $match)) {
            return $match[1];
        }

        return $version;
    }

    /**
     * `app()->environment()`: APP_ENV, or `app.env` (Laravel, Lumen, and Laravel Zero).
     *
     * @return string|null
     */
    public function environment()
    {
        if (!is_object($this->app) || !method_exists($this->app, 'environment')) {
            return null;
        }
        $environment = $this->app->environment();

        return is_string($environment) ? $environment : null;
    }

    /** Every visible Artisan command (or the Laravel Zero app's commands), as `php <script> <name>`. */
    public function commands(): array
    {
        if (!is_object($this->app) || !method_exists($this->app, 'make')) {
            return [];
        }
        $kernel = $this->app->make('Illuminate\Contracts\Console\Kernel');
        if (!is_object($kernel) || !method_exists($kernel, 'all')) {
            return [];
        }

        return $this->consoleCommands($kernel->all(), 'php ' . $this->consoleScript($this->projectPath ?? '.'));
    }

    /**
     * The console entry script, relative to the project: `artisan` for Laravel and Lumen; for
     * Laravel Zero, the binary named in composer.json "bin", or the PHP script in the project
     * root that loads bootstrap/app.php.
     */
    protected function consoleScript(string $projectPath): string
    {
        if ($this->flavor($projectPath) !== 'laravel-zero') {
            return 'artisan';
        }
        $manifest = @file_get_contents($projectPath . '/composer.json');
        $composer = is_string($manifest) ? json_decode($manifest, true) : null;
        foreach ((array) ($composer['bin'] ?? []) as $binary) {
            if (is_string($binary) && $binary !== '' && is_file($projectPath . '/' . $binary)) {
                return preg_match('/^[A-Za-z0-9\/._-]+$/', $binary) ? $binary : escapeshellarg($binary);
            }
        }
        foreach ((array) @scandir($projectPath) as $entry) {
            $path = $projectPath . '/' . $entry;
            if (!is_string($entry) || $entry === '' || $entry[0] === '.' || strpos($entry, '.') !== false || !is_file($path)) {
                continue;
            }
            $head = (string) @file_get_contents($path, false, null, 0, 2048);
            if (strpos($head, '#!') === 0 && strpos($head, 'php') !== false && strpos($head, 'bootstrap/app.php') !== false) {
                return preg_match('/^[A-Za-z0-9._-]+$/', $entry) ? $entry : escapeshellarg($entry);
            }
        }

        return is_file($projectPath . '/artisan') ? 'artisan' : 'application';
    }

    private static function hasPackage(string $projectPath, string $package): bool
    {
        if (is_dir($projectPath . '/vendor/' . $package)) {
            return true;
        }
        $manifest = @file_get_contents($projectPath . '/composer.json');
        $composer = is_string($manifest) ? json_decode($manifest, true) : null;
        if (!is_array($composer)) {
            return false;
        }
        foreach (['require', 'require-dev'] as $section) {
            if (isset($composer[$section][$package])) {
                return true;
            }
        }

        return false;
    }
}

/**
 * WordPress: a standard install, Bedrock (web/wp), public/wp, wordpress/, or wp/.
 *
 * WordPress is written for the global scope. Like WP-CLI, Runlet loads it from a function
 * whose WordPress globals are declared `global`, then promotes any other variable the
 * load defined. Snippets run in their own scope: use `global $post;` (or $GLOBALS) for
 * globals other than the injected $wpdb.
 */
class WordPressDriver extends Driver
{
    /** @var array{location: string, status: int, caller: string}|null The last redirect WordPress tried while booting. */
    private static $bootRedirect;
    /** @var bool The request uses the localhost default: take the host from the `home` option once the database is up. */
    private static $hostFromDatabase = false;
    /** @var array<string, float> Boot milestones (microtime) for the Run Log's timing breakdown. */
    private static $bootMarks = [];
    /** @var array<string, float> Seconds spent loading each plugin (by folder or file name). */
    private static $pluginTimes = [];
    /** @var float When the previous plugin finished loading. */
    private static $lastPluginMark = 0.0;
    /** Globals WordPress core and common setups assign at file scope while loading. */
    private const WORDPRESS_GLOBALS = [
        'wpdb', 'table_prefix', 'wp_version', 'wp_db_version', 'tinymce_version', 'required_php_version',
        'required_php_extensions', 'required_mysql_version', 'wp_local_package', 'blog_id', 'site_id', 'public',
        'current_site', 'current_blog', 'path', 'domain', 'shortcode_tags', 'wp_filter', 'wp_actions', 'wp_filters',
        'wp_current_filter', 'wp_object_cache', 'wp_embed', 'wp_textdomain_registry', 'wp_plugin_paths',
        'wp_the_query', 'wp_query', 'wp_rewrite', 'wp', 'wp_widget_factory', 'wp_roles', 'locale', 'locale_file',
        'wp_locale', 'wp_locale_switcher', 'wp_theme', 'wp_theme_directories', 'pagenow', 'is_lynx', 'is_gecko',
        'is_winIE', 'is_macIE', 'is_opera', 'is_NS4', 'is_safari', 'is_chrome', 'is_iphone', 'is_IE', 'is_edge',
        'is_apache', 'is_nginx', 'is_caddy', 'is_IIS', 'is_iis7', '_wp_switched_stack', 'switched', 'current_user',
        'post', 'posts', 'wp_post_types', 'wp_taxonomies', 'wp_post_statuses', 'wp_scripts', 'wp_styles', 'l10n',
        'allowedposttags', 'allowedtags', 'allowedentitynames', 'allowedxmlentitynames', 'wp_registered_sidebars',
        'wp_registered_widgets', 'wp_meta_boxes', 'wp_settings_errors', 'wp_rest_server', 'wp_sitemaps',
        'mu_plugin', 'network_plugin', 'plugin', '_wp_plugin_file',
    ];

    /** @var array<int, string> */
    private const LOADERS = ['wp-load.php', 'web/wp/wp-load.php', 'public/wp/wp-load.php', 'wordpress/wp-load.php', 'wp/wp-load.php'];

    public function name(): string
    {
        return 'WordPress';
    }

    public function canBootstrap(string $projectPath): bool
    {
        return $this->locateLoader($projectPath) !== null;
    }

    public function bootstrap(string $projectPath): void
    {
        $loader = $this->locateLoader($projectPath);
        if ($loader === null) {
            throw new \RuntimeException('WordPress was not found: there is no wp-load.php in ' . $projectPath . ' (also looked in ' . implode(', ', array_map('dirname', array_slice(self::LOADERS, 1))) . ').');
        }
        $config = self::configFile(dirname($loader));
        if ($config === null) {
            throw new \RuntimeException('WordPress is not configured: wp-config.php was not found next to ' . $loader . ' or one directory above it.');
        }
        if (is_file($projectPath . '/vendor/autoload.php')) {
            require_once $projectPath . '/vendor/autoload.php';
        }

        $this->prepareRequest($config);
        if (!defined('WP_USE_THEMES')) {
            define('WP_USE_THEMES', false);
        }
        $inspector = Inspector::current();
        if ($inspector !== null && $inspector->isEnabled() && !defined('SAVEQUERIES') && strpos((string) @file_get_contents($config), 'SAVEQUERIES') === false) {
            // Query timings for Runlet's inspector come from WordPress's own query log. Left
            // alone when wp-config.php sets SAVEQUERIES itself.
            define('SAVEQUERIES', true);
        }
        $guard = $this->installBootstrapHooks();
        self::installTimingHooks();

        self::load($loader);

        if (function_exists('remove_filter')) {
            remove_filter('nocache_headers', $guard, 10);
        }
        self::$bootMarks['loaded'] = microtime(true);
        // The admin APIs (get_plugins(), wp_delete_post() helpers, ...), as WP-CLI loads them.
        if (defined('ABSPATH') && is_file(ABSPATH . 'wp-admin/includes/admin.php')) {
            require_once ABSPATH . 'wp-admin/includes/admin.php';
        }
        self::$bootMarks['admin'] = microtime(true);
        self::logBootTimings();
    }

    /**
     * Records WordPress's load milestones (the earliest callback on each) and the time each
     * plugin file took, for the Run Log. Hooks that never fire leave gaps the summary skips.
     */
    private static function installTimingHooks(): void
    {
        self::$bootMarks = ['start' => microtime(true)];
        self::$pluginTimes = [];
        foreach (['muplugins_loaded', 'plugins_loaded', 'setup_theme', 'after_setup_theme', 'init', 'wp_loaded'] as $hook) {
            self::addFilter($hook, static function ($value = null) use ($hook) {
                if (!isset(self::$bootMarks[$hook])) {
                    self::$bootMarks[$hook] = microtime(true);
                }
                if ($hook === 'muplugins_loaded') {
                    self::$lastPluginMark = self::$bootMarks[$hook];
                }

                return $value;
            }, -1000000);
        }
        self::addFilter('plugin_loaded', static function ($plugin = null) {
            $now = microtime(true);
            $since = self::$lastPluginMark > 0 ? self::$lastPluginMark : $now;
            $name = is_string($plugin) ? self::pluginName($plugin) : '?';
            self::$pluginTimes[$name] = (self::$pluginTimes[$name] ?? 0) + ($now - $since);
            self::$lastPluginMark = $now;

            return $plugin;
        });
    }

    /** "sitepress-multilingual-cms" for wp-content/plugins/sitepress-multilingual-cms/sitepress.php. */
    private static function pluginName(string $file): string
    {
        $root = defined('WP_PLUGIN_DIR') ? rtrim((string) WP_PLUGIN_DIR, '/') . '/' : '';
        $relative = $root !== '' && strpos($file, $root) === 0 ? substr($file, strlen($root)) : basename($file);
        $slash = strpos($relative, '/');

        return $slash === false ? basename($relative, '.php') : substr($relative, 0, $slash);
    }

    /** One Run Log line: where WordPress's boot time went, the slowest plugins, and the opcode cache. */
    private static function logBootTimings(): void
    {
        $marks = self::$bootMarks;
        $phases = [
            'core & must-use plugins' => ['start', 'muplugins_loaded'],
            'plugins' => ['muplugins_loaded', 'plugins_loaded'],
            'plugins_loaded hooks' => ['plugins_loaded', 'setup_theme'],
            'theme' => ['setup_theme', 'after_setup_theme'],
            'user & init setup' => ['after_setup_theme', 'init'],
            'init hooks' => ['init', 'wp_loaded'],
            'wp_loaded hooks' => ['wp_loaded', 'loaded'],
            'admin APIs' => ['loaded', 'admin'],
        ];
        $parts = [];
        foreach ($phases as $label => [$from, $to]) {
            if (isset($marks[$from], $marks[$to])) {
                $parts[] = $label . ' ' . (int) round(($marks[$to] - $marks[$from]) * 1000) . ' ms';
            }
        }
        $total = isset($marks['start'], $marks['admin']) ? (int) round(($marks['admin'] - $marks['start']) * 1000) : null;
        $details = [];
        if (self::$pluginTimes !== []) {
            arsort(self::$pluginTimes);
            $slowest = [];
            foreach (array_slice(self::$pluginTimes, 0, 8, true) as $name => $seconds) {
                $slowest[] = $name . ' ' . (int) round($seconds * 1000) . ' ms';
            }
            $details[] = count(self::$pluginTimes) . ' plugins; slowest to load: ' . implode(' · ', $slowest);
        }
        $files = count(get_included_files());
        $cacheOn = function_exists('opcache_get_status') && (bool) ini_get('opcache.enable') && (bool) ini_get('opcache.enable_cli');
        $fileCache = (string) ini_get('opcache.file_cache');
        $details[] = $cacheOn
            ? 'opcode cache: on for the command line' . ($fileCache !== '' ? ', file cache in ' . $fileCache : '') . ' (' . $files . ' files loaded)'
            : 'opcode cache: off for the command line (opcache.enable_cli), so every run compiles all ' . $files . ' files; web requests keep them compiled';
        \RunletRunner\Runner::log('driver', 'WordPress boot' . ($total !== null ? ' ' . $total . ' ms' : '') . ': ' . implode(' · ', $parts), implode("\n", $details));
    }

    /** @return array<string, mixed> */
    public function variables(): array
    {
        return isset($GLOBALS['wpdb']) ? ['wpdb' => $GLOBALS['wpdb']] : [];
    }

    /** SQL tabs (#35): $wpdb, WordPress's only connection. */
    public function sqlConnection(?string $connection)
    {
        $wpdb = $GLOBALS['wpdb'] ?? null;
        if (!is_object($wpdb) || !method_exists($wpdb, 'query')) {
            return null;
        }
        if ($connection !== null && $connection !== 'wpdb') {
            throw new \InvalidArgumentException('WordPress has one database connection ($wpdb), not "' . $connection . '". Choose the default connection.');
        }

        return SqlConnections::wpdb($wpdb);
    }

    public function bootstrapExitHint(): ?string
    {
        $redirect = self::$bootRedirect;
        if ($redirect === null) {
            return null;
        }
        $text = 'WordPress redirected to ' . $redirect['location'] . ' (' . $redirect['status'] . ')'
            . ($redirect['caller'] !== '' ? ', sent from ' . $redirect['caller'] : '') . ', then exited.';
        if (strpos($redirect['location'], 'wp-admin/install.php') !== false) {
            $text .= ' WordPress found no installation in the database wp-config.php points to: check DB_NAME, DB_HOST, and $table_prefix as PHP on the command line sees them (environment variables, a different DB_HOST than the web server).';
        } elseif (strpos($redirect['location'], 'https://') === 0) {
            $text .= ' Runlet presents the site\'s host and scheme from WP_HOME / WP_SITEURL, or from the home option once the database is up; code that redirects earlier than that (a drop-in, a must-use plugin) still sees http://localhost. Define WP_HOME (https://your-host) in wp-config.php, or let the redirect skip the CLI (php_sapi_name() === \'cli\').';
        }

        return $text;
    }

    public function version(): ?string
    {
        return isset($GLOBALS['wp_version']) ? (string) $GLOBALS['wp_version'] : null;
    }

    /**
     * wp_get_environment_type() (WordPress 5.5+): WP_ENVIRONMENT_TYPE from the environment
     * or wp-config.php, and "production" when neither sets it.
     *
     * @return string|null
     */
    public function environment()
    {
        return function_exists('wp_get_environment_type') ? (string) \wp_get_environment_type() : null;
    }

    /** The wp-load.php to use, or null when the project is not WordPress. */
    protected function locateLoader(string $projectPath): ?string
    {
        foreach (self::LOADERS as $candidate) {
            if (is_file($projectPath . '/' . $candidate)) {
                return $projectPath . '/' . $candidate;
            }
        }

        return null;
    }

    /**
     * Request defaults for a CLI process, so WordPress and plugins find the usual
     * $_SERVER keys. A multisite's main site is taken from DOMAIN_CURRENT_SITE when
     * wp-config.php defines it literally; otherwise set $_SERVER['HTTP_HOST'] in a project
     * driver before calling parent::bootstrap().
     */
    protected function prepareRequest(string $configFile): void
    {
        $url = null;
        $source = null;
        if (!isset($_SERVER['HTTP_HOST'])) {
            // The site's real URL, so canonical-host and force-HTTPS code (page caches such as
            // W3 Total Cache, which cache the host before any hook runs; SSL plugins) sees the
            // request it expects: remembered from an earlier run while wp-config.php is
            // unchanged, else wp-config.php evaluated like WP-CLI does, else read as text.
            $stamp = @filemtime($configFile) . ':' . @filesize($configFile) . ' ';
            $remembered = \RunletRunner\Runner::recalled('wordpress.siteUrl');
            if ($remembered !== null && strpos($remembered, $stamp) === 0 && strlen($remembered) > strlen($stamp)) {
                [$url, $source] = [substr($remembered, strlen($stamp)), 'remembered for this session (wp-config.php unchanged)'];
            } else {
                [$url, $source] = self::probeSiteUrl($configFile);
                if ($url === null) {
                    [$url, $source] = self::staticSiteUrl($configFile, $source);
                }
                if ($url !== null) {
                    \RunletRunner\Runner::remember('wordpress.siteUrl', $stamp . $url);
                }
            }
        }
        $parts = $url === null ? null : parse_url($url);
        $https = is_array($parts) && ($parts['scheme'] ?? 'http') === 'https';
        $hostName = is_array($parts) && isset($parts['host']) && $parts['host'] !== '' ? $parts['host'] : 'localhost';
        $host = $hostName . (is_array($parts) && isset($parts['port']) ? ':' . $parts['port'] : '');
        $path = is_array($parts) && isset($parts['path']) && $parts['path'] !== '' ? rtrim($parts['path'], '/') . '/' : '/';
        $defaults = [
            'HTTP_HOST' => $host,
            'SERVER_NAME' => $hostName,
            'REQUEST_URI' => $path,
            'REQUEST_METHOD' => 'GET',
            'SERVER_PROTOCOL' => 'HTTP/1.1',
            'SERVER_PORT' => is_array($parts) && isset($parts['port']) ? (string) $parts['port'] : ($https ? '443' : '80'),
            'REMOTE_ADDR' => '127.0.0.1',
            'HTTP_USER_AGENT' => 'Runlet',
        ];
        if ($https) {
            $defaults['HTTPS'] = 'on';
        }
        self::$hostFromDatabase = $hostName === 'localhost' && !isset($_SERVER['HTTP_HOST']);
        $preset = isset($_SERVER['HTTP_HOST']);
        foreach ($defaults as $key => $value) {
            if (!isset($_SERVER[$key])) {
                $_SERVER[$key] = $value;
            }
        }
        $scheme = ($_SERVER['HTTPS'] ?? '') === 'on' ? 'https' : 'http';
        \RunletRunner\Runner::log('driver', 'WordPress request: ' . $scheme . '://' . $_SERVER['HTTP_HOST'] . $_SERVER['REQUEST_URI'],
            $preset ? 'HTTP_HOST was already set' : ($url !== null ? 'from ' . $source : 'defaults to localhost: ' . ($source ?? 'no site URL found in wp-config.php or the database')));
    }

    /**
     * Evaluates wp-config.php in a separate PHP process, as WP-CLI does: the line that loads
     * wp-settings.php is removed (so WordPress itself doesn't load there), `__DIR__` and
     * `__FILE__` point at the real file, and output is discarded. Reports the WP_HOME /
     * WP_SITEURL / DOMAIN_CURRENT_SITE that really apply (conditionals, environment
     * variables, included files), else reads `home` from the database with the real settings.
     *
     * @return array{0: string|null, 1: string|null} the URL and where it came from, or why not
     */
    private static function probeSiteUrl(string $configFile): array
    {
        if (!function_exists('proc_open') || PHP_BINARY === '' || !is_executable(PHP_BINARY)) {
            return [null, 'could not start a PHP process to evaluate wp-config.php'];
        }
        $command = [PHP_BINARY, '-d', 'display_errors=0', '-d', 'log_errors=0', '-r', self::CONFIG_PROBE, '--', $configFile];
        $process = @proc_open($command, [0 => ['file', '/dev/null', 'r'], 1 => ['pipe', 'w'], 2 => ['file', '/dev/null', 'w']], $pipes, dirname($configFile));
        if (!is_resource($process)) {
            return [null, 'could not start a PHP process to evaluate wp-config.php'];
        }
        stream_set_blocking($pipes[1], false);
        $output = '';
        $deadline = microtime(true) + 8;
        while (!feof($pipes[1]) && microtime(true) < $deadline) {
            $read = [$pipes[1]];
            $write = $except = null;
            if (@stream_select($read, $write, $except, 0, 200000) > 0) {
                $output .= (string) fread($pipes[1], 65536);
            }
        }
        $timedOut = !feof($pipes[1]);
        fclose($pipes[1]);
        if ($timedOut) {
            proc_terminate($process, 9);
        }
        proc_close($process);
        $marker = strrpos($output, "\x1eRUNLET_WPCONFIG");
        $result = $marker === false ? null : json_decode(substr($output, $marker + 16), true);
        if (!is_array($result)) {
            return [null, $timedOut ? 'evaluating wp-config.php took longer than 8 s' : 'evaluating wp-config.php reported nothing'];
        }
        if (isset($result['url']) && is_string($result['url']) && $result['url'] !== '') {
            return [$result['url'], (string) ($result['source'] ?? 'wp-config.php')];
        }

        return [null, isset($result['skipped']) ? (string) $result['skipped'] : 'wp-config.php defines no site URL and the home option could not be read'];
    }

    /** Runs in the probe process (see probeSiteUrl); prints a marker and JSON at the end. */
    private const CONFIG_PROBE = <<<'PHP'
error_reporting(0);
$config = (string) end($argv);
$out = [];
$code = @file_get_contents($config);
if (is_string($code)) {
    $code = preg_replace('/\b(?:require|include)(?:_once)?\b[^;]*wp-settings\.php[^;]*;/i', ';', $code, -1, $count);
    if ($count > 0) {
        $code = str_replace(['__FILE__', '__DIR__'], [var_export($config, true), var_export(dirname($config), true)], (string) $code);
        if (!defined('ABSPATH')) {
            define('ABSPATH', dirname($config) . '/');
        }
        ob_start();
        try {
            eval('?>' . $code);
        } catch (\Throwable $error) {
            $out['error'] = get_class($error) . ': ' . $error->getMessage();
        }
        ob_end_clean();
        if (defined('WP_HOME') && (string) WP_HOME !== '') {
            $out = ['url' => (string) WP_HOME, 'source' => 'WP_HOME (wp-config.php, evaluated)'];
        } elseif (defined('WP_SITEURL') && (string) WP_SITEURL !== '') {
            $out = ['url' => (string) WP_SITEURL, 'source' => 'WP_SITEURL (wp-config.php, evaluated)'];
        } elseif (defined('DOMAIN_CURRENT_SITE')) {
            $out = ['url' => 'http://' . DOMAIN_CURRENT_SITE . (defined('PATH_CURRENT_SITE') ? PATH_CURRENT_SITE : '/'), 'source' => 'DOMAIN_CURRENT_SITE (wp-config.php, evaluated)'];
        } elseif (defined('DB_NAME') && defined('DB_USER') && class_exists('mysqli')) {
            $host = defined('DB_HOST') ? (string) DB_HOST : 'localhost';
            $port = null;
            $socket = null;
            if (preg_match('/^(.*?):(\/.+)$/', $host, $match)) {
                [$host, $socket] = [$match[1] === '' ? 'localhost' : $match[1], $match[2]];
            } elseif (preg_match('/^(.+):(\d+)$/', $host, $match)) {
                [$host, $port] = [$match[1], (int) $match[2]];
            }
            $prefix = isset($table_prefix) && is_string($table_prefix) && preg_match('/^[A-Za-z0-9_]+$/', $table_prefix) ? $table_prefix : 'wp_';
            mysqli_report(MYSQLI_REPORT_OFF);
            $link = mysqli_init();
            if ($link !== false) {
                $link->options(MYSQLI_OPT_CONNECT_TIMEOUT, 3);
                if (@$link->real_connect($host, (string) DB_USER, defined('DB_PASSWORD') ? (string) DB_PASSWORD : '', (string) DB_NAME, $port, $socket)) {
                    $result = $link->query("SELECT option_name, option_value FROM `{$prefix}options` WHERE option_name IN ('home', 'siteurl')");
                    $values = [];
                    if ($result instanceof mysqli_result) {
                        while ($row = $result->fetch_assoc()) {
                            $values[$row['option_name']] = (string) $row['option_value'];
                        }
                    }
                    $link->close();
                    $home = $values['home'] ?? ($values['siteurl'] ?? '');
                    if ($home !== '') {
                        $out = ['url' => $home, 'source' => 'the home option (database settings from wp-config.php, evaluated)'];
                    } else {
                        $out['skipped'] = 'the database has no home option in ' . $prefix . 'options';
                    }
                } else {
                    $out['skipped'] = 'could not connect to the database wp-config.php points to';
                }
            }
        } else {
            $out['skipped'] = 'wp-config.php defines no site URL or database settings';
        }
    } else {
        $out['skipped'] = 'wp-config.php does not load wp-settings.php itself, so it was not evaluated';
    }
}
echo "\x1eRUNLET_WPCONFIG" . json_encode($out);
PHP;

    /**
     * Reads wp-config.php as text (comments removed): WP_HOME / WP_SITEURL /
     * DOMAIN_CURRENT_SITE, else `home` from the database with literal settings. Used when the
     * probe can't run. Conditional definitions can't be told apart here.
     *
     * @return array{0: string|null, 1: string|null}
     */
    private static function staticSiteUrl(string $configFile, ?string $why): array
    {
        $config = self::withoutComments((string) @file_get_contents($configFile));
        if (preg_match('/define\(\s*[\'"](?:WP_HOME|WP_SITEURL)[\'"]\s*,\s*[\'"](https?:\/\/[^\'"]+)[\'"]/', $config, $match)) {
            return [$match[1], 'WP_HOME / WP_SITEURL (wp-config.php, read as text)'];
        }
        if (preg_match('/define\(\s*[\'"]DOMAIN_CURRENT_SITE[\'"]\s*,\s*[\'"]([^\'"]+)[\'"]/', $config, $match)) {
            $path = preg_match('/define\(\s*[\'"]PATH_CURRENT_SITE[\'"]\s*,\s*[\'"]([^\'"]+)[\'"]/', $config, $pathMatch) ? $pathMatch[1] : '/';

            return ['http://' . $match[1] . $path, 'DOMAIN_CURRENT_SITE (wp-config.php, read as text)'];
        }
        $home = self::homeFromDatabase($config);
        if ($home !== null) {
            return [$home, 'the home option (read before loading WordPress)'];
        }

        return [null, $why];
    }

    /** PHP source without comments, so commented-out definitions are ignored. */
    private static function withoutComments(string $code): string
    {
        if (!function_exists('token_get_all')) {
            return $code;
        }
        $out = '';
        foreach (@token_get_all($code) as $token) {
            if (is_array($token)) {
                if ($token[0] !== T_COMMENT && $token[0] !== T_DOC_COMMENT) {
                    $out .= $token[1];
                }
            } else {
                $out .= $token;
            }
        }

        return $out;
    }

    /**
     * wp-config.php's literal database settings: DB_NAME, DB_USER, DB_PASSWORD, DB_HOST, and
     * $table_prefix. Null when any of the first three is not a plain string (environment
     * variables, constants built from other values), or for multisite.
     *
     * @return array{name: string, user: string, password: string, host: string, prefix: string}|null
     */
    public static function databaseSettings(string $config): ?array
    {
        if (preg_match('/define\(\s*[\'"]MULTISITE[\'"]\s*,\s*true/i', $config)) {
            return null;
        }
        $literal = static function (string $name) use ($config): ?string {
            if (preg_match('/define\(\s*[\'"]' . $name . '[\'"]\s*,\s*\'((?:[^\'\\\\]|\\\\.)*)\'\s*\)/', $config, $match)) {
                return str_replace(['\\\'', '\\\\'], ['\'', '\\'], $match[1]);
            }
            if (preg_match('/define\(\s*[\'"]' . $name . '[\'"]\s*,\s*"([^"$\\\\]*)"\s*\)/', $config, $match)) {
                return $match[1];
            }

            return null;
        };
        $name = $literal('DB_NAME');
        $user = $literal('DB_USER');
        $password = $literal('DB_PASSWORD');
        if ($name === null || $user === null || $password === null) {
            return null;
        }
        $prefix = preg_match('/\$table_prefix\s*=\s*[\'"]([A-Za-z0-9_]+)[\'"]\s*;/', $config, $match) ? $match[1] : 'wp_';

        return ['name' => $name, 'user' => $user, 'password' => $password, 'host' => $literal('DB_HOST') ?? 'localhost', 'prefix' => $prefix];
    }

    /** The `home` option (else `siteurl`) read with mysqli before WordPress loads; null on any failure. */
    private static function homeFromDatabase(string $config): ?string
    {
        $settings = self::databaseSettings($config);
        if ($settings === null || !class_exists('mysqli')) {
            return null;
        }
        // DB_HOST: "host", "host:port", "host:/path/to.sock", or ":/path/to.sock".
        $host = $settings['host'];
        $port = null;
        $socket = null;
        if (preg_match('/^(.*?):(\/.+)$/', $host, $match)) {
            [$host, $socket] = [$match[1] === '' ? 'localhost' : $match[1], $match[2]];
        } elseif (preg_match('/^(.+):(\d+)$/', $host, $match)) {
            [$host, $port] = [$match[1], (int) $match[2]];
        }
        try {
            if (function_exists('mysqli_report')) {
                mysqli_report(MYSQLI_REPORT_OFF);
            }
            $link = mysqli_init();
            if ($link === false) {
                return null;
            }
            $link->options(MYSQLI_OPT_CONNECT_TIMEOUT, 3);
            if (!@$link->real_connect($host, $settings['user'], $settings['password'], $settings['name'], $port, $socket)) {
                return null;
            }
            $result = $link->query("SELECT option_name, option_value FROM `" . $settings['prefix'] . "options` WHERE option_name IN ('home', 'siteurl')");
            $values = [];
            if ($result instanceof \mysqli_result) {
                while ($row = $result->fetch_assoc()) {
                    $values[$row['option_name']] = (string) $row['option_value'];
                }
                $result->free();
            }
            $link->close();
            $home = $values['home'] ?? ($values['siteurl'] ?? '');

            return $home !== '' ? $home : null;
        } catch (\Throwable $ignored) {
            return null;
        }
    }

    /**
     * Filters registered before WordPress loads (WordPress turns pre-filled $wp_filter
     * entries into hooks). Returns the bootstrap-only nocache_headers guard.
     */
    private function installBootstrapHooks(): \Closure
    {
        $false = static function (): bool {
            return false;
        };
        // WordPress's own fatal-error handler would print an HTML error page, pause the
        // plugin, and possibly email a recovery-mode link after a snippet's fatal error.
        self::addFilter('wp_fatal_error_handler_enabled', $false);
        // Page-cache drop-ins and maintenance mode can serve a page and exit.
        self::addFilter('enable_loading_advanced_cache_dropin', $false);
        self::addFilter('enable_maintenance_mode', $false);
        self::addFilter('ms_site_check', static function (): bool {
            return true;
        });
        // Without WP_HOME / WP_SITEURL / DOMAIN_CURRENT_SITE, the site's real URL lives in the
        // database: once it is connected (after must-use plugins, before regular plugins load),
        // present the `home` option's host and scheme, so canonical-host and force-HTTPS code
        // (page caches such as W3 Total Cache, SSL plugins) doesn't redirect and exit.
        self::addFilter('muplugins_loaded', static function (): void {
            if (!self::$hostFromDatabase || !function_exists('get_option')) {
                return;
            }
            self::$hostFromDatabase = false;
            $home = (string) get_option('home');
            $parts = parse_url($home !== '' ? $home : (string) get_option('siteurl'));
            if (!is_array($parts) || !isset($parts['host']) || $parts['host'] === '') {
                return;
            }
            $https = ($parts['scheme'] ?? 'http') === 'https';
            $_SERVER['HTTP_HOST'] = $parts['host'] . (isset($parts['port']) ? ':' . $parts['port'] : '');
            $_SERVER['SERVER_NAME'] = $parts['host'];
            $_SERVER['SERVER_PORT'] = isset($parts['port']) ? (string) $parts['port'] : ($https ? '443' : '80');
            $_SERVER['REQUEST_URI'] = isset($parts['path']) && $parts['path'] !== '' ? rtrim($parts['path'], '/') . '/' : '/';
            if ($https) {
                $_SERVER['HTTPS'] = 'on';
            }
            \RunletRunner\Runner::log('driver', 'WordPress request: ' . ($https ? 'https' : 'http') . '://' . $_SERVER['HTTP_HOST'] . $_SERVER['REQUEST_URI'], 'from the home option in the database (before plugins load)');
        });
        // A run should not spawn WP-Cron (an HTTP request to the site and a lock write at
        // shutdown, or a redirect with ALTERNATE_WP_CRON). Snippets can still call wp_cron().
        self::addFilter('muplugins_loaded', static function (): void {
            remove_action('init', 'wp_cron');
        });
        // A redirect during bootstrap (not installed → install.php, a forced HTTPS or canonical
        // host, a login wall) is followed by exit(): remember it and who sent it.
        self::addFilter('wp_redirect', static function ($location, $status = 302) {
            $caller = '';
            foreach (debug_backtrace(DEBUG_BACKTRACE_IGNORE_ARGS) as $frame) {
                $file = $frame['file'] ?? '';
                if ($file !== '' && strpos($file, '/wp-includes/') === false && ($frame['function'] ?? '') !== 'apply_filters') {
                    $caller = $file . ':' . ($frame['line'] ?? 0);
                    break;
                }
            }
            self::$bootRedirect = ['location' => (string) $location, 'status' => (int) $status, 'caller' => $caller];
            \RunletRunner\Runner::log('driver', 'WordPress redirect to ' . $location . ' (' . (int) $status . ')', $caller === '' ? null : 'from ' . $caller);

            return $location;
        });
        // wp_die() prints an HTML page and exits; report its message as an exception instead.
        self::addFilter('wp_die_handler', static function () {
            return static function ($message, $title = '', $args = []): void {
                if (is_object($message) && method_exists($message, 'get_error_message')) {
                    $message = $message->get_error_message();
                }
                $text = is_scalar($message) ? (string) $message : '';
                if ($text === '' && is_scalar($title)) {
                    $text = (string) $title;
                }
                $text = trim(html_entity_decode(strip_tags($text), ENT_QUOTES));

                throw new \RuntimeException('wp_die(): ' . ($text === '' ? 'WordPress stopped the request.' : $text));
            };
        });
        // While loading, nocache_headers() means WordPress is about to redirect and exit
        // because its database is unreachable or it is not installed.
        $guard = static function ($headers) {
            $wpdb = $GLOBALS['wpdb'] ?? null;
            if (is_object($wpdb) && !empty($wpdb->error)) {
                $error = $wpdb->error;
                if (is_object($error) && method_exists($error, 'get_error_message')) {
                    $error = $error->get_error_message();
                }
                throw new \RuntimeException('WordPress could not use its database: ' . trim(strip_tags(is_scalar($error) ? (string) $error : 'unknown error')));
            }
            $installing = function_exists('wp_installing') && wp_installing();
            if (!$installing && function_exists('is_blog_installed') && !is_blog_installed()) {
                throw new \RuntimeException('WordPress is not installed in its database yet. Finish the installation first (for example with `wp core install`).');
            }

            return $headers;
        };
        self::addFilter('nocache_headers', $guard);

        return $guard;
    }

    private static function addFilter(string $hook, callable $callback, int $priority = 10): void
    {
        if (function_exists('add_filter')) {
            add_filter($hook, $callback, $priority, 1);

            return;
        }
        $GLOBALS['wp_filter'][$hook][$priority][] = ['function' => $callback, 'accepted_args' => 1];
    }

    /** Mirrors wp-load.php's lookup: ABSPATH/wp-config.php, or one level up (Bedrock). */
    private static function configFile(string $abspath): ?string
    {
        if (is_file($abspath . '/wp-config.php')) {
            return $abspath . '/wp-config.php';
        }
        $parent = dirname($abspath);
        if (is_file($parent . '/wp-config.php') && !is_file($parent . '/wp-settings.php')) {
            return $parent . '/wp-config.php';
        }

        return null;
    }

    private static function load(string $__runletLoader): void
    {
        foreach (self::WORDPRESS_GLOBALS as $__runletName) {
            global $$__runletName;
        }
        unset($__runletName);
        $__runletBefore = get_defined_vars();

        require $__runletLoader;

        // Anything else WordPress, wp-config.php, or a plugin defined at "file scope" would
        // have been global in a web request.
        foreach (get_defined_vars() as $__runletName => $__runletValue) {
            if ($__runletName !== '__runletBefore' && !array_key_exists($__runletName, $__runletBefore)) {
                $GLOBALS[$__runletName] = $__runletValue;
            }
        }
    }
}

/**
 * Symfony (Flex skeleton or classic): loads the .env files like the Runtime component,
 * then boots the kernel. Snippets get $kernel and $container.
 */
class SymfonyDriver extends ComposerDriver
{
    /** @var object|null The booted kernel. */
    protected $kernel;

    public function name(): string
    {
        return 'Symfony';
    }

    public function canBootstrap(string $projectPath): bool
    {
        return is_file($projectPath . '/bin/console')
            && (is_file($projectPath . '/src/Kernel.php') || is_file($projectPath . '/config/bundles.php'));
    }

    public function bootstrap(string $projectPath): void
    {
        $this->requireAutoloader($projectPath);
        $this->loadEnvironment($projectPath);

        $class = $this->kernelClass($projectPath);
        $environment = (string) ($_SERVER['APP_ENV'] ?? $_ENV['APP_ENV'] ?? 'dev');
        $debug = $_SERVER['APP_DEBUG'] ?? $_ENV['APP_DEBUG'] ?? ($environment !== 'prod');
        $kernel = new $class($environment, (bool) $debug);
        $kernel->boot();
        $this->kernel = $kernel;
    }

    /** @return array<string, mixed> */
    public function variables(): array
    {
        if (!is_object($this->kernel)) {
            return [];
        }

        return ['kernel' => $this->kernel, 'container' => $this->kernel->getContainer()];
    }

    /**
     * Doctrine DBAL connections from the `doctrine` registry and mail sent through Symfony
     * Mailer (intercepted with MessageEvent::reject(), Symfony 6.3+), plus the automatic
     * detection every driver has.
     */
    public function inspect(Inspector $inspector): void
    {
        parent::inspect($inspector);
        if (!is_object($this->kernel)) {
            return;
        }
        $container = $this->kernel->getContainer();
        if ($container->has('doctrine')) {
            $registry = $container->get('doctrine');
            if (is_object($registry) && method_exists($registry, 'getConnectionNames')) {
                foreach (array_keys($registry->getConnectionNames()) as $name) {
                    // Getting a connection creates the service; DBAL connects on first use.
                    $this->inspectDoctrine($inspector, $registry->getConnection($name), (string) $name);
                }
            }
        }
        $messageEvent = 'Symfony\Component\Mailer\Event\MessageEvent';
        if ($container->has('event_dispatcher') && class_exists($messageEvent) && $inspector->once('symfony-mailer')) {
            $intercept = $inspector->shouldInterceptMail() && method_exists($messageEvent, 'reject');
            $inspector->section(Inspector::MAIL);
            // After the listeners that render templated emails.
            $container->get('event_dispatcher')->addListener($messageEvent, static function ($event) use ($inspector, $intercept): void {
                $queued = method_exists($event, 'isQueued') && $event->isQueued();
                $inspector->mail($event->getMessage(), $queued ? ['queued' => true, 'mailer' => $event->getTransport()] : ['intercepted' => $intercept, 'mailer' => $event->getTransport()]);
                if ($intercept && !$queued) {
                    $event->reject();
                }
            }, -1024);
            if ($intercept) {
                $inspector->interceptingMail();
            }
        }
    }

    /** SQL tabs (#35): the named (or default) connection of the `doctrine` registry. */
    public function sqlConnection(?string $connection)
    {
        $registry = $this->doctrine();

        return $registry === null ? null : SqlConnections::doctrine($registry->getConnection($connection));
    }

    /** SQL tabs (#35): the `doctrine` registry's connection names, the default first. */
    public function sqlConnections(): array
    {
        $registry = $this->doctrine();
        if ($registry === null || !method_exists($registry, 'getConnectionNames')) {
            return [];
        }
        $names = array_map('strval', array_keys($registry->getConnectionNames()));
        $default = method_exists($registry, 'getDefaultConnectionName') ? (string) $registry->getDefaultConnectionName() : '';
        if ($default !== '' && in_array($default, $names, true)) {
            $names = array_merge([$default], array_values(array_diff($names, [$default])));
        }

        return $names;
    }

    /** @return object|null The `doctrine` registry, when DoctrineBundle is installed. */
    private function doctrine()
    {
        if (!is_object($this->kernel)) {
            return null;
        }
        $container = $this->kernel->getContainer();

        return $container->has('doctrine') ? $container->get('doctrine') : null;
    }

    public function version(): ?string
    {
        $constant = 'Symfony\Component\HttpKernel\Kernel::VERSION';

        return defined($constant) ? (string) constant($constant) : null;
    }

    /**
     * The kernel's environment (APP_ENV: dev, test, prod, …).
     *
     * @return string|null
     */
    public function environment()
    {
        return is_object($this->kernel) && method_exists($this->kernel, 'getEnvironment') ? (string) $this->kernel->getEnvironment() : null;
    }

    /** Every visible `bin/console` command of the booted kernel, as `php bin/console <name>`. */
    public function commands(): array
    {
        $application = 'Symfony\Bundle\FrameworkBundle\Console\Application';
        if (!is_object($this->kernel) || !class_exists($application)) {
            return [];
        }
        $console = new $application($this->kernel);

        return $this->consoleCommands($console->all(), 'php bin/console');
    }

    /** Loads .env, .env.local, .env.<env>, ... (Symfony 5.1+ bootEnv; config/bootstrap.php on 4.x). */
    protected function loadEnvironment(string $projectPath): void
    {
        if (is_file($projectPath . '/config/bootstrap.php')) {
            require $projectPath . '/config/bootstrap.php';

            return;
        }
        $dotenv = 'Symfony\Component\Dotenv\Dotenv';
        if (!class_exists($dotenv) || (!is_file($projectPath . '/.env') && !is_file($projectPath . '/.env.dist'))) {
            return;
        }
        if (method_exists($dotenv, 'bootEnv')) {
            (new $dotenv())->bootEnv($projectPath . '/.env');
        } elseif (method_exists($dotenv, 'loadEnv')) {
            (new $dotenv())->loadEnv($projectPath . '/.env');
        }
    }

    /** The kernel class declared in src/Kernel.php (App\Kernel by default). */
    protected function kernelClass(string $projectPath): string
    {
        $source = @file_get_contents($projectPath . '/src/Kernel.php');
        if (is_string($source) && preg_match('/^\s*namespace\s+([A-Za-z0-9_\\\\]+)\s*;/m', $source, $match) && class_exists($match[1] . '\Kernel')) {
            return $match[1] . '\Kernel';
        }
        if (class_exists('App\Kernel')) {
            return 'App\Kernel';
        }

        throw new \RuntimeException('Runlet could not find the Symfony kernel (expected App\Kernel in src/Kernel.php). Add a project driver in .runlet/ to boot this application.');
    }
}
