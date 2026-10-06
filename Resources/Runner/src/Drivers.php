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
 * environment(), and then inspect() and casters() (and, for a dry run, rollbackConnections())
 * before a snippet runs, commands() when it lists the project's commands instead, or panels()
 * for App Info. Each run is a fresh PHP process, so a
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
     * Where this application writes its logs (#20), for Runlet's log viewer (View > Logs):
     * paths relative to the project, or absolute as the application sees them (inside its
     * container or on its server). Each is a file, a folder (its `*.log` files are listed), or
     * a pattern with `*` in its last part:
     *
     *     return ['storage/logs/worker.log', 'var/log', 'logs/app-*.log'];
     *
     * Runlet lists these before the files it finds by itself (Laravel's storage/logs, Symfony's
     * var/log, WordPress's wp-content/debug.log). Called before bootstrap(), when Runlet lists
     * the project's commands: return declarations only, without running anything. The log
     * viewer reads the files themselves and never calls this method.
     *
     * @return array<int, string>
     */
    public function logPaths(): array
    {
        return [];
    }

    /**
     * Experimental and not documented yet: the shape of this hook may change before it is.
     *
     * Extra tabs in Runlet's inspector, next to History, Snippets, Commands, and Database.
     * Each tab lists rows with a command that runs on the Mac, in the project's folder there
     * (like hostCommands()), and can start a long-running command per row in a terminal:
     *
     *     return [[
     *         'id' => 'workers',            // unique within the driver
     *         'title' => 'Workers',
     *         'icon' => 'tray.full',        // optional SF Symbol
     *         'list' => 'mytool workers --json',
     *         'run' => 'mytool work {id}',  // {id}: the row's id, shell-quoted
     *         'empty' => 'Nothing to do.',  // optional
     *         // Optional, at most 6: a filter with a tag shows the rows whose tags have it.
     *         'filters' => [
     *             ['id' => 'busy', 'title' => 'Busy', 'tag' => 'busy', 'default' => true],
     *             ['id' => 'all', 'title' => 'All'],
     *         ],
     *     ]];
     *
     * `list` is a command on the Mac that prints {"items": [{"id", "title", "subtitle"?,
     * "badge"?, "tags"?}], "message"?}, or a PHP callable (a closure, `[$this, 'method']`, or a
     * 'Class::method' string) that returns the same as an array, or just the items: Runlet
     * then boots the project, like for App Info, and calls it. Items hold strings and numbers
     * only. Runlet lists a tab when it appears and on Refresh, and runs `run` in a terminal
     * tab when a row is started; stopping a row sends it Ctrl-C. inspectorTabs() is called
     * before bootstrap(), when Runlet lists the project's commands: return declarations only,
     * without running anything (a callable runs only when the tab lists).
     *
     * @return array<int, array{id: string, title: string, icon?: string|null, list: string|callable, run: string, empty?: string|null, filters?: array<int, array{id: string, title: string, tag?: string, default?: bool}>}>
     */
    public function inspectorTabs(): array
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
     *    that the project has no SQL connection. The application's own connections need no
     *    credentials from Runlet; a user can also save a connection for the target (#138),
     *    which runs without booting the project and never calls this method.
     *
     * Throw to report a problem, such as an unknown connection name: the tab shows the
     * message. Called after bootstrap(), only when an SQL tab runs. The built-in drivers
     * return the application's own connection (Laravel's DB::connection(), Symfony's
     * Doctrine registry, WordPress's PDO from wp-config.php or else $wpdb, #208);
     * SqlConnections has helpers for your own.
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
     * Redis tabs (#190): how a command from a Redis tab reaches this application's Redis.
     * `$connection` is the name chosen in the tab, or null for the default connection. Return
     * a phpredis \Redis, a Predis client, a Laravel Redis connection, a callable
     * `function (array $argv)` that sends the command and returns its reply, or null when this
     * driver has no Redis connection. Called after bootstrap(), only when a Redis tab runs. The
     * built-in Laravel driver returns Redis::connection($connection). A saved Redis connection
     * never calls it.
     *
     * @return mixed
     */
    public function redisConnection(?string $connection)
    {
        return null;
    }

    /**
     * Redis tabs (#190): the names of the application's Redis connections, the default first,
     * for the tab's connection picker.
     *
     * @return string[]
     */
    public function redisConnections(): array
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
     * Rollback mode (#13): the database connections a dry run wraps in a transaction. Runlet
     * begins one on each before the snippet runs and rolls each back afterwards, whether the
     * snippet returns, throws, or exits. Called after inspect(), only when the tab's Dry Run is
     * on. Return a list, or name => connection; a connection is
     *
     *  - Eloquent: a Laravel or Capsule DatabaseManager (its open connections, and the ones the
     *    snippet opens later where illuminate/database announces them), or one Connection;
     *  - a Doctrine DBAL Connection, or a Doctrine connection registry;
     *  - WordPress's $wpdb;
     *  - a \PDO.
     *
     * The key names a Doctrine, $wpdb, or PDO connection in Runlet; use the name you report its
     * queries under in inspect(). The default finds what inspect() finds by itself (Eloquent
     * and $wpdb). Add your own with `parent::rollbackConnections() + ['reports' => $dbal]`, or
     * return [] to keep a driver's connections out of dry runs. Throwing stops the run before
     * the snippet: a dry run doesn't run code it can't wrap.
     *
     * @return array<int|string, object>
     */
    public function rollbackConnections(): array
    {
        return $this->automaticRollbackConnections();
    }

    /**
     * What rollbackConnections() finds by default: the connection resolver Eloquent models use
     * (Laravel's DatabaseManager), Capsule's global instance, and WordPress's $wpdb.
     *
     * @return array<int|string, object>
     */
    protected function automaticRollbackConnections(): array
    {
        $found = [];
        // Only classes the application already loaded: detection never autoloads.
        if (class_exists('Illuminate\Database\Eloquent\Model', false)) {
            $resolver = \Illuminate\Database\Eloquent\Model::getConnectionResolver();
            if (is_object($resolver)) {
                $found[] = $resolver;
            }
        }
        if (class_exists('Illuminate\Database\Capsule\Manager', false)) {
            $capsule = self::readStaticProperty('Illuminate\Database\Capsule\Manager', 'instance');
            if (is_object($capsule)) {
                $found[] = $capsule;
            }
        }
        $wpdb = $GLOBALS['wpdb'] ?? null;
        if (is_object($wpdb) && is_a($wpdb, 'wpdb')) {
            $found['wpdb'] = $wpdb;
        }

        return $found;
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
     * Casters (#6): how this application's own types show in Runlet's output, keyed by class
     * or interface name. Runlet never calls a value's methods to show it; a caster is the
     * explicit exception, and runs only while a value of its type is shown (a result, a dump,
     * a magic comment, or a run-inspector record).
     *
     *     return [
     *         Money::class => fn (Money $money) => $money->format(),
     *         EmailAddress::class => fn (EmailAddress $email) => ['address' => $email->value()],
     *     ];
     *
     * A caster returns a string or number (the summary line), an array (the fields), a
     * \Runlet\Cast (both), or null to leave the value to Runlet. The object's own class wins,
     * then its parent classes, then interfaces in the order given. A caster that throws, or
     * returns the object itself, leaves the object as Runlet shows it, with a note. Called once
     * per run, after inspect(), and never when Runlet lists commands. See docs/drivers.md.
     *
     * @return array<string, callable>
     */
    public function casters(): array
    {
        return [];
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
use Runlet\LaravelEventRecorder;
use Runlet\LaravelHttpRecorder;
use Runlet\LaravelJobRecorder;
use Runlet\SqlConnections;
use Runlet\WordPressHttpRecorder;

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

    /** Redis tabs (#190): Redis::connection($connection), the application's own (phpredis or Predis). */
    public function redisConnection(?string $connection)
    {
        $redis = $this->resolveService('redis');
        if ($redis === null || !method_exists($redis, 'connection')) {
            return null;
        }

        return $redis->connection($connection);
    }

    /** Redis tabs (#190): the connections of config('database.redis'), "default" first. */
    public function redisConnections(): array
    {
        $config = $this->resolveService('config');
        if ($config === null || !method_exists($config, 'get')) {
            return [];
        }
        $names = [];
        foreach (array_keys((array) $config->get('database.redis', [])) as $name) {
            if (!in_array($name, ['client', 'options', 'clusters'], true) && is_array($config->get('database.redis.' . $name))) {
                $names[] = (string) $name;
            }
        }
        if (in_array('default', $names, true)) {
            $names = array_merge(['default'], array_values(array_diff($names, ['default'])));
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
            $this->inspectLaravelHttp($inspector, $events);
            $this->inspectLaravelJobs($inspector, $events);
            $this->inspectLaravelEvents($inspector, $events);
        }
    }

    /**
     * Requests through Laravel's HTTP client (#5, Laravel 8.45+): method, URL, status, time,
     * and redacted headers, with bodies when the run asks for them. A response from
     * Http::fake() is marked faked.
     *
     * @param object $events the application's event dispatcher
     */
    protected function inspectLaravelHttp(Inspector $inspector, $events): void
    {
        if (!$inspector->shouldRecord(Inspector::HTTP) || !$inspector->once('laravel-http:' . spl_object_id($events))) {
            return;
        }
        $app = $this->app;
        $faking = static function () use ($app): bool {
            $class = 'Illuminate\Http\Client\Factory';
            if (!is_object($app) || !method_exists($app, 'resolved') || !$app->resolved($class)) {
                return false;
            }
            $stubs = self::readProperty($app->make($class), 'stubCallbacks');

            return $stubs instanceof \Countable && count($stubs) > 0;
        };
        (new LaravelHttpRecorder($inspector, $faking))->install($events);
    }

    /**
     * Jobs pushed to a queue (JobQueued, Laravel 8.24+) and jobs run during the run, as the
     * sync queue runs them (#5), with their time and any exception.
     *
     * @param object $events the application's event dispatcher
     */
    protected function inspectLaravelJobs(Inspector $inspector, $events): void
    {
        if (!$inspector->shouldRecord(Inspector::JOBS) || !$inspector->once('laravel-jobs:' . spl_object_id($events))) {
            return;
        }
        (new LaravelJobRecorder($inspector, $this->syncConnection()))->install($events);
    }

    /**
     * Every event the application dispatches (#5), when the run records events (off by
     * default): a wildcard listener that returns nothing, so it never stops an event.
     *
     * @param object $events the application's event dispatcher
     */
    protected function inspectLaravelEvents(Inspector $inspector, $events): void
    {
        if (!$inspector->shouldRecord(Inspector::EVENTS) || !$inspector->once('laravel-events:' . spl_object_id($events))) {
            return;
        }
        (new LaravelEventRecorder($inspector))->install($events);
    }

    /**
     * Whether a queue connection runs its jobs right away (the sync driver): its jobs are
     * recorded as they run, not as queued.
     *
     * @return \Closure(?string): bool
     */
    private function syncConnection(): \Closure
    {
        $app = $this->app;

        return static function (?string $connection) use ($app): bool {
            if ($connection === null || $connection === '') {
                return false;
            }
            if ($connection === 'sync') {
                return true;
            }
            try {
                $config = is_object($app) && method_exists($app, 'resolved') && $app->resolved('config') ? $app->make('config') : null;

                return is_object($config) && method_exists($config, 'get') && $config->get('queue.connections.' . $connection . '.driver') === 'sync';
            } catch (\Throwable $error) {
                return false;
            }
        };
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
        // The Jobs section (#5) lists the same jobs, by the same rules: a sync connection's
        // jobs run (and send) during the run, so they aren't queued mail.
        $isSync = $this->syncConnection();
        $events->listen('Illuminate\Queue\Events\JobQueued', static function ($event) use ($inspector, $isSync): void {
            $job = $event->job ?? null;
            $connection = isset($event->connectionName) && is_string($event->connectionName) ? $event->connectionName : null;
            if (!is_object($job) || $isSync($connection)) {
                return;
            }
            if (is_a($job, 'Illuminate\Notifications\SendQueuedNotifications') && is_array($job->channels ?? null) && !in_array('mail', $job->channels, true)) {
                return;
            }
            $mailable = is_a($job, 'Illuminate\Mail\SendQueuedMailable') || is_a($job, 'Illuminate\Notifications\SendQueuedNotifications')
                ? LaravelJobRecorder::names($job)[1]
                : null;
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

    /**
     * Rollback mode (#13): the application's database manager, so every connection it has open
     * and every one the snippet opens (ConnectionEstablished, Laravel 9.49+) joins the dry run.
     */
    public function rollbackConnections(): array
    {
        $connections = parent::rollbackConnections();
        $database = $this->resolveService('db');
        if (is_object($database)) {
            array_unshift($connections, $database);
        }

        return $connections;
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
    /** @var WordPressMail|null wp_mail() recording and interception for this run (#192). */
    private $mail;
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
        if ($inspector !== null && $inspector->isEnabled() && $this->mail === null) {
            // Before WordPress loads, so mail a plugin sends while WordPress boots (on init,
            // say) is recorded, and intercepted when the run asks for it.
            $this->mail = new WordPressMail($inspector);
            $this->mail->install();
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

    /** Queries ($wpdb) and mail sent with wp_mail(), intercepted when the run asks for it. */
    public function inspect(Inspector $inspector): void
    {
        parent::inspect($inspector);
        $this->inspectWordPressMail($inspector);
        $this->inspectWordPressHttp($inspector);
    }

    /**
     * Requests through WordPress's HTTP API (#5): wp_remote_get() and friends, timed from
     * `pre_http_request` to `http_api_debug`. Requests made while WordPress boots aren't
     * recorded; a request another `pre_http_request` callback answered is marked faked.
     */
    protected function inspectWordPressHttp(Inspector $inspector): void
    {
        if (!$inspector->shouldRecord(Inspector::HTTP) || !function_exists('add_filter') || !function_exists('add_action') || !$inspector->once('wordpress-http')) {
            return;
        }
        (new WordPressHttpRecorder($inspector))->install();
    }

    /**
     * Mail sent with wp_mail() (#192): each message in the Mail section, with its recipients,
     * bodies, attachments, and the plugin or theme that sent it. With Intercept Mail on,
     * `pre_wp_mail` stops each message before PHPMailer sees it (WordPress 5.7+), and
     * wp_mail() reports success to its caller. The hooks go in before WordPress loads, so
     * no file is added to the project. Runlet confirms interception only when it is
     * guaranteed; otherwise it says why (an older WordPress, a plugin that replaces wp_mail()
     * or takes over pre_wp_mail).
     */
    protected function inspectWordPressMail(Inspector $inspector): void
    {
        if (!function_exists('add_filter') || !function_exists('wp_mail')) {
            return;
        }
        if ($this->mail === null) {
            // A project driver that loaded WordPress without parent::bootstrap().
            $this->mail = new WordPressMail($inspector);
            $this->mail->install();
        }
        $inspector->section(Inspector::MAIL);
        if (!$inspector->shouldInterceptMail()) {
            return;
        }
        $reason = $this->mail->interceptionBlocker();
        if ($reason === null) {
            $inspector->interceptingMail();
        } else {
            $inspector->cannotInterceptMail($reason);
        }
    }

    /**
     * SQL tabs (#35, #208): WordPress's database, through a PDO connection opened from
     * wp-config.php's own settings when an SQL feature first needs it (MySQL and MariaDB with
     * DB_HOST, DB_NAME, DB_USER, DB_PASSWORD, and TLS; the SQLite Database Integration
     * drop-in's file), else through $wpdb, with the reason in the origin
     * (\RunletRunner\WordPressDatabase). The `wpdb` connection always runs through $wpdb.
     */
    public function sqlConnection(?string $connection)
    {
        $wpdb = $GLOBALS['wpdb'] ?? null;
        if (!is_object($wpdb) || !method_exists($wpdb, 'query')) {
            return null;
        }
        if ($connection !== null && $connection !== 'wpdb') {
            throw new \InvalidArgumentException('WordPress has one database connection, not "' . $connection . '". Choose the default connection, or "wpdb" to run statements through $wpdb.');
        }

        return \RunletRunner\WordPressDatabase::connection($wpdb, $connection === 'wpdb');
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
 * @internal wp_mail() for the run inspector (#192), used by WordPressDriver: records each
 * message in the Mail section and, when the run intercepts mail, stops it with `pre_wp_mail`.
 *
 * A message is recorded when WordPress reports how it went (`wp_mail_succeeded`,
 * `wp_mail_failed`), from what PHPMailer was given (`phpmailer_init`: the final recipients,
 * bodies, and attachments, after other plugins' changes). An intercepted message never reaches
 * PHPMailer, so it is recorded from wp_mail()'s arguments, read the way wp_mail() reads them.
 * Without an outcome (WordPress before 5.9, or a plugin's own wp_mail()), the message is
 * recorded when the next one starts or the run ends.
 */
final class WordPressMail
{
    /** @var Inspector */
    private $inspector;
    /** @var array<string, mixed>|null The message wp_mail() is handling now: `atts`, `fields`, `location`, `caller`. */
    private $pending;
    /** @var bool */
    private $installed = false;
    /** @var int Bytes of inline images turned into data: URLs this run. */
    private $inlineBudget = 4194304;

    public function __construct(Inspector $inspector)
    {
        $this->inspector = $inspector;
    }

    /** Adds the hooks: through add_filter() once WordPress is loaded, else into $wp_filter for WordPress to pick up. */
    public function install(): void
    {
        if ($this->installed) {
            return;
        }
        $this->installed = true;
        // Last, so the arguments and the PHPMailer object are final, and so Runlet's answer
        // on pre_wp_mail is the one wp_mail() gets.
        $hooks = [
            ['wp_mail', 'started', 1],
            ['pre_wp_mail', 'beforeSending', 2],
            ['phpmailer_init', 'built', 1],
            ['wp_mail_succeeded', 'succeeded', 1],
            ['wp_mail_failed', 'failed', 1],
        ];
        foreach ($hooks as [$hook, $method, $arguments]) {
            $callback = [$this, $method];
            if (function_exists('add_filter')) {
                add_filter($hook, $callback, PHP_INT_MAX, $arguments);
            } else {
                $GLOBALS['wp_filter'][$hook][PHP_INT_MAX][] = ['function' => $callback, 'accepted_args' => $arguments];
            }
        }
        $this->inspector->atFinish(function (): void {
            $this->flush();
        });
    }

    /**
     * Why this run can't promise that no wp_mail() message is sent, or null when it can.
     * Checked after WordPress loaded (plugins and the theme set up their hooks by then).
     */
    public function interceptionBlocker(): ?string
    {
        $version = isset($GLOBALS['wp_version']) ? (string) $GLOBALS['wp_version'] : '';
        if ($version !== '' && version_compare($version, '5.7', '<')) {
            return 'WordPress ' . $version . ' has no pre_wp_mail filter (WordPress 5.7 added it), so Runlet can\'t stop its mail.';
        }
        $replacement = self::wpMailReplacement();
        if ($replacement !== null) {
            return ucfirst($replacement) . ' replaces wp_mail(); Runlet can\'t stop its mail.';
        }
        $other = $this->otherPreWpMailCallback();
        if ($other !== null) {
            return ucfirst($other) . ' filters pre_wp_mail and could send mail itself before Runlet stops it. Messages marked intercepted were not sent.';
        }

        return null;
    }

    /**
     * `wp_mail` filter: the final arguments of a new message.
     *
     * @param mixed $atts
     * @return mixed
     */
    public function started($atts)
    {
        try {
            // The previous message's outcome was never reported (WordPress before 5.9).
            $this->flush();
            if (is_array($atts)) {
                $this->pending = ['atts' => $atts] + $this->origin();
            }
        } catch (\Throwable $error) {
            // Recording never breaks wp_mail().
        }

        return $atts;
    }

    /**
     * `pre_wp_mail` filter: true stops wp_mail() before PHPMailer, and wp_mail() returns true.
     *
     * @param mixed $return null, or what an earlier callback answered
     * @param mixed $atts
     * @return mixed
     */
    public function beforeSending($return, $atts = null)
    {
        try {
            if ($return !== null || !$this->inspector->shouldInterceptMail() || self::wpMailReplacement() !== null || $this->otherPreWpMailCallback(true) !== null) {
                // Not Runlet's to stop: interception is off, an earlier callback already
                // answered for this message, or a plugin's own wp_mail() or later callback
                // decides what happens next.
                return $return;
            }
            $pending = $this->pending ?? $this->origin();
            $this->pending = null;
            $arguments = is_array($atts) ? $atts : (is_array($pending['atts'] ?? null) ? $pending['atts'] : []);
            $this->report($this->fromArguments($arguments), $pending, ['intercepted' => true]);

            return true;
        } catch (\Throwable $error) {
            return $return;
        }
    }

    /**
     * `phpmailer_init` action: the message as PHPMailer will send it.
     *
     * @param mixed $phpmailer
     */
    public function built($phpmailer): void
    {
        try {
            if (!is_object($phpmailer)) {
                return;
            }
            $fields = $this->fromPhpMailer($phpmailer);
            if ($this->pending === null) {
                $this->pending = $this->origin();
            }
            $this->pending['fields'] = $fields;
        } catch (\Throwable $error) {
            // Recording never breaks wp_mail().
        }
    }

    /**
     * `wp_mail_succeeded` action (WordPress 5.9+).
     *
     * @param mixed $data
     */
    public function succeeded($data = null): void
    {
        $this->flush();
    }

    /**
     * `wp_mail_failed` action: the message, and PHPMailer's error.
     *
     * @param mixed $error a WP_Error
     */
    public function failed($error = null): void
    {
        try {
            $message = is_object($error) && method_exists($error, 'get_error_message') ? (string) $error->get_error_message() : '';
            $data = is_object($error) && method_exists($error, 'get_error_data') ? $error->get_error_data() : null;
            $pending = $this->pending ?? $this->origin();
            $this->pending = null;
            if (!isset($pending['fields'])) {
                $pending['fields'] = $this->fromArguments(is_array($pending['atts'] ?? null) ? $pending['atts'] : (is_array($data) ? $data : []));
            }
            $this->report($pending['fields'], $pending, ['error' => $message !== '' ? $message : 'wp_mail() could not send the message.']);
        } catch (\Throwable $ignored) {
            // Recording never breaks wp_mail().
        }
    }

    /** Records the message in progress as sent, if there is one. */
    private function flush(): void
    {
        $pending = $this->pending;
        if ($pending === null) {
            return;
        }
        $this->pending = null;
        try {
            $fields = $pending['fields'] ?? $this->fromArguments(is_array($pending['atts'] ?? null) ? $pending['atts'] : []);
            $this->report($fields, $pending, []);
        } catch (\Throwable $error) {
            // Recording never breaks wp_mail().
        }
    }

    /**
     * @param array<string, mixed> $fields
     * @param array<string, mixed> $pending
     * @param array<string, mixed> $details
     */
    private function report(array $fields, array $pending, array $details): void
    {
        $details += ['mailer' => 'wp_mail', 'intercepted' => false];
        if (isset($pending['location']) && is_array($pending['location']) && $pending['location'] !== []) {
            $details['location'] = $pending['location'];
        }
        if (isset($pending['caller']) && is_string($pending['caller'])) {
            $details['caller'] = $pending['caller'];
        }
        $this->inspector->mail($fields, $details);
    }

    /**
     * Where wp_mail() was called from: the snippet line when the snippet is on the stack,
     * else the call site; and the plugin, theme, or core function that called it.
     *
     * @return array{location: array<string, mixed>, caller?: string}
     */
    private function origin(): array
    {
        $location = $this->inspector->location();
        $frames = debug_backtrace(DEBUG_BACKTRACE_IGNORE_ARGS);
        $start = null;
        foreach ($frames as $index => $frame) {
            if (($frame['function'] ?? '') === 'wp_mail' && !isset($frame['class']) && isset($frame['file'])) {
                $start = $index;
                break;
            }
        }
        if ($start === null) {
            return ['location' => $location];
        }
        if (($location['inSnippet'] ?? false) !== true) {
            $location = ['inSnippet' => false, 'file' => (string) $frames[$start]['file'], 'line' => (int) ($frames[$start]['line'] ?? 0)];
        }
        $origin = ['location' => $location];
        $coreFunction = null;
        for ($index = $start; $index < count($frames); $index++) {
            $file = $frames[$index]['file'] ?? null;
            if (!is_string($file) || substr($file, -13) === "eval()'d code" || strpos($file, 'Standard input code') === 0 || $file === '-') {
                break;
            }
            $owner = self::owner($file);
            if ($owner === null) {
                // WordPress core: name the core function that sent it (retrieve_password()).
                if ($coreFunction === null && isset($frames[$index + 1]['function'])) {
                    $outer = $frames[$index + 1];
                    $coreFunction = (isset($outer['class']) ? $outer['class'] . '::' : '') . $outer['function'] . '()';
                }
                continue;
            }
            // "plugin acme-forms (src/Mailer.php:42)"; a one-file plugin: "plugin acme.php (line 3)".
            $short = self::shortPath($file);
            $line = (int) ($frames[$index]['line'] ?? 0);
            $where = substr($owner, -strlen($short) - 1) === ' ' . $short ? 'line ' . $line : $short . ':' . $line;
            $origin['caller'] = $owner . ' (' . $where . ')' . ($coreFunction !== null ? ' through ' . $coreFunction : '');

            return $origin;
        }
        if ($coreFunction !== null) {
            $origin['caller'] = 'WordPress core: ' . $coreFunction;
        }

        return $origin;
    }

    /**
     * The plugin, must-use plugin, or theme a file belongs to ("plugin acme-forms"), "code in
     * <path>" for other files outside WordPress core, or null for core (wp-includes, wp-admin).
     */
    private static function owner(string $file): ?string
    {
        $roots = [];
        if (defined('WPMU_PLUGIN_DIR')) {
            $roots['must-use plugin'] = (string) WPMU_PLUGIN_DIR;
        }
        if (defined('WP_PLUGIN_DIR')) {
            $roots['plugin'] = (string) WP_PLUGIN_DIR;
        }
        if (function_exists('get_theme_root')) {
            $roots['theme'] = (string) get_theme_root();
        } elseif (defined('WP_CONTENT_DIR')) {
            $roots['theme'] = WP_CONTENT_DIR . '/themes';
        }
        foreach ($roots as $kind => $root) {
            $relative = self::relativeTo($file, $root);
            if ($relative !== null) {
                $slash = strpos($relative, '/');

                return $kind . ' ' . ($slash === false ? $relative : substr($relative, 0, $slash));
            }
        }
        if (defined('ABSPATH') && defined('WPINC')) {
            foreach ([ABSPATH . WPINC, ABSPATH . 'wp-admin'] as $core) {
                if (self::relativeTo($file, $core) !== null) {
                    return null;
                }
            }
        }

        return 'code in ' . self::shortPath($file);
    }

    /** $file relative to the folder $root, or null when it is outside it (symbolic links resolved). */
    private static function relativeTo(string $file, string $root): ?string
    {
        $root = rtrim($root, '/');
        if ($root === '') {
            return null;
        }
        foreach (array_unique([$root, (string) realpath($root)]) as $candidate) {
            if ($candidate !== '' && strpos($file, $candidate . '/') === 0) {
                return substr($file, strlen($candidate) + 1);
            }
        }

        return null;
    }

    /** A path relative to the plugin, theme, or WordPress folder it is in. */
    private static function shortPath(string $file): string
    {
        $roots = [];
        foreach (['WPMU_PLUGIN_DIR', 'WP_PLUGIN_DIR'] as $constant) {
            if (defined($constant)) {
                $roots[] = (string) constant($constant);
            }
        }
        if (function_exists('get_theme_root')) {
            $roots[] = (string) get_theme_root();
        }
        foreach ($roots as $root) {
            $relative = self::relativeTo($file, $root);
            if ($relative !== null) {
                $slash = strpos($relative, '/');

                return $slash === false ? $relative : substr($relative, $slash + 1);
            }
        }
        if (defined('ABSPATH')) {
            $relative = self::relativeTo($file, (string) ABSPATH);
            if ($relative !== null) {
                return $relative;
            }
        }

        return basename($file);
    }

    /**
     * Who defined wp_mail() instead of WordPress (`wp-includes/pluggable.php`): "a plugin
     * (acme-smtp)", or null for WordPress's own.
     */
    private static function wpMailReplacement(): ?string
    {
        if (!function_exists('wp_mail') || !defined('ABSPATH') || !defined('WPINC')) {
            return null;
        }
        $file = (string) (new \ReflectionFunction('wp_mail'))->getFileName();
        $core = ABSPATH . WPINC . '/pluggable.php';
        if ($file === $core || realpath($file) === realpath($core)) {
            return null;
        }

        return self::described(self::owner($file) ?? 'code in ' . self::shortPath($file));
    }

    /**
     * A callback on pre_wp_mail that isn't Runlet's ("a plugin (acme-mailer)"), or null.
     * With $afterRunlet, only those that run after Runlet's (they would have the last word).
     */
    private function otherPreWpMailCallback(bool $afterRunlet = false): ?string
    {
        $hook = $GLOBALS['wp_filter']['pre_wp_mail'] ?? null;
        $callbacks = is_object($hook) && isset($hook->callbacks) && is_array($hook->callbacks) ? $hook->callbacks : (is_array($hook) ? $hook : []);
        ksort($callbacks);
        $seenRunlet = false;
        foreach ($callbacks as $entries) {
            foreach (is_array($entries) ? $entries : [] as $entry) {
                $function = is_array($entry) ? ($entry['function'] ?? null) : null;
                if (is_array($function) && ($function[0] ?? null) === $this) {
                    $seenRunlet = true;
                    continue;
                }
                if ($afterRunlet && !$seenRunlet) {
                    continue;
                }
                $file = self::callbackFile($function);

                return self::described($file === null ? 'a plugin' : (self::owner($file) ?? 'WordPress core'));
            }
        }

        return null;
    }

    /** "plugin acme-smtp" → "a plugin (acme-smtp)"; other descriptions stay as they are. */
    private static function described(string $owner): string
    {
        foreach (['must-use plugin', 'plugin', 'theme'] as $kind) {
            if (strpos($owner, $kind . ' ') === 0) {
                return 'a ' . $kind . ' (' . substr($owner, strlen($kind) + 1) . ')';
            }
        }

        return $owner;
    }

    /** @param mixed $callback */
    private static function callbackFile($callback): ?string
    {
        try {
            if (is_string($callback) && strpos($callback, '::') !== false) {
                $callback = explode('::', $callback, 2);
            }
            if (is_array($callback) && count($callback) === 2) {
                $reflection = new \ReflectionMethod($callback[0], (string) $callback[1]);
            } elseif ($callback instanceof \Closure || (is_string($callback) && function_exists($callback))) {
                $reflection = new \ReflectionFunction($callback);
            } elseif (is_object($callback) && method_exists($callback, '__invoke')) {
                $reflection = new \ReflectionMethod($callback, '__invoke');
            } else {
                return null;
            }
            $file = $reflection->getFileName();

            return is_string($file) ? $file : null;
        } catch (\Throwable $error) {
            return null;
        }
    }

    /**
     * A message from wp_mail()'s arguments, read as wp_mail() reads them: its headers (From,
     * Cc, Bcc, Reply-To, Content-Type), its defaults, and the filters that change them
     * (`wp_mail_from`, `wp_mail_from_name`, `wp_mail_content_type`).
     *
     * @param array<string, mixed> $atts
     * @return array<string, mixed>
     */
    private function fromArguments(array $atts): array
    {
        $split = static function ($value): array {
            $items = is_array($value) ? $value : explode(',', (string) $value);

            return array_values(array_filter(array_map(static function ($item): string {
                return is_scalar($item) ? trim((string) $item) : '';
            }, $items), 'strlen'));
        };
        $headers = $atts['headers'] ?? [];
        $lines = is_array($headers) ? $headers : explode("\n", str_replace("\r\n", "\n", (string) $headers));
        $cc = $bcc = $replyTo = [];
        $fromEmail = $fromName = $contentType = null;
        foreach ($lines as $line) {
            if (!is_string($line) || strpos($line, ':') === false) {
                continue;
            }
            [$name, $content] = explode(':', trim($line), 2);
            $content = trim($content);
            switch (strtolower(trim($name))) {
                case 'from':
                    $bracket = strpos($content, '<');
                    if ($bracket !== false) {
                        if ($bracket > 0) {
                            $fromName = trim(str_replace('"', '', substr($content, 0, $bracket)));
                        }
                        $fromEmail = trim(str_replace('>', '', substr($content, $bracket + 1)));
                    } elseif ($content !== '') {
                        $fromEmail = $content;
                    }
                    break;
                case 'content-type':
                    $type = trim(explode(';', $content)[0]);
                    if ($type !== '') {
                        $contentType = $type;
                    }
                    break;
                case 'cc':
                    $cc = array_merge($cc, $split($content));
                    break;
                case 'bcc':
                    $bcc = array_merge($bcc, $split($content));
                    break;
                case 'reply-to':
                    $replyTo = array_merge($replyTo, $split($content));
                    break;
            }
        }
        if ($fromEmail === null) {
            $host = function_exists('network_home_url') ? parse_url((string) network_home_url(), PHP_URL_HOST) : null;
            $fromEmail = 'wordpress@' . (is_string($host) ? preg_replace('/^www\./', '', $host) : '');
        }
        $fromName = $fromName ?? 'WordPress';
        $contentType = $contentType ?? 'text/plain';
        if (function_exists('apply_filters')) {
            $fromEmail = apply_filters('wp_mail_from', $fromEmail);
            $fromName = apply_filters('wp_mail_from_name', $fromName);
            $contentType = apply_filters('wp_mail_content_type', $contentType);
        }
        $message = isset($atts['message']) && is_scalar($atts['message']) ? (string) $atts['message'] : '';
        $fields = [
            'subject' => isset($atts['subject']) && is_scalar($atts['subject']) ? (string) $atts['subject'] : '',
            'from' => [['address' => is_scalar($fromEmail) ? (string) $fromEmail : '', 'name' => is_scalar($fromName) ? (string) $fromName : '']],
            'to' => $split($atts['to'] ?? []),
            'cc' => $cc,
            'bcc' => $bcc,
            'replyTo' => $replyTo,
            ($contentType === 'text/html' ? 'html' : 'text') => $message,
            'attachments' => [],
        ];
        $inline = [];
        $attachments = $atts['attachments'] ?? [];
        foreach (is_array($attachments) ? $attachments : explode("\n", str_replace("\r\n", "\n", (string) $attachments)) as $name => $path) {
            if (is_string($path) && $path !== '' && is_file($path) && is_readable($path)) {
                $fields['attachments'][] = self::fileAttachment($path, is_string($name) && $name !== '' ? $name : basename($path), false);
            }
        }
        $embeds = $atts['embeds'] ?? [];
        foreach (is_array($embeds) ? $embeds : explode("\n", str_replace("\r\n", "\n", (string) $embeds)) as $id => $path) {
            if (is_string($path) && $path !== '' && is_file($path) && is_readable($path)) {
                $fields['attachments'][] = self::fileAttachment($path, basename($path), true);
                $inline[(string) $id] = [$path, false];
            }
        }
        if (isset($fields['html']) && $inline !== []) {
            $fields['html'] = $this->inlineImages($fields['html'], $inline);
        }

        return $fields;
    }

    /**
     * The message PHPMailer was given: recipients, From, subject, bodies, attachments.
     *
     * @return array<string, mixed>
     */
    private function fromPhpMailer(object $mailer): array
    {
        $addresses = static function (object $mailer, string $method): array {
            $list = method_exists($mailer, $method) ? $mailer->$method() : [];
            $result = [];
            foreach (is_array($list) ? $list : [] as $entry) {
                if (is_array($entry) && isset($entry[0]) && is_string($entry[0])) {
                    $result[] = ['address' => $entry[0], 'name' => isset($entry[1]) && is_string($entry[1]) ? $entry[1] : ''];
                }
            }

            return $result;
        };
        $fields = [
            'subject' => isset($mailer->Subject) && is_scalar($mailer->Subject) ? (string) $mailer->Subject : '',
            'from' => [['address' => isset($mailer->From) ? (string) $mailer->From : '', 'name' => isset($mailer->FromName) ? (string) $mailer->FromName : '']],
            'to' => $addresses($mailer, 'getToAddresses'),
            'cc' => $addresses($mailer, 'getCcAddresses'),
            'bcc' => $addresses($mailer, 'getBccAddresses'),
            'replyTo' => $addresses($mailer, 'getReplyToAddresses'),
            'attachments' => [],
        ];
        $body = isset($mailer->Body) && is_scalar($mailer->Body) ? (string) $mailer->Body : '';
        $alternative = isset($mailer->AltBody) && is_scalar($mailer->AltBody) ? (string) $mailer->AltBody : '';
        if (stripos(isset($mailer->ContentType) ? (string) $mailer->ContentType : '', 'html') !== false) {
            $fields['html'] = $body;
            if ($alternative !== '') {
                $fields['text'] = $alternative;
            }
        } else {
            $fields['text'] = $body;
        }
        $inline = [];
        foreach (method_exists($mailer, 'getAttachments') ? (array) $mailer->getAttachments() : [] as $attachment) {
            // [path or contents, file name, name, encoding, type, is string, disposition, cid]
            if (!is_array($attachment) || !isset($attachment[0]) || !is_string($attachment[0])) {
                continue;
            }
            $isString = ($attachment[5] ?? false) === true;
            $isInline = ($attachment[6] ?? '') === 'inline';
            $name = isset($attachment[2]) && is_string($attachment[2]) && $attachment[2] !== '' ? $attachment[2] : (isset($attachment[1]) && is_string($attachment[1]) ? $attachment[1] : '');
            $entry = ['filename' => $name !== '' ? $name : ($isString ? 'attachment' : basename($attachment[0]))];
            if (isset($attachment[4]) && is_string($attachment[4]) && $attachment[4] !== '') {
                $entry['contentType'] = $attachment[4];
            }
            $size = $isString ? strlen($attachment[0]) : (is_file($attachment[0]) ? @filesize($attachment[0]) : false);
            if (is_int($size)) {
                $entry['size'] = $size;
            }
            if ($isInline) {
                $entry['inline'] = true;
                if (isset($attachment[7]) && is_string($attachment[7]) && $attachment[7] !== '') {
                    $inline[$attachment[7]] = [$attachment[0], $isString, $entry['contentType'] ?? null];
                }
            }
            $fields['attachments'][] = $entry;
        }
        if (isset($fields['html']) && $inline !== []) {
            $fields['html'] = $this->inlineImages($fields['html'], $inline);
        }

        return $fields;
    }

    /**
     * An attachment as PHPMailer would add it: typed from its path, named $name.
     *
     * @return array{filename: string, contentType?: string, size?: int, inline?: bool}
     */
    private static function fileAttachment(string $path, string $name, bool $inline): array
    {
        $entry = ['filename' => $name];
        $phpmailer = 'PHPMailer\PHPMailer\PHPMailer';
        if (!class_exists($phpmailer, false) && defined('ABSPATH') && defined('WPINC') && is_file(ABSPATH . WPINC . '/PHPMailer/PHPMailer.php')) {
            // WordPress 5.5+ loads it for every message it sends.
            require_once ABSPATH . WPINC . '/PHPMailer/PHPMailer.php';
        }
        if (class_exists($phpmailer, false) && method_exists($phpmailer, 'filenameToType')) {
            $type = $phpmailer::filenameToType($path);
        } else {
            $type = function_exists('wp_check_filetype') ? (wp_check_filetype($path)['type'] ?? null) : null;
        }
        if (is_string($type) && $type !== '') {
            $entry['contentType'] = $type;
        }
        $size = @filesize($path);
        if (is_int($size)) {
            $entry['size'] = $size;
        }
        if ($inline) {
            $entry['inline'] = true;
        }

        return $entry;
    }

    /**
     * `cid:` references in $html as data: URLs, so the preview shows inline images without
     * loading anything. At most 4 MB of images per run.
     *
     * @param array<string, array<int, mixed>> $inline cid => [path or contents, whether it is the contents, type]
     */
    private function inlineImages(string $html, array $inline): string
    {
        if (strpos($html, 'cid:') === false) {
            return $html;
        }
        foreach ($inline as $id => $image) {
            if ($id === '' || strpos($html, 'cid:' . $id) === false) {
                continue;
            }
            $contents = $image[1] ? $image[0] : (is_file($image[0]) && @filesize($image[0]) <= $this->inlineBudget ? @file_get_contents($image[0]) : false);
            if (!is_string($contents) || strlen($contents) > $this->inlineBudget) {
                continue;
            }
            $this->inlineBudget -= strlen($contents);
            $type = $image[2] ?? null;
            if (!is_string($type) || $type === '') {
                $type = !$image[1] && function_exists('wp_check_filetype') ? (string) (wp_check_filetype($image[0])['type'] ?? '') : '';
            }
            $html = str_replace('cid:' . $id, 'data:' . ($type !== '' ? $type : 'application/octet-stream') . ';base64,' . base64_encode($contents), $html);
        }

        return $html;
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

    /**
     * Rollback mode (#13): every connection of the `doctrine` registry, by name (beginning a
     * transaction connects it), plus what every driver finds.
     */
    public function rollbackConnections(): array
    {
        $connections = parent::rollbackConnections();
        $registry = $this->doctrine();
        if ($registry !== null && method_exists($registry, 'getConnectionNames')) {
            foreach (array_keys($registry->getConnectionNames()) as $name) {
                $connections[(string) $name] = $registry->getConnection($name);
            }
        }

        return $connections;
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
